import 'dart:ffi';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_desktop_remote/core/bridge/native_core_bridge.dart';
import 'package:cross_desktop_remote/core/security/trusted_device_models.dart';
import 'package:cross_desktop_remote/core/security/trusted_webrtc_binding.dart';
import 'package:ffi/ffi.dart';

enum TrustedSecurityPhase {
  idle,
  pairingAwaitingConfirmation,
  pairingConfirmed,
  authenticating,
  awaitingHostAuthorization,
  awaitingAuthorizationAck,
  awaitingWebRtcBinding,
  authorized,
  failed,
}

enum TrustedSecuritySessionMode { pairing, trustedAuthentication }

enum TrustedSecurityFailure {
  unavailable,
  invalidArgument,
  invalidState,
  invalidSignature,
  replay,
  notYetValid,
  expired,
  softExpired,
  hardExpired,
  lifetimeExceeded,
  permissionDenied,
  revoked,
  sessionMismatch,
  paused,
  invalidMessage,
  unknown,
}

class TrustedSecurityEngineException implements Exception {
  const TrustedSecurityEngineException(this.failure, this.message);

  final TrustedSecurityFailure failure;
  final String message;

  @override
  String toString() => message;
}

abstract interface class TrustedSecurityEngineFactory {
  TrustedSecuritySession create(Uint8List localRootFingerprint);

  void validatePeerIdentity({
    required TrustedPeerIdentity peer,
    required DateTime now,
  });
}

abstract interface class TrustedSecuritySession {
  TrustedSecurityPhase get phase;

  void setPaused(bool paused);

  void begin({
    required String sessionId,
    required Uint8List peerRootFingerprint,
    required Set<TrustedPermission> requestedPermissions,
    required TrustedSecuritySessionMode mode,
    required TrustedSessionNegotiationContext negotiation,
  });

  void confirmPairing(bool sasMatches);

  void completePairing();

  Set<TrustedPermission> validatePairingGrant({
    required TrustedDeviceGrant grant,
    required Uint8List issuerRootPublicKey,
    required DateTime now,
  });

  void verifyEnvelope({
    required SignedTrustedEnvelope envelope,
    required TrustedPeerIdentity sender,
    required DateTime now,
  });

  Set<TrustedPermission> authorizeGrant({
    required TrustedDeviceGrant grant,
    required Uint8List issuerRootPublicKey,
    required Uint8List expectedSubjectFingerprint,
    required DateTime now,
  });

  void authenticateCredential({
    required TrustedDeviceGrant grant,
    required Uint8List issuerRootPublicKey,
    required Uint8List expectedSubjectFingerprint,
    required DateTime now,
  });

  Set<TrustedPermission> applyHostAuthorization({
    required TrustedSessionAuthorization authorization,
    required bool localIsHost,
    required DateTime now,
  });

  Set<TrustedPermission> confirmHostAuthorizationAck({
    required TrustedSessionAuthorizationAck acknowledgement,
    required DateTime now,
  });

  void configureWebRtcContext({
    required Uint8List controllerNonce,
    required Uint8List hostNonce,
    required Uint8List controllerAuthenticationPublicKey,
    required Uint8List hostAuthenticationPublicKey,
  });

  Set<TrustedPermission> bindWebRtc({
    required TrustedSessionBinding binding,
    required String offerSdp,
    required String answerSdp,
    required DateTime now,
  });

  void validateSdpManifest({
    required TrustedSdpManifest manifest,
    required String sdp,
    required DateTime now,
  });

  void revokeGrant(Uint8List grantId);

  void end();

  void dispose();
}

