import 'dart:io';

import 'package:flutter/foundation.dart';

/// A single request to open [url] in the built-in browser. Carries a sequence
/// number so clicking the same link twice still fires (ValueNotifier dedupes
/// equal values).
class BrowserLaunch {
  const BrowserLaunch(this.url, this.seq);

  final String url;
  final int seq;
}

/// Global bridge that asks the built-in browser to open a URL. HomeShell
/// listens to switch to the Browse tab; BrowserScreen listens to navigate.
class BrowserRequest {
  BrowserRequest._();

  static final ValueNotifier<BrowserLaunch?> request =
      ValueNotifier<BrowserLaunch?>(null);

  static int _seq = 0;

  /// Fire a request for the app to open [url] in the built-in browser tab.
  static void open(String url) {
    request.value = BrowserLaunch(url, ++_seq);
  }
}

/// URL detection and opening across platforms.
class UrlService {
  UrlService._();

  /// Matches http/https/ftp URLs and bare `www.` hosts.
  static final RegExp urlPattern = RegExp(
    r'https?://[^\s<>"]+|ftp://[^\s<>"]+|www\.[^\s<>"]+',
    caseSensitive: false,
  );

  /// All URLs found in [text].
  static List<String> findUrls(String text) =>
      urlPattern.allMatches(text).map((m) => m.group(0)!).toList();

  /// Normalize a raw user string into a navigable URL.
  static String normalize(String raw) {
    var s = raw.trim();
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    if (s.startsWith('ftp://')) return s;
    if (s.startsWith('www.')) return 'https://$s';
    final host = Uri.tryParse('https://$s')?.host;
    if (!s.contains(' ') && host != null && host.contains('.')) {
      return 'https://$s';
    }
    return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(s)}';
  }

  /// Open [url] in the built-in browser (Windows/Android) or, where no
  /// built-in webview exists (Linux), launch the system browser with
  /// xdg-open.
  static Future<void> open(String url) async {
    if (!kIsWeb && Platform.isLinux) {
      await openSystem(url);
      return;
    }
    BrowserRequest.open(url);
  }

  /// Launch the platform default web browser via xdg-open.
  static Future<bool> openSystem(String url) async {
    if (kIsWeb) return false;
    try {
      await Process.start('xdg-open', [url]);
      return true;
    } catch (_) {
      return false;
    }
  }
}