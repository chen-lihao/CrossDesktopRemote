// Flutter's same-isolate desktop windowing API is still marked internal.
// Keep the dependency isolated in this file so the rest of the application
// remains on public Flutter APIs and can fall back safely when disabled.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:io';

import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';

bool get desktopWindowingAvailable =>
    isWindowingEnabled &&
    (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

Widget buildDesktopWindowingRoot(Widget child) {
  if (!desktopWindowingAvailable) return child;
  return WindowManager(child: child);
}
