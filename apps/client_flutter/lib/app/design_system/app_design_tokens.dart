import 'package:flutter/material.dart';

/// Shared visual tokens for the Hoshimado ("star window") design language.
///
/// Domain and session code must not depend on these values. Keeping the theme
/// in the presentation layer lets every platform share one visual contract
/// without coupling platform capabilities to layout decisions.
abstract final class AppPalette {
  static const indigo = Color(0xFF5964B5);
  static const indigoDark = Color(0xFFC4C8FF);
  static const sakura = Color(0xFFB95B7F);
  static const sakuraDark = Color(0xFFF1A8C0);
  static const mint = Color(0xFF32766F);
  static const mintDark = Color(0xFF8FD2C9);

  static const lightCanvas = Color(0xFFF2F4FB);
  static const lightSurface = Color(0xFFFAFBFF);
  static const lightInk = Color(0xFF25283B);
  static const lightMutedInk = Color(0xFF5C6077);

  static const darkCanvas = Color(0xFF101422);
  static const darkSurface = Color(0xFF181D2E);
  static const darkInk = Color(0xFFF2F3FC);
  static const darkMutedInk = Color(0xFFBEC2D8);
}

abstract final class AppSpacing {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

abstract final class AppRadii {
  static const control = 12.0;
  static const inner = 16.0;
  static const card = 22.0;
  static const panel = 28.0;
}

abstract final class AppMotion {
  static const quick = Duration(milliseconds: 120);
  static const standard = Duration(milliseconds: 190);
  static const deliberate = Duration(milliseconds: 260);

  static const standardCurve = Curves.easeOutCubic;
}

abstract final class AppIconSizes {
  static const small = 18.0;
  static const medium = 22.0;
  static const large = 28.0;
}

@immutable
class AppVisualTheme extends ThemeExtension<AppVisualTheme> {
  const AppVisualTheme({
    required this.accent,
    required this.onAccent,
    required this.success,
    required this.warning,
    required this.info,
    required this.navigationSurface,
    required this.ambientLine,
    required this.ambientGlow,
    required this.focusRing,
  });

  AppVisualTheme.light()
    : accent = AppPalette.sakura,
      onAccent = Colors.white,
      success = AppPalette.mint,
      warning = Color(0xFF9B5B17),
      info = AppPalette.indigo,
      navigationSurface = Color(0xFFEAEDF8),
      ambientLine = Color(0x155964B5),
      ambientGlow = Color(0x125964B5),
      focusRing = Color(0xFF48549F);

  AppVisualTheme.dark()
    : accent = AppPalette.sakuraDark,
      onAccent = Color(0xFF5A1730),
      success = AppPalette.mintDark,
      warning = Color(0xFFFFBE73),
      info = AppPalette.indigoDark,
      navigationSurface = Color(0xFF14192A),
      ambientLine = Color(0x20C4C8FF),
      ambientGlow = Color(0x16C4C8FF),
      focusRing = Color(0xFFDEE0FF);

  final Color accent;
  final Color onAccent;
  final Color success;
  final Color warning;
  final Color info;
  final Color navigationSurface;
  final Color ambientLine;
  final Color ambientGlow;
  final Color focusRing;

  @override
  AppVisualTheme copyWith({
    Color? accent,
    Color? onAccent,
    Color? success,
    Color? warning,
    Color? info,
    Color? navigationSurface,
    Color? ambientLine,
    Color? ambientGlow,
    Color? focusRing,
  }) => AppVisualTheme(
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    info: info ?? this.info,
    navigationSurface: navigationSurface ?? this.navigationSurface,
    ambientLine: ambientLine ?? this.ambientLine,
    ambientGlow: ambientGlow ?? this.ambientGlow,
    focusRing: focusRing ?? this.focusRing,
  );

  @override
  AppVisualTheme lerp(covariant AppVisualTheme? other, double t) {
    if (other == null) return this;
    return AppVisualTheme(
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
      navigationSurface: Color.lerp(
        navigationSurface,
        other.navigationSurface,
        t,
      )!,
      ambientLine: Color.lerp(ambientLine, other.ambientLine, t)!,
      ambientGlow: Color.lerp(ambientGlow, other.ambientGlow, t)!,
      focusRing: Color.lerp(focusRing, other.focusRing, t)!,
    );
  }
}

extension AppVisualThemeContext on BuildContext {
  AppVisualTheme get visualTheme =>
      Theme.of(this).extension<AppVisualTheme>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? AppVisualTheme.dark()
          : AppVisualTheme.light());
}
