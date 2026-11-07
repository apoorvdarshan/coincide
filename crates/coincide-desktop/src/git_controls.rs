//! The git action bar at the foot of the Git workspace and the branch toolbar under
//! the composer (Swift GitActionsBar, GitResultBanner, CommitSheetController,
//! BranchToolbarView and BranchPickerController). Git runs in the engine
//! (`git.actions.*`, `git.branches.*`, `git.worktrees.*`). One worker reads status,
//! one lists branches and one runs actions, so the UI never waits on git; results
//! of an action that finished while another thread was shown wait for that thread.
use super::*;
use crate::worker_owner::{Admission, ShutdownStatus as WorkerShutdown, WorkerOwner};
use coincide_core::git_actions::{
    FollowUp, GitBranch, GitBranchList, GitPullRequest, GitStatus, StackedAction, host::Term, names,
};
use std::{
    collections::{HashMap, HashSet},
    sync::mpsc,
};

#[path = "git_controls_view.rs"]
mod view;

/// Successes leave after ten seconds; failures stay until dismissed.
const BANNER_LIFETIME: Duration = Duration::from_secs(10);

/// Where the selected thread runs, read from its stored record.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Binding {
    thread: Option<String>,
    folder: Option<String>,
    worktree: Option<String>,
    branch: Option<String>,
    started: bool,
    running: bool,
}

#[derive(Clone, Debug, Default)]
struct Toolbar {
    base_branch: Option<String>,
    preparing: bool,
    previous: Option<(String, Option<String>)>,
}

