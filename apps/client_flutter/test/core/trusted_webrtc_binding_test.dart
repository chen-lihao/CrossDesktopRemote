import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_desktop_remote/core/security/trusted_device_models.dart';
import 'package:cross_desktop_remote/core/security/trusted_webrtc_binding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = TrustedWebRtcBindingCodec();
  const fingerprintA =
      '11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:'
      '11:11:11:11:11:11:11:11:11:11:11:11:11:11:11:11';
  const fingerprintB =
      '22:22:22:22:22:22:22:22:22:22:22:22:22:22:22:22:'
      '22:22:22:22:22:22:22:22:22:22:22:22:22:22:22:22';
  final offer = 'v=0\r\na=fingerprint:sha-256 $fingerprintA\r\n';
  final answer = 'v=0\r\na=fingerprint:sha-256 $fingerprintB\r\n';
  final controller = _identity(1);
  final host = _identity(2);

  test('builds a deterministic binding for the signed SDP transcript', () {
    final first = codec.build(
      sessionId: 'route-1',
      controllerNonce: Uint8List.fromList(List.filled(16, 3)),
      hostNonce: Uint8List.fromList(List.filled(16, 1)),
      requestedPermissions: defaultTrustedPermissions,
      controllerIdentity: controller,
      hostIdentity: host,
      offerSdp: offer,
      answerSdp: answer,
      expiresAt: DateTime.utc(2026, 9, 13, 10),
    );
    final restored = TrustedSessionBinding.fromJson(first.toJson());

    expect(restored.signingBytes, orderedEquals(first.signingBytes));
    expect(
      codec.matchesTranscript(
        restored,
        sessionId: 'route-1',
        controllerNonce: Uint8List.fromList(List.filled(16, 3)),
        hostNonce: Uint8List.fromList(List.filled(16, 1)),
        requestedPermissions: defaultTrustedPermissions,
        controllerIdentity: controller,
        hostIdentity: host,
        offerSdp: offer,
        answerSdp: answer,
      ),
      isTrue,
    );
  });

  test('rejects modified SDP and inconsistent fingerprint lines', () {
    final binding = codec.build(
      sessionId: 'route-2',
      controllerNonce: Uint8List.fromList(List.filled(16, 3)),
      hostNonce: Uint8List.fromList(List.filled(16, 2)),
      requestedPermissions: defaultTrustedPermissions,
      controllerIdentity: controller,
      hostIdentity: host,
      offerSdp: offer,
      answerSdp: answer,
      expiresAt: DateTime.utc(2026, 9, 13, 10),
    );

    expect(
      codec.matchesTranscript(
        binding,
        sessionId: 'route-2',
        controllerNonce: Uint8List.fromList(List.filled(16, 3)),
        hostNonce: Uint8List.fromList(List.filled(16, 2)),
        requestedPermissions: defaultTrustedPermissions,
        controllerIdentity: controller,
        hostIdentity: host,
        offerSdp: '$offer\na=x-tampered:1',
        answerSdp: answer,
      ),
      isFalse,
    );
    expect(
      () => codec.dtlsSha256Fingerprint(
        '$offer\n'
        'a=fingerprint:sha-256 $fingerprintB\n',
      ),
      throwsFormatException,
    );
  });

  test('rejects empty nonce and transcript hash sentinels', () {
    expect(
      () => codec.build(
        sessionId: 'route-3',
        controllerNonce: Uint8List(16),
        hostNonce: Uint8List.fromList(List.filled(16, 4)),
        requestedPermissions: defaultTrustedPermissions,
        controllerIdentity: controller,
        hostIdentity: host,
        offerSdp: offer,
        answerSdp: answer,
        expiresAt: DateTime.utc(2026, 9, 13, 10),
      ),
      throwsFormatException,
    );
  });

  test('large Windows SDP is represented by a compact signed manifest', () {
    final largeOffer = StringBuffer(offer);
    while (utf8.encode(largeOffer.toString()).length < 60 * 1024) {
      largeOffer.writeln('a=fmtp:96 x-google-start-bitrate=2500');
    }
    final manifest = codec.buildOfferManifest(
      sessionId: 'route-large-windows-offer',
      controllerNonce: Uint8List.fromList(List.filled(16, 3)),
      hostNonce: Uint8List.fromList(List.filled(16, 4)),
      requestedPermissions: defaultHostAccessPermissions,
      controllerIdentity: controller,
      hostIdentity: host,
      offerSdp: largeOffer.toString(),
      expiresAt: DateTime.utc(2026, 9, 13, 10),
      authorizationSha256: Uint8List.fromList(List.filled(32, 7)),
      capabilitySha256: Uint8List.fromList(List.filled(32, 8)),
    );
    final restored = TrustedSdpManifest.fromJson(manifest.toJson());

    expect(utf8.encode(largeOffer.toString()).length, greaterThan(32 * 1024));
    expect(manifest.signingBytes.length, lessThan(1024));
    expect(restored.signingBytes, orderedEquals(manifest.signingBytes));
  });

  test('suite v2 binds the accepted authorization and capability set', () {
    final authorizationSha256 = Uint8List.fromList(List.filled(32, 7));
    final capabilitySha256 = trustedAuthSuiteCapabilityHash(trustedAuthSuiteV2);
    final binding = codec.build(
      sessionId: 'route-v2',
      controllerNonce: Uint8List.fromList(List.filled(16, 3)),
      hostNonce: Uint8List.fromList(List.filled(16, 4)),
      requestedPermissions: defaultHostAccessPermissions,
      controllerIdentity: controller,
      hostIdentity: host,
      offerSdp: offer,
      answerSdp: answer,
      expiresAt: DateTime.utc(2026, 9, 13, 10),
      authSuiteVersion: trustedAuthSuiteV2,
      authorizationSha256: authorizationSha256,
      capabilitySha256: capabilitySha256,
    );
    final restored = TrustedSessionBinding.fromJson(binding.toJson());

    expect(restored.signingBytes, orderedEquals(binding.signingBytes));
    expect(
      codec.matchesTranscript(
        restored,
        sessionId: 'route-v2',
        controllerNonce: Uint8List.fromList(List.filled(16, 3)),
        hostNonce: Uint8List.fromList(List.filled(16, 4)),
        requestedPermissions: defaultHostAccessPermissions,
        controllerIdentity: controller,
        hostIdentity: host,
        offerSdp: offer,
        answerSdp: answer,
        authSuiteVersion: trustedAuthSuiteV2,
        authorizationSha256: authorizationSha256,
        capabilitySha256: Uint8List.fromList(List.filled(32, 8)),
      ),
      isFalse,
    );
    expect(
      codec.matchesTranscript(
        restored,
        sessionId: 'route-v2',
        controllerNonce: Uint8List.fromList(List.filled(16, 3)),
        hostNonce: Uint8List.fromList(List.filled(16, 4)),
        requestedPermissions: defaultHostAccessPermissions,
        controllerIdentity: controller,
        hostIdentity: host,
        offerSdp: offer,
        answerSdp: answer,
        authSuiteVersion: trustedAuthSuiteV2,
        authorizationSha256: Uint8List.fromList(List.filled(32, 9)),
        capabilitySha256: capabilitySha256,
      ),
      isFalse,
    );
  });

  test(
    'authorization acknowledgement round-trips without losing authority',
    () {
      final acknowledgement = TrustedSessionAuthorizationAck(
        sessionId: 'route-ack',
        authorizationSha256: Uint8List.fromList(List.filled(32, 7)),
        policyRevision: 5,
        permissions: defaultHostAccessPermissions,
        controllerRootFingerprint: Uint8List.fromList(List.filled(32, 1)),
        hostRootFingerprint: Uint8List.fromList(List.filled(32, 2)),
        controllerNonce: Uint8List.fromList(List.filled(16, 3)),
        hostNonce: Uint8List.fromList(List.filled(16, 4)),
        issuedAt: DateTime.utc(2026, 9, 13, 9),
        expiresAt: DateTime.utc(2026, 9, 13, 9, 0, 45),
        authSuiteVersion: trustedAuthSuiteV2,
        capabilitySha256: trustedAuthSuiteCapabilityHash(trustedAuthSuiteV2),
      );
      final restored = TrustedSessionAuthorizationAck.fromJson(
        acknowledgement.toJson(),
      );

      restored.validateStructure();
      expect(
        restored.signingBytes,
        orderedEquals(acknowledgement.signingBytes),
      );

      final tampered = <String, Object?>{
        ...acknowledgement.toJson(),
        'authorizationSha256': base64Encode(Uint8List(32)),
      };
      expect(
        () =>
            TrustedSessionAuthorizationAck.fromJson(tampered)
                .validateStructure(),
        throwsFormatException,
      );
    },
  );
}

TrustedPeerIdentity _identity(int fill) => TrustedPeerIdentity(
  machineCode: 'CDR2-AAAA-BBBB-CCCC-DDDD',
  rootPublicKey: Uint8List.fromList([0x04, ...List.filled(64, fill)]),
  rootFingerprint: Uint8List.fromList(List.filled(32, fill)),
  authenticationPublicKey: Uint8List.fromList([
    0x04,
    ...List.filled(64, fill + 2),
  ]),
  authenticationNotBefore: DateTime.utc(2026, 9, 1),
  authenticationExpiresAt: DateTime.utc(2026, 10, 1),
  authenticationCertificate: Uint8List.fromList(List.filled(70, fill + 4)),
);
