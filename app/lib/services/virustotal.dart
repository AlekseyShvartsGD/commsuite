import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/localizations.dart';

/// A VirusTotal failure with a message fit to show the user.
class VirusTotalException implements Exception {
  const VirusTotalException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _Response {
  const _Response(this.status, this.body);

  final int status;
  final String body;
}

class _ProxyPlan {
  const _ProxyPlan.socks(this.host, this.port) : socks = true;

  const _ProxyPlan.http(this.host, this.port) : socks = false;

  final bool socks;
  final String host;
  final int port;
}

/// Buffered reader over a single-subscription socket. dart:io sockets can only
/// be listened to once, so every read has to share one subscription.
class _SocketReader {
  _SocketReader(this._socket) {
    _subscription = _socket.listen(
      _onData,
      onError: (Object error) {
        _error = error;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      cancelOnError: false,
    );
  }

  final Socket _socket;
  late final StreamSubscription<List<int>> _subscription;
  final List<int> _buffer = <int>[];
  Completer<void>? _pending;
  Object? _error;
  bool _done = false;

  void _onData(List<int> chunk) {
    _buffer.addAll(chunk);
    _wake();
  }

  void _wake() {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      _pending = null;
      pending.complete();
    }
  }

  /// Reads exactly [count] bytes, consuming them from the buffer.
  Future<List<int>> read(int count) async {
    while (_buffer.length < count) {
      final error = _error;
      if (error != null) throw error;
      if (_done) {
        throw VirusTotalException(L.t('The proxy closed the connection unexpectedly.',
            ru: 'Прокси неожиданно закрыл соединение.'));
      }
      _pending = Completer<void>();
      await _pending!.future;
    }
    final out = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return out;
  }

  Future<void> cancel() => _subscription.cancel();
}

/// Thin client for the VirusTotal v3 API used to check chat links.
///
/// VirusTotal is blocked on some networks (the TLS handshake is torn down), so
/// an optional proxy can be supplied: either an HTTP proxy (`host:port`, routed
/// through `HttpClient.findProxy`) or a SOCKS5 proxy (`socks5://host:port`,
/// tunnelled by hand because dart:io's HTTP client speaks no SOCKS).
class VirusTotalService {
  VirusTotalService._();

  static const _host = 'www.virustotal.com';
  static const _api = 'https://$_host/api/v3';
  static const _timeout = Duration(seconds: 20);

  /// Submits [url] for analysis and waits for the verdict. Returns the engine
  /// tally: `malicious`, `suspicious`, `harmless`, `undetected`, `timeout`.
  static Future<Map<String, int>> scanUrl(
    String apiKey,
    String url, {
    String proxy = '',
  }) async {
    final plan = _parseProxy(proxy);
    return plan != null && plan.socks
        ? _scanViaSocks(plan, apiKey, url)
        : _scanViaHttp(plan, apiKey, url);
  }

  /// Uploads [file] to VirusTotal and waits for the verdict, using the same
  /// engine tally as [scanUrl].
  ///
  /// The hash is looked up first: re-uploading a file VirusTotal already knows
  /// is pointless, and the lookup is free, so repeat scans of the same download
  /// cost no quota.
  static Future<Map<String, int>> scanFile(
    String apiKey,
    File file, {
    String proxy = '',
    void Function(int sent, int total)? onProgress,
  }) async {
    final fileStat = await file.stat();
    if (fileStat.type != FileSystemEntityType.file) {
      throw VirusTotalException(L.t('That file no longer exists.',
          ru: 'Этот файл больше не существует.'));
    }
    // The free tier caps uploads at 200MB (32MB for the very first upload of a
    // day); above the hard cap the API would reject the body anyway.
    if (fileStat.size > _maxUploadBytes) {
      throw VirusTotalException(L.t(
        'File is too large to scan (${_formatSize(fileStat.size)}; the limit is '
        '200 MB).',
        ru: 'Файл слишком большой для проверки'
            ' (${_formatSize(fileStat.size)}; лимит 200 МБ).',
      ));
    }
    final plan = _parseProxy(proxy);
    return plan != null && plan.socks
        ? _scanFileViaSocks(plan, apiKey, file, fileStat.size, onProgress)
        : _scanFileViaHttp(plan, apiKey, file, fileStat.size, onProgress);
  }

