//! The Diff inspector, after Swift's DiffViewController: what changed in the
//! conversation's folder, uncommitted or on the branch, as a file list over a
//! line-numbered diff. One worker owns each load's Git and Engine calls; the diff
//! follows the agent's edits while a turn runs, at most every live-refresh floor.
#[path = "diff_document.rs"]
mod document;

use crate::worker_owner::{Admission, ShutdownStatus, WorkerOwner};
use anyhow::{Context as _, Result, ensure};
use coincide_core::{
    api::{SharedEngine, call},
    workspace_diff::{self, GitDiff, Presentation, Review, Scope},
};
pub(crate) use document::DiffLayout;
use document::{Document, Side, counts, path_label, status_badge};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    base::Disableable as _,
    component::{
        ActiveTheme as _, Icon, Sizable as _,
        button::*,
        menu::{DropdownMenu, PopupMenu, PopupMenuItem},
        spinner::Spinner,
        tooltip::Tooltip,
    },
    *,
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, mpsc},
    time::{Duration, Instant},
};

/// What the empty view says when there is no diff to show.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Message {
    NoThread,
    FolderMissing(String),
    NotRepository,
    NoUncommittedChanges,
    NoBranchChanges(Option<String>),
    Failed(String),
}

impl Message {
    fn content(&self) -> (gpui_kit::assets::IconName, &'static str, String) {
        use gpui_kit::assets::IconName;
        match self {
            Self::NoThread => (
                IconName::Diff,
                "No Thread Selected",
                "Select a thread to see the changes in its folder.".into(),
            ),
            Self::FolderMissing(path) => (IconName::FolderX, "Folder Not Found", path.clone()),
            Self::NotRepository => (
                IconName::GitBranch,
                "Not a Git Repository",
                "Changes, turn diffs and checkpoints need Git.".into(),
            ),
            Self::NoUncommittedChanges => (
                IconName::CircleCheck,
                "No Uncommitted Changes",
                "The working tree matches the last commit.".into(),
            ),
            Self::NoBranchChanges(base) => (
                IconName::CircleCheck,
                "No Changes on This Branch",
                base.as_ref()
                    .map(|base| format!("Nothing differs from {base}."))
                    .unwrap_or_default(),
            ),
            Self::Failed(text) => (
                IconName::TriangleAlert,
                "Couldn't Load the Changes",
                text.clone(),
            ),
        }
    }
}

pub(crate) fn scope_title(scope: Scope) -> &'static str {
    match scope {
        Scope::Uncommitted => "Uncommitted Changes",
        Scope::Branch => "Branch Changes",
    }
}

/// `1 file` or `N files`.
pub(crate) fn files_label(count: usize) -> String {
    if count == 1 {
        "1 file".into()
    } else {
        format!("{count} files")
    }
}

/// The file list gets room for its files, up to a third of the panel.
pub(crate) fn file_list_height(count: usize, available: f32) -> f32 {
    (count as f32 * 24. + 8.).min((available / 3.).max(96.))
}

/// The divider stays between 48 points from the top and 120 from the bottom.
pub(crate) fn clamp_file_list(height: f32, available: f32) -> f32 {
    height.min(available - 120.).max(48.)
}

/// When an automatic reload may run (Swift's `scheduleReload`). Bursts of change
/// coalesce into one reload; a running load is never cut short, so a reload asked
/// for meanwhile follows it.
#[derive(Debug, Default)]
pub(crate) struct ReloadSchedule {
    pending: Option<Instant>,
    last_load_start: Option<Instant>,
    queued_floor: Option<Duration>,
}

impl ReloadSchedule {
    const COALESCE: Duration = Duration::from_millis(400);
    /// The least time between automatic reloads for the agent's edits (T3 Code's
    /// live-refresh floor); a Git diff is too costly to repeat on a timer.
    pub(crate) const LIVE_FLOOR: Duration = Duration::from_secs(10);

    pub(crate) fn schedule(&mut self, now: Instant, floor: Duration, loading: bool) {
        if loading {
            self.queued_floor = Some(self.queued_floor.map_or(floor, |queued| queued.min(floor)));
            return;
        }
        let mut deadline = now + Self::COALESCE;
        if let Some(start) = self.last_load_start {
            deadline = deadline.max(start + floor);
        }
        if self.pending.is_some_and(|pending| pending <= deadline) {
            return;
        }
        self.pending = Some(deadline);
    }

    /// Whether the scheduled reload is due; it is consumed when it is.
    pub(crate) fn due(&mut self, now: Instant) -> bool {
        if self.pending.is_some_and(|pending| pending <= now) {
            self.pending = None;
            true
        } else {
            false
        }
    }

    /// A load started: it reads everything reported so far.
    pub(crate) fn started(&mut self, now: Instant) {
        self.pending = None;
        self.queued_floor = None;
        self.last_load_start = Some(now);
    }

    pub(crate) fn cancel(&mut self) {
        self.pending = None;
    }

    /// The floor of a reload asked for while the load that just finished ran.
    pub(crate) fn finished(&mut self) -> Option<Duration> {
        self.queued_floor.take()
    }
}

