//! Dedicated background worker for scoped idle-sleep inhibition. This is not a
//! registered daemon or an agent-session host. No native effects occur by default.
//! The coordinator must register this module and wire policy/status into Engine.
use super::inhibitor::NativeSleepInhibitor;
use super::power::{AwakeController, AwakePolicy, SleepInhibitor};
use anyhow::{Context, Result, bail};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

#[derive(Debug, Clone, Copy)]
pub struct Settings {
    /// Explicit integration gate. Default stays false even if a submitted policy
    /// says enabled. The app must deliberately wire its opt-in setting here.
    pub allow_inhibition: bool,
    pub tick_interval: Duration,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            allow_inhibition: false,
            tick_interval: Duration::from_secs(5),
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Starting,
    Applying,
    Waiting,
    Stopping,
    Stopped,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LeaseState {
    Released,
    Held,
    Unknown,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub phase: Phase,
    /// Latest submitted snapshot; mailbox storage remains exactly one slot.
    pub requested_revision: u64,
    /// Last snapshot attempted (including errors); timer retries reuse its revision.
    pub processed_revision: Option<u64>,
    /// Last snapshot successfully acknowledged by the backend. A queued snapshot,
    /// an attempted call, and an error never advance this field.
    pub acknowledged_revision: Option<u64>,
    pub acknowledged_policy: Option<AwakePolicy>,
    pub lease: LeaseState,
    /// Bounded latest diagnostic; no accumulating event/status queue.
    pub error: Option<String>,
}
struct State {
    pending: Option<(u64, AwakePolicy)>,
    stopping: bool,
    status: Status,
}
struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}
impl Shared {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        // A backend panic never occurs while this lock is held. Recover anyway
        // so shutdown cannot strand the worker if a caller panics during a read.
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}
#[derive(Clone)]
pub struct Handle {
    shared: Arc<Shared>,
}
impl Handle {
    /// Nonblocking with respect to backend work. New policy replaces any pending
    /// policy, so bursts cannot grow memory. Revisions identify coalesced updates.
    pub fn submit(&self, policy: AwakePolicy) -> Result<u64> {
        let mut state = self.shared.lock();
        if state.stopping || state.status.phase == Phase::Stopped {
            bail!("host worker is stopping or stopped");
        }
        let revision = state
            .status
            .requested_revision
            .checked_add(1)
            .context("host policy revision exhausted")?;
        state.status.requested_revision = revision;
        state.pending = Some((revision, policy));
        self.shared.changed.notify_all();
        Ok(revision)
    }
    pub fn status(&self) -> Status {
        self.shared.lock().status.clone()
    }
    /// Shutdown has its own flag and cannot be evicted by policy coalescing.
    pub fn request_shutdown(&self) {
        let mut state = self.shared.lock();
        state.stopping = true;
        state.pending = None;
        self.shared.changed.notify_all();
    }
    /// Intended for non-UI consumers/tests. Returns on processing, stop or timeout;
    /// callers inspect acknowledged_revision/error to distinguish success.
    pub fn wait_processed(&self, revision: u64, timeout: Duration) -> Status {
        let state = self.shared.lock();
        let (state, _) = self
            .shared
            .changed
            .wait_timeout_while(state, timeout, |s| {
                s.status.phase != Phase::Stopped
                    && s.status.processed_revision.is_none_or(|r| r < revision)
            })
            .unwrap_or_else(|e| e.into_inner());
        state.status.clone()
    }
}

