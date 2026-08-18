import 'package:cross_desktop_remote/features/remote/application/remote_input_sequence_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('motion overtaking a reliable event does not discard that event', () {
    final guard = RemoteInputSequenceGuard();

    expect(guard.accept(11, motion: true), isTrue);
    expect(guard.accept(10, motion: false), isTrue);
    expect(guard.accept(10, motion: false), isFalse);
  });

  test('stale motion is rejected independently of reliable input', () {
    final guard = RemoteInputSequenceGuard();

    expect(guard.accept(20, motion: false), isTrue);
    expect(guard.accept(18, motion: true), isTrue);
    expect(guard.accept(17, motion: true), isFalse);
  });
}
