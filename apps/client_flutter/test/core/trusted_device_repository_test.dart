import 'dart:typed_data';

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
