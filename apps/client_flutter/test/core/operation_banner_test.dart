import 'package:cross_desktop_remote/core/presentation/operation_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('dismiss and cancel keep distinct semantics', (tester) async {
    var cancelCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OperationBanner(
            operationKey: 'offer-1',
            title: '复制文件准备就绪',
            collapsedLabel: '待粘贴文件',
            details: '粘贴后开始传输',
            onCancel: () => cancelCount += 1,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('operation-banner-dismiss')));
    await tester.pump();
    expect(cancelCount, 0);
    expect(find.text('复制文件准备就绪'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OperationBanner(
            operationKey: 'offer-2',
            title: '复制文件准备就绪',
            collapsedLabel: '待粘贴文件',
            onCancel: () => cancelCount += 1,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('operation-banner-cancel')));
    expect(cancelCount, 1);
  });

  testWidgets('collapses after four seconds and can be reopened', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: OperationBanner(
            operationKey: 'offer-1',
            title: '复制文件准备就绪',
            collapsedLabel: '待粘贴文件',
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('operation-banner-expanded')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
    expect(
      find.byKey(const ValueKey('operation-banner-collapsed')),
      findsOneWidget,
    );

    await tester.tap(find.text('待粘贴文件'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('operation-banner-expanded')),
      findsOneWidget,
    );
  });
}
