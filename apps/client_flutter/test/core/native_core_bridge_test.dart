import 'dart:typed_data';
import 'dart:io';

import 'package:cross_desktop_remote/core/bridge/core_bridge.dart';
import 'package:cross_desktop_remote/core/bridge/native_core_bridge.dart';
import 'package:cross_desktop_remote/core/security/trusted_device_models.dart';
import 'package:cross_desktop_remote/core/security/trusted_security_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final libraryPath = Platform.environment['CROSSDESKTOP_CORE_LIBRARY'];

  test(
    'reads build information through the Rust C ABI',
    () {
      final bridge = NativeCoreBridge.open(libraryPath: libraryPath);
      final info = bridge.readBuildInfo();

      expect(info.abiVersion, 1);
      expect(info.protocolMajorVersion, 1);
      expect(info.supports(CoreFeatures.narrowCAbi), isTrue);
      expect(info.supports(CoreFeatures.protobufV1), isTrue);
    },
    skip: libraryPath == null
        ? 'Set CROSSDESKTOP_CORE_LIBRARY to a built Rust dynamic library.'
        : false,
  );

  test(
    'requires a Rust-validated grant before completing pairing',
    () {
      final factory = NativeTrustedSecurityEngineFactory.open(
        libraryPath: libraryPath,
      );
      final session = factory.create(Uint8List.fromList(List.filled(32, 1)));
      addTearDown(session.dispose);

      session.begin(
        sessionId: 'ffi-pairing',
        peerRootFingerprint: Uint8List.fromList(List.filled(32, 2)),
        requestedPermissions: defaultTrustedPermissions,
        mode: TrustedSecuritySessionMode.pairing,
        negotiation: TrustedSessionNegotiationContext.legacy(),
      );
      expect(session.phase, TrustedSecurityPhase.pairingAwaitingConfirmation);
      session.confirmPairing(true);
      expect(session.phase, TrustedSecurityPhase.pairingConfirmed);
      expect(
        session.completePairing,
        throwsA(isA<TrustedSecurityEngineException>()),
      );
      session.end();
    },
    skip: libraryPath == null
        ? 'Set CROSSDESKTOP_CORE_LIBRARY to a built Rust dynamic library.'
        : false,
  );

  test(
    'freezes the trusted WebRTC context through the Rust C ABI',
    () {
      final factory = NativeTrustedSecurityEngineFactory.open(
        libraryPath: libraryPath,
      );
      final session = factory.create(Uint8List.fromList(List.filled(32, 1)));
      addTearDown(session.dispose);

      session.begin(
        sessionId: 'ffi-webrtc-context',
        peerRootFingerprint: Uint8List.fromList(List.filled(32, 2)),
        requestedPermissions: defaultTrustedPermissions,
        mode: TrustedSecuritySessionMode.trustedAuthentication,
        negotiation: TrustedSessionNegotiationContext.legacy(),
      );
      session.configureWebRtcContext(
        controllerNonce: Uint8List.fromList(List.filled(16, 1)),
        hostNonce: Uint8List.fromList(List.filled(16, 2)),
        controllerAuthenticationPublicKey: _p256Generator,
        hostAuthenticationPublicKey: _p256Generator,
      );
      expect(session.phase, TrustedSecurityPhase.authenticating);
    },
    skip: libraryPath == null
        ? 'Set CROSSDESKTOP_CORE_LIBRARY to a built Rust dynamic library.'
        : false,
  );
}

final Uint8List _p256Generator = Uint8List.fromList([
  0x04,
  0x6b,
  0x17,
  0xd1,
  0xf2,
  0xe1,
  0x2c,
  0x42,
  0x47,
  0xf8,
  0xbc,
  0xe6,
  0xe5,
  0x63,
  0xa4,
  0x40,
  0xf2,
  0x77,
  0x03,
  0x7d,
  0x81,
  0x2d,
  0xeb,
  0x33,
  0xa0,
  0xf4,
  0xa1,
  0x39,
  0x45,
  0xd8,
  0x98,
  0xc2,
  0x96,
  0x4f,
  0xe3,
  0x42,
  0xe2,
  0xfe,
  0x1a,
  0x7f,
  0x9b,
  0x8e,
  0xe7,
  0xeb,
  0x4a,
  0x7c,
  0x0f,
  0x9e,
  0x16,
  0x2b,
  0xce,
  0x33,
  0x57,
  0x6b,
  0x31,
  0x5e,
  0xce,
  0xcb,
  0xb6,
  0x40,
  0x68,
  0x37,
  0xbf,
  0x51,
  0xf5,
]);
