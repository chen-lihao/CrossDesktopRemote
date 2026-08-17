import 'package:cross_desktop_remote/core/network/lan_address_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('filters unusable addresses and prioritizes physical interfaces', () {
    final result = selectUsableLanAddresses(const [
      LanAddress(
        interfaceName: 'utun3',
        address: '10.8.0.2',
        recommended: false,
      ),
      LanAddress(
        interfaceName: 'lo0',
        address: '127.0.0.1',
        recommended: false,
      ),
      LanAddress(
        interfaceName: 'awdl0',
        address: '192.168.44.2',
        recommended: false,
      ),
      LanAddress(
        interfaceName: 'en1',
        address: '192.168.1.9',
        recommended: true,
      ),
      LanAddress(
        interfaceName: 'en0',
        address: '172.22.232.27',
        recommended: true,
      ),
      LanAddress(
        interfaceName: 'en5',
        address: '169.254.1.7',
        recommended: true,
      ),
      LanAddress(
        interfaceName: 'bridge0',
        address: '192.168.64.1',
        recommended: false,
      ),
      LanAddress(
        interfaceName: 'en8',
        address: '172.22.232.27',
        recommended: true,
      ),
    ]);

    expect(result.map((address) => address.address), [
      '172.22.232.27',
      '192.168.1.9',
      '192.168.64.1',
      '10.8.0.2',
    ]);
  });

  test('rejects loopback, link-local, multicast, and malformed IPv4', () {
    expect(isUsableLanIpv4('127.0.0.1'), isFalse);
    expect(isUsableLanIpv4('169.254.3.8'), isFalse);
    expect(isUsableLanIpv4('224.0.0.251'), isFalse);
    expect(isUsableLanIpv4('300.1.1.1'), isFalse);
    expect(isUsableLanIpv4('192.168.1.10'), isTrue);
  });

  test('builds a controller-safe signaling URL', () {
    const address = LanAddress(
      interfaceName: 'en0',
      address: '172.22.232.27',
      recommended: true,
    );

    expect(address.signalingUrl(), 'ws://172.22.232.27:8080/ws/signaling');
  });
}