class NativeTrustedSecurityEngineFactory
    implements TrustedSecurityEngineFactory {
  NativeTrustedSecurityEngineFactory._(this._bindings);

  factory NativeTrustedSecurityEngineFactory.open({String? libraryPath}) =>
      NativeTrustedSecurityEngineFactory._(
        _TrustedSecurityBindings(
          NativeCoreBridge.openLibrary(libraryPath: libraryPath),
        ),
      );

  static NativeTrustedSecurityEngineFactory? tryOpen({String? libraryPath}) {
    try {
      return NativeTrustedSecurityEngineFactory.open(libraryPath: libraryPath);
    } catch (_) {
      return null;
    }
  }

  final _TrustedSecurityBindings _bindings;

  @override
  TrustedSecuritySession create(Uint8List localRootFingerprint) =>
      _NativeTrustedSecuritySession(_bindings, localRootFingerprint);

  @override
  void validatePeerIdentity({
    required TrustedPeerIdentity peer,
    required DateTime now,
  }) {
    final encoded = _encodeIdentity(peer);
    _withBytes(
      encoded,
      (pointer, length) => _throwIfSecurityFailure(
        _bindings.validateDeviceIdentity(
          pointer,
          length,
          now.toUtc().millisecondsSinceEpoch,
        ),
      ),
    );
  }
}

class _NativeTrustedSecuritySession implements TrustedSecuritySession {
  _NativeTrustedSecuritySession(this._bindings, Uint8List fingerprint) {
    if (fingerprint.length != 32) {
      throw const FormatException('Invalid local root fingerprint');
    }
    _handle = _withBytes(
      fingerprint,
      (pointer, length) => _bindings.create(pointer, length),
    );
    if (_handle == nullptr) {
      throw const TrustedSecurityEngineException(
        TrustedSecurityFailure.unavailable,
        'Rust trusted security engine is unavailable',
      );
    }
  }

  final _TrustedSecurityBindings _bindings;
  late Pointer<Void> _handle;

  void _ensureOpen() {
    if (_handle == nullptr) {
      throw StateError('Trusted security session has been disposed');
    }
  }

  @override
  TrustedSecurityPhase get phase {
    _ensureOpen();
    final output = calloc<Uint32>();
    try {
      _check(_bindings.phase(_handle, output));
      final value = output.value;
      if (value >= TrustedSecurityPhase.values.length) {
        throw const TrustedSecurityEngineException(
          TrustedSecurityFailure.invalidState,
          'Rust security engine returned an invalid phase',
        );
      }
      return TrustedSecurityPhase.values[value];
    } finally {
      calloc.free(output);
    }
  }

  @override
  void setPaused(bool paused) {
    _ensureOpen();
    _check(_bindings.setPaused(_handle, paused ? 1 : 0));
  }

  @override
  void begin({
    required String sessionId,
    required Uint8List peerRootFingerprint,
    required Set<TrustedPermission> requestedPermissions,
    required TrustedSecuritySessionMode mode,
    required TrustedSessionNegotiationContext negotiation,
  }) {
    _ensureOpen();
    negotiation.validate();
    final sessionBytes = Uint8List.fromList(utf8.encode(sessionId));
    if (sessionBytes.isEmpty || peerRootFingerprint.length != 32) {
      throw const FormatException('Invalid trusted session context');
    }
    _withBytes(sessionBytes, (sessionPointer, sessionLength) {
      _withBytes(peerRootFingerprint, (peerPointer, peerLength) {
        _withBytes(negotiation.capabilitySha256, (hashPointer, hashLength) {
          _check(
            _bindings.beginV2(
              _handle,
              sessionPointer,
              sessionLength,
              peerPointer,
              peerLength,
              trustedPermissionBits(requestedPermissions),
              mode.index + 1,
              negotiation.authSuiteVersion,
              hashPointer,
              hashLength,
            ),
          );
        });
      });
    });
  }

  @override
  void confirmPairing(bool sasMatches) {
    _ensureOpen();
    _check(_bindings.confirmPairing(_handle, sasMatches ? 1 : 0));
  }

  @override
  void completePairing() {
    _ensureOpen();
    _check(_bindings.completePairing(_handle));
  }

