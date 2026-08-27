pub const DEFAULT_MAX_WIRE_MESSAGE_BYTES: u32 = 16 * 1024;
pub const DEFAULT_MAX_CHUNK_BYTES: u32 = 256 * 1024;
pub const DEFAULT_MAX_IN_FLIGHT_CHUNKS: u16 = 8;
pub const DEFAULT_MAX_ENTRIES: u32 = 10_000;
pub const DEFAULT_MAX_RELATIVE_PATH_BYTES: u16 = 4_096;
pub const DEFAULT_MAX_PATH_DEPTH: u16 = 64;
pub const DEFAULT_MAX_SINGLE_FILE_BYTES: u64 = 512 * 1024 * 1024 * 1024;
pub const DEFAULT_MAX_TOTAL_BYTES: u64 = 1024 * 1024 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TransferLimits {
    /// Logical block size used by the resume bitmap.
    pub max_chunk_bytes: u32,
    /// Maximum payload passed to one transport send call.
    pub max_wire_message_bytes: u32,
    pub max_in_flight_chunks: u16,
    pub max_entries: u32,
    pub max_relative_path_bytes: u16,
    pub max_path_depth: u16,
    pub max_single_file_bytes: u64,
    pub max_total_bytes: u64,
}

impl Default for TransferLimits {
    fn default() -> Self {
        Self {
            max_chunk_bytes: DEFAULT_MAX_CHUNK_BYTES,
            max_wire_message_bytes: DEFAULT_MAX_WIRE_MESSAGE_BYTES,
            max_in_flight_chunks: DEFAULT_MAX_IN_FLIGHT_CHUNKS,
            max_entries: DEFAULT_MAX_ENTRIES,
            max_relative_path_bytes: DEFAULT_MAX_RELATIVE_PATH_BYTES,
            max_path_depth: DEFAULT_MAX_PATH_DEPTH,
            max_single_file_bytes: DEFAULT_MAX_SINGLE_FILE_BYTES,
            max_total_bytes: DEFAULT_MAX_TOTAL_BYTES,
        }
    }
}

impl TransferLimits {
    #[must_use]
    pub const fn is_valid(self) -> bool {
        self.max_wire_message_bytes > 0
            && self.max_wire_message_bytes <= DEFAULT_MAX_WIRE_MESSAGE_BYTES
            && self.max_chunk_bytes >= self.max_wire_message_bytes
            && self
                .max_chunk_bytes
                .is_multiple_of(self.max_wire_message_bytes)
            && self.max_in_flight_chunks > 0
            && self.max_entries > 0
            && self.max_relative_path_bytes > 0
            && self.max_path_depth > 0
            && self.max_single_file_bytes > 0
            && self.max_total_bytes >= self.max_single_file_bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_limits_are_bounded() {
        let limits = TransferLimits::default();

        assert!(limits.is_valid());
        assert_eq!(limits.max_chunk_bytes, 256 * 1024);
        assert_eq!(limits.max_wire_message_bytes, 16 * 1024);
        assert_eq!(limits.max_in_flight_chunks, 8);
    }

    #[test]
    fn rejects_oversized_webrtc_messages() {
        let limits = TransferLimits {
            max_wire_message_bytes: 64 * 1024,
            ..TransferLimits::default()
        };

        assert!(!limits.is_valid());
    }
}
