//! Coincide Remote's view of the app, as `RemoteStoreAdapter.swift` gives it:
//! turns the engine's threads, projects and runs into the protocol's models, and
//! carries out what the phone asks through the same engine commands the
//! desktop's own controls use. The engine stays the only source of truth; the
//! adapter keeps only a cache of per-thread fields the sidebar summary needs.
use super::protocol::{
    Approval, ApprovalOption, Delivery, ErrorCode, Item, ItemPage, Project, Question,
    QuestionOption, QuestionSet, QueuedMessage, RemoteError, Script, Selection, SendRequest,
    ServerInfo, ThemeInfo, ThreadAction, ThreadSummary, Transcript, TurnState, Workspace,
};
use crate::api::{SharedEngine, call};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    sync::Mutex,
};
use uuid::Uuid;

/// Largest tool output and input sent per item; the rest stays on the computer.
pub const MAX_TOOL_TEXT: usize = 6_000;
pub const MAX_TOOL_DETAIL: usize = 8_000;
/// Threads outside any project live in the sidebar's Chats.
const NO_PROJECT: &str = "00000000-0000-0000-0000-000000000000";
const SWIFT_EPOCH: f64 = 978_307_200.;

/// Milliseconds since 1970 from a stored date: Swift reference-date seconds, or
/// an RFC 3339 string in imported documents.
pub fn stored_date_ms(value: &Value) -> Option<f64> {
    if let Some(seconds) = value.as_f64().filter(|n| n.is_finite()) {
        return Some((seconds + SWIFT_EPOCH) * 1000.);
    }
    chrono::DateTime::parse_from_rfc3339(value.as_str()?)
        .ok()
        .map(|date| date.timestamp_millis() as f64)
}

/// Swift reference-date seconds from milliseconds since 1970.
pub fn swift_seconds(ms: f64) -> f64 {
    ms / 1000. - SWIFT_EPOCH
}

/// The fields of a thread document the sidebar needs, cached by its summary.
#[derive(Clone, Debug, PartialEq)]
struct ThreadFields {
    created_at: f64,
    updated_at: f64,
    selection: Value,
    access_mode: String,
    interaction_mode: String,
    branch: Option<String>,
    has_worktree: bool,
    has_draft: bool,
    item_count: usize,
    queued: usize,
}

/// A pending provider request: its id, method and parameters.
pub type PendingRequest = (String, String, Value);

/// The engine's run state, read once per snapshot.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Runs {
    pub running: HashSet<String>,
    /// Pending provider requests by thread: (request id, method, params).
    pub pending: HashMap<String, Vec<PendingRequest>>,
}

pub struct Adapter {
    engine: SharedEngine,
    app_version: String,
    cache: Mutex<HashMap<String, (Value, ThreadFields)>>,
}

fn failed(error: anyhow::Error) -> RemoteError {
    RemoteError::failed(error.to_string())
}

fn upper(id: &str) -> String {
    id.to_uppercase()
}

impl Adapter {
    pub fn new(engine: SharedEngine, app_version: impl Into<String>) -> Self {
        Self {
            engine,
            app_version: app_version.into(),
            cache: Mutex::new(HashMap::new()),
        }
    }

    pub fn engine(&self) -> &SharedEngine {
        &self.engine
    }

    fn call(&self, method: &str, params: Value) -> Result<Value, RemoteError> {
        call(&self.engine, method, params).map_err(failed)
    }

    /// The engine's revision, polling it first so runs progress even while no
    /// window is drawing.
    pub fn revision(&self) -> Option<u64> {
        self.call("app.status", json!({})).ok()?["revision"].as_u64()
    }

    pub fn server_info(&self, server_id: &str, name: &str) -> ServerInfo {
        let settings = self.call("settings.read", json!({})).unwrap_or_default();
        let string = |key: &str, fallback: &str| {
            settings[key]
                .as_str()
                .filter(|s| !s.is_empty())
                .unwrap_or(fallback)
                .to_owned()
        };
        ServerInfo {
            server_id: server_id.into(),
            name: name.into(),
            app_version: self.app_version.clone(),
            protocol_version: super::protocol::VERSION,
            theme: ThemeInfo {
                appearance: string("appearance", "system"),
                dark_theme_id: string("darkTheme", "carbon"),
                light_theme_id: string("lightTheme", "carbon-light"),
            },
            shows_reasoning: settings["showReasoning"].as_bool().unwrap_or(true),
            follow_up_behavior: string("followUpBehavior", "steer"),
            notifies: None,
            reply_typeface: Some(string("replyTypeface", "newYork")),
            user_message_side: Some(string("userMessageSide", "right")),
        }
    }

