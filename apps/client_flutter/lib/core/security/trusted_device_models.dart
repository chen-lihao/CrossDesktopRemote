import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

const trustedSessionTicketLifetime = Duration(seconds: 60);
const trustedAuthenticationKeyLifetime = Duration(days: 30);
const trustedAuthenticationKeyOverlap = Duration(days: 7);
const trustedGrantSoftLifetime = Duration(days: 90);
const trustedGrantRenewalWindow = Duration(days: 14);
const trustedGrantHardLifetime = Duration(days: 365);
const trustedMaximumClockSkew = Duration(seconds: 30);
// The signaling endpoint accepts 64 KiB JSON messages. Signed payloads are
// base64-encoded inside an envelope, so keep the raw payload below 32 KiB to
// leave deterministic room for the signature and identity metadata.
const trustedMaximumSignedPayloadBytes = 32 * 1024;
const trustedMaximumSessionIdBytes = 128;
const trustedMaximumSignatureBytes = 80;
const trustedAuthSuiteLegacy = 1;
const trustedAuthSuiteV2 = 2;

Uint8List trustedAuthSuiteCapabilityHash(int version) {
  if (version != trustedAuthSuiteV2) {
    return Uint8List(32);
  }
  return Uint8List.fromList(
    sha256
        .convert(
          utf8.encode(
            'CrossDesktopRemote/TrustedAuthSuite/v2\n'
            'decoupled-trust-policy-v1\n'
            'directional-file-permissions-v1\n'
            'host-session-authorization-v1\n'
            'signed-webrtc-binding-v1\n'
            'trusted-auth-suite-v2',
          ),
        )
        .bytes,
  );
}

enum TrustedPermission {
  viewScreen,
  controlInput,
  readClipboard,
  writeClipboard,
  transferFiles,
  captureScreenshot,
  recordSession,
  uploadFilesToHost,
  downloadFilesFromHost,
}

int trustedPermissionBits(Iterable<TrustedPermission> permissions) =>
    permissions.fold(0, (bits, value) => bits | (1 << value.index));

Set<TrustedPermission> trustedPermissionsFromBits(int bits) => {
  for (final permission in TrustedPermission.values)
    if (bits & (1 << permission.index) != 0) permission,
};

Set<TrustedPermission> trustedPermissionsFromBitsStrict(int bits) {
  final validMask = (1 << TrustedPermission.values.length) - 1;
  if (bits < 0 || bits & ~validMask != 0) {
    throw const FormatException('Unknown trusted permission bits');
  }
  return trustedPermissionsFromBits(bits);
}

const defaultTrustedPermissions = {
  TrustedPermission.viewScreen,
  TrustedPermission.controlInput,
};

const defaultHostAccessPermissions = {
  TrustedPermission.viewScreen,
  TrustedPermission.controlInput,
  TrustedPermission.readClipboard,
  TrustedPermission.writeClipboard,
  TrustedPermission.uploadFilesToHost,
  TrustedPermission.downloadFilesFromHost,
};

Set<TrustedPermission> normalizeHostAccessPermissions(
  Iterable<TrustedPermission> permissions,
) {
  final normalized = permissions.toSet();
  if (normalized.remove(TrustedPermission.transferFiles)) {
    normalized
      ..add(TrustedPermission.uploadFilesToHost)
      ..add(TrustedPermission.downloadFilesFromHost);
  }
  return Set.unmodifiable(normalized);
}

Set<TrustedPermission> legacyCompatiblePermissions(
  Iterable<TrustedPermission> permissions,
) {
  final compatible = permissions.toSet();
  if (compatible.contains(TrustedPermission.uploadFilesToHost) &&
      compatible.contains(TrustedPermission.downloadFilesFromHost)) {
    compatible.add(TrustedPermission.transferFiles);
  }
  return Set.unmodifiable(compatible);
}

@immutable
class HostAccessPolicy {
  const HostAccessPolicy({
    required this.controllerRootFingerprint,
    required this.revision,
    required this.enabled,
    required this.permissions,
    required this.updatedAt,
  });

  factory HostAccessPolicy.fromJson(Map<String, dynamic> value) =>
      HostAccessPolicy(
        controllerRootFingerprint: base64Decode(
          value['controllerRootFingerprint'] as String,
        ),
        revision: (value['revision'] as num).toInt(),
        enabled: value['enabled'] == true,
        permissions: normalizeHostAccessPermissions(
          trustedPermissionsFromBitsStrict(
            (value['permissionBits'] as num).toInt(),
          ),
        ),
        updatedAt: DateTime.parse(value['updatedAt'] as String).toUtc(),
      );

  final Uint8List controllerRootFingerprint;
  final int revision;
  final bool enabled;
  final Set<TrustedPermission> permissions;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'controllerRootFingerprint': base64Encode(controllerRootFingerprint),
    'revision': revision,
    'enabled': enabled,
    'permissionBits': trustedPermissionBits(permissions),
    'updatedAt': updatedAt.toIso8601String(),
  };

  void validateStructure() {
    _requireLength(controllerRootFingerprint, 32, 'controllerRootFingerprint');
    if (revision < 1 ||
        permissions.isEmpty ||
        !permissions.contains(TrustedPermission.viewScreen) ||
        permissions.contains(TrustedPermission.transferFiles)) {
      throw const FormatException('Invalid host access policy');
    }
  }
}

@immutable
class TrustedSessionAuthorization {
  const TrustedSessionAuthorization({
    required this.sessionId,
    required this.credentialId,
    required this.policyRevision,
    required this.permissions,
    required this.controllerRootFingerprint,
    required this.hostRootFingerprint,
    required this.controllerNonce,
    required this.hostNonce,
    required this.issuedAt,
    required this.expiresAt,
    required this.authSuiteVersion,
    required this.capabilitySha256,
  });

