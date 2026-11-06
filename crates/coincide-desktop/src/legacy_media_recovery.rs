//! Native parent recovery bridge: explicit requests only; all storage IO off GPUI.
//! Keep this owner AND the panel alive until shutdown_ready is true.
use coincide_core::legacy_media_recovery::{
    DurableOwnership, RecoveryError, RecoveryResult, RecoveryStore,
};
use coincide_core::legacy_media_service::{CompletionReceipt, ReceiptId, ServiceConfig};
use std::{
    collections::{HashMap, HashSet},
    sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
        mpsc::{self, Receiver, SyncSender, TrySendError},
    },
};
const MAX_PENDING: usize = 8;
struct Request {
    id: ReceiptId,
    receipt: Arc<CompletionReceipt>,
}
pub struct OwnershipOutcome {
    pub receipt_id: ReceiptId,
    pub result: RecoveryResult<DurableOwnership>,
}
/// No automatic ack, deletion, retry, receipt export, DB/media mutation, or joining on UI thread.
pub struct ParentRecoveryOwner {
    sender: Option<SyncSender<Request>>,
    completion: Arc<AtomicU8>,
    receiver: Receiver<OwnershipOutcome>,
    pending: HashMap<ReceiptId, Arc<CompletionReceipt>>,
    inflight: HashSet<ReceiptId>,
    durable: HashMap<ReceiptId, DurableOwnership>,
}
impl ParentRecoveryOwner {
    /// Spawns only a bounded IO worker. Opening/creating the recovery directory waits
    /// for the first explicit take_ownership request; construction itself does no disk IO.
    pub fn spawn(config: ServiceConfig) -> Self {
        let (sender, requests) = mpsc::sync_channel::<Request>(MAX_PENDING);
        let (results, receiver) = mpsc::sync_channel(MAX_PENDING);
        let worker = std::thread::spawn(move || {
            let mut store = None;
            while let Ok(request) = requests.recv() {
                let result = (|| {
                    if store.is_none() {
                        store = Some(RecoveryStore::open(&config)?);
                    }
                    store
                        .as_mut()
                        .ok_or(RecoveryError::Io)?
                        .persist(request.id, &request.receipt)
                })();
                if results
                    .send(OwnershipOutcome {
                        receipt_id: request.id,
                        result,
                    })
                    .is_err()
                {
                    break;
                }
            }
            // No memory-only job/Arc implies a crash-safety guarantee. Parent must drain first.
        });
        let completion = Arc::new(AtomicU8::new(0));
        let joined = completion.clone();
        std::thread::spawn(move || {
            joined.store(if worker.join().is_ok() { 1 } else { 2 }, Ordering::Release);
        });
        Self {
            sender: Some(sender),
            completion,
            receiver,
            pending: HashMap::new(),
            inflight: HashSet::new(),
            durable: HashMap::new(),
        }
    }
    /// Explicit RecoveryOwnershipRequested hook. Queueing is NOT durable ownership.
    /// Failures keep existing retained Arc; panel/service must retain newly rejected work.
    pub fn take_ownership(
        &mut self,
        id: ReceiptId,
        receipt: Arc<CompletionReceipt>,
    ) -> RecoveryResult<()> {
        if self.sender.is_none() {
            return Err(RecoveryError::Busy);
        }
        if let Some(existing) = self.pending.get(&id) {
            // A receipt ID cannot be rebound to another object even with matching visible fields.
            if !Arc::ptr_eq(existing, &receipt) {
                return Err(RecoveryError::Conflict);
            }
        } else {
            if self.pending.len() >= MAX_PENDING {
                return Err(RecoveryError::Quota);
            }
            self.pending.insert(id, receipt.clone());
        }
        if self.inflight.contains(&id) || self.durable.contains_key(&id) {
            return Err(RecoveryError::Busy);
        }
        match self
            .sender
            .as_ref()
            .ok_or(RecoveryError::Busy)?
            .try_send(Request { id, receipt })
        {
            Ok(()) => {
                self.inflight.insert(id);
                Ok(())
            }
            Err(TrySendError::Full(_)) => Err(RecoveryError::Busy),
            Err(TrySendError::Disconnected(_)) => Err(RecoveryError::Io),
        }
    }
    /// Nonblocking; success is the only path authorizing the parent's next explicit
    /// panel.acknowledge_reconciled(id,cx). Busy/error from panel must retain this owner.
    pub fn poll(&mut self) -> Option<OwnershipOutcome> {
        let outcome = self.receiver.try_recv().ok()?;
        self.inflight.remove(&outcome.receipt_id);
        if let Ok(token) = &outcome.result {
            self.durable.insert(outcome.receipt_id, token.clone());
        }
        Some(outcome)
    }
    /// Call ONLY AFTER panel/service acknowledgment returned Ok. On failure keep token
    /// and Arc and retry acknowledgment, never rerun materialization.
    pub fn acknowledged(&mut self, id: ReceiptId, token: &DurableOwnership) -> RecoveryResult<()> {
        let stored = self.durable.get(&id).ok_or(RecoveryError::Conflict)?;
        if stored.receipt_id() != token.receipt_id()
            || stored.operation_id() != token.operation_id()
            || stored.thread_id() != token.thread_id()
            || stored.digest() != token.digest()
        {
            return Err(RecoveryError::Conflict);
        }
        self.durable.remove(&id);
        self.pending.remove(&id);
        Ok(())
    }
    pub fn durable_ownership(&self, id: ReceiptId) -> Option<&DurableOwnership> {
        self.durable.get(&id)
    }
    pub fn pending_receipts(&self) -> Vec<(ReceiptId, Arc<CompletionReceipt>)> {
        self.pending
            .iter()
            .map(|(id, r)| (*id, r.clone()))
            .collect()
    }
    /// Parent passes panel.has_in_flight_work() and panel.retained_receipts().len().
    /// Service.pending_recovery().is_empty() is NOT a substitute for either value.
    pub fn shutdown_ready(&self, panel_inflight: bool, panel_retained_count: usize) -> bool {
        !panel_inflight
            && panel_retained_count == 0
            && self.pending.is_empty()
            && self.inflight.is_empty()
    }
    /// Close IO only after every durable handoff was acknowledged. The panel's
    /// service worker is a separate owner; this never substitutes for its drain.
    pub fn request_worker_shutdown(&mut self) -> RecoveryResult<()> {
        if !self.pending.is_empty() || !self.inflight.is_empty() || !self.durable.is_empty() {
            return Err(RecoveryError::Busy);
        }
        self.sender.take();
        Ok(())
    }
    pub fn worker_shutdown_status(&self) -> coincide_core::agent::WorkerThreadStatus {
        use coincide_core::agent::WorkerThreadStatus;
        match self.completion.load(Ordering::Acquire) {
            0 => WorkerThreadStatus::Running,
            1 => WorkerThreadStatus::Returned,
            2 => WorkerThreadStatus::Panicked,
            _ => WorkerThreadStatus::Unclassified,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recovery_worker_explicit_eof_is_joined_without_opening_storage() {
        let directory =
            std::env::temp_dir().join(format!("unused-recovery-{}", uuid::Uuid::new_v4()));
        let mut owner = ParentRecoveryOwner::spawn(ServiceConfig {
            database_path: directory.join("missing.sqlite"),
            expected_data_directory: directory.clone(),
        });
        owner.request_worker_shutdown().unwrap();
        owner.request_worker_shutdown().unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while owner.worker_shutdown_status() == coincide_core::agent::WorkerThreadStatus::Running {
            assert!(
                std::time::Instant::now() < deadline,
                "recovery worker failed to join"
            );
            std::thread::yield_now();
        }
        assert_eq!(
            owner.worker_shutdown_status(),
            coincide_core::agent::WorkerThreadStatus::Returned
        );
        assert!(!directory.exists());
    }
    #[test]
    fn shutdown_blocks_on_panel_work_and_unowned_receipts_without_opening_storage() {
        // Channels only: no native effects or background jobs; opaque IDs are never reconstructed.
        let (sender, _) = mpsc::sync_channel(MAX_PENDING);
        let (_, receiver) = mpsc::sync_channel(MAX_PENDING);
        let owner = ParentRecoveryOwner {
            sender: Some(sender),
            completion: Arc::new(AtomicU8::new(0)),
            receiver,
            pending: HashMap::new(),
            inflight: HashSet::new(),
            durable: HashMap::new(),
        };
        assert!(owner.shutdown_ready(false, 0));
        assert!(!owner.shutdown_ready(true, 0));
        assert!(!owner.shutdown_ready(false, 1));
    }
}
