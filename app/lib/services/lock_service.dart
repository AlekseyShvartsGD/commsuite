import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/enigma.dart';

class LockService extends ChangeNotifier {
  LockService._();

  static final LockService instance = LockService._();

  static const _enabledKey = 'commsuite.lock.enabled';
  static const _secretKey = 'commsuite.lock.secret';
  static const _chatsKey = 'commsuite.lock.chats';

  final LocalAuthentication _auth = LocalAuthentication();

  bool _enabled = false;
  bool _loaded = false;
  bool _unlocked = true;
  String? _secret;
  final Set<String> _lockedChats = {};
  final Set<String> _sessionUnlockedChats = {};

  bool get loaded => _loaded;
  bool get enabled => _enabled;
  bool get locked => _enabled && !_unlocked;
  bool get hasPasscode => (_secret ?? '').isNotEmpty;
  bool get biometricSupported => !kIsWeb && Platform.isAndroid;
  Set<String> get lockedChats => Set.unmodifiable(_lockedChats);

  static bool validPasscode(String value) =>
      RegExp(r'^[A-Za-z]+$').hasMatch(value.trim());

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? false;
    _secret = prefs.getString(_secretKey);
    _lockedChats
      ..clear()
      ..addAll(prefs.getStringList(_chatsKey) ?? const <String>[]);
    _unlocked = !_enabled;
    _loaded = true;
    notifyListeners();
  }

  bool verifyPasscode(String passcode) {
    final secret = _secret;
    final value = passcode.trim();
    if (secret == null || value.isEmpty) return false;
    return enigmaEncrypt(value) == secret;
  }

  /// Sets/replaces the passcode. App-lock at launch stays a separate switch.
  Future<void> setPasscode(String passcode) async {
    _secret = enigmaEncrypt(passcode.trim());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_secretKey, _secret!);
    _unlocked = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (value && !hasPasscode) return;
    final prefs = await SharedPreferences.getInstance();
    _enabled = value;
    _unlocked = true;
    await prefs.setBool(_enabledKey, value);
    notifyListeners();
  }

  Future<bool> authenticateBiometric() async {
    if (!biometricSupported) return false;
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock Commsuite',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  void markUnlocked() {
    if (_unlocked) return;
    _unlocked = true;
    notifyListeners();
  }

  void lockNow() {
    if (!_enabled || !_unlocked) return;
    _unlocked = false;
    _sessionUnlockedChats.clear();
    notifyListeners();
  }

  bool isChatLocked(String id) => _lockedChats.contains(id);
  bool chatNeedsUnlock(String id) =>
      hasPasscode && _lockedChats.contains(id) && !_sessionUnlockedChats.contains(id);

  Future<void> toggleChatLock(String id) async {
    if (_lockedChats.contains(id)) {
      _lockedChats.remove(id);
      _sessionUnlockedChats.remove(id);
    } else {
      _lockedChats.add(id);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_chatsKey, _lockedChats.toList());
    notifyListeners();
  }

  void grantChatAccess(String id) {
    if (!_lockedChats.contains(id)) return;
    if (_sessionUnlockedChats.add(id)) notifyListeners();
  }
}
