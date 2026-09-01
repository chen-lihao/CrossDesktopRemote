import 'dart:io';

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

  test(
    'desktop startup scavenger removes expired managed and legacy dirs',
    () async {
      final systemTemp = await Directory.systemTemp.createTemp(
        'crossdesktop-platform-test-',
      );
      addTearDown(() async {
        if (await systemTemp.exists()) await systemTemp.delete(recursive: true);
      });
      final adapter = DesktopExplicitFileTransferPlatformAdapter(
        systemTemp: systemTemp,
      );
      final managed = await Directory(
        [
          systemTemp.path,
          'CrossDesktopRemote',
          'clipboard',
          'managed-test',
        ].join(Platform.pathSeparator),
      ).create(recursive: true);
      final legacy = await systemTemp.createTemp(
        'crossdesktop-file-clipboard-legacy-',
      );

      await Future<void>.delayed(const Duration(milliseconds: 2));
      await adapter.cleanupOrphanedClipboardReceiveDirectories(
        maxAge: Duration.zero,
      );

      expect(await managed.exists(), isFalse);
      expect(await legacy.exists(), isFalse);
    },
  );
}
