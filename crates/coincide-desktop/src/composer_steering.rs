//! Explicit Codex text steering controller. This model never changes a draft,
//! queues a follow-up, or treats local admission as provider acceptance.
use crate::worker_owner::{ShutdownStatus, WorkerOwner};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc,
        mpsc::{self, Receiver},
    },
    time::{Duration, Instant},
};

type Backend = Arc<dyn Fn(&str, &Value) -> Result<Value, String> + Send + Sync>;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Submitting,
    Pending,
    Accepted,
    Rejected,
    Unknown,
    Error,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MessageView {
    pub thread_id: String,
    pub phase: Phase,
    pub message: String,
    /// All outcomes retain the original editor draft; acceptance never clears it.
    pub draft_retained: bool,
}
struct Pending {
    thread: String,
    id: String,
}
enum Call {
    Submit { thread: String, text: String },
    Poll { thread: String, id: String },
}
struct Reply {
    call: Call,
    result: Result<Value, String>,
}
pub struct SteeringController {
    backend: Backend,
    owner: WorkerOwner,
    reply: Option<Receiver<Reply>>,
    pending: Option<Pending>,
    view: Option<MessageView>,
    blocked: HashMap<String, String>,
    last_poll: Instant,
}
impl SteeringController {
    fn with_backend(backend: Backend) -> Self {
        Self {
            backend,
            owner: WorkerOwner::default(),
            reply: None,
            pending: None,
            view: None,
            blocked: HashMap::new(),
            last_poll: Instant::now() - Duration::from_secs(1),
        }
    }
    pub fn observe_draft(&mut self, thread: &str, text: &str) {
        if self
            .blocked
            .get(thread)
            .is_some_and(|submitted| submitted != text)
        {
            self.blocked.remove(thread);
        }
    }
    pub fn status(&self, thread: &str) -> Option<&MessageView> {
        self.view.as_ref().filter(|view| view.thread_id == thread)
    }
    pub fn can_submit(&mut self, thread: &str, text: &str, provider: &str, running: bool) -> bool {
        self.owner.can_start()
            && self.reply.is_none()
            && self.pending.is_none()
            && provider == "codex"
            && running
            && !text.trim().is_empty()
            && text.len() <= 1024 * 1024
            && !self
                .blocked
                .get(thread)
                .is_some_and(|submitted| submitted == text)
            && (self.blocked.len() < 32 || self.blocked.contains_key(thread))
    }
    pub fn submit(&mut self, thread: &str, text: &str, provider: &str, running: bool) -> bool {
        if !self.can_submit(thread, text, provider, running) {
            return false;
        }
        let call = Call::Submit {
            thread: thread.into(),
            text: text.into(),
        };
        if !self.start(call) {
            return false;
        }
        self.blocked.insert(thread.into(), text.into());
        self.set_view(
            thread,
            Phase::Submitting,
            "Submitting steering request. Draft retained.",
        );
        true
    }
    fn set_view(&mut self, thread: &str, phase: Phase, message: &str) {
        self.view = Some(MessageView {
            thread_id: thread.into(),
            phase,
            message: message.chars().take(1024).collect(),
            draft_retained: true,
        });
    }
    fn start(&mut self, call: Call) -> bool {
        if self.reply.is_some() || !self.owner.can_start() {
            return false;
        }
        let backend = self.backend.clone();
        let (tx, rx) = mpsc::sync_channel(1);
        if !self.owner.spawn(move |admission| {
            if !admission.allowed() {
                return;
            }
            let result = match &call {
                Call::Submit { thread, text } => {
                    backend("agent.steer", &json!({"threadId":thread,"text":text}))
                }
                Call::Poll { thread, id } => backend(
                    "agent.steer.result",
                    &json!({"threadId":thread,"operationId":id}),
                ),
            };
            if admission.allowed() {
                let _ = tx.try_send(Reply { call, result });
            }
        }) {
            return false;
        }
        self.reply = Some(rx);
        true
    }
    /// Native tick calls this without holding Engine. An outstanding operation
    /// remains scoped to its original thread even when the visible thread changes.
    pub fn poll(&mut self) -> bool {
        self.owner.poll();
        if self.owner.closed() {
            self.reply = None;
            return false;
        }
        let received = self.reply.as_ref().map(|rx| rx.try_recv());
        let disconnected = matches!(&received, Some(Err(mpsc::TryRecvError::Disconnected)));
        let reply = received.and_then(Result::ok);
        let mut changed = false;
        if let Some(reply) = reply {
            self.reply = None;
            changed = true;
            match reply.call {
                Call::Submit { thread, text: _ } => match reply.result {
                    Ok(value)
                        if value["threadId"] == thread
                            && value["status"] == "pending"
                            && value["operationId"]
                                .as_str()
                                .is_some_and(|id| uuid::Uuid::parse_str(id).is_ok()) =>
                    {
                        self.pending = Some(Pending {
                            thread: thread.clone(),
                            id: value["operationId"].as_str().unwrap().into(),
                        });
                        self.set_view(
                            &thread,
                            Phase::Pending,
                            "Waiting for Codex acknowledgement. Draft retained.",
                        );
                    }
                    Ok(_) => {
                        self.set_view(&thread,Phase::Unknown,"Steering admission could not be confirmed. Draft retained; do not automatically resend.");
                    }
                    Err(error) => {
                        self.set_view(&thread, Phase::Error, &format!("{error}. Draft retained."));
                    }
                },
                Call::Poll { thread, id } => {
                    let scoped = self
                        .pending
                        .as_ref()
                        .is_some_and(|op| op.thread == thread && op.id == id);
                    if scoped {
                        match reply.result {
                        Ok(value) if value["threadId"]==thread&&value["operationId"]==id=>{
                            match value["status"].as_str() {
                                Some("accepted") if value["persisted"]==true=>{self.pending=None;self.set_view(&thread,Phase::Accepted,"Codex accepted the message for this turn. Draft retained; change or clear it before steering again.");},
                                Some("rejected")=>{self.pending=None;self.set_view(&thread,Phase::Rejected,"Codex did not accept the message. Draft retained.");},
                                Some("unknown")=>{self.pending=None;self.set_view(&thread,Phase::Unknown,"Delivery is unknown. Draft retained; do not automatically resend.");},
                                Some("accepted_pending_persistence")=>self.set_view(&thread,Phase::Pending,"Codex accepted the message; saving it is still pending. Draft retained."),
                                Some("pending")=>{},
                                _=>self.set_view(&thread,Phase::Pending,"Waiting for a valid scoped steering result. Draft retained."),
                            }
                        },
                        _=>self.set_view(&thread,Phase::Pending,"Steering status is temporarily unavailable. Draft retained."),
                    }
                    }
                }
            }
        } else if disconnected {
            self.reply = None;
            changed = true;
            if let Some(thread) = self.view.as_ref().map(|view| view.thread_id.clone()) {
                self.set_view(
                    &thread,
                    if self.pending.is_some() {
                        Phase::Pending
                    } else {
                        Phase::Unknown
                    },
                    "Steering status is unavailable. Draft retained.",
                );
            }
        }
        if self.reply.is_none()
            && self.last_poll.elapsed() >= Duration::from_millis(250)
            && let Some(pending) = &self.pending
        {
            let call = Call::Poll {
                thread: pending.thread.clone(),
                id: pending.id.clone(),
            };
            if self.start(call) {
                self.last_poll = Instant::now();
            }
        }
        changed
    }
    pub fn request_shutdown(&mut self) {
        self.owner.close();
        self.reply = None;
        // Core owns any admitted operation and continues its actual ACK/Store
        // drain. Closing this UI observer does not cancel or certify delivery.
    }
    pub fn shutdown_status(&mut self) -> ShutdownStatus {
        self.owner.status()
    }
}

#[cfg(test)]
#[path = "composer_steering_tests.rs"]
mod tests;
