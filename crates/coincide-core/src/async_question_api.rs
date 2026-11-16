use super::*;
use crate::composer_follow_up::Behavior;
use crate::message_queue::{self as queue, State};

fn account(value: &Value) -> &str {
    value
        .as_str()
        .filter(|s| !s.is_empty())
        .unwrap_or("default")
}

impl Engine {
    /// The native click creates a durable, session-bound queue entry before
    /// attempting delivery. It never reads or consumes the composer's draft.
    pub fn submit_async_question(
        &mut self,
        id: &str,
        request_id: &str,
        answers: &Value,
    ) -> Result<Option<NativeFollowUpTicket>> {
        self.require_admissions()?;
        ensure!(
            !self.shutdown && !self.unsaved_threads.contains_key(id),
            "Conversation is unavailable"
        );
        let current = self.store.thread(id)?;
        ensure!(
            !self.store.is_imported(id)? && current["isArchived"] != true,
            "Restore or fork this conversation first"
        );
        let requests = current["rustAsyncQuestions"]
            .as_array()
            .context("Question is unavailable")?;
        let mut matches = requests
            .iter()
            .filter(|request| request["requestId"] == request_id);
        let request = matches.next().context("Question is unavailable")?;
        ensure!(
            matches.next().is_none()
                && request["rustAsync"] == true
                && request["status"] == "pending",
            "Question is no longer pending"
        );
        ensure!(
            current["selection"]["provider"] == "codex"
                && account(&current["selection"]["accountID"]) == account(&request["accountID"]),
            "Choose the Codex account that asked this question"
        );
        let native_session = required(request, "nativeSession")?;
        ensure!(
            agent::provider_session(&current, "codex").as_deref() == Some(native_session),
            "This question belongs to a different Codex session"
        );
        let prompt = crate::async_questions::reply(request, answers)?;
        let existing = queue::read(&current)?;
        let unfinished = existing
            .iter()
            .any(|message| matches!(message.state, State::Pending | State::Dispatching));
        let can_enable = self.enabled_queues.contains(id) || !unfinished;
        let mut next = current.clone();
        let mut message = queue::add_payload(&mut next, &prompt, Value::Null, Vec::new())?;
        message.codex_question_session = Some(native_session.to_owned());
        let row = next["rustMessageQueue"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|row| row["id"] == message.id)
            .context("Answer queue entry disappeared")?;
        *row = serde_json::to_value(&message)?;
        let request = next["rustAsyncQuestions"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|request| request["requestId"] == request_id)
            .unwrap();
        request["status"] = json!("submitted");
        request["queueID"] = json!(message.id);
        if let Some(row) = next["items"].as_array_mut().and_then(|items| {
            items.iter_mut().rev().find(|row| {
                row["kind"] == "question"
                    && row["rustAsync"] == true
                    && row["externalID"] == request_id
            })
        }) {
            row["status"] = json!("completed");
            row["answers"] = answers.clone();
        }
        self.store.save_native_follow_up_turn(&current, &next)?;
        if can_enable {
            self.enabled_queues.insert(id.to_owned());
        }
        self.sync_goal_queue_waiting(id);
        self.revision += 1;

        // Never dismiss an unrelated approval or overtake another submission.
        // If immediate steering is unavailable, the durable queue sends later.
        let can_steer = can_enable
            && !unfinished
            && self.active_thread.as_deref() == Some(id)
            && !self.native_follow_up.pending_thread(id)
            && self.native_follow_up.has_capacity()
            && self.runs.get(id).is_some_and(|run| {
                run.provider == "codex"
                    && run.pending.is_empty()
                    && run.session.can_steer()
                    && run
                        .session
                        .steering_identity()
                        .is_ok_and(|(thread, _)| thread == native_session)
                    && run
                        .usage_context
                        .as_ref()
                        .is_some_and(|context| context.matches(&current))
            });
        if can_steer {
            let visible = serde_json::to_value(message)?;
            // Once durable, failure must not make the caller submit it twice.
            return Ok(self
                .native_send_queued_with_behavior(&next, &visible, Some(Behavior::Steer))
                .ok());
        }
        Ok(None)
    }

