import 'package:cross_desktop_remote/features/remote/presentation/remote_pointer_event_coalescer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps only the latest absolute pointer position', () {
    final coalescer = RemotePointerEventCoalescer()
      ..add(const RemotePointerPacket(phase: 'move', x: 0.1, y: 0.2))
      ..add(const RemotePointerPacket(phase: 'move', x: 0.8, y: 0.9));

    final packet = coalescer.drain().single;
    expect(packet.x, 0.8);
    expect(packet.y, 0.9);
    expect(coalescer.isEmpty, isTrue);
  });

  test(
    'accumulates relative movement so coalescing does not lose distance',
    () {
      final coalescer = RemotePointerEventCoalescer()
        ..add(
          const RemotePointerPacket(
            phase: 'move',
            mode: 'relative',
            x: 0.5,
            y: 0.5,
            movementX: 3,
            movementY: -2,
          ),
        )
        ..add(
          const RemotePointerPacket(
            phase: 'move',
            mode: 'relative',
            x: 0.5,
            y: 0.5,
            movementX: 4,
            movementY: 5,
          ),
        );

      final packet = coalescer.drain().single;
      expect(packet.movementX, 7);
      expect(packet.movementY, 3);
    },
  );

  test('accumulates scroll deltas separately from movement', () {
    final coalescer = RemotePointerEventCoalescer()
      ..add(
        const RemotePointerPacket(
          phase: 'scroll',
          mode: 'relative',
          x: 0.5,
          y: 0.5,
          deltaY: 5,
        ),
      )
      ..add(
        const RemotePointerPacket(
          phase: 'scroll',
          mode: 'relative',
          x: 0.5,
          y: 0.5,
          deltaY: -2,
        ),
      );

    final packet = coalescer.drain().single;
    expect(packet.deltaY, 3);
  });
}
