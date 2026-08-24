import 'package:cross_desktop_remote/core/input/mac_input_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a native capture first-frame state', () {
    final state = MacCaptureFrameState.fromMap(const {
      'sequence': 12,
      'sourceId': '69733382',
      'width': 1310,
      'height': 892,
    });

    expect(state.sequence, 12);
    expect(state.sourceId, '69733382');
    expect(state.width, 1310);
    expect(state.height, 892);
  });

  test('uses an empty non-ready state for missing native values', () {
    final state = MacCaptureFrameState.fromMap(const {});

    expect(state.sequence, 0);
    expect(state.sourceId, isEmpty);
    expect(state.width, 0);
    expect(state.height, 0);
  });
}
