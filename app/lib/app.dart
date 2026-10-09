import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/error_bus.dart';
import 'core/localizations.dart';
import 'core/navigation.dart';
import 'services/comms_controller.dart';
import 'services/crash_reporter.dart';
import 'services/server_auto_starter.dart';
import 'services/tray_service.dart';
import 'services/update_service.dart';
import 'screens/auth_screen.dart';
import 'screens/home_shell.dart';
import 'screens/server_redirect_screen.dart';

class CommsScope extends InheritedNotifier<CommsController> {
  const CommsScope({
    super.key,
    required CommsController controller,
    required super.child,
  }) : super(notifier: controller);

  static CommsController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<CommsScope>();
    assert(scope != null, 'CommsScope not found in widget tree');
    return scope!.notifier!;
  }

  static CommsController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<CommsScope>();
    return scope!.notifier!;
  }
}

class CommsApp extends StatefulWidget {
  const CommsApp({super.key});

  @override
  State<CommsApp> createState() => _CommsAppState();
}

class _CommsAppState extends State<CommsApp> with WidgetsBindingObserver {
  late final CommsController controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      TrayService.instance.initTray();
      _showPendingCrash();
    });
    // Windows: if the saved server is unreachable, boot it (WSL node + tunnels)
    // in the background. The "redirecting to your server" screen covers the wait.
    ServerAutoStarter.ensureRunning();
    // Windows: check the server's /update feed for a newer build.
    UpdateService.instance.start();
    controller = CommsController();
    controller.bootstrap();
    controller.webrtc.initRenderers();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      controller.reconnectIfNeeded();
    }
  }

  Future<void> _showPendingCrash() async {
    final report = await CrashReporter.readPendingCrash();
    if (!mounted || report == null) return;
    await showDialog<void>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => _CrashReportDialog(report: report),
    );
    await CrashReporter.clearPendingCrash();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.webrtc.disposeRenderers();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CommsScope(
      controller: controller,
      child: ValueListenableBuilder<String>(
        valueListenable: L.current,
        builder: (context, language, _) {
          return MaterialApp(
            title: 'Commsuite',
            navigatorKey: navigatorKey,
            scaffoldMessengerKey: controller.messengerKey,
            debugShowCheckedModeBanner: false,
            locale: Locale(language),
            supportedLocales: const [Locale('en'), Locale('ru')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: ThemeData(
              useMaterial3: true,
              colorSchemeSeed: const Color(0xFF00696D),
              brightness: Brightness.light,
            ),
            darkTheme: ThemeData(
              useMaterial3: true,
              colorSchemeSeed: const Color(0xFF00696D),
              brightness: Brightness.dark,
            ),
            themeMode: ThemeMode.system,
            home: const _Root(),
            builder: (context, child) =>
                Stack(children: [?child, const _ErrorBanner()]),
          );
        },
      ),
    );
  }
}

/// Shows the most recent unhandled error (if any) inside the app so a crash
/// that would otherwise kill the process "silently" leaves a readable trace.
class _ErrorBanner extends StatefulWidget {
  const _ErrorBanner();

  @override
  State<_ErrorBanner> createState() => _ErrorBannerState();
}

class _ErrorBannerState extends State<_ErrorBanner> {
  String? _latest;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    errorBus.addListener(_onError);
  }

  @override
  void dispose() {
    errorBus.removeListener(_onError);
    _dismissTimer?.cancel();
    super.dispose();
  }

  void _onError() {
    final next = errorBus.value.isEmpty ? null : errorBus.value.first;
    if (next == null || next == _latest) return;
    _scheduleShow(next);
    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _latest = null);
    });
  }

  /// The bus may be updated during build/layout/paint (e.g. by the crash
  /// handler). Calling setState there throws "Build scheduled during frame",
  /// so the show is deferred to a post-frame callback.
  void _scheduleShow(String next) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !errorBus.value.contains(next)) return;
      setState(() => _latest = next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final latest = _latest;
    if (latest == null) return const SizedBox.shrink();
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            color: const Color(0xFFB71C1C),
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.warning_amber, color: Colors.white),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      latest,
                      style: const TextStyle(color: Colors.white),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () {
                      _dismissTimer?.cancel();
                      if (mounted) setState(() => _latest = null);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CrashReportDialog extends StatelessWidget {
  const _CrashReportDialog({required this.report});

  final String report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = report.trim().split('\n');
    final summary = lines.length > 2
        ? lines[1]
        : (lines.isEmpty ? '' : lines[0]);
    return AlertDialog(
      icon: const Icon(Icons.bug_report, color: Color(0xFFB71C1C), size: 36),
      title: Text(
        L.t(
          'Commsuite recovered from a crash',
          ru: 'Commsuite восстановился после сбоя',
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              L.t(
                'Your last session ended with an unhandled error:',
                ru: 'Ваш последний сеанс завершился необработанной ошибкой:',
              ),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              summary,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Divider(height: 24),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: SelectableText(
                  report,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: report));
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(L.t('Copy log', ru: 'Копировать лог')),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: Text(L.t('OK', ru: 'ОК')),
        ),
      ],
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    if (controller.busy) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (controller.serverConnecting) {
      return const ServerRedirectScreen();
    }
    if (!controller.authed) {
      return const AuthScreen();
    }
    return const HomeShell();
  }
}
