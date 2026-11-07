//! Compact conversation chrome. All actions retain their existing controllers;
//! expanding secondary actions changes presentation only.
use super::*;
use gpui_kit::{assets::IconName, component::tooltip::Tooltip};

// Read only the selected conversation's persisted metadata. The independent
// sidebar project filter is not the conversation's project or live Git HEAD.
fn conversation_subtitle(selected: Option<&Value>, projects: &[Value]) -> Option<String> {
    let selected = selected?;
    let project = selected["projectID"].as_str().and_then(|id| {
        projects.iter().find(|project| {
            project["id"]
                .as_str()
                .is_some_and(|known| known.eq_ignore_ascii_case(id))
        })
    });
    let chats = project.is_some_and(|project| project["isChats"] == true);
    let name = if chats {
        Some("Chat")
    } else {
        project.and_then(|project| project["name"].as_str())
    };
    // Swift Thread/ThreadFile persist this exact optional "branch" key.
    let branch = if chats {
        None
    } else {
        selected["branch"].as_str()
    };
    let parts = [name, branch]
        .into_iter()
        .flatten()
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>();
    (!parts.is_empty()).then(|| parts.join(" · "))
}

impl Coincide {
    pub(super) fn conversation_toolbar(&self, title: String, cx: &mut Context<Self>) -> AnyElement {
        let subtitle = conversation_subtitle(self.selected.as_ref(), &self.projects);
        let accessible = subtitle
            .as_ref()
            .map(|subtitle| format!("{title}, {subtitle}"))
            .unwrap_or_else(|| title.clone());
        let tooltip = subtitle
            .as_ref()
            .map(|subtitle| format!("{title}\n{subtitle}"))
            .unwrap_or_else(|| title.clone());
        let heading = div()
            .id("conversation-header-context")
            .role(Role::Label)
            .aria_label(accessible)
            .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
            .flex_1()
            .min_w_0()
            .h(px(32.))
            .flex()
            .flex_col()
            .justify_center()
            .child(
                div()
                    .min_w_0()
                    .truncate()
                    .text_size(px(13.))
                    .line_height(px(16.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(title),
            )
            .when_some(subtitle, |heading, subtitle| {
                heading.child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(px(11.))
                        .line_height(px(14.))
                        .text_color(self.color(0xe4e9f2).opacity(0.65))
                        .child(subtitle),
                )
            });
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
                    .child(heading)
                    .when_some(self.project_scripts_control(cx), |toolbar, scripts| {
                        toolbar.child(scripts)
                    })
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
                    .when(self.terminal_on_right(), |toolbar| {
                        toolbar.child(
                            Button::new("terminal")
                                .icon(IconName::SquareTerminal)
                                .accessibility_label("Terminal")
                                .tooltip("Toggle terminal")
                                .ghost()
                                .compact()
                                .selected(self.terminal_visible_thread.is_some())
                                .on_click(
                                    cx.listener(|this, _, window, cx| this.terminal(window, cx)),
                                ),
                        )
                    })
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
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.clear_inspector_placeholders();
                                this.session_import_open = false;
                                this.workspace_open = !this.workspace_open;
                                if this.workspace_open {
                                    this.ensure_inspector_space(window);
                                    this.hide_selected_browser_surface(cx);
                                    if this.terminal_on_right() {
                                        this.terminal_open = false;
                                    }
                                    this.close_schedule_surface();
                                }
                                this.settings_open = false;
                                this.sync_transcription_binding(cx);
                                this.remember_current_inspector(cx);
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
                                    this.sync_credentials(cx);
                                    this.sync_transcription_binding(cx);
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new("schedules")
                                .label(
                                    if self.schedules_open
                                        && !self.schedule_editor.all_conversations
                                    {
                                        "Close schedules"
                                    } else {
                                        "Schedules"
                                    },
                                )
                                .ghost()
                                .compact()
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.settings_open = false;
                                    this.workspace_open = false;
                                    this.session_import_open = false;
                                    if this.schedules_open
                                        && !this.schedule_editor.all_conversations
                                    {
                                        this.close_schedule_surface();
                                    } else {
                                        this.open_conversation_schedules(window, cx);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn header_context_uses_selected_thread_project_not_another_filtered_project() {
        let projects = vec![
            json!({"id":"filter-project","name":"Filtered project"}),
            json!({"id":"selected-project","name":"Selected project"}),
        ];
        let selected = json!({"projectID":"SELECTED-PROJECT","branch":"feature/selected","branchName":"wrong-key"});
        assert_eq!(
            conversation_subtitle(Some(&selected), &projects).as_deref(),
            Some("Selected project · feature/selected")
        );
    }

    #[::core::prelude::v1::test]
    fn header_context_omits_unknown_empty_and_malformed_values_without_inference() {
        assert!(conversation_subtitle(None, &[]).is_none());
        for selected in [
            json!({"projectID":"unknown"}),
            json!({"projectID":"unknown","branch":"  ","branchName":"main"}),
            json!({"projectID":42,"branch":false}),
            json!({"projectID":"blank","branch":null}),
        ] {
            assert!(
                conversation_subtitle(Some(&selected), &[json!({"id":"blank","name":"  "})])
                    .is_none()
            );
        }
        let selected = json!({"projectID":"unknown","branch":" saved/branch "});
        assert_eq!(
            conversation_subtitle(Some(&selected), &[]).as_deref(),
            Some("saved/branch")
        );
    }

    #[::core::prelude::v1::test]
    fn header_context_chat_project_omits_branch_like_swift() {
        let selected = json!({"projectID":"chats","branch":"irrelevant"});
        assert_eq!(
            conversation_subtitle(
                Some(&selected),
                &[json!({"id":"chats","isChats":true,"name":"Chats container"})]
            )
            .as_deref(),
            Some("Chat")
        );
    }
}
