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

  testWidgets('presents application feedback in FIFO order', (tester) async {
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
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      AppNotificationCenter.instance.pendingCount(AppNotificationScope.main),
      2,
    );
    expect(
      AppNotificationCenter.instance.hasActiveNotification(
        AppNotificationScope.main,
      ),
      isTrue,
    );

    expect(find.text('第一条'), findsOneWidget);
    expect(find.text('第二条'), findsNothing);
    expect(find.text('第三条'), findsNothing);

    await _finishNotification(tester);
    expect(find.text('第二条'), findsOneWidget);
    expect(find.text('第三条'), findsNothing);

    await _finishNotification(tester);
    expect(find.text('第三条'), findsOneWidget);
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

    await _finishNotification(tester);
    await tester.pump(const Duration(seconds: 1));
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

Future<void> _finishNotification(WidgetTester tester) async {
  AppMessenger.scaffoldMessengerKey.currentState!.removeCurrentSnackBar();
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}
