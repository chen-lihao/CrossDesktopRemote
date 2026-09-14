import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

enum PlatformDeviceKeyProtection {
  secureHardware,
  osProtected,
  legacySoftware,
  unknown,
}

enum PlatformDeviceKeySecurityState {
  readyHardwareProtected,
  readyOsProtected,
  migrationRequired,
}

class PlatformDeviceKeyIdentity {
  const PlatformDeviceKeyIdentity({
    required this.rootKeyHandle,
    required this.rootPublicKey,
    required this.authenticationKeyHandle,
    required this.authenticationPublicKey,
    required this.authenticationNotBefore,
    required this.authenticationExpiresAt,
    required this.authenticationCertificate,
    required this.protection,
    required this.securityState,
    this.diagnosticCode,
    this.diagnosticMessage,
  });

  final String rootKeyHandle;
  final Uint8List rootPublicKey;
  final String authenticationKeyHandle;
  final Uint8List authenticationPublicKey;
  final DateTime authenticationNotBefore;
  final DateTime authenticationExpiresAt;
  final Uint8List authenticationCertificate;
  final PlatformDeviceKeyProtection protection;
  final PlatformDeviceKeySecurityState securityState;
  final String? diagnosticCode;
  final String? diagnosticMessage;

  bool get hardwareBacked =>
      protection == PlatformDeviceKeyProtection.secureHardware;

  factory PlatformDeviceKeyIdentity.fromMap(Map<Object?, Object?> value) {
    Uint8List bytes(String key) {
      final encoded = value[key] as String?;
      if (encoded == null || encoded.isEmpty) {
        throw PlatformException(
          code: 'invalid_device_identity',
          message: 'Missing $key from native device identity',
        );
      }
      return base64Decode(encoded);
    }

    final hardwareBacked = value['hardwareBacked'] == true;
    final protection = switch (value['protection'] as String?) {
      'secureHardware' => PlatformDeviceKeyProtection.secureHardware,
      'osProtected' => PlatformDeviceKeyProtection.osProtected,
      'legacySoftware' => PlatformDeviceKeyProtection.legacySoftware,
      _ =>
        hardwareBacked
            ? PlatformDeviceKeyProtection.secureHardware
            : PlatformDeviceKeyProtection.osProtected,
    };
    final securityState = switch (value['securityState'] as String?) {
      'readyHardwareProtected' =>
        PlatformDeviceKeySecurityState.readyHardwareProtected,
      'readyOsProtected' => PlatformDeviceKeySecurityState.readyOsProtected,
      'migrationRequired' => PlatformDeviceKeySecurityState.migrationRequired,
      _ =>
        hardwareBacked
            ? PlatformDeviceKeySecurityState.readyHardwareProtected
            : PlatformDeviceKeySecurityState.readyOsProtected,
    };
    return PlatformDeviceKeyIdentity(
      rootKeyHandle: value['rootKeyHandle'] as String? ?? '',
      rootPublicKey: bytes('rootPublicKey'),
      authenticationKeyHandle:
          value['authenticationKeyHandle'] as String? ?? '',
      authenticationPublicKey: bytes('authenticationPublicKey'),
      authenticationNotBefore: DateTime.fromMillisecondsSinceEpoch(
        (value['authenticationNotBeforeUnixMs'] as num?)?.toInt() ?? 0,
        isUtc: true,
      ),
      authenticationExpiresAt: DateTime.fromMillisecondsSinceEpoch(
        (value['authenticationExpiresAtUnixMs'] as num?)?.toInt() ?? 0,
        isUtc: true,
      ),
      authenticationCertificate: bytes('authenticationCertificate'),
      protection: protection,
      securityState: securityState,
      diagnosticCode: value['diagnosticCode'] as String?,
      diagnosticMessage: value['diagnosticMessage'] as String?,
    );
  }
}

abstract interface class DeviceKeyPlatformAdapter {
  bool get supported;

  bool get supportsIdentityRecovery;

  Future<PlatformDeviceKeyIdentity> loadOrCreateIdentity();

  Future<PlatformDeviceKeyIdentity> rotateAuthenticationKey();

  Future<PlatformDeviceKeyIdentity> upgradeToHardwareIdentity();

  Future<PlatformDeviceKeyIdentity> resetIdentity();

  Future<Uint8List> signWithRoot(Uint8List message);

