import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(AppMessenger.resetForTesting);
  tearDown(AppMessenger.resetForTesting);

  test('uses severity-specific display durations', () {
    AppNotification notification(AppMessageLevel severity) => AppNotification(
      id: severity.name,
      message: severity.name,
      severity: severity,
    );

    expect(
      notification(AppMessageLevel.info).effectiveDuration,
      const Duration(seconds: 3),
    );
    expect(
      notification(AppMessageLevel.success).effectiveDuration,
      const Duration(seconds: 3),
    );
    expect(
      notification(AppMessageLevel.warning).effectiveDuration,
      const Duration(seconds: 5),
    );
    expect(
      notification(AppMessageLevel.error).effectiveDuration,
      const Duration(seconds: 8),
    );
  });

  testWidgets('stacks concurrent feedback near the top without overlap', (
    tester,
  ) async {
    await _pumpMessenger(tester);
    expect(
      AppNotificationCenter.instance.hasPresenter(AppNotificationScope.main),
      isTrue,
    );

    for (final message in const ['第一条', '第二条', '第三条']) {
      AppMessenger.show(message, duration: const Duration(seconds: 1));
    }
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      AppNotificationCenter.instance.pendingCount(AppNotificationScope.main),
      0,
    );
    expect(
      AppNotificationCenter.instance.activeCount(AppNotificationScope.main),
      3,
    );
    expect(
      AppNotificationCenter.instance.hasActiveNotification(
        AppNotificationScope.main,
      ),
      isTrue,
    );

    expect(find.text('第一条'), findsOneWidget);
    expect(find.text('第二条'), findsOneWidget);
    expect(find.text('第三条'), findsOneWidget);

    final first = tester.getRect(find.text('第一条'));
    final second = tester.getRect(find.text('第二条'));
    final third = tester.getRect(find.text('第三条'));
    expect(first.top, greaterThan(0));
    expect(first.top, lessThan(200));
    expect(first.bottom, lessThan(second.top));
    expect(second.bottom, lessThan(third.top));

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('第一条'), findsNothing);
    expect(find.text('第二条'), findsNothing);
    expect(find.text('第三条'), findsNothing);
  });

  testWidgets('deduplicates repeated feedback inside one second', (
    tester,
  ) async {
    await _pumpMessenger(tester);

    AppMessenger.show(
      '正在恢复连接',
      dedupeKey: 'connection-recovering',
      duration: const Duration(seconds: 1),
    );
    AppMessenger.show(
      '正在恢复连接',
      dedupeKey: 'connection-recovering',
      duration: const Duration(seconds: 1),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在恢复连接'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('正在恢复连接'), findsNothing);
  });

  testWidgets('routes feedback to the nearest window presenter', (
    tester,
  ) async {
    late BuildContext remoteContext;
    await tester.pumpWidget(
      MaterialApp(
        home: AppNotificationPresenter(
          scope: AppNotificationScope.remoteDesktop,
          clearOnDispose: true,
          child: Builder(
            builder: (context) {
              remoteContext = context;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      ),
    );
    await tester.pump();

    AppMessenger.show('远程窗口消息', context: remoteContext);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('远程窗口消息'), findsOneWidget);
    expect(
      AppNotificationCenter.instance.hasActiveNotification(
        AppNotificationScope.remoteDesktop,
      ),
      isTrue,
    );
  });
}

Future<void> _pumpMessenger(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: AppMessenger.navigatorKey,
      scaffoldMessengerKey: AppMessenger.scaffoldMessengerKey,
      builder: (context, child) => AppNotificationPresenter(
        scope: AppNotificationScope.main,
        messengerKey: AppMessenger.scaffoldMessengerKey,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const Scaffold(body: SizedBox()),
    ),
  );
  await tester.pump();
}
