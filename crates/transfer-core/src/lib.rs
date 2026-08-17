pub const DEFAULT_MAX_CHUNK_BYTES: u32 = 256 * 1024;
pub const DEFAULT_MAX_IN_FLIGHT_CHUNKS: u16 = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TransferLimits {
    pub max_chunk_bytes: u32,
    pub max_in_flight_chunks: u16,
}

impl Default for TransferLimits {
    fn default() -> Self {
        Self {
            max_chunk_bytes: DEFAULT_MAX_CHUNK_BYTES,
            max_in_flight_chunks: DEFAULT_MAX_IN_FLIGHT_CHUNKS,
        }
    }
}

impl TransferLimits {
    #[must_use]
    pub const fn is_valid(self) -> bool {
        self.max_chunk_bytes > 0 && self.max_in_flight_chunks > 0
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
        assert_eq!(limits.max_in_flight_chunks, 8);
    }
}
