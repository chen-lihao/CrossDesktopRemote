import 'package:cross_desktop_remote/core/audio/system_audio_capture_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('systemAudioCaptureBackendFor', () {
    test('keeps the verified Windows loopback backend enabled', () {
      expect(
        systemAudioCaptureBackendFor('windows'),
        SystemAudioCaptureBackend.windowsLoopback,
      );
    });

    test('routes macOS through the microphone-free external ADM', () {
      expect(
        systemAudioCaptureBackendFor('macos'),
        SystemAudioCaptureBackend.appleExternalAdm,
      );
    });

    test('does not accidentally advertise capture on other platforms', () {
      for (final platform in ['ios', 'android', 'linux', 'web', '']) {
        expect(
          systemAudioCaptureBackendFor(platform),
          SystemAudioCaptureBackend.unsupported,
          reason: platform,
        );
      }
    });
  });

  group('isCompatibleAppleSystemAudioBackendInfo', () {
    test('accepts the capture-clock render-block external ADM', () {
      expect(
        isCompatibleAppleSystemAudioBackendInfo(const {
          'backend': 'screen-capture-kit-external-adm',
          'version': 3,
          'microphoneFree': true,
          'deliveryMode': 'capture-clock-render-block',
          'frameDurationMs': 10,
        }),
        isTrue,
      );
    });

    test('fails closed for stale or incomplete native backends', () {
      for (final info in <Map<String, dynamic>>[
        const {},
        const {
          'backend': 'screen-capture-kit-external-adm',
          'version': 1,
          'microphoneFree': true,
          'frameDurationMs': 10,
        },
        const {
          'backend': 'screen-capture-kit-external-adm',
          'version': 3,
          'microphoneFree': false,
          'deliveryMode': 'capture-clock-render-block',
          'frameDurationMs': 10,
        },
        const {
          'backend': 'screen-capture-kit-external-adm',
          'version': 3,
          'microphoneFree': true,
          'deliveryMode': 'capture-clock-render-block',
          'frameDurationMs': 20,
        },
        const {
          'backend': 'screen-capture-kit-external-adm',
          'version': 3,
          'microphoneFree': true,
          'deliveryMode': 'timer-ring-buffer',
          'frameDurationMs': 10,
        },
      ]) {
        expect(isCompatibleAppleSystemAudioBackendInfo(info), isFalse);
      }
    });
  });
}
