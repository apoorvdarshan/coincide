//! Typed desktop handoff only. This module never enables authority, grants a
//! thread, requests OS permission, or invokes a native backend.
use super::*;
use crate::computer_use::{Authority, Failure, MAX_REQUEST, MAX_RESULT, Request};

pub(super) const METHODS: &[&str] = &["computer_use.request", "computer_use.result"];
const CAPACITY: usize = 8;
const DEADLINE: Duration = Duration::from_secs(10);
const RETENTION: Duration = Duration::from_secs(30);

pub struct Pending {
    pub id: Uuid,
    pub thread: Uuid,
    pub grant: Uuid,
    pub request: Request,
    pub deadline: Instant,
}
struct Operation {
    thread: Uuid,
    grant: Uuid,
    deadline: Instant,
    result: Option<std::result::Result<Value, Failure>>,
    finished: Option<Instant>,
}
#[derive(Default)]
pub(super) struct State {
    authority: Option<Authority>,
    queue: VecDeque<Pending>,
    operations: HashMap<Uuid, Operation>,
}
impl State {
    fn expire(&mut self) -> bool {
        let now = Instant::now();
        let mut changed = false;
        let authority = self.authority.as_ref();
        self.operations.retain(|_, op| {
            if op.result.is_none() && now >= op.deadline {
                op.result = Some(Err(Failure::TimedOut));
                op.finished = Some(now);
                changed = true;
            }
            if authority.is_none_or(|authority| authority.grant(op.thread) != Ok(op.grant))
                && !matches!(op.result.as_ref(), Some(Err(Failure::Revoked)))
            {
                op.result = Some(Err(Failure::Revoked));
                op.finished = Some(now);
                changed = true;
            }
            let keep = op
                .finished
                .is_none_or(|finished| now.saturating_duration_since(finished) < RETENTION);
            changed |= !keep;
            keep
        });
        self.queue.retain(|queued| {
            self.operations
                .get(&queued.id)
                .is_some_and(|op| op.result.is_none())
        });
        changed
    }
    fn revoke(&mut self, thread: Option<Uuid>) -> bool {
        let mut changed = false;
        for op in self
            .operations
            .values_mut()
            .filter(|op| thread.is_none_or(|thread| op.thread == thread))
        {
            if !matches!(op.result.as_ref(), Some(Err(Failure::Revoked))) {
                op.result = Some(Err(Failure::Revoked));
                op.finished = Some(Instant::now());
                changed = true;
            }
        }
        self.queue
            .retain(|queued| thread.is_some_and(|thread| queued.thread != thread));
        changed
    }
}
impl Engine {
    /// Native parent only: bind the exact Authority shared by the Runtime.
    /// This does not enable it or grant a thread. No JSON route exposes binding.
    pub fn computer_use_bind_authority(&mut self, authority: Authority) {
        self.computer_use_revoke_all();
        self.computer_use.authority = Some(authority);
    }
    pub fn computer_use_unbind_authority(&mut self) {
        self.computer_use_revoke_all();
        self.computer_use.authority = None;
    }
    /// Trusted provider transport entry point. The context must come from the
    /// session/transport owner; it must never be derived from JSON parameters.
    /// Only this narrow tool bridge is accepted on the scoped provider channel.
    pub fn dispatch_scoped(&mut self, request: Value, trusted_thread: Uuid) -> Value {
        self.dispatch_computer_use(request, Some(trusted_thread))
    }
    /// A provider channel without a session identity cannot inherit owner-CLI
    /// privileges by supplying a thread ID in its payload.
    pub fn dispatch_provider(&mut self, request: Value, trusted_thread: Option<Uuid>) -> Value {
        match trusted_thread {
            Some(thread) => self.dispatch_scoped(request, thread),
            None => {
                json!({"id":request.get("id"),"error":{"message":"Provider Computer Use requires trusted thread context"}})
            }
        }
    }
    fn dispatch_computer_use(&mut self, request: Value, trusted_thread: Option<Uuid>) -> Value {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let method = request["method"].as_str().unwrap_or("");
        let result = if METHODS.contains(&method) {
            self.computer_use_command(method, &request["params"], trusted_thread)
        } else {
            bail_scoped()
        };
        match result {
            Ok(result) => json!({"id":id,"result":result}),
            Err(error) => json!({"id":id,"error":{"message":error.to_string()}}),
        }
    }
    pub(super) fn computer_use_command(
        &mut self,
        method: &str,
        params: &Value,
        trusted_thread: Option<Uuid>,
    ) -> Result<Value> {
        ensure!(
            !self.shutdown || method == "computer_use.result",
            "Application is shutting down"
        );
        let object = params
            .as_object()
            .context("Computer Use parameters must be an object")?;
        let allowed: &[&str] = match method {
            "computer_use.request" => &["threadId", "request"],
            "computer_use.result" => &["threadId", "operationId"],
            _ => bail!("Unsupported Computer Use method"),
        };
        ensure!(
            object.keys().all(|key| allowed.contains(&key.as_str())),
            "Unsupported Computer Use parameter"
        );
        let thread_text = required(params, "threadId")?;
        let thread = Uuid::parse_str(thread_text).context("Invalid Computer Use thread ID")?;
        let selected = self
            .active_thread
            .as_deref()
            .context("Select a stored thread before using Computer Use")?;
        ensure!(
            Uuid::parse_str(selected).ok() == Some(thread),
            "Select this stored thread before using Computer Use"
        );
        // Preserve the Store's original ID spelling (legacy UUIDs are often
        // uppercase); transport/native identities compare as typed UUIDs.
        self.store.thread(selected)?;
        ensure!(
            trusted_thread.is_none_or(|trusted| trusted == thread),
            "Computer Use payload does not match the trusted transport thread"
        );
        if self.computer_use.expire() {
            self.revision += 1;
        }
        if method == "computer_use.result" {
            let id = Uuid::parse_str(required(params, "operationId")?)
                .context("Invalid Computer Use operation ID")?;
            let op = self
                .computer_use
                .operations
                .get(&id)
                .context("Computer Use operation not found or expired")?;
            ensure!(
                op.thread == thread,
                "Computer Use operation belongs to another thread"
            );
            if op.result.is_none() {
                return Ok(json!({"ready":false,"result":null,"error":null}));
            }
            let op = self.computer_use.operations.remove(&id).unwrap();
            self.revision += 1;
            return Ok(match op.result.unwrap() {
                Ok(result) => json!({"ready":true,"result":result,"error":null}),
                Err(error) => json!({"ready":true,"result":null,"error":error}),
            });
        }
        ensure!(
            self.ui_available,
            "Computer Use requires the desktop window"
        );
        ensure!(
            self.computer_use.operations.len() < CAPACITY,
            "Computer Use queue is full; collect completed results first"
        );
        ensure!(
            !self
                .computer_use
                .operations
                .values()
                .any(|op| op.thread == thread && op.result.is_none()),
            "Computer Use already has a pending request for this thread"
        );
        let bytes = serde_json::to_vec(
            params
                .get("request")
                .context("Computer Use request required")?,
        )?;
        ensure!(
            bytes.len() <= MAX_REQUEST,
            "Computer Use request exceeds its size limit"
        );
        let request = Request::parse(&bytes).map_err(|failure| {
            anyhow::anyhow!("Invalid typed Computer Use request: {failure:?}")
        })?;
        let grant = self
            .computer_use
            .authority
            .as_ref()
            .context("Computer Use desktop authority is not bound")?
            .grant(thread)
            .map_err(|failure| anyhow::anyhow!("Computer Use unavailable: {failure:?}"))?;
        let id = Uuid::new_v4();
        let deadline = Instant::now() + DEADLINE;
        self.computer_use.operations.insert(
            id,
            Operation {
                thread,
                grant,
                deadline,
                result: None,
                finished: None,
            },
        );
        self.computer_use.queue.push_back(Pending {
            id,
            thread,
            grant,
            request,
            deadline,
        });
        self.revision += 1;
        Ok(json!({"operationId":id}))
    }
    /// Move requests under a short Engine lock, then release it before calling
    /// Runtime.Handle. Native handoff must preserve this original deadline.
    pub fn computer_use_drain(&mut self) -> Vec<Pending> {
        if self.computer_use.expire() {
            self.revision += 1;
        }
        if self.shutdown {
            self.computer_use_shutdown();
            return Vec::new();
        }
        let selected = self
            .active_thread
            .as_deref()
            .and_then(|id| Uuid::parse_str(id).ok());
        let stale = self
            .computer_use
            .queue
            .iter()
            .filter(|queued| Some(queued.thread) != selected)
            .map(|queued| queued.thread)
            .collect::<Vec<_>>();
        for thread in stale {
            self.computer_use_revoke(thread);
        }
        self.computer_use.queue.drain(..).collect()
    }
    /// Native owner only; no JSON route accepts replies or authority changes.
    /// Runtime must recheck grant/deadline before giving the parent this result.
    pub fn computer_use_reply(
        &mut self,
        id: Uuid,
        thread: Uuid,
        result: std::result::Result<Value, Failure>,
    ) -> bool {
        if self.computer_use.expire() {
            self.revision += 1;
        }
        if self.shutdown {
            return false;
        }
        let Some(op) = self.computer_use.operations.get_mut(&id) else {
            return false;
        };
        if op.thread != thread || op.result.is_some() {
            return false;
        }
        op.result = Some(match result {
            Ok(value)
                if serde_json::to_vec(&value)
                    .is_ok_and(|bytes| bytes.len() <= MAX_RESULT.saturating_sub(1024)) =>
            {
                Ok(value)
            }
            Ok(_) => Err(Failure::TooLarge),
            Err(error) => Err(error),
        });
        op.finished = Some(Instant::now());
        self.revision += 1;
        true
    }
    /// Call alongside the native UI's revoke/disable action. This only clears
    /// the Engine handoff/results; native Runtime owns the actual authority.
    pub fn computer_use_revoke(&mut self, thread: Uuid) {
        if self.computer_use.revoke(Some(thread)) {
            self.revision += 1;
        }
    }
    /// Trusted selection transition: revoke the old grant synchronously, even
    /// when desktop polling never observes an intermediate selected thread.
    pub(super) fn computer_use_selection_changed(&mut self, thread: Uuid) {
        if let Some(authority) = self.computer_use.authority.as_ref() {
            authority.native_revoke(thread);
        }
        self.computer_use_revoke(thread);
    }
    /// Pair with native master disable, which revokes every Runtime grant.
    /// Invalidate queued work and retained observation payloads for all threads.
    pub fn computer_use_revoke_all(&mut self) {
        if self.computer_use.revoke(None) {
            self.revision += 1;
        }
    }
    pub fn computer_use_shutdown(&mut self) {
        self.computer_use_unbind_authority();
    }
    pub(super) fn computer_use_expire(&mut self) {
        if self.computer_use.expire() {
            self.revision += 1;
        }
    }
}
fn bail_scoped() -> Result<Value> {
    bail!("Unsupported scoped provider method")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::computer_use::Authority;
    fn fixture() -> (tempfile::TempDir, Engine, String, String) {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        let a = text(&engine.execute("threads.create", &json!({})).unwrap(), "id");
        let b = text(&engine.execute("threads.create", &json!({})).unwrap(), "id");
        engine.active_thread = Some(a.clone());
        engine.ui_available = true;
        let authority = Authority::default();
        authority.native_enable(true);
        authority
            .native_grant(Uuid::parse_str(&a).unwrap())
            .unwrap();
        authority
            .native_grant(Uuid::parse_str(&b).unwrap())
            .unwrap();
        engine.computer_use_bind_authority(authority);
        (dir, engine, a, b)
    }
    fn request(thread: &str) -> Value {
        json!({"threadId":thread,"request":{"action":"status"}})
    }
    fn result(thread: &str, id: Uuid) -> Value {
        json!({"threadId":thread,"operationId":id})
    }
    fn admit(engine: &mut Engine, thread: &str) -> Uuid {
        Uuid::parse_str(
            engine
                .execute("computer_use.request", &request(thread))
                .unwrap()["operationId"]
                .as_str()
                .unwrap(),
        )
        .unwrap()
    }
    #[test]
    fn local_owner_requires_selected_stored_thread_and_typed_payload_cannot_grant() {
        let (_dir, mut e, a, b) = fixture();
        let authority = e.computer_use.authority.as_ref().unwrap().clone();
        authority.native_enable(false);
        let before = e.store.thread(&a).unwrap();
        for p in [
            request(&b),
            json!({"threadId":a,"request":{"action":"enable"}}),
            json!({"threadId":a,"request":{"action":"status","grant":"forged"}}),
            json!({"threadId":a,"request":{"action":"call","name":"request_permission","arguments":{}}}),
            json!({"threadId":a,"grant":true,"request":{"action":"status"}}),
        ] {
            assert!(e.execute("computer_use.request", &p).is_err());
        }
        assert!(e.computer_use_drain().is_empty());
        e.ui_available = false;
        assert!(e.execute("computer_use.request", &request(&a)).is_err());
        e.ui_available = true;
        assert!(e.execute("computer_use.request", &request(&a)).is_err());
        assert!(e.computer_use_drain().is_empty());
        e.computer_use_unbind_authority();
        assert!(e.execute("computer_use.request", &request(&a)).is_err());
        assert!(!authority.enabled());
        assert_eq!(e.store.thread(&a).unwrap(), before);
    }
    #[test]
    fn transport_uuid_case_alias_preserves_selected_store_identity_and_result_scope() {
        let (_dir, mut e, a, _) = fixture();
        let canonical = Uuid::parse_str(&a).unwrap();
        let before = e.store.thread(&a).unwrap();
        let lower = canonical.to_string();
        let payload = json!({"method":"computer_use.request","params":request(&lower)});
        let accepted = e.dispatch_scoped(payload, canonical);
        let id = Uuid::parse_str(accepted["result"]["operationId"].as_str().unwrap()).unwrap();
        let pending = e.computer_use_drain();
        assert_eq!(pending[0].thread, canonical);
        assert!(e.computer_use_reply(id, canonical, Err(Failure::Off)));
        assert_eq!(
            e.dispatch_scoped(
                json!({"method":"computer_use.result","params":result(&lower,id)}),
                canonical
            )["result"]["error"],
            "off"
        );
        assert_eq!(e.store.thread(&a).unwrap(), before);
        assert_eq!(e.active_thread.as_deref(), Some(a.as_str()));
    }
    #[test]
    fn provider_context_spoof_and_unscoped_provider_requests_fail_closed() {
        let (_dir, mut e, a, b) = fixture();
        let payload = json!({"id":1,"method":"computer_use.request","params":request(&a)});
        assert!(
            e.dispatch_scoped(payload.clone(), Uuid::parse_str(&b).unwrap())
                .get("error")
                .is_some()
        );
        assert!(
            e.dispatch_provider(payload.clone(), None)
                .get("error")
                .is_some()
        );
        assert!(e.computer_use_drain().is_empty());
        let accepted = e.dispatch_scoped(payload, Uuid::parse_str(&a).unwrap());
        assert!(accepted.get("result").is_some());
        assert_eq!(e.computer_use_drain().len(), 1);
        assert!(
            e.dispatch_scoped(
                json!({"method":"app.quit","params":{}}),
                Uuid::parse_str(&a).unwrap()
            )
            .get("error")
            .is_some()
        );
        assert!(!e.shutdown);
    }
    #[test]
    fn queue_is_one_pending_per_thread_bounded_and_never_replays_drained_requests() {
        let (_dir, mut e, a, _) = fixture();
        admit(&mut e, &a);
        assert!(e.execute("computer_use.request", &request(&a)).is_err());
        for _ in 1..CAPACITY {
            let id = text(&e.execute("threads.create", &json!({})).unwrap(), "id");
            e.active_thread = Some(id.clone());
            e.computer_use
                .authority
                .as_ref()
                .unwrap()
                .native_grant(Uuid::parse_str(&id).unwrap())
                .unwrap();
            admit(&mut e, &id);
        }
        let ninth = text(&e.execute("threads.create", &json!({})).unwrap(), "id");
        e.active_thread = Some(ninth.clone());
        assert!(e.execute("computer_use.request", &request(&ninth)).is_err());
        assert_eq!(e.computer_use.operations.len(), CAPACITY);
        // Selection changed: stale queued work is completed revoked rather than
        // dispatched under another selected thread's current UI context.
        assert!(e.computer_use_drain().is_empty());
        assert!(
            e.computer_use
                .operations
                .values()
                .all(|op| matches!(op.result.as_ref(), Some(Err(Failure::Revoked))))
        );
    }
    #[test]
    fn replies_and_collection_require_exact_operation_and_thread() {
        let (_dir, mut e, a, b) = fixture();
        let id = admit(&mut e, &a);
        let jobs = e.computer_use_drain();
        assert_eq!(jobs.len(), 1);
        let thread = Uuid::parse_str(&a).unwrap();
        assert!(!e.computer_use_reply(
            id,
            Uuid::parse_str(&b).unwrap(),
            Ok(json!({"private":"fixture"}))
        ));
        assert!(!e.computer_use_reply(Uuid::new_v4(), thread, Ok(json!({}))));
        assert!(e.computer_use_reply(id, thread, Ok(json!({"fixture":true}))));
        assert!(!e.computer_use_reply(id, thread, Ok(json!({"different":true}))));
        e.active_thread = Some(b.clone());
        assert!(e.execute("computer_use.result", &result(&b, id)).is_err());
        e.active_thread = Some(a.clone());
        assert_eq!(
            e.execute("computer_use.result", &result(&a, id)).unwrap()["result"],
            json!({"fixture":true})
        );
        assert!(e.execute("computer_use.result", &result(&a, id)).is_err());
        assert!(e.computer_use_drain().is_empty());
    }
    #[test]
    fn deadline_revoke_and_shutdown_invalidate_late_results_without_native_retry() {
        let (_dir, mut e, a, _) = fixture();
        let thread = Uuid::parse_str(&a).unwrap();
        let expired = admit(&mut e, &a);
        e.computer_use
            .operations
            .get_mut(&expired)
            .unwrap()
            .deadline = Instant::now() - Duration::from_millis(1);
        assert!(e.computer_use_drain().is_empty());
        assert!(!e.computer_use_reply(expired, thread, Ok(json!({"late":true}))));
        assert_eq!(
            e.execute("computer_use.result", &result(&a, expired))
                .unwrap()["error"],
            "timed_out"
        );
        let revoked = admit(&mut e, &a);
        e.computer_use_drain();
        assert!(e.computer_use_reply(revoked, thread, Ok(json!({"private":"old-grant"}))));
        e.computer_use_revoke(thread);
        assert_eq!(
            e.execute("computer_use.result", &result(&a, revoked))
                .unwrap()["error"],
            "revoked"
        );
        let stopped = admit(&mut e, &a);
        e.execute("app.quit", &json!({})).unwrap();
        assert!(e.computer_use_drain().is_empty());
        assert!(!e.computer_use_reply(stopped, thread, Ok(json!({}))));
        assert!(e.execute("computer_use.request", &request(&a)).is_err());
        assert_eq!(
            e.execute("computer_use.result", &result(&a, stopped))
                .unwrap()["error"],
            "revoked"
        );
    }
    #[test]
    fn collection_rechecks_shared_authority_without_waiting_for_native_revoke_hook() {
        let (_dir, mut e, a, _) = fixture();
        let thread = Uuid::parse_str(&a).unwrap();
        let authority = e.computer_use.authority.as_ref().unwrap().clone();
        for rotate in [false, true] {
            if authority.grant(thread).is_err() {
                authority.native_grant(thread).unwrap();
            }
            let id = admit(&mut e, &a);
            let pending = e.computer_use_drain();
            assert_eq!(pending[0].grant, authority.grant(thread).unwrap());
            assert!(e.computer_use_reply(id, thread, Ok(json!({"private":"prior-epoch"}))));
            if rotate {
                authority.native_grant(thread).unwrap();
            } else {
                authority.native_revoke(thread);
            }
            // No Engine revoke hook/tick here: collection itself must fence
            // retained successful observation content against the live grant.
            assert_eq!(
                e.execute("computer_use.result", &result(&a, id)).unwrap()["error"],
                "revoked"
            );
        }
        let id = admit(&mut e, &a);
        authority.native_grant(thread).unwrap();
        assert!(
            e.computer_use_drain().is_empty(),
            "old epoch work must not enter Runtime"
        );
        assert_eq!(
            e.execute("computer_use.result", &result(&a, id)).unwrap()["error"],
            "revoked"
        );
    }
    #[test]
    fn native_master_disable_invalidates_all_threads_and_retained_observations() {
        let (_dir, mut e, a, b) = fixture();
        let first = admit(&mut e, &a);
        e.computer_use_drain();
        assert!(e.computer_use_reply(
            first,
            Uuid::parse_str(&a).unwrap(),
            Ok(json!({"observation":"old-grant"}))
        ));
        e.active_thread = Some(b.clone());
        let second = admit(&mut e, &b);
        e.computer_use_revoke_all();
        assert!(e.computer_use_drain().is_empty());
        assert_eq!(
            e.execute("computer_use.result", &result(&b, second))
                .unwrap()["error"],
            "revoked"
        );
        e.active_thread = Some(a.clone());
        assert_eq!(
            e.execute("computer_use.result", &result(&a, first))
                .unwrap()["error"],
            "revoked"
        );
        assert!(
            !e.shutdown,
            "native disable must not shut down the application"
        );
    }
    #[test]
    fn request_result_size_limits_and_expired_result_retention_are_bounded() {
        let (_dir, mut e, a, _) = fixture();
        let thread = Uuid::parse_str(&a).unwrap();
        let too_large = json!({"threadId":a,"request":{"action":"call","name":"set_value","arguments":{"element_token":Uuid::new_v4(),"text":"x".repeat(MAX_REQUEST)}}});
        assert!(e.execute("computer_use.request", &too_large).is_err());
        let id = admit(&mut e, &a);
        e.computer_use_drain();
        assert!(e.computer_use_reply(id, thread, Ok(json!("x".repeat(MAX_RESULT)))));
        assert_eq!(
            e.execute("computer_use.result", &result(&a, id)).unwrap()["error"],
            "too_large"
        );
        let abandoned = admit(&mut e, &a);
        e.computer_use_revoke(thread);
        e.computer_use
            .operations
            .get_mut(&abandoned)
            .unwrap()
            .finished = Some(Instant::now() - RETENTION);
        e.computer_use_expire();
        assert!(!e.computer_use.operations.contains_key(&abandoned));
        assert!(e.computer_use_drain().is_empty());
    }
}
