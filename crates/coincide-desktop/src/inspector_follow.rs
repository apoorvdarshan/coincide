//! Presentation follows actual loaded threads. Saved JSON never opens a tab,
//! starts terminal discovery, refreshes GitHub, or restores any native proof.
use super::*;
pub(super) use coincide_core::inspector_preferences::Panel as SavedPanel;
use coincide_core::inspector_preferences::{self as preferences, Change};
#[derive(Default)]
pub(super) struct State {
    bound: Option<String>,
    pending: std::collections::BTreeMap<String, Option<SavedPanel>>,
    failed: std::collections::BTreeSet<String>,
    pub(super) terminal_placeholder: bool,
    pub(super) preview_placeholder: bool,
    pub(super) error: Option<String>,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct RestorePlan {
    workspace: bool,
    pull_requests: bool,
    preview: bool,
    terminal: bool,
    terminal_placeholder: bool,
    preview_placeholder: bool,
}
fn restore_plan(
    panel: SavedPanel,
    right: bool,
    owned_terminal: bool,
    browser_available: bool,
) -> Option<RestorePlan> {
    Some(match panel {
        SavedPanel::Diff => RestorePlan {
            workspace: true,
            ..RestorePlan::default()
        },
        SavedPanel::PullRequests => RestorePlan {
            workspace: true,
            pull_requests: true,
            ..RestorePlan::default()
        },
        SavedPanel::Preview => RestorePlan {
            preview: true,
            preview_placeholder: !browser_available,
            ..RestorePlan::default()
        },
        SavedPanel::Terminal if right => RestorePlan {
            terminal: owned_terminal,
            terminal_placeholder: !owned_terminal,
            ..RestorePlan::default()
        },
        SavedPanel::Terminal | SavedPanel::Schedules => return None,
    })
}
impl Coincide {
    fn current_inspector_choice(&self) -> Option<SavedPanel> {
        if self.schedules_open {
            return Some(SavedPanel::Schedules);
        }
        match self.chat_inspector_panel() {
            Some(chat_inspector::Panel::Workspace) => {
                Some(if self.github_open || self.github_threads_open {
                    SavedPanel::PullRequests
                } else {
                    SavedPanel::Diff
                })
            }
            Some(chat_inspector::Panel::Browser) => Some(SavedPanel::Preview),
            Some(chat_inspector::Panel::Terminal) => Some(SavedPanel::Terminal),
            Some(chat_inspector::Panel::ConversationSchedules) => Some(SavedPanel::Schedules),
            None => None,
        }
    }
    pub(super) fn suspend_inspector_presentation(&mut self, cx: &mut Context<Self>) {
        if let Some(previous) = self.terminal_visible_thread.take()
            && let Some(workspace) = self.terminal_workspaces.get(&previous)
        {
            workspace.update(cx, |workspace, cx| workspace.set_visible(false, cx));
        }
        if let Some(browser) = &mut self.browser {
            browser.set_thread_visible(None, cx);
        }
    }
    pub(super) fn restore_inspector_for_selected(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            self.inspector_follow.bound = None;
            self.suspend_inspector_presentation(cx);
            return;
        };
        if self.inspector_follow.bound.as_deref() == Some(id.as_str()) {
            return;
        }
        if self
            .current_inspector_choice()
            .is_some_and(SavedPanel::window_wide)
        {
            self.inspector_follow.bound = Some(id);
            return;
        }
        let result = (|| -> Result<Option<SavedPanel>> {
            if let Some(pending) = self.inspector_follow.pending.get(&id) {
                return Ok(*pending);
            }
            let engine = try_state(&self.engine)?;
            let document = engine
                .store
                .native_inspector_document()?
                .unwrap_or_else(|| json!({}));
            preferences::saved(&document, &id)
        })();
        let saved = match result {
            Ok(saved) => saved,
            Err(error) => {
                self.inspector_follow.error =
                    Some(format!("Inspector state was not restored: {error}"));
                self.status = self.inspector_follow.error.clone().unwrap();
                self.clear_inspector_placeholders();
                self.workspace_open = false;
                if self.terminal_on_right() {
                    self.terminal_open = false;
                }
                self.hide_selected_browser_surface(cx);
                return;
            }
        };
        let current = self.current_inspector_choice();
        let change = preferences::follow(current, saved, self.terminal_on_right());
        // Even an unchanged panel type follows a different native context. No
        // tab/session/PTY is created to satisfy the saved display preference.
        self.suspend_inspector_presentation(cx);
        self.inspector_follow.terminal_placeholder = false;
        self.inspector_follow.preview_placeholder = false;
        match change {
            Change::None if saved.is_none() => {
                self.workspace_open = false;
                if self.terminal_on_right() {
                    self.terminal_open = false;
                }
                self.hide_selected_browser_surface(cx);
            }
            Change::None | Change::Show(_) => {
                if let Some(panel) = saved {
                    self.apply_saved_inspector(panel, &id, cx);
                }
            }
            Change::Close => {
                self.workspace_open = false;
                if self.terminal_on_right() {
                    self.terminal_open = false;
                }
                self.hide_selected_browser_surface(cx);
            }
        }
        if !self.inspector_follow.failed.contains(&id) {
            self.inspector_follow.error = None;
        }
        self.inspector_follow.bound = Some(id);
        self.sync_github_context(cx);
    }
    fn apply_saved_inspector(&mut self, panel: SavedPanel, id: &str, cx: &mut Context<Self>) {
        self.workspace_open = false;
        if self.terminal_on_right() {
            self.terminal_open = false;
        }
        self.hide_selected_browser_surface(cx);
        let Some(plan) = restore_plan(
            panel,
            self.terminal_on_right(),
            self.terminal_workspaces.contains_key(id),
            self.browser.is_some(),
        ) else {
            return;
        };
        self.workspace_open = plan.workspace;
        if plan.workspace {
            self.github_open = plan.pull_requests;
            self.github_threads_open = false;
        }
        if plan.preview {
            self.browser_panels.insert(id.to_owned());
        }
        if self.terminal_on_right() {
            self.terminal_open = plan.terminal;
        }
        self.inspector_follow.terminal_placeholder = plan.terminal_placeholder;
        self.inspector_follow.preview_placeholder = plan.preview_placeholder;
    }
    pub(super) fn remember_current_inspector(&mut self, cx: &mut Context<Self>) {
        let choice = self.current_inspector_choice();
        self.remember_inspector_choice(choice, cx);
    }
    pub(super) fn remember_inspector_choice(
        &mut self,
        choice: Option<SavedPanel>,
        cx: &mut Context<Self>,
    ) {
        if choice.is_some_and(SavedPanel::window_wide)
            || self.media.close_requested
            || self.media.shutdown_requested
        {
            return;
        }
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return;
        };
        if self.inspector_follow.pending.len() >= 32
            && !self.inspector_follow.pending.contains_key(&id)
        {
            self.inspector_follow.error = Some(
                "Inspector choice is kept for this session; saved preferences are busy.".into(),
            );
            return;
        }
        self.inspector_follow.failed.remove(&id);
        self.inspector_follow.pending.insert(id.clone(), choice);
        self.inspector_follow.bound = Some(id);
        self.persist_current_inspector(cx);
    }
    fn persist_current_inspector(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return;
        };
        let Some(choice) = self.inspector_follow.pending.get(&id).copied() else {
            return;
        };
        let result = (|| -> Result<()> {
            let mut engine = try_state(&self.engine)?;
            anyhow::ensure!(
                !engine.admissions_frozen() && !engine.shutdown,
                "App is closing"
            );
            let source = engine.store.native_inspector_document()?;
            engine
                .store
                .remember_native_inspector_panel(source.as_ref(), &id, choice)?;
            Ok(())
        })();
        match result {
            Ok(()) => {
                self.inspector_follow.pending.remove(&id);
                self.inspector_follow.failed.remove(&id);
                self.inspector_follow.error = None;
            }
            Err(error) => {
                // A failed compare-and-save must not silently rebase over a
                // newer writer. Only an explicit new native choice retries it.
                if !engine_busy(&error) {
                    self.inspector_follow.failed.insert(id);
                }
                self.inspector_follow.error = Some(format!(
                    "Inspector choice is kept for this session; could not save: {error}"
                ));
            }
        }
        cx.notify();
    }
    pub(super) fn poll_inspector_follow(&mut self, cx: &mut Context<Self>) {
        if self.media.close_requested || self.media.shutdown_requested {
            return;
        }
        self.restore_inspector_for_selected(cx);
        if self.selected.as_ref().is_some_and(|thread| {
            self.inspector_follow
                .pending
                .contains_key(&text(thread, "id"))
                && !self.inspector_follow.failed.contains(&text(thread, "id"))
        }) {
            self.persist_current_inspector(cx);
        }
    }
    pub(super) fn clear_inspector_placeholders(&mut self) {
        self.inspector_follow.terminal_placeholder = false;
        self.inspector_follow.preview_placeholder = false;
    }
    pub(super) fn saved_inspector_placeholder(
        &self,
        terminal: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut view=div().flex().flex_col().gap_3().p_4().child(if terminal {"Terminal"}else{"Browser"})
            .child(if terminal {"The saved panel is open. Open Terminal to discover this conversation's actual running shells."}else{"The native browser is unavailable for this session. Saved panel data has not opened a page."});
        if terminal {
            view = view.child(
                Button::new("restore-terminal-explicit-open")
                    .label("Open Terminal")
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.clear_inspector_placeholders();
                        this.terminal(window, cx);
                    })),
            );
        }
        view.child(
            Button::new("close-saved-inspector")
                .label("Close panel")
                .on_click(cx.listener(|this, _, _, cx| this.close_chat_inspector(cx))),
        )
        .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::{SavedPanel, restore_plan};
    #[::core::prelude::v1::test]
    fn saved_terminal_is_presentation_only_until_an_actual_owned_workspace_exists() {
        let cold = restore_plan(SavedPanel::Terminal, true, false, false).unwrap();
        assert!(!cold.terminal && cold.terminal_placeholder);
        assert!(!cold.preview && !cold.workspace);
        let retained = restore_plan(SavedPanel::Terminal, true, true, false).unwrap();
        assert!(retained.terminal && !retained.terminal_placeholder);
        assert!(restore_plan(SavedPanel::Terminal, false, true, true).is_none());
    }
    #[::core::prelude::v1::test]
    fn saved_panels_never_select_inline_review_or_create_browser_owners_and_schedules_stay_windowwide()
     {
        let preview = restore_plan(SavedPanel::Preview, true, false, false).unwrap();
        assert!(preview.preview && preview.preview_placeholder);
        assert!(!preview.terminal && !preview.workspace);
        let requests = restore_plan(SavedPanel::PullRequests, true, false, true).unwrap();
        assert!(requests.workspace && requests.pull_requests);
        assert!(!requests.preview && !requests.terminal);
        assert!(restore_plan(SavedPanel::Schedules, true, true, true).is_none());
    }
}
