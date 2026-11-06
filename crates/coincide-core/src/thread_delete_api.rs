//! Typed human archive confirmation and session-only Undo. Deliberately absent
//! from Engine JSON dispatch; caller JSON/import data cannot construct a plan.
use super::*;
use crate::store::{ArchivedConversations, DeleteRow, DeleteVersion};
pub struct PreparedThreadDeletion {
    owner: Uuid,
    source: (PathBuf, crate::private_fs::Identity),
    version: DeleteVersion,
    rows: Vec<DeleteRow>,
}

impl PreparedThreadDeletion {
    pub fn count(&self) -> usize {
        self.rows.len()
    }
    pub fn titles(&self) -> Vec<String> {
        self.rows
            .iter()
            .take(8)
            .map(|row| row.title.clone())
            .collect()
    }
    pub fn byte_len(&self) -> usize {
        self.rows.iter().map(|row| row.raw.len()).sum()
    }
}
/// Retained by the native panel only until Quit. No serialization/Clone or
/// import path exists, and another Engine cannot adopt this receipt.
pub struct ThreadDeletionUndo {
    owner: Uuid,
    source: (PathBuf, crate::private_fs::Identity),
    token: String,
    rows: Vec<DeleteRow>,
}
impl ThreadDeletionUndo {
    pub fn count(&self) -> usize {
        self.rows.len()
    }
    pub fn byte_len(&self) -> usize {
        self.rows.iter().map(|row| row.raw.len()).sum()
    }
    pub fn thread_ids(&self) -> Vec<String> {
        self.rows.iter().map(|row| row.id.clone()).collect()
    }
}
impl Engine {
    pub(super) fn unrevoked_provider_session(
        &self,
        thread: &Value,
        provider: &str,
    ) -> Result<Option<String>> {
        let session = agent::provider_session(thread, provider);
        let account = thread["selection"]["accountID"]
            .as_str()
            .filter(|value| !value.is_empty())
            .unwrap_or("default");
        if let Some(native) = &session
            && (self
                .store
                .is_native_session_revoked(required(thread, "id")?, native)?
                || provider == "codex"
                    && self.store.is_native_session_uncertain(
                        required(thread, "id")?,
                        account,
                        native,
                    )?)
        {
            return Ok(None);
        }
        Ok(session)
    }
    fn archive_delete_admitted(&mut self, ids: &[String], deleting: bool) -> Result<()> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let workers = self.provider_workers_status();
        ensure!(
            self.runs.is_empty()
                && workers.running == 0
                && workers.panicked == 0
                && workers.unclassified == 0,
            "Wait for all provider workers to finish cleanup before deleting or restoring conversations"
        );
        ensure!(
            self.workspace_mutations.is_empty()
                && self.steering_operations.is_empty()
                && !self.native_follow_up.has_pending()
                && self.schedule_completions.is_empty(),
            "Wait for pending workspace/provider results before deleting or restoring conversations"
        );
        ensure!(
            self.codex_profile_login
                .as_ref()
                .is_none_or(|operation| !operation.active()),
            "Wait for provider sign-in cleanup before deleting conversations"
        );
        ensure!(
            self.notification_events.status()["inFlight"].as_u64() == Some(0),
            "Wait for native notification delivery before deleting conversations"
        );
        for id in ids {
            ensure!(
                !self.unsaved_threads.contains_key(id) && !self.pending_usage.contains_key(id),
                "A conversation has unsaved transcript or usage changes"
            );
            ensure!(
                !self.attachment_operations.contains(id)
                    && !self
                        .workspace_pending
                        .values()
                        .any(|(owner, _)| owner.eq_ignore_ascii_case(id)),
                "Wait for this conversation's draft or file import to finish"
            );
            ensure!(
                !self
                    .terminals
                    .values()
                    .any(|(owner, _)| owner.eq_ignore_ascii_case(id)),
                "Close this conversation's terminal panes before deleting it"
            );
            ensure!(
                !self
                    .browser_pending
                    .values()
                    .any(|(owner, _)| owner.eq_ignore_ascii_case(id))
                    && !self
                        .browser_requests
                        .iter()
                        .any(|request| request.thread_id.eq_ignore_ascii_case(id)),
                "Wait for this conversation's browser work to finish"
            );
            if let Ok(thread) = self.store.thread(id) {
                ensure!(
                    thread["rustMessageQueue"]
                        .as_array()
                        .is_none_or(Vec::is_empty),
                    "Pause and clear queued messages before deleting this conversation"
                );
            }
        }
        if deleting {
            let schedules = self
                .store
                .document("scheduled-tasks.json")?
                .unwrap_or(json!({"tasks":[]}));
            let tasks=schedules["tasks"].as_array().context("Scheduled tasks are malformed; repair or remove their configuration before deleting conversations")?;
            ensure!(
                !tasks.iter().any(|task| task["threadID"]
                    .as_str()
                    .is_some_and(|thread| ids.iter().any(|id| id.eq_ignore_ascii_case(thread)))),
                "A schedule targets a selected conversation; remove or retarget that schedule before deleting it"
            );
        }
        Ok(())
    }
    pub fn native_archived_conversations(
        &self,
        query: &str,
        offset: usize,
        limit: usize,
    ) -> Result<ArchivedConversations> {
        self.store.archived_conversations(query, offset, limit)
    }
    pub fn native_archived_conversations_for_project(
        &self,
        query: &str,
        project: Option<&str>,
        offset: usize,
        limit: usize,
    ) -> Result<ArchivedConversations> {
        self.store
            .archived_conversations_for_project(query, project, offset, limit)
    }
    pub fn prepare_native_thread_deletion(
        &mut self,
        ids: &[String],
    ) -> Result<PreparedThreadDeletion> {
        self.archive_delete_admitted(ids, true)?;
        let source = self.store.delete_source_identity()?;
        let (version, rows) = self.store.prepare_delete_rows(ids)?;
        ensure!(
            self.store.delete_source_identity()? == source,
            "Archive Store changed while preparing confirmation"
        );
        Ok(PreparedThreadDeletion {
            owner: self.thread_bulk_owner,
            source,
            version,
            rows,
        })
    }
    /// Call only from the native Delete confirmation callback. Consumes the
    /// reviewed plan; any stale/failing confirmation requires a new review.
    pub fn apply_native_thread_deletion(
        &mut self,
        mut prepared: PreparedThreadDeletion,
    ) -> Result<ThreadDeletionUndo> {
        ensure!(
            prepared.owner == self.thread_bulk_owner
                && self.store.delete_source_identity()? == prepared.source,
            "Deletion review belongs to another app or Store owner"
        );
        let ids = prepared
            .rows
            .iter()
            .map(|row| row.id.clone())
            .collect::<Vec<_>>();
        self.archive_delete_admitted(&ids, true)?;
        self.store
            .validate_delete_rows(prepared.version, &prepared.rows)?;
        // Revocations are intentionally before SQL. A later SQL rollback may
        // discard an optional continuation opportunity, but never removes data.
        if let Some(active) = self.active_thread().and_then(|id| Uuid::parse_str(id).ok())
            && ids
                .iter()
                .any(|id| Uuid::parse_str(id).ok() == Some(active))
        {
            self.cancel_provider_restore();
        }
        self.model_catalog.invalidate_deleted_threads(&ids);
        let revoked = self.named_resume.invalidate_threads(&ids, &self.store)?;
        for (thread, native) in revoked {
            let thread = Uuid::parse_str(&thread)?;
            let row = prepared
                .rows
                .iter_mut()
                .find(|row| Uuid::parse_str(&row.id).ok() == Some(thread))
                .context("Private native-session revocation belongs to another conversation")?;
            row.revoke_native(&native)?;
        }
        for id in &ids {
            self.computer_use_selection_changed(Uuid::parse_str(id)?);
        }
        self.notification_events.discard_deleted_threads(&ids);
        let token = Uuid::new_v4().to_string();
        self.store
            .delete_archived_rows(prepared.version, &prepared.rows, &token)?;
        let selected = ids
            .iter()
            .map(|id| id.to_ascii_lowercase())
            .collect::<HashSet<_>>();
        self.enabled_queues
            .retain(|id| !selected.contains(&id.to_ascii_lowercase()));
        if self
            .active_thread
            .as_ref()
            .is_some_and(|id| selected.contains(&id.to_ascii_lowercase()))
        {
            self.active_thread = None;
            self.requested_open = None;
        }
        self.revision += 1;
        Ok(ThreadDeletionUndo {
            owner: self.thread_bulk_owner,
            source: prepared.source,
            token,
            rows: prepared.rows,
        })
    }
    /// Restores exact content/indexes, never old native/cached launch authority.
    pub fn undo_native_thread_deletion(&mut self, undo: &ThreadDeletionUndo) -> Result<()> {
        ensure!(
            undo.owner == self.thread_bulk_owner
                && self.store.delete_source_identity()? == undo.source,
            "Delete Undo belongs to another app or Store owner"
        );
        self.archive_delete_admitted(&undo.thread_ids(), false)?;
        self.store.restore_deleted_rows(&undo.rows, &undo.token)?;
        self.revision += 1;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Engine, String) {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("data/state.sqlite")).unwrap();
        let mut thread = store.new_thread("").unwrap();
        thread["isArchived"] = json!(true);
        thread["title"] = json!("Synthetic native archive");
        thread["sessions"] = json!({"codex":{"sessionID":"old-default-native"}});
        store.save(&thread).unwrap();
        (dir, Engine::fixture(store), text(&thread, "id"))
    }
    #[test]
    fn human_confirmed_delete_and_undo_are_owner_bound_and_preserve_native_denials() {
        let (dir, mut engine, id) = fixture();
        let before = engine.store.thread(&id).unwrap();
        engine.set_active_thread(Some(id.clone())).unwrap();
        let plan = engine
            .prepare_native_thread_deletion(std::slice::from_ref(&id))
            .unwrap();
        let undo = engine.apply_native_thread_deletion(plan).unwrap();
        assert!(engine.store.thread(&id).is_err());
        assert!(engine.active_thread().is_none());
        assert!(
            engine.store.save(&before).is_err(),
            "Ordinary saves cannot recreate a deleted UUID"
        );
        let mut other =
            Engine::fixture(Store::open(&dir.path().join("data/state.sqlite")).unwrap());
        assert!(
            other.undo_native_thread_deletion(&undo).is_err(),
            "Another Engine cannot adopt a retained or imported Undo receipt"
        );
        drop(other);
        engine.undo_native_thread_deletion(&undo).unwrap();
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        assert!(
            engine
                .store
                .is_native_session_revoked(&id, "old-default-native")
                .unwrap()
        );
        assert!(
            !engine
                .store
                .is_native_session_revoked(&id, "new-native")
                .unwrap()
        );
        assert!(engine.undo_native_thread_deletion(&undo).is_err());
    }
    #[test]
    fn frozen_closing_persistence_and_draft_import_states_refuse_without_deletion() {
        let (_dir, mut engine, id) = fixture();
        let before = engine.store.thread(&id).unwrap();
        engine.shutdown = true;
        assert!(
            engine
                .prepare_native_thread_deletion(std::slice::from_ref(&id))
                .is_err()
        );
        engine.shutdown = false;
        engine.unsaved_threads.insert(id.clone(), before.clone());
        assert!(
            engine
                .prepare_native_thread_deletion(std::slice::from_ref(&id))
                .is_err()
        );
        engine.unsaved_threads.clear();
        engine.attachment_operations.insert(id.clone());
        assert!(
            engine
                .prepare_native_thread_deletion(std::slice::from_ref(&id))
                .is_err()
        );
        engine.attachment_operations.clear();
        engine
            .workspace_pending
            .insert("synthetic-import".into(), (id.clone(), Instant::now()));
        assert!(
            engine
                .prepare_native_thread_deletion(std::slice::from_ref(&id))
                .is_err()
        );
        engine.workspace_pending.clear();
        let plan = engine
            .prepare_native_thread_deletion(std::slice::from_ref(&id))
            .unwrap();
        engine.freeze_admissions();
        assert!(engine.apply_native_thread_deletion(plan).is_err());
        assert_eq!(engine.store.thread(&id).unwrap(), before);
    }
    #[test]
    fn semantic_finished_never_allows_delete_before_actual_owned_worker_join() {
        let (_dir, mut engine, id) = fixture();
        let (release, held) = std::sync::mpsc::channel();
        let session = Session::fixture_worker(move |_, events| {
            events.send(Event::Finished).unwrap();
            held.recv().unwrap();
        });
        assert!(matches!(
            session
                .events
                .recv_timeout(Duration::from_secs(10))
                .unwrap(),
            Event::Finished
        ));
        let worker = session.worker_completion();
        engine.provider_workers.push(worker.clone());
        assert!(
            engine
                .prepare_native_thread_deletion(std::slice::from_ref(&id))
                .is_err()
        );
        release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while worker.status() == agent::WorkerThreadStatus::Running {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(2));
        }
        let plan = engine
            .prepare_native_thread_deletion(std::slice::from_ref(&id))
            .unwrap();
        assert_eq!(plan.count(), 1);
    }
    #[test]
    fn stale_confirmation_and_targeted_schedules_refuse_but_unrelated_data_stays_exact() {
        let (_dir, mut engine, id) = fixture();
        let plan = engine
            .prepare_native_thread_deletion(std::slice::from_ref(&id))
            .unwrap();
        engine
            .store
            .patch_thread(&id, &json!({"title":"Changed after review"}))
            .unwrap();
        assert!(engine.apply_native_thread_deletion(plan).is_err());
        let tasks = json!({"tasks":[{"id":Uuid::new_v4(),"threadID":id,"isPaused":true,"future":42},{"id":Uuid::new_v4(),"threadID":Uuid::new_v4(),"future":43}]});
        engine
            .store
            .save_document("scheduled-tasks.json", &tasks)
            .unwrap();
        assert!(
            engine
                .prepare_native_thread_deletion(std::slice::from_ref(&id))
                .is_err()
        );
        assert_eq!(
            engine.store.document("scheduled-tasks.json").unwrap(),
            Some(tasks)
        );
        let unrelated =
            json!({"tasks":[{"id":Uuid::new_v4(),"threadID":Uuid::new_v4(),"future":43}]});
        engine
            .store
            .save_document("scheduled-tasks.json", &unrelated)
            .unwrap();
        let plan = engine
            .prepare_native_thread_deletion(std::slice::from_ref(&id))
            .unwrap();
        let _undo = engine.apply_native_thread_deletion(plan).unwrap();
        assert_eq!(
            engine.store.document("scheduled-tasks.json").unwrap(),
            Some(unrelated)
        );
    }
    #[test]
    fn delete_has_no_json_dispatch_or_imported_confirmation_backdoor() {
        let (_dir, mut engine, id) = fixture();
        let before = engine.store.thread(&id).unwrap();
        for method in [
            "threads.delete",
            "threads.delete-all",
            "archive.delete",
            "threadDeletion.apply",
        ] {
            assert!(engine.dispatch(json!({"method":method,"params":{"threadId":id,"confirmed":true,"owner":Uuid::new_v4(),"rows":[before]}})).get("error").is_some());
        }
        assert_eq!(engine.store.thread(&id).unwrap(), before);
    }
    #[test]
    fn undo_denies_each_old_provider_account_session_and_store_errors_fail_closed() {
        let (_dir, mut engine, id) = fixture();
        let providers = [
            "codex",
            "claude",
            "cursor",
            "grok",
            "opencode",
            "antigravity",
        ];
        let mut thread = engine.store.thread(&id).unwrap();
        for provider in providers {
            thread["sessions"][provider] =
                json!({"sessionID":format!("old-{provider}"),"seenItemCount":3});
        }
        thread["accountSessions"] =
            json!({"codex/named-account":{"sessionID":"old-named","seenItemCount":3}});
        engine.store.save(&thread).unwrap();
        let plan = engine
            .prepare_native_thread_deletion(std::slice::from_ref(&id))
            .unwrap();
        let undo = engine.apply_native_thread_deletion(plan).unwrap();
        engine.undo_native_thread_deletion(&undo).unwrap();
        for provider in providers {
            let mut selected = engine.store.thread(&id).unwrap();
            selected["selection"] =
                json!({"provider":provider,"accountID":"default","modelID":"default"});
            assert!(agent::provider_session(&selected, provider).is_some());
            assert_eq!(
                engine
                    .unrevoked_provider_session(&selected, provider)
                    .unwrap(),
                None
            );
        }
        let mut selected = engine.store.thread(&id).unwrap();
        selected["selection"] =
            json!({"provider":"codex","accountID":"named-account","modelID":"default"});
        assert_eq!(
            agent::provider_session(&selected, "codex").as_deref(),
            Some("old-named")
        );
        assert_eq!(
            engine
                .unrevoked_provider_session(&selected, "codex")
                .unwrap(),
            None
        );
        engine.store.close_for_shutdown().unwrap();
        assert!(
            engine
                .unrevoked_provider_session(&selected, "codex")
                .is_err()
        );
    }
}
