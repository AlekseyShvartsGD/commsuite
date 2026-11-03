import 'package:commsuite/services/password_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('creates a vault and verifies the passphrase', () async {
    final vault = PasswordVault();
    expect(await vault.hasVault(), isFalse);

    await vault.create('correct horse');
    expect(await vault.hasVault(), isTrue);
    expect(vault.unlocked, isTrue);

    vault.lock();
    expect(vault.unlocked, isFalse);
    expect(await vault.unlock('wrong passphrase'), isFalse);
    expect(vault.unlocked, isFalse);
    expect(await vault.unlock('correct horse'), isTrue);
    expect(vault.unlocked, isTrue);
  });

  test('rejects a short passphrase when creating', () async {
    final vault = PasswordVault();
    await expectLater(vault.create('short'), throwsArgumentError);
    expect(await vault.hasVault(), isFalse);

    await vault.create('12345678');
    await expectLater(vault.create('another one'), throwsStateError);
  });

  test('stores entries encrypted and reads them back', () async {
    final vault = PasswordVault();
    await vault.create('correct horse');
    await vault.save(
      title: 'Commsuite account',
      username: 'alice',
      password: 's3cret-password',
      note: 'main',
    );
    await vault.save(
      title: 'Email',
      username: 'alice@example.com',
      password: 'mail-password',
    );

    final prefs = await SharedPreferences.getInstance();
    final onDisk = prefs.getString('commsuite.vault.entries') ?? '';
    expect(onDisk, isNot(contains('s3cret-password')));
    expect(onDisk, isNot(contains('mail-password')));
    expect(onDisk, isNot(contains('alice@example.com')));

    final entries = await vault.entries();
    expect(entries.length, 2);
    expect(entries.first.title, 'Commsuite account');
    expect(entries.first.username, 'alice');
    expect(entries.first.password, 's3cret-password');
    expect(entries.last.title, 'Email');

    // A fresh instance still decrypts the same records.
    final reopened = PasswordVault();
    expect(await reopened.unlock('correct horse'), isTrue);
    final again = await reopened.entries();
    expect(again.map((e) => e.password), contains('mail-password'));
  });

  test('updates and removes records', () async {
    final vault = PasswordVault();
    await vault.create('correct horse');
    final saved = await vault.save(
      title: 'Email',
      username: 'alice',
      password: 'old',
    );
    await vault.save(
      id: saved.id,
      title: 'Email',
      username: 'alice',
      password: 'new',
    );
    expect((await vault.entries()).single.password, 'new');

    await vault.remove(saved.id);
    expect(await vault.entries(), isEmpty);
  });

  test('rekeys every record when the passphrase changes', () async {
    final vault = PasswordVault();
    await vault.create('correct horse');
    await vault.save(
      title: 'Email',
      username: 'alice',
      password: 'mail-password',
    );

    expect(
      await vault.changePassphrase(current: 'nope', next: 'new passphrase'),
      isFalse,
    );
    expect(
      await vault.changePassphrase(
        current: 'correct horse',
        next: 'new passphrase',
      ),
      isTrue,
    );

    vault.lock();
    expect(await vault.unlock('correct horse'), isFalse);
    expect(await vault.unlock('new passphrase'), isTrue);
    final entries = await vault.entries();
    expect(entries.single.password, 'mail-password');
  });

  test('clear destroys the vault', () async {
    final vault = PasswordVault();
    await vault.create('correct horse');
    await vault.save(title: 'x', username: 'x', password: 'x');
    await vault.clear();

    expect(await vault.hasVault(), isFalse);
    expect(vault.unlocked, isFalse);
    expect(await vault.hasEntries(), isFalse);
  });

  test('entries() refuses to run while locked', () async {
    final vault = PasswordVault();
    await vault.create('correct horse');
    vault.lock();
    await expectLater(vault.entries(), throwsStateError);
  });
}
