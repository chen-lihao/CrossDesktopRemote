import 'package:cross_desktop_remote/app/design_system/app_design_tokens.dart';
import 'package:flutter/material.dart';

abstract final class CrossDesktopTheme {
  static ThemeData light() => _theme(Brightness.light);

  static ThemeData dark() => _theme(Brightness.dark);

  static ThemeData _theme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final visual = isDark ? AppVisualTheme.dark() : AppVisualTheme.light();
    final generatedScheme = ColorScheme.fromSeed(
      seedColor: isDark ? AppPalette.indigoDark : AppPalette.indigo,
      brightness: brightness,
    );
    final colorScheme = generatedScheme.copyWith(
      primary: isDark ? AppPalette.indigoDark : AppPalette.indigo,
      onPrimary: isDark ? const Color(0xFF252B5E) : Colors.white,
      primaryContainer: isDark
          ? const Color(0xFF363E72)
          : const Color(0xFFE1E5FF),
      onPrimaryContainer: isDark
          ? const Color(0xFFF0F1FF)
          : const Color(0xFF29315F),
      secondary: isDark ? AppPalette.mintDark : AppPalette.mint,
      onSecondary: isDark ? const Color(0xFF123D39) : Colors.white,
      secondaryContainer: isDark
          ? const Color(0xFF244B49)
          : const Color(0xFFDCEDEA),
      onSecondaryContainer: isDark
          ? const Color(0xFFD7F5F0)
          : const Color(0xFF244A46),
      tertiary: isDark ? AppPalette.sakuraDark : AppPalette.sakura,
      onTertiary: isDark ? const Color(0xFF5A1730) : Colors.white,
      surface: isDark ? AppPalette.darkSurface : AppPalette.lightSurface,
      onSurface: isDark ? AppPalette.darkInk : AppPalette.lightInk,
      onSurfaceVariant: isDark
          ? AppPalette.darkMutedInk
          : AppPalette.lightMutedInk,
      surfaceContainerLowest: isDark
          ? AppPalette.darkCanvas
          : AppPalette.lightCanvas,
      surfaceContainerLow: isDark
          ? const Color(0xFF171C2C)
          : const Color(0xFFF8F9FE),
      surfaceContainer: isDark
          ? const Color(0xFF1C2234)
          : const Color(0xFFF0F2FA),
      surfaceContainerHigh: isDark
          ? const Color(0xFF242A3E)
          : const Color(0xFFE9ECF6),
      surfaceContainerHighest: isDark
          ? const Color(0xFF2C3348)
          : const Color(0xFFE1E5F0),
      outline: isDark ? const Color(0xFF9499B0) : const Color(0xFF747A91),
      outlineVariant: isDark
          ? const Color(0xFF3B435A)
          : const Color(0xFFD4D9E8),
    );

    final baseTypography = brightness == Brightness.dark
        ? Typography.material2021().white
        : Typography.material2021().black;
    final textTheme = baseTypography
        .copyWith(
          headlineMedium: baseTypography.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -.8,
            height: 1.15,
          ),
          headlineSmall: baseTypography.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -.45,
          ),
          titleLarge: baseTypography.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -.2,
          ),
          titleMedium: baseTypography.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          titleSmall: baseTypography.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: baseTypography.bodyLarge?.copyWith(height: 1.5),
          bodyMedium: baseTypography.bodyMedium?.copyWith(height: 1.5),
          bodySmall: baseTypography.bodySmall?.copyWith(height: 1.45),
          labelLarge: baseTypography.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        )
        .apply(
          bodyColor: colorScheme.onSurface,
          displayColor: colorScheme.onSurface,
        );

    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      brightness: brightness,
      textTheme: textTheme,
      focusColor: visual.focusRing.withValues(alpha: .18),
      hoverColor: colorScheme.primary.withValues(alpha: .06),
      splashColor: colorScheme.primary.withValues(alpha: .10),
      scaffoldBackgroundColor: colorScheme.surfaceContainerLowest,
      extensions: [visual],
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: colorScheme.surfaceContainerLow,
        shadowColor: colorScheme.primary.withValues(alpha: .08),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.card),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: .62),
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant.withValues(alpha: .70),
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
          borderSide: BorderSide(color: visual.focusRing, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 46),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 46),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size.square(44)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colorScheme.primary,
        minVerticalPadding: AppSpacing.sm,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xxs,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.inner),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: visual.navigationSurface,
        indicatorColor: colorScheme.primaryContainer,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.inner),
        ),
        selectedIconTheme: IconThemeData(color: colorScheme.onPrimaryContainer),
        selectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          color: colorScheme.primary,
        ),
        useIndicator: true,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: visual.navigationSurface,
        indicatorColor: colorScheme.primaryContainer,
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            color: selected
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          );
        }),
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: colorScheme.surfaceContainerLowest,
        foregroundColor: colorScheme.onSurface,
        titleTextStyle: textTheme.titleLarge,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.inner),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: colorScheme.inverseSurface,
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        textStyle: textTheme.bodySmall?.copyWith(
          color: colorScheme.onInverseSurface,
        ),
      ),
    );
  }
}
