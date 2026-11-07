//! Import CLI Session, as Swift's `CLISessionImportController`: the Claude Code
//! and Codex sessions found in the CLIs' history roots, with search, Refresh and
//! Choose File…, a bounded preview, then Import. Parent: render the entity, call
//! set_project on destination changes and set_visible each frame, and handle
//! SessionImportEvent (Imported selects the thread, Cancelled closes the sheet).
//! Every scan and API call runs on a single background worker, never on the
//! GPUI thread.
use crate::worker_owner::{ShutdownStatus, WorkerOwner};
use anyhow::{Context as _, Result, ensure};
use coincide_core::{
    api::{SharedEngine, call},
    cli_session_discovery::{self as discovery, Candidate, Scan},
};
use gpui_kit::base::Disableable;
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::{
    component::{
        ActiveTheme,
        button::*,
        input::{Input, InputEvent, InputState},
        tooltip::Tooltip,
    },
    *,
};
use serde_json::{Value, json};
use std::{path::PathBuf, sync::mpsc, time::Duration};

const VISIBLE_MESSAGES: usize = 12;
const VISIBLE_CHARS: usize = 1500;
#[derive(Clone, Debug, PartialEq, Eq)]
struct Selection {
    path: PathBuf,
    /// `codex` or `claude` for a listed session; `auto` for a chosen file,
    /// which the preview replaces with the detected provider.
    provider: String,
    project: Option<String>,
}
impl Selection {
    fn params(&self) -> Result<Value> {
        ensure!(self.path.is_absolute(), "Choose an absolute source file");
        ensure!(
            matches!(self.provider.as_str(), "codex" | "claude" | "auto"),
            "Choose a Claude Code session or Codex rollout JSONL file."
        );
        Ok(
            json!({"path":self.path.to_str().context("Source path must be UTF-8")?,
            "provider":self.provider,"projectId":self.project}),
        )
    }
}
#[derive(Clone)]
struct Preview {
    selection: Selection,
    sha256: String,
    title: String,
    details: String,
    count: u64,
    omissions: u64,
    shortened: bool,
    messages: Vec<(String, String)>,
    display_shortened: bool,
    /// An earlier import of this session, opened instead of importing again.
    existing: Option<String>,
}
impl Preview {
    fn from_reply(mut selection: Selection, reply: Value) -> Result<Self> {
        let sha256 = reply["sha256"]
            .as_str()
            .context("Preview has no fingerprint")?;
        ensure!(
            sha256.len() == 64 && sha256.bytes().all(|c| c.is_ascii_hexdigit()),
            "Invalid preview fingerprint"
        );
        let provider = reply["provider"].as_str().unwrap_or("");
        ensure!(
            matches!(provider, "codex" | "claude")
                && (selection.provider == "auto" || selection.provider == provider)
                && reply["executable"] == false,
            "Invalid preview provider or execution state"
        );
        // Import names the detected format exactly; it never detects again.
        selection.provider = provider.to_owned();
        let count = reply["messageCount"]
            .as_u64()
            .context("Preview has no message count")?;
        ensure!(
            count > 0 && count <= 100_000,
            "Invalid preview message count"
        );
        let messages = reply["messages"]
            .as_array()
            .context("Preview has no messages")?;
        ensure!(
            messages.len() <= 20,
            "Preview response exceeds message bound"
        );
        let name = provider_display_name(provider);
        let mut display_shortened = count > messages.len().min(VISIBLE_MESSAGES) as u64;
        let messages = messages
            .iter()
            .take(VISIBLE_MESSAGES)
            .map(|message| {
                let role = message["role"].as_str().context("Invalid preview role")?;
                ensure!(
                    matches!(role, "user" | "assistant"),
                    "Unsupported preview role"
                );
                let text = message["text"].as_str().context("Invalid preview text")?;
                let shortened = text.chars().count() > VISIBLE_CHARS;
                display_shortened |= shortened;
                Ok((
                    if role == "user" { "You" } else { name }.to_owned(),
                    if shortened {
                        text.chars().take(VISIBLE_CHARS).collect::<String>() + "\n…"
                    } else {
                        text.to_owned()
                    },
                ))
            })
            .collect::<Result<Vec<_>>>()?;
        let existing = match &reply["existingThreadId"] {
            Value::Null => None,
            Value::String(id) => {
                uuid::Uuid::parse_str(id).context("Preview returned an invalid thread ID")?;
                Some(id.clone())
            }
            _ => anyhow::bail!("Preview returned an invalid thread ID"),
        };
        let bounded = |key: &str, limit: usize| -> String {
            reply[key]
                .as_str()
                .unwrap_or_default()
                .chars()
                .take(limit)
                .collect()
        };
        let model = bounded("model", 200);
        let details = format!(
            "{name} · {} · {}\n{}",
            if model.is_empty() { "default" } else { &model },
            bounded("sessionId", 64),
            bounded("directory", 1000)
        );
        Ok(Self {
            selection,
            sha256: sha256.to_owned(),
            title: reply["title"]
                .as_str()
                .unwrap_or("Imported conversation")
                .chars()
                .take(100)
                .collect(),
            details,
            count,
            omissions: reply["omittedRecords"]
                .as_u64()
                .context("Preview has no omission count")?,
            shortened: reply["shortenedText"] == true,
            messages,
            display_shortened,
            existing,
        })
    }
    fn import_params(&self) -> Result<Value> {
        let mut params = self.selection.params()?;
        params["sha256"] = json!(self.sha256);
        Ok(params)
    }
}
fn provider_display_name(provider: &str) -> &'static str {
    if provider == "codex" {
        "Codex"
    } else {
        "Claude Code"
    }
}
enum Action {
    Scan,
    Preview(Selection),
    Import(Preview),
}
enum Outcome {
    Scanned(Scan),
    Preview(Preview),
    Imported(String),
}
fn run(api: &mut impl FnMut(&str, Value) -> Result<Value>, action: Action) -> Result<Outcome> {
    match action {
        Action::Scan => Ok(Outcome::Scanned(discovery::scan_default(&|| false))),
        Action::Preview(selection) => {
            let reply = api("cli.sessions.preview", selection.params()?)?;
            Ok(Outcome::Preview(Preview::from_reply(selection, reply)?))
        }
        Action::Import(preview) => {
            let reply = api("cli.sessions.import", preview.import_params()?)?;
            let id = reply["threadId"]
                .as_str()
                .context("Import outcome unknown: refresh conversations before retrying")?;
            uuid::Uuid::parse_str(id).context("Import returned an invalid thread ID")?;
            Ok(Outcome::Imported(id.to_owned()))
        }
    }
}

