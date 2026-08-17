import 'package:cross_desktop_remote/core/discovery/lan_discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a Bonjour advertisement into a signaling endpoint', () {
    final device = DiscoveredDevice.fromMap({
      'id': 'macbook-pro',
      'name': 'MacBook Pro',
      'host': 'macbook-pro.local.',
      'port': 8080,
      'path': '/ws/signaling',
      'version': '1',
      'capabilities': 'screen,pointer',
    });

    expect(device.host, 'macbook-pro.local');
    expect(device.signalingUrl, 'ws://macbook-pro.local:8080/ws/signaling');
    expect(device.capabilities, contains('pointer'));
  });

  test('normalizes paths and rejects invalid advertisements', () {
    final device = DiscoveredDevice.fromMap({
      'name': 'Mac mini',
      'host': 'mac-mini.local',
      'port': 8080,
      'path': 'ws/signaling',
    });

    expect(device.path, '/ws/signaling');
    expect(
      () => DiscoveredDevice.fromMap({'host': '', 'port': 8080}),
      throwsFormatException,
    );
    expect(
      () => DiscoveredDevice.fromMap({'host': 'mac.local', 'port': 70000}),
      throwsFormatException,
    );
  });
}
