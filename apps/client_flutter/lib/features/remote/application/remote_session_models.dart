class RemoteDisplay {
  const RemoteDisplay({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.isPrimary,
    this.pixelWidth = 0,
    this.pixelHeight = 0,
    this.pointPixelScale = 1,
  });

  factory RemoteDisplay.fromMessage(Map<String, dynamic> message) {
    return RemoteDisplay(
      id: message['id'] as String,
      name: message['name'] as String? ?? 'Display',
      width: (message['width'] as num?)?.toInt() ?? 0,
      height: (message['height'] as num?)?.toInt() ?? 0,
      pixelWidth: (message['pixelWidth'] as num?)?.toInt() ?? 0,
      pixelHeight: (message['pixelHeight'] as num?)?.toInt() ?? 0,
      pointPixelScale: (message['pointPixelScale'] as num?)?.toDouble() ?? 1,
      isPrimary: message['isPrimary'] as bool? ?? false,
    );
  }

  final String id;
  final String name;
  final int width;
  final int height;
  final int pixelWidth;
  final int pixelHeight;
  final double pointPixelScale;
  final bool isPrimary;

  int get captureWidth => pixelWidth > 0 ? pixelWidth : width;
  int get captureHeight => pixelHeight > 0 ? pixelHeight : height;

  Map<String, dynamic> toMessage() => {
    'id': id,
    'name': name,
    'width': width,
    'height': height,
    'pixelWidth': captureWidth,
    'pixelHeight': captureHeight,
    'pointPixelScale': pointPixelScale,
    'isPrimary': isPrimary,
  };

  String get resolutionLabel => captureWidth > 0 && captureHeight > 0
      ? '$captureWidth×$captureHeight'
      : '分辨率检测中';

  String get geometryDiagnosticsLabel =>
      '$width×$height pt · $captureWidth×$captureHeight px · '
      '${pointPixelScale.toStringAsFixed(2)}x';
}

class RemoteVideoFrameSize {
  const RemoteVideoFrameSize({required this.width, required this.height});

  factory RemoteVideoFrameSize.fromMessage(Map<String, dynamic> message) {
    return RemoteVideoFrameSize(
      width: (message['width'] as num?)?.toInt() ?? 0,
      height: (message['height'] as num?)?.toInt() ?? 0,
    );
  }

  static RemoteVideoFrameSize? fromRtcStats(
    Iterable<Map<dynamic, dynamic>> reports, {
    required String statType,
  }) {
    RemoteVideoFrameSize? largest;
    for (final report in reports) {
      if (report['type'] != statType) continue;
      final mediaType = report['kind'] ?? report['mediaType'];
      if (mediaType != null && mediaType != 'video') continue;
      final width = (report['frameWidth'] as num?)?.toInt() ?? 0;
      final height = (report['frameHeight'] as num?)?.toInt() ?? 0;
      if (width <= 0 || height <= 0) continue;
      final candidate = RemoteVideoFrameSize(width: width, height: height);
      if (largest == null || candidate.pixelCount > largest.pixelCount) {
        largest = candidate;
      }
    }
    return largest;
  }

  final int width;
  final int height;

  int get pixelCount => width * height;
  bool get isValid => width > 0 && height > 0;
  String get label => isValid ? '$width×$height' : 'Unknown';

  bool approximatelyMatches(
    RemoteVideoFrameSize other, {
    int dimensionTolerance = 2,
    double aspectTolerance = 0.005,
  }) {
    if (!isValid || !other.isValid) return false;
    final dimensionsMatch =
        (width - other.width).abs() <= dimensionTolerance &&
        (height - other.height).abs() <= dimensionTolerance;
    if (dimensionsMatch) return true;
    final aspect = width / height;
    final otherAspect = other.width / other.height;
    return (aspect - otherAspect).abs() <= aspectTolerance &&
        (width - other.width).abs() <= dimensionTolerance * 2 &&
        (height - other.height).abs() <= dimensionTolerance * 2;
  }

  Map<String, dynamic> toMessage() => {'width': width, 'height': height};
}

enum RemoteVideoGeometryState {
  stable,
  adapting,
  constrained;

  static RemoteVideoGeometryState fromWireValue(String? value) {
    return RemoteVideoGeometryState.values.firstWhere(
      (state) => state.name == value,
      orElse: () => RemoteVideoGeometryState.stable,
    );
  }
}

