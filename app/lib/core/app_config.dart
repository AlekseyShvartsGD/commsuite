import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static const _urlKey = 'commsuite.server_url';
  static const _tokenKey = 'commsuite.token';
  static const _turnHostKey = 'commsuite.turn_host';
  static const _turnPortKey = 'commsuite.turn_port';
  static const _turnUserKey = 'commsuite.turn_user';
  static const _turnPassKey = 'commsuite.turn_pass';
  static const _rememberKey = 'commsuite.remember_me';
  static const _vtKeyKey = 'commsuite.vtkey';
  static const _vtProxyKey = 'commsuite.vtproxy';
  static const _langKey = 'commsuite.lang';
  static String _serverUrl = '';
  static String _turnHost = '';
  static int _turnPort = 0;
  static String _turnUser = '';
  static String _turnPass = '';
  static bool _rememberMe = true;
  static bool _loaded = false;

  static String get serverUrl => _serverUrl;
  static String get apiBase => '$_serverUrl/api';

  static bool get turnEnabled =>
      _turnHost.isNotEmpty && _turnPort > 0 && _turnUser.isNotEmpty && _turnPass.isNotEmpty;
  static String get turnHost => _turnHost;
  static int get turnPort => _turnPort;
  static String get turnUser => _turnUser;
  static String get turnPass => _turnPass;

  /// RTCConfiguration for WebRTC calls.
  /// With a TURN relay configured, all ICE is forced through it (TCP-only
  /// networks where direct UDP paths do not exist); otherwise plain STUN.
  static Map<String, dynamic> callIceConfig() {
    if (turnEnabled) {
      return {
        'iceServers': [
          {
            'urls': ['turn:$_turnHost:$_turnPort?transport=tcp'],
            'username': _turnUser,
            'credential': _turnPass,
          },
        ],
        'iceTransportPolicy': 'relay',
      };
    }
    return {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ],
    };
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
    _serverUrl = prefs.getString(_urlKey) ?? _defaultUrl();
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
    _loaded = true;
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

  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  static Future<String?> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  static Future<void> clearToken() async {
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
  static Future<String> loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_langKey);
    if (saved != null && (saved == 'en' || saved == 'ru')) return saved;
    return PlatformDispatcher.instance.locale.languageCode == 'ru' ? 'ru' : 'en';
  }

  static Future<void> setLanguage(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_langKey, code);
  }

  static String _defaultUrl() {
    if (!kIsWeb && Platform.isAndroid) {
      return 'https://immutably-undamaged-tortoise.cloudpub.ru';
    }
    return 'http://localhost:3000';
  }
}