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

#[path = "active_thread.rs"]
mod active_thread;
#[path = "admission_freeze.rs"]
mod admission_freeze;
#[cfg(test)]
#[path = "admission_freeze_tests.rs"]
mod admission_freeze_tests;
#[path = "provider_antigravity_api.rs"]
mod antigravity_api;
#[cfg(test)]
#[path = "attachment_completion_tests.rs"]
mod attachment_completion_tests;
#[path = "background_workers.rs"]
mod background_workers;
#[path = "bot_engine.rs"]
mod bot_engine;
#[path = "browser_bookmarks_api.rs"]
mod browser_bookmarks_api;
#[path = "codex_login_profiles_api.rs"]
mod codex_login_profiles_api;
#[path = "codex_tool_metadata.rs"]
mod codex_tool_metadata;
pub use browser_bookmarks_api::{PreparedBookmarkOpen, QueuedBookmarkOpen};
#[cfg(test)]
#[path = "browser_bookmarks_api_tests.rs"]
mod browser_bookmarks_api_tests;
pub use background_workers::BackgroundShutdownStatus;
#[cfg(test)]
#[path = "composer_astra_api_tests.rs"]
mod composer_astra_api_tests;
#[path = "composer_context_api.rs"]
mod composer_context_api;
#[cfg(test)]
#[path = "composer_context_boundary_tests.rs"]
mod composer_context_boundary_tests;
#[path = "composer_effort_api.rs"]
mod composer_effort_api;
#[cfg(test)]
#[path = "composer_effort_api_tests.rs"]
mod composer_effort_api_tests;
#[cfg(test)]
#[path = "composer_speed_api_tests.rs"]
mod composer_speed_api_tests;
#[path = "computer_use_engine.rs"]
pub mod computer_use_engine;
#[path = "github_engine.rs"]
mod github_engine;
#[path = "github_threads_engine.rs"]
mod github_threads_engine;
#[path = "idle_sleep.rs"]
mod idle_sleep;
#[path = "notification_events.rs"]
pub mod notification_events;
#[path = "organization_api.rs"]
mod organization_api;
#[cfg(test)]
#[path = "provider_worker_tests.rs"]
mod provider_worker_tests;
#[path = "session_import_api.rs"]
mod session_import_api;
#[path = "shutdown_owner.rs"]
mod shutdown_owner;
pub use shutdown_owner::CoreOwnerShutdownStatus;
#[path = "steering_api.rs"]
mod steering_api;
#[path = "terminal_shutdown.rs"]
pub mod terminal_shutdown;
#[path = "thread_defaults.rs"]
mod thread_defaults;
#[path = "thread_resolution.rs"]
mod thread_resolution;
#[path = "workspace_api.rs"]
mod workspace_api;
#[cfg(test)]
#[path = "workspace_runtime_tests.rs"]
mod workspace_runtime_tests;

