import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'account.dart';

class AppConfig {
  static const _urlKey = 'commsuite.server_url';
  static const _tokenKey = 'commsuite.token';
  static const _accountsKey = 'commsuite.accounts';
  static const _activeAccountKey = 'commsuite.active_account';
  static const _turnHostKey = 'commsuite.turn_host';
  static const _turnPortKey = 'commsuite.turn_port';
  static const _turnUserKey = 'commsuite.turn_user';
  static const _turnPassKey = 'commsuite.turn_pass';
  static const _rememberKey = 'commsuite.remember_me';
  static const _vtKeyKey = 'commsuite.vtkey';
  static const _vtProxyKey = 'commsuite.vtproxy';
  static const _langKey = 'commsuite.lang';
  static const _cameraIdKey = 'commsuite.camera_id';
  static const _micIdKey = 'commsuite.mic_id';
  static String _serverUrl = '';
  static String _turnHost = '';
  static int _turnPort = 0;
  static String _turnUser = '';
  static String _turnPass = '';
  static bool _rememberMe = true;
  static bool _loaded = false;
  static String _cameraId = '';
  static String _micId = '';
  static List<AccountRecord> _accounts = <AccountRecord>[];
  static String? _activeId;

  static String get serverUrl => _serverUrl;
  static String get apiBase => '$_serverUrl/api';

  /// Saved accounts, most recently used first.
  static List<AccountRecord> get accounts => List.unmodifiable(_accounts);

