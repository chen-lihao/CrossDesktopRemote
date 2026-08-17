#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKind {
    Video,
    Audio,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameMetadata {
    pub stream_id: u32,
    pub sequence: u64,
    pub timestamp_micros: u64,
    pub key_frame: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_frame_timing_outside_the_flutter_boundary() {
        let frame = FrameMetadata {
            stream_id: 7,
            sequence: 42,
            timestamp_micros: 16_667,
            key_frame: true,
        };

        assert_eq!(frame.sequence, 42);
        assert!(frame.key_frame);
    }
}
