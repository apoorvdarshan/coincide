//! Additive UI-thread ownership receipts. No WebKit deallocation or updater
//! readiness is inferred from these Rust/task facts.
use gpui::App;
#[cfg(any(
    test,
    all(feature = "gpui-fast", any(target_os = "macos", target_os = "linux"))
))]
use gpui::Task;
use std::{
    any::Any,
    cell::RefCell,
    future::Future,
    ops::Deref,
    pin::Pin,
    rc::Rc,
    sync::atomic::{AtomicU64, Ordering},
    task::{Context, Poll, Waker},
    thread::ThreadId,
};

#[cfg(any(
    test,
    all(feature = "gpui-fast", any(target_os = "macos", target_os = "linux"))
))]
use std::rc::Weak;

static NEXT_ID: AtomicU64 = AtomicU64::new(1);
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReleaseId(u64);
impl ReleaseId {
    pub fn get(self) -> u64 {
        self.0
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SurfacePhase {
    NotCreated,
    Owned,
    Pending,
    Removed,
    Failed(String),
    Unknown(String),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RustOwnerPhase {
    Owned,
    DropReturned,
    WrongThread,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReleaseTaskPhase {
    NotStarted,
    Running,
    Returned,
    Failed,
    Abandoned,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NativeReleasePhase {
    Unknown,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReleaseSnapshot {
    pub id: ReleaseId,
    pub surface: SurfacePhase,
    pub rust_owner: RustOwnerPhase,
    pub task: ReleaseTaskPhase,
    pub native: NativeReleasePhase,
}
struct State {
    snapshot: RefCell<ReleaseSnapshot>,
    creator: ThreadId,
}
#[derive(Clone)]
pub struct ReleaseReceipt {
    state: Rc<State>,
    #[cfg(any(
        test,
        all(feature = "gpui-fast", any(target_os = "macos", target_os = "linux"))
    ))]
    registry: Weak<RefCell<RegistryInner>>,
}
impl ReleaseReceipt {
    pub fn snapshot(&self) -> ReleaseSnapshot {
        self.state.snapshot.borrow().clone()
    }
    pub(crate) fn set_surface(&self, surface: SurfacePhase) {
        self.state.snapshot.borrow_mut().surface = surface;
    }
    #[cfg(any(
        test,
        all(feature = "gpui-fast", any(target_os = "macos", target_os = "linux"))
    ))]
    pub(crate) fn track_task(&self, task: Task<SurfaceResult>) {
        self.track_future(task);
    }
    #[cfg(any(
        test,
        all(feature = "gpui-fast", any(target_os = "macos", target_os = "linux"))
    ))]
    fn track_future(&self, task: impl Future<Output = SurfaceResult> + 'static) {
        let Some(registry) = self.registry.upgrade() else {
            self.state.snapshot.borrow_mut().task = ReleaseTaskPhase::Abandoned;
            return;
        };
        let mut registry = registry.borrow_mut();
        let Some(record) = registry
            .records
            .iter_mut()
            .find(|record| Rc::ptr_eq(&record.state, &self.state))
        else {
            self.state.snapshot.borrow_mut().task = ReleaseTaskPhase::Abandoned;
            return;
        };
        if record.task.is_some() || self.snapshot().task != ReleaseTaskPhase::NotStarted {
            let mut state = self.state.snapshot.borrow_mut();
            state.surface = SurfacePhase::Unknown("Duplicate release task".into());
            state.task = ReleaseTaskPhase::Abandoned;
            return;
        }
        {
            let mut state = self.state.snapshot.borrow_mut();
            state.surface = SurfacePhase::Pending;
            state.task = ReleaseTaskPhase::Running;
        }
        record.task = Some(Box::pin(task));
    }
}
/// Retains the exact resources associated with a failed removal. No implicit
/// retry or destruction is used as evidence of successful surface removal.
pub(crate) struct SurfaceFailure {
    error: String,
    _custody: Box<dyn Any>,
}
impl SurfaceFailure {
    #[cfg(any(
        test,
        all(feature = "gpui-fast", any(target_os = "macos", target_os = "linux"))
    ))]
    pub(crate) fn new(error: String, custody: impl Any) -> Self {
        Self {
            error,
            _custody: Box::new(custody),
        }
    }
}
pub(crate) type SurfaceResult = Result<(), SurfaceFailure>;
struct Record {
    state: Rc<State>,
    task: Option<Pin<Box<dyn Future<Output = SurfaceResult>>>>,
    failure: Option<SurfaceFailure>,
}
impl Drop for Record {
    fn drop(&mut self) {
        if self.task.is_some() {
            self.state.snapshot.borrow_mut().task = ReleaseTaskPhase::Abandoned;
        }
    }
}
#[derive(Default)]
struct RegistryInner {
    closed: bool,
    records: Vec<Record>,
}
/// Keep this UI-thread-local registry alive and poll it while releasing views.
/// Receipts and task captures never hold it strongly, avoiding owner cycles.
#[derive(Clone, Default)]
pub struct ReleaseRegistry {
    inner: Rc<RefCell<RegistryInner>>,
}
impl ReleaseRegistry {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn close(&mut self) {
        self.inner.borrow_mut().closed = true;
    }
    pub(crate) fn ensure_open(&self) -> anyhow::Result<()> {
        anyhow::ensure!(
            !self.inner.borrow().closed,
            "WebView release registry is closed"
        );
        Ok(())
    }
    pub(crate) fn register(&self, surface: SurfacePhase) -> anyhow::Result<ReleaseReceipt> {
        self.ensure_open()?;
        let id = NEXT_ID
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
                value.checked_add(1)
            })
            .map_err(|_| anyhow::anyhow!("WebView release identities exhausted"))?;
        let state = Rc::new(State {
            creator: std::thread::current().id(),
            snapshot: RefCell::new(ReleaseSnapshot {
                id: ReleaseId(id),
                surface,
                rust_owner: RustOwnerPhase::Owned,
                task: ReleaseTaskPhase::NotStarted,
                native: NativeReleasePhase::Unknown,
            }),
        });
        self.inner.borrow_mut().records.push(Record {
            state: state.clone(),
            task: None,
            failure: None,
        });
        Ok(ReleaseReceipt {
            state,
            #[cfg(any(
                test,
                all(feature = "gpui-fast", any(target_os = "macos", target_os = "linux"))
            ))]
            registry: Rc::downgrade(&self.inner),
        })
    }
    pub fn snapshots(&self) -> Vec<ReleaseSnapshot> {
        self.inner
            .borrow()
            .records
            .iter()
            .map(|record| record.state.snapshot.borrow().clone())
            .collect()
    }
    /// Poll the actual retained foreground Tasks. A flag set inside the future
    /// cannot settle the record; its result and future destruction are required.
    pub fn poll(&mut self, _cx: &mut App) -> Vec<ReleaseSnapshot> {
        self.poll_tasks();
        self.snapshots()
    }
    fn poll_tasks(&mut self) {
        let mut registry = self.inner.borrow_mut();
        let mut cx = Context::from_waker(Waker::noop());
        for record in &mut registry.records {
            if record.state.snapshot.borrow().task != ReleaseTaskPhase::Running {
                continue;
            }
            let Some(task) = record.task.as_mut() else {
                continue;
            };
            let polled = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                task.as_mut().poll(&mut cx)
            }));
            let result = match polled {
                Ok(Poll::Ready(result)) => result,
                Ok(Poll::Pending) => continue,
                Err(_) => {
                    let mut state = record.state.snapshot.borrow_mut();
                    state.task = ReleaseTaskPhase::Abandoned;
                    state.surface =
                        SurfacePhase::Unknown("Release task panicked; custody retained".into());
                    continue;
                }
            };
            // Drop the completed task/future and its captures before publishing.
            drop(record.task.take());
            let mut state = record.state.snapshot.borrow_mut();
            match result {
                Ok(()) => {
                    state.surface = SurfacePhase::Removed;
                    state.task = ReleaseTaskPhase::Returned;
                }
                Err(failure) => {
                    state.surface = SurfacePhase::Failed(failure.error.clone());
                    state.task = ReleaseTaskPhase::Failed;
                    record.failure = Some(failure);
                }
            }
        }
    }
}
/// Every tracked frame and handle shares this exact owner. The receipt is
/// updated only after the actual inner Wry value and all fields finish dropping.
pub(crate) struct OwnedNative<T> {
    value: Option<T>,
    receipt: Option<ReleaseReceipt>,
}
impl<T> OwnedNative<T> {
    pub(crate) fn new(value: T) -> Self {
        Self {
            value: Some(value),
            receipt: None,
        }
    }
    pub(crate) fn attach(&mut self, receipt: ReleaseReceipt) {
        self.receipt = Some(receipt);
    }
    pub(crate) fn receipt(&self) -> Option<ReleaseReceipt> {
        self.receipt.clone()
    }
}
impl<T> Deref for OwnedNative<T> {
    type Target = T;
    fn deref(&self) -> &T {
        self.value.as_ref().expect("live native owner")
    }
}
impl<T> Drop for OwnedNative<T> {
    fn drop(&mut self) {
        drop(self.value.take());
        if let Some(receipt) = &self.receipt {
            receipt.state.snapshot.borrow_mut().rust_owner =
                if receipt.state.creator == std::thread::current().id() {
                    RustOwnerPhase::DropReturned
                } else {
                    RustOwnerPhase::WrongThread
                };
        }
    }
}
pub(crate) type OwnedWry = OwnedNative<wry::WebView>;

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    struct Dropped(Rc<Cell<usize>>);
    impl Drop for Dropped {
        fn drop(&mut self) {
            self.0.set(self.0.get() + 1);
        }
    }
    #[test]
    fn held_frames_and_handles_delay_actual_rust_drop_return() {
        let registry = ReleaseRegistry::new();
        let receipt = registry.register(SurfacePhase::NotCreated).unwrap();
        let drops = Rc::new(Cell::new(0));
        let mut value = OwnedNative::new(Dropped(drops.clone()));
        value.attach(receipt.clone());
        let owner = Rc::new(value);
        let frame = owner.clone();
        let handle = frame.clone();
        drop(owner);
        drop(frame);
        assert_eq!(receipt.snapshot().rust_owner, RustOwnerPhase::Owned);
        assert_eq!(drops.get(), 0);
        drop(handle);
        assert_eq!(drops.get(), 1);
        assert_eq!(receipt.snapshot().rust_owner, RustOwnerPhase::DropReturned);
        assert_eq!(receipt.snapshot().native, NativeReleasePhase::Unknown);
    }
    #[test]
    fn semantic_flag_does_not_finish_gated_task_or_drop_its_resources() {
        struct Gated {
            flag: Rc<Cell<bool>>,
            gate: Rc<Cell<bool>>,
            _resource: Dropped,
        }
        impl Future for Gated {
            type Output = SurfaceResult;
            fn poll(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Self::Output> {
                self.flag.set(true);
                if self.gate.get() {
                    Poll::Ready(Ok(()))
                } else {
                    Poll::Pending
                }
            }
        }
        let mut registry = ReleaseRegistry::new();
        let receipt = registry.register(SurfacePhase::Owned).unwrap();
        let flag = Rc::new(Cell::new(false));
        let gate = Rc::new(Cell::new(false));
        let drops = Rc::new(Cell::new(0));
        receipt.track_future(Gated {
            flag: flag.clone(),
            gate: gate.clone(),
            _resource: Dropped(drops.clone()),
        });
        registry.poll_tasks();
        assert!(flag.get());
        assert_eq!(receipt.snapshot().task, ReleaseTaskPhase::Running);
        assert_eq!(drops.get(), 0);
        gate.set(true);
        registry.poll_tasks();
        assert_eq!(drops.get(), 1);
        assert_eq!(receipt.snapshot().surface, SurfacePhase::Removed);
        assert_eq!(receipt.snapshot().task, ReleaseTaskPhase::Returned);
    }
    #[test]
    fn failed_actual_task_retains_custody_and_never_reports_removal() {
        let mut registry = ReleaseRegistry::new();
        let receipt = registry.register(SurfacePhase::Owned).unwrap();
        let drops = Rc::new(Cell::new(0));
        receipt.track_task(Task::ready(Err(SurfaceFailure::new(
            "synthetic window/remove failure".into(),
            Dropped(drops.clone()),
        ))));
        registry.poll_tasks();
        assert_eq!(receipt.snapshot().task, ReleaseTaskPhase::Failed);
        assert!(matches!(
            receipt.snapshot().surface,
            SurfacePhase::Failed(_)
        ));
        assert_eq!(drops.get(), 0);
        registry.poll_tasks();
        assert_eq!(drops.get(), 0);
        drop(registry);
        assert_eq!(drops.get(), 1);
    }
    #[test]
    fn panicked_task_is_unknown_with_resources_retained_and_not_repolled() {
        struct Panics {
            polls: Rc<Cell<usize>>,
            _resource: Dropped,
        }
        impl Future for Panics {
            type Output = SurfaceResult;
            fn poll(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Self::Output> {
                self.polls.set(self.polls.get() + 1);
                panic!("synthetic release task failure")
            }
        }
        let mut registry = ReleaseRegistry::new();
        let receipt = registry.register(SurfacePhase::Owned).unwrap();
        let polls = Rc::new(Cell::new(0));
        let drops = Rc::new(Cell::new(0));
        receipt.track_future(Panics {
            polls: polls.clone(),
            _resource: Dropped(drops.clone()),
        });
        registry.poll_tasks();
        registry.poll_tasks();
        assert_eq!(polls.get(), 1);
        assert_eq!(drops.get(), 0);
        assert_eq!(receipt.snapshot().task, ReleaseTaskPhase::Abandoned);
        assert!(matches!(
            receipt.snapshot().surface,
            SurfacePhase::Unknown(_)
        ));
        drop(registry);
        assert_eq!(drops.get(), 1);
    }
    #[test]
    fn actual_ready_task_result_is_consumed_without_native_claim() {
        let mut registry = ReleaseRegistry::new();
        let receipt = registry.register(SurfacePhase::Owned).unwrap();
        receipt.track_task(Task::ready(Ok(())));
        assert_eq!(receipt.snapshot().task, ReleaseTaskPhase::Running);
        registry.poll_tasks();
        assert_eq!(receipt.snapshot().task, ReleaseTaskPhase::Returned);
        assert_eq!(receipt.snapshot().surface, SurfacePhase::Removed);
        assert_eq!(receipt.snapshot().native, NativeReleasePhase::Unknown);
    }
    #[test]
    fn registry_and_task_captures_have_no_strong_owner_cycle() {
        let registry = ReleaseRegistry::new();
        let weak = Rc::downgrade(&registry.inner);
        let receipt = registry.register(SurfacePhase::Owned).unwrap();
        let captured = receipt.clone();
        receipt.track_future(async move {
            let _held = captured;
            std::future::pending::<SurfaceResult>().await
        });
        drop(registry);
        assert!(weak.upgrade().is_none());
        assert_eq!(receipt.snapshot().task, ReleaseTaskPhase::Abandoned);
    }
    #[test]
    fn one_receipt_task_cannot_settle_another_view_identity() {
        let mut registry = ReleaseRegistry::new();
        let first = registry.register(SurfacePhase::Owned).unwrap();
        let second = registry.register(SurfacePhase::Owned).unwrap();
        assert_ne!(first.snapshot().id, second.snapshot().id);
        first.track_task(Task::ready(Ok(())));
        registry.poll_tasks();
        assert_eq!(first.snapshot().surface, SurfacePhase::Removed);
        assert_eq!(second.snapshot().surface, SurfacePhase::Owned);
        assert_eq!(second.snapshot().task, ReleaseTaskPhase::NotStarted);
    }
    #[test]
    fn closed_admission_and_unknown_construction_cleanup_never_become_success() {
        let mut registry = ReleaseRegistry::new();
        let receipt = registry
            .register(SurfacePhase::Unknown(
                "construction cleanup unconfirmed".into(),
            ))
            .unwrap();
        registry.close();
        assert!(registry.register(SurfacePhase::NotCreated).is_err());
        registry.poll_tasks();
        assert!(matches!(
            receipt.snapshot().surface,
            SurfacePhase::Unknown(_)
        ));
        assert_eq!(receipt.snapshot().native, NativeReleasePhase::Unknown);
    }
}
