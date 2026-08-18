import 'dart:async';
import 'dart:io';

import 'package:cross_desktop_remote/core/discovery/lan_discovery_service.dart';
import 'package:cross_desktop_remote/core/network/lan_address_service.dart';
import 'package:cross_desktop_remote/core/platform/device_capabilities.dart';
import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/features/remote/application/host_sharing_lifecycle.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_desktop_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.session,
    required this.discoveryService,
    required this.capabilities,
    required this.onRoleChanged,
    this.addressService = const LanAddressService(),
  });

  final RemoteSessionController session;
  final LanDiscoveryService discoveryService;
  final DeviceCapabilities capabilities;
  final ValueChanged<RemoteRole> onRoleChanged;
  final LanAddressService addressService;

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
  bool _isPublishing = false;
  bool _publicationBusy = false;
  final HostSharingLifecycle _hostSharing = HostSharingLifecycle();
  late RemoteSessionState _lastSessionState = _session.state;

  @override
  void initState() {
    super.initState();
    _session.addListener(_handleSessionChanged);
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
      unawaited(_startBrowsing());
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
    if (_isBrowsing) {
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
    if (_role != RemoteRole.host) return;

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
    if (mounted) setState(() {});

    _reconcileHostPublication();
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
    _session.removeListener(_handleSessionChanged);
    unawaited(_discoverySubscription?.cancel());
    unawaited(_noticeSubscription?.cancel());
    _serverController.dispose();
    _roomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _session,
      builder: (context, _) {
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              sliver: SliverToBoxAdapter(
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
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
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
                          onConnect: _connect,
                          onDisconnect: _disconnect,
                          onRefreshAddresses: _findLocalAddresses,
                          onRefreshDiscovery: _refreshDiscovery,
                          onSelectDevice: _selectDevice,
                        ),
                        if (_role == RemoteRole.controller &&
                            _session.hasRemoteVideo) ...[
                          const SizedBox(height: 16),
                          RemoteDesktopPanel(session: _session),
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
    required this.onConnect,
    required this.onDisconnect,
    required this.onRefreshAddresses,
    required this.onRefreshDiscovery,
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
  final Future<void> Function() onConnect;
  final Future<void> Function() onDisconnect;
  final Future<void> Function() onRefreshAddresses;
  final Future<void> Function() onRefreshDiscovery;
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              role == RemoteRole.host ? '本机共享' : '远程控制',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            if (role == RemoteRole.controller) ...[
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
              decoration: InputDecoration(
                labelText: role == RemoteRole.host ? '本机信令地址' : '手动信令地址',
                prefixIcon: const Icon(Icons.dns_outlined),
              ),
            ),
            if (role == RemoteRole.host) ...[
              const SizedBox(height: 6),
              const Text('127.0.0.1 仅供本机服务使用；其他设备请使用下方局域网地址。'),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('roomCodeField'),
              controller: roomController,
              enabled: role == RemoteRole.controller && !_isActive,
              maxLength: 6,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: '六位连接码',
                prefixIcon: const Icon(Icons.pin_outlined),
                suffixIcon: role == RemoteRole.host
                    ? IconButton(
                        tooltip: '复制连接码',
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: roomController.text),
                          );
                          AppMessenger.show(
                            '连接码已复制',
                            level: AppMessageLevel.success,
                          );
                        },
                        icon: const Icon(Icons.copy_outlined),
                      )
                    : null,
              ),
            ),
            if (role == RemoteRole.host) ...[
              _LanAddressList(
                addresses: localAddresses,
                error: addressError,
                onRefresh: onRefreshAddresses,
              ),
              const SizedBox(height: 8),
              Text(isPublishing ? '已在局域网发布本机，其他控制端可自动发现。' : '开始共享后会发布本机。'),
              if (discoveryError != null)
                Text(
                  discoveryError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 8),
              const Text('需要先在本机启动 Java 控制平面。'),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  session.state == RemoteSessionState.failed
                      ? Icons.error_outline
                      : Icons.circle,
                  size: 14,
                  color: session.state == RemoteSessionState.failed
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
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
            ),
            const SizedBox(height: 16),
            if (role == RemoteRole.host) ...[
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
                  session.accessibilityGranted == true
                      ? '远程输入权限已就绪'
                      : '设置远程输入权限',
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (session.state == RemoteSessionState.awaitingApproval) ...[
              FilledButton.icon(
                onPressed: session.approve,
                icon: const Icon(Icons.screen_share_outlined),
                label: const Text('允许查看和控制'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: session.reject,
                child: const Text('拒绝'),
              ),
            ] else if (_isActive) ...[
              OutlinedButton.icon(
                onPressed: onDisconnect,
                icon: Icon(
                  role == RemoteRole.host
                      ? Icons.stop_circle_outlined
                      : Icons.link_off,
                ),
                label: Text(role == RemoteRole.host ? '停止共享本机' : '断开'),
              ),
            ] else ...[
              FilledButton.icon(
                onPressed: onConnect,
                icon: Icon(
                  role == RemoteRole.host
                      ? Icons.sensors
                      : Icons.desktop_windows_outlined,
                ),
                label: Text(role == RemoteRole.host ? '开始共享本机' : '连接远程设备'),
              ),
            ],
          ],
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
  });

  final List<LanAddress>? addresses;
  final String? error;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final values = addresses;
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
                    '控制端可用连接地址',
                    style: TextStyle(fontWeight: FontWeight.w600),
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
              for (final address in values)
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
