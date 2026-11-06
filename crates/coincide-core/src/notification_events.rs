//! Session-only native alert outbox. Live Engine events become deliverable only
//! after their exact transcript UUID is persisted. Startup/import never scans
//! old transcripts. No OS permission prompts, delivery, or remote transport here.
use super::*;
use crate::platform_host::notifications::{Alert, AlertKind, Delivery, EventKey};
use std::collections::{BTreeMap, BTreeSet};

const DOCUMENT: &str = "rust-native-notifications.json";
const QUEUE_LIMIT: usize = 256;
const CLAIM_LIMIT: usize = 4096;
const MAX_ATTEMPTS: u8 = 3;

pub struct NotificationClaim {
    pub claim_id: Uuid,
    pub alert: Alert,
}
#[derive(Debug, Clone, Copy)]
pub enum NotificationAck {
    Delivered(Delivery),
    Suppressed,
    Cancelled,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    AwaitingPersistence,
    Ready,
    InFlight(Uuid),
    Unavailable,
}
struct Entry {
    thread_id: String,
    state: State,
    request: Option<String>,
    attempts: u8,
}
pub(super) struct Outbox {
    enabled: bool,
    entries: BTreeMap<EventKey, Entry>,
    seen: BTreeSet<EventKey>,
    overflow: u64,
    uncertain: u64,
    error: Option<String>,
}
impl Outbox {
    pub fn new(store: &Store) -> Self {
        let setting = (|| -> Result<bool> {
            let Some(document) = store.local_document(DOCUMENT)? else {
                return Ok(false);
            };
            ensure!(
                document["version"] == 1,
                "Unsupported native notification configuration"
            );
            document["enabled"]
                .as_bool()
                .context("Invalid native notification opt-in")
        })();
        let (enabled, error) = match setting {
            Ok(enabled) => (enabled, None),
            Err(error) => (false, Some(error.to_string())),
        };
        Self {
            enabled,
            entries: BTreeMap::new(),
            seen: BTreeSet::new(),
            overflow: 0,
            uncertain: 0,
            error,
        }
    }
    pub fn status(&self) -> Value {
        json!({"enabled":self.enabled,"configurationSource":"rust_owned","scope":"session_native_events",
            "queued":self.entries.values().filter(|e| e.state == State::Ready).count(),
            "awaitingPersistence":self.entries.values().filter(|e| e.state == State::AwaitingPersistence).count(),
            "inFlight":self.entries.values().filter(|e| matches!(e.state, State::InFlight(_))).count(),
            "unavailable":self.entries.values().filter(|e| e.state == State::Unavailable).count(),
            "uncertain":self.uncertain,"overflow":self.overflow,"error":self.error,
            "queueLimit":QUEUE_LIMIT,"sessionClaimLimit":CLAIM_LIMIT,"maxAttempts":MAX_ATTEMPTS,
            "previews":false,"restartReplay":false,"remoteDelivery":false,"deliveryConnected":false})
    }
    pub fn stage(
        &mut self,
        thread: &Value,
        item: &Value,
        kind: AlertKind,
        request: Option<String>,
    ) {
        if !self.enabled || thread["isArchived"] == true {
            return;
        }
        let thread_id = text(thread, "id");
        let (Ok(thread), Ok(item)) = (
            Uuid::parse_str(text(thread, "id").as_str()),
            Uuid::parse_str(text(item, "id").as_str()),
        ) else {
            return;
        };
        let key = EventKey { thread, item, kind };
        if self.seen.contains(&key) {
            return;
        }
        if self.entries.len() >= QUEUE_LIMIT || self.seen.len() >= CLAIM_LIMIT {
            self.overflow = self.overflow.saturating_add(1);
            self.error = Some("Native alert outbox is full; new alerts were not queued".into());
            return;
        }
        self.seen.insert(key);
        self.entries.insert(
            key,
            Entry {
                thread_id,
                state: State::AwaitingPersistence,
                request,
                attempts: 0,
            },
        );
    }
    pub fn persisted(&mut self, thread: &Value) {
        let Ok(id) = Uuid::parse_str(text(thread, "id").as_str()) else {
            return;
        };
        self.entries.retain(|key, entry| {
            if key.thread != id || entry.state != State::AwaitingPersistence {
                return true;
            }
            if thread["isArchived"] == true {
                return false;
            }
            let present = thread["items"].as_array().is_some_and(|items| {
                items.iter().any(|item| {
                    Uuid::parse_str(text(item, "id").as_str()).ok() == Some(key.item)
                        && match key.kind {
                            AlertKind::Approval => item["kind"] == "approval",
                            AlertKind::Question => item["kind"] == "question",
                            AlertKind::Completed => item["kind"] == "notice",
                            AlertKind::Failed => item["kind"] == "error",
                            AlertKind::SlowStart => false,
                        }
                })
            });
            if present {
                entry.state = State::Ready;
            }
            present
        });
    }
    pub fn cancel_request(&mut self, thread: &str, request: &str) {
        let Ok(thread) = Uuid::parse_str(thread) else {
            return;
        };
        self.entries.retain(|key, entry| {
            key.thread != thread
                || entry.request.as_deref() != Some(request)
                || matches!(entry.state, State::InFlight(_))
        });
    }
    pub fn cancel_requests(&mut self, thread: &str) {
        let Ok(thread) = Uuid::parse_str(thread) else {
            return;
        };
        self.entries.retain(|key, entry| {
            key.thread != thread
                || entry.request.is_none()
                || matches!(entry.state, State::InFlight(_))
        });
    }
}

