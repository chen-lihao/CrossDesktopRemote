import 'dart:async';

import 'package:cross_desktop_remote/features/remote/application/host_invitation_lease_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rotates shortly before an invitation expires', () async {
    final rotated = Completer<void>();
    final controller = HostInvitationLeaseController(
      onRotationDue: () async => rotated.complete(),
      safetyMargin: Duration.zero,
    );
    addTearDown(controller.dispose);

    controller.arm(DateTime.now().add(const Duration(milliseconds: 30)));

    await rotated.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);
    expect(controller.rotationPending, isFalse);
  });

  test('cancel prevents an armed invitation from rotating', () async {
    var rotations = 0;
    final controller = HostInvitationLeaseController(
      onRotationDue: () async => rotations += 1,
      safetyMargin: Duration.zero,
    );
    addTearDown(controller.dispose);

    controller.arm(DateTime.now().add(const Duration(milliseconds: 40)));
    controller.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(rotations, 0);
    expect(controller.expiresAt, isNull);
  });

  test('server-authoritative lease only counts down locally', () async {
    var rotations = 0;
    final controller = HostInvitationLeaseController(
      onRotationDue: () async => rotations += 1,
      safetyMargin: Duration.zero,
    );
    addTearDown(controller.dispose);

    controller.arm(
      DateTime.now().add(const Duration(milliseconds: 30)),
      serverAuthoritative: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(rotations, 0);
    expect(controller.serverAuthoritative, isTrue);
    expect(controller.remaining, Duration.zero);
  });

  test('coalesces concurrent manual rotations', () async {
    final release = Completer<void>();
    var rotations = 0;
    final controller = HostInvitationLeaseController(
      onRotationDue: () async {
        rotations += 1;
        await release.future;
      },
    );
    addTearDown(controller.dispose);

    final first = controller.rotateNow();
    final second = controller.rotateNow();
    expect(rotations, 1);
    release.complete();
    await Future.wait([first, second]);

    expect(rotations, 1);
    expect(controller.rotationPending, isFalse);
  });

  test('contains scheduled rotation failures for owner recovery', () async {
    var rotations = 0;
    final controller = HostInvitationLeaseController(
      onRotationDue: () async {
        rotations += 1;
        throw StateError('stale lease');
      },
      safetyMargin: Duration.zero,
    );
    addTearDown(controller.dispose);

    controller.arm(DateTime.now().add(const Duration(milliseconds: 20)));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(rotations, 1);
    expect(controller.rotationPending, isFalse);
    expect(controller.expiresAt, isNull);
  });
}
