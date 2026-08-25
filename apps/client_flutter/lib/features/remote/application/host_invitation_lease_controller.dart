import 'dart:async';

import 'package:flutter/foundation.dart';

typedef HostInvitationRotation = Future<void> Function();

/// Owns the expiry timer for one host invitation without coupling it to the
/// WebRTC session lifecycle.
class HostInvitationLeaseController extends ChangeNotifier {
  HostInvitationLeaseController({
    required this.onRotationDue,
    DateTime Function()? now,
    this.safetyMargin = const Duration(seconds: 2),
  }) : _now = now ?? DateTime.now;

  final HostInvitationRotation onRotationDue;
  final DateTime Function() _now;
  final Duration safetyMargin;

  Timer? _rotationTimer;
  Timer? _countdownTimer;
  DateTime? _expiresAt;
  bool _rotationPending = false;

  DateTime? get expiresAt => _expiresAt;
  bool get rotationPending => _rotationPending;

  Duration? get remaining {
    final expiresAt = _expiresAt;
    if (expiresAt == null) return null;
    final value = expiresAt.difference(_now());
    return value.isNegative ? Duration.zero : value;
  }

  String get statusLabel {
    if (_rotationPending) return '正在生成并注册新连接码';
    final value = remaining;
    if (value == null) return '开始共享后连接码有效 5 分钟';
    final totalSeconds = value.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '剩余 ${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')} 后自动更新';
  }

  void arm(DateTime expiresAt) {
    if (_expiresAt == expiresAt && _rotationTimer?.isActive == true) return;
    _cancelTimers();
    _expiresAt = expiresAt;
    _rotationPending = false;
    final delay = expiresAt.difference(_now()) - safetyMargin;
    _rotationTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(rotateNow()),
    );
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => notifyListeners(),
    );
    notifyListeners();
  }

  Future<void> rotateNow() async {
    if (_rotationPending) return;
    final previousExpiry = _expiresAt;
    _rotationPending = true;
    _cancelTimers();
    notifyListeners();
    try {
      await onRotationDue();
    } finally {
      _rotationPending = false;
      if (_expiresAt == previousExpiry) {
        _expiresAt = null;
      }
      notifyListeners();
    }
  }

  void cancel() {
    final changed = _expiresAt != null || _rotationPending;
    _cancelTimers();
    _expiresAt = null;
    _rotationPending = false;
    if (changed) notifyListeners();
  }

  void _cancelTimers() {
    _rotationTimer?.cancel();
    _rotationTimer = null;
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }
}
