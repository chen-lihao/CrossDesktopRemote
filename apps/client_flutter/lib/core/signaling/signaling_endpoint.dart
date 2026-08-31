import 'dart:math';

enum RemoteRole { host, controller }

String generateRoomCode([Random? random]) {
  final source = random ?? Random.secure();
  return (source.nextInt(900000) + 100000).toString();
}

bool isValidRoomCode(String value) => RegExp(r'^[0-9]{6}$').hasMatch(value);

String normalizeSignalingServerUrl(String value) {
  final trimmed = value.trim();
  final uri = Uri.parse(trimmed);
  if (uri.scheme != 'ws' && uri.scheme != 'wss') {
    throw const FormatException('信令地址必须使用 ws:// 或 wss://');
  }
  if (uri.host.isEmpty) {
    throw const FormatException('信令地址缺少主机名或 IP');
  }
  if (uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
    throw const FormatException('信令地址不能包含用户信息或片段');
  }
  return uri.toString();
}

/// Builds a real WebSocket handshake target without consuming a user code.
/// The server may close the probe after accepting the handshake; that still
/// proves TLS, HTTP upgrade and the configured WebSocket path are valid.
Uri buildSignalingProbeUri(String serverUrl) {
  final base = Uri.parse(normalizeSignalingServerUrl(serverUrl));
  return base.replace(
    queryParameters: {
      ...base.queryParameters,
      // Host registration without a room is supported by current and legacy
      // control planes, and does not consume a user's invitation retry budget.
      'role': RemoteRole.host.name,
      'protocol': '2',
      'probe': 'true',
    },
  );
}

Uri buildSignalingUri({
  required String serverUrl,
  required String roomCode,
  required RemoteRole role,
  String deviceId = '',
  String clientPlatform = '',
  Iterable<String> clientCapabilities = const [],
}) {
  final baseUri = Uri.parse(normalizeSignalingServerUrl(serverUrl));
  if (role == RemoteRole.controller && !isValidRoomCode(roomCode)) {
    throw const FormatException('连接码必须是 6 位数字');
  }

  final capabilities = clientCapabilities
      .map((value) => value.trim().toLowerCase())
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList(growable: false);

  return baseUri.replace(
    queryParameters: {
      ...baseUri.queryParameters,
      if (roomCode.isNotEmpty) 'room': roomCode,
      'role': role.name,
      'protocol': '2',
      if (deviceId.trim().isNotEmpty) 'deviceId': deviceId.trim().toLowerCase(),
      if (clientPlatform.trim().isNotEmpty)
        'platform': clientPlatform.trim().toLowerCase(),
      // Keep the first capability for servers that only understand the legacy
      // singular value. New servers consume every repeated capability entry,
      // avoiding delimiter encoding differences between Dart and Spring.
      if (capabilities.isNotEmpty) 'capabilities': capabilities.first,
      if (capabilities.isNotEmpty) 'capability': capabilities,
    },
  );
}
