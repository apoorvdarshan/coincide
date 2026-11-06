//! Native project forms using real Engine transactions and a directory-only picker.
use super::project_management::{Mode, Session};
use super::*;
pub(super) struct Projects {
    pub session: Session,
    name: Entity<InputState>,
    restore_focus: Option<FocusHandle>,
    pub folders: Vec<std::path::PathBuf>,
}
impl Projects {
    pub fn new(window: &mut Window, cx: &mut App) -> Self {
        Self {
            session: Session::default(),
            name: cx.new(|cx| InputState::new(window, cx).placeholder("Project name")),
            restore_focus: None,
            folders: Vec::new(),
        }
    }
}
impl Coincide {
    fn clear_removed_project_selection(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.dismiss_find(window, cx);
        self.selected = None;
        self.thread_actions_open = false;
        self.pending_requests.clear();
        self.queued_messages.clear();
        self.terminal_open = false;
        self.composer
            .update(cx, |v, cx| v.set_value("", window, cx));
        if let Some(browser) = &mut self.browser {
            browser.set_thread_visible(None, cx);
        }
        self.sync_workspace_context(cx);
        self.sync_transcription_binding(cx);
        self.sync_composer_selection(window, cx);
        self.sync_historical_image_view(window, cx);
        self.sync_terminal_workspace(window, cx);
    }
    pub(super) fn project_ui_admitted(&self) -> bool {
        !self.media.close_requested
            && !self.media.shutdown_requested
            && !self.historical_image_is_open()
    }
    pub(super) fn close_project_form(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.project_management.session.close();
        if let Some(focus) = self.project_management.restore_focus.take() {
            focus.focus(window, cx);
        }
        cx.notify();
    }
    pub(super) fn open_project_form(
        &mut self,
        mode: Mode,
        target: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.project_ui_admitted() {
            return;
        }
        if !self.project_management.session.open {
            self.project_management.restore_focus = window.focused(cx);
        }
        self.project_management.session.begin(mode, target);
        self.project_picker_open = true;
        if mode == Mode::Add {
            self.project_path
                .update(cx, |v, cx| v.set_value("", window, cx));
            self.project_management.folders.clear();
        }
        self.review_project_form(window, cx);
    }
    fn review_project_form(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.project_ui_admitted() {
            return;
        }
        let mode = self.project_management.session.mode;
        let keep_input = !self.project_management.session.error.is_empty();
        self.project_management.session.preview = None;
        self.project_management.session.error.clear();
        if mode == Mode::Recovery {
            match call(&self.engine, "projects.recovery", json!({})) {
                Ok(v) => {
                    self.project_management.session.recoveries =
                        v.as_array().cloned().unwrap_or_default()
                }
                Err(e) => self.project_management.session.error = e.to_string(),
            };
            cx.notify();
            return;
        }
        let Some(operation) = mode.operation() else {
            cx.notify();
            return;
        };
        if !self.pending_drafts.is_empty() && matches!(mode, Mode::Relocate | Mode::Remove) {
            self.project_management.session.error =
                "Wait for unsaved drafts to finish saving before changing this project.".into();
            cx.notify();
            return;
        }
        let Some(target) = self.project_management.session.target.clone() else {
            return;
        };
        match call(
            &self.engine,
            "projects.prepare",
            json!({"projectId":target,"action":operation}),
        ) {
            Ok(preview) => {
                if mode == Mode::Rename && !keep_input {
                    self.project_management
                        .name
                        .update(cx, |v, cx| v.set_value(text(&preview, "name"), window, cx));
                    self.project_management
                        .name
                        .read(cx)
                        .focus_handle(cx)
                        .focus(window, cx);
                }
                if mode == Mode::Relocate && !keep_input {
                    self.project_path
                        .update(cx, |v, cx| v.set_value("", window, cx));
                }
                self.project_management.session.preview = Some(preview);
            }
            Err(e) => self.project_management.session.error = e.to_string(),
        }
        cx.notify();
    }
    pub(super) fn choose_project_folder(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.project_ui_admitted() {
            return;
        }
        let Some(stamp) = self.project_management.session.choose() else {
            return;
        };
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: stamp.1 == Mode::Add,
            prompt: Some("Choose project folder".into()),
        });
        cx.spawn_in(window, async move |this, cx| {
            let picked: Result<_> = async { picker.await? }.await;
            let _ = this.update_in(cx, |this, window, cx| {
                if !this.project_ui_admitted()
                    || !this.project_picker_open
                    || !this.project_management.session.chosen(&stamp)
                {
                    return;
                }
                match picked {
                    Ok(Some(paths))
                        if !paths.is_empty() && (stamp.1 == Mode::Add || paths.len() == 1) =>
                    {
                        let path = paths[0].to_str().map(str::to_owned);
                        if let Some(path) = path {
                            this.project_path
                                .update(cx, |v, cx| v.set_value(path, window, cx));
                            if stamp.1 == Mode::Add {
                                this.project_management.folders = paths;
                            }
                        } else {
                            this.project_management.session.error =
                                "The chosen folder path is not UTF-8.".into();
                        }
                    }
                    Ok(_) => {}
                    Err(e) => this.project_management.session.error = e.to_string(),
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    fn commit_project_form(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.project_ui_admitted() || self.project_management.session.choosing {
            return;
        }
        let mode = self.project_management.session.mode;
        if mode == Mode::Add {
            self.add_project(window, cx);
            return;
        }
        if !self.pending_drafts.is_empty() && matches!(mode, Mode::Remove | Mode::Relocate) {
            self.project_management.session.error =
                "Unsaved drafts remain in this window; no project changes were sent.".into();
            cx.notify();
            return;
        }
        let Some(preview) = self.project_management.session.preview.take() else {
            return;
        };
        let Some(target) = self.project_management.session.target.clone() else {
            return;
        };
        let Some(operation) = mode.operation() else {
            return;
        };
        let mut params = json!({"projectId":target,"ticket":preview["ticket"]});
        match mode {
            Mode::Rename => {
                params["name"] = json!(self.project_management.name.read(cx).value().trim())
            }
            Mode::Relocate => params["path"] = json!(self.project_path.read(cx).value().trim()),
            Mode::Remove | Mode::Restore => {
                params["confirmed"] = json!(true);
                params["confirmedThreadCount"] = preview["threadCount"].clone();
            }
            _ => return,
        }
        match call(&self.engine, &format!("projects.{operation}"), params) {
            Ok(outcome) => {
                let refreshed = self.refresh(cx);
                if mode == Mode::Remove {
                    if self.selected_project.as_ref() == Some(&target) {
                        self.selected_project = None;
                    }
                    let removed = outcome["threadIds"].as_array().cloned().unwrap_or_default();
                    self.projects.retain(|p| p["id"] != target);
                    self.threads
                        .retain(|t| !removed.iter().any(|id| id.as_str() == Some(t.id.as_str())));
                    let selection_removed = self
                        .selected
                        .as_ref()
                        .is_some_and(|v| removed.contains(&v["id"]));
                    if selection_removed {
                        if let Some(next) = self.threads.first().map(|v| v.id.clone()) {
                            self.select(&next, window, cx);
                            if self
                                .selected
                                .as_ref()
                                .is_some_and(|v| removed.contains(&v["id"]))
                            {
                                self.clear_removed_project_selection(window, cx);
                            }
                        } else {
                            self.clear_removed_project_selection(window, cx);
                        }
                    }
                    self.status = format!(
                        "Removed {} and {} conversations. Recovery retains their data; working files are unchanged.",
                        text(&preview, "name"),
                        preview["threadCount"]
                    );
                    self.project_management.session.begin(Mode::Recovery, None);
                    self.review_project_form(window, cx);
                } else {
                    self.status = if mode == Mode::Restore {
                        format!("Restored {} and its conversations.", text(&preview, "name"))
                    } else {
                        format!(
                            "Updated project {}. Working files are unchanged.",
                            text(&outcome["project"], "name")
                        )
                    };
                    self.close_project_form(window, cx);
                }
                if !refreshed {
                    self.status.push_str(
                        " The change was saved, but the sidebar could not be fully refreshed.",
                    );
                }
            }
            Err(e) => {
                self.project_management.session.error = format!(
                    "No project change was completed: {e}. Review the current target before trying again."
                )
            }
        }
        cx.notify();
    }
    pub(super) fn project_management_form(&self, cx: &Context<Self>) -> Option<AnyElement> {
        let state = &self.project_management.session;
        if !state.open {
            return None;
        }
        let mode = state.mode;
        let choosing = state.choosing;
        let title = match mode {
            Mode::Manage => "Manage project",
            Mode::Add => "Add existing folder",
            Mode::Rename => "Rename project",
            Mode::Relocate => "Locate project folder",
            Mode::Remove => "Remove from Coincide",
            Mode::Recovery => "Removed project recovery",
            Mode::Restore => "Restore project",
        };
        let target = state.target.clone();
        let project = state
            .preview
            .as_ref()
            .cloned()
            .or_else(|| {
                target
                    .as_ref()
                    .and_then(|id| self.projects.iter().find(|p| p["id"] == *id).cloned())
            })
            .unwrap_or(Value::Null);
        let mut panel = div()
            .id("project-management-form")
            .flex()
            .flex_col()
            .gap_2()
            .max_h(px(360.))
            .overflow_y_scroll()
            .border_1()
            .border_color(self.color(0x29303d))
            .rounded_md()
            .p_2()
            .child(div().text_sm().child(title));
        if !project.is_null() {
            panel = panel
                .child(div().text_sm().child(text(&project, "name")))
                .child(div().text_xs().child(text(&project, "path")));
        }
        if mode == Mode::Manage {
            for (label, next) in [
                ("Rename…", Mode::Rename),
                ("Locate folder…", Mode::Relocate),
                ("Remove from Coincide…", Mode::Remove),
            ] {
                let target = target.clone();
                panel = panel.child(
                    Button::new(SharedString::from(format!("project-manage-{next:?}")))
                        .label(label)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.open_project_form(next, target.clone(), window, cx)
                        })),
                );
            }
        }
        if mode == Mode::Recovery {
            if state.recoveries.is_empty() && state.error.is_empty() {
                panel = panel.child(
                    div()
                        .text_sm()
                        .child("No removed projects are awaiting restore."),
                );
            }
            for entry in &state.recoveries {
                let id = text(entry, "id");
                panel = panel.child(
                    Button::new(SharedString::from(format!("project-restore-{id}")))
                        .label(format!(
                            "Review restore: {} ({} conversations)",
                            text(entry, "name"),
                            entry["threadCount"]
                        ))
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.open_project_form(Mode::Restore, Some(id.clone()), window, cx)
                        })),
                );
            }
        }
        if mode == Mode::Rename {
            panel = panel.child(Input::new(&self.project_management.name));
        }
        if matches!(mode, Mode::Add | Mode::Relocate) {
            panel = panel
                .child(Input::new(&self.project_path).readonly(mode == Mode::Add))
                .child(
                    Button::new("project-choose-folder")
                        .label(if choosing {
                            "Choosing folder…"
                        } else {
                            "Choose folder…"
                        })
                        .disabled(choosing)
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.choose_project_folder(window, cx)
                        })),
                );
            if mode == Mode::Add && self.project_management.folders.len() > 1 {
                panel = panel.child(div().text_xs().child(format!(
                    "{} chosen folders; the first opens after adding.",
                    self.project_management.folders.len()
                )));
            }
            if mode == Mode::Relocate {
                panel=panel.child(div().text_xs().child("Only the saved folder location changes. Working files and conversation data are kept. Close terminal panes and finish active work first."));
            }
        }
        if matches!(mode, Mode::Remove | Mode::Restore) && state.preview.is_some() {
            let count = project["threadCount"].as_u64().unwrap_or(0);
            panel=panel.child(div().text_sm().child(if mode==Mode::Remove {format!("Remove this project and all {count} conversations, including archived ones? Their complete data is kept in recovery. The folder and files are not changed.")}else {format!("Restore this project and all {count} conversations? Existing IDs or folders will not be overwritten.")}));
        }
        if !state.error.is_empty() {
            panel = panel.child(
                div()
                    .text_sm()
                    .text_color(self.color(0xf0a090))
                    .child(state.error.clone()),
            );
        }
        if mode.operation().is_some() && state.preview.is_none() {
            panel = panel.child(
                Button::new("project-review-again")
                    .label("Review current project")
                    .on_click(
                        cx.listener(|this, _, window, cx| this.review_project_form(window, cx)),
                    ),
            );
        }
        if mode == Mode::Add || state.preview.is_some() {
            let label = match mode {
                Mode::Add => "Add selected folder".into(),
                Mode::Rename => "Save project name".into(),
                Mode::Relocate => "Use this folder".into(),
                Mode::Remove => format!(
                    "Remove project and {} conversations",
                    project["threadCount"]
                ),
                Mode::Restore => format!(
                    "Restore project and {} conversations",
                    project["threadCount"]
                ),
                _ => String::new(),
            };
            panel = panel.child(
                Button::new("project-confirm-change")
                    .accessibility_label(format!(
                        "{label}: {} — {}",
                        text(&project, "name"),
                        text(&project, "path")
                    ))
                    .label(label)
                    .disabled(
                        choosing
                            || (mode == Mode::Add && self.project_management.folders.is_empty()),
                    )
                    .on_click(
                        cx.listener(|this, _, window, cx| this.commit_project_form(window, cx)),
                    ),
            );
        }
        panel = panel.child(
            Button::new("project-cancel-change")
                .label("Cancel")
                .on_click(cx.listener(|this, _, window, cx| this.close_project_form(window, cx))),
        );
        Some(panel.into_any_element())
    }
}
