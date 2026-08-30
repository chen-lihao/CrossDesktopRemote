import 'dart:math';

import 'package:cross_desktop_remote/core/identity/device_identity.dart';
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
}

class _MemoryIdentityStore implements DeviceIdentityStore {
  String? value;

  @override
  Future<String?> readDeviceId() async => value;

  @override
  Future<void> writeDeviceId(String deviceId) async => value = deviceId;
}
