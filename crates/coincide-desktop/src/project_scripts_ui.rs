//! Swift ProjectScriptsControl and ProjectScriptEditor: the conversation
//! toolbar's project scripts (the one run last as a button beside a menu of
//! every script) and the sheet that adds or edits one. Every edit is checked
//! against the project the menu showed; runs go to the thread's terminal.
use super::*;
use coincide_core::{
    project_scripts::{self, ProjectScript, ScriptDraft, ScriptIcon},
    store::ScriptEdit,
};
use gpui_kit::{
    assets::IconName,
    component::{
        checkbox::Checkbox,
        menu::{DropdownMenu, PopupMenuItem},
    },
};
use std::collections::HashMap;
use uuid::Uuid;

/// Swift `ProjectScript.Icon.symbolName`, in Lucide.
pub(super) fn icon_name(icon: ScriptIcon) -> IconName {
    match icon {
        ScriptIcon::Play => IconName::Play,
        ScriptIcon::Test => IconName::BadgeCheck,
        ScriptIcon::Lint => IconName::WandSparkles,
        ScriptIcon::Configure => IconName::Settings,
        ScriptIcon::Build => IconName::Hammer,
        ScriptIcon::Debug => IconName::Bug,
    }
}

fn project_uuid(project: &Value) -> Option<Uuid> {
    project["id"]
        .as_str()
        .and_then(|id| Uuid::parse_str(id).ok())
}

/// The project whose scripts the toolbar shows: the open conversation's own,
/// when it is a saved project (Swift `ProjectScripts.project(ofThread:)`).
fn thread_project<'a>(selected: Option<&Value>, projects: &'a [Value]) -> Option<&'a Value> {
    let id = selected?["projectID"]
        .as_str()
        .and_then(|id| Uuid::parse_str(id).ok())?;
    projects
        .iter()
        .find(|project| project_uuid(project) == Some(id))
        .filter(|project| project["isBots"] != true)
}

/// Swift `ProjectScriptEditor.updateSaveButton`.
fn can_save(name: &str, command: &str) -> bool {
    !name.trim().is_empty() && !command.trim().is_empty()
}

struct Editor {
    /// The project as the menu showed it; saving fails if it changed since.
    project: Value,
    /// None adds a script.
    script: Option<Uuid>,
    icon: ScriptIcon,
    run_on_worktree_create: bool,
    error: String,
}

pub(super) struct State {
    /// Swift UIState `lastScripts`, as last read from window state.
    last: HashMap<Uuid, Uuid>,
    editor: Option<Editor>,
    name: Entity<InputState>,
    command: Entity<InputState>,
    focus: FocusHandle,
    restore_focus: Option<FocusHandle>,
}
impl State {
    pub(super) fn new(window: &mut Window, cx: &mut App) -> Self {
        Self {
            last: HashMap::new(),
            editor: None,
            name: cx.new(|cx| InputState::new(window, cx).placeholder("Dev server")),
            command: cx.new(|cx| InputState::new(window, cx).placeholder("npm run dev")),
            focus: cx.focus_handle(),
            restore_focus: None,
        }
    }
    /// Save turns on as soon as both fields have text.
    pub(super) fn subscriptions(&self, cx: &mut Context<Coincide>) -> Vec<Subscription> {
        [&self.name, &self.command]
            .into_iter()
            .map(|input| {
                cx.subscribe(input, |this, _, event, cx| {
                    if matches!(event, InputEvent::Change) && this.project_scripts.editor.is_some()
                    {
                        cx.notify();
                    }
                })
            })
            .collect()
    }
    /// Reads the window state's last-run scripts after the engine changed.
    pub(super) fn remember(&mut self, ui_state: Option<&Value>) {
        self.last = ui_state
            .map(project_scripts::last_scripts)
            .unwrap_or_default();
    }
}

impl Coincide {
    fn edit_project_scripts(&mut self, expected: &Value, edit: &ScriptEdit) -> Result<Value> {
        let project = try_state(&self.engine)?.native_edit_project_scripts(expected, edit)?;
        if let Some(old) = self
            .projects
            .iter_mut()
            .find(|old| old["id"] == project["id"])
        {
            *old = project.clone();
        }
        Ok(project)
    }

