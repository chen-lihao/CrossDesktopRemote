import 'dart:math';

import 'package:cross_desktop_remote/core/identity/device_key_platform_adapter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DeviceIdentitySecurityState {
  unavailable,
  readyHardwareBacked,
  readySoftwareBacked,
  keyUnavailable,
  identityChanged,
}

@immutable
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.machineCode,
    required this.legacyDeviceId,
    required this.legacyMachineCode,
    this.rootPublicKey,
    this.rootFingerprint,
    this.authenticationPublicKey,
    this.authenticationCertificate,
    this.authenticationNotBefore,
    this.authenticationExpiresAt,
    this.hardwareBacked = false,
    this.securityState = DeviceIdentitySecurityState.unavailable,
  });

  final String deviceId;
  final String machineCode;
  final String legacyDeviceId;
  final String legacyMachineCode;
  final Uint8List? rootPublicKey;
  final Uint8List? rootFingerprint;
  final Uint8List? authenticationPublicKey;
  final Uint8List? authenticationCertificate;
  final DateTime? authenticationNotBefore;
  final DateTime? authenticationExpiresAt;
  final bool hardwareBacked;
  final DeviceIdentitySecurityState securityState;

  bool get trustedAuthenticationAvailable =>
      rootPublicKey != null &&
      rootFingerprint != null &&
      authenticationPublicKey != null &&
      authenticationCertificate != null &&
      hardwareBacked &&
      securityState == DeviceIdentitySecurityState.readyHardwareBacked;
}

abstract interface class DeviceIdentityStore {
  Future<String?> readDeviceId();

  Future<void> writeDeviceId(String deviceId);
}

abstract interface class DeviceRootBindingStore {
  Future<String?> readRootFingerprint();

  Future<void> writeRootFingerprint(String fingerprint);
}

