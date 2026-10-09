import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/app_config.dart';
import '../core/app_version.dart';
import '../core/navigation.dart';

import '../core/localizations.dart';

class UpdateInfo {
  final String version;
  final String windowsVersion;
  final String apkVersion;
  final String linuxVersion;
  final String notes;
  final String installer;
  final int? size;
  final String? sha256;
  final String apk;
  final int? apkSize;
  final String? apkSha256;
  final String linux;
  final int? linuxSize;
  final String? linuxSha256;

  /// Optional mirror URLs tried before the primary server, so a release stays
  /// installable when the primary host is down, blocked, or (in a browser)
  /// carrying a reputation warning. Absolute URLs only - mirrors may live on a
  /// host with a different layout (e.g. GitHub release assets).
  final List<String> installerMirrors;
  final List<String> apkMirrors;
  final List<String> linuxMirrors;

  const UpdateInfo({
    required this.version,
    this.windowsVersion = '',
    this.apkVersion = '',
    this.linuxVersion = '',
    required this.notes,
    required this.installer,
    this.size,
    this.sha256,
    this.apk = '',
    this.apkSize,
    this.apkSha256,
    this.linux = '',
    this.linuxSize,
    this.linuxSha256,
    this.installerMirrors = const [],
    this.apkMirrors = const [],
    this.linuxMirrors = const [],
  });

  /// Accepts either a single URL string or a list of them; anything that is not
  /// an absolute http(s) URL is ignored so a malformed manifest cannot send the
  /// downloader somewhere unexpected.
  static List<String> _mirrors(dynamic value) {
    final raw = value is List ? value : <dynamic>[value];
    return <String>[
      for (final v in raw)
        if (v is String &&
            (v.startsWith('http://') || v.startsWith('https://')))
          v,
    ];
  }

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    final mirrors = json['mirrors'];
    List<String> pick(String key) =>
        mirrors is Map ? _mirrors(mirrors[key]) : const <String>[];
    return UpdateInfo(
      version: json['version'] as String? ?? '',
      windowsVersion: json['windowsVersion'] as String? ?? '',
      apkVersion: json['apkVersion'] as String? ?? '',
      linuxVersion: json['linuxVersion'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      installer: json['installer'] as String? ?? '/update/commsuite-setup.exe',
      size: (json['installerSize'] as num?)?.toInt(),
      sha256: json['installerSha256'] as String?,
      apk: json['apk'] as String? ?? '/update/commsuite.apk',
      apkSize: (json['apkSize'] as num?)?.toInt(),
      apkSha256: json['apkSha256'] as String?,
      linux: json['linux'] as String? ?? '/update/commsuite-linux.tar.gz',
      linuxSize: (json['linuxSize'] as num?)?.toInt(),
      linuxSha256: json['linuxSha256'] as String?,
      installerMirrors: pick('installer'),
      apkMirrors: pick('apk'),
      linuxMirrors: pick('linux'),
    );
  }

  bool get valid => version.isNotEmpty;

  /// The version that applies to THIS platform. A release that only bumped one
  /// platform must not look newer to the others (the manifest carries per-
  /// platform versions; old manifests only have 'version').
  String get targetVersion {
    if (Platform.isWindows && windowsVersion.isNotEmpty) return windowsVersion;
    if (Platform.isAndroid && apkVersion.isNotEmpty) return apkVersion;
    if (Platform.isLinux && linuxVersion.isNotEmpty) return linuxVersion;
    return version;
  }
}

/// Compares dotted numeric versions. Returns >0 if [a] is newer than [b].
int _compareVersions(String a, String b) {
  final pa = a.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final pb = b.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x - y;
  }
  return 0;
}

