//! Compact conversation chrome. All actions retain their existing controllers;
//! expanding secondary actions changes presentation only.
use super::*;
use gpui_kit::assets::IconName;

impl Coincide {
    pub(super) fn conversation_toolbar(&self, title: String, cx: &mut Context<Self>) -> AnyElement {
        div()
            .id("conversation-toolbar")
            .flex()
            .flex_col()
            .flex_shrink_0()
            .w_full()
            .min_w_0()
            .border_b_1()
            .border_color(self.color(0x29303d))
            .child(
                div()
                    .id("conversation-toolbar-primary")
                    .flex()
                    .items_center()
                    .h(px(44.))
                    .px_3()
                    .gap_1()
                    .child(div().flex_1().min_w_0().truncate().text_sm().child(title))
                    .child(
                        Button::new("transcript-find-open")
                            .icon(IconName::Search)
                            .accessibility_label("Find in conversation")
                            .tooltip("Find in conversation")
                            .ghost()
                            .compact()
                            .disabled(!self.find_context_available())
                            .on_click(
                                cx.listener(|this, _, window, cx| this.open_find(window, cx)),
                            ),
                    )
                    .child(
                        Button::new("terminal")
                            .icon(IconName::SquareTerminal)
                            .accessibility_label("Terminal")
                            .tooltip("Toggle terminal")
                            .ghost()
                            .compact()
                            .selected(self.terminal_visible_thread.is_some())
                            .on_click(cx.listener(|this, _, window, cx| this.terminal(window, cx))),
                    )
                    .child(
                        Button::new("browser")
                            .icon(IconName::Globe)
                            .accessibility_label("Browser")
                            .tooltip("Toggle browser")
                            .ghost()
                            .compact()
                            .on_click(cx.listener(|this, _, _, cx| this.toggle_browser(cx))),
                    )
                    .child(
                        Button::new("git-workspace-toggle")
                            .icon(IconName::GitBranch)
                            .accessibility_label(if self.workspace_open {
                                "Close Git workspace"
                            } else {
                                "Git workspace"
                            })
                            .tooltip("Toggle Git workspace")
                            .ghost()
                            .compact()
                            .selected(self.workspace_open)
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
                        Button::new("conversation-actions-toggle")
                            .icon(IconName::Ellipsis)
                            .accessibility_label(if self.thread_actions_open {
                                "Hide conversation actions"
                            } else {
                                "More conversation actions"
                            })
                            .tooltip("More conversation actions")
                            .ghost()
                            .compact()
                            .selected(self.thread_actions_open)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.thread_actions_open = !this.thread_actions_open;
                                cx.notify();
                            })),
                    ),
            )
            .when(self.thread_actions_open, |view| {
                view.child(
                    div()
                        .id("conversation-toolbar-secondary")
                        .flex()
                        .flex_wrap()
                        .items_center()
                        .gap_1()
                        .px_3()
                        .pb_2()
                        .child(
                            Button::new("session-import-toggle")
                                .label(if self.session_import_open {
                                    "Close import"
                                } else {
                                    "Import CLI session"
                                })
                                .ghost()
                                .compact()
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
                                .ghost()
                                .compact()
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.session_import_open = false;
                                    let open = !(this.settings_open && this.credentials_open);
                                    this.credentials_open = open;
                                    this.browser_settings_open = false;
                                    this.media.opened = false;
                                    this.credential_panel
                                        .update(cx, |panel, cx| panel.cancel(cx));
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
                            Button::new("schedules")
                                .label(if self.schedules_open {
                                    "Conversation"
                                } else {
                                    "Schedules"
                                })
                                .ghost()
                                .compact()
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
                            Button::new("fork")
                                .label("Fork")
                                .ghost()
                                .compact()
                                .on_click(cx.listener(|this, _, window, cx| this.fork(window, cx))),
                        )
                        .child(
                            Button::new("pin")
                                .label("Pin / unpin")
                                .ghost()
                                .compact()
                                .on_click(
                                    cx.listener(|this, _, _, cx| this.toggle("isPinned", cx)),
                                ),
                        )
                        .child(
                            Button::new("rename-thread")
                                .label("Rename")
                                .ghost()
                                .compact()
                                .disabled(self.selected.is_none())
                                .on_click(
                                    cx.listener(|this, _, window, cx| {
                                        this.begin_rename(window, cx)
                                    }),
                                ),
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
                                .ghost()
                                .compact()
                                .disabled(self.selected.is_none())
                                .on_click(cx.listener(|this, _, _, cx| this.request_archive(cx))),
                        ),
                )
            })
            .into_any_element()
    }
}
