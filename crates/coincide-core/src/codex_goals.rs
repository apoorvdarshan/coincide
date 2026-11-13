//! Codex goal controls belong to the native thread, not to an ordinary prompt.
use super::{Event, request, transport::Transport};
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::mpsc::SyncSender,
    time::{Duration, Instant},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Command {
    Show,
    Set(String),
    Pause,
    Resume,
    Clear,
    Edit,
    /// Internal controls let a locally queued turn run before a goal resumes.
    PauseForQueue,
    ResumeForQueue,
    CheckForResume,
}

/// Only an explicit, standalone `/goal` prefix is a control. Attached images,
/// references, and provider changes are checked by the caller.
pub(crate) fn parse(text: &str) -> Option<Command> {
    let input = text.trim();
    let rest = input.strip_prefix("/goal")?;
    if !rest.is_empty() && !rest.starts_with(char::is_whitespace) {
        return None;
    }
    let argument = rest.trim();
    Some(match argument.to_ascii_lowercase().as_str() {
        "" => Command::Show,
        "pause" => Command::Pause,
        "resume" => Command::Resume,
        "clear" => Command::Clear,
        "edit" => Command::Edit,
        _ => Command::Set(argument.to_owned()),
    })
}

/// A queue may resume only the exact Codex account, native thread and
/// objective that Coincide itself paused for that queue.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PausedGoal {
    pub objective: String,
    pub created_at: Option<i64>,
    pub updated_at: Option<i64>,
}
#[cfg(test)]
impl From<&str> for PausedGoal {
    fn from(objective: &str) -> Self {
        Self {
            objective: objective.into(),
            created_at: None,
            updated_at: None,
        }
    }
}
pub(crate) fn queued_resume_objective(
    thread: &Value,
    session: Option<&str>,
    queued: bool,
) -> Option<PausedGoal> {
    if !queued || thread["selection"]["provider"] != "codex" {
        return None;
    }
    let session = session.filter(|value| !value.is_empty())?;
    let marker = &thread["rustCodexGoalAutoResume"];
    if marker["sessionID"].as_str() != Some(session)
        || marker["accountID"].as_str()
            != Some(
                thread["selection"]["accountID"]
                    .as_str()
                    .unwrap_or("default"),
            )
    {
        return None;
    }
    let objective = marker["objective"]
        .as_str()
        .filter(|value| !value.trim().is_empty() && value.len() <= 1024 * 1024)
        .map(str::to_owned)?;
    if (!marker["createdAt"].is_null() && marker["createdAt"].as_i64().is_none())
        || (!marker["updatedAt"].is_null() && marker["updatedAt"].as_i64().is_none())
    {
        return None;
    }
    Some(PausedGoal {
        objective,
        created_at: marker["createdAt"].as_i64(),
        updated_at: marker["updatedAt"].as_i64(),
    })
}

impl Command {
    pub(super) fn request(&self, thread: &str) -> Result<(&'static str, Value)> {
        ensure!(
            !thread.is_empty() && thread.len() <= 512,
            "Invalid Codex thread"
        );
        Ok(match self {
            Self::Show | Self::Edit | Self::CheckForResume => {
                ("thread/goal/get", json!({"threadId":thread}))
            }
            Self::Set(objective) => {
                ensure!(
                    !objective.trim().is_empty() && objective.len() <= 1024 * 1024,
                    "Goal objective must be nonempty and fit within 1 MiB"
                );
                (
                    "thread/goal/set",
                    json!({"threadId":thread,"objective":objective,"status":"active","origin":"user"}),
                )
            }
            Self::Pause | Self::PauseForQueue => (
                "thread/goal/set",
                json!({"threadId":thread,"status":"paused","origin":if matches!(self, Self::PauseForQueue) {"automatic"} else {"user"}}),
            ),
            Self::Resume | Self::ResumeForQueue => (
                "thread/goal/set",
                json!({"threadId":thread,"status":"active","origin":if matches!(self, Self::ResumeForQueue) {"automatic"} else {"user"}}),
            ),
            Self::Clear => (
                "thread/goal/clear",
                json!({"threadId":thread,"origin":"user"}),
            ),
        })
    }
}

