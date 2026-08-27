import 'package:cross_desktop_remote/features/remote/presentation/desktop_mouse_click_tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

void main() {
  final start = DateTime(2026);

  test(
    'second physical click uses clickCount two without delaying first click',
    () {
      final tracker = DesktopMouseClickTracker();

      expect(
        tracker.pointerDown(
          pointer: 1,
          button: 'left',
          displayId: 'main',
          position: const Offset(20, 20),
          time: start,
        ),
        1,
      );
      expect(
        tracker.pointerUp(
          pointer: 1,
          position: const Offset(20, 20),
          time: start.add(const Duration(milliseconds: 20)),
        ),
        1,
      );
      expect(
        tracker.pointerDown(
          pointer: 2,
          button: 'left',
          displayId: 'main',
          position: const Offset(22, 21),
          time: start.add(const Duration(milliseconds: 120)),
        ),
        2,
      );
      expect(
        tracker.pointerUp(
          pointer: 2,
          position: const Offset(22, 21),
          time: start.add(const Duration(milliseconds: 150)),
        ),
        2,
      );
    },
  );

  test('drag, timeout, button and display changes break the click chain', () {
    final tracker = DesktopMouseClickTracker(
      settings: const DesktopMouseDoubleClickSettings(
        interval: Duration(milliseconds: 300),
        slop: Size(4, 4),
      ),
    );

    tracker.pointerDown(
      pointer: 1,
      button: 'left',
      displayId: 'main',
      position: const Offset(10, 10),
      time: start,
    );
    tracker.pointerMove(pointer: 1, position: const Offset(30, 10));
    tracker.pointerUp(
      pointer: 1,
      position: const Offset(30, 10),
      time: start.add(const Duration(milliseconds: 20)),
    );
    expect(
      tracker.pointerDown(
        pointer: 2,
        button: 'left',
        displayId: 'main',
        position: const Offset(30, 10),
        time: start.add(const Duration(milliseconds: 100)),
      ),
      1,
    );
    tracker.pointerCancel(2);

    tracker.pointerDown(
      pointer: 3,
      button: 'left',
      displayId: 'main',
      position: const Offset(10, 10),
      time: start.add(const Duration(milliseconds: 200)),
    );
    tracker.pointerUp(
      pointer: 3,
      position: const Offset(10, 10),
      time: start.add(const Duration(milliseconds: 220)),
    );
    expect(
      tracker.pointerDown(
        pointer: 4,
        button: 'right',
        displayId: 'main',
        position: const Offset(10, 10),
        time: start.add(const Duration(milliseconds: 250)),
      ),
      1,
    );
    tracker.pointerCancel(4);

    tracker.pointerDown(
      pointer: 5,
      button: 'left',
      displayId: 'main',
      position: const Offset(10, 10),
      time: start.add(const Duration(milliseconds: 300)),
    );
    tracker.pointerUp(
      pointer: 5,
      position: const Offset(10, 10),
      time: start.add(const Duration(milliseconds: 320)),
    );
    expect(
      tracker.pointerDown(
        pointer: 6,
        button: 'left',
        displayId: 'side',
        position: const Offset(10, 10),
        time: start.add(const Duration(milliseconds: 350)),
      ),
      1,
    );
    tracker.pointerCancel(6);

    tracker.pointerDown(
      pointer: 7,
      button: 'left',
      displayId: 'main',
      position: const Offset(10, 10),
      time: start.add(const Duration(milliseconds: 400)),
    );
    tracker.pointerUp(
      pointer: 7,
      position: const Offset(10, 10),
      time: start.add(const Duration(milliseconds: 420)),
    );
    expect(
      tracker.pointerDown(
        pointer: 8,
        button: 'left',
        displayId: 'main',
        position: const Offset(10, 10),
        time: start.add(const Duration(milliseconds: 800)),
      ),
      1,
    );
  });
}