  factory TrustedSessionAuthorization.fromJson(Map<String, dynamic> value) =>
      TrustedSessionAuthorization(
        sessionId: value['sessionId'] as String,
        credentialId: base64Decode(value['credentialId'] as String),
        policyRevision: (value['policyRevision'] as num).toInt(),
        permissions: normalizeHostAccessPermissions(
          trustedPermissionsFromBitsStrict(
            (value['permissionBits'] as num).toInt(),
          ),
        ),
        controllerRootFingerprint: base64Decode(
          value['controllerRootFingerprint'] as String,
        ),
        hostRootFingerprint: base64Decode(
          value['hostRootFingerprint'] as String,
        ),
        controllerNonce: base64Decode(value['controllerNonce'] as String),
        hostNonce: base64Decode(value['hostNonce'] as String),
        issuedAt: DateTime.fromMillisecondsSinceEpoch(
          (value['issuedAtUnixMs'] as num).toInt(),
          isUtc: true,
        ),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (value['expiresAtUnixMs'] as num).toInt(),
          isUtc: true,
        ),
        authSuiteVersion: (value['authSuiteVersion'] as num).toInt(),
        capabilitySha256: base64Decode(value['capabilitySha256'] as String),
      );

  final String sessionId;
  final Uint8List credentialId;
  final int policyRevision;
  final Set<TrustedPermission> permissions;
  final Uint8List controllerRootFingerprint;
  final Uint8List hostRootFingerprint;
  final Uint8List controllerNonce;
  final Uint8List hostNonce;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final int authSuiteVersion;
  final Uint8List capabilitySha256;

  Uint8List get signingBytes => securityCanonicalBytes((out) {
    out.bytes(utf8.encode('CrossDesktopRemote/TrustedSessionAuthorization/v2'));
    out.bytes(utf8.encode(sessionId));
    out.bytes(credentialId);
    out.uint64(policyRevision);
    out.uint64(trustedPermissionBits(permissions));
    out.bytes(controllerRootFingerprint);
    out.bytes(hostRootFingerprint);
    out.bytes(controllerNonce);
    out.bytes(hostNonce);
    out.uint64(issuedAt.millisecondsSinceEpoch);
    out.uint64(expiresAt.millisecondsSinceEpoch);
    out.uint32(authSuiteVersion);
    out.bytes(capabilitySha256);
  });

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'credentialId': base64Encode(credentialId),
    'policyRevision': policyRevision,
    'permissionBits': trustedPermissionBits(permissions),
    'controllerRootFingerprint': base64Encode(controllerRootFingerprint),
    'hostRootFingerprint': base64Encode(hostRootFingerprint),
    'controllerNonce': base64Encode(controllerNonce),
    'hostNonce': base64Encode(hostNonce),
    'issuedAtUnixMs': issuedAt.millisecondsSinceEpoch,
    'expiresAtUnixMs': expiresAt.millisecondsSinceEpoch,
    'authSuiteVersion': authSuiteVersion,
    'capabilitySha256': base64Encode(capabilitySha256),
  };

  void validateStructure() {
    if (utf8.encode(sessionId).isEmpty ||
        utf8.encode(sessionId).length > trustedMaximumSessionIdBytes ||
        credentialId.length != 16 ||
        policyRevision < 1 ||
        permissions.isEmpty ||
        !permissions.contains(TrustedPermission.viewScreen) ||
        permissions.contains(TrustedPermission.transferFiles) ||
        !expiresAt.isAfter(issuedAt) ||
        authSuiteVersion != trustedAuthSuiteV2) {
      throw const FormatException('Invalid trusted session authorization');
    }
    _requireLength(controllerRootFingerprint, 32, 'controllerRootFingerprint');
    _requireLength(hostRootFingerprint, 32, 'hostRootFingerprint');
    _requireLength(capabilitySha256, 32, 'capabilitySha256');
    if (_allZero(capabilitySha256)) {
      throw const FormatException('Invalid trusted authentication suite');
    }
    _requireLength(controllerNonce, 16, 'controllerNonce');
    _requireLength(hostNonce, 16, 'hostNonce');
  }
}

@immutable
class TrustedPeerIdentity {
  const TrustedPeerIdentity({
    required this.machineCode,
    required this.rootPublicKey,
    required this.rootFingerprint,
    required this.authenticationPublicKey,
    required this.authenticationNotBefore,
    required this.authenticationExpiresAt,
    required this.authenticationCertificate,
  });

  factory TrustedPeerIdentity.fromJson(Map<String, dynamic> value) =>
      TrustedPeerIdentity(
        machineCode: value['machineCode'] as String,
        rootPublicKey: base64Decode(value['rootPublicKey'] as String),
        rootFingerprint: base64Decode(value['rootFingerprint'] as String),
        authenticationPublicKey: base64Decode(
          value['authenticationPublicKey'] as String,
        ),
        authenticationNotBefore: DateTime.fromMillisecondsSinceEpoch(
          (value['authenticationNotBeforeUnixMs'] as num).toInt(),
          isUtc: true,
        ),
        authenticationExpiresAt: DateTime.fromMillisecondsSinceEpoch(
          (value['authenticationExpiresAtUnixMs'] as num).toInt(),
          isUtc: true,
        ),
        authenticationCertificate: base64Decode(
          value['authenticationCertificate'] as String,
        ),
      );

