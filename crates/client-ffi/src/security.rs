use std::{ptr, slice};

use prost::Message;
use protocol::v1::{
    DeviceIdentityPublic as ProtoDeviceIdentity, PermissionScope,
    SignedPeerEnvelope as ProtoSignedPeerEnvelope, TrustGrant as ProtoTrustGrant,
    TrustedSessionAuthorization as ProtoTrustedSessionAuthorization,
    TrustedSessionAuthorizationAck as ProtoTrustedSessionAuthorizationAck,
    TrustedSessionBinding as ProtoTrustedSessionBinding,
};
use security_core::{
    AuthenticationKeyCertificate, PermissionSet, ROOT_FINGERPRINT_BYTES, SecurityError,
    SessionPermission, SignedPeerEnvelope, TrustGrant, TrustedSecurityEngine,
    TrustedSessionAuthorization, TrustedSessionAuthorizationAck, TrustedSessionBinding,
    TrustedSessionMode, machine_code_v2, sas_code, validate_device_identity,
    verify_p256_signature_der,
};

const CDR_OK: i32 = 0;
const CDR_ERROR_NULL_POINTER: i32 = -1;
const CDR_ERROR_INVALID_ARGUMENT: i32 = -2;
const CDR_ERROR_INVALID_STATE: i32 = -3;
const CDR_ERROR_BUFFER_TOO_SMALL: i32 = -11;
const CDR_ERROR_INVALID_SIGNATURE: i32 = -12;
const CDR_ERROR_REPLAY: i32 = -13;
const CDR_ERROR_EXPIRED: i32 = -14;
const CDR_ERROR_PERMISSION_DENIED: i32 = -15;
const CDR_ERROR_REVOKED: i32 = -16;
const CDR_ERROR_SESSION_MISMATCH: i32 = -17;
const CDR_ERROR_PAUSED: i32 = -18;
const CDR_ERROR_INVALID_MESSAGE: i32 = -19;
const CDR_ERROR_NOT_YET_VALID: i32 = -20;
const CDR_ERROR_SOFT_EXPIRED: i32 = -21;
const CDR_ERROR_HARD_EXPIRED: i32 = -22;
const CDR_ERROR_LIFETIME_EXCEEDED: i32 = -23;

pub struct CdrSecurityEngine {
    core: TrustedSecurityEngine,
}

#[unsafe(no_mangle)]
pub extern "C" fn cdr_security_engine_create(
    local_root_fingerprint: *const u8,
    local_root_fingerprint_len: usize,
) -> *mut CdrSecurityEngine {
    if local_root_fingerprint.is_null() || local_root_fingerprint_len != ROOT_FINGERPRINT_BYTES {
        return ptr::null_mut();
    }
    // SAFETY: The pointer is non-null and the caller supplied the exact fixed length.
    let bytes =
        unsafe { slice::from_raw_parts(local_root_fingerprint, local_root_fingerprint_len) };
    let Ok(fingerprint) = bytes.try_into() else {
        return ptr::null_mut();
    };
    Box::into_raw(Box::new(CdrSecurityEngine {
        core: TrustedSecurityEngine::new(fingerprint),
    }))
}

/// # Safety
/// `engine` must be null or a pointer returned exactly once by
/// `cdr_security_engine_create`. It must not be used after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_destroy(engine: *mut CdrSecurityEngine) {
    if !engine.is_null() {
        // SAFETY: Guaranteed by the caller contract.
        drop(unsafe { Box::from_raw(engine) });
    }
}

/// # Safety
/// `engine` and `out_phase` must point to valid values for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_phase(
    engine: *const CdrSecurityEngine,
    out_phase: *mut u32,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Some(out_phase) = (unsafe { out_phase.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    *out_phase = engine.core.phase() as u32;
    CDR_OK
}

/// # Safety
/// `engine` must point to a valid security engine for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_set_paused(
    engine: *mut CdrSecurityEngine,
    paused: u8,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    if paused > 1 {
        return CDR_ERROR_INVALID_ARGUMENT;
    }
    engine.core.set_paused(paused != 0);
    CDR_OK
}

