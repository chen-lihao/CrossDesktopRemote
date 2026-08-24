import 'package:cross_desktop_remote/features/sessions/application/session_history_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('session metadata round trips without screen or input content', () {
    final startedAt = DateTime.utc(2026, 8, 24, 1, 2, 3);
    final original = SessionRecord(
      id: 'session-1',
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(minutes: 3)),
      role: 'controller',
      deviceName: 'MacBook',
      displayName: 'Sidecar Display',
      quality: '超清 2K',
      outcome: '正常断开',
    );

    final json = original.toJson();
    final decoded = SessionRecord.fromJson(json);

    expect(decoded.id, original.id);
    expect(decoded.duration, const Duration(minutes: 3));
    expect(decoded.displayName, 'Sidecar Display');
    expect(json, isNot(contains('screenContent')));
    expect(json, isNot(contains('keyboardInput')));
  });
}
