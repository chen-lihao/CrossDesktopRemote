import 'package:cross_desktop_remote/core/input/host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/mac_input_bridge.dart';

class MacHostPlatformAdapter implements HostPlatformAdapter {
  const MacHostPlatformAdapter({this.bridge = const MacInputBridge()});

  final MacInputBridge bridge;

  @override
  HostPlatformType get type => HostPlatformType.macOS;

  @override
  HostPlatformCapabilities get capabilities => const HostPlatformCapabilities(
    canHostDesktop: true,
    captureFrameReadiness: true,
    colorDiagnostics: true,
    permissionSettings: true,
    capturePermissionSettings: true,
  );

  @override
  Future<List<HostDisplay>> listDisplays() async {
    final displays = await bridge.listDisplays();
    return displays
        .map(
          (display) => HostDisplay(
            id: display.id,
            name: display.name,
            width: display.width,
            height: display.height,
            pixelWidth: display.pixelWidth,
            pixelHeight: display.pixelHeight,
            pointPixelScale: display.pointPixelScale,
            isPrimary: display.isPrimary,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<HostPermissionState> checkPermissions() async {
    final input = await bridge.checkInputAccess();
    final capture = await bridge.checkScreenCaptureAccess();
    return HostPermissionState(
      inputGranted: input,
      screenCaptureGranted: capture,
      limitation: input ? null : '尚未允许辅助功能/输入监控权限',
      screenCaptureLimitation: capture ? null : '尚未允许屏幕与系统音频录制权限',
    );
  }

  @override
  Future<HostPermissionState> requestPermissions() async {
    await bridge.requestInputAccess();
    return checkPermissions();
  }

  @override
  Future<bool> openPermissionSettings() => bridge.openInputSettings();

  @override
  Future<HostPermissionState> requestScreenCapturePermission() async {
    await bridge.requestScreenCaptureAccess();
    return checkPermissions();
  }

  @override
  Future<bool> openScreenCapturePermissionSettings() =>
      bridge.openScreenCaptureSettings();

  @override
  Future<void> sendPointer(HostPointerEvent event) {
    return bridge.sendPointer(
      phase: event.phase,
      x: event.x,
      y: event.y,
      displayId: event.displayId,
      mode: event.mode,
      button: event.button,
      clickCount: event.clickCount,
      movementX: event.movementX,
      movementY: event.movementY,
      deltaX: event.deltaX,
      deltaY: event.deltaY,
      modifiers: event.modifiers,
    );
  }

  @override
  Future<void> sendKey(HostKeyEvent event) {
    return bridge.sendKey(
      phase: event.phase,
      key: event.key,
      modifiers: event.modifiers,
    );
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
  Future<HostCaptureFrameState?> getCaptureFrameState() async {
    final state = await bridge.getCaptureFrameState();
    return HostCaptureFrameState(
      sequence: state.sequence,
      sourceId: state.sourceId,
      width: state.width,
      height: state.height,
      captureGeneration: state.captureGeneration,
      gateStatus: state.gateStatus,
      rejectionReason: state.rejectionReason,
      staleFrameCount: state.staleFrameCount,
      wrongSizeCount: state.wrongSizeCount,
      missingContentMetadataCount: state.missingContentMetadataCount,
      contentAspectMismatchCount: state.contentAspectMismatchCount,
      normalizationFailureCount: state.normalizationFailureCount,
      bufferWidth: state.bufferWidth,
      bufferHeight: state.bufferHeight,
      activeContentX: state.activeContentX,
      activeContentY: state.activeContentY,
      activeContentWidth: state.activeContentWidth,
      activeContentHeight: state.activeContentHeight,
    );
  }

  @override
  Future<Map<String, dynamic>> getColorDiagnostics() {
    return bridge.getColorDiagnostics();
  }

  @override
  Future<void> showGrayscaleTestPattern() {
    return bridge.showGrayscaleTestPattern();
  }

  @override
  Future<bool> openDisplaySettings() => bridge.openDisplaySettings();
}