pub struct HostRuntime {
    handle: Handle,
    worker: Option<JoinHandle<()>>,
}
/// Owns the worker join without making the polling thread wait for backend work.
pub struct PendingShutdown {
    handle: Handle,
    // Retained if starting the join thread fails. Dropping a JoinHandle never joins.
    _worker: Arc<Mutex<Option<JoinHandle<()>>>>,
    completion: Arc<Mutex<Option<std::result::Result<(), String>>>>,
    start_error: Option<String>,
}
#[derive(Debug, Clone)]
pub struct ShutdownStatus {
    pub joined: bool,
    pub status: Status,
}
impl ShutdownStatus {
    pub fn ready(&self) -> bool {
        self.joined
            && self.status.phase == Phase::Stopped
            && self.status.lease == LeaseState::Released
            && self.status.error.is_none()
    }
}
impl PendingShutdown {
    pub fn poll(&self) -> ShutdownStatus {
        let completion = self.completion.lock().unwrap_or_else(|e| e.into_inner());
        let mut status = self.handle.status();
        let joined = matches!(&*completion, Some(Ok(())));
        let error = self.start_error.clone().or_else(|| match &*completion {
            Some(Err(error)) => Some(error.clone()),
            _ => None,
        });
        if let Some(error) = error {
            status.lease = LeaseState::Unknown;
            status.error = Some(error);
        }
        ShutdownStatus { joined, status }
    }
}
impl HostRuntime {
    /// Only creates the worker. Its initial policy is disabled. This does not
    /// register a login item, persist settings or enable native inhibition.
    pub fn spawn_native(settings: Settings) -> Result<Self> {
        Self::spawn(NativeSleepInhibitor::native(), settings)
    }
    pub fn spawn<B: SleepInhibitor + Send + 'static>(
        backend: B,
        settings: Settings,
    ) -> Result<Self> {
        if !(Duration::from_millis(10)..=Duration::from_secs(60)).contains(&settings.tick_interval)
        {
            bail!("host tick interval must be between 10ms and 60s");
        }
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                pending: None,
                stopping: false,
                status: Status {
                    phase: Phase::Starting,
                    requested_revision: 0,
                    processed_revision: None,
                    acknowledged_revision: None,
                    acknowledged_policy: None,
                    lease: LeaseState::Released,
                    error: None,
                },
            }),
            changed: Condvar::new(),
        });
        let thread_shared = shared.clone();
        let worker = thread::Builder::new()
            .name("coincide-idle-host".into())
            .spawn(move || {
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    run(backend, settings, &thread_shared)
                }));
                if result.is_err() {
                    let mut state = thread_shared.lock();
                    state.stopping = true;
                    state.pending = None;
                    state.status.phase = Phase::Stopped;
                    state.status.lease = LeaseState::Unknown;
                    state.status.error =
                        Some("host backend panicked; cleanup depends on backend Drop".into());
                    thread_shared.changed.notify_all();
                }
            })
            .context("start idle host worker")?;
        Ok(Self {
            handle: Handle { shared },
            worker: Some(worker),
        })
    }
    pub fn handle(&self) -> Handle {
        self.handle.clone()
    }
    /// Stop immediately and transfer the actual join to a separate thread.
    /// Polling and dropping this owner never join on the caller's thread.
    pub fn into_pending_shutdown(mut self) -> PendingShutdown {
        self.handle.request_shutdown();
        let worker = Arc::new(Mutex::new(self.worker.take()));
        let completion = Arc::new(Mutex::new(None));
        let thread_worker = worker.clone();
        let thread_completion = completion.clone();
        let started = thread::Builder::new()
            .name("coincide-idle-host-join".into())
            .spawn(move || {
                let worker = thread_worker
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .take();
                let result = worker.map_or(Ok(()), |worker| {
                    worker
                        .join()
                        .map_err(|_| "host worker join failed".to_owned())
                });
                // Join returns only after worker-local destructors have completed.
                *thread_completion.lock().unwrap_or_else(|e| e.into_inner()) = Some(result);
            });
        PendingShutdown {
            handle: self.handle.clone(),
            _worker: worker,
            completion,
            start_error: started
                .err()
                .map(|_| "start host join worker failed".into()),
        }
    }
    /// May wait for an in-progress backend call (native startup up to two seconds).
    /// Call off the render thread. Stop status reports cleanup acknowledgement.
    pub fn shutdown(&mut self) -> Result<Status> {
        self.handle.request_shutdown();
        if let Some(worker) = self.worker.take() {
            worker
                .join()
                .map_err(|_| anyhow::anyhow!("host worker join failed"))?;
        }
        Ok(self.handle.status())
    }
}
impl Drop for HostRuntime {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}
fn diagnostic(error: anyhow::Error) -> String {
    format!("{error:#}").chars().take(1024).collect()
}
fn run<B: SleepInhibitor>(backend: B, settings: Settings, shared: &Shared) {
    let mut controller = AwakeController::new(backend);
    let mut current = (0, AwakePolicy::default());
    loop {
        {
            let mut state = shared.lock();
            if state.stopping {
                break;
            }
            if let Some(next) = state.pending.take() {
                current = next;
            }
            state.status.phase = Phase::Applying;
            // Do not report a requested lease as held before backend confirmation.
            shared.changed.notify_all();
        }
        let mut effective = current.1;
        effective.enabled &= settings.allow_inhibition;
        // Always attempt cleanup for a disabled policy, including after a prior
        // health-check failure cleared the controller's held flag.
        let result = if effective.needs_lease() {
            controller.reconcile(effective)
        } else {
            controller.shutdown()
        };
        {
            let mut state = shared.lock();
            state.status.processed_revision = Some(current.0);
            match result {
                Ok(()) => {
                    state.status.acknowledged_revision = Some(current.0);
                    state.status.acknowledged_policy = Some(effective);
                    state.status.lease = if controller.is_held() {
                        LeaseState::Held
                    } else {
                        LeaseState::Released
                    };
                    state.status.error = None;
                }
                Err(error) => {
                    state.status.lease = LeaseState::Unknown;
                    state.status.error = Some(diagnostic(error));
                }
            }
            state.status.phase = Phase::Waiting;
            shared.changed.notify_all();
            drop(
                shared
                    .changed
                    .wait_timeout_while(state, settings.tick_interval, |s| {
                        !s.stopping && s.pending.is_none()
                    })
                    .unwrap_or_else(|e| e.into_inner()),
            );
        }
    }
    {
        let mut state = shared.lock();
        state.status.phase = Phase::Stopping;
        shared.changed.notify_all();
    }
    // Bounded shutdown retries; preserve errors/Unknown if all fail. Native
    // backend Drop is an additional cleanup attempt when controller goes away.
    let mut result = controller.shutdown();
    for _ in 0..2 {
        if result.is_ok() {
            break;
        }
        result = controller.shutdown();
    }
    let mut state = shared.lock();
    state.status.phase = Phase::Stopped;
    match result {
        Ok(()) => {
            state.status.lease = LeaseState::Released;
            state.status.error = None;
        }
        Err(error) => {
            state.status.lease = LeaseState::Unknown;
            state.status.error = Some(diagnostic(error));
        }
    }
    shared.changed.notify_all();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::time::Instant;
    struct UnlockOnDrop(Arc<(Mutex<bool>, Condvar)>);
    impl Drop for UnlockOnDrop {
        fn drop(&mut self) {
            *self.0.0.lock().unwrap() = false;
            self.0.1.notify_all();
        }
    }
    struct Fake {
        acquires: Arc<AtomicUsize>,
        releases: Arc<AtomicUsize>,
        fail: Arc<AtomicBool>,
        fail_release: Arc<AtomicBool>,
        gate: Option<Arc<(Mutex<bool>, Condvar)>>,
    }
    impl SleepInhibitor for Fake {
        fn acquire(&mut self) -> Result<()> {
            self.acquires.fetch_add(1, Ordering::SeqCst);
            if let Some(gate) = &self.gate {
                let (lock, ready) = &**gate;
                let guard = lock.lock().unwrap();
                drop(ready.wait_while(guard, |blocked| *blocked).unwrap());
            }
            if self.fail.load(Ordering::SeqCst) {
                bail!("fixture failure");
            }
            Ok(())
        }
        fn release(&mut self) -> Result<()> {
            self.releases.fetch_add(1, Ordering::SeqCst);
            if self.fail_release.load(Ordering::SeqCst) {
                bail!("fixture release failure");
            }
            Ok(())
        }
        fn check(&mut self) -> Result<()> {
            if self.fail.load(Ordering::SeqCst) {
                bail!("fixture failure");
            }
            Ok(())
        }
    }
    fn fake() -> Fake {
        Fake {
            acquires: Arc::default(),
            releases: Arc::default(),
            fail: Arc::default(),
            fail_release: Arc::default(),
            gate: None,
        }
    }
    fn policy() -> AwakePolicy {
        AwakePolicy {
            enabled: true,
            active_turns: 1,
            ..Default::default()
        }
    }
    fn settings() -> Settings {
        Settings {
            allow_inhibition: true,
            tick_interval: Duration::from_millis(10),
        }
    }
    #[test]
    fn pending_shutdown_requires_actual_join_after_worker_tls_exit() {
        struct ExitGate {
            entered: Arc<AtomicBool>,
            gate: Arc<(Mutex<bool>, Condvar)>,
        }
        impl Drop for ExitGate {
            fn drop(&mut self) {
                self.entered.store(true, Ordering::SeqCst);
                let guard = self.gate.0.lock().unwrap();
                drop(self.gate.1.wait_while(guard, |blocked| *blocked).unwrap());
            }
        }
        thread_local! { static EXIT: std::cell::RefCell<Option<ExitGate>> = const { std::cell::RefCell::new(None) }; }
        struct Gated {
            acquire: Arc<(Mutex<bool>, Condvar)>,
            exit: Arc<(Mutex<bool>, Condvar)>,
            entered: Arc<AtomicBool>,
            calls: Arc<AtomicUsize>,
            releases: Arc<AtomicUsize>,
        }
        impl SleepInhibitor for Gated {
            fn acquire(&mut self) -> Result<()> {
                EXIT.with(|slot| {
                    *slot.borrow_mut() = Some(ExitGate {
                        entered: self.entered.clone(),
                        gate: self.exit.clone(),
                    })
                });
                self.calls.fetch_add(1, Ordering::SeqCst);
                let guard = self.acquire.0.lock().unwrap();
                drop(
                    self.acquire
                        .1
                        .wait_while(guard, |blocked| *blocked)
                        .unwrap(),
                );
                Ok(())
            }
            fn release(&mut self) -> Result<()> {
                self.releases.fetch_add(1, Ordering::SeqCst);
                Ok(())
            }
        }
        let acquire = Arc::new((Mutex::new(true), Condvar::new()));
        let exit = Arc::new((Mutex::new(true), Condvar::new()));
        let _unblock_acquire = UnlockOnDrop(acquire.clone());
        let _unblock_exit = UnlockOnDrop(exit.clone());
        let entered = Arc::new(AtomicBool::new(false));
        let calls = Arc::new(AtomicUsize::new(0));
        let releases = Arc::new(AtomicUsize::new(0));
        let runtime = HostRuntime::spawn(
            Gated {
                acquire: acquire.clone(),
                exit: exit.clone(),
                entered: entered.clone(),
                calls: calls.clone(),
                releases: releases.clone(),
            },
            settings(),
        )
        .unwrap();
        runtime.handle().submit(policy()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while calls.load(Ordering::SeqCst) == 0 {
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
        let before = releases.load(Ordering::SeqCst);
        let pending = runtime.into_pending_shutdown();
        assert!(!pending.poll().ready());
        assert_eq!(releases.load(Ordering::SeqCst), before);
        *acquire.0.lock().unwrap() = false;
        acquire.1.notify_all();
        while !entered.load(Ordering::SeqCst) {
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
        let state = pending.poll();
        assert_eq!(state.status.phase, Phase::Stopped);
        assert_eq!(state.status.lease, LeaseState::Released);
        assert!(
            !state.joined,
            "Stopped/release precedes TLS teardown and actual join"
        );
        assert!(!state.ready());
        *exit.0.lock().unwrap() = false;
        exit.1.notify_all();
        while !pending.poll().joined {
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
        assert!(pending.poll().ready());
    }
    #[test]
    fn pending_shutdown_release_error_remains_unknown_after_join() {
        let backend = fake();
        backend.fail_release.store(true, Ordering::SeqCst);
        let pending = HostRuntime::spawn(backend, settings())
            .unwrap()
            .into_pending_shutdown();
        let deadline = Instant::now() + Duration::from_secs(2);
        while !pending.poll().joined {
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
        let state = pending.poll();
        assert_eq!(state.status.phase, Phase::Stopped);
        assert_eq!(state.status.lease, LeaseState::Unknown);
        assert!(state.status.error.is_some());
        assert!(!state.ready());
    }
    #[test]
    fn default_gate_prevents_acquisition_and_drop_stops_cloned_handles() {
        let backend = fake();
        let acquires = backend.acquires.clone();
        let runtime = HostRuntime::spawn(backend, Settings::default()).unwrap();
        let h = runtime.handle();
        let revision = h.submit(policy()).unwrap();
        let status = h.wait_processed(revision, Duration::from_secs(2));
        assert_eq!(status.acknowledged_revision, Some(revision));
        assert_eq!(status.lease, LeaseState::Released);
        assert_eq!(acquires.load(Ordering::SeqCst), 0);
        drop(runtime);
        assert_eq!(h.status().phase, Phase::Stopped);
        assert!(h.submit(policy()).is_err());
    }
    #[test]
    fn mailbox_coalesces_while_acquire_is_blocked_and_ack_waits() {
        let mut backend = fake();
        let gate = Arc::new((Mutex::new(true), Condvar::new()));
        backend.gate = Some(gate.clone());
        let acquires = backend.acquires.clone();
        let mut runtime = HostRuntime::spawn(backend, settings()).unwrap();
        let h = runtime.handle();
        let _unlock_on_panic = UnlockOnDrop(gate.clone());
        let first = h.submit(policy()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while acquires.load(Ordering::SeqCst) == 0 && Instant::now() < deadline {
            thread::yield_now();
        }
        let mut last = first;
        for count in 1..1000 {
            last = h
                .submit(AwakePolicy {
                    active_turns: count,
                    ..policy()
                })
                .unwrap();
        }
        assert!(h.status().acknowledged_revision.is_none_or(|r| r < first));
        // Exactly one pending snapshot, independent of burst size.
        assert_eq!(h.shared.lock().pending.unwrap().0, last);
        *gate.0.lock().unwrap() = false;
        gate.1.notify_all();
        let status = h.wait_processed(last, Duration::from_secs(2));
        assert_eq!(status.acknowledged_revision, Some(last));
        assert_eq!(status.lease, LeaseState::Held);
        assert_eq!(acquires.load(Ordering::SeqCst), 1);
        assert_eq!(runtime.shutdown().unwrap().lease, LeaseState::Released);
    }
    #[test]
    fn failed_snapshot_is_retried_on_timer_without_new_command() {
        let backend = fake();
        let fail = backend.fail.clone();
        fail.store(true, Ordering::SeqCst);
        let mut runtime = HostRuntime::spawn(backend, settings()).unwrap();
        let h = runtime.handle();
        let revision = h.submit(policy()).unwrap();
        let status = h.wait_processed(revision, Duration::from_secs(2));
        assert_ne!(status.acknowledged_revision, Some(revision));
        assert_eq!(status.lease, LeaseState::Unknown);
        fail.store(false, Ordering::SeqCst);
        let state = h.shared.lock();
        let (state, _) = h
            .shared
            .changed
            .wait_timeout_while(state, Duration::from_secs(2), |s| {
                s.status.acknowledged_revision != Some(revision)
            })
            .unwrap();
        assert_eq!(state.status.acknowledged_revision, Some(revision));
        drop(state);
        runtime.shutdown().unwrap();
    }
    #[test]
    fn shutdown_cannot_be_evicted_and_cleans_up() {
        let backend = fake();
        let releases = backend.releases.clone();
        let mut runtime = HostRuntime::spawn(backend, settings()).unwrap();
        let h = runtime.handle();
        let revision = h.submit(policy()).unwrap();
        h.wait_processed(revision, Duration::from_secs(2));
        h.request_shutdown();
        assert!(h.submit(policy()).is_err());
        let stopped = runtime.shutdown().unwrap();
        assert_eq!(stopped.phase, Phase::Stopped);
        assert_eq!(stopped.lease, LeaseState::Released);
        assert!(releases.load(Ordering::SeqCst) > 0);
    }
    #[test]
    fn cleanup_failure_is_bounded_and_never_reports_released() {
        let backend = fake();
        let fail_release = backend.fail_release.clone();
        let releases = backend.releases.clone();
        let mut runtime = HostRuntime::spawn(backend, settings()).unwrap();
        let h = runtime.handle();
        let revision = h.submit(policy()).unwrap();
        assert_eq!(
            h.wait_processed(revision, Duration::from_secs(2)).lease,
            LeaseState::Held
        );
        fail_release.store(true, Ordering::SeqCst);
        let before = releases.load(Ordering::SeqCst);
        let stopped = runtime.shutdown().unwrap();
        assert_eq!(stopped.phase, Phase::Stopped);
        assert_eq!(stopped.lease, LeaseState::Unknown);
        assert!(stopped.error.is_some());
        assert_eq!(releases.load(Ordering::SeqCst) - before, 3);
    }
    #[test]
    fn backend_panic_is_visible_and_closes_mailbox() {
        struct Panics;
        impl SleepInhibitor for Panics {
            fn acquire(&mut self) -> Result<()> {
                panic!("synthetic backend panic");
            }
            fn release(&mut self) -> Result<()> {
                Ok(())
            }
        }
        let mut runtime = HostRuntime::spawn(Panics, settings()).unwrap();
        let h = runtime.handle();
        let revision = h.submit(policy()).unwrap();
        let stopped = h.wait_processed(revision, Duration::from_secs(2));
        assert_eq!(stopped.phase, Phase::Stopped);
        assert_eq!(stopped.lease, LeaseState::Unknown);
        assert!(h.submit(policy()).is_err());
        runtime.shutdown().unwrap();
    }
    #[test]
    fn invalid_timer_is_rejected_without_starting_worker() {
        assert!(
            HostRuntime::spawn(
                fake(),
                Settings {
                    tick_interval: Duration::ZERO,
                    ..Settings::default()
                }
            )
            .is_err()
        );
    }
}
