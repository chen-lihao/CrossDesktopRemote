import 'package:cross_desktop_remote/features/remote/application/host_sharing_lifecycle.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('re-arms sharing after an established peer disconnects', () {
    final lifecycle = HostSharingLifecycle()..start();

    final shouldRestart = lifecycle.observeTransition(
      previous: RemoteSessionState.streaming,
      next: RemoteSessionState.disconnected,
    );

    expect(shouldRestart, isTrue);
    expect(lifecycle.sharingRequested, isTrue);
    expect(lifecycle.rearming, isTrue);
  });

  test('explicit stop never re-arms sharing', () {
    final lifecycle = HostSharingLifecycle()
      ..start()
      ..stop();

    final shouldRestart = lifecycle.observeTransition(
      previous: RemoteSessionState.streaming,
      next: RemoteSessionState.disconnected,
    );

    expect(shouldRestart, isFalse);
    expect(lifecycle.sharingRequested, isFalse);
  });

  test('an initial connection failure does not form a retry loop', () {
    final lifecycle = HostSharingLifecycle()..start();

    final shouldRestart = lifecycle.observeTransition(
      previous: RemoteSessionState.connecting,
      next: RemoteSessionState.disconnected,
    );

    expect(shouldRestart, isFalse);
    expect(lifecycle.sharingRequested, isFalse);
  });

  test('a failed re-arm returns control to the user', () {
    final lifecycle = HostSharingLifecycle()..start();
    lifecycle.observeTransition(
      previous: RemoteSessionState.streaming,
      next: RemoteSessionState.disconnected,
    );

    final shouldRestartAgain = lifecycle.observeTransition(
      previous: RemoteSessionState.connecting,
      next: RemoteSessionState.disconnected,
    );

    expect(shouldRestartAgain, isFalse);
    expect(lifecycle.sharingRequested, isFalse);
    expect(lifecycle.rearming, isFalse);
  });
}
