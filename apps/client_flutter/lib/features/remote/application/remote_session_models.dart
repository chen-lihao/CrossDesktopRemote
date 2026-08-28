import 'package:cross_desktop_remote/core/protocol/wire_value_parsers.dart';

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
      isPrimary: wireBool(message['isPrimary']),
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

  bool hasSameAspectRatio(
    RemoteVideoFrameSize other, {
    double relativeTolerance = 0.015,
  }) {
    if (!isValid || !other.isValid) return false;
    final ratio = (width / height) / (other.width / other.height);
    return (ratio - 1).abs() <= relativeTolerance;
  }

  Map<String, dynamic> toMessage() => {'width': width, 'height': height};
}

/// Geometry for one committed remote-display media generation.
///
/// The logical desktop, capture surface, encoded canvas and active pixels are
/// intentionally kept separate. Input is normalized against [activeContent]
/// and then applied to the logical desktop; renderer dimensions are only a
/// validation signal and never become the coordinate system by themselves.
class RemoteFrameGeometry {
  const RemoteFrameGeometry({
    required this.displayId,
    required this.generation,
    required this.logicalWidth,
    required this.logicalHeight,
    required this.captureWidth,
    required this.captureHeight,
    required this.encodedWidth,
    required this.encodedHeight,
    required this.activeContentX,
    required this.activeContentY,
    required this.activeContentWidth,
    required this.activeContentHeight,
    this.rotation = 0,
  });

  factory RemoteFrameGeometry.fromMessage(Map<String, dynamic> message) {
    return RemoteFrameGeometry(
      displayId: message['displayId'] as String? ?? '',
      generation: (message['generation'] as num?)?.toInt() ?? 0,
      logicalWidth: (message['logicalWidth'] as num?)?.toInt() ?? 0,
      logicalHeight: (message['logicalHeight'] as num?)?.toInt() ?? 0,
      captureWidth: (message['captureWidth'] as num?)?.toInt() ?? 0,
      captureHeight: (message['captureHeight'] as num?)?.toInt() ?? 0,
      encodedWidth: (message['encodedWidth'] as num?)?.toInt() ?? 0,
      encodedHeight: (message['encodedHeight'] as num?)?.toInt() ?? 0,
      activeContentX: (message['activeContentX'] as num?)?.toDouble() ?? 0,
      activeContentY: (message['activeContentY'] as num?)?.toDouble() ?? 0,
      activeContentWidth:
          (message['activeContentWidth'] as num?)?.toDouble() ?? 0,
      activeContentHeight:
          (message['activeContentHeight'] as num?)?.toDouble() ?? 0,
      rotation: (message['rotation'] as num?)?.toInt() ?? 0,
    );
  }

  final String displayId;
  final int generation;
  final int logicalWidth;
  final int logicalHeight;
  final int captureWidth;
  final int captureHeight;
  final int encodedWidth;
  final int encodedHeight;
  final double activeContentX;
  final double activeContentY;
  final double activeContentWidth;
  final double activeContentHeight;
  final int rotation;

  bool get isValid =>
      displayId.isNotEmpty &&
      logicalWidth > 0 &&
      logicalHeight > 0 &&
      captureWidth > 0 &&
      captureHeight > 0 &&
      encodedWidth > 0 &&
      encodedHeight > 0 &&
      activeContentWidth > 0 &&
      activeContentHeight > 0 &&
      activeContentX >= 0 &&
      activeContentY >= 0 &&
      activeContentX + activeContentWidth <= encodedWidth + 1 &&
      activeContentY + activeContentHeight <= encodedHeight + 1;

  RemoteVideoFrameSize get encodedSize =>
      RemoteVideoFrameSize(width: encodedWidth, height: encodedHeight);

  double get activeAspectRatio => activeContentWidth / activeContentHeight;

  bool belongsTo({required String? displayId, required int generation}) {
    return isValid &&
        this.displayId == displayId &&
        (generation <= 0 || this.generation == generation);
  }

  RemoteFrameGeometry withGeneration(int value) => RemoteFrameGeometry(
    displayId: displayId,
    generation: value,
    logicalWidth: logicalWidth,
    logicalHeight: logicalHeight,
    captureWidth: captureWidth,
    captureHeight: captureHeight,
    encodedWidth: encodedWidth,
    encodedHeight: encodedHeight,
    activeContentX: activeContentX,
    activeContentY: activeContentY,
    activeContentWidth: activeContentWidth,
    activeContentHeight: activeContentHeight,
    rotation: rotation,
  );

