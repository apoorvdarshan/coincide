//! Native, one-owner follow-up delivery. No JSON route or serialized operation
//! can schedule an interrupt. Crash/Quit loses pending delivery and keeps draft.
use super::*;
use crate::composer_follow_up::{self as choice, Behavior, Dispatch};
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NativeFollowUpStatus {
    Pending,
    Delivered {
        dispatch: Dispatch,
        draft_cleared: bool,
    },
    Retained(String),
}
pub struct NativeFollowUpTicket {
    owner: Uuid,
    id: Uuid,
}
enum Delivery {
    Steering(String),
    Deferred(agent::WorkerCompletion),
}
struct Operation {
    thread: String,
    source: Value,
    prefix: Vec<Value>,
    text: String,
    dispatch: Dispatch,
    delivery: Option<Delivery>,
    status: NativeFollowUpStatus,
}
pub(super) struct State {
    owner: Uuid,
    operations: HashMap<Uuid, Operation>,
    blocked: HashMap<String, String>,
}
impl Default for State {
    fn default() -> Self {
        Self {
            owner: Uuid::new_v4(),
            operations: HashMap::new(),
            blocked: HashMap::new(),
        }
    }
}
impl State {
    pub(super) fn has_pending(&self) -> bool {
        self.operations
            .values()
            .any(|op| op.status == NativeFollowUpStatus::Pending)
    }
    pub(super) fn pending_thread(&self, thread: &str) -> bool {
        self.operations
            .values()
            .any(|op| op.thread == thread && op.status == NativeFollowUpStatus::Pending)
    }
}
use choice::scope;
impl Engine {
    /// Named follow-ups use the selected account's actual private catalog and
    /// policy, just like normal turn admission; never borrow a default proof.
    pub(super) fn validate_native_follow_up_policy(&self, thread: &Value) -> Result<()> {
        self.require_provider_enabled(&text(&thread["selection"], "provider"))?;
        if let Some(profile) = self.codex_login_context(thread)? {
            let binding = crate::model_catalog::NamedBinding::capture(
                profile,
                required(thread, "id")?,
                &self.working_directory(thread)?,
            )?;
            self.model_catalog
                .named_resume_admission(thread, &binding)?;
            let proof = self
                .model_catalog
                .named_model_proof(thread, &binding, None)?;
            crate::composer_policy::Policy::parse_named(
                thread,
                crate::composer_policy::Origin::Ordinary,
                proof.as_ref(),
            )?
            .preflight()
        } else {
            let proof = self.composer_thread_effort_proof(thread)?;
            crate::composer_selection::validate_thread_with_proof(thread, proof.as_ref())
        }
    }
    pub fn choose_native_follow_up(
        &mut self,
        expected: &Value,
        behavior: Behavior,
    ) -> Result<Value> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let id = required(expected, "id")?;
        ensure!(
            self.active_thread.as_deref() == Some(id),
            "Composer is no longer active"
        );
        ensure!(
            !self.unsaved_threads.contains_key(id),
            "Transcript persistence is recovering"
        );
        ensure!(
            behavior != Behavior::Steer || expected["selection"]["provider"] == "codex",
            "This provider does not support native steering yet"
        );
        let thread = self.store.choose_follow_up(expected, behavior)?;
        self.revision += 1;
        Ok(thread)
    }
    /// Actual run readiness, not saved metadata, selects the native send glyph.
    pub fn native_follow_up_dispatch(&self, thread: &Value, alternate: bool) -> Result<Dispatch> {
        let settings = self
            .store
            .document("settings.json")?
            .unwrap_or_else(|| json!({}));
        let run = self.runs.get(required(thread, "id")?);
        let supports = thread["selection"]["provider"] == "codex";
        let behavior = choice::effective(choice::selected(thread, &settings), supports);
        let ready = run.is_some_and(|run| {
            !run.cancelled
                && run.persistence_error.is_none()
                && thread["interactionMode"]
                    .as_str()
                    .is_none_or(|mode| mode == "build")
                && run.session.can_steer()
        });
        let approval = run.is_some_and(|run| {
            run.pending
                .values()
                .any(|frame| frame["method"] != "item/tool/requestUserInput")
        });
        Ok(choice::resolve(run.is_some(), ready, alternate, behavior, approval).0)
    }
    pub fn send_native_follow_up(
        &mut self,
        expected: &Value,
        alternate: bool,
    ) -> Result<NativeFollowUpTicket> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let id = required(expected, "id")?.to_owned();
        ensure!(
            self.active_thread.as_deref() == Some(id.as_str()),
            "Composer is no longer active"
        );
        ensure!(
            self.native_follow_up.operations.len() < 32
                && !self.native_follow_up.pending_thread(&id),
            "Collect the previous follow-up before sending again"
        );
        ensure!(
            !self.unsaved_threads.contains_key(&id),
            "Transcript persistence is recovering"
        );
        let current = self.store.thread(&id)?;
        ensure!(
            scope(&current) == scope(expected),
            "Composer changed; draft retained"
        );
        self.require_provider_enabled(&text(&current["selection"], "provider"))?;
        ensure!(
            !self.store.is_imported(&id)? && current["isArchived"] != true,
            "Fork or restore this conversation before sending"
        );
        ensure!(
            serde_json::to_vec(&scope(&current))?.len() <= 2 * 1024 * 1024,
            "Composer scope exceeds safe follow-up limit"
        );
        let text = required(&current, "draft")?.to_owned();
        ensure!(
            !text.trim().is_empty() && text.len() <= 1024 * 1024,
            "Follow-up text must be nonempty and fit within 1 MiB"
        );
        ensure!(
            self.native_follow_up.blocked.get(&id) != Some(&text),
            "This text was already submitted; edit it before submitting again"
        );
        self.native_follow_up.blocked.remove(&id);
        let store = &self.store;
        self.native_follow_up.blocked.retain(|thread, submitted| {
            store
                .thread(thread)
                .is_ok_and(|value| value["draft"].as_str() == Some(submitted.as_str()))
        });
        ensure!(
            self.native_follow_up.blocked.len() < 32,
            "Edit or collect retained follow-up drafts before sending more"
        );
        let run = self
            .runs
            .get(&id)
            .context("A native follow-up requires a running turn")?;
        ensure!(
            !run.cancelled && run.persistence_error.is_none(),
            "Turn is stopping or persistence is recovering"
        );
        ensure!(
            run.usage_context
                .as_ref()
                .is_some_and(|context| context.matches(&current)),
            "Stored selection or project differs from the running turn"
        );
        for field in ["draftContext", "rustDraftImages"] {
            ensure!(
                current[field].is_null() || current[field].as_array().is_some_and(Vec::is_empty),
                "Follow-ups currently support text only; attached material remains in the draft"
            );
        }
        ensure!(
            !self.attachment_operations.iter().any(|operation| self
                .workspace_pending
                .get(operation)
                .is_some_and(|(owner, _)| owner == &id)),
            "Wait for image imports to finish before sending a follow-up"
        );
        self.validate_native_follow_up_policy(&current)?;
        let cwd = self.working_directory(&current)?;
        self.bot_instructions(&current, &cwd)?;
        let settings = self
            .store
            .document("settings.json")?
            .unwrap_or_else(|| json!({}));
        let behavior = choice::effective(
            choice::selected(&current, &settings),
            run.provider == "codex",
        );
        let can_steer = run.provider == "codex"
            && current["interactionMode"]
                .as_str()
                .is_none_or(|mode| mode == "build")
            && run.session.can_steer();
        let approval = run
            .pending
            .values()
            .any(|frame| frame["method"] != "item/tool/requestUserInput");
        let (dispatch, means_steer) =
            choice::resolve(true, can_steer, alternate, behavior, approval);
        let worker = run.session.worker_completion();
        let prefix: Vec<Value> = current["items"]
            .as_array()
            .context("Missing transcript")?
            .iter()
            .take(run.transcript_start)
            .cloned()
            .collect();
        ensure!(
            serde_json::to_vec(&prefix)?.len() <= 8 * 1024 * 1024,
            "Conversation prefix exceeds safe native follow-up limit"
        );
        // Validate every denial before replying to any pending request. Never
        // grant an approval, invent a question answer, or use stale UI request IDs.
        let mut denials = Vec::new();
        ensure!(
            run.pending.len() <= 64,
            "Too many pending requests; respond explicitly first"
        );
        for (key, frame) in &run.pending {
            let result = if frame["method"] == "item/tool/requestUserInput" {
                json!({"answers":{}})
            } else {
                let offered = frame["params"]["availableDecisions"].as_array();
                let decision = ["decline", "cancel"]
                    .into_iter()
                    .find(|decision| offered.is_none_or(|values| values.contains(&json!(decision))))
                    .context("Agent offers no safe decline; respond explicitly first")?;
                json!({"decision":decision})
            };
            denials.push((key.clone(), frame["id"].clone(), result));
        }
        for (key, request, result) in denials {
            let run = self
                .runs
                .get_mut(&id)
                .context("Turn stopped before redirect")?;
            run.session.reply(request, result)?;
            run.pending.remove(&key);
            self.notification_events.cancel_request(&id, &key);
        }
        let mut op = Operation {
            thread: id.clone(),
            source: scope(&current),
            prefix,
            text: text.clone(),
            dispatch,
            delivery: None,
            status: NativeFollowUpStatus::Pending,
        };
        match dispatch {
            Dispatch::Steer => {
                let result =
                    self.steer_command("agent.steer", &json!({"threadId":id,"text":text}))?;
                op.delivery = Some(Delivery::Steering(required(&result, "operationId")?.into()));
            }
            Dispatch::Interrupt => {
                self.request_provider_stop(&id)?;
                op.delivery = Some(Delivery::Deferred(worker));
            }
            Dispatch::Queue if means_steer => {
                op.delivery = Some(Delivery::Deferred(worker));
            }
            Dispatch::Queue => {
                let enabled = self.store.queue_native_follow_up(
                    &current,
                    &text,
                    self.enabled_queues.contains(&id),
                )?;
                if enabled {
                    self.enabled_queues.insert(id.clone());
                }
                op.status = NativeFollowUpStatus::Delivered {
                    dispatch,
                    draft_cleared: true,
                };
            }
            Dispatch::Send => unreachable!(),
        }
        let ticket = NativeFollowUpTicket {
            owner: self.native_follow_up.owner,
            id: Uuid::new_v4(),
        };
        if !matches!(
            op.status,
            NativeFollowUpStatus::Delivered {
                draft_cleared: true,
                ..
            }
        ) {
            self.native_follow_up.blocked.insert(id, text);
        }
        self.native_follow_up.operations.insert(ticket.id, op);
        self.revision += 1;
        Ok(ticket)
    }
    pub fn native_follow_up_status(
        &self,
        ticket: &NativeFollowUpTicket,
    ) -> Result<NativeFollowUpStatus> {
        ensure!(
            ticket.owner == self.native_follow_up.owner,
            "Follow-up belongs to another Engine"
        );
        Ok(self
            .native_follow_up
            .operations
            .get(&ticket.id)
            .context("Unknown follow-up")?
            .status
            .clone())
    }
    pub fn collect_native_follow_up(&mut self, ticket: NativeFollowUpTicket) -> Result<()> {
        ensure!(
            ticket.owner == self.native_follow_up.owner,
            "Follow-up belongs to another Engine"
        );
        ensure!(
            self.native_follow_up
                .operations
                .get(&ticket.id)
                .is_some_and(|op| op.status != NativeFollowUpStatus::Pending),
            "Follow-up still owns pending delivery"
        );
        self.native_follow_up.operations.remove(&ticket.id);
        Ok(())
    }
    pub(super) fn poll_native_follow_ups(&mut self) {
        let mut operations = std::mem::take(&mut self.native_follow_up.operations);
        for op in operations
            .values_mut()
            .filter(|op| op.status == NativeFollowUpStatus::Pending)
        {
            let result = (|| -> Result<Option<bool>> {
                ensure!(
                    !self.admissions_frozen() && !self.shutdown,
                    "Application is closing; draft retained"
                );
                match op.delivery.as_ref().context("Missing follow-up delivery")? {
                    Delivery::Steering(operation) => {
                        let result = self.steer_command(
                            "agent.steer.result",
                            &json!({"threadId":op.thread,"operationId":operation}),
                        )?;
                        match result["status"].as_str() {
                            Some("pending" | "accepted_pending_persistence") => Ok(None),
                            Some("accepted") => {
                                Ok(Some(self.store.clear_native_follow_up_draft(&op.source)?))
                            }
                            _ => bail!(
                                "Steering was rejected or delivery is unknown; draft retained"
                            ),
                        }
                    }
                    Delivery::Deferred(worker) => {
                        match worker.status() {
                            agent::WorkerThreadStatus::Running => return Ok(None),
                            agent::WorkerThreadStatus::Returned => {}
                            _ => bail!("Previous worker did not return cleanly; draft retained"),
                        }
                        if self.runs.contains_key(&op.thread)
                            || self.unsaved_threads.contains_key(&op.thread)
                        {
                            return Ok(None);
                        }
                        let current = self.store.thread(&op.thread)?;
                        ensure!(
                            scope(&current) == scope(&op.source),
                            "Composer changed while stopping; draft retained"
                        );
                        ensure!(
                            current["items"]
                                .as_array()
                                .is_some_and(|items| items.starts_with(&op.prefix)),
                            "Conversation prefix changed; draft retained"
                        );
                        self.send_turn_if_unchanged(
                            &json!({"threadId":op.thread,"text":op.text}),
                            &SendOrigin::Ordinary,
                            Some(&op.source),
                            op.dispatch == Dispatch::Interrupt,
                        )?;
                        Ok(Some(true))
                    }
                }
            })();
            match result {
                Ok(Some(cleared)) => {
                    if cleared {
                        self.native_follow_up.blocked.remove(&op.thread);
                    }
                    op.delivery = None;
                    op.status = NativeFollowUpStatus::Delivered {
                        dispatch: op.dispatch,
                        draft_cleared: cleared,
                    };
                    self.revision += 1;
                }
                Ok(None) => {}
                Err(error) => {
                    op.delivery = None;
                    op.status = NativeFollowUpStatus::Retained(error.to_string());
                    self.revision += 1;
                }
            }
        }
        self.native_follow_up.operations = operations;
    }
}

#[cfg(test)]
#[path = "follow_up_api_tests.rs"]
mod tests;