    pub fn dismiss_async_question(&mut self, id: &str, request_id: &str) -> Result<()> {
        self.require_admissions()?;
        let current = self.store.thread(id)?;
        let mut next = current.clone();
        let request = next["rustAsyncQuestions"]
            .as_array_mut()
            .and_then(|requests| {
                requests.iter_mut().find(|request| {
                    request["requestId"] == request_id
                        && request["rustAsync"] == true
                        && request["status"] == "pending"
                })
            })
            .context("Question is no longer pending")?;
        request["status"] = json!("dismissed");
        if let Some(row) = next["items"].as_array_mut().and_then(|items| {
            items.iter_mut().rev().find(|row| {
                row["kind"] == "question"
                    && row["rustAsync"] == true
                    && row["externalID"] == request_id
            })
        }) {
            row["status"] = json!("declined");
        }
        self.store.save_native_follow_up_turn(&current, &next)?;
        self.revision += 1;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (tempfile::TempDir, Engine, String, String) {
        let directory = tempfile::tempdir().unwrap();
        let mut engine =
            Engine::fixture(Store::open(&directory.path().join("state.sqlite")).unwrap());
        let thread = engine
            .execute("threads.create", &json!({"cwd":directory.path()}))
            .unwrap();
        let id = text(&thread, "id");
        let mut thread = engine.store.thread(&id).unwrap();
        thread["selection"] = json!({"provider":"codex","modelID":"default"});
        thread["draft"] = json!("Independent draft");
        thread["rustDraftImages"] = json!([{"id":"independent"}]);
        thread["draftContext"] = json!([{"type":"future-reference"}]);
        agent::set_provider_session(&mut thread, "codex", "native-session");
        thread["items"] = json!([{"id":Uuid::new_v4().to_string(),"kind":"assistant","text":"Pick","externalID":"question-1"}]);
        let item = json!({"type":"agentMessage","delivery":"async","id":"question-1",
            "questions":[{"title":"Pick one","options":["A","B"]}]});
        assert!(crate::async_questions::observe(
            &mut thread,
            &item,
            "native-session",
            &json!({}),
            0
        ));
        let question_id = text(
            &thread["rustAsyncQuestions"][0]["params"]["questions"][0],
            "id",
        );
        engine.store.save(&thread).unwrap();
        (directory, engine, id, question_id)
    }

    #[test]
    fn answer_is_saved_once_without_touching_the_composer_and_is_session_bound() {
        let (_dir, mut engine, id, question_id) = fixture();
        let before = engine.store.thread(&id).unwrap();
        let answers = json!({question_id:{"answers":["B"]}});
        assert!(
            engine
                .submit_async_question(&id, "question-1", &answers)
                .unwrap()
                .is_none()
        );
        let saved = engine.store.thread(&id).unwrap();
        for key in [
            "draft",
            "draftContext",
            "rustDraftImages",
            "selection",
            "sessions",
        ] {
            assert_eq!(saved[key], before[key], "{key}");
        }
        assert_eq!(saved["rustAsyncQuestions"][0]["status"], "submitted");
        assert_eq!(saved["items"][0]["answers"], answers);
        let queue = queue::read(&saved).unwrap();
        assert_eq!(queue.len(), 1);
        assert_eq!(
            crate::async_questions::display_reply(&queue[0].text).as_deref(),
            Some("B")
        );
        assert_eq!(
            queue[0].codex_question_session.as_deref(),
            Some("native-session")
        );
        assert!(
            engine
                .submit_async_question(&id, "question-1", &answers)
                .is_err()
        );
        let mut changed = saved.clone();
        agent::set_provider_session(&mut changed, "codex", "different-session");
        engine.store.save(&changed).unwrap();
        assert!(engine.claim_next_queue_turn(&id).is_err());
        assert_eq!(
            queue::read(&engine.store.thread(&id).unwrap()).unwrap()[0].state,
            State::Pending
        );
    }

    #[test]
    fn mismatched_account_session_and_invalid_answers_change_nothing() {
        let (_dir, mut engine, id, question_id) = fixture();
        let before = engine.store.thread(&id).unwrap();
        assert!(
            engine
                .submit_async_question(&id, "question-1", &json!({}))
                .is_err()
        );
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        let mut changed = before.clone();
        changed["selection"]["accountID"] = json!("another-account");
        engine.store.save(&changed).unwrap();
        assert!(
            engine
                .submit_async_question(&id, "question-1", &json!({question_id:{"answers":["B"]}}))
                .is_err()
        );
        assert_eq!(engine.store.thread(&id).unwrap(), changed);
    }

    #[test]
    fn dismiss_survives_reload_without_sending() {
        let (_dir, mut engine, id, _) = fixture();
        engine.dismiss_async_question(&id, "question-1").unwrap();
        let saved = engine.store.thread(&id).unwrap();
        assert!(crate::async_questions::pending(&saved).is_empty());
        assert_eq!(saved["items"][0]["status"], "declined");
        assert!(queue::read(&saved).unwrap().is_empty());
        assert!(engine.dismiss_async_question(&id, "question-1").is_err());
    }

    #[test]
    fn removing_an_unsent_answer_restores_the_question() {
        let (_dir, mut engine, id, question_id) = fixture();
        engine
            .submit_async_question(&id, "question-1", &json!({question_id:{"answers":["B"]}}))
            .unwrap();
        let saved = engine.store.thread(&id).unwrap();
        let queue_id = saved["rustMessageQueue"][0]["id"].as_str().unwrap();
        engine
            .execute(
                "agent.queue.remove",
                &json!({"threadId":id,"messageId":queue_id}),
            )
            .unwrap();
        let saved = engine.store.thread(&id).unwrap();
        assert_eq!(crate::async_questions::pending(&saved).len(), 1);
        assert_eq!(saved["items"][0]["status"], "pending");
        assert!(saved["items"][0]["answers"].is_null());
        assert_eq!(saved["draft"], "Independent draft");
    }
}