struct Read {
    status: Option<GitStatus>,
    host_name: Option<String>,
    term: Term,
    toolbar: Toolbar,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum BannerAction {
    Run(StackedAction),
    Open(String),
    OpenPage(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Banner {
    pub title: String,
    pub detail: Option<String>,
    pub error: bool,
    pub action: Option<(String, BannerAction)>,
}

struct ShownBanner {
    banner: Banner,
    shown: Instant,
}

/// What a finished toolbar operation changes once it reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ToolbarOp {
    Checkout,
    NewWorktree,
    Workspace,
}

enum Message {
    Read {
        generation: u64,
        result: Result<Read, String>,
    },
    PullRequest {
        generation: u64,
        branch: String,
        pull_request: Option<GitPullRequest>,
    },
    Branches {
        token: u64,
        result: Result<GitBranchList, String>,
    },
    Progress {
        thread: String,
        label: String,
    },
    Finished {
        thread: String,
        banner: Option<Banner>,
        /// A host page to open at once while the thread is shown.
        open: Option<String>,
    },
    ToolbarFinished {
        thread: String,
        error: Option<Banner>,
    },
}

pub(super) struct CommitSheet {
    pub thread: String,
    pub branch: Option<String>,
    pub is_default: bool,
    pub files: Vec<coincide_core::git_actions::ChangedFile>,
    pub excluded: HashSet<String>,
}

pub(super) struct Confirm {
    pub thread: String,
    pub action: StackedAction,
    pub message: Option<String>,
    pub paths: Option<Vec<String>>,
    pub branch: String,
    pub can_branch: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum PickerMode {
    /// Check out the picked branch (or create one) in the thread's folder.
    Checkout,
    /// Pick the branch a new worktree starts from.
    Base,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum PickerRow {
    Header(&'static str),
    Branch(GitBranch),
    Create(String),
}

pub(super) struct Picker {
    pub thread: String,
    pub mode: PickerMode,
    pub token: u64,
    pub list: Option<GitBranchList>,
    pub footer: String,
    pub rows: Vec<PickerRow>,
    pub highlighted: Option<usize>,
    pub selected_name: Option<String>,
}

/// The rows for a search: "Create branch" from the text (checkout only), then the
/// Local and Remote sections (Swift BranchPickerController.rebuild).
pub(super) fn picker_rows(
    list: Option<&GitBranchList>,
    raw: &str,
    mode: PickerMode,
) -> Vec<PickerRow> {
    let query = raw.trim().to_lowercase();
    let sanitized = names::sanitize_new_ref_name(&query);
    let matches = |branch: &&GitBranch| {
        let name = branch.name.to_lowercase();
        query.is_empty()
            || name.contains(&query)
            || (!sanitized.is_empty() && name.contains(&sanitized))
    };
    let mut rows = Vec::new();
    if mode == PickerMode::Checkout
        && !query.is_empty()
        && !list.is_some_and(|list| {
            list.local()
                .any(|branch| branch.name.to_lowercase() == sanitized)
        })
    {
        rows.push(PickerRow::Create(names::sanitize_new_ref_name(raw)));
    }
    let Some(list) = list else {
        return rows;
    };
    let local: Vec<&GitBranch> = list.local().filter(matches).collect();
    let remote: Vec<&GitBranch> = list.remote().filter(matches).collect();
    if !local.is_empty() {
        rows.push(PickerRow::Header("Local"));
        rows.extend(local.into_iter().cloned().map(PickerRow::Branch));
    }
    if !remote.is_empty() {
        rows.push(PickerRow::Header("Remote"));
        rows.extend(remote.into_iter().cloned().map(PickerRow::Branch));
    }
    rows
}

/// The next selectable row from `from`, skipping headers.
pub(super) fn picker_move(rows: &[PickerRow], from: Option<usize>, down: bool) -> Option<usize> {
    let mut row = from.map_or(if down { -1 } else { rows.len() as isize }, |row| {
        row as isize
    });
    loop {
        row += if down { 1 } else { -1 };
        let index = usize::try_from(row).ok().filter(|row| *row < rows.len())?;
        if !matches!(rows[index], PickerRow::Header(_)) {
            return Some(index);
        }
    }
}

/// "↑2 ↓1 #12" beside the branch.
pub(super) fn sync_label(
    status: &GitStatus,
    pull_request: Option<&GitPullRequest>,
    term: Term,
) -> String {
    let mut parts = Vec::new();
    if status.ahead > 0 {
        parts.push(format!("↑{}", status.ahead));
    }
    if status.behind > 0 {
        parts.push(format!("↓{}", status.behind));
    }
    if let Some(pull_request) = pull_request {
        parts.push(term.reference(pull_request.number));
    }
    parts.join(" ")
}

/// The branch tooltip: the branch, what it tracks and its pull request.
pub(super) fn branch_tooltip(
    status: &GitStatus,
    pull_request: Option<&GitPullRequest>,
    term: Term,
) -> String {
    let mut tooltip = status
        .branch
        .clone()
        .unwrap_or_else(|| "HEAD is not on a branch.".into());
    if let Some(upstream) = &status.upstream {
        tooltip.push_str(&format!("\nTracks {upstream}"));
    }
    if let Some(pull_request) = pull_request {
        tooltip.push('\n');
        tooltip.push_str(&term.summary(pull_request.number, &pull_request.title));
    }
    tooltip
}

fn host_page(url: &str, allow_http: bool) -> bool {
    url.strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://").filter(|_| allow_http))
        .is_some_and(|rest| !rest.is_empty() && !rest.starts_with('/'))
}

/// The banner for an action's result, with its follow-up (Swift showResult).
pub(super) fn result_banner(result: &Value) -> Banner {
    let term: Term =
        serde_json::from_value(result["changeRequestTerm"].clone()).unwrap_or_default();
    let follow_up: Option<FollowUp> = serde_json::from_value(result["followUp"].clone())
        .ok()
        .flatten();
    let action = follow_up.map(|follow_up| match follow_up {
        FollowUp::Run(next) => (
            if next == StackedAction::Push {
                "Push".to_owned()
            } else {
                StackedAction::CreatePr.title(term).to_owned()
            },
            BannerAction::Run(next),
        ),
        FollowUp::OpenPullRequest(url) => {
            (term.view_button_title().to_owned(), BannerAction::Open(url))
        }
        FollowUp::OpenChangeRequestPage(url) => (
            format!("Open {}", result["hostName"].as_str().unwrap_or("")),
            BannerAction::OpenPage(url),
        ),
    });
    Banner {
        title: text(result, "title"),
        detail: result["detail"]
            .as_str()
            .filter(|d| !d.is_empty())
            .map(str::to_owned),
        error: false,
        action,
    }
}

fn failure_banner(value: &Value) -> Banner {
    Banner {
        title: value["error"]
            .as_str()
            .unwrap_or("The Git action failed.")
            .to_owned(),
        detail: value["detail"]
            .as_str()
            .filter(|d| !d.is_empty())
            .map(str::to_owned),
        error: true,
        action: None,
    }
}

fn engine_call(
    engine: &SharedEngine,
    admission: &Admission,
    method: &str,
    params: Value,
) -> Result<Value> {
    anyhow::ensure!(admission.allowed(), "Coincide is quitting");
    coincide_core::api::call(engine, method, params)
}

/// Starts an engine Git operation and waits for its result, reporting each step.
/// Direct replies (no operation) are returned as they are.
fn engine_op(
    engine: &SharedEngine,
    admission: &Admission,
    method: &str,
    params: Value,
    progress: &dyn Fn(&str),
) -> Result<Value> {
    let thread = params["threadId"].clone();
    let started = engine_call(engine, admission, method, params)?;
    let Some(id) = started["operationId"].as_str().map(str::to_owned) else {
        return Ok(started);
    };
    // Longer than the engine keeps an operation, so its own expiry reports first.
    let deadline = Instant::now() + Duration::from_secs(46 * 60);
    let mut step = String::new();
    loop {
        let reply = engine_call(
            engine,
            admission,
            "git.actions.result",
            json!({"threadId":thread,"operationId":id}),
        )?;
        if reply["ready"] == true {
            return Ok(reply["result"].clone());
        }
        if let Some(label) = reply["progress"].as_str()
            && label != step
        {
            step = label.to_owned();
            progress(label);
        }
        anyhow::ensure!(
            Instant::now() < deadline,
            "The Git action did not finish. Refresh before trying again."
        );
        std::thread::sleep(Duration::from_millis(80));
    }
}

pub(super) struct GitControls {
    engine: SharedEngine,
    binding: Binding,
    generation: u64,
    status: Option<GitStatus>,
    status_folder: Option<String>,
    host_name: Option<String>,
    term: Term,
    pull_request: Option<GitPullRequest>,
    toolbar: Toolbar,
    read_pending: bool,
    reads: WorkerOwner,
    lists: WorkerOwner,
    actions: WorkerOwner,
    /// The thread the running action belongs to. Only one action runs at a time.
    action_thread: Option<String>,
    toolbar_op: Option<ToolbarOp>,
    progress: Option<String>,
    banner: Option<ShownBanner>,
    deferred: HashMap<String, Banner>,
    commit: Option<CommitSheet>,
    confirm: Option<Confirm>,
    alert: Option<Banner>,
    picker: Option<Picker>,
    picker_token: u64,
    message: Entity<TextareaState>,
    search: Entity<InputState>,
    restore_focus: Option<FocusHandle>,
    tx: mpsc::Sender<Message>,
    rx: mpsc::Receiver<Message>,
    _subscriptions: Vec<Subscription>,
}

impl GitControls {
    pub(super) fn new(
        engine: SharedEngine,
        window: &mut Window,
        cx: &mut Context<Coincide>,
    ) -> Self {
        let (tx, rx) = mpsc::channel();
        let message = cx.new(|cx| {
            TextareaState::new(window, cx)
                .placeholder("Leave empty to generate a message")
                .submit_on_enter(false)
        });
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search branches"));
        let subscriptions = vec![cx.subscribe_in(
            &search,
            window,
            |this: &mut Coincide, _, event: &InputEvent, window, cx| match event {
                InputEvent::Change => this.git_picker_search_changed(cx),
                InputEvent::PressEnter { .. } => {
                    let row = this
                        .git_controls
                        .picker
                        .as_ref()
                        .and_then(|p| p.highlighted);
                    if let Some(row) = row {
                        this.git_pick(row, window, cx);
                    }
                }
                _ => {}
            },
        )];
        Self {
            engine,
            binding: Binding::default(),
            generation: 0,
            status: None,
            status_folder: None,
            host_name: None,
            term: Term::PullRequest,
            pull_request: None,
            toolbar: Toolbar::default(),
            read_pending: false,
            reads: WorkerOwner::default(),
            lists: WorkerOwner::default(),
            actions: WorkerOwner::default(),
            action_thread: None,
            toolbar_op: None,
            progress: None,
            banner: None,
            deferred: HashMap::new(),
            commit: None,
            confirm: None,
            alert: None,
            picker: None,
            picker_token: 0,
            message,
            search,
            restore_focus: None,
            tx,
            rx,
            _subscriptions: subscriptions,
        }
    }

    pub(super) fn request_refresh(&mut self) {
        if self.binding.thread.is_some() {
            self.read_pending = true;
        }
    }

    pub(super) fn request_shutdown(&mut self) {
        self.reads.close();
        self.lists.close();
        self.actions.close();
        self.read_pending = false;
        for _ in self.rx.try_iter() {}
    }

    /// One status for the three workers: drained only when all are.
    pub(super) fn shutdown_status(&mut self) -> WorkerShutdown {
        for _ in self.rx.try_iter() {}
        let [reads, lists, actions] = [
            self.reads.status(),
            self.lists.status(),
            self.actions.status(),
        ];
        WorkerShutdown {
            closed: reads.closed && lists.closed && actions.closed,
            unjoined: reads.unjoined + lists.unjoined + actions.unjoined,
            returned: reads.returned + lists.returned + actions.returned,
            panicked: reads.panicked + lists.panicked + actions.panicked,
            unclassified: reads.unclassified + lists.unclassified + actions.unclassified,
            pending_pickers: reads.pending_pickers
                + lists.pending_pickers
                + actions.pending_pickers,
            spawn_error: reads
                .spawn_error
                .or(lists.spawn_error)
                .or(actions.spawn_error),
        }
    }

    fn busy(&self) -> bool {
        self.action_thread.is_some()
    }

    fn show(&mut self, banner: Banner) {
        self.banner = Some(ShownBanner {
            banner,
            shown: Instant::now(),
        });
    }

    fn start_read(&mut self) {
        let Some(thread) = self.binding.thread.clone() else {
            return;
        };
        if !self.reads.can_start() {
            self.read_pending = true;
            return;
        }
        self.read_pending = false;
        let (engine, tx, generation) = (self.engine.clone(), self.tx.clone(), self.generation);
        self.reads.spawn(move |admission| {
            let read = (|| -> Result<Read> {
                let params = json!({"threadId":thread});
                let toolbar =
                    engine_call(&engine, &admission, "git.toolbar.state", params.clone())?;
                let reply = engine_op(&engine, &admission, "git.actions.status", params, &|_| {})?;
                anyhow::ensure!(reply["error"].is_null(), "{}", text(&reply, "error"));
                Ok(Read {
                    status: serde_json::from_value(reply["status"].clone()).ok(),
                    host_name: reply["hostName"].as_str().map(str::to_owned),
                    term: serde_json::from_value(reply["changeRequestTerm"].clone())
                        .unwrap_or_default(),
                    toolbar: Toolbar {
                        base_branch: toolbar["baseBranch"].as_str().map(str::to_owned),
                        preparing: toolbar["preparing"] == true,
                        previous: toolbar["previousWorktree"]["path"].as_str().map(|path| {
                            (
                                path.to_owned(),
                                toolbar["previousWorktree"]["branch"]
                                    .as_str()
                                    .map(str::to_owned),
                            )
                        }),
                    },
                })
            })();
            let branch = read.as_ref().ok().and_then(|read| {
                read.status
                    .as_ref()
                    .filter(|status| status.has_upstream())
                    .and_then(|status| status.branch.clone())
            });
            let _ = tx.send(Message::Read {
                generation,
                result: read.map_err(|error| error.to_string()),
            });
            // The pull request needs the network, so it follows the status.
            if let Some(branch) = branch {
                let pull_request = engine_op(
                    &engine,
                    &admission,
                    "git.actions.pullRequest",
                    json!({"threadId":thread,"branch":branch}),
                    &|_| {},
                )
                .ok()
                .and_then(|reply| serde_json::from_value(reply["pullRequest"].clone()).ok());
                let _ = tx.send(Message::PullRequest {
                    generation,
                    branch,
                    pull_request,
                });
            }
        });
    }
}

impl Coincide {
    /// Follows the selected thread. Cheap and idempotent: called on every render.
    pub(super) fn sync_git_controls(&mut self, cx: &mut Context<Self>) {
        let binding = match &self.selected {
            None => Binding::default(),
            Some(thread) => {
                let id = text(thread, "id");
                let worktree = thread["worktreePath"].as_str().map(str::to_owned);
                Binding {
                    folder: worktree.clone().or_else(|| {
                        self.projects
                            .iter()
                            .find(|project| {
                                project["id"] == thread["projectID"] && project["isChats"] != true
                            })
                            .and_then(|project| project["path"].as_str())
                            .map(str::to_owned)
                    }),
                    worktree,
                    branch: thread["branch"].as_str().map(str::to_owned),
                    started: thread["items"]
                        .as_array()
                        .is_some_and(|items| items.iter().any(|item| item["kind"] == "user")),
                    running: self.running.contains(&id),
                    thread: Some(id),
                }
            }
        };
        let controls = &mut self.git_controls;
        if controls.binding == binding {
            return;
        }
        let previous = std::mem::replace(&mut controls.binding, binding.clone());
        if previous.thread != binding.thread {
            controls.generation = controls.generation.wrapping_add(1);
            controls.status = None;
            controls.status_folder = None;
            controls.pull_request = None;
            controls.host_name = None;
            controls.toolbar = Toolbar::default();
            controls.banner = None;
            controls.commit = None;
            controls.confirm = None;
            controls.alert = None;
            controls.picker = None;
            // An action that finished while another thread was shown reports now.
            if let Some(thread) = &binding.thread
                && let Some(report) = controls.deferred.remove(thread)
            {
                controls.show(report);
            }
            controls.request_refresh();
        } else if previous.folder != binding.folder
            || previous.running != binding.running
            || previous.started != binding.started
        {
            // A turn starting or ending, or the thread moving, needs another look.
            controls.generation = controls.generation.wrapping_add(1);
            controls.request_refresh();
        }
        cx.notify();
    }

    pub(super) fn poll_git_controls(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let controls = &mut self.git_controls;
        controls.reads.poll();
        controls.lists.poll();
        controls.actions.poll();
        if controls.reads.closed() {
            return;
        }
        let mut changed = false;
        if controls
            .banner
            .as_ref()
            .is_some_and(|shown| !shown.banner.error && shown.shown.elapsed() >= BANNER_LIFETIME)
        {
            controls.banner = None;
            changed = true;
        }
        let messages: Vec<Message> = controls.rx.try_iter().collect();
        for message in messages {
            changed = true;
            self.git_message(message, window, cx);
        }
        let controls = &mut self.git_controls;
        if controls.read_pending {
            controls.start_read();
        }
        if changed {
            cx.notify();
        }
    }

    fn git_message(&mut self, message: Message, window: &mut Window, cx: &mut Context<Self>) {
        let current = self.git_controls.binding.thread.clone();
        let controls = &mut self.git_controls;
        match message {
            Message::Read { generation, result } => {
                if generation != controls.generation {
                    return;
                }
                match result {
                    Ok(read) => {
                        if read.status.as_ref().and_then(|s| s.branch.as_ref())
                            != controls.status.as_ref().and_then(|s| s.branch.as_ref())
                        {
                            controls.pull_request = None;
                        }
                        controls.status = read.status;
                        controls.status_folder = controls.binding.folder.clone();
                        controls.host_name = read.host_name;
                        controls.term = read.term;
                        controls.toolbar = read.toolbar;
                    }
                    Err(_) => {
                        // Not a repository, or no folder: both surfaces hide.
                        controls.status = None;
                        controls.pull_request = None;
                    }
                }
            }
            Message::PullRequest {
                generation,
                branch,
                pull_request,
            } => {
                if generation == controls.generation
                    && controls.status.as_ref().and_then(|s| s.branch.as_deref())
                        == Some(branch.as_str())
                {
                    controls.pull_request = pull_request;
                }
            }
            Message::Branches { token, result } => {
                if let Some(picker) = controls
                    .picker
                    .as_mut()
                    .filter(|picker| picker.token == token)
                {
                    match result {
                        Ok(list) => {
                            picker.footer = match picker.mode {
                                PickerMode::Checkout => {
                                    "Checking out changes the branch of the project folder."
                                }
                                PickerMode::Base => "The new worktree starts from this branch.",
                            }
                            .into();
                            picker.list = Some(list);
                        }
                        Err(error) => {
                            picker.list = Some(GitBranchList {
                                is_repository: true,
                                ..GitBranchList::default()
                            });
                            picker.footer = error;
                        }
                    }
                    self.git_picker_search_changed(cx);
                }
            }
            Message::Progress { thread, label } => {
                if controls.action_thread.as_deref() == Some(thread.as_str()) {
                    controls.progress = Some(label);
                }
            }
            Message::Finished {
                thread,
                banner,
                open,
            } => {
                controls.action_thread = None;
                controls.progress = None;
                controls.generation = controls.generation.wrapping_add(1);
                controls.request_refresh();
                if current.as_deref() == Some(thread.as_str()) {
                    // Without a signed-in CLI the pull request is finished on the host's
                    // page, opened at once; the banner's button opens it again.
                    if let Some(page) = open.filter(|page| host_page(page, false)) {
                        cx.open_url(&page);
                    }
                    if let Some(banner) = banner {
                        self.git_controls.show(banner);
                    }
                } else if let Some(banner) = banner {
                    controls.deferred.insert(thread, banner);
                }
            }
            Message::ToolbarFinished { thread, error } => {
                controls.action_thread = None;
                controls.toolbar_op = None;
                controls.progress = None;
                controls.generation = controls.generation.wrapping_add(1);
                controls.request_refresh();
                if current.as_deref() == Some(thread.as_str()) {
                    controls.alert = error;
                }
                let _ = window;
            }
        }
    }

    // MARK: Actions

    fn git_open(&mut self, url: &str, page: bool, cx: &mut Context<Self>) {
        if host_page(url, !page) {
            cx.open_url(url);
        } else {
            self.status = "That page can't be opened.".into();
            cx.notify();
        }
    }

    pub(super) fn git_run_banner_action(&mut self, action: BannerAction, cx: &mut Context<Self>) {
        self.git_controls.banner = None;
        match action {
            BannerAction::Run(next) => self.git_perform(next, None, None, false, false, cx),
            BannerAction::Open(url) => self.git_open(&url, false, cx),
            BannerAction::OpenPage(url) => self.git_open(&url, true, cx),
        }
        cx.notify();
    }

    pub(super) fn git_quick_action(&mut self, cx: &mut Context<Self>) {
        let action = self.git_quick();
        match action.kind {
            coincide_core::git_actions::QuickKind::Run(next) => {
                self.git_perform(next, None, None, false, false, cx)
            }
            coincide_core::git_actions::QuickKind::Pull => self.git_pull(cx),
            coincide_core::git_actions::QuickKind::Hint(hint) => {
                self.git_controls.show(Banner {
                    title: action.title,
                    detail: Some(hint),
                    error: false,
                    action: None,
                });
                cx.notify();
            }
        }
    }

    fn git_quick(&self) -> coincide_core::git_actions::QuickAction {
        let controls = &self.git_controls;
        coincide_core::git_actions::QuickAction::resolve(
            controls.status.as_ref(),
            controls.busy(),
            controls.pull_request.is_some(),
            controls.term,
        )
    }

    fn git_availability(&self) -> coincide_core::git_actions::Availability {
        let controls = &self.git_controls;
        coincide_core::git_actions::Availability::resolve(
            controls.status.as_ref(),
            controls.busy(),
            controls.pull_request.is_some(),
        )
    }

    /// Runs a stacked action. Pushing from the default branch asks first, offering a
    /// feature branch (Swift DiffViewController.perform).
    pub(super) fn git_perform(
        &mut self,
        action: StackedAction,
        message: Option<String>,
        paths: Option<Vec<String>>,
        feature_branch: bool,
        confirmed: bool,
        cx: &mut Context<Self>,
    ) {
        let controls = &mut self.git_controls;
        // Without the status, whether this is the default branch is unknown.
        let (Some(thread), Some(status)) =
            (controls.binding.thread.clone(), controls.status.clone())
        else {
            return;
        };
        if controls.busy() || !controls.actions.can_start() {
            return;
        }
        if !confirmed
            && !feature_branch
            && coincide_core::git_actions::QuickAction::requires_default_branch_confirmation(
                action,
                status.is_default_branch,
            )
        {
            controls.confirm = Some(Confirm {
                thread,
                action,
                message,
                paths,
                branch: status.branch.clone().unwrap_or_else(|| "HEAD".into()),
                can_branch: action.includes_commit() && status.has_changes(),
            });
            cx.notify();
            return;
        }
        controls.action_thread = Some(thread.clone());
        controls.progress = Some("Starting…".into());
        controls.banner = None;
        let (engine, tx) = (controls.engine.clone(), controls.tx.clone());
        let params = json!({
            "threadId": thread,
            "action": action,
            "message": message,
            "paths": paths,
            "featureBranch": feature_branch,
        });
        let started = controls.actions.spawn(move |admission| {
            let progress_tx = tx.clone();
            let progress_thread = thread.clone();
            let reply = engine_op(&engine, &admission, "git.actions.run", params, &|label| {
                let _ = progress_tx.send(Message::Progress {
                    thread: progress_thread.clone(),
                    label: label.to_owned(),
                });
            });
            let (banner, open) = match reply {
                Ok(reply) if reply["error"].is_null() => {
                    let result = &reply["result"];
                    let open = (result["followUp"]["kind"] == "openChangeRequestPage")
                        .then(|| text(&result["followUp"], "value"));
                    (result_banner(result), open)
                }
                Ok(reply) => (failure_banner(&reply), None),
                Err(error) => (failure_banner(&json!({"error":error.to_string()})), None),
            };
            let _ = tx.send(Message::Finished {
                thread,
                banner: Some(banner),
                open,
            });
        });
        if !started {
            controls.action_thread = None;
            controls.progress = None;
        }
        cx.notify();
    }

    pub(super) fn git_pull(&mut self, cx: &mut Context<Self>) {
        let controls = &mut self.git_controls;
        let Some(thread) = controls.binding.thread.clone() else {
            return;
        };
        if controls.busy() || !controls.actions.can_start() {
            return;
        }
        controls.action_thread = Some(thread.clone());
        controls.progress = Some("Pulling…".into());
        let (engine, tx) = (controls.engine.clone(), controls.tx.clone());
        let started = controls.actions.spawn(move |admission| {
            let reply = engine_op(
                &engine,
                &admission,
                "git.actions.pull",
                json!({"threadId":thread}),
                &|_| {},
            );
            let banner = match reply {
                Ok(reply) if reply["error"].is_null() => Banner {
                    title: if reply["pulled"] == true {
                        "Pulled the latest changes"
                    } else {
                        "Already up to date"
                    }
                    .into(),
                    detail: None,
                    error: false,
                    action: None,
                },
                Ok(reply) => failure_banner(&reply),
                Err(error) => failure_banner(&json!({"error":error.to_string()})),
            };
            let _ = tx.send(Message::Finished {
                thread,
                banner: Some(banner),
                open: None,
            });
        });
        if !started {
            controls.action_thread = None;
            controls.progress = None;
        }
        cx.notify();
    }

    pub(super) fn git_show_commit_sheet(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let controls = &mut self.git_controls;
        let (Some(thread), Some(status)) =
            (controls.binding.thread.clone(), controls.status.as_ref())
        else {
            return;
        };
        if !status.has_changes() || controls.busy() {
            return;
        }
        controls.commit = Some(CommitSheet {
            thread,
            branch: status.branch.clone(),
            is_default: status.is_default_branch,
            files: status.files.clone(),
            excluded: HashSet::new(),
        });
        controls.restore_focus = window.focused(cx);
        let message = controls.message.clone();
        message.update(cx, |input, cx| input.set_value("", window, cx));
        message.read(cx).focus_handle(cx).focus(window, cx);
        cx.notify();
    }

    pub(super) fn git_close_modal(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let controls = &mut self.git_controls;
        controls.commit = None;
        controls.confirm = None;
        controls.alert = None;
        if let Some(focus) = controls.restore_focus.take() {
            focus.focus(window, cx);
        }
        cx.notify();
    }

    pub(super) fn git_commit(
        &mut self,
        on_new_branch: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(sheet) = self.git_controls.commit.take() else {
            return;
        };
        // The files picked are in this thread's folder.
        if self.git_controls.binding.thread.as_deref() != Some(sheet.thread.as_str()) {
            return;
        }
        let paths: Vec<String> = sheet
            .files
            .iter()
            .map(|file| file.path.clone())
            .filter(|path| !sheet.excluded.contains(path))
            .collect();
        if paths.is_empty() {
            self.git_controls.commit = Some(sheet);
            return;
        }
        let message = self.git_controls.message.read(cx).value().to_string();
        let paths = (!sheet.excluded.is_empty()).then_some(paths);
        self.git_close_modal(window, cx);
        self.git_perform(
            StackedAction::Commit,
            Some(message),
            paths,
            on_new_branch,
            false,
            cx,
        );
    }

    pub(super) fn git_confirm(
        &mut self,
        feature_branch: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(confirm) = self.git_controls.confirm.take() else {
            return;
        };
        self.git_close_modal(window, cx);
        // The question named this thread's branch.
        if self.git_controls.binding.thread.as_deref() == Some(confirm.thread.as_str()) {
            self.git_perform(
                confirm.action,
                confirm.message,
                confirm.paths,
                feature_branch,
                true,
                cx,
            );
        }
    }

    // MARK: Branch toolbar

    fn git_toolbar_op(
        &mut self,
        op: ToolbarOp,
        method: &'static str,
        params: Value,
        cx: &mut Context<Self>,
    ) {
        let controls = &mut self.git_controls;
        let Some(thread) = controls.binding.thread.clone() else {
            return;
        };
        if controls.busy() || !controls.actions.can_start() {
            return;
        }
        controls.action_thread = Some(thread.clone());
        controls.toolbar_op = Some(op);
        let (engine, tx) = (controls.engine.clone(), controls.tx.clone());
        let mut params = params;
        params["threadId"] = json!(thread);
        let started = controls.actions.spawn(move |admission| {
            let reply = engine_op(&engine, &admission, method, params, &|_| {});
            let error = match reply {
                Ok(reply) if reply["error"].is_null() => None,
                Ok(reply) => Some(failure_banner(&reply)),
                Err(error) => Some(failure_banner(&json!({"error":error.to_string()}))),
            };
            let _ = tx.send(Message::ToolbarFinished { thread, error });
        });
        if !started {
            controls.action_thread = None;
            controls.toolbar_op = None;
        }
        cx.notify();
    }

    pub(super) fn git_use_checkout(&mut self, cx: &mut Context<Self>) {
        self.git_toolbar_op(
            ToolbarOp::Workspace,
            "git.worktrees.useCheckout",
            json!({}),
            cx,
        );
    }

    pub(super) fn git_use_new_worktree(&mut self, base: Option<String>, cx: &mut Context<Self>) {
        self.git_toolbar_op(
            ToolbarOp::NewWorktree,
            "git.worktrees.useNew",
            json!({"baseBranch":base}),
            cx,
        );
    }

    pub(super) fn git_use_existing(
        &mut self,
        path: String,
        branch: Option<String>,
        cx: &mut Context<Self>,
    ) {
        self.git_toolbar_op(
            ToolbarOp::Workspace,
            "git.worktrees.useExisting",
            json!({"path":path,"branch":branch}),
            cx,
        );
    }

    pub(super) fn git_preparing(&self) -> bool {
        let controls = &self.git_controls;
        controls.toolbar.preparing
            || (controls.toolbar_op == Some(ToolbarOp::NewWorktree)
                && controls.action_thread == controls.binding.thread)
    }

    pub(super) fn git_open_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let controls = &mut self.git_controls;
        let Some(thread) = controls.binding.thread.clone() else {
            return;
        };
        if controls.picker.is_some() {
            controls.picker = None;
            cx.notify();
            return;
        }
        let base = (!controls.binding.started)
            .then(|| controls.toolbar.base_branch.clone())
            .flatten();
        if base.is_none() && controls.binding.worktree.is_some() {
            return;
        }
        let mode = if base.is_some() {
            PickerMode::Base
        } else {
            PickerMode::Checkout
        };
        controls.picker_token = controls.picker_token.wrapping_add(1);
        let token = controls.picker_token;
        controls.picker = Some(Picker {
            thread: thread.clone(),
            mode,
            token,
            list: None,
            footer: "Loading branches…".into(),
            rows: Vec::new(),
            highlighted: None,
            selected_name: base.or_else(|| controls.status.as_ref().and_then(|s| s.branch.clone())),
        });
        let search = controls.search.clone();
        search.update(cx, |input, cx| {
            input.set_placeholder(
                if mode == PickerMode::Checkout {
                    "Search or create a branch"
                } else {
                    "Search branches"
                },
                window,
                cx,
            );
            input.set_value("", window, cx);
        });
        search.read(cx).focus_handle(cx).focus(window, cx);
        // A new worktree's base comes from the project's branches, not the worktree's.
        let scope = if mode == PickerMode::Base {
            "project"
        } else {
            "thread"
        };
        let (engine, tx) = (controls.engine.clone(), controls.tx.clone());
        if !controls.lists.spawn(move |admission| {
            let result = engine_op(
                &engine,
                &admission,
                "git.branches.list",
                json!({"threadId":thread,"scope":scope}),
                &|_| {},
            )
            .map_err(|error| error.to_string())
            .and_then(|reply| match reply["error"].as_str() {
                Some(error) => Err(error.to_owned()),
                None => serde_json::from_value(reply["branches"].clone())
                    .map_err(|error| error.to_string()),
            });
            let _ = tx.send(Message::Branches { token, result });
        }) && let Some(picker) = controls.picker.as_mut()
        {
            picker.footer = "Branches are still loading. Try again in a moment.".into();
        }
        cx.notify();
    }

    fn git_picker_search_changed(&mut self, cx: &mut Context<Self>) {
        let query = self.git_controls.search.read(cx).value().to_string();
        let Some(picker) = self.git_controls.picker.as_mut() else {
            return;
        };
        picker.rows = picker_rows(picker.list.as_ref(), &query, picker.mode);
        picker.highlighted = if query.trim().is_empty() {
            None
        } else {
            picker_move(&picker.rows, None, true)
        };
        if picker.list.is_some() && picker.rows.is_empty() {
            picker.footer = "No matching branches.".into();
        }
        cx.notify();
    }

    pub(super) fn git_picker_move(&mut self, down: bool, cx: &mut Context<Self>) {
        if let Some(picker) = self.git_controls.picker.as_mut()
            && let Some(next) = picker_move(&picker.rows, picker.highlighted, down)
        {
            picker.highlighted = Some(next);
            cx.notify();
        }
    }

    pub(super) fn git_close_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.git_controls.picker.take().is_some() {
            self.composer.read(cx).focus_handle(cx).focus(window, cx);
            cx.notify();
        }
    }

    pub(super) fn git_pick(&mut self, row: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(picker) = self.git_controls.picker.as_ref() else {
            return;
        };
        let Some(choice) = picker.rows.get(row).cloned() else {
            return;
        };
        let (mode, thread) = (picker.mode, picker.thread.clone());
        if matches!(choice, PickerRow::Header(_))
            || matches!(&choice, PickerRow::Create(name) if name.is_empty())
        {
            return;
        }
        self.git_close_picker(window, cx);
        if self.git_controls.binding.thread.as_deref() != Some(thread.as_str()) {
            return;
        }
        match (mode, choice) {
            (PickerMode::Base, PickerRow::Branch(branch)) => {
                self.git_use_new_worktree(Some(branch.name), cx)
            }
            (PickerMode::Checkout, PickerRow::Branch(branch)) => {
                if let Some(path) = branch.worktree_path.clone().filter(|_| !branch.is_current) {
                    // Git checks a branch out in one folder at a time; before the first
                    // message the thread can move to that folder instead.
                    if !self.git_controls.binding.started {
                        self.git_use_existing(path, Some(branch.name), cx);
                    } else {
                        self.git_controls.alert = Some(Banner {
                            title: format!("“{}” is checked out in another worktree.", branch.name),
                            detail: Some(format!(
                                "Git can check a branch out in only one folder at a time: {path}"
                            )),
                            error: true,
                            action: None,
                        });
                        cx.notify();
                    }
                    return;
                }
                self.git_toolbar_op(
                    ToolbarOp::Checkout,
                    "git.branches.checkout",
                    json!({"name":branch.name}),
                    cx,
                );
            }
            (PickerMode::Checkout, PickerRow::Create(name)) => {
                self.git_toolbar_op(
                    ToolbarOp::Checkout,
                    "git.branches.create",
                    json!({"name":name}),
                    cx,
                );
            }
            _ => {}
        }
    }

    pub(super) fn git_copy_path(&mut self, cx: &mut Context<Self>) {
        if let Some(folder) = self.git_controls.binding.folder.clone() {
            cx.write_to_clipboard(ClipboardItem::new_string(folder));
        }
    }

    pub(super) fn git_reveal_folder(&mut self, cx: &mut Context<Self>) {
        let Some(folder) = self.git_controls.binding.folder.clone() else {
            return;
        };
        if let Some(target) = open_targets::file_manager() {
            self.open_in_folder(target, std::path::PathBuf::from(folder), cx);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn branch(name: &str, remote: bool) -> GitBranch {
        GitBranch {
            name: name.into(),
            is_remote: remote,
            ..GitBranch::default()
        }
    }

    fn list() -> GitBranchList {
        GitBranchList {
            is_repository: true,
            branches: vec![
                branch("main", false),
                branch("feature/login", false),
                branch("origin/release", true),
            ],
            ..GitBranchList::default()
        }
    }

    #[::core::prelude::v1::test]
    fn picker_rows_offer_create_and_sections_like_swift() {
        let list = list();
        let all = picker_rows(Some(&list), "", PickerMode::Checkout);
        assert_eq!(all[0], PickerRow::Header("Local"));
        assert_eq!(all[3], PickerRow::Header("Remote"));
        assert_eq!(all.len(), 5);
        let typed = picker_rows(Some(&list), "new  idea", PickerMode::Checkout);
        assert_eq!(typed, vec![PickerRow::Create("new-idea".into())]);
        let existing = picker_rows(Some(&list), "MAIN", PickerMode::Checkout);
        assert_eq!(
            existing,
            vec![
                PickerRow::Header("Local"),
                PickerRow::Branch(branch("main", false))
            ]
        );
        let base = picker_rows(Some(&list), "rel", PickerMode::Base);
        assert_eq!(
            base,
            vec![
                PickerRow::Header("Remote"),
                PickerRow::Branch(branch("origin/release", true))
            ]
        );
        assert_eq!(
            picker_rows(None, "x", PickerMode::Checkout),
            vec![PickerRow::Create("x".into())]
        );
        assert!(picker_rows(None, "", PickerMode::Base).is_empty());
    }

    #[::core::prelude::v1::test]
    fn picker_moves_skip_headers() {
        let rows = picker_rows(Some(&list()), "", PickerMode::Checkout);
        assert_eq!(picker_move(&rows, None, true), Some(1));
        assert_eq!(picker_move(&rows, Some(2), true), Some(4));
        assert_eq!(picker_move(&rows, Some(4), true), None);
        assert_eq!(picker_move(&rows, Some(1), false), None);
        assert_eq!(picker_move(&rows, None, false), Some(4));
    }

    #[::core::prelude::v1::test]
    fn bar_labels_and_banners_match_swift() {
        let status = GitStatus {
            is_repository: true,
            branch: Some("feature".into()),
            upstream: Some("origin/feature".into()),
            ahead: 2,
            behind: 1,
            ..GitStatus::default()
        };
        let pull_request = GitPullRequest {
            number: 12,
            url: "https://github.com/o/r/pull/12".into(),
            title: "Fix the parser".into(),
            state: "OPEN".into(),
            base_branch: "main".into(),
            head_branch: "feature".into(),
            is_draft: false,
        };
        assert_eq!(
            sync_label(&status, Some(&pull_request), Term::PullRequest),
            "↑2 ↓1 #12"
        );
        assert_eq!(
            sync_label(&status, Some(&pull_request), Term::MergeRequest),
            "↑2 ↓1 !12"
        );
        assert_eq!(
            branch_tooltip(&status, Some(&pull_request), Term::PullRequest),
            "feature\nTracks origin/feature\nPull request #12: Fix the parser"
        );
        let committed = result_banner(&json!({
            "title":"Committed abc1234","detail":"Add notes","followUp":{"kind":"run","value":"push"},
            "changeRequestTerm":"pullRequest"
        }));
        assert_eq!(
            committed.action,
            Some(("Push".into(), BannerAction::Run(StackedAction::Push)))
        );
        let pushed = result_banner(&json!({
            "title":"Pushed","followUp":{"kind":"run","value":"createPr"},"changeRequestTerm":"mergeRequest"
        }));
        assert_eq!(pushed.action.unwrap().0, "Create MR");
        let page = result_banner(&json!({
            "title":"Create the merge request on GitLab","hostName":"GitLab",
            "followUp":{"kind":"openChangeRequestPage","value":"https://gitlab.com/a/b/-/merge_requests/new"},
            "changeRequestTerm":"mergeRequest"
        }));
        assert_eq!(page.action.as_ref().unwrap().0, "Open GitLab");
        let opened = result_banner(&json!({
            "title":"Opened PR #3","followUp":{"kind":"openPullRequest","value":"https://github.com/o/r/pull/3"}
        }));
        assert_eq!(opened.action.unwrap().0, "View PR");
        let failure = failure_banner(&json!({"error":"Could not push “x”.","detail":"rejected"}));
        assert!(failure.error && failure.detail.as_deref() == Some("rejected"));
        assert!(host_page("https://github.com/o/r/pull/3", false));
        assert!(!host_page("http://example.com", false) && host_page("http://example.com", true));
        assert!(!host_page("file:///etc/passwd", true) && !host_page("https:///x", true));
    }
}
