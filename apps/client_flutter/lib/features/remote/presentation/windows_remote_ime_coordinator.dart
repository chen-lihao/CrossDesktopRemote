import 'package:cross_desktop_remote/features/remote/presentation/remote_keyboard_translator.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_text_input_synchronizer.dart';
import 'package:flutter/services.dart';

enum DesktopRemoteImePhase { idle, composing }

/// Keeps desktop IME composition local and decides which physical keys must
/// bypass the text client and be sent to the remote host.
///
/// The coordinator contains no platform calls so its composition and routing
/// rules can be regression-tested on every development host.
class DesktopRemoteImeCoordinator {
  DesktopRemoteImeCoordinator({RemoteTextInputSynchronizer? synchronizer})
    : _synchronizer = synchronizer ?? RemoteTextInputSynchronizer();

  final RemoteTextInputSynchronizer _synchronizer;
  DesktopRemoteImePhase _phase = DesktopRemoteImePhase.idle;
  int _compositionLength = 0;

  DesktopRemoteImePhase get phase => _phase;
  bool get isComposing => _phase == DesktopRemoteImePhase.composing;
  int get compositionLength => _compositionLength;

  RemoteTextEdit update(TextEditingValue value) {
    final composing = value.composing;
    final active = composing.isValid && !composing.isCollapsed;
    _phase = active
        ? DesktopRemoteImePhase.composing
        : DesktopRemoteImePhase.idle;
    _compositionLength = active ? composing.end - composing.start : 0;
    return _synchronizer.update(value);
  }

  /// Returns true only for a key that should bypass the local IME.
  ///
  /// While composition is active every key stays local so candidate selection,
  /// cancellation and editing remain owned by Microsoft Pinyin. Outside a
  /// composition, shortcuts and non-text navigation keys use the reliable
  /// remote physical-key channel. A previously routed key must also receive
  /// its KeyUp even if the modifier was released first.
  bool shouldRouteToRemote(
    KeyEvent event, {
    required bool shortcutPressed,
    bool remoteKeyIsPressed = false,
  }) {
    if (isComposing) return false;
    if (event is KeyUpEvent && remoteKeyIsPressed) return true;
    if (shortcutPressed) return remoteKeyName(event.logicalKey) != null;
    return _remoteNavigationKeys.contains(event.logicalKey);
  }

  /// A remote caret-moving/editing key invalidates the local append-only
  /// baseline. Resetting before its KeyDown prevents a later text commit from
  /// generating deletion events against stale local text.
  bool shouldResetBufferBefore(KeyEvent event) =>
      event is KeyDownEvent && _remoteNavigationKeys.contains(event.logicalKey);

  bool shouldCompact({int maximumGraphemes = 80}) =>
      _synchronizer.shouldCompact(maximumGraphemes: maximumGraphemes);

  void reset() {
    _phase = DesktopRemoteImePhase.idle;
    _compositionLength = 0;
    _synchronizer.reset();
  }
}

final Set<LogicalKeyboardKey> _remoteNavigationKeys = {
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.backspace,
  LogicalKeyboardKey.delete,
  LogicalKeyboardKey.tab,
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.home,
  LogicalKeyboardKey.end,
  LogicalKeyboardKey.pageUp,
  LogicalKeyboardKey.pageDown,
  LogicalKeyboardKey.f1,
  LogicalKeyboardKey.f2,
  LogicalKeyboardKey.f3,
  LogicalKeyboardKey.f4,
  LogicalKeyboardKey.f5,
  LogicalKeyboardKey.f6,
  LogicalKeyboardKey.f7,
  LogicalKeyboardKey.f8,
  LogicalKeyboardKey.f9,
  LogicalKeyboardKey.f10,
  LogicalKeyboardKey.f11,
  LogicalKeyboardKey.f12,
};
