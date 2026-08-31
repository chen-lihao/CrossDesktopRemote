import 'package:cross_desktop_remote/core/input/host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/mac_host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/unsupported_host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/windows_host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/windows_input_bridge.dart';
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
        modifiers: ['command', 'shift'],
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
    await adapter.invokeShortcut(key: 'KeyV', modifiers: const ['command']);
    await adapter.releaseKeyboardState();
    await adapter.releaseAllInput();

    expect(calls.map((call) => call.method), [
      'pointer',
      'keyboard',
      'keyboard',
      'invokeShortcut',
      'releaseKeyboardState',
      'releaseAllInput',
    ]);
    expect((calls[0].arguments as Map)['displayId'], '42');
    expect((calls[0].arguments as Map)['modifiers'], ['command', 'shift']);
    expect((calls[1].arguments as Map)['key'], 'KeyC');
    expect((calls[2].arguments as Map)['text'], '你好');
  });

  test('Mac adapter exposes the canonical active capture rectangle', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(inputChannel, (call) async {
          if (call.method != 'getCaptureFrameState') return null;
          return {
            'sequence': 4,
            'sourceId': 'sidecar',
            'width': 1920,
            'height': 1080,
            'captureGeneration': 3,
            'activeContentX': 160.0,
            'activeContentY': 0.0,
            'activeContentWidth': 1600.0,
            'activeContentHeight': 1080.0,
          };
        });

    final state = await const MacHostPlatformAdapter().getCaptureFrameState();

    expect(state, isNotNull);
    expect(state!.hasValidActiveContent, isTrue);
    expect(state.activeContentWidth, 1600);
    expect(state.sourceId, 'sidecar');
  });

  test('capture readiness is bound to generation and active content', () {
    const state = HostCaptureFrameState(
      sequence: 8,
      sourceId: 'sidecar',
      width: 1920,
      height: 1080,
      captureGeneration: 5,
      gateStatus: 'ready',
      rejectionReason: '',
      staleFrameCount: 0,
      wrongSizeCount: 0,
      missingContentMetadataCount: 0,
      contentAspectMismatchCount: 0,
      normalizationFailureCount: 0,
      bufferWidth: 1920,
      bufferHeight: 1080,
      activeContentX: 0,
      activeContentY: 0,
      activeContentWidth: 1920,
      activeContentHeight: 1000,
    );

    expect(
      state.isReadyAfter(
        sequence: 7,
        targetSourceId: 'sidecar',
        targetCaptureGeneration: 5,
        requireActiveContent: true,
      ),
      isTrue,
    );
    expect(
      state.isReadyAfter(
        sequence: 7,
        targetSourceId: 'sidecar',
        targetCaptureGeneration: 4,
        requireActiveContent: true,
      ),
      isFalse,
    );
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

  test(
    'Windows adapter enables host only through a compatible bridge',
    () async {
      final bridge = _FakeWindowsInputBridge();
      final adapter = WindowsHostPlatformAdapter(bridge: bridge);

      expect(adapter.type, HostPlatformType.windows);
      expect(adapter.capabilities.canHostDesktop, isTrue);
      final permission = await adapter.requestPermissions();
      expect(permission.inputGranted, isTrue);
      expect(permission.limitation, contains('UAC'));
      expect((await adapter.listDisplays()).single.pixelWidth, 1920);

      await adapter.sendPointer(
        const HostPointerEvent(
          phase: 'down',
          x: .5,
          y: .5,
          displayId: r'\\.\DISPLAY1',
        ),
      );
      await adapter.sendKey(
        const HostKeyEvent(
          phase: 'down',
          key: 'KeyA',
          modifiers: ['control'],
          physicalHidUsage: 0x70004,
        ),
      );
      await adapter.sendText('中文');
      await adapter.invokeShortcut(key: 'KeyV', modifiers: const ['control']);
      await adapter.releaseKeyboardState();
      await adapter.releaseAllInput();

      expect(bridge.pointerEvents.single.displayId, r'\\.\DISPLAY1');
      expect(bridge.keyEvents.single.physicalHidUsage, 0x70004);
      expect(bridge.textValues, ['中文']);
      expect(bridge.shortcuts.single.key, 'KeyV');
      expect(bridge.keyboardReleaseCount, 1);
      expect(bridge.releaseCount, 1);
    },
  );

  test('Windows method channel preserves the native host contract', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(inputChannel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'getHostCapabilities' => {
              'protocolVersion': 1,
              'canHostDesktop': true,
              'canInjectInput': true,
              'canEnumerateDisplays': true,
              'supportsUnicode': true,
              'supportsVirtualDesktop': true,
              'limitation': 'UAC secure desktop is unavailable',
            },
            'listDisplays' => [
              {
                'id': r'\\.\DISPLAY1',
                'name': 'DISPLAY1',
                'width': 1536,
                'height': 864,
                'pixelWidth': 1920,
                'pixelHeight': 1080,
                'pointPixelScale': 1.25,
                'isPrimary': true,
              },
            ],
            _ => null,
          };
        });

    const bridge = WindowsInputBridge();
    final capabilities = await bridge.getHostCapabilities();
    final displays = await bridge.listDisplays();
    await bridge.sendPointer(
      const HostPointerEvent(
        phase: 'scroll',
        x: .5,
        y: .5,
        displayId: r'\\.\DISPLAY1',
        deltaY: 20,
        modifiers: ['control'],
      ),
    );
    await bridge.sendKey(
      const HostKeyEvent(
        phase: 'down',
        key: 'KeyC',
        modifiers: ['control'],
        physicalHidUsage: 0x70006,
      ),
    );
    await bridge.sendText('你好');
    await bridge.invokeShortcut(key: 'KeyV', modifiers: const ['control']);
    await bridge.releaseKeyboardState();
    await bridge.releaseAllInput();

    expect(capabilities.isCompatible, isTrue);
    expect(displays.single.pointPixelScale, 1.25);
    expect(calls.map((call) => call.method), [
      'getHostCapabilities',
      'listDisplays',
      'pointer',
      'keyboard',
      'keyboard',
      'invokeShortcut',
      'releaseKeyboardState',
      'releaseAllInput',
    ]);
    expect((calls[3].arguments as Map)['physicalHidUsage'], 0x70006);
    expect((calls[4].arguments as Map)['text'], '你好');
    expect((calls[2].arguments as Map)['modifiers'], ['control']);
  });

  test('Windows adapter rejects an incompatible native bridge', () async {
    final adapter = WindowsHostPlatformAdapter(
      bridge: _FakeWindowsInputBridge(protocolVersion: 0),
    );

    final permission = await adapter.checkPermissions();
    expect(permission.inputGranted, isFalse);
    await expectLater(adapter.requestPermissions(), throwsA(isA<StateError>()));
  });
}

