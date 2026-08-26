import 'dart:math';

enum RemoteRole { host, controller }

String generateRoomCode([Random? random]) {
  final source = random ?? Random.secure();
  return (source.nextInt(900000) + 100000).toString();
}

bool isValidRoomCode(String value) => RegExp(r'^[0-9]{6}$').hasMatch(value);

Uri buildSignalingUri({
  required String serverUrl,
  required String roomCode,
  required RemoteRole role,
  String clientPlatform = '',
  Iterable<String> clientCapabilities = const [],
}) {
  final baseUri = Uri.parse(serverUrl.trim());
  if (baseUri.scheme != 'ws' && baseUri.scheme != 'wss') {
    throw const FormatException('信令地址必须使用 ws:// 或 wss://');
  }
  if (baseUri.host.isEmpty) {
    throw const FormatException('信令地址缺少主机名或 IP');
  }
  if (role == RemoteRole.controller && !isValidRoomCode(roomCode)) {
    throw const FormatException('连接码必须是 6 位数字');
  }

  return baseUri.replace(
    queryParameters: {
      ...baseUri.queryParameters,
      if (roomCode.isNotEmpty) 'room': roomCode,
      'role': role.name,
      'protocol': '2',
      if (clientPlatform.trim().isNotEmpty)
        'platform': clientPlatform.trim().toLowerCase(),
      if (clientCapabilities.isNotEmpty)
        'capabilities': clientCapabilities.join(','),
    },
  );
}
