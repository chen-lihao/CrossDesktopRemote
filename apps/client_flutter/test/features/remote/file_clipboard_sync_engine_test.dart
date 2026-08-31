import 'dart:async';

import 'package:cross_desktop_remote/core/clipboard/clipboard_platform_adapter.dart';
import 'package:cross_desktop_remote/features/remote/application/file_clipboard_sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ClipboardSnapshot files(int revision, List<String> paths) =>
      ClipboardSnapshot(
        revision: revision,
        hasText: false,
        tooLarge: false,
        utf8Bytes: 0,
        filePaths: paths,
      );

  test(
    'new clipboard revision never reuses the previous transfer id',
    () async {
      final second = Completer<String>();
      var publishes = 0;
      final cancelled = <String>[];
      final coordinator = FileClipboardOfferBroker(
        publisher: (paths) {
          publishes += 1;
          return publishes == 1 ? Future.value('transfer-a') : second.future;
        },
        canceller: (id) async => cancelled.add(id),
      );

      final firstSnapshot = files(1, ['/tmp/a.txt']);
      coordinator.arm(firstSnapshot);
      expect(await coordinator.materialize(firstSnapshot), 'transfer-a');
      final secondSnapshot = files(2, ['/tmp/b.txt']);
      coordinator.arm(secondSnapshot);
      final background = coordinator.materialize(secondSnapshot);
      final explicitPaste = coordinator.materialize(secondSnapshot);
      var completedEarly = false;
      explicitPaste.then((_) => completedEarly = true);
      await Future<void>.delayed(Duration.zero);

      expect(completedEarly, isFalse);
      expect(publishes, 2);
      second.complete('transfer-b');
      expect(await background, 'transfer-b');
      expect(await explicitPaste, 'transfer-b');
      expect(cancelled, contains('transfer-a'));
    },
  );

  test('late completion from a superseded generation is cancelled', () async {
    final first = Completer<String>();
    final second = Completer<String>();
    final cancelled = <String>[];
    var publishes = 0;
    final coordinator = FileClipboardOfferBroker(
      publisher: (_) => ++publishes == 1 ? first.future : second.future,
      canceller: (id) async => cancelled.add(id),
    );

    final firstSnapshot = files(10, ['/tmp/a.txt']);
    coordinator.arm(firstSnapshot);
    final stale = coordinator.materialize(firstSnapshot);
    final secondSnapshot = files(11, ['/tmp/b.txt']);
    coordinator.arm(secondSnapshot);
    final current = coordinator.materialize(secondSnapshot);
    second.complete('transfer-b');
    expect(await current, 'transfer-b');
    first.complete('transfer-a');
    expect(await stale, isNull);
    expect(cancelled, contains('transfer-a'));
    expect(coordinator.currentTransferId, 'transfer-b');
  });

  test(
    'copying the same path with a new revision creates a new task',
    () async {
      var publishes = 0;
      final coordinator = FileClipboardOfferBroker(
        publisher: (_) async => 'transfer-${++publishes}',
        canceller: (_) async {},
      );

      final firstSnapshot = files(20, ['/tmp/a.txt']);
      coordinator.arm(firstSnapshot);
      expect(await coordinator.materialize(firstSnapshot), 'transfer-1');
      final secondSnapshot = files(21, ['/tmp/a.txt']);
      coordinator.arm(secondSnapshot);
      expect(await coordinator.materialize(secondSnapshot), 'transfer-2');
      expect(publishes, 2);
    },
  );

  test(
    'releasing an applied transfer does not cancel its backing task',
    () async {
      final cancelled = <String>[];
      var publishes = 0;
      final coordinator = FileClipboardOfferBroker(
        publisher: (_) async => 'transfer-${++publishes}',
        canceller: (id) async => cancelled.add(id),
      );

      final snapshot = files(30, ['/tmp/a.txt']);
      coordinator.arm(snapshot);
      final transferId = await coordinator.materialize(snapshot);
      coordinator.releaseTransfer(transferId!);
      expect(cancelled, isEmpty);
      expect(coordinator.currentTransferId, isNull);
      coordinator.arm(snapshot);
      expect(await coordinator.materialize(snapshot), 'transfer-2');
    },
  );

  test('copy arms an immutable offer without starting transfer', () async {
    var publishes = 0;
    final coordinator = FileClipboardOfferBroker(
      publisher: (_) async => 'transfer-${++publishes}',
      canceller: (_) async {},
    );
    final snapshot = files(40, ['/tmp/a.txt']);

    coordinator.arm(snapshot);

    expect(coordinator.hasOffer, isTrue);
    expect(coordinator.currentRevision, 40);
    expect(coordinator.currentTransferId, isNull);
    expect(publishes, 0);
    expect(await coordinator.materialize(snapshot), 'transfer-1');
    expect(publishes, 1);
  });

  test('text clipboard revision revokes an unmaterialized offer', () async {
    var publishes = 0;
    final coordinator = FileClipboardOfferBroker(
      publisher: (_) async => 'transfer-${++publishes}',
      canceller: (_) async {},
    );
    coordinator.arm(files(50, ['/tmp/a.txt']));

    await coordinator.invalidate();

    expect(coordinator.hasOffer, isFalse);
    expect(publishes, 0);
  });

  test('paste cannot resurrect an expired offer', () async {
    var publishes = 0;
    final coordinator = FileClipboardOfferBroker(
      publisher: (_) async => 'transfer-${++publishes}',
      canceller: (_) async {},
      offerLifetime: Duration.zero,
    );
    final snapshot = files(60, ['/tmp/a.txt']);
    coordinator.arm(snapshot);

    expect(await coordinator.materialize(snapshot), isNull);
    expect(coordinator.hasOffer, isFalse);
    expect(publishes, 0);
  });

  test('offer lease no longer expires after paste starts transfer', () async {
    final transfer = Completer<String>();
    final coordinator = FileClipboardOfferBroker(
      publisher: (_) => transfer.future,
      canceller: (_) async {},
      offerLifetime: const Duration(milliseconds: 10),
    );
    final snapshot = files(61, ['/tmp/large.bin']);
    coordinator.arm(snapshot);
    final result = coordinator.materialize(snapshot);

    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(coordinator.hasOffer, isTrue);
    transfer.complete('transfer-large');
    expect(await result, 'transfer-large');
  });

  test(
    'clipboard temp lease is cleaned only after ownership changes',
    () async {
      final cleaned = <String>[];
      final leases = ClipboardTempLeaseManager(
        cleanup: (path) async => cleaned.add(path),
        retirementGrace: Duration.zero,
      );
      leases.registerReceiving('transfer-a', '/tmp/lease-a');
      leases.markClipboardOwned(
        'transfer-a',
        paths: const ['/tmp/lease-a/a.txt'],
        revision: 7,
      );

      leases.observeClipboard(files(7, ['/tmp/lease-a/a.txt']));
      await leases.drain();
      expect(cleaned, isEmpty);

      leases.observeClipboard(
        const ClipboardSnapshot(
          revision: 8,
          hasText: true,
          tooLarge: false,
          utf8Bytes: 4,
          text: 'next',
        ),
      );
      await leases.drain();
      expect(cleaned, ['/tmp/lease-a']);
      expect(leases.leaseCount, 0);
    },
  );

  test(
    'session retirement keeps the current clipboard backing files',
    () async {
      final cleaned = <String>[];
      final leases = ClipboardTempLeaseManager(
        cleanup: (path) async => cleaned.add(path),
        retirementGrace: Duration.zero,
      );
      leases.registerReceiving('owned', '/tmp/owned');
      leases.markClipboardOwned(
        'owned',
        paths: const ['/tmp/owned/a.txt'],
        revision: 1,
      );
      leases.registerReceiving('partial', '/tmp/partial');

      leases.retireSessionNonOwners();
      await leases.drain();
      expect(cleaned, ['/tmp/partial']);
      expect(leases.leaseCount, 1);
      await leases.dispose();
      expect(cleaned, ['/tmp/partial']);
    },
  );

  test(
    'terminal transfer cleanup never deletes clipboard-owned files',
    () async {
      final cleaned = <String>[];
      final leases = ClipboardTempLeaseManager(
        cleanup: (path) async => cleaned.add(path),
        retirementGrace: Duration.zero,
      );
      leases.registerReceiving('owned', '/tmp/owned');
      leases.markClipboardOwned(
        'owned',
        paths: const ['/tmp/owned/a.txt'],
        revision: 1,
      );

      leases.retireTransfer('owned', immediately: true);
      await leases.drain();
      expect(cleaned, isEmpty);
      expect(leases.leaseCount, 1);
    },
  );

  test(
    'apply gate completes only for the matching materialized transfer',
    () async {
      final gate = FileClipboardApplyGate();
      final waiting = gate.waitFor(
        '0123456789abcdef',
        timeout: const Duration(seconds: 1),
      );

      expect(
        gate.accept(fileClipboardAppliedMessage('fedcba9876543210')),
        isTrue,
      );
      expect(
        gate.accept(fileClipboardAppliedMessage('0123456789abcdef')),
        isTrue,
      );
      expect(await waiting, isTrue);
    },
  );

  test('apply gate retains an early materialization acknowledgement', () async {
    final gate = FileClipboardApplyGate();
    gate.accept(fileClipboardAppliedMessage('0123456789abcdef'));
    expect(await gate.waitFor('0123456789abcdef'), isTrue);
  });

  test('apply gate retains an early transfer failure', () async {
    final gate = FileClipboardApplyGate();
    gate.fail('0123456789abcdef');
    expect(await gate.waitFor('0123456789abcdef'), isFalse);
  });

  test('echo guard suppresses only the native write notification', () {
    final guard = FileClipboardEchoGuard()
      ..expect(['/tmp/a.txt', '/tmp/b.txt']);
    final matching = ClipboardSnapshot(
      revision: 2,
      hasText: false,
      tooLarge: false,
      utf8Bytes: 0,
      filePaths: const ['/tmp/b.txt', '/tmp/a.txt'],
    );
    expect(guard.consumeIfExpected(matching), isTrue);
    expect(guard.consumeIfExpected(matching), isFalse);
  });
}
