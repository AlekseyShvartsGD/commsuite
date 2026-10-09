import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows-only: reads/writes the per-user "Start with Windows" registry entry
/// (HKCU\...\Run) that the NSIS installer seeds with `"<exe>" --background`.
/// Using HKCU keeps the toggle elevation-free.
class AutostartService {
  AutostartService._();

  static const MethodChannel _channel = MethodChannel('commsuite/autostart');

  static bool get supported => !kIsWeb && Platform.isWindows;

  static Future<bool> isEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
      return true;
    } catch (_) {
      return false;
    }
  }
}