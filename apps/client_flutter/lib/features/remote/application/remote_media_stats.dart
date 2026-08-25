import 'dart:math' as math;

import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';

class RemoteMediaStatsSnapshot {
  const RemoteMediaStatsSnapshot({
    required this.sampledAt,
    this.framesPerSecond,
    this.framesEncoded,
    this.framesDecoded,
    this.framesDropped,
    this.freezeCount,
    this.keyFramesEncoded,
    this.keyFramesDecoded,
    this.totalEncodeTimeSeconds,
    this.totalDecodeTimeSeconds,
    this.jitterBufferDelaySeconds,
    this.jitterBufferEmittedCount,
    this.bytesSent,
    this.bytesReceived,
    this.packetsLost,
    this.packetsReceived,
    this.fractionLost,
    this.nackCount,
    this.pliCount,
    this.firCount,
    this.networkRoundTripMs,
    this.availableOutgoingBitrateMbps,
    this.qualityLimitationReason,
    this.codec,
    this.encoderImplementation,
    this.decoderImplementation,
  });

  factory RemoteMediaStatsSnapshot.fromReports(
    Iterable<Map<dynamic, dynamic>> reports, {
    DateTime? sampledAt,
  }) {
    final list = reports.toList(growable: false);
    final codecs = <String, Map<dynamic, dynamic>>{
      for (final report in list)
        if (report['type'] == 'codec' && report['id'] is String)
          report['id'] as String: report,
    };
    Map<dynamic, dynamic>? outbound;
    Map<dynamic, dynamic>? inbound;
    Map<dynamic, dynamic>? remoteInbound;
    Map<dynamic, dynamic>? candidatePair;
    for (final report in list) {
      final type = report['type'];
      final mediaType = report['kind'] ?? report['mediaType'];
      final isVideo = mediaType == null || mediaType == 'video';
      if (type == 'outbound-rtp' && isVideo) {
        outbound ??= report;
      } else if (type == 'inbound-rtp' && isVideo) {
        inbound ??= report;
      } else if (type == 'remote-inbound-rtp' && isVideo) {
        remoteInbound ??= report;
      } else if (type == 'candidate-pair' &&
          (report['nominated'] == true || report['selected'] == true) &&
          report['state'] == 'succeeded') {
        candidatePair ??= report;
      }
    }

    final primary = outbound ?? inbound;
    final codecId = primary?['codecId'] as String?;
    final codecReport = codecId == null ? null : codecs[codecId];
    final mimeType = codecReport?['mimeType'] as String?;
    final fmtp = codecReport?['sdpFmtpLine'] as String?;
    final codec = mimeType == null
        ? null
        : fmtp == null || fmtp.isEmpty
        ? mimeType
        : '$mimeType · $fmtp';
    final remoteFractionLost = (remoteInbound?['fractionLost'] as num?)
        ?.toDouble();
    final inboundPacketsLost = (inbound?['packetsLost'] as num?)?.toInt();
    final remotePacketsLost = (remoteInbound?['packetsLost'] as num?)?.toInt();
    final candidateRtt = (candidatePair?['currentRoundTripTime'] as num?)
        ?.toDouble();
    final remoteRtt = (remoteInbound?['roundTripTime'] as num?)?.toDouble();

    return RemoteMediaStatsSnapshot(
      sampledAt: sampledAt ?? DateTime.now(),
      framesPerSecond:
          (outbound?['framesPerSecond'] as num?)?.toDouble() ??
          (inbound?['framesPerSecond'] as num?)?.toDouble(),
      framesEncoded: (outbound?['framesEncoded'] as num?)?.toInt(),
      framesDecoded: (inbound?['framesDecoded'] as num?)?.toInt(),
      framesDropped: (inbound?['framesDropped'] as num?)?.toInt(),
      freezeCount: (inbound?['freezeCount'] as num?)?.toInt(),
      keyFramesEncoded: (outbound?['keyFramesEncoded'] as num?)?.toInt(),
      keyFramesDecoded: (inbound?['keyFramesDecoded'] as num?)?.toInt(),
      totalEncodeTimeSeconds: (outbound?['totalEncodeTime'] as num?)
          ?.toDouble(),
      totalDecodeTimeSeconds: (inbound?['totalDecodeTime'] as num?)?.toDouble(),
      jitterBufferDelaySeconds: (inbound?['jitterBufferDelay'] as num?)
          ?.toDouble(),
      jitterBufferEmittedCount: (inbound?['jitterBufferEmittedCount'] as num?)
          ?.toInt(),
      bytesSent: (outbound?['bytesSent'] as num?)?.toInt(),
      bytesReceived: (inbound?['bytesReceived'] as num?)?.toInt(),
      packetsLost: inboundPacketsLost ?? remotePacketsLost,
      packetsReceived: (inbound?['packetsReceived'] as num?)?.toInt(),
      fractionLost: remoteFractionLost,
      nackCount:
          (inbound?['nackCount'] as num?)?.toInt() ??
          (outbound?['nackCount'] as num?)?.toInt(),
      pliCount:
          (inbound?['pliCount'] as num?)?.toInt() ??
          (outbound?['pliCount'] as num?)?.toInt(),
      firCount:
          (inbound?['firCount'] as num?)?.toInt() ??
          (outbound?['firCount'] as num?)?.toInt(),
      networkRoundTripMs: (candidateRtt ?? remoteRtt) == null
          ? null
          : (candidateRtt ?? remoteRtt)! * 1000,
      availableOutgoingBitrateMbps:
          (candidatePair?['availableOutgoingBitrate'] as num?)?.toDouble() ==
              null
          ? null
          : (candidatePair!['availableOutgoingBitrate'] as num).toDouble() /
                1000000,
      qualityLimitationReason: outbound?['qualityLimitationReason'] as String?,
      codec: codec,
      encoderImplementation: outbound?['encoderImplementation'] as String?,
      decoderImplementation: inbound?['decoderImplementation'] as String?,
    );
  }

