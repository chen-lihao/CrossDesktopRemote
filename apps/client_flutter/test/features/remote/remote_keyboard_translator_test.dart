import 'package:cross_desktop_remote/features/remote/presentation/remote_keyboard_translator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('printable key sends text without an unmatched key-up', () {
    final translator = RemoteKeyboardTranslator();

    final down = translator.translate(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        character: 'a',
        timeStamp: Duration.zero,
      ),
      modifiers: const [],
    );
    final up = translator.translate(
      const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        timeStamp: Duration.zero,
      ),
      modifiers: const [],
    );

    expect(down, hasLength(1));
    expect(down.single.type, RemoteKeyboardActionType.text);
    expect(down.single.text, 'a');
    expect(up, isEmpty);
  });

  test('shortcut preserves a balanced physical key sequence', () {
    final translator = RemoteKeyboardTranslator();

    final down = translator.translate(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyC,
        logicalKey: LogicalKeyboardKey.keyC,
        character: 'c',
        timeStamp: Duration.zero,
      ),
      modifiers: const ['control'],
    );
    expect(translator.isPressed(PhysicalKeyboardKey.keyC), isTrue);
    final up = translator.translate(
      const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyC,
        logicalKey: LogicalKeyboardKey.keyC,
        timeStamp: Duration.zero,
      ),
      modifiers: const ['control'],
    );

    expect(down.single.type, RemoteKeyboardActionType.key);
    expect(down.single.phase, 'down');
    expect(down.single.key, 'KeyC');
    expect(down.single.physicalHidUsage, isNonZero);
    expect(up.single.phase, 'up');
    expect(translator.isPressed(PhysicalKeyboardKey.keyC), isFalse);
  });

  test('remote IME mode sends printable keys as balanced HID events', () {
    final translator = RemoteKeyboardTranslator();

    final down = translator.translate(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyN,
        logicalKey: LogicalKeyboardKey.keyN,
        character: 'n',
        timeStamp: Duration.zero,
      ),
      modifiers: const [],
      physicalOnly: true,
    );
    final up = translator.translate(
      const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyN,
        logicalKey: LogicalKeyboardKey.keyN,
        timeStamp: Duration.zero,
      ),
      modifiers: const [],
      physicalOnly: true,
    );

    expect(down.single.type, RemoteKeyboardActionType.key);
    expect(down.single.key, 'KeyN');
    expect(down.single.physicalHidUsage, isNonZero);
    expect(up.single.phase, 'up');
  });

  test('editing keys use stable host semantic mapping', () {
    final translator = RemoteKeyboardTranslator();

    for (final key in [
      (
        physical: PhysicalKeyboardKey.enter,
        logical: LogicalKeyboardKey.enter,
        wire: 'Enter',
      ),
      (
        physical: PhysicalKeyboardKey.backspace,
        logical: LogicalKeyboardKey.backspace,
        wire: 'Backspace',
      ),
    ]) {
      final down = translator.translate(
        KeyDownEvent(
          physicalKey: key.physical,
          logicalKey: key.logical,
          timeStamp: Duration.zero,
        ),
        modifiers: const [],
        physicalOnly: true,
      );
      final up = translator.translate(
        KeyUpEvent(
          physicalKey: key.physical,
          logicalKey: key.logical,
          timeStamp: Duration.zero,
        ),
        modifiers: const [],
        physicalOnly: true,
      );

      expect(down.single.key, key.wire);
      expect(down.single.physicalHidUsage, isNull);
      expect(up.single.key, key.wire);
      expect(up.single.physicalHidUsage, isNull);
    }
  });

  test('focus loss releases all physical keys', () {
    final translator = RemoteKeyboardTranslator();
    translator.translate(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.backspace,
        logicalKey: LogicalKeyboardKey.backspace,
        timeStamp: Duration.zero,
      ),
      modifiers: const [],
    );

    final released = translator.releaseAll();

    expect(released, hasLength(1));
    expect(released.single.phase, 'up');
    expect(released.single.key, 'Backspace');
    expect(translator.releaseAll(), isEmpty);
  });
}
