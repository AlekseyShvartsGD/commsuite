import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../app.dart';
import '../../core/localizations.dart';
import '../../core/navigation.dart';
import '../../models.dart';
import '../../services/comms_controller.dart';

/// Full-screen live-stream UI. The broadcaster sees their camera preview and
/// controls; the viewer sees the relayed video. Media never travels directly
/// between the two devices: ICE is forced through the server TURN relay.
class LiveStreamScreen extends StatefulWidget {
  const LiveStreamScreen({super.key});

  static void push() {
    navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => const LiveStreamScreen()),
    );
  }

  @override
  State<LiveStreamScreen> createState() => _LiveStreamScreenState();
}

class _LiveStreamScreenState extends State<LiveStreamScreen> {
  bool _popped = false;

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final stream = controller.liveStream;

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
        if (stream.phase == LiveStreamPhase.incoming) {
          controller.declineLiveStream();
        } else {
          controller.endLiveStream();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: _buildBody(context, controller, stream)),
      ),
    );
  }

  void _popIfCurrent(BuildContext context) {
    if (_popped || !mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && route.isCurrent) {
      _popped = true;
      Navigator.of(context).pop();
    }
  }

  Widget _buildBody(
    BuildContext context,
    CommsController controller,
    LiveStreamSession stream,
  ) {
    final theme = Theme.of(context);
    final remote = controller.webrtc.remoteRenderer;
    final local = controller.webrtc.localRenderer;
    final isBroadcaster = stream.outgoing;
    final live = stream.phase == LiveStreamPhase.live;
    final watching =
        !isBroadcaster &&
        live &&
        controller.webrtc.remoteHasVideo &&
        remote.srcObject != null;
    final preview =
        isBroadcaster &&
        controller.webrtc.localHasVideo &&
        local.srcObject != null;

    final statusText = switch (stream.phase) {
      LiveStreamPhase.inviting => L.t(
        'Waiting for ${stream.peer.displayName} to join…',
        ru: 'Ждём ${stream.peer.displayName}…',
      ),
      LiveStreamPhase.incoming => L.t(
        '${stream.peer.displayName} is live',
        ru: '${stream.peer.displayName} в эфире',
      ),
      LiveStreamPhase.connecting =>
        isBroadcaster
            ? L.t('Connecting to viewer…', ru: 'Подключение к зрителю…')
            : L.t('Joining the live stream…', ru: 'Подключаемся к трансляции…'),
      LiveStreamPhase.live =>
        isBroadcaster
            ? L.t(
                'LIVE • ${stream.peer.displayName} is watching',
                ru: 'ЭФИР • ${stream.peer.displayName} смотрит',
              )
            : L.t(
                'LIVE • ${stream.peer.displayName}',
                ru: 'ЭФИР • ${stream.peer.displayName}',
              ),
    };

    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (watching)
                RTCVideoView(
                  remote,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              else if (preview)
                RTCVideoView(
                  local,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              else
                _placeholder(theme, stream),
              Positioned(left: 16, top: 16, child: _LiveBadge(live: live)),
              if (isBroadcaster && !preview && live)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 16,
                  child: Center(
                    child: Text(
                      L.t('camera off', ru: 'камера выключена'),
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                stream.peer.displayName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                statusText,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.dns_outlined,
                    size: 14,
                    color: Colors.white38,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    L.t('Relayed through the server', ru: 'Через сервер'),
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: isBroadcaster
                    ? [
                        _StreamButton(
                          icon: controller.webrtc.micEnabled
                              ? Icons.mic
                              : Icons.mic_off,
                          color: Colors.white24,
                          label: controller.webrtc.micEnabled
                              ? L.t('Mute', ru: 'Выключить звук')
                              : L.t('Unmute', ru: 'Включить звук'),
                          onTap: () async {
                            await controller.webrtc.toggleMic();
                            setState(() {});
                          },
                        ),
                        _StreamButton(
                          icon: controller.webrtc.hasVideo
                              ? Icons.videocam
                              : Icons.videocam_off,
                          color: Colors.white24,
                          label: controller.webrtc.hasVideo
                              ? L.t('Camera', ru: 'Камера')
                              : L.t('Camera off', ru: 'Камера выключена'),
                          onTap: () async {
                            await controller.webrtc.toggleCamera();
                            setState(() {});
                          },
                        ),
                        _StreamButton(
                          icon: Icons.stop_circle_outlined,
                          color: Colors.red,
                          label: L.t('End stream', ru: 'Завершить эфир'),
                          onTap: controller.endLiveStream,
                        ),
                      ]
                    : [
                        if (stream.phase == LiveStreamPhase.incoming) ...[
                          _StreamButton(
                            icon: Icons.close,
                            color: Colors.red,
                            label: L.t('Decline', ru: 'Отклонить'),
                            onTap: controller.declineLiveStream,
                          ),
                          _StreamButton(
                            icon: Icons.play_arrow,
                            color: Colors.green,
                            label: L.t('Watch', ru: 'Смотреть'),
                            onTap: controller.acceptLiveStream,
                          ),
                        ] else
                          _StreamButton(
                            icon: Icons.exit_to_app,
                            color: Colors.red,
                            label: L.t('Leave stream', ru: 'Покинуть эфир'),
                            onTap: controller.endLiveStream,
                          ),
                      ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _placeholder(ThemeData theme, LiveStreamSession stream) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 56,
            backgroundColor: theme.colorScheme.primaryContainer,
            foregroundColor: theme.colorScheme.onPrimaryContainer,
            child: Text(
              stream.peer.displayName.isEmpty
                  ? '?'
                  : stream.peer.displayName.characters
                        .take(2)
                        .toString()
                        .toUpperCase(),
              style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 16),
          const Icon(Icons.podcasts, color: Colors.white38),
        ],
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  final bool live;

  const _LiveBadge({required this.live});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: live ? Colors.red : Colors.black54,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: live ? Colors.white : Colors.white54,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            live ? L.t('LIVE', ru: 'ЭФИР') : L.t('PREVIEW', ru: 'ПРЕВЬЮ'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _StreamButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _StreamButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Icon(icon, color: Colors.white, size: 26),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}
