import 'dart:math';

import 'package:cross_desktop_remote/core/identity/device_identity.dart';
import 'package:cross_desktop_remote/core/identity/device_key_platform_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'creates and persists a stable non-editable installation identity',
    () async {
      final store = _MemoryIdentityStore();
      final first = DeviceIdentityController(store: store, random: Random(42));
      final initial = await first.loadOrCreate();
      final restarted = DeviceIdentityController(
        store: store,
        random: Random(7),
      );
      final restored = await restarted.loadOrCreate();

      expect(initial.deviceId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(initial.deviceId, restored.deviceId);
      expect(initial.machineCode, restored.machineCode);
      expect(
        initial.machineCode,
        matches(RegExp(r'^CDR-[0-9A-HJKMNP-TV-Z-]+$')),
      );
    },
  );

  test('replaces malformed legacy identity values', () async {
    final store = _MemoryIdentityStore()..value = 'desktop-name';
    final controller = DeviceIdentityController(
      store: store,
      random: Random(11),
    );

    final identity = await controller.loadOrCreate();

    expect(identity.deviceId, isNot('desktop-name'));
    expect(store.value, identity.deviceId);
  });

  test('reports a legacy software identity as migration required', () async {
    final rootBinding = _MemoryRootBindingStore();
    final controller = DeviceIdentityController(
      store: _MemoryIdentityStore(),
      rootBindingStore: rootBinding,
      keyPlatform: _FakeDeviceKeyPlatform(
        current: _platformIdentity(
          seed: 1,
          protection: PlatformDeviceKeyProtection.legacySoftware,
          state: PlatformDeviceKeySecurityState.migrationRequired,
        ),
      ),
      random: Random(1),
    );

    final identity = await controller.loadOrCreate();

    expect(
      identity.securityState,
      DeviceIdentitySecurityState.migrationRequired,
    );
    expect(identity.trustedAuthenticationAvailable, isFalse);
    expect(identity.requiresMigration, isTrue);
    expect(identity.machineCode, startsWith('CDR2-'));
    expect(rootBinding.value, isNotNull);
  });

  test('explicit hardware upgrade replaces the bound root identity', () async {
    final rootBinding = _MemoryRootBindingStore();
    final platform = _FakeDeviceKeyPlatform(
      current: _platformIdentity(
        seed: 2,
        protection: PlatformDeviceKeyProtection.legacySoftware,
        state: PlatformDeviceKeySecurityState.migrationRequired,
      ),
      upgraded: _platformIdentity(
        seed: 3,
        protection: PlatformDeviceKeyProtection.secureHardware,
        state: PlatformDeviceKeySecurityState.readyHardwareProtected,
      ),
    );
    final controller = DeviceIdentityController(
      store: _MemoryIdentityStore(),
      rootBindingStore: rootBinding,
      keyPlatform: platform,
      random: Random(2),
    );
    final before = await controller.loadOrCreate();

    final upgraded = await controller.upgradeToHardwareIdentity();

    expect(platform.upgradeCalls, 1);
    expect(upgraded.trustedAuthenticationAvailable, isTrue);
    expect(
      upgraded.securityState,
      DeviceIdentitySecurityState.readyHardwareBacked,
    );
    expect(upgraded.machineCode, isNot(before.machineCode));
    expect(rootBinding.value, isNotNull);
  });

  test('preserves a retryable protected storage diagnostic', () async {
    final controller = DeviceIdentityController(
      store: _MemoryIdentityStore(),
      rootBindingStore: _MemoryRootBindingStore(),
      keyPlatform: _FakeDeviceKeyPlatform(
        loadError: PlatformException(
          code: 'device_identity_failed',
          message: 'Unable to persist protected device key',
          details: {'diagnosticCode': 'identity_storage_failure'},
        ),
      ),
      random: Random(3),
    );

    final identity = await controller.loadOrCreate();

    expect(
      identity.securityState,
      DeviceIdentitySecurityState.transientFailure,
    );
    expect(identity.diagnosticCode, 'identity_storage_failure');
    expect(identity.canRetryProtectedIdentity, isTrue);
  });

  test(
    'maps a detected legacy Keychain identity to explicit migration',
    () async {
      final controller = DeviceIdentityController(
        store: _MemoryIdentityStore(),
        rootBindingStore: _MemoryRootBindingStore(),
        keyPlatform: _FakeDeviceKeyPlatform(
          loadError: PlatformException(
            code: 'device_identity_failed',
            message: 'Legacy identity requires replacement',
            details: {'diagnosticCode': 'legacy_keychain_identity_detected'},
          ),
        ),
        random: Random(4),
      );

      final identity = await controller.loadOrCreate();

      expect(
        identity.securityState,
        DeviceIdentitySecurityState.migrationRequired,
      );
      expect(identity.trustedAuthenticationAvailable, isFalse);
      expect(identity.requiresMigration, isTrue);
    },
  );

  test('keeps unsigned macOS builds on the connection-code fallback', () async {
    final controller = DeviceIdentityController(
      store: _MemoryIdentityStore(),
      rootBindingStore: _MemoryRootBindingStore(),
      keyPlatform: _FakeDeviceKeyPlatform(
        loadError: PlatformException(
          code: 'protected_storage_failed',
          message: 'Trusted identity is disabled for this unsigned build',
          details: {'diagnosticCode': 'trusted_identity_disabled'},
        ),
      ),
      random: Random(5),
    );

    final identity = await controller.loadOrCreate();

    expect(identity.securityState, DeviceIdentitySecurityState.unavailable);
    expect(identity.trustedAuthenticationAvailable, isFalse);
    expect(identity.canRetryProtectedIdentity, isFalse);
    expect(identity.machineCode, startsWith('CDR-'));
  });
}

