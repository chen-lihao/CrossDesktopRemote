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
      canHost: Platform.isMacOS || Platform.isWindows,
      canDiscover: Platform.isIOS || Platform.isMacOS || Platform.isWindows,
    );
  }

  final bool canControl;
  final bool canHost;
  final bool canDiscover;
}