    pub fn runs(&self) -> Runs {
        let mut runs = Runs::default();
        let Ok(status) = self.call("app.status", json!({})) else {
            return runs;
        };
        for id in status["running"].as_array().into_iter().flatten() {
            let Some(id) = id.as_str() else { continue };
            runs.running.insert(upper(id));
            if let Ok(pending) = self.call("agent.pending", json!({"threadId":id})) {
                runs.pending.insert(
                    upper(id),
                    pending
                        .as_array()
                        .into_iter()
                        .flatten()
                        .map(|request| {
                            (
                                request["requestId"].as_str().unwrap_or_default().to_owned(),
                                request["method"].as_str().unwrap_or_default().to_owned(),
                                request["params"].clone(),
                            )
                        })
                        .collect(),
                );
            }
        }
        runs
    }

    fn fields(document: &Value) -> ThreadFields {
        let queued = crate::message_queue::read(document)
            .map(|messages| {
                messages
                    .iter()
                    .filter(|m| m.state == crate::message_queue::State::Pending)
                    .count()
            })
            .unwrap_or(0);
        ThreadFields {
            created_at: stored_date_ms(&document["createdAt"]).unwrap_or(0.),
            updated_at: stored_date_ms(&document["updatedAt"]).unwrap_or(0.),
            selection: document["selection"].clone(),
            access_mode: document["accessMode"]
                .as_str()
                .unwrap_or("approval")
                .to_owned(),
            interaction_mode: document["interactionMode"]
                .as_str()
                .unwrap_or("build")
                .to_owned(),
            branch: document["branch"].as_str().map(str::to_owned),
            has_worktree: document["worktreePath"].as_str().is_some(),
            has_draft: document["draft"]
                .as_str()
                .is_some_and(|d| !d.trim().is_empty()),
            item_count: document["items"].as_array().map_or(0, Vec::len),
            queued,
        }
    }

    /// The thread document's sidebar fields, read again only when its summary
    /// changed or it's running (streaming changes the document, not the title).
    fn cached_fields(&self, summary: &Value, runs: &Runs) -> Option<ThreadFields> {
        let id = summary["id"].as_str()?;
        let key = upper(id);
        let mut cache = self.cache.lock().ok()?;
        if !runs.running.contains(&key)
            && let Some((seen, fields)) = cache.get(&key)
            && seen == summary
        {
            return Some(fields.clone());
        }
        let document = self.call("threads.read", json!({"threadId":id})).ok()?;
        let fields = Self::fields(&document);
        cache.insert(key, (summary.clone(), fields.clone()));
        Some(fields)
    }

    fn selection(selection: &Value) -> Selection {
        let model_id = selection["modelID"]
            .as_str()
            .unwrap_or("default")
            .to_owned();
        let string = |key: &str| selection[key].as_str().map(str::to_owned);
        Selection {
            provider: selection["provider"].as_str().unwrap_or("codex").to_owned(),
            model_name: if model_id == "default" {
                "Default".into()
            } else {
                model_id.clone()
            },
            model_id,
            effort: string("effort"),
            speed: string("speed"),
            account_id: string("accountID"),
            account_name: None,
        }
    }

    fn summary(
        summary: &Value,
        fields: &ThreadFields,
        project_id: &str,
        runs: &Runs,
    ) -> ThreadSummary {
        let id = upper(summary["id"].as_str().unwrap_or_default());
        let pending = runs.pending.get(&id).map(Vec::as_slice).unwrap_or_default();
        let questions = pending
            .iter()
            .filter(|(_, method, _)| method == "item/tool/requestUserInput")
            .count();
        let snoozed_until = summary["snoozed_until"].as_f64().map(|unix| unix * 1000.);
        ThreadSummary {
            project_id: upper(project_id),
            title: summary["title"].as_str().unwrap_or_default().to_owned(),
            created_at: fields.created_at,
            updated_at: fields.updated_at,
            selection: Self::selection(&fields.selection),
            access_mode: fields.access_mode.clone(),
            interaction_mode: fields.interaction_mode.clone(),
            is_pinned: summary["pinned"] == true,
            is_archived: summary["archived"] == true,
            snoozed_until,
            is_settled: false,
            is_hidden: snoozed_until.is_some_and(|until| until > super::pairing::now_ms()),
            branch: fields.branch.clone(),
            has_worktree: fields.has_worktree,
            is_running: runs.running.contains(&id),
            is_starting: false,
            pending_approvals: pending.len() - questions,
            pending_questions: questions,
            unseen: None,
            queued_messages: fields.queued,
            has_draft: fields.has_draft,
            item_count: fields.item_count,
            running_since: None,
            id,
        }
    }

