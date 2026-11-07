//! Standalone GPUI Git workspace. Parent integration: `mod workspace;`, create an
//! Entity<WorkspacePanel> with new(engine, window, cx), call set_thread on selection,
//! and render that entity in the workspace surface. Requires workspace_api routes.
use crate::worker_owner::{Admission, ShutdownStatus as WorkerOwnerStatus, WorkerOwner};
use anyhow::{Context as _, Result, ensure};
use coincide_core::api::{SharedEngine, call};
use gpui_kit::base::Disableable;
use gpui_kit::{
    component::{
        button::*,
        input::{Input, InputState},
    },
    *,
};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    sync::mpsc,
    time::{Duration, Instant},
};

#[derive(Clone, Debug, PartialEq, Eq)]
struct Binding {
    thread: String,
    root: String,
    head: String,
}
#[derive(Clone)]
struct Snapshot {
    binding: Binding,
    status: Value,
    checkpoints: Value,
    worktrees: Value,
}
#[derive(Clone)]
enum Action {
    Refresh(String),
    Diff(Binding, Option<String>, bool),
    Review(Binding, String),
    Create(Binding, String),
    Reserve(Binding, String, String),
}
struct Outcome {
    snapshot: Option<Snapshot>,
    diff: Option<String>,
    notice: String,
}
fn string(value: &Value, key: &str) -> Result<String> {
    Ok(value[key]
        .as_str()
        .with_context(|| format!("Missing {key}"))?
        .to_owned())
}

