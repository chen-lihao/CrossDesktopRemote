import 'package:cross_desktop_remote/core/signaling/remote_capabilities.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS and Windows controllers share the same switch capabilities', () {
    final capabilities = buildRemoteClientCapabilities(
      role: RemoteRole.controller,
      platform: 'ios',
      clipboardSupported: true,
      explicitFileTransferSupported: true,
    );

    final windowsCapabilities = buildRemoteClientCapabilities(
      role: RemoteRole.controller,
      platform: 'windows',
      clipboardSupported: true,
      explicitFileTransferSupported: true,
    );

    expect(capabilities, windowsCapabilities);
    expect(capabilities, contains(displaySwitchTransactionV1Capability));
    expect(capabilities, contains(activeContentGeometryV2Capability));
    expect(capabilities, contains(activeContentGeometryV3Capability));
    expect(capabilities, contains(textureCropRenderingV1Capability));
    expect(capabilities, contains(textClipboardV1Capability));
    expect(capabilities, contains(explicitFileTransferV1Capability));
  });

  test('crop-aware controllers retain the legacy geometry fallback', () {
    final capabilities = buildRemoteClientCapabilities(
      role: RemoteRole.controller,
      platform: 'windows',
      clipboardSupported: false,
      explicitFileTransferSupported: false,
    );

    expect(capabilities, [
      displaySwitchTransactionV1Capability,
      activeContentGeometryV2Capability,
      activeContentGeometryV3Capability,
      textureCropRenderingV1Capability,
      atomicShortcutV1Capability,
    ]);
  });

  test('iOS geometry capability can be disabled for physical rollback', () {
    final capabilities = buildRemoteClientCapabilities(
      role: RemoteRole.controller,
      platform: 'ios',
      clipboardSupported: false,
      explicitFileTransferSupported: false,
      enableIosGeometryV3: false,
    );

    expect(capabilities, [
      displaySwitchTransactionV1Capability,
      atomicShortcutV1Capability,
    ]);
  });

  test('host does not advertise controller capabilities', () {
    expect(
      buildRemoteClientCapabilities(
        role: RemoteRole.host,
        platform: 'ios',
        clipboardSupported: false,
        explicitFileTransferSupported: false,
      ),
      [atomicShortcutV1Capability],
    );
  });

  test('legacy renderers still use the unified display transaction', () {
    expect(
      buildRemoteClientCapabilities(
        role: RemoteRole.controller,
        platform: 'android',
        clipboardSupported: false,
        explicitFileTransferSupported: false,
      ),
      [displaySwitchTransactionV1Capability, atomicShortcutV1Capability],
    );
  });

  test('host accepts both geometry generations', () {
    expect(
      supportsActiveContentGeometry([activeContentGeometryV2Capability]),
      isTrue,
    );
    expect(
      supportsActiveContentGeometry([activeContentGeometryV3Capability]),
      isTrue,
    );
    expect(supportsActiveContentGeometry(const []), isFalse);
    expect(
      activeContentGeometryVersion([activeContentGeometryV3Capability]),
      3,
    );
    expect(
      activeContentGeometryVersion([activeContentGeometryV2Capability]),
      2,
    );
    expect(activeContentGeometryVersion(const []), 0);
  });

  test('file clipboard requires clipboard and explicit transfer support', () {
    final capabilities = buildRemoteClientCapabilities(
      role: RemoteRole.host,
      platform: 'windows',
      clipboardSupported: true,
      explicitFileTransferSupported: true,
      fileClipboardSupported: true,
    );
    expect(capabilities, contains(textClipboardV1Capability));
    expect(capabilities, contains(explicitFileTransferV1Capability));
    expect(capabilities, contains(fileClipboardV1Capability));

    expect(
      buildRemoteClientCapabilities(
        role: RemoteRole.host,
        platform: 'windows',
        clipboardSupported: false,
        explicitFileTransferSupported: true,
        fileClipboardSupported: true,
      ),
      isNot(contains(fileClipboardV1Capability)),
    );
  });
}