/// # Safety
/// All pointers must address their stated readable byte lengths. `mode` is 1
/// for pairing and 2 for trusted authentication.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_begin_session(
    engine: *mut CdrSecurityEngine,
    session_id: *const u8,
    session_id_len: usize,
    peer_root_fingerprint: *const u8,
    peer_root_fingerprint_len: usize,
    requested_permission_bits: u64,
    mode: u32,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Ok(session_id) = (unsafe { read_utf8(session_id, session_id_len) }) else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    let Ok(peer) = (unsafe {
        read_fixed::<ROOT_FINGERPRINT_BYTES>(peer_root_fingerprint, peer_root_fingerprint_len)
    }) else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    let mode = match mode {
        1 => TrustedSessionMode::Pairing,
        2 => TrustedSessionMode::TrustedAuthentication,
        _ => return CDR_ERROR_INVALID_ARGUMENT,
    };
    map_security_result(engine.core.begin_session(
        session_id,
        peer,
        PermissionSet::from_bits(requested_permission_bits),
        mode,
    ))
}

/// # Safety
/// `engine` must point to a valid security engine for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_confirm_pairing(
    engine: *mut CdrSecurityEngine,
    sas_matches: u8,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    if sas_matches > 1 {
        return CDR_ERROR_INVALID_ARGUMENT;
    }
    map_security_result(engine.core.confirm_pairing(sas_matches != 0))
}

/// # Safety
/// `engine` must point to a valid security engine for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_complete_pairing(
    engine: *mut CdrSecurityEngine,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    map_security_result(engine.core.complete_pairing())
}

/// # Safety
/// Encoded grant and issuer key pointers must be valid for their stated
/// lengths. The output permission pointer must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_validate_pairing_grant(
    engine: *mut CdrSecurityEngine,
    grant_protobuf: *const u8,
    grant_protobuf_len: usize,
    issuer_root_public_key: *const u8,
    issuer_root_public_key_len: usize,
    now_unix_ms: u64,
    out_permission_bits: *mut u64,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Some(out_permission_bits) = (unsafe { out_permission_bits.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Ok(grant_proto) =
        (unsafe { decode_message::<ProtoTrustGrant>(grant_protobuf, grant_protobuf_len) })
    else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let Ok(grant) = trust_grant_from_proto(grant_proto) else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let Ok(issuer_key) =
        (unsafe { read_non_empty(issuer_root_public_key, issuer_root_public_key_len) })
    else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    match engine
        .core
        .validate_pairing_grant(&grant, issuer_key, now_unix_ms)
    {
        Ok(permissions) => {
            *out_permission_bits = permissions.bits();
            CDR_OK
        }
        Err(error) => map_security_error(error),
    }
}

/// # Safety
/// `engine` must point to a valid security engine for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_end_session(engine: *mut CdrSecurityEngine) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    engine.core.end_session();
    CDR_OK
}

/// # Safety
/// The engine and fixed-size grant id pointers must be valid for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_revoke_grant(
    engine: *mut CdrSecurityEngine,
    grant_id: *const u8,
    grant_id_len: usize,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Ok(grant_id) = (unsafe { read_fixed::<16>(grant_id, grant_id_len) }) else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    engine.core.revoke(grant_id);
    CDR_OK
}

/// # Safety
/// Encoded message and engine pointers must be valid for their stated lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_verify_envelope(
    engine: *mut CdrSecurityEngine,
    envelope_protobuf: *const u8,
    envelope_protobuf_len: usize,
    sender_identity_protobuf: *const u8,
    sender_identity_protobuf_len: usize,
    now_unix_ms: u64,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Ok(envelope_proto) = (unsafe {
        decode_message::<ProtoSignedPeerEnvelope>(envelope_protobuf, envelope_protobuf_len)
    }) else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let Ok(identity_proto) = (unsafe {
        decode_message::<ProtoDeviceIdentity>(
            sender_identity_protobuf,
            sender_identity_protobuf_len,
        )
    }) else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let Ok((envelope, root_public_key, certificate)) =
        signed_envelope_from_proto(envelope_proto, identity_proto)
    else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    map_security_result(engine.core.verify_envelope(
        &envelope,
        &root_public_key,
        &certificate,
        now_unix_ms,
    ))
}

