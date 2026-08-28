import 'package:cross_desktop_remote/features/remote/application/remote_display_switch_geometry.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('old geometry cannot re-enter after switching back to a display', () {
    const oldMainGeometry = RemoteFrameGeometry(
      displayId: 'main',
      generation: 1,
      logicalWidth: 1920,
      logicalHeight: 1080,
      captureWidth: 1920,
      captureHeight: 1080,
      encodedWidth: 1920,
      encodedHeight: 1080,
      activeContentX: 0,
      activeContentY: 0,
      activeContentWidth: 1920,
      activeContentHeight: 1080,
    );

    expect(
      oldMainGeometry.belongsTo(displayId: 'main', generation: 3),
      isFalse,
      reason: 'display id alone is ambiguous after main-secondary-main',
    );
    expect(oldMainGeometry.belongsTo(displayId: 'main', generation: 1), isTrue);
    expect(
      oldMainGeometry
          .withGeneration(3)
          .belongsTo(displayId: 'main', generation: 3),
      isTrue,
      reason: 'an explicit failed-switch rollback may retain proven geometry',
    );
  });

  test(
    'rejects a new key frame that still uses the previous display aspect',
    () {
      final gate = RemoteVideoGeometryGate(
        target: const RemoteVideoFrameSize(width: 1311, height: 892),
      );

      expect(
        gate.observe(
          size: const RemoteVideoFrameSize(width: 1920, height: 1080),
          frames: 101,
          mediaAdvanced: true,
          keyFrameAdvanced: true,
        ),
        isFalse,
      );
    },
  );

  test('requires two new frame samples at a stable target geometry', () {
    final gate = RemoteVideoGeometryGate(
      target: const RemoteVideoFrameSize(width: 1311, height: 892),
    );
    const adapted = RemoteVideoFrameSize(width: 1280, height: 870);

    expect(
      gate.observe(
        size: adapted,
        frames: 102,
        mediaAdvanced: true,
        keyFrameAdvanced: true,
      ),
      isFalse,
    );
    expect(
      gate.observe(
        size: adapted,
        frames: 102,
        mediaAdvanced: true,
        keyFrameAdvanced: true,
      ),
      isFalse,
      reason: 're-reading the same RTP stats sample is not a new video frame',
    );
    expect(
      gate.observe(
        size: adapted,
        frames: 103,
        mediaAdvanced: true,
        keyFrameAdvanced: true,
      ),
      isTrue,
    );
  });
}
