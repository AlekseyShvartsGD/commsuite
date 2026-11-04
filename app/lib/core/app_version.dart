/// Current app version (semver). Must stay in sync with:
///  - pubspec.yaml `version:`
///  - installer/CommsuiteInstaller.csproj `Version` / `FileVersion`
///  - server/update/latest.json `version`
///
/// `test/version_sync_test.dart` fails when this drifts from pubspec.yaml, so
/// the update prompt can never advertise a version the build already is.
const String appVersion = '1.1.3';