  @override
  Set<TrustedPermission> validatePairingGrant({
    required TrustedDeviceGrant grant,
    required Uint8List issuerRootPublicKey,
    required DateTime now,
  }) {
    _ensureOpen();
    final encodedGrant = _encodeGrant(grant);
    final output = calloc<Uint64>();
    try {
      _withBytes(encodedGrant, (grantPointer, grantLength) {
        _withBytes(issuerRootPublicKey, (keyPointer, keyLength) {
          _check(
            _bindings.validatePairingGrant(
              _handle,
              grantPointer,
              grantLength,
              keyPointer,
              keyLength,
              now.toUtc().millisecondsSinceEpoch,
              output,
            ),
          );
        });
      });
      return Set.unmodifiable(trustedPermissionsFromBits(output.value));
    } finally {
      calloc.free(output);
    }
  }

  @override
  void verifyEnvelope({
    required SignedTrustedEnvelope envelope,
    required TrustedPeerIdentity sender,
    required DateTime now,
  }) {
    _ensureOpen();
    final encodedEnvelope = _encodeEnvelope(envelope, sender);
    final encodedIdentity = _encodeIdentity(sender);
    _withBytes(encodedEnvelope, (envelopePointer, envelopeLength) {
      _withBytes(encodedIdentity, (identityPointer, identityLength) {
        _check(
          _bindings.verifyEnvelope(
            _handle,
            envelopePointer,
            envelopeLength,
            identityPointer,
            identityLength,
            now.toUtc().millisecondsSinceEpoch,
          ),
        );
      });
    });
  }

  @override
  Set<TrustedPermission> authorizeGrant({
    required TrustedDeviceGrant grant,
    required Uint8List issuerRootPublicKey,
    required Uint8List expectedSubjectFingerprint,
    required DateTime now,
  }) {
    _ensureOpen();
    final encodedGrant = _encodeGrant(grant);
    final output = calloc<Uint64>();
    try {
      _withBytes(encodedGrant, (grantPointer, grantLength) {
        _withBytes(issuerRootPublicKey, (keyPointer, keyLength) {
          _withBytes(expectedSubjectFingerprint, (
            subjectPointer,
            subjectLength,
          ) {
            _check(
              _bindings.authorizeGrant(
                _handle,
                grantPointer,
                grantLength,
                keyPointer,
                keyLength,
                subjectPointer,
                subjectLength,
                now.toUtc().millisecondsSinceEpoch,
                output,
              ),
            );
          });
        });
      });
      return Set.unmodifiable(trustedPermissionsFromBits(output.value));
    } finally {
      calloc.free(output);
    }
  }

  @override
  void authenticateCredential({
    required TrustedDeviceGrant grant,
    required Uint8List issuerRootPublicKey,
    required Uint8List expectedSubjectFingerprint,
    required DateTime now,
  }) {
    _ensureOpen();
    final encodedGrant = _encodeGrant(grant);
    _withBytes(encodedGrant, (grantPointer, grantLength) {
      _withBytes(issuerRootPublicKey, (keyPointer, keyLength) {
        _withBytes(expectedSubjectFingerprint, (subjectPointer, subjectLength) {
          _check(
            _bindings.authenticateCredential(
              _handle,
              grantPointer,
              grantLength,
              keyPointer,
              keyLength,
              subjectPointer,
              subjectLength,
              now.toUtc().millisecondsSinceEpoch,
            ),
          );
        });
      });
    });
  }

  @override
  Set<TrustedPermission> applyHostAuthorization({
    required TrustedSessionAuthorization authorization,
    required bool localIsHost,
    required DateTime now,
  }) {
    _ensureOpen();
    authorization.validateStructure();
    final encoded = _encodeSessionAuthorization(authorization);
    final output = calloc<Uint64>();
    try {
      _withBytes(encoded, (pointer, length) {
        _check(
          _bindings.applyHostAuthorization(
            _handle,
            pointer,
            length,
            now.toUtc().millisecondsSinceEpoch,
            localIsHost ? 1 : 0,
            output,
          ),
        );
      });
      return Set.unmodifiable(trustedPermissionsFromBits(output.value));
    } finally {
      calloc.free(output);
    }
  }

