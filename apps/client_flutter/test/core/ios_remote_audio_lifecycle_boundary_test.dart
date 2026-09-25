import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _readProjectFile(String relativePath) =>
    File(relativePath).readAsStringSync();

void main() {
  test(
    'iOS keeps the WebRTC AudioEngine playout used by the audible baseline',
    () {
      final plugin = _readProjectFile(
        '../../third_party/flutter_webrtc/ios/flutter_webrtc/Sources/'
        'flutter_webrtc/FlutterWebRTCPlugin.m',
      );

      expect(
        plugin,
        contains(
          'RTCAudioDeviceModuleType audioDeviceModuleType = '
          'RTCAudioDeviceModuleTypeAudioEngine;',
        ),
      );
      expect(plugin, isNot(contains('FlutterRTCPlaybackAudioDevice')));
    },
  );

  test('remote session has one terminal PeerConnection operation', () {
    final controller = _readProjectFile(
      'lib/features/remote/application/remote_session_controller.dart',
    );

    expect(controller, contains('await peerConnection?.dispose();'));
    expect(controller, isNot(contains('await _peerConnection?.close();')));
    expect(
      controller,
      isNot(contains('await videoSender?.replaceTrack(null);')),
      reason:
          'Terminal video teardown is owned by PeerConnection.dispose(); '
          'pre-detaching the live ScreenCaptureKit track can over-release it.',
    );
    expect(
      controller.indexOf('await peerConnection?.dispose();'),
      lessThan(
        controller.indexOf('await _disposeMediaStream(localVideoStream);'),
      ),
      reason:
          'The capture stream must outlive the PeerConnection sender graph.',
    );
    expect(controller, contains('Future<void>? _closeSessionFuture;'));
  });

  test('Dart playout leases never deactivate the native audio session', () {
    final coordinator = _readProjectFile(
      'lib/core/audio/remote_audio_playout_coordinator.dart',
    );

    expect(coordinator, isNot(contains('deactivateAppleAudioSession')));
    expect(coordinator, isNot(contains('deactivateSharedPlayout')));
  });

  test('iOS declares the privacy key required by the WebRTC AudioEngine', () {
    final infoPlist = _readProjectFile('ios/Runner/Info.plist');

    expect(infoPlist, contains('<key>NSMicrophoneUsageDescription</key>'));
  });
}
