//! Persistent native Settings entity and background Engine/outbox bridge.
//! Constructor/UI/Drop never wait for Engine, native callbacks or worker joins.
use crate::notification_runtime::{
    self as worker, Command, NotificationRuntime, Outcome, Receipt, SubmitError,
};
use crate::notifications::{Permission, Settings};
use anyhow::{Context as _, Result, ensure};
use coincide_core::api::{
    SharedEngine,
    notification_events::{NotificationAck, NotificationClaim},
};
use coincide_core::platform_host::notifications::{Delivery, DesktopActivity, EventKey};
use gpui_kit::{base::Disableable, component::button::Button, *};
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender},
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;
const WINDOW: usize = 8;
const CONTROLS: usize = 16;
fn native_compiled() -> bool {
    cfg!(all(target_os = "macos", feature = "native-notifications"))
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub native_compiled: bool,
    pub bridge_ready: bool,
    /// Core explicitly reports only an outbox, not native connectivity.
    pub core_delivery_connected: bool,
    pub enabled: bool,
    pub permission: Permission,
    pub busy: bool,
    pub outstanding: usize,
    pub stopped: bool,
    pub error: Option<String>,
}
impl Default for Status {
    fn default() -> Self {
        Self {
            native_compiled: native_compiled(),
            bridge_ready: false,
            core_delivery_connected: false,
            enabled: false,
            permission: Permission::Unknown,
            busy: true,
            outstanding: 0,
            stopped: false,
            error: None,
        }
    }
}
#[derive(Clone, Copy)]
pub enum Action {
    Configure(bool),
    AllowNotifications,
    RefreshStatus,
}
#[derive(Clone)]
pub struct BridgeHandle {
    actions: SyncSender<Action>,
    activity: Arc<Mutex<Option<DesktopActivity>>>,
    status: Arc<Mutex<Status>>,
    stop: Arc<AtomicBool>,
}
impl BridgeHandle {
    pub fn try_action(&self, action: Action) -> bool {
        !self.stop.load(Ordering::Acquire) && self.actions.try_send(action).is_ok()
    }
    /// Latest-only bounded slot. Return false means parent retries a fresh snapshot.
    pub fn update_activity(&self, activity: DesktopActivity) -> bool {
        if self.stop.load(Ordering::Acquire) {
            return false;
        }
        let Ok(mut latest) = self.activity.try_lock() else {
            return false;
        };
        *latest = Some(activity);
        true
    }
    pub fn try_status(&self) -> Option<Status> {
        self.status.try_lock().ok().map(|s| s.clone())
    }
    pub fn request_shutdown(&self) {
        self.stop.store(true, Ordering::Release);
    }
}
pub struct Bridge {
    handle: BridgeHandle,
}
impl Bridge {
    pub fn start(engine: SharedEngine) -> Result<Self> {
        Self::start_with(
            EngineAccess(engine),
            NotificationRuntime::spawn_native,
            native_compiled(),
        )
    }
    fn start_with<E, F>(mut engine: E, factory: F, compiled: bool) -> Result<Self>
    where
        E: Outbox + Send + 'static,
        F: FnOnce() -> Result<NotificationRuntime> + Send + 'static,
    {
        let (tx, actions) = mpsc::sync_channel(CONTROLS);
        let handle = BridgeHandle {
            actions: tx,
            activity: Arc::new(Mutex::new(None)),
            status: Arc::new(Mutex::new(Status {
                native_compiled: compiled,
                ..Status::default()
            })),
            stop: Arc::new(AtomicBool::new(false)),
        };
        let h = handle.clone();
        // Detached join ownership is deliberate: the background thread owns and
        // joins the native worker. Entity Drop only signals, never blocks GPUI.
        thread::Builder::new()
            .name("coincide-notification-bridge".into())
            .spawn(move || {
                let run =
                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<()> {
                        let runtime = factory()?;
                        let enabled = engine.enabled()?;
                        let mut pump = Pump::new(runtime, compiled, enabled);
                        while !h.stop.load(Ordering::Acquire) && !pump.closed {
                            for _ in 0..CONTROLS {
                                let Ok(action) = actions.try_recv() else {
                                    break;
                                };
                                pump.action(&mut engine, action);
                            }
                            let activity = *h.activity.lock().unwrap_or_else(|e| e.into_inner());
                            pump.tick(&mut engine, activity);
                            *h.status.lock().unwrap_or_else(|e| e.into_inner()) =
                                pump.status.clone();
                            thread::park_timeout(Duration::from_millis(25));
                        }
                        pump.finish(&mut engine);
                        *h.status.lock().unwrap_or_else(|e| e.into_inner()) = pump.status;
                        Ok(())
                    }));
                let mut status = h.status.lock().unwrap_or_else(|e| e.into_inner());
                match run {
                    Ok(Ok(())) => {}
                    Ok(Err(e)) => status.error = Some(short(e)),
                    Err(_) => {
                        status.error = Some(
                            "Notification bridge panicked; outstanding claims remain uncertain"
                                .into(),
                        )
                    }
                }
                status.stopped = true;
                status.bridge_ready = false;
                status.busy = false;
                h.stop.store(true, Ordering::Release);
            })
            .context("start notification bridge")?;
        Ok(Self { handle })
    }
    pub fn handle(&self) -> BridgeHandle {
        self.handle.clone()
    }
}
impl Drop for Bridge {
    fn drop(&mut self) {
        self.handle.request_shutdown();
    }
}
fn short(error: anyhow::Error) -> String {
    error.to_string().chars().take(512).collect()
}
trait Outbox {
    fn enabled(&mut self) -> Result<bool>;
    fn configure(&mut self, enabled: bool) -> Result<()>;
    fn claim(&mut self, limit: usize) -> Result<Vec<NotificationClaim>>;
    fn ack(&mut self, claim: Uuid, key: EventKey, ack: NotificationAck) -> Result<()>;
}
struct EngineAccess(SharedEngine);
impl Outbox for EngineAccess {
    fn enabled(&mut self) -> Result<bool> {
        // Direct local-document read avoids dispatch()/poll() causing unrelated
        // provider/schedule work merely because the Settings entity was created.
        let engine = self
            .0
            .lock()
            .map_err(|_| anyhow::anyhow!("Engine lock failed"))?;
        let Some(doc) = engine
            .store
            .local_document("rust-native-notifications.json")?
        else {
            return Ok(false);
        };
        ensure!(
            doc["version"] == 1,
            "Unsupported notification configuration"
        );
        doc["enabled"]
            .as_bool()
            .context("Invalid notification enabled setting")
    }
    fn configure(&mut self, enabled: bool) -> Result<()> {
        self.0
            .lock()
            .map_err(|_| anyhow::anyhow!("Engine lock failed"))?
            .configure_native_notifications(enabled)?;
        Ok(())
    }
    fn claim(&mut self, limit: usize) -> Result<Vec<NotificationClaim>> {
        Ok(self
            .0
            .lock()
            .map_err(|_| anyhow::anyhow!("Engine lock failed"))?
            .claim_notification_events(limit))
    }
    fn ack(&mut self, claim: Uuid, key: EventKey, ack: NotificationAck) -> Result<()> {
        self.0
            .lock()
            .map_err(|_| anyhow::anyhow!("Engine lock failed"))?
            .ack_notification_event(claim, key, ack)
    }
}
#[derive(Clone, Copy)]
struct Identity {
    claim: Uuid,
    key: EventKey,
}
enum Flight {
    Configure(bool),
    Control,
    Event(Identity),
}
struct PendingAck {
    id: Identity,
    ack: NotificationAck,
}
struct Pump {
    runtime: NotificationRuntime,
    handle: worker::Handle,
    status: Status,
    desired: Option<bool>,
    pending: VecDeque<Command>,
    flights: BTreeMap<Uuid, Flight>,
    failed_acks: Vec<PendingAck>,
    last_seen: Option<Uuid>,
    closed: bool,
}
impl Pump {
    fn new(runtime: NotificationRuntime, compiled: bool, enabled: bool) -> Self {
        Self {
            handle: runtime.handle(),
            runtime,
            status: Status {
                enabled,
                native_compiled: compiled,
                ..Status::default()
            },
            desired: Some(enabled && compiled),
            pending: VecDeque::new(),
            flights: BTreeMap::new(),
            failed_acks: vec![],
            last_seen: None,
            closed: false,
        }
    }
    fn ack(&mut self, engine: &mut impl Outbox, id: Identity, ack: NotificationAck) {
        if let Err(e) = engine.ack(id.claim, id.key, ack) {
            self.status.error = Some(short(e));
            self.failed_acks.push(PendingAck { id, ack });
        }
    }
    fn cancel_pending(&mut self, engine: &mut impl Outbox, thread: Option<Uuid>) {
        let mut keep = VecDeque::new();
        while let Some(command) = self.pending.pop_front() {
            match command {
                Command::Dispatch {
                    claim_id, alert, ..
                } if thread.is_none_or(|t| t == alert.key.thread) => self.ack(
                    engine,
                    Identity {
                        claim: claim_id,
                        key: alert.key,
                    },
                    if thread.is_some() {
                        NotificationAck::Suppressed
                    } else {
                        NotificationAck::Cancelled
                    },
                ),
                Command::RequestPermission if thread.is_none() => {}
                command => keep.push_back(command),
            }
        }
        self.pending = keep;
    }
    fn action(&mut self, engine: &mut impl Outbox, action: Action) {
        match action {
            Action::Configure(enabled) => {
                if enabled && !self.status.native_compiled {
                    self.status.error =
                        Some("Native notifications are not compiled in this build".into());
                    return;
                }
                match engine.configure(enabled) {
                    Ok(()) => {
                        self.status.error = None;
                        self.status.enabled = enabled;
                        self.status.bridge_ready = false;
                        self.desired = Some(enabled);
                        if !enabled {
                            self.cancel_pending(engine, None);
                        }
                    }
                    Err(e) => self.status.error = Some(short(e)),
                }
            }
            action if self.pending.len() < CONTROLS && self.desired.is_none() => {
                self.pending.push_back(match action {
                    Action::AllowNotifications => Command::RequestPermission,
                    Action::RefreshStatus => Command::RefreshPermission,
                    _ => unreachable!(),
                })
            }
            _ => {
                self.status.error = Some(
                    "Notification controls busy; try again after configuration completes".into(),
                )
            }
        }
    }
    fn receipt(&mut self, engine: &mut impl Outbox, receipt: Receipt) {
        let Some(flight) = self.flights.remove(&receipt.command_id) else {
            self.status.error = Some("Unexpected notification receipt".into());
            return;
        };
        match (flight, receipt.outcome) {
            (Flight::Configure(enabled), Outcome::Configured) => {
                if self.desired.is_none() {
                    self.status.bridge_ready =
                        self.status.native_compiled && enabled == self.status.enabled;
                }
            }
            (
                Flight::Event(id),
                Outcome::Notification {
                    claim_id, key, ack, ..
                },
            ) if claim_id == id.claim && key == id.key => self.ack(
                engine,
                id,
                match ack {
                    worker::Ack::Delivered(d) => NotificationAck::Delivered(d),
                    worker::Ack::Suppressed => NotificationAck::Suppressed,
                    worker::Ack::Cancelled => NotificationAck::Cancelled,
                },
            ),
            (Flight::Event(id), _) => {
                self.ack(engine, id, NotificationAck::Delivered(Delivery::Uncertain))
            }
            (_, Outcome::Rejected(error)) => self.status.error = Some(error),
            (
                _,
                Outcome::Cleared {
                    error: Some(error), ..
                },
            ) => self.status.error = Some(error),
            (_, Outcome::Permission(permission)) => self.status.permission = permission,
            _ => {}
        }
    }
    fn tick(&mut self, engine: &mut impl Outbox, activity: Option<DesktopActivity>) {
        while let Ok(receipt) = self.runtime.try_receipt() {
            self.receipt(engine, receipt);
        }
        if let Some(status) = self.handle.try_status() {
            self.status.permission = if self.status.native_compiled {
                status.permission
            } else {
                Permission::Unsupported
            };
            if let Some(error) = status.error {
                self.status.error = Some(error);
            }
            if status.stopped {
                self.closed = true;
            }
            if self.desired.is_none()
                && !self
                    .flights
                    .values()
                    .any(|f| matches!(f, Flight::Configure(_)))
                && !self
                    .pending
                    .iter()
                    .any(|c| matches!(c, Command::Configure(_)))
            {
                self.status.bridge_ready = self.status.native_compiled
                    && status.configured
                    && !status.stopped
                    && status.enabled == self.status.enabled;
            }
        }
        if let Some(activity) = activity {
            let seen = if activity.app_active && !activity.locked && !activity.display_asleep {
                activity.visible_thread
            } else {
                None
            };
            if seen != self.last_seen && self.pending.len() < CONTROLS {
                if let Some(thread) = seen {
                    self.cancel_pending(engine, Some(thread));
                    self.pending.push_back(Command::ClearThread(thread));
                }
                self.last_seen = seen;
            }
        }
        // Configure barriers have priority over all not-yet-submitted commands.
        if !self
            .flights
            .values()
            .any(|f| matches!(f, Flight::Configure(_)))
            && let Some(enabled) = self.desired.take()
        {
            self.pending.retain(|c| !matches!(c, Command::Configure(_)));
            self.pending.push_front(Command::Configure(Settings {
                enabled,
                include_preview: false,
            }));
        }
        while self.flights.len() < WINDOW {
            let Some(mut command) = self.pending.pop_front() else {
                break;
            };
            if let Command::Dispatch { desktop, .. } = &mut command
                && let Some(latest) = activity
            {
                *desktop = latest;
            }
            let flight = match &command {
                Command::Dispatch {
                    claim_id, alert, ..
                } => Flight::Event(Identity {
                    claim: *claim_id,
                    key: alert.key,
                }),
                Command::Configure(settings) => Flight::Configure(settings.enabled),
                _ => Flight::Control,
            };
            match self.handle.try_send(command) {
                Ok(id) => {
                    self.flights.insert(id, flight);
                }
                Err(SubmitError::Full(command)) => {
                    self.pending.push_front(command);
                    break;
                }
                Err(SubmitError::Closed(command)) => {
                    self.pending.push_front(command);
                    self.closed = true;
                    self.status.bridge_ready = false;
                    self.status.error = Some(
                        "Notification worker closed; retained claims require shutdown accounting"
                            .into(),
                    );
                    break;
                }
            }
        }
        let room = WINDOW.saturating_sub(self.flights.len() + self.pending.len());
        if !self.closed
            && self.status.bridge_ready
            && self.status.enabled
            && self.desired.is_none()
            && self.failed_acks.is_empty()
            && room > 0
            && let Some(desktop) = activity
        {
            match engine.claim(room) {
                Ok(claims) => {
                    for claim in claims {
                        self.pending.push_back(Command::Dispatch {
                            claim_id: claim.claim_id,
                            alert: claim.alert,
                            desktop,
                            now: SystemTime::now()
                                .duration_since(UNIX_EPOCH)
                                .unwrap_or_default()
                                .as_secs(),
                        });
                    }
                }
                Err(e) => self.status.error = Some(short(e)),
            }
        }
        self.status.busy = self.desired.is_some()
            || self
                .pending
                .iter()
                .any(|c| !matches!(c, Command::Dispatch { .. }))
            || self
                .flights
                .values()
                .any(|f| !matches!(f, Flight::Event(_)));
        self.status.outstanding = self.pending.len() + self.flights.len() + self.failed_acks.len();
    }
    fn finish(&mut self, engine: &mut impl Outbox) {
        self.cancel_pending(engine, None);
        match self.runtime.shutdown() {
            Ok(exit) => {
                while let Ok(receipt) = self.runtime.try_receipt() {
                    self.receipt(engine, receipt);
                }
                if let Some(receipt) = exit.pending_receipt {
                    self.receipt(engine, receipt);
                }
                for queued in exit.unprocessed {
                    if let Some(Flight::Event(id)) = self.flights.remove(&queued.command_id) {
                        self.ack(engine, id, NotificationAck::Cancelled);
                    }
                }
            }
            Err(e) => self.status.error = Some(short(e)),
        }
        let remaining = std::mem::take(&mut self.flights);
        for flight in remaining.into_values() {
            if let Flight::Event(id) = flight {
                self.ack(engine, id, NotificationAck::Delivered(Delivery::Uncertain));
            }
        }
        // Failed acknowledgement is never converted to a delivery retry. Leave
        // exact claims in the Engine for conservative parent reconciliation.
        let failed = std::mem::take(&mut self.failed_acks);
        for failed in failed {
            self.ack(engine, failed.id, failed.ack);
        }
        self.status.outstanding = self.failed_acks.len();
        self.status.stopped = true;
        self.status.bridge_ready = false;
        self.status.busy = false;
    }
}

