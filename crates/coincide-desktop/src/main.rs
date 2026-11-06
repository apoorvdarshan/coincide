mod codex_limits_mount;
mod codex_limits_view;
mod usage_history_mount;
mod usage_history_view;
mod worker_owner;
use anyhow::Result;
mod app_menu;
mod app_menu_mount;
mod assets;
mod bot_settings;
mod browser;
mod browser_settings;
mod command_palette;
mod composer_attachments;
mod composer_commands;
mod composer_context_mount;
mod composer_context_view;
mod composer_selection;
mod composer_steering;
mod composer_steering_mount;
mod computer_use;
mod computer_use_mount;
mod computer_use_settings;
mod conversation_toolbar;
mod credential_settings;
mod credentials;
mod draft_close;
mod github_actions;
mod github_review;
mod github_threads;
mod github_write_transport;
mod historical_image_view;
mod legacy_media_mount;
mod legacy_media_recovery;
mod legacy_media_settings;
mod microphone;
mod microphone_settings;
mod native_quit;
mod navigation;
mod navigation_rail;
mod navigation_resize;
mod notification_runtime;
mod notification_settings;
mod notifications;
mod presentation;
mod provider_settings;
mod queue;
mod quit_mount;
mod scheduling;
mod session_import;
mod settings;
mod shutdown_runtime;
mod terminal_selection;
mod terminal_workspace;
mod transcript;
mod transcript_find;
mod transcription_composer;
mod transcription_settings;
#[cfg(feature = "preview-updater-helper")]
pub mod updater_helper_transport;
mod updater_lifecycle;
mod updater_settings;
mod workspace;
use browser::BrowserController;
use coincide_core::{
    api::{Engine, SharedEngine},
    attachments::StoredImage,
    browser_protocol::BrowserAction,
    control,
    store::{Store, ThreadSummary, text},
};
use draft_close::PendingDraft;
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