    /// Projects in the sidebar's order with Chats last, and every thread in
    /// them, most recently active first.
    pub fn workspace(&self, include_archived: bool, runs: &Runs) -> Result<Workspace, RemoteError> {
        let stored = self.call("projects.list", json!({}))?;
        let chats_id = stored
            .as_array()
            .into_iter()
            .flatten()
            .find(|p| p["isChats"] == true)
            .and_then(|p| p["id"].as_str())
            .unwrap_or(NO_PROJECT)
            .to_uppercase();
        let home = home_directory();
        let mut projects = stored
            .as_array()
            .into_iter()
            .flatten()
            .filter(|p| p["isChats"] != true && p["isBots"] != true)
            .filter(|p| {
                !p["id"]
                    .as_str()
                    .is_some_and(|id| id.eq_ignore_ascii_case(crate::bot_runtime::BOTS_PROJECT_ID))
            })
            .filter_map(|p| {
                Some(Project {
                    id: upper(p["id"].as_str()?),
                    name: p["name"].as_str().unwrap_or("Project").to_owned(),
                    path: abbreviate(p["path"].as_str().unwrap_or_default(), home.as_deref()),
                    is_chats: false,
                    scripts: p["scripts"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|s| {
                            Some(Script {
                                id: upper(s["id"].as_str()?),
                                name: s["name"].as_str().unwrap_or_default().to_owned(),
                                command: s["command"].as_str().unwrap_or_default().to_owned(),
                                icon: s["icon"].as_str().unwrap_or("play").to_owned(),
                            })
                        })
                        .collect(),
                    is_expanded: Some(p["isExpanded"].as_bool().unwrap_or(true)),
                })
            })
            .collect::<Vec<_>>();
        let chats_path = stored
            .as_array()
            .into_iter()
            .flatten()
            .find(|p| p["isChats"] == true)
            .and_then(|p| p["path"].as_str())
            .map(|path| abbreviate(path, home.as_deref()))
            .unwrap_or_else(|| "~".into());
        projects.push(Project {
            id: chats_id.clone(),
            name: "Chats".into(),
            path: chats_path,
            is_chats: true,
            scripts: Vec::new(),
            is_expanded: None,
        });
        let known = projects
            .iter()
            .map(|p| p.id.clone())
            .collect::<HashSet<_>>();
        let summaries = self.call("threads.list", json!({"includeArchived":include_archived}))?;
        let mut threads = Vec::new();
        let mut seen = HashSet::new();
        for summary in summaries.as_array().into_iter().flatten() {
            let project = upper(summary["project_id"].as_str().unwrap_or_default());
            if project.eq_ignore_ascii_case(crate::bot_runtime::BOTS_PROJECT_ID) {
                continue;
            }
            let project = if known.contains(&project) {
                project
            } else {
                chats_id.clone()
            };
            if let Some(fields) = self.cached_fields(summary, runs) {
                seen.insert(upper(summary["id"].as_str().unwrap_or_default()));
                threads.push(Self::summary(summary, &fields, &project, runs));
            }
        }
        if let Ok(mut cache) = self.cache.lock() {
            cache.retain(|id, _| seen.contains(id));
        }
        // Grouped by the projects' order, most recent activity first in each.
        let order = projects
            .iter()
            .enumerate()
            .map(|(index, p)| (p.id.clone(), index))
            .collect::<HashMap<_, _>>();
        threads.sort_by(|a, b| {
            order[&a.project_id]
                .cmp(&order[&b.project_id])
                .then(b.updated_at.total_cmp(&a.updated_at))
        });
        let pinned_order = threads
            .iter()
            .filter(|t| t.is_pinned)
            .map(|t| t.id.clone())
            .collect();
        Ok(Workspace {
            projects,
            threads,
            providers: Vec::new(),
            sections: vec!["pinned".into(), "projects".into(), "chats".into()],
            pinned_order,
        })
    }

