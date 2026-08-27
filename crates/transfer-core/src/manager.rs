use std::{collections::BTreeMap, sync::Arc};

use crate::{
    TransferDirection, TransferError, TransferErrorKind, TransferId, TransferLimits,
    TransferProgress, TransferResult, TransferTask, TransferTransport,
};

pub type TransferProgressObserver = Arc<dyn Fn(TransferProgress) + Send + Sync + 'static>;

pub struct TransferManager {
    limits: TransferLimits,
    tasks: BTreeMap<TransferId, TransferTask>,
    observer: Option<TransferProgressObserver>,
    transport: Option<Arc<dyn TransferTransport>>,
}

impl TransferManager {
    pub fn new(limits: TransferLimits) -> TransferResult<Self> {
        if !limits.is_valid() {
            return Err(TransferError::new(
                TransferErrorKind::InvalidArgument,
                "invalid transfer manager limits",
            ));
        }
        Ok(Self {
            limits,
            tasks: BTreeMap::new(),
            observer: None,
            transport: None,
        })
    }

    #[must_use]
    pub const fn limits(&self) -> TransferLimits {
        self.limits
    }

    pub fn set_progress_observer(&mut self, observer: Option<TransferProgressObserver>) {
        self.observer = observer;
    }

    pub fn set_transport(&mut self, transport: Option<Arc<dyn TransferTransport>>) {
        self.transport = transport;
    }

    pub fn create_task(
        &mut self,
        id: TransferId,
        direction: TransferDirection,
        total_bytes: u64,
        entry_count: u32,
    ) -> TransferResult<TransferProgress> {
        if self.tasks.contains_key(&id) {
            return Err(TransferError::new(
                TransferErrorKind::InvalidArgument,
                "transfer identifier already exists",
            ));
        }
        let mut task = TransferTask::new(id, direction, total_bytes, entry_count, self.limits)?;
        task.offer()?;
        let progress = task.progress();
        self.tasks.insert(id, task);
        self.notify(progress);
        Ok(progress)
    }

    /// Accepting an offer starts the data phase. Preparation of local files is
    /// completed by the platform adapter before it calls this method.
    pub fn accept(&mut self, id: TransferId) -> TransferResult<TransferProgress> {
        self.update(id, |task| {
            task.accept()?;
            task.start()
        })
    }

    pub fn pause(&mut self, id: TransferId) -> TransferResult<TransferProgress> {
        self.update(id, TransferTask::pause)
    }

    pub fn resume(&mut self, id: TransferId) -> TransferResult<TransferProgress> {
        self.update(id, TransferTask::resume)
    }

    pub fn cancel(&mut self, id: TransferId) -> TransferResult<TransferProgress> {
        self.update(id, TransferTask::cancel)
    }

    pub fn record_progress(
        &mut self,
        id: TransferId,
        delta_bytes: u64,
    ) -> TransferResult<TransferProgress> {
        self.update(id, |task| task.record_progress(delta_bytes))
    }

    pub fn begin_verification(&mut self, id: TransferId) -> TransferResult<TransferProgress> {
        self.update(id, TransferTask::begin_verification)
    }

    pub fn complete(&mut self, id: TransferId) -> TransferResult<TransferProgress> {
        self.update(id, TransferTask::complete)
    }

    pub fn fail(
        &mut self,
        id: TransferId,
        reason: impl Into<String>,
    ) -> TransferResult<TransferProgress> {
        let reason = reason.into();
        self.update(id, |task| task.fail(reason))
    }

    pub fn progress(&self, id: TransferId) -> TransferResult<TransferProgress> {
        self.tasks
            .get(&id)
            .map(TransferTask::progress)
            .ok_or_else(not_found)
    }

    pub fn transport_send(&self, lane: crate::TransferLane, payload: &[u8]) -> TransferResult<()> {
        self.transport
            .as_ref()
            .ok_or_else(|| {
                TransferError::new(
                    TransferErrorKind::Transport,
                    "transfer transport is not configured",
                )
            })?
            .send(lane, payload)
    }

    fn update(
        &mut self,
        id: TransferId,
        operation: impl FnOnce(&mut TransferTask) -> TransferResult<()>,
    ) -> TransferResult<TransferProgress> {
        let progress = {
            let task = self.tasks.get_mut(&id).ok_or_else(not_found)?;
            operation(task)?;
            task.progress()
        };
        self.notify(progress);
        Ok(progress)
    }

    fn notify(&self, progress: TransferProgress) {
        if let Some(observer) = &self.observer {
            observer(progress);
        }
    }
}

fn not_found() -> TransferError {
    TransferError::new(TransferErrorKind::NotFound, "transfer task was not found")
}

#[cfg(test)]
mod tests {
    use std::sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    };

    use super::*;

    #[test]
    fn manages_tasks_and_notifies_progress() {
        let notifications = Arc::new(AtomicUsize::new(0));
        let observed_states = Arc::new(Mutex::new(Vec::new()));
        let notification_counter = Arc::clone(&notifications);
        let states = Arc::clone(&observed_states);
        let mut manager = TransferManager::new(TransferLimits::default()).expect("manager");
        manager.set_progress_observer(Some(Arc::new(move |progress| {
            notification_counter.fetch_add(1, Ordering::Relaxed);
            states.lock().expect("states lock").push(progress.state);
        })));
        let id = TransferId::new([3; 16]);

        manager
            .create_task(id, TransferDirection::Upload, 4, 1)
            .expect("create");
        manager.accept(id).expect("accept");
        manager.record_progress(id, 4).expect("progress");
        manager.begin_verification(id).expect("verify");
        manager.complete(id).expect("complete");

        assert_eq!(notifications.load(Ordering::Relaxed), 5);
        assert_eq!(
            observed_states.lock().expect("states lock").last(),
            Some(&crate::TransferState::Completed)
        );
    }
}
