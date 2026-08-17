import 'package:cross_desktop_remote/features/devices/presentation/devices_page.dart';
import 'package:cross_desktop_remote/features/sessions/presentation/sessions_page.dart';
import 'package:cross_desktop_remote/features/settings/presentation/settings_page.dart';
import 'package:flutter/material.dart';

enum HomeSection { devices, sessions, settings }

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _desktopBreakpoint = 840.0;

  static const _destinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.devices_outlined),
      selectedIcon: Icon(Icons.devices),
      label: '设备',
    ),
    NavigationDestination(
      icon: Icon(Icons.monitor_heart_outlined),
      selectedIcon: Icon(Icons.monitor_heart),
      label: '会话',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: '设置',
    ),
  ];

  static const _pages = <Widget>[DevicesPage(), SessionsPage(), SettingsPage()];

  int _selectedIndex = HomeSection.devices.index;

  void _select(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useNavigationRail = constraints.maxWidth >= _desktopBreakpoint;

        if (useNavigationRail) {
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  NavigationRail(
                    extended: constraints.maxWidth >= 1180,
                    selectedIndex: _selectedIndex,
                    onDestinationSelected: _select,
                    leading: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Tooltip(
                        message: 'CrossDesktopRemote',
                        child: Icon(Icons.desktop_windows_outlined),
                      ),
                    ),
                    destinations: _destinations
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
                  Expanded(child: _pages[_selectedIndex]),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text(
              'CrossDesktopRemote',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: SafeArea(child: _pages[_selectedIndex]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: _select,
            destinations: _destinations,
          ),
        );
      },
    );
  }
}
