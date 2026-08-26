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

  test('does not re-arm sharing during a transient connection recovery', () {
    final lifecycle = HostSharingLifecycle()..start();

    expect(
      lifecycle.observeTransition(
        previous: RemoteSessionState.streaming,
        next: RemoteSessionState.reconnecting,
      ),
      isFalse,
    );
    expect(lifecycle.sharingRequested, isTrue);
    expect(lifecycle.rearming, isFalse);

    expect(
      lifecycle.observeTransition(
        previous: RemoteSessionState.reconnecting,
        next: RemoteSessionState.streaming,
      ),
      isFalse,
    );
    expect(lifecycle.sharingRequested, isTrue);
    expect(lifecycle.rearming, isFalse);
  });

  test('re-arms after a recovery window ends in a terminal disconnect', () {
    final lifecycle = HostSharingLifecycle()..start();
    lifecycle.observeTransition(
      previous: RemoteSessionState.streaming,
      next: RemoteSessionState.reconnecting,
    );

    final shouldRestart = lifecycle.observeTransition(
      previous: RemoteSessionState.reconnecting,
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

  test('re-arms when a consumed code fails before media starts', () {
    final lifecycle = HostSharingLifecycle()..start();
    expect(
      lifecycle.observeTransition(
        previous: RemoteSessionState.waitingForPeer,
        next: RemoteSessionState.connecting,
      ),
      isFalse,
    );

    final shouldRestart = lifecycle.observeTransition(
      previous: RemoteSessionState.connecting,
      next: RemoteSessionState.disconnected,
    );

    expect(shouldRestart, isTrue);
    expect(lifecycle.sharingRequested, isTrue);
    expect(lifecycle.rearming, isTrue);
  });

  test('re-arms when host capture fails after consuming the code', () {
    final lifecycle = HostSharingLifecycle()..start();
    lifecycle.observeTransition(
      previous: RemoteSessionState.waitingForPeer,
      next: RemoteSessionState.connecting,
    );

    final shouldRestart = lifecycle.observeTransition(
      previous: RemoteSessionState.connecting,
      next: RemoteSessionState.failed,
    );

    expect(shouldRestart, isTrue);
    expect(lifecycle.sharingRequested, isTrue);
    expect(lifecycle.rearming, isTrue);
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
