// Flutter's same-isolate desktop windowing API is still marked internal.
// Keep the dependency isolated in this file so the rest of the application
// remains on public Flutter APIs and can fall back safely when disabled.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:io';

import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';

/// Native secondary Flutter views are production-enabled only on the platform
/// that has completed the application's WebRTC/input regression matrix.
///
/// Windows keeps the remote viewer in the primary view because the current
/// flutter_webrtc texture registrar is not view-aware. Linux follows the same
/// conservative fallback until it has its own physical acceptance coverage.
bool get desktopWindowingAvailable =>
    isWindowingEnabled &&
    nativeDesktopWindowingSupported(Platform.operatingSystem);

@visibleForTesting
bool nativeDesktopWindowingSupported(String operatingSystem) =>
    operatingSystem == 'macos';

/// Wraps the application with the experimental window registry when available.
///
/// The returned widget must still be started with [runApp] so the primary
/// application is attached to the platform's implicit view.
Widget buildDesktopWindowingRoot(Widget child) {
  if (!desktopWindowingAvailable) return child;
  return WindowManager(child: child);
}