pub type SharedEngine = Arc<Mutex<Engine>>;
pub use idle_sleep::IdleShutdownStatus;
/// Sampled provider Rust-thread ownership, not whole-app quiescence or process
/// cleanup acceptance. Terminal outcomes remain counted after run retirement.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ProviderWorkersStatus {
    pub running: usize,
    pub returned: u64,
    pub panicked: u64,
    pub unclassified: u64,
}
struct Running {
    usage_context: Option<agent::usage_capture::TurnContext>,
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
    model_catalog: crate::model_catalog::ModelCatalog,
    github_threads: github_threads_engine::State,
    computer_use: computer_use_engine::State,
    pub store: Store,
    idle_sleep: idle_sleep::IdleSleep,
    github: github_engine::GithubState,
    notification_events: notification_events::Outbox,
    runs: HashMap<String, Running>,
    provider_workers: Vec<agent::WorkerCompletion>,
    background_workers: background_workers::State,
    provider_worker_outcomes: ProviderWorkersStatus,
    pub revision: u64,
    pub requested_open: Option<String>,
    terminals: HashMap<String, (String, crate::terminal::Terminal)>,
    terminal_shutdown: terminal_shutdown::State,
    pub shutdown: bool,
    admissions_frozen: bool,
    active_thread: Option<String>,
    pub ui_available: bool,
    bookmark_owner: Uuid,
    pub browser_requests: VecDeque<crate::browser_protocol::BrowserRequest>,
    browser_pending: HashMap<String, (String, Instant)>,
    browser_results: HashMap<String, crate::browser_protocol::BrowserReply>,
    workspace_pending: HashMap<String, (String, Instant)>,
    workspace_results: HashMap<String, Value>,
    workspace_git_operations: HashSet<String>,
    // Running mutations outlive result collection deadlines. Only worker
    // completion may release their exclusion. This is intentionally in-memory.
    workspace_mutations: HashSet<String>,
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
    pending_usage: HashMap<String, agent::usage_capture::Record>,
    steering_operations: HashMap<String, steering_api::Operation>,
    enabled_queues: HashSet<String>,
}
impl Engine {
    pub fn new(store: Store) -> Self {
        Self::initialize(store, true)
    }
    #[cfg(test)]
    fn fixture(store: Store) -> Self {
        Self::initialize(store, false)
    }
    fn initialize(store: Store, discover: bool) -> Self {
        let (workspace_tx, workspace_rx) = std::sync::mpsc::sync_channel(32);
        let mut background_workers = background_workers::State::default();
        if discover {
            let discovery_tx = workspace_tx.clone();
            let worker = std::thread::spawn(move || {
                let report = crate::provider_catalog::discover_installed_tools();
                workspace_api::publish_completion(
                    discovery_tx,
                    "provider-discovery".into(),
                    json!(report),
                );
            });
            background_workers.track(worker);
        }
        let idle_sleep = idle_sleep::IdleSleep::new(&store);
        let notification_events = notification_events::Outbox::new(&store);
        Self {
            model_catalog: crate::model_catalog::ModelCatalog::default(),
            github_threads: github_threads_engine::State::default(),
            computer_use: computer_use_engine::State::default(),
            store,
            idle_sleep,
            notification_events,
            github: if discover {
                github_engine::GithubState::discover()
            } else {
                github_engine::GithubState::unavailable()
            },
            runs: HashMap::new(),
            provider_workers: Vec::new(),
            background_workers,
            provider_worker_outcomes: ProviderWorkersStatus::default(),
            revision: 0,
            requested_open: None,
            terminals: HashMap::new(),
            terminal_shutdown: terminal_shutdown::State::default(),
            shutdown: false,
            admissions_frozen: false,
            active_thread: None,
            ui_available: false,
            bookmark_owner: Uuid::new_v4(),
            browser_requests: VecDeque::new(),
            browser_pending: HashMap::new(),
            browser_results: HashMap::new(),
            workspace_pending: HashMap::new(),
            workspace_results: HashMap::new(),
            workspace_git_operations: HashSet::new(),
            workspace_mutations: HashSet::new(),
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
            pending_usage: HashMap::new(),
            steering_operations: HashMap::new(),
            enabled_queues: HashSet::new(),
        }
    }
    pub fn dispatch(&mut self, request: Value) -> Value {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        if let Err(error) = self.require_admissions() {
            return json!({"id":id,"error":{"message":error.to_string()}});
        }
        let method = request["method"].as_str().unwrap_or("");
        // Apply cancellation intent before polling can dispatch the next message.
        if !matches!(
            method,
            "agent.queue.pause" | "agent.queue.remove" | "agent.stop"
        ) {
            self.poll();
        }
        let result = self.execute(method, &request["params"]);
        self.idle_sleep.update(self.runs.len(), self.shutdown);
        match result {
            Ok(result) => json!({"id":id,"result":result}),
            Err(e) => json!({"id":id,"error":{"message":e.to_string()}}),
        }
    }
    fn execute(&mut self, method: &str, p: &Value) -> Result<Value> {
        self.require_admissions()?;
        if method == "threads.resolve_id" {
            return self.resolve_thread_id_command(p);
        }
        if computer_use_engine::METHODS.contains(&method) {
            return self.computer_use_command(method, p, None);
        }
        if github_threads_engine::METHODS.contains(&method) {
            return self.github_threads_command(method, p);
        }
        if github_engine::METHODS.contains(&method) {
            return self.github_command(method, p);
        }
        if method == "bots.conversations.create" {
            return self.create_bot_conversation(p);
        }
        if organization_api::METHODS.contains(&method) {
            return self.organization_command(method, p);
        }
        if workspace_api::METHODS.contains(&method) {
            return self.workspace_command(method, p);
        }
        match method {
            "notifications.status" => Ok(self.notification_events.status()),
            "host.awake.status" | "host.awake.configure" => self.awake_command(method, p),
            "cli.sessions.preview" => {
                ensure!(cfg!(unix), "CLI-session file import is not supported on this platform yet");
                session_import_api::preview(p)
            }
            "cli.sessions.import" => {
                ensure!(cfg!(unix), "CLI-session file import is not supported on this platform yet");
                let result = session_import_api::import(&mut self.store, p)?;
                self.revision += 1;
                Ok(result)
            }
            "providers.codex.profiles.status" | "providers.codex.profiles.create" | "providers.codex.profiles.select" => self.codex_login_profile_command(method,p),
            "providers.antigravity.status" | "providers.antigravity.configure" | "providers.antigravity.acknowledge" => self.antigravity_command(method,p),
            "providers.list"=>Ok(json!({"catalog":crate::provider_catalog::provider_catalog(),"discovery":self.provider_discovery,"runtimeConnected":Provider::supported_names(),"discoveryOnly":true})),
            "attachments.add" => {
                self.require_background_admission()?;
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
                let activity = self.idle_sleep.background_job();
                let worker = std::thread::spawn(move || {
                    let _activity = activity;
                    import_attachment(root, source, tx, operation, || {});
                });
                self.background_workers.track(worker);
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
                self.require_background_admission()?;
                ensure!(self.workspace_pending.len()<32,"Too many workspace operations; collect results first");
                let thread=required(p,"threadId")?;
                let cwd=self.working_directory(&self.store.thread(thread)?)?;
                let id=Uuid::new_v4().to_string();
                self.workspace_pending.insert(id.clone(),(thread.into(),Instant::now()));
                let tx=self.workspace_tx.clone();let params=p.clone();let operation=id.clone();let method=method.to_owned();
                let activity = self.idle_sleep.background_job();
                let worker = std::thread::spawn(move || {
                    let _activity = activity;
                    let result=(||->Result<Value>{
                        match method.as_str() {
                            "git.status"=>crate::workspace::status(&cwd),
                            "git.diff"=>crate::workspace::diff(&cwd,params["path"].as_str(),params["staged"].as_bool().unwrap_or(false)),
                            "files.list"=>crate::workspace::files(&cwd,params["query"].as_str().unwrap_or(""),params["limit"].as_u64().unwrap_or(200) as usize),
                            "files.read"=>crate::workspace::read_file(&cwd,required(&params,"path")?,params["lineOffset"].as_u64().unwrap_or(0) as usize,params["lineLimit"].as_u64().unwrap_or(200) as usize),
                            _=>unreachable!(),
                        }
                    })().unwrap_or_else(|e|json!({"error":e.to_string()}));
                    workspace_api::publish_completion(tx, operation, result);
                });
                self.background_workers.track(worker);
                Ok(json!({"operationId":id}))
            }
            "workspace.result"=>{
                let id=required(p,"operationId")?;
                ensure!(!self.workspace_git_operations.contains(id),"Use git.workspace.result for this operation");
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
            "browser.bookmarks.list" | "browser.bookmarks.import" | "browser.bookmarks.open" => self.browser_bookmarks_command(method,p),
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
            "app.quit"=>{ensure!(self.unsaved_threads.is_empty() && self.runs.values().all(|run|run.persistence_error.is_none()),"Transcript changes are not saved yet; wait for persistence recovery before quitting");self.computer_use_shutdown();self.shutdown=true;self.revision+=1;Ok(json!({"requested":true}))}
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
            "terminal.prompt_marks"=>{
                #[derive(serde::Deserialize)]
                #[serde(rename_all="camelCase",deny_unknown_fields)]
                struct Request { terminal_id:String, revision:u64 }
                let request:Request=serde_json::from_value(p.clone())?;
                let terminal=&mut self.terminals.get_mut(&request.terminal_id).context("Terminal not found")?.1;
                terminal.prompt_marks(request.revision)
            }
            "terminal.scroll"=>{
                // Reject misspelled fields and invalid deltas before changing the
                // viewport. Revision is required even for absolute/no-op moves.
                #[derive(serde::Deserialize)]
                #[serde(rename_all="camelCase",deny_unknown_fields)]
                struct Request {
                    terminal_id:String,
                    revision:u64,
                    scroll:crate::terminal::TerminalScroll,
                }
                let request:Request=serde_json::from_value(p.clone())?;
                let terminal=&mut self.terminals.get_mut(&request.terminal_id).context("Terminal not found")?.1;
                let changed=terminal.scroll_checked(request.revision,request.scroll)?;
                if changed {self.revision+=1;}
                let frame=terminal.snapshot()?;
                Ok(json!({"changed":changed,"frame":frame}))
            }
            "terminal.selection"=>{
                let revision=p["revision"].as_u64().context("Missing terminal revision")?;
                let start:crate::terminal::TerminalPoint=serde_json::from_value(p["start"].clone())?;
                let end:crate::terminal::TerminalPoint=serde_json::from_value(p["end"].clone())?;
                let terminal=&mut self.terminals.get_mut(required(p,"terminalId")?).context("Terminal not found")?.1;
                Ok(json!({"text":terminal.copy_selection(revision,start,end)?,"revision":revision}))
            }
            "terminal.input"=>{
                #[derive(serde::Deserialize)]
                #[serde(rename_all="camelCase",deny_unknown_fields)]
                struct Request {terminal_id:String,input:crate::terminal::TerminalInput}
                let request:Request=serde_json::from_value(p.clone())?;
                let terminal=&mut self.terminals.get_mut(&request.terminal_id).context("Terminal not found")?.1;
                let before=terminal.revision;
                let result=terminal.input(request.input);
                if terminal.revision!=before {self.revision+=1;}
                result
            }
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
            "app.capabilities" => {
                let mut methods = vec![
                "app.status", "app.quit", "terminal.create", "terminal.list", "terminal.read", "terminal.prompt_marks", "terminal.scroll", "terminal.selection", "terminal.input", "terminal.write", "terminal.resize", "terminal.close",
                "app.capabilities", "notifications.status", "host.awake.status", "host.awake.configure", "providers.list", "providers.antigravity.status", "providers.antigravity.configure", "providers.antigravity.acknowledge", "browser.request", "browser.result", "browser.bookmarks.list", "browser.bookmarks.import", "browser.bookmarks.open", "git.status", "git.diff", "files.list", "files.read", "workspace.result", "attachments.add", "attachments.remove",
                "schedules.list", "schedules.create", "schedules.patch", "schedules.pause", "schedules.resume", "schedules.delete", "schedules.run-now",
                "projects.list", "projects.create", "projects.patch", "projects.remove", "settings.read", "settings.patch",
                "threads.list", "threads.resolve_id",
                "threads.read",
                "threads.open",
                "threads.create",
                "threads.patch",
                "threads.fork", "threads.edit-branch",
                "agent.queue.add", "agent.queue.list", "agent.queue.remove", "agent.queue.pause", "agent.queue.resume", "agent.send", "agent.steer", "agent.steer.result",
                "agent.stop",
                "agent.respond"
                ,"agent.pending", "agent.answer", "agent.select", "agent.selection.capabilities", "agent.models.refresh", "agent.models.status", "usage.codexLimits.refresh", "usage.codexLimits.status"
                ];
                methods.extend_from_slice(computer_use_engine::METHODS);
                methods.extend_from_slice(workspace_api::METHODS);
                methods.extend_from_slice(organization_api::METHODS);
                methods.push("composer.context.edit");
                methods.push("bots.conversations.create");
                #[cfg(unix)]
                methods.extend_from_slice(github_engine::METHODS);
                #[cfg(unix)]
                methods.extend_from_slice(github_threads_engine::METHODS);
                #[cfg(unix)]
                methods.extend_from_slice(&["cli.sessions.preview", "cli.sessions.import"]);
                Ok(json!(methods))
            },
            "threads.open" => {
                let id = required(p, "threadId")?;
                self.set_active_thread(Some(id.into()))?;
                self.requested_open = self.active_thread.clone();
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
            "threads.create" => self.create_ordinary_thread(p),
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
                self.preserve_bot_branch(&source,&mut branch)?;
                self.store.save(&branch)?;
                self.revision+=1;
                Ok(branch)
            }
            "usage.codexLimits.refresh" => {
                crate::model_catalog::limits::validate_refresh(p)?;
                let executable = self.codex_limits_executable();
                let result = self.model_catalog.refresh_limits(executable)?;
                self.revision += 1;
                Ok(result)
            }
            "usage.codexLimits.status" => {
                let id = crate::model_catalog::status_id(p)?;
                let executable = self.codex_limits_executable();
                let changed = self.model_catalog.limits_context(executable);
                if self.model_catalog.poll() | changed { self.revision += 1; }
                self.model_catalog.limits_status(id)
            }
            "agent.models.refresh" => {
                let provider = crate::model_catalog::refresh_provider(p)?;
                let executable = if crate::model_catalog::supported(provider) {
                    let variable = if provider == "codex" { "COINCIDE_CODEX_EXECUTABLE" } else { "COINCIDE_CLAUDE_EXECUTABLE" };
                    std::env::var_os(variable).map(PathBuf::from).or_else(|| {
                        self.provider_discovery.as_ref()?["providers"].as_array()?.iter()
                            .find(|entry| entry["provider"] == provider)?["executable"].as_str().map(PathBuf::from)
                    })
                } else { None };
                let result = self.model_catalog.refresh(provider, executable)?;
                self.revision += 1;
                Ok(result)
            }
            "agent.models.status" => {
                let id = crate::model_catalog::status_id(p)?;
                if self.model_catalog.poll() { self.revision += 1; }
                self.model_catalog.status(id)
            }
            "agent.selection.capabilities" => {
                let mut result = crate::composer_selection::capabilities();
                if let Some(id) = p.get("threadId") {
                    let id = id.as_str().context("threadId must be text")?;
                    let thread = self.store.thread(id)?;
                    let reason = if !thread["rustBotContext"].is_null() {
                        Some("Bot selection is fixed for this conversation; create a new bot conversation".to_owned())
                    } else if self.store.is_imported(id)? {
                        Some("Fork an imported thread before changing its provider".to_owned())
                    } else if self.runs.contains_key(id) {
                        Some("Stop the current turn before changing provider".to_owned())
                    } else if self.unsaved_threads.contains_key(id) {
                        Some("Transcript persistence is recovering; retry after recovery".to_owned())
                    } else {
                        self.composer_thread_effort_proof(&thread).and_then(|proof| crate::composer_selection::validate_thread_with_proof(&thread,proof.as_ref())).err().map(|error|error.to_string())
                    };
                    if thread["rustBotContext"].is_null() && thread["botID"].is_null() && !self.store.is_imported(id)?
                        && let Some(provider) = result["providers"].as_array_mut().and_then(|providers|providers.iter_mut().find(|provider|provider["provider"] == "codex")) {
                        provider["effort"] = self.composer_effort_capability(&thread["selection"]);
                        provider["speed"] = self.composer_speed_capability(&thread["selection"]);
                    }
                    // A repair capability is separate from the locked/proof state.
                    // It permits only removing effort, never sending unproved work.
                    result["repairClearAvailable"] = json!(!self.admissions_frozen() && thread["rustBotContext"].is_null()
                        && thread["botID"].is_null() && !self.store.is_imported(id)?
                        && !self.runs.contains_key(id) && !self.unsaved_threads.contains_key(id)
                        && crate::composer_selection::repair_clear_effort(&json!({"threadId":id,"effort":null}),&thread).is_ok());
                    result["repairSpeedClearAvailable"] = json!(!self.admissions_frozen() && thread["rustBotContext"].is_null()
                        && thread["botID"].is_null() && !self.store.is_imported(id)?
                        && !self.runs.contains_key(id) && !self.unsaved_threads.contains_key(id)
                        && crate::composer_selection::repair_clear_speed(&json!({"threadId":id,"speed":null}),&thread).is_ok());
                    result["repairOptionsClearAvailable"] = json!(!self.admissions_frozen() && thread["rustBotContext"].is_null()
                        && thread["botID"].is_null() && !self.store.is_imported(id)?
                        && !self.runs.contains_key(id) && !self.unsaved_threads.contains_key(id)
                        && crate::composer_selection::repair_clear_options(&json!({"threadId":id,"effort":null,"speed":null}),&thread).is_ok());
                    result["canReplaceUnprovedAutomaticDefault"] = json!(!self.admissions_frozen()
                        && thread["rustBotContext"].is_null() && thread["botID"].is_null() && !self.store.is_imported(id)?
                        && !self.runs.contains_key(id) && !self.unsaved_threads.contains_key(id)
                        && crate::model_catalog::astra_default_needed(&thread["selection"]) && thread["selection"]["speed"].is_null()
                        && crate::composer_selection::validate_thread_base(&thread).is_ok()
                        && self.composer_thread_effort_proof(&thread).is_err());
                    result["locked"] = json!(reason.is_some());
                    result["lockReason"] = json!(reason);
                }
                Ok(result)
            }
            "agent.select" => {
                let id = required(p, "threadId")?;
                ensure!(!self.unsaved_threads.contains_key(id),"Transcript persistence is recovering; retry after recovery");
                ensure!(!self.runs.contains_key(id), "Stop the current turn before changing provider");
                let mut v = self.store.thread(id)?;
                ensure!(!self.store.is_imported(id)?, "Fork an imported thread before changing its provider");
                ensure!(v["rustBotContext"].is_null() && v["botID"].is_null(),"Bot selection is fixed for this conversation; create a new bot conversation");
                if p.get("effort").is_some_and(Value::is_null) && p.get("speed").is_some_and(Value::is_null)
                    && let Ok(selection) = crate::composer_selection::repair_clear_options(p,&v)
                {
                    v["selection"] = selection;
                    self.store.save(&v)?; self.revision += 1;
                    return Ok(v);
                }
                if p.get("effort").is_some_and(Value::is_null) && !v["selection"]["effort"].is_null()
                    && let Ok(selection) = crate::composer_selection::repair_clear_effort(p,&v)
                {
                    // This exact one-field repair needs no provider/catalog IO.
                    v["selection"] = selection;
                    self.store.save(&v)?; self.revision += 1;
                    return Ok(v);
                }
                if p.get("speed").is_some_and(Value::is_null) && !v["selection"]["speed"].is_null()
                    && let Ok(selection) = crate::composer_selection::repair_clear_speed(p,&v)
                {
                    v["selection"] = selection;
                    self.store.save(&v)?; self.revision += 1;
                    return Ok(v);
                }
                let current_proof = self.composer_current_selection_proof(&v)?;
                let target_proof = self.composer_target_effort_proof(p)?;
                let selection = crate::composer_selection::select_with_proofs(p, &v,current_proof.as_ref(),target_proof.as_ref())?;
                if selection["provider"] == "antigravity" {
                    self.antigravity_selection(&selection)?;
                }
                v["selection"] = selection;
                crate::composer_selection::apply_modes_with_proof(p,&mut v,target_proof.as_ref())?;
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
                run.pending.remove(key);
                self.notification_events.cancel_request(required(p,"threadId")?,key);
                self.revision += 1;
                Ok(json!({"answered":true}))
            }
            "agent.queue.add" | "agent.queue.list" | "agent.queue.remove" | "agent.queue.pause" | "agent.queue.resume" => self.queue_command(method, p),
            "agent.steer" | "agent.steer.result" => self.steer_command(method,p),
            "composer.context.edit" => self.edit_composer_context(p),
            "agent.send" => self.send_turn(p,false),
            "agent.stop" => {
                self.request_provider_stop(required(p,"threadId")?)?;
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
                self.notification_events.cancel_request(required(p,"threadId")?,key);
                self.revision += 1;
                Ok(json!({"answered":true}))
            }
            _ => bail!("Unsupported method: {method}"),
        }
    }
    /// Trusted native UI entry point. Deliberately not part of the agent dispatcher.
    fn send_turn(&mut self, p: &Value, scheduled: bool) -> Result<Value> {
        self.require_admissions()?;
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
        ensure!(
            p.get("context").is_none() && p.get("draftContext").is_none(),
            "Attach references through composer.context.edit before sending"
        );
        // Scheduled/queued turns never consume the user's unrelated composer.
        let context = if scheduled {
            Value::Null
        } else {
            v["draftContext"].clone()
        };
        crate::composer_context::validate(&context)?;
        let runtime_prompt = crate::composer_context::prompt(prompt, &context)?;
        let codex_profile = self.codex_login_context(&v)?;
        ensure!(
            codex_profile.is_none() || !scheduled,
            "Named Codex profiles are not connected to queued/scheduled dispatch"
        );
        let validation_thread = if codex_profile.is_some() {
            crate::codex_login_profiles::validation_view(&v)
        } else {
            v.clone()
        };
        let effort_proof = self.composer_thread_effort_proof(&validation_thread)?;
        crate::composer_selection::validate_thread_with_proof(
            &validation_thread,
            effort_proof.as_ref(),
        )?;
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
            !prompt.trim().is_empty()
                || !draft_images.is_empty()
                || crate::composer_context::has_context(&context),
            "Add text, an image or a reference before sending"
        );
        // Imported native sessions may still be owned by the running Swift app.
        // A fork starts a separate provider session and cannot steal that session.
        ensure!(
            !self.store.is_imported(&id)?,
            "Imported conversations are read-only for agent execution until cutover; fork first"
        );
        let cwd = self.working_directory(&v)?;
        ensure!(cwd.is_dir(), "Working directory does not exist");
        let bot_instructions = self.bot_instructions(&v, &cwd)?;
        let mode_policy = if v["selection"]["provider"] == "codex" && bot_instructions.is_none() {
            Some(crate::composer_policy::Policy::parse_with_effort_proof(
                &validation_thread,
                crate::composer_policy::Origin::Ordinary,
                effort_proof.as_ref(),
            )?)
        } else {
            None
        };
        let provider = text(&v["selection"], "provider");
        let mut adapter = Provider::from_name(&provider)?;
        ensure!(
            provider == "antigravity"
                || codex_profile.is_some()
                || crate::composer_selection::default_account(&v["selection"]["accountID"])
                || bot_instructions.is_some(),
            "Alternate provider accounts are not connected yet"
        );
        let data = self.store.data_directory()?;
        let antigravity_executable = if provider == "antigravity" {
            let launch_selection = crate::composer_selection::launch_selection(&v["selection"])?;
            let (configured, executable) = self.antigravity_launch(&id, &launch_selection)?;
            adapter = configured;
            Some(executable)
        } else {
            None
        };
        if let Provider::Cursor { profile } = &mut adapter {
            *profile = Some(data.join("providers").join("cursor").join(&id));
        }
        ensure!(
            draft_images
                .iter()
                .try_fold(0u64, |total, image| total.checked_add(image.byte_len))
                .is_some_and(|bytes| bytes <= 20 * 1024 * 1024),
            "Draft images exceed 20 MiB"
        );
        // account/read exposes display metadata, not stable account authority.
        // Named profiles use a fresh native thread and full context replay.
        let session = if codex_profile.is_some() {
            None
        } else {
            agent::provider_session(&v, &provider)
        };
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
                let historical =
                    crate::composer_context::prompt(&text(item, "text"), &item["context"])?;
                let addition = format!("\n{}: {}\n", text(item, "kind"), historical);
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
        ensure!(
            outgoing.len() + runtime_prompt.len() <= 2 * 1024 * 1024,
            "Conversation and attached references exceed the preview handoff limit"
        );
        outgoing.push_str(&runtime_prompt);
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
        let model = crate::composer_selection::launch_model(&v["selection"])?;
        let executable_variable = match provider.as_str() {
            "claude" => "COINCIDE_CLAUDE_EXECUTABLE",
            "codex" => "COINCIDE_CODEX_EXECUTABLE",
            "grok" => "COINCIDE_GROK_EXECUTABLE",
            "opencode" => "COINCIDE_OPENCODE_EXECUTABLE",
            "cursor" => "COINCIDE_CURSOR_EXECUTABLE",
            "antigravity" => "COINCIDE_ANTIGRAVITY_EXECUTABLE",
            _ => bail!("Provider executable is not configured"),
        };
        let executable = antigravity_executable
            .or_else(|| std::env::var_os(executable_variable).map(PathBuf::from))
            .unwrap_or_else(|| {
                if provider == "cursor" {
                    "cursor-agent".into()
                } else {
                    provider.clone().into()
                }
            });
        // Use exactly the executable whose catalog authorized effort, not a
        // later PATH lookup or another configured provider/account.
        let executable = if let Some(profile) = &codex_profile {
            profile.executable().to_path_buf()
        } else if effort_proof.is_some() {
            self.composer_codex_executable()?
        } else {
            executable
        };
        if let Some(policy) = &mode_policy {
            policy.validate_launch_executable(&executable)?;
        }
        append(&mut v, "user", prompt, None);
        if crate::composer_context::has_context(&context) {
            v["items"].as_array_mut().unwrap().last_mut().unwrap()["context"] = context;
        }
        if !draft_images.is_empty() {
            v["items"].as_array_mut().unwrap().last_mut().unwrap()["rustImages"] =
                serde_json::to_value(&draft_images)?;
        }
        if !scheduled {
            v["rustDraftImages"] = json!([]);
            v["draft"] = json!("");
            v.as_object_mut().unwrap().remove("draftContext");
        }
        v["updatedAt"] = json!(swift_timestamp());
        if v["title"] == "New conversation" {
            v["title"] = json!(if prompt.trim().is_empty() {
                if draft_images.is_empty() {
                    "Reference conversation".into()
                } else {
                    "Image conversation".into()
                }
            } else {
                prompt.chars().take(70).collect::<String>()
            });
        }
        self.store.save(&v)?;
        self.insert_running(
            id,
            Running {
                usage_context: Some(agent::usage_capture::TurnContext::new(&v)),
                session: Session::start_with_mode_policy_and_profile(
                    adapter,
                    Launch {
                        executable,
                        cwd,
                        session,
                        prompt: outgoing,
                        model,
                    },
                    images,
                    bot_instructions,
                    mode_policy,
                    codex_profile,
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
    fn insert_running(&mut self, id: String, run: Running) {
        self.provider_workers.push(run.session.worker_completion());
        self.runs.insert(id, run);
    }
    /// Nonblocking observer for trusted native owners. Background observers join
    /// provider threads; completed observations fold into sticky counters here.
    pub fn provider_workers_status(&mut self) -> ProviderWorkersStatus {
        let totals = &mut self.provider_worker_outcomes;
        self.provider_workers.retain(|worker| {
            let counter = match worker.status() {
                agent::WorkerThreadStatus::Running => return true,
                agent::WorkerThreadStatus::Returned => &mut totals.returned,
                agent::WorkerThreadStatus::Panicked => &mut totals.panicked,
                agent::WorkerThreadStatus::Unclassified => return true,
            };
            *counter = counter.saturating_add(1);
            false
        });
        ProviderWorkersStatus {
            running: self.provider_workers.len(),
            unclassified: totals.unclassified
                + self
                    .provider_workers
                    .iter()
                    .filter(|w| w.status() == agent::WorkerThreadStatus::Unclassified)
                    .count() as u64,
            ..*totals
        }
    }
    /// Request idle-host release and off-thread join after admission freeze.
    pub fn request_idle_host_shutdown(&mut self) -> Result<()> {
        ensure!(
            self.admissions_frozen(),
            "Idle host shutdown requires frozen admissions"
        );
        self.idle_sleep.request_shutdown();
        Ok(())
    }
    /// Native host ownership only; does not certify other Engine work is drained.
    pub fn idle_host_shutdown_status(&mut self) -> Result<IdleShutdownStatus> {
        ensure!(
            self.admissions_frozen(),
            "Idle host shutdown status requires frozen admissions"
        );
        Ok(self.idle_sleep.poll_shutdown())
    }
    /// Trusted owner-only catalog cancellation after Engine admission freeze.
    /// This requests cancellation and never waits for a worker or process.
    pub fn request_model_catalog_shutdown(&mut self) -> Result<()> {
        ensure!(
            self.admissions_frozen(),
            "Catalog shutdown requires frozen admissions"
        );
        self.model_catalog.request_shutdown();
        Ok(())
    }
    /// Catalog thread ownership only, not whole-app quiescence or child cleanup.
    pub fn model_catalog_shutdown_status(
        &mut self,
    ) -> Result<crate::model_catalog::ShutdownStatus> {
        ensure!(
            self.admissions_frozen(),
            "Catalog shutdown status requires frozen admissions"
        );
        Ok(self.model_catalog.shutdown_status())
    }
    fn queue_command(&mut self, method: &str, p: &Value) -> Result<Value> {
        self.require_admissions()?;
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
                    p.get("context").is_none() && p.get("draftContext").is_none(),
                    "Queueing attached references is not supported"
                );
                crate::composer_context::validate(&thread["draftContext"])?;
                ensure!(
                    !crate::composer_context::has_context(&thread["draftContext"]),
                    "Queueing attached references is not supported; keep this draft for a normal send"
                );
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
        if self.admissions_frozen() {
            return;
        }
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
        self.require_admissions()?;
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
        if self.admissions_frozen() {
            return Ok(());
        }
        let jobs = ScheduleService::new(&mut self.store).plan_due(now)?;
        for job in jobs.into_iter().take(16) {
            self.launch_schedule(&job)?;
        }
        Ok(())
    }
    fn launch_schedule(&mut self, job: &crate::schedule_service::DueJob) -> Result<()> {
        self.require_admissions()?;
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
    fn poll_workspace_completions(&mut self) {
        self.workspace_pending
            .retain(|_, (_, started)| started.elapsed() < Duration::from_secs(300));
        self.workspace_results
            .retain(|id, _| self.workspace_pending.contains_key(id));
        self.workspace_git_operations
            .retain(|id| self.workspace_pending.contains_key(id));
        for (id, mut result) in self.workspace_rx.try_iter() {
            // Worker completion, not a client timeout or abandoned result,
            // releases mutation exclusion even if its result has expired.
            self.workspace_mutations.remove(&id);
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
    }
    fn codex_limits_executable(&self) -> Option<PathBuf> {
        std::env::var_os("COINCIDE_CODEX_EXECUTABLE")
            .map(PathBuf::from)
            .or_else(|| {
                self.provider_discovery.as_ref()?["providers"]
                    .as_array()?
                    .iter()
                    .find(|entry| entry["provider"] == "codex")?["executable"]
                    .as_str()
                    .map(PathBuf::from)
            })
    }
    pub fn poll(&mut self) {
        self.poll_steering();
        self.provider_workers_status();
        self.computer_use_expire();
        let limits_executable = self.codex_limits_executable();
        let limits_changed = self.model_catalog.limits_context(limits_executable);
        if self.model_catalog.poll() | limits_changed {
            self.revision += 1;
        }
        self.poll_workspace_completions();
        self.background_workers.poll();
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
            // A worker publishes steering ACK before Finished. Recheck after
            // receiving terminal events so accepted input precedes seen-count
            // advancement and cannot be recapped into the next turn twice.
            self.poll_steering();
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
            let mut completion_alert = None;
            let transcript_start = self.runs[&id].transcript_start;
            for event in events {
                if matches!(&event, Event::Finished | Event::Failed(_)) {
                    let run = self.runs.get_mut(&id).unwrap();
                    if let Some(context) = run.usage_context.take()
                        && let Some(snapshot) = run.session.take_usage()
                    {
                        self.pending_usage
                            .insert(id.clone(), context.finish(snapshot));
                    }
                }
                match event {
                    Event::Session(session) => {
                        if let Some(account) = self.runs[&id].session.codex_profile_account() {
                            agent::set_provider_session_for_account(
                                &mut v,
                                &self.runs[&id].provider,
                                account,
                                &session,
                            );
                        } else {
                            agent::set_provider_session(&mut v, &self.runs[&id].provider, &session);
                        }
                    }
                    Event::Finished => {
                        finished = true;
                        append(&mut v, "notice", "Turn ended", None);
                        if completion_alert.is_none() {
                            completion_alert = v["items"]
                                .as_array()
                                .and_then(|items| items.last())
                                .cloned()
                                .map(|item| {
                                    (
                                        crate::platform_host::notifications::AlertKind::Completed,
                                        item,
                                    )
                                });
                        }
                    }
                    Event::Failed(error) => {
                        finished = true;
                        failure = Some(error.clone());
                        append(&mut v, "error", &error, None);
                        completion_alert = v["items"]
                            .as_array()
                            .and_then(|items| items.last())
                            .cloned()
                            .map(|item| {
                                (crate::platform_host::notifications::AlertKind::Failed, item)
                            });
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
                                let kind = if method == "item/tool/requestUserInput" {
                                    "question"
                                } else {
                                    "approval"
                                };
                                let previous = v["items"]
                                    .as_array()
                                    .unwrap()
                                    .iter()
                                    .skip(transcript_start)
                                    .find(|item| item["externalID"] == key && item["kind"] == kind)
                                    .cloned();
                                let item = if let Some(item) = previous {
                                    item
                                } else {
                                    append(&mut v, kind, &p.to_string(), Some(&key));
                                    v["items"].as_array().unwrap().last().unwrap().clone()
                                };
                                self.notification_events.stage(
                                    &v,
                                    &item,
                                    if kind == "question" {
                                        crate::platform_host::notifications::AlertKind::Question
                                    } else {
                                        crate::platform_host::notifications::AlertKind::Approval
                                    },
                                    Some(key.clone()),
                                );
                                self.runs.get_mut(&id).unwrap().pending.insert(key, frame);
                            }
                            "provider/requestCancelled" => {
                                let key = p["id"].to_string();
                                self.runs.get_mut(&id).unwrap().pending.remove(&key);
                                self.notification_events.cancel_request(&id, &key);
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
                                        codex_tool_metadata::apply(
                                            existing,
                                            &self.runs[&id].provider,
                                            item,
                                        );
                                    } else {
                                        append(&mut v, "tool", &item.to_string(), Some(&external));
                                        codex_tool_metadata::apply(
                                            v["items"].as_array_mut().unwrap().last_mut().unwrap(),
                                            &self.runs[&id].provider,
                                            item,
                                        );
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
                if let Some(account) = self.runs[&id].session.codex_profile_account() {
                    agent::mark_provider_seen_for_account(
                        &mut v,
                        &self.runs[&id].provider,
                        account,
                    );
                } else {
                    agent::mark_provider_seen(&mut v, &self.runs[&id].provider);
                }
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
            if finished {
                self.notification_events.cancel_requests(&id);
                if !self.runs[&id].cancelled
                    && self.runs[&id].persistence_error.is_none()
                    && let Some((kind, item)) = completion_alert
                {
                    self.notification_events.stage(&v, &item, kind, None);
                }
            }
            if let Err(error) = self
                .store
                .save_with_usage(&v, self.pending_usage.get(&id).map(|record| &record.0))
            {
                let message = format!("Transcript could not be saved: {error}");
                self.enabled_queues.remove(&id);
                self.unsaved_threads.insert(id.clone(), v);
                let run = self.runs.get_mut(&id).unwrap();
                run.persistence_error = Some(message.clone());
                run.session.stop();
                self.schedule_error = Some(message);
            } else {
                self.unsaved_threads.remove(&id);
                self.pending_usage.remove(&id);
                self.notification_events.persisted(&v);
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
            self.unsaved_threads.retain(|id, thread| {
                if self
                    .store
                    .save_with_usage(thread, self.pending_usage.get(id).map(|record| &record.0))
                    .is_err()
                {
                    true
                } else {
                    self.pending_usage.remove(id);
                    self.notification_events.persisted(thread);
                    false
                }
            });
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
        self.idle_sleep.update(self.runs.len(), self.shutdown);
    }
}
// Runs only on the attachment worker. Backpressure must retain both the
// completion and worker activity until Engine::poll can receive it.
fn import_attachment(
    root: PathBuf,
    source: PathBuf,
    tx: std::sync::mpsc::SyncSender<(String, Value)>,
    operation: String,
    on_backpressure: impl FnOnce(),
) {
    let result = crate::attachments::ingest_image(&root, &source)
        .and_then(|image| Ok(json!({"attachment":serde_json::to_value(image)?})))
        .unwrap_or_else(|error| json!({"error":error.to_string()}));
    match tx.try_send((operation, result)) {
        Ok(()) | Err(std::sync::mpsc::TrySendError::Disconnected(_)) => {}
        Err(std::sync::mpsc::TrySendError::Full((operation, result))) => {
            // Private synchronization point for the saturation fixture: the
            // channel has actually refused this completion, not merely been
            // filled before an asynchronously scheduled ingestion started.
            on_backpressure();
            workspace_api::publish_completion(tx, operation, result);
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
        for provider in Provider::supported_names()
            .iter()
            .filter(|name| **name != "antigravity")
        {
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
        for provider in ["antigravity", "unknown"] {
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

#[cfg(test)]
#[path = "composer_selection_tests.rs"]
mod composer_selection_tests;

#[cfg(all(test, unix))]
mod terminal_prompt_api_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    #[test]
    fn prompt_marks_route_is_strict_revision_checked_and_read_only() {
        let dir = tempfile::tempdir().unwrap();
        let shell = dir.path().join("prompt-api-fixture");
        // A fixed synthetic executable, never a user's shell/profile. Octal
        // bytes emit one prompt marker, then an exact readiness title.
        std::fs::write(&shell,"#!/bin/sh\nstty -echo\nprintf '\\033]133;A\\007$ fixture\\033]2;prompt-api-ready\\007'\nIFS= read -r finish\n").unwrap();
        std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut terminal =
            crate::terminal::Terminal::spawn(dir.path(), shell.to_str().unwrap(), 4, 20).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        let frame = loop {
            let frame = terminal.snapshot().unwrap();
            if frame["title"] == "prompt-api-ready" {
                break frame;
            }
            assert!(
                Instant::now() < deadline,
                "synthetic prompt fixture did not finish"
            );
            std::thread::sleep(Duration::from_millis(5));
        };
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        let owner = text(&engine.execute("threads.create", &json!({})).unwrap(), "id");
        let terminal_id = Uuid::new_v4().to_string();
        engine
            .terminals
            .insert(terminal_id.clone(), (owner.clone(), terminal));
        let revision = frame["revision"].as_u64().unwrap();
        let engine_revision = engine.revision;
        let scope = json!({"terminalId":terminal_id,"revision":revision});
        let marks = engine.execute("terminal.prompt_marks", &scope).unwrap();
        assert_eq!(
            marks,
            json!({"revision":revision,"marks":[{"line":0,"col":0,"displayOffset":0}]})
        );
        assert_eq!(engine.revision, engine_revision);
        assert!(
            engine
                .execute("app.capabilities", &json!({}))
                .unwrap()
                .as_array()
                .unwrap()
                .contains(&json!("terminal.prompt_marks"))
        );
        for (key, value) in [
            ("revision", Value::Null),
            ("revision", json!(-1)),
            ("revision", json!("0")),
            ("revision", json!(revision + 1)),
            ("terminalId", json!("unknown")),
            ("unexpected", json!(true)),
        ] {
            let mut invalid = scope.clone();
            invalid[key] = value;
            assert!(
                engine.execute("terminal.prompt_marks", &invalid).is_err(),
                "accepted {invalid}"
            );
        }
        let unchanged = engine
            .execute("terminal.read", &json!({"terminalId":terminal_id}))
            .unwrap();
        assert_eq!(unchanged["revision"], revision);
        assert_eq!(unchanged["rows"], frame["rows"]);
        engine
            .execute(
                "terminal.resize",
                &json!({"terminalId":terminal_id,"rows":5,"cols":20}),
            )
            .unwrap();
        assert!(engine.execute("terminal.prompt_marks", &scope).is_err());
        let current = engine
            .execute("terminal.read", &json!({"terminalId":terminal_id}))
            .unwrap();
        assert!(
            engine
                .execute(
                    "terminal.prompt_marks",
                    &json!({"terminalId":terminal_id,"revision":current["revision"]})
                )
                .is_ok()
        );
        engine
            .execute("terminal.close", &json!({"terminalId":terminal_id}))
            .unwrap();
        assert!(engine.execute("terminal.prompt_marks", &scope).is_err());
        assert_eq!(engine.store.thread(&owner).unwrap()["id"], owner);
    }
}

#[cfg(test)]
mod catalog_shutdown_adapter_tests {
    use super::*;
    #[test]
    fn catalog_shutdown_adapters_require_frozen_admissions_and_add_no_json_route() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        assert!(engine.request_model_catalog_shutdown().is_err());
        assert!(engine.model_catalog_shutdown_status().is_err());
        engine.freeze_admissions();
        engine.request_model_catalog_shutdown().unwrap();
        engine.request_model_catalog_shutdown().unwrap();
        let status = engine.model_catalog_shutdown_status().unwrap();
        assert!(status.closed);
        assert_eq!(status.running, 0);
        assert_eq!(status.panicked, 0);
        assert!(!engine.shutdown);
        let reply =
            engine.dispatch(json!({"method":"agent.models.refresh","params":{"provider":"codex"}}));
        assert_eq!(reply["error"]["message"], "Engine admissions are frozen");
    }
}

#[cfg(test)]
#[path = "usage_capture_engine_tests.rs"]
mod usage_capture_engine_tests;

#[cfg(test)]
#[path = "composer_policy_api_tests.rs"]
mod composer_policy_api_tests;
