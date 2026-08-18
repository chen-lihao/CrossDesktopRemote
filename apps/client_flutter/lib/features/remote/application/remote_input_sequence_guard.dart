class RemoteInputSequenceGuard {
  int _lastStateSequence = 0;
  int _lastMotionSequence = 0;

  bool accept(int sequence, {required bool motion}) {
    final lastSequence = motion ? _lastMotionSequence : _lastStateSequence;
    if (sequence <= lastSequence) return false;
    if (motion) {
      _lastMotionSequence = sequence;
    } else {
      _lastStateSequence = sequence;
    }
    return true;
  }

  void reset() {
    _lastStateSequence = 0;
    _lastMotionSequence = 0;
  }
}
