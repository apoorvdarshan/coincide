//! Conservative ownership accounting; native WebKit release remains unconfirmed.
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering},
};

#[derive(Clone, Default)]
pub(super) struct Callbacks {
    pub closed: Arc<AtomicBool>,
    pending: Arc<AtomicUsize>,
    lifetimes: NativeLifetimes,
}
/// These counters describe actual captured Rust ownership, not evaluation ACKs,
/// WebKit superclass deallocation, or whole-app/native release.
#[derive(Clone, Default)]
pub(super) struct NativeLifetimes {
    blocks: Arc<AtomicUsize>,
    targets: Arc<AtomicUsize>,
}
pub(super) struct NativeLease {
    count: Arc<AtomicUsize>,
}
impl NativeLease {
    fn new(count: Arc<AtomicUsize>) -> Self {
        count.fetch_add(1, Ordering::AcqRel);
        Self { count }
    }
}
impl Clone for NativeLease {
    fn clone(&self) -> Self {
        Self::new(self.count.clone())
    }
}
impl Drop for NativeLease {
    fn drop(&mut self) {
        self.count.fetch_sub(1, Ordering::AcqRel);
    }
}
impl NativeLifetimes {
    pub fn block(&self) -> NativeLease {
        NativeLease::new(self.blocks.clone())
    }
    #[cfg(any(target_os = "macos", test))]
    pub fn target(&self) -> NativeLease {
        NativeLease::new(self.targets.clone())
    }
    fn blocks_pending(&self) -> usize {
        self.blocks.load(Ordering::Acquire)
    }
    fn targets_pending(&self) -> usize {
        self.targets.load(Ordering::Acquire)
    }
}
#[derive(Clone)]
pub(super) struct CallbackAck {
    pending: Arc<AtomicUsize>,
    acknowledged: Arc<AtomicBool>,
}
impl CallbackAck {
    pub fn ack(&self) {
        if !self.acknowledged.swap(true, Ordering::AcqRel) {
            self.pending.fetch_sub(1, Ordering::AcqRel);
        }
    }
}
impl Callbacks {
    pub fn lifetimes(&self) -> NativeLifetimes {
        self.lifetimes.clone()
    }
    pub fn begin(&self) -> CallbackAck {
        self.pending.fetch_add(1, Ordering::AcqRel);
        CallbackAck {
            pending: self.pending.clone(),
            acknowledged: Arc::new(AtomicBool::new(false)),
        }
    }
    pub fn pending(&self) -> usize {
        self.pending.load(Ordering::Acquire)
    }
    pub fn closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }
}
pub(super) trait TrackedEvaluation {
    fn evaluate_script_tracked(
        &self,
        source: &str,
        callbacks: &Callbacks,
        callback: impl Fn(String) + Send + 'static,
    ) -> wry::Result<()>;
}
impl TrackedEvaluation for wry::WebView {
    fn evaluate_script_tracked(
        &self,
        source: &str,
        callbacks: &Callbacks,
        callback: impl Fn(String) + Send + 'static,
    ) -> wry::Result<()> {
        let ack = callbacks.begin();
        let block_lease = callbacks.lifetimes.block();
        let closed = callbacks.closed.clone();
        // A synchronous error or dropped closure is not native completion proof.
        // If no callback arrives, retain the unknown pending owner.
        self.evaluate_script_with_callback(source, move |payload| {
            // Borrow, never consume: Fn invocation may precede final native
            // RcBlock/closure release. Drop is deliberately not an ACK.
            let _held_block = &block_lease;
            if !closed.load(Ordering::Acquire) {
                callback(payload);
            }
            ack.ack();
        })
    }
}
struct Worker {
    outcome: Arc<AtomicU8>,
    _handle: Arc<Mutex<Option<std::thread::JoinHandle<()>>>>,
}
#[derive(Default)]
pub(super) struct Shutdown {
    pub callbacks: Callbacks,
    workers: Vec<Worker>,
    returned: usize,
    failed: usize,
    pub ever_native: bool,
}
#[derive(Debug, Clone)]
pub struct BrowserShutdownStatus {
    pub closed: bool,
    pub upload_workers_pending: usize,
    pub upload_workers_joined: usize,
    pub upload_workers_failed: usize,
    pub callbacks_pending: usize,
    /// Captured callback closures/blocks not yet finally dropped, including
    /// private-fill probe and final-mutation blocks independently.
    pub callback_blocks_pending: usize,
    /// Retained NativeCredentialTarget instances/clones not yet dropped.
    /// This is not a count or deallocation receipt for WKWebView objects.
    pub native_targets_pending: usize,
    pub downloads_pending: usize,
    pub owned_views: usize,
    pub owned_contexts: usize,
    pub native_release_unconfirmed: bool,
}
impl BrowserShutdownStatus {
    pub fn owners_drained(&self) -> bool {
        self.closed
            && self.upload_workers_pending == 0
            && self.upload_workers_failed == 0
            && self.callbacks_pending == 0
            && self.downloads_pending == 0
    }
    pub fn ready(&self) -> bool {
        self.owners_drained()
            && self.callback_blocks_pending == 0
            && self.native_targets_pending == 0
            && !self.native_release_unconfirmed
            && self.owned_views == 0
            && self.owned_contexts == 0
    }
}
impl Shutdown {
    pub fn close(&self) {
        self.callbacks.closed.store(true, Ordering::Release);
    }
    pub fn track(&mut self, worker: std::thread::JoinHandle<()>) {
        let handle = Arc::new(Mutex::new(Some(worker)));
        let outcome = Arc::new(AtomicU8::new(0));
        let owned = handle.clone();
        let done = outcome.clone();
        let spawn = std::thread::Builder::new()
            .name("browser-upload-join".into())
            .spawn(move || {
                let worker = owned.lock().unwrap_or_else(|e| e.into_inner()).take();
                let success = worker.is_some_and(|worker| worker.join().is_ok());
                done.store(if success { 1 } else { 2 }, Ordering::Release);
            });
        if spawn.is_err() {
            outcome.store(3, Ordering::Release);
        }
        self.workers.push(Worker {
            outcome,
            _handle: handle,
        });
    }
    pub fn status(
        &mut self,
        downloads_pending: usize,
        owned_views: usize,
        owned_contexts: usize,
    ) -> BrowserShutdownStatus {
        self.workers
            .retain(|worker| match worker.outcome.load(Ordering::Acquire) {
                0 | 3 => true,
                1 => {
                    self.returned += 1;
                    false
                }
                _ => {
                    self.failed += 1;
                    false
                }
            });
        BrowserShutdownStatus {
            closed: self.callbacks.closed(),
            upload_workers_pending: self.workers.len(),
            upload_workers_joined: self.returned,
            upload_workers_failed: self.failed
                + self
                    .workers
                    .iter()
                    .filter(|worker| worker.outcome.load(Ordering::Acquire) == 3)
                    .count(),
            callbacks_pending: self.callbacks.pending(),
            callback_blocks_pending: self.callbacks.lifetimes.blocks_pending(),
            native_targets_pending: self.callbacks.lifetimes.targets_pending(),
            downloads_pending,
            owned_views,
            owned_contexts,
            native_release_unconfirmed: self.ever_native,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        sync::Condvar,
        time::{Duration, Instant},
    };
    #[test]
    fn callback_invocation_ack_precedes_actual_closure_release() {
        let mut owner = Shutdown::default();
        let ack = owner.callbacks.begin();
        let lease = owner.callbacks.lifetimes().block();
        let callback: Box<dyn Fn()> = Box::new(move || {
            let _held = &lease;
            ack.ack();
        });
        owner.close();
        assert_eq!(owner.status(0, 0, 0).callback_blocks_pending, 1);
        callback();
        let invoked = owner.status(0, 0, 0);
        assert_eq!(invoked.callbacks_pending, 0);
        assert_eq!(invoked.callback_blocks_pending, 1);
        assert!(
            invoked.owners_drained(),
            "ordinary process-exit policy remains unchanged"
        );
        assert!(!invoked.ready());
        drop(callback);
        assert_eq!(owner.status(0, 0, 0).callback_blocks_pending, 0);
        assert!(owner.status(0, 0, 0).ready());
    }
    #[test]
    fn dropped_uninvoked_block_releases_lease_but_never_creates_ack() {
        let mut owner = Shutdown::default();
        let ack = owner.callbacks.begin();
        let lease = owner.callbacks.lifetimes().block();
        let callback = move || {
            let _held = &lease;
            ack.ack();
        };
        owner.close();
        drop(callback);
        let dropped = owner.status(0, 0, 0);
        assert_eq!(dropped.callback_blocks_pending, 0);
        assert_eq!(dropped.callbacks_pending, 1);
        assert!(!dropped.owners_drained());
        assert!(!dropped.ready());
    }
    #[test]
    fn nested_probe_and_mutation_blocks_keep_independent_lifetimes() {
        let mut owner = Shutdown::default();
        let lifetimes = owner.callbacks.lifetimes();
        let probe = lifetimes.block();
        let target = lifetimes.target();
        let ack = owner.callbacks.begin();
        let outer: Box<dyn Fn() -> Box<dyn Fn()>> = Box::new(move || {
            let _probe = &probe;
            let _direct_native_target = &target;
            let mutation = lifetimes.block();
            let ack = ack.clone();
            Box::new(move || {
                let _held_mutation = &mutation;
                ack.ack();
            })
        });
        owner.close();
        let inner = outer();
        assert_eq!(owner.status(0, 0, 0).callback_blocks_pending, 2);
        assert_eq!(owner.status(0, 0, 0).native_targets_pending, 1);
        inner();
        assert!(owner.status(0, 0, 0).owners_drained());
        assert_eq!(owner.status(0, 0, 0).callback_blocks_pending, 2);
        drop(outer);
        let probe_released = owner.status(0, 0, 0);
        assert_eq!(probe_released.callback_blocks_pending, 1);
        assert_eq!(probe_released.native_targets_pending, 0);
        assert!(!probe_released.ready());
        drop(inner);
        assert!(owner.status(0, 0, 0).ready());
    }
    #[test]
    fn direct_retained_target_clones_are_counted_until_each_view_release_returns() {
        struct FakeView {
            lifetimes: NativeLifetimes,
            released: Arc<AtomicUsize>,
        }
        impl Drop for FakeView {
            fn drop(&mut self) {
                assert!(
                    self.lifetimes.targets_pending() > 0,
                    "lease must outlive retained-view release"
                );
                self.released.fetch_add(1, Ordering::AcqRel);
            }
        }
        struct Target {
            _view: FakeView,
            _lease: NativeLease,
        }
        let mut owner = Shutdown::default();
        let lifetimes = owner.callbacks.lifetimes();
        let released = Arc::new(AtomicUsize::new(0));
        let target = Target {
            _view: FakeView {
                lifetimes: lifetimes.clone(),
                released: released.clone(),
            },
            _lease: lifetimes.target(),
        };
        let captured = Target {
            _view: FakeView {
                lifetimes: lifetimes.clone(),
                released: released.clone(),
            },
            _lease: target._lease.clone(),
        };
        owner.close();
        assert_eq!(owner.status(0, 0, 0).native_targets_pending, 2);
        drop(target);
        assert_eq!(owner.status(0, 0, 0).native_targets_pending, 1);
        assert_eq!(released.load(Ordering::Acquire), 1);
        assert!(owner.status(0, 0, 0).owners_drained());
        assert!(!owner.status(0, 0, 0).ready());
        drop(captured);
        assert_eq!(released.load(Ordering::Acquire), 2);
        assert_eq!(owner.status(0, 0, 0).native_targets_pending, 0);
        assert!(owner.status(0, 0, 0).ready());
        owner.ever_native = true;
        assert!(
            !owner.status(0, 0, 0).ready(),
            "lease facts do not establish native WebKit release"
        );
    }
    #[test]
    fn missing_callback_ack_stays_pending_even_when_closure_is_dropped() {
        let mut owner = Shutdown::default();
        let ack = owner.callbacks.begin();
        let callback = move || ack.ack();
        owner.close();
        drop(callback);
        let state = owner.status(0, 0, 0);
        assert_eq!(state.callbacks_pending, 1);
        assert!(!state.ready());
    }
    #[test]
    fn callback_ack_is_explicit_and_idempotent_but_native_release_still_blocks() {
        let owner = Shutdown {
            ever_native: true,
            ..Shutdown::default()
        };
        let ack = owner.callbacks.begin();
        owner.close();
        assert!(!owner.status(0, 1, 1).owners_drained());
        ack.ack();
        ack.ack();
        let state = owner.status(0, 1, 1);
        assert!(state.owners_drained());
        assert!(state.native_release_unconfirmed);
        assert!(!state.ready());
        assert!(
            !owner.status(1, 1, 1).owners_drained(),
            "accepted download needs native completion"
        );
    }
    #[test]
    fn upload_worker_result_before_tls_exit_is_not_actual_join() {
        struct Gate(Arc<(Mutex<bool>, Condvar)>, Arc<AtomicBool>);
        impl Drop for Gate {
            fn drop(&mut self) {
                self.1.store(true, Ordering::Release);
                let lock = self.0.0.lock().unwrap();
                drop(self.0.1.wait_while(lock, |blocked| *blocked).unwrap());
            }
        }
        thread_local! {static EXIT:std::cell::RefCell<Option<Gate>>=const {std::cell::RefCell::new(None)};}
        let gate = Arc::new((Mutex::new(true), Condvar::new()));
        struct Release(Arc<(Mutex<bool>, Condvar)>);
        impl Drop for Release {
            fn drop(&mut self) {
                *self.0.0.lock().unwrap() = false;
                self.0.1.notify_all();
            }
        }
        let _release = Release(gate.clone());
        let entered = Arc::new(AtomicBool::new(false));
        let g = gate.clone();
        let e = entered.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            EXIT.with(|slot| *slot.borrow_mut() = Some(Gate(g, e)));
            let _ = tx.send(());
        });
        let mut owner = Shutdown::default();
        owner.track(worker);
        owner.close();
        rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while !entered.load(Ordering::Acquire) {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(owner.status(0, 0, 0).upload_workers_pending, 1);
        assert!(!owner.status(0, 0, 0).ready());
        *gate.0.lock().unwrap() = false;
        gate.1.notify_all();
        while !owner.status(0, 0, 0).ready() {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(owner.status(0, 0, 0).upload_workers_joined, 1);
    }
    #[test]
    fn panicked_upload_worker_remains_failure_after_actual_join() {
        let mut owner = Shutdown::default();
        owner.track(std::thread::spawn(|| {
            panic!("synthetic upload worker panic")
        }));
        owner.close();
        let deadline = Instant::now() + Duration::from_secs(3);
        while owner.status(0, 0, 0).upload_workers_pending != 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(owner.status(0, 0, 0).upload_workers_failed, 1);
        assert!(!owner.status(0, 0, 0).ready());
    }
    #[test]
    fn shutdown_without_native_owners_is_inert() {
        let mut owner = Shutdown::default();
        assert!(!owner.status(0, 0, 0).ready());
        owner.close();
        assert!(owner.status(0, 0, 0).ready());
    }
}