  @override
  Set<TrustedPermission> confirmHostAuthorizationAck({
    required TrustedSessionAuthorizationAck acknowledgement,
    required DateTime now,
  }) {
    _ensureOpen();
    acknowledgement.validateStructure();
    final encoded = _encodeSessionAuthorizationAck(acknowledgement);
    final output = calloc<Uint64>();
    try {
      _withBytes(encoded, (pointer, length) {
        _check(
          _bindings.confirmHostAuthorizationAck(
            _handle,
            pointer,
            length,
            now.toUtc().millisecondsSinceEpoch,
            output,
          ),
        );
      });
      return Set.unmodifiable(trustedPermissionsFromBits(output.value));
    } finally {
      calloc.free(output);
    }
  }

  @override
  void configureWebRtcContext({
    required Uint8List controllerNonce,
    required Uint8List hostNonce,
    required Uint8List controllerAuthenticationPublicKey,
    required Uint8List hostAuthenticationPublicKey,
  }) {
    _ensureOpen();
    if (controllerNonce.length != 16 || hostNonce.length != 16) {
      throw const FormatException('Invalid trusted WebRTC nonce');
    }
    _withBytes(controllerNonce, (
      controllerNoncePointer,
      controllerNonceLength,
    ) {
      _withBytes(hostNonce, (hostNoncePointer, hostNonceLength) {
        _withBytes(controllerAuthenticationPublicKey, (
          controllerKeyPointer,
          controllerKeyLength,
        ) {
          _withBytes(hostAuthenticationPublicKey, (
            hostKeyPointer,
            hostKeyLength,
          ) {
            _check(
              _bindings.configureWebRtcContext(
                _handle,
                controllerNoncePointer,
                controllerNonceLength,
                hostNoncePointer,
                hostNonceLength,
                controllerKeyPointer,
                controllerKeyLength,
                hostKeyPointer,
                hostKeyLength,
              ),
            );
          });
        });
      });
    });
  }

  @override
  Set<TrustedPermission> bindWebRtc({
    required TrustedSessionBinding binding,
    required String offerSdp,
    required String answerSdp,
    required DateTime now,
  }) {
    _ensureOpen();
    final encoded = _encodeBinding(binding);
    final output = calloc<Uint64>();
    try {
      _withBytes(encoded, (pointer, length) {
        _withBytes(Uint8List.fromList(utf8.encode(offerSdp)), (
          offerPointer,
          offerLength,
        ) {
          _withBytes(Uint8List.fromList(utf8.encode(answerSdp)), (
            answerPointer,
            answerLength,
          ) {
            _check(
              _bindings.bindWebRtcTranscript(
                _handle,
                pointer,
                length,
                offerPointer,
                offerLength,
                answerPointer,
                answerLength,
                now.toUtc().millisecondsSinceEpoch,
                output,
              ),
            );
          });
        });
      });
      return Set.unmodifiable(trustedPermissionsFromBits(output.value));
    } finally {
      calloc.free(output);
    }
  }

  @override
  void validateSdpManifest({
    required TrustedSdpManifest manifest,
    required String sdp,
    required DateTime now,
  }) {
    _ensureOpen();
    final encoded = _encodeSdpManifest(manifest);
    _withBytes(encoded, (manifestPointer, manifestLength) {
      _withBytes(Uint8List.fromList(utf8.encode(sdp)), (sdpPointer, sdpLength) {
        _check(
          _bindings.validateSdpManifest(
            _handle,
            manifestPointer,
            manifestLength,
            sdpPointer,
            sdpLength,
            now.toUtc().millisecondsSinceEpoch,
          ),
        );
      });
    });
  }

  @override
  void revokeGrant(Uint8List grantId) {
    _ensureOpen();
    _withBytes(
      grantId,
      (pointer, length) =>
          _check(_bindings.revokeGrant(_handle, pointer, length)),
    );
  }

  @override
  void end() {
    _ensureOpen();
    _check(_bindings.end(_handle));
  }

