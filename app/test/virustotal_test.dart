import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:commsuite/services/virustotal.dart';
import 'package:flutter_test/flutter_test.dart';

/// Buffered reader (a dart:io socket stream can only be listened to once).
class _BufReader {
  _BufReader(this._socket) {
    _socket.listen(
      (chunk) {
        _buffer.addAll(chunk);
        _wake();
      },
      onError: (Object _) => _wake(),
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  final Stream<List<int>> _socket;
  final List<int> _buffer = <int>[];
  Completer<void>? _pending;
  bool _done = false;

  void _wake() {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      _pending = null;
      pending.complete();
    }
  }

  Future<List<int>> read(int count) async {
    while (_buffer.length < count) {
      if (_done) throw StateError('short read');
      _pending = Completer<void>();
      await _pending!.future;
    }
    final out = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return out;
  }

  Future<String> readUntil(String marker) async {
    while (!utf8.decode(_buffer, allowMalformed: true).contains(marker)) {
      if (_done) throw StateError('short read');
      _pending = Completer<void>();
      await _pending!.future;
    }
    final text = utf8.decode(_buffer, allowMalformed: true);
    final at = text.indexOf(marker) + marker.length;
    final out = text.substring(0, at);
    _buffer.removeRange(0, at);
    return out;
  }
}

/// Minimal SOCKS5 server stub: answers the greeting, records the CONNECT
/// target, then closes (no TLS server behind it).
class _FakeSocks5 {
  final List<int> _greeting = <int>[];
  String? connectHost;
  int? connectPort;
  late final ServerSocket _server;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) async {
      final reader = _BufReader(socket);
      try {
        _greeting.addAll(await reader.read(3));
        socket.add([0x05, 0x00]);
        await socket.flush();
        final head = await reader.read(4);
        expect(head.sublist(0, 3), [0x05, 0x01, 0x00]);
        // ATYP 0x03 (domain name): the next byte is the name length.
        final length = (await reader.read(1))[0];
        connectHost = utf8.decode(await reader.read(length));
        final portBytes = await reader.read(2);
        connectPort = (portBytes[0] << 8) | portBytes[1];
        socket.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        await socket.flush();
      } catch (_) {}
      await socket.close();
    });
  }

  int get port => _server.port;

  Future<void> stop() => _server.close();
}

/// Minimal HTTP proxy stub: records the CONNECT line, answers 200, closes.
class _FakeHttpProxy {
  String? firstLine;
  late final ServerSocket _server;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) async {
      final reader = _BufReader(socket);
      try {
        final request = await reader.readUntil('\r\n\r\n');
        firstLine = request.split('\r\n').first;
        socket.add(utf8.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
        await socket.flush();
      } catch (_) {}
      await socket.close();
    });
  }

  int get port => _server.port;

  Future<void> stop() => _server.close();
}

void main() {
  test('socks5:// proxy tunnels the request to VirusTotal', () async {
    final proxy = _FakeSocks5();
    await proxy.start();
    addTearDown(proxy.stop);

    await expectLater(
      VirusTotalService.scanUrl('key', 'https://example.com',
          proxy: 'socks5://127.0.0.1:${proxy.port}'),
      throwsA(isA<VirusTotalException>()),
    );

    expect(proxy._greeting, [0x05, 0x01, 0x00]);
    expect(proxy.connectHost, 'www.virustotal.com');
    expect(proxy.connectPort, 443);
  });

  test('host:port is treated as an HTTP proxy', () async {
    final proxy = _FakeHttpProxy();
    await proxy.start();
    addTearDown(proxy.stop);

    await expectLater(
      VirusTotalService.scanUrl('key', 'https://example.com',
          proxy: '127.0.0.1:${proxy.port}'),
      throwsA(isA<VirusTotalException>()),
    );

    expect(proxy.firstLine, startsWith('CONNECT www.virustotal.com:443'));
  });

  test('bare host without a port is rejected', () async {
    await expectLater(
      VirusTotalService.scanUrl('key', 'https://example.com',
          proxy: '127.0.0.1'),
      throwsA(
        isA<VirusTotalException>().having(
            (e) => e.message, 'message', contains('host:port')),
      ),
    );
  });

  test('socks4 is rejected with a clear message', () async {
    await expectLater(
      VirusTotalService.scanUrl('key', 'https://example.com',
          proxy: 'socks4://127.0.0.1:1080'),
      throwsA(
        isA<VirusTotalException>()
            .having((e) => e.message, 'message', contains('SOCKS5')),
      ),
    );
  });
}