/// Windows/Android/Linux updater. Checks the configured server's /update
/// feed and, when a newer version exists, asks the user to download and apply
/// it. Updates are never applied automatically: the old silent updater tore
/// the app down mid-session and corrupted the WebView2 state, so every update
/// now requires explicit confirmation.
class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const MethodChannel _channel = MethodChannel('commsuite/updater');

  final ValueNotifier<double> progress = ValueNotifier(0);
  bool _checking = false;
  String _shownFor = '';

  bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isAndroid || Platform.isLinux);

  /// Starts background polling. Called once at app startup: an immediate
  /// check (with a few retries while the local server boots) then every 60 s.
  void start() {
    if (!supported) return;
    _schedule(const Duration(seconds: 3));
    // Active repeating timers are held by the isolate's timer queue, so the
    // periodic handle can be dropped after creation.
    Timer.periodic(const Duration(minutes: 1), (_) => _tick());
  }

  void _schedule(Duration delay) {
    Future<void>.delayed(delay, _tick);
  }

  Future<void> _tick() async {
    if (_checking) return;
    _checking = true;
    try {
      // A few retries so the check survives the server still booting
      // (the auto-starter starts WSL/node on demand).
      for (var attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(const Duration(seconds: 8));
        }
        final info = await _fetch();
        if (info == null) continue; // nothing newer (or server unreachable yet)
        if (info.targetVersion != _shownFor) {
          _shownFor = info.targetVersion;
          // Never install silently. Auto-update was removed because it killed
          // the app mid-session and left WebView2 in a broken state; the user
          // always confirms first.
          _prompt(info);
        }
        break;
      }
    } catch (_) {
    } finally {
      _checking = false;
    }
  }

  Future<UpdateInfo?> _fetch() async {
    final uri = Uri.parse('${AppConfig.serverUrl}/update/latest.json');
    final resp = await http.get(uri).timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;
    final info = UpdateInfo.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
    if (!info.valid) return null;
    if (_compareVersions(info.targetVersion, appVersion) <= 0) {
      return null; // nothing newer on this platform
    }
    return info;
  }

  Future<void> _prompt(UpdateInfo info) async {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    final onAndroid = Platform.isAndroid;
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.system_update_alt),
        title: Text(
          L.t(
            'Commsuite v${info.targetVersion} available',
            ru: 'Доступна новая версия Commsuite v${info.targetVersion}',
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                L.t(
                  'You are on v$appVersion.',
                  ru: 'У вас установлена v$appVersion.',
                ),
              ),
              if (info.notes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(info.notes),
              ],
              const SizedBox(height: 8),
              Text(
                onAndroid
                    ? L.t(
                        'The update will be downloaded and opened in the system installer.',
                        ru: 'Обновление будет загружено и открыто в системном установщике.',
                      )
                    : L.t(
                        'The app will close briefly during the update and reopen automatically.',
                        ru: 'Приложение ненадолго закроется при обновлении и откроется снова автоматически.',
                      ),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Later', ru: 'Позже')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.t('Update now', ru: 'Обновить сейчас')),
          ),
        ],
      ),
    ).then((accept) {
      if (accept == true) runUpdate(info);
    });
  }

  Future<void> runUpdate(UpdateInfo info) async {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    // Grab the messenger up front so the failure branch below doesn't have to
    // touch a BuildContext after the async gaps.
    final messenger = ScaffoldMessenger.maybeOf(context);

    progress.value = 0;
    // Download in the background while the progress dialog is on screen;
    // pop the dialog with the file path when the download finishes.
    final path = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _download(info).then((p) {
          if (dialogContext.mounted) Navigator.of(dialogContext).pop(p);
        });
        return AlertDialog(
          title: Text(L.t('Downloading update…', ru: 'Загрузка обновления…')),
          content: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder: (context, value, _) =>
                      LinearProgressIndicator(value: value),
                ),
              ),
              const SizedBox(width: 12),
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ),
        );
      },
    );
    if (path == null || !await File(path).exists()) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            L.t(
              'Update download failed. Please try again later.',
              ru: 'Не удалось загрузить обновление. Попробуйте позже.',
            ),
          ),
        ),
      );
      return;
    }
    await _install(path);
  }

  Future<String?> _download(UpdateInfo info) async {
    final isAndroid = Platform.isAndroid;
    final isLinux = Platform.isLinux;
    final url = isAndroid ? info.apk : (isLinux ? info.linux : info.installer);
    if (url.isEmpty) return null;
    final mirrors = isAndroid
        ? info.apkMirrors
        : (isLinux ? info.linuxMirrors : info.installerMirrors);
    final dir = await getTemporaryDirectory();
    final ext = isAndroid ? '.apk' : (isLinux ? '.tar.gz' : '.exe');
    final target = File(
      '${dir.path}${Platform.pathSeparator}commsuite-update-${info.version}$ext',
    );
    final expectedSize = isAndroid
        ? info.apkSize
        : (isLinux ? info.linuxSize : info.size);
    final expectedSha = isAndroid
        ? info.apkSha256
        : (isLinux ? info.linuxSha256 : info.sha256);

    // Mirrors first, primary host last: a mirror failure (or a bad file on it)
    // falls through to the next candidate, and the last word belongs to the
    // server we control.
    final candidates = <String>[...mirrors, '${AppConfig.serverUrl}$url'];
    for (final candidate in candidates) {
      final path = await _fetchArtifact(
        Uri.parse(candidate),
        target,
        expectedSize,
        expectedSha,
      );
      if (path != null) return path;
    }
    return null;
  }

  /// Downloads [uri] into [target], returning its path only when the file is
  /// complete and (when the feed provided one) hash-identical to the release.
  Future<String?> _fetchArtifact(
    Uri uri,
    File target,
    int? expectedSize,
    String? expectedSha,
  ) async {
    try {
      final client = http.Client();
      final streamed = await client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 30));
      if (streamed.statusCode != 200) {
        client.close();
        return null;
      }
      final total = streamed.contentLength ?? 0;
      final sink = target.openWrite();
      var received = 0;
      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) progress.value = received / total;
      }
      await sink.close();
      client.close();
      progress.value = 1;

      // Guard against truncated/corrupt transfers (the public tunnel has cut a
      // transfer mid-stream before): require the exact byte count and, when the
      // feed provides one, a matching SHA-256. The same check covers a mirror
      // that serves a stale or tampered file.
      if (expectedSize != null && received != expectedSize) {
        target.deleteSync();
        return null;
      }
      if (expectedSha != null) {
        final bytes = await target.readAsBytes();
        final digest = sha256.convert(bytes).toString().toLowerCase();
        if (digest != expectedSha.toLowerCase()) {
          target.deleteSync();
          return null;
        }
      }
      return target.path;
    } catch (_) {
      if (target.existsSync()) {
        try {
          target.deleteSync();
        } catch (_) {}
      }
      return null;
    }
  }

  Future<void> _install(String filePath) async {
    if (Platform.isAndroid) {
      // Hand the verified APK to the system installer (via FileProvider).
      final ok = await _channel
          .invokeMethod<bool>('installApk', {'path': filePath})
          .catchError((Object _) => false);
      if (ok != true) {
        ScaffoldMessenger.maybeOf(navigatorKey.currentContext!)?.showSnackBar(
          SnackBar(
            content: Text(
              L.t(
                'Unable to launch the installer. Allow "Install unknown apps" for Commsuite in Android settings, then try again.',
                ru: 'Не удалось запустить установщик. Разрешите «Установка неизвестных приложений» для Commsuite в настройках Android и попробуйте снова.',
              ),
            ),
          ),
        );
      }
      return;
    }

    if (Platform.isLinux) {
      await _installLinux(filePath);
      return;
    }

    // Windows: the app exits first, then the UAC-elevated installer replaces
    // the files (silently) and relaunches the app. The scheduled-task
    // auto-update path was removed; this runs only on user confirmation.
    try {
      await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-WindowStyle',
          'Hidden',
          '-Command',
          'Start-Process -FilePath "$filePath" -ArgumentList "/S"',
        ],
        mode: ProcessStartMode.detached,
        runInShell: true,
      );
    } catch (_) {
      return; // refused to start; give up quietly
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    exit(0);
  }

  /// Linux: swap the running bundle for the verified tarball in place and
  /// relaunch. The running binary is renamed out of the way first (a mapped
  /// executable cannot be overwritten in place), tar extracts the new bundle,
  /// then the fresh copy is started and this process exits.
  Future<void> _installLinux(String tarballPath) async {
    final messenger = navigatorKey.currentContext == null
        ? null
        : ScaffoldMessenger.maybeOf(navigatorKey.currentContext!);
    final exe = Platform.resolvedExecutable;
    final dir = File(exe).parent;
    final oldExe = '$exe.old';
    try {
      final mv = await Process.run('mv', [exe, oldExe]).timeout(
        const Duration(seconds: 20),
        onTimeout: () => ProcessResult(-1, -1, '', 'timed out'),
      );
      if (mv.exitCode != 0) {
        messenger?.showSnackBar(
          SnackBar(
            content: Text(
              L.t(
                'Update apply failed (could not replace the app files).',
                ru: 'Не удалось применить обновление (не удалось заменить файлы приложения).',
              ),
            ),
          ),
        );
        return;
      }
      final tar = await Process.run('tar', ['xzf', tarballPath, '-C', dir.path])
          .timeout(
            const Duration(seconds: 120),
            onTimeout: () => ProcessResult(-1, -1, '', 'timed out'),
          );
      if (tar.exitCode != 0) {
        // Roll back so the previous build keeps working.
        await Process.run('mv', [oldExe, exe]);
        messenger?.showSnackBar(
          SnackBar(
            content: Text(
              L.t(
                'Update apply failed; kept the previous build.',
                ru: 'Не удалось применить обновление; сохранена предыдущая версия.',
              ),
            ),
          ),
        );
        return;
      }
    } catch (_) {
      try {
        await Process.run('mv', [oldExe, exe]);
      } catch (_) {}
      return;
    }
    try {
      await File(tarballPath).delete();
    } catch (_) {}
    try {
      await File(oldExe).delete();
    } catch (_) {}
    await Process.start(exe, [], mode: ProcessStartMode.detached);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }
}
