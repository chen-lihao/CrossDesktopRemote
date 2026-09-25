import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _source(String relativePath) => File(relativePath).readAsStringSync();

void main() {
  const pluginRoot =
      '../../third_party/flutter_webrtc/macos/flutter_webrtc/Sources/'
      'flutter_webrtc';
  const runnerSource = 'macos/Runner/MainFlutterWindow.swift';

  test('macOS system audio never creates an independent SCStream', () {
    final audioSource = _source('$pluginRoot/FlutterRTCSystemAudioCapturer.m');
    final screenSource = _source(
      '$pluginRoot/FlutterScreenCaptureKitCapturer.m',
    );

    expect(audioSource, isNot(contains('[[SCStream alloc]')));
    expect(
      audioSource,
      isNot(contains('getShareableContentExcludingDesktopWindows')),
    );
    expect(audioSource, contains('startSystemAudioWithDevice'));
    expect(screenSource, contains('SCStreamOutputTypeScreen'));
    expect(screenSource, contains('SCStreamOutputTypeAudio'));
    expect(screenSource, contains('consumeSystemAudioSampleBuffer'));
  });

  test(
    'the unified capturer drains audio before releasing the external ADM',
    () {
      final source = _source('$pluginRoot/FlutterScreenCaptureKitCapturer.m');
      final removeAudio = source.indexOf(
        'removeStreamOutput:self\n                            type:SCStreamOutputTypeAudio',
      );
      final stopCapture = source.indexOf(
        'stopCaptureWithCompletionHandler',
        removeAudio,
      );
      final detachAudio = source.indexOf(
        'detachSystemAudioSource',
        stopCapture,
      );

      expect(removeAudio, greaterThanOrEqualTo(0));
      expect(stopCapture, greaterThan(removeAudio));
      expect(detachAudio, greaterThan(stopCapture));
    },
  );

  test('getDisplayMedia resolves only after ScreenCaptureKit is running', () {
    final desktopSource = _source('$pluginRoot/FlutterRTCDesktopCapturer.m');
    final captureSource = _source(
      '$pluginRoot/FlutterScreenCaptureKitCapturer.m',
    );
    final systemAudioSource = _source(
      '$pluginRoot/FlutterRTCSystemAudioCapturer.m',
    );

    expect(
      desktopSource,
      contains('screenCaptureKitMediaResult = mediaResult'),
    );
    expect(desktopSource, contains('result(screenCaptureKitMediaResult)'));
    expect(
      captureSource,
      contains('self.captureLifecycleState = CDRCaptureLifecycleStateRunning'),
    );
    expect(captureSource, contains('- (BOOL)isCaptureRunning'));
    expect(
      systemAudioSource,
      contains('if (!screenCapturer.isCaptureRunning)'),
    );
  });

  test(
    'privacy windows have one ARC owner and disable AppKit auto release',
    () {
      final source = _source(runnerSource);

      expect(
        source,
        contains(
          'class CrossDesktopRemotePrivacyWindowController: NSWindowController',
        ),
      );
      expect(source, contains('privacyWindow.isReleasedWhenClosed = false'));
      expect(
        source,
        contains(
          'windowControllers: [CrossDesktopRemotePrivacyWindowController]',
        ),
      );
      expect(source, isNot(contains('private var windows: [NSWindow]')));
    },
  );

  test('all privacy-window teardown uses the controller close boundary', () {
    final source = _source(runnerSource);
    final closeBoundary = source.substring(
      source.indexOf('private func closePrivacyWindows()'),
      source.indexOf(
        '\n  }\n}\n\nfunc crossDesktopRemoteAbsolutePointerPosition',
      ),
    );

    expect(closeBoundary, contains('let controllers = windowControllers'));
    expect(closeBoundary, contains('windowControllers.removeAll'));
    expect(closeBoundary, contains('controller.closePrivacyWindow()'));
    expect(closeBoundary, isNot(contains('window.close()')));
  });
}