  Map<String, dynamic> toMessage() => {
    'displayId': displayId,
    'generation': generation,
    'logicalWidth': logicalWidth,
    'logicalHeight': logicalHeight,
    'captureWidth': captureWidth,
    'captureHeight': captureHeight,
    'encodedWidth': encodedWidth,
    'encodedHeight': encodedHeight,
    'activeContentX': activeContentX,
    'activeContentY': activeContentY,
    'activeContentWidth': activeContentWidth,
    'activeContentHeight': activeContentHeight,
    'rotation': rotation,
  };

  String get label =>
      '$displayId · logical $logicalWidth×$logicalHeight · '
      'capture $captureWidth×$captureHeight · '
      'encoded $encodedWidth×$encodedHeight · '
      'active ${activeContentWidth.toStringAsFixed(0)}×'
      '${activeContentHeight.toStringAsFixed(0)} @ '
      '${activeContentX.toStringAsFixed(0)},'
      '${activeContentY.toStringAsFixed(0)} · gen $generation';
}

RemoteFrameGeometry? remoteFrameGeometryFromValue(Object? value) {
  if (value is! Map) return null;
  final geometry = RemoteFrameGeometry.fromMessage(
    value.map((key, item) => MapEntry(key.toString(), item)),
  );
  return geometry.isValid ? geometry : null;
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
    this.packetLossPercent,
    this.bitrateMbps,
    this.availableOutgoingBitrateMbps,
    this.framesDroppedDelta,
    this.freezeCountDelta,
    this.keyFramesEncoded,
    this.keyFramesDecoded,
    this.keyFramesEncodedDelta,
    this.keyFramesDecodedDelta,
    this.nackCountDelta,
    this.pliCountDelta,
    this.firCountDelta,
    this.codec,
    this.encoderImplementation,
    this.decoderImplementation,
    this.qualityLimitationReason,
  });

  final double? framesPerSecond;
  final double? encodeMsPerFrame;
  final double? decodeMsPerFrame;
  final double? jitterBufferMsPerFrame;
  final double? networkRoundTripMs;
  final int? packetsLost;
  final double? packetLossPercent;
  final double? bitrateMbps;
  final double? availableOutgoingBitrateMbps;
  final int? framesDroppedDelta;
  final int? freezeCountDelta;
  final int? keyFramesEncoded;
  final int? keyFramesDecoded;
  final int? keyFramesEncodedDelta;
  final int? keyFramesDecodedDelta;
  final int? nackCountDelta;
  final int? pliCountDelta;
  final int? firCountDelta;
  final String? codec;
  final String? encoderImplementation;
  final String? decoderImplementation;
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
      hdrActive: wireBool(message['hdrActive']),
      hdrCapable: wireBool(message['hdrCapable']),
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

class RemoteCaptureFrameGeometry {
  const RemoteCaptureFrameGeometry({
    required this.bufferWidth,
    required this.bufferHeight,
    required this.contentRectX,
    required this.contentRectY,
    required this.contentRectWidth,
    required this.contentRectHeight,
    required this.contentScale,
    required this.scaleFactor,
    required this.visiblePixelRectX,
    required this.visiblePixelRectY,
    required this.visiblePixelRectWidth,
    required this.visiblePixelRectHeight,
    required this.visibleWidthCoverage,
    required this.visibleHeightCoverage,
    required this.contentRectMetadataPresent,
    required this.contentFillsBuffer,
    required this.captureGeneration,
  });

  factory RemoteCaptureFrameGeometry.fromMessage(Map<String, dynamic> message) {
    return RemoteCaptureFrameGeometry(
      bufferWidth: (message['bufferWidth'] as num?)?.toInt() ?? 0,
      bufferHeight: (message['bufferHeight'] as num?)?.toInt() ?? 0,
      contentRectX: (message['contentRectX'] as num?)?.toDouble() ?? 0,
      contentRectY: (message['contentRectY'] as num?)?.toDouble() ?? 0,
      contentRectWidth: (message['contentRectWidth'] as num?)?.toDouble() ?? 0,
      contentRectHeight:
          (message['contentRectHeight'] as num?)?.toDouble() ?? 0,
      contentScale: (message['contentScale'] as num?)?.toDouble() ?? 0,
      scaleFactor: (message['scaleFactor'] as num?)?.toDouble() ?? 0,
      visiblePixelRectX:
          (message['visiblePixelRectX'] as num?)?.toDouble() ?? 0,
      visiblePixelRectY:
          (message['visiblePixelRectY'] as num?)?.toDouble() ?? 0,
      visiblePixelRectWidth:
          (message['visiblePixelRectWidth'] as num?)?.toDouble() ?? 0,
      visiblePixelRectHeight:
          (message['visiblePixelRectHeight'] as num?)?.toDouble() ?? 0,
      visibleWidthCoverage:
          (message['visibleWidthCoverage'] as num?)?.toDouble() ?? 0,
      visibleHeightCoverage:
          (message['visibleHeightCoverage'] as num?)?.toDouble() ?? 0,
      contentRectMetadataPresent: wireBool(
        message['contentRectMetadataPresent'],
      ),
      contentFillsBuffer: wireBool(message['contentFillsBuffer']),
      captureGeneration: (message['captureGeneration'] as num?)?.toInt() ?? 0,
    );
  }