  final String machineCode;
  final Uint8List rootPublicKey;
  final Uint8List rootFingerprint;
  final Uint8List authenticationPublicKey;
  final DateTime authenticationNotBefore;
  final DateTime authenticationExpiresAt;
  final Uint8List authenticationCertificate;

  Map<String, dynamic> toJson() => {
    'machineCode': machineCode,
    'rootPublicKey': base64Encode(rootPublicKey),
    'rootFingerprint': base64Encode(rootFingerprint),
    'authenticationPublicKey': base64Encode(authenticationPublicKey),
    'authenticationNotBeforeUnixMs':
        authenticationNotBefore.millisecondsSinceEpoch,
    'authenticationExpiresAtUnixMs':
        authenticationExpiresAt.millisecondsSinceEpoch,
    'authenticationCertificate': base64Encode(authenticationCertificate),
  };

  Uint8List get authenticationCertificateBody => securityCanonicalBytes((out) {
    out.bytes(utf8.encode('CrossDesktopRemote/AuthKeyCertificate/v1'));
    out.bytes(rootFingerprint);
    out.bytes(authenticationPublicKey);
    out.uint64(authenticationNotBefore.millisecondsSinceEpoch);
    out.uint64(authenticationExpiresAt.millisecondsSinceEpoch);
  });

  void validateStructure() {
    if (!RegExp(r'^CDR2(?:-[0-9A-HJKMNP-TV-Z]{1,4}){4,8}$')
        .hasMatch(machineCode)) {
      throw const FormatException('Invalid trusted machine code');
    }
    _requireP256PublicKey(rootPublicKey, 'rootPublicKey');
    _requireLength(rootFingerprint, 32, 'rootFingerprint');
    _requireP256PublicKey(authenticationPublicKey, 'authenticationPublicKey');
    _requireDerSignature(
      authenticationCertificate,
      'authenticationCertificate',
    );
    final lifetime = authenticationExpiresAt.difference(
      authenticationNotBefore,
    );
    if (lifetime <= Duration.zero ||
        lifetime > trustedAuthenticationKeyLifetime) {
      throw const FormatException('Invalid authentication key lifetime');
    }
  }
}

@immutable
class TrustedDeviceGrant {
  const TrustedDeviceGrant({
    required this.grantId,
    required this.issuerRootFingerprint,
    required this.subjectRootFingerprint,
    required this.permissions,
    required this.issuedAt,
    required this.softExpiresAt,
    required this.hardExpiresAt,
    required this.automaticRenewal,
    required this.signature,
  });

  factory TrustedDeviceGrant.fromJson(Map<String, dynamic> value) =>
      TrustedDeviceGrant(
        grantId: base64Decode(value['grantId'] as String),
        issuerRootFingerprint: base64Decode(
          value['issuerRootFingerprint'] as String,
        ),
        subjectRootFingerprint: base64Decode(
          value['subjectRootFingerprint'] as String,
        ),
        permissions: trustedPermissionsFromBits(
          (value['permissionBits'] as num).toInt(),
        ),
        issuedAt: DateTime.fromMillisecondsSinceEpoch(
          (value['issuedAtUnixMs'] as num).toInt(),
          isUtc: true,
        ),
        softExpiresAt: DateTime.fromMillisecondsSinceEpoch(
          (value['softExpiresAtUnixMs'] as num).toInt(),
          isUtc: true,
        ),
        hardExpiresAt: DateTime.fromMillisecondsSinceEpoch(
          (value['hardExpiresAtUnixMs'] as num).toInt(),
          isUtc: true,
        ),
        automaticRenewal: value['automaticRenewal'] == true,
        signature: base64Decode(value['signature'] as String),
      );

  final Uint8List grantId;
  final Uint8List issuerRootFingerprint;
  final Uint8List subjectRootFingerprint;
  final Set<TrustedPermission> permissions;
  final DateTime issuedAt;
  final DateTime softExpiresAt;
  final DateTime hardExpiresAt;
  final bool automaticRenewal;
  final Uint8List signature;

  bool isUsableAt(
    DateTime now, {
    Duration maximumClockSkew = trustedMaximumClockSkew,
  }) {
    final utcNow = now.toUtc();
    return !issuedAt.isAfter(utcNow.add(maximumClockSkew)) &&
        utcNow.isBefore(softExpiresAt) &&
        utcNow.isBefore(hardExpiresAt);
  }

  bool shouldRenewAt(DateTime now) =>
      automaticRenewal &&
      isUsableAt(now) &&
      softExpiresAt.difference(now) <= trustedGrantRenewalWindow;

  Uint8List get signingBytes => securityCanonicalBytes((out) {
    out.bytes(utf8.encode('CrossDesktopRemote/TrustGrant/v1'));
    out.bytes(grantId);
    out.bytes(issuerRootFingerprint);
    out.bytes(subjectRootFingerprint);
    out.uint64(trustedPermissionBits(permissions));
    out.uint64(issuedAt.millisecondsSinceEpoch);
    out.uint64(softExpiresAt.millisecondsSinceEpoch);
    out.uint64(hardExpiresAt.millisecondsSinceEpoch);
    out.raw([automaticRenewal ? 1 : 0]);
  });

  Map<String, dynamic> toJson() => {
    'grantId': base64Encode(grantId),
    'issuerRootFingerprint': base64Encode(issuerRootFingerprint),
    'subjectRootFingerprint': base64Encode(subjectRootFingerprint),
    'permissionBits': trustedPermissionBits(permissions),
    'issuedAtUnixMs': issuedAt.millisecondsSinceEpoch,
    'softExpiresAtUnixMs': softExpiresAt.millisecondsSinceEpoch,
    'hardExpiresAtUnixMs': hardExpiresAt.millisecondsSinceEpoch,
    'automaticRenewal': automaticRenewal,
    'signature': base64Encode(signature),
  };

