import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the version contract documented in README.md ("The version lives in
/// `installer/CommsuiteInstaller.csproj` (`Version`, `FileVersion`) and must
/// stay in sync with `app/pubspec.yaml`, `app/lib/core/app_version.dart` and
/// `server/update/latest.json`").
///
/// Shipping a build whose compiled-in `appVersion` is older than the manifest
/// makes `UpdateService` advertise the running version forever: every launch
/// prompts for an update that reinstalling cannot clear. That is a user-visible
/// bug that no other test catches, because `appVersion` is a constant.
void main() {
  String pubspecVersion() {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.trimLeft().startsWith('version:'));
    // "1.0.42+42" -> "1.0.42"
    return line.split(':')[1].trim().split('+').first;
  }

  String? csprojValue(String tag) {
    final file = File('../installer/CommsuiteInstaller.csproj');
    if (!file.existsSync()) return null;
    final m = RegExp('<$tag>([^<]+)</$tag>')
        .firstMatch(file.readAsStringSync());
    return m?.group(1)?.trim();
  }

  group('version sync', () {
    test('appVersion matches pubspec.yaml', () {
      final m = RegExp(r"appVersion\s*=\s*'([^']+)'")
          .firstMatch(File('lib/core/app_version.dart').readAsStringSync());
      expect(m, isNotNull, reason: 'appVersion constant not found');
      expect(m!.group(1), pubspecVersion());
    });

    test('installer csproj matches pubspec.yaml', () {
      final version = pubspecVersion();
      // Only the repo layout has the installer next to the app; a copied-out
      // build tree legitimately lacks it.
      if (csprojValue('Version') == null) {
        markTestSkipped('installer project not present');
        return;
      }
      expect(csprojValue('Version'), version);
      expect(csprojValue('FileVersion'), '$version.0');
      expect(csprojValue('AssemblyVersion'), '$version.0');
    });

    test('update manifest does not advertise a newer version', () {
      final manifest = File('../server/update/latest.json');
      if (!manifest.existsSync()) {
        markTestSkipped('update manifest not present');
        return;
      }
      final text = manifest.readAsStringSync();
      final m = RegExp(r'"version"\s*:\s*"([^"]+)"').firstMatch(text);
      expect(m, isNotNull, reason: 'manifest has no version');

      List<int> parts(String v) => v.split('.').map(int.parse).toList();
      final feed = parts(m!.group(1)!);
      final app = parts(pubspecVersion());
      for (var i = 0; i < app.length; i++) {
        final f = i < feed.length ? feed[i] : 0;
        if (f != app[i]) {
          expect(
            f < app[i],
            isTrue,
            reason:
                'manifest ${m.group(1)} is newer than the app '
                '${pubspecVersion()}: publish the manifest or bump the build',
          );
          break;
        }
      }
    });
  });
}