class SharedPreferencesDeviceRootBindingStore
    implements DeviceRootBindingStore {
  SharedPreferencesDeviceRootBindingStore([this._preferences]);

  static const _rootFingerprintKey = 'identity.root_fingerprint.v2';

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
  Future<String?> readRootFingerprint() async =>
      (await _store?.getString(_rootFingerprintKey))?.trim().toLowerCase();

  @override
  Future<void> writeRootFingerprint(String fingerprint) async {
    await _store?.setString(_rootFingerprintKey, fingerprint.toLowerCase());
  }
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
  DeviceIdentityController({
    DeviceIdentityStore? store,
    DeviceRootBindingStore? rootBindingStore,
    DeviceKeyPlatformAdapter? keyPlatform,
    Random? random,
  }) : _store = store ?? SharedPreferencesDeviceIdentityStore(),
       _rootBindingStore =
           rootBindingStore ?? SharedPreferencesDeviceRootBindingStore(),
       _keyPlatform = keyPlatform ?? createDeviceKeyPlatformAdapter(),
       _random = random ?? Random.secure();

  static final RegExp _deviceIdPattern = RegExp(r'^[0-9a-f]{32}$');
  static const _base32Alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  final DeviceIdentityStore _store;
  final DeviceRootBindingStore _rootBindingStore;
  final DeviceKeyPlatformAdapter _keyPlatform;
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
    final legacyMachineCode = _formatLegacyMachineCode(deviceId);
    final identity = await _loadProtectedIdentity(
      deviceId: deviceId,
      legacyMachineCode: legacyMachineCode,
      boundFingerprint: await _readBoundFingerprint(),
    );
    _identity = identity;
    notifyListeners();
    return identity;
  }

  Future<DeviceIdentity> refreshAuthenticationKey({
    bool forceRotation = false,
  }) async {
    final current = await loadOrCreate();
    if (!_keyPlatform.supported || current.rootFingerprint == null) {
      return current;
    }
    try {
      final protected = forceRotation
          ? await _keyPlatform.rotateAuthenticationKey()
          : await _keyPlatform.loadOrCreateIdentity();
      _validateP256PublicKey(protected.rootPublicKey, 'rootPublicKey');
      _validateP256PublicKey(
        protected.authenticationPublicKey,
        'authenticationPublicKey',
      );
      final fingerprint = Uint8List.fromList(
        sha256.convert(protected.rootPublicKey).bytes,
      );
      if (!_constantTimeEqual(current.rootFingerprint!, fingerprint)) {
        throw const FormatException('Protected root identity changed');
      }
      _identity = DeviceIdentity(
        deviceId: current.deviceId,
        machineCode: _formatMachineCodeV2(fingerprint),
        legacyDeviceId: current.legacyDeviceId,
        legacyMachineCode: current.legacyMachineCode,
        rootPublicKey: protected.rootPublicKey,
        rootFingerprint: fingerprint,
        authenticationPublicKey: protected.authenticationPublicKey,
        authenticationCertificate: protected.authenticationCertificate,
        authenticationNotBefore: protected.authenticationNotBefore,
        authenticationExpiresAt: protected.authenticationExpiresAt,
        hardwareBacked: protected.hardwareBacked,
        securityState: protected.hardwareBacked
            ? DeviceIdentitySecurityState.readyHardwareBacked
            : DeviceIdentitySecurityState.readySoftwareBacked,
      );
      notifyListeners();
      return _identity!;
    } catch (_) {
      _identity = DeviceIdentity(
        deviceId: current.deviceId,
        machineCode: current.machineCode,
        legacyDeviceId: current.legacyDeviceId,
        legacyMachineCode: current.legacyMachineCode,
        rootFingerprint: current.rootFingerprint,
        securityState: DeviceIdentitySecurityState.keyUnavailable,
      );
      notifyListeners();
      return _identity!;
    }
  }

  Future<DeviceIdentity> _loadProtectedIdentity({
    required String deviceId,
    required String legacyMachineCode,
    required Uint8List? boundFingerprint,
  }) async {
    if (!_keyPlatform.supported) {
      return _fallbackIdentity(
        deviceId: deviceId,
        legacyMachineCode: legacyMachineCode,
        boundFingerprint: boundFingerprint,
        securityState: DeviceIdentitySecurityState.unavailable,
      );
    }
    try {
      final protected = await _keyPlatform.loadOrCreateIdentity();
      _validateP256PublicKey(protected.rootPublicKey, 'rootPublicKey');
      _validateP256PublicKey(
        protected.authenticationPublicKey,
        'authenticationPublicKey',
      );
      final fingerprint = Uint8List.fromList(
        sha256.convert(protected.rootPublicKey).bytes,
      );
      if (boundFingerprint != null &&
          !_constantTimeEqual(boundFingerprint, fingerprint)) {
        return _fallbackIdentity(
          deviceId: deviceId,
          legacyMachineCode: legacyMachineCode,
          boundFingerprint: boundFingerprint,
          securityState: DeviceIdentitySecurityState.identityChanged,
        );
      }
      if (boundFingerprint == null) {
        await _rootBindingStore.writeRootFingerprint(_hex(fingerprint));
      }
      final securityState = protected.hardwareBacked
          ? DeviceIdentitySecurityState.readyHardwareBacked
          : DeviceIdentitySecurityState.readySoftwareBacked;
      return DeviceIdentity(
        // Preserve the installation ID used by the connection-code and LAN
        // discovery paths. Trusted routing uses machineCode explicitly.
        deviceId: deviceId,
        machineCode: _formatMachineCodeV2(fingerprint),
        legacyDeviceId: deviceId,
        legacyMachineCode: legacyMachineCode,
        rootPublicKey: protected.rootPublicKey,
        rootFingerprint: fingerprint,
        authenticationPublicKey: protected.authenticationPublicKey,
        authenticationCertificate: protected.authenticationCertificate,
        authenticationNotBefore: protected.authenticationNotBefore,
        authenticationExpiresAt: protected.authenticationExpiresAt,
        hardwareBacked: protected.hardwareBacked,
        securityState: securityState,
      );
    } catch (_) {
      return _fallbackIdentity(
        deviceId: deviceId,
        legacyMachineCode: legacyMachineCode,
        boundFingerprint: boundFingerprint,
        securityState: DeviceIdentitySecurityState.keyUnavailable,
      );
    }
  }

  DeviceIdentity _fallbackIdentity({
    required String deviceId,
    required String legacyMachineCode,
    required Uint8List? boundFingerprint,
    required DeviceIdentitySecurityState securityState,
  }) {
    return DeviceIdentity(
      deviceId: deviceId,
      machineCode: boundFingerprint == null
          ? legacyMachineCode
          : _formatMachineCodeV2(boundFingerprint),
      legacyDeviceId: deviceId,
      legacyMachineCode: legacyMachineCode,
      rootFingerprint: boundFingerprint,
      securityState: securityState,
    );
  }

  Future<Uint8List?> _readBoundFingerprint() async {
    final value = await _rootBindingStore.readRootFingerprint();
    if (value == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      return null;
    }
    return Uint8List.fromList([
      for (var offset = 0; offset < value.length; offset += 2)
        int.parse(value.substring(offset, offset + 2), radix: 16),
    ]);
  }

  static void _validateP256PublicKey(Uint8List value, String name) {
    if (value.length != 65 || value.first != 0x04) {
      throw FormatException('$name must be an uncompressed P-256 SEC1 key');
    }
  }

  static bool _constantTimeEqual(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var index = 0; index < first.length; index++) {
      difference |= first[index] ^ second[index];
    }
    return difference == 0;
  }

  String _generateDeviceId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    // Mark the random installation identifier as UUID-v4-compatible without
    // depending on a platform UUID API.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<Uint8List> signWithRoot(Uint8List message) {
    if (_identity?.trustedAuthenticationAvailable != true) {
      throw StateError('当前设备没有受保护的根身份密钥');
    }
    return _keyPlatform.signWithRoot(message);
  }

  Future<Uint8List> signWithAuthenticationKey(Uint8List message) {
    if (_identity?.trustedAuthenticationAvailable != true) {
      throw StateError('当前设备没有受保护的认证密钥');
    }
    return _keyPlatform.signWithAuthenticationKey(message);
  }

  Future<bool> verifyP256Signature({
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => _keyPlatform.verifyP256Signature(
    publicKey: publicKey,
    message: message,
    signature: signature,
  );

  static String _formatLegacyMachineCode(String deviceId) {
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

  static String _formatMachineCodeV2(Uint8List fingerprint) {
    final material = Uint8List(13)
      ..setRange(0, 12, fingerprint)
      ..[12] = sha256.convert(fingerprint).bytes.first;
    final value = _encodeCrockford(material);
    final groups = <String>[
      for (var offset = 0; offset < value.length; offset += 4)
        value.substring(offset, min(offset + 4, value.length)),
    ];
    return 'CDR2-${groups.join('-')}';
  }

  static String machineCodeV2ForRootPublicKey(Uint8List rootPublicKey) {
    _validateP256PublicKey(rootPublicKey, 'rootPublicKey');
    return _formatMachineCodeV2(
      Uint8List.fromList(sha256.convert(rootPublicKey).bytes),
    );
  }

  static String _encodeCrockford(List<int> bytes) {
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
    return encoded.toString();
  }

  static String _hex(List<int> bytes) =>
      bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}
