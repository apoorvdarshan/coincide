//! The `/` command, `$` skill and `#` pull-request list above the composer (Swift's
//! `ComposerSuggestionPanel`). It never takes focus: typing stays in the composer while Up and
//! Down move the highlight, Return or Tab choose and Escape hides it until the caret leaves the
//! word. `@` paths stay with the file picker.
use super::*;
use crate::worker_owner::{Admission, ShutdownStatus, WorkerOwner};
use coincide_core::composer_suggestions::{
    self as catalog, BuiltIn, CommandKind, ProviderCommand, PullRequest, Trigger, TriggerKind,
};
use gpui_base::{Align, ElementExt as _, Placement, Positioner};
use gpui_kit::component::input::{InlineToken, InputContent};
use std::{cell::Cell, ops::Range, rc::Rc, sync::mpsc};

const ROW_HEIGHT: f32 = 30.;
const MAX_VISIBLE_ROWS: usize = 8;
const PADDING: f32 = 6.;
/// Agent lists are capped, as in Swift; pull requests are capped by their matcher.
const MAX_AGENT_ROWS: usize = 200;
const MAX_PULL_ROWS: usize = 50;
/// A pull request list older than this is read again when `#` opens.
const PULL_MAX_AGE: Duration = Duration::from_secs(60);

#[derive(Clone, Debug, PartialEq)]
pub(super) enum Suggestion {
    Command(BuiltIn),
    /// One of the agent's own commands or skills, written as `token` (`/` or `$`) plus its name.
    Agent {
        command: ProviderCommand,
        provider: String,
        token: char,
    },
    /// An open pull request of the thread's repository, written as a `[#123](url)` mention.
    PullRequest(PullRequest),
}
impl Suggestion {
    fn agent_insertion(command: &ProviderCommand, token: char) -> String {
        // Claude's skills are invoked with `/`, even when found through `$`.
        let token = if token == '$' && command.is_slash_command {
            '/'
        } else {
            token
        };
        format!("{token}{} ", command.name)
    }
    fn title(&self) -> String {
        match self {
            Self::Command(command) => command.title(),
            Self::Agent { command, token, .. } => match &command.argument_hint {
                Some(hint) => format!("{token}{} {hint}", command.name),
                None => format!("{token}{}", command.name),
            },
            Self::PullRequest(pull) => format!("#{} {}", pull.number, pull.title),
        }
    }
    fn detail(&self) -> String {
        match self {
            Self::Command(command) => command.summary(),
            Self::Agent { command, .. } => command.description.clone().unwrap_or_default(),
            Self::PullRequest(pull) => pull
                .author
                .clone()
                .unwrap_or_else(|| pull.head_branch.clone()),
        }
    }
    /// What VoiceOver and other readers hear for the row.
    fn accessible(&self) -> String {
        let (title, detail) = match self {
            Self::PullRequest(pull) => (
                format!("Pull request #{}, {}", pull.number, pull.title),
                self.detail(),
            ),
            Self::Agent { command, token, .. } => {
                (format!("{token}{}", command.name), self.detail())
            }
            _ => (self.title(), self.detail()),
        };
        if detail.is_empty() {
            title
        } else {
            format!("{title}, {detail}")
        }
    }
}

