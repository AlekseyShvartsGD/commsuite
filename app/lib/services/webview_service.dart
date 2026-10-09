import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('commsuite/webview2');

/// Installed Microsoft Edge WebView2 Runtime version on Windows.
///
/// Empty when the runtime is missing or this isn't the Windows desktop
/// build. The Browser tab uses this to fall back to the system browser
/// instead of letting WebView2 initialization throw.
Future<String> webview2RuntimeVersion() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
    return '';
  }
  try {
    return await _channel.invokeMethod<String>('runtimeVersion') ?? '';
  } catch (_) {
    return '';
  }
}