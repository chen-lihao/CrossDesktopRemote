import 'package:cross_desktop_remote/core/clipboard/clipboard_platform_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('clipboard-test-methods');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  test('snapshot parser preserves native revision and size metadata', () {
    final snapshot = ClipboardSnapshot.fromMap(const {
      'revision': 42,
      'hasText': true,
      'tooLarge': false,
      'utf8Bytes': 6,
      'text': '中文',
    });

    expect(snapshot.revision, 42);
    expect(snapshot.hasText, isTrue);
    expect(snapshot.utf8Bytes, 6);
    expect(snapshot.text, '中文');
  });

  test('method channel reads and writes bounded UTF-8 text', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          return {
            'revision': calls.length,
            'hasText': true,
            'tooLarge': false,
            'utf8Bytes': 5,
            'text': call.method == 'writeText'
                ? (call.arguments as Map)['text']
                : 'hello',
          };
        });
    final adapter = MethodChannelClipboardPlatformAdapter(
      methodChannel: methodChannel,
      eventChannel: const EventChannel('clipboard-test-events'),
    );

    expect((await adapter.readSnapshot()).text, 'hello');
    expect((await adapter.writeText('你好')).text, '你好');
    expect(calls.map((call) => call.method), ['getSnapshot', 'writeText']);
  });

  test(
    'user initiated adapter never monitors and reads only on demand',
    () async {
      var reads = 0;
      var written = '';
      final adapter = UserInitiatedClipboardPlatformAdapter(
        readText: () async {
          reads += 1;
          return 'iPad 粘贴';
        },
        writeText: (text) async => written = text,
      );

      expect(adapter.automaticMonitoringSupported, isFalse);
      expect(await adapter.changes.isEmpty, isTrue);
      expect(reads, 0);

      final snapshot = await adapter.readSnapshot();
      expect(reads, 1);
      expect(snapshot.text, 'iPad 粘贴');
    expect(snapshot.utf8Bytes, 11);

      await adapter.writeText('remote');
      expect(written, 'remote');
    },
  );
}
