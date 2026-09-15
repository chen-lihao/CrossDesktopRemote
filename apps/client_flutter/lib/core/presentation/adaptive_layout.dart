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
  static const sectionSpacing = 16.0;
  static const headerSpacing = 24.0;
  static const maxContentWidth = 1160.0;

  static double pagePadding(AppLayoutSize size) => switch (size) {
    AppLayoutSize.compact => 16,
    AppLayoutSize.medium => 20,
    AppLayoutSize.expanded => 24,
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
            appBar: AppBar(
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            body: SafeArea(child: scopedBody),
            bottomNavigationBar: NavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: onDestinationSelected,
              destinations: destinations,
            ),
          );
        }

        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                NavigationRail(
                  extended: size == AppLayoutSize.expanded,
                  selectedIndex: selectedIndex,
                  onDestinationSelected: onDestinationSelected,
                  leading: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Tooltip(
                      message: 'CrossDesktopRemote',
                      child: Icon(Icons.desktop_windows_outlined),
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
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final double maxWidth;

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
                Text(title, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 6),
                Text(subtitle, style: Theme.of(context).textTheme.bodyLarge),
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
