import 'dart:async';

/// Serializes remote input operations which mutate host-owned input state.
///
/// Keyboard events, pointer button transitions and scoped resets must reach the
/// native host in the same order in which they were received on the reliable
/// WebRTC channel. Pointer motion is intentionally excluded: it may be dropped
/// or reordered, and therefore must never mutate keyboard/button ownership.
class RemoteInputStateCoordinator {
  Future<void> _tail = Future<void>.value();
  int _generation = 0;

  int get generation => _generation;

  Future<void> enqueue(Future<void> Function() operation) {
    final completer = Completer<void>();
    final scheduledGeneration = _generation;
    _tail = _tail
        .then((_) async {
          if (scheduledGeneration != _generation) {
            completer.complete();
            return;
          }
          try {
            await operation();
            completer.complete();
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        })
        .catchError((Object _, StackTrace _) {
          // A failed operation is reported through its own completer. Keep the
          // executor alive so one native input error cannot poison later input.
        });
    return completer.future;
  }

  /// Invalidates operations which have not started. Native state is released
  /// separately by the caller using the appropriate scoped reset.
  void advanceGeneration() {
    _generation += 1;
  }
}
