import 'package:cross_desktop_remote/core/input/host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/windows_input_bridge.dart';
import 'package:flutter/services.dart';

class WindowsHostPlatformAdapter implements HostPlatformAdapter {
  const WindowsHostPlatformAdapter({this.bridge = const WindowsInputBridge()});

  final WindowsInputBridgeApi bridge;

  @override
  HostPlatformType get type => HostPlatformType.windows;

  @override
  HostPlatformCapabilities get capabilities => const HostPlatformCapabilities(
    canHostDesktop: true,
    captureFrameReadiness: false,
    colorDiagnostics: false,
    permissionSettings: false,
  );

  @override
  Future<List<HostDisplay>> listDisplays() => bridge.listDisplays();

  @override
  Future<HostPermissionState> checkPermissions() async {
    try {
      final native = await bridge.getHostCapabilities();
      if (!native.isCompatible) {
        return const HostPermissionState.unavailable(
          limitation: 'Windows 原生被控组件版本不兼容，请重新构建应用',
        );
      }
      return HostPermissionState(
        inputGranted: true,
        limitation: native.limitation,
      );
    } on MissingPluginException {
      return const HostPermissionState.unavailable(
        limitation: 'Windows 原生被控组件未加载，请重新构建应用',
      );
    } on PlatformException catch (error) {
      return HostPermissionState.unavailable(
        limitation: error.message ?? 'Windows 原生被控组件不可用',
      );
    } catch (_) {
      return const HostPermissionState.unavailable(
        limitation: 'Windows 原生被控组件返回了无法识别的能力数据',
      );
    }
  }

  @override
  Future<HostPermissionState> requestPermissions() async {
    final state = await checkPermissions();
    if (!state.inputGranted) {
      throw StateError(state.limitation ?? 'Windows 原生被控组件不可用');
    }
    return state;
  }

  @override
  Future<bool> openPermissionSettings() async => false;

  @override
  Future<void> sendPointer(HostPointerEvent event) {
    return bridge.sendPointer(event);
  }

  @override
  Future<void> sendKey(HostKeyEvent event) {
    return bridge.sendKey(event);
  }

  @override
  Future<void> sendText(String text) => bridge.sendText(text);

  @override
  Future<void> invokeShortcut({
    required String key,
    required List<String> modifiers,
  }) => bridge.invokeShortcut(key: key, modifiers: modifiers);

  @override
  Future<void> releasePointerButtons() => bridge.releasePointerButtons();

  @override
  Future<void> releaseKeyboardState() => bridge.releaseKeyboardState();

  @override
  Future<void> releaseAllInput() => bridge.releaseAllInput();

  @override
  Future<HostCaptureFrameState?> getCaptureFrameState() async => null;

  @override
  Future<Map<String, dynamic>> getColorDiagnostics() async => const {};

  @override
  Future<void> showGrayscaleTestPattern() async {
    throw UnsupportedError('Windows 暂不支持本机灰阶诊断');
  }

  @override
  Future<bool> openDisplaySettings() async => false;
}
