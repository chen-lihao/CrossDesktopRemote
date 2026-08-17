import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows application feedback through the global messenger', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: AppMessenger.scaffoldMessengerKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );

    AppMessenger.show('远程会话连接成功', level: AppMessageLevel.success);
    await tester.pump();

    expect(find.text('远程会话连接成功'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });
}
