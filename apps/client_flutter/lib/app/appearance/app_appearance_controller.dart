import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Owns the presentation-only color-mode preference for every Flutter view.
///
/// Keeping this outside the remote-session settings prevents appearance
/// changes from rebuilding or mutating media, input, transfer, and security
/// state. Secondary desktop windows listen to the same process-wide instance.
class AppAppearanceController extends ChangeNotifier {
  AppAppearanceController._();

  static final instance = AppAppearanceController._();

  static const _themeModeKey = 'appearance.theme_mode.v1';

  ThemeMode _themeMode = ThemeMode.system;
  Future<void>? _loadOperation;
  int _mutationRevision = 0;

  ThemeMode get themeMode => _themeMode;

  Future<void> load() => _loadOperation ??= _load();

  Future<void> _load() async {
    final revisionAtStart = _mutationRevision;
    try {
      final store = SharedPreferencesAsync();
      final stored = await store.getString(_themeModeKey);
      final resolved = ThemeMode.values.firstWhere(
        (mode) => mode.name == stored,
        orElse: () => ThemeMode.system,
      );
      if (revisionAtStart == _mutationRevision && resolved != _themeMode) {
        _themeMode = resolved;
        notifyListeners();
      }
    } catch (_) {
      // Widget tests, previews, and unsigned development builds can run
      // without the preferences plugin. System mode remains a safe default.
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _mutationRevision++;
    _themeMode = mode;
    notifyListeners();
    try {
      await SharedPreferencesAsync().setString(_themeModeKey, mode.name);
    } catch (_) {
      // The visual change is still valid for this process when persistence is
      // unavailable. No remote-session behavior depends on this write.
    }
  }

  @visibleForTesting
  void resetForTesting() {
    _themeMode = ThemeMode.system;
    _loadOperation = null;
    _mutationRevision = 0;
    notifyListeners();
  }
}

extension AppThemeModeLabel on ThemeMode {
  String get label => switch (this) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '亮色',
    ThemeMode.dark => '暗色',
  };

  String get description => switch (this) {
    ThemeMode.system => '随设备外观自动切换',
    ThemeMode.light => '始终使用明亮界面',
    ThemeMode.dark => '始终使用夜间界面',
  };

  IconData get icon => switch (this) {
    ThemeMode.system => Icons.brightness_auto_outlined,
    ThemeMode.light => Icons.light_mode_outlined,
    ThemeMode.dark => Icons.dark_mode_outlined,
  };
}
