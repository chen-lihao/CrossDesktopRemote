use crate::{TransferError, TransferErrorKind, TransferLimits, TransferResult};

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TransferId(pub [u8; 16]);

impl TransferId {
    #[must_use]
    pub const fn new(bytes: [u8; 16]) -> Self {
        Self(bytes)
    }
}

#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferDirection {
    Upload = 1,
    Download = 2,
}

#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferState {
    Created = 1,
    Offered = 2,
    Accepted = 3,
    Transferring = 4,
    Paused = 5,
    Reconnecting = 6,
    Verifying = 7,
    Completed = 8,
    Failed = 9,
    Cancelled = 10,
}

impl TransferState {
    #[must_use]
    pub const fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TransferProgress {
    pub transfer_id: TransferId,
    pub state: TransferState,
    pub transferred_bytes: u64,
    pub total_bytes: u64,
    pub entry_count: u32,
}

impl TransferProgress {
    #[must_use]
    pub fn basis_points(self) -> u16 {
        if self.total_bytes == 0 {
            return if self.state == TransferState::Completed {
                10_000
            } else {
                0
            };
        }
        let scaled = u128::from(self.transferred_bytes) * 10_000;
        (scaled / u128::from(self.total_bytes)).min(10_000) as u16
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferTask {
    id: TransferId,
    direction: TransferDirection,
    state: TransferState,
    transferred_bytes: u64,
    total_bytes: u64,
    entry_count: u32,
    failure_reason: Option<String>,
}

impl TransferTask {
    pub fn new(
        id: TransferId,
        direction: TransferDirection,
        total_bytes: u64,
        entry_count: u32,
        limits: TransferLimits,
    ) -> TransferResult<Self> {
        if !limits.is_valid() {
            return Err(TransferError::new(
                TransferErrorKind::InvalidArgument,
                "invalid transfer limits",
            ));
        }
        if entry_count == 0 || entry_count > limits.max_entries {
            return Err(TransferError::new(
                TransferErrorKind::LimitExceeded,
                "transfer entry count exceeds the configured limit",
            ));
        }
        if total_bytes > limits.max_total_bytes {
            return Err(TransferError::new(
                TransferErrorKind::LimitExceeded,
                "transfer size exceeds the configured limit",
            ));
        }

        Ok(Self {
            id,
            direction,
            state: TransferState::Created,
            transferred_bytes: 0,
            total_bytes,
            entry_count,
            failure_reason: None,
        })
    }

    #[must_use]
    pub const fn id(&self) -> TransferId {
        self.id
    }

    #[must_use]
    pub const fn direction(&self) -> TransferDirection {
        self.direction
    }

    #[must_use]
    pub const fn state(&self) -> TransferState {
        self.state
    }

    #[must_use]
    pub fn failure_reason(&self) -> Option<&str> {
        self.failure_reason.as_deref()
    }

    #[must_use]
    pub const fn progress(&self) -> TransferProgress {
        TransferProgress {
            transfer_id: self.id,
            state: self.state,
            transferred_bytes: self.transferred_bytes,
            total_bytes: self.total_bytes,
            entry_count: self.entry_count,
        }
    }

    pub fn offer(&mut self) -> TransferResult<()> {
        self.transition(TransferState::Created, TransferState::Offered)
    }

    pub fn accept(&mut self) -> TransferResult<()> {
        self.transition(TransferState::Offered, TransferState::Accepted)
    }

    pub fn start(&mut self) -> TransferResult<()> {
        self.transition(TransferState::Accepted, TransferState::Transferring)
    }

    pub fn pause(&mut self) -> TransferResult<()> {
        match self.state {
            TransferState::Transferring | TransferState::Reconnecting => {
                self.state = TransferState::Paused;
                Ok(())
            }
            _ => Err(self.invalid_transition(TransferState::Paused)),
        }
    }

    pub fn resume(&mut self) -> TransferResult<()> {
        self.transition(TransferState::Paused, TransferState::Transferring)
    }

    pub fn mark_reconnecting(&mut self) -> TransferResult<()> {
        self.transition(TransferState::Transferring, TransferState::Reconnecting)
    }

    pub fn record_progress(&mut self, delta_bytes: u64) -> TransferResult<()> {
        if self.state != TransferState::Transferring {
            return Err(self.invalid_transition(TransferState::Transferring));
        }
        let next = self
            .transferred_bytes
            .checked_add(delta_bytes)
            .ok_or_else(|| {
                TransferError::new(
                    TransferErrorKind::LimitExceeded,
                    "transfer progress overflowed",
                )
            })?;
        if next > self.total_bytes {
            return Err(TransferError::new(
                TransferErrorKind::InvalidArgument,
                "transfer progress exceeds total bytes",
            ));
        }
        self.transferred_bytes = next;
        Ok(())
    }

    pub fn begin_verification(&mut self) -> TransferResult<()> {
        if self.transferred_bytes != self.total_bytes {
            return Err(TransferError::new(
                TransferErrorKind::InvalidState,
                "cannot verify an incomplete transfer",
            ));
        }
        self.transition(TransferState::Transferring, TransferState::Verifying)
    }

    pub fn complete(&mut self) -> TransferResult<()> {
        self.transition(TransferState::Verifying, TransferState::Completed)
    }

    pub fn fail(&mut self, reason: impl Into<String>) -> TransferResult<()> {
        if self.state.is_terminal() {
            return Err(self.invalid_transition(TransferState::Failed));
        }
        self.state = TransferState::Failed;
        self.failure_reason = Some(reason.into());
        Ok(())
    }

    pub fn cancel(&mut self) -> TransferResult<()> {
        if self.state.is_terminal() {
            return Err(self.invalid_transition(TransferState::Cancelled));
        }
        self.state = TransferState::Cancelled;
        Ok(())
    }

    fn transition(&mut self, from: TransferState, to: TransferState) -> TransferResult<()> {
        if self.state != from {
            return Err(self.invalid_transition(to));
        }
        self.state = to;
        Ok(())
    }

    fn invalid_transition(&self, target: TransferState) -> TransferError {
        TransferError::new(
            TransferErrorKind::InvalidState,
            format!(
                "invalid transfer state transition from {:?} to {target:?}",
                self.state
            ),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task() -> TransferTask {
        TransferTask::new(
            TransferId::new([7; 16]),
            TransferDirection::Upload,
            10,
            1,
            TransferLimits::default(),
        )
        .expect("task must be valid")
    }

    #[test]
    fn runs_the_happy_path() {
        let mut task = task();
        task.offer().expect("offer");
        task.accept().expect("accept");
        task.start().expect("start");
        task.record_progress(4).expect("progress");
        task.pause().expect("pause");
        task.resume().expect("resume");
        task.record_progress(6).expect("progress");
        task.begin_verification().expect("verify");
        task.complete().expect("complete");

        assert_eq!(task.state(), TransferState::Completed);
        assert_eq!(task.progress().basis_points(), 10_000);
    }

    #[test]
    fn rejects_progress_while_paused() {
        let mut task = task();
        task.offer().expect("offer");
        task.accept().expect("accept");
        task.start().expect("start");
        task.pause().expect("pause");

        assert_eq!(
            task.record_progress(1).expect_err("must reject").kind,
            TransferErrorKind::InvalidState
        );
    }
}