  static const _maxUploadBytes = 200 * 1024 * 1024;

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// SHA-256 of the file, the id VirusTotal files are keyed by.
  static Future<String> fileHash(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// Submits the file (multipart/form-data) and polls the analysis to
  /// completion, returning the engine tally.
  static Future<Map<String, int>> _scanFileViaHttp(
    _ProxyPlan? plan,
    String apiKey,
    File file,
    int size,
    void Function(int sent, int total)? onProgress,
  ) async {
    final client = plan == null ? http.Client() : IOClient(_proxyClient(plan));
    try {
      final hash = await fileHash(file);
      final known = await _fileReportViaHttp(client, apiKey, hash);
      if (known != null) return known;

      final request = http.MultipartRequest('POST', Uri.parse('$_api/files'))
        ..headers['x-apikey'] = apiKey
        ..files.add(await http.MultipartFile.fromPath('file', file.path));
      final response = await _guard(() async {
        final sent = await client.send(request);
        return http.Response.fromStream(sent);
      }, timeout: Duration(seconds: 120 + size ~/ (256 * 1024)));
      if (response.statusCode != 200) {
        throw _vtError(response.statusCode, response.body);
      }
      final id = (jsonDecode(response.body) as Map<String, dynamic>)['data']
          ?['id'] as String?;
      if (id == null) {
        throw VirusTotalException(L.t('VirusTotal did not return a file id.',
          ru: 'VirusTotal не вернул идентификатор файла.'));
      }
      return await _awaitReport(client, apiKey, '/analyses/$id',
          onProgress: onProgress);
    } finally {
      client.close();
    }
  }

  /// Existing report for [hash], or null when VirusTotal has never seen it.
  static Future<Map<String, int>?> _fileReportViaHttp(
    http.Client client,
    String apiKey,
    String hash,
  ) async {
    final report = await _guard(
      () => client.get(
        Uri.parse('$_api/files/$hash'),
        headers: {'x-apikey': apiKey},
      ),
    );
    if (report.statusCode == 404) return null; // unknown file - must upload
    if (report.statusCode != 200) throw _vtError(report.statusCode, report.body);
    final data = (jsonDecode(report.body) as Map<String, dynamic>)['data'];
    if (data is! Map<String, dynamic>) return null;
    final stats = (data['attributes'] as Map<String, dynamic>?)?['last_analysis_stats'];
    if (stats is! Map<String, dynamic>) return null;
    return _normalizeStats(stats);
  }

  static Future<Map<String, int>> _awaitReport(
    http.Client client,
    String apiKey,
    String path, {
    void Function(int sent, int total)? onProgress,
  }) async {
    onProgress?.call(0, 0);
    var attributes = <String, dynamic>{};
    var remaining = 12;
    while (true) {
      final report = await _guard(
        () => client.get(Uri.parse('$_api$path'), headers: {'x-apikey': apiKey}),
      );
      if (report.statusCode != 200) {
        throw _vtError(report.statusCode, report.body);
      }
      attributes = (jsonDecode(report.body) as Map<String, dynamic>)['data']
              ?['attributes'] as Map<String, dynamic>? ??
          {};
      if (attributes['status'] == 'completed' || remaining <= 0) break;
      await Future<void>.delayed(const Duration(seconds: 2));
      remaining--;
    }
    onProgress?.call(1, 1);
    return _statsFrom(attributes);
  }

  static Future<Map<String, int>> _scanFileViaSocks(
    _ProxyPlan plan,
    String apiKey,
    File file,
    int size,
    void Function(int sent, int total)? onProgress,
  ) async {
    final hash = await fileHash(file);
    final known = await _socksRequest(plan, apiKey, 'GET', '/files/$hash');
    if (known.status == 200) {
      final data = (jsonDecode(known.body) as Map<String, dynamic>)['data'];
      final stats =
          (data is Map<String, dynamic> ? data['attributes'] : null) is Map<String, dynamic>
              ? ((data['attributes'] as Map<String, dynamic>)['last_analysis_stats'])
              : null;
      if (stats is Map<String, dynamic>) return _normalizeStats(stats);
    } else if (known.status != 404) {
      throw _vtError(known.status, known.body);
    }

    // multipart/form-data by hand: the tunnel writes raw bytes, so the body is
    // assembled here rather than by package:http.
    const boundary = '----CommsuiteVTUpload';
    final head = StringBuffer()
      ..writeln('--$boundary')
      ..writeln('Content-Disposition: form-data; name="file"; '
          'filename="${file.uri.pathSegments.last}"')
      ..writeln('Content-Type: application/octet-stream')
      ..writeln()
      ..writeln('--$boundary--')
      ..writeln();
    final headBytes = utf8.encode(head.toString());
    final contentLength = headBytes.length + size;
    onProgress?.call(0, contentLength);

    final submit = await _socksRequestRaw(
      plan,
      apiKey,
      'POST',
      '/files',
      contentType: 'multipart/form-data; boundary=$boundary',
      bodyBuilder: (sink) async {
        sink.add(headBytes.sublist(0, headBytes.length - 2)); // trailing CRLF
        var sent = 0;
        await for (final chunk in file.openRead()) {
          sink.add(chunk);
          sent += chunk.length;
          onProgress?.call(sent, contentLength);
        }
        sink.add('\r\n--$boundary--\r\n'.codeUnits);
      },
      contentLength: contentLength + '\r\n--$boundary--\r\n'.length,
      timeout: Duration(seconds: 120 + size ~/ (256 * 1024)),
    );
    onProgress?.call(contentLength, contentLength);
    if (submit.status != 200) {
      throw _vtError(submit.status, submit.body);
    }
    final id = (jsonDecode(submit.body) as Map<String, dynamic>)['data']?['id']
        as String?;
    if (id == null) {
      throw VirusTotalException(L.t('VirusTotal did not return a file id.',
          ru: 'VirusTotal не вернул идентификатор файла.'));
    }

    var attributes = <String, dynamic>{};
    var remaining = 12;
    while (true) {
      final report =
          await _socksRequest(plan, apiKey, 'GET', '/analyses/$id');
      if (report.status != 200) {
        throw _vtError(report.status, report.body);
      }
      attributes = (jsonDecode(report.body) as Map<String, dynamic>)['data']
              ?['attributes'] as Map<String, dynamic>? ??
          {};
      if (attributes['status'] == 'completed' || remaining <= 0) break;
      await Future<void>.delayed(const Duration(seconds: 2));
      remaining--;
    }
    return _statsFrom(attributes);
  }

  // --- direct / HTTP-proxy path -------------------------------------------

  static Future<Map<String, int>> _scanViaHttp(
    _ProxyPlan? plan,
    String apiKey,
    String url,
  ) async {
    final client = plan == null ? http.Client() : IOClient(_proxyClient(plan));
    try {
      final submit = await _guard(
        () => client.post(
          Uri.parse('$_api/urls'),
          headers: {'x-apikey': apiKey},
          body: {'url': url},
        ),
      );
      if (submit.statusCode != 200) {
        throw _vtError(submit.statusCode, submit.body);
      }
      final submitJson = jsonDecode(submit.body) as Map<String, dynamic>;
      final analysisId = submitJson['data']?['id'] as String?;
      if (analysisId == null) {
        throw VirusTotalException(L.t(
            'VirusTotal did not return an analysis id',
            ru: 'VirusTotal не вернул идентификатор анализа'));
      }

      Map<String, dynamic> attributes;
      var remaining = 12;
      while (true) {
        final report = await _guard(
          () => client.get(
            Uri.parse('$_api/analyses/$analysisId'),
            headers: {'x-apikey': apiKey},
          ),
        );
        if (report.statusCode != 200) {
          throw _vtError(report.statusCode, report.body);
        }
        attributes = (jsonDecode(report.body) as Map<String, dynamic>)['data']
                ?['attributes'] as Map<String, dynamic>? ??
            {};
        if (attributes['status'] == 'completed' || remaining <= 0) break;
        await Future<void>.delayed(const Duration(seconds: 2));
        remaining--;
      }
      return _statsFrom(attributes);
    } finally {
      client.close();
    }
  }

  static HttpClient _proxyClient(_ProxyPlan plan) {
    final client = HttpClient();
    client.connectionTimeout = _timeout;
    // dart:io speaks only the PROXY directive here (no SOCKS), which is why
    // socks5:// proxies take the tunnel path below instead.
    client.findProxy = (uri) => 'PROXY ${plan.host}:${plan.port}';
    return client;
  }

  // --- SOCKS5 path ---------------------------------------------------------

  static Future<Map<String, int>> _scanViaSocks(
    _ProxyPlan plan,
    String apiKey,
    String url,
  ) async {
    final submit = await _socksRequest(plan, apiKey, 'POST', '/urls',
        form: {'url': url});
    if (submit.status != 200) {
      throw _vtError(submit.status, submit.body);
    }
    final submitJson = jsonDecode(submit.body) as Map<String, dynamic>;
    final analysisId = submitJson['data']?['id'] as String?;
    if (analysisId == null) {
      throw VirusTotalException(L.t(
          'VirusTotal did not return an analysis id',
          ru: 'VirusTotal не вернул идентификатор анализа'));
    }

    Map<String, dynamic> attributes;
    var remaining = 12;
    while (true) {
      final report =
          await _socksRequest(plan, apiKey, 'GET', '/analyses/$analysisId');
      if (report.status != 200) {
        throw _vtError(report.status, report.body);
      }
      attributes = (jsonDecode(report.body) as Map<String, dynamic>)['data']
              ?['attributes'] as Map<String, dynamic>? ??
          {};
      if (attributes['status'] == 'completed' || remaining <= 0) break;
      await Future<void>.delayed(const Duration(seconds: 2));
      remaining--;
    }
    return _statsFrom(attributes);
  }

  /// One request over a fresh SOCKS5 tunnel (a tunnel per request keeps this
  /// simple: no keep-alive reuse to get wrong).
  static Future<_Response> _socksRequest(
    _ProxyPlan plan,
    String apiKey,
    String method,
    String path, {
    Map<String, String>? form,
  }) {
    if (form == null) {
      return _socksRequestRaw(
        plan,
        apiKey,
        method,
        path,
        bodyBuilder: (_) async {},
      );
    }
    final body = Uri(queryParameters: form).query;
    return _socksRequestRaw(
      plan,
      apiKey,
      method,
      path,
      contentType: 'application/x-www-form-urlencoded',
      bodyBuilder: (sink) async => sink.add(utf8.encode(body)),
      contentLength: body.length,
    );
  }

  /// A SOCKS5 request whose body may be streamed (file uploads), so
  /// [contentLength] is required whenever [bodyBuilder] writes anything.
  static Future<_Response> _socksRequestRaw(
    _ProxyPlan plan,
    String apiKey,
    String method,
    String path, {
    String? contentType,
    required Future<void> Function(Socket sink) bodyBuilder,
    int? contentLength,
    Duration? timeout,
  }) async {
    return _guard(() async {
      final socket = await _openSocks(plan);
      final head = StringBuffer()
        ..writeln('$method $path HTTP/1.1')
        ..writeln('Host: $_host')
        ..writeln('x-apikey: $apiKey')
        ..writeln('Accept: application/json')
        ..writeln('Connection: close');
      if (contentType != null) head.writeln('Content-Type: $contentType');
      if (contentLength != null) {
        head.writeln('Content-Length: $contentLength');
      }
      head.writeln();

      socket.add(utf8.encode(head.toString()));
      await socket.flush();
      await bodyBuilder(socket);
      await socket.flush();

      final bytes = <int>[];
      await for (final chunk in socket) {
        bytes.addAll(chunk);
      }
      socket.destroy();
      return _parseHttp(utf8.decode(bytes, allowMalformed: true));
    }, timeout: timeout);
  }

  /// Opens a SOCKS5 tunnel to VirusTotal and completes the TLS handshake.
  static Future<SecureSocket> _openSocks(_ProxyPlan plan) async {
    Socket socket;
    try {
      socket = await _socks5Connect(plan.host, plan.port, _host, 443);
    } on SocketException {
      throw VirusTotalException(L.t(
          'Could not reach the proxy ${plan.host}:${plan.port}.',
          ru: 'Не удалось подключиться к прокси '
              '${plan.host}:${plan.port}.'));
    }
    try {
      return await SecureSocket.secure(socket, host: _host);
    } on HandshakeException {
      socket.destroy();
      throw VirusTotalException(L.t(
          'VirusTotal rejected the TLS session through the proxy. The proxy '
          'is not routing this domain.',
          ru: 'VirusTotal отклонил TLS-сессию через прокси. Прокси не '
              'маршрутизирует этот домен.'));
    } on SocketException {
      socket.destroy();
      throw VirusTotalException(L.t(
          'VirusTotal closed the connection through the proxy.',
          ru: 'VirusTotal закрыл соединение через прокси.'));
    }
  }

  /// Opens a SOCKS5 (no-auth) tunnel to `host:port` through the proxy.
  static Future<Socket> _socks5Connect(
    String proxyHost,
    int proxyPort,
    String host,
    int port,
  ) async {
    final socket =
        await Socket.connect(proxyHost, proxyPort, timeout: _timeout);
    final reader = _SocketReader(socket);

    // Greeting: version 5, one method, "no authentication required".
    socket.add([0x05, 0x01, 0x00]);
    await socket.flush();
    final greeting = await reader.read(2);
    if (greeting[0] != 0x05 || greeting[1] != 0x00) {
      socket.destroy();
      throw VirusTotalException(L.t(
          'The SOCKS5 proxy did not offer the no-auth method.',
          ru: 'SOCKS5-прокси не предложил метод без аутентификации.'));
    }

    final hostBytes = utf8.encode(host);
    socket.add(<int>[
      0x05, // version
      0x01, // CONNECT
      0x00, // reserved
      0x03, // domain name
      hostBytes.length,
      ...hostBytes,
      (port >> 8) & 0xff,
      port & 0xff,
    ]);
    await socket.flush();

    final reply = await reader.read(4);
    if (reply[1] != 0x00) {
      socket.destroy();
      throw VirusTotalException(L.t(
          'The SOCKS5 proxy refused the connection (code ${reply[1]}).',
          ru: 'SOCKS5-прокси отклонил соединение (код ${reply[1]}).'));
    }
    // Consume the bound address/port the proxy reports back.
    switch (reply[3]) {
      case 0x01:
        await reader.read(6);
      case 0x04:
        await reader.read(18);
      case 0x03:
        final length = (await reader.read(1))[0];
        await reader.read(length + 2);
      default:
        socket.destroy();
        throw VirusTotalException(L.t(
            'The SOCKS5 proxy sent an invalid reply.',
            ru: 'SOCKS5-прокси прислал неверный ответ.'));
    }
    // Hand the live socket to the caller; it owns it from here.
    unawaited(reader.cancel());
    return socket;
  }

  // --- shared helpers ------------------------------------------------------

  /// Analysis tally from a completed analysis (`stats`).
  static Map<String, int> _statsFrom(Map<String, dynamic> attributes) {
    final stats = attributes['stats'] as Map<String, dynamic>?;
    if (stats == null) {
      throw VirusTotalException(L.t('VirusTotal analysis is incomplete',
          ru: 'Анализ VirusTotal не завершён'));
    }
    return _normalizeStats(stats);
  }

  /// Tally from a file object (`last_analysis_stats`), falling back to
  /// `stats` for older payloads.
  static Map<String, int> _normalizeStats(Map<String, dynamic> stats) {
    return {
      for (final e in stats.entries)
        if (e.value is num) e.key: (e.value as num).toInt(),
    };
  }

  static _ProxyPlan? _parseProxy(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;

    var socks = false;
    final schemeAt = text.indexOf('://');
    if (schemeAt != -1) {
      final scheme = text.substring(0, schemeAt).toLowerCase();
      if (scheme.startsWith('socks')) {
        if (!scheme.endsWith('5')) {
          throw VirusTotalException(L.t(
              'Only SOCKS5 proxies are supported (socks5://host:port).',
              ru: 'Поддерживаются только SOCKS5-прокси '
                  '(socks5://host:port).'));
        }
        socks = true;
      }
      text = text.substring(schemeAt + 3);
    }
    // Strip any credentials and path.
    final at = text.lastIndexOf('@');
    if (at != -1) text = text.substring(at + 1);
    text = text.replaceAll('/', '').trim();

    final colon = text.lastIndexOf(':');
    final host =
        colon == -1 ? text : text.substring(0, colon).trim();
    final port = colon == -1 ? 0 : int.tryParse(text.substring(colon + 1).trim()) ?? 0;
    if (host.isEmpty || port <= 0 || port > 65535) {
      throw VirusTotalException(L.t(
          'Invalid proxy: expected host:port, e.g. 127.0.0.1:7890',
          ru: 'Неверный прокси: ожидался host:port, например 127.0.0.1:7890'));
    }
    return socks ? _ProxyPlan.socks(host, port) : _ProxyPlan.http(host, port);
  }

  static _Response _parseHttp(String raw) {
    final split = raw.indexOf('\r\n\r\n');
    final head = split == -1 ? raw : raw.substring(0, split);
    var body = split == -1 ? '' : raw.substring(split + 4);
    final lines = head.split('\r\n');
    final status = lines.isEmpty
        ? 0
        : int.tryParse(
                (lines.first.split(' ').length > 1
                    ? lines.first.split(' ')[1]
                    : '0'),
              ) ??
              0;
    if (head.toLowerCase().contains('transfer-encoding: chunked')) {
      body = _dechunk(body);
    }
    return _Response(status, body);
  }

  static String _dechunk(String body) {
    final out = StringBuffer();
    var rest = body;
    while (true) {
      final nl = rest.indexOf('\r\n');
      if (nl == -1) break;
      final size =
          int.tryParse(rest.substring(0, nl).split(';').first.trim(), radix: 16) ?? 0;
      if (size == 0) break;
      final start = nl + 2;
      final end = start + size;
      if (end > rest.length) {
        out.write(rest.substring(start));
        break;
      }
      out.write(rest.substring(start, end));
      rest = rest.substring(end + 2);
    }
    return out.toString();
  }

  static Exception _vtError(int status, String body) {
    if (status == 401) {
      return VirusTotalException(L.t(
          'VirusTotal rejected the API key (401). Check it in Settings - '
          'Security.',
          ru: 'VirusTotal отклонил API-ключ (401). Проверьте его в разделе '
              '«Настройки — Безопасность».'));
    }
    if (status == 429) {
      return VirusTotalException(L.t(
          'VirusTotal rate limit reached (429). The free tier allows a few '
          'scans per minute.',
          ru: 'Достигнут лимит запросов VirusTotal (429). Бесплатный тариф '
              'позволяет несколько проверок в минуту.'));
    }
    final msg = 'HTTP $status';
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final error = decoded['error']?['message'];
      if (error is String && error.isNotEmpty) {
        return VirusTotalException('$msg - $error');
      }
    } catch (_) {}
    return VirusTotalException(msg);
  }

  /// Runs a request with a timeout and turns network/TLS failures into a
  /// message worth showing (a DPI block that terminates the TLS handshake would
  /// otherwise surface as a raw HandshakeException).
  static Future<T> _guard<T>(
    Future<T> Function() run, {
    Duration? timeout,
  }) async {
    try {
      return await run().timeout(timeout ?? _timeout);
    } on HandshakeException {
      throw VirusTotalException(L.t(
          'Could not reach VirusTotal: the TLS connection was terminated. This '
          'network appears to filter virustotal.com - set a proxy in '
          'Settings - Security or use a VPN.',
          ru: 'Не удалось подключиться к VirusTotal: TLS-соединение было '
              'прервано. Похоже, сеть фильтрует virustotal.com — укажите '
              'прокси в разделе «Настройки — Безопасность» или используйте '
              'VPN.'));
    } on SocketException {
      throw VirusTotalException(L.t(
          'Could not reach VirusTotal: no route to virustotal.com.',
          ru: 'Не удалось подключиться к VirusTotal: нет маршрута к '
              'virustotal.com.'));
    } on TimeoutException {
      throw VirusTotalException(L.t('VirusTotal did not respond in time.',
          ru: 'VirusTotal не ответил вовремя.'));
    }
  }
}