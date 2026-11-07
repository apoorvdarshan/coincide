//! Feeds the Diff inspector the selected thread's run state, transcript items and
//! diff settings from the main poll, and its visibility from the main render.
use super::*;

impl Coincide {
    /// `read` is set when the selected thread was just read again, so its items are new;
    /// a newly selected thread's items are read once to start following its edits.
    pub(super) fn sync_diff_thread(&mut self, read: bool, cx: &mut Context<Self>) {
        let running = self
            .selected
            .as_ref()
            .is_some_and(|thread| self.running.contains(&text(thread, "id")));
        let read = read || self.diff_panel.read(cx).awaits_items();
        let items = self
            .selected
            .as_ref()
            .filter(|_| read)
            .and_then(|thread| thread["items"].as_array())
            .map(Vec::as_slice);
        let font_size = self.conversation_font_size();
        let settings = &self.settings;
        self.diff_panel.update(cx, |panel, cx| {
            panel.apply_settings(settings, font_size, cx);
            panel.observe_thread(running, items, cx);
        });
    }

    /// Whether the Diff tab of the workspace inspector is on screen.
    pub(super) fn diff_tab_visible(&self) -> bool {
        self.chat_inspector_panel() == Some(chat_inspector::Panel::Workspace)
            && !self.github_open
            && !self.github_threads_open
            && !self.git_tools_open
    }

    pub(super) fn sync_diff_visibility(&mut self, cx: &mut Context<Self>) {
        let visible = self.diff_tab_visible();
        self.diff_panel
            .update(cx, |panel, cx| panel.set_visible(visible, cx));
    }
}