fn run_admitted(
    api: &mut impl FnMut(&str, Value) -> Result<Value>,
    action: Action,
    admission: &crate::worker_owner::Admission,
) -> Result<Outcome> {
    ensure!(admission.allowed(), "Session import admissions are closed");
    if let Action::Scan = action {
        // Closing the app stops a long walk between entries.
        return Ok(Outcome::Scanned(discovery::scan_default(&|| {
            !admission.allowed()
        })));
    }
    run(
        &mut |method, params| {
            ensure!(admission.allowed(), "Session import admissions are closed");
            api(method, params)
        },
        action,
    )
}
fn finish_choice(workers: &mut WorkerOwner, expected: u64, current: u64) -> bool {
    workers.finish_picker() && expected == current
}

pub enum SessionImportEvent {
    Imported { thread_id: String },
    Cancelled,
}
pub struct SessionImportPanel {
    engine: SharedEngine,
    project: Option<String>,
    generation: u64,
    busy: bool,
    scanning: bool,
    visible: bool,
    workers: WorkerOwner,
    choosing: bool,
    search: Entity<InputState>,
    /// Keeps Return and Escape with the sheet after a row is clicked.
    focus: FocusHandle,
    candidates: Vec<Candidate>,
    selected: Option<PathBuf>,
    /// The latest preview asked for while the worker was busy.
    queued: Option<Selection>,
    preview: Option<Preview>,
    notice: String,
    tx: mpsc::Sender<(u64, Result<Outcome>)>,
    rx: mpsc::Receiver<(u64, Result<Outcome>)>,
    _poll: Option<Task<()>>,
    _search: Subscription,
}
impl EventEmitter<SessionImportEvent> for SessionImportPanel {}
impl SessionImportPanel {
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
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search sessions"));
        let subscription = cx.subscribe(&search, |this, _, event, cx| match event {
            InputEvent::Change => {
                // Swift resets the preview when the list is filtered again.
                this.selected = None;
                this.queued = None;
                this.preview = None;
                this.generation = this.generation.wrapping_add(1);
                cx.notify();
            }
            InputEvent::PressEnter {
                secondary: false,
                shift: false,
            } => this.import_selected(cx),
            _ => {}
        });
        Self {
            engine,
            project: None,
            generation: 0,
            busy: false,
            scanning: false,
            visible: false,
            workers: WorkerOwner::default(),
            choosing: false,
            search,
            focus: cx.focus_handle(),
            candidates: Vec::new(),
            selected: None,
            queued: None,
            preview: None,
            notice: "Scanning local sessions…".into(),
            tx,
            rx,
            _poll: Some(poll),
            _search: subscription,
        }
    }
    /// Each time the sheet opens, list the local sessions again, as Swift's
    /// sheet does when it appears.
    pub fn set_visible(&mut self, visible: bool, cx: &mut Context<Self>) {
        let opened = visible && !self.visible;
        self.visible = visible;
        if opened && !self.workers.closed() {
            self.refresh(cx);
        }
    }
    /// Capture destination at preview time; never silently import into a newly
    /// selected project. An in-flight import still emits its actual persisted ID.
    pub fn set_project(&mut self, project: Option<String>, cx: &mut Context<Self>) {
        if self.workers.closed() || self.project == project {
            return;
        }
        self.project = project;
        self.generation = self.generation.wrapping_add(1);
        self.preview = None;
        self.selected = None;
        self.queued = None;
        self.notice = if self.busy { "Destination changed. Waiting for the previous operation; an import already started may complete." }
            else { "Destination changed. Select a session again to preview it for this destination." }.into();
        cx.notify();
    }
    fn refresh(&mut self, cx: &mut Context<Self>) {
        if self.busy || self.choosing {
            return;
        }
        self.generation = self.generation.wrapping_add(1);
        self.preview = None;
        self.selected = None;
        self.queued = None;
        self.start(Action::Scan, cx);
    }
    fn select(&mut self, candidate: &Candidate, cx: &mut Context<Self>) {
        if self.workers.closed() || self.choosing {
            return;
        }
        self.generation = self.generation.wrapping_add(1);
        self.selected = Some(candidate.path.clone());
        self.preview = None;
        let selection = Selection {
            path: candidate.path.clone(),
            provider: discovery::provider_name(candidate.provider).into(),
            project: self.project.clone(),
        };
        if self.busy {
            self.queued = Some(selection);
            self.notice = "Loading preview…".into();
            cx.notify();
        } else {
            self.start(Action::Preview(selection), cx);
        }
    }
    fn choose(&mut self, cx: &mut Context<Self>) {
        if self.busy || self.choosing || !self.workers.begin_picker() {
            return;
        }
        self.choosing = true;
        self.preview = None;
        self.selected = None;
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        let selection = Selection {
            path: PathBuf::new(),
            provider: "auto".into(),
            project: self.project.clone(),
        };
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Preview".into()),
        });
        self.notice =
            "Choose a Claude Code session or Codex rollout JSONL file. Originals are preserved."
                .into();
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result: Result<_> = async { picker.await? }.await;
            let _ = this.update(cx, |this, cx| {
                this.choosing = false;
                if !finish_choice(&mut this.workers, generation, this.generation) {
                    cx.notify();
                    return;
                }
                match result {
                    Ok(Some(paths)) if paths.len() == 1 => {
                        let mut selection = selection;
                        selection.path = paths[0].clone();
                        this.start(Action::Preview(selection), cx);
                    }
                    Ok(_) => {
                        this.notice = "Select a session to preview it.".into();
                        cx.notify();
                    }
                    Err(error) => {
                        this.notice = format!("File selection failed: {error}");
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }
    fn import_selected(&mut self, cx: &mut Context<Self>) {
        if self.busy || self.choosing || self.workers.closed() {
            return;
        }
        let Some(preview) = self.preview.clone() else {
            return;
        };
        if let Some(thread_id) = preview.existing {
            cx.emit(SessionImportEvent::Imported { thread_id });
            return;
        }
        self.start(Action::Import(preview), cx);
    }
    fn cancel(&mut self, cx: &mut Context<Self>) {
        self.generation = self.generation.wrapping_add(1);
        self.preview = None;
        self.selected = None;
        self.queued = None;
        cx.emit(SessionImportEvent::Cancelled);
    }
    fn start(&mut self, action: Action, cx: &mut Context<Self>) {
        if self.busy || self.choosing || !self.workers.can_start() {
            return;
        }
        self.busy = true;
        self.scanning = matches!(action, Action::Scan);
        self.notice = match action {
            Action::Scan => "Scanning local sessions…",
            Action::Preview(_) => "Loading preview…",
            Action::Import(_) => "Importing…",
        }
        .into();
        let tx = self.tx.clone();
        let generation = self.generation;
        let engine = self.engine.clone();
        // Worker owns every Engine lock, file walk and source parse. GPUI polls
        // only a channel.
        if !self.workers.spawn(move |admission| {
            let result = run_admitted(
                &mut |method, params| call(&engine, method, params),
                action,
                &admission,
            );
            let _ = tx.send((generation, result));
        }) {
            self.busy = false;
            self.scanning = false;
            self.notice = "Session import worker could not start.".into();
        }
        cx.notify();
    }
    pub fn request_shutdown(&mut self) {
        if self.workers.close() {
            self.generation = self.generation.wrapping_add(1);
            self.preview = None;
            self.queued = None;
            drop(self._poll.take());
        }
        self.discard_results();
    }
    fn discard_results(&mut self) {
        for result in self.rx.try_iter() {
            drop(result);
            self.busy = false;
            self.scanning = false;
        }
    }
    pub fn shutdown_status(&mut self) -> ShutdownStatus {
        if self.workers.closed() {
            self.discard_results();
        }
        let status = self.workers.status();
        if self.workers.closed() {
            self.discard_results();
        }
        status
    }
    fn poll(&mut self, cx: &mut Context<Self>) {
        self.workers.poll();
        if self.workers.closed() {
            self.discard_results();
            return;
        }
        let Ok((generation, result)) = self.rx.try_recv() else {
            return;
        };
        self.busy = false;
        self.scanning = false;
        match result {
            Ok(Outcome::Imported(thread_id)) => {
                self.preview = None;
                self.notice =
                    "Imported as a read-only conversation. Fork it before sending messages.".into();
                // Do not discard a durable success after the destination changes.
                cx.emit(SessionImportEvent::Imported { thread_id });
            }
            Ok(Outcome::Scanned(scan)) => {
                self.candidates = scan.candidates;
                self.notice = if scan.incomplete {
                    "Some sessions could not be listed. Use Choose File to open a specific JSONL file."
                } else {
                    "Select a session to preview it."
                }
                .into();
            }
            Ok(Outcome::Preview(preview)) if generation == self.generation => {
                self.notice = "The preview shows the first messages. Unsupported records and longer text remain in the saved original source.".into();
                if preview.omissions > 0 || preview.shortened {
                    self.notice.push_str(
                        " This session includes content that is preserved only in the original source.",
                    );
                }
                self.preview = Some(preview);
            }
            Ok(Outcome::Preview(_)) => {}
            Err(error) if generation == self.generation || self.queued.is_none() => {
                self.preview = None;
                self.notice = format!(
                    "{error}. No automatic retry. Refresh conversations before retrying an import."
                );
            }
            Err(_) => {}
        }
        if let Some(selection) = self.queued.take() {
            self.start(Action::Preview(selection), cx);
        }
        cx.notify();
    }
    fn filtered(&self, cx: &App) -> Vec<Candidate> {
        let query = self.search.read(cx).value().to_string();
        self.candidates
            .iter()
            .filter(|candidate| discovery::matches(candidate, &query))
            .cloned()
            .collect()
    }
}
impl Drop for SessionImportPanel {
    fn drop(&mut self) {
        self.request_shutdown();
    }
}
impl Render for SessionImportPanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let closed = self.workers.closed();
        let disabled = self.busy || self.choosing || closed;
        let border = cx.theme().border;
        let muted = cx.theme().muted_foreground;
        let selected_background = cx.theme().accent;
        let rows = self.filtered(cx);
        let mut list = div()
            .id("session-import-list")
            .w(px(290.))
            .flex_none()
            .h_full()
            .min_h_0()
            .overflow_y_scroll()
            .border_1()
            .border_color(border)
            .rounded_md()
            .flex()
            .flex_col();
        if rows.is_empty() && !self.scanning {
            list = list.child(div().p_3().text_sm().text_color(muted).child(
                if self.candidates.is_empty() {
                    "No Claude Code or Codex sessions were found."
                } else {
                    "No sessions match the search."
                },
            ));
        }
        for (index, candidate) in rows.into_iter().enumerate() {
            let selected = self.selected.as_ref() == Some(&candidate.path);
            let subtitle = format!(
                "{} · {}",
                discovery::display_name(candidate.provider),
                candidate.directory
            );
            list = list.child(
                div()
                    .id(SharedString::from(format!("session-import-row-{index}")))
                    .flex()
                    .flex_col()
                    .gap_0p5()
                    .px_2()
                    .py_1p5()
                    .border_b_1()
                    .border_color(border)
                    .when(selected, |row| row.bg(selected_background))
                    .when(!selected && !closed, |row| {
                        row.hover(|row| row.bg(selected_background.opacity(0.5)))
                    })
                    .child(div().truncate().child(candidate.title.clone()))
                    .child(div().text_xs().text_color(muted).truncate().child(subtitle))
                    .tooltip({
                        let path = candidate.path.to_string_lossy().into_owned();
                        move |window, cx| Tooltip::new(path.clone()).build(window, cx)
                    })
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.focus.focus(window, cx);
                        this.select(&candidate, cx)
                    })),
            );
        }
        let mut reading = div()
            .id("session-import-preview")
            .flex_1()
            .min_w_0()
            .h_full()
            .min_h_0()
            .overflow_y_scroll()
            .border_1()
            .border_color(border)
            .rounded_md()
            .p_3()
            .flex()
            .flex_col()
            .gap_2();
        let mut details = div().text_sm().text_color(muted).flex().flex_col();
        if let Some(preview) = &self.preview {
            details = details.child(preview.details.clone()).child(format!(
                "{} messages · {} omitted records or content blocks",
                preview.count, preview.omissions
            ));
            reading = reading.child(
                div()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(preview.title.clone()),
            );
            if preview.shortened {
                reading = reading.child(div().text_sm().text_color(muted).child("Some imported message text was shortened to the import limit. Exact originals remain preserved."));
            }
            if preview.display_shortened {
                reading = reading.child(div().text_sm().text_color(muted).child(
                    "Showing an excerpt of the first messages; this panel limits text for display.",
                ));
            }
            for (index, (label, text)) in preview.messages.iter().enumerate() {
                reading = reading.child(
                    div()
                        .id(SharedString::from(format!(
                            "session-import-message-{index}"
                        )))
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(div().font_weight(FontWeight::SEMIBOLD).child(label.clone()))
                        .child(div().text_sm().font_family("monospace").child(text.clone())),
                );
            }
        }
        let existing = self.preview.as_ref().is_some_and(|p| p.existing.is_some());
        div()
            .id("session-import-panel")
            .size_full()
            .flex()
            .flex_col()
            .gap_2p5()
            .p_5()
            .track_focus(&self.focus)
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                let modifiers = event.keystroke.modifiers;
                if modifiers.platform || modifiers.control || modifiers.alt || modifiers.shift {
                    return;
                }
                // As Swift's sheet: Escape cancels and Return imports. The search
                // field reports its own Return as PressEnter.
                match event.keystroke.key.as_str() {
                    "escape" => this.cancel(cx),
                    "enter" | "return"
                        if !this.search.read(cx).focus_handle(cx).is_focused(window) =>
                    {
                        this.import_selected(cx)
                    }
                    _ => return,
                }
                cx.stop_propagation();
            }))
            .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child("Import CLI Session"))
            .child(div().text_color(muted).child("Preview a Claude Code or Codex conversation before importing. The original file stays unchanged; Coincide keeps a private copy. Imported threads are read-only until you fork them."))
            .child(Input::new(&self.search).disabled(closed))
            .child(div().flex_1().min_h(px(260.)).flex().gap_3().child(list).child(reading))
            .child(details)
            .child(div().text_xs().text_color(muted).child(format!(
                "{} · Destination: {}",
                self.notice,
                self.project.as_deref().unwrap_or("Chats")
            )))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(Button::new("session-import-choose").label("Choose File…").disabled(disabled)
                        .on_click(cx.listener(|this, _, _, cx| this.choose(cx))))
                    .child(Button::new("session-import-refresh").label("Refresh").disabled(disabled)
                        .on_click(cx.listener(|this, _, _, cx| this.refresh(cx))))
                    .child(div().flex_1())
                    .child(Button::new("session-import-cancel").label("Cancel")
                        .on_click(cx.listener(|this, _, _, cx| this.cancel(cx))))
                    .child(Button::new("session-import-confirm")
                        .label(if existing { "Open Existing Thread" } else { "Import" })
                        .primary()
                        .disabled(disabled || self.preview.is_none())
                        .on_click(cx.listener(|this, _, _, cx| this.import_selected(cx)))),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn selection() -> Selection {
        Selection {
            path: PathBuf::from("/synthetic/source.jsonl"),
            provider: "codex".into(),
            project: None,
        }
    }
    fn reply() -> Value {
        json!({"provider":"codex","executable":false,"sha256":"a".repeat(64),"title":"Synthetic",
        "messageCount":1,"omittedRecords":3,"shortenedText":false,"messages":[{"role":"user","text":"hello"}]})
    }
    #[::core::prelude::v1::test]
    fn confirmation_uses_exact_preview_binding_and_never_repreviews() {
        let mut calls = Vec::new();
        let preview = match run(
            &mut |method, params| {
                calls.push((method.to_owned(), params));
                Ok(reply())
            },
            Action::Preview(selection()),
        )
        .unwrap()
        {
            Outcome::Preview(p) => p,
            _ => panic!("preview"),
        };
        let outcome = run(
            &mut |method, params| {
                calls.push((method.to_owned(), params));
                Ok(json!({"threadId":"00000000-0000-4000-8000-000000000001"}))
            },
            Action::Import(preview),
        )
        .unwrap();
        assert!(matches!(outcome, Outcome::Imported(_)));
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].0, "cli.sessions.preview");
        assert_eq!(calls[1].0, "cli.sessions.import");
        assert_eq!(calls[1].1["sha256"], "a".repeat(64));
        assert_eq!(calls[1].1["path"], "/synthetic/source.jsonl");
        assert!(calls[1].1["projectId"].is_null());
    }
    #[::core::prelude::v1::test]
    fn display_is_bounded_and_omissions_preserved() {
        let mut value = reply();
        value["messages"][0]["text"] = json!("🦀".repeat(5000));
        let preview = Preview::from_reply(selection(), value).unwrap();
        assert_eq!(preview.omissions, 3);
        assert!(preview.display_shortened);
        assert_eq!(preview.messages[0].1.chars().count(), VISIBLE_CHARS + 2);
        let mut value = reply();
        value["provider"] = json!("claude");
        assert!(Preview::from_reply(selection(), value).is_err());
    }
    #[::core::prelude::v1::test]
    fn chosen_file_imports_with_the_detected_provider_and_existing_threads_open() {
        let mut chosen = selection();
        chosen.provider = "auto".into();
        let mut value = reply();
        value["provider"] = json!("claude");
        value["model"] = json!("fixture-model");
        value["sessionId"] = json!("00000000-0000-4000-8000-000000000002");
        value["directory"] = json!("/synthetic/work");
        let preview = Preview::from_reply(chosen.clone(), value.clone()).unwrap();
        assert_eq!(preview.import_params().unwrap()["provider"], "claude");
        assert_eq!(preview.messages[0].0, "You");
        assert_eq!(
            preview.details,
            "Claude Code · fixture-model · 00000000-0000-4000-8000-000000000002\n/synthetic/work"
        );
        assert!(preview.existing.is_none());
        value["existingThreadId"] = json!("00000000-0000-4000-8000-000000000003");
        let existing = Preview::from_reply(chosen.clone(), value.clone()).unwrap();
        assert_eq!(
            existing.existing.as_deref(),
            Some("00000000-0000-4000-8000-000000000003")
        );
        value["existingThreadId"] = json!("not-a-thread");
        assert!(Preview::from_reply(chosen.clone(), value.clone()).is_err());
        value["existingThreadId"] = Value::Null;
        value["provider"] = json!("grok");
        assert!(Preview::from_reply(chosen, value).is_err());
    }
    #[::core::prelude::v1::test]
    fn failed_import_is_never_retried() {
        let preview = Preview::from_reply(selection(), reply()).unwrap();
        let mut count = 0;
        assert!(
            run(
                &mut |_, _| {
                    count += 1;
                    anyhow::bail!("synthetic source changed")
                },
                Action::Import(preview)
            )
            .is_err()
        );
        assert_eq!(count, 1);
    }
}

