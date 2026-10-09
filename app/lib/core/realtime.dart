import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'localizations.dart';

class RealtimeChannel {
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();
  final ValueNotifier<bool> connected = ValueNotifier(false);
  final ValueNotifier<String> status = ValueNotifier(
    L.t('offline', ru: 'не в сети'),
  );

  Stream<Map<String, dynamic>> get events => _controller.stream;

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  Timer? _watchdog;
  String? _url;
  int _attempt = 0;
  bool _closed = true;
  StreamSubscription? _sub;
  DateTime _lastActivity = DateTime.fromMillisecondsSinceEpoch(0);

  void connect(String url) {
    disconnect();
    _closed = false;
    _url = url;
    status.value = 'connecting';
    _open();
  }

  void disconnect() {
    _closed = true;
    _attempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    connected.value = false;
    status.value = L.t('offline', ru: 'не в сети');
  }

  Future<void> _open() async {
    if (_closed || _url == null) return;
    status.value = 'connecting';
    _channel = null;
    try {
      final channel = WebSocketChannel.connect(Uri.parse(_url!));
      _channel = channel;
      // Wait for the handshake to actually complete. Until then the server is
      // still booting (~10-20 s) and the upgrade failure must NOT surface as an
      // unhandled error — it simply schedules a reconnect.
      await channel.ready;
      if (_closed) {
        try {
          await channel.sink.close();
        } catch (_) {}
        return;
      }
      _attempt = 0;
      _lastActivity = DateTime.now();
      connected.value = true;
      status.value = 'online';
      _startWatchdog();
      _sub = channel.stream.listen(
        (data) {
          _lastActivity = DateTime.now();
          try {
            final m = jsonDecode(data as String);
            if (m is Map<String, dynamic>) _controller.add(m);
          } catch (_) {}
        },
        onError: (Object e) {
          connected.value = false;
          _scheduleReconnect();
        },
        onDone: () {
          connected.value = false;
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  /// While the process is alive, any socket that stops acknowledging traffic
  /// (e.g. wedged after the OS suspended the network) is force-reconnected.
  /// Pings arrive every 25 s, so 30 s of silence means the socket is dead even
  /// though the OS never delivered an onDone/onError.
  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_closed || !connected.value) {
        _watchdog?.cancel();
        _watchdog = null;
        return;
      }
      if (DateTime.now().difference(_lastActivity).inSeconds > 30) {
        connected.value = false;
        status.value = L.t(
          'reconnecting (stale socket)',
          ru: 'переподключение (сокет не отвечает)',
        );
        _sub?.cancel();
        _sub = null;
        try {
          _channel?.sink.close();
        } catch (_) {}
        _channel = null;
        _scheduleReconnect();
      }
    });
  }

  void _scheduleReconnect() {
    if (_closed || _reconnectTimer != null) return;
    _attempt = math.min(_attempt + 1, 6);
    final delay = math.min(math.pow(2, _attempt).toInt(), 30);
    status.value = L.t(
      'reconnecting in ${delay}s',
      ru: 'переподключение через $delay с',
    );
    connected.value = false;
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      _reconnectTimer = null;
      _open();
    });
  }

  void send(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null || !connected.value) return;
    try {
      channel.sink.add(jsonEncode(message));
    } catch (_) {}
  }

  void dispose() {
    disconnect();
    _controller.close();
  }
}