impl Engine {
    /// Trusted native-user action only, deliberately absent from agent JSON APIs.
    /// This opt-in does not request OS authorization or send any notifications.
    pub fn configure_native_notifications(&mut self, enabled: bool) -> Result<Value> {
        let mut document = self.store.local_document(DOCUMENT)?.unwrap_or(json!({}));
        ensure!(
            document.is_object(),
            "Invalid native notification configuration"
        );
        document["version"] = json!(1);
        document["enabled"] = json!(enabled);
        self.store.save_document(DOCUMENT, &document)?;
        self.notification_events.enabled = enabled;
        self.notification_events.error = None;
        if !enabled {
            self.notification_events
                .entries
                .retain(|_, entry| matches!(entry.state, State::InFlight(_)));
        }
        self.revision += 1;
        Ok(self.notification_events.status())
    }
    /// Copy at most 16 claims while locked, then release the Engine lock before
    /// passing them to an async native delivery worker. Never expire in-flight
    /// claims: an absent receipt cannot prove nothing was delivered.
    pub fn claim_notification_events(&mut self, limit: usize) -> Vec<NotificationClaim> {
        if !self.notification_events.enabled || self.shutdown {
            return Vec::new();
        }
        let mut claims = Vec::new();
        for (key, entry) in &mut self.notification_events.entries {
            if claims.len() >= limit.min(16) {
                break;
            }
            if entry.state != State::Ready {
                continue;
            }
            let Ok(thread) = self.store.thread(&entry.thread_id) else {
                continue;
            };
            if thread["isArchived"] == true {
                continue;
            }
            if let Some(request) = &entry.request {
                // Store uses uppercase UUIDs; compare parsed identities, not casing.
                let pending = self.runs.iter().any(|(id, run)| {
                    Uuid::parse_str(id).ok() == Some(key.thread)
                        && !run.cancelled
                        && run.pending.contains_key(request)
                });
                if !pending {
                    continue;
                }
            }
            let claim_id = Uuid::new_v4();
            entry.state = State::InFlight(claim_id);
            entry.attempts += 1;
            claims.push(NotificationClaim {
                claim_id,
                alert: Alert {
                    key: *key,
                    title: match key.kind {
                        AlertKind::Completed => "Coincide turn completed",
                        AlertKind::Failed => "Coincide turn failed",
                        AlertKind::Approval => "Coincide needs approval",
                        AlertKind::Question => "Coincide has a question",
                        AlertKind::SlowStart => "Coincide is waiting",
                    }
                    .into(),
                    body: None,
                },
            });
        }
        claims
    }
    pub fn ack_notification_event(
        &mut self,
        claim_id: Uuid,
        key: EventKey,
        outcome: NotificationAck,
    ) -> Result<()> {
        let entry = self
            .notification_events
            .entries
            .get_mut(&key)
            .context("Notification claim is no longer pending")?;
        ensure!(
            entry.state == State::InFlight(claim_id),
            "Stale notification acknowledgement"
        );
        match outcome {
            NotificationAck::Delivered(Delivery::Unavailable) => entry.state = State::Unavailable,
            outcome => {
                if matches!(outcome, NotificationAck::Delivered(Delivery::Uncertain)) {
                    self.notification_events.uncertain =
                        self.notification_events.uncertain.saturating_add(1);
                }
                self.notification_events.entries.remove(&key);
            }
        }
        Ok(())
    }
    /// Explicit retry only after a receipt proves no delivery happened.
    pub fn retry_notification_event(&mut self, key: EventKey) -> Result<()> {
        ensure!(
            self.notification_events.enabled && !self.shutdown,
            "Native notifications are disabled"
        );
        let entry = self
            .notification_events
            .entries
            .get_mut(&key)
            .context("Notification is not retryable")?;
        ensure!(
            entry.state == State::Unavailable,
            "Only definitely unavailable notifications may retry"
        );
        ensure!(
            entry.attempts < MAX_ATTEMPTS,
            "Native notification retry limit reached"
        );
        entry.state = State::Ready;
        Ok(())
    }
}

#[cfg(test)]
#[path = "notification_events_tests.rs"]
mod tests;
