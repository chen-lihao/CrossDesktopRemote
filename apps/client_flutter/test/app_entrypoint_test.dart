import 'package:cross_desktop_remote/main.dart' as application;
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100 && finder.evaluate().isEmpty; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(finder, findsAtLeastNWidgets(1));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettingsController.repositoryFactoryOverride = () async =>
        MemoryAppSettingsRepository();
  });
  tearDown(() => AppSettingsController.repositoryFactoryOverride = null);

  testWidgets('entrypoint attaches the home shell to the default view', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    application.main();
    await _pumpUntilFound(tester, find.byType(NavigationRail));

    expect(tester.takeException(), isNull);
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('控制其他设备'), findsAtLeastNWidgets(1));
  });
}
