import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../core/app_config.dart';

/// One broadcaster fanning out to several viewers, plus the receive-only side
/// used by a viewer. Every peer connection is forced through the server TURN
/// relay: live media never goes directly between two devices.
///
/// Quality presets change the capture resolution; switching while live swaps
/// the track on every sender, so no renegotiation is needed and viewers keep
/// watching uninterrupted.
class BroadcastService {
  static const Map<String, Map<String, int>> _presets = {
    '480p': {'width': 854, 'height': 480},
    '720p': {'width': 1280, 'height': 720},
  };

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  final Map<String, _Peer> _peers = {};
  final Map<String, List<RTCIceCandidate>> _orphanIce = {};
  MediaStream? _localStream;
  Map<String, dynamic>? _iceConfig;
  bool _broadcaster = false;
  bool _micEnabled = true;
  bool _cameraEnabled = true;
  String _quality = '720p';
  bool _localRendererReady = false;
  bool _remoteRendererReady = false;

  /// Sends one signalling message to [to] (a viewer when broadcasting, or the
  /// broadcaster when watching).
  void Function(String to, String kind, Map<String, dynamic> payload)? onSignal;

  /// Broadcaster-side: a viewer's peer connection reached `connected`.
  void Function(String viewerId)? onViewerConnected;

  /// Broadcaster-side: a viewer's peer connection dropped.
  void Function(String viewerId)? onViewerDisconnected;

  /// Viewer-side: the broadcaster's media has been attached to
  /// [remoteRenderer]. The UI listens for this to replace its placeholder.
  void Function()? onRemoteStream;

  bool get broadcasting => _broadcaster;
  bool get micEnabled => _micEnabled;
  bool get cameraEnabled => _cameraEnabled;
  String get quality => _quality;
  Set<String> get connectedViewers => {
        for (final entry in _peers.entries)
          if (entry.value.connected) entry.key,
      };

  Future<void> _ensureLocalRenderer() async {
    if (_localRendererReady) return;
    await localRenderer.initialize();
    _localRendererReady = true;
  }

  Future<void> _ensureRemoteRenderer() async {
    if (_remoteRendererReady) return;
    await remoteRenderer.initialize();
    _remoteRendererReady = true;
  }

  Future<Map<String, dynamic>> _ice() async {
    if (_iceConfig != null) return _iceConfig!;
    final config = await AppConfig.fetchIceConfig();
    // Even if the server forgot the policy, never leak host/srflx candidates.
    _iceConfig = {...config, 'iceTransportPolicy': 'relay'};
    return _iceConfig!;
  }

  Future<bool> _capture(String quality) async {
    _quality = _presets.containsKey(quality) ? quality : '720p';
    final size = _presets[_quality]!;
    if (Platform.isAndroid) {
      final mic = await ph.Permission.microphone.request();
      final cam = await ph.Permission.camera.request();
      if (!mic.isGranted || !cam.isGranted) return false;
    }
    final constraints = <String, dynamic>{
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        if (AppConfig.micId.isNotEmpty) 'deviceId': {'ideal': AppConfig.micId},
      },
      'video': {
        'width': size['width'],
        'height': size['height'],
        if (AppConfig.cameraId.isNotEmpty)
          'deviceId': {'ideal': AppConfig.cameraId}
        else
          'facingMode': 'user',
      },
    };
    try {
      final stream = await navigator.mediaDevices.getUserMedia(constraints);
      final previous = _localStream;
      _localStream = stream;
      _micEnabled = true;
      _cameraEnabled = true;
      localRenderer.srcObject = stream;
      // Swap senders first, then release the old capture.
      for (final peer in _peers.values) {
        for (final sender in await peer.pc.getSenders()) {
          final kind = sender.track?.kind;
          if (kind == null) continue;
          final tracks =
              kind == 'video' ? stream.getVideoTracks() : stream.getAudioTracks();
          if (tracks.isNotEmpty) {
            try {
              await sender.replaceTrack(tracks.first);
            } catch (_) {}
          }
        }
      }
      if (previous != null && !identical(previous, stream)) {
        for (final track in previous.getTracks()) {
          await track.stop();
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Broadcaster: capture camera+mic and show the local preview.
  Future<bool> startBroadcast({String quality = '720p'}) async {
    _broadcaster = true;
    await _ensureLocalRenderer();
    await _ice();
    return _capture(quality);
  }

  /// Viewer: get the renderer and negotiation config ready. The actual peer is
  /// created when the broadcaster's offer arrives.
  Future<void> prepareWatching() async {
    _broadcaster = false;
    await _ensureRemoteRenderer();
    await _ice();
  }

  Future<void> _hookPeer(RTCPeerConnection pc, String peerId, {required bool sendLocal}) async {
    pc.onIceCandidate = (candidate) {
      final value = candidate.candidate;
      if (value == null || value.isEmpty) return;
      onSignal?.call(peerId, 'ice', candidate.toMap());
    };
    pc.onTrack = (e) async {
      if (sendLocal) return; // the broadcaster does not render remote video
      if (e.streams.isNotEmpty) {
        remoteRenderer.srcObject = e.streams.first;
      } else {
        final stream = await createLocalMediaStream('remote');
        await stream.addTrack(e.track);
        remoteRenderer.srcObject = stream;
      }
      onRemoteStream?.call();
    };
    pc.onConnectionState = (state) {
      final peer = _peers[peerId];
      if (peer == null) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        peer.connected = true;
        if (sendLocal) onViewerConnected?.call(peerId);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        peer.connected = false;
        if (sendLocal) onViewerDisconnected?.call(peerId);
      }
    };
  }

  Future<RTCPeerConnection> _createPeer(String peerId, {required bool sendLocal}) async {
    final pc = await createPeerConnection(await _ice());
    _peers[peerId] = _Peer(pc);
    await _hookPeer(pc, peerId, sendLocal: sendLocal);
    final stream = _localStream;
    if (sendLocal && stream != null) {
      // Always pass the stream: addTrack(track) alone sends a null stream id
      // and crashes the Android JNI callback.
      for (final track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }
    }
    return pc;
  }

  /// Broadcaster: start sending to one viewer and send them an offer.
  Future<void> addViewer(String viewerId) async {
    if (!_broadcaster || _localStream == null) return;
    final existing = _peers[viewerId];
    if (existing != null) return;
    final pc = await _createPeer(viewerId, sendLocal: true);
    final offer = await pc.createOffer({
      'offerToReceiveAudio': false,
      'offerToReceiveVideo': false,
    });
    await pc.setLocalDescription(offer);
    onSignal?.call(viewerId, 'offer', offer.toMap());
  }

  Future<void> removeViewer(String viewerId) async {
    final peer = _peers.remove(viewerId);
    if (peer == null) return;
    await _closePeer(peer);
  }

  Future<void> _closePeer(_Peer peer) async {
    peer.pc.onIceCandidate = null;
    peer.pc.onTrack = null;
    peer.pc.onConnectionState = null;
    try {
      await peer.pc.close();
    } catch (_) {}
  }

  /// Routes one signalling message from [from] (viewer id when broadcasting,
  /// broadcaster id when watching).
  Future<void> handleSignal(String from, String kind, Map<String, dynamic>? payload) async {
    if (kind == 'ice') {
      await _addIce(from, payload ?? const {});
      return;
    }
    if (_broadcaster) {
      final peer = _peers[from];
      if (peer == null) return;
      if (kind == 'answer') await _setRemote(peer, payload);
      return;
    }
    // Viewer: the broadcaster always offers.
    var peer = _peers[from];
    if (peer == null) {
      await _ensureRemoteRenderer();
      final pc = await _createPeer(from, sendLocal: false);
      peer = _peers[from]!;
      // Guard: closing the stream while awaiting the offer.
      if (!_peers.containsKey(from)) {
        await pc.close();
        return;
      }
      // Candidates that raced ahead of the offer wait here.
      for (final candidate in _orphanIce.remove(from) ?? const <RTCIceCandidate>[]) {
        peer.pendingIce.add(candidate);
      }
    }
    if (kind != 'offer') return;
    await _setRemote(peer, payload);
    if (await peer.pc.getSignalingState() !=
        RTCSignalingState.RTCSignalingStateHaveRemoteOffer) {
      return;
    }
    final answer = await peer.pc.createAnswer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });
    await peer.pc.setLocalDescription(answer);
    onSignal?.call(from, 'answer', answer.toMap());
  }

