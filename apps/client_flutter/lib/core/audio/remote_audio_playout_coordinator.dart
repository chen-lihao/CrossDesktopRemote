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
  FlutterWebRtcRemoteAudioPlayoutPlatform();

  Function(dynamic)? _previousDeviceChangeHandler;
  bool _followingWindowsDefaultOutput = false;
  Future<void> _outputMutation = Future<void>.value();

  @override
  Future<void> activateSharedPlayout() async {
    if (Platform.isIOS) {
      await Helper.setAppleAudioIOMode(AppleAudioIOMode.remoteOnly);
      return;
    }
    if (!Platform.isWindows || _followingWindowsDefaultOutput) return;
    _followingWindowsDefaultOutput = true;
    _previousDeviceChangeHandler = navigator.mediaDevices.ondevicechange;
    navigator.mediaDevices.ondevicechange = (event) {
      _previousDeviceChangeHandler?.call(event);
      unawaited(
        _scheduleWindowsDefaultOutputSelection().catchError((_) {
          // Device removal can race libwebrtc teardown. The next device event
          // or session activation resolves the current system default again.
        }),
      );
    };
    await _scheduleWindowsDefaultOutputSelection();
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
    if (!Platform.isWindows || !_followingWindowsDefaultOutput) return;
    navigator.mediaDevices.ondevicechange = _previousDeviceChangeHandler;
    _previousDeviceChangeHandler = null;
    _followingWindowsDefaultOutput = false;
    await _outputMutation;
  }

  Future<void> _scheduleWindowsDefaultOutputSelection() {
    final completion = Completer<void>();
    _outputMutation = _outputMutation
        .catchError((_) {})
        .then((_) => _selectWindowsDefaultOutput())
        .then((_) => completion.complete())
        .catchError((Object error, StackTrace stackTrace) {
          if (!completion.isCompleted) {
            completion.completeError(error, stackTrace);
          }
        });
    return completion.future;
  }

  Future<void> _selectWindowsDefaultOutput() async {
    if (!_followingWindowsDefaultOutput) return;
    final outputs = await Helper.audiooutputs;
    if (!_followingWindowsDefaultOutput || outputs.isEmpty) return;
    // libwebrtc exposes the system-default render endpoint as the first
    // playout device. Re-resolving it after onDeviceChange avoids persisting a
    // stale speaker GUID when the user connects headphones.
    await Helper.selectAudioOutput(outputs.first.deviceId);
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
    : _platform = platform ?? FlutterWebRtcRemoteAudioPlayoutPlatform();

  static final RemoteAudioPlayoutCoordinator instance =
      RemoteAudioPlayoutCoordinator();

  final RemoteAudioPlayoutPlatform _platform;
  final Set<int> _owners = <int>{};
  Future<void> _mutation = Future<void>.value();
  int _nextToken = 0;

  int get activeLeaseCount => _owners.length;

  Future<void> setTrackMuted(MediaStreamTrack track, bool muted) =>
      _enqueue(() => _platform.setTrackMuted(track, muted));

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
