import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class DeviceIdentity {
  const DeviceIdentity({required this.deviceId, required this.machineCode});

  final String deviceId;
  final String machineCode;
}

abstract interface class DeviceIdentityStore {
  Future<String?> readDeviceId();

  Future<void> writeDeviceId(String deviceId);
}

class SharedPreferencesDeviceIdentityStore implements DeviceIdentityStore {
  SharedPreferencesDeviceIdentityStore([this._preferences]);

  static const _deviceIdKey = 'identity.device_id.v1';

  SharedPreferencesAsync? _preferences;

  SharedPreferencesAsync? get _store {
    if (_preferences != null) return _preferences;
    try {
      return _preferences = SharedPreferencesAsync();
    } on StateError {
      return null;
    }
  }

  @override
  Future<String?> readDeviceId() async {
    return await _store?.getString(_deviceIdKey);
  }

  @override
  Future<void> writeDeviceId(String deviceId) async {
    await _store?.setString(_deviceIdKey, deviceId);
  }
}

class DeviceIdentityController extends ChangeNotifier {
  DeviceIdentityController({DeviceIdentityStore? store, Random? random})
    : _store = store ?? SharedPreferencesDeviceIdentityStore(),
      _random = random ?? Random.secure();

  static final RegExp _deviceIdPattern = RegExp(r'^[0-9a-f]{32}$');
  static const _base32Alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  final DeviceIdentityStore _store;
  final Random _random;
  DeviceIdentity? _identity;

  DeviceIdentity? get identity => _identity;
  bool get loaded => _identity != null;
  String get deviceId => _identity?.deviceId ?? '';
  String get machineCode => _identity?.machineCode ?? '';

  Future<DeviceIdentity> loadOrCreate() async {
    if (_identity case final existing?) return existing;
    final stored = (await _store.readDeviceId())?.trim().toLowerCase();
    final deviceId = stored != null && _deviceIdPattern.hasMatch(stored)
        ? stored
        : _generateDeviceId();
    if (stored != deviceId) await _store.writeDeviceId(deviceId);
    final identity = DeviceIdentity(
      deviceId: deviceId,
      machineCode: _formatMachineCode(deviceId),
    );
    _identity = identity;
    notifyListeners();
    return identity;
  }

  String _generateDeviceId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    // Mark the random installation identifier as UUID-v4-compatible without
    // depending on a platform UUID API.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _formatMachineCode(String deviceId) {
    final bytes = <int>[
      for (var offset = 0; offset < deviceId.length; offset += 2)
        int.parse(deviceId.substring(offset, offset + 2), radix: 16),
    ];
    var buffer = 0;
    var bits = 0;
    final encoded = StringBuffer();
    for (final byte in bytes) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        encoded.write(_base32Alphabet[(buffer >> bits) & 31]);
      }
    }
    if (bits > 0) encoded.write(_base32Alphabet[(buffer << (5 - bits)) & 31]);
    final value = encoded.toString();
    final groups = <String>[
      for (var offset = 0; offset < value.length; offset += 4)
        value.substring(offset, min(offset + 4, value.length)),
    ];
    return 'CDR-${groups.join('-')}';
  }
}