  static AccountRecord? get activeAccount {
    final id = _activeId;
    if (id == null) return null;
    for (final a in _accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  static String? get activeAccountId => _activeId;

  static AccountRecord? accountById(String id) {
    for (final a in _accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Most recent account that is not [id], used when removing the active one.
  static AccountRecord? _nextAccount(String? exclude) {
    AccountRecord? best;
    for (final a in _accounts) {
      if (a.id == exclude) continue;
      if (best == null || a.lastUsedAt > best.lastUsedAt) best = a;
    }
    return best;
  }

  static bool get turnEnabled =>
      _turnHost.isNotEmpty && _turnPort > 0 && _turnUser.isNotEmpty && _turnPass.isNotEmpty;
  static String get turnHost => _turnHost;
  static int get turnPort => _turnPort;
  static String get turnUser => _turnUser;
  static String get turnPass => _turnPass;

  /// Exactly which capture devices calls use. Empty means "system default".
  static String get cameraId => _cameraId;
  static String get micId => _micId;

  /// Extra RTCConfiguration keys applied to every call. On Android the
  /// CPU-overuse detector is disabled: its `FrameProcessingTimes` sampling
  /// trips a libwebrtc `Check failed: time >= last_data_point.time` (SIGABRT on
  /// the VideoEncoderQueue thread) when the software encoder is reconfigured
  /// mid-stream, which is what kills the app on emulators/constrained devices.
  static Map<String, dynamic> get _callTweaks =>
      Platform.isAndroid ? const {'enableCpuOveruseDetection': false} : const {};

  /// RTCConfiguration for WebRTC calls.
  /// With a TURN relay configured, all ICE is forced through it; both UDP and
  /// TCP relay transport URLs are offered so a call still connects on networks
  /// that filter UDP (e.g. an Android emulator). Otherwise plain STUN.
  static Map<String, dynamic> callIceConfig() {
    if (turnEnabled) {
      return {
        'iceServers': [
          {
            'urls': [
              'turn:$_turnHost:$_turnPort?transport=udp',
              'turn:$_turnHost:$_turnPort?transport=tcp',
            ],
            'username': _turnUser,
            'credential': _turnPass,
          },
        ],
        'iceTransportPolicy': 'relay',
        ..._callTweaks,
      };
    }
    return {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ],
      ..._callTweaks,
    };
  }

  /// RTCConfiguration for calls. Prefers short-lived TURN credentials issued by
  /// the server (GET /api/turn, Cloudflare Realtime TURN) so calls connect even
  /// behind carrier-grade NAT; falls back to the manually configured TURN, then
  /// plain STUN.
  static Future<Map<String, dynamic>> fetchIceConfig() async {
    try {
      final token = await loadToken();
      if (_serverUrl.isNotEmpty && token != null && token.isNotEmpty) {
        final resp = await http
            .get(Uri.parse('$apiBase/turn'), headers: {'Authorization': 'Bearer $token'})
            .timeout(const Duration(seconds: 8));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          final servers = data['iceServers'];
          if (servers is List && servers.isNotEmpty) {
            return {
              'iceServers': servers,
              'iceTransportPolicy': 'relay',
              ..._callTweaks,
            };
          }
        }
      }
    } catch (_) {
      // Server unreachable or TURN not configured: use the local fallback.
    }
    return callIceConfig();
  }

  static String get wsUrl => wsUrlWithToken(null);

  static String wsUrlWithToken(String? token) {
    final u = Uri.parse(_serverUrl);
    final scheme = u.scheme == 'https' ? 'wss' : 'ws';
    final port = (u.hasPort && u.port != 0) ? u.port : (scheme == 'wss' ? 443 : 80);
    final base = '$scheme://${u.host}:$port/ws';
    return token == null ? base : '$base?token=$token';
  }

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _accounts = _decodeAccounts(prefs.getString(_accountsKey));
    // "Remember me" was off: those sessions live for this run only.
    final beforeDrop = _accounts.length;
    _accounts.removeWhere((a) => !a.remember);
    final dropped = _accounts.length != beforeDrop;
    _activeId = prefs.getString(_activeAccountKey);
    if (_activeId == null || accountById(_activeId!) == null) {
      _activeId = _nextAccount(null)?.id;
    }
    final active = activeAccount;
    _serverUrl = active?.serverUrl ?? prefs.getString(_urlKey) ?? _defaultUrl();
    if (_serverUrl.endsWith('/')) {
      _serverUrl = _serverUrl.substring(0, _serverUrl.length - 1);
    }
    // A stray ":0" port (bad legacy entry) breaks all WS/HTTP traffic;
    // normalize it away so the default port is used instead.
    if (Uri.tryParse(_serverUrl)?.hasPort == true &&
        Uri.parse(_serverUrl).port == 0) {
      _serverUrl = _serverUrl.substring(0, _serverUrl.length - 2);
    }
    _turnHost = prefs.getString(_turnHostKey) ?? '';
    _turnPort = prefs.getInt(_turnPortKey) ?? 0;
    _turnUser = prefs.getString(_turnUserKey) ?? '';
    _turnPass = prefs.getString(_turnPassKey) ?? '';
    _rememberMe = prefs.getBool(_rememberKey) ?? true;
    _cameraId = _readScoped(prefs, _cameraIdKey);
    _micId = _readScoped(prefs, _micIdKey);
    _loaded = true;
    if (dropped) await _persistAccounts(); // forget session-only tokens
  }

  static bool get rememberMe => _loaded ? _rememberMe : true;

  static Future<void> setRememberMe(bool value) async {
    _rememberMe = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_rememberKey, value);
  }

  static Future<void> setServerUrl(String url) async {
    var clean = url.trim();
    while (clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    if (!clean.startsWith('http://') && !clean.startsWith('https://')) {
      clean = 'http://$clean';
    }
    _serverUrl = clean;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, _serverUrl);
  }