  @override
  void dispose() {
    final handle = _handle;
    if (handle == nullptr) return;
    _handle = nullptr;
    _bindings.destroy(handle);
  }

  void _check(int result) {
    _throwIfSecurityFailure(result);
  }
}

void _throwIfSecurityFailure(int result) {
  if (result == 0) return;
  final failure = switch (result) {
    -2 => TrustedSecurityFailure.invalidArgument,
    -3 => TrustedSecurityFailure.invalidState,
    -12 => TrustedSecurityFailure.invalidSignature,
    -13 => TrustedSecurityFailure.replay,
    -14 => TrustedSecurityFailure.expired,
    -15 => TrustedSecurityFailure.permissionDenied,
    -16 => TrustedSecurityFailure.revoked,
    -17 => TrustedSecurityFailure.sessionMismatch,
    -18 => TrustedSecurityFailure.paused,
    -19 => TrustedSecurityFailure.invalidMessage,
    -20 => TrustedSecurityFailure.notYetValid,
    -21 => TrustedSecurityFailure.softExpired,
    -22 => TrustedSecurityFailure.hardExpired,
    -23 => TrustedSecurityFailure.lifetimeExceeded,
    _ => TrustedSecurityFailure.unknown,
  };
  throw TrustedSecurityEngineException(
    failure,
    'Rust trusted security engine rejected the operation (code $result)',
  );
}

typedef _CreateNative = Pointer<Void> Function(Pointer<Uint8>, IntPtr);
typedef _CreateDart = Pointer<Void> Function(Pointer<Uint8>, int);
typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);
typedef _ValidateDeviceIdentityNative = Int32 Function(
  Pointer<Uint8>,
  IntPtr,
  Uint64,
);
typedef _ValidateDeviceIdentityDart = int Function(Pointer<Uint8>, int, int);
typedef _PhaseNative = Int32 Function(Pointer<Void>, Pointer<Uint32>);
typedef _PhaseDart = int Function(Pointer<Void>, Pointer<Uint32>);
typedef _SetPausedNative = Int32 Function(Pointer<Void>, Uint8);
typedef _SetPausedDart = int Function(Pointer<Void>, int);
typedef _BeginV2Native = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
  Uint64,
  Uint32,
  Uint32,
  Pointer<Uint8>,
  IntPtr,
);
typedef _BeginV2Dart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
  int,
  int,
  Pointer<Uint8>,
  int,
);
typedef _BoolOperationNative = Int32 Function(Pointer<Void>, Uint8);
typedef _BoolOperationDart = int Function(Pointer<Void>, int);
typedef _SimpleOperationNative = Int32 Function(Pointer<Void>);
typedef _SimpleOperationDart = int Function(Pointer<Void>);
typedef _BytesOperationNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
);
typedef _BytesOperationDart = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _VerifyEnvelopeNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
  Uint64,
);
typedef _VerifyEnvelopeDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
);
typedef _AuthorizeGrantNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
  Uint64,
  Pointer<Uint64>,
);
typedef _AuthorizeGrantDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
  Pointer<Uint64>,
);
typedef _AuthenticateCredentialNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
  Uint64,
);
typedef _AuthenticateCredentialDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
);
typedef _ApplyHostAuthorizationNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
  Uint64,
  Uint8,
  Pointer<Uint64>,
);
typedef _ApplyHostAuthorizationDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  int,
  int,
  Pointer<Uint64>,
);
typedef _ValidatePairingGrantNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
  Uint64,
  Pointer<Uint64>,
);
typedef _ValidatePairingGrantDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
  Pointer<Uint64>,
);
typedef _BindWebRtcNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
  Uint64,
  Pointer<Uint64>,
);
typedef _ConfigureWebRtcContextNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
);
typedef _ConfigureWebRtcContextDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);
typedef _BindWebRtcDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  int,
  Pointer<Uint64>,
);
typedef _ValidateSdpManifestNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
  Uint64,
);
typedef _ValidateSdpManifestDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
);
typedef _BindWebRtcTranscriptNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
  Uint64,
  Pointer<Uint64>,
);
typedef _BindWebRtcTranscriptDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
  Pointer<Uint64>,
);

