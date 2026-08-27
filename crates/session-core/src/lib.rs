use std::collections::BTreeSet;

use protocol::v1::{ClientCapabilities, ClipboardFormat, ProtocolVersion, TransferTransportKind};

pub const CORE_ABI_VERSION: u32 = 1;
pub const PROTOCOL_MAJOR_VERSION: u32 = 1;
pub const FEATURE_NARROW_C_ABI: u64 = 1 << 0;
pub const FEATURE_PROTOBUF_V1: u64 = 1 << 1;
pub const FEATURE_CLIPBOARD_PROTOCOL_V1: u64 = 1 << 2;
pub const FEATURE_FILE_TRANSFER_PROTOCOL_V1: u64 = 1 << 3;
pub const FEATURE_WEBRTC_TRANSFER_TRANSPORT: u64 = 1 << 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoreBuildInfo {
    pub abi_version: u32,
    pub protocol_major_version: u32,
    pub feature_flags: u64,
}

pub const fn core_build_info() -> CoreBuildInfo {
    CoreBuildInfo {
        abi_version: CORE_ABI_VERSION,
        protocol_major_version: PROTOCOL_MAJOR_VERSION,
        feature_flags: FEATURE_NARROW_C_ABI
            | FEATURE_PROTOBUF_V1
            | FEATURE_CLIPBOARD_PROTOCOL_V1
            | FEATURE_FILE_TRANSFER_PROTOCOL_V1
            | FEATURE_WEBRTC_TRANSFER_TRANSPORT,
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct NegotiatedClipboardCapabilities {
    pub enabled: bool,
    pub protocol_version: Option<ProtocolVersion>,
    pub formats: Vec<i32>,
    pub max_text_bytes: u64,
    pub max_image_bytes: u64,
    pub supports_delayed_rendering: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct NegotiatedTransferCapabilities {
    pub enabled: bool,
    pub protocol_version: Option<ProtocolVersion>,
    pub selected_transport: i32,
    pub max_wire_fragment_bytes: u32,
    pub max_in_flight_fragments: u32,
    pub max_single_file_bytes: u64,
    pub max_entries: u32,
    pub supports_resume: bool,
    pub supports_sha256: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct NegotiatedDataCapabilities {
    pub legacy_peer: bool,
    pub clipboard: NegotiatedClipboardCapabilities,
    pub transfer: NegotiatedTransferCapabilities,
}

/// Computes only mutually advertised features. A peer that predates the data
/// capability fields is treated as screen/input-only instead of failing the
/// session or guessing support from its platform.
#[must_use]
pub fn negotiate_data_capabilities(
    local: &ClientCapabilities,
    remote: &ClientCapabilities,
) -> NegotiatedDataCapabilities {
    NegotiatedDataCapabilities {
        legacy_peer: remote.clipboard.is_none() && remote.transfer.is_none(),
        clipboard: negotiate_clipboard(local, remote),
        transfer: negotiate_transfer(local, remote),
    }
}

fn negotiate_clipboard(
    local: &ClientCapabilities,
    remote: &ClientCapabilities,
) -> NegotiatedClipboardCapabilities {
    let (Some(local), Some(remote)) = (&local.clipboard, &remote.clipboard) else {
        return NegotiatedClipboardCapabilities::default();
    };
    let Some(protocol_version) = negotiate_version(
        local.protocol_version.as_ref(),
        remote.protocol_version.as_ref(),
    ) else {
        return NegotiatedClipboardCapabilities::default();
    };

    let remote_formats: BTreeSet<_> = remote.formats.iter().copied().collect();
    let mut formats: Vec<_> = local
        .formats
        .iter()
        .copied()
        .filter(|format| *format != 0 && remote_formats.contains(format))
        .collect();
    formats.sort_unstable();
    formats.dedup();
    let max_text_bytes = local.max_text_bytes.min(remote.max_text_bytes);
    let max_image_bytes = local.max_image_bytes.min(remote.max_image_bytes);
    formats.retain(|format| match *format {
        value if value == ClipboardFormat::TextUtf8 as i32 => max_text_bytes > 0,
        value if value == ClipboardFormat::Png as i32 => max_image_bytes > 0,
        value if value == ClipboardFormat::FileList as i32 => true,
        _ => false,
    });

    NegotiatedClipboardCapabilities {
        enabled: !formats.is_empty(),
        protocol_version: Some(protocol_version),
        formats,
        max_text_bytes,
        max_image_bytes,
        supports_delayed_rendering: local.supports_delayed_rendering
            && remote.supports_delayed_rendering,
    }
}

fn negotiate_transfer(
    local_client: &ClientCapabilities,
    remote_client: &ClientCapabilities,
) -> NegotiatedTransferCapabilities {
    let (Some(local), Some(remote)) = (&local_client.transfer, &remote_client.transfer) else {
        return NegotiatedTransferCapabilities::default();
    };
    let Some(protocol_version) = negotiate_version(
        local.protocol_version.as_ref(),
        remote.protocol_version.as_ref(),
    ) else {
        return NegotiatedTransferCapabilities::default();
    };

    // WebRTC is the only compiled transport in V1. QUIC can be selected here
    // after a future implementation advertises its own core feature flag.
    let webrtc = TransferTransportKind::Webrtc as i32;
    let selected_transport =
        if local.transports.contains(&webrtc) && remote.transports.contains(&webrtc) {
            webrtc
        } else {
            0
        };
    let max_wire_fragment_bytes = local
        .max_wire_fragment_bytes
        .min(remote.max_wire_fragment_bytes)
        .min(16 * 1024);
    let max_in_flight_fragments = local
        .max_in_flight_fragments
        .min(remote.max_in_flight_fragments);
    let max_single_file_bytes = local
        .max_single_file_bytes
        .min(remote.max_single_file_bytes);
    let max_entries = local.max_entries.min(remote.max_entries);
    let enabled = selected_transport != 0
        && max_wire_fragment_bytes > 0
        && max_in_flight_fragments > 0
        && max_single_file_bytes > 0
        && max_entries > 0;

    NegotiatedTransferCapabilities {
        enabled,
        protocol_version: Some(protocol_version),
        selected_transport,
        max_wire_fragment_bytes,
        max_in_flight_fragments,
        max_single_file_bytes,
        max_entries,
        supports_resume: enabled
            && local.supports_resume
            && remote.supports_resume
            && local_client.supports_file_resume
            && remote_client.supports_file_resume,
        supports_sha256: enabled && local.supports_sha256 && remote.supports_sha256,
    }
}

fn negotiate_version(
    local: Option<&ProtocolVersion>,
    remote: Option<&ProtocolVersion>,
) -> Option<ProtocolVersion> {
    let (Some(local), Some(remote)) = (local, remote) else {
        return None;
    };
    if local.major != PROTOCOL_MAJOR_VERSION
        || remote.major != PROTOCOL_MAJOR_VERSION
        || local.major != remote.major
    {
        return None;
    }
    Some(ProtocolVersion {
        major: local.major,
        minor: local.minor.min(remote.minor),
    })
}

#[cfg(test)]
mod tests {
    use protocol::v1::{ClipboardCapabilities, TransferCapabilities};

    use super::*;

    #[test]
    fn reports_only_compiled_core_features() {
        let info = core_build_info();

        assert_eq!(info.abi_version, 1);
        assert_eq!(info.protocol_major_version, 1);
        assert_ne!(info.feature_flags & FEATURE_NARROW_C_ABI, 0);
        assert_ne!(info.feature_flags & FEATURE_PROTOBUF_V1, 0);
        assert_ne!(info.feature_flags & FEATURE_CLIPBOARD_PROTOCOL_V1, 0);
        assert_ne!(info.feature_flags & FEATURE_FILE_TRANSFER_PROTOCOL_V1, 0);
        assert_ne!(info.feature_flags & FEATURE_WEBRTC_TRANSFER_TRANSPORT, 0);
    }

    #[test]
    fn old_client_downgrades_without_disabling_the_session() {
        let negotiated = negotiate_data_capabilities(&full_capabilities(), &Default::default());

        assert!(negotiated.legacy_peer);
        assert!(!negotiated.clipboard.enabled);
        assert!(!negotiated.transfer.enabled);
    }

    #[test]
    fn negotiates_intersection_and_bounded_webrtc_fragments() {
        let local = full_capabilities();
        let mut remote = full_capabilities();
        remote.clipboard.as_mut().expect("clipboard").formats =
            vec![ClipboardFormat::TextUtf8 as i32];
        remote
            .transfer
            .as_mut()
            .expect("transfer")
            .max_wire_fragment_bytes = 64 * 1024;
        remote
            .transfer
            .as_mut()
            .expect("transfer")
            .max_in_flight_fragments = 4;

        let negotiated = negotiate_data_capabilities(&local, &remote);

        assert!(!negotiated.legacy_peer);
        assert_eq!(
            negotiated.clipboard.formats,
            vec![ClipboardFormat::TextUtf8 as i32]
        );
        assert_eq!(negotiated.transfer.max_wire_fragment_bytes, 16 * 1024);
        assert_eq!(negotiated.transfer.max_in_flight_fragments, 4);
        assert!(negotiated.transfer.supports_resume);
    }

    #[test]
    fn incompatible_major_version_disables_only_data_features() {
        let local = full_capabilities();
        let mut remote = full_capabilities();
        remote
            .clipboard
            .as_mut()
            .expect("clipboard")
            .protocol_version
            .as_mut()
            .expect("version")
            .major = 2;
        remote
            .transfer
            .as_mut()
            .expect("transfer")
            .protocol_version
            .as_mut()
            .expect("version")
            .major = 2;

        let negotiated = negotiate_data_capabilities(&local, &remote);

        assert!(!negotiated.clipboard.enabled);
        assert!(!negotiated.transfer.enabled);
    }

    fn full_capabilities() -> ClientCapabilities {
        ClientCapabilities {
            supports_file_resume: true,
            clipboard: Some(ClipboardCapabilities {
                protocol_version: Some(ProtocolVersion { major: 1, minor: 1 }),
                formats: vec![
                    ClipboardFormat::TextUtf8 as i32,
                    ClipboardFormat::Png as i32,
                    ClipboardFormat::FileList as i32,
                ],
                max_text_bytes: 4 * 1024 * 1024,
                max_image_bytes: 16 * 1024 * 1024,
                supports_delayed_rendering: true,
            }),
            transfer: Some(TransferCapabilities {
                protocol_version: Some(ProtocolVersion { major: 1, minor: 0 }),
                transports: vec![TransferTransportKind::Webrtc as i32],
                max_wire_fragment_bytes: 16 * 1024,
                max_in_flight_fragments: 8,
                max_single_file_bytes: 1024 * 1024,
                max_entries: 100,
                supports_resume: true,
                supports_sha256: true,
            }),
            ..Default::default()
        }
    }
}
