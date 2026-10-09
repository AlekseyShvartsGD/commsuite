import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_config.dart';
import 'core/localizations.dart';
import 'services/crash_reporter.dart';
import 'services/tray_service.dart';

Future<void> main() async {
  // Start the guarded zone BEFORE the bindings so runApp runs in the same zone.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Auto-started from the installer's "Run at login" entry with
    // `--background`: start hidden in the system tray instead of a window.
    if (Platform.executableArguments.contains('--background')) {
      TrayService.instance.requestStartHidden = true;
      _logError(
          'auto-start (--background); argv=${Platform.executableArguments}',
          StackTrace.current);
    }

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      final message = details.exceptionAsString();
      // RenderFlex overflow diagnostics fire during paint. Feeding them to
      // CrashReporter made the error banner setState mid-frame which itself
      // threw "Build scheduled during frame" -> cascade and ANRs.
      if (message.contains('overflowed by ') &&
          (message.contains('pixels on the') || message.contains('pixels. '))) {
        return;
      }
      _logError(message, details.stack ?? StackTrace.current);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _logError('$error', stack);
      return true;
    };
    // Restore the saved UI language before anything builds.
    await AppConfig.init();
    L.setLang(await AppConfig.loadLanguage());
    await TrayService.instance.initWindow();
    runApp(const CommsApp());
  }, (error, stack) => _logError('$error', stack));
}

void _logError(String message, StackTrace stack) {
  CrashReporter.log(message, stack);
}