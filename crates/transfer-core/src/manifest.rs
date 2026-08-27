use std::collections::{BTreeMap, BTreeSet};

use crate::{
    TransferError, TransferErrorKind, TransferLimits, TransferResult, ValidatedRelativePath,
    validate_relative_path,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferEntryKind {
    File,
    Directory,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferEntryMetadata {
    pub relative_path: ValidatedRelativePath,
    pub kind: TransferEntryKind,
    pub size_bytes: u64,
    pub sha256: Option<[u8; 32]>,
}

impl TransferEntryMetadata {
    pub fn new(
        relative_path: &str,
        kind: TransferEntryKind,
        size_bytes: u64,
        sha256: Option<[u8; 32]>,
        limits: TransferLimits,
    ) -> TransferResult<Self> {
        if kind == TransferEntryKind::Directory && (size_bytes != 0 || sha256.is_some()) {
            return Err(TransferError::new(
                TransferErrorKind::InvalidArgument,
                "directory entries cannot carry file size or digest",
            ));
        }
        if kind == TransferEntryKind::File && size_bytes > limits.max_single_file_bytes {
            return Err(TransferError::new(
                TransferErrorKind::LimitExceeded,
                "file size exceeds the configured limit",
            ));
        }
        Ok(Self {
            relative_path: validate_relative_path(relative_path, limits)?,
            kind,
            size_bytes,
            sha256,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferManifest {
    entries: Vec<TransferEntryMetadata>,
    total_bytes: u64,
}

impl TransferManifest {
    pub fn new(
        entries: Vec<TransferEntryMetadata>,
        declared_total_bytes: u64,
        limits: TransferLimits,
    ) -> TransferResult<Self> {
        if entries.is_empty() || entries.len() > limits.max_entries as usize {
            return Err(TransferError::new(
                TransferErrorKind::LimitExceeded,
                "manifest entry count exceeds the configured limit",
            ));
        }

        let mut paths = BTreeSet::new();
        let mut kinds = BTreeMap::new();
        let mut total_bytes = 0_u64;
        for entry in &entries {
            let path = entry.relative_path.as_str();
            if !paths.insert(path.to_owned()) {
                return Err(TransferError::new(
                    TransferErrorKind::InvalidArgument,
                    "manifest contains a duplicate relative path",
                ));
            }
            total_bytes = total_bytes.checked_add(entry.size_bytes).ok_or_else(|| {
                TransferError::new(
                    TransferErrorKind::LimitExceeded,
                    "manifest total size overflowed",
                )
            })?;
            if total_bytes > limits.max_total_bytes {
                return Err(TransferError::new(
                    TransferErrorKind::LimitExceeded,
                    "manifest total size exceeds the configured limit",
                ));
            }
            kinds.insert(path.to_owned(), entry.kind);
        }
        if total_bytes != declared_total_bytes {
            return Err(TransferError::new(
                TransferErrorKind::InvalidArgument,
                "manifest total size does not match the declared total",
            ));
        }

        for path in &paths {
            let mut ancestor = String::new();
            let component_count = path.split('/').count();
            for (index, component) in path.split('/').enumerate() {
                if index + 1 == component_count {
                    break;
                }
                if !ancestor.is_empty() {
                    ancestor.push('/');
                }
                ancestor.push_str(component);
                if kinds.get(&ancestor) == Some(&TransferEntryKind::File) {
                    return Err(TransferError::new(
                        TransferErrorKind::InvalidArgument,
                        "manifest places an entry below a file",
                    ));
                }
            }
        }

        Ok(Self {
            entries,
            total_bytes,
        })
    }

    #[must_use]
    pub fn entries(&self) -> &[TransferEntryMetadata] {
        &self.entries
    }

    #[must_use]
    pub const fn total_bytes(&self) -> u64 {
        self.total_bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(path: &str, size: u64) -> TransferEntryMetadata {
        TransferEntryMetadata::new(
            path,
            TransferEntryKind::File,
            size,
            Some([1; 32]),
            TransferLimits::default(),
        )
        .expect("file")
    }

    #[test]
    fn validates_manifest_totals_and_paths() {
        let manifest = TransferManifest::new(
            vec![file("folder/a.txt", 3), file("folder/b.txt", 4)],
            7,
            TransferLimits::default(),
        )
        .expect("manifest");

        assert_eq!(manifest.total_bytes(), 7);
        assert_eq!(manifest.entries().len(), 2);
    }

    #[test]
    fn rejects_duplicates_and_children_below_files() {
        assert!(
            TransferManifest::new(
                vec![file("a", 1), file("a", 1)],
                2,
                TransferLimits::default(),
            )
            .is_err()
        );
        assert!(
            TransferManifest::new(
                vec![file("a", 1), file("a/b", 1)],
                2,
                TransferLimits::default(),
            )
            .is_err()
        );
    }
}
