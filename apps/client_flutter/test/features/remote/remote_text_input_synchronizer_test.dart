import 'package:cross_desktop_remote/core/input/remote_text_chunks.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_text_input_synchronizer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'does not send Pinyin composing text and sends only committed Chinese',
    () {
      final synchronizer = RemoteTextInputSynchronizer();

      expect(
        synchronizer
            .update(
              const TextEditingValue(
                text: 'ni',
                composing: TextRange(start: 0, end: 2),
              ),
            )
            .isEmpty,
        isTrue,
      );

      final committed = synchronizer.update(
        const TextEditingValue(
          text: '你',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      expect(committed.backspaceCount, 0);
      expect(committed.insertedText, '你');
    },
  );

  test('sends a committed phrase exactly once', () {
    final synchronizer = RemoteTextInputSynchronizer();

    synchronizer.update(
      const TextEditingValue(
        text: 'nihao',
        composing: TextRange(start: 0, end: 5),
      ),
    );
    final committed = synchronizer.update(const TextEditingValue(text: '你好'));
    final unchanged = synchronizer.update(const TextEditingValue(text: '你好'));

    expect(committed.insertedText, '你好');
    expect(unchanged.isEmpty, isTrue);
  });

  test('keeps consecutive Microsoft Pinyin compositions local', () {
    final synchronizer = RemoteTextInputSynchronizer();

    synchronizer.update(
      const TextEditingValue(
        text: 'ni',
        composing: TextRange(start: 0, end: 2),
      ),
    );
    final firstCommit = synchronizer.update(const TextEditingValue(text: '你'));
    final secondComposition = synchronizer.update(
      const TextEditingValue(
        text: '你hao',
        composing: TextRange(start: 1, end: 4),
      ),
    );
    final secondCommit = synchronizer.update(
      const TextEditingValue(text: '你好'),
    );

    expect(firstCommit.insertedText, '你');
    expect(secondComposition.isEmpty, isTrue);
    expect(secondCommit.backspaceCount, 0);
    expect(secondCommit.insertedText, '好');
  });

  test('cancelling a Microsoft Pinyin composition sends nothing', () {
    final synchronizer = RemoteTextInputSynchronizer();
    synchronizer.update(const TextEditingValue(text: 'A'));

    synchronizer.update(
      const TextEditingValue(
        text: 'Ani',
        composing: TextRange(start: 1, end: 3),
      ),
    );
    final cancelled = synchronizer.update(const TextEditingValue(text: 'A'));

    expect(cancelled.isEmpty, isTrue);
  });

  test('deletion counts grapheme clusters instead of UTF-16 code units', () {
    final synchronizer = RemoteTextInputSynchronizer();
    synchronizer.update(const TextEditingValue(text: 'A👨‍👩‍👧‍👦'));

    final edit = synchronizer.update(const TextEditingValue(text: 'A'));

    expect(edit.backspaceCount, 1);
    expect(edit.insertedText, isEmpty);
  });

  test('replacement rewrites only the changed suffix', () {
    final synchronizer = RemoteTextInputSynchronizer();
    synchronizer.update(const TextEditingValue(text: 'hello'));

    final edit = synchronizer.update(const TextEditingValue(text: 'heXllo'));

    expect(edit.backspaceCount, 3);
    expect(edit.insertedText, 'Xllo');
  });

  test('chunks text without splitting ordinary grapheme clusters', () {
    final chunks = chunkRemoteText(
      '你好👨‍👩‍👧‍👦abc',
      maximumUtf16Units: 12,
    ).toList();

    expect(chunks.join(), '你好👨‍👩‍👧‍👦abc');
    expect(chunks.every((chunk) => chunk.length <= 12), isTrue);
  });
}
