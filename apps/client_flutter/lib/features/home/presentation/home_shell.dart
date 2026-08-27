import 'dart:async';

import 'package:cross_desktop_remote/core/discovery/lan_discovery_service.dart';
import 'package:cross_desktop_remote/core/platform/device_capabilities.dart';
import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/features/devices/presentation/devices_page.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/sessions/presentation/sessions_page.dart';
import 'package:cross_desktop_remote/features/sessions/application/session_history_controller.dart';
import 'package:cross_desktop_remote/features/settings/presentation/settings_page.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:flutter/material.dart';

enum HomeSection { devices, sessions, settings }

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
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

  int _selectedIndex = HomeSection.devices.index;
  late final DeviceCapabilities _capabilities;
  late final AppSettingsController _settings;
  late final SessionHistoryController _history;
  late RemoteRole _role;
  late RemoteSessionController _session;
  late LanDiscoveryService _discovery;
  late List<Widget> _pages;
  bool _desktopRemoteFullScreen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _capabilities = DeviceCapabilities.current();
    _settings = AppSettingsController();
    _history = SessionHistoryController(settings: _settings);
    _role = _capabilities.defaultToHost
        ? RemoteRole.host
        : RemoteRole.controller;
    _createWorkspace();
    _settings.addListener(_handleSettingsChanged);
    unawaited(_loadPersistentState());
  }

  Future<void> _loadPersistentState() async {
    await _settings.load();
    await _history.load();
  }

  void _createWorkspace() {
    _session = RemoteSessionController(
      role: _role,
      initialQuality: _settings.defaultQuality,
      initialClipboardMode: _settings.clipboardSyncMode,
    );
    _history.attach(_session);
    _discovery = createLanDiscoveryService();
    _pages = <Widget>[
      DevicesPage(
        session: _session,
        discoveryService: _discovery,
        capabilities: _capabilities,
        onRoleChanged: _changeRole,
        settings: _settings,
        onDesktopFullScreenChanged: _handleDesktopFullScreenChanged,
      ),
      SessionsPage(
        session: _session,
        history: _history,
        onOpenDevices: () => _select(HomeSection.devices.index),
      ),
      SettingsPage(settings: _settings, session: _session),
    ];
  }

  void _changeRole(RemoteRole nextRole) {
    if (nextRole == _role ||
        (nextRole == RemoteRole.host && !_capabilities.canHost) ||
        (nextRole == RemoteRole.controller && !_capabilities.canControl)) {
      return;
    }
    final previousSession = _session;
    final previousDiscovery = _discovery;
    setState(() {
      _role = nextRole;
      _selectedIndex = HomeSection.devices.index;
      _createWorkspace();
    });
    previousSession.dispose();
    unawaited(previousDiscovery.dispose());
    AppMessenger.show(
      nextRole == RemoteRole.host ? '已切换为共享本机' : '已切换为控制其他设备',
      level: AppMessageLevel.success,
    );
  }

  void _handleSettingsChanged() {
    _session.setIdleQuality(_settings.defaultQuality);
    _session.setClipboardMode(_settings.clipboardSyncMode);
  }

  void _handleDesktopFullScreenChanged(bool enabled) {
    if (!mounted || _desktopRemoteFullScreen == enabled) return;
    setState(() => _desktopRemoteFullScreen = enabled);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_session.refreshHostPermissions());
    }
  }

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
                  if (!_desktopRemoteFullScreen) ...[
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
                  ],
                  Expanded(
                    key: const ValueKey('workspace'),
                    child: IndexedStack(
                      index: _selectedIndex,
                      children: _pages,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          appBar: _desktopRemoteFullScreen
              ? null
              : AppBar(
                  title: const Text(
                    'CrossDesktopRemote',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
          body: SafeArea(
            child: IndexedStack(index: _selectedIndex, children: _pages),
          ),
          bottomNavigationBar: _desktopRemoteFullScreen
              ? null
              : NavigationBar(
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: _select,
                  destinations: _destinations,
                ),
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_discovery.dispose());
    _history.dispose();
    _session.dispose();
    _settings.removeListener(_handleSettingsChanged);
    _settings.dispose();
    super.dispose();
  }
}
