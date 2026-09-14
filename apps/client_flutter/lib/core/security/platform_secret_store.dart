import 'dart:convert';

import 'package:flutter/services.dart';

/// Small, purpose-built bridge for secrets that protect local encrypted data.
///
/// The native implementations keep the secret in the platform account scope:
/// Apple Keychain with ThisDeviceOnly accessibility, or Windows DPAPI bound to
/// the current user. Callers only receive the unwrapped key while the process
/// is running; no plaintext key is persisted by Dart.
abstract interface class PlatformSecretStore {
  Future<Uint8List> loadOrCreate(String name, {int length = 32});

  Future<void> delete(String name);
}

class MethodChannelPlatformSecretStore implements PlatformSecretStore {
  MethodChannelPlatformSecretStore({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel(
            'com.crossdesktopremote.cross_desktop_remote/device_identity',
          );

  final MethodChannel _channel;

  @override
  Future<Uint8List> loadOrCreate(String name, {int length = 32}) async {
    if (!_validName(name) || length < 16 || length > 64) {
      throw ArgumentError('Invalid platform secret request');
    }
    final encoded = await _channel.invokeMethod<String>('loadOrCreateSecret', {
      'name': name,
      'length': length,
    });
    if (encoded == null || encoded.isEmpty) {
      throw PlatformException(
        code: 'platform_secret_unavailable',
        message: 'Native secret store returned no value',
      );
    }
    final value = base64Decode(encoded);
    if (value.length != length) {
      throw PlatformException(
        code: 'platform_secret_invalid',
        message: 'Native secret store returned an invalid value',
      );
    }
    return value;
  }

  @override
  Future<void> delete(String name) async {
    if (!_validName(name)) throw ArgumentError('Invalid platform secret name');
    await _channel.invokeMethod<void>('deleteSecret', {'name': name});
  }

  static bool _validName(String value) =>
      RegExp(r'^[a-z0-9][a-z0-9._-]{0,127}$').hasMatch(value);
}
