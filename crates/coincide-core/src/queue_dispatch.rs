//! The sole queued send origin. An opaque claim is issued only after its exact
//! pending row becomes durably dispatching. No JSON field constructs this type.
use super::*;
use crate::message_queue::{self as queue, State};
pub(super) struct QueueClaim {
    owner: Uuid,
    thread: String,
    message: queue::Message,
    source: Value,
    native_now: bool,
}
impl QueueClaim {
    pub(super) fn text(&self) -> &str {
        &self.message.text
    }
    pub(super) fn context(&self) -> &Value {
        &self.message.context
    }
    pub(super) fn images(&self) -> &[crate::attachments::StoredImage] {
        &self.message.images
    }
    pub(super) fn id(&self) -> &str {
        &self.message.id
    }
    pub(super) fn validate(
        &self,
        owner: Uuid,
        id: &str,
        prompt: &str,
        thread: &Value,
    ) -> Result<()> {
        ensure!(
            owner == self.owner
                && id == self.thread
                && prompt == self.message.text
                && *thread == self.source,
            "Queued dispatch claim or conversation changed"
        );
        let messages = queue::read(thread)?;
        let mut matches = messages
            .iter()
            .filter(|message| message.id == self.message.id);
        let actual = matches
            .next()
            .context("Queued dispatch claim disappeared")?;
        ensure!(
            matches.next().is_none()
                && actual.state == State::Dispatching
                && actual.selection == thread["selection"]
                && actual.selection == self.message.selection
                && actual.text == prompt,
            "Queued dispatch claim is no longer current"
        );
        Ok(())
    }
}
impl QueueClaim {
    pub(super) fn permits_fresh_replacement(&self) -> bool {
        self.native_now
    }
    fn exact_row<'a>(&self, thread: &'a Value) -> Result<&'a Value> {
        let rows = thread["rustMessageQueue"]
            .as_array()
            .context("Queued messages are unavailable")?;
        let mut found = rows.iter().filter(|row| row["id"] == self.message.id);
        let row = found.next().context("Queued message disappeared")?;
        ensure!(
            found.next().is_none(),
            "Queued message identity is ambiguous"
        );
        let expected = self.source["rustMessageQueue"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["id"] == self.message.id))
            .context("Missing owned queue row")?;
        ensure!(
            row == expected,
            "Queued message changed after Send now admission"
        );
        Ok(row)
    }
    pub(super) fn rebound(&self, owner: Uuid, current: &Value) -> Result<Self> {
        ensure!(
            self.native_now && owner == self.owner,
            "Queue replacement is not owned by this native action"
        );
        self.exact_row(current)?;
        for key in [
            "id",
            "projectID",
            "projectPath",
            "worktreePath",
            "botID",
            "rustBotContext",
            "selection",
            "accessMode",
            "interactionMode",
        ] {
            ensure!(
                current.get(key) == self.source.get(key),
                "Queued execution context changed; message retained"
            );
        }
        Ok(Self {
            owner: self.owner,
            thread: self.thread.clone(),
            message: self.message.clone(),
            source: current.clone(),
            native_now: true,
        })
    }
}