// A worker owns the entire request/poll sequence; GPUI never waits on Git or the
// Engine mutex. Unknown mutation outcomes are displayed, never automatically retried.
fn operation(
    api: &mut impl FnMut(&str, Value) -> Result<Value>,
    method: &str,
    params: Value,
) -> Result<Value> {
    let owner = params["threadId"].clone();
    let reply = api(method, params)?;
    let id = string(&reply, "operationId")?;
    let result_method =
        if method.starts_with("git.checkpoints.") || method.starts_with("git.worktrees.") {
            "git.workspace.result"
        } else {
            "workspace.result"
        };
    let deadline = Instant::now() + Duration::from_secs(125);
    loop {
        let reply = api(result_method, json!({"threadId":owner,"operationId":id}))?;
        if reply["ready"] == true {
            let result = reply["result"].clone();
            ensure!(
                result["error"].is_null(),
                "{}",
                result["error"]
                    .as_str()
                    .unwrap_or("Workspace operation failed")
            );
            return Ok(result);
        }
        ensure!(
            Instant::now() < deadline,
            "Operation outcome unknown; refresh before retrying a mutation"
        );
        std::thread::sleep(Duration::from_millis(80));
    }
}
fn stored_root(api: &mut impl FnMut(&str, Value) -> Result<Value>, thread: &str) -> Result<String> {
    let value = api("threads.read", json!({"threadId":thread,"itemLimit":0}))?;
    let path = if let Some(path) = value["worktreePath"].as_str() {
        PathBuf::from(path)
    } else {
        let projects = api("projects.list", json!({}))?;
        let project = projects
            .as_array()
            .context("Invalid projects")?
            .iter()
            .find(|p| p["id"] == value["projectID"])
            .context("Choose a project working directory first")?;
        PathBuf::from(string(project, "path")?)
    };
    ensure!(path.is_absolute(), "Working directory must be absolute");
    Ok(path
        .canonicalize()?
        .to_str()
        .context("Working directory is not UTF-8")?
        .to_owned())
}
fn refresh(api: &mut impl FnMut(&str, Value) -> Result<Value>, thread: &str) -> Result<Snapshot> {
    let root = stored_root(api, thread)?;
    let params = json!({"threadId":thread,"expectedRoot":root});
    let worktrees = operation(api, "git.worktrees.list", params.clone())?;
    let current = worktrees["worktrees"]
        .as_array()
        .context("Invalid worktree list")?
        .iter()
        .find(|tree| {
            tree["worktree"]
                .as_str()
                .and_then(|p| Path::new(p).canonicalize().ok())
                .is_some_and(|p| p == Path::new(&root))
        })
        .context("Choose the repository root, rather than a subdirectory")?;
    let head = string(current, "HEAD")?;
    coincide_core::workspace_git::validate_oid(&head)?;
    let status = operation(api, "git.status", json!({"threadId":thread}))?;
    let checkpoints = operation(api, "git.checkpoints.list", params)?;
    ensure!(
        stored_root(api, thread)? == root,
        "Working directory changed during refresh"
    );
    Ok(Snapshot {
        binding: Binding {
            thread: thread.into(),
            root,
            head,
        },
        status,
        checkpoints,
        worktrees,
    })
}
fn run_admitted(
    api: &mut impl FnMut(&str, Value) -> Result<Value>,
    action: Action,
    admission: &Admission,
) -> Result<Outcome> {
    run(
        &mut |method, params| {
            ensure!(admission.allowed(), "Workflow is shutting down");
            api(method, params)
        },
        action,
    )
}
fn run(api: &mut impl FnMut(&str, Value) -> Result<Value>, action: Action) -> Result<Outcome> {
    let mut outcome = Outcome {
        snapshot: None,
        diff: None,
        notice: String::new(),
    };
    match action {
        Action::Refresh(thread) => outcome.snapshot = Some(refresh(api, &thread)?),
        Action::Diff(binding, path, staged) => {
            ensure!(
                stored_root(api, &binding.thread)? == binding.root,
                "Working directory changed; refresh"
            );
            let mut params = json!({"threadId":binding.thread,"staged":staged});
            if let Some(path) = path {
                params["path"] = json!(path);
            }
            outcome.diff = Some(string(&operation(api, "git.diff", params)?, "diff")?);
            outcome.notice = if staged {
                "Staged diff"
            } else {
                "Working diff (untracked file contents are not included)"
            }
            .into();
        }
        Action::Review(binding, id) => {
            outcome.diff = Some(string(
                &operation(
                    api,
                    "git.checkpoints.diff",
                    json!({"threadId":binding.thread,"expectedRoot":binding.root,"checkpointId":id}),
                )?,
                "diff",
            )?);
            outcome.notice = format!("Checkpoint {id}: staged snapshot relative to its parent");
        }
        Action::Create(binding, label) => {
            let created = operation(
                api,
                "git.checkpoints.create",
                json!({"threadId":binding.thread,"expectedRoot":binding.root,"expectedHead":binding.head,"label":label}),
            )?;
            outcome.notice = format!(
                "Created staged checkpoint {}. Working files and HEAD preserved.",
                string(&created, "id")?
            );
            match refresh(api, &binding.thread) {
                Ok(snapshot) => outcome.snapshot = Some(snapshot),
                Err(error) => outcome.notice.push_str(&format!(
                    " Refresh failed: {error}. Refresh before another mutation."
                )),
            }
        }
        Action::Reserve(binding, name, branch) => {
            let created = operation(
                api,
                "git.worktrees.reserve",
                json!({"threadId":binding.thread,"expectedRoot":binding.root,"base":binding.head,"name":name,"branch":branch}),
            )?;
            outcome.notice = format!(
                "Reserved {}. Unpopulated: no files were checked out. This panel cannot populate or launch it.",
                string(&created, "path")?
            );
            match refresh(api, &binding.thread) {
                Ok(snapshot) => outcome.snapshot = Some(snapshot),
                Err(error) => outcome.notice.push_str(&format!(
                    " Refresh failed: {error}. Refresh before another mutation."
                )),
            }
        }
    }
    Ok(outcome)
}

