import 'dart:async';

import 'package:flutter/material.dart';

import '../core/navigation.dart';
import 'sound.dart';

import '../core/localizations.dart';

/// Custom in-app notifications (no OS/Windows toasts): an incoming-call banner
/// with accept/decline + ringtone, and transient banners for new messages.
class NotificationService {
  static OverlayEntry? _callEntry;
  static OverlayEntry? _messageEntry;
  static Timer? _messageTimer;

  static OverlayState? get _overlay => navigatorKey.currentState?.overlay;

  /// Overlay mutations are deferred to the next frame: inserting/removing
  /// entries or pushing routes while the current frame is mid-layout is what
  /// made the call UI crash on Windows ("RenderBox was not laid out").
  static void _onNextFrame(VoidCallback fn) {
    WidgetsBinding.instance.addPostFrameCallback((_) => fn());
  }

  static void showCall({
    required String displayName,
    required bool video,
    required VoidCallback onAccept,
    required VoidCallback onDecline,
    bool ring = true,
  }) {
    _onNextFrame(() {
      _removeCall();
      final entry = OverlayEntry(
        builder: (_) => _CallBanner(
          displayName: displayName,
          video: video,
          onAccept: () {
            _removeCall();
            onAccept();
          },
          onDecline: () {
            _removeCall();
            onDecline();
          },
        ),
      );
      _callEntry = entry;
      _overlay?.insert(entry);
    });
    if (ring) SoundPlayer.startRing();
  }

  static void hideCall() {
    _onNextFrame(_removeCall);
    SoundPlayer.stopRing();
  }

  static void _removeCall() {
    _callEntry?.remove();
    _callEntry = null;
  }

  static void showMessage({required String title, required String body}) {
    _onNextFrame(() {
      _messageTimer?.cancel();
      _messageEntry?.remove();
      final entry = OverlayEntry(
        builder: (_) =>
            _MessageBanner(title: title, body: body, onClose: hideMessage),
      );
      _messageEntry = entry;
      _overlay?.insert(entry);
      _messageTimer = Timer(const Duration(seconds: 5), hideMessage);
    });
    SoundPlayer.ding();
  }

  static void hideMessage() {
    _onNextFrame(() {
      _messageTimer?.cancel();
      _messageEntry?.remove();
      _messageEntry = null;
    });
  }

  static void hideAll() {
    _onNextFrame(_removeCall);
    _onNextFrame(() {
      _messageTimer?.cancel();
      _messageEntry?.remove();
      _messageEntry = null;
    });
    SoundPlayer.stopRing();
  }
}

class _CallBanner extends StatelessWidget {
  final String displayName;
  final bool video;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _CallBanner({
    required this.displayName,
    required this.video,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Transform.translate(
              offset: Offset(0, -48 * (1 - t)),
              child: Opacity(opacity: t, child: child),
            ),
            child: Container(
              margin: const EdgeInsets.all(12),
              constraints: const BoxConstraints(maxWidth: 420),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.6),
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 20,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        video ? Icons.videocam : Icons.call,
                        color: scheme.onPrimary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            video
                                ? L.t(
                                    'Incoming video call',
                                    ru: 'Входящий видеозвонок',
                                  )
                                : L.t('Incoming call', ru: 'Входящий звонок'),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: L.t('Decline', ru: 'Отклонить'),
                      onPressed: onDecline,
                      icon: const Icon(Icons.call_end, color: Colors.redAccent),
                    ),
                    IconButton(
                      tooltip: L.t('Accept', ru: 'Принять'),
                      onPressed: onAccept,
                      icon: const Icon(Icons.call, color: Colors.greenAccent),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageBanner extends StatelessWidget {
  final String title;
  final String body;
  final VoidCallback onClose;

  const _MessageBanner({
    required this.title,
    required this.body,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Transform.translate(
              offset: Offset(0, -36 * (1 - t)),
              child: Opacity(opacity: t, child: child),
            ),
            child: Container(
              margin: const EdgeInsets.all(12),
              constraints: const BoxConstraints(maxWidth: 420),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 16,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                child: Row(
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      color: scheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                      visualDensity: VisualDensity.compact,
                      tooltip: L.t('Dismiss', ru: 'Скрыть'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
