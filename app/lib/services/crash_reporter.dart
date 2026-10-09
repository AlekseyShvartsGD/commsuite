import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/error_bus.dart';

/// Persists unhandled exceptions to disk and lets the next app launch surface
/// them ("Commsuite recovered from a crash") so a crash doesn't stay silent.
class CrashReporter {
  CrashReporter._();

  static const _logName = 'commsuite-error.log';
  static const _pendingName = 'commsuite-crash.txt';

  static File _logFile() =>
      File('${Directory.systemTemp.path}${Platform.pathSeparator}$_logName');

  static File _pendingFile() =>
      File('${Directory.systemTemp.path}${Platform.pathSeparator}$_pendingName');

  static void log(String message, StackTrace stack) {
    final stamp = '[${DateTime.now().toIso8601String()}]\n$message\n$stack\n';
    try {
      _logFile().writeAsStringSync(stamp, mode: FileMode.append);
      _pendingFile().writeAsStringSync(stamp);
    } catch (_) {}
    if (!kIsWeb) debugPrint('commsuite error: $message\n$stack');
    reportError(message, stack);
  }

  /// Returns the pending crash report from the previous session, if any.
  static Future<String?> readPendingCrash() async {
    try {
      final f = _pendingFile();
      if (!await f.exists()) return null;
      final text = await f.readAsString();
      if (text.trim().isEmpty) {
        await clearPendingCrash();
        return null;
      }
      return text;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearPendingCrash() async {
    try {
      final f = _pendingFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}