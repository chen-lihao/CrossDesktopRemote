import 'dart:async';

import 'package:cross_desktop_remote/core/discovery/lan_discovery_service.dart';
import 'package:cross_desktop_remote/core/identity/device_identity.dart';
import 'package:cross_desktop_remote/core/platform/device_capabilities.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/features/devices/presentation/devices_page.dart';
import 'package:cross_desktop_remote/features/remote/application/host_availability_controller.dart';
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
  late final DeviceIdentityController _identity;
  late final SessionHistoryController _history;
  late final RemoteSessionController _controllerSession;
  RemoteSessionController? _hostSession;
  HostAvailabilityController? _hostAvailability;
  late LanDiscoveryService _discovery;
  late List<Widget> _pages;
  bool _desktopRemoteFullScreen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _capabilities = DeviceCapabilities.current();
    _settings = AppSettingsController();
    _identity = DeviceIdentityController();
    _history = SessionHistoryController(settings: _settings);
    _createWorkspace();
    _settings.addListener(_handleSettingsChanged);
    unawaited(_loadPersistentState());
  }

  Future<void> _loadPersistentState() async {
    final identity = await _identity.loadOrCreate();
    _controllerSession.setLocalDeviceId(identity.deviceId);
    _hostSession?.setLocalDeviceId(identity.deviceId);
    await _settings.load();
    await _history.load();
    final availability = _hostAvailability;
    if (availability != null) {
      await availability.setIncomingAccessEnabled(
        _settings.incomingAccessEnabled,
      );
      await availability.initialize();
    }
  }

  void _createWorkspace() {
    _controllerSession = RemoteSessionController(
      role: RemoteRole.controller,
      localDeviceId: _identity.deviceId,
      initialQuality: _settings.defaultQuality,
      initialClipboardMode: _settings.clipboardSyncMode,
    );
    if (_capabilities.canHost) {
      _hostSession = RemoteSessionController(
        role: RemoteRole.host,
        localDeviceId: _identity.deviceId,
        initialQuality: _settings.defaultQuality,
        initialClipboardMode: _settings.clipboardSyncMode,
      );
      _hostAvailability = HostAvailabilityController(
        session: _hostSession!,
        serverUrl: () => _settings.signalingServerUrl,
      );
    }
    _history.attachAll([_controllerSession, ?_hostSession]);
    _discovery = createLanDiscoveryService();
    _pages = <Widget>[
      DevicesPage(
        controllerSession: _controllerSession,
        hostAvailability: _hostAvailability,
        discoveryService: _discovery,
        identity: _identity,
        settings: _settings,
        onDesktopFullScreenChanged: _handleDesktopFullScreenChanged,
      ),
      SessionsPage(
        sessions: [_controllerSession, ?_hostSession],
        history: _history,
        onOpenDevices: () => _select(HomeSection.devices.index),
      ),
      SettingsPage(
        settings: _settings,
        session: _controllerSession,
        hostSession: _hostSession,
      ),
    ];
  }

  void _handleSettingsChanged() {
    _controllerSession.setIdleQuality(_settings.defaultQuality);
    _controllerSession.setClipboardMode(_settings.clipboardSyncMode);
    _hostSession?.setIdleQuality(_settings.defaultQuality);
    _hostSession?.setClipboardMode(_settings.clipboardSyncMode);
    final availability = _hostAvailability;
    if (availability != null) {
      unawaited(
        availability.setIncomingAccessEnabled(_settings.incomingAccessEnabled),
      );
      availability.reconcileServerConfiguration();
      unawaited(availability.ensureOnline());
    }
  }

  void _handleDesktopFullScreenChanged(bool enabled) {
    if (!mounted || _desktopRemoteFullScreen == enabled) return;
    setState(() => _desktopRemoteFullScreen = enabled);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final hostSession = _hostSession;
      if (hostSession != null) {
        unawaited(hostSession.refreshHostPermissions());
      }
      final availability = _hostAvailability;
      if (availability != null) {
        unawaited(availability.ensureOnline());
      }
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
    _hostAvailability?.dispose();
    _hostSession?.dispose();
    _controllerSession.dispose();
    _settings.removeListener(_handleSettingsChanged);
    _identity.dispose();
    _settings.dispose();
    super.dispose();
  }
}
