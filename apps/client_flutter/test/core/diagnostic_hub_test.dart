import 'dart:convert';
import 'dart:io';

import 'package:cross_desktop_remote/core/diagnostics/diagnostic_event.dart';
import 'package:cross_desktop_remote/core/diagnostics/diagnostic_hub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buffers startup events until local storage is ready', () async {
    final directory = await Directory.systemTemp.createTemp('cdr-diag-test-');
    addTearDown(() => directory.delete(recursive: true));
    final hub = DiagnosticHub.forTesting();

    hub.record(component: 'app.lifecycle', name: 'before_initialize');
    await hub.initialize(rootDirectory: directory);
    await hub.flush();

    final log = File('${directory.path}/diagnostics-v1/events-0.jsonl');
    final names = (await log.readAsLines())
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .map((event) => event['event'])
        .toList();
    expect(names, contains('before_initialize'));
    expect(names, contains('process_started'));
  });

  test('persists structured events after mandatory redaction', () async {
    final directory = await Directory.systemTemp.createTemp('cdr-diag-test-');
    addTearDown(() => directory.delete(recursive: true));
    final hub = DiagnosticHub.forTesting();
    await hub.initialize(rootDirectory: directory);

    hub.record(
      component: 'signaling.websocket',
      name: 'failed',
      context: const DiagnosticContext(
        traceId: '11111111111111111111111111111111',
        attemptId: '22222222222222222222222222222222',
      ),
      attributes: {
        'roomCode': '123456',
        'peerAddress': '192.168.1.20',
        'message': 'connect 192.168.1.20 with code 123456',
      },
    );
    await hub.flush();

    final log = File('${directory.path}/diagnostics-v1/events-0.jsonl');
    final lines = await log.readAsLines();
    final event = jsonDecode(lines.last) as Map<String, dynamic>;
    final attributes = event['attributes'] as Map<String, dynamic>;
    expect(attributes['roomCode'], '[redacted]');
    expect(attributes['peerAddress'], startsWith('<hash:'));
    expect(attributes['message'], isNot(contains('192.168.1.20')));
    expect(attributes['message'], isNot(contains('123456')));
    expect(event['traceId'], '11111111111111111111111111111111');
  });

  test('exports a bounded local diagnostic package', () async {
    final directory = await Directory.systemTemp.createTemp('cdr-diag-test-');
    addTearDown(() => directory.delete(recursive: true));
    final hub = DiagnosticHub.forTesting();
    await hub.initialize(rootDirectory: directory);
    hub.record(component: 'session.state', name: 'streaming');
    await hub.flush();

    final result = await hub.exportBundle();
    final payload = jsonDecode(
      await File(result.path).readAsString(),
    ) as Map<String, dynamic>;

    expect(result.eventCount, greaterThanOrEqualTo(2));
    expect(payload['format'], 'crossdesktop-diagnostics');
    expect((payload['privacy'] as Map)['automaticUpload'], isFalse);
    expect((payload['events'] as List), isNotEmpty);
  });
}
