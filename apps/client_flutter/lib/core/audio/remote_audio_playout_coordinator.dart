import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Owns the process-wide playback policy used while one or more remote desktop
/// sessions are receiving audio. AVAudioSession is process-wide on iOS, so a
/// per-session boolean is not sufficient when multiple Flutter views exist.
abstract interface class RemoteAudioPlayoutPlatform {
  Future<void> activateSharedPlayout();
}

class FlutterWebRtcRemoteAudioPlayoutPlatform
    implements RemoteAudioPlayoutPlatform {
  const FlutterWebRtcRemoteAudioPlayoutPlatform();

  @override
  Future<void> activateSharedPlayout() async {
    if (!Platform.isIOS) return;
    await Helper.setAppleAudioIOMode(AppleAudioIOMode.remoteOnly);
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
          completer.complete();
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        });
    return completer.future;
  }
}
