import 'package:cross_desktop_remote/features/remote/presentation/windows_remote_ime_coordinator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const keyA = PhysicalKeyboardKey.keyA;
  const keyC = PhysicalKeyboardKey.keyC;
  const keyEnter = PhysicalKeyboardKey.enter;

  test('keeps Pinyin composition local and emits only committed CJK text', () {
    final coordinator = WindowsRemoteImeCoordinator();

    final composing = coordinator.update(
      const TextEditingValue(
        text: 'nihao',
        composing: TextRange(start: 0, end: 5),
      ),
    );
    expect(coordinator.phase, WindowsRemoteImePhase.composing);
    expect(coordinator.compositionLength, 5);
    expect(composing.isEmpty, isTrue);

    final committed = coordinator.update(const TextEditingValue(text: '你好'));
    expect(coordinator.phase, WindowsRemoteImePhase.idle);
    expect(committed.backspaceCount, 0);
    expect(committed.insertedText, '你好');
  });

  test('does not route candidate keys while composition is active', () {
    final coordinator = WindowsRemoteImeCoordinator();
    coordinator.update(
      const TextEditingValue(
        text: 'ni',
        composing: TextRange(start: 0, end: 2),
      ),
    );

    final enter = KeyDownEvent(
      physicalKey: keyEnter,
      logicalKey: LogicalKeyboardKey.enter,
      timeStamp: Duration.zero,
    );
    final candidateLetter = KeyDownEvent(
      physicalKey: keyA,
      logicalKey: LogicalKeyboardKey.keyA,
      character: 'a',
      timeStamp: Duration.zero,
    );

    expect(
      coordinator.shouldRouteToRemote(enter, shortcutPressed: false),
      isFalse,
    );
    expect(
      coordinator.shouldRouteToRemote(candidateLetter, shortcutPressed: false),
      isFalse,
    );
  });

  test('routes shortcuts and navigation but leaves printable text to IME', () {
    final coordinator = WindowsRemoteImeCoordinator();
    final letter = KeyDownEvent(
      physicalKey: keyA,
      logicalKey: LogicalKeyboardKey.keyA,
      character: 'a',
      timeStamp: Duration.zero,
    );
    final shortcut = KeyDownEvent(
      physicalKey: keyC,
      logicalKey: LogicalKeyboardKey.keyC,
      character: 'c',
      timeStamp: Duration.zero,
    );
    final enter = KeyDownEvent(
      physicalKey: keyEnter,
      logicalKey: LogicalKeyboardKey.enter,
      timeStamp: Duration.zero,
    );

    expect(
      coordinator.shouldRouteToRemote(letter, shortcutPressed: false),
      isFalse,
    );
    expect(
      coordinator.shouldRouteToRemote(shortcut, shortcutPressed: true),
      isTrue,
    );
    expect(
      coordinator.shouldRouteToRemote(enter, shortcutPressed: false),
      isTrue,
    );
  });

  test('routes key up for a key that was sent with a modifier', () {
    final coordinator = WindowsRemoteImeCoordinator();
    final keyUp = KeyUpEvent(
      physicalKey: keyC,
      logicalKey: LogicalKeyboardKey.keyC,
      timeStamp: Duration.zero,
    );

    expect(
      coordinator.shouldRouteToRemote(
        keyUp,
        shortcutPressed: false,
        remoteKeyIsPressed: true,
      ),
      isTrue,
    );
  });

  test('resets the append baseline before remote caret editing', () {
    final coordinator = WindowsRemoteImeCoordinator();
    coordinator.update(const TextEditingValue(text: 'hello'));
    final backspace = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.backspace,
      logicalKey: LogicalKeyboardKey.backspace,
      timeStamp: Duration.zero,
    );

    expect(coordinator.shouldResetBufferBefore(backspace), isTrue);
    coordinator.reset();
    final nextText = coordinator.update(const TextEditingValue(text: '你'));

    expect(nextText.backspaceCount, 0);
    expect(nextText.insertedText, '你');
  });

  test('cancelling composition emits no remote edit', () {
    final coordinator = WindowsRemoteImeCoordinator();
    coordinator.update(const TextEditingValue(text: 'A'));
    coordinator.update(
      const TextEditingValue(
        text: 'Ani',
        composing: TextRange(start: 1, end: 3),
      ),
    );

    final cancelled = coordinator.update(const TextEditingValue(text: 'A'));

    expect(cancelled.isEmpty, isTrue);
    expect(coordinator.phase, WindowsRemoteImePhase.idle);
  });
}
