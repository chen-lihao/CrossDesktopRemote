import 'package:cross_desktop_remote/features/remote/application/remote_media_stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses interval deltas for latency, bitrate, loss, and key frames', () {
    final accumulator = RemoteMediaStatsAccumulator();
    final startedAt = DateTime(2026, 8, 24, 12);
    accumulator.update(
      RemoteMediaStatsSnapshot(
        sampledAt: startedAt,
        framesEncoded: 100,
        keyFramesEncoded: 2,
        totalEncodeTimeSeconds: 1,
        bytesSent: 1000000,
        packetsLost: 10,
        packetsReceived: 990,
        nackCount: 2,
        pliCount: 1,
        firCount: 0,
      ),
    );

    final result = accumulator.update(
      RemoteMediaStatsSnapshot(
        sampledAt: startedAt.add(const Duration(seconds: 1)),
        framesPerSecond: 30,
        framesEncoded: 130,
        keyFramesEncoded: 3,
        totalEncodeTimeSeconds: 1.12,
        bytesSent: 1750000,
        packetsLost: 12,
        packetsReceived: 1088,
        nackCount: 5,
        pliCount: 2,
        firCount: 1,
      ),
    );

    expect(result.encodeMsPerFrame, closeTo(4, 0.001));
    expect(result.bitrateMbps, closeTo(6, 0.001));
    expect(result.packetLossPercent, closeTo(2, 0.001));
    expect(result.keyFramesEncodedDelta, 1);
    expect(result.nackCountDelta, 3);
    expect(result.pliCountDelta, 1);
    expect(result.firCountDelta, 1);
  });

  test('correlates codec and selected candidate pair reports', () {
    final snapshot = RemoteMediaStatsSnapshot.fromReports([
      {
        'id': 'outbound',
        'type': 'outbound-rtp',
        'kind': 'video',
        'codecId': 'codec',
        'framesPerSecond': 30,
        'encoderImplementation': 'VideoToolbox',
      },
      {
        'id': 'codec',
        'type': 'codec',
        'mimeType': 'video/H264',
        'sdpFmtpLine': 'profile-level-id=42e01f',
      },
      {
        'id': 'pair',
        'type': 'candidate-pair',
        'selected': true,
        'state': 'succeeded',
        'currentRoundTripTime': 0.012,
        'availableOutgoingBitrate': 12000000,
      },
    ]);

    expect(snapshot.codec, contains('video/H264'));
    expect(snapshot.encoderImplementation, 'VideoToolbox');
    expect(snapshot.networkRoundTripMs, 12);
    expect(snapshot.availableOutgoingBitrateMbps, 12);
  });
}