/// # Safety
/// Encoded message and fixed-size fingerprint pointers must be valid. The
/// output permission pointer must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_authorize_grant(
    engine: *mut CdrSecurityEngine,
    grant_protobuf: *const u8,
    grant_protobuf_len: usize,
    issuer_root_public_key: *const u8,
    issuer_root_public_key_len: usize,
    expected_subject_fingerprint: *const u8,
    expected_subject_fingerprint_len: usize,
    now_unix_ms: u64,
    out_permission_bits: *mut u64,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Some(out_permission_bits) = (unsafe { out_permission_bits.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Ok(grant_proto) =
        (unsafe { decode_message::<ProtoTrustGrant>(grant_protobuf, grant_protobuf_len) })
    else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let Ok(grant) = trust_grant_from_proto(grant_proto) else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let Ok(issuer_key) =
        (unsafe { read_non_empty(issuer_root_public_key, issuer_root_public_key_len) })
    else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    let Ok(expected_subject) = (unsafe {
        read_fixed::<ROOT_FINGERPRINT_BYTES>(
            expected_subject_fingerprint,
            expected_subject_fingerprint_len,
        )
    }) else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    match engine
        .core
        .authorize_grant(&grant, issuer_key, &expected_subject, now_unix_ms)
    {
        Ok(permissions) => {
            *out_permission_bits = permissions.bits();
            CDR_OK
        }
        Err(error) => map_security_error(error),
    }
}

/// # Safety
/// Encoded grant, key and subject pointers must be valid for their stated
/// lengths. The grant is validated only as a device credential.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_authenticate_credential(
    engine: *mut CdrSecurityEngine,
    grant_protobuf: *const u8,
    grant_protobuf_len: usize,
    issuer_root_public_key: *const u8,
    issuer_root_public_key_len: usize,
    expected_subject_fingerprint: *const u8,
    expected_subject_fingerprint_len: usize,
    now_unix_ms: u64,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Ok(grant_proto) =
        (unsafe { decode_message::<ProtoTrustGrant>(grant_protobuf, grant_protobuf_len) })
    else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let Ok(grant) = trust_grant_from_proto(grant_proto) else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let Ok(issuer_key) =
        (unsafe { read_non_empty(issuer_root_public_key, issuer_root_public_key_len) })
    else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    let Ok(expected_subject) = (unsafe {
        read_fixed::<ROOT_FINGERPRINT_BYTES>(
            expected_subject_fingerprint,
            expected_subject_fingerprint_len,
        )
    }) else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    map_security_result(engine.core.authenticate_credential(
        &grant,
        issuer_key,
        &expected_subject,
        now_unix_ms,
    ))
}

