import 'dart:convert';

import 'package:cross_desktop_remote/core/identity/device_identity.dart';
import 'package:cross_desktop_remote/core/security/trusted_device_models.dart';
import 'package:cross_desktop_remote/core/security/trusted_device_repository.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

enum TrustedAuthenticationFailure {
  unsupported,
  identityChanged,
  invalidCertificate,
  invalidSignature,
  replay,
  expired,
  revoked,
  permissionsDenied,
  hardReviewRequired,
}

class TrustedAuthenticationException implements Exception {
  const TrustedAuthenticationException(this.failure, this.message);

  final TrustedAuthenticationFailure failure;
  final String message;

  @override
  String toString() => message;
}

class TrustedDeviceCoordinator extends ChangeNotifier {
  TrustedDeviceCoordinator({
    required this.identity,
    TrustedDeviceRepository? initialRepository,
    DateTime Function()? now,
  }) : _repository = initialRepository,
       _now = now ?? DateTime.now;

  final DeviceIdentityController identity;
  TrustedDeviceRepository? _repository;
  Future<void>? _initializing;
  final DateTime Function() _now;
  List<TrustedDeviceRecord> _devices = const [];
  bool _connectionsPaused = false;
  final Map<String, int> _nextSequenceBySession = {};
  final Map<String, int> _lastRemoteSequenceBySession = {};
  final Map<String, DateTime> _consumedNonces = {};

  bool get initialized => _repository != null;
  bool get supported =>
      identity.identity?.trustedAuthenticationAvailable == true;
  bool get connectionsPaused => _connectionsPaused;
  bool get connectionsEnabled => supported && !_connectionsPaused;
  List<TrustedDeviceRecord> get devices => List.unmodifiable(_devices);

  Future<void> initialize() async {
    if (_repository != null) return;
    final pending = _initializing;
    if (pending != null) return pending;
    final operation = _openRepository();
    _initializing = operation;
    try {
      await operation;
    } finally {
      if (identical(_initializing, operation)) _initializing = null;
    }
  }

  Future<void> _openRepository() async {
    _repository = await TrustedDeviceRepository.open();
    _connectionsPaused = await _repository!.readConnectionsPaused();
    await reload();
  }

  Future<void> setConnectionsPaused(bool value) async {
    await initialize();
    if (_connectionsPaused == value) return;
    await _repository!.writeConnectionsPaused(value);
    _connectionsPaused = value;
    notifyListeners();
  }

  Future<void> reload() async {
    final repository = _repository;
    if (repository == null) return;
    _devices = await repository.list();
    notifyListeners();
  }

