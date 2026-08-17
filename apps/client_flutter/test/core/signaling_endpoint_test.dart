import 'dart:math';

import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('creates a six digit room code', () {
    final roomCode = generateRoomCode(Random(42));

    expect(roomCode, hasLength(6));
    expect(isValidRoomCode(roomCode), isTrue);
  });

  test('adds room and role to a websocket endpoint', () {
    final endpoint = buildSignalingUri(
      serverUrl: 'ws://192.168.1.8:8080/ws/signaling',
      roomCode: '123456',
      role: RemoteRole.controller,
    );

    expect(endpoint.scheme, 'ws');
    expect(endpoint.queryParameters['room'], '123456');
    expect(endpoint.queryParameters['role'], 'controller');
  });

  test('rejects non websocket endpoints', () {
    expect(
      () => buildSignalingUri(
        serverUrl: 'http://192.168.1.8:8080/ws/signaling',
        roomCode: '123456',
        role: RemoteRole.host,
      ),
      throwsFormatException,
    );
  });
}
