import 'package:cross_desktop_remote/core/input/host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/mac_host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/unsupported_host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/windows_host_platform_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const inputChannel = MethodChannel(
    'com.crossdesktopremote.cross_desktop_remote/input',
  );

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(inputChannel, null);
  });

  test('Mac adapter maps native displays and permission state', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(inputChannel, (call) async {
          return switch (call.method) {
            'listDisplays' => [
              {
                'id': '42',
                'name': 'Built-in Display',
                'width': 1512,
                'height': 982,
                'pixelWidth': 3024,
                'pixelHeight': 1964,
                'pointPixelScale': 2.0,
                'isPrimary': true,
              },
            ],
            'checkInputAccess' => true,
            _ => null,
          };
        });

    const adapter = MacHostPlatformAdapter();
    final displays = await adapter.listDisplays();
    final permission = await adapter.checkPermissions();

    expect(adapter.type, HostPlatformType.macOS);
    expect(adapter.capabilities.captureFrameReadiness, isTrue);
    expect(displays.single.id, '42');
    expect(displays.single.pixelWidth, 3024);
    expect(displays.single.isPrimary, isTrue);
    expect(permission.inputGranted, isTrue);
  });

  test('Mac adapter preserves generic pointer and key protocol', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(inputChannel, (call) async {
          calls.add(call);
          return null;
        });

    const adapter = MacHostPlatformAdapter();
    await adapter.sendPointer(
      const HostPointerEvent(
        phase: 'down',
        x: .25,
        y: .75,
        displayId: '42',
        button: 'right',
      ),
    );
    await adapter.sendKey(
      const HostKeyEvent(
        phase: 'down',
        key: 'KeyC',
        modifiers: ['control'],
        physicalHidUsage: 0x70006,
      ),
    );
    await adapter.sendText('你好');

    expect(calls.map((call) => call.method), [
      'pointer',
      'keyboard',
      'keyboard',
    ]);
    expect((calls[0].arguments as Map)['displayId'], '42');
    expect((calls[1].arguments as Map)['key'], 'KeyC');
    expect((calls[2].arguments as Map)['text'], '你好');
  });

  test(
    'unsupported adapter exposes capabilities without native calls',
    () async {
      const adapter = UnsupportedHostPlatformAdapter();

      expect(adapter.capabilities.canHostDesktop, isFalse);
      expect(await adapter.listDisplays(), isEmpty);
      expect((await adapter.checkPermissions()).inputGranted, isFalse);
      await expectLater(
        adapter.sendText('text'),
        throwsA(isA<UnsupportedError>()),
      );
    },
  );

  test('Windows adapter does not advertise unverified host support', () async {
    const adapter = WindowsHostPlatformAdapter();

    expect(adapter.type, HostPlatformType.windows);
    expect(adapter.capabilities.canHostDesktop, isFalse);
    expect((await adapter.checkPermissions()).limitation, contains('Windows'));
  });
}
