//! Serialized session-only notification delivery. No Engine locks or persistent
//! queue live here. Register/wire from the parent after feature/test validation.
use crate::notifications::{Backend, DesktopNotifications, Permission, Settings};
use anyhow::{Context, Result, bail};
use coincide_core::platform_host::notifications::{
    Alert, Delivery, DesktopActivity, Dispatch, Dispatcher, Environment, EventKey,
};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
    mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError},
};
use std::thread::{self, JoinHandle};
use std::time::Duration;
use uuid::Uuid;

pub enum Command {
    Configure(Settings),
    RefreshPermission,
    /// Only enqueue from an explicit native permission button click.
    RequestPermission,
    ClearThread(Uuid),
    Dispatch {
        claim_id: Uuid,
        alert: Alert,
        desktop: DesktopActivity,
        now: u64,
    },
}
pub struct Queued {
    pub command_id: Uuid,
    pub command: Command,
}
pub enum SubmitError {
    Full(Command),
    Closed(Command),
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ack {
    Delivered(Delivery),
    Suppressed,
    Cancelled,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    Attempted,
    Suppressed,
    Disabled,
    Duplicate,
    LedgerFull,
    BackendPanic,
}
#[derive(Debug)]
pub enum Outcome {
    Configured,
    Permission(Permission),
    Cleared {
        thread: Uuid,
        error: Option<String>,
    },
    Notification {
        claim_id: Uuid,
        key: EventKey,
        ack: Ack,
        reason: Reason,
    },
    Rejected(String),
}
#[derive(Debug)]
pub struct Receipt {
    pub command_id: Uuid,
    pub outcome: Outcome,
}
#[derive(Debug, Clone)]
pub struct Status {
    pub configured: bool,
    pub enabled: bool,
    pub permission: Permission,
    pub error: Option<String>,
    pub busy: bool,
    pub stopped: bool,
    pub receipt_backpressure: bool,
}
impl Default for Status {
    fn default() -> Self {
        Self {
            configured: false,
            enabled: false,
            permission: Permission::Unknown,
            error: None,
            busy: false,
            stopped: false,
            receipt_backpressure: false,
        }
    }
}
#[derive(Clone)]
pub struct Handle {
    commands: SyncSender<Queued>,
    submission: Arc<Mutex<()>>,
    stop: Arc<AtomicBool>,
    status: Arc<Mutex<Status>>,
}
impl Handle {
    /// Bounded, nonblocking submission. Full/Closed returns the original command;
    /// the parent retains its core claim until a definitive receipt/cancellation.
    pub fn try_send(&self, command: Command) -> std::result::Result<Uuid, SubmitError> {
        let Ok(_submission) = self.submission.try_lock() else {
            return Err(SubmitError::Full(command));
        };
        if self.stop.load(Ordering::Acquire) {
            return Err(SubmitError::Closed(command));
        }
        let command_id = Uuid::new_v4();
        match self.commands.try_send(Queued {
            command_id,
            command,
        }) {
            Ok(()) => Ok(command_id),
            Err(TrySendError::Full(item)) => Err(SubmitError::Full(item.command)),
            Err(TrySendError::Disconnected(item)) => Err(SubmitError::Closed(item.command)),
        }
    }
    /// Latest-only, bounded status slot. Busy lock returns None; GPUI never waits.
    pub fn try_status(&self) -> Option<Status> {
        self.status.try_lock().ok().map(|s| s.clone())
    }
    pub fn request_shutdown(&self) {
        self.stop.store(true, Ordering::Release);
    }
}
/// Caller must account for these before dropping the core outbox/Engine. Pending
/// receipt may describe an actual send; unprocessed commands are definitely unsent.
pub struct WorkerExit {
    pub unprocessed: Vec<Queued>,
    pub pending_receipt: Option<Receipt>,
}
pub struct NotificationRuntime {
    handle: Handle,
    receipts: Receiver<Receipt>,
    worker: Option<JoinHandle<WorkerExit>>,
}
impl NotificationRuntime {
    pub fn spawn_native() -> Result<Self> {
        #[cfg(all(target_os = "macos", feature = "native-notifications"))]
        {
            Self::spawn(crate::notifications::macos::NativeBackend, 32)
        }
        #[cfg(not(all(target_os = "macos", feature = "native-notifications")))]
        {
            Self::spawn(crate::notifications::UnsupportedBackend, 32)
        }
    }
    /// Backend constructors must be effect-free. Worker startup never calls the
    /// backend; even status/clear/request commands require prior Configure.
    pub fn spawn<B: Backend + Send + 'static>(backend: B, capacity: usize) -> Result<Self> {
        if !(1..=256).contains(&capacity) {
            bail!("notification channel capacity must be 1..=256");
        }
        let (tx, commands) = mpsc::sync_channel(capacity);
        let (receipts_tx, receipts) = mpsc::sync_channel(capacity);
        let handle = Handle {
            commands: tx,
            submission: Arc::new(Mutex::new(())),
            stop: Arc::new(AtomicBool::new(false)),
            status: Arc::new(Mutex::new(Status::default())),
        };
        let worker_handle = handle.clone();
        let worker = thread::Builder::new()
            .name("coincide-notifications".into())
            .spawn(move || run(backend, worker_handle, commands, receipts_tx))
            .context("start notification worker")?;
        Ok(Self {
            handle,
            receipts,
            worker: Some(worker),
        })
    }
    pub fn handle(&self) -> Handle {
        self.handle.clone()
    }
    /// Exactly one parent consumer drains and acknowledges core claims, outside
    /// native worker execution. No receipt is overwritten/coalesced.
    pub fn try_receipt(&self) -> std::result::Result<Receipt, TryRecvError> {
        self.receipts.try_recv()
    }
    /// Call off GPUI. Native callbacks already in progress may take seconds.
    /// Drain queued receipts too, then account for WorkerExit before Engine teardown.
    pub fn shutdown(&mut self) -> Result<WorkerExit> {
        self.handle.request_shutdown();
        match self.worker.take() {
            Some(worker) => worker.join().map_err(|_| {
                anyhow::anyhow!("notification worker panicked; in-flight claim remains uncertain")
            }),
            None => Ok(WorkerExit {
                unprocessed: vec![],
                pending_receipt: None,
            }),
        }
    }
}
impl Drop for NotificationRuntime {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}
fn publish(handle: &Handle, status: &Status) {
    *handle.status.lock().unwrap_or_else(|e| e.into_inner()) = status.clone();
}
fn run<B: Backend>(
    backend: B,
    handle: Handle,
    commands: Receiver<Queued>,
    receipts: SyncSender<Receipt>,
) -> WorkerExit {
    let mut adapter = DesktopNotifications::new(backend);
    let mut dispatcher = Dispatcher::new(4096);
    let mut status = Status::default();
    let mut pending = None;
    while !handle.stop.load(Ordering::Acquire) {
        if let Some(receipt) = pending.take() {
            match receipts.try_send(receipt) {
                Ok(()) => {
                    status.receipt_backpressure = false;
                    publish(&handle, &status);
                }
                Err(TrySendError::Full(receipt)) => {
                    pending = Some(receipt);
                    status.receipt_backpressure = true;
                    publish(&handle, &status);
                    thread::park_timeout(Duration::from_millis(10));
                    continue;
                }
                Err(TrySendError::Disconnected(receipt)) => {
                    pending = Some(receipt);
                    break;
                }
            }
        }
        let queued = match commands.recv_timeout(Duration::from_millis(20)) {
            Ok(item) => item,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        };
        // Stop racing receive: retain the command as definitely unsent on exit.
        if handle.stop.load(Ordering::Acquire) {
            let _submission = handle.submission.lock().unwrap_or_else(|e| e.into_inner());
            let mut unprocessed = vec![queued];
            unprocessed.extend(commands.try_iter());
            status.stopped = true;
            publish(&handle, &status);
            return WorkerExit {
                unprocessed,
                pending_receipt: pending,
            };
        }
        status.busy = true;
        publish(&handle, &status);
        let identity = match &queued.command {
            Command::Dispatch {
                claim_id, alert, ..
            } => Some((*claim_id, alert.key)),
            _ => None,
        };
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            process(&mut adapter, &mut dispatcher, &mut status, queued.command)
        }));
        let outcome = match result {
            Ok(outcome) => outcome,
            Err(_) => {
                status.error = Some(
                    "notification backend panicked; outstanding claims require reconciliation"
                        .into(),
                );
                handle.stop.store(true, Ordering::Release);
                match identity {
                    Some((claim_id, key)) => Outcome::Notification {
                        claim_id,
                        key,
                        ack: Ack::Delivered(Delivery::Uncertain),
                        reason: Reason::BackendPanic,
                    },
                    None => Outcome::Rejected(status.error.clone().unwrap()),
                }
            }
        };
        status.busy = false;
        status.permission = adapter.permission_status();
        if !handle.stop.load(Ordering::Acquire) {
            status.error = adapter.last_error().map(str::to_owned);
        }
        publish(&handle, &status);
        pending = Some(Receipt {
            command_id: queued.command_id,
            outcome,
        });
    }
    status.stopped = true;
    status.busy = false;
    handle.stop.store(true, Ordering::Release);
    publish(&handle, &status);
    let _submission = handle.submission.lock().unwrap_or_else(|e| e.into_inner());
    WorkerExit {
        unprocessed: commands.try_iter().collect(),
        pending_receipt: pending,
    }
}
fn process<B: Backend>(
    adapter: &mut DesktopNotifications<B>,
    dispatcher: &mut Dispatcher,
    status: &mut Status,
    command: Command,
) -> Outcome {
    match command {
        Command::Configure(settings) => {
            status.configured = true;
            status.enabled = settings.enabled;
            adapter.set_settings(settings);
            Outcome::Configured
        }
        Command::Dispatch {
            claim_id,
            alert,
            desktop,
            now,
        } => {
            let result = dispatcher.dispatch(
                &alert,
                &Environment {
                    enabled: status.configured && status.enabled,
                    desktop,
                    devices: &[],
                    push_targets: &[],
                    push_available: false,
                    presence_lifetime: 0,
                    now,
                },
                adapter,
            );
            let (ack, reason) = match result {
                Dispatch::Attempted { result, .. } => (Ack::Delivered(result), Reason::Attempted),
                Dispatch::Suppressed => (Ack::Suppressed, Reason::Suppressed),
                Dispatch::Disabled => (Ack::Cancelled, Reason::Disabled),
                Dispatch::Duplicate => (Ack::Delivered(Delivery::Uncertain), Reason::Duplicate),
                Dispatch::LedgerFull => (Ack::Delivered(Delivery::Unavailable), Reason::LedgerFull),
            };
            Outcome::Notification {
                claim_id,
                key: alert.key,
                ack,
                reason,
            }
        }
        _ if !status.configured => {
            Outcome::Rejected("configure notification worker before native operations".into())
        }
        Command::RefreshPermission => Outcome::Permission(adapter.refresh_permission()),
        Command::RequestPermission => match adapter.request_permission_from_user_action() {
            Ok(p) => Outcome::Permission(p),
            Err(e) => Outcome::Rejected(e.to_string().chars().take(512).collect()),
        },
        Command::ClearThread(_)
            if !status.enabled || adapter.permission_status() != Permission::Authorized =>
        {
            Outcome::Rejected(
                "Notification clearing requires enabled notifications and observed authorization"
                    .into(),
            )
        }
        Command::ClearThread(thread) => {
            dispatcher.thread_seen(thread, adapter);
            Outcome::Cleared {
                thread,
                error: adapter.last_error().map(str::to_owned),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notifications::Payload;
    use coincide_core::platform_host::notifications::AlertKind;
    use std::time::Instant;
    #[derive(Default)]
    struct State {
        calls: Vec<&'static str>,
    }
    struct Fake {
        state: Arc<Mutex<State>>,
        result: Delivery,
    }
    impl Backend for Fake {
        fn permission(&mut self) -> Result<Permission> {
            self.state.lock().unwrap().calls.push("status");
            Ok(Permission::Authorized)
        }
        fn request_permission(&mut self) -> Result<Permission> {
            self.state.lock().unwrap().calls.push("request");
            Ok(Permission::Authorized)
        }
        fn post(&mut self, _: &Payload) -> Delivery {
            self.state.lock().unwrap().calls.push("post");
            self.result
        }
        fn clear_thread(&mut self, _: Uuid) -> Result<()> {
            self.state.lock().unwrap().calls.push("clear");
            Ok(())
        }
    }
    fn receipt(runtime: &NotificationRuntime) -> Receipt {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            if let Ok(r) = runtime.try_receipt() {
                return r;
            }
            assert!(Instant::now() < deadline, "receipt timed out");
            thread::yield_now();
        }
    }
    fn send(h: &Handle, command: Command) {
        assert!(h.try_send(command).is_ok());
    }
    fn alert(key: EventKey) -> Alert {
        Alert {
            key,
            title: "generic".into(),
            body: None,
        }
    }
    fn key() -> EventKey {
        EventKey {
            thread: Uuid::new_v4(),
            item: Uuid::new_v4(),
            kind: AlertKind::Completed,
        }
    }
    fn job(key: EventKey) -> Command {
        Command::Dispatch {
            claim_id: Uuid::new_v4(),
            alert: alert(key),
            desktop: DesktopActivity {
                app_active: false,
                visible_thread: None,
                idle_seconds: 0,
                locked: false,
                display_asleep: false,
            },
            now: 1000,
        }
    }
    fn setup(result: Delivery, capacity: usize) -> (NotificationRuntime, Arc<Mutex<State>>) {
        let state = Arc::new(Mutex::new(State::default()));
        (
            NotificationRuntime::spawn(
                Fake {
                    state: state.clone(),
                    result,
                },
                capacity,
            )
            .unwrap(),
            state,
        )
    }
    #[test]
    fn startup_and_preconfiguration_commands_have_no_native_effects() {
        let (mut runtime, state) = setup(Delivery::Accepted, 8);
        let h = runtime.handle();
        assert!(state.lock().unwrap().calls.is_empty());
        for command in [
            Command::RefreshPermission,
            Command::RequestPermission,
            Command::ClearThread(Uuid::new_v4()),
        ] {
            send(&h, command);
            assert!(matches!(receipt(&runtime).outcome, Outcome::Rejected(_)));
        }
        send(&h, job(key()));
        assert!(matches!(
            receipt(&runtime).outcome,
            Outcome::Notification {
                ack: Ack::Cancelled,
                ..
            }
        ));
        send(&h, Command::Configure(Settings::default()));
        receipt(&runtime);
        assert!(state.lock().unwrap().calls.is_empty());
        runtime.shutdown().unwrap();
    }
    #[test]
    fn dispatch_permission_and_clear_are_serialized_and_uncertainty_is_terminal() {
        let (mut runtime, state) = setup(Delivery::Uncertain, 8);
        let h = runtime.handle();
        let key = key();
        send(
            &h,
            Command::Configure(Settings {
                enabled: true,
                include_preview: false,
            }),
        );
        receipt(&runtime);
        send(&h, Command::RequestPermission);
        receipt(&runtime);
        send(&h, job(key));
        assert!(matches!(
            receipt(&runtime).outcome,
            Outcome::Notification {
                ack: Ack::Delivered(Delivery::Uncertain),
                ..
            }
        ));
        send(&h, Command::ClearThread(key.thread));
        receipt(&runtime);
        // A late external completion cannot mutate a prior receipt or trigger a
        // replay. Native OS late-arrival clearing itself remains backend acceptance.

        send(&h, job(key));
        assert!(matches!(
            receipt(&runtime).outcome,
            Outcome::Notification {
                reason: Reason::Duplicate,
                ack: Ack::Delivered(Delivery::Uncertain),
                ..
            }
        ));
        assert_eq!(
            state.lock().unwrap().calls,
            vec!["request", "status", "post", "clear"]
        );
        runtime.shutdown().unwrap();
    }
    #[test]
    fn clear_waits_for_delayed_post_completion_and_never_replays_it() {
        struct CallbackFake {
            calls: Arc<Mutex<Vec<&'static str>>>,
            entered: SyncSender<()>,
            completion: Receiver<Delivery>,
        }
        impl Backend for CallbackFake {
            fn permission(&mut self) -> Result<Permission> {
                Ok(Permission::Authorized)
            }
            fn request_permission(&mut self) -> Result<Permission> {
                unreachable!()
            }
            fn post(&mut self, _: &Payload) -> Delivery {
                self.calls.lock().unwrap().push("post");
                self.entered.try_send(()).unwrap();
                self.completion.recv().unwrap()
            }
            fn clear_thread(&mut self, _: Uuid) -> Result<()> {
                self.calls.lock().unwrap().push("clear");
                Ok(())
            }
        }
        struct ReleaseOnDrop(Option<SyncSender<Delivery>>);
        impl Drop for ReleaseOnDrop {
            fn drop(&mut self) {
                if let Some(tx) = self.0.take() {
                    let _ = tx.try_send(Delivery::Uncertain);
                }
            }
        }
        let calls = Arc::new(Mutex::new(vec![]));
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (completion_tx, completion_rx) = mpsc::sync_channel(1);
        let mut runtime = NotificationRuntime::spawn(
            CallbackFake {
                calls: calls.clone(),
                entered: entered_tx,
                completion: completion_rx,
            },
            8,
        )
        .unwrap();
        let mut release = ReleaseOnDrop(Some(completion_tx));
        let h = runtime.handle();
        let key = key();
        send(
            &h,
            Command::Configure(Settings {
                enabled: true,
                include_preview: false,
            }),
        );
        receipt(&runtime);
        send(&h, job(key));
        entered_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        send(&h, Command::ClearThread(key.thread));
        assert_eq!(*calls.lock().unwrap(), vec!["post"]);
        release
            .0
            .take()
            .unwrap()
            .try_send(Delivery::Uncertain)
            .unwrap();
        assert!(matches!(
            receipt(&runtime).outcome,
            Outcome::Notification {
                ack: Ack::Delivered(Delivery::Uncertain),
                ..
            }
        ));
        assert!(matches!(receipt(&runtime).outcome, Outcome::Cleared { .. }));
        send(&h, job(key));
        receipt(&runtime);
        assert_eq!(*calls.lock().unwrap(), vec!["post", "clear"]);
        runtime.shutdown().unwrap();
    }
    #[test]
    fn saturated_receipts_pause_work_and_shutdown_returns_unsent_commands() {
        let (mut runtime, state) = setup(Delivery::Accepted, 1);
        let h = runtime.handle();
        send(
            &h,
            Command::Configure(Settings {
                enabled: true,
                include_preview: false,
            }),
        );
        receipt(&runtime);
        send(&h, Command::RefreshPermission);
        // Wait for first native operation to fill the receipt path.
        let deadline = Instant::now() + Duration::from_secs(3);
        while state.lock().unwrap().calls.is_empty() {
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
        // Queue until bounded mailbox reports Full, retaining exactly the command.
        let rejected = loop {
            match h.try_send(Command::ClearThread(Uuid::nil())) {
                Ok(_) => {}
                Err(SubmitError::Full(c)) => break c,
                Err(_) => panic!("unexpected close"),
            }
        };
        assert!(matches!(rejected, Command::ClearThread(id) if id.is_nil()));
        while !h.try_status().is_some_and(|s| s.receipt_backpressure) {
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
        assert!(state.lock().unwrap().calls.len() <= 2);
        let exit = runtime.shutdown().unwrap();
        assert!(
            exit.pending_receipt.is_some()
                || !exit.unprocessed.is_empty()
                || runtime.try_receipt().is_ok()
        );
        assert!(matches!(
            h.try_send(Command::RefreshPermission),
            Err(SubmitError::Closed(Command::RefreshPermission))
        ));
    }
    #[test]
    fn clear_requires_enabled_and_observed_authorization_without_implicit_queries() {
        let (mut runtime, state) = setup(Delivery::Accepted, 8);
        let h = runtime.handle();
        let thread = Uuid::new_v4();
        send(&h, Command::Configure(Settings::default()));
        receipt(&runtime);
        send(&h, Command::ClearThread(thread));
        assert!(matches!(receipt(&runtime).outcome, Outcome::Rejected(_)));
        send(
            &h,
            Command::Configure(Settings {
                enabled: true,
                include_preview: false,
            }),
        );
        receipt(&runtime);
        send(&h, Command::ClearThread(thread));
        assert!(matches!(receipt(&runtime).outcome, Outcome::Rejected(_)));
        assert!(state.lock().unwrap().calls.is_empty());
        send(&h, Command::RefreshPermission);
        receipt(&runtime);
        send(&h, Command::ClearThread(thread));
        assert!(matches!(
            receipt(&runtime).outcome,
            Outcome::Cleared { error: None, .. }
        ));
        send(&h, Command::Configure(Settings::default()));
        receipt(&runtime);
        send(&h, Command::ClearThread(thread));
        assert!(matches!(receipt(&runtime).outcome, Outcome::Rejected(_)));
        assert_eq!(state.lock().unwrap().calls, vec!["status", "clear"]);
        runtime.shutdown().unwrap();
    }
    #[test]
    fn disable_and_seen_controls_ack_in_order_and_cancel_subsequent_dispatch() {
        let (mut runtime, state) = setup(Delivery::Accepted, 8);
        let h = runtime.handle();
        let original = key();
        send(
            &h,
            Command::Configure(Settings {
                enabled: true,
                include_preview: false,
            }),
        );
        receipt(&runtime);
        send(&h, job(original));
        assert!(matches!(
            receipt(&runtime).outcome,
            Outcome::Notification {
                ack: Ack::Delivered(Delivery::Accepted),
                ..
            }
        ));
        send(&h, Command::Configure(Settings::default()));
        send(&h, Command::ClearThread(original.thread));
        send(&h, job(key()));
        assert!(matches!(receipt(&runtime).outcome, Outcome::Configured));
        assert!(matches!(receipt(&runtime).outcome, Outcome::Rejected(_)));
        assert!(matches!(
            receipt(&runtime).outcome,
            Outcome::Notification {
                ack: Ack::Cancelled,
                reason: Reason::Disabled,
                ..
            }
        ));
        assert_eq!(state.lock().unwrap().calls, vec!["status", "post"]);
        runtime.shutdown().unwrap();
    }
    #[test]
    fn backend_panic_returns_uncertain_identity_without_requeue() {
        struct Panics;
        impl Backend for Panics {
            fn permission(&mut self) -> Result<Permission> {
                Ok(Permission::Authorized)
            }
            fn request_permission(&mut self) -> Result<Permission> {
                unreachable!()
            }
            fn post(&mut self, _: &Payload) -> Delivery {
                panic!("synthetic post panic");
            }
            fn clear_thread(&mut self, _: Uuid) -> Result<()> {
                Ok(())
            }
        }
        let mut runtime = NotificationRuntime::spawn(Panics, 8).unwrap();
        let h = runtime.handle();
        let key = key();
        send(
            &h,
            Command::Configure(Settings {
                enabled: true,
                include_preview: false,
            }),
        );
        receipt(&runtime);
        send(&h, job(key));
        let deadline = Instant::now() + Duration::from_secs(3);
        while !h.try_status().is_some_and(|s| s.stopped) {
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
        let exit = runtime.shutdown().unwrap();
        assert!(
            matches!(exit.pending_receipt.unwrap().outcome, Outcome::Notification { key: returned, ack: Ack::Delivered(Delivery::Uncertain), reason: Reason::BackendPanic, .. } if returned == key)
        );
    }
    #[test]
    fn explicit_retry_only_for_definitely_unavailable_and_visible_suppression() {
        let (mut runtime, state) = setup(Delivery::Unavailable, 8);
        let h = runtime.handle();
        let key = key();
        send(
            &h,
            Command::Configure(Settings {
                enabled: true,
                include_preview: false,
            }),
        );
        receipt(&runtime);
        for _ in 0..2 {
            send(&h, job(key));
            assert!(matches!(
                receipt(&runtime).outcome,
                Outcome::Notification {
                    ack: Ack::Delivered(Delivery::Unavailable),
                    ..
                }
            ));
        }
        let Command::Dispatch {
            claim_id,
            alert,
            mut desktop,
            now,
        } = job(key)
        else {
            unreachable!()
        };
        desktop.app_active = true;
        desktop.visible_thread = Some(key.thread);
        send(
            &h,
            Command::Dispatch {
                claim_id,
                alert,
                desktop,
                now,
            },
        );
        assert!(matches!(
            receipt(&runtime).outcome,
            Outcome::Notification {
                ack: Ack::Suppressed,
                ..
            }
        ));
        assert_eq!(
            state.lock().unwrap().calls,
            vec!["status", "post", "status", "post"]
        );
        runtime.shutdown().unwrap();
    }
}
