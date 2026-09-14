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
