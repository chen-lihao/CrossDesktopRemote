import 'package:flutter/foundation.dart';

enum HostPlatformType { macOS, windows, unsupported }

@immutable
class HostPlatformCapabilities {
  const HostPlatformCapabilities({
    required this.canHostDesktop,
    required this.captureFrameReadiness,
    required this.colorDiagnostics,
    required this.permissionSettings,
  });

  const HostPlatformCapabilities.unsupported()
    : canHostDesktop = false,
      captureFrameReadiness = false,
      colorDiagnostics = false,
      permissionSettings = false;

  final bool canHostDesktop;
  final bool captureFrameReadiness;
  final bool colorDiagnostics;
  final bool permissionSettings;
}

@immutable
class HostPermissionState {
  const HostPermissionState({required this.inputGranted, this.limitation});

  const HostPermissionState.unavailable({String? limitation})
    : this(inputGranted: false, limitation: limitation);

  final bool inputGranted;
  final String? limitation;
}

@immutable
class HostDisplay {
  const HostDisplay({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.pointPixelScale,
    required this.isPrimary,
  });

  final String id;
  final String name;
  final int width;
  final int height;
  final int pixelWidth;
  final int pixelHeight;
  final double pointPixelScale;
  final bool isPrimary;
}

@immutable
class HostPointerEvent {
  const HostPointerEvent({
    required this.phase,
    required this.x,
    required this.y,
    required this.displayId,
    this.mode = 'absolute',
    this.button = 'left',
    this.clickCount = 1,
    this.movementX = 0,
    this.movementY = 0,
    this.deltaX = 0,
    this.deltaY = 0,
  });

  final String phase;
  final double x;
  final double y;
  final String displayId;
  final String mode;
  final String button;
  final int clickCount;
  final double movementX;
  final double movementY;
  final double deltaX;
  final double deltaY;
}

@immutable
class HostKeyEvent {
  const HostKeyEvent({
    required this.phase,
    required this.key,
    required this.modifiers,
    this.physicalHidUsage,
    this.repeat = false,
  });

  final String phase;
  final String key;
  final List<String> modifiers;
  final int? physicalHidUsage;
  final bool repeat;
}

@immutable
class HostCaptureFrameState {
  const HostCaptureFrameState({
    required this.sequence,
    required this.sourceId,
    required this.width,
    required this.height,
    required this.captureGeneration,
    required this.gateStatus,
    required this.rejectionReason,
    required this.staleFrameCount,
    required this.wrongSizeCount,
    required this.missingContentMetadataCount,
    required this.contentAspectMismatchCount,
    required this.normalizationFailureCount,
    required this.bufferWidth,
    required this.bufferHeight,
    required this.activeContentX,
    required this.activeContentY,
    required this.activeContentWidth,
    required this.activeContentHeight,
  });

  final int sequence;
  final String sourceId;
  final int width;
  final int height;
  final int captureGeneration;
  final String gateStatus;
  final String rejectionReason;
  final int staleFrameCount;
  final int wrongSizeCount;
  final int missingContentMetadataCount;
  final int contentAspectMismatchCount;
  final int normalizationFailureCount;
  final int bufferWidth;
  final int bufferHeight;
  final double activeContentX;
  final double activeContentY;
  final double activeContentWidth;
  final double activeContentHeight;

  bool get hasValidActiveContent =>
      width > 0 &&
      height > 0 &&
      activeContentX >= 0 &&
      activeContentY >= 0 &&
      activeContentWidth > 0 &&
      activeContentHeight > 0 &&
      activeContentX + activeContentWidth <= width + 1 &&
      activeContentY + activeContentHeight <= height + 1;

  bool isReadyAfter({required int sequence, required String targetSourceId}) {
    return this.sequence > sequence &&
        sourceId == targetSourceId &&
        width > 0 &&
        height > 0;
  }

  String get gateDiagnosticSummary {
    final reason = rejectionReason.isEmpty ? 'unknown' : rejectionReason;
    final geometry = bufferWidth > 0 && bufferHeight > 0
        ? '，Buffer $bufferWidth×$bufferHeight'
        : '';
    return '$reason$geometry'
        '，旧帧 $staleFrameCount、尺寸 $wrongSizeCount、缺少元数据 '
        '$missingContentMetadataCount、宽高比 $contentAspectMismatchCount、规范化 '
        '$normalizationFailureCount';
  }
}

abstract interface class HostPlatformAdapter {
  HostPlatformType get type;

  HostPlatformCapabilities get capabilities;

  Future<List<HostDisplay>> listDisplays();

  Future<HostPermissionState> checkPermissions();

  Future<HostPermissionState> requestPermissions();

  Future<bool> openPermissionSettings();

  Future<void> sendPointer(HostPointerEvent event);

  Future<void> sendKey(HostKeyEvent event);

  Future<void> sendText(String text);

  Future<void> releasePointerButtons();

  Future<HostCaptureFrameState?> getCaptureFrameState();

  Future<Map<String, dynamic>> getColorDiagnostics();

  Future<void> showGrayscaleTestPattern();

  Future<bool> openDisplaySettings();
}