impl Engine {
    pub(super) fn claim_next_queue_turn(&mut self, id: &str) -> Result<Option<QueueClaim>> {
        self.require_admissions()?;
        ensure!(self.enabled_queues.contains(id), "Queue is paused");
        ensure!(
            !self.runs.contains_key(id)
                && !self.unsaved_threads.contains_key(id)
                && !self.native_follow_up.pending_thread(id),
            "Queued conversation is busy"
        );
        let source = self.store.thread(id)?;
        ensure!(
            !self.store.is_imported(id)? && source["isArchived"] != true,
            "Queued thread is unavailable"
        );
        let messages = queue::read(&source)?;
        let mut ids = HashSet::new();
        for message in &messages {
            ensure!(
                ids.insert(Uuid::parse_str(&message.id)?),
                "Queue message identity is ambiguous"
            );
        }
        ensure!(
            !messages
                .iter()
                .any(|message| message.state == State::Dispatching),
            "Queue has an unconfirmed dispatch; resume it explicitly"
        );
        let Some(index) = messages
            .iter()
            .position(|message| message.state == State::Pending)
        else {
            return Ok(None);
        };
        ensure!(
            messages[index].selection == source["selection"],
            "Provider selection changed; remove and requeue this message"
        );
        let mut target = source.clone();
        let row = target["rustMessageQueue"]
            .as_array_mut()
            .context("Queued messages are malformed")?
            .get_mut(index)
            .context("Queued message disappeared")?;
        row["state"] = json!("dispatching");
        if let Some(row) = row.as_object_mut() {
            row.remove("error");
        }
        self.store.save_native_follow_up_turn(&source, &target)?;
        self.revision += 1;
        let mut message = messages[index].clone();
        message.state = State::Dispatching;
        message.error = None;
        Ok(Some(QueueClaim {
            owner: self.thread_bulk_owner,
            native_now: false,
            thread: id.into(),
            message,
            source: target,
        }))
    }
    pub(super) fn fail_queue_claim(&mut self, claim: &QueueClaim, error: &str) -> Result<()> {
        let source = self.store.thread(&claim.thread)?;
        let mut target = source.clone();
        let messages = queue::read(&source)?;
        let matching = messages
            .iter()
            .filter(|message| message.id == claim.message.id)
            .collect::<Vec<_>>();
        ensure!(
            matching.len() == 1
                && matching[0].selection == claim.message.selection
                && matching[0].text == claim.message.text,
            "Queued claim changed while dispatch was refused"
        );
        let expected = claim.source["rustMessageQueue"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["id"] == claim.message.id));
        let actual = source["rustMessageQueue"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["id"] == claim.message.id));
        ensure!(
            expected == actual,
            "Queued claim metadata changed while dispatch was refused"
        );
        queue::finish(&mut target, &claim.message.id, State::Failed, Some(error))?;
        self.store.save_native_follow_up_turn(&source, &target)?;
        self.revision += 1;
        Ok(())
    }
}

