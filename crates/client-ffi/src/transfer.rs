use std::{ffi::c_void, slice, sync::Arc};

use transfer_core::{
    TransferDirection, TransferErrorKind, TransferId, TransferLane, TransferLimits,
    TransferManager, TransferProgress, WebRtcTransport,
};

pub const CDR_OK: i32 = 0;
pub const CDR_ERROR_NULL_POINTER: i32 = -1;
pub const CDR_ERROR_INVALID_ARGUMENT: i32 = -2;
pub const CDR_ERROR_INVALID_STATE: i32 = -3;
pub const CDR_ERROR_LIMIT_EXCEEDED: i32 = -4;
pub const CDR_ERROR_NOT_FOUND: i32 = -5;
pub const CDR_ERROR_PATH_REJECTED: i32 = -6;
pub const CDR_ERROR_BACKPRESSURE: i32 = -7;
pub const CDR_ERROR_TRANSPORT: i32 = -8;
pub const CDR_ERROR_INTEGRITY: i32 = -9;
pub const CDR_ERROR_IO: i32 = -10;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CdrTransferId {
    pub bytes: [u8; 16],
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CdrTransferProgress {
    pub transfer_id: CdrTransferId,
    pub state: u32,
    pub transferred_bytes: u64,
    pub total_bytes: u64,
    pub entry_count: u32,
    pub basis_points: u16,
}

pub type CdrTransferProgressCallback =
    Option<unsafe extern "C" fn(*const CdrTransferProgress, *mut c_void)>;
pub type CdrWebRtcSendCallback = Option<
    unsafe extern "C" fn(
        lane: u32,
        stream_id: u16,
        payload: *const u8,
        payload_len: usize,
        user_data: *mut c_void,
    ) -> i32,
>;
pub type CdrWebRtcBufferedAmountCallback =
    Option<unsafe extern "C" fn(lane: u32, stream_id: u16, user_data: *mut c_void) -> u64>;

pub struct CdrTransferManager {
    core: TransferManager,
    progress_callback: CdrTransferProgressCallback,
    progress_user_data: *mut c_void,
}

impl CdrTransferManager {
    fn notify(&self, progress: TransferProgress) {
        let Some(callback) = self.progress_callback else {
            return;
        };
        let progress = to_ffi_progress(progress);
        // SAFETY: The C caller promises that the callback and user data remain
        // valid until they are replaced or this manager is destroyed.
        unsafe { callback(&progress, self.progress_user_data) };
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn cdr_transfer_manager_create() -> *mut CdrTransferManager {
    let core = TransferManager::new(TransferLimits::default())
        .expect("compiled default transfer limits must be valid");
    Box::into_raw(Box::new(CdrTransferManager {
        core,
        progress_callback: None,
        progress_user_data: std::ptr::null_mut(),
    }))
}

/// # Safety
/// `manager` must be null or a pointer returned exactly once by
/// `cdr_transfer_manager_create`. It must not be used after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_transfer_manager_destroy(manager: *mut CdrTransferManager) {
    if !manager.is_null() {
        // SAFETY: Guaranteed by the caller contract above.
        drop(unsafe { Box::from_raw(manager) });
    }
}

/// # Safety
/// The manager pointer must be valid. The callback and `user_data` must remain
/// valid until replaced or until the manager is destroyed. Callbacks run
/// synchronously on the thread invoking the task API and must not re-enter it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_transfer_set_progress_callback(
    manager: *mut CdrTransferManager,
    callback: CdrTransferProgressCallback,
    user_data: *mut c_void,
) -> i32 {
    let Some(manager) = (unsafe { manager.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    manager.progress_callback = callback;
    manager.progress_user_data = user_data;
    CDR_OK
}

/// # Safety
/// `manager` and `transfer_id` must point to valid values for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_transfer_task_create(
    manager: *mut CdrTransferManager,
    transfer_id: *const CdrTransferId,
    direction: u32,
    total_bytes: u64,
    entry_count: u32,
) -> i32 {
    let Some(manager) = (unsafe { manager.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Some(transfer_id) = (unsafe { transfer_id.as_ref() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let direction = match direction {
        1 => TransferDirection::Upload,
        2 => TransferDirection::Download,
        _ => return CDR_ERROR_INVALID_ARGUMENT,
    };
    match manager.core.create_task(
        TransferId::new(transfer_id.bytes),
        direction,
        total_bytes,
        entry_count,
    ) {
        Ok(progress) => {
            manager.notify(progress);
            CDR_OK
        }
        Err(error) => map_error(error.kind),
    }
}

/// # Safety
/// `manager` and `transfer_id` must point to valid values for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_transfer_task_accept(
    manager: *mut CdrTransferManager,
    transfer_id: *const CdrTransferId,
) -> i32 {
    unsafe { run_task_operation(manager, transfer_id, TransferManager::accept) }
}

/// # Safety
/// `manager` and `transfer_id` must point to valid values for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_transfer_task_pause(
    manager: *mut CdrTransferManager,
    transfer_id: *const CdrTransferId,
) -> i32 {
    unsafe { run_task_operation(manager, transfer_id, TransferManager::pause) }
}

/// # Safety
/// `manager` and `transfer_id` must point to valid values for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_transfer_task_resume(
    manager: *mut CdrTransferManager,
    transfer_id: *const CdrTransferId,
) -> i32 {
    unsafe { run_task_operation(manager, transfer_id, TransferManager::resume) }
}

/// # Safety
/// `manager` and `transfer_id` must point to valid values for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_transfer_task_cancel(
    manager: *mut CdrTransferManager,
    transfer_id: *const CdrTransferId,
) -> i32 {
    unsafe { run_task_operation(manager, transfer_id, TransferManager::cancel) }
}

/// # Safety
/// `manager` and `transfer_id` must point to valid values for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_transfer_task_record_progress(
    manager: *mut CdrTransferManager,
    transfer_id: *const CdrTransferId,
    delta_bytes: u64,
) -> i32 {
    unsafe {
        run_task_operation(manager, transfer_id, |core, id| {
            core.record_progress(id, delta_bytes)
        })
    }
}

/// # Safety
/// `manager` and `transfer_id` must point to valid values for this call. The
/// native receiver must call this only after all resume blocks are present.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_transfer_task_begin_verification(
    manager: *mut CdrTransferManager,
    transfer_id: *const CdrTransferId,
) -> i32 {
    unsafe { run_task_operation(manager, transfer_id, TransferManager::begin_verification) }
}

