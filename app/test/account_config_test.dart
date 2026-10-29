import 'package:commsuite/core/account.dart';
import 'package:commsuite/core/app_config.dart';
import 'package:commsuite/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

User _user(String id, String username) => User(
  id: id,
  username: username,
  displayName: username.toUpperCase(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppConfig.init();
  });

  test('accounts persist, activate and restore by recency', () async {
    final a = AccountRecord.fromUser(
      _user('u1', 'alice'),
      serverUrl: 'http://a.test:3000',
      token: 'tok-a',
    );
    final b = AccountRecord.fromUser(
      _user('u2', 'bob'),
      serverUrl: 'http://b.test:3000',
      token: 'tok-b',
    );
    await AppConfig.upsertAccount(a);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await AppConfig.upsertAccount(b);

    expect(AppConfig.accounts.length, 2);
    expect(AppConfig.activeAccountId, b.id);
    expect(await AppConfig.loadToken(), 'tok-b');
    expect(AppConfig.serverUrl, 'http://b.test:3000');

    await AppConfig.activateAccount(a.id);
    expect(await AppConfig.loadToken(), 'tok-a');
    expect(AppConfig.serverUrl, 'http://a.test:3000');

    // Reload from disk: the most recently used account wins.
    await AppConfig.init();
    expect(AppConfig.activeAccountId, a.id);
    expect(await AppConfig.loadToken(), 'tok-a');
  });

  test('removing the active account selects the remaining one', () async {
    final a = AccountRecord.fromUser(
      _user('u1', 'alice'),
      serverUrl: 'http://a.test:3000',
      token: 'tok-a',
    );
    final b = AccountRecord.fromUser(
      _user('u2', 'bob'),
      serverUrl: 'http://a.test:3000',
      token: 'tok-b',
    );
    await AppConfig.upsertAccount(a);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await AppConfig.upsertAccount(b);

    await AppConfig.removeAccount(b.id);
    expect(AppConfig.accounts.single.id, a.id);
    expect(AppConfig.activeAccountId, a.id);
    expect(await AppConfig.loadToken(), 'tok-a');

    await AppConfig.removeAccount(a.id);
    expect(AppConfig.accounts, isEmpty);
    expect(AppConfig.activeAccountId, isNull);
    expect(await AppConfig.loadToken(), isNull);
  });

  test('legacy single token is adopted as the first account', () async {
    SharedPreferences.setMockInitialValues({
      'commsuite.server_url': 'http://old.test:3000',
      'commsuite.token': 'legacy-token',
    });
    await AppConfig.init();
    expect(AppConfig.accounts, isEmpty);
    expect(await AppConfig.loadToken(), 'legacy-token');

    final user = _user('u9', 'legacy');
    await AppConfig.adoptLegacyToken(user, 'legacy-token');

    expect(AppConfig.accounts.length, 1);
    expect(AppConfig.activeAccount?.username, 'legacy');
    expect(AppConfig.serverUrl, 'http://old.test:3000');
    expect(await AppConfig.loadToken(), 'legacy-token');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('commsuite.token'), isNull);
  });

  test('camera and language preferences are per account', () async {
    final a = AccountRecord.fromUser(
      _user('u1', 'alice'),
      serverUrl: 'http://a.test:3000',
      token: 'tok-a',
    );
    final b = AccountRecord.fromUser(
      _user('u2', 'bob'),
      serverUrl: 'http://a.test:3000',
      token: 'tok-b',
    );
    await AppConfig.upsertAccount(a);
    await AppConfig.setCameraId('camera-a');
    await AppConfig.setLanguage('ru');

    await AppConfig.upsertAccount(b);
    expect(AppConfig.cameraId, ''); // bob has no choice yet
    await AppConfig.setCameraId('camera-b');
    expect(AppConfig.cameraId, 'camera-b');

    await AppConfig.activateAccount(a.id);
    expect(AppConfig.cameraId, 'camera-a');
    expect(await AppConfig.loadLanguage(), 'ru');

    await AppConfig.activateAccount(b.id);
    expect(AppConfig.cameraId, 'camera-b');
  });

  test('changing the server re-keys the active account and keeps its prefs', () async {
    final a = AccountRecord.fromUser(
      _user('u1', 'alice'),
      serverUrl: 'http://a.test:3000',
      token: 'tok-a',
    );
    await AppConfig.upsertAccount(a);
    await AppConfig.setCameraId('cam-a');
    await AppConfig.setLanguage('ru');

    await AppConfig.moveActiveAccountToServer('http://new.test:3000/');

    final active = AppConfig.activeAccount!;
    expect(active.serverUrl, 'http://new.test:3000');
    expect(active.id, AccountRecord.keyFor('http://new.test:3000', 'u1'));
    expect(AppConfig.serverUrl, 'http://new.test:3000');
    expect(AppConfig.cameraId, 'cam-a');
    expect(await AppConfig.loadLanguage(), 'ru');
    expect(await AppConfig.loadToken(), 'tok-a');

    await AppConfig.init();
    expect(AppConfig.activeAccountId, active.id);
    expect(AppConfig.cameraId, 'cam-a');
  });

  test('session-only accounts are dropped on the next launch', () async {
    final a = AccountRecord.fromUser(
      _user('u1', 'alice'),
      serverUrl: 'http://a.test:3000',
      token: 'tok-a',
      remember: false,
    );
    await AppConfig.upsertAccount(a);
    expect(AppConfig.accounts.length, 1);

    await AppConfig.init();
    expect(AppConfig.accounts, isEmpty);
    expect(await AppConfig.loadToken(), isNull);
  });
}