    fn document(&self, thread: Uuid) -> Result<(String, Value), RemoteError> {
        // The stored id keeps its own spelling; the phone's may differ in case.
        let resolved = self
            .call("threads.resolve_id", json!({"threadId":thread.to_string()}))
            .map_err(|_| RemoteError::thread_not_found())?;
        let id = resolved["threadId"]
            .as_str()
            .ok_or_else(RemoteError::thread_not_found)?
            .to_owned();
        let document = self
            .call("threads.read", json!({"threadId":id}))
            .map_err(|_| RemoteError::thread_not_found())?;
        Ok((id, document))
    }

    pub fn has_thread(&self, thread: Uuid) -> bool {
        self.document(thread).is_ok()
    }

    /// The thread's summary as the sidebar would list it.
    fn thread_summary(&self, id: &str, document: &Value, runs: &Runs) -> ThreadSummary {
        let summary = json!({
            "id": id,
            "title": document["title"],
            "project_id": document["projectID"],
            "pinned": document["isPinned"] == true,
            "archived": document["isArchived"] == true,
            "snoozed_until": document["snoozedUntil"].as_f64().map(|s| s + SWIFT_EPOCH),
        });
        let project = document["projectID"].as_str().unwrap_or(NO_PROJECT);
        Self::summary(&summary, &Self::fields(document), project, runs)
    }

    pub fn turn_state(&self, id: &str, document: &Value, runs: &Runs) -> TurnState {
        let running = runs.running.contains(&upper(id));
        TurnState {
            is_running: running,
            is_starting: false,
            started_at: None,
            provider: running
                .then(|| {
                    document["selection"]["provider"]
                        .as_str()
                        .map(str::to_owned)
                })
                .flatten(),
            can_steer: running,
            queued: crate::message_queue::read(document)
                .unwrap_or_default()
                .into_iter()
                .filter(|m| m.state == crate::message_queue::State::Pending)
                .map(|m| QueuedMessage {
                    id: m.id.to_uppercase(),
                    text: m.text,
                    image_count: m.images.len(),
                })
                .collect(),
        }
    }

    /// The thread's newest `limit` items with its turn state.
    pub fn transcript(
        &self,
        thread: Uuid,
        limit: i64,
        runs: &Runs,
    ) -> Result<(Transcript, Value), RemoteError> {
        let (id, document) = self.document(thread)?;
        let items = document["items"].as_array().cloned().unwrap_or_default();
        let limit = limit.clamp(1, 1_000) as usize;
        let start = items.len().saturating_sub(limit);
        let pending = runs.pending.get(&upper(&id)).cloned().unwrap_or_default();
        let remote = items[start..]
            .iter()
            .enumerate()
            .map(|(offset, item)| remote_item(item, start + offset, &pending))
            .collect();
        Ok((
            Transcript {
                thread: self.thread_summary(&id, &document, runs),
                items: remote,
                has_earlier: start > 0,
                turn: self.turn_state(&id, &document, runs),
                turn_changes: BTreeMap::new(),
            },
            document,
        ))
    }

    pub fn items_before(
        &self,
        thread: Uuid,
        before: i64,
        limit: i64,
        runs: &Runs,
    ) -> Result<ItemPage, RemoteError> {
        let (id, document) = self.document(thread)?;
        let items = document["items"].as_array().cloned().unwrap_or_default();
        let end = (before.max(0) as usize).min(items.len());
        let start = end.saturating_sub(limit.clamp(1, 1_000) as usize);
        let pending = runs.pending.get(&upper(&id)).cloned().unwrap_or_default();
        Ok(ItemPage {
            items: items[start..end]
                .iter()
                .enumerate()
                .map(|(offset, item)| remote_item(item, start + offset, &pending))
                .collect(),
            has_earlier: start > 0,
        })
    }

    /// Reads a thread for change tracking: its id, document and summary.
    pub fn snapshot(&self, thread: Uuid, runs: &Runs) -> Option<(String, Value, ThreadSummary)> {
        let (id, document) = self.document(thread).ok()?;
        let summary = self.thread_summary(&id, &document, runs);
        Some((id, document, summary))
    }

