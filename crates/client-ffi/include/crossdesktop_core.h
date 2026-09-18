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
  CDR_ERROR_BUFFER_TOO_SMALL = -11,
  CDR_ERROR_INVALID_SIGNATURE = -12,
  CDR_ERROR_REPLAY = -13,
  CDR_ERROR_EXPIRED = -14,
  CDR_ERROR_PERMISSION_DENIED = -15,
  CDR_ERROR_REVOKED = -16,
  CDR_ERROR_SESSION_MISMATCH = -17,
  CDR_ERROR_PAUSED = -18,
  CDR_ERROR_INVALID_MESSAGE = -19,
  CDR_ERROR_NOT_YET_VALID = -20,
  CDR_ERROR_SOFT_EXPIRED = -21,
  CDR_ERROR_HARD_EXPIRED = -22,
  CDR_ERROR_LIFETIME_EXCEEDED = -23,
};

/* Security helpers never accept or return private key material. Native
 * platform keystores own signing keys and pass only public data/signatures. */
int32_t cdr_security_machine_code_v2(
    const uint8_t *public_key, size_t public_key_len, uint8_t *output,
    size_t output_capacity, size_t *output_len);
int32_t cdr_security_verify_p256_signature_der(
    const uint8_t *public_key, size_t public_key_len, const uint8_t *message,
    size_t message_len, const uint8_t *signature, size_t signature_len);
int32_t cdr_security_validate_device_identity(
    const uint8_t *identity_protobuf, size_t identity_protobuf_len,
    uint64_t now_unix_ms);
int32_t cdr_security_sas_code(
    const uint8_t *first_public_key, size_t first_public_key_len,
    const uint8_t *second_public_key, size_t second_public_key_len,
    const uint8_t *session_nonce, size_t session_nonce_len, uint8_t *output,
    size_t output_capacity);

typedef struct CdrSecurityEngine CdrSecurityEngine;

enum CdrSecurityPhase {
  CDR_SECURITY_PHASE_IDLE = 0,
  CDR_SECURITY_PHASE_PAIRING_AWAITING_CONFIRMATION = 1,
  CDR_SECURITY_PHASE_PAIRING_CONFIRMED = 2,
  CDR_SECURITY_PHASE_AUTHENTICATING = 3,
  CDR_SECURITY_PHASE_AWAITING_HOST_AUTHORIZATION = 4,
  CDR_SECURITY_PHASE_AWAITING_AUTHORIZATION_ACK = 5,
  CDR_SECURITY_PHASE_AWAITING_WEBRTC_BINDING = 6,
  CDR_SECURITY_PHASE_AUTHORIZED = 7,
  CDR_SECURITY_PHASE_FAILED = 8,
};

enum CdrSecuritySessionMode {
  CDR_SECURITY_SESSION_MODE_PAIRING = 1,
  CDR_SECURITY_SESSION_MODE_TRUSTED_AUTHENTICATION = 2,
};

/* Security engines are single-thread confined. Protobuf inputs use the
 * crossdesktop.v1 trust.proto messages and are copied during each call. */
CdrSecurityEngine *cdr_security_engine_create(
    const uint8_t *local_root_fingerprint,
    size_t local_root_fingerprint_len);
void cdr_security_engine_destroy(CdrSecurityEngine *engine);
int32_t cdr_security_engine_phase(
    const CdrSecurityEngine *engine, uint32_t *out_phase);
int32_t cdr_security_engine_set_paused(
    CdrSecurityEngine *engine, uint8_t paused);
int32_t cdr_security_engine_begin_session(
    CdrSecurityEngine *engine, const uint8_t *session_id,
    size_t session_id_len, const uint8_t *peer_root_fingerprint,
    size_t peer_root_fingerprint_len, uint64_t requested_permission_bits,
    uint32_t mode);
