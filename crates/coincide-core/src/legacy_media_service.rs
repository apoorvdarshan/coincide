//! Native-only historical-media controller. No JSON root approval or Engine lock.
//! Parent must retain service while hidden and take recovery ownership before ack/drop.
use crate::{
    attachments::StoredImage,
    legacy_media::{
        self as media, ApprovedRoot, Candidate, CheckedReference, InspectOptions, InspectionLimit,
        MediaBatch, MediaPlan, MediaPreview, Status,
    },
    store::Store,
};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs::{File, Metadata},
    io::Read,
    path::{Component, Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering},
        mpsc::{self, SyncSender},
    },
    time::{Duration, Instant},
};
use uuid::Uuid;
const ROOT_TTL: Duration = Duration::from_secs(600);
const PREVIEW_TTL: Duration = Duration::from_secs(300);
const MAX_RECEIPTS: usize = 8;
const MAX_REGISTRY: usize = 8;
const MAX_OVERLAY: usize = 4 * 1024 * 1024;
const MAX_THREAD: usize = 16_000_000;
const QUEUED: u8 = 0;
const RUNNING: u8 = 1;
const CANCELLED: u8 = 2;
const COMMITTING: u8 = 3;
const FINISHED: u8 = 4;
macro_rules! token {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub struct $name(Uuid);
        impl std::fmt::Display for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                self.0.fmt(f)
            }
        }
    };
}
token!(PlanId);
token!(PreviewId);
token!(OperationId);
token!(ReceiptId);
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ServiceError {
    Busy,
    QueueFull,
    RecoveryRequired,
    InvalidSelection,
    SelectionChanged,
    RootApprovalRequired,
    RootRevoked,
    Expired,
    UnknownPlan,
    UnknownPreview,
    AlreadyConsumed,
    InvalidCandidates,
    ThreadMissing,
    ThreadChanged,
    OverlayChanged,
    OverlayLimit,
    InvalidOverlay,
    PlatformUnsupported,
    Cancelled,
    StoreUnavailable,
    CommitFailed,
    CommitUnknown,
}
impl std::fmt::Display for ServiceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for ServiceError {}
pub type ServiceResult<T> = std::result::Result<T, ServiceError>;
#[derive(Clone, Debug)]
pub struct SelectionToken {
    owner: Uuid,
    thread: Option<String>,
    generation: u64,
    active: Arc<AtomicBool>,
}
impl SelectionToken {
    pub fn accepts(&self, thread_id: &str, generation: u64) -> bool {
        self.active.load(Ordering::SeqCst)
            && self.generation == generation
            && self.thread.as_deref() == Some(thread_id)
    }
}
#[derive(Clone, Debug)]
pub struct RootCapability {
    id: Uuid,
    selection: SelectionToken,
    roots: Vec<ApprovedRoot>,
    relative_base: Option<String>,
    expires: Instant,
    active: Arc<AtomicBool>,
}
#[derive(Clone, Debug)]
pub struct ServiceConfig {
    pub database_path: PathBuf,
    pub expected_data_directory: PathBuf,
}
#[derive(Clone, Debug)]
pub enum CancelAck {
    Requested,
    TooLateMayCommit,
    Finished,
    UnknownOperation,
}
#[derive(Debug)]
pub struct CompletionReceipt {
    pub operation_id: OperationId,
    pub thread_id: String,
    pub generation: u64,
    pub committed: bool,
    pub error: Option<ServiceError>,
    pub batch: MediaBatch,
    pub committed_candidate_ids: Vec<String>,
}
pub struct ValidatedRenderEntry {
    pub item_id: String,
    pub candidate_id: String,
    pub image: StoredImage,
    pub normalized_bytes: Arc<Vec<u8>>,
}
impl std::fmt::Debug for ValidatedRenderEntry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ValidatedRenderEntry")
            .field("item_id", &self.item_id)
            .field("candidate_id", &self.candidate_id)
            .field("image_id", &self.image.id)
            .field("normalized_byte_len", &self.normalized_bytes.len())
            .finish()
    }
}
#[derive(Debug)]
pub struct RenderFailure {
    pub candidate_id: String,
    pub error: ServiceError,
}
#[derive(Debug)]
pub enum ServiceEvent {
    Inspected {
        operation_id: OperationId,
        thread_id: String,
        generation: u64,
        plan_id: PlanId,
        source_thread_sha256: String,
        candidates: Vec<Candidate>,
        next_item_offset: Option<usize>,
        limits: Vec<InspectionLimit>,
        expires_in_seconds: u64,
    },
    Validated {
        operation_id: OperationId,
        thread_id: String,
        generation: u64,
        preview_id: PreviewId,
        source_thread_sha256: String,
        references: Vec<CheckedReference>,
        expires_in_seconds: u64,
    },
    Finished {
        operation_id: OperationId,
        receipt_id: ReceiptId,
    },
    Rendered {
        operation_id: OperationId,
        thread_id: String,
        generation: u64,
        entries: Vec<ValidatedRenderEntry>,
        failures: Vec<RenderFailure>,
    },
    Failed {
        operation_id: OperationId,
        thread_id: Option<String>,
        generation: u64,
        error: ServiceError,
    },
}
#[derive(Clone)]
struct Control {
    state: Arc<AtomicU8>,
    selection: SelectionToken,
}
impl Control {
    fn check(&self) -> ServiceResult<()> {
        if self.state.load(Ordering::SeqCst) == CANCELLED {
            return Err(ServiceError::Cancelled);
        }
        check_selection(&self.selection)
    }
    fn cancel(&self) -> CancelAck {
        loop {
            let state = self.state.load(Ordering::SeqCst);
            match state {
                QUEUED | RUNNING => {
                    if self
                        .state
                        .compare_exchange(state, CANCELLED, Ordering::SeqCst, Ordering::SeqCst)
                        .is_ok()
                    {
                        return CancelAck::Requested;
                    }
                }
                CANCELLED => return CancelAck::Requested,
                COMMITTING => return CancelAck::TooLateMayCommit,
                _ => return CancelAck::Finished,
            }
        }
    }
}
fn check_selection(selection: &SelectionToken) -> ServiceResult<()> {
    if selection.thread.is_none() {
        return Err(ServiceError::InvalidSelection);
    }
    if !selection.active.load(Ordering::SeqCst) {
        return Err(ServiceError::SelectionChanged);
    }
    Ok(())
}
fn check_roots(cap: &RootCapability) -> ServiceResult<()> {
    check_selection(&cap.selection)?;
    if !cap.active.load(Ordering::SeqCst) {
        return Err(ServiceError::RootRevoked);
    }
    if Instant::now() >= cap.expires {
        return Err(ServiceError::Expired);
    }
    Ok(())
}
fn same_selection(a: &SelectionToken, b: &SelectionToken) -> bool {
    a.owner == b.owner && a.generation == b.generation && a.thread == b.thread
}
enum Command {
    Inspect(RootCapability, usize),
    Validate(PlanId, Vec<String>),
    Confirm(PreviewId, Vec<String>),
    Render(Vec<String>),
}
struct Job {
    id: OperationId,
    control: Control,
    command: Command,
    reserved_receipt: bool,
}
type Results = Arc<Mutex<HashMap<OperationId, ServiceEvent>>>;
type Receipts = Arc<Mutex<HashMap<ReceiptId, Arc<CompletionReceipt>>>>;
pub struct LegacyMediaService {
    owner: Uuid,
    generation: u64,
    selection: SelectionToken,
    tx: Option<SyncSender<Job>>,
    completion: crate::agent::WorkerCompletion,
    results: Results,
    receipts: Receipts,
    receipt_slots: Arc<AtomicUsize>,
    operations: HashMap<OperationId, Control>,
    caps: HashMap<Uuid, RootCapability>,
}
impl LegacyMediaService {
    /// All filesystem/database initialization happens on the spawned worker.
    pub fn spawn(config: ServiceConfig) -> Self {
        let (tx, rx) = mpsc::sync_channel::<Job>(8);
        let results = Arc::new(Mutex::new(HashMap::new()));
        let receipts = Arc::new(Mutex::new(HashMap::new()));
        let slots = Arc::new(AtomicUsize::new(0));
        let (out, recover, reserved) = (results.clone(), receipts.clone(), slots.clone());
        let worker = std::thread::spawn(move || {
            let worker = Worker::open(config);
            let mut worker = worker.ok();
            while let Ok(job) = rx.recv() {
                let id = job.id;
                let control = job.control.clone();
                let mut receipt_kept = false;
                let outcome = if control
                    .state
                    .compare_exchange(QUEUED, RUNNING, Ordering::SeqCst, Ordering::SeqCst)
                    .is_err()
                {
                    Err(ServiceError::Cancelled)
                } else if let Some(worker) = worker.as_mut() {
                    worker.execute(job.id, &control, job.command, &recover, &mut receipt_kept)
                } else {
                    Err(ServiceError::StoreUnavailable)
                };
                if job.reserved_receipt && !receipt_kept {
                    reserved.fetch_sub(1, Ordering::SeqCst);
                }
                control.state.store(FINISHED, Ordering::SeqCst);
                let event = outcome.unwrap_or_else(|error| ServiceEvent::Failed {
                    operation_id: id,
                    thread_id: control.selection.thread.clone(),
                    generation: control.selection.generation,
                    error,
                });
                out.lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(id, event);
            }
        });
        let owner = Uuid::new_v4();
        let selection = SelectionToken {
            owner,
            thread: None,
            generation: 0,
            active: Arc::new(AtomicBool::new(false)),
        };
        Self {
            owner,
            generation: 0,
            selection,
            tx: Some(tx),
            completion: crate::agent::WorkerCompletion::observe(worker),
            results,
            receipts,
            receipt_slots: slots,
            operations: HashMap::new(),
            caps: HashMap::new(),
        }
    }
    /// Close native admissions, cancel uncommitted work, and let the owned
    /// worker drain its queue. Committing work and every receipt remain owned.
    pub fn request_shutdown(&mut self) {
        self.selection.active.store(false, Ordering::SeqCst);
        for control in self.operations.values() {
            control.cancel();
        }
        for cap in self.caps.values() {
            cap.active.store(false, Ordering::SeqCst);
        }
        self.tx.take();
    }
    /// Does not consume completion events or acknowledge retained image receipts.
    pub fn shutdown_status(&self) -> ServiceShutdownStatus {
        ServiceShutdownStatus {
            requested: self.tx.is_none(),
            worker: self.completion.status(),
            operations: self.operations.len(),
            retained_receipts: self.receipts.try_lock().ok().map(|r| r.len()),
        }
    }
    pub fn select_thread(&mut self, thread_id: Option<String>) -> SelectionToken {
        self.selection.active.store(false, Ordering::SeqCst);
        for control in self.operations.values() {
            control.cancel();
        }
        for cap in self.caps.values() {
            cap.active.store(false, Ordering::SeqCst);
        }
        self.caps.clear();
        self.generation = self.generation.wrapping_add(1);
        let valid = thread_id
            .as_deref()
            .is_some_and(|id| Uuid::parse_str(id).is_ok());
        self.selection = SelectionToken {
            owner: self.owner,
            thread: thread_id,
            generation: self.generation,
            active: Arc::new(AtomicBool::new(valid && self.tx.is_some())),
        };
        self.selection.clone()
    }
    fn selection_ok(&self, selection: &SelectionToken) -> ServiceResult<()> {
        if self.tx.is_none() {
            return Err(ServiceError::Cancelled);
        }
        if !same_selection(selection, &self.selection) {
            return Err(ServiceError::InvalidSelection);
        }
        check_selection(selection)
    }
    pub fn approve_roots_native(
        &mut self,
        selection: &SelectionToken,
        roots: Vec<ApprovedRoot>,
        relative_base_root_id: Option<String>,
    ) -> ServiceResult<RootCapability> {
        self.selection_ok(selection)?;
        self.caps
            .retain(|_, c| c.active.load(Ordering::SeqCst) && Instant::now() < c.expires);
        if roots.is_empty() || roots.len() > 32 || self.caps.len() >= 8 {
            return Err(ServiceError::RootApprovalRequired);
        }
        let cap = RootCapability {
            id: Uuid::new_v4(),
            selection: selection.clone(),
            roots,
            relative_base: relative_base_root_id,
            expires: Instant::now() + ROOT_TTL,
            active: Arc::new(AtomicBool::new(true)),
        };
        self.caps.insert(cap.id, cap.clone());
        Ok(cap)
    }
    fn enqueue(
        &mut self,
        selection: &SelectionToken,
        command: Command,
        reserve: bool,
    ) -> ServiceResult<OperationId> {
        if self.tx.is_none() {
            return Err(ServiceError::Cancelled);
        }
        self.selection_ok(selection)?;
        if self.operations.len() >= 9 {
            return Err(ServiceError::QueueFull);
        }
        if reserve {
            let mut slots = self.receipt_slots.load(Ordering::SeqCst);
            loop {
                if slots >= MAX_RECEIPTS {
                    return Err(ServiceError::RecoveryRequired);
                }
                match self.receipt_slots.compare_exchange(
                    slots,
                    slots + 1,
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                ) {
                    Ok(_) => break,
                    Err(current) => slots = current,
                }
            }
        }
        let id = OperationId(Uuid::new_v4());
        let control = Control {
            state: Arc::new(AtomicU8::new(QUEUED)),
            selection: selection.clone(),
        };
        if self
            .tx
            .as_ref()
            .ok_or(ServiceError::Cancelled)?
            .try_send(Job {
                id,
                control: control.clone(),
                command,
                reserved_receipt: reserve,
            })
            .is_err()
        {
            if reserve {
                self.receipt_slots.fetch_sub(1, Ordering::SeqCst);
            }
            return Err(ServiceError::QueueFull);
        }
        self.operations.insert(id, control);
        Ok(id)
    }
    pub fn inspect(
        &mut self,
        selection: &SelectionToken,
        roots: &RootCapability,
        item_offset: usize,
    ) -> ServiceResult<OperationId> {
        self.selection_ok(selection)?;
        if !same_selection(selection, &roots.selection) || !self.caps.contains_key(&roots.id) {
            return Err(ServiceError::RootApprovalRequired);
        }
        check_roots(roots)?;
        self.enqueue(
            selection,
            Command::Inspect(roots.clone(), item_offset),
            false,
        )
    }
    pub fn validate(
        &mut self,
        selection: &SelectionToken,
        plan: PlanId,
        candidate_ids: Vec<String>,
    ) -> ServiceResult<OperationId> {
        self.enqueue(selection, Command::Validate(plan, candidate_ids), false)
    }
    pub fn confirm(
        &mut self,
        selection: &SelectionToken,
        preview: PreviewId,
        candidate_ids: Vec<String>,
    ) -> ServiceResult<OperationId> {
        self.enqueue(selection, Command::Confirm(preview, candidate_ids), true)
    }
    pub fn load_visible(
        &mut self,
        selection: &SelectionToken,
        item_ids: Vec<String>,
    ) -> ServiceResult<OperationId> {
        if item_ids.len() > 20 {
            return Err(ServiceError::InvalidCandidates);
        }
        self.enqueue(selection, Command::Render(item_ids), false)
    }
    pub fn cancel(&mut self, operation: OperationId) -> CancelAck {
        self.operations
            .get(&operation)
            .map_or(CancelAck::UnknownOperation, Control::cancel)
    }
    pub fn revoke_roots(&mut self, cap: RootCapability) {
        if let Some(known) = self.caps.remove(&cap.id) {
            known.active.store(false, Ordering::SeqCst);
            for control in self
                .operations
                .values()
                .filter(|c| same_selection(&c.selection, &known.selection))
            {
                control.cancel();
            }
        }
    }
    pub fn poll(&mut self) -> Vec<ServiceEvent> {
        let Ok(mut results) = self.results.try_lock() else {
            return Vec::new();
        };
        let events = results.drain().collect::<Vec<_>>();
        drop(results);
        events
            .into_iter()
            .map(|(id, event)| {
                self.operations.remove(&id);
                event
            })
            .collect()
    }
    pub fn receipt(&self, id: ReceiptId) -> Option<Arc<CompletionReceipt>> {
        self.receipts.try_lock().ok()?.get(&id).cloned()
    }
    /// Native parent must durably take ownership/reconcile uncommitted images first.
    pub fn acknowledge_receipt(&mut self, id: ReceiptId) -> ServiceResult<()> {
        let mut receipts = self.receipts.try_lock().map_err(|_| ServiceError::Busy)?;
        if receipts.remove(&id).is_none() {
            return Err(ServiceError::InvalidCandidates);
        }
        self.receipt_slots.fetch_sub(1, Ordering::SeqCst);
        Ok(())
    }
    pub fn pending_recovery(&self) -> Vec<ReceiptId> {
        self.receipts
            .try_lock()
            .map(|r| {
                r.iter()
                    .filter(|(_, r)| {
                        r.batch.references.iter().any(|entry| {
                            entry.image.is_some()
                                && !r
                                    .committed_candidate_ids
                                    .contains(&entry.reference.candidate.candidate_id)
                        })
                    })
                    .map(|(id, _)| *id)
                    .collect()
            })
            .unwrap_or_default()
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ServiceShutdownStatus {
    pub requested: bool,
    pub worker: crate::agent::WorkerThreadStatus,
    pub operations: usize,
    /// None means the receipt registry is busy, never empty.
    pub retained_receipts: Option<usize>,
}
impl ServiceShutdownStatus {
    pub fn ready(&self) -> bool {
        self.requested
            && self.worker == crate::agent::WorkerThreadStatus::Returned
            && self.operations == 0
            && self.retained_receipts == Some(0)
    }
}
impl Drop for LegacyMediaService {
    fn drop(&mut self) {
        self.request_shutdown();
    }
}
struct PlanRecord {
    selection: SelectionToken,
    cap: RootCapability,
    thread: Arc<Value>,
    overlay: Option<Value>,
    plan: MediaPlan,
    expires: Instant,
}
struct PreviewRecord {
    record: PlanRecord,
    preview: MediaPreview,
    validated: Vec<String>,
    expires: Instant,
}
struct Worker {
    store: Store,
    config: ServiceConfig,
    identity: Metadata,
    data: PathBuf,
    plans: HashMap<PlanId, PlanRecord>,
    previews: HashMap<PreviewId, PreviewRecord>,
    consumed: Vec<PreviewId>,
    #[cfg(test)]
    after_materialize: Option<Box<dyn FnOnce() + Send>>,
}
impl Worker {
    fn open(config: ServiceConfig) -> Result<Self> {
        let held = open_regular_existing(&config.database_path)?;
        let identity = held.metadata()?;
        let store = Store::open_existing_for_legacy_media(
            &config.database_path,
            &config.expected_data_directory,
        )?;
        ensure!(
            same_file(
                &identity,
                &open_regular_existing(&config.database_path)?.metadata()?
            ),
            "Database replaced during startup"
        );
        let data = store.data_directory()?;
        Ok(Self {
            store,
            config,
            identity,
            data,
            plans: HashMap::new(),
            previews: HashMap::new(),
            consumed: Vec::new(),
            #[cfg(test)]
            after_materialize: None,
        })
    }
    fn database_ok(&self) -> ServiceResult<()> {
        let file = open_regular_existing(&self.config.database_path)
            .map_err(|_| ServiceError::StoreUnavailable)?;
        if !same_file(
            &self.identity,
            &file
                .metadata()
                .map_err(|_| ServiceError::StoreUnavailable)?,
        ) {
            return Err(ServiceError::StoreUnavailable);
        }
        Ok(())
    }
    fn cleanup(&mut self) {
        let now = Instant::now();
        self.plans
            .retain(|_, r| now < r.expires && check_roots(&r.cap).is_ok());
        self.previews
            .retain(|_, r| now < r.expires && check_roots(&r.record.cap).is_ok());
    }
    fn record_ok(&self, record: &PlanRecord, control: &Control) -> ServiceResult<()> {
        control.check()?;
        if !same_selection(&record.selection, &control.selection) {
            return Err(ServiceError::InvalidSelection);
        }
        check_roots(&record.cap)?;
        if Instant::now() >= record.expires {
            return Err(ServiceError::Expired);
        }
        let current = self
            .store
            .thread(record.selection.thread.as_deref().unwrap())
            .map_err(|_| ServiceError::ThreadMissing)?;
        if current != *record.thread {
            return Err(ServiceError::ThreadChanged);
        }
        Ok(())
    }
    fn execute(
        &mut self,
        id: OperationId,
        control: &Control,
        command: Command,
        receipts: &Receipts,
        kept: &mut bool,
    ) -> ServiceResult<ServiceEvent> {
        self.database_ok()?;
        control.check()?;
        let thread_id = control
            .selection
            .thread
            .clone()
            .ok_or(ServiceError::InvalidSelection)?;
        match command {
            Command::Inspect(cap, item_offset) => {
                self.cleanup();
                check_roots(&cap)?;
                if !same_selection(&cap.selection, &control.selection) {
                    return Err(ServiceError::InvalidSelection);
                }
                if self.plans.len() + self.previews.len() >= MAX_REGISTRY {
                    return Err(ServiceError::Busy);
                }
                let thread = self
                    .store
                    .thread(&thread_id)
                    .map_err(|_| ServiceError::ThreadMissing)?;
                let overlay = self
                    .store
                    .local_document(
                        &overlay_name(&thread_id).map_err(|_| ServiceError::InvalidSelection)?,
                    )
                    .map_err(|_| ServiceError::InvalidOverlay)?;
                let plan = media::inspect(
                    &thread,
                    &cap.roots,
                    InspectOptions {
                        item_offset,
                        relative_base_root_id: cap.relative_base.clone(),
                    },
                )
                .map_err(|_| ServiceError::InvalidCandidates)?;
                control.check()?;
                check_roots(&cap)?;
                let plan_id = PlanId(Uuid::new_v4());
                let expires = cap.expires.min(Instant::now() + ROOT_TTL);
                let event = ServiceEvent::Inspected {
                    operation_id: id,
                    thread_id,
                    generation: control.selection.generation,
                    plan_id,
                    source_thread_sha256: plan.thread_sha256().into(),
                    candidates: plan.candidates().to_vec(),
                    next_item_offset: plan.next_item_offset(),
                    limits: plan.inspection_limits().to_vec(),
                    expires_in_seconds: expires.saturating_duration_since(Instant::now()).as_secs(),
                };
                self.plans.insert(
                    plan_id,
                    PlanRecord {
                        selection: control.selection.clone(),
                        cap,
                        thread: Arc::new(thread),
                        overlay,
                        plan,
                        expires,
                    },
                );
                Ok(event)
            }
            Command::Validate(plan_id, ids) => {
                let record = self
                    .plans
                    .remove(&plan_id)
                    .ok_or(ServiceError::UnknownPlan)?;
                self.record_ok(&record, control)?;
                let preview = media::validate(&record.plan, &ids)
                    .map_err(|_| ServiceError::InvalidCandidates)?;
                self.record_ok(&record, control)?;
                let expires = record.expires.min(Instant::now() + PREVIEW_TTL);
                let preview_id = PreviewId(Uuid::new_v4());
                let event = ServiceEvent::Validated {
                    operation_id: id,
                    thread_id,
                    generation: control.selection.generation,
                    preview_id,
                    source_thread_sha256: preview.thread_sha256().into(),
                    references: preview.references().to_vec(),
                    expires_in_seconds: expires.saturating_duration_since(Instant::now()).as_secs(),
                };
                self.previews.insert(
                    preview_id,
                    PreviewRecord {
                        record,
                        preview,
                        validated: ids,
                        expires,
                    },
                );
                Ok(event)
            }
            Command::Confirm(preview_id, ids) => {
                if self.consumed.contains(&preview_id) {
                    return Err(ServiceError::AlreadyConsumed);
                }
                let preview = self
                    .previews
                    .get(&preview_id)
                    .ok_or(ServiceError::UnknownPreview)?;
                self.record_ok(&preview.record, control)?;
                if Instant::now() >= preview.expires {
                    return Err(ServiceError::Expired);
                }
                if ids.is_empty()
                    || ids.len() > 20
                    || ids.iter().any(|id| {
                        !preview.validated.contains(id)
                            || !preview.preview.references().iter().any(|r| {
                                &r.candidate.candidate_id == id && r.status == Status::Ready
                            })
                    })
                {
                    return Err(ServiceError::InvalidCandidates);
                }
                let preview = self
                    .previews
                    .remove(&preview_id)
                    .expect("validated preview exists");
                self.consumed.push(preview_id);
                if self.consumed.len() > 64 {
                    self.consumed.remove(0);
                }
                let batch = media::materialize(&preview.preview, &ids, &self.data)
                    .map_err(|_| ServiceError::InvalidCandidates)?;
                #[cfg(test)]
                if let Some(hook) = self.after_materialize.take() {
                    hook();
                }
                // No fallible early return after materialization: every created ID
                // must reach a retained receipt even on cancellation/commit errors.
                let result = (|| -> ServiceResult<Vec<String>> {
                    self.record_ok(&preview.record, control)?;
                    if !batch.references.iter().any(|r| {
                        r.reference.status == Status::Materialized
                            && r.image.is_some()
                            && r.validation_error.is_none()
                    }) {
                        return Err(ServiceError::InvalidCandidates);
                    }
                    if Instant::now() >= preview.expires {
                        return Err(ServiceError::Expired);
                    }
                    self.database_ok()?;
                    let next = merge_overlay(
                        &preview.record.thread,
                        preview.record.overlay.as_ref(),
                        &batch,
                    )
                    .map_err(|error| {
                        if error.to_string().contains("Overlay limit") {
                            ServiceError::OverlayLimit
                        } else {
                            ServiceError::InvalidOverlay
                        }
                    })?;
                    if control
                        .state
                        .compare_exchange(RUNNING, COMMITTING, Ordering::SeqCst, Ordering::SeqCst)
                        .is_err()
                    {
                        return Err(ServiceError::Cancelled);
                    }
                    check_selection(&control.selection)?;
                    check_roots(&preview.record.cap)?;
                    if let Err(error) = self.store.commit_legacy_media_overlay_if_unchanged(
                        &preview.record.thread,
                        preview.record.overlay.as_ref(),
                        &next,
                    ) {
                        let text = error.to_string();
                        if text.contains("thread changed") {
                            return Err(ServiceError::ThreadChanged);
                        }
                        if text.contains("overlay changed") {
                            return Err(ServiceError::OverlayChanged);
                        }
                        match self.store.local_document(
                            &overlay_name(&thread_id).map_err(|_| ServiceError::InvalidOverlay)?,
                        ) {
                            Ok(Some(actual)) if actual == next => {}
                            Ok(actual) if actual.as_ref() == preview.record.overlay.as_ref() => {
                                return Err(ServiceError::CommitFailed);
                            }
                            _ => return Err(ServiceError::CommitUnknown),
                        }
                    }
                    Ok(batch
                        .references
                        .iter()
                        .filter(|r| {
                            r.reference.status == Status::Materialized
                                && r.image.is_some()
                                && r.validation_error.is_none()
                        })
                        .map(|r| r.reference.candidate.candidate_id.clone())
                        .collect())
                })();
                let (committed, error, committed_ids) = match result {
                    Ok(ids) => (true, None, ids),
                    Err(error) => (false, Some(error), Vec::new()),
                };
                let receipt_id = ReceiptId(Uuid::new_v4());
                let receipt = CompletionReceipt {
                    operation_id: id,
                    thread_id,
                    generation: control.selection.generation,
                    committed,
                    error,
                    batch,
                    committed_candidate_ids: committed_ids,
                };
                receipts
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(receipt_id, Arc::new(receipt));
                *kept = true;
                Ok(ServiceEvent::Finished {
                    operation_id: id,
                    receipt_id,
                })
            }
            Command::Render(items) => {
                let thread = self
                    .store
                    .thread(&thread_id)
                    .map_err(|_| ServiceError::ThreadMissing)?;
                let overlay = self
                    .store
                    .local_document(
                        &overlay_name(&thread_id).map_err(|_| ServiceError::InvalidSelection)?,
                    )
                    .map_err(|_| ServiceError::InvalidOverlay)?;
                let Some(overlay) = overlay else {
                    return Ok(ServiceEvent::Rendered {
                        operation_id: id,
                        thread_id,
                        generation: control.selection.generation,
                        entries: Vec::new(),
                        failures: Vec::new(),
                    });
                };
                let current_hash = thread_hash(&thread).map_err(|_| ServiceError::ThreadChanged)?;
                if overlay["sourceThreadSha256"].as_str() != Some(current_hash.as_str()) {
                    return Err(ServiceError::ThreadChanged);
                }
                validate_overlay(&thread, &overlay).map_err(|_| ServiceError::InvalidOverlay)?;
                let (mut entries, mut failures) = (Vec::new(), Vec::new());
                for entry in overlay["entries"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter(|e| items.iter().any(|id| e["itemId"] == *id))
                    .take(8)
                {
                    control.check()?;
                    let candidate_id = entry["candidateId"].as_str().unwrap_or_default().to_owned();
                    let result = (|| -> Result<ValidatedRenderEntry> {
                        let image: StoredImage = serde_json::from_value(entry["image"].clone())?;
                        image.prepare_in(&self.data)?;
                        let original = managed_bytes(
                            &self.data,
                            &image.original_path,
                            crate::attachments::MAX_SOURCE_BYTES,
                        )?;
                        ensure!(
                            entry["sourceSha256"] == hash(&original),
                            "Original hash mismatch"
                        );
                        let bytes = managed_bytes(
                            &self.data,
                            &image.path,
                            crate::attachments::MAX_NORMALIZED_BYTES,
                        )?;
                        ensure!(
                            entry["normalizedSha256"] == hash(&bytes),
                            "Normalized hash mismatch"
                        );
                        Ok(ValidatedRenderEntry {
                            item_id: entry["itemId"].as_str().unwrap().into(),
                            candidate_id: candidate_id.clone(),
                            image,
                            normalized_bytes: Arc::new(bytes),
                        })
                    })();
                    match result {
                        Ok(entry) => entries.push(entry),
                        Err(_) => failures.push(RenderFailure {
                            candidate_id,
                            error: ServiceError::InvalidOverlay,
                        }),
                    }
                }
                control.check()?;
                if self
                    .store
                    .thread(&thread_id)
                    .map_err(|_| ServiceError::ThreadMissing)?
                    != thread
                {
                    return Err(ServiceError::ThreadChanged);
                }
                Ok(ServiceEvent::Rendered {
                    operation_id: id,
                    thread_id,
                    generation: control.selection.generation,
                    entries,
                    failures,
                })
            }
        }
    }
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn thread_hash(thread: &Value) -> Result<String> {
    let bytes = serde_json::to_vec(thread)?;
    ensure!(bytes.len() <= MAX_THREAD, "Thread too large");
    Ok(hash(&bytes))
}
pub fn overlay_name(thread_id: &str) -> Result<String> {
    Ok(format!(
        "rust-legacy-media-{}.json",
        Uuid::parse_str(thread_id)?
    ))
}
fn hash_string(value: &Value) -> bool {
    value
        .as_str()
        .is_some_and(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
}
pub(crate) fn validate_overlay(thread: &Value, overlay: &Value) -> Result<()> {
    let id = thread["id"].as_str().context("Missing thread ID")?;
    Uuid::parse_str(id)?;
    ensure!(
        overlay["version"] == 1
            && overlay["threadId"] == id
            && overlay["sourceThreadSha256"] == thread_hash(thread)?,
        "Invalid overlay binding"
    );
    let entries = overlay["entries"]
        .as_array()
        .context("Missing overlay entries")?;
    ensure!(
        entries.len() <= 1000 && serde_json::to_vec(overlay)?.len() <= MAX_OVERLAY,
        "Overlay limit"
    );
    let items = thread["items"].as_array().context("Missing transcript")?;
    let mut seen = std::collections::HashSet::new();
    for entry in entries {
        let candidate = entry["candidateId"]
            .as_str()
            .context("Missing candidate ID")?;
        ensure!(
            hash_string(&entry["candidateId"]) && seen.insert(candidate),
            "Duplicate/invalid candidate"
        );
        let item_index =
            usize::try_from(entry["itemIndex"].as_u64().context("Missing item index")?)?;
        let attachment = usize::try_from(
            entry["attachmentIndex"]
                .as_u64()
                .context("Missing reference index")?,
        )?;
        let item = items.get(item_index).context("Missing item")?;
        ensure!(item["id"] == entry["itemId"], "Item identity changed");
        Uuid::parse_str(entry["itemId"].as_str().context("Invalid item ID")?)?;
        let raw = item["attachments"]
            .as_array()
            .and_then(|a| a.get(attachment))
            .context("Missing reference")?;
        ensure!(
            raw.is_string() && entry["rawReferenceSha256"] == hash(&serde_json::to_vec(raw)?),
            "Reference changed"
        );
        ensure!(
            candidate
                == hash(&serde_json::to_vec(&json!([
                    id, item_index, item["id"], attachment, raw
                ]))?),
            "Candidate binding changed"
        );
        ensure!(
            hash_string(&entry["sourceSha256"]) && hash_string(&entry["normalizedSha256"]),
            "Invalid media hash"
        );
        let image: StoredImage = serde_json::from_value(entry["image"].clone())?;
        Uuid::parse_str(&image.id)?;
    }
    Ok(())
}
fn merge_overlay(thread: &Value, old: Option<&Value>, batch: &MediaBatch) -> Result<Value> {
    let mut overlay = if let Some(old) = old {
        validate_overlay(thread, old)?;
        old.clone()
    } else {
        json!({"version":1,"threadId":thread["id"],"sourceThreadSha256":thread_hash(thread)?,"entries":[]})
    };
    for result in &batch.references {
        if result.reference.status != Status::Materialized || result.validation_error.is_some() {
            continue;
        }
        let Some(image) = &result.image else { continue };
        let reference = &result.reference;
        let c = &reference.candidate;
        let entry = json!({"candidateId":c.candidate_id,"itemId":c.item_id,"itemIndex":c.item_index,"attachmentIndex":c.attachment_index,
            "rawReferenceSha256":hash(&serde_json::to_vec(&c.raw_reference)?),"sourceSha256":reference.source_sha256,"normalizedSha256":result.normalized_sha256,"image":image});
        let entries = overlay["entries"].as_array_mut().unwrap();
        if let Some(old) = entries
            .iter_mut()
            .find(|e| e["candidateId"] == c.candidate_id)
        {
            *old = entry
        } else {
            entries.push(entry)
        }
    }
    validate_overlay(thread, &overlay)?;
    Ok(overlay)
}

/// Strict regular-file open of an absolute path without following ANY symlink.
pub(crate) fn open_regular_existing(path: &Path) -> Result<File> {
    #[cfg(unix)]
    {
        use std::{
            ffi::CString,
            os::{
                fd::{AsRawFd, FromRawFd},
                unix::ffi::OsStrExt,
            },
        };
        ensure!(
            path.is_absolute()
                && path
                    .to_str()
                    .is_some_and(|s| !s.split('/').any(|p| matches!(p, "." | ".."))),
            "Path must be absolute without traversal"
        );
        let parts = path.components().collect::<Vec<_>>();
        let mut directory = File::open("/")?;
        for (index, part) in parts.iter().enumerate().skip(1) {
            let Component::Normal(name) = part else {
                anyhow::bail!("Invalid path")
            };
            let name = CString::new(name.as_bytes())?;
            let last = index == parts.len() - 1;
            // SAFETY: owned directory FD, single NUL-terminated component.
            let fd = unsafe {
                libc::openat(
                    directory.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY
                        | libc::O_CLOEXEC
                        | libc::O_NOFOLLOW
                        | libc::O_NONBLOCK
                        | if last { 0 } else { libc::O_DIRECTORY },
                )
            };
            if fd < 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            // SAFETY: newly-opened FD transfers to File exactly once.
            let file = unsafe { File::from_raw_fd(fd) };
            if last {
                ensure!(file.metadata()?.is_file(), "Expected regular file");
                return Ok(file);
            }
            directory = file;
        }
        anyhow::bail!("Missing file")
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        anyhow::bail!("Safe relative-handle media service is unsupported on this platform")
    }
}
pub(crate) fn same_file(a: &Metadata, b: &Metadata) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        a.dev() == b.dev() && a.ino() == b.ino()
    }
    #[cfg(not(unix))]
    {
        let _ = (a, b);
        false
    }
}
pub(crate) fn verify_database_identity(
    path: &Path,
    held: &File,
    db: &rusqlite::Connection,
) -> Result<()> {
    ensure!(
        db.path().map(Path::new) == Some(path),
        "SQLite opened another database path"
    );
    ensure!(
        same_file(&held.metadata()?, &open_regular_existing(path)?.metadata()?),
        "Database path replaced"
    );
    let mut moved: std::ffi::c_int = 0;
    // SAFETY: valid live SQLite connection and pointer to an integer result.
    let rc = unsafe {
        rusqlite::ffi::sqlite3_file_control(
            db.handle(),
            c"main".as_ptr(),
            rusqlite::ffi::SQLITE_FCNTL_HAS_MOVED,
            (&mut moved as *mut std::ffi::c_int).cast(),
        )
    };
    ensure!(
        rc == rusqlite::ffi::SQLITE_OK && moved == 0,
        "SQLite database identity changed or cannot be verified"
    );
    Ok(())
}
fn managed_bytes(root: &Path, path: &Path, limit: u64) -> Result<Vec<u8>> {
    ensure!(
        path.starts_with(root),
        "Managed image outside data directory"
    );
    let file = open_regular_existing(path)?;
    let before = file.metadata()?;
    ensure!(
        before.len() > 0 && before.len() <= limit,
        "Managed image byte limit"
    );
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 == before.len(), "Managed image changed");
    Ok(bytes)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use image::{DynamicImage, ImageFormat};
    use std::{fs, os::unix::fs::symlink};
    const ITEM: &str = "00000000-0000-4000-8000-000000000002";
    #[test]
    fn explicit_shutdown_drains_worker_without_reopening_admissions_or_mutating_source() {
        let fixture = fixture();
        let before = fs::read(&fixture.config.database_path).unwrap();
        let (mut service, selection, _) = setup(&fixture);
        assert!(!service.shutdown_status().ready());
        service.request_shutdown();
        service.request_shutdown();
        assert!(!selection.accepts(fixture.thread["id"].as_str().unwrap(), selection.generation));
        let later = service.select_thread(Some(fixture.thread["id"].as_str().unwrap().into()));
        assert!(matches!(
            service.load_visible(&later, vec![]),
            Err(ServiceError::Cancelled)
        ));
        let deadline = Instant::now() + Duration::from_secs(3);
        while service.shutdown_status().worker == crate::agent::WorkerThreadStatus::Running {
            assert!(Instant::now() < deadline, "media worker failed to join");
            std::thread::yield_now();
        }
        assert!(service.shutdown_status().ready());
        assert_eq!(fs::read(&fixture.config.database_path).unwrap(), before);
        let held = service.receipts.lock().unwrap();
        assert_eq!(service.shutdown_status().retained_receipts, None);
        assert!(!service.shutdown_status().ready());
        drop(held);
    }
    struct Fixture {
        _dir: tempfile::TempDir,
        config: ServiceConfig,
        thread: Value,
        source: PathBuf,
        root: ApprovedRoot,
    }
    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().canonicalize().unwrap();
        let source = base.join("source");
        fs::create_dir(&source).unwrap();
        let mut png = std::io::Cursor::new(Vec::new());
        DynamicImage::new_rgba8(2, 2)
            .write_to(&mut png, ImageFormat::Png)
            .unwrap();
        fs::write(source.join("image.png"), png.into_inner()).unwrap();
        let database_path = base.join("rust/state.sqlite");
        let mut store = Store::open(&database_path).unwrap();
        let mut thread = store
            .new_thread("00000000-0000-0000-0000-000000000000")
            .unwrap();
        thread["items"] = json!([{"id":ITEM,"kind":"user","text":"old","attachments":["/legacy/image.png"],"unknown":{"keep":true}}]);
        thread["draft"] = json!("Preserve unsent draft");
        store.save(&thread).unwrap();
        store
            .save_document("bots.json", &json!({"fixtureBot":"unchanged"}))
            .unwrap();
        drop(store);
        let root = ApprovedRoot::new(
            "native-approved".into(),
            PathBuf::from("/legacy"),
            source.clone(),
        )
        .unwrap();
        let expected_data_directory = database_path.parent().unwrap().to_owned();
        Fixture {
            _dir: dir,
            config: ServiceConfig {
                database_path,
                expected_data_directory,
            },
            thread,
            source,
            root,
        }
    }
    fn event_id(event: &ServiceEvent) -> OperationId {
        match event {
            ServiceEvent::Inspected { operation_id, .. }
            | ServiceEvent::Validated { operation_id, .. }
            | ServiceEvent::Finished { operation_id, .. }
            | ServiceEvent::Rendered { operation_id, .. }
            | ServiceEvent::Failed { operation_id, .. } => *operation_id,
        }
    }
    fn wait(service: &mut LegacyMediaService, id: OperationId) -> ServiceEvent {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            for event in service.poll() {
                if event_id(&event) == id {
                    return event;
                }
            }
            assert!(Instant::now() < deadline, "service timeout");
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    fn setup(fixture: &Fixture) -> (LegacyMediaService, SelectionToken, RootCapability) {
        let mut service = LegacyMediaService::spawn(fixture.config.clone());
        let selection = service.select_thread(Some(fixture.thread["id"].as_str().unwrap().into()));
        let cap = service
            .approve_roots_native(&selection, vec![fixture.root.clone()], None)
            .unwrap();
        (service, selection, cap)
    }
    fn preview(
        service: &mut LegacyMediaService,
        selection: &SelectionToken,
        cap: &RootCapability,
    ) -> (PreviewId, Vec<String>) {
        let op = service.inspect(selection, cap, 0).unwrap();
        let ServiceEvent::Inspected {
            plan_id,
            candidates,
            ..
        } = wait(service, op)
        else {
            panic!("inspect")
        };
        let ids = candidates
            .iter()
            .map(|c| c.candidate_id.clone())
            .collect::<Vec<_>>();
        let op = service.validate(selection, plan_id, ids.clone()).unwrap();
        let ServiceEvent::Validated {
            preview_id,
            references,
            ..
        } = wait(service, op)
        else {
            panic!("preview")
        };
        assert_eq!(references[0].status, Status::Ready);
        (preview_id, ids)
    }
    #[test]
    fn restores_local_overlay_and_worker_verifies_render_without_mutating_threads() {
        let f = fixture();
        let original = fs::read(f.source.join("image.png")).unwrap();
        let (mut service, selection, cap) = setup(&f);
        let (p, ids) = preview(&mut service, &selection, &cap);
        let op = service.confirm(&selection, p, ids).unwrap();
        let ServiceEvent::Finished { receipt_id, .. } = wait(&mut service, op) else {
            panic!("receipt")
        };
        let receipt = service.receipt(receipt_id).unwrap();
        assert_eq!(service.receipt_slots.load(Ordering::SeqCst), 1);
        assert!(receipt.committed, "{:?}", receipt.error);
        assert_eq!(receipt.batch.references.len(), 1);
        let store = Store::open_existing_for_legacy_media(
            &f.config.database_path,
            &f.config.expected_data_directory,
        )
        .unwrap();
        assert_eq!(
            store.thread(f.thread["id"].as_str().unwrap()).unwrap(),
            f.thread
        );
        assert_eq!(
            store.document("bots.json").unwrap().unwrap(),
            json!({"fixtureBot":"unchanged"})
        );
        assert_eq!(fs::read(f.source.join("image.png")).unwrap(), original);
        let name = overlay_name(f.thread["id"].as_str().unwrap()).unwrap();
        assert!(store.local_document(&name).unwrap().is_some());
        drop(store);
        let op = service.load_visible(&selection, vec![ITEM.into()]).unwrap();
        let ServiceEvent::Rendered {
            entries, failures, ..
        } = wait(&mut service, op)
        else {
            panic!("render")
        };
        assert_eq!(entries.len(), 1);
        assert!(failures.is_empty());
        assert!(!entries[0].normalized_bytes.is_empty());
        let op = service.confirm(&selection, p, Vec::new()).unwrap();
        assert!(matches!(
            wait(&mut service, op),
            ServiceEvent::Failed {
                error: ServiceError::AlreadyConsumed,
                ..
            }
        ));
        service.acknowledge_receipt(receipt_id).unwrap();
        assert_eq!(service.receipt_slots.load(Ordering::SeqCst), 0);
    }
    #[test]
    fn commit_failure_retains_partial_images_even_without_finished_notification() {
        let f = fixture();
        let (mut service, selection, cap) = setup(&f);
        let (p, ids) = preview(&mut service, &selection, &cap);
        let db = rusqlite::Connection::open(&f.config.database_path).unwrap();
        db.execute_batch("CREATE TRIGGER fail_media_overlay BEFORE INSERT ON documents WHEN NEW.name LIKE 'rust-legacy-media-%' BEGIN SELECT RAISE(ABORT,'fixture commit failure'); END;").unwrap();
        let op = service.confirm(&selection, p, ids).unwrap();
        let ServiceEvent::Finished { receipt_id, .. } = wait(&mut service, op) else {
            panic!("finished")
        };
        let receipt = service.receipt(receipt_id).unwrap();
        assert!(!receipt.committed);
        assert_eq!(receipt.error, Some(ServiceError::CommitFailed));
        assert!(
            receipt.batch.references[0]
                .image
                .as_ref()
                .unwrap()
                .path
                .is_file()
        );
        assert_eq!(service.pending_recovery(), vec![receipt_id]);
        let store = Store::open_existing_for_legacy_media(
            &f.config.database_path,
            &f.config.expected_data_directory,
        )
        .unwrap();
        assert!(
            store
                .local_document(&overlay_name(f.thread["id"].as_str().unwrap()).unwrap())
                .unwrap()
                .is_none()
        );
        assert_eq!(
            store.thread(f.thread["id"].as_str().unwrap()).unwrap(),
            f.thread
        );
        // Receipt remains retrievable after notification was consumed/dropped.
        assert!(service.receipt(receipt_id).is_some());
        service.acknowledge_receipt(receipt_id).unwrap();
        assert!(
            receipt.batch.references[0]
                .image
                .as_ref()
                .unwrap()
                .path
                .exists()
        );
    }
    #[test]
    fn full_thread_change_and_competing_overlay_writer_fail_without_source_changes() {
        let f = fixture();
        let (mut service, selection, cap) = setup(&f);
        let (p, ids) = preview(&mut service, &selection, &cap);
        let mut other = Store::open_existing_for_legacy_media(
            &f.config.database_path,
            &f.config.expected_data_directory,
        )
        .unwrap();
        let mut changed = f.thread.clone();
        changed["draft"] = json!("edited while previewing");
        other.save(&changed).unwrap();
        let op = service.confirm(&selection, p, ids).unwrap();
        assert!(matches!(
            wait(&mut service, op),
            ServiceEvent::Failed {
                error: ServiceError::ThreadChanged,
                ..
            }
        ));
        assert!(
            !f.config
                .expected_data_directory
                .join("attachments")
                .exists()
        );
        other.save(&f.thread).unwrap();
        let (p, ids) = preview(&mut service, &selection, &cap);
        let name = overlay_name(f.thread["id"].as_str().unwrap()).unwrap();
        let empty = json!({"version":1,"threadId":f.thread["id"],"sourceThreadSha256":thread_hash(&f.thread).unwrap(),"entries":[]});
        other
            .commit_legacy_media_overlay_if_unchanged(&f.thread, None, &empty)
            .unwrap();
        let op = service.confirm(&selection, p, ids).unwrap();
        let ServiceEvent::Finished { receipt_id, .. } = wait(&mut service, op) else {
            panic!("finished")
        };
        let receipt = service.receipt(receipt_id).unwrap();
        assert_eq!(receipt.error, Some(ServiceError::OverlayChanged));
        assert!(receipt.batch.references[0].image.is_some());
        assert_eq!(other.local_document(&name).unwrap(), Some(empty));
    }
    #[test]
    fn imported_overlay_cannot_grant_rendering_and_metadata_changes_are_explicit() {
        let f = fixture();
        let (mut service, selection, cap) = setup(&f);
        let (p, ids) = preview(&mut service, &selection, &cap);
        let op = service.confirm(&selection, p, ids).unwrap();
        let ServiceEvent::Finished { receipt_id, .. } = wait(&mut service, op) else {
            panic!("finished")
        };
        assert!(service.receipt(receipt_id).unwrap().committed);
        let name = overlay_name(f.thread["id"].as_str().unwrap()).unwrap();
        let db = rusqlite::Connection::open(&f.config.database_path).unwrap();
        let overlay: String = db
            .query_row(
                "SELECT document FROM documents WHERE name=?1",
                [&name],
                |r| r.get(0),
            )
            .unwrap();
        db.execute(
            "INSERT INTO original_files(path,data) VALUES (?1,?2)",
            rusqlite::params![name, overlay.as_bytes()],
        )
        .unwrap();
        db.execute("DELETE FROM documents WHERE name=?1", [&name])
            .unwrap();
        let op = service.load_visible(&selection, vec![ITEM.into()]).unwrap();
        let ServiceEvent::Rendered { entries, .. } = wait(&mut service, op) else {
            panic!("render")
        };
        assert!(entries.is_empty());
        db.execute(
            "INSERT INTO documents(name,document) VALUES (?1,?2)",
            rusqlite::params![name, overlay],
        )
        .unwrap();
        let mut store = Store::open_existing_for_legacy_media(
            &f.config.database_path,
            &f.config.expected_data_directory,
        )
        .unwrap();
        let mut changed = f.thread.clone();
        changed["title"] = json!("metadata changed");
        store.save(&changed).unwrap();
        let op = service.load_visible(&selection, vec![ITEM.into()]).unwrap();
        assert!(matches!(
            wait(&mut service, op),
            ServiceEvent::Failed {
                error: ServiceError::ThreadChanged,
                ..
            }
        ));
    }
    #[test]
    fn cancellation_selection_expiry_and_receipt_backpressure_have_no_fallback() {
        let f = fixture();
        let (mut service, selection, mut cap) = setup(&f);
        cap.expires = Instant::now() - Duration::from_secs(1);
        assert_eq!(
            service.inspect(&selection, &cap, 0).unwrap_err(),
            ServiceError::Expired
        );
        let cap = service
            .approve_roots_native(&selection, vec![f.root.clone()], None)
            .unwrap();
        let (p, ids) = preview(&mut service, &selection, &cap);
        service.receipt_slots.store(MAX_RECEIPTS, Ordering::SeqCst);
        assert_eq!(
            service.confirm(&selection, p, ids.clone()).unwrap_err(),
            ServiceError::RecoveryRequired
        );
        assert_eq!(service.receipt_slots.load(Ordering::SeqCst), MAX_RECEIPTS);
        // A failed enqueue must release the last available reservation without
        // consuming the preview or stealing any already-retained receipt slot.
        let (disconnected, receiver) = mpsc::sync_channel(8);
        drop(receiver);
        let connected = service.tx.replace(disconnected);
        service
            .receipt_slots
            .store(MAX_RECEIPTS - 1, Ordering::SeqCst);
        assert_eq!(
            service.confirm(&selection, p, ids.clone()).unwrap_err(),
            ServiceError::QueueFull
        );
        assert_eq!(
            service.receipt_slots.load(Ordering::SeqCst),
            MAX_RECEIPTS - 1
        );
        service.tx = connected;
        service.receipt_slots.store(0, Ordering::SeqCst);
        let control = Control {
            state: Arc::new(AtomicU8::new(RUNNING)),
            selection: selection.clone(),
        };
        assert!(matches!(control.cancel(), CancelAck::Requested));
        assert!(
            control
                .state
                .compare_exchange(RUNNING, COMMITTING, Ordering::SeqCst, Ordering::SeqCst)
                .is_err()
        );
        control.state.store(COMMITTING, Ordering::SeqCst);
        assert!(matches!(control.cancel(), CancelAck::TooLateMayCommit));
        service.select_thread(None);
        assert_eq!(
            service.confirm(&selection, p, ids).unwrap_err(),
            ServiceError::InvalidSelection
        );
        assert!(
            !f.config
                .expected_data_directory
                .join("attachments")
                .exists()
        );
    }
    #[test]
    fn existing_only_opener_refuses_missing_symlink_old_schema_mismatch_and_replacement() {
        let f = fixture();
        let root = f.config.expected_data_directory.clone();
        let missing = root.join("missing.sqlite");
        assert!(Store::open_existing_for_legacy_media(&missing, &root).is_err());
        assert!(!missing.exists());
        let linked = root.join("link.sqlite");
        symlink(&f.config.database_path, &linked).unwrap();
        assert!(Store::open_existing_for_legacy_media(&linked, &root).is_err());
        assert!(Store::open_existing_for_legacy_media(&f.config.database_path, &f.source).is_err());
        let old = root.join("old.sqlite");
        let db = rusqlite::Connection::open(&old).unwrap();
        db.execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);INSERT INTO metadata VALUES('schema','2');").unwrap();
        drop(db);
        let before = fs::read(&old).unwrap();
        assert!(Store::open_existing_for_legacy_media(&old, &root).is_err());
        assert_eq!(fs::read(&old).unwrap(), before);
        let incomplete = root.join("incomplete.sqlite");
        let db = rusqlite::Connection::open(&incomplete).unwrap();
        db.execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);INSERT INTO metadata VALUES('schema','3');").unwrap();
        drop(db);
        let before = fs::read(&incomplete).unwrap();
        assert!(Store::open_existing_for_legacy_media(&incomplete, &root).is_err());
        assert_eq!(fs::read(&incomplete).unwrap(), before);
        let alias = f.source.join("linked-data-directory");
        symlink(&root, &alias).unwrap();
        assert!(
            Store::open_existing_for_legacy_media(&alias.join("state.sqlite"), &alias,).is_err()
        );
        let held = open_regular_existing(&f.config.database_path).unwrap();
        let db = rusqlite::Connection::open_with_flags(
            &f.config.database_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE,
        )
        .unwrap();
        let moved = root.join("moved.sqlite");
        fs::rename(&f.config.database_path, &moved).unwrap();
        fs::copy(&moved, &f.config.database_path).unwrap();
        assert!(verify_database_identity(&f.config.database_path, &held, &db).is_err());
        let corrupt = root.join("corrupt.sqlite");
        fs::write(&corrupt, b"not sqlite").unwrap();
        assert!(Store::open_existing_for_legacy_media(&corrupt, &root).is_err());
        assert_eq!(fs::read(&corrupt).unwrap(), b"not sqlite");
    }
    #[test]
    fn cancellation_after_materialize_retains_images_and_skips_overlay_commit() {
        let f = fixture();
        let (_front, selection, cap) = setup(&f);
        let mut worker = Worker::open(f.config.clone()).unwrap();
        let control = Control {
            state: Arc::new(AtomicU8::new(RUNNING)),
            selection,
        };
        let receipts: Receipts = Arc::new(Mutex::new(HashMap::new()));
        let mut kept = false;
        let ServiceEvent::Inspected {
            plan_id,
            candidates,
            ..
        } = worker
            .execute(
                OperationId(Uuid::new_v4()),
                &control,
                Command::Inspect(cap, 0),
                &receipts,
                &mut kept,
            )
            .unwrap()
        else {
            panic!("inspect")
        };
        let ids = candidates
            .iter()
            .map(|c| c.candidate_id.clone())
            .collect::<Vec<_>>();
        let ServiceEvent::Validated { preview_id, .. } = worker
            .execute(
                OperationId(Uuid::new_v4()),
                &control,
                Command::Validate(plan_id, ids.clone()),
                &receipts,
                &mut kept,
            )
            .unwrap()
        else {
            panic!("preview")
        };
        let cancellation = control.clone();
        worker.after_materialize = Some(Box::new(move || {
            cancellation.cancel();
        }));
        let ServiceEvent::Finished { receipt_id, .. } = worker
            .execute(
                OperationId(Uuid::new_v4()),
                &control,
                Command::Confirm(preview_id, ids),
                &receipts,
                &mut kept,
            )
            .unwrap()
        else {
            panic!("receipt")
        };
        assert!(kept);
        let receipt = receipts.lock().unwrap().get(&receipt_id).unwrap().clone();
        assert!(!receipt.committed);
        assert_eq!(receipt.error, Some(ServiceError::Cancelled));
        assert!(
            receipt.batch.references[0]
                .image
                .as_ref()
                .unwrap()
                .path
                .is_file()
        );
        assert!(
            worker
                .store
                .local_document(&overlay_name(f.thread["id"].as_str().unwrap()).unwrap())
                .unwrap()
                .is_none()
        );
    }
    #[test]
    fn invalid_overlay_after_copy_retains_created_identity_and_original_local_value() {
        let f = fixture();
        let name = overlay_name(f.thread["id"].as_str().unwrap()).unwrap();
        let invalid = json!({"version":1,"threadId":f.thread["id"],"entries":"invalid fixture"});
        let db = rusqlite::Connection::open(&f.config.database_path).unwrap();
        db.execute(
            "INSERT INTO documents(name,document) VALUES (?1,?2)",
            rusqlite::params![name, serde_json::to_string(&invalid).unwrap()],
        )
        .unwrap();
        let (mut service, selection, cap) = setup(&f);
        let (p, ids) = preview(&mut service, &selection, &cap);
        let op = service.confirm(&selection, p, ids).unwrap();
        let ServiceEvent::Finished { receipt_id, .. } = wait(&mut service, op) else {
            panic!("receipt")
        };
        let receipt = service.receipt(receipt_id).unwrap();
        assert!(!receipt.committed);
        assert_eq!(receipt.error, Some(ServiceError::InvalidOverlay));
        assert!(receipt.committed_candidate_ids.is_empty());
        let image = receipt.batch.references[0].image.as_ref().unwrap();
        assert!(image.path.is_file());
        assert!(image.original_path.is_file());
        assert_eq!(service.pending_recovery(), vec![receipt_id]);
        let store = Store::open_existing_for_legacy_media(
            &f.config.database_path,
            &f.config.expected_data_directory,
        )
        .unwrap();
        assert_eq!(store.local_document(&name).unwrap(), Some(invalid));
        assert_eq!(
            store.thread(f.thread["id"].as_str().unwrap()).unwrap(),
            f.thread
        );
    }