  TrustedDeviceGrant copyWith({
    DateTime? softExpiresAt,
    bool? automaticRenewal,
    Uint8List? signature,
  }) => TrustedDeviceGrant(
    grantId: grantId,
    issuerRootFingerprint: issuerRootFingerprint,
    subjectRootFingerprint: subjectRootFingerprint,
    permissions: permissions,
    issuedAt: issuedAt,
    softExpiresAt: softExpiresAt ?? this.softExpiresAt,
    hardExpiresAt: hardExpiresAt,
    automaticRenewal: automaticRenewal ?? this.automaticRenewal,
    signature: signature ?? this.signature,
  );

  void validateStructure() {
    _requireLength(grantId, 16, 'grantId');
    _requireLength(issuerRootFingerprint, 32, 'issuerRootFingerprint');
    _requireLength(subjectRootFingerprint, 32, 'subjectRootFingerprint');
    _requireDerSignature(signature, 'grantSignature');
    if (permissions.isEmpty ||
        !permissions.contains(TrustedPermission.viewScreen)) {
      throw const FormatException('Trust grant must include screen access');
    }
    if (!softExpiresAt.isAfter(issuedAt) ||
        hardExpiresAt.isBefore(softExpiresAt) ||
        hardExpiresAt.difference(issuedAt) > trustedGrantHardLifetime) {
      throw const FormatException('Invalid trust grant lifetime');
    }
  }
}

@immutable
class TrustedSessionAuthorizationAck {
  const TrustedSessionAuthorizationAck({
    required this.sessionId,
    required this.authorizationSha256,
    required this.policyRevision,
    required this.permissions,
    required this.controllerRootFingerprint,
    required this.hostRootFingerprint,
    required this.controllerNonce,
    required this.hostNonce,
    required this.issuedAt,
    required this.expiresAt,
    required this.authSuiteVersion,
    required this.capabilitySha256,
  });

  factory TrustedSessionAuthorizationAck.fromJson(
    Map<String, dynamic> value,
  ) => TrustedSessionAuthorizationAck(
    sessionId: value['sessionId'] as String,
    authorizationSha256: base64Decode(value['authorizationSha256'] as String),
    policyRevision: (value['policyRevision'] as num).toInt(),
    permissions: normalizeHostAccessPermissions(
      trustedPermissionsFromBitsStrict(
        (value['permissionBits'] as num).toInt(),
      ),
    ),
    controllerRootFingerprint: base64Decode(
      value['controllerRootFingerprint'] as String,
    ),
    hostRootFingerprint: base64Decode(value['hostRootFingerprint'] as String),
    controllerNonce: base64Decode(value['controllerNonce'] as String),
    hostNonce: base64Decode(value['hostNonce'] as String),
    issuedAt: DateTime.fromMillisecondsSinceEpoch(
      (value['issuedAtUnixMs'] as num).toInt(),
      isUtc: true,
    ),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(
      (value['expiresAtUnixMs'] as num).toInt(),
      isUtc: true,
    ),
    authSuiteVersion: (value['authSuiteVersion'] as num).toInt(),
    capabilitySha256: base64Decode(value['capabilitySha256'] as String),
  );

  final String sessionId;
  final Uint8List authorizationSha256;
  final int policyRevision;
  final Set<TrustedPermission> permissions;
  final Uint8List controllerRootFingerprint;
  final Uint8List hostRootFingerprint;
  final Uint8List controllerNonce;
  final Uint8List hostNonce;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final int authSuiteVersion;
  final Uint8List capabilitySha256;

  Uint8List get signingBytes => securityCanonicalBytes((out) {
    out.bytes(
      utf8.encode('CrossDesktopRemote/TrustedSessionAuthorizationAck/v1'),
    );
    out.bytes(utf8.encode(sessionId));
    out.bytes(authorizationSha256);
    out.uint64(policyRevision);
    out.uint64(trustedPermissionBits(permissions));
    out.bytes(controllerRootFingerprint);
    out.bytes(hostRootFingerprint);
    out.bytes(controllerNonce);
    out.bytes(hostNonce);
    out.uint64(issuedAt.millisecondsSinceEpoch);
    out.uint64(expiresAt.millisecondsSinceEpoch);
    out.uint32(authSuiteVersion);
    out.bytes(capabilitySha256);
  });

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'authorizationSha256': base64Encode(authorizationSha256),
    'policyRevision': policyRevision,
    'permissionBits': trustedPermissionBits(permissions),
    'controllerRootFingerprint': base64Encode(controllerRootFingerprint),
    'hostRootFingerprint': base64Encode(hostRootFingerprint),
    'controllerNonce': base64Encode(controllerNonce),
    'hostNonce': base64Encode(hostNonce),
    'issuedAtUnixMs': issuedAt.millisecondsSinceEpoch,
    'expiresAtUnixMs': expiresAt.millisecondsSinceEpoch,
    'authSuiteVersion': authSuiteVersion,
    'capabilitySha256': base64Encode(capabilitySha256),
  };

  void validateStructure() {
    final sessionBytes = utf8.encode(sessionId);
    if (sessionBytes.isEmpty ||
        sessionBytes.length > trustedMaximumSessionIdBytes ||
        policyRevision < 1 ||
        permissions.isEmpty ||
        !permissions.contains(TrustedPermission.viewScreen) ||
        permissions.contains(TrustedPermission.transferFiles) ||
        !expiresAt.isAfter(issuedAt) ||
        authSuiteVersion != trustedAuthSuiteV2) {
      throw const FormatException('Invalid trusted authorization receipt');
    }
    _requireLength(authorizationSha256, 32, 'authorizationSha256');
    _requireLength(controllerRootFingerprint, 32, 'controllerRootFingerprint');
    _requireLength(hostRootFingerprint, 32, 'hostRootFingerprint');
    _requireLength(controllerNonce, 16, 'controllerNonce');
    _requireLength(hostNonce, 16, 'hostNonce');
    _requireLength(capabilitySha256, 32, 'capabilitySha256');
    if (_allZero(authorizationSha256) || _allZero(capabilitySha256)) {
      throw const FormatException('Invalid trusted authorization receipt');
    }
  }
}

