//! Bounded, read-only `gh pr list/view` service. Parent registers Engine routes.
//! Never add writes or forward arbitrary argv, hostnames, queries or URLs here.
//! Availability reads local Git and runs the fixed `gh auth status` for github.com.
use crate::github_repository::Availability;
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

const MAX_OUTPUT: usize = 3 * 1024 * 1024;
const SUMMARY: &str = "number,title,url,state,isDraft,headRefOid,headRefName,baseRefName";
const DETAIL: &str = "number,title,url,state,isDraft,headRefOid,headRefName,baseRefName,body,author,updatedAt,additions,deletions,changedFiles,mergeable,mergeStateStatus,reviewDecision,reviews,statusCheckRollup";

#[cfg(test)]
#[path = "github_shutdown_tests.rs"]
mod shutdown_tests;

#[derive(Clone)]
pub struct GhRunner {
    executable: PathBuf,
    pub(crate) timeout: Duration,
}
impl GhRunner {
    /// Explicit configured executable. Never resolve a page/agent-provided path.
    pub fn new(executable: PathBuf) -> Result<Self> {
        ensure!(
            executable.is_absolute(),
            "Configure an absolute gh executable"
        );
        let executable = executable
            .canonicalize()
            .context("gh executable unavailable")?;
        ensure!(executable.is_file(), "gh executable is not a file");
        Ok(Self {
            executable,
            timeout: Duration::from_secs(15),
        })
    }
    /// Swift `GitHubCLI.isReady`: whether `gh auth status` succeeds for github.com.
    /// Its output is discarded; only the exit status counts.
    fn signed_in(&self, root: &Path, cancelled: &AtomicBool) -> Result<bool> {
        let args = ["auth", "status", "--hostname", "github.com"].map(String::from);
        match self.capture(root, &args, cancelled) {
            Ok(_) => Ok(true),
            Err(_) if cancelled.load(Ordering::Acquire) => bail!("GitHub operation cancelled"),
            Err(_) => Ok(false),
        }
    }
    #[cfg(windows)]
    pub(crate) fn capture(
        &self,
        root: &Path,
        args: &[String],
        cancelled: &AtomicBool,
    ) -> Result<Vec<u8>> {
        windows::capture(self, root, args, cancelled)
    }
    #[cfg(not(any(unix, windows)))]
    pub(crate) fn capture(&self, _: &Path, _: &[String], _: &AtomicBool) -> Result<Vec<u8>> {
        bail!("Bounded GitHub reads unavailable on this platform")
    }
    #[cfg(unix)]
    pub(crate) fn capture(
        &self,
        root: &Path,
        args: &[String],
        cancelled: &AtomicBool,
    ) -> Result<Vec<u8>> {
        use std::{
            io::Read,
            os::{fd::AsRawFd, unix::process::CommandExt},
            process::{Command, Stdio},
        };
        let child = Command::new(&self.executable)
            .args(args)
            .current_dir(root)
            .env("GH_HOST", "github.com")
            .env("GH_PROMPT_DISABLED", "1")
            .env("GH_PAGER", "cat")
            .env("PAGER", "cat")
            .env("NO_COLOR", "1")
            .env("GH_NO_UPDATE_NOTIFIER", "1")
            .env_remove("GH_DEBUG")
            .env_remove("GH_REPO")
            .env_remove("GH_FORCE_TTY")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .context("Unable to start configured gh")?;
        let mut group = ProcessGroup(child);
        let mut stdout = group.0.stdout.take().context("Missing gh stdout")?;
        let fd = stdout.as_raw_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        ensure!(
            flags >= 0 && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } >= 0,
            "Unable to bound gh output capture"
        );
        let started = Instant::now();
        let mut bytes = Vec::new();
        let mut eof = false;
        loop {
            ensure!(
                !cancelled.load(Ordering::Acquire),
                "GitHub operation cancelled"
            );
            ensure!(
                started.elapsed() < self.timeout,
                "GitHub operation timed out"
            );
            let mut chunk = [0u8; 16384];
            match stdout.read(&mut chunk) {
                Ok(0) => eof = true,
                Ok(n) => {
                    ensure!(bytes.len() + n <= MAX_OUTPUT, "GitHub output exceeds 3 MiB");
                    bytes.extend_from_slice(&chunk[..n]);
                    continue;
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => bail!("Unable to read gh output"),
            }
            if let Some(success) = group.exited()? {
                ensure!(
                    success,
                    "gh read failed; check configured authentication and repository access"
                );
                if eof {
                    return Ok(bytes);
                }
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
#[cfg(unix)]
struct ProcessGroup(std::process::Child);
#[cfg(unix)]
impl ProcessGroup {
    fn exited(&self) -> Result<Option<bool>> {
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                self.0.id(),
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result != 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                return Ok(None);
            }
            bail!("Unable to observe gh process");
        }
        if unsafe { info.si_pid() } == 0 {
            return Ok(None);
        }
        Ok(Some(
            info.si_code == libc::CLD_EXITED && unsafe { info.si_status() } == 0,
        ))
    }
}
#[cfg(unix)]
impl Drop for ProcessGroup {
    fn drop(&mut self) {
        // Keep the unreaped leader until after group kill so PGID cannot be reused.
        unsafe {
            libc::kill(-(self.0.id() as i32), libc::SIGKILL);
        }
        let _ = self.0.wait();
    }
}

#[cfg(windows)]
#[path = "github_api_windows.rs"]
pub(crate) mod windows;
#[derive(Clone)]
struct Root {
    path: PathBuf,
    identity: crate::native_file::Identity,
}
impl Root {
    fn bind(stored: &Path, expected: &Path) -> Result<Self> {
        ensure!(
            stored.is_absolute() && expected.is_absolute(),
            "Expected an absolute stored project root"
        );
        let path = stored
            .canonicalize()
            .context("Stored project root unavailable")?;
        ensure!(
            expected.canonicalize()? == path && path.is_dir(),
            "Project root changed"
        );
        let identity = crate::native_file::path_identity(&path)?;
        Ok(Self { path, identity })
    }
    fn same(&self, other: &Self) -> bool {
        self.path == other.path && self.identity == other.identity
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Involvement {
    All,
    Authored,
    Assigned,
    ReviewRequested,
}
impl Involvement {
    fn parse(value: Option<&Value>) -> Result<Self> {
        match value {
            None => Ok(Self::All),
            Some(Value::String(value)) => match value.as_str() {
                "all" => Ok(Self::All),
                "authored" => Ok(Self::Authored),
                "assigned" => Ok(Self::Assigned),
                "review-requested" => Ok(Self::ReviewRequested),
                _ => bail!("Unsupported PR involvement filter"),
            },
            Some(_) => bail!("Invalid PR involvement filter"),
        }
    }
    fn wire(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::Authored => "authored",
            Self::Assigned => "assigned",
            Self::ReviewRequested => "review-requested",
        }
    }
    fn arguments(self) -> &'static [&'static str] {
        match self {
            Self::All => &[],
            Self::Authored => &["--author", "@me"],
            Self::Assigned => &["--assignee", "@me"],
            Self::ReviewRequested => &["--search", "review-requested:@me"],
        }
    }
}
#[derive(Clone)]
enum Read {
    List {
        state: String,
        limit: usize,
        involvement: Involvement,
    },
    Detail {
        number: u64,
        head: String,
    },
}
impl Read {
    fn arguments(&self, repository: &str) -> Vec<String> {
        let mut args = match self {
            Self::List { state, limit, .. } => vec![
                "pr".into(),
                "list".into(),
                "--state".into(),
                state.clone(),
                "--limit".into(),
                limit.to_string(),
                "--json".into(),
                SUMMARY.into(),
            ],
            Self::Detail { number, .. } => vec![
                "pr".into(),
                "view".into(),
                number.to_string(),
                "--json".into(),
                DETAIL.into(),
            ],
        };
        if let Self::List { involvement, .. } = self {
            args.extend(involvement.arguments().iter().map(|arg| (*arg).into()));
        }
        args.extend(["--repo".into(), format!("github.com/{repository}")]);
        args
    }
}
/// An `owner/name` the read service accepts for `--repo github.com/…`.
pub(crate) fn valid_repository(value: &str) -> bool {
    repository(value).is_ok()
}
fn repository(value: &str) -> Result<()> {
    let parts: Vec<_> = value.split('/').collect();
    ensure!(
        parts.len() == 2
            && parts.iter().all(|s| !s.is_empty()
                && s.len() <= 100
                && !matches!(*s, "." | "..")
                && s.as_bytes()[0].is_ascii_alphanumeric()
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))),
        "Use explicit owner/repository on github.com"
    );
    Ok(())
}
fn full_head(value: &str) -> Result<()> {
    ensure!(
        value.len() == 40 && value.bytes().all(|b| b.is_ascii_hexdigit()),
        "Expected a full 40-character PR head SHA"
    );
    Ok(())
}
struct Operation {
    owner: String,
    root: Root,
    started: Instant,
    cancel: Arc<AtomicBool>,
    receiver: mpsc::Receiver<Value>,
    result: Option<Value>,
}
/// Joined Rust read-worker ownership, independent of retained UI results.
/// Process cleanup errors and the desktop write service are separate owners.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ReadShutdownStatus {
    pub closed: bool,
    pub running: usize,
    pub returned: u64,
    pub panicked: u64,
    pub unclassified: u64,
}
#[derive(Default)]
pub(crate) struct ReadWorkers {
    workers: Vec<(Arc<AtomicBool>, crate::agent::WorkerCompletion)>,
    totals: ReadShutdownStatus,
}
impl ReadWorkers {
    pub(crate) fn require_open(&self) -> Result<()> {
        ensure!(!self.totals.closed, "GitHub reads are shutting down");
        Ok(())
    }
    pub(crate) fn track(&mut self, cancel: Arc<AtomicBool>, worker: std::thread::JoinHandle<()>) {
        self.workers
            .push((cancel, crate::agent::WorkerCompletion::observe(worker)));
    }
    pub(crate) fn request_shutdown(&mut self) {
        self.totals.closed = true;
        for (cancel, _) in &self.workers {
            cancel.store(true, Ordering::Release);
        }
    }
    pub(crate) fn status(&mut self) -> ReadShutdownStatus {
        self.workers.retain(|(_, completion)| {
            use crate::agent::WorkerThreadStatus;
            let counter = match completion.status() {
                WorkerThreadStatus::Running => return true,
                WorkerThreadStatus::Returned => &mut self.totals.returned,
                WorkerThreadStatus::Panicked => &mut self.totals.panicked,
                WorkerThreadStatus::Unclassified => return true,
            };
            *counter = counter.saturating_add(1);
            false
        });
        ReadShutdownStatus {
            running: self.workers.len(),
            unclassified: self.totals.unclassified
                + self
                    .workers
                    .iter()
                    .filter(|(_, w)| w.status() == crate::agent::WorkerThreadStatus::Unclassified)
                    .count() as u64,
            ..self.totals
        }
    }
}
/// At most two executing workers, 32 retained operations, 120-second retention.
/// Completion is collected only by the owning thread with the same stored root.
pub struct GithubService {
    runner: Option<GhRunner>,
    /// Why there is no runner, reported by every read that needs `gh`.
    unavailable: String,
    /// When `gh auth status` last succeeded; Swift trusts it for five minutes.
    signed_in: Arc<Mutex<Option<Instant>>>,
    operations: HashMap<String, Operation>,
    workers: ReadWorkers,
}
impl GithubService {
    pub(crate) fn executable(&self) -> Result<&Path> {
        Ok(&self.runner()?.executable)
    }
    fn runner(&self) -> Result<&GhRunner> {
        self.runner
            .as_ref()
            .with_context(|| self.unavailable.clone())
    }
    pub fn new(runner: GhRunner) -> Self {
        Self::with_runner(Some(runner), String::new())
    }
    /// Without `gh`, availability still reads the folder and reports that the
    /// GitHub CLI is needed; list and detail reads fail with `reason`.
    pub fn without_cli(reason: String) -> Self {
        Self::with_runner(None, reason)
    }
    fn with_runner(runner: Option<GhRunner>, unavailable: String) -> Self {
        Self {
            runner,
            unavailable,
            signed_in: Arc::new(Mutex::new(None)),
            operations: HashMap::new(),
            workers: ReadWorkers::default(),
        }
    }
    fn collect(&mut self) {
        self.workers.status();
        self.operations.retain(|_, op| {
            if op.started.elapsed() >= Duration::from_secs(120) {
                op.cancel.store(true, Ordering::Release);
                return false;
            }
            if op.result.is_none() {
                match op.receiver.try_recv() {
                    Ok(value) => op.result = Some(value),
                    Err(mpsc::TryRecvError::Disconnected) => {
                        op.result =
                            Some(json!({"error":"GitHub worker stopped","code":"worker_stopped"}))
                    }
                    Err(mpsc::TryRecvError::Empty) => {}
                }
            }
            true
        });
    }
    /// Parent must resolve `thread_id` and `stored_root` from its thread store,
    /// never from request JSON. This method performs no repository inference.
    pub fn start(
        &mut self,
        thread_id: &str,
        stored_root: &Path,
        method: &str,
        params: &Value,
    ) -> Result<Value> {
        self.start_with_guard(thread_id, stored_root, method, params, ())
    }
    /// The guard owns Engine background activity until the worker actually exits.
    pub(crate) fn start_with_guard<G: Send + 'static>(
        &mut self,
        thread_id: &str,
        stored_root: &Path,
        method: &str,
        params: &Value,
        activity: G,
    ) -> Result<Value> {
        self.workers.require_open()?;
        uuid::Uuid::parse_str(thread_id)?;
        ensure!(
            params["threadId"].as_str() == Some(thread_id),
            "Thread binding mismatch"
        );
        let root = Root::bind(
            stored_root,
            Path::new(
                params["expectedRoot"]
                    .as_str()
                    .context("expectedRoot required")?,
            ),
        )?;
        let repo = params["repository"]
            .as_str()
            .context("repository required")?
            .to_owned();
        repository(&repo)?;
        let read = match method {
            "github.pr.list" => {
                let state = params
                    .get("state")
                    .map(|v| v.as_str().context("Invalid PR state"))
                    .transpose()?
                    .unwrap_or("open");
                ensure!(
                    ["open", "closed", "merged", "all"].contains(&state),
                    "Unsupported PR state"
                );
                let limit = params
                    .get("limit")
                    .map(|v| v.as_u64().context("Invalid PR limit"))
                    .transpose()?
                    .unwrap_or(30);
                ensure!((1..=50).contains(&limit), "PR limit must be 1–50");
                Read::List {
                    state: state.into(),
                    limit: limit as usize,
                    involvement: Involvement::parse(params.get("involvement"))?,
                }
            }
            "github.pr.read" => {
                let number = params["number"]
                    .as_u64()
                    .filter(|n| *n > 0)
                    .context("Positive PR number required")?;
                let head = params["expectedHead"]
                    .as_str()
                    .context("expectedHead required")?
                    .to_ascii_lowercase();
                full_head(&head)?;
                Read::Detail { number, head }
            }
            _ => bail!("Unsupported read-only GitHub method"),
        };
        let runner = self.runner()?.clone();
        let owner = thread_id.to_owned();
        self.spawn(thread_id, root, activity, move |root, cancel| {
            let bytes = runner.capture(&root.path, &read.arguments(&repo), cancel)?;
            // Detect directory replacement during the read, before accepting output.
            ensure!(
                root.same(&Root::bind(&root.path, &root.path)?),
                "Project root changed"
            );
            snapshot(&bytes, &read, &repo, &owner, &root.path)
        })
    }
    /// Swift `PullRequestService.availability` for the stored root, which the
    /// parent has already found to be a directory: which github.com repository
    /// it lists, or why it can't. Local Git and `gh auth status` run in a worker;
    /// the reply's `expectedRoot` binds the result and every later read.
    pub(crate) fn start_availability<G: Send + 'static>(
        &mut self,
        thread_id: &str,
        stored_root: &Path,
        activity: G,
    ) -> Result<Value> {
        self.workers.require_open()?;
        uuid::Uuid::parse_str(thread_id)?;
        let root = Root::bind(stored_root, stored_root)?;
        let expected = root
            .path
            .to_str()
            .context("Working directory is not UTF-8")?
            .to_owned();
        let runner = self.runner.clone();
        let signed_in = self.signed_in.clone();
        let owner = thread_id.to_owned();
        let bound = expected.clone();
        let mut reply = self.spawn(thread_id, root, activity, move |root, cancel| {
            let mut availability = crate::github_repository::inspect(&root.path);
            ensure!(
                !cancel.load(Ordering::Acquire),
                "GitHub operation cancelled"
            );
            if matches!(availability, Availability::Ready(_))
                && !gh_ready(runner.as_ref(), &signed_in, &root.path, cancel)?
            {
                availability = Availability::NeedsGitHubCli;
            }
            ensure!(
                root.same(&Root::bind(&root.path, &root.path)?),
                "Project root changed"
            );
            let mut value = availability.to_json();
            value["kind"] = json!("availability");
            value["threadId"] = json!(owner);
            value["expectedRoot"] = json!(bound);
            Ok(value)
        })?;
        reply["expectedRoot"] = json!(expected);
        Ok(reply)
    }
    /// Runs `work` in a tracked worker whose one result only `thread_id`, with the
    /// same root, can collect.
    fn spawn<G: Send + 'static>(
        &mut self,
        thread_id: &str,
        root: Root,
        activity: G,
        work: impl FnOnce(&Root, &AtomicBool) -> Result<Value> + Send + 'static,
    ) -> Result<Value> {
        self.collect();
        ensure!(
            self.operations.len() < 32,
            "Collect GitHub results before starting more operations"
        );
        ensure!(
            self.workers.status().running < 2,
            "At most two GitHub reads may execute"
        );
        let id = uuid::Uuid::new_v4().to_string();
        let (sender, receiver) = mpsc::sync_channel(1);
        let cancel = Arc::new(AtomicBool::new(false));
        let worker_cancel = cancel.clone();
        let worker_root = root.clone();
        let worker = std::thread::Builder::new()
            .name("github-read".into())
            .spawn(move || {
                let _activity = activity;
                let value = match work(&worker_root, &worker_cancel) {
                    Ok(value) => value,
                    Err(error) => failure(&error),
                };
                let _ = sender.try_send(value);
            })?;
        self.workers.track(cancel.clone(), worker);
        self.operations.insert(
            id.clone(),
            Operation {
                owner: thread_id.into(),
                root,
                started: Instant::now(),
                cancel,
                receiver,
                result: None,
            },
        );
        Ok(json!({"operationId":id}))
    }
    pub fn request_shutdown(&mut self) {
        self.workers.request_shutdown();
    }
    pub fn shutdown_status(&mut self) -> ReadShutdownStatus {
        self.collect();
        self.workers.status()
    }
    pub fn result(
        &mut self,
        thread_id: &str,
        stored_root: &Path,
        expected_root: &Path,
        operation_id: &str,
    ) -> Result<Value> {
        self.collect();
        let op = self
            .operations
            .get(operation_id)
            .context("GitHub operation not found")?;
        ensure!(
            op.owner == thread_id,
            "GitHub operation belongs to another thread"
        );
        let current = Root::bind(stored_root, expected_root)?;
        ensure!(op.root.same(&current), "Project root changed");
        if op.result.is_none() {
            return Ok(json!({"ready":false,"result":null}));
        }
        let op = self
            .operations
            .remove(operation_id)
            .expect("existing operation");
        Ok(json!({"ready":true,"result":op.result}))
    }
}
impl Drop for GithubService {
    fn drop(&mut self) {
        self.workers.request_shutdown();
        for op in self.operations.values() {
            op.cancel.store(true, Ordering::Release);
        }
    }
}
/// `gh auth status` for github.com, trusted for five minutes once it succeeds, as
/// Swift caches it. A signed-out answer is asked again next time.
fn gh_ready(
    runner: Option<&GhRunner>,
    cache: &Mutex<Option<Instant>>,
    root: &Path,
    cancelled: &AtomicBool,
) -> Result<bool> {
    let Some(runner) = runner else {
        return Ok(false);
    };
    let fresh = |at: &Option<Instant>| at.is_some_and(|at| at.elapsed() < SIGNED_IN_AGE);
    if cache.lock().is_ok_and(|at| fresh(&at)) {
        return Ok(true);
    }
    let ready = runner.signed_in(root, cancelled)?;
    if ready && let Ok(mut at) = cache.lock() {
        *at = Some(Instant::now());
    }
    Ok(ready)
}
const SIGNED_IN_AGE: Duration = Duration::from_secs(300);
fn failure(error: &anyhow::Error) -> Value {
    // Never expose raw child stderr, command output, URLs/configuration or OS errors.
    let message = error.to_string();
    let (code, text) = if message == "PR head changed" {
        ("head_changed", "PR head changed; refresh the list")
    } else if message.contains("timed out") {
        ("timeout", "GitHub read timed out")
    } else if message.contains("exceeds 3 MiB") {
        ("output_limit", "GitHub response exceeds 3 MiB")
    } else {
        ("read_failed", "Unable to read validated GitHub PR metadata")
    };
    json!({"error":text,"code":code})
}