class _TrustedSecurityBindings {
  _TrustedSecurityBindings(DynamicLibrary library)
    : create = library.lookupFunction<_CreateNative, _CreateDart>(
        'cdr_security_engine_create',
      ),
      destroy = library.lookupFunction<_DestroyNative, _DestroyDart>(
        'cdr_security_engine_destroy',
      ),
      validateDeviceIdentity = library
          .lookupFunction<
            _ValidateDeviceIdentityNative,
            _ValidateDeviceIdentityDart
          >('cdr_security_validate_device_identity'),
      phase = library.lookupFunction<_PhaseNative, _PhaseDart>(
        'cdr_security_engine_phase',
      ),
      setPaused = library.lookupFunction<_SetPausedNative, _SetPausedDart>(
        'cdr_security_engine_set_paused',
      ),
      beginV2 = library.lookupFunction<_BeginV2Native, _BeginV2Dart>(
        'cdr_security_engine_begin_session_v2',
      ),
      confirmPairing = library
          .lookupFunction<_BoolOperationNative, _BoolOperationDart>(
            'cdr_security_engine_confirm_pairing',
          ),
      completePairing = library
          .lookupFunction<_SimpleOperationNative, _SimpleOperationDart>(
            'cdr_security_engine_complete_pairing',
          ),
      end = library
          .lookupFunction<_SimpleOperationNative, _SimpleOperationDart>(
            'cdr_security_engine_end_session',
          ),
      revokeGrant = library
          .lookupFunction<_BytesOperationNative, _BytesOperationDart>(
            'cdr_security_engine_revoke_grant',
          ),
      verifyEnvelope = library
          .lookupFunction<_VerifyEnvelopeNative, _VerifyEnvelopeDart>(
            'cdr_security_engine_verify_envelope',
          ),
      authorizeGrant = library
          .lookupFunction<_AuthorizeGrantNative, _AuthorizeGrantDart>(
            'cdr_security_engine_authorize_grant',
          ),
      authenticateCredential = library
          .lookupFunction<
            _AuthenticateCredentialNative,
            _AuthenticateCredentialDart
          >('cdr_security_engine_authenticate_credential'),
      applyHostAuthorization = library
          .lookupFunction<
            _ApplyHostAuthorizationNative,
            _ApplyHostAuthorizationDart
          >('cdr_security_engine_apply_host_authorization'),
      confirmHostAuthorizationAck = library
          .lookupFunction<_BindWebRtcNative, _BindWebRtcDart>(
            'cdr_security_engine_confirm_host_authorization_ack',
          ),
      validatePairingGrant = library
          .lookupFunction<
            _ValidatePairingGrantNative,
            _ValidatePairingGrantDart
          >('cdr_security_engine_validate_pairing_grant'),
      configureWebRtcContext = library
          .lookupFunction<
            _ConfigureWebRtcContextNative,
            _ConfigureWebRtcContextDart
          >('cdr_security_engine_configure_webrtc_context'),
      validateSdpManifest = library
          .lookupFunction<_ValidateSdpManifestNative, _ValidateSdpManifestDart>(
            'cdr_security_engine_validate_sdp_manifest',
          ),
      bindWebRtcTranscript = library
          .lookupFunction<
            _BindWebRtcTranscriptNative,
            _BindWebRtcTranscriptDart
          >('cdr_security_engine_bind_webrtc_transcript');