@immutable
class TrustedDeviceRecord {
  const TrustedDeviceRecord({
    required this.peerName,
    required this.peerIdentity,
    required this.grant,
    required this.localIsIssuer,
    required this.createdAt,
    required this.lastConnectedAt,
    this.revokedAt,
    this.previousGrant,
    this.previousGrantExpiresAt,
  });

  factory TrustedDeviceRecord.fromJson(Map<String, dynamic> value) =>
      TrustedDeviceRecord(
        peerName: value['peerName'] as String? ?? '可信设备',
        peerIdentity: TrustedPeerIdentity.fromJson(
          value['peerIdentity'] as Map<String, dynamic>,
        ),
        grant: TrustedDeviceGrant.fromJson(
          value['grant'] as Map<String, dynamic>,
        ),
        localIsIssuer: value['localIsIssuer'] == true,
        createdAt: DateTime.parse(value['createdAt'] as String).toUtc(),
        lastConnectedAt: DateTime.parse(value['lastConnectedAt'] as String)
            .toUtc(),
        revokedAt: value['revokedAt'] == null
            ? null
            : DateTime.parse(value['revokedAt'] as String).toUtc(),
        previousGrant: value['previousGrant'] == null
            ? null
            : TrustedDeviceGrant.fromJson(
                (value['previousGrant'] as Map).cast<String, dynamic>(),
              ),
        previousGrantExpiresAt: value['previousGrantExpiresAt'] == null
            ? null
            : DateTime.parse(value['previousGrantExpiresAt'] as String).toUtc(),
      );

  final String peerName;
  final TrustedPeerIdentity peerIdentity;
  final TrustedDeviceGrant grant;
  final bool localIsIssuer;
  final DateTime createdAt;
  final DateTime lastConnectedAt;
  final DateTime? revokedAt;
  final TrustedDeviceGrant? previousGrant;
  final DateTime? previousGrantExpiresAt;

  bool get revoked => revokedAt != null;
  bool usableAt(DateTime now) => !revoked && grant.isUsableAt(now);

  Map<String, dynamic> toJson() => {
    'peerName': peerName,
    'peerIdentity': peerIdentity.toJson(),
    'grant': grant.toJson(),
    'localIsIssuer': localIsIssuer,
    'createdAt': createdAt.toIso8601String(),
    'lastConnectedAt': lastConnectedAt.toIso8601String(),
    'revokedAt': revokedAt?.toIso8601String(),
    'previousGrant': previousGrant?.toJson(),
    'previousGrantExpiresAt': previousGrantExpiresAt?.toIso8601String(),
  };

  TrustedDeviceRecord copyWith({
    TrustedPeerIdentity? peerIdentity,
    TrustedDeviceGrant? grant,
    DateTime? lastConnectedAt,
    DateTime? revokedAt,
    TrustedDeviceGrant? previousGrant,
    DateTime? previousGrantExpiresAt,
    bool clearPreviousGrant = false,
  }) => TrustedDeviceRecord(
    peerName: peerName,
    peerIdentity: peerIdentity ?? this.peerIdentity,
    grant: grant ?? this.grant,
    localIsIssuer: localIsIssuer,
    createdAt: createdAt,
    lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    revokedAt: revokedAt ?? this.revokedAt,
    previousGrant: clearPreviousGrant
        ? null
        : previousGrant ?? this.previousGrant,
    previousGrantExpiresAt: clearPreviousGrant
        ? null
        : previousGrantExpiresAt ?? this.previousGrantExpiresAt,
  );
}

enum TrustedAuditAction {
  paired,
  connected,
  renewed,
  permissionsChanged,
  revoked,
  expired,
}

@immutable
class TrustedAuditRecord {
  const TrustedAuditRecord({
    required this.id,
    required this.action,
    required this.peerName,
    required this.peerMachineCode,
    required this.occurredAt,
    this.detail = '',
  });

  factory TrustedAuditRecord.fromJson(Map<String, dynamic> value) =>
      TrustedAuditRecord(
        id: value['id'] as String,
        action: TrustedAuditAction.values.firstWhere(
          (action) => action.name == value['action'],
        ),
        peerName: value['peerName'] as String,
        peerMachineCode: value['peerMachineCode'] as String,
        occurredAt: DateTime.parse(value['occurredAt'] as String).toUtc(),
        detail: value['detail'] as String? ?? '',
      );

  final String id;
  final TrustedAuditAction action;
  final String peerName;
  final String peerMachineCode;
  final DateTime occurredAt;
  final String detail;

  Map<String, dynamic> toJson() => {
    'id': id,
    'action': action.name,
    'peerName': peerName,
    'peerMachineCode': peerMachineCode,
    'occurredAt': occurredAt.toIso8601String(),
    'detail': detail,
  };
}

