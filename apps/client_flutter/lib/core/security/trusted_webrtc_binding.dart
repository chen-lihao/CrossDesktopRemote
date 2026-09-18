import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_desktop_remote/core/security/trusted_device_models.dart';
import 'package:crypto/crypto.dart';

enum TrustedSdpDescriptionType { offer, answer }

/// Small signed transcript for one SDP document. The complete SDP travels as
/// a normal signaling field; this manifest is the only part placed inside the
/// size-limited trusted envelope.
final class TrustedSdpManifest {
  const TrustedSdpManifest({
    required this.descriptionType,
    required this.sessionId,
    required this.controllerNonce,
    required this.hostNonce,
    required this.requestedPermissions,
    required this.controllerAuthenticationPublicKey,
    required this.hostAuthenticationPublicKey,
    required this.sdpSha256,
    required this.dtlsFingerprintSha256,
    required this.expiresAt,
    required this.authSuiteVersion,
    required this.authorizationSha256,
    required this.capabilitySha256,
  });

  factory TrustedSdpManifest.fromJson(Map<String, dynamic> value) =>
      TrustedSdpManifest(
        descriptionType: TrustedSdpDescriptionType.values.byName(
          value['descriptionType'] as String,
        ),
        sessionId: value['sessionId'] as String,
        controllerNonce: base64Decode(value['controllerNonce'] as String),
        hostNonce: base64Decode(value['hostNonce'] as String),
        requestedPermissions: trustedPermissionsFromBitsStrict(
          (value['permissionBits'] as num).toInt(),
        ),
        controllerAuthenticationPublicKey: base64Decode(
          value['controllerAuthenticationPublicKey'] as String,
        ),
        hostAuthenticationPublicKey: base64Decode(
          value['hostAuthenticationPublicKey'] as String,
        ),
        sdpSha256: base64Decode(value['sdpSha256'] as String),
        dtlsFingerprintSha256: base64Decode(
          value['dtlsFingerprintSha256'] as String,
        ),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (value['expiresAtUnixMs'] as num).toInt(),
          isUtc: true,
        ),
        authSuiteVersion: (value['authSuiteVersion'] as num).toInt(),
        authorizationSha256: base64Decode(
          value['authorizationSha256'] as String,
        ),
        capabilitySha256: base64Decode(value['capabilitySha256'] as String),
      );

  final TrustedSdpDescriptionType descriptionType;
  final String sessionId;
  final Uint8List controllerNonce;
  final Uint8List hostNonce;
  final Set<TrustedPermission> requestedPermissions;
  final Uint8List controllerAuthenticationPublicKey;
  final Uint8List hostAuthenticationPublicKey;
  final Uint8List sdpSha256;
  final Uint8List dtlsFingerprintSha256;
  final DateTime expiresAt;
  final int authSuiteVersion;
  final Uint8List authorizationSha256;
  final Uint8List capabilitySha256;

  Uint8List get signingBytes => securityCanonicalBytes((out) {
    out.bytes(utf8.encode('CrossDesktopRemote/TrustedSdpManifest/v1'));
    out.uint32(descriptionType.index + 1);
    out.bytes(utf8.encode(sessionId));
    out.bytes(controllerNonce);
    out.bytes(hostNonce);
    out.uint64(trustedPermissionBits(requestedPermissions));
    out.bytes(controllerAuthenticationPublicKey);
    out.bytes(hostAuthenticationPublicKey);
    out.bytes(sdpSha256);
    out.bytes(dtlsFingerprintSha256);
    out.uint64(expiresAt.toUtc().millisecondsSinceEpoch);
    out.uint32(authSuiteVersion);
    out.bytes(authorizationSha256);
    out.bytes(capabilitySha256);
  });

  Map<String, dynamic> toJson() => {
    'descriptionType': descriptionType.name,
    'sessionId': sessionId,
    'controllerNonce': base64Encode(controllerNonce),
    'hostNonce': base64Encode(hostNonce),
    'permissionBits': trustedPermissionBits(requestedPermissions),
    'controllerAuthenticationPublicKey': base64Encode(
      controllerAuthenticationPublicKey,
    ),
    'hostAuthenticationPublicKey': base64Encode(hostAuthenticationPublicKey),
    'sdpSha256': base64Encode(sdpSha256),
    'dtlsFingerprintSha256': base64Encode(dtlsFingerprintSha256),
    'expiresAtUnixMs': expiresAt.toUtc().millisecondsSinceEpoch,
    'authSuiteVersion': authSuiteVersion,
    'authorizationSha256': base64Encode(authorizationSha256),
    'capabilitySha256': base64Encode(capabilitySha256),
  };
}

/// Builds and verifies the identity-to-media transcript used by trusted
/// sessions. Signaling transports this value, but cannot alter it without
/// invalidating the peer signature.
final class TrustedWebRtcBindingCodec {
  const TrustedWebRtcBindingCodec();

  TrustedSdpManifest buildOfferManifest({
    required String sessionId,
    required Uint8List controllerNonce,
    required Uint8List hostNonce,
    required Set<TrustedPermission> requestedPermissions,
    required TrustedPeerIdentity controllerIdentity,
    required TrustedPeerIdentity hostIdentity,
    required String offerSdp,
    required DateTime expiresAt,
    required Uint8List authorizationSha256,
    required Uint8List capabilitySha256,
  }) => TrustedSdpManifest(
    descriptionType: TrustedSdpDescriptionType.offer,
    sessionId: sessionId,
    controllerNonce: controllerNonce,
    hostNonce: hostNonce,
    requestedPermissions: requestedPermissions,
    controllerAuthenticationPublicKey:
        controllerIdentity.authenticationPublicKey,
    hostAuthenticationPublicKey: hostIdentity.authenticationPublicKey,
    sdpSha256: _sha256Utf8(offerSdp),
    dtlsFingerprintSha256: dtlsSha256Fingerprint(offerSdp),
    expiresAt: expiresAt.toUtc(),
    authSuiteVersion: trustedAuthSuiteV2,
    authorizationSha256: authorizationSha256,
    capabilitySha256: capabilitySha256,
  );

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
