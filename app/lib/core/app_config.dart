import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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

  static String get serverUrl => _serverUrl;
  static String get apiBase => '$_serverUrl/api';

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
    _cameraId = prefs.getString(_cameraIdKey) ?? '';
    _micId = prefs.getString(_micIdKey) ?? '';
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

  static Future<void> setCameraId(String id) async {
    _cameraId = id.trim();
    final prefs = await SharedPreferences.getInstance();
    if (_cameraId.isEmpty) {
      await prefs.remove(_cameraIdKey);
    } else {
      await prefs.setString(_cameraIdKey, _cameraId);
    }
  }

  static Future<void> setMicId(String id) async {
    _micId = id.trim();
    final prefs = await SharedPreferences.getInstance();
    if (_micId.isEmpty) {
      await prefs.remove(_micIdKey);
    } else {
      await prefs.setString(_micIdKey, _micId);
    }
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