int32_t cdr_security_engine_begin_session_v2(
    CdrSecurityEngine *engine, const uint8_t *session_id,
    size_t session_id_len, const uint8_t *peer_root_fingerprint,
    size_t peer_root_fingerprint_len, uint64_t requested_permission_bits,
    uint32_t mode, uint32_t auth_suite_version,
    const uint8_t *capability_sha256, size_t capability_sha256_len);
int32_t cdr_security_engine_confirm_pairing(
    CdrSecurityEngine *engine, uint8_t sas_matches);
int32_t cdr_security_engine_validate_pairing_grant(
    CdrSecurityEngine *engine, const uint8_t *grant_protobuf,
    size_t grant_protobuf_len, const uint8_t *issuer_root_public_key,
    size_t issuer_root_public_key_len, uint64_t now_unix_ms,
    uint64_t *out_permission_bits);
int32_t cdr_security_engine_complete_pairing(CdrSecurityEngine *engine);
int32_t cdr_security_engine_end_session(CdrSecurityEngine *engine);
int32_t cdr_security_engine_revoke_grant(
    CdrSecurityEngine *engine, const uint8_t *grant_id,
    size_t grant_id_len);
int32_t cdr_security_engine_verify_envelope(
    CdrSecurityEngine *engine, const uint8_t *envelope_protobuf,
    size_t envelope_protobuf_len, const uint8_t *sender_identity_protobuf,
    size_t sender_identity_protobuf_len, uint64_t now_unix_ms);
int32_t cdr_security_engine_authorize_grant(
    CdrSecurityEngine *engine, const uint8_t *grant_protobuf,
    size_t grant_protobuf_len, const uint8_t *issuer_root_public_key,
    size_t issuer_root_public_key_len,
    const uint8_t *expected_subject_fingerprint,
    size_t expected_subject_fingerprint_len, uint64_t now_unix_ms,
    uint64_t *out_permission_bits);
int32_t cdr_security_engine_authenticate_credential(
    CdrSecurityEngine *engine, const uint8_t *grant_protobuf,
    size_t grant_protobuf_len, const uint8_t *issuer_root_public_key,
    size_t issuer_root_public_key_len,
    const uint8_t *expected_subject_fingerprint,
    size_t expected_subject_fingerprint_len, uint64_t now_unix_ms);
int32_t cdr_security_engine_apply_host_authorization(
    CdrSecurityEngine *engine, const uint8_t *authorization_protobuf,
    size_t authorization_protobuf_len, uint64_t now_unix_ms,
    uint8_t local_is_host, uint64_t *out_permission_bits);
int32_t cdr_security_engine_confirm_host_authorization_ack(
    CdrSecurityEngine *engine, const uint8_t *acknowledgement_protobuf,
    size_t acknowledgement_protobuf_len, uint64_t now_unix_ms,
    uint64_t *out_permission_bits);
int32_t cdr_security_engine_configure_webrtc_context(
    CdrSecurityEngine *engine, const uint8_t *controller_nonce,
    size_t controller_nonce_len, const uint8_t *host_nonce,
    size_t host_nonce_len,
    const uint8_t *controller_authentication_public_key,
    size_t controller_authentication_public_key_len,
    const uint8_t *host_authentication_public_key,
    size_t host_authentication_public_key_len);
int32_t cdr_security_engine_bind_webrtc(
    CdrSecurityEngine *engine, const uint8_t *binding_protobuf,
    size_t binding_protobuf_len, uint64_t now_unix_ms,
    uint64_t *out_permission_bits);
int32_t cdr_security_engine_validate_sdp_manifest(
    CdrSecurityEngine *engine, const uint8_t *manifest_protobuf,
    size_t manifest_protobuf_len, const uint8_t *sdp, size_t sdp_len,
    uint64_t now_unix_ms);
int32_t cdr_security_engine_bind_webrtc_transcript(
    CdrSecurityEngine *engine, const uint8_t *binding_protobuf,
    size_t binding_protobuf_len, const uint8_t *offer_sdp,
    size_t offer_sdp_len, const uint8_t *answer_sdp,
    size_t answer_sdp_len, uint64_t now_unix_ms,
    uint64_t *out_permission_bits);

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
