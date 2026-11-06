//! Product CLI/API -> serialized Computer Use runtime mount. The parent calls
//! poll ONLY after dropping its Engine guard. No native action is performed here.
use crate::{
    computer_use::{Handle, Reply, Runtime},
    computer_use_settings::ComputerUseSettingsPanel,
};
use anyhow::{Context as _, Result};
use coincide_core::{
    api::{Engine, SharedEngine, computer_use_engine::Pending},
    computer_use::{Authority, Failure},
};
use gpui_kit::{App, AppContext, Entity, Window};
use serde_json::Value;
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{Arc, Mutex, TryLockError, Weak},
    time::Instant,
};
use uuid::Uuid;
const LIMIT: usize = 8;
#[derive(Clone, Copy)]
struct Identity {
    engine: Uuid,
    thread: Uuid,
    grant: Uuid,
    deadline: Instant,
}
struct Completion {
    identity: Identity,
    result: std::result::Result<Value, Failure>,
}
struct Plan {
    requests: Vec<Pending>,
    revoke: Option<Uuid>,
}
trait Gateway {
    fn bind(&mut self, authority: Authority);
    fn unbind(&mut self);
    fn selection(&self) -> Option<Uuid>;
    fn drain(&mut self) -> Vec<Pending>;
    fn reply(
        &mut self,
        id: Uuid,
        thread: Uuid,
        result: std::result::Result<Value, Failure>,
    ) -> bool;
    fn revoke(&mut self, thread: Uuid);
    fn revoke_all(&mut self);
    fn shutdown(&mut self);
}
impl Gateway for Engine {
    fn bind(&mut self, a: Authority) {
        self.computer_use_bind_authority(a);
    }
    fn unbind(&mut self) {
        self.computer_use_unbind_authority();
    }
    fn selection(&self) -> Option<Uuid> {
        self.active_thread().and_then(|s| Uuid::parse_str(s).ok())
    }
    fn drain(&mut self) -> Vec<Pending> {
        self.computer_use_drain()
    }
    fn reply(&mut self, id: Uuid, t: Uuid, r: std::result::Result<Value, Failure>) -> bool {
        self.computer_use_reply(id, t, r)
    }
    fn revoke(&mut self, t: Uuid) {
        self.computer_use_revoke(t);
    }
    fn revoke_all(&mut self) {
        self.computer_use_revoke_all();
    }
    fn shutdown(&mut self) {
        self.computer_use_shutdown();
    }
}
struct Handoff {
    runtime: Runtime,
    handle: Handle,
    flights: BTreeMap<Uuid, Identity>,
    completions: VecDeque<Completion>,
    selected: Option<Uuid>,
    bound: bool,
    closing: bool,
    accounted: bool,
    error: Option<Failure>,
}
impl Handoff {
    fn new(runtime: Runtime) -> Self {
        Self {
            handle: runtime.handle(),
            runtime,
            flights: BTreeMap::new(),
            completions: VecDeque::new(),
            selected: None,
            bound: false,
            closing: false,
            accounted: false,
            error: None,
        }
    }
    fn harvest(&mut self) {
        while self.completions.len() < LIMIT {
            let Ok(reply) = self.runtime.try_reply() else {
                break;
            };
            self.accept(reply);
        }
        let expired = self
            .flights
            .iter()
            .filter(|(_, id)| Instant::now() >= id.deadline)
            .map(|(id, _)| *id)
            .take(LIMIT - self.completions.len())
            .collect::<Vec<_>>();
        for native in expired {
            if let Some(identity) = self.flights.remove(&native) {
                self.completions.push_back(Completion {
                    identity,
                    result: Err(Failure::TimedOut),
                });
            }
        }
    }
    fn accept(&mut self, reply: Reply) {
        self.accept_frame(reply.id, reply.thread, reply.result);
    }
    fn accept_frame(
        &mut self,
        native: Uuid,
        thread: Uuid,
        result: std::result::Result<Value, Failure>,
    ) {
        let Some(identity) = self.flights.remove(&native) else {
            return;
        }; // expired/revoked late reply: drop data
        let result = if thread != identity.thread {
            self.error = Some(Failure::Native);
            Err(Failure::Revoked)
        } else {
            result
        };
        self.completions.push_back(Completion { identity, result });
    }
    fn flush(&mut self, gateway: &mut impl Gateway) {
        while let Some(mut completion) = self.completions.pop_front() {
            let id = completion.identity;
            if Some(id.thread) != gateway.selection()
                || self.handle.authority_for_engine().grant(id.thread) != Ok(id.grant)
            {
                completion.result = Err(Failure::Revoked);
            } else if Instant::now() >= id.deadline {
                completion.result = Err(Failure::TimedOut);
            }
            // False means expired/revoked/consumed in Engine: never resubmit input.
            gateway.reply(id.engine, id.thread, completion.result);
        }
    }
    /// Engine-only phase. Absolutely no Handle submission/panel/native calls.
    fn prepare(&mut self, gateway: &mut impl Gateway) -> Plan {
        if self.closing {
            gateway.shutdown();
            gateway.unbind();
            self.bound = false;
            self.accounted = true;
            self.completions.clear();
            self.flights.clear();
            self.selected = None;
            return Plan {
                requests: vec![],
                revoke: None,
            };
        }
        if !self.bound {
            gateway.bind(self.handle.authority_for_engine());
            self.bound = true;
        }
        let selected = gateway.selection();
        let previous = self.selected;
        if selected != previous {
            if let Some(old) = previous {
                gateway.revoke(old);
            }
            self.selected = selected;
        }
        let status = self.handle.try_status();
        let master = self.handle.authority_for_engine().enabled();
        let stopped = status.as_ref().is_some_and(|s| s.stopped);
        let enabled = master && status.as_ref().is_some_and(|s| !s.stopped);
        // A contended latest-status slot pauses admission; it is not a disable.
        if !master || stopped {
            gateway.revoke_all();
        }
        self.flush(gateway);
        let room = LIMIT.saturating_sub(self.flights.len() + self.completions.len());
        // Gateway already bounds the batch to8. Keep map bounded even when older
        // runtime work outlives Engine expiry; surplus jobs receive Busy, no retry.
        let requests = if enabled && room > 0 {
            gateway.drain()
        } else {
            vec![]
        };
        Plan {
            requests,
            revoke: if selected != previous { previous } else { None },
        }
    }
    /// Outside Engine guard: authority revocation + native mailbox admission only.
    fn submit(&mut self, plan: Plan) {
        if let Some(old) = plan.revoke {
            self.handle.native_revoke(old);
        }
        for pending in plan.requests {
            let identity = Identity {
                engine: pending.id,
                thread: pending.thread,
                grant: pending.grant,
                deadline: pending.deadline,
            };
            let result = if self.closing || Some(pending.thread) != self.selected {
                Err(Failure::Revoked)
            } else if self.flights.len() >= LIMIT {
                Err(Failure::Busy)
            } else {
                self.handle.try_request_bound(
                    pending.thread,
                    pending.request,
                    pending.deadline,
                    pending.grant,
                )
            };
            match result {
                Ok(native) => {
                    self.flights.insert(native, identity);
                }
                Err(error) => {
                    self.completions.push_back(Completion {
                        identity,
                        result: Err(error),
                    });
                }
            }
        }
        debug_assert!(self.flights.len() <= LIMIT && self.completions.len() <= LIMIT);
    }
    fn stop(&mut self) {
        self.runtime.request_shutdown();
        self.closing = true;
    }
}
/// Parent field: `computer_use: Mount` (or Option<Mount> after construction error).
/// One Mount per SharedEngine. Runtime and persistent Settings entity are owned here.
pub struct Mount {
    handoff: Handoff,
    panel: Entity<ComputerUseSettingsPanel>,
    engine: Option<Weak<Mutex<Engine>>>,
}
pub struct MountShutdownStatus {
    pub engine_accounted: bool,
    pub retained_flights: usize,
    pub retained_completions: usize,
    pub runtime: crate::computer_use::ShutdownStatus,
}
impl MountShutdownStatus {
    pub fn ready(&self) -> bool {
        self.engine_accounted
            && self.retained_flights == 0
            && self.retained_completions == 0
            && self.runtime.requested
            && self.runtime.worker == coincide_core::agent::WorkerThreadStatus::Returned
            && self.runtime.observer_error.is_none()
            && self.runtime.pending_reservations == Some(0)
            && self
                .runtime
                .backend
                .as_ref()
                .is_some_and(|s| s.stopped && !s.busy && s.error.is_none())
    }
}
impl Mount {
    /// Inert: creates worker/panel only, no Engine lock or native queries/prompts.
    pub fn new(window: &mut Window, cx: &mut App) -> Result<Self> {
        let runtime = Runtime::spawn_native().context("start Computer Use runtime")?;
        let handle = runtime.handle();
        let panel = cx.new(|cx| ComputerUseSettingsPanel::new(handle, window, cx));
        Ok(Self {
            handoff: Handoff::new(runtime),
            panel,
            engine: None,
        })
    }
    pub fn panel(&self) -> Entity<ComputerUseSettingsPanel> {
        self.panel.clone()
    }
    pub fn last_error(&self) -> Option<Failure> {
        self.handoff.error
    }
    pub fn shutdown_accounted(&self) -> bool {
        self.handoff.accounted
    }
    /// Engine request revocation and actual native worker cleanup are distinct.
    pub fn shutdown_status(&mut self) -> MountShutdownStatus {
        MountShutdownStatus {
            engine_accounted: self.handoff.accounted,
            retained_flights: self.handoff.flights.len(),
            retained_completions: self.handoff.completions.len(),
            runtime: self.handoff.runtime.shutdown_status(),
        }
    }
    /// Must be called outside parent's existing Engine lock. All lock acquisition
    /// is try_lock; no queue wait, native operation, or worker join blocks GPUI.
    pub fn poll(&mut self, engine: &SharedEngine, cx: &mut App) {
        if let Some(previous) = self.engine.as_ref().and_then(Weak::upgrade) {
            if !Arc::ptr_eq(&previous, engine) {
                self.handoff.error = Some(Failure::Revoked);
                self.handoff.stop();
            }
        } else {
            self.engine = Some(Arc::downgrade(engine));
        }
        self.handoff.harvest();
        let plan = match engine.try_lock() {
            Ok(mut gateway) => self.handoff.prepare(&mut *gateway),
            Err(TryLockError::WouldBlock) => return,
            Err(TryLockError::Poisoned(_)) => {
                self.handoff.error = Some(Failure::Native);
                self.handoff.stop();
                return;
            }
        }; // guard dropped BEFORE submission or any panel update
        self.handoff.submit(plan);
        if let Ok(mut gateway) = engine.try_lock() {
            self.handoff.flush(&mut *gateway);
        }
        let selected = self.handoff.selected;
        self.panel
            .update(cx, |panel, cx| panel.set_thread(selected, cx));
    }
    /// Native lifecycle only. Signal immediately; try to invalidate Engine state
    /// without waiting. If contended, keep polling until shutdown_accounted().
    pub fn shutdown(&mut self, engine: &SharedEngine) {
        self.handoff.stop();
        if let Ok(mut gateway) = engine.try_lock() {
            self.handoff.prepare(&mut *gateway);
        }
    }
}
impl Drop for Mount {
    fn drop(&mut self) {
        self.handoff.stop();
        if let Some(engine) = self.engine.as_ref().and_then(Weak::upgrade)
            && let Ok(mut gateway) = engine.try_lock()
        {
            gateway.computer_use_shutdown();
            gateway.computer_use_unbind_authority();
        }
        // If lock is busy, shared Authority is already revoked. Collection-time
        // stamp checks still deny retained results; no UI-thread join is performed.
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use coincide_core::computer_use::{
        Backend, Empty, NativeCall, NativeResult, Permission, PermissionKind, Permissions, Permit,
        Request, Tool,
    };
    use std::{
        sync::atomic::{AtomicUsize, Ordering},
        thread,
        time::Duration,
    };
    struct FakeBackend(Arc<AtomicUsize>);
    impl Backend for FakeBackend {
        fn permissions(&mut self) -> Result<Permissions, Failure> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Ok(Permissions {
                accessibility: Permission::Granted,
                screen_capture: Permission::Granted,
            })
        }
        fn request_permission(&mut self, _: PermissionKind) -> Result<Permissions, Failure> {
            self.permissions()
        }
        fn call(&mut self, _: NativeCall, p: &Permit) -> Result<NativeResult, Failure> {
            p.check()?;
            self.0.fetch_add(1, Ordering::SeqCst);
            Ok(NativeResult::Data(serde_json::json!({"fixture":true})))
        }
        fn invalidate(&mut self) {}
    }
    #[derive(Default)]
    struct FakeGateway {
        authority: Option<Authority>,
        selected: Option<Uuid>,
        queue: Vec<Pending>,
        results: BTreeMap<Uuid, (Uuid, std::result::Result<Value, Failure>)>,
        revoked: Vec<Uuid>,
        shutdown: bool,
    }
    impl Gateway for FakeGateway {
        fn bind(&mut self, a: Authority) {
            self.revoke_all();
            self.authority = Some(a);
        }
        fn unbind(&mut self) {
            self.authority = None;
        }
        fn selection(&self) -> Option<Uuid> {
            self.selected
        }
        fn drain(&mut self) -> Vec<Pending> {
            std::mem::take(&mut self.queue)
        }
        fn reply(&mut self, id: Uuid, t: Uuid, r: std::result::Result<Value, Failure>) -> bool {
            self.results.insert(id, (t, r));
            true
        }
        fn revoke(&mut self, t: Uuid) {
            self.revoked.push(t);
            self.queue.retain(|p| p.thread != t);
            for (_, result) in self.results.values_mut().filter(|(thread, _)| *thread == t) {
                *result = Err(Failure::Revoked);
            }
        }
        fn revoke_all(&mut self) {
            self.queue.clear();
            for (_, result) in self.results.values_mut() {
                *result = Err(Failure::Revoked);
            }
        }
        fn shutdown(&mut self) {
            self.shutdown = true;
            self.revoke_all();
        }
    }
    fn setup() -> (Handoff, FakeGateway, Arc<AtomicUsize>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let runtime = Runtime::spawn(FakeBackend(calls.clone()), true).unwrap();
        let mut handoff = Handoff::new(runtime);
        let mut gateway = FakeGateway::default();
        step(&mut handoff, &mut gateway);
        (handoff, gateway, calls)
    }
    fn step(h: &mut Handoff, g: &mut FakeGateway) {
        h.harvest();
        let plan = h.prepare(g);
        h.submit(plan);
        h.flush(g);
    }
    fn until(h: &mut Handoff, g: &mut FakeGateway, p: impl Fn(&FakeGateway) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while !p(g) {
            step(h, g);
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
    }
    fn queue(h: &Handoff, g: &mut FakeGateway, t: Uuid, deadline: Instant) -> Uuid {
        let id = Uuid::new_v4();
        g.queue.push(Pending {
            id,
            thread: t,
            grant: h.handle.authority_for_engine().grant(t).unwrap(),
            request: Request::Call(Tool::ListApps(Empty {})),
            deadline,
        });
        id
    }
    #[test]
    fn default_off_headless_mount_has_no_native_effects_and_binds_same_authority() {
        let (mut h, mut g, calls) = setup();
        step(&mut h, &mut g);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert!(!g.authority.as_ref().unwrap().enabled());
        h.handle.native_enable(true).unwrap();
        let t = Uuid::new_v4();
        h.handle.native_grant(t).unwrap();
        assert_eq!(
            g.authority.as_ref().unwrap().grant(t),
            h.handle.authority_for_engine().grant(t)
        );
        h.stop();
        step(&mut h, &mut g);
        assert!(h.accounted && g.shutdown && g.authority.is_none());
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }
    #[test]
    fn native_and_engine_ids_thread_deadline_roundtrip_without_replay() {
        let (mut h, mut g, calls) = setup();
        let t = Uuid::new_v4();
        g.selected = Some(t);
        h.handle.native_enable(true).unwrap();
        h.handle.native_grant(t).unwrap();
        let id = queue(&h, &mut g, t, Instant::now() + Duration::from_secs(1));
        until(&mut h, &mut g, |g| g.results.contains_key(&id));
        assert!(g.results[&id].1.is_ok());
        assert_eq!(g.results[&id].0, t);
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        for _ in 0..20 {
            step(&mut h, &mut g);
        }
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        h.stop();
        step(&mut h, &mut g);
    }
    #[test]
    fn navigation_revokes_old_thread_and_retained_results() {
        let (mut h, mut g, _) = setup();
        let old = Uuid::new_v4();
        g.selected = Some(old);
        h.handle.native_enable(true).unwrap();
        h.handle.native_grant(old).unwrap();
        let id = queue(&h, &mut g, old, Instant::now() + Duration::from_secs(1));
        until(&mut h, &mut g, |g| g.results.contains_key(&id));
        g.selected = Some(Uuid::new_v4());
        step(&mut h, &mut g);
        assert!(!h.handle.thread_enabled(old));
        assert_eq!(g.results[&id].1, Err(Failure::Revoked));
        assert!(g.revoked.contains(&old));
        h.stop();
        step(&mut h, &mut g);
    }
    #[test]
    fn regrant_between_drain_and_submission_denies_old_operation() {
        let (mut h, mut g, calls) = setup();
        let t = Uuid::new_v4();
        g.selected = Some(t);
        h.handle.native_enable(true).unwrap();
        h.handle.native_grant(t).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        let id = queue(&h, &mut g, t, deadline);
        let old_grant = h.handle.authority_for_engine().grant(t).unwrap();
        // prepare deliberately pauses admission when the runtime's latest-status
        // mutex is contended. Establish the actual drain boundary before changing
        // authority; empty plans neither submit nor execute the queued operation.
        let plan = loop {
            assert!(
                Instant::now() < deadline,
                "queued operation was not drained before its original deadline"
            );
            assert_eq!(h.handle.authority_for_engine().grant(t), Ok(old_grant));
            let plan = h.prepare(&mut g);
            if !plan.requests.is_empty() {
                break plan;
            }
            assert!(plan.revoke.is_none());
            assert_eq!(g.queue.len(), 1);
            assert_eq!(g.queue[0].id, id);
            assert_eq!(g.queue[0].grant, old_grant);
            assert!(g.results.is_empty());
            assert_eq!(calls.load(Ordering::SeqCst), 0);
            thread::yield_now();
        };
        assert_eq!(plan.requests.len(), 1);
        assert_eq!(plan.requests[0].id, id);
        assert_eq!(plan.requests[0].thread, t);
        assert_eq!(plan.requests[0].grant, old_grant);
        assert_eq!(plan.requests[0].deadline, deadline);
        assert!(g.queue.is_empty() && g.results.is_empty());
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        h.handle.native_grant(t).unwrap();
        assert_ne!(h.handle.authority_for_engine().grant(t), Ok(old_grant));
        h.submit(plan);
        h.flush(&mut g);
        assert_eq!(g.results[&id].1, Err(Failure::Revoked));
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        h.stop();
        step(&mut h, &mut g);
    }
    #[test]
    fn mismatched_native_thread_and_navigation_never_restore_payload() {
        let (mut h, mut g, calls) = setup();
        let t = Uuid::new_v4();
        g.selected = Some(t);
        h.handle.native_enable(true).unwrap();
        h.handle.native_grant(t).unwrap();
        step(&mut h, &mut g);
        let id = Identity {
            engine: Uuid::new_v4(),
            thread: t,
            grant: h.handle.authority_for_engine().grant(t).unwrap(),
            deadline: Instant::now() + Duration::from_secs(1),
        };
        let native = Uuid::new_v4();
        h.flights.insert(native, id);
        h.accept_frame(
            native,
            Uuid::new_v4(),
            Ok(serde_json::json!({"private":"fixture"})),
        );
        h.flush(&mut g);
        assert_eq!(g.results[&id.engine].0, t);
        assert_eq!(g.results[&id.engine].1, Err(Failure::Revoked));
        h.completions.push_back(Completion {
            identity: id,
            result: Ok(serde_json::json!({"private":"late fixture"})),
        });
        g.selected = Some(Uuid::new_v4());
        step(&mut h, &mut g);
        assert_eq!(g.results[&id.engine].1, Err(Failure::Revoked));
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        h.stop();
        step(&mut h, &mut g);
    }
    #[test]
    fn expired_api_deadline_and_master_disable_never_dispatch() {
        let (mut h, mut g, calls) = setup();
        let t = Uuid::new_v4();
        g.selected = Some(t);
        h.handle.native_enable(true).unwrap();
        h.handle.native_grant(t).unwrap();
        let id = queue(&h, &mut g, t, Instant::now() - Duration::from_secs(1));
        // The runtime's latest-status mutex may be held by its real worker.
        // A contended snapshot intentionally pauses admission for this frame;
        // wait for the reply instead of assuming one UI poll must drain it.
        until(&mut h, &mut g, |g| g.results.contains_key(&id));
        assert_eq!(g.results[&id].1, Err(Failure::TimedOut));
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        h.handle.native_enable(false).unwrap();
        step(&mut h, &mut g);
        assert_eq!(g.results[&id].1, Err(Failure::Revoked));
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        h.stop();
        step(&mut h, &mut g);
    }
}