class _FakeWindowsInputBridge implements WindowsInputBridgeApi {
  _FakeWindowsInputBridge({this.protocolVersion = 1});

  final int protocolVersion;
  final pointerEvents = <HostPointerEvent>[];
  final keyEvents = <HostKeyEvent>[];
  final shortcuts = <({String key, List<String> modifiers})>[];
  final textValues = <String>[];
  int releaseCount = 0;
  int keyboardReleaseCount = 0;

  @override
  Future<void> invokeShortcut({
    required String key,
    required List<String> modifiers,
  }) async {
    shortcuts.add((key: key, modifiers: modifiers));
  }

  @override
  Future<WindowsNativeHostCapabilities> getHostCapabilities() async {
    return WindowsNativeHostCapabilities(
      protocolVersion: protocolVersion,
      canHostDesktop: true,
      canInjectInput: true,
      canEnumerateDisplays: true,
      supportsUnicode: true,
      supportsVirtualDesktop: true,
      limitation: 'UAC secure desktop is unavailable',
    );
  }

  @override
  Future<List<HostDisplay>> listDisplays() async {
    return const [
      HostDisplay(
        id: r'\\.\DISPLAY1',
        name: 'DISPLAY1',
        width: 1920,
        height: 1080,
        pixelWidth: 1920,
        pixelHeight: 1080,
        pointPixelScale: 1,
        isPrimary: true,
      ),
    ];
  }

  @override
  Future<void> releasePointerButtons() async {
    releaseCount += 1;
  }

  @override
  Future<void> releaseKeyboardState() async {
    keyboardReleaseCount += 1;
  }

  @override
  Future<void> releaseAllInput() async {
    releaseCount += 1;
  }

  @override
  Future<void> sendKey(HostKeyEvent event) async {
    keyEvents.add(event);
  }

  @override
  Future<void> sendPointer(HostPointerEvent event) async {
    pointerEvents.add(event);
  }

  @override
  Future<void> sendText(String text) async {
    textValues.add(text);
  }
}
