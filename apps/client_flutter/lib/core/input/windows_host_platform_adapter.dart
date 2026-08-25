import 'package:cross_desktop_remote/core/input/host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/unsupported_host_platform_adapter.dart';

/// Windows host boundary.
///
/// The controller-side Windows client is already supported. Host capture and
/// SendInput stay disabled until the Windows runner implements and passes the
/// native contract; this prevents the UI from advertising a host mode that can
/// capture video but cannot reliably release injected keys or mouse buttons.
class WindowsHostPlatformAdapter extends UnsupportedHostPlatformAdapter {
  const WindowsHostPlatformAdapter();

  @override
  HostPlatformType get type => HostPlatformType.windows;

  @override
  Future<HostPermissionState> checkPermissions() async {
    return const HostPermissionState.unavailable(
      limitation: 'Windows 被控端输入注入尚未完成实机验收',
    );
  }
}
