import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:flutter/painting.dart';

enum RemoteGestureActionType {
  absoluteDown,
  absoluteMove,
  absoluteUp,
  relativeDown,
  relativeMove,
  relativeUp,
  scroll,
  haptic,
}

class RemoteGestureAction {
  const RemoteGestureAction(
    this.type, {
    this.position,
    this.delta = Offset.zero,
    this.button = 'left',
    this.clickCount = 1,
  });

  final RemoteGestureActionType type;
  final Offset? position;
  final Offset delta;
  final String button;
  final int clickCount;
}

/// Interprets touch input without depending on a remote session or viewport.
class RemoteTouchGestureController {
  factory RemoteTouchGestureController({
    required RemotePointerMode mode,
    double pointerSensitivity = 1.25,
    double scrollSensitivity = 2,
  }) => RemoteTouchGestureController._(
    mode,
    pointerSensitivity,
    scrollSensitivity,
  );

  RemoteTouchGestureController._(
    this._mode,
    this._pointerSensitivity,
    this._scrollSensitivity,
  );

  static const _dragThreshold = 7.0;
  static const _multiTouchThreshold = 3.0;
  static const _doubleTapDuration = Duration(milliseconds: 350);
  static const _doubleTapDistance = 28.0;

  RemotePointerMode _mode;
  double _pointerSensitivity;
  double _scrollSensitivity;
  final Map<int, Offset> _pointers = {};
  int? _primaryPointer;
  Offset? _downPosition;
  bool _multiTouch = false;
  double _multiTouchTravel = 0;
  bool _directDragging = false;
  bool _directLongPress = false;
  bool _directSecondTapDown = false;
  bool _trackpadMoved = false;
  double _trackpadTravel = 0;
  bool _trackpadSecondTapDown = false;
  bool _dragLock = false;
  DateTime? _lastDirectTapTime;
  Offset? _lastDirectTapPosition;
  DateTime? _lastTrackpadTapTime;
  Offset? _lastTrackpadTapPosition;

  bool get dragLock => _dragLock;

  List<RemoteGestureAction> updateConfiguration({
    required RemotePointerMode mode,
    required double pointerSensitivity,
    required double scrollSensitivity,
    required bool dragLock,
  }) {
    final actions = <RemoteGestureAction>[];
    if (mode != _mode) {
      actions.addAll(cancelAll(releaseDragLock: true));
      _mode = mode;
    }
    _pointerSensitivity = pointerSensitivity;
    _scrollSensitivity = scrollSensitivity;
    if (_mode != RemotePointerMode.touchpad) {
      dragLock = false;
    }
    actions.addAll(setDragLock(dragLock));
    return actions;
  }

  List<RemoteGestureAction> setDragLock(bool enabled) {
    if (_dragLock == enabled) return const [];
    _dragLock = enabled;
    return [
      RemoteGestureAction(
        enabled
            ? RemoteGestureActionType.relativeDown
            : RemoteGestureActionType.relativeUp,
      ),
      const RemoteGestureAction(RemoteGestureActionType.haptic),
    ];
  }

  List<RemoteGestureAction> pointerDown(
    int pointer,
    Offset position,
    DateTime time,
  ) {
    _pointers[pointer] = position;
    if (_primaryPointer == null) {
      _primaryPointer = pointer;
      _downPosition = position;
      if (_mode == RemotePointerMode.direct &&
          _isDoubleTap(
            time,
            position,
            _lastDirectTapTime,
            _lastDirectTapPosition,
          )) {
        _directSecondTapDown = true;
        _lastDirectTapTime = null;
        _lastDirectTapPosition = null;
        return [
          RemoteGestureAction(
            RemoteGestureActionType.absoluteDown,
            position: position,
            clickCount: 2,
          ),
          const RemoteGestureAction(RemoteGestureActionType.haptic),
        ];
      }
      if (_mode == RemotePointerMode.touchpad &&
          !_dragLock &&
          _isDoubleTap(
            time,
            position,
            _lastTrackpadTapTime,
            _lastTrackpadTapPosition,
          )) {
        _trackpadSecondTapDown = true;
        _lastTrackpadTapTime = null;
        _lastTrackpadTapPosition = null;
        return const [
          RemoteGestureAction(
            RemoteGestureActionType.relativeDown,
            clickCount: 2,
          ),
          RemoteGestureAction(RemoteGestureActionType.haptic),
        ];
      }
      return const [];
    }

    _multiTouch = true;
    if (_directSecondTapDown) {
      _directSecondTapDown = false;
      return [
        RemoteGestureAction(
          RemoteGestureActionType.absoluteUp,
          position: _downPosition,
          clickCount: 2,
        ),
      ];
    }
    if (_trackpadSecondTapDown) {
      _trackpadSecondTapDown = false;
      return const [
        RemoteGestureAction(RemoteGestureActionType.relativeUp, clickCount: 2),
      ];
    }
    return const [];
  }