/// Trusted draft persistence only; decide and write under the same try-lock.
fn persist_pending_draft(engine: &SharedEngine, id: &str, text: &str) -> Result<()> {
    let mut engine = try_state(engine)?;
    if engine.admissions_frozen() {
        return engine.persist_frozen_draft(id, text);
    }
    let response = engine.dispatch(json!({
        "method":"threads.patch", "params":{"threadId":id,"patch":{"draft":text}}
    }));
    if let Some(error) = response.get("error") {
        anyhow::bail!("{}", error["message"].as_str().unwrap_or("Command failed"));
    }
    Ok(())
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

#[derive(Clone, Debug, PartialEq, Eq)]
struct FindReveal {
    thread: String,
    item: String,
    generation: u64,
    serial: u64,
}
fn find_sources(thread: &Value) -> Result<Vec<transcript_find::FindItem>> {
    let items = thread["items"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("Conversation items unavailable"))?;
    anyhow::ensure!(
        items.len() <= 2000,
        "Find supports at most 2000 full messages"
    );
    let mut ids = std::collections::HashSet::new();
    let mut size = 0usize;
    let mut sources = Vec::with_capacity(items.len());
    for item in items {
        let id = item["id"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= 512 && !id.contains('\0'))
            .ok_or_else(|| anyhow::anyhow!("Find requires stable message IDs"))?;
        anyhow::ensure!(ids.insert(id), "Find requires unique message IDs");
        let source = item["text"].as_str().unwrap_or("");
        anyhow::ensure!(
            source.len() <= 2 * 1024 * 1024,
            "Find message exceeds 2 MiB"
        );
        size = size.saturating_add(id.len()).saturating_add(source.len());
        anyhow::ensure!(
            size <= 16 * 1024 * 1024,
            "Find full-source snapshot exceeds 16 MiB"
        );
        sources.push(transcript_find::FindItem {
            item_id: id.into(),
            source: source.into(),
        });
    }
    Ok(sources)
}
fn find_source_matches(thread: &Value, sources: &[transcript_find::FindItem]) -> bool {
    thread["items"].as_array().is_some_and(|items| {
        items.len() == sources.len()
            && items.iter().zip(sources).all(|(item, source)| {
                item["id"].as_str() == Some(source.item_id.as_str())
                    && item["text"].as_str().unwrap_or("") == source.source.as_str()
            })
    })
}
fn find_snapshot_current(
    thread: &Value,
    thread_id: &str,
    generation: u64,
    current_generation: u64,
    sources: &[transcript_find::FindItem],
) -> bool {
    thread["id"] == thread_id
        && generation == current_generation
        && find_source_matches(thread, sources)
}
fn transcript_find_shortcut_routes(
    thread: Option<&Value>,
    browser_panels: &std::collections::HashSet<String>,
) -> bool {
    thread
        .and_then(|thread| thread["id"].as_str())
        .is_some_and(|id| !browser_panels.contains(id))
}
fn consume_open_activation(requested: &mut Option<String>, selected: &str) -> bool {
    if requested.as_deref() == Some(selected) {
        *requested = None;
        true
    } else {
        false
    }
}
fn github_threads_method_allowed(method: &str) -> bool {
    matches!(
        method,
        "github.threads.list"
            | "github.threads.comments"
            | "github.threads.result"
            | "github.threads.cancel"
    )
}
fn find_row(thread: &Value, thread_id: &str, item_id: &str) -> Option<usize> {
    if thread["id"] != thread_id {
        return None;
    }
    thread["items"]
        .as_array()?
        .iter()
        .position(|item| item["id"] == item_id)
}
struct Coincide {
    engine: SharedEngine,
    quit_requested: Arc<std::sync::atomic::AtomicBool>,
    control_owner: Arc<Mutex<control::Server>>,
    quit_runtime: Option<shutdown_runtime::Runtime>,
    quit_runtime_error: Option<String>,
    quit_frame_seen: bool,
    native_quit: Option<native_quit::NativeQuit>,
    native_quit_observed: bool,
    quit_issued: bool,
    command_palette: Entity<command_palette::CommandPalette>,
    transcript_find: Entity<transcript_find::TranscriptFind>,
    find_thread: Option<String>,
    find_generation: u64,
    find_items: Vec<transcript_find::FindItem>,
    find_pending: Option<FindReveal>,
    find_revealed: Option<(String, String, u64)>,
    find_last_serial: u64,
    palette_revision: u64,
    palette_entries: Vec<command_palette::PaletteEntry>,
    revision: u64,
    running: Vec<String>,
    pending_requests: Vec<Value>,
    pending_inputs: std::collections::HashMap<(String, String, String), Entity<InputState>>,
    pending_choices: std::collections::HashMap<(String, String, String), Vec<String>>,
    queued_messages: Vec<Value>,
    queue_enabled: bool,
    queue_error: String,
    thread_list_open: bool,
    sidebar_resize: navigation_resize::State,
    thread_list_focus: FocusHandle,
    navigation_focus: FocusHandle,
    settings_open: bool,
    thread_actions_open: bool,
    settings_search: Entity<InputState>,
    settings_section: settings::SettingsSection,
    usage_history: usage_history_mount::Mount,
    codex_limits: codex_limits_mount::Mount,
    steering: composer_steering::SteeringController,
    computer_use_mount: Option<computer_use_mount::Mount>,
    computer_use_open: bool,
    computer_use_status: String,
    media: legacy_media_mount::ParentMedia,
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
    browser_settings_open: bool,
    browser_settings_panel: Entity<browser_settings::BrowserSettings>,
    browser_profile_requests: std::sync::mpsc::Receiver<browser_settings::ProfileRequest>,
    credential_panel: Entity<credential_settings::CredentialSettings>,
    credential_jobs: std::sync::mpsc::Receiver<credentials::FillJob>,
    workspace_open: bool,
    workspace_panel: Entity<workspace::WorkspacePanel>,
    github_open: bool,
    github_panel: Entity<github_review::GitHubReviewPanel>,
    github_threads_panel: Entity<github_threads::GitHubThreadsPanel>,
    github_threads_open: bool,
    github_threads_seed: Option<(String, u64, String)>,
    github_threads_scope_stale: bool,
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
    terminal_open: bool,
    terminal_workspaces:
        std::collections::HashMap<String, Entity<terminal_workspace::TerminalWorkspace>>,
    terminal_visible_thread: Option<String>,
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
    selection_ui: composer_selection::ComposerSelection,
    composer_accessory_scroll: ScrollHandle,
    attachment_import_threads: std::collections::HashSet<String>,
    attachment_root: Option<std::path::PathBuf>,
    image_previews: std::collections::HashMap<String, ImagePreview>,
    image_preview_order: std::collections::VecDeque<String>,
    image_validations_running: usize,
    image_validation_tasks: Vec<Task<()>>,
    navigation_tasks: Vec<Task<()>>,
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
            .update(cx, |panel, cx| panel.set_context(context.clone(), cx));
        let threads_context = if self.workspace_open
            && self.github_threads_open
            && !self.settings_open
            && !self.schedules_open
            && !self.session_import_open
            && !self.command_palette.read(cx).is_open()
            && !self.github_threads_scope_stale
        {
            context
        } else {
            None
        };
        self.github_threads_panel
            .update(cx, |panel, cx| panel.set_context(threads_context, cx));
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
    fn sync_browser_settings_route(&mut self, cx: &mut Context<Self>) {
        let thread = (self.browser_settings_visible() && !self.command_palette.read(cx).is_open())
            .then(|| self.selected.as_ref().map(|thread| text(thread, "id")))
            .flatten();
        self.browser_settings_panel.update(cx, |panel, cx| {
            panel.sync_route_context(thread.as_deref(), cx);
        });
    }
    fn sync_transcription_binding(
        &mut self,
        cx: &mut Context<Self>,
    ) -> Option<transcription_settings::ComposerBinding> {
        self.sync_browser_settings_route(cx);
        let thread = if self.settings_open
            && self.transcription_open
            && !self.bots_open
            && !self.notifications_open
            && !self.session_import_open
            && !self.credentials_open
            && !self.provider_settings.open
            && !self.command_palette.read(cx).is_open()
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
        let engine = self.engine.clone();
        if let Some(error) = draft_close::save_one(&mut self.pending_drafts, id, |id, text| {
            persist_pending_draft(&engine, id, text)
                .map_err(|error| (engine_busy(&error), error.to_string()))
        }) {
            self.status = format!("Draft remains in this window; not yet saved: {error}");
        }
    }
    fn flush_pending_drafts(&mut self) -> bool {
        for id in self.pending_drafts.keys().cloned().collect::<Vec<_>>() {
            self.save_pending_draft(&id);
        }
        self.pending_drafts.is_empty()
    }
    fn preserve_pending_draft(&self, thread: &mut Value) {
        if let Some(draft) = self.pending_drafts.get(&text(thread, "id")) {
            thread["draft"] = json!(draft.text);
        }
    }
    fn new(
        engine: SharedEngine,
        quit_requested: Arc<std::sync::atomic::AtomicBool>,
        control_owner: Arc<Mutex<control::Server>>,
        profile_dir: std::path::PathBuf,
        media_config: coincide_core::legacy_media_service::ServiceConfig,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        #[cfg(target_os = "macos")]
        let native_quit = Some(
            native_quit::install().expect("Install native quit custody before accepting input"),
        );
        #[cfg(not(target_os = "macos"))]
        let native_quit = None;
        let (computer_use_mount, computer_use_status) =
            match computer_use_mount::Mount::new(window, cx) {
                Ok(mount) => (Some(mount), String::new()),
                Err(error) => (None, format!("Computer Use unavailable: {error}")),
            };
        let media = legacy_media_mount::ParentMedia::new(media_config, window, cx);
        let weak = cx.entity().downgrade();
        window.on_window_should_close(cx, move |window, cx| {
            weak.update(cx, |this, cx| {
                // Keep the global drain owner and its recovery controls alive.
                // Closing this window cannot bypass the broader quit fence.
                if this.media.shutdown_requested {
                    cx.notify();
                    return false;
                }
                let drafts_saved = this.flush_pending_drafts();
                let cookies_ready = this.poll_cookie_close(cx);
                this.shutdown_computer_use(cx);
                let media_ready = this.request_media_close(window, cx);
                cx.notify();
                drafts_saved && media_ready && cookies_ready && this.computer_use_shutdown_ready()
            })
            .unwrap_or(false)
        });
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
        let usage_history = usage_history_mount::Mount::new(engine.clone(), cx);
        let codex_limits = codex_limits_mount::Mount::new(engine.clone(), cx);
        let steering = composer_steering::SteeringController::new(engine.clone());
        let settings_search =
            cx.new(|cx| InputState::new(window, cx).placeholder("Search settings"));
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
        let mut browser_profile_requests = None;
        let browser_settings_panel = cx.new(|cx| {
            let (panel, requests) = browser_settings::BrowserSettings::new(window, cx);
            browser_profile_requests = Some(requests);
            panel
        });
        let browser_profile_requests =
            browser_profile_requests.expect("Browser profile requests initialized");
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
        let transcript_find = cx.new(|cx| transcript_find::TranscriptFind::new(window, cx));
        let command_palette = cx.new(|cx| command_palette::CommandPalette::new(window, cx));
        let threads_engine = engine.clone();
        let threads_transport: github_threads::ThreadsTransport =
            Arc::new(move |method, params| {
                anyhow::ensure!(
                    github_threads_method_allowed(method),
                    "Unsupported native inline review method"
                );
                call(&threads_engine, method, params)
            });
        let github_threads_panel =
            cx.new(|cx| github_threads::GitHubThreadsPanel::new(threads_transport, window, cx));
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
            cx.subscribe(&codex_limits.panel, |this, _, _, cx| {
                this.codex_limits.refresh(cx);
            }),
            cx.subscribe(&usage_history.panel, |this, _, event, cx| {
                this.usage_history.load(event, cx);
            }),
            cx.observe(&github_panel, |this,_,cx| {
                let loaded=this.github_panel.read(cx).loaded_pr_scope(cx);
                if this.github_threads_seed.as_ref().is_some_and(|seed|Some(seed)!=loaded.as_ref()) {
                    this.github_threads_seed=None;
                    this.github_threads_scope_stale=true;
                    this.github_threads_panel.update(cx,|panel,cx|panel.set_context(None,cx));
                    cx.notify();
                }
            }),
            cx.subscribe_in(&transcript_find, window, |this, _, event, window, cx| {
                this.find_event(event, window, cx);
            }),
            cx.subscribe(&settings_search, |_, _, event, cx| { if matches!(event,InputEvent::Change) {cx.notify();} }),
            cx.subscribe(&model_input, |this, _, event, cx| {
                if matches!(event, InputEvent::Change) { this.selection_model_changed(cx); }
            }),
            cx.subscribe_in(&command_palette, window, |this, _, event, window, cx| {
                if let command_palette::PaletteEvent::Activated { revision, command } = event {
                    this.activate_palette(*revision, command.clone(), window, cx);
                }
                this.sync_transcription_binding(cx);
                cx.notify();
            }),
            cx.observe_window_activation(window, |this, window, cx| {
                this.microphone_window_active = window.is_window_active() && window.visibility().is_visible();
                this.sync_terminal_workspace(window, cx);
                this.sync_transcription_binding(cx);
                this.sync_notification_activity(window, cx);
            }),
            cx.observe_window_visibility(window, |this, visibility, window, cx| {
                this.microphone_window_active = visibility.is_visible() && window.is_window_active();
                this.sync_terminal_workspace(window, cx);
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
                if this.media.shutdown_requested { return; }
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
                        let completion = cx.spawn_in(window, async move |this, cx| {
                            let result = open.await;
                            let _ = this.update_in(cx, |this, window, cx| {
                                if this.media.shutdown_requested { return; }
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
                        });
                        this.navigation_tasks.push(completion);
                    }
                }
                cx.notify();
            }),
            cx.subscribe_in(
                &session_import_panel,
                window,
                |this, _, event, window, cx| {
                    if this.media.shutdown_requested { return; }
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
                    let completion = cx.spawn_in(window, async move |this, cx| {
                        let result = open.await;
                        let _ = this.update_in(cx, |this, window, cx| {
                            if this.media.shutdown_requested { return; }
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
                    });
                    this.navigation_tasks.push(completion);
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
                if matches!(event, InputEvent::Change)
                    && let Some(v) = this.selected.as_mut()
                {
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
        let sidebar_resize = navigation_resize::State::load(&engine);
        let mut this = Self {
            engine,
            quit_requested,
            control_owner,
            quit_runtime: None,
            quit_runtime_error: None,
            quit_frame_seen: false,
            native_quit,
            native_quit_observed: false,
            quit_issued: false,
            command_palette,
            transcript_find,
            find_thread: None,
            find_generation: 0,
            find_items: Vec::new(),
            find_pending: None,
            find_revealed: None,
            find_last_serial: 0,
            palette_revision: 0,
            palette_entries: Vec::new(),
            revision: 0,
            running: Vec::new(),
            pending_requests: Vec::new(),
            pending_inputs: Default::default(),
            pending_choices: Default::default(),
            queued_messages: Vec::new(),
            queue_enabled: false,
            queue_error: String::new(),
            thread_list_open: true,
            sidebar_resize,
            thread_list_focus: cx.focus_handle(),
            navigation_focus: cx.focus_handle(),
            settings_open: false,
            thread_actions_open: false,
            settings_search,
            settings_section: Default::default(),
            usage_history,
            codex_limits,
            steering,
            computer_use_mount,
            computer_use_open: false,
            computer_use_status,
            media,
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
            browser_settings_open: false,
            browser_settings_panel,
            browser_profile_requests,
            credential_panel,
            credential_jobs,
            workspace_open: false,
            workspace_panel,
            github_open: false,
            github_panel,
            github_threads_panel,
            github_threads_open: false,
            github_threads_seed: None,
            github_threads_scope_stale: false,
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
            terminal_open: false,
            terminal_workspaces: Default::default(),
            terminal_visible_thread: None,
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
            selection_ui: Default::default(),
            composer_accessory_scroll: ScrollHandle::default(),
            attachment_import_threads: Default::default(),
            attachment_root,
            image_previews: Default::default(),
            image_preview_order: Default::default(),
            image_validations_running: 0,
            image_validation_tasks: Vec::new(),
            navigation_tasks: Vec::new(),
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
        this.poll_computer_use(cx);
        this
    }
    fn poll_computer_use(&mut self, cx: &mut Context<Self>) {
        let selected = self.selected.as_ref().map(|thread| text(thread, "id"));
        let ready = if let Ok(mut engine) = self.engine.try_lock() {
            // An explicit pending open is processed by the native view before
            // any old selected-thread request can enter the runtime.
            if engine
                .requested_open
                .as_ref()
                .is_some_and(|requested| Some(requested.as_str()) != selected.as_deref())
            {
                false
            } else if engine.active_thread() == selected.as_deref() {
                true
            } else {
                match engine.set_active_thread(selected) {
                    Ok(()) => true,
                    Err(error) => {
                        let _ = engine.set_active_thread(None);
                        self.computer_use_status =
                            format!("Computer Use selection unavailable: {error}");
                        false
                    }
                }
            }
        } else {
            false
        }; // guard released before Mount/panel/runtime submission
        if ready && let Some(mount) = &mut self.computer_use_mount {
            mount.poll(&self.engine, cx);
            if let Some(error) = mount.last_error() {
                self.computer_use_status = format!("Computer Use request unavailable: {error:?}");
            }
        }
    }
    fn shutdown_computer_use(&mut self, cx: &mut Context<Self>) {
        if let Some(mount) = &mut self.computer_use_mount {
            mount.shutdown(&self.engine);
            mount.poll(&self.engine, cx);
        }
    }
    fn computer_use_shutdown_ready(&mut self) -> bool {
        self.computer_use_mount
            .as_mut()
            .is_none_or(|mount| mount.shutdown_status().ready())
    }
    fn computer_use_settings_visible(&self) -> bool {
        self.settings_open
            && self.computer_use_open
            && !self.bots_open
            && !self.transcription_open
            && !self.notifications_open
            && !self.credentials_open
            && !self.browser_settings_open
            && !self.media.opened
            && !self.provider_settings.open
            && !self.session_import_open
    }
    fn computer_use_settings_pane(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut pane = div()
            .id("computer-use-settings-surface")
            .flex_1()
            .min_h_0()
            .min_w_0()
            .flex()
            .flex_col()
            .child(
                Button::new("computer-use-settings-back")
                    .label("Back to Settings")
                    .disabled(self.media.close_requested || self.media.shutdown_requested)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.computer_use_open = false;
                        cx.notify();
                    })),
            )
            .child(
                div()
                    .p_2()
                    .text_sm()
                    .child(self.computer_use_status.clone()),
            );
        if let Some(mount) = &self.computer_use_mount {
            pane = pane.child(
                div()
                    .id("computer-use-settings-scroll")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .child(mount.panel()),
            );
        }
        pane.into_any_element()
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
        let image_viewer_open = self.historical_image_is_open();
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
            .filter(|thread| self.browser_panels.contains(*thread) && !image_viewer_open);
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
        if self.historical_image_is_open() {
            return None;
        }
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
        self.dismiss_palette(window, cx);
        self.dismiss_find(window, cx);
        self.credential_panel
            .update(cx, |panel, cx| panel.cancel(cx));
        match call(&self.engine, "threads.read", json!({"threadId":id})) {
            Ok(mut v) => {
                if self
                    .selected
                    .as_ref()
                    .is_none_or(|thread| thread["id"] != id)
                {
                    self.thread_actions_open = false;
                }
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
                    self.composer_accessory_scroll
                        .set_offset(point(px(0.), px(0.)));
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
                let activate_requested = if let Ok(mut engine) = self.engine.try_lock() {
                    if engine.active_thread() != Some(id)
                        && let Err(error) = engine.set_active_thread(Some(id.into()))
                    {
                        let _ = engine.set_active_thread(None);
                        self.status =
                            format!("Selected conversation authority unavailable: {error}");
                    }
                    consume_open_activation(&mut engine.requested_open, id)
                } else {
                    false
                };
                if activate_requested {
                    // Explicit threads.open, consumed once after a successful
                    // load. Polls and ordinary selection never steal focus.
                    cx.activate(true);
                    window.activate_window();
                }
                self.terminal_open = false;
                self.sync_terminal_workspace(window, cx);
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
    fn find_context_available(&self) -> bool {
        self.selected.is_some()
            && !self.settings_open
            && !self.schedules_open
            && !self.workspace_open
            && !self.session_import_open
    }
    fn clear_find_reveal(&mut self, cx: &mut Context<Self>) {
        if let Some((thread, item, _)) = self.find_revealed.take()
            && let Some(index) = self
                .selected
                .as_ref()
                .and_then(|selected| find_row(selected, &thread, &item))
        {
            self.transcript_list.splice(index..index + 1, 1);
        }
        self.find_pending = None;
        cx.notify();
    }
    fn dismiss_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.transcript_find
            .update(cx, |find, cx| find.dismiss(window, cx));
        self.clear_find_reveal(cx);
    }
    fn open_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.find_context_available() {
            self.status = "Open a conversation to find text.".into();
            cx.notify();
            return;
        }
        let result = (|| -> Result<transcript_find::FindSnapshot> {
            let thread = self.selected.as_ref().unwrap();
            let items = find_sources(thread)?;
            let generation = self
                .find_generation
                .checked_add(1)
                .ok_or_else(|| anyhow::anyhow!("Find generation exhausted"))?;
            Ok(transcript_find::FindSnapshot {
                thread_id: text(thread, "id"),
                generation,
                items,
            })
        })();
        match result {
            Ok(snapshot) => {
                self.clear_find_reveal(cx);
                self.find_thread = Some(snapshot.thread_id.clone());
                self.find_generation = snapshot.generation;
                self.find_items = snapshot.items.clone();
                if let Err(error) = self
                    .transcript_find
                    .update(cx, |find, cx| find.open(snapshot, window, cx))
                {
                    self.status = format!("Find unavailable: {error}");
                    self.dismiss_find(window, cx);
                }
            }
            Err(error) => {
                self.status = format!("Find unavailable: {error}");
                self.dismiss_find(window, cx);
            }
        }
        cx.notify();
    }
    fn sync_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.transcript_find.read(cx).is_open() {
            return;
        }
        let selected = self.selected.as_ref();
        if !self.find_context_available()
            || selected.map(|thread| text(thread, "id")) != self.find_thread
        {
            self.dismiss_find(window, cx);
            if !self.find_context_available() {
                window.blur(cx);
            }
            return;
        }
        if find_source_matches(selected.unwrap(), &self.find_items) {
            return;
        }
        match find_sources(selected.unwrap()) {
            Ok(items) if items == self.find_items => {}
            Ok(items) => {
                let Some(generation) = self.find_generation.checked_add(1) else {
                    self.dismiss_find(window, cx);
                    return;
                };
                self.find_pending = None;
                if let Some((_, item, old_generation)) = &mut self.find_revealed {
                    if items.iter().any(|entry| &entry.item_id == item) {
                        *old_generation = generation;
                    } else {
                        self.find_revealed = None;
                    }
                }
                self.find_generation = generation;
                self.find_items = items.clone();
                let snapshot = transcript_find::FindSnapshot {
                    thread_id: self.find_thread.clone().unwrap(),
                    generation,
                    items,
                };
                if let Err(error) = self
                    .transcript_find
                    .update(cx, |find, cx| find.replace_snapshot(snapshot, cx))
                {
                    self.status = format!("Find stopped: {error}");
                    self.dismiss_find(window, cx);
                }
            }
            Err(error) => {
                self.status = format!("Find stopped: {error}");
                self.dismiss_find(window, cx);
            }
        }
    }
    fn find_event(
        &mut self,
        event: &transcript_find::FindEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        use transcript_find::FindEvent as E;
        match event {
            E::Dismissed => {
                if !self.transcript_find.read(cx).is_open() {
                    self.clear_find_reveal(cx);
                }
            }
            E::Cleared {
                thread_id,
                generation,
                match_serial,
            } => {
                if self.find_thread.as_deref() == Some(thread_id.as_str())
                    && *generation == self.find_generation
                    && *match_serial >= self.find_last_serial
                {
                    self.find_last_serial = *match_serial;
                    self.clear_find_reveal(cx);
                }
            }
            E::Reveal {
                thread_id,
                item_id,
                generation,
                match_serial,
                range,
            } => {
                if !self.find_context_available()
                    || !self.transcript_find.read(cx).is_open()
                    || self.find_thread.as_deref() != Some(thread_id.as_str())
                    || *generation != self.find_generation
                {
                    return;
                }
                let Some(thread) = self.selected.as_ref() else {
                    return;
                };
                let Some(index) = find_row(thread, thread_id, item_id) else {
                    return;
                };
                if !find_snapshot_current(
                    thread,
                    thread_id,
                    *generation,
                    self.find_generation,
                    &self.find_items,
                ) {
                    self.sync_find(window, cx);
                    return;
                }
                let find = self.transcript_find.read(cx);
                let Some(projection) = find.projection_for(thread_id, item_id, *generation) else {
                    return;
                };
                let Some(state) = find.state_for(thread_id, item_id, *generation) else {
                    return;
                };
                let rendered = state.read(cx).rendered_text();
                let text = rendered.as_str();
                if projection.match_serial != *match_serial
                    || range.start >= range.end
                    || range.end > text.len()
                    || !text.is_char_boundary(range.start)
                    || !text.is_char_boundary(range.end)
                {
                    return;
                }
                self.clear_find_reveal(cx);
                self.find_last_serial = *match_serial;
                self.find_revealed = Some((thread_id.clone(), item_id.clone(), *generation));
                self.find_pending = Some(FindReveal {
                    thread: thread_id.clone(),
                    item: item_id.clone(),
                    generation: *generation,
                    serial: *match_serial,
                });
                self.transcript_list.splice(index..index + 1, 1);
                // The expanded/previously hidden row is now unmeasured.
                // Pixel-based reveal uses its zero height and can anchor the
                // preceding row; direct item anchoring mounts the exact target
                // and stops tail-following before the native line reveal.
                self.transcript_list.scroll_to(ListOffset {
                    item_ix: index,
                    offset_in_item: px(0.),
                });
                cx.notify();
            }
        }
    }
    fn find_body(
        &mut self,
        thread: &str,
        item: &str,
        source: String,
        full: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> TextView {
        if full && self.find_context_available() && self.transcript_find.read(cx).is_open() {
            let find = self.transcript_find.read(cx);
            if let Some(state) = find.state_for(thread, item, self.find_generation) {
                if let Some(projection) = find.projection_for(thread, item, self.find_generation) {
                    let pending = FindReveal {
                        thread: thread.into(),
                        item: item.into(),
                        generation: self.find_generation,
                        serial: projection.match_serial,
                    };
                    if self.find_pending.as_ref() == Some(&pending) {
                        match transcript::apply_find_projection(&state, &projection, cx) {
                            Ok(true) => {
                                if self.transcript_find.update(cx, |find, _| {
                                    find.acknowledge_reveal(projection.match_serial)
                                }) {
                                    self.find_pending = None;
                                }
                            }
                            Ok(false) => {}
                            Err(error) => {
                                self.status = format!("Find reveal failed: {error}");
                                self.find_pending = None;
                            }
                        }
                    }
                }
                return transcript::managed_markdown(thread, item, &state, window, cx);
            }
        }
        transcript::markdown(thread, item, source, window, cx)
    }
    fn palette_catalog(&self) -> Vec<command_palette::PaletteEntry> {
        use command_palette::{PaletteCommand as C, PaletteEntry as E};
        let entry = |command, title, subtitle| E {
            command,
            title,
            subtitle,
            keywords: Vec::new(),
            enabled: true,
            disabled_reason: None,
        };
        let mut entries = vec![
            entry(
                C::NewThread { project_id: None },
                "New projectless conversation".into(),
                None,
            ),
            entry(C::OpenSettings, "Open settings".into(), None),
            entry(C::ShowSchedules, "Show schedules".into(), None),
            entry(
                C::SelectProject { project_id: None },
                "All projects".into(),
                None,
            ),
        ];
        for project in &self.projects {
            let id = text(project, "id");
            if id.is_empty() {
                continue;
            }
            let name = text(project, "name");
            entries.push(entry(
                C::SelectProject {
                    project_id: Some(id.clone()),
                },
                format!("Show project: {name}"),
                None,
            ));
            if !id.eq_ignore_ascii_case(coincide_core::bot_runtime::BOTS_PROJECT_ID) {
                entries.push(entry(
                    C::NewThread {
                        project_id: Some(id),
                    },
                    format!("New conversation in {name}"),
                    None,
                ));
            }
        }
        for thread in &self.threads {
            entries.push(entry(
                C::OpenThread {
                    thread_id: thread.id.clone(),
                },
                thread.title.clone(),
                Some("Conversation".into()),
            ));
        }
        entries
    }
    fn dismiss_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.command_palette
            .update(cx, |palette, cx| palette.dismiss(window, cx));
    }
    fn toggle_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.command_palette.read(cx).is_open() {
            self.dismiss_palette(window, cx);
        } else {
            self.dismiss_find(window, cx);
            self.credential_panel
                .update(cx, |panel, cx| panel.cancel(cx));
            self.palette_revision = self.palette_revision.saturating_add(1);
            self.palette_entries = self.palette_catalog();
            let snapshot = command_palette::PaletteSnapshot {
                revision: self.palette_revision,
                entries: self.palette_entries.clone(),
            };
            if let Err(error) = self
                .command_palette
                .update(cx, |palette, cx| palette.open(snapshot, window, cx))
            {
                self.status = format!("Palette unavailable: {error}");
            }
        }
        self.sync_transcription_binding(cx);
        cx.notify();
    }
    fn sync_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.command_palette.read(cx).is_open() {
            return;
        }
        if !window.is_window_active() || !window.visibility().is_visible() {
            self.dismiss_palette(window, cx);
            return;
        }
        let entries = self.palette_catalog();
        if !palette_entries_equal(&entries, &self.palette_entries) {
            self.palette_revision = self.palette_revision.saturating_add(1);
            let snapshot = command_palette::PaletteSnapshot {
                revision: self.palette_revision,
                entries: entries.clone(),
            };
            if self
                .command_palette
                .update(cx, |palette, cx| palette.replace_snapshot(snapshot, cx))
                .is_ok()
            {
                self.palette_entries = entries;
            } else {
                self.dismiss_palette(window, cx);
            }
        }
    }
    fn activate_palette(
        &mut self,
        revision: u64,
        command: command_palette::PaletteCommand,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        use command_palette::PaletteCommand as C;
        let current = self.palette_catalog();
        if revision != self.palette_revision
            || !palette_entries_equal(&current, &self.palette_entries)
            || !current
                .iter()
                .any(|entry| entry.enabled && entry.command == command)
        {
            self.status = "Palette context changed; reopen it to choose again".into();
            return;
        }
        match command {
            C::OpenThread { thread_id } => self.select(&thread_id, window, cx),
            C::SelectProject { project_id } => self.selected_project = project_id,
            C::NewThread { project_id } => self.new_thread_in_project(
                project_id
                    .as_deref()
                    .unwrap_or("00000000-0000-0000-0000-000000000000"),
                window,
                cx,
            ),
            C::OpenSettings => self.open_settings_panel(window, cx),
            C::ShowSchedules => {
                self.settings_open = false;
                self.workspace_open = false;
                self.session_import_open = false;
                self.schedules_open = true;
                self.refresh_schedules(cx);
            }
        }
        self.sync_transcription_binding(cx);
        cx.notify();
    }
    fn new_thread(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let project = self
            .selected_project
            .clone()
            .or_else(|| self.selected.as_ref().map(|v| text(v, "projectID")))
            .unwrap_or_else(|| "00000000-0000-0000-0000-000000000000".into());
        self.new_thread_in_project(&project, window, cx);
    }
    fn new_thread_in_project(
        &mut self,
        project: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
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
            .find(|p| p["id"].as_str() == Some(project))
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
    fn browser_settings_visible(&self) -> bool {
        self.settings_open
            && self.browser_settings_open
            && !self.computer_use_settings_visible()
            && !self.media_settings_visible()
            && !self.credentials_open
            && !self.bots_open
            && !self.transcription_open
            && !self.notifications_open
            && !self.provider_settings.open
            && !self.session_import_open
    }
    fn cookie_settings_thread(&self, cx: &Context<Self>) -> Option<String> {
        (!self.media.shutdown_requested
            && !self.media.close_requested
            && self.browser_settings_visible()
            && !self.command_palette.read(cx).is_open())
        .then(|| self.selected.as_ref().map(|thread| text(thread, "id")))
        .flatten()
    }
    fn sync_browser_settings(&mut self, cx: &mut Context<Self>) {
        self.sync_browser_settings_route(cx);
        let visible = self.browser_settings_visible() && !self.command_palette.read(cx).is_open();
        let selected_thread = self.selected.as_ref().map(|thread| text(thread, "id"));
        for request in self.browser_profile_requests.try_iter().take(8) {
            let result = if visible {
                selected_thread
                    .as_deref()
                    .ok_or_else(|| "No selected thread".to_owned())
                    .and_then(|thread| {
                        self.browser
                            .as_mut()
                            .ok_or_else(|| "Browser unavailable".to_owned())
                            .and_then(|browser| {
                                browser
                                    .apply_profile_request(thread, request)
                                    .map_err(|error| error.to_string())
                            })
                    })
            } else {
                Err("Browser settings closed; profile request cancelled".into())
            };
            self.browser_settings_panel
                .update(cx, |panel, cx| panel.set_result(result, cx));
        }
        let snapshot = if visible {
            selected_thread.as_deref().and_then(|thread| {
                self.browser
                    .as_ref()
                    .map(|browser| browser.profile_snapshot(thread))
            })
        } else {
            None
        };
        let engine = self.engine.clone();
        let (bookmark, reservation, prepared) =
            self.browser_settings_panel.update(cx, |panel, cx| {
                // Idempotent injection: only the first binding initializes context.
                panel.set_library_engine(engine);
                panel.set_snapshot(snapshot, cx);
                panel.poll(cx);
                (
                    panel.take_bookmark_open(),
                    panel.take_cookie_reservation_request(),
                    panel.take_prepared_cookie_import(),
                )
            });
        if let Some(request) = reservation {
            let result = self
                .cookie_settings_thread(cx)
                .filter(|thread| thread == &request.context.snapshot.thread)
                .ok_or_else(|| {
                    "Cookie settings closed or selected conversation changed.".to_owned()
                })
                .and_then(|thread| {
                    self.browser
                        .as_ref()
                        .ok_or_else(|| "Browser unavailable.".to_owned())
                        .and_then(|browser| browser.reserve_cookie_import(&thread, request))
                });
            self.browser_settings_panel
                .update(cx, |panel, cx| panel.cookie_reservation_result(result, cx));
        }
        if let Some(prepared) = prepared {
            let result = self
                .cookie_settings_thread(cx)
                .filter(|thread| thread == &prepared.reservation.context.snapshot.thread)
                .ok_or_else(|| {
                    "Cookie settings closed or selected conversation changed.".to_owned()
                })
                .and_then(|thread| {
                    self.browser
                        .as_mut()
                        .ok_or_else(|| "Browser unavailable.".to_owned())
                        .and_then(|browser| browser.admit_cookie_import(&thread, prepared))
                });
            self.browser_settings_panel
                .update(cx, |panel, cx| match result {
                    Ok(status) => panel.set_cookie_import_status(status, cx),
                    Err(error) => panel.set_cookie_import_error(error, cx),
                });
            // Admission may have created exactly its reserved destination. Feed
            // its status first, then reconcile a fresh ordinary snapshot.
            let snapshot = self.cookie_settings_thread(cx).and_then(|thread| {
                self.browser
                    .as_ref()
                    .map(|browser| browser.profile_snapshot(&thread))
            });
            self.browser_settings_panel
                .update(cx, |panel, cx| panel.set_snapshot(snapshot, cx));
        }
        if let Some(bookmark) = bookmark
            && visible
            && selected_thread.as_deref() == Some(bookmark.thread.as_str())
        {
            // Preparation read the saved library off UI. Admission is memory-only
            // and runs after this native visibility/selection check, before queueing.
            let admitted = self
                .engine
                .try_lock()
                .map_err(|_| "The app is busy; click Open again.".to_owned())
                .and_then(|mut engine| {
                    engine
                        .admit_prepared_bookmark(bookmark.prepared)
                        .map_err(|error| error.to_string())
                });
            match admitted {
                Ok(queued) => {
                    // Results may already be retained on the next poll_browser;
                    // these IDs collect completion, not browser authorization.
                    self.browser_ui_operations
                        .insert(queued.navigate_operation, queued.thread.clone());
                    self.browser_ui_operations
                        .insert(queued.show_operation, queued.thread);
                    self.browser_settings_open = false;
                    self.settings_open = false;
                    self.sync_browser_settings_route(cx);
                    cx.notify();
                }
                Err(error) => self
                    .browser_settings_panel
                    .update(cx, |panel, cx| panel.set_bookmark_open_error(error, cx)),
            }
        }
    }
    fn sync_credentials(&mut self, cx: &mut Context<Self>) {
        // Provider setup is another native settings workflow, never a reason
        // to keep password approval active behind that panel.
        if self.provider_settings.open {
            self.credentials_open = false;
        }
        let visible = self.settings_open
            && (self.credentials_open || self.browser_settings_visible())
            && !self.session_import_open
            && !self.bots_open
            && !self.notifications_open
            && !self.transcription_open
            && !self.provider_settings.open
            && !self.command_palette.read(cx).is_open();
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
            panel.set_context(
                visible.then(|| thread.clone()).flatten(),
                page,
                available,
                cx,
            );
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
        if self
            .quit_requested
            .swap(false, std::sync::atomic::Ordering::AcqRel)
        {
            self.media.shutdown_requested = true;
        }
        self.image_validation_tasks.retain(|task| !task.is_ready());
        self.navigation_tasks.retain(|task| !task.is_ready());
        if self
            .native_quit
            .as_ref()
            .is_some_and(|guard| guard.take_requested())
        {
            self.native_quit_observed = true;
            self.media.shutdown_requested = true;
        }
        // Persistence must precede either close path, including API app.quit.
        let drafts_saved = self.flush_pending_drafts();
        self.sync_media_context(cx);
        self.poll_media_parent(cx);
        if self.engine.try_lock().is_ok_and(|engine| engine.shutdown) {
            self.media.shutdown_requested = true;
        }
        if self.media.shutdown_requested {
            if self.poll_global_quit(window, cx) {
                self.finish_normal_quit(cx);
            }
            cx.notify();
            return;
        }
        // Global Quit progresses the stopped actor through poll_shutdown above.
        // A window-close wait closes cookie admission before polling receipts.
        let cookies_ready = if self.media.close_requested {
            self.poll_cookie_close(cx)
        } else {
            self.sync_browser_settings_route(cx);
            if let Some(status) = self
                .browser
                .as_mut()
                .and_then(|browser| browser.poll_cookie_import())
            {
                self.browser_settings_panel
                    .update(cx, |panel, cx| panel.set_cookie_import_status(status, cx));
            }
            true
        };
        if self.media.close_requested {
            self.shutdown_computer_use(cx);
            self.sync_media_context(cx);
            if drafts_saved
                && cookies_ready
                && self.media_shutdown_ready(cx)
                && self.computer_use_shutdown_ready()
            {
                window.remove_window();
            } else if !drafts_saved {
                self.status =
                    "Closing is waiting for drafts to save. Failed saves require Retry save."
                        .into();
                cx.notify();
            } else if !cookies_ready
                && self.media_shutdown_ready(cx)
                && self.computer_use_shutdown_ready()
            {
                self.status =
                    "Closing waits for owned cookie work and private snapshot cleanup.".into();
                cx.notify();
            } else if !self.media_shutdown_ready(cx) {
                self.computer_use_open = false;
                self.show_media_shutdown(window, cx);
            } else {
                self.settings_open = true;
                self.computer_use_open = true;
                self.media.opened = false;
                self.browser_settings_open = false;
                self.credentials_open = false;
                self.bots_open = false;
                self.notifications_open = false;
                self.transcription_open = false;
                self.provider_settings.open = false;
                self.session_import_open = false;
                self.sync_browser_settings_route(cx);
                self.computer_use_status="Closing is waiting for Computer Use shutdown accounting. No native actions are retried.".into();
                cx.notify();
            }
            return;
        }
        self.poll_app_menu(window, cx);
        self.poll_computer_use(cx);
        self.sync_composer_selection(window, cx);
        self.poll_selection_catalog(cx);
        self.sync_palette(window, cx);
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
                self.media.shutdown_requested = true;
                return;
            }
            engine.ui_available = self.browser.is_some();
            let selected = self.selected.as_ref().map(|thread| text(thread, "id"));
            if engine.active_thread() != selected.as_deref()
                && let Err(error) = engine.set_active_thread(selected)
            {
                let _ = engine.set_active_thread(None);
                self.status = format!("Selected conversation authority unavailable: {error}");
            }
            if self.attachment_root.is_none() {
                self.attachment_root = engine.store.data_directory().ok();
            }
        }
        self.refresh_awake_status(cx);
        self.apply_appearance(window, cx);
        if self.navigation_last_clock.elapsed() >= Duration::from_secs(30) {
            self.navigation_last_clock = Instant::now();
            cx.notify();
        }
        self.usage_history.poll(cx);
        self.codex_limits.poll(cx);
        if let Some(thread) = &self.selected {
            self.steering
                .observe_draft(&text(thread, "id"), self.composer.read(cx).value().as_ref());
        }
        if self.steering.poll() {
            cx.notify();
        }
        self.poll_browser(window, cx);
        self.sync_browser_settings(cx);
        self.sync_github_context(cx);
        self.sync_credentials(cx);
        self.sync_terminal_workspace(window, cx);
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
        self.sync_media_context(cx);
        self.sync_find(window, cx);
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
            let actions = if request["method"] == "item/tool/requestUserInput" {
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
                div().flex_shrink_0().child(
                    Button::new(SharedString::from(format!("submit-{request_id}")))
                        .label("Submit answers")
                        .on_click(cx.listener(move |this, _, _, cx| this.answer_pending(&id, cx))),
                )
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
                div().flex_shrink_0().child(buttons)
            };
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
                if let Some(index) = row
                    && let Some(thread) = self.selected.as_ref().map(|thread| text(thread, "id"))
                {
                    self.image_waiting_rows.insert((thread, index));
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
            let completion = cx.spawn(async move |this, cx| {
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
            });
            self.image_validation_tasks.push(completion);
        }
        self.image_preview_order.retain(|previous| previous != &key);
        self.image_preview_order.push_back(key.clone());
        let entry = self
            .image_previews
            .get_mut(&key)
            .expect("preview was inserted");
        if let Some(index) = row
            && let Some(thread) = self.selected.as_ref().map(|thread| text(thread, "id"))
        {
            let target = (thread, index);
            if !entry.rows.contains(&target) {
                entry.rows.push(target);
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
        if let Some(thread) = &self.selected {
            let draft = self.composer.read(cx).value().to_string();
            if let Some(command) = composer_commands::intercept(thread, &draft, |command| command) {
                let submission = composer_commands::Submission::new(thread, &draft);
                self.perform_composer_command(command, submission, window, cx);
                return;
            }
            let context = thread.get("draftContext").unwrap_or(&Value::Null);
            if let Err(error) = coincide_core::composer_context::validate(context) {
                self.status = format!("Attached references were retained: {error}");
                cx.notify();
                return;
            }
            if self.running.contains(&text(thread, "id"))
                && coincide_core::composer_context::has_context(context)
            {
                self.status = "Queued messages do not yet support references. Send after the current turn finishes, or remove the references explicitly.".into();
                cx.notify();
                return;
            }
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
                        thread.as_object_mut().unwrap().remove("draftContext");
                    }
                    self.composer
                        .update(cx, |input, cx| input.set_value("", window, cx));
                }
                Err(e) => self.status = e.to_string(),
            }
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
        let find_revealed =
            self.find_revealed
                .as_ref()
                .is_some_and(|(thread, item, generation)| {
                    thread == &source_id && item == &item_id && *generation == self.find_generation
                });
        if kind == "reasoning"
            && !find_revealed
            && !self.settings["showReasoning"].as_bool().unwrap_or(true)
        {
            return div().into_any_element();
        }
        let body = text(item, "text");
        let copy_empty = body.is_empty();
        let collapsible = kind != "user" && kind != "assistant";
        let expanded = self.expanded.contains(&index) || find_revealed;
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
        let work_header = presentation::work_header(item);
        let work_status = work_header.as_ref().and_then(|header| header.status);
        let label = match kind.as_str() {
            "user" => "You".to_owned(),
            "assistant" => presentation::provider_name(&provider).to_owned(),
            "reasoning" | "tool" => work_header
                .as_ref()
                .map(|header| header.title.clone())
                .unwrap_or_default(),
            "error" => "Error".to_owned(),
            "system" => "Conversation update".to_owned(),
            _ => kind.clone(),
        };
        let action_excerpt: String = text(item, "text").chars().take(72).collect();
        // Only Rust-ingested metadata is previewable. Legacy imported media is
        // deliberately not opened through arbitrary historical paths.
        let images = item["rustImages"].as_array().cloned().unwrap_or_default();
        let context_pane = self.transcript_context_pane(&item["context"]);
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
        let native_body = self.find_body(
            &source_id,
            &item_id,
            shown,
            !collapsible || expanded,
            window,
            cx,
        );
        let copy_action = {
            let source = source_id.clone();
            let item = item_id.clone();
            Button::new(SharedString::from(format!(
                "copy-message-{source_id}-{item_id}"
            )))
            .accessibility_id(SharedString::from(format!(
                "copy-message-{source_id}-{item_id}"
            )))
            .accessibility_label("Copy message")
            .when(kind == "user", |button| {
                button.icon(gpui_kit::assets::IconName::Copy)
            })
            .when(kind != "user", |button| button.label("Copy message"))
            .ghost()
            .compact()
            .when(kind == "assistant" || kind == "user", |button| {
                button.xsmall()
            })
            .disabled(copy_empty)
            .tooltip("Copy the complete message text, including collapsed content")
            .on_click(cx.listener(move |this, _, _, cx| this.copy_message(&source, &item, cx)))
        };
        let (metadata_copy, user_copy) = if kind == "user" {
            (None, Some(copy_action))
        } else {
            (Some(copy_action), None)
        };
        let disclosure = collapsible.then(|| {
            let source = source_id.clone();
            let item = item_id.clone();
            Button::new(SharedString::from(format!("expand-{source_id}-{item_id}")))
                .accessibility_id(SharedString::from(format!("expand-{source_id}-{item_id}")))
                .label(if expanded { "Collapse" } else { "Expand" })
                .ghost()
                .compact()
                .on_click(cx.listener(move |this, _, _, cx| {
                    let Some(thread) = this.selected.as_ref().filter(|v| v["id"] == source) else {
                        return;
                    };
                    let Some(index) = thread["items"]
                        .as_array()
                        .and_then(|items| items.iter().position(|v| v["id"] == item))
                    else {
                        return;
                    };
                    if this
                        .find_revealed
                        .as_ref()
                        .is_some_and(|(thread, id, _)| thread == &source && id == &item)
                    {
                        this.find_revealed = None;
                        this.find_pending = None;
                        this.expanded.remove(&index);
                    } else if !this.expanded.remove(&index) {
                        this.expanded.insert(index);
                    }
                    this.transcript_list.splice(index..index + 1, 1);
                    cx.notify();
                }))
        });
        let (work_disclosure, other_disclosure) = if work_header.is_some() {
            (disclosure, None)
        } else {
            (None, disclosure)
        };
        // Swift's assistant row reads body first; provider/model and existing
        // actions form a quiet signature below the reply and its media. Native
        // text/find/selection state and every action controller stay unchanged.
        let metadata = div()
            .text_sm()
            .text_color(if kind == "assistant" {
                self.provider_ink(&provider)
            } else {
                self.color(0xe4e9f2).opacity(0.7)
            })
            .when(kind == "assistant", |meta| meta.mt_2().text_xs())
            .when(kind != "assistant", |meta| meta.mb_2())
            .flex()
            .flex_wrap()
            .items_center()
            .justify_between()
            .gap_2()
            .child(
                div()
                    .min_w_0()
                    .flex_1()
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .gap_2()
                    .child(label)
                    .when_some(work_status, |label, status| {
                        label.child(
                            div()
                                .text_xs()
                                .px_1()
                                .rounded_sm()
                                .bg(self.color(0xe4e9f2).opacity(0.06))
                                .child(status),
                        )
                    })
                    .when(kind == "assistant" && !model.is_empty(), |label| {
                        label.child(
                            div()
                                .text_xs()
                                .text_color(self.color(0xe4e9f2).opacity(0.6))
                                .child(model),
                        )
                    }),
            )
            .when(kind == "assistant", |header| {
                let source = source_id.clone();
                let item = item_id.clone();
                header.child(
                    Button::new(SharedString::from(format!(
                        "quote-message-{source_id}-{item_id}"
                    )))
                    .accessibility_id(SharedString::from(format!(
                        "quote-message-{source_id}-{item_id}"
                    )))
                    .label("Quote message")
                    .ghost()
                    .compact()
                    .xsmall()
                    .disabled(copy_empty)
                    .tooltip("Attach the complete reply as reference material (up to 16,000 bytes)")
                    .on_click(
                        cx.listener(move |this, _, _, cx| this.quote_message(&source, &item, cx)),
                    ),
                )
            })
            .when_some(metadata_copy, |header, copy| header.child(copy))
            .when(kind == "assistant" && settled, |footer| {
                let source = source_id.clone();
                let item = item_id.clone();
                footer.child(
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
                    .ghost()
                    .compact()
                    .xsmall()
                    .tooltip("Copy settled conversation through this turn into a separate branch")
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.branch_from_item(&source, &item, false, window, cx)
                    })),
                )
            })
            .when_some(work_disclosure, |header, control| header.child(control));
        let (header, footer) = if kind == "assistant" {
            (None, Some(metadata.into_any_element()))
        } else if kind == "user" {
            (None, None)
        } else {
            (Some(metadata.into_any_element()), None)
        };
        let card = div()
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
                    .my_0()
            })
            .when(kind == "assistant", |card| {
                card.px_1().py_0().rounded_none()
            })
            .when(collapsible, |card| {
                card.bg(self.color(0x181d28))
                    .border_1()
                    .border_color(self.color(0x29303d))
            })
            .when_some(header, |view, header| view.child(header))
            .when_some(context_pane, |view, context| view.child(context))
            .when_some(other_disclosure, |view, control| view.child(control))
            .child(transcript::preserve_selected_copy(
                &source_id,
                &item_id,
                native_body
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
            .children(self.historical_images(&item_id, cx))
            .when_some(footer, |view, footer| view.child(footer));
        // Swift's user card has no permanent author header. Keep both real
        // actions together below the bubble at its outer edge. They stay
        // reachable for keyboard/AX use without adding hover-only state.
        let card = if kind == "user" {
            let source = source_id.clone();
            let item = item_id.clone();
            let right = self.settings["userMessageSide"].as_str().unwrap_or("right") != "left";
            let edit_action = Button::new(SharedString::from(format!(
                "edit-message-branch-{source_id}-{item_id}"
            )))
            .accessibility_id(SharedString::from(format!(
                "edit-message-branch-{source_id}-{item_id}"
            )))
            .accessibility_label(SharedString::from(format!(
                "Edit message in new branch: {action_excerpt}"
            )))
            .label("Edit in new branch")
            .ghost()
            .compact()
            .xsmall()
            .disabled(source_running)
            .tooltip(if source_running {
                "Stop the current turn before editing an earlier message"
            } else {
                "Create a separate conversation with this message restored as a draft"
            })
            .on_click(cx.listener(move |this, _, window, cx| {
                this.branch_from_item(&source, &item, true, window, cx)
            }));
            div()
                .flex()
                .flex_col()
                .min_w_0()
                .w_full()
                .max_w(px((presentation::CONTENT_WIDTH
                    - presentation::RAIL_GUTTER)
                    * 0.75))
                .my_3()
                .child(card)
                .child(
                    div()
                        .mt_1()
                        .flex()
                        .flex_wrap()
                        .items_center()
                        .gap_1()
                        .text_color(self.color(0xe4e9f2).opacity(0.7))
                        .when(right, |actions| actions.justify_end())
                        .child(edit_action)
                        .when_some(user_copy, |actions, copy| actions.child(copy)),
                )
                .into_any_element()
        } else {
            card.into_any_element()
        };
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
    fn terminal(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.selected.is_none() {
            return;
        }
        self.terminal_open = !self.terminal_open;
        self.sync_terminal_workspace(window, cx);
        cx.notify();
    }
    fn sync_terminal_workspace(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let selected = self.selected.as_ref().map(|thread| text(thread, "id"));
        let visible = self.terminal_open
            && !self.settings_open
            && !self.schedules_open
            && !self.workspace_open
            && !self.session_import_open
            && !self.command_palette.read(cx).is_open()
            && !self.historical_image_is_open()
            && window.is_window_active()
            && window.visibility().is_visible();
        let target = selected.filter(|id| visible && !id.is_empty());
        if self.terminal_visible_thread == target {
            return;
        }
        if let Some(previous) = self.terminal_visible_thread.take()
            && let Some(workspace) = self.terminal_workspaces.get(&previous)
        {
            workspace.update(cx, |workspace, cx| workspace.set_visible(false, cx));
        }
        if let Some(thread) = target {
            let workspace = self
                .terminal_workspaces
                .entry(thread.clone())
                .or_insert_with(|| {
                    cx.new(|cx| {
                        terminal_workspace::TerminalWorkspace::new(
                            self.engine.clone(),
                            thread.clone(),
                            window,
                            cx,
                        )
                    })
                });
            debug_assert_eq!(workspace.read(cx).thread_id(), thread);
            workspace.update(cx, |workspace, cx| workspace.set_visible(true, cx));
            self.terminal_visible_thread = Some(thread);
        }
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
        // Revoke image-modal input immediately on either close path, before its
        // ordinary conversation surface is replaced by cleanup-only controls.
        if self.media.close_requested || self.media.shutdown_requested {
            self.sync_historical_image_view(window, cx);
        }
        // Closing exposes only already-owned cleanup recovery, never the general
        // settings surface or a new source/profile admission.
        let cookie_recovery = if self.media.shutdown_requested || self.media.close_requested {
            self.browser_settings_panel
                .update(cx, |panel, cx| panel.cookie_cleanup_recovery(cx))
        } else {
            None
        };
        if self.media.shutdown_requested
            || (self.media.close_requested
                && self.media_shutdown_ready(cx)
                && self.computer_use_shutdown_ready())
        {
            self.quit_frame_seen = true;
            return div()
                .flex()
                .flex_col()
                .size_full()
                .p_6()
                .gap_3()
                .bg(self.color(0x10141c))
                .text_color(self.color(0xe4e9f2))
                .child(if self.media.shutdown_requested {
                    "Finishing background work and saving before quitting…"
                } else {
                    "Finishing background work and saving before closing…"
                })
                .child(self.status.clone())
                .when_some(cookie_recovery, |view, recovery| view.child(recovery))
                .when(!self.pending_drafts.is_empty(), |view| {
                    view.child(Button::new("quit-retry-save").label("Retry save").on_click(
                        cx.listener(|this, _, _, cx| {
                            draft_close::retry_failed(&mut this.pending_drafts);
                            this.flush_pending_drafts();
                            cx.notify();
                        }),
                    ))
                })
                .when(!self.media_shutdown_ready(cx), |view| {
                    view.child(self.media_settings_pane(cx))
                });
        }
        self.sync_media_context(cx);
        self.sync_historical_image_view(window, cx);
        self.sync_terminal_workspace(window, cx);
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
        self.sync_composer_selection(window, cx);
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
        self.sync_sidebar_resize(window);
        let navigation_rail = self.navigation_rail(cx);
        let sidebar = self
            .thread_list_open
            .then(|| self.navigation_sidebar(&selected_id, window, cx));
        let title = self
            .selected
            .as_ref()
            .map(|v| text(v, "title"))
            .unwrap_or_else(|| "Welcome to Coincide".into());
        let entity = cx.entity();
        let transcript = div()
            .on_children_prepainted(self.media_layout_observer(cx))
            .flex_1()
            .min_h(px(120.))
            .child(
                list(self.transcript_list.clone(), move |index, window, cx| {
                    entity.update(cx, |this, cx| this.message(index, window, cx))
                })
                .size_full(),
            );
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
            } else if self.computer_use_settings_visible() {
                self.computer_use_settings_pane(cx)
            } else if self.media_settings_visible() {
                self.media_settings_pane(cx)
            } else if self.browser_settings_visible() {
                let scroll = self.browser_settings_panel.read(cx).form_scroll();
                div()
                    .id("browser-settings-surface")
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(
                        Button::new("browser-settings-back")
                            .label("Back to Settings")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.browser_settings_open = false;
                                this.credential_panel
                                    .update(cx, |panel, cx| panel.cancel(cx));
                                this.sync_transcription_binding(cx);
                                cx.notify();
                            })),
                    )
                    .child(
                        div().relative().flex_1().min_h_0().flex().flex_col().overflow_hidden()
                            .child(div()
                                .id("browser-settings-scroll")
                                .track_scroll(&scroll).pr_4()
                                .flex_1().min_h_0().overflow_y_scroll()
                                .when(self.browser.is_none(),|view|view.child(div().p_3().child("The browser is unavailable; profile changes and password filling are disabled.")))
                                .child(self.browser_settings_panel.clone())
                                .child(div().p_3().text_lg().child("Passwords"))
                                .child(self.credential_panel.clone()))
                            .child(gpui_kit::component::scroll::Scrollbar::vertical(&scroll)
                                .mode(gpui_kit::component::scroll::ScrollbarMode::Always)),
                    )
                    .into_any_element()
            } else if self.credentials_open {
                div()
                    .id("password-settings-surface")
                    .flex_1()
                    .flex_basis(px(0.))
                    .min_h_0()
                    .min_w_0()
                    .overflow_y_scroll()
                    .child(
                        Button::new("password-settings-back")
                            .label("Back to Settings")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.credentials_open = false;
                                this.credential_panel
                                    .update(cx, |panel, cx| panel.cancel(cx));
                                this.sync_transcription_binding(cx);
                                cx.notify();
                            })),
                    )
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
                                    this.github_threads_open = false;
                                    this.sync_github_context(cx);
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new("workspace-github-tab")
                                .label("GitHub pull requests")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.github_open = true;
                                    this.github_threads_open = false;
                                    this.sync_workspace_context(cx);
                                    cx.notify();
                                })),
                        )
                        .child(Button::new("workspace-github-threads-tab").label("Inline review threads")
                            .on_click(cx.listener(|this,_,window,cx|{
                                this.github_open=false;this.github_threads_open=true;this.github_threads_scope_stale=false;
                                this.sync_workspace_context(cx);
                                let loaded=this.github_panel.read(cx).loaded_pr_scope(cx);
                                this.github_threads_seed=loaded.clone();
                                if let Some((repository,number,head))=loaded {
                                    this.github_threads_panel.update(cx,|panel,cx|panel.set_pr(repository,number,head,window,cx));
                                }
                                cx.notify();
                            }))),
                )
                .child(if self.github_threads_open {
                    div().flex_1().flex_basis(px(0.)).min_h_0().min_w_0().overflow_hidden().flex().flex_col()
                        .when(self.github_threads_scope_stale,|view|view.child(div().p_2().text_sm().child("PR detail changed. Reopen Inline review threads to bind the new loaded scope, or return to Local Git.")))
                        .child(self.github_threads_panel.clone()).into_any_element()
                } else if self.github_open {
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
        let historical_image = self.historical_image_overlay(cx);
        div()
            .relative()
            .capture_key_down(
                cx.listener(|this, event, window, cx| {
                    if !this.historical_image_shortcut(event, window, cx) {
                        this.app_shortcut(event, window, cx);
                    }
                }),
            )
            .flex()
            .size_full()
            .bg(self.color(0x10141c))
            .text_color(self.color(0xe4e9f2))
            .child(navigation_rail)
            .when_some(sidebar, |view, sidebar| view.child(sidebar))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .when_some(cookie_recovery, |view, recovery| view.child(recovery))
                    .when(!self.pending_drafts.is_empty(), |view| {
                        view.child(
                            div()
                                .p_2()
                                .flex()
                                .items_center()
                                .gap_2()
                                .child("Drafts are not saved yet. Keep this window open.")
                                .when(
                                    self.pending_drafts.values().any(|draft| !draft.retry),
                                    |view| {
                                        view.child(
                                            Button::new("retry-draft-save")
                                                .label("Retry save")
                                                .on_click(cx.listener(|this, _, _, cx| {
                                                    draft_close::retry_failed(
                                                        &mut this.pending_drafts,
                                                    );
                                                    this.flush_pending_drafts();
                                                    cx.notify();
                                                })),
                                        )
                                    },
                                ),
                        )
                    })
                    .child(self.conversation_toolbar(title, cx))
                    .when_some(self.thread_management(cx), |view, management| {
                        view.child(management)
                    })
                    .when(
                        self.find_context_available() && self.transcript_find.read(cx).is_open(),
                        |view| {
                            view.child(
                                div()
                                    .id("transcript-find-surface")
                                    .max_h(px(140.))
                                    .flex_shrink_0()
                                    .overflow_y_scroll()
                                    .child(self.transcript_find.clone()),
                            )
                        },
                    )
                    .child(conversation_content)
                    .when_some(pending_pane, |view, pane| view.child(pane))
                    .when(self.terminal_visible_thread.is_some(), |view| {
                        view.child(
                            div()
                                .id("terminal-workspace-surface")
                                .h(px(320.))
                                .min_h(px(140.))
                                .flex_shrink_1()
                                .child(
                                    self.terminal_workspaces
                                        [self.terminal_visible_thread.as_ref().unwrap()]
                                    .clone(),
                                ),
                        )
                    })
                    .when(show_composer, |view| {
                        view.child(
                            div()
                                .id("composer-column")
                                .w_full()
                                .flex()
                                .flex_col()
                                .items_center()
                                .justify_center()
                                .min_h(px(140.))
                                .max_h(px(320.))
                                .flex_shrink_0()
                                .overflow_hidden()
                                .px(px(presentation::CONTENT_GUTTER))
                                .py_3()
                                .child(
                                    div()
                                        .w_full()
                                        .min_w_0()
                                        .min_h_0()
                                        .max_h(px(296.))
                                        .flex()
                                        .flex_col()
                                        .max_w(px(presentation::CONTENT_WIDTH))
                                        .p_3()
                                        .rounded(px(22.))
                                        .bg(self.color(0x181d28))
                                        .border_1()
                                        .border_color(self.color(0x29303d))
                                        .child(
                                            // The bounded accessory viewport shrinks independently of
                                            // the pinned textarea/actions. Keep a persistent thumb so
                                            // long selection forms do not require coarse wheel steps.
                                            div()
                                                .relative()
                                                .min_h_0()
                                                .max_h(px(160.))
                                                .flex_shrink_1()
                                                .flex()
                                                .flex_col()
                                                .overflow_hidden()
                                                .child(
                                                    div()
                                                        .id("composer-accessories")
                                                        .track_scroll(&self.composer_accessory_scroll)
                                                        .pr_4()
                                                        .min_h_0()
                                                        .max_h(px(160.))
                                                        .flex_shrink_1()
                                                        .overflow_y_scroll()
                                                        .when(self.composer_selection_expanded(), |view| view.child(self.composer_selection_pane(cx)))
                                                        .when_some(
                                                            self.composer_steering_pane(cx),
                                                            |view, steering| view.child(steering),
                                                        )
                                                        .when_some(
                                                            self.composer_context_pane(cx),
                                                            |view, context| view.child(context),
                                                        )
                                                        .when_some(queue_pane, |view, queue| {
                                                            view.child(queue)
                                                        })
                                                        .when_some(draft_images, |view, images| {
                                                            view.child(images)
                                                        })
                                                )
                                                .child(
                                                    gpui_kit::component::scroll::Scrollbar::vertical(
                                                        &self.composer_accessory_scroll,
                                                    )
                                                    .mode(gpui_kit::component::scroll::ScrollbarMode::Always),
                                                ),
                                        )
                                        .child({
                                            let target = cx.entity().downgrade();
                                            div()
                                                .id("composer-image-drop")
                                                .flex_shrink_0()
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
                                                .id("composer-actions")
                                                .flex()
                                                .flex_shrink_0()
                                                .flex_wrap()
                                                .items_center()
                                                .min_w_0()
                                                .gap_1()
                                                .mt_2()
                                                .child(self.composer_selection_footer(cx))
                                                .child(
                                                    Button::new("attach-images")
                                                        .icon(gpui_kit::assets::IconName::Plus)
                                                        .accessibility_label(if importing_images {
                                                            "Importing images…"
                                                        } else {
                                                            "Attach images"
                                                        })
                                                        .tooltip(if importing_images { "Importing images…" } else { "Attach images" })
                                                        .compact().ghost()
                                                        .disabled(importing_images)
                                                        .on_click(cx.listener(|this, _, _, cx| {
                                                            this.attach_images(cx)
                                                        })),
                                                )
                                                .child(
                                                    Button::new("send")
                                                        .primary()
                                                        .disabled(importing_images || self.selection_send_blocked())
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
                                                .child(Button::new("stop").icon(gpui_kit::assets::IconName::Square)
                                                    .accessibility_label("Stop agent").tooltip("Stop agent")
                                                    .compact().ghost().disabled(!self.running.contains(&selected_id)).on_click(
                                                    cx.listener(|this, _, _, cx| {
                                                        if let Some(v) = this.selected.as_ref()
                                                            && let Err(e) = call(
                                                                &this.engine,
                                                                "agent.stop",
                                                                json!({"threadId":v["id"]}),
                                                            )
                                                        {
                                                            this.status = e.to_string();
                                                        }
                                                        cx.notify();
                                                    }),
                                                )),
                                        )
                                        .child(
                                            div()
                                                .id("composer-status")
                                                .mt_2()
                                                .max_h(px(32.))
                                                .flex_shrink_0()
                                                .overflow_y_scroll()
                                                .text_sm()
                                                .text_color(self.color(0xe4e9f2).opacity(0.7))
                                                .child(self.status.clone()),
                                        ),
                                ),
                        )
                    }),
            )
            .when_some(browser_pane, |view, pane| view.child(pane))
            .when_some(historical_image, |view, image| view.child(image))
            .when(self.command_palette.read(cx).is_open(), |view| {
                view.child(
                    div()
                        .absolute()
                        .inset_0()
                        .flex()
                        .justify_center()
                        .pt_16()
                        .bg(rgba(0x00000080))
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(|_, _, _, cx| cx.stop_propagation()),
                        )
                        .child(
                            div()
                                .w_full()
                                .max_w(px(680.))
                                .h(px(580.))
                                .max_h_full()
                                .child(self.command_palette.clone()),
                        ),
                )
            })
    }
}
fn palette_entries_equal(
    a: &[command_palette::PaletteEntry],
    b: &[command_palette::PaletteEntry],
) -> bool {
    a.len() == b.len()
        && a.iter().zip(b).all(|(a, b)| {
            a.command == b.command
                && a.title == b.title
                && a.subtitle == b.subtitle
                && a.keywords == b.keywords
                && a.enabled == b.enabled
                && a.disabled_reason == b.disabled_reason
        })
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
    let store = Store::open(&data.join("coincide.sqlite"))?;
    let media_data = store.data_directory()?;
    let media_config = coincide_core::legacy_media_service::ServiceConfig {
        database_path: media_data.join("coincide.sqlite"),
        expected_data_directory: media_data,
    };
    let engine = Arc::new(Mutex::new(Engine::new(store)));
    let control_owner = Arc::new(Mutex::new(control::serve(
        data.join("control.sock"),
        engine.clone(),
    )?));
    // Retain the control owner across ordinary window closure. Final Drop is
    // outside GPUI after the explicit quit driver observed its actual join.
    let _control_lifetime = control_owner.clone();
    #[cfg(target_os = "linux")]
    let application = gpui_kit::platform::linux(WindowingModes::X11);
    #[cfg(not(target_os = "linux"))]
    let application = gpui_kit::application();
    application
        .with_assets(assets::CoincideAssets)
        .run(move |cx| {
            gpui_kit::init(cx);
            let quit_requested = app_menu::install(cx);
            transcript::init(cx);
            Theme::change(ThemeMode::Dark, None, cx);
            let bounds = Bounds::centered(None, size(px(1280.), px(820.)), cx);
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    window_min_size: Some(size(px(820.), px(520.))),
                    ..Default::default()
                },
                cx,
                |window, cx| {
                    window.set_window_title("Coincide Rust Preview");
                    cx.new(|cx| {
                        Coincide::new(
                            engine,
                            quit_requested,
                            control_owner,
                            data.join("browser-profile"),
                            media_config,
                            window,
                            cx,
                        )
                    })
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

#[cfg(test)]
mod find_mount_tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn full_snapshot_includes_folded_reasoning_and_omits_draft_metadata() {
        let long = format!("**bold** {} needle", "x".repeat(400));
        let thread = json!({"id":"thread","draft":"private draft needle","items":[{"id":"reason","kind":"reasoning","text":long},{"id":"tool","kind":"tool","text":"`code` 中"}]});
        let sources = find_sources(&thread).unwrap();
        assert_eq!(sources[0].source, long);
        assert_eq!(sources[1].source, "`code` 中");
        assert!(
            !sources
                .iter()
                .any(|item| item.source.contains("private draft"))
        );
    }
    #[::core::prelude::v1::test]
    fn source_generation_and_thread_stamps_reject_stale_reveals() {
        let mut thread = json!({"id":"thread","items":[{"id":"a","text":"old"}]});
        let snapshot = find_sources(&thread).unwrap();
        assert!(find_snapshot_current(&thread, "thread", 2, 2, &snapshot));
        assert!(!find_snapshot_current(&thread, "thread", 1, 2, &snapshot));
        assert!(!find_snapshot_current(&thread, "other", 2, 2, &snapshot));
        thread["items"][0]["text"] = json!("new");
        assert!(!find_snapshot_current(&thread, "thread", 2, 2, &snapshot));
    }
    #[::core::prelude::v1::test]
    fn row_reveal_resolves_current_stable_id_and_refuses_ambiguous_snapshots() {
        let mut thread =
            json!({"id":"thread","items":[{"id":"a","text":"A"},{"id":"b","text":"B"}]});
        assert_eq!(find_row(&thread, "thread", "b"), Some(1));
        thread["items"].as_array_mut().unwrap().swap(0, 1);
        assert_eq!(find_row(&thread, "thread", "b"), Some(0));
        assert_eq!(find_row(&thread, "other", "b"), None);
        thread["items"][1]["id"] = json!("b");
        assert!(find_sources(&thread).is_err());
        thread["items"][1]["id"] = Value::Null;
        assert!(find_sources(&thread).is_err());
    }
    #[::core::prelude::v1::test]
    fn browser_visible_find_shortcut_passthrough_is_selected_thread_scoped() {
        let thread = json!({"id":"selected"});
        let mut panels = std::collections::HashSet::new();
        assert!(transcript_find_shortcut_routes(Some(&thread), &panels));
        panels.insert("other".into());
        assert!(transcript_find_shortcut_routes(Some(&thread), &panels));
        panels.insert("selected".into());
        assert!(!transcript_find_shortcut_routes(Some(&thread), &panels));
        assert!(!transcript_find_shortcut_routes(None, &panels));
    }
    #[::core::prelude::v1::test]
    fn inline_threads_transport_does_not_expose_write_or_arbitrary_routes() {
        for method in [
            "github.threads.list",
            "github.threads.comments",
            "github.threads.result",
            "github.threads.cancel",
        ] {
            assert!(github_threads_method_allowed(method));
        }
        for method in [
            "github.write.submit",
            "github.pr.read",
            "agent.send",
            "terminal.create",
            "github.threads.unknown",
        ] {
            assert!(!github_threads_method_allowed(method));
        }
    }
    #[::core::prelude::v1::test]
    fn native_activation_consumes_only_matching_explicit_open_once() {
        let mut requested = None;
        assert!(!consume_open_activation(&mut requested, "thread"));
        requested = Some("other".into());
        assert!(!consume_open_activation(&mut requested, "thread"));
        assert_eq!(requested.as_deref(), Some("other"));
        assert!(consume_open_activation(&mut requested, "other"));
        assert!(requested.is_none());
        assert!(!consume_open_activation(&mut requested, "other"));
    }
    #[::core::prelude::v1::test]
    fn find_mount_anchors_an_unmeasured_row_without_tail_following() {
        let list =
            ListState::new(100, ListAlignment::Bottom, px(500.)).with_uniform_item_height(px(20.));
        list.splice(74..75, 1);
        list.scroll_to(ListOffset {
            item_ix: 74,
            offset_in_item: px(0.),
        });
        assert_eq!(list.logical_scroll_top().item_ix, 74);
        assert_eq!(list.logical_scroll_top().offset_in_item, px(0.));
        assert!(!list.is_following_tail());
    }
}