  final _CreateDart create;
  final _DestroyDart destroy;
  final _ValidateDeviceIdentityDart validateDeviceIdentity;
  final _PhaseDart phase;
  final _SetPausedDart setPaused;
  final _BeginV2Dart beginV2;
  final _BoolOperationDart confirmPairing;
  final _SimpleOperationDart completePairing;
  final _SimpleOperationDart end;
  final _BytesOperationDart revokeGrant;
  final _VerifyEnvelopeDart verifyEnvelope;
  final _AuthorizeGrantDart authorizeGrant;
  final _AuthenticateCredentialDart authenticateCredential;
  final _ApplyHostAuthorizationDart applyHostAuthorization;
  final _BindWebRtcDart confirmHostAuthorizationAck;
  final _ValidatePairingGrantDart validatePairingGrant;
  final _ConfigureWebRtcContextDart configureWebRtcContext;
  final _ValidateSdpManifestDart validateSdpManifest;
  final _BindWebRtcTranscriptDart bindWebRtcTranscript;
}

T _withBytes<T>(
  Uint8List bytes,
  T Function(Pointer<Uint8> pointer, int length) operation,
) {
  if (bytes.isEmpty) {
    throw const FormatException('Security FFI input cannot be empty');
  }
  final pointer = calloc<Uint8>(bytes.length);
  try {
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    return operation(pointer, bytes.length);
  } finally {
    calloc.free(pointer);
  }
}

Uint8List _encodeIdentity(TrustedPeerIdentity identity) {
  final writer = _ProtoWriter()
    ..string(1, identity.machineCode)
    ..bytes(2, identity.rootPublicKey)
    ..bytes(3, identity.rootFingerprint)
    ..bytes(4, identity.authenticationPublicKey)
    ..uint64(5, identity.authenticationNotBefore.millisecondsSinceEpoch)
    ..uint64(6, identity.authenticationExpiresAt.millisecondsSinceEpoch)
    ..bytes(7, identity.authenticationCertificate);
  return writer.takeBytes();
}

Uint8List _encodeEnvelope(
  SignedTrustedEnvelope envelope,
  TrustedPeerIdentity sender,
) {
  final writer = _ProtoWriter()
    ..uint64(1, 1)
    ..string(2, envelope.sessionId)
    ..bytes(3, envelope.senderRootFingerprint)
    ..bytes(4, envelope.recipientRootFingerprint)
    ..uint64(5, envelope.sequence)
    ..uint64(6, envelope.issuedAt.millisecondsSinceEpoch)
    ..uint64(7, envelope.expiresAt.millisecondsSinceEpoch)
    ..bytes(8, envelope.nonce)
    ..bytes(9, envelope.payload)
    ..bytes(10, sender.authenticationPublicKey)
    ..bytes(11, sender.authenticationCertificate)
    ..bytes(12, envelope.signature);
  return writer.takeBytes();
}

Uint8List _encodeGrant(TrustedDeviceGrant grant) {
  final writer = _ProtoWriter()
    ..bytes(1, grant.grantId)
    ..bytes(2, grant.issuerRootFingerprint)
    ..bytes(3, grant.subjectRootFingerprint);
  for (final permission in grant.permissions) {
    writer.uint64(4, permission.index + 1);
  }
  writer
    ..uint64(5, grant.issuedAt.millisecondsSinceEpoch)
    ..uint64(6, grant.softExpiresAt.millisecondsSinceEpoch)
    ..uint64(7, grant.hardExpiresAt.millisecondsSinceEpoch)
    ..boolean(8, grant.automaticRenewal)
    ..bytes(9, grant.signature);
  return writer.takeBytes();
}

Uint8List _encodeBinding(TrustedSessionBinding binding) {
  final writer = _ProtoWriter()
    ..string(1, binding.sessionId)
    ..bytes(2, binding.controllerNonce)
    ..bytes(3, binding.hostNonce);
  for (final permission in binding.requestedPermissions) {
    writer.uint64(4, permission.index + 1);
  }
  writer
    ..bytes(5, binding.controllerEphemeralPublicKey)
    ..bytes(6, binding.hostEphemeralPublicKey)
    ..bytes(7, binding.offerSha256)
    ..bytes(8, binding.answerSha256)
    ..bytes(9, binding.controllerDtlsFingerprintSha256)
    ..bytes(10, binding.hostDtlsFingerprintSha256)
    ..uint64(11, binding.expiresAt.millisecondsSinceEpoch)
    ..uint64(12, binding.authSuiteVersion)
    ..bytes(13, binding.authorizationSha256)
    ..bytes(14, binding.capabilitySha256);
  return writer.takeBytes();
}

