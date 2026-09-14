use std::collections::{BTreeMap, BTreeSet};

use p256::ecdsa::{Signature, VerifyingKey, signature::Verifier};
use sha2::{Digest, Sha256};

pub const ROOT_FINGERPRINT_BYTES: usize = 32;
pub const NONCE_BYTES: usize = 16;
pub const DEFAULT_SESSION_TICKET_LIFETIME_MS: u64 = 60_000;
pub const DEFAULT_AUTH_KEY_LIFETIME_MS: u64 = 30 * 24 * 60 * 60 * 1_000;
pub const DEFAULT_AUTH_KEY_OVERLAP_MS: u64 = 7 * 24 * 60 * 60 * 1_000;
pub const DEFAULT_TRUST_SOFT_LIFETIME_MS: u64 = 90 * 24 * 60 * 60 * 1_000;
pub const DEFAULT_TRUST_RENEWAL_WINDOW_MS: u64 = 14 * 24 * 60 * 60 * 1_000;
pub const DEFAULT_TRUST_HARD_LIFETIME_MS: u64 = 365 * 24 * 60 * 60 * 1_000;
pub const DEFAULT_MAXIMUM_CLOCK_SKEW_MS: u64 = 30_000;
pub const MAX_SESSION_ID_BYTES: usize = 128;
// Signed payloads are base64-encoded into a signaling JSON envelope whose
// total limit is 64 KiB. Keep enough headroom for identity and signature data.
pub const MAX_SIGNED_PAYLOAD_BYTES: usize = 32 * 1_024;
pub const MAX_DER_SIGNATURE_BYTES: usize = 80;
pub const MAX_EPHEMERAL_PUBLIC_KEY_BYTES: usize = 512;
pub const P256_UNCOMPRESSED_PUBLIC_KEY_BYTES: usize = 65;
pub const TRUSTED_AUTH_SUITE_LEGACY: u32 = 1;
pub const TRUSTED_AUTH_SUITE_V2: u32 = 2;

/// One time-validity policy is shared by certificates, grants and signed
/// envelopes. Clock skew is accepted only at the lower (not-before) bound;
/// expiry bounds remain strict and are never extended by the tolerance.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrustedTimePolicy {
    maximum_clock_skew_ms: u64,
}

impl TrustedTimePolicy {
    #[must_use]
    pub const fn new(maximum_clock_skew_ms: u64) -> Self {
        Self {
            maximum_clock_skew_ms,
        }
    }

    #[must_use]
    pub const fn maximum_clock_skew_ms(self) -> u64 {
        self.maximum_clock_skew_ms
    }

    fn validate_not_before(
        self,
        not_before_unix_ms: u64,
        now_unix_ms: u64,
    ) -> Result<(), SecurityError> {
        if not_before_unix_ms > now_unix_ms.saturating_add(self.maximum_clock_skew_ms) {
            return Err(SecurityError::NotYetValid);
        }
        Ok(())
    }
}

impl Default for TrustedTimePolicy {
    fn default() -> Self {
        Self::new(DEFAULT_MAXIMUM_CLOCK_SKEW_MS)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u8)]
pub enum SessionPermission {
    ViewScreen = 0,
    ControlInput = 1,
    ReadClipboard = 2,
    WriteClipboard = 3,
    TransferFiles = 4,
    CaptureScreenshot = 5,
    RecordSession = 6,
    UploadFilesToHost = 7,
    DownloadFilesFromHost = 8,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PermissionSet(u64);

impl PermissionSet {
    #[must_use]
    pub const fn from_bits(bits: u64) -> Self {
        Self(bits & 0x1ff)
    }

    #[must_use]
    pub const fn bits(self) -> u64 {
        self.0
    }

    #[must_use]
    pub const fn grant(self, permission: SessionPermission) -> Self {
        Self(self.0 | (1_u64 << permission as u8))
    }

    #[must_use]
    pub const fn contains(self, permission: SessionPermission) -> bool {
        self.0 & (1_u64 << permission as u8) != 0
    }

    #[must_use]
    pub const fn intersection(self, requested: Self) -> Self {
        Self(self.0 & requested.0)
    }

