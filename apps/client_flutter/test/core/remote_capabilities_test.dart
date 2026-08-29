import 'package:cross_desktop_remote/core/signaling/remote_capabilities.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS controller advertises only crop-aware geometry v3', () {
    final capabilities = buildRemoteClientCapabilities(
      role: RemoteRole.controller,
      platform: 'ios',
      clipboardSupported: true,
      explicitFileTransferSupported: true,
    );

    expect(capabilities, contains(activeContentGeometryV3Capability));
    expect(capabilities, isNot(contains(activeContentGeometryV2Capability)));
    expect(capabilities, contains(textClipboardV1Capability));
    expect(capabilities, contains(explicitFileTransferV1Capability));
  });

  test('Windows controller keeps v2 fallback and advertises v3', () {
    final capabilities = buildRemoteClientCapabilities(
      role: RemoteRole.controller,
      platform: 'windows',
      clipboardSupported: false,
      explicitFileTransferSupported: false,
    );

    expect(capabilities, [
      activeContentGeometryV2Capability,
      activeContentGeometryV3Capability,
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

    expect(capabilities, isEmpty);
  });

  test('host and unsupported controllers do not advertise geometry', () {
    expect(
      buildRemoteClientCapabilities(
        role: RemoteRole.host,
        platform: 'ios',
        clipboardSupported: false,
        explicitFileTransferSupported: false,
      ),
      isEmpty,
    );
    expect(
      buildRemoteClientCapabilities(
        role: RemoteRole.controller,
        platform: 'android',
        clipboardSupported: false,
        explicitFileTransferSupported: false,
      ),
      isEmpty,
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
}
