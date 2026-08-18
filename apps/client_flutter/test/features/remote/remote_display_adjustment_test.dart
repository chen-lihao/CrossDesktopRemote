import 'package:cross_desktop_remote/features/remote/presentation/remote_display_adjustment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic and standard SDR keep an identity matrix', () {
    expect(const RemoteDisplayAdjustment().isIdentity, isTrue);
    expect(
      const RemoteDisplayAdjustment(
        mode: RemoteDisplayAdjustmentMode.standardSdr,
      ).colorMatrix,
      const [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
    );
  });

  test('soft highlights lowers white without flattening adjacent values', () {
    const adjustment = RemoteDisplayAdjustment(
      mode: RemoteDisplayAdjustmentMode.softHighlights,
    );
    final matrix = adjustment.colorMatrix;

    double output(double input) {
      return matrix[0] * input +
          matrix[1] * input +
          matrix[2] * input +
          matrix[4];
    }

    expect(output(255), lessThan(240));
    expect(output(251), lessThan(output(255)));
    expect(output(247), lessThan(output(251)));
  });

  test('settings are isolated by remote device and display', () async {
    final store = _MemoryStore();
    final controller = RemoteDisplayAdjustmentController(store: store);

    await controller.selectTarget(deviceId: 'mac-a', displayId: 'main');
    controller.updateCustom(brightness: -0.1);
    await Future<void>.delayed(Duration.zero);

    await controller.selectTarget(deviceId: 'mac-a', displayId: 'external');
    expect(controller.value.mode, RemoteDisplayAdjustmentMode.automatic);
    controller.setMode(RemoteDisplayAdjustmentMode.softHighlights);
    await Future<void>.delayed(Duration.zero);

    await controller.selectTarget(deviceId: 'mac-a', displayId: 'main');
    expect(controller.value.mode, RemoteDisplayAdjustmentMode.custom);
    expect(controller.value.brightness, -0.1);
  });
}

class _MemoryStore implements RemoteDisplayAdjustmentStore {
  final values = <String, RemoteDisplayAdjustment>{};

  @override
  Future<RemoteDisplayAdjustment?> load(String key) async => values[key];

  @override
  Future<void> remove(String key) async => values.remove(key);

  @override
  Future<void> save(String key, RemoteDisplayAdjustment value) async {
    values[key] = value;
  }
}
