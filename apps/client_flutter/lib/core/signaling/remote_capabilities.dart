import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';

const activeContentGeometryV2Capability = 'active-content-geometry-v2';
const activeContentGeometryV3Capability = 'active-content-geometry-v3';
const displaySwitchTransactionV1Capability = 'display-switch-transaction-v1';
const textureCropRenderingV1Capability = 'texture-crop-rendering-v1';
const textClipboardV1Capability = 'text-clipboard-v1';
const explicitFileTransferV1Capability = 'explicit-file-transfer-v1';
const iosActiveContentGeometryV3Enabled = bool.fromEnvironment(
  'CDR_IOS_ACTIVE_CONTENT_GEOMETRY_V3',
  defaultValue: true,
);

bool usesCropAwareRemoteTexture(String platform) {
  final normalizedPlatform = platform.trim().toLowerCase();
  return normalizedPlatform == 'windows' ||
      (normalizedPlatform == 'ios' && iosActiveContentGeometryV3Enabled);
}

/// Builds the capabilities that are safe for the local presentation stack.
///
/// Display switching is one shared transaction on every controller. Platform
/// detection only describes the renderer boundary; it never changes the
/// transaction state machine or its media acknowledgement rules.
List<String> buildRemoteClientCapabilities({
  required RemoteRole role,
  required String platform,
  required bool clipboardSupported,
  required bool explicitFileTransferSupported,
  bool enableIosGeometryV3 = iosActiveContentGeometryV3Enabled,
}) {
  final capabilities = <String>[];
  final normalizedPlatform = platform.trim().toLowerCase();
  if (role == RemoteRole.controller) {
    capabilities.add(displaySwitchTransactionV1Capability);
    final cropAware =
        normalizedPlatform == 'windows' ||
        (normalizedPlatform == 'ios' && enableIosGeometryV3);
    if (cropAware) {
      capabilities.add(activeContentGeometryV2Capability);
      capabilities.add(activeContentGeometryV3Capability);
      capabilities.add(textureCropRenderingV1Capability);
    }
  }
  if (clipboardSupported) capabilities.add(textClipboardV1Capability);
  if (explicitFileTransferSupported) {
    capabilities.add(explicitFileTransferV1Capability);
  }
  return capabilities;
}

bool supportsActiveContentGeometry(Iterable<String> capabilities) {
  return activeContentGeometryVersion(capabilities) > 0;
}

int activeContentGeometryVersion(Iterable<String> capabilities) {
  if (capabilities.contains(activeContentGeometryV3Capability)) return 3;
  if (capabilities.contains(activeContentGeometryV2Capability)) return 2;
  return 0;
}
