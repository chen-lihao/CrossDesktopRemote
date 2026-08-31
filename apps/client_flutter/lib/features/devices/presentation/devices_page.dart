import 'dart:async';
import 'dart:io';

import 'package:cross_desktop_remote/core/discovery/lan_discovery_service.dart';
import 'package:cross_desktop_remote/core/identity/device_identity.dart';
import 'package:cross_desktop_remote/core/network/lan_address_service.dart';
import 'package:cross_desktop_remote/core/platform/desktop_window_mode.dart';
import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/features/remote/application/host_availability_controller.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/features/remote/presentation/explicit_file_transfer_center.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_desktop_panel.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.controllerSession,
    required this.hostAvailability,
    required this.discoveryService,
    required this.identity,
    required this.settings,
    this.addressService = const LanAddressService(),
    this.windowModeController = const PlatformDesktopWindowModeController(),
    this.onDesktopFullScreenChanged,
  });

  final RemoteSessionController controllerSession;
  final HostAvailabilityController? hostAvailability;
  final LanDiscoveryService discoveryService;
  final DeviceIdentityController identity;
  final AppSettingsController settings;
  final LanAddressService addressService;
  final DesktopWindowModeController windowModeController;
  final ValueChanged<bool>? onDesktopFullScreenChanged;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  RemoteSessionController get _controllerSession => widget.controllerSession;
  HostAvailabilityController? get _hostAvailability => widget.hostAvailability;
  RemoteSessionController? get _hostSession => _hostAvailability?.session;
  bool get _controllerSessionIsActive => !{
    RemoteSessionState.idle,
    RemoteSessionState.disconnected,
    RemoteSessionState.failed,
  }.contains(_controllerSession.state);

  late final TextEditingController _serverController = TextEditingController(
    text: widget.settings.signalingServerUrl,
  );
  late final TextEditingController _controllerCodeController =
      TextEditingController(text: '');
  late final TextEditingController _hostCodeController = TextEditingController(
    text: '',
  );
  StreamSubscription<List<DiscoveredDevice>>? _discoverySubscription;
  final List<StreamSubscription<RemoteNotice>> _noticeSubscriptions = [];
  List<LanAddress>? _localAddresses;
  List<DiscoveredDevice> _discoveredDevices = const [];
  LanDiscoveryDiagnostics? _lanDiscoveryDiagnostics;
  String? _addressError;
  String? _discoveryError;
  bool _isBrowsing = false;
  bool _discoveryActive = false;
  bool _isPublishing = false;
  bool _publicationBusy = false;
  bool _serverTesting = false;
  String? _serverTestStatus;
  bool _desktopFullScreen = false;
  bool _windowModeChanging = false;
  final GlobalKey _remoteDesktopPanelKey = GlobalKey(
    debugLabel: 'persistent-remote-desktop-panel',
  );

  @override
  void initState() {
    super.initState();
    _controllerSession.addListener(_handleControllerSessionChanged);
    _hostAvailability?.addListener(_handleHostAvailabilityChanged);
    widget.settings.addListener(_handleSettingsChanged);
    _noticeSubscriptions.add(
      _controllerSession.notices.listen(_showRemoteNotice),
    );
    final host = _hostSession;
    if (host != null) {
      _noticeSubscriptions.add(host.notices.listen(_showRemoteNotice));
    }
    _discoverySubscription = widget.discoveryService.devices.listen(
      (devices) {
        if (mounted) {
          setState(() {
            _discoveredDevices = visibleLanDevices(
              devices: devices,
              localDeviceId: widget.identity.deviceId,
            );
            _discoveryError = null;
          });
          unawaited(_refreshDiscoveryDiagnostics());
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
    unawaited(_findLocalAddresses());
  }

  void _handleSettingsChanged() {
    if (!_controllerSessionIsActive &&
        _serverController.text != widget.settings.signalingServerUrl) {
      _serverController.value = TextEditingValue(
        text: widget.settings.signalingServerUrl,
        selection: TextSelection.collapsed(
          offset: widget.settings.signalingServerUrl.length,
        ),
      );
    }
    if (widget.settings.lanDiscoveryEnabled) {
      unawaited(_startBrowsing());
      _reconcileHostPublication();
    } else {
      unawaited(_disableBrowsing());
      if (_isPublishing) {
        unawaited(_stopPublishing());
      }
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
          _lanDiscoveryDiagnostics = null;
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
      await _refreshDiscoveryDiagnostics();
    }
  }

  Future<void> _refreshDiscoveryDiagnostics() async {
    if (!mounted || !widget.discoveryService.isSupported) return;
    LanDiscoveryDiagnostics diagnostics;
    if (Platform.isWindows) {
      try {
        diagnostics = await widget.discoveryService.getDiagnostics();
      } catch (error) {
        diagnostics = LanDiscoveryDiagnostics(
          browsing: _discoveryActive,
          publishing: _isPublishing,
          discoveredCount: _discoveredDevices.length,
          resolvingCount: 0,
          lastError: '读取发现状态失败：$error',
        );
      }
    } else {
      diagnostics = LanDiscoveryDiagnostics(
        browsing: _discoveryActive,
        publishing: _isPublishing,
        discoveredCount: _discoveredDevices.length,
        resolvingCount: 0,
        lastError: _discoveryError ?? '',
      );
    }
    if (mounted) setState(() => _lanDiscoveryDiagnostics = diagnostics);
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
    await _refreshDiscoveryDiagnostics();
    if (_discoveryError == null) {
      AppMessenger.show('附近设备列表已刷新', level: AppMessageLevel.success);
    }
  }

  Future<void> _testSignalingServer() async {
    if (_serverTesting) return;
    setState(() {
      _serverTesting = true;
      _serverTestStatus = null;
    });
    final stopwatch = Stopwatch()..start();
    try {
      final normalized = normalizeSignalingServerUrl(_serverController.text);
      final socket = await WebSocket.connect(
        buildSignalingProbeUri(normalized).toString(),
      ).timeout(const Duration(seconds: 5));
      await socket.close(WebSocketStatus.normalClosure, 'probe-complete');
      stopwatch.stop();
      _serverTestStatus =
          'WebSocket 握手成功 · ${stopwatch.elapsedMilliseconds} ms';
      await widget.settings.setSignalingServerUrl(normalized);
      AppMessenger.show(_serverTestStatus!, level: AppMessageLevel.success);
    } catch (error) {
      _serverTestStatus = '信令服务器不可达：$error';
      AppMessenger.show(_serverTestStatus!, level: AppMessageLevel.error);
    } finally {
      if (mounted) setState(() => _serverTesting = false);
    }
  }

  void _selectDevice(DiscoveredDevice device) {
    final currentServer = _serverController.text.trim();
    final selectedServer = signalingUrlForSelectedDevice(
      currentServerUrl: currentServer,
      device: device,
    );
    if (selectedServer.isNotEmpty && selectedServer != currentServer) {
      _serverController.value = TextEditingValue(
        text: selectedServer,
        selection: TextSelection.collapsed(offset: selectedServer.length),
      );
      unawaited(widget.settings.setSignalingServerUrl(selectedServer));
      AppMessenger.show(
        '已采用 ${device.name} 声明的信令服务器',
        level: AppMessageLevel.info,
      );
    }
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
    final transferSession = [_controllerSession, ?_hostSession]
        .where((session) => session.pendingIncomingFileTransferCount > 0)
        .firstOrNull;
    final incomingFileTransfer =
        notice.message == '收到文件传输请求' && transferSession != null;
    AppMessenger.show(
      notice.message,
      level: level,
      actionLabel: incomingFileTransfer ? '查看' : null,
      onAction: incomingFileTransfer
          ? () {
              if (!mounted) return;
              showExplicitFileTransferCenter(context, transferSession);
            }
          : null,
    );
  }

  Future<void> _connectController() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await _controllerSession.connect(
      serverUrl: _serverController.text,
      roomCode: _controllerCodeController.text,
    );
  }

  Future<void> _disconnectController() => _controllerSession.disconnect();

  Future<void> _disconnectIncomingSession() async {
    await _hostSession?.disconnect();
  }

  void _handleControllerSessionChanged() {
    if (_desktopFullScreen && !_controllerSession.hasRemoteVideo) {
      unawaited(_setDesktopFullScreen(false, announce: false));
    }
    if ({
      RemoteSessionState.disconnected,
      RemoteSessionState.failed,
    }.contains(_controllerSession.state)) {
      _controllerCodeController.clear();
    }
    if (mounted) setState(() {});
  }

  void _handleHostAvailabilityChanged() {
    final code = _hostSession?.hostInvitationCode ?? '';
    if (code != _hostCodeController.text) {
      _hostCodeController.text = code;
    }
    _reconcileHostPublication();
    if (mounted) setState(() {});
  }

  Future<void> _rotateHostInvitation() async {
    final availability = _hostAvailability;
    if (!mounted || availability == null || !availability.available) return;
    AppMessenger.show('正在向信令服务器申请新连接码', level: AppMessageLevel.info);
    try {
      await availability.invitationLease.rotateNow();
    } catch (error) {
      AppMessenger.show('刷新连接码失败：$error', level: AppMessageLevel.error);
    }
  }

  void _reconcileHostPublication() {
    final availability = _hostAvailability;
    if (!mounted || availability == null || _publicationBusy) return;
    final shouldPublish =
        widget.settings.lanDiscoveryEnabled &&
        availability.desiredOnline &&
        (availability.session.state == RemoteSessionState.waitingForPeer ||
            (_isPublishing &&
                {
                  RemoteSessionState.connecting,
                  RemoteSessionState.streaming,
                }.contains(availability.session.state)));
    if (shouldPublish && !_isPublishing) {
      unawaited(_publishHost());
    } else if (!shouldPublish && _isPublishing) {
      unawaited(_stopPublishing());
    }
  }

  Future<void> _publishHost() async {
    _publicationBusy = true;
    try {
      if (!widget.discoveryService.isSupported) {
        throw UnsupportedError('当前平台暂不支持局域网设备发布');
      }
      final endpoint = Uri.parse(_serverController.text.trim());
      var advertisedEndpoint = endpoint;
      if (const {'127.0.0.1', 'localhost', '::1'}.contains(endpoint.host)) {
        var addresses = _localAddresses;
        if (addresses == null || addresses.isEmpty) {
          addresses = await widget.addressService.listUsableAddresses();
          if (mounted) _localAddresses = addresses;
        }
        final address =
            addresses.where((value) => value.recommended).firstOrNull ??
            addresses.firstOrNull;
        if (address == null) {
          throw StateError('信令服务器使用本机回环地址，但未找到可发布的局域网地址');
        }
        advertisedEndpoint = endpoint.replace(host: address.address);
      }
      await widget.discoveryService.publishHost(
        HostAdvertisement(
          deviceId: widget.identity.deviceId,
          name: Platform.localHostname,
          port: endpoint.hasPort
              ? endpoint.port
              : endpoint.scheme == 'wss'
              ? 443
              : 80,
          path: endpoint.path.isEmpty ? '/ws/signaling' : endpoint.path,
          version: '2',
          platform: Platform.operatingSystem,
          signalingProfileId: signalingProfileIdForUrl(
            advertisedEndpoint.toString(),
          ),
          rendezvousUrl: advertisedEndpoint.toString(),
        ),
      );
      _isPublishing = true;
      _discoveryError = null;
      await _refreshDiscoveryDiagnostics();
      AppMessenger.show('本机已上线并发布到局域网', level: AppMessageLevel.success);
    } catch (error) {
      _discoveryError = '发布局域网设备失败：$error';
      AppMessenger.show(_discoveryError!, level: AppMessageLevel.error);
    } finally {
      _publicationBusy = false;
      if (mounted) {
        setState(() {});
      }
    }
    _reconcileHostPublication();
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
      await _refreshDiscoveryDiagnostics();
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
    _controllerSession.removeListener(_handleControllerSessionChanged);
    _hostAvailability?.removeListener(_handleHostAvailabilityChanged);
    widget.settings.removeListener(_handleSettingsChanged);
    unawaited(_discoverySubscription?.cancel());
    for (final subscription in _noticeSubscriptions) {
      unawaited(subscription.cancel());
    }
    _serverController.dispose();
    _controllerCodeController.dispose();
    _hostCodeController.dispose();
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
      session: _controllerSession,
      initialInputSettings: widget.settings.inputSettings,
      desktopFullScreen: _desktopFullScreen,
      onDesktopFullScreenChanged: _setDesktopFullScreen,
      onKeyboardModeChanged: (mode) =>
          unawaited(widget.settings.setKeyboardMode(mode)),
      onTextInputModeChanged: (mode) =>
          unawaited(widget.settings.setTextInputMode(mode)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_controllerSession, ?_hostAvailability]),
      builder: (context, _) {
        if (_desktopFullScreen && _controllerSession.hasRemoteVideo) {
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
                        Text(
                          '设备',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text('本机在线与控制其他设备相互独立；只有连接码验证成功后才开始屏幕采集。'),
                        const SizedBox(height: 16),
                        _DeviceIdentityCard(identity: widget.identity),
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
                        if (_hostAvailability != null) ...[
                          _buildHostConnectionCard(),
                          const SizedBox(height: 16),
                        ] else ...[
                          const _UnsupportedHostCard(),
                          const SizedBox(height: 16),
                        ],
                        _buildControllerConnectionCard(),
                        if (_controllerSession.hasRemoteVideo) ...[
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

  _ConnectionCard _buildHostConnectionCard() {
    final availability = _hostAvailability!;
    return _ConnectionCard(
      role: RemoteRole.host,
      serverController: _serverController,
      roomController: _hostCodeController,
      session: availability.session,
      localAddresses: _localAddresses,
      addressError: _addressError,
      discoveredDevices: _discoveredDevices,
      discoveryError: _discoveryError,
      discoveryEmptyHint: lanDiscoveryEmptyHint(
        platform: Platform.operatingSystem,
      ),
      discoveryDiagnostics: _lanDiscoveryDiagnostics,
      isBrowsing: _isBrowsing,
      isPublishing: _isPublishing,
      hostSharingRequested: availability.desiredOnline,
      hostRestarting: availability.starting || availability.reconnecting,
      invitationStatus: availability.statusLabel,
      invitationRefreshing: availability.invitationLease.rotationPending,
      settings: widget.settings,
      onConnect: availability.ensureOnline,
      onDisconnect: _disconnectIncomingSession,
      onRefreshAddresses: _findLocalAddresses,
      onRefreshDiscovery: _refreshDiscovery,
      onRefreshRoomCode: _rotateHostInvitation,
      onSelectDevice: _selectDevice,
      onServerChanged: _setServerUrl,
      onTestServer: _testSignalingServer,
      serverTesting: _serverTesting,
      serverTestStatus: _serverTestStatus,
    );
  }

  _ConnectionCard _buildControllerConnectionCard() {
    return _ConnectionCard(
      role: RemoteRole.controller,
      serverController: _serverController,
      roomController: _controllerCodeController,
      session: _controllerSession,
      localAddresses: _localAddresses,
      addressError: _addressError,
      discoveredDevices: _discoveredDevices,
      discoveryError: _discoveryError,
      discoveryEmptyHint: lanDiscoveryEmptyHint(
        platform: Platform.operatingSystem,
      ),
      discoveryDiagnostics: _lanDiscoveryDiagnostics,
      isBrowsing: _isBrowsing,
      isPublishing: _isPublishing,
      hostSharingRequested: false,
      hostRestarting: false,
      invitationStatus: '',
      invitationRefreshing: false,
      settings: widget.settings,
      onConnect: _connectController,
      onDisconnect: _disconnectController,
      onRefreshAddresses: _findLocalAddresses,
      onRefreshDiscovery: _refreshDiscovery,
      onRefreshRoomCode: _rotateHostInvitation,
      onSelectDevice: _selectDevice,
      onServerChanged: _setServerUrl,
      onTestServer: _testSignalingServer,
      serverTesting: _serverTesting,
      serverTestStatus: _serverTestStatus,
    );
  }

  void _setServerUrl(String value) {
    unawaited(widget.settings.setSignalingServerUrl(value));
  }
}

class _UnsupportedHostCard extends StatelessWidget {
  const _UnsupportedHostCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: ListTile(
        leading: Icon(Icons.info_outline),
        title: Text('允许远程访问'),
        subtitle: Text('当前平台暂不支持作为桌面被控端；机器码仍可用于设备识别和后续可信设备功能。'),
      ),
    );
  }
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
    required this.discoveryEmptyHint,
    required this.discoveryDiagnostics,
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
    required this.onServerChanged,
    required this.onTestServer,
    required this.serverTesting,
    required this.serverTestStatus,
  });

  final RemoteRole role;
  final TextEditingController serverController;
  final TextEditingController roomController;
  final RemoteSessionController session;
  final List<LanAddress>? localAddresses;
  final String? addressError;
  final List<DiscoveredDevice> discoveredDevices;
  final String? discoveryError;
  final String discoveryEmptyHint;
  final LanDiscoveryDiagnostics? discoveryDiagnostics;
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
  final ValueChanged<String> onServerChanged;
  final Future<void> Function() onTestServer;
  final bool serverTesting;
  final String? serverTestStatus;

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
              if (role == RemoteRole.host &&
                  session.localExplicitFileTransferSupported &&
                  (session.remoteSupportsExplicitFileTransferV1 ||
                      session.fileTransferTasks.isNotEmpty)) ...[
                const SizedBox(height: 16),
                HostFileTransferSection(session: session),
              ],
              const SizedBox(height: 16),
              _buildActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHostContent(BuildContext context, {required bool twoColumns}) {
    final canRegisterHost = {
      RemoteSessionState.idle,
      RemoteSessionState.disconnected,
      RemoteSessionState.failed,
    }.contains(session.state);
    final invitationConsumed =
        hostSharingRequested &&
        roomController.text.isNotEmpty &&
        session.state != RemoteSessionState.waitingForPeer;
    final credentials = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('允许远程访问', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        const Text('在线状态只连接信令服务，不采集屏幕；连接码验证成功后才建立远程会话。'),
        const SizedBox(height: 18),
        _HostRoomCodeDisplay(code: roomController.text),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: Text(invitationStatus)),
            TextButton.icon(
              key: const ValueKey('refreshRoomCodeButton'),
              onPressed: invitationRefreshing
                  ? null
                  : session.state == RemoteSessionState.waitingForPeer
                  ? onRefreshRoomCode
                  : canRegisterHost
                  ? onConnect
                  : null,
              icon: invitationRefreshing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: Text(
                roomController.text.isEmpty
                    ? '生成连接码'
                    : invitationConsumed
                    ? '当前码已使用'
                    : '刷新连接码',
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('hostSignalingServerField'),
          controller: serverController,
          enabled: canRegisterHost,
          onChanged: onServerChanged,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: '信令服务器',
            prefixIcon: const Icon(Icons.dns_outlined),
            suffixIcon: IconButton(
              tooltip: '测试 WebSocket 信令服务',
              onPressed: serverTesting ? null : onTestServer,
              icon: serverTesting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_ping),
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Text('控制端和被控端必须使用同一个信令服务器；127.0.0.1 仅表示当前设备。'),
        if (serverTestStatus != null) ...[
          const SizedBox(height: 4),
          Text(serverTestStatus!),
        ],
      ],
    );
    final network = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('网络与发现', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(isPublishing ? '本机在线；发布与附近设备浏览同时运行。' : '连接信令服务后自动发布到局域网。'),
        if (discoveredDevices.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('同时发现 ${discoveredDevices.length} 台其他设备。'),
        ],
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
        if (settings.showAdvancedNetwork && discoveryDiagnostics != null) ...[
          const SizedBox(height: 8),
          Text('发现诊断：${discoveryDiagnostics!.label}'),
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
        Text('控制其他设备', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        const Text('附近设备发现用于找到被控端；信令服务可以在 Mac、Windows 或独立公网服务器上。'),
        const SizedBox(height: 18),
        if (settings.lanDiscoveryEnabled) ...[
          _NearbyDevices(
            devices: discoveredDevices,
            error: discoveryError,
            emptyHint: discoveryEmptyHint,
            diagnostics: discoveryDiagnostics,
            isBrowsing: isBrowsing,
            enabled: !_isActive,
            currentServerUrl: serverController.text.trim(),
            onRefresh: onRefreshDiscovery,
            onSelect: onSelectDevice,
          ),
          const SizedBox(height: 16),
          const Text('点击设备会采用它声明的信令地址，但仍需输入一次性连接码。mDNS 被禁用时请使用手动地址。'),
          const SizedBox(height: 12),
        ],
        TextField(
          key: const ValueKey('signalingServerField'),
          controller: serverController,
          enabled: !_isActive,
          onChanged: onServerChanged,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration:
              const InputDecoration(
                labelText: '手动信令地址',
                prefixIcon: Icon(Icons.dns_outlined),
              ).copyWith(
                suffixIcon: IconButton(
                  tooltip: '测试信令服务器',
                  onPressed: serverTesting ? null : onTestServer,
                  icon: serverTesting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_ping),
                ),
              ),
        ),
        if (serverTestStatus != null) ...[
          const SizedBox(height: 4),
          Text(serverTestStatus!),
        ],
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
    final hostHasPeer =
        role == RemoteRole.host &&
        {
          RemoteSessionState.connecting,
          RemoteSessionState.streaming,
          RemoteSessionState.reconnecting,
        }.contains(session.state);
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
        if (role == RemoteRole.host)
          OutlinedButton.icon(
            onPressed: session.screenCaptureGranted
                ? () => session.refreshHostPermissions(announce: true)
                : session.requestHostScreenCapturePermission,
            icon: Icon(
              session.screenCaptureGranted
                  ? Icons.check_circle_outline
                  : Icons.screen_share_outlined,
            ),
            label: Text(session.screenCaptureGranted ? '录屏权限已就绪' : '设置录屏权限'),
          ),
        if (role == RemoteRole.host && hostHasPeer)
          FilledButton.tonalIcon(
            onPressed: onDisconnect,
            icon: const Icon(Icons.link_off),
            label: const Text('断开当前会话'),
          )
        else if (role == RemoteRole.controller && _isActive)
          FilledButton.tonalIcon(
            onPressed: onDisconnect,
            icon: const Icon(Icons.link_off),
            label: const Text('断开'),
          )
        else if (role == RemoteRole.controller)
          FilledButton.icon(
            onPressed: onConnect,
            icon: const Icon(Icons.desktop_windows_outlined),
            label: const Text('连接远程设备'),
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

class _DeviceIdentityCard extends StatelessWidget {
  const _DeviceIdentityCard({required this.identity});

  final DeviceIdentityController identity;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: identity,
      builder: (context, _) => Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: const Text('本机机器码'),
          subtitle: SelectableText(
            identity.loaded ? identity.machineCode : '正在创建设备身份',
            key: const ValueKey('machineCodeText'),
          ),
          trailing: IconButton(
            key: const ValueKey('copyMachineCodeButton'),
            tooltip: '复制机器码',
            onPressed: !identity.loaded
                ? null
                : () async {
                    await Clipboard.setData(
                      ClipboardData(text: identity.machineCode),
                    );
                    AppMessenger.show('机器码已复制', level: AppMessageLevel.success);
                  },
            icon: const Icon(Icons.copy_outlined),
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
    required this.emptyHint,
    required this.diagnostics,
    required this.isBrowsing,
    required this.enabled,
    required this.currentServerUrl,
    required this.onRefresh,
    required this.onSelect,
  });

  final List<DiscoveredDevice> devices;
  final String? error;
  final String emptyHint;
  final LanDiscoveryDiagnostics? diagnostics;
  final bool isBrowsing;
  final bool enabled;
  final String currentServerUrl;
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(emptyHint),
                  if (diagnostics case final value?) ...[
                    const SizedBox(height: 6),
                    Text(
                      value.label,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              )
            else
              for (final device in devices)
                ListTile(
                  enabled: enabled,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.devices_outlined),
                  title: Text(device.name),
                  subtitle: Text(
                    [
                      device.platform,
                      if (device.rendezvousUrl.isNotEmpty)
                        signalingUrlForSelectedDevice(
                                  currentServerUrl: currentServerUrl,
                                  device: device,
                                ) ==
                                currentServerUrl.trim()
                            ? '使用当前信令服务'
                            : '点击后切换至设备信令服务',
                      '${device.host}:${device.port}',
                    ].join(' · '),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: enabled ? () => onSelect(device) : null,
                ),
          ],
        ),
      ),
    );
  }
}
