import 'package:cross_desktop_remote/features/remote/application/remote_session_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'keeps one stable identity across lifecycle and transfer events',
    () async {
      final kernel = RemoteSessionKernel(role: 'controller');
      final events = <RemoteSessionDomainEvent>[];
      final subscription = kernel.events.listen(events.add);

      final sessionId = kernel.begin(localDeviceId: 'local-device');
      kernel.updatePeer('remote-device');
      kernel.recordState(state: 'streaming', message: 'connected');
      kernel.recordTransfer(
        transferId: 'transfer-1',
        direction: 'outgoing',
        state: 'transferring',
        transferredBytes: 16,
        totalBytes: 32,
        items: const [
          RemoteTransferItemMetadata(
            relativePath: 'a.txt',
            sizeBytes: 32,
            kind: 'file',
          ),
        ],
      );
      kernel.end(outcome: 'disconnected');

      expect(sessionId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(events, hasLength(5));
      expect(events.map((event) => event.sessionId).toSet(), {sessionId});
      expect(
        events.whereType<RemoteSessionClosedEvent>().single.outcome,
        'disconnected',
      );

      await subscription.cancel();
      await kernel.dispose();
    },
  );

  test('begin retires the previous active identity', () async {
    final kernel = RemoteSessionKernel(role: 'host');
    final events = <RemoteSessionDomainEvent>[];
    final subscription = kernel.events.listen(events.add);

    final first = kernel.begin(localDeviceId: 'local-device');
    final second = kernel.begin(localDeviceId: 'local-device');

    expect(second, isNot(first));
    expect(
      events.whereType<RemoteSessionClosedEvent>().single.outcome,
      'superseded',
    );

    await subscription.cancel();
    await kernel.dispose();
  });
}