  TrustedPeerIdentity localPublicIdentity() {
    final local = identity.identity;
    if (local == null || !local.trustedAuthenticationAvailable) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.unsupported,
        '当前平台没有受保护的设备身份密钥',
      );
    }
    return TrustedPeerIdentity(
      machineCode: local.machineCode,
      rootPublicKey: local.rootPublicKey!,
      rootFingerprint: local.rootFingerprint!,
      authenticationPublicKey: local.authenticationPublicKey!,
      authenticationNotBefore: local.authenticationNotBefore!,
      authenticationExpiresAt: local.authenticationExpiresAt!,
      authenticationCertificate: local.authenticationCertificate!,
    );
  }

  Future<TrustedDeviceGrant> issueGrant({
    required TrustedPeerIdentity subject,
    Set<TrustedPermission> permissions = defaultTrustedPermissions,
    bool automaticRenewal = true,
    Duration softLifetime = trustedGrantSoftLifetime,
  }) async {
    await _validatePeerIdentity(subject);
    if (softLifetime <= Duration.zero ||
        softLifetime > trustedGrantSoftLifetime ||
        permissions.isEmpty ||
        !permissions.contains(TrustedPermission.viewScreen)) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.permissionsDenied,
        '可信授权范围或有效期无效',
      );
    }
    final local = localPublicIdentity();
    final now = _now().toUtc();
    final unsigned = TrustedDeviceGrant(
      grantId: securityRandomBytes(16),
      issuerRootFingerprint: local.rootFingerprint,
      subjectRootFingerprint: subject.rootFingerprint,
      permissions: Set.unmodifiable(permissions),
      issuedAt: now,
      softExpiresAt: now.add(softLifetime),
      hardExpiresAt: now.add(trustedGrantHardLifetime),
      automaticRenewal: automaticRenewal,
      signature: Uint8List(0),
    );
    final signature = await identity.signWithRoot(unsigned.signingBytes);
    return unsigned.copyWith(signature: signature);
  }

  Future<void> validatePeerIdentity(TrustedPeerIdentity peer) =>
      _validatePeerIdentity(peer);

  Future<bool> verifyRootSignature({
    required TrustedPeerIdentity peer,
    required Uint8List message,
    required Uint8List signature,
  }) async {
    await _validatePeerIdentity(peer);
    return identity.verifyP256Signature(
      publicKey: peer.rootPublicKey,
      message: message,
      signature: signature,
    );
  }

  Future<TrustedDeviceRecord> trustController({
    required String peerName,
    required TrustedPeerIdentity controller,
    required TrustedDeviceGrant grant,
  }) async {
    await initialize();
    await _validatePeerIdentity(controller);
    await _validateGrant(
      grant: grant,
      issuer: localPublicIdentity(),
      expectedSubject: controller.rootFingerprint,
      requestedPermissions: grant.permissions,
    );
    final now = _now().toUtc();
    final record = TrustedDeviceRecord(
      peerName: peerName,
      peerIdentity: controller,
      grant: grant,
      localIsIssuer: true,
      createdAt: now,
      lastConnectedAt: now,
    );
    await _save(record);
    await _appendAudit(TrustedAuditAction.paired, record);
    return record;
  }

  Future<TrustedDeviceRecord> trustHost({
    required String peerName,
    required TrustedPeerIdentity host,
    required TrustedDeviceGrant grant,
  }) async {
    await initialize();
    await _validatePeerIdentity(host);
    await _validateGrant(
      grant: grant,
      issuer: host,
      expectedSubject: localPublicIdentity().rootFingerprint,
      requestedPermissions: grant.permissions,
    );
    final now = _now().toUtc();
    final record = TrustedDeviceRecord(
      peerName: peerName,
      peerIdentity: host,
      grant: grant,
      localIsIssuer: false,
      createdAt: now,
      lastConnectedAt: now,
    );
    await _save(record);
    await _appendAudit(TrustedAuditAction.paired, record);
    return record;
  }

  Future<TrustedDeviceRecord?> findTrustedHost(String machineCode) async {
    await initialize();
    final record = await _repository!.findByMachineCode(
      machineCode,
      localIsIssuer: false,
    );
    if (record == null) return null;
    _ensureGrantCurrent(record);
    return record;
  }

  Future<TrustedDeviceRecord?> findTrustedController(
    Uint8List fingerprint,
  ) async {
    await initialize();
    for (final record in _devices) {
      if (record.localIsIssuer &&
          constantTimeBytesEqual(
            record.peerIdentity.rootFingerprint,
            fingerprint,
          )) {
        _ensureGrantCurrent(record);
        return record;
      }
    }
    return null;
  }

  Future<SignedTrustedEnvelope> createEnvelope({
    required String sessionId,
    required Uint8List recipientRootFingerprint,
    required Map<String, dynamic> payload,
    Uint8List? nonce,
  }) async {
    if (utf8.encode(sessionId).isEmpty ||
        utf8.encode(sessionId).length > trustedMaximumSessionIdBytes) {
      throw const FormatException('Invalid trusted session id');
    }
    final encodedPayload = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    if (encodedPayload.length > trustedMaximumSignedPayloadBytes) {
      throw const FormatException('Trusted message is too large');
    }
    final local = localPublicIdentity();
    final now = _now().toUtc();
    final sequence = (_nextSequenceBySession[sessionId] ?? 0) + 1;
    _nextSequenceBySession[sessionId] = sequence;
    final unsigned = SignedTrustedEnvelope(
      sessionId: sessionId,
      senderRootFingerprint: local.rootFingerprint,
      recipientRootFingerprint: recipientRootFingerprint,
      sequence: sequence,
      issuedAt: now,
      expiresAt: now.add(trustedSessionTicketLifetime),
      nonce: nonce ?? securityRandomBytes(16),
      payload: encodedPayload,
      signature: Uint8List(0),
    );
    final signature = await identity.signWithAuthenticationKey(
      unsigned.signingBytes,
    );
    return SignedTrustedEnvelope(
      sessionId: unsigned.sessionId,
      senderRootFingerprint: unsigned.senderRootFingerprint,
      recipientRootFingerprint: unsigned.recipientRootFingerprint,
      sequence: unsigned.sequence,
      issuedAt: unsigned.issuedAt,
      expiresAt: unsigned.expiresAt,
      nonce: unsigned.nonce,
      payload: unsigned.payload,
      signature: signature,
    );
  }

  Future<Map<String, dynamic>> verifyEnvelope({
    required SignedTrustedEnvelope envelope,
    required TrustedPeerIdentity sender,
  }) async {
    envelope.validateStructure();
    await _validatePeerIdentity(sender);
    final local = localPublicIdentity();
    final now = _now().toUtc();
    if (!constantTimeBytesEqual(
      envelope.senderRootFingerprint,
      sender.rootFingerprint,
    )) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.identityChanged,
        '发送设备身份与已固定身份不一致',
      );
    }
    if (!constantTimeBytesEqual(
      envelope.recipientRootFingerprint,
      local.rootFingerprint,
    )) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.identityChanged,
        '可信消息并非发送给本机',
      );
    }
    if (envelope.issuedAt.isAfter(now.add(trustedMaximumClockSkew)) ||
        !now.isBefore(envelope.expiresAt)) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.expired,
        '可信会话票据已过期',
      );
    }
    _consumedNonces.removeWhere((_, expiresAt) => !now.isBefore(expiresAt));
    final peerSessionKey =
        '${envelope.sessionId}:'
        '${base64UrlEncode(envelope.senderRootFingerprint)}';
    final lastSequence = _lastRemoteSequenceBySession[peerSessionKey] ?? 0;
    final nonce = '$peerSessionKey:${base64UrlEncode(envelope.nonce)}';
    if (envelope.sequence <= lastSequence ||
        _consumedNonces.containsKey(nonce)) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.replay,
        '检测到重复或回退的可信认证消息',
      );
    }
    if (_consumedNonces.length >= 4096) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.replay,
        '可信认证防重放缓存已满，请重新建立会话',
      );
    }
    final verified = await identity.verifyP256Signature(
      publicKey: sender.authenticationPublicKey,
      message: envelope.signingBytes,
      signature: envelope.signature,
    );
    if (!verified) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.invalidSignature,
        '可信认证签名无效',
      );
    }
    _lastRemoteSequenceBySession[peerSessionKey] = envelope.sequence;
    _consumedNonces[nonce] = envelope.expiresAt;
    final decoded = jsonDecode(utf8.decode(envelope.payload));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Trusted envelope payload must be a map');
    }
    return decoded;
  }

  Future<void> validatePresentedGrant({
    required TrustedDeviceGrant grant,
    required TrustedPeerIdentity controller,
    Set<TrustedPermission> requestedPermissions = defaultTrustedPermissions,
  }) async {
    await initialize();
    final authoritative = await findTrustedController(
      controller.rootFingerprint,
    );
    final now = _now().toUtc();
    final currentMatches =
        authoritative != null && _sameGrant(authoritative.grant, grant);
    final previousMatches =
        authoritative?.previousGrant != null &&
        authoritative!.previousGrantExpiresAt != null &&
        now.isBefore(authoritative.previousGrantExpiresAt!) &&
        _sameGrant(authoritative.previousGrant!, grant);
    if (!currentMatches && !previousMatches) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.revoked,
        '可信授权已被替换、撤销或不属于本机授权库',
      );
    }
    if (await _repository!.isGrantRevoked(grant.grantId)) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.revoked,
        '该可信授权已被撤销',
      );
    }
    await _validateGrant(
      grant: grant,
      issuer: localPublicIdentity(),
      expectedSubject: controller.rootFingerprint,
      requestedPermissions: requestedPermissions,
    );
  }

  Future<void> markConnected(TrustedDeviceRecord record) async {
    final updated = record.copyWith(lastConnectedAt: _now().toUtc());
    await _save(updated);
    await _appendAudit(TrustedAuditAction.connected, updated);
  }

  Future<TrustedDeviceRecord> renewControllerGrant(
    TrustedDeviceRecord record,
  ) async {
    await initialize();
    if (!record.localIsIssuer || record.revoked) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.permissionsDenied,
        '只有被控端可以续期其签发的可信授权',
      );
    }
    _ensureGrantCurrent(record);
    final now = _now().toUtc();
    if (!record.grant.automaticRenewal || !record.grant.shouldRenewAt(now)) {
      return record;
    }
    final requestedSoftExpiry = now.add(trustedGrantSoftLifetime);
    final softExpiry = requestedSoftExpiry.isBefore(record.grant.hardExpiresAt)
        ? requestedSoftExpiry
        : record.grant.hardExpiresAt;
    if (!softExpiry.isAfter(now)) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.hardReviewRequired,
        '可信关系已达到人工复核期限',
      );
    }
    final unsigned = TrustedDeviceGrant(
      grantId: securityRandomBytes(16),
      issuerRootFingerprint: record.grant.issuerRootFingerprint,
      subjectRootFingerprint: record.grant.subjectRootFingerprint,
      permissions: record.grant.permissions,
      issuedAt: now,
      softExpiresAt: softExpiry,
      hardExpiresAt: record.grant.hardExpiresAt,
      automaticRenewal: true,
      signature: Uint8List(0),
    );
    final renewed = unsigned.copyWith(
      signature: await identity.signWithRoot(unsigned.signingBytes),
    );
    final overlapEnd = now.add(trustedAuthenticationKeyOverlap);
    final updated = record.copyWith(
      grant: renewed,
      previousGrant: record.grant,
      previousGrantExpiresAt: overlapEnd.isBefore(record.grant.softExpiresAt)
          ? overlapEnd
          : record.grant.softExpiresAt,
      lastConnectedAt: now,
    );
    await _save(updated);
    await _appendAudit(TrustedAuditAction.renewed, updated);
    return updated;
  }

  Future<TrustedDeviceRecord> acceptHostRenewal({
    required TrustedDeviceRecord record,
    required TrustedPeerIdentity host,
    required TrustedDeviceGrant grant,
  }) async {
    await initialize();
    if (record.localIsIssuer ||
        !constantTimeBytesEqual(
          record.peerIdentity.rootFingerprint,
          host.rootFingerprint,
        ) ||
        !grant.permissions.every(record.grant.permissions.contains) ||
        grant.hardExpiresAt.millisecondsSinceEpoch !=
            record.grant.hardExpiresAt.millisecondsSinceEpoch) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.permissionsDenied,
        '续期授权试图更换设备、扩大权限或延长人工复核期限',
      );
    }
    await _validatePeerIdentity(host);
    await _validateGrant(
      grant: grant,
      issuer: host,
      expectedSubject: localPublicIdentity().rootFingerprint,
      requestedPermissions: grant.permissions,
    );
    if (!grant.issuedAt.isAfter(record.grant.issuedAt)) return record;
    final now = _now().toUtc();
    final overlapEnd = now.add(trustedAuthenticationKeyOverlap);
    final updated = record.copyWith(
      peerIdentity: host,
      grant: grant,
      previousGrant: record.grant,
      previousGrantExpiresAt: overlapEnd.isBefore(record.grant.softExpiresAt)
          ? overlapEnd
          : record.grant.softExpiresAt,
      lastConnectedAt: now,
    );
    await _save(updated);
    await _appendAudit(TrustedAuditAction.renewed, updated);
    return updated;
  }

  Future<TrustedDeviceRecord> updatePeerAuthenticationIdentity({
    required TrustedDeviceRecord record,
    required TrustedPeerIdentity peerIdentity,
  }) async {
    await _validatePeerIdentity(peerIdentity);
    if (!constantTimeBytesEqual(
      record.peerIdentity.rootFingerprint,
      peerIdentity.rootFingerprint,
    )) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.identityChanged,
        '远程设备根身份已变化',
      );
    }
    final updated = record.copyWith(
      peerIdentity: peerIdentity,
      lastConnectedAt: _now().toUtc(),
    );
    await _save(updated);
    return updated;
  }

  Future<void> revoke(TrustedDeviceRecord record) async {
    await initialize();
    await _repository!.revoke(record, _now().toUtc());
    await _appendAudit(TrustedAuditAction.revoked, record);
    await reload();
  }

  Future<List<TrustedAuditRecord>> listAudit({
    int limit = 50,
    int offset = 0,
  }) async {
    await initialize();
    return _repository!.listAudit(limit: limit, offset: offset);
  }

  void endSession(String sessionId) {
    _nextSequenceBySession.remove(sessionId);
    _lastRemoteSequenceBySession.removeWhere(
      (key, _) => key.startsWith('$sessionId:'),
    );
    _consumedNonces.removeWhere((key, _) => key.startsWith('$sessionId:'));
  }

  Future<void> _validatePeerIdentity(TrustedPeerIdentity peer) async {
    peer.validateStructure();
    final fingerprint = Uint8List.fromList(
      sha256.convert(peer.rootPublicKey).bytes,
    );
    if (!constantTimeBytesEqual(fingerprint, peer.rootFingerprint)) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.identityChanged,
        '设备根公钥指纹不匹配',
      );
    }
    if (DeviceIdentityController.machineCodeV2ForRootPublicKey(
          peer.rootPublicKey,
        ) !=
        peer.machineCode) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.identityChanged,
        '机器码与设备根身份不匹配',
      );
    }
    final now = _now().toUtc();
    if (now.isBefore(peer.authenticationNotBefore) ||
        !now.isBefore(peer.authenticationExpiresAt)) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.expired,
        '设备认证子密钥已过期',
      );
    }
    final verified = await identity.verifyP256Signature(
      publicKey: peer.rootPublicKey,
      message: peer.authenticationCertificateBody,
      signature: peer.authenticationCertificate,
    );
    if (!verified) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.invalidCertificate,
        '设备认证子密钥证书无效',
      );
    }
  }

  Future<void> _validateGrant({
    required TrustedDeviceGrant grant,
    required TrustedPeerIdentity issuer,
    required Uint8List expectedSubject,
    required Set<TrustedPermission> requestedPermissions,
  }) async {
    grant.validateStructure();
    if (!constantTimeBytesEqual(
          grant.issuerRootFingerprint,
          issuer.rootFingerprint,
        ) ||
        !constantTimeBytesEqual(
          grant.subjectRootFingerprint,
          expectedSubject,
        )) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.identityChanged,
        '可信授权的设备身份不匹配',
      );
    }
    final now = _now().toUtc();
    if (!now.isBefore(grant.hardExpiresAt)) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.hardReviewRequired,
        '可信关系已达到人工复核期限，请使用连接码重新确认',
      );
    }
    if (!grant.isUsableAt(now)) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.expired,
        '可信授权已过期，请使用连接码重新确认',
      );
    }
    if (!requestedPermissions.every(grant.permissions.contains)) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.permissionsDenied,
        '本次请求超出可信授权范围',
      );
    }
    final verified = await identity.verifyP256Signature(
      publicKey: issuer.rootPublicKey,
      message: grant.signingBytes,
      signature: grant.signature,
    );
    if (!verified) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.invalidSignature,
        '可信授权签名无效',
      );
    }
  }

  void _ensureGrantCurrent(TrustedDeviceRecord record) {
    final now = _now().toUtc();
    if (!now.isBefore(record.grant.hardExpiresAt)) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.hardReviewRequired,
        '可信关系需要通过连接码重新确认',
      );
    }
    if (!record.usableAt(now)) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.expired,
        '可信关系已过期，请改用连接码',
      );
    }
  }

  Future<void> _save(TrustedDeviceRecord record) async {
    await _repository!.upsert(record);
    await reload();
  }

  bool _sameGrant(TrustedDeviceGrant first, TrustedDeviceGrant second) =>
      constantTimeBytesEqual(first.signingBytes, second.signingBytes) &&
      constantTimeBytesEqual(first.signature, second.signature);

  Future<void> _appendAudit(
    TrustedAuditAction action,
    TrustedDeviceRecord record,
  ) async {
    final repository = _repository;
    if (repository == null) return;
    final now = _now().toUtc();
    await repository.appendAudit(
      TrustedAuditRecord(
        id: base64UrlEncode(securityRandomBytes(16)).replaceAll('=', ''),
        action: action,
        peerName: record.peerName,
        peerMachineCode: record.peerIdentity.machineCode,
        occurredAt: now,
        detail:
            'permissionBits=${trustedPermissionBits(record.grant.permissions)}',
      ),
    );
  }

  @override
  void dispose() {
    _repository?.close();
    super.dispose();
  }
}