  Future<void> _setRemote(_Peer peer, Map<String, dynamic>? payload) async {
    final m = payload ?? const <String, dynamic>{};
    final sdp = '${m['sdp'] ?? ''}';
    if (sdp.isEmpty) return;
    final type = (m['type'] as String?) == 'offer' ? 'offer' : 'answer';
    final state = await peer.pc.getSignalingState();
    if (type == 'answer' &&
        state != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      return; // stale/duplicate answer
    }
    await peer.pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    peer.remoteSet = true;
    for (final candidate in peer.pendingIce) {
      try {
        await peer.pc.addCandidate(candidate);
      } catch (_) {}
    }
    peer.pendingIce.clear();
  }

  Future<void> _addIce(String from, Map<String, dynamic> payload) async {
    final peer = _peers[from];
    if (peer == null) {
      // Viewer side: offer and ICE travel as separate messages and may arrive
      // out of order. Keep early candidates until the offer creates the peer.
      if (!_broadcaster) {
        _orphanIce.putIfAbsent(from, () => []).add(
          RTCIceCandidate(
            '${payload['candidate'] ?? ''}',
            payload['sdpMid'] as String?,
            (payload['sdpMLineIndex'] as num?)?.toInt(),
          ),
        );
      }
      return;
    }
    final candidate = RTCIceCandidate(
      '${payload['candidate'] ?? ''}',
      payload['sdpMid'] as String?,
      (payload['sdpMLineIndex'] as num?)?.toInt(),
    );
    if (peer.remoteSet) {
      try {
        await peer.pc.addCandidate(candidate);
      } catch (_) {}
    } else {
      peer.pendingIce.add(candidate);
    }
  }

  Future<void> toggleMic() async {
    _micEnabled = !_micEnabled;
    for (final track
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = _micEnabled;
    }
  }

  Future<void> toggleCamera() async {
    _cameraEnabled = !_cameraEnabled;
    for (final track
        in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = _cameraEnabled;
    }
  }

  Future<void> switchCamera() async {
    for (final track
        in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      if (track.kind == 'video') {
        try {
          await Helper.switchCamera(track);
        } catch (_) {}
      }
    }
  }

  Future<bool> setQuality(String quality) async {
    if (quality == _quality) return true;
    return _capture(quality);
  }

  Future<void> stop() async {
    for (final peer in _peers.values) {
      await _closePeer(peer);
    }
    _peers.clear();
    _orphanIce.clear();
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
    }
    _broadcaster = false;
    _cameraEnabled = true;
    _micEnabled = true;
  }
}

class _Peer {
  _Peer(this.pc);

  final RTCPeerConnection pc;
  final List<RTCIceCandidate> pendingIce = [];
  bool remoteSet = false;
  bool connected = false;
}
