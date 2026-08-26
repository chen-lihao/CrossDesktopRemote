import 'package:cross_desktop_remote/core/discovery/lan_discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'unsupported discovery reports its capability instead of succeeding',
    () {
      final service = UnsupportedLanDiscoveryService();

      expect(service.isSupported, isFalse);
      expect(service.startBrowsing(), throwsUnsupportedError);
      expect(
        service.publishHost(
          const HostAdvertisement(deviceId: 'linux', name: 'Linux', port: 8080),
        ),
        throwsUnsupportedError,
      );
    },
  );

  test('keeps device identity separate from its rendezvous server', () {
    final device = DiscoveredDevice.fromMap({
      'id': 'macbook-pro',
      'name': 'MacBook Pro',
      'host': 'macbook-pro.local.',
      'port': 8080,
      'path': '/ws/signaling',
      'version': '1',
      'capabilities': 'screen,pointer',
      'platform': 'macos',
      'signalingProfileId': 'signal-prod',
      'rendezvousUrl': 'wss://signal.example.com/ws/signaling',
    });

    expect(device.host, 'macbook-pro.local');
    expect(device.signalingUrl, 'wss://signal.example.com/ws/signaling');
    expect(device.signalingProfileId, 'signal-prod');
    expect(device.platform, 'macos');
    expect(device.capabilities, contains('pointer'));
  });

  test('creates a stable non-secret signaling profile identifier', () {
    expect(
      signalingProfileIdForUrl('WS://MAC.LOCAL:8080/ws/signaling '),
      signalingProfileIdForUrl('ws://mac.local:8080/ws/signaling'),
    );
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

  test('desktop duplex discovery filters self and interface duplicates', () {
    const self = DiscoveredDevice(
      id: 'mac-mini',
      name: 'Mac mini',
      host: 'mac-mini.local',
      port: 8080,
      path: '/ws/signaling',
      version: '2',
      capabilities: 'screen',
    );
    const windows = DiscoveredDevice(
      id: 'windows-pc',
      name: 'Windows PC',
      host: 'windows-pc.local',
      port: 8080,
      path: '/ws/signaling',
      version: '2',
      capabilities: 'screen',
    );

    final visible = visibleLanDevices(
      devices: const [windows, self, windows],
      localDeviceId: 'MAC-MINI',
    );

    expect(visible, [windows]);
  });

  test('Windows empty discovery state provides an actionable hint', () {
    expect(lanDiscoveryEmptyHint(platform: 'windows'), contains('专用网络'));
    expect(lanDiscoveryEmptyHint(platform: 'macos'), contains('mDNS'));
  });

  test('decodes native DNS-SD diagnostics without dynamic type casts', () {
    final diagnostics = LanDiscoveryDiagnostics.fromMap({
      'browsing': true,
      'publishing': true,
      'discoveredCount': 2,
      'resolvingCount': 1,
      'lastError': '',
    });

    expect(diagnostics.browsing, isTrue);
    expect(diagnostics.publishing, isTrue);
    expect(diagnostics.discoveredCount, 2);
    expect(diagnostics.label, contains('解析中 1 项'));
  });

  group('selected device signaling endpoint', () {
    final device = DiscoveredDevice.fromMap({
      'id': 'windows-host',
      'name': 'Windows Host',
      'host': 'windows-host.local',
      'port': 8080,
      'rendezvousUrl': 'ws://192.168.1.20:8080/ws/signaling',
      'signalingProfileId': signalingProfileIdForUrl(
        'ws://192.168.1.20:8080/ws/signaling',
      ),
    });

    test('replaces a loopback default with the host rendezvous endpoint', () {
      expect(
        signalingUrlForSelectedDevice(
          currentServerUrl: 'ws://127.0.0.1:8080/ws/signaling',
          device: device,
        ),
        device.rendezvousUrl,
      );
    });

    test('replaces a different signaling profile after explicit selection', () {
      expect(
        signalingUrlForSelectedDevice(
          currentServerUrl: 'wss://signal.example.com/ws/signaling',
          device: device,
        ),
        device.rendezvousUrl,
      );
    });

    test('keeps an endpoint that already matches the advertised profile', () {
      expect(
        signalingUrlForSelectedDevice(
          currentServerUrl: device.rendezvousUrl,
          device: device,
        ),
        device.rendezvousUrl,
      );
    });
  });
}
