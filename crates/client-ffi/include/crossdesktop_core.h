#ifndef CROSSDESKTOP_CORE_H
#define CROSSDESKTOP_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint32_t cdr_core_abi_version(void);
uint32_t cdr_core_protocol_major_version(void);
uint64_t cdr_core_feature_flags(void);

typedef struct CdrTransferManager CdrTransferManager;

typedef struct CdrTransferId {
  uint8_t bytes[16];
} CdrTransferId;

typedef struct CdrTransferProgress {
  CdrTransferId transfer_id;
  uint32_t state;
  uint64_t transferred_bytes;
  uint64_t total_bytes;
  uint32_t entry_count;
  uint16_t basis_points;
} CdrTransferProgress;

enum CdrResult {
  CDR_OK = 0,
  CDR_ERROR_NULL_POINTER = -1,
  CDR_ERROR_INVALID_ARGUMENT = -2,
  CDR_ERROR_INVALID_STATE = -3,
  CDR_ERROR_LIMIT_EXCEEDED = -4,
  CDR_ERROR_NOT_FOUND = -5,
  CDR_ERROR_PATH_REJECTED = -6,
  CDR_ERROR_BACKPRESSURE = -7,
  CDR_ERROR_TRANSPORT = -8,
  CDR_ERROR_INTEGRITY = -9,
  CDR_ERROR_IO = -10,
};

enum CdrTransferDirection {
  CDR_TRANSFER_DIRECTION_UPLOAD = 1,
  CDR_TRANSFER_DIRECTION_DOWNLOAD = 2,
};

enum CdrTransferState {
  CDR_TRANSFER_STATE_CREATED = 1,
  CDR_TRANSFER_STATE_OFFERED = 2,
  CDR_TRANSFER_STATE_ACCEPTED = 3,
  CDR_TRANSFER_STATE_TRANSFERRING = 4,
  CDR_TRANSFER_STATE_PAUSED = 5,
  CDR_TRANSFER_STATE_RECONNECTING = 6,
  CDR_TRANSFER_STATE_VERIFYING = 7,
  CDR_TRANSFER_STATE_COMPLETED = 8,
  CDR_TRANSFER_STATE_FAILED = 9,
  CDR_TRANSFER_STATE_CANCELLED = 10,
};

enum CdrTransferLane {
  CDR_TRANSFER_LANE_CLIPBOARD = 1,
  CDR_TRANSFER_LANE_CONTROL = 2,
  CDR_TRANSFER_LANE_FILE = 3,
};

typedef void (*CdrTransferProgressCallback)(
    const CdrTransferProgress *progress, void *user_data);
typedef int32_t (*CdrWebRtcSendCallback)(
    uint32_t lane, uint16_t stream_id, const uint8_t *payload,
    size_t payload_len, void *user_data);
typedef uint64_t (*CdrWebRtcBufferedAmountCallback)(
    uint32_t lane, uint16_t stream_id, void *user_data);

/*
 * Managers are single-thread confined. Callbacks run synchronously on the
 * calling thread, must not re-enter the manager, and remain owned by the
 * caller. WebRTC send callbacks must consume/copy payload bytes before return.
 */
CdrTransferManager *cdr_transfer_manager_create(void);
void cdr_transfer_manager_destroy(CdrTransferManager *manager);
int32_t cdr_transfer_set_progress_callback(
    CdrTransferManager *manager, CdrTransferProgressCallback callback,
    void *user_data);
int32_t cdr_transfer_task_create(
    CdrTransferManager *manager, const CdrTransferId *transfer_id,
    uint32_t direction, uint64_t total_bytes, uint32_t entry_count);
int32_t cdr_transfer_task_accept(
    CdrTransferManager *manager, const CdrTransferId *transfer_id);
int32_t cdr_transfer_task_pause(
    CdrTransferManager *manager, const CdrTransferId *transfer_id);
int32_t cdr_transfer_task_resume(
    CdrTransferManager *manager, const CdrTransferId *transfer_id);
int32_t cdr_transfer_task_cancel(
    CdrTransferManager *manager, const CdrTransferId *transfer_id);
int32_t cdr_transfer_task_record_progress(
    CdrTransferManager *manager, const CdrTransferId *transfer_id,
    uint64_t delta_bytes);
int32_t cdr_transfer_task_begin_verification(
    CdrTransferManager *manager, const CdrTransferId *transfer_id);
int32_t cdr_transfer_task_complete(
    CdrTransferManager *manager, const CdrTransferId *transfer_id);
int32_t cdr_transfer_task_get_progress(
    const CdrTransferManager *manager, const CdrTransferId *transfer_id,
    CdrTransferProgress *out_progress);
int32_t cdr_transfer_set_webrtc_transport(
    CdrTransferManager *manager, size_t max_payload_bytes,
    uint64_t max_buffered_bytes, CdrWebRtcSendCallback send_callback,
    CdrWebRtcBufferedAmountCallback buffered_amount_callback, void *user_data);
int32_t cdr_transfer_transport_send(
    const CdrTransferManager *manager, uint32_t lane, uint16_t stream_id,
    const uint8_t *payload, size_t payload_len);

#ifdef __cplusplus
}
#endif

#endif
