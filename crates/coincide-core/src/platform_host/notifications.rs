//! Single-destination alert routing and bounded, session-local deduplication.
//! All timestamps are seconds on the same trusted host clock. No payloads persist.
use crate::remote::{Presence, PushTarget};
use std::collections::BTreeMap;
use uuid::Uuid;

#[derive(Debug, Clone, Copy)]
pub struct DesktopActivity {
    pub app_active: bool,
    pub visible_thread: Option<Uuid>,
    pub idle_seconds: u64,
    pub locked: bool,
    pub display_asleep: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Route {
    Suppressed,
    Desktop,
    Device(String),
    Push(PushTarget),
}

pub struct Environment<'a> {
    pub enabled: bool,
    pub desktop: DesktopActivity,
    /// Only authenticated, paired sessions may supply these records.
    pub devices: &'a [Presence],
    pub push_targets: &'a [PushTarget],
    /// False until a native CloudKit adapter is ready; never infer from a saved setting.
    pub push_available: bool,
    /// Supplied from the negotiated companion protocol; not guessed here.
    pub presence_lifetime: u64,
    pub now: u64,
}
impl Environment<'_> {
    pub fn route(&self, thread: Uuid) -> Route {
        let desktop = if self.desktop.app_active && self.desktop.visible_thread == Some(thread) {
            Route::Suppressed
        } else {
            Route::Desktop
        };
        if !self.enabled {
            return Route::Suppressed;
        }
        if self.desktop.idle_seconds < 120 && !self.desktop.locked && !self.desktop.display_asleep {
            return desktop;
        }
        if let Some(phone) = self
            .devices
            .iter()
            .filter(|p| p.foreground(self.now, self.presence_lifetime))
            .max_by_key(|p| (p.last_interaction(), &p.device_id))
        {
            return if phone.open_thread == Some(thread) {
                Route::Suppressed
            } else {
                Route::Device(phone.device_id.clone())
            };
        }
        if self.push_available
            && let Some(target) = self
                .push_targets
                .iter()
                .filter(|p| {
                    !p.zone.trim().is_empty()
                        && self
                            .now
                            .checked_sub(p.last_active_at)
                            .is_some_and(|age| age <= 4 * 60 * 60)
                        && !self.devices.iter().any(|d| {
                            d.device_id == p.device_id
                                && d.foreground(self.now, self.presence_lifetime)
                        })
                })
                .max_by_key(|p| (p.last_active_at, &p.device_id))
        {
            return Route::Push(target.clone());
        }
        desktop
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum AlertKind {
    Completed,
    Failed,
    Approval,
    Question,
    SlowStart,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct EventKey {
    pub thread: Uuid,
    /// Stable persisted transcript item/request UUID, not a new ID on replay.
    pub item: Uuid,
    pub kind: AlertKind,
}
pub struct Alert {
    pub key: EventKey,
    pub title: String,
    pub body: Option<String>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Delivery {
    Accepted,
    /// Adapter proves nothing was sent. Desktop fallback is safe.
    Unavailable,
    /// A timeout may have delivered; do not create a duplicate via fallback.
    Uncertain,
}
pub trait AlertDelivery {
    fn deliver(&mut self, route: &Route, alert: &Alert) -> Delivery;
    /// Remove visible notifications and cancel pending push writes for the thread.
    fn clear_thread(&mut self, thread: Uuid);
}
#[derive(Debug, PartialEq, Eq)]
pub enum Dispatch {
    Disabled,
    Duplicate,
    Suppressed,
    /// Explicit backpressure instead of evicting live claims and risking duplicates.
    LedgerFull,
    Attempted {
        route: Route,
        result: Delivery,
    },
}
/// Claims last 24h in this instance only. Restarts require a durable ledger before
/// replaying old events. Serialize calls through the Engine owner. An uncertain
/// send stays claimed; a definite failed send can be retried with the same key.
pub struct Dispatcher {
    claims: BTreeMap<EventKey, u64>,
    capacity: usize,
}
impl Dispatcher {
    pub fn new(capacity: usize) -> Self {
        Self {
            claims: BTreeMap::new(),
            capacity,
        }
    }
    pub fn dispatch(
        &mut self,
        alert: &Alert,
        env: &Environment<'_>,
        sink: &mut impl AlertDelivery,
    ) -> Dispatch {
        if !env.enabled {
            return Dispatch::Disabled;
        }
        // Retain claims on clock rollback rather than redelivering them.
        self.claims
            .retain(|_, t| env.now.saturating_sub(*t) <= 86400);
        if self.claims.contains_key(&alert.key) {
            return Dispatch::Duplicate;
        }
        if self.claims.len() >= self.capacity {
            return Dispatch::LedgerFull;
        }
        let mut route = if alert.key.kind == AlertKind::SlowStart {
            if env.desktop.app_active && env.desktop.visible_thread == Some(alert.key.thread) {
                Route::Suppressed
            } else {
                Route::Desktop
            }
        } else {
            env.route(alert.key.thread)
        };
        self.claims.insert(alert.key, env.now);
        if route == Route::Suppressed {
            return Dispatch::Suppressed;
        }
        let mut result = sink.deliver(&route, alert);
        if result == Delivery::Unavailable && matches!(route, Route::Device(_) | Route::Push(_)) {
            route = Route::Desktop;
            result = sink.deliver(&route, alert);
        }
        if result == Delivery::Unavailable {
            self.claims.remove(&alert.key);
        }
        Dispatch::Attempted { route, result }
    }
    /// Retain deduplication claims: seeing a thread must not replay old alerts.
    pub fn thread_seen(&mut self, thread: Uuid, sink: &mut impl AlertDelivery) {
        sink.clear_thread(thread);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn environment<'a>() -> Environment<'a> {
        Environment {
            enabled: true,
            desktop: DesktopActivity {
                app_active: false,
                visible_thread: None,
                idle_seconds: 0,
                locked: false,
                display_asleep: false,
            },
            devices: &[],
            push_targets: &[],
            push_available: false,
            presence_lifetime: 30,
            now: 1000,
        }
    }
    fn alert() -> Alert {
        Alert {
            key: EventKey {
                thread: Uuid::new_v4(),
                item: Uuid::new_v4(),
                kind: AlertKind::Completed,
            },
            title: "Fixture".into(),
            body: None,
        }
    }
    struct Sink {
        calls: Vec<Route>,
        result: Delivery,
    }
    impl AlertDelivery for Sink {
        fn deliver(&mut self, route: &Route, _: &Alert) -> Delivery {
            self.calls.push(route.clone());
            self.result
        }
        fn clear_thread(&mut self, _: Uuid) {}
    }
    #[test]
    fn desktop_precedence_phone_suppression_and_stale_push() {
        let thread = Uuid::new_v4();
        let mut env = environment();
        let phones = [Presence {
            device_id: "phone".into(),
            active: true,
            open_thread: Some(thread),
            received_at: 1000,
            idle_seconds: 0,
        }];
        let targets = [PushTarget {
            device_id: "phone".into(),
            zone: "fixture".into(),
            last_active_at: 1000,
        }];
        env.devices = &phones;
        env.push_targets = &targets;
        env.push_available = true;
        assert_eq!(env.route(thread), Route::Desktop);
        env.desktop.locked = true;
        assert_eq!(env.route(thread), Route::Suppressed);
        env.now = 1031;
        assert_eq!(env.route(thread), Route::Push(targets[0].clone()));
        env.now = 15401;
        assert_eq!(env.route(thread), Route::Desktop);
        env.now = 999;
        assert_eq!(env.route(thread), Route::Desktop);
    }
    #[test]
    fn dedupe_capacity_expiration_and_disabled() {
        let a = alert();
        let mut env = environment();
        let mut d = Dispatcher::new(1);
        let mut sink = Sink {
            calls: vec![],
            result: Delivery::Accepted,
        };
        env.enabled = false;
        assert_eq!(d.dispatch(&a, &env, &mut sink), Dispatch::Disabled);
        env.enabled = true;
        d.dispatch(&a, &env, &mut sink);
        d.thread_seen(a.key.thread, &mut sink);
        assert_eq!(d.dispatch(&a, &env, &mut sink), Dispatch::Duplicate);
        assert_eq!(d.dispatch(&alert(), &env, &mut sink), Dispatch::LedgerFull);
        env.now += 86401;
        d.dispatch(&a, &env, &mut sink);
        assert_eq!(sink.calls.len(), 2);
    }
    #[test]
    fn uncertain_push_does_not_fallback_but_unavailable_does() {
        let a = alert();
        let mut env = environment();
        env.desktop.locked = true;
        let targets = [PushTarget {
            device_id: "phone".into(),
            zone: "fixture".into(),
            last_active_at: 1000,
        }];
        env.push_targets = &targets;
        env.push_available = true;
        let mut sink = Sink {
            calls: vec![],
            result: Delivery::Uncertain,
        };
        let mut d = Dispatcher::new(10);
        d.dispatch(&a, &env, &mut sink);
        assert_eq!(sink.calls.len(), 1);
        assert_eq!(d.dispatch(&a, &env, &mut sink), Dispatch::Duplicate);
        sink.result = Delivery::Unavailable;
        let next = alert();
        d.dispatch(&next, &env, &mut sink);
        assert_eq!(sink.calls.last(), Some(&Route::Desktop));
        assert!(matches!(
            d.dispatch(&next, &env, &mut sink),
            Dispatch::Attempted { .. }
        ));
    }
    #[test]
    fn slow_start_stays_local_and_visible_thread_stays_quiet() {
        let mut a = alert();
        a.key.kind = AlertKind::SlowStart;
        let mut env = environment();
        env.desktop.locked = true;
        let phones = [Presence {
            device_id: "phone".into(),
            active: true,
            open_thread: None,
            received_at: 1000,
            idle_seconds: 0,
        }];
        env.devices = &phones;
        let mut sink = Sink {
            calls: vec![],
            result: Delivery::Accepted,
        };
        Dispatcher::new(10).dispatch(&a, &env, &mut sink);
        assert_eq!(sink.calls, vec![Route::Desktop]);
        env.desktop.app_active = true;
        env.desktop.visible_thread = Some(a.key.thread);
        assert_eq!(
            Dispatcher::new(10).dispatch(&a, &env, &mut sink),
            Dispatch::Suppressed
        );
    }
}
