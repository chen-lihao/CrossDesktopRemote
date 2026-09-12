use std::{ptr, slice};

use security_core::{machine_code_v2, sas_code, verify_p256_signature_der};

const CDR_OK: i32 = 0;
const CDR_ERROR_NULL_POINTER: i32 = -1;
const CDR_ERROR_INVALID_ARGUMENT: i32 = -2;
const CDR_ERROR_BUFFER_TOO_SMALL: i32 = -11;
const CDR_ERROR_INVALID_SIGNATURE: i32 = -12;

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

#[cfg(test)]
mod tests {
    use p256::ecdsa::SigningKey;

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
}
