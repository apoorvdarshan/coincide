//! The sole queued send origin. An opaque claim is issued only after its exact
//! pending row becomes durably dispatching. No JSON field constructs this type.
use super::*;
use crate::message_queue::{self as queue, State};
pub(super) struct QueueClaim {
    owner: Uuid,
    thread: String,
    message: queue::Message,
    source: Value,
}
impl QueueClaim {
    pub(super) fn text(&self) -> &str {
        &self.message.text
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
}
