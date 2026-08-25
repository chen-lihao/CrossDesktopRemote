import 'package:cross_desktop_remote/features/remote/application/remote_quality_adaptation.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const good = RemoteMediaDiagnostics(
    framesPerSecond: 30,
    encodeMsPerFrame: 4,
    packetLossPercent: 0.1,
    networkRoundTripMs: 12,
    bitrateMbps: 4,
    availableOutgoingBitrateMbps: 20,
    qualityLimitationReason: 'none',
  );
  const bad = RemoteMediaDiagnostics(
    framesPerSecond: 18,
    encodeMsPerFrame: 20,
    packetLossPercent: 3,
    networkRoundTripMs: 120,
    bitrateMbps: 5,
    qualityLimitationReason: 'bandwidth',
  );

  test(
    'starts conservatively at 1080p30 and downgrades after two bad samples',
    () {
      final controller = RemoteQualityAdaptationController();
      expect(controller.tier, RemoteAdaptiveVideoTier.hd30);
      expect(controller.observe(bad), isNull);
      expect(controller.observe(bad), RemoteAdaptiveVideoTier.smooth60);
    },
  );

  test('requires sustained good samples and upgrade hysteresis', () {
    final controller = RemoteQualityAdaptationController();
    final startedAt = DateTime(2026, 8, 24, 12);
    controller.reset(now: startedAt);
    for (var index = 0; index < 9; index += 1) {
      expect(
        controller.observe(good, now: startedAt.add(Duration(seconds: index))),
        isNull,
      );
    }
    expect(
      controller.observe(good, now: startedAt.add(const Duration(seconds: 15))),
      RemoteAdaptiveVideoTier.hd60,
    );
  });

  test(
    'maps manual profiles to stable frame-rate or resolution priorities',
    () {
      final smooth = RemoteVideoTarget.forProfile(RemoteQualityProfile.smooth);
      final high = RemoteVideoTarget.forProfile(RemoteQualityProfile.high);
      expect(smooth.prioritizeFrameRate, isTrue);
      expect(smooth.maxFramerate, 60);
      expect(high.prioritizeFrameRate, isFalse);
      expect(high.maxFramerate, 30);
    },
  );
}
