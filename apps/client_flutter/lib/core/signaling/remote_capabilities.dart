import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:crypto/crypto.dart';

const activeContentGeometryV2Capability = 'active-content-geometry-v2';
const activeContentGeometryV3Capability = 'active-content-geometry-v3';
const displaySwitchTransactionV1Capability = 'display-switch-transaction-v1';
const textureCropRenderingV1Capability = 'texture-crop-rendering-v1';
const textClipboardV1Capability = 'text-clipboard-v1';
const explicitFileTransferV1Capability = 'explicit-file-transfer-v1';
const fileClipboardV1Capability = 'file-clipboard-v1';
const destinationLeasedFilePasteV1Capability =
    'destination-leased-file-paste-v1';
const atomicShortcutV1Capability = 'atomic-shortcut-v1';
const scopedInputResetV1Capability = 'scoped-input-reset-v1';
const videoPolicyV2Capability = 'video-policy-v2';
const multiDisplayStreamV1Capability = 'multi-display-stream-v1';
const deviceIdentityV1Capability = 'device-identity-v1';
const trustedDeviceAuthV1Capability = 'trusted-device-auth-v1';
const signedWebRtcBindingV1Capability = 'signed-webrtc-binding-v1';
const trustLeaseRenewalV1Capability = 'trust-lease-renewal-v1';
const trustedPairingTransactionV1Capability = 'trusted-pairing-transaction-v1';
const decoupledTrustPolicyV1Capability = 'decoupled-trust-policy-v1';
const hostSessionAuthorizationV1Capability = 'host-session-authorization-v1';
const directionalFilePermissionsV1Capability =
    'directional-file-permissions-v1';
const trustedAuthSuiteV2Capability = 'trusted-auth-suite-v2';
const completeCapabilityManifestV1Capability = 'capability-manifest-v1';
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
  bool fileClipboardSupported = false,
  bool trustedDeviceAuthenticationSupported = false,
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
  if (clipboardSupported &&
      explicitFileTransferSupported &&
      fileClipboardSupported) {
    if (normalizedPlatform == 'macos' || normalizedPlatform == 'windows') {
      capabilities.add(destinationLeasedFilePasteV1Capability);
    }
  }
  capabilities.add(atomicShortcutV1Capability);
  capabilities.add(scopedInputResetV1Capability);
  capabilities.add(videoPolicyV2Capability);
  if (trustedDeviceAuthenticationSupported) {
    capabilities.addAll(const [
      deviceIdentityV1Capability,
      trustedDeviceAuthV1Capability,
      signedWebRtcBindingV1Capability,
      trustLeaseRenewalV1Capability,
      trustedPairingTransactionV1Capability,
      decoupledTrustPolicyV1Capability,
      hostSessionAuthorizationV1Capability,
      directionalFilePermissionsV1Capability,
      trustedAuthSuiteV2Capability,
    ]);
  }
  return capabilities;
}

bool supportsTrustedDeviceAuthentication(Iterable<String> capabilities) =>
    capabilities.contains(deviceIdentityV1Capability) &&
    capabilities.contains(trustedDeviceAuthV1Capability) &&
    capabilities.contains(signedWebRtcBindingV1Capability);

bool supportsTransactionalTrustedPairing(Iterable<String> capabilities) =>
    supportsTrustedDeviceAuthentication(capabilities) &&
    capabilities.contains(trustedPairingTransactionV1Capability);

bool supportsHostOwnedTrustedPolicy(Iterable<String> capabilities) =>
    supportsTrustedDeviceAuthentication(capabilities) &&
    capabilities.contains(decoupledTrustPolicyV1Capability) &&
    capabilities.contains(hostSessionAuthorizationV1Capability) &&
    capabilities.contains(directionalFilePermissionsV1Capability);

bool supportsTrustedAuthSuiteV2(Iterable<String> capabilities) =>
    supportsHostOwnedTrustedPolicy(capabilities) &&
    capabilities.contains(trustedAuthSuiteV2Capability);

bool supportsCompleteTrustedRouteV2({
  required Iterable<String> serverCapabilities,
  required Iterable<String> localCapabilities,
  required Iterable<String> remoteCapabilities,
}) =>
    serverCapabilities.contains(completeCapabilityManifestV1Capability) &&
    supportsTrustedAuthSuiteV2(localCapabilities) &&
    supportsTrustedAuthSuiteV2(remoteCapabilities);

/// Produces the canonical transcript hash for the capabilities that both
/// endpoints actually advertised. The same intersection is computed on both
/// roles, so signaling reordering and duplicates cannot change the result.
Uint8List negotiatedTrustedCapabilityHash({
  required int authSuiteVersion,
  required Iterable<String> localCapabilities,
  required Iterable<String> remoteCapabilities,
}) {
  if (authSuiteVersion <= 1) return Uint8List(32);
  final local = localCapabilities
      .map((value) => value.trim().toLowerCase())
      .toSet();
  final negotiated =
      remoteCapabilities
          .map((value) => value.trim().toLowerCase())
          .where(local.contains)
          .toSet()
          .toList(growable: false)
        ..sort();
  return Uint8List.fromList(
    sha256
        .convert(
          utf8.encode(
            'CrossDesktopRemote/NegotiatedCapabilities/v1\n'
            '$authSuiteVersion\n'
            '${negotiated.join('\n')}\n',
          ),
        )
        .bytes,
  );
}

bool supportsActiveContentGeometry(Iterable<String> capabilities) {
  return activeContentGeometryVersion(capabilities) > 0;
}

int activeContentGeometryVersion(Iterable<String> capabilities) {
  if (capabilities.contains(activeContentGeometryV3Capability)) return 3;
  if (capabilities.contains(activeContentGeometryV2Capability)) return 2;
  return 0;
}