/// # Safety
/// Encoded authorization and engine pointers must be valid. `local_is_host`
/// must be 0 or 1 and the output permission pointer must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_apply_host_authorization(
    engine: *mut CdrSecurityEngine,
    authorization_protobuf: *const u8,
    authorization_protobuf_len: usize,
    now_unix_ms: u64,
    local_is_host: u8,
    out_permission_bits: *mut u64,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Some(out_permission_bits) = (unsafe { out_permission_bits.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    if local_is_host > 1 {
        return CDR_ERROR_INVALID_ARGUMENT;
    }
    let Ok(proto) = (unsafe {
        decode_message::<ProtoTrustedSessionAuthorization>(
            authorization_protobuf,
            authorization_protobuf_len,
        )
    }) else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let Ok(authorization) = trusted_authorization_from_proto(proto) else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let result = if local_is_host != 0 {
        engine
            .core
            .install_host_authorization(&authorization, now_unix_ms)
    } else {
        engine
            .core
            .accept_host_authorization(&authorization, now_unix_ms)
    };
    match result {
        Ok(permissions) => {
            *out_permission_bits = permissions.bits();
            CDR_OK
        }
        Err(error) => map_security_error(error),
    }
}

/// # Safety
/// Encoded acknowledgement and engine pointers must be valid. The output
/// permission pointer must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_confirm_host_authorization_ack(
    engine: *mut CdrSecurityEngine,
    acknowledgement_protobuf: *const u8,
    acknowledgement_protobuf_len: usize,
    now_unix_ms: u64,
    out_permission_bits: *mut u64,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Some(out_permission_bits) = (unsafe { out_permission_bits.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Ok(proto) = (unsafe {
        decode_message::<ProtoTrustedSessionAuthorizationAck>(
            acknowledgement_protobuf,
            acknowledgement_protobuf_len,
        )
    }) else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let Ok(acknowledgement) = trusted_authorization_ack_from_proto(proto) else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    match engine
        .core
        .confirm_host_authorization_ack(&acknowledgement, now_unix_ms)
    {
        Ok(permissions) => {
            *out_permission_bits = permissions.bits();
            CDR_OK
        }
        Err(error) => map_security_error(error),
    }
}

/// # Safety
/// The engine and all input pointers must be valid for their stated lengths.
/// Authentication keys must be uncompressed SEC1 P-256 public keys.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_configure_webrtc_context(
    engine: *mut CdrSecurityEngine,
    controller_nonce: *const u8,
    controller_nonce_len: usize,
    host_nonce: *const u8,
    host_nonce_len: usize,
    controller_authentication_public_key: *const u8,
    controller_authentication_public_key_len: usize,
    host_authentication_public_key: *const u8,
    host_authentication_public_key_len: usize,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Ok(controller_nonce) =
        (unsafe { read_fixed::<16>(controller_nonce, controller_nonce_len) })
    else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    let Ok(host_nonce) = (unsafe { read_fixed::<16>(host_nonce, host_nonce_len) }) else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    let Ok(controller_key) = (unsafe {
        read_non_empty(
            controller_authentication_public_key,
            controller_authentication_public_key_len,
        )
    }) else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    let Ok(host_key) = (unsafe {
        read_non_empty(
            host_authentication_public_key,
            host_authentication_public_key_len,
        )
    }) else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    map_security_result(engine.core.configure_webrtc_context(
        controller_nonce,
        host_nonce,
        controller_key.to_vec(),
        host_key.to_vec(),
    ))
}

/// # Safety
/// Encoded binding and engine pointers must be valid. The output permission
/// pointer must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_engine_bind_webrtc(
    engine: *mut CdrSecurityEngine,
    binding_protobuf: *const u8,
    binding_protobuf_len: usize,
    now_unix_ms: u64,
    out_permission_bits: *mut u64,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Some(out_permission_bits) = (unsafe { out_permission_bits.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Ok(binding_proto) = (unsafe {
        decode_message::<ProtoTrustedSessionBinding>(binding_protobuf, binding_protobuf_len)
    }) else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let Ok(binding) = trusted_binding_from_proto(binding_proto) else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    match engine.core.bind_webrtc(&binding, now_unix_ms) {
        Ok(permissions) => {
            *out_permission_bits = permissions.bits();
            CDR_OK
        }
        Err(error) => map_security_error(error),
    }
}

/// # Safety
/// Input pointers must address the stated readable byte lengths. `output_len`
/// must be writable. `output` may be null only to query the required length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_machine_code_v2(
    public_key: *const u8,
    public_key_len: usize,
    output: *mut u8,
    output_capacity: usize,
    output_len: *mut usize,
) -> i32 {
    let Some(output_len) = (unsafe { output_len.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    if public_key.is_null() || public_key_len == 0 {
        return CDR_ERROR_INVALID_ARGUMENT;
    }
    // SAFETY: Guaranteed by the caller contract.
    let public_key = unsafe { slice::from_raw_parts(public_key, public_key_len) };
    let Ok(value) = machine_code_v2(public_key) else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    *output_len = value.len();
    if output.is_null() || output_capacity < value.len() {
        return CDR_ERROR_BUFFER_TOO_SMALL;
    }
    // SAFETY: Capacity was checked above and regions do not overlap.
    unsafe { ptr::copy_nonoverlapping(value.as_ptr(), output, value.len()) };
    CDR_OK
}

/// # Safety
/// All pointers must address their stated readable byte lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_verify_p256_signature_der(
    public_key: *const u8,
    public_key_len: usize,
    message: *const u8,
    message_len: usize,
    signature: *const u8,
    signature_len: usize,
) -> i32 {
    if public_key.is_null()
        || public_key_len == 0
        || message.is_null()
        || signature.is_null()
        || signature_len == 0
    {
        return CDR_ERROR_INVALID_ARGUMENT;
    }
    // SAFETY: Guaranteed by the caller contract.
    let public_key = unsafe { slice::from_raw_parts(public_key, public_key_len) };
    // SAFETY: A zero-length message still carries a non-null pointer.
    let message = unsafe { slice::from_raw_parts(message, message_len) };
    // SAFETY: Guaranteed by the caller contract.
    let signature = unsafe { slice::from_raw_parts(signature, signature_len) };
    match verify_p256_signature_der(public_key, message, signature) {
        Ok(()) => CDR_OK,
        Err(_) => CDR_ERROR_INVALID_SIGNATURE,
    }
}

/// # Safety
/// `identity_protobuf` must point to a valid encoded `DeviceIdentityPublic`
/// message for the stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_validate_device_identity(
    identity_protobuf: *const u8,
    identity_protobuf_len: usize,
    now_unix_ms: u64,
) -> i32 {
    let Ok(identity) = (unsafe {
        decode_message::<ProtoDeviceIdentity>(identity_protobuf, identity_protobuf_len)
    }) else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let Ok(root_fingerprint) = fixed_vec(identity.root_fingerprint_sha256) else {
        return CDR_ERROR_INVALID_MESSAGE;
    };
    let certificate = AuthenticationKeyCertificate {
        root_fingerprint,
        authentication_public_key_sec1: identity.authentication_public_key_sec1,
        not_before_unix_ms: identity.authentication_key_not_before_unix_ms,
        expires_at_unix_ms: identity.authentication_key_expires_at_unix_ms,
        root_signature_der: identity.authentication_key_certificate,
    };
    map_security_result(validate_device_identity(
        &identity.machine_code,
        &identity.root_public_key_sec1,
        &root_fingerprint,
        &certificate,
        now_unix_ms,
    ))
}

/// # Safety
/// Input pointers must address their stated readable byte lengths. The SAS
/// output is exactly six ASCII bytes; `output` must have at least that capacity.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_security_sas_code(
    first_public_key: *const u8,
    first_public_key_len: usize,
    second_public_key: *const u8,
    second_public_key_len: usize,
    session_nonce: *const u8,
    session_nonce_len: usize,
    output: *mut u8,
    output_capacity: usize,
) -> i32 {
    if first_public_key.is_null()
        || second_public_key.is_null()
        || session_nonce.is_null()
        || output.is_null()
        || first_public_key_len == 0
        || second_public_key_len == 0
        || session_nonce_len == 0
    {
        return CDR_ERROR_INVALID_ARGUMENT;
    }
    if output_capacity < 6 {
        return CDR_ERROR_BUFFER_TOO_SMALL;
    }
    // SAFETY: Guaranteed by the caller contract.
    let first = unsafe { slice::from_raw_parts(first_public_key, first_public_key_len) };
    // SAFETY: Guaranteed by the caller contract.
    let second = unsafe { slice::from_raw_parts(second_public_key, second_public_key_len) };
    // SAFETY: Guaranteed by the caller contract.
    let nonce = unsafe { slice::from_raw_parts(session_nonce, session_nonce_len) };
    let Ok(value) = sas_code(first, second, nonce) else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    // SAFETY: Capacity was checked above and regions do not overlap.
    unsafe { ptr::copy_nonoverlapping(value.as_ptr(), output, 6) };
    CDR_OK
}

