import 'package:cross_desktop_remote/features/remote/application/remote_display_switch_geometry.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
