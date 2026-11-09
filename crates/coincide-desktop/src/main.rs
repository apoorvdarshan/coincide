mod appshots;
mod appshots_platform;
mod appshots_settings;
mod codex_limits_mount;
mod codex_limits_view;
#[cfg(test)]
#[path = "dictation_preview_ui_tests.rs"]
mod dictation_preview_ui_tests;
mod draft_saver;
#[cfg(test)]
#[path = "../swift_link_options.rs"]
mod swift_link_options_tests;
mod usage_dashboard;
mod usage_dashboard_ui;
mod usage_history_mount;
mod usage_history_view;
mod voice_credentials;
mod voice_settings;
mod voice_shortcut;
mod voice_speech;
mod voice_system;
mod worker_owner;
use anyhow::{Context as _, Result};
mod about_settings;
mod app_commands;
mod app_menu;
mod app_menu_mount;
mod app_shell;
mod app_shell_mount;
mod approval_banner;
mod archive_settings;
mod assets;
mod bot_avatar;
mod bot_settings;
mod browser;
mod browser_address_bar;
mod browser_controls;
mod browser_dialog_ui;
mod browser_login_mount;
mod browser_passkey_ui;
mod browser_settings;
mod browser_tab_shortcuts;
mod browser_tab_shortcuts_mount;
mod browser_user_turn_ui;
#[cfg(any(target_os = "windows", test))]
mod browser_viewport_geometry;
mod chat_inspector;
mod chat_layout;
mod chat_rewind;
mod chat_turns;
mod command_palette;
mod community_links;
mod composer_attachments;
mod composer_commands;
mod composer_context_mount;
mod composer_context_view;
mod composer_file_picker;
mod composer_follow_up_mount;
mod composer_plan_card;
mod composer_selection;
mod composer_steering;
mod composer_steering_mount;
mod composer_suggestions;
mod computer_use;
mod computer_use_mount;
mod computer_use_settings;
mod context_details;
mod context_details_mount;
mod conversation_toolbar;
mod credential_settings;
mod credentials;
mod dictation_preview;
mod diff_mount;
mod diff_panel;
mod draft_close;
mod general_settings;
mod git_controls;
mod github_actions;
mod github_review;
mod github_threads;
mod github_write_transport;
mod historical_image_view;
mod inbox_undo;
mod inspector_follow;
mod instructions;
mod instructions_config;
mod instructions_scope;
mod keyboard_settings;
mod legacy_media_mount;
mod legacy_media_recovery;
mod legacy_media_settings;
mod main_window_poll;
mod microphone;
mod microphone_settings;
#[rustfmt::skip]
mod bot_artwork_data;
mod models_settings;
mod native_quit;
mod navigation;
mod navigation_rail;
mod navigation_resize;
mod notification_activity;
mod notification_runtime;
#[cfg(any(test, all(target_os = "linux", feature = "native-notifications")))]
mod notification_server;
mod notification_settings;
mod notifications;
mod open_targets;
mod palette_catalog;
mod palette_search_owner;
mod presentation;
mod project_defaults_ui;
mod project_management;
mod project_management_mount;
mod project_scripts_ui;
mod provider_configuration_ui;
mod provider_settings;
mod provider_setup_terminal;
mod queue;
mod quit_confirmation;
mod quit_mount;
mod quit_shortcut;
mod remote_settings;
mod reply_selection_mount;
mod scheduling;
mod session_import;
mod settings;
mod settings_navigation;
mod settings_scroll;
mod settings_search;
mod settings_window;
mod shutdown_runtime;
mod sidebar_bots;
mod sidebar_controls;
mod sidebar_drop;
mod sidebar_keys;
mod sidebar_lifecycle;
mod sidebar_menus;
mod sidebar_preferences;
mod sidebar_rename;
mod sidebar_search;
mod sidebar_settle;
mod sidebar_thread_status;
mod terminal_context_mount;
mod terminal_layout;
mod terminal_selection;
mod terminal_workspace;
mod thread_bulk;
mod tool_detail;
mod transcript;
mod transcript_find;
mod transcript_links;
mod transcription_composer;
mod transcription_settings;
mod turn_changes;
#[cfg(feature = "preview-updater-helper")]
pub mod updater_helper_transport;
mod updater_lifecycle;
mod updater_mount;
mod updater_settings;
mod window_chrome;
mod workspace;
mod workspace_inspector;
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
        "method":"threads.patch", "params":{"threadId":id,"patch":{"draft":text},"compact":true}
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