pub struct WorkspacePanel {
    workers: WorkerOwner,
    refresh_pending: bool,
    engine: SharedEngine,
    thread: Option<String>,
    root_hint: Option<String>,
    generation: u64,
    snapshot: Option<Snapshot>,
    diff: String,
    notice: String,
    busy: bool,
    confirmation: Option<Action>,
    label: Entity<InputState>,
    name: Entity<InputState>,
    branch: Entity<InputState>,
    tx: mpsc::Sender<(u64, Result<Outcome>)>,
    rx: mpsc::Receiver<(u64, Result<Outcome>)>,
    _poll: Task<()>,
}
impl WorkspacePanel {
    pub fn request_shutdown(&mut self) {
        if self.workers.close() {
            self.generation = self.generation.wrapping_add(1);
        }
        self.confirmation = None;
        self.refresh_pending = false;
        self.discard_shutdown_results();
    }
    fn discard_shutdown_results(&mut self) {
        for result in self.rx.try_iter() {
            drop(result);
        }
    }
    pub fn shutdown_status(&mut self) -> WorkerOwnerStatus {
        if self.workers.closed() {
            self.discard_shutdown_results();
        }
        self.workers.status()
    }
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
        Self {
            workers: WorkerOwner::default(),
            refresh_pending: false,
            engine,
            thread: None,
            root_hint: None,
            generation: 0,
            snapshot: None,
            diff: String::new(),
            notice: "Choose a conversation to inspect its Git workspace.".into(),
            busy: false,
            confirmation: None,
            label: cx.new(|cx| InputState::new(window, cx).placeholder("Staged checkpoint label")),
            name: cx.new(|cx| {
                InputState::new(window, cx).placeholder("Worktree folder name, e.g. task-42")
            }),
            branch: cx.new(|cx| {
                InputState::new(window, cx).placeholder("New branch, e.g. feature/task-42")
            }),
            tx,
            rx,
            _poll: poll,
        }
    }
    /// Parent must call on every selection change, including None. Results from a
    /// prior thread are discarded; in-flight Git is not cancelled or replayed.
    pub fn set_thread(&mut self, thread: Option<String>, cx: &mut Context<Self>) {
        if self.thread == thread {
            return;
        }
        self.set_context(thread, None, cx);
    }
    /// The hint is cached stored metadata, never canonicalized on the UI thread.
    /// A root change invalidates in-flight results even for the same thread.
    pub fn set_context(
        &mut self,
        thread: Option<String>,
        root_hint: Option<String>,
        cx: &mut Context<Self>,
    ) {
        if self.workers.closed() {
            return;
        }
        if self.thread == thread && self.root_hint == root_hint {
            return;
        }
        self.generation = self.generation.wrapping_add(1);
        self.thread = thread.clone();
        self.root_hint = root_hint;
        self.snapshot = None;
        self.diff.clear();
        self.confirmation = None;
        // Keep a single worker even across selection changes. poll() refreshes the
        // latest selected thread after collecting the previous worker's outcome.
        if !self.busy {
            if let Some(thread) = thread {
                self.refresh_pending = true;
                if self.workers.can_start() {
                    self.refresh_pending = false;
                    self.start(Action::Refresh(thread), cx);
                }
            } else {
                self.notice = "Choose a conversation to inspect its Git workspace.".into();
            }
        } else {
            self.notice = "Waiting for the previous workspace operation. It may finish after switching conversations.".into();
        }
        cx.notify();
    }
    /// A diff the parent read itself, such as one turn's changes. A later
    /// refresh keeps it; choosing another diff here replaces it.
    pub fn show_diff(&mut self, notice: String, diff: String, cx: &mut Context<Self>) {
        self.notice = notice;
        self.diff = diff;
        cx.notify();
    }
    /// Only a completed worker refresh supplies an authoritative canonical root.
    pub fn cached_context(&self) -> Option<(String, String)> {
        let binding = &self.snapshot.as_ref()?.binding;
        (self.thread.as_deref() == Some(binding.thread.as_str()))
            .then(|| (binding.thread.clone(), binding.root.clone()))
    }
    fn start(&mut self, action: Action, cx: &mut Context<Self>) {
        if self.busy || !self.workers.can_start() {
            return;
        }
        self.busy = true;
        self.confirmation = None;
        self.notice = "Working…".into();
        let engine = self.engine.clone();
        let tx = self.tx.clone();
        let generation = self.generation;
        if !self.workers.spawn(move |admission| {
            let result = run_admitted(
                &mut |method, params| call(&engine, method, params),
                action,
                &admission,
            );
            let _ = tx.send((generation, result));
        }) {
            self.busy = false;
            self.notice = "Background worker could not start.".into();
        }
        cx.notify();
    }
    fn poll(&mut self, cx: &mut Context<Self>) {
        self.workers.poll();
        if self.workers.closed() {
            self.discard_shutdown_results();
            return;
        }
        if self.refresh_pending && !self.busy && self.workers.can_start() {
            self.refresh_pending = false;
            if let Some(thread) = self.thread.clone() {
                self.start(Action::Refresh(thread), cx);
            }
        }
        let Ok((generation, result)) = self.rx.try_recv() else {
            return;
        };
        self.busy = false;
        if generation != self.generation {
            if self.thread.is_some() {
                self.refresh_pending = true;
            } else {
                self.notice = "No conversation selected. Refresh the previous workspace before retrying mutations.".into();
            }
            cx.notify();
            return;
        }
        match result {
            Ok(outcome) => {
                // Mutation success with failed refresh invalidates the baseline.
                if outcome.notice.starts_with("Created ") || outcome.notice.starts_with("Reserved ")
                {
                    self.snapshot = None;
                }
                if let Some(snapshot) = outcome.snapshot {
                    self.snapshot = Some(snapshot);
                }
                if let Some(diff) = outcome.diff {
                    self.diff = diff;
                }
                self.notice = if outcome.notice.is_empty() {
                    "Workspace refreshed".into()
                } else {
                    outcome.notice
                };
            }
            Err(error) => {
                self.snapshot = None;
                self.diff.clear();
                self.notice = format!("{error}. Refresh before retrying a mutation.");
            }
        }
        cx.notify();
    }
    fn prepare(&mut self, reserve: bool, cx: &mut Context<Self>) {
        let Some(snapshot) = &self.snapshot else {
            return;
        };
        let label = self.label.read(cx).value().trim().to_string();
        let name = self.name.read(cx).value().trim().to_string();
        let branch = self.branch.read(cx).value().trim().to_string();
        if (reserve && (name.is_empty() || branch.is_empty())) || (!reserve && label.is_empty()) {
            self.notice = "Enter the required fields first.".into();
            cx.notify();
            return;
        }
        self.confirmation = Some(if reserve {
            Action::Reserve(snapshot.binding.clone(), name, branch)
        } else {
            Action::Create(snapshot.binding.clone(), label)
        });
        cx.notify();
    }
}
impl Drop for WorkspacePanel {
    fn drop(&mut self) {
        self.request_shutdown();
    }
}
impl Render for WorkspacePanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let binding = self.snapshot.as_ref().map(|s| s.binding.clone());
        let disabled = self.busy || binding.is_none();
        let mut pane = div()
            .id("git-workspace")
            .size_full()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1().child("Git workspace"))
                    .child(
                        Button::new("git-refresh")
                            .label("Refresh")
                            .disabled(self.busy || self.thread.is_none())
                            .on_click(cx.listener(|this, _, _, cx| {
                                if let Some(thread) = this.thread.clone() {
                                    this.start(Action::Refresh(thread), cx);
                                }
                            })),
                    ),
            )
            .child(div().text_sm().child(self.notice.clone()));
        if let Some(binding) = &binding {
            pane = pane.child(
                div()
                    .text_sm()
                    .child(format!("Root: {}\nHEAD: {}", binding.root, binding.head)),
            );
        }
        let mut body = div()
            .id("git-workspace-content")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_2();
        if let Some(snapshot) = &self.snapshot {
            body = body.child(format!(
                "Branch: {} · {} changed paths",
                snapshot.status["branch"].as_str().unwrap_or("detached"),
                snapshot.status["entries"].as_array().map_or(0, Vec::len)
            ));
        }
        body = body.child(
            div().flex().gap_2().children(
                [(false, "Working diff"), (true, "Staged diff")]
                    .into_iter()
                    .map(|(staged, label)| {
                        Button::new(if staged {
                            "git-staged-diff"
                        } else {
                            "git-working-diff"
                        })
                        .label(label)
                        .disabled(disabled)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(s) = &this.snapshot {
                                this.start(Action::Diff(s.binding.clone(), None, staged), cx);
                            }
                        }))
                    }),
            ),
        );
        if let Some(snapshot) = &self.snapshot {
            for (index, entry) in snapshot.status["entries"]
                .as_array()
                .into_iter()
                .flatten()
                .take(200)
                .enumerate()
            {
                let path = entry["path"].as_str().unwrap_or_default().to_owned();
                let selected = path.clone();
                body = body.child(
                    Button::new(SharedString::from(format!("git-path-{index}")))
                        .label(format!("{} {path}", entry["status"].as_str().unwrap_or("")))
                        .disabled(disabled)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(s) = &this.snapshot {
                                this.start(
                                    Action::Diff(s.binding.clone(), Some(selected.clone()), false),
                                    cx,
                                );
                            }
                        })),
                );
            }
            if snapshot.status["entries"]
                .as_array()
                .is_some_and(|v| v.len() > 200)
            {
                body =
                    body.child("Showing first 200 paths. Full diff includes all tracked changes.");
            }
        }
        body = body.child("Staged checkpoints").child("Captures the staged index only. Unstaged and untracked files are excluded; HEAD and working files stay in place.")
            .child(Input::new(&self.label)).child(Button::new("git-prepare-checkpoint").label("Review checkpoint creation…").disabled(disabled).on_click(cx.listener(|this,_,_,cx|this.prepare(false,cx))));
        if let Some(snapshot) = &self.snapshot {
            for checkpoint in snapshot.checkpoints["checkpoints"]
                .as_array()
                .into_iter()
                .flatten()
                .take(100)
            {
                let id = checkpoint["id"].as_str().unwrap_or_default().to_owned();
                let selected = id.clone();
                body = body.child(
                    Button::new(SharedString::from(format!("git-checkpoint-{id}")))
                        .label(format!(
                            "Review {id} · {}",
                            checkpoint["commit"].as_str().unwrap_or("")
                        ))
                        .disabled(disabled)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(s) = &this.snapshot {
                                this.start(Action::Review(s.binding.clone(), selected.clone()), cx);
                            }
                        })),
                );
            }
            if snapshot.checkpoints["checkpoints"]
                .as_array()
                .is_some_and(|v| v.len() > 100)
            {
                body = body.child("Showing first 100 checkpoints.");
            }
        }
        body = body.child("Worktrees").child("Reservation creates a new branch and an UNPOPULATED linked worktree in Coincide's data directory. No files are checked out. Population and launch are not available here.")
            .child(Input::new(&self.name)).child(Input::new(&self.branch))
            .child(Button::new("git-prepare-worktree").label("Review worktree reservation…").disabled(disabled).on_click(cx.listener(|this,_,_,cx|this.prepare(true,cx))));
        if let Some(snapshot) = &self.snapshot {
            for tree in snapshot.worktrees["worktrees"]
                .as_array()
                .into_iter()
                .flatten()
                .take(100)
            {
                body = body.child(div().text_sm().child(format!("{}\n{} · {}\nPopulation state is not reported by Git list; a reservation from this panel starts unpopulated.",tree["worktree"].as_str().unwrap_or(""),tree["branch"].as_str().unwrap_or("detached"),tree["HEAD"].as_str().unwrap_or(""))));
            }
        }
        if self.snapshot.as_ref().is_some_and(|s| {
            s.worktrees["worktrees"]
                .as_array()
                .is_some_and(|v| v.len() > 100)
        }) {
            body = body.child("Showing first 100 worktrees.");
        }
        if let Some(action) = &self.confirmation {
            let message = match action {
                Action::Create(b, label) => format!(
                    "Create staged checkpoint ‘{label}’?\nRoot: {}\nExpected HEAD: {}",
                    b.root, b.head
                ),
                Action::Reserve(b, name, branch) => format!(
                    "Reserve unpopulated worktree ‘{name}’ on new branch ‘{branch}’?\nSource root: {}\nBase commit: {}",
                    b.root, b.head
                ),
                _ => String::new(),
            };
            pane = pane.child(
                div()
                    .id("git-confirmation")
                    .p_2()
                    .border_1()
                    .child(
                        div()
                            .id("git-confirmation-details")
                            .max_h(px(140.))
                            .overflow_y_scroll()
                            .child(message),
                    )
                    .child(
                        Button::new("git-confirm")
                            .label("Confirm")
                            .disabled(self.busy)
                            .on_click(cx.listener(|this, _, _, cx| {
                                if let Some(action) = this.confirmation.take() {
                                    this.start(action, cx);
                                }
                            })),
                    )
                    .child(
                        Button::new("git-cancel-confirmation")
                            .label("Cancel")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.confirmation = None;
                                cx.notify();
                            })),
                    ),
            );
        }
        body = body.child(
            Button::new("git-copy-diff")
                .label("Copy full loaded diff")
                .disabled(self.diff.is_empty())
                .on_click(cx.listener(|this, _, _, cx| {
                    cx.write_to_clipboard(ClipboardItem::new_string(this.diff.clone()));
                })),
        );
        body = body.child(
            div()
                .id("git-diff-text")
                .text_sm()
                .child(if self.diff.is_empty() {
                    "No diff loaded, or the selected diff is empty.".to_owned()
                } else {
                    self.diff.chars().take(100_000).collect::<String>()
                }),
        );
        if self.diff.chars().count() > 100_000 {
            body = body.child(
                "Diff display truncated at 100,000 characters. Narrow the path to inspect more.",
            );
        }
        pane.child(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    struct Fixture {
        root: PathBuf,
        requests: Vec<(String, Value)>,
        pending: HashMap<String, Value>,
        fail_refresh: bool,
        fail_mutation: bool,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "coincide-workspace-ui-fixture-{}",
                uuid::Uuid::new_v4()
            ));
            std::fs::create_dir(&root).unwrap();
            Self {
                root: root.canonicalize().unwrap(),
                requests: Vec::new(),
                pending: HashMap::new(),
                fail_refresh: false,
                fail_mutation: false,
            }
        }
        fn binding(&self) -> Binding {
            Binding {
                thread: "fixture-thread".into(),
                root: self.root.to_str().unwrap().into(),
                head: "a".repeat(40),
            }
        }
        fn api(&mut self, method: &str, params: Value) -> Result<Value> {
            self.requests.push((method.into(), params.clone()));
            match method {
                "threads.read" => {
                    ensure!(!self.fail_refresh, "Fixture refresh failure");
                    Ok(json!({"id":"fixture-thread","projectID":"fixture-project"}))
                }
                "projects.list" => Ok(json!([{"id":"fixture-project","path":self.root}])),
                "workspace.result" | "git.workspace.result" => {
                    let id = params["operationId"].as_str().unwrap();
                    let result = self
                        .pending
                        .remove(id)
                        .context("Unexpected result operation")?;
                    Ok(json!({"ready":true,"result":result}))
                }
                _ => {
                    let result = match method {
                        "git.worktrees.list" => {
                            json!({"worktrees":[{"worktree":self.root,"HEAD":"a".repeat(40),"branch":"refs/heads/fixture"}]})
                        }
                        "git.status" => {
                            json!({"branch":"fixture","entries":[{"path":"fixture.txt","status":" M"}]})
                        }
                        "git.checkpoints.list" => {
                            json!({"checkpoints":[{"id":"fixture-checkpoint","commit":"b".repeat(40)}]})
                        }
                        "git.diff" | "git.checkpoints.diff" => json!({"diff":"+fixture diff"}),
                        "git.checkpoints.create" if self.fail_mutation => {
                            json!({"error":"HEAD changed"})
                        }
                        "git.checkpoints.create" => json!({"id":"created-checkpoint"}),
                        "git.worktrees.reserve" => {
                            json!({"path":self.root.join("reserved"),"populated":false})
                        }
                        _ => anyhow::bail!("Unexpected method {method}"),
                    };
                    let id = uuid::Uuid::new_v4().to_string();
                    self.pending.insert(id.clone(), result);
                    Ok(json!({"operationId":id}))
                }
            }
        }
        fn execute(&mut self, action: Action) -> Result<Outcome> {
            run(&mut |method, params| self.api(method, params), action)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            std::fs::remove_dir(&self.root).unwrap();
        }
    }
    #[::core::prelude::v1::test]
    fn refresh_polls_both_contracts_and_binds_full_head() {
        let mut fixture = Fixture::new();
        let loaded = fixture
            .execute(Action::Refresh("fixture-thread".into()))
            .unwrap()
            .snapshot
            .unwrap();
        assert_eq!(loaded.binding, fixture.binding());
        assert_eq!(loaded.status["entries"][0]["path"], "fixture.txt");
        assert!(
            fixture
                .requests
                .iter()
                .any(|(m, _)| m == "workspace.result")
        );
        assert!(
            fixture
                .requests
                .iter()
                .any(|(m, _)| m == "git.workspace.result")
        );
        assert!(fixture.pending.is_empty());
    }
    #[::core::prelude::v1::test]
    fn checkpoint_sends_confirmed_root_head_label_and_refreshes_after_success() {
        let mut fixture = Fixture::new();
        let binding = fixture.binding();
        let outcome = fixture
            .execute(Action::Create(binding.clone(), "Confirmed label".into()))
            .unwrap();
        assert!(outcome.snapshot.is_some());
        assert!(outcome.notice.contains("created-checkpoint"));
        let params = &fixture
            .requests
            .iter()
            .find(|(m, _)| m == "git.checkpoints.create")
            .unwrap()
            .1;
        assert_eq!(
            params,
            &json!({"threadId":binding.thread,"expectedRoot":binding.root,"expectedHead":binding.head,"label":"Confirmed label"})
        );
        assert_eq!(
            fixture
                .requests
                .iter()
                .filter(|(m, _)| m == "git.checkpoints.create")
                .count(),
            1
        );
    }
    #[::core::prelude::v1::test]
    fn committed_mutation_with_failed_refresh_is_not_reported_as_failed_or_replayed() {
        let mut fixture = Fixture::new();
        fixture.fail_refresh = true;
        let binding = fixture.binding();
        let outcome = fixture
            .execute(Action::Create(binding, "fixture".into()))
            .unwrap();
        assert!(outcome.snapshot.is_none());
        assert!(outcome.notice.starts_with("Created "));
        assert!(outcome.notice.contains("Refresh failed"));
        assert_eq!(
            fixture
                .requests
                .iter()
                .filter(|(m, _)| m == "git.checkpoints.create")
                .count(),
            1
        );
    }
    #[::core::prelude::v1::test]
    fn failed_checkpoint_is_not_retried_and_does_not_refresh_as_success() {
        let mut fixture = Fixture::new();
        fixture.fail_mutation = true;
        let binding = fixture.binding();
        let error = fixture
            .execute(Action::Create(binding, "fixture".into()))
            .err()
            .unwrap();
        assert!(error.to_string().contains("HEAD changed"));
        assert_eq!(
            fixture
                .requests
                .iter()
                .filter(|(m, _)| m == "git.checkpoints.create")
                .count(),
            1
        );
        assert!(!fixture.requests.iter().any(|(m, _)| m == "threads.read"));
    }
    #[::core::prelude::v1::test]
    fn worktree_reservation_uses_confirmed_base_and_reports_unpopulated() {
        let mut fixture = Fixture::new();
        let binding = fixture.binding();
        let outcome = fixture
            .execute(Action::Reserve(
                binding.clone(),
                "task-42".into(),
                "feature/task-42".into(),
            ))
            .unwrap();
        assert!(outcome.notice.contains("Unpopulated"));
        assert!(outcome.notice.contains("no files were checked out"));
        let params = &fixture
            .requests
            .iter()
            .find(|(m, _)| m == "git.worktrees.reserve")
            .unwrap()
            .1;
        assert_eq!(
            params,
            &json!({"threadId":binding.thread,"expectedRoot":binding.root,"base":binding.head,"name":"task-42","branch":"feature/task-42"})
        );
    }
    #[::core::prelude::v1::test]
    fn diff_is_path_scoped_and_stale_root_prevents_dispatch() {
        let mut fixture = Fixture::new();
        let binding = fixture.binding();
        let outcome = fixture
            .execute(Action::Diff(
                binding.clone(),
                Some("[literal].txt".into()),
                true,
            ))
            .unwrap();
        assert_eq!(outcome.diff.as_deref(), Some("+fixture diff"));
        assert!(
            fixture.requests.iter().any(|(m, p)| m == "git.diff"
                && p["path"] == "[literal].txt"
                && p["staged"] == true)
        );
        let mut stale = binding;
        stale.root.push_str("-stale");
        fixture.requests.clear();
        assert!(fixture.execute(Action::Diff(stale, None, false)).is_err());
        assert!(!fixture.requests.iter().any(|(m, _)| m == "git.diff"));
    }
    #[::core::prelude::v1::test]
    fn checkpoint_review_sends_root_and_id() {
        let mut fixture = Fixture::new();
        let binding = fixture.binding();
        let outcome = fixture
            .execute(Action::Review(binding.clone(), "checkpoint-id".into()))
            .unwrap();
        assert_eq!(outcome.diff.as_deref(), Some("+fixture diff"));
        assert!(
            fixture
                .requests
                .iter()
                .any(|(m, p)| m == "git.checkpoints.diff"
                    && p["expectedRoot"] == binding.root
                    && p["checkpointId"] == "checkpoint-id")
        );
    }
}

#[cfg(test)]
mod shutdown_tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn closed_admitted_worker_does_not_dispatch_and_retains_actual_join_ownership() {
        let mut owner = WorkerOwner::default();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let probe = calls.clone();
        assert!(owner.spawn(move |admission| {
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            assert!(
                run_admitted(
                    &mut |_, _| {
                        probe.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        Ok(json!({}))
                    },
                    Action::Refresh("synthetic-thread".into()),
                    &admission
                )
                .is_err()
            );
        }));
        entered_rx
            .recv_timeout(std::time::Duration::from_secs(3))
            .unwrap();
        owner.close();
        assert_eq!(owner.status().unjoined, 1);
        release_tx.send(()).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while owner.status().unjoined != 0 {
            assert!(std::time::Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(owner.status().returned, 1);
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 0);
        assert!(!owner.spawn(|_| panic!("closed owner cannot restart")));
    }
}