unsafe fn read_non_empty<'a>(pointer: *const u8, length: usize) -> Result<&'a [u8], ()> {
    if pointer.is_null() || length == 0 {
        return Err(());
    }
    // SAFETY: The caller guarantees the pointer is readable for `length` bytes.
    Ok(unsafe { slice::from_raw_parts(pointer, length) })
}

unsafe fn read_fixed<const N: usize>(pointer: *const u8, length: usize) -> Result<[u8; N], ()> {
    if length != N {
        return Err(());
    }
    let bytes = unsafe { read_non_empty(pointer, length) }?;
    bytes.try_into().map_err(|_| ())
}

unsafe fn read_utf8(pointer: *const u8, length: usize) -> Result<String, ()> {
    let bytes = unsafe { read_non_empty(pointer, length) }?;
    std::str::from_utf8(bytes)
        .map(str::to_owned)
        .map_err(|_| ())
}

unsafe fn decode_message<T: Message + Default>(pointer: *const u8, length: usize) -> Result<T, ()> {
    let bytes = unsafe { read_non_empty(pointer, length) }?;
    T::decode(bytes).map_err(|_| ())
}

fn signed_envelope_from_proto(
    envelope: ProtoSignedPeerEnvelope,
    identity: ProtoDeviceIdentity,
) -> Result<(SignedPeerEnvelope, Vec<u8>, AuthenticationKeyCertificate), ()> {
    if envelope.authentication_public_key_sec1 != identity.authentication_public_key_sec1
        || envelope.authentication_key_certificate != identity.authentication_key_certificate
        || identity.root_public_key_sec1.is_empty()
    {
        return Err(());
    }
    let certificate = AuthenticationKeyCertificate {
        root_fingerprint: fixed_vec(identity.root_fingerprint_sha256)?,
        authentication_public_key_sec1: identity.authentication_public_key_sec1,
        not_before_unix_ms: identity.authentication_key_not_before_unix_ms,
        expires_at_unix_ms: identity.authentication_key_expires_at_unix_ms,
        root_signature_der: identity.authentication_key_certificate,
    };
    let envelope = SignedPeerEnvelope {
        protocol_version: envelope.protocol_version,
        session_id: envelope.session_id,
        sender_root_fingerprint: fixed_vec(envelope.sender_root_fingerprint)?,
        recipient_root_fingerprint: fixed_vec(envelope.recipient_root_fingerprint)?,
        sequence: envelope.sequence,
        issued_at_unix_ms: envelope.issued_at_unix_ms,
        expires_at_unix_ms: envelope.expires_at_unix_ms,
        nonce: fixed_vec(envelope.nonce)?,
        payload: envelope.payload,
        signature_der: envelope.signature,
    };
    Ok((envelope, identity.root_public_key_sec1, certificate))
}

