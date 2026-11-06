//! Owned provider processes and bounded JSON transports.
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Read, Write},
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU8, Ordering},
        mpsc::{self, Receiver, Sender},
    },
    thread,
    time::{Duration, Instant},
};

#[path = "provider_acp.rs"]
mod acp;
#[path = "provider_antigravity.rs"]
mod antigravity;
#[path = "provider_claude.rs"]
mod claude;
#[path = "codex_speed.rs"]
mod codex_speed;
#[path = "codex_steering.rs"]
pub(crate) mod codex_steering;
#[path = "provider_cursor.rs"]
mod cursor;
#[path = "provider_grok.rs"]
mod grok;
#[path = "provider_images.rs"]
mod images;
#[path = "provider_opencode.rs"]
mod opencode;
#[path = "provider_transport.rs"]
mod transport;
#[path = "usage_capture.rs"]
pub(crate) mod usage_capture;
pub use images::{ImageAttachment, validate_images};

/// Protocol selection is separate from executable discovery and account selection.
/// Launches inherit the caller's environment; no adapter switches accounts or permissions.
#[derive(Clone, Debug)]
pub enum Provider {
    Codex,
    Claude,
    Grok,
    OpenCode,
    Antigravity {
        profile: Option<PathBuf>,
        source_profile: Option<PathBuf>,
        risk_acknowledged: bool,
    },
    Cursor {
        profile: Option<PathBuf>,
    },
    /// An explicitly configured ACP v1 server. Provider-specific discovery, login,
    /// modes and extensions are not implied by support for its wire protocol.
    AcpV1 {
        arguments: Vec<String>,
    },
}

impl Provider {
    pub fn supported_names() -> &'static [&'static str] {
        &[
            "codex",
            "claude",
            "grok",
            "opencode",
            "cursor",
            "antigravity",
        ]
    }
    pub fn from_name(name: &str) -> Result<Self> {
        match name {
            "codex" => Ok(Self::Codex),
            "claude" => Ok(Self::Claude),
            "grok" => Ok(Self::Grok),
            "cursor" => Ok(Self::Cursor { profile: None }),
            "opencode" => Ok(Self::OpenCode),
            "antigravity" => Ok(Self::Antigravity {
                profile: None,
                source_profile: None,
                risk_acknowledged: false,
            }),
            _ => bail!("Unknown provider: {name}"),
        }
    }
    pub fn id(&self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
            Self::Grok => "grok",
            Self::OpenCode => "opencode",
            Self::Antigravity { .. } => "antigravity",
            Self::Cursor { .. } => "cursor",
            Self::AcpV1 { .. } => "acp",
        }
    }
}

pub struct Launch {
    pub executable: PathBuf,
    pub cwd: PathBuf,
    pub session: Option<String>,
    pub prompt: String,
    pub model: Option<String>,
}
#[derive(Debug)]
pub enum Event {
    Session(String),
    Frame(Value),
    Finished,
    Failed(String),
}
pub enum Control {
    Stop,
    Reply { id: Value, result: Value },
}
/// Rust-thread ownership only: Returned does not prove provider success or
/// successful child/process-group cleanup. No status waits for a worker.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorkerThreadStatus {
    Running,
    Returned,
    Panicked,
    Unclassified,
}

