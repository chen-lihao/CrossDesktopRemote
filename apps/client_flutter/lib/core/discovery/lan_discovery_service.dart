import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

const lanDiscoveryServiceType = '_cdrremote._tcp';

class LanDiscoveryDiagnostics {
  const LanDiscoveryDiagnostics({
    required this.browsing,
    required this.publishing,
    required this.discoveredCount,
    required this.resolvingCount,
    this.browseCallbackCount = 0,
    this.ptrRecordCount = 0,
    this.resolveStartedCount = 0,
    this.resolveSucceededCount = 0,
    this.registrationSucceededCount = 0,
    this.activeRegistrationAddress = '',
    this.lastError = '',
  });

  factory LanDiscoveryDiagnostics.fromMap(Map<Object?, Object?> value) {
    return LanDiscoveryDiagnostics(
      browsing: value['browsing'] == true,
      publishing: value['publishing'] == true,
      discoveredCount: (value['discoveredCount'] as num?)?.toInt() ?? 0,
      resolvingCount: (value['resolvingCount'] as num?)?.toInt() ?? 0,
      browseCallbackCount: (value['browseCallbackCount'] as num?)?.toInt() ?? 0,
      ptrRecordCount: (value['ptrRecordCount'] as num?)?.toInt() ?? 0,
      resolveStartedCount: (value['resolveStartedCount'] as num?)?.toInt() ?? 0,
      resolveSucceededCount:
          (value['resolveSucceededCount'] as num?)?.toInt() ?? 0,
      registrationSucceededCount:
          (value['registrationSucceededCount'] as num?)?.toInt() ?? 0,
      activeRegistrationAddress:
          value['activeRegistrationAddress']?.toString() ?? '',
      lastError: value['lastError']?.toString() ?? '',
    );
  }

  final bool browsing;
  final bool publishing;
  final int discoveredCount;
  final int resolvingCount;
  final int browseCallbackCount;
  final int ptrRecordCount;
  final int resolveStartedCount;
  final int resolveSucceededCount;
  final int registrationSucceededCount;
  final String activeRegistrationAddress;
  final String lastError;

  String get label => [
    browsing ? '浏览运行中' : '浏览未启动',
    publishing ? '发布运行中' : '未发布',
    '已解析 $discoveredCount 台',
    if (resolvingCount > 0) '解析中 $resolvingCount 项',
    if (browseCallbackCount > 0) '回调 $browseCallbackCount',
    if (ptrRecordCount > 0) 'PTR $ptrRecordCount',
    if (resolveStartedCount > 0)
      '解析 $resolveSucceededCount/$resolveStartedCount',
    if (registrationSucceededCount > 0) '注册 $registrationSucceededCount 次',
    if (activeRegistrationAddress.isNotEmpty) '地址 $activeRegistrationAddress',
    if (lastError.isNotEmpty) lastError,
  ].join(' · ');
}

class HostAdvertisement {
  const HostAdvertisement({
    required this.deviceId,
    required this.name,
    required this.port,
    this.path = '/ws/signaling',
    this.version = '1',
    this.capabilities = 'screen,pointer,keyboard,quality,displays',
    this.platform = 'unknown',
    this.signalingProfileId = '',
    this.rendezvousUrl = '',
  });

  final String deviceId;
  final String name;
  final int port;
  final String path;
  final String version;
  final String capabilities;
  final String platform;
  final String signalingProfileId;
  final String rendezvousUrl;

  Map<String, Object> toMap() => {
    'deviceId': deviceId,
    'name': name,
    'port': port,
    'path': path,
    'version': version,
    'capabilities': capabilities,
    'platform': platform,
    'signalingProfileId': signalingProfileId,
    'rendezvousUrl': rendezvousUrl,
  };
}

String signalingProfileIdForUrl(String value) {
  final normalized = value.trim().toLowerCase();
  var hash = 0x811c9dc5;
  for (final byte in normalized.codeUnits) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return 'fnv1a-${hash.toRadixString(16).padLeft(8, '0')}';
}

bool isLoopbackSignalingUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return false;
  return const {
    '127.0.0.1',
    'localhost',
    '::1',
  }.contains(uri.host.toLowerCase());
}

