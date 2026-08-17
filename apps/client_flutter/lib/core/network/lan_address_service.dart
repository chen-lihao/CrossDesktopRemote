import 'dart:io';

class LanAddress {
  const LanAddress({
    required this.interfaceName,
    required this.address,
    required this.recommended,
  });

  final String interfaceName;
  final String address;
  final bool recommended;

  String signalingUrl({int port = 8080, String path = '/ws/signaling'}) =>
      Uri(scheme: 'ws', host: address, port: port, path: path).toString();
}

class LanAddressService {
  const LanAddressService();

  Future<List<LanAddress>> listUsableAddresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return selectUsableLanAddresses(
      interfaces.expand(
        (interface) => interface.addresses.map(
          (address) => LanAddress(
            interfaceName: interface.name,
            address: address.address,
            recommended: isPreferredInterface(interface.name),
          ),
        ),
      ),
    );
  }
}

List<LanAddress> selectUsableLanAddresses(Iterable<LanAddress> candidates) {
  final byAddress = <String, LanAddress>{};
  for (final candidate in candidates) {
    if (!isUsableLanIpv4(candidate.address) ||
        isApplePeerToPeerInterface(candidate.interfaceName)) {
      continue;
    }
    byAddress.putIfAbsent(candidate.address, () => candidate);
  }
  final result = byAddress.values.toList(growable: false);
  result.sort((left, right) {
    final rank = interfaceRank(left.interfaceName)
        .compareTo(interfaceRank(right.interfaceName));
    if (rank != 0) {
      return rank;
    }
    return left.address.compareTo(right.address);
  });
  return result;
}

bool isUsableLanIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) {
    return false;
  }
  final octets = parts.map(int.tryParse).toList(growable: false);
  if (octets.any((part) => part == null || part < 0 || part > 255)) {
    return false;
  }
  final first = octets[0]!;
  final second = octets[1]!;
  if (first == 0 || first == 127 || first >= 224) {
    return false;
  }
  if (first == 169 && second == 254) {
    return false;
  }
  return true;
}

bool isPreferredInterface(String name) => RegExp(r'^en\d+$').hasMatch(name);

bool isApplePeerToPeerInterface(String name) =>
    name.startsWith('awdl') || name.startsWith('llw');

int interfaceRank(String name) {
  if (name == 'en0') {
    return 0;
  }
  if (isPreferredInterface(name)) {
    return 1;
  }
  if (name.startsWith('bridge')) {
    return 2;
  }
  if (name.startsWith('utun')) {
    return 4;
  }
  return 3;
}