/// Independent observer; dropping a Session cannot discard this ownership.
/// A dedicated background observer joins the provider thread, including its TLS
/// destructors, before publishing an outcome. Status and Drop never join/wait.
#[derive(Clone)]
pub struct WorkerCompletion {
    outcome: Arc<AtomicU8>,
    _worker: Arc<Mutex<Option<thread::JoinHandle<()>>>>,
}
impl WorkerCompletion {
    /// Trusted Rust owners transfer a real thread handle here. This observes
    /// thread exit only, never process cleanup or whole-app quiescence.
    /// Observer startup failure retains the handle and reports Unclassified;
    /// status and Drop never join on the calling thread.
    pub fn observe(worker: thread::JoinHandle<()>) -> Self {
        Self::observe_with(worker, |observe| {
            thread::Builder::new()
                .name("coincide-worker-join".into())
                .spawn(observe)
        })
    }
    fn observe_with(
        worker: thread::JoinHandle<()>,
        spawn: impl FnOnce(Box<dyn FnOnce() + Send>) -> std::io::Result<thread::JoinHandle<()>>,
    ) -> Self {
        let outcome = Arc::new(AtomicU8::new(0));
        let joined_outcome = outcome.clone();
        let retained = Arc::new(Mutex::new(Some(worker)));
        let owned = retained.clone();
        // is_finished may precede TLS destruction; publish only after join.
        let observer = spawn(Box::new(move || {
            let worker = owned.lock().unwrap_or_else(|e| e.into_inner()).take();
            let status = worker.map_or(3, |worker| if worker.join().is_ok() { 1 } else { 2 });
            joined_outcome.store(status, Ordering::Release);
        }));
        if observer.is_err() {
            outcome.store(3, Ordering::Release);
        }
        Self {
            outcome,
            _worker: retained,
        }
    }
    pub fn status(&self) -> WorkerThreadStatus {
        match self.outcome.load(Ordering::Acquire) {
            0 => WorkerThreadStatus::Running,
            1 => WorkerThreadStatus::Returned,
            2 => WorkerThreadStatus::Panicked,
            _ => WorkerThreadStatus::Unclassified,
        }
    }
}
pub struct Session {
    pub events: Receiver<Event>,
    control: Sender<Control>,
    completion: WorkerCompletion,
    usage: Arc<Mutex<Option<usage_capture::Snapshot>>>,
    steering: Option<codex_steering::Client>,
    codex_profile_account: Option<String>,
}
#[cfg(test)]
mod completion_owner_tests {
    use super::*;
    #[test]
    fn observer_start_failure_retains_real_worker_without_publishing_exit() {
        let (release, wait) = mpsc::channel();
        let worker = thread::spawn(move || {
            let _ = wait.recv();
        });
        let observation = WorkerCompletion::observe_with(worker, |_| {
            Err(std::io::Error::other("synthetic observer failure"))
        });
        assert_eq!(observation.status(), WorkerThreadStatus::Unclassified);
        assert!(observation._worker.lock().unwrap().is_some());
        release.send(()).unwrap();
        // Even when the body is allowed to return, no join ACK was observed.
        assert_eq!(observation.status(), WorkerThreadStatus::Unclassified);
    }
}
impl Session {
    pub fn start(launch: Launch) -> Self {
        Self::start_with(Provider::Codex, launch)
    }
    pub fn start_with(provider: Provider, launch: Launch) -> Self {
        Self::start_with_images(provider, launch, Vec::new())
    }
    /// Images are validated/materialized by the caller before launch. Existing
    /// text-only callers keep the same Launch and Session interfaces.
    pub fn start_with_images(
        provider: Provider,
        launch: Launch,
        images: Vec<ImageAttachment>,
    ) -> Self {
        Self::start_with_images_and_instructions(provider, launch, images, None)
    }
    /// Explicit bot-local instruction CONTENT, not a path or an agent-supplied
    /// global setting. Parent must validate rustBotContext before calling.
    /// Every turn must supply the same validated snapshot, including resume.
    pub fn start_with_images_and_instructions(
        provider: Provider,
        launch: Launch,
        images: Vec<ImageAttachment>,
        instructions: Option<String>,
    ) -> Self {
        Self::start_with_mode_policy(provider, launch, images, instructions, None)
    }
    /// Trusted ordinary-turn policy; Engine has already validated origin,
    /// selection and preflight before any persistence or provider launch.
    pub fn start_with_mode_policy(
        provider: Provider,
        launch: Launch,
        images: Vec<ImageAttachment>,
        instructions: Option<String>,
        policy: Option<crate::composer_policy::Policy>,
    ) -> Self {
        Self::start_with_mode_policy_and_profile(
            provider,
            launch,
            images,
            instructions,
            policy,
            None,
        )
    }
    pub(crate) fn start_with_mode_policy_and_profile(
        provider: Provider,
        launch: Launch,
        images: Vec<ImageAttachment>,
        instructions: Option<String>,
        policy: Option<crate::composer_policy::Policy>,
        profile: Option<crate::codex_login_profiles::LaunchContext>,
    ) -> Self {
        let profile_account = profile.as_ref().map(|profile| profile.account().to_owned());
        let codex = matches!(&provider, Provider::Codex);
        let (steer_client, steer_server) = codex_steering::pair();
        let usage = Arc::new(Mutex::new(None));
        let output = usage.clone();
        let mut session = Self::spawn_worker(move |commands, events_tx| {
            let result = validate_instructions(&provider, instructions.as_deref())
                .and_then(|()| {
                    if let Some(policy) = &policy {
                        ensure!(
                            matches!(&provider, Provider::Codex) && instructions.is_none(),
                            "Mode policy is supported only for ordinary Codex turns"
                        );
                        policy.require_codex()?;
                        policy.preflight()?;
                        policy.validate_launch_executable(&launch.executable)?;
                    }
                    Ok(())
                })
                .and_then(|()| {
                    ensure!(
                        profile.is_none() || matches!(&provider, Provider::Codex),
                        "A Codex profile cannot launch another provider"
                    );
                    validate_images(&provider, &images)
                })
                .and_then(|()| match provider {
                    Provider::Codex => run(
                        launch,
                        images,
                        instructions,
                        commands,
                        events_tx,
                        CodexOptions {
                            usage: output,
                            steering: steer_server,
                            policy,
                            profile,
                        },
                    ),
                    Provider::Claude => {
                        claude::run(launch, images, instructions, commands, events_tx)
                    }
                    Provider::Grok => grok::run(launch, images, commands, events_tx),
                    Provider::OpenCode => opencode::run(launch, images, commands, events_tx),
                    Provider::Antigravity {
                        profile,
                        source_profile,
                        risk_acknowledged,
                    } => antigravity::run(
                        launch,
                        images,
                        profile,
                        source_profile,
                        risk_acknowledged,
                        commands,
                        events_tx,
                    ),
                    Provider::Cursor { profile } => {
                        cursor::run(launch, images, profile, commands, events_tx)
                    }
                    Provider::AcpV1 { arguments } => {
                        acp::run(launch, arguments, images, commands, events_tx)
                    }
                });
            if let Err(e) = result {
                let _ = events_tx.send(Event::Failed(e.to_string()));
            }
        });
        session.usage = usage;
        session.codex_profile_account = profile_account;
        if codex {
            session.steering = Some(steer_client);
        }
        session
    }
    pub(crate) fn codex_profile_account(&self) -> Option<&str> {
        self.codex_profile_account.as_deref()
    }
    pub(crate) fn steer(&self, text: &str) -> Result<codex_steering::Ticket> {
        self.steering
            .as_ref()
            .context("Active-turn steering is supported only for Codex")?
            .submit(text)
    }
    pub(crate) fn take_usage(&self) -> Option<usage_capture::Snapshot> {
        self.usage.lock().ok()?.take()
    }
    fn spawn_worker(work: impl FnOnce(Receiver<Control>, &Sender<Event>) + Send + 'static) -> Self {
        let (events_tx, events) = mpsc::channel();
        let (control, commands) = mpsc::channel();
        let worker = thread::spawn(move || {
            work(commands, &events_tx);
        });
        Self {
            events,
            control,
            completion: WorkerCompletion::observe(worker),
            usage: Arc::new(Mutex::new(None)),
            steering: None,
            codex_profile_account: None,
        }
    }
    #[cfg(test)]
    pub(crate) fn fixture_worker(
        work: impl FnOnce(Receiver<Control>, &Sender<Event>) + Send + 'static,
    ) -> Self {
        Self::spawn_worker(work)
    }
    #[cfg(test)]
    pub(crate) fn fixture_steering(&mut self) -> codex_steering::Server {
        let (client, server) = codex_steering::pair();
        self.steering = Some(client);
        server
    }
    #[cfg(test)]
    pub(crate) fn fixture_usage(&self, snapshot: usage_capture::Snapshot) {
        *self.usage.lock().unwrap() = Some(snapshot);
    }
    pub fn worker_completion(&self) -> WorkerCompletion {
        self.completion.clone()
    }
    pub fn stop(&self) {
        let _ = self.control.send(Control::Stop);
    }
    pub fn reply(&self, id: Value, result: Value) -> Result<()> {
        Ok(self.control.send(Control::Reply { id, result })?)
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.stop();
    }
}
/// Shared content cap for Claude argv and Codex JSON transport.
pub const MAX_INSTRUCTIONS_BYTES: usize = 64 * 1024;
fn validate_instructions(provider: &Provider, instructions: Option<&str>) -> Result<()> {
    if let Some(instructions) = instructions {
        ensure!(
            matches!(provider, Provider::Codex | Provider::Claude),
            "Bot-local instructions are unsupported for this provider"
        );
        ensure!(
            !instructions.trim().is_empty(),
            "Bot-local instructions cannot be empty"
        );
        ensure!(
            instructions.len() <= MAX_INSTRUCTIONS_BYTES,
            "Bot-local instructions exceed 64 KiB"
        );
        ensure!(
            !instructions.contains('\0'),
            "Bot-local instructions cannot contain NUL"
        );
    }
    Ok(())
}

