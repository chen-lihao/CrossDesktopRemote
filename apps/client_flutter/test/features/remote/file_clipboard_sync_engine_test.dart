import 'dart:async';
import 'dart:math';

import 'package:cross_desktop_remote/core/clipboard/clipboard_platform_adapter.dart';
import 'package:cross_desktop_remote/core/files/file_paste_target_platform_adapter.dart';
import 'package:cross_desktop_remote/features/remote/application/file_clipboard_sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const destinationLeaseId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const sessionId = '11111111111111111111111111111111';
  const offerId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const generation = 7;
  FilePasteTransactionIdentity transaction([
    String pasteIntentId = 'cccccccccccccccccccccccccccccccc',
  ]) => FilePasteTransactionIdentity(
    sessionId: sessionId,
    offerId: offerId,
    generation: generation,
    pasteIntentId: pasteIntentId,
  );
  ClipboardSnapshot files(int revision, List<String> paths) =>
      ClipboardSnapshot(
        revision: revision,
        hasText: false,
        tooLarge: false,
        utf8Bytes: 0,
        filePaths: paths,
      );

  test('coordinator resets all session-scoped paste identities atomically', () {
    final coordinator = FileCopyPasteCoordinator(
      publisher: (_, _) async => 'transfer-a',
      canceller: (_) async {},
    );
    final previousSessionId = coordinator.localSessionId;
    coordinator.remoteSessionId = sessionId;
    coordinator.remoteOffer = const RemoteFileClipboardOffer(
      sessionId: sessionId,
      id: offerId,
      generation: generation,
      revision: 1,
      names: ['a.txt'],
      itemCount: 1,
    );
    coordinator.remoteTransfersByIntent[transaction().pasteIntentId] = (
      transferId: 'transfer-a',
      destinationLeaseId: destinationLeaseId,
      transaction: transaction(),
    );
    coordinator.trackedRemotePasteIntents.add(transaction().pasteIntentId);

    coordinator.beginSession();

    expect(coordinator.localSessionId, isNot(previousSessionId));
    expect(coordinator.remoteSessionId, isNull);
    expect(coordinator.remoteOffer, isNull);
    expect(coordinator.remoteTransfersByIntent, isEmpty);
    expect(coordinator.trackedRemotePasteIntents, isEmpty);
  });

  test(
    'new clipboard revision never reuses the previous transfer id',
    () async {
      final second = Completer<String>();
      var publishes = 0;
      final cancelled = <String>[];
      final coordinator = FileClipboardOfferBroker(
        publisher: (paths, _) {
          publishes += 1;
          return publishes == 1 ? Future.value('transfer-a') : second.future;
        },
        canceller: (id) async => cancelled.add(id),
      );

      final firstSnapshot = files(1, ['/tmp/a.txt']);
      coordinator.arm(firstSnapshot);
      expect(
        await coordinator.materialize(
          firstSnapshot,
          destinationLeaseId: destinationLeaseId,
        ),
        'transfer-a',
      );
      final secondSnapshot = files(2, ['/tmp/b.txt']);
      coordinator.arm(secondSnapshot);
      final background = coordinator.materialize(
        secondSnapshot,
        destinationLeaseId: destinationLeaseId,
      );
      final explicitPaste = coordinator.materialize(
        secondSnapshot,
        destinationLeaseId: destinationLeaseId,
      );
      var completedEarly = false;
      explicitPaste.then((_) => completedEarly = true);
      await Future<void>.delayed(Duration.zero);

      expect(completedEarly, isFalse);
      expect(publishes, 2);
      second.complete('transfer-b');
      expect(await background, 'transfer-b');
      expect(await explicitPaste, 'transfer-b');
      expect(cancelled, isEmpty);
    },
  );

  test('paste intent survives a later clipboard revision', () async {
    final first = Completer<String>();
    final second = Completer<String>();
    final cancelled = <String>[];
    var publishes = 0;
    final coordinator = FileClipboardOfferBroker(
      publisher: (_, _) => ++publishes == 1 ? first.future : second.future,
      canceller: (id) async => cancelled.add(id),
    );

    final firstSnapshot = files(10, ['/tmp/a.txt']);
    coordinator.arm(firstSnapshot);
    final stale = coordinator.materialize(
      firstSnapshot,
      destinationLeaseId: destinationLeaseId,
    );
    final secondSnapshot = files(11, ['/tmp/b.txt']);
    coordinator.arm(secondSnapshot);
    final current = coordinator.materialize(
      secondSnapshot,
      destinationLeaseId: destinationLeaseId,
    );
    second.complete('transfer-b');
    expect(await current, 'transfer-b');
    first.complete('transfer-a');
    expect(await stale, 'transfer-a');
    expect(cancelled, isEmpty);
    expect(coordinator.currentTransferId, 'transfer-b');
  });

  test(
    'copying the same path with a new revision creates a new task',
    () async {
      var publishes = 0;
      final coordinator = FileClipboardOfferBroker(
        publisher: (_, _) async => 'transfer-${++publishes}',
        canceller: (_) async {},
      );

      final firstSnapshot = files(20, ['/tmp/a.txt']);
      coordinator.arm(firstSnapshot);
      expect(
        await coordinator.materialize(
          firstSnapshot,
          destinationLeaseId: destinationLeaseId,
        ),
        'transfer-1',
      );
      final secondSnapshot = files(21, ['/tmp/a.txt']);
      coordinator.arm(secondSnapshot);
      expect(
        await coordinator.materialize(
          secondSnapshot,
          destinationLeaseId: destinationLeaseId,
        ),
        'transfer-2',
      );
      expect(publishes, 2);
    },
  );

  test(
    'releasing an applied transfer does not cancel its backing task',
    () async {
      final cancelled = <String>[];
      var publishes = 0;
      final coordinator = FileClipboardOfferBroker(
        publisher: (_, _) async => 'transfer-${++publishes}',
        canceller: (id) async => cancelled.add(id),
      );

      final snapshot = files(30, ['/tmp/a.txt']);
      coordinator.arm(snapshot);
      final transferId = await coordinator.materialize(
        snapshot,
        destinationLeaseId: destinationLeaseId,
      );
      coordinator.releaseTransfer(transferId!);
      expect(cancelled, isEmpty);
      expect(coordinator.currentTransferId, isNull);
      coordinator.arm(snapshot);
      expect(
        await coordinator.materialize(
          snapshot,
          destinationLeaseId: destinationLeaseId,
        ),
        'transfer-2',
      );
    },
  );

  test('copy arms an immutable offer without starting transfer', () async {
    var publishes = 0;
    final coordinator = FileClipboardOfferBroker(
      publisher: (_, _) async => 'transfer-${++publishes}',
      canceller: (_) async {},
    );
    final snapshot = files(40, ['/tmp/a.txt']);

    coordinator.arm(snapshot);

    expect(coordinator.hasOffer, isTrue);
    expect(coordinator.currentRevision, 40);
    expect(coordinator.currentTransferId, isNull);
    expect(publishes, 0);
    expect(
      await coordinator.materialize(
        snapshot,
        destinationLeaseId: destinationLeaseId,
      ),
      'transfer-1',
    );
    expect(publishes, 1);
  });

  test('remote offer contains metadata only and validates its identity', () {
    final message = remoteFileOfferMessage(
      sessionId: sessionId,
      offerId: offerId,
      generation: generation,
      revision: 41,
      names: const ['a.txt', '资料'],
    );
    final offer = RemoteFileClipboardOffer.fromMessage(message);

    expect(offer.sessionId, sessionId);
    expect(offer.id, offerId);
    expect(offer.generation, generation);
    expect(offer.revision, 41);
    expect(offer.names, ['a.txt', '资料']);
    expect(offer.itemCount, 2);
    expect(message, isNot(contains('paths')));
    expect(message, isNot(contains('destination')));
  });

  test('remote offer rejects malformed metadata', () {
    expect(
      () => RemoteFileClipboardOffer.fromMessage({
        'type': 'file-offer',
        'version': fileClipboardWireVersion,
        'sessionId': sessionId,
        'offerId': offerId,
        'generation': generation,
        'revision': 1,
        'names': const <String>[],
        'itemCount': 1,
      }),
      throwsFormatException,
    );
  });

  test('text clipboard revision revokes an unmaterialized offer', () async {
    var publishes = 0;
    final coordinator = FileClipboardOfferBroker(
      publisher: (_, _) async => 'transfer-${++publishes}',
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
      publisher: (_, _) async => 'transfer-${++publishes}',
      canceller: (_) async {},
      offerLifetime: Duration.zero,
    );
    final snapshot = files(60, ['/tmp/a.txt']);
    coordinator.arm(snapshot);

    expect(
      await coordinator.materialize(
        snapshot,
        destinationLeaseId: destinationLeaseId,
      ),
      isNull,
    );
    expect(coordinator.hasOffer, isFalse);
    expect(publishes, 0);
  });

  test('offer lease no longer expires after paste starts transfer', () async {
    final transfer = Completer<String>();
    final coordinator = FileClipboardOfferBroker(
      publisher: (_, _) => transfer.future,
      canceller: (_) async {},
      offerLifetime: const Duration(milliseconds: 10),
    );
    final snapshot = files(61, ['/tmp/large.bin']);
    coordinator.arm(snapshot);
    final result = coordinator.materialize(
      snapshot,
      destinationLeaseId: destinationLeaseId,
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(coordinator.hasOffer, isTrue);
    transfer.complete('transfer-large');
    expect(await result, 'transfer-large');
  });

  test('paste intent returns only an opaque destination lease', () async {
    final gate = FilePasteIntentGate(random: Random(7));
    final ticket = gate.begin(
      sessionId: sessionId,
      offerId: offerId,
      generation: generation,
    );

    expect(
      gate.accept(
        filePasteReadyMessage(
          transaction: ticket.transaction,
          destinationLeaseId: destinationLeaseId,
        ),
      ),
      isTrue,
    );
    expect(await ticket.ready, destinationLeaseId);
  });

  test('destination lease freezes and consumes one active folder', () {
    final registry = FilePasteDestinationLeaseRegistry(random: Random(9));
    const target = FilePasteTarget(
      path: '/Users/example/Documents',
      displayName: 'Documents',
      application: 'Finder',
      directoryIdentity: '1:42',
      writable: true,
    );
    final lease = registry.create(transaction: transaction(), target: target);

    expect(lease.id, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(registry.take(lease.id)?.target.path, target.path);
    expect(registry.take(lease.id), isNull);
  });

  test('destination lease is idempotent only for the same transaction', () {
    final registry = FilePasteDestinationLeaseRegistry(random: Random(10));
    const target = FilePasteTarget(
      path: '/Users/example/Documents',
      displayName: 'Documents',
      application: 'Finder',
      directoryIdentity: '1:42',
      writable: true,
    );
    final first = registry.create(transaction: transaction(), target: target);
    final duplicate = registry.create(
      transaction: transaction(),
      target: target,
    );

    expect(duplicate.id, first.id);
    expect(
      () => registry.create(
        transaction: transaction().copyWithForTest(generation: generation + 1),
        target: target,
      ),
      throwsStateError,
    );
    expect(registry.revoke(first.id, transaction: transaction()), isTrue);
  });

  test('paste reply from another session cannot satisfy the intent', () async {
    final gate = FilePasteIntentGate(random: Random(11));
    final ticket = gate.begin(
      sessionId: sessionId,
      offerId: offerId,
      generation: generation,
    );
    final staleTransaction = FilePasteTransactionIdentity(
      sessionId: '22222222222222222222222222222222',
      offerId: ticket.transaction.offerId,
      generation: ticket.transaction.generation,
      pasteIntentId: ticket.transaction.pasteIntentId,
    );

    expect(
      gate.accept(
        filePasteReadyMessage(
          transaction: staleTransaction,
          destinationLeaseId: destinationLeaseId,
        ),
      ),
      isFalse,
    );
    expect(await ticket.ready, isNull);
  });

  test('commit gate completes only for the matching paste identity', () async {
    final gate = FilePasteCommitGate();
    final waiting = gate.waitFor(
      '0123456789abcdef0123456789abcdef',
      transaction: transaction(),
      destinationLeaseId: destinationLeaseId,
      timeout: const Duration(seconds: 1),
    );

    expect(
      gate.accept(
        filePasteCommittedMessage(
          transaction: transaction('dddddddddddddddddddddddddddddddd'),
          destinationLeaseId: destinationLeaseId,
          transferId: 'fedcba9876543210fedcba9876543210',
        ),
      ),
      isTrue,
    );
    expect(
      gate.accept(
        filePasteCommittedMessage(
          transaction: transaction(),
          destinationLeaseId: destinationLeaseId,
          transferId: '0123456789abcdef0123456789abcdef',
        ),
      ),
      isTrue,
    );
    expect(await waiting, isTrue);
  });

  test('commit gate retains an early destination acknowledgement', () async {
    final gate = FilePasteCommitGate();
    gate.accept(
      filePasteCommittedMessage(
        transaction: transaction(),
        destinationLeaseId: destinationLeaseId,
        transferId: '0123456789abcdef0123456789abcdef',
      ),
    );
    expect(
      await gate.waitFor(
        '0123456789abcdef0123456789abcdef',
        transaction: transaction(),
        destinationLeaseId: destinationLeaseId,
      ),
      isTrue,
    );
  });

  test('commit gate retains an early transfer failure', () async {
    final gate = FilePasteCommitGate();
    gate.fail('0123456789abcdef0123456789abcdef');
    expect(
      await gate.waitFor(
        '0123456789abcdef0123456789abcdef',
        transaction: transaction(),
        destinationLeaseId: destinationLeaseId,
      ),
      isFalse,
    );
  });

  test('a paste transaction cannot be rebound to another directory', () async {
    var publishes = 0;
    final coordinator = FileClipboardOfferBroker(
      publisher: (_, _) async => 'transfer-${++publishes}',
      canceller: (_) async {},
    );
    final snapshot = files(70, ['/tmp/a.txt']);
    coordinator.arm(snapshot);

    expect(
      await coordinator.materialize(
        snapshot,
        destinationLeaseId: destinationLeaseId,
      ),
      'transfer-1',
    );
    expect(
      await coordinator.materialize(
        snapshot,
        destinationLeaseId: 'dddddddddddddddddddddddddddddddd',
      ),
      isNull,
    );
    expect(publishes, 1);
  });
}

extension on FilePasteTransactionIdentity {
  FilePasteTransactionIdentity copyWithForTest({int? generation}) {
    return FilePasteTransactionIdentity(
      sessionId: sessionId,
      offerId: offerId,
      generation: generation ?? this.generation,
      pasteIntentId: pasteIntentId,
    );
  }
}