/// Resolves the signaling endpoint after the user explicitly selects a LAN
/// device. DNS-SD discovers a host, not a signaling server; the non-secret
/// rendezvous URL in that host's TXT record tells both peers where to meet.
///
/// An explicitly selected device may replace an empty, loopback, or different
/// signaling profile. Matching profiles keep the user's canonical endpoint.
String signalingUrlForSelectedDevice({
  required String currentServerUrl,
  required DiscoveredDevice device,
}) {
  final current = currentServerUrl.trim();
  final advertised = device.rendezvousUrl.trim();
  if (advertised.isEmpty) return current;
  if (current.isEmpty || isLoopbackSignalingUrl(current)) return advertised;
  final advertisedProfile = device.signalingProfileId;
  if (advertisedProfile.isNotEmpty &&
      advertisedProfile != signalingProfileIdForUrl(current)) {
    return advertised;
  }
  return current;
}

class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.path,
    required this.version,
    required this.capabilities,
    this.platform = 'unknown',
    this.signalingProfileId = '',
    this.rendezvousUrl = '',
  });

  factory DiscoveredDevice.fromMap(Map<Object?, Object?> value) {
    final port = value['port'];
    if (port is! num || port <= 0 || port > 65535) {
      throw const FormatException('局域网设备端口无效');
    }
    final host = value['host']?.toString().trim() ?? '';
    if (host.isEmpty) {
      throw const FormatException('局域网设备主机名无效');
    }
    final name = value['name']?.toString().trim();
    final id = value['id']?.toString().trim();
    final rawPath = value['path']?.toString().trim() ?? '/ws/signaling';
    final rawRendezvousUrl = value['rendezvousUrl']?.toString().trim() ?? '';
    final rendezvousUri = Uri.tryParse(rawRendezvousUrl);
    final rendezvousUrl =
        rendezvousUri != null &&
            const {'ws', 'wss'}.contains(rendezvousUri.scheme) &&
            rendezvousUri.host.isNotEmpty
        ? rendezvousUri.toString()
        : '';
    return DiscoveredDevice(
      id: id == null || id.isEmpty ? '$host:${port.toInt()}' : id,
      name: name == null || name.isEmpty ? host : name,
      host: host.endsWith('.') ? host.substring(0, host.length - 1) : host,
      port: port.toInt(),
      path: rawPath.startsWith('/') ? rawPath : '/$rawPath',
      version: value['version']?.toString() ?? '1',
      capabilities: value['capabilities']?.toString() ?? '',
      platform: value['platform']?.toString() ?? 'unknown',
      signalingProfileId: value['signalingProfileId']?.toString() ?? '',
      rendezvousUrl: rendezvousUrl,
    );
  }

  final String id;
  final String name;
  final String host;
  final int port;
  final String path;
  final String version;
  final String capabilities;
  final String platform;
  final String signalingProfileId;
  final String rendezvousUrl;

  String get signalingUrl => rendezvousUrl.isNotEmpty
      ? rendezvousUrl
      : Uri(scheme: 'ws', host: host, port: port, path: path).toString();
}

/// Desktop hosts browse and publish concurrently. Keep their own DNS-SD
/// advertisement out of the nearby-device list and normalize duplicates that
/// may arrive through multiple active network interfaces.
List<DiscoveredDevice> visibleLanDevices({
  required Iterable<DiscoveredDevice> devices,
  required String localDeviceId,
}) {
  final normalizedLocalId = localDeviceId.trim().toLowerCase();
  final byId = <String, DiscoveredDevice>{};
  for (final device in devices) {
    final normalizedId = device.id.trim().toLowerCase();
    if (normalizedLocalId.isNotEmpty && normalizedId == normalizedLocalId) {
      continue;
    }
    byId[normalizedId] = device;
  }
  final result = byId.values.toList(growable: false);
  result.sort((left, right) => left.name.compareTo(right.name));
  return result;
}

String lanDiscoveryEmptyHint({required String platform}) {
  if (platform.toLowerCase() == 'windows') {
    return '正在搜索；若持续为空，请确认当前网络为“专用网络”，并允许应用通过 Windows 防火墙。';
  }
  return '正在搜索；若网络禁用 mDNS/组播，可继续使用下方手动信令地址。';
}