class RemoteMediaDiagnostics {
  const RemoteMediaDiagnostics({
    this.framesPerSecond,
    this.encodeMsPerFrame,
    this.decodeMsPerFrame,
    this.jitterBufferMsPerFrame,
    this.networkRoundTripMs,
    this.packetsLost,
    this.qualityLimitationReason,
  });

  final double? framesPerSecond;
  final double? encodeMsPerFrame;
  final double? decodeMsPerFrame;
  final double? jitterBufferMsPerFrame;
  final double? networkRoundTripMs;
  final int? packetsLost;
  final String? qualityLimitationReason;
}

class RemoteDisplayColorDiagnostics {
  const RemoteDisplayColorDiagnostics({
    required this.id,
    required this.name,
    required this.colorSpace,
    required this.hdrActive,
    required this.hdrCapable,
    required this.currentEdrHeadroom,
    required this.potentialEdrHeadroom,
  });

  factory RemoteDisplayColorDiagnostics.fromMessage(
    Map<String, dynamic> message,
  ) {
    return RemoteDisplayColorDiagnostics(
      id: message['id'] as String? ?? '',
      name: message['name'] as String? ?? 'Display',
      colorSpace: message['colorSpace'] as String? ?? 'Unknown',
      hdrActive: message['hdrActive'] as bool? ?? false,
      hdrCapable: message['hdrCapable'] as bool? ?? false,
      currentEdrHeadroom:
          (message['currentEdrHeadroom'] as num?)?.toDouble() ?? 1,
      potentialEdrHeadroom:
          (message['potentialEdrHeadroom'] as num?)?.toDouble() ?? 1,
    );
  }

  final String id;
  final String name;
  final String colorSpace;
  final bool hdrActive;
  final bool hdrCapable;
  final double currentEdrHeadroom;
  final double potentialEdrHeadroom;
}

class RemoteFrameColorDiagnostics {
  const RemoteFrameColorDiagnostics({
    required this.stage,
    required this.width,
    required this.height,
    required this.pixelFormat,
    required this.range,
    required this.colorPrimaries,
    required this.transferFunction,
    required this.yCbCrMatrix,
    required this.sampleCount,
    required this.lumaMin,
    required this.lumaMax,
    required this.nominalBlack,
    required this.nominalWhite,
    required this.belowNominalBlackPercent,
    required this.aboveNominalWhitePercent,
    required this.lumaHistogram16,
  });

  factory RemoteFrameColorDiagnostics.fromMessage(
    Map<String, dynamic> message,
  ) {
    return RemoteFrameColorDiagnostics(
      stage: message['stage'] as String? ?? 'unknown',
      width: (message['width'] as num?)?.toInt() ?? 0,
      height: (message['height'] as num?)?.toInt() ?? 0,
      pixelFormat: message['pixelFormat'] as String? ?? 'Unknown',
      range: message['range'] as String? ?? 'Unknown',
      colorPrimaries: message['colorPrimaries'] as String? ?? 'Unknown',
      transferFunction: message['transferFunction'] as String? ?? 'Unknown',
      yCbCrMatrix: message['yCbCrMatrix'] as String? ?? 'Unknown',
      sampleCount: (message['sampleCount'] as num?)?.toInt() ?? 0,
      lumaMin: (message['lumaMin'] as num?)?.toInt() ?? 0,
      lumaMax: (message['lumaMax'] as num?)?.toInt() ?? 0,
      nominalBlack: (message['nominalBlack'] as num?)?.toInt() ?? 0,
      nominalWhite: (message['nominalWhite'] as num?)?.toInt() ?? 255,
      belowNominalBlackPercent:
          (message['belowNominalBlackPercent'] as num?)?.toDouble() ?? 0,
      aboveNominalWhitePercent:
          (message['aboveNominalWhitePercent'] as num?)?.toDouble() ?? 0,
      lumaHistogram16:
          (message['lumaHistogram16'] as List<dynamic>? ?? const [])
              .whereType<num>()
              .map((value) => value.toInt())
              .toList(growable: false),
    );
  }

  final String stage;
  final int width;
  final int height;
  final String pixelFormat;
  final String range;
  final String colorPrimaries;
  final String transferFunction;
  final String yCbCrMatrix;
  final int sampleCount;
  final int lumaMin;
  final int lumaMax;
  final int nominalBlack;
  final int nominalWhite;
  final double belowNominalBlackPercent;
  final double aboveNominalWhitePercent;
  final List<int> lumaHistogram16;

  String get dimensions =>
      width > 0 && height > 0 ? '$width×$height' : 'Unknown';