  List<RemoteGestureAction> pointerMove(
    int pointer,
    Offset position,
    Offset delta,
  ) {
    if (!_pointers.containsKey(pointer)) return const [];
    _pointers[pointer] = position;

    if (_multiTouch) {
      _multiTouchTravel += delta.distance;
      if (_multiTouchTravel < _multiTouchThreshold) return const [];
      return [
        RemoteGestureAction(
          RemoteGestureActionType.scroll,
          position: _mode == RemotePointerMode.direct ? position : null,
          delta: Offset(
            -delta.dx * _scrollSensitivity,
            -delta.dy * _scrollSensitivity,
          ),
        ),
      ];
    }

    if (_mode == RemotePointerMode.touchpad) {
      _trackpadTravel += delta.distance;
      if (_trackpadTravel >= _dragThreshold) _trackpadMoved = true;
      return [
        RemoteGestureAction(
          RemoteGestureActionType.relativeMove,
          delta: delta * _pointerSensitivity,
        ),
      ];
    }

    if (pointer != _primaryPointer || _downPosition == null) return const [];
    final actions = <RemoteGestureAction>[];
    if (!_directDragging &&
        !_directSecondTapDown &&
        (position - _downPosition!).distance >= _dragThreshold) {
      _directLongPress = false;
      _directDragging = true;
      actions.add(
        RemoteGestureAction(
          RemoteGestureActionType.absoluteDown,
          position: _downPosition,
        ),
      );
    }
    if (_directDragging || _directSecondTapDown) {
      actions.add(
        RemoteGestureAction(
          RemoteGestureActionType.absoluteMove,
          position: position,
        ),
      );
    }
    return actions;
  }