fn trust_grant_from_proto(grant: ProtoTrustGrant) -> Result<TrustGrant, ()> {
    Ok(TrustGrant {
        grant_id: fixed_vec(grant.grant_id)?,
        issuer_root_fingerprint: fixed_vec(grant.issuer_root_fingerprint)?,
        subject_root_fingerprint: fixed_vec(grant.subject_root_fingerprint)?,
        permissions: permissions_from_proto(&grant.permissions)?,
        issued_at_unix_ms: grant.issued_at_unix_ms,
        soft_expires_at_unix_ms: grant.soft_expires_at_unix_ms,
        hard_expires_at_unix_ms: grant.hard_expires_at_unix_ms,
        automatic_renewal: grant.automatic_renewal,
        issuer_signature_der: grant.issuer_signature,
    })
}

fn trusted_binding_from_proto(
    binding: ProtoTrustedSessionBinding,
) -> Result<TrustedSessionBinding, ()> {
    let auth_suite_version = if binding.auth_suite_version == 0 {
        security_core::TRUSTED_AUTH_SUITE_LEGACY
    } else {
        binding.auth_suite_version
    };
    Ok(TrustedSessionBinding {
        session_id: binding.session_id,
        controller_nonce: fixed_vec(binding.controller_nonce)?,
        host_nonce: fixed_vec(binding.host_nonce)?,
        requested_permissions: permissions_from_proto(&binding.requested_permissions)?,
        controller_ephemeral_public_key: binding.controller_ephemeral_public_key,
        host_ephemeral_public_key: binding.host_ephemeral_public_key,
        offer_sha256: fixed_vec(binding.offer_sha256)?,
        answer_sha256: fixed_vec(binding.answer_sha256)?,
        controller_dtls_fingerprint_sha256: fixed_vec(binding.controller_dtls_fingerprint_sha256)?,
        host_dtls_fingerprint_sha256: fixed_vec(binding.host_dtls_fingerprint_sha256)?,
        expires_at_unix_ms: binding.expires_at_unix_ms,
        auth_suite_version,
        authorization_sha256: fixed_or_zero(binding.authorization_sha256)?,
        capability_sha256: fixed_or_zero(binding.capability_sha256)?,
    })
}

fn trusted_authorization_from_proto(
    authorization: ProtoTrustedSessionAuthorization,
) -> Result<TrustedSessionAuthorization, ()> {
    Ok(TrustedSessionAuthorization {
        protocol_version: authorization.protocol_version,
        session_id: authorization.session_id,
        credential_id: fixed_vec(authorization.credential_id)?,
        policy_revision: authorization.policy_revision,
        permissions: permissions_from_proto(&authorization.permissions)?,
        controller_root_fingerprint: fixed_vec(authorization.controller_root_fingerprint)?,
        host_root_fingerprint: fixed_vec(authorization.host_root_fingerprint)?,
        controller_nonce: fixed_vec(authorization.controller_nonce)?,
        host_nonce: fixed_vec(authorization.host_nonce)?,
        issued_at_unix_ms: authorization.issued_at_unix_ms,
        expires_at_unix_ms: authorization.expires_at_unix_ms,
        auth_suite_version: authorization.auth_suite_version,
        capability_sha256: fixed_vec(authorization.capability_sha256)?,
    })
}

fn trusted_authorization_ack_from_proto(
    acknowledgement: ProtoTrustedSessionAuthorizationAck,
) -> Result<TrustedSessionAuthorizationAck, ()> {
    Ok(TrustedSessionAuthorizationAck {
        protocol_version: acknowledgement.protocol_version,
        session_id: acknowledgement.session_id,
        authorization_sha256: fixed_vec(acknowledgement.authorization_sha256)?,
        policy_revision: acknowledgement.policy_revision,
        permissions: permissions_from_proto(&acknowledgement.permissions)?,
        controller_root_fingerprint: fixed_vec(acknowledgement.controller_root_fingerprint)?,
        host_root_fingerprint: fixed_vec(acknowledgement.host_root_fingerprint)?,
        controller_nonce: fixed_vec(acknowledgement.controller_nonce)?,
        host_nonce: fixed_vec(acknowledgement.host_nonce)?,
        issued_at_unix_ms: acknowledgement.issued_at_unix_ms,
        expires_at_unix_ms: acknowledgement.expires_at_unix_ms,
        auth_suite_version: acknowledgement.auth_suite_version,
        capability_sha256: fixed_vec(acknowledgement.capability_sha256)?,
    })
}

