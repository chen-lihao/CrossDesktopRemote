import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

const lanDiscoveryServiceType = '_cdrremote._tcp';

class HostAdvertisement {
  const HostAdvertisement({
    required this.deviceId,
    required this.name,
    required this.port,
    this.path = '/ws/signaling',
    this.version = '1',
    this.capabilities = 'screen,pointer,keyboard,quality,displays',
  });

  final String deviceId;
  final String name;
  final int port;
  final String path;
  final String version;
  final String capabilities;

  Map<String, Object> toMap() => {
    'deviceId': deviceId,
    'name': name,
    'port': port,
    'path': path,
    'version': version,
    'capabilities': capabilities,
  };
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
    return DiscoveredDevice(
      id: id == null || id.isEmpty ? '$host:${port.toInt()}' : id,
      name: name == null || name.isEmpty ? host : name,
      host: host.endsWith('.') ? host.substring(0, host.length - 1) : host,
      port: port.toInt(),
      path: rawPath.startsWith('/') ? rawPath : '/$rawPath',
      version: value['version']?.toString() ?? '1',
      capabilities: value['capabilities']?.toString() ?? '',
    );
  }

  final String id;
  final String name;
  final String host;
  final int port;
  final String path;
  final String version;
  final String capabilities;

  String get signalingUrl =>
      Uri(scheme: 'ws', host: host, port: port, path: path).toString();
}

abstract interface class LanDiscoveryService {
  bool get isSupported;

  Stream<List<DiscoveredDevice>> get devices;

  Future<void> startBrowsing();

  Future<void> stopBrowsing();

  Future<void> publishHost(HostAdvertisement host);

  Future<void> stopPublishing();

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
  Future<void> dispose() async {}
}