/// The latest finished tool that can change files (a command or an edit, not a read,
/// search, web search or plan update): T3 Code's workspace mutation.
pub(crate) fn workspace_change(items: &[Value]) -> Option<String> {
    items.iter().enumerate().rev().find_map(|(index, item)| {
        let finished = matches!(
            item["status"].as_str(),
            Some(status) if status != "running" && status != "waiting"
        );
        let reads = matches!(
            item["category"].as_str(),
            Some("read" | "search" | "web" | "todo")
        );
        (item["kind"] == "tool" && finished && !reads).then(|| {
            item["id"]
                .as_str()
                .map_or_else(|| format!("#{index}"), str::to_owned)
        })
    })
}

enum Content {
    /// The first load for this thread has not finished.
    Loading,
    Empty(Message),
    Diff,
}

enum Outcome {
    Empty(Message),
    Diff {
        root: PathBuf,
        diff: Arc<GitDiff>,
        presentation: Arc<Presentation>,
    },
}

struct Request {
    thread: String,
    scope: Scope,
    ignore_whitespace: bool,
}

fn string(value: &Value, key: &str) -> Result<String> {
    Ok(value[key]
        .as_str()
        .with_context(|| format!("Missing {key}"))?
        .to_owned())
}

/// Starts a workspace operation and waits for its result on this worker.
fn operation(api: &mut impl FnMut(&str, Value) -> Result<Value>, params: Value) -> Result<Value> {
    let owner = params["threadId"].clone();
    let id = string(&api("git.review.diff", params)?, "operationId")?;
    let deadline = Instant::now() + Duration::from_secs(125);
    loop {
        let reply = api(
            "git.workspace.result",
            json!({"threadId":owner,"operationId":id}),
        )?;
        if reply["ready"] == true {
            let result = reply["result"].clone();
            ensure!(
                result["error"].is_null(),
                "{}",
                result["error"]
                    .as_str()
                    .unwrap_or("Could not read the changes.")
            );
            return Ok(result);
        }
        ensure!(Instant::now() < deadline, "Reading the changes timed out.");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The stored working directory, which the Engine checks the request against.
fn working_directory(
    api: &mut impl FnMut(&str, Value) -> Result<Value>,
    thread: &str,
) -> Result<Option<PathBuf>> {
    let value = api("threads.read", json!({"threadId":thread,"itemLimit":0}))?;
    if let Some(path) = value["worktreePath"]
        .as_str()
        .filter(|path| !path.is_empty())
    {
        return Ok(Some(PathBuf::from(path)));
    }
    let projects = api("projects.list", json!({}))?;
    Ok(projects
        .as_array()
        .context("Invalid projects")?
        .iter()
        .find(|project| project["id"] == value["projectID"])
        .and_then(|project| project["path"].as_str())
        .filter(|path| !path.is_empty())
        .map(PathBuf::from))
}

fn load(api: &mut impl FnMut(&str, Value) -> Result<Value>, request: &Request) -> Result<Outcome> {
    let stored = working_directory(api, &request.thread)?;
    let Some(folder) = stored
        .as_ref()
        .filter(|path| path.is_absolute() && path.is_dir())
    else {
        return Ok(Outcome::Empty(Message::FolderMissing(
            stored
                .map(|path| path.display().to_string())
                .unwrap_or_default(),
        )));
    };
    let root = folder
        .canonicalize()?
        .to_str()
        .context("Working directory is not UTF-8")?
        .to_owned();
    let reply = operation(
        api,
        json!({
            "threadId": request.thread,
            "expectedRoot": root,
            "scope": request.scope.as_str(),
            "ignoreWhitespace": request.ignore_whitespace,
        }),
    )?;
    Ok(match workspace_diff::decode(&reply)? {
        Review::NotRepository => Outcome::Empty(Message::NotRepository),
        Review::Diff { diff, .. } if diff.files.is_empty() => Outcome::Empty(match request.scope {
            Scope::Uncommitted => Message::NoUncommittedChanges,
            Scope::Branch => Message::NoBranchChanges(diff.base_label),
        }),
        Review::Diff { root, diff } => {
            let presentation = Presentation::make(&diff);
            Outcome::Diff {
                root,
                diff: Arc::new(diff),
                presentation: Arc::new(presentation),
            }
        }
    })
}

#[derive(Clone)]
struct ResizeFileList;
impl Render for ResizeFileList {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        Empty
    }
}

pub struct DiffPanel {
    engine: SharedEngine,
    workers: WorkerOwner,
    tx: mpsc::Sender<(u64, Result<Outcome>)>,
    rx: mpsc::Receiver<(u64, Result<Outcome>)>,
    generation: u64,
    loading: bool,
    /// Keep the top row in place when the running load's diff is shown.
    keep_position: bool,
    /// A reload asked for while a load ran, and whether it keeps the position.
    reload_after: Option<bool>,
    thread: Option<String>,
    root_hint: Option<String>,
    scopes: HashMap<String, Scope>,
    ignore_whitespace: bool,
    /// Settings last applied, so a change made here is not undone by a stale copy.
    synced_layout: Option<String>,
    synced_whitespace: Option<bool>,
    font_size: f32,
    visible: bool,
    needs_reload: bool,
    schedule: ReloadSchedule,
    running: Option<bool>,
    last_workspace_change: Option<Option<String>>,
    content: Content,
    root: Option<PathBuf>,
    document: Document,
    files: UniformListScrollHandle,
    selected_file: Option<usize>,
    followed_file: Option<usize>,
    dragged_height: Option<f32>,
    sized_file_count: usize,
    split_height: f32,
    notice: Option<String>,
    _poll: Task<()>,
    _activation: Subscription,
}

impl DiffPanel {
    pub fn new(engine: SharedEngine, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (tx, rx) = mpsc::channel();
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
        let activation = cx.observe_window_activation(window, |this, window, cx| {
            if window.is_window_active() {
                this.schedule_reload(Duration::ZERO, cx);
            }
        });
        Self {
            engine,
            workers: WorkerOwner::default(),
            tx,
            rx,
            generation: 0,
            loading: false,
            keep_position: false,
            reload_after: None,
            thread: None,
            root_hint: None,
            scopes: HashMap::new(),
            ignore_whitespace: false,
            synced_layout: None,
            synced_whitespace: None,
            font_size: 13.,
            visible: false,
            needs_reload: false,
            schedule: ReloadSchedule::default(),
            running: None,
            last_workspace_change: None,
            content: Content::Empty(Message::NoThread),
            root: None,
            document: Document::new(DiffLayout::Unified, cx),
            files: UniformListScrollHandle::new(),
            selected_file: None,
            followed_file: None,
            dragged_height: None,
            sized_file_count: 0,
            split_height: 0.,
            notice: None,
            _poll: poll,
            _activation: activation,
        }
    }

    pub fn request_shutdown(&mut self) {
        if self.workers.close() {
            self.generation = self.generation.wrapping_add(1);
        }
        self.reload_after = None;
        for result in self.rx.try_iter() {
            drop(result);
        }
    }

    pub fn shutdown_status(&mut self) -> ShutdownStatus {
        if self.workers.closed() {
            for result in self.rx.try_iter() {
                drop(result);
            }
        }
        self.workers.status()
    }

    fn scope(&self) -> Scope {
        self.thread
            .as_ref()
            .and_then(|thread| self.scopes.get(thread).copied())
            .unwrap_or_default()
    }

    /// The selected conversation and its stored folder (cached metadata only; the
    /// worker resolves the folder). Another thread discards the shown changes.
    pub fn set_context(
        &mut self,
        thread: Option<String>,
        root_hint: Option<String>,
        cx: &mut Context<Self>,
    ) {
        if self.workers.closed() || (self.thread == thread && self.root_hint == root_hint) {
            return;
        }
        let switched = self.thread != thread;
        self.thread = thread;
        self.root_hint = root_hint;
        if switched {
            self.running = None;
            self.last_workspace_change = None;
            self.root = None;
            self.selected_file = None;
            self.followed_file = None;
            self.document.clear();
            self.content = if self.thread.is_some() {
                Content::Loading
            } else {
                Content::Empty(Message::NoThread)
            };
        }
        // The thread may have moved into (or out of) a worktree.
        self.reload(false, cx);
        cx.notify();
    }

    /// Whether the selected thread's items have not been seen since it was selected.
    pub fn awaits_items(&self) -> bool {
        self.thread.is_some() && self.last_workspace_change.is_none()
    }

    /// The selected thread's run state and transcript items, from the parent's poll.
    pub fn observe_thread(
        &mut self,
        running: bool,
        items: Option<&[Value]>,
        cx: &mut Context<Self>,
    ) {
        if self.thread.is_none() {
            return;
        }
        // Only a turn starting or ending changes what the diff shows.
        if self
            .running
            .replace(running)
            .is_some_and(|was| was != running)
        {
            self.schedule_reload(Duration::ZERO, cx);
        }
        let Some(items) = items else {
            return;
        };
        let change = workspace_change(items);
        let previous = self.last_workspace_change.replace(change.clone());
        // While a turn runs, the diff follows the agent's commands and edits once one
        // finishes, at most every live-refresh floor.
        if running && previous.is_some_and(|previous| previous != change) {
            self.schedule_reload(ReloadSchedule::LIVE_FLOOR, cx);
        }
    }

    /// Diff preferences from settings, and the conversation font size.
    pub fn apply_settings(&mut self, settings: &Value, font_size: f32, cx: &mut Context<Self>) {
        let layout = settings["diffLayout"].as_str().map(str::to_owned);
        if layout != self.synced_layout {
            self.synced_layout = layout.clone();
            let layout = layout
                .as_deref()
                .and_then(DiffLayout::from_setting)
                .unwrap_or_default();
            self.document.set_layout(layout);
            cx.notify();
        }
        let whitespace = settings["diffIgnoreWhitespace"].as_bool();
        if whitespace != self.synced_whitespace {
            self.synced_whitespace = whitespace;
            let ignore = whitespace.unwrap_or(false);
            if ignore != self.ignore_whitespace {
                self.ignore_whitespace = ignore;
                self.reload(true, cx);
            }
        }
        if (font_size - self.font_size).abs() > f32::EPSILON {
            self.font_size = font_size;
            cx.notify();
        }
    }

    /// Whether the panel is on screen; loads wait until it is.
    pub fn set_visible(&mut self, visible: bool, cx: &mut Context<Self>) {
        if self.visible == visible {
            return;
        }
        self.visible = visible;
        if visible && !self.loading && (self.needs_reload || !matches!(self.content, Content::Diff))
        {
            self.reload(false, cx);
        }
    }

    fn schedule_reload(&mut self, floor: Duration, cx: &mut Context<Self>) {
        if self.thread.is_none() || self.workers.closed() {
            return;
        }
        self.schedule.schedule(Instant::now(), floor, self.loading);
        cx.notify();
    }

    /// Reloads the diff for the current scope.
    fn reload(&mut self, keep_position: bool, cx: &mut Context<Self>) {
        if self.workers.closed() {
            return;
        }
        if !self.visible {
            self.needs_reload = true;
            return;
        }
        self.needs_reload = false;
        self.schedule.cancel();
        let Some(thread) = self.thread.clone() else {
            self.show_empty(Message::NoThread);
            cx.notify();
            return;
        };
        if self.loading || !self.workers.can_start() {
            // The running load's result is dropped; this one follows it.
            self.generation = self.generation.wrapping_add(1);
            self.reload_after = Some(
                self.reload_after
                    .map_or(keep_position, |keep| keep && keep_position),
            );
            return;
        }
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        let request = Request {
            thread,
            scope: self.scope(),
            ignore_whitespace: self.ignore_whitespace,
        };
        let engine = self.engine.clone();
        let tx = self.tx.clone();
        let started = self.workers.spawn(move |admission: Admission| {
            let result = load(
                &mut |method, params| {
                    ensure!(admission.allowed(), "Workflow is shutting down");
                    call(&engine, method, params)
                },
                &request,
            );
            let _ = tx.send((generation, result));
        });
        if started {
            self.loading = true;
            self.keep_position = keep_position;
            self.schedule.started(Instant::now());
        } else {
            self.show_empty(Message::Failed("Background worker could not start.".into()));
        }
        cx.notify();
    }

    fn poll(&mut self, cx: &mut Context<Self>) {
        self.workers.poll();
        if self.workers.closed() {
            for result in self.rx.try_iter() {
                drop(result);
            }
            return;
        }
        if let Ok((generation, result)) = self.rx.try_recv() {
            self.loading = false;
            if generation == self.generation {
                match result {
                    Ok(outcome) => self.apply(outcome, cx),
                    Err(error) => self.show_empty(Message::Failed(error.to_string())),
                }
                cx.notify();
            }
            // Changes reported while this load ran may have come too late for it.
            if let Some(floor) = self.schedule.finished() {
                self.schedule.schedule(Instant::now(), floor, false);
            }
        }
        if !self.loading
            && self.workers.can_start()
            && let Some(keep) = self.reload_after.take()
        {
            self.reload(keep, cx);
        } else if !self.loading && self.schedule.due(Instant::now()) {
            self.reload(true, cx);
        }
    }

    fn show_empty(&mut self, message: Message) {
        self.content = Content::Empty(message);
        self.root = None;
        self.document.clear();
    }

    fn apply(&mut self, outcome: Outcome, cx: &mut Context<Self>) {
        match outcome {
            Outcome::Empty(message) => self.show_empty(message),
            Outcome::Diff {
                root,
                diff,
                presentation,
            } => {
                self.root = Some(root);
                let unchanged =
                    matches!(self.content, Content::Diff) && *diff == *self.document.diff;
                self.content = Content::Diff;
                if !unchanged {
                    let selected = self
                        .selected_file
                        .and_then(|index| self.document.diff.files.get(index))
                        .map(|file| file.path.clone());
                    self.document.show(diff, presentation, self.keep_position);
                    self.selected_file = selected.and_then(|path| {
                        self.document
                            .diff
                            .files
                            .iter()
                            .position(|file| file.path == path)
                    });
                    self.followed_file = None;
                    if self.document.diff.files.len() != self.sized_file_count {
                        // Only a change in the number of files moves the divider.
                        self.sized_file_count = self.document.diff.files.len();
                        self.dragged_height = None;
                    }
                }
            }
        }
        cx.notify();
    }

    fn select_scope(&mut self, scope: Scope, cx: &mut Context<Self>) {
        let Some(thread) = self.thread.clone() else {
            return;
        };
        if scope == self.scope() {
            return;
        }
        self.scopes.insert(thread, scope);
        self.content = Content::Loading;
        self.document.clear();
        self.reload(false, cx);
        cx.notify();
    }

    fn save_setting(&mut self, key: &str, value: Value) {
        // A busy Engine keeps the choice for this session; the next save retries.
        let saved = self.engine.try_lock().ok().map(|mut engine| {
            engine.dispatch(json!({"method":"settings.patch","params":{"patch":{key:value}}}))
        });
        self.notice = match saved {
            Some(reply) if reply.get("error").is_none() => None,
            _ => Some("Diff options are kept for this session but could not be saved.".into()),
        };
    }

    fn change_layout(&mut self, layout: DiffLayout, cx: &mut Context<Self>) {
        self.document.set_layout(layout);
        self.synced_layout = Some(layout.setting().to_owned());
        self.save_setting("diffLayout", json!(layout.setting()));
        cx.notify();
    }

    fn toggle_whitespace(&mut self, cx: &mut Context<Self>) {
        self.ignore_whitespace = !self.ignore_whitespace;
        self.synced_whitespace = Some(self.ignore_whitespace);
        self.save_setting("diffIgnoreWhitespace", json!(self.ignore_whitespace));
        self.reload(true, cx);
        cx.notify();
    }

    fn toggle_collapse_all(&mut self, cx: &mut Context<Self>) {
        let collapse = !self.document.all_collapsed();
        self.document.set_all_collapsed(collapse);
        cx.notify();
    }

    fn reveal_folder(&mut self, cx: &mut Context<Self>) {
        let folder = self
            .root_hint
            .as_deref()
            .map(Path::new)
            .filter(|path| path.is_absolute());
        if let Some(folder) = folder {
            cx.reveal_path(folder);
        }
    }

    fn toggle_file(&mut self, file: usize, cx: &mut Context<Self>) {
        self.document.toggle(file);
        cx.notify();
    }

    fn click_row(
        &mut self,
        row: usize,
        extend: bool,
        toggle: bool,
        side: Option<Side>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        window.focus(&self.document.focus, cx);
        self.document.click(row, extend, toggle, side);
        cx.notify();
    }

    fn select_file(&mut self, index: usize, cx: &mut Context<Self>) {
        self.selected_file = Some(index);
        self.followed_file = Some(index);
        self.document.scroll_to_file(index);
        cx.notify();
    }

    fn render_header(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let theme = cx.theme();
        let (addition, deletion, warning, secondary, border) = (
            theme.success,
            theme.danger,
            theme.warning,
            theme.muted_foreground,
            theme.border,
        );
        let size = px(self.font_size - 2.);
        let this = cx.entity().downgrade();
        let scope = self.scope();
        let has_thread = self.thread.is_some();
        let summary = matches!(self.content, Content::Diff).then(|| {
            let diff = &self.document.diff;
            div()
                .flex()
                .min_w_0()
                .overflow_hidden()
                .whitespace_nowrap()
                .text_size(size)
                .font_weight(FontWeight::MEDIUM)
                .child(
                    div()
                        .text_color(secondary)
                        .child(format!("{}  ", files_label(diff.files.len()))),
                )
                .child(
                    div()
                        .text_color(addition)
                        .child(format!("+{}", diff.additions())),
                )
                .child(" ")
                .child(
                    div()
                        .text_color(deletion)
                        .child(format!("−{}", diff.deletions())),
                )
                .when(diff.is_truncated, |view| {
                    view.child(div().text_color(warning).child("  (partial)"))
                })
        });
        // Swift also offers Latest Turn and Turn N; those scopes need per-turn
        // checkpoints, which the shared Engine does not record yet.
        let scope_menu = {
            let this = this.clone();
            move |mut menu: PopupMenu, _: &mut Window, _: &mut Context<PopupMenu>| {
                for choice in [Scope::Uncommitted, Scope::Branch] {
                    let this = this.clone();
                    menu = menu.item(
                        PopupMenuItem::new(scope_title(choice))
                            .checked(choice == scope)
                            .on_click(move |_, _, cx| {
                                let _ = this.update(cx, |this, cx| this.select_scope(choice, cx));
                            }),
                    );
                }
                menu
            }
        };
        let layout = self.document.layout;
        let ignore_whitespace = self.ignore_whitespace;
        let has_diff = matches!(self.content, Content::Diff);
        let all_collapsed = self.document.all_collapsed();
        let can_reveal = self.root_hint.is_some();
        let options_menu =
            move |mut menu: PopupMenu, _: &mut Window, _: &mut Context<PopupMenu>| {
                for choice in DiffLayout::ALL {
                    let this = this.clone();
                    menu = menu.item(
                        PopupMenuItem::new(choice.title())
                            .checked(choice == layout)
                            .on_click(move |_, _, cx| {
                                let _ = this.update(cx, |this, cx| this.change_layout(choice, cx));
                            }),
                    );
                }
                menu = menu.item(PopupMenuItem::separator());
                {
                    let this = this.clone();
                    menu = menu.item(
                        PopupMenuItem::new("Ignore Whitespace")
                            .checked(ignore_whitespace)
                            .on_click(move |_, _, cx| {
                                let _ = this.update(cx, |this, cx| this.toggle_whitespace(cx));
                            }),
                    );
                }
                {
                    let this = this.clone();
                    menu = menu.item(
                        PopupMenuItem::new(if all_collapsed {
                            "Expand All Files"
                        } else {
                            "Collapse All Files"
                        })
                        .disabled(!has_diff)
                        .on_click(move |_, _, cx| {
                            let _ = this.update(cx, |this, cx| this.toggle_collapse_all(cx));
                        }),
                    );
                }
                menu = menu.item(PopupMenuItem::separator());
                let this = this.clone();
                menu.item(
                    PopupMenuItem::new(reveal_title())
                        .disabled(!can_reveal)
                        .on_click(move |_, _, cx| {
                            let _ = this.update(cx, |this, cx| this.reveal_folder(cx));
                        }),
                )
            };
        let refresh = cx.listener(|this, _: &ClickEvent, _, cx| this.reload(true, cx));
        div()
            .flex()
            .flex_shrink_0()
            .items_center()
            .gap(px(6.))
            .pt(px(6.))
            .pb(px(6.))
            .pl(px(10.))
            .pr(px(8.))
            .border_b_1()
            .border_color(border)
            .child(
                Button::new("diff-scope")
                    .label(scope_title(scope))
                    .ghost()
                    .compact()
                    .dropdown_caret(true)
                    .disabled(!has_thread)
                    .accessibility_label("Changes to show")
                    .dropdown_menu(scope_menu),
            )
            .children(summary)
            .child(div().flex_1())
            .when(self.loading, |view| view.child(Spinner::new().small()))
            .child(
                Button::new("diff-refresh")
                    .icon(gpui_kit::assets::IconName::RefreshCw)
                    .ghost()
                    .compact()
                    .tooltip("Refresh")
                    .accessibility_label("Refresh")
                    .on_click(refresh),
            )
            .child(
                Button::new("diff-options")
                    .icon(gpui_kit::assets::IconName::Ellipsis)
                    .ghost()
                    .compact()
                    .tooltip("Diff options")
                    .accessibility_label("Diff options")
                    .dropdown_menu_with_anchor(Anchor::TopRight, options_menu),
            )
    }

    fn render_empty(&self, message: &Message, cx: &mut Context<Self>) -> AnyElement {
        let (icon, title, text) = message.content();
        let (tertiary, secondary) = (
            cx.theme().muted_foreground.opacity(0.65),
            cx.theme().muted_foreground,
        );
        let label = [title, text.as_str()]
            .into_iter()
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(". ");
        div()
            .id("diff-empty")
            .flex_1()
            .min_h_0()
            .flex()
            .items_center()
            .justify_center()
            .px(px(24.))
            .child(
                div()
                    .id("diff-empty-message")
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap(px(6.))
                    .mb(px(40.))
                    .role(Role::Group)
                    .aria_label(label)
                    .child(
                        Icon::new(icon)
                            .size(px(28.))
                            .text_color(tertiary)
                            .mb(px(4.)),
                    )
                    .child(
                        div()
                            .text_size(px(self.font_size + 1.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_center()
                            .child(title),
                    )
                    .when(!text.is_empty(), |view| {
                        view.child(
                            div()
                                .max_w(px(280.))
                                .text_size(px(self.font_size - 1.))
                                .text_color(secondary)
                                .text_center()
                                .child(text),
                        )
                    }),
            )
            .into_any_element()
    }

    fn render_files(&mut self, height: f32, cx: &mut Context<Self>) -> AnyElement {
        let diff = self.document.diff.clone();
        let theme = cx.theme();
        let (foreground, secondary, tertiary, selection) = (
            theme.foreground,
            theme.muted_foreground,
            theme.muted_foreground.opacity(0.65),
            theme.list_active,
        );
        let (addition, deletion, warning, info) =
            (theme.success, theme.danger, theme.warning, theme.info);
        let size = px(self.font_size - 1.);
        let selected = self.selected_file;
        let this = cx.entity().downgrade();
        div()
            .id("diff-file-list")
            .flex_shrink_0()
            .h(px(height))
            .min_h_0()
            .role(Role::List)
            .aria_label("Changed files")
            .child(
                uniform_list("diff-files", diff.files.len(), move |range, _, _| {
                    range
                        .map(|index| {
                            let file = &diff.files[index];
                            let color = match file.status {
                                workspace_diff::ChangeStatus::Added
                                | workspace_diff::ChangeStatus::Untracked => addition,
                                workspace_diff::ChangeStatus::Modified => warning,
                                workspace_diff::ChangeStatus::Deleted => deletion,
                                workspace_diff::ChangeStatus::Renamed => info,
                            };
                            let this = this.clone();
                            let tooltip = match &file.old_path {
                                Some(old) => format!("{old} → {}", file.path),
                                None => file.path.clone(),
                            };
                            div()
                                .id(ElementId::named_usize("diff-file", index))
                                .h(px(24.))
                                .px(px(4.))
                                .child(
                                    div()
                                        .size_full()
                                        .rounded(px(5.))
                                        .when(selected == Some(index), |view| view.bg(selection))
                                        .pl(px(8.))
                                        .pr(px(8.))
                                        .flex()
                                        .items_center()
                                        .gap(px(8.))
                                        .child(status_badge(
                                            file.status,
                                            color,
                                            (size - px(2.)).max(px(9.)),
                                        ))
                                        .child(div().flex_1().min_w_0().child(path_label(
                                            &file.path,
                                            file.old_path.as_deref(),
                                            size,
                                            foreground,
                                            secondary,
                                            tertiary,
                                        )))
                                        .child(counts(
                                            file,
                                            size - px(1.),
                                            addition,
                                            deletion,
                                            secondary,
                                            " ",
                                        )),
                                )
                                .role(Role::ListItem)
                                .aria_label(format!(
                                    "{}, {}, {} added, {} removed",
                                    file.path,
                                    file.status.name(),
                                    file.additions,
                                    file.deletions
                                ))
                                .tooltip(move |window, cx| {
                                    Tooltip::new(tooltip.clone()).build(window, cx)
                                })
                                .on_click(move |_, _, cx| {
                                    let _ = this.update(cx, |this, cx| this.select_file(index, cx));
                                })
                        })
                        .collect()
                })
                .track_scroll(&self.files)
                .size_full(),
            )
            .into_any_element()
    }

    fn render_diff(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        // The file list follows the file at the top of the diff as it scrolls.
        let visible = self.document.visible_file();
        if visible != self.followed_file
            && let Some(index) = visible
        {
            self.followed_file = Some(index);
            self.selected_file = Some(index);
            self.files.scroll_to_item(index, ScrollStrategy::Nearest);
        }
        let available = if self.split_height > 0. {
            self.split_height
        } else {
            480.
        };
        let count = self.document.diff.files.len();
        let height = clamp_file_list(
            self.dragged_height
                .unwrap_or_else(|| file_list_height(count, available)),
            available,
        );
        let border = cx.theme().border;
        let files = self.render_files(height, cx);
        let document = self.render_document(window, cx);
        let this = cx.entity().downgrade();
        div()
            .id("diff-split")
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .on_drag_move(
                cx.listener(|this, event: &DragMoveEvent<ResizeFileList>, _, cx| {
                    let top = event.bounds.origin.y;
                    let height = f32::from(event.event.position.y - top);
                    this.dragged_height =
                        Some(clamp_file_list(height, f32::from(event.bounds.size.height)));
                    cx.notify();
                }),
            )
            .child(files)
            .child(
                div()
                    .id("diff-split-divider")
                    .flex_shrink_0()
                    .h(px(5.))
                    .mt(px(-2.))
                    .mb(px(-2.))
                    .cursor(CursorStyle::ResizeRow)
                    .role(Role::Splitter)
                    .aria_label("Resize changed files")
                    .child(div().mt(px(2.)).h(px(1.)).bg(border))
                    .on_drag(ResizeFileList, |drag, _, _, cx| cx.new(|_| drag.clone())),
            )
            .child(document)
            .child(
                canvas(
                    move |bounds, _, cx| {
                        let _ = this.update(cx, |this, cx| {
                            let height = f32::from(bounds.size.height);
                            if (height - this.split_height).abs() > 0.5 {
                                this.split_height = height;
                                cx.notify();
                            }
                        });
                    },
                    |_, _, _, _| {},
                )
                .absolute()
                .size_full(),
            )
            .relative()
            .into_any_element()
    }
}

/// The platform's name for showing a folder in its file manager.
pub(crate) fn reveal_title() -> &'static str {
    if cfg!(target_os = "macos") {
        "Reveal Folder in Finder"
    } else if cfg!(target_os = "windows") {
        "Show Folder in File Explorer"
    } else {
        "Show Folder in File Manager"
    }
}

impl Drop for DiffPanel {
    fn drop(&mut self) {
        self.request_shutdown();
    }
}

impl Render for DiffPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let header = self.render_header(cx);
        let body = match &self.content {
            Content::Loading => div().flex_1().into_any_element(),
            Content::Empty(message) => {
                let message = message.clone();
                self.render_empty(&message, cx)
            }
            Content::Diff => self.render_diff(window, cx),
        };
        div()
            .id("diff-panel")
            .size_full()
            .min_h_0()
            .min_w_0()
            .flex()
            .flex_col()
            .bg(cx.theme().background)
            .role(Role::Group)
            .aria_label("Diff")
            .child(header)
            .when_some(self.notice.clone(), |view, notice| {
                view.child(div().px(px(10.)).py(px(4.)).text_xs().child(notice))
            })
            .child(body)
    }
}

