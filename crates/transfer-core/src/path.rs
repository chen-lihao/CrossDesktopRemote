use std::{
    fs,
    io::ErrorKind,
    path::{Path, PathBuf},
};

use crate::{TransferError, TransferErrorKind, TransferLimits, TransferResult};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidatedRelativePath(String);

impl ValidatedRelativePath {
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn components(&self) -> impl Iterator<Item = &str> {
        self.0.split('/')
    }
}

pub fn validate_relative_path(
    raw: &str,
    limits: TransferLimits,
) -> TransferResult<ValidatedRelativePath> {
    if raw.is_empty() || raw.len() > usize::from(limits.max_relative_path_bytes) {
        return Err(rejected("relative path is empty or too long"));
    }
    if raw.starts_with('/') || raw.starts_with('\\') || has_windows_drive_prefix(raw) {
        return Err(rejected("absolute paths are not allowed"));
    }

    let normalized = raw.replace('\\', "/");
    let components: Vec<_> = normalized.split('/').collect();
    if components.len() > usize::from(limits.max_path_depth) {
        return Err(rejected("relative path is too deep"));
    }
    for component in &components {
        validate_component(component)?;
    }

    Ok(ValidatedRelativePath(components.join("/")))
}

/// Performs a portable path preflight and rejects existing symbolic links.
/// The platform writer must still use no-follow/open-relative APIs to close
/// the time-of-check/time-of-use race when creating the actual file.
pub fn resolve_safe_destination(
    destination_root: &Path,
    relative_path: &ValidatedRelativePath,
) -> TransferResult<PathBuf> {
    let canonical_root = destination_root.canonicalize().map_err(io_error)?;
    if !canonical_root.is_dir() {
        return Err(rejected("destination root is not a directory"));
    }

    let mut candidate = canonical_root.clone();
    for component in relative_path.components() {
        candidate.push(component);
        match fs::symlink_metadata(&candidate) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(rejected("symbolic links are not allowed in transfer paths"));
            }
            Ok(_) => {
                let canonical = candidate.canonicalize().map_err(io_error)?;
                if !canonical.starts_with(&canonical_root) {
                    return Err(rejected("transfer path escapes the destination root"));
                }
            }
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(io_error(error)),
        }
    }
    Ok(candidate)
}

fn validate_component(component: &str) -> TransferResult<()> {
    if component.is_empty() || component == "." || component == ".." {
        return Err(rejected("empty and dot path components are not allowed"));
    }
    if component.len() > 255 {
        return Err(rejected("path component exceeds 255 UTF-8 bytes"));
    }
    if component.chars().any(char::is_control) || component.contains(':') {
        return Err(rejected("path component contains a reserved character"));
    }
    if component.ends_with([' ', '.']) {
        return Err(rejected("path component has a reserved Windows suffix"));
    }

    let stem = component
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_uppercase();
    let reserved = matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || stem.strip_prefix("COM").is_some_and(|suffix| {
            matches!(suffix, "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9")
        })
        || stem.strip_prefix("LPT").is_some_and(|suffix| {
            matches!(suffix, "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9")
        });
    if reserved {
        return Err(rejected("path component is a reserved Windows device name"));
    }
    Ok(())
}

fn has_windows_drive_prefix(path: &str) -> bool {
    let bytes = path.as_bytes();
    bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':'
}

fn rejected(message: &str) -> TransferError {
    TransferError::new(TransferErrorKind::PathRejected, message)
}

fn io_error(error: std::io::Error) -> TransferError {
    TransferError::new(TransferErrorKind::Io, error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_portable_relative_paths() {
        let path = validate_relative_path("folder\\report.txt", TransferLimits::default())
            .expect("path must be valid");
        assert_eq!(path.as_str(), "folder/report.txt");
    }

    #[test]
    fn rejects_traversal_absolute_and_reserved_paths() {
        for path in ["../secret", "/etc/passwd", "C:\\secret", "folder/CON.txt"] {
            assert!(validate_relative_path(path, TransferLimits::default()).is_err());
        }
    }

    #[cfg(unix)]
    #[test]
    fn rejects_existing_symlink_components() {
        use std::os::unix::fs::symlink;

        let root =
            std::env::temp_dir().join(format!("crossdesktop-transfer-path-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("create root");
        symlink("/tmp", root.join("escape")).expect("create symlink");
        let relative =
            validate_relative_path("escape/file", TransferLimits::default()).expect("relative");

        assert_eq!(
            resolve_safe_destination(&root, &relative)
                .expect_err("symlink must fail")
                .kind,
            TransferErrorKind::PathRejected
        );
        fs::remove_dir_all(&root).expect("cleanup");
    }
}