    fn waiting_item(
        &self,
        thread: Uuid,
        item: Uuid,
        kind: &str,
        runs: &Runs,
    ) -> Result<(String, Value, Vec<PendingRequest>), RemoteError> {
        let (id, document) = self.document(thread)?;
        let found = document["items"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|i| {
                i["id"].as_str().and_then(|v| Uuid::parse_str(v).ok()) == Some(item)
                    && i["kind"] == kind
            })
            .cloned()
            .ok_or_else(|| {
                RemoteError::new(ErrorCode::NotFound, "That request no longer exists.")
            })?;
        let pending = runs.pending.get(&upper(&id)).cloned().unwrap_or_default();
        let key = found["externalID"].as_str().unwrap_or_default();
        if !pending.iter().any(|(request, _, _)| request == key) {
            return Err(RemoteError::new(
                ErrorCode::NotAllowed,
                "That request was already answered.",
            ));
        }
        Ok((id, found, pending))
    }

    pub fn respond(
        &self,
        thread: Uuid,
        item: Uuid,
        option: &str,
        runs: &Runs,
    ) -> Result<(), RemoteError> {
        let (id, found, pending) = self.waiting_item(thread, item, "approval", runs)?;
        let key = found["externalID"].as_str().unwrap_or_default();
        let params = pending
            .iter()
            .find(|(request, _, _)| request == key)
            .map(|(_, _, params)| params.clone())
            .unwrap_or_default();
        if !approval_options(&params).iter().any(|o| o.id == option) {
            return Err(RemoteError::new(
                ErrorCode::BadRequest,
                "That choice isn’t offered.",
            ));
        }
        self.call(
            "agent.respond",
            json!({"threadId":id,"requestId":key,"decision":option}),
        )
        .map(|_| ())
    }

    pub fn answer(
        &self,
        thread: Uuid,
        item: Uuid,
        answers: &BTreeMap<String, Vec<String>>,
        runs: &Runs,
    ) -> Result<(), RemoteError> {
        let (id, found, _) = self.waiting_item(thread, item, "question", runs)?;
        let answers = answers
            .iter()
            .map(|(question, values)| (question.clone(), json!({"answers":values})))
            .collect::<serde_json::Map<_, _>>();
        self.call(
            "agent.answer",
            json!({"threadId":id,"requestId":found["externalID"],"answers":answers}),
        )
        .map(|_| ())
    }

    pub fn stop(&self, thread: Uuid, runs: &Runs) -> Result<(), RemoteError> {
        let (id, _) = self.document(thread)?;
        if runs.running.contains(&upper(&id)) {
            self.call("agent.stop", json!({"threadId":id}))?;
        }
        Ok(())
    }

    pub fn remove_queued(&self, thread: Uuid, message: Uuid) -> Result<(), RemoteError> {
        let (id, document) = self.document(thread)?;
        let Some(stored) = crate::message_queue::read(&document)
            .unwrap_or_default()
            .into_iter()
            .find(|m| Uuid::parse_str(&m.id).ok() == Some(message))
        else {
            return Ok(());
        };
        self.call(
            "agent.queue.remove",
            json!({"threadId":id,"messageId":stored.id}),
        )
        .map(|_| ())
    }

