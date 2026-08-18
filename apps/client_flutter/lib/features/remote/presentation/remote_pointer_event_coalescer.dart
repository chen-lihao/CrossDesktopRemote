import 'dart:collection';

class RemotePointerPacket {
  const RemotePointerPacket({
    required this.phase,
    required this.x,
    required this.y,
    this.mode = 'absolute',
    this.button = 'left',
    this.clickCount = 1,
    this.movementX = 0,
    this.movementY = 0,
    this.deltaX = 0,
    this.deltaY = 0,
  });

  final String phase;
  final String mode;
  final String button;
  final int clickCount;
  final double x;
  final double y;
  final double movementX;
  final double movementY;
  final double deltaX;
  final double deltaY;

  bool get canCoalesce => phase == 'move' || phase == 'scroll';

  String get coalescingKey => '$phase:$mode:$button';

  RemotePointerPacket merge(RemotePointerPacket newer) {
    assert(coalescingKey == newer.coalescingKey);
    if (phase == 'move' && mode == 'absolute') {
      return newer;
    }
    return RemotePointerPacket(
      phase: phase,
      mode: mode,
      button: newer.button,
      clickCount: newer.clickCount,
      x: newer.x,
      y: newer.y,
      movementX: movementX + newer.movementX,
      movementY: movementY + newer.movementY,
      deltaX: deltaX + newer.deltaX,
      deltaY: deltaY + newer.deltaY,
    );
  }
}

/// Keeps only the latest absolute position while accumulating relative motion.
class RemotePointerEventCoalescer {
  final LinkedHashMap<String, RemotePointerPacket> _pending = LinkedHashMap();

  bool get isEmpty => _pending.isEmpty;
  int get pendingCount => _pending.length;

  void add(RemotePointerPacket packet) {
    if (!packet.canCoalesce) {
      throw ArgumentError.value(packet.phase, 'phase', 'is not coalescible');
    }
    final previous = _pending[packet.coalescingKey];
    _pending[packet.coalescingKey] = previous == null
        ? packet
        : previous.merge(packet);
  }

  List<RemotePointerPacket> drain() {
    final packets = _pending.values.toList(growable: false);
    _pending.clear();
    return packets;
  }

  void clear() => _pending.clear();
}
