import 'dart:io';

import 'package:flutter/services.dart';

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

  @override
  bool get supportsNativeFullScreen => Platform.isWindows;

  @override
  Future<void> setFullScreen(bool enabled) async {
    if (!supportsNativeFullScreen) {
      throw UnsupportedError('Native desktop full screen is unavailable');
    }
    await _channel.invokeMethod<void>('setFullScreen', {'enabled': enabled});
  }
}
