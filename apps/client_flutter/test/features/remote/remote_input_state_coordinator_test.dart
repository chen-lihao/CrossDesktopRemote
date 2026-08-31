import 'dart:async';

import 'package:cross_desktop_remote/features/remote/application/remote_input_state_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reliable input mutations run in receive order', () async {
    final coordinator = RemoteInputStateCoordinator();
    final firstGate = Completer<void>();
    final events = <String>[];

    final first = coordinator.enqueue(() async {
      events.add('modifier-down');
      await firstGate.future;
      events.add('modifier-ready');
    });
    final second = coordinator.enqueue(() async {
      events.add('pointer-down');
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, ['modifier-down']);
    firstGate.complete();
    await Future.wait([first, second]);
    expect(events, ['modifier-down', 'modifier-ready', 'pointer-down']);
  });

  test('failed input does not poison later reliable input', () async {
    final coordinator = RemoteInputStateCoordinator();
    final events = <String>[];

    await expectLater(
      coordinator.enqueue(() async => throw StateError('native failure')),
      throwsStateError,
    );
    await coordinator.enqueue(() async => events.add('recovered'));

    expect(events, ['recovered']);
  });

  test('generation change drops queued stale input before reset', () async {
    final coordinator = RemoteInputStateCoordinator();
    final firstGate = Completer<void>();
    final events = <String>[];

    final running = coordinator.enqueue(() async {
      events.add('running');
      await firstGate.future;
    });
    await Future<void>.delayed(Duration.zero);
    final stale = coordinator.enqueue(() async => events.add('stale'));
    coordinator.advanceGeneration();
    final reset = coordinator.enqueue(() async => events.add('reset'));

    firstGate.complete();
    await Future.wait([running, stale, reset]);
    expect(events, ['running', 'reset']);
  });
}
