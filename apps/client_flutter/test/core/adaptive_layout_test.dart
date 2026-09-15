import 'package:cross_desktop_remote/core/presentation/adaptive_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const destinations = <NavigationDestination>[
    NavigationDestination(icon: Icon(Icons.devices), label: '设备'),
    NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
  ];

  for (final testCase in const <(double, AppLayoutSize)>[
    (699, AppLayoutSize.compact),
    (700, AppLayoutSize.medium),
    (1099, AppLayoutSize.medium),
    (1100, AppLayoutSize.expanded),
  ]) {
    testWidgets('uses ${testCase.$2.name} layout at ${testCase.$1}', (
      tester,
    ) async {
      tester.view.physicalSize = Size(testCase.$1, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      AppLayoutSize? observed;
      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveAppShell(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            destinations: destinations,
            body: Builder(
              builder: (context) {
                observed = AppLayoutScope.sizeOf(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      expect(observed, testCase.$2);
      expect(
        find.byType(NavigationBar),
        testCase.$2 == AppLayoutSize.compact ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(NavigationRail),
        testCase.$2 == AppLayoutSize.compact ? findsNothing : findsOneWidget,
      );
    });
  }
}
