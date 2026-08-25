import 'dart:io';

import 'package:cross_desktop_remote/core/input/host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/mac_host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/unsupported_host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/windows_host_platform_adapter.dart';

HostPlatformAdapter createHostPlatformAdapter() {
  if (Platform.isMacOS) return const MacHostPlatformAdapter();
  if (Platform.isWindows) return const WindowsHostPlatformAdapter();
  return const UnsupportedHostPlatformAdapter();
}