/// The word the list completes, bound to the exact draft and caret it was read from.
#[derive(Clone, Debug, PartialEq)]
struct Live {
    thread: String,
    provider: String,
    account: Value,
    draft: String,
    selection: Range<usize>,
    trigger: Trigger,
}
impl Live {
    fn same_word(&self, other: &Self) -> bool {
        self.thread == other.thread
            && self.trigger.kind == other.trigger.kind
            && self.trigger.range.start == other.trigger.range.start
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Key {
    Up,
    Down,
    Enter,
    Tab,
    Escape,
}
impl Key {
    fn activation(self) -> Option<usize> {
        match self {
            Self::Enter => Some(0),
            Self::Tab => Some(1),
            _ => None,
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Decision {
    Pass,
    Consume,
    Select(usize),
    Choose(usize),
    Dismiss,
}
/// Swift's `doCommandBy` routing, plus custody of the key that chose a row until its key-up,
/// so a held Return cannot go on to send the message.
#[derive(Default)]
pub(super) struct Keys {
    held: [Option<String>; 2],
}
impl Keys {
    pub fn release(&mut self, key: Key) {
        if let Some(index) = key.activation() {
            self.held[index] = None;
        }
    }
    pub fn decide(
        &mut self,
        key: Key,
        thread: &str,
        visible: bool,
        trigger: bool,
        count: usize,
        selected: usize,
    ) -> Decision {
        if let Some(index) = key.activation()
            && self.held[index].as_deref() == Some(thread)
        {
            return Decision::Consume;
        }
        match key {
            Key::Escape if visible || trigger => Decision::Dismiss,
            Key::Up | Key::Down if visible && count == 0 => Decision::Consume,
            Key::Up | Key::Down if visible => {
                let current = selected.min(count - 1);
                Decision::Select(if key == Key::Down {
                    (current + 1) % count
                } else {
                    (current + count - 1) % count
                })
            }
            Key::Enter | Key::Tab if visible && selected < count => {
                self.held[key.activation().unwrap()] = Some(thread.into());
                Decision::Choose(selected)
            }
            _ => Decision::Pass,
        }
    }
}

#[derive(Clone)]
struct Queued {
    command: crate::composer_commands::Command,
    thread: String,
    draft: String,
    until: Instant,
}
struct PullList {
    key: String,
    /// None when the folder has no github.com remote or `gh` is unavailable.
    list: Option<Vec<PullRequest>>,
    read_at: Instant,
}
type PullReply = (
    String,
    std::result::Result<Option<Vec<PullRequest>>, String>,
);
type CommandReply = (
    String,
    std::result::Result<Option<coincide_core::api::NativeCommandReceipt>, String>,
);

pub(super) struct Suggestions {
    live: Option<Live>,
    /// A word dismissed with Escape stays hidden until the caret leaves it.
    dismissed: Option<Live>,
    items: Vec<Suggestion>,
    selected: usize,
    visible: bool,
    empty_text: Option<&'static str>,
    label: &'static str,
    pub keys: Keys,
    anchor: Rc<Cell<Option<Bounds<Pixels>>>>,
    scroll: ScrollHandle,
    commands: Option<(String, Vec<ProviderCommand>)>,
    commands_revision: u64,
    /// The built-ins last listed, so the list follows agents and limits as they load.
    builtins: Vec<BuiltIn>,
    pulls: Option<PullList>,
    pulls_revision: u64,
    shown_revision: u64,
    pull_pending: Option<String>,
    workers: WorkerOwner,
    sender: mpsc::SyncSender<PullReply>,
    receiver: mpsc::Receiver<PullReply>,
    command_workers: WorkerOwner,
    command_sender: mpsc::SyncSender<CommandReply>,
    command_receiver: mpsc::Receiver<CommandReply>,
    command_pending: Option<String>,
    command_receipt: Option<(String, coincide_core::api::NativeCommandReceipt)>,
    command_attempts: std::collections::HashMap<String, Instant>,
    /// A command chosen from the list, run once its edited draft is saved.
    queued: Option<Queued>,
}
impl Default for Suggestions {
    fn default() -> Self {
        let (sender, receiver) = mpsc::sync_channel(1);
        let (command_sender, command_receiver) = mpsc::sync_channel(1);
        Self {
            live: None,
            dismissed: None,
            items: Vec::new(),
            selected: 0,
            visible: false,
            empty_text: None,
            label: "Commands",
            keys: Keys::default(),
            anchor: Rc::default(),
            scroll: ScrollHandle::new(),
            commands: None,
            commands_revision: 0,
            builtins: Vec::new(),
            pulls: None,
            pulls_revision: 0,
            shown_revision: 0,
            pull_pending: None,
            workers: WorkerOwner::default(),
            sender,
            receiver,
            command_workers: WorkerOwner::default(),
            command_sender,
            command_receiver,
            command_pending: None,
            command_receipt: None,
            command_attempts: Default::default(),
            queued: None,
        }
    }
}
impl Suggestions {
    fn hide(&mut self) {
        self.visible = false;
        self.items.clear();
        self.empty_text = None;
    }
    fn show(
        &mut self,
        items: Vec<Suggestion>,
        empty_text: Option<&'static str>,
        label: &'static str,
    ) {
        let previous = self.items.get(self.selected).cloned();
        self.selected = previous
            .and_then(|item| items.iter().position(|candidate| *candidate == item))
            .unwrap_or(0);
        self.items = items;
        self.empty_text = empty_text;
        self.label = label;
        self.visible = !self.items.is_empty() || empty_text.is_some();
        self.scroll.scroll_to_item(self.selected);
    }
    pub fn close(&mut self) {
        self.workers.close();
        self.command_workers.close();
        self.live = None;
        self.queued = None;
        self.hide();
    }
    pub fn shutdown_status(&mut self) -> ShutdownStatus {
        let mut status = self.workers.status();
        let commands = self.command_workers.status();
        status.closed &= commands.closed;
        status.unjoined += commands.unjoined;
        status.returned = status.returned.saturating_add(commands.returned);
        status.panicked = status.panicked.saturating_add(commands.panicked);
        status.unclassified += commands.unclassified;
        status.pending_pickers += commands.pending_pickers;
        if status.spawn_error.is_none() {
            status.spawn_error = commands.spawn_error;
        }
        status
    }
    pub fn closed_and_drained(&mut self) -> bool {
        let status = self.shutdown_status();
        status.closed && status.unjoined == 0 && status.unclassified == 0
    }
}

/// Pull request lists are kept per folder: a project, or one of its worktrees.
fn pull_key(thread: &Value) -> String {
    format!("{}\0{}", thread["projectID"], thread["worktreePath"])
}

fn admitted_call(
    engine: &SharedEngine,
    admission: &Admission,
    method: &str,
    params: Value,
) -> Result<Value> {
    anyhow::ensure!(admission.allowed(), "Pull request reads are closed");
    coincide_core::api::call(engine, method, params)
}

/// The thread folder's open pull requests through the read-only GitHub service: its primary
/// remote must be on github.com and `gh` installed, as `#` is plain text otherwise.
fn read_pulls(
    engine: &SharedEngine,
    thread: &str,
    admission: &Admission,
) -> Result<Option<Vec<PullRequest>>> {
    let root = {
        let engine = engine
            .lock()
            .map_err(|_| anyhow::anyhow!("App owner is unavailable"))?;
        anyhow::ensure!(admission.allowed(), "Pull request reads are closed");
        if engine.github_cli_path().is_err() {
            return Ok(None);
        }
        engine.github_write_root(thread)?
    };
    let Some(repository) = catalog::github_repository(&root)? else {
        return Ok(None);
    };
    let expected = root.to_string_lossy().into_owned();
    let start = admitted_call(
        engine,
        admission,
        "github.pr.list",
        json!({"threadId":thread,"expectedRoot":expected,"repository":repository,"state":"open","limit":MAX_PULL_ROWS}),
    )?;
    let operation = start["operationId"]
        .as_str()
        .context("Missing GitHub operation ID")?
        .to_owned();
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let reply = admitted_call(
            engine,
            admission,
            "github.result",
            json!({"threadId":thread,"expectedRoot":expected,"operationId":operation}),
        )?;
        if reply["ready"] == true {
            let payload = &reply["result"];
            if let Some(error) = payload["error"].as_str() {
                anyhow::bail!("{error}");
            }
            anyhow::ensure!(
                payload["kind"] == "list"
                    && payload["threadId"] == thread
                    && payload["repository"] == repository.as_str(),
                "Pull request list belongs to another thread or repository"
            );
            return Ok(Some(
                payload["pullRequests"]
                    .as_array()
                    .context("Missing pull request list")?
                    .iter()
                    .filter_map(PullRequest::from_list)
                    .collect(),
            ));
        }
        anyhow::ensure!(reply["ready"] == false, "Invalid GitHub polling response");
        anyhow::ensure!(Instant::now() < deadline, "GitHub read timed out");
        std::thread::sleep(Duration::from_millis(80));
    }
}

impl Coincide {
    fn suggestion_route(&self, window: &Window, cx: &App) -> bool {
        window.is_window_active()
            && self.microphone_window_active
            && self.chat_visible()
            && !self.command_palette.read(cx).is_open()
            && !self.historical_image_is_open()
            && !self.media.close_requested
            && !self.media.shutdown_requested
            && !self.composer_files.opened
            && self.voice.preview.is_none()
    }
    /// The `/`, `$` or `#` word at the caret of the focused composer, if it asks for completions.
    fn live_suggestion_trigger(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<Live> {
        if !self.suggestion_route(window, cx) {
            return None;
        }
        let thread = self.selected.as_ref()?;
        let id = text(thread, "id");
        // A native WebKit responder is not represented by GPUI focus handles.
        if id.is_empty()
            || self.browser_panels.contains(&id)
            || !self.composer.read(cx).focus_handle(cx).is_focused(window)
        {
            return None;
        }
        let provider = text(&thread["selection"], "provider");
        let account = thread["selection"]["accountID"].clone();
        let (draft, selection, reversed, marked, editable, tokens) =
            self.composer.update(cx, |input, cx| {
                (
                    input.value().to_string(),
                    input.selected_range(),
                    input.is_selection_reversed(),
                    gpui_kit::EntityInputHandler::marked_text_range(input, window, cx).is_some(),
                    input.is_editable(),
                    input
                        .tokens()
                        .iter()
                        .map(|token| token.range())
                        .collect::<Vec<_>>(),
                )
            });
        if marked
            || !editable
            || reversed
            || selection.start != selection.end
            || draft.len() > 1024 * 1024
        {
            return None;
        }
        let trigger = catalog::detect(&draft, selection.end)?;
        if trigger.query.len() > 256
            || trigger.query.chars().any(char::is_control)
            || tokens
                .iter()
                .any(|token| token.start < trigger.range.end && trigger.range.start < token.end)
        {
            return None;
        }
        // The pinned toolkit validates grapheme boundaries without changing the input.
        InputContent::new(&draft)
            .with_token(
                trigger.range.clone(),
                InlineToken::new("suggestion-range-proof", &draft[trigger.range.clone()]),
            )
            .ok()?;
        Some(Live {
            thread: id,
            provider,
            account,
            draft,
            selection,
            trigger,
        })
    }
    pub(super) fn sync_composer_suggestions(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.media.close_requested || self.media.shutdown_requested {
            self.composer_suggestions.close();
            return;
        }
        self.run_queued_suggestion_command(window, cx);
        let mut live = self.live_suggestion_trigger(window, cx);
        match (&live, &self.composer_suggestions.dismissed) {
            (Some(current), Some(dismissed)) if current.same_word(dismissed) => live = None,
            _ => self.composer_suggestions.dismissed = None,
        }
        let state = &self.composer_suggestions;
        let changed = state.live != live;
        let pulls_changed = live
            .as_ref()
            .is_some_and(|live| live.trigger.kind == TriggerKind::PullRequest)
            && state.shown_revision != state.pulls_revision;
        let builtins_changed = live.as_ref().is_some_and(|live| {
            live.trigger.kind == TriggerKind::Command
                && self.composer_builtins(live) != self.composer_suggestions.builtins
        });
        let reports_changed = live.as_ref().is_some_and(|live| {
            matches!(live.trigger.kind, TriggerKind::Command | TriggerKind::Skill)
                && state.commands_revision != self.revision
        });
        if !changed && !pulls_changed && !builtins_changed && !reports_changed {
            return;
        }
        self.composer_suggestions.commands_revision = self.revision;
        self.composer_suggestions.live = live;
        self.load_composer_suggestions(cx);
    }
    fn load_composer_suggestions(&mut self, cx: &mut Context<Self>) {
        let Some(live) = self.composer_suggestions.live.clone() else {
            self.composer_suggestions.hide();
            return;
        };
        match live.trigger.kind {
            TriggerKind::Command | TriggerKind::Skill => {
                let skills = live.trigger.kind == TriggerKind::Skill;
                self.start_native_command_discovery(&live);
                let mut items = if skills {
                    Vec::new()
                } else {
                    let builtins = self.composer_builtins(&live);
                    let matching = BuiltIn::matching(&live.trigger.query, &builtins);
                    self.composer_suggestions.builtins = builtins;
                    matching.into_iter().map(Suggestion::Command).collect()
                };
                let commands = self.reported_agent_commands(&live);
                let offered = commands
                    .into_iter()
                    .filter(|command| {
                        if skills {
                            command.kind == CommandKind::Skill
                        } else {
                            command.is_slash_command
                        }
                    })
                    .collect::<Vec<_>>();
                items.extend(
                    ProviderCommand::matching(&live.trigger.query, &offered)
                        .into_iter()
                        .take(MAX_AGENT_ROWS)
                        .map(|command| Suggestion::Agent {
                            command: command.clone(),
                            provider: live.provider.clone(),
                            token: if skills { '$' } else { '/' },
                        }),
                );
                if items.is_empty()
                    && self.composer_suggestions.command_pending.is_some()
                    && matches!(live.provider.as_str(), "codex" | "opencode" | "claude")
                {
                    self.composer_suggestions.show(
                        items,
                        Some("Loading skills…"),
                        if skills { "Skills" } else { "Commands" },
                    );
                } else if items.is_empty() {
                    self.composer_suggestions.hide();
                } else {
                    self.composer_suggestions.show(
                        items,
                        None,
                        if skills { "Skills" } else { "Commands" },
                    );
                }
            }
            TriggerKind::PullRequest => self.load_pull_suggestions(&live),
        }
        cx.notify();
    }
    fn start_native_command_discovery(&mut self, live: &Live) {
        if !matches!(live.provider.as_str(), "codex" | "opencode" | "claude")
            || self.composer_suggestions.command_pending.is_some()
        {
            return;
        }
        let Some(thread) = self
            .selected
            .as_ref()
            .filter(|thread| thread["id"] == live.thread)
        else {
            return;
        };
        let key = format!(
            "{}\0{}\0{}\0{}\0{}",
            live.thread, live.provider, live.account, thread["projectID"], thread["worktreePath"]
        );
        if self
            .composer_suggestions
            .command_attempts
            .get(&key)
            .is_some_and(|at| at.elapsed() < Duration::from_secs(60))
        {
            return;
        }
        let engine = self.engine.clone();
        let sender = self.composer_suggestions.command_sender.clone();
        let id = live.thread.clone();
        let worker_key = key.clone();
        if self
            .composer_suggestions
            .command_workers
            .spawn(move |admission| {
                let result = (|| -> Result<Option<coincide_core::api::NativeCommandReceipt>> {
                    let request = {
                        let engine = engine
                            .try_lock()
                            .map_err(|_| anyhow::anyhow!("App is busy"))?;
                        engine.prepare_native_command_discovery(&id)?
                    };
                    request
                        .map(|request| request.read(|| admission.allowed()))
                        .transpose()
                })()
                .map_err(|error| error.to_string());
                let _ = sender.send((worker_key, result));
            })
        {
            self.composer_suggestions
                .command_attempts
                .insert(key.clone(), Instant::now());
            self.composer_suggestions.command_pending = Some(key);
        }
    }
    fn poll_native_command_discovery(&mut self, cx: &mut Context<Self>) {
        if let Ok((key, result)) = self.composer_suggestions.command_receiver.try_recv() {
            self.composer_suggestions.command_pending = None;
            match result {
                Ok(Some(receipt)) => {
                    self.composer_suggestions.command_receipt = Some((key, receipt))
                }
                Err(error) if error.contains("busy") => {
                    self.composer_suggestions.command_attempts.remove(&key);
                }
                _ => {}
            }
            self.composer_suggestions.commands_revision = self.revision.wrapping_sub(1);
            cx.notify();
        }
        if self.composer_suggestions.command_receipt.is_some()
            && let Ok(mut engine) = self.engine.try_lock()
        {
            let (key, receipt) = self.composer_suggestions.command_receipt.take().unwrap();
            if engine.accept_native_command_discovery(receipt).is_err() {
                self.composer_suggestions.command_attempts.remove(&key);
            }
            self.composer_suggestions.commands_revision = self.revision.wrapping_sub(1);
            cx.notify();
        }
        if self.composer_suggestions.command_pending.is_some()
            && self.composer_suggestions.command_workers.status().unjoined == 0
        {
            self.composer_suggestions.command_pending = None;
            self.composer_suggestions.commands_revision = self.revision.wrapping_sub(1);
            cx.notify();
        }
    }
    /// `/model`, `/plan`, `/build`, `/usage-limits` when reported, then one per other agent
    /// this conversation can switch to.
    fn composer_builtins(&self, live: &Live) -> Vec<BuiltIn> {
        let agents = self.composer_selection_capabilities()["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|row| {
                row["enabled"] != false
                    && row["provider"] != live.provider.as_str()
                    && matches!(
                        row["accountPolicy"].as_str(),
                        Some("default_only" | "configured_codex_profile")
                    )
            })
            .filter_map(|row| {
                let provider = row["provider"].as_str()?;
                // Only agents the Send-time command accepts, such as `/codex`.
                crate::composer_commands::standalone(&format!("/{provider}"))?;
                Some((
                    provider.to_owned(),
                    row["displayName"].as_str().unwrap_or(provider).to_owned(),
                ))
            })
            .collect::<Vec<_>>();
        // Only reported default-account Codex limits are connected to `/usage-limits`.
        let limits = live.provider == "codex"
            && matches!(live.account.as_str(), None | Some("" | "default"))
            && self
                .codex_limits
                .reported_observation()
                .is_some_and(|observed| crate::codex_limits_mount::has_reported_windows(&observed));
        BuiltIn::available(&agents, limits)
    }
    /// What the thread's agent reported: its session's commands and skills, else what it
    /// reported last in this folder. A busy engine keeps the previous answer for the agent.
    fn reported_agent_commands(&mut self, live: &Live) -> Vec<ProviderCommand> {
        let key = format!("{}\0{}\0{}", live.thread, live.provider, live.account);
        if let Ok(reply) = call(
            &self.engine,
            "composer.commands",
            json!({"threadId":live.thread}),
        ) && reply["provider"] == live.provider.as_str()
            && let Ok(commands) = serde_json::from_value(reply["commands"].clone())
        {
            self.composer_suggestions.commands = Some((key.clone(), commands));
        }
        match &self.composer_suggestions.commands {
            Some((cached, commands)) if *cached == key => commands.clone(),
            _ => Vec::new(),
        }
    }
    /// The last list at once, then a fresh one when it is older than a minute. Like `/` and
    /// `$`, the list closes when nothing matches, since `#` also starts headings and hashtags.
    fn load_pull_suggestions(&mut self, live: &Live) {
        let Some(thread) = self
            .selected
            .clone()
            .filter(|thread| thread["id"] == live.thread.as_str())
        else {
            return self.composer_suggestions.hide();
        };
        let key = pull_key(&thread);
        let state = &mut self.composer_suggestions;
        state.shown_revision = state.pulls_revision;
        let cached = state.pulls.as_ref().filter(|pulls| pulls.key == key);
        let stale = cached.is_none_or(|pulls| pulls.read_at.elapsed() >= PULL_MAX_AGE);
        let items = cached.map(|pulls| {
            pulls.list.as_ref().map(|list| {
                PullRequest::matching(&live.trigger.query, list, MAX_PULL_ROWS)
                    .into_iter()
                    .cloned()
                    .map(Suggestion::PullRequest)
                    .collect::<Vec<_>>()
            })
        });
        if stale && state.pull_pending.is_none() {
            let engine = self.engine.clone();
            let sender = state.sender.clone();
            let thread_id = live.thread.clone();
            let reply_key = key.clone();
            if state.workers.spawn(move |admission| {
                let result =
                    read_pulls(&engine, &thread_id, &admission).map_err(|error| error.to_string());
                let _ = sender.send((reply_key, result));
            }) {
                state.pull_pending = Some(key);
            }
        }
        match items {
            Some(Some(items)) if !items.is_empty() => state.show(items, None, "Pull requests"),
            None if state.pull_pending.is_some() => {
                state.show(Vec::new(), Some("Loading pull requests…"), "Pull requests")
            }
            _ => state.hide(),
        }
    }
    pub(super) fn poll_composer_suggestions(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.poll_native_command_discovery(cx);
        self.run_queued_suggestion_command(window, cx);
        let state = &mut self.composer_suggestions;
        // A worker that stopped without replying leaves nothing pending, so `#` can retry.
        let finished = state.workers.status().unjoined == 0;
        let Ok((key, result)) = state.receiver.try_recv() else {
            if finished && state.pull_pending.take().is_some() {
                state.pulls_revision = state.pulls_revision.wrapping_add(1);
                cx.notify();
            }
            return;
        };
        state.pull_pending = None;
        let previous = state
            .pulls
            .take()
            .filter(|pulls| pulls.key == key)
            .and_then(|pulls| pulls.list);
        // A failed read keeps the last good list, as Swift's cache does, but waits a minute.
        let list = match result {
            Ok(list) => list,
            Err(_) => Some(previous.unwrap_or_default()),
        };
        state.pulls = Some(PullList {
            key,
            list,
            read_at: Instant::now(),
        });
        state.pulls_revision = state.pulls_revision.wrapping_add(1);
        cx.notify();
    }

    /// Bound to the composer's private suggestion keys after the file picker declined them.
    pub(super) fn composer_suggestion_key(
        &mut self,
        key: Key,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let thread = self
            .selected
            .as_ref()
            .map(|thread| text(thread, "id"))
            .unwrap_or_default();
        if thread.is_empty() {
            return false;
        }
        // Read the word again so a stale list never chooses for text that changed.
        let live = self.live_suggestion_trigger(window, cx);
        let state = &mut self.composer_suggestions;
        let current = live.is_some() && live == state.live;
        let decision = state.keys.decide(
            key,
            &thread,
            current && state.visible,
            current,
            state.items.len(),
            state.selected,
        );
        match decision {
            Decision::Pass => return false,
            Decision::Consume => {}
            Decision::Select(index) => {
                state.selected = index;
                state.scroll.scroll_to_item(index);
                cx.notify();
            }
            Decision::Choose(index) => self.choose_composer_suggestion(index, window, cx),
            Decision::Dismiss => {
                state.dismissed = state.live.take();
                state.hide();
                cx.notify();
            }
        }
        true
    }

    fn choose_composer_suggestion(
        &mut self,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let state = &self.composer_suggestions;
        let (Some(live), Some(item)) = (state.live.clone(), state.items.get(index).cloned()) else {
            return;
        };
        let insertion = match &item {
            Suggestion::Command(_) => String::new(),
            Suggestion::Agent { command, token, .. } => {
                Suggestion::agent_insertion(command, *token)
            }
            Suggestion::PullRequest(pull) => match pull.markdown() {
                Some(mention) => format!("{mention} "),
                None => return,
            },
        };
        let (expected, replaced) =
            catalog::replacement(&live.draft, live.trigger.range.clone(), &insertion);
        let utf16 = live.draft[..replaced.start].encode_utf16().count()
            ..live.draft[..replaced.end].encode_utf16().count();
        let applied = self.composer.update(cx, |input, cx| {
            use gpui_kit::EntityInputHandler;
            if input.value().as_ref() != live.draft
                || input.selected_range() != live.selection
                || !input.is_editable()
                || input.is_selection_reversed()
                || input.marked_text_range(window, cx).is_some()
            {
                return false;
            }
            input.replace_text_in_range(Some(utf16), &insertion, window, cx);
            input.value().as_ref() == expected
        });
        self.composer_suggestions.live = None;
        self.composer_suggestions.hide();
        self.composer.read(cx).focus_handle(cx).focus(window, cx);
        if !applied {
            self.status =
                "The draft changed before the suggestion was applied; newer text was kept.".into();
        } else if let Suggestion::Command(command) = item
            && let Some(command) = crate::composer_commands::standalone(&command.title())
        {
            // The draft is saved from the edit's change event; run the command once it is.
            self.composer_suggestions.queued = Some(Queued {
                command,
                thread: live.thread,
                draft: expected,
                until: Instant::now() + Duration::from_secs(5),
            });
            cx.defer_in(window, |this, window, cx| {
                this.run_queued_suggestion_command(window, cx)
            });
        }
        cx.notify();
    }
    /// Runs a chosen built-in through the same validated selection path as a sent `/plan`,
    /// keeping the rest of the draft. It waits while the edited draft is still saving.
    fn run_queued_suggestion_command(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(queued) = self.composer_suggestions.queued.clone() else {
            return;
        };
        let selected = self
            .selected
            .clone()
            .filter(|selected| selected["id"] == queued.thread.as_str())
            .filter(|_| self.committed_composer_draft(cx) == queued.draft);
        let selected = match selected {
            Some(selected) if Instant::now() < queued.until => selected,
            unsaved => {
                self.composer_suggestions.queued = None;
                self.status = if unsaved.is_some() {
                    "The edited draft could not be saved; the chosen command did not run."
                } else {
                    "The draft changed; the chosen command did not run."
                }
                .into();
                cx.notify();
                return;
            }
        };
        // The edit's change event updates and saves the draft; until then, wait.
        if selected["draft"] != queued.draft.as_str() {
            return;
        }
        if self.pending_drafts.contains_key(&queued.thread) {
            self.save_pending_draft(&queued.thread);
            if self.pending_drafts.contains_key(&queued.thread) {
                return;
            }
        }
        self.composer_suggestions.queued = None;
        let submission = crate::composer_commands::Submission::suggested(&selected, &queued.draft);
        self.perform_composer_command(queued.command, submission, window, cx);
    }

    /// Records the composer's bounds each frame, so the list stays glued to it as it grows,
    /// and floats the list over it.
    pub(super) fn composer_suggestion_surface(&self, surface: Div, cx: &mut Context<Self>) -> Div {
        let anchor = self.composer_suggestions.anchor.clone();
        let visible = self.composer_suggestions.visible;
        surface
            .on_prepaint(move |bounds, window, _| {
                if anchor.replace(Some(bounds)) != Some(bounds) && visible {
                    window.refresh();
                }
            })
            .when_some(self.composer_suggestion_popup(cx), |surface, popup| {
                surface.child(popup)
            })
    }

    fn suggestion_icon(&self, item: &Suggestion, selected: bool) -> AnyElement {
        use gpui_kit::assets::IconName;
        let logo = |provider: &str| {
            chat_layout::provider_logo(provider).map(|image| {
                img(image)
                    .w(px(14.))
                    .h(px(14.))
                    .rounded(px(3.))
                    .bg(rgb(0x2b2b2b))
                    .into_any_element()
            })
        };
        let secondary = self
            .color(0xe4e9f2)
            .opacity(if selected { 0.9 } else { 0.6 });
        let symbol = |name: IconName, color: Hsla| {
            Icon::new(name).small().text_color(color).into_any_element()
        };
        match item {
            Suggestion::Command(BuiltIn::Agent { provider, .. })
            | Suggestion::Agent { provider, .. } => {
                logo(provider).unwrap_or_else(|| symbol(IconName::Cpu, secondary.into()))
            }
            Suggestion::Command(command) => symbol(
                match command {
                    BuiltIn::Model => IconName::Cpu,
                    BuiltIn::Plan => IconName::PencilRuler,
                    BuiltIn::Build => IconName::Hammer,
                    _ => IconName::Gauge,
                },
                secondary.into(),
            ),
            Suggestion::PullRequest(pull) if pull.is_draft => {
                symbol(IconName::GitPullRequestDraft, secondary.into())
            }
            Suggestion::PullRequest(_) => symbol(IconName::GitPullRequest, rgb(0x3fb950).into()),
        }
    }

    /// The list floats just above the composer, or below it where there is no room above.
    fn composer_suggestion_popup(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let state = &self.composer_suggestions;
        if !state.visible {
            return None;
        }
        let bounds = state.anchor.get()?;
        let ink = self.color(0xe4e9f2);
        let height = if state.items.is_empty() {
            40.
        } else {
            state.items.len().min(MAX_VISIBLE_ROWS) as f32 * ROW_HEIGHT + PADDING * 2.
        };
        let mut surface = div()
            .id("composer-suggestions")
            .occlude()
            .w(bounds.size.width)
            .h(px(height))
            .rounded(px(14.))
            .bg(self.color(0x181d28))
            .border_1()
            .border_color(self.color(0x29303d))
            .shadow_lg()
            .overflow_hidden()
            .text_color(ink);
        if state.items.is_empty() {
            surface = surface.child(
                div()
                    .h_full()
                    .px(px(16.))
                    .flex()
                    .items_center()
                    .text_xs()
                    .text_color(ink.opacity(0.6))
                    .child(state.empty_text.unwrap_or_default()),
            );
        } else {
            let mut rows = div()
                .id("composer-suggestion-rows")
                .track_scroll(&state.scroll)
                .role(Role::List)
                .aria_label(state.label)
                .size_full()
                .py(px(PADDING))
                .overflow_y_scroll()
                .flex()
                .flex_col();
            for (index, item) in state.items.iter().enumerate() {
                let selected = index == state.selected;
                let detail = item.detail();
                rows = rows.child(
                    div()
                        .id(("composer-suggestion", index))
                        .role(Role::ListItem)
                        .aria_selected(selected)
                        .aria_label(format!(
                            "{}{}",
                            item.accessible(),
                            if selected { ", selected" } else { "" }
                        ))
                        .h(px(ROW_HEIGHT))
                        .flex_shrink_0()
                        .mx(px(6.))
                        .px(px(8.))
                        .rounded(px(6.))
                        .when(selected, |row| row.bg(self.color(0x253046)))
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .text_xs()
                        .child(
                            div()
                                .w(px(16.))
                                .h(px(16.))
                                .flex_shrink_0()
                                .flex()
                                .items_center()
                                .justify_center()
                                .child(self.suggestion_icon(item, selected)),
                        )
                        .child(
                            div()
                                .max_w(relative(0.5))
                                .min_w_0()
                                .flex_shrink_0()
                                .truncate()
                                .font_weight(FontWeight::MEDIUM)
                                .child(item.title()),
                        )
                        .when(!detail.is_empty(), |row| {
                            row.child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_color(ink.opacity(if selected { 0.75 } else { 0.6 }))
                                    .child(detail),
                            )
                        })
                        // Selects the row under the pointer, like a menu, and takes the click
                        // on mouse-down so the composer never loses the caret first.
                        .on_mouse_move(cx.listener(move |this, _: &MouseMoveEvent, _, cx| {
                            if this.composer_suggestions.selected != index {
                                this.composer_suggestions.selected = index;
                                cx.notify();
                            }
                        }))
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(move |this, _: &MouseDownEvent, window, cx| {
                                window.prevent_default();
                                cx.stop_propagation();
                                this.choose_composer_suggestion(index, window, cx);
                            }),
                        ),
                );
            }
            surface = surface.child(rows);
        }
        Some(
            deferred(
                Positioner::side(bounds)
                    .placement(Placement::Top)
                    .align(Align::Start)
                    .offset(px(6.))
                    .margin(px(8.))
                    .occlude()
                    .child(surface),
            )
            .with_priority(1)
            .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn swift_key_routing_moves_wraps_chooses_and_dismisses() {
        let mut keys = Keys::default();
        assert_eq!(
            keys.decide(Key::Down, "a", true, true, 3, 0),
            Decision::Select(1)
        );
        assert_eq!(
            keys.decide(Key::Up, "a", true, true, 3, 0),
            Decision::Select(2)
        );
        assert_eq!(
            keys.decide(Key::Down, "a", true, true, 3, 2),
            Decision::Select(0)
        );
        // A stale highlight past the end clamps to the last row first.
        assert_eq!(
            keys.decide(Key::Up, "a", true, true, 2, 9),
            Decision::Select(0)
        );
        // A visible list that is still loading swallows arrows but Return still sends.
        assert_eq!(
            keys.decide(Key::Down, "a", true, true, 0, 0),
            Decision::Consume
        );
        assert_eq!(
            keys.decide(Key::Enter, "a", true, true, 0, 0),
            Decision::Pass
        );
        assert_eq!(
            keys.decide(Key::Tab, "a", true, true, 3, 1),
            Decision::Choose(1)
        );
        // Without a list, arrows recall history and Return sends.
        for key in [Key::Up, Key::Down, Key::Enter] {
            assert_eq!(keys.decide(key, "a", false, false, 0, 0), Decision::Pass);
        }
        // Escape dismisses a visible list, or a word whose list is empty, else passes.
        assert_eq!(
            keys.decide(Key::Escape, "a", true, true, 3, 0),
            Decision::Dismiss
        );
        assert_eq!(
            keys.decide(Key::Escape, "a", false, true, 0, 0),
            Decision::Dismiss
        );
        assert_eq!(
            keys.decide(Key::Escape, "a", false, false, 0, 0),
            Decision::Pass
        );
    }

    #[::core::prelude::v1::test]
    fn the_key_that_chose_a_row_cannot_send_until_it_is_released() {
        let mut keys = Keys::default();
        assert_eq!(
            keys.decide(Key::Enter, "a", true, true, 2, 0),
            Decision::Choose(0)
        );
        // Repeats after the list closed are swallowed, not sent.
        for _ in 0..3 {
            assert_eq!(
                keys.decide(Key::Enter, "a", false, false, 0, 0),
                Decision::Consume
            );
        }
        // Tab is separate custody; another thread is never blocked.
        assert_eq!(
            keys.decide(Key::Tab, "a", false, false, 0, 0),
            Decision::Pass
        );
        assert_eq!(
            keys.decide(Key::Enter, "b", false, false, 0, 0),
            Decision::Pass
        );
        keys.release(Key::Tab);
        assert_eq!(
            keys.decide(Key::Enter, "a", false, false, 0, 0),
            Decision::Consume
        );
        keys.release(Key::Enter);
        assert_eq!(
            keys.decide(Key::Enter, "a", false, false, 0, 0),
            Decision::Pass
        );
    }

    #[::core::prelude::v1::test]
    fn rows_use_swift_titles_details_and_spoken_labels() {
        let pull = PullRequest {
            number: 7,
            title: "Fix login".into(),
            url: "https://github.com/owner/project/pull/7".into(),
            author: None,
            head_branch: "fix/login".into(),
            is_draft: false,
            updated_at: None,
        };
        let row = Suggestion::PullRequest(pull.clone());
        assert_eq!(row.title(), "#7 Fix login");
        assert_eq!(row.detail(), "fix/login");
        assert_eq!(row.accessible(), "Pull request #7, Fix login, fix/login");
        let authored = Suggestion::PullRequest(PullRequest {
            author: Some("ana".into()),
            ..pull
        });
        assert_eq!(authored.detail(), "ana");
        let skill = Suggestion::Agent {
            command: ProviderCommand {
                name: "review".into(),
                description: None,
                argument_hint: Some("[pr]".into()),
                kind: CommandKind::Skill,
                is_built_in: false,
                is_slash_command: true,
            },
            provider: "claude".into(),
            token: '$',
        };
        assert_eq!(skill.title(), "$review [pr]");
        assert_eq!(skill.accessible(), "$review");
        if let Suggestion::Agent { command, .. } = &skill {
            assert_eq!(Suggestion::agent_insertion(command, '$'), "/review ");
            let mut codex = command.clone();
            codex.is_slash_command = false;
            assert_eq!(Suggestion::agent_insertion(&codex, '$'), "$review ");
        }
        let plan = Suggestion::Command(BuiltIn::Plan);
        assert_eq!(plan.title(), "/plan");
        assert_eq!(
            plan.accessible(),
            "/plan, Switch this thread into plan mode"
        );
    }

    #[::core::prelude::v1::test]
    fn every_built_in_title_is_a_command_the_send_path_runs() {
        let agents = coincide_core::provider_catalog::provider_catalog()
            .iter()
            .map(|entry| {
                let id = serde_json::to_value(entry.id).unwrap();
                (
                    id.as_str().unwrap().to_owned(),
                    entry.display_name.to_owned(),
                )
            })
            .collect::<Vec<_>>();
        for command in BuiltIn::available(&agents, true) {
            assert!(
                crate::composer_commands::standalone(&command.title()).is_some(),
                "{}",
                command.title()
            );
        }
    }
}
