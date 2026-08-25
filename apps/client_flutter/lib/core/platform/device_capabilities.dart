import 'dart:io';

class DeviceCapabilities {
  const DeviceCapabilities({
    required this.canControl,
    required this.canHost,
    required this.canDiscover,
    this.defaultToHost = false,
  });

  factory DeviceCapabilities.current() {
    return DeviceCapabilities(
      canControl: true,
      canHost: Platform.isMacOS || Platform.isWindows,
      canDiscover: Platform.isIOS || Platform.isMacOS || Platform.isWindows,
      // Keep Windows on its established controller-first startup path. The
      // user can explicitly switch to "共享本机" after the runner capability
      // handshake succeeds.
      defaultToHost: Platform.isMacOS,
    );
  }

  final bool canControl;
  final bool canHost;
  final bool canDiscover;
  final bool defaultToHost;

  bool get supportsRoleSwitching => canControl && canHost;
}