  final DateTime sampledAt;
  final double? framesPerSecond;
  final int? framesEncoded;
  final int? framesDecoded;
  final int? framesDropped;
  final int? freezeCount;
  final int? keyFramesEncoded;
  final int? keyFramesDecoded;
  final double? totalEncodeTimeSeconds;
  final double? totalDecodeTimeSeconds;
  final double? jitterBufferDelaySeconds;
  final int? jitterBufferEmittedCount;
  final int? bytesSent;
  final int? bytesReceived;
  final int? packetsLost;
  final int? packetsReceived;
  final double? fractionLost;
  final int? nackCount;
  final int? pliCount;
  final int? firCount;
  final double? networkRoundTripMs;
  final double? availableOutgoingBitrateMbps;
  final String? qualityLimitationReason;
  final String? codec;
  final String? encoderImplementation;
  final String? decoderImplementation;
}

class RemoteMediaStatsAccumulator {
  RemoteMediaStatsSnapshot? _previous;

  RemoteMediaDiagnostics update(RemoteMediaStatsSnapshot current) {
    final previous = _previous;
    _previous = current;
    final elapsedSeconds = previous == null
        ? null
        : current.sampledAt.difference(previous.sampledAt).inMicroseconds /
              1000000;
    final encodeMs = _durationPerUnit(
      current.totalEncodeTimeSeconds,
      previous?.totalEncodeTimeSeconds,
      current.framesEncoded,
      previous?.framesEncoded,
    );
    final decodeMs = _durationPerUnit(
      current.totalDecodeTimeSeconds,
      previous?.totalDecodeTimeSeconds,
      current.framesDecoded,
      previous?.framesDecoded,
    );
    final jitterMs = _durationPerUnit(
      current.jitterBufferDelaySeconds,
      previous?.jitterBufferDelaySeconds,
      current.jitterBufferEmittedCount,
      previous?.jitterBufferEmittedCount,
    );
    final bytes = _positiveDelta(
      current.bytesSent ?? current.bytesReceived,
      previous == null ? null : previous.bytesSent ?? previous.bytesReceived,
    );
    final bitrateMbps =
        bytes == null || elapsedSeconds == null || elapsedSeconds <= 0
        ? null
        : bytes * 8 / elapsedSeconds / 1000000;
    final lostDelta = _positiveDelta(
      current.packetsLost,
      previous?.packetsLost,
    );
    final receivedDelta = _positiveDelta(
      current.packetsReceived,
      previous?.packetsReceived,
    );
    double? lossPercent;
    if (lostDelta != null && receivedDelta != null) {
      final total = lostDelta + receivedDelta;
      if (total > 0) lossPercent = lostDelta * 100 / total;
    }
    lossPercent ??= current.fractionLost == null
        ? null
        : current.fractionLost!.clamp(0, 1) * 100;

    return RemoteMediaDiagnostics(
      framesPerSecond: current.framesPerSecond,
      encodeMsPerFrame: encodeMs,
      decodeMsPerFrame: decodeMs,
      jitterBufferMsPerFrame: jitterMs,
      networkRoundTripMs: current.networkRoundTripMs,
      packetsLost: current.packetsLost,
      packetLossPercent: lossPercent,
      bitrateMbps: bitrateMbps,
      availableOutgoingBitrateMbps: current.availableOutgoingBitrateMbps,
      framesDroppedDelta: _positiveDelta(
        current.framesDropped,
        previous?.framesDropped,
      ),
      freezeCountDelta: _positiveDelta(
        current.freezeCount,
        previous?.freezeCount,
      ),
      keyFramesEncoded: current.keyFramesEncoded,
      keyFramesDecoded: current.keyFramesDecoded,
      keyFramesEncodedDelta: _positiveDelta(
        current.keyFramesEncoded,
        previous?.keyFramesEncoded,
      ),
      keyFramesDecodedDelta: _positiveDelta(
        current.keyFramesDecoded,
        previous?.keyFramesDecoded,
      ),
      nackCountDelta: _positiveDelta(current.nackCount, previous?.nackCount),
      pliCountDelta: _positiveDelta(current.pliCount, previous?.pliCount),
      firCountDelta: _positiveDelta(current.firCount, previous?.firCount),
      codec: current.codec,
      encoderImplementation: current.encoderImplementation,
      decoderImplementation: current.decoderImplementation,
      qualityLimitationReason: current.qualityLimitationReason,
    );
  }

  void reset() => _previous = null;

  static int? _positiveDelta(int? current, int? previous) {
    if (current == null || previous == null) return null;
    return math.max(0, current - previous);
  }

  static double? _durationPerUnit(
    double? currentDuration,
    double? previousDuration,
    int? currentCount,
    int? previousCount,
  ) {
    if (currentDuration == null || currentCount == null) return null;
    if (previousDuration == null || previousCount == null) {
      return currentCount <= 0 ? null : currentDuration * 1000 / currentCount;
    }
    final countDelta = currentCount - previousCount;
    final durationDelta = currentDuration - previousDuration;
    if (countDelta <= 0 || durationDelta < 0) return null;
    return durationDelta * 1000 / countDelta;
  }
}
