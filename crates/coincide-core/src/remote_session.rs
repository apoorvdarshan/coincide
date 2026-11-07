//! One phone's connection, as `RemoteSession.swift` runs it: authenticates the
//! phone, answers its requests through the adapter, and passes on what changes
//! in the threads it has open.
//!
//! Nothing but `hello` or `pair` is accepted until the phone has authenticated;
//! anything else, or no `hello` within `AUTHENTICATION_TIMEOUT`, closes the
//! connection. Changes are found by `refresh`, which the server calls at most
//! every `ITEM_INTERVAL` for transcripts and `WORKSPACE_INTERVAL` for the
//! sidebar, so streaming text goes out in batches.
use super::adapter::{Adapter, PendingRequest, Runs, remote_item};
use super::pairing::Pairing;
use super::protocol::{
    self, ClientMessage, Device, ErrorCode, PairResult, Presence, RemoteError, Request, ServerInfo,
};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, hash_map::DefaultHasher},
    hash::{Hash, Hasher},
    sync::Mutex,
    time::{Duration, Instant},
};
use uuid::Uuid;

pub const AUTHENTICATION_TIMEOUT: Duration = Duration::from_secs(10);
pub const ITEM_INTERVAL: Duration = Duration::from_millis(80);
pub const WORKSPACE_INTERVAL: Duration = Duration::from_millis(300);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum State {
    AwaitingAuthentication,
    Authenticated(String),
    Closed,
}

/// What the session needs from the server.
pub struct Context<'a> {
    pub adapter: &'a Adapter,
    pub pairing: &'a Mutex<Pairing>,
    pub server_info: &'a dyn Fn() -> ServerInfo,
}

/// What the phone was last sent of an open thread, to find what changed.
struct Mirror {
    items: Vec<(String, u64)>,
    turn: Value,
}

pub struct Session {
    state: State,
    peer: String,
    started: Instant,
    outbox: Vec<Value>,
    open: HashMap<Uuid, Mirror>,
    includes_archived: bool,
    last_workspace: Option<Value>,
    last_server: Option<Value>,
    /// What the phone last said about itself.
    pub presence: Option<Presence>,
    /// The device that just paired on this connection, for Settings to show.
    pub paired: Option<Device>,
}

/// An item's identity and contents, including whether its provider request is
/// still waiting, which changes how it's drawn without changing the document.
fn mirror_items(document: &Value, pending: &[PendingRequest]) -> Vec<(String, u64)> {
    document["items"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|item| {
            let mut hasher = DefaultHasher::new();
            item.to_string().hash(&mut hasher);
            let key = item["externalID"].as_str().unwrap_or_default();
            pending
                .iter()
                .any(|(request, _, _)| request == key)
                .hash(&mut hasher);
            (
                item["id"].as_str().unwrap_or_default().to_uppercase(),
                hasher.finish(),
            )
        })
        .collect()
}

fn pending_for<'a>(runs: &'a Runs, id: &str) -> &'a [PendingRequest] {
    runs.pending
        .get(&id.to_uppercase())
        .map(Vec::as_slice)
        .unwrap_or_default()
}

impl Session {
    pub fn new(peer: impl Into<String>) -> Self {
        Self {
            state: State::AwaitingAuthentication,
            peer: peer.into(),
            started: Instant::now(),
            outbox: Vec::new(),
            open: HashMap::new(),
            includes_archived: false,
            last_workspace: None,
            last_server: None,
            presence: None,
            paired: None,
        }
    }

    /// Counts the time to authenticate from when the connection arrived.
    pub fn start_clock(&mut self, started: Instant) {
        self.started = started;
    }

    pub fn state(&self) -> &State {
        &self.state
    }

    pub fn device_id(&self) -> Option<&str> {
        match &self.state {
            State::Authenticated(id) => Some(id),
            _ => None,
        }
    }

    pub fn is_closed(&self) -> bool {
        self.state == State::Closed
    }