    #[must_use]
    pub const fn is_subset_of(self, allowed: Self) -> bool {
        self.0 & !allowed.0 == 0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthenticationKeyCertificate {
    pub root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
    pub authentication_public_key_sec1: Vec<u8>,
    pub not_before_unix_ms: u64,
    pub expires_at_unix_ms: u64,
    pub root_signature_der: Vec<u8>,
}

impl AuthenticationKeyCertificate {
    #[must_use]
    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut output = Vec::with_capacity(96 + self.authentication_public_key_sec1.len());
        append_domain(&mut output, b"CrossDesktopRemote/AuthKeyCertificate/v1");
        append_bytes(&mut output, &self.root_fingerprint);
        append_bytes(&mut output, &self.authentication_public_key_sec1);
        output.extend_from_slice(&self.not_before_unix_ms.to_be_bytes());
        output.extend_from_slice(&self.expires_at_unix_ms.to_be_bytes());
        output
    }

    pub fn validate(
        &self,
        root_public_key_sec1: &[u8],
        now_unix_ms: u64,
    ) -> Result<(), SecurityError> {
        self.validate_with_policy(
            root_public_key_sec1,
            now_unix_ms,
            TrustedTimePolicy::default(),
        )
    }

    pub fn validate_with_policy(
        &self,
        root_public_key_sec1: &[u8],
        now_unix_ms: u64,
        time_policy: TrustedTimePolicy,
    ) -> Result<(), SecurityError> {
        if root_fingerprint(root_public_key_sec1)? != self.root_fingerprint {
            return Err(SecurityError::FingerprintMismatch);
        }
        if self.expires_at_unix_ms <= self.not_before_unix_ms
            || self.expires_at_unix_ms - self.not_before_unix_ms > DEFAULT_AUTH_KEY_LIFETIME_MS
        {
            return Err(SecurityError::LifetimeExceeded);
        }
        time_policy.validate_not_before(self.not_before_unix_ms, now_unix_ms)?;
        if now_unix_ms >= self.expires_at_unix_ms {
            return Err(SecurityError::Expired);
        }
        verify_p256_signature_der(
            root_public_key_sec1,
            &self.signing_bytes(),
            &self.root_signature_der,
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustGrant {
    pub grant_id: [u8; 16],
    pub issuer_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
    pub subject_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
    pub permissions: PermissionSet,
    pub issued_at_unix_ms: u64,
    pub soft_expires_at_unix_ms: u64,
    pub hard_expires_at_unix_ms: u64,
    pub automatic_renewal: bool,
    pub issuer_signature_der: Vec<u8>,
}

impl TrustGrant {
    #[must_use]
    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut output = Vec::with_capacity(160);
        append_domain(&mut output, b"CrossDesktopRemote/TrustGrant/v1");
        append_bytes(&mut output, &self.grant_id);
        append_bytes(&mut output, &self.issuer_root_fingerprint);
        append_bytes(&mut output, &self.subject_root_fingerprint);
        output.extend_from_slice(&self.permissions.bits().to_be_bytes());
        output.extend_from_slice(&self.issued_at_unix_ms.to_be_bytes());
        output.extend_from_slice(&self.soft_expires_at_unix_ms.to_be_bytes());
        output.extend_from_slice(&self.hard_expires_at_unix_ms.to_be_bytes());
        output.push(u8::from(self.automatic_renewal));
        output
    }

    pub fn validate(
        &self,
        issuer_root_public_key_sec1: &[u8],
        expected_subject: &[u8; ROOT_FINGERPRINT_BYTES],
        requested_permissions: PermissionSet,
        now_unix_ms: u64,
    ) -> Result<PermissionSet, SecurityError> {
        self.validate_with_policy(
            issuer_root_public_key_sec1,
            expected_subject,
            requested_permissions,
            now_unix_ms,
            TrustedTimePolicy::default(),
        )
    }

    pub fn validate_with_policy(
        &self,
        issuer_root_public_key_sec1: &[u8],
        expected_subject: &[u8; ROOT_FINGERPRINT_BYTES],
        requested_permissions: PermissionSet,
        now_unix_ms: u64,
        time_policy: TrustedTimePolicy,
    ) -> Result<PermissionSet, SecurityError> {
        if &self.subject_root_fingerprint != expected_subject {
            return Err(SecurityError::WrongRecipient);
        }
        if self.soft_expires_at_unix_ms <= self.issued_at_unix_ms
            || self.hard_expires_at_unix_ms < self.soft_expires_at_unix_ms
            || self.hard_expires_at_unix_ms - self.issued_at_unix_ms
                > DEFAULT_TRUST_HARD_LIFETIME_MS
        {
            return Err(SecurityError::LifetimeExceeded);
        }
        time_policy.validate_not_before(self.issued_at_unix_ms, now_unix_ms)?;
        if now_unix_ms >= self.hard_expires_at_unix_ms {
            return Err(SecurityError::HardExpired);
        }
        if now_unix_ms >= self.soft_expires_at_unix_ms {
            return Err(SecurityError::SoftExpired);
        }
        if !requested_permissions.is_subset_of(self.permissions) {
            return Err(SecurityError::PermissionDenied);
        }
        if root_fingerprint(issuer_root_public_key_sec1)? != self.issuer_root_fingerprint {
            return Err(SecurityError::FingerprintMismatch);
        }
        verify_p256_signature_der(
            issuer_root_public_key_sec1,
            &self.signing_bytes(),
            &self.issuer_signature_der,
        )?;
        Ok(self.permissions.intersection(requested_permissions))
    }

    #[must_use]
    pub fn should_auto_renew(&self, now_unix_ms: u64) -> bool {
        self.automatic_renewal
            && now_unix_ms < self.soft_expires_at_unix_ms
            && now_unix_ms < self.hard_expires_at_unix_ms
            && self.soft_expires_at_unix_ms.saturating_sub(now_unix_ms)
                <= DEFAULT_TRUST_RENEWAL_WINDOW_MS
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignedPeerEnvelope {
    pub protocol_version: u32,
    pub session_id: String,
    pub sender_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
    pub recipient_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
    pub sequence: u64,
    pub issued_at_unix_ms: u64,
    pub expires_at_unix_ms: u64,
    pub nonce: [u8; NONCE_BYTES],
    pub payload: Vec<u8>,
    pub signature_der: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustedSessionBinding {
    pub session_id: String,
    pub controller_nonce: [u8; NONCE_BYTES],
    pub host_nonce: [u8; NONCE_BYTES],
    pub requested_permissions: PermissionSet,
    pub controller_ephemeral_public_key: Vec<u8>,
    pub host_ephemeral_public_key: Vec<u8>,
    pub offer_sha256: [u8; ROOT_FINGERPRINT_BYTES],
    pub answer_sha256: [u8; ROOT_FINGERPRINT_BYTES],
    pub controller_dtls_fingerprint_sha256: [u8; ROOT_FINGERPRINT_BYTES],
    pub host_dtls_fingerprint_sha256: [u8; ROOT_FINGERPRINT_BYTES],
    pub expires_at_unix_ms: u64,
    pub auth_suite_version: u32,
    pub authorization_sha256: [u8; ROOT_FINGERPRINT_BYTES],
    pub capability_sha256: [u8; ROOT_FINGERPRINT_BYTES],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustedSessionAuthorization {
    pub protocol_version: u32,
    pub session_id: String,
    pub credential_id: [u8; 16],
    pub policy_revision: u64,
    pub permissions: PermissionSet,
    pub controller_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
    pub host_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
    pub controller_nonce: [u8; NONCE_BYTES],
    pub host_nonce: [u8; NONCE_BYTES],
    pub issued_at_unix_ms: u64,
    pub expires_at_unix_ms: u64,
    pub auth_suite_version: u32,
    pub capability_sha256: [u8; ROOT_FINGERPRINT_BYTES],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustedSessionAuthorizationAck {
    pub protocol_version: u32,
    pub session_id: String,
    pub authorization_sha256: [u8; ROOT_FINGERPRINT_BYTES],
    pub policy_revision: u64,
    pub permissions: PermissionSet,
    pub controller_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
    pub host_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
    pub controller_nonce: [u8; NONCE_BYTES],
    pub host_nonce: [u8; NONCE_BYTES],
    pub issued_at_unix_ms: u64,
    pub expires_at_unix_ms: u64,
    pub auth_suite_version: u32,
    pub capability_sha256: [u8; ROOT_FINGERPRINT_BYTES],
}

impl TrustedSessionAuthorization {
    #[must_use]
    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut output = Vec::with_capacity(256);
        append_domain(
            &mut output,
            b"CrossDesktopRemote/TrustedSessionAuthorization/v2",
        );
        append_bytes(&mut output, self.session_id.as_bytes());
        append_bytes(&mut output, &self.credential_id);
        output.extend_from_slice(&self.policy_revision.to_be_bytes());
        output.extend_from_slice(&self.permissions.bits().to_be_bytes());
        append_bytes(&mut output, &self.controller_root_fingerprint);
        append_bytes(&mut output, &self.host_root_fingerprint);
        append_bytes(&mut output, &self.controller_nonce);
        append_bytes(&mut output, &self.host_nonce);
        output.extend_from_slice(&self.issued_at_unix_ms.to_be_bytes());
        output.extend_from_slice(&self.expires_at_unix_ms.to_be_bytes());
        output.extend_from_slice(&self.auth_suite_version.to_be_bytes());
        append_bytes(&mut output, &self.capability_sha256);
        output
    }

    fn validate_time(&self, now_unix_ms: u64) -> Result<(), SecurityError> {
        if self.protocol_version != 1
            || self.session_id.is_empty()
            || self.session_id.len() > MAX_SESSION_ID_BYTES
            || self.policy_revision == 0
            || self.permissions.bits() == 0
            || !self.permissions.contains(SessionPermission::ViewScreen)
            || self.permissions.contains(SessionPermission::TransferFiles)
            || self.auth_suite_version != TRUSTED_AUTH_SUITE_V2
            || self.capability_sha256.iter().all(|byte| *byte == 0)
            || self.expires_at_unix_ms <= self.issued_at_unix_ms
            || self.expires_at_unix_ms - self.issued_at_unix_ms > DEFAULT_SESSION_TICKET_LIFETIME_MS
        {
            return Err(SecurityError::InvalidMessage);
        }
        TrustedTimePolicy::default().validate_not_before(self.issued_at_unix_ms, now_unix_ms)?;
        if now_unix_ms >= self.expires_at_unix_ms {
            return Err(SecurityError::Expired);
        }
        Ok(())
    }
}

impl TrustedSessionAuthorizationAck {
    #[must_use]
    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut output = Vec::with_capacity(256);
        append_domain(
            &mut output,
            b"CrossDesktopRemote/TrustedSessionAuthorizationAck/v1",
        );
        append_bytes(&mut output, self.session_id.as_bytes());
        append_bytes(&mut output, &self.authorization_sha256);
        output.extend_from_slice(&self.policy_revision.to_be_bytes());
        output.extend_from_slice(&self.permissions.bits().to_be_bytes());
        append_bytes(&mut output, &self.controller_root_fingerprint);
        append_bytes(&mut output, &self.host_root_fingerprint);
        append_bytes(&mut output, &self.controller_nonce);
        append_bytes(&mut output, &self.host_nonce);
        output.extend_from_slice(&self.issued_at_unix_ms.to_be_bytes());
        output.extend_from_slice(&self.expires_at_unix_ms.to_be_bytes());
        output.extend_from_slice(&self.auth_suite_version.to_be_bytes());
        append_bytes(&mut output, &self.capability_sha256);
        output
    }

    fn validate_time(&self, now_unix_ms: u64) -> Result<(), SecurityError> {
        if self.protocol_version != 1
            || self.session_id.is_empty()
            || self.session_id.len() > MAX_SESSION_ID_BYTES
            || self.authorization_sha256.iter().all(|byte| *byte == 0)
            || self.policy_revision == 0
            || self.permissions.bits() == 0
            || !self.permissions.contains(SessionPermission::ViewScreen)
            || self.permissions.contains(SessionPermission::TransferFiles)
            || self.auth_suite_version != TRUSTED_AUTH_SUITE_V2
            || self.capability_sha256.iter().all(|byte| *byte == 0)
            || self.expires_at_unix_ms <= self.issued_at_unix_ms
            || self.expires_at_unix_ms - self.issued_at_unix_ms > DEFAULT_SESSION_TICKET_LIFETIME_MS
        {
            return Err(SecurityError::InvalidMessage);
        }
        TrustedTimePolicy::default().validate_not_before(self.issued_at_unix_ms, now_unix_ms)?;
        if now_unix_ms >= self.expires_at_unix_ms {
            return Err(SecurityError::Expired);
        }
        Ok(())
    }
}

impl TrustedSessionBinding {
    #[must_use]
    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut output = Vec::with_capacity(320);
        append_domain(
            &mut output,
            if self.auth_suite_version == TRUSTED_AUTH_SUITE_V2 {
                b"CrossDesktopRemote/TrustedSessionBinding/v2"
            } else {
                b"CrossDesktopRemote/TrustedSessionBinding/v1"
            },
        );
        append_bytes(&mut output, self.session_id.as_bytes());
        append_bytes(&mut output, &self.controller_nonce);
        append_bytes(&mut output, &self.host_nonce);
        output.extend_from_slice(&self.requested_permissions.bits().to_be_bytes());
        append_bytes(&mut output, &self.controller_ephemeral_public_key);
        append_bytes(&mut output, &self.host_ephemeral_public_key);
        append_bytes(&mut output, &self.offer_sha256);
        append_bytes(&mut output, &self.answer_sha256);
        append_bytes(&mut output, &self.controller_dtls_fingerprint_sha256);
        append_bytes(&mut output, &self.host_dtls_fingerprint_sha256);
        output.extend_from_slice(&self.expires_at_unix_ms.to_be_bytes());
        if self.auth_suite_version == TRUSTED_AUTH_SUITE_V2 {
            output.extend_from_slice(&self.auth_suite_version.to_be_bytes());
            append_bytes(&mut output, &self.authorization_sha256);
            append_bytes(&mut output, &self.capability_sha256);
        }
        output
    }

    pub fn validate(
        &self,
        granted_permissions: PermissionSet,
        now_unix_ms: u64,
    ) -> Result<(), SecurityError> {
        if self.session_id.is_empty() || self.session_id.len() > MAX_SESSION_ID_BYTES {
            return Err(SecurityError::InvalidMessage);
        }
        if self.controller_nonce.iter().all(|byte| *byte == 0)
            || self.host_nonce.iter().all(|byte| *byte == 0)
            || self.controller_nonce == self.host_nonce
            || self.offer_sha256.iter().all(|byte| *byte == 0)
            || self.answer_sha256.iter().all(|byte| *byte == 0)
            || self
                .controller_dtls_fingerprint_sha256
                .iter()
                .all(|byte| *byte == 0)
            || self
                .host_dtls_fingerprint_sha256
                .iter()
                .all(|byte| *byte == 0)
        {
            return Err(SecurityError::InvalidMessage);
        }
        let valid_suite = match self.auth_suite_version {
            TRUSTED_AUTH_SUITE_LEGACY => {
                self.authorization_sha256.iter().all(|byte| *byte == 0)
                    && self.capability_sha256.iter().all(|byte| *byte == 0)
            }
            TRUSTED_AUTH_SUITE_V2 => {
                !self.authorization_sha256.iter().all(|byte| *byte == 0)
                    && !self.capability_sha256.iter().all(|byte| *byte == 0)
            }
            _ => false,
        };
        if !valid_suite {
            return Err(SecurityError::InvalidMessage);
        }
        validate_p256_public_key(&self.controller_ephemeral_public_key)?;
        validate_p256_public_key(&self.host_ephemeral_public_key)?;
        if !self.requested_permissions.is_subset_of(granted_permissions) {
            return Err(SecurityError::PermissionDenied);
        }
        if now_unix_ms >= self.expires_at_unix_ms
            || self.expires_at_unix_ms.saturating_sub(now_unix_ms)
                > DEFAULT_SESSION_TICKET_LIFETIME_MS
        {
            return Err(SecurityError::Expired);
        }
        Ok(())
    }
}

#[must_use]
pub fn pairing_nonce_commitment(
    session_id: &str,
    root_fingerprint: &[u8; ROOT_FINGERPRINT_BYTES],
    nonce: &[u8; NONCE_BYTES],
) -> [u8; ROOT_FINGERPRINT_BYTES] {
    let mut digest = Sha256::new();
    digest.update(b"CrossDesktopRemote/PairingNonceCommitment/v1");
    digest.update((session_id.len() as u32).to_be_bytes());
    digest.update(session_id.as_bytes());
    digest.update(root_fingerprint);
    digest.update(nonce);
    digest.finalize().into()
}

pub fn pairing_sas_code(
    session_id: &str,
    first_root_public_key_sec1: &[u8],
    first_nonce: &[u8; NONCE_BYTES],
    second_root_public_key_sec1: &[u8],
    second_nonce: &[u8; NONCE_BYTES],
) -> Result<String, SecurityError> {
    if session_id.is_empty() || session_id.len() > MAX_SESSION_ID_BYTES {
        return Err(SecurityError::InvalidMessage);
    }
    let first = root_fingerprint(first_root_public_key_sec1)?;
    let second = root_fingerprint(second_root_public_key_sec1)?;
    let ((lower_fingerprint, lower_nonce), (upper_fingerprint, upper_nonce)) = if first <= second {
        ((first, first_nonce), (second, second_nonce))
    } else {
        ((second, second_nonce), (first, first_nonce))
    };
    let mut digest = Sha256::new();
    digest.update(b"CrossDesktopRemote/PairingSAS/v1");
    digest.update((session_id.len() as u32).to_be_bytes());
    digest.update(session_id.as_bytes());
    digest.update(lower_fingerprint);
    digest.update(lower_nonce);
    digest.update(upper_fingerprint);
    digest.update(upper_nonce);
    let digest = digest.finalize();
    let value = u32::from_be_bytes(digest[..4].try_into().expect("fixed digest")) % 1_000_000;
    Ok(format!("{value:06}"))
}

impl SignedPeerEnvelope {
    #[must_use]
    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut output = Vec::with_capacity(192 + self.payload.len());
        append_domain(&mut output, b"CrossDesktopRemote/SignedPeerEnvelope/v1");
        output.extend_from_slice(&self.protocol_version.to_be_bytes());
        append_bytes(&mut output, self.session_id.as_bytes());
        append_bytes(&mut output, &self.sender_root_fingerprint);
        append_bytes(&mut output, &self.recipient_root_fingerprint);
        output.extend_from_slice(&self.sequence.to_be_bytes());
        output.extend_from_slice(&self.issued_at_unix_ms.to_be_bytes());
        output.extend_from_slice(&self.expires_at_unix_ms.to_be_bytes());
        append_bytes(&mut output, &self.nonce);
        append_bytes(&mut output, &self.payload);
        output
    }
}

#[derive(Debug)]
pub struct EnvelopeVerifier {
    local_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
    last_sequence_by_session: BTreeMap<(String, [u8; ROOT_FINGERPRINT_BYTES]), u64>,
    consumed_nonces: BTreeMap<[u8; NONCE_BYTES], u64>,
    revoked_grants: BTreeSet<[u8; 16]>,
    maximum_nonces: usize,
    time_policy: TrustedTimePolicy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum TrustedSecurityPhase {
    Idle = 0,
    PairingAwaitingConfirmation = 1,
    PairingConfirmed = 2,
    Authenticating = 3,
    AwaitingHostAuthorization = 4,
    AwaitingAuthorizationAck = 5,
    AwaitingWebRtcBinding = 6,
    Authorized = 7,
    Failed = 8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrustedSessionMode {
    Pairing,
    TrustedAuthentication,
}

#[derive(Debug)]
struct ActiveTrustedSession {
    session_id: String,
    peer_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
    requested_permissions: PermissionSet,
    granted_permissions: PermissionSet,
    grant_id: Option<[u8; 16]>,
    peer_proof_verified: bool,
    peer_authentication_public_key: Option<Vec<u8>>,
    verified_payload: Option<Vec<u8>>,
    web_rtc_context: Option<TrustedWebRtcContext>,
    authorization_sha256: Option<[u8; ROOT_FINGERPRINT_BYTES]>,
    authorization_policy_revision: Option<u64>,
    authorization_capability_sha256: Option<[u8; ROOT_FINGERPRINT_BYTES]>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct TrustedWebRtcContext {
    controller_nonce: [u8; NONCE_BYTES],
    host_nonce: [u8; NONCE_BYTES],
    controller_authentication_public_key: Vec<u8>,
    host_authentication_public_key: Vec<u8>,
}

impl TrustedWebRtcContext {
    fn validate(&self) -> Result<(), SecurityError> {
        if self.controller_nonce.iter().all(|byte| *byte == 0)
            || self.host_nonce.iter().all(|byte| *byte == 0)
            || self.controller_nonce == self.host_nonce
        {
            return Err(SecurityError::InvalidMessage);
        }
        validate_p256_public_key(&self.controller_authentication_public_key)?;
        validate_p256_public_key(&self.host_authentication_public_key)
    }

    fn matches(&self, binding: &TrustedSessionBinding) -> bool {
        self.controller_nonce == binding.controller_nonce
            && self.host_nonce == binding.host_nonce
            && self.controller_authentication_public_key == binding.controller_ephemeral_public_key
            && self.host_authentication_public_key == binding.host_ephemeral_public_key
    }
}

/// Authoritative state machine for trusted-device pairing and authentication.
///
/// Platform code owns non-exportable private keys. Presentation code may drive
/// this engine, but cannot skip a phase or grant permissions on its own.
#[derive(Debug)]
pub struct TrustedSecurityEngine {
    local_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
    phase: TrustedSecurityPhase,
    paused: bool,
    active: Option<ActiveTrustedSession>,
    verifier: EnvelopeVerifier,
    revoked_grants: BTreeSet<[u8; 16]>,
}

impl TrustedSecurityEngine {
    #[must_use]
    pub fn new(local_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES]) -> Self {
        Self {
            local_root_fingerprint,
            phase: TrustedSecurityPhase::Idle,
            paused: false,
            active: None,
            verifier: EnvelopeVerifier::new(local_root_fingerprint),
            revoked_grants: BTreeSet::new(),
        }
    }

    #[must_use]
    pub const fn phase(&self) -> TrustedSecurityPhase {
        self.phase
    }

    #[must_use]
    pub const fn local_root_fingerprint(&self) -> [u8; ROOT_FINGERPRINT_BYTES] {
        self.local_root_fingerprint
    }

    #[must_use]
    pub const fn paused(&self) -> bool {
        self.paused
    }

    pub fn set_paused(&mut self, paused: bool) {
        self.paused = paused;
        if paused && self.phase != TrustedSecurityPhase::Idle {
            self.fail_closed();
        }
    }

    pub fn begin_session(
        &mut self,
        session_id: String,
        peer_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
        requested_permissions: PermissionSet,
        mode: TrustedSessionMode,
    ) -> Result<(), SecurityError> {
        if self.paused {
            return Err(SecurityError::Paused);
        }
        if self.phase != TrustedSecurityPhase::Idle
            || session_id.is_empty()
            || session_id.len() > MAX_SESSION_ID_BYTES
            || requested_permissions.bits() == 0
            || !requested_permissions.contains(SessionPermission::ViewScreen)
        {
            return Err(SecurityError::InvalidState);
        }
        self.active = Some(ActiveTrustedSession {
            session_id,
            peer_root_fingerprint,
            requested_permissions,
            granted_permissions: PermissionSet::default(),
            grant_id: None,
            peer_proof_verified: false,
            peer_authentication_public_key: None,
            verified_payload: None,
            web_rtc_context: None,
            authorization_sha256: None,
            authorization_policy_revision: None,
            authorization_capability_sha256: None,
        });
        self.phase = match mode {
            TrustedSessionMode::Pairing => TrustedSecurityPhase::PairingAwaitingConfirmation,
            TrustedSessionMode::TrustedAuthentication => TrustedSecurityPhase::Authenticating,
        };
        Ok(())
    }

    /// Freezes the authenticated nonces and certified authentication keys
    /// that the final WebRTC transcript must contain. Repeating the same
    /// context is idempotent; attempting to replace it fails the session.
    pub fn configure_webrtc_context(
        &mut self,
        controller_nonce: [u8; NONCE_BYTES],
        host_nonce: [u8; NONCE_BYTES],
        controller_authentication_public_key: Vec<u8>,
        host_authentication_public_key: Vec<u8>,
    ) -> Result<(), SecurityError> {
        if self.paused
            || !matches!(
                self.phase,
                TrustedSecurityPhase::Authenticating
                    | TrustedSecurityPhase::AwaitingWebRtcBinding
                    | TrustedSecurityPhase::AwaitingHostAuthorization
                    | TrustedSecurityPhase::AwaitingAuthorizationAck
            )
        {
            return Err(SecurityError::InvalidState);
        }
        let context = TrustedWebRtcContext {
            controller_nonce,
            host_nonce,
            controller_authentication_public_key,
            host_authentication_public_key,
        };
        if let Err(error) = context.validate() {
            self.fail_closed();
            return Err(error);
        }
        let active = self.active.as_mut().ok_or(SecurityError::InvalidState)?;
        if let Some(existing) = &active.web_rtc_context {
            if existing == &context {
                return Ok(());
            }
            self.fail_closed();
            return Err(SecurityError::SessionMismatch);
        }
        active.web_rtc_context = Some(context);
        Ok(())
    }

    pub fn confirm_pairing(&mut self, sas_matches: bool) -> Result<(), SecurityError> {
        if self.phase != TrustedSecurityPhase::PairingAwaitingConfirmation {
            return Err(SecurityError::InvalidState);
        }
        if !sas_matches {
            self.fail_closed();
            return Err(SecurityError::InvalidSignature);
        }
        self.phase = TrustedSecurityPhase::PairingConfirmed;
        Ok(())
    }

    pub fn complete_pairing(&mut self) -> Result<(), SecurityError> {
        if self.phase != TrustedSecurityPhase::PairingConfirmed
            || self
                .active
                .as_ref()
                .and_then(|active| active.grant_id)
                .is_none()
        {
            return Err(SecurityError::InvalidState);
        }
        self.end_session();
        Ok(())
    }

    /// Validates the grant exchanged by a confirmed pairing transaction.
    /// Either the local device or the authenticated peer may be the issuer;
    /// the subject must be the opposite endpoint from that issuer.
    pub fn validate_pairing_grant(
        &mut self,
        grant: &TrustGrant,
        issuer_root_public_key_sec1: &[u8],
        now_unix_ms: u64,
    ) -> Result<PermissionSet, SecurityError> {
        if self.paused || self.phase != TrustedSecurityPhase::PairingConfirmed {
            return Err(SecurityError::InvalidState);
        }
        let active = self.active.as_ref().ok_or(SecurityError::InvalidState)?;
        if self.revoked_grants.contains(&grant.grant_id) {
            self.fail_closed();
            return Err(SecurityError::Revoked);
        }
        let expected_subject = if grant.issuer_root_fingerprint == self.local_root_fingerprint {
            active.peer_root_fingerprint
        } else if grant.issuer_root_fingerprint == active.peer_root_fingerprint {
            self.local_root_fingerprint
        } else {
            self.fail_closed();
            return Err(SecurityError::SessionMismatch);
        };
        let requested = active.requested_permissions;
        let granted = match grant.validate_with_policy(
            issuer_root_public_key_sec1,
            &expected_subject,
            requested,
            now_unix_ms,
            TrustedTimePolicy::default(),
        ) {
            Ok(value) => value,
            Err(error) => {
                self.fail_closed();
                return Err(error);
            }
        };
        let active = self.active.as_mut().ok_or(SecurityError::InvalidState)?;
        if let Some(existing_grant_id) = active.grant_id {
            if existing_grant_id == grant.grant_id && active.granted_permissions == granted {
                return Ok(granted);
            }
            self.fail_closed();
            return Err(SecurityError::SessionMismatch);
        }
        active.granted_permissions = granted;
        active.grant_id = Some(grant.grant_id);
        Ok(granted)
    }

    pub fn verify_envelope(
        &mut self,
        envelope: &SignedPeerEnvelope,
        sender_root_public_key_sec1: &[u8],
        sender_authentication_certificate: &AuthenticationKeyCertificate,
        now_unix_ms: u64,
    ) -> Result<(), SecurityError> {
        if self.paused
            || !matches!(
                self.phase,
                TrustedSecurityPhase::Authenticating
                    | TrustedSecurityPhase::AwaitingHostAuthorization
                    | TrustedSecurityPhase::AwaitingAuthorizationAck
                    | TrustedSecurityPhase::AwaitingWebRtcBinding
                    | TrustedSecurityPhase::Authorized
            )
        {
            return Err(SecurityError::InvalidState);
        }
        let active = self.active.as_ref().ok_or(SecurityError::InvalidState)?;
        if envelope.session_id != active.session_id
            || envelope.sender_root_fingerprint != active.peer_root_fingerprint
        {
            self.fail_closed();
            return Err(SecurityError::SessionMismatch);
        }
        let peer = active.peer_root_fingerprint;
        if let Err(error) = self.verifier.verify(
            envelope,
            sender_root_public_key_sec1,
            sender_authentication_certificate,
            &peer,
            now_unix_ms,
        ) {
            self.fail_closed();
            return Err(error);
        }
        let active = self.active.as_mut().ok_or(SecurityError::InvalidState)?;
        let peer_key = &sender_authentication_certificate.authentication_public_key_sec1;
        if active
            .peer_authentication_public_key
            .as_ref()
            .is_some_and(|existing| existing != peer_key)
        {
            self.fail_closed();
            return Err(SecurityError::SessionMismatch);
        }
        active.peer_proof_verified = true;
        active.peer_authentication_public_key = Some(peer_key.clone());
        active.verified_payload = Some(envelope.payload.clone());
        self.advance_after_authentication_inputs();
        Ok(())
    }

    pub fn authorize_grant(
        &mut self,
        grant: &TrustGrant,
        issuer_root_public_key_sec1: &[u8],
        expected_subject: &[u8; ROOT_FINGERPRINT_BYTES],
        now_unix_ms: u64,
    ) -> Result<PermissionSet, SecurityError> {
        if self.paused
            || !matches!(
                self.phase,
                TrustedSecurityPhase::Authenticating
                    | TrustedSecurityPhase::AwaitingWebRtcBinding
                    | TrustedSecurityPhase::Authorized
            )
        {
            return Err(SecurityError::InvalidState);
        }
        let active = self.active.as_ref().ok_or(SecurityError::InvalidState)?;
        if self.revoked_grants.contains(&grant.grant_id) {
            self.fail_closed();
            return Err(SecurityError::Revoked);
        }
        let requested = active.requested_permissions;
        let granted = match grant.validate(
            issuer_root_public_key_sec1,
            expected_subject,
            requested,
            now_unix_ms,
        ) {
            Ok(value) => value,
            Err(error) => {
                self.fail_closed();
                return Err(error);
            }
        };
        let active = self.active.as_mut().ok_or(SecurityError::InvalidState)?;
        active.granted_permissions = granted;
        active.grant_id = Some(grant.grant_id);
        self.advance_after_authentication_inputs();
        Ok(granted)
    }

    /// Validates a trust grant only as a device credential. Its legacy
    /// permission bits never become live session authority.
    pub fn authenticate_credential(
        &mut self,
        grant: &TrustGrant,
        issuer_root_public_key_sec1: &[u8],
        expected_subject: &[u8; ROOT_FINGERPRINT_BYTES],
        now_unix_ms: u64,
    ) -> Result<(), SecurityError> {
        if self.paused
            || !matches!(
                self.phase,
                TrustedSecurityPhase::Authenticating
                    | TrustedSecurityPhase::AwaitingHostAuthorization
                    | TrustedSecurityPhase::Authorized
            )
        {
            return Err(SecurityError::InvalidState);
        }
        let active = self.active.as_ref().ok_or(SecurityError::InvalidState)?;
        if self.revoked_grants.contains(&grant.grant_id) {
            self.fail_closed();
            return Err(SecurityError::Revoked);
        }
        let identity_scope = PermissionSet::default().grant(SessionPermission::ViewScreen);
        if let Err(error) = grant.validate(
            issuer_root_public_key_sec1,
            expected_subject,
            identity_scope,
            now_unix_ms,
        ) {
            self.fail_closed();
            return Err(error);
        }
        if self.phase == TrustedSecurityPhase::Authorized {
            return Ok(());
        }
        if active.requested_permissions != identity_scope {
            self.fail_closed();
            return Err(SecurityError::PermissionDenied);
        }
        let active = self.active.as_mut().ok_or(SecurityError::InvalidState)?;
        active.grant_id = Some(grant.grant_id);
        self.advance_after_authentication_inputs();
        Ok(())
    }

    /// Installs the host-owned policy snapshot on the host side. The security
    /// core validates every binding field; Dart cannot expand its authority.
    pub fn install_host_authorization(
        &mut self,
        authorization: &TrustedSessionAuthorization,
        now_unix_ms: u64,
    ) -> Result<PermissionSet, SecurityError> {
        self.apply_host_authorization(authorization, now_unix_ms, true)
    }

    /// Accepts the exact authorization payload previously verified inside the
    /// host's signed envelope on the controller side.
    pub fn accept_host_authorization(
        &mut self,
        authorization: &TrustedSessionAuthorization,
        now_unix_ms: u64,
    ) -> Result<PermissionSet, SecurityError> {
        self.apply_host_authorization(authorization, now_unix_ms, false)
    }

    fn apply_host_authorization(
        &mut self,
        authorization: &TrustedSessionAuthorization,
        now_unix_ms: u64,
        local_is_host: bool,
    ) -> Result<PermissionSet, SecurityError> {
        if self.paused || self.phase != TrustedSecurityPhase::AwaitingHostAuthorization {
            return Err(SecurityError::InvalidState);
        }
        if let Err(error) = authorization.validate_time(now_unix_ms) {
            self.fail_closed();
            return Err(error);
        }
        let active = self.active.as_ref().ok_or(SecurityError::InvalidState)?;
        let Some(context) = active.web_rtc_context.as_ref() else {
            self.fail_closed();
            return Err(SecurityError::InvalidState);
        };
        let identities_match = if local_is_host {
            authorization.host_root_fingerprint == self.local_root_fingerprint
                && authorization.controller_root_fingerprint == active.peer_root_fingerprint
        } else {
            authorization.controller_root_fingerprint == self.local_root_fingerprint
                && authorization.host_root_fingerprint == active.peer_root_fingerprint
        };
        let signed_payload_matches = local_is_host
            || active.verified_payload.as_deref() == Some(authorization.signing_bytes().as_slice());
        if authorization.session_id != active.session_id
            || active.grant_id != Some(authorization.credential_id)
            || authorization.controller_nonce != context.controller_nonce
            || authorization.host_nonce != context.host_nonce
            || !identities_match
            || !signed_payload_matches
        {
            self.fail_closed();
            return Err(SecurityError::SessionMismatch);
        }
        let authorization_sha256: [u8; ROOT_FINGERPRINT_BYTES] =
            Sha256::digest(authorization.signing_bytes()).into();
        let active = self.active.as_mut().ok_or(SecurityError::InvalidState)?;
        active.requested_permissions = authorization.permissions;
        active.granted_permissions = authorization.permissions;
        active.authorization_sha256 = Some(authorization_sha256);
        active.authorization_policy_revision = Some(authorization.policy_revision);
        active.authorization_capability_sha256 = Some(authorization.capability_sha256);
        self.phase = if local_is_host {
            TrustedSecurityPhase::AwaitingAuthorizationAck
        } else {
            TrustedSecurityPhase::AwaitingWebRtcBinding
        };
        Ok(authorization.permissions)
    }

    /// Confirms that the controller accepted the exact host-owned permission
    /// snapshot. The host must not start capture or create a WebRTC offer until
    /// the controller's signed acknowledgement has passed this check.
    pub fn confirm_host_authorization_ack(
        &mut self,
        acknowledgement: &TrustedSessionAuthorizationAck,
        now_unix_ms: u64,
    ) -> Result<PermissionSet, SecurityError> {
        if self.paused || self.phase != TrustedSecurityPhase::AwaitingAuthorizationAck {
            return Err(SecurityError::InvalidState);
        }
        if let Err(error) = acknowledgement.validate_time(now_unix_ms) {
            self.fail_closed();
            return Err(error);
        }
        let active = self.active.as_ref().ok_or(SecurityError::InvalidState)?;
        let Some(context) = active.web_rtc_context.as_ref() else {
            self.fail_closed();
            return Err(SecurityError::InvalidState);
        };
        if acknowledgement.session_id != active.session_id
            || acknowledgement.controller_root_fingerprint != active.peer_root_fingerprint
            || acknowledgement.host_root_fingerprint != self.local_root_fingerprint
            || acknowledgement.controller_nonce != context.controller_nonce
            || acknowledgement.host_nonce != context.host_nonce
            || acknowledgement.permissions != active.granted_permissions
            || active.authorization_sha256 != Some(acknowledgement.authorization_sha256)
            || active.authorization_policy_revision != Some(acknowledgement.policy_revision)
            || active.authorization_capability_sha256 != Some(acknowledgement.capability_sha256)
            || active.verified_payload.as_deref()
                != Some(acknowledgement.signing_bytes().as_slice())
        {
            self.fail_closed();
            return Err(SecurityError::SessionMismatch);
        }
        self.phase = TrustedSecurityPhase::AwaitingWebRtcBinding;
        Ok(active.granted_permissions)
    }

    pub fn bind_webrtc(
        &mut self,
        binding: &TrustedSessionBinding,
        now_unix_ms: u64,
    ) -> Result<PermissionSet, SecurityError> {
        if self.paused || self.phase != TrustedSecurityPhase::AwaitingWebRtcBinding {
            return Err(SecurityError::InvalidState);
        }
        let active = self.active.as_ref().ok_or(SecurityError::InvalidState)?;
        let Some(context) = active.web_rtc_context.as_ref() else {
            self.fail_closed();
            return Err(SecurityError::InvalidState);
        };
        let Some(peer_authentication_public_key) = active.peer_authentication_public_key.as_ref()
        else {
            self.fail_closed();
            return Err(SecurityError::InvalidState);
        };
        let controller_is_peer =
            context.controller_authentication_public_key == *peer_authentication_public_key;
        let host_is_peer =
            context.host_authentication_public_key == *peer_authentication_public_key;
        let authorization_matches = match active.authorization_sha256 {
            Some(expected) => {
                binding.auth_suite_version == TRUSTED_AUTH_SUITE_V2
                    && binding.authorization_sha256 == expected
                    && active.authorization_capability_sha256 == Some(binding.capability_sha256)
            }
            None => binding.auth_suite_version == TRUSTED_AUTH_SUITE_LEGACY,
        };
        if binding.session_id != active.session_id
            || binding.requested_permissions != active.requested_permissions
            || active.verified_payload.as_deref() != Some(binding.signing_bytes().as_slice())
            || !context.matches(binding)
            || controller_is_peer == host_is_peer
            || !authorization_matches
        {
            self.fail_closed();
            return Err(SecurityError::SessionMismatch);
        }
        if let Err(error) = binding.validate(active.granted_permissions, now_unix_ms) {
            self.fail_closed();
            return Err(error);
        }
        self.phase = TrustedSecurityPhase::Authorized;
        Ok(active.granted_permissions)
    }

    #[must_use]
    pub fn authorized_permissions(&self) -> Option<PermissionSet> {
        (self.phase == TrustedSecurityPhase::Authorized)
            .then(|| {
                self.active
                    .as_ref()
                    .map(|active| active.granted_permissions)
            })
            .flatten()
    }

    pub fn revoke(&mut self, grant_id: [u8; 16]) {
        self.revoked_grants.insert(grant_id);
        self.verifier.revoke(grant_id);
        if self
            .active
            .as_ref()
            .and_then(|active| active.grant_id)
            .is_some_and(|active| active == grant_id)
        {
            self.fail_closed();
        }
    }

    pub fn end_session(&mut self) {
        self.active = None;
        self.phase = TrustedSecurityPhase::Idle;
    }

    fn advance_after_authentication_inputs(&mut self) {
        let ready = self
            .active
            .as_ref()
            .filter(|active| active.peer_proof_verified && active.grant_id.is_some());
        if matches!(
            self.phase,
            TrustedSecurityPhase::Authenticating | TrustedSecurityPhase::AwaitingHostAuthorization
        ) && ready.is_some()
        {
            self.phase = if ready.is_some_and(|active| active.granted_permissions.bits() == 0) {
                TrustedSecurityPhase::AwaitingHostAuthorization
            } else {
                TrustedSecurityPhase::AwaitingWebRtcBinding
            };
        }
    }

    fn fail_closed(&mut self) {
        self.active = None;
        self.phase = TrustedSecurityPhase::Failed;
    }
}

impl EnvelopeVerifier {
    #[must_use]
    pub fn new(local_root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES]) -> Self {
        Self {
            local_root_fingerprint,
            last_sequence_by_session: BTreeMap::new(),
            consumed_nonces: BTreeMap::new(),
            revoked_grants: BTreeSet::new(),
            maximum_nonces: 4_096,
            time_policy: TrustedTimePolicy::default(),
        }
    }

    pub fn verify(
        &mut self,
        envelope: &SignedPeerEnvelope,
        sender_root_public_key_sec1: &[u8],
        sender_authentication_certificate: &AuthenticationKeyCertificate,
        expected_sender_root_fingerprint: &[u8; ROOT_FINGERPRINT_BYTES],
        now_unix_ms: u64,
    ) -> Result<(), SecurityError> {
        self.prune_nonces(now_unix_ms);
        if envelope.session_id.is_empty()
            || envelope.session_id.len() > MAX_SESSION_ID_BYTES
            || envelope.payload.len() > MAX_SIGNED_PAYLOAD_BYTES
            || envelope.signature_der.is_empty()
            || envelope.signature_der.len() > MAX_DER_SIGNATURE_BYTES
        {
            return Err(SecurityError::InvalidMessage);
        }
        if envelope.protocol_version != 1 {
            return Err(SecurityError::UnsupportedVersion);
        }
        if envelope.recipient_root_fingerprint != self.local_root_fingerprint {
            return Err(SecurityError::WrongRecipient);
        }
        if &envelope.sender_root_fingerprint != expected_sender_root_fingerprint
            || sender_authentication_certificate.root_fingerprint
                != *expected_sender_root_fingerprint
        {
            return Err(SecurityError::FingerprintMismatch);
        }
        sender_authentication_certificate.validate_with_policy(
            sender_root_public_key_sec1,
            now_unix_ms,
            self.time_policy,
        )?;
        if envelope.expires_at_unix_ms <= envelope.issued_at_unix_ms
            || envelope.expires_at_unix_ms - envelope.issued_at_unix_ms
                > DEFAULT_SESSION_TICKET_LIFETIME_MS
        {
            return Err(SecurityError::LifetimeExceeded);
        }
        self.time_policy
            .validate_not_before(envelope.issued_at_unix_ms, now_unix_ms)?;
        if now_unix_ms >= envelope.expires_at_unix_ms {
            return Err(SecurityError::Expired);
        }
        if self.consumed_nonces.contains_key(&envelope.nonce) {
            return Err(SecurityError::Replay);
        }
        let sequence_key = (
            envelope.session_id.clone(),
            envelope.sender_root_fingerprint,
        );
        if self
            .last_sequence_by_session
            .get(&sequence_key)
            .is_some_and(|last| envelope.sequence <= *last)
        {
            return Err(SecurityError::SequenceRollback);
        }
        verify_p256_signature_der(
            &sender_authentication_certificate.authentication_public_key_sec1,
            &envelope.signing_bytes(),
            &envelope.signature_der,
        )?;
        if self.consumed_nonces.len() >= self.maximum_nonces {
            return Err(SecurityError::ReplayCacheFull);
        }
        self.last_sequence_by_session
            .insert(sequence_key, envelope.sequence);
        self.consumed_nonces
            .insert(envelope.nonce, envelope.expires_at_unix_ms);
        Ok(())
    }

    pub fn revoke(&mut self, grant_id: [u8; 16]) {
        self.revoked_grants.insert(grant_id);
    }

    #[must_use]
    pub fn is_revoked(&self, grant_id: &[u8; 16]) -> bool {
        self.revoked_grants.contains(grant_id)
    }

    fn prune_nonces(&mut self, now_unix_ms: u64) {
        self.consumed_nonces
            .retain(|_, expires_at| *expires_at > now_unix_ms);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SecurityError {
    UnsupportedVersion,
    InvalidKey,
    InvalidSignature,
    FingerprintMismatch,
    WrongRecipient,
    NotYetValid,
    Expired,
    SoftExpired,
    HardExpired,
    LifetimeExceeded,
    Replay,
    SequenceRollback,
    PermissionDenied,
    InvalidMessage,
    ReplayCacheFull,
    InvalidState,
    Paused,
    Revoked,
    SessionMismatch,
}

pub fn root_fingerprint(
    root_public_key_sec1: &[u8],
) -> Result<[u8; ROOT_FINGERPRINT_BYTES], SecurityError> {
    let key = VerifyingKey::from_sec1_bytes(root_public_key_sec1)
        .map_err(|_| SecurityError::InvalidKey)?;
    let canonical = key.to_encoded_point(false);
    Ok(Sha256::digest(canonical.as_bytes()).into())
}

fn validate_p256_public_key(public_key_sec1: &[u8]) -> Result<(), SecurityError> {
    if public_key_sec1.len() != P256_UNCOMPRESSED_PUBLIC_KEY_BYTES
        || public_key_sec1.first() != Some(&0x04)
    {
        return Err(SecurityError::InvalidKey);
    }
    VerifyingKey::from_sec1_bytes(public_key_sec1)
        .map(|_| ())
        .map_err(|_| SecurityError::InvalidKey)
}

pub fn machine_code_v2(root_public_key_sec1: &[u8]) -> Result<String, SecurityError> {
    let fingerprint = root_fingerprint(root_public_key_sec1)?;
    let mut material = [0_u8; 13];
    material[..12].copy_from_slice(&fingerprint[..12]);
    material[12] = Sha256::digest(fingerprint)[0];
    let encoded = crockford_base32(&material);
    let groups = encoded
        .as_bytes()
        .chunks(4)
        .map(|chunk| std::str::from_utf8(chunk).expect("alphabet is ASCII"))
        .collect::<Vec<_>>();
    Ok(format!("CDR2-{}", groups.join("-")))
}

pub fn validate_device_identity(
    machine_code: &str,
    root_public_key_sec1: &[u8],
    expected_root_fingerprint: &[u8; ROOT_FINGERPRINT_BYTES],
    authentication_certificate: &AuthenticationKeyCertificate,
    now_unix_ms: u64,
) -> Result<(), SecurityError> {
    let actual_fingerprint = root_fingerprint(root_public_key_sec1)?;
    if actual_fingerprint != *expected_root_fingerprint
        || authentication_certificate.root_fingerprint != *expected_root_fingerprint
        || machine_code_v2(root_public_key_sec1)? != machine_code
    {
        return Err(SecurityError::FingerprintMismatch);
    }
    authentication_certificate.validate_with_policy(
        root_public_key_sec1,
        now_unix_ms,
        TrustedTimePolicy::default(),
    )
}

pub fn verify_p256_signature_der(
    public_key_sec1: &[u8],
    message: &[u8],
    signature_der: &[u8],
) -> Result<(), SecurityError> {
    let key =
        VerifyingKey::from_sec1_bytes(public_key_sec1).map_err(|_| SecurityError::InvalidKey)?;
    let signature =
        Signature::from_der(signature_der).map_err(|_| SecurityError::InvalidSignature)?;
    key.verify(message, &signature)
        .map_err(|_| SecurityError::InvalidSignature)
}

pub fn sas_code(
    first_root_public_key_sec1: &[u8],
    second_root_public_key_sec1: &[u8],
    session_nonce: &[u8],
) -> Result<String, SecurityError> {
    if session_nonce.len() < NONCE_BYTES {
        return Err(SecurityError::InvalidMessage);
    }
    let first = root_fingerprint(first_root_public_key_sec1)?;
    let second = root_fingerprint(second_root_public_key_sec1)?;
    let (lower, upper) = if first <= second {
        (first, second)
    } else {
        (second, first)
    };
    let mut digest = Sha256::new();
    digest.update(b"CrossDesktopRemote/SAS/v1");
    digest.update(lower);
    digest.update(upper);
    digest.update(session_nonce);
    let digest = digest.finalize();
    let value = u32::from_be_bytes(digest[..4].try_into().expect("fixed digest")) % 1_000_000;
    Ok(format!("{value:06}"))
}

fn append_domain(output: &mut Vec<u8>, domain: &[u8]) {
    append_bytes(output, domain);
}

fn append_bytes(output: &mut Vec<u8>, value: &[u8]) {
    output.extend_from_slice(&(value.len() as u32).to_be_bytes());
    output.extend_from_slice(value);
}

fn crockford_base32(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    let mut buffer: u32 = 0;
    let mut bits = 0_u8;
    let mut output = String::new();
    for byte in bytes {
        buffer = (buffer << 8) | u32::from(*byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            output.push(ALPHABET[((buffer >> bits) & 31) as usize] as char);
        }
    }
    if bits > 0 {
        output.push(ALPHABET[((buffer << (5 - bits)) & 31) as usize] as char);
    }
    output
}

#[cfg(test)]
mod tests {
    use p256::ecdsa::{SigningKey, signature::Signer};

    use super::*;

    fn key(byte: u8) -> SigningKey {
        SigningKey::from_bytes((&[byte; 32]).into()).expect("test key")
    }

    fn authentication_certificate(
        root: &SigningKey,
        authentication: &SigningKey,
        root_fingerprint: [u8; ROOT_FINGERPRINT_BYTES],
    ) -> AuthenticationKeyCertificate {
        let mut certificate = AuthenticationKeyCertificate {
            root_fingerprint,
            authentication_public_key_sec1: authentication
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec(),
            not_before_unix_ms: 1_000,
            expires_at_unix_ms: 1_000 + DEFAULT_AUTH_KEY_LIFETIME_MS,
            root_signature_der: Vec::new(),
        };
        let signature: Signature = root.sign(&certificate.signing_bytes());
        certificate.root_signature_der = signature.to_der().as_bytes().to_vec();
        certificate
    }

    struct EnvelopeContext<'a> {
        session_id: &'a str,
        sender: [u8; ROOT_FINGERPRINT_BYTES],
        recipient: [u8; ROOT_FINGERPRINT_BYTES],
        sequence: u64,
        nonce: [u8; NONCE_BYTES],
        payload: Vec<u8>,
    }

    fn signed_envelope(
        authentication: &SigningKey,
        context: EnvelopeContext<'_>,
    ) -> SignedPeerEnvelope {
        let mut envelope = SignedPeerEnvelope {
            protocol_version: 1,
            session_id: context.session_id.into(),
            sender_root_fingerprint: context.sender,
            recipient_root_fingerprint: context.recipient,
            sequence: context.sequence,
            issued_at_unix_ms: 2_000 + context.sequence * 1_000,
            expires_at_unix_ms: 55_000,
            nonce: context.nonce,
            payload: context.payload,
            signature_der: Vec::new(),
        };
        let signature: Signature = authentication.sign(&envelope.signing_bytes());
        envelope.signature_der = signature.to_der().as_bytes().to_vec();
        envelope
    }

    #[test]
    fn permissions_are_independent_and_intersected() {
        let allowed = PermissionSet::default()
            .grant(SessionPermission::ViewScreen)
            .grant(SessionPermission::ReadClipboard);
        let requested = PermissionSet::default()
            .grant(SessionPermission::ViewScreen)
            .grant(SessionPermission::ControlInput);

        assert!(allowed.contains(SessionPermission::ViewScreen));
        assert_eq!(
            allowed.intersection(requested),
            PermissionSet::default().grant(SessionPermission::ViewScreen)
        );
        assert!(!requested.is_subset_of(allowed));
    }

    #[test]
    fn host_session_authorization_requires_directional_frozen_permissions() {
        let authorization = TrustedSessionAuthorization {
            protocol_version: 1,
            session_id: "policy-session".into(),
            credential_id: [1; 16],
            policy_revision: 3,
            permissions: PermissionSet::default()
                .grant(SessionPermission::ViewScreen)
                .grant(SessionPermission::UploadFilesToHost),
            controller_root_fingerprint: [2; ROOT_FINGERPRINT_BYTES],
            host_root_fingerprint: [3; ROOT_FINGERPRINT_BYTES],
            controller_nonce: [4; NONCE_BYTES],
            host_nonce: [5; NONCE_BYTES],
            issued_at_unix_ms: 1_000,
            expires_at_unix_ms: 46_000,
            auth_suite_version: TRUSTED_AUTH_SUITE_V2,
            capability_sha256: [6; ROOT_FINGERPRINT_BYTES],
        };

        assert_eq!(authorization.validate_time(2_000), Ok(()));
        assert_eq!(
            authorization.validate_time(46_000),
            Err(SecurityError::Expired)
        );
        let legacy = TrustedSessionAuthorization {
            permissions: PermissionSet::default()
                .grant(SessionPermission::ViewScreen)
                .grant(SessionPermission::TransferFiles),
            ..authorization
        };
        assert_eq!(
            legacy.validate_time(2_000),
            Err(SecurityError::InvalidMessage)
        );
    }

    #[test]
    fn machine_code_is_stable_and_checksummed() {
        let public = key(7).verifying_key().to_encoded_point(false);
        let first = machine_code_v2(public.as_bytes()).expect("machine code");
        let second = machine_code_v2(public.as_bytes()).expect("machine code");

        assert_eq!(first, second);
        assert!(first.starts_with("CDR2-"));
        assert_eq!(first.split('-').count(), 7);
    }

    #[test]
    fn verifies_grant_signature_permission_and_expiry() {
        let issuer = key(11);
        let subject = key(12);
        let issuer_public = issuer.verifying_key().to_encoded_point(false);
        let subject_fingerprint =
            root_fingerprint(subject.verifying_key().to_encoded_point(false).as_bytes())
                .expect("subject fingerprint");
        let mut grant = TrustGrant {
            grant_id: [3; 16],
            issuer_root_fingerprint: root_fingerprint(issuer_public.as_bytes())
                .expect("issuer fingerprint"),
            subject_root_fingerprint: subject_fingerprint,
            permissions: PermissionSet::default()
                .grant(SessionPermission::ViewScreen)
                .grant(SessionPermission::ControlInput),
            issued_at_unix_ms: 1_000,
            soft_expires_at_unix_ms: 10_000,
            hard_expires_at_unix_ms: 20_000,
            automatic_renewal: true,
            issuer_signature_der: Vec::new(),
        };
        let signature: Signature = issuer.sign(&grant.signing_bytes());
        grant.issuer_signature_der = signature.to_der().as_bytes().to_vec();

        let requested = PermissionSet::default().grant(SessionPermission::ViewScreen);
        assert_eq!(
            grant.validate(
                issuer_public.as_bytes(),
                &subject_fingerprint,
                requested,
                5_000
            ),
            Ok(requested)
        );
        assert_eq!(
            grant.validate(
                issuer_public.as_bytes(),
                &subject_fingerprint,
                requested,
                10_000
            ),
            Err(SecurityError::SoftExpired)
        );
    }

    #[test]
    fn time_policy_tolerates_only_bounded_future_start_times() {
        let issuer = key(13);
        let issuer_public = issuer.verifying_key().to_encoded_point(false);
        let issuer_fingerprint =
            root_fingerprint(issuer_public.as_bytes()).expect("issuer fingerprint");
        let subject_fingerprint = [17_u8; ROOT_FINGERPRINT_BYTES];
        let requested = PermissionSet::default().grant(SessionPermission::ViewScreen);
        let issued_at = 100_000;
        let mut grant = TrustGrant {
            grant_id: [19; 16],
            issuer_root_fingerprint: issuer_fingerprint,
            subject_root_fingerprint: subject_fingerprint,
            permissions: requested,
            issued_at_unix_ms: issued_at,
            soft_expires_at_unix_ms: issued_at + DEFAULT_TRUST_SOFT_LIFETIME_MS,
            hard_expires_at_unix_ms: issued_at + DEFAULT_TRUST_HARD_LIFETIME_MS,
            automatic_renewal: true,
            issuer_signature_der: Vec::new(),
        };
        let signature: Signature = issuer.sign(&grant.signing_bytes());
        grant.issuer_signature_der = signature.to_der().as_bytes().to_vec();

        assert_eq!(
            grant.validate(
                issuer_public.as_bytes(),
                &subject_fingerprint,
                requested,
                issued_at - DEFAULT_MAXIMUM_CLOCK_SKEW_MS,
            ),
            Ok(requested)
        );
        assert_eq!(
            grant.validate(
                issuer_public.as_bytes(),
                &subject_fingerprint,
                requested,
                issued_at - DEFAULT_MAXIMUM_CLOCK_SKEW_MS - 1,
            ),
            Err(SecurityError::NotYetValid)
        );
        assert_eq!(
            grant.validate(
                issuer_public.as_bytes(),
                &subject_fingerprint,
                requested,
                grant.soft_expires_at_unix_ms,
            ),
            Err(SecurityError::SoftExpired)
        );

        let authentication = key(14);
        let mut certificate = AuthenticationKeyCertificate {
            root_fingerprint: issuer_fingerprint,
            authentication_public_key_sec1: authentication
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec(),
            not_before_unix_ms: issued_at,
            expires_at_unix_ms: issued_at + DEFAULT_AUTH_KEY_LIFETIME_MS,
            root_signature_der: Vec::new(),
        };
        let signature: Signature = issuer.sign(&certificate.signing_bytes());
        certificate.root_signature_der = signature.to_der().as_bytes().to_vec();
        assert_eq!(
            certificate.validate(
                issuer_public.as_bytes(),
                issued_at - DEFAULT_MAXIMUM_CLOCK_SKEW_MS,
            ),
            Ok(())
        );
        assert_eq!(
            certificate.validate(
                issuer_public.as_bytes(),
                issued_at - DEFAULT_MAXIMUM_CLOCK_SKEW_MS - 1,
            ),
            Err(SecurityError::NotYetValid)
        );
        assert_eq!(
            certificate.validate(issuer_public.as_bytes(), certificate.expires_at_unix_ms),
            Err(SecurityError::Expired)
        );
    }

    #[test]
    fn rejects_replayed_envelopes() {
        let sender = key(21);
        let sender_authentication = key(23);
        let recipient = key(22);
        let sender_public = sender.verifying_key().to_encoded_point(false);
        let sender_fingerprint =
            root_fingerprint(sender_public.as_bytes()).expect("sender fingerprint");
        let recipient_fingerprint =
            root_fingerprint(recipient.verifying_key().to_encoded_point(false).as_bytes())
                .expect("recipient fingerprint");
        let mut certificate = AuthenticationKeyCertificate {
            root_fingerprint: sender_fingerprint,
            authentication_public_key_sec1: sender_authentication
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec(),
            not_before_unix_ms: 1_000,
            expires_at_unix_ms: 1_000 + DEFAULT_AUTH_KEY_LIFETIME_MS,
            root_signature_der: Vec::new(),
        };
        let certificate_signature: Signature = sender.sign(&certificate.signing_bytes());
        certificate.root_signature_der = certificate_signature.to_der().as_bytes().to_vec();
        let mut envelope = SignedPeerEnvelope {
            protocol_version: 1,
            session_id: "session-1".into(),
            sender_root_fingerprint: sender_fingerprint,
            recipient_root_fingerprint: recipient_fingerprint,
            sequence: 1,
            issued_at_unix_ms: 5_000,
            expires_at_unix_ms: 55_000,
            nonce: [9; NONCE_BYTES],
            payload: b"challenge-response".to_vec(),
            signature_der: Vec::new(),
        };
        let signature: Signature = sender_authentication.sign(&envelope.signing_bytes());
        envelope.signature_der = signature.to_der().as_bytes().to_vec();
        let mut verifier = EnvelopeVerifier::new(recipient_fingerprint);

        assert_eq!(
            verifier.verify(
                &envelope,
                sender_public.as_bytes(),
                &certificate,
                &sender_fingerprint,
                6_000,
            ),
            Ok(())
        );
        assert_eq!(
            verifier.verify(
                &envelope,
                sender_public.as_bytes(),
                &certificate,
                &sender_fingerprint,
                6_001,
            ),
            Err(SecurityError::Replay)
        );
    }

    #[test]
    fn sas_is_symmetric() {
        let first = key(31).verifying_key().to_encoded_point(false);
        let second = key(32).verifying_key().to_encoded_point(false);

        assert_eq!(
            sas_code(first.as_bytes(), second.as_bytes(), b"pairing-session!").expect("first SAS"),
            sas_code(second.as_bytes(), first.as_bytes(), b"pairing-session!").expect("second SAS")
        );
    }

    #[test]
    fn trusted_engine_requires_envelope_grant_and_media_binding_in_order() {
        let host = key(41);
        let controller = key(42);
        let controller_authentication = key(43);
        let host_authentication = key(44);
        let host_public = host.verifying_key().to_encoded_point(false);
        let controller_public = controller.verifying_key().to_encoded_point(false);
        let host_fingerprint = root_fingerprint(host_public.as_bytes()).expect("host fingerprint");
        let controller_fingerprint =
            root_fingerprint(controller_public.as_bytes()).expect("controller fingerprint");
        let requested = PermissionSet::default()
            .grant(SessionPermission::ViewScreen)
            .grant(SessionPermission::ControlInput);
        let mut engine = TrustedSecurityEngine::new(host_fingerprint);
        engine
            .begin_session(
                "trusted-session".into(),
                controller_fingerprint,
                requested,
                TrustedSessionMode::TrustedAuthentication,
            )
            .expect("begin session");

        let binding = TrustedSessionBinding {
            session_id: "trusted-session".into(),
            controller_nonce: [1; NONCE_BYTES],
            host_nonce: [2; NONCE_BYTES],
            requested_permissions: requested,
            controller_ephemeral_public_key: controller_authentication
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec(),
            host_ephemeral_public_key: host_authentication
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec(),
            offer_sha256: [3; ROOT_FINGERPRINT_BYTES],
            answer_sha256: [4; ROOT_FINGERPRINT_BYTES],
            controller_dtls_fingerprint_sha256: [5; ROOT_FINGERPRINT_BYTES],
            host_dtls_fingerprint_sha256: [6; ROOT_FINGERPRINT_BYTES],
            expires_at_unix_ms: 55_000,
            auth_suite_version: TRUSTED_AUTH_SUITE_LEGACY,
            authorization_sha256: [0; ROOT_FINGERPRINT_BYTES],
            capability_sha256: [0; ROOT_FINGERPRINT_BYTES],
        };

        let mut certificate = AuthenticationKeyCertificate {
            root_fingerprint: controller_fingerprint,
            authentication_public_key_sec1: controller_authentication
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec(),
            not_before_unix_ms: 1_000,
            expires_at_unix_ms: 1_000 + DEFAULT_AUTH_KEY_LIFETIME_MS,
            root_signature_der: Vec::new(),
        };
        let certificate_signature: Signature = controller.sign(&certificate.signing_bytes());
        certificate.root_signature_der = certificate_signature.to_der().as_bytes().to_vec();
        let mut envelope = SignedPeerEnvelope {
            protocol_version: 1,
            session_id: "trusted-session".into(),
            sender_root_fingerprint: controller_fingerprint,
            recipient_root_fingerprint: host_fingerprint,
            sequence: 1,
            issued_at_unix_ms: 2_000,
            expires_at_unix_ms: 50_000,
            nonce: [7; NONCE_BYTES],
            payload: binding.signing_bytes(),
            signature_der: Vec::new(),
        };
        let envelope_signature: Signature =
            controller_authentication.sign(&envelope.signing_bytes());
        envelope.signature_der = envelope_signature.to_der().as_bytes().to_vec();
        engine
            .verify_envelope(&envelope, controller_public.as_bytes(), &certificate, 3_000)
            .expect("envelope");

        let mut grant = TrustGrant {
            grant_id: [8; 16],
            issuer_root_fingerprint: host_fingerprint,
            subject_root_fingerprint: controller_fingerprint,
            permissions: requested,
            issued_at_unix_ms: 1_000,
            soft_expires_at_unix_ms: 10_000,
            hard_expires_at_unix_ms: 20_000,
            automatic_renewal: true,
            issuer_signature_der: Vec::new(),
        };
        let grant_signature: Signature = host.sign(&grant.signing_bytes());
        grant.issuer_signature_der = grant_signature.to_der().as_bytes().to_vec();
        assert_eq!(
            engine
                .authorize_grant(
                    &grant,
                    host_public.as_bytes(),
                    &controller_fingerprint,
                    4_000,
                )
                .expect("grant"),
            requested
        );
        engine
            .configure_webrtc_context(
                binding.controller_nonce,
                binding.host_nonce,
                binding.controller_ephemeral_public_key.clone(),
                binding.host_ephemeral_public_key.clone(),
            )
            .expect("freeze WebRTC context");

        assert_eq!(
            engine.bind_webrtc(&binding, 5_000).expect("binding"),
            requested
        );
        assert_eq!(engine.phase(), TrustedSecurityPhase::Authorized);
        assert_eq!(engine.authorized_permissions(), Some(requested));

        let rotated_authentication = key(45);
        let mut rotated_certificate = AuthenticationKeyCertificate {
            root_fingerprint: controller_fingerprint,
            authentication_public_key_sec1: rotated_authentication
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec(),
            not_before_unix_ms: 1_000,
            expires_at_unix_ms: 1_000 + DEFAULT_AUTH_KEY_LIFETIME_MS,
            root_signature_der: Vec::new(),
        };
        let certificate_signature: Signature =
            controller.sign(&rotated_certificate.signing_bytes());
        rotated_certificate.root_signature_der = certificate_signature.to_der().as_bytes().to_vec();
        let mut rotated_envelope = SignedPeerEnvelope {
            protocol_version: 1,
            session_id: "trusted-session".into(),
            sender_root_fingerprint: controller_fingerprint,
            recipient_root_fingerprint: host_fingerprint,
            sequence: 2,
            issued_at_unix_ms: 6_000,
            expires_at_unix_ms: 50_000,
            nonce: [9; NONCE_BYTES],
            payload: binding.signing_bytes(),
            signature_der: Vec::new(),
        };
        let envelope_signature: Signature =
            rotated_authentication.sign(&rotated_envelope.signing_bytes());
        rotated_envelope.signature_der = envelope_signature.to_der().as_bytes().to_vec();
        assert_eq!(
            engine.verify_envelope(
                &rotated_envelope,
                controller_public.as_bytes(),
                &rotated_certificate,
                7_000,
            ),
            Err(SecurityError::SessionMismatch)
        );
        assert_eq!(engine.phase(), TrustedSecurityPhase::Failed);
    }

    #[test]
    fn controller_accepts_only_host_signed_session_policy_before_media() {
        let host = key(71);
        let controller = key(72);
        let host_authentication = key(73);
        let controller_authentication = key(74);
        let host_public = host.verifying_key().to_encoded_point(false);
        let controller_public = controller.verifying_key().to_encoded_point(false);
        let host_fingerprint = root_fingerprint(host_public.as_bytes()).expect("host fingerprint");
        let controller_fingerprint =
            root_fingerprint(controller_public.as_bytes()).expect("controller fingerprint");
        let identity_scope = PermissionSet::default().grant(SessionPermission::ViewScreen);
        let policy_permissions = identity_scope
            .grant(SessionPermission::ControlInput)
            .grant(SessionPermission::DownloadFilesFromHost);
        let controller_nonce = [1; NONCE_BYTES];
        let host_nonce = [2; NONCE_BYTES];
        let mut engine = TrustedSecurityEngine::new(controller_fingerprint);
        engine
            .begin_session(
                "host-policy-session".into(),
                host_fingerprint,
                identity_scope,
                TrustedSessionMode::TrustedAuthentication,
            )
            .expect("begin session");
        engine
            .configure_webrtc_context(
                controller_nonce,
                host_nonce,
                controller_authentication
                    .verifying_key()
                    .to_encoded_point(false)
                    .as_bytes()
                    .to_vec(),
                host_authentication
                    .verifying_key()
                    .to_encoded_point(false)
                    .as_bytes()
                    .to_vec(),
            )
            .expect("freeze WebRTC context");

        let mut host_certificate = AuthenticationKeyCertificate {
            root_fingerprint: host_fingerprint,
            authentication_public_key_sec1: host_authentication
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec(),
            not_before_unix_ms: 1_000,
            expires_at_unix_ms: 1_000 + DEFAULT_AUTH_KEY_LIFETIME_MS,
            root_signature_der: Vec::new(),
        };
        let certificate_signature: Signature = host.sign(&host_certificate.signing_bytes());
        host_certificate.root_signature_der = certificate_signature.to_der().as_bytes().to_vec();
        let mut challenge = SignedPeerEnvelope {
            protocol_version: 1,
            session_id: "host-policy-session".into(),
            sender_root_fingerprint: host_fingerprint,
            recipient_root_fingerprint: controller_fingerprint,
            sequence: 1,
            issued_at_unix_ms: 2_000,
            expires_at_unix_ms: 50_000,
            nonce: [3; NONCE_BYTES],
            payload: b"host-challenge".to_vec(),
            signature_der: Vec::new(),
        };
        let challenge_signature: Signature = host_authentication.sign(&challenge.signing_bytes());
        challenge.signature_der = challenge_signature.to_der().as_bytes().to_vec();
        engine
            .verify_envelope(&challenge, host_public.as_bytes(), &host_certificate, 3_000)
            .expect("host proof");

        let mut credential = TrustGrant {
            grant_id: [4; 16],
            issuer_root_fingerprint: host_fingerprint,
            subject_root_fingerprint: controller_fingerprint,
            permissions: identity_scope,
            issued_at_unix_ms: 1_000,
            soft_expires_at_unix_ms: 10_000,
            hard_expires_at_unix_ms: 20_000,
            automatic_renewal: true,
            issuer_signature_der: Vec::new(),
        };
        let credential_signature: Signature = host.sign(&credential.signing_bytes());
        credential.issuer_signature_der = credential_signature.to_der().as_bytes().to_vec();
        engine
            .authenticate_credential(
                &credential,
                host_public.as_bytes(),
                &controller_fingerprint,
                4_000,
            )
            .expect("identity credential");
        assert_eq!(
            engine.phase(),
            TrustedSecurityPhase::AwaitingHostAuthorization
        );

        let authorization = TrustedSessionAuthorization {
            protocol_version: 1,
            session_id: "host-policy-session".into(),
            credential_id: credential.grant_id,
            policy_revision: 7,
            permissions: policy_permissions,
            controller_root_fingerprint: controller_fingerprint,
            host_root_fingerprint: host_fingerprint,
            controller_nonce,
            host_nonce,
            issued_at_unix_ms: 4_000,
            expires_at_unix_ms: 49_000,
            auth_suite_version: TRUSTED_AUTH_SUITE_V2,
            capability_sha256: [11; ROOT_FINGERPRINT_BYTES],
        };
        let mut policy_envelope = SignedPeerEnvelope {
            protocol_version: 1,
            session_id: "host-policy-session".into(),
            sender_root_fingerprint: host_fingerprint,
            recipient_root_fingerprint: controller_fingerprint,
            sequence: 2,
            issued_at_unix_ms: 4_000,
            expires_at_unix_ms: 50_000,
            nonce: [5; NONCE_BYTES],
            payload: authorization.signing_bytes(),
            signature_der: Vec::new(),
        };
        let policy_signature: Signature =
            host_authentication.sign(&policy_envelope.signing_bytes());
        policy_envelope.signature_der = policy_signature.to_der().as_bytes().to_vec();
        engine
            .verify_envelope(
                &policy_envelope,
                host_public.as_bytes(),
                &host_certificate,
                5_000,
            )
            .expect("signed host policy");
        assert_eq!(
            engine
                .accept_host_authorization(&authorization, 5_000)
                .expect("accept policy"),
            policy_permissions
        );

        let authorization_sha256: [u8; ROOT_FINGERPRINT_BYTES] =
            Sha256::digest(authorization.signing_bytes()).into();
        let binding = TrustedSessionBinding {
            session_id: "host-policy-session".into(),
            controller_nonce,
            host_nonce,
            requested_permissions: policy_permissions,
            controller_ephemeral_public_key: controller_authentication
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec(),
            host_ephemeral_public_key: host_authentication
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec(),
            offer_sha256: [6; ROOT_FINGERPRINT_BYTES],
            answer_sha256: [7; ROOT_FINGERPRINT_BYTES],
            controller_dtls_fingerprint_sha256: [8; ROOT_FINGERPRINT_BYTES],
            host_dtls_fingerprint_sha256: [9; ROOT_FINGERPRINT_BYTES],
            expires_at_unix_ms: 50_000,
            auth_suite_version: TRUSTED_AUTH_SUITE_V2,
            authorization_sha256,
            capability_sha256: authorization.capability_sha256,
        };
        let mut offer_envelope = SignedPeerEnvelope {
            protocol_version: 1,
            session_id: "host-policy-session".into(),
            sender_root_fingerprint: host_fingerprint,
            recipient_root_fingerprint: controller_fingerprint,
            sequence: 3,
            issued_at_unix_ms: 5_000,
            expires_at_unix_ms: 50_000,
            nonce: [10; NONCE_BYTES],
            payload: binding.signing_bytes(),
            signature_der: Vec::new(),
        };
        let offer_signature: Signature = host_authentication.sign(&offer_envelope.signing_bytes());
        offer_envelope.signature_der = offer_signature.to_der().as_bytes().to_vec();
        engine
            .verify_envelope(
                &offer_envelope,
                host_public.as_bytes(),
                &host_certificate,
                5_500,
            )
            .expect("signed media offer");
        assert_eq!(
            engine.bind_webrtc(&binding, 6_000).expect("media binding"),
            policy_permissions
        );
        assert_eq!(engine.phase(), TrustedSecurityPhase::Authorized);
    }

    #[test]
    fn suite_v2_requires_controller_authorization_ack_before_media() {
        let host_root = key(81);
        let controller_root = key(82);
        let host_authentication = key(83);
        let controller_authentication = key(84);
        let host_public = host_root.verifying_key().to_encoded_point(false);
        let controller_public = controller_root.verifying_key().to_encoded_point(false);
        let host_fingerprint = root_fingerprint(host_public.as_bytes()).expect("host fingerprint");
        let controller_fingerprint =
            root_fingerprint(controller_public.as_bytes()).expect("controller fingerprint");
        let host_certificate =
            authentication_certificate(&host_root, &host_authentication, host_fingerprint);
        let controller_certificate = authentication_certificate(
            &controller_root,
            &controller_authentication,
            controller_fingerprint,
        );
        let identity_scope = PermissionSet::default().grant(SessionPermission::ViewScreen);
        let policy_permissions = identity_scope
            .grant(SessionPermission::ControlInput)
            .grant(SessionPermission::UploadFilesToHost)
            .grant(SessionPermission::DownloadFilesFromHost);
        let controller_nonce = [1; NONCE_BYTES];
        let host_nonce = [2; NONCE_BYTES];
        let capability_sha256 = [12; ROOT_FINGERPRINT_BYTES];
        let mut host = TrustedSecurityEngine::new(host_fingerprint);
        let mut controller = TrustedSecurityEngine::new(controller_fingerprint);
        for (engine, peer) in [
            (&mut host, controller_fingerprint),
            (&mut controller, host_fingerprint),
        ] {
            engine
                .begin_session(
                    "suite-v2-session".into(),
                    peer,
                    identity_scope,
                    TrustedSessionMode::TrustedAuthentication,
                )
                .expect("begin session");
            engine
                .configure_webrtc_context(
                    controller_nonce,
                    host_nonce,
                    controller_authentication
                        .verifying_key()
                        .to_encoded_point(false)
                        .as_bytes()
                        .to_vec(),
                    host_authentication
                        .verifying_key()
                        .to_encoded_point(false)
                        .as_bytes()
                        .to_vec(),
                )
                .expect("freeze WebRTC context");
        }

        let host_proof = signed_envelope(
            &host_authentication,
            EnvelopeContext {
                session_id: "suite-v2-session",
                sender: host_fingerprint,
                recipient: controller_fingerprint,
                sequence: 1,
                nonce: [3; NONCE_BYTES],
                payload: b"host-proof".to_vec(),
            },
        );
        controller
            .verify_envelope(
                &host_proof,
                host_public.as_bytes(),
                &host_certificate,
                4_000,
            )
            .expect("verify host proof");
        let controller_proof = signed_envelope(
            &controller_authentication,
            EnvelopeContext {
                session_id: "suite-v2-session",
                sender: controller_fingerprint,
                recipient: host_fingerprint,
                sequence: 1,
                nonce: [4; NONCE_BYTES],
                payload: b"controller-proof".to_vec(),
            },
        );
        host.verify_envelope(
            &controller_proof,
            controller_public.as_bytes(),
            &controller_certificate,
            4_000,
        )
        .expect("verify controller proof");

        let mut credential = TrustGrant {
            grant_id: [5; 16],
            issuer_root_fingerprint: host_fingerprint,
            subject_root_fingerprint: controller_fingerprint,
            permissions: identity_scope,
            issued_at_unix_ms: 1_000,
            soft_expires_at_unix_ms: 30_000,
            hard_expires_at_unix_ms: 60_000,
            automatic_renewal: true,
            issuer_signature_der: Vec::new(),
        };
        let signature: Signature = host_root.sign(&credential.signing_bytes());
        credential.issuer_signature_der = signature.to_der().as_bytes().to_vec();
        for engine in [&mut host, &mut controller] {
            engine
                .authenticate_credential(
                    &credential,
                    host_public.as_bytes(),
                    &controller_fingerprint,
                    5_000,
                )
                .expect("authenticate identity credential");
            assert_eq!(
                engine.phase(),
                TrustedSecurityPhase::AwaitingHostAuthorization
            );
        }

        let authorization = TrustedSessionAuthorization {
            protocol_version: 1,
            session_id: "suite-v2-session".into(),
            credential_id: credential.grant_id,
            policy_revision: 9,
            permissions: policy_permissions,
            controller_root_fingerprint: controller_fingerprint,
            host_root_fingerprint: host_fingerprint,
            controller_nonce,
            host_nonce,
            issued_at_unix_ms: 5_000,
            expires_at_unix_ms: 50_000,
            auth_suite_version: TRUSTED_AUTH_SUITE_V2,
            capability_sha256,
        };
        assert_eq!(
            host.install_host_authorization(&authorization, 6_000)
                .expect("install host authorization"),
            policy_permissions
        );
        assert_eq!(host.phase(), TrustedSecurityPhase::AwaitingAuthorizationAck);

        let authorization_envelope = signed_envelope(
            &host_authentication,
            EnvelopeContext {
                session_id: "suite-v2-session",
                sender: host_fingerprint,
                recipient: controller_fingerprint,
                sequence: 2,
                nonce: [6; NONCE_BYTES],
                payload: authorization.signing_bytes(),
            },
        );
        controller
            .verify_envelope(
                &authorization_envelope,
                host_public.as_bytes(),
                &host_certificate,
                6_000,
            )
            .expect("verify host authorization");
        controller
            .accept_host_authorization(&authorization, 6_000)
            .expect("accept host authorization");
        assert_eq!(
            controller.phase(),
            TrustedSecurityPhase::AwaitingWebRtcBinding
        );

        let authorization_sha256: [u8; ROOT_FINGERPRINT_BYTES] =
            Sha256::digest(authorization.signing_bytes()).into();
        let binding = TrustedSessionBinding {
            session_id: "suite-v2-session".into(),
            controller_nonce,
            host_nonce,
            requested_permissions: policy_permissions,
            controller_ephemeral_public_key: controller_authentication
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec(),
            host_ephemeral_public_key: host_authentication
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec(),
            offer_sha256: [7; ROOT_FINGERPRINT_BYTES],
            answer_sha256: [8; ROOT_FINGERPRINT_BYTES],
            controller_dtls_fingerprint_sha256: [9; ROOT_FINGERPRINT_BYTES],
            host_dtls_fingerprint_sha256: [10; ROOT_FINGERPRINT_BYTES],
            expires_at_unix_ms: 50_000,
            auth_suite_version: TRUSTED_AUTH_SUITE_V2,
            authorization_sha256,
            capability_sha256,
        };
        assert_eq!(
            host.bind_webrtc(&binding, 6_000),
            Err(SecurityError::InvalidState)
        );

        let acknowledgement = TrustedSessionAuthorizationAck {
            protocol_version: 1,
            session_id: "suite-v2-session".into(),
            authorization_sha256,
            policy_revision: authorization.policy_revision,
            permissions: policy_permissions,
            controller_root_fingerprint: controller_fingerprint,
            host_root_fingerprint: host_fingerprint,
            controller_nonce,
            host_nonce,
            issued_at_unix_ms: 6_000,
            expires_at_unix_ms: 50_000,
            auth_suite_version: TRUSTED_AUTH_SUITE_V2,
            capability_sha256,
        };
        let acknowledgement_envelope = signed_envelope(
            &controller_authentication,
            EnvelopeContext {
                session_id: "suite-v2-session",
                sender: controller_fingerprint,
                recipient: host_fingerprint,
                sequence: 2,
                nonce: [11; NONCE_BYTES],
                payload: acknowledgement.signing_bytes(),
            },
        );
        host.verify_envelope(
            &acknowledgement_envelope,
            controller_public.as_bytes(),
            &controller_certificate,
            7_000,
        )
        .expect("verify controller authorization acknowledgement");
        assert_eq!(
            host.confirm_host_authorization_ack(&acknowledgement, 7_000)
                .expect("confirm authorization acknowledgement"),
            policy_permissions
        );
        assert_eq!(host.phase(), TrustedSecurityPhase::AwaitingWebRtcBinding);

        let offer_envelope = signed_envelope(
            &host_authentication,
            EnvelopeContext {
                session_id: "suite-v2-session",
                sender: host_fingerprint,
                recipient: controller_fingerprint,
                sequence: 3,
                nonce: [12; NONCE_BYTES],
                payload: binding.signing_bytes(),
            },
        );
        controller
            .verify_envelope(
                &offer_envelope,
                host_public.as_bytes(),
                &host_certificate,
                8_000,
            )
            .expect("verify signed offer binding");
        controller
            .bind_webrtc(&binding, 8_000)
            .expect("authorize controller media");

        let answer_envelope = signed_envelope(
            &controller_authentication,
            EnvelopeContext {
                session_id: "suite-v2-session",
                sender: controller_fingerprint,
                recipient: host_fingerprint,
                sequence: 3,
                nonce: [13; NONCE_BYTES],
                payload: binding.signing_bytes(),
            },
        );
        host.verify_envelope(
            &answer_envelope,
            controller_public.as_bytes(),
            &controller_certificate,
            8_000,
        )
        .expect("verify signed answer binding");
        host.bind_webrtc(&binding, 8_000)
            .expect("authorize host media");
        assert_eq!(host.phase(), TrustedSecurityPhase::Authorized);
        assert_eq!(controller.phase(), TrustedSecurityPhase::Authorized);
    }

    #[test]
    fn trusted_engine_rejects_replacing_frozen_webrtc_context() {
        let local = key(51).verifying_key().to_encoded_point(false);
        let peer = key(52).verifying_key().to_encoded_point(false);
        let controller_authentication = key(53).verifying_key().to_encoded_point(false);
        let host_authentication = key(54).verifying_key().to_encoded_point(false);
        let mut engine = TrustedSecurityEngine::new(
            root_fingerprint(local.as_bytes()).expect("local fingerprint"),
        );
        engine
            .begin_session(
                "frozen-context".into(),
                root_fingerprint(peer.as_bytes()).expect("peer fingerprint"),
                PermissionSet::default().grant(SessionPermission::ViewScreen),
                TrustedSessionMode::TrustedAuthentication,
            )
            .expect("begin");
        engine
            .configure_webrtc_context(
                [1; NONCE_BYTES],
                [2; NONCE_BYTES],
                controller_authentication.as_bytes().to_vec(),
                host_authentication.as_bytes().to_vec(),
            )
            .expect("first context");
        engine
            .configure_webrtc_context(
                [1; NONCE_BYTES],
                [2; NONCE_BYTES],
                controller_authentication.as_bytes().to_vec(),
                host_authentication.as_bytes().to_vec(),
            )
            .expect("idempotent context");

        assert_eq!(
            engine.configure_webrtc_context(
                [3; NONCE_BYTES],
                [2; NONCE_BYTES],
                controller_authentication.as_bytes().to_vec(),
                host_authentication.as_bytes().to_vec(),
            ),
            Err(SecurityError::SessionMismatch)
        );
        assert_eq!(engine.phase(), TrustedSecurityPhase::Failed);
    }

    #[test]
    fn trusted_binding_rejects_invalid_cryptographic_material() {
        let public = key(55).verifying_key().to_encoded_point(false);
        let requested = PermissionSet::default().grant(SessionPermission::ViewScreen);
        let valid = TrustedSessionBinding {
            session_id: "binding-validation".into(),
            controller_nonce: [1; NONCE_BYTES],
            host_nonce: [2; NONCE_BYTES],
            requested_permissions: requested,
            controller_ephemeral_public_key: public.as_bytes().to_vec(),
            host_ephemeral_public_key: public.as_bytes().to_vec(),
            offer_sha256: [3; ROOT_FINGERPRINT_BYTES],
            answer_sha256: [4; ROOT_FINGERPRINT_BYTES],
            controller_dtls_fingerprint_sha256: [5; ROOT_FINGERPRINT_BYTES],
            host_dtls_fingerprint_sha256: [6; ROOT_FINGERPRINT_BYTES],
            expires_at_unix_ms: 55_000,
            auth_suite_version: TRUSTED_AUTH_SUITE_LEGACY,
            authorization_sha256: [0; ROOT_FINGERPRINT_BYTES],
            capability_sha256: [0; ROOT_FINGERPRINT_BYTES],
        };
        assert_eq!(valid.validate(requested, 5_000), Ok(()));

        let mut invalid = valid.clone();
        invalid.offer_sha256 = [0; ROOT_FINGERPRINT_BYTES];
        assert_eq!(
            invalid.validate(requested, 5_000),
            Err(SecurityError::InvalidMessage)
        );
        let mut invalid = valid.clone();
        invalid.controller_ephemeral_public_key = vec![0x04; 65];
        assert_eq!(
            invalid.validate(requested, 5_000),
            Err(SecurityError::InvalidKey)
        );
    }

    #[test]
    fn trusted_engine_accepts_host_grant_before_controller_proof() {
        let host = key(61);
        let controller = key(62);
        let controller_authentication = key(63);
        let host_public = host.verifying_key().to_encoded_point(false);
        let controller_public = controller.verifying_key().to_encoded_point(false);
        let host_fingerprint = root_fingerprint(host_public.as_bytes()).expect("host fingerprint");
        let controller_fingerprint =
            root_fingerprint(controller_public.as_bytes()).expect("controller fingerprint");
        let requested = PermissionSet::default().grant(SessionPermission::ViewScreen);
        let mut engine = TrustedSecurityEngine::new(host_fingerprint);
        engine
            .begin_session(
                "host-order".into(),
                controller_fingerprint,
                requested,
                TrustedSessionMode::TrustedAuthentication,
            )
            .expect("begin");

        let mut grant = TrustGrant {
            grant_id: [9; 16],
            issuer_root_fingerprint: host_fingerprint,
            subject_root_fingerprint: controller_fingerprint,
            permissions: requested,
            issued_at_unix_ms: 1_000,
            soft_expires_at_unix_ms: 10_000,
            hard_expires_at_unix_ms: 20_000,
            automatic_renewal: true,
            issuer_signature_der: Vec::new(),
        };
        let grant_signature: Signature = host.sign(&grant.signing_bytes());
        grant.issuer_signature_der = grant_signature.to_der().as_bytes().to_vec();
        engine
            .authorize_grant(
                &grant,
                host_public.as_bytes(),
                &controller_fingerprint,
                2_000,
            )
            .expect("grant before proof");
        assert_eq!(engine.phase(), TrustedSecurityPhase::Authenticating);

        let mut certificate = AuthenticationKeyCertificate {
            root_fingerprint: controller_fingerprint,
            authentication_public_key_sec1: controller_authentication
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes()
                .to_vec(),
            not_before_unix_ms: 1_000,
            expires_at_unix_ms: 1_000 + DEFAULT_AUTH_KEY_LIFETIME_MS,
            root_signature_der: Vec::new(),
        };
        let certificate_signature: Signature = controller.sign(&certificate.signing_bytes());
        certificate.root_signature_der = certificate_signature.to_der().as_bytes().to_vec();
        let mut envelope = SignedPeerEnvelope {
            protocol_version: 1,
            session_id: "host-order".into(),
            sender_root_fingerprint: controller_fingerprint,
            recipient_root_fingerprint: host_fingerprint,
            sequence: 1,
            issued_at_unix_ms: 2_000,
            expires_at_unix_ms: 50_000,
            nonce: [4; NONCE_BYTES],
            payload: b"controller-proof".to_vec(),
            signature_der: Vec::new(),
        };
        let envelope_signature: Signature =
            controller_authentication.sign(&envelope.signing_bytes());
        envelope.signature_der = envelope_signature.to_der().as_bytes().to_vec();
        engine
            .verify_envelope(&envelope, controller_public.as_bytes(), &certificate, 3_000)
            .expect("proof after grant");
        assert_eq!(engine.phase(), TrustedSecurityPhase::AwaitingWebRtcBinding);
    }

    #[test]
    fn trusted_engine_fails_closed_on_pause_replay_and_revocation() {
        let local = root_fingerprint(key(51).verifying_key().to_encoded_point(false).as_bytes())
            .expect("local fingerprint");
        let peer = root_fingerprint(key(52).verifying_key().to_encoded_point(false).as_bytes())
            .expect("peer fingerprint");
        let requested = PermissionSet::default().grant(SessionPermission::ViewScreen);
        let mut engine = TrustedSecurityEngine::new(local);
        engine.set_paused(true);
        assert_eq!(
            engine.begin_session(
                "blocked".into(),
                peer,
                requested,
                TrustedSessionMode::TrustedAuthentication,
            ),
            Err(SecurityError::Paused)
        );
        engine.set_paused(false);
        engine
            .begin_session(
                "pairing".into(),
                peer,
                requested,
                TrustedSessionMode::Pairing,
            )
            .expect("pairing");
        assert_eq!(
            engine.confirm_pairing(false),
            Err(SecurityError::InvalidSignature)
        );
        assert_eq!(engine.phase(), TrustedSecurityPhase::Failed);
        engine.end_session();
        assert_eq!(engine.phase(), TrustedSecurityPhase::Idle);
    }
}
