use anyhow::Result;
mod assets;
mod bot_settings;
mod browser;
mod composer_attachments;
mod credential_settings;
mod credentials;
mod github_actions;
mod github_review;
mod github_write_transport;
mod microphone;
mod microphone_settings;
mod navigation;
mod notification_runtime;
mod notification_settings;
mod notifications;
mod presentation;
mod provider_settings;
mod queue;
mod scheduling;
mod session_import;
mod settings;
mod terminal_selection;
mod terminal_workspace;
mod transcript;
mod transcription_composer;
mod transcription_settings;
mod workspace;
use browser::BrowserController;
use coincide_core::{
    api::{Engine, SharedEngine},
    attachments::StoredImage,
    browser_protocol::BrowserAction,
    control,
    store::{Store, ThreadSummary, text},
    terminal::TerminalScroll,
};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::{
    component::{
        button::*,
        input::{Input, InputEvent, InputState, Textarea, TextareaState},
        text::TextView,
        *,
    },
    *,
};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Debug)]
struct EngineBusy;
impl std::fmt::Display for EngineBusy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("App is busy processing another operation; try again shortly")
    }
}
impl std::error::Error for EngineBusy {}
fn engine_busy(error: &anyhow::Error) -> bool {
    error.is::<EngineBusy>()
}
fn try_state<T>(state: &Mutex<T>) -> Result<std::sync::MutexGuard<'_, T>> {
    state.try_lock().map_err(|error| match error {
        std::sync::TryLockError::WouldBlock => EngineBusy.into(),
        std::sync::TryLockError::Poisoned(_) => anyhow::anyhow!("App engine is unavailable"),
    })
}
/// Native callbacks must never wait for a background import holding the engine.
/// Busy means dispatch did not run, so callers can retain their current state.
fn call(engine: &SharedEngine, method: &str, params: Value) -> Result<Value> {
    let response = try_state(engine)?.dispatch(json!({"method":method,"params":params}));
    if let Some(error) = response.get("error") {
        anyhow::bail!("{}", error["message"].as_str().unwrap_or("Command failed"));
    }
    Ok(response["result"].clone())
}

struct PendingDraft {
    text: String,
    retry: bool,
}

enum PreviewState {
    Checking,
    Ready(std::path::PathBuf),
    Unavailable,
}
struct ImagePreview {
    state: PreviewState,
    rows: Vec<(String, usize)>,
}

const TERMINAL_PAGE_ROWS: usize = 40;
const TERMINAL_CELL_WIDTH: f32 = 8.;
const TERMINAL_CELL_HEIGHT: f32 = 18.;

fn terminal_rgb(value: &Value, fallback: u32) -> Rgba {
    let Some(parts) = value.as_array().filter(|v| v.len() == 3) else {
        return rgb(fallback);
    };
    match (parts[0].as_u64(), parts[1].as_u64(), parts[2].as_u64()) {
        (Some(r), Some(g), Some(b)) if r <= 255 && g <= 255 && b <= 255 => {
            rgb(((r as u32) << 16) | ((g as u32) << 8) | b as u32)
        }
        _ => rgb(fallback),
    }
}

