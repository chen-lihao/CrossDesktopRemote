import 'dart:async';

import 'package:cross_desktop_remote/core/audio/remote_audio_playout_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class _FakePlayoutPlatform implements RemoteAudioPlayoutPlatform {
  int activations = 0;
  int deactivations = 0;
  final List<bool> mutedStates = [];
  Completer<void>? muteGate;

  @override
  Future<void> activateSharedPlayout() async {
    activations += 1;
  }

  @override
  Future<void> releaseSharedPlayoutPolicy() async {
    deactivations += 1;
  }

  @override
  Future<void> setTrackMuted(MediaStreamTrack track, bool muted) async {
    mutedStates.add(muted);
    await muteGate?.future;
  }
}

class _FakeMediaStreamTrack extends Fake implements MediaStreamTrack {}

void main() {
  test('remote-only Apple policy is playback mixing without voice mode', () {
    final configuration =
        AppleNativeAudioManagement.getAppleAudioConfigurationForMode(
          AppleAudioIOMode.remoteOnly,
        );

    expect(configuration.appleAudioCategory, AppleAudioCategory.playback);
    expect(configuration.appleAudioMode, AppleAudioMode.default_);
    expect(
      configuration.appleAudioCategoryOptions,
      contains(AppleAudioCategoryOption.mixWithOthers),
    );
    expect(
      configuration.appleAudioCategoryOptions,
      isNot(contains(AppleAudioCategoryOption.duckOthers)),
    );
  });

  test(
    'keeps process playback active until the final owner releases it',
    () async {
      final platform = _FakePlayoutPlatform();
      final coordinator = RemoteAudioPlayoutCoordinator(platform: platform);

      final first = await coordinator.acquire();
      final second = await coordinator.acquire();

      expect(platform.activations, 1);
      expect(coordinator.activeLeaseCount, 2);

      await first.release();
      expect(coordinator.activeLeaseCount, 1);
      expect(platform.deactivations, 0);

      await second.release();
      expect(coordinator.activeLeaseCount, 0);
      expect(platform.deactivations, 1);
    },
  );

  test('release is idempotent and a later session activates again', () async {
    final platform = _FakePlayoutPlatform();
    final coordinator = RemoteAudioPlayoutCoordinator(platform: platform);

    final first = await coordinator.acquire();
    await first.release();
    await first.release();
    final second = await coordinator.acquire();

    expect(platform.activations, 2);
    expect(platform.deactivations, 1);

    await second.release();
    expect(coordinator.activeLeaseCount, 0);
    expect(platform.deactivations, 2);
  });

  test(
    'drain waits for accepted gain changes before native teardown',
    () async {
      final platform = _FakePlayoutPlatform();
      final gate = Completer<void>();
      platform.muteGate = gate;
      final coordinator = RemoteAudioPlayoutCoordinator(platform: platform);

      final mutation = coordinator.setTrackMuted(_FakeMediaStreamTrack(), true);
      var drained = false;
      final drain = coordinator.drain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);

      expect(drained, isFalse);
      gate.complete();
      await mutation;
      await drain;
      expect(drained, isTrue);
    },
  );
}