abstract interface class LanDiscoveryService {
  bool get isSupported;

  Stream<List<DiscoveredDevice>> get devices;

  Future<void> startBrowsing();

  Future<void> stopBrowsing();

  Future<void> publishHost(HostAdvertisement host);

  Future<void> stopPublishing();

  Future<LanDiscoveryDiagnostics> getDiagnostics();

  Future<void> dispose();
}

LanDiscoveryService createLanDiscoveryService() {
  if (Platform.isIOS || Platform.isMacOS || Platform.isWindows) {
    return MethodChannelLanDiscoveryService();
  }
  return UnsupportedLanDiscoveryService();
}

class MethodChannelLanDiscoveryService implements LanDiscoveryService {
  static const _methodChannel = MethodChannel(
    'com.crossdesktopremote.cross_desktop_remote/lan_discovery',
  );
  static const _eventChannel = EventChannel(
    'com.crossdesktopremote.cross_desktop_remote/lan_discovery_events',
  );

  Stream<List<DiscoveredDevice>>? _devices;

  @override
  bool get isSupported => true;

  @override
  Stream<List<DiscoveredDevice>> get devices =>
      _devices ??= _eventChannel.receiveBroadcastStream().map(_decodeDevices);

  List<DiscoveredDevice> _decodeDevices(Object? event) {
    if (event is! List) {
      return const [];
    }
    final byId = <String, DiscoveredDevice>{};
    for (final value in event) {
      if (value is! Map) {
        continue;
      }
      try {
        final device = DiscoveredDevice.fromMap(value);
        byId[device.id] = device;
      } on FormatException {
        // Ignore malformed advertisements from other LAN devices.
      }
    }
    final result = byId.values.toList(growable: false);
    result.sort((left, right) => left.name.compareTo(right.name));
    return result;
  }

  @override
  Future<void> startBrowsing() =>
      _methodChannel.invokeMethod<void>('startBrowsing');

  @override
  Future<void> stopBrowsing() =>
      _methodChannel.invokeMethod<void>('stopBrowsing');

  @override
  Future<void> publishHost(HostAdvertisement host) =>
      _methodChannel.invokeMethod<void>('publishHost', host.toMap());

  @override
  Future<void> stopPublishing() =>
      _methodChannel.invokeMethod<void>('stopPublishing');

  @override
  Future<LanDiscoveryDiagnostics> getDiagnostics() async {
    if (!Platform.isWindows) {
      return const LanDiscoveryDiagnostics(
        browsing: true,
        publishing: false,
        discoveredCount: 0,
        resolvingCount: 0,
      );
    }
    try {
      final value = await _methodChannel.invokeMapMethod<Object?, Object?>(
        'getDiagnostics',
      );
      return LanDiscoveryDiagnostics.fromMap(value ?? const {});
    } on MissingPluginException {
      return const LanDiscoveryDiagnostics(
        browsing: false,
        publishing: false,
        discoveredCount: 0,
        resolvingCount: 0,
        lastError: '当前 Windows Runner 尚未提供发现诊断',
      );
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await stopBrowsing();
    } catch (_) {
      // The Flutter engine may already be detached during application shutdown.
    }
    try {
      await stopPublishing();
    } catch (_) {
      // Publishing is process-scoped and also disappears when the process exits.
    }
  }
}

class UnsupportedLanDiscoveryService implements LanDiscoveryService {
  @override
  bool get isSupported => false;

  @override
  Stream<List<DiscoveredDevice>> get devices => const Stream.empty();

  @override
  Future<void> startBrowsing() async {
    throw UnsupportedError('当前平台暂不支持局域网设备发现');
  }

  @override
  Future<void> stopBrowsing() async {}

  @override
  Future<void> publishHost(HostAdvertisement host) async {
    throw UnsupportedError('当前平台暂不支持局域网设备发布');
  }

  @override
  Future<void> stopPublishing() async {}

  @override
  Future<LanDiscoveryDiagnostics> getDiagnostics() async {
    return const LanDiscoveryDiagnostics(
      browsing: false,
      publishing: false,
      discoveredCount: 0,
      resolvingCount: 0,
      lastError: '当前平台不支持局域网发现',
    );
  }

  @override
  Future<void> dispose() async {}
}
