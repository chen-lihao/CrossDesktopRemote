import 'dart:async';

import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/features/remote/application/host_invitation_lease_controller.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:flutter/foundation.dart';

typedef SignalingServerUrlProvider = String Function();

/// Keeps a host-capable device registered independently from outgoing remote
/// control sessions. Media capture still starts only after the server consumes
/// a valid invitation code.
class HostAvailabilityController extends ChangeNotifier {
  HostAvailabilityController({
    required this.session,
    required this.serverUrl,
    this.reconnectDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
  }) : invitationLease = HostInvitationLeaseController(
         onRotationDue: () async {},
       ) {
    // The lease callback needs this fully constructed instance.
    invitationLease.onRotationDue = rotateInvitation;
    session.addListener(_handleSessionChanged);
    invitationLease.addListener(_forwardChange);
    _lastState = session.state;
  }

  final RemoteSessionController session;
  final SignalingServerUrlProvider serverUrl;
  final List<Duration> reconnectDelays;
  final HostInvitationLeaseController invitationLease;

  late RemoteSessionState _lastState;
  Timer? _reconnectTimer;
  Timer? _serverReconfigureTimer;
  bool _desiredOnline = true;
  bool _starting = false;
  bool _reconfiguring = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  String? _connectedEndpoint;

  bool get desiredOnline => _desiredOnline;
  bool get starting => _starting;
  bool get reconfiguring => _reconfiguring;
  bool get reconnecting => _reconnectTimer?.isActive == true;
  bool get available => session.state == RemoteSessionState.waitingForPeer;
  bool get busy => {
    RemoteSessionState.connecting,
    RemoteSessionState.streaming,
    RemoteSessionState.reconnecting,
  }.contains(session.state);

  Future<void> initialize() async {
    await session.initialize();
    if (_desiredOnline) await ensureOnline();
  }

  Future<void> ensureOnline() async {
    if (_disposed || !_desiredOnline || _starting) return;
    if (!{
      RemoteSessionState.idle,
      RemoteSessionState.disconnected,
      RemoteSessionState.failed,
    }.contains(session.state)) {
      return;
    }
    final endpoint = serverUrl().trim();
    if (endpoint.isEmpty) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      return;
    }
    _reconnectTimer?.cancel();
    _starting = true;
    notifyListeners();
    try {
      await session.connect(
        serverUrl: endpoint,
        roomCode: '',
        announceLifecycle: false,
      );
      if (session.state != RemoteSessionState.failed) {
        _connectedEndpoint = endpoint;
      }
    } finally {
      _starting = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Applies a changed signaling endpoint without reconnecting for every
  /// keystroke in the settings field. An active remote-control session keeps
  /// its current endpoint and applies the new one after disconnecting.
  void reconcileServerConfiguration() {
    if (_disposed || !_desiredOnline) return;
    final endpoint = serverUrl().trim();
    if (endpoint == _connectedEndpoint) return;
    // A server URL is edited character by character. Restart the timer for
    // every change so a partial URL can never disconnect a healthy host.
    _serverReconfigureTimer?.cancel();
    _serverReconfigureTimer = Timer(const Duration(milliseconds: 700), () {
      unawaited(_applyServerConfiguration());
    });
  }

  Future<void> _applyServerConfiguration() async {
    _serverReconfigureTimer?.cancel();
    _serverReconfigureTimer = null;
    if (_disposed || !_desiredOnline) return;
    final endpoint = serverUrl().trim();
    if (endpoint == _connectedEndpoint) return;
    if (endpoint.isNotEmpty) {
      try {
        normalizeSignalingServerUrl(endpoint);
      } on FormatException {
        // Keep the existing registration while the field contains a partial
        // or invalid URL. A later valid edit schedules another transaction.
        return;
      }
    }
    if ({
      RemoteSessionState.connecting,
      RemoteSessionState.awaitingApproval,
      RemoteSessionState.streaming,
      RemoteSessionState.reconnecting,
    }.contains(session.state)) {
      return;
    }
    _reconfiguring = true;
    notifyListeners();
    try {
      if (!{
        RemoteSessionState.idle,
        RemoteSessionState.disconnected,
        RemoteSessionState.failed,
      }.contains(session.state)) {
        await session.disconnect();
      }
      _connectedEndpoint = null;
      _reconnectAttempt = 0;
      if (endpoint.isNotEmpty) await ensureOnline();
    } finally {
      _reconfiguring = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> rotateInvitation() async {
    if (!available) return;
    try {
      await session.rotateHostInvitation();
    } catch (_) {
      // A stale or expired lease cannot be reused. Re-register the host to
      // obtain a fresh one instead of leaving an apparently valid dead code.
      await session.disconnect();
      _connectedEndpoint = null;
      await ensureOnline();
      rethrow;
    }
  }

  Future<void> setIncomingAccessEnabled(bool enabled) async {
    if (_desiredOnline == enabled) return;
    _desiredOnline = enabled;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _serverReconfigureTimer?.cancel();
    _serverReconfigureTimer = null;
    if (enabled) {
      _reconnectAttempt = 0;
      await ensureOnline();
    } else {
      invitationLease.cancel();
      await session.disconnect();
    }
    notifyListeners();
  }

  void _handleSessionChanged() {
    final previous = _lastState;
    final next = session.state;
    _lastState = next;
    if (next == RemoteSessionState.waitingForPeer) {
      _reconnectAttempt = 0;
      final expiresAt = session.hostInvitationExpiresAt;
      if (expiresAt != null) {
        invitationLease.arm(
          expiresAt,
          serverAuthoritative: session.supportsServerInvitationPush,
        );
      }
    } else if (!invitationLease.rotationPending) {
      invitationLease.cancel();
    }

    if ({
      RemoteSessionState.disconnected,
      RemoteSessionState.failed,
    }.contains(next)) {
      _connectedEndpoint = null;
    }

    if (_desiredOnline &&
        {
          RemoteSessionState.disconnected,
          RemoteSessionState.failed,
        }.contains(next)) {
      final hadPeer = {
        RemoteSessionState.connecting,
        RemoteSessionState.streaming,
        RemoteSessionState.reconnecting,
      }.contains(previous);
      _scheduleReconnect(immediate: hadPeer);
    }
    notifyListeners();
  }

  void _scheduleReconnect({bool immediate = false}) {
    if (_disposed || !_desiredOnline || _reconnectTimer?.isActive == true) {
      return;
    }
    final delay = immediate
        ? const Duration(milliseconds: 300)
        : reconnectDelays[_reconnectAttempt.clamp(
            0,
            reconnectDelays.length - 1,
          )];
    if (!immediate && _reconnectAttempt < reconnectDelays.length - 1) {
      _reconnectAttempt += 1;
    }
    _reconnectTimer = Timer(delay, () => unawaited(ensureOnline()));
    notifyListeners();
  }

  void _forwardChange() => notifyListeners();

  String get statusLabel {
    if (!_desiredOnline) return '已暂停接收远程连接';
    if (serverUrl().trim().isEmpty) return '请先配置信令服务器';
    if (_starting) return '正在连接信令服务';
    if (_reconfiguring) return '正在切换信令服务器';
    if (reconnecting) return '信令连接中断，正在自动恢复';
    if (session.hostInvitationState == HostInvitationState.consumed) {
      return '本次连接码已使用；会话断开后自动生成新码';
    }
    return invitationLease.statusLabel;
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _serverReconfigureTimer?.cancel();
    session.removeListener(_handleSessionChanged);
    invitationLease
      ..removeListener(_forwardChange)
      ..dispose();
    super.dispose();
  }
}
