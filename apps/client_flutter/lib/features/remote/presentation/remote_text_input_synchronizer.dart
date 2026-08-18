import 'package:characters/characters.dart';
import 'package:flutter/services.dart';

class RemoteTextEdit {
  const RemoteTextEdit({this.backspaceCount = 0, this.insertedText = ''});

  final int backspaceCount;
  final String insertedText;

  bool get isEmpty => backspaceCount == 0 && insertedText.isEmpty;
}

/// Converts Flutter editing-buffer updates into remote append/backspace events.
///
/// The committed baseline is intentionally not changed while an IME composing
/// range is active. This keeps iOS Pinyin candidate selection local and sends
/// only the final committed Unicode text to the remote computer.
class RemoteTextInputSynchronizer {
  String _committedText = '';

  String get committedText => _committedText;

  RemoteTextEdit update(TextEditingValue value) {
    final composing = value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return const RemoteTextEdit();
    }

    final previous = _committedText.characters.toList(growable: false);
    final current = value.text.characters.toList(growable: false);
    var commonPrefixLength = 0;
    while (commonPrefixLength < previous.length &&
        commonPrefixLength < current.length &&
        previous[commonPrefixLength] == current[commonPrefixLength]) {
      commonPrefixLength += 1;
    }

    final edit = RemoteTextEdit(
      backspaceCount: previous.length - commonPrefixLength,
      insertedText: current.skip(commonPrefixLength).join(),
    );
    _committedText = value.text;
    return edit;
  }

  bool shouldCompact({int maximumGraphemes = 80}) =>
      _committedText.characters.length >= maximumGraphemes;

  void reset([String text = '']) {
    _committedText = text;
  }
}
