//! Retained workspace/GitHub controllers mounted beside the current chat.
use super::*;
use crate::native_menu::AccessibleMenuExt as _;
use gpui_kit::component::menu::PopupMenuItem;
impl Coincide {
    /// Whether the inspector column shows the GitHub pull requests panel.
    pub(super) fn pull_requests_panel_open(&self) -> bool {
        self.workspace_open && self.github_open && !self.github_threads_open
    }
    /// Swift's togglePullRequestsPanel, shared by the toolbar button and the
    /// palette: shows the PR panel in the inspector, or closes it when shown.
    pub(super) fn toggle_pull_requests_panel(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let showing = self.pull_requests_panel_open();
        self.clear_inspector_placeholders();
        self.session_import_open = false;
        if showing {
            self.workspace_open = false;
        } else {
            self.workspace_open = true;
            self.github_open = true;
            self.github_threads_open = false;
            self.ensure_inspector_space(window);
            self.hide_selected_browser_surface(cx);
            if self.terminal_on_right() {
                self.terminal_open = false;
            }
            self.close_schedule_surface();
        }
        self.settings_open = false;
        self.sync_transcription_binding(cx);
        self.remember_current_inspector(cx);
        self.sync_workspace_context(cx);
        cx.notify();
    }
    fn workspace_switcher(&self, cx: &mut Context<Self>) -> AnyElement {
        let owner = cx.entity().downgrade();
        let active = if self.github_threads_open {
            3
        } else if self.github_open {
            2
        } else if self.git_tools_open {
            1
        } else {
            0
        };
        let title = ["Changes", "Local Git", "Pull Requests", "Review comments"][active];
        div()
            .flex()
            .items_center()
            .justify_between()
            .h(px(38.))
            .px_3()
            .gap_2()
            .bg(self.color(0x111722))
            .border_b_1()
            .border_color(self.color(0x29303d))
            .child(
                div()
                    .text_sm()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(self.color(0xe4e9f2).opacity(0.85))
                    .child(title),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_1()
                    .child(
                        Button::new("workspace-tools")
                            .icon(gpui_kit::assets::IconName::Ellipsis)
                            .ghost()
                            .compact()
                            .xsmall()
                            .accessibility_label("Workspace views")
                            .tooltip("Workspace views")
                            .accessible_menu_with_anchor(
                                Anchor::TopRight,
                                move |mut menu, _, _| {
                                    for (index, label) in
                                        ["Changes", "Local Git", "Pull Requests", "Review comments"]
                                            .into_iter()
                                            .enumerate()
                                    {
                                        let owner = owner.clone();
                                        menu = menu.item(
                                            PopupMenuItem::new(label)
                                                .checked(index == active)
                                                .on_click(move |_, window, cx| {
                                                    let _ =
                                                        owner.update(cx, |this, cx| {
                                                            this.github_open = index == 2;
                                                            this.github_threads_open = index == 3;
                                                            this.git_tools_open = index == 1;
                                                            this.github_threads_scope_stale = false;
                                                            this.remember_current_inspector(cx);
                                                            this.sync_workspace_context(cx);
                                                            if index == 3 {
                                                                let loaded = this
                                                                    .github_panel
                                                                    .read(cx)
                                                                    .loaded_pr_scope(cx);
                                                                this.github_threads_seed =
                                                                    loaded.clone();
                                                                if let Some((
                                                                    repository,
                                                                    number,
                                                                    head,
                                                                )) = loaded
                                                                {
                                                                    this.github_threads_panel
                                                                        .update(cx, |panel, cx| {
                                                                            panel.set_pr(
                                                                                repository, number,
                                                                                head, window, cx,
                                                                            )
                                                                        });
                                                                }
                                                            }
                                                            cx.notify();
                                                        });
                                                }),
                                        );
                                    }
                                    menu
                                },
                            ),
                    )
                    .child(
                        Button::new("close-chat-inspector")
                            .icon(gpui_kit::assets::IconName::Close)
                            .ghost()
                            .compact()
                            .small()
                            .accessibility_label("Close panel")
                            .tooltip("Close panel")
                            .on_click(cx.listener(|this, _, _, cx| this.close_chat_inspector(cx))),
                    ),
            )
            .into_any_element()
    }
    pub(super) fn workspace_inspector_body(&mut self, cx: &mut Context<Self>) -> AnyElement {
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
                .child(self.workspace_switcher(cx))
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
                        .flex()
                        .flex_col()
                        .child(
                            div().flex_1().flex_basis(px(0.)).min_h_0().min_w_0().overflow_hidden()
                                .child(if self.git_tools_open {
                                    self.workspace_panel.clone().into_any_element()
                                } else {
                                    self.diff_panel.clone().into_any_element()
                                }),
                        )
                        // The action bar stays below the selected Git workspace surface.
                        .when_some(self.git_actions_bar(cx), |view, bar| view.child(bar))
                        .into_any_element()
                })
                .into_any_element()
    }
}