    /// Messages to send, oldest first.
    pub fn take_outgoing(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.outbox)
    }

    pub fn close(&mut self) {
        self.state = State::Closed;
        self.open.clear();
    }

    /// Tells a phone whose pairing was revoked to forget it, and hangs up.
    pub fn revoke(&mut self) {
        self.send(protocol::event("revoked", None));
        self.close();
    }

    /// Closes a connection that hasn't authenticated in time.
    pub fn check_timeout(&mut self, now: Instant) {
        if self.state == State::AwaitingAuthentication
            && now.duration_since(self.started) >= AUTHENTICATION_TIMEOUT
        {
            self.fail(
                None,
                RemoteError::new(ErrorCode::Unauthorized, "Authentication timed out."),
                true,
            );
        }
    }

    fn send(&mut self, message: Value) {
        if self.state != State::Closed {
            self.outbox.push(message);
        }
    }

    fn respond(&mut self, id: &str, kind: &str, body: Option<Value>) {
        self.send(protocol::response(id, kind, body));
    }

    fn fail(&mut self, id: Option<&str>, error: RemoteError, closing: bool) {
        self.send(protocol::failure(id, &error));
        if closing {
            self.close();
        }
    }

    pub fn receive(&mut self, data: &[u8], context: &Context<'_>) {
        if self.is_closed() {
            return;
        }
        match ClientMessage::decode(data) {
            Ok(message) => self.handle(message, context),
            Err(failure) => {
                // Before authentication, anything unreadable ends the connection.
                let closing = self.state == State::AwaitingAuthentication;
                self.fail(failure.id.as_deref(), failure.error, closing);
            }
        }
    }

    fn handle(&mut self, message: ClientMessage, context: &Context<'_>) {
        let id = message.id.as_str();
        match (&self.state, message.request) {
            (State::AwaitingAuthentication, Request::Hello(hello)) => {
                let result = match context.pairing.lock() {
                    Ok(mut pairing) => {
                        pairing.authenticate(&hello.device_id, &hello.token, &self.peer)
                    }
                    Err(_) => Err(RemoteError::failed("Pairing is unavailable.")),
                };
                match result {
                    Ok(device) => {
                        self.state = State::Authenticated(device.id);
                        let info = (context.server_info)();
                        self.last_server = serde_json::to_value(&info).ok();
                        self.respond(id, "server", serde_json::to_value(info).ok());
                    }
                    Err(error) => self.fail(Some(id), error, true),
                }
            }
            (State::AwaitingAuthentication, Request::Pair(request)) => {
                let result = match context.pairing.lock() {
                    Ok(mut pairing) => {
                        pairing.pair(&request.secret, &request.device_name, &self.peer)
                    }
                    Err(_) => Err(RemoteError::failed("Pairing is unavailable.")),
                };
                match result {
                    Ok((device, token)) => {
                        self.state = State::Authenticated(device.id.clone());
                        let server = (context.server_info)();
                        self.last_server = serde_json::to_value(&server).ok();
                        let result = PairResult {
                            device_id: device.id.clone(),
                            token,
                            server,
                        };
                        self.respond(id, "paired", serde_json::to_value(result).ok());
                        self.paired = Some(device);
                    }
                    Err(error) => self.fail(Some(id), error, true),
                }
            }
            (State::AwaitingAuthentication, _) => self.fail(
                Some(id),
                RemoteError::new(ErrorCode::Unauthorized, "Pair this device first."),
                true,
            ),
            (State::Authenticated(_), Request::Hello(_) | Request::Pair(_)) => self.fail(
                Some(id),
                RemoteError::new(ErrorCode::BadRequest, "Already authenticated."),
                false,
            ),
            (State::Authenticated(_), request) => {
                if let Err(error) = self.perform(request, id, context) {
                    self.fail(Some(id), error, false);
                }
            }
            (State::Closed, _) => {}
        }
    }

    fn perform(
        &mut self,
        request: Request,
        id: &str,
        context: &Context<'_>,
    ) -> Result<(), RemoteError> {
        let adapter = context.adapter;
        let runs = || adapter.runs();
        match request {
            Request::Hello(_) | Request::Pair(_) => {}
            Request::Ping => self.respond(id, "ok", None),
            Request::Workspace { include_archived } => {
                self.includes_archived = include_archived;
                let workspace = serde_json::to_value(adapter.workspace(include_archived, &runs())?)
                    .map_err(|e| RemoteError::failed(e.to_string()))?;
                self.last_workspace = Some(workspace.clone());
                self.respond(id, "workspace", Some(workspace));
            }
            Request::OpenThread { thread_id, limit } => {
                let runs = runs();
                let (transcript, document) = adapter.transcript(thread_id, limit, &runs)?;
                self.open.insert(
                    thread_id,
                    Mirror {
                        items: mirror_items(&document, pending_for(&runs, &transcript.thread.id)),
                        turn: serde_json::to_value(&transcript.turn).unwrap_or_default(),
                    },
                );
                self.respond(id, "transcript", serde_json::to_value(transcript).ok());
            }
            Request::CloseThread { thread_id } => {
                self.open.remove(&thread_id);
                self.respond(id, "ok", None);
            }
            Request::LoadEarlier {
                thread_id,
                before_index,
                limit,
            } => {
                let page = adapter.items_before(thread_id, before_index, limit, &runs())?;
                self.respond(id, "items", serde_json::to_value(page).ok());
            }
            Request::MarkSeen { thread_id } => {
                if !adapter.has_thread(thread_id) {
                    return Err(RemoteError::thread_not_found());
                }
                return Err(RemoteError::unsupported("markSeen"));
            }
            Request::Send(send) => {
                let delivery = adapter.send(&send, &runs())?;
                self.respond(id, "delivery", Some(protocol::value_body(delivery)));
            }
            Request::RemoveQueued {
                thread_id,
                message_id,
            } => {
                adapter.remove_queued(thread_id, message_id)?;
                self.respond(id, "ok", None);
            }
            Request::Stop { thread_id } => {
                adapter.stop(thread_id, &runs())?;
                self.respond(id, "ok", None);
            }
            Request::Respond {
                thread_id,
                item_id,
                option_id,
                ..
            } => {
                adapter.respond(thread_id, item_id, &option_id, &runs())?;
                self.respond(id, "ok", None);
            }
            Request::Answer {
                thread_id,
                item_id,
                answers,
            } => {
                adapter.answer(thread_id, item_id, &answers, &runs())?;
                self.respond(id, "ok", None);
            }
            Request::NewThread { project_id } => {
                let thread = adapter.new_thread(project_id, &runs())?;
                self.respond(id, "thread", Some(protocol::value_body(thread)));
            }
            Request::ThreadAction { thread_id, action } => {
                adapter.perform(thread_id, &action)?;
                self.respond(id, "ok", None);
            }
            // No usage windows are shared with phones yet: an empty list, which the
            // phone shows as nothing to report.
            Request::UsageLimits => {
                self.respond(id, "usage", Some(protocol::value_body(Vec::<Value>::new())))
            }
            Request::Presence(presence) => {
                self.presence = Some(presence);
                self.respond(id, "ok", None);
            }
            // Only the computer's own command-line tool may open threads in its window.
            Request::ShowThread { .. } => return Err(RemoteError::unsupported("showThread")),
            Request::SteerQueued { .. } => return Err(RemoteError::unsupported("steerQueued")),
            Request::DismissQuestion { .. } => {
                return Err(RemoteError::unsupported("dismissQuestion"));
            }
            Request::Unimplemented(kind) => return Err(RemoteError::unsupported(&kind)),
        }
        Ok(())
    }

    /// Sends what changed since the phone last heard: open threads' items and
    /// turns always, the sidebar and server settings when `workspace` is due.
    pub fn refresh(&mut self, context: &Context<'_>, workspace: bool) {
        if self.device_id().is_none() {
            return;
        }
        let adapter = context.adapter;
        let runs = adapter.runs();
        if workspace {
            let info = serde_json::to_value((context.server_info)()).ok();
            if info.is_some() && info != self.last_server {
                self.last_server = info.clone();
                self.send(protocol::event("server", info));
            }
            if self.last_workspace.is_some()
                && let Ok(next) = adapter
                    .workspace(self.includes_archived, &runs)
                    .map(|w| serde_json::to_value(w).unwrap_or_default())
                && Some(&next) != self.last_workspace.as_ref()
            {
                self.last_workspace = Some(next.clone());
                self.send(protocol::event("workspace", Some(next)));
            }
        }
        let threads = self.open.keys().copied().collect::<Vec<_>>();
        for thread in threads {
            self.refresh_thread(thread, adapter, &runs);
        }
    }

    fn refresh_thread(&mut self, thread: Uuid, adapter: &Adapter, runs: &Runs) {
        let Some((id, document, _)) = adapter.snapshot(thread, runs) else {
            self.open.remove(&thread);
            self.send(protocol::event(
                "threadRemoved",
                Some(protocol::value_body(thread.to_string().to_uppercase())),
            ));
            return;
        };
        let pending = pending_for(runs, &id);
        let items = mirror_items(&document, pending);
        let Some(mirror) = self.open.get(&thread) else {
            return;
        };
        let reordered = items.len() < mirror.items.len()
            || mirror
                .items
                .iter()
                .zip(&items)
                .any(|(old, new)| old.0 != new.0);
        let turn =
            serde_json::to_value(adapter.turn_state(&id, &document, runs)).unwrap_or_default();
        let turn_changed = turn != mirror.turn;
        if reordered {
            // Rewound or reloaded: the whole transcript again.
            if let Ok((transcript, _)) = adapter.transcript(thread, 200, runs) {
                self.send(protocol::event(
                    "transcript",
                    serde_json::to_value(transcript).ok(),
                ));
            }
        } else {
            let all = document["items"].as_array().cloned().unwrap_or_default();
            let changed = items
                .iter()
                .enumerate()
                .filter(|(index, item)| mirror.items.get(*index) != Some(item))
                .map(|(index, _)| remote_item(&all[index], index, pending))
                .collect::<Vec<_>>();
            if !changed.is_empty() {
                self.send(protocol::event(
                    "items",
                    Some(json!({"threadID":id.to_uppercase(),"items":changed,"count":items.len()})),
                ));
            }
        }
        if turn_changed {
            self.send(protocol::event(
                "turn",
                Some(json!({"threadID":id.to_uppercase(),"state":turn})),
            ));
        }
        if let Some(mirror) = self.open.get_mut(&thread) {
            mirror.items = items;
            mirror.turn = turn;
        }
    }
}
