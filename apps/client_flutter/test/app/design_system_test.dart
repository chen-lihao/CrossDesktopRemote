import 'package:cross_desktop_remote/app/design_system/app_components.dart';
import 'package:cross_desktop_remote/app/design_system/app_design_tokens.dart';
import 'package:cross_desktop_remote/app/theme.dart';
import 'package:cross_desktop_remote/core/presentation/adaptive_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('light and dark themes expose the same semantic visual contract', () {
    for (final theme in [CrossDesktopTheme.light(), CrossDesktopTheme.dark()]) {
      final visual = theme.extension<AppVisualTheme>();
      expect(visual, isNotNull);
      expect(theme.useMaterial3, isTrue);
      expect(theme.cardTheme.elevation, 0);
      expect(theme.colorScheme.primary, isNot(theme.colorScheme.error));
    }

    expect(
      CrossDesktopTheme.light().extension<AppVisualTheme>()!.accent,
      isNot(CrossDesktopTheme.dark().extension<AppVisualTheme>()!.accent),
    );
  });

  for (final size in const [Size(390, 844), Size(834, 1112), Size(1440, 900)]) {
    testWidgets('page foundation remains usable at ${size.width}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: CrossDesktopTheme.light(),
          home: AdaptiveAppShell(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.devices_outlined),
                label: '设备',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                label: '设置',
              ),
            ],
            body: const AppPageScaffold(
              title: '设置',
              subtitle: '管理远程桌面的默认行为与安全选项。',
              icon: Icons.tune_outlined,
              children: [
                AppSectionCard(
                  title: '画质与性能',
                  icon: Icons.high_quality_outlined,
                  children: [
                    ListTile(
                      title: Text('默认分辨率'),
                      subtitle: Text('自动根据网络与设备能力调整'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(AppPageHeader),
          matching: find.text('设置'),
        ),
        findsOneWidget,
      );
      expect(find.byType(AppBrandMark), findsOneWidget);
      expect(find.byType(AppSectionCard), findsOneWidget);
    });
  }

  testWidgets('large text keeps the compact page scrollable', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          textScaler: TextScaler.linear(2),
        ),
        child: MaterialApp(
          theme: CrossDesktopTheme.light(),
          home: const AppPageScaffold(
            title: '可信设备与远程访问',
            subtitle: '在不降低安全性的前提下管理设备、连接与授权。',
            icon: Icons.devices_outlined,
            children: [
              AppEmptyState(
                icon: Icons.history_outlined,
                title: '暂无会话记录',
                message: '建立远程连接后，这里会显示经过加密处理的连接元数据。',
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(Scrollable), findsWidgets);
  });
}
