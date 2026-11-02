import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../app.dart';
import '../../core/localizations.dart';
import '../../models.dart';
import '../../services/comms_controller.dart';
import '../../widgets/user_avatar.dart';
import '../chat/chat_screen.dart';

/// The full-screen broadcast room. The broadcaster sees their own camera
/// preview plus the stream controls; a viewer sees the relayed video. Both
/// sides can open the dedicated stream chat.
///
/// Media never travels directly between two devices: every peer connection is
/// forced through the server TURN relay (see [BroadcastService]).
class StreamRoomScreen extends StatefulWidget {
  const StreamRoomScreen({super.key, required this.broadcaster});

  final bool broadcaster;

  @override
  State<StreamRoomScreen> createState() => _StreamRoomScreenState();
}

class _StreamRoomScreenState extends State<StreamRoomScreen> {
  bool _popped = false;
  bool _leaving = false;

  CommsController get _controller => CommsScope.read(context);

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final stream = widget.broadcaster ? controller.myStream : controller.watching;

    if (stream == null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _popIfCurrent(context),
      );
      return const Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.shrink(),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _leave();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              _topBar(context, stream),
              Expanded(child: _video(context, controller, stream)),
              _controls(context, controller, stream),
            ],
          ),
        ),
      ),
    );
  }

  // ---- video ---------------------------------------------------------------

  Widget _video(
    BuildContext context,
    CommsController controller,
    StreamInfo stream,
  ) {
    final theme = Theme.of(context);
    if (widget.broadcaster) {
      final renderer = controller.broadcast.localRenderer;
      final preview = renderer.srcObject != null;
      return Stack(
        fit: StackFit.expand,
        children: [
          if (preview)
            RTCVideoView(
              renderer,
              mirror: true,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
          else
            _placeholder(
              theme,
              icon: Icons.videocam_off_outlined,
              title: L.t('Camera is off', ru: 'Камера выключена'),
              subtitle: L.t(
                'Turn the camera back on to keep streaming.',
                ru: 'Включите камеру, чтобы продолжить трансляцию.',
              ),
            ),
          if (preview && !controller.broadcast.cameraEnabled)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    L.t('camera off', ru: 'камера выключена'),
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    final renderer = controller.broadcast.remoteRenderer;
    final hasVideo = renderer.srcObject != null;
    if (!hasVideo) {
      return _placeholder(
        theme,
        icon: Icons.hourglass_top,
        title: L.t('Connecting to the stream…', ru: 'Подключаемся к трансляции…'),
        subtitle: L.t(
          'The broadcaster is about to send video.',
          ru: 'Транслятор вот-вот начнёт передачу видео.',
        ),
      );
    }
    return RTCVideoView(
      renderer,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );
  }

  Widget _placeholder(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: Colors.white38),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  // ---- header --------------------------------------------------------------

  Widget _topBar(BuildContext context, StreamInfo stream) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          const _LiveBadge(),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stream.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _topBarSubtitle(stream),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          if (stream.canManage)
            IconButton(
              tooltip: L.t('Moderation', ru: 'Модерация'),
              icon: const Icon(Icons.shield_outlined, color: Colors.white),
              onPressed: () => _openModeration(stream),
            ),
          IconButton(
            tooltip: L.t('Close', ru: 'Закрыть'),
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: _leave,
          ),
        ],
      ),
    );
  }

  // ---- controls ------------------------------------------------------------

  Widget _controls(
    BuildContext context,
    CommsController controller,
    StreamInfo stream,
  ) {
    final broadcast = controller.broadcast;
    if (!widget.broadcaster) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white30),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _openChat,
                icon: const Icon(Icons.chat_bubble_outline),
                label: Text(L.t('Stream chat', ru: 'Чат трансляции')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _leaving ? null : _leave,
                icon: const Icon(Icons.logout),
                label: Text(L.t('Leave', ru: 'Выйти')),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      color: Colors.black,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              _RoundToggle(
                tooltip: broadcast.micEnabled
                    ? L.t('Mute microphone', ru: 'Выключить микрофон')
                    : L.t('Unmute microphone', ru: 'Включить микрофон'),
                icon: broadcast.micEnabled ? Icons.mic : Icons.mic_off,
                active: broadcast.micEnabled,
                onPressed: () async {
                  await broadcast.toggleMic();
                  if (mounted) setState(() {});
                },
              ),
              _RoundToggle(
                tooltip: broadcast.cameraEnabled
                    ? L.t('Turn camera off', ru: 'Выключить камеру')
                    : L.t('Turn camera on', ru: 'Включить камеру'),
                icon: broadcast.cameraEnabled
                    ? Icons.videocam
                    : Icons.videocam_off,
                active: broadcast.cameraEnabled,
                onPressed: () async {
                  await broadcast.toggleCamera();
                  if (mounted) setState(() {});
                },
              ),
              _RoundToggle(
                tooltip: L.t('Switch camera', ru: 'Сменить камеру'),
                icon: Icons.cameraswitch_outlined,
                active: true,
                onPressed: () => broadcast.switchCamera(),
              ),
              PopupMenuButton<String>(
                tooltip: L.t('Stream quality', ru: 'Качество трансляции'),
                initialValue: controller.streamQuality,
                onSelected: controller.setStreamQuality,
                itemBuilder: (context) => [
                  for (final q in const ['480p', '720p'])
                    PopupMenuItem(
                      value: q,
                      child: Row(
                        children: [
                          Icon(
                            controller.streamQuality == q
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(q),
                        ],
                      ),
                    ),
                ],
                child: _RoundToggle(
                  tooltip: L.t('Stream quality', ru: 'Качество трансляции'),
                  icon: Icons.high_quality_outlined,
                  active: true,
                  onPressed: null,
                ),
              ),
              _RoundToggle(
                tooltip: L.t('Stream chat', ru: 'Чат трансляции'),
                icon: Icons.chat_bubble_outline,
                active: true,
                onPressed: _openChat,
              ),
              _RoundToggle(
                tooltip: L.t('End stream', ru: 'Завершить трансляцию'),
                icon: Icons.stop_circle_outlined,
                active: false,
                danger: true,
                onPressed: _leaving ? null : _endBroadcast,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            controller.streamQuality,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }

  String _topBarSubtitle(StreamInfo stream) {
    if (!widget.broadcaster) return stream.broadcaster.displayName;
    return L.t(
      '${stream.viewerCount} of ${stream.maxViewers} viewers',
      ru: '${stream.viewerCount} из ${stream.maxViewers} зрителей',
    );
  }

  Future<void> _openModeration(StreamInfo stream) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ModerationSheet(streamId: stream.id),
    );
  }

  // ---- actions -------------------------------------------------------------

  Future<void> _openChat() async {
    final controller = _controller;
    final conversation = await controller.openStreamChat();
    if (!mounted || conversation == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversation)),
    );
  }

  Future<void> _endBroadcast() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L.t('End the stream?', ru: 'Завершить трансляцию?')),
        content: Text(
          L.t(
            'Every viewer is disconnected and the stream chat is archived.',
            ru: 'Все зрители будут отключены, а чат трансляции архивирован.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.t('End stream', ru: 'Завершить')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _leaving = true);
    await _controller.endMyStream();
    if (!mounted) return;
    _popIfCurrent(context);
  }

  Future<void> _leave() async {
    if (_leaving) return;
    if (widget.broadcaster) {
      await _endBroadcast();
      return;
    }
    setState(() => _leaving = true);
    await _controller.leaveWatching();
    if (!mounted) return;
    _popIfCurrent(context);
  }

  void _popIfCurrent(BuildContext context) {
    if (_popped || !mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && route.isCurrent) {
      _popped = true;
      Navigator.of(context).pop();
    }
  }
}

