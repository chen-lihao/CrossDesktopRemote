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
      clientPlatform: 'Windows',
      clientCapabilities: const ['active-content-geometry-v2'],
    );

    expect(endpoint.scheme, 'ws');
    expect(endpoint.queryParameters['room'], '123456');
    expect(endpoint.queryParameters['role'], 'controller');
    expect(endpoint.queryParameters['protocol'], '2');
    expect(endpoint.queryParameters['platform'], 'windows');
    expect(
      endpoint.queryParameters['capabilities'],
      'active-content-geometry-v2',
    );
    expect(endpoint.queryParametersAll['capability'], const [
      'active-content-geometry-v2',
    ]);
  });

  test('encodes multiple capabilities as repeated query parameters', () {
    final endpoint = buildSignalingUri(
      serverUrl: 'ws://192.168.1.8:8080/ws/signaling',
      roomCode: '123456',
      role: RemoteRole.controller,
      clientPlatform: 'Windows',
      clientCapabilities: const [
        'active-content-geometry-v2',
        'text-clipboard-v1',
      ],
    );

    expect(
      endpoint.queryParameters['capabilities'],
      'active-content-geometry-v2',
    );
    expect(endpoint.queryParametersAll['capability'], const [
      'active-content-geometry-v2',
      'text-clipboard-v1',
    ]);
    expect(endpoint.toString(), isNot(contains('%2C')));
  });

  test('allows a version two host to request a server-owned invitation', () {
    final endpoint = buildSignalingUri(
      serverUrl: 'wss://signal.example.com/ws/signaling',
      roomCode: '',
      role: RemoteRole.host,
    );

    expect(endpoint.queryParameters.containsKey('room'), isFalse);
    expect(endpoint.queryParameters['role'], 'host');
    expect(endpoint.queryParameters['protocol'], '2');
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
