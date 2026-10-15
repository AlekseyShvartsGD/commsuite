import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/app_config.dart';

/// Learns the server's current public address when the saved one stops
/// answering.
///
/// The CloudPub tunnel is handed a random `*.cloudpub.ru` subdomain, so the
/// address baked into a build (and the one a user typed once) eventually goes
/// stale. After every publish the host machine uploads the live URL to a tiny
/// public pointer file; here we fetch it only when the configured server is
/// unreachable, so a normal launch never waits on the network.
class ServerDiscovery {
  ServerDiscovery._();
  static final ServerDiscovery instance = ServerDiscovery._();

  static const _pointer =
      'https://raw.githubusercontent.com/AlekseyShvartsGD/commsuite/main/public-url.json';

  static const _cooldown = Duration(seconds: 60);

  bool _running = false;
  DateTime? _lastAttempt;

  /// Resolves the current server address. Safe to call repeatedly: attempts
  /// are serialized and rate-limited, and a resolved address is persisted by
  /// [AppConfig.setServerUrl].
  void start() {
    if (_running) return;
    final now = DateTime.now();
    if (_lastAttempt != null && now.difference(_lastAttempt!) < _cooldown) {
      return;
    }
    _lastAttempt = now;
    _running = true;
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    try {
      // A loopback server (the Windows default) is never replaced by the
      // public tunnel: the desktop app talks to the local stack directly.
      if (isLoopback(AppConfig.serverUrl)) return;
      if (await _healthy(AppConfig.serverUrl)) return;
      final discovered = await _fetchPointer();
      if (discovered == null || discovered == AppConfig.serverUrl) return;
      if (!await _healthy(discovered)) return;
      await AppConfig.setServerUrl(discovered);
    } catch (_) {
      // Best-effort: a failure just leaves the saved address untouched.
    } finally {
      _running = false;
    }
  }

  static bool isLoopback(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  Future<String?> _fetchPointer() async {
    try {
      final resp = await http
          .get(Uri.parse(_pointer))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final url = (json['url'] as String? ?? '').trim();
      if (url.startsWith('http://') || url.startsWith('https://')) return url;
    } catch (_) {}
    return null;
  }

  Future<bool> _healthy(String url) async {
    if (url.isEmpty) return false;
    try {
      final res = await http
          .get(Uri.parse('$url/health'))
          .timeout(const Duration(seconds: 5));
      return res.statusCode >= 200 && res.statusCode < 500;
    } catch (_) {
      return false;
    }
  }
}
