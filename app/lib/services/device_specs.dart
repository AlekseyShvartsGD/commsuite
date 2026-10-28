import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Best-effort collection of the device / OS / app details attached to a crash
/// report. It never throws: an unsupported platform or a missing plugin simply
/// contributes fewer fields.
class DeviceSpecs {
  DeviceSpecs._();

  static Future<Map<String, String>> collect() async {
    final specs = <String, String>{};
    _put(specs, 'OS', '${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    _put(specs, 'Locale', Platform.localeName);
    _put(specs, 'CPU cores', '${Platform.numberOfProcessors}');

    final plugin = DeviceInfoPlugin();
    try {
      if (Platform.isWindows) {
        final info = await plugin.windowsInfo;
        _put(specs, 'Device', info.productName);
        _put(specs, 'Computer', info.computerName);
        _put(specs, 'Windows', '${info.productName} ${info.releaseId} (build ${info.buildNumber})');
      } else if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        _put(specs, 'Device', '${info.manufacturer} ${info.model}');
        _put(specs, 'Android', '${info.version.release} (SDK ${info.version.sdkInt})');
        _put(specs, 'Board', info.board);
      } else if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        _put(specs, 'Device', info.name);
        _put(specs, 'iOS', '${info.systemName} ${info.systemVersion} (${info.model})');
      } else if (Platform.isMacOS) {
        final info = await plugin.macOsInfo;
        _put(specs, 'Device', info.model);
        _put(specs, 'Computer', info.computerName);
        _put(specs, 'macOS', info.osRelease);
      } else if (Platform.isLinux) {
        final info = await plugin.linuxInfo;
        _put(specs, 'Device', info.name);
        _put(specs, 'Linux', info.prettyName);
      }
    } catch (_) {}

    return specs;
  }

  static Future<String> appVersion() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      return '${pkg.version}+${pkg.buildNumber}';
    } catch (_) {
      return '';
    }
  }

  static void _put(Map<String, String> specs, String key, String? value) {
    final v = value?.trim();
    if (v != null && v.isNotEmpty) specs[key] = v;
  }
}
