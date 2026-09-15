import 'dart:typed_data';

import 'package:cross_desktop_remote/core/identity/device_identity.dart';
import 'package:cross_desktop_remote/core/security/trusted_device_coordinator.dart';
import 'package:cross_desktop_remote/core/security/trusted_device_models.dart';
import 'package:cross_desktop_remote/core/security/trusted_device_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pairing SAS is symmetric and binds both nonces', () {
    final firstKey = Uint8List.fromList([4, ...List<int>.filled(64, 11)]);
    final secondKey = Uint8List.fromList([4, ...List<int>.filled(64, 29)]);
    final firstNonce = Uint8List.fromList(List<int>.filled(16, 3));
    final secondNonce = Uint8List.fromList(List<int>.filled(16, 5));

    final forward = trustedPairingSasCode(
      sessionId: 'pairing-session',
      firstPublicKey: firstKey,
      firstNonce: firstNonce,
      secondPublicKey: secondKey,
      secondNonce: secondNonce,
    );
    final reverse = trustedPairingSasCode(
      sessionId: 'pairing-session',
      firstPublicKey: secondKey,
      firstNonce: secondNonce,
      secondPublicKey: firstKey,
      secondNonce: firstNonce,
    );
    final changed = trustedPairingSasCode(
      sessionId: 'pairing-session',
      firstPublicKey: firstKey,
      firstNonce: Uint8List.fromList(List<int>.filled(16, 4)),
      secondPublicKey: secondKey,
      secondNonce: secondNonce,
    );

    expect(forward, matches(RegExp(r'^\d{6}$')));
    expect(reverse, forward);
    expect(changed, isNot(forward));
  });

  test('pairing confirmation binds the final host permission decision', () {
    final controllerFingerprint = Uint8List.fromList(List<int>.filled(32, 7));
    final hostFingerprint = Uint8List.fromList(List<int>.filled(32, 11));
    final controllerNonce = Uint8List.fromList(List<int>.filled(16, 13));
    final hostNonce = Uint8List.fromList(List<int>.filled(16, 17));

    Uint8List confirmation(Set<TrustedPermission> permissions) =>
        trustedPairingConfirmationBytes(
          sessionId: 'permission-bound-pairing',
          controllerRootFingerprint: controllerFingerprint,
          hostRootFingerprint: hostFingerprint,
          controllerNonce: controllerNonce,
          hostNonce: hostNonce,
          permissions: permissions,
        );

    final leastPrivilege = confirmation(defaultTrustedPermissions);
    final withFileTransfer = confirmation({
      ...defaultTrustedPermissions,
      TrustedPermission.transferFiles,
    });

    expect(withFileTransfer, isNot(orderedEquals(leastPrivilege)));
    expect(
      confirmation(defaultTrustedPermissions),
      orderedEquals(leastPrivilege),
    );
  });

  test('pairing receipt binds transaction, stage and signed grant', () {
    final now = DateTime.utc(2026, 9, 12);
    final grant = _grant(now, id: 6);
    final accepted = trustedPairingReceiptBytes(
      sessionId: 'pairing-receipt',
      grant: grant,
      stage: TrustedPairingReceiptStage.accepted,
    );
    final committed = trustedPairingReceiptBytes(
      sessionId: 'pairing-receipt',
      grant: grant,
      stage: TrustedPairingReceiptStage.committed,
    );

    expect(committed, isNot(orderedEquals(accepted)));
    expect(
      trustedPairingReceiptBytes(
        sessionId: 'different-session',
        grant: grant,
        stage: TrustedPairingReceiptStage.accepted,
      ),
      isNot(orderedEquals(accepted)),
    );
  });

  test('grant clock skew applies only to its start time', () {
    final now = DateTime.utc(2026, 9, 12, 12);
    final future = _grant(now.add(const Duration(seconds: 30)), id: 9);
    final tooFarFuture = _grant(
      now.add(const Duration(seconds: 30, milliseconds: 1)),
      id: 10,
    );
    final expired = _grant(now.subtract(const Duration(days: 90)), id: 11);

    expect(future.isUsableAt(now), isTrue);
    expect(tooFarFuture.isUsableAt(now), isFalse);
    expect(expired.isUsableAt(now), isFalse);
  });

  test('pairing records remain pending until peer commit', () async {
    final repository = await TrustedDeviceRepository.open(
      databasePath: ':memory:',
      encryptionKey: List<int>.filled(32, 19),
    );
    addTearDown(repository.close);
    final now = DateTime.utc(2026, 9, 12);
    final record = TrustedDeviceRecord(
      peerName: 'Pending PC',
      peerIdentity: _identity(),
      grant: _grant(now, id: 20),
      localIsIssuer: false,
      createdAt: now,
      lastConnectedAt: now,
    );

    await repository.stagePairing(
      pairingSessionId: 'pending-session',
      record: record,
      expiresAt: now.add(const Duration(minutes: 5)),
    );
    expect(await repository.list(), isEmpty);

    final firstCommit = await repository.commitPairing(
      pairingSessionId: 'pending-session',
      grantId: record.grant.grantId,
      now: now.add(const Duration(minutes: 1)),
    );
    final duplicateCommit = await repository.commitPairing(
      pairingSessionId: 'pending-session',
      grantId: record.grant.grantId,
      now: now.add(const Duration(minutes: 1)),
    );

    expect(firstCommit.committedNow, isTrue);
    expect(duplicateCommit.committedNow, isFalse);
    expect((await repository.list()).single.peerName, 'Pending PC');
  });

  test('cancelled pairing never becomes trusted', () async {
    final repository = await TrustedDeviceRepository.open(
      databasePath: ':memory:',
      encryptionKey: List<int>.filled(32, 21),
    );
    addTearDown(repository.close);
    final now = DateTime.utc(2026, 9, 12);
    final record = TrustedDeviceRecord(
      peerName: 'Cancelled PC',
      peerIdentity: _identity(),
      grant: _grant(now, id: 22),
      localIsIssuer: true,
      createdAt: now,
      lastConnectedAt: now,
    );
    await repository.stagePairing(
      pairingSessionId: 'cancelled-session',
      record: record,
      expiresAt: now.add(const Duration(minutes: 5)),
    );
    await repository.discardPairing(
      pairingSessionId: 'cancelled-session',
      grantId: record.grant.grantId,
    );

    await expectLater(
      repository.commitPairing(
        pairingSessionId: 'cancelled-session',
        grantId: record.grant.grantId,
        now: now,
      ),
      throwsA(isA<StateError>()),
    );
    expect(await repository.list(), isEmpty);
  });

  test('encrypts, lists, audits and revokes trusted-device records', () async {
    final repository = await TrustedDeviceRepository.open(
      databasePath: ':memory:',
      encryptionKey: List<int>.generate(32, (index) => index),
    );
    addTearDown(repository.close);
    final now = DateTime.utc(2026, 9, 12);
    final previous = _grant(now, id: 7);
    final record = TrustedDeviceRecord(
      peerName: 'Test PC',
      peerIdentity: _identity(),
      grant: _grant(now, id: 8),
      previousGrant: previous,
      previousGrantExpiresAt: now.add(const Duration(days: 7)),
      localIsIssuer: true,
      createdAt: now,
      lastConnectedAt: now,
    );

    await repository.upsert(record);
    final stored = await repository.list();
    expect(stored, hasLength(1));
    expect(stored.single.peerName, 'Test PC');
    expect(stored.single.previousGrant?.grantId.first, 7);

    final audit = TrustedAuditRecord(
      id: 'audit-1',
      action: TrustedAuditAction.paired,
      peerName: record.peerName,
      peerMachineCode: record.peerIdentity.machineCode,
      occurredAt: now,
    );
    await repository.appendAudit(audit);
    expect(
      (await repository.listAudit()).single.action,
      TrustedAuditAction.paired,
    );

    await repository.revoke(record, now.add(const Duration(hours: 1)));
    expect(await repository.list(), isEmpty);
    expect(await repository.isGrantRevoked(record.grant.grantId), isTrue);
    expect(await repository.isGrantRevoked(previous.grantId), isTrue);
  });

  test('persists fail-closed trusted connection pause state', () async {
    final repository = await TrustedDeviceRepository.open(
      databasePath: ':memory:',
      encryptionKey: List<int>.filled(32, 23),
    );
    addTearDown(repository.close);

    expect(await repository.readConnectionsPaused(), isFalse);
    await repository.writeConnectionsPaused(true);
    expect(await repository.readConnectionsPaused(), isTrue);
    await repository.writeConnectionsPaused(false);
    expect(await repository.readConnectionsPaused(), isFalse);
  });

  test(
    'stores host-owned directional access policy by monotonic revision',
    () async {
      final repository = await TrustedDeviceRepository.open(
        databasePath: ':memory:',
        encryptionKey: List<int>.filled(32, 27),
      );
      addTearDown(repository.close);
      final fingerprint = Uint8List.fromList(List<int>.filled(32, 5));
      final first = HostAccessPolicy(
        controllerRootFingerprint: fingerprint,
        revision: 1,
        enabled: true,
        permissions: const {
          TrustedPermission.viewScreen,
          TrustedPermission.uploadFilesToHost,
        },
        updatedAt: DateTime.utc(2026, 9, 14, 10),
      );
      final second = HostAccessPolicy(
        controllerRootFingerprint: fingerprint,
        revision: 2,
        enabled: false,
        permissions: const {
          TrustedPermission.viewScreen,
          TrustedPermission.downloadFilesFromHost,
        },
        updatedAt: DateTime.utc(2026, 9, 14, 11),
      );

      await repository.writeHostAccessPolicy(first);
      await repository.writeHostAccessPolicy(second);
      await repository.writeHostAccessPolicy(first);

      final stored = await repository.readHostAccessPolicy(fingerprint);
      expect(stored?.revision, 2);
      expect(stored?.enabled, isFalse);
      expect(stored?.permissions, {
        TrustedPermission.viewScreen,
        TrustedPermission.downloadFilesFromHost,
      });
    },
  );

  test('commits host policy with pairing and removes it on revoke', () async {
    final repository = await TrustedDeviceRepository.open(
      databasePath: ':memory:',
      encryptionKey: List<int>.filled(32, 29),
    );
    addTearDown(repository.close);
    final now = DateTime.utc(2026, 9, 14, 12);
    final record = TrustedDeviceRecord(
      peerName: 'Managed controller',
      peerIdentity: _identity(),
      grant: _grant(now, id: 24),
      localIsIssuer: true,
      createdAt: now,
      lastConnectedAt: now,
    );
    await repository.stagePairing(
      pairingSessionId: 'host-policy-pairing',
      record: record,
      expiresAt: now.add(const Duration(minutes: 5)),
    );

    await repository.commitPairing(
      pairingSessionId: 'host-policy-pairing',
      grantId: record.grant.grantId,
      now: now.add(const Duration(seconds: 1)),
      initialHostAccessPermissions: const {
        TrustedPermission.viewScreen,
        TrustedPermission.uploadFilesToHost,
      },
    );
    final policy = await repository.readHostAccessPolicy(
      record.peerIdentity.rootFingerprint,
    );
    expect(policy?.revision, 1);
    expect(policy?.permissions, {
      TrustedPermission.viewScreen,
      TrustedPermission.uploadFilesToHost,
    });

    final replacement = HostAccessPolicy(
      controllerRootFingerprint: record.peerIdentity.rootFingerprint,
      revision: 2,
      enabled: true,
      permissions: const {
        TrustedPermission.viewScreen,
        TrustedPermission.downloadFilesFromHost,
      },
      updatedAt: now.add(const Duration(minutes: 1)),
    );
    expect(
      await repository.replaceHostAccessPolicy(
        replacement,
        expectedRevision: 1,
      ),
      isTrue,
    );
    expect(
      await repository.replaceHostAccessPolicy(
        replacement,
        expectedRevision: 1,
      ),
      isFalse,
    );

    await repository.revoke(record, now.add(const Duration(minutes: 2)));
    expect(
      await repository.readHostAccessPolicy(
        record.peerIdentity.rootFingerprint,
      ),
      isNull,
    );
  });

  test('normalizes legacy file permission only at the policy boundary', () {
    final normalized = normalizeHostAccessPermissions(const {
      TrustedPermission.viewScreen,
      TrustedPermission.transferFiles,
    });

    expect(normalized, isNot(contains(TrustedPermission.transferFiles)));
    expect(normalized, contains(TrustedPermission.uploadFilesToHost));
    expect(normalized, contains(TrustedPermission.downloadFilesFromHost));
    expect(
      legacyCompatiblePermissions(normalized),
      contains(TrustedPermission.transferFiles),
    );
    expect(
      () => trustedPermissionsFromBitsStrict(
        1 << TrustedPermission.values.length,
      ),
      throwsFormatException,
    );
  });

  test('system audio permission is explicit and survives strict decoding', () {
    final permissions = {
      TrustedPermission.viewScreen,
      TrustedPermission.listenSystemAudio,
    };
    final bits = trustedPermissionBits(permissions);

    expect(trustedPermissionsFromBitsStrict(bits), permissions);
    expect(
      defaultHostAccessPermissions,
      isNot(contains(TrustedPermission.listenSystemAudio)),
    );
  });

  test('publishes active-session invalidations for pause and revoke', () async {
    final repository = await TrustedDeviceRepository.open(
      databasePath: ':memory:',
      encryptionKey: List<int>.filled(32, 31),
    );
    final now = DateTime.utc(2026, 9, 12);
    final record = TrustedDeviceRecord(
      peerName: 'Revoked PC',
      peerIdentity: _identity(),
      grant: _grant(now, id: 12),
      localIsIssuer: true,
      createdAt: now,
      lastConnectedAt: now,
    );
    await repository.upsert(record);
    final coordinator = TrustedDeviceCoordinator(
      identity: DeviceIdentityController(),
      initialRepository: repository,
      now: () => now,
    );
    addTearDown(coordinator.dispose);
    await coordinator.initialize();
    final invalidations = <TrustedAuthorizationInvalidation>[];
    final subscription = coordinator.invalidations.listen(invalidations.add);
    addTearDown(subscription.cancel);

    await coordinator.setConnectionsPaused(true);
    await coordinator.setConnectionsPaused(false);
    await coordinator.revoke(record);

    expect(invalidations, hasLength(2));
    expect(
      invalidations.first.reason,
      TrustedAuthorizationInvalidationReason.allConnectionsPaused,
    );
    expect(
      invalidations.last.affects(
        peerFingerprint: record.peerIdentity.rootFingerprint,
      ),
      isTrue,
    );
    expect(invalidations.last.affects(grantId: record.grant.grantId), isTrue);
  });
}

