import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../core/app_config.dart';

class WebRTCService {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  bool _remoteSet = false;
  bool _polite = false;
  final List<RTCIceCandidate> _pendingIce = [];

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  bool _videoEnabled = false;
  bool _micEnabled = true;

  bool get hasVideo => (_localStream?.getVideoTracks().isNotEmpty ?? false) && _videoEnabled;
  bool get localHasVideo => _localStream?.getVideoTracks().isNotEmpty ?? false;
  bool get remoteHasVideo => remoteRenderer.srcObject?.getVideoTracks().isNotEmpty ?? false;
  bool get micEnabled => _micEnabled;

  Future<void> initRenderers() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
  }

  Future<void> disposeRenderers() async {
    await stop();
    await localRenderer.dispose();
    await remoteRenderer.dispose();
  }

  Future<bool> startLocal({required bool video}) async {
    await _stopLocal();
    if (Platform.isAndroid) {
      final mic = await ph.Permission.microphone.request();
      var cam = ph.PermissionStatus.granted;
      if (video) cam = await ph.Permission.camera.request();
      if (!mic.isGranted || (video && !cam.isGranted)) return false;
    }
    final constraints = <String, dynamic>{
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        if (AppConfig.micId.isNotEmpty) 'deviceId': {'ideal': AppConfig.micId},
      },
      'video': video
          ? {
              'width': 1280,
              'height': 720,
              if (AppConfig.cameraId.isNotEmpty)
                'deviceId': {'ideal': AppConfig.cameraId}
              else
                'facingMode': 'user',
            }
          : false,
    };
    try {
      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      _videoEnabled = video;
      _micEnabled = true;
      // Only feed the renderer when the stream actually carries video tracks:
      // rendering an audio-only stream crashes the native renderer on Windows.
      if (localHasVideo) localRenderer.srcObject = _localStream;
      return true;
    } catch (e) {
      _stopLocal();
      return false;
    }
  }

  Future<void> createPeer({
    required void Function(String kind, Map? payload) onSignal,
    required void Function() onConnected,
    required void Function() onDisconnected,
    bool polite = false,
  }) async {
    // Perfect-negotiation role for offer collisions: exactly one side (the
    // "polite" one) yields when both send an offer at once. The controller
    // derives it from the two user ids so both ends always agree.
    _polite = polite;
    // Reuse the live connection across re-offers. Recreating it on every
    // incoming offer tore down tracks/negotiation mid-call, which produced the
    // "setRemoteDescription ... wrong state stable" and m-line mismatch errors
    // and left the video tiles black.
    if (_pc != null) return;
    _remoteSet = false;
    _pendingIce.clear();
    final iceConfig = await AppConfig.fetchIceConfig();
    final pc = await createPeerConnection(iceConfig);
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      final c = candidate.candidate;
      if (c != null && c.isNotEmpty) {
        onSignal('ice', candidate.toMap());
      }
    };

    pc.onTrack = (e) {
      if (e.streams.isNotEmpty && e.streams.first.getVideoTracks().isNotEmpty) {
        remoteRenderer.srcObject = e.streams.first;
      }
    };

    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onConnected();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        onDisconnected();
      }
    };

    pc.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        onDisconnected();
      }
    };

    // Always pass the local stream to addTrack: flutter_webrtc builds the
    // native `streamIds` argument as [stream?.id], so calling addTrack(track)
    // with no stream sends a list containing null. On Android that null hits
    // JniHelper.getStringBytes(null) -> NullPointerException inside the JNI
    // callback, which cannot be thrown across the boundary and aborts the
    // process (nativeAddTrack -> jvm.cc "Check failed: false" -> SIGABRT).
    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }
    }
  }

  Future<RTCSessionDescription?> createOffer() async {
    final pc = _pc;
    if (pc == null) return null;
    // Never fire a fresh offer while a negotiation is already in flight: that
    // is exactly the offer/offer glare that yields the m-line order errors.
    if (await pc.getSignalingState() != RTCSignalingState.RTCSignalingStateStable) {
      return null;
    }
    final desc = await pc.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
    await pc.setLocalDescription(desc);
    return desc;
  }

  Future<RTCSessionDescription?> createAnswer() async {
    final pc = _pc;
    if (pc == null) return null;
    // Only answer when we actually hold a remote offer.
    if (await pc.getSignalingState() !=
        RTCSignalingState.RTCSignalingStateHaveRemoteOffer) {
      return null;
    }
    final desc = await pc.createAnswer({'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
    await pc.setLocalDescription(desc);
    return desc;
  }

  Future<void> setRemoteOffer(Map<String, dynamic> m) => _setRemote(m);
  Future<void> setRemoteAnswer(Map<String, dynamic> m) => _setRemote(m);

  Future<void> _setRemote(Map<String, dynamic> m) async {
    final pc = _pc;
    if (pc == null) return;
    final sdp = '${m['sdp'] ?? ''}';
    if (sdp.isEmpty) return; // ignore a malformed/empty description
    final type = (m['type'] as String?) == 'offer' ? 'offer' : 'answer';
    final state = await pc.getSignalingState();
    if (type == 'answer') {
      // A duplicate/stale answer arrives when we are back in 'stable', and
      // applying it throws "Called in wrong state: stable". Only accept an
      // answer while it can match an outstanding local offer.
      if (state != RTCSignalingState.RTCSignalingStateHaveLocalOffer) return;
    } else if (state == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      // Offer collision (both ends offered). The impolite peer ignores the
      // incoming offer and keeps its own; the polite peer rolls its offer back
      // (implicit rollback in setRemoteDescription) and accepts theirs.
      if (!_polite) return;
    }
    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    _remoteSet = true;
    await _flushIce();
  }

  Future<void> addRemoteIce(Map<String, dynamic> m) async {
    final pc = _pc;
    final candidate = RTCIceCandidate(
      '${m['candidate'] ?? ''}',
      m['sdpMid'] as String?,
      (m['sdpMLineIndex'] as num?)?.toInt(),
    );
    if (pc != null && _remoteSet) {
      await pc.addCandidate(candidate);
    } else {
      _pendingIce.add(candidate);
    }
  }

  Future<void> _flushIce() async {
    final pc = _pc;
    if (pc == null) return;
    final queued = List<RTCIceCandidate>.from(_pendingIce);
    _pendingIce.clear();
    for (final c in queued) {
      try {
        await pc.addCandidate(c);
      } catch (_) {}
    }
  }

  Future<void> toggleMic() async {
    _micEnabled = !_micEnabled;
    for (final t in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = _micEnabled;
    }
  }

  Future<void> toggleCamera() async {
    _videoEnabled = !_videoEnabled;
    for (final t in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = _videoEnabled;
    }
  }

  Future<void> switchCamera() async {
    for (final t in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      if (t.kind == 'video') {
        await Helper.switchCamera(t);
      }
    }
  }

  /// Video input devices the OS exposes (e.g. an attached webcam, or the
  /// GoPro Webcam virtual camera once its utility is running). Labels can be
  /// empty until a capture permission has been granted at least once.
  static Future<List<MediaDeviceInfo>> listCameras() => _listDevices('videoinput');

  /// Audio input devices the OS exposes.
  static Future<List<MediaDeviceInfo>> listMicrophones() => _listDevices('audioinput');

  static Future<List<MediaDeviceInfo>> _listDevices(String kind) async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      return devices
          .where((d) => d.kind == kind && d.deviceId.isNotEmpty)
          .toList();
    } catch (_) {
      return const <MediaDeviceInfo>[];
    }
  }

  /// Uses [deviceId] for the camera from now on. When a call is live the
  /// current video track is hot-swapped so the remote peer sees the change
  /// without a renegotiation. Empty [deviceId] means "system default".
  Future<bool> useCamera(String deviceId) async {
    final pc = _pc;
    final stream = _localStream;
    if (pc == null || stream == null || stream.getVideoTracks().isEmpty) {
      await AppConfig.setCameraId(deviceId);
      return true;
    }
    try {
      final cam = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': deviceId.isEmpty
            ? {'facingMode': 'user', 'width': 1280, 'height': 720}
            : {'deviceId': {'exact': deviceId}, 'width': 1280, 'height': 720},
      });
      final newTrack = cam.getVideoTracks().first;
      newTrack.enabled = _videoEnabled;
      await _swapTrack(pc, stream, newTrack, 'video');
      localRenderer.srcObject = null;
      localRenderer.srcObject = stream;
      await AppConfig.setCameraId(deviceId);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Uses [deviceId] for the microphone from now on, hot-swapping the live
  /// audio track when a call is in progress. Empty [deviceId] means "default".
  Future<bool> useMicrophone(String deviceId) async {
    final pc = _pc;
    final stream = _localStream;
    if (pc == null || stream == null || stream.getAudioTracks().isEmpty) {
      await AppConfig.setMicId(deviceId);
      return true;
    }
    try {
      final mic = await navigator.mediaDevices.getUserMedia({
        'video': false,
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
          if (deviceId.isNotEmpty) 'deviceId': {'exact': deviceId},
        },
      });
      final newTrack = mic.getAudioTracks().first;
      newTrack.enabled = _micEnabled;
      await _swapTrack(pc, stream, newTrack, 'audio');
      await AppConfig.setMicId(deviceId);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _swapTrack(
    RTCPeerConnection pc,
    MediaStream stream,
    MediaStreamTrack track,
    String kind,
  ) async {
    var replaced = false;
    for (final sender in await pc.getSenders()) {
      if (sender.track?.kind == kind) {
        await sender.replaceTrack(track);
        replaced = true;
      }
    }
    if (!replaced) {
      await pc.addTrack(track, stream);
    }
    final olds =
        kind == 'video' ? stream.getVideoTracks() : stream.getAudioTracks();
    for (final old in olds) {
      await stream.removeTrack(old);
      await old.stop();
    }
    await stream.addTrack(track);
  }

  Future<void> closePeer() async {
    final pc = _pc;
    _pc = null;
    _remoteSet = false;
    _pendingIce.clear();
    if (pc != null) {
      pc.onIceCandidate = null;
      pc.onTrack = null;
      pc.onConnectionState = null;
      pc.onIceConnectionState = null;
      await pc.close();
    }
    remoteRenderer.srcObject = null;
  }

  Future<void> _stopLocal() async {
    localRenderer.srcObject = null;
    final stream = _localStream;
    if (stream != null) {
      for (final t in stream.getTracks()) {
        await t.stop();
      }
      _localStream = null;
    }
    _videoEnabled = false;
  }

  Future<void> stop() async {
    await closePeer();
    await _stopLocal();
  }
}