    /// Swift `ProjectScripts.run`: remembers the script as the project's
    /// one-click script and types it into a new terminal tab of the open
    /// thread, opening the terminal when it is closed.
    fn run_project_script(
        &mut self,
        project: Uuid,
        script: Uuid,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.project_ui_admitted() {
            return;
        }
        let Some(thread) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return;
        };
        let id = script.hyphenated().to_string().to_uppercase();
        if self.terminal_open && self.terminal_visible_thread.as_deref() == Some(thread.as_str()) {
            if let Some(workspace) = self.terminal_workspaces.get(&thread).cloned() {
                workspace.update(cx, |workspace, cx| workspace.run_script(id, window, cx));
            }
        } else {
            self.terminal_open = false;
            self.toggle_terminal(Some(id), window, cx);
        }
        if self.terminal_visible_thread.as_deref() == Some(thread.as_str()) {
            self.project_scripts.last.insert(project, script);
        } else {
            self.status =
                "The script did not start because the terminal could not open here.".into();
        }
        cx.notify();
    }

    fn open_project_script_editor(
        &mut self,
        project: Value,
        script: Option<ProjectScript>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.project_ui_admitted() || self.project_scripts.editor.is_some() {
            return;
        }
        let draft = script
            .as_ref()
            .map(ProjectScript::draft)
            .unwrap_or_default();
        let state = &mut self.project_scripts;
        state.name.update(cx, |input, cx| {
            input.set_value(draft.name.clone(), window, cx)
        });
        state.command.update(cx, |input, cx| {
            input.set_value(draft.command.clone(), window, cx)
        });
        state.restore_focus = window.focused(cx);
        // Swift focuses the name of a new script and the command of one being edited.
        let field = if script.is_some() {
            &state.command
        } else {
            &state.name
        };
        field.read(cx).focus_handle(cx).focus(window, cx);
        state.editor = Some(Editor {
            project,
            script: script.as_ref().map(ProjectScript::uuid),
            icon: draft.icon,
            run_on_worktree_create: draft.run_on_worktree_create,
            error: String::new(),
        });
        cx.notify();
    }

    fn close_project_script_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let state = &mut self.project_scripts;
        if state.editor.take().is_none() {
            return;
        }
        if let Some(focus) = state.restore_focus.take() {
            focus.focus(window, cx);
        }
        cx.notify();
    }

    fn save_project_script_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let state = &self.project_scripts;
        let Some(editor) = &state.editor else {
            return;
        };
        let name = state.name.read(cx).value().to_string();
        let command = state.command.read(cx).value().to_string();
        if !self.project_ui_admitted() || !can_save(&name, &command) {
            return;
        }
        let expected = editor.project.clone();
        let edit = ScriptEdit::Save {
            id: editor.script,
            draft: ScriptDraft {
                name,
                command,
                icon: editor.icon,
                run_on_worktree_create: editor.run_on_worktree_create,
            },
        };
        self.finish_project_script_edit(&expected, &edit, window, cx);
    }

    fn delete_project_script_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(editor) = &self.project_scripts.editor else {
            return;
        };
        let Some(script) = editor.script else {
            return;
        };
        if !self.project_ui_admitted() {
            return;
        }
        let expected = editor.project.clone();
        self.finish_project_script_edit(&expected, &ScriptEdit::Delete(script), window, cx);
    }

    fn finish_project_script_edit(
        &mut self,
        expected: &Value,
        edit: &ScriptEdit,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match self.edit_project_scripts(expected, edit) {
            Ok(_) => self.close_project_script_editor(window, cx),
            Err(error) => {
                if let Some(editor) = &mut self.project_scripts.editor {
                    editor.error = error.to_string();
                }
                cx.notify();
            }
        }
    }

    fn import_t3_project_scripts(&mut self, project: Value, cx: &mut Context<Self>) {
        if !self.project_ui_admitted() {
            return;
        }
        if let Err(error) = self.edit_project_scripts(&project, &ScriptEdit::ImportT3) {
            self.status = format!("Scripts were not imported: {error}");
        }
        cx.notify();
    }

    /// Return saves and Escape cancels while the editor is open; other app
    /// shortcuts wait until it closes.
    pub(super) fn project_script_editor_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.project_scripts.editor.is_none() {
            return false;
        }
        let key = &event.keystroke;
        let plain = !key.modifiers.platform
            && !key.modifiers.control
            && !key.modifiers.alt
            && !key.modifiers.shift;
        let state = &self.project_scripts;
        let focused = state.focus.contains_focused(window, cx)
            || state.name.read(cx).focus_handle(cx).is_focused(window)
            || state.command.read(cx).focus_handle(cx).is_focused(window);
        if plain && !event.is_held && focused {
            match key.key.as_str() {
                "escape" => {
                    self.close_project_script_editor(window, cx);
                    cx.stop_propagation();
                }
                "enter" => {
                    self.save_project_script_editor(window, cx);
                    cx.stop_propagation();
                }
                _ => {}
            }
        }
        true
    }

    /// The toolbar's scripts: the one run last as a one-click button, then a
    /// menu of every script and ways to add, edit or import them. Without
    /// scripts it is a single button offering to add one.
    pub(super) fn project_scripts_control(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let project = thread_project(self.selected.as_ref(), &self.projects)?.clone();
        let project_id = project_uuid(&project)?;
        let scripts = project_scripts::scripts(&project);
        let primary = project_scripts::primary(
            &scripts,
            self.project_scripts.last.get(&project_id).copied(),
        )
        .cloned();
        let parent = cx.entity().downgrade();
        let muted = self.color(0xe4e9f2).opacity(0.65);
        let menu_project = project.clone();
        let menu_scripts = scripts.clone();
        let menu = Button::new("project-scripts-menu")
            .accessibility_label("Project scripts")
            .tooltip(if primary.is_some() {
                "Project scripts"
            } else {
                "Add a project script, such as your dev server or tests"
            })
            .ghost()
            .compact()
            .h(px(26.))
            .rounded(px(7.))
            .when(primary.is_some(), |button| {
                button.icon(IconName::ChevronDown)
            })
            .when(primary.is_none(), |button| {
                button.icon(IconName::SquarePlay).dropdown_caret(true)
            })
            .dropdown_menu(move |mut menu, window, cx| {
                for script in &menu_scripts {
                    let parent = parent.clone();
                    let id = script.uuid();
                    let title = format!("Run {}", script.name);
                    let command = script.command.clone();
                    menu = menu.item(
                        PopupMenuItem::element(move |_, _| {
                            div()
                                .flex()
                                .flex_col()
                                .min_w_0()
                                .max_w(px(360.))
                                .child(div().truncate().child(title.clone()))
                                .child(
                                    div()
                                        .truncate()
                                        .text_xs()
                                        .text_color(muted)
                                        .child(command.clone()),
                                )
                        })
                        .icon(icon_name(script.icon))
                        .on_click(move |_, window, cx| {
                            let _ = parent.update(cx, |this, cx| {
                                this.run_project_script(project_id, id, window, cx)
                            });
                        }),
                    );
                }
                if !menu_scripts.is_empty() {
                    menu = menu.item(PopupMenuItem::separator());
                }
                let add_parent = parent.clone();
                let add_project = menu_project.clone();
                menu = menu.item(PopupMenuItem::new("Add Script…").on_click(
                    move |_, window, cx| {
                        let _ = add_parent.update(cx, |this, cx| {
                            this.open_project_script_editor(add_project.clone(), None, window, cx)
                        });
                    },
                ));
                if !menu_scripts.is_empty() {
                    let parent = parent.clone();
                    let project = menu_project.clone();
                    let scripts = menu_scripts.clone();
                    menu = menu.submenu("Edit Script", window, cx, move |mut submenu, _, _| {
                        for script in &scripts {
                            let parent = parent.clone();
                            let project = project.clone();
                            let script = script.clone();
                            submenu =
                                submenu.item(PopupMenuItem::new(script.name.clone()).on_click(
                                    move |_, window, cx| {
                                        let _ = parent.update(cx, |this, cx| {
                                            this.open_project_script_editor(
                                                project.clone(),
                                                Some(script.clone()),
                                                window,
                                                cx,
                                            )
                                        });
                                    },
                                ));
                        }
                        submenu
                    });
                }
                // Read when the menu opens, like Swift's menu provider.
                let importable = project_scripts::importable_t3_scripts(&menu_project).len();
                if importable > 0 {
                    let parent = parent.clone();
                    let project = menu_project.clone();
                    menu = menu.item(
                        PopupMenuItem::new(format!("Import {importable} Scripts from t3.json"))
                            .on_click(move |_, _, cx| {
                                let _ = parent.update(cx, |this, cx| {
                                    this.import_t3_project_scripts(project.clone(), cx)
                                });
                            }),
                    );
                }
                menu
            });
        let run = primary.map(|primary| {
            let id = primary.uuid();
            Button::new("project-script-run")
                .icon(icon_name(primary.icon))
                .child(div().min_w_0().truncate().child(primary.name.clone()))
                .accessibility_label(format!("Run {}", primary.name))
                .tooltip(format!("Run {}: {}", primary.name, primary.command))
                .ghost()
                .compact()
                .h(px(26.))
                .min_w(px(44.))
                .max_w(px(220.))
                .rounded(px(7.))
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.run_project_script(project_id, id, window, cx)
                }))
        });
        Some(
            div()
                .id("project-scripts")
                .role(Role::Group)
                .aria_label("Project scripts")
                .flex()
                .flex_shrink_0()
                .items_center()
                .h(px(28.))
                .p(px(1.))
                .rounded(px(8.))
                .border_1()
                .border_color(self.color(0x29303d))
                .bg(self.color(0x202a3b))
                .when_some(run, |control, run| control.child(run))
                .child(menu)
                .into_any_element(),
        )
    }

    /// Swift ProjectScriptEditor's sheet.
    pub(super) fn project_script_editor(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let state = &self.project_scripts;
        let editor = state.editor.as_ref()?;
        let muted = self.color(0xe4e9f2).opacity(0.65);
        let label = |text: &'static str| {
            div()
                .text_size(px(12.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(muted)
                .child(text)
        };
        let saveable = can_save(
            &state.name.read(cx).value(),
            &state.command.read(cx).value(),
        );
        let icons = ScriptIcon::ALL.into_iter().map(|icon| {
            let selected = icon == editor.icon;
            Button::new(SharedString::from(format!(
                "project-script-icon-{}",
                icon.raw()
            )))
            .icon(icon_name(icon))
            .tooltip(icon.title())
            .accessibility_label(icon.title())
            .toggled(selected)
            .when(selected, |button| button.primary())
            .w(px(34.))
            .on_click(cx.listener(move |this, _, _, cx| {
                if let Some(editor) = &mut this.project_scripts.editor {
                    editor.icon = icon;
                    cx.notify();
                }
            }))
        });
        let form = div()
            .id("project-script-editor")
            .role(Role::Dialog)
            .aria_label(if editor.script.is_some() {
                "Edit Script"
            } else {
                "Add Script"
            })
            .track_focus(&state.focus)
            .w(px(440.))
            .max_w_full()
            .max_h_full()
            .overflow_y_scroll()
            .p_5()
            .flex()
            .flex_col()
            .rounded_lg()
            .border_1()
            .border_color(self.color(0x29303d))
            .bg(self.color(0x10141c))
            .text_color(self.color(0xe4e9f2))
            .child(
                div()
                    .text_size(px(15.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(if editor.script.is_some() {
                        "Edit Script"
                    } else {
                        "Add Script"
                    }),
            )
            .child(
                div()
                    .mt_1()
                    .text_size(px(12.))
                    .text_color(muted)
                    .child(
                        "Runs in a terminal of the thread, in its worktree or the project folder. \
                         $COINCIDE_PROJECT_ROOT is the project folder and $COINCIDE_WORKTREE_PATH the worktree.",
                    ),
            )
            .child(div().mt_4().child(label("Name")))
            .child(div().mt(px(6.)).child(Input::new(&state.name)))
            .child(div().mt_3().child(label("Command")))
            .child(
                div().mt(px(6.)).child(Input::new(&state.command).font_family(
                    if cfg!(target_os = "macos") {
                        "Menlo"
                    } else {
                        "monospace"
                    },
                )),
            )
            .child(div().mt_3().child(label("Icon")))
            .child(
                div()
                    .id("project-script-icons")
                    .role(Role::Group)
                    .aria_label("Icon")
                    .mt(px(6.))
                    .flex()
                    .gap(px(6.))
                    .children(icons),
            )
            .child(
                div().mt(px(14.)).child(
                    Checkbox::new("project-script-worktree")
                        .label("Run when a thread gets a new worktree")
                        .checked(editor.run_on_worktree_create)
                        .on_click(cx.listener(|this, checked: &bool, _, cx| {
                            if let Some(editor) = &mut this.project_scripts.editor {
                                editor.run_on_worktree_create = *checked;
                                cx.notify();
                            }
                        })),
                ),
            )
            .when(!editor.error.is_empty(), |form| {
                form.child(
                    div()
                        .mt_3()
                        .text_sm()
                        .text_color(self.color(0xf0a090))
                        .child(editor.error.clone()),
                )
            })
            .child(
                div()
                    .mt_5()
                    .flex()
                    .items_center()
                    .gap_2()
                    .when(editor.script.is_some(), |row| {
                        row.child(
                            Button::new("project-script-delete")
                                .label("Delete")
                                .ghost()
                                .text_color(self.color(0xf0a090))
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.delete_project_script_editor(window, cx)
                                })),
                        )
                    })
                    .child(div().flex_1())
                    .child(Button::new("project-script-cancel").label("Cancel").on_click(
                        cx.listener(|this, _, window, cx| {
                            this.close_project_script_editor(window, cx)
                        }),
                    ))
                    .child(
                        Button::new("project-script-save")
                            .label("Save")
                            .primary()
                            .disabled(!saveable)
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.save_project_script_editor(window, cx)
                            })),
                    ),
            );
        Some(
            div()
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .p_3()
                .bg(rgba(0x00000080))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|_, _, _, cx| cx.stop_propagation()),
                )
                .child(form)
                .into_any_element(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const PROJECT: &str = "0A5C0A5C-AAAA-4AAA-8AAA-00000000000A";

    #[::core::prelude::v1::test]
    fn toolbar_shows_the_conversations_own_saved_project_only() {
        let projects = vec![
            json!({"id":"0A5C0A5C-BBBB-4BBB-8BBB-00000000000B","name":"Other"}),
            json!({"id":PROJECT,"name":"Own"}),
        ];
        let selected = json!({"projectID":PROJECT.to_lowercase()});
        assert_eq!(
            thread_project(Some(&selected), &projects).unwrap()["name"],
            "Own"
        );
        assert!(thread_project(None, &projects).is_none());
        assert!(thread_project(Some(&json!({"projectID":"unknown"})), &projects).is_none());
        assert!(thread_project(Some(&json!({})), &projects).is_none());
        let bots = vec![json!({"id":PROJECT,"isBots":true})];
        assert!(thread_project(Some(&selected), &bots).is_none());
        // Swift lists scripts for Chats too, since it is one of the projects.
        let chats = vec![json!({"id":PROJECT,"isChats":true})];
        assert!(thread_project(Some(&selected), &chats).is_some());
    }

    #[::core::prelude::v1::test]
    fn save_needs_both_fields_like_swift_editor() {
        assert!(can_save("Dev", "npm run dev"));
        assert!(!can_save("  ", "npm run dev"));
        assert!(!can_save("Dev", "\n"));
        assert!(!can_save("", ""));
    }

    #[::core::prelude::v1::test]
    fn every_script_icon_has_a_distinct_lucide_icon() {
        let icons: std::collections::HashSet<_> =
            ScriptIcon::ALL.into_iter().map(icon_name).collect();
        assert_eq!(icons.len(), ScriptIcon::ALL.len());
    }
}
