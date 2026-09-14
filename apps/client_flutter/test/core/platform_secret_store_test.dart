import 'dart:convert';

import 'package:cross_desktop_remote/core/security/platform_secret_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.platform-secret-store');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('loads an exact-length native protected secret', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return base64Encode(List<int>.generate(32, (index) => index));
        });

    final value = await MethodChannelPlatformSecretStore(
      channel: channel,
    ).loadOrCreate('trusted-device.database-key.v1');

    expect(value, hasLength(32));
    expect(received?.method, 'loadOrCreateSecret');
    expect(received?.arguments, {
      'name': 'trusted-device.database-key.v1',
      'length': 32,
    });
  });

  test('rejects malformed requests before calling native code', () async {
    var invoked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          invoked = true;
          return null;
        });

    final store = MethodChannelPlatformSecretStore(channel: channel);

    await expectLater(
      store.loadOrCreate('../unsafe'),
      throwsA(isA<ArgumentError>()),
    );
    expect(invoked, isFalse);
  });

  test('fails closed when native returns the wrong secret length', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => base64Encode(List<int>.filled(16, 1)),
        );

    await expectLater(
      MethodChannelPlatformSecretStore(channel: channel).loadOrCreate('audit'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'platform_secret_invalid',
        ),
      ),
    );
  });
}