  List<RemoteGestureAction> pointerUp(
    int pointer,
    Offset position,
    DateTime time,
  ) {
    if (!_pointers.containsKey(pointer)) return const [];
    _pointers.remove(pointer);

    if (_multiTouch) {
      if (_pointers.isNotEmpty) return const [];
      final actions = <RemoteGestureAction>[];
      if (_multiTouchTravel < _multiTouchThreshold) {
        if (_mode == RemotePointerMode.direct) {
          actions.addAll([
            RemoteGestureAction(
              RemoteGestureActionType.absoluteDown,
              position: _downPosition ?? position,
              button: 'right',
            ),
            RemoteGestureAction(
              RemoteGestureActionType.absoluteUp,
              position: _downPosition ?? position,
              button: 'right',
            ),
          ]);
        } else {
          actions.addAll(const [
            RemoteGestureAction(
              RemoteGestureActionType.relativeDown,
              button: 'right',
            ),
            RemoteGestureAction(
              RemoteGestureActionType.relativeUp,
              button: 'right',
            ),
          ]);
        }
      }
      _resetActiveGesture();
      return actions;
    }

    if (pointer != _primaryPointer) return const [];
    final actions = <RemoteGestureAction>[];
    if (_mode == RemotePointerMode.direct) {
      if (_directSecondTapDown) {
        actions.add(
          RemoteGestureAction(
            RemoteGestureActionType.absoluteUp,
            position: position,
            clickCount: 2,
          ),
        );
      } else if (_directDragging) {
        actions.add(
          RemoteGestureAction(
            RemoteGestureActionType.absoluteUp,
            position: position,
          ),
        );
      } else if (_directLongPress) {
        actions.addAll([
          RemoteGestureAction(
            RemoteGestureActionType.absoluteDown,
            position: position,
            button: 'right',
          ),
          RemoteGestureAction(
            RemoteGestureActionType.absoluteUp,
            position: position,
            button: 'right',
          ),
        ]);
      } else {
        actions.addAll([
          RemoteGestureAction(
            RemoteGestureActionType.absoluteDown,
            position: position,
          ),
          RemoteGestureAction(
            RemoteGestureActionType.absoluteUp,
            position: position,
          ),
        ]);
        _lastDirectTapTime = time;
        _lastDirectTapPosition = position;
      }
    } else if (_trackpadSecondTapDown) {
      actions.add(
        const RemoteGestureAction(
          RemoteGestureActionType.relativeUp,
          clickCount: 2,
        ),
      );
    } else if (!_trackpadMoved && !_dragLock) {
      actions.addAll(const [
        RemoteGestureAction(RemoteGestureActionType.relativeDown),
        RemoteGestureAction(RemoteGestureActionType.relativeUp),
      ]);
      _lastTrackpadTapTime = time;
      _lastTrackpadTapPosition = position;
    }
    _resetActiveGesture();
    return actions;
  }

  List<RemoteGestureAction> longPress() {
    if (_mode != RemotePointerMode.direct ||
        _primaryPointer == null ||
        _multiTouch ||
        _directDragging ||
        _directSecondTapDown) {
      return const [];
    }
    _directLongPress = true;
    return const [RemoteGestureAction(RemoteGestureActionType.haptic)];
  }

  List<RemoteGestureAction> pointerCancel(int pointer, Offset position) {
    if (!_pointers.containsKey(pointer)) return const [];
    final actions = <RemoteGestureAction>[];
    if (pointer == _primaryPointer) {
      if (_directDragging || _directSecondTapDown) {
        actions.add(
          RemoteGestureAction(
            RemoteGestureActionType.absoluteUp,
            position: position,
            clickCount: _directSecondTapDown ? 2 : 1,
          ),
        );
      }
      if (_trackpadSecondTapDown) {
        actions.add(
          const RemoteGestureAction(RemoteGestureActionType.relativeUp),
        );
      }
    }
    _pointers.remove(pointer);
    if (_pointers.isEmpty) _resetActiveGesture();
    return actions;
  }

  List<RemoteGestureAction> cancelAll({bool releaseDragLock = false}) {
    final actions = <RemoteGestureAction>[];
    if (_directDragging || _directSecondTapDown) {
      actions.add(
        RemoteGestureAction(
          RemoteGestureActionType.absoluteUp,
          position: _pointers[_primaryPointer] ?? _downPosition,
          clickCount: _directSecondTapDown ? 2 : 1,
        ),
      );
    }
    if (_trackpadSecondTapDown || (releaseDragLock && _dragLock)) {
      actions.add(
        const RemoteGestureAction(RemoteGestureActionType.relativeUp),
      );
    }
    if (releaseDragLock) _dragLock = false;
    _pointers.clear();
    _resetActiveGesture();
    return actions;
  }

  bool _isDoubleTap(
    DateTime time,
    Offset position,
    DateTime? previousTime,
    Offset? previousPosition,
  ) =>
      previousTime != null &&
      time.difference(previousTime) <= _doubleTapDuration &&
      previousPosition != null &&
      (position - previousPosition).distance <= _doubleTapDistance;

  void _resetActiveGesture() {
    _primaryPointer = null;
    _downPosition = null;
    _multiTouch = false;
    _multiTouchTravel = 0;
    _directDragging = false;
    _directLongPress = false;
    _directSecondTapDown = false;
    _trackpadMoved = false;
    _trackpadTravel = 0;
    _trackpadSecondTapDown = false;
  }
}