/// Accept only provider state for the bound native thread. Treat missing or
/// unfamiliar statuses as unavailable, never as proof that a goal is complete.
pub(super) fn validate_goal(goal: &Value, thread: &str) -> Result<()> {
    ensure!(
        goal.is_object()
            && goal["threadId"] == thread
            && goal["objective"]
                .as_str()
                .is_some_and(|s| !s.trim().is_empty() && s.len() <= 1024 * 1024)
            && goal["status"].as_str().is_some_and(|s| !s.is_empty()
                && s.len() <= 128
                && !s.chars().any(char::is_control)),
        "Codex returned an invalid goal for this conversation"
    );
    Ok(())
}

struct Pending {
    command: Command,
    reply: Option<SyncSender<std::result::Result<(), String>>>,
    started: Instant,
    revision: u64,
}

#[derive(Default)]
pub(super) struct Tracker {
    pub(super) goal: Option<Value>,
    pending: HashMap<u64, Pending>,
    next_id: u64,
    revision: u64,
}

impl Tracker {
    pub(super) fn active(&self) -> bool {
        self.goal
            .as_ref()
            .is_some_and(|goal| goal["status"] == "active")
    }

    pub(super) fn pending(&self) -> bool {
        !self.pending.is_empty()
    }
    pub(super) fn paused(&self) -> bool {
        self.goal
            .as_ref()
            .is_some_and(|goal| goal["status"] == "paused")
    }
    pub(super) fn paused_objective_is(&self, expected: &PausedGoal) -> bool {
        self.goal.as_ref().is_some_and(|goal| {
            goal["status"] == "paused"
                && goal["objective"] == expected.objective
                && expected
                    .created_at
                    .is_none_or(|value| goal["createdAt"].as_i64() == Some(value))
                && expected
                    .updated_at
                    .is_none_or(|value| goal["updatedAt"].as_i64() == Some(value))
        })
    }

    pub(super) fn send(
        &mut self,
        command: Command,
        thread: &str,
        reply: Option<SyncSender<std::result::Result<(), String>>>,
        transport: &mut Transport,
    ) -> Result<()> {
        ensure!(
            self.pending.len() < 8,
            "Too many pending Codex goal actions"
        );
        let (method, params) = command.request(thread)?;
        self.next_id = self.next_id.wrapping_add(1);
        // Separate from startup and account request IDs; the provider's own
        // request IDs are correlated independently by the transport.
        let id = 5_000_000_000u64 + self.next_id;
        transport.write(&request(id, method, params))?;
        self.pending.insert(
            id,
            Pending {
                command,
                reply,
                started: Instant::now(),
                revision: self.revision,
            },
        );
        Ok(())
    }