/// # Safety
/// `manager` and `transfer_id` must point to valid values for this call. The
/// native receiver must call this only after SHA-256 verification succeeds.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_transfer_task_complete(
    manager: *mut CdrTransferManager,
    transfer_id: *const CdrTransferId,
) -> i32 {
    unsafe { run_task_operation(manager, transfer_id, TransferManager::complete) }
}

/// # Safety
/// All pointers must be valid for this call. `out_progress` is initialized only
/// when the function returns `CDR_OK`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_transfer_task_get_progress(
    manager: *const CdrTransferManager,
    transfer_id: *const CdrTransferId,
    out_progress: *mut CdrTransferProgress,
) -> i32 {
    let Some(manager) = (unsafe { manager.as_ref() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Some(transfer_id) = (unsafe { transfer_id.as_ref() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Some(out_progress) = (unsafe { out_progress.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    match manager.core.progress(TransferId::new(transfer_id.bytes)) {
        Ok(progress) => {
            *out_progress = to_ffi_progress(progress);
            CDR_OK
        }
        Err(error) => map_error(error.kind),
    }
}

/// # Safety
/// The manager pointer must be valid. The callbacks and `user_data` must remain
/// valid until replaced or until the manager is destroyed. The send callback
/// must consume/copy the payload synchronously; it must not retain the pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_transfer_set_webrtc_transport(
    manager: *mut CdrTransferManager,
    max_payload_bytes: usize,
    max_buffered_bytes: u64,
    send_callback: CdrWebRtcSendCallback,
    buffered_amount_callback: CdrWebRtcBufferedAmountCallback,
    user_data: *mut c_void,
) -> i32 {
    let Some(manager) = (unsafe { manager.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Some(send_callback) = send_callback else {
        manager.core.set_transport(None);
        return CDR_OK;
    };
    let user_data = user_data as usize;
    let send_frame = Arc::new(move |lane: TransferLane, payload: &[u8]| {
        let (lane, stream_id) = lane_parts(lane);
        // SAFETY: Callback lifetime and synchronous payload use are guaranteed
        // by the caller contract for cdr_transfer_set_webrtc_transport.
        let result = unsafe {
            send_callback(
                lane,
                stream_id,
                payload.as_ptr(),
                payload.len(),
                user_data as *mut c_void,
            )
        };
        if result == CDR_OK {
            Ok(())
        } else if result == CDR_ERROR_BACKPRESSURE {
            Err(transfer_core::TransferError::new(
                TransferErrorKind::Backpressure,
                "native WebRTC channel reported backpressure",
            ))
        } else {
            Err(transfer_core::TransferError::new(
                TransferErrorKind::Transport,
                "native WebRTC send callback failed",
            ))
        }
    });
    let buffered_amount = Arc::new(move |lane: TransferLane| {
        let Some(callback) = buffered_amount_callback else {
            return Ok(0);
        };
        let (lane, stream_id) = lane_parts(lane);
        // SAFETY: Callback lifetime is guaranteed by the caller contract.
        Ok(unsafe { callback(lane, stream_id, user_data as *mut c_void) })
    });
    match WebRtcTransport::new(
        max_payload_bytes,
        max_buffered_bytes,
        send_frame,
        buffered_amount,
    ) {
        Ok(transport) => {
            manager.core.set_transport(Some(Arc::new(transport)));
            CDR_OK
        }
        Err(error) => map_error(error.kind),
    }
}

/// # Safety
/// The manager must be valid. `payload` must point to `payload_len` readable
/// bytes and remains borrowed only for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cdr_transfer_transport_send(
    manager: *const CdrTransferManager,
    lane: u32,
    stream_id: u16,
    payload: *const u8,
    payload_len: usize,
) -> i32 {
    let Some(manager) = (unsafe { manager.as_ref() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    if payload.is_null() || payload_len == 0 {
        return CDR_ERROR_INVALID_ARGUMENT;
    }
    let Some(lane) = parse_lane(lane, stream_id) else {
        return CDR_ERROR_INVALID_ARGUMENT;
    };
    // SAFETY: The pointer and length are guaranteed by the caller contract.
    let payload = unsafe { slice::from_raw_parts(payload, payload_len) };
    match manager.core.transport_send(lane, payload) {
        Ok(()) => CDR_OK,
        Err(error) => map_error(error.kind),
    }
}

unsafe fn run_task_operation(
    manager: *mut CdrTransferManager,
    transfer_id: *const CdrTransferId,
    operation: impl FnOnce(
        &mut TransferManager,
        TransferId,
    ) -> transfer_core::TransferResult<TransferProgress>,
) -> i32 {
    let Some(manager) = (unsafe { manager.as_mut() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    let Some(transfer_id) = (unsafe { transfer_id.as_ref() }) else {
        return CDR_ERROR_NULL_POINTER;
    };
    match operation(&mut manager.core, TransferId::new(transfer_id.bytes)) {
        Ok(progress) => {
            manager.notify(progress);
            CDR_OK
        }
        Err(error) => map_error(error.kind),
    }
}

fn to_ffi_progress(progress: TransferProgress) -> CdrTransferProgress {
    CdrTransferProgress {
        transfer_id: CdrTransferId {
            bytes: progress.transfer_id.0,
        },
        state: progress.state as u32,
        transferred_bytes: progress.transferred_bytes,
        total_bytes: progress.total_bytes,
        entry_count: progress.entry_count,
        basis_points: progress.basis_points(),
    }
}

fn lane_parts(lane: TransferLane) -> (u32, u16) {
    match lane {
        TransferLane::Clipboard => (1, 0),
        TransferLane::Control => (2, 0),
        TransferLane::File(stream_id) => (3, stream_id),
    }
}

fn parse_lane(lane: u32, stream_id: u16) -> Option<TransferLane> {
    match lane {
        1 if stream_id == 0 => Some(TransferLane::Clipboard),
        2 if stream_id == 0 => Some(TransferLane::Control),
        3 => Some(TransferLane::File(stream_id)),
        _ => None,
    }
}

fn map_error(kind: TransferErrorKind) -> i32 {
    match kind {
        TransferErrorKind::InvalidArgument => CDR_ERROR_INVALID_ARGUMENT,
        TransferErrorKind::InvalidState => CDR_ERROR_INVALID_STATE,
        TransferErrorKind::LimitExceeded => CDR_ERROR_LIMIT_EXCEEDED,
        TransferErrorKind::NotFound => CDR_ERROR_NOT_FOUND,
        TransferErrorKind::PathRejected => CDR_ERROR_PATH_REJECTED,
        TransferErrorKind::Backpressure => CDR_ERROR_BACKPRESSURE,
        TransferErrorKind::Transport => CDR_ERROR_TRANSPORT,
        TransferErrorKind::Integrity => CDR_ERROR_INTEGRITY,
        TransferErrorKind::Io => CDR_ERROR_IO,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe extern "C" fn count_progress(
        _progress: *const CdrTransferProgress,
        user_data: *mut c_void,
    ) {
        // SAFETY: The test passes a valid usize pointer for the callback life.
        let counter = unsafe { &mut *user_data.cast::<usize>() };
        *counter += 1;
    }

    unsafe extern "C" fn send_frame(
        _lane: u32,
        _stream_id: u16,
        _payload: *const u8,
        payload_len: usize,
        user_data: *mut c_void,
    ) -> i32 {
        // SAFETY: The test passes a valid usize pointer for the callback life.
        let sent = unsafe { &mut *user_data.cast::<usize>() };
        *sent += payload_len;
        CDR_OK
    }

    #[test]
    fn exposes_task_lifecycle_and_progress_subscription() {
        let manager = cdr_transfer_manager_create();
        let id = CdrTransferId { bytes: [5; 16] };
        let cancelled_id = CdrTransferId { bytes: [6; 16] };
        let mut notifications = 0_usize;
        // SAFETY: All pointers remain valid for the duration of the calls.
        unsafe {
            assert_eq!(
                cdr_transfer_set_progress_callback(
                    manager,
                    Some(count_progress),
                    (&mut notifications as *mut usize).cast(),
                ),
                CDR_OK
            );
            assert_eq!(cdr_transfer_task_create(manager, &id, 1, 8, 1), CDR_OK);
            assert_eq!(cdr_transfer_task_accept(manager, &id), CDR_OK);
            assert_eq!(cdr_transfer_task_pause(manager, &id), CDR_OK);
            assert_eq!(cdr_transfer_task_resume(manager, &id), CDR_OK);
            assert_eq!(cdr_transfer_task_record_progress(manager, &id, 8), CDR_OK);
            assert_eq!(cdr_transfer_task_begin_verification(manager, &id), CDR_OK);
            assert_eq!(cdr_transfer_task_complete(manager, &id), CDR_OK);
            assert_eq!(
                cdr_transfer_task_create(manager, &cancelled_id, 2, 1, 1),
                CDR_OK
            );
            assert_eq!(cdr_transfer_task_cancel(manager, &cancelled_id), CDR_OK);

            let mut progress = CdrTransferProgress {
                transfer_id: id,
                state: 0,
                transferred_bytes: 0,
                total_bytes: 0,
                entry_count: 0,
                basis_points: 0,
            };
            assert_eq!(
                cdr_transfer_task_get_progress(manager, &id, &mut progress),
                CDR_OK
            );
            assert_eq!(
                progress.state,
                transfer_core::TransferState::Completed as u32
            );
            cdr_transfer_manager_destroy(manager);
        }
        assert_eq!(notifications, 9);
    }

    #[test]
    fn bridges_bounded_frames_to_native_webrtc() {
        let manager = cdr_transfer_manager_create();
        let mut sent = 0_usize;
        let payload = [1_u8; 16];
        // SAFETY: All pointers remain valid for the duration of the calls.
        unsafe {
            assert_eq!(
                cdr_transfer_set_webrtc_transport(
                    manager,
                    16,
                    32,
                    Some(send_frame),
                    None,
                    (&mut sent as *mut usize).cast(),
                ),
                CDR_OK
            );
            assert_eq!(
                cdr_transfer_transport_send(manager, 3, 7, payload.as_ptr(), payload.len()),
                CDR_OK
            );
            cdr_transfer_manager_destroy(manager);
        }
        assert_eq!(sent, payload.len());
    }
}
