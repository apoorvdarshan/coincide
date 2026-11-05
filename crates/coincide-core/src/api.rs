//! One command dispatcher for the desktop and the local CLI/API.
use crate::{
    agent::{self, Event, Launch, Provider, Session},
    store::{Store, swift_timestamp, text},
};
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet, VecDeque},
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
    schedule_claim: Option<String>,
    queue_claim: Option<String>,
    cancelled: bool,
    events: VecDeque<Event>,
    persistence_error: Option<String>,
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
    workspace_pending: HashMap<String, (String, Instant)>,
    workspace_results: HashMap<String, Value>,
    attachment_operations: HashSet<String>,
    workspace_tx: std::sync::mpsc::SyncSender<(String, Value)>,
    workspace_rx: std::sync::mpsc::Receiver<(String, Value)>,
    provider_discovery: Option<Value>,
    schedule_initialized: bool,
    schedule_recovery_pending: bool,
    schedule_last_poll: Instant,
    schedule_completions: Vec<(String, crate::schedule_service::Outcome, Option<String>)>,
    pub schedule_error: Option<String>,
    unsaved_threads: HashMap<String, Value>,
    enabled_queues: HashSet<String>,
}
impl Engine {
    pub fn new(store: Store) -> Self {
        let (workspace_tx, workspace_rx) = std::sync::mpsc::sync_channel(32);
        let discovery_tx = workspace_tx.clone();
        std::thread::spawn(move || {
            let report = crate::provider_catalog::discover_installed_tools();
            let _ = discovery_tx.try_send(("provider-discovery".into(), json!(report)));
        });
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
            workspace_pending: HashMap::new(),
            workspace_results: HashMap::new(),
            attachment_operations: HashSet::new(),
            workspace_tx,
            workspace_rx,
            provider_discovery: None,
            schedule_initialized: false,
            schedule_recovery_pending: false,
            schedule_last_poll: Instant::now() - Duration::from_secs(2),
            schedule_completions: Vec::new(),
            schedule_error: None,
            unsaved_threads: HashMap::new(),
            enabled_queues: HashSet::new(),
        }
    }
    pub fn dispatch(&mut self, request: Value) -> Value {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let method = request["method"].as_str().unwrap_or("");
        // Apply cancellation intent before polling can dispatch the next message.
        if !matches!(
            method,
            "agent.queue.pause" | "agent.queue.remove" | "agent.stop"
        ) {
            self.poll();
        }
        match self.execute(method, &request["params"]) {
            Ok(result) => json!({"id":id,"result":result}),
            Err(e) => json!({"id":id,"error":{"message":e.to_string()}}),
        }
    }
    fn execute(&mut self, method: &str, p: &Value) -> Result<Value> {
        match method {
            "providers.list"=>Ok(json!({"catalog":crate::provider_catalog::provider_catalog(),"discovery":self.provider_discovery,"runtimeConnected":Provider::supported_names(),"discoveryOnly":true})),
            "attachments.add" => {
                ensure!(self.workspace_pending.len()<32 && self.attachment_operations.len()<4,"Too many attachment imports; wait for existing imports to finish");
                let thread=required(p,"threadId")?.to_owned();
                ensure!(!self.unsaved_threads.contains_key(&thread),"Transcript persistence is recovering; retry after recovery");
                let value=self.store.thread(&thread)?;
                ensure!(!self.store.is_imported(&thread)?,"Fork an imported thread before adding attachments");
                ensure!(value["rustDraftImages"].as_array().map_or(0,Vec::len)<20,"A draft can contain at most 20 images");
                let source=PathBuf::from(required(p,"path")?);
                ensure!(source.is_absolute(),"Image path must be absolute");
                let root=self.store.data_directory()?;
                let id=Uuid::new_v4().to_string();
                self.workspace_pending.insert(id.clone(),(thread,Instant::now()));
                self.attachment_operations.insert(id.clone());
                let tx=self.workspace_tx.clone();let operation=id.clone();
                std::thread::spawn(move || {
                    let result=crate::attachments::ingest_image(&root,&source)
                        .and_then(|image|Ok(json!({"attachment":serde_json::to_value(image)?})))
                        .unwrap_or_else(|error|json!({"error":error.to_string()}));
                    let _=tx.try_send((operation,result));
                });
                Ok(json!({"operationId":id}))
            }
            "attachments.remove" => {
                let id=required(p,"threadId")?;
                ensure!(!self.unsaved_threads.contains_key(id),"Transcript persistence is recovering; retry after recovery");
                let attachment=required(p,"attachmentId")?;
                let mut thread=self.store.thread(id)?;
                ensure!(!self.store.is_imported(id)?,"Fork an imported thread before changing attachments");
                let images=thread["rustDraftImages"].as_array_mut().context("Draft has no image attachments")?;
                let before=images.len();images.retain(|value|value["id"]!=attachment);
                ensure!(images.len()<before,"Draft image not found");
                self.store.save(&thread)?;self.revision+=1;
                Ok(json!({"removed":true}))
            }
            "schedules.list"=> {
                let service=crate::schedule_service::ScheduleService::new(&mut self.store);
                let mut tasks=service.list()?;
                for task in &mut tasks {task["approvalState"]=serde_json::to_value(service.approval_state(&text(task,"id"))?)?;}
                Ok(json!({"tasks":tasks.into_iter().filter(|task|p["threadId"].as_str().is_none_or(|id|task["threadID"]==id)).collect::<Vec<_>>(),"executionAvailable":self.schedule_initialized,"error":self.schedule_error}))
            }
            "schedules.create"=> {
                let task=crate::schedule_service::ScheduleService::new(&mut self.store).create(&p["task"],chrono::Utc::now())?;
                self.revision+=1;Ok(json!({"task":task,"executionAvailable":self.schedule_initialized}))
            }
            "schedules.patch"=> {
                let task=crate::schedule_service::ScheduleService::new(&mut self.store).patch(required(p,"scheduleId")?,&p["patch"],chrono::Utc::now())?;
                self.revision+=1;Ok(json!({"task":task,"executionAvailable":self.schedule_initialized}))
            }
            "schedules.pause" | "schedules.resume"=> {
                let task=crate::schedule_service::ScheduleService::new(&mut self.store).set_paused(required(p,"scheduleId")?,method=="schedules.pause",chrono::Utc::now())?;
                self.revision+=1;Ok(json!({"task":task,"executionAvailable":self.schedule_initialized}))
            }
            "schedules.delete"=> {
                let removed=crate::schedule_service::ScheduleService::new(&mut self.store).delete(required(p,"scheduleId")?)?;
                self.revision+=1;Ok(json!({"removed":removed}))
            }
            "schedules.run-now"=> {
                ensure!(self.schedule_initialized,"Scheduler recovery has not completed");
                let id=required(p,"scheduleId")?;
                let job=crate::schedule_service::ScheduleService::new(&mut self.store).plan_now(id,chrono::Utc::now())?;
                self.launch_schedule(&job)?;
                Ok(json!({"task":crate::schedule_service::ScheduleService::new(&mut self.store).list()?.into_iter().find(|v|v["id"]==id)}))
            }
            "git.status" | "git.diff" | "files.list" | "files.read" => {
                ensure!(self.workspace_pending.len()<32,"Too many workspace operations; collect results first");
                let thread=required(p,"threadId")?;
                let cwd=self.working_directory(&self.store.thread(thread)?)?;
                let id=Uuid::new_v4().to_string();
                self.workspace_pending.insert(id.clone(),(thread.into(),Instant::now()));
                let tx=self.workspace_tx.clone();let params=p.clone();let operation=id.clone();let method=method.to_owned();
                std::thread::spawn(move || {
                    let result=(||->Result<Value>{
                        match method.as_str() {
                            "git.status"=>crate::workspace::status(&cwd),
                            "git.diff"=>crate::workspace::diff(&cwd,params["path"].as_str(),params["staged"].as_bool().unwrap_or(false)),
                            "files.list"=>crate::workspace::files(&cwd,params["query"].as_str().unwrap_or(""),params["limit"].as_u64().unwrap_or(200) as usize),
                            "files.read"=>crate::workspace::read_file(&cwd,required(&params,"path")?,params["lineOffset"].as_u64().unwrap_or(0) as usize,params["lineLimit"].as_u64().unwrap_or(200) as usize),
                            _=>unreachable!(),
                        }
                    })().unwrap_or_else(|e|json!({"error":e.to_string()}));
                    let _=tx.try_send((operation,result));
                });
                Ok(json!({"operationId":id}))
            }
            "workspace.result"=>{
                let id=required(p,"operationId")?;
                let (owner,started)=self.workspace_pending.get(id).context("Workspace operation not found")?;
                ensure!(owner==required(p,"threadId")?,"Workspace operation belongs to another thread");
                if let Some(result)=self.workspace_results.remove(id) {
                    self.workspace_pending.remove(id);return Ok(json!({"ready":true,"result":result}));
                }
                if started.elapsed()>Duration::from_secs(if self.attachment_operations.contains(id){120}else{20}) {
                    self.workspace_pending.remove(id);return Ok(json!({"ready":true,"result":{"error":"Workspace operation timed out"}}));
                }
                Ok(json!({"ready":false}))
            }
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
            "app.quit"=>{ensure!(self.unsaved_threads.is_empty() && self.runs.values().all(|run|run.persistence_error.is_none()),"Transcript changes are not saved yet; wait for persistence recovery before quitting");self.shutdown=true;self.revision+=1;Ok(json!({"requested":true}))}
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
            "terminal.read"=>{
                let terminal=&mut self.terminals.get_mut(required(p,"terminalId")?).context("Terminal not found")?.1;
                if p["styled"]==true {
                    terminal.styled_snapshot(usize::try_from(p["rowOffset"].as_u64().unwrap_or(0))?,usize::try_from(p["rowLimit"].as_u64().unwrap_or(10))?)
                } else {terminal.snapshot()}
            },
            "terminal.write"=>{self.terminals.get_mut(required(p,"terminalId")?).context("Terminal not found")?.1.write(required(p,"text")?)?;Ok(json!({"accepted":true}))}
            "terminal.resize"=>{
                let rows=u16::try_from(p["rows"].as_u64().context("Missing rows")?)?;
                let cols=u16::try_from(p["cols"].as_u64().context("Missing cols")?)?;
                self.terminals.get_mut(required(p,"terminalId")?).context("Terminal not found")?.1.resize(rows,cols)?;Ok(json!({"resized":true}))
            }
            "terminal.close"=>{ensure!(self.terminals.remove(required(p,"terminalId")?).is_some(),"Terminal not found");self.revision+=1;Ok(json!({"closed":true}))}
            "app.status" => Ok(
                json!({"version":env!("CARGO_PKG_VERSION"),"revision":self.revision,"running":self.runs.keys().collect::<Vec<_>>(),"preview":true,"activeThread":self.active_thread,"persistencePending":self.unsaved_threads.len(),"schedulerError":self.schedule_error}),
            ),
            "app.capabilities" => Ok(json!([
                "app.status", "app.quit", "terminal.create", "terminal.list", "terminal.read", "terminal.write", "terminal.resize", "terminal.close",
                "app.capabilities", "providers.list", "browser.request", "browser.result", "git.status", "git.diff", "files.list", "files.read", "workspace.result", "attachments.add", "attachments.remove",
                "schedules.list", "schedules.create", "schedules.patch", "schedules.pause", "schedules.resume", "schedules.delete", "schedules.run-now",
                "projects.list", "projects.create", "projects.patch", "projects.remove", "settings.read", "settings.patch",
                "threads.list",
                "threads.read",
                "threads.open",
                "threads.create",
                "threads.patch",
                "threads.fork", "threads.edit-branch",
                "agent.queue.add", "agent.queue.list", "agent.queue.remove", "agent.queue.pause", "agent.queue.resume", "agent.send",
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
                let id=required(p,"threadId")?;
                let mut v=if let Some(v)=self.unsaved_threads.get(id){v.clone()}else{self.store.thread(id)?};
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
                ensure!(!self.unsaved_threads.contains_key(required(p,"threadId")?),"Transcript persistence is recovering; retry this edit after recovery");
                let v=self.store.patch_thread(required(p,"threadId")?,&p["patch"])?;
                self.revision+=1;Ok(v)
            }
            "threads.fork" | "threads.edit-branch" => {
                let id=required(p,"threadId")?;
                ensure!(!self.unsaved_threads.contains_key(id), "Transcript persistence is recovering; retry after recovery");
                let source=self.store.thread(id)?;
                let new_id=Uuid::new_v4().to_string().to_uppercase();
                let running_turn = self.runs.get(id).map(|run| {
                    source["items"].as_array().and_then(|items|items.get(run.transcript_start.saturating_sub(1)))
                        .and_then(|item|item["id"].as_str()).context("Running turn boundary is unavailable")
                }).transpose()?;
                let options=crate::thread_history::HistoryOptions {
                    new_thread_id:&new_id, now:swift_timestamp(), running_turn_id:running_turn, turn_openers:&[],
                };
                let plan=if method == "threads.edit-branch" {
                    crate::thread_history::edit_from_user(&source,required(p,"itemId")?,options)?
                } else {
                    crate::thread_history::fork_through_turn(&source,p["itemId"].as_str(),options)?
                };
                let mut branch=plan.thread;
                branch["accessMode"]=json!("approval");
                branch["interactionMode"]=json!("build");
                // Imported sessions/accounts cannot attach to the live legacy app.
                branch["selection"]=json!({"provider":source["selection"]["provider"].as_str().filter(|name|Provider::from_name(name).is_ok()).unwrap_or("codex"),"modelID":source["selection"]["modelID"].as_str().unwrap_or("default")});
                self.store.save(&branch)?;
                self.revision+=1;
                Ok(branch)
            }
            "agent.select" => {
                let id = required(p, "threadId")?;
                ensure!(!self.unsaved_threads.contains_key(id),"Transcript persistence is recovering; retry after recovery");
                ensure!(!self.runs.contains_key(id), "Stop the current turn before changing provider");
                let provider = required(p, "provider")?;
                Provider::from_name(provider)?;
                let model = p["model"].as_str().unwrap_or("default");
                ensure!(model.len() <= 512 && !model.chars().any(char::is_control), "Invalid model ID");
                let mut v = self.store.thread(id)?;
                ensure!(!self.store.is_imported(id)?, "Fork an imported thread before changing its provider");
                v["selection"] = json!({"provider":provider,"modelID":model});
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
            "agent.queue.add" | "agent.queue.list" | "agent.queue.remove" | "agent.queue.pause" | "agent.queue.resume" => self.queue_command(method, p),
            "agent.send" => self.send_turn(p,false),
            "agent.stop" => {
                let run=self.runs.get_mut(required(p,"threadId")?).context("Thread is not running")?;
                run.cancelled=true;run.session.stop();
                self.enabled_queues.remove(required(p,"threadId")?);
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
    /// Trusted native UI entry point. Deliberately not part of the agent dispatcher.
    fn send_turn(&mut self, p: &Value, scheduled: bool) -> Result<Value> {
        let id = required(p, "threadId")?.to_owned();
        ensure!(
            !self.unsaved_threads.contains_key(&id),
            "Transcript persistence is recovering; retry after recovery"
        );
        ensure!(
            !self.runs.contains_key(&id),
            "This thread is already running"
        );
        if !scheduled {
            ensure!(
                !self.attachment_operations.iter().any(|operation| self
                    .workspace_pending
                    .get(operation)
                    .is_some_and(|(owner, _)| owner == &id)),
                "Wait for this thread's image imports to finish before sending"
            );
        }
        let prompt = required(p, "text")?;
        ensure!(
            prompt.len() <= 1024 * 1024,
            "Message text must fit within 1 MiB"
        );
        let mut v = self.store.thread(&id)?;
        let draft_images: Vec<crate::attachments::StoredImage> =
            if scheduled || v["rustDraftImages"].is_null() {
                Vec::new()
            } else {
                ensure!(
                    v["rustDraftImages"]
                        .as_array()
                        .context("Invalid draft image metadata")?
                        .len()
                        <= 20,
                    "A draft can contain at most 20 images"
                );
                serde_json::from_value(v["rustDraftImages"].clone())
                    .context("Invalid draft image metadata")?
            };
        ensure!(
            !prompt.trim().is_empty() || !draft_images.is_empty(),
            "Add text or an image before sending"
        );
        ensure!(
            v["accessMode"]
                .as_str()
                .is_none_or(|mode| mode == "approval")
                && v["interactionMode"]
                    .as_str()
                    .is_none_or(|mode| mode == "build"),
            "This preview supports approval/build mode only; fork this conversation to use supported defaults"
        );
        let provider = text(&v["selection"], "provider");
        let adapter = Provider::from_name(&provider)?;
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
        let data = self.store.data_directory()?;
        ensure!(
            draft_images
                .iter()
                .try_fold(0u64, |total, image| total.checked_add(image.byte_len))
                .is_some_and(|bytes| bytes <= 20 * 1024 * 1024),
            "Draft images exceed 20 MiB"
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
        let seen = if session.is_some() {
            agent::provider_seen_count(&v, &provider)
        } else {
            0
        };
        let mut handoff_images = Vec::<crate::attachments::StoredImage>::new();
        let mut outgoing = String::new();
        if let Some(items) = v["items"].as_array() {
            for item in items
                .iter()
                .skip(seen)
                .filter(|item| item["kind"] == "user" || item["kind"] == "assistant")
            {
                if outgoing.is_empty() {
                    outgoing.push_str("Earlier conversation context (historical messages, not a new user request):\n");
                }
                let addition = format!("\n{}: {}\n", text(item, "kind"), text(item, "text"));
                ensure!(
                    outgoing.len() + addition.len() < 2 * 1024 * 1024,
                    "Conversation is too large for the preview handoff; start a new thread"
                );
                outgoing.push_str(&addition);
                if let Some(raw) = item["rustImages"].as_array() {
                    ensure!(
                        handoff_images.len() + raw.len() + draft_images.len() <= 20,
                        "Conversation image handoff exceeds 20 images; start a new thread"
                    );
                    for raw in raw {
                        handoff_images.push(
                            serde_json::from_value(raw.clone())
                                .context("Invalid historical image metadata")?,
                        );
                    }
                }
            }
        }
        if !outgoing.is_empty() {
            outgoing.push_str("\nCurrent user request:\n");
        }
        outgoing.push_str(prompt);
        handoff_images.extend(draft_images.iter().cloned());
        ensure!(
            handoff_images
                .iter()
                .try_fold(0u64, |total, image| total.checked_add(image.byte_len))
                .is_some_and(|bytes| bytes <= 20 * 1024 * 1024),
            "Conversation images exceed 20 MiB"
        );
        let images = handoff_images
            .iter()
            .map(|image| image.prepare_in(&data))
            .collect::<Result<Vec<_>>>()?;
        agent::validate_images(&adapter, &images)?;
        let model = v["selection"]["modelID"]
            .as_str()
            .filter(|m| !m.is_empty() && *m != "default")
            .map(str::to_owned);
        let executable_variable = match provider.as_str() {
            "claude" => "COINCIDE_CLAUDE_EXECUTABLE",
            "codex" => "COINCIDE_CODEX_EXECUTABLE",
            "grok" => "COINCIDE_GROK_EXECUTABLE",
            "opencode" => "COINCIDE_OPENCODE_EXECUTABLE",
            _ => bail!("Provider executable is not configured"),
        };
        let executable = std::env::var_os(executable_variable)
            .map(PathBuf::from)
            .unwrap_or_else(|| provider.clone().into());
        append(&mut v, "user", prompt, None);
        if !draft_images.is_empty() {
            v["items"].as_array_mut().unwrap().last_mut().unwrap()["rustImages"] =
                serde_json::to_value(&draft_images)?;
        }
        if !scheduled {
            v["rustDraftImages"] = json!([]);
            v["draft"] = json!("");
        }
        v["updatedAt"] = json!(swift_timestamp());
        if v["title"] == "New conversation" {
            v["title"] = json!(if prompt.trim().is_empty() {
                "Image conversation".into()
            } else {
                prompt.chars().take(70).collect::<String>()
            });
        }
        self.store.save(&v)?;
        self.runs.insert(
            id,
            Running {
                session: Session::start_with_images(
                    adapter,
                    Launch {
                        executable,
                        cwd,
                        session,
                        prompt: outgoing,
                        model,
                    },
                    images,
                ),
                provider,
                transcript_start: v["items"].as_array().map_or(0, Vec::len),
                pending: HashMap::new(),
                schedule_claim: None,
                queue_claim: None,
                cancelled: false,
                events: VecDeque::new(),
                persistence_error: None,
            },
        );
        self.revision += 1;
        Ok(json!({"accepted":true}))
    }
    fn queue_command(&mut self, method: &str, p: &Value) -> Result<Value> {
        use crate::message_queue::{self as queue, State};
        let id = required(p, "threadId")?;
        ensure!(
            !self.unsaved_threads.contains_key(id),
            "Transcript persistence is recovering; retry after recovery"
        );
        let mut thread = self.store.thread(id)?;
        if method == "agent.queue.list" {
            return Ok(
                json!({"messages":queue::read(&thread)?, "error":thread["rustQueueError"],"enabled":self.enabled_queues.contains(id)}),
            );
        }
        ensure!(
            !self.store.is_imported(id)?,
            "Fork an imported thread before queueing messages"
        );
        match method {
            "agent.queue.add" => {
                ensure!(
                    p.get("images").is_none() && p.get("attachments").is_none(),
                    "Queueing supports text only"
                );
                ensure!(
                    thread["isArchived"] != true,
                    "Restore this thread before queueing messages"
                );
                Provider::from_name(&text(&thread["selection"], "provider"))?;
                // A resumed queue needs an explicit resume. Adding an entry must
                // not turn an uncertain previous dispatch into automatic execution.
                let existing = queue::read(&thread)?;
                let can_enable = existing.iter().all(|m| m.state != State::Dispatching)
                    && (self.enabled_queues.contains(id)
                        || existing.iter().all(|m| m.state != State::Pending));
                let message = queue::add(&mut thread, required(p, "text")?)?;
                thread["rustQueueError"] = Value::Null;
                self.store.save(&thread)?;
                if can_enable {
                    self.enabled_queues.insert(id.into());
                }
                self.revision += 1;
                return Ok(
                    json!({"message":message,"error":thread["rustQueueError"],"enabled":self.enabled_queues.contains(id)}),
                );
            }
            "agent.queue.pause" => {
                self.enabled_queues.remove(id);
            }
            "agent.queue.resume" => {
                ensure!(
                    thread["isArchived"] != true,
                    "Restore this thread before resuming messages"
                );
                let mut messages = queue::read(&thread)?;
                let active = self.runs.get(id).and_then(|run| run.queue_claim.as_deref());
                for message in &mut messages {
                    if message.state == State::Dispatching && active != Some(message.id.as_str()) {
                        message.state = State::Interrupted;
                        message.error = Some("Previous dispatch was interrupted or unconfirmed; it will not be replayed automatically".into());
                    }
                }
                queue::write(&mut thread, &messages)?;
                thread["rustQueueError"] = Value::Null;
                self.store.save(&thread)?;
                self.enabled_queues.insert(id.into());
            }
            "agent.queue.remove" => {
                let message_id = required(p, "messageId")?;
                let mut messages = queue::read(&thread)?;
                let index = messages
                    .iter()
                    .position(|m| m.id == message_id)
                    .context("Queued message not found")?;
                ensure!(
                    messages[index].state != State::Dispatching,
                    "Stop this turn before removing its message"
                );
                messages.remove(index);
                queue::write(&mut thread, &messages)?;
                self.store.save(&thread)?;
            }
            _ => bail!("Unsupported queue command"),
        }
        self.revision += 1;
        Ok(
            json!({"messages":queue::read(&thread)?,"error":thread["rustQueueError"],"enabled":self.enabled_queues.contains(id)}),
        )
    }
    fn poll_message_queues(&mut self) {
        use crate::message_queue::{self as queue, State};
        let ids: Vec<_> = self.enabled_queues.iter().cloned().collect();
        for id in ids {
            if self.runs.contains_key(&id) || self.unsaved_threads.contains_key(&id) {
                continue;
            }
            let launched = (|| -> Result<bool> {
                let mut thread = self.store.thread(&id)?;
                ensure!(
                    !self.store.is_imported(&id)? && thread["isArchived"] != true,
                    "Queued thread is unavailable"
                );
                let mut messages = queue::read(&thread)?;
                let Some(index) = messages.iter().position(|m| m.state == State::Pending) else {
                    return Ok(false);
                };
                ensure!(
                    !messages.iter().any(|m| m.state == State::Dispatching),
                    "Queue has an unconfirmed dispatch; resume it explicitly"
                );
                // Model/account changes must not silently redirect already queued work.
                ensure!(
                    messages[index].selection == thread["selection"],
                    "Provider selection changed; remove and requeue this message"
                );
                messages[index].state = State::Dispatching;
                let message = messages[index].clone();
                queue::write(&mut thread, &messages)?;
                self.store.save(&thread)?;
                self.revision += 1;
                match self.send_turn(&json!({"threadId":id,"text":message.text}), true) {
                    Ok(_) => {
                        self.runs.get_mut(&id).unwrap().queue_claim = Some(message.id);
                        Ok(true)
                    }
                    Err(error) => {
                        queue::finish(
                            &mut thread,
                            &message.id,
                            State::Failed,
                            Some(&error.to_string()),
                        )?;
                        self.store.save(&thread)?;
                        Err(error)
                    }
                }
            })();
            if !matches!(launched, Ok(true)) {
                self.enabled_queues.remove(&id);
                self.revision += 1;
                // The queued text remains persisted even when preflight fails.
                if let Err(error) = launched
                    && let Ok(mut thread) = self.store.thread(&id)
                {
                    thread["rustQueueError"] = json!(error.to_string());
                    let _ = self.store.save(&thread);
                }
            }
        }
    }

    pub fn approve_schedule(&mut self, id: &str) -> Result<Value> {
        ensure!(
            self.schedule_initialized,
            "Scheduler recovery has not completed"
        );
        let approved = crate::schedule_service::ScheduleService::new(&mut self.store)
            .approve(id, chrono::Utc::now())?;
        self.revision += 1;
        Ok(serde_json::to_value(approved)?)
    }
    fn poll_schedules(&mut self, resumed: bool) -> Result<()> {
        use crate::schedule_service::ScheduleService;
        let now = chrono::Utc::now();
        self.schedule_recovery_pending |= resumed;
        if !self.schedule_initialized || self.schedule_recovery_pending {
            let count =
                ScheduleService::new(&mut self.store).recover(now, !self.schedule_initialized)?;
            self.schedule_initialized = true;
            self.schedule_recovery_pending = false;
            if count > 0 {
                self.revision += 1;
            }
        }
        // A failed disk write must never cause a second provider submission.
        while let Some((claim, outcome, message)) = self.schedule_completions.pop() {
            match ScheduleService::new(&mut self.store).complete(
                &claim,
                outcome,
                message.as_deref(),
                now,
            ) {
                Ok(changed) => {
                    if changed {
                        self.revision += 1;
                    }
                }
                Err(error) => {
                    self.schedule_completions.push((claim, outcome, message));
                    return Err(error);
                }
            }
        }
        let jobs = ScheduleService::new(&mut self.store).plan_due(now)?;
        for job in jobs.into_iter().take(16) {
            self.launch_schedule(&job)?;
        }
        Ok(())
    }
    fn launch_schedule(&mut self, job: &crate::schedule_service::DueJob) -> Result<()> {
        use crate::schedule_service::{Outcome, ScheduleService, TargetState};
        let task = ScheduleService::new(&mut self.store)
            .list()?
            .into_iter()
            .find(|task| task["id"] == job.schedule_id)
            .context("Schedule no longer exists")?;
        let state = if let Some(id) = task["threadID"].as_str() {
            match self.store.thread(id) {
                Ok(thread) if thread["isArchived"] == true => TargetState::Archived,
                Ok(_) if self.runs.contains_key(id) => TargetState::Busy,
                Ok(thread) => {
                    if self.store.is_imported(id)?
                        || self.unsaved_threads.contains_key(id)
                        || self
                            .working_directory(&thread)
                            .map_or(true, |path| !path.is_dir())
                    {
                        TargetState::Unavailable
                    } else {
                        TargetState::Ready
                    }
                }
                Err(_) => TargetState::Missing,
            }
        } else if self.store.projects()?.as_array().is_some_and(|projects| {
            projects.iter().any(|project| {
                project["id"] == task["projectID"]
                    && project["path"]
                        .as_str()
                        .is_some_and(|path| std::path::Path::new(path).is_dir())
            })
        }) {
            TargetState::Ready
        } else {
            TargetState::Unavailable
        };
        let claim = ScheduleService::new(&mut self.store).claim(job, state, chrono::Utc::now())?;
        self.revision += 1;
        let Some(claim) = claim else {
            return Ok(());
        };
        let launched = (|| -> Result<()> {
            let thread = if let Some(id) = &claim.thread_id {
                id.clone()
            } else {
                let thread =
                    self.execute("threads.create", &json!({"projectId":claim.project_id}))?;
                let id = text(&thread, "id");
                ensure!(
                    ScheduleService::new(&mut self.store).attach_thread(&claim.claim_id, &id)?,
                    "Schedule changed before its thread was attached"
                );
                id
            };
            self.send_turn(&json!({"threadId":thread,"text":claim.prompt}), true)?;
            self.runs
                .get_mut(&thread)
                .context("Scheduled turn did not start")?
                .schedule_claim = Some(claim.claim_id.clone());
            Ok(())
        })();
        if let Err(error) = launched {
            self.schedule_completions.push((
                claim.claim_id,
                Outcome::Failed,
                Some(error.to_string()),
            ));
        }
        Ok(())
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
        self.workspace_pending
            .retain(|_, (_, started)| started.elapsed() < Duration::from_secs(300));
        self.workspace_results
            .retain(|id, _| self.workspace_pending.contains_key(id));
        for (id, mut result) in self.workspace_rx.try_iter() {
            let is_attachment = self.attachment_operations.remove(&id);
            if id == "provider-discovery" {
                self.provider_discovery = Some(result);
                self.revision += 1;
                continue;
            }
            if self.workspace_pending.contains_key(&id) {
                if is_attachment && result.get("error").is_none() {
                    let owner = self.workspace_pending[&id].0.clone();
                    let saved = (|| -> Result<()> {
                        ensure!(
                            !self.unsaved_threads.contains_key(&owner),
                            "Transcript persistence is recovering; image was imported but not added to draft"
                        );
                        let mut thread = self.store.thread(&owner)?;
                        if thread["rustDraftImages"].is_null() {
                            thread["rustDraftImages"] = json!([]);
                        }
                        let images = thread["rustDraftImages"]
                            .as_array_mut()
                            .context("Invalid draft image metadata")?;
                        ensure!(images.len() < 20, "A draft can contain at most 20 images");
                        let total = images
                            .iter()
                            .map(|v| v["byteLen"].as_u64().unwrap_or(u64::MAX))
                            .try_fold(0u64, |sum, size| sum.checked_add(size))
                            .context("Invalid image byte total")?;
                        ensure!(
                            total.saturating_add(
                                result["attachment"]["byteLen"]
                                    .as_u64()
                                    .context("Missing image size")?
                            ) <= 20 * 1024 * 1024,
                            "Draft images exceed 20 MiB"
                        );
                        images.push(result["attachment"].clone());
                        self.store.save(&thread)?;
                        Ok(())
                    })();
                    if let Err(error) = saved {
                        result["error"] = json!(error.to_string());
                        result["attached"] = json!(false);
                    }
                }
                self.workspace_results.insert(id, result);
                self.revision += 1;
            }
        }
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
            if let Some(run) = self.runs.get_mut(&id)
                && run.events.is_empty()
            {
                run.events.extend(run.session.events.try_iter().take(256));
            }
            if self.runs[&id].events.is_empty() {
                continue;
            }
            let mut v = if let Some(v) = self.unsaved_threads.get(&id) {
                v.clone()
            } else {
                match self.store.thread(&id) {
                    Ok(v) => v,
                    Err(error) => {
                        let message = format!("Transcript read failed: {error}");
                        let run = self.runs.get_mut(&id).unwrap();
                        run.persistence_error = Some(message.clone());
                        run.session.stop();
                        self.schedule_error = Some(message);
                        continue;
                    }
                }
            };
            let events = std::mem::take(&mut self.runs.get_mut(&id).unwrap().events);
            let mut finished = false;
            let mut failure = None;
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
                        failure = Some(error.clone());
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
            if finished
                && failure.is_none()
                && !self.runs[&id].cancelled
                && self.runs[&id].persistence_error.is_none()
            {
                agent::mark_provider_seen(&mut v, &self.runs[&id].provider);
            }
            if finished {
                let run = &self.runs[&id];
                let failed = failure.is_some() || run.cancelled || run.persistence_error.is_some();
                if failed {
                    self.enabled_queues.remove(&id);
                }
                if let Some(claim) = &run.queue_claim {
                    let state = if run.cancelled {
                        crate::message_queue::State::Interrupted
                    } else if failed {
                        crate::message_queue::State::Failed
                    } else {
                        crate::message_queue::State::Completed
                    };
                    if let Err(error) =
                        crate::message_queue::finish(&mut v, claim, state, failure.as_deref())
                    {
                        self.enabled_queues.remove(&id);
                        failure = Some(error.to_string());
                    }
                }
            }
            if let Err(error) = self.store.save(&v) {
                let message = format!("Transcript could not be saved: {error}");
                self.enabled_queues.remove(&id);
                self.unsaved_threads.insert(id.clone(), v);
                let run = self.runs.get_mut(&id).unwrap();
                run.persistence_error = Some(message.clone());
                run.session.stop();
                self.schedule_error = Some(message);
            } else {
                self.unsaved_threads.remove(&id);
            }
            self.revision += 1;
            if finished
                && let Some(run) = self.runs.remove(&id)
                && let Some(claim) = run.schedule_claim
            {
                let failure = failure.or(run.persistence_error);
                let outcome = if run.cancelled {
                    crate::schedule_service::Outcome::Interrupted
                } else if failure.is_some() {
                    crate::schedule_service::Outcome::Failed
                } else {
                    crate::schedule_service::Outcome::Completed
                };
                self.schedule_completions.push((claim, outcome, failure));
            }
        }
        self.poll_message_queues();
        if self.schedule_last_poll.elapsed() >= Duration::from_secs(1) {
            let resumed = self.schedule_last_poll.elapsed() > Duration::from_secs(120);
            self.schedule_last_poll = Instant::now();
            self.unsaved_threads
                .retain(|_, thread| self.store.save(thread).is_err());
            match self.poll_schedules(resumed) {
                Ok(()) => {
                    self.schedule_error = if !self.unsaved_threads.is_empty() {
                        Some("Transcript persistence is recovering; unsaved changes remain in memory".into())
                    } else {
                        self.runs
                            .values()
                            .find_map(|run| run.persistence_error.clone())
                    };
                }
                Err(error) => self.schedule_error = Some(error.to_string()),
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
    #[test]
    fn provider_selection_matches_runtime_support_and_rejects_invalid_models() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::new(Store::open(&dir.path().join("data.sqlite")).unwrap());
        let created = engine.execute("threads.create", &json!({})).unwrap();
        let id = created["id"].clone();
        let catalog = engine.execute("providers.list", &json!({})).unwrap();
        assert_eq!(
            catalog["runtimeConnected"],
            json!(Provider::supported_names())
        );
        for provider in Provider::supported_names() {
            let selected = engine
                .execute(
                    "agent.select",
                    &json!({"threadId":id,"provider":provider,"model":"fixture-model"}),
                )
                .unwrap();
            assert_eq!(selected["selection"]["provider"], *provider);
            assert_eq!(selected["selection"]["modelID"], "fixture-model");
        }
        let before = engine.store.thread(id.as_str().unwrap()).unwrap();
        for provider in ["cursor", "antigravity", "unknown"] {
            assert!(
                engine
                    .execute("agent.select", &json!({"threadId":id,"provider":provider}))
                    .is_err()
            );
        }
        for model in ["bad\nmodel".to_owned(), "x".repeat(513)] {
            assert!(
                engine
                    .execute(
                        "agent.select",
                        &json!({"threadId":id,"provider":"codex","model":model})
                    )
                    .is_err()
            );
        }
        assert_eq!(engine.store.thread(id.as_str().unwrap()).unwrap(), before);
    }
    #[test]
    fn queue_pause_and_remove_take_priority_over_idle_dispatch() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::new(Store::open(&dir.path().join("queue.sqlite")).unwrap());
        let mut thread = engine
            .execute("threads.create", &json!({"cwd":dir.path()}))
            .unwrap();
        let id = text(&thread, "id");
        let message = crate::message_queue::add(&mut thread, "must not launch").unwrap();
        engine.store.save(&thread).unwrap();
        engine.enabled_queues.insert(id.clone());
        let paused =
            engine.dispatch(json!({"method":"agent.queue.pause","params":{"threadId":id}}));
        assert!(paused.get("error").is_none());
        assert!(engine.runs.is_empty());
        assert_eq!(
            crate::message_queue::read(&engine.store.thread(&id).unwrap()).unwrap()[0].state,
            crate::message_queue::State::Pending
        );
        engine.enabled_queues.insert(id.clone());
        let removed = engine.dispatch(
            json!({"method":"agent.queue.remove","params":{"threadId":id,"messageId":message.id}}),
        );
        assert!(removed.get("error").is_none());
        assert!(engine.runs.is_empty());
        assert!(
            crate::message_queue::read(&engine.store.thread(&id).unwrap())
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn history_api_creates_isolated_draft_and_settled_branches() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::new(Store::open(&dir.path().join("history.sqlite")).unwrap());
        let mut source = engine
            .execute("threads.create", &json!({"cwd":dir.path()}))
            .unwrap();
        append(&mut source, "user", "first", None);
        append(&mut source, "assistant", "answer", None);
        append(&mut source, "user", "edit me", None);
        source["sessions"] = json!({"codex":{"sessionID":"never-resume-parent"}});
        source["draft"] = json!("original draft");
        engine.store.save(&source).unwrap();
        let id = source["id"].clone();
        let fork = engine
            .execute(
                "threads.fork",
                &json!({"threadId":id,"itemId":source["items"][0]["id"]}),
            )
            .unwrap();
        assert_eq!(fork["items"].as_array().unwrap().len(), 2);
        assert_eq!(fork["sessions"], json!({}));
        let edit = engine
            .execute(
                "threads.edit-branch",
                &json!({"threadId":id,"itemId":source["items"][2]["id"]}),
            )
            .unwrap();
        assert_eq!(edit["draft"], "edit me");
        assert_eq!(edit["items"].as_array().unwrap().len(), 2);
        assert_ne!(edit["id"], source["id"]);
        assert_eq!(engine.store.thread(id.as_str().unwrap()).unwrap(), source);
    }
}