    /// Consume only a response to our request, never an unrelated provider
    /// frame. A missing ACK remains a failure rather than fabricated success.
    pub(super) fn response(
        &mut self,
        frame: &Value,
        thread: &str,
        events: &std::sync::mpsc::Sender<Event>,
    ) -> Result<bool> {
        if frame.get("method").is_some() {
            return Ok(false);
        }
        let Some(id) = frame["id"].as_u64() else {
            return Ok(false);
        };
        let Some(pending) = self.pending.remove(&id) else {
            // A late answer to one of our expired controls must not fail a
            // newer turn or be mistaken for a provider-initiated request.
            return Ok(id > 5_000_000_000 && id <= 5_000_000_000 + self.next_id);
        };
        let outcome = (|| -> Result<(Option<Value>, Option<String>)> {
            ensure!(
                frame.get("error").is_none(),
                "Codex declined the goal action"
            );
            let result = frame["result"]
                .as_object()
                .ok_or_else(|| anyhow::anyhow!("Codex returned an invalid goal response"))?;
            if pending.command == Command::Clear {
                ensure!(
                    result.get("cleared").and_then(Value::as_bool).is_some(),
                    "Codex did not confirm the goal action"
                );
                return Ok((
                    None,
                    Some(
                        if result["cleared"] == true {
                            "Goal cleared."
                        } else {
                            "No goal is set."
                        }
                        .into(),
                    ),
                ));
            }
            let goal = result.get("goal").filter(|goal| !goal.is_null()).cloned();
            if let Some(goal) = &goal {
                validate_goal(goal, thread)?;
            }
            match &pending.command {
                Command::Set(_) | Command::Resume | Command::ResumeForQueue => ensure!(
                    goal.as_ref().is_some_and(|goal| goal["status"] == "active"),
                    "Codex did not activate the goal"
                ),
                Command::Pause | Command::PauseForQueue => ensure!(
                    goal.as_ref().is_some_and(|goal| goal["status"] == "paused"),
                    "Codex did not pause the goal"
                ),
                _ => {}
            }
            let notice = match &pending.command {
                Command::Show | Command::Edit => Some(match &goal {
                    Some(goal) => format!(
                        "Goal ({}): {}{}",
                        goal["status"].as_str().unwrap_or("unknown"),
                        goal["objective"].as_str().unwrap_or(""),
                        if pending.command == Command::Edit {
                            "\nTo change it, send /goal followed by the new objective."
                        } else {
                            ""
                        }
                    ),
                    None => {
                        "No goal is set. Send /goal followed by an objective to start one.".into()
                    }
                }),
                _ => None,
            };
            Ok((goal, notice))
        })();
        match outcome {
            Ok((goal, notice)) => {
                // A newer notification can precede an older RPC reply. Never
                // roll back the live goal to the stale reply's status.
                let notification_is_newer = pending.revision != self.revision
                    && self
                        .goal
                        .as_ref()
                        .and_then(|goal| goal["updatedAt"].as_i64())
                        .zip(goal.as_ref().and_then(|goal| goal["updatedAt"].as_i64()))
                        .is_some_and(|(notification, reply)| notification > reply);
                let current = if !notification_is_newer {
                    self.goal = goal;
                    self.goal.clone()
                } else {
                    self.goal.clone()
                };
                let queue_action = match &pending.command {
                    Command::PauseForQueue
                        if current
                            .as_ref()
                            .is_some_and(|goal| goal["status"] == "paused") =>
                    {
                        Some(true)
                    }
                    Command::ResumeForQueue => Some(false),
                    _ => None,
                };
                events.send(Event::Goal {
                    thread: thread.into(),
                    goal: current,
                    notice,
                    queue_action,
                    user_mutation: matches!(
                        &pending.command,
                        Command::Set(_) | Command::Pause | Command::Resume | Command::Clear
                    ),
                })?;
                if let Some(reply) = pending.reply {
                    let _ = reply.try_send(Ok(()));
                }
            }
            Err(error) => {
                if let Some(reply) = pending.reply {
                    let _ = reply.try_send(Err(error.to_string()));
                } else {
                    return Err(error);
                }
            }
        }
        Ok(true)
    }

    pub(super) fn notification(
        &mut self,
        frame: &Value,
        thread: &str,
        events: &std::sync::mpsc::Sender<Event>,
    ) -> Result<bool> {
        if frame["params"]["threadId"] != thread {
            return Ok(false);
        }
        let goal = match frame["method"].as_str() {
            Some("thread/goal/updated") => {
                let goal = frame["params"]["goal"].clone();
                validate_goal(&goal, thread)?;
                Some(goal)
            }
            Some("thread/goal/cleared") => None,
            _ => return Ok(false),
        };
        self.goal = goal.clone();
        self.revision = self.revision.wrapping_add(1);
        events.send(Event::Goal {
            thread: thread.into(),
            goal,
            notice: None,
            queue_action: None,
            user_mutation: false,
        })?;
        Ok(true)
    }