@immutable
class TrustedSessionBinding {
  const TrustedSessionBinding({
    required this.sessionId,
    required this.controllerNonce,
    required this.hostNonce,
    required this.requestedPermissions,
    required this.controllerEphemeralPublicKey,
    required this.hostEphemeralPublicKey,
    required this.offerSha256,
    required this.answerSha256,
    required this.controllerDtlsFingerprintSha256,
    required this.hostDtlsFingerprintSha256,
    required this.expiresAt,
    required this.authSuiteVersion,
    required this.authorizationSha256,
    required this.capabilitySha256,
  });

  factory TrustedSessionBinding.fromJson(Map<String, dynamic> value) =>
      TrustedSessionBinding(
        sessionId: value['sessionId'] as String,
        controllerNonce: base64Decode(value['controllerNonce'] as String),
        hostNonce: base64Decode(value['hostNonce'] as String),
        requestedPermissions: trustedPermissionsFromBits(
          (value['permissionBits'] as num).toInt(),
        ),
        controllerEphemeralPublicKey: base64Decode(
          value['controllerEphemeralPublicKey'] as String,
        ),
        hostEphemeralPublicKey: base64Decode(
          value['hostEphemeralPublicKey'] as String,
        ),
        offerSha256: base64Decode(value['offerSha256'] as String),
        answerSha256: base64Decode(value['answerSha256'] as String),
        controllerDtlsFingerprintSha256: base64Decode(
          value['controllerDtlsFingerprintSha256'] as String,
        ),
        hostDtlsFingerprintSha256: base64Decode(
          value['hostDtlsFingerprintSha256'] as String,
        ),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (value['expiresAtUnixMs'] as num).toInt(),
          isUtc: true,
        ),
        authSuiteVersion:
            (value['authSuiteVersion'] as num?)?.toInt() ??
            trustedAuthSuiteLegacy,
        authorizationSha256: value['authorizationSha256'] is String
            ? base64Decode(value['authorizationSha256'] as String)
            : Uint8List(32),
        capabilitySha256: value['capabilitySha256'] is String
            ? base64Decode(value['capabilitySha256'] as String)
            : Uint8List(32),
      );

  final String sessionId;
  final Uint8List controllerNonce;
  final Uint8List hostNonce;
  final Set<TrustedPermission> requestedPermissions;
  final Uint8List controllerEphemeralPublicKey;
  final Uint8List hostEphemeralPublicKey;
  final Uint8List offerSha256;
  final Uint8List answerSha256;
  final Uint8List controllerDtlsFingerprintSha256;
  final Uint8List hostDtlsFingerprintSha256;
  final DateTime expiresAt;
  final int authSuiteVersion;
  final Uint8List authorizationSha256;
  final Uint8List capabilitySha256;

  Uint8List get signingBytes => securityCanonicalBytes((out) {
    out.bytes(
      utf8.encode(
        authSuiteVersion == trustedAuthSuiteV2
            ? 'CrossDesktopRemote/TrustedSessionBinding/v2'
            : 'CrossDesktopRemote/TrustedSessionBinding/v1',
      ),
    );
    out.bytes(utf8.encode(sessionId));
    out.bytes(controllerNonce);
    out.bytes(hostNonce);
    out.uint64(trustedPermissionBits(requestedPermissions));
    out.bytes(controllerEphemeralPublicKey);
    out.bytes(hostEphemeralPublicKey);
    out.bytes(offerSha256);
    out.bytes(answerSha256);
    out.bytes(controllerDtlsFingerprintSha256);
    out.bytes(hostDtlsFingerprintSha256);
    out.uint64(expiresAt.millisecondsSinceEpoch);
    if (authSuiteVersion == trustedAuthSuiteV2) {
      out.uint32(authSuiteVersion);
      out.bytes(authorizationSha256);
      out.bytes(capabilitySha256);
    }
  });

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'controllerNonce': base64Encode(controllerNonce),
    'hostNonce': base64Encode(hostNonce),
    'permissionBits': trustedPermissionBits(requestedPermissions),
    'controllerEphemeralPublicKey': base64Encode(controllerEphemeralPublicKey),
    'hostEphemeralPublicKey': base64Encode(hostEphemeralPublicKey),
    'offerSha256': base64Encode(offerSha256),
    'answerSha256': base64Encode(answerSha256),
    'controllerDtlsFingerprintSha256': base64Encode(
      controllerDtlsFingerprintSha256,
    ),
    'hostDtlsFingerprintSha256': base64Encode(hostDtlsFingerprintSha256),
    'expiresAtUnixMs': expiresAt.millisecondsSinceEpoch,
    if (authSuiteVersion == trustedAuthSuiteV2) ...{
      'authSuiteVersion': authSuiteVersion,
      'authorizationSha256': base64Encode(authorizationSha256),
      'capabilitySha256': base64Encode(capabilitySha256),
    },
  };

  void validateStructure() {
    final sessionBytes = utf8.encode(sessionId);
    if (sessionBytes.isEmpty ||
        sessionBytes.length > trustedMaximumSessionIdBytes ||
        requestedPermissions.isEmpty ||
        !requestedPermissions.contains(TrustedPermission.viewScreen) ||
        !expiresAt.isAfter(
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        )) {
      throw const FormatException('Invalid trusted WebRTC binding');
    }
    _requireLength(controllerNonce, 16, 'controllerNonce');
    _requireLength(hostNonce, 16, 'hostNonce');
    if (_allZero(controllerNonce) ||
        _allZero(hostNonce) ||
        constantTimeBytesEqual(controllerNonce, hostNonce)) {
      throw const FormatException('Invalid trusted WebRTC nonces');
    }
    _requireP256PublicKey(
      controllerEphemeralPublicKey,
      'controllerEphemeralPublicKey',
    );
    _requireP256PublicKey(hostEphemeralPublicKey, 'hostEphemeralPublicKey');
    _requireLength(offerSha256, 32, 'offerSha256');
    _requireLength(answerSha256, 32, 'answerSha256');
    _requireLength(
      controllerDtlsFingerprintSha256,
      32,
      'controllerDtlsFingerprintSha256',
    );
    _requireLength(hostDtlsFingerprintSha256, 32, 'hostDtlsFingerprintSha256');
    _requireLength(authorizationSha256, 32, 'authorizationSha256');
    _requireLength(capabilitySha256, 32, 'capabilitySha256');
    if (authSuiteVersion != trustedAuthSuiteLegacy &&
        authSuiteVersion != trustedAuthSuiteV2) {
      throw const FormatException('Unsupported trusted authentication suite');
    }
    if (authSuiteVersion == trustedAuthSuiteV2 &&
        (_allZero(authorizationSha256) || _allZero(capabilitySha256))) {
      throw const FormatException('Trusted suite v2 binding is incomplete');
    }
    if (authSuiteVersion == trustedAuthSuiteLegacy &&
        (!_allZero(authorizationSha256) || !_allZero(capabilitySha256))) {
      throw const FormatException('Legacy binding contains v2 authorization');
    }
    if (_allZero(offerSha256) ||
        _allZero(answerSha256) ||
        _allZero(controllerDtlsFingerprintSha256) ||
        _allZero(hostDtlsFingerprintSha256)) {
      throw const FormatException('Invalid trusted WebRTC transcript hashes');
    }
  }
}