PlatformDeviceKeyIdentity _platformIdentity({
  required int seed,
  required PlatformDeviceKeyProtection protection,
  required PlatformDeviceKeySecurityState state,
}) {
  Uint8List publicKey(int offset) => Uint8List.fromList([
    0x04,
    ...List<int>.generate(64, (index) => (seed + offset + index) & 0xff),
  ]);
  return PlatformDeviceKeyIdentity(
    rootKeyHandle: 'root-$seed',
    rootPublicKey: publicKey(0),
    authenticationKeyHandle: 'auth-$seed',
    authenticationPublicKey: publicKey(17),
    authenticationNotBefore: DateTime.utc(2026),
    authenticationExpiresAt: DateTime.utc(2026, 2),
    authenticationCertificate: Uint8List.fromList([seed]),
    protection: protection,
    securityState: state,
  );
}

class _MemoryIdentityStore implements DeviceIdentityStore {
  String? value;

  @override
  Future<String?> readDeviceId() async => value;

  @override
  Future<void> writeDeviceId(String deviceId) async => value = deviceId;
}

class _MemoryRootBindingStore implements DeviceRootBindingStore {
  String? value;

  @override
  Future<void> clearRootFingerprint() async => value = null;

  @override
  Future<String?> readRootFingerprint() async => value;

  @override
  Future<void> writeRootFingerprint(String fingerprint) async {
    value = fingerprint;
  }
}

class _FakeDeviceKeyPlatform implements DeviceKeyPlatformAdapter {
  _FakeDeviceKeyPlatform({this.current, this.upgraded, this.loadError});

  final PlatformDeviceKeyIdentity? current;
  final PlatformDeviceKeyIdentity? upgraded;
  final Object? loadError;
  int upgradeCalls = 0;

  @override
  bool get supported => true;

  @override
  bool get supportsIdentityRecovery => true;

  @override
  Future<PlatformDeviceKeyIdentity> loadOrCreateIdentity() async {
    if (loadError case final error?) throw error;
    return current!;
  }

  @override
  Future<PlatformDeviceKeyIdentity> resetIdentity() async => upgraded!;

  @override
  Future<PlatformDeviceKeyIdentity> rotateAuthenticationKey() async => current!;

  @override
  Future<Uint8List> signWithAuthenticationKey(Uint8List message) async =>
      Uint8List.fromList(message);

  @override
  Future<Uint8List> signWithRoot(Uint8List message) async =>
      Uint8List.fromList(message);

  @override
  Future<PlatformDeviceKeyIdentity> upgradeToHardwareIdentity() async {
    upgradeCalls += 1;
    return upgraded!;
  }

  @override
  Future<bool> verifyP256Signature({
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) async => true;
}
