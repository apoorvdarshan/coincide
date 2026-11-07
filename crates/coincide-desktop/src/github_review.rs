//! Native GitHub PR metadata panel with a separate explicit action surface. Parent mounts this entity and calls
//! set_context with the selected conversation and whether the panel shows. The Engine finds the repository from
//! the conversation's stored folder and says why when it can't (Swift PullRequestService.availability).
//! All Engine calls run in one background worker, never GPUI render.
use crate::worker_owner::{Admission, ShutdownStatus as ReadShutdownStatus, WorkerOwner};
use anyhow::{Context as _, Result, bail, ensure};
use coincide_core::api::SharedEngine;
use gpui_kit::{
    assets::IconName,
    base::Disableable,
    component::{ActiveTheme, Icon, Sizable, button::*, spinner::Spinner},
    prelude::FluentBuilder,
    *,
};
use serde_json::{Value, json};
use std::{
    path::Path,
    sync::{Mutex, mpsc},
    time::{Duration, Instant},
};

const LIMIT: usize = 30;
const STATES: &[&str] = &["open", "closed", "merged", "all"];
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
enum Involvement {
    #[default]
    All,
    Authored,
    Assigned,
    ReviewRequested,
}
impl Involvement {
    const ALL: [Self; 4] = [
        Self::All,
        Self::Authored,
        Self::Assigned,
        Self::ReviewRequested,
    ];
    fn wire(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::Authored => "authored",
            Self::Assigned => "assigned",
            Self::ReviewRequested => "review-requested",
        }
    }
    fn label(self) -> &'static str {
        match self {
            Self::All => "All PRs",
            Self::Authored => "Authored by me",
            Self::Assigned => "Assigned to me",
            Self::ReviewRequested => "Review requested",
        }
    }
}
/// The selected conversation as the window has it. `root_hint` is its stored
/// worktree or project folder, so a moved folder is looked at again.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selection {
    pub thread: String,
    pub project: String,
    pub root_hint: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Binding {
    thread: String,
    root: String,
    repository: String,
    involvement: Involvement,
}
/// What Swift shows in place of the list, with its wording.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Unavailable {
    NoThread,
    FolderNotFound(String),
    NotRepository,
    NoRemote,
    /// `self_hosted` hosts are ones Swift leaves to `gh`; the read service lists github.com only.
    UnsupportedHost {
        host: String,
        self_hosted: bool,
    },
    NeedsGitHubCli,
    /// The list failed with none shown behind it.
    Failed(String),
}
impl Unavailable {
    fn icon(&self) -> IconName {
        match self {
            Self::NoThread | Self::UnsupportedHost { .. } => IconName::Github,
            Self::FolderNotFound(_) => IconName::FolderClosed,
            Self::NotRepository => IconName::HardDrive,
            Self::NoRemote => IconName::Globe,
            Self::NeedsGitHubCli => IconName::SquareTerminal,
            Self::Failed(_) => IconName::TriangleAlert,
        }
    }
    fn title(&self) -> &'static str {
        match self {
            Self::NoThread => "No Thread Selected",
            Self::FolderNotFound(_) => "Folder Not Found",
            Self::NotRepository => "Not a Git Repository",
            Self::NoRemote => "No Remote",
            Self::UnsupportedHost { .. } => "Pull Requests Need GitHub",
            Self::NeedsGitHubCli => "GitHub CLI Needed",
            Self::Failed(_) => "Couldn’t Load the Pull Requests",
        }
    }
    fn text(&self) -> String {
        match self {
            Self::NoThread => "Select a thread to see its repository’s pull requests.".into(),
            Self::FolderNotFound(path) => path.clone(),
            Self::NotRepository => "Pull requests need a Git repository on GitHub.".into(),
            Self::NoRemote => {
                "Push this repository to GitHub to see its pull requests here.".into()
            }
            Self::UnsupportedHost {
                host,
                self_hosted: false,
            } => format!("This repository is on {host}. Coincide lists pull requests from GitHub."),
            Self::UnsupportedHost {
                host,
                self_hosted: true,
            } => format!(
                "This repository is on {host}. Coincide lists pull requests from github.com."
            ),
            Self::NeedsGitHubCli => "Install the GitHub CLI (gh) and run “gh auth login” to see this repository’s pull requests.".into(),
            Self::Failed(error) => error.clone(),
        }
    }
}
/// Swift's empty list wording for the filter shown.
fn empty_list(state: &str, involvement: Involvement) -> (&'static str, &'static str) {
    match (involvement, state) {
        (Involvement::Authored, _) => (
            "No Pull Requests of Yours",
            "Pull requests you open in this repository show here.",
        ),
        (Involvement::ReviewRequested, _) => (
            "No Reviews Requested",
            "Pull requests waiting on your review show here.",
        ),
        (Involvement::Assigned, _) => (
            "No Pull Requests Assigned to You",
            "Pull requests assigned to you in this repository show here.",
        ),
        (Involvement::All, "closed") => (
            "No Closed Pull Requests",
            "Closed pull requests of this repository show here.",
        ),
        (Involvement::All, "merged") => (
            "No Merged Pull Requests",
            "Merged pull requests of this repository show here.",
        ),
        (Involvement::All, "all") => (
            "No Pull Requests",
            "Pull requests of this repository show here.",
        ),
        (Involvement::All, _) => (
            "No Open Pull Requests",
            "Open pull requests of this repository show here.",
        ),
    }
}
/// One load of the panel: the repository, its list and the open pull request.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Load {
    thread: String,
    state: String,
    involvement: Involvement,
    /// The open pull request, read again under the new binding.
    open: Option<(u64, String)>,
}
enum Loaded {
    Unavailable(Unavailable),
    List {
        binding: Binding,
        list: Value,
        detail: Option<(Request, Result<Value>)>,
    },
}
/// Swift reloads at most this often when the panel shows again or the app comes back.
const FRESH: Duration = Duration::from_secs(30);
#[derive(Clone, Debug, PartialEq, Eq)]
enum View {
    List(String),
    Detail { number: u64, head: String },
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Request {
    binding: Binding,
    view: View,
}
fn head(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|b| b.is_ascii_hexdigit())
}
fn repository(value: &str) -> bool {
    let pieces = value.split('/').collect::<Vec<_>>();
    pieces.len() == 2
        && pieces.iter().all(|s| {
            !s.is_empty()
                && s.len() <= 100
                && *s != "."
                && *s != ".."
                && !s.starts_with('-')
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        })
}
fn validate_pr(pr: &Value, repo: &str) -> Result<()> {
    let number = pr["number"]
        .as_u64()
        .filter(|n| *n > 0)
        .context("Invalid PR number")?;
    for key in [
        "title",
        "url",
        "state",
        "headRefOid",
        "headRefName",
        "baseRefName",
    ] {
        ensure!(pr[key].is_string(), "Invalid PR {key}");
    }
    ensure!(
        pr["isDraft"].is_boolean() && head(pr["headRefOid"].as_str().unwrap_or("")),
        "Invalid PR head or draft state"
    );
    let expected = format!("https://github.com/{repo}/pull/{number}");
    ensure!(
        pr["url"]
            .as_str()
            .is_some_and(|url| url.eq_ignore_ascii_case(&expected)),
        "PR URL does not match repository/number"
    );
    Ok(())
}
fn validate_payload(request: &Request, payload: &Value) -> Result<()> {
    ensure!(
        payload["threadId"] == request.binding.thread
            && payload["expectedRoot"] == request.binding.root
            && payload["repository"] == request.binding.repository,
        "PR response belongs to another thread/root/repository"
    );
    match &request.view {
        View::List(state) => {
            ensure!(
                payload["state"] == *state
                    && payload["involvement"] == request.binding.involvement.wire(),
                "PR response belongs to another state/involvement filter"
            );
            ensure!(
                payload["kind"] == "list"
                    && payload["limit"].as_u64() == Some(LIMIT as u64)
                    && payload["truncated"].is_boolean(),
                "Invalid PR list envelope"
            );
            let rows = payload["pullRequests"]
                .as_array()
                .context("Missing PR list")?;
            ensure!(rows.len() <= LIMIT, "PR list exceeds requested limit");
            let mut numbers = std::collections::HashSet::new();
            for pr in rows {
                validate_pr(pr, &request.binding.repository)?;
                ensure!(
                    numbers.insert(pr["number"].as_u64()),
                    "Duplicate PR in list"
                );
            }
        }
        View::Detail { number, head } => {
            ensure!(
                payload["kind"] == "read" && payload["expectedHead"] == *head,
                "PR detail head binding changed"
            );
            let pr = &payload["pullRequest"];
            validate_pr(pr, &request.binding.repository)?;
            ensure!(
                pr["number"].as_u64() == Some(*number) && pr["headRefOid"] == *head,
                "PR head changed; refresh the list"
            );
            ensure!(
                pr["body"].is_string()
                    && pr["reviews"].is_array()
                    && pr["statusCheckRollup"].is_array(),
                "Incomplete PR detail"
            );
        }
    }
    Ok(())
}
fn fetch(api: &mut impl FnMut(&str, Value) -> Result<Value>, request: &Request) -> Result<Value> {
    let b = &request.binding;
    ensure!(
        !b.thread.is_empty()
            && b.thread.len() <= 128
            && Path::new(&b.root).is_absolute()
            && repository(&b.repository),
        "Choose a valid thread/root and owner/repository"
    );
    let mut params = json!({"threadId":b.thread,"expectedRoot":b.root,"repository":b.repository});
    let method = match &request.view {
        View::List(state) => {
            ensure!(STATES.contains(&state.as_str()), "Invalid PR state filter");
            params["state"] = json!(state);
            params["involvement"] = json!(b.involvement.wire());
            params["limit"] = json!(LIMIT);
            "github.pr.list"
        }
        View::Detail {
            number,
            head: expected,
        } => {
            ensure!(*number > 0 && head(expected), "Invalid PR number/head");
            params["number"] = json!(number);
            params["expectedHead"] = json!(expected);
            "github.pr.read"
        }
    };
    let start = api(method, params)?;
    let id = start["operationId"]
        .as_str()
        .context("Missing GitHub operation ID")?;
    let payload = wait_result(api, &b.thread, &b.root, id)?;
    validate_payload(request, &payload)?;
    Ok(payload)
}
/// Polls one operation's result, which only its thread and root collect.
fn wait_result(
    api: &mut impl FnMut(&str, Value) -> Result<Value>,
    thread: &str,
    root: &str,
    id: &str,
) -> Result<Value> {
    let deadline = Instant::now() + Duration::from_secs(110);
    loop {
        let reply = api(
            "github.result",
            json!({"threadId":thread,"expectedRoot":root,"operationId":id}),
        )?;
        if reply["ready"] == true {
            let payload = reply["result"].clone();
            if let Some(error) = payload["error"].as_str() {
                bail!(
                    "{}: {}",
                    payload["code"].as_str().unwrap_or("github_error"),
                    error
                );
            }
            return Ok(payload);
        }
        ensure!(reply["ready"] == false, "Invalid GitHub polling response");
        ensure!(
            Instant::now() < deadline,
            "GitHub read timed out; retry with Refresh"
        );
        std::thread::sleep(Duration::from_millis(80));
    }
}
/// The root and repository the Engine found for `thread`'s stored folder, or the
/// state Swift shows instead. A folder that is gone answers at once.
fn availability(
    api: &mut impl FnMut(&str, Value) -> Result<Value>,
    thread: &str,
) -> Result<std::result::Result<(String, String), Unavailable>> {
    let start = api("github.pr.availability", json!({"threadId":thread}))?;
    let (payload, root) = if start["ready"] == true {
        (start["result"].clone(), None)
    } else {
        let id = start["operationId"]
            .as_str()
            .context("Missing GitHub operation ID")?;
        let root = start["expectedRoot"]
            .as_str()
            .filter(|root| Path::new(root).is_absolute())
            .context("Missing repository folder")?;
        (wait_result(api, thread, root, id)?, Some(root.to_owned()))
    };
    ensure!(
        payload["kind"] == "availability" && payload["threadId"] == thread,
        "Repository check belongs to another thread"
    );
    let state = payload["state"].as_str().unwrap_or("");
    if state == "ready" || root.is_some() {
        ensure!(
            root.is_some() && payload["expectedRoot"].as_str() == root.as_deref(),
            "Repository check belongs to another folder"
        );
    }
    Ok(Err(match state {
        "ready" => {
            let repository = payload["repository"]
                .as_str()
                .filter(|repo| self::repository(repo))
                .context("Invalid GitHub repository")?;
            return Ok(Ok((root.unwrap_or_default(), repository.to_owned())));
        }
        "noFolder" => Unavailable::NoThread,
        "folderNotFound" => Unavailable::FolderNotFound(
            payload["path"]
                .as_str()
                .context("Missing folder path")?
                .to_owned(),
        ),
        "notRepository" => Unavailable::NotRepository,
        "noRemote" => Unavailable::NoRemote,
        "unsupportedHost" => Unavailable::UnsupportedHost {
            host: payload["host"]
                .as_str()
                .filter(|host| !host.is_empty() && host.len() <= 255)
                .context("Missing host")?
                .to_owned(),
            self_hosted: payload["selfHosted"] == true,
        },
        "needsGitHubCli" => Unavailable::NeedsGitHubCli,
        _ => bail!("Invalid repository check"),
    }))
}
/// Swift reload: the repository, then its list, then the open pull request.
fn load(api: &mut impl FnMut(&str, Value) -> Result<Value>, load: &Load) -> Result<Loaded> {
    let (root, repository) = match availability(api, &load.thread)? {
        Ok(found) => found,
        Err(state) => return Ok(Loaded::Unavailable(state)),
    };
    let binding = Binding {
        thread: load.thread.clone(),
        root,
        repository,
        involvement: load.involvement,
    };
    let list = fetch(
        api,
        &Request {
            binding: binding.clone(),
            view: View::List(load.state.clone()),
        },
    )?;
    let detail = load.open.as_ref().map(|(number, head)| {
        // Swift reads the open pull request by number, so it follows a new head
        // the list shows; the read stays bound to one exact head.
        let head = list["pullRequests"]
            .as_array()
            .and_then(|rows| {
                rows.iter()
                    .find(|pr| pr["number"].as_u64() == Some(*number))
            })
            .and_then(|pr| pr["headRefOid"].as_str())
            .unwrap_or(head)
            .to_owned();
        let request = Request {
            binding: binding.clone(),
            view: View::Detail {
                number: *number,
                head,
            },
        };
        let result = fetch(api, &request);
        (request, result)
    });
    Ok(Loaded::List {
        binding,
        list,
        detail,
    })
}
/// Engine contention must remain cancellable after the UI closes. This is a
/// read admission only; the Engine still owns and drains any operation started.
fn call_admitted(
    engine: &SharedEngine,
    method: &str,
    params: Value,
    admission: &Admission,
) -> Result<Value> {
    with_admitted_lock(
        engine,
        admission,
        Instant::now() + Duration::from_secs(3),
        |engine| {
            let response = engine.dispatch(json!({"method":method,"params":params}));
            if let Some(error) = response.get("error") {
                bail!("{}", error["message"].as_str().unwrap_or("Command failed"));
            }
            Ok(response["result"].clone())
        },
    )
}
fn with_admitted_lock<T, R>(
    state: &Mutex<T>,
    admission: &Admission,
    deadline: Instant,
    work: impl FnOnce(&mut T) -> Result<R>,
) -> Result<R> {
    loop {
        ensure!(admission.allowed(), "GitHub UI read admissions are closed");
        ensure!(
            Instant::now() < deadline,
            "GitHub Engine is busy; retry with Refresh"
        );
        match state.try_lock() {
            Ok(mut state) => {
                ensure!(admission.allowed(), "GitHub UI read admissions are closed");
                return work(&mut state);
            }
            Err(std::sync::TryLockError::WouldBlock) => {
                std::thread::sleep(Duration::from_millis(10))
            }
            Err(_) => bail!("GitHub Engine is unavailable"),
        }
    }
}
fn load_admitted(
    api: &mut impl FnMut(&str, Value) -> Result<Value>,
    request: &Load,
    admission: &Admission,
) -> Result<Loaded> {
    load(
        &mut |method, params| {
            ensure!(admission.allowed(), "GitHub UI read admissions are closed");
            api(method, params)
        },
        request,
    )
}
/// A failure's message without the Engine's `code: ` prefix.
fn describe(error: &anyhow::Error) -> String {
    let message = error.to_string();
    match message.split_once(": ") {
        Some((code, rest))
            if !code.is_empty() && code.bytes().all(|b| b.is_ascii_lowercase() || b == b'_') =>
        {
            rest.to_owned()
        }
        _ => message,
    }
}
fn fetch_admitted(
    api: &mut impl FnMut(&str, Value) -> Result<Value>,
    request: &Request,
    admission: &Admission,
) -> Result<Value> {
    fetch(
        &mut |method, params| {
            ensure!(admission.allowed(), "GitHub UI read admissions are closed");
            api(method, params)
        },
        request,
    )
}
fn current(generation: u64, request: &Request, active: Option<&(u64, Request)>) -> bool {
    active.is_some_and(|(g, r)| *g == generation && r == request)
}
fn text(value: &Value, key: &str) -> String {
    value[key]
        .as_str()
        .unwrap_or("Unknown / not supplied")
        .to_owned()
}
fn excerpt(value: &str, max: usize) -> String {
    let mut s = value.chars().take(max).collect::<String>();
    if value.chars().count() > max {
        s.push_str("… [display truncated]");
    }
    s
}

