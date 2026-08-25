import 'package:cross_desktop_remote/core/input/remote_ime_input_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a committed text event', () {
    final event = RemoteImeInputEvent.tryParse({
      'clientId': 'surface-1',
      'type': 'commit',
      'text': '你好',
    });

    expect(event, isNotNull);
    expect(event!.type, RemoteImeInputEventType.commit);
    expect(event.text, '你好');
  });

  test('parses privacy-safe diagnostic metadata', () {
    final event = RemoteImeInputEvent.tryParse({
      'clientId': 'surface-1',
      'type': 'diagnostic',
      'name': 'setMarkedText',
      'markedLength': 5,
      'containsCjk': false,
    });

    expect(event, isNotNull);
    expect(event!.diagnosticName, 'setMarkedText');
    expect(event.markedLength, 5);
    expect(event.containsCjk, isFalse);
    expect(event.text, isEmpty);
  });

  test('parses docked and floating keyboard geometry', () {
    final event = RemoteImeInputEvent.tryParse({
      'clientId': 'surface-1',
      'type': 'keyboardFrame',
      'visible': true,
      'x': 30,
      'y': 500,
      'width': 700,
      'height': 280,
      'docked': false,
    });

    expect(event, isNotNull);
    expect(event!.type, RemoteImeInputEventType.keyboardFrame);
    expect(event.keyboardVisible, isTrue);
    expect(event.keyboardDocked, isFalse);
    expect(event.keyboardFrame, const Rect.fromLTWH(30, 500, 700, 280));
  });

  test('rejects malformed or unknown native events', () {
    expect(RemoteImeInputEvent.tryParse(null), isNull);
    expect(RemoteImeInputEvent.tryParse({'type': 'commit'}), isNull);
    expect(
      RemoteImeInputEvent.tryParse({
        'clientId': 'surface-1',
        'type': 'unknown',
      }),
      isNull,
    );
  });
}