  Future<Uint8List> signWithAuthenticationKey(Uint8List message);

  Future<bool> verifyP256Signature({
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  });
}

class MethodChannelDeviceKeyPlatformAdapter
    implements DeviceKeyPlatformAdapter {
  MethodChannelDeviceKeyPlatformAdapter({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel(
            'com.crossdesktopremote.cross_desktop_remote/device_identity',
          );

  final MethodChannel _channel;

  @override
  bool get supported =>
      Platform.isMacOS || Platform.isIOS || Platform.isWindows;

  @override
  bool get supportsIdentityRecovery =>
      Platform.isMacOS || Platform.isIOS || Platform.isWindows;

  @override
  Future<PlatformDeviceKeyIdentity> loadOrCreateIdentity() async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'loadOrCreateIdentity',
    );
    if (value == null) {
      throw PlatformException(
        code: 'device_identity_unavailable',
        message: 'Native device identity returned no value',
      );
    }
    return PlatformDeviceKeyIdentity.fromMap(value);
  }

  @override
  Future<PlatformDeviceKeyIdentity> rotateAuthenticationKey() async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'rotateAuthenticationKey',
    );
    if (value == null) {
      throw PlatformException(
        code: 'device_identity_unavailable',
        message: 'Native authentication key rotation returned no value',
      );
    }
    return PlatformDeviceKeyIdentity.fromMap(value);
  }

  @override
  Future<PlatformDeviceKeyIdentity> upgradeToHardwareIdentity() =>
      _loadIdentity('upgradeToHardwareIdentity');

  @override
  Future<PlatformDeviceKeyIdentity> resetIdentity() =>
      _loadIdentity('resetIdentity');

  Future<PlatformDeviceKeyIdentity> _loadIdentity(String method) async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(method);
    if (value == null) {
      throw PlatformException(
        code: 'device_identity_unavailable',
        message: 'Native device identity returned no value for $method',
      );
    }
    return PlatformDeviceKeyIdentity.fromMap(value);
  }

  @override
  Future<Uint8List> signWithRoot(Uint8List message) =>
      _sign('signWithRoot', message);

  @override
  Future<Uint8List> signWithAuthenticationKey(Uint8List message) =>
      _sign('signWithAuthenticationKey', message);

  Future<Uint8List> _sign(String method, Uint8List message) async {
    final encoded = await _channel.invokeMethod<String>(method, {
      'message': base64Encode(message),
    });
    if (encoded == null || encoded.isEmpty) {
      throw PlatformException(
        code: 'device_signature_failed',
        message: 'Native signer returned no signature',
      );
    }
    return base64Decode(encoded);
  }

  @override
  Future<bool> verifyP256Signature({
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) async {
    return await _channel.invokeMethod<bool>('verifyP256Signature', {
          'publicKey': base64Encode(publicKey),
          'message': base64Encode(message),
          'signature': base64Encode(signature),
        }) ??
        false;
  }
}

class UnsupportedDeviceKeyPlatformAdapter implements DeviceKeyPlatformAdapter {
  const UnsupportedDeviceKeyPlatformAdapter();

  @override
  bool get supported => false;

  @override
  bool get supportsIdentityRecovery => false;

  Never _unsupported() => throw UnsupportedError(
    'Current platform has no protected device-key implementation.',
  );

  @override
  Future<PlatformDeviceKeyIdentity> loadOrCreateIdentity() async =>
      _unsupported();

  @override
  Future<PlatformDeviceKeyIdentity> rotateAuthenticationKey() async =>
      _unsupported();

  @override
  Future<PlatformDeviceKeyIdentity> upgradeToHardwareIdentity() async =>
      _unsupported();

  @override
  Future<PlatformDeviceKeyIdentity> resetIdentity() async => _unsupported();

  @override
  Future<Uint8List> signWithAuthenticationKey(Uint8List message) async =>
      _unsupported();

  @override
  Future<Uint8List> signWithRoot(Uint8List message) async => _unsupported();

  @override
  Future<bool> verifyP256Signature({
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) async => _unsupported();
}

DeviceKeyPlatformAdapter createDeviceKeyPlatformAdapter() {
  if (Platform.isMacOS || Platform.isIOS || Platform.isWindows) {
    return MethodChannelDeviceKeyPlatformAdapter();
  }
  return const UnsupportedDeviceKeyPlatformAdapter();
}
