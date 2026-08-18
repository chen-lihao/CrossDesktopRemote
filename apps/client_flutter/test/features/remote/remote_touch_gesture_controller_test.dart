import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_touch_gesture_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026);

  test('direct two-finger tap produces a right click', () {
    final gestures = RemoteTouchGestureController(
      mode: RemotePointerMode.direct,
    );
    gestures.pointerDown(1, const Offset(20, 20), start);
    gestures.pointerDown(2, const Offset(40, 20), start);
    gestures.pointerUp(1, const Offset(20, 20), start);
    final actions = gestures.pointerUp(2, const Offset(40, 20), start);

    expect(actions.map((action) => action.type), [
      RemoteGestureActionType.absoluteDown,
      RemoteGestureActionType.absoluteUp,
    ]);
    expect(actions.every((action) => action.button == 'right'), isTrue);
  });

  test('direct long press defers right click until release', () {
    final gestures = RemoteTouchGestureController(
      mode: RemotePointerMode.direct,
    );
    gestures.pointerDown(1, const Offset(20, 20), start);

    final holdActions = gestures.longPress();
    final releaseActions = gestures.pointerUp(
      1,
      const Offset(20, 20),
      start.add(const Duration(milliseconds: 600)),
    );

    expect(holdActions.single.type, RemoteGestureActionType.haptic);
    expect(releaseActions.length, 2);
    expect(releaseActions.every((action) => action.button == 'right'), isTrue);
  });

  test('direct movement after long press becomes left drag', () {
    final gestures = RemoteTouchGestureController(
      mode: RemotePointerMode.direct,
    );
    gestures.pointerDown(1, const Offset(10, 10), start);
    gestures.longPress();

    final actions = gestures.pointerMove(
      1,
      const Offset(30, 10),
      const Offset(20, 0),
    );

    expect(actions.map((action) => action.type), [
      RemoteGestureActionType.absoluteDown,
      RemoteGestureActionType.absoluteMove,
    ]);
    expect(actions.every((action) => action.button == 'left'), isTrue);
  });

  test('touchpad second tap holds left button for text selection', () {
    final gestures = RemoteTouchGestureController(
      mode: RemotePointerMode.touchpad,
    );
    gestures.pointerDown(1, const Offset(20, 20), start);
    gestures.pointerUp(1, const Offset(20, 20), start);

    final downActions = gestures.pointerDown(
      2,
      const Offset(20, 20),
      start.add(const Duration(milliseconds: 100)),
    );
    final moveActions = gestures.pointerMove(
      2,
      const Offset(40, 20),
      const Offset(20, 0),
    );
    final upActions = gestures.pointerUp(
      2,
      const Offset(40, 20),
      start.add(const Duration(milliseconds: 200)),
    );

    expect(downActions.first.type, RemoteGestureActionType.relativeDown);
    expect(downActions.first.clickCount, 2);
    expect(moveActions.single.type, RemoteGestureActionType.relativeMove);
    expect(upActions.single.type, RemoteGestureActionType.relativeUp);
  });

  test('small touchpad tremor still resolves to a click', () {
    final gestures = RemoteTouchGestureController(
      mode: RemotePointerMode.touchpad,
    );
    gestures.pointerDown(1, const Offset(20, 20), start);
    gestures.pointerMove(1, const Offset(22, 21), const Offset(2, 1));

    final actions = gestures.pointerUp(
      1,
      const Offset(22, 21),
      start.add(const Duration(milliseconds: 80)),
    );

    expect(actions.map((action) => action.type), [
      RemoteGestureActionType.relativeDown,
      RemoteGestureActionType.relativeUp,
    ]);
  });

  test('drag lock emits a balanced relative down and up', () {
    final gestures = RemoteTouchGestureController(
      mode: RemotePointerMode.touchpad,
    );

    expect(
      gestures.setDragLock(true).first.type,
      RemoteGestureActionType.relativeDown,
    );
    expect(
      gestures.setDragLock(false).first.type,
      RemoteGestureActionType.relativeUp,
    );
  });
}