    #[test]
    fn thread_change_after_materialize_retains_images_and_cannot_commit_stale_overlay() {
        let f = fixture();
        let (_front, selection, cap) = setup(&f);
        let mut worker = Worker::open(f.config.clone()).unwrap();
        let control = Control {
            state: Arc::new(AtomicU8::new(RUNNING)),
            selection,
        };
        let receipts: Receipts = Arc::new(Mutex::new(HashMap::new()));
        let mut kept = false;
        let ServiceEvent::Inspected {
            plan_id,
            candidates,
            ..
        } = worker
            .execute(
                OperationId(Uuid::new_v4()),
                &control,
                Command::Inspect(cap, 0),
                &receipts,
                &mut kept,
            )
            .unwrap()
        else {
            panic!("inspect")
        };
        let ids = candidates
            .iter()
            .map(|c| c.candidate_id.clone())
            .collect::<Vec<_>>();
        let ServiceEvent::Validated { preview_id, .. } = worker
            .execute(
                OperationId(Uuid::new_v4()),
                &control,
                Command::Validate(plan_id, ids.clone()),
                &receipts,
                &mut kept,
            )
            .unwrap()
        else {
            panic!("preview")
        };
        let config = f.config.clone();
        let mut changed = f.thread.clone();
        changed["draft"] = json!("edited after copying; retain this draft");
        let expected = changed.clone();
        worker.after_materialize = Some(Box::new(move || {
            let mut other = Store::open_existing_for_legacy_media(
                &config.database_path,
                &config.expected_data_directory,
            )
            .unwrap();
            other.save(&changed).unwrap();
        }));
        let ServiceEvent::Finished { receipt_id, .. } = worker
            .execute(
                OperationId(Uuid::new_v4()),
                &control,
                Command::Confirm(preview_id, ids),
                &receipts,
                &mut kept,
            )
            .unwrap()
        else {
            panic!("receipt")
        };
        assert!(kept);
        let receipt = receipts.lock().unwrap().get(&receipt_id).unwrap().clone();
        assert!(!receipt.committed);
        assert_eq!(receipt.error, Some(ServiceError::ThreadChanged));
        assert!(
            receipt.batch.references[0]
                .image
                .as_ref()
                .unwrap()
                .path
                .is_file()
        );
        assert!(
            worker
                .store
                .local_document(&overlay_name(f.thread["id"].as_str().unwrap(),).unwrap())
                .unwrap()
                .is_none()
        );
        assert_eq!(
            worker
                .store
                .thread(f.thread["id"].as_str().unwrap())
                .unwrap(),
            expected
        );
    }

