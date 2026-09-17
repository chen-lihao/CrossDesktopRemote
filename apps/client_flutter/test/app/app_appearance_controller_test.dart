import 'package:cross_desktop_remote/app/appearance/app_appearance_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final appearance = AppAppearanceController.instance;

  setUp(appearance.resetForTesting);
  tearDown(appearance.resetForTesting);

  test('offers system, light, and dark appearance modes', () async {
    expect(appearance.themeMode, ThemeMode.system);

    await appearance.setThemeMode(ThemeMode.light);
    expect(appearance.themeMode, ThemeMode.light);
    expect(appearance.themeMode.label, '亮色');

    await appearance.setThemeMode(ThemeMode.dark);
    expect(appearance.themeMode, ThemeMode.dark);
    expect(appearance.themeMode.label, '暗色');

    await appearance.setThemeMode(ThemeMode.system);
    expect(appearance.themeMode, ThemeMode.system);
    expect(appearance.themeMode.label, '跟随系统');
  });
}
