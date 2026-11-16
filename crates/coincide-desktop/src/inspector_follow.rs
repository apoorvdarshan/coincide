//! Presentation follows actual loaded threads. Saved JSON never opens a tab,
//! starts terminal discovery, refreshes GitHub, or restores any native proof.
use super::*;
pub(super) use coincide_core::inspector_preferences::Panel as SavedPanel;
use coincide_core::inspector_preferences::{self as preferences, Change};
#[derive(Default)]
pub(super) struct State {
    bound: Option<String>,
    /// The last presentation for each visited thread, including a closed one.
    /// This lets switching stay immediate even while the store is busy.
    choices: std::collections::BTreeMap<String, Option<SavedPanel>>,
    /// Snapshot loaded before the selected conversation is presented. Local
    /// edits in `choices` always take precedence over this display-only cache.
    document: Option<Value>,
    deferred_browser_hides: std::collections::BTreeSet<String>,
    pending: std::collections::BTreeMap<String, Option<SavedPanel>>,
    failed: std::collections::BTreeSet<String>,
    pub(super) terminal_placeholder: bool,
    pub(super) preview_placeholder: bool,
    pub(super) error: Option<String>,
}
#[derive(Debug, PartialEq, Eq)]
pub(super) enum SavedChoice {
    Deferred,
    Ready(Option<SavedPanel>),
}
pub(super) fn read_saved_choice(engine: &SharedEngine, id: &str) -> Result<SavedChoice> {
    let engine = match try_state(engine) {
        Ok(engine) => engine,
        // The next existing main-window poll retries this read. Contention did
        // not read the document, so it must not close a pane or publish failure.
        Err(error) if engine_busy(&error) => return Ok(SavedChoice::Deferred),
        Err(error) => return Err(error),
    };
    let document = engine
        .store
        .native_inspector_document()?
        .unwrap_or_else(|| json!({}));
    preferences::saved(&document, id).map(SavedChoice::Ready)
}
impl State {
    pub(super) fn load(engine: &SharedEngine) -> Self {
        let document = try_state(engine)
            .ok()
            .and_then(|engine| engine.store.native_inspector_document().ok())
            .map(|document| document.unwrap_or_else(|| json!({})))
            .filter(|document| preferences::validate(document).is_ok());
        Self {
            document,
            ..Self::default()
        }
    }
    fn remembered(&self, id: &str) -> Option<Option<SavedPanel>> {
        self.pending
            .get(id)
            .or_else(|| self.choices.get(id))
            .copied()
    }
    fn choice(&self, engine: &SharedEngine, id: &str) -> Result<SavedChoice> {
        if self.deferred_browser_hides.contains(id) {
            return Ok(SavedChoice::Deferred);
        }
        match self.remembered(id) {
            Some(choice) => Ok(SavedChoice::Ready(choice)),
            None if self.document.is_some() => {
                preferences::saved(self.document.as_ref().unwrap(), id).map(SavedChoice::Ready)
            }
            None => read_saved_choice(engine, id),
        }
    }
    /// Resolve the destination before changing the visible conversation. A
    /// temporarily busy store keeps the previous layout on screen until the
    /// target panel and thread can be presented together.
    pub(super) fn prepare_destination(&mut self, engine: &SharedEngine, id: &str) -> Result<bool> {
        match self.choice(engine, id)? {
            SavedChoice::Deferred => Ok(false),
            SavedChoice::Ready(choice) => {
                self.choices.insert(id.to_owned(), choice);
                Ok(true)
            }
        }
    }
    /// A damaged saved preference must not make the conversation inaccessible.
    /// Keep the fallback in memory; do not overwrite the saved document.
    pub(super) fn fallback_destination(&mut self, id: &str) {
        self.choices.insert(id.to_owned(), None);
    }
    /// Keep the newest choice queued while the engine is temporarily busy.
    /// A successful retry updates the store; a real failure is still reported.
    fn persist_choice(&mut self, engine: &SharedEngine, id: &str) -> bool {
        let Some(choice) = self.pending.get(id).copied() else {
            return false;
        };
        let result = (|| -> Result<Value> {
            let mut engine = try_state(engine)?;
            anyhow::ensure!(
                !engine.admissions_frozen() && !engine.shutdown,
                "App is closing"
            );
            let source = engine.store.native_inspector_document()?;
            let saved =
                engine
                    .store
                    .remember_native_inspector_panel(source.as_ref(), id, choice)?;
            Ok(saved)
        })();
        match result {
            Ok(document) => {
                self.document = Some(document);
                self.pending.remove(id);
                self.failed.remove(id);
                self.error = None;
            }
            Err(error) if engine_busy(&error) => return false,
            Err(error) => {
                // Do not silently rebase a failed compare-and-save. A new
                // explicit choice may retry it against the newer state.
                eprintln!("Inspector choice could not be saved: {error}");
                self.failed.insert(id.to_owned());
                self.error = Some(format!(
                    "Inspector choice is kept for this session; could not save: {error}"
                ));
            }
        }
        true
    }
    pub(super) fn clear_loaded_error(&mut self, id: &str, status: &mut String) {
        if !self.failed.contains(id) {
            if self.error.as_ref().is_some_and(|error| error == status) {
                status.clear();
            }
            self.error = None;
        }
    }
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct RestorePlan {
    workspace: bool,
    pull_requests: bool,
    local_git: bool,
    review_comments: bool,
    conversation_schedules: bool,
    schedules: bool,
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
        SavedPanel::LocalGit => RestorePlan {
            workspace: true,
            local_git: true,
            ..RestorePlan::default()
        },
        SavedPanel::PullRequests => RestorePlan {
            workspace: true,
            pull_requests: true,
            ..RestorePlan::default()
        },
        SavedPanel::ReviewComments => RestorePlan {
            workspace: true,
            review_comments: true,
            ..RestorePlan::default()
        },
        SavedPanel::ConversationSchedules => RestorePlan {
            conversation_schedules: true,
            ..RestorePlan::default()
        },
        SavedPanel::Schedules => RestorePlan {
            schedules: true,
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
        SavedPanel::Terminal => return None,
    })
}
impl Coincide {
    fn current_inspector_choice(&self) -> Option<SavedPanel> {
        if self.global_schedules_route() {
            return Some(SavedPanel::Schedules);
        }
        match self.chat_inspector_panel() {
            Some(chat_inspector::Panel::Workspace) => Some(if self.github_threads_open {
                SavedPanel::ReviewComments
            } else if self.github_open {
                SavedPanel::PullRequests
            } else if self.git_tools_open {
                SavedPanel::LocalGit
            } else {
                SavedPanel::Diff
            }),
            Some(chat_inspector::Panel::Browser) => Some(SavedPanel::Preview),
            Some(chat_inspector::Panel::Terminal) => Some(SavedPanel::Terminal),
            Some(chat_inspector::Panel::ConversationSchedules) => {
                Some(SavedPanel::ConversationSchedules)
            }
            Some(chat_inspector::Panel::Schedules) => Some(SavedPanel::Schedules),
            None => None,
        }
    }
    /// Called before replacing a different thread. Preserve its choice, then
    /// clear only the shared presentation flags; owned tabs and PTYs stay alive.
    pub(super) fn prepare_inspector_thread_change(&mut self) {
        if let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id"))
            && self.inspector_follow.bound.as_deref() == Some(id.as_str())
            && self.chat_visible()
            && !self.inspector_follow.choices.contains_key(&id)
        {
            let choice = self.current_inspector_choice();
            self.inspector_follow.choices.insert(id, choice);
        }
        self.workspace_open = false;
        if self.terminal_on_right() {
            self.terminal_open = false;
        }
        if self.schedules_open {
            self.close_schedule_surface();
        }
        self.clear_inspector_placeholders();
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
        let result = self.inspector_follow.choice(&self.engine, &id);
        let saved = match result {
            Ok(SavedChoice::Deferred) => return,
            Ok(SavedChoice::Ready(saved)) => saved,
            Err(error) => {
                eprintln!("Inspector state could not be restored: {error}");
                self.inspector_follow.error =
                    Some(format!("Inspector state was not restored: {error}"));
                self.clear_inspector_placeholders();
                self.workspace_open = false;
                if self.terminal_on_right() {
                    self.terminal_open = false;
                }
                self.hide_selected_browser_surface(cx);
                self.inspector_follow.bound = Some(id);
                return;
            }
        };
        self.inspector_follow.choices.insert(id.clone(), saved);
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
                if self.schedules_open {
                    self.close_schedule_surface();
                }
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
                if self.schedules_open {
                    self.close_schedule_surface();
                }
                if self.terminal_on_right() {
                    self.terminal_open = false;
                }
                self.hide_selected_browser_surface(cx);
            }
        }
        self.inspector_follow
            .clear_loaded_error(&id, &mut self.status);
        self.inspector_follow.bound = Some(id);
        self.sync_github_context(cx);
    }
    fn apply_saved_inspector(&mut self, panel: SavedPanel, id: &str, cx: &mut Context<Self>) {
        self.workspace_open = false;
        if self.schedules_open {
            self.close_schedule_surface();
        }
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
            self.github_threads_open = plan.review_comments;
            self.git_tools_open = plan.local_git;
        }
        if plan.conversation_schedules {
            self.restore_conversation_schedules(cx);
        }
        if plan.schedules {
            self.restore_global_schedules(cx);
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
        if self.media.close_requested || self.media.shutdown_requested {
            return;
        }
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return;
        };
        self.remember_thread_inspector_choice(&id, choice, cx);
    }
    /// A background browser request owns its originating thread, not the chat
    /// that happens to be selected when the request completes.
    pub(super) fn remember_background_browser_visibility(
        &mut self,
        id: &str,
        visible: bool,
        cx: &mut Context<Self>,
    ) {
        if self
            .selected
            .as_ref()
            .is_some_and(|thread| thread["id"] == id)
        {
            return;
        }
        if visible {
            self.remember_thread_inspector_choice(id, Some(SavedPanel::Preview), cx);
        } else {
            match self.inspector_follow.choice(&self.engine, id) {
                Ok(SavedChoice::Ready(Some(SavedPanel::Preview))) => {
                    self.remember_thread_inspector_choice(id, None, cx);
                }
                Ok(SavedChoice::Deferred) => {
                    self.inspector_follow
                        .deferred_browser_hides
                        .insert(id.to_owned());
                }
                _ => {}
            }
        }
    }
    fn remember_thread_inspector_choice(
        &mut self,
        id: &str,
        choice: Option<SavedPanel>,
        cx: &mut Context<Self>,
    ) {
        if self.media.close_requested || self.media.shutdown_requested {
            return;
        }
        let id = id.to_owned();
        self.inspector_follow.deferred_browser_hides.remove(&id);
        self.inspector_follow.choices.insert(id.clone(), choice);
        if self
            .selected
            .as_ref()
            .is_some_and(|thread| thread["id"] == id)
        {
            self.inspector_follow.bound = Some(id.clone());
        }
        self.inspector_follow.failed.remove(&id);
        self.inspector_follow.pending.insert(id.clone(), choice);
        self.persist_inspector_choice(&id, cx);
    }
    fn persist_inspector_choice(&mut self, id: &str, cx: &mut Context<Self>) {
        if self.inspector_follow.persist_choice(&self.engine, id) {
            cx.notify();
        }
    }
    pub(super) fn poll_inspector_follow(&mut self, cx: &mut Context<Self>) {
        if self.media.close_requested || self.media.shutdown_requested {
            return;
        }
        if let Some(id) = self
            .inspector_follow
            .deferred_browser_hides
            .iter()
            .next()
            .cloned()
        {
            match read_saved_choice(&self.engine, &id) {
                Ok(SavedChoice::Ready(choice)) => {
                    self.inspector_follow.deferred_browser_hides.remove(&id);
                    if choice == Some(SavedPanel::Preview) {
                        self.remember_thread_inspector_choice(&id, None, cx);
                    }
                }
                Ok(SavedChoice::Deferred) => {}
                Err(_) => {
                    self.inspector_follow.deferred_browser_hides.remove(&id);
                }
            }
        }
        self.restore_inspector_for_selected(cx);
        if let Some(id) = self
            .inspector_follow
            .pending
            .keys()
            .find(|id| !self.inspector_follow.failed.contains(*id))
            .cloned()
        {
            self.persist_inspector_choice(&id, cx);
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
    use super::{SavedPanel, State, restore_plan};
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
    fn saved_panels_do_not_create_browser_owners_and_schedules_restore_as_panels() {
        let preview = restore_plan(SavedPanel::Preview, true, false, false).unwrap();
        assert!(preview.preview && preview.preview_placeholder);
        assert!(!preview.terminal && !preview.workspace);
        let requests = restore_plan(SavedPanel::PullRequests, true, false, true).unwrap();
        assert!(requests.workspace && requests.pull_requests);
        assert!(!requests.preview && !requests.terminal);
        assert!(
            restore_plan(SavedPanel::Schedules, true, true, true)
                .unwrap()
                .schedules
        );
    }
    #[::core::prelude::v1::test]
    fn remembered_panel_is_isolated_per_thread_even_when_writes_are_pending() {
        let mut state = State::default();
        state.choices.insert("a".into(), Some(SavedPanel::Preview));
        state.choices.insert("b".into(), None);
        assert_eq!(state.remembered("a"), Some(Some(SavedPanel::Preview)));
        assert_eq!(state.remembered("b"), Some(None));
        assert_eq!(state.remembered("c"), None);
        state.pending.insert("a".into(), Some(SavedPanel::LocalGit));
        assert_eq!(state.remembered("a"), Some(Some(SavedPanel::LocalGit)));
        assert_eq!(state.remembered("b"), Some(None));
        let local = restore_plan(SavedPanel::LocalGit, true, false, true).unwrap();
        assert!(local.workspace && local.local_git && !local.pull_requests);
        let comments = restore_plan(SavedPanel::ReviewComments, true, false, true).unwrap();
        assert!(comments.workspace && comments.review_comments && !comments.pull_requests);
        let schedule = restore_plan(SavedPanel::ConversationSchedules, true, false, true).unwrap();
        assert!(schedule.conversation_schedules && !schedule.workspace);
    }
    #[::core::prelude::v1::test]
    fn busy_store_never_leaks_another_threads_panel_or_blocks_a_visited_thread() {
        use super::SavedChoice;
        use coincide_core::{api::Engine, store::Store};
        use std::sync::{Arc, Mutex};
        let directory = tempfile::tempdir().unwrap();
        let mut store = Store::open(&directory.path().join("state.sqlite")).unwrap();
        let c = "00000000-0000-4000-8000-000000000003";
        store
            .save_document(
                "ui-state.json",
                &serde_json::json!({"threadPanels":{(c):"pullRequests"}}),
            )
            .unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(store)));
        let mut state = State::default();
        state.choices.insert("a".into(), Some(SavedPanel::Preview));
        state.choices.insert("b".into(), None);
        let held = engine.lock().unwrap();
        assert_eq!(
            state.choice(&engine, "a").unwrap(),
            SavedChoice::Ready(Some(SavedPanel::Preview))
        );
        assert_eq!(
            state.choice(&engine, "b").unwrap(),
            SavedChoice::Ready(None)
        );
        assert_eq!(state.choice(&engine, c).unwrap(), SavedChoice::Deferred);
        drop(held);
        state.deferred_browser_hides.insert(c.to_owned());
        assert_eq!(state.choice(&engine, c).unwrap(), SavedChoice::Deferred);
        state.deferred_browser_hides.remove(c);
        assert_eq!(
            state.choice(&engine, c).unwrap(),
            SavedChoice::Ready(Some(SavedPanel::PullRequests))
        );
    }

    #[::core::prelude::v1::test]
    fn saved_destination_is_ready_before_switch_even_while_store_is_busy() {
        use super::SavedChoice;
        use coincide_core::{api::Engine, store::Store};
        use std::sync::{Arc, Mutex};
        let directory = tempfile::tempdir().unwrap();
        let mut store = Store::open(&directory.path().join("state.sqlite")).unwrap();
        let open = "00000000-0000-4000-8000-000000000001";
        let closed = "00000000-0000-4000-8000-000000000002";
        store
            .save_document(
                "ui-state.json",
                &serde_json::json!({"threadPanels":{(open):"pullRequests"}}),
            )
            .unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(store)));
        let mut cached = State::load(&engine);
        let mut cold = State::default();
        let held = engine.lock().unwrap();
        assert!(cached.prepare_destination(&engine, open).unwrap());
        assert!(cached.prepare_destination(&engine, closed).unwrap());
        assert_eq!(
            cached.choice(&engine, open).unwrap(),
            SavedChoice::Ready(Some(SavedPanel::PullRequests))
        );
        assert_eq!(
            cached.choice(&engine, closed).unwrap(),
            SavedChoice::Ready(None)
        );
        assert!(!cold.prepare_destination(&engine, open).unwrap());
        cached
            .pending
            .insert(open.into(), Some(SavedPanel::Preview));
        assert_eq!(
            cached.choice(&engine, open).unwrap(),
            SavedChoice::Ready(Some(SavedPanel::Preview))
        );
        drop(held);
        assert!(cold.prepare_destination(&engine, open).unwrap());
        assert_eq!(
            cold.choice(&engine, open).unwrap(),
            SavedChoice::Ready(Some(SavedPanel::PullRequests))
        );
    }

    #[::core::prelude::v1::test]
    fn malformed_panel_preferences_do_not_block_switching_or_overwrite_the_document() {
        use super::SavedChoice;
        use coincide_core::{api::Engine, store::Store};
        use std::sync::{Arc, Mutex};
        let directory = tempfile::tempdir().unwrap();
        let mut store = Store::open(&directory.path().join("state.sqlite")).unwrap();
        let invalid = serde_json::json!({"threadPanels":false,"other":"keep"});
        store.save_document("ui-state.json", &invalid).unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(store)));
        let mut state = State::load(&engine);
        let id = "00000000-0000-4000-8000-000000000001";
        assert!(state.prepare_destination(&engine, id).is_err());
        state.fallback_destination(id);
        assert_eq!(state.choice(&engine, id).unwrap(), SavedChoice::Ready(None));
        assert_eq!(
            engine
                .lock()
                .unwrap()
                .store
                .native_inspector_document()
                .unwrap()
                .unwrap(),
            invalid
        );
    }

    #[::core::prelude::v1::test]
    fn busy_save_is_silent_and_persists_the_choice_after_retry() {
        use coincide_core::{api::Engine, store::Store};
        use std::sync::{Arc, Mutex};
        let directory = tempfile::tempdir().unwrap();
        let mut store = Store::open(&directory.path().join("state.sqlite")).unwrap();
        let id = "00000000-0000-4000-8000-000000000001";
        store
            .save(&serde_json::json!({"id":id,"title":"Synthetic","items":[]}))
            .unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(store)));
        let mut state = State::default();
        state.pending.insert(id.into(), Some(SavedPanel::Schedules));
        let held = engine.lock().unwrap();
        assert!(!state.persist_choice(&engine, id));
        assert!(state.error.is_none());
        assert!(state.pending.contains_key(id));
        drop(held);
        assert!(state.persist_choice(&engine, id));
        assert!(state.pending.is_empty());
        assert!(state.error.is_none());
        let document = engine
            .lock()
            .unwrap()
            .store
            .native_inspector_document()
            .unwrap()
            .unwrap();
        assert_eq!(
            coincide_core::inspector_preferences::saved(&document, id).unwrap(),
            Some(SavedPanel::Schedules)
        );
    }
}
