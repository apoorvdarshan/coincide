//! One command dispatcher for the desktop and the local CLI/API.
#[path = "github_checkout_api.rs"]
mod github_checkout_api;
#[path = "reply_selection_api.rs"]
mod reply_selection_api;
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

#[path = "appshots_api.rs"]
mod appshots_api;
#[path = "checkpoint_api.rs"]
mod checkpoint_api;
#[cfg(test)]
#[path = "checkpoint_api_tests.rs"]
mod checkpoint_api_tests;
#[path = "git_actions_api.rs"]
mod git_actions_api;
#[path = "terminal_api.rs"]
mod terminal_api;
pub use appshots_api::{AppshotTicket, PreparedAppshot};

#[path = "queue_dispatch.rs"]
mod queue_dispatch;

#[path = "async_question_api.rs"]
mod async_question_api;
#[path = "follow_up_api.rs"]
mod follow_up_api;
#[path = "handoff_prompt.rs"]
mod handoff_prompt;
#[path = "project_defaults.rs"]
pub mod project_defaults;
#[path = "queue_edit_api.rs"]
mod queue_edit_api;
pub use follow_up_api::{CapturedNativeSend, NativeFollowUpStatus, NativeFollowUpTicket};
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
#[path = "bot_starters.rs"]
mod bot_starters;
#[path = "browser_bookmarks_api.rs"]
mod browser_bookmarks_api;
#[path = "browser_history_api.rs"]
mod browser_history_api;
#[path = "browser_link_api.rs"]
mod browser_link_api;
#[path = "browser_settings_api.rs"]
mod browser_settings_api;
#[cfg(test)]
#[path = "desktop_poll_tests.rs"]
mod desktop_poll_tests;
#[path = "named_profile_departure_api.rs"]
mod named_profile_departure;
#[cfg(test)]
#[path = "run_clock_tests.rs"]
mod run_clock_tests;
pub use browser_history_api::{AdmittedHistoryOpen, PreparedHistoryOpen};
#[path = "acp_registry_api.rs"]
mod acp_registry_api;
#[path = "codex_login_profiles_api.rs"]
mod codex_login_profiles_api;
#[path = "codex_profile_limits_api.rs"]
mod codex_profile_limits_api;
#[path = "codex_profile_login_api.rs"]
mod codex_profile_login_api;
#[path = "codex_profile_models_api.rs"]
mod codex_profile_models_api;
#[path = "composer_choices_api.rs"]
mod composer_choices_api;
#[path = "project_management_api.rs"]
mod project_management_api;
#[path = "project_scripts_api.rs"]
mod project_scripts_api;
#[path = "provider_restore_api.rs"]
mod provider_restore_api;
#[path = "provider_switch_api.rs"]
mod provider_switch_api;
mod provider_tool_metadata;
pub use browser_bookmarks_api::{PreparedBookmarkOpen, QueuedBookmarkOpen};
pub use browser_link_api::QueuedBrowserLink;
#[cfg(test)]
#[path = "browser_bookmarks_api_tests.rs"]
mod browser_bookmarks_api_tests;
pub use background_workers::BackgroundShutdownStatus;
#[cfg(test)]
#[path = "composer_astra_api_tests.rs"]
mod composer_astra_api_tests;
#[path = "composer_context_api.rs"]
mod composer_context_api;
#[path = "composer_file_reference.rs"]
mod composer_file_reference;
#[path = "composer_suggestions_api.rs"]
mod composer_suggestions_api;
pub use composer_suggestions_api::{NativeCommandDiscovery, NativeCommandReceipt};
#[path = "terminal_activity_api.rs"]
mod terminal_activity_api;
#[path = "terminal_context_api.rs"]
mod terminal_context_api;
#[cfg(test)]
#[path = "terminal_context_tests.rs"]
mod terminal_context_tests;
pub use composer_file_reference::{
    AttachedFileReference, FileReference, FileReferenceList, FileReferenceScope,
};
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
#[path = "thread_activity_api.rs"]
mod thread_activity_api;
#[path = "thread_bulk_api.rs"]
mod thread_bulk_api;
pub use thread_bulk_api::{PreparedThreadFlags, ThreadFlagAction, ThreadFlagUndo};
#[path = "bot_lifecycle_api.rs"]
mod bot_lifecycle_api;
pub use bot_lifecycle_api::{BotConversationDisposition, BotDeletionUndo, PreparedBotDeletion};
#[path = "sidebar_lifecycle_api.rs"]
mod sidebar_lifecycle_api;
#[path = "thread_delete_api.rs"]
mod thread_delete_api;
pub use sidebar_lifecycle_api::{PreparedThreadMove, ThreadMoveUndo};

pub use thread_delete_api::{ConversationCleanup, PreparedThreadDeletion, ThreadDeletionUndo};
#[path = "thread_idle_api.rs"]
mod thread_idle_api;
pub use thread_idle_api::NativeNewThread;
#[path = "thread_defaults.rs"]
mod thread_defaults;
#[path = "thread_resolution.rs"]
mod thread_resolution;
#[path = "workspace_api.rs"]
mod workspace_api;
#[cfg(test)]
#[path = "workspace_runtime_tests.rs"]
mod workspace_runtime_tests;

#[path = "provider_configuration.rs"]
pub mod provider_configuration;

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
/// Closed owner-selected origin. A queued origin contains a durable native
/// claim; callers cannot select it with JSON or impersonate a scheduled turn.
enum SendOrigin {
    Ordinary,
    /// Authenticated Remote payload belongs to the phone, not the Mac's draft.
    Remote(Vec<crate::attachments::StoredImage>),
    Scheduled,
    Queued(Box<queue_dispatch::QueueClaim>),
    /// Resume an exact goal paused by Coincide after the user pauses/removes
    /// its local queue. This private origin never borrows the user's draft.
    GoalResume(agent::codex_goals::PausedGoal),
}
impl SendOrigin {
    fn consumes_composer(&self) -> bool {
        matches!(self, Self::Ordinary)
    }
    fn scheduled(&self) -> bool {
        matches!(self, Self::Scheduled)
    }
}
struct Running {
    configuration: Option<provider_configuration::LaunchConfiguration>,
    usage_context: Option<agent::usage_capture::TurnContext>,
    session: Session,
    resume_safe: Arc<std::sync::atomic::AtomicBool>,
    provider: String,
    transcript_start: usize,
    pending: HashMap<String, Value>,
    schedule_claim: Option<String>,
    queue_claim: Option<String>,
    cancelled: bool,
    events: VecDeque<Event>,
    persistence_error: Option<String>,
}
#[derive(Clone)]
struct RunClock {
    started_at: f64,
    started_monotonic: Instant,
    run_id: Uuid,
    opener: Option<String>,
    connected: bool,
    work: crate::active_work::Work,
}
pub struct Engine {
    appshots_owner: Uuid,
    thread_bulk_owner: Uuid,
    native_move_undos: HashMap<String, Uuid>,
    composer_file_owner: Uuid,
    codex_profile_login: Option<agent::codex_profile_login::Operation>,
    project_management: project_management_api::State,
    model_catalog: crate::model_catalog::ModelCatalog,
    pub(crate) native_ui_editors: crate::native_ui_edits::NativeUiEditors,
    catalog_shutdown_requested: bool,
    named_resume: crate::named_profile_resume::Registry,
    provider_restore: Option<provider_switch_api::RestoreIntent>,
    github_threads: github_threads_engine::State,
    computer_use: computer_use_engine::State,
    pub store: Store,
    idle_sleep: idle_sleep::IdleSleep,
    github: github_engine::GithubState,
    notification_events: notification_events::Outbox,
    runs: HashMap<String, Running>,
    /// When each run started and whether its provider has answered yet, for the
    /// toolbar's "Connecting…" and "Working m:ss" (`app.status` `runClocks`).
    run_clocks: HashMap<String, RunClock>,
    /// Runs whose provider has reported anything yet. The others are still
    /// starting, which the transcript's live line says ("Starting Claude…").
    answered_runs: HashSet<String>,
    provider_workers: Vec<(Option<String>, agent::WorkerCompletion)>,
    failed_thread_workers: HashSet<String>,
    background_workers: background_workers::State,
    provider_worker_outcomes: ProviderWorkersStatus,
    pub revision: u64,
    pub requested_open: Option<String>,
    /// `app.activate`: another copy of the app asked this one to come forward.
    pub activation_requested: bool,
    terminals: HashMap<String, (String, crate::terminal::Terminal)>,
    terminal_shutdown: terminal_shutdown::State,
    pub shutdown: bool,
    admissions_frozen: bool,
    active_thread: Option<String>,
    new_composer: Option<String>,
    pub ui_available: bool,
    bookmark_owner: Uuid,
    pub browser_requests: VecDeque<crate::browser_protocol::BrowserRequest>,
    browser_pending: HashMap<String, (String, Instant)>,
    /// Operations that wait longer than the usual 30 seconds (ask-user).
    browser_timeouts: HashMap<String, Duration>,
    browser_results: HashMap<String, crate::browser_protocol::BrowserReply>,
    git_actions: git_actions_api::State,
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
    provider_discovery_pending: bool,
    acp_registry: Vec<crate::acp_registry::Agent>,
    acp_registry_pending: bool,
    acp_registry_error: Option<String>,
    schedule_initialized: bool,
    schedule_recovery_pending: bool,
    schedule_last_poll: Instant,
    schedule_completions: Vec<(String, crate::schedule_service::Outcome, Option<String>)>,
    pub schedule_error: Option<String>,
    unsaved_threads: HashMap<String, Value>,
    pending_usage: HashMap<String, agent::usage_capture::Record>,
    steering_operations: HashMap<String, steering_api::Operation>,
    enabled_queues: HashSet<String>,
    queue_catalog_retry_after: Option<Instant>,
    queue_catalog_poll_after: HashMap<String, Instant>,
    goal_selection_waiting: HashSet<String>,
    native_follow_up: follow_up_api::State,
    turn_results: thread_activity_api::TurnResults,
    turn_checkpoints: checkpoint_api::State,
    composer_commands: crate::composer_suggestions::ReportedCommands,
}

/// A revision-bound thread captured while the engine is locked. Decoding the
/// stored document can happen after releasing that lock.
pub enum ThreadReadSnapshot {
    Stored(String),
    Unsaved(Value),
}
impl ThreadReadSnapshot {
    pub fn decode(self) -> Result<Value> {
        match self {
            Self::Stored(document) => Ok(serde_json::from_str(&document)?),
            Self::Unsaved(thread) => Ok(thread),
        }
    }
}
/// Where the last launch's discovered model lists live. Display metadata only.
const SAVED_MODEL_CATALOG: &str = "model-catalog.json";

impl Engine {
    pub fn unsaved_thread_for_navigation(&self, id: &str) -> Option<Value> {
        self.unsaved_threads.get(id).cloned()
    }

    pub fn capture_thread_read(&self, id: &str) -> Result<(u64, ThreadReadSnapshot, Option<bool>)> {
        let thread = match self.unsaved_threads.get(id) {
            Some(thread) => ThreadReadSnapshot::Unsaved(thread.clone()),
            None => ThreadReadSnapshot::Stored(self.store.thread_document(id)?),
        };
        let queue =
            (!self.unsaved_threads.contains_key(id)).then(|| self.enabled_queues.contains(id));
        Ok((self.revision, thread, queue))
    }

    /// The desktop also needs the original queue fields for exact-match
    /// actions; this internal view does not expand the public queue response.
    pub fn native_queue_read(&self, id: &str) -> Result<Value> {
        self.require_admissions()?;
        ensure!(
            !self.unsaved_threads.contains_key(id),
            "Transcript persistence is recovering; retry after recovery"
        );
        let thread = self.store.thread_queue_snapshot(id)?;
        crate::message_queue::native_snapshot(&thread, self.enabled_queues.contains(id))
    }

    /// Keep the latest discovered lists for the next launch. A failure here is
    /// not a user-facing error: the catalog still works for this run.
    fn save_model_catalog(&mut self) {
        let saved = self.model_catalog.saved_document();
        let empty = saved["providers"]
            .as_object()
            .is_none_or(|providers| providers.is_empty());
        if empty {
            return;
        }
        if self
            .store
            .document(SAVED_MODEL_CATALOG)
            .ok()
            .flatten()
            .as_ref()
            == Some(&saved)
        {
            return;
        }
        let _ = self.store.save_document(SAVED_MODEL_CATALOG, &saved);
    }

    pub(crate) fn remote_discovered_models(&mut self) -> Value {
        if self.model_catalog.poll() {
            self.revision += 1;
        }
        self.model_catalog.remote_default_models()
    }

    /// Preserve a pending in-memory transcript, but copy only the fields a
    /// remote sidebar needs. Persisted threads are projected by SQLite.
    pub(crate) fn remote_thread_metadata(&self, id: &str) -> Result<(Value, usize)> {
        if let Some(thread) = self.unsaved_threads.get(id) {
            let mut metadata = serde_json::Map::new();
            for key in [
                "createdAt",
                "updatedAt",
                "selection",
                "accessMode",
                "interactionMode",
                "branch",
                "worktreePath",
                "draft",
                "botID",
                "rustMessageQueue",
            ] {
                if let Some(value) = thread.get(key) {
                    metadata.insert(key.to_owned(), value.clone());
                }
            }
            let count = thread["items"].as_array().map_or(0, Vec::len);
            Ok((Value::Object(metadata), count))
        } else {
            self.store.remote_thread_metadata(id)
        }
    }

    /// The saved selection identity used by the native composer's background
    /// capability reader. Do not deserialize the transcript merely to compare
    /// these three fields before and after that read.
    pub fn saved_selection_envelope(&self, id: &str) -> Result<Value> {
        self.store.thread_selection_envelope(id)
    }

    /// Read a composer's capabilities without polling provider events again;
    /// the desktop's normal poll owns event advancement.
    pub fn selection_capabilities_snapshot(&mut self, id: &str) -> Result<Value> {
        self.require_admissions()?;
        self.execute("agent.selection.capabilities", &json!({"threadId":id}))
    }

