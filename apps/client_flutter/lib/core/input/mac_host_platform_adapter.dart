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
    return HostPermissionState(inputGranted: await bridge.checkInputAccess());
  }

  @override
  Future<HostPermissionState> requestPermissions() async {
    return HostPermissionState(inputGranted: await bridge.requestInputAccess());
  }

  @override
  Future<bool> openPermissionSettings() => bridge.openInputSettings();

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
  Future<void> releasePointerButtons() => bridge.releasePointerButtons();

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
