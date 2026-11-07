//! Native GitHub PR metadata panel with a separate explicit action surface. Parent mounts this entity and calls
//! set_context on every thread/root change. Repository is explicitly entered by
//! the user. All Engine calls run in one background worker, never GPUI render.
//! Check Out in New Thread emits CheckoutOpened for the parent to select.
use crate::worker_owner::{Admission, ShutdownStatus as ReadShutdownStatus, WorkerOwner};
use anyhow::{Context as _, Result, ensure};
use coincide_core::{
    api::{SharedEngine, call},
    github_checkout::Checkout,
};
use gpui_kit::{
    base::Disableable,
    component::{
        button::*,
        input::{Input, InputEvent, InputState},
        menu::{ContextMenuExt, PopupMenuItem},
    },
    prelude::FluentBuilder as _,
    *,
};
use serde_json::{Value, json};
use std::{
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
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
#[derive(Clone, Debug, PartialEq, Eq)]
struct Binding {
    thread: String,
    root: String,
    repository: String,
    involvement: Involvement,
}
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
    let deadline = Instant::now() + Duration::from_secs(110);
    loop {
        let reply = api(
            "github.result",
            json!({"threadId":b.thread,"expectedRoot":b.root,"operationId":id}),
        )?;
        if reply["ready"] == true {
            let payload = reply["result"].clone();
            if let Some(error) = payload["error"].as_str() {
                anyhow::bail!(
                    "{}: {}",
                    payload["code"].as_str().unwrap_or("github_error"),
                    error
                );
            }
            validate_payload(request, &payload)?;
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
/// A link the browser may open: https with a host and no credentials. Core
/// already drops other check links; PR URLs are pinned to github.com.
fn browser_link(value: &str) -> Option<&str> {
    let rest = value.strip_prefix("https://")?;
    let authority = rest.split(['/', '?', '#']).next()?;
    (!authority.is_empty()
        && !authority.contains('@')
        && !value.chars().any(|c| c.is_control() || c.is_whitespace()))
    .then_some(value)
}
/// Swift's PullRequestMention.markdown: a durable reference kept in the
/// user's message, with the characters Markdown would misread escaped.
fn mention_markdown(number: u64, url: &str) -> Option<String> {
    let mut destination = browser_link(url)?.to_owned();
    for (character, escaped) in [
        ("(", "%28"),
        (")", "%29"),
        ("<", "%3C"),
        (">", "%3E"),
        ("\\", "%5C"),
    ] {
        destination = destination.replace(character, escaped);
    }
    Some(format!("[#{number}]({destination})"))
}
/// What Mention in Message types at the caret: a space first when the caret
/// follows a word, and one after, as Swift's composer inserts it.
pub(crate) fn mention_insertion(text: &str, caret: usize, mention: &str) -> String {
    let after_word = text
        .get(..caret)
        .and_then(|before| before.chars().next_back())
        .is_some_and(|c| !c.is_whitespace());
    format!("{}{mention} ", if after_word { " " } else { "" })
}
fn check_link(check: &Value) -> Option<String> {
    ["detailsUrl", "targetUrl"]
        .into_iter()
        .find_map(|key| check[key].as_str().and_then(browser_link))
        .map(str::to_owned)
}
fn excerpt(value: &str, max: usize) -> String {
    let mut s = value.chars().take(max).collect::<String>();
    if value.chars().count() > max {
        s.push_str("… [display truncated]");
    }
    s
}

fn open_draft(pr: &Value) -> bool {
    pr["isDraft"] == true && pr["state"] == "OPEN"
}
/// Swift Formatting.abbreviatedPath: the home folder as `~`.
fn abbreviated(path: &Path) -> String {
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(std::path::PathBuf::from)
        .filter(|home| home.is_absolute());
    match home.and_then(|home| path.strip_prefix(home).ok().map(Path::to_path_buf)) {
        Some(rest) if rest.as_os_str().is_empty() => "~".into(),
        Some(rest) => Path::new("~").join(rest).display().to_string(),
        None => path.display().to_string(),
    }
}
type CheckoutResult = (u64, Result<(Value, Checkout)>);
/// The exact loaded conversation, root, repository and displayed head.
struct CheckoutScope {
    thread: String,
    root: String,
    repository: String,
    number: u64,
    head: String,
}
/// Capture and admission hold the Engine briefly; fetch and worktree creation
/// run between them without it. Closing admissions keeps a finished worktree.
fn check_out_pull_request(
    engine: &SharedEngine,
    admission: &Admission,
    cancelled: &AtomicBool,
    scope: &CheckoutScope,
) -> Result<(Value, Checkout)> {
    let lock = || {
        engine
            .lock()
            .map_err(|_| anyhow::anyhow!("App engine is unavailable"))
    };
    ensure!(admission.allowed(), "GitHub checkout admissions are closed");
    let source = lock()?.native_github_checkout_source(
        &scope.thread,
        Path::new(&scope.root),
        &scope.repository,
        scope.number,
        &scope.head,
    )?;
    let checkout = coincide_core::github_checkout::run(&source, cancelled)?;
    ensure!(
        admission.allowed(),
        "The app is closing; the checked-out worktree was kept at {}",
        checkout.path.display()
    );
    let opened = lock()?.native_open_github_checkout(&source, &checkout)?;
    Ok((opened, checkout))
}
/// A checked-out pull request's conversation, for the window to open.
pub struct CheckoutOpened {
    pub thread: String,
    pub notice: Option<String>,
}
impl EventEmitter<CheckoutOpened> for GitHubReviewPanel {}

fn discard_completions<T>(receiver: &mpsc::Receiver<T>) -> bool {
    let mut discarded = false;
    for result in receiver.try_iter() {
        drop(result);
        discarded = true;
    }
    discarded
}
/// What the PR panel asks of the window around it.
pub enum ReviewPanelEvent {
    /// Swift's Mention in Message: insert this Markdown link at the composer caret.
    Mention(String),
}
impl EventEmitter<ReviewPanelEvent> for GitHubReviewPanel {}
pub struct ReviewShutdownStatus {
    pub read: ReadShutdownStatus,
    pub actions: Option<coincide_core::github_write::WriteShutdownStatus>,
    pub writes: Option<crate::github_write_transport::NativeWriteShutdownStatus>,
}
pub struct GitHubReviewPanel {
    engine: SharedEngine,
    scope: Option<(String, String)>,
    repository: Entity<InputState>,
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
    checkout_tx: mpsc::Sender<CheckoutResult>,
    checkout_rx: mpsc::Receiver<CheckoutResult>,
    checkout_cancel: Arc<AtomicBool>,
    checking_out: Option<u64>,
    _poll: Option<Task<()>>,
    _repository_changes: Subscription,
    actions: Option<Entity<crate::github_actions::GitHubActions>>,
    writes: Option<crate::github_write_transport::NativeWrites>,
    write_status: Option<crate::github_write_transport::Status>,
    actions_open: bool,
    /// Mark Ready for Review succeeded for this PR; its reloaded detail says so.
    marked_ready: Option<u64>,
    _actions_events: Option<Subscription>,
    scroll: ScrollHandle,
}
impl GitHubReviewPanel {
    pub fn new(engine: SharedEngine, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (tx, rx) = mpsc::channel();
        let (checkout_tx, checkout_rx) = mpsc::channel();
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
        let repository = cx.new(|cx| {
            InputState::new(window, cx).placeholder("Explicit GitHub repository: owner/name")
        });
        let repository_changes = cx.subscribe(&repository, |this, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                if this.workers.closed() {
                    return;
                }
                this.generation = this.generation.wrapping_add(1);
                this.active = None;
                this.detail = None;
                this.selected = None;
                this.list.clear();
                this.truncated = false;
                this.invalidate_actions(cx);
                this.notice = "Repository changed. Load its pull requests to continue.".into();
                cx.notify();
            }
        });
        Self {
            engine,
            scope: None,
            repository,
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
            notice: "Choose a conversation and enter its GitHub repository.".into(),
            tx,
            rx,
            checkout_tx,
            checkout_rx,
            checkout_cancel: Arc::new(AtomicBool::new(false)),
            checking_out: None,
            _poll: Some(poll),
            _repository_changes: repository_changes,
            actions: None,
            writes: None,
            write_status: None,
            actions_open: false,
            marked_ready: None,
            _actions_events: None,
            scroll: ScrollHandle::new(),
        }
    }
    pub fn attach_actions(
        &mut self,
        actions: Entity<crate::github_actions::GitHubActions>,
        writes: crate::github_write_transport::NativeWrites,
        cx: &mut Context<Self>,
    ) {
        self._actions_events = Some(cx.subscribe(&actions, |this, _, event, cx| match event {
            crate::github_actions::ActionsEvent::MarkedReady(number) => {
                this.reload_after_ready(*number, cx)
            }
        }));
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
    fn validated_loaded_scope(&self, cx: &App) -> Option<crate::github_actions::ActionScope> {
        if self.workers.closed() {
            return None;
        }
        let (_, request) = self.active.as_ref()?;
        let pr = self.detail.as_ref()?;
        let View::Detail { number, head } = &request.view else {
            return None;
        };
        if self.busy
            || self.scope.as_ref()
                != Some(&(request.binding.thread.clone(), request.binding.root.clone()))
            || self.repository.read(cx).value().trim() != request.binding.repository
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
        let draft = scope.is_some() && self.detail.as_ref().is_some_and(open_draft);
        if let Some(actions) = &self.actions {
            actions.update(cx, |actions, cx| {
                actions.set_scope(scope, cx);
                actions.set_draft(draft, cx);
            });
        }
    }
    /// Swift reloads the PR after it is marked ready and says so in its banner.
    fn reload_after_ready(&mut self, number: u64, cx: &mut Context<Self>) {
        let Some(head) = self
            .detail
            .as_ref()
            .filter(|pr| pr["number"].as_u64() == Some(number))
            .map(|pr| text(pr, "headRefOid"))
        else {
            return;
        };
        self.marked_ready = Some(number);
        if self.busy {
            self.notice = format!("Pull request #{number} is ready for review.");
            cx.notify();
        } else {
            self.load_detail(number, head, cx);
        }
    }
    fn open_actions(&mut self, cx: &mut Context<Self>) {
        if self.workers.closed() {
            return;
        }
        self.sync_action_scope(cx);
        self.actions_open = true;
        cx.notify();
    }
    /// root must be the canonical stored-thread working directory. No calls or
    /// filesystem I/O run here. Changing scope invalidates every visible PR/head.
    pub fn set_context(&mut self, scope: Option<(String, String)>, cx: &mut Context<Self>) {
        if self.workers.closed() {
            return;
        }
        if self.scope == scope {
            return;
        }
        self.scope = scope;
        self.invalidate_actions(cx);
        self.generation = self.generation.wrapping_add(1);
        self.active = None;
        self.list.clear();
        self.detail = None;
        self.selected = None;
        self.truncated = false;
        self.notice = if self.busy {
            "Waiting for the previous read; its result will be discarded."
        } else {
            "Enter owner/name and load pull requests for this context."
        }
        .into();
        cx.notify();
    }
    fn select_involvement(&mut self, involvement: Involvement, cx: &mut Context<Self>) {
        if self.busy || self.workers.closed() || self.involvement == involvement {
            return;
        }
        self.involvement = involvement;
        self.invalidate_actions(cx);
        self.generation = self.generation.wrapping_add(1);
        self.active = None;
        self.list.clear();
        self.detail = None;
        self.selected = None;
        self.truncated = false;
        self.load_list(cx);
        cx.notify();
    }
    fn load_list(&mut self, cx: &mut Context<Self>) {
        if self.busy || !self.workers.can_start() {
            return;
        }
        let Some((thread, root)) = self.scope.clone() else {
            return;
        };
        let repository = self.repository.read(cx).value().trim().to_string();
        if !self::repository(&repository) {
            self.invalidate_actions(cx);
            self.list.clear();
            self.detail = None;
            self.selected = None;
            self.active = None;
            self.truncated = false;
            self.notice = "Enter a GitHub repository as owner/name.".into();
            cx.notify();
            return;
        }
        self.list.clear();
        self.selected = None;
        self.detail = None;
        self.truncated = false;
        self.start(
            Request {
                binding: Binding {
                    thread,
                    root,
                    repository,
                    involvement: self.involvement,
                },
                view: View::List(self.state.clone()),
            },
            cx,
        );
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
        self.notice = "Loading GitHub metadata…".into();
        let engine = self.engine.clone();
        let tx = self.tx.clone();
        if !self.workers.spawn(move |admission| {
            let result = fetch_admitted(
                &mut |method, params| call(&engine, method, params),
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
        // A running checkout stops its Git process group; it never waits here.
        self.checkout_cancel.store(true, Ordering::Release);
        if self.workers.close() {
            self.generation = self.generation.wrapping_add(1);
            self.active = None;
            self.scope = None;
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
        if discard_completions(&self.rx) | discard_completions(&self.checkout_rx) {
            self.busy = false;
            self.checking_out = None;
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
        if let Ok((number, result)) = self.checkout_rx.try_recv() {
            self.finish_checkout(number, result, cx);
            return;
        }
        let Ok((generation, request, result)) = self.rx.try_recv() else {
            return;
        };
        self.busy = false;
        if !current(generation, &request, self.active.as_ref()) {
            self.notice = "Previous result discarded. Load the current context when ready.".into();
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
                    self.notice = format!(
                        "{} PRs loaded. Select a row for exact-head detail.",
                        self.list.len()
                    );
                }
                View::Detail { number, .. } => {
                    self.detail = Some(payload["pullRequest"].clone());
                    self.notice = if self.marked_ready.take() == Some(number) {
                        format!("Pull request #{number} is ready for review.")
                    } else {
                        "Read-only detail loaded for the selected head. Refresh before relying on current server state.".into()
                    };
                }
            },
            Err(error) => {
                self.detail = None;
                self.marked_ready = None;
                self.notice = format!("{error}. Refresh the list to retry.");
            }
        }
        self.sync_action_scope(cx);
        cx.notify();
    }
}
impl GitHubReviewPanel {
    /// Swift PullRequestsViewController.checkOut for the exact loaded head.
    fn check_out(&mut self, cx: &mut Context<Self>) {
        if self.busy || !self.workers.can_start() {
            return;
        }
        let scope = self
            .validated_loaded_scope(cx)
            .and(self.active.as_ref())
            .and_then(|(_, request)| match &request.view {
                View::Detail { number, head } => Some(CheckoutScope {
                    thread: request.binding.thread.clone(),
                    root: request.binding.root.clone(),
                    repository: request.binding.repository.clone(),
                    number: *number,
                    head: head.clone(),
                }),
                View::List(_) => None,
            });
        let Some(scope) = scope else {
            self.notice = "Refresh the selected pull request before checking it out.".into();
            cx.notify();
            return;
        };
        let number = scope.number;
        self.invalidate_actions(cx);
        self.busy = true;
        self.checking_out = Some(number);
        self.notice = format!("Checking out pull request #{number}…");
        let engine = self.engine.clone();
        let tx = self.checkout_tx.clone();
        let cancelled = self.checkout_cancel.clone();
        if !self.workers.spawn(move |admission| {
            let result = check_out_pull_request(&engine, &admission, &cancelled, &scope);
            let _ = tx.send((number, result));
        }) {
            self.busy = false;
            self.checking_out = None;
            self.notice = "GitHub checkout worker could not start.".into();
        }
        cx.notify();
    }
    fn finish_checkout(
        &mut self,
        number: u64,
        result: Result<(Value, Checkout)>,
        cx: &mut Context<Self>,
    ) {
        self.busy = false;
        self.checking_out = None;
        match result {
            Ok((thread, checkout)) => {
                let notice = checkout.reused.then(|| {
                    format!(
                        "Opened a thread in the worktree that has #{number} checked out.\n{}",
                        abbreviated(&checkout.path)
                    )
                });
                self.notice = notice.clone().unwrap_or_else(|| {
                    format!(
                        "Checked out pull request #{number} on {} in a new worktree.",
                        checkout.branch
                    )
                });
                if let Some(id) = thread["id"].as_str() {
                    cx.emit(CheckoutOpened {
                        thread: id.to_owned(),
                        notice,
                    });
                }
            }
            Err(error) => self.notice = error.to_string(),
        }
        self.sync_action_scope(cx);
        cx.notify();
    }
}
impl Drop for GitHubReviewPanel {
    fn drop(&mut self) {
        self.checkout_cancel.store(true, Ordering::Release);
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
                "Review pull requests, comment, approve or request changes for the displayed commit, merge eligible pull requests or mark drafts ready for review after confirmation, and check a pull request out in a worktree of its own. Right-click a pull request to open, copy or mention it.",
            ))
            .child(Input::new(&self.repository))
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
                Button::new("github-refresh")
                    .label("Load / refresh PR list")
                    .disabled(self.busy || self.workers.closed() || self.scope.is_none())
                    .on_click(cx.listener(|this, _, _, cx| this.load_list(cx))),
            )
            .child(div().text_sm().child(self.notice.clone()));
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
            let opened = browser_link(&copied).map(str::to_owned);
            let draft = open_draft(pr);
            let writes_disabled = self.busy
                || self.workers.closed()
                || self.actions.is_none()
                || self.write_status != Some(crate::github_write_transport::Status::Ready);
            toolbar = toolbar
                .child(
                    Button::new("github-open-browser")
                        .icon(gpui_kit::assets::IconName::ExternalLink)
                        .label("Open in Browser")
                        .disabled(opened.is_none())
                        .on_click(move |_, _, cx| {
                            if let Some(url) = &opened {
                                cx.open_url(url);
                            }
                        }),
                )
                .child(
                    Button::new("github-copy-url")
                        .label("Copy PR URL")
                        .on_click(move |_, _, cx| {
                            cx.write_to_clipboard(ClipboardItem::new_string(copied.clone()))
                        }),
                )
                .when(draft, |toolbar| {
                    toolbar.child(
                        Button::new("github-mark-ready")
                            .label("Mark Ready for Review…")
                            .primary()
                            .disabled(writes_disabled)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.open_actions(cx);
                                if let Some(actions) = &this.actions {
                                    actions.update(cx, |actions, cx| actions.request_ready(cx));
                                }
                            })),
                    )
                })
                .child(
                    Button::new("github-open-actions")
                        .label(if draft {
                            "Review…"
                        } else {
                            "Review or merge…"
                        })
                        .disabled(writes_disabled)
                        .on_click(cx.listener(|this, _, _, cx| this.open_actions(cx))),
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
            body = body.child(div().text_sm().child(text(pr, "url")));
            // Swift shows Check Out in New Thread for open pull requests only.
            if pr["state"] == "OPEN" {
                body = body.child(
                    Button::new("github-checkout")
                        .label(if self.checking_out == Some(number) {
                            "Checking out…"
                        } else {
                            "Check Out in New Thread"
                        })
                        .tooltip("Creates a worktree on this pull request’s branch and opens a new thread in it")
                        .disabled(self.busy || self.workers.closed())
                        .on_click(cx.listener(|this, _, _, cx| this.check_out(cx))),
                );
            }
            body = body.child("Checks");
            let checks = pr["statusCheckRollup"].as_array();
            if checks.is_none_or(|checks| checks.is_empty()) {
                body = body.child("No checks were reported; this is not proof of passing checks.");
            }
            for (index, check) in checks.into_iter().flatten().take(100).enumerate() {
                let name = check["name"]
                    .as_str()
                    .or(check["context"].as_str())
                    .unwrap_or("Unnamed check")
                    .to_owned();
                let line = format!(
                    "{name} · status {} · conclusion {}",
                    check["status"]
                        .as_str()
                        .or(check["state"].as_str())
                        .unwrap_or("Unknown"),
                    check["conclusion"].as_str().unwrap_or("Not supplied")
                );
                let id = SharedString::from(format!("github-check-{number}-{index}"));
                // Swift's check rows with a run open it in the browser.
                body = body.child(match check_link(check) {
                    Some(url) => Button::new(id)
                        .label(format!("{line} ↗"))
                        .ghost()
                        .tooltip(format!("Open {name} in the browser"))
                        .on_click(move |_, _, cx| cx.open_url(&url))
                        .into_any_element(),
                    None => div().id(id).text_sm().child(line).into_any_element(),
                });
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
        } else {
            if self.list.is_empty() && !self.busy {
                body = body.child("No pull requests loaded for this filter.");
            }
            let panel = cx.entity().downgrade();
            for pr in &self.list {
                let number = pr["number"].as_u64().unwrap_or(0);
                let head = text(pr, "headRefOid");
                let url = browser_link(&text(pr, "url")).map(str::to_owned);
                let panel = panel.clone();
                body = body.child(
                    div()
                        .id(SharedString::from(format!("github-pr-row-{number}")))
                        .child(
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
                        )
                        // Swift's PR row menu. Check Out in New Thread is not connected yet.
                        .context_menu(move |menu, _, _| {
                            let Some(url) = url.clone() else {
                                return menu;
                            };
                            let (opened, copied, panel) = (url.clone(), url.clone(), panel.clone());
                            menu.item(
                                PopupMenuItem::new("Open in Browser")
                                    .icon(gpui_kit::assets::IconName::ExternalLink)
                                    .on_click(move |_, _, cx| cx.open_url(&opened)),
                            )
                            .item(
                                PopupMenuItem::new("Copy Link")
                                    .icon(gpui_kit::assets::IconName::Link)
                                    .on_click(move |_, _, cx| {
                                        cx.write_to_clipboard(ClipboardItem::new_string(
                                            copied.clone(),
                                        ))
                                    }),
                            )
                            .item(
                                PopupMenuItem::new("Mention in Message")
                                    .icon(gpui_kit::assets::IconName::Hash)
                                    .on_click(move |_, _, cx| {
                                        if let Some(mention) = mention_markdown(number, &url) {
                                            let _ = panel.update(cx, |_, cx| {
                                                cx.emit(ReviewPanelEvent::Mention(mention))
                                            });
                                        }
                                    }),
                            )
                            .separator()
                            .item(
                                PopupMenuItem::new("Check Out in New Thread")
                                    .icon(gpui_kit::assets::IconName::GitBranch)
                                    .disabled(true),
                            )
                        }),
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
        Binding, Involvement, LIMIT, Request, View, abbreviated, browser_link, check_link, current,
        fetch, mention_insertion, mention_markdown, open_draft, repository, validate_payload,
    };
    use anyhow::Result;
    use serde_json::{Value, json};
    #[::core::prelude::v1::test]
    fn browser_links_and_mentions_match_swift_and_refuse_unsafe_urls() {
        let url = "https://github.com/owner/repo/pull/12";
        assert_eq!(browser_link(url), Some(url));
        for unsafe_url in [
            "http://github.com/owner/repo/pull/12",
            "https://user:pass@github.com/owner/repo/pull/12",
            "https:///pull/12",
            "https://github.com/a b",
            "javascript:alert(1)",
        ] {
            assert_eq!(browser_link(unsafe_url), None, "{unsafe_url}");
        }
        assert_eq!(
            mention_markdown(12, url).as_deref(),
            Some("[#12](https://github.com/owner/repo/pull/12)")
        );
        assert_eq!(
            mention_markdown(3, "https://example.com/a(b)<c>\\d").as_deref(),
            Some("[#3](https://example.com/a%28b%29%3Cc%3E%5Cd)")
        );
        assert_eq!(mention_markdown(3, "http://example.com"), None);
    }
    #[::core::prelude::v1::test]
    fn mention_is_spaced_from_a_preceding_word_only() {
        assert_eq!(mention_insertion("", 0, "[#1](u)"), "[#1](u) ");
        assert_eq!(mention_insertion("see", 3, "[#1](u)"), " [#1](u) ");
        assert_eq!(mention_insertion("see ", 4, "[#1](u)"), "[#1](u) ");
        assert_eq!(
            mention_insertion("café", "café".len(), "[#1](u)"),
            " [#1](u) "
        );
        assert_eq!(mention_insertion("a\n", 2, "[#1](u)"), "[#1](u) ");
    }
    #[::core::prelude::v1::test]
    fn check_runs_open_their_safe_link_and_drafts_offer_ready_for_review() {
        let run = json!({"name":"CI","detailsUrl":"https://github.com/o/r/actions/runs/1"});
        assert_eq!(
            check_link(&run).as_deref(),
            Some("https://github.com/o/r/actions/runs/1")
        );
        let status =
            json!({"context":"ci/x","detailsUrl":null,"targetUrl":"https://ci.example/build/2"});
        assert_eq!(
            check_link(&status).as_deref(),
            Some("https://ci.example/build/2")
        );
        assert_eq!(check_link(&json!({"name":"CI","detailsUrl":null})), None);
        assert!(open_draft(&json!({"isDraft":true,"state":"OPEN"})));
        assert!(!open_draft(&json!({"isDraft":true,"state":"CLOSED"})));
        assert!(!open_draft(&json!({"isDraft": false, "state": "OPEN"})));
    }
    #[test]
    fn checkout_notice_abbreviates_the_home_folder_like_swift() {
        let variable = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
        let Some(home) = std::env::var_os(variable).map(std::path::PathBuf::from) else {
            return;
        };
        let worktree = home.join("worktrees").join("repo");
        assert_eq!(
            abbreviated(&worktree),
            std::path::Path::new("~")
                .join("worktrees")
                .join("repo")
                .display()
                .to_string()
        );
        assert_eq!(abbreviated(&home), "~");
        let outside = std::env::temp_dir().join("coincide-not-home");
        if !outside.starts_with(&home) {
            assert_eq!(abbreviated(&outside), outside.display().to_string());
        }
    }
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
}
