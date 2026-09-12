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
pub const MAX_SESSION_ID_BYTES: usize = 128;
// Signed payloads are base64-encoded into a signaling JSON envelope whose
// total limit is 64 KiB. Keep enough headroom for identity and signature data.
pub const MAX_SIGNED_PAYLOAD_BYTES: usize = 32 * 1_024;
pub const MAX_DER_SIGNATURE_BYTES: usize = 80;

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
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PermissionSet(u64);

impl PermissionSet {
    #[must_use]
    pub const fn from_bits(bits: u64) -> Self {
        Self(bits & 0x7f)
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
        if root_fingerprint(root_public_key_sec1)? != self.root_fingerprint {
            return Err(SecurityError::FingerprintMismatch);
        }
        if self.expires_at_unix_ms <= self.not_before_unix_ms
            || self.expires_at_unix_ms - self.not_before_unix_ms > DEFAULT_AUTH_KEY_LIFETIME_MS
        {
            return Err(SecurityError::LifetimeExceeded);
        }
        if now_unix_ms < self.not_before_unix_ms {
            return Err(SecurityError::NotYetValid);
        }
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
        if &self.subject_root_fingerprint != expected_subject {
            return Err(SecurityError::WrongRecipient);
        }
        if now_unix_ms < self.issued_at_unix_ms {
            return Err(SecurityError::NotYetValid);
        }
        if now_unix_ms >= self.hard_expires_at_unix_ms {
            return Err(SecurityError::HardExpired);
        }
        if now_unix_ms >= self.soft_expires_at_unix_ms {
            return Err(SecurityError::SoftExpired);
        }
        if !requested_permissions.is_subset_of(self.permissions) {
            return Err(SecurityError::PermissionDenied);
        }
        if self.soft_expires_at_unix_ms <= self.issued_at_unix_ms
            || self.hard_expires_at_unix_ms < self.soft_expires_at_unix_ms
            || self.hard_expires_at_unix_ms - self.issued_at_unix_ms
                > DEFAULT_TRUST_HARD_LIFETIME_MS
        {
            return Err(SecurityError::LifetimeExceeded);
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
    pub offer_sha256: [u8; ROOT_FINGERPRINT_BYTES],
    pub answer_sha256: [u8; ROOT_FINGERPRINT_BYTES],
    pub controller_dtls_fingerprint_sha256: [u8; ROOT_FINGERPRINT_BYTES],
    pub host_dtls_fingerprint_sha256: [u8; ROOT_FINGERPRINT_BYTES],
    pub expires_at_unix_ms: u64,
}

impl TrustedSessionBinding {
    #[must_use]
    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut output = Vec::with_capacity(320);
        append_domain(&mut output, b"CrossDesktopRemote/TrustedSessionBinding/v1");
        append_bytes(&mut output, self.session_id.as_bytes());
        append_bytes(&mut output, &self.controller_nonce);
        append_bytes(&mut output, &self.host_nonce);
        output.extend_from_slice(&self.requested_permissions.bits().to_be_bytes());
        append_bytes(&mut output, &self.offer_sha256);
        append_bytes(&mut output, &self.answer_sha256);
        append_bytes(&mut output, &self.controller_dtls_fingerprint_sha256);
        append_bytes(&mut output, &self.host_dtls_fingerprint_sha256);
        output.extend_from_slice(&self.expires_at_unix_ms.to_be_bytes());
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
    maximum_clock_skew_ms: u64,
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
            maximum_clock_skew_ms: 30_000,
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
        sender_authentication_certificate.validate(sender_root_public_key_sec1, now_unix_ms)?;
        if envelope.expires_at_unix_ms <= envelope.issued_at_unix_ms
            || now_unix_ms >= envelope.expires_at_unix_ms
        {
            return Err(SecurityError::Expired);
        }
        if envelope.issued_at_unix_ms > now_unix_ms.saturating_add(self.maximum_clock_skew_ms) {
            return Err(SecurityError::NotYetValid);
        }
        if envelope
            .expires_at_unix_ms
            .saturating_sub(envelope.issued_at_unix_ms)
            > DEFAULT_SESSION_TICKET_LIFETIME_MS
        {
            return Err(SecurityError::LifetimeExceeded);
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
}

pub fn root_fingerprint(
    root_public_key_sec1: &[u8],
) -> Result<[u8; ROOT_FINGERPRINT_BYTES], SecurityError> {
    let key = VerifyingKey::from_sec1_bytes(root_public_key_sec1)
        .map_err(|_| SecurityError::InvalidKey)?;
    let canonical = key.to_encoded_point(false);
    Ok(Sha256::digest(canonical.as_bytes()).into())
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
}
