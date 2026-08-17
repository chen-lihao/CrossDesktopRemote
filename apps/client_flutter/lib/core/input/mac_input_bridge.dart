import 'package:flutter/services.dart';

class MacDisplayInfo {
  const MacDisplayInfo({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.isPrimary,
  });

  factory MacDisplayInfo.fromMap(Map<Object?, Object?> map) {
    return MacDisplayInfo(
      id: map['id'] as String,
      name: map['name'] as String? ?? 'Display',
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      isPrimary: map['isPrimary'] as bool? ?? false,
    );
  }

  final String id;
  final String name;
  final int width;
  final int height;
  final bool isPrimary;
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
}
