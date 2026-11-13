//! One in-flight, source-bound Codex steering request with prepared images. No fallback send.
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc, Mutex,
        mpsc::{self, Receiver, SyncSender, TryRecvError},
    },
    time::{Duration, Instant},
};
use uuid::Uuid;
#[derive(Clone, Default)]
struct View {
    identity: Option<(String, String)>,
    assistant: Option<String>,
}
#[derive(Clone)]
pub(crate) struct Client {
    view: Arc<Mutex<View>>,
    commands: SyncSender<Command>,
}
struct Command {
    identity: (String, String),
    input: Vec<Value>,
    reply: SyncSender<Outcome>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Outcome {
    Accepted,
    Rejected,
    Unknown,
}
pub(crate) struct Ticket {
    pub receiver: Receiver<Outcome>,
}
struct Pending {
    id: String,
    identity: (String, String),
    reply: SyncSender<Outcome>,
    started: Instant,
}
pub(crate) struct Server {
    view: Arc<Mutex<View>>,
    commands: Receiver<Command>,
    pending: Option<Pending>,
    retired: Vec<String>,
}
pub(crate) fn pair() -> (Client, Server) {
    let view = Arc::new(Mutex::new(View::default()));
    let (commands, receiver) = mpsc::sync_channel(1);
    (
        Client {
            view: view.clone(),
            commands,
        },
        Server {
            view,
            commands: receiver,
            pending: None,
            retired: Vec::new(),
        },
    )
}
impl Client {
    pub(crate) fn can_submit(&self) -> bool {
        self.view
            .try_lock()
            .is_ok_and(|view| view.identity.is_some() && view.assistant.is_none())
    }
    pub(crate) fn identity(&self) -> Result<(String, String)> {
        let view = self
            .view
            .try_lock()
            .map_err(|_| anyhow::anyhow!("Steering state is busy or unavailable"))?;
        ensure!(
            view.assistant.is_none(),
            "Wait for the current assistant message to finish before steering"
        );
        view.identity.clone().ok_or_else(|| {
            anyhow::anyhow!("Codex has no acknowledged active turn available for steering")
        })
    }
    #[cfg(test)]
    pub(crate) fn submit(&self, text: &str) -> Result<Ticket> {
        self.submit_exact(text, &self.identity()?)
    }
    #[cfg(test)]
    pub(crate) fn submit_exact(&self, text: &str, expected: &(String, String)) -> Result<Ticket> {
        ensure!(
            !text.trim().is_empty() && text.len() <= 1024 * 1024,
            "Steering text must be nonempty and fit within 1 MiB"
        );
        self.submit_input_exact(text, &[], expected)
    }
    pub(crate) fn submit_input_exact(
        &self,
        text: &str,
        images: &[super::ImageAttachment],
        expected: &(String, String),
    ) -> Result<Ticket> {
        super::validate_images(&super::Provider::from_name("codex")?, images)?;
        ensure!(
            (!text.trim().is_empty() || !images.is_empty()) && text.len() <= 2 * 1024 * 1024,
            "Prepared steering input exceeds safe limits"
        );
        let identity = self.identity()?;
        ensure!(
            &identity == expected,
            "Acknowledged steering turn changed before delivery"
        );
        let mut input = Vec::new();
        if !text.is_empty() {
            input.push(json!({"type":"text","text":text}));
        }
        input.extend(
            images
                .iter()
                .map(|image| json!({"type":"localImage","path":image.path()})),
        );
        let (reply, receiver) = mpsc::sync_channel(1);
        self.commands
            .try_send(Command {
                identity,
                input,
                reply,
            })
            .map_err(|_| anyhow::anyhow!("Codex steering is busy or unavailable"))?;
        Ok(Ticket { receiver })
    }
}
impl Server {
    pub(crate) fn activate(&mut self, thread: &str, turn: &str) {
        if let Ok(mut view) = self.view.lock() {
            view.identity = Some((thread.into(), turn.into()));
            view.assistant = None;
        }
    }
    pub(crate) fn observe(&mut self, frame: &Value) {
        let p = &frame["params"];
        let Ok(mut view) = self.view.lock() else {
            return;
        };
        let Some((thread, turn)) = &view.identity else {
            return;
        };
        if p["threadId"] != thread.as_str() || p["turnId"] != turn.as_str() {
            return;
        }
        match frame["method"].as_str() {
            Some("item/agentMessage/delta") => {
                view.assistant = Some(p["itemId"].as_str().unwrap_or("").to_owned());
            }
            Some("item/started") => {
                if p["item"]["type"] == "agentMessage" {
                    view.assistant = Some(p["item"]["id"].as_str().unwrap_or("").to_owned());
                }
            }
            Some("item/completed") if view.assistant.as_deref() == p["item"]["id"].as_str() => {
                view.assistant = None;
            }
            _ => {}
        }
    }
    pub(crate) fn next_request(&mut self) -> Option<Value> {
        if self
            .pending
            .as_ref()
            .is_some_and(|p| p.started.elapsed() >= Duration::from_secs(30))
        {
            let pending = self.pending.take().unwrap();
            self.retired.push(pending.id);
            if self.retired.len() > 32 {
                self.retired.remove(0);
            }
            let _ = pending.reply.try_send(Outcome::Unknown);
        }
        let command = match self.commands.try_recv() {
            Ok(command) => command,
            Err(TryRecvError::Empty | TryRecvError::Disconnected) => return None,
        };
        let valid = self.view.lock().is_ok_and(|view| {
            view.identity.as_ref() == Some(&command.identity) && view.assistant.is_none()
        });
        if !valid || self.pending.is_some() {
            let _ = command.reply.try_send(Outcome::Rejected);
            return None;
        }
        let id = Uuid::new_v4().to_string();
        let request = json!({"id":id,"method":"turn/steer","params":{"threadId":command.identity.0,"expectedTurnId":command.identity.1,"input":command.input}});
        self.pending = Some(Pending {
            id,
            identity: command.identity,
            reply: command.reply,
            started: Instant::now(),
        });
        Some(request)
    }
    pub(crate) fn response(&mut self, frame: &Value) -> bool {
        if frame.get("method").is_some() {
            return false;
        }
        if frame["id"]
            .as_str()
            .is_some_and(|id| self.retired.iter().any(|old| old == id))
        {
            return true;
        }
        if !self
            .pending
            .as_ref()
            .is_some_and(|p| frame["id"].as_str() == Some(p.id.as_str()))
        {
            // The client generates UUIDs only for steering requests. An
            // expired response may arrive after its bounded retirement entry
            // was evicted; it is still an owned reply, not a startup failure.
            return frame["id"]
                .as_str()
                .is_some_and(|id| Uuid::parse_str(id).is_ok());
        }
        let pending = self.pending.take().unwrap();
        self.retired.push(pending.id);
        if self.retired.len() > 32 {
            self.retired.remove(0);
        }
        let outcome = if frame.get("error").is_some() {
            Outcome::Rejected
        } else if frame["result"]["turnId"] == pending.identity.1 {
            Outcome::Accepted
        } else {
            Outcome::Unknown
        };
        let _ = pending.reply.try_send(outcome);
        true
    }
    pub(crate) fn close(&mut self) {
        if let Ok(mut view) = self.view.lock() {
            view.identity = None;
            view.assistant = None;
        }
        if let Some(pending) = self.pending.take() {
            let _ = pending.reply.try_send(Outcome::Unknown);
        }
        while let Ok(command) = self.commands.try_recv() {
            let _ = command.reply.try_send(Outcome::Rejected);
        }
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.close();
    }
}

#[cfg(test)]
#[path = "codex_steering_tests.rs"]
mod tests;
