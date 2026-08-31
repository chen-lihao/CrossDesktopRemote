import 'package:cross_desktop_remote/core/input/host_platform_adapter.dart';

class UnsupportedHostPlatformAdapter implements HostPlatformAdapter {
  const UnsupportedHostPlatformAdapter();

  UnsupportedError _unsupported() => UnsupportedError('当前平台尚未实现被控能力');

  @override
  HostPlatformType get type => HostPlatformType.unsupported;

  @override
  HostPlatformCapabilities get capabilities =>
      const HostPlatformCapabilities.unsupported();

  @override
  Future<List<HostDisplay>> listDisplays() async => const [];

  @override
  Future<HostPermissionState> checkPermissions() async =>
      const HostPermissionState.unavailable(limitation: '当前平台尚未实现输入注入');

  @override
  Future<HostPermissionState> requestPermissions() => checkPermissions();

  @override
  Future<bool> openPermissionSettings() async => false;

  @override
  Future<void> sendPointer(HostPointerEvent event) async {
    throw _unsupported();
  }

  @override
  Future<void> sendKey(HostKeyEvent event) async {
    throw _unsupported();
  }

  @override
  Future<void> sendText(String text) async {
    throw _unsupported();
  }

  @override
  Future<void> invokeShortcut({
    required String key,
    required List<String> modifiers,
  }) async {
    throw _unsupported();
  }

  @override
  Future<void> releasePointerButtons() async {}

  @override
  Future<void> releaseKeyboardState() async {}

  @override
  Future<void> releaseAllInput() async {}

  @override
  Future<HostCaptureFrameState?> getCaptureFrameState() async => null;

  @override
  Future<Map<String, dynamic>> getColorDiagnostics() async => const {};

  @override
  Future<void> showGrayscaleTestPattern() async {
    throw _unsupported();
  }

  @override
  Future<bool> openDisplaySettings() async => false;
}
