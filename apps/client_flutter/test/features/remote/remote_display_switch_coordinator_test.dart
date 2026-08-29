import 'package:cross_desktop_remote/features/remote/application/remote_display_switch_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RemoteDisplaySwitchCoordinator', () {
    test('uses one transaction flow for every controller platform', () {
      final coordinator = RemoteDisplaySwitchCoordinator();
      final generation = coordinator.beginLocalRequest('secondary');

      expect(coordinator.pending, isTrue);
      expect(
        coordinator.markPreparing(
          displayId: 'secondary',
          generation: generation,
          inboundFramesBaseline: 100,
        ),
        isTrue,
      );
      expect(
        RemoteDisplaySwitchCoordinator.mediaAdvanced(
          baselineFrames: coordinator.inboundFramesBaseline,
          currentFrames: 101,
          hasValidFrame: false,
        ),
        isTrue,
        reason: 'media progress, not geometry, commits the switch',
      );
      expect(
        coordinator.markMediaReady(
          displayId: 'secondary',
          generation: generation,
        ),
        isTrue,
      );
      expect(
        coordinator.commit(displayId: 'secondary', generation: generation),
        isTrue,
      );
      expect(coordinator.pending, isFalse);
      expect(coordinator.snapshot.phase, RemoteDisplaySwitchPhase.committed);
    });

    test('does not require exact frame geometry when counters advance', () {
      expect(
        RemoteDisplaySwitchCoordinator.mediaAdvanced(
          baselineFrames: 200,
          currentFrames: 201,
          hasValidFrame: false,
        ),
        isTrue,
      );
      expect(
        RemoteDisplaySwitchCoordinator.mediaAdvanced(
          baselineFrames: 200,
          currentFrames: 200,
          hasValidFrame: true,
        ),
        isFalse,
      );
    });

    test('uses a valid frame when the WebRTC build omits counters', () {
      expect(
        RemoteDisplaySwitchCoordinator.mediaAdvanced(
          baselineFrames: null,
          currentFrames: null,
          hasValidFrame: true,
        ),
        isTrue,
      );
    });

    test('rejects stale generations without replacing the active request', () {
      final coordinator = RemoteDisplaySwitchCoordinator();
      final first = coordinator.beginLocalRequest('secondary');
      expect(coordinator.fail(generation: first, code: 'cancelled'), isTrue);
      final second = coordinator.beginLocalRequest('primary');

      expect(
        coordinator.markPreparing(displayId: 'secondary', generation: first),
        isFalse,
      );
      expect(coordinator.generation, second);
      expect(coordinator.targetDisplayId, 'primary');
    });

    test('keeps geometry outside the transaction contract', () {
      final coordinator = RemoteDisplaySwitchCoordinator();
      final generation = coordinator.beginLocalRequest('secondary');
      coordinator.markPreparing(displayId: 'secondary', generation: generation);

      expect(
        coordinator.markMediaReady(
          displayId: 'secondary',
          generation: generation,
        ),
        isTrue,
      );
      expect(
        coordinator.commit(displayId: 'secondary', generation: generation),
        isTrue,
      );
    });
  });
}
