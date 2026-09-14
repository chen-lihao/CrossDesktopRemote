import 'dart:async';
import 'dart:convert';

import 'package:cross_desktop_remote/core/identity/device_identity.dart';
import 'package:cross_desktop_remote/core/security/trusted_device_models.dart';
import 'package:cross_desktop_remote/core/security/trusted_device_repository.dart';
import 'package:cross_desktop_remote/core/security/trusted_security_engine.dart';
import 'package:flutter/foundation.dart';

enum TrustedAuthenticationFailure {
  unsupported,
  identityChanged,
  invalidCertificate,
  invalidSignature,
  replay,
  clockSkew,
  expired,
  revoked,
  permissionsDenied,
  hardReviewRequired,
  invalidLifetime,
}

enum TrustedAuthorizationInvalidationReason {
  allConnectionsPaused,
  grantRevoked,
}

@immutable
class TrustedAuthorizationInvalidation {
  const TrustedAuthorizationInvalidation({
    required this.reason,
    this.peerRootFingerprint,
    this.grantIds = const [],
  });

  final TrustedAuthorizationInvalidationReason reason;
  final Uint8List? peerRootFingerprint;
  final List<Uint8List> grantIds;

  bool affects({Uint8List? peerFingerprint, Uint8List? grantId}) {
    if (reason == TrustedAuthorizationInvalidationReason.allConnectionsPaused) {
      return true;
    }
    if (peerFingerprint != null &&
        peerRootFingerprint != null &&
        constantTimeBytesEqual(peerFingerprint, peerRootFingerprint!)) {
      return true;
    }
    return grantId != null &&
        grantIds.any((value) => constantTimeBytesEqual(value, grantId));
  }
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
    TrustedSecurityEngineFactory? securityEngineFactory,
    DateTime Function()? now,
  }) : _repository = initialRepository,
       _securityEngineFactory =
           securityEngineFactory ??
           NativeTrustedSecurityEngineFactory.tryOpen(),
       _now = now ?? DateTime.now;

  final DeviceIdentityController identity;
  final TrustedSecurityEngineFactory? _securityEngineFactory;
  TrustedDeviceRepository? _repository;
  Future<void>? _initializing;
  final DateTime Function() _now;
  List<TrustedDeviceRecord> _devices = const [];
  bool _connectionsPaused = false;
  final Map<String, int> _nextSequenceBySession = {};
  final Map<String, TrustedSecuritySession> _securitySessions = {};
  final StreamController<TrustedAuthorizationInvalidation> _invalidations =
      StreamController<TrustedAuthorizationInvalidation>.broadcast(sync: true);

  bool get initialized => _repository != null;
  bool get supported =>
      identity.identity?.trustedAuthenticationAvailable == true &&
      _securityEngineFactory != null;
  bool get securityCoreAvailable => _securityEngineFactory != null;
  bool get connectionsPaused => _connectionsPaused;
  bool get connectionsEnabled => supported && !_connectionsPaused;
  List<TrustedDeviceRecord> get devices => List.unmodifiable(_devices);
  Stream<TrustedAuthorizationInvalidation> get invalidations =>
      _invalidations.stream;

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
    await _repository!.prunePairingTransactions(_now());
    _connectionsPaused = await _repository!.readConnectionsPaused();
    await reload();
  }

  Future<void> setConnectionsPaused(bool value) async {
    await initialize();
    if (_connectionsPaused == value) return;
    await _repository!.writeConnectionsPaused(value);
    _connectionsPaused = value;
    for (final session in _securitySessions.values) {
      session.setPaused(value);
    }
    if (value) {
      _invalidations.add(
        const TrustedAuthorizationInvalidation(
          reason: TrustedAuthorizationInvalidationReason.allConnectionsPaused,
        ),
      );
    }
    notifyListeners();
  }

  void beginSecuritySession({
    required String sessionId,
    required Uint8List peerRootFingerprint,
    required Set<TrustedPermission> requestedPermissions,
    required TrustedSecuritySessionMode mode,
  }) {
    final factory = _securityEngineFactory;
    final local = localPublicIdentity();
    if (factory == null) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.unsupported,
        'Rust 可信安全核心不可用',
      );
    }
    endSession(sessionId);
    final session = factory.create(local.rootFingerprint);
    try {
      session.setPaused(_connectionsPaused);
      session.begin(
        sessionId: sessionId,
        peerRootFingerprint: peerRootFingerprint,
        requestedPermissions: requestedPermissions,
        mode: mode,
      );
      _securitySessions[sessionId] = session;
    } on TrustedSecurityEngineException catch (error) {
      session.dispose();
      throw _authenticationException(error);
    } catch (_) {
      session.dispose();
      rethrow;
    }
  }

  TrustedSecurityPhase securityPhase(String sessionId) =>
      _requireSecuritySession(sessionId).phase;

  void confirmPairingSecuritySession(String sessionId, bool sasMatches) {
    try {
      _requireSecuritySession(sessionId).confirmPairing(sasMatches);
    } on TrustedSecurityEngineException catch (error) {
      throw _authenticationException(error);
    }
  }

  void completePairingSecuritySession(String sessionId) {
    try {
      _requireSecuritySession(sessionId).completePairing();
    } on TrustedSecurityEngineException catch (error) {
      throw _authenticationException(error);
    } finally {
      endSession(sessionId);
    }
  }

  Set<TrustedPermission> authorizeSessionGrant({
    required String sessionId,
    required TrustedDeviceGrant grant,
    required Uint8List issuerRootPublicKey,
    required Uint8List expectedSubjectFingerprint,
  }) {
    try {
      return _requireSecuritySession(sessionId).authorizeGrant(
        grant: grant,
        issuerRootPublicKey: issuerRootPublicKey,
        expectedSubjectFingerprint: expectedSubjectFingerprint,
        now: _now(),
      );
    } on TrustedSecurityEngineException catch (error) {
      throw _authenticationException(error);
    }
  }

  Set<TrustedPermission> validatePairingGrant({
    required String sessionId,
    required TrustedDeviceGrant grant,
    required Uint8List issuerRootPublicKey,
  }) {
    try {
      return _requireSecuritySession(sessionId).validatePairingGrant(
        grant: grant,
        issuerRootPublicKey: issuerRootPublicKey,
        now: _now(),
      );
    } on TrustedSecurityEngineException catch (error) {
      throw _authenticationException(error);
    }
  }

  void configureWebRtcSecurityContext({
    required String sessionId,
    required Uint8List controllerNonce,
    required Uint8List hostNonce,
    required TrustedPeerIdentity controllerIdentity,
    required TrustedPeerIdentity hostIdentity,
  }) {
    try {
      _requireSecuritySession(sessionId).configureWebRtcContext(
        controllerNonce: controllerNonce,
        hostNonce: hostNonce,
        controllerAuthenticationPublicKey:
            controllerIdentity.authenticationPublicKey,
        hostAuthenticationPublicKey: hostIdentity.authenticationPublicKey,
      );
    } on TrustedSecurityEngineException catch (error) {
      throw _authenticationException(error);
    }
  }

  Set<TrustedPermission> bindWebRtcSession({
    required String sessionId,
    required TrustedSessionBinding binding,
  }) {
    binding.validateStructure();
    try {
      return _requireSecuritySession(sessionId)
          .bindWebRtc(binding: binding, now: _now());
    } on TrustedSecurityEngineException catch (error) {
      throw _authenticationException(error);
    }
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

  Future<TrustedDeviceRecord> stagePairing({
    required String pairingSessionId,
    required String peerName,
    required TrustedPeerIdentity peer,
    required TrustedDeviceGrant grant,
    required bool localIsIssuer,
  }) async {
    await initialize();
    final now = _now().toUtc();
    final record = TrustedDeviceRecord(
      peerName: peerName,
      peerIdentity: peer,
      grant: grant,
      localIsIssuer: localIsIssuer,
      createdAt: now,
      lastConnectedAt: now,
    );
    await _repository!.stagePairing(
      pairingSessionId: pairingSessionId,
      record: record,
      expiresAt: now.add(const Duration(minutes: 5)),
    );
    return record;
  }

  Future<TrustedDeviceRecord> commitPairing({
    required String pairingSessionId,
    required Uint8List grantId,
  }) async {
    await initialize();
    final result = await _repository!.commitPairing(
      pairingSessionId: pairingSessionId,
      grantId: grantId,
      now: _now(),
    );
    if (result.committedNow) {
      await _appendAudit(TrustedAuditAction.paired, result.record);
      await reload();
    }
    return result.record;
  }

  Future<void> discardPendingPairing(
    String pairingSessionId, {
    Uint8List? grantId,
  }) async {
    await initialize();
    await _repository!.discardPairing(
      pairingSessionId: pairingSessionId,
      grantId: grantId,
    );
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
    return createRawEnvelope(
      sessionId: sessionId,
      recipientRootFingerprint: recipientRootFingerprint,
      payload: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      nonce: nonce,
    );
  }

  Future<SignedTrustedEnvelope> createRawEnvelope({
    required String sessionId,
    required Uint8List recipientRootFingerprint,
    required Uint8List payload,
    Uint8List? nonce,
  }) async {
    if (payload.length > trustedMaximumSignedPayloadBytes) {
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
      payload: payload,
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
    final payload = await verifyRawEnvelope(envelope: envelope, sender: sender);
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Trusted envelope payload must be a map');
    }
    return decoded;
  }

  Future<Uint8List> verifyRawEnvelope({
    required SignedTrustedEnvelope envelope,
    required TrustedPeerIdentity sender,
  }) async {
    envelope.validateStructure();
    await _validatePeerIdentity(sender);
    if (!constantTimeBytesEqual(
      envelope.senderRootFingerprint,
      sender.rootFingerprint,
    )) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.identityChanged,
        '发送设备身份与已固定身份不一致',
      );
    }
    try {
      _requireSecuritySession(envelope.sessionId)
          .verifyEnvelope(envelope: envelope, sender: sender, now: _now());
    } on TrustedSecurityEngineException catch (error) {
      throw _authenticationException(error);
    }
    return envelope.payload;
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
    final grantIds = <Uint8List>[
      record.grant.grantId,
      if (record.previousGrant case final previous?) previous.grantId,
    ];
    for (final session in _securitySessions.values) {
      for (final grantId in grantIds) {
        session.revokeGrant(grantId);
      }
    }
    _invalidations.add(
      TrustedAuthorizationInvalidation(
        reason: TrustedAuthorizationInvalidationReason.grantRevoked,
        peerRootFingerprint: record.peerIdentity.rootFingerprint,
        grantIds: List.unmodifiable(grantIds),
      ),
    );
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
    final session = _securitySessions.remove(sessionId);
    if (session != null) {
      try {
        session.end();
      } finally {
        session.dispose();
      }
    }
  }

  TrustedSecuritySession _requireSecuritySession(String sessionId) {
    final session = _securitySessions[sessionId];
    if (session == null) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.unsupported,
        '可信安全会话尚未建立',
      );
    }
    return session;
  }

  TrustedAuthenticationException _authenticationException(
    TrustedSecurityEngineException error,
  ) {
    final failure = switch (error.failure) {
      TrustedSecurityFailure.invalidSignature ||
      TrustedSecurityFailure.invalidMessage =>
        TrustedAuthenticationFailure.invalidSignature,
      TrustedSecurityFailure.replay => TrustedAuthenticationFailure.replay,
      TrustedSecurityFailure.notYetValid =>
        TrustedAuthenticationFailure.clockSkew,
      TrustedSecurityFailure.expired || TrustedSecurityFailure.softExpired =>
        TrustedAuthenticationFailure.expired,
      TrustedSecurityFailure.hardExpired =>
        TrustedAuthenticationFailure.hardReviewRequired,
      TrustedSecurityFailure.lifetimeExceeded =>
        TrustedAuthenticationFailure.invalidLifetime,
      TrustedSecurityFailure.permissionDenied =>
        TrustedAuthenticationFailure.permissionsDenied,
      TrustedSecurityFailure.revoked => TrustedAuthenticationFailure.revoked,
      TrustedSecurityFailure.sessionMismatch =>
        TrustedAuthenticationFailure.identityChanged,
      TrustedSecurityFailure.paused || TrustedSecurityFailure.unavailable =>
        TrustedAuthenticationFailure.unsupported,
      TrustedSecurityFailure.invalidArgument ||
      TrustedSecurityFailure.invalidState ||
      TrustedSecurityFailure.unknown =>
        TrustedAuthenticationFailure.invalidSignature,
    };
    final message = switch (failure) {
      TrustedAuthenticationFailure.clockSkew =>
        '两端系统时间相差超过 30 秒，请检查两台设备的“自动设置日期与时间”',
      TrustedAuthenticationFailure.expired => '可信授权或认证子密钥已过期',
      TrustedAuthenticationFailure.hardReviewRequired =>
        '可信关系已达到人工复核期限，请使用连接码重新确认',
      TrustedAuthenticationFailure.invalidLifetime => '可信凭证的有效期范围无效',
      _ => error.message,
    };
    return TrustedAuthenticationException(failure, message);
  }

  Future<void> _validatePeerIdentity(TrustedPeerIdentity peer) async {
    peer.validateStructure();
    final factory = _securityEngineFactory;
    if (factory == null) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.unsupported,
        'Rust 可信安全核心不可用',
      );
    }
    try {
      factory.validatePeerIdentity(peer: peer, now: _now());
    } on TrustedSecurityEngineException catch (error) {
      throw _authenticationException(error);
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
    if (grant.issuedAt.isAfter(now.add(trustedMaximumClockSkew))) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.clockSkew,
        '两端系统时间相差超过 30 秒，请检查两台设备的“自动设置日期与时间”',
      );
    }
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
    if (record.grant.issuedAt.isAfter(now.add(trustedMaximumClockSkew))) {
      throw const TrustedAuthenticationException(
        TrustedAuthenticationFailure.clockSkew,
        '两端系统时间相差超过 30 秒，请检查两台设备的“自动设置日期与时间”',
      );
    }
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
    for (final session in _securitySessions.values) {
      session.dispose();
    }
    _securitySessions.clear();
    _repository?.close();
    unawaited(_invalidations.close());
    super.dispose();
  }
}
