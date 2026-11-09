//! What Swift's MainWindowController menu actions do, shared by shortcuts, the
//! menu bar and the command palette. Each command reuses the existing Rust
//! controller for its surface; none adds a second owner or engine path.
use super::*;
use app_menu::AppAction;
use keyboard_settings::Command as K;

/// The file manager targets `open_targets::installed` offers on each platform.
const FILE_MANAGERS: [&str; 3] = ["com.apple.finder", "windows.explorer", "linux.files"];

impl Coincide {
    pub(super) fn selected_id(&self) -> Option<String> {
        self.selected
            .as_ref()
            .map(|thread| text(thread, "id"))
            .filter(|id| !id.is_empty())
    }
    pub(super) fn selected_running(&self) -> bool {
        self.selected_id()
            .is_some_and(|id| self.running.contains(&id))
    }
    pub(super) fn file_manager_target(&self) -> Option<open_targets::Target> {
        self.open_targets
            .iter()
            .find(|target| FILE_MANAGERS.contains(&target.id))
            .cloned()
    }
    pub(super) fn diff_open(&self) -> bool {
        self.workspace_open && !self.github_open && !self.github_threads_open
    }
    pub(super) fn pull_requests_open(&self) -> bool {
        self.workspace_open && (self.github_open || self.github_threads_open)
    }
    pub(super) fn browser_panel_open(&self) -> bool {
        self.selected_id()
            .is_some_and(|id| self.browser_panels.contains(&id))
    }
    /// Whether a command can run now; its menu item and palette row follow it.
    pub(super) fn keyboard_command_available(&self, command: K) -> bool {
        let thread = self.selected.is_some();
        match command {
            K::OpenInEditor => {
                self.open_folder().is_some()
                    && open_targets::preferred(&self.open_targets, &self.settings).is_some()
            }
            K::RevealInFinder => {
                self.open_folder().is_some() && self.file_manager_target().is_some()
            }
            K::CopyPath => self.open_folder().is_some(),
            K::Terminal => thread && self.chat_visible(),
            K::Stop => self.selected_running(),
            K::PreviousThread | K::NextThread | K::Jump(_) => !self.threads.is_empty(),
            K::Diff
            | K::ChooseModel
            | K::ReasoningEffort
            | K::AccessMode
            | K::PlanMode
            | K::Rename
            | K::Pin
            | K::Archive
            | K::Delete => thread,
            K::NewThread
            | K::NewChat
            | K::AddProject
            | K::AddToComposer
            | K::SearchThreads
            | K::Sidebar
            | K::Schedules
            | K::Palette
            | K::Larger
            | K::Smaller
            | K::FontReset
            | K::ShowArchive
            | K::ReportIssue
            | K::RequestFeature => true,
        }
    }
    /// Show the Git workspace's local diff or its pull requests, or hide it
    /// when that view is already showing (the toolbar's Git workspace button).
    pub(super) fn toggle_workspace_surface(
        &mut self,
        pull_requests: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let showing = if pull_requests {
            self.pull_requests_open()
        } else {
            self.diff_open()
        };
        self.clear_inspector_placeholders();
        self.session_import_open = false;
        if showing {
            self.workspace_open = false;
        } else {
            self.workspace_open = true;
            self.github_open = pull_requests;
            self.github_threads_open = false;
            self.ensure_inspector_space(window);
            self.hide_selected_browser_surface(cx);
            if self.terminal_on_right() {
                self.terminal_open = false;
            }
            self.close_schedule_surface();
        }
        self.hide_inline_settings();
        self.remember_current_inspector(cx);
        self.sync_workspace_context(cx);
        self.sync_github_context(cx);
    }
    fn step_thread(&mut self, step: i32, window: &mut Window, cx: &mut Context<Self>) {
        let rows = self.bulk_sidebar_binding(cx).rows;
        let ids = rows.iter().map(|row| row.0.as_str()).collect::<Vec<_>>();
        let selected = self
            .selected
            .as_ref()
            .and_then(|thread| thread["id"].as_str());
        if let Some(id) = navigation::adjacent_sidebar_row(&ids, selected, step).map(str::to_owned)
        {
            self.select(&id, window, cx);
        }
    }
    fn open_settings_section(
        &mut self,
        section: settings::SettingsSection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.open_settings_panel(window, cx);
        self.navigate_settings_section(section, window, cx);
    }
    pub(super) fn run_keyboard_command(
        &mut self,
        command: K,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.keyboard_command_available(command) {
            return;
        }
        match command {
            K::NewThread => self.new_thread(window, cx),
            K::NewChat => self.new_thread_in_project(navigation::NO_PROJECT_ID, window, cx),
            K::AddProject => {
                self.open_project_form(project_management::Mode::Add, None, window, cx)
            }
            K::OpenInEditor => {
                if let Some(target) =
                    open_targets::preferred(&self.open_targets, &self.settings).cloned()
                {
                    self.open_in_target(target, false, window, cx);
                }
            }
            K::RevealInFinder => {
                if let Some(target) = self.file_manager_target() {
                    self.open_in_target(target, false, window, cx);
                }
            }
            K::AddToComposer => self.add_selection_to_composer(window, cx),
            K::SearchThreads => {
                if !self.thread_list_open {
                    self.toggle_sidebar(window, cx);
                }
                self.search.read(cx).focus_handle(cx).focus(window, cx);
            }
            K::Sidebar => self.toggle_sidebar(window, cx),
            K::Terminal => self.terminal(window, cx),
            K::Diff => self.toggle_workspace_surface(false, window, cx),
            K::Schedules => {
                self.hide_inline_settings();
                self.workspace_open = false;
                self.session_import_open = false;
                if self.schedules_open {
                    self.schedules_open = false;
                } else {
                    self.open_global_schedules(cx);
                }
            }
            K::Palette => self.toggle_palette(window, cx),
            K::Larger | K::Smaller | K::FontReset => {
                let size = match command {
                    K::Larger => (self.conversation_font_size() + 1.).min(24.),
                    K::Smaller => (self.conversation_font_size() - 1.).max(10.),
                    _ => 13.,
                };
                self.change_setting("fontSize", json!(size), window, cx);
            }
            K::ShowArchive => {
                self.open_settings_section(settings::SettingsSection::Archive, window, cx)
            }
            K::Stop => {
                if let Some(id) = self.selected_id()
                    && let Err(error) = call(&self.engine, "agent.stop", json!({"threadId":id}))
                {
                    self.status = error.to_string();
                }
            }
            K::PreviousThread => self.step_thread(-1, window, cx),
            K::NextThread => self.step_thread(1, window, cx),
            K::Jump(_) => {
                let index = command.jump_index().unwrap_or(1) - 1;
                if let Some((id, _, _)) = self.bulk_sidebar_binding(cx).rows.get(index).cloned() {
                    self.select(&id, window, cx);
                }
            }
            K::ChooseModel => self.open_composer_picker(composer_selection::PickerFacet::Model, cx),
            K::ReasoningEffort => {
                self.open_composer_picker(composer_selection::PickerFacet::Effort, cx)
            }
            K::AccessMode => self.open_composer_picker(composer_selection::PickerFacet::Access, cx),
            K::PlanMode => {
                // Interaction mode is saved through the composer's selection
                // draft, so this opens its Plan/Build choice to apply.
                self.open_composer_picker(composer_selection::PickerFacet::Mode, cx);
                self.status = "Choose Plan or Build, then apply the selection.".into();
            }
            K::Rename => self.begin_rename(window, cx),
            K::Pin => self.toggle("isPinned", cx),
            K::Archive => self.request_archive(window, cx),
            K::CopyPath => {
                if let Some(path) = self.open_folder() {
                    cx.write_to_clipboard(ClipboardItem::new_string(path.display().to_string()));
                    self.status = "Copied the thread’s folder path.".into();
                }
            }
            K::Delete => {
                if let Some(id) = self.selected_id() {
                    self.sidebar_delete_review(id, cx);
                }
            }
            K::ReportIssue | K::RequestFeature => {
                if let Some((_, url, _)) = app_menu::HELP_LINKS
                    .iter()
                    .flat_map(|group| group.iter())
                    .find(|(_, _, bound)| *bound == Some(command))
                {
                    cx.open_url(url);
                }
            }
        }
        self.sync_transcription_binding(cx);
        cx.notify();
    }
    /// Menu items with a fixed shortcut or none (Swift's other MainMenu items).
    pub(super) fn run_app_action(
        &mut self,
        action: AppAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match action {
            AppAction::About => {
                self.open_settings_section(settings::SettingsSection::About, window, cx)
            }
            AppAction::Settings => {
                self.credential_panel
                    .update(cx, |panel, cx| panel.cancel(cx));
                self.open_settings_panel(window, cx);
            }
            AppAction::CheckForUpdates => {
                self.updater_settings
                    .update(cx, |view, cx| view.check_now(cx));
                self.open_settings_section(settings::SettingsSection::About, window, cx);
            }
            AppAction::Hide => cx.hide(),
            AppAction::HideOthers => cx.hide_other_apps(),
            AppAction::ShowAll => cx.unhide_other_apps(),
            AppAction::NewBot => {
                self.new_thread_in_project(coincide_core::bot_runtime::BOTS_PROJECT_ID, window, cx)
            }
            AppAction::NewThreadIn(project) => {
                if self.projects.iter().any(|p| p["id"] == project) {
                    self.new_thread_in_project(&project, window, cx);
                }
            }
            AppAction::RevealImportedSource => {
                let path = self
                    .selected
                    .as_ref()
                    .and_then(|thread| thread["importedSession"]["path"].as_str())
                    .map(std::path::PathBuf::from);
                match path {
                    Some(path) if path.is_absolute() => self.reveal_in_file_manager(path, cx),
                    _ => {
                        self.status =
                            "This conversation has no imported source file to reveal.".into();
                        cx.notify();
                    }
                }
            }
            AppAction::ImportSession => {
                self.session_import_open = true;
                self.sync_credentials(cx);
            }
            AppAction::OpenIn(id) => {
                if let Some(target) = self
                    .open_targets
                    .iter()
                    .find(|target| target.id == id)
                    .cloned()
                {
                    self.open_in_target(target, false, window, cx);
                }
            }
            AppAction::EditInstructions => {
                self.open_settings_section(settings::SettingsSection::Instructions, window, cx)
            }
            AppAction::CloseWindow => {
                // The main window keeps its own close button and quit fence;
                // this closes the separate Settings window.
                if self.settings_window.is_some() {
                    self.settings_window_closed(cx);
                }
            }
            AppAction::Find => {
                if transcript_find_shortcut_routes(self.selected.as_ref(), &self.browser_panels) {
                    self.open_find(window, cx);
                }
            }
            AppAction::FindNext | AppAction::FindPrevious => {
                if self.transcript_find.read(cx).is_open() {
                    let next = action == AppAction::FindNext;
                    self.transcript_find
                        .update(cx, |find, cx| find.step_match(next, cx));
                } else if transcript_find_shortcut_routes(
                    self.selected.as_ref(),
                    &self.browser_panels,
                ) {
                    self.open_find(window, cx);
                }
            }
            AppAction::BrowserPreview => self.toggle_browser(cx),
            AppAction::PullRequests => self.toggle_workspace_surface(true, window, cx),
            AppAction::FullScreen => window.toggle_fullscreen(),
            AppAction::Schedule => {
                if self.selected.is_some() {
                    self.hide_inline_settings();
                    self.workspace_open = false;
                    self.session_import_open = false;
                    self.open_conversation_schedules(window, cx);
                }
            }
            AppAction::Minimize => window.minimize_window(),
            AppAction::Zoom => window.zoom_window(),
            AppAction::BringAllToFront => cx.activate(true),
            AppAction::Link(url) => cx.open_url(url),
        }
        self.sync_transcription_binding(cx);
        cx.notify();
    }
}
