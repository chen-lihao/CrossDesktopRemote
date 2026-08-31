import 'package:cross_desktop_remote/core/input/host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/protocol/wire_value_parsers.dart';
import 'package:flutter/services.dart';

class WindowsNativeHostCapabilities {
  const WindowsNativeHostCapabilities({
    required this.protocolVersion,
    required this.canHostDesktop,
    required this.canInjectInput,
    required this.canEnumerateDisplays,
    required this.supportsUnicode,
    required this.supportsVirtualDesktop,
    required this.limitation,
  });

  factory WindowsNativeHostCapabilities.fromMap(Map<Object?, Object?> map) {
    return WindowsNativeHostCapabilities(
      protocolVersion: (map['protocolVersion'] as num?)?.toInt() ?? 0,
      canHostDesktop: wireBool(map['canHostDesktop']),
      canInjectInput: wireBool(map['canInjectInput']),
      canEnumerateDisplays: wireBool(map['canEnumerateDisplays']),
      supportsUnicode: wireBool(map['supportsUnicode']),
      supportsVirtualDesktop: wireBool(map['supportsVirtualDesktop']),
      limitation: map['limitation'] as String?,
    );
  }

  final int protocolVersion;
  final bool canHostDesktop;
  final bool canInjectInput;
  final bool canEnumerateDisplays;
  final bool supportsUnicode;
  final bool supportsVirtualDesktop;
  final String? limitation;

  bool get isCompatible =>
      protocolVersion == 1 &&
      canHostDesktop &&
      canInjectInput &&
      canEnumerateDisplays &&
      supportsUnicode &&
      supportsVirtualDesktop;
}

abstract interface class WindowsInputBridgeApi {
  Future<WindowsNativeHostCapabilities> getHostCapabilities();

  Future<List<HostDisplay>> listDisplays();

  Future<void> sendPointer(HostPointerEvent event);

  Future<void> sendKey(HostKeyEvent event);

  Future<void> sendText(String text);

  Future<void> invokeShortcut({
    required String key,
    required List<String> modifiers,
  });

  Future<void> releasePointerButtons();

  Future<void> releaseKeyboardState();

  Future<void> releaseAllInput();
}

class WindowsInputBridge implements WindowsInputBridgeApi {
  const WindowsInputBridge();

  static const _channel = MethodChannel(
    'com.crossdesktopremote.cross_desktop_remote/input',
  );

  @override
  Future<WindowsNativeHostCapabilities> getHostCapabilities() async {
    final value =
        await _channel.invokeMapMethod<Object?, Object?>(
          'getHostCapabilities',
        ) ??
        const <Object?, Object?>{};
    return WindowsNativeHostCapabilities.fromMap(value);
  }

  @override
  Future<List<HostDisplay>> listDisplays() async {
    final values =
        await _channel.invokeListMethod<Map<Object?, Object?>>(
          'listDisplays',
        ) ??
        const [];
    return values
        .map(
          (value) => HostDisplay(
            id: value['id'] as String? ?? '',
            name: value['name'] as String? ?? 'Display',
            width: (value['width'] as num?)?.toInt() ?? 0,
            height: (value['height'] as num?)?.toInt() ?? 0,
            pixelWidth: (value['pixelWidth'] as num?)?.toInt() ?? 0,
            pixelHeight: (value['pixelHeight'] as num?)?.toInt() ?? 0,
            pointPixelScale:
                (value['pointPixelScale'] as num?)?.toDouble() ?? 1,
            isPrimary: wireBool(value['isPrimary']),
          ),
        )
        .where((display) => display.id.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<void> sendPointer(HostPointerEvent event) {
    return _channel.invokeMethod<void>('pointer', {
      'phase': event.phase,
      'x': event.x,
      'y': event.y,
      'displayId': event.displayId,
      'mode': event.mode,
      'button': event.button,
      'clickCount': event.clickCount,
      'movementX': event.movementX,
      'movementY': event.movementY,
      'deltaX': event.deltaX,
      'deltaY': event.deltaY,
      'modifiers': event.modifiers,
    });
  }

  @override
  Future<void> sendKey(HostKeyEvent event) {
    return _channel.invokeMethod<void>('keyboard', {
      'type': 'key',
      'phase': event.phase,
      'key': event.key,
      'modifiers': event.modifiers,
      'physicalHidUsage': ?event.physicalHidUsage,
      if (event.repeat) 'repeat': true,
    });
  }

  @override
  Future<void> sendText(String text) {
    return _channel.invokeMethod<void>('keyboard', {
      'type': 'text',
      'text': text,
    });
  }

  @override
  Future<void> invokeShortcut({
    required String key,
    required List<String> modifiers,
  }) {
    return _channel.invokeMethod<void>('invokeShortcut', {
      'key': key,
      'modifiers': modifiers,
    });
  }

  @override
  Future<void> releasePointerButtons() {
    return _channel.invokeMethod<void>('releasePointerButtons');
  }

  @override
  Future<void> releaseKeyboardState() {
    return _channel.invokeMethod<void>('releaseKeyboardState');
  }

  @override
  Future<void> releaseAllInput() {
    return _channel.invokeMethod<void>('releaseAllInput');
  }
}
