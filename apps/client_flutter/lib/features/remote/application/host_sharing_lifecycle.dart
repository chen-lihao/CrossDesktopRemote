import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';

/// Keeps the user's host-sharing intent separate from one WebRTC session.
///
/// A completed session may be re-armed automatically. Initial connection
/// failures and failures while re-arming deliberately stop instead of forming
/// an unbounded reconnect loop.
class HostSharingLifecycle {
  bool _sharingRequested = false;
  bool _rearming = false;

  bool get sharingRequested => _sharingRequested;
  bool get rearming => _rearming;

  void start() {
    _sharingRequested = true;
    _rearming = false;
  }

  void stop() {
    _sharingRequested = false;
    _rearming = false;
  }

  bool observeTransition({
    required RemoteSessionState previous,
    required RemoteSessionState next,
  }) {
    if (!_sharingRequested) return false;

    if (next == RemoteSessionState.waitingForPeer) {
      _rearming = false;
      return false;
    }

    if (next == RemoteSessionState.failed) {
      stop();
      return false;
    }

    if (next != RemoteSessionState.disconnected) return false;

    if (!_rearming && previous == RemoteSessionState.streaming) {
      _rearming = true;
      return true;
    }

    // A disconnect before streaming, or another disconnect while re-arming,
    // needs explicit user action and must not retry forever.
    stop();
    return false;
  }
}
