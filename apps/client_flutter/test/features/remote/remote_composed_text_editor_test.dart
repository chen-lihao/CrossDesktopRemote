import 'package:cross_desktop_remote/features/remote/presentation/remote_composed_text_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'can open, cancel, and send repeatedly without lifecycle errors',
    (tester) async {
      String? lastResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  lastResult = await showRemoteComposedTextEditor(context);
                },
                child: const Text('打开编辑器'),
              ),
            ),
          ),
        ),
      );

      for (var index = 0; index < 30; index += 1) {
        await tester.tap(find.text('打开编辑器'));
        await tester.pumpAndSettle();
        expect(find.text('本地编辑后发送'), findsOneWidget);

        if (index.isEven) {
          await tester.tap(find.byKey(const ValueKey('cancel-composed-text')));
        } else {
          await tester.enterText(
            find.byKey(const ValueKey('remote-composed-text-field')),
            '第 $index 次输入',
          );
          await tester.tap(find.byKey(const ValueKey('send-composed-text')));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      expect(lastResult, '第 29 次输入');
    },
  );
}