@immutable
class SignedTrustedEnvelope {
  const SignedTrustedEnvelope({
    required this.sessionId,
    required this.senderRootFingerprint,
    required this.recipientRootFingerprint,
    required this.sequence,
    required this.issuedAt,
    required this.expiresAt,
    required this.nonce,
    required this.payload,
    required this.signature,
  });

  factory SignedTrustedEnvelope.fromJson(Map<String, dynamic> value) =>
      SignedTrustedEnvelope(
        sessionId: value['sessionId'] as String,
        senderRootFingerprint: base64Decode(
          value['senderRootFingerprint'] as String,
        ),
        recipientRootFingerprint: base64Decode(
          value['recipientRootFingerprint'] as String,
        ),
        sequence: (value['sequence'] as num).toInt(),
        issuedAt: DateTime.fromMillisecondsSinceEpoch(
          (value['issuedAtUnixMs'] as num).toInt(),
          isUtc: true,
        ),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (value['expiresAtUnixMs'] as num).toInt(),
          isUtc: true,
        ),
        nonce: base64Decode(value['nonce'] as String),
        payload: base64Decode(value['payload'] as String),
        signature: base64Decode(value['signature'] as String),
      );

  final String sessionId;
  final Uint8List senderRootFingerprint;
  final Uint8List recipientRootFingerprint;
  final int sequence;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final Uint8List nonce;
  final Uint8List payload;
  final Uint8List signature;

  Uint8List get signingBytes => securityCanonicalBytes((out) {
    out.bytes(utf8.encode('CrossDesktopRemote/SignedPeerEnvelope/v1'));
    out.uint32(1);
    out.bytes(utf8.encode(sessionId));
    out.bytes(senderRootFingerprint);
    out.bytes(recipientRootFingerprint);
    out.uint64(sequence);
    out.uint64(issuedAt.millisecondsSinceEpoch);
    out.uint64(expiresAt.millisecondsSinceEpoch);
    out.bytes(nonce);
    out.bytes(payload);
  });

  Map<String, dynamic> toJson() => {
    'protocolVersion': 1,
    'sessionId': sessionId,
    'senderRootFingerprint': base64Encode(senderRootFingerprint),
    'recipientRootFingerprint': base64Encode(recipientRootFingerprint),
    'sequence': sequence,
    'issuedAtUnixMs': issuedAt.millisecondsSinceEpoch,
    'expiresAtUnixMs': expiresAt.millisecondsSinceEpoch,
    'nonce': base64Encode(nonce),
    'payload': base64Encode(payload),
    'signature': base64Encode(signature),
  };

  void validateStructure() {
    final sessionBytes = utf8.encode(sessionId);
    if (sessionBytes.isEmpty ||
        sessionBytes.length > trustedMaximumSessionIdBytes ||
        sequence <= 0) {
      throw const FormatException('Invalid trusted envelope session');
    }
    _requireLength(senderRootFingerprint, 32, 'senderRootFingerprint');
    _requireLength(recipientRootFingerprint, 32, 'recipientRootFingerprint');
    _requireLength(nonce, 16, 'nonce');
    _requireDerSignature(signature, 'envelopeSignature');
    if (payload.length > trustedMaximumSignedPayloadBytes ||
        !expiresAt.isAfter(issuedAt) ||
        expiresAt.difference(issuedAt) > trustedSessionTicketLifetime) {
      throw const FormatException(
        'Invalid trusted envelope lifetime or payload',
      );
    }
  }
}

Uint8List securityRandomBytes(int length, [Random? random]) {
  final source = random ?? Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => source.nextInt(256)),
  );
}

