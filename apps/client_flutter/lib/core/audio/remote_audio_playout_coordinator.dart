import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Owns the process-wide playback policy used while one or more remote desktop
/// sessions are receiving audio. AVAudioSession is process-wide on iOS, so a
/// per-session boolean is not sufficient when multiple Flutter views exist.
abstract interface class RemoteAudioPlayoutPlatform {
  Future<void> activateSharedPlayout();

  Future<void> setTrackMuted(MediaStreamTrack track, bool muted);

  Future<void> releaseSharedPlayoutPolicy();
}

class FlutterWebRtcRemoteAudioPlayoutPlatform
    implements RemoteAudioPlayoutPlatform {
  const FlutterWebRtcRemoteAudioPlayoutPlatform();

  @override
  Future<void> activateSharedPlayout() async {
    if (Platform.isIOS) {
      await Helper.setAppleAudioIOMode(AppleAudioIOMode.remoteOnly);
      return;
    }
    // Windows playout routing is owned by the native ADM. Switching its device
    // from Dart while playout is active races peer connection teardown and can
    // crash the process. The ADM follows the Windows default render endpoint.
  }

  @override
  Future<void> setTrackMuted(MediaStreamTrack track, bool muted) async {
    if (Platform.isWindows) {
      // A receiving track must remain enabled so the jitter buffer and decoder
      // stay warm. RTCAudioTrack::SetVolume is the native per-track playout
      // control; toggling MediaStreamTrack.enabled is a sender-oriented API and
      // is not a reliable mute mechanism on the Windows ADM.
      await Helper.setVolume(muted ? 0 : 1, track);
      return;
    }
    track.enabled = !muted;
  }

  @override
  Future<void> releaseSharedPlayoutPolicy() async {
    // No process-wide Windows policy is retained. iOS teardown remains owned
    // by flutter_webrtc together with the final peer connection.
  }
}

class RemoteAudioPlayoutLease {
  RemoteAudioPlayoutLease._(this._owner, this._token);

  final RemoteAudioPlayoutCoordinator _owner;
  final int _token;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _owner._release(_token);
  }
}

class RemoteAudioPlayoutCoordinator {
  RemoteAudioPlayoutCoordinator({RemoteAudioPlayoutPlatform? platform})
    : _platform = platform ?? const FlutterWebRtcRemoteAudioPlayoutPlatform();

  static final RemoteAudioPlayoutCoordinator instance =
      RemoteAudioPlayoutCoordinator();

  final RemoteAudioPlayoutPlatform _platform;
  final Set<int> _owners = <int>{};
  Future<void> _mutation = Future<void>.value();
  int _nextToken = 0;

  int get activeLeaseCount => _owners.length;

  Future<void> setTrackMuted(MediaStreamTrack track, bool muted) =>
      _enqueue(() => _platform.setTrackMuted(track, muted));

  /// Waits until all already accepted playout mutations have completed.
  /// Callers use this before disposing the peer connection that owns a track.
  Future<void> drain() => _enqueue(() async {});

  Future<RemoteAudioPlayoutLease> acquire() {
    final completer = Completer<RemoteAudioPlayoutLease>();
    _mutation = _mutation
        .then((_) async {
          final token = ++_nextToken;
          if (_owners.isEmpty) {
            await _platform.activateSharedPlayout();
          }
          _owners.add(token);
          completer.complete(RemoteAudioPlayoutLease._(this, token));
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        });
    return completer.future;
  }

  Future<void> _release(int token) {
    final completer = Completer<void>();
    _mutation = _mutation
        .then((_) async {
          if (!_owners.remove(token)) {
            completer.complete();
            return;
          }
          // The WebRTC plugin owns AVAudioSession teardown together with the
          // final RTCPeerConnection. Releasing a Dart-side policy lease must
          // never race that native teardown or deactivate audio for another
          // Flutter view. A later first owner reapplies the playback policy.
          if (_owners.isEmpty) {
            await _platform.releaseSharedPlayoutPolicy();
          }
          completer.complete();
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        });
    return completer.future;
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final completer = Completer<void>();
    _mutation = _mutation
        .then((_) => operation())
        .then((_) => completer.complete())
        .catchError((Object error, StackTrace stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        });
    return completer.future;
  }
}
