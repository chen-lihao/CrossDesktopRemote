use std::fmt::{Display, Formatter};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferErrorKind {
    InvalidArgument,
    InvalidState,
    LimitExceeded,
    NotFound,
    PathRejected,
    Io,
    Integrity,
    Backpressure,
    Transport,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferError {
    pub kind: TransferErrorKind,
    pub message: String,
}

impl TransferError {
    #[must_use]
    pub fn new(kind: TransferErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

impl Display for TransferError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for TransferError {}

pub type TransferResult<T> = Result<T, TransferError>;
