import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';

/// Keeps the user's host-sharing intent separate from one WebRTC session.
///
/// A completed session may be re-armed automatically. Initial connection
/// failures and failures while re-arming deliberately stop instead of forming
/// an unbounded reconnect loop.
class HostSharingLifecycle {
  bool _sharingRequested = false;
  bool _rearming = false;
  bool _hadStreamingSession = false;
  bool _invitationWasConsumed = false;

  bool get sharingRequested => _sharingRequested;
  bool get rearming => _rearming;

  void start() {
    _sharingRequested = true;
    _rearming = false;
    _hadStreamingSession = false;
    _invitationWasConsumed = false;
  }

  void stop() {
    _sharingRequested = false;
    _rearming = false;
    _hadStreamingSession = false;
    _invitationWasConsumed = false;
  }

  bool observeTransition({
    required RemoteSessionState previous,
    required RemoteSessionState next,
  }) {
    if (!_sharingRequested) return false;

    if (previous == RemoteSessionState.streaming ||
        next == RemoteSessionState.streaming) {
      _hadStreamingSession = true;
    }

    // A controller consumes the one-time invitation before WebRTC reaches
    // streaming. If capture/SDP then fails, that code must still be replaced
    // automatically instead of leaving sharing stopped with an unusable code.
    if (previous == RemoteSessionState.waitingForPeer &&
        next == RemoteSessionState.connecting) {
      _invitationWasConsumed = true;
    }

    if (next == RemoteSessionState.waitingForPeer) {
      _rearming = false;
      _hadStreamingSession = false;
      _invitationWasConsumed = false;
      return false;
    }

    final terminal =
        next == RemoteSessionState.disconnected ||
        next == RemoteSessionState.failed;
    if (!terminal) return false;

    if (!_rearming && (_hadStreamingSession || _invitationWasConsumed)) {
      _rearming = true;
      return true;
    }

    // A disconnect before streaming, or another disconnect while re-arming,
    // needs explicit user action and must not retry forever.
    stop();
    return false;
  }
}
