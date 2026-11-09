//! Native GitHub pull requests panel after Swift's PullRequestsViewController,
//! with a separate explicit action surface. Parent mounts this entity, calls
//! set_context on every thread/root change and set_visible as the panel shows
//! or hides. The selected folder's repository is discovered automatically; a
//! manual override remains under Choose repository. GitHub reads run in
//! one background worker, never GPUI render; only the saved filter touches the
//! Engine here, with try_lock, when the panel opens and when the user picks one.
//! Check Out in New Thread emits CheckoutOpened for the parent to select.
use crate::native_menu::AccessibleMenuExt as _;
use crate::worker_owner::{Admission, ShutdownStatus as ReadShutdownStatus, WorkerOwner};
use anyhow::{Context as _, Result, ensure};
use coincide_core::{
    api::{SharedEngine, call},
    github_checkout::Checkout,
};
use gpui_kit::{
    assets::IconName,
    base::Disableable,
    component::{
        ActiveTheme, Icon, Sizable, StyledExt,
        button::*,
        input::{Enter, Escape, Input, InputEvent, InputState, Textarea, TextareaState},
        menu::PopupMenuItem,
        spinner::Spinner,
        text::TextView,
        tooltip::Tooltip,
    },
    prelude::FluentBuilder,
    *,
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

#[path = "github_presentation.rs"]
mod presentation;
use crate::github_actions::{Action as WriteAction, ActionsEvent, ReviewEvent};
use presentation::{MergeMethod, Tone};

const LIMIT: usize = 30;
const STATES: &[&str] = &["open", "closed", "merged", "all"];
/// Swift's list cache age, and how old an open pull request's detail may get
/// before showing the panel or the app again reads it anew.
const FRESH: Duration = Duration::from_secs(30);
/// The saved filter in ui-state.json (Swift keeps it as "PullRequestFilter").
const FILTER_KEY: &str = "pullRequestFilter";
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
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
    fn parse(wire: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|involvement| involvement.wire() == wire)
    }
    /// Swift PullRequestFilter's titles, and the one Rust adds.
    fn label(self) -> &'static str {
        match self {
            Self::All => "All Pull Requests",
            Self::Authored => "My Pull Requests",
            Self::Assigned => "Assigned to Me",
            Self::ReviewRequested => "Review Requested",
        }
    }
    fn icon(self) -> IconName {
        match self {
            Self::All => IconName::GitPullRequest,
            Self::Authored => IconName::User,
            Self::Assigned => IconName::UserCheck,
            Self::ReviewRequested => IconName::Eye,
        }
    }
}
fn state_label(state: &str) -> &'static str {
    match state {
        "closed" => "Closed",
        "merged" => "Merged",
        "all" => "Any State",
        _ => "Open",
    }
}
/// The filter button's title: Swift's "Open Pull Requests", "My Pull Requests"
/// and "Review Requested" for open ones, and the state beside any other choice.
fn filter_title(state: &str, involvement: Involvement) -> String {
    match (state, involvement) {
        ("open", Involvement::All) => "Open Pull Requests".into(),
        ("all", Involvement::All) => "All Pull Requests".into(),
        (_, Involvement::All) => format!("{} Pull Requests", state_label(state)),
        ("open", involvement) => involvement.label().into(),
        (_, involvement) => format!("{} · {}", involvement.label(), state_label(state)),
    }
}
/// What an empty list says, in Swift's words for its three filters.
fn empty_list(state: &str, involvement: Involvement) -> (&'static str, &'static str) {
    match (state, involvement) {
        ("open", Involvement::All) => (
            "No Open Pull Requests",
            "Open pull requests of this repository show here.",
        ),
        ("open", Involvement::Authored) => (
            "No Pull Requests of Yours",
            "Pull requests you open in this repository show here.",
        ),
        ("open", Involvement::ReviewRequested) => (
            "No Reviews Requested",
            "Pull requests waiting on your review show here.",
        ),
        _ => (
            "No Pull Requests",
            "Pull requests matching this filter show here.",
        ),
    }
}
/// The saved filter, or Swift's default (open pull requests) when there is
/// none or it doesn't read.
fn saved_filter(document: &Value) -> (String, Involvement) {
    let saved = &document[FILTER_KEY];
    let state = saved["state"]
        .as_str()
        .filter(|state| STATES.contains(state))
        .unwrap_or("open");
    let involvement = saved["involvement"]
        .as_str()
        .and_then(Involvement::parse)
        .unwrap_or_default();
    (state.into(), involvement)
}
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Binding {
    thread: String,
    root: String,
    repository: String,
    involvement: Involvement,
}
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum View {
    List(String),
    Detail { number: u64, head: String },
}
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
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
    let payload = finish(api, b, &start)?;
    validate_payload(request, &payload)?;
    Ok(payload)
}
/// Polls one started read until its payload is ready.
fn finish(
    api: &mut impl FnMut(&str, Value) -> Result<Value>,
    b: &Binding,
    start: &Value,
) -> Result<Value> {
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
/// The merge methods the repository allows, for the Merge… menu. Swift falls
/// back to all three when they don't read, leaving GitHub the final word.
fn fetch_merge_methods(
    api: &mut impl FnMut(&str, Value) -> Result<Value>,
    b: &Binding,
) -> Vec<MergeMethod> {
    let all = vec![MergeMethod::Merge, MergeMethod::Squash, MergeMethod::Rebase];
    let read = (|| -> Result<Value> {
        let start = api(
            "github.repo.merge-methods",
            json!({"threadId":b.thread,"expectedRoot":b.root,"repository":b.repository}),
        )?;
        let payload = finish(api, b, &start)?;
        ensure!(
            payload["kind"] == "mergeMethods"
                && payload["threadId"] == b.thread
                && payload["repository"] == b.repository,
            "Merge settings belong to another repository"
        );
        Ok(payload)
    })();
    let methods = read
        .ok()
        .and_then(|payload| payload["methods"].as_array().cloned())
        .into_iter()
        .flatten()
        .filter_map(|method| method.as_str().and_then(MergeMethod::parse))
        .collect::<Vec<_>>();
    if methods.is_empty() { all } else { methods }
}
fn fetch_availability(
    api: &mut impl FnMut(&str, Value) -> Result<Value>,
    scope: &(String, String),
) -> Result<Value> {
    let start = api("github.pr.availability", json!({"threadId":scope.0}))?;
    ensure!(
        start["expectedRoot"] == scope.1,
        "Repository folder changed"
    );
    let binding = Binding {
        thread: scope.0.clone(),
        root: scope.1.clone(),
        repository: String::new(),
        involvement: Involvement::All,
    };
    let payload = finish(api, &binding, &start)?;
    ensure!(
        payload["kind"] == "availability"
            && payload["threadId"] == scope.0
            && payload["expectedRoot"] == scope.1,
        "Repository response belongs to another conversation"
    );
    Ok(payload)
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
pub struct ReviewShutdownStatus {
    pub read: ReadShutdownStatus,
    pub actions: Option<coincide_core::github_write::WriteShutdownStatus>,
    pub writes: Option<crate::github_write_transport::NativeWriteShutdownStatus>,
}
/// A list read for one exact binding and filter, shown at once next time
/// (Swift's cachedPullRequests) and read again once it is `FRESH` old.
struct CachedList {
    at: Instant,
    list: Vec<Value>,
    truncated: bool,
}
/// Swift's PullRequestReviewSheet, shown over the pull request.
struct ReviewSheet {
    number: u64,
    event: ReviewEvent,
    error: Option<String>,
    submitting: bool,
}
type ReadResult = (u64, Request, Result<Value>);
pub struct GitHubReviewPanel {
    engine: SharedEngine,
    scope: Option<(String, String)>,
    repository: Entity<InputState>,
    detected_repository: Option<String>,
    override_scope: Option<(String, String)>,
    discovery_attempted: bool,
    refresh_pending: bool,
    repository_editing: bool,
    setup_expanded: bool,
    discovery_tx: mpsc::Sender<(u64, (String, String), Result<Value>)>,
    discovery_rx: mpsc::Receiver<(u64, (String, String), Result<Value>)>,
    state: String,
    involvement: Involvement,
    filter_loaded: bool,
    generation: u64,
    active: Option<(u64, Request)>,
    busy: bool,
    workers: WorkerOwner,
    list: Vec<Value>,
    truncated: bool,
    cache: HashMap<Request, CachedList>,
    /// The row arrow keys move to; Return opens it.
    cursor: Option<usize>,
    selected: Option<(u64, String)>,
    detail: Option<Value>,
    detail_loaded_at: Option<Instant>,
    /// Reopen this pull request once the list shows its new head.
    reopen: Option<u64>,
    merge_methods: HashMap<String, Vec<MergeMethod>>,
    merge_confirm: Option<MergeMethod>,
    review: Option<ReviewSheet>,
    review_body: Entity<TextareaState>,
    /// A submitted review's text goes when the sheet next opens.
    clear_review: bool,
    /// The panel shows in the inspector (Swift reloads on appearing).
    visible: bool,
    notice: String,
    /// The last action's outcome, as Swift's result banner: text, failed.
    banner: Option<(String, bool)>,
    focus: FocusHandle,
    tx: mpsc::Sender<ReadResult>,
    rx: mpsc::Receiver<ReadResult>,
    checkout_tx: mpsc::Sender<CheckoutResult>,
    checkout_rx: mpsc::Receiver<CheckoutResult>,
    checkout_cancel: Arc<AtomicBool>,
    checking_out: Option<u64>,
    _poll: Option<Task<()>>,
    _repository_changes: Subscription,
    _review_changes: Subscription,
    _activation: Subscription,
    _action_events: Option<Subscription>,
    _action_changes: Option<Subscription>,
    actions: Option<Entity<crate::github_actions::GitHubActions>>,
    writes: Option<crate::github_write_transport::NativeWrites>,
    write_status: Option<crate::github_write_transport::Status>,
    actions_open: bool,
    scroll: ScrollHandle,
}
impl GitHubReviewPanel {
    pub fn new(engine: SharedEngine, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (tx, rx) = mpsc::channel();
        let (checkout_tx, checkout_rx) = mpsc::channel();
        let (discovery_tx, discovery_rx) = mpsc::channel();
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
            if matches!(event, InputEvent::PressEnter { .. }) {
                this.load_list(true, cx);
            }
            if matches!(event, InputEvent::Change) {
                if this.workers.closed() {
                    return;
                }
                this.override_scope = this.scope.clone();
                this.generation = this.generation.wrapping_add(1);
                this.active = None;
                this.detail = None;
                this.selected = None;
                this.cursor = None;
                this.list.clear();
                this.truncated = false;
                this.close_sheets();
                this.invalidate_actions(cx);
                this.notice = "Repository changed. Load its pull requests to continue.".into();
                cx.notify();
            }
        });
        let review_body = cx.new(|cx| {
            TextareaState::new(window, cx)
                .placeholder("Write your review…")
                .submit_on_enter(false)
        });
        let review_changes = cx.subscribe(&review_body, |_, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        });
        // Coming back to the app picks up what changed on GitHub meanwhile, at
        // most every thirty seconds, so switching apps doesn't run gh each time.
        let activation = cx.observe_window_activation(window, |this, window, cx| {
            if window.is_window_active() && this.visible {
                this.reload(false, cx);
            }
        });
        let mut panel = Self {
            engine,
            scope: None,
            repository,
            detected_repository: None,
            override_scope: None,
            discovery_attempted: false,
            refresh_pending: false,
            repository_editing: false,
            setup_expanded: false,
            discovery_tx,
            discovery_rx,
            state: "open".into(),
            involvement: Involvement::All,
            filter_loaded: false,
            generation: 0,
            active: None,
            busy: false,
            workers: WorkerOwner::default(),
            list: Vec::new(),
            truncated: false,
            cache: HashMap::new(),
            cursor: None,
            selected: None,
            detail: None,
            detail_loaded_at: None,
            reopen: None,
            merge_methods: HashMap::new(),
            merge_confirm: None,
            review: None,
            review_body,
            clear_review: false,
            visible: false,
            notice: "Choose a conversation to see its repository’s pull requests.".into(),
            banner: None,
            focus: cx.focus_handle(),
            tx,
            rx,
            checkout_tx,
            checkout_rx,
            checkout_cancel: Arc::new(AtomicBool::new(false)),
            checking_out: None,
            _poll: Some(poll),
            _repository_changes: repository_changes,
            _review_changes: review_changes,
            _activation: activation,
            _action_events: None,
            _action_changes: None,
            actions: None,
            writes: None,
            write_status: None,
            actions_open: false,
            scroll: ScrollHandle::new(),
        };
        panel.load_saved_filter();
        panel
    }
    pub fn attach_actions(
        &mut self,
        actions: Entity<crate::github_actions::GitHubActions>,
        writes: crate::github_write_transport::NativeWrites,
        cx: &mut Context<Self>,
    ) {
        self._action_events = Some(cx.subscribe(&actions, |this, _, event, cx| {
            let ActionsEvent::Finished(result) = event;
            this.finish_action(result.clone(), cx);
        }));
        // Merge… and Review… follow the action history as it loads.
        self._action_changes = Some(cx.observe(&actions, |_, _, cx| cx.notify()));
        self.actions = Some(actions);
        self.writes = Some(writes);
        if self.workers.closed() {
            self.request_shutdown(cx);
        } else {
            self.sync_action_scope(cx);
        }
    }
    /// The saved filter, read once the Engine is free (Swift UserDefaults).
    fn load_saved_filter(&mut self) {
        if self.filter_loaded {
            return;
        }
        let document = crate::try_state(&self.engine)
            .and_then(|engine| Ok(engine.store.document("ui-state.json")?.unwrap_or(json!({}))));
        match document {
            Ok(document) => {
                (self.state, self.involvement) = saved_filter(&document);
                self.filter_loaded = true;
            }
            Err(error) if crate::engine_busy(&error) => {}
            // A malformed document keeps Swift's default, unchanged on disk.
            Err(_) => self.filter_loaded = true,
        }
    }
    fn save_filter(&mut self) {
        let filter = json!({FILTER_KEY:{"state":self.state,"involvement":self.involvement.wire()}});
        let saved = crate::try_state(&self.engine)
            .and_then(|mut engine| engine.store.patch_document("ui-state.json", &filter));
        if saved.is_err() {
            self.banner = Some((
                "The filter applies now but wasn’t saved for next time.".into(),
                true,
            ));
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
            || self.repository_value(cx) != request.binding.repository
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
        self.detected_repository = None;
        self.override_scope = None;
        self.discovery_attempted = false;
        self.repository_editing = false;
        self.refresh_pending = true;
        self.invalidate_actions(cx);
        self.generation = self.generation.wrapping_add(1);
        self.active = None;
        self.list.clear();
        self.detail = None;
        self.selected = None;
        self.cursor = None;
        self.truncated = false;
        self.close_sheets();
        self.banner = None;
        self.notice = if self.busy {
            "Waiting for the previous read; its result will be discarded."
        } else {
            "Finding this folder’s GitHub repository…"
        }
        .into();
        // A repository already entered reloads for the new thread, as Swift's
        // panel does for the open thread's repository.
        if self.visible {
            self.reload(false, cx);
        }
        cx.notify();
    }
    /// Swift reloads when the panel appears. The parent calls this as it
    /// renders the inspector; only a change of visibility acts.
    pub fn set_visible(&mut self, visible: bool, cx: &mut Context<Self>) {
        if self.visible == visible || self.workers.closed() {
            return;
        }
        self.visible = visible;
        if visible {
            self.load_saved_filter();
            // Never start reads inside the parent's render pass.
            cx.spawn(async move |this, cx| {
                let _ = this.update(cx, |this, cx| this.reload(false, cx));
            })
            .detach();
        }
    }
    fn repository_value(&self, cx: &App) -> String {
        if self.override_scope.is_some() && self.override_scope == self.scope {
            self.repository.read(cx).value().trim().to_owned()
        } else {
            self.detected_repository.clone().unwrap_or_default()
        }
    }
    fn discover_repository(&mut self, cx: &mut Context<Self>) {
        if self.busy || !self.workers.can_start() {
            self.refresh_pending = true;
            return;
        }
        let Some(scope) = self.scope.clone() else {
            return;
        };
        self.discovery_attempted = true;
        self.busy = true;
        self.notice = "Finding this folder’s GitHub repository…".into();
        let generation = self.generation;
        let tx = self.discovery_tx.clone();
        let engine = self.engine.clone();
        if !self.workers.spawn(move |admission| {
            let result = (|| -> Result<Value> {
                ensure!(admission.allowed(), "GitHub panel closed");
                fetch_availability(
                    &mut |method, params| {
                        ensure!(admission.allowed(), "GitHub panel closed");
                        call(&engine, method, params)
                    },
                    &scope,
                )
            })();
            let _ = tx.send((generation, scope, result));
        }) {
            self.busy = false;
            self.notice = "Could not start repository discovery. Try Refresh.".into();
        }
        cx.notify();
    }
    fn close_sheets(&mut self) {
        self.merge_confirm = None;
        if self.review.as_ref().is_none_or(|sheet| !sheet.submitting) {
            self.review = None;
        }
    }
    /// Reads what is showing again: the open pull request once its detail is
    /// `FRESH` old (checks finish without the list changing), otherwise the
    /// list, which shows its cached copy at once. `force` reads regardless.
    fn reload(&mut self, force: bool, cx: &mut Context<Self>) {
        if self.busy || self.performing(cx) || self.workers.closed() {
            return;
        }
        if self.scope.is_none() {
            return;
        }
        if !self::repository(&self.repository_value(cx)) {
            if self.override_scope.is_some() && self.override_scope == self.scope {
                self.notice = "Enter a GitHub repository as owner/name.".into();
                cx.notify();
                return;
            }
            if force || !self.discovery_attempted {
                self.discover_repository(cx);
            }
            return;
        }
        match self.selected.clone() {
            Some((number, head)) => {
                if force || self.detail_loaded_at.is_none_or(|at| at.elapsed() >= FRESH) {
                    self.load_detail(number, head, cx);
                }
            }
            None => self.load_list(force, cx),
        }
    }
    /// A merge or review is on its way to GitHub; reads wait for its outcome.
    fn performing(&self, cx: &App) -> bool {
        self.review.as_ref().is_some_and(|sheet| sheet.submitting)
            || self
                .actions
                .as_ref()
                .is_some_and(|actions| actions.read(cx).performing())
    }
    fn select_filter(&mut self, state: &str, involvement: Involvement, cx: &mut Context<Self>) {
        if self.busy || self.workers.closed() {
            return;
        }
        if self.state == state && self.involvement == involvement {
            return;
        }
        self.state = state.into();
        self.involvement = involvement;
        self.filter_loaded = true;
        self.save_filter();
        self.invalidate_actions(cx);
        self.generation = self.generation.wrapping_add(1);
        self.active = None;
        self.list.clear();
        self.detail = None;
        self.selected = None;
        self.cursor = None;
        self.truncated = false;
        self.load_list(false, cx);
        cx.notify();
    }
    fn list_request(&mut self, cx: &mut Context<Self>) -> Option<Request> {
        let (thread, root) = self.scope.clone()?;
        let repository = self.repository_value(cx);
        if !self::repository(&repository) {
            self.invalidate_actions(cx);
            self.list.clear();
            self.detail = None;
            self.selected = None;
            self.active = None;
            self.truncated = false;
            if !self.discovery_attempted {
                self.discover_repository(cx);
            }
            cx.notify();
            return None;
        }
        Some(Request {
            binding: Binding {
                thread,
                root,
                repository,
                involvement: self.involvement,
            },
            view: View::List(self.state.clone()),
        })
    }
    fn load_list(&mut self, force: bool, cx: &mut Context<Self>) {
        if self.busy || !self.workers.can_start() {
            return;
        }
        let Some(request) = self.list_request(cx) else {
            return;
        };
        self.selected = None;
        self.detail = None;
        self.detail_loaded_at = None;
        self.close_sheets();
        // Swift shows the last list read for this filter at once.
        if let Some(cached) = self.cache.get(&request) {
            let fresh = cached.at.elapsed() < FRESH;
            self.list = cached.list.clone();
            self.truncated = cached.truncated;
            self.clamp_cursor();
            if !force && fresh && self.reopen.is_none() {
                self.invalidate_actions(cx);
                self.generation = self.generation.wrapping_add(1);
                self.active = Some((self.generation, request));
                self.notice.clear();
                cx.notify();
                return;
            }
        } else {
            self.list.clear();
            self.truncated = false;
            self.cursor = None;
        }
        self.start(request, cx);
    }
    fn load_detail(&mut self, number: u64, head: String, cx: &mut Context<Self>) {
        if self.busy || !self.workers.can_start() {
            return;
        }
        let Some((_, active)) = &self.active else {
            return;
        };
        let binding = active.binding.clone();
        // A refresh of the same pull request keeps showing it meanwhile.
        if self
            .selected
            .as_ref()
            .is_none_or(|(shown, _)| *shown != number)
        {
            self.detail = None;
            self.merge_confirm = None;
        }
        self.selected = Some((number, head.clone()));
        self.detail_loaded_at = Some(Instant::now());
        self.start(
            Request {
                binding,
                view: View::Detail { number, head },
            },
            cx,
        );
    }
    fn open_row(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(pr) = self.list.get(index) else {
            return;
        };
        let number = pr["number"].as_u64().unwrap_or(0);
        let head = text(pr, "headRefOid");
        self.cursor = Some(index);
        self.banner = None;
        self.load_detail(number, head, cx);
        window.focus(&self.focus, cx);
    }
    /// Escape and the back button: from a pull request to the list.
    fn back(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.selected.is_none() || self.busy || self.workers.closed() {
            return;
        }
        self.selected = None;
        self.detail = None;
        self.detail_loaded_at = None;
        self.close_sheets();
        self.invalidate_actions(cx);
        self.load_list(false, cx);
        window.focus(&self.focus, cx);
        cx.notify();
    }
    fn clamp_cursor(&mut self) {
        self.cursor = match self.cursor {
            _ if self.list.is_empty() => None,
            Some(index) => Some(index.min(self.list.len() - 1)),
            None => None,
        };
    }
    /// Swift PullRequestTableView: arrows move through the rows, Return or
    /// Enter opens one, and Escape goes back from a pull request.
    fn key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        // Only the panel itself, never the repository field or the review box.
        if !self.focus.is_focused(window) {
            return;
        }
        let modifiers = event.keystroke.modifiers;
        if modifiers.platform || modifiers.control || modifiers.alt {
            return;
        }
        match event.keystroke.key.as_str() {
            "escape" if self.merge_confirm.is_some() => self.merge_confirm = None,
            "escape" if self.selected.is_some() => self.back(window, cx),
            "up" | "down" if self.selected.is_none() && !self.list.is_empty() => {
                let last = self.list.len() - 1;
                self.cursor = Some(match (self.cursor, event.keystroke.key.as_str()) {
                    (None, "up") => last,
                    (None, _) => 0,
                    (Some(index), "up") => index.saturating_sub(1),
                    (Some(index), _) => (index + 1).min(last),
                });
            }
            "enter" if self.selected.is_none() => {
                if let Some(index) = self.cursor {
                    self.open_row(index, window, cx);
                }
            }
            _ => return,
        }
        cx.stop_propagation();
        cx.notify();
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
        // The Merge… menu lists the repository's methods, read once per repository.
        let methods = match &request.view {
            View::Detail { .. } => !self.merge_methods.contains_key(&request.binding.repository),
            View::List(_) => false,
        };
        let engine = self.engine.clone();
        let tx = self.tx.clone();
        if !self.workers.spawn(move |admission| {
            let mut result = fetch_admitted(
                &mut |method, params| call(&engine, method, params),
                &request,
                &admission,
            );
            if methods && let Ok(payload) = &mut result {
                let methods = fetch_merge_methods(
                    &mut |method, params| {
                        ensure!(admission.allowed(), "GitHub UI read admissions are closed");
                        call(&engine, method, params)
                    },
                    &request.binding,
                );
                payload["mergeMethods"] = json!(
                    methods
                        .into_iter()
                        .map(MergeMethod::wire)
                        .collect::<Vec<_>>()
                );
            }
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
            self.cache.clear();
            self.truncated = false;
            self.actions_open = false;
            self.merge_confirm = None;
            self.review = None;
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
        while self.discovery_rx.try_recv().is_ok() {
            self.busy = false;
        }
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
        while let Ok((generation, scope, result)) = self.discovery_rx.try_recv() {
            self.busy = false;
            if self.generation != generation || self.scope.as_ref() != Some(&scope) {
                self.refresh_pending = true;
                continue;
            }
            match result {
                Ok(payload) if payload["state"] == "ready" => {
                    let repository = payload["repository"].as_str().unwrap_or_default();
                    if self::repository(repository) {
                        self.detected_repository = Some(repository.into());
                        self.notice.clear();
                        self.refresh_pending = true;
                    } else {
                        self.notice = "The repository address could not be read.".into();
                    }
                }
                Ok(payload) => {
                    self.notice = match payload["state"].as_str() {
                        Some("notRepository") => "This folder is not a Git repository.",
                        Some("noRemote") => {
                            "Add a GitHub remote to this repository to see its pull requests."
                        }
                        Some("needsGitHubCli") => {
                            "Sign in with GitHub CLI (gh auth login), then Refresh."
                        }
                        Some("unsupportedHost") => {
                            "This repository’s host is not supported by the GitHub panel."
                        }
                        _ => "Could not find this repository. Try Refresh or choose a repository.",
                    }
                    .into();
                }
                Err(error) => self.notice = format!("Could not load the repository: {error}"),
            }
            cx.notify();
        }
        if self.refresh_pending && !self.busy && self.visible && self.workers.can_start() {
            self.refresh_pending = false;
            self.reload(false, cx);
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
                    self.clamp_cursor();
                    self.cache.insert(
                        request.clone(),
                        CachedList {
                            at: Instant::now(),
                            list: self.list.clone(),
                            truncated: self.truncated,
                        },
                    );
                    // A pull request whose head moved opens again on its new head.
                    if let Some(number) = self.reopen.take()
                        && let Some(index) = self
                            .list
                            .iter()
                            .position(|pr| pr["number"].as_u64() == Some(number))
                    {
                        let head = text(&self.list[index], "headRefOid");
                        self.cursor = Some(index);
                        self.load_detail(number, head, cx);
                        return;
                    }
                }
                View::Detail { .. } => {
                    let pr = payload["pullRequest"].clone();
                    if let Some(methods) = payload["mergeMethods"].as_array() {
                        self.merge_methods.insert(
                            request.binding.repository.clone(),
                            methods
                                .iter()
                                .filter_map(|method| method.as_str().and_then(MergeMethod::parse))
                                .collect(),
                        );
                    }
                    if !presentation::can_merge(&pr) {
                        self.merge_confirm = None;
                    }
                    self.detail = Some(pr);
                    self.detail_loaded_at = Some(Instant::now());
                }
            },
            Err(error) => {
                let moved = error.to_string().starts_with("head_changed");
                if let (View::Detail { number, .. }, true) = (&request.view, moved) {
                    // New commits: read the list for the new head, then reopen.
                    self.reopen = Some(*number);
                    self.selected = None;
                    self.detail = None;
                    self.sync_action_scope(cx);
                    self.load_list(true, cx);
                    return;
                }
                self.reopen = None;
                // Swift keeps what it showed and reports the failure; any
                // write still reads a fresh baseline first.
                self.banner = Some((format!("{error}. Refresh to retry."), true));
            }
        }
        self.sync_action_scope(cx);
        cx.notify();
    }
    /// A Merge… or Review… came back from GitHub: report it as Swift's banner
    /// does, then read the pull request and the list again.
    fn finish_action(
        &mut self,
        result: std::result::Result<String, String>,
        cx: &mut Context<Self>,
    ) {
        match result {
            Ok(message) => {
                self.banner = Some((message, false));
                if self.review.take().is_some() {
                    self.clear_review = true;
                }
                self.merge_confirm = None;
                self.cache.clear();
                self.reload(true, cx);
            }
            Err(error) => {
                // A failed review keeps the sheet and its text, with the error.
                if let Some(sheet) = &mut self.review {
                    sheet.submitting = false;
                    sheet.error = Some(error);
                } else {
                    self.banner = Some((error, true));
                }
            }
        }
        cx.notify();
    }
    fn actions_ready(&self, cx: &App) -> bool {
        self.validated_loaded_scope(cx).is_some()
            && self.write_status == Some(crate::github_write_transport::Status::Ready)
            && self
                .actions
                .as_ref()
                .is_some_and(|actions| actions.read(cx).ready())
    }
    fn merge(&mut self, method: MergeMethod, cx: &mut Context<Self>) {
        self.merge_confirm = None;
        if !self.actions_ready(cx) {
            return;
        }
        let Some(actions) = self.actions.clone() else {
            return;
        };
        let started = actions.update(cx, |actions, cx| {
            actions.perform(WriteAction::Merge(method.wire().into()), cx)
        });
        if let Err(error) = started {
            self.banner = Some((error.to_string(), true));
        }
        cx.notify();
    }
    fn open_review(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(number) = self.selected.as_ref().map(|(number, _)| *number) else {
            return;
        };
        if self.clear_review
            || self
                .review
                .as_ref()
                .is_some_and(|sheet| sheet.number != number)
        {
            self.clear_review = false;
            self.review_body
                .update(cx, |input, cx| input.set_value("", window, cx));
        }
        self.merge_confirm = None;
        self.review = Some(ReviewSheet {
            number,
            event: self
                .review
                .as_ref()
                .filter(|sheet| sheet.number == number)
                .map_or(ReviewEvent::Comment, |sheet| sheet.event),
            error: None,
            submitting: false,
        });
        self.review_body
            .update(cx, |input, cx| input.focus(window, cx));
        cx.notify();
    }
    fn cancel_review(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.review.as_ref().is_some_and(|sheet| sheet.submitting) {
            return;
        }
        self.review = None;
        window.focus(&self.focus, cx);
        cx.notify();
    }
    fn submit_review(&mut self, cx: &mut Context<Self>) {
        let body = self.review_body.read(cx).value().to_string();
        let ready = self.actions_ready(cx);
        let Some(sheet) = &mut self.review else {
            return;
        };
        if sheet.submitting || !sheet.event.accepts(&body) || !ready {
            return;
        }
        let event = sheet.event;
        let Some(actions) = self.actions.clone() else {
            return;
        };
        let started = actions.update(cx, |actions, cx| {
            actions.perform(WriteAction::Review(event, body), cx)
        });
        if let Some(sheet) = &mut self.review {
            match started {
                Ok(()) => {
                    sheet.submitting = true;
                    sheet.error = None;
                }
                Err(error) => sheet.error = Some(error.to_string()),
            }
        }
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
fn tone(tone: Tone, cx: &App) -> Hsla {
    let theme = cx.theme();
    match tone {
        Tone::Success => theme.success,
        Tone::Failure => theme.danger,
        Tone::Warning => theme.warning,
        Tone::Merged => theme.magenta,
        Tone::Muted => theme.muted_foreground,
        Tone::Faint => theme.muted_foreground.opacity(0.6),
    }
}
/// A glyph with what it says as its tooltip, as Swift's row icons have.
fn glyph_icon(id: impl Into<ElementId>, glyph: presentation::Glyph, cx: &App) -> AnyElement {
    let label = glyph.label;
    div()
        .id(id)
        .flex_none()
        .tooltip(move |window, cx| Tooltip::new(label).build(window, cx))
        .child(
            Icon::new(glyph.icon)
                .xsmall()
                .text_color(tone(glyph.tone, cx)),
        )
        .into_any_element()
}
fn line(icon: impl IntoElement, label: impl Into<SharedString>, color: Hsla) -> Div {
    div()
        .flex()
        .items_center()
        .gap_1p5()
        .min_w_0()
        .text_sm()
        .text_color(color)
        .child(div().flex_none().w(px(16.)).child(icon))
        .child(div().min_w_0().truncate().child(label.into()))
}
impl GitHubReviewPanel {
    fn header(&self, cx: &mut Context<Self>) -> Div {
        let muted = cx.theme().muted_foreground;
        let mut header = div()
            .flex()
            .flex_none()
            .items_center()
            .gap_1p5()
            .min_h(px(32.))
            .min_w_0();
        let disabled = self.busy || self.workers.closed();
        if let Some((number, _)) = &self.selected {
            let title = self
                .detail
                .as_ref()
                .or_else(|| {
                    self.list
                        .iter()
                        .find(|pr| pr["number"].as_u64() == Some(*number))
                })
                .map(|pr| text(pr, "title"))
                .unwrap_or_default();
            header = header
                .child(
                    Button::new("github-back")
                        .icon(IconName::ChevronLeft)
                        .ghost()
                        .compact()
                        .tooltip("All Pull Requests")
                        .accessibility_label("All Pull Requests")
                        .disabled(disabled)
                        .on_click(cx.listener(|this, _, window, cx| this.back(window, cx))),
                )
                .child(
                    div()
                        .id("github-detail-number")
                        .font_semibold()
                        .tooltip(move |window, cx| Tooltip::new(title.clone()).build(window, cx))
                        .child(format!("#{number}")),
                );
        } else {
            let parent = cx.entity().downgrade();
            let (state, involvement) = (self.state.clone(), self.involvement);
            header = header.child(
                Button::new("github-filter")
                    .label(filter_title(&self.state, self.involvement))
                    .ghost()
                    .compact()
                    .dropdown_caret(true)
                    .accessibility_label("Pull requests to show")
                    .disabled(disabled)
                    .accessible_menu(move |mut menu, _, _| {
                        for option in Involvement::ALL {
                            let parent = parent.clone();
                            let state = state.clone();
                            menu = menu.item(
                                PopupMenuItem::new(option.label())
                                    .icon(option.icon())
                                    .checked(option == involvement)
                                    .on_click(move |_, _, cx| {
                                        let _ = parent.update(cx, |this, cx| {
                                            this.select_filter(&state, option, cx)
                                        });
                                    }),
                            );
                        }
                        menu = menu.separator();
                        for option in STATES {
                            let parent = parent.clone();
                            menu = menu.item(
                                PopupMenuItem::new(state_label(option))
                                    .checked(*option == state)
                                    .on_click(move |_, _, cx| {
                                        let _ = parent.update(cx, |this, cx| {
                                            this.select_filter(option, involvement, cx)
                                        });
                                    }),
                            );
                        }
                        menu
                    }),
            );
            if !self.list.is_empty() {
                header = header.child(
                    div()
                        .text_sm()
                        .text_color(muted)
                        .child(self.list.len().to_string()),
                );
            }
        }
        header = header.child(div().flex_1());
        if self.selected.is_none() {
            let repo = self.repository_value(cx);
            if !repo.is_empty() {
                header = header.child(
                    div()
                        .min_w_0()
                        .max_w(px(180.))
                        .truncate()
                        .text_xs()
                        .text_color(muted)
                        .child(repo),
                );
            }
        }
        header = header.child(
            Button::new("github-choose-repository")
                .icon(IconName::Settings2)
                .ghost()
                .compact()
                .accessibility_label("Choose repository")
                .tooltip("Choose repository")
                .on_click(cx.listener(|this, _, window, cx| {
                    this.repository_editing = !this.repository_editing;
                    if this.repository_editing {
                        let value = this.repository_value(cx);
                        this.repository
                            .update(cx, |input, cx| input.set_value(value, window, cx));
                    }
                    cx.notify();
                })),
        );
        if self.busy || self.performing(cx) {
            header = header.child(Spinner::new().xsmall().color(muted));
        }
        if let Some(pr) = &self.detail {
            let url = text(pr, "url");
            header = header.child(
                Button::new("github-open-browser")
                    .icon(IconName::ExternalLink)
                    .ghost()
                    .compact()
                    .tooltip("Open in Browser")
                    .accessibility_label("Open in Browser")
                    .on_click(move |_, _, cx| cx.open_url(&url)),
            );
        }
        header.child(
            Button::new("github-refresh")
                .icon(IconName::RefreshCw)
                .ghost()
                .compact()
                .tooltip("Refresh")
                .accessibility_label("Refresh")
                .disabled(disabled || self.scope.is_none())
                .on_click(cx.listener(|this, _, _, cx| {
                    this.banner = None;
                    this.reload(true, cx);
                    if this.active.is_none() && !this.busy {
                        this.load_list(true, cx);
                    }
                })),
        )
    }
    fn row(&self, index: usize, pr: &Value, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.theme();
        let (ink, muted, hover, active) = (
            theme.foreground,
            theme.muted_foreground,
            theme.list_hover,
            theme.list_active,
        );
        let number = pr["number"].as_u64().unwrap_or(0);
        let state = presentation::state(pr);
        let checks =
            presentation::checks_state(&pr["statusCheckRollup"]).map(|state| state.glyph());
        let review = presentation::review_decision(pr).map(|decision| decision.glyph());
        let meta = presentation::row_meta(pr);
        let title = text(pr, "title");
        let spoken = [Some(title.as_str()), Some(meta.as_str()), Some(state.label)]
            .into_iter()
            .chain([
                checks.map(|glyph| glyph.label),
                review.map(|glyph| glyph.label),
            ])
            .flatten()
            .collect::<Vec<_>>()
            .join(", ");
        let now = coincide_core::store::swift_timestamp() + 978_307_200.;
        let mut first = div().flex().items_center().gap_1p5().min_w_0().child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_sm()
                .font_medium()
                .text_color(if pr["isDraft"] == true { muted } else { ink })
                .child(excerpt(&title, 180)),
        );
        if let Some(glyph) = checks {
            first = first.child(glyph_icon(
                SharedString::from(format!("github-pr-checks-{number}")),
                glyph,
                cx,
            ));
        }
        if let Some(glyph) = review {
            first = first.child(glyph_icon(
                SharedString::from(format!("github-pr-review-{number}")),
                glyph,
                cx,
            ));
        }
        div()
            .id(SharedString::from(format!("github-pr-{number}")))
            .role(gpui_kit::Role::Button)
            .aria_label(spoken)
            .flex()
            .items_center()
            .gap_2()
            .px_3()
            .py_1p5()
            .rounded_md()
            .cursor_pointer()
            .hover(move |style| style.bg(hover))
            .when(self.cursor == Some(index), move |row| row.bg(active))
            .child(
                div().flex_none().w(px(16.)).child(
                    Icon::new(state.icon)
                        .small()
                        .text_color(tone(state.tone, cx)),
                ),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap_0p5()
                    .child(first)
                    .child(
                        div()
                            .flex()
                            .gap_1p5()
                            .min_w_0()
                            .text_xs()
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_color(muted)
                                    .child(meta),
                            )
                            .child(
                                div()
                                    .flex_none()
                                    .text_color(muted.opacity(0.7))
                                    .child(presentation::age(&pr["updatedAt"], now)),
                            ),
                    ),
            )
            .on_click(cx.listener(move |this, _, window, cx| {
                if !this.busy && !this.workers.closed() {
                    this.open_row(index, window, cx);
                }
            }))
            .into_any_element()
    }
    fn list_body(&self, cx: &mut Context<Self>) -> Div {
        let muted = cx.theme().muted_foreground;
        let mut body = div().flex().flex_col().gap_0p5();
        if self.list.is_empty() && (self.active.is_none() || !self.notice.is_empty()) {
            return body.child(
                div()
                    .flex()
                    .flex_col()
                    .items_center()
                    .text_center()
                    .gap_2()
                    .px_4()
                    .py_8()
                    .child(Icon::new(IconName::GitPullRequest).text_color(muted))
                    .child(div().font_semibold().child(if self.busy {
                        "Loading pull requests…"
                    } else if self.scope.is_none() {
                        "No conversation selected"
                    } else {
                        "Pull requests"
                    }))
                    .child(div().text_sm().text_color(muted).child(self.notice.clone())),
            );
        }
        if self.list.is_empty() && !self.busy && self.active.is_some() {
            let (title, explanation) = empty_list(&self.state, self.involvement);
            return body.child(
                div()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap_1()
                    .py_8()
                    .child(Icon::new(self.involvement.icon()).text_color(muted))
                    .child(div().font_semibold().child(title))
                    .child(div().text_sm().text_color(muted).child(explanation)),
            );
        }
        for (index, pr) in self.list.iter().enumerate() {
            body = body.child(self.row(index, pr, cx));
        }
        if self.truncated {
            body = body.child(div().px_3().py_2().text_xs().text_color(muted).child(format!(
                "Showing the first {LIMIT} pull requests. Choose a narrower filter to see others."
            )));
        }
        body
    }
    fn detail_body(&self, cx: &mut Context<Self>) -> Div {
        let theme = cx.theme();
        let (muted, warning) = (theme.muted_foreground, theme.warning);
        let Some((number, _)) = &self.selected else {
            return div();
        };
        let number = *number;
        let loaded = self.detail.as_ref();
        // The row's summary shows at once; checks and the description follow.
        let Some(pr) = loaded.or_else(|| {
            self.list
                .iter()
                .find(|pr| pr["number"].as_u64() == Some(number))
        }) else {
            return div().text_sm().text_color(muted).child("Loading…");
        };
        let state = presentation::state(pr);
        let open = pr["state"] == "OPEN";
        let draft = pr["isDraft"] == true;
        let mut body = div()
            .flex()
            .flex_col()
            .gap_1p5()
            .min_w_0()
            .px_1()
            .child(div().text_lg().font_semibold().child(text(pr, "title")))
            .child(line(
                Icon::new(state.icon)
                    .small()
                    .text_color(tone(state.tone, cx)),
                presentation::byline(pr),
                muted,
            ))
            .child(
                div()
                    .id("github-detail-branches")
                    .text_xs()
                    .font_family("monospace")
                    .text_color(muted)
                    .truncate()
                    .child(format!(
                        "{} → {}",
                        text(pr, "headRefName"),
                        text(pr, "baseRefName")
                    )),
            );
        if let Some(stats) = loaded.and_then(presentation::stats) {
            body = body.child(div().text_xs().text_color(muted).child(stats));
        }
        if let Some(glyph) = presentation::review_decision(pr).map(|decision| decision.glyph()) {
            body = body.child(line(
                Icon::new(glyph.icon)
                    .small()
                    .text_color(tone(glyph.tone, cx)),
                glyph.label,
                muted,
            ));
        }
        if let Some(glyph) =
            presentation::checks_state(&pr["statusCheckRollup"]).map(|state| state.glyph())
        {
            body = body.child(line(
                Icon::new(glyph.icon)
                    .small()
                    .text_color(tone(glyph.tone, cx)),
                glyph.label,
                muted,
            ));
        }
        if loaded.is_some_and(presentation::conflicting) {
            body = body.child(line(
                Icon::new(IconName::TriangleAlert)
                    .small()
                    .text_color(warning),
                format!("Conflicts with {}", text(pr, "baseRefName")),
                warning,
            ));
        }
        if open {
            body = body.child(self.actions_row(pr, draft, cx));
        }
        if let Some(sheet) = self
            .merge_confirm
            .map(|method| self.merge_sheet(method, pr, cx))
        {
            body = body.child(sheet);
        }
        if let Some(sheet) = self.review_sheet(cx) {
            body = body.child(sheet);
        }
        body = body.child(div().h(px(1.)).my_2().bg(cx.theme().border));
        let checks = loaded.map(|pr| presentation::checks(&pr["statusCheckRollup"]));
        body = body.child(div().text_xs().font_semibold().text_color(muted).child(
            match checks.as_ref().map(Vec::len) {
                Some(count) if count > 0 => format!("Checks ({count})"),
                _ => "Checks".into(),
            },
        ));
        match &checks {
            None => body = body.child(div().text_sm().text_color(muted).child("Loading…")),
            Some(checks) if checks.is_empty() => {
                body = body.child(
                    div()
                        .text_sm()
                        .text_color(muted)
                        .child("No checks ran on this pull request."),
                )
            }
            Some(checks) => {
                for (index, check) in checks.iter().enumerate() {
                    body = body.child(self.check_row(number, index, check, cx));
                }
            }
        }
        body = body
            .child(div().h(px(1.)).my_2().bg(cx.theme().border))
            .child(
                div()
                    .text_xs()
                    .font_semibold()
                    .text_color(muted)
                    .child("Description"),
            );
        match loaded.map(|pr| presentation::display_markdown(pr["body"].as_str().unwrap_or(""))) {
            None => body = body.child(div().text_sm().text_color(muted).child("Loading…")),
            Some(description) if description.is_empty() => {
                body = body.child(
                    div()
                        .text_sm()
                        .text_color(muted)
                        .child("No description provided."),
                )
            }
            Some(description) => {
                body = body.child(TextView::markdown(
                    SharedString::from(format!("github-pr-description-{number}")),
                    description,
                ))
            }
        }
        let reviews = loaded
            .and_then(|pr| pr["reviews"].as_array())
            .into_iter()
            .flatten()
            .filter(|review| review["state"] != "PENDING")
            .take(100)
            .collect::<Vec<_>>();
        if !reviews.is_empty() {
            body = body.child(
                div()
                    .mt_3()
                    .text_xs()
                    .font_semibold()
                    .text_color(muted)
                    .child("Reviews"),
            );
            for (index, review) in reviews.into_iter().enumerate() {
                let author = review["author"]["login"].as_str().unwrap_or("—");
                let review_body = review["body"].as_str().unwrap_or("");
                body = body.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .mt_1()
                        .child(div().text_sm().font_medium().child(format!(
                            "{author} · {}",
                            presentation::review_state(review["state"].as_str().unwrap_or(""))
                        )))
                        .when(!review_body.is_empty(), |row| {
                            row.child(TextView::markdown(
                                SharedString::from(format!("github-pr-review-{number}-{index}")),
                                review_body.to_owned(),
                            ))
                        }),
                );
            }
        }
        body
    }
    fn actions_row(&self, pr: &Value, draft: bool, cx: &mut Context<Self>) -> Div {
        let ready = self.actions_ready(cx);
        let idle = !self.busy && !self.performing(cx) && !self.workers.closed();
        let mut row = div().flex().flex_wrap().gap_2().mt_2();
        if !draft {
            let methods = self
                .active
                .as_ref()
                .and_then(|(_, request)| self.merge_methods.get(&request.binding.repository))
                .cloned()
                .unwrap_or_default();
            let parent = cx.entity().downgrade();
            let can_merge = self.detail.is_some() && presentation::can_merge(pr);
            row = row.child(
                Button::new("github-merge")
                    .label("Merge…")
                    .primary()
                    .small()
                    .disabled(!idle || !ready || !can_merge || methods.is_empty())
                    .accessible_menu(move |mut menu, _, _| {
                        for method in &methods {
                            let parent = parent.clone();
                            let method = *method;
                            menu = menu.item(PopupMenuItem::new(method.title()).on_click(
                                move |_, _, cx| {
                                    let _ = parent.update(cx, |this, cx| {
                                        this.review = None;
                                        this.merge_confirm = Some(method);
                                        cx.notify();
                                    });
                                },
                            ));
                        }
                        menu
                    }),
            );
        }
        row = row
            .child(
                Button::new("github-checkout")
                    .label(if self.checking_out == Some(pr["number"].as_u64().unwrap_or(0)) {
                        "Checking out…"
                    } else {
                        "Check Out in New Thread"
                    })
                    .small()
                    .tooltip("Creates a worktree on this pull request’s branch and opens a new thread in it")
                    .disabled(!idle)
                    .on_click(cx.listener(|this, _, _, cx| this.check_out(cx))),
            )
            .child(
                Button::new("github-review")
                    .label("Review…")
                    .small()
                    .disabled(!idle || !ready || self.detail.is_none())
                    .on_click(cx.listener(|this, _, window, cx| this.open_review(window, cx))),
            )
            .child(
                Button::new("github-open-actions")
                    .label("Action History…")
                    .ghost()
                    .small()
                    .tooltip("Every write sent for this pull request, and its outcome")
                    .disabled(
                        !idle
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
            );
        row
    }
    /// Swift's merge warning: one confirmation, then the merge.
    fn merge_sheet(&self, method: MergeMethod, pr: &Value, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.theme();
        let number = pr["number"].as_u64().unwrap_or(0);
        div()
            .flex()
            .flex_col()
            .gap_2()
            .mt_2()
            .p_3()
            .rounded_md()
            .border_1()
            .border_color(theme.warning)
            .child(div().font_semibold().child(method.question(number)))
            .child(
                div()
                    .text_sm()
                    .text_color(theme.muted_foreground)
                    .child(format!(
                        "“{}” is merged into {} on GitHub. Its branch is kept.",
                        text(pr, "title"),
                        text(pr, "baseRefName")
                    )),
            )
            .child(
                div()
                    .flex()
                    .justify_end()
                    .gap_2()
                    .child(
                        Button::new("github-merge-cancel")
                            .label("Cancel")
                            .small()
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.merge_confirm = None;
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("github-merge-confirm")
                            .label("Merge")
                            .primary()
                            .small()
                            .disabled(!self.actions_ready(cx))
                            .on_click(cx.listener(move |this, _, _, cx| this.merge(method, cx))),
                    ),
            )
            .into_any_element()
    }
    /// Swift's PullRequestReviewSheet: an outcome, a message, ⌘Return to
    /// submit and Esc to cancel. A failure keeps the text and shows inline.
    fn review_sheet(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let sheet = self.review.as_ref()?;
        let theme = cx.theme();
        let (border, danger) = (theme.border, theme.danger);
        let body = self.review_body.read(cx).value().to_string();
        let submittable = !sheet.submitting && sheet.event.accepts(&body) && self.actions_ready(cx);
        let parent = cx.entity().downgrade();
        let selected = sheet.event;
        let mut card = div()
            .id("github-review-sheet")
            .flex()
            .flex_col()
            .gap_3()
            .mt_2()
            .p_3()
            .rounded_md()
            .border_1()
            .border_color(border)
            .capture_action(cx.listener(|this, action: &Enter, window, cx| {
                if action.secondary {
                    window.prevent_default();
                    cx.stop_propagation();
                    this.submit_review(cx);
                }
            }))
            .capture_action(cx.listener(|this, _: &Escape, window, cx| {
                cx.stop_propagation();
                this.cancel_review(window, cx);
            }))
            .child(
                div()
                    .font_semibold()
                    .child(format!("Review pull request #{}", sheet.number)),
            )
            .child(
                Button::new("github-review-outcome")
                    .label(sheet.event.title())
                    .small()
                    .dropdown_caret(true)
                    .accessibility_label("Review outcome")
                    .disabled(sheet.submitting)
                    .accessible_menu(move |mut menu, _, _| {
                        for event in ReviewEvent::ALL {
                            let parent = parent.clone();
                            menu = menu.item(
                                PopupMenuItem::new(event.title())
                                    .checked(event == selected)
                                    .on_click(move |_, _, cx| {
                                        let _ = parent.update(cx, |this, cx| {
                                            if let Some(sheet) = &mut this.review
                                                && !sheet.submitting
                                            {
                                                sheet.event = event;
                                                cx.notify();
                                            }
                                        });
                                    }),
                            );
                        }
                        menu
                    }),
            )
            .child(
                Textarea::new(&self.review_body)
                    .h(px(160.))
                    .disabled(sheet.submitting),
            );
        if let Some(error) = &sheet.error {
            card = card.child(div().text_sm().text_color(danger).child(error.clone()));
        }
        Some(
            card.child(
                div()
                    .flex()
                    .justify_end()
                    .gap_2()
                    .child(
                        Button::new("github-review-cancel")
                            .label("Cancel")
                            .small()
                            .disabled(sheet.submitting)
                            .on_click(
                                cx.listener(|this, _, window, cx| this.cancel_review(window, cx)),
                            ),
                    )
                    .child(
                        Button::new("github-review-submit")
                            .label("Submit Review")
                            .primary()
                            .small()
                            .disabled(!submittable)
                            .on_click(cx.listener(|this, _, _, cx| this.submit_review(cx))),
                    ),
            )
            .into_any_element(),
        )
    }
    fn check_row(
        &self,
        number: u64,
        index: usize,
        check: &presentation::Check,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = cx.theme();
        let (muted, hover) = (theme.muted_foreground, theme.list_hover);
        let glyph = check.status.glyph();
        let url = check.url.clone();
        let tooltip = match &url {
            Some(_) => format!("Open {} in the browser", check.name),
            None => check.name.clone(),
        };
        div()
            .id(SharedString::from(format!("github-check-{number}-{index}")))
            .aria_label(format!("{}, {}", check.name, glyph.label))
            .flex()
            .items_center()
            .gap_1p5()
            .px_1p5()
            .py_1()
            .rounded_md()
            .min_w_0()
            .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
            .child(
                div().flex_none().w(px(14.)).child(
                    Icon::new(glyph.icon)
                        .xsmall()
                        .text_color(tone(glyph.tone, cx)),
                ),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_sm()
                    .child(check.name.clone()),
            )
            .child(
                div()
                    .flex_none()
                    .text_xs()
                    .text_color(muted)
                    .child(glyph.label),
            )
            .when_some(url, |row, url| {
                row.cursor_pointer()
                    .hover(move |style| style.bg(hover))
                    .child(
                        Icon::new(IconName::ArrowUpRight)
                            .xsmall()
                            .text_color(muted.opacity(0.6)),
                    )
                    .on_click(move |_, _, cx| cx.open_url(&url))
            })
            .into_any_element()
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
        let theme = cx.theme();
        let (muted, border, danger, success) = (
            theme.muted_foreground,
            theme.border,
            theme.danger,
            theme.success,
        );
        let mut pane = div()
            .id("github-review-panel")
            .track_focus(&self.focus)
            .on_key_down(cx.listener(|this, event, window, cx| this.key(event, window, cx)))
            .size_full()
            .min_h_0()
            .min_w_0()
            .overflow_hidden()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .when(self.repository_editing, |pane| {
                pane.child(Input::new(&self.repository).small())
            })
            .child(self.header(cx))
            .child(div().h(px(1.)).flex_none().bg(border));
        if self.selected.is_some()
            && let Some(status) = &self.write_status
        {
            let message = match status {
                crate::github_write_transport::Status::Opening => Some("Opening the local GitHub action ledger…".into()),
                crate::github_write_transport::Status::Initializing => Some("Initializing the local ledger. No GitHub request is made.".into()),
                crate::github_write_transport::Status::FirstSetup => Some("First setup: initialize a private local action ledger before merging or reviewing. If this app previously sent GitHub actions, restore its original ledger instead.".into()),
                crate::github_write_transport::Status::Ready => None,
                crate::github_write_transport::Status::Failed(error) => Some(format!("GitHub actions unavailable: {error}. Restore the original ledger; it will not be recreated automatically.")),
            };
            if self.setup_expanded
                && let Some(message) = message
            {
                pane = pane.child(div().flex_none().text_xs().text_color(muted).child(message));
            }
            if status == &crate::github_write_transport::Status::FirstSetup {
                pane = pane.child(Button::new("github-write-first-setup").label(if self.setup_expanded { "Enable GitHub actions" } else { "Set up merge and review actions…" }).small()
                    .on_click(cx.listener(|this, _, _, cx| {
                        if !this.setup_expanded { this.setup_expanded = true; cx.notify(); return; }
                        if this.workers.closed() { return; }
                        if let Some(writes) = &this.writes
                            && !writes.initialize_from_user_action()
                        { this.notice = "Ledger setup is busy or no longer available. No action was queued.".into(); }
                        cx.notify();
                    })));
            }
        }
        if !self.notice.is_empty() && self.selected.is_some() {
            pane = pane.child(
                div()
                    .flex_none()
                    .text_sm()
                    .text_color(muted)
                    .child(self.notice.clone()),
            );
        }
        if let Some((message, failed)) = &self.banner {
            pane = pane.child(
                div()
                    .id("github-result-banner")
                    .flex_none()
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_2()
                    .py_1p5()
                    .rounded_md()
                    .border_1()
                    .border_color(if *failed { danger } else { success })
                    .child(div().flex_1().text_sm().child(message.clone()))
                    .child(
                        Button::new("github-result-dismiss")
                            .icon(IconName::Close)
                            .ghost()
                            .xsmall()
                            .accessibility_label("Dismiss")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.banner = None;
                                cx.notify();
                            })),
                    ),
            );
        }
        let body = if self.selected.is_some() {
            self.detail_body(cx)
        } else {
            self.list_body(cx)
        };
        pane.child(
            div()
                .id("github-review-scroll")
                .flex_1()
                .flex_basis(px(0.))
                .min_h_0()
                .min_w_0()
                .overflow_y_scroll()
                .track_scroll(&self.scroll)
                .child(body.w_full().min_w_0().flex_none()),
        )
        .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Binding, Involvement, LIMIT, Request, View, abbreviated, current, fetch, repository,
        validate_payload,
    };
    use anyhow::Result;
    use serde_json::{Value, json};
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
    fn saved_filter_reads_back_and_falls_back_to_open_pull_requests() {
        use super::{filter_title, saved_filter};
        assert_eq!(
            saved_filter(
                &json!({"pullRequestFilter":{"state":"merged","involvement":"review-requested"}})
            ),
            ("merged".to_owned(), Involvement::ReviewRequested)
        );
        for document in [
            json!({}),
            json!({"pullRequestFilter":"open"}),
            json!({"pullRequestFilter":{"state":"mine","involvement":"--author @me"}}),
        ] {
            assert_eq!(
                saved_filter(&document),
                ("open".to_owned(), Involvement::All)
            );
        }
        assert_eq!(filter_title("open", Involvement::All), "Open Pull Requests");
        assert_eq!(
            filter_title("open", Involvement::Authored),
            "My Pull Requests"
        );
        assert_eq!(
            filter_title("open", Involvement::ReviewRequested),
            "Review Requested"
        );
        assert_eq!(
            filter_title("closed", Involvement::All),
            "Closed Pull Requests"
        );
        assert_eq!(filter_title("all", Involvement::All), "All Pull Requests");
        assert_eq!(
            filter_title("merged", Involvement::Authored),
            "My Pull Requests · Merged"
        );
        assert_eq!(
            super::empty_list("open", Involvement::Authored).0,
            "No Pull Requests of Yours"
        );
    }
    #[::core::prelude::v1::test]
    fn merge_menu_lists_the_repository_methods_or_all_when_they_dont_read() {
        use super::{MergeMethod, fetch_merge_methods};
        let binding = request(View::List("open".into())).binding;
        let mut calls = Vec::new();
        let methods = fetch_merge_methods(
            &mut |method, params| -> Result<Value> {
                calls.push((method.to_owned(), params));
                Ok(if method == "github.repo.merge-methods" {
                    json!({"operationId":"op-methods"})
                } else {
                    json!({"ready":true,"result":{"kind":"mergeMethods","threadId":"thread-a","repository":"fixture/repo","methods":["squash","rebase"]}})
                })
            },
            &binding,
        );
        assert_eq!(methods, [MergeMethod::Squash, MergeMethod::Rebase]);
        assert_eq!(
            calls[0].1,
            json!({"threadId":"thread-a","expectedRoot":binding.root,"repository":"fixture/repo"})
        );
        // Another repository's answer, or a failed read, leaves GitHub to decide.
        for reply in [
            json!({"ready":true,"result":{"kind":"mergeMethods","threadId":"thread-a","repository":"fixture/other","methods":["squash"]}}),
            json!({"ready":true,"result":{"code":"read_failed","error":"Unable to read"}}),
        ] {
            let methods = fetch_merge_methods(
                &mut |method, _| -> Result<Value> {
                    Ok(if method == "github.repo.merge-methods" {
                        json!({"operationId":"op"})
                    } else {
                        reply.clone()
                    })
                },
                &binding,
            );
            assert_eq!(
                methods,
                [MergeMethod::Merge, MergeMethod::Squash, MergeMethod::Rebase]
            );
        }
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

#[cfg(test)]
mod repository_discovery_tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn availability_is_automatic_and_bound_to_the_selected_folder() {
        let scope = ("thread".to_owned(), "/workspace/project".to_owned());
        let mut methods = Vec::new();
        let result = fetch_availability(&mut |method, params| {
            methods.push(method.to_owned());
            assert_eq!(params["threadId"], "thread");
            if method == "github.pr.availability" {
                Ok(json!({"operationId":"discovery", "expectedRoot":"/workspace/project"}))
            } else {
                assert_eq!(params["expectedRoot"], "/workspace/project");
                Ok(json!({"ready":true,"result":{"kind":"availability","threadId":"thread","expectedRoot":"/workspace/project","state":"ready","repository":"owner/project"}}))
            }
        }, &scope).unwrap();
        assert_eq!(result["repository"], "owner/project");
        assert_eq!(methods, ["github.pr.availability", "github.result"]);
    }
    #[::core::prelude::v1::test]
    fn discovery_rejects_replies_from_another_conversation_or_root() {
        let scope = ("thread".to_owned(), "/workspace/project".to_owned());
        for (thread, root) in [("other", "/workspace/project"), ("thread", "/other")] {
            assert!(fetch_availability(&mut |method, _| {
                Ok(if method == "github.pr.availability" {json!({"operationId":"d","expectedRoot":"/workspace/project"})} else {json!({"ready":true,"result":{"kind":"availability","threadId":thread,"expectedRoot":root,"state":"ready","repository":"owner/project"}})})
            }, &scope).is_err());
        }
    }
}
