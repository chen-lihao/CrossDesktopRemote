import 'package:cross_desktop_remote/core/platform/desktop_window_mode.dart';
import 'package:flutter/widgets.dart';

export 'package:cross_desktop_remote/core/platform/desktop_window_mode.dart'
    show DesktopMouseDoubleClickSettings;

class DesktopMouseClickTracker {
  DesktopMouseClickTracker({
    DesktopMouseDoubleClickSettings settings =
        const DesktopMouseDoubleClickSettings(),
  }) : _settings = settings.sanitized();

  DesktopMouseDoubleClickSettings _settings;
  final Map<int, _ActiveDesktopClick> _active = {};
  _CompletedDesktopClick? _lastCompleted;

  void updateSettings(DesktopMouseDoubleClickSettings settings) {
    _settings = settings.sanitized();
    reset();
  }

  int pointerDown({
    required int pointer,
    required String button,
    required String? displayId,
    required Offset position,
    required DateTime time,
  }) {
    final previous = _lastCompleted;
    final isSecondClick =
        previous != null &&
        previous.button == button &&
        previous.displayId == displayId &&
        !time.isBefore(previous.time) &&
        time.difference(previous.time) <= _settings.interval &&
        _withinSlop(previous.position, position);
    final clickCount = isSecondClick ? 2 : 1;
    _active[pointer] = _ActiveDesktopClick(
      button: button,
      displayId: displayId,
      downPosition: position,
      clickCount: clickCount,
    );
    if (isSecondClick) _lastCompleted = null;
    return clickCount;
  }

  void pointerMove({required int pointer, required Offset position}) {
    final active = _active[pointer];
    if (active == null || active.dragged) return;
    if (!_withinSlop(active.downPosition, position)) {
      active.dragged = true;
      _lastCompleted = null;
    }
  }

  int pointerUp({
    required int pointer,
    required Offset position,
    required DateTime time,
  }) {
    final active = _active.remove(pointer);
    if (active == null) return 1;
    if (!active.dragged && _withinSlop(active.downPosition, position)) {
      if (active.clickCount == 1) {
        _lastCompleted = _CompletedDesktopClick(
          button: active.button,
          displayId: active.displayId,
          position: position,
          time: time,
        );
      } else {
        _lastCompleted = null;
      }
    } else {
      _lastCompleted = null;
    }
    return active.clickCount;
  }

  int pointerCancel(int pointer) {
    final clickCount = _active.remove(pointer)?.clickCount ?? 1;
    _lastCompleted = null;
    return clickCount;
  }

  void reset() {
    _active.clear();
    _lastCompleted = null;
  }

  bool _withinSlop(Offset first, Offset second) {
    return (first.dx - second.dx).abs() <= _settings.slop.width &&
        (first.dy - second.dy).abs() <= _settings.slop.height;
  }
}

class _ActiveDesktopClick {
  _ActiveDesktopClick({
    required this.button,
    required this.displayId,
    required this.downPosition,
    required this.clickCount,
  });

  final String button;
  final String? displayId;
  final Offset downPosition;
  final int clickCount;
  bool dragged = false;
}

class _CompletedDesktopClick {
  const _CompletedDesktopClick({
    required this.button,
    required this.displayId,
    required this.position,
    required this.time,
  });

  final String button;
  final String? displayId;
  final Offset position;
  final DateTime time;
}