    pub fn new(store: Store) -> Self {
        Self::initialize(store, true)
    }
    #[cfg(test)]
    pub(crate) fn fixture(store: Store) -> Self {
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
        // The last launch's discovery is display metadata a conversation opens
        // with; a live refresh replaces it.
        let mut model_catalog = crate::model_catalog::ModelCatalog::default();
        if let Ok(Some(saved)) = store.document(SAVED_MODEL_CATALOG) {
            model_catalog.restore_saved(&saved);
        }
        let mut engine = Self {
            appshots_owner: Uuid::new_v4(),
            thread_bulk_owner: Uuid::new_v4(),
            native_move_undos: HashMap::new(),
            composer_file_owner: Uuid::new_v4(),
            codex_profile_login: None,
            project_management: project_management_api::State::default(),
            model_catalog,
            catalog_shutdown_requested: false,
            native_ui_editors: Default::default(),
            named_resume: crate::named_profile_resume::Registry::for_store(&store),
            provider_restore: None,
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
            run_clocks: HashMap::new(),
            answered_runs: HashSet::new(),
            provider_workers: Vec::new(),
            failed_thread_workers: HashSet::new(),
            background_workers,
            provider_worker_outcomes: ProviderWorkersStatus::default(),
            revision: 0,
            requested_open: None,
            activation_requested: false,
            terminals: HashMap::new(),
            terminal_shutdown: terminal_shutdown::State::default(),
            shutdown: false,
            admissions_frozen: false,
            active_thread: None,
            new_composer: None,
            ui_available: false,
            bookmark_owner: Uuid::new_v4(),
            browser_requests: VecDeque::new(),
            browser_pending: HashMap::new(),
            browser_timeouts: HashMap::new(),
            browser_results: HashMap::new(),
            git_actions: git_actions_api::State::default(),
            workspace_pending: HashMap::new(),
            workspace_results: HashMap::new(),
            workspace_git_operations: HashSet::new(),
            workspace_mutations: HashSet::new(),
            attachment_operations: HashSet::new(),
            workspace_tx,
            workspace_rx,
            provider_discovery: None,
            provider_discovery_pending: discover,
            acp_registry: Vec::new(),
            acp_registry_pending: false,
            acp_registry_error: None,
            schedule_initialized: false,
            schedule_recovery_pending: false,
            schedule_last_poll: Instant::now() - Duration::from_secs(2),
            schedule_completions: Vec::new(),
            schedule_error: None,
            unsaved_threads: HashMap::new(),
            pending_usage: HashMap::new(),
            steering_operations: HashMap::new(),
            enabled_queues: HashSet::new(),
            queue_catalog_retry_after: None,
            queue_catalog_poll_after: HashMap::new(),
            goal_selection_waiting: HashSet::new(),
            native_follow_up: follow_up_api::State::default(),
            turn_results: Default::default(),
            turn_checkpoints: checkpoint_api::State::default(),
            composer_commands: Default::default(),
        };
        if discover {
            let _ = engine.refresh_native_acp_registry();
        }
        engine
    }
    pub fn native_ui_editors(&self) -> crate::native_ui_edits::NativeUiEditors {
        self.native_ui_editors.clone()
    }
    pub fn dispatch(&mut self, request: Value) -> Value {
        self.dispatch_inner(request, true)
    }

    /// The desktop's frequent status reads must not drain provider events on
    /// the UI thread. The control owner continuously polls the same engine on
    /// its own thread, including when command-line access is disabled. Only
    /// independent snapshots, provider-catalog reads, and native browser
    /// queue admission/receipts bypass that poll. Browser requests retain
    /// their own queue order; other actions retain provider-event ordering.
    pub fn dispatch_desktop(&mut self, request: Value) -> Value {
        let method = request["method"].as_str().unwrap_or("");
        let snapshot = matches!(
            method,
            "app.status"
                | "agent.pending"
                | "settings.read"
                | "projects.list"
                | "bots.list"
                | "threads.list"
                | "threads.read"
                | "schedules.list"
                | "browser.request"
                | "browser.result"
                | "host.awake.status"
                | "agent.models.refresh"
                | "agent.models.status"
                | "providers.antigravity.status"
                | "providers.codex.profiles.status"
                | "usage.codexLimits.refresh"
                | "usage.codexLimits.status"
                | "usage.claudeLimits.refresh"
                | "usage.claudeLimits.status"
                | "providers.codex.profiles.limits.refresh"
                | "providers.codex.profiles.limits.status"
        );
        self.dispatch_inner(request, !snapshot)
    }

    fn dispatch_inner(&mut self, request: Value, poll_before: bool) -> Value {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        if let Err(error) = self.require_admissions() {
            return json!({"id":id,"error":{"message":error.to_string()}});
        }
        let method = request["method"].as_str().unwrap_or("");
        // Apply cancellation intent before polling can dispatch the next message.
        if poll_before
            && !matches!(
                method,
                "agent.queue.pause" | "agent.queue.remove" | "agent.stop"
            )
        {
            self.poll();
        }
        let result = self.execute(method, &request["params"]);
        self.idle_sleep.update(self.runs.len(), self.shutdown);
        match result {
            Ok(result) => json!({"id":id,"result":result}),
            Err(e) => json!({"id":id,"error":{"message":e.to_string()}}),
        }
    }