  final int bufferWidth;
  final int bufferHeight;
  final double contentRectX;
  final double contentRectY;
  final double contentRectWidth;
  final double contentRectHeight;
  final double contentScale;
  final double scaleFactor;
  final double visiblePixelRectX;
  final double visiblePixelRectY;
  final double visiblePixelRectWidth;
  final double visiblePixelRectHeight;
  final double visibleWidthCoverage;
  final double visibleHeightCoverage;
  final bool contentRectMetadataPresent;
  final bool contentFillsBuffer;
  final int captureGeneration;

  String get label =>
      'buffer $bufferWidth×$bufferHeight · '
      'content ${contentRectWidth.toStringAsFixed(0)}×'
      '${contentRectHeight.toStringAsFixed(0)} @ '
      '${contentRectX.toStringAsFixed(0)},${contentRectY.toStringAsFixed(0)} · '
      'visible ${visiblePixelRectWidth.toStringAsFixed(0)}×'
      '${visiblePixelRectHeight.toStringAsFixed(0)} @ '
      '${visiblePixelRectX.toStringAsFixed(0)},'
      '${visiblePixelRectY.toStringAsFixed(0)} · '
      'coverage ${(visibleWidthCoverage * 100).toStringAsFixed(1)}%×'
      '${(visibleHeightCoverage * 100).toStringAsFixed(1)}% · '
      '${contentFillsBuffer ? 'full' : 'normalized'} · '
      'contentScale ${contentScale.toStringAsFixed(2)} · '
      'scaleFactor ${scaleFactor.toStringAsFixed(2)} · gen $captureGeneration';
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
    this.frameGeometry,
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
      normalizationBypassed: wireBool(capture['normalizationBypassed']),
      normalizationDurationMs: (capture['normalizationDurationMs'] as num?)
          ?.toDouble(),
      rawFrame: _frameDiagnosticsFromValue(capture['rawFrame']),
      encoderInput: _frameDiagnosticsFromValue(capture['encoderInput']),
      frameGeometry: _captureGeometryFromValue(capture['frameGeometry']),
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
  final RemoteCaptureFrameGeometry? frameGeometry;
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

RemoteCaptureFrameGeometry? _captureGeometryFromValue(Object? value) {
  if (value is! Map) return null;
  return RemoteCaptureFrameGeometry.fromMessage(
    value.map((key, item) => MapEntry(key.toString(), item)),
  );
}

enum RemotePointerMode { direct, touchpad }

enum RemoteViewFit { contain, cover }

enum RemoteQualityProfile {
  automatic('自动', 1920, 7 * 1000 * 1000, 30),
  smooth('流畅 720p60', 1280, 5 * 1000 * 1000, 60),
  high('高清 1080p30', 1920, 9 * 1000 * 1000, 30),
  high60('高清 1080p60', 1920, 14 * 1000 * 1000, 60, true),
  ultra('超清 2K', 2560, 16 * 1000 * 1000, 30),
  ultra60('超清 2K60', 2560, 24 * 1000 * 1000, 60, true),
  original('原画 30fps', null, 35 * 1000 * 1000, 30),
  original60('原画 60fps', null, 48 * 1000 * 1000, 60, true);

  const RemoteQualityProfile(
    this.label,
    this.targetLongEdge,
    this.maxBitrate,
    this.maxFramerate, [
    this.prioritizeFrameRate = false,
  ]);

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
  final bool prioritizeFrameRate;

  /// Keep the established mobile quality menu unchanged until the more
  /// demanding manual 60 fps modes are physically verified on tablets.
  bool get desktopControllerOnly => switch (this) {
    high60 || ultra60 || original60 => true,
    _ => false,
  };

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
