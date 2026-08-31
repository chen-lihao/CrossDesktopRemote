import 'package:cross_desktop_remote/core/input/remote_input_reset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('input reset scopes have stable wire values', () {
    for (final scope in RemoteInputResetScope.values) {
      expect(parseRemoteInputResetScope(scope.wireValue), scope);
    }
  });

  test('unknown reset scope is rejected instead of becoming a full reset', () {
    expect(parseRemoteInputResetScope('everything'), isNull);
    expect(parseRemoteInputResetScope(null), isNull);
  });
}