struct OwnedChild(Child);
impl OwnedChild {
    fn spawn(command: &mut Command) -> Result<Self> {
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            // A dedicated group lets cancellation terminate tools and shells too.
            command.process_group(0);
        }
        Ok(Self(command.spawn()?))
    }
}
impl Drop for OwnedChild {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            // Only groups created by OwnedChild::spawn are owned here. Negative
            // PID targets this child's process group, never the host app's group.
            if let Ok(pid) = i32::try_from(self.0.id()) {
                unsafe {
                    libc::kill(-pid, libc::SIGKILL);
                }
            }
        }
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn request(id: u64, method: &str, params: Value) -> Value {
    json!({"id":id,"method":method,"params":params})
}

struct CodexOptions {
    usage: Arc<Mutex<Option<usage_capture::Snapshot>>>,
    steering: codex_steering::Server,
    policy: Option<crate::composer_policy::Policy>,
    profile: Option<crate::codex_login_profiles::LaunchContext>,
}
fn run(
    launch: Launch,
    images: Vec<ImageAttachment>,
    instructions: Option<String>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
    options: CodexOptions,
) -> Result<()> {
    let CodexOptions {
        usage,
        mut steering,
        policy,
        profile,
    } = options;
    if let Some(policy) = &policy {
        policy.preflight()?;
        policy.validate_launch_executable(&launch.executable)?;
    }
    let mut capture = usage_capture::Capture::default();
    let mut service_tier = codex_speed::History::default();
    let image_paths = images
        .iter()
        .map(|image| image.path().to_path_buf())
        .collect::<Vec<_>>();
    drop(images);
    let mut transport = if let Some(profile) = &profile {
        ensure!(
            launch.session.is_none() && launch.model.is_none() && instructions.is_none(),
            "Named Codex profile native resume/options are unavailable"
        );
        transport::Transport::spawn_codex_profile(&launch, profile)?
    } else {
        transport::Transport::spawn(&launch, &["app-server".into()], &[])?
    };
    transport.write(&request(
        1,
        "initialize",
        json!({"clientInfo":{"name":"coincide","title":"Coincide","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}),
    ))?;
    let started = Instant::now();
    let mut stage = 1;
    let mut account_pending = false;
    const ACCOUNT_REQUEST: u64 = 4_000_000_001;
    let mut completed = false;
    let mut early_completions = std::collections::VecDeque::new();
    let mut provisional_turn = false;
    let mut early_steering_frames = Vec::new();
    loop {
        while let Ok(command) = commands.try_recv() {
            match command {
                Control::Stop => {
                    events.send(Event::Finished)?;
                    return Ok(());
                }
                Control::Reply { id, result } => {
                    transport.write(&json!({"id":id,"result":result}))?
                }
            }
        }
        if completed {
            steering.close();
            if transport.is_flushed()? {
                events.send(Event::Finished)?;
                return Ok(());
            }
            thread::sleep(Duration::from_millis(10));
            continue;
        }
        if stage < 4 && started.elapsed() > Duration::from_secs(120) {
            bail!("Codex startup timed out");
        }
        if let Some(request) = steering.next_request() {
            transport.write(&request)?;
        }
        let frame = if stage >= 4 {
            match early_completions.pop_front() {
                Some(frame) => Some(frame),
                None => transport.next()?,
            }
        } else {
            transport.next()?
        };
        if let Some(frame) = frame {
            if let Some(profile) = profile.as_ref()
                && frame["id"].as_u64() == Some(ACCOUNT_REQUEST)
            {
                ensure!(
                    account_pending && stage == 1 && frame.get("error").is_none(),
                    "Codex profile authentication check failed"
                );
                profile.admit_account(&frame["result"])?;
                account_pending = false;
                write_thread_request(&mut transport, &launch, instructions.as_deref())?;
                stage = 2;
                continue; // Never forward account metadata to transcript/events.
            }
            if profile.is_some() && frame["method"] == "account/rateLimits/updated" {
                // This ordinary sparse quota notification provides no account
                // authority. Named-profile limits are not mounted in this slice.
                continue;
            }
            if profile.is_some()
                && frame["method"]
                    .as_str()
                    .is_some_and(|method| method.starts_with("account/"))
            {
                ensure!(
                    stage == 1,
                    "Codex profile authentication changed during the turn"
                );
                continue;
            }
            if steering.response(&frame) {
                continue;
            }
            if stage < 4
                && capture.owns_thread(&frame["params"])
                && matches!(
                    frame["method"].as_str(),
                    Some("item/started" | "item/completed" | "item/agentMessage/delta")
                )
            {
                ensure!(
                    early_steering_frames.len() < 64 && frame.to_string().len() <= 65_536,
                    "Codex early item boundary buffer exceeded limit"
                );
                early_steering_frames.push(frame.clone());
            }
            steering.observe(&frame);
            if frame.get("error").is_some() && frame.get("id").is_some() {
                bail!("Codex rejected request: {}", frame["error"]);
            }
            if frame["id"].as_u64() == Some(stage) && frame.get("result").is_some() {
                match stage {
                    1 => {
                        transport.write(&json!({"method":"initialized"}))?;
                        if profile.is_some() {
                            account_pending = true;
                            transport.write(&request(
                                ACCOUNT_REQUEST,
                                "account/read",
                                json!({"refreshToken":false}),
                            ))?;
                            continue;
                        }
                        write_thread_request(&mut transport, &launch, instructions.as_deref())?;
                    }
                    2 => {
                        if let Some(profile) = &profile {
                            profile.validate()?;
                        }
                        let id = frame["result"]["thread"]["id"]
                            .as_str()
                            .context("Codex returned no thread ID")?;
                        ensure!(
                            launch
                                .session
                                .as_ref()
                                .is_none_or(|expected| expected == id),
                            "Codex resume returned another source thread identity"
                        );
                        ensure!(
                            capture.bind_thread(id),
                            "Codex returned an invalid or duplicate thread identity"
                        );
                        events.send(Event::Session(id.into()))?;
                        let mut params = turn_params(id, &launch, &image_paths);
                        if let Some(policy) = &policy {
                            let resolved =
                                crate::composer_policy::ResolvedCodexModel::from_thread_result(
                                    id,
                                    &frame["result"],
                                )
                                .ok();
                            let history = if launch.session.is_some() {
                                crate::composer_policy::CollaborationHistory::Unknown
                            } else {
                                crate::composer_policy::CollaborationHistory::NeverApplied
                            };
                            let fields =
                                policy.codex_turn_fields(id, resolved.as_ref(), history)?;
                            params
                                .as_object_mut()
                                .unwrap()
                                .extend(fields.as_object().unwrap().clone());
                        }
                        if let Some(policy) = &policy {
                            service_tier.adopt(id, &frame["result"])?;
                            if let Some(tier) = service_tier.request(policy.codex_speed()) {
                                params["serviceTier"] = json!(tier);
                            }
                        }
                        transport.write(&request(3, "turn/start", params))?;
                    }
                    3 => ensure!(
                        capture.bind_turn(&frame["result"]["turn"]["id"]),
                        "Codex returned a missing, invalid or duplicate turn identity"
                    ),
                    _ => {}
                }
                stage += 1;
                if stage == 4
                    && !early_completions
                        .iter()
                        .any(|frame: &Value| capture.matches_completion(&frame["params"]))
                    && let Some((thread, turn)) = capture.identity()
                {
                    steering.activate(thread, turn);
                    for early in early_steering_frames.drain(..) {
                        steering.observe(&early);
                    }
                }
            } else if frame["id"].as_u64().is_some_and(|id| (1..=3).contains(&id))
                && frame.get("result").is_some()
            {
                bail!("Codex returned a duplicate or out-of-order startup response");
            } else if frame["method"] == "turn/started" {
                if stage == 3 && capture.owns_thread(&frame["params"]) {
                    ensure!(
                        !provisional_turn,
                        "Codex returned a duplicate provisional turn identity"
                    );
                    ensure!(
                        capture.bind_turn(&frame["params"]["turn"]["id"]),
                        "Codex returned an invalid provisional turn identity"
                    );
                    provisional_turn = true;
                }
            } else if frame["method"] == "turn/completed" {
                if stage == 3 && capture.owns_thread(&frame["params"]) {
                    ensure!(
                        early_completions.len() < 8 && frame.to_string().len() <= 65_536,
                        "Codex early completion buffer exceeded limit"
                    );
                    early_completions.push_back(frame);
                    continue;
                }
                if !capture.matches_completion(&frame["params"]) {
                    continue;
                }
                if let Some(snapshot) = capture.complete(&frame["params"])
                    && let Ok(mut output) = usage.lock()
                {
                    *output = Some(snapshot);
                }
                if frame["params"]["turn"]["status"] == "failed" {
                    bail!("Codex turn failed: {}", frame["params"]["turn"]["error"]);
                }
                ensure!(
                    matches!(
                        frame["params"]["turn"]["status"].as_str(),
                        Some("completed" | "interrupted")
                    ),
                    "Codex returned an invalid turn completion status"
                );
                completed = true;
            } else {
                if frame["method"] == "thread/tokenUsage/updated" {
                    ensure!(
                        capture.update(&frame["params"]),
                        "Codex early usage buffer exceeded limit"
                    );
                }
                events.send(Event::Frame(frame))?;
            }
        }
    }
}
fn write_thread_request(
    transport: &mut transport::Transport,
    launch: &Launch,
    instructions: Option<&str>,
) -> Result<()> {
    let mut params = json!({"cwd":launch.cwd,"approvalPolicy":"untrusted","sandbox":"read-only"});
    if let Some(model) = &launch.model {
        params["model"] = json!(model);
    }
    if let Some(instructions) = instructions {
        params["developerInstructions"] = json!(instructions);
    }
    let method = if let Some(session) = &launch.session {
        params["threadId"] = json!(session);
        params["excludeTurns"] = json!(true);
        "thread/resume"
    } else {
        "thread/start"
    };
    transport.write(&request(2, method, params))
}
fn turn_params(id: &str, launch: &Launch, image_paths: &[PathBuf]) -> Value {
    let mut input = Vec::new();
    if !launch.prompt.is_empty() {
        input.push(json!({"type":"text","text":launch.prompt}));
    }
    input.extend(
        image_paths
            .iter()
            .map(|path| json!({"type":"localImage","path":path})),
    );
    let mut v = json!({"threadId":id,"cwd":launch.cwd,"input":input,"approvalPolicy":"untrusted","approvalsReviewer":"user","sandboxPolicy":{"type":"readOnly"}});
    if let Some(model) = &launch.model {
        v["model"] = json!(model);
    }
    v
}

/// Swift encodes dictionaries whose key is an enum as alternating key/value arrays.
/// Accept both representations; never replace other providers' session references.
pub fn provider_session(thread: &Value, provider: &str) -> Option<String> {
    provider_reference(thread, provider)?["sessionID"]
        .as_str()
        .map(str::to_owned)
}

fn selected_account<'a>(thread: &'a Value, provider: &str) -> &'a str {
    if thread["selection"]["provider"] == provider {
        thread["selection"]["accountID"]
            .as_str()
            .filter(|id| !id.is_empty())
            .unwrap_or("default")
    } else {
        "default"
    }
}
fn reference_account(reference: &Value) -> &str {
    reference["accountID"]
        .as_str()
        .filter(|id| !id.is_empty())
        .unwrap_or("default")
}
fn current_reference<'a>(thread: &'a Value, provider: &str) -> Option<&'a Value> {
    let sessions = &thread["sessions"];
    if let Some(array) = sessions.as_array() {
        array
            .as_chunks::<2>()
            .0
            .iter()
            .find(|pair| pair[0] == provider)
            .map(|pair| &pair[1])
    } else {
        sessions.get(provider)
    }
}
fn provider_reference<'a>(thread: &'a Value, provider: &str) -> Option<&'a Value> {
    let account = selected_account(thread, provider);
    current_reference(thread, provider)
        .filter(|reference| reference_account(reference) == account)
        .or_else(|| thread["accountSessions"].get(format!("{provider}/{account}")))
}

