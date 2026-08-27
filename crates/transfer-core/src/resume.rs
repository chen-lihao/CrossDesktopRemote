use crate::{TransferError, TransferErrorKind, TransferResult};

const MAX_RESUME_CHUNKS: u64 = 16 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CompletedRange {
    pub offset: u64,
    pub length: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeBitmap {
    total_bytes: u64,
    chunk_bytes: u32,
    chunk_count: u64,
    words: Vec<u64>,
}

impl ResumeBitmap {
    pub fn new(total_bytes: u64, chunk_bytes: u32) -> TransferResult<Self> {
        if chunk_bytes == 0 {
            return Err(TransferError::new(
                TransferErrorKind::InvalidArgument,
                "resume chunk size must be positive",
            ));
        }
        let chunk_count = total_bytes.div_ceil(u64::from(chunk_bytes));
        if chunk_count > MAX_RESUME_CHUNKS {
            return Err(TransferError::new(
                TransferErrorKind::LimitExceeded,
                "resume bitmap exceeds the configured chunk limit",
            ));
        }
        let word_count = chunk_count.div_ceil(64) as usize;
        Ok(Self {
            total_bytes,
            chunk_bytes,
            chunk_count,
            words: vec![0; word_count],
        })
    }

    pub fn from_bytes(total_bytes: u64, chunk_bytes: u32, encoded: &[u8]) -> TransferResult<Self> {
        let mut bitmap = Self::new(total_bytes, chunk_bytes)?;
        let expected = bitmap.chunk_count.div_ceil(8) as usize;
        if encoded.len() != expected {
            return Err(TransferError::new(
                TransferErrorKind::InvalidArgument,
                "resume bitmap length does not match transfer geometry",
            ));
        }
        for (index, byte) in encoded.iter().copied().enumerate() {
            let word = index / 8;
            let shift = (index % 8) * 8;
            bitmap.words[word] |= u64::from(byte) << shift;
        }
        bitmap.clear_unused_bits();
        Ok(bitmap)
    }

    #[must_use]
    pub const fn chunk_bytes(&self) -> u32 {
        self.chunk_bytes
    }

    #[must_use]
    pub const fn chunk_count(&self) -> u64 {
        self.chunk_count
    }

    pub fn mark_chunk(&mut self, chunk_index: u64) -> TransferResult<()> {
        if chunk_index >= self.chunk_count {
            return Err(TransferError::new(
                TransferErrorKind::InvalidArgument,
                "resume chunk index is out of range",
            ));
        }
        let word = (chunk_index / 64) as usize;
        let bit = chunk_index % 64;
        self.words[word] |= 1_u64 << bit;
        Ok(())
    }

    #[must_use]
    pub fn contains(&self, chunk_index: u64) -> bool {
        if chunk_index >= self.chunk_count {
            return false;
        }
        let word = (chunk_index / 64) as usize;
        let bit = chunk_index % 64;
        self.words[word] & (1_u64 << bit) != 0
    }

    #[must_use]
    pub fn completed_bytes(&self) -> u64 {
        (0..self.chunk_count)
            .filter(|index| self.contains(*index))
            .map(|index| self.chunk_length(index))
            .sum()
    }

    #[must_use]
    pub fn contiguous_bytes(&self) -> u64 {
        (0..self.chunk_count)
            .take_while(|index| self.contains(*index))
            .map(|index| self.chunk_length(index))
            .sum()
    }

    #[must_use]
    pub fn is_complete(&self) -> bool {
        self.chunk_count == 0 || (0..self.chunk_count).all(|index| self.contains(index))
    }

    #[must_use]
    pub fn missing_ranges(&self) -> Vec<CompletedRange> {
        let mut ranges = Vec::new();
        let mut start = None;
        for index in 0..=self.chunk_count {
            let missing = index < self.chunk_count && !self.contains(index);
            match (start, missing) {
                (None, true) => start = Some(index),
                (Some(first), false) => {
                    let offset = first * u64::from(self.chunk_bytes);
                    let end = (index * u64::from(self.chunk_bytes)).min(self.total_bytes);
                    ranges.push(CompletedRange {
                        offset,
                        length: end - offset,
                    });
                    start = None;
                }
                _ => {}
            }
        }
        ranges
    }

    #[must_use]
    pub fn to_bytes(&self) -> Vec<u8> {
        let byte_count = self.chunk_count.div_ceil(8) as usize;
        let mut encoded = Vec::with_capacity(byte_count);
        for word in &self.words {
            encoded.extend_from_slice(&word.to_le_bytes());
        }
        encoded.truncate(byte_count);
        encoded
    }

    fn chunk_length(&self, chunk_index: u64) -> u64 {
        let offset = chunk_index * u64::from(self.chunk_bytes);
        (self.total_bytes - offset).min(u64::from(self.chunk_bytes))
    }

    fn clear_unused_bits(&mut self) {
        let used_in_last_word = self.chunk_count % 64;
        if used_in_last_word == 0 {
            return;
        }
        if let Some(last) = self.words.last_mut() {
            *last &= (1_u64 << used_in_last_word) - 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_coalesces_missing_ranges() {
        let mut bitmap = ResumeBitmap::new(10, 4).expect("bitmap");
        bitmap.mark_chunk(0).expect("first chunk");
        bitmap.mark_chunk(2).expect("last chunk");

        assert_eq!(bitmap.completed_bytes(), 6);
        assert_eq!(bitmap.contiguous_bytes(), 4);
        assert_eq!(
            bitmap.missing_ranges(),
            vec![CompletedRange {
                offset: 4,
                length: 4
            }]
        );

        let decoded = ResumeBitmap::from_bytes(10, 4, &bitmap.to_bytes()).expect("decode");
        assert_eq!(decoded, bitmap);
    }

    #[test]
    fn empty_file_is_complete() {
        let bitmap = ResumeBitmap::new(0, 4).expect("bitmap");
        assert!(bitmap.is_complete());
    }
}
