//! Retained workspace/GitHub controllers mounted beside the current chat.
use super::*;
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
    /// Swift's ComposerViewController.mentionPullRequest: the link replaces
    /// the selection at the caret of the open conversation's composer.
    pub(super) fn mention_pull_request(
        &mut self,
        mention: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.selected.is_none() {
            return;
        }
        let inserted = self.composer.update(cx, |input, cx| {
            use gpui_kit::EntityInputHandler;
            if !input.is_editable() || input.marked_text_range(window, cx).is_some() {
                return false;
            }
            let text = input.value().to_string();
            let range = input.selected_range();
            let (Some(before), Some(through)) = (text.get(..range.start), text.get(..range.end))
            else {
                return false;
            };
            let insertion = github_review::mention_insertion(&text, range.start, mention);
            let utf16 = before.encode_utf16().count()..through.encode_utf16().count();
            input.replace_text_in_range(Some(utf16), &insertion, window, cx);
            true
        });
        if inserted {
            self.composer.read(cx).focus_handle(cx).focus(window, cx);
        }
        cx.notify();
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
                .child(
                    div()
                        .p_2()
                        .flex()
                        .gap_2()
                        .child(
                            Button::new("workspace-diff-tab")
                                .label("Diff")
                                .selected(self.diff_tab_visible())
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.github_open = false;
                                    this.github_threads_open = false;
                                    this.git_tools_open = false;
                                    this.remember_current_inspector(cx);
                                    this.sync_github_context(cx);
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new("workspace-local-tab")
                                .label("Local Git")
                                .selected(
                                    self.git_tools_open
                                        && !self.github_open
                                        && !self.github_threads_open,
                                )
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.github_open = false;
                                    this.github_threads_open = false;
                                    this.git_tools_open = true;
                                    this.remember_current_inspector(cx);
                                    this.sync_github_context(cx);
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new("workspace-github-tab")
                                .label("GitHub pull requests")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.github_open = true;
                                    this.github_threads_open = false;
                                    this.remember_current_inspector(cx);
                                    this.sync_workspace_context(cx);
                                    cx.notify();
                                })),
                        )
                        .child(Button::new("workspace-github-threads-tab").label("Inline review threads")
                            .on_click(cx.listener(|this,_,window,cx|{
                                this.github_open=false;this.github_threads_open=true;this.github_threads_scope_stale=false;
                                this.remember_current_inspector(cx);
                                this.sync_workspace_context(cx);
                                let loaded=this.github_panel.read(cx).loaded_pr_scope(cx);
                                this.github_threads_seed=loaded.clone();
                                if let Some((repository,number,head))=loaded {
                                    this.github_threads_panel.update(cx,|panel,cx|panel.set_pr(repository,number,head,window,cx));
                                }
                                cx.notify();
                            }))),
                )
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