/// Missing or malformed progress must replay context rather than silently skip
/// it. The index is into the complete transcript, including non-message items.
pub fn provider_seen_count(thread: &Value, provider: &str) -> usize {
    let Some(reference) = provider_reference(thread, provider) else {
        return 0;
    };
    if reference["sessionID"].as_str().is_none_or(str::is_empty) {
        return 0;
    }
    let count = reference["seenItemCount"]
        .as_u64()
        .and_then(|count| usize::try_from(count).ok());
    let length = thread["items"].as_array().map_or(0, Vec::len);
    count.filter(|count| *count <= length).unwrap_or(0)
}

/// Call only after the turn completed successfully and its transcript is ready
/// to persist. Session creation alone does not prove the prompt was delivered.
/// This never fabricates a missing session or changes another provider/account.
pub fn mark_provider_seen(thread: &mut Value, provider: &str) {
    let account = selected_account(thread, provider).to_owned();
    mark_provider_seen_for_account(thread, provider, &account);
}
pub(crate) fn mark_provider_seen_for_account(thread: &mut Value, provider: &str, account: &str) {
    let count = thread["items"].as_array().map_or(0, Vec::len);
    let current_matches = current_reference(thread, provider)
        .is_some_and(|reference| reference_account(reference) == account);
    let reference = if current_matches {
        let sessions = &mut thread["sessions"];
        if let Some(array) = sessions.as_array_mut() {
            array
                .as_chunks_mut::<2>()
                .0
                .iter_mut()
                .find(|pair| pair[0] == provider)
                .map(|pair| &mut pair[1])
        } else {
            sessions.get_mut(provider)
        }
    } else {
        thread["accountSessions"].get_mut(format!("{provider}/{account}"))
    };
    if let Some(reference) = reference
        && reference.is_object()
        && reference["sessionID"]
            .as_str()
            .is_some_and(|id| !id.is_empty())
    {
        reference["seenItemCount"] = json!(count);
    }
}

