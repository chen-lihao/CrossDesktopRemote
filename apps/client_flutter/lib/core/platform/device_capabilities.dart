import 'dart:io';

class DeviceCapabilities {
  const DeviceCapabilities({
    required this.canControl,
    required this.canHost,
    required this.canDiscover,
  });

  factory DeviceCapabilities.current() {
    return DeviceCapabilities(
      canControl: true,
      // macOS is the first implemented host. Windows/Linux host support can be
      // enabled here once their capture and native input bridges are ready.
      canHost: Platform.isMacOS,
      canDiscover: Platform.isIOS || Platform.isMacOS,
    );
  }

  final bool canControl;
  final bool canHost;
  final bool canDiscover;

  bool get supportsRoleSwitching => canControl && canHost;
}
