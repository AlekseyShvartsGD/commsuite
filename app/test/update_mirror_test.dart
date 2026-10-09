import 'package:commsuite/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UpdateInfo.fromJson mirrors', () {
    test('reads absolute mirror URLs per platform', () {
      final info = UpdateInfo.fromJson({
        'version': '1.0.29',
        'notes': '',
        'mirrors': {
          'installer': [
            'https://cdn.example.com/commsuite-setup.exe',
            'https://backup.example.com/commsuite-setup.exe',
          ],
          'apk': 'https://github.com/o/r/releases/download/v1/commsuite.apk',
          'linux': <String>[],
        },
      });

      expect(info.installerMirrors, [
        'https://cdn.example.com/commsuite-setup.exe',
        'https://backup.example.com/commsuite-setup.exe',
      ]);
      expect(info.apkMirrors, ['https://github.com/o/r/releases/download/v1/commsuite.apk']);
      expect(info.linuxMirrors, isEmpty);
    });

    test('ignores relative or non-http values and a missing block', () {
      final info = UpdateInfo.fromJson({
        'version': '1.0.29',
        'notes': '',
        'mirrors': {
          'installer': [
            '/update/commsuite-setup.exe',
            'file:///etc/passwd',
            'ftp://example.com/x.exe',
            42,
          ],
        },
      });
      expect(info.installerMirrors, isEmpty);

      final bare = UpdateInfo.fromJson({'version': '1.0.29', 'notes': ''});
      expect(bare.installerMirrors, isEmpty);
      expect(bare.apkMirrors, isEmpty);
      expect(bare.linuxMirrors, isEmpty);
    });

    test('existing manifests without mirrors still parse', () {
      final info = UpdateInfo.fromJson({
        'version': '1.0.29',
        'notes': 'hi',
        'installer': '/update/commsuite-setup.exe',
        'installerSize': 10,
        'linux': '/update/commsuite-linux-1.0.29.tar.gz',
      });
      expect(info.valid, isTrue);
      expect(info.installer, '/update/commsuite-setup.exe');
      expect(info.installerMirrors, isEmpty);
    });
  });
}