    /// Sends as the composer does: while a turn runs it steers or queues per the
    /// follow-up setting (the alternate delivery does the other), and approvals
    /// still waiting are declined so the message redirects the agent.
    pub fn send(&self, request: &SendRequest, runs: &Runs) -> Result<&'static str, RemoteError> {
        let (id, document) = self.document(request.thread_id)?;
        if request.text.trim().is_empty() && request.images.is_empty() {
            return Err(RemoteError::new(
                ErrorCode::BadRequest,
                "The message is empty.",
            ));
        }
        if !request.images.is_empty() {
            return Err(RemoteError::new(
                ErrorCode::NotAllowed,
                "This computer can’t take images from Coincide Remote yet. Send the text alone, or attach them on the computer.",
            ));
        }
        if !runs.running.contains(&upper(&id)) {
            self.call("agent.send", json!({"threadId":id,"text":request.text}))?;
            return Ok("sent");
        }
        let settings = self.call("settings.read", json!({})).unwrap_or_default();
        let behavior = document["followUpBehavior"]
            .as_str()
            .or(settings["followUpBehavior"].as_str())
            .unwrap_or("steer");
        let steers = (behavior == "steer") != (request.delivery == Delivery::Alternate);
        for (request_id, method, params) in runs.pending.get(&upper(&id)).into_iter().flatten() {
            if method == "item/tool/requestUserInput" {
                continue;
            }
            let options = approval_options(params);
            if let Some(decline) = options
                .iter()
                .find(|o| o.kind == "deny")
                .or_else(|| options.iter().find(|o| o.kind == "cancel"))
            {
                let _ = self.call(
                    "agent.respond",
                    json!({"threadId":id,"requestId":request_id,"decision":decline.id}),
                );
            }
        }
        if steers
            && self
                .call("agent.steer", json!({"threadId":id,"text":request.text}))
                .is_ok()
        {
            return Ok("steered");
        }
        self.call(
            "agent.queue.add",
            json!({"threadId":id,"text":request.text}),
        )?;
        Ok("queued")
    }

    /// A new thread in the project, or a chat for none, reusing an untouched
    /// one there as New Thread does.
    pub fn new_thread(&self, project: Option<Uuid>, runs: &Runs) -> Result<String, RemoteError> {
        let workspace = self.workspace(false, runs)?;
        let project = match project {
            Some(project) => workspace
                .projects
                .iter()
                .find(|p| Uuid::parse_str(&p.id).ok() == Some(project))
                .ok_or_else(|| {
                    RemoteError::new(ErrorCode::NotFound, "That project no longer exists.")
                })?,
            None => workspace
                .projects
                .iter()
                .find(|p| p.is_chats)
                .ok_or_else(|| {
                    RemoteError::new(ErrorCode::NotFound, "That project no longer exists.")
                })?,
        };
        if let Some(empty) = workspace.threads.iter().find(|t| {
            t.project_id == project.id
                && t.item_count == 0
                && !t.has_draft
                && !t.is_archived
                && !t.is_hidden
                && !t.has_worktree
        }) {
            return Ok(empty.id.clone());
        }
        let project_id = if project.id == NO_PROJECT {
            Value::Null
        } else {
            json!(project.id)
        };
        let created = self.call("threads.create", json!({"projectId":project_id}))?;
        Ok(upper(created["id"].as_str().unwrap_or_default()))
    }

    pub fn perform(&self, thread: Uuid, action: &ThreadAction) -> Result<(), RemoteError> {
        let (id, _) = self.document(thread)?;
        let patch = match action {
            ThreadAction::Rename(title) => {
                let title = title.trim();
                if title.is_empty() {
                    return Err(RemoteError::new(
                        ErrorCode::BadRequest,
                        "A thread needs a name.",
                    ));
                }
                json!({"title":title.chars().take(512).collect::<String>()})
            }
            ThreadAction::Pin(value) => json!({"isPinned":value}),
            ThreadAction::Archive(value) => json!({"isArchived":value}),
            ThreadAction::Snooze(date) => json!({"snoozedUntil":date.map(swift_seconds)}),
            ThreadAction::Settle(_)
            | ThreadAction::MarkUnread
            | ThreadAction::Move(_)
            | ThreadAction::Delete => {
                return Err(RemoteError::new(
                    ErrorCode::NotAllowed,
                    "Do this on the computer; Coincide Remote can’t do it here yet.",
                ));
            }
        };
        self.call("threads.patch", json!({"threadId":id,"patch":patch}))
            .map(|_| ())
    }
}

fn home_directory() -> Option<String> {
    std::env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .ok()
        .filter(|h| !h.is_empty())
}

/// The folder with the home folder shortened to `~`.
pub fn abbreviate(path: &str, home: Option<&str>) -> String {
    match home {
        Some(home) if path == home => "~".into(),
        Some(home) => path
            .strip_prefix(home)
            .filter(|rest| rest.starts_with(['/', '\\']))
            .map(|rest| format!("~{rest}"))
            .unwrap_or_else(|| path.into()),
        None => path.into(),
    }
}

/// The choices an approval offers, as the desktop's buttons show them.
pub fn approval_options(params: &Value) -> Vec<ApprovalOption> {
    let offered = params["availableDecisions"].as_array();
    [
        ("accept", "Allow once", "allowOnce"),
        ("decline", "Decline", "deny"),
        ("cancel", "Cancel request", "cancel"),
    ]
    .into_iter()
    .filter(|(id, _, _)| offered.is_none_or(|options| options.iter().any(|v| v == id)))
    .map(|(id, label, kind)| ApprovalOption {
        id: id.into(),
        label: label.into(),
        kind: kind.into(),
    })
    .collect()
}