Uint8List _encodeSdpManifest(TrustedSdpManifest manifest) {
  final writer = _ProtoWriter()
    ..uint64(1, manifest.descriptionType.index + 1)
    ..string(2, manifest.sessionId)
    ..bytes(3, manifest.controllerNonce)
    ..bytes(4, manifest.hostNonce);
  for (final permission in manifest.requestedPermissions) {
    writer.uint64(5, permission.index + 1);
  }
  writer
    ..bytes(6, manifest.controllerAuthenticationPublicKey)
    ..bytes(7, manifest.hostAuthenticationPublicKey)
    ..bytes(8, manifest.sdpSha256)
    ..bytes(9, manifest.dtlsFingerprintSha256)
    ..uint64(10, manifest.expiresAt.millisecondsSinceEpoch)
    ..uint64(11, manifest.authSuiteVersion)
    ..bytes(12, manifest.authorizationSha256)
    ..bytes(13, manifest.capabilitySha256);
  return writer.takeBytes();
}

Uint8List _encodeSessionAuthorization(
  TrustedSessionAuthorization authorization,
) {
  final writer = _ProtoWriter()
    ..uint64(1, 1)
    ..string(2, authorization.sessionId)
    ..bytes(3, authorization.credentialId)
    ..uint64(4, authorization.policyRevision);
  for (final permission in authorization.permissions) {
    writer.uint64(5, permission.index + 1);
  }
  writer
    ..bytes(6, authorization.controllerRootFingerprint)
    ..bytes(7, authorization.hostRootFingerprint)
    ..bytes(8, authorization.controllerNonce)
    ..bytes(9, authorization.hostNonce)
    ..uint64(10, authorization.issuedAt.millisecondsSinceEpoch)
    ..uint64(11, authorization.expiresAt.millisecondsSinceEpoch)
    ..uint64(12, authorization.authSuiteVersion)
    ..bytes(13, authorization.capabilitySha256);
  return writer.takeBytes();
}

Uint8List _encodeSessionAuthorizationAck(
  TrustedSessionAuthorizationAck acknowledgement,
) {
  final writer = _ProtoWriter()
    ..uint64(1, 1)
    ..string(2, acknowledgement.sessionId)
    ..bytes(3, acknowledgement.authorizationSha256)
    ..uint64(4, acknowledgement.policyRevision);
  for (final permission in acknowledgement.permissions) {
    writer.uint64(5, permission.index + 1);
  }
  writer
    ..bytes(6, acknowledgement.controllerRootFingerprint)
    ..bytes(7, acknowledgement.hostRootFingerprint)
    ..bytes(8, acknowledgement.controllerNonce)
    ..bytes(9, acknowledgement.hostNonce)
    ..uint64(10, acknowledgement.issuedAt.millisecondsSinceEpoch)
    ..uint64(11, acknowledgement.expiresAt.millisecondsSinceEpoch)
    ..uint64(12, acknowledgement.authSuiteVersion)
    ..bytes(13, acknowledgement.capabilitySha256);
  return writer.takeBytes();
}

class _ProtoWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void bytes(int field, List<int> value) {
    _varint((field << 3) | 2);
    _varint(value.length);
    _builder.add(value);
  }

  void string(int field, String value) => bytes(field, utf8.encode(value));

  void boolean(int field, bool value) => uint64(field, value ? 1 : 0);

  void uint64(int field, int value) {
    if (value < 0) throw const FormatException('Negative protobuf uint64');
    _varint(field << 3);
    _varint(value);
  }

  void _varint(int value) {
    var remaining = value;
    do {
      var next = remaining & 0x7f;
      remaining >>= 7;
      if (remaining != 0) next |= 0x80;
      _builder.addByte(next);
    } while (remaining != 0);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}
