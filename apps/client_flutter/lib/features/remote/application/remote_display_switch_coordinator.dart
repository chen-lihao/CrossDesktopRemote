enum RemoteDisplaySwitchPhase {
  idle,
  requested,
  preparing,
  mediaReady,
  committed,
  failed,
}

class RemoteDisplaySwitchSnapshot {
  const RemoteDisplaySwitchSnapshot({
    required this.phase,
    required this.generation,
    this.targetDisplayId,
    this.inboundFramesBaseline,
    this.failureCode,
  });

  const RemoteDisplaySwitchSnapshot.idle()
    : phase = RemoteDisplaySwitchPhase.idle,
      generation = 0,
      targetDisplayId = null,
      inboundFramesBaseline = null,
      failureCode = null;

  final RemoteDisplaySwitchPhase phase;
  final int generation;
  final String? targetDisplayId;
  final int? inboundFramesBaseline;
  final String? failureCode;

  bool get pending => switch (phase) {
    RemoteDisplaySwitchPhase.requested ||
    RemoteDisplaySwitchPhase.preparing ||
    RemoteDisplaySwitchPhase.mediaReady => true,
    _ => false,
  };

  RemoteDisplaySwitchSnapshot copyWith({
    RemoteDisplaySwitchPhase? phase,
    int? generation,
    String? targetDisplayId,
    bool clearTargetDisplayId = false,
    int? inboundFramesBaseline,
    bool clearInboundFramesBaseline = false,
    String? failureCode,
    bool clearFailureCode = false,
  }) {
    return RemoteDisplaySwitchSnapshot(
      phase: phase ?? this.phase,
      generation: generation ?? this.generation,
      targetDisplayId: clearTargetDisplayId
          ? null
          : targetDisplayId ?? this.targetDisplayId,
      inboundFramesBaseline: clearInboundFramesBaseline
          ? null
          : inboundFramesBaseline ?? this.inboundFramesBaseline,
      failureCode: clearFailureCode ? null : failureCode ?? this.failureCode,
    );
  }
}

/// Owns the platform-independent display-switch transaction.
///
/// Capture APIs and renderer geometry live behind their platform adapters.
/// This coordinator only decides whether a request is current and whether
/// remote media has advanced. Geometry metadata is deliberately not part of
/// the commit contract.
class RemoteDisplaySwitchCoordinator {
  RemoteDisplaySwitchSnapshot _snapshot =
      const RemoteDisplaySwitchSnapshot.idle();
  int _lastGeneration = 0;

  RemoteDisplaySwitchSnapshot get snapshot => _snapshot;
  int get generation => _snapshot.generation;
  bool get pending => _snapshot.pending;
  String? get targetDisplayId => _snapshot.targetDisplayId;
  int? get inboundFramesBaseline => _snapshot.inboundFramesBaseline;

  int beginLocalRequest(String displayId) {
    final generation = _lastGeneration + 1;
    _lastGeneration = generation;
    _snapshot = RemoteDisplaySwitchSnapshot(
      phase: RemoteDisplaySwitchPhase.requested,
      generation: generation,
      targetDisplayId: displayId,
    );
    return generation;
  }

  bool acceptRequest({required String displayId, required int generation}) {
    if (displayId.isEmpty || (generation > 0 && generation < _lastGeneration)) {
      return false;
    }
    final effectiveGeneration = generation;
    if (_snapshot.pending &&
        effectiveGeneration == _snapshot.generation &&
        _snapshot.targetDisplayId != displayId) {
      return false;
    }
    if (effectiveGeneration > 0) _lastGeneration = effectiveGeneration;
    _snapshot = RemoteDisplaySwitchSnapshot(
      phase: RemoteDisplaySwitchPhase.requested,
      generation: effectiveGeneration,
      targetDisplayId: displayId,
    );
    return true;
  }

  bool markPreparing({
    required String displayId,
    required int generation,
    int? inboundFramesBaseline,
  }) {
    if (!_acceptCurrentOrNew(displayId: displayId, generation: generation)) {
      return false;
    }
    _snapshot = RemoteDisplaySwitchSnapshot(
      phase: RemoteDisplaySwitchPhase.preparing,
      generation: generation,
      targetDisplayId: displayId,
      inboundFramesBaseline: inboundFramesBaseline,
    );
    return true;
  }

  bool updateInboundFramesBaseline({
    required int generation,
    required int? frames,
  }) {
    if (!_matches(generation: generation)) return false;
    _snapshot = _snapshot.copyWith(
      inboundFramesBaseline: frames,
      clearInboundFramesBaseline: frames == null,
    );
    return true;
  }

  bool markMediaReady({required String displayId, required int generation}) {
    if (!_matches(displayId: displayId, generation: generation)) return false;
    _snapshot = _snapshot.copyWith(
      phase: RemoteDisplaySwitchPhase.mediaReady,
      clearFailureCode: true,
    );
    return true;
  }

  bool commit({required String displayId, required int generation}) {
    if (!_matches(displayId: displayId, generation: generation)) return false;
    _snapshot = _snapshot.copyWith(
      phase: RemoteDisplaySwitchPhase.committed,
      clearInboundFramesBaseline: true,
      clearFailureCode: true,
    );
    return true;
  }

  bool fail({required int generation, String? code}) {
    if (!_matches(generation: generation)) return false;
    _snapshot = _snapshot.copyWith(
      phase: RemoteDisplaySwitchPhase.failed,
      clearInboundFramesBaseline: true,
      failureCode: code,
    );
    return true;
  }

  bool isCurrent({required String displayId, required int generation}) {
    return _matches(displayId: displayId, generation: generation);
  }

  void reset() {
    _snapshot = const RemoteDisplaySwitchSnapshot.idle();
    _lastGeneration = 0;
  }

  static bool mediaAdvanced({
    required int? baselineFrames,
    required int? currentFrames,
    required bool hasValidFrame,
  }) {
    if (currentFrames != null) {
      return baselineFrames == null
          ? currentFrames > 0
          : currentFrames > baselineFrames;
    }
    return baselineFrames == null && hasValidFrame;
  }

  bool _acceptCurrentOrNew({
    required String displayId,
    required int generation,
  }) {
    if (displayId.isEmpty || generation < _lastGeneration) return false;
    if (generation > _lastGeneration || !_snapshot.pending) {
      _lastGeneration = generation;
      _snapshot = RemoteDisplaySwitchSnapshot(
        phase: RemoteDisplaySwitchPhase.requested,
        generation: generation,
        targetDisplayId: displayId,
      );
      return true;
    }
    return _matches(displayId: displayId, generation: generation);
  }

  bool _matches({String? displayId, required int generation}) {
    return generation == _snapshot.generation &&
        (displayId == null || displayId == _snapshot.targetDisplayId);
  }
}
