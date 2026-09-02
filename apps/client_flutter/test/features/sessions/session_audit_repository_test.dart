import 'dart:io';

import 'package:cross_desktop_remote/features/sessions/application/session_audit_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'encrypts sensitive metadata and pages ten sessions at a time',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cdr-audit-test-',
      );
      final databasePath = '${directory.path}/audit.sqlite3';
      final repository = await SessionAuditRepository.open(
        databasePath: databasePath,
        encryptionKey: List<int>.generate(32, (index) => index),
      );
      addTearDown(() async {
        repository.close();
        await directory.delete(recursive: true);
      });

      for (var index = 0; index < 12; index += 1) {
        final startedAt = DateTime.utc(2026, 8, 1, 0, index);
        await repository.upsertSession(
          SessionRecord(
            id: 'session-$index',
            startedAt: startedAt,
            endedAt: startedAt.add(const Duration(minutes: 1)),
            role: 'controller',
            deviceName: 'secret-device-$index',
            displayName: 'Sidecar',
            quality: '2K · 60 fps',
            outcome: '正常断开',
            localAddress: '192.168.1.10',
            remoteAddress: '192.168.1.20',
          ),
        );
      }

      final first = await repository.loadSessions();
      final second = await repository.loadSessions(cursor: first.nextCursor);
      final bytes = await File(databasePath).readAsBytes();
      final databaseText = String.fromCharCodes(bytes);

      expect(first.records, hasLength(10));
      expect(first.nextCursor, isNotNull);
      expect(second.records, hasLength(2));
      expect(second.nextCursor, isNull);
      expect(databaseText, isNot(contains('secret-device')));
      expect(databaseText, isNot(contains('192.168.1.20')));
    },
  );

  test('upserts transfer progress and retains encrypted paths', () async {
    final directory = await Directory.systemTemp.createTemp('cdr-audit-test-');
    final databasePath = '${directory.path}/audit.sqlite3';
    final repository = await SessionAuditRepository.open(
      databasePath: databasePath,
      encryptionKey: List<int>.filled(32, 7),
    );
    addTearDown(() async {
      repository.close();
      await directory.delete(recursive: true);
    });
    final now = DateTime.utc(2026, 8, 1);
    await repository.upsertSession(
      SessionRecord(
        id: 'session',
        startedAt: now,
        endedAt: now,
        role: 'host',
        deviceName: 'Windows',
        displayName: 'Display 1',
        quality: '自动',
        outcome: '进行中',
      ),
    );
    await repository.upsertTransfer(
      FileTransferAuditRecord(
        id: 'transfer',
        sessionId: 'session',
        updatedAt: now,
        direction: 'incoming',
        state: 'transferring',
        transferredBytes: 5,
        totalBytes: 10,
        relativePaths: const ['report.docx'],
        sourcePaths: const ['C:\\private\\report.docx'],
        destinationRoot: '/Users/example/Documents',
      ),
    );
    await repository.upsertTransfer(
      FileTransferAuditRecord(
        id: 'transfer',
        sessionId: 'session',
        updatedAt: now.add(const Duration(seconds: 1)),
        direction: 'incoming',
        state: 'completed',
        transferredBytes: 10,
        totalBytes: 10,
        relativePaths: const ['report.docx'],
        sourcePaths: const ['C:\\private\\report.docx'],
        destinationRoot: '/Users/example/Documents',
      ),
    );

    final records = await repository.loadTransfers('session');
    final databaseText = String.fromCharCodes(
      await File(databasePath).readAsBytes(),
    );

    expect(records, hasLength(1));
    expect(records.single.state, 'completed');
    expect(databaseText, isNot(contains('report.docx')));
    expect(databaseText, isNot(contains('/Users/example/Documents')));
  });
}
