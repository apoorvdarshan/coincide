//! Publish capabilities only after the host's selected-thread handoff is acknowledged.
use super::*;
use std::sync::TryLockError;

pub(super) type Scope = (String, Value, bool);
#[derive(Default)]
pub(super) struct CapabilityCache {
    authoritative: Option<Scope>,
}
pub(super) enum Read {
    Cached,
    Pending(&'static str),
    Ready(Result<Value>),
}
impl CapabilityCache {
    pub(super) fn invalidate(&mut self) {
        self.authoritative = None;
    }
    pub(super) fn is_current(&self, scope: &Scope) -> bool {
        self.authoritative.as_ref() == Some(scope)
    }
    pub(super) fn read(&mut self, shared: &SharedEngine, scope: &Scope) -> Read {
        self.read_with(shared, scope, |engine, id| {
            selection_response(
                engine,
                "agent.selection.capabilities",
                json!({"threadId":id}),
            )
        })
    }
    fn read_with(
        &mut self,
        shared: &SharedEngine,
        scope: &Scope,
        load: impl FnOnce(&mut Engine, &str) -> Result<Value>,
    ) -> Read {
        if self.is_current(scope) {
            return Read::Cached;
        }
        let mut engine = match shared.try_lock() {
            Ok(engine) => engine,
            Err(TryLockError::WouldBlock) => {
                return Read::Pending("Selection is waiting for the conversation owner");
            }
            Err(TryLockError::Poisoned(_)) => {
                self.authoritative = Some(scope.clone());
                return Read::Ready(Err(anyhow::anyhow!("Conversation state is unavailable")));
            }
        };
        // An explicit pending open belongs to its new UI load. Do not reclaim
        // the previous view's authority while that transition is pending.
        if engine
            .requested_open
            .as_ref()
            .is_some_and(|id| id != &scope.0)
        {
            return Read::Pending("Selection is waiting for the requested conversation to open");
        }
        let result = (|| {
            anyhow::ensure!(
                !engine.admissions_frozen(),
                "Application admission is closed"
            );
            let current = engine.store.thread(&scope.0)?;
            anyhow::ensure!(
                scope.1 == selection_envelope(&current),
                "Saved selection changed; reload before refreshing capabilities"
            );
            // Same trusted native handoff as select()/tick(), performed before
            // the read under this lock. A busy earlier handoff is not a verdict.
            if engine.active_thread() != Some(scope.0.as_str())
                && let Err(error) = engine.set_active_thread(Some(scope.0.clone()))
            {
                let _ = engine.set_active_thread(None);
                return Err(error);
            }
            anyhow::ensure!(
                engine.active_thread() == Some(scope.0.as_str()),
                "Conversation owner did not acknowledge the selected thread"
            );
            load(&mut engine, &scope.0)
        })();
        // Actual responses (including a missing/stale private model proof) are
        // stable cache entries. Only lock contention/pending handoff may retry.
        self.authoritative = Some(scope.clone());
        Read::Ready(result)
    }
}
pub(super) fn selection_envelope(thread: &Value) -> Value {
    json!({"selection":thread["selection"],"accessMode":thread["accessMode"],"interactionMode":thread["interactionMode"]})
}
pub(super) fn closed_capabilities(scope: &Scope, reason: &str) -> Value {
    let mut value = coincide_core::composer_selection::capabilities();
    value["locked"] = json!(true);
    value["lockReason"] = json!(reason);
    if scope.1["selection"]["provider"] == "codex"
        && !coincide_core::composer_selection::default_account(&scope.1["selection"]["accountID"])
    {
        value["namedModels"] = json!({"supported":true,"threadId":scope.0,"accountID":scope.1["selection"]["accountID"],"refreshAllowed":false,"reason":reason,"authenticationChecked":false,"accountIdentityVerified":false});
    }
    value
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        cell::Cell,
        path::PathBuf,
        sync::{Arc, Mutex},
    };
    struct FixtureDirectory(PathBuf);
    impl Drop for FixtureDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn fixture() -> (FixtureDirectory, SharedEngine, Value, Value) {
        let dir = FixtureDirectory(std::env::temp_dir().join(format!(
            "coincide-capability-handoff-{}",
            uuid::Uuid::new_v4()
        )));
        std::fs::create_dir(&dir.0).unwrap();
        let mut engine = Engine::new(Store::open(&dir.0.join("state.sqlite")).unwrap());
        let a = selection_response(&mut engine, "threads.create", json!({})).unwrap();
        let b = selection_response(&mut engine, "threads.create", json!({})).unwrap();
        engine.set_active_thread(Some(text(&a, "id"))).unwrap();
        (dir, Arc::new(Mutex::new(engine)), a, b)
    }
    fn scope(thread: &Value) -> Scope {
        (text(thread, "id"), selection_envelope(thread), false)
    }
    fn actual_read(
        cache: &mut CapabilityCache,
        shared: &SharedEngine,
        scope: &Scope,
        reads: &Cell<usize>,
    ) -> Read {
        cache.read_with(shared, scope, |engine, id| {
            assert_eq!(engine.active_thread(), Some(id));
            reads.set(reads.get() + 1);
            selection_response(
                engine,
                "agent.selection.capabilities",
                json!({"threadId":id}),
            )
        })
    }
    #[::core::prelude::v1::test]
    fn selection_capability_handoff_busy_a_b_a_reads_once_after_owner_ack() {
        let (_dir, shared, a, b) = fixture();
        let mut cache = CapabilityCache::default();
        let reads = Cell::new(0);
        assert!(matches!(
            actual_read(&mut cache, &shared, &scope(&a), &reads),
            Read::Ready(Ok(value)) if value["locked"] == false
        ));
        let held = shared.lock().unwrap();
        assert!(matches!(
            actual_read(&mut cache, &shared, &scope(&b), &reads),
            Read::Pending(_)
        ));
        assert_eq!(reads.get(), 1);
        assert!(!cache.is_current(&scope(&b)));
        let closed = closed_capabilities(&scope(&b), "pending owner");
        assert!(current_submission_blocked(
            Some(&scope(&b)),
            &closed,
            &b,
            false
        ));
        assert_eq!(held.active_thread(), a["id"].as_str());
        drop(held);
        assert!(matches!(
            actual_read(&mut cache, &shared, &scope(&b), &reads),
            Read::Ready(Ok(value)) if value["locked"] == false
        ));
        assert_eq!(shared.lock().unwrap().active_thread(), b["id"].as_str());
        for _ in 0..8 {
            assert!(matches!(
                actual_read(&mut cache, &shared, &scope(&b), &reads),
                Read::Cached
            ));
        }
        assert_eq!(reads.get(), 2);
        assert!(matches!(
            actual_read(&mut cache, &shared, &scope(&a), &reads),
            Read::Ready(Ok(value)) if value["locked"] == false
        ));
        assert_eq!(shared.lock().unwrap().active_thread(), a["id"].as_str());
        assert_eq!(reads.get(), 3);
        let mut named = b.clone();
        named["selection"]["accountID"] = json!(uuid::Uuid::new_v4().to_string());
        let closed = closed_capabilities(&scope(&named), "pending owner");
        assert_eq!(closed["namedModels"]["refreshAllowed"], false);
        assert_eq!(closed["namedModels"]["threadId"], b["id"]);
        assert!(current_submission_blocked(
            Some(&scope(&named)),
            &closed,
            &named,
            false
        ));
    }
    #[::core::prelude::v1::test]
    fn selection_capability_handoff_keeps_real_proof_lock_and_pending_open_closed() {
        let (_dir, shared, a, mut b) = fixture();
        b["selection"]["modelID"] = json!("gpt-6-astra");
        shared.lock().unwrap().store.save(&b).unwrap();
        let mut cache = CapabilityCache::default();
        let reads = Cell::new(0);
        shared.lock().unwrap().requested_open = Some(text(&a, "id"));
        assert!(matches!(
            actual_read(&mut cache, &shared, &scope(&b), &reads),
            Read::Pending(_)
        ));
        assert_eq!(reads.get(), 0);
        assert_eq!(shared.lock().unwrap().active_thread(), a["id"].as_str());
        shared.lock().unwrap().requested_open = None;
        let Read::Ready(Ok(caps)) = actual_read(&mut cache, &shared, &scope(&b), &reads) else {
            panic!("actual capability read did not finish")
        };
        assert_eq!(caps["locked"], true);
        assert_eq!(caps["canReplaceUnprovedAutomaticDefault"], true);
        assert!(current_submission_blocked(
            Some(&scope(&b)),
            &caps,
            &b,
            false
        ));
        for _ in 0..8 {
            assert!(matches!(
                actual_read(&mut cache, &shared, &scope(&b), &reads),
                Read::Cached
            ));
        }
        assert_eq!(reads.get(), 1);
        cache.invalidate();
        assert!(
            matches!(actual_read(&mut cache,&shared,&scope(&b),&reads),Read::Ready(Ok(value)) if value["locked"]==true)
        );
        assert_eq!(reads.get(), 2);
    }
    #[::core::prelude::v1::test]
    fn selection_capability_handoff_never_claims_stale_or_frozen_target() {
        let (_dir, shared, a, b) = fixture();
        let mut changed = b.clone();
        changed["selection"]["modelID"] = json!("synthetic-external-change");
        shared.lock().unwrap().store.save(&changed).unwrap();
        let mut cache = CapabilityCache::default();
        let reads = Cell::new(0);
        assert!(matches!(
            actual_read(&mut cache, &shared, &scope(&b), &reads),
            Read::Ready(Err(_))
        ));
        assert_eq!(reads.get(), 0);
        assert_eq!(shared.lock().unwrap().active_thread(), a["id"].as_str());
        assert!(matches!(
            actual_read(&mut cache, &shared, &scope(&b), &reads),
            Read::Cached
        ));
        assert!(matches!(
            actual_read(&mut cache, &shared, &scope(&changed), &reads),
            Read::Ready(Ok(_))
        ));
        assert_eq!(reads.get(), 1);
        shared.lock().unwrap().freeze_admissions();
        assert!(matches!(
            actual_read(&mut cache, &shared, &scope(&a), &reads),
            Read::Ready(Err(_))
        ));
        assert_eq!(reads.get(), 1);
        assert_eq!(shared.lock().unwrap().active_thread(), b["id"].as_str());
    }
}
