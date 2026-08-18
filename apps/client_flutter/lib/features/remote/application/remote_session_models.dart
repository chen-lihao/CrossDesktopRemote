class RemoteDisplay {
  const RemoteDisplay({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.isPrimary,
  });

  factory RemoteDisplay.fromMessage(Map<String, dynamic> message) {
    return RemoteDisplay(
      id: message['id'] as String,
      name: message['name'] as String? ?? 'Display',
      width: (message['width'] as num?)?.toInt() ?? 0,
      height: (message['height'] as num?)?.toInt() ?? 0,
      isPrimary: message['isPrimary'] as bool? ?? false,
    );
  }

  final String id;
  final String name;
  final int width;
  final int height;
  final bool isPrimary;

  Map<String, dynamic> toMessage() => {
    'id': id,
    'name': name,
    'width': width,
    'height': height,
    'isPrimary': isPrimary,
  };

  String get resolutionLabel =>
      width > 0 && height > 0 ? '$width×$height' : '分辨率检测中';
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
  final List<RemoteDisplayColorDiagnostics> displays;

  RemoteDisplayColorDiagnostics? forDisplay(String? displayId) {
    for (final display in displays) {
      if (display.id == displayId) return display;
    }
    return displays.firstOrNull;
  }
}

enum RemotePointerMode { direct, touchpad }

enum RemoteViewFit { contain, cover }

enum RemoteQualityProfile {
  automatic('自动', 1920, 12 * 1000 * 1000, 30),
  smooth('流畅 720p', 1280, 4 * 1000 * 1000, 30),
  high('高清 1080p', 1920, 8 * 1000 * 1000, 30),
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
    final sourceLongEdge = display.width > display.height
        ? display.width
        : display.height;
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
