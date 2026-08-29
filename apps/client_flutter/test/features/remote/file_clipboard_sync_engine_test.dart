import 'package:cross_desktop_remote/core/clipboard/clipboard_platform_adapter.dart';
import 'package:cross_desktop_remote/features/remote/application/file_clipboard_sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'apply gate completes only for the matching materialized transfer',
    () async {
      final gate = FileClipboardApplyGate();
      final waiting = gate.waitFor(
        '0123456789abcdef',
        timeout: const Duration(seconds: 1),
      );

      expect(
        gate.accept(fileClipboardAppliedMessage('fedcba9876543210')),
        isTrue,
      );
      expect(
        gate.accept(fileClipboardAppliedMessage('0123456789abcdef')),
        isTrue,
      );
      expect(await waiting, isTrue);
    },
  );

  test('apply gate retains an early materialization acknowledgement', () async {
    final gate = FileClipboardApplyGate();
    gate.accept(fileClipboardAppliedMessage('0123456789abcdef'));
    expect(await gate.waitFor('0123456789abcdef'), isTrue);
  });

  test('apply gate retains an early transfer failure', () async {
    final gate = FileClipboardApplyGate();
    gate.fail('0123456789abcdef');
    expect(await gate.waitFor('0123456789abcdef'), isFalse);
  });

  test('echo guard suppresses only the native write notification', () {
    final guard = FileClipboardEchoGuard()
      ..expect(['/tmp/a.txt', '/tmp/b.txt']);
    final matching = ClipboardSnapshot(
      revision: 2,
      hasText: false,
      tooLarge: false,
      utf8Bytes: 0,
      filePaths: const ['/tmp/b.txt', '/tmp/a.txt'],
    );
    expect(guard.consumeIfExpected(matching), isTrue);
    expect(guard.consumeIfExpected(matching), isFalse);
  });
}
