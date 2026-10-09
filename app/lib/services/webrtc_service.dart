import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../core/app_config.dart';

class WebRTCService {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  bool _remoteSet = false;
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
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': video
          ? {'facingMode': 'user', 'width': 1280, 'height': 720}
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
  }) async {
    await closePeer();
    _remoteSet = false;
    _pendingIce.clear();
    final pc = await createPeerConnection(AppConfig.callIceConfig());
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

    _localStream?.getTracks().forEach(pc.addTrack);
  }

  Future<RTCSessionDescription?> createOffer() async {
    final pc = _pc;
    if (pc == null) return null;
    final desc = await pc.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
    await pc.setLocalDescription(desc);
    return desc;
  }

  Future<RTCSessionDescription?> createAnswer() async {
    final pc = _pc;
    if (pc == null) return null;
    final desc = await pc.createAnswer({'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
    await pc.setLocalDescription(desc);
    return desc;
  }

  Future<void> setRemoteOffer(Map<String, dynamic> m) => _setRemote(m);
  Future<void> setRemoteAnswer(Map<String, dynamic> m) => _setRemote(m);

  Future<void> _setRemote(Map<String, dynamic> m) async {
    final pc = _pc;
    if (pc == null) return;
    final type = (m['type'] as String?) == 'offer' ? 'offer' : 'answer';
    await pc.setRemoteDescription(RTCSessionDescription('${m['sdp'] ?? ''}', type));
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