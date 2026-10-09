import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/download_service.dart';
import '../../services/url_service.dart';
import 'downloads_sheet.dart';
import '../../core/localizations.dart';

class _BrowserTab {
  InAppWebViewController? controller;
  late String currentUrl;
  String? title;
  int progress = 0;
  final List<String> history = [];

  _BrowserTab(this.currentUrl);
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final List<_BrowserTab> _tabs = [];
  int _active = 0;
  final _urlController = TextEditingController();
  final List<Map<String, String>> _bookmarks = [];

  static const _home = 'https://www.google.com/';
  static const _bookmarksKey = 'commsuite.bookmarks';

  @override
  void initState() {
    super.initState();
    _tabs.add(_BrowserTab(_home));
    _urlController.text = _home;
    _loadBookmarks();
    BrowserRequest.request.addListener(_onBrowserRequest);
    // Rebuild the list from disk so downloads from earlier sessions show up.
    DownloadService.instance.refresh();
  }

  @override
  void dispose() {
    BrowserRequest.request.removeListener(_onBrowserRequest);
    _urlController.dispose();
    super.dispose();
  }

  void _onBrowserRequest() {
    final launch = BrowserRequest.request.value;
    if (launch == null || launch.url.isEmpty) return;
    // Navigate one frame later: HomeShell switches to this tab in the same
    // notification burst, and WebView2 drops loadUrl calls issued while the
    // webview is still offstage. By the frame callback the tab is onstage, so
    // the navigation actually takes effect.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _go(launch.url);
    });
  }

  /// Whether this build actually ships an embedded webview (Windows/Android).
  /// On Linux there is none, so the tab acts as a launcher for the system
  /// browser instead (xdg-open).
  bool get _embedded => InAppWebViewPlatform.instance != null;

  _BrowserTab get _activeTab => _tabs[_active];

  Future<void> _loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_bookmarksKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as List;
      setState(() {
        _bookmarks.clear();
        for (final entry in decoded) {
          final pair = entry as List;
          _bookmarks.add({'title': pair[0], 'url': pair[1]});
        }
      });
    } catch (_) {}
  }

  Future<void> _saveBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final data = _bookmarks.map((b) => [b['title'], b['url']]).toList();
    await prefs.setString(_bookmarksKey, jsonEncode(data));
  }

  void _newTab() {
    setState(() {
      _tabs.add(_BrowserTab(_home));
      _active = _tabs.length - 1;
      _urlController.text = _activeTab.currentUrl;
    });
  }

  void _closeTab(int index) {
    if (_tabs.length <= 1) return;
    setState(() {
      final tab = _tabs.removeAt(index);
      tab.controller?.dispose();
      if (_active > index) _active--;
      _active = _active.clamp(0, _tabs.length - 1);
      _syncUrlBar();
    });
  }

  void _selectTab(int index) {
    setState(() {
      _active = index;
      _syncUrlBar();
    });
  }

  void _syncUrlBar() {
    _urlController.text = _activeTab.currentUrl;
  }

  String _normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return _activeTab.currentUrl;
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    final hasNoSpaces = !s.contains(' ');
    final host = Uri.tryParse('https://$s')?.host;
    if (hasNoSpaces && host != null && host.contains('.')) return 'https://$s';
    return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(s)}';
  }

  Future<void> _go(String raw) async {
    final url = _normalize(raw);
    final tab = _activeTab;
    setState(() {
      tab.currentUrl = url;
      _urlController.text = url;
      if (!_embedded) {
        tab.progress = 0;
        tab.title = Uri.tryParse(url)?.host ?? url;
      }
    });
    if (!_embedded) {
      await _openExternal(url);
      return;
    }
    final controller = tab.controller;
    if (controller != null) {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
  }

  Future<void> _openExternal(String url) async {
    final ok = await UrlService.openSystem(url);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t(
              'Could not open $url - is xdg-open available?',
              ru: 'Не удалось открыть $url — доступен ли xdg-open?',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _back() {
    if (!_embedded) return Future.value();
    return _activeTab.controller?.goBack() ?? Future.value();
  }

  Future<void> _forward() {
    if (!_embedded) return Future.value();
    return _activeTab.controller?.goForward() ?? Future.value();
  }

  Future<void> _reload() {
    if (!_embedded) {
      final url = _activeTab.currentUrl;
      if (url.isEmpty) return Future.value();
      return _openExternal(url);
    }
    return _activeTab.controller?.reload() ?? Future.value();
  }

  bool get _isBookmarked {
    final url = _activeTab.currentUrl;
    return _bookmarks.any((b) => b['url'] == url);
  }

  Future<void> _toggleBookmark() async {
    final tab = _activeTab;
    final url = tab.currentUrl;
    if (url.isEmpty) return;
    setState(() {
      final existing = _bookmarks.indexWhere((b) => b['url'] == url);
      if (existing >= 0) {
        _bookmarks.removeAt(existing);
      } else {
        _bookmarks.add({
          'title': tab.title?.trim().isNotEmpty == true ? tab.title! : url,
          'url': url,
        });
      }
    });
    await _saveBookmarks();
  }

  void _showDownloads() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      builder: (context) => const DownloadsSheet(),
    );
  }

  /// Called by the webview when a page starts a download.
  void _onDownloadStart(
    InAppWebViewController controller,
    DownloadStartRequest request,
  ) {
    DownloadService.instance
        .start(
          request.url.toString(),
          suggestedName: request.suggestedFilename ?? '',
        )
        .then((item) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                L.t('Downloading ${item.name}', ru: 'Загрузка ${item.name}'),
              ),
              action: SnackBarAction(
                label: L.t('Open', ru: 'Открыть'),
                onPressed: _showDownloads,
              ),
            ),
          );
        });
  }

  void _showBookmarks() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                L.t('Bookmarks', ru: 'Закладки'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (_bookmarks.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  L.t(
                    'No bookmarks yet. Tap the star to save a page.',
                    ru:
                        'Пока нет закладок. Нажмите на звезду, чтобы '
                        'сохранить страницу.',
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _bookmarks.length,
                  itemBuilder: (context, index) {
                    final b = _bookmarks[index];
                    return ListTile(
                      leading: const Icon(Icons.bookmark),
                      title: Text(
                        b['title']!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        b['url']!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        _go(b['url']!);
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('Browser', ru: 'Браузер')),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: L.t('New tab', ru: 'Новая вкладка'),
            onPressed: _newTab,
          ),
          AnimatedBuilder(
            animation: DownloadService.instance,
            builder: (context, _) {
              final active = DownloadService.instance.items
                  .where((d) => d.inProgress)
                  .length;
              return IconButton(
                icon: active > 0
                    ? Badge.count(
                        count: active,
                        child: const Icon(Icons.downloading),
                      )
                    : const Icon(Icons.download),
                tooltip: L.t('Downloads', ru: 'Загрузки'),
                onPressed: _showDownloads,
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.bookmark_border),
            tooltip: L.t('Bookmarks', ru: 'Закладки'),
            onPressed: _showBookmarks,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_tabs.length > 1)
            SizedBox(
              height: 40,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _tabs.length,
                itemBuilder: (context, index) {
                  final tab = _tabs[index];
                  final active = index == _active;
                  return GestureDetector(
                    onTap: () => _selectTab(index),
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: active
                            ? colorScheme.primaryContainer
                            : colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              tab.title ?? L.t('New tab', ru: 'Новая вкладка'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          InkWell(
                            onTap: () => _closeTab(index),
                            child: const Icon(Icons.close, size: 16),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: L.t('Back', ru: 'Назад'),
                  onPressed: _embedded ? _back : null,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  tooltip: L.t('Forward', ru: 'Вперёд'),
                  onPressed: _embedded ? _forward : null,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: L.t('Reload', ru: 'Обновить'),
                  onPressed: _reload,
                ),
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: _go,
                    decoration: InputDecoration(
                      hintText: L.t(
                        'Search or type a URL',
                        ru: 'Поиск или введите URL',
                      ),
                      isDense: true,
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(_isBookmarked ? Icons.star : Icons.star_border),
                  tooltip: L.t(
                    'Bookmark this page',
                    ru: 'Добавить страницу в закладки',
                  ),
                  onPressed: _toggleBookmark,
                ),
              ],
            ),
          ),
          if (_activeTab.progress > 0 && _activeTab.progress < 100)
            LinearProgressIndicator(value: _activeTab.progress / 100)
          else
            const SizedBox(height: 2),
          Expanded(
            child: IndexedStack(
              index: _active,
              children: _tabs.map(_tabBody).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabBody(_BrowserTab tab) {
    if (!_embedded) {
      return _ExternalBrowserView(
        url: tab.currentUrl,
        onOpen: () => _openExternal(tab.currentUrl),
      );
    }
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(tab.currentUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        allowFileAccess: true,
      ),
      onWebViewCreated: (controller) async {
        tab.controller = controller;
        // Cover the race where navigation happened before the webview was
        // created (e.g. a link request fired while the tab was still offstage).
        if (tab.currentUrl.isNotEmpty) {
          await controller.loadUrl(
            urlRequest: URLRequest(url: WebUri(tab.currentUrl)),
          );
        }
      },
      onTitleChanged: (controller, title) {
        if (!mounted) return;
        setState(() => tab.title = title);
      },
      onProgressChanged: (controller, progress) {
        if (!mounted) return;
        setState(() => tab.progress = progress);
      },
      onUpdateVisitedHistory: (controller, uri, isReload) {
        if (!mounted || uri == null) return;
        setState(() {
          tab.history.add(uri.toString());
          tab.currentUrl = uri.toString();
          if (identical(tab, _activeTab)) _urlController.text = uri.toString();
        });
      },
      onDownloadStartRequest: (controller, request) =>
          _onDownloadStart(controller, request),
    );
  }
}

class _ExternalBrowserView extends StatelessWidget {
  final String url;
  final VoidCallback onOpen;

  const _ExternalBrowserView({required this.url, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.open_in_browser,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              L.t('System browser', ru: 'Системный браузер'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              L.t(
                'No built-in webview is available on Linux - pages open in '
                'your system web browser (xdg-open).',
                ru:
                    'Встроенный веб-просмотр недоступен в Linux — страницы '
                    'открываются в системном браузере (xdg-open).',
              ),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            SelectableText(
              url,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.launch),
              label: Text(
                L.t(
                  'Open in system browser',
                  ru: 'Открыть в системном браузере',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
