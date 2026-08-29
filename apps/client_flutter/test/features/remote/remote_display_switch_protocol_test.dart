import 'package:cross_desktop_remote/features/remote/application/remote_display_switch_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps the control wire version independent from geometry versions', () {
    final message = remoteDisplaySwitchMessage(
      type: 'display-selected',
      displayId: 'secondary',
      generation: 7,
      payload: const {'version': 3, 'activeContentGeometryVersion': 3},
    );

    expect(message['version'], remoteDisplaySwitchWireVersion);
    expect(message['activeContentGeometryVersion'], 3);
    expect(isSupportedRemoteDisplaySwitchMessage(message), isTrue);
  });
}
