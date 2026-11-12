//! Atomic native composer preference writes. Imported originals stay untouched.
use super::*;
pub(crate) struct NativeUncertainty {
    source: std::path::PathBuf,
    identity: crate::private_fs::Identity,
    thread: String,
    account: String,
    native_hash: [u8; 32],
    nonce: String,
}
fn uncertain_account(account: &str) -> Result<String> {
    if account == "default" {
        Ok(account.into())
    } else {
        Ok(Uuid::parse_str(account)?.to_string())
    }
}
fn uncertain_native_hash(native: &str) -> Result<[u8; 32]> {
    use sha2::{Digest, Sha256};
    ensure!(
        !native.is_empty() && native.len() <= 512 && !native.chars().any(char::is_control),
        "Invalid actual native steering identity"
    );
    let mut digest = Sha256::new();
    digest.update(b"Coincide uncertain steering context v1\0");
    digest.update(native.as_bytes());
    Ok(digest.finalize().into())
}
impl Store {
    /// Durable deny-only reservation BEFORE sending into an acknowledged turn.
    /// This token never enters JSON/imports or grants native launch authority.
    pub(crate) fn mark_native_uncertain(
        &mut self,
        thread: &str,
        account: &str,
        native: &str,
    ) -> Result<NativeUncertainty> {
        let source = Path::new(
            self.connection()?
                .path()
                .context("Store has no filesystem identity")?,
        )
        .canonicalize()?;
        let identity = crate::private_fs::identity(&source)?;
        let thread = Uuid::parse_str(thread)?.to_string();
        let account = uncertain_account(account)?;
        let native_hash = uncertain_native_hash(native)?;
        let nonce = Uuid::new_v4().to_string();
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        tx.execute_batch("CREATE TABLE IF NOT EXISTS uncertain_native_sessions(thread_id TEXT NOT NULL COLLATE NOCASE,account TEXT NOT NULL,native_hash BLOB NOT NULL,nonce TEXT NOT NULL,PRIMARY KEY(thread_id,account,native_hash));")?;
        let inserted=tx.execute("INSERT OR IGNORE INTO uncertain_native_sessions(thread_id,account,native_hash,nonce) VALUES (?1,?2,?3,?4)",params![thread,account,native_hash.as_slice(),nonce])?;
        ensure!(
            inserted == 1,
            "This native context already has an uncertain delivery; start a fresh turn"
        );
        tx.commit()?;
        Ok(NativeUncertainty {
            source,
            identity,
            thread,
            account,
            native_hash,
            nonce,
        })
    }
    pub(crate) fn clear_native_uncertainty(&mut self, token: &NativeUncertainty) -> Result<()> {
        let source = Path::new(
            self.connection()?
                .path()
                .context("Store has no filesystem identity")?,
        )
        .canonicalize()?;
        ensure!(
            source == token.source && crate::private_fs::identity(&source)? == token.identity,
            "Uncertainty receipt belongs to another Store"
        );
        let removed=self.connection_mut()?.execute("DELETE FROM uncertain_native_sessions WHERE thread_id=?1 AND account=?2 AND native_hash=?3 AND nonce=?4",params![token.thread,token.account,token.native_hash.as_slice(),token.nonce])?;
        ensure!(
            removed == 1,
            "Uncertainty receipt changed; context stays unavailable"
        );
        Ok(())
    }
    pub(crate) fn is_native_session_uncertain(
        &self,
        thread: &str,
        account: &str,
        native: &str,
    ) -> Result<bool> {
        let exists:bool=self.connection()?.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='uncertain_native_sessions')",[],|row|row.get(0))?;
        if !exists {
            return Ok(false);
        }
        let thread = Uuid::parse_str(thread)?.to_string();
        let account = uncertain_account(account)?;
        let native_hash = uncertain_native_hash(native)?;
        Ok(self.connection()?.query_row("SELECT EXISTS(SELECT 1 FROM uncertain_native_sessions WHERE thread_id=?1 AND account=?2 AND native_hash=?3)",params![thread,account,native_hash.as_slice()],|row|row.get(0))?)
    }
    pub(crate) fn save_native_follow_up_turn(
        &mut self,
        expected: &Value,
        next: &Value,
    ) -> Result<()> {
        self.save_with_usage_and_settings(next, None, None, Some(expected))
    }
    pub(crate) fn queue_native_follow_up(
        &mut self,
        expected: &Value,
        text: &str,
        enabled: bool,
    ) -> Result<bool> {
        use crate::message_queue::{self as queue, State};
        let id = expected["id"]
            .as_str()
            .context("Missing queue thread identity")?;
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure_not_deleted(&tx, id)?;
        let raw: String =
            tx.query_row("SELECT document FROM threads WHERE id=?1", [id], |row| {
                row.get(0)
            })?;
        let mut current: Value = serde_json::from_str(&raw)?;
        ensure!(
            &current == expected,
            "Composer changed before queue admission; draft retained"
        );
        ensure!(
            !tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1)",
                [id],
                |row| row.get::<_, bool>(0)
            )?,
            "Fork an imported conversation before queueing"
        );
        let existing = queue::read(&current)?;
        let can_enable = existing
            .iter()
            .all(|message| message.state != State::Dispatching)
            && (enabled
                || existing
                    .iter()
                    .all(|message| message.state != State::Pending));
        let context = current["draftContext"].clone();
        let images = if current["rustDraftImages"].is_null() {
            Vec::new()
        } else {
            serde_json::from_value(current["rustDraftImages"].clone())
                .context("Invalid draft image metadata")?
        };
        queue::add_payload(&mut current, text, context, images)?;
        current["rustQueueError"] = Value::Null;
        current["draft"] = json!("");
        current["rustDraftImages"] = json!([]);
        current.as_object_mut().unwrap().remove("draftContext");
        tx.execute(
            "UPDATE threads SET document=?2 WHERE id=?1",
            params![id, current.to_string()],
        )?;
        cache_thread(&tx, &current, false)?;
        tx.commit()?;
        self.note_selection_scope(&current);
        Ok(can_enable)
    }
    pub(crate) fn clear_native_follow_up_draft(
        &mut self,
        expected_scope: &Value,
        expected_revision: Option<&[u8]>,
    ) -> Result<bool> {
        let id = expected_scope["id"]
            .as_str()
            .context("Missing native draft identity")?;
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure_not_deleted(&tx, id)?;
        let raw: String =
            tx.query_row("SELECT document FROM threads WHERE id=?1", [id], |row| {
                row.get(0)
            })?;
        let mut current: Value = serde_json::from_str(&raw)?;
        ensure!(
            !tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1)",
                [id],
                |row| row.get::<_, bool>(0)
            )?,
            "Imported conversation is read-only"
        );
        let revision = draft_revision(&tx, id)?;
        // Settings, context or images can change while the provider is
        // acknowledging a message. They must not resurrect its text, but a
        // later draft write (even an identical retype) belongs to the user.
        let clear_text =
            revision.as_deref() == expected_revision && current["draft"] == expected_scope["draft"];
        let before = current.clone();
        if clear_text {
            current["draft"] = json!("");
            if current["draftContext"] == expected_scope["draftContext"] {
                current.as_object_mut().unwrap().remove("draftContext");
            }
        }
        let submitted = expected_scope["rustDraftImages"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        if let Some(images) = current
            .get_mut("rustDraftImages")
            .and_then(Value::as_array_mut)
        {
            images.retain(|image| !submitted.contains(image));
        }
        if current == before {
            return Ok(clear_text);
        }
        tx.execute(
            "UPDATE threads SET document=?2 WHERE id=?1",
            params![id, current.to_string()],
        )?;
        cache_thread(&tx, &current, false)?;
        tx.commit()?;
        self.note_selection_scope(&current);
        Ok(clear_text)
    }
    pub(crate) fn choose_follow_up(
        &mut self,
        expected: &Value,
        behavior: crate::composer_follow_up::Behavior,
    ) -> Result<Value> {
        let id = expected["id"].as_str().context("Missing thread identity")?;
        ensure!(
            !self.is_imported(id)?,
            "Fork an imported conversation before changing its composer"
        );
        let expected_settings = self.document("settings.json")?;
        let mut settings = expected_settings.clone().unwrap_or_else(|| json!({}));
        let settings_object = settings
            .as_object_mut()
            .context("Settings must be an object")?;
        let prior = settings_object
            .get("followUpBehavior")
            .and_then(crate::composer_follow_up::Behavior::parse)
            .unwrap_or(crate::composer_follow_up::Behavior::Steer);
        settings_object
            .entry("existingThreadsFollowUpBehavior".to_owned())
            .or_insert_with(|| json!(prior.key()));
        settings_object.insert("followUpBehavior".into(), json!(behavior.key()));
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let local: Option<String> = tx
            .query_row(
                "SELECT document FROM documents WHERE name='settings.json'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        let actual_settings: Option<Value> = if let Some(local) = local {
            Some(serde_json::from_str(&local)?)
        } else {
            let original: Option<Vec<u8>> = tx
                .query_row(
                    "SELECT data FROM original_files WHERE path='settings.json'",
                    [],
                    |row| row.get(0),
                )
                .optional()?;
            original
                .as_deref()
                .map(serde_json::from_slice)
                .transpose()?
        };
        ensure!(
            actual_settings == expected_settings,
            "Settings changed; reload before choosing follow-up behavior"
        );
        ensure!(
            !tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1)",
                [id],
                |row| row.get::<_, bool>(0)
            )?,
            "Imported conversation is read-only"
        );
        let raw: String =
            tx.query_row("SELECT document FROM threads WHERE id=?1", [id], |row| {
                row.get(0)
            })?;
        let mut thread: Value = serde_json::from_str(&raw)?;
        ensure!(
            &thread == expected,
            "Composer changed; reload before choosing follow-up behavior"
        );
        thread["followUpBehavior"] = json!(behavior.key());
        tx.execute(
            "UPDATE threads SET document=?2 WHERE id=?1",
            params![id, thread.to_string()],
        )?;
        cache_thread(&tx, &thread, false)?;
        tx.execute("INSERT INTO documents(name,document) VALUES ('settings.json',?1) ON CONFLICT(name) DO UPDATE SET document=excluded.document", [settings.to_string()])?;
        tx.commit()?;
        self.note_selection_scope(&thread);
        Ok(thread)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::composer_follow_up::{self as choice, Behavior};
    #[test]
    fn native_choice_is_atomic_preserves_unknown_fields_and_freezes_existing_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("state.sqlite")).unwrap();
        let original_settings = json!({"followUpBehavior":"queue","unknown":{"keep":[1,2]}});
        let original_raw =
            br#"{ "followUpBehavior": "queue", "unknown": {"keep":[1,2]} }"#.to_vec();
        store
            .connection()
            .unwrap()
            .execute(
                "INSERT INTO original_files(path,data) VALUES ('settings.json',?1)",
                [&original_raw],
            )
            .unwrap();
        let mut first = store.new_thread("").unwrap();
        first.as_object_mut().unwrap().remove("followUpBehavior");
        first["unknown"] = json!({"opaque":true});
        first["draft"] = json!("retained");
        store.save(&first).unwrap();
        let mut other = store.new_thread("").unwrap();
        other.as_object_mut().unwrap().remove("followUpBehavior");
        store.save(&other).unwrap();
        let saved = store.choose_follow_up(&first, Behavior::Interrupt).unwrap();
        let mut expected = first.clone();
        expected["followUpBehavior"] = json!("interrupt");
        assert_eq!(saved, expected);
        assert_eq!(
            store.original("settings.json").unwrap().unwrap(),
            original_raw
        );
        let settings = store.document("settings.json").unwrap().unwrap();
        assert_eq!(settings["unknown"], original_settings["unknown"]);
        assert_eq!(choice::selected(&other, &settings), Behavior::Queue);
        assert_eq!(
            store.new_thread("").unwrap()["followUpBehavior"],
            "interrupt"
        );
        assert!(store.choose_follow_up(&first, Behavior::Steer).is_err());
        assert_eq!(store.thread(text(&saved, "id").as_str()).unwrap(), saved);
        assert_eq!(store.document("settings.json").unwrap().unwrap(), settings);
        store.connection().unwrap().execute_batch("CREATE TRIGGER reject_follow_up BEFORE UPDATE ON documents BEGIN SELECT RAISE(ABORT,'synthetic rollback'); END;").unwrap();
        assert!(store.choose_follow_up(&saved, Behavior::Queue).is_err());
        assert_eq!(store.thread(text(&saved, "id").as_str()).unwrap(), saved);
        assert_eq!(store.document("settings.json").unwrap().unwrap(), settings);
    }
    #[test]
    fn independent_store_edits_cannot_be_cleared_or_queued_by_a_stale_native_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.sqlite");
        let mut store = Store::open(&path).unwrap();
        let mut source = store.new_thread("").unwrap();
        let id = text(&source, "id");
        source["draft"] = json!("original synthetic draft");
        store.save(&source).unwrap();
        let (_, revision) = store.thread_with_draft_revision(&id).unwrap();
        let mut other = Store::open(&path).unwrap();
        let edited = other
            .patch_thread(&id, &json!({"draft":"newer independent draft"}))
            .unwrap();
        assert!(
            store
                .queue_native_follow_up(&source, "original synthetic draft", false)
                .is_err()
        );
        assert!(
            !store
                .clear_native_follow_up_draft(&source, revision.as_deref())
                .unwrap()
        );
        let mut turn = source.clone();
        turn["draft"] = json!("");
        turn["items"] =
            json!([{"id":"synthetic-item","kind":"user","text":"original synthetic draft"}]);
        assert!(store.save_native_follow_up_turn(&source, &turn).is_err());
        assert_eq!(store.thread(&id).unwrap(), edited);
        assert!(store.thread(&id).unwrap()["rustMessageQueue"].is_null());
        assert!(
            store
                .queue_native_follow_up(&edited, "newer independent draft", false)
                .unwrap()
        );
        let queued = other.thread(&id).unwrap();
        assert_eq!(queued["draft"], "");
        assert_eq!(crate::message_queue::read(&queued).unwrap().len(), 1);
    }
    #[test]
    fn acknowledged_images_are_removed_without_losing_the_new_draft() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("state.sqlite")).unwrap();
        let mut original = store.new_thread("").unwrap();
        let id = text(&original, "id");
        let submitted = json!({"id":"image-a", "originalName":"a.png"});
        let newer = json!({"id":"image-b", "originalName":"b.png"});
        let changed = json!({"id":"image-a", "originalName":"changed.png"});
        original["draft"] = json!("sent");
        original["rustDraftImages"] = json!([submitted]);
        store.save(&original).unwrap();
        let (_, revision) = store.thread_with_draft_revision(&id).unwrap();

        let mut edited = original.clone();
        edited["draft"] = json!("next message");
        edited["rustDraftImages"] = json!([submitted, newer, changed]);
        edited["draftContext"] = json!({"keep":true});
        store.save(&edited).unwrap();
        assert!(
            !store
                .clear_native_follow_up_draft(&original, revision.as_deref())
                .unwrap()
        );
        let actual = store.thread(&id).unwrap();
        assert_eq!(actual["draft"], "next message");
        assert_eq!(actual["draftContext"], edited["draftContext"]);
        assert_eq!(actual["rustDraftImages"], json!([newer, changed]));
    }

    #[test]
    fn acknowledged_text_clears_across_context_changes_but_not_a_retyped_draft() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.sqlite");
        let mut store = Store::open(&path).unwrap();
        let mut original = store.new_thread("").unwrap();
        let id = text(&original, "id");
        original["draft"] = json!("submitted");
        original["rustDraftImages"] = json!([{"id":"first"}]);
        store.save(&original).unwrap();
        let (_, revision) = store.thread_with_draft_revision(&id).unwrap();

        let mut other = Store::open(&path).unwrap();
        let mut next = other.thread(&id).unwrap();
        next["draftContext"] = json!([{"id":"new-context"}]);
        next["rustDraftImages"] = json!([{"id":"first"}, {"id":"next"}]);
        next["selection"]["modelID"] = json!("different-model");
        other.save(&next).unwrap();
        assert!(
            store
                .clear_native_follow_up_draft(&original, revision.as_deref())
                .unwrap()
        );
        let saved = other.thread(&id).unwrap();
        assert_eq!(saved["draft"], "");
        assert_eq!(saved["draftContext"], next["draftContext"]);
        assert_eq!(saved["rustDraftImages"], json!([{"id":"next"}]));
        assert_eq!(saved["selection"], next["selection"]);

        other.patch_draft(&id, "submitted").unwrap();
        let (submitted, revision) = store.thread_with_draft_revision(&id).unwrap();
        // This explicit write can be a deliberate retype of the same text.
        other.patch_draft(&id, "submitted").unwrap();
        assert!(
            !store
                .clear_native_follow_up_draft(&submitted, revision.as_deref())
                .unwrap()
        );
        assert_eq!(other.thread(&id).unwrap()["draft"], "submitted");
    }
    #[test]
    fn uncertainty_is_account_scoped_durable_and_old_nonce_cannot_clear_a_new_reservation() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.sqlite");
        let mut store = Store::open(&path).unwrap();
        let id = Uuid::new_v4().to_string();
        let a = Uuid::new_v4().to_string();
        let b = Uuid::new_v4().to_string();
        let old = store
            .mark_native_uncertain(&id, &a, "synthetic-private-native")
            .unwrap();
        assert!(
            store
                .is_native_session_uncertain(&id, &a, "synthetic-private-native")
                .unwrap()
        );
        assert!(
            !store
                .is_native_session_uncertain(&id, &b, "synthetic-private-native")
                .unwrap()
        );
        assert!(
            store
                .mark_native_uncertain(&id, &a, "synthetic-private-native")
                .is_err()
        );
        let mut other = Store::open(&dir.path().join("other.sqlite")).unwrap();
        assert!(other.clear_native_uncertainty(&old).is_err());
        store.clear_native_uncertainty(&old).unwrap();
        let _current = store
            .mark_native_uncertain(&id, &a, "synthetic-private-native")
            .unwrap();
        assert!(store.clear_native_uncertainty(&old).is_err());
        drop(store);
        let store = Store::open(&path).unwrap();
        assert!(
            store
                .is_native_session_uncertain(&id, &a, "synthetic-private-native")
                .unwrap()
        );
        assert!(
            !store
                .is_native_session_uncertain(&id, &b, "synthetic-private-native")
                .unwrap()
        );
    }
}