// ---- widgets --------------------------------------------------------------

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        L.t('LIVE', ru: 'ЭФИР'),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _RoundToggle extends StatelessWidget {
  const _RoundToggle({
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.onPressed,
    this.danger = false,
  });

  final String tooltip;
  final IconData icon;
  final bool active;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final background = danger
        ? Colors.red
        : active
            ? Colors.white24
            : Colors.white10;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }
}

/// Viewer and ban management for the broadcaster and channel moderators.
class _ModerationSheet extends StatefulWidget {
  const _ModerationSheet({required this.streamId});

  final String streamId;

  @override
  State<_ModerationSheet> createState() => _ModerationSheetState();
}

class _ModerationSheetState extends State<_ModerationSheet> {
  List<StreamViewer> _viewers = const [];
  List<User> _bans = const [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final controller = CommsScope.read(context);
    final viewers = await controller.fetchStreamViewers(widget.streamId);
    final bans = await controller.fetchStreamBans(widget.streamId);
    if (!mounted) return;
    setState(() {
      _viewers = viewers;
      _bans = bans;
      _loading = false;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    await action();
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      L.t('Stream moderation', ru: 'Модерация трансляции'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: L.t('Refresh', ru: 'Обновить'),
                    icon: const Icon(Icons.refresh),
                    onPressed: _loading ? null : _load,
                  ),
                ],
              ),
            ),
            if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else
              Expanded(
                child: ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text(
                        L.t(
                          'Viewers (${_viewers.length})',
                          ru: 'Зрители (${_viewers.length})',
                        ),
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    if (_viewers.isEmpty)
                      ListTile(
                        title: Text(
                          L.t('Nobody is watching yet', ru: 'Пока никто не смотрит'),
                        ),
                      ),
                    for (final viewer in _viewers)
                      ListTile(
                        leading: UserAvatar(
                          name: viewer.user.displayName,
                          seed: viewer.user.id,
                          isVerified: viewer.user.isVerified,
                          radius: 18,
                        ),
                        title: Text(viewer.user.displayName),
                        subtitle: viewer.online
                            ? Text(L.t('watching now', ru: 'смотрит сейчас'))
                            : Text(L.t('offline', ru: 'не в сети')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: L.t('Kick', ru: 'Выгнать'),
                              icon: const Icon(Icons.logout),
                              onPressed: _busy
                                  ? null
                                  : () => _run(
                                        () => CommsScope.read(context)
                                            .kickStreamViewer(
                                          widget.streamId,
                                          viewer.user.id,
                                        ),
                                      ),
                            ),
                            IconButton(
                              tooltip: L.t(
                                'Ban from channel',
                                ru: 'Забанить на канале',
                              ),
                              icon: const Icon(Icons.block),
                              onPressed: _busy
                                  ? null
                                  : () => _run(
                                        () => CommsScope.read(context)
                                            .banStreamViewer(
                                          widget.streamId,
                                          viewer.user.id,
                                        ),
                                      ),
                            ),
                          ],
                        ),
                      ),
                    const Divider(height: 24),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                        L.t(
                          'Banned (${_bans.length})',
                          ru: 'Забанены (${_bans.length})',
                        ),
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    if (_bans.isEmpty)
                      ListTile(
                        title: Text(L.t('No one is banned', ru: 'Никто не забанен')),
                      ),
                    for (final banned in _bans)
                      ListTile(
                        leading: UserAvatar(
                          name: banned.displayName,
                          seed: banned.id,
                          radius: 18,
                        ),
                        title: Text(banned.displayName),
                        trailing: TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(
                                    () => CommsScope.read(context)
                                        .unbanStreamViewer(
                                      widget.streamId,
                                      banned.id,
                                    ),
                                  ),
                          child: Text(L.t('Unban', ru: 'Разбанить')),
                        ),
                      ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
