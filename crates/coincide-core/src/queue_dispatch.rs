//! The sole queued send origin. An opaque claim is issued only after its exact
//! pending row becomes durably dispatching. No JSON field constructs this type.
use super::*;
use crate::message_queue::{self as queue, State};
fn validate_question_session(message: &queue::Message, thread: &Value) -> Result<()> {
    if let Some(session) = &message.codex_question_session {
        ensure!(
            thread["selection"]["provider"] == "codex"
                && agent::provider_session(thread, "codex").as_deref() == Some(session),
            "The question belongs to a different Codex session; the answer was retained"
        );
    }
    Ok(())
}
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
    pub(super) fn captured_scope(&self) -> Value {
        crate::composer_follow_up::scope(&self.source)
    }
    pub(super) fn presents_immediately(&self) -> bool {
        self.message.native_immediate
    }
    pub(super) fn question_session(&self) -> Option<&str> {
        self.message.codex_question_session.as_deref()
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
        validate_question_session(actual, thread)?;
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

fn needs_default_codex_catalog(thread: &Value) -> bool {
    let selection = &thread["selection"];
    selection["provider"] == "codex"
        && crate::composer_selection::default_account(&selection["accountID"])
        && thread["botID"].is_null()
        && thread["rustBotContext"].is_null()
        && (!selection["effort"].is_null()
            || !selection["speed"].is_null()
            || crate::model_catalog::astra_default_needed(selection))
}

impl Engine {
    /// A queued turn must not be claimed and failed merely because the
    /// in-memory default Codex catalog is still starting after a restart.
    /// Discovery runs in its own worker and is shared across waiting queues.
    pub(super) fn queue_waits_for_codex_catalog(&mut self, thread: &Value) -> bool {
        let selection = &thread["selection"];
        let Ok(messages) = queue::read(thread) else {
            return false;
        };
        if messages
            .iter()
            .any(|message| message.state == State::Dispatching)
            || messages
                .iter()
                .find(|message| message.state == State::Pending)
                .is_none_or(|message| message.selection != *selection)
        {
            return false;
        }
        self.waits_for_default_codex_catalog(thread)
    }

    /// Only an unchanged native send can request a model read. Final send
    /// admission still rechecks the full captured execution context.
    pub fn native_send_waits_for_codex_catalog(&mut self, captured: &Value) -> bool {
        if !needs_default_codex_catalog(captured) {
            return false;
        }
        let Some(id) = captured["id"].as_str() else {
            return false;
        };
        let Ok(current) = self.saved_selection_envelope(id) else {
            return false;
        };
        if ["selection", "accessMode", "interactionMode"]
            .iter()
            .any(|field| current[*field] != captured[*field])
        {
            return false;
        }
        self.waits_for_default_codex_catalog(captured)
    }

    fn waits_for_default_codex_catalog(&mut self, thread: &Value) -> bool {
        if !needs_default_codex_catalog(thread) || self.require_provider_enabled("codex").is_err() {
            return false;
        }
        let Ok(configuration) = self.provider_launch_configuration_for_thread(thread) else {
            return false;
        };
        let _configuration_scope = crate::provider_configuration::enter(configuration);
        let executable = match self.composer_codex_executable() {
            Ok(executable) => executable,
            Err(_) => return self.provider_discovery_pending,
        };
        if self.composer_thread_effort_proof(thread).is_ok() {
            return false;
        }
        match self.model_catalog.codex_catalog_state(&executable) {
            // A real, current list without the chosen model or options is a
            // validation failure, not a reason to keep retrying forever.
            crate::model_catalog::CodexCatalogState::Ready => false,
            crate::model_catalog::CodexCatalogState::Loading => true,
            crate::model_catalog::CodexCatalogState::Missing
            | crate::model_catalog::CodexCatalogState::Failed => {
                let now = Instant::now();
                if self
                    .queue_catalog_retry_after
                    .is_none_or(|until| now >= until)
                {
                    let started = self
                        .model_catalog
                        .refresh("codex", Some(executable))
                        .is_ok();
                    self.queue_catalog_retry_after =
                        Some(now + Duration::from_secs(if started { 30 } else { 2 }));
                    if started {
                        self.revision += 1;
                    }
                }
                true
            }
        }
    }

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
        validate_question_session(&messages[index], &source)?;
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
            source["selection"] == expected["selection"],
            "Visible provider changed; refresh before sending"
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
        if let Some(active) = messages
            .iter()
            .find(|message| message.state == State::Dispatching)
        {
            ensure!(
                !self.owns_queue_dispatch(id, &active.id),
                "Another queued message is still being delivered"
            );
            bail!("Queue has an unconfirmed dispatch; resume explicitly first");
        }
        let id_message = required(visible, "id")?;
        let mut matches = messages
            .iter()
            .enumerate()
            .filter(|(_, message)| message.id == id_message);
        let (index, message) = matches.next().context("Queued message disappeared")?;
        validate_question_session(message, &source)?;
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
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    #[test]
    fn queued_codex_turn_waits_for_background_catalog_and_recovers_from_failure() {
        use std::{fs, os::unix::fs::PermissionsExt};
        let (root, mut engine, binary) = super::super::provider_configuration::tests::fixture();
        fs::write(&binary, r#"#!/usr/bin/env python3
import json,sys
from pathlib import Path
root=Path(__file__).parent
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
r=read(); write({'id':r['id'],'result':{}}); assert read()['method']=='initialized'
r=read()
if r['method']=='model/list':
 with (root/'model-reads').open('a') as f: f.write('read\n')
 if (root/'fail-models').exists():
  write({'id':r['id'],'error':{'code':-32603,'message':'temporary test failure'}}); sys.exit(0)
 write({'id':r['id'],'result':{'data':[{'model':'reported-model','supportedReasoningEfforts':[{'reasoningEffort':'high'}]}],'nextCursor':None}}); sys.exit(0)
assert r['method'] in ['thread/start','thread/resume']
write({'id':r['id'],'result':{'thread':{'id':'native-thread'},'model':'reported-model'}})
r=read(); assert r['method']=='turn/start'
with (root/'turns').open('a') as f: f.write(json.dumps(r['params'])+'\n')
write({'id':r['id'],'result':{'turn':{'id':'native-turn'}}})
write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'native-turn','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        super::super::provider_configuration::tests::save(
            &mut engine,
            "codex",
            &binary,
            "synthetic",
        );
        let mut thread = engine
            .execute("threads.create", &json!({"cwd":root.path()}))
            .unwrap();
        let id = text(&thread, "id");
        thread["selection"] =
            json!({"provider":"codex","modelID":"reported-model","effort":"high","speed":null});
        queue::add(&mut thread, "deliver exactly once").unwrap();
        engine.store.save(&thread).unwrap();
        engine.enabled_queues.insert(id.clone());
        fs::write(root.path().join("fail-models"), b"").unwrap();
        let mut stale = thread.clone();
        stale["selection"]["modelID"] = json!("another-model");
        assert!(!engine.native_send_waits_for_codex_catalog(&stale));
        assert!(engine.native_send_waits_for_codex_catalog(&thread));
        engine.poll_message_queues();
        let saved = engine.store.thread(&id).unwrap();
        assert_eq!(queue::read(&saved).unwrap()[0].state, State::Pending);
        assert!(saved["rustQueueError"].is_null());
        assert!(engine.enabled_queues.contains(&id));
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            engine.model_catalog.poll();
            let _scope = crate::provider_configuration::enter(
                engine.provider_launch_configuration("codex").unwrap(),
            );
            if engine.model_catalog.codex_catalog_state(&binary)
                == crate::model_catalog::CodexCatalogState::Failed
            {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "catalog failure was not observed"
            );
            std::thread::yield_now();
        }
        assert_eq!(
            queue::read(&engine.store.thread(&id).unwrap()).unwrap()[0].state,
            State::Pending
        );
        assert!(!root.path().join("turns").exists());
        fs::remove_file(root.path().join("fail-models")).unwrap();
        engine.queue_catalog_retry_after = None;
        engine.queue_catalog_poll_after.clear();
        loop {
            engine.poll();
            let saved = engine.store.thread(&id).unwrap();
            let state = queue::read(&saved).unwrap()[0].state;
            if state == State::Completed {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "queued turn did not recover: state={state:?}, error={}, enabled={}, model_reads={}, turns={}",
                saved["rustQueueError"],
                engine.enabled_queues.contains(&id),
                fs::read_to_string(root.path().join("model-reads"))
                    .unwrap_or_default()
                    .lines()
                    .count(),
                fs::read_to_string(root.path().join("turns"))
                    .unwrap_or_default()
                    .lines()
                    .count(),
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        let turns = fs::read_to_string(root.path().join("turns")).unwrap();
        assert_eq!(turns.lines().count(), 1);
        assert_eq!(
            serde_json::from_str::<Value>(turns.lines().next().unwrap()).unwrap()["effort"],
            "high"
        );
        assert!(
            fs::read_to_string(root.path().join("model-reads"))
                .unwrap()
                .lines()
                .count()
                >= 2
        );
        let saved = engine.store.thread(&id).unwrap();
        assert!(saved["rustQueueError"].is_null());
        engine.freeze_admissions();
        if engine.runs.contains_key(&id) {
            engine.request_provider_stop(&id).unwrap();
        }
    }
    #[test]
    fn a_fresh_catalog_with_an_unavailable_model_does_not_retry_forever() {
        let (_root, mut engine, binary) = super::super::provider_configuration::tests::fixture();
        super::super::provider_configuration::tests::save(
            &mut engine,
            "codex",
            &binary,
            "synthetic",
        );
        {
            let _scope = crate::provider_configuration::enter(
                engine.provider_launch_configuration("codex").unwrap(),
            );
            engine
                .model_catalog
                .fixture_reported_configuration_effort(&binary)
                .unwrap();
        }
        let mut thread = engine.store.new_thread("").unwrap();
        thread["selection"] = json!({"provider":"codex","modelID":"removed-model","effort":"high"});
        queue::add(&mut thread, "saved").unwrap();
        engine.store.save(&thread).unwrap();
        assert!(!engine.queue_waits_for_codex_catalog(&thread));
    }
    #[cfg(unix)]
    #[test]
    fn pausing_queue_checks_a_paused_goal_without_touching_the_composer() {
        use std::{fs, os::unix::fs::PermissionsExt};
        let (root, mut engine, binary) = super::super::provider_configuration::tests::fixture();
        fs::write(&binary, r#"#!/usr/bin/env python3
import json,sys
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
r=read(); write({'id':r['id'],'result':{}}); assert read()['method']=='initialized'
r=read(); assert r['method']=='thread/resume'; write({'id':r['id'],'result':{'thread':{'id':'native-thread'},'model':'synthetic-model'}})
r=read(); assert r['method']=='thread/settings/update'; write({'id':r['id'],'result':{}})
r=read(); assert r['method']=='thread/goal/get'; write({'id':r['id'],'result':{'goal':{'threadId':'native-thread','objective':'changed elsewhere','status':'paused'}}})
sys.stdin.readline()
"#).unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        super::super::provider_configuration::tests::save(
            &mut engine,
            "codex",
            &binary,
            "synthetic",
        );
        let configuration = engine
            .provider_launch_configuration("codex")
            .unwrap()
            .unwrap();
        let mut thread = engine
            .execute("threads.create", &serde_json::json!({"cwd":root.path()}))
            .unwrap();
        let id = thread["id"].as_str().unwrap().to_owned();
        thread["selection"] = serde_json::json!({"provider":"codex","modelID":"default"});
        crate::agent::set_provider_session(&mut thread, "codex", "native-thread");
        queue::add(&mut thread, "queued message").unwrap();
        thread["rustCodexGoalAutoResume"] = serde_json::json!({"sessionID":"native-thread","accountID":"default","objective":"test"});
        thread["draft"] = serde_json::json!("unsent draft");
        thread["rustDraftImages"] = serde_json::json!([{"future":"untouched"}]);
        thread["draftContext"] = serde_json::json!([{"future":"untouched"}]);
        engine.store.save(&thread).unwrap();
        engine
            .remember_native_configuration_session(
                "codex",
                &id,
                "native-thread",
                Some(configuration.stamp()),
            )
            .unwrap();
        let before_items = thread["items"].clone();
        engine
            .execute("agent.queue.pause", &serde_json::json!({"threadId":id}))
            .unwrap();
        assert!(
            engine.runs.contains_key(&id),
            "goal check must start without sending the draft"
        );
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while engine.runs.contains_key(&id) {
            engine.poll();
            assert!(std::time::Instant::now() < deadline);
            std::thread::yield_now();
        }
        let saved = engine.store.thread(&id).unwrap();
        assert_eq!(saved["draft"], "unsent draft");
        assert_eq!(saved["rustDraftImages"], thread["rustDraftImages"]);
        assert_eq!(saved["draftContext"], thread["draftContext"]);
        assert_eq!(saved["items"], before_items);
        assert!(saved["rustCodexGoalAutoResume"].is_null());
        assert_eq!(queue::read(&saved).unwrap()[0].state, State::Pending);
    }
    #[test]
    fn acknowledged_queue_delivery_clears_the_row_while_the_turn_continues() {
        for provider in [
            "codex",
            "claude",
            "cursor",
            "grok",
            "opencode",
            "antigravity",
        ] {
            for dismiss in [false, true] {
                let (_dir, mut engine, id) = fixture();
                let mut thread = engine.store.thread(&id).unwrap();
                let message = queue::read(&thread).unwrap()[0].clone();
                thread["rustMessageQueue"][0]["state"] = serde_json::json!("dispatching");
                engine.store.save(&thread).unwrap();
                let (send, receive) = std::sync::mpsc::channel();
                let session = crate::agent::Session::fixture_worker(move |commands, events| {
                    while let Ok(event) = receive.recv() {
                        let finished = matches!(event, crate::agent::Event::Finished);
                        events.send(event).unwrap();
                        if finished {
                            return;
                        }
                    }
                    drop(commands);
                });
                engine.insert_running(
                    id.clone(),
                    super::super::Running {
                        configuration: None,
                        resume_safe: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true)),
                        usage_context: None,
                        session,
                        provider: provider.into(),
                        transcript_start: 0,
                        pending: std::collections::HashMap::new(),
                        schedule_claim: None,
                        queue_claim: Some(message.id.clone()),
                        cancelled: false,
                        events: std::collections::VecDeque::new(),
                        persistence_error: None,
                    },
                );
                // A session ID alone is not a prompt acknowledgement.
                send.send(crate::agent::Event::Session("session".into()))
                    .unwrap();
                let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
                loop {
                    engine.poll();
                    if crate::agent::provider_session(&engine.store.thread(&id).unwrap(), provider)
                        .is_some()
                    {
                        break;
                    }
                    assert!(std::time::Instant::now() < deadline);
                    std::thread::yield_now();
                }
                assert_eq!(
                    queue::read(&engine.store.thread(&id).unwrap()).unwrap()[0].state,
                    State::Dispatching
                );
                if dismiss {
                    let result = engine
                        .execute(
                            "agent.queue.remove",
                            &json!({"threadId":id,"messageId":message.id}),
                        )
                        .unwrap();
                    assert!(result["messages"].as_array().unwrap().is_empty());
                    let saved = engine.store.thread(&id).unwrap();
                    assert_eq!(saved["rustMessageQueue"][0]["dismissed"], true);
                    assert_eq!(saved["rustMessageQueue"][0]["future"], json!({"keep":1}));
                    assert_eq!(
                        engine.runs[&id].queue_claim.as_deref(),
                        Some(message.id.as_str())
                    );
                    assert!(
                        engine.native_queue_read(&id).unwrap()["messages"]
                            .as_array()
                            .unwrap()
                            .is_empty()
                    );
                }
                send.send(crate::agent::Event::TurnAccepted).unwrap();
                loop {
                    engine.poll();
                    if queue::read(&engine.store.thread(&id).unwrap()).unwrap()[0].state
                        == State::Completed
                    {
                        break;
                    }
                    assert!(std::time::Instant::now() < deadline);
                    std::thread::yield_now();
                }
                assert!(engine.runs.contains_key(&id));
                assert!(engine.runs[&id].queue_claim.is_none());
                send.send(crate::agent::Event::Finished).unwrap();
                while engine.runs.contains_key(&id) {
                    engine.poll();
                    assert!(std::time::Instant::now() < deadline);
                    std::thread::yield_now();
                }
            }
        }
    }

    #[test]
    fn queued_row_finishes_at_turn_boundary_while_goal_worker_continues() {
        let (_dir, mut engine, id) = fixture();
        let mut thread = engine.store.thread(&id).unwrap();
        let message = queue::read(&thread).unwrap()[0].clone();
        thread["rustMessageQueue"][0]["state"] = serde_json::json!("dispatching");
        engine.store.save(&thread).unwrap();
        let (release, wait) = std::sync::mpsc::channel();
        let session = crate::agent::Session::fixture_worker(move |commands, events| {
            wait.recv().unwrap();
            events.send(crate::agent::Event::TurnBoundary).unwrap();
            let _ = commands.recv();
            let _ = events.send(crate::agent::Event::Finished);
        });
        engine.insert_running(
            id.clone(),
            super::super::Running {
                configuration: None,
                resume_safe: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true)),
                usage_context: Some(crate::agent::usage_capture::TurnContext::new(&thread)),
                session,
                provider: "codex".into(),
                transcript_start: 0,
                pending: std::collections::HashMap::new(),
                schedule_claim: None,
                queue_claim: Some(message.id),
                cancelled: false,
                events: std::collections::VecDeque::new(),
                persistence_error: None,
            },
        );
        release.send(()).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            engine.poll();
            if queue::read(&engine.store.thread(&id).unwrap()).unwrap()[0].state == State::Completed
            {
                break;
            }
            assert!(std::time::Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert!(engine.runs.contains_key(&id));
        assert!(engine.runs[&id].queue_claim.is_none());
        engine.freeze_admissions();
        engine.request_provider_stop(&id).unwrap();
    }
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
