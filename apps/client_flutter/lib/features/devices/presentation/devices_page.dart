import 'dart:async';
import 'dart:io';

import 'package:cross_desktop_remote/core/discovery/lan_discovery_service.dart';
import 'package:cross_desktop_remote/core/network/lan_address_service.dart';
import 'package:cross_desktop_remote/core/platform/device_capabilities.dart';
import 'package:cross_desktop_remote/core/platform/desktop_window_mode.dart';
import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/features/remote/application/host_sharing_lifecycle.dart';
import 'package:cross_desktop_remote/features/remote/application/host_invitation_lease_controller.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_desktop_panel.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.session,
    required this.discoveryService,
    required this.capabilities,
    required this.onRoleChanged,
    required this.settings,
    this.addressService = const LanAddressService(),
    this.windowModeController = const PlatformDesktopWindowModeController(),
    this.onDesktopFullScreenChanged,
  });

  final RemoteSessionController session;
  final LanDiscoveryService discoveryService;
  final DeviceCapabilities capabilities;
  final ValueChanged<RemoteRole> onRoleChanged;
  final AppSettingsController settings;
  final LanAddressService addressService;
  final DesktopWindowModeController windowModeController;
  final ValueChanged<bool>? onDesktopFullScreenChanged;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  RemoteRole get _role => widget.session.role;
  RemoteSessionController get _session => widget.session;

  late final TextEditingController _serverController = TextEditingController(
    text: _role == RemoteRole.host
        ? 'ws://127.0.0.1:8080/ws/signaling'
        : 'ws://<设备-IP>:8080/ws/signaling',
  );
  late final TextEditingController _roomController = TextEditingController(
    text: _role == RemoteRole.host ? generateRoomCode() : '',
  );
  StreamSubscription<List<DiscoveredDevice>>? _discoverySubscription;
  StreamSubscription<RemoteNotice>? _noticeSubscription;
  List<LanAddress>? _localAddresses;
  List<DiscoveredDevice> _discoveredDevices = const [];
  String? _addressError;
  String? _discoveryError;
  bool _isBrowsing = false;
  bool _discoveryActive = false;
  bool _isPublishing = false;
  bool _publicationBusy = false;
  bool _desktopFullScreen = false;
  bool _windowModeChanging = false;
  final GlobalKey _remoteDesktopPanelKey = GlobalKey(
    debugLabel: 'persistent-remote-desktop-panel',
  );
  final HostSharingLifecycle _hostSharing = HostSharingLifecycle();
  late final HostInvitationLeaseController _invitationLease;
  late RemoteSessionState _lastSessionState = _session.state;

  @override
  void initState() {
    super.initState();
    _invitationLease = HostInvitationLeaseController(
      onRotationDue: _rotateHostInvitation,
    )..addListener(_handleInvitationLeaseChanged);
    _session.addListener(_handleSessionChanged);
    widget.settings.addListener(_handleSettingsChanged);
    _noticeSubscription = _session.notices.listen(_showRemoteNotice);
    unawaited(_session.initialize());
    if (_role == RemoteRole.host) {
      unawaited(_findLocalAddresses());
    } else {
      _discoverySubscription = widget.discoveryService.devices.listen(
        (devices) {
          if (mounted) {
            setState(() {
              _discoveredDevices = devices;
              _discoveryError = null;
            });
          }
        },
        onError: (Object error) {
          if (mounted) {
            setState(() => _discoveryError = '附近设备发现失败：$error');
          }
        },
      );
      if (widget.settings.lanDiscoveryEnabled) {
        unawaited(_startBrowsing());
      }
    }
  }

  void _handleSettingsChanged() {
    if (_role != RemoteRole.controller) {
      if (mounted) setState(() {});
      return;
    }
    if (widget.settings.lanDiscoveryEnabled) {
      unawaited(_startBrowsing());
    } else {
      unawaited(_disableBrowsing());
    }
  }

  Future<void> _disableBrowsing() async {
    try {
      await widget.discoveryService.stopBrowsing();
    } catch (error) {
      if (mounted) {
        setState(() => _discoveryError = '停止附近设备发现失败：$error');
      }
    } finally {
      _discoveryActive = false;
      if (mounted) {
        setState(() {
          _discoveredDevices = const [];
          _isBrowsing = false;
        });
      }
    }
  }

  Future<void> _findLocalAddresses() async {
    try {
      final addresses = await widget.addressService.listUsableAddresses();
      if (mounted) {
        setState(() {
          _localAddresses = addresses;
          _addressError = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _localAddresses = const [];
          _addressError = '读取局域网地址失败：$error';
        });
      }
    }
  }

  Future<void> _startBrowsing() async {
    if (!widget.discoveryService.isSupported) {
      if (mounted) {
        setState(() => _discoveryError = '当前平台暂不支持局域网设备发现');
      }
      return;
    }
    if (_isBrowsing || _discoveryActive) {
      return;
    }
    if (mounted) {
      setState(() {
        _isBrowsing = true;
        _discoveryError = null;
      });
    }
    try {
      await widget.discoveryService.startBrowsing();
      _discoveryActive = true;
    } catch (error) {
      if (mounted) {
        setState(() => _discoveryError = '无法搜索附近设备：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _isBrowsing = false);
      }
    }
  }

  Future<void> _refreshDiscovery() async {
    try {
      await widget.discoveryService.stopBrowsing();
    } catch (_) {
      // Restarting discovery is best effort; the following start reports errors.
    } finally {
      _discoveryActive = false;
    }
    if (mounted) {
      setState(() => _discoveredDevices = const []);
    }
    await _startBrowsing();
    if (_discoveryError == null) {
      AppMessenger.show('附近设备列表已刷新', level: AppMessageLevel.success);
    }
  }

  void _selectDevice(DiscoveredDevice device) {
    _serverController.text = device.signalingUrl;
    setState(() => _discoveryError = null);
    AppMessenger.show('已选择 ${device.name}', level: AppMessageLevel.success);
  }

  void _showRemoteNotice(RemoteNotice notice) {
    final level = switch (notice.level) {
      RemoteNoticeLevel.info => AppMessageLevel.info,
      RemoteNoticeLevel.success => AppMessageLevel.success,
      RemoteNoticeLevel.warning => AppMessageLevel.warning,
      RemoteNoticeLevel.error => AppMessageLevel.error,
    };
    AppMessenger.show(notice.message, level: level);
  }

  Future<void> _connect({bool userInitiated = true}) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_role == RemoteRole.host && userInitiated) {
      _hostSharing.start();
      if (mounted) setState(() {});
    }
    await _session.connect(
      serverUrl: _serverController.text,
      roomCode: _roomController.text,
    );
  }

  Future<void> _disconnect() async {
    if (_role == RemoteRole.host) {
      _hostSharing.stop();
      if (mounted) setState(() {});
    }
    await _session.disconnect();
  }

  void _handleSessionChanged() {
    final previousState = _lastSessionState;
    _lastSessionState = _session.state;
    if (_desktopFullScreen && !_session.hasRemoteVideo) {
      unawaited(_setDesktopFullScreen(false, announce: false));
    }
    if (_role != RemoteRole.host) {
      _invitationLease.cancel();
      return;
    }

    final shouldRestart = _hostSharing.observeTransition(
      previous: previousState,
      next: _session.state,
    );
    if (previousState != RemoteSessionState.idle &&
        {
          RemoteSessionState.disconnected,
          RemoteSessionState.failed,
        }.contains(_session.state)) {
      _roomController.text = generateRoomCode();
    }
    if (shouldRestart) unawaited(_restartHostSharing());
    _reconcileInvitationLease();
    if (mounted) setState(() {});

    _reconcileHostPublication();
  }

  void _handleInvitationLeaseChanged() {
    if (mounted) setState(() {});
  }

  void _reconcileInvitationLease() {
    final expiresAt = _session.hostInvitationExpiresAt;
    if (_session.state == RemoteSessionState.waitingForPeer &&
        _hostSharing.sharingRequested &&
        expiresAt != null) {
      _invitationLease.arm(expiresAt);
    } else if (!_invitationLease.rotationPending) {
      _invitationLease.cancel();
    }
  }

  Future<void> _rotateHostInvitation() async {
    if (!mounted ||
        _role != RemoteRole.host ||
        !_hostSharing.sharingRequested ||
        _session.state != RemoteSessionState.waitingForPeer) {
      return;
    }
    final previousCode = _roomController.text;
    var nextCode = generateRoomCode();
    while (nextCode == previousCode) {
      nextCode = generateRoomCode();
    }
    _roomController.text = nextCode;
    AppMessenger.show('正在更新一次性连接码', level: AppMessageLevel.info);
    await _connect(userInitiated: false);
  }

  void _reconcileHostPublication() {
    if (!mounted || _role != RemoteRole.host || _publicationBusy) return;
    final shouldPublish = _session.state == RemoteSessionState.waitingForPeer;
    if (shouldPublish && !_isPublishing) {
      unawaited(_publishHost());
    } else if (!shouldPublish && _isPublishing) {
      unawaited(_stopPublishing());
    }
  }

  Future<void> _restartHostSharing() async {
    AppMessenger.show('上一会话已结束，正在生成新连接码并恢复共享', level: AppMessageLevel.info);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted || !_hostSharing.sharingRequested) return;
    await _connect(userInitiated: false);
  }

  Future<void> _publishHost() async {
    _publicationBusy = true;
    try {
      if (!widget.discoveryService.isSupported) {
        throw UnsupportedError('当前平台暂不支持局域网设备发布');
      }
      final endpoint = Uri.parse(_serverController.text.trim());
      await widget.discoveryService.publishHost(
        HostAdvertisement(
          deviceId: Platform.localHostname.toLowerCase(),
          name: Platform.localHostname,
          port: endpoint.hasPort
              ? endpoint.port
              : endpoint.scheme == 'wss'
              ? 443
              : 80,
          path: endpoint.path.isEmpty ? '/ws/signaling' : endpoint.path,
        ),
      );
      _isPublishing = true;
      _discoveryError = null;
      AppMessenger.show('本机已发布到局域网', level: AppMessageLevel.success);
    } catch (error) {
      _discoveryError = '发布局域网设备失败：$error';
      AppMessenger.show(_discoveryError!, level: AppMessageLevel.error);
    } finally {
      _publicationBusy = false;
      if (mounted) {
        setState(() {});
      }
    }
    if (_session.state != RemoteSessionState.waitingForPeer && _isPublishing) {
      await _stopPublishing();
    }
  }

  Future<void> _stopPublishing() async {
    _publicationBusy = true;
    try {
      await widget.discoveryService.stopPublishing();
    } catch (error) {
      _discoveryError = '停止发布局域网设备失败：$error';
    } finally {
      _isPublishing = false;
      _publicationBusy = false;
      if (mounted) {
        setState(() {});
      }
    }
    // A fast automatic reconnect may reach waitingForPeer while the previous
    // Bonjour publication is still being stopped. Reconcile once the native
    // operation has completed so the host cannot remain undiscoverable.
    _reconcileHostPublication();
  }

  @override
  void dispose() {
    if (_desktopFullScreen &&
        widget.windowModeController.supportsNativeFullScreen) {
      unawaited(_restoreWindowModeForDispose());
    }
    _session.removeListener(_handleSessionChanged);
    widget.settings.removeListener(_handleSettingsChanged);
    _invitationLease
      ..removeListener(_handleInvitationLeaseChanged)
      ..dispose();
    unawaited(_discoverySubscription?.cancel());
    unawaited(_noticeSubscription?.cancel());
    _serverController.dispose();
    _roomController.dispose();
    super.dispose();
  }

  Future<void> _restoreWindowModeForDispose() async {
    try {
      await widget.windowModeController.setFullScreen(false);
    } catch (_) {
      // The Windows engine may already be shutting down with the application.
    }
  }

  Future<bool> _setDesktopFullScreen(
    bool enabled, {
    bool announce = true,
  }) async {
    if (_desktopFullScreen == enabled) return true;
    if (_windowModeChanging ||
        !widget.windowModeController.supportsNativeFullScreen) {
      return false;
    }
    _windowModeChanging = true;
    try {
      await widget.windowModeController.setFullScreen(enabled);
      if (!mounted) return false;
      setState(() => _desktopFullScreen = enabled);
      widget.onDesktopFullScreenChanged?.call(enabled);
      return true;
    } catch (error) {
      if (mounted && announce) {
        AppMessenger.show(
          enabled ? '进入全屏失败：$error' : '退出全屏失败：$error',
          level: AppMessageLevel.error,
        );
      }
      return false;
    } finally {
      _windowModeChanging = false;
    }
  }

  RemoteDesktopPanel _buildRemoteDesktopPanel() {
    return RemoteDesktopPanel(
      key: _remoteDesktopPanelKey,
      session: _session,
      initialInputSettings: widget.settings.inputSettings,
      desktopFullScreen: _desktopFullScreen,
      onDesktopFullScreenChanged: _setDesktopFullScreen,
      onKeyboardModeChanged: (mode) =>
          unawaited(widget.settings.setKeyboardMode(mode)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _session,
      builder: (context, _) {
        if (_desktopFullScreen &&
            _role == RemoteRole.controller &&
            _session.hasRemoteVideo) {
          return ColoredBox(
            color: Colors.black,
            child: _buildRemoteDesktopPanel(),
          );
        }
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1160),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.capabilities.supportsRoleSwitching) ...[
                          SegmentedButton<RemoteRole>(
                            segments: const [
                              ButtonSegment(
                                value: RemoteRole.controller,
                                icon: Icon(Icons.desktop_windows_outlined),
                                label: Text('控制其他设备'),
                              ),
                              ButtonSegment(
                                value: RemoteRole.host,
                                icon: Icon(Icons.screen_share_outlined),
                                label: Text('共享本机'),
                              ),
                            ],
                            selected: {_role},
                            onSelectionChanged: _sessionIsActive
                                ? null
                                : (selection) =>
                                      widget.onRoleChanged(selection.single),
                          ),
                          const SizedBox(height: 20),
                        ],
                        Text(
                          _role == RemoteRole.host ? '共享本机' : '控制其他设备',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _role == RemoteRole.host
                              ? '创建五分钟有效的一次性连接码，控制端验证成功后自动共享。'
                              : '选择附近设备，或输入远程设备地址和六位连接码。',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1160),
                    child: Column(
                      children: [
                        _ConnectionCard(
                          role: _role,
                          serverController: _serverController,
                          roomController: _roomController,
                          session: _session,
                          localAddresses: _localAddresses,
                          addressError: _addressError,
                          discoveredDevices: _discoveredDevices,
                          discoveryError: _discoveryError,
                          isBrowsing: _isBrowsing,
                          isPublishing: _isPublishing,
                          hostSharingRequested: _hostSharing.sharingRequested,
                          hostRestarting: _hostSharing.rearming,
                          invitationStatus: _invitationLease.statusLabel,
                          invitationRefreshing:
                              _invitationLease.rotationPending,
                          settings: widget.settings,
                          onConnect: _connect,
                          onDisconnect: _disconnect,
                          onRefreshAddresses: _findLocalAddresses,
                          onRefreshDiscovery: _refreshDiscovery,
                          onRefreshRoomCode: _invitationLease.rotateNow,
                          onSelectDevice: _selectDevice,
                        ),
                        if (_role == RemoteRole.controller &&
                            _session.hasRemoteVideo) ...[
                          const SizedBox(height: 16),
                          _buildRemoteDesktopPanel(),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  bool get _sessionIsActive =>
      !{
        RemoteSessionState.idle,
        RemoteSessionState.disconnected,
        RemoteSessionState.failed,
      }.contains(_session.state) ||
      (_role == RemoteRole.host && _hostSharing.sharingRequested);
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.role,
    required this.serverController,
    required this.roomController,
    required this.session,
    required this.localAddresses,
    required this.addressError,
    required this.discoveredDevices,
    required this.discoveryError,
    required this.isBrowsing,
    required this.isPublishing,
    required this.hostSharingRequested,
    required this.hostRestarting,
    required this.invitationStatus,
    required this.invitationRefreshing,
    required this.settings,
    required this.onConnect,
    required this.onDisconnect,
    required this.onRefreshAddresses,
    required this.onRefreshDiscovery,
    required this.onRefreshRoomCode,
    required this.onSelectDevice,
  });

  final RemoteRole role;
  final TextEditingController serverController;
  final TextEditingController roomController;
  final RemoteSessionController session;
  final List<LanAddress>? localAddresses;
  final String? addressError;
  final List<DiscoveredDevice> discoveredDevices;
  final String? discoveryError;
  final bool isBrowsing;
  final bool isPublishing;
  final bool hostSharingRequested;
  final bool hostRestarting;
  final String invitationStatus;
  final bool invitationRefreshing;
  final AppSettingsController settings;
  final Future<void> Function() onConnect;
  final Future<void> Function() onDisconnect;
  final Future<void> Function() onRefreshAddresses;
  final Future<void> Function() onRefreshDiscovery;
  final Future<void> Function() onRefreshRoomCode;
  final ValueChanged<DiscoveredDevice> onSelectDevice;

  bool get _isActive => role == RemoteRole.host
      ? hostSharingRequested
      : !{
          RemoteSessionState.idle,
          RemoteSessionState.disconnected,
          RemoteSessionState.failed,
        }.contains(session.state);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (role == RemoteRole.host)
                _buildHostContent(
                  context,
                  twoColumns: constraints.maxWidth >= 820,
                )
              else
                _buildControllerContent(context),
              const SizedBox(height: 20),
              const Divider(height: 1),
              const SizedBox(height: 16),
              _buildStatus(context),
              const SizedBox(height: 16),
              _buildActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHostContent(BuildContext context, {required bool twoColumns}) {
    final credentials = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('连接凭证', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        const Text('正确连接码验证后会自动建立远程会话。'),
        const SizedBox(height: 18),
        _HostRoomCodeDisplay(code: roomController.text),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: Text(invitationStatus)),
            TextButton.icon(
              key: const ValueKey('refreshRoomCodeButton'),
              onPressed:
                  hostSharingRequested &&
                      session.state == RemoteSessionState.waitingForPeer &&
                      !invitationRefreshing
                  ? onRefreshRoomCode
                  : null,
              icon: invitationRefreshing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: const Text('刷新连接码'),
            ),
          ],
        ),
        if (settings.showAdvancedNetwork) ...[
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('signalingServerField'),
            controller: serverController,
            enabled: !_isActive,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '本机信令地址',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: 6),
          const Text('127.0.0.1 仅供本机服务使用。'),
        ],
      ],
    );
    final network = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('网络与发现', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(isPublishing ? '本机已发布，控制端可以自动发现。' : '开始共享后自动发布到局域网。'),
        const SizedBox(height: 18),
        _LanAddressList(
          addresses: localAddresses,
          error: addressError,
          onRefresh: onRefreshAddresses,
          showAll: settings.showAdvancedNetwork,
        ),
        if (discoveryError != null) ...[
          const SizedBox(height: 8),
          Text(
            discoveryError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (settings.showAdvancedNetwork) ...[
          const SizedBox(height: 8),
          const Text('需要先在本机启动 Java 控制平面。'),
        ],
      ],
    );
    if (!twoColumns) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [credentials, const SizedBox(height: 24), network],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 5, child: credentials),
        const SizedBox(width: 28),
        Expanded(flex: 4, child: network),
      ],
    );
  }

  Widget _buildControllerContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('连接设备', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        const Text('优先选择附近设备，也可以手动输入局域网地址。'),
        const SizedBox(height: 18),
        if (settings.lanDiscoveryEnabled) ...[
          _NearbyDevices(
            devices: discoveredDevices,
            error: discoveryError,
            isBrowsing: isBrowsing,
            enabled: !_isActive,
            onRefresh: onRefreshDiscovery,
            onSelect: onSelectDevice,
          ),
          const SizedBox(height: 16),
        ],
        TextField(
          key: const ValueKey('signalingServerField'),
          controller: serverController,
          enabled: !_isActive,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '手动信令地址',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('roomCodeField'),
          controller: roomController,
          enabled: !_isActive,
          onChanged: (_) => session.clearConnectionAttemptFeedback(),
          maxLength: 6,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: '六位连接码',
            prefixIcon: Icon(Icons.pin_outlined),
          ),
        ),
      ],
    );
  }

  Widget _buildStatus(BuildContext context) {
    return Row(
      children: [
        Icon(
          switch (session.state) {
            RemoteSessionState.failed => Icons.error_outline,
            RemoteSessionState.reconnecting => Icons.sync,
            _ => Icons.circle,
          },
          size: 14,
          color: switch (session.state) {
            RemoteSessionState.failed => Theme.of(context).colorScheme.error,
            RemoteSessionState.reconnecting => Theme.of(
              context,
            ).colorScheme.tertiary,
            _ => Theme.of(context).colorScheme.primary,
          },
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            role == RemoteRole.host && hostRestarting
                ? '上一会话已结束，正在恢复共享'
                : session.statusMessage,
          ),
        ),
      ],
    );
  }

  Widget _buildActions() {
    if (session.state == RemoteSessionState.awaitingApproval) {
      return Wrap(
        alignment: WrapAlignment.end,
        spacing: 10,
        runSpacing: 10,
        children: [
          OutlinedButton(onPressed: session.reject, child: const Text('拒绝')),
          FilledButton.icon(
            onPressed: session.approve,
            icon: const Icon(Icons.screen_share_outlined),
            label: const Text('允许查看和控制'),
          ),
        ],
      );
    }
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 10,
      runSpacing: 10,
      children: [
        if (role == RemoteRole.host)
          OutlinedButton.icon(
            onPressed: session.accessibilityGranted == true
                ? () => session.refreshHostPermissions(announce: true)
                : session.requestHostInputPermission,
            icon: Icon(
              session.accessibilityGranted == true
                  ? Icons.check_circle_outline
                  : Icons.admin_panel_settings_outlined,
            ),
            label: Text(
              session.accessibilityGranted == true ? '输入权限已就绪' : '设置输入权限',
            ),
          ),
        if (_isActive)
          FilledButton.tonalIcon(
            onPressed: onDisconnect,
            icon: Icon(
              role == RemoteRole.host
                  ? Icons.stop_circle_outlined
                  : Icons.link_off,
            ),
            label: Text(role == RemoteRole.host ? '停止共享' : '断开'),
          )
        else
          FilledButton.icon(
            onPressed: onConnect,
            icon: Icon(
              role == RemoteRole.host
                  ? Icons.sensors
                  : Icons.desktop_windows_outlined,
            ),
            label: Text(role == RemoteRole.host ? '开始共享' : '连接远程设备'),
          ),
      ],
    );
  }
}

