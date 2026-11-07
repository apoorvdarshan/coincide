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

/// A bot's conversation is titled with the bot, the conversation below it, as
/// Swift's `updateTitle`. None for other threads or a bot that is gone.
fn bot_heading(selected: Option<&Value>, bots: &[Value]) -> Option<(String, String)> {
    let selected = selected?;
    let id = selected["botID"].as_str()?;
    let bot = bots.iter().find(|bot| {
        bot["id"]
            .as_str()
            .is_some_and(|known| known.eq_ignore_ascii_case(id))
    })?;
    let name = bot["name"]
        .as_str()
        .filter(|name| !name.trim().is_empty())
        .unwrap_or("Bot");
    Some((name.to_owned(), text(selected, "title")))
}

/// The panels that open in the inspector column, as Swift's `InspectorPanelButtons`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RightPanel {
    Schedules,
    Diff,
    PullRequests,
    Preview,
    Terminal,
}

impl Coincide {
    pub(super) fn conversation_toolbar(&self, title: String, cx: &mut Context<Self>) -> AnyElement {
        let bot = bot_heading(self.selected.as_ref(), &self.sidebar_bots);
        let (title, subtitle) = match bot.clone() {
            Some((name, conversation)) => (name, Some(conversation).filter(|c| !c.is_empty())),
            None => (
                title,
                conversation_subtitle(self.selected.as_ref(), &self.projects),
            ),
        };
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
            .when(bot.is_some(), |heading| {
                heading.pl(px(26.)).relative().child(
                    div()
                        .absolute()
                        .left_0()
                        .top(px(8.))
                        .size(px(18.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(IconName::Bot),
                )
            })
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
                    .when_some(self.run_status_pill(cx), |toolbar, pill| {
                        toolbar.child(pill)
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
                    .child(self.right_panel_buttons(cx))
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

impl Coincide {
    /// Swift's `RunStatusView`: "Connecting…", "Working 0:42" with Stop, or an
    /// orange "Needs approval"; nothing while the open thread is idle.
    fn run_status_pill(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let status = self.run_status();
        let label = status.label(coincide_core::store::swift_timestamp())?;
        let theme = cx.theme();
        let approval = matches!(status, window_chrome::RunStatus::Approval(_));
        let tint = if approval {
            theme.warning
        } else {
            self.color(0xe4e9f2).opacity(0.65).into()
        };
        Some(
            div()
                .id("toolbar-run-status")
                .role(Role::Group)
                .aria_label(label.clone())
                .flex()
                .flex_shrink_0()
                .items_center()
                .gap(px(6.))
                .h(px(28.))
                .pl(px(10.))
                .pr(px(4.))
                .rounded(px(14.))
                .bg(self.color(0x202a3b))
                .border_1()
                .border_color(self.color(0x29303d))
                .child(if approval {
                    div()
                        .text_color(theme.warning)
                        .child(Icon::new(IconName::ShieldAlert).xsmall())
                        .into_any_element()
                } else {
                    gpui_kit::component::spinner::Spinner::new()
                        .small()
                        .into_any_element()
                })
                .child(
                    div()
                        .text_size(px(12.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(tint)
                        .whitespace_nowrap()
                        .child(label),
                )
                .child(
                    Button::new("toolbar-run-stop")
                        .icon(IconName::Square)
                        .ghost()
                        .xsmall()
                        .w(px(24.))
                        .h(px(24.))
                        .rounded(px(12.))
                        .accessibility_label("Stop")
                        .tooltip("Stop")
                        .on_click(cx.listener(|this, _, _, cx| {
                            if let Some(thread) = this.selected.as_ref()
                                && let Err(error) = call(
                                    &this.engine,
                                    "agent.stop",
                                    json!({"threadId":thread["id"]}),
                                )
                            {
                                this.status = error.to_string();
                            }
                            cx.notify();
                        })),
                )
                .into_any_element(),
        )
    }
    fn open_right_panel(&self) -> Option<RightPanel> {
        if self.schedules_open {
            return Some(RightPanel::Schedules);
        }
        match self.chat_inspector_panel()? {
            chat_inspector::Panel::Workspace if self.github_open || self.github_threads_open => {
                Some(RightPanel::PullRequests)
            }
            chat_inspector::Panel::Workspace => Some(RightPanel::Diff),
            chat_inspector::Panel::Browser => Some(RightPanel::Preview),
            chat_inspector::Panel::Terminal => Some(RightPanel::Terminal),
            chat_inspector::Panel::ConversationSchedules => Some(RightPanel::Schedules),
        }
    }
    /// The Git workspace on its diff or its pull requests; the lit one closes.
    fn toggle_workspace_panel(
        &mut self,
        pull_requests: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let panel = if pull_requests {
            RightPanel::PullRequests
        } else {
            RightPanel::Diff
        };
        self.clear_inspector_placeholders();
        self.session_import_open = false;
        self.settings_open = false;
        if self.open_right_panel() == Some(panel) {
            self.workspace_open = false;
        } else {
            self.github_open = pull_requests;
            self.github_threads_open = false;
            self.workspace_open = true;
            self.ensure_inspector_space(window);
            self.hide_selected_browser_surface(cx);
            if self.terminal_on_right() {
                self.terminal_open = false;
            }
            self.close_schedule_surface();
        }
        self.sync_workspace_context(cx);
        self.sync_transcription_binding(cx);
        self.remember_current_inspector(cx);
        cx.notify();
    }
    /// The Scheduled panel; while the open thread has schedules it opens on them.
    fn toggle_schedules_panel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.settings_open = false;
        self.workspace_open = false;
        self.session_import_open = false;
        let thread = self.selected.as_ref().map(|thread| text(thread, "id"));
        if self.schedules_open {
            self.close_schedule_surface();
        } else if thread.is_some_and(|id| {
            coincide_core::schedule_presentation::thread_tooltip_now(&self.sidebar_schedules, &id)
                .is_some()
        }) {
            self.open_conversation_schedules(window, cx);
        } else {
            self.open_global_schedules(cx);
        }
        self.sync_transcription_binding(cx);
        cx.notify();
    }
    /// One pill of tab-like buttons for whatever opens on the right: every
    /// schedule (with the open thread's next run), the diff, the pull requests,
    /// the browser and, when Settings puts it on the right, the terminal.
    fn right_panel_buttons(&self, cx: &mut Context<Self>) -> AnyElement {
        use keyboard_settings::Command;
        let open = self.open_right_panel();
        let hint = |label: &str, command: Option<Command>| {
            command
                .and_then(|command| keyboard_settings::shortcut_hint(&self.settings, command))
                .map(|keys| format!("{label} ({keys})"))
                .unwrap_or_else(|| label.to_owned())
        };
        let thread = self.selected.as_ref().map(|thread| text(thread, "id"));
        let next_run = thread.as_deref().and_then(|id| {
            coincide_core::schedule_presentation::next_run_label(&self.sidebar_schedules, id)
        });
        let schedule_detail = thread.as_deref().and_then(|id| {
            coincide_core::schedule_presentation::thread_tooltip_now(&self.sidebar_schedules, id)
        });
        let button = |id: &'static str, icon: IconName, label: &'static str, panel: RightPanel| {
            Button::new(id)
                .icon(icon)
                .ghost()
                .compact()
                .h(px(26.))
                .min_w(px(30.))
                .accessibility_label(label)
                .selected(open == Some(panel))
        };
        let schedule_tooltip = [
            Some(hint("Scheduled Tasks", Some(Command::Schedules))),
            schedule_detail,
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join("\n");
        div()
            .id("toolbar-right-panels")
            .role(Role::Group)
            .aria_label("Right Panels")
            .flex()
            .flex_shrink_0()
            .items_center()
            .h(px(28.))
            .p(px(1.))
            .rounded(px(8.))
            .bg(self.color(0x202a3b))
            .border_1()
            .border_color(self.color(0x29303d))
            .child(
                button(
                    "toolbar-schedules",
                    IconName::Clock,
                    "Scheduled Tasks",
                    RightPanel::Schedules,
                )
                .when_some(next_run, |button, next| button.label(next))
                .tooltip(schedule_tooltip)
                .on_click(
                    cx.listener(|this, _, window, cx| this.toggle_schedules_panel(window, cx)),
                ),
            )
            .child(
                button("toolbar-diff", IconName::Diff, "Diff", RightPanel::Diff)
                    .tooltip("Diff")
                    .disabled(self.selected.is_none())
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.toggle_workspace_panel(false, window, cx)
                    })),
            )
            .child(
                button(
                    "toolbar-pull-requests",
                    IconName::GitPullRequest,
                    "Pull Requests",
                    RightPanel::PullRequests,
                )
                .tooltip("Pull Requests")
                .disabled(self.selected.is_none())
                .on_click(
                    cx.listener(|this, _, window, cx| {
                        this.toggle_workspace_panel(true, window, cx)
                    }),
                ),
            )
            .child(
                button(
                    "browser",
                    IconName::Globe,
                    "Browser Preview",
                    RightPanel::Preview,
                )
                .tooltip("Browser Preview")
                .disabled(self.selected.is_none())
                .on_click(cx.listener(|this, _, _, cx| this.toggle_browser(cx))),
            )
            .when(self.terminal_on_right(), |pill| {
                pill.child(
                    button(
                        "terminal",
                        IconName::SquareTerminal,
                        "Terminal",
                        RightPanel::Terminal,
                    )
                    .tooltip(hint("Terminal", Some(Command::Terminal)))
                    .disabled(self.selected.is_none())
                    .on_click(cx.listener(|this, _, window, cx| this.terminal(window, cx))),
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
    fn bot_conversations_are_titled_with_the_bot_and_the_conversation_below() {
        let bots = vec![
            json!({"id":"BOT","name":"Researcher"}),
            json!({"id":"blank","name":" "}),
        ];
        let selected = json!({"botID":"bot","title":"Weekly digest"});
        assert_eq!(
            bot_heading(Some(&selected), &bots),
            Some(("Researcher".into(), "Weekly digest".into()))
        );
        let unnamed = json!({"botID":"blank","title":"Hello"});
        assert_eq!(
            bot_heading(Some(&unnamed), &bots).map(|(name, _)| name),
            Some("Bot".into())
        );
        // An ordinary thread, or a bot that is gone, keeps the thread's own heading.
        assert!(bot_heading(Some(&json!({"title":"Plain"})), &bots).is_none());
        assert!(bot_heading(Some(&json!({"botID":"gone","title":"x"})), &bots).is_none());
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