fn fixed_vec<const N: usize>(value: Vec<u8>) -> Result<[u8; N], ()> {
    value.try_into().map_err(|_| ())
}

fn fixed_or_zero<const N: usize>(value: Vec<u8>) -> Result<[u8; N], ()> {
    if value.is_empty() {
        Ok([0; N])
    } else {
        fixed_vec(value)
    }
}

fn permissions_from_proto(values: &[i32]) -> Result<PermissionSet, ()> {
    let mut result = PermissionSet::default();
    for value in values {
        let permission = match PermissionScope::try_from(*value).map_err(|_| ())? {
            PermissionScope::ViewScreen => SessionPermission::ViewScreen,
            PermissionScope::ControlInput => SessionPermission::ControlInput,
            PermissionScope::ReadClipboard => SessionPermission::ReadClipboard,
            PermissionScope::WriteClipboard => SessionPermission::WriteClipboard,
            PermissionScope::TransferFile => SessionPermission::TransferFiles,
            PermissionScope::CaptureScreenshot => SessionPermission::CaptureScreenshot,
            PermissionScope::RecordSession => SessionPermission::RecordSession,
            PermissionScope::UploadFileToHost => SessionPermission::UploadFilesToHost,
            PermissionScope::DownloadFileFromHost => SessionPermission::DownloadFilesFromHost,
            PermissionScope::Unspecified => return Err(()),
        };
        result = result.grant(permission);
    }
    if result.bits() == 0 {
        return Err(());
    }
    Ok(result)
}

fn map_security_result(result: Result<(), SecurityError>) -> i32 {
    match result {
        Ok(()) => CDR_OK,
        Err(error) => map_security_error(error),
    }
}

fn map_security_error(error: SecurityError) -> i32 {
    match error {
        SecurityError::InvalidState => CDR_ERROR_INVALID_STATE,
        SecurityError::InvalidSignature => CDR_ERROR_INVALID_SIGNATURE,
        SecurityError::Replay
        | SecurityError::SequenceRollback
        | SecurityError::ReplayCacheFull => CDR_ERROR_REPLAY,
        SecurityError::NotYetValid => CDR_ERROR_NOT_YET_VALID,
        SecurityError::Expired => CDR_ERROR_EXPIRED,
        SecurityError::SoftExpired => CDR_ERROR_SOFT_EXPIRED,
        SecurityError::HardExpired => CDR_ERROR_HARD_EXPIRED,
        SecurityError::LifetimeExceeded => CDR_ERROR_LIFETIME_EXCEEDED,
        SecurityError::PermissionDenied => CDR_ERROR_PERMISSION_DENIED,
        SecurityError::Revoked => CDR_ERROR_REVOKED,
        SecurityError::SessionMismatch
        | SecurityError::FingerprintMismatch
        | SecurityError::WrongRecipient => CDR_ERROR_SESSION_MISMATCH,
        SecurityError::Paused => CDR_ERROR_PAUSED,
        SecurityError::UnsupportedVersion
        | SecurityError::InvalidKey
        | SecurityError::InvalidMessage => CDR_ERROR_INVALID_MESSAGE,
    }
}

#[cfg(test)]
mod tests {
    use p256::ecdsa::{SigningKey, signature::Signer};
    use security_core::root_fingerprint;

    use super::*;

    #[test]
    fn exports_machine_code_with_sized_buffer_contract() {
        let key = SigningKey::from_bytes((&[8_u8; 32]).into()).expect("key");
        let public = key.verifying_key().to_encoded_point(false);
        let mut required = 0_usize;
        // SAFETY: All pointers are valid for their stated lengths.
        let sized = unsafe {
            cdr_security_machine_code_v2(
                public.as_bytes().as_ptr(),
                public.as_bytes().len(),
                ptr::null_mut(),
                0,
                &mut required,
            )
        };
        assert_eq!(sized, CDR_ERROR_BUFFER_TOO_SMALL);
        assert!(required > 6);
        let mut output = vec![0_u8; required];
        // SAFETY: All pointers are valid for their stated lengths.
        let written = unsafe {
            cdr_security_machine_code_v2(
                public.as_bytes().as_ptr(),
                public.as_bytes().len(),
                output.as_mut_ptr(),
                output.len(),
                &mut required,
            )
        };
        assert_eq!(written, CDR_OK);
        assert!(
            std::str::from_utf8(&output)
                .expect("ascii")
                .starts_with("CDR2-")
        );
    }

