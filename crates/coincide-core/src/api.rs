//! One command dispatcher for the desktop and the local CLI/API.
use crate::{
    agent::{self, Event, Launch, Provider, Session},
    store::{Store, swift_timestamp, text},
};
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use uuid::Uuid;

pub type SharedEngine = Arc<Mutex<Engine>>;
struct Running {
    session: Session,
    provider: String,
    transcript_start: usize,
    pending: HashMap<String, Value>,
}
pub struct Engine {
    pub store: Store,
    runs: HashMap<String, Running>,
    pub revision: u64,
    pub requested_open: Option<String>,
    terminals: HashMap<String, (String, crate::terminal::Terminal)>,
    pub shutdown: bool,
    pub active_thread: Option<String>,
    pub ui_available: bool,
    pub browser_requests: VecDeque<crate::browser_protocol::BrowserRequest>,
    browser_pending: HashMap<String, (String, Instant)>,
    browser_results: HashMap<String, crate::browser_protocol::BrowserReply>,
}
impl Engine {
    pub fn new(store: Store) -> Self {
        Self {
            store,
            runs: HashMap::new(),
            revision: 0,
            requested_open: None,
            terminals: HashMap::new(),
            shutdown: false,
            active_thread: None,
            ui_available: false,
            browser_requests: VecDeque::new(),
            browser_pending: HashMap::new(),
            browser_results: HashMap::new(),
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
            "browser.request"=>{
                ensure!(p.is_object(), "Browser request parameters must be an object");
                ensure!(self.ui_available,"Browser requires the desktop window");
                ensure!(self.browser_pending.len()<128,"Too many browser requests; collect completed results first");
                let mut params=p.clone();
                params["id"]=json!(Uuid::new_v4().to_string());
                let request:crate::browser_protocol::BrowserRequest=serde_json::from_value(params)?;
                request.validate()?;self.store.thread(&request.thread_id)?;
                let id=request.id.clone();
                self.browser_pending.insert(id.clone(),(request.thread_id.clone(),Instant::now()));
                self.browser_requests.push_back(request);self.revision+=1;
                Ok(json!({"operationId":id}))
            }
            "browser.result"=>{
                let id=required(p,"operationId")?;
                let (thread,started)=self.browser_pending.get(id).context("Browser operation not found")?;
                ensure!(thread==required(p,"threadId")?,"Browser operation belongs to another thread");
                if let Some(reply)=self.browser_results.remove(id){
                    self.browser_pending.remove(id);return Ok(json!({"ready":true,"result":reply.result}));
                }
                if started.elapsed()>Duration::from_secs(30){
                    self.browser_pending.remove(id);
                    self.browser_requests.retain(|r|r.id!=id);
                    return Ok(json!({"ready":true,"result":{"error":"Browser operation timed out; read current page state before retrying"}}));
                }
                Ok(json!({"ready":false}))
            }
            "app.quit"=>{self.shutdown=true;self.revision+=1;Ok(json!({"requested":true}))}
            "terminal.create"=>{
                ensure!(self.terminals.len()<32,"Too many terminal panes");
                let thread=required(p,"threadId")?;
                let v=self.store.thread(thread)?;
                let cwd=self.working_directory(&v)?;
                let shell=std::env::var("SHELL").unwrap_or_else(|_|if cfg!(windows){"powershell.exe".into()}else{"/bin/sh".into()});
                let terminal=crate::terminal::Terminal::spawn(&cwd,&shell,24,100)?;
                let id=Uuid::new_v4().to_string();self.terminals.insert(id.clone(),(thread.into(),terminal));self.revision+=1;
                Ok(json!({"terminalId":id}))
            }
            "terminal.list"=>Ok(json!(self.terminals.iter().filter(|(_, (thread,_))|p["threadId"].as_str().is_none_or(|id|thread==id)).map(|(id,(thread,terminal))|json!({"terminalId":id,"threadId":thread,"title":terminal.title})).collect::<Vec<_>>())),
            "terminal.read"=>self.terminals.get_mut(required(p,"terminalId")?).context("Terminal not found")?.1.snapshot(),
            "terminal.write"=>{self.terminals.get_mut(required(p,"terminalId")?).context("Terminal not found")?.1.write(required(p,"text")?)?;Ok(json!({"accepted":true}))}
            "terminal.resize"=>{
                let rows=u16::try_from(p["rows"].as_u64().context("Missing rows")?)?;
                let cols=u16::try_from(p["cols"].as_u64().context("Missing cols")?)?;
                self.terminals.get_mut(required(p,"terminalId")?).context("Terminal not found")?.1.resize(rows,cols)?;Ok(json!({"resized":true}))
            }
            "terminal.close"=>{ensure!(self.terminals.remove(required(p,"terminalId")?).is_some(),"Terminal not found");self.revision+=1;Ok(json!({"closed":true}))}
            "app.status" => Ok(
                json!({"version":env!("CARGO_PKG_VERSION"),"revision":self.revision,"running":self.runs.keys().collect::<Vec<_>>(),"preview":true,"activeThread":self.active_thread}),
            ),
            "app.capabilities" => Ok(json!([
                "app.status", "app.quit", "terminal.create", "terminal.list", "terminal.read", "terminal.write", "terminal.resize", "terminal.close",
                "app.capabilities", "browser.request", "browser.result",
                "projects.list", "projects.create", "projects.patch", "projects.remove", "settings.read", "settings.patch",
                "threads.list",
                "threads.read",
                "threads.open",
                "threads.create",
                "threads.patch",
                "threads.fork",
                "agent.send",
                "agent.stop",
                "agent.respond"
                ,"agent.pending", "agent.answer", "agent.select"
            ])),
            "threads.open" => {
                let id = required(p, "threadId")?;
                self.store.thread(id)?;
                self.requested_open = Some(id.into());
                self.revision += 1;
                Ok(json!({"requested":true}))
            }
            "projects.list" => self.store.projects(),
            "projects.create"=>{let v=self.store.create_project(std::path::Path::new(required(p,"path")?),p["name"].as_str())?;self.revision+=1;Ok(v)}
            "projects.patch"=>{let v=self.store.patch_project(required(p,"projectId")?,&p["patch"])?;self.revision+=1;Ok(v)}
            "projects.remove"=>{self.store.remove_project(required(p,"projectId")?)?;self.revision+=1;Ok(json!({"removed":true}))}
            "settings.read"=>Ok(self.store.document("settings.json")?.unwrap_or(json!({}))),
            "settings.patch"=>{let v=self.store.patch_document("settings.json",&p["patch"])?;self.revision+=1;Ok(v)}
            "threads.list" => Ok(serde_json::to_value(self.store.summaries(
                p["query"].as_str().unwrap_or(""),
                p["includeArchived"].as_bool().unwrap_or(false),
            )?)?),
            "threads.read" => {
                let mut v=self.store.thread(required(p,"threadId")?)?;
                if let Some(limit)=p["itemLimit"].as_u64(){
                    ensure!(limit<=1000,"itemLimit must be at most 1000");
                    let items=v["items"].as_array().context("Invalid transcript")?;
                    let total=items.len();let offset=p["itemOffset"].as_u64().unwrap_or(total.saturating_sub(limit as usize) as u64).min(total as u64) as usize;
                    v["items"]=json!(items.iter().skip(offset).take(limit as usize).cloned().collect::<Vec<_>>());
                    v["page"]=json!({"offset":offset,"total":total});
                }
                Ok(v)
            }
            "threads.create" => {
                if let Some(cwd)=p["cwd"].as_str(){ensure!(PathBuf::from(cwd).is_dir(),"Working directory does not exist");}
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
                let v=self.store.patch_thread(required(p,"threadId")?,&p["patch"])?;
                self.revision+=1;Ok(v)
            }
            "threads.fork" => {
                let mut v = self.store.thread(required(p, "threadId")?)?;
                v["id"] = json!(Uuid::new_v4().to_string().to_uppercase());
                v["title"] = json!(format!("{} (fork)", text(&v, "title")));
                v["sessions"] = json!({});
                v["accountSessions"] = json!({});
                v["selection"] = json!({"provider":"codex","modelID":"default"});
                v["isArchived"] = json!(false);
                v["accessMode"] = json!("approval");
                v["interactionMode"] = json!("build");
                append(&mut v,"notice","Preview fork starts a separate provider session in approval/build mode; plan and full-access modes are not connected yet.",None);
                v["createdAt"] = json!(swift_timestamp());
                v["updatedAt"] = json!(swift_timestamp());
                self.store.save(&v)?;
                self.revision += 1;
                Ok(v)
            }
            "agent.select" => {
                let id = required(p, "threadId")?;
                ensure!(!self.runs.contains_key(id), "Stop the current turn before changing provider");
                let provider = required(p, "provider")?;
                ensure!(["codex", "claude"].contains(&provider), "Provider not connected in this preview");
                let mut v = self.store.thread(id)?;
                ensure!(!self.store.is_imported(id)?, "Fork an imported thread before changing its provider");
                v["selection"] = json!({"provider":provider,"modelID":p["model"].as_str().unwrap_or("default")});
                self.store.save(&v)?; self.revision += 1;
                Ok(v)
            }
            "agent.pending" => {
                self.store.thread(required(p,"threadId")?)?;
                Ok(json!(self.runs.get(required(p,"threadId")?).map(|run|run.pending.iter().map(|(id,frame)|json!({"requestId":id,"method":frame["method"],"params":frame["params"]})).collect::<Vec<_>>()).unwrap_or_default()))
            }
            "agent.answer" => {
                let run = self.runs.get_mut(required(p,"threadId")?).context("Thread is not running")?;
                let key = required(p,"requestId")?;
                let frame = run.pending.get(key).context("Question is no longer pending")?;
                ensure!(frame["method"]=="item/tool/requestUserInput", "Request is not a user question");
                let answers = p["answers"].as_object().context("Missing answers object")?;
                let questions = frame["params"]["questions"].as_array().context("Malformed provider questions")?;
                for question in questions {
                    let id = question["id"].as_str().context("Question has no identifier")?;
                    let values = answers.get(id).and_then(|a|a["answers"].as_array()).context("Every question requires an answers array")?;
                    ensure!(!values.is_empty() && values.iter().all(|v|v.as_str().is_some_and(|s| !s.trim().is_empty() && s.len()<=65536)), "Provide nonempty text answers");
                }
                run.session.reply(frame["id"].clone(),json!({"answers":answers}))?;
                run.pending.remove(key); self.revision += 1;
                Ok(json!({"answered":true}))
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
                ensure!(v["accessMode"].as_str().is_none_or(|mode|mode=="approval") && v["interactionMode"].as_str().is_none_or(|mode|mode=="build"), "This preview supports approval/build mode only; fork this conversation to use supported defaults");
                let provider = text(&v["selection"], "provider");
                let adapter = match provider.as_str() {
                    "codex" => Provider::Codex,
                    "claude" => Provider::Claude,
                    _ => bail!("Provider not connected in this preview; fork and choose Codex or Claude"),
                };
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
                let session = agent::provider_session(&v, &provider);
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
                let executable = std::env::var_os(if provider=="claude" {"COINCIDE_CLAUDE_EXECUTABLE"} else {"COINCIDE_CODEX_EXECUTABLE"})
                    .map(PathBuf::from)
                    .unwrap_or_else(|| provider.clone().into());
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
                        session: Session::start_with(adapter, Launch {
                            executable,
                            cwd,
                            session,
                            prompt: outgoing,
                            model,
                        }),
                        provider,
                        transcript_start: v["items"].as_array().map_or(0, Vec::len),
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
                ensure!(frame["method"]!="item/tool/requestUserInput", "Use agent.answer for user questions");
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
                self.revision += 1;
                Ok(json!({"answered":true}))
            }
            _ => bail!("Unsupported method: {method}"),
        }
    }
    pub fn browser_reply(&mut self, reply: crate::browser_protocol::BrowserReply) {
        if self
            .browser_pending
            .get(&reply.id)
            .is_some_and(|(thread, _)| thread == &reply.thread_id)
        {
            self.browser_results.insert(reply.id.clone(), reply);
            self.revision += 1;
        }
    }
    fn working_directory(&self, v: &Value) -> Result<PathBuf> {
        if let Some(path) = v["worktreePath"].as_str() {
            return Ok(PathBuf::from(path));
        }
        self.store
            .projects()?
            .as_array()
            .and_then(|projects| {
                projects
                    .iter()
                    .find(|p| p["id"] == v["projectID"])
                    .and_then(|p| p["path"].as_str())
                    .map(PathBuf::from)
            })
            .context("Choose a project working directory first")
    }
    pub fn poll(&mut self) {
        // Reclaim abandoned operations while allowing callers time to collect a result.
        self.browser_pending
            .retain(|_, (_, started)| started.elapsed() < Duration::from_secs(300));
        self.browser_requests
            .retain(|r| self.browser_pending.contains_key(&r.id));
        self.browser_results
            .retain(|id, _| self.browser_pending.contains_key(id));
        for (_, terminal) in self.terminals.values_mut() {
            if terminal.poll().unwrap_or(false) {
                self.revision += 1;
            }
        }

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
            let transcript_start = self.runs[&id].transcript_start;
            for event in events {
                match event {
                    Event::Session(session) => {
                        agent::set_provider_session(&mut v, &self.runs[&id].provider, &session)
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
                                    .skip(transcript_start)
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
                            | "item/fileChange/requestApproval"
                            | "item/tool/requestUserInput" => {
                                let key = frame["id"].to_string();
                                append(
                                    &mut v,
                                    if method == "item/tool/requestUserInput" {
                                        "question"
                                    } else {
                                        "approval"
                                    },
                                    &p.to_string(),
                                    Some(&key),
                                );
                                self.runs.get_mut(&id).unwrap().pending.insert(key, frame);
                            }
                            "provider/requestCancelled" => {
                                let key = p["id"].to_string();
                                self.runs.get_mut(&id).unwrap().pending.remove(&key);
                                for item in v["items"]
                                    .as_array_mut()
                                    .unwrap()
                                    .iter_mut()
                                    .skip(transcript_start)
                                    .rev()
                                {
                                    if item["externalID"] == key
                                        && (item["kind"] == "approval"
                                            || item["kind"] == "question")
                                    {
                                        item["kind"] = json!("notice");
                                        item["text"] = json!("Provider cancelled this request");
                                        break;
                                    }
                                }
                            }
                            "provider/requestRejected" => {
                                append(
                                    &mut v,
                                    "error",
                                    &format!(
                                        "Provider rejected the response: {}",
                                        text(p, "message")
                                    ),
                                    None,
                                );
                            }
                            "item/started" | "item/completed" => {
                                let item = &p["item"];
                                if item["type"] == "agentMessage" && method == "item/completed" {
                                    let external = text(item, "id");
                                    let items = v["items"].as_array_mut().unwrap();
                                    if let Some(existing) = items
                                        .iter_mut()
                                        .skip(transcript_start)
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
                                } else if item["type"] != "userMessage"
                                    && item["type"] != "agentMessage"
                                {
                                    let external = format!(
                                        "tool:{}",
                                        item["id"]
                                            .as_str()
                                            .filter(|id| !id.is_empty())
                                            .map(str::to_owned)
                                            .unwrap_or_else(|| Uuid::new_v4().to_string())
                                    );
                                    let items = v["items"].as_array_mut().unwrap();
                                    if let Some(existing) = items
                                        .iter_mut()
                                        .skip(transcript_start)
                                        .rev()
                                        .find(|it| it["externalID"] == external)
                                    {
                                        existing["text"] = json!(item.to_string());
                                    } else {
                                        append(&mut v, "tool", &item.to_string(), Some(&external));
                                    }
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
    let provider = v["selection"]["provider"].clone();
    v["items"].as_array_mut().expect("validated thread").push(json!({"id":Uuid::new_v4().to_string().to_uppercase(),"kind":kind,"text":text,"provider":provider,"createdAt":swift_timestamp(),"externalID":external}));
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
    fn browser_results_are_scoped_and_abandoned_requests_are_reclaimed() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::new(Store::open(&dir.path().join("data.sqlite")).unwrap());
        let a = engine.execute("threads.create", &json!({})).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let b = engine.execute("threads.create", &json!({})).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        assert!(
            engine
                .execute("browser.request", &json!({"threadId":a,"action":"tabs"}))
                .is_err()
        );
        engine.ui_available = true;
        assert!(engine.execute("browser.request", &json!(true)).is_err());
        let operation = engine
            .execute("browser.request", &json!({"threadId":a,"action":"tabs"}))
            .unwrap()["operationId"]
            .as_str()
            .unwrap()
            .to_owned();
        engine.browser_reply(crate::browser_protocol::BrowserReply {
            id: operation.clone(),
            thread_id: b.clone(),
            result: json!({"wrong":true}),
        });
        assert!(engine.browser_results.is_empty());
        assert!(
            engine
                .execute(
                    "browser.result",
                    &json!({"threadId":b,"operationId":operation})
                )
                .is_err()
        );
        engine.browser_reply(crate::browser_protocol::BrowserReply {
            id: operation.clone(),
            thread_id: a.clone(),
            result: json!({"tabs":[]}),
        });
        let result = engine
            .execute(
                "browser.result",
                &json!({"threadId":a,"operationId":operation}),
            )
            .unwrap();
        assert_eq!(result["result"]["tabs"], json!([]));
        let operation = engine
            .execute("browser.request", &json!({"threadId":a,"action":"tabs"}))
            .unwrap()["operationId"]
            .as_str()
            .unwrap()
            .to_owned();
        engine.browser_pending.get_mut(&operation).unwrap().1 =
            Instant::now() - Duration::from_secs(301);
        engine.poll();
        assert!(engine.browser_pending.is_empty());
        assert!(engine.browser_requests.is_empty());
    }
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