Uint8List trustedPairingNonceCommitment({
  required String sessionId,
  required Uint8List rootFingerprint,
  required Uint8List nonce,
}) {
  _requireLength(rootFingerprint, 32, 'rootFingerprint');
  _requireLength(nonce, 16, 'pairingNonce');
  if (sessionId.isEmpty || utf8.encode(sessionId).length > 128) {
    throw const FormatException('Invalid pairing session');
  }
  return Uint8List.fromList(
    sha256.convert([
      ...utf8.encode('CrossDesktopRemote/PairingNonceCommitment/v1'),
      ..._uint32Bytes(utf8.encode(sessionId).length),
      ...utf8.encode(sessionId),
      ...rootFingerprint,
      ...nonce,
    ]).bytes,
  );
}

String trustedPairingSasCode({
  required String sessionId,
  required Uint8List firstPublicKey,
  required Uint8List firstNonce,
  required Uint8List secondPublicKey,
  required Uint8List secondNonce,
}) {
  if (sessionId.isEmpty || utf8.encode(sessionId).length > 128) {
    throw const FormatException('Invalid pairing session');
  }
  _requireP256PublicKey(firstPublicKey, 'firstPublicKey');
  _requireP256PublicKey(secondPublicKey, 'secondPublicKey');
  _requireLength(firstNonce, 16, 'firstNonce');
  _requireLength(secondNonce, 16, 'secondNonce');
  final first = Uint8List.fromList(sha256.convert(firstPublicKey).bytes);
  final second = Uint8List.fromList(sha256.convert(secondPublicKey).bytes);
  final lowerFirst = _compareBytes(first, second) <= 0;
  final lowerFingerprint = lowerFirst ? first : second;
  final lowerNonce = lowerFirst ? firstNonce : secondNonce;
  final upperFingerprint = lowerFirst ? second : first;
  final upperNonce = lowerFirst ? secondNonce : firstNonce;
  final digest = sha256.convert([
    ...utf8.encode('CrossDesktopRemote/PairingSAS/v1'),
    ..._uint32Bytes(utf8.encode(sessionId).length),
    ...utf8.encode(sessionId),
    ...lowerFingerprint,
    ...lowerNonce,
    ...upperFingerprint,
    ...upperNonce,
  ]).bytes;
  final value =
      ByteData.sublistView(Uint8List.fromList(digest))
          .getUint32(0, Endian.big) %
      1000000;
  return value.toString().padLeft(6, '0');
}

Uint8List trustedPairingConfirmationBytes({
  required String sessionId,
  required Uint8List controllerRootFingerprint,
  required Uint8List hostRootFingerprint,
  required Uint8List controllerNonce,
  required Uint8List hostNonce,
  required Set<TrustedPermission> permissions,
}) => securityCanonicalBytes((out) {
  out.bytes(utf8.encode('CrossDesktopRemote/PairingConfirmation/v1'));
  out.bytes(utf8.encode(sessionId));
  out.bytes(controllerRootFingerprint);
  out.bytes(hostRootFingerprint);
  out.bytes(controllerNonce);
  out.bytes(hostNonce);
  out.uint64(trustedPermissionBits(permissions));
});

enum TrustedPairingReceiptStage { accepted, committed }

Uint8List trustedPairingReceiptBytes({
  required String sessionId,
  required TrustedDeviceGrant grant,
  required TrustedPairingReceiptStage stage,
}) {
  final sessionBytes = utf8.encode(sessionId);
  if (sessionBytes.isEmpty ||
      sessionBytes.length > trustedMaximumSessionIdBytes) {
    throw const FormatException('Invalid pairing session');
  }
  grant.validateStructure();
  final signedGrantHash = sha256.convert([
    ...grant.signingBytes,
    ...grant.signature,
  ]).bytes;
  return securityCanonicalBytes((out) {
    out.bytes(utf8.encode('CrossDesktopRemote/PairingReceipt/v1'));
    out.bytes(sessionBytes);
    out.uint32(stage.index + 1);
    out.bytes(grant.grantId);
    out.bytes(signedGrantHash);
  });
}

Uint8List securityCanonicalBytes(void Function(SecurityCanonicalOutput) write) {
  final builder = BytesBuilder(copy: false);
  write(SecurityCanonicalOutput(builder));
  return builder.takeBytes();
}

class SecurityCanonicalOutput {
  SecurityCanonicalOutput(this._builder);

  final BytesBuilder _builder;

  void raw(List<int> value) => _builder.add(value);

  void bytes(List<int> value) {
    uint32(value.length);
    _builder.add(value);
  }

  void uint32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.big);
    _builder.add(data.buffer.asUint8List());
  }

  void uint64(int value) {
    final data = ByteData(8)..setUint64(0, value, Endian.big);
    _builder.add(data.buffer.asUint8List());
  }
}

int _compareBytes(List<int> first, List<int> second) {
  for (var index = 0; index < first.length && index < second.length; index++) {
    final difference = first[index] - second[index];
    if (difference != 0) return difference;
  }
  return first.length - second.length;
}

bool constantTimeBytesEqual(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  var difference = 0;
  for (var index = 0; index < first.length; index++) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}

List<int> _uint32Bytes(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.big);
  return data.buffer.asUint8List();
}

void _requireLength(List<int> value, int length, String name) {
  if (value.length != length) throw FormatException('Invalid $name length');
}

bool _allZero(List<int> value) => value.every((byte) => byte == 0);

void _requireP256PublicKey(List<int> value, String name) {
  if (value.length != 65 || value.first != 0x04) {
    throw FormatException('$name must be an uncompressed P-256 key');
  }
}

void _requireDerSignature(List<int> value, String name) {
  if (value.length < 8 || value.length > trustedMaximumSignatureBytes) {
    throw FormatException('Invalid $name length');
  }
}
