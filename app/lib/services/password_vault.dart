import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One saved password. The whole record (title, username, password, note) is
/// encrypted on disk; nothing here is ever sent to the server.
class VaultEntry {
  const VaultEntry({
    required this.id,
    required this.title,
    required this.username,
    required this.password,
    required this.note,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String username;
  final String password;
  final String note;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
        'title': title,
        'username': username,
        'password': password,
        'note': note,
        'updatedAt': updatedAt,
      };

  factory VaultEntry.fromJson(String id, Map<String, dynamic> json) =>
      VaultEntry(
        id: id,
        title: '${json['title'] ?? ''}',
        username: '${json['username'] ?? ''}',
        password: '${json['password'] ?? ''}',
        note: '${json['note'] ?? ''}',
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

/// Local, client-side password vault.
///
/// Records live in SharedPreferences encrypted with AES-GCM. The key is
/// derived from a dedicated vault passphrase using PBKDF2-HMAC-SHA256, so it
/// is independent of the Enigma app passcode and of the account password:
/// changing either of those never breaks the vault. The server only ever sees
/// bcrypt hashes and cannot recover anything stored here.
///
/// The derived key is held in memory only while the vault is unlocked. Call
/// [lock] when leaving the vault UI.
class PasswordVault {
  PasswordVault({SharedPreferences? prefs}) : _injectedPrefs = prefs;

  static final PasswordVault instance = PasswordVault();

  static const _saltKey = 'commsuite.vault.salt';
  static const _verifierKey = 'commsuite.vault.verifier';
  static const _entriesKey = 'commsuite.vault.entries';

  static const _verifyPlain = 'commsuite.vault.verifier.v1';
  static const _aadVerify = 'commsuite.vault.verify';
  static const _aadEntry = 'commsuite.vault.entry';

  static const _iterations = 100000;
  static const _saltLength = 16;

  static const minPassphraseLength = 8;

  final SharedPreferences? _injectedPrefs;
  SharedPreferences? _cachedPrefs;

  final Random _random = Random.secure();
  SecretKey? _key;

  bool get unlocked => _key != null;

  Future<SharedPreferences> _prefs() async =>
      _cachedPrefs ??= _injectedPrefs ?? await SharedPreferences.getInstance();

  // ---- lifecycle -----------------------------------------------------------

  /// True once a vault has been created on this device.
  Future<bool> hasVault() async {
    final prefs = await _prefs();
    return prefs.containsKey(_saltKey) && prefs.containsKey(_verifierKey);
  }

  /// True when the vault exists and has at least one saved record.
  Future<bool> hasEntries() async {
    final prefs = await _prefs();
    return _readEntries(prefs).isNotEmpty;
  }

  /// Creates a brand-new vault. Throws [ArgumentError] when the passphrase is
  /// too short or a vault already exists.
  Future<void> create(String passphrase) async {
    if (passphrase.length < minPassphraseLength) {
      throw ArgumentError.value(
        passphrase,
        'passphrase',
        'must be at least $minPassphraseLength characters',
      );
    }
    final prefs = await _prefs();
    if (prefs.containsKey(_saltKey) || prefs.containsKey(_verifierKey)) {
      throw StateError('vault already exists');
    }
    final salt = _randomBytes(_saltLength);
    final key = await _deriveKey(passphrase, salt);
    final verifier = await _encrypt(key, _verifyPlain, _aadVerify);
    await prefs.setString(_saltKey, base64Encode(salt));
    await prefs.setString(_verifierKey, _encodeBox(verifier));
    await prefs.setString(_entriesKey, '{}');
    _key = key;
  }

  /// Derives the key and checks it against the stored verifier.
  Future<bool> unlock(String passphrase) async {
    final prefs = await _prefs();
    final salt = prefs.getString(_saltKey);
    final verifier = prefs.getString(_verifierKey);
    if (salt == null || verifier == null) return false;
    final key = await _deriveKey(passphrase, base64Decode(salt));
    try {
      final plain = await _decrypt(
        key,
        _decodeBox(jsonDecode(verifier) as Map<String, dynamic>),
        _aadVerify,
      );
      if (plain != _verifyPlain) return false;
    } catch (_) {
      return false;
    }
    _key = key;
    return true;
  }

  /// Forgets the in-memory key. Records stay encrypted on disk.
  void lock() {
    _key = null;
  }

  /// Removes every vault key and locks. This cannot be undone.
  Future<void> clear() async {
    final prefs = await _prefs();
    await prefs.remove(_saltKey);
    await prefs.remove(_verifierKey);
    await prefs.remove(_entriesKey);
    _key = null;
  }

  // ---- records -------------------------------------------------------------

  /// Decrypts all records, sorted by title. Throws [StateError] when locked.
  Future<List<VaultEntry>> entries() async {
    final key = _key;
    if (key == null) throw StateError('vault is locked');
    final prefs = await _prefs();
    final raw = _readEntries(prefs);
    final out = <VaultEntry>[];
    for (final item in raw.entries) {
      try {
        final box = _decodeBox(jsonDecode(item.value) as Map<String, dynamic>);
        final plain = await _decrypt(key, box, _aadEntry);
        out.add(
          VaultEntry.fromJson(
            item.key,
            jsonDecode(plain) as Map<String, dynamic>,
          ),
        );
      } catch (_) {
        // A record encrypted with another key (or corrupted) is skipped
        // instead of blocking the whole list.
      }
    }
    out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return out;
  }

  /// Creates or updates a record. [id] must match an existing record when
  /// editing. Throws [StateError] when locked.
  Future<VaultEntry> save({
    String? id,
    required String title,
    required String username,
    required String password,
    String note = '',
  }) async {
    final key = _key;
    if (key == null) throw StateError('vault is locked');
    final prefs = await _prefs();
    final raw = _readEntries(prefs);
    final recordId = id ?? _newId();
    final entry = VaultEntry(
      id: recordId,
      title: title.trim().isEmpty ? username.trim() : title.trim(),
      username: username.trim(),
      password: password,
      note: note.trim(),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final box = await _encrypt(key, jsonEncode(entry.toJson()), _aadEntry);
    raw[recordId] = _encodeBox(box);
    await prefs.setString(_entriesKey, jsonEncode(raw));
    return entry;
  }

  Future<void> remove(String id) async {
    final prefs = await _prefs();
    final raw = _readEntries(prefs);
    if (raw.remove(id) != null) {
      await prefs.setString(_entriesKey, jsonEncode(raw));
    }
  }

  /// Re-encrypts every record under a new passphrase. Returns false when the
  /// current passphrase is wrong or there is no vault.
  Future<bool> changePassphrase({
    required String current,
    required String next,
  }) async {
    if (next.length < minPassphraseLength) return false;
    if (!await unlock(current)) return false;
    final key = _key;
    if (key == null) return false;
    final prefs = await _prefs();
    final raw = _readEntries(prefs);
    final plain = <String, String>{};
    for (final item in raw.entries) {
      try {
        final box = _decodeBox(jsonDecode(item.value) as Map<String, dynamic>);
        plain[item.key] = await _decrypt(key, box, _aadEntry);
      } catch (_) {
        // Leave records this key cannot read out of the migrated set.
      }
    }
    final salt = _randomBytes(_saltLength);
    final newKey = await _deriveKey(next, salt);
    final verifier = await _encrypt(newKey, _verifyPlain, _aadVerify);
    final enc = <String, String>{};
    for (final item in plain.entries) {
      final box = await _encrypt(newKey, item.value, _aadEntry);
      enc[item.key] = _encodeBox(box);
    }
    await prefs.setString(_saltKey, base64Encode(salt));
    await prefs.setString(_verifierKey, _encodeBox(verifier));
    await prefs.setString(_entriesKey, jsonEncode(enc));
    _key = newKey;
    return true;
  }

  // ---- crypto helpers ------------------------------------------------------

  Future<SecretKey> _deriveKey(String passphrase, List<int> salt) {
    final pbkdf2 = Pbkdf2.hmacSha256(
      iterations: _iterations,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  Future<SecretBox> _encrypt(
    SecretKey key,
    String plain,
    String aad,
  ) {
    final aes = AesGcm.with256bits();
    return aes.encrypt(
      utf8.encode(plain),
      secretKey: key,
      aad: utf8.encode(aad),
    );
  }

  Future<String> _decrypt(
    SecretKey key,
    SecretBox box,
    String aad,
  ) async {
    final aes = AesGcm.with256bits();
    final bytes = await aes.decrypt(
      box,
      secretKey: key,
      aad: utf8.encode(aad),
    );
    return utf8.decode(bytes);
  }

  Map<String, String> _readEntries(SharedPreferences prefs) {
    final raw = prefs.getString(_entriesKey);
    if (raw == null || raw.trim().isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return {
        for (final item in decoded.entries)
          '${item.key}': '${item.value}',
      };
    } catch (_) {
      return <String, String>{};
    }
  }

  List<int> _randomBytes(int length) =>
      List<int>.generate(length, (_) => _random.nextInt(256));

  String _newId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final extra = _random.nextInt(1 << 32).toRadixString(36);
    return '$now-$extra';
  }

  String _encodeBox(SecretBox box) => jsonEncode({
        'n': base64Encode(box.nonce),
        'c': base64Encode(box.cipherText),
        'm': base64Encode(box.mac.bytes),
      });

  SecretBox _decodeBox(Map<String, dynamic> json) => SecretBox(
        base64Decode('${json['c'] ?? ''}'),
        nonce: base64Decode('${json['n'] ?? ''}'),
        mac: Mac(base64Decode('${json['m'] ?? ''}')),
      );
}