/// One coherent viewport, every visible row read under one Engine lock, so a
/// tall pane never mixes revisions. Busy means the last frame stays visible.
fn read_terminal_frame(
    engine: &SharedEngine,
    id: &str,
    palette: &coincide_core::terminal::Palette,
) -> Result<Option<Value>> {
    let mut frame = try_state(engine)?.read_terminal_viewport(id, palette)?;
    let rows = frame["rows"].as_u64().unwrap_or(0) as usize;
    let cols = frame["cols"].as_u64().unwrap_or(0) as usize;
    anyhow::ensure!(rows <= 300 && cols <= 500, "Invalid terminal viewport");
    let grid = frame["grid"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("Terminal page has no cells"))?;
    anyhow::ensure!(
        grid.len() == rows
            && grid
                .iter()
                .all(|row| row.as_array().is_some_and(|cells| cells.len() == cols)),
        "Invalid terminal page dimensions"
    );
    frame.as_object_mut().unwrap().remove("lines");
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
    palette_search: palette_search_owner::State,
    palette_entries: Vec<command_palette::PaletteEntry>,
    palette_menus: Vec<command_palette::PaletteMenu>,
    revision: u64,
    running: Vec<String>,
    pending_requests: Vec<Value>,
    follow_up_picker: bool,
    follow_up_anchor: Option<Point<Pixels>>,
    follow_up_deliveries: Vec<composer_follow_up_mount::PendingDelivery>,
    pending_inputs: std::collections::HashMap<(String, String, String), Entity<InputState>>,
    pending_choices: std::collections::HashMap<(String, String, String), Vec<String>>,
    queued_messages: Vec<Value>,
    queue_enabled: bool,
    queue_error: String,
    thread_list_open: bool,
    thread_bulk: thread_bulk::State,
    sidebar_lifecycle: sidebar_lifecycle::State,
    thread_bulk_focus: FocusHandle,
    sidebar_resize: navigation_resize::State,
    sidebar_list_height: f32,
    thread_list_focus: FocusHandle,
    navigation_focus: FocusHandle,
    open_targets: Vec<open_targets::Target>,
    open_target_children: Vec<std::process::Child>,
    settings_open: bool,
    thread_actions_open: bool,
    settings_search: Entity<InputState>,
    settings_navigation: settings_navigation::State,
    instructions_panel: Entity<instructions::InstructionsPanel>,
    provider_configuration_panel: Entity<provider_configuration_ui::Panel>,
    provider_enable_prompt: Option<Task<()>>,
    models_settings: models_settings::ModelsSettings,
    archive_settings: archive_settings::ArchiveSettings,
    instruction_quit_prompt_pending: bool,
    instruction_quit_task: Option<Task<()>>,
    /// The open "Quit Coincide?" prompt.
    quit_confirmation: Option<Task<()>>,
    /// Whether this launch already offered the starter bots.
    starter_bots_checked: bool,
    settings_section: settings::SettingsSection,
    settings_scroll: settings_scroll::State,
    settings_reveal: settings_search::Reveal,
    general_settings: general_settings::State,
    settings_window: Option<gpui_kit::AnyWindowHandle>,
    settings_window_pending: bool,
    main_window: gpui_kit::AnyWindowHandle,
    settings_focus: FocusHandle,
    appshots: appshots::State,
    context_details: context_details_mount::State,
    keyboard: keyboard_settings::State,
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
    remote_panel: Entity<remote_settings::RemoteSettingsPanel>,
    created_bot_thread_to_focus: Option<String>,
    transcription_open: bool,
    transcription_panel: Entity<transcription_settings::TranscriptionSettings>,
    transcription_events: std::sync::mpsc::Receiver<transcription_settings::TextReady>,
    transcription_target: transcription_composer::ComposerTarget,
    voice: voice_shortcut::State,
    voice_credentials: Entity<voice_credentials::Panel>,
    microphone_panel: Entity<microphone_settings::MicrophoneSettings>,
    microphone_events: std::sync::mpsc::Receiver<transcription_settings::TextReady>,
    microphone_window_active: bool,
    microphone_settings_active: bool,
    session_import_open: bool,
    session_import_panel: Entity<session_import::SessionImportPanel>,
    updater_settings: Entity<updater_settings::UpdaterSettingsView>,
    credentials_open: bool,
    browser_settings_open: bool,
    browser_settings_panel: Entity<browser_settings::BrowserSettings>,
    browser_profile_requests: std::sync::mpsc::Receiver<browser_settings::ProfileRequest>,
    credential_panel: Entity<credential_settings::CredentialSettings>,
    credential_jobs: std::sync::mpsc::Receiver<credentials::FillJob>,
    inspector_follow: inspector_follow::State,
    workspace_open: bool,
    workspace_panel: Entity<workspace::WorkspacePanel>,
    git_controls: git_controls::GitControls,
    diff_panel: Entity<diff_panel::DiffPanel>,
    /// The Local Git tab shows the Rust-only checkpoint and worktree tools, not the diff.
    git_tools_open: bool,
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
    terminal_layout: terminal_layout::State,
    terminal_workspaces:
        std::collections::HashMap<String, Entity<terminal_workspace::TerminalWorkspace>>,
    terminal_visible_thread: Option<String>,
    transcript_list: ListState,
    transcript_count: usize,
    expanded: std::collections::HashSet<usize>,
    chat_turns: chat_turns::State,
    approval_replies: approval_banner::Replies,
    threads: Vec<ThreadSummary>,
    sidebar_all_threads: Vec<ThreadSummary>,
    sidebar_preferences: sidebar_preferences::Preferences,
    sidebar_bots: Vec<Value>,
    sidebar_schedules: Vec<Value>,
    sidebar_bot_baseline: String,
    sidebar_bot_pending: Option<String>,
    sidebar_settle_undo: Option<Vec<sidebar_settle::SettleChange>>,
    inbox_undo: inbox_undo::State,
    sidebar_message_search: sidebar_search::MessageSearch,
    /// Projects whose folder is gone, checked when the list refreshes.
    missing_project_folders: std::collections::HashSet<String>,
    window_chrome: window_chrome::State,
    projects: Vec<Value>,
    selected_project: Option<String>,
    expanded_sidebar_lists: std::collections::HashSet<String>,
    collapsed_projects: std::collections::HashSet<String>,
    show_snoozed: bool,
    navigation_last_clock: Instant,
    thread_activity: sidebar_thread_status::ThreadActivity,
    sidebar_renaming: Option<sidebar_rename::Renaming>,
    sidebar_rename_candidate: Option<String>,
    sidebar_type_select: sidebar_keys::TypeSelect,
    rename_input: Entity<InputState>,
    archive_confirmation: Option<String>,
    project_management: project_management_mount::Projects,
    project_defaults: project_defaults_ui::State,
    project_scripts: project_scripts_ui::State,
    project_picker_open: bool,
    project_path: Entity<InputState>,
    selected: Option<Value>,
    pending_native_selection: Option<Option<String>>,
    startup_selection_pending: bool,
    pending_drafts: std::collections::HashMap<String, PendingDraft>,
    draft_saver: draft_saver::Saver,
    composer: Entity<TextareaState>,
    model_input: Entity<InputState>,
    model_picker_search: Entity<InputState>,
    selection_ui: composer_selection::ComposerSelection,
    composer_accessory_scroll: ScrollHandle,
    composer_files: composer_file_picker::Picker,
    composer_suggestions: composer_suggestions::Suggestions,
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
    browser_focus: FocusHandle,
    browser_address_page: Option<(String, String)>,
    browser_completion: browser_address_bar::Completion,
    /// The page area's bounds from the last layout, for fixed test viewports.
    browser_page_bounds: std::rc::Rc<std::cell::Cell<Option<Bounds<Pixels>>>>,
    browser_panels: std::collections::HashSet<String>,
    browser_library_thread: Option<String>,
    browser_control: Value,
    browser_ui_operations: std::collections::HashMap<String, String>,
    browser_replies: Vec<coincide_core::browser_protocol::BrowserReply>,
    link_menu: Option<transcript_links::LinkMenu>,
    turn_changes: turn_changes::TurnChanges,
    plan_card: composer_plan_card::State,
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
        let visible = self.chat_inspector_panel() == Some(chat_inspector::Panel::Workspace)
            && self.github_open
            && !self.github_threads_open;
        self.github_panel.update(cx, |panel, cx| {
            panel.set_context(context.clone(), cx);
            panel.set_visible(visible, cx);
        });
        let threads_context = if self.chat_inspector_panel()
            == Some(chat_inspector::Panel::Workspace)
            && self.github_threads_open
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
    /// The selected conversation's stored worktree or project folder.
    fn selected_root_hint(&self) -> Option<String> {
        self.selected.as_ref().and_then(|selected| {
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
        })
    }
    fn sync_workspace_context(&mut self, cx: &mut Context<Self>) {
        let thread = self.selected.as_ref().map(|selected| text(selected, "id"));
        let root_hint = self.selected_root_hint();
        self.diff_panel.update(cx, |panel, cx| {
            panel.set_context(thread.clone(), root_hint.clone(), cx)
        });
        self.sync_diff_thread(false, cx);
        self.workspace_panel
            .update(cx, |panel, cx| panel.set_context(thread, root_hint, cx));
        self.sync_github_context(cx);
        self.sync_git_controls(cx);
    }
    fn sync_browser_settings_route(&mut self, cx: &mut Context<Self>) {
        if self
            .browser_library_thread
            .as_deref()
            .is_some_and(|thread| {
                self.selected
                    .as_ref()
                    .and_then(|selected| selected["id"].as_str())
                    != Some(thread)
            })
            || self.settings_open
            || !self.chat_visible()
        {
            self.browser_library_thread = None;
        }
        let route = (!self.command_palette.read(cx).is_open())
            .then(|| {
                let thread = self.selected.as_ref().map(|thread| text(thread, "id"))?;
                if self.browser_settings_visible() {
                    Some(format!("settings:{thread}"))
                } else if self.browser_pane_controls_visible() {
                    Some(format!("pane:{}:{thread}", self.browser_library_visible()))
                } else {
                    None
                }
            })
            .flatten();
        self.browser_settings_panel.update(cx, |panel, cx| {
            panel.sync_route_context(route.as_deref(), cx);
        });
    }

    fn sync_transcription_binding(
        &mut self,
        cx: &mut Context<Self>,
    ) -> Option<transcription_settings::ComposerBinding> {
        self.sync_thread_bulk(cx);
        self.sync_browser_settings_route(cx);
        let voice_composer =
            self.chat_visible() && coincide_core::voice::Settings::decode(&self.settings).enabled;
        let voice_settings = self.settings_open
            && self.transcription_open
            && !self.bots_open
            && !self.notifications_open
            && !self.session_import_open
            && !self.credentials_open
            && !self.provider_settings.open
            && !self.command_palette.read(cx).is_open();
        let thread = if voice_composer || voice_settings {
            self.selected.as_ref().map(|thread| text(thread, "id"))
        } else {
            None
        };
        let preview_source = self.dictation_original_source(cx);
        let composer = self.composer.read(cx);
        let (source, selection, reversed) = preview_source.unwrap_or_else(|| {
            (
                composer.value().to_string(),
                composer.selected_range(),
                composer.is_selection_reversed(),
            )
        });
        let binding =
            self.transcription_target
                .bind(thread.as_deref(), &source, selection, reversed);
        self.transcription_panel.update(cx, |panel, cx| {
            panel.set_binding(
                if voice_settings {
                    binding.clone()
                } else {
                    None
                },
                cx,
            )
        });
        let (settings_revision, mut configuration) = self
            .transcription_panel
            .read(cx)
            .recording_configuration(cx);
        if voice_composer && let Some(config) = configuration.as_mut() {
            let language = coincide_core::voice::Settings::decode(&self.settings).language;
            config.language = if language == "auto" {
                "auto".into()
            } else {
                language.split('-').next().unwrap_or("auto").to_lowercase()
            };
        }
        let microphone_binding = (self.microphone_window_active || self.microphone_settings_active)
            .then(|| binding.clone())
            .flatten();
        let voice = coincide_core::voice::Settings::decode(&self.settings);
        let configuration = if voice_composer
            && self.microphone_window_active
            && !self.microphone_settings_active
        {
            use coincide_core::{dictation::transcription::Provider, voice::Engine as VoiceEngine};
            match voice_speech::effective_engine(voice.engine) {
                VoiceEngine::OpenAi | VoiceEngine::Groq => {
                    let provider = if voice.engine == VoiceEngine::OpenAi {
                        Provider::OpenAi
                    } else {
                        Provider::Groq
                    };
                    let model = if provider == Provider::OpenAi {
                        voice.openai_model
                    } else {
                        voice.groq_model
                    };
                    let language = (voice.language != "auto").then(|| {
                        voice
                            .language
                            .split('-')
                            .next()
                            .unwrap_or("en")
                            .to_lowercase()
                    });
                    self.voice_credentials
                        .read(cx)
                        .configuration(provider, model, language, cx)
                        .map(microphone_settings::RecordingConfig::Hosted)
                }
                VoiceEngine::Whisper => {
                    configuration.map(microphone_settings::RecordingConfig::Local)
                }
                VoiceEngine::Apple => Some(microphone_settings::RecordingConfig::Apple(
                    voice_speech::Configuration {
                        locale: voice.language.clone(),
                        maximum_seconds: 60,
                    },
                )),
            }
        } else {
            configuration.map(microphone_settings::RecordingConfig::Local)
        };
        self.microphone_panel.update(cx, |panel, cx| {
            // This is a compiled capability, not OS permission or a capture
            // acceptance claim. Only the native Enable/Record actions can
            // request authorization/open a device; rendering has no OS effects.
            panel.set_configuration_target(
                microphone_binding,
                settings_revision,
                configuration,
                voice.input_device_uid,
                microphone::compiled_backend_available(),
                cx,
            );
        });
        binding
    }
    fn poll_transcription(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.microphone_window_active =
            window.is_window_active() && window.visibility().is_visible();
        self.voice_credentials
            .update(cx, |panel, cx| panel.poll(window, cx));
        self.sync_transcription_binding(cx);
        self.poll_voice_shortcut(window, cx);
        self.transcription_panel
            .update(cx, |panel, cx| panel.poll(cx));
        self.microphone_panel.update(cx, |panel, cx| panel.poll(cx));
        if let Some(request) = self
            .transcription_panel
            .update(cx, |panel, _| panel.take_model_use())
        {
            let result = (|| -> Result<Value> {
                anyhow::ensure!(
                    self.settings.get("voice") == request.expected_voice.as_ref(),
                    "Voice settings changed while verifying the model; choose Use again"
                );
                let mut owner = try_state(&self.engine)?;
                let current = owner.store.document("settings.json")?;
                anyhow::ensure!(
                    current.as_ref().and_then(|v| v.get("voice"))
                        == request.expected_voice.as_ref(),
                    "Voice settings changed; reload before choosing the model"
                );
                owner.store.save_native_voice_settings_if_unchanged(
                    current.as_ref(),
                    coincide_core::voice::Edit::WhisperModel(request.model.id()),
                )
            })();
            match result {
                Ok(settings) => {
                    self.microphone_panel
                        .update(cx, |panel, cx| panel.cancel(cx));
                    self.transcription_panel.update(cx, |panel, cx| {
                        panel.accept_catalog_model(request.model, cx)
                    });
                    let mut public = self.settings.clone();
                    public["voice"] = settings["voice"].clone();
                    self.accept_settings(public, window, cx);
                }
                Err(error) => self.status = error.to_string(),
            }
        }
        self.poll_dictation_preview(window, cx);
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
            if !self.prepare_dictation_final_source(from_microphone, &event, cx) {
                continue;
            }
            let editable = self.composer.update(cx, |composer, cx| {
                composer.is_editable() && composer.marked_text_range(window, cx).is_none()
            });
            if !editable {
                if from_microphone {
                    self.cancel_composer_dictation(cx);
                }
                self.status="Transcript retained no insertion: the composer has editing restrictions or an active composition.".into();
                continue;
            }
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
            let send_dictation = if from_microphone {
                self.voice.ticket.take().is_some_and(|intent| {
                    intent.accepts(&event, self.settings.get("voice").unwrap_or(&Value::Null))
                })
            } else {
                false
            };
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
                    if send_dictation && !event.text.trim().is_empty() && self.chat_visible() {
                        // Native session intent, exact accepted target and ordinary
                        // Send admission; a preference document alone never sends.
                        self.send_selected(false, window, cx);
                    }
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
    fn flush_native_selection(&mut self) -> bool {
        let Some(selected) = self.pending_native_selection.as_ref() else {
            return true;
        };
        let Ok(mut engine) = self.engine.try_lock() else {
            return false;
        };
        match engine
            .store
            .remember_native_selected_thread(selected.as_deref())
        {
            Ok(_) => {
                self.pending_native_selection = None;
                true
            }
            Err(error) => {
                self.status = format!("Unable to remember conversation selection: {error}");
                false
            }
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
        native_editors: coincide_core::native_ui_edits::NativeUiEditors,
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
                if this.block_voice_close(window, cx)
                    || this.block_provider_configuration_close(window, cx)
                {
                    return false;
                }
                if this.instructions_panel.read(cx).has_unsaved_edits(cx) {
                    this.prompt_instruction_close(false, window, cx);
                    return false;
                }
                // Keep the global drain owner and its recovery controls alive.
                // Closing this window cannot bypass the broader quit fence.
                if this.media.shutdown_requested {
                    cx.notify();
                    return false;
                }
                let drafts_saved = this.flush_pending_drafts();
                let cookies_ready = this.poll_cookie_close(cx);
                this.appshots.close();
                this.shutdown_computer_use(cx);
                let media_ready = this.request_media_close(window, cx);
                cx.notify();
                drafts_saved
                    && media_ready
                    && cookies_ready
                    && this.computer_use_shutdown_ready()
                    && this.appshots.drained()
            })
            .unwrap_or(false)
        });
        let settings = call(&engine, "settings.read", json!({})).unwrap_or_else(|_| json!({}));
        quit_shortcut::configure(&settings, cx);
        let composer = cx.new(|cx| {
            TextareaState::new(window, cx)
                .placeholder("Ask anything. @ files, / commands")
                .submit_on_enter(settings["sendOnReturn"].as_bool().unwrap_or(true))
        });
        let mut transcription_events = None;
        let transcription_panel = cx.new(|cx| {
            let (mut panel, events) =
                transcription_settings::TranscriptionSettings::new(window, cx);
            panel.configure_model_downloads(engine.clone(), native_editors.clone());
            transcription_events = Some(events);
            panel
        });
        let transcription_events =
            transcription_events.expect("Transcription receiver initialized");
        let (microphone_settings, microphone_events) =
            microphone_settings::MicrophoneSettings::new();
        let microphone_panel = cx.new(|_| microphone_settings);
        let voice_credentials =
            cx.new(|cx| voice_credentials::Panel::new(native_editors.clone(), window, cx));
        let bot_panel =
            cx.new(|cx| bot_settings::BotSettingsPanel::new(engine.clone(), window, cx));
        let notification_panel = cx.new(|cx| {
            notification_settings::NotificationSettingsPanel::new(engine.clone(), window, cx)
        });
        // Listens only when "Allow Coincide Remote" was left on.
        let remote_panel = cx.new(|_| remote_settings::RemoteSettingsPanel::new(engine.clone()));
        let usage_history = usage_history_mount::Mount::new(engine.clone(), cx);
        let codex_limits = codex_limits_mount::Mount::new(engine.clone(), cx);
        let steering = composer_steering::SteeringController::new(engine.clone());
        let settings_search = cx.new(|cx| InputState::new(window, cx).placeholder("Search"));
        let provider_configuration_panel = cx.new(|cx| {
            provider_configuration_ui::Panel::new(
                engine.clone(),
                native_editors.clone(),
                window,
                cx,
            )
        });
        let instructions_panel = cx.new(|cx| {
            instructions::InstructionsPanel::new(
                engine.clone(),
                native_editors.editor(),
                window,
                cx,
            )
        });
        let models_settings = models_settings::ModelsSettings::new(window, cx);
        let archive_settings = archive_settings::ArchiveSettings::new(window, cx);
        let general_settings = general_settings::State::new(cx);
        let project_scripts = project_scripts_ui::State::new(window, cx);
        let model_picker_search =
            cx.new(|cx| InputState::new(window, cx).placeholder("Search models"));
        let model_input = cx.new(|cx| InputState::new(window, cx).placeholder("Default model"));
        let schedule_editor = scheduling::ScheduleEditor::new(window, cx);
        let provider_settings = provider_settings::ProviderSettings::new(window, cx);
        let session_import_panel =
            cx.new(|cx| session_import::SessionImportPanel::new(engine.clone(), window, cx));
        // The channel is present only when the trusted launcher supplies the
        // feed/base/anchor; otherwise this remains the unavailable default.
        let updater_mount = updater_mount::Mount::prepare();
        let updater_settings = cx.new(|cx| {
            updater_settings::UpdaterSettingsView::new(
                updater_mount.settings,
                updater_mount.policy,
                updater_mount.launcher,
                engine.clone(),
                cx,
            )
        });
        // Discovery checks executable metadata only. Vault reads require a
        // password-manager button click in this native panel.
        // Discovery checks executable metadata only. Vault reads for filling
        // require a password-manager button click in this native panel; a page's
        // passkey request lists Bitwarden's passkeys only while "Use passkeys
        // from Bitwarden" is on and Bitwarden is unlocked (browser_passkeys.rs).
        let credential_sources = credential_settings::installed_sources();
        let passkey_vault = credential_settings::bitwarden_passkeys(&credential_sources);
        let (credential_settings, credential_jobs) =
            credential_settings::CredentialSettings::new(credential_sources);
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
        let git_controls = git_controls::GitControls::new(engine.clone(), window, cx);
        let prefix = general_settings::branch_prefix(&settings);
        workspace_panel.update(cx, |panel, _| panel.set_branch_prefix(prefix));
        let diff_panel = cx.new(|cx| diff_panel::DiffPanel::new(engine.clone(), window, cx));
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
        let composer_files = composer_file_picker::Picker::new(window, cx);
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search"));
        let rename_input =
            cx.new(|cx| InputState::new(window, cx).placeholder("Conversation title"));
        let project_path =
            cx.new(|cx| InputState::new(window, cx).placeholder("Existing project folder path"));
        let browser_address =
            cx.new(|cx| InputState::new(window, cx).placeholder(browser_address_bar::PLACEHOLDER));
        let (browser, browser_error) = match control::download_directory()
            .and_then(|downloads| BrowserController::new(profile_dir, downloads))
        {
            Ok(mut browser) => {
                // `bw` runs only after a page asks and, for the key, after Sign In.
                browser.set_passkey_vault(passkey_vault);
                (Some(browser), None)
            }
            Err(error) => (None, Some(format!("Browser unavailable: {error}"))),
        };
        if let Ok(mut engine) = engine.try_lock() {
            engine.ui_available = browser.is_some();
        }
        let mut composer_sizing = chat_layout::ComposerSizing::default();
        let mut subscriptions = vec![
            cx.subscribe(&composer_files.query,|this,_,event,cx| {if matches!(event,InputEvent::Change) {this.composer_files.invalidate();cx.notify();}}),
            cx.subscribe(&codex_limits.panel, |this, _, _, cx| {
                this.codex_limits.set_context(this.selected.as_ref(), cx);
                this.codex_limits.refresh(cx);
            }),
            cx.subscribe(&usage_history.panel, |this, _, event, cx| {
                this.usage_history.load(event, cx);
            }),
            cx.observe(&provider_configuration_panel, |_, _, cx| cx.notify()),
            cx.subscribe_in(&github_panel, window, |this, _, event, window, cx| {
                this.open_github_checkout(event, window, cx);
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
                match event {
                    command_palette::PaletteEvent::Activated { revision, command } => {
                        this.palette_search.cancel();
                        this.activate_palette(*revision, command.clone(), window, cx)
                    }
                    command_palette::PaletteEvent::Search(request) => {
                        this.run_palette_search(request.clone(), cx)
                    }
                    command_palette::PaletteEvent::Dismissed
                    | command_palette::PaletteEvent::SearchInvalidated => this.palette_search.cancel(),
                }
                this.sync_transcription_binding(cx);
                cx.notify();
            }),
            cx.observe_window_activation(window, |this, window, cx| {
                if window.is_window_active() {
                    this.appshots.app_activated();
                }
                this.microphone_window_active = window.is_window_active() && window.visibility().is_visible();
                // Git may have changed outside Coincide while the window was inactive.
                if window.is_window_active() {
                    this.git_controls.request_refresh();
                }
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
            cx.observe(&composer, move |this, _, cx| {
                let native_preview=this.owns_dictation_preview_notification(cx);
                if !native_preview && this.voice.preview.is_some(){this.cancel_composer_dictation(cx);}
                let composer = this.composer.read(cx);
                if !native_preview {this.composer_files.observe_composer(
                    composer.value().to_string(),
                    composer.selected_range(),
                    composer.is_selection_reversed(),
                );}
                // Selection has no dedicated InputEvent in gpui-base 0.9.0.
                // Invalidate on every notification, including a coalesced
                // caret-away/back sequence; hidden unfocused composer is stable.
                if !native_preview {this.transcription_target.changed();this.sync_transcription_binding(cx);}
                // Cursor/selection notifications do not change composer height.
                // Only a changed native wrapped-text measurement refits it.
                {
                    let composer = this.composer.read(cx);
                    if composer_sizing.changed(
                        composer.display_map().wrap_row_count(),
                        composer.line_height().map(f32::from).unwrap_or(20.),
                    ) {
                        cx.notify();
                    }
                }
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
                        let completion_window = this.main_window;
                        let completion = cx.spawn_in(window, async move |this, cx| {
                            let result = open.await;
                            let _ = main_window_poll::update(completion_window, &this, cx, |this, window, cx| {
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
                    let thread_id = match event {
                        session_import::SessionImportEvent::Imported { thread_id } => thread_id,
                        session_import::SessionImportEvent::Cancelled => {
                            this.session_import_open = false;
                            this.sync_transcription_binding(cx);
                            this.sync_credentials(cx);
                            cx.notify();
                            return;
                        }
                    };
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
                    let completion_window = this.main_window;
                    let completion = cx.spawn_in(window, async move |this, cx| {
                        let result = open.await;
                        let _ = main_window_poll::update(completion_window, &this, cx, |this, window, cx| {
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
            // Return or a click elsewhere saves a sidebar rename.
            cx.subscribe_in(&rename_input, window, |this, _, event, window, cx| {
                if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
                    this.end_sidebar_rename(true, window, cx);
                }
            }),
            cx.subscribe_in(&composer, window, |this, _, event, window, cx| {
                if matches!(event, InputEvent::PressEnter { shift: false, .. })
                    && this.settings["sendOnReturn"].as_bool().unwrap_or(true)
                    && !this.settings_open
                    && this.chat_visible()
                {
                    this.send(window, cx);
                }
            }),
            cx.subscribe_in(&browser_address, window, |this, input, event, window, cx| {
                match event {
                    InputEvent::PressEnter { .. } => this.browser_go(window, cx),
                    InputEvent::Focus => this.begin_browser_address(cx),
                    InputEvent::Change => {
                        let thread = this.selected.as_ref().map(|thread| text(thread, "id"));
                        this.browser_completion
                            .changed(input, thread.as_deref(), window, cx);
                    }
                    _ => {}
                }
            }),
            cx.subscribe(&search, |this, search, event, cx| {
                if matches!(event, InputEvent::Change) {
                    this.thread_bulk.invalidate();
                    let query = search.read(cx).value().to_string();
                    this.sidebar_message_search.changed(&query, Instant::now());
                    this.refresh(cx);
                }
            }),
            cx.subscribe(&composer, |this, _, event, cx| {
                if matches!(event, InputEvent::Blur) {
                    this.flush_pending_drafts();
                }
                if matches!(event, InputEvent::Change) {this.thread_bulk.invalidate();this.composer_files.text_changed();this.invalidate_terminal_contexts(cx);}
                if matches!(event, InputEvent::Change)
                    && let Some(v) = this.selected.as_mut()
                {
                    let draft = this.composer.read(cx).value().to_string();
                    if v["draft"].as_str() == Some(draft.as_str()) {
                        return;
                    }
                    v["draft"] = json!(draft);
                    let id = text(v, "id");
                    this.draft_saver.record(&id, &draft);
                    this.pending_drafts.insert(
                        id.clone(),
                        PendingDraft {
                            text: draft,
                            retry: true,
                        },
                    );
                    // Drafts persist when the composer loses focus, the thread
                    // changes or the app quits. Keeping the store off the typing
                    // path is essential: a long imported thread rewrites a
                    // multi-megabyte document and blocks the UI.
                }
            }),
        ];
        subscriptions.push(cx.observe_window_bounds(window, |this, _, _| {
            this.window_chrome.frame_changed();
        }));
        subscriptions.push(cx.subscribe(&model_picker_search, |_, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        }));
        subscriptions.extend(models_settings.subscriptions(window, cx));
        subscriptions.extend(archive_settings.subscriptions(cx));
        subscriptions.extend(general_settings.subscriptions(window, cx));
        subscriptions.extend(project_scripts.subscriptions(cx));
        subscriptions.extend(schedule_editor.subscriptions(cx));
        subscriptions.extend(provider_settings.subscriptions(cx));
        let sidebar_preferences = sidebar_preferences::Preferences::load(&engine);
        let sidebar_schedules = call(&engine, "schedules.list", json!({}))
            .ok()
            .and_then(|reply| reply["tasks"].as_array().cloned())
            .unwrap_or_default();
        let sidebar_bot_reply = call(&engine, "bots.list", json!({})).unwrap_or(Value::Null);
        let sidebar_bots = sidebar_bot_reply["bots"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let sidebar_bot_baseline = text(&sidebar_bot_reply, "baseline");
        let threads: Vec<ThreadSummary> = call(
            &engine,
            "threads.list",
            json!({"includeArchived":sidebar_preferences.flag("showsArchivedThreads")}),
        )
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
        let poll_window = window.window_handle();
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(150))
                    .await;
                if let Err(error) =
                    main_window_poll::update(poll_window, &this, cx, |this, window, cx| {
                        this.tick(window, cx)
                    })
                {
                    // A removed main window or released owner ends this task;
                    // never silently keep polling through an unexpected error.
                    eprintln!("Main window polling stopped: {error}");
                    break;
                }
            }
        });
        let collapsed_projects = projects
            .iter()
            .filter(|project| project["isExpanded"] == false)
            .map(|project| text(project, "id"))
            .collect();
        let sidebar_resize = navigation_resize::State::load(&engine);
        let keyboard = keyboard_settings::State::new(cx);
        let terminal_layout = terminal_layout::State::load(&engine);
        let thread_list_open = window_chrome::sidebar_open(&engine);
        let window_chrome = window_chrome::State::new(
            try_state(&engine)
                .ok()
                .and_then(|engine| window_chrome::saved_frame(&engine.store)),
        );
        let browser_control = engine
            .try_lock()
            .map(|engine| engine.browser_agent_control_settings())
            .unwrap_or(json!({"agentControlByDefault":false}));
        let draft_saver = draft_saver::Saver::new(engine.clone());
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
            palette_search: Default::default(),
            palette_entries: Vec::new(),
            palette_menus: Vec::new(),
            revision: 0,
            running: Vec::new(),
            pending_requests: Vec::new(),
            follow_up_picker: false,
            follow_up_anchor: None,
            follow_up_deliveries: Vec::new(),
            pending_inputs: Default::default(),
            pending_choices: Default::default(),
            queued_messages: Vec::new(),
            queue_enabled: false,
            queue_error: String::new(),
            thread_list_open,
            thread_bulk: Default::default(),
            sidebar_lifecycle: Default::default(),
            thread_bulk_focus: cx.focus_handle(),
            sidebar_resize,
            sidebar_list_height: 560.,
            thread_list_focus: cx.focus_handle(),
            navigation_focus: cx.focus_handle(),
            open_targets: open_targets::installed(),
            open_target_children: Vec::new(),
            settings_open: false,
            thread_actions_open: false,
            settings_search,
            settings_navigation: Default::default(),
            settings_section: Default::default(),
            settings_scroll: Default::default(),
            settings_reveal: Default::default(),
            instructions_panel,
            provider_configuration_panel,
            provider_enable_prompt: None,
            models_settings,
            general_settings,
            archive_settings,
            instruction_quit_prompt_pending: false,
            instruction_quit_task: None,
            quit_confirmation: None,
            starter_bots_checked: false,
            settings_window: None,
            settings_window_pending: false,
            main_window: window.window_handle(),
            settings_focus: cx.focus_handle(),
            appshots: appshots::State::new(cx),
            context_details: Default::default(),
            keyboard,
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
            remote_panel,
            created_bot_thread_to_focus: None,
            transcription_open: false,
            transcription_panel,
            transcription_events,
            transcription_target: Default::default(),
            voice: Default::default(),
            voice_credentials,
            microphone_panel,
            microphone_events,
            microphone_window_active: window.is_window_active() && window.visibility().is_visible(),
            microphone_settings_active: false,
            session_import_open: false,
            session_import_panel,
            updater_settings,
            credentials_open: false,
            browser_settings_open: false,
            browser_settings_panel,
            browser_profile_requests,
            credential_panel,
            credential_jobs,
            inspector_follow: Default::default(),
            workspace_open: false,
            workspace_panel,
            git_controls,
            diff_panel,
            git_tools_open: false,
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
            terminal_layout,
            terminal_workspaces: Default::default(),
            terminal_visible_thread: None,
            transcript_list: ListState::new(0, ListAlignment::Bottom, px(500.)),
            transcript_count: 0,
            expanded: Default::default(),
            chat_turns: Default::default(),
            approval_replies: Default::default(),
            sidebar_all_threads: threads.clone(),
            show_archived: sidebar_preferences.flag("showsArchivedThreads"),
            show_snoozed: sidebar_preferences.flag("showsSnoozedThreads"),
            sidebar_preferences,
            sidebar_bots,
            sidebar_schedules,
            sidebar_bot_baseline,
            sidebar_bot_pending: None,
            sidebar_settle_undo: None,
            inbox_undo: Default::default(),
            sidebar_message_search: Default::default(),
            missing_project_folders: Default::default(),
            window_chrome,
            threads,
            projects,
            selected_project: None,
            expanded_sidebar_lists: std::collections::HashSet::new(),
            collapsed_projects,
            navigation_last_clock: Instant::now(),
            thread_activity: Default::default(),
            sidebar_renaming: None,
            sidebar_rename_candidate: None,
            sidebar_type_select: Default::default(),
            rename_input,
            archive_confirmation: None,
            project_management: project_management_mount::Projects::new(window, cx),
            project_defaults: project_defaults_ui::State::new(window, cx),
            project_scripts,
            project_picker_open: false,
            project_path,
            selected: None,
            pending_native_selection: None,
            startup_selection_pending: true,
            pending_drafts: Default::default(),
            draft_saver,
            composer,
            model_input,
            model_picker_search,
            selection_ui: {
                let mut ui = composer_selection::ComposerSelection::default();
                if let Ok(directory) = coincide_core::control::data_directory()
                    && let Ok(text) =
                        std::fs::read_to_string(directory.join("model-catalog-cache.json"))
                    && let Ok(cached) = serde_json::from_str::<Value>(&text)
                    && cached["state"] == "ready"
                {
                    ui.catalog = cached;
                }
                ui
            },
            composer_accessory_scroll: ScrollHandle::default(),
            composer_files,
            composer_suggestions: Default::default(),
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
            browser,
            browser_address,
            browser_focus: cx.focus_handle(),
            browser_address_page: None,
            browser_completion: Default::default(),
            browser_page_bounds: Default::default(),
            browser_panels: Default::default(),
            browser_library_thread: None,
            browser_control,
            browser_ui_operations: Default::default(),
            browser_replies: Vec::new(),
            link_menu: None,
            turn_changes: Default::default(),
            plan_card: Default::default(),
            _subscriptions: subscriptions,
        };
        Self::install_link_router(cx);
        this.apply_appearance(window, cx);
        this.restore_startup_selection(window, cx);
        this.appshots.sync(&this.settings);
        this.poll_computer_use(cx);
        this
    }
    fn restore_startup_selection(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.startup_selection_pending {
            return;
        }
        let snapshot = (|| -> Result<(Vec<ThreadSummary>, Option<String>)> {
            let mut engine = try_state(&self.engine)?;
            let requested = engine.requested_open.clone();
            let remembered = engine.store.native_last_selected_thread()?;
            let response = engine.dispatch(json!({"method":"threads.list","params":{}}));
            if let Some(error) = response.get("error") {
                anyhow::bail!(
                    "{}",
                    error["message"]
                        .as_str()
                        .unwrap_or("Unable to load conversations")
                );
            }
            Ok((
                serde_json::from_value(response["result"].clone())?,
                requested.or(remembered),
            ))
        })();
        match snapshot {
            Ok((threads, remembered)) => {
                let target = remembered
                    .filter(|id| threads.iter().any(|thread| &thread.id == id))
                    .or_else(|| threads.first().map(|thread| thread.id.clone()));
                self.threads = threads;
                if let Some(id) = target {
                    self.select(&id, window, cx);
                    self.startup_selection_pending = self
                        .selected
                        .as_ref()
                        .is_none_or(|thread| thread["id"] != id);
                } else {
                    self.startup_selection_pending = false;
                }
            }
            Err(error) if engine_busy(&error) => {}
            Err(error) => {
                self.status = format!("Saved conversation selection unavailable: {error}")
            }
        }
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
        if self.computer_use_settings_visible()
            && let Some(mount) = &self.computer_use_mount
        {
            let titles = self
                .threads
                .iter()
                .filter_map(|thread| {
                    Some((
                        uuid::Uuid::parse_str(&thread.id).ok()?,
                        thread.title.clone(),
                    ))
                })
                .collect();
            mount
                .panel()
                .update(cx, |panel, cx| panel.set_titles(titles, cx));
        }
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
            .child(self.settings_subpage_header("Computer Use", "computer-use-settings-done", cx))
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
    /// What the user typed: an address, a local file, or a search with their
    /// engine, as Swift's `PreviewSession.navigate(_:)`.
    fn browser_go(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let typed = self.browser_address.read(cx).value().to_string();
        let engine = self
            .engine
            .try_lock()
            .map(|engine| engine.browser_search_engine())
            .unwrap_or_default();
        match browser_address_bar::destination(&typed, engine) {
            Some(
                coincide_core::browser_address::Destination::Web(url)
                | coincide_core::browser_address::Destination::Search(url),
            ) => self.browser_action(BrowserAction::Navigate { url: url.into() }, None, cx),
            Some(coincide_core::browser_address::Destination::File(file)) => {
                let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
                    return;
                };
                if let Some(browser) = &mut self.browser
                    && let Err(error) = browser.open_local_file(&thread, &file, window, cx)
                {
                    self.status = format!("Browser: {error}");
                }
                cx.notify();
            }
            None => {
                self.status = format!("Browser: {}", browser_address_bar::INVALID_ADDRESS);
                cx.notify();
            }
        }
    }
    /// Loads completion for the selected thread's profile as editing begins.
    fn begin_browser_address(&mut self, cx: &mut Context<Self>) {
        let value = self.browser_address.read(cx).value().to_string();
        self.browser_completion.begin_editing(&value);
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        let profile = self.browser.as_ref().and_then(|browser| {
            match browser.profile_snapshot(&thread).selected {
                browser_settings::ProfileChoice::Persistent(id) => Some(id),
                browser_settings::ProfileChoice::Private => None,
            }
        });
        self.browser_completion
            .load(&self.engine, &thread, profile, cx);
    }
    fn toggle_browser(&mut self, cx: &mut Context<Self>) {
        if self.global_schedules_route() {
            self.close_schedule_surface();
        }
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
        let mut ordinary_requests = Vec::with_capacity(requests.len());
        let requested_login = requests
            .iter()
            .any(|r| matches!(r.action, BrowserAction::FillLogin { .. }));
        for request in requests {
            if !browser_controls::agent_request_allowed(
                &self.browser_control,
                &request.thread_id,
                self.browser_ui_operations.contains_key(&request.id),
            ) {
                self.browser_replies
                    .push(coincide_core::browser_protocol::BrowserReply {
                        id: request.id,
                        thread_id: request.thread_id,
                        result: json!({"error":"Agent Control is off for this conversation"}),
                    });
                continue;
            }
            if matches!(request.action, BrowserAction::FillLogin { .. }) {
                self.request_browser_login(request, window, cx);
            } else {
                ordinary_requests.push(request);
            }
        }
        let requests = ordinary_requests;
        let image_viewer_open = self.historical_image_is_open();
        let terminal_right = self.terminal_on_right();
        let selected_id = self.selected.as_ref().map(|thread| text(thread, "id"));
        let mut changed = requested_login || !requests.is_empty();
        let mut browser_note: Option<Option<inspector_follow::SavedPanel>> = None;
        let selected_closes_last = requests.iter().any(|request| {
            matches!(&request.action, BrowserAction::CloseTab)
                && selected_id.as_deref() == Some(request.thread_id.as_str())
        });

        // Presentation arbitration precedes native WebView reconciliation. Work
        // for a background thread cannot replace the foreground chat route.
        for request in &requests {
            match &request.action {
                // An agent handing the user a step opens the browser, as
                // Swift's `reveal` does for ask-user.
                BrowserAction::Show | BrowserAction::AskUser { .. } => {
                    if selected_id.as_deref() == Some(request.thread_id.as_str())
                        && self.chat_visible()
                    {
                        self.clear_inspector_placeholders();
                        self.workspace_open = false;
                        self.close_schedule_surface();
                        browser_note = Some(Some(inspector_follow::SavedPanel::Preview));
                        if terminal_right {
                            self.terminal_open = false;
                        }
                    }
                    self.browser_panels.insert(request.thread_id.clone());
                }
                BrowserAction::Hide => {
                    if selected_id.as_deref() == Some(request.thread_id.as_str())
                        && self.chat_inspector_panel() == Some(chat_inspector::Panel::Browser)
                    {
                        self.clear_inspector_placeholders();
                        browser_note = Some(None);
                    }
                    self.browser_panels.remove(&request.thread_id);
                }
                _ => {}
            }
        }
        if requests.iter().any(|request| {
            matches!(
                &request.action,
                BrowserAction::Show | BrowserAction::AskUser { .. }
            ) && selected_id.as_deref() == Some(request.thread_id.as_str())
        }) && self.chat_visible()
        {
            self.ensure_inspector_space(window);
        }
        let browser_is_panel = self.chat_inspector_panel() == Some(chat_inspector::Panel::Browser);
        let close_visible_last_tab = selected_closes_last && browser_is_panel;
        let Some(browser) = &mut self.browser else {
            if let Ok(mut engine) = self.engine.try_lock() {
                for reply in self.browser_replies.drain(..) {
                    engine.browser_reply(reply);
                }
            }
            return;
        };
        let viewport_changed = requests
            .iter()
            .any(|request| matches!(request.action, BrowserAction::Viewport { .. }));
        for request in requests {
            browser.execute(request, window, cx);
        }
        // The panel lays out a fixed viewport only on its next render.
        changed |= viewport_changed;
        changed |= browser.set_passkey_preferences(browser::passkeys::Preferences::from_settings(
            &self.settings,
        ));
        changed |= browser.poll(window, cx);
        self.browser_completion.poll();
        if close_visible_last_tab
            && selected_id
                .as_deref()
                .is_some_and(|thread| browser.active_view(thread).is_none())
        {
            if let Some(thread) = &selected_id {
                self.browser_panels.remove(thread);
            }
            self.inspector_follow.preview_placeholder = false;
            browser_note = Some(None);
        }

        let selected = self.selected.as_ref().map(|v| text(v, "id"));
        let visible = selected.as_deref().filter(|thread| {
            browser_is_panel && self.browser_panels.contains(*thread) && !image_viewer_open
        });
        // API work for another thread may create a native surface; reconcile it
        // before yielding to the run loop so it never covers this conversation.
        browser.set_thread_visible(visible, cx);
        self.browser_replies.extend(browser.drain_replies());
        let native_tab_shortcuts = browser.drain_tab_shortcuts();
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
        if let Some(choice) = browser_note {
            self.remember_inspector_choice(choice, cx);
        }
        for (source, command) in native_tab_shortcuts {
            self.perform_browser_tab_shortcut(source, command, true, window, cx);
            changed = true;
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
        let pane_controls = self.browser_pane_controls(&thread, active.as_ref(), cx);
        let library_popup = self
            .browser_library_visible()
            .then(|| self.browser_settings_panel.clone());
        let dialog_banner = self.browser_dialog_banner(cx);
        let user_turn_banner = self.browser_user_turn_banner(cx);
        let page = self.browser_page(&thread, webview, cx);
        let passkey_banner = self.browser_passkey_banner(cx);
        Some(
            div()
                .track_focus(&self.browser_focus)
                .flex()
                .flex_col()
                .flex_1()
                .min_w_0()
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
                        .child(Button::new("browser-go").label("Go").on_click(
                            cx.listener(|this, _, window, cx| this.browser_go(window, cx)),
                        )),
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
                .child(pane_controls)
                .children(library_popup)
                .children(dialog_banner)
                .children(user_turn_banner)
                .child(page)
                .children(passkey_banner)
                .into_any_element(),
        )
    }
    fn refresh(&mut self, cx: &mut Context<Self>) -> bool {
        if let Ok(engine) = self.engine.try_lock() {
            self.browser_control = engine.browser_agent_control_settings();
        }
        let mut complete = true;
        self.refresh_queue(cx);
        if self.schedules_open {
            self.refresh_schedules(cx);
        }
        // Settings › Archive stays current as threads are archived and deleted.
        if self.settings_open && self.settings_section == settings::SettingsSection::Archive {
            self.refresh_archive_settings(cx);
        }
        if let Ok(projects) = call(&self.engine, "projects.list", json!({})) {
            self.projects = projects.as_array().cloned().unwrap_or_default();
            // The project scripts' one-click script (Swift UIState lastScripts).
            if let Ok(engine) = try_state(&self.engine)
                && let Ok(document) = engine.store.native_inspector_document()
            {
                self.project_scripts.remember(document.as_ref());
            }
            self.collapsed_projects = self
                .projects
                .iter()
                .filter(|project| project["isExpanded"] == false)
                .map(|project| text(project, "id"))
                .collect();
        } else {
            complete = false;
        }
        self.missing_project_folders = navigation::missing_project_folders(&self.projects);
        match sidebar_search::read(
            &self.engine,
            &self.search.read(cx).value(),
            self.show_archived,
            &self.projects,
            self.sidebar_message_search.matches(),
            &self.sidebar_branch_prefix(),
        ) {
            Ok((visible, all)) => {
                self.threads = visible;
                self.sidebar_all_threads = all;
                // A transient busy lock must not leave a permanent error line.
                if self.status.starts_with("Unable to load conversations:") {
                    self.status.clear();
                }
            }
            Err(error) => {
                complete = false;
                self.status = format!("Unable to load conversations: {error}");
            }
        }
        if let Ok(reply) = call(&self.engine, "schedules.list", json!({})) {
            if let Some(tasks) = reply["tasks"].as_array() {
                self.sidebar_schedules = tasks.clone();
            }
        }
        if let Ok(reply) = call(&self.engine, "bots.list", json!({})) {
            if let Some(bots) = reply["bots"].as_array() {
                self.sidebar_bots = bots.clone();
                self.sidebar_bot_baseline = text(&reply, "baseline");
            }
        }
        cx.notify();
        complete
    }
    fn select(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.flush_pending_drafts();
        self.startup_selection_pending = false;
        self.composer_files.invalidate();
        self.thread_bulk.close_selection();
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
                    self.context_details.invalidate();
                    self.invalidate_native_conversation_view();
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
                self.rebind_conversation_schedule_editor(id);
                let section = if v["botID"].is_string() {
                    "bots"
                } else if v["isPinned"] == true {
                    "pinned"
                } else if text(&v, "projectID").is_empty()
                    || v["projectID"] == navigation::NO_PROJECT_ID
                {
                    "chats"
                } else {
                    "projects"
                };
                if self.sidebar_preferences.collapsed(section) {
                    self.toggle_sidebar_section(section, cx);
                }
                if self
                    .selected
                    .as_ref()
                    .is_none_or(|previous| previous["id"] != id)
                {
                    self.suspend_inspector_presentation(cx);
                }
                self.selected = Some(v);
                self.refresh_turn_changes();
                if self.sidebar_preferences.document["unseen"][id].is_string() {
                    self.sidebar_thread_marker("unseen", id, None, cx);
                }
                self.sync_workspace_context(cx);
                self.hide_inline_settings();
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
                self.pending_native_selection = Some(Some(id.to_owned()));
                let activate_requested = if let Ok(mut engine) = self.engine.try_lock() {
                    if engine.active_thread() != Some(id)
                        && let Err(error) = engine.set_active_thread(Some(id.into()))
                    {
                        let _ = engine.set_active_thread(None);
                        self.status =
                            format!("Selected conversation authority unavailable: {error}");
                    }
                    match engine.store.remember_native_selected_thread(Some(id)) {
                        Ok(_) => self.pending_native_selection = None,
                        Err(error) => {
                            self.status =
                                format!("Unable to remember conversation selection: {error}")
                        }
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
                self.restore_inspector_for_selected(cx);
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
        self.chat_visible()
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
            let snapshot = self.palette_snapshot();
            self.palette_entries = snapshot.entries.clone();
            self.palette_menus = snapshot.menus.clone();
            let colors = self.palette_colors();
            if let Err(error) = self.command_palette.update(cx, |palette, cx| {
                palette.set_colors(colors);
                palette.open(snapshot, window, cx)
            }) {
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
        let mut snapshot = self.palette_snapshot();
        if snapshot.entries != self.palette_entries || snapshot.menus != self.palette_menus {
            self.palette_revision = self.palette_revision.saturating_add(1);
            snapshot.revision = self.palette_revision;
            let (entries, menus) = (snapshot.entries.clone(), snapshot.menus.clone());
            if self
                .command_palette
                .update(cx, |palette, cx| {
                    palette.replace_snapshot(snapshot, window, cx)
                })
                .is_ok()
            {
                self.palette_entries = entries;
                self.palette_menus = menus;
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
        let (current, menus) = self.palette_catalog();
        // Search results are checked against the open thread's folder and the
        // disk instead of the catalog.
        let listed = match &command {
            C::OpenFile { root, path, .. } => self.palette_file(root, path).is_some(),
            C::AddProject { path } => {
                std::path::Path::new(path).is_absolute() && std::path::Path::new(path).is_dir()
            }
            C::OpenMenu { .. } => false,
            command => current
                .iter()
                .chain(menus.iter().flat_map(|menu| match &menu.content {
                    command_palette::MenuContent::Lists(lists) => {
                        lists.iter().flat_map(|list| list.entries.iter()).collect()
                    }
                    command_palette::MenuContent::Search(_) => Vec::new(),
                }))
                .any(|entry| entry.enabled && &entry.command == command),
        };
        if revision != self.palette_revision
            || current != self.palette_entries
            || menus != self.palette_menus
            || !listed
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
                self.run_keyboard_command(keyboard_settings::Command::Schedules, window, cx)
            }
            C::Action { id } => self.run_palette_action(&id, window, cx),
            C::AddProject { path } => {
                if self.project_ui_admitted()
                    && let Err((_, error)) = self.add_project_paths(&[path.into()], window, cx)
                {
                    self.status = format!("The folder was not added: {error}");
                }
            }
            C::OpenFile { root, path, line } => {
                if let Some(file) = self.palette_file(&root, &path) {
                    self.open_file_at_line(file, line, cx);
                }
            }
            C::OpenMenu { .. } => {}
        }
        self.sync_transcription_binding(cx);
        cx.notify();
    }
    fn new_thread(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(bot) = self
            .selected
            .as_ref()
            .and_then(|thread| thread["botID"].as_str())
            .map(str::to_owned)
        {
            if self.sidebar_bots.iter().any(|saved| {
                saved["id"]
                    .as_str()
                    .is_some_and(|id| id.eq_ignore_ascii_case(&bot))
            }) {
                self.sidebar_open_bot(bot, true, window, cx);
                return;
            }
        }
        if self.settings["newThreadStartsChat"] == true {
            self.new_thread_in_project(navigation::NO_PROJECT_ID, window, cx);
            return;
        }
        match navigation::new_thread_project(
            self.selected_project.as_deref(),
            self.selected.as_ref(),
            &self.projects,
            &self.sidebar_all_threads,
        ) {
            Some(project) => self.new_thread_in_project(&project, window, cx),
            // With no project to start in, New Thread asks for a folder, as in Swift.
            None => self.add_project_from_sidebar(window, cx),
        }
    }
    fn new_thread_in_project(
        &mut self,
        project: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.new_thread_in_folder(project, None, window, cx);
    }
    /// Swift's `ThreadActions.newThread(in:basedOn:)`: a new thread in the
    /// source thread's folder, on its branch.
    fn new_thread_on_branch(&mut self, source: &str, window: &mut Window, cx: &mut Context<Self>) {
        let based = call(&self.engine, "threads.read", json!({"threadId":source})).map(|thread| {
            let branch = text(&thread, "branch");
            (
                text(&thread, "projectID"),
                open_targets::folder_of(&thread, &self.projects),
                branch,
            )
        });
        match based {
            Ok((project, Some(folder), branch)) if !branch.is_empty() => {
                self.new_thread_in_folder(&project, Some((folder, branch)), window, cx)
            }
            Ok(_) => {
                self.status = "This conversation's folder or branch is unavailable.".into();
                cx.notify();
            }
            Err(error) => {
                self.status = format!("Conversation could not be read: {error}");
                cx.notify();
            }
        }
    }
    fn new_thread_in_folder(
        &mut self,
        project: &str,
        based_on: Option<(std::path::PathBuf, String)>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.startup_selection_pending = false;
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
        let (cwd, branch) = match based_on {
            Some((folder, branch)) => (Some(folder), Some(branch)),
            None => (
                self.projects
                    .iter()
                    .find(|p| p["id"].as_str() == Some(project))
                    .and_then(|p| p["path"].as_str())
                    .filter(|path| !path.is_empty())
                    .map(std::path::PathBuf::from)
                    .or_else(|| std::env::current_dir().ok()),
                None,
            ),
        };
        if !self.flush_pending_drafts() {
            self.status = "Save pending drafts before opening a new conversation.".into();
            cx.notify();
            return;
        }
        let result = (|| -> Result<Value> {
            let mut engine = try_state(&self.engine)?;
            let mut request = json!({"projectId":project,"cwd":cwd});
            if let Some(branch) = &branch {
                request["branch"] = json!(branch);
            }
            let intent = engine.prepare_native_new_thread(&request)?;
            engine.apply_native_new_thread(intent)
        })();
        match result {
            Ok(v) => {
                let created = text(&v, "id");
                self.created_bot_thread_to_focus = Some(created.clone());
                self.schedules_open = false;
                self.workspace_open = false;
                self.session_import_open = false;
                self.refresh(cx);
                self.select(&created, window, cx);
            }
            Err(e) => self.status = e.to_string(),
        }
    }
    /// Swift ThreadActions.newThread(in:worktreePath:branch:) after a PR
    /// checkout: the Engine already admitted the conversation, so only
    /// navigation runs here. Selection is retried by ID until it reads.
    fn open_github_checkout(
        &mut self,
        event: &github_review::CheckoutOpened,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.media.shutdown_requested {
            return;
        }
        self.startup_selection_pending = false;
        self.created_bot_thread_to_focus = Some(event.thread.clone());
        self.schedules_open = false;
        self.session_import_open = false;
        self.refresh(cx);
        self.select(&event.thread, window, cx);
        if let Some(notice) = &event.notice {
            self.status = notice.clone();
        }
        cx.notify();
    }
    fn add_project(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.project_ui_admitted() {
            return;
        }
        let paths = self.project_management.folders.clone();
        if paths.is_empty() {
            return;
        }
        match self.add_project_paths(&paths, window, cx) {
            Ok(()) => self.close_project_form(window, cx),
            Err((added, error)) => {
                self.project_management.session.error = format!(
                    "Added {added} of {} folders. The remaining folder was not added: {error}. Already-added folders will be reused on review.",
                    paths.len()
                )
            }
        }
        cx.notify();
    }
    /// Adds folders as projects and opens the first one's latest thread, or a
    /// new one. On failure, how many were added and why the next one was not.
    fn add_project_paths(
        &mut self,
        paths: &[std::path::PathBuf],
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> std::result::Result<(), (usize, String)> {
        let mut first = None;
        let mut added = 0;
        let mut failure = None;
        for path in paths {
            match call(&self.engine, "projects.create", json!({"path":path})) {
                Ok(project) => {
                    if first.is_none() {
                        first = Some(project);
                    }
                    added += 1;
                }
                Err(error) => {
                    failure = Some(error.to_string());
                    break;
                }
            }
        }
        self.refresh(cx);
        self.status = format!("Added {added} folders.");
        if let Some(project) = first {
            let id = text(&project, "id");
            self.selected_project = Some(id.clone());
            match call(
                &self.engine,
                "projects.latest-thread",
                json!({"projectId":id}),
            ) {
                Ok(value) => {
                    if let Some(thread) = value["threadId"].as_str() {
                        self.select(thread, window, cx);
                    } else {
                        self.new_thread_in_project(&id, window, cx);
                    }
                }
                Err(error) => {
                    self.status = format!(
                        "Project added, but its latest conversation could not be opened: {error}"
                    )
                }
            }
        }
        cx.notify();
        failure.map_or(Ok(()), |error| Err((added, error)))
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
    fn sync_browser_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.sync_browser_settings_route(cx);
        let pane_library = self.browser_library_visible();
        let pane_visible = self.browser_pane_controls_visible();
        let settings_visible =
            self.browser_settings_visible() && !self.command_palette.read(cx).is_open();
        let visible =
            (settings_visible || pane_visible) && !self.command_palette.read(cx).is_open();
        let selected_thread = self.selected.as_ref().map(|thread| text(thread, "id"));
        for request in self.browser_profile_requests.try_iter().take(8) {
            let result = if settings_visible {
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
        let history_binding = if settings_visible {
            selected_thread.as_deref().and_then(|thread| {
                self.browser
                    .as_ref()
                    .map(|browser| browser.history_binding(thread))
            })
        } else {
            None
        };
        let (bookmark, reservation, prepared, history) =
            self.browser_settings_panel.update(cx, |panel, cx| {
                // Idempotent injection: only the first binding initializes context.
                panel.pane_mode = !settings_visible;
                panel.set_library_engine(engine);
                panel.set_snapshot(snapshot, cx);
                panel.set_history_binding(history_binding, cx);
                if pane_visible {
                    panel.ensure_pane_library(cx);
                }
                panel.poll(cx);
                (
                    panel.take_bookmark_open(),
                    panel.take_cookie_reservation_request(),
                    panel.take_prepared_cookie_import(),
                    panel.take_history_open(),
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
        if let Some(history) = history {
            let result = (|| -> Result<()> {
                anyhow::ensure!(
                    settings_visible
                        && !self.media.shutdown_requested
                        && !self.media.close_requested
                        && !self.historical_image_is_open()
                        && selected_thread.as_deref()
                            == Some(history.binding.snapshot.thread.as_str()),
                    "History settings closed or selected conversation changed"
                );
                let browser = self.browser.as_ref().context("Browser unavailable")?;
                anyhow::ensure!(
                    browser.history_binding(&history.binding.snapshot.thread) == history.binding,
                    "Browser profile, tab or page changed; click Open again"
                );
                let admitted = {
                    let engine = self
                        .engine
                        .try_lock()
                        .map_err(|_| anyhow::anyhow!("App is busy; click Open again"))?;
                    engine.admit_prepared_history(history.prepared)?
                };
                self.browser
                    .as_mut()
                    .context("Browser unavailable")?
                    .open_saved_history(&history.binding, admitted, window, cx)?;
                Ok(())
            })();
            match result {
                Ok(()) => {
                    self.browser_panels.insert(history.binding.snapshot.thread);
                    self.browser_settings_open = false;
                    self.settings_open = false;
                    self.sync_browser_settings_route(cx);
                    cx.notify();
                }
                Err(error) => self.browser_settings_panel.update(cx, |panel, cx| {
                    panel.history_open_error(error.to_string(), cx)
                }),
            }
        }
        if let Some(bookmark) = bookmark
            && visible
            && (settings_visible || pane_library)
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
                    self.browser_library_thread = None;
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
        let credential_replies = self.credential_panel.update(cx, |panel, cx| {
            panel.set_context(
                visible.then(|| thread.clone()).flatten(),
                page,
                available,
                cx,
            );
            panel.poll(cx);
            panel.browser_replies()
        });
        self.browser_replies.extend(credential_replies);
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
        let visible_thread = self
            .chat_visible()
            .then(|| {
                self.selected.as_ref().and_then(|thread| {
                    thread["id"]
                        .as_str()
                        .and_then(|id| uuid::Uuid::parse_str(id).ok())
                })
            })
            .flatten();
        // GPUI supplies only foreground window/visible conversation. The
        // configured native notification worker fills available OS activity
        // observations; the UI and fake backends never query the host here.
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
        self.poll_project_defaults(window, cx);
        self.tick_schedule_times(cx);
        self.poll_git_controls(window, cx);
        self.open_target_children
            .retain_mut(|child| matches!(child.try_wait(), Ok(None)));
        if self.sidebar_preferences.retry(&self.engine) {
            self.show_archived = self.sidebar_preferences.flag("showsArchivedThreads");
            self.show_snoozed = self.sidebar_preferences.flag("showsSnoozedThreads");
            self.refresh(cx);
        }
        // A blur or thread switch can land while the engine is busy. Retry the
        // in-memory draft as soon as the engine is free instead of leaving it
        // only in the window until the user notices the retry banner.
        if !self.pending_drafts.is_empty() && self.engine.try_lock().is_ok() {
            self.flush_pending_drafts();
        }
        let menu_quit = self
            .quit_requested
            .swap(false, std::sync::atomic::Ordering::AcqRel);
        self.image_validation_tasks.retain(|task| !task.is_ready());
        self.navigation_tasks.retain(|task| !task.is_ready());
        self.poll_palette_search(cx);
        let native_quit = self
            .native_quit
            .as_ref()
            .is_some_and(|guard| guard.take_requested());
        if native_quit {
            quit_shortcut::cancel(cx);
            self.native_quit_observed = true;
        }
        if menu_quit {
            self.native_quit_observed = true;
            if let Some(guard) = &self.native_quit {
                guard.observe_user_quit();
            }
        }
        if (menu_quit || native_quit)
            && !self.block_voice_close(window, cx)
            && !self.block_provider_configuration_close(window, cx)
        {
            self.request_quit(window, cx);
        }
        // Persistence must precede either close path, including API app.quit.
        let drafts_saved = self.flush_pending_drafts();
        self.sync_media_context(cx);
        self.poll_media_parent(cx);
        self.poll_thread_bulk(window, cx);
        self.instructions_panel.update(cx, |panel, cx| {
            panel.poll_initial_instruction_setup(cx);
            panel.poll_instruction_git(cx);
        });
        self.poll_sidebar_lifecycle(window, cx);
        self.poll_inspector_follow(cx);
        self.poll_composer_file_picker(window, cx);
        self.remote_panel.update(cx, |panel, cx| panel.poll(cx));
        self.poll_composer_suggestions(window, cx);
        if self.engine.try_lock().is_ok_and(|engine| engine.shutdown) {
            self.media.shutdown_requested = true;
        }
        if self.media.shutdown_requested {
            quit_shortcut::cancel(cx);
            // Phones are disconnected before the engine is saved and stopped.
            self.remote_panel.update(cx, |panel, _| panel.shut_down());
            if self.poll_global_quit(window, cx) && self.updater_quit_ready(cx) {
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
            self.appshots.close();
            self.shutdown_computer_use(cx);
            self.sync_media_context(cx);
            if drafts_saved
                && cookies_ready
                && self.media_shutdown_ready(cx)
                && self.appshots.drained()
                && self.computer_use_shutdown_ready()
                && self.thread_bulk.closed_and_drained()
                && self.composer_files.closed_and_drained()
                && self.composer_suggestions.closed_and_drained()
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
            } else if !self.composer_files.closed_and_drained() {
                self.status="Closing waits for owned project-file discovery/attachment work and its receipt.".into();
                cx.notify();
            } else if !self.composer_suggestions.closed_and_drained() {
                self.status = "Closing waits for the pull request list read to finish.".into();
                cx.notify();
            } else if !self.thread_bulk.closed_and_drained() {
                self.status = "Closing waits for the owned sidebar operation to finish and join. Committed changes retain their receipt.".into();
                cx.notify();
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
        self.poll_app_shell(window, cx);
        self.poll_appshots(window, cx);
        self.poll_computer_use(cx);
        self.sync_composer_selection(window, cx);
        self.poll_selection_catalog(cx);
        self.sync_palette(window, cx);
        self.sync_notification_activity(window, cx);
        // A successful creation is retained by ID until its read succeeds.
        // Retry navigation only, never the create request or a Send.
        if let Some(created) = self.created_bot_thread_to_focus.clone() {
            if self
                .selected
                .as_ref()
                .is_none_or(|thread| thread["id"] != created)
            {
                self.select(&created, window, cx);
            }
        }
        if self
            .created_bot_thread_to_focus
            .as_deref()
            .is_some_and(|id| {
                self.selected
                    .as_ref()
                    .is_some_and(|thread| thread["id"] == id)
            })
            && self.find_context_available()
            && !self.command_palette.read(cx).is_open()
            && window.is_window_active()
        {
            self.created_bot_thread_to_focus = None;
            self.composer.read(cx).focus_handle(cx).focus(window, cx);
        }
        if let Ok(mut engine) = self.engine.try_lock() {
            if engine.shutdown {
                self.media.shutdown_requested = true;
                return;
            }
            if let Some(selected) = &self.pending_native_selection {
                match engine
                    .store
                    .remember_native_selected_thread(selected.as_deref())
                {
                    Ok(_) => self.pending_native_selection = None,
                    Err(error) => {
                        self.status = format!("Unable to remember conversation selection: {error}");
                    }
                }
            }
            if !self.media.close_requested && !self.media.shutdown_requested {
                if let Err(error) = engine.native_wake_due_snoozes() {
                    self.status = format!("Snoozed conversations could not wake: {error}");
                }
            }
            engine.ui_available = self.browser.is_some();
            let selected = self.selected.as_ref().map(|thread| text(thread, "id"));
            let pending_open_compatible = engine
                .requested_open
                .as_ref()
                .is_none_or(|requested| Some(requested.as_str()) == selected.as_deref());
            if pending_open_compatible
                && engine.active_thread() != selected.as_deref()
                && let Err(error) = engine.set_active_thread(selected)
            {
                let _ = engine.set_active_thread(None);
                self.status = format!("Selected conversation authority unavailable: {error}");
            }
            if self.attachment_root.is_none() {
                self.attachment_root = engine.store.data_directory().ok();
            }
        }
        self.restore_startup_selection(window, cx);
        self.refresh_awake_status(cx);
        self.apply_appearance(window, cx);
        if self.navigation_last_clock.elapsed() >= Duration::from_secs(30) {
            self.navigation_last_clock = Instant::now();
            // A project folder may have been moved or deleted meanwhile.
            self.missing_project_folders = navigation::missing_project_folders(&self.projects);
            cx.notify();
        }
        self.poll_window_chrome(window, cx);
        self.poll_sidebar_message_search(cx);
        // Opening Settings › Usage reads saved local history, as Swift's `appeared()`;
        // plan limits wait for Refresh.
        let usage_visible =
            self.settings_open && self.settings_section == settings::SettingsSection::Usage;
        if self
            .usage_history
            .dashboard
            .appeared(usage_visible, chrono::Utc::now())
        {
            self.usage_history.load_dashboard();
            cx.notify();
        }
        if self.usage_history.poll(cx) {
            cx.notify();
        }
        self.codex_limits.set_context(self.selected.as_ref(), cx);
        self.codex_limits.poll(cx);
        if let Some(thread) = &self.selected {
            let draft = self.committed_composer_draft(cx);
            self.steering.observe_draft(&text(thread, "id"), &draft);
        }
        if self.steering.poll() {
            cx.notify();
        }
        self.poll_composer_follow_ups(window, cx);
        self.poll_browser(window, cx);
        self.sync_browser_settings(window, cx);
        self.poll_codex_account_settings(cx);
        self.sync_github_context(cx);
        self.sync_credentials(cx);
        self.sync_terminal_workspace(window, cx);
        if let Ok(status) = call(&self.engine, "app.status", json!({})) {
            self.window_chrome.observe_status(&status);
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
            let starting = status["starting"]
                .as_array()
                .map(|ids| {
                    ids.iter()
                        .filter_map(|id| id.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default();
            self.set_starting_runs(starting, cx);
            if was_running != is_running {
                self.transcript_list
                    .splice(0..self.transcript_count, self.transcript_count);
                cx.notify();
            }
            self.observe_thread_activity(&status, window, cx);
            if was_running
                && selected_thread
                    .as_ref()
                    .is_some_and(|id| !self.running.contains(id))
                && self.status == "Agent running · approval required for changes"
            {
                self.status = "Agent turn ended.".into();
                cx.notify();
            }
            app_shell::set_badge(app_shell::pending_approvals(&status), cx);
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
                        self.refresh_turn_changes();
                    } else {
                        return; // Retry this revision after the worker releases the engine.
                    }
                }
                if self.refresh(cx) {
                    self.revision = revision;
                }
                self.sync_diff_thread(true, cx);
            } else {
                self.sync_diff_thread(false, cx);
            }
            self.tick_turn_clock(cx);
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
        self.sync_approval_replies(&thread, &requests, window, cx);
        if self.pending_requests != requests {
            self.pending_requests = requests;
            // A waiting approval replaces the live line below the last row.
            self.redraw_live_row(cx);
            cx.notify();
        }
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
    fn pending_pane(&self, window: &Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        if self.pending_requests.is_empty() {
            return None;
        }
        let thread = self.selected.as_ref().map(|v| text(v, "id"))?;
        // Approvals show one at a time in Swift's banner; questions keep their cards.
        let banner = self.approval_banner(window, cx);
        let mut cards = Vec::new();
        for request in &self.pending_requests {
            if request["method"] != "item/tool/requestUserInput" {
                continue;
            }
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
            let actions = {
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
            };
            // Only the request details scroll. Decisions stay in a separate
            // footer, reachable even when questions/options exceed the pane.
            cards.push(card.child(body).child(actions));
        }
        let questions = (!cards.is_empty()).then(|| {
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
        });
        Some(
            div()
                .flex()
                .flex_col()
                .flex_shrink_0()
                .children(banner)
                .children(questions)
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
        self.send_selected(false, window, cx);
    }
    fn send_selected(&mut self, alternate: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.voice.preview.is_some() {
            self.cancel_composer_dictation(cx);
        }
        // A hidden composer may retain focus after opening the Git pane.
        if !self.chat_visible() {
            return;
        }
        // Sending nothing while a plan is offered implements it, as in Swift.
        if self.composer.read(cx).value().trim().is_empty() && self.proposed_plan().is_some() {
            self.implement_plan(window, cx);
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
        }
        if self.selection_send_blocked() {
            self.retry_selected_account_readiness();
            self.status = self.selected_account_wait_status().into();
            cx.notify();
            return;
        }
        if self
            .selected
            .as_ref()
            .is_some_and(|v| self.running.contains(&text(v, "id")))
        {
            self.send_follow_up(alternate, cx);
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
                Err(e) => {
                    self.retry_selected_account_readiness();
                    self.status = e.to_string();
                }
            }
        }
        cx.notify();
    }
    fn toggle_item_expanded(&mut self, source: &str, item: &str, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref().filter(|v| v["id"] == source) else {
            return;
        };
        let Some(index) = thread["items"]
            .as_array()
            .and_then(|items| items.iter().position(|v| v["id"] == item))
        else {
            return;
        };
        if self
            .find_revealed
            .as_ref()
            .is_some_and(|(thread, id, _)| thread == source && id == item)
        {
            self.find_revealed = None;
            self.find_pending = None;
            self.expanded.remove(&index);
        } else if !self.expanded.remove(&index) {
            self.expanded.insert(index);
        }
        self.transcript_list.splice(index..index + 1, 1);
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
        // Swift's turn layout: work folded under "Worked for…", rows that
        // never draw, and headers below the messages that open or split turns.
        // A find target stays drawn even inside a folded turn.
        let plan = self.turn_plan(index);
        if plan.hidden && !find_revealed {
            return self.turn_decorated(index, div().into_any_element(), None, cx);
        }
        let body = text(item, "text");
        // The active find target uses the existing expanded native body so a
        // later-line match remains visible. Clearing Find remounts the compact row.
        if kind == "notice" && !find_revealed {
            let row = self.notice_row(&source_id, &item_id, body, window, cx);
            return self.turn_decorated(index, row, plan.header, cx);
        }
        if kind == "tool" && !find_revealed {
            let item = item.clone();
            let expanded = self.expanded.contains(&index);
            let row = self.tool_row(&source_id, &item_id, &item, expanded, window, cx);
            return self.turn_decorated(index, row, plan.header, cx);
        }
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
            "reasoning" => format!(
                "{} · {}",
                presentation::provider_name(&provider),
                work_header
                    .as_ref()
                    .map(|header| header.title.as_str())
                    .unwrap_or("Reasoning")
            ),
            "tool" => work_header
                .as_ref()
                .map(|header| header.title.clone())
                .unwrap_or_else(|| "Tool activity".into()),
            "error" => "Error".to_owned(),
            "system" => "Conversation update".to_owned(),
            _ => kind.clone(),
        };
        let action_excerpt: String = text(item, "text").chars().take(72).collect();
        // Only Rust-ingested metadata is previewable. Legacy imported media is
        // deliberately not opened through arbitrary historical paths.
        let images = item["rustImages"].as_array().cloned().unwrap_or_default();
        let context_pane = self.transcript_context_pane(&source_id, &item_id, item, cx);
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
        let disclosure =
            collapsible.then(|| {
                let source = source_id.clone();
                let item = item_id.clone();
                Button::new(SharedString::from(format!("expand-{source_id}-{item_id}")))
                    .accessibility_id(SharedString::from(format!("expand-{source_id}-{item_id}")))
                    .label(if expanded { "Collapse" } else { "Expand" })
                    .ghost()
                    .compact()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.toggle_item_expanded(&source, &item, cx)
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
            let edit_action = if self.turn_changes.rewinds_in_place(&source_id) {
                self.edit_from_here_button(
                    &source_id,
                    &item_id,
                    &action_excerpt,
                    source_running,
                    cx,
                )
            } else {
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
                }))
            };
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
        let row = div()
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
            .into_any_element();
        let row = self.with_turn_changes(index, row, cx);
        self.turn_decorated(index, row, plan.header, cx)
    }
    fn terminal(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.toggle_terminal(None, window, cx);
    }
    /// With `script`, the panel this opens runs that project script in a new
    /// tab instead of showing or starting a plain shell.
    fn toggle_terminal(
        &mut self,
        script: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.clear_inspector_placeholders();
        if self.selected.is_none() {
            return;
        }
        self.terminal_open = !self.terminal_open;
        if self.terminal_open && self.terminal_on_right() {
            self.workspace_open = false;
            self.close_schedule_surface();
            self.ensure_terminal_space(window);
            if self
                .selected
                .as_ref()
                .is_some_and(|thread| self.browser_panels.contains(&text(thread, "id")))
            {
                self.browser_action(BrowserAction::Hide, None, cx);
                if let Some(thread) = &self.selected {
                    self.browser_panels.remove(&text(thread, "id"));
                }
                if let Some(browser) = &mut self.browser {
                    browser.set_thread_visible(None, cx);
                }
            }
        }
        self.sync_terminal_workspace(window, cx);
        if self.terminal_open
            && let Some(id) = &self.terminal_visible_thread
            && let Some(workspace) = self.terminal_workspaces.get(id).cloned()
        {
            workspace.update(cx, |workspace, cx| match script {
                Some(script) => workspace.run_script(script, window, cx),
                None => workspace.activate(window, cx),
            });
        }
        if self.terminal_on_right() {
            self.remember_current_inspector(cx);
        }
        cx.notify();
    }
    fn sync_terminal_workspace(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // Placement changes move the retained entity. This callback has the
        // actual main window, unlike an edit made inside native Settings.
        if self
            .terminal_layout
            .observe_placement(terminal_layout::placement(&self.settings))
            && self.terminal_open
        {
            if self.terminal_on_right() {
                self.workspace_open = false;
                self.close_schedule_surface();
                self.hide_selected_browser_surface(cx);
                self.ensure_inspector_space(window);
                self.remember_inspector_choice(Some(inspector_follow::SavedPanel::Terminal), cx);
            } else {
                // Swift removes the thread's terminal inspector choice when
                // that actual open controller moves into its bottom drawer.
                self.remember_inspector_choice(None, cx);
            }
        }
        let selected = self.selected.as_ref().map(|thread| text(thread, "id"));
        let visible = self.terminal_open
            && self.chat_visible()
            && (!self.terminal_on_right()
                || self.chat_inspector_panel() == Some(chat_inspector::Panel::Terminal))
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
            let workspace = if let Some(workspace) = self.terminal_workspaces.get(&thread) {
                workspace.clone()
            } else {
                let workspace = cx.new(|cx| {
                    terminal_workspace::TerminalWorkspace::new(
                        self.engine.clone(),
                        thread.clone(),
                        window,
                        cx,
                    )
                });
                self._subscriptions.push(cx.subscribe_in(
                    &workspace,
                    window,
                    |this, workspace, event, window, cx| {
                        this.terminal_context_event(workspace, event, window, cx)
                    },
                ));
                self.terminal_workspaces
                    .insert(thread.clone(), workspace.clone());
                workspace
            };
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
        // Swift's palette floats about a sixth of the way down the window.
        let palette_top = (f32::from(window.viewport_size().height) * 0.16).max(64.);
        self.sync_context_details();
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
                .when(self.appshots.private_cleanup_pending(), |view| {
                    view.child(div().text_sm().child(self.appshots.outcome.clone()))
                        .child(
                            Button::new("quit-retry-appshot-cleanup")
                                .label("Retry capture cleanup")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.appshots.retry_private_cleanup();
                                    cx.notify();
                                })),
                        )
                })
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
        let import_visible = self.session_import_open;
        self.session_import_panel.update(cx, |panel, cx| {
            panel.set_project(import_project, cx);
            panel.set_visible(import_visible, cx);
        });
        self.sync_workspace_context(cx);
        self.sync_composer_selection(window, cx);
        if let Some(thread) = self.selected.as_mut()
            && let Some(draft) = self.pending_drafts.get(&text(thread, "id"))
        {
            thread["draft"] = json!(draft.text);
        }
        if let Some(v) = self.selected.as_ref() {
            let draft = text(v, "draft");
            if self.committed_composer_draft(cx) != draft {
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
        self.sync_terminal_resize(window);
        self.sync_thread_bulk(cx);
        self.sync_composer_file_picker(window, cx);
        self.sync_automatic_file_mentions(window, cx);
        self.sync_composer_suggestions(window, cx);
        if self.settings_window.is_none() {
            self.sync_keyboard_recording(window, cx);
        }
        let navigation_rail = self.navigation_rail(window, cx);
        let sidebar = self
            .thread_list_open
            .then(|| self.navigation_sidebar(&selected_id, window, cx));
        let title = self
            .selected
            .as_ref()
            .map(|v| text(v, "title"))
            .unwrap_or_else(|| "Welcome to Coincide".into());
        let entity = cx.entity();
        let jump_to_latest = !self.transcript_list.is_following_tail();
        let transcript = div()
            .on_children_prepainted(self.media_layout_observer(cx))
            .relative()
            .flex_1()
            .min_h(px(120.))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, _, _| this.record_appshot_interaction()),
            )
            .child(
                list(self.transcript_list.clone(), move |index, window, cx| {
                    entity.update(cx, |this, cx| this.message(index, window, cx))
                })
                .size_full(),
            )
            .when(jump_to_latest, |view| {
                view.child(
                    div()
                        .absolute()
                        .bottom(px(14.))
                        .left_0()
                        .right_0()
                        .flex()
                        .justify_center()
                        .child(
                            Button::new("jump-to-latest")
                                .label("Jump to Latest")
                                .icon(gpui_kit::assets::IconName::ArrowDown)
                                .compact()
                                .h(px(28.))
                                .rounded(px(14.))
                                .bg(self.color(0x202a3b))
                                .border_1()
                                .border_color(self.color(0x29303d))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.transcript_list.scroll_to_end();
                                    cx.notify();
                                })),
                        ),
                )
            });
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
        } else if self.settings_in_main_window() {
            self.settings_surface(cx)
        } else if self.global_schedules_route() {
            self.schedules_pane(cx)
        } else {
            transcript.into_any_element()
        };
        self.sync_inspector_browser_visibility(cx);
        // Swift reloads the pull requests as their panel appears.
        let pull_requests_visible = self.chat_inspector_panel()
            == Some(chat_inspector::Panel::Workspace)
            && self.github_open
            && !self.github_threads_open;
        self.github_panel
            .update(cx, |panel, cx| panel.set_visible(pull_requests_visible, cx));
        let inspector_pane = self.chat_inspector_surface(window, cx);
        let pending_pane = if self.chat_visible() {
            self.pending_pane(window, cx)
        } else {
            None
        };
        let draft_images = if self.chat_visible() {
            self.draft_images(window, cx)
        } else {
            None
        };
        let show_composer = self.chat_visible();
        let importing_images = self.attachment_import_threads.contains(&selected_id);
        let queue_pane = self.queue_pane(cx);
        let plan_card = if self.chat_visible() {
            self.plan_card(window, cx)
        } else {
            None
        };
        let implement_button = self.implement_button(cx);
        let historical_image = self.historical_image_overlay(cx);
        let terminal_bottom = self.terminal_surface(false, window, cx);

        let chat_column = div()
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
                    .when_some(terminal_bottom,|view,pane|view.child(pane))
                    .when(
                        show_composer
                            && self.selected.as_ref().is_some_and(|thread| {
                                thread["items"]
                                    .as_array()
                                    .is_some_and(|items| items.is_empty())
                            }),
                        |view| view.child(self.chat_welcome(cx)),
                    )
                    .when(show_composer, |view| {
                        view.child(
                            div()
                                .id("composer-column")
                                .w_full()
                                .flex()
                                .flex_col()
                                .items_center()
                                .justify_center()

                                .flex_shrink_0()
                                .overflow_hidden()
                                .px(px(presentation::CONTENT_GUTTER))
                                .py_3()
                                .child(
                                    self.composer_file_key_scope(div(), cx)
                                        .w_full()
                                        .min_w_0()
                                        .min_h_0()

                                        .flex()
                                        .flex_col()
                                        .max_w(px(presentation::CONTENT_WIDTH))
                                        .p_3()
                                        .rounded(px(22.))
                                        .bg(self.color(0x181d28))
                                        .border_1()
                                        .border_color(self.color(0x29303d))
                                        .when_some(plan_card, |view, card| view.child(card))
                                        .child(
                                            // The bounded accessory viewport shrinks independently of
                                            // the pinned textarea/actions. Keep a persistent thumb so
                                            // long selection forms do not require coarse wheel steps.
                                            div()
                                                .relative()
                                                .min_h_0()
                                                .max_h(px(160.))
                                                .flex_shrink_1()
                                                .when(self.composer_files.opened, |view| view.flex_shrink_0())
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
                                                        .when(self.composer_files.opened, |view| view.flex_shrink_0())
                                                        .overflow_y_scroll()
                                                        .when(self.composer_files.opened, |view| view.when_some(self.composer_file_pane(cx), |view, files| view.child(files)))
                                                        .when(!self.composer_files.opened, |view| view
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
                                                        }))
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
                                                        .accessibility_id("composer-input")
                                                        .aria_label("Message")
                                                        .appearance(false)
                                                        .bordered(false)
                                                        .h({
                                                            {
                                                                let state = self.composer.read(cx);
                                                                px(chat_layout::composer_height(
                                                                    state.display_map().wrap_row_count(),
                                                                    state.line_height().map(f32::from).unwrap_or(20.),
                                                                    f32::from(window.viewport_size().height),
                                                                ))
                                                            }
                                                        })
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
                                                .gap(px(6.))
                                                .mt_2()
                                                .when(!self.composer_files.opened, |view| view.child(self.composer_selection_footer(cx)))
                                                .child(
                                                    Button::new("attach-images")
                                                        .icon(gpui_kit::assets::IconName::Paperclip)
                                                        .accessibility_label(if importing_images {
                                                            "Importing images…"
                                                        } else {
                                                            "Attach images"
                                                        })
                                                        .tooltip(if importing_images { "Importing images…" } else { "Attach images" })
                                                        .compact().ghost()
                                                        .xsmall().h(px(26.)).rounded(px(7.))
                                                        .disabled(importing_images)
                                                        .on_click(cx.listener(|this, _, _, cx| {
                                                            this.attach_images(cx)
                                                        })),
                                                )
                                                .child(self.composer_voice_control(cx))
                                                .when(self.running.contains(&selected_id), |view| view.child(self.composer_stop_button(cx)))
                                                .when(implement_button.is_none(), |view| view.child(
                                                    Button::new("send")
                                                        .primary()
                                                        .disabled(importing_images || self.selection_send_blocked())
                                                        .accessibility_label(composer_follow_up_mount::dispatch_label(self.composer_send_dispatch(false)))
                                                        .tooltip(composer_follow_up_mount::dispatch_label(self.composer_send_dispatch(false)))
                                                        .icon(composer_follow_up_mount::dispatch_icon(self.composer_send_dispatch(false)))
                                                        .w(px(28.)).h(px(28.)).rounded(px(14.)).p_0()
                                                        .on_click(cx.listener(
                                                            |this, event: &gpui_kit::ClickEvent, window, cx| {
                                                                let modifiers = event.modifiers();
                                                                let alternate = if cfg!(target_os = "macos") { modifiers.platform } else { modifiers.control };
                                                                this.send_selected(alternate, window, cx)
                                                            },
                                                        )),
                                                ))
                                                .when_some(implement_button, |view, button| view.child(button))

                                        )
                                        .when(!self.composer_files.opened && self.status != "Rust preview · separate data store", |view| view.child(
                                            div()
                                                .id("composer-status")
                                                .mt_2()
                                                .max_h(px(32.))
                                                .flex_shrink_0()
                                                .overflow_y_scroll()
                                                .text_sm()
                                                .text_color(self.color(0xe4e9f2).opacity(0.7))
                                                .child(self.status.clone()),
                                        )),
                                )
                                .when_some(self.branch_toolbar(cx), |view, toolbar| view.child(toolbar)),
                        )
                    }).into_any_element();
        div()
            .relative()
            .capture_key_up(
                cx.listener(|this, event, window, cx| this.voice_key_up(event, window, cx)),
            )
            .on_modifiers_changed(
                cx.listener(|this, event, window, cx| this.voice_modifiers(event, window, cx)),
            )
            .capture_key_down(cx.listener(|this, event, window, cx| {
                if !this.voice_key_down(event, window, cx)
                    && !this.escape_dismisses_popover(event, cx)
                    && !this.sidebar_search_shortcut(event, window, cx)
                    && !this.inbox_undo_shortcut(event, window, cx)
                    && !this.context_details_shortcut(event, window, cx)
                    && !this.project_defaults_key(event, window, cx)
                    && !this.project_script_editor_key(event, window, cx)
                    && !this.historical_image_shortcut(event, window, cx)
                    && !this.reply_selection_shortcut(event, window, cx)
                {
                    this.app_shortcut(event, window, cx);
                }
            }))
            .on_action(
                cx.listener(|this, _: &app_menu::AddSelectionToComposer, window, cx| {
                    this.add_selection_to_composer(window, cx)
                }),
            )
            .flex()
            .size_full()
            .bg(self.color(0x10141c))
            .text_color(self.color(0xe4e9f2))
            .child(navigation_rail)
            .when_some(sidebar, |view, sidebar| view.child(sidebar))
            .child(chat_inspector::columns(chat_column, inspector_pane))
            .when_some(self.composer_popover(window, cx), |view, popover| {
                view.child(popover)
            })
            .when_some(historical_image, |view, image| view.child(image))
            .when_some(self.project_defaults_form(cx), |view, form| {
                view.child(form)
            })
            .when_some(self.project_script_editor(cx), |view, form| {
                view.child(form)
            })
            .when_some(self.git_modal(cx), |view, modal| view.child(modal))
            .when_some(self.context_details_overlay(cx), |view, details| {
                view.child(details)
            })
            .when_some(self.link_menu_overlay(), |view, menu| view.child(menu))
            .when(self.command_palette.read(cx).is_open(), |view| {
                view.child(
                    div()
                        .absolute()
                        .inset_0()
                        .flex()
                        .justify_center()
                        .pt(px(palette_top))
                        .px(px(24.))
                        // A click beside the palette closes it, as the Swift
                        // panel closes when it loses focus.
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(|this, _, window, cx| {
                                cx.stop_propagation();
                                this.dismiss_palette(window, cx);
                            }),
                        )
                        .child(
                            div()
                                .w_full()
                                .max_w(px(640.))
                                .max_h_full()
                                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                                .child(self.command_palette.clone()),
                        ),
                )
            })
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
/// Finder launches inherit launchd's minimal PATH, while agent CLIs live wherever
/// the user's shell puts them. Ask the login shell once, bounded, and merge the
/// directories Coincide also searches before any provider discovery starts.
#[cfg(unix)]
fn adopt_login_shell_path() {
    use std::{
        io::Read,
        process::{Command, Stdio},
        time::{Duration, Instant},
    };
    const START: &str = "__COINCIDE_PATH_START__";
    const END: &str = "__COINCIDE_PATH_END__";
    let shell = std::env::var("SHELL")
        .ok()
        .filter(|shell| std::path::Path::new(shell).is_file())
        .unwrap_or_else(|| "/bin/zsh".into());
    let current_path = std::env::var("PATH").unwrap_or_default();
    // A terminal launch already carries the user's PATH; only Finder's minimal
    // environment needs the login shell.
    let needs_shell = !current_path
        .split(':')
        .any(|entry| entry == "/opt/homebrew/bin")
        && !current_path
            .split(':')
            .any(|entry| entry == "/usr/local/bin");
    let mut from_shell = None;
    if needs_shell
        && let Ok(mut child) = Command::new(&shell)
            .args([
                "-ilc",
                &format!("printf '%s%s%s' '{START}' \"$PATH\" '{END}'"),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
    {
        let deadline = Instant::now() + Duration::from_millis(2500);
        loop {
            match child.try_wait() {
                Ok(Some(_)) => break,
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(25));
                }
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break;
                }
            }
        }
        if let Some(mut output) = child.stdout.take() {
            let mut text = String::new();
            let _ = output.take(64 * 1024).read_to_string(&mut text);
            if let Some(start) = text.find(START)
                && let Some(end) = text[start..].find(END)
            {
                let path = &text[start + START.len()..start + end];
                if !path.is_empty() && path.len() <= 32 * 1024 {
                    from_shell = Some(path.to_owned());
                }
            }
        }
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let extras = [
        "/opt/homebrew/bin".to_owned(),
        "/opt/homebrew/sbin".to_owned(),
        "/usr/local/bin".to_owned(),
        format!("{home}/.local/bin"),
        format!("{home}/.bun/bin"),
        format!("{home}/.npm-global/bin"),
        format!("{home}/.cargo/bin"),
        format!("{home}/.grok/bin"),
        format!("{home}/.opencode/bin"),
        format!("{home}/.cursor/bin"),
        "/usr/bin".to_owned(),
        "/bin".to_owned(),
        "/usr/sbin".to_owned(),
        "/sbin".to_owned(),
    ];
    let current = current_path.clone();
    let mut seen = std::collections::HashSet::new();
    let mut parts = Vec::new();
    for entry in from_shell
        .iter()
        .flat_map(|path| path.split(':'))
        .chain(current.split(':'))
        .chain(extras.iter().map(String::as_str))
        .filter(|entry| !entry.is_empty())
    {
        if seen.insert(entry.to_owned()) {
            parts.push(entry.to_owned());
        }
    }
    let merged = parts.join(":");
    if merged != current {
        // Called before any other thread or provider process exists.
        unsafe { std::env::set_var("PATH", merged) };
    }
}
#[cfg(not(unix))]
fn adopt_login_shell_path() {}
fn main() -> Result<()> {
    adopt_login_shell_path();
    let arguments = std::env::args_os().skip(1).collect::<Vec<_>>();
    if arguments
        .first()
        .is_some_and(|argument| argument == "--native-provider-setup")
    {
        anyhow::ensure!(
            arguments.len() == 2,
            "Native setup requires one sealed handoff path"
        );
        let code = coincide_core::provider_configuration::run_native_provider_setup(
            std::path::Path::new(&arguments[1]),
        )?;
        std::process::exit(code);
    }
    let data = control::data_directory()?;
    // A second copy hands over to the one already running and quits, as
    // Swift's SecondInstance does.
    if app_shell::hand_off(&data.join("control.sock")) {
        return Ok(());
    }
    let store = Store::open(&data.join("coincide.sqlite"))?;
    let saved_frame = window_chrome::saved_frame(&store);
    let media_data = store.data_directory()?;
    let media_config = coincide_core::legacy_media_service::ServiceConfig {
        database_path: media_data.join("coincide.sqlite"),
        expected_data_directory: media_data,
    };
    let engine = Engine::new(store);
    let native_editors = engine.native_ui_editors();
    let engine = Arc::new(Mutex::new(engine));
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
    let application = application.with_assets(assets::CoincideAssets);
    // Clicking the Dock icon brings the main window back after it was closed.
    application.on_reopen(reopen_main_window);
    application.run(move |cx| {
        gpui_kit::init(cx);
        composer_file_picker::init(cx);
        sidebar_keys::init(cx);
        composer_follow_up_mount::init(cx);
        let quit_requested = app_menu::install(cx);
        app_shell::install(cx);
        transcript::init(cx);
        Theme::change(ThemeMode::Dark, None, cx);
        cx.set_global(Launch {
            engine,
            native_editors,
            quit_requested,
            control_owner,
            profile_dir: data.join("browser-profile"),
            media_config,
            saved_frame,
        });
        open_main_window(cx).expect("Unable to open Coincide window");
        cx.activate(true);
    });
    Ok(())
}

/// What a main window is made from, kept so the Dock can open it again.
#[derive(Clone)]
struct Launch {
    engine: SharedEngine,
    native_editors: coincide_core::native_ui_edits::NativeUiEditors,
    quit_requested: Arc<std::sync::atomic::AtomicBool>,
    control_owner: Arc<Mutex<control::Server>>,
    profile_dir: std::path::PathBuf,
    media_config: coincide_core::legacy_media_service::ServiceConfig,
    saved_frame: Option<window_chrome::SavedFrame>,
}
impl Global for Launch {}
/// The open main window, for the Dock to bring forward.
struct MainWindow(AnyWindowHandle, WeakEntity<Coincide>);
impl Global for MainWindow {}

fn open_main_window(cx: &mut App) -> Result<()> {
    let launch = cx
        .try_global::<Launch>()
        .cloned()
        .context("Coincide has not launched")?;
    let (bounds, display_id) = window_chrome::opening_bounds(launch.saved_frame.as_ref(), cx);
    let (handle, root) = gpui_kit::open_window(
        WindowOptions {
            window_bounds: Some(bounds),
            display_id,
            window_min_size: Some(size(px(820.), px(520.))),
            ..Default::default()
        },
        cx,
        |window, cx| {
            window.set_window_title("Coincide Rust Preview");
            cx.new(|cx| {
                Coincide::new(
                    launch.engine,
                    launch.native_editors,
                    launch.quit_requested,
                    launch.control_owner,
                    launch.profile_dir,
                    launch.media_config,
                    window,
                    cx,
                )
            })
        },
    )?;
    cx.set_global(MainWindow(handle, root.downgrade()));
    Ok(())
}

/// Swift `applicationShouldHandleReopen`: the main window comes forward, or a
/// new one opens when it was closed. Never while quitting.
fn reopen_main_window(cx: &mut App) {
    let open = cx.try_global::<MainWindow>().and_then(|main| {
        (main.1.upgrade().is_some() && cx.windows().contains(&main.0)).then_some(main.0)
    });
    if let Some(main) = open {
        let _ = main.update(cx, |_, window, _| window.activate_window());
    } else if !cx
        .try_global::<Launch>()
        .is_some_and(|launch| launch.engine.try_lock().is_ok_and(|engine| engine.shutdown))
        && let Err(error) = open_main_window(cx)
    {
        eprintln!("Unable to reopen the Coincide window: {error}");
        return;
    }
    cx.activate(true);
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