fn clip_end(text: &str, limit: usize) -> (String, bool) {
    let count = text.chars().count();
    if count <= limit {
        return (text.into(), false);
    }
    (
        format!(
            "…\n{}",
            text.chars().skip(count - limit).collect::<String>()
        ),
        true,
    )
}

fn clip_start(text: &str, limit: usize) -> (String, bool) {
    if text.chars().count() <= limit {
        return (text.into(), false);
    }
    (
        format!("{}\n…", text.chars().take(limit).collect::<String>()),
        true,
    )
}

fn file_name(path: &str) -> String {
    path.rsplit(['/', '\\']).next().unwrap_or(path).to_owned()
}

/// An item as the phone draws it. Approval and question items keep their
/// provider request as JSON text; they're turned into choices here, waiting
/// while the request is still pending.
pub fn remote_item(item: &Value, index: usize, pending: &[PendingRequest]) -> Item {
    let string = |key: &str| item[key].as_str().map(str::to_owned);
    let kind = item["kind"].as_str().unwrap_or("notice").to_owned();
    let mut text = item["text"].as_str().unwrap_or_default().to_owned();
    let mut detail = string("detail");
    let mut title = string("title");
    let mut status = string("status");
    let mut clipped = false;
    let mut approval = None;
    let mut questions = None;
    if kind == "tool" {
        let (clipped_text, text_cut) = clip_end(&text, MAX_TOOL_TEXT);
        text = clipped_text;
        if let Some(value) = &detail {
            let (value, cut) = clip_start(value, MAX_TOOL_DETAIL);
            detail = Some(value);
            clipped |= cut;
        }
        clipped |= text_cut;
    }
    if kind == "approval" || kind == "question" {
        let key = item["externalID"].as_str().unwrap_or_default();
        let live = pending.iter().find(|(request, _, _)| request == key);
        let params = live
            .map(|(_, _, params)| params.clone())
            .or_else(|| serde_json::from_str::<Value>(&text).ok())
            .unwrap_or_default();
        if live.is_some() {
            status = Some("waiting".into());
        } else if status.is_none() {
            status = Some("completed".into());
        }
        if kind == "approval" {
            title.get_or_insert_with(|| "Approval required".into());
            let mut shown = params.clone();
            if let Some(object) = shown.as_object_mut() {
                object.remove("providerFrame");
                object.remove("availableDecisions");
            }
            let (value, cut) = clip_start(
                &serde_json::to_string_pretty(&shown).unwrap_or_default(),
                MAX_TOOL_DETAIL,
            );
            detail = detail.or(Some(value));
            clipped |= cut;
            approval = Some(Approval {
                options: approval_options(&params),
                resolution: string("resolution"),
                text_placeholder: None,
                accepts_text: false,
                response_text: None,
            });
        } else {
            questions = Some(QuestionSet {
                title: params["title"].as_str().map(str::to_owned),
                questions: params["questions"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|q| Question {
                        id: q["id"].as_str().unwrap_or_default().to_owned(),
                        header: q["header"]
                            .as_str()
                            .filter(|h| !h.is_empty())
                            .map(str::to_owned),
                        prompt: q["question"]
                            .as_str()
                            .or(q["prompt"].as_str())
                            .unwrap_or_default()
                            .to_owned(),
                        options: q["options"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .map(|o| QuestionOption {
                                label: o["label"].as_str().unwrap_or_default().to_owned(),
                                detail: o["description"]
                                    .as_str()
                                    .filter(|d| !d.is_empty())
                                    .map(str::to_owned),
                            })
                            .collect(),
                        allows_multiple_selection: q["multiSelect"] == true,
                        allows_free_text: true,
                        is_secret: q["isSecret"] == true,
                    })
                    .collect(),
            });
        }
        // The provider request itself is shown as choices, not raw JSON.
        text = String::new();
    }
    let mut answers =
        serde_json::from_value::<BTreeMap<String, Vec<String>>>(item["answers"].clone()).ok();
    // Secret answers never leave the computer.
    if let (Some(answers), Some(set)) = (answers.as_mut(), questions.as_ref()) {
        for question in set.questions.iter().filter(|q| q.is_secret) {
            if let Some(values) = answers.get_mut(&question.id) {
                *values = vec!["••••••".into()];
            }
        }
    }
    Item {
        id: upper(item["id"].as_str().unwrap_or_default()),
        index,
        text,
        title,
        detail,
        category: string("category"),
        status,
        provider: string("provider"),
        model_id: string("modelID"),
        approval,
        questions,
        answers,
        attachments: item["attachments"].as_array().map(|list| {
            list.iter()
                .filter_map(Value::as_str)
                .map(file_name)
                .collect()
        }),
        context: item["context"].as_array().map(|list| {
            list.iter()
                .filter_map(|c| c["summary"].as_str().or(c["title"].as_str()))
                .map(str::to_owned)
                .collect()
        }),
        steered: item["steered"] == true,
        is_clipped: clipped,
        created_at: stored_date_ms(&item["createdAt"]).unwrap_or(0.),
        completed_at: stored_date_ms(&item["completedAt"]),
        schedule_name: item["schedule"]["name"].as_str().map(str::to_owned),
        kind,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_paths_and_options_convert_as_the_mac_sends_them() {
        assert_eq!(stored_date_ms(&json!(0.0)), Some(978_307_200_000.));
        assert_eq!(
            stored_date_ms(&json!("2001-01-01T00:00:01Z")),
            Some(978_307_201_000.)
        );
        assert_eq!(swift_seconds(978_307_201_000.), 1.);
        assert_eq!(abbreviate("/Users/a/src", Some("/Users/a")), "~/src");
        assert_eq!(abbreviate("/Users/ab", Some("/Users/a")), "/Users/ab");
        assert_eq!(abbreviate("/Users/a", Some("/Users/a")), "~");
        let all = approval_options(&json!({}));
        assert_eq!(
            all.iter().map(|o| o.kind.as_str()).collect::<Vec<_>>(),
            ["allowOnce", "deny", "cancel"]
        );
        let offered = approval_options(&json!({"availableDecisions":["accept"]}));
        assert_eq!(offered.len(), 1);
        assert_eq!(offered[0].label, "Allow once");
    }

    #[test]
    fn items_clip_tool_text_and_turn_requests_into_choices() {
        let tool = remote_item(
            &json!({"id":"a1b2c3d4-0000-0000-0000-000000000000","kind":"tool","text":"x".repeat(MAX_TOOL_TEXT + 5),"detail":"d","createdAt":1.0}),
            3,
            &[],
        );
        assert!(tool.is_clipped);
        assert!(tool.text.starts_with("…\n"));
        assert_eq!(tool.text.chars().count(), MAX_TOOL_TEXT + 2);
        assert_eq!(tool.id, "A1B2C3D4-0000-0000-0000-000000000000");
        assert_eq!(tool.index, 3);
        assert_eq!(tool.created_at, 978_307_201_000.);
        let params = json!({"command":"ls","availableDecisions":["accept","decline"]});
        let approval = json!({"id":"E1","kind":"approval","text":params.to_string(),"externalID":"7","createdAt":0});
        let waiting = remote_item(
            &approval,
            0,
            &[(
                "7".into(),
                "item/commandExecution/requestApproval".into(),
                params.clone(),
            )],
        );
        assert_eq!(waiting.status.as_deref(), Some("waiting"));
        assert_eq!(waiting.approval.as_ref().unwrap().options.len(), 2);
        assert!(waiting.detail.as_ref().unwrap().contains("\"command\""));
        assert!(waiting.text.is_empty());
        let answered = remote_item(&approval, 0, &[]);
        assert_eq!(answered.status.as_deref(), Some("completed"));
        let question = json!({"id":"Q","kind":"question","externalID":"9","createdAt":0,
            "text":json!({"questions":[{"id":"pw","question":"Password?","isSecret":true,"options":[{"label":"a","description":"b"}]}]}).to_string(),
            "answers":{"pw":["hunter2"]}});
        let asked = remote_item(&question, 1, &[]);
        let set = asked.questions.unwrap();
        assert_eq!(set.questions[0].prompt, "Password?");
        assert!(set.questions[0].is_secret);
        assert_eq!(set.questions[0].options[0].detail.as_deref(), Some("b"));
        assert_eq!(asked.answers.unwrap()["pw"], vec!["••••••".to_owned()]);
        let user = remote_item(
            &json!({"id":"U","kind":"user","text":"hi","attachments":["/tmp/a/b.png"],"steered":true,"createdAt":0}),
            0,
            &[],
        );
        assert_eq!(user.attachments.unwrap(), vec!["b.png".to_owned()]);
        assert!(user.steered);
    }
}
