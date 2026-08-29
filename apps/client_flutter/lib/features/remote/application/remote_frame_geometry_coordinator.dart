import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';

/// Commits presentation geometry independently from the display media switch.
///
/// Missing, invalid, late, or stale geometry is ignored. None of those cases
/// can reject or roll back a healthy display-switch transaction.
class RemoteFrameGeometryCoordinator {
  RemoteFrameGeometry? _current;

  RemoteFrameGeometry? get current => _current;

  bool offer(
    RemoteFrameGeometry? geometry, {
    required String? displayId,
    required int minimumGeneration,
  }) {
    if (geometry == null ||
        !geometry.isValid ||
        geometry.displayId != displayId ||
        (minimumGeneration > 0 && geometry.generation < minimumGeneration)) {
      return false;
    }
    final current = _current;
    if (current != null &&
        current.displayId == geometry.displayId &&
        current.generation > geometry.generation) {
      return false;
    }
    _current = geometry;
    return true;
  }

  void clear() => _current = null;
}
