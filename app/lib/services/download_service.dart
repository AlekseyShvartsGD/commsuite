import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/localizations.dart';

/// One row in the browser's download list.
class DownloadItem {
  const DownloadItem({
    required this.path,
    required this.name,
    required this.size,
    required this.addedAt,
    required this.sourceUrl,
    this.inProgress = false,
    this.received = 0,
    this.error,
  });

  final String path;
  final String name;
  final int size;
  final DateTime addedAt;
  final String sourceUrl;
  final bool inProgress;
  final int received;
  final String? error;

  double? get progress =>
      (inProgress && size > 0) ? (received / size).clamp(0.0, 1.0) : null;

  DownloadItem copyWith({
    String? path,
    String? name,
    int? size,
    bool? inProgress,
    int? received,
    String? error,
    bool clearError = false,
  }) =>
      DownloadItem(
        path: path ?? this.path,
        name: name ?? this.name,
        size: size ?? this.size,
        addedAt: addedAt,
        sourceUrl: sourceUrl,
        inProgress: inProgress ?? this.inProgress,
        received: received ?? this.received,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Files the browser saved, newest first.
///
/// The list is rebuilt by scanning the downloads folder on startup, so files
/// survive a restart (and remain manageable after the browser tab that fetched
/// them is gone). Source URLs and sizes are not persisted - they are only shown
/// as a hint next to the file name.
class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  final List<DownloadItem> _items = [];
  List<DownloadItem> get items => List.unmodifiable(_items);

  /// Where downloads live: `<app documents>/downloads`.
  static Future<Directory> directory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> refresh() async {
    final dir = await directory();
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File) files.add(entity);
    }
    final busyPaths = {
      for (final i in _items)
        if (i.inProgress) i.path,
    };
    // Keep live rows (a download in flight is not on disk yet, or is partial),
    // then replace everything else with what the folder actually holds.
    final kept = _items.where((i) => busyPaths.contains(i.path)).toList();
    for (final file in files) {
      if (busyPaths.contains(file.path)) continue;
      final stat = await file.stat();
      kept.add(DownloadItem(
        path: file.path,
        name: file.uri.pathSegments.last,
        size: stat.size,
        addedAt: stat.modified,
        sourceUrl: '',
      ));
    }
    kept.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    _items
      ..clear()
      ..addAll(kept);
    notifyListeners();
  }

  /// Registers a download and starts fetching it in the background.
  ///
  /// [suggestedName] comes from the webview (Content-Disposition or the URL);
  /// collisions get a " (n)" suffix so a repeat download is never overwritten.
  Future<DownloadItem> start(
    String url, {
    String suggestedName = '',
    void Function(int code)? onStatus,
  }) async {
    final dir = await directory();
    final name = _uniqueName(dir, suggestedName.isEmpty ? _nameFromUrl(url) : suggestedName);
    final target = File('${dir.path}${Platform.pathSeparator}$name');

    final item = DownloadItem(
      path: target.path,
      name: name,
      size: 0,
      addedAt: DateTime.now(),
      sourceUrl: url,
      inProgress: true,
    );
    _items.insert(0, item);
    notifyListeners();

    unawaited(_fetch(url, target, onStatus));
    return item;
  }

  Future<void> _fetch(
    String url,
    File target,
    void Function(int code)? onStatus,
  ) async {
    final client = http.Client();
    File? partial;
    final path = target.path;
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request).timeout(const Duration(seconds: 30));
      onStatus?.call(response.statusCode);
      if (response.statusCode != 200) {
        _fail(path, L.t('Download failed (HTTP ${response.statusCode})',
            ru: 'Ошибка загрузки (HTTP ${response.statusCode})'));
        return;
      }
      // Write to a .part file first: a killed app must not leave a truncated
      // file that looks complete in the downloads list.
      partial = File('$path.part');
      final sink = partial.openWrite();
      var received = 0;
      final total = response.contentLength ?? 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        _update(path, received: received, size: total);
      }
      await sink.close();
      await partial.rename(path);
      _update(path,
          inProgress: false, received: received, size: received, clearError: true);
    } on TimeoutException {
      _fail(path, L.t('The server did not respond in time.',
        ru: 'Сервер не ответил вовремя.'));
    } on SocketException catch (e) {
      _fail(path, L.t('Network error: ${e.message}',
            ru: 'Ошибка сети: ${e.message}'));
    } catch (e) {
      _fail(path, L.t('Download failed: $e', ru: 'Ошибка загрузки: $e'));
    } finally {
      client.close();
      if (partial != null && partial.existsSync()) {
        try {
          partial.deleteSync();
        } catch (_) {}
      }
    }
  }

  void _update(String path,
      {bool? inProgress, int? received, int? size, bool clearError = false}) {
    final index = _items.indexWhere((i) => i.path == path);
    if (index == -1) return;
    _items[index] = _items[index].copyWith(
      inProgress: inProgress,
      received: received,
      size: size,
      clearError: clearError,
    );
    notifyListeners();
  }

  void _fail(String path, String message) {
    final index = _items.indexWhere((i) => i.path == path);
    if (index == -1) return;
    _items[index] = _items[index]
        .copyWith(inProgress: false, error: message, clearError: false);
    notifyListeners();
  }

  /// Renames the file on disk, keeping its row in place.
  ///
  /// Returns the new name, or throws [FileSystemException] when the target
  /// exists or the name is unusable.
  Future<String> rename(DownloadItem item, String newName) async {
    final clean = sanitizeFileName(newName);
    if (clean.isEmpty) {
      throw FileSystemException(L.t('Enter a name for the file.',
        ru: 'Введите имя файла.'));
    }
    final file = File(item.path);
    if (!await file.exists()) {
      throw FileSystemException(L.t('That file no longer exists.',
        ru: 'Этот файл больше не существует.'));
    }
    final dir = File(item.path).parent;
    if (clean == item.name) return clean;
    final target = File('${dir.path}${Platform.pathSeparator}$clean');
    if (await target.exists()) {
      throw FileSystemException(L.t('A file with that name already exists.',
        ru: 'Файл с таким именем уже существует.'));
    }
    await file.rename(target.path);
    final index = _items.indexOf(item);
    if (index != -1) {
      _items[index] = item.copyWith(path: target.path, name: clean);
      notifyListeners();
    }
    return clean;
  }

  Future<void> delete(DownloadItem item) async {
    final file = File(item.path);
    if (await file.exists()) {
      try {
        await file.delete();
      } on FileSystemException {
        // A file open elsewhere (or read-only) cannot be removed; surface that
        // instead of pretending the delete worked.
        rethrow;
      }
    }
    _items.remove(item);
    notifyListeners();
  }

  /// Strips characters no mainstream filesystem accepts, and keeps the result
  /// from escaping the folder (no separators, no "..").
  static String sanitizeFileName(String raw) {
    var name = raw.trim();
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    name = name.replaceAll('..', '.');
    name = name.trim();
    // Windows rejects trailing dots and spaces; other platforms tolerate them.
    while (name.isNotEmpty && (name.endsWith('.') || name.endsWith(' '))) {
      name = name.substring(0, name.length - 1);
    }
    if (name.length > 120) {
      // Keep the extension when trimming: "archive.tar.gz" must not become
      // "archive.tar". The trailing extension group starts at the earliest dot
      // within the last 12 characters, so multi-part suffixes survive.
      var extStart = -1;
      for (var i = name.length - 1; i >= 0 && name.length - i <= 12; i--) {
        if (name[i] == '.') extStart = i;
      }
      if (extStart > 0) {
        final ext = name.substring(extStart);
        name = name.substring(0, 120 - ext.length) + ext;
      } else {
        name = name.substring(0, 120);
      }
    }
    return name;
  }

  /// "setup.exe" from ".../files/setup.exe?token=1".
  static String _nameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    final segment = uri?.pathSegments.isNotEmpty == true
        ? uri!.pathSegments.last
        : '';
    final decoded = segment.isEmpty ? '' : Uri.decodeComponent(segment);
    final clean = sanitizeFileName(decoded);
    return clean.isEmpty ? 'download' : clean;
  }

  static String _uniqueName(Directory dir, String name) {
    var candidate = sanitizeFileName(name);
    if (candidate.isEmpty) candidate = 'download';
    if (!File('${dir.path}${Platform.pathSeparator}$candidate').existsSync()) {
      return candidate;
    }
    final dot = candidate.lastIndexOf('.');
    final stem = dot > 0 ? candidate.substring(0, dot) : candidate;
    final ext = dot > 0 ? candidate.substring(dot) : '';
    for (var n = 1; n < 1000; n++) {
      final next = '$stem ($n)$ext';
      if (!File('${dir.path}${Platform.pathSeparator}$next').existsSync()) {
        return next;
      }
    }
    return '${stem}_${DateTime.now().millisecondsSinceEpoch}$ext';
  }
}