fn discard_completions<T>(receiver: &mpsc::Receiver<T>) -> bool {
    let mut discarded = false;
    for result in receiver.try_iter() {
        drop(result);
        discarded = true;
    }
    discarded
}
pub struct ReviewShutdownStatus {
    pub read: ReadShutdownStatus,
    pub actions: Option<coincide_core::github_write::WriteShutdownStatus>,
    pub writes: Option<crate::github_write_transport::NativeWriteShutdownStatus>,
}
pub struct GitHubReviewPanel {
    engine: SharedEngine,
    selection: Option<Selection>,
    visible: bool,
    /// The repository and folder the shown list was read from.
    binding: Option<Binding>,
    unavailable: Option<Unavailable>,
    loading: Option<(u64, Load)>,
    /// A load waits for the panel to show or the running read to finish.
    needs_load: bool,
    loaded_at: Option<Instant>,
    state: String,
    involvement: Involvement,
    generation: u64,
    active: Option<(u64, Request)>,
    busy: bool,
    workers: WorkerOwner,
    list: Vec<Value>,
    truncated: bool,
    selected: Option<(u64, String)>,
    detail: Option<Value>,
    notice: String,
    tx: mpsc::Sender<(u64, Request, Result<Value>)>,
    rx: mpsc::Receiver<(u64, Request, Result<Value>)>,
    load_tx: mpsc::Sender<(u64, Load, Result<Loaded>)>,
    load_rx: mpsc::Receiver<(u64, Load, Result<Loaded>)>,
    _poll: Option<Task<()>>,
    actions: Option<Entity<crate::github_actions::GitHubActions>>,
    writes: Option<crate::github_write_transport::NativeWrites>,
    write_status: Option<crate::github_write_transport::Status>,
    actions_open: bool,
    scroll: ScrollHandle,
}
impl GitHubReviewPanel {
    pub fn new(engine: SharedEngine, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (tx, rx) = mpsc::channel();
        let (load_tx, load_rx) = mpsc::channel();
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
                if this.update(cx, |this, cx| this.poll(cx)).is_err() {
                    break;
                }
            }
        });
        Self {
            engine,
            selection: None,
            visible: false,
            binding: None,
            unavailable: Some(Unavailable::NoThread),
            loading: None,
            needs_load: false,
            loaded_at: None,
            state: "open".into(),
            involvement: Involvement::All,
            generation: 0,
            active: None,
            busy: false,
            workers: WorkerOwner::default(),
            list: Vec::new(),
            truncated: false,
            selected: None,
            detail: None,
            notice: String::new(),
            tx,
            rx,
            load_tx,
            load_rx,
            _poll: Some(poll),
            actions: None,
            writes: None,
            write_status: None,
            actions_open: false,
            scroll: ScrollHandle::new(),
        }
    }
    pub fn attach_actions(
        &mut self,
        actions: Entity<crate::github_actions::GitHubActions>,
        writes: crate::github_write_transport::NativeWrites,
        cx: &mut Context<Self>,
    ) {
        self.actions = Some(actions);
        self.writes = Some(writes);
        if self.workers.closed() {
            self.request_shutdown(cx);
        } else {
            self.sync_action_scope(cx);
        }
    }
    fn invalidate_actions(&mut self, cx: &mut Context<Self>) {
        self.actions_open = false;
        if let Some(actions) = &self.actions {
            actions.update(cx, |actions, cx| {
                actions.set_scope(None, cx);
                actions.invalidate(cx);
            });
        }
    }
    fn validated_loaded_scope(&self, _cx: &App) -> Option<crate::github_actions::ActionScope> {
        if self.workers.closed() {
            return None;
        }
        let (_, request) = self.active.as_ref()?;
        let pr = self.detail.as_ref()?;
        let View::Detail { number, head } = &request.view else {
            return None;
        };
        if self.busy
            || self.selection.as_ref().map(|s| &s.thread) != Some(&request.binding.thread)
            || self.binding.as_ref() != Some(&request.binding)
            || self.involvement != request.binding.involvement
            || pr["number"].as_u64() != Some(*number)
            || pr["headRefOid"] != *head
        {
            return None;
        }
        crate::github_actions::ActionScope::new(
            request.binding.thread.clone(),
            request.binding.root.clone(),
            request.binding.repository.clone(),
            *number,
            head.clone(),
        )
        .ok()
    }
    /// Exact currently loaded detail only; no reads, network or focus changes.
    pub fn loaded_pr_scope(&self, cx: &App) -> Option<(String, u64, String)> {
        self.validated_loaded_scope(cx)?;
        let (_, request) = self.active.as_ref()?;
        let View::Detail { number, head } = &request.view else {
            return None;
        };
        Some((request.binding.repository.clone(), *number, head.clone()))
    }
    fn sync_action_scope(&mut self, cx: &mut Context<Self>) {
        if self.workers.closed() {
            return;
        }
        let scope = self.validated_loaded_scope(cx);
        if let Some(actions) = &self.actions {
            actions.update(cx, |actions, cx| actions.set_scope(scope, cx));
        }
    }
    /// The selected conversation and whether the panel shows. No calls or
    /// filesystem I/O run here. Another conversation invalidates the prepared
    /// actions; one of the same project keeps its list and open pull request
    /// showing while they are read again for it, as Swift does.
    pub fn set_context(
        &mut self,
        selection: Option<Selection>,
        visible: bool,
        cx: &mut Context<Self>,
    ) {
        if self.workers.closed() || (self.selection == selection && self.visible == visible) {
            return;
        }
        let appeared = visible && !self.visible;
        self.visible = visible;
        if self.selection != selection {
            let same_project = matches!(
                (&self.selection, &selection),
                (Some(old), Some(new)) if old.project == new.project
            );
            self.selection = selection;
            self.invalidate_actions(cx);
            self.generation = self.generation.wrapping_add(1);
            self.active = None;
            self.loading = None;
            self.binding = None;
            self.loaded_at = None;
            self.needs_load = true;
            if !same_project {
                self.close_list();
            }
        }
        if self.needs_load || (appeared && !self.fresh()) {
            self.load(cx);
        }
        cx.notify();
    }
    /// Swift applicationDidBecomeActive: the app coming back picks up what
    /// changed on GitHub meanwhile, at most every thirty seconds.
    pub fn app_activated(&mut self, cx: &mut Context<Self>) {
        if self.visible && !self.workers.closed() && !self.fresh() {
            self.load(cx);
            cx.notify();
        }
    }
    fn fresh(&self) -> bool {
        self.loaded_at.is_some_and(|at| at.elapsed() < FRESH)
    }
    fn close_list(&mut self) {
        self.list.clear();
        self.truncated = false;
        self.selected = None;
        self.detail = None;
        self.unavailable = None;
    }
    fn select_involvement(&mut self, involvement: Involvement, cx: &mut Context<Self>) {
        if self.busy || self.workers.closed() || self.involvement == involvement {
            return;
        }
        self.involvement = involvement;
        self.load_list(cx);
    }
    /// A filter change shows that filter's list from the start.
    fn load_list(&mut self, cx: &mut Context<Self>) {
        if self.busy || self.workers.closed() {
            return;
        }
        self.close_list();
        self.load(cx);
        cx.notify();
    }
    /// Swift reload: finds the repository again, then reads the list and the
    /// open pull request. Waits while hidden or while another read runs.
    fn load(&mut self, cx: &mut Context<Self>) {
        if self.workers.closed() {
            return;
        }
        let Some(selection) = self.selection.clone() else {
            self.needs_load = false;
            self.show_unavailable(Unavailable::NoThread, cx);
            return;
        };
        if !self.visible || self.busy || !self.workers.can_start() {
            self.needs_load = true;
            return;
        }
        self.needs_load = false;
        let request = Load {
            thread: selection.thread,
            state: self.state.clone(),
            involvement: self.involvement,
            open: self.selected.clone(),
        };
        self.invalidate_actions(cx);
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        self.loading = Some((generation, request.clone()));
        self.busy = true;
        self.notice.clear();
        let engine = self.engine.clone();
        let tx = self.load_tx.clone();
        if !self.workers.spawn(move |admission| {
            let result = load_admitted(
                &mut |method, params| call_admitted(&engine, method, params, &admission),
                &request,
                &admission,
            );
            let _ = tx.send((generation, request, result));
        }) {
            self.busy = false;
            self.loading = None;
            self.notice = "GitHub read worker could not start.".into();
        }
    }
    /// Shows a state in place of the list; an open pull request closes, since
    /// there is nothing behind it.
    fn show_unavailable(&mut self, state: Unavailable, cx: &mut Context<Self>) {
        self.invalidate_actions(cx);
        self.close_list();
        self.binding = None;
        self.active = None;
        self.unavailable = Some(state);
    }
    fn reload(&mut self, cx: &mut Context<Self>) {
        self.load(cx);
        cx.notify();
    }
    fn load_detail(&mut self, number: u64, head: String, cx: &mut Context<Self>) {
        if self.busy || !self.workers.can_start() {
            return;
        }
        let Some((_, active)) = &self.active else {
            return;
        };
        let binding = active.binding.clone();
        self.detail = None;
        self.selected = Some((number, head.clone()));
        self.start(
            Request {
                binding,
                view: View::Detail { number, head },
            },
            cx,
        );
    }
    fn start(&mut self, request: Request, cx: &mut Context<Self>) {
        if self.busy || !self.workers.can_start() {
            return;
        }
        // Every request invalidates prepared actions, including refreshing
        // detail for exactly the same PR/head after checks/reviews change.
        self.invalidate_actions(cx);
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        self.active = Some((generation, request.clone()));
        self.busy = true;
        self.notice.clear();
        let engine = self.engine.clone();
        let tx = self.tx.clone();
        if !self.workers.spawn(move |admission| {
            let result = fetch_admitted(
                &mut |method, params| call_admitted(&engine, method, params, &admission),
                &request,
                &admission,
            );
            let _ = tx.send((generation, request, result));
        }) {
            self.busy = false;
            self.notice = "GitHub read worker could not start.".into();
        }
        cx.notify();
    }
    pub fn request_shutdown(&mut self, cx: &mut Context<Self>) {
        if self.workers.close() {
            self.generation = self.generation.wrapping_add(1);
            self.active = None;
            self.loading = None;
            self.selection = None;
            self.binding = None;
            self.detail = None;
            self.selected = None;
            self.list.clear();
            self.truncated = false;
            self.actions_open = false;
            drop(self._poll.take());
        }
        if let Some(actions) = &self.actions {
            actions.update(cx, |actions, cx| actions.request_shutdown(cx));
        }
        if let Some(writes) = &self.writes {
            writes.request_shutdown();
        }
        self.discard_read_results();
    }
    fn discard_read_results(&mut self) {
        if discard_completions(&self.rx) | discard_completions(&self.load_rx) {
            self.busy = false;
        }
    }
    pub fn shutdown_status(&mut self, cx: &App) -> ReviewShutdownStatus {
        if self.workers.closed() {
            self.discard_read_results();
        }
        let read = self.workers.status();
        if self.workers.closed() {
            self.discard_read_results();
        }
        ReviewShutdownStatus {
            read,
            actions: self
                .actions
                .as_ref()
                .map(|actions| actions.read(cx).shutdown_status()),
            writes: self.writes.as_ref().map(|writes| writes.shutdown_status()),
        }
    }
    fn poll(&mut self, cx: &mut Context<Self>) {
        self.workers.poll();
        if self.workers.closed() {
            self.discard_read_results();
            return;
        }
        if let Some(status) = self.writes.as_ref().and_then(|writes| writes.status())
            && self.write_status.as_ref() != Some(&status)
        {
            let ready = status == crate::github_write_transport::Status::Ready;
            self.write_status = Some(status);
            if ready {
                self.sync_action_scope(cx);
                if let Some(actions) = &self.actions {
                    actions.update(cx, |actions, cx| actions.invalidate(cx));
                }
            }
            cx.notify();
        }
        if let Ok((generation, request, result)) = self.load_rx.try_recv() {
            self.busy = false;
            if self.loading.as_ref() == Some(&(generation, request)) {
                self.loading = None;
                self.finish_load(generation, result, cx);
            }
            // A conversation or filter change during the read loads now.
            if self.needs_load {
                self.load(cx);
            }
            cx.notify();
            return;
        }
        let Ok((generation, request, result)) = self.rx.try_recv() else {
            return;
        };
        self.busy = false;
        if !current(generation, &request, self.active.as_ref()) {
            if self.needs_load {
                self.load(cx);
            }
            cx.notify();
            return;
        }
        match result {
            Ok(payload) => match request.view {
                View::List(_) => {
                    self.list = payload["pullRequests"]
                        .as_array()
                        .cloned()
                        .unwrap_or_default();
                    self.truncated = payload["truncated"] == true;
                }
                View::Detail { .. } => {
                    self.detail = Some(payload["pullRequest"].clone());
                }
            },
            Err(error) => {
                self.detail = None;
                self.notice = format!("{}. Refresh to try again.", describe(&error));
            }
        }
        self.sync_action_scope(cx);
        if self.needs_load {
            self.load(cx);
        }
        cx.notify();
    }
    fn finish_load(&mut self, generation: u64, result: Result<Loaded>, cx: &mut Context<Self>) {
        self.loaded_at = Some(Instant::now());
        match result {
            Ok(Loaded::Unavailable(state)) => self.show_unavailable(state, cx),
            Ok(Loaded::List {
                binding,
                list,
                detail,
            }) => {
                self.unavailable = None;
                self.list = list["pullRequests"].as_array().cloned().unwrap_or_default();
                self.truncated = list["truncated"] == true;
                self.binding = Some(binding.clone());
                self.active = Some((
                    generation,
                    Request {
                        binding,
                        view: View::List(self.state.clone()),
                    },
                ));
                if let Some((request, result)) = detail {
                    let View::Detail { number, head } = &request.view else {
                        unreachable!("open pull requests are read as details");
                    };
                    self.selected = Some((*number, head.clone()));
                    match result {
                        Ok(payload) => {
                            self.detail = Some(payload["pullRequest"].clone());
                            self.active = Some((generation, request));
                        }
                        Err(error) => {
                            self.detail = None;
                            self.notice = format!("{}. Refresh to try again.", describe(&error));
                        }
                    }
                }
            }
            // Swift keeps a list it already shows and reports the failure.
            Err(error) if !self.list.is_empty() || self.selected.is_some() => {
                self.notice = format!("{}. Refresh to try again.", describe(&error));
            }
            Err(error) => self.show_unavailable(Unavailable::Failed(describe(&error)), cx),
        }
        self.sync_action_scope(cx);
    }
}
/// Swift's empty state: a symbol, a title and a line of text, with Try Again
/// after a failed load.
fn state_view(
    icon: IconName,
    title: &'static str,
    text: String,
    retry: bool,
    cx: &mut Context<GitHubReviewPanel>,
) -> AnyElement {
    let muted = cx.theme().muted_foreground;
    div()
        .id("github-pr-state")
        .w_full()
        .min_w_0()
        .py_8()
        .px_6()
        .flex()
        .flex_col()
        .items_center()
        .gap_2()
        .child(Icon::new(icon).large().text_color(muted))
        .child(
            div()
                .font_weight(FontWeight::SEMIBOLD)
                .text_center()
                .child(title),
        )
        .child(div().text_sm().text_center().text_color(muted).child(text))
        .when(retry, |state| {
            state.child(
                Button::new("github-try-again")
                    .label("Try Again")
                    .on_click(cx.listener(|this, _, _, cx| this.reload(cx))),
            )
        })
        .into_any_element()
}
impl Drop for GitHubReviewPanel {
    fn drop(&mut self) {
        self.workers.close();
        if let Some(writes) = &self.writes {
            writes.request_shutdown();
        }
    }
}
impl Render for GitHubReviewPanel {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.actions_open
            && let Some(actions) = self.actions.clone()
        {
            return div()
                .id("github-action-surface")
                .size_full()
                .overflow_hidden()
                .min_h_0()
                .min_w_0()
                .flex()
                .flex_col()
                .child(
                    Button::new("github-actions-back")
                        .label("Back to PR details")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.actions_open = false;
                            if let Some(actions) = &this.actions {
                                actions.update(cx, |actions, cx| actions.invalidate(cx));
                            }
                            cx.notify();
                        })),
                )
                .child(
                    div()
                        .flex_1()
                        .min_h_0()
                        .min_w_0()
                        .overflow_hidden()
                        .child(actions),
                )
                .into_any_element();
        }
        let mut pane = div()
            .id("github-review-panel")
            .size_full()
            .min_h_0()
            .min_w_0()
            .overflow_hidden()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .child("GitHub pull requests")
            .child(div().text_sm().child(
                "Review pull requests, comment, approve or request changes for the displayed commit, and merge eligible pull requests after confirmation. Checkout is not connected.",
            ))
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .children(STATES.iter().map(|state| {
                        let state = *state;
                        Button::new(SharedString::from(format!("github-state-{state}")))
                            .label(if self.state == state {
                                format!("• {state}")
                            } else {
                                state.to_owned()
                            })
                            .disabled(self.busy || self.workers.closed())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.state = state.into();
                                this.load_list(cx);
                            }))
                    })),
            )
            .child(div().flex().flex_wrap().gap_2().children(Involvement::ALL.into_iter().map(|involvement| {
                Button::new(SharedString::from(format!("github-involvement-{}",involvement.wire())))
                    .label(if self.involvement==involvement {format!("• {}",involvement.label())} else {involvement.label().to_owned()})
                    .disabled(self.busy || self.workers.closed())
                    .on_click(cx.listener(move |this,_,_,cx| { this.select_involvement(involvement,cx); }))
            })))
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_end()
                    .gap_2()
                    .when(self.busy, |row| row.child(Spinner::new().small()))
                    .child(
                        Button::new("github-refresh")
                            .icon(IconName::RefreshCw)
                            .accessibility_label("Refresh")
                            .tooltip("Refresh")
                            .ghost()
                            .compact()
                            .disabled(
                                self.busy || self.workers.closed() || self.selection.is_none(),
                            )
                            .on_click(cx.listener(|this, _, _, cx| this.reload(cx))),
                    ),
            )
            .when(!self.notice.is_empty(), |pane| {
                pane.child(div().text_sm().child(self.notice.clone()))
            });
        if let Some(status) = &self.write_status {
            let message = match status {
                crate::github_write_transport::Status::Opening => "Opening the local GitHub action ledger…".into(),
                crate::github_write_transport::Status::Initializing => "Initializing the local ledger. No GitHub request is made.".into(),
                crate::github_write_transport::Status::FirstSetup => "First setup: initialize a private local action ledger before preparing writes. If this app previously sent GitHub actions, restore its original ledger instead.".into(),
                crate::github_write_transport::Status::Ready => "Local action ledger ready. Each write needs a fresh preflight and explicit confirmation.".into(),
                crate::github_write_transport::Status::Failed(error) => format!("GitHub actions unavailable: {error}. Restore the original ledger; it will not be recreated automatically."),
            };
            pane = pane.child(div().text_sm().child(message));
            if status == &crate::github_write_transport::Status::FirstSetup {
                pane = pane.child(Button::new("github-write-first-setup").label("Initialize local GitHub action ledger")
                    .on_click(cx.listener(|this, _, _, cx| {
                        if this.workers.closed() { return; }
                        if let Some(writes) = &this.writes
                            && !writes.initialize_from_user_action()
                        { this.notice = "Ledger setup is busy or no longer available. No action was queued.".into(); }
                        cx.notify();
                    })));
            }
        }
        if let Some((_, request)) = &self.active {
            pane = pane.child(div().text_sm().child(format!(
                "Repository: {}\nRoot: {}",
                request.binding.repository, request.binding.root
            )));
        }
        // Keep navigation and write entry points outside the long metadata
        // viewport. Its natural-height child supplies the scrollable extent.
        let mut toolbar = div()
            .id("github-detail-toolbar")
            .flex()
            .flex_wrap()
            .gap_2()
            .flex_none();
        if self.selected.is_some() {
            toolbar = toolbar.child(
                Button::new("github-back")
                    .label("Back to PR list")
                    .disabled(self.busy || self.workers.closed())
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.selected = None;
                        this.detail = None;
                        this.invalidate_actions(cx);
                        cx.notify();
                    })),
            );
        }
        if let Some(pr) = &self.detail {
            let number = pr["number"].as_u64().unwrap_or(0);
            let refresh_head = text(pr, "headRefOid");
            let copied = text(pr, "url");
            toolbar = toolbar
                .child(
                    Button::new("github-copy-url")
                        .label("Copy PR URL")
                        .on_click(move |_, _, cx| {
                            cx.write_to_clipboard(ClipboardItem::new_string(copied.clone()))
                        }),
                )
                .child(
                    Button::new("github-open-actions")
                        .label("Review or merge…")
                        .disabled(
                            self.busy
                                || self.workers.closed()
                                || self.actions.is_none()
                                || self.write_status
                                    != Some(crate::github_write_transport::Status::Ready),
                        )
                        .on_click(cx.listener(|this, _, _, cx| {
                            if this.workers.closed() {
                                return;
                            }
                            this.sync_action_scope(cx);
                            this.actions_open = true;
                            cx.notify();
                        })),
                )
                .child(
                    Button::new("github-refresh-detail")
                        .label("Refresh selected PR")
                        .disabled(self.busy || self.workers.closed())
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.load_detail(number, refresh_head.clone(), cx);
                        })),
                );
        }
        pane = pane.child(toolbar);
        let mut body = div()
            .w_full()
            .min_w_0()
            .flex_none()
            .flex()
            .flex_col()
            .gap_2();
        if let Some(pr) = &self.detail {
            let number = pr["number"].as_u64().unwrap_or(0);
            let full_head = text(pr, "headRefOid");
            body = body
                .child(format!("#{number} {}", text(pr, "title")))
                .child(format!(
                    "{}{} · author {}",
                    text(pr, "state"),
                    if pr["isDraft"] == true {
                        " (Draft)"
                    } else {
                        ""
                    },
                    pr["author"]["login"]
                        .as_str()
                        .unwrap_or("Unknown / deleted account")
                ))
                .child(format!(
                    "{} → {}\nHead: {full_head}",
                    text(pr, "headRefName"),
                    text(pr, "baseRefName")
                ))
                .child(format!(
                    "Updated: {}\nReview decision: {}\nMergeability: {} · {}",
                    text(pr, "updatedAt"),
                    text(pr, "reviewDecision"),
                    text(pr, "mergeable"),
                    text(pr, "mergeStateStatus")
                ));
            if pr["additions"].is_number() && pr["deletions"].is_number() {
                body = body.child(format!(
                    "+{} / -{} · changed files {}",
                    pr["additions"],
                    pr["deletions"],
                    pr["changedFiles"]
                        .as_u64()
                        .map(|n| n.to_string())
                        .unwrap_or_else(|| "Unknown".into())
                ));
            }
            body = body.child(div().text_sm().child(text(pr, "url")))
                .child(Button::new("github-checkout-unavailable").label("Check out").disabled(true))
                .child("Use the review actions below for the displayed commit. Checkout is not connected.")
                .child("Checks");
            let checks = pr["statusCheckRollup"].as_array();
            if checks.is_none_or(|checks| checks.is_empty()) {
                body = body.child("No checks were reported; this is not proof of passing checks.");
            }
            for (index, check) in checks.into_iter().flatten().take(100).enumerate() {
                body = body.child(
                    div()
                        .id(SharedString::from(format!("github-check-{number}-{index}")))
                        .text_sm()
                        .child(format!(
                            "{} · status {} · conclusion {}",
                            check["name"]
                                .as_str()
                                .or(check["context"].as_str())
                                .unwrap_or("Unnamed check"),
                            check["status"]
                                .as_str()
                                .or(check["state"].as_str())
                                .unwrap_or("Unknown"),
                            check["conclusion"].as_str().unwrap_or("Not supplied")
                        )),
                );
            }
            if checks.is_some_and(|v| v.len() > 100) {
                body = body.child("Showing first 100 checks.");
            }
            body = body
                .child("Description (Markdown source)")
                .child(excerpt(pr["body"].as_str().unwrap_or(""), 30_000))
                .child("Reviews");
            let reviews = pr["reviews"].as_array();
            if reviews.is_none_or(|reviews| reviews.is_empty()) {
                body = body.child(
                    "No review records were reported. Inline review threads are not included.",
                );
            }
            for (index, review) in reviews.into_iter().flatten().take(100).enumerate() {
                let commit = review["commit"]["oid"].as_str();
                body = body.child(
                    div()
                        .id(SharedString::from(format!(
                            "github-review-{number}-{index}"
                        )))
                        .p_2()
                        .border_1()
                        .child(format!(
                            "{} · {} · {}",
                            review["author"]["login"]
                                .as_str()
                                .unwrap_or("Unknown / deleted account"),
                            text(review, "state"),
                            text(review, "submittedAt")
                        ))
                        .child(format!(
                            "Review commit: {}{}",
                            commit.unwrap_or("Not supplied"),
                            if commit.is_some_and(|oid| oid != full_head) {
                                " (different from selected PR head)"
                            } else {
                                ""
                            }
                        ))
                        .child(excerpt(review["body"].as_str().unwrap_or(""), 8000)),
                );
            }
            if reviews.is_some_and(|v| v.len() > 100) {
                body = body.child("Showing first 100 reviews.");
            }
        } else if self.selected.is_some() {
            body=body.child("Detail is not available for this selection. Refresh the list after errors or head changes.");
        } else if let Some(state) = &self.unavailable {
            let retry = matches!(state, Unavailable::Failed(_));
            body = body.child(state_view(
                state.icon(),
                state.title(),
                state.text(),
                retry,
                cx,
            ));
        } else {
            if self.list.is_empty() && !self.busy && self.binding.is_some() {
                let (title, text) = empty_list(&self.state, self.involvement);
                body = body.child(state_view(IconName::Inbox, title, text.into(), false, cx));
            }
            for pr in &self.list {
                let number = pr["number"].as_u64().unwrap_or(0);
                let head = text(pr, "headRefOid");
                body = body.child(
                    Button::new(SharedString::from(format!("github-pr-{number}")))
                        .label(format!(
                            "#{number} {} · {}{}\n{} → {}",
                            excerpt(&text(pr, "title"), 180),
                            text(pr, "state"),
                            if pr["isDraft"] == true {
                                " / Draft"
                            } else {
                                ""
                            },
                            text(pr, "headRefName"),
                            text(pr, "baseRefName")
                        ))
                        .disabled(self.busy || self.workers.closed())
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.load_detail(number, head.clone(), cx)
                        })),
                );
            }
            if self.truncated {
                body=body.child("List may be truncated at 30 pull requests. Use a narrower state filter; pagination is unavailable.");
            }
        }
        pane.child(
            div()
                .id("github-review-scroll")
                .flex_1()
                .flex_basis(px(0.))
                .min_h_0()
                .min_w_0()
                .overflow_y_scroll()
                .track_scroll(&self.scroll)
                .child(body),
        )
        .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Binding, Involvement, LIMIT, Load, Loaded, Request, Unavailable, View, availability,
        current, describe, empty_list, fetch, load, repository, validate_payload,
    };
    use anyhow::Result;
    use serde_json::{Value, json};
    fn request(view: View) -> Request {
        Request {
            binding: Binding {
                thread: "thread-a".into(),
                root: std::env::temp_dir().to_str().unwrap().into(),
                repository: "fixture/repo".into(),
                involvement: Involvement::All,
            },
            view,
        }
    }
    fn pr() -> Value {
        json!({"number":42,"title":"Unicode café 中文","url":"https://github.com/fixture/repo/pull/42","state":"OPEN","isDraft":false,"headRefOid":"a".repeat(40),"headRefName":"feature/test","baseRefName":"main","body":"# Description\n\nActual metadata.","author":null,"updatedAt":null,"additions":null,"deletions":null,"changedFiles":null,"mergeable":null,"mergeStateStatus":null,"reviewDecision":null,"reviews":[],"statusCheckRollup":[]})
    }
    fn payload(r: &Request) -> Value {
        let b = &r.binding;
        match &r.view {
            View::List(state) => {
                json!({"kind":"list","state":state,"involvement":b.involvement.wire(),"threadId":b.thread,"expectedRoot":b.root,"repository":b.repository,"pullRequests":[pr()],"limit":LIMIT,"truncated":false})
            }
            View::Detail { head, .. } => {
                json!({"kind":"read","threadId":b.thread,"expectedRoot":b.root,"repository":b.repository,"expectedHead":head,"pullRequest":pr()})
            }
        }
    }
    #[::core::prelude::v1::test]
    fn list_uses_chosen_contract_and_polls_with_same_thread_root() {
        let request = request(View::List("open".into()));
        let result = payload(&request);
        let mut calls = Vec::new();
        let got = fetch(
            &mut |method, params| -> Result<Value> {
                calls.push((method.to_owned(), params));
                Ok(if method == "github.pr.list" {
                    json!({"operationId":"op-list"})
                } else {
                    json!({"ready":true,"result":result})
                })
            },
            &request,
        )
        .unwrap();
        assert_eq!(got["pullRequests"][0]["title"], "Unicode café 中文");
        assert_eq!(calls.len(), 2);
        assert_eq!(
            calls[0],
            (
                "github.pr.list".into(),
                json!({"threadId":request.binding.thread,"expectedRoot":request.binding.root,"repository":"fixture/repo","state":"open","involvement":"all","limit":30})
            )
        );
        assert_eq!(
            calls[1],
            (
                "github.result".into(),
                json!({"threadId":request.binding.thread,"expectedRoot":request.binding.root,"operationId":"op-list"})
            )
        );
    }
    #[::core::prelude::v1::test]
    fn read_binds_selected_list_head_and_preserves_nullable_review_metadata() {
        let request = request(View::Detail {
            number: 42,
            head: "a".repeat(40),
        });
        let mut result = payload(&request);
        result["pullRequest"]["reviews"] = json!([{"id":"review-1","state":"COMMENTED","body":"  café 中文\n","author":null,"commit":{"oid":"b".repeat(40)},"submittedAt":null}]);
        let mut calls = Vec::new();
        let got = fetch(
            &mut |method, p| -> Result<Value> {
                calls.push((method.to_owned(), p));
                Ok(if method == "github.pr.read" {
                    json!({"operationId":"op-read"})
                } else {
                    json!({"ready":true,"result":result})
                })
            },
            &request,
        )
        .unwrap();
        assert_eq!(calls[0].1["expectedHead"], "a".repeat(40));
        assert_eq!(calls[0].1["number"], 42);
        assert!(got["pullRequest"]["reviewDecision"].is_null());
        assert!(got["pullRequest"]["reviews"][0]["author"].is_null());
        assert_eq!(got["pullRequest"]["reviews"][0]["body"], "  café 中文\n");
    }
    #[::core::prelude::v1::test]
    fn head_changed_error_is_returned_once_without_detail_or_retry() {
        let request = request(View::Detail {
            number: 42,
            head: "a".repeat(40),
        });
        let mut calls = 0;
        let error = fetch(
            &mut |method, _| -> Result<Value> {
                calls += 1;
                Ok(if method == "github.pr.read" {
                    json!({"operationId":"op"})
                } else {
                    json!({"ready":true,"result":{"code":"head_changed","error":"PR head changed"}})
                })
            },
            &request,
        )
        .unwrap_err();
        assert!(error.to_string().contains("head_changed"));
        assert_eq!(calls, 2);
    }
    #[::core::prelude::v1::test]
    fn wrong_thread_root_repository_number_or_head_never_becomes_detail() {
        let request = request(View::Detail {
            number: 42,
            head: "a".repeat(40),
        });
        for (key, value) in [
            ("threadId", json!("thread-b")),
            ("expectedRoot", json!("/other")),
            ("repository", json!("fixture/other")),
            ("expectedHead", json!("b".repeat(40))),
        ] {
            let mut result = payload(&request);
            result[key] = value;
            assert!(validate_payload(&request, &result).is_err(), "{key}");
        }
        for (key, value) in [
            ("number", json!(43)),
            ("headRefOid", json!("b".repeat(40))),
            ("url", json!("https://github.com/fixture/other/pull/42")),
        ] {
            let mut result = payload(&request);
            result["pullRequest"][key] = value;
            assert!(validate_payload(&request, &result).is_err(), "{key}");
        }
    }
    #[::core::prelude::v1::test]
    fn generation_and_full_selection_identity_reject_stale_completion() {
        let first = request(View::Detail {
            number: 42,
            head: "a".repeat(40),
        });
        let active = (7, first.clone());
        assert!(current(7, &first, Some(&active)));
        assert!(!current(6, &first, Some(&active)));
        assert!(!current(7, &first, None));
        for other in [
            request(View::Detail {
                number: 43,
                head: "a".repeat(40),
            }),
            request(View::Detail {
                number: 42,
                head: "b".repeat(40),
            }),
            Request {
                binding: Binding {
                    repository: "fixture/other".into(),
                    ..first.binding.clone()
                },
                view: first.view.clone(),
            },
            Request {
                binding: Binding {
                    thread: "thread-b".into(),
                    ..first.binding.clone()
                },
                view: first.view.clone(),
            },
        ] {
            assert!(!current(7, &other, Some(&active)));
        }
    }
    #[::core::prelude::v1::test]
    fn involvement_is_part_of_every_request_and_list_envelope() {
        let authored = Request {
            binding: Binding {
                involvement: Involvement::Authored,
                ..request(View::List("open".into())).binding
            },
            view: View::List("open".into()),
        };
        let assigned = Request {
            binding: Binding {
                involvement: Involvement::Assigned,
                ..authored.binding.clone()
            },
            view: authored.view.clone(),
        };
        let active = (9, assigned.clone());
        assert!(!current(9, &authored, Some(&active)));
        assert!(current(9, &assigned, Some(&active)));
        assert!(!current(8, &assigned, Some(&active)));
        assert!(validate_payload(&assigned, &payload(&authored)).is_err());
        let mut wrong_state = payload(&assigned);
        wrong_state["state"] = json!("closed");
        assert!(validate_payload(&assigned, &wrong_state).is_err());
        let mut wrong_filter = payload(&assigned);
        wrong_filter["involvement"] = json!("--assignee @me");
        assert!(validate_payload(&assigned, &wrong_filter).is_err());
        let detail = View::Detail {
            number: 42,
            head: "a".repeat(40),
        };
        let authored_detail = Request {
            view: detail.clone(),
            ..authored
        };
        let assigned_detail = Request {
            view: detail,
            ..assigned
        };
        assert!(!current(9, &authored_detail, Some(&(9, assigned_detail))));
    }
    #[cfg(unix)]
    #[::core::prelude::v1::test]
    fn actual_fake_cli_filter_result_cannot_replace_a_newer_ui_source() {
        use coincide_core::github_api::{GhRunner, GithubService};
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap();
        let executable = root.join("gh-fixture");
        std::fs::write(
            &executable,
            "#!/bin/sh\nprintf '%s\n' \"$@\" > argv.txt\ncat response.json\n",
        )
        .unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(
            root.join("response.json"),
            serde_json::to_vec(&vec![pr()]).unwrap(),
        )
        .unwrap();
        let mut service = GithubService::new(GhRunner::new(executable).unwrap());
        let mut old = request(View::List("open".into()));
        old.binding.thread = uuid::Uuid::new_v4().to_string();
        old.binding.root = root.to_str().unwrap().into();
        old.binding.involvement = Involvement::Authored;
        let new = Request {
            binding: Binding {
                involvement: Involvement::ReviewRequested,
                ..old.binding.clone()
            },
            view: old.view.clone(),
        };
        let mut api = |method: &str, params: Value| -> Result<Value> {
            match method {
                "github.pr.list" => service.start(&old.binding.thread, &root, method, &params),
                "github.result" => service.result(
                    &old.binding.thread,
                    &root,
                    &root,
                    params["operationId"].as_str().unwrap(),
                ),
                _ => panic!("unexpected method"),
            }
        };
        let old_result = fetch(&mut api, &old).unwrap();
        let new_result = fetch(&mut api, &new).unwrap();
        let active = (20, new.clone());
        assert!(!current(19, &old, Some(&active)));
        assert!(!current(20, &old, Some(&active)));
        assert!(validate_payload(&new, &old_result).is_err());
        assert!(current(20, &new, Some(&active)));
        validate_payload(&new, &new_result).unwrap();
        assert_eq!(new_result["involvement"], "review-requested");
        let argv = std::fs::read_to_string(root.join("argv.txt")).unwrap();
        assert!(argv.contains("--search\nreview-requested:@me\n--repo\ngithub.com/fixture/repo\n"));
    }
    #[::core::prelude::v1::test]
    fn state_and_list_bounds_reject_unsupported_or_incomplete_data() {
        let r = request(View::List("all".into()));
        let mut result = payload(&r);
        result["truncated"] = json!(true);
        validate_payload(&r, &result).unwrap();
        result["pullRequests"] = json!(vec![pr(); 31]);
        assert!(validate_payload(&r, &result).is_err());
        result = payload(&r);
        result["pullRequests"][0]["headRefOid"] = Value::Null;
        assert!(validate_payload(&r, &result).is_err());
        let r = request(View::List("mine".into()));
        let mut called = false;
        assert!(
            fetch(
                &mut |_, _| -> Result<Value> {
                    called = true;
                    Ok(Value::Null)
                },
                &r
            )
            .is_err()
        );
        assert!(!called);
    }
    /// A fake Engine: availability answers `state` at once or through one
    /// operation; list and read answer with fixture pull requests.
    fn engine(
        availability: Value,
        immediate: bool,
        list: Vec<Value>,
        calls: &mut Vec<(String, Value)>,
    ) -> impl FnMut(&str, Value) -> Result<Value> + '_ {
        let root = request(View::List("open".into())).binding.root;
        let mut pending = Vec::<(String, Value)>::new();
        let mut next = 0;
        move |method, params| {
            calls.push((method.to_owned(), params.clone()));
            let result = match method {
                "github.pr.availability" if immediate => {
                    return Ok(json!({"ready":true,"result":availability.clone()}));
                }
                "github.pr.availability" => availability.clone(),
                "github.pr.list" => {
                    json!({"kind":"list","threadId":params["threadId"],"expectedRoot":params["expectedRoot"],
                        "repository":params["repository"],"state":params["state"],"involvement":params["involvement"],
                        "pullRequests":list,"limit":LIMIT,"truncated":false})
                }
                "github.pr.read" => {
                    let mut pr = pr();
                    pr["headRefOid"] = params["expectedHead"].clone();
                    json!({"kind":"read","threadId":params["threadId"],"expectedRoot":params["expectedRoot"],
                        "repository":params["repository"],"expectedHead":params["expectedHead"],"pullRequest":pr})
                }
                "github.result" => {
                    let id = params["operationId"].as_str().unwrap();
                    let index = pending.iter().position(|(op, _)| op == id).unwrap();
                    return Ok(json!({"ready":true,"result":pending.remove(index).1}));
                }
                _ => panic!("unexpected {method}"),
            };
            next += 1;
            let id = format!("op-{next}");
            pending.push((id.clone(), result));
            Ok(json!({"operationId":id,"expectedRoot":root}))
        }
    }
    fn ready(thread: &str) -> Value {
        let root = request(View::List("open".into())).binding.root;
        json!({"kind":"availability","threadId":thread,"expectedRoot":root,"state":"ready","repository":"fixture/repo"})
    }
    #[::core::prelude::v1::test]
    fn availability_reads_each_swift_state_from_the_engine() {
        let thread = "thread-a";
        let mut calls = Vec::new();
        for (state, expected) in [
            (json!({"state":"noFolder"}), Unavailable::NoThread),
            (
                json!({"state":"folderNotFound","path":"/gone/project"}),
                Unavailable::FolderNotFound("/gone/project".into()),
            ),
        ] {
            let mut payload = state;
            payload["kind"] = json!("availability");
            payload["threadId"] = json!(thread);
            let mut api = engine(payload, true, vec![], &mut calls);
            assert_eq!(availability(&mut api, thread).unwrap(), Err(expected));
            drop(api);
        }
        let root = request(View::List("open".into())).binding.root;
        for (state, expected) in [
            (json!({"state":"notRepository"}), Unavailable::NotRepository),
            (json!({"state":"noRemote"}), Unavailable::NoRemote),
            (
                json!({"state":"unsupportedHost","host":"GitLab","selfHosted":false}),
                Unavailable::UnsupportedHost {
                    host: "GitLab".into(),
                    self_hosted: false,
                },
            ),
            (
                json!({"state":"needsGitHubCli"}),
                Unavailable::NeedsGitHubCli,
            ),
        ] {
            let mut payload = state;
            payload["kind"] = json!("availability");
            payload["threadId"] = json!(thread);
            payload["expectedRoot"] = json!(root);
            let mut api = engine(payload, false, vec![], &mut calls);
            assert_eq!(availability(&mut api, thread).unwrap(), Err(expected));
            drop(api);
        }
        let mut api = engine(ready(thread), false, vec![], &mut calls);
        assert_eq!(
            availability(&mut api, thread).unwrap(),
            Ok((root.clone(), "fixture/repo".into()))
        );
        drop(api);
        // Another thread's or folder's answer, an immediate ready, an unknown
        // state and an unusable repository never become a binding.
        let mut wrong_root = ready(thread);
        wrong_root["expectedRoot"] = json!("/elsewhere");
        let mut bad_repository = ready(thread);
        bad_repository["repository"] = json!("https://github.com/a/b");
        let mut unknown = ready(thread);
        unknown["state"] = json!("maybe");
        for (payload, immediate) in [
            (ready("thread-b"), false),
            (wrong_root, false),
            (ready(thread), true),
            (bad_repository, false),
            (unknown, false),
        ] {
            let mut api = engine(payload, immediate, vec![], &mut calls);
            assert!(availability(&mut api, thread).is_err());
            drop(api);
        }
        assert!(
            calls
                .iter()
                .filter(|(method, _)| method == "github.pr.availability")
                .all(|(_, params)| *params == json!({"threadId":thread}))
        );
    }
    #[::core::prelude::v1::test]
    fn load_finds_the_repository_then_lists_and_follows_the_open_pr_head() {
        let thread = "thread-a";
        let mut moved = pr();
        moved["headRefOid"] = json!("b".repeat(40));
        let mut calls = Vec::new();
        let request = Load {
            thread: thread.into(),
            state: "open".into(),
            involvement: Involvement::Authored,
            open: Some((42, "a".repeat(40))),
        };
        let mut api = engine(ready(thread), false, vec![moved], &mut calls);
        let Loaded::List {
            binding,
            list,
            detail,
        } = load(&mut api, &request).unwrap()
        else {
            panic!("expected a list");
        };
        drop(api);
        assert_eq!(binding.repository, "fixture/repo");
        assert_eq!(binding.involvement, Involvement::Authored);
        assert_eq!(list["pullRequests"][0]["number"], 42);
        let (read, result) = detail.unwrap();
        assert_eq!(
            read.view,
            View::Detail {
                number: 42,
                head: "b".repeat(40)
            }
        );
        assert_eq!(result.unwrap()["pullRequest"]["headRefOid"], "b".repeat(40));
        let methods = calls
            .iter()
            .map(|(method, _)| method.as_str())
            .filter(|method| *method != "github.result")
            .collect::<Vec<_>>();
        assert_eq!(
            methods,
            ["github.pr.availability", "github.pr.list", "github.pr.read"]
        );
        let list_call = &calls.iter().find(|(m, _)| m == "github.pr.list").unwrap().1;
        assert_eq!(list_call["repository"], "fixture/repo");
        assert_eq!(list_call["involvement"], "authored");
        // A folder that can't list stops before any GitHub read.
        let mut calls = Vec::new();
        let mut payload = ready(thread);
        payload["state"] = json!("noRemote");
        let mut api = engine(payload, false, vec![], &mut calls);
        assert!(matches!(
            load(&mut api, &request).unwrap(),
            Loaded::Unavailable(Unavailable::NoRemote)
        ));
        drop(api);
        assert!(calls.iter().all(|(method, _)| method != "github.pr.list"));
    }
    #[::core::prelude::v1::test]
    fn states_and_messages_use_swift_wording() {
        assert_eq!(Unavailable::NoThread.title(), "No Thread Selected");
        assert_eq!(
            Unavailable::UnsupportedHost {
                host: "GitLab".into(),
                self_hosted: false
            }
            .text(),
            "This repository is on GitLab. Coincide lists pull requests from GitHub."
        );
        assert_eq!(
            Unavailable::NeedsGitHubCli.text(),
            "Install the GitHub CLI (gh) and run “gh auth login” to see this repository’s pull requests."
        );
        assert_eq!(Unavailable::FolderNotFound("/gone".into()).text(), "/gone");
        assert_eq!(
            empty_list("open", Involvement::All).0,
            "No Open Pull Requests"
        );
        assert_eq!(
            empty_list("open", Involvement::ReviewRequested).0,
            "No Reviews Requested"
        );
        assert_eq!(
            describe(&anyhow::anyhow!(
                "read_failed: Unable to read validated GitHub PR metadata"
            )),
            "Unable to read validated GitHub PR metadata"
        );
        assert_eq!(
            describe(&anyhow::anyhow!(
                "GitHub read timed out; retry with Refresh"
            )),
            "GitHub read timed out; retry with Refresh"
        );
    }
    #[::core::prelude::v1::test]
    fn repository_input_is_explicit_and_not_a_url_or_shell_fragment() {
        assert!(repository("owner/repo-name"));
        for invalid in [
            "",
            "owner",
            "a/b/c",
            "https://github.com/a/b",
            "a/b;id",
            "-owner/repo",
            "../repo",
            "a/..",
            "a/b\n",
        ] {
            assert!(!repository(invalid), "{invalid}");
        }
    }
    struct ShutdownTls {
        entered: std::sync::mpsc::Sender<()>,
        release: std::sync::mpsc::Receiver<()>,
    }
    impl Drop for ShutdownTls {
        fn drop(&mut self) {
            let _ = self.entered.send(());
            let _ = self.release.recv();
        }
    }
    thread_local! { static SHUTDOWN_TLS:std::cell::RefCell<Option<ShutdownTls>>=const { std::cell::RefCell::new(None) }; }
    #[::core::prelude::v1::test]
    fn shutdown_discards_late_private_pr_reply_and_keeps_actual_tls_owner() {
        let mut owner = crate::worker_owner::WorkerOwner::default();
        let request = request(View::List("open".into()));
        let result = payload(&request);
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let (tls_tx, tls_rx) = std::sync::mpsc::channel();
        let (tls_release_tx, tls_release_rx) = std::sync::mpsc::channel();
        let (reply_tx, reply_rx) = std::sync::mpsc::channel();
        assert!(owner.spawn(move |admission| {
            SHUTDOWN_TLS.with(|slot| {
                *slot.borrow_mut() = Some(ShutdownTls {
                    entered: tls_tx,
                    release: tls_release_rx,
                })
            });
            let result = super::fetch_admitted(
                &mut |method, _| {
                    if method == "github.pr.list" {
                        Ok(json!({"operationId":"synthetic"}))
                    } else {
                        entered_tx.send(()).unwrap();
                        release_rx.recv().unwrap();
                        Ok(json!({"ready":true,"result":result.clone()}))
                    }
                },
                &request,
                &admission,
            );
            let _ = reply_tx.send((1, request, result));
        }));
        entered_rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
        owner.close();
        release_tx.send(()).unwrap();
        tls_rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
        assert!(super::discard_completions(&reply_rx));
        assert!(reply_rx.try_recv().is_err());
        assert_eq!(owner.status().unjoined, 1);
        assert!(!owner.spawn(|_| panic!("closed panel must not spawn")));
        tls_release_tx.send(()).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while owner.status().unjoined != 0 {
            assert!(std::time::Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(owner.status().returned, 1);
    }
    #[::core::prelude::v1::test]
    fn closed_read_admission_never_enters_engine_transport() {
        let mut owner = crate::worker_owner::WorkerOwner::default();
        let request = request(View::List("open".into()));
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        assert!(owner.spawn(move |admission| {
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            let result = super::fetch_admitted(
                &mut |_, _| panic!("closed UI worker must not touch Engine"),
                &request,
                &admission,
            );
            done_tx.send(result.is_err()).unwrap();
        }));
        entered_rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
        owner.close();
        release_tx.send(()).unwrap();
        assert!(
            done_rx
                .recv_timeout(std::time::Duration::from_secs(5))
                .unwrap()
        );
    }
    #[::core::prelude::v1::test]
    fn held_engine_acquisition_is_deadlined_and_closed_admission_is_interruptible() {
        use super::with_admitted_lock;
        use crate::worker_owner::WorkerOwner;
        use std::{
            sync::{Arc, Mutex},
            time::{Duration, Instant},
        };
        let engine = Arc::new(Mutex::new(()));
        let guard = engine.lock().unwrap();
        let mut owner = WorkerOwner::default();
        let worker_engine = engine.clone();
        let (sent, done) = std::sync::mpsc::channel();
        assert!(owner.spawn(move |admission| {
            let started = Instant::now();
            assert!(
                with_admitted_lock(
                    &worker_engine,
                    &admission,
                    started + Duration::from_millis(80),
                    |_| Ok(())
                )
                .is_err()
            );
            sent.send(started.elapsed()).unwrap();
        }));
        assert!(done.recv_timeout(Duration::from_secs(1)).unwrap() < Duration::from_secs(1));
        let until = Instant::now() + Duration::from_secs(1);
        while owner.status().unjoined != 0 {
            assert!(Instant::now() < until);
            std::thread::yield_now();
        }
        let worker_engine = engine.clone();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (sent, done) = std::sync::mpsc::channel();
        assert!(owner.spawn(move |admission| {
            entered_tx.send(()).unwrap();
            sent.send(
                with_admitted_lock(
                    &worker_engine,
                    &admission,
                    Instant::now() + Duration::from_secs(3),
                    |_| Ok(()),
                )
                .is_err(),
            )
            .unwrap();
        }));
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        owner.close();
        assert!(done.recv_timeout(Duration::from_secs(1)).unwrap());
        drop(guard);
        let until = Instant::now() + Duration::from_secs(1);
        while owner.status().unjoined != 0 {
            assert!(Instant::now() < until);
            std::thread::yield_now();
        }
        assert_eq!(owner.status().returned, 2);
    }
}