/// Publish pages only as one coherent bounded viewport. New output between API
/// calls invalidates the candidate frame; the last complete frame stays visible.
fn read_terminal_frame(engine: &SharedEngine, id: &str, offset: usize) -> Result<Option<Value>> {
    let mut frame = call(
        engine,
        "terminal.read",
        json!({"terminalId":id,"styled":true,"rowOffset":offset,"rowLimit":10}),
    )?;
    let rows = frame["rows"].as_u64().unwrap_or(0) as usize;
    let cols = frame["cols"].as_u64().unwrap_or(0) as usize;
    anyhow::ensure!(
        rows <= 300 && cols <= 500 && offset <= rows,
        "Invalid terminal viewport"
    );
    let end = (offset + TERMINAL_PAGE_ROWS).min(rows);
    let revision = frame["revision"].clone();
    let mut grid = Vec::new();
    let mut truncated = false;
    let mut next = offset;
    loop {
        anyhow::ensure!(
            frame["rowOffset"].as_u64() == Some(next as u64),
            "Invalid terminal page offset"
        );
        let page = frame["grid"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Terminal page has no cells"))?;
        anyhow::ensure!(
            page.len() == 10.min(end - next)
                && page
                    .iter()
                    .all(|row| row.as_array().is_some_and(|cells| cells.len() == cols)),
            "Invalid terminal page dimensions"
        );
        grid.extend(page.iter().cloned());
        truncated |= frame["truncated"] == true;
        next += page.len();
        if next >= end {
            break;
        }
        let page = call(
            engine,
            "terminal.read",
            json!({"terminalId":id,"styled":true,"rowOffset":next,"rowLimit":10.min(end-next)}),
        )?;
        if page["revision"] != revision
            || page["rows"].as_u64() != Some(rows as u64)
            || page["cols"].as_u64() != Some(cols as u64)
        {
            return Ok(None);
        }
        frame = page;
    }
    frame.as_object_mut().unwrap().remove("lines");
    frame["grid"] = json!(grid);
    frame["rowOffset"] = json!(offset);
    frame["rowCount"] = json!(end - offset);
    frame["truncated"] = json!(truncated);
    Ok(Some(frame))
}

struct Coincide {
    engine: SharedEngine,
    revision: u64,
    running: Vec<String>,
    pending_requests: Vec<Value>,
    pending_inputs: std::collections::HashMap<(String, String, String), Entity<InputState>>,
    pending_choices: std::collections::HashMap<(String, String, String), Vec<String>>,
    queued_messages: Vec<Value>,
    queue_enabled: bool,
    queue_error: String,
    settings_open: bool,
    bots_open: bool,
    bot_panel: Entity<bot_settings::BotSettingsPanel>,
    notifications_open: bool,
    notification_panel: Entity<notification_settings::NotificationSettingsPanel>,
    created_bot_thread_to_focus: Option<String>,
    transcription_open: bool,
    transcription_panel: Entity<transcription_settings::TranscriptionSettings>,
    transcription_events: std::sync::mpsc::Receiver<transcription_settings::TextReady>,
    transcription_target: transcription_composer::ComposerTarget,
    microphone_panel: Entity<microphone_settings::MicrophoneSettings>,
    microphone_events: std::sync::mpsc::Receiver<transcription_settings::TextReady>,
    microphone_window_active: bool,
    session_import_open: bool,
    session_import_panel: Entity<session_import::SessionImportPanel>,
    credentials_open: bool,
    credential_panel: Entity<credential_settings::CredentialSettings>,
    credential_jobs: std::sync::mpsc::Receiver<credentials::FillJob>,
    workspace_open: bool,
    workspace_panel: Entity<workspace::WorkspacePanel>,
    github_open: bool,
    github_panel: Entity<github_review::GitHubReviewPanel>,
    provider_settings: provider_settings::ProviderSettings,
    settings: Value,
    awake_status: Value,
    settings_status: String,
    appearance_dark: bool,
    applied_theme: Option<(bool, String)>,
    schedules_open: bool,
    schedules: Vec<Value>,
    schedule_editor: scheduling::ScheduleEditor,
    schedule_status: String,
    _poll: Task<()>,
    terminal_id: Option<String>,
    terminal_frame: Option<Value>,
    terminal_selection: terminal_selection::TerminalSelection,
    terminal_tabs: Vec<Value>,
    terminal_selected: std::collections::HashMap<String, String>,
    terminal_row_offset: usize,
    terminal_grid_scroll: ScrollHandle,
    terminal_wheel: Option<(String, f32)>,
    terminal_tabs_last_poll: Instant,
    terminal_blink_origin: Instant,
    terminal_blink_on: bool,
    terminal_status: String,
    terminal_focus: FocusHandle,
    transcript_list: ListState,
    transcript_count: usize,
    expanded: std::collections::HashSet<usize>,
    threads: Vec<ThreadSummary>,
    projects: Vec<Value>,
    selected_project: Option<String>,
    collapsed_projects: std::collections::HashSet<String>,
    show_snoozed: bool,
    navigation_last_clock: Instant,
    rename_target: Option<String>,
    rename_input: Entity<InputState>,
    archive_confirmation: Option<String>,
    project_picker_open: bool,
    project_path: Entity<InputState>,
    selected: Option<Value>,
    pending_drafts: std::collections::HashMap<String, PendingDraft>,
    composer: Entity<TextareaState>,
    model_input: Entity<InputState>,
    model_binding: Option<(String, String, String)>,
    attachment_import_threads: std::collections::HashSet<String>,
    attachment_root: Option<std::path::PathBuf>,
    image_previews: std::collections::HashMap<String, ImagePreview>,
    image_preview_order: std::collections::VecDeque<String>,
    image_validations_running: usize,
    image_waiting_rows: std::collections::HashSet<(String, usize)>,
    image_assets: Entity<RetainAllImageCache>,
    image_asset_order: std::collections::VecDeque<std::path::PathBuf>,
    search: Entity<InputState>,
    status: String,
    show_archived: bool,
    browser: Option<BrowserController>,
    browser_address: Entity<InputState>,
    browser_address_page: Option<(String, String)>,
    browser_panels: std::collections::HashSet<String>,
    browser_ui_operations: std::collections::HashMap<String, String>,
    browser_replies: Vec<coincide_core::browser_protocol::BrowserReply>,
    _subscriptions: Vec<Subscription>,
}

impl Coincide {
    fn sync_github_context(&mut self, cx: &mut Context<Self>) {
        let context = self
            .workspace_panel
            .read(cx)
            .cached_context()
            .filter(|(thread, _)| {
                self.selected
                    .as_ref()
                    .is_some_and(|selected| selected["id"] == *thread)
            });
        self.github_panel
            .update(cx, |panel, cx| panel.set_context(context, cx));
    }
    fn sync_workspace_context(&mut self, cx: &mut Context<Self>) {
        let thread = self.selected.as_ref().map(|selected| text(selected, "id"));
        let root_hint = self.selected.as_ref().and_then(|selected| {
            selected["worktreePath"]
                .as_str()
                .map(str::to_owned)
                .or_else(|| {
                    self.projects
                        .iter()
                        .find(|project| project["id"] == selected["projectID"])
                        .and_then(|project| project["path"].as_str())
                        .map(str::to_owned)
                })
        });
        self.workspace_panel
            .update(cx, |panel, cx| panel.set_context(thread, root_hint, cx));
        self.sync_github_context(cx);
    }
    fn sync_transcription_binding(
        &mut self,
        cx: &mut Context<Self>,
    ) -> Option<transcription_settings::ComposerBinding> {
        let thread = if self.settings_open
            && self.transcription_open
            && !self.bots_open
            && !self.notifications_open
            && !self.session_import_open
            && !self.credentials_open
            && !self.provider_settings.open
        {
            self.selected.as_ref().map(|thread| text(thread, "id"))
        } else {
            None
        };
        let composer = self.composer.read(cx);
        let binding = self.transcription_target.bind(
            thread.as_deref(),
            composer.value().as_ref(),
            composer.selected_range(),
            composer.is_selection_reversed(),
        );
        self.transcription_panel
            .update(cx, |panel, cx| panel.set_binding(binding.clone(), cx));
        let (settings_revision, configuration) = self
            .transcription_panel
            .read(cx)
            .recording_configuration(cx);
        let microphone_binding = self
            .microphone_window_active
            .then(|| binding.clone())
            .flatten();
        self.microphone_panel.update(cx, |panel, cx| {
            // Compilation is not live acceptance. No runtime or persisted
            // setting can enable native permission/capture through this mount.
            panel.set_target(
                microphone_binding,
                settings_revision,
                configuration,
                false,
                cx,
            );
        });
        binding
    }
    fn poll_transcription(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.microphone_window_active =
            window.is_window_active() && window.visibility().is_visible();
        self.sync_transcription_binding(cx);
        self.transcription_panel
            .update(cx, |panel, cx| panel.poll(cx));
        self.microphone_panel.update(cx, |panel, cx| panel.poll(cx));
        let events = self
            .transcription_events
            .try_iter()
            .take(4)
            .map(|event| (false, event))
            .chain(
                self.microphone_events
                    .try_iter()
                    .take(4)
                    .map(|event| (true, event)),
            )
            .collect::<Vec<_>>();
        for (from_microphone, event) in events {
            // Re-read text/range and ownership immediately before insertion,
            // independent of whether GPUI has delivered pending observations.
            let Some(binding) = self.sync_transcription_binding(cx) else {
                continue;
            };
            // Each panel owns its generation space. A microphone event must
            // never be validated against the file-transcription generation.
            let accepted = if from_microphone {
                self.microphone_panel
                    .read(cx)
                    .accepts_text(&event, &binding)
            } else {
                self.transcription_panel
                    .read(cx)
                    .accepts_text(&event, &binding)
            };
            if !accepted {
                continue;
            }
            let original = self.composer.read(cx).value().to_string();
            if self
                .selected
                .as_ref()
                .is_none_or(|thread| text(thread, "draft") != original)
            {
                self.transcription_target.changed();
                self.status = "Draft changed; transcript discarded.".into();
                cx.notify();
                continue;
            }
            match transcription_composer::insert(&binding, &event, &original) {
                Ok((updated, caret)) => {
                    if let Some(thread) = self
                        .selected
                        .as_mut()
                        .filter(|thread| thread["id"] == binding.thread_id)
                    {
                        thread["draft"] = json!(updated);
                    } else {
                        continue;
                    }
                    self.pending_drafts.insert(
                        binding.thread_id.clone(),
                        PendingDraft {
                            text: updated.clone(),
                            retry: true,
                        },
                    );
                    self.composer.update(cx, |composer, cx| {
                        composer.replace_all(updated, window, cx);
                        composer.set_selected_range(caret..caret, cx);
                    });
                    self.transcription_target.changed();
                    self.sync_transcription_binding(cx);
                    self.status =
                        "Transcript inserted into the selected draft. Nothing was sent.".into();
                    self.save_pending_draft(&binding.thread_id);
                    cx.notify();
                }
                Err(error) => {
                    self.status = error.to_string();
                    cx.notify();
                }
            }
        }
    }
    fn save_pending_draft(&mut self, id: &str) {
        let Some(pending) = self.pending_drafts.get(id).filter(|draft| draft.retry) else {
            return;
        };
        match call(
            &self.engine,
            "threads.patch",
            json!({"threadId":id,"patch":{"draft":pending.text}}),
        ) {
            Ok(_) => {
                self.pending_drafts.remove(id);
            }
            Err(error) => {
                // Only a failed try_lock guarantees no mutation happened. Keep
                // other failures visible without automatically replaying them.
                self.pending_drafts.get_mut(id).unwrap().retry = engine_busy(&error);
                self.status = format!("Draft remains in this window; not yet saved: {error}");
            }
        }
    }
    fn preserve_pending_draft(&self, thread: &mut Value) {
        if let Some(draft) = self.pending_drafts.get(&text(thread, "id")) {
            thread["draft"] = json!(draft.text);
        }
    }
    fn new(
        engine: SharedEngine,
        profile_dir: std::path::PathBuf,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let settings = call(&engine, "settings.read", json!({})).unwrap_or_else(|_| json!({}));
        let composer = cx.new(|cx| {
            TextareaState::new(window, cx)
                .placeholder("Write a message…")
                .submit_on_enter(settings["sendOnReturn"].as_bool().unwrap_or(true))
        });
        let mut transcription_events = None;
        let transcription_panel = cx.new(|cx| {
            let (panel, events) = transcription_settings::TranscriptionSettings::new(window, cx);
            transcription_events = Some(events);
            panel
        });
        let transcription_events =
            transcription_events.expect("Transcription receiver initialized");
        let (microphone_settings, microphone_events) =
            microphone_settings::MicrophoneSettings::new();
        let microphone_panel = cx.new(|_| microphone_settings);
        let bot_panel =
            cx.new(|cx| bot_settings::BotSettingsPanel::new(engine.clone(), window, cx));
        let notification_panel = cx.new(|cx| {
            notification_settings::NotificationSettingsPanel::new(engine.clone(), window, cx)
        });
        let model_input = cx.new(|cx| InputState::new(window, cx).placeholder("Default model"));
        let schedule_editor = scheduling::ScheduleEditor::new(window, cx);
        let provider_settings = provider_settings::ProviderSettings::new(window, cx);
        let session_import_panel =
            cx.new(|cx| session_import::SessionImportPanel::new(engine.clone(), window, cx));
        // Discovery checks executable metadata only. Vault reads require a
        // password-manager button click in this native panel.
        let (credential_settings, credential_jobs) =
            credential_settings::CredentialSettings::new(credential_settings::installed_sources());
        let credential_panel = cx.new(|_| credential_settings);
        let workspace_panel =
            cx.new(|cx| workspace::WorkspacePanel::new(engine.clone(), window, cx));
        let github_writes = github_write_transport::NativeWrites::new(engine.clone());
        let github_actions =
            cx.new(|cx| github_actions::GitHubActions::new(github_writes.transport(), window, cx));
        let github_panel = cx.new(|cx| {
            let mut panel = github_review::GitHubReviewPanel::new(engine.clone(), window, cx);
            panel.attach_actions(github_actions, github_writes, cx);
            panel
        });
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search conversations"));
        let rename_input =
            cx.new(|cx| InputState::new(window, cx).placeholder("Conversation title"));
        let project_path =
            cx.new(|cx| InputState::new(window, cx).placeholder("Existing project folder path"));
        let browser_address =
            cx.new(|cx| InputState::new(window, cx).placeholder("https://example.com"));
        let (browser, browser_error) = match BrowserController::new(profile_dir) {
            Ok(browser) => (Some(browser), None),
            Err(error) => (None, Some(format!("Browser unavailable: {error}"))),
        };
        if let Ok(mut engine) = engine.try_lock() {
            engine.ui_available = browser.is_some();
        }
        let mut subscriptions = vec![
            cx.observe_window_activation(window, |this, window, cx| {
                this.microphone_window_active = window.is_window_active() && window.visibility().is_visible();
                this.sync_transcription_binding(cx);
                this.sync_notification_activity(window, cx);
            }),
            cx.observe_window_visibility(window, |this, visibility, window, cx| {
                this.microphone_window_active = visibility.is_visible() && window.is_window_active();
                this.sync_transcription_binding(cx);
                this.sync_notification_activity(window, cx);
            }),
            cx.observe(&transcription_panel, |this, _, cx| {
                // Revoke stopped audio or queued text on configuration changes,
                // including an edit away and back before the next UI tick.
                this.sync_transcription_binding(cx);
            }),
            cx.observe(&workspace_panel, |this, _, cx| this.sync_github_context(cx)),
            cx.observe(&composer, |this, _, cx| {
                // Selection has no dedicated InputEvent in gpui-base 0.9.0.
                // Invalidate on every notification, including a coalesced
                // caret-away/back sequence; hidden unfocused composer is stable.
                this.transcription_target.changed();
                this.sync_transcription_binding(cx);
            }),
            cx.subscribe_in(&bot_panel, window, |this, _, event, window, cx| {
                match event {
                    bot_settings::BotSettingsEvent::Saved { bot_id } => {
                        this.settings_status = format!("Bot {bot_id} saved. Changes apply to new conversations.");
                    }
                    bot_settings::BotSettingsEvent::ConversationCreated { thread_id } => {
                        let thread_id = thread_id.clone();
                        let requested = thread_id.clone();
                        let engine = this.engine.clone();
                        // The worker already created the empty conversation.
                        // Only navigation runs here; never send or recreate it.
                        let open = cx.background_executor().spawn(async move {
                            coincide_core::api::call(&engine, "threads.open", json!({"threadId":requested}))
                        });
                        cx.spawn_in(window, async move |this, cx| {
                            let result = open.await;
                            let _ = this.update_in(cx, |this, window, cx| {
                                this.refresh(cx);
                                match result {
                                    Ok(_) => {
                                        this.session_import_open = false;
                                        this.workspace_open = false;
                                        this.schedules_open = false;
                                        this.selected_project = Some(coincide_core::bot_runtime::BOTS_PROJECT_ID.into());
                                        this.collapsed_projects.remove(coincide_core::bot_runtime::BOTS_PROJECT_ID);
                                        this.created_bot_thread_to_focus = Some(thread_id.clone());
                                        this.select(&thread_id, window, cx);
                                        this.status = if this.selected.as_ref().is_some_and(|thread| thread["id"] == thread_id) {
                                            "Opened an empty bot conversation. No message was sent.".into()
                                        } else {
                                            "Created an empty bot conversation; waiting to open it. No message was sent.".into()
                                        };
                                    }
                                    Err(error) => this.status = format!("Bot conversation created, but opening it failed: {error}"),
                                }
                                cx.notify();
                            });
                        }).detach();
                    }
                }
                cx.notify();
            }),
            cx.subscribe_in(
                &session_import_panel,
                window,
                |this, _, event, window, cx| {
                    let session_import::SessionImportEvent::Imported { thread_id } = event;
                    this.session_import_open = false;
                    this.workspace_open = false;
                    this.schedules_open = false;
                    let thread_id = thread_id.clone();
                    let engine = this.engine.clone();
                    let requested = thread_id.clone();
                    // Queue navigation off the UI thread so a busy Engine cannot
                    // lose a completed import's selection. Render retries it.
                    let open = cx.background_executor().spawn(async move {
                        coincide_core::api::call(&engine, "threads.open", json!({"threadId":requested}))
                    });
                    cx.spawn_in(window, async move |this, cx| {
                        let result = open.await;
                        let _ = this.update_in(cx, |this, window, cx| {
                            this.refresh(cx);
                            match result {
                                Ok(_) => {
                                    this.select(&thread_id, window, cx);
                                    this.status = "Imported a read-only conversation. Fork it before sending messages.".into();
                                }
                                Err(error) => this.status = format!("Session imported, but opening it failed: {error}"),
                            }
                            cx.notify();
                        });
                    }).detach();
                    cx.notify();
                },
            ),
            cx.subscribe(&rename_input, |this, _, event, cx| {
                if matches!(event, InputEvent::PressEnter { .. }) {
                    this.save_rename(cx);
                }
            }),
            cx.subscribe_in(&composer, window, |this, _, event, window, cx| {
                if matches!(event, InputEvent::PressEnter { shift: false, .. })
                    && this.settings["sendOnReturn"].as_bool().unwrap_or(true)
                    && !this.settings_open
                    && !this.schedules_open
                    && !this.workspace_open
                    && !this.session_import_open
                {
                    this.send(window, cx);
                }
            }),
            cx.subscribe(&browser_address, |this, _, event, cx| {
                if matches!(event, InputEvent::PressEnter { .. }) {
                    this.browser_go(cx);
                }
            }),
            cx.subscribe(&search, |this, _, event, cx| {
                if matches!(event, InputEvent::Change) {
                    this.refresh(cx);
                }
            }),
            cx.subscribe(&composer, |this, _, event, cx| {
                if matches!(event, InputEvent::Change) {
                    if let Some(v) = this.selected.as_mut() {
                        let draft = this.composer.read(cx).value().to_string();
                        if v["draft"].as_str() == Some(draft.as_str()) {
                            return;
                        }
                        v["draft"] = json!(draft);
                        let id = text(v, "id");
                        this.pending_drafts.insert(
                            id.clone(),
                            PendingDraft {
                                text: draft,
                                retry: true,
                            },
                        );
                        this.save_pending_draft(&id);
                    }
                }
            }),
        ];
        subscriptions.extend(schedule_editor.subscriptions(cx));
        subscriptions.extend(provider_settings.subscriptions(cx));
        let threads = call(&engine, "threads.list", json!({}))
            .and_then(|v| Ok(serde_json::from_value(v)?))
            .unwrap_or_default();
        let projects = call(&engine, "projects.list", json!({}))
            .ok()
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default();
        let attachment_root = engine
            .try_lock()
            .ok()
            .and_then(|engine| engine.store.data_directory().ok());
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(150))
                    .await;
                if this
                    .update_in(cx, |this, window, cx| this.tick(window, cx))
                    .is_err()
                {
                    break;
                }
            }
        });
        let mut this = Self {
            engine,
            revision: 0,
            running: Vec::new(),
            pending_requests: Vec::new(),
            pending_inputs: Default::default(),
            pending_choices: Default::default(),
            queued_messages: Vec::new(),
            queue_enabled: false,
            queue_error: String::new(),
            settings_open: false,
            bots_open: false,
            bot_panel,
            notifications_open: false,
            notification_panel,
            created_bot_thread_to_focus: None,
            transcription_open: false,
            transcription_panel,
            transcription_events,
            transcription_target: Default::default(),
            microphone_panel,
            microphone_events,
            microphone_window_active: window.is_window_active() && window.visibility().is_visible(),
            session_import_open: false,
            session_import_panel,
            credentials_open: false,
            credential_panel,
            credential_jobs,
            workspace_open: false,
            workspace_panel,
            github_open: false,
            github_panel,
            provider_settings,
            settings,
            awake_status: json!({}),
            settings_status: String::new(),
            appearance_dark: true,
            applied_theme: None,
            schedules_open: false,
            schedules: Vec::new(),
            schedule_editor,
            schedule_status: String::new(),
            _poll: poll,
            terminal_id: None,
            terminal_frame: None,
            terminal_selection: Default::default(),
            terminal_tabs: Vec::new(),
            terminal_selected: Default::default(),
            terminal_row_offset: 0,
            terminal_grid_scroll: ScrollHandle::new(),
            terminal_wheel: None,
            terminal_tabs_last_poll: Instant::now(),
            terminal_blink_origin: Instant::now(),
            terminal_blink_on: true,
            terminal_status: String::new(),
            terminal_focus: cx.focus_handle(),
            transcript_list: ListState::new(0, ListAlignment::Bottom, px(500.)),
            transcript_count: 0,
            expanded: Default::default(),
            threads,
            projects,
            selected_project: None,
            collapsed_projects: Default::default(),
            show_snoozed: false,
            navigation_last_clock: Instant::now(),
            rename_target: None,
            rename_input,
            archive_confirmation: None,
            project_picker_open: false,
            project_path,
            selected: None,
            pending_drafts: Default::default(),
            composer,
            model_input,
            model_binding: None,
            attachment_import_threads: Default::default(),
            attachment_root,
            image_previews: Default::default(),
            image_preview_order: Default::default(),
            image_validations_running: 0,
            image_waiting_rows: Default::default(),
            image_assets: RetainAllImageCache::new(cx),
            image_asset_order: Default::default(),
            search,
            status: browser_error.unwrap_or_else(|| "Rust preview · separate data store".into()),
            show_archived: false,
            browser,
            browser_address,
            browser_address_page: None,
            browser_panels: Default::default(),
            browser_ui_operations: Default::default(),
            browser_replies: Vec::new(),
            _subscriptions: subscriptions,
        };
        this.apply_appearance(window, cx);
        if let Some(id) = this.threads.first().map(|t| t.id.clone()) {
            this.select(&id, window, cx);
        }
        this
    }
    fn browser_action(
        &mut self,
        action: BrowserAction,
        tab: Option<String>,
        cx: &mut Context<Self>,
    ) {
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        let mut params = serde_json::to_value(action).unwrap_or_default();
        params["threadId"] = json!(thread);
        if let Some(tab) = tab {
            params["tab"] = json!(tab);
        }
        match call(&self.engine, "browser.request", params) {
            Ok(result) => {
                self.browser_ui_operations
                    .insert(text(&result, "operationId"), thread);
            }
            Err(error) => self.status = format!("Browser: {error}"),
        }
        cx.notify();
    }
    fn browser_go(&mut self, cx: &mut Context<Self>) {
        let url = self.browser_address.read(cx).value().to_string();
        self.browser_action(BrowserAction::Navigate { url }, None, cx);
    }
    fn toggle_browser(&mut self, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        let action = if self.browser_panels.contains(&thread) {
            BrowserAction::Hide
        } else {
            BrowserAction::Show
        };
        self.browser_action(action, None, cx);
    }
    fn poll_browser(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let requests = self
            .engine
            .try_lock()
            .map(|mut engine| engine.browser_requests.drain(..).collect::<Vec<_>>())
            .unwrap_or_default();
        let Some(browser) = &mut self.browser else {
            return;
        };
        let mut changed = !requests.is_empty();
        for request in requests {
            match &request.action {
                BrowserAction::Show => {
                    self.browser_panels.insert(request.thread_id.clone());
                }
                BrowserAction::Hide => {
                    self.browser_panels.remove(&request.thread_id);
                }
                _ => {}
            }
            browser.execute(request, window, cx);
        }
        changed |= browser.poll(window, cx);
        let selected = self.selected.as_ref().map(|v| text(v, "id"));
        let visible = selected
            .as_deref()
            .filter(|thread| self.browser_panels.contains(*thread));
        // API work for another thread may create a native surface; reconcile it
        // before yielding to the run loop so it never covers this conversation.
        browser.set_thread_visible(visible, cx);
        self.browser_replies.extend(browser.drain_replies());
        if let Ok(mut engine) = self.engine.try_lock() {
            for reply in self.browser_replies.drain(..) {
                engine.browser_reply(reply);
            }
        }
        for (id, thread) in self.browser_ui_operations.clone() {
            match call(
                &self.engine,
                "browser.result",
                json!({"operationId":id,"threadId":thread}),
            ) {
                Ok(result) if result["ready"] == true => {
                    self.browser_ui_operations.remove(&id);
                    if let Some(error) = result["result"]["error"].as_str() {
                        self.status = format!("Browser: {error}");
                    }
                    changed = true;
                }
                Err(error) if engine_busy(&error) => {}
                Err(error) => {
                    self.browser_ui_operations.remove(&id);
                    self.status = format!("Browser: {error}");
                    changed = true;
                }
                _ => {}
            }
        }
        // Track the actual page, not each render, so an unsubmitted address is
        // retained until navigation/tab selection changes it. Never replace text
        // while the user is working in the address field.
        if !self
            .browser_address
            .read(cx)
            .focus_handle(cx)
            .is_focused(window)
        {
            let current_page = selected.as_deref().and_then(|thread| {
                let tabs = browser.tab_list(thread);
                tabs["tabs"]
                    .as_array()?
                    .iter()
                    .find(|tab| tab["active"] == true)
                    .map(|tab| (text(tab, "id"), text(tab, "url")))
            });
            if current_page != self.browser_address_page {
                let address = current_page
                    .as_ref()
                    .map(|(_, url)| url.as_str())
                    .unwrap_or("");
                self.browser_address
                    .update(cx, |input, cx| input.set_value(address, window, cx));
                self.browser_address_page = current_page;
                changed = true;
            }
        }
        if changed {
            cx.notify();
        }
    }
    fn browser_pane(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let thread = self.selected.as_ref().map(|v| text(v, "id"))?;
        let browser = self.browser.as_ref()?;
        if !browser.is_visible(&thread) {
            return None;
        }
        let tabs = browser.tab_list(&thread);
        let webview = browser.active_view(&thread);
        let active = tabs["tabs"]
            .as_array()
            .and_then(|tabs| tabs.iter().find(|t| t["active"] == true))
            .cloned();
        let url = active
            .as_ref()
            .map(|tab| text(tab, "url"))
            .unwrap_or_default();
        let tab_buttons = tabs["tabs"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|tab| {
                let id = text(tab, "id");
                let title: String = text(tab, "title").chars().take(24).collect();
                Button::new(SharedString::from(format!("browser-tab-{id}")))
                    .label(title)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.browser_action(BrowserAction::SelectTab, Some(id.clone()), cx)
                    }))
            })
            .collect::<Vec<_>>();
        let active_id = active.as_ref().map(|tab| text(tab, "id"));
        Some(
            div()
                .flex()
                .flex_col()
                .w(px(500.))
                .flex_shrink_0()
                .h_full()
                .border_l_1()
                .border_color(self.color(0x29303d))
                .child(
                    div()
                        .flex()
                        .flex_wrap()
                        .flex_shrink_0()
                        .gap_1()
                        .p_2()
                        .child(Button::new("browser-back").label("←").on_click(cx.listener(
                            |this, _, _, cx| this.browser_action(BrowserAction::Back, None, cx),
                        )))
                        .child(
                            Button::new("browser-forward")
                                .label("→")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.browser_action(BrowserAction::Forward, None, cx)
                                })),
                        )
                        .child(
                            Button::new("browser-reload")
                                .label("Reload")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.browser_action(BrowserAction::Reload, None, cx)
                                })),
                        )
                        .child(
                            Button::new("browser-new-tab")
                                .label("+")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.browser_action(
                                        BrowserAction::NewTab { url: None },
                                        None,
                                        cx,
                                    )
                                })),
                        )
                        .child(
                            Button::new("browser-close-tab")
                                .label("Close tab")
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if let Some(id) = active_id.clone() {
                                        this.browser_action(BrowserAction::CloseTab, Some(id), cx);
                                    }
                                })),
                        )
                        .child(
                            Button::new("browser-hide")
                                .label("Hide")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.browser_action(BrowserAction::Hide, None, cx)
                                })),
                        ),
                )
                .child(
                    div()
                        .id("browser-tabs")
                        .flex()
                        .gap_1()
                        .px_2()
                        .overflow_x_scroll()
                        .children(tab_buttons),
                )
                .child(
                    div()
                        .flex()
                        .gap_1()
                        .p_2()
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .child(Input::new(&self.browser_address)),
                        )
                        .child(
                            Button::new("browser-go")
                                .label("Go")
                                .on_click(cx.listener(|this, _, _, cx| this.browser_go(cx))),
                        ),
                )
                .child(
                    div()
                        .px_2()
                        .pb_2()
                        .min_w_0()
                        .truncate()
                        .text_xs()
                        .child(url),
                )
                .child(
                    div()
                        .flex_1()
                        .min_h_0()
                        .when_some(webview, |pane, view| pane.child(view)),
                )
                .into_any_element(),
        )
    }
    fn refresh(&mut self, cx: &mut Context<Self>) -> bool {
        let mut complete = true;
        self.refresh_queue(cx);
        if self.schedules_open {
            self.refresh_schedules(cx);
        }
        if let Ok(projects) = call(&self.engine, "projects.list", json!({})) {
            self.projects = projects.as_array().cloned().unwrap_or_default();
        } else {
            complete = false;
        }
        match call(&self.engine,"threads.list",json!({"query":self.search.read(cx).value().to_string(),"includeArchived":self.show_archived})).and_then(|v|Ok(serde_json::from_value(v)?)) {
            Ok(threads) => self.threads = threads,
            Err(e) => { complete = false; self.status = format!("Unable to load conversations: {e}"); },
        }
        cx.notify();
        complete
    }
    fn select(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        match call(&self.engine, "threads.read", json!({"threadId":id})) {
            Ok(mut v) => {
                self.preserve_pending_draft(&mut v);
                if self
                    .created_bot_thread_to_focus
                    .as_deref()
                    .is_some_and(|pending| pending != id)
                {
                    self.created_bot_thread_to_focus = None;
                }
                self.transcription_target.changed();
                let draft = text(&v, "draft");
                if self
                    .selected
                    .as_ref()
                    .is_none_or(|thread| thread["id"] != id)
                {
                    self.image_assets
                        .update(cx, |cache, cx| cache.clear(window, cx));
                    self.image_asset_order.clear();
                    self.image_waiting_rows.clear();
                    for entry in self.image_previews.values_mut() {
                        entry.rows.clear();
                    }
                }
                self.transcript_count = v["items"].as_array().map_or(0, Vec::len);
                self.transcript_list.reset(self.transcript_count);
                self.expanded.clear();
                if self.schedule_editor.thread_id != id {
                    self.schedule_editor.open = false;
                }
                self.selected = Some(v);
                self.sync_workspace_context(cx);
                self.settings_open = false;
                self.rename_target = None;
                self.archive_confirmation = None;
                self.pending_requests.clear();
                self.schedules.clear();
                self.queued_messages.clear();
                self.queue_enabled = false;
                self.queue_error.clear();
                let visible = self.browser_panels.contains(id).then_some(id);
                if let Some(browser) = &mut self.browser {
                    browser.set_thread_visible(visible, cx);
                    let tabs = browser.tab_list(id);
                    let url = tabs["tabs"]
                        .as_array()
                        .and_then(|tabs| tabs.iter().find(|t| t["active"] == true))
                        .map(|tab| text(tab, "url"))
                        .unwrap_or_default();
                    self.browser_address
                        .update(cx, |input, cx| input.set_value(url, window, cx));
                }
                if let Ok(mut engine) = self.engine.try_lock() {
                    engine.active_thread = Some(id.into());
                    if engine.requested_open.as_deref() == Some(id) {
                        engine.requested_open = None;
                    }
                }
                self.terminal_id = None;
                self.terminal_frame = None;
                self.terminal_selection.clear();
                self.terminal_tabs.clear();
                self.terminal_row_offset = 0;
                self.terminal_status.clear();
                self.composer
                    .update(cx, |input, cx| input.set_value(draft, window, cx));
            }
            Err(e) => self.status = format!("Unable to open conversation: {e}"),
        }
        self.sync_transcription_binding(cx);
        self.refresh_queue(cx);
        if self.schedules_open {
            self.refresh_schedules(cx);
        }
        cx.notify();
    }
    fn new_thread(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let project = self
            .selected_project
            .clone()
            .or_else(|| self.selected.as_ref().map(|v| text(v, "projectID")))
            .unwrap_or_else(|| "00000000-0000-0000-0000-000000000000".into());
        if project.eq_ignore_ascii_case(coincide_core::bot_runtime::BOTS_PROJECT_ID) {
            // A virtual bot group has no filesystem project or generic default
            // bot. The user chooses a saved bot in its existing native editor.
            self.settings_open = true;
            self.bots_open = true;
            self.notifications_open = false;
            self.transcription_open = false;
            self.credentials_open = false;
            self.provider_settings.open = false;
            self.session_import_open = false;
            self.sync_transcription_binding(cx);
            cx.notify();
            return;
        }
        let cwd = self
            .projects
            .iter()
            .find(|p| p["id"] == project)
            .and_then(|p| p["path"].as_str())
            .filter(|path| !path.is_empty())
            .map(std::path::PathBuf::from)
            .or_else(|| std::env::current_dir().ok());
        match call(
            &self.engine,
            "threads.create",
            json!({"projectId":project,"cwd":cwd}),
        ) {
            Ok(v) => {
                self.refresh(cx);
                self.select(&text(&v, "id"), window, cx);
            }
            Err(e) => self.status = e.to_string(),
        }
    }
    fn add_project(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let path = self.project_path.read(cx).value().to_string();
        match call(&self.engine, "projects.create", json!({"path":path.trim()})) {
            Ok(project) => {
                self.selected_project = Some(text(&project, "id"));
                self.project_path
                    .update(cx, |input, cx| input.set_value("", window, cx));
                self.status = format!("Selected project {}", text(&project, "name"));
                self.refresh(cx);
            }
            Err(error) => {
                self.status = format!("Project could not be added: {error}");
                cx.notify();
            }
        }
    }
    fn toggle(&mut self, key: &str, cx: &mut Context<Self>) {
        if let Some(v) = self.selected.as_ref() {
            let mut patch = json!({});
            patch[key] = json!(!v[key].as_bool().unwrap_or(false));
            match call(
                &self.engine,
                "threads.patch",
                json!({"threadId":v["id"],"patch":patch}),
            ) {
                Ok(v) => self.selected = Some(v),
                Err(e) => self.status = e.to_string(),
            }
            self.refresh(cx);
        }
    }
    fn sync_credentials(&mut self, cx: &mut Context<Self>) {
        // Provider setup is another native settings workflow, never a reason
        // to keep password approval active behind that panel.
        if self.provider_settings.open {
            self.credentials_open = false;
        }
        let visible = self.settings_open && self.credentials_open && !self.session_import_open;
        let thread = self.selected.as_ref().map(|thread| text(thread, "id"));
        let (page, available) = if visible {
            self.browser
                .as_ref()
                .map(|browser| {
                    (
                        thread
                            .as_deref()
                            .and_then(|thread| browser.credential_page(thread, cx)),
                        browser.credential_fill_available(),
                    )
                })
                .unwrap_or((None, false))
        } else {
            (None, false)
        };
        // Revocation precedes polling or delivery: closing the panel, changing
        // documents, or losing the selection cannot retain a prior approval.
        self.credential_panel.update(cx, |panel, cx| {
            panel.set_page(page, available, cx);
            panel.poll(cx);
        });
        if let Some(browser) = &mut self.browser {
            browser.drain_credential_fills(
                thread.as_deref().unwrap_or(""),
                &self.credential_jobs,
                cx,
            );
        } else {
            // Dropping a private job disconnects its acknowledgement receiver;
            // a missing browser must never leave a worker believing it filled.
            for job in self.credential_jobs.try_iter().take(2) {
                drop(job);
            }
        }
    }
    fn sync_notification_activity(&self, window: &Window, cx: &App) {
        let visible_thread = (!self.settings_open
            && !self.schedules_open
            && !self.workspace_open
            && !self.session_import_open)
            .then(|| {
                self.selected.as_ref().and_then(|thread| {
                    thread["id"]
                        .as_str()
                        .and_then(|id| uuid::Uuid::parse_str(id).ok())
                })
            })
            .flatten();
        // Only foreground window/visible conversation are observed here.
        // No idle, lock or display-sleep monitors are connected. Do not assert
        // recent desktop interaction; remote delivery remains disconnected.
        let _ = self.notification_panel.read(cx).update_activity(
            coincide_core::platform_host::notifications::DesktopActivity {
                app_active: window.is_window_active() && window.visibility().is_visible(),
                visible_thread,
                idle_seconds: u64::MAX,
                locked: false,
                display_asleep: false,
            },
        );
    }
    fn tick(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.sync_notification_activity(window, cx);
        if self
            .created_bot_thread_to_focus
            .as_deref()
            .is_some_and(|id| {
                self.selected
                    .as_ref()
                    .is_some_and(|thread| thread["id"] == id)
            })
            && !self.settings_open
        {
            self.created_bot_thread_to_focus = None;
            self.composer.read(cx).focus_handle(cx).focus(window, cx);
        }
        if let Ok(mut engine) = self.engine.try_lock() {
            if engine.shutdown {
                cx.quit();
                return;
            }
            engine.ui_available = self.browser.is_some();
            engine.active_thread = self.selected.as_ref().map(|v| text(v, "id"));
            if self.attachment_root.is_none() {
                self.attachment_root = engine.store.data_directory().ok();
            }
        }
        for id in self.pending_drafts.keys().cloned().collect::<Vec<_>>() {
            self.save_pending_draft(&id);
        }
        self.refresh_awake_status(cx);
        self.apply_appearance(window, cx);
        if self.navigation_last_clock.elapsed() >= Duration::from_secs(30) {
            self.navigation_last_clock = Instant::now();
            cx.notify();
        }
        self.poll_browser(window, cx);
        self.sync_credentials(cx);
        self.poll_terminal(cx);
        if let Ok(status) = call(&self.engine, "app.status", json!({})) {
            let selected_thread = self.selected.as_ref().map(|thread| text(thread, "id"));
            let was_running = selected_thread
                .as_ref()
                .is_some_and(|id| self.running.contains(id));
            self.running = status["running"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default();
            let is_running = selected_thread
                .as_ref()
                .is_some_and(|id| self.running.contains(id));
            if was_running != is_running {
                self.transcript_list
                    .splice(0..self.transcript_count, self.transcript_count);
                cx.notify();
            }
            if was_running
                && selected_thread
                    .as_ref()
                    .is_some_and(|id| !self.running.contains(id))
                && self.status == "Agent running · approval required for changes"
            {
                self.status = "Agent turn ended.".into();
                cx.notify();
            }
            let revision = status["revision"].as_u64().unwrap_or(0);
            if revision != self.revision {
                self.refresh_settings(window, cx);
                if let Some(id) = self.selected.as_ref().map(|v| text(v, "id")) {
                    if let Ok(mut v) = call(&self.engine, "threads.read", json!({"threadId":id})) {
                        self.preserve_pending_draft(&mut v);
                        let count = v["items"].as_array().map_or(0, Vec::len);
                        let start = self.transcript_count.saturating_sub(1).min(count);
                        self.transcript_list
                            .splice(start..self.transcript_count, count - start);
                        self.transcript_count = count;
                        self.selected = Some(v);
                    } else {
                        return; // Retry this revision after the worker releases the engine.
                    }
                }
                if self.refresh(cx) {
                    self.revision = revision;
                }
            }
        }
        self.refresh_pending(window, cx);
        self.poll_transcription(window, cx);
    }
    fn refresh_pending(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        let requests = if self.running.contains(&thread) {
            match call(&self.engine, "agent.pending", json!({"threadId":thread})) {
                Ok(value) => value.as_array().cloned().unwrap_or_default(),
                Err(error) => {
                    let status = format!("Unable to load agent requests: {error}");
                    if self.status != status {
                        self.status = status;
                        cx.notify();
                    }
                    return;
                }
            }
        } else {
            Vec::new()
        };
        let live: std::collections::HashSet<_> =
            requests.iter().map(|r| text(r, "requestId")).collect();
        self.pending_inputs
            .retain(|(owner, id, _), _| owner != &thread || live.contains(id));
        self.pending_choices
            .retain(|(owner, id, _), _| owner != &thread || live.contains(id));
        for request in &requests {
            let request_id = text(request, "requestId");
            for question in request["params"]["questions"]
                .as_array()
                .into_iter()
                .flatten()
            {
                let key = (thread.clone(), request_id.clone(), text(question, "id"));
                self.pending_inputs.entry(key).or_insert_with(|| {
                    cx.new(|cx| {
                        let mut input =
                            InputState::new(window, cx).placeholder("Write your answer");
                        if question["isSecret"] == true {
                            input.set_masked(true, window, cx);
                        }
                        input
                    })
                });
            }
        }
        if self.pending_requests != requests {
            self.pending_requests = requests;
            cx.notify();
        }
    }
    fn respond_pending(&mut self, request_id: &str, decision: &str, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        self.finish_pending(
            &thread,
            request_id,
            "agent.respond",
            json!({"threadId":thread,"requestId":request_id,"decision":decision}),
            cx,
        );
    }
    fn answer_pending(&mut self, request_id: &str, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        let Some(request) = self
            .pending_requests
            .iter()
            .find(|r| r["requestId"] == request_id)
        else {
            return;
        };
        let Some(questions) = request["params"]["questions"].as_array() else {
            return;
        };
        let mut answers = serde_json::Map::new();
        for question in questions {
            let id = text(question, "id");
            let key = (thread.clone(), request_id.to_owned(), id.clone());
            let freeform = self
                .pending_inputs
                .get(&key)
                .map(|input| input.read(cx).value().to_string())
                .unwrap_or_default();
            let values = if freeform.trim().is_empty() {
                self.pending_choices.get(&key).cloned().unwrap_or_default()
            } else {
                vec![freeform]
            };
            if values.is_empty() {
                self.status = "Answer every question before submitting.".into();
                cx.notify();
                return;
            }
            answers.insert(id, json!({"answers":values}));
        }
        self.finish_pending(
            &thread,
            request_id,
            "agent.answer",
            json!({"threadId":thread,"requestId":request_id,"answers":answers}),
            cx,
        );
    }
    fn finish_pending(
        &mut self,
        thread: &str,
        request_id: &str,
        method: &str,
        params: Value,
        cx: &mut Context<Self>,
    ) {
        match call(&self.engine, method, params) {
            Ok(_) => {
                self.pending_requests
                    .retain(|r| r["requestId"] != request_id);
                self.pending_inputs
                    .retain(|(owner, id, _), _| owner != thread || id != request_id);
                self.pending_choices
                    .retain(|(owner, id, _), _| owner != thread || id != request_id);
                self.status = "Response sent to the agent.".into();
            }
            Err(error) => self.status = format!("Response was not sent: {error}"),
        }
        cx.notify();
    }
    fn pending_pane(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        if self.pending_requests.is_empty() {
            return None;
        }
        let thread = self.selected.as_ref().map(|v| text(v, "id"))?;
        let mut cards = Vec::new();
        for request in &self.pending_requests {
            let request_id = text(request, "requestId");
            let card = div()
                .flex()
                .flex_col()
                .h(px(260.))
                .flex_shrink_0()
                .gap_2()
                .p_3()
                .rounded_md()
                .bg(self.color(0x253046));
            let mut body = div()
                .id(SharedString::from(format!("pending-body-{request_id}")))
                .flex()
                .flex_col()
                .flex_1()
                .min_h_0()
                .gap_2()
                .overflow_y_scroll();
            let actions;
            if request["method"] == "item/tool/requestUserInput" {
                body = body.child(div().font_semibold().child("The agent needs your answer"));
                for (index, question) in request["params"]["questions"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .enumerate()
                {
                    let key = (thread.clone(), request_id.clone(), text(question, "id"));
                    body = body
                        .child(div().text_sm().child(text(question, "header")))
                        .child(div().child(text(question, "question")));
                    let multiple = question["multiSelect"] == true;
                    let mut options = div().flex().flex_col().gap_1();
                    for (option_index, option) in question["options"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .enumerate()
                    {
                        let label = text(option, "label");
                        let chosen = self
                            .pending_choices
                            .get(&key)
                            .is_some_and(|choices| choices.contains(&label));
                        let key = key.clone();
                        let button_label = format!("{}{}", if chosen { "✓ " } else { "" }, label);
                        options =
                            options
                                .child(
                                    Button::new(SharedString::from(format!(
                                        "answer-{request_id}-{index}-{option_index}"
                                    )))
                                    .label(button_label)
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        let choices =
                                            this.pending_choices.entry(key.clone()).or_default();
                                        if multiple {
                                            if choices.contains(&label) {
                                                choices.retain(|v| v != &label);
                                            } else {
                                                choices.push(label.clone());
                                            }
                                        } else {
                                            *choices = vec![label.clone()];
                                        }
                                        if let Some(input) = this.pending_inputs.get(&key) {
                                            input.update(cx, |input, cx| {
                                                input.set_value("", window, cx)
                                            });
                                        }
                                        cx.notify();
                                    })),
                                )
                                .child(div().text_sm().child(text(option, "description")));
                    }
                    body = body.child(options);
                    if let Some(input) = self.pending_inputs.get(&key) {
                        body = body
                            .child(
                                div()
                                    .text_sm()
                                    .child("Or write an answer; this replaces selected options."),
                            )
                            .child(Input::new(input));
                    }
                }
                let id = request_id.clone();
                actions = div().flex_shrink_0().child(
                    Button::new(SharedString::from(format!("submit-{request_id}")))
                        .label("Submit answers")
                        .on_click(cx.listener(move |this, _, _, cx| this.answer_pending(&id, cx))),
                );
            } else {
                body = body.child(div().font_semibold().child("Approval required"));
                let mut details = request["params"].clone();
                if let Some(object) = details.as_object_mut() {
                    object.remove("providerFrame");
                }
                body = body
                    .child(div().text_sm().child(text(request, "method")))
                    .child(TextView::markdown(
                        SharedString::from(format!("approval-details-{request_id}")),
                        format!(
                            "```json\n{}\n```",
                            serde_json::to_string_pretty(&details).unwrap_or_default()
                        ),
                    ));
                let offered = request["params"]["availableDecisions"].as_array();
                let mut buttons = div().flex().flex_wrap().flex_shrink_0().gap_2();
                for (decision, label) in [
                    ("accept", "Allow once"),
                    ("decline", "Decline"),
                    ("cancel", "Cancel request"),
                ] {
                    if offered.is_some_and(|options| !options.iter().any(|v| v == decision)) {
                        continue;
                    }
                    let id = request_id.clone();
                    buttons = buttons.child(
                        Button::new(SharedString::from(format!(
                            "decision-{request_id}-{decision}"
                        )))
                        .label(label)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.respond_pending(&id, decision, cx)
                        })),
                    );
                }
                actions = div().flex_shrink_0().child(buttons);
            }
            // Only the request details scroll. Decisions stay in a separate
            // footer, reachable even when questions/options exceed the pane.
            cards.push(card.child(body).child(actions));
        }
        Some(
            div()
                .id("pending-agent-requests")
                .flex()
                .flex_col()
                .gap_2()
                .max_h(px(340.))
                .flex_shrink_0()
                .overflow_y_scroll()
                .p_3()
                .child(div().text_sm().child(format!(
                    "{} pending request(s)",
                    self.pending_requests.len()
                )))
                .children(cards)
                .into_any_element(),
        )
    }
    fn remove_image(&mut self, attachment_id: &str, cx: &mut Context<Self>) {
        let Some(thread_id) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        match call(
            &self.engine,
            "attachments.remove",
            json!({"threadId":thread_id,"attachmentId":attachment_id}),
        ) {
            Ok(_) => {
                if let Ok(thread) =
                    call(&self.engine, "threads.read", json!({"threadId":thread_id}))
                {
                    self.selected = Some(thread);
                }
                self.status = "Image removed from this draft.".into();
            }
            Err(error) => self.status = format!("Image could not be removed: {error}"),
        }
        cx.notify();
    }
    fn image_preview(
        &mut self,
        metadata: &Value,
        row: Option<usize>,
        width: f32,
        height: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let placeholder_background = self.color(0x111722);
        let placeholder = |label: &'static str| {
            div()
                .w(px(width))
                .h(px(height))
                .flex_shrink_0()
                .flex()
                .items_center()
                .justify_center()
                .bg(placeholder_background)
                .rounded_md()
                .text_xs()
                .child(label)
                .into_any_element()
        };
        let Ok(stored) = serde_json::from_value::<StoredImage>(metadata.clone()) else {
            return placeholder("Image unavailable");
        };
        // The complete typed metadata is the cache revision. An ID reused with
        // a different path/dimensions never inherits an earlier validation.
        let Ok(key) = serde_json::to_string(&stored) else {
            return placeholder("Image unavailable");
        };
        if key.len() > 16384 {
            return placeholder("Image unavailable");
        }
        if !self.image_previews.contains_key(&key) {
            if self.image_validations_running >= 4 {
                if let Some(index) = row {
                    if let Some(thread) = self.selected.as_ref().map(|thread| text(thread, "id")) {
                        self.image_waiting_rows.insert((thread, index));
                    }
                }
                return placeholder("Loading image…");
            }
            let Some(root) = self.attachment_root.clone() else {
                return placeholder("Image unavailable");
            };
            while self.image_previews.len() >= 128 {
                let candidate = self
                    .image_preview_order
                    .iter()
                    .find(|key| {
                        self.image_previews
                            .get(*key)
                            .is_none_or(|entry| !matches!(entry.state, PreviewState::Checking))
                    })
                    .cloned();
                let Some(candidate) = candidate else {
                    break;
                };
                self.image_preview_order.retain(|key| key != &candidate);
                self.image_previews.remove(&candidate);
            }
            self.image_previews.insert(
                key.clone(),
                ImagePreview {
                    state: PreviewState::Checking,
                    rows: Vec::new(),
                },
            );
            self.image_validations_running += 1;
            let validation = cx.background_executor().spawn(async move {
                // Includes UUID-root/path/symlink/size/decoded-dimension checks.
                // No metadata path reaches GPUI until this succeeds.
                stored.prepare_in(&root).map(|_| stored.path)
            });
            let completed_key = key.clone();
            cx.spawn(async move |this, cx| {
                let result = validation.await;
                let _ = this.update(cx, |this, cx| {
                    this.image_validations_running =
                        this.image_validations_running.saturating_sub(1);
                    if let Some(entry) = this.image_previews.get_mut(&completed_key) {
                        entry.state = match result {
                            Ok(path) => PreviewState::Ready(path),
                            Err(_) => PreviewState::Unavailable,
                        };
                        let selected = this.selected.as_ref().map(|thread| text(thread, "id"));
                        for (thread, index) in &entry.rows {
                            if selected.as_deref() == Some(thread.as_str())
                                && *index < this.transcript_count
                            {
                                this.transcript_list.splice(*index..*index + 1, 1);
                            }
                        }
                    }
                    let selected = this.selected.as_ref().map(|thread| text(thread, "id"));
                    for (thread, index) in this.image_waiting_rows.drain() {
                        if selected.as_deref() == Some(thread.as_str())
                            && index < this.transcript_count
                        {
                            this.transcript_list.splice(index..index + 1, 1);
                        }
                    }
                    cx.notify();
                });
            })
            .detach();
        }
        self.image_preview_order.retain(|previous| previous != &key);
        self.image_preview_order.push_back(key.clone());
        let entry = self
            .image_previews
            .get_mut(&key)
            .expect("preview was inserted");
        if let Some(index) = row {
            if let Some(thread) = self.selected.as_ref().map(|thread| text(thread, "id")) {
                let target = (thread, index);
                if !entry.rows.contains(&target) {
                    entry.rows.push(target);
                }
            }
        }
        let path = match &entry.state {
            PreviewState::Ready(path) => path.clone(),
            PreviewState::Checking => return placeholder("Loading image…"),
            PreviewState::Unavailable => return placeholder("Image unavailable"),
        };
        self.image_asset_order.retain(|old| old != &path);
        self.image_asset_order.push_back(path.clone());
        // Bound decoded native/GPU images independently of cheap validation
        // records. Offscreen transcript rows remain virtualized by ListState.
        while self.image_asset_order.len() > 32 {
            if let Some(old) = self.image_asset_order.pop_front() {
                let resource: Resource = old.into();
                self.image_assets
                    .update(cx, |cache, cx| cache.remove(&resource, window, cx));
            }
        }
        img(path)
            .image_cache(&self.image_assets)
            .w(px(width))
            .h(px(height))
            .flex_shrink_0()
            .object_fit(ObjectFit::Contain)
            .rounded_md()
            .with_loading(|| div().text_xs().child("Loading image…").into_any_element())
            .with_fallback(|| {
                div()
                    .text_xs()
                    .child("Image unavailable")
                    .into_any_element()
            })
            .into_any_element()
    }
    fn draft_images(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let images = self.selected.as_ref()?["rustDraftImages"]
            .as_array()?
            .clone();
        if images.is_empty() {
            return None;
        }
        Some(
            div()
                .id("draft-images")
                .flex()
                .flex_col()
                .gap_1()
                .max_h(px(110.))
                .overflow_y_scroll()
                .mb_2()
                .child(
                    div()
                        .text_sm()
                        .child(format!("{} image(s) attached", images.len())),
                )
                .children(images.iter().map(|image| {
                    let id = text(image, "id");
                    div()
                        .flex()
                        .items_center()
                        .gap_2()
                        .flex_shrink_0()
                        .child(self.image_preview(image, None, 64., 64., window, cx))
                        .child(div().flex_1().min_w_0().truncate().text_sm().child(format!(
                            "{} · {}×{}",
                            text(image, "originalName"),
                            image["width"],
                            image["height"]
                        )))
                        .child(
                            Button::new(SharedString::from(format!("remove-image-{id}")))
                                .label("Remove")
                                .on_click(
                                    cx.listener(move |this, _, _, cx| this.remove_image(&id, cx)),
                                ),
                        )
                }))
                .into_any_element(),
        )
    }
    fn send(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // A hidden composer may retain focus after opening the Git pane.
        if self.workspace_open || self.session_import_open {
            return;
        }
        if self
            .selected
            .as_ref()
            .is_some_and(|v| self.running.contains(&text(v, "id")))
        {
            self.queue_message(window, cx);
            return;
        }
        if let Some(v) = self.selected.as_ref() {
            if self.attachment_import_threads.contains(&text(v, "id")) {
                self.status = "Wait for image imports to finish before sending.".into();
                cx.notify();
                return;
            }
            match call(
                &self.engine,
                "agent.send",
                json!({"threadId":v["id"],"text":self.composer.read(cx).value().to_string()}),
            ) {
                Ok(_) => {
                    let id = text(v, "id");
                    self.pending_drafts.remove(&id);
                    if !self.running.contains(&id) {
                        self.running.push(id);
                        self.transcript_list
                            .splice(0..self.transcript_count, self.transcript_count);
                    }
                    self.status = "Agent running · approval required for changes".into();
                    if let Some(thread) = self.selected.as_mut() {
                        thread["draft"] = json!("");
                    }
                    self.composer
                        .update(cx, |input, cx| input.set_value("", window, cx));
                }
                Err(e) => self.status = e.to_string(),
            }
        }
        cx.notify();
    }
    fn select_provider(&mut self, provider: &str, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        match call(
            &self.engine,
            "agent.select",
            json!({"threadId":thread,"provider":provider}),
        ) {
            Ok(thread) => {
                self.selected = Some(thread);
                self.model_binding = None;
                self.status = format!("Selected {provider}");
            }
            Err(error) => self.status = error.to_string(),
        }
        cx.notify();
    }
    fn sync_model_input(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let binding = self.selected.as_ref().map(|thread| {
            (
                text(thread, "id"),
                text(&thread["selection"], "provider"),
                text(&thread["selection"], "modelID"),
            )
        });
        if self.model_binding == binding {
            return;
        }
        let model = binding
            .as_ref()
            .map(|(_, _, model)| model.clone())
            .filter(|model| model != "default")
            .unwrap_or_default();
        self.model_input
            .update(cx, |input, cx| input.set_value(model, window, cx));
        self.model_binding = binding;
    }
    fn apply_model(&mut self, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref() else {
            return;
        };
        let model = self.model_input.read(cx).value().to_string();
        if model.len() > 512 || model.chars().any(char::is_control) {
            self.status = "Model ID must be at most 512 bytes without control characters.".into();
            cx.notify();
            return;
        }
        let model = model.trim();
        match call(
            &self.engine,
            "agent.select",
            json!({"threadId":thread["id"],"provider":thread["selection"]["provider"],"accountId":thread["selection"]["accountID"],"model":if model.is_empty(){"default"}else{model}}),
        ) {
            Ok(thread) => {
                self.selected = Some(thread);
                self.model_binding = None;
                self.status = "Model selection saved.".into();
            }
            Err(error) => self.status = error.to_string(),
        }
        cx.notify();
    }
    fn message(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let Some(item) = self
            .selected
            .as_ref()
            .and_then(|v| v["items"].as_array())
            .and_then(|items| items.get(index))
        else {
            return div().into_any_element();
        };
        let kind = text(item, "kind");
        let item_id = text(item, "id");
        let source_id = self
            .selected
            .as_ref()
            .map(|v| text(v, "id"))
            .unwrap_or_default();
        let source_running = self.running.contains(&source_id);
        let running_start = self
            .selected
            .as_ref()
            .and_then(|v| v["items"].as_array())
            .and_then(|items| {
                items
                    .iter()
                    .rposition(|item| item["kind"] == "user" && item["steered"] != true)
            });
        let settled = !source_running || running_start.is_some_and(|start| index < start);
        if kind == "reasoning" && !self.settings["showReasoning"].as_bool().unwrap_or(true) {
            return div().into_any_element();
        }
        let body = text(item, "text");
        let copy_empty = body.is_empty();
        let collapsible = kind != "user" && kind != "assistant";
        let expanded = self.expanded.contains(&index);
        let shown = if collapsible && !expanded {
            body.chars().take(180).collect()
        } else {
            body
        };
        let provider = text(item, "provider");
        let model = item["modelID"]
            .as_str()
            .or_else(|| item["model"].as_str())
            .unwrap_or_default()
            .to_owned();
        let label = match kind.as_str() {
            "user" => "You".to_owned(),
            "assistant" => presentation::provider_name(&provider).to_owned(),
            "reasoning" => format!("{} · Thinking", presentation::provider_name(&provider)),
            "tool" => "Tool activity".to_owned(),
            "error" => "Error".to_owned(),
            "system" => "Conversation update".to_owned(),
            _ => kind.clone(),
        };
        let action_excerpt: String = text(item, "text").chars().take(72).collect();
        // Only Rust-ingested metadata is previewable. Legacy imported media is
        // deliberately not opened through arbitrary historical paths.
        let images = item["rustImages"].as_array().cloned().unwrap_or_default();
        let previews = images
            .iter()
            .take(20)
            .map(|image| {
                let name: String = text(image, "originalName").chars().take(200).collect();
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(self.image_preview(image, Some(index), 240., 180., window, cx))
                    .child(div().max_w(px(240.)).truncate().text_xs().child(name))
            })
            .collect::<Vec<_>>();
        let card =
            div()
                .id(SharedString::from(format!(
                    "message-row-{source_id}-{item_id}"
                )))
                .min_w_0()
                .w_full()
                .my_3()
                .p_3()
                .rounded(px(12.))
                .when(kind == "user", |card| {
                    card.max_w(px((presentation::CONTENT_WIDTH
                        - presentation::RAIL_GUTTER)
                        * 0.75))
                        .bg(self.color(0xe4e9f2).opacity(0.06))
                })
                .when(kind == "assistant", |card| {
                    card.border_l_2()
                        .border_color(self.provider_ink(&provider))
                        .rounded_none()
                })
                .when(collapsible, |card| {
                    card.bg(self.color(0x181d28))
                        .border_1()
                        .border_color(self.color(0x29303d))
                })
                .child(
                    div()
                        .text_sm()
                        .text_color(if kind == "assistant" {
                            self.provider_ink(&provider)
                        } else {
                            self.color(0xe4e9f2).opacity(0.7)
                        })
                        .mb_2()
                        .flex()
                        .flex_wrap()
                        .items_center()
                        .justify_between()
                        .gap_2()
                        .child(div().min_w_0().flex_1().child(label).when(
                            kind == "assistant" && !model.is_empty(),
                            |label| {
                                label.child(
                                    div()
                                        .text_xs()
                                        .text_color(self.color(0xe4e9f2).opacity(0.6))
                                        .child(model),
                                )
                            },
                        ))
                        .child({
                            let source = source_id.clone();
                            let item = item_id.clone();
                            Button::new(SharedString::from(format!(
                                "copy-message-{source_id}-{item_id}"
                            )))
                            .accessibility_id(SharedString::from(format!(
                                "copy-message-{source_id}-{item_id}"
                            )))
                            .label("Copy message")
                            .ghost()
                            .compact()
                            .disabled(copy_empty)
                            .tooltip("Copy the complete message text, including collapsed content")
                            .on_click(cx.listener(
                                move |this, _, _, cx| this.copy_message(&source, &item, cx),
                            ))
                        }),
                )
                .when(collapsible, |view| {
                    let source = source_id.clone();
                    let item = item_id.clone();
                    view.child(
                        Button::new(SharedString::from(format!("expand-{source_id}-{item_id}")))
                            .accessibility_id(SharedString::from(format!(
                                "expand-{source_id}-{item_id}"
                            )))
                            .label(if expanded { "Collapse" } else { "Expand" })
                            .ghost()
                            .compact()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                let Some(thread) =
                                    this.selected.as_ref().filter(|v| v["id"] == source)
                                else {
                                    return;
                                };
                                let Some(index) = thread["items"]
                                    .as_array()
                                    .and_then(|items| items.iter().position(|v| v["id"] == item))
                                else {
                                    return;
                                };
                                if !this.expanded.remove(&index) {
                                    this.expanded.insert(index);
                                }
                                this.transcript_list.splice(index..index + 1, 1);
                                cx.notify();
                            })),
                    )
                })
                .child(transcript::preserve_selected_copy(
                    &source_id,
                    &item_id,
                    transcript::markdown(&source_id, &item_id, shown, window, cx)
                        .text_size(px(self.conversation_font_size()
                            + if kind == "assistant"
                                && self.settings["replyTypeface"].as_str().unwrap_or("newYork")
                                    == "newYork"
                            {
                                1.
                            } else {
                                0.
                            }))
                        .when(
                            kind == "assistant"
                                && self.settings["replyTypeface"].as_str().unwrap_or("newYork")
                                    == "newYork",
                            |view| view.font_family(settings::reply_font()),
                        ),
                ))
                .when(!previews.is_empty(), |view| {
                    view.child(div().flex().flex_wrap().gap_2().mt_2().children(previews))
                })
                .when(kind == "user", |view| {
                    let source = source_id.clone();
                    let item = item_id.clone();
                    view.child(
                    div().mt_2().child(
                        Button::new(SharedString::from(format!(
                            "edit-message-branch-{source_id}-{item_id}"
                        )))
                        .accessibility_id(SharedString::from(format!(
                            "edit-message-branch-{source_id}-{item_id}"
                        )))
                        .accessibility_label(SharedString::from(format!(
                            "Edit message in new branch: {action_excerpt}"
                        )))
                        .label("Edit in new branch")
                        .ghost().compact()
                        .disabled(source_running)
                        .tooltip(if source_running {
                            "Stop the current turn before editing an earlier message"
                        } else {
                            "Create a separate conversation with this message restored as a draft"
                        })
                        .on_click(cx.listener(
                            move |this, _, window, cx| {
                                this.branch_from_item(&source, &item, true, window, cx)
                            },
                        )),
                    ),
                )
                })
                .when(kind == "assistant" && settled, |view| {
                    view.child(
                    div().mt_2().child(
                        Button::new(SharedString::from(format!(
                            "fork-message-turn-{source_id}-{item_id}"
                        )))
                        .accessibility_id(SharedString::from(format!(
                            "fork-message-turn-{source_id}-{item_id}"
                        )))
                        .accessibility_label(SharedString::from(format!(
                            "Fork through response: {action_excerpt}"
                        )))
                        .label("Fork through this turn")
                        .ghost().compact()
                        .tooltip(
                            "Copy settled conversation through this turn into a separate branch",
                        )
                        .on_click(cx.listener(
                            move |this, _, window, cx| {
                                this.branch_from_item(&source_id, &item_id, false, window, cx)
                            },
                        )),
                    ),
                )
                });
        div()
            .flex()
            .w_full()
            .px(px(presentation::CONTENT_GUTTER))
            .justify_center()
            .child(
                div()
                    .flex()
                    .w_full()
                    .min_w_0()
                    .max_w(px(presentation::CONTENT_WIDTH))
                    .pl(px(presentation::RAIL_GUTTER))
                    .when(
                        kind == "user"
                            && self.settings["userMessageSide"].as_str().unwrap_or("right")
                                != "left",
                        |row| row.justify_end(),
                    )
                    .child(card),
            )
            .into_any_element()
    }
    fn refresh_terminal_tabs(&mut self) {
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        match call(&self.engine, "terminal.list", json!({"threadId":thread})) {
            Ok(value) => {
                let old_ids = self
                    .terminal_tabs
                    .iter()
                    .map(|tab| text(tab, "terminalId"))
                    .collect::<Vec<_>>();
                let mut tabs = value.as_array().cloned().unwrap_or_default();
                tabs.sort_by_key(|tab| {
                    let id = text(tab, "terminalId");
                    (
                        old_ids
                            .iter()
                            .position(|old| old == &id)
                            .unwrap_or(usize::MAX),
                        id,
                    )
                });
                self.terminal_tabs = tabs;
                if self.terminal_id.as_ref().is_some_and(|id| {
                    !self
                        .terminal_tabs
                        .iter()
                        .any(|tab| tab["terminalId"] == *id)
                }) {
                    self.terminal_id = self
                        .terminal_tabs
                        .first()
                        .map(|tab| text(tab, "terminalId"));
                    self.terminal_frame = None;
                    self.terminal_selection.clear();
                    self.terminal_row_offset = 0;
                    if let Some(id) = &self.terminal_id {
                        self.terminal_selected.insert(thread, id.clone());
                    }
                }
            }
            Err(error) => self.terminal_status = error.to_string(),
        }
        self.terminal_tabs_last_poll = Instant::now();
    }
    fn select_terminal(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        self.terminal_selection.clear();
        self.terminal_wheel = None;
        self.terminal_grid_scroll.scroll_to_bottom();
        if let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) {
            self.terminal_selected.insert(thread, id.clone());
        }
        self.terminal_id = Some(id);
        self.terminal_frame = None;
        self.terminal_row_offset = 0;
        self.terminal_status.clear();
        self.terminal_blink_origin = Instant::now();
        self.terminal_blink_on = true;
        window.focus(&self.terminal_focus, cx);
        self.poll_terminal(cx);
        self.terminal_grid_scroll.scroll_to_bottom();
        cx.notify();
    }
    fn new_terminal(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        match call(&self.engine, "terminal.create", json!({"threadId":thread})) {
            Ok(value) => {
                self.refresh_terminal_tabs();
                self.select_terminal(text(&value, "terminalId"), window, cx);
            }
            Err(error) => {
                self.status = error.to_string();
                cx.notify();
            }
        }
    }
    fn close_terminal(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let was_active = self.terminal_id.as_deref() == Some(id);
        match call(&self.engine, "terminal.close", json!({"terminalId":id})) {
            Ok(_) => {
                self.terminal_selected.retain(|_, selected| selected != id);
                self.refresh_terminal_tabs();
                if was_active {
                    if let Some(active) = self.terminal_id.clone() {
                        self.select_terminal(active, window, cx);
                    }
                } else {
                    window.focus(&self.terminal_focus, cx);
                }
            }
            Err(error) => self.terminal_status = error.to_string(),
        }
        cx.notify();
    }
    fn terminal(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.terminal_id.is_some() {
            self.terminal_selection.clear();
            self.terminal_id = None;
            self.terminal_frame = None;
            cx.notify();
            return;
        }
        self.refresh_terminal_tabs();
        let preferred = self
            .selected
            .as_ref()
            .and_then(|thread| self.terminal_selected.get(&text(thread, "id")))
            .cloned();
        let existing = preferred
            .filter(|id| {
                self.terminal_tabs
                    .iter()
                    .any(|tab| tab["terminalId"] == *id)
            })
            .or_else(|| {
                self.terminal_tabs
                    .first()
                    .map(|tab| text(tab, "terminalId"))
            });
        if let Some(id) = existing {
            self.select_terminal(id, window, cx);
        } else {
            self.new_terminal(window, cx);
        }
    }
    fn poll_terminal(&mut self, cx: &mut Context<Self>) {
        if self.terminal_id.is_none() {
            return;
        }
        if self.terminal_tabs_last_poll.elapsed() >= Duration::from_secs(1) {
            let before = self.terminal_tabs.clone();
            self.refresh_terminal_tabs();
            if self.terminal_tabs != before {
                cx.notify();
            }
        }
        let Some(id) = self.terminal_id.clone() else {
            return;
        };
        match call(&self.engine, "terminal.read", json!({"terminalId":id})) {
            Ok(plain) => {
                let rows = plain["rows"].as_u64().unwrap_or(0) as usize;
                self.terminal_row_offset = self
                    .terminal_row_offset
                    .min(rows.saturating_sub(1) / TERMINAL_PAGE_ROWS * TERMINAL_PAGE_ROWS);
                let needs_frame = self.terminal_frame.as_ref().is_none_or(|frame| {
                    frame["revision"] != plain["revision"]
                        || frame["exitCode"] != plain["exitCode"]
                        || frame["rowOffset"].as_u64() != Some(self.terminal_row_offset as u64)
                });
                if needs_frame {
                    match read_terminal_frame(&self.engine, &id, self.terminal_row_offset) {
                        Ok(Some(frame)) => {
                            self.terminal_selection.sync(&id, &frame);
                            self.terminal_frame = Some(frame);
                            self.terminal_status.clear();
                            self.terminal_blink_origin = Instant::now();
                            self.terminal_blink_on = true;
                            cx.notify();
                        }
                        Ok(None) => {} // Output changed between pages; retain the last coherent frame.
                        Err(error) => {
                            self.terminal_status = error.to_string();
                            cx.notify();
                        }
                    }
                }
            }
            Err(error) => {
                self.terminal_status = error.to_string();
                cx.notify();
            }
        }
        let blink = (self.terminal_blink_origin.elapsed().as_millis() / 500).is_multiple_of(2);
        if blink != self.terminal_blink_on {
            self.terminal_blink_on = blink;
            if self
                .terminal_frame
                .as_ref()
                .is_some_and(|frame| frame["cursor"]["blinking"] == true)
            {
                cx.notify();
            }
        }
    }
    fn scroll_terminal(
        &mut self,
        expected_id: &str,
        scroll: TerminalScroll,
        cx: &mut Context<Self>,
    ) {
        if self.terminal_id.as_deref() != Some(expected_id) {
            return;
        }
        self.poll_terminal(cx);
        let Some(frame) = &self.terminal_frame else {
            return;
        };
        if frame["viewport"]["alternateScreen"] == true {
            return;
        }
        let Some(revision) = frame["revision"].as_u64() else {
            return;
        };
        let result = call(
            &self.engine,
            "terminal.scroll",
            json!({
                "terminalId":expected_id,"revision":revision,"scroll":scroll
            }),
        );
        self.terminal_selection.clear();
        if let Ok(result) = &result {
            match scroll {
                TerminalScroll::Top => self.terminal_row_offset = 0,
                TerminalScroll::Bottom => {
                    let rows = result["frame"]["rows"].as_u64().unwrap_or(0) as usize;
                    self.terminal_row_offset =
                        rows.saturating_sub(1) / TERMINAL_PAGE_ROWS * TERMINAL_PAGE_ROWS;
                }
                _ => {}
            }
        }
        self.terminal_frame = None;
        self.poll_terminal(cx);
        match result {
            Ok(_) => match scroll {
                TerminalScroll::Bottom => self.terminal_grid_scroll.scroll_to_bottom(),
                TerminalScroll::Top => self.terminal_grid_scroll.set_offset(point(px(0.), px(0.))),
                _ => {}
            },
            Err(error) => self.terminal_status = error.to_string(),
        }
        cx.notify();
    }

    fn terminal_wheel(&mut self, expected_id: &str, event: &ScrollEvent, cx: &mut Context<Self>) {
        if self.terminal_id.as_deref() != Some(expected_id)
            || event.modifiers.control
            || event.modifiers.platform
            || event.modifiers.alt
        {
            return;
        }
        let Some(frame) = &self.terminal_frame else {
            return;
        };
        if frame["viewport"]["alternateScreen"] == true {
            return;
        }
        let delta = event.delta.pixel_delta(px(TERMINAL_CELL_HEIGHT));
        let dy = f32::from(delta.y);
        if !dy.is_finite() || dy == 0. || delta.x.abs() > delta.y.abs() {
            return;
        }
        // First traverse the locally clipped grid. At its edge, continue into
        // PTY history. Shift+vertical-wheel explicitly targets history.
        let offset = self.terminal_grid_scroll.offset().y;
        let max = self.terminal_grid_scroll.max_offset().y;
        let at_edge = if dy > 0. {
            offset >= px(-1.)
        } else {
            offset <= -max + px(1.)
        };
        if !at_edge && !event.modifiers.shift {
            self.terminal_wheel = None;
            return;
        }
        let history = frame["viewport"]["historySize"].as_u64().unwrap_or(0);
        let above = frame["viewport"]["displayOffset"].as_u64().unwrap_or(0);
        if (dy > 0. && above >= history) || (dy < 0. && above == 0) {
            return;
        }
        let remainder = self
            .terminal_wheel
            .get_or_insert_with(|| (expected_id.into(), 0.));
        if remainder.0 != expected_id || remainder.1.signum() != dy.signum() {
            *remainder = (expected_id.into(), 0.);
        }
        remainder.1 += (dy / TERMINAL_CELL_HEIGHT).clamp(-40., 40.);
        let lines = remainder.1.trunc() as i32;
        remainder.1 -= lines as f32;
        cx.stop_propagation();
        if lines != 0 {
            self.scroll_terminal(expected_id, TerminalScroll::Lines(lines), cx);
        }
    }

    fn terminal_pane(&self, window: &Window, cx: &mut Context<Self>) -> AnyElement {
        let mut tabs = div()
            .id("terminal-tabs")
            .flex()
            .gap_1()
            .items_center()
            .overflow_x_scroll()
            .h(px(42.));
        for (index, tab) in self.terminal_tabs.iter().enumerate() {
            let id = text(tab, "terminalId");
            let close = id.clone();
            let active = self.terminal_id.as_deref() == Some(id.as_str());
            let title = text(tab, "title");
            let label = format!(
                "{}{}",
                if active { "● " } else { "" },
                if title.trim().is_empty() {
                    format!("Terminal {}", index + 1)
                } else {
                    title.chars().take(28).collect()
                }
            );
            tabs = tabs.child(
                div()
                    .flex()
                    .flex_shrink_0()
                    .gap_1()
                    .child(
                        Button::new(SharedString::from(format!("terminal-tab-{id}")))
                            .label(label)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.select_terminal(id.clone(), window, cx)
                            })),
                    )
                    .child(
                        Button::new(SharedString::from(format!("terminal-close-{close}")))
                            .label("×")
                            .tooltip("Close this terminal and its shell")
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.close_terminal(&close, window, cx)
                            })),
                    ),
            );
        }
        tabs = tabs
            .child(
                Button::new("terminal-new-tab")
                    .label("New terminal")
                    .on_click(cx.listener(|this, _, window, cx| this.new_terminal(window, cx))),
            )
            .child(
                Button::new("terminal-hide")
                    .label("Hide")
                    .on_click(cx.listener(|this, _, window, cx| this.terminal(window, cx))),
            );
        let mut body = div()
            .id("terminal-grid-scroll")
            .flex_1()
            .min_h_0()
            .overflow_scroll()
            .track_scroll(&self.terminal_grid_scroll)
            .p_2()
            .bg(rgb(0x0c0c0c))
            .track_focus(&self.terminal_focus)
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, window, cx| window.focus(&this.terminal_focus, cx)),
            )
            .on_key_down(cx.listener(|this, event, _, cx| this.terminal_key(event, cx)))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, _, _, _| this.terminal_selection.end_drag()),
            )
            .on_mouse_up_out(
                MouseButton::Left,
                cx.listener(|this, _, _, _| this.terminal_selection.end_drag()),
            )
            .font_family(if cfg!(target_os = "macos") {
                "Menlo"
            } else {
                "monospace"
            })
            .text_size(px(12.))
            .line_height(px(TERMINAL_CELL_HEIGHT));
        let mut footer = div().flex().flex_wrap().gap_2().items_center().text_sm();
        if let Some(frame) = &self.terminal_frame {
            let cols = frame["cols"].as_u64().unwrap_or(0) as usize;
            let offset = frame["rowOffset"].as_u64().unwrap_or(0) as usize;
            let rows = frame["rows"].as_u64().unwrap_or(0) as usize;
            let grid = frame["grid"].as_array();
            let count = grid.map_or(0, Vec::len);
            let focused = self.terminal_focus.is_focused(window);
            let selection_terminal = self.terminal_id.clone().unwrap_or_default();
            let selection_revision = frame["revision"].as_u64().unwrap_or(0);
            if let Some(grid) = grid {
                let scroll_terminal = selection_terminal.clone();
                let mut canvas = div()
                    .flex()
                    .flex_col()
                    .on_scroll(cx.listener(move |this, event: &ScrollEvent, _, cx| {
                        this.terminal_wheel(&scroll_terminal, event, cx);
                    }))
                    .w(px(cols as f32 * TERMINAL_CELL_WIDTH))
                    .flex_shrink_0();
                for (index, cells) in grid.iter().enumerate() {
                    let mut row = div()
                        .relative()
                        .flex()
                        .flex_shrink_0()
                        .h(px(TERMINAL_CELL_HEIGHT))
                        .w_full();
                    if let Some(cells) = cells.as_array() {
                        for (column, cell) in cells.iter().enumerate() {
                            if cell["continuation"] == true
                                && column > 0
                                && cells[column - 1]["width"] == 2
                            {
                                continue;
                            }
                            let width = cell["width"].as_u64().unwrap_or(1).clamp(1, 2) as f32;
                            let selected = self.terminal_selection.is_selected(
                                &selection_terminal,
                                frame,
                                offset + index,
                                column,
                                width as usize,
                            );
                            let down_terminal = selection_terminal.clone();
                            let drag_terminal = selection_terminal.clone();
                            row = row.child(
                                div()
                                    .relative()
                                    .flex_shrink_0()
                                    .w(px(width * TERMINAL_CELL_WIDTH))
                                    .h(px(TERMINAL_CELL_HEIGHT))
                                    .overflow_hidden()
                                    .bg(terminal_rgb(&cell["background"], 0x0c0c0c))
                                    .text_color(terminal_rgb(&cell["foreground"], 0xd4d4d4))
                                    .when(cell["bold"] == true, |view| {
                                        view.font_weight(FontWeight::BOLD)
                                    })
                                    .when(cell["italic"] == true, |view| view.italic())
                                    .when(cell["underline"] == true, |view| view.underline())
                                    .when(cell["strikethrough"] == true, |view| view.line_through())
                                    .child(if cell["hidden"] == true {
                                        " ".repeat(width as usize)
                                    } else {
                                        text(cell, "text")
                                    })
                                    // Tint the complete cell, including foreground;
                                    // replacing only background could reveal ANSI concealed text.
                                    .when(selected, |view| {
                                        view.child(div().absolute().inset_0().bg(rgba(0x648ce670)))
                                    })
                                    .on_mouse_down(
                                        MouseButton::Left,
                                        cx.listener(
                                            move |this, event: &MouseDownEvent, window, cx| {
                                                if this.terminal_id.as_deref()
                                                    != Some(down_terminal.as_str())
                                                {
                                                    return;
                                                }
                                                if let Some(frame) = &this.terminal_frame {
                                                    if frame["revision"].as_u64()
                                                        != Some(selection_revision)
                                                        || frame["rowOffset"].as_u64()
                                                            != Some(offset as u64)
                                                        || frame["cols"].as_u64()
                                                            != Some(cols as u64)
                                                        || frame["grid"].as_array().map(Vec::len)
                                                            != Some(count)
                                                    {
                                                        return;
                                                    }
                                                    this.terminal_selection.begin(
                                                        &down_terminal,
                                                        frame,
                                                        offset + index,
                                                        column,
                                                        event.modifiers.shift,
                                                    );
                                                    window.focus(&this.terminal_focus, cx);
                                                    cx.stop_propagation();
                                                    cx.notify();
                                                }
                                            },
                                        ),
                                    )
                                    .on_mouse_move(cx.listener(
                                        move |this, event: &MouseMoveEvent, _, cx| {
                                            if event.pressed_button != Some(MouseButton::Left)
                                                || this.terminal_id.as_deref()
                                                    != Some(drag_terminal.as_str())
                                            {
                                                return;
                                            }
                                            if let Some(frame) = &this.terminal_frame {
                                                if frame["revision"].as_u64()
                                                    != Some(selection_revision)
                                                    || frame["rowOffset"].as_u64()
                                                        != Some(offset as u64)
                                                    || frame["cols"].as_u64() != Some(cols as u64)
                                                    || frame["grid"].as_array().map(Vec::len)
                                                        != Some(count)
                                                {
                                                    return;
                                                }
                                                if this.terminal_selection.drag(
                                                    &drag_terminal,
                                                    frame,
                                                    offset + index,
                                                    column,
                                                ) {
                                                    cx.notify();
                                                }
                                            }
                                        },
                                    )),
                            );
                        }
                    }
                    let cursor = &frame["cursor"];
                    let show = cursor["visible"] == true
                        && cursor["row"].as_u64() == Some((offset + index) as u64)
                        && (!focused || cursor["blinking"] != true || self.terminal_blink_on);
                    if show {
                        let shape = if focused {
                            cursor["shape"].as_str().unwrap_or("block")
                        } else {
                            "hollowBlock"
                        };
                        let cursor = div()
                            .absolute()
                            .left(px(
                                cursor["col"].as_u64().unwrap_or(0) as f32 * TERMINAL_CELL_WIDTH
                            ))
                            .bottom_0()
                            .w(px(if shape == "beam" {
                                2.
                            } else {
                                TERMINAL_CELL_WIDTH
                            }))
                            .h(px(if shape == "underline" {
                                2.
                            } else {
                                TERMINAL_CELL_HEIGHT
                            }))
                            .when(shape == "hollowBlock", |view| {
                                view.border_1().border_color(rgb(0xb4cbff))
                            })
                            .when(shape != "hollowBlock", |view| {
                                view.bg(rgba(if shape == "block" {
                                    0xb4cbff70
                                } else {
                                    0xb4cbffff
                                }))
                            });
                        row = row.child(cursor);
                    }
                    canvas = canvas.child(row);
                }
                body = body.child(canvas);
            }
            footer = footer.child(div().child(format!(
                    "{} columns · rows {}–{} of {}{}",
                    cols,
                    offset + usize::from(count > 0),
                    offset + count,
                    rows,
                    frame["exitCode"]
                        .as_i64()
                        .map(|code| format!(" · exited {code}"))
                        .unwrap_or_default()
                )));
            footer=footer.child(Button::new("terminal-copy-selection").label("Copy selection")
                .tooltip("Select cells with the mouse or Shift+arrows. Copy: Cmd+C or Ctrl+Shift+C. Select displayed page: Cmd+A or Ctrl+Shift+A.")
                .disabled(!self.terminal_selection.has_selection(&selection_terminal,frame))
                .on_click(cx.listener(|this,_,window,cx|this.copy_terminal_selection(window,cx))));
            let history = frame["viewport"]["historySize"].as_u64().unwrap_or(0);
            let above = frame["viewport"]["displayOffset"].as_u64().unwrap_or(0);
            let alternate = frame["viewport"]["alternateScreen"] == true;
            footer = footer.child(div().text_xs().child(if alternate {
                "Alternate screen".into()
            } else if above == 0 {
                format!("Live · {history} history rows")
            } else {
                format!("{above} rows above live")
            }));
            for (id, label, scroll, disabled, shortcut) in [
                (
                    "terminal-history-up",
                    "History ↑",
                    TerminalScroll::PageUp,
                    alternate || above >= history,
                    "Ctrl+Shift+PageUp",
                ),
                (
                    "terminal-history-down",
                    "History ↓",
                    TerminalScroll::PageDown,
                    alternate || above == 0,
                    "Ctrl+Shift+PageDown",
                ),
                (
                    "terminal-history-top",
                    "Oldest",
                    TerminalScroll::Top,
                    alternate || above >= history,
                    "Ctrl+Shift+Home",
                ),
                (
                    "terminal-history-bottom",
                    "Live",
                    TerminalScroll::Bottom,
                    alternate || above == 0,
                    "Ctrl+Shift+End",
                ),
            ] {
                let terminal = selection_terminal.clone();
                footer = footer.child(
                    Button::new(id)
                        .accessibility_id(id)
                        .label(label)
                        .ghost()
                        .compact()
                        .disabled(disabled)
                        .tooltip(shortcut)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.scroll_terminal(&terminal, scroll, cx)
                        })),
                );
            }
            if rows > TERMINAL_PAGE_ROWS {
                footer = footer
                    .child(
                        Button::new("terminal-page-up")
                            .label("Earlier rows")
                            .disabled(offset == 0)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.terminal_selection.clear();
                                this.terminal_row_offset =
                                    this.terminal_row_offset.saturating_sub(TERMINAL_PAGE_ROWS);
                                this.terminal_frame = None;
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("terminal-page-down")
                            .label("Later rows")
                            .disabled(offset + count >= rows)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.terminal_selection.clear();
                                this.terminal_row_offset += TERMINAL_PAGE_ROWS;
                                this.terminal_frame = None;
                                cx.notify();
                            })),
                    );
            }
            if frame["truncated"] == true {
                footer = footer.child(div().child("Long cell text or title clipped"));
            }
        } else {
            body = body.child("Waiting for terminal output…");
        }
        div()
            .id("terminal-pane")
            .flex()
            .flex_col()
            .h(px(300.))
            .min_h_0()
            .flex_shrink_0()
            .border_t_1()
            .border_color(self.color(0x29303d))
            .child(div().p_2().child(tabs))
            .child(body)
            .child(div().p_2().child(footer))
            .when(!self.terminal_status.is_empty(), |view| {
                view.child(div().px_2().text_sm().child(self.terminal_status.clone()))
            })
            .into_any_element()
    }
    fn terminal_key(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) {
        let key = &event.keystroke;
        if key.modifiers.control
            && key.modifiers.shift
            && !key.modifiers.alt
            && !key.modifiers.platform
            && self
                .terminal_frame
                .as_ref()
                .is_some_and(|frame| frame["viewport"]["alternateScreen"] == false)
        {
            let scroll = match key.key.as_str() {
                "pageup" => Some(TerminalScroll::PageUp),
                "pagedown" => Some(TerminalScroll::PageDown),
                "home" => Some(TerminalScroll::Top),
                "end" => Some(TerminalScroll::Bottom),
                _ => None,
            };
            if let (Some(id), Some(scroll)) = (self.terminal_id.clone(), scroll) {
                self.scroll_terminal(&id, scroll, cx);
                cx.stop_propagation();
                return;
            }
        }
        let Some(id) = self.terminal_id.as_ref() else {
            return;
        };
        if let Some(frame) = &self.terminal_frame {
            match self.terminal_selection.key(id, frame, event, cx) {
                Ok(true) => {
                    cx.stop_propagation();
                    cx.notify();
                    return;
                }
                Err(error) => {
                    self.terminal_status = error.to_string();
                    cx.stop_propagation();
                    cx.notify();
                    return;
                }
                Ok(false) => {}
            }
        } else {
            let key = &event.keystroke;
            if (key.modifiers.platform || (key.modifiers.control && key.modifiers.shift))
                && !key.modifiers.alt
                && matches!(key.key.as_str(), "c" | "C" | "a" | "A")
            {
                self.terminal_status = "Wait for terminal output before selecting text".into();
                cx.stop_propagation();
                cx.notify();
                return;
            }
        }
        let key = &event.keystroke;
        if key.modifiers.platform {
            return;
        }
        let input = if key.modifiers.control && key.key.len() == 1 {
            let b = key.key.as_bytes()[0].to_ascii_uppercase();
            if (b'@'..=b'_').contains(&b) {
                String::from((b - 64) as char)
            } else {
                return;
            }
        } else {
            match key.key.as_str() {
                "enter" => "\r".into(),
                "backspace" => "\x7f".into(),
                "tab" => "\t".into(),
                "escape" => "\x1b".into(),
                "up" => "\x1b[A".into(),
                "down" => "\x1b[B".into(),
                "right" => "\x1b[C".into(),
                "left" => "\x1b[D".into(),
                "pageup" | "pagedown" | "home" | "end" => {
                    // Unmodified navigation belongs to the shell. Preserve
                    // modified keys in alternate-screen applications too.
                    let modifier = 1
                        + u8::from(key.modifiers.shift)
                        + 2 * u8::from(key.modifiers.alt)
                        + 4 * u8::from(key.modifiers.control);
                    match (key.key.as_str(), modifier) {
                        ("home", 1) => "\x1b[H".into(),
                        ("end", 1) => "\x1b[F".into(),
                        ("home", m) => format!("\x1b[1;{m}H"),
                        ("end", m) => format!("\x1b[1;{m}F"),
                        (key, m) => {
                            let code = if key == "pageup" { 5 } else { 6 };
                            if m == 1 {
                                format!("\x1b[{code}~")
                            } else {
                                format!("\x1b[{code};{m}~")
                            }
                        }
                    }
                }
                _ => match &key.key_char {
                    Some(text) => text.clone(),
                    None => return,
                },
            }
        };
        if let Err(e) = call(
            &self.engine,
            "terminal.write",
            json!({"terminalId":id,"text":input}),
        ) {
            self.status = e.to_string();
        }
        self.terminal_blink_origin = Instant::now();
        self.terminal_blink_on = true;
        cx.notify();
        cx.stop_propagation();
    }
    fn copy_terminal_selection(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let (Some(id), Some(frame)) = (&self.terminal_id, &self.terminal_frame) {
            self.terminal_status = match self.terminal_selection.copy(id, frame, cx) {
                Ok(bytes) => format!("Copied {bytes} bytes from the selected visible cells"),
                Err(error) => error.to_string(),
            };
        }
        window.focus(&self.terminal_focus, cx);
        cx.notify();
    }
    fn branch_from_item(
        &mut self,
        source: &str,
        item: &str,
        edit: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .selected
            .as_ref()
            .is_none_or(|thread| thread["id"] != source)
        {
            self.status = "Conversation changed. Select the message again before branching.".into();
            cx.notify();
            return;
        }
        let method = if edit {
            "threads.edit-branch"
        } else {
            "threads.fork"
        };
        match call(
            &self.engine,
            method,
            json!({"threadId":source,"itemId":item}),
        ) {
            Ok(thread) => {
                self.schedules_open = false;
                self.select(&text(&thread, "id"), window, cx);
                self.refresh(cx);
                self.composer.read(cx).focus_handle(cx).focus(window, cx);
                self.status = if edit {
                    "Opened a separate branch with the message restored as a draft. Original conversation and files are unchanged.".into()
                } else {
                    "Opened a separate branch through the settled turn. Original conversation and files are unchanged.".into()
                };
            }
            Err(error) => self.status = format!("Could not create branch: {error}"),
        }
        cx.notify();
    }
    fn fork(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(v) = self.selected.as_ref() {
            match call(&self.engine, "threads.fork", json!({"threadId":v["id"]})) {
                Ok(v) => {
                    self.select(&text(&v, "id"), window, cx);
                    self.refresh(cx);
                }
                Err(e) => self.status = e.to_string(),
            }
        }
    }
}
impl Render for Coincide {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let open = self
            .engine
            .try_lock()
            .ok()
            .and_then(|engine| engine.requested_open.clone());
        if let Some(id) = open {
            self.select(&id, window, cx);
        }
        self.sync_credentials(cx);
        self.sync_notification_activity(window, cx);
        let import_project = self.selected_project.clone();
        self.session_import_panel
            .update(cx, |panel, cx| panel.set_project(import_project, cx));
        self.sync_workspace_context(cx);
        self.sync_model_input(window, cx);
        if let Some(thread) = self.selected.as_mut()
            && let Some(draft) = self.pending_drafts.get(&text(thread, "id"))
        {
            thread["draft"] = json!(draft.text);
        }
        if let Some(v) = self.selected.as_ref() {
            let draft = text(v, "draft");
            if self.composer.read(cx).value().as_ref() != draft {
                self.composer
                    .update(cx, |input, cx| input.set_value(draft, window, cx));
            }
        }
        let selected_id = self
            .selected
            .as_ref()
            .map(|v| text(v, "id"))
            .unwrap_or_default();
        let sidebar = self.navigation_sidebar(&selected_id, cx);
        let title = self
            .selected
            .as_ref()
            .map(|v| text(v, "title"))
            .unwrap_or_else(|| "Welcome to Coincide".into());
        let entity = cx.entity();
        let transcript = list(self.transcript_list.clone(), move |index, window, cx| {
            entity.update(cx, |this, cx| this.message(index, window, cx))
        })
        .flex_1()
        .min_h_0();
        let conversation_content = if self.session_import_open {
            div()
                .id("session-import-surface")
                .flex_1()
                .flex_basis(px(0.))
                .min_h_0()
                .min_w_0()
                .overflow_hidden()
                .child(self.session_import_panel.clone())
                .into_any_element()
        } else if self.settings_open {
            if (self.bots_open || self.transcription_open || self.notifications_open)
                && !self.provider_settings.open
            {
                div()
                    .id("extra-settings-surface")
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(
                        Button::new("extra-settings-back")
                            .label("Back to Settings")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.bots_open = false;
                                this.transcription_open = false;
                                this.notifications_open = false;
                                this.sync_transcription_binding(cx);
                                cx.notify();
                            })),
                    )
                    .child(if self.bots_open {
                        div()
                            .flex_1()
                            .min_h_0()
                            .child(self.bot_panel.clone())
                            .into_any_element()
                    } else if self.notifications_open {
                        div()
                            .id("notification-settings-scroll")
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .child(self.notification_panel.clone())
                            .child(div().p_3().text_sm().child("Foreground conversation visibility is observed. System idle, screen lock, display sleep and remote-device monitoring are not connected."))
                            .into_any_element()
                    } else {
                        div()
                            .id("transcription-settings-scroll")
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .child(self.transcription_panel.clone())
                            .child(self.microphone_panel.clone())
                            .child(div().p_3().text_sm().child("Recording uses the executable, model, language and CPU-thread settings above, with a 60-second limit. Native microphone acceptance is pending; recording controls remain disabled."))
                            .child(div().p_3().text_sm().child(self.status.clone()))
                            .into_any_element()
                    })
                    .into_any_element()
            } else if self.credentials_open {
                div()
                    .id("password-settings-surface")
                    .flex_1()
                    .flex_basis(px(0.))
                    .min_h_0()
                    .min_w_0()
                    .overflow_y_scroll()
                    .child(self.credential_panel.clone())
                    .into_any_element()
            } else if self.provider_settings.open {
                self.antigravity_settings(cx)
            } else {
                self.settings_pane(cx)
            }
        } else if self.schedules_open {
            self.schedules_pane(cx)
        } else if self.workspace_open {
            // The outer column has a finite window height. A zero flex basis
            // keeps the workspace entity bounded and lets its own body scroll.
            div()
                .id("workspace-surface")
                .flex_1()
                .flex_basis(px(0.))
                .min_h_0()
                .min_w_0()
                .overflow_hidden()
                .flex()
                .flex_col()
                .child(
                    div()
                        .p_2()
                        .flex()
                        .gap_2()
                        .child(
                            Button::new("workspace-local-tab")
                                .label("Local Git")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.github_open = false;
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new("workspace-github-tab")
                                .label("GitHub pull requests")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.github_open = true;
                                    this.sync_workspace_context(cx);
                                    cx.notify();
                                })),
                        ),
                )
                .child(if self.github_open {
                    div()
                        .flex_1()
                        .flex_basis(px(0.))
                        .min_h_0()
                        .min_w_0()
                        .overflow_hidden()
                        .child(self.github_panel.clone())
                        .into_any_element()
                } else {
                    div()
                        .flex_1()
                        .flex_basis(px(0.))
                        .min_h_0()
                        .min_w_0()
                        .overflow_hidden()
                        .child(self.workspace_panel.clone())
                        .into_any_element()
                })
                .into_any_element()
        } else {
            transcript.into_any_element()
        };
        let browser_pane = self.browser_pane(cx);
        let pending_pane = if self.workspace_open || self.session_import_open {
            None
        } else {
            self.pending_pane(cx)
        };
        let draft_images = if self.schedules_open
            || self.settings_open
            || self.workspace_open
            || self.session_import_open
        {
            None
        } else {
            self.draft_images(window, cx)
        };
        let show_composer = !self.schedules_open
            && !self.settings_open
            && !self.workspace_open
            && !self.session_import_open;
        let importing_images = self.attachment_import_threads.contains(&selected_id);
        let queue_pane = self.queue_pane(cx);
        div()
            .capture_key_down(
                cx.listener(|this, event, window, cx| this.app_shortcut(event, window, cx)),
            )
            .flex()
            .size_full()
            .bg(self.color(0x10141c))
            .text_color(self.color(0xe4e9f2))
            .child(sidebar)
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .child(
                        div()
                            .flex()
                            .flex_wrap()
                            .flex_shrink_0()
                            .w_full()
                            .overflow_hidden()
                            .items_center()
                            .gap_3()
                            .p_4()
                            .border_b_1()
                            .border_color(self.color(0x29303d))
                            .child(div().w_full().min_w_0().truncate().text_lg().child(title))
                            .child(Button::new("terminal").label("Terminal").on_click(
                                cx.listener(|this, _, window, cx| this.terminal(window, cx)),
                            ))
                            .child(
                                Button::new("browser").label("Browser").on_click(
                                    cx.listener(|this, _, _, cx| this.toggle_browser(cx)),
                                ),
                            )
                            .child(
                                Button::new("session-import-toggle")
                                    .label(if self.session_import_open {
                                        "Close import"
                                    } else {
                                        "Import CLI session"
                                    })
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.session_import_open = !this.session_import_open;
                                        this.sync_transcription_binding(cx);
                                        this.sync_credentials(cx);
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("password-settings-toggle")
                                    .label(if self.settings_open && self.credentials_open {
                                        "Close passwords"
                                    } else {
                                        "Passwords"
                                    })
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.session_import_open = false;
                                        let open = !(this.settings_open && this.credentials_open);
                                        this.credentials_open = open;
                                        this.notifications_open = false;
                                        this.bots_open = false;
                                        this.transcription_open = false;
                                        this.settings_open = open;
                                        this.provider_settings.open = false;
                                        this.workspace_open = false;
                                        this.schedules_open = false;
                                        this.sync_credentials(cx);
                                        this.sync_transcription_binding(cx);
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("git-workspace-toggle")
                                    .label(if self.workspace_open {
                                        "Close Git workspace"
                                    } else {
                                        "Git workspace"
                                    })
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.session_import_open = false;
                                        this.workspace_open = !this.workspace_open;
                                        this.settings_open = false;
                                        this.schedules_open = false;
                                        this.sync_transcription_binding(cx);
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("schedules")
                                    .label(if self.schedules_open {
                                        "Conversation"
                                    } else {
                                        "Schedules"
                                    })
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.settings_open = false;
                                        this.workspace_open = false;
                                        this.session_import_open = false;
                                        this.schedules_open = !this.schedules_open;
                                        this.sync_transcription_binding(cx);
                                        if this.schedules_open {
                                            this.refresh_schedules(cx);
                                        }
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("fork").label("Fork").on_click(
                                    cx.listener(|this, _, window, cx| this.fork(window, cx)),
                                ),
                            )
                            .child(Button::new("pin").label("Pin / unpin").on_click(
                                cx.listener(|this, _, _, cx| this.toggle("isPinned", cx)),
                            ))
                            .child(
                                Button::new("rename-thread")
                                    .label("Rename")
                                    .disabled(self.selected.is_none())
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.begin_rename(window, cx)
                                    })),
                            )
                            .child(
                                Button::new("archive")
                                    .label(
                                        if self
                                            .selected
                                            .as_ref()
                                            .is_some_and(|v| v["isArchived"] == true)
                                        {
                                            "Restore"
                                        } else {
                                            "Archive"
                                        },
                                    )
                                    .disabled(self.selected.is_none())
                                    .on_click(
                                        cx.listener(|this, _, _, cx| this.request_archive(cx)),
                                    ),
                            ),
                    )
                    .when_some(self.thread_management(cx), |view, management| {
                        view.child(management)
                    })
                    .child(conversation_content)
                    .when_some(pending_pane, |view, pane| view.child(pane))
                    .when(
                        self.terminal_id.is_some()
                            && !self.workspace_open
                            && !self.session_import_open,
                        |view| view.child(self.terminal_pane(window, cx)),
                    )
                    .when(show_composer, |view| {
                        view.child(
                            div()
                                .id("composer-column")
                                .w_full()
                                .flex()
                                .items_start()
                                .justify_center()
                                .min_h(px(180.))
                                .overflow_y_scroll()
                                .px(px(presentation::CONTENT_GUTTER))
                                .py_3()
                                .child(
                                    div()
                                        .w_full()
                                        .min_w_0()
                                        .max_w(px(presentation::CONTENT_WIDTH))
                                        .p_3()
                                        .rounded(px(22.))
                                        .bg(self.color(0x181d28))
                                        .border_1()
                                        .border_color(self.color(0x29303d))
                                        .child(
                                            div()
                                                .flex()
                                                .flex_wrap()
                                                .gap_2()
                                                .mb_2()
                                                .child(
                                                    Button::new("provider-codex")
                                                        .label("Codex")
                                                        .on_click(cx.listener(|this, _, _, cx| {
                                                            this.select_provider("codex", cx)
                                                        })),
                                                )
                                                .child(
                                                    Button::new("provider-claude")
                                                        .label("Claude")
                                                        .on_click(cx.listener(|this, _, _, cx| {
                                                            this.select_provider("claude", cx)
                                                        })),
                                                )
                                                .child(
                                                    Button::new("provider-grok")
                                                        .label("Grok")
                                                        .on_click(cx.listener(|this, _, _, cx| {
                                                            this.select_provider("grok", cx)
                                                        })),
                                                )
                                                .child(
                                                    Button::new("provider-cursor")
                                                        .label("Cursor")
                                                        .on_click(cx.listener(|this, _, _, cx| {
                                                            this.select_provider("cursor", cx)
                                                        })),
                                                )
                                                .child(
                                                    Button::new("provider-opencode")
                                                        .label("OpenCode")
                                                        .on_click(cx.listener(|this, _, _, cx| {
                                                            this.select_provider("opencode", cx)
                                                        })),
                                                )
                                                .child(
                                                    Button::new("provider-antigravity-setup")
                                                        .accessibility_id(
                                                            "provider-antigravity-setup",
                                                        )
                                                        .label("Antigravity setup")
                                                        .on_click(cx.listener(
                                                            |this, _, window, cx| {
                                                                this.open_antigravity_settings(
                                                                    window, cx,
                                                                );
                                                                this.sync_transcription_binding(cx);
                                                            },
                                                        )),
                                                )
                                                .child(
                                                    div().text_sm().child(
                                                        self.selected
                                                            .as_ref()
                                                            .map(|v| {
                                                                text(&v["selection"], "provider")
                                                            })
                                                            .unwrap_or_default(),
                                                    ),
                                                ),
                                        )
                                        .child(
                                            div()
                                                .flex()
                                                .gap_2()
                                                .items_center()
                                                .mb_2()
                                                .child(div().text_sm().child("Model ID"))
                                                .child(
                                                    div()
                                                        .flex_1()
                                                        .min_w_0()
                                                        .child(Input::new(&self.model_input)),
                                                )
                                                .child(
                                                    Button::new("apply-model")
                                                        .label("Apply model")
                                                        .disabled(
                                                            self.selected.as_ref().is_none_or(
                                                                |thread| {
                                                                    self.running.contains(&text(
                                                                        thread, "id",
                                                                    ))
                                                                },
                                                            ),
                                                        )
                                                        .on_click(cx.listener(|this, _, _, cx| {
                                                            this.apply_model(cx)
                                                        })),
                                                ),
                                        )
                                        .when_some(queue_pane, |view, queue| view.child(queue))
                                        .when_some(draft_images, |view, images| view.child(images))
                                        .child({
                                            let target = cx.entity().downgrade();
                                            div()
                                                .id("composer-image-drop")
                                                .on_drop(cx.listener(
                                                    |this, paths: &ExternalPaths, _, cx| {
                                                        this.drop_image_paths(paths, cx)
                                                    },
                                                ))
                                                .child(
                                                    Textarea::new(&self.composer)
                                                        .h(px(110.))
                                                        .on_paste(move |item, _, cx| {
                                                            target
                                                                .update(cx, |this, cx| {
                                                                    this.paste_images(item, cx)
                                                                })
                                                                .unwrap_or(false)
                                                        }),
                                                )
                                        })
                                        .child(
                                            div()
                                                .flex()
                                                .flex_wrap()
                                                .gap_2()
                                                .mt_2()
                                                .child(
                                                    Button::new("attach-images")
                                                        .label(if importing_images {
                                                            "Importing images…"
                                                        } else {
                                                            "Attach images"
                                                        })
                                                        .disabled(importing_images)
                                                        .on_click(cx.listener(|this, _, _, cx| {
                                                            this.attach_images(cx)
                                                        })),
                                                )
                                                .child(
                                                    Button::new("send")
                                                        .primary()
                                                        .disabled(importing_images)
                                                        .label(
                                                            if self.running.contains(&selected_id) {
                                                                "Queue message"
                                                            } else {
                                                                "Send"
                                                            },
                                                        )
                                                        .on_click(cx.listener(
                                                            |this, _, window, cx| {
                                                                this.send(window, cx)
                                                            },
                                                        )),
                                                )
                                                .child(Button::new("stop").label("Stop").on_click(
                                                    cx.listener(|this, _, _, cx| {
                                                        if let Some(v) = this.selected.as_ref() {
                                                            if let Err(e) = call(
                                                                &this.engine,
                                                                "agent.stop",
                                                                json!({"threadId":v["id"]}),
                                                            ) {
                                                                this.status = e.to_string();
                                                            }
                                                        }
                                                        cx.notify();
                                                    }),
                                                )),
                                        )
                                        .child(
                                            div()
                                                .mt_2()
                                                .text_sm()
                                                .text_color(self.color(0xe4e9f2).opacity(0.7))
                                                .child(self.status.clone()),
                                        ),
                                ),
                        )
                    }),
            )
            .when_some(browser_pane, |view, pane| view.child(pane))
    }
}
fn schedule_date(value: &Value) -> String {
    if value.is_null() {
        return "None".into();
    }
    coincide_core::scheduling::parse_date(value)
        .map(|date| date.format("%Y-%m-%d %H:%M UTC").to_string())
        .unwrap_or_else(|_| "Unavailable".into())
}
fn main() -> Result<()> {
    let data = control::data_directory()?;
    let engine = Arc::new(Mutex::new(Engine::new(Store::open(
        &data.join("coincide.sqlite"),
    )?)));
    let _server = control::serve(data.join("control.sock"), engine.clone())?;
    #[cfg(target_os = "linux")]
    let application = gpui_kit::platform::linux(WindowingModes::X11);
    #[cfg(not(target_os = "linux"))]
    let application = gpui_kit::application();
    application
        .with_assets(assets::CoincideAssets)
        .run(move |cx| {
            gpui_kit::init(cx);
            transcript::init(cx);
            Theme::change(ThemeMode::Dark, None, cx);
            let bounds = Bounds::centered(None, size(px(1180.), px(820.)), cx);
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    ..Default::default()
                },
                cx,
                |window, cx| {
                    window.set_window_title("Coincide Rust Preview");
                    cx.new(|cx| Coincide::new(engine, data.join("browser-profile"), window, cx))
                },
            )
            .expect("Unable to open Coincide window");
            cx.activate(true);
        });
    Ok(())
}

#[cfg(test)]
mod liveness_tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn native_call_reports_busy_without_dispatching_or_poisoning_engine() {
        struct Fixture(std::path::PathBuf);
        impl Drop for Fixture {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let fixture = Fixture(
            std::env::temp_dir().join(format!("coincide-ui-lock-{}", uuid::Uuid::new_v4())),
        );
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&fixture.0.join("data.sqlite")).unwrap(),
        )));
        let held = engine.lock().unwrap();
        let error = call(&engine, "threads.create", json!({})).unwrap_err();
        assert!(engine_busy(&error));
        drop(held);
        assert!(
            call(&engine, "threads.list", json!({}))
                .unwrap()
                .as_array()
                .unwrap()
                .is_empty()
        );
        let created = call(
            &engine,
            "threads.create",
            json!({"title":"after contention"}),
        )
        .unwrap();
        assert!(created["id"].is_string());
        assert_eq!(
            call(&engine, "threads.list", json!({}))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }
}