    /// Read the current in-memory snapshot without advancing provider events.
    /// Remote workspace construction performs several reads; polling for each
    /// one repeatedly saves the active transcript and can starve the phone.
    /// Keep the allowlist narrow: actions must use normal dispatch and its
    /// ordering guarantees. The regular desktop/control poll advances events.
    pub(crate) fn dispatch_remote_snapshot(&mut self, method: &str, params: Value) -> Value {
        if !matches!(
            method,
            "app.status"
                | "agent.pending"
                | "projects.list"
                | "bots.list"
                | "threads.list"
                | "agent.selection.capabilities"
        ) {
            return json!({"error":{"message":"Unsupported remote snapshot read"}});
        }
        match self.execute(method, &params) {
            Ok(result) => json!({"result":result}),
            Err(error) => json!({"error":{"message":error.to_string()}}),
        }
    }
    fn execute(&mut self, method: &str, p: &Value) -> Result<Value> {
        self.require_admissions()?;
        let _provider_configuration_scope = self.native_provider_scope_for_command(method, p)?;
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
        if project_management_api::METHODS.contains(&method) {
            return self.project_command(method, p);
        }
        if workspace_api::METHODS.contains(&method) {
            return self.workspace_command(method, p);
        }
        if git_actions_api::METHODS.contains(&method) {
            return self.git_actions_command(method, p);
        }
        if terminal_api::METHODS.contains(&method) {
            return self.terminal_command(method, p);
        }
        if checkpoint_api::METHODS.contains(&method) {
            return self.checkpoint_command(method, p);
        }
        match method {
            "notifications.status" => Ok(self.notification_events.status()),
            "host.awake.status" | "host.awake.configure" => self.awake_command(method, p),
            "cli.sessions.preview" => {
                ensure!(cfg!(any(unix, windows)), "CLI-session file import is not supported on this platform yet");
                session_import_api::preview(&self.store, p)
            }
            "cli.sessions.import" => {
                ensure!(cfg!(any(unix, windows)), "CLI-session file import is not supported on this platform yet");
                let result = session_import_api::import(&mut self.store, p)?;
                if result["existing"] != true {
                    self.revision += 1;
                }
                Ok(result)
            }
            "providers.codex.profiles.limits.refresh" | "providers.codex.profiles.limits.status" => self.codex_profile_limits_command(method,p),
            "providers.codex.profiles.models.refresh" | "providers.codex.profiles.models.status" | "providers.codex.profiles.models.select" => self.codex_profile_model_command(method,p),
            "providers.codex.profiles.status" | "providers.codex.profiles.create" | "providers.codex.profiles.select" => self.codex_login_profile_command(method,p),
            "providers.codex.profiles.login.start" | "providers.codex.profiles.login.status" | "providers.codex.profiles.login.cancel" => self.codex_profile_login_command(method,p),
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
            "browser.settings.read" | "browser.settings.patch" => self.browser_settings_command(method,p),
            "browser.request"=>{
                ensure!(p.is_object(), "Browser request parameters must be an object");
                ensure!(self.ui_available,"Browser requires the desktop window");
                ensure!(self.browser_pending.len()<128,"Too many browser requests; collect completed results first");
                crate::browser_protocol::validate_screenshot_parameters(p)?;
                let mut params=p.clone();
                params["id"]=json!(Uuid::new_v4().to_string());
                let mut request:crate::browser_protocol::BrowserRequest=serde_json::from_value(params)?;
                request.validate()?;
                ensure!(self.store.contains_thread(&request.thread_id)?,"Conversation not found");
                self.resolve_browser_search(&mut request)?;
                let id=request.id.clone();
                let timeout=request.action.result_timeout();
                if timeout>Duration::from_secs(30){self.browser_timeouts.insert(id.clone(),timeout);}
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
                if started.elapsed()>self.browser_timeouts.get(id).copied().unwrap_or(Duration::from_secs(30)){
                    self.browser_pending.remove(id);
                    self.browser_requests.retain(|r|r.id!=id);
                    return Ok(json!({"ready":true,"result":{"error":"Browser operation timed out; read current page state before retrying"}}));
                }
                Ok(json!({"ready":false}))
            }
            "app.quit"=>{ensure!(self.native_ui_editors.pending() == 0,"Unsaved native editor changes require Save or Discard before quitting");ensure!(self.unsaved_threads.is_empty() && self.runs.values().all(|run|run.persistence_error.is_none()),"Transcript changes are not saved yet; wait for persistence recovery before quitting");self.computer_use_shutdown();self.shutdown=true;self.revision+=1;Ok(json!({"requested":true}))}
            "app.activate"=>{self.activation_requested=true;self.revision+=1;Ok(json!({"requested":true}))}
            "terminal.create"=>{
                let shell=std::env::var("SHELL").unwrap_or_else(|_|if cfg!(windows){"powershell.exe".into()}else{"/bin/sh".into()});
                self.create_terminal(p,&shell)
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
            "terminal.clear"=>{
                #[derive(serde::Deserialize)]
                #[serde(rename_all="camelCase",deny_unknown_fields)]
                struct Request {terminal_id:String}
                let request:Request=serde_json::from_value(p.clone())?;
                let terminal=&mut self.terminals.get_mut(&request.terminal_id).context("Terminal not found")?.1;
                terminal.clear()?;
                self.revision+=1;
                Ok(json!({"cleared":true}))
            }
            "terminal.resize"=>{
                let rows=u16::try_from(p["rows"].as_u64().context("Missing rows")?)?;
                let cols=u16::try_from(p["cols"].as_u64().context("Missing cols")?)?;
                self.terminals.get_mut(required(p,"terminalId")?).context("Terminal not found")?.1.resize(rows,cols)?;Ok(json!({"resized":true}))
            }
            "terminal.close"=>{ensure!(self.terminals.remove(required(p,"terminalId")?).is_some(),"Terminal not found");self.revision+=1;Ok(json!({"closed":true}))}
            "app.status" => Ok(
                json!({"version":env!("CARGO_PKG_VERSION"),"revision":self.revision,"running":self.runs.keys().collect::<Vec<_>>(),"stagedGoalSelections":self.goal_selection_waiting.iter().collect::<Vec<_>>(),"runClocks":self.run_clocks_status(),"activeWork":self.active_work_status(),"starting":self.runs.keys().filter(|id|!self.answered_runs.contains(*id)).collect::<Vec<_>>(),"preview":true,"activeThread":self.active_thread,"persistencePending":self.unsaved_threads.len(),"schedulerError":self.schedule_error,"pendingApprovals":self.pending_approvals(),"turnResults":self.turn_results.status()}),
            ),
            "app.capabilities" => {
                let mut methods = vec![
                "app.status", "app.quit", "app.activate", "terminal.create", "terminal.list", "terminal.read", "terminal.prompt_marks", "terminal.scroll", "terminal.selection", "terminal.input", "terminal.write", "terminal.clear", "terminal.resize", "terminal.close",
                "app.capabilities", "notifications.status", "host.awake.status", "host.awake.configure", "providers.list", "providers.antigravity.status", "browser.request", "browser.result", "browser.bookmarks.list", "browser.bookmarks.import", "browser.bookmarks.open", "browser.settings.read", "browser.settings.patch", "git.status", "git.diff", "files.list", "files.read", "workspace.result", "attachments.add", "attachments.remove",
                "schedules.list", "schedules.create", "schedules.patch", "schedules.pause", "schedules.resume", "schedules.delete", "schedules.run-now",
                "projects.list", "projects.create", "projects.patch", "settings.read", "settings.patch",
                "threads.list", "threads.resolve_id",
                "threads.read",
                "threads.open",
                "threads.create",
                "threads.patch",
                "threads.fork", "threads.edit-branch",
                "agent.queue.add", "agent.queue.list", "agent.queue.remove", "agent.queue.pause", "agent.queue.resume", "agent.send", "agent.steer", "agent.steer.result",
                "agent.stop",
                "agent.respond"
                ,"agent.pending", "agent.answer", "agent.dismissQuestion", "agent.provider.select", "agent.provider.cancelRestore", "agent.select", "agent.selection.capabilities", "agent.models.refresh", "agent.models.status", "usage.codexLimits.refresh", "usage.codexLimits.status", "usage.claudeLimits.refresh", "usage.claudeLimits.status"
                ];
                methods.extend_from_slice(&[
                    "providers.codex.profiles.status", "providers.codex.profiles.create", "providers.codex.profiles.select",
                    "providers.codex.profiles.login.start", "providers.codex.profiles.login.status", "providers.codex.profiles.login.cancel",
                    "providers.codex.profiles.models.refresh", "providers.codex.profiles.models.status", "providers.codex.profiles.models.select",
                    "providers.codex.profiles.limits.refresh", "providers.codex.profiles.limits.status",
                ]);
                methods.extend_from_slice(project_management_api::METHODS);
                methods.extend_from_slice(computer_use_engine::METHODS);
                methods.extend_from_slice(workspace_api::METHODS);
                methods.extend_from_slice(git_actions_api::METHODS);
                methods.extend_from_slice(checkpoint_api::METHODS);
                methods.extend_from_slice(organization_api::METHODS);
                methods.push("composer.context.edit");
                methods.push("composer.context.attachTerminalSelection");
                methods.push("composer.commands");
                methods.push("bots.conversations.create");
                #[cfg(unix)]
                methods.extend_from_slice(github_engine::METHODS);
                #[cfg(unix)]
                methods.extend_from_slice(github_threads_engine::METHODS);
                #[cfg(any(unix, windows))]
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
            "settings.read"=>Ok(provider_configuration::public_settings(self.store.document("settings.json")?.unwrap_or(json!({})))),
            "settings.patch"=>{let current=self.store.document("settings.json")?.unwrap_or(json!({}));ensure!(p["patch"].get(crate::computer_use::SETTING).is_none_or(|value|current.get(crate::computer_use::SETTING)==Some(value)),"Computer Use can only be turned on or off in Settings › Computer Use");let patch=provider_configuration::retain_legacy_environment(&current,&p["patch"])?;let v=self.store.patch_document("settings.json",&patch)?;self.revision+=1;Ok(provider_configuration::public_settings(v))}
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
                let id=required(p,"threadId")?;
                let patch=&p["patch"];
                let compact = p["compact"].as_bool()==Some(true)
                    && patch.as_object().is_some_and(|fields| fields.len()==1)
                    && patch.get("draft").is_some_and(Value::is_string);
                let v = if compact {
                    let draft = patch["draft"].as_str().expect("validated draft text");
                    self.store.patch_draft(id, draft)?;
                    json!({"id":id,"draft":draft})
                } else {
                    self.store.patch_thread(id,patch)?
                };
                // A draft-only patch must not invalidate the transcript view:
                // the desktop reloads the whole thread (and a 24k-item thread
                // stalls typing) whenever revision changes.
                if !compact {
                    self.revision+=1;
                }
                Ok(v)
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
                } else if p["snapshot"] == true {
                    crate::thread_history::fork_through_message_snapshot(&source,required(p,"itemId")?,options)?
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
            "usage.claudeLimits.refresh" => {
                crate::model_catalog::claude_limits::validate_refresh(p)?;
                self.require_provider_enabled("claude")?;
                let executable = std::env::var_os("COINCIDE_CLAUDE_EXECUTABLE")
                    .map(PathBuf::from)
                    .or_else(|| {
                        self.provider_discovery.as_ref()?["providers"].as_array()?.iter()
                            .find(|entry| entry["provider"] == "claude")?["executable"].as_str().map(PathBuf::from)
                    })
                    .map(provider_configuration::current_executable);
                let result = self.model_catalog.refresh_claude_limits(executable)?;
                self.revision += 1;
                Ok(result)
            }
            "usage.claudeLimits.status" => {
                let id = crate::model_catalog::status_id(p)?;
                if self.model_catalog.poll() { self.revision += 1; }
                self.model_catalog.claude_limits_status(id)
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
                self.require_provider_enabled(provider)?;
                let acp_configuration = if crate::acp_registry::registry_id(provider).is_some() {
                    self.provider_launch_configuration(provider)?
                } else { provider_configuration::current() };
                let _provider_configuration_scope = provider_configuration::enter(acp_configuration);
                let executable = if crate::model_catalog::supported(provider) {
                    let variable = match provider {
                        "codex" => "COINCIDE_CODEX_EXECUTABLE",
                        "claude" => "COINCIDE_CLAUDE_EXECUTABLE",
                        "opencode" | "lithos" => "COINCIDE_OPENCODE_EXECUTABLE",
                        "cursor" => "COINCIDE_CURSOR_EXECUTABLE",
                        "grok" => "COINCIDE_GROK_EXECUTABLE",
                        "antigravity" => "COINCIDE_ANTIGRAVITY_EXECUTABLE",
                        _ => "",
                    };
                    (!variable.is_empty()).then(|| std::env::var_os(variable)).flatten().map(PathBuf::from).or_else(|| {
                        self.provider_discovery.as_ref()?["providers"].as_array()?.iter()
                            .find(|entry| entry["provider"] == provider)?["executable"].as_str().map(PathBuf::from)
                    })
                } else { None };
                let executable=executable.map(provider_configuration::current_executable).or_else(||provider_configuration::current().and_then(|configuration|configuration.approved_executable()));
                ensure!(
                    !crate::model_catalog::supported(provider)
                        || executable.is_some()
                        || !self.provider_discovery_pending,
                    "Provider discovery is still in progress"
                );
                let workspace = if let Some(thread_id) = p["threadId"].as_str() {
                    let thread = self.store.thread_selection_snapshot(thread_id)?;
                    let account = p["accountId"].as_str().filter(|id| !id.is_empty()).unwrap_or("default");
                    if thread["selection"]["provider"] == provider {
                        let saved_account = thread["selection"]["accountID"].as_str().filter(|id| !id.is_empty()).unwrap_or("default");
                        ensure!(account == saved_account, "Select this account before reading its models");
                    }
                    if account != "default" {
                        ensure!(thread["selection"]["provider"] == provider
                            && thread["selection"]["accountID"] == account
                            && provider_configuration::native_account_matches(&thread["selection"]),
                            "Select this provider account in the conversation before reading its models");
                    }
                    let cwd = self.working_directory(&thread).or_else(|_| {
                        std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
                            .map(PathBuf::from).context("Working directory unavailable")
                    })?;
                    Some((thread_id.to_owned(), cwd, account.to_owned()))
                } else { None };
                let result = self.model_catalog.refresh_workspace(provider, executable, workspace)?;
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
                self.append_native_acp_capabilities(&mut result)?;
                self.apply_provider_preferences(&mut result)?;
                if let Some(id) = p.get("threadId") {
                    let id = id.as_str().context("threadId must be text")?;
                    // Ordinary capability reads need selection and queue metadata,
                    // not the transcript. Bot and named-profile checks retain the
                    // complete document for their stronger ownership validation.
                    let compact = self.store.thread_selection_snapshot(id)?;
                    let thread = if !compact["rustBotContext"].is_null()
                        || !compact["botID"].is_null()
                        || codex_profile_models_api::named_thread(&compact)
                    {
                        self.store.thread(id)?
                    } else {
                        compact
                    };
                    let is_bot = !thread["rustBotContext"].is_null() || !thread["botID"].is_null();
                    let policy_view = if is_bot { self.bot_validation_view(&thread).map(Some) } else { Ok(None) };
                    let policy_thread = policy_view.as_ref().ok().and_then(Option::as_ref).unwrap_or(&thread);
                    result["nativeAccountSelectionAllowed"]=json!(!is_bot && self.native_account_choice_available(&thread));
                    if !is_bot && codex_profile_models_api::named_thread(&thread) {
                        let mut named = self.codex_profile_model_capabilities(&thread);
                        self.apply_provider_preferences(&mut named)?;
                        return Ok(named);
                    }
                    if provider_configuration::native_account_matches(&thread["selection"]) && let Some(provider)=result["providers"].as_array_mut().and_then(|rows|rows.iter_mut().find(|provider|provider["provider"]==thread["selection"]["provider"])) {
                        provider["accountPolicy"]=json!("selected_native_account");
                        provider["selectedNativeAccountID"]=thread["selection"]["accountID"].clone();
                    }
                    let reason = if let Err(error) = self.require_provider_enabled(text(&thread["selection"], "provider").as_str()) {
                        Some(error.to_string())
                    } else if let Err(error) = &policy_view {
                        Some(error.to_string())
                    } else if self.store.is_imported(id)? {
                        Some("Fork an imported thread before changing its provider".to_owned())
                    } else if self.runs.contains_key(id) {
                        Some("Stop the current turn before changing provider".to_owned())
                    } else if self.unsaved_threads.contains_key(id) {
                        Some("Transcript persistence is recovering; retry after recovery".to_owned())
                    } else {
                        self.composer_thread_effort_proof(policy_thread).and_then(|proof| crate::composer_selection::validate_thread_with_proof(policy_thread,proof.as_ref())).err().map(|error|error.to_string())
                    };
                    if policy_view.is_ok() && !self.store.is_imported(id)?
                        && let Some(provider) = result["providers"].as_array_mut().and_then(|providers|providers.iter_mut().find(|provider|provider["provider"] == "codex")) {
                        provider["effort"] = self.composer_effort_capability(&thread["selection"]);
                        provider["speed"] = self.composer_speed_capability(&thread["selection"]);
                    }
                    // Codex keeps its own proof path above; every other provider
                    // offers what its discovered model list reported, so a
                    // provider with effort levels is never left unconnected.
                    let effort_provider = thread["selection"]["provider"].clone();
                    let workspace_scoped = effort_provider == "opencode" || effort_provider == "lithos" || effort_provider.as_str().is_some_and(|id| crate::acp_registry::registry_id(id).is_some());
                    let workspace_directory = workspace_scoped.then(|| self.working_directory(&thread).or_else(|_| {
                        std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
                            .map(PathBuf::from).context("Working directory unavailable")
                    }).ok()).flatten();
                    if effort_provider != "codex"
                        && policy_view.is_ok()
                        && !self.store.is_imported(id)?
                        && let Some((choices, reported)) = self.model_catalog.reported_efforts_for_thread(&thread["selection"],
                            workspace_scoped.then(|| thread["id"].as_str()).flatten(), workspace_directory.as_deref())
                        && let Some(provider) = result["providers"].as_array_mut().and_then(|providers| providers.iter_mut().find(|provider| provider["provider"] == effort_provider))
                    {
                        provider["effort"] = json!({"supported":true,"choices":choices,"reportedDefault":reported,
                            "effectiveDefault":null,"provenance":"provider_model_list","requiresExplicitModel":true,
                            "reason":null});
                    }
                    // A repair capability is separate from the locked/proof state.
                    // It permits only removing effort, never sending unproved work.
                    result["repairClearAvailable"] = json!(!self.admissions_frozen() && policy_view.is_ok()
                        && !self.store.is_imported(id)?
                        && !self.runs.contains_key(id) && !self.unsaved_threads.contains_key(id)
                        && crate::composer_selection::repair_clear_effort(&json!({"threadId":id,"effort":null}),policy_thread).is_ok());
                    result["repairSpeedClearAvailable"] = json!(!self.admissions_frozen() && policy_view.is_ok()
                        && !self.store.is_imported(id)?
                        && !self.runs.contains_key(id) && !self.unsaved_threads.contains_key(id)
                        && crate::composer_selection::repair_clear_speed(&json!({"threadId":id,"speed":null}),policy_thread).is_ok());
                    result["repairOptionsClearAvailable"] = json!(!self.admissions_frozen() && policy_view.is_ok()
                        && !self.store.is_imported(id)?
                        && !self.runs.contains_key(id) && !self.unsaved_threads.contains_key(id)
                        && crate::composer_selection::repair_clear_options(&json!({"threadId":id,"effort":null,"speed":null}),policy_thread).is_ok());
                    result["canReplaceUnprovedAutomaticDefault"] = json!(!self.admissions_frozen()
                        && policy_view.is_ok() && !self.store.is_imported(id)?
                        && !self.runs.contains_key(id) && !self.unsaved_threads.contains_key(id)
                        && crate::model_catalog::astra_default_needed(&thread["selection"]) && thread["selection"]["speed"].is_null()
                        && crate::composer_selection::validate_thread_base(policy_thread).is_ok()
                        && self.composer_thread_effort_proof(policy_thread).is_err());
                    result["locked"] = json!(reason.is_some());
                    result["lockReason"] = json!(reason);
                }
                Ok(result)
            }
            "agent.provider.select" => self.select_provider_from_history(p),
            "agent.provider.cancelRestore" => {
                ensure!(p.as_object().is_some_and(|fields| fields.is_empty()), "Restore cancellation takes no parameters");
                self.cancel_provider_restore();
                Ok(json!({"cancelled":true}))
            },
            "agent.select" => {
                let id = required(p, "threadId")?;
                ensure!(!self.unsaved_threads.contains_key(id),"Transcript persistence is recovering; retry after recovery");
                ensure!(!self.runs.contains_key(id), "Stop the current turn before changing provider");
                let mut v = self.store.thread(id)?;
                ensure!(!self.store.is_imported(id)?, "Fork an imported thread before changing its provider");
                self.authorize_existing_bot(&mut v)?;
                let source = v.clone();
                let mut policy_thread = self.bot_validation_view(&v)?;
                let is_bot = !v["botID"].is_null();
                if is_bot && p.get("provider").is_some() {
                    ensure!(crate::composer_selection::default_account(&p["accountId"]), "Alternate bot accounts are not yet connected");
                }
                if p.get("effort").is_some_and(Value::is_null) && p.get("speed").is_some_and(Value::is_null)
                    && let Ok(selection) = crate::composer_selection::repair_clear_options(p,&policy_thread)
                {
                    v["selection"] = selection;
                    self.save_composer_choice(&source, &mut v, p)?; self.revision += 1;
                    self.finish_staged_goal_selection(id);
                    return Ok(v);
                }
                if p.get("effort").is_some_and(Value::is_null) && !v["selection"]["effort"].is_null()
                    && let Ok(selection) = crate::composer_selection::repair_clear_effort(p,&policy_thread)
                {
                    // This exact one-field repair needs no provider/catalog IO.
                    v["selection"] = selection;
                    self.save_composer_choice(&source, &mut v, p)?; self.revision += 1;
                    self.finish_staged_goal_selection(id);
                    return Ok(v);
                }
                if p.get("speed").is_some_and(Value::is_null) && !v["selection"]["speed"].is_null()
                    && let Ok(selection) = crate::composer_selection::repair_clear_speed(p,&policy_thread)
                {
                    v["selection"] = selection;
                    self.save_composer_choice(&source, &mut v, p)?; self.revision += 1;
                    self.finish_staged_goal_selection(id);
                    return Ok(v);
                }
                let current_proof = self.composer_current_selection_proof(&policy_thread)?;
                let target_proof = self.composer_target_effort_proof(p)?;
                let selection = crate::composer_selection::select_with_proofs(p, &policy_thread,current_proof.as_ref(),target_proof.as_ref())?;
                if let Some(provider) = selection["provider"].as_str().filter(|provider| crate::acp_registry::registry_id(provider).is_some()) {
                    self.require_provider_enabled(provider)?;
                }
                if selection["provider"] == "antigravity" {
                    self.antigravity_selection(&selection)?;
                }
                if v["selection"]["provider"] != selection["provider"]
                    || v["selection"]["accountID"] != selection["accountID"] { self.park_named_departure(&v)?; }
                policy_thread["selection"] = selection.clone();
                crate::composer_selection::apply_modes_with_proof(p,&mut policy_thread,target_proof.as_ref())?;
                v["selection"] = selection;
                for field in ["accessMode", "interactionMode"] {
                    if p.get(field).is_some() { v[field] = policy_thread[field].clone(); }
                }
                self.save_composer_choice(&source, &mut v, p)?; self.revision += 1;
                self.finish_staged_goal_selection(id);
                Ok(v)
            }
            "agent.pending" => {
                let id=required(p,"threadId")?;
                ensure!(self.store.contains_thread(id)?, "Thread not found");
                Ok(json!(self.runs.get(id).map(|run|run.pending.iter().map(|(id,frame)|json!({"requestId":id,"method":frame["method"],"params":frame["params"],"provider":run.provider})).collect::<Vec<_>>()).unwrap_or_default()))
            }
            "agent.answer" => {
                let thread = required(p,"threadId")?;
                let key = required(p,"requestId")?;
                let (frame_id, answers) = {
                    let run = self.runs.get(thread).context("Thread is not running")?;
                    let frame = run.pending.get(key).context("Question is no longer pending")?;
                    ensure!(frame["method"]=="item/tool/requestUserInput", "Request is not a user question");
                    let answers = p["answers"].as_object().context("Missing answers object")?;
                    let questions = frame["params"]["questions"].as_array().context("Malformed provider questions")?;
                    for question in questions {
                        let id = question["id"].as_str().context("Question has no identifier")?;
                        let values = answers.get(id).and_then(|a|a["answers"].as_array()).context("Every question requires an answers array")?;
                        ensure!(!values.is_empty() && values.iter().all(|v|v.as_str().is_some_and(|s| !s.trim().is_empty() && s.len()<=65536)), "Provide nonempty text answers");
                    }
                    (frame["id"].clone(), json!(answers))
                };
                self.runs.get_mut(thread).unwrap().session.reply(frame_id,json!({"answers":answers.clone()}))?;
                self.runs.get_mut(thread).unwrap().pending.remove(key);
                // Swift keeps the answer on the question row so the transcript
                // says "answered" instead of dumping the original request JSON
                // or leaving a waiting question behind.
                let mut v = self.store.thread(thread)?;
                if let Some(item) = v["items"]
                    .as_array_mut()
                    .and_then(|items| items.iter_mut().rev().find(|item| {
                        item["kind"] == "question" && item["externalID"] == key
                    }))
                {
                    item["status"] = json!("completed");
                    item["answers"] = answers.clone();
                }
                self.store.save(&v)?;
                self.notification_events.cancel_request(thread,key);
                self.revision += 1;
                Ok(json!({"answered":true}))
            }
            "agent.dismissQuestion" => {
                let thread = required(p,"threadId")?;
                let item_id = Uuid::parse_str(required(p,"itemId")?).context("Invalid question ID")?;
                let mut document = self.store.thread(thread)?;
                let items = document["items"].as_array_mut().context("Missing transcript")?;
                let item = items.iter_mut().find(|item| {
                    item["kind"] == "question" && item["id"].as_str()
                        .and_then(|id| Uuid::parse_str(id).ok()) == Some(item_id)
                }).context("Question no longer exists")?;
                ensure!(!matches!(item["status"].as_str(), Some("completed" | "declined")), "Question is no longer pending");
                let key = required(item,"externalID")?.to_owned();
                let (frame_id, reply) = {
                    let run = self.runs.get(thread).context("Thread is not running")?;
                    let frame = run.pending.get(&key).context("Question is no longer pending")?;
                    ensure!(frame["method"] == "item/tool/requestUserInput", "Request is not a user question");
                    (frame["id"].clone(), question_dismissal(&run.provider)?)
                };
                self.runs.get_mut(thread).unwrap().session.reply(frame_id,reply)?;
                self.runs.get_mut(thread).unwrap().pending.remove(&key);
                item["status"] = json!("declined");
                item["completedAt"] = json!(swift_timestamp());
                self.store.save(&document)?;
                self.notification_events.cancel_request(thread,&key);
                self.revision += 1;
                Ok(json!({"dismissed":true}))
            }
            "agent.queue.add" | "agent.queue.list" | "agent.queue.remove" | "agent.queue.pause" | "agent.queue.resume" => self.queue_command(method, p),
            "agent.steer" | "agent.steer.result" => self.steer_command(method,p),
            "composer.context.edit" => self.edit_composer_context(p),
            "composer.context.attachTerminalSelection" => self.attach_terminal_selection(p),
            "composer.commands" => self.reported_composer_commands(p),
            "agent.send" => self.send_turn(p,SendOrigin::Ordinary),
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
                // Only Claude Code reads a note with its answer (what to do
                // instead of a denied call); never drop one silently elsewhere.
                let mut answer = json!({"decision":decision});
                let answer_text = p.get("text").and_then(Value::as_str).map(str::to_owned);
                if let Some(note) = p.get("text").filter(|note| !note.is_null()) {
                    let note = note.as_str().context("Reply text must be a string")?;
                    ensure!(note.len() <= 65536, "Reply text must fit within 64 KiB");
                    ensure!(
                        running.provider == "claude" || note.trim().is_empty(),
                        "This agent does not take a reply with its approvals"
                    );
                    if !note.trim().is_empty() {
                        answer["text"] = json!(note);
                    }
                }
                running.session.reply(frame["id"].clone(), answer)?;
                running.pending.remove(key);
                self.notification_events.cancel_request(required(p,"threadId")?,key);
                // Swift resolves the transcript card, so it stops saying
                // "waiting" once the answer is in.
                let thread = required(p, "threadId")?;
                let mut v = self.store.thread(thread)?;
                if let Some(item) = v["items"]
                    .as_array_mut()
                    .and_then(|items| items.iter_mut().rev().find(|item| {
                        item["kind"] == "approval" && item["externalID"] == key
                    }))
                {
                    item["status"] = json!(if decision == "accept" { "completed" } else { "declined" });
                    item["approval"] = json!({
                        "resolution": match decision {
                            "accept" => "Approved",
                            "decline" => "Declined",
                            _ => "Cancelled",
                        },
                        "responseText": answer_text,
                    });
                }
                self.store.save(&v)?;
                self.revision += 1;
                Ok(json!({"answered":true}))
            }
            _ => bail!("Unsupported method: {method}"),
        }
    }
    /// JSON sends always select Ordinary. Only the owning queue/scheduler
    /// control paths can supply the other closed send origins.
    fn send_turn(&mut self, p: &Value, origin: SendOrigin) -> Result<Value> {
        self.send_turn_if_unchanged(p, &origin, None, false)
    }
    /// The desktop may wait for the engine on a worker after Send is clicked.
    /// Recheck the captured execution context before admitting that one send.
    pub fn send_captured_native_turn(&mut self, captured: &Value, prompt: &str) -> Result<Value> {
        self.require_admissions()?;
        let id = required(captured, "id")?;
        let current = self.store.thread(id)?;
        for key in [
            "selection",
            "accessMode",
            "interactionMode",
            "projectID",
            "projectPath",
            "worktreePath",
            "botID",
            "rustBotContext",
            "rustDraftImages",
            "draftContext",
        ] {
            ensure!(
                current[key] == captured[key],
                "Conversation context changed; message retained"
            );
        }
        self.send_turn(&json!({"threadId":id,"text":prompt}), SendOrigin::Ordinary)
    }
    /// Remote owns its own submitted text. Validate its captured execution
    /// context under the engine lock without consuming the desktop composer.
    pub(crate) fn send_remote_text(&mut self, expected: &Value, prompt: &str) -> Result<Value> {
        self.send_remote_submission(expected, prompt, Vec::new())
    }
    pub(crate) fn send_remote_submission(
        &mut self,
        expected: &Value,
        prompt: &str,
        images: Vec<crate::attachments::StoredImage>,
    ) -> Result<Value> {
        let id = required(expected, "id")?;
        let current = self.store.thread(id)?;
        for key in [
            "selection",
            "projectID",
            "projectPath",
            "worktreePath",
            "botID",
            "rustBotContext",
            "accessMode",
            "interactionMode",
        ] {
            ensure!(
                current[key] == expected[key],
                "Conversation context changed; send again after refreshing"
            );
        }
        self.send_turn(
            &json!({"threadId":id,"text":prompt}),
            SendOrigin::Remote(images),
        )
    }
    fn send_turn_if_unchanged(
        &mut self,
        p: &Value,
        origin: &SendOrigin,
        expected_scope: Option<&Value>,
        force_fresh: bool,
    ) -> Result<Value> {
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
        if origin.consumes_composer() {
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
        let native_configuration = self.provider_launch_configuration_for_thread(&v)?;
        if let Some(configuration) = &native_configuration {
            configuration.validate_launch()?;
        }
        let _provider_configuration_scope = provider_configuration::enter(native_configuration);
        self.require_provider_enabled(text(&v["selection"], "provider").as_str())?;
        if let SendOrigin::Queued(claim) = origin {
            ensure!(
                expected_scope.is_none() && (!force_fresh || claim.permits_fresh_replacement()),
                "Queued dispatch cannot borrow replacement authority"
            );
            claim.validate(self.thread_bulk_owner, &id, prompt, &v)?;
        }
        let mut original = if let SendOrigin::Queued(_) = origin {
            Some(v.clone())
        } else if let Some(expected) = expected_scope {
            ensure!(
                crate::composer_follow_up::scope(&v) == crate::composer_follow_up::scope(expected),
                "Composer changed before replacement admission; draft retained"
            );
            Some(v.clone())
        } else {
            None
        };
        // Check any captured or queued scope before refreshing a bot context.
        // The authorization transaction changes only the local context; use
        // its resulting snapshot for the subsequent compare-and-save.
        let bot_context_changed = if !v["botID"].is_null() {
            // OpenCode handles slash commands through a separate endpoint
            // which does not carry the inline bot context. Leave an edit
            // pending until its next ordinary prompt can actually deliver it.
            let changed = if matches!(
                v["selection"]["provider"].as_str(),
                Some("opencode" | "lithos")
            ) && prompt.trim_start().starts_with('/')
            {
                self.authorize_existing_bot(&mut v)?;
                false
            } else {
                self.refresh_bot_instructions(&mut v)?
            };
            if original.is_some() {
                original = Some(v.clone());
            }
            changed
        } else {
            false
        };
        ensure!(
            p.get("context").is_none() && p.get("draftContext").is_none(),
            "Attach references through composer.context.edit before sending"
        );
        // Remote, scheduled and queued turns never consume the unrelated composer.
        let context = match origin {
            SendOrigin::Queued(claim) => claim.context().clone(),
            SendOrigin::Remote(_) | SendOrigin::Scheduled | SendOrigin::GoalResume(_) => {
                Value::Null
            }
            SendOrigin::Ordinary => v["draftContext"].clone(),
        };
        crate::composer_context::validate(&context)?;
        let mut runtime_prompt = crate::composer_context::prompt(prompt, &context)?;
        // Per-thread capabilities valid only for this running app; never saved
        // as user text (Swift ThreadRunner.ephemeralRuntimeContexts).
        if let Some(capability) = Uuid::parse_str(&id)
            .ok()
            .and_then(|thread| self.computer_use_runtime_context(thread))
        {
            runtime_prompt.push_str("\n\n");
            runtime_prompt.push_str(&capability);
        }
        let codex_profile = self.codex_login_context(&v)?;
        if let Some(configuration) = provider_configuration::current() {
            configuration.validate_named_profile(
                codex_profile.is_some() || v["selection"]["provider"] == "antigravity",
            )?;
        }
        ensure!(
            codex_profile.is_none() || !origin.scheduled(),
            "Named Codex profiles are not connected to scheduled dispatch"
        );
        let bot_policy_view = self.bot_validation_view(&v)?;
        let validation_thread = if codex_profile.is_some() {
            crate::codex_login_profiles::validation_view(&v)
        } else {
            bot_policy_view
        };
        // Named models require their own account/cwd-bound job. Never consult
        // the default-account effort catalog through the validation alias.
        let named_model_proof = if let Some(profile) = &codex_profile {
            let binding = crate::model_catalog::NamedBinding::capture(
                profile.clone(),
                &id,
                &self.working_directory(&v)?,
            )?;
            self.model_catalog.named_model_proof(&v, &binding, None)?
        } else {
            None
        };
        let effort_proof = if codex_profile.is_some() {
            None
        } else {
            self.composer_thread_effort_proof(&validation_thread)?
        };
        let named_policy = if codex_profile.is_some() {
            let policy = crate::composer_policy::Policy::parse_named(
                &v,
                crate::composer_policy::Origin::Ordinary,
                named_model_proof.as_ref(),
            )?;
            policy.preflight()?;
            Some(policy)
        } else {
            crate::composer_selection::validate_thread_with_proof(
                &validation_thread,
                effort_proof.as_ref(),
            )?;
            None
        };
        let draft_images: Vec<crate::attachments::StoredImage> =
            if let SendOrigin::Queued(claim) = origin {
                claim.images().to_vec()
            } else if let SendOrigin::Remote(images) = origin {
                images.clone()
            } else if !origin.consumes_composer() || v["rustDraftImages"].is_null() {
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
        let mode_policy = if v["selection"]["provider"] == "codex" {
            Some(if let Some(policy) = named_policy {
                policy
            } else {
                crate::composer_policy::Policy::parse_with_effort_proof(
                    &validation_thread,
                    crate::composer_policy::Origin::Ordinary,
                    effort_proof.as_ref(),
                )?
            })
        } else {
            None
        };
        let provider = text(&v["selection"], "provider");
        if provider == "lithos" {
            let model = v["selection"]["modelID"].as_str().unwrap_or("");
            ensure!(
                crate::model_catalog::lithos_model_id(model),
                "Choose a Lithos model before sending"
            );
            ensure!(
                !model.starts_with("coincide-lithos/")
                    || !crate::composer_selection::default_account(&v["selection"]["accountID"]),
                "Add and select a Lithos API key account before using a hosted model"
            );
        }
        let mut adapter = Provider::from_name(&provider)?;
        if let Provider::RegisteredAcp { arguments, .. } = &mut adapter {
            *arguments = provider_configuration::current_acp_arguments(&provider)?;
        }
        ensure!(
            provider == "antigravity"
                || codex_profile.is_some()
                || crate::composer_selection::default_account(&v["selection"]["accountID"])
                || provider_configuration::native_account_matches(&v["selection"])
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
        let saved_session = agent::provider_session(&v, &provider);
        let available_session = self
            .unrevoked_provider_session(&v, &provider)?
            .filter(|session| {
                self.native_configuration_session_allowed(&provider, &id, session)
                    .unwrap_or(false)
            })
            .filter(|_| {
                crate::acp_registry::registry_id(&provider).is_none()
                    || v["rustAcpResumable"][&provider] != false
            });
        // Native Interrupt and changed configuration each deny old continuation;
        // public JSON cannot select this branch or create native authority.
        let allowed_session = if force_fresh { None } else { available_session };
        if let Some(profile) = codex_profile.as_ref()
            && saved_session.is_some()
            && allowed_session.is_none()
        {
            // Preserve independent parked accounts while revoking this context.
            self.named_resume
                .invalidate_account(&id, profile.account(), &self.store)?;
        }
        // Session JSON cannot authorize named resume. The private registry
        // and authenticated restart journal require a saved owned worker join.
        let named_resume = if let Some(profile) = &codex_profile {
            Some(
                self.named_resume.prepare_admitted(
                    &v,
                    profile.clone(),
                    &cwd,
                    mode_policy
                        .as_ref()
                        .context("Missing named policy")?
                        .clone(),
                    self.model_catalog
                        .named_resume_admission(
                            &v,
                            &crate::model_catalog::NamedBinding::capture(
                                profile.clone(),
                                &id,
                                &cwd,
                            )?,
                        )
                        .ok(),
                )?,
            )
        } else {
            None
        };
        let session = if let Some(authority) = &named_resume {
            authority.session().map(str::to_owned)
        } else {
            allowed_session
        };
        if let SendOrigin::Queued(claim) = origin
            && let Some(expected) = claim.question_session()
        {
            ensure!(
                session.as_deref() == Some(expected),
                "The question's original Codex session is unavailable; the answer was retained"
            );
        }
        // Codex slash controls are client commands, not chat text. Only the
        // exact, attachment-free user command has authority to compact the
        // existing provider session; quoted history is never interpreted.
        let native_compact = matches!(provider.as_str(), "codex" | "opencode" | "lithos")
            && agent::codex_compact_command(prompt)
            && draft_images.is_empty()
            && !crate::composer_context::has_context(&context);
        ensure!(
            !native_compact || session.is_some(),
            "Start a provider conversation before compacting its context"
        );
        let restore_paused_goal = if let SendOrigin::GoalResume(expected) = origin {
            ensure!(
                agent::codex_goals::queued_resume_objective(&v, session.as_deref(), true).as_ref()
                    == Some(expected),
                "Paused goal belongs to another conversation or account"
            );
            Some(expected.clone())
        } else {
            None
        };
        let codex_goal = (provider == "codex"
            && !origin.scheduled()
            && restore_paused_goal.is_none()
            && draft_images.is_empty()
            && !crate::composer_context::has_context(&context)
            && bot_instructions.is_none())
        .then(|| agent::codex_goals::parse(prompt))
        .flatten();
        if let Some(agent::codex_goals::Command::Set(objective)) = &codex_goal {
            // The first turn carries any cross-provider history and the
            // thread's runtime capabilities. Goal state itself receives
            // the exact objective through its native control request.
            ensure!(
                runtime_prompt.starts_with(prompt),
                "Goal context changed before sending"
            );
            runtime_prompt.replace_range(..prompt.len(), objective);
        }
        let opencode_command = (matches!(provider.as_str(), "opencode" | "lithos")
            && prompt.trim_start().starts_with('/')
            && draft_images.is_empty()
            && !crate::composer_context::has_context(&context))
        .then(|| prompt.to_owned());
        let seen = if let Some(authority) = &named_resume {
            authority.seen()
        } else if session.is_some() {
            agent::provider_seen_count(&v, &provider)
        } else {
            0
        };
        let inline_bot_context = if !matches!(provider.as_str(), "codex" | "claude")
            && (session.is_none() || seen == 0 || bot_context_changed)
        {
            bot_instructions
                .as_deref()
                .map(crate::bot_runtime::inline_instructions)
        } else {
            None
        };
        let (outgoing, handoff_images) = if restore_paused_goal.is_some()
            || codex_goal
                .as_ref()
                .is_some_and(|command| !matches!(command, agent::codex_goals::Command::Set(_)))
        {
            (String::new(), Vec::new())
        } else {
            handoff_prompt::build(
                v["items"].as_array().map(Vec::as_slice).unwrap_or(&[]),
                seen,
                &runtime_prompt,
                &draft_images,
                inline_bot_context.as_deref(),
            )?
        };
        let images = handoff_images
            .iter()
            .map(|image| image.prepare_in(&data))
            .collect::<Result<Vec<_>>>()?;
        agent::validate_images(&adapter, &images)?;
        let model = crate::composer_selection::launch_model(&v["selection"])?;
        // OpenCode selects a model's reasoning variant in its model reference;
        // other providers carry effort on their own wire fields.
        let variant = (matches!(provider.as_str(), "opencode" | "lithos"))
            .then(|| v["selection"]["effort"].as_str().map(str::to_owned))
            .flatten();
        let full_access = v["accessMode"] == "fullAccess";
        let executable_variable = match provider.as_str() {
            "claude" => "COINCIDE_CLAUDE_EXECUTABLE",
            "codex" => "COINCIDE_CODEX_EXECUTABLE",
            "grok" => "COINCIDE_GROK_EXECUTABLE",
            "opencode" | "lithos" => "COINCIDE_OPENCODE_EXECUTABLE",
            "cursor" => "COINCIDE_CURSOR_EXECUTABLE",
            "antigravity" => "COINCIDE_ANTIGRAVITY_EXECUTABLE",
            _ if crate::acp_registry::registry_id(&provider).is_some() => "",
            _ => bail!("Provider executable is not configured"),
        };
        let executable = antigravity_executable
            .or_else(|| {
                (!executable_variable.is_empty())
                    .then(|| std::env::var_os(executable_variable))
                    .flatten()
                    .map(PathBuf::from)
            })
            .unwrap_or_else(|| {
                if provider == "lithos" {
                    "opencode".into()
                } else if provider == "cursor" {
                    "cursor-agent".into()
                } else {
                    provider.clone().into()
                }
            });
        // Use exactly the executable whose catalog authorized effort, not a
        // later PATH lookup or another configured provider/account.
        let executable = provider_configuration::current_executable(executable);
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
        let named_launch = if let Some(profile) = codex_profile {
            Some(agent::NamedProfileLaunch {
                profile,
                model: named_model_proof,
                resume: named_resume.context("Missing captured named-session authority")?,
            })
        } else {
            None
        };
        let goal_queue_waiting = provider == "codex"
            && (self.goal_selection_waiting.contains(&id)
                || (self.enabled_queues.contains(&id)
                    && crate::message_queue::read(&v).is_ok_and(|messages| {
                        messages
                            .iter()
                            .any(|message| message.state == crate::message_queue::State::Pending)
                    })));
        let resume_queued_goal = agent::codex_goals::queued_resume_objective(
            &v,
            session.as_deref(),
            matches!(origin, SendOrigin::Queued(_)),
        );
        if restore_paused_goal.is_none() {
            append(&mut v, "user", prompt, None);
            if let SendOrigin::Queued(claim) = origin {
                let item = v["items"].as_array_mut().unwrap().last_mut().unwrap();
                item["rustQueueMessageID"] = json!(claim.id());
                item["rustAwaitingQueueDelivery"] = json!(true);
            }
            if crate::composer_context::has_context(&context) {
                v["items"].as_array_mut().unwrap().last_mut().unwrap()["context"] = context;
            }
            if !draft_images.is_empty() {
                v["items"].as_array_mut().unwrap().last_mut().unwrap()["rustImages"] =
                    serde_json::to_value(&draft_images)?;
            }
            if origin.consumes_composer() {
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
        }
        self.store.save_starting_turn(&v, original.as_ref())?;
        // The durable claim and this exact runtime owner are both selected
        // before Session starts its worker. No post-launch claim lookup exists.
        let queue_claim = match origin {
            SendOrigin::Queued(claim) => Some(claim.id().to_owned()),
            _ => None,
        };
        let user_item_id = v["items"]
            .as_array()
            .and_then(|items| items.last())
            .map(|item| text(item, "id"))
            .unwrap_or_default();
        let checkpoint = if restore_paused_goal.is_some() {
            None
        } else {
            self.prepare_turn_checkpoint(&id, &user_item_id, &cwd)
        };
        let turn_opener = (restore_paused_goal.is_none() && !user_item_id.is_empty())
            .then(|| user_item_id.clone());
        self.insert_running_for_turn(
            id,
            Running {
                configuration: provider_configuration::current(),
                resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
                usage_context: Some(agent::usage_capture::TurnContext::new(&v)),
                session: Session::start_with_mode_policy_and_profile(
                    adapter,
                    Launch {
                        executable,
                        cwd,
                        session,
                        prompt: outgoing,
                        model,
                        variant,
                        full_access,
                    },
                    images,
                    if matches!(provider.as_str(), "codex" | "claude") {
                        bot_instructions
                    } else {
                        None
                    },
                    mode_policy,
                    agent::LaunchOptions {
                        named: named_launch,
                        prelude: checkpoint,
                        compact: native_compact,
                        opencode_command,
                        codex_goal,
                        goal_queue_waiting,
                        resume_queued_goal,
                        restore_paused_goal,
                    },
                ),
                provider,
                transcript_start: v["items"].as_array().map_or(0, Vec::len),
                pending: HashMap::new(),
                schedule_claim: None,
                queue_claim,
                cancelled: false,
                events: VecDeque::new(),
                persistence_error: None,
            },
            turn_opener,
        );
        self.revision += 1;
        Ok(json!({"accepted":true}))
    }
    #[cfg(test)]
    fn insert_running(&mut self, id: String, run: Running) {
        self.insert_running_for_turn(id, run, None);
    }
    fn insert_running_for_turn(&mut self, id: String, run: Running, opener: Option<String>) {
        self.answered_runs.remove(&id);
        self.composer_commands.begin_run(&id);
        self.provider_workers
            .push((Some(id.clone()), run.session.worker_completion()));
        self.run_clocks.insert(
            id.clone(),
            RunClock {
                started_at: swift_timestamp(),
                started_monotonic: Instant::now(),
                run_id: Uuid::new_v4(),
                opener,
                connected: false,
                work: crate::active_work::Work::default(),
            },
        );
        self.runs.insert(id, run);
    }
    /// Current provider turns, independent of whether a desktop window exists.
    pub fn running_thread_count(&self) -> usize {
        self.runs.len()
    }
    /// Whether this exact conversation currently owns a provider turn.
    pub fn is_thread_running(&self, thread_id: &str) -> bool {
        self.runs.contains_key(thread_id)
    }
    pub fn is_thread_stopping(&self, thread_id: &str) -> bool {
        self.runs.get(thread_id).is_some_and(|run| run.cancelled)
    }
    pub fn current_run_id(&self, thread_id: &str) -> Option<Uuid> {
        self.run_clocks.get(thread_id).map(|clock| clock.run_id)
    }
    fn active_work_status(&self) -> HashMap<&str, crate::active_work::Summary> {
        self.runs
            .keys()
            .filter_map(|id| {
                let summary = self.run_clocks.get(id)?.work.summary();
                (summary.total() > 0).then_some((id.as_str(), summary))
            })
            .collect()
    }
    /// Each running thread's start (Swift reference seconds) and whether it is
    /// still connecting: its provider has sent nothing since the run began.
    fn run_clocks_status(&self) -> Value {
        Value::Object(
            self.runs
                .keys()
                .filter_map(|id| {
                    let clock = self.run_clocks.get(id)?;
                    Some((
                        id.clone(),
                        json!({"startedAt":clock.started_at,"runId":clock.run_id.to_string(),"connecting":!clock.connected}),
                    ))
                })
                .collect(),
        )
    }
    pub(crate) fn remote_running_provider(&self, id: &str) -> Option<&str> {
        self.runs.get(id).map(|run| run.provider.as_str())
    }
    /// A Remote settle/archive cannot hide a run or an uncommitted follow-up.
    pub(crate) fn remote_thread_idle(&self, id: &str) -> bool {
        !self.runs.contains_key(id)
            && !self.unsaved_threads.contains_key(id)
            && !self.native_follow_up.pending_thread(id)
    }

    /// Whether Remote can use its text-steering route for this exact run.
    /// The run's provider and configuration remain authoritative.
    pub(crate) fn remote_can_steer(&self, id: &str, thread: &Value) -> bool {
        let Some(run) = self.runs.get(id) else {
            return false;
        };
        if run.cancelled
            || run.persistence_error.is_some()
            || self.unsaved_threads.contains_key(id)
            || thread["isArchived"] == true
            || self.store.is_imported(id).unwrap_or(true)
            || self.require_provider_enabled(&run.provider).is_err()
            || thread["selection"]["provider"] != run.provider
            || thread["interactionMode"]
                .as_str()
                .is_some_and(|mode| mode != "build")
            || !run
                .usage_context
                .as_ref()
                .is_some_and(|context| context.matches(thread))
        {
            return false;
        }
        match run.provider.as_str() {
            "codex" => run.session.can_steer(),
            "opencode" | "lithos" => true,
            // Claude has a native composer follow-up, but Remote's current
            // text-steering route cannot submit it yet.
            _ => false,
        }
    }
    /// Nonblocking observer for trusted native owners. Background observers join
    /// provider threads; completed observations fold into sticky counters here.
    pub fn provider_workers_status(&mut self) -> ProviderWorkersStatus {
        let totals = &mut self.provider_worker_outcomes;
        let failed = &mut self.failed_thread_workers;
        self.provider_workers.retain(|(thread, worker)| {
            let counter = match worker.status() {
                agent::WorkerThreadStatus::Running => return true,
                agent::WorkerThreadStatus::Returned => &mut totals.returned,
                agent::WorkerThreadStatus::Panicked => {
                    if let Some(thread) = thread {
                        failed.insert(thread.clone());
                    }
                    &mut totals.panicked
                }
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
                    .filter(|(_, worker)| {
                        worker.status() == agent::WorkerThreadStatus::Unclassified
                    })
                    .count() as u64,
            ..*totals
        }
    }
    pub(super) fn require_conversation_workers_idle(&mut self, ids: &[String]) -> Result<()> {
        self.provider_workers_status();
        let affected = |owner: &str| ids.iter().any(|id| id.eq_ignore_ascii_case(owner));
        if self
            .failed_thread_workers
            .iter()
            .any(|owner| affected(owner))
        {
            return Err(ConversationCleanup::Failed.into());
        }
        if self.runs.keys().any(|owner| affected(owner)) {
            return Err(ConversationCleanup::Running.into());
        }
        if self
            .provider_workers
            .iter()
            .any(|(owner, _)| owner.as_ref().is_some_and(|owner| affected(owner)))
        {
            return Err(ConversationCleanup::Waiting.into());
        }
        Ok(())
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
        self.catalog_shutdown_requested = true;
        self.poll_model_catalog_shutdown_request();
        Ok(())
    }
    fn poll_model_catalog_shutdown_request(&mut self) {
        if self.catalog_shutdown_requested
            && self.runs.is_empty()
            && self.provider_workers_status().running == 0
        {
            // First admit exact joined-worker saved completions, then revoke
            // catalog authority. An unfinished/panicked turn cannot mint here.
            self.named_resume.poll();
            self.model_catalog.request_shutdown();
        }
    }
    /// Catalog thread ownership only, not whole-app quiescence or child cleanup.
    pub fn model_catalog_shutdown_status(
        &mut self,
    ) -> Result<crate::model_catalog::ShutdownStatus> {
        ensure!(
            self.admissions_frozen(),
            "Catalog shutdown status requires frozen admissions"
        );
        self.poll_model_catalog_shutdown_request();
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
        if method == "agent.queue.list" {
            let mut result = self.native_queue_read(id)?;
            if let Some(object) = result.as_object_mut() {
                object.remove("rawQueue");
            }
            return Ok(result);
        }
        let mut thread = self.store.thread(id)?;
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
                self.sync_goal_queue_waiting(id);
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
                if messages[index].state == State::Dispatching {
                    // Removing a row cannot recall a prompt already handed to
                    // a provider. Hide it while retaining its owned claim so
                    // later acknowledgement and recovery remain exactly once.
                    let owned = self.runs.get(id).and_then(|run| run.queue_claim.as_deref())
                        == Some(message_id);
                    if !owned {
                        // No current worker can acknowledge this old claim.
                        // It stays non-replayable, but must not keep the queue
                        // and provider switch blocked after the user dismisses it.
                        thread["rustMessageQueue"][index]["state"] = json!("interrupted");
                    }
                    thread["rustMessageQueue"][index]["dismissed"] = json!(true);
                } else {
                    if matches!(messages[index].state, State::Pending | State::Failed)
                        && messages[index].codex_question_session.is_some()
                    {
                        crate::async_questions::restore_removed_reply(&mut thread, message_id);
                    }
                    messages.remove(index);
                    queue::write(&mut thread, &messages)?;
                }
                self.store.save(&thread)?;
            }
            _ => bail!("Unsupported queue command"),
        }
        self.revision += 1;
        self.sync_goal_queue_waiting(id);
        if matches!(method, "agent.queue.pause" | "agent.queue.remove")
            && let Err(error) = self.resume_paused_goal_if_ready(id)
        {
            self.schedule_error = Some(format!(
                "The queue changed, but the paused goal could not resume: {error}"
            ));
        }
        let mut result = queue::native_snapshot(&thread, self.enabled_queues.contains(id))?;
        if let Some(object) = result.as_object_mut() {
            object.remove("rawQueue");
        }
        Ok(result)
    }
    fn sync_goal_queue_waiting(&self, id: &str) {
        if let Some(run) = self.runs.get(id).filter(|run| run.provider == "codex") {
            let waiting = self.goal_selection_waiting.contains(id)
                || (self.enabled_queues.contains(id)
                    && self
                        .store
                        .thread(id)
                        .and_then(|thread| crate::message_queue::read(&thread))
                        .map(|messages| {
                            messages.iter().any(|message| {
                                message.state == crate::message_queue::State::Pending
                            })
                        })
                        .unwrap_or(true));
            run.session.set_goal_queue_waiting(waiting);
        }
    }
    /// A native selection editor may stage a change while a turn is running.
    /// A continuing goal yields at the boundary so that choice can take effect.
    pub fn defer_goal_for_staged_selection(
        &mut self,
        expected: &Value,
        staged: bool,
    ) -> Result<()> {
        self.require_admissions()?;
        let id = required(expected, "id")?;
        ensure!(
            self.active_thread.as_deref() == Some(id),
            "Selection belongs to another conversation"
        );
        let current = self.store.thread(id)?;
        ensure!(
            current["selection"] == expected["selection"],
            "Selection changed while staging"
        );
        if self.runs.get(id).is_some_and(|run| run.provider == "codex") {
            if staged {
                self.goal_selection_waiting.insert(id.into());
            } else {
                self.goal_selection_waiting.remove(id);
            }
            self.sync_goal_queue_waiting(id);
        }
        Ok(())
    }
    fn finish_staged_goal_selection(&mut self, id: &str) {
        self.goal_selection_waiting.remove(id);
        self.sync_goal_queue_waiting(id);
        if let Err(error) = self.resume_paused_goal_if_ready(id) {
            self.schedule_error = Some(format!(
                "Selection saved, but the paused goal could not resume: {error}"
            ));
        }
    }
    fn resume_paused_goal_if_ready(&mut self, id: &str) -> Result<()> {
        if self.runs.contains_key(id)
            || self.unsaved_threads.contains_key(id)
            || self.goal_selection_waiting.contains(id)
            || self.admissions_frozen()
        {
            return Ok(());
        }
        let thread = self.store.thread(id)?;
        if !thread["rustCodexGoalAutoResume"].is_object() {
            return Ok(());
        }
        let messages = crate::message_queue::read(&thread)?;
        if messages
            .iter()
            .any(|message| message.state == crate::message_queue::State::Dispatching)
            || (self.enabled_queues.contains(id)
                && messages
                    .iter()
                    .any(|message| message.state == crate::message_queue::State::Pending))
        {
            return Ok(());
        }
        let session = agent::provider_session(&thread, "codex");
        if let Some(objective) =
            agent::codex_goals::queued_resume_objective(&thread, session.as_deref(), true)
        {
            self.send_turn(
                &json!({"threadId":id,"text":"/goal resume"}),
                SendOrigin::GoalResume(objective),
            )?;
        }
        Ok(())
    }
    fn launch_next_queue_turn(&mut self, id: &str) -> Result<bool> {
        let Some(claim) = self.claim_next_queue_turn(id)? else {
            return Ok(false);
        };
        let prompt = claim.text().to_owned();
        let origin = SendOrigin::Queued(Box::new(claim));
        match self.send_turn_if_unchanged(
            &json!({"threadId":id,"text":prompt}),
            &origin,
            None,
            false,
        ) {
            Ok(_) => Ok(true),
            Err(error) => {
                if let SendOrigin::Queued(claim) = &origin {
                    self.fail_queue_claim(claim, &error.to_string())?;
                }
                Err(error)
            }
        }
    }

    fn poll_message_queues(&mut self) {
        if self.admissions_frozen() {
            return;
        }
        self.queue_catalog_poll_after
            .retain(|id, _| self.enabled_queues.contains(id));
        let ids: Vec<_> = self.enabled_queues.iter().cloned().collect();
        for id in ids {
            if self.runs.contains_key(&id)
                || self.unsaved_threads.contains_key(&id)
                || self.goal_selection_waiting.contains(&id)
                || self.native_follow_up.pending_thread(&id)
            {
                continue;
            }
            if self
                .queue_catalog_poll_after
                .get(&id)
                .is_some_and(|until| Instant::now() < *until)
            {
                continue;
            }
            if let Ok(thread) = self.store.thread(&id) {
                if self.named_resume.waiting_for_join(&thread) {
                    continue;
                }
                if self.queue_waits_for_codex_catalog(&thread) {
                    // Do not repeatedly decode a long transcript while the
                    // asynchronous model-list worker is running.
                    self.queue_catalog_poll_after
                        .insert(id.clone(), Instant::now() + Duration::from_secs(1));
                    continue;
                }
            }
            self.queue_catalog_poll_after.remove(&id);
            let launched = self.launch_next_queue_turn(&id);
            if !matches!(launched, Ok(true)) {
                self.enabled_queues.remove(&id);
                self.revision += 1;
                // The queued text remains persisted even when preflight fails.
                if let Err(error) = launched
                    && let Ok(mut thread) = self.store.thread(&id)
                {
                    let source = thread.clone();
                    thread["rustQueueError"] = json!(error.to_string());
                    let _ = self.store.save_native_follow_up_turn(&source, &thread);
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
            self.send_turn(
                &json!({"threadId":thread,"text":claim.prompt}),
                SendOrigin::Scheduled,
            )?;
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
            self.browser_results
                .entry(reply.id.clone())
                .or_insert(reply);
            self.revision += 1;
        }
    }
    fn working_directory(&self, v: &Value) -> Result<PathBuf> {
        if let Some(path) = v["worktreePath"].as_str() {
            return Ok(PathBuf::from(path));
        }
        if let Some(path) = self.store.projects()?.as_array().and_then(|projects| {
            projects
                .iter()
                .find(|p| p["id"] == v["projectID"])
                .and_then(|p| p["path"].as_str())
                .map(PathBuf::from)
        }) {
            return Ok(path);
        }
        if !v["botID"].is_null()
            && let Some(path) = v["rustBotContext"]["cwd"].as_str()
        {
            return Ok(PathBuf::from(path));
        }
        if let Some(bot) = v["botID"].as_str().filter(|id| !id.is_empty())
            && let Some(path) = self.store.bot_working_directory(bot)?
        {
            return Ok(path);
        }
        anyhow::bail!("Choose a project working directory first")
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
                self.provider_discovery_pending = false;
                self.revision += 1;
                continue;
            }
            if id == "acp-registry-local" {
                if let Ok(agents) = serde_json::from_value::<Vec<crate::acp_registry::Agent>>(
                    result["agents"].take(),
                ) {
                    for local in agents {
                        if let Some(previous) =
                            self.acp_registry.iter_mut().find(|a| a.id == local.id)
                        {
                            // Re-scan installed paths without replacing newer registry metadata.
                            previous.executable = local.executable;
                        } else {
                            self.acp_registry.push(local);
                        }
                    }
                    self.revision += 1;
                }
                continue;
            }
            if id == "acp-registry" {
                self.acp_registry_pending = false;
                let error = result["error"].as_str().map(str::to_owned);
                if let Some(rows) = result.get_mut("agents")
                    && let Ok(agents) = serde_json::from_value(rows.take())
                    && (error.is_none() || self.acp_registry.is_empty())
                {
                    self.acp_registry = agents;
                }
                self.acp_registry_error = error;
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
        self.poll_provider_restore();
        self.poll_codex_profile_login();
        self.poll_steering();
        self.provider_workers_status();
        self.named_resume.poll();
        self.poll_model_catalog_shutdown_request();
        self.computer_use_expire();
        let limits_executable = self.codex_limits_executable();
        let named_limits = self.current_profile_limits_binding();
        let limits_changed = self.model_catalog.limits_context(limits_executable)
            | self.model_catalog.named_limits_context(named_limits);
        let catalog_changed = self.model_catalog.poll();
        if catalog_changed {
            self.save_model_catalog();
        }
        if catalog_changed | limits_changed {
            self.revision += 1;
        }
        self.poll_workspace_completions();
        self.poll_git_actions();
        self.poll_turn_checkpoints();
        self.background_workers.poll();
        // Reclaim abandoned operations while allowing callers time to collect a result.
        let timeouts = &self.browser_timeouts;
        self.browser_pending.retain(|id, (_, started)| {
            started.elapsed()
                < Duration::from_secs(300) + timeouts.get(id).copied().unwrap_or_default()
        });
        self.browser_timeouts
            .retain(|id, _| self.browser_pending.contains_key(id));
        self.browser_requests
            .retain(|r| self.browser_pending.contains_key(&r.id));
        self.browser_results
            .retain(|id, _| self.browser_pending.contains_key(id));
        for (_, terminal) in self.terminals.values_mut() {
            if terminal.poll().unwrap_or(false) {
                self.revision += 1;
            }
        }

        let runs = &self.runs;
        self.run_clocks.retain(|id, _| runs.contains_key(id));
        let ids = self.runs.keys().cloned().collect::<Vec<_>>();
        for id in ids {
            if let Some(run) = self.runs.get_mut(&id)
                && run.events.is_empty()
            {
                let mut clock = self.run_clocks.get_mut(&id);
                for event in run.session.events.try_iter().take(256) {
                    if let (Some(clock), Event::Frame(frame)) = (clock.as_deref_mut(), &event) {
                        clock.work.observe(&run.provider, frame);
                    }
                    run.events.push_back(event);
                }
            }
            if self.runs[&id].events.is_empty() {
                continue;
            }
            let newly_connected = self.run_clocks.get_mut(&id).is_some_and(|clock| {
                let changed = !clock.connected;
                clock.connected = true;
                changed
            });
            let newly_answered = self.answered_runs.insert(id.clone());
            // Many provider notifications (for example token-usage updates)
            // are already handled by the provider worker and have no effect
            // on the transcript. Avoid decoding and rewriting the entire
            // conversation for those notifications. Recovery still uses the
            // regular save path when an earlier write or usage record is pending.
            if !self.unsaved_threads.contains_key(&id)
                && !self.pending_usage.contains_key(&id)
                && self.store.contains_thread(&id).unwrap_or(false)
            {
                let run = self.runs.get_mut(&id).unwrap();
                let no_queue_claim = run.queue_claim.is_none();
                run.events.retain(|event| {
                    !(no_queue_claim && matches!(event, Event::TurnAccepted))
                        && !ignored_provider_notification(event)
                });
                if run.events.is_empty() {
                    if newly_connected || newly_answered {
                        self.revision += 1;
                    }
                    continue;
                }
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
            let mut events = std::mem::take(&mut self.runs.get_mut(&id).unwrap().events);
            let mut finished = false;
            let mut failure = None;
            let mut completion_alert = None;
            let transcript_start = self.runs[&id].transcript_start;
            while let Some(event) = events.pop_front() {
                // One usage record and its transcript save commit together.
                // A very fast continuation may finish more than once before
                // the UI polls; leave later receipts for the next save.
                if matches!(&event, Event::Usage) && self.pending_usage.contains_key(&id) {
                    events.push_front(event);
                    break;
                }
                if matches!(&event, Event::Usage | Event::Finished | Event::Failed(_))
                    && !self.pending_usage.contains_key(&id)
                {
                    let run = self.runs.get_mut(&id).unwrap();
                    if let Some(snapshot) = run.session.take_usage() {
                        let context = if matches!(&event, Event::Usage) {
                            run.usage_context
                                .replace(agent::usage_capture::TurnContext::new(&v))
                        } else {
                            run.usage_context.take()
                        }
                        .unwrap_or_else(|| agent::usage_capture::TurnContext::new(&v));
                        self.pending_usage
                            .insert(id.clone(), context.finish(snapshot));
                    }
                }
                match event {
                    Event::Session(session) => {
                        if self
                            .remember_native_configuration_session(
                                &self.runs[&id].provider,
                                &id,
                                &session,
                                self.runs[&id]
                                    .configuration
                                    .as_ref()
                                    .map(|configuration| configuration.stamp()),
                            )
                            .is_err()
                        {
                            append(
                                &mut v,
                                "notice",
                                "Provider session configuration could not be bound; a future turn will start a fresh provider session.",
                                None,
                            );
                        }
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
                        let provider = self.runs[&id].provider.clone();
                        if let Some(commands) =
                            self.composer_commands.bind_run(&id, &provider, &session)
                        {
                            let account = if v["selection"]["provider"] == provider {
                                v["selection"]["accountID"].clone()
                            } else {
                                Value::Null
                            };
                            let folder = self
                                .working_directory(&v)
                                .ok()
                                .and_then(|path| path.canonicalize().ok());
                            self.composer_commands.record(
                                &id,
                                &provider,
                                &account,
                                folder.as_deref(),
                                commands,
                            );
                        }
                    }
                    Event::Goal {
                        thread,
                        goal,
                        notice,
                        queue_action,
                        user_mutation,
                    } => {
                        if self.runs[&id].provider == "codex"
                            && agent::provider_session(&v, "codex").as_deref()
                                == Some(thread.as_str())
                        {
                            let account = self.runs[&id]
                                .session
                                .codex_profile_account()
                                .or_else(|| v["selection"]["accountID"].as_str())
                                .unwrap_or("default")
                                .to_owned();
                            v["rustCodexGoal"] =
                                json!({"sessionID":thread,"accountID":account,"goal":goal});
                            if queue_action == Some(true) && !self.runs[&id].cancelled {
                                if let Some(objective) =
                                    goal.as_ref().and_then(|goal| goal["objective"].as_str())
                                {
                                    v["rustCodexGoalAutoResume"] = json!({"sessionID":thread,"accountID":account,"objective":objective,"createdAt":goal.as_ref().unwrap()["createdAt"],"updatedAt":goal.as_ref().unwrap()["updatedAt"]});
                                }
                            } else if queue_action == Some(false)
                                || user_mutation
                                || self.runs[&id].cancelled
                            {
                                v.as_object_mut().unwrap().remove("rustCodexGoalAutoResume");
                            }
                            if let Some(notice) = notice {
                                append(&mut v, "notice", &notice, None);
                            }
                        }
                    }
                    Event::Usage => {}
                    Event::TurnAccepted => {
                        // A queue row represents delivery, not the duration of
                        // the provider's reply. Session creation alone does not
                        // prove delivery; this follows a verified turn ACK.
                        if !self.runs[&id].cancelled
                            && self.runs[&id].persistence_error.is_none()
                            && let Some(claim) = self.runs.get_mut(&id).unwrap().queue_claim.take()
                            && let Err(error) = crate::message_queue::finish(
                                &mut v,
                                &claim,
                                crate::message_queue::State::Completed,
                                None,
                            )
                        {
                            self.runs.get_mut(&id).unwrap().queue_claim = Some(claim);
                            self.runs.get_mut(&id).unwrap().persistence_error =
                                Some(error.to_string());
                            self.runs[&id].session.stop();
                        }
                    }
                    Event::TurnBoundary => {
                        // A queued turn can finish while the native goal
                        // continues in the same worker. Settle its owned row
                        // at that boundary, not when the whole goal ends.
                        if !self.runs[&id].cancelled
                            && self.runs[&id].persistence_error.is_none()
                            && let Some(claim) = self.runs.get_mut(&id).unwrap().queue_claim.take()
                            && let Err(error) = crate::message_queue::finish(
                                &mut v,
                                &claim,
                                crate::message_queue::State::Completed,
                                None,
                            )
                        {
                            self.runs.get_mut(&id).unwrap().queue_claim = Some(claim);
                            self.runs.get_mut(&id).unwrap().persistence_error =
                                Some(error.to_string());
                            self.runs[&id].session.stop();
                        }
                        if !self.runs[&id].cancelled
                            && self.runs[&id].persistence_error.is_none()
                            && !self.runs[&id].session.is_provider_control()
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
                    }
                    Event::Finished => {
                        finished = true;
                        if self.runs[&id].cancelled {
                            v.as_object_mut().unwrap().remove("rustCodexGoalAutoResume");
                        }
                        if completion_alert.is_none() {
                            completion_alert = v["items"]
                                .as_array()
                                .and_then(|items| {
                                    // A tool or reasoning event can follow the reply.
                                    // Anchor the alert to this turn's reply rather
                                    // than dropping it when the final item is a tool.
                                    items.iter().skip(transcript_start).rev().find(|item| {
                                        matches!(
                                            item["kind"].as_str(),
                                            Some("assistant" | "notice")
                                        )
                                    })
                                })
                                .cloned()
                                .map(|item| {
                                    (
                                        crate::platform_host::notifications::AlertKind::Completed,
                                        item,
                                    )
                                });
                            if completion_alert.is_none()
                                && self.notification_events.enabled()
                                && !self.runs[&id].cancelled
                                && self.runs[&id].persistence_error.is_none()
                            {
                                // Preserve the transcript as-is while giving a
                                // reply-less turn a unique persisted event identity.
                                let completion_id = Uuid::new_v4().to_string().to_uppercase();
                                v["rustNotificationCompletionID"] = json!(completion_id);
                                completion_alert = Some((
                                    crate::platform_host::notifications::AlertKind::Completed,
                                    json!({"id":completion_id}),
                                ));
                            }
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
                                    if item["rustAsync"] != true {
                                        let next = format!(
                                            "{}{}",
                                            text(item, "text"),
                                            p["delta"].as_str().unwrap_or("")
                                        );
                                        item["text"] = json!(next);
                                    }
                                } else {
                                    append(
                                        &mut v,
                                        kind,
                                        p["delta"].as_str().unwrap_or(""),
                                        Some(external),
                                    );
                                    if kind == "reasoning" {
                                        v["items"].as_array_mut().unwrap().last_mut().unwrap()["status"] =
                                            json!("running");
                                    }
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
                                    if item["externalID"] == key {
                                        if item["kind"] == "question" {
                                            // Keep the question row so it can say
                                            // "Not answered" like Swift.
                                            item["status"] = json!("declined");
                                            break;
                                        }
                                        if item["kind"] == "approval" {
                                            item["kind"] = json!("notice");
                                            item["text"] = json!("Provider cancelled this request");
                                            break;
                                        }
                                    }
                                }
                            }
                            "provider/acpSessionPersistence" => {
                                let provider = self.runs[&id].provider.clone();
                                if crate::acp_registry::registry_id(&provider).is_some()
                                    && let Some(can_resume) = p["canResume"].as_bool()
                                {
                                    if !v["rustAcpResumable"].is_object() {
                                        v["rustAcpResumable"] = json!({});
                                    }
                                    v["rustAcpResumable"][provider] = json!(can_resume);
                                }
                            }
                            "provider/event" => {
                                if let Some(commands) =
                                    crate::composer_suggestions::reported_commands(p)
                                {
                                    let provider = self.runs[&id].provider.clone();
                                    let frame = &p["providerFrame"];
                                    let commands = if frame["method"] == "session/update" {
                                        frame["params"]["sessionId"].as_str().and_then(|session| {
                                            self.composer_commands
                                                .acp_report(&id, &provider, session, commands)
                                        })
                                    } else {
                                        Some(commands)
                                    };
                                    let Some(commands) = commands else {
                                        continue;
                                    };
                                    let account = if v["selection"]["provider"] == provider {
                                        v["selection"]["accountID"].clone()
                                    } else {
                                        Value::Null
                                    };
                                    let folder = self
                                        .working_directory(&v)
                                        .ok()
                                        .and_then(|path| path.canonicalize().ok());
                                    self.composer_commands.record(
                                        &id,
                                        &provider,
                                        &account,
                                        folder.as_deref(),
                                        commands,
                                    );
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
                                if self.runs[&id].provider == "codex"
                                    && apply_compaction_item(&mut v, item, method, transcript_start)
                                {
                                    // Manual and automatic compaction are provider events;
                                    // keep one status row instead of showing raw JSON as a tool.
                                } else if let Some(kind) = completed_message_kind(item, method) {
                                    let external = text(item, "id");
                                    let items = v["items"].as_array_mut().unwrap();
                                    if let Some(existing) = items
                                        .iter_mut()
                                        .skip(transcript_start)
                                        .rev()
                                        .find(|it| it["externalID"] == external)
                                    {
                                        if existing["rustAsync"] != true {
                                            existing["text"] = item["text"].clone();
                                        }
                                        if kind == "reasoning" {
                                            existing["status"] = json!("completed");
                                        }
                                    } else {
                                        append(
                                            &mut v,
                                            kind,
                                            item["text"].as_str().unwrap_or(""),
                                            (!external.is_empty()).then_some(external.as_str()),
                                        );
                                        if kind == "reasoning" {
                                            v["items"]
                                                .as_array_mut()
                                                .unwrap()
                                                .last_mut()
                                                .unwrap()["status"] = json!("completed");
                                        }
                                    }
                                    if self.runs[&id].provider == "codex" {
                                        let native_session = p["threadId"].as_str().unwrap_or("");
                                        let selection = self.runs[&id]
                                            .usage_context
                                            .as_ref()
                                            .map(|context| context.selection().clone())
                                            .unwrap_or_else(|| v["selection"].clone());
                                        crate::async_questions::observe(
                                            &mut v,
                                            item,
                                            native_session,
                                            &selection,
                                            transcript_start,
                                        );
                                    }
                                } else if item["type"] != "userMessage"
                                    && item["type"] != "agentMessage"
                                    && item["type"] != "reasoning"
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
                                        provider_tool_metadata::apply(
                                            existing,
                                            &self.runs[&id].provider,
                                            item,
                                        );
                                        mark_completed(existing, method);
                                    } else {
                                        append(&mut v, "tool", &item.to_string(), Some(&external));
                                        let row =
                                            v["items"].as_array_mut().unwrap().last_mut().unwrap();
                                        provider_tool_metadata::apply(
                                            row,
                                            &self.runs[&id].provider,
                                            item,
                                        );
                                        mark_completed(row, method);
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
            if !events.is_empty() {
                self.runs.get_mut(&id).unwrap().events.extend(events);
            }
            if finished
                && failure.is_none()
                && !self.runs[&id].cancelled
                && self.runs[&id].persistence_error.is_none()
                && !self.runs[&id].session.is_provider_control()
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
                if let Some(clock) = self.run_clocks.get(&id)
                    && let Some(opener) = clock.opener.as_deref()
                {
                    record_turn_duration(
                        &mut v,
                        opener,
                        clock.started_monotonic.elapsed().as_secs_f64(),
                    );
                }
                self.notification_events.cancel_requests(&id);
                if !self.runs[&id].cancelled
                    && self.runs[&id].persistence_error.is_none()
                    && let Some((kind, item)) = completion_alert
                {
                    self.notification_events.stage(&v, &item, kind, None);
                }
            }
            if let Err(error) = self.store.save_streaming_with_usage(
                &v,
                self.pending_usage.get(&id).map(|record| &record.0),
                finished,
            ) {
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
                if finished
                    && failure.is_none()
                    && !self.runs[&id].cancelled
                    && self.runs[&id].persistence_error.is_none()
                    && self.runs[&id]
                        .resume_safe
                        .load(std::sync::atomic::Ordering::Acquire)
                    && let Some(ack) = self.runs[&id].session.take_named_completion()
                {
                    self.named_resume.persisted(
                        ack,
                        &v,
                        self.runs[&id].session.worker_completion(),
                    );
                }
            }
            self.revision += 1;
            if finished {
                self.composer_commands.end_run(&id);
                self.record_turn_result(&id, failure.is_some());
                self.finish_turn_checkpoint(&id);
            }
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
        self.answered_runs.retain(|id| self.runs.contains_key(id));
        self.poll_native_follow_ups();
        self.poll_message_queues();
        if self.schedule_last_poll.elapsed() >= Duration::from_secs(1) {
            let resumed = self.schedule_last_poll.elapsed() > Duration::from_secs(120);
            self.schedule_last_poll = Instant::now();
            self.unsaved_threads.retain(|id, thread| {
                if self
                    .store
                    .save_streaming_with_usage(
                        thread,
                        self.pending_usage.get(id).map(|record| &record.0),
                        !self.runs.contains_key(id),
                    )
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
/// Display Codex's own compaction events without changing its compaction policy.
fn apply_compaction_item(thread: &mut Value, item: &Value, method: &str, start: usize) -> bool {
    if item["type"] != "contextCompaction" || !matches!(method, "item/started" | "item/completed") {
        return false;
    }
    let Some(id) = item["id"]
        .as_str()
        .filter(|id| !id.is_empty() && id.len() <= 512 && !id.chars().any(char::is_control))
    else {
        return false;
    };
    let external = format!("compaction:{id}");
    let label = if method == "item/completed" {
        "Context compacted"
    } else {
        "Compacting context"
    };
    let existing = thread["items"].as_array_mut().and_then(|items| {
        items
            .iter_mut()
            .skip(start)
            .rev()
            .find(|entry| entry["externalID"] == external)
    });
    if let Some(existing) = existing {
        existing["text"] = json!(label);
        existing["status"] = json!(if method == "item/completed" {
            "completed"
        } else {
            "running"
        });
    } else {
        append(thread, "notice", label, Some(&external));
        if let Some(row) = thread["items"]
            .as_array_mut()
            .and_then(|items| items.last_mut())
        {
            row["status"] = json!(if method == "item/completed" {
                "completed"
            } else {
                "running"
            });
        }
    }
    true
}

/// Completed assistant text and reasoning both stream as message items. A
/// reasoning completion must update the existing reasoning row, never append a
/// duplicate tool row containing the provider's JSON payload.
fn completed_message_kind(item: &Value, method: &str) -> Option<&'static str> {
    if method != "item/completed" {
        return None;
    }
    match item["type"].as_str()? {
        "agentMessage" => Some("assistant"),
        "reasoning" => Some("reasoning"),
        _ => None,
    }
}
/// Keep display-only timing outside the immutable transcript prefix used by
/// interrupted follow-ups. Resumed work must not rewrite another turn.
fn record_turn_duration(thread: &mut Value, opener: &str, duration: f64) {
    if !duration.is_finite() || duration < 0. {
        return;
    }
    let eligible = thread["items"].as_array().is_some_and(|items| {
        items
            .iter()
            .any(|item| item["id"] == opener && item["kind"] == "user" && item["steered"] != true)
    });
    if !eligible {
        return;
    }
    if let Some(object) = thread.as_object_mut()
        && let Some(durations) = object
            .entry("rustTurnDurations")
            .or_insert_with(|| json!({}))
            .as_object_mut()
    {
        durations
            .entry(opener.to_owned())
            .or_insert(json!(duration));
    }
}

/// When the provider first reported a tool call finished, for its duration.
/// Display metadata only, like createdAt; it never settles the call or a turn.
fn mark_completed(row: &mut Value, method: &str) {
    if method == "item/completed"
        && let Some(fields) = row.as_object_mut()
    {
        fields
            .entry("completedAt")
            .or_insert_with(|| json!(swift_timestamp()));
    }
}
/// Mirrors the no-op cases in the frame handler without touching the
/// saved conversation. Requests with an ID are retained so unsupported
/// provider requests still produce an error row rather than being ignored.
fn ignored_provider_notification(event: &Event) -> bool {
    let Event::Frame(frame) = event else {
        return false;
    };
    match frame["method"].as_str().unwrap_or("") {
        "provider/event" => {
            crate::composer_suggestions::reported_commands(&frame["params"]).is_none()
        }
        "item/agentMessage/delta"
        | "item/reasoning/textDelta"
        | "item/reasoning/summaryTextDelta"
        | "item/commandExecution/requestApproval"
        | "item/fileChange/requestApproval"
        | "item/tool/requestUserInput"
        | "provider/requestCancelled"
        | "provider/requestRejected"
        | "provider/acpSessionPersistence"
        | "item/started"
        | "item/completed" => false,
        _ => frame.get("id").is_none() || frame.get("method").is_none(),
    }
}
/// A dismissed question must use each provider adapter's cancellation shape.
/// In particular, an empty answer alone is rejected by the ACP adapters.
pub(crate) fn question_dismissal(provider: &str) -> Result<Value> {
    match provider {
        "codex" | "claude" => Ok(json!({"answers":{}})),
        "cursor" | "grok" | "opencode" | "lithos" | "antigravity" => {
            Ok(json!({"decision":"cancel"}))
        }
        _ => bail!("This provider does not support dismissing questions"),
    }
}

fn append(v: &mut Value, kind: &str, text: &str, external: Option<&str>) {
    let provider = v["selection"]["provider"].clone();
    let model = v["selection"]["modelID"].clone();
    let account = v["selection"]["accountID"].clone();
    v["items"].as_array_mut().expect("validated thread").push(json!({"id":Uuid::new_v4().to_string().to_uppercase(),"kind":kind,"text":text,"provider":provider,"modelID":model,"accountID":account,"createdAt":swift_timestamp(),"externalID":external}));
}
pub fn call(engine: &SharedEngine, method: &str, params: Value) -> Result<Value> {
    let mut response = engine
        .lock()
        .map_err(|_| anyhow::anyhow!("Engine lock failed"))?
        .dispatch(json!({"method":method,"params":params}));
    if let Some(error) = response.get("error") {
        bail!("{}", error["message"].as_str().unwrap_or("Command failed"));
    }
    Ok(response
        .get_mut("result")
        .map(Value::take)
        .unwrap_or(Value::Null))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn codex_automatic_and_manual_compaction_update_one_status_row() {
        let mut thread = json!({"selection":{"provider":"codex","modelID":"model"},"items":[]});
        let item = json!({"type":"contextCompaction","id":"compaction-1"});
        assert!(apply_compaction_item(&mut thread, &item, "item/started", 0));
        assert_eq!(thread["items"][0]["text"], "Compacting context");
        assert!(apply_compaction_item(
            &mut thread,
            &item,
            "item/completed",
            0
        ));
        assert_eq!(thread["items"].as_array().unwrap().len(), 1);
        assert_eq!(thread["items"][0]["text"], "Context compacted");
        assert_eq!(thread["items"][0]["status"], "completed");
        assert!(!apply_compaction_item(
            &mut thread,
            &json!({"type":"other","id":"x"}),
            "item/completed",
            0
        ));
    }
    #[test]
    fn completed_reasoning_is_a_reasoning_row_not_a_tool_payload() {
        assert_eq!(
            completed_message_kind(
                &json!({"type":"reasoning","id":"m:reasoning:0","text":"thought"}),
                "item/completed"
            ),
            Some("reasoning")
        );
        assert_eq!(
            completed_message_kind(
                &json!({"type":"agentMessage","id":"m:text:0","text":"answer"}),
                "item/completed"
            ),
            Some("assistant")
        );
        assert_eq!(
            completed_message_kind(&json!({"type":"toolCall","id":"t"}), "item/completed"),
            None
        );
        assert_eq!(
            completed_message_kind(
                &json!({"type":"reasoning","id":"m:reasoning:0"}),
                "item/started"
            ),
            None
        );
    }
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
    fn remote_snapshot_cannot_perform_mutations() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(&dir.path().join("data.sqlite")).unwrap();
        let mut engine = Engine::fixture(store);
        let thread = engine.store.new_thread("").unwrap();
        let id = thread["id"].as_str().unwrap();
        let result = engine.dispatch_remote_snapshot(
            "threads.patch",
            json!({"threadId":id,"patch":{"draft":"must not be saved"}}),
        );
        assert!(result.get("error").is_some());
        assert_eq!(engine.store.thread(id).unwrap()["draft"], thread["draft"]);
    }
    #[test]
    fn thread_read_snapshot_keeps_its_revision_and_unsaved_recovery_data() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::new(Store::open(&dir.path().join("snapshot.sqlite")).unwrap());
        let created = engine.execute("threads.create", &json!({})).unwrap();
        let id = text(&created, "id");
        let (revision, snapshot, _) = engine.capture_thread_read(&id).unwrap();
        engine
            .execute(
                "threads.patch",
                &json!({"threadId":id,"patch":{"draft":"newer"}}),
            )
            .unwrap();
        assert!(engine.revision > revision);
        assert_ne!(snapshot.decode().unwrap()["draft"], "newer");
        let mut unsaved = engine.store.thread(&id).unwrap();
        unsaved["items"] = json!([{"id":"recovery","kind":"assistant","text":"not yet saved"}]);
        engine.unsaved_threads.insert(id.clone(), unsaved.clone());
        let (_, snapshot, queue) = engine.capture_thread_read(&id).unwrap();
        assert_eq!(snapshot.decode().unwrap(), unsaved);
        assert_eq!(queue, None);
        assert!(engine.capture_thread_read("missing").is_err());
    }

    #[test]
    fn remote_sidebar_reads_unsaved_fields_without_copying_the_transcript() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        let mut thread = engine
            .store
            .new_thread("00000000-0000-0000-0000-000000000000")
            .unwrap();
        let id = text(&thread, "id");
        thread["items"] = json!([{"text":"not yet persisted"}, {"text":"second item"}]);
        thread["draft"] = json!("unsaved draft");
        engine.unsaved_threads.insert(id.clone(), thread);
        let (metadata, count) = engine.remote_thread_metadata(&id).unwrap();
        assert_eq!(count, 2);
        assert_eq!(metadata["draft"], "unsaved draft");
        assert!(metadata.get("items").is_none());
    }
    #[test]
    fn queue_and_pending_reads_keep_validation_and_raw_queue_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::new(Store::open(&dir.path().join("reads.sqlite")).unwrap());
        let mut thread = engine.execute("threads.create", &json!({})).unwrap();
        let id = text(&thread, "id");
        crate::message_queue::add(&mut thread, "queued").unwrap();
        thread["rustMessageQueue"][0]["futureField"] = json!({"preserve":true});
        thread["rustQueueError"] = json!("paused");
        engine.store.save(&thread).unwrap();
        let result = engine
            .execute("agent.queue.list", &json!({"threadId":id}))
            .unwrap();
        assert_eq!(result["messages"][0]["text"], "queued");
        assert!(result.get("rawQueue").is_none());
        assert_eq!(
            engine.native_queue_read(&id).unwrap()["rawQueue"],
            thread["rustMessageQueue"]
        );
        assert_eq!(result["error"], "paused");
        assert_eq!(
            engine
                .execute("agent.pending", &json!({"threadId":id}))
                .unwrap(),
            json!([])
        );
        assert!(
            engine
                .execute("agent.pending", &json!({"threadId":"missing"}))
                .is_err()
        );
        thread["rustMessageQueue"] = json!(true);
        engine.store.save(&thread).unwrap();
        assert!(
            engine
                .execute("agent.queue.list", &json!({"threadId":id}))
                .is_err()
        );
    }
    #[test]
    fn completed_or_removed_queue_does_not_expose_an_old_error() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("queue.sqlite")).unwrap());
        let mut thread = engine.store.new_thread("").unwrap();
        let id = text(&thread, "id");
        crate::message_queue::add(&mut thread, "saved message").unwrap();
        thread["rustQueueError"] = json!("old catalog failure");
        engine.store.save(&thread).unwrap();
        assert_eq!(
            engine.native_queue_read(&id).unwrap()["error"],
            "old catalog failure"
        );
        for state in ["failed", "interrupted", "dispatching"] {
            thread["rustMessageQueue"][0]["state"] = json!(state);
            engine.store.save(&thread).unwrap();
            assert_eq!(
                engine.native_queue_read(&id).unwrap()["error"],
                "old catalog failure"
            );
        }
        thread["rustMessageQueue"][0]["state"] = json!("completed");
        engine.store.save(&thread).unwrap();
        assert!(engine.native_queue_read(&id).unwrap()["error"].is_null());
        assert_eq!(
            engine.store.thread(&id).unwrap()["rustQueueError"],
            "old catalog failure"
        );
        thread["rustMessageQueue"] = json!([]);
        engine.store.save(&thread).unwrap();
        assert!(engine.native_queue_read(&id).unwrap()["error"].is_null());
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
        assert!(
            engine
                .execute("agent.select", &json!({"threadId":id,"provider":"unknown"}))
                .is_err()
        );
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
    fn catalog_revocation_waits_for_exact_provider_worker_join() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        let (release, held) = std::sync::mpsc::channel();
        let session = Session::fixture_worker(move |_, events| {
            events.send(Event::Finished).unwrap();
            held.recv().unwrap();
        });
        assert!(matches!(
            session
                .events
                .recv_timeout(Duration::from_secs(10))
                .unwrap(),
            Event::Finished
        ));
        let worker = session.worker_completion();
        engine.provider_workers.push((None, worker.clone()));
        engine.freeze_admissions();
        engine.request_model_catalog_shutdown().unwrap();
        assert!(
            !engine.model_catalog_shutdown_status().unwrap().closed,
            "Semantic completion must not revoke a saved pending receipt before actual join"
        );
        release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while worker.status() == agent::WorkerThreadStatus::Running {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(worker.status(), agent::WorkerThreadStatus::Returned);
        assert!(engine.model_catalog_shutdown_status().unwrap().closed);
    }
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

#[cfg(test)]
#[path = "question_dismiss_tests.rs"]
mod question_dismiss_tests;
#[cfg(test)]
#[path = "remote_marker_tests.rs"]
mod remote_marker_tests;