    #[test]
    fn partial_success_commits_only_valid_entries_and_changed_managed_file_fails_render() {
        let mut f = fixture();
        fs::copy(f.source.join("image.png"), f.source.join("second.png")).unwrap();
        f.thread["items"][0]["attachments"]
            .as_array_mut()
            .unwrap()
            .push(json!("/legacy/second.png"));
        let mut store = Store::open_existing_for_legacy_media(
            &f.config.database_path,
            &f.config.expected_data_directory,
        )
        .unwrap();
        store.save(&f.thread).unwrap();
        drop(store);
        let (mut service, selection, cap) = setup(&f);
        let (p, ids) = preview(&mut service, &selection, &cap);
        fs::write(f.source.join("second.png"), b"changed source").unwrap();
        let op = service.confirm(&selection, p, ids).unwrap();
        let ServiceEvent::Finished { receipt_id, .. } = wait(&mut service, op) else {
            panic!("receipt")
        };
        let receipt = service.receipt(receipt_id).unwrap();
        assert!(receipt.committed);
        assert_eq!(receipt.committed_candidate_ids.len(), 1);
        assert_eq!(
            receipt.batch.references[1].reference.status,
            Status::Changed
        );
        let image = receipt.batch.references[0].image.as_ref().unwrap();
        fs::write(&image.path, b"changed managed output").unwrap();
        let op = service.load_visible(&selection, vec![ITEM.into()]).unwrap();
        let ServiceEvent::Rendered {
            entries, failures, ..
        } = wait(&mut service, op)
        else {
            panic!("render")
        };
        assert!(entries.is_empty());
        assert_eq!(failures.len(), 1);
        let store = Store::open_existing_for_legacy_media(
            &f.config.database_path,
            &f.config.expected_data_directory,
        )
        .unwrap();
        let overlay = store
            .local_document(&overlay_name(f.thread["id"].as_str().unwrap()).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(overlay["entries"].as_array().unwrap().len(), 1);
    }
}
