//! Swift's sidebar drops: a conversation dropped on a project, on Chats or
//! among a project's conversations moves there (through the move review),
//! and folders dropped from the file manager are added as projects.
use super::*;

#[derive(Clone)]
pub(super) struct ThreadDrag {
    pub id: String,
    pub title: String,
    pub project: String,
    /// Dragged from Pinned, whose order only pinned rows change.
    pub pinned: bool,
}
impl Render for ThreadDrag {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().child(self.title.clone())
    }
}

/// Whether a dropped conversation moves into `project`: another ordinary
/// project or Chats, never the bots' list or where it already is.
pub(super) fn moves_into(drag: &ThreadDrag, project: &str) -> bool {
    !drag.project.eq_ignore_ascii_case(project)
        && !project.eq_ignore_ascii_case(coincide_core::bot_runtime::BOTS_PROJECT_ID)
}

impl Coincide {
    pub(super) fn sidebar_drop_on_project(
        &mut self,
        drag: &ThreadDrag,
        project: &str,
        cx: &mut Context<Self>,
    ) {
        if self.thread_bulk.mode
            || self.media.shutdown_requested
            || self.media.close_requested
            || !moves_into(drag, project)
        {
            return;
        }
        self.sidebar_move_to(drag.id.clone(), project.to_owned(), cx);
    }
    /// Swift's `ThreadActions.addProjects`: the dropped folders become
    /// projects, then the first opens at its latest conversation or a new one.
    pub(super) fn sidebar_drop_folders(
        &mut self,
        paths: &ExternalPaths,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let folders = paths
            .paths()
            .iter()
            .filter(|path| path.is_dir())
            .cloned()
            .collect::<Vec<_>>();
        if folders.is_empty() || !self.project_ui_admitted() {
            return;
        }
        let picker_was_open = self.project_picker_open;
        self.open_project_form(project_management::Mode::Add, None, window, cx);
        self.project_management.folders = folders;
        self.add_project(window, cx);
        // A failure stays in the form, which shows why.
        if !self.project_management.session.open && !picker_was_open {
            self.project_picker_open = false;
        }
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn conversations_move_only_into_another_ordinary_project() {
        let drag = ThreadDrag {
            id: "thread".into(),
            title: "Title".into(),
            project: "AAAA".into(),
            pinned: false,
        };
        assert!(moves_into(&drag, "bbbb"));
        assert!(moves_into(&drag, navigation::NO_PROJECT_ID));
        assert!(!moves_into(&drag, "aaaa"));
        assert!(!moves_into(
            &drag,
            &coincide_core::bot_runtime::BOTS_PROJECT_ID.to_uppercase()
        ));
    }
}
