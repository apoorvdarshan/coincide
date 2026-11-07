//! Chat-route visibility is independent of the retained right-side inspector.
//! These projections carry no provider, filesystem, native-session or PR grants.
use super::*;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Panel {
    Workspace,
    ConversationSchedules,
    Browser,
    Terminal,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct ChatRoute {
    pub selected: bool,
    pub settings: bool,
    pub global_schedules: bool,
    pub importing: bool,
}
impl ChatRoute {
    pub fn available(self) -> bool {
        !self.settings && !self.global_schedules && !self.importing
    }
    pub fn visible(self) -> bool {
        self.selected && self.available()
    }
}
pub(super) fn panel(
    route: ChatRoute,
    workspace: bool,
    conversation_schedules: bool,
    right_terminal: bool,
    browser: bool,
) -> Option<Panel> {
    if !route.visible() {
        None
    } else if workspace {
        Some(Panel::Workspace)
    } else if conversation_schedules {
        Some(Panel::ConversationSchedules)
    } else if right_terminal {
        Some(Panel::Terminal)
    } else if browser {
        Some(Panel::Browser)
    } else {
        None
    }
}
pub(super) fn columns(chat: AnyElement, inspector: Option<AnyElement>) -> Div {
    div()
        .flex()
        .flex_1()
        .flex_basis(px(0.))
        .min_w_0()
        .h_full()
        .child(chat)
        .when_some(inspector, |view, panel| view.child(panel))
}
impl Coincide {
    pub(super) fn sync_inspector_browser_visibility(&mut self, cx: &mut Context<Self>) {
        let visible =
            self.chat_inspector_panel() == Some(Panel::Browser) && !self.historical_image_is_open();
        let selected = self.selected.as_ref().map(|thread| text(thread, "id"));
        if let Some(browser) = &mut self.browser {
            // Reconcile native presentation in the same UI turn as a route
            // change. Tabs, storage and provider grants remain controller-owned.
            browser.set_thread_visible(selected.as_deref().filter(|_| visible), cx);
        }
    }
    pub(super) fn hide_selected_browser_surface(&mut self, cx: &mut Context<Self>) {
        if let Some(thread) = &self.selected {
            self.browser_panels.remove(&text(thread, "id"));
        }
        if let Some(browser) = &mut self.browser {
            browser.set_thread_visible(None, cx);
        }
    }
    pub(super) fn global_schedules_route(&self) -> bool {
        self.schedules_open && self.schedule_editor.all_conversations
    }
    fn chat_route(&self) -> ChatRoute {
        ChatRoute {
            selected: self.selected.is_some(),
            settings: self.settings_in_main_window(),
            global_schedules: self.global_schedules_route(),
            importing: self.session_import_open,
        }
    }
    pub(super) fn chat_route_available(&self) -> bool {
        self.chat_route().available()
    }
    pub(super) fn chat_visible(&self) -> bool {
        self.chat_route().visible()
    }
    pub(super) fn chat_inspector_panel(&self) -> Option<Panel> {
        panel(
            self.chat_route(),
            self.workspace_open,
            self.schedules_open && !self.schedule_editor.all_conversations,
            (self.terminal_open || self.inspector_follow.terminal_placeholder)
                && self.terminal_on_right(),
            self.inspector_follow.preview_placeholder
                || (self.browser.is_some()
                    && self
                        .selected
                        .as_ref()
                        .is_some_and(|thread| self.browser_panels.contains(&text(thread, "id")))),
        )
    }
    pub(super) fn close_chat_inspector(&mut self, cx: &mut Context<Self>) {
        let window_wide = self.schedules_open;
        match self.chat_inspector_panel() {
            Some(Panel::Workspace) => {
                self.workspace_open = false;
                self.sync_github_context(cx);
            }
            Some(Panel::ConversationSchedules) => self.close_schedule_surface(),
            Some(Panel::Browser) => self.hide_selected_browser_surface(cx),
            Some(Panel::Terminal) => self.terminal_open = false,
            None => (),
        }
        self.clear_inspector_placeholders();
        if !window_wide {
            self.remember_inspector_choice(None, cx);
        }
        cx.notify();
    }
    pub(super) fn chat_inspector_surface(
        &mut self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let (id, body) = match self.chat_inspector_panel()? {
            Panel::Terminal
                if self.inspector_follow.terminal_placeholder && !self.terminal_open =>
            {
                (
                    "saved-terminal-inspector",
                    self.saved_inspector_placeholder(true, cx),
                )
            }
            Panel::Terminal => return self.terminal_surface(true, window, cx),
            Panel::Workspace => ("workspace-inspector", self.workspace_inspector_body(cx)),
            Panel::ConversationSchedules => {
                ("conversation-schedules-inspector", self.schedules_pane(cx))
            }
            Panel::Browser
                if self.inspector_follow.preview_placeholder && self.browser.is_none() =>
            {
                (
                    "saved-browser-inspector",
                    self.saved_inspector_placeholder(false, cx),
                )
            }
            Panel::Browser => ("browser-inspector", self.browser_pane(cx)?),
        };
        let body = if matches!(
            self.chat_inspector_panel(),
            Some(Panel::Workspace | Panel::ConversationSchedules)
        ) {
            div()
                .flex()
                .flex_col()
                .min_h_0()
                .h_full()
                .child(
                    div().flex().items_center().justify_end().p_1().child(
                        Button::new("close-chat-inspector")
                            .label("Close panel")
                            .on_click(cx.listener(|this, _, _, cx| this.close_chat_inspector(cx))),
                    ),
                )
                .child(body)
                .into_any_element()
        } else {
            body
        };
        let body = if let Some(error) = self.inspector_follow.error.clone() {
            div()
                .flex()
                .flex_col()
                .h_full()
                .child(div().p_2().text_sm().child(error))
                .child(body)
                .into_any_element()
        } else {
            body
        };
        self.inspector_surface(id, body, window, cx)
    }
}

#[cfg(test)]
mod tests {
    use super::{ChatRoute, Panel, panel};
    #[::core::prelude::v1::test]
    fn only_full_routes_hide_chat_and_inspectors_never_do() {
        let route = ChatRoute {
            selected: true,
            ..ChatRoute::default()
        };
        for expected in [
            Panel::Workspace,
            Panel::ConversationSchedules,
            Panel::Terminal,
            Panel::Browser,
        ] {
            let chosen = panel(
                route,
                expected == Panel::Workspace,
                expected == Panel::ConversationSchedules,
                expected == Panel::Terminal,
                expected == Panel::Browser,
            );
            assert_eq!(chosen, Some(expected));
            assert!(route.visible());
        }
        for unavailable in [
            ChatRoute::default(),
            ChatRoute {
                settings: true,
                ..route
            },
            ChatRoute {
                global_schedules: true,
                ..route
            },
            ChatRoute {
                importing: true,
                ..route
            },
        ] {
            assert!(!unavailable.visible());
            assert_eq!(panel(unavailable, true, true, true, true), None);
        }
    }
    #[::core::prelude::v1::test]
    fn right_panes_have_one_deterministic_owner_during_reconciliation() {
        let route = ChatRoute {
            selected: true,
            ..ChatRoute::default()
        };
        assert_eq!(panel(route, true, true, true, true), Some(Panel::Workspace));
        assert_eq!(
            panel(route, false, true, true, true),
            Some(Panel::ConversationSchedules)
        );
        assert_eq!(
            panel(route, false, false, true, true),
            Some(Panel::Terminal)
        );
        assert_eq!(
            panel(route, false, false, false, true),
            Some(Panel::Browser)
        );
        assert_eq!(panel(route, false, false, false, false), None);
    }
}
#[cfg(test)]
#[path = "chat_inspector_ui_tests.rs"]
mod native_tests;
