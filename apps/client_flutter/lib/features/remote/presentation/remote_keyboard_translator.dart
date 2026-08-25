import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum RemoteKeyboardActionType { key, text }

@immutable
class RemoteKeyboardAction {
  const RemoteKeyboardAction.key({
    required this.phase,
    required this.key,
    required this.physicalHidUsage,
    required this.modifiers,
    this.repeat = false,
  }) : type = RemoteKeyboardActionType.key,
       text = null;

  const RemoteKeyboardAction.text(this.text)
    : type = RemoteKeyboardActionType.text,
      phase = null,
      key = null,
      physicalHidUsage = null,
      modifiers = const [],
      repeat = false;

  final RemoteKeyboardActionType type;
  final String? phase;
  final String? key;
  final int? physicalHidUsage;
  final List<String> modifiers;
  final bool repeat;
  final String? text;
}

class RemoteKeyboardTranslator {
  final Map<PhysicalKeyboardKey, _PressedRemoteKey> _pressed = {};

  bool isPressed(PhysicalKeyboardKey key) => _pressed.containsKey(key);

  List<RemoteKeyboardAction> translate(
    KeyEvent event, {
    required List<String> modifiers,
  }) {
    if (event is KeyUpEvent) {
      final pressed = _pressed.remove(event.physicalKey);
      if (pressed == null) return const [];
      return [
        RemoteKeyboardAction.key(
          phase: 'up',
          key: pressed.key,
          physicalHidUsage: pressed.physicalHidUsage,
          modifiers: modifiers,
        ),
      ];
    }

    final key = remoteKeyName(event.logicalKey);
    final character = event.character;
    final shortcut = modifiers.any(
      const {'command', 'control', 'option'}.contains,
    );
    final requiresPhysicalKey =
        key != null && (shortcut || character == null || character.isEmpty);

    if (requiresPhysicalKey) {
      final physicalHidUsage = event.physicalKey.usbHidUsage;
      if (event is KeyDownEvent) {
        _pressed[event.physicalKey] = _PressedRemoteKey(
          key: key,
          physicalHidUsage: physicalHidUsage,
        );
      }
      return [
        RemoteKeyboardAction.key(
          phase: 'down',
          key: key,
          physicalHidUsage: physicalHidUsage,
          modifiers: modifiers,
          repeat: event is KeyRepeatEvent,
        ),
      ];
    }

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (character != null && character.isNotEmpty) {
        return [RemoteKeyboardAction.text(character)];
      }
    }
    return const [];
  }

  List<RemoteKeyboardAction> releaseAll({List<String> modifiers = const []}) {
    final actions = [
      for (final pressed in _pressed.values)
        RemoteKeyboardAction.key(
          phase: 'up',
          key: pressed.key,
          physicalHidUsage: pressed.physicalHidUsage,
          modifiers: modifiers,
        ),
    ];
    _pressed.clear();
    return actions;
  }
}

String? remoteKeyName(LogicalKeyboardKey key) {
  final label = key.keyLabel;
  if (label.length == 1 && RegExp('[A-Za-z]').hasMatch(label)) {
    return 'Key${label.toUpperCase()}';
  }
  if (label.length == 1 && RegExp('[0-9]').hasMatch(label)) {
    return 'Digit$label';
  }
  return <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.enter: 'Enter',
    LogicalKeyboardKey.numpadEnter: 'Enter',
    LogicalKeyboardKey.backspace: 'Backspace',
    LogicalKeyboardKey.delete: 'Delete',
    LogicalKeyboardKey.tab: 'Tab',
    LogicalKeyboardKey.escape: 'Escape',
    LogicalKeyboardKey.space: 'Space',
    LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
    LogicalKeyboardKey.arrowRight: 'ArrowRight',
    LogicalKeyboardKey.arrowUp: 'ArrowUp',
    LogicalKeyboardKey.arrowDown: 'ArrowDown',
    LogicalKeyboardKey.home: 'Home',
    LogicalKeyboardKey.end: 'End',
    LogicalKeyboardKey.pageUp: 'PageUp',
    LogicalKeyboardKey.pageDown: 'PageDown',
    LogicalKeyboardKey.f1: 'F1',
    LogicalKeyboardKey.f2: 'F2',
    LogicalKeyboardKey.f3: 'F3',
    LogicalKeyboardKey.f4: 'F4',
    LogicalKeyboardKey.f5: 'F5',
    LogicalKeyboardKey.f6: 'F6',
    LogicalKeyboardKey.f7: 'F7',
    LogicalKeyboardKey.f8: 'F8',
    LogicalKeyboardKey.f9: 'F9',
    LogicalKeyboardKey.f10: 'F10',
    LogicalKeyboardKey.f11: 'F11',
    LogicalKeyboardKey.f12: 'F12',
    LogicalKeyboardKey.minus: 'Minus',
    LogicalKeyboardKey.equal: 'Equal',
    LogicalKeyboardKey.bracketLeft: 'BracketLeft',
    LogicalKeyboardKey.bracketRight: 'BracketRight',
    LogicalKeyboardKey.backslash: 'Backslash',
    LogicalKeyboardKey.semicolon: 'Semicolon',
    LogicalKeyboardKey.quote: 'Quote',
    LogicalKeyboardKey.comma: 'Comma',
    LogicalKeyboardKey.period: 'Period',
    LogicalKeyboardKey.slash: 'Slash',
    LogicalKeyboardKey.backquote: 'Backquote',
  }[key];
}

class _PressedRemoteKey {
  const _PressedRemoteKey({required this.key, required this.physicalHidUsage});

  final String key;
  final int physicalHidUsage;
}
