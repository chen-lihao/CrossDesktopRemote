import 'package:cross_desktop_remote/features/remote/application/remote_frame_geometry_coordinator.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  RemoteFrameGeometry geometry({
    required String displayId,
    required int generation,
  }) {
    return RemoteFrameGeometry(
      displayId: displayId,
      generation: generation,
      logicalWidth: 1920,
      logicalHeight: 1080,
      captureWidth: 1920,
      captureHeight: 1080,
      encodedWidth: 1920,
      encodedHeight: 1080,
      activeContentX: 0,
      activeContentY: 0,
      activeContentWidth: 1920,
      activeContentHeight: 1080,
    );
  }

  test('accepts late geometry after media has already committed', () {
    final coordinator = RemoteFrameGeometryCoordinator();

    expect(
      coordinator.offer(
        geometry(displayId: 'secondary', generation: 3),
        displayId: 'secondary',
        minimumGeneration: 3,
      ),
      isTrue,
    );
    expect(coordinator.current?.generation, 3);
  });

  test('ignores stale or wrong-display geometry without clearing current', () {
    final coordinator = RemoteFrameGeometryCoordinator();
    final current = geometry(displayId: 'secondary', generation: 4);
    coordinator.offer(current, displayId: 'secondary', minimumGeneration: 4);

    expect(
      coordinator.offer(
        geometry(displayId: 'secondary', generation: 3),
        displayId: 'secondary',
        minimumGeneration: 4,
      ),
      isFalse,
    );
    expect(
      coordinator.offer(
        geometry(displayId: 'primary', generation: 4),
        displayId: 'secondary',
        minimumGeneration: 4,
      ),
      isFalse,
    );
    expect(coordinator.current, same(current));
  });
}