pub struct NotificationSettingsPanel {
    bridge: Option<Bridge>,
    status: Status,
    notice: Option<String>,
    _poll: Task<()>,
}
impl NotificationSettingsPanel {
    pub fn new(engine: SharedEngine, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (bridge, notice) = match Bridge::start(engine) {
            Ok(b) => (Some(b), None),
            Err(e) => (None, Some(short(e))),
        };
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
                if this
                    .update_in(cx, |this, _, cx| {
                        if let Some(status) =
                            this.bridge.as_ref().and_then(|b| b.handle.try_status())
                            && status != this.status
                        {
                            this.status = status;
                            cx.notify();
                        }
                    })
                    .is_err()
                {
                    break;
                }
            }
        });
        let status = if bridge.is_some() {
            Status::default()
        } else {
            Status {
                busy: false,
                stopped: true,
                ..Status::default()
            }
        };
        Self {
            bridge,
            status,
            notice,
            _poll: poll,
        }
    }
    pub fn bridge_handle(&self) -> Option<BridgeHandle> {
        self.bridge.as_ref().map(Bridge::handle)
    }
    pub fn update_activity(&self, activity: DesktopActivity) -> bool {
        self.bridge
            .as_ref()
            .is_some_and(|b| b.handle.update_activity(activity))
    }
    fn action(&mut self, action: Action, cx: &mut Context<Self>) {
        self.notice = if self
            .bridge
            .as_ref()
            .is_some_and(|b| b.handle.try_action(action))
        {
            None
        } else {
            Some("Notification bridge busy or stopped; try again".into())
        };
        cx.notify();
    }
}
impl Render for NotificationSettingsPanel {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let enabled = self.status.enabled;
        div().flex().flex_col().gap_3().p_4()
            .child(div().text_lg().child("Desktop notifications"))
            .child("Notify about completed turns, failures, approvals and questions. Notification previews stay off.")
            .child(format!("Native compiled: {} · Bridge ready: {} · Core outbox deliveryConnected: {}", self.status.native_compiled, self.status.bridge_ready, self.status.core_delivery_connected))
            .child(format!("Permission: {:?} · Outstanding: {}", self.status.permission, self.status.outstanding))
            .child(div().flex().gap_2()
                .child(Button::new("notification-enabled").label(if enabled { "Disable notifications" } else { "Enable notifications" }).disabled(self.status.busy || self.status.stopped || (!enabled && !self.status.native_compiled)).on_click(cx.listener(move |this, _, _, cx| this.action(Action::Configure(!enabled), cx))))
                .child(Button::new("notification-permission").label("Allow notifications").disabled(self.status.busy || self.status.stopped || !self.status.native_compiled).on_click(cx.listener(|this, _, _, cx| this.action(Action::AllowNotifications, cx))))
                .child(Button::new("notification-refresh").label("Refresh status").disabled(self.status.busy || self.status.stopped || !self.status.native_compiled).on_click(cx.listener(|this, _, _, cx| this.action(Action::RefreshStatus, cx)))))
            .child(self.notice.clone().or_else(|| self.status.error.clone()).unwrap_or_default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notifications::{Backend, Payload};
    use coincide_core::platform_host::notifications::{Alert, AlertKind};
    #[derive(Default)]
    struct EngineState {
        enabled: bool,
        writes: Vec<bool>,
        claims: VecDeque<NotificationClaim>,
        acks: Vec<(Uuid, NotificationAck)>,
    }
    struct FakeEngine(Arc<Mutex<EngineState>>);
    impl Outbox for FakeEngine {
        fn enabled(&mut self) -> Result<bool> {
            Ok(self.0.lock().unwrap().enabled)
        }
        fn configure(&mut self, value: bool) -> Result<()> {
            let mut s = self.0.lock().unwrap();
            s.writes.push(value);
            s.enabled = value;
            Ok(())
        }
        fn claim(&mut self, limit: usize) -> Result<Vec<NotificationClaim>> {
            let mut s = self.0.lock().unwrap();
            let count = limit.min(s.claims.len());
            Ok(s.claims.drain(..count).collect())
        }
        fn ack(&mut self, id: Uuid, _: EventKey, ack: NotificationAck) -> Result<()> {
            self.0.lock().unwrap().acks.push((id, ack));
            Ok(())
        }
    }
    struct FakeBackend {
        calls: Arc<Mutex<Vec<&'static str>>>,
        result: Delivery,
    }
    impl Backend for FakeBackend {
        fn permission(&mut self) -> Result<Permission> {
            self.calls.lock().unwrap().push("status");
            Ok(Permission::Authorized)
        }
        fn request_permission(&mut self) -> Result<Permission> {
            self.calls.lock().unwrap().push("request");
            Ok(Permission::Authorized)
        }
        fn post(&mut self, payload: &Payload) -> Delivery {
            assert!(payload.body.is_none());
            self.calls.lock().unwrap().push("post");
            self.result
        }
        fn clear_thread(&mut self, _: Uuid) -> Result<()> {
            self.calls.lock().unwrap().push("clear");
            Ok(())
        }
    }
    fn activity() -> DesktopActivity {
        DesktopActivity {
            app_active: false,
            visible_thread: None,
            idle_seconds: 0,
            locked: false,
            display_asleep: false,
        }
    }
    fn claim() -> NotificationClaim {
        NotificationClaim {
            claim_id: Uuid::new_v4(),
            alert: Alert {
                key: EventKey {
                    thread: Uuid::new_v4(),
                    item: Uuid::new_v4(),
                    kind: AlertKind::Completed,
                },
                title: "generic".into(),
                body: None,
            },
        }
    }
    fn setup(
        result: Delivery,
        compiled: bool,
    ) -> (Pump, FakeEngine, Arc<Mutex<Vec<&'static str>>>) {
        let calls = Arc::new(Mutex::new(vec![]));
        let runtime = NotificationRuntime::spawn(
            FakeBackend {
                calls: calls.clone(),
                result,
            },
            WINDOW,
        )
        .unwrap();
        (
            Pump::new(runtime, compiled, false),
            FakeEngine(Arc::default()),
            calls,
        )
    }
    fn until(pump: &mut Pump, engine: &mut FakeEngine, predicate: impl Fn(&Pump) -> bool) {
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while !predicate(pump) {
            pump.tick(engine, Some(activity()));
            assert!(std::time::Instant::now() < deadline);
            thread::yield_now();
        }
    }
    #[test]
    fn startup_reads_only_and_explicit_click_writes_without_permission_prompt() {
        let (mut pump, mut engine, calls) = setup(Delivery::Accepted, true);
        until(&mut pump, &mut engine, |p| !p.status.busy);
        assert!(calls.lock().unwrap().is_empty());
        assert!(engine.0.lock().unwrap().writes.is_empty());
        pump.action(&mut engine, Action::Configure(true));
        until(&mut pump, &mut engine, |p| {
            p.status.bridge_ready && !p.status.busy
        });
        assert_eq!(engine.0.lock().unwrap().writes, vec![true]);
        assert!(calls.lock().unwrap().is_empty());
        pump.action(&mut engine, Action::AllowNotifications);
        until(&mut pump, &mut engine, |p| {
            p.pending.is_empty() && p.flights.is_empty()
        });
        assert_eq!(*calls.lock().unwrap(), vec!["request"]);
        pump.finish(&mut engine);
    }
    #[test]
    fn uncertain_receipt_is_acked_once_without_delivery_retry() {
        let (mut pump, mut engine, calls) = setup(Delivery::Uncertain, true);
        pump.action(&mut engine, Action::Configure(true));
        let event = claim();
        let id = event.claim_id;
        engine.0.lock().unwrap().claims.push_back(event);
        until(&mut pump, &mut engine, |p| {
            p.status.bridge_ready && !p.flights.is_empty()
        });
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while engine.0.lock().unwrap().acks.is_empty() {
            pump.tick(&mut engine, Some(activity()));
            assert!(std::time::Instant::now() < deadline);
            thread::yield_now();
        }
        assert!(
            matches!(engine.0.lock().unwrap().acks.as_slice(), [(got, NotificationAck::Delivered(Delivery::Uncertain))] if *got == id)
        );
        for _ in 0..20 {
            pump.tick(&mut engine, Some(activity()));
        }
        assert_eq!(*calls.lock().unwrap(), vec!["status", "post"]);
        pump.finish(&mut engine);
    }
    #[test]
    fn closed_worker_retains_unsent_claim_for_cancel_ack_on_shutdown() {
        let (mut pump, mut engine, _) = setup(Delivery::Accepted, true);
        until(&mut pump, &mut engine, |p| !p.status.busy);
        pump.handle.request_shutdown();
        let event = claim();
        let id = event.claim_id;
        pump.pending.push_back(Command::Dispatch {
            claim_id: id,
            alert: event.alert,
            desktop: activity(),
            now: 1,
        });
        pump.tick(&mut engine, Some(activity()));
        assert!(pump.closed);
        assert!(
            matches!(pump.pending.front(), Some(Command::Dispatch { claim_id, .. }) if *claim_id == id)
        );
        pump.finish(&mut engine);
        assert!(
            matches!(engine.0.lock().unwrap().acks.as_slice(), [(got, NotificationAck::Cancelled)] if *got == id)
        );
    }
    #[test]
    fn real_bridge_constructor_is_read_only_and_activity_slot_is_latest_only() {
        let state = Arc::new(Mutex::new(EngineState::default()));
        let calls = Arc::new(Mutex::new(vec![]));
        let backend_calls = calls.clone();
        let bridge = Bridge::start_with(
            FakeEngine(state.clone()),
            move || {
                NotificationRuntime::spawn(
                    FakeBackend {
                        calls: backend_calls,
                        result: Delivery::Accepted,
                    },
                    WINDOW,
                )
            },
            true,
        )
        .unwrap();
        let h = bridge.handle();
        let mut latest = activity();
        latest.idle_seconds = 999;
        assert!(h.update_activity(latest));
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while !h.try_status().is_some_and(|s| !s.busy) {
            assert!(std::time::Instant::now() < deadline);
            thread::yield_now();
        }
        assert_eq!(h.activity.lock().unwrap().unwrap().idle_seconds, 999);
        assert!(state.lock().unwrap().writes.is_empty());
        assert!(calls.lock().unwrap().is_empty());
        drop(bridge); // signals only; shutdown/join remains on bridge thread
        while !h.try_status().is_some_and(|s| s.stopped) {
            assert!(std::time::Instant::now() < deadline);
            thread::yield_now();
        }
    }
    #[test]
    fn inactive_build_never_claims_or_pretends_delivery() {
        let (mut pump, mut engine, calls) = setup(Delivery::Accepted, false);
        engine.0.lock().unwrap().claims.push_back(claim());
        pump.action(&mut engine, Action::Configure(true));
        for _ in 0..30 {
            pump.tick(&mut engine, Some(activity()));
        }
        assert!(!pump.status.bridge_ready);
        assert!(engine.0.lock().unwrap().writes.is_empty());
        assert_eq!(engine.0.lock().unwrap().claims.len(), 1);
        assert!(calls.lock().unwrap().is_empty());
        pump.finish(&mut engine);
    }
    #[test]
    fn disable_cancels_retained_unsent_claim_and_clear_runs_off_bridge() {
        let (mut pump, mut engine, calls) = setup(Delivery::Accepted, true);
        let event = claim();
        let thread = event.alert.key.thread;
        pump.pending.push_back(Command::Dispatch {
            claim_id: event.claim_id,
            alert: event.alert,
            desktop: activity(),
            now: 1,
        });
        pump.action(&mut engine, Action::Configure(false));
        assert!(matches!(
            engine.0.lock().unwrap().acks.as_slice(),
            [(_, NotificationAck::Cancelled)]
        ));
        until(&mut pump, &mut engine, |p| !p.status.busy);
        let mut seen = activity();
        seen.app_active = true;
        seen.visible_thread = Some(thread);
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while !calls.lock().unwrap().contains(&"clear") {
            pump.tick(&mut engine, Some(seen));
            assert!(std::time::Instant::now() < deadline);
            thread::yield_now();
        }
        assert!(!calls.lock().unwrap().contains(&"post"));
        pump.finish(&mut engine);
    }
}
