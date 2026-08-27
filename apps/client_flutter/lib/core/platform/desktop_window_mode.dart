import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class DesktopMouseDoubleClickSettings {
  const DesktopMouseDoubleClickSettings({
    this.interval = const Duration(milliseconds: 500),
    this.slop = const Size(4, 4),
  });

  final Duration interval;
  final Size slop;

  DesktopMouseDoubleClickSettings sanitized() {
    final intervalMs = interval.inMilliseconds.clamp(100, 1000);
    return DesktopMouseDoubleClickSettings(
      interval: Duration(milliseconds: intervalMs),
      slop: Size(slop.width.clamp(1, 32), slop.height.clamp(1, 32)),
    );
  }
}

enum DesktopWindowLifecycleEvent {
  minimized,
  restored,
  maximized,
  resizeCompleted,
  displayChanged;

  static DesktopWindowLifecycleEvent? fromWireName(String? value) {
    for (final event in values) {
      if (event.name == value) return event;
    }
    return null;
  }
}

abstract interface class DesktopWindowModeController {
  bool get supportsNativeFullScreen;

  Future<void> setFullScreen(bool enabled);
}

class PlatformDesktopWindowModeController
    implements DesktopWindowModeController {
  const PlatformDesktopWindowModeController();

  static const _channel = MethodChannel(
    'com.crossdesktopremote.cross_desktop_remote/window',
  );

  static final StreamController<DesktopWindowLifecycleEvent> _lifecycleEvents =
      StreamController.broadcast(sync: true);
  static bool _lifecycleHandlerInstalled = false;

  @override
  bool get supportsNativeFullScreen => Platform.isWindows;

  @override
  Future<void> setFullScreen(bool enabled) async {
    if (!supportsNativeFullScreen) {
      throw UnsupportedError('Native desktop full screen is unavailable');
    }
    await _channel.invokeMethod<void>('setFullScreen', {'enabled': enabled});
  }

  static Stream<DesktopWindowLifecycleEvent> get lifecycleEvents {
    if (!Platform.isWindows) return const Stream.empty();
    _installLifecycleHandler();
    return _lifecycleEvents.stream;
  }

  static Future<DesktopMouseDoubleClickSettings>
  mouseDoubleClickSettings() async {
    if (!Platform.isWindows) {
      return const DesktopMouseDoubleClickSettings();
    }
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'getMouseDoubleClickSettings',
    );
    return DesktopMouseDoubleClickSettings(
      interval: Duration(
        milliseconds: (value?['intervalMs'] as num?)?.toInt() ?? 500,
      ),
      slop: Size(
        (value?['width'] as num?)?.toDouble() ?? 4,
        (value?['height'] as num?)?.toDouble() ?? 4,
      ),
    ).sanitized();
  }

  static void _installLifecycleHandler() {
    if (_lifecycleHandlerInstalled) return;
    _lifecycleHandlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'windowStateChanged') return;
      final arguments = call.arguments;
      final value = arguments is Map ? arguments['event'] as String? : null;
      final event = DesktopWindowLifecycleEvent.fromWireName(value);
      if (event != null) _lifecycleEvents.add(event);
    });
  }
}
