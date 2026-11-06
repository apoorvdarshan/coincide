//! Consume app commands on the normal UI tick, after closing/quit admission.
use crate::{Coincide, app_menu};
use gpui_kit::{Context, Window};

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
        app_menu::set_context(cx, context);
        let selection_available = self.selection_to_composer_available(window, cx);
        app_menu::set_selection_available(cx, selection_available);
        for request in app_menu::take_requests(cx) {
            match request {
                app_menu::MenuRequest::Settings => {
                    self.open_settings_panel(window, cx);
                    self.sync_transcription_binding(cx);
                    cx.notify();
                }
                app_menu::MenuRequest::NewConversation => self.new_thread(window, cx),
                app_menu::MenuRequest::Hide => cx.hide(),
                app_menu::MenuRequest::HideOthers => cx.hide_other_apps(),
                app_menu::MenuRequest::ShowAll => cx.unhide_other_apps(),
            }
        }
    }
}
