import 'package:cross_desktop_remote/core/files/file_paste_target_platform_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/file_paste_target');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('native interception follows the aggregate session ownership', () async {
    final transitions = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'setRemoteOfferAvailable');
          final arguments = call.arguments as Map<Object?, Object?>;
          transitions.add(arguments['available']! as bool);
          return null;
        });
    final adapter = MethodChannelFilePasteTargetPlatformAdapter(
      channel: channel,
    );

    await adapter.setRemoteOfferAvailable(
      ownerId: 'controller',
      available: true,
    );
    await adapter.setRemoteOfferAvailable(ownerId: 'host', available: true);
    await adapter.setRemoteOfferAvailable(
      ownerId: 'controller',
      available: false,
    );
    await adapter.setRemoteOfferAvailable(ownerId: 'host', available: false);

    expect(transitions, [true, false]);
  });

  test('failed native registration rolls back the owner', () async {
    var shouldFail = true;
    final transitions = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final arguments = call.arguments as Map<Object?, Object?>;
          transitions.add(arguments['available']! as bool);
          if (shouldFail) {
            shouldFail = false;
            throw PlatformException(code: 'registration_failed');
          }
          return null;
        });
    final adapter = MethodChannelFilePasteTargetPlatformAdapter(
      channel: channel,
    );

    await expectLater(
      adapter.setRemoteOfferAvailable(ownerId: 'controller', available: true),
      throwsA(isA<PlatformException>()),
    );
    await adapter.setRemoteOfferAvailable(ownerId: 'host', available: true);

    expect(transitions, [true, true]);
  });

  test(
    'target validation sends only local path and directory identity',
    () async {
      MethodCall? invocation;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            invocation = call;
            return true;
          });
      final adapter = MethodChannelFilePasteTargetPlatformAdapter(
        channel: channel,
      );

      final valid = await adapter.validateTarget(
        const FilePasteTarget(
          path: '/tmp/target',
          displayName: 'target',
          application: 'Finder',
          directoryIdentity: '1:42',
          writable: true,
        ),
      );

      expect(valid, isTrue);
      expect(invocation?.method, 'validateTarget');
      expect(invocation?.arguments, {
        'path': '/tmp/target',
        'directoryIdentity': '1:42',
      });
    },
  );
}
