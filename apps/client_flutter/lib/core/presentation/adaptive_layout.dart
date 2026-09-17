import 'package:cross_desktop_remote/app/design_system/app_components.dart';
import 'package:cross_desktop_remote/app/design_system/app_design_tokens.dart';
import 'package:flutter/material.dart';

enum AppLayoutSize { compact, medium, expanded }

abstract final class AppLayoutBreakpoints {
  static const compact = 700.0;
  static const expanded = 1100.0;

  static AppLayoutSize fromWidth(double width) {
    if (width < compact) return AppLayoutSize.compact;
    if (width < expanded) return AppLayoutSize.medium;
    return AppLayoutSize.expanded;
  }
}

abstract final class AppLayoutTokens {
  static const sectionSpacing = AppSpacing.md;
  static const headerSpacing = AppSpacing.lg;
  static const maxContentWidth = 1160.0;

  static double pagePadding(AppLayoutSize size) => switch (size) {
    AppLayoutSize.compact => AppSpacing.md,
    AppLayoutSize.medium => AppSpacing.lg,
    AppLayoutSize.expanded => AppSpacing.xl,
  };
}

class AppLayoutScope extends InheritedWidget {
  const AppLayoutScope({super.key, required this.size, required super.child});

  final AppLayoutSize size;

  static AppLayoutSize sizeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLayoutScope>()?.size ??
      AppLayoutBreakpoints.fromWidth(MediaQuery.sizeOf(context).width);

  @override
  bool updateShouldNotify(AppLayoutScope oldWidget) => oldWidget.size != size;
}

/// Shared navigation and breakpoint policy for every supported platform.
class AdaptiveAppShell extends StatelessWidget {
  const AdaptiveAppShell({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.body,
    this.title = 'CrossDesktopRemote',
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;
  final Widget body;
  final String title;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = AppLayoutBreakpoints.fromWidth(constraints.maxWidth);
        final scopedBody = AppLayoutScope(size: size, child: body);
        if (size == AppLayoutSize.compact) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              titleSpacing: AppSpacing.md,
              title: Row(
                children: [
                  const AppBrandMark(size: 34),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            body: Stack(
              children: [
                const Positioned.fill(child: AppAmbientBackground()),
                SafeArea(top: false, child: scopedBody),
              ],
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: onDestinationSelected,
              destinations: destinations,
            ),
          );
        }

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              const Positioned.fill(child: AppAmbientBackground()),
              SafeArea(
                child: Row(
                  children: [
                    NavigationRail(
                      extended: size == AppLayoutSize.expanded,
                      selectedIndex: selectedIndex,
                      onDestinationSelected: onDestinationSelected,
                      leading: const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                        child: Tooltip(
                          message: 'CrossDesktopRemote',
                          child: AppBrandMark(
                            size: 42,
                            semanticLabel: 'CrossDesktopRemote',
                          ),
                        ),
                      ),
                      destinations: destinations
                          .map(
                            (destination) => NavigationRailDestination(
                              icon: destination.icon,
                              selectedIcon: destination.selectedIcon,
                              label: Text(destination.label),
                            ),
                          )
                          .toList(growable: false),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: scopedBody),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Common page hierarchy used on macOS, Windows and iPad.
class AppPageScaffold extends StatelessWidget {
  const AppPageScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    this.maxWidth = AppLayoutTokens.maxContentWidth,
    this.icon,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final double maxWidth;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final size = AppLayoutScope.sizeOf(context);
    final padding = AppLayoutTokens.pagePadding(size);
    return ListView(
      padding: EdgeInsets.all(padding),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppPageHeader(
                  title: title,
                  subtitle: subtitle,
                  icon: icon,
                  trailing: trailing,
                ),
                const SizedBox(height: AppLayoutTokens.headerSpacing),
                ...children,
              ],
            ),
          ),
        ),
      ],
    );
  }
}