TrustedPeerIdentity _identity() {
  final root = Uint8List.fromList([4, ...List<int>.filled(64, 1)]);
  return TrustedPeerIdentity(
    machineCode: 'CDR2-1234-5678-9ABC-DEFG-HJKM-NPQR',
    rootPublicKey: root,
    rootFingerprint: Uint8List.fromList(List<int>.filled(32, 2)),
    authenticationPublicKey: Uint8List.fromList([
      4,
      ...List<int>.filled(64, 3),
    ]),
    authenticationNotBefore: DateTime.utc(2026, 9, 12),
    authenticationExpiresAt: DateTime.utc(2026, 10, 12),
    authenticationCertificate: Uint8List.fromList([0x30, 6, 2, 1, 1, 2, 1, 1]),
  );
}

TrustedDeviceGrant _grant(DateTime now, {required int id}) =>
    TrustedDeviceGrant(
      grantId: Uint8List.fromList(List<int>.filled(16, id)),
      issuerRootFingerprint: Uint8List.fromList(List<int>.filled(32, 4)),
      subjectRootFingerprint: Uint8List.fromList(List<int>.filled(32, 2)),
      permissions: defaultTrustedPermissions,
      issuedAt: now,
      softExpiresAt: now.add(const Duration(days: 90)),
      hardExpiresAt: now.add(const Duration(days: 365)),
      automaticRenewal: true,
      signature: Uint8List.fromList([0x30, 6, 2, 1, 1, 2, 1, 1]),
    );
