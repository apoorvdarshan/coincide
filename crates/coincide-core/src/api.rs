//! One command dispatcher for the desktop and the local CLI/API.
use crate::{
    agent::{self, Event, Launch, Session},
    store::{Store, swift_timestamp, text},
};
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex},
};
use uuid::Uuid;

pub type SharedEngine = Arc<Mutex<Engine>>;
struct Running {
    session: Session,
    pending: HashMap<String, Value>,
}
pub struct Engine {
    pub store: Store,
    runs: HashMap<String, Running>,
    pub revision: u64,
    pub requested_open: Option<String>,
}
impl Engine {
    pub fn new(store: Store) -> Self {
        Self {
            store,
            runs: HashMap::new(),
            revision: 0,
            requested_open: None,
        }
    }
    pub fn dispatch(&mut self, request: Value) -> Value {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        self.poll();
        match self.execute(request["method"].as_str().unwrap_or(""), &request["params"]) {
            Ok(result) => json!({"id":id,"result":result}),
            Err(e) => json!({"id":id,"error":{"message":e.to_string()}}),
        }
    }
    fn execute(&mut self, method: &str, p: &Value) -> Result<Value> {
        match method {
            "app.status" => Ok(
                json!({"version":env!("CARGO_PKG_VERSION"),"revision":self.revision,"running":self.runs.keys().collect::<Vec<_>>(),"preview":true}),
            ),
            "app.capabilities" => Ok(json!([
                "app.status",
                "app.capabilities",
                "projects.list",
                "threads.list",
                "threads.read",
                "threads.open",
                "threads.create",
                "threads.patch",
                "threads.fork",
                "agent.send",
                "agent.stop",
                "agent.respond"
            ])),
            "threads.open" => {
                let id = required(p, "threadId")?;
                self.store.thread(id)?;
                self.requested_open = Some(id.into());
                self.revision += 1;
                Ok(json!({"requested":true}))
            }
            "projects.list" => self.store.projects(),
            "threads.list" => Ok(serde_json::to_value(self.store.summaries(
                p["query"].as_str().unwrap_or(""),
                p["includeArchived"].as_bool().unwrap_or(false),
            )?)?),
            "threads.read" => self.store.thread(required(p, "threadId")?),
            "threads.create" => {
                let mut v = self.store.new_thread(
                    p["projectId"]
                        .as_str()
                        .unwrap_or("00000000-0000-0000-0000-000000000000"),
                )?;
                v["selection"] = json!({"provider":"codex","modelID":"default"});
                if let Some(cwd) = p["cwd"].as_str() {
                    ensure!(
                        PathBuf::from(cwd).is_dir(),
                        "Working directory does not exist"
                    );
                    v["worktreePath"] = json!(cwd);
                }
                self.store.save(&v)?;
                self.revision += 1;
                Ok(v)
            }
            "threads.patch" => {
                let mut v = self.store.thread(required(p, "threadId")?)?;
                let patch = p["patch"].as_object().context("Missing patch")?;
                for (k, value) in patch {
                    match k.as_str() {
                        "draft" | "title" => ensure!(value.is_string(), "{k} must be text"),
                        "isPinned" | "isArchived" => {
                            ensure!(value.is_boolean(), "{k} must be boolean")
                        }
                        _ => bail!("Field cannot be patched: {k}"),
                    }
                    v[k] = value.clone();
                }
                self.store.save(&v)?;
                self.revision += 1;
                Ok(v)
            }
            "threads.fork" => {
                let mut v = self.store.thread(required(p, "threadId")?)?;
                v["id"] = json!(Uuid::new_v4().to_string().to_uppercase());
                v["title"] = json!(format!("{} (fork)", text(&v, "title")));
                v["sessions"] = json!({});
                v["accountSessions"] = json!({});
                v["selection"] = json!({"provider":"codex","modelID":"default"});
                v["isArchived"] = json!(false);
                v["createdAt"] = json!(swift_timestamp());
                v["updatedAt"] = json!(swift_timestamp());
                self.store.save(&v)?;
                self.revision += 1;
                Ok(v)
            }
            "agent.send" => {
                let id = required(p, "threadId")?.to_owned();
                ensure!(
                    !self.runs.contains_key(&id),
                    "This thread is already running"
                );
                let prompt = required(p, "text")?;
                ensure!(
                    !prompt.trim().is_empty() && prompt.len() <= 1024 * 1024,
                    "Message must contain text and fit within 1 MiB"
                );
                let mut v = self.store.thread(&id)?;
                ensure!(
                    v["selection"]["provider"] == "codex",
                    "Only Codex is connected in this preview; fork to a new Codex conversation"
                );
                ensure!(
                    v["selection"]["accountID"].is_null(),
                    "Alternate provider accounts are not connected yet"
                );
                // Imported native sessions may still be owned by the running Swift app.
                // A fork starts a separate provider session and cannot steal that session.
                ensure!(
                    !self.store.is_imported(&id)?,
                    "Imported conversations are read-only for agent execution until cutover; fork first"
                );
                let cwd = if let Some(path) = v["worktreePath"].as_str() {
                    PathBuf::from(path)
                } else {
                    self.store
                        .projects()?
                        .as_array()
                        .and_then(|projects| {
                            projects
                                .iter()
                                .find(|project| project["id"] == v["projectID"])
                                .and_then(|project| project["path"].as_str())
                                .map(PathBuf::from)
                        })
                        .context("Choose a project working directory first")?
                };
                ensure!(cwd.is_dir(), "Working directory does not exist");
                let session = agent::provider_session(&v, "codex");
                let mut outgoing = String::new();
                if session.is_none()
                    && let Some(items) = v["items"].as_array()
                {
                    for item in items
                        .iter()
                        .filter(|item| item["kind"] == "user" || item["kind"] == "assistant")
                    {
                        let addition =
                            format!("\n{}: {}\n", text(item, "kind"), text(item, "text"));
                        ensure!(
                            outgoing.len() + addition.len() < 2 * 1024 * 1024,
                            "Conversation is too large for the preview handoff; start a new thread"
                        );
                        outgoing.push_str(&addition);
                    }
                }
                outgoing.push_str(prompt);
                let model = v["selection"]["modelID"]
                    .as_str()
                    .filter(|m| !m.is_empty() && *m != "default")
                    .map(str::to_owned);
                let executable = std::env::var_os("COINCIDE_CODEX_EXECUTABLE")
                    .map(PathBuf::from)
                    .unwrap_or_else(|| "codex".into());
                append(&mut v, "user", prompt, None);
                v["draft"] = json!("");
                v["updatedAt"] = json!(swift_timestamp());
                if v["title"] == "New conversation" {
                    v["title"] = json!(prompt.chars().take(70).collect::<String>());
                }
                self.store.save(&v)?;
                self.runs.insert(
                    id,
                    Running {
                        session: Session::start(Launch {
                            executable,
                            cwd,
                            session,
                            prompt: outgoing,
                            model,
                        }),
                        pending: HashMap::new(),
                    },
                );
                self.revision += 1;
                Ok(json!({"accepted":true}))
            }
            "agent.stop" => {
                self.runs
                    .get(required(p, "threadId")?)
                    .context("Thread is not running")?
                    .session
                    .stop();
                Ok(json!({"requested":true}))
            }
            "agent.respond" => {
                let running = self
                    .runs
                    .get_mut(required(p, "threadId")?)
                    .context("Thread is not running")?;
                let key = required(p, "requestId")?;
                let frame = running
                    .pending
                    .get(key)
                    .context("Approval is no longer pending")?;
                let decision = required(p, "decision")?;
                ensure!(
                    ["accept", "decline", "cancel"].contains(&decision),
                    "Unsupported approval decision"
                );
                if let Some(options) = frame["params"]["availableDecisions"].as_array() {
                    ensure!(
                        options.contains(&json!(decision)),
                        "Decision is not offered by the agent"
                    );
                }
                running
                    .session
                    .reply(frame["id"].clone(), json!({"decision":decision}))?;
                running.pending.remove(key);
                Ok(json!({"answered":true}))
            }
            _ => bail!("Unsupported method: {method}"),
        }
    }
    pub fn poll(&mut self) {
        let ids = self.runs.keys().cloned().collect::<Vec<_>>();
        for id in ids {
            let mut events = Vec::new();
            if let Some(run) = self.runs.get(&id) {
                events.extend(run.session.events.try_iter().take(256));
            }
            if events.is_empty() {
                continue;
            }
            let Ok(mut v) = self.store.thread(&id) else {
                continue;
            };
            let mut finished = false;
            for event in events {
                match event {
                    Event::Session(session) => {
                        agent::set_provider_session(&mut v, "codex", &session)
                    }
                    Event::Finished => {
                        finished = true;
                        append(&mut v, "notice", "Turn ended", None);
                    }
                    Event::Failed(error) => {
                        finished = true;
                        append(&mut v, "error", &error, None);
                    }
                    Event::Frame(frame) => {
                        let method = frame["method"].as_str().unwrap_or("");
                        let p = &frame["params"];
                        match method {
                            "item/agentMessage/delta"
                            | "item/reasoning/textDelta"
                            | "item/reasoning/summaryTextDelta" => {
                                let kind = if method == "item/agentMessage/delta" {
                                    "assistant"
                                } else {
                                    "reasoning"
                                };
                                let external = p["itemId"].as_str().unwrap_or("stream");
                                let items = v["items"].as_array_mut().expect("validated thread");
                                if let Some(item) = items
                                    .iter_mut()
                                    .rev()
                                    .find(|item| item["externalID"] == external)
                                {
                                    let next = format!(
                                        "{}{}",
                                        text(item, "text"),
                                        p["delta"].as_str().unwrap_or("")
                                    );
                                    item["text"] = json!(next);
                                } else {
                                    append(
                                        &mut v,
                                        kind,
                                        p["delta"].as_str().unwrap_or(""),
                                        Some(external),
                                    );
                                }
                            }
                            "item/commandExecution/requestApproval"
                            | "item/fileChange/requestApproval" => {
                                let key = frame["id"].to_string();
                                append(&mut v, "approval", &p.to_string(), Some(&key));
                                self.runs.get_mut(&id).unwrap().pending.insert(key, frame);
                            }
                            "item/completed" => {
                                let item = &p["item"];
                                if item["type"] == "agentMessage" {
                                    let external = text(item, "id");
                                    let items = v["items"].as_array_mut().unwrap();
                                    if let Some(existing) = items
                                        .iter_mut()
                                        .rev()
                                        .find(|it| it["externalID"] == external)
                                    {
                                        existing["text"] = item["text"].clone();
                                    } else {
                                        append(
                                            &mut v,
                                            "assistant",
                                            item["text"].as_str().unwrap_or(""),
                                            Some(&external),
                                        );
                                    }
                                } else if item["type"] != "userMessage" {
                                    append(&mut v, "tool", &item.to_string(), None);
                                }
                            }
                            _ => {
                                if frame.get("id").is_some() && frame.get("method").is_some() {
                                    // Never invent answers to unsupported questions or grants.
                                    append(
                                        &mut v,
                                        "error",
                                        &format!(
                                            "Unsupported agent request: {method}. Stop this turn to continue in the existing app."
                                        ),
                                        None,
                                    );
                                }
                            }
                        }
                    }
                }
            }
            if self.store.save(&v).is_err()
                && let Some(run) = self.runs.get(&id)
            {
                run.session.stop();
            }
            self.revision += 1;
            if finished {
                self.runs.remove(&id);
            }
        }
    }
}
fn required<'a>(p: &'a Value, key: &str) -> Result<&'a str> {
    p[key].as_str().with_context(|| format!("Missing {key}"))
}
fn append(v: &mut Value, kind: &str, text: &str, external: Option<&str>) {
    v["items"].as_array_mut().expect("validated thread").push(json!({"id":Uuid::new_v4().to_string().to_uppercase(),"kind":kind,"text":text,"provider":"codex","createdAt":swift_timestamp(),"externalID":external}));
}
pub fn call(engine: &SharedEngine, method: &str, params: Value) -> Result<Value> {
    let response = engine
        .lock()
        .map_err(|_| anyhow::anyhow!("Engine lock failed"))?
        .dispatch(json!({"method":method,"params":params}));
    if let Some(error) = response.get("error") {
        bail!("{}", error["message"].as_str().unwrap_or("Command failed"));
    }
    Ok(response["result"].clone())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn patch_preserves_other_fields_and_rejects_session_edits() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(&dir.path().join("data.sqlite")).unwrap();
        let mut e = Engine::new(store);
        let created = e.dispatch(json!({"id":1,"method":"threads.create","params":{}}));
        let id = created["result"]["id"].clone();
        let reply=e.dispatch(json!({"id":2,"method":"threads.patch","params":{"threadId":id,"patch":{"draft":"hello"}}}));
        assert_eq!(reply["id"], 2);
        assert_eq!(reply["result"]["draft"], "hello");
        assert!(reply["result"]["sessions"].is_object());
        let reply = e.dispatch(
            json!({"method":"threads.patch","params":{"threadId":id,"patch":{"sessions":{}}}}),
        );
        assert!(reply.get("error").is_some());
    }
}
