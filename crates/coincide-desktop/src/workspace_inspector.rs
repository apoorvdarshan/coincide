//! Retained workspace/GitHub controllers mounted beside the current chat.
use super::*;
impl Coincide {
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