  static Future<void> setTurn({
    required String host,
    required int port,
    required String user,
    required String pass,
  }) async {
    _turnHost = host.trim();
    _turnPort = port;
    _turnUser = user.trim();
    _turnPass = pass.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_turnHostKey, _turnHost);
    await prefs.setInt(_turnPortKey, _turnPort);
    await prefs.setString(_turnUserKey, _turnUser);
    await prefs.setString(_turnPassKey, _turnPass);
  }

  static Future<void> clearTurn() async {
    _turnHost = '';
    _turnPort = 0;
    _turnUser = '';
    _turnPass = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_turnHostKey);
    await prefs.remove(_turnPortKey);
    await prefs.remove(_turnUserKey);
    await prefs.remove(_turnPassKey);
  }

  static Future<void> setCameraId(String id) async {
    _cameraId = id.trim();
    final prefs = await SharedPreferences.getInstance();
    final key = _scoped(_cameraIdKey);
    if (_cameraId.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, _cameraId);
    }
  }

  static Future<void> setMicId(String id) async {
    _micId = id.trim();
    final prefs = await SharedPreferences.getInstance();
    final key = _scoped(_micIdKey);
    if (_micId.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, _micId);
    }
  }

  // ---- accounts -----------------------------------------------------------

  static List<AccountRecord> _decodeAccounts(String? raw) {
    if (raw == null || raw.isEmpty) return <AccountRecord>[];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return <AccountRecord>[];
      return list
          .whereType<Map>()
          .map((e) => AccountRecord.fromJson(Map<String, dynamic>.from(e)))
          .where((a) => a.id.isNotEmpty && a.userId.isNotEmpty)
          .toList();
    } catch (_) {
      return <AccountRecord>[];
    }
  }

  static Future<void> _persistAccounts() async {
    _accounts.sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _accountsKey,
      jsonEncode(_accounts.map((a) => a.toJson()).toList()),
    );
    final id = _activeId;
    if (id == null) {
      await prefs.remove(_activeAccountKey);
    } else {
      await prefs.setString(_activeAccountKey, id);
    }
  }

  /// Adds or updates [account]. Makes it active unless [activate] is false.
  static Future<void> upsertAccount(
    AccountRecord account, {
    bool activate = true,
  }) async {
    final idx = _accounts.indexWhere((a) => a.id == account.id);
    if (idx >= 0) {
      _accounts[idx] = account;
    } else {
      _accounts.add(account);
    }
    if (activate) {
      account.touch();
      _activeId = account.id;
      await setServerUrl(account.serverUrl);
      _cameraId = await _loadScoped(_cameraIdKey);
      _micId = await _loadScoped(_micIdKey);
    }
    await _persistAccounts();
  }

  /// Keeps the active entry in sync with the identity the server reports.
  static Future<void> confirmAccount(User user, String token) async {
    final active = activeAccount;
    if (active == null) {
      await upsertAccount(
        AccountRecord.fromUser(
          user,
          serverUrl: _serverUrl,
          token: token,
          remember: _rememberMe,
        ),
      );
      return;
    }
    active
      ..username = user.username
      ..displayName = user.displayName
      ..verified = user.isVerified
      ..token = token;
    await _persistAccounts();
  }

  /// Upgrades the old single-token install: the saved token becomes the first
  /// account once its identity is known.
  static Future<void> adoptLegacyToken(User user, String token) async {
    if (_activeId != null) {
      await confirmAccount(user, token);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await upsertAccount(
      AccountRecord.fromUser(
        user,
        serverUrl: _serverUrl,
        token: token,
        remember: _rememberMe,
      ),
    );
    await prefs.remove(_tokenKey);
  }

  static Future<void> activateAccount(String id) async {
    final account = accountById(id);
    if (account == null) return;
    account.touch();
    _activeId = account.id;
    await setServerUrl(account.serverUrl);
    _cameraId = await _loadScoped(_cameraIdKey);
    _micId = await _loadScoped(_micIdKey);
    await _persistAccounts();
  }

  /// Removes [id]. If it was active, the most recently used remaining account
  /// becomes active (or none, when it was the last one).
  static Future<void> removeAccount(String id) async {
    final wasActive = _activeId == id;
    _accounts.removeWhere((a) => a.id == id);
    if (wasActive) {
      final next = _nextAccount(null);
      _activeId = next?.id;
      if (next != null) {
        await setServerUrl(next.serverUrl);
        _cameraId = await _loadScoped(_cameraIdKey);
        _micId = await _loadScoped(_micIdKey);
      }
    }
    await _persistAccounts();
  }

  static Future<void> setAccountUnread(String id, int unread) async {
    final account = accountById(id);
    if (account == null || account.unread == unread) return;
    account.unread = unread < 0 ? 0 : unread;
    await _persistAccounts();
  }

  /// Keeps the active account pointing at [url] when the server address is
  /// edited in Settings (same account, possibly a new host/port). Re-keys the
  /// entry so switching back still resolves it.
  static Future<void> moveActiveAccountToServer(String url) async {
    final active = activeAccount;
    if (active == null) return;
    final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (clean.isEmpty) return;
    if (clean == active.serverUrl) {
      await setServerUrl(clean);
      return;
    }
    await setServerUrl(clean);
    final newId = AccountRecord.keyFor(clean, active.userId);
    final moved = AccountRecord(
      id: newId,
      userId: active.userId,
      username: active.username,
      displayName: active.displayName,
      serverUrl: clean,
      token: active.token,
      verified: active.verified,
      remember: active.remember,
      unread: active.unread,
      lastUsedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _accounts.removeWhere((a) => a.id == active.id || a.id == newId);
    _accounts.add(moved);
    _activeId = newId;
    await _migrateScoped(active.id, newId);
    await _persistAccounts();
  }

  /// Carries the per-account preferences over when the active account is
  /// re-keyed to a new server address.
  static Future<void> _migrateScoped(String fromId, String toId) async {
    if (fromId == toId) return;
    final prefs = await SharedPreferences.getInstance();
    for (final key in [_langKey, _cameraIdKey, _micIdKey]) {
      final from = 'commsuite.acct.${_safeId(fromId)}.$key';
      final value = prefs.getString(from);
      if (value == null) continue;
      await prefs.setString('commsuite.acct.${_safeId(toId)}.$key', value);
      await prefs.remove(from);
    }
  }

  static Future<void> saveToken(String token) async {
    final active = activeAccount;
    if (active != null) {
      active.token = token;
      await _persistAccounts();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  static Future<String?> loadToken() async {
    final active = activeAccount;
    if (active != null) {
      return active.token.isEmpty ? null : active.token;
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  static Future<void> clearToken() async {
    final active = activeAccount;
    if (active != null) {
      active.token = '';
      await _persistAccounts();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  static Future<String?> loadVirusTotalKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_vtKeyKey);
  }

  static Future<void> setVirusTotalKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_vtKeyKey, key.trim());
  }

  /// Optional proxy for VirusTotal requests: `host:port` (HTTP) or
  /// `socks5://host:port`. Empty means direct.
  static Future<String> loadVirusTotalProxy() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_vtProxyKey) ?? '';
  }

  static Future<void> setVirusTotalProxy(String proxy) async {
    final prefs = await SharedPreferences.getInstance();
    final value = proxy.trim();
    if (value.isEmpty) {
      await prefs.remove(_vtProxyKey);
    } else {
      await prefs.setString(_vtProxyKey, value);
    }
  }

  /// Persisted UI language code; on first run the OS locale is used.
  /// Each account remembers its own language.
  static Future<String> loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_scoped(_langKey)) ?? prefs.getString(_langKey);
    if (saved != null && (saved == 'en' || saved == 'ru')) return saved;
    return PlatformDispatcher.instance.locale.languageCode == 'ru' ? 'ru' : 'en';
  }

  static Future<void> setLanguage(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_scoped(_langKey), code);
    // Also keep the global default so a new account starts in this language.
    await prefs.setString(_langKey, code);
  }

  /// Per-account preference key. The active account's value wins; the
  /// unscoped key remains as a fallback for installs upgrading from 1.0.40.
  static String _safeId(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');

  static String _scoped(String key) {
    final id = _activeId;
    if (id == null || id.isEmpty) return key;
    return 'commsuite.acct.${_safeId(id)}.$key';
  }

  static String _readScoped(SharedPreferences prefs, String key) =>
      prefs.getString(_scoped(key)) ?? prefs.getString(key) ?? '';

  static Future<String> _loadScoped(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return _readScoped(prefs, key);
  }

  static String _defaultUrl() {
    if (!kIsWeb && Platform.isAndroid) {
      return 'https://immutably-undamaged-tortoise.cloudpub.ru';
    }
    return 'http://localhost:3000';
  }
}