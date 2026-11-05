//! Strict asynchronous text steering. Admission is distinct from provider ACK
//! and durable transcript persistence; unknown delivery never becomes success.
use super::*;
use agent::codex_steering::{Outcome, Ticket};
use std::sync::mpsc::TryRecvError;
pub(super) struct Operation {
    thread: String,
    text: String,
    ticket: Ticket,
    outcome: Option<Outcome>,
    persisted: bool,
}
impl Engine {
    pub(super) fn steer_command(&mut self, method: &str, p: &Value) -> Result<Value> {
        self.require_admissions()?;
        let fields = p
            .as_object()
            .context("Steering parameters must be an object")?;
        let result = method == "agent.steer.result";
        ensure!(
            fields
                .keys()
                .all(|key| key == "threadId" || key == if result { "operationId" } else { "text" }),
            "Unsupported steering parameters"
        );
        let thread = required(p, "threadId")?;
        if result {
            let id = required(p, "operationId")?;
            let op = self
                .steering_operations
                .get(id)
                .context("Unknown steering operation")?;
            ensure!(
                op.thread == thread,
                "Steering operation belongs to another thread"
            );
            let status = match op.outcome {
                None => "pending",
                Some(Outcome::Accepted) => {
                    if op.persisted {
                        "accepted"
                    } else {
                        "accepted_pending_persistence"
                    }
                }
                Some(Outcome::Rejected) => "rejected",
                Some(Outcome::Unknown) => "unknown",
            };
            let reply = json!({"operationId":id,"threadId":thread,"status":status,"persisted":op.persisted,"text":op.text});
            // Terminal results are collected once; pending accepted persistence
            // remains private until an actual successful Store write.
            if op.outcome.is_some() && (op.outcome != Some(Outcome::Accepted) || op.persisted) {
                self.steering_operations.remove(id);
            }
            return Ok(reply);
        }
        ensure!(
            self.steering_operations.len() < 32,
            "Collect earlier steering results before submitting more"
        );
        ensure!(
            !self
                .steering_operations
                .values()
                .any(|op| op.thread == thread
                    && (op.outcome.is_none()
                        || op.outcome == Some(Outcome::Accepted) && !op.persisted)),
            "A steering operation is already pending for this thread"
        );
        ensure!(
            !self.unsaved_threads.contains_key(thread),
            "Transcript persistence is recovering; retry after recovery"
        );
        let text = required(p, "text")?;
        ensure!(
            !text.trim().is_empty() && text.len() <= 1024 * 1024,
            "Steering text must be nonempty and fit within 1 MiB"
        );
        let stored = self.store.thread(thread)?;
        ensure!(
            !self.store.is_imported(thread)?,
            "Imported conversations are read-only for agent execution until cutover; fork first"
        );
        for key in ["draftContext", "rustDraftImages"] {
            ensure!(
                stored[key].is_null() || stored[key].as_array().is_some_and(Vec::is_empty),
                "Text-only steering cannot deliver attached context or images; send them separately"
            );
        }
        let effort_proof = self.composer_effort_proof(&stored["selection"])?;
        crate::composer_selection::validate_thread_with_proof(&stored, effort_proof.as_ref())?;
        ensure!(
            stored["interactionMode"]
                .as_str()
                .is_none_or(|mode| mode == "build"),
            "Text steering is available only in Build mode"
        );
        let cwd = self.working_directory(&stored)?;
        self.bot_instructions(&stored, &cwd)?;
        let run = self.runs.get(thread).context("Thread is not running")?;
        ensure!(
            run.provider == "codex" && stored["selection"]["provider"] == "codex",
            "Active-turn steering is supported only for Codex"
        );
        ensure!(
            !run.cancelled && run.persistence_error.is_none(),
            "The running turn is stopping or recovering"
        );
        ensure!(
            run.usage_context
                .as_ref()
                .is_some_and(|context| context.matches(&stored)),
            "Stored selection or project differs from the running turn"
        );
        let ticket = run.session.steer(text)?;
        let id = Uuid::new_v4().to_string();
        self.steering_operations.insert(
            id.clone(),
            Operation {
                thread: thread.into(),
                text: text.into(),
                ticket,
                outcome: None,
                persisted: false,
            },
        );
        Ok(json!({"operationId":id,"threadId":thread,"status":"pending","persisted":false}))
    }
    pub(super) fn poll_steering(&mut self) {
        for (id, op) in &mut self.steering_operations {
            if op.outcome.is_none() {
                op.outcome = match op.ticket.receiver.try_recv() {
                    Ok(outcome) => Some(outcome),
                    Err(TryRecvError::Disconnected) => Some(Outcome::Unknown),
                    Err(TryRecvError::Empty) => None,
                };
            }
            if op.outcome != Some(Outcome::Accepted) || op.persisted {
                continue;
            }
            let result = (|| -> Result<()> {
                let mut thread = if let Some(thread) = self.unsaved_threads.get(&op.thread) {
                    thread.clone()
                } else {
                    self.store.thread(&op.thread)?
                };
                if !thread["items"]
                    .as_array()
                    .context("Invalid transcript")?
                    .iter()
                    .any(|item| item["id"] == id.as_str())
                {
                    append(&mut thread, "user", &op.text, None);
                    let item = thread["items"].as_array_mut().unwrap().last_mut().unwrap();
                    item["id"] = json!(id);
                    item["steered"] = json!(true);
                    item["provider"] = json!("codex");
                }
                if let Err(error) = self.store.save_with_usage(
                    &thread,
                    self.pending_usage.get(&op.thread).map(|record| &record.0),
                ) {
                    self.unsaved_threads.insert(op.thread.clone(), thread);
                    return Err(error);
                }
                self.unsaved_threads.remove(&op.thread);
                self.pending_usage.remove(&op.thread);
                Ok(())
            })();
            if let Err(error) = result {
                self.schedule_error = Some(format!("Steered message could not be saved: {error}"));
                if let Some(run) = self.runs.get_mut(&op.thread) {
                    run.persistence_error = self.schedule_error.clone();
                    run.session.stop();
                }
            } else {
                op.persisted = true;
                self.revision += 1;
            }
        }
    }
    pub(super) fn pending_steering_count(&self) -> usize {
        self.steering_operations
            .values()
            .filter(|op| {
                op.outcome.is_none() || op.outcome == Some(Outcome::Accepted) && !op.persisted
            })
            .count()
    }
}

#[cfg(test)]
#[path = "steering_api_tests.rs"]
mod tests;