pub fn set_provider_session(thread: &mut Value, provider: &str, id: &str) {
    let account = selected_account(thread, provider).to_owned();
    set_provider_session_for_account(thread, provider, &account, id);
}
pub(crate) fn set_provider_session_for_account(
    thread: &mut Value,
    provider: &str,
    account: &str,
    id: &str,
) {
    let current = current_reference(thread, provider).cloned();
    let same_account = current
        .as_ref()
        .is_some_and(|reference| reference_account(reference) == account);
    let mut reference = if same_account {
        current.clone().unwrap()
    } else {
        if !thread["accountSessions"].is_object() {
            thread["accountSessions"] = json!({});
        }
        if let Some(current) = current {
            let key = format!("{provider}/{}", reference_account(&current));
            thread["accountSessions"][key] = current;
        }
        thread["accountSessions"]
            .as_object_mut()
            .unwrap()
            .remove(&format!("{provider}/{account}"))
            .unwrap_or_else(|| json!({"seenItemCount":0}))
    };
    if !reference.is_object() {
        reference = json!({"seenItemCount":0});
    }
    reference["sessionID"] = json!(id);
    if account != "default" {
        reference["accountID"] = json!(account);
    }
    if let Some(array) = thread["sessions"].as_array_mut() {
        if let Some(pair) = array
            .as_chunks_mut::<2>()
            .0
            .iter_mut()
            .find(|pair| pair[0] == provider)
        {
            pair[1] = reference;
        } else {
            array.extend([json!(provider), reference]);
        }
    } else {
        if !thread["sessions"].is_object() {
            thread["sessions"] = json!({});
        }
        thread["sessions"][provider] = reference;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn account_selection_never_resumes_or_overwrites_another_accounts_session() {
        for sessions in [
            json!({"antigravity":{"sessionID":"default-native","seenItemCount":1,"future":42}}),
            json!(["antigravity",{"sessionID":"default-native","seenItemCount":1,"future":42}]),
        ] {
            let mut thread = json!({"selection":{"provider":"antigravity","accountID":"other"},"sessions":sessions,"items":[{},{}]});
            assert_eq!(provider_session(&thread, "antigravity"), None);
            set_provider_session(&mut thread, "antigravity", "other-native");
            mark_provider_seen(&mut thread, "antigravity");
            assert_eq!(
                provider_session(&thread, "antigravity").as_deref(),
                Some("other-native")
            );
            assert_eq!(
                thread["accountSessions"]["antigravity/default"]["future"],
                42
            );
            thread["selection"]["accountID"] = Value::Null;
            assert_eq!(
                provider_session(&thread, "antigravity").as_deref(),
                Some("default-native")
            );
            assert_eq!(provider_seen_count(&thread, "antigravity"), 1);
            set_provider_session(&mut thread, "antigravity", "default-native");
            assert_eq!(
                thread["accountSessions"]["antigravity/other"]["sessionID"],
                "other-native"
            );
            assert_eq!(
                thread["accountSessions"]["antigravity/other"]["seenItemCount"],
                2
            );
            assert_eq!(
                provider_reference(&thread, "antigravity").unwrap()["future"],
                42
            );
        }
    }
    #[test]
    fn captured_profile_session_cannot_attach_to_a_later_saved_account_selection() {
        let mut thread = json!({"selection":{"provider":"codex","accountID":"profile-b"},"sessions":{"codex":{"sessionID":"native-b","accountID":"profile-b","seenItemCount":1,"future":42}},"items":[{},{}]});
        set_provider_session_for_account(&mut thread, "codex", "profile-a", "native-a");
        mark_provider_seen_for_account(&mut thread, "codex", "profile-a");
        assert_eq!(
            provider_session(&thread, "codex").as_deref(),
            Some("native-b")
        );
        assert_eq!(
            thread["accountSessions"]["codex/profile-b"]["seenItemCount"],
            1
        );
        assert_eq!(thread["accountSessions"]["codex/profile-b"]["future"], 42);
        assert_eq!(thread["sessions"]["codex"]["accountID"], "profile-a");
        assert_eq!(thread["sessions"]["codex"]["seenItemCount"], 2);
        assert_eq!(thread["selection"]["accountID"], "profile-b");
    }
    #[test]
    fn session_update_preserves_other_accounts_and_future_fields() {
        let mut v = json!({"items":[],"sessions":["claude",{"sessionID":"a"},"codex",{"sessionID":"b","future":42}],"accountSessions":{"codex/other":{"sessionID":"c"}}});
        assert_eq!(provider_session(&v, "codex").as_deref(), Some("b"));
        set_provider_session(&mut v, "codex", "d");
        assert_eq!(v["sessions"][3]["future"], 42);
        assert_eq!(provider_session(&v, "claude").as_deref(), Some("a"));
        assert_eq!(v["accountSessions"]["codex/other"]["sessionID"], "c");
    }
    #[test]
    fn seen_progress_supports_both_encodings_and_preserves_unknown_fields() {
        for sessions in [
            json!({"claude":{"sessionID":"native","seenItemCount":1,"future":{"keep":true}},"codex":{"sessionID":"other","seenItemCount":2}}),
            json!(["claude",{"sessionID":"native","seenItemCount":1,"future":{"keep":true}},"codex",{"sessionID":"other","seenItemCount":2}]),
        ] {
            let mut thread = json!({"items":[{}, {}, {}],"sessions":sessions,"accountSessions":{"claude/other":{"sessionID":"account","seenItemCount":9}}});
            assert_eq!(provider_seen_count(&thread, "claude"), 1);
            set_provider_session(&mut thread, "claude", "native");
            assert_eq!(
                provider_seen_count(&thread, "claude"),
                1,
                "initialization must not mark a queued prompt seen"
            );
            mark_provider_seen(&mut thread, "claude");
            assert_eq!(provider_seen_count(&thread, "claude"), 3);
            assert_eq!(
                provider_reference(&thread, "claude").unwrap()["future"],
                json!({"keep":true})
            );
            assert_eq!(provider_seen_count(&thread, "codex"), 2);
            assert_eq!(
                thread["accountSessions"]["claude/other"]["seenItemCount"],
                9
            );
            let before = thread.clone();
            mark_provider_seen(&mut thread, "missing");
            assert_eq!(thread, before);
        }
    }
    #[test]
    fn newly_created_session_has_no_seen_items_until_success_is_marked() {
        for sessions in [json!({}), json!([])] {
            let mut thread = json!({"items":[{},{}],"sessions":sessions});
            set_provider_session(&mut thread, "claude", "fresh");
            assert_eq!(provider_seen_count(&thread, "claude"), 0);
            mark_provider_seen(&mut thread, "claude");
            assert_eq!(provider_seen_count(&thread, "claude"), 2);
        }
    }
    #[test]
    fn invalid_or_stale_seen_indices_replay_context_instead_of_skipping_it() {
        for value in [
            Value::Null,
            json!(-1),
            json!("2"),
            json!(3),
            json!(u64::MAX),
        ] {
            let thread = json!({"items":[{},{}],"sessions":{"claude":{"sessionID":"native","seenItemCount":value}}});
            assert_eq!(provider_seen_count(&thread, "claude"), 0);
        }
        for reference in [
            json!("opaque"),
            json!({"seenItemCount":1}),
            json!({"sessionID":"","seenItemCount":1}),
        ] {
            let mut thread = json!({"items":[{},{}],"sessions":["claude",reference]});
            let before = thread.clone();
            assert_eq!(provider_seen_count(&thread, "claude"), 0);
            mark_provider_seen(&mut thread, "claude");
            assert_eq!(thread, before);
        }
    }
    #[test]
    fn default_turn_never_grants_full_access() {
        let v = turn_params(
            "test",
            &Launch {
                executable: "codex".into(),
                cwd: "/tmp".into(),
                session: None,
                prompt: "hello".into(),
                model: None,
            },
            &[],
        );
        assert_eq!(v["approvalPolicy"], "untrusted");
        assert_eq!(v["sandboxPolicy"]["type"], "readOnly");
    }
}
