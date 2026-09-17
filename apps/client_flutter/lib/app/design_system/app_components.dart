import 'dart:math' as math;

import 'package:cross_desktop_remote/app/design_system/app_design_tokens.dart';
import 'package:flutter/material.dart';

class AppBrandMark extends StatelessWidget {
  const AppBrandMark({super.key, this.size = 38, this.semanticLabel});

  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mark = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(size * .31),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Center(
              child: Icon(
                Icons.desktop_windows_outlined,
                color: scheme.onPrimary,
                size: size * .55,
              ),
            ),
            Positioned(
              right: -size * .04,
              top: -size * .07,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.visualTheme.accent,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: scheme.surface,
                    width: math.max(1.5, size * .055),
                  ),
                ),
                child: SizedBox.square(dimension: size * .25),
              ),
            ),
          ],
        ),
      ),
    );
    if (semanticLabel == null) return ExcludeSemantics(child: mark);
    return Semantics(label: semanticLabel, image: true, child: mark);
  }
}

class AppPageHeader extends StatelessWidget {
  const AppPageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      container: true,
      header: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 54,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color: context.visualTheme.accent,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          if (icon != null) ...[
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(AppRadii.inner),
              ),
              child: Icon(icon, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.headlineMedium),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.md),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class AppSectionCard extends StatelessWidget {
  const AppSectionCard({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xs,
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    child: Icon(
                      icon,
                      color: scheme.onPrimaryContainer,
                      size: AppIconSizes.medium,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.titleMedium),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: AppSpacing.sm),
                    trailing!,
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            ...children,
          ],
        ),
      ),
    );
  }
}

class AppStatusPill extends StatelessWidget {
  const AppStatusPill({
    super.key,
    required this.label,
    this.value,
    this.icon,
    this.color,
  });

  final String label;
  final String? value;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effectiveColor = color ?? scheme.primary;
    return Semantics(
      label: value == null ? label : '$label，$value',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: effectiveColor.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: effectiveColor.withValues(alpha: .22)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: AppIconSizes.small, color: effectiveColor),
                const SizedBox(width: AppSpacing.xs),
              ],
              Text(
                value == null ? label : '$label  $value',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(AppRadii.inner),
              ),
              child: Icon(icon, color: scheme.onSecondaryContainer),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: AppSpacing.md),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class AppAmbientBackground extends StatelessWidget {
  const AppAmbientBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visual = context.visualTheme;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _StarWindowPainter(
              canvasColor: scheme.surfaceContainerLowest,
              lineColor: visual.ambientLine,
              glowColor: visual.ambientGlow,
              sparkColor: visual.accent.withValues(alpha: .34),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _StarWindowPainter extends CustomPainter {
  const _StarWindowPainter({
    required this.canvasColor,
    required this.lineColor,
    required this.glowColor,
    required this.sparkColor,
  });

  final Color canvasColor;
  final Color lineColor;
  final Color glowColor;
  final Color sparkColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = canvasColor);

    final linePaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final glowPaint = Paint()
      ..shader =
          RadialGradient(colors: [glowColor, glowColor.withValues(alpha: 0)])
              .createShader(
                Rect.fromCircle(
                  center: Offset(size.width * .86, size.height * .12),
                  radius: math.max(size.width, size.height) * .36,
                ),
              );

    canvas.drawRect(Offset.zero & size, glowPaint);

    final anchor = Offset(size.width * .88, size.height * .12);
    canvas.drawCircle(
      anchor,
      math.min(size.width, size.height) * .19,
      linePaint,
    );
    canvas.drawCircle(
      anchor,
      math.min(size.width, size.height) * .12,
      linePaint,
    );
    canvas.drawCircle(
      Offset(size.width * .12, size.height * .82),
      math.min(size.width, size.height) * .16,
      linePaint,
    );
    canvas.drawCircle(anchor, 2.8, Paint()..color = sparkColor);

    final path = Path()
      ..moveTo(size.width * .68, 0)
      ..lineTo(size.width, size.height * .30)
      ..moveTo(size.width * .80, 0)
      ..lineTo(size.width, size.height * .18);
    canvas.drawPath(path, linePaint);

    final sparkPaint = Paint()
      ..color = sparkColor
      ..style = PaintingStyle.fill;
    for (final point in <Offset>[
      Offset(size.width * .72, size.height * .16),
      Offset(size.width * .93, size.height * .36),
      Offset(size.width * .17, size.height * .72),
    ]) {
      final spark = Path()
        ..moveTo(point.dx, point.dy - 3)
        ..lineTo(point.dx + 2, point.dy)
        ..lineTo(point.dx, point.dy + 3)
        ..lineTo(point.dx - 2, point.dy)
        ..close();
      canvas.drawPath(spark, sparkPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _StarWindowPainter oldDelegate) =>
      oldDelegate.canvasColor != canvasColor ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.glowColor != glowColor ||
      oldDelegate.sparkColor != sparkColor;
}
