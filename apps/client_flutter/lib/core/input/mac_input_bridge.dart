import 'package:flutter/services.dart';

class MacDisplayInfo {
  const MacDisplayInfo({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.pointPixelScale,
    required this.isPrimary,
  });

  factory MacDisplayInfo.fromMap(Map<Object?, Object?> map) {
    return MacDisplayInfo(
      id: map['id'] as String,
      name: map['name'] as String? ?? 'Display',
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      pixelWidth: (map['pixelWidth'] as num?)?.toInt() ?? 0,
      pixelHeight: (map['pixelHeight'] as num?)?.toInt() ?? 0,
      pointPixelScale: (map['pointPixelScale'] as num?)?.toDouble() ?? 1,
      isPrimary: map['isPrimary'] as bool? ?? false,
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
}

class MacCaptureFrameState {
  const MacCaptureFrameState({
    required this.sequence,
    required this.sourceId,
    required this.width,
    required this.height,
  });

  factory MacCaptureFrameState.fromMap(Map<Object?, Object?> map) {
    return MacCaptureFrameState(
      sequence: (map['sequence'] as num?)?.toInt() ?? 0,
      sourceId: map['sourceId'] as String? ?? '',
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
    );
  }

  final int sequence;
  final String sourceId;
  final int width;
  final int height;
}

class MacInputBridge {
  const MacInputBridge();

  static const _channel = MethodChannel(
    'com.crossdesktopremote.cross_desktop_remote/input',
  );

  Future<bool> requestInputAccess() async {
    return await _channel.invokeMethod<bool>('requestInputAccess') ?? false;
  }

  Future<bool> checkInputAccess() async {
    return await _channel.invokeMethod<bool>('checkInputAccess') ?? false;
  }

  Future<bool> openInputSettings() async {
    return await _channel.invokeMethod<bool>('openInputSettings') ?? false;
  }

  Future<List<MacDisplayInfo>> listDisplays() async {
    final values =
        await _channel.invokeListMethod<Map<Object?, Object?>>(
          'listDisplays',
        ) ??
        const [];
    return values.map(MacDisplayInfo.fromMap).toList(growable: false);
  }

  Future<Map<String, dynamic>> getColorDiagnostics() async {
    final value = await _channel.invokeMethod<Object?>('getColorDiagnostics');
    return _normalizeStringMap(value);
  }

  Future<MacCaptureFrameState> getCaptureFrameState() async {
    final value =
        await _channel.invokeMapMethod<Object?, Object?>(
          'getCaptureFrameState',
        ) ??
        const <Object?, Object?>{};
    return MacCaptureFrameState.fromMap(value);
  }

  Future<void> showGrayscaleTestPattern() {
    return _channel.invokeMethod<void>('showGrayscaleTestPattern');
  }

  Future<bool> openDisplaySettings() async {
    return await _channel.invokeMethod<bool>('openDisplaySettings') ?? false;
  }

  Future<void> sendPointer({
    required String phase,
    required double x,
    required double y,
    required String displayId,
    String mode = 'absolute',
    String button = 'left',
    int clickCount = 1,
    double movementX = 0,
    double movementY = 0,
    double deltaX = 0,
    double deltaY = 0,
  }) {
    return _channel.invokeMethod<void>('pointer', {
      'version': 2,
      'phase': phase,
      'x': x.clamp(0, 1),
      'y': y.clamp(0, 1),
      'displayId': displayId,
      'mode': mode,
      'button': button,
      'clickCount': clickCount,
      'movementX': movementX,
      'movementY': movementY,
      'deltaX': deltaX,
      'deltaY': deltaY,
    });
  }

  Future<void> sendKey({
    required String phase,
    required String key,
    required List<String> modifiers,
  }) {
    return _channel.invokeMethod<void>('keyboard', {
      'version': 2,
      'type': 'key',
      'phase': phase,
      'key': key,
      'modifiers': modifiers,
    });
  }

  Future<void> sendText(String text) {
    return _channel.invokeMethod<void>('keyboard', {
      'version': 2,
      'type': 'text',
      'text': text,
    });
  }

  Future<void> releasePointerButtons() {
    return _channel.invokeMethod<void>('releasePointerButtons');
  }
}

Map<String, dynamic> _normalizeStringMap(Object? value) {
  if (value is! Map) return const {};
  return value.map(
    (key, item) => MapEntry(key.toString(), _normalizePlatformValue(item)),
  );
}

Object? _normalizePlatformValue(Object? value) {
  if (value is Map) return _normalizeStringMap(value);
  if (value is List) return value.map(_normalizePlatformValue).toList();
  return value;
}
