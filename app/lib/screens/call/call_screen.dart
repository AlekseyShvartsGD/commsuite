import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../app.dart';
import '../../core/app_config.dart';
import '../../core/navigation.dart';
import '../../models.dart';
import '../../services/comms_controller.dart';
import '../../services/webrtc_service.dart';
import '../../core/localizations.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  /// Pushes the call UI onto the root navigator (used when an incoming call is
  /// accepted from the custom notification banner).
  static void push() {
    navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => const CallScreen()),
    );
  }

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool _popped = false;

  @override
  Widget build(BuildContext context) {
    final controller = CommsScope.of(context);
    final call = controller.call;

    if (call == null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _popIfCurrent(context),
      );
      return const Scaffold(body: SizedBox.shrink());
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(child: _buildBody(context, controller, call)),
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

  Future<void> _showDeviceSheet(CommsController controller) async {
    final cameras = await WebRTCService.listCameras();
    final mics = await WebRTCService.listMicrophones();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) {
        final theme = Theme.of(sheet);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              if (Platform.isAndroid)
                ListTile(
                  leading: const Icon(Icons.flip_camera_android),
                  title: Text(L.t('Flip camera (front/back)',
                      ru: 'Переключить камеру (спереди/сзади)')),
                  onTap: () async {
                    Navigator.of(sheet).pop();
                    await controller.webrtc.switchCamera();
                    setState(() {});
                  },
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(L.t('Camera', ru: 'Камера'),
                    style: theme.textTheme.titleSmall),
              ),
              ListTile(
                leading: Icon(AppConfig.cameraId.isEmpty
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                title:
                    Text(L.t('System default', ru: 'Системная по умолчанию')),
                onTap: () => _pickCamera(sheet, controller, ''),
              ),
              for (var i = 0; i < cameras.length; i++)
                ListTile(
                  leading: Icon(cameras[i].deviceId == AppConfig.cameraId
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked),
                  title: Text(
                    cameras[i].label.trim().isEmpty
                        ? '${L.t('Camera', ru: 'Камера')} ${i + 1}'
                        : cameras[i].label,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () =>
                      _pickCamera(sheet, controller, cameras[i].deviceId),
                ),
              const Divider(height: 24),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Text(L.t('Microphone', ru: 'Микрофон'),
                    style: theme.textTheme.titleSmall),
              ),
              ListTile(
                leading: Icon(AppConfig.micId.isEmpty
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                title:
                    Text(L.t('System default', ru: 'Системный по умолчанию')),
                onTap: () => _pickMic(sheet, controller, ''),
              ),
              for (var i = 0; i < mics.length; i++)
                ListTile(
                  leading: Icon(mics[i].deviceId == AppConfig.micId
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked),
                  title: Text(
                    mics[i].label.trim().isEmpty
                        ? '${L.t('Microphone', ru: 'Микрофон')} ${i + 1}'
                        : mics[i].label,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _pickMic(sheet, controller, mics[i].deviceId),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickCamera(
    BuildContext sheet,
    CommsController controller,
    String deviceId,
  ) async {
    Navigator.of(sheet).pop();
    final ok = await controller.webrtc.useCamera(deviceId);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(L.t('Could not switch camera.',
                ru: 'Не удалось переключить камеру.'))),
      );
    }
    setState(() {});
  }

  Future<void> _pickMic(
    BuildContext sheet,
    CommsController controller,
    String deviceId,
  ) async {
    Navigator.of(sheet).pop();
    final ok = await controller.webrtc.useMicrophone(deviceId);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(L.t('Could not switch microphone.',
                ru: 'Не удалось переключить микрофон.'))),
      );
    }
    setState(() {});
  }

  Widget _buildBody(
    BuildContext context,
    CommsController controller,
    CallSession call,
  ) {
    final theme = Theme.of(context);
    final remote = controller.webrtc.remoteRenderer;
    final local = controller.webrtc.localRenderer;

    final videoCall = call.video;
    final remoteHasVideo =
        controller.webrtc.remoteHasVideo && call.phase == CallPhase.connected;
    final showRemoteVideo = videoCall && remoteHasVideo;
    final showLocalPreview = videoCall && controller.webrtc.localHasVideo;

    final String statusText;
    switch (call.phase) {
      case CallPhase.incoming:
        statusText = videoCall
            ? L.t('Incoming video call…', ru: 'Входящий видеозвонок…')
            : L.t('Incoming call…', ru: 'Входящий звонок…');
        break;
      case CallPhase.outgoing:
        statusText = L.t('Ringing…', ru: 'Идёт вызов…');
        break;
      case CallPhase.connecting:
        statusText = L.t('Connecting…', ru: 'Соединение…');
        break;
      case CallPhase.connected:
        statusText = L.t('Connected', ru: 'Соединено');
        break;
      default:
        statusText = '';
    }

    return Column(
      children: [
        Expanded(
          child: SizedBox.expand(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (showRemoteVideo && remote.srcObject != null)
                  RTCVideoView(
                    remote,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                else
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 56,
                          backgroundColor: theme.colorScheme.primaryContainer,
                          foregroundColor: theme.colorScheme.onPrimaryContainer,
                          child: Text(
                            call.peer.displayName.isEmpty
                                ? '?'
                                : call.peer.displayName.characters
                                      .take(2)
                                      .toString()
                                      .toUpperCase(),
                            style: const TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (videoCall && call.phase == CallPhase.connected) ...[
                          const SizedBox(height: 16),
                          Text(
                            L.t('camera off', ru: 'камера выключена'),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                if (showLocalPreview && local.srcObject != null)
                  Positioned(
                    left: 16,
                    top: 16,
                    child: RTCVideoView(
                      local,
                      mirror: videoCall,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                call.peer.displayName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(statusText, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 28),
              if (call.phase == CallPhase.incoming)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _RoundButton(
                      icon: Icons.close,
                      color: Colors.red,
                      label: L.t('Decline', ru: 'Отклонить'),
                      onTap: () => controller.declineCall(),
                    ),
                    _RoundButton(
                      icon: Icons.call,
                      color: Colors.green,
                      label: L.t('Accept', ru: 'Принять'),
                      onTap: () => controller.acceptCall(),
                    ),
                  ],
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (call.phase == CallPhase.connected) ...[
                      _RoundButton(
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
                      if (videoCall) ...[
                        _RoundButton(
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
                        _RoundButton(
                          icon: Icons.settings_input_component,
                          color: Colors.white24,
                          label: L.t('Devices', ru: 'Устройства'),
                          onTap: () => _showDeviceSheet(controller),
                        ),
                      ],
                    ],
                    _RoundButton(
                      icon: Icons.call_end,
                      color: Colors.red,
                      label: call.phase == CallPhase.outgoing
                          ? L.t('Cancel', ru: 'Отмена')
                          : L.t('Hang up', ru: 'Завершить'),
                      onTap: () => controller.hangUp(),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _RoundButton({
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
        InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 28),
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
