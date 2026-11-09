//! Consume app commands on the normal UI tick, after closing/quit admission.
use super::*;

impl Coincide {
    pub(super) fn open_settings_panel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings_open && (self.settings_window.is_some() || self.settings_window_pending) {
            self.show_settings_window(cx);
            return;
        }
        self.computer_use_open = false;
        self.media.opened = false;
        self.browser_settings_open = false;
        self.bots_open = false;
        self.notifications_open = false;
        self.transcription_open = false;
        self.credentials_open = false;
        self.provider_settings.open = false;
        self.settings_open = true;
        self.focus_settings_route(window, cx);
        self.refresh_settings(window, cx);
    }

    /// What the menu bar shows now. Key equivalents follow the same routing as
    /// keys: while a browser panel is visible only its two commands keep theirs,
    /// so native page keys never reach a menu item instead.
    fn menu_snapshot(
        &self,
        context: app_menu::EditContext,
        selection_available: bool,
        main_active: bool,
    ) -> app_menu::MenuSnapshot {
        use keyboard_settings::Command as K;
        let browser = self.browser_panel_open();
        let keys = K::ALL
            .into_iter()
            .filter(|command| {
                command.jump_index().is_none()
                    && *command != K::AddToComposer
                    && (!browser || keyboard_settings::browser_command(*command))
            })
            .filter_map(|command| {
                keyboard_settings::menu_keystroke(&self.settings, command)
                    .map(|keys| (command, keys))
            })
            .collect();
        app_menu::MenuSnapshot {
            imported_source: self
                .selected
                .as_ref()
                .and_then(|thread| thread["importedSession"]["path"].as_str())
                .unwrap_or_default()
                .to_owned(),
            context,
            selection_available,
            keys,
            add_selection_key: keyboard_settings::menu_keystroke(&self.settings, K::AddToComposer),
            fixed_keys: !browser,
            enabled: K::ALL
                .into_iter()
                .filter(|command| self.keyboard_command_available(*command))
                .collect(),
            sidebar: self.thread_list_open,
            terminal: self.terminal_visible_thread.is_some(),
            diff: self.diff_open(),
            schedules: self.schedules_open,
            browser,
            pull_requests: self.pull_requests_open(),
            pinned: self
                .selected
                .as_ref()
                .is_some_and(|t| t["isPinned"] == true),
            archived: self
                .selected
                .as_ref()
                .is_some_and(|t| t["isArchived"] == true),
            thread: self.selected.is_some(),
            find: self.find_context_available(),
            settings_window: self.settings_window.is_some() && !main_active,
            projects: self
                .projects
                .iter()
                .filter(|project| {
                    let id = text(project, "id");
                    !id.is_empty()
                        && project["isChats"] != true
                        && project["isBots"] != true
                        && id != navigation::NO_PROJECT_ID
                        && !id.eq_ignore_ascii_case(coincide_core::bot_runtime::BOTS_PROJECT_ID)
                })
                .map(|project| (text(project, "id"), text(project, "name")))
                .collect(),
            open_targets: self
                .open_targets
                .iter()
                .map(|target| (target.id.to_owned(), target.name.to_owned()))
                .collect(),
        }
    }

    pub(super) fn poll_app_menu(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // Native selectors route to the actual macOS responder. The terminal
        // currently handles keyboard edits itself, so its menu remains disabled.
        // Other platforms need their own native-responder acceptance first.
        let context = if !window.is_window_active() {
            app_menu::EditContext::Unverified
        } else if self
            .terminal_workspaces
            .values()
            .any(|workspace| workspace.read(cx).is_focused(window))
        {
            app_menu::EditContext::Terminal
        } else if cfg!(target_os = "macos") {
            app_menu::EditContext::StandardResponder
        } else {
            app_menu::EditContext::Unverified
        };
        let selection_available = self.selection_to_composer_available(window, cx);
        let snapshot = self.menu_snapshot(context, selection_available, window.is_window_active());
        app_menu::update(cx, snapshot);
        for request in app_menu::take_requests(cx) {
            match request {
                app_menu::MenuRequest::Command(command) => {
                    self.run_keyboard_command(command, window, cx)
                }
                app_menu::MenuRequest::App(action) => self.run_app_action(action, window, cx),
            }
        }
    }
}