impl Engine {
    pub(super) fn claim_native_queue_now(
        &mut self,
        expected: &Value,
        visible: &Value,
    ) -> Result<QueueClaim> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let id = required(expected, "id")?;
        ensure!(
            self.active_thread.as_deref() == Some(id)
                && !self.unsaved_threads.contains_key(id)
                && !self.native_follow_up.pending_thread(id)
                && self.native_follow_up.has_capacity(),
            "Conversation changed or another native delivery is pending"
        );
        let source = self.store.thread(id)?;
        ensure!(
            !self.store.is_imported(id)? && source["isArchived"] != true,
            "Restore or fork this conversation first"
        );
        ensure!(
            source["rustMessageQueue"] == expected["rustMessageQueue"]
                && source["selection"] == expected["selection"],
            "Visible queue or provider changed; refresh before sending"
        );
        for key in [
            "projectID",
            "projectPath",
            "worktreePath",
            "botID",
            "rustBotContext",
            "accessMode",
            "interactionMode",
        ] {
            ensure!(
                source.get(key) == expected.get(key),
                "Visible queued execution context changed"
            );
        }
        let messages = queue::read(&source)?;
        let mut ids = HashSet::new();
        for message in &messages {
            ensure!(
                ids.insert(Uuid::parse_str(&message.id)?),
                "Queue message identity is ambiguous"
            );
        }
        ensure!(
            !messages
                .iter()
                .any(|message| message.state == State::Dispatching),
            "Queue has an unconfirmed dispatch; resume explicitly first"
        );
        let id_message = required(visible, "id")?;
        let mut matches = messages
            .iter()
            .enumerate()
            .filter(|(_, message)| message.id == id_message);
        let (index, message) = matches.next().context("Queued message disappeared")?;
        ensure!(
            matches.next().is_none()
                && message.state == State::Pending
                && message.selection == source["selection"],
            "Only the exact pending message can be sent now"
        );
        ensure!(
            serde_json::to_value(message)? == *visible,
            "Visible queue message changed"
        );
        let mut target = source.clone();
        let row = target["rustMessageQueue"]
            .as_array_mut()
            .unwrap()
            .get_mut(index)
            .unwrap();
        row["state"] = json!("dispatching");
        row.as_object_mut().unwrap().remove("error");
        self.store.save_native_follow_up_turn(&source, &target)?;
        self.revision += 1;
        let mut message = message.clone();
        message.state = State::Dispatching;
        message.error = None;
        Ok(QueueClaim {
            owner: self.thread_bulk_owner,
            thread: id.into(),
            message,
            source: target,
            native_now: true,
        })
    }
    pub(super) fn complete_native_queue_steer(&mut self, claim: &QueueClaim) -> Result<()> {
        ensure!(
            claim.native_now && claim.owner == self.thread_bulk_owner,
            "Queued steering belongs to another native owner"
        );
        let source = self.store.thread(&claim.thread)?;
        claim.exact_row(&source)?;
        let mut target = source.clone();
        queue::finish(&mut target, claim.id(), State::Completed, None)?;
        self.store.save_native_follow_up_turn(&source, &target)?;
        self.revision += 1;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Engine, String) {
        let directory = tempfile::tempdir().unwrap();
        let mut store = Store::open(&directory.path().join("state.sqlite")).unwrap();
        let mut thread = store.new_thread("").unwrap();
        let id = text(&thread, "id");
        thread["selection"] =
            json!({"provider":"codex","modelID":"synthetic-model","accountID":Uuid::new_v4()});
        queue::add(&mut thread, "synthetic queued text").unwrap();
        thread["draft"] = json!("unrelated unsent draft");
        thread["draftContext"] = json!([{"future":"retained opaque draft context"}]);
        thread["rustDraftImages"] = json!([{"future":"retained unopened image"}]);
        thread["rustMessageQueue"][0]["future"] = json!({"keep":1});
        store.save(&thread).unwrap();
        let mut engine = Engine::fixture(store);
        engine.enabled_queues.insert(id.clone());
        (directory, engine, id)
    }
    #[test]
    fn durable_claim_is_exact_engine_thread_text_selection_and_source_bound() {
        let (_directory, mut engine, id) = fixture();
        let original = engine.store.thread(&id).unwrap();
        let claim = engine.claim_next_queue_turn(&id).unwrap().unwrap();
        let saved = engine.store.thread(&id).unwrap();
        assert_eq!(saved["rustMessageQueue"][0]["state"], "dispatching");
        assert_eq!(
            saved["rustMessageQueue"][0]["future"],
            original["rustMessageQueue"][0]["future"]
        );
        for key in ["draft", "draftContext", "rustDraftImages", "selection"] {
            assert_eq!(saved[key], original[key]);
        }
        assert!(
            claim
                .validate(engine.thread_bulk_owner, &id, claim.text(), &saved)
                .is_ok()
        );
        assert!(
            claim
                .validate(Uuid::new_v4(), &id, claim.text(), &saved)
                .is_err()
        );
        assert!(
            claim
                .validate(
                    engine.thread_bulk_owner,
                    "other-thread",
                    claim.text(),
                    &saved
                )
                .is_err()
        );
        assert!(
            claim
                .validate(engine.thread_bulk_owner, &id, "injected text", &saved)
                .is_err()
        );
        let mut changed = saved.clone();
        changed["draft"] = json!("changed while claiming");
        assert!(
            claim
                .validate(engine.thread_bulk_owner, &id, claim.text(), &changed)
                .is_err()
        );
        assert!(
            engine.claim_next_queue_turn(&id).is_err(),
            "dispatching claims cannot be reissued"
        );
    }
    #[test]
    fn failed_admission_retains_latest_unrelated_draft_and_all_raw_queue_metadata() {
        let (_directory, mut engine, id) = fixture();
        let claim = engine.claim_next_queue_turn(&id).unwrap().unwrap();
        let mut newer = engine.store.thread(&id).unwrap();
        newer["draft"] = json!("new unrelated draft");
        newer["future"] = json!(7);
        engine.store.save(&newer).unwrap();
        engine
            .fail_queue_claim(&claim, "synthetic preflight denial")
            .unwrap();
        let saved = engine.store.thread(&id).unwrap();
        assert_eq!(saved["draft"], "new unrelated draft");
        assert_eq!(saved["future"], 7);
        assert_eq!(saved["rustMessageQueue"][0]["future"], json!({"keep":1}));
        assert_eq!(saved["rustMessageQueue"][0]["state"], "failed");
        assert_eq!(
            saved["rustMessageQueue"][0]["error"],
            "synthetic preflight denial"
        );
        assert!(engine.runs.is_empty());
    }
    #[test]
    fn changed_selected_claim_is_never_failed_or_rewritten_as_an_old_attempt() {
        let (_directory, mut engine, id) = fixture();
        let claim = engine.claim_next_queue_turn(&id).unwrap().unwrap();
        let mut current = engine.store.thread(&id).unwrap();
        current["rustMessageQueue"][0]["future"] = json!({"replacement":2});
        engine.store.save(&current).unwrap();
        assert!(engine.fail_queue_claim(&claim, "old denial").is_err());
        assert_eq!(engine.store.thread(&id).unwrap(), current);
    }
    #[test]
    fn mismatched_selection_duplicate_identity_frozen_and_paused_never_issue_claims() {
        for change in ["selection", "duplicate", "freeze", "pause"] {
            let (_directory, mut engine, id) = fixture();
            let mut current = engine.store.thread(&id).unwrap();
            match change {
                "selection" => current["selection"]["accountID"] = json!(Uuid::new_v4()),
                "duplicate" => {
                    let duplicate = current["rustMessageQueue"][0].clone();
                    current["rustMessageQueue"]
                        .as_array_mut()
                        .unwrap()
                        .push(duplicate);
                }
                "freeze" => engine.freeze_admissions(),
                _ => {
                    engine.enabled_queues.remove(&id);
                }
            }
            engine.store.save(&current).unwrap();
            let changes = engine.store.mutation_serial().unwrap();
            assert!(engine.claim_next_queue_turn(&id).is_err(), "{change}");
            assert_eq!(engine.store.thread(&id).unwrap(), current);
            assert_eq!(engine.store.mutation_serial().unwrap(), changes);
        }
    }
    #[test]
    fn caller_json_flags_cannot_construct_owned_queue_or_schedule_origin() {
        let (_directory, mut engine, id) = fixture();
        engine.enabled_queues.remove(&id);
        let before = engine.store.thread(&id).unwrap();
        let reply=engine.dispatch(json!({"method":"agent.send","params":{"threadId":id,"text":"injected","queued":true,"scheduled":true,"origin":"queued","queueClaim":before["rustMessageQueue"][0]["id"]}}));
        assert!(reply.get("error").is_some());
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        assert!(engine.runs.is_empty());
    }
    #[test]
    fn send_now_claim_preserves_paused_queue_and_unrelated_draft_and_requires_exact_row() {
        let (_directory, mut engine, id) = fixture();
        engine.active_thread = Some(id.clone());
        engine.enabled_queues.remove(&id);
        let source = engine.store.thread(&id).unwrap();
        let visible = serde_json::to_value(&queue::read(&source).unwrap()[0]).unwrap();
        let claim = engine.claim_native_queue_now(&source, &visible).unwrap();
        assert!(claim.permits_fresh_replacement());
        assert!(!engine.enabled_queues.contains(&id));
        let saved = engine.store.thread(&id).unwrap();
        for field in ["draft", "draftContext", "rustDraftImages"] {
            assert_eq!(saved[field], source[field]);
        }
        let mut newer = saved.clone();
        newer["draft"] = json!("typed while the old worker returns");
        newer["items"]
            .as_array_mut()
            .unwrap()
            .push(json!({"kind":"assistant","text":"completed old turn"}));
        let rebound = claim.rebound(engine.thread_bulk_owner, &newer).unwrap();
        rebound
            .validate(engine.thread_bulk_owner, &id, claim.text(), &newer)
            .unwrap();
        newer["rustMessageQueue"][0]["future"] = json!({"replaced":true});
        assert!(claim.rebound(engine.thread_bulk_owner, &newer).is_err());
        assert!(claim.rebound(Uuid::new_v4(), &saved).is_err());
        let mut changed_policy = saved.clone();
        changed_policy["accessMode"] = json!("changed-policy");
        assert!(
            claim
                .rebound(engine.thread_bulk_owner, &changed_policy)
                .is_err()
        );
    }
    #[test]
    fn send_now_rejects_stale_duplicate_inactive_and_existing_uncertain_claim_without_writes() {
        for change in ["stale", "duplicate", "inactive", "uncertain"] {
            let (_directory, mut engine, id) = fixture();
            engine.active_thread = Some(id.clone());
            let expected = engine.store.thread(&id).unwrap();
            let visible = serde_json::to_value(&queue::read(&expected).unwrap()[0]).unwrap();
            let mut current = expected.clone();
            match change {
                "stale" => current["rustMessageQueue"][0]["text"] = json!("changed text"),
                "duplicate" => {
                    let duplicate = current["rustMessageQueue"][0].clone();
                    current["rustMessageQueue"]
                        .as_array_mut()
                        .unwrap()
                        .push(duplicate);
                }
                "inactive" => engine.active_thread = None,
                _ => current["rustMessageQueue"][0]["state"] = json!("dispatching"),
            }
            engine.store.save(&current).unwrap();
            let serial = engine.store.mutation_serial().unwrap();
            assert!(
                engine.claim_native_queue_now(&expected, &visible).is_err(),
                "{change}"
            );
            assert_eq!(engine.store.thread(&id).unwrap(), current);
            assert_eq!(engine.store.mutation_serial().unwrap(), serial);
            assert!(engine.runs.is_empty());
        }
    }
}
