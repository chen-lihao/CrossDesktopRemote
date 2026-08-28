import 'package:cross_desktop_remote/core/files/explicit_file_transfer_platform_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ios-file-transfer-test');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'iOS file adapter delegates user actions to the native bridge',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'pickOutgoingFiles' => <String>['/staged/report.pdf'],
              'createReceiveDirectory' => '/managed/incoming/transfer-1',
              _ => null,
            };
          });
      final adapter = IosExplicitFileTransferPlatformAdapter(channel: channel);

      expect(adapter.supported, isTrue);
      expect(adapter.supportsDirectorySelection, isFalse);
      expect(adapter.usesManagedReceiveStorage, isTrue);
      expect(await adapter.pickOutgoingFiles(), ['/staged/report.pdf']);
      expect(
        await adapter.createReceiveDirectory('transfer-1'),
        '/managed/incoming/transfer-1',
      );
      await adapter.exportReceivedFiles(['/managed/incoming/transfer-1/a.txt']);
      await adapter.shareReceivedFiles(['/managed/incoming/transfer-1/a.txt']);
      await adapter.cleanupOutgoingFiles(['/staged/report.pdf']);

      expect(calls.map((call) => call.method), [
        'pickOutgoingFiles',
        'createReceiveDirectory',
        'exportReceivedFiles',
        'shareReceivedFiles',
        'cleanupOutgoingFiles',
      ]);
    },
  );
}