fn nullable_text(value: &Value, limit: usize) -> Result<Value> {
    if value.is_null() {
        return Ok(Value::Null);
    }
    let text = value.as_str().context("Invalid PR text")?;
    ensure!(text.len() <= limit, "PR text exceeds field limit");
    Ok(json!(text))
}
fn actor(value: &Value) -> Result<Value> {
    if value.is_null() {
        return Ok(Value::Null);
    }
    let login = value["login"].as_str().context("Invalid GitHub author")?;
    ensure!(
        !login.is_empty() && login.len() <= 100,
        "Invalid GitHub author"
    );
    Ok(json!({"login":login}))
}
fn safe_link(value: &Value) -> Value {
    value
        .as_str()
        .and_then(|s| url::Url::parse(s).ok())
        .filter(|url| {
            url.scheme() == "https"
                && url.host_str().is_some()
                && url.username().is_empty()
                && url.password().is_none()
        })
        .map(|url| json!(url.as_str()))
        .unwrap_or(Value::Null)
}
fn normalize_pr(raw: &Value, repo: &str, detail: bool) -> Result<Value> {
    let number = raw["number"]
        .as_u64()
        .filter(|n| *n > 0)
        .context("Invalid PR number")?;
    let head = raw["headRefOid"]
        .as_str()
        .context("Missing PR head")?
        .to_ascii_lowercase();
    full_head(&head)?;
    let address = raw["url"].as_str().context("Missing GitHub PR URL")?;
    ensure!(
        address.eq_ignore_ascii_case(&format!("https://github.com/{repo}/pull/{number}")),
        "GitHub PR URL does not match requested repository"
    );
    let state = raw["state"].as_str().context("Missing PR state")?;
    ensure!(
        ["OPEN", "CLOSED", "MERGED"].contains(&state),
        "Invalid PR state"
    );
    let mut pr = json!({"number":number,"url":address,"state":state,"headRefOid":head,
        "isDraft":raw["isDraft"].as_bool().context("Missing draft state")?,
        "title":nullable_text(&raw["title"],4096)?,"headRefName":nullable_text(&raw["headRefName"],1024)?,"baseRefName":nullable_text(&raw["baseRefName"],1024)?,
        "body":null,"author":null,"updatedAt":null,"additions":null,"deletions":null,"changedFiles":null,
        "mergeable":null,"mergeStateStatus":null,"reviewDecision":null,"reviews":[],"statusCheckRollup":[]});
    for field in ["title", "headRefName", "baseRefName"] {
        ensure!(pr[field].is_string(), "Required PR summary field missing");
    }
    if detail {
        pr["body"] = nullable_text(&raw["body"], 128 * 1024)?;
        if pr["body"].is_null() {
            pr["body"] = json!("");
        }
        pr["author"] = actor(&raw["author"])?;
        pr["updatedAt"] = nullable_text(&raw["updatedAt"], 100)?;
        for field in ["additions", "deletions", "changedFiles"] {
            ensure!(
                raw[field].is_null() || raw[field].as_u64().is_some(),
                "Invalid PR count"
            );
            pr[field] = raw[field].clone();
        }
        for field in ["mergeable", "mergeStateStatus", "reviewDecision"] {
            pr[field] = nullable_text(&raw[field], 100)?;
        }
        if !raw["reviews"].is_null() {
            let reviews = raw["reviews"].as_array().context("Invalid reviews")?;
            ensure!(reviews.len() <= 500, "Too many PR reviews");
            let mut selected = Vec::new();
            for review in reviews {
                let id = review["id"].as_str().context("Missing review id")?;
                ensure!(!id.is_empty() && id.len() <= 256, "Invalid review id");
                let state = review["state"].as_str().context("Missing review state")?;
                ensure!(state.len() <= 100, "Invalid review state");
                let commit = if review["commit"].is_null() {
                    Value::Null
                } else {
                    let oid = review["commit"]["oid"]
                        .as_str()
                        .context("Missing review commit")?;
                    full_head(oid)?;
                    json!({"oid":oid.to_ascii_lowercase()})
                };
                selected.push(json!({"id":id,"state":state,"body":nullable_text(&review["body"],128*1024)?.as_str().unwrap_or(""),
                    "author":actor(&review["author"])?,"commit":commit,"submittedAt":nullable_text(&review["submittedAt"],100)?}));
            }
            pr["reviews"] = json!(selected);
        }
        if !raw["statusCheckRollup"].is_null() {
            let checks = raw["statusCheckRollup"]
                .as_array()
                .context("Invalid checks")?;
            ensure!(checks.len() <= 500, "Too many PR checks");
            let mut selected = Vec::new();
            for check in checks {
                ensure!(check.is_object(), "Invalid check entry");
                let mut item = serde_json::Map::new();
                for field in [
                    "__typename",
                    "name",
                    "context",
                    "status",
                    "conclusion",
                    "state",
                ] {
                    if let Some(value) = check.get(field) {
                        item.insert(field.into(), nullable_text(value, 1024)?);
                    }
                }
                for field in ["detailsUrl", "targetUrl"] {
                    if let Some(value) = check.get(field) {
                        item.insert(field.into(), safe_link(value));
                    }
                }
                selected.push(Value::Object(item));
            }
            pr["statusCheckRollup"] = json!(selected);
        }
    }
    // Use the existing offline parser for the shared PR/URL/oid invariant; it
    // expects strings for unknown merge fields, while our UI contract uses null.
    let mut parser_input = pr.clone();
    for field in ["mergeable", "mergeStateStatus", "reviewDecision"] {
        if parser_input[field].is_null() {
            parser_input[field] = json!("");
        }
    }
    crate::workspace_github::parse_snapshot(&serde_json::to_vec(&parser_input)?)?;
    Ok(pr)
}
fn snapshot(bytes: &[u8], read: &Read, repo: &str, thread_id: &str, root: &Path) -> Result<Value> {
    ensure!(bytes.len() <= MAX_OUTPUT, "GitHub output exceeds 3 MiB");
    let value: Value = serde_json::from_slice(bytes).context("Invalid GitHub JSON")?;
    match read {
        Read::List {
            state,
            limit,
            involvement,
        } => {
            let list = value.as_array().context("Expected PR list")?;
            ensure!(list.len() <= *limit, "Too many PR list entries");
            let mut seen = HashSet::new();
            let mut selected = Vec::new();
            for raw in list {
                let pr = normalize_pr(raw, repo, false)?;
                ensure!(
                    seen.insert(pr["number"].as_u64().unwrap()),
                    "Duplicate PR list number"
                );
                selected.push(pr);
            }
            Ok(
                json!({"kind":"list","threadId":thread_id,"expectedRoot":root,"repository":repo,"state":state,"involvement":involvement.wire(),"pullRequests":selected,"limit":limit,"truncated":list.len()==*limit}),
            )
        }
        Read::Detail { number, head } => {
            let pr = normalize_pr(&value, repo, true)?;
            ensure!(pr["number"].as_u64() == Some(*number), "PR number changed");
            ensure!(
                pr["headRefOid"].as_str() == Some(head.as_str()),
                "PR head changed"
            );
            Ok(
                json!({"kind":"read","threadId":thread_id,"expectedRoot":root,"repository":repo,"expectedHead":head,"pullRequest":pr}),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn pr() -> Value {
        json!({"number":7,"title":"Synthetic PR","url":"https://github.com/owner/project/pull/7","state":"OPEN","isDraft":false,"headRefOid":"a".repeat(40),"headRefName":"feature","baseRefName":"main"})
    }
    #[test]
    fn involvement_is_closed_and_emits_only_fixed_cli_flags() {
        for (wire, expected) in [
            ("all", vec![]),
            ("authored", vec!["--author", "@me"]),
            ("assigned", vec!["--assignee", "@me"]),
            ("review-requested", vec!["--search", "review-requested:@me"]),
        ] {
            let involvement = Involvement::parse(Some(&json!(wire))).unwrap();
            let arguments = Read::List {
                state: "open".into(),
                limit: 30,
                involvement,
            }
            .arguments("owner/project");
            let mut full = vec![
                "pr", "list", "--state", "open", "--limit", "30", "--json", SUMMARY,
            ];
            full.extend(expected);
            full.extend(["--repo", "github.com/owner/project"]);
            assert_eq!(arguments, full);
        }
        assert_eq!(Involvement::parse(None).unwrap(), Involvement::All);
        for value in [
            json!(null),
            json!(true),
            json!(["authored"]),
            json!("mine"),
            json!("--author @me"),
            json!("review-requested:@me repo:attacker/repo"),
            json!("authored\n--repo=other/repo"),
        ] {
            assert!(Involvement::parse(Some(&value)).is_err());
        }
    }
    #[test]
    fn strict_repository_url_and_head_binding() {
        for repo in [
            "https://github.com/o/r",
            "o/r/extra",
            "-option/repo",
            "owner/..",
            "owner/repo?token=secret",
        ] {
            assert!(repository(repo).is_err());
        }
        let read = Read::Detail {
            number: 7,
            head: "a".repeat(40),
        };
        let output = snapshot(
            &serde_json::to_vec(&pr()).unwrap(),
            &read,
            "owner/project",
            "thread",
            Path::new("/fixture"),
        )
        .unwrap();
        assert_eq!(output["pullRequest"]["body"], "");
        assert!(
            snapshot(
                &serde_json::to_vec(&pr()).unwrap(),
                &Read::Detail {
                    number: 7,
                    head: "b".repeat(40)
                },
                "owner/project",
                "thread",
                Path::new("/fixture")
            )
            .is_err()
        );
        let mut bad = pr();
        bad["url"] = json!("https://github.com/attacker/project/pull/7");
        assert!(normalize_pr(&bad, "owner/project", true).is_err());
        bad = pr();
        bad["headRefOid"] = json!("abcdef");
        assert!(normalize_pr(&bad, "owner/project", true).is_err());
    }
    #[test]
    fn reviews_and_checks_are_whitelisted_and_nullable() {
        let mut raw = pr();
        raw["body"] = json!("Body **markdown**");
        raw["author"] = json!({"login":"fixture","private":"discard"});
        raw["reviews"] = json!([{"id":"review-id","state":"APPROVED","body":"Reviewed","author":null,"commit":{"oid":"a".repeat(40)},"submittedAt":null}]);
        raw["statusCheckRollup"] = json!([{"__typename":"CheckRun","name":"CI","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"javascript:bad()","private":"discard"}]);
        let value = normalize_pr(&raw, "owner/project", true).unwrap();
        assert_eq!(value["reviews"][0]["commit"]["oid"], "a".repeat(40));
        assert!(value["reviews"][0]["author"].is_null());
        assert!(value["statusCheckRollup"][0]["detailsUrl"].is_null());
        assert!(value["statusCheckRollup"][0].get("private").is_none());
        assert_eq!(value["author"], json!({"login":"fixture"}));
        let list = snapshot(
            &serde_json::to_vec(&vec![raw]).unwrap(),
            &Read::List {
                state: "open".into(),
                limit: 30,
                involvement: Involvement::All,
            },
            "owner/project",
            "thread",
            Path::new("/fixture"),
        )
        .unwrap();
        assert!(list["pullRequests"][0]["body"].is_null());
    }
    #[cfg(unix)]
    fn fake(script: &str) -> (tempfile::TempDir, GhRunner) {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("gh-fixture");
        std::fs::write(&path, format!("#!/bin/sh\n{script}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let runner = GhRunner::new(path).unwrap();
        (dir, runner)
    }
    fn wait(service: &mut GithubService, owner: &str, root: &Path, id: &str) -> Value {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let value = service.result(owner, root, root, id).unwrap();
            if value["ready"] == true {
                return value["result"].clone();
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    #[cfg(unix)]
    #[test]
    fn fake_cli_fixed_argv_service_ownership_and_one_shot_results() {
        let response = serde_json::to_string(&vec![pr()]).unwrap();
        let script = format!(
            "test \"$1\" = pr && test \"$2\" = list && test \"$3\" = --state && test \"$4\" = open && test \"$9\" = --repo && test \"${{10}}\" = github.com/owner/project || exit 5\nprintf '%s' '{response}'"
        );
        let (dir, runner) = fake(&script);
        let root = dir.path().canonicalize().unwrap();
        let mut service = GithubService::new(runner);
        let owner = uuid::Uuid::new_v4().to_string();
        let other = uuid::Uuid::new_v4().to_string();
        let params = json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project"});
        let id = service
            .start(&owner, &root, "github.pr.list", &params)
            .unwrap()["operationId"]
            .as_str()
            .unwrap()
            .to_owned();
        assert!(service.result(&other, &root, &root, &id).is_err());
        let output = wait(&mut service, &owner, &root, &id);
        assert_eq!(output["pullRequests"][0]["number"], 7);
        assert!(service.result(&owner, &root, &root, &id).is_err());
        assert!(
            service
                .start(&owner, &root, "github.pr.merge", &params)
                .is_err()
        );
    }
    #[cfg(unix)]
    #[test]
    fn fake_cli_timeout_output_limit_and_private_stderr() {
        let cancelled = AtomicBool::new(false);
        let (dir, mut runner) = fake("sleep 5");
        runner.timeout = Duration::from_millis(60);
        let started = Instant::now();
        assert!(
            runner
                .capture(dir.path(), &[], &cancelled)
                .unwrap_err()
                .to_string()
                .contains("timed out")
        );
        assert!(started.elapsed() < Duration::from_secs(2));
        // A finite shell-builtin producer avoids dependence on an external
        // `yes` executable/descendant while still exercising the real pipe cap.
        let chunk = "x".repeat(4096);
        let (dir, runner) = fake(&format!(
            "chunk='{chunk}'\ni=0\nwhile [ \"$i\" -lt 769 ]; do printf '%s' \"$chunk\"; i=$((i + 1)); done"
        ));
        let error = runner
            .capture(dir.path(), &[], &cancelled)
            .expect_err("Oversized fixture output must be rejected");
        assert!(
            error.to_string().contains("exceeds 3 MiB"),
            "Expected the output-limit rejection, got: {error:#}"
        );
        let (dir, runner) = fake("printf private-sentinel >&2; exit 3");
        let error = runner.capture(dir.path(), &[], &cancelled).unwrap_err();
        assert!(!error.to_string().contains("private-sentinel"));
        cancelled.store(true, Ordering::Release);
        assert!(runner.capture(dir.path(), &[], &cancelled).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn pending_bounds_root_replacement_and_detail_head_change() {
        let (dir, runner) = fake("sleep 1; printf '[]'");
        let root = dir.path().canonicalize().unwrap();
        let mut service = GithubService::new(runner);
        let owner = uuid::Uuid::new_v4().to_string();
        let params = json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project"});
        for _ in 0..2 {
            service
                .start(&owner, &root, "github.pr.list", &params)
                .unwrap();
        }
        assert!(
            service
                .start(&owner, &root, "github.pr.list", &params)
                .is_err()
        );
        let wrong = tempfile::tempdir().unwrap();
        assert!(
            service
                .start(&owner, wrong.path(), "github.pr.list", &params)
                .is_err()
        );
        drop(service);
        let response = serde_json::to_string(&pr()).unwrap();
        let (dir, runner) = fake(&format!("printf '%s' '{response}'"));
        let root = dir.path().canonicalize().unwrap();
        let mut service = GithubService::new(runner);
        let params = json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project","number":7,"expectedHead":"b".repeat(40)});
        let id = service
            .start(&owner, &root, "github.pr.read", &params)
            .unwrap()["operationId"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(
            wait(&mut service, &owner, &root, &id)["code"],
            "head_changed"
        );
    }
    fn availability(service: &mut GithubService, owner: &str, root: &Path) -> Value {
        let reply = service.start_availability(owner, root, ()).unwrap();
        assert_eq!(reply["expectedRoot"], root.to_str().unwrap());
        wait(service, owner, root, reply["operationId"].as_str().unwrap())
    }
    #[cfg(unix)]
    #[test]
    fn availability_asks_gh_auth_status_last_and_remembers_a_sign_in() {
        let (dir, runner) = fake("printf '%s\\n' \"$@\" >> argv.txt\ntest -f signed-in");
        let root = dir.path().canonicalize().unwrap();
        let mut service = GithubService::new(runner);
        let owner = uuid::Uuid::new_v4().to_string();
        // Git decides first; gh is never asked about a folder it can't list.
        assert_eq!(
            availability(&mut service, &owner, &root)["state"],
            "notRepository"
        );
        assert!(!root.join("argv.txt").exists());
        crate::workspace::git(&root, &["init", "-q"]).unwrap();
        let remote = [
            "remote",
            "add",
            "origin",
            "https://github.com/owner/project.git",
        ];
        crate::workspace::git(&root, &remote).unwrap();
        let result = availability(&mut service, &owner, &root);
        assert_eq!(result["state"], "needsGitHubCli");
        assert_eq!(
            std::fs::read_to_string(root.join("argv.txt")).unwrap(),
            "auth\nstatus\n--hostname\ngithub.com\n"
        );
        std::fs::write(root.join("signed-in"), "").unwrap();
        let result = availability(&mut service, &owner, &root);
        assert_eq!(
            result,
            json!({"kind":"availability","threadId":owner,"expectedRoot":root,
                "state":"ready","repository":"owner/project"})
        );
        // A sign-in is trusted for five minutes without running gh again.
        std::fs::remove_file(root.join("argv.txt")).unwrap();
        assert_eq!(availability(&mut service, &owner, &root)["state"], "ready");
        assert!(!root.join("argv.txt").exists());
        // Only the owning thread collects it.
        let reply = service.start_availability(&owner, &root, ()).unwrap();
        let other = uuid::Uuid::new_v4().to_string();
        let id = reply["operationId"].as_str().unwrap();
        assert!(service.result(&other, &root, &root, id).is_err());
    }
    #[test]
    fn availability_without_gh_still_reads_git_and_says_gh_is_needed() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap();
        let reason = "GitHub CLI not found; install gh";
        let mut service = GithubService::without_cli(reason.into());
        let owner = uuid::Uuid::new_v4().to_string();
        assert_eq!(
            availability(&mut service, &owner, &root)["state"],
            "notRepository"
        );
        crate::workspace::git(&root, &["init", "-q"]).unwrap();
        assert_eq!(
            availability(&mut service, &owner, &root)["state"],
            "noRemote"
        );
        let remote = [
            "remote",
            "add",
            "origin",
            "git@gitlab.com:group/project.git",
        ];
        crate::workspace::git(&root, &remote).unwrap();
        assert_eq!(
            availability(&mut service, &owner, &root),
            json!({"kind":"availability","threadId":owner,"expectedRoot":root,
                "state":"unsupportedHost","host":"GitLab","selfHosted":false})
        );
        crate::workspace::git(
            &root,
            &["remote", "set-url", "origin", "git@github.com:o/p.git"],
        )
        .unwrap();
        assert_eq!(
            availability(&mut service, &owner, &root)["state"],
            "needsGitHubCli"
        );
        let params = json!({"threadId":owner,"expectedRoot":root,"repository":"o/p"});
        let error = service
            .start(&owner, &root, "github.pr.list", &params)
            .unwrap_err();
        assert_eq!(error.to_string(), reason);
        assert_eq!(service.executable().unwrap_err().to_string(), reason);
        let missing = root.join("missing");
        assert!(service.start_availability(&owner, &missing, ()).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn result_rejects_replaced_root_and_expired_retained_operations() {
        let (dir, runner) = fake("printf '[]'");
        let root = dir.path().join("project");
        std::fs::create_dir(&root).unwrap();
        let owner = uuid::Uuid::new_v4().to_string();
        let mut service = GithubService::new(runner);
        let params = json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project"});
        let id = service
            .start(&owner, &root, "github.pr.list", &params)
            .unwrap()["operationId"]
            .as_str()
            .unwrap()
            .to_owned();
        let old = dir.path().join("old-project");
        std::fs::rename(&root, &old).unwrap();
        std::fs::create_dir(&root).unwrap();
        assert!(service.result(&owner, &root, &root, &id).is_err());
        service.operations.get_mut(&id).unwrap().started =
            Instant::now() - Duration::from_secs(121);
        service.collect();
        assert!(service.operations.is_empty());
    }
    #[test]
    fn response_limits_duplicates_and_urls_fail_closed() {
        let raw = pr();
        let list = serde_json::to_vec(&vec![raw.clone(), raw.clone()]).unwrap();
        assert!(
            snapshot(
                &list,
                &Read::List {
                    state: "open".into(),
                    limit: 30,
                    involvement: Involvement::All,
                },
                "owner/project",
                "thread",
                Path::new("/fixture")
            )
            .is_err()
        );
        assert!(
            snapshot(
                &list,
                &Read::List {
                    state: "open".into(),
                    limit: 1,
                    involvement: Involvement::All,
                },
                "owner/project",
                "thread",
                Path::new("/fixture")
            )
            .is_err()
        );
        for address in [
            "https://github.com/owner/project/pull/7?token=x",
            "https://user:secret@github.com/owner/project/pull/7",
            "https://github.com/owner/project/pull/7#fragment",
            "http://github.com/owner/project/pull/7",
        ] {
            let mut bad = raw.clone();
            bad["url"] = json!(address);
            assert!(normalize_pr(&bad, "owner/project", false).is_err());
        }
        let mut bad = raw;
        bad["body"] = json!("x".repeat(128 * 1024 + 1));
        assert!(normalize_pr(&bad, "owner/project", true).is_err());
        assert_eq!(
            failure(&anyhow::anyhow!("private output sentinel")),
            json!({"error":"Unable to read validated GitHub PR metadata","code":"read_failed"})
        );
    }
}

#[cfg(test)]
mod native_root_tests {
    use super::*;
    #[test]
    fn replaced_directory_at_same_path_never_reuses_github_read_context() {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("project");
        std::fs::create_dir(&path).unwrap();
        let before = Root::bind(&path, &path).unwrap();
        std::fs::rename(&path, temporary.path().join("old")).unwrap();
        std::fs::create_dir(&path).unwrap();
        let after = Root::bind(&path, &path).unwrap();
        assert!(!before.same(&after));
    }
}
