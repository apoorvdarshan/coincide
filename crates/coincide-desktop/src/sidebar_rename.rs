//! Swift's inline rename: a conversation's or project's title becomes a field
//! in its sidebar row. Return or a click elsewhere saves; Escape restores the
//! title. An empty or unchanged name changes nothing, as in Swift.
use super::*;

#[derive(Clone)]
pub(super) enum Renaming {
    Thread(String),
    /// The project and the Core review its rename commits against.
    Project(String, Value),
}

/// The name to save, or None when it is empty or unchanged.
fn renamed(typed: &str, current: &str) -> Option<String> {
    let name = typed.trim();
    (!name.is_empty() && name != current).then(|| name.to_owned())
}

impl Coincide {
    pub(super) fn renaming_thread(&self, id: &str) -> bool {
        matches!(&self.sidebar_renaming, Some(Renaming::Thread(target)) if target == id)
    }
    pub(super) fn renaming_project(&self, id: &str) -> bool {
        matches!(&self.sidebar_renaming, Some(Renaming::Project(target, _)) if target == id)
    }
    fn edit_name(&mut self, name: String, window: &mut Window, cx: &mut Context<Self>) {
        self.rename_input.update(cx, |input, cx| {
            input.set_value(name, window, cx);
            input.select_all(window, cx);
        });
        self.rename_input
            .read(cx)
            .focus_handle(cx)
            .focus(window, cx);
        cx.notify();
    }
    /// Makes the conversation's row visible (Swift's beginRename(threadID:)):
    /// the list open, the search cleared and its project expanded.
    fn reveal_sidebar_row(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.thread_list_open = true;
        let visible = |this: &Self, cx: &Context<Self>| {
            this.bulk_sidebar_binding(cx)
                .rows
                .iter()
                .any(|row| row.0 == id)
        };
        if visible(self, cx) {
            return;
        }
        if !self.search.read(cx).value().trim().is_empty() {
            self.search
                .update(cx, |input, cx| input.set_value("", window, cx));
            self.refresh(cx);
        }
        let project = self
            .threads
            .iter()
            .find(|thread| thread.id == id)
            .map(|thread| thread.project_id.clone());
        if let Some(project) = project
            .as_ref()
            .filter(|project| self.collapsed_projects.contains(*project))
        {
            self.sidebar_expand_project(project, true, cx);
        }
        if !visible(self, cx) {
            if let Some(project) = project {
                self.expanded_sidebar_lists.insert(project);
            }
        }
    }
    /// Swift renames on a second click of the open conversation's title: the
    /// second click of a double-click whose first landed on the open row.
    pub(super) fn sidebar_title_click(&mut self, id: &str, count: usize) -> bool {
        let open = self
            .selected
            .as_ref()
            .is_some_and(|thread| thread["id"] == id);
        match count {
            1 => {
                self.sidebar_rename_candidate = open.then(|| id.to_owned());
                false
            }
            2 => open && self.sidebar_rename_candidate.take().as_deref() == Some(id),
            _ => false,
        }
    }
    pub(super) fn begin_sidebar_rename(
        &mut self,
        id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        let title = self
            .threads
            .iter()
            .find(|thread| thread.id == id)
            .map(|thread| thread.title.clone())
            .or_else(|| {
                self.selected
                    .as_ref()
                    .filter(|thread| thread["id"] == id)
                    .map(|thread| text(thread, "title"))
            });
        let Some(title) = title else {
            return;
        };
        // A rename already open is finished first, as a click elsewhere would.
        self.end_sidebar_rename(true, window, cx);
        self.thread_bulk.close_selection();
        self.reveal_sidebar_row(id, window, cx);
        self.sidebar_renaming = Some(Renaming::Thread(id.to_owned()));
        self.edit_name(title, window, cx);
    }
    pub(super) fn begin_project_rename(
        &mut self,
        id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.project_ui_admitted() {
            return;
        }
        match call(
            &self.engine,
            "projects.prepare",
            json!({"projectId":id,"action":"rename"}),
        ) {
            Ok(preview) => {
                self.end_sidebar_rename(true, window, cx);
                let name = text(&preview, "name");
                self.sidebar_renaming = Some(Renaming::Project(id.to_owned(), preview));
                self.edit_name(name, window, cx);
            }
            Err(error) => {
                self.status = format!("Project could not be renamed: {error}");
                cx.notify();
            }
        }
    }
    /// Saves the typed name when `save`, otherwise restores the title, then
    /// returns the keyboard to the list.
    pub(super) fn end_sidebar_rename(
        &mut self,
        save: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(renaming) = self.sidebar_renaming.take() else {
            return;
        };
        let typed = self.rename_input.read(cx).value().to_string();
        match renaming {
            Renaming::Thread(id) if save => {
                let current = self
                    .threads
                    .iter()
                    .find(|thread| thread.id == id)
                    .map(|thread| thread.title.clone())
                    .unwrap_or_default();
                if let Some(title) = renamed(&typed, &current) {
                    if title.len() > 512 || title.chars().any(char::is_control) {
                        self.status =
                            "Use a title up to 512 bytes without control characters.".into();
                    } else {
                        self.patch_navigation(
                            &id,
                            json!({"title":title}),
                            "Conversation renamed.",
                            cx,
                        );
                    }
                }
            }
            Renaming::Project(id, preview) if save => {
                if let Some(name) = renamed(&typed, &text(&preview, "name")) {
                    match call(
                        &self.engine,
                        "projects.rename",
                        json!({"projectId":id,"ticket":preview["ticket"],"name":name}),
                    ) {
                        Ok(_) => {
                            self.refresh(cx);
                        }
                        Err(error) => {
                            self.status = format!("Project could not be renamed: {error}")
                        }
                    }
                }
            }
            _ => {}
        }
        if self.thread_list_open {
            self.thread_list_focus.focus(window, cx);
        }
        cx.notify();
    }
    /// The field that replaces a row's title while it is renamed.
    pub(super) fn sidebar_rename_field(&self, cx: &mut Context<Self>) -> AnyElement {
        div()
            .w_full()
            .min_w_0()
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                if event.keystroke.key == "escape" {
                    this.end_sidebar_rename(false, window, cx);
                    cx.stop_propagation();
                }
            }))
            .child(Input::new(&self.rename_input).h(px(26.)))
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::renamed;
    #[::core::prelude::v1::test]
    fn only_a_changed_nonempty_name_is_saved_and_it_is_trimmed() {
        assert_eq!(renamed("  New name ", "Old"), Some("New name".into()));
        assert_eq!(renamed("Old", "Old"), None);
        assert_eq!(renamed(" Old ", "Old"), None);
        assert_eq!(renamed("   ", "Old"), None);
    }
}
