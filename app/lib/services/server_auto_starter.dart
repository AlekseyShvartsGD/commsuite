import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/app_config.dart';

/// Windows-only: if the configured server is unreachable when the app starts,
/// boots the local server stack (WSL node + CloudPub tunnels) in the background
/// by running the manage script, then waits for it to come up. Calls/messages
/// then keep working even if the operator forgot to start the server.
class ServerAutoStarter {
  ServerAutoStarter._();

  static bool _attempted = false;

  static Future<void> ensureRunning() async {
    if (kIsWeb || !Platform.isWindows || _attempted) return;
    _attempted = true;
    if (await _isUp()) return;
    final script = _findScript();
    if (script == null) return;
    try {
      await Process.start('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script,
      ]);
    } catch (_) {
      return;
    }
    // Poll the health endpoint for up to ~90 s while the stack boots.
    for (var i = 0; i < 45; i++) {
      if (await _isUp()) return;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  static Future<bool> _isUp() async {
    try {
      final res = await http
          .get(Uri.parse('${AppConfig.serverUrl}/health'))
          .timeout(const Duration(seconds: 4));
      return res.statusCode >= 200 && res.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  static String? _findScript() {
    final env = Platform.environment;
    final override = env['COMMSUITE_START_SCRIPT'];
    if (override != null && File(override).existsSync()) return override;
    final home = env['USERPROFILE'] ?? '';
    final candidateRoots = <String>[
      r'C:\Users\aleks\Desktop\alekz',
      '$home\\Desktop\\alekz',
      '$home\\Documents\\alekz',
    ];
    for (final root in candidateRoots) {
      final path = '$root\\server\\turn\\start-all.ps1';
      if (File(path).existsSync()) return path;
    }
    return null;
  }
}