  String get histogramLabel =>
      lumaHistogram16.isEmpty ? '未采样' : lumaHistogram16.join(', ');
}

class RemoteColorDiagnostics {
  const RemoteColorDiagnostics({
    required this.pixelFormat,
    required this.range,
    required this.colorPrimaries,
    required this.transferFunction,
    required this.yCbCrMatrix,
    required this.colorSpace,
    required this.captureDynamicRange,
    required this.displays,
    this.normalization = 'Unknown',
    this.normalizationBypassed = false,
    this.normalizationDurationMs,
    this.rawFrame,
    this.encoderInput,
  });

  factory RemoteColorDiagnostics.fromMessage(Map<String, dynamic> message) {
    final capture =
        (message['capture'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final displays = (message['displays'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (value) => RemoteDisplayColorDiagnostics.fromMessage(
            value.cast<String, dynamic>(),
          ),
        )
        .toList(growable: false);
    return RemoteColorDiagnostics(
      pixelFormat: capture['pixelFormat'] as String? ?? 'Unknown',
      range: capture['range'] as String? ?? 'Unknown',
      colorPrimaries: capture['colorPrimaries'] as String? ?? 'Unknown',
      transferFunction: capture['transferFunction'] as String? ?? 'Unknown',
      yCbCrMatrix: capture['yCbCrMatrix'] as String? ?? 'Unknown',
      colorSpace: capture['colorSpace'] as String? ?? 'Unknown',
      captureDynamicRange:
          capture['captureDynamicRange'] as String? ?? 'Unknown',
      normalization: capture['normalization'] as String? ?? 'Unknown',
      normalizationBypassed: capture['normalizationBypassed'] as bool? ?? false,
      normalizationDurationMs: (capture['normalizationDurationMs'] as num?)
          ?.toDouble(),
      rawFrame: _frameDiagnosticsFromValue(capture['rawFrame']),
      encoderInput: _frameDiagnosticsFromValue(capture['encoderInput']),
      displays: displays,
    );
  }

  final String pixelFormat;
  final String range;
  final String colorPrimaries;
  final String transferFunction;
  final String yCbCrMatrix;
  final String colorSpace;
  final String captureDynamicRange;
  final String normalization;
  final bool normalizationBypassed;
  final double? normalizationDurationMs;
  final RemoteFrameColorDiagnostics? rawFrame;
  final RemoteFrameColorDiagnostics? encoderInput;
  final List<RemoteDisplayColorDiagnostics> displays;

  RemoteDisplayColorDiagnostics? forDisplay(String? displayId) {
    for (final display in displays) {
      if (display.id == displayId) return display;
    }
    return displays.firstOrNull;
  }
}

RemoteFrameColorDiagnostics? _frameDiagnosticsFromValue(Object? value) {
  if (value is! Map) return null;
  return RemoteFrameColorDiagnostics.fromMessage(
    value.map((key, item) => MapEntry(key.toString(), item)),
  );
}

enum RemotePointerMode { direct, touchpad }

enum RemoteViewFit { contain, cover }

enum RemoteQualityProfile {
  automatic('自动', 1920, 12 * 1000 * 1000, 60),
  smooth('流畅 720p', 1280, 4 * 1000 * 1000, 60),
  high('高清 1080p', 1920, 8 * 1000 * 1000, 60),
  ultra('超清 2K', 2560, 16 * 1000 * 1000, 30),
  original('原画', null, 35 * 1000 * 1000, 30);

  const RemoteQualityProfile(
    this.label,
    this.targetLongEdge,
    this.maxBitrate,
    this.maxFramerate,
  );

  factory RemoteQualityProfile.fromWireValue(String? value) {
    return RemoteQualityProfile.values.firstWhere(
      (profile) => profile.name == value,
      orElse: () => RemoteQualityProfile.automatic,
    );
  }

  final String label;
  final int? targetLongEdge;
  final int maxBitrate;
  final int maxFramerate;

  double scaleFor(RemoteDisplay? display) {
    final target = targetLongEdge;
    if (target == null || display == null) {
      return 1;
    }
    final sourceLongEdge = display.captureWidth > display.captureHeight
        ? display.captureWidth
        : display.captureHeight;
    if (sourceLongEdge <= 0 || sourceLongEdge <= target) {
      return 1;
    }
    return sourceLongEdge / target;
  }
}

enum RemoteNoticeLevel { info, success, warning, error }

class RemoteNotice {
  const RemoteNotice(this.message, {this.level = RemoteNoticeLevel.info});

  final String message;
  final RemoteNoticeLevel level;
}
