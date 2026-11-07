use super::*;
use browser_tab_shortcuts::{self as shortcuts, Command, Source};
impl Coincide {
    fn browser_shortcut_blocked(&self, cx: &App) -> bool {
        !self.chat_visible()
            || self.historical_image_is_open()
            || self.command_palette.read(cx).is_open()
            || self.settings_in_main_window()
    }
    pub(super) fn browser_tab_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let key = &event.keystroke;
        let primary = if cfg!(target_os = "macos") {
            key.modifiers.platform
        } else {
            key.modifiers.control
        };
        let other = if cfg!(target_os = "macos") {
            key.modifiers.control
        } else {
            key.modifiers.platform
        };
        let Some(command) = shortcuts::recognize(
            &key.key,
            primary,
            other,
            key.modifiers.alt,
            key.modifiers.shift,
        ) else {
            return false;
        };
        let Some(thread) = self.selected.as_ref().map(|t| text(t, "id")) else {
            return false;
        };
        if !shortcuts::eligible(
            window.is_window_active(),
            self.browser_panels.contains(&thread),
            self.browser_focus.contains_focused(window, cx),
            self.browser_shortcut_blocked(cx),
        ) {
            return false;
        }
        let Some(source) = self
            .browser
            .as_ref()
            .and_then(|browser| browser.shortcut_source(&thread, cx))
        else {
            return false;
        };
        self.perform_browser_tab_shortcut(source, command, false, window, cx);
        cx.stop_propagation();
        true
    }
    pub(super) fn perform_browser_tab_shortcut(
        &mut self,
        source: Source,
        command: Command,
        native_focus: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let selected = self
            .selected
            .as_ref()
            .is_some_and(|t| t["id"].as_str() == Some(source.thread.as_str()));
        if !selected
            || !shortcuts::eligible(
                window.is_window_active(),
                self.browser_panels.contains(&source.thread),
                shortcuts::dispatch_focus(
                    native_focus,
                    self.browser
                        .as_ref()
                        .is_some_and(|browser| browser.native_shortcut_focused(&source, cx)),
                    self.browser_focus.contains_focused(window, cx),
                ),
                self.browser_shortcut_blocked(cx),
            )
        {
            return;
        }
        let Some(browser) = &mut self.browser else {
            return;
        };
        if !browser.shortcut_source_current(&source, cx) {
            return;
        }
        match browser.apply_tab_shortcut(&source, command, window, cx) {
            Err(error) => self.status = format!("Browser: {error}"),
            Ok(closed_last) => {
                if closed_last {
                    browser.set_thread_visible(None, cx);
                    self.browser_panels.remove(&source.thread);
                    self.inspector_follow.preview_placeholder = false;
                    self.remember_inspector_choice(None, cx);
                    self.composer.read(cx).focus_handle(cx).focus(window, cx);
                } else if command == Command::New {
                    if let Some(view) = browser.active_view(&source.thread) {
                        let _ = view.read(cx).raw().focus_parent();
                    }
                    self.browser_address
                        .update(cx, |input, cx| input.set_value("", window, cx));
                    self.browser_address
                        .read(cx)
                        .focus_handle(cx)
                        .focus(window, cx);
                } else if command == Command::Close || native_focus {
                    let _ = browser.focus_active_native(&source.thread, cx);
                }
            }
        }
        cx.notify();
    }
}
