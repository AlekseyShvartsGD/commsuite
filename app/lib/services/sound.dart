import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Plays the app's built-in sounds (synthesized WAV assets) on every platform.
/// The PC shows our own UI (no OS toast) — sound is the shared cue.
class SoundPlayer {
  static AudioPlayer? _ring;
  static AudioPlayer? _ding;
  static bool _ready = false;

  static AudioPlayer get _ringPlayer => _ring ??= AudioPlayer();
  static AudioPlayer get _dingPlayer => _ding ??= AudioPlayer();

  static Future<void> _prepare() async {
    if (_ready) return;
    _ready = true;
    try {
      await _ringPlayer.setReleaseMode(ReleaseMode.loop);
      await _ringPlayer.setVolume(0.85);
      await _dingPlayer.setReleaseMode(ReleaseMode.stop);
      await _dingPlayer.setVolume(0.7);
    } catch (e) {
      _debugPrint(e);
    }
  }

  static Future<void> startRing() async {
    try {
      await _prepare();
      await _ringPlayer.play(AssetSource('sounds/ring.wav'));
    } catch (e) {
      _debugPrint(e);
    }
  }

  static Future<void> stopRing() async {
    try {
      await _ring?.stop();
    } catch (_) {}
  }

  static Future<void> ding() async {
    try {
      await _prepare();
      await _dingPlayer.stop();
      await _dingPlayer.play(AssetSource('sounds/ding.wav'));
    } catch (e) {
      _debugPrint(e);
    }
  }

  /// Stops AND fully releases the native audio players so they cannot conflict
  /// with the camera/mic capture that starts right after (and to free memory
  /// at the exact point of the call transition). Safe to call any time.
  static Future<void> stopAndRelease() async {
    try {
      await _ring?.stop();
    } catch (_) {}
    try {
      await _ring?.dispose();
    } catch (_) {}
    try {
      await _ding?.dispose();
    } catch (_) {}
    _ring = null;
    _ding = null;
    _ready = false;
  }

  /// audioplayers/linux needs GStreamer at runtime; on desktop a failure to
  /// init the pipeline used to fail silently (no sound, no crash). Surface it
  /// so "why no ping?" is answerable from the app's own logs.
  ///
  /// On Linux the app links libgstreamer-1.0 + libgstapp/base, so the machine
  /// must have `libgstreamer1.0-0` and `libgstreamer-plugins-base1.0-0`
  /// installed (ubuntu/debian desktop installs usually already have them).
  static void _debugPrint(Object error) {
    final message = 'SoundPlayer error: $error';
    if (kDebugMode) {
      debugPrint(message);
      return;
    }
    try {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '.';
      final file = File('$home/.local/share/commsuite/sound.log');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
          '${DateTime.now().toIso8601String()} $message\n',
          mode: FileMode.append,
          flush: true);
    } catch (_) {}
  }
}