#[cfg(all(test, unix))]
mod fixture_tests {
    use super::*;
    use coincide_core::{api::Engine, store::Store};
    use std::{
        fs,
        sync::{Arc, Mutex},
    };
    struct FixtureDirectory(PathBuf);
    impl FixtureDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "coincide-session-panel-test-{}",
                uuid::Uuid::new_v4()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for FixtureDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[::core::prelude::v1::test]
    fn worker_uses_real_api_to_preview_and_import_synthetic_sources() {
        let fixture = FixtureDirectory::new();
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&fixture.0.join("rust/state.sqlite")).unwrap(),
        )));
        for provider in ["codex", "claude"] {
            let path = fixture.0.join(format!("{provider}.jsonl"));
            let id = uuid::Uuid::new_v4().to_string();
            let source = if provider == "codex" {
                [json!({"type":"session_meta","payload":{"id":id,"cwd":"/synthetic","unknown":"kept"}}),
                json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"synthetic panel fixture"}]}})].iter().map(Value::to_string).collect::<Vec<_>>().join("\n")
            } else {
                json!({"sessionId":id,"cwd":"/synthetic","uuid":"message-one","parentUuid":null,"type":"user","message":{"role":"user","content":"synthetic panel fixture"},"unknown":"kept"}).to_string()
            };
            fs::write(&path, source.as_bytes()).unwrap();
            let mut api = |method: &str, params| call(&engine, method, params);
            let Outcome::Preview(preview) = run(
                &mut api,
                Action::Preview(Selection {
                    path: path.clone(),
                    provider: provider.into(),
                    project: None,
                }),
            )
            .unwrap() else {
                panic!("expected preview")
            };
            assert_eq!(preview.count, 1);
            let Outcome::Imported(thread) = run(&mut api, Action::Import(preview)).unwrap() else {
                panic!("expected import")
            };
            assert!(engine.lock().unwrap().store.is_imported(&thread).unwrap());
            assert_eq!(fs::read(&path).unwrap(), source.as_bytes());
            assert_eq!(
                engine
                    .lock()
                    .unwrap()
                    .store
                    .original(&format!("ImportedSessions/{provider}/{id}.jsonl"))
                    .unwrap()
                    .unwrap(),
                source.as_bytes()
            );
        }
    }
    #[::core::prelude::v1::test]
    fn worker_real_api_rejects_changed_source_after_review() {
        let fixture = FixtureDirectory::new();
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&fixture.0.join("rust/state.sqlite")).unwrap(),
        )));
        let path = fixture.0.join("claude.jsonl");
        let source = json!({"sessionId":uuid::Uuid::new_v4().to_string(),"cwd":"/synthetic","uuid":"message-one","type":"user","message":{"role":"user","content":"before"}}).to_string();
        fs::write(&path, source).unwrap();
        let mut api = |method: &str, params| call(&engine, method, params);
        let Outcome::Preview(preview) = run(
            &mut api,
            Action::Preview(Selection {
                path: path.clone(),
                provider: "claude".into(),
                project: None,
            }),
        )
        .unwrap() else {
            panic!("preview")
        };
        fs::write(&path, b"changed after review").unwrap();
        assert!(run(&mut api, Action::Import(preview)).is_err());
        assert!(
            engine
                .lock()
                .unwrap()
                .store
                .summaries("", true)
                .unwrap()
                .is_empty()
        );
    }
    #[::core::prelude::v1::test]
    fn closed_import_owner_rejects_late_picker_and_worker_api_dispatch() {
        let mut workers = WorkerOwner::default();
        assert!(workers.begin_picker());
        workers.close();
        assert_eq!(workers.status().pending_pickers, 1);
        assert!(!finish_choice(&mut workers, 4, 4));
        assert_eq!(workers.status().pending_pickers, 0);
        let mut workers = WorkerOwner::default();
        let (ready_tx, ready_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (result_tx, result_rx) = mpsc::channel();
        assert!(workers.spawn(move |admission| {
            ready_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            let action = Action::Preview(Selection {
                path: PathBuf::from("/synthetic/session.jsonl"),
                provider: "codex".into(),
                project: None,
            });
            let result = run_admitted(
                &mut |_, _| panic!("closed worker must not touch Engine or source"),
                action,
                &admission,
            );
            result_tx.send(result.is_err()).unwrap();
        }));
        ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        workers.close();
        release_tx.send(()).unwrap();
        assert!(result_rx.recv_timeout(Duration::from_secs(5)).unwrap());
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while workers.status().unjoined != 0 {
            assert!(std::time::Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(workers.status().returned, 1);
    }
}