class _HostRoomCodeDisplay extends StatelessWidget {
  const _HostRoomCodeDisplay({required this.code});

  final String code;

  Future<void> _copy() async {
    if (code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    AppMessenger.show('连接码已复制', level: AppMessageLevel.success);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '六位连接码 $code',
      value: code,
      child: InputDecorator(
        key: const ValueKey('hostRoomCodeField'),
        decoration: InputDecoration(
          labelText: '六位连接码',
          prefixIcon: const Icon(Icons.pin_outlined),
          suffixIcon: IconButton(
            key: const ValueKey('copyRoomCodeButton'),
            tooltip: '复制连接码',
            onPressed: code.isEmpty ? null : _copy,
            icon: const Icon(Icons.copy_outlined),
          ),
        ),
        child: SelectableText(
          code,
          key: const ValueKey('hostRoomCodeText'),
          maxLines: 1,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 5,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

class _LanAddressList extends StatelessWidget {
  const _LanAddressList({
    required this.addresses,
    required this.error,
    required this.onRefresh,
    required this.showAll,
  });

  final List<LanAddress>? addresses;
  final String? error;
  final Future<void> Function() onRefresh;
  final bool showAll;

  @override
  Widget build(BuildContext context) {
    final values = addresses;
    final visibleValues = values == null || showAll || values.isEmpty
        ? values
        : [
            values.where((value) => value.recommended).firstOrNull ??
                values.first,
          ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    showAll ? '控制端可用连接地址' : '推荐连接地址',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '刷新网络地址',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else if (values == null)
              const LinearProgressIndicator()
            else if (values.isEmpty)
              const Text('未找到可用 IPv4 地址，请检查本机网络连接。')
            else
              for (final address in visibleValues!)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    address.recommended
                        ? Icons.wifi_outlined
                        : Icons.lan_outlined,
                  ),
                  title: SelectableText(address.signalingUrl()),
                  subtitle: Text(
                    address.recommended
                        ? '${address.interfaceName} · 推荐'
                        : address.interfaceName,
                  ),
                  trailing: IconButton(
                    tooltip: '复制连接地址',
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: address.signalingUrl()),
                      );
                      AppMessenger.show(
                        '连接地址已复制',
                        level: AppMessageLevel.success,
                      );
                    },
                    icon: const Icon(Icons.copy_outlined),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _NearbyDevices extends StatelessWidget {
  const _NearbyDevices({
    required this.devices,
    required this.error,
    required this.isBrowsing,
    required this.enabled,
    required this.onRefresh,
    required this.onSelect,
  });

  final List<DiscoveredDevice> devices;
  final String? error;
  final bool isBrowsing;
  final bool enabled;
  final Future<void> Function() onRefresh;
  final ValueChanged<DiscoveredDevice> onSelect;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '附近设备',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '刷新附近设备',
                  onPressed: enabled && !isBrowsing ? onRefresh : null,
                  icon: isBrowsing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else if (devices.isEmpty)
              const Text('正在搜索；也可继续使用下方手动地址。')
            else
              for (final device in devices)
                ListTile(
                  enabled: enabled,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.devices_outlined),
                  title: Text(device.name),
                  subtitle: Text('${device.host}:${device.port}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: enabled ? () => onSelect(device) : null,
                ),
          ],
        ),
      ),
    );
  }
}