    #[test]
    fn security_engine_enforces_pairing_state_order() {
        let issuer = SigningKey::from_bytes((&[31_u8; 32]).into()).expect("issuer key");
        let issuer_public = issuer.verifying_key().to_encoded_point(false);
        let local = root_fingerprint(issuer_public.as_bytes()).expect("local fingerprint");
        let peer = [2_u8; ROOT_FINGERPRINT_BYTES];
        let session = b"pairing-session";
        let engine = cdr_security_engine_create(local.as_ptr(), local.len());
        assert!(!engine.is_null());
        // SAFETY: All pointers originate from live values in this scope.
        unsafe {
            assert_eq!(
                cdr_security_engine_begin_session(
                    engine,
                    session.as_ptr(),
                    session.len(),
                    peer.as_ptr(),
                    peer.len(),
                    1,
                    1,
                ),
                CDR_OK
            );
            let mut phase = u32::MAX;
            assert_eq!(cdr_security_engine_phase(engine, &mut phase), CDR_OK);
            assert_eq!(phase, 1);
            assert_eq!(cdr_security_engine_confirm_pairing(engine, 1), CDR_OK);
            assert_eq!(
                cdr_security_engine_complete_pairing(engine),
                CDR_ERROR_INVALID_STATE
            );
            let issued_at = 100_000_u64;
            let mut grant = TrustGrant {
                grant_id: [7; 16],
                issuer_root_fingerprint: local,
                subject_root_fingerprint: peer,
                permissions: PermissionSet::default().grant(SessionPermission::ViewScreen),
                issued_at_unix_ms: issued_at,
                soft_expires_at_unix_ms: issued_at + 10_000,
                hard_expires_at_unix_ms: issued_at + 20_000,
                automatic_renewal: true,
                issuer_signature_der: Vec::new(),
            };
            let signature: p256::ecdsa::Signature = issuer.sign(&grant.signing_bytes());
            grant.issuer_signature_der = signature.to_der().as_bytes().to_vec();
            let grant_proto = ProtoTrustGrant {
                grant_id: grant.grant_id.to_vec(),
                issuer_root_fingerprint: grant.issuer_root_fingerprint.to_vec(),
                subject_root_fingerprint: grant.subject_root_fingerprint.to_vec(),
                permissions: vec![PermissionScope::ViewScreen as i32],
                issued_at_unix_ms: grant.issued_at_unix_ms,
                soft_expires_at_unix_ms: grant.soft_expires_at_unix_ms,
                hard_expires_at_unix_ms: grant.hard_expires_at_unix_ms,
                automatic_renewal: grant.automatic_renewal,
                issuer_signature: grant.issuer_signature_der,
            }
            .encode_to_vec();
            let mut permissions = 0_u64;
            assert_eq!(
                cdr_security_engine_validate_pairing_grant(
                    engine,
                    grant_proto.as_ptr(),
                    grant_proto.len(),
                    issuer_public.as_bytes().as_ptr(),
                    issuer_public.as_bytes().len(),
                    issued_at - 30_000,
                    &mut permissions,
                ),
                CDR_OK
            );
            assert_eq!(permissions, 1);
            assert_eq!(cdr_security_engine_complete_pairing(engine), CDR_OK);
            assert_eq!(cdr_security_engine_phase(engine, &mut phase), CDR_OK);
            assert_eq!(phase, 0);
            cdr_security_engine_destroy(engine);

            let skewed_engine = cdr_security_engine_create(local.as_ptr(), local.len());
            assert!(!skewed_engine.is_null());
            assert_eq!(
                cdr_security_engine_begin_session(
                    skewed_engine,
                    session.as_ptr(),
                    session.len(),
                    peer.as_ptr(),
                    peer.len(),
                    1,
                    1,
                ),
                CDR_OK
            );
            assert_eq!(
                cdr_security_engine_confirm_pairing(skewed_engine, 1),
                CDR_OK
            );
            assert_eq!(
                cdr_security_engine_validate_pairing_grant(
                    skewed_engine,
                    grant_proto.as_ptr(),
                    grant_proto.len(),
                    issuer_public.as_bytes().as_ptr(),
                    issuer_public.as_bytes().len(),
                    issued_at - 30_001,
                    &mut permissions,
                ),
                CDR_ERROR_NOT_YET_VALID
            );
            cdr_security_engine_destroy(skewed_engine);
        }
    }
}