    pub(super) fn expire(&mut self) -> Result<()> {
        let expired = self
            .pending
            .iter()
            .filter_map(|(id, pending)| {
                (pending.started.elapsed() >= Duration::from_secs(30)).then_some(*id)
            })
            .collect::<Vec<_>>();
        for id in expired {
            let pending = self
                .pending
                .remove(&id)
                .expect("observed pending goal action");
            // Dropping a live reply marks delivery unknown to its owner. Do not
            // turn an unconfirmed request into a definite rejection or retry.
            if pending.reply.is_none() {
                anyhow::bail!("Codex did not confirm the goal action");
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_commands_follow_the_native_goal_protocol() {
        for (text, method, params) in [
            ("/goal", "thread/goal/get", json!({"threadId":"thread"})),
            (
                "/goal pause",
                "thread/goal/set",
                json!({"threadId":"thread","status":"paused","origin":"user"}),
            ),
            (
                "/goal resume",
                "thread/goal/set",
                json!({"threadId":"thread","status":"active","origin":"user"}),
            ),
            (
                "/goal clear",
                "thread/goal/clear",
                json!({"threadId":"thread","origin":"user"}),
            ),
            (
                "/goal keep testing",
                "thread/goal/set",
                json!({"threadId":"thread","objective":"keep testing","status":"active","origin":"user"}),
            ),
        ] {
            assert_eq!(
                parse(text).unwrap().request("thread").unwrap(),
                (method, params)
            );
        }
        assert_eq!(parse("/goals"), None);
        assert_eq!(parse("please run /goal"), None);
        assert_eq!(parse("/goalkeeper"), None);
        assert_eq!(parse("/goal edit"), Some(Command::Edit));
    }

    #[test]
    fn goal_updates_must_belong_to_the_current_native_thread() {
        let valid = json!({"threadId":"native","objective":"finish","status":"active"});
        assert!(validate_goal(&valid, "native").is_ok());
        assert!(validate_goal(&valid, "another").is_err());
        let mut future = valid;
        future["status"] = json!("future-status");
        assert!(validate_goal(&future, "native").is_ok());
    }
    #[test]
    fn queued_resume_never_borrows_another_provider_account_or_thread() {
        let mut thread = json!({"selection":{"provider":"codex","accountID":"account-a"},"rustCodexGoalAutoResume":{"sessionID":"native-a","accountID":"account-a","objective":"finish"}});
        assert_eq!(
            queued_resume_objective(&thread, Some("native-a"), true).map(|goal| goal.objective),
            Some("finish".into())
        );
        assert_eq!(
            queued_resume_objective(&thread, Some("native-b"), true),
            None
        );
        assert_eq!(queued_resume_objective(&thread, None, true), None);
        assert_eq!(
            queued_resume_objective(&thread, Some("native-a"), false),
            None
        );
        thread["selection"]["accountID"] = json!("account-b");
        assert_eq!(
            queued_resume_objective(&thread, Some("native-a"), true),
            None
        );
        thread["selection"]["provider"] = json!("claude");
        assert_eq!(
            queued_resume_objective(&thread, Some("native-a"), true),
            None
        );
    }
    #[test]
    fn newer_native_goal_notification_is_not_overwritten_by_an_old_control_reply() {
        let (events, received) = std::sync::mpsc::channel();
        let mut tracker = Tracker {
            next_id: 1,
            ..Default::default()
        };
        tracker.pending.insert(
            5_000_000_001,
            Pending {
                command: Command::PauseForQueue,
                reply: None,
                started: Instant::now(),
                revision: 0,
            },
        );
        let done =
            json!({"threadId":"native","objective":"finish","status":"complete","updatedAt":20});
        tracker
            .notification(
                &json!({"method":"thread/goal/updated","params":{"threadId":"native","goal":done}}),
                "native",
                &events,
            )
            .unwrap();
        tracker.response(&json!({"id":5_000_000_001u64,"result":{"goal":{"threadId":"native","objective":"finish","status":"paused","updatedAt":10}}}), "native", &events).unwrap();
        assert_eq!(tracker.goal.unwrap()["status"], "complete");
        received.recv().unwrap();
        match received.recv().unwrap() {
            Event::Goal {
                goal: Some(goal),
                queue_action,
                ..
            } => {
                assert_eq!(goal["status"], "complete");
                assert_eq!(queue_action, None);
            }
            _ => panic!("expected a goal state"),
        }
    }
}
