import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_desktop_remote/core/security/trusted_device_models.dart';
import 'package:crypto/crypto.dart';

/// Builds and verifies the identity-to-media transcript used by trusted
/// sessions. Signaling transports this value, but cannot alter it without
/// invalidating the peer signature.
final class TrustedWebRtcBindingCodec {
  const TrustedWebRtcBindingCodec();

  TrustedSessionBinding build({
    required String sessionId,
    required Uint8List controllerNonce,
    required Uint8List hostNonce,
    required Set<TrustedPermission> requestedPermissions,
    required TrustedPeerIdentity controllerIdentity,
    required TrustedPeerIdentity hostIdentity,
    required String offerSdp,
    required String answerSdp,
    required DateTime expiresAt,
    int authSuiteVersion = trustedAuthSuiteLegacy,
    Uint8List? authorizationSha256,
    Uint8List? capabilitySha256,
  }) {
    final binding = TrustedSessionBinding(
      sessionId: sessionId,
      controllerNonce: controllerNonce,
      hostNonce: hostNonce,
      requestedPermissions: requestedPermissions,
      // Protocol v1 names these fields "ephemeral". They intentionally carry
      // the certified authentication-key references; the actual ephemeral
      // key agreement belongs to DTLS and is pinned by both fingerprints.
      controllerEphemeralPublicKey: controllerIdentity.authenticationPublicKey,
      hostEphemeralPublicKey: hostIdentity.authenticationPublicKey,
      offerSha256: _sha256Utf8(offerSdp),
      answerSha256: _sha256Utf8(answerSdp),
      controllerDtlsFingerprintSha256: dtlsSha256Fingerprint(answerSdp),
      hostDtlsFingerprintSha256: dtlsSha256Fingerprint(offerSdp),
      expiresAt: expiresAt.toUtc(),
      authSuiteVersion: authSuiteVersion,
      authorizationSha256: authorizationSha256 ?? Uint8List(32),
      capabilitySha256: capabilitySha256 ?? Uint8List(32),
    );
    binding.validateStructure();
    return binding;
  }

  bool matchesTranscript(
    TrustedSessionBinding binding, {
    required String sessionId,
    required Uint8List controllerNonce,
    required Uint8List hostNonce,
    required Set<TrustedPermission> requestedPermissions,
    required TrustedPeerIdentity controllerIdentity,
    required TrustedPeerIdentity hostIdentity,
    required String offerSdp,
    required String answerSdp,
    int authSuiteVersion = trustedAuthSuiteLegacy,
    Uint8List? authorizationSha256,
    Uint8List? capabilitySha256,
  }) {
    final expected = build(
      sessionId: sessionId,
      controllerNonce: controllerNonce,
      hostNonce: hostNonce,
      requestedPermissions: requestedPermissions,
      controllerIdentity: controllerIdentity,
      hostIdentity: hostIdentity,
      offerSdp: offerSdp,
      answerSdp: answerSdp,
      expiresAt: binding.expiresAt,
      authSuiteVersion: authSuiteVersion,
      authorizationSha256: authorizationSha256,
      capabilitySha256: capabilitySha256,
    );
    return constantTimeBytesEqual(expected.signingBytes, binding.signingBytes);
  }

  Uint8List dtlsSha256Fingerprint(String sdp) {
    final matches = RegExp(
      r'^a=fingerprint:sha-256\s+([0-9A-Fa-f:]{95})\s*$',
      multiLine: true,
    ).allMatches(sdp.replaceAll('\r\n', '\n'));
    if (matches.isEmpty) {
      throw const FormatException(
        'WebRTC SDP is missing a SHA-256 DTLS fingerprint',
      );
    }
    final distinct = matches
        .map((match) => match.group(1)!.replaceAll(':', '').toLowerCase())
        .toSet();
    if (distinct.length != 1) {
      throw const FormatException(
        'WebRTC SDP contains inconsistent SHA-256 DTLS fingerprints',
      );
    }
    final hex = distinct.single;
    return Uint8List.fromList([
      for (var index = 0; index < hex.length; index += 2)
        int.parse(hex.substring(index, index + 2), radix: 16),
    ]);
  }

  static Uint8List _sha256Utf8(String value) =>
      Uint8List.fromList(sha256.convert(utf8.encode(value)).bytes);
}
