import 'package:cross_desktop_remote/core/protocol/wire_value_parsers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wireBool preserves JSON booleans', () {
    expect(wireBool(true), isTrue);
    expect(wireBool(false), isFalse);
  });

  test('wireBool accepts native NSNumber boolean values', () {
    expect(wireBool(1), isTrue);
    expect(wireBool(0), isFalse);
    expect(wireBool(-1), isTrue);
  });

  test('wireBool safely falls back for unsupported values', () {
    expect(wireBool(null), isFalse);
    expect(wireBool('true'), isFalse);
    expect(wireBool(null, fallback: true), isTrue);
  });
}