#[cfg(test)]
#[path = "diff_panel_ui_tests.rs"]
mod native_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn schedule_coalesces_bursts_and_honors_the_live_floor() {
        let start = Instant::now();
        let mut schedule = ReloadSchedule::default();
        schedule.schedule(start, Duration::ZERO, false);
        assert!(!schedule.due(start + Duration::from_millis(399)));
        // A later request keeps the earlier deadline.
        schedule.schedule(start + Duration::from_millis(200), Duration::ZERO, false);
        assert!(schedule.due(start + Duration::from_millis(400)));
        assert!(!schedule.due(start + Duration::from_secs(1)));
        schedule.started(start + Duration::from_secs(1));
        schedule.schedule(
            start + Duration::from_secs(2),
            ReloadSchedule::LIVE_FLOOR,
            false,
        );
        assert!(!schedule.due(start + Duration::from_secs(10)));
        assert!(schedule.due(start + Duration::from_secs(11)));
        // An earlier deadline replaces a later one.
        schedule.started(start + Duration::from_secs(12));
        schedule.schedule(
            start + Duration::from_secs(13),
            ReloadSchedule::LIVE_FLOOR,
            false,
        );
        schedule.schedule(start + Duration::from_secs(13), Duration::ZERO, false);
        assert!(schedule.due(start + Duration::from_millis(13_400)));
    }

    #[::core::prelude::v1::test]
    fn requests_during_a_load_follow_it_with_the_lowest_floor() {
        let start = Instant::now();
        let mut schedule = ReloadSchedule::default();
        schedule.started(start);
        schedule.schedule(start, ReloadSchedule::LIVE_FLOOR, true);
        schedule.schedule(start, Duration::ZERO, true);
        assert!(!schedule.due(start + Duration::from_secs(60)));
        assert_eq!(schedule.finished(), Some(Duration::ZERO));
        assert_eq!(schedule.finished(), None);
        schedule.schedule(start + Duration::from_secs(1), Duration::ZERO, false);
        assert!(schedule.due(start + Duration::from_millis(1_400)));
    }

    #[::core::prelude::v1::test]
    fn workspace_changes_are_finished_mutating_tools_only() {
        let items = [
            json!({"id":"edit","kind":"tool","status":"completed","category":"fileChange"}),
            json!({"id":"read","kind":"tool","status":"completed","category":"read"}),
            json!({"id":"live","kind":"tool","status":"running","category":"command"}),
            json!({"id":"note","kind":"message","status":"completed"}),
        ];
        assert_eq!(workspace_change(&items).as_deref(), Some("edit"));
        let more = [
            items[0].clone(),
            json!({"kind":"tool","status":"failed","category":"command"}),
            json!({"id":"ask","kind":"tool","status":"waiting","category":"command"}),
        ];
        assert_eq!(workspace_change(&more).as_deref(), Some("#1"));
        assert_eq!(workspace_change(&items[1..]), None);
        assert_eq!(workspace_change(&[]), None);
    }

    #[::core::prelude::v1::test]
    fn labels_and_file_list_sizes_match_swift() {
        assert_eq!(files_label(1), "1 file");
        assert_eq!(files_label(3), "3 files");
        assert_eq!(file_list_height(2, 900.), 56.);
        assert_eq!(file_list_height(100, 900.), 300.);
        assert_eq!(file_list_height(100, 200.), 96.);
        assert_eq!(clamp_file_list(10., 600.), 48.);
        assert_eq!(clamp_file_list(590., 600.), 480.);
        assert_eq!(scope_title(Scope::Branch), "Branch Changes");
        assert_eq!(
            Message::NoBranchChanges(Some("origin/main".into()))
                .content()
                .2,
            "Nothing differs from origin/main."
        );
        assert_eq!(Message::NoBranchChanges(None).content().2, "");
    }

    #[::core::prelude::v1::test]
    fn loads_report_missing_folders_and_empty_scopes_without_dispatching_git() {
        let missing =
            std::env::temp_dir().join(format!("coincide-diff-missing-{}", uuid::Uuid::new_v4()));
        let mut calls = Vec::new();
        let request = Request {
            thread: "fixture".into(),
            scope: Scope::Uncommitted,
            ignore_whitespace: false,
        };
        let outcome = load(
            &mut |method: &str, _params: Value| {
                calls.push(method.to_owned());
                Ok(match method {
                    "threads.read" => json!({"worktreePath":missing}),
                    _ => anyhow::bail!("unexpected {method}"),
                })
            },
            &request,
        )
        .unwrap();
        assert!(
            matches!(outcome, Outcome::Empty(Message::FolderMissing(path)) if path == missing.display().to_string())
        );
        assert!(!calls.iter().any(|method| method == "git.review.diff"));
        let folder = tempfile::tempdir().unwrap();
        let mut sent = Value::Null;
        let outcome = load(
            &mut |method: &str, params: Value| {
                Ok(match method {
                    "threads.read" => json!({"worktreePath":folder.path()}),
                    "git.review.diff" => {
                        sent = params;
                        json!({"operationId":"op"})
                    }
                    "git.workspace.result" => json!({"ready":true,"result":{
                        "root": folder.path(), "patch": "", "numstat": [], "untracked": [],
                        "baseLabel": "origin/main", "truncated": false
                    }}),
                    _ => anyhow::bail!("unexpected {method}"),
                })
            },
            &Request {
                scope: Scope::Branch,
                ignore_whitespace: true,
                ..request
            },
        )
        .unwrap();
        assert!(matches!(
            outcome,
            Outcome::Empty(Message::NoBranchChanges(Some(base))) if base == "origin/main"
        ));
        assert_eq!(sent["scope"], "branch");
        assert_eq!(sent["ignoreWhitespace"], true);
        assert_eq!(
            Path::new(sent["expectedRoot"].as_str().unwrap()),
            folder.path().canonicalize().unwrap()
        );
    }
}
