use super::*;

use coincide_core::bot_runtime::BOTS_PROJECT_ID;

#[path = "navigation_sections.rs"]
mod sections;
use gpui_kit::assets::IconName;
use gpui_kit::component::menu::{ContextMenuExt, PopupMenuItem};
use sections::NO_PROJECT;

// Button's root alignment does not reach its independently centered label slot.
// A full-width content child keeps the real Button and aligns/truncates its text.
fn sidebar_button_label(label: String) -> Div {
    div().w_full().min_w_0().truncate().text_left().child(label)
}

#[derive(Clone, Copy)]
enum SidebarThreadAction {
    Pin,
    Rename,
    Fork,
    Archive,
}

impl Coincide {
    fn sidebar_sections(&self, now: f64, searching: bool) -> Vec<sections::Section<'_>> {
        sections::display(
            &self.threads,
            self.projects
                .iter()
                .map(|p| (text(p, "id"), text(p, "name")))
                .collect(),
            self.selected_project.as_deref(),
            self.show_snoozed,
            now,
            searching,
        )
    }
    fn sidebar_projects_heading(&self, cx: &mut Context<Self>) -> AnyElement {
        div()
            .flex()
            .items_center()
            .h(px(36.))
            .px_2()
            .gap_1()
            .child(
                div()
                    .id("sidebar-section-projects")
                    .role(Role::Heading)
                    .text_xs()
                    .text_color(self.color(0xe4e9f2).opacity(0.55))
                    .flex_1()
                    .child("Projects"),
            )
            .child(
                Button::new("sidebar-add-project")
                    .icon(IconName::FolderPlus)
                    .accessibility_label("Add project folders")
                    .tooltip("Add folders…")
                    .ghost()
                    .compact()
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.open_project_form(project_management::Mode::Add, None, window, cx)
                    })),
            )
            .into_any_element()
    }
    pub(super) fn bulk_sidebar_binding(&self, cx: &Context<Self>) -> thread_bulk::Binding {
        let query = self.search.read(cx).value().to_string();
        let searching = !query.trim().is_empty();
        let rows = self
            .sidebar_sections(coincide_core::store::swift_timestamp(), searching)
            .into_iter()
            .filter(|section| {
                searching
                    || section
                        .project_id
                        .as_ref()
                        .is_none_or(|id| !self.collapsed_projects.contains(id))
            })
            .flat_map(|section| {
                section
                    .threads
                    .into_iter()
                    .map(|t| (t.id.clone(), t.pinned, t.archived))
            })
            .collect();
        thread_bulk::Binding {
            rows,
            project: self.selected_project.clone(),
            query,
            archived: self.show_archived,
            snoozed: self.show_snoozed,
            available: self.thread_list_open
                && self.microphone_window_active
                && !self.settings_in_main_window()
                && !self.schedules_open
                && !self.session_import_open
                && !self.workspace_open
                && !self.project_picker_open
                && !self.command_palette.read(cx).is_open()
                && !self.historical_image_is_open()
                && !self.media.close_requested
                && !self.media.shutdown_requested,
        }
    }
    pub(super) fn navigation_sidebar(
        &self,
        selected: &str,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let parent = cx.entity().downgrade();
        let resize = gpui_kit::component::resizable::resize_handle(
            "conversation-list-resize",
            Axis::Horizontal,
        )
        .inside(gpui_kit::component::resizable::HandleEdge::Trailing)
        .role(Role::Splitter)
        .aria_label("Resize conversation list")
        .on_drag(navigation_resize::ResizeList, move |drag, _, window, cx| {
            let pointer = f64::from(f32::from(window.mouse_position().x));
            let width = f64::from(f32::from(window.viewport_size().width));
            let active = window.is_window_active();
            let _ = parent.update(cx, |this, cx| {
                if active
                    && this.thread_list_open
                    && !this.media.close_requested
                    && !this.media.shutdown_requested
                {
                    this.sidebar_resize.begin(pointer, width);
                    cx.notify();
                }
            });
            cx.new(|_| drag.clone())
        });
        let project_label = match self.selected_project.as_deref() {
            None => "All projects".into(),
            Some(NO_PROJECT) => "No project".into(),
            Some(BOTS_PROJECT_ID) => "Bots".into(),
            Some(id) => self
                .projects
                .iter()
                .find(|p| p["id"] == id)
                .map(|p| text(p, "name"))
                .unwrap_or_else(|| "Unavailable project".into()),
        };
        let searching = !self.search.read(cx).value().trim().is_empty();
        let now = coincide_core::store::swift_timestamp();
        let sections = self.sidebar_sections(now, searching);
        let mut projects_heading = false;
        let mut conversations = div().id("threads").flex_1().min_h_0().overflow_y_scroll();
        if sections.is_empty() {
            conversations = conversations.child(
                div()
                    .p_3()
                    .text_sm()
                    .child("No conversations match these filters."),
            );
        }
        for (section_index, section) in sections.into_iter().enumerate() {
            if !projects_heading
                && section
                    .project_id
                    .as_ref()
                    .is_some_and(|id| !id.eq_ignore_ascii_case(BOTS_PROJECT_ID))
            {
                conversations = conversations.child(self.sidebar_projects_heading(cx));
                projects_heading = true;
            }
            let pinned = section.project_id.is_none();
            let name = section.name;
            let group_key = section.project_id.clone();
            let expanded = group_key
                .as_ref()
                .is_some_and(|id| self.expanded_sidebar_lists.contains(id));
            let limit = sections::automatic_limit(
                (f32::from(window.viewport_size().height) - 130.).max(0.),
            );
            let total = section.threads.len();
            let (threads, hidden) = sections::visible_rows(
                &section.threads,
                if pinned { 0 } else { limit },
                selected,
                expanded,
                searching,
            );
            // Keep existing raw project collapse keys and the bot-open reveal
            // contract. Pinned is a section, never a fabricated project key.
            let collapsed = !searching
                && section
                    .project_id
                    .as_ref()
                    .is_some_and(|id| self.collapsed_projects.contains(id));
            let mut group = div().flex().flex_col().mb_2();
            if let Some(group_id) = section.project_id {
                let chats = group_id == NO_PROJECT;
                let target = group_id.clone();
                group = group.child(
                    Button::new(SharedString::from(format!("project-group-{group_id}")))
                        .ghost()
                        .compact()
                        .justify_start()
                        .w_full()
                        .h(px(if chats {
                            if section_index == 0 { 30. } else { 36. }
                        } else {
                            28.
                        }))
                        .accessibility_id(SharedString::from(format!("project-group-{group_id}")))
                        .accessibility_label(SharedString::from(format!(
                            "{} {} {name}, {} conversations",
                            if collapsed { "Expand" } else { "Collapse" },
                            if chats { "section" } else { "project" },
                            threads.len()
                        )))
                        .child(
                            div()
                                .w_full()
                                .min_w_0()
                                .flex()
                                .items_center()
                                .gap_2()
                                .child(if collapsed {
                                    IconName::ChevronRight
                                } else {
                                    IconName::ChevronDown
                                })
                                .when(
                                    !chats && !group_id.eq_ignore_ascii_case(BOTS_PROJECT_ID),
                                    |row| row.child(IconName::Folder),
                                )
                                .child(sidebar_button_label(name)),
                        )
                        .disabled(searching)
                        .when(searching, |button| {
                            button.tooltip("Clear search to collapse project groups")
                        })
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.thread_bulk.invalidate();
                            if !this.collapsed_projects.remove(&target) {
                                this.collapsed_projects.insert(target.clone());
                            }
                            cx.notify();
                        })),
                );
            } else {
                group = group.child(
                    div()
                        .id("sidebar-section-pinned")
                        .role(Role::Heading)
                        .aria_label(SharedString::from(format!(
                            "Pinned section, {} conversations",
                            threads.len()
                        )))
                        .h(px(if section_index == 0 { 30. } else { 36. }))
                        .flex()
                        .items_center()
                        .px_2()
                        .text_xs()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(self.color(0xe4e9f2).opacity(0.65))
                        .child("Pinned"),
                );
            }
            if !collapsed {
                if threads.is_empty() {
                    group = group.child(
                        div()
                            .h(px(24.))
                            .pl(px(36.))
                            .text_xs()
                            .text_color(self.color(0xe4e9f2).opacity(0.55))
                            .child("No threads yet"),
                    );
                }
                for thread in threads {
                    let id = thread.id.clone();
                    let selecting = self.thread_bulk.mode;
                    let menu_id = id.clone();
                    let parent = cx.entity().downgrade();
                    let is_pinned = thread.pinned;
                    let is_archived = thread.archived;
                    let snoozed = thread.snoozed_until.is_some_and(|date| date > now);
                    let label = format!(
                        "{}{}{}{}",
                        if thread.pinned && !pinned { "★ " } else { "" },
                        if thread.archived { "Archived · " } else { "" },
                        if snoozed { "Snoozed · " } else { "" },
                        thread.title
                    );
                    group = group.child(
                        Button::new(SharedString::from(format!("thread-{id}")))
                            .ghost()
                            .compact()
                            .justify_start()
                            .h(px(28.))
                            .min_w_0()
                            .accessibility_id(SharedString::from(format!("thread-{id}")))
                            .accessibility_label(SharedString::from(format!(
                                "{} conversation: {}",
                                if self.thread_bulk.mode {
                                    "Select"
                                } else {
                                    "Open"
                                },
                                thread.title
                            )))
                            .child(sidebar_button_label(if self.thread_bulk.mode {
                                format!(
                                    "{} {label}",
                                    if self.thread_bulk.picked.contains(&id) {
                                        "☑"
                                    } else {
                                        "☐"
                                    }
                                )
                            } else {
                                label
                            }))
                            .tooltip(thread.title.clone())
                            .w_full()
                            .selected(if self.thread_bulk.mode {
                                self.thread_bulk.picked.contains(&id)
                            } else {
                                id == selected
                            })
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.bulk_row_click(&id, selecting, window, cx)
                            }))
                            .context_menu(move |mut menu, _, _| {
                                for (label, action) in [
                                    (
                                        if is_pinned { "Unpin" } else { "Pin" },
                                        SidebarThreadAction::Pin,
                                    ),
                                    ("Rename…", SidebarThreadAction::Rename),
                                    ("Fork", SidebarThreadAction::Fork),
                                    (
                                        if is_archived { "Restore" } else { "Archive…" },
                                        SidebarThreadAction::Archive,
                                    ),
                                ] {
                                    let parent = parent.clone();
                                    let id = menu_id.clone();
                                    menu = menu.item(PopupMenuItem::new(label).on_click(
                                        move |_, window, cx| {
                                            let _ = parent.update(cx, |this, cx| {
                                                if this.thread_bulk.mode
                                                    || this.media.shutdown_requested
                                                    || this.media.close_requested
                                                {
                                                    return;
                                                }
                                                this.select(&id, window, cx);
                                                if this
                                                    .selected
                                                    .as_ref()
                                                    .is_none_or(|thread| thread["id"] != id)
                                                {
                                                    return;
                                                }
                                                match action {
                                                    SidebarThreadAction::Pin => {
                                                        this.toggle("isPinned", cx)
                                                    }
                                                    SidebarThreadAction::Rename => {
                                                        this.begin_rename(window, cx)
                                                    }
                                                    SidebarThreadAction::Fork => {
                                                        this.fork(window, cx)
                                                    }
                                                    SidebarThreadAction::Archive => {
                                                        this.request_archive(cx)
                                                    }
                                                }
                                            });
                                        },
                                    ));
                                }
                                menu
                            }),
                    );
                }
            }
            if !collapsed && !searching && !pinned && (hidden > 0 || (expanded && total > limit)) {
                if let Some(key) = group_key {
                    group = group.child(
                        Button::new(SharedString::from(format!("sidebar-more-{key}")))
                            .ghost()
                            .compact()
                            .w_full()
                            .h(px(24.))
                            .justify_start()
                            .label(if hidden > 0 {
                                format!("Show {hidden} more")
                            } else {
                                "Show less".into()
                            })
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.thread_bulk.invalidate();
                                if !this.expanded_sidebar_lists.remove(&key) {
                                    this.expanded_sidebar_lists.insert(key.clone());
                                }
                                cx.notify();
                            })),
                    );
                }
            }
            conversations = conversations.child(group);
        }
        if !projects_heading && !searching {
            conversations = conversations.child(self.sidebar_projects_heading(cx));
        }
        div()
            .id("conversation-list")
            .relative()
            .track_focus(&self.thread_list_focus)
            .flex()
            .flex_col()
            .w(px(self
                .sidebar_resize
                .visible(f64::from(f32::from(window.viewport_size().width)))
                as f32))
            .flex_shrink_0()
            .h_full()
            .bg(self.color(0x151922))
            .border_r_1()
            .border_color(self.color(0x29303d))
            .p_3()
            .gap_2()
            .on_drag_move(cx.listener(
                |this, event: &DragMoveEvent<navigation_resize::ResizeList>, window, cx| {
                    if this.sidebar_resize.move_to(
                        f64::from(f32::from(event.event.position.x)),
                        f64::from(f32::from(window.viewport_size().width)),
                    ) {
                        cx.notify();
                    }
                },
            ))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, _, _, cx| this.finish_sidebar_resize(cx)),
            )
            .on_mouse_up_out(
                MouseButton::Left,
                cx.listener(|this, _, _, cx| this.finish_sidebar_resize(cx)),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_1()
                    .child(
                        Button::new("sidebar-new-thread")
                            .icon(IconName::SquarePen)
                            .ghost()
                            .compact()
                            .h(px(32.))
                            .flex_1()
                            .justify_start()
                            .accessibility_label("New Thread")
                            .child(sidebar_button_label("New Thread".into()))
                            .on_click(
                                cx.listener(|this, _, window, cx| this.new_thread(window, cx)),
                            ),
                    )
                    .child(
                        Button::new("projects-toggle")
                            .icon(IconName::Ellipsis)
                            .ghost()
                            .compact()
                            .h(px(32.))
                            .accessibility_label(format!("Project: {project_label}"))
                            .tooltip("Conversation filters and project actions")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.thread_bulk.invalidate();
                                this.project_picker_open = !this.project_picker_open;
                                if !this.project_picker_open {
                                    this.close_project_form(window, cx);
                                }
                                cx.notify();
                            })),
                    ),
            )
            .child(
                Input::new(&self.search)
                    .appearance(false)
                    .bordered(false)
                    .prefix(IconName::Search)
                    .h(px(32.)),
            )
            .child(
                Button::new("sidebar-scheduled")
                    .icon(IconName::Clock)
                    .ghost()
                    .compact()
                    .h(px(32.))
                    .w_full()
                    .justify_start()
                    .accessibility_label("Scheduled")
                    .selected(self.schedules_open)
                    .child(sidebar_button_label("Scheduled".into()))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.thread_bulk.invalidate();
                        this.hide_inline_settings();
                        this.workspace_open = false;
                        this.session_import_open = false;
                        this.open_global_schedules(cx);
                        this.sync_transcription_binding(cx);
                        cx.notify();
                    })),
            )
            .when(self.project_picker_open, |view| {
                view.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .child(
                            Button::new("projects-all")
                                .label("All projects")
                                .when(self.selected_project.is_none(), |b| b.primary())
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.thread_bulk.invalidate();
                                    this.selected_project = None;
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new("projects-none")
                                .label("No project")
                                .when(self.selected_project.as_deref() == Some(NO_PROJECT), |b| {
                                    b.primary()
                                })
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.thread_bulk.invalidate();
                                    this.selected_project = Some(NO_PROJECT.into());
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new("projects-bots")
                                .label("Bots")
                                .when(
                                    self.selected_project.as_deref() == Some(BOTS_PROJECT_ID),
                                    |b| b.primary(),
                                )
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.thread_bulk.invalidate();
                                    this.selected_project = Some(BOTS_PROJECT_ID.into());
                                    cx.notify();
                                })),
                        )
                        .child(
                            div()
                                .id("project-picker")
                                .max_h(px(180.))
                                .overflow_y_scroll()
                                .flex()
                                .flex_col()
                                .gap_1()
                                .children(
                                    self.projects
                                        .iter()
                                        .filter(|p| {
                                            p["id"] != NO_PROJECT
                                                && !p["id"].as_str().is_some_and(|id| {
                                                    id.eq_ignore_ascii_case(BOTS_PROJECT_ID)
                                                })
                                        })
                                        .map(|project| {
                                            let id = text(project, "id");
                                            Button::new(SharedString::from(format!("project-{id}")))
                                                .label(text(project, "name"))
                                                .accessibility_label(format!(
                                                    "Project {}: {}",
                                                    text(project, "name"),
                                                    text(project, "path")
                                                ))
                                                .tooltip(text(project, "path"))
                                                .when(
                                                    self.selected_project.as_ref() == Some(&id),
                                                    |b| b.primary(),
                                                )
                                                .on_click(cx.listener(move |this, _, _, cx| {
                                                    this.thread_bulk.invalidate();
                                                    this.selected_project = Some(id.clone());
                                                    cx.notify();
                                                }))
                                        }),
                                ),
                        )
                        .child(Button::new("project-add").label("Add folders…").on_click(
                            cx.listener(|this, _, window, cx| {
                                this.open_project_form(
                                    project_management::Mode::Add,
                                    None,
                                    window,
                                    cx,
                                )
                            }),
                        ))
                        .child(
                            Button::new("project-manage-selected")
                                .label("Manage selected project…")
                                .disabled(self.selected_project.as_ref().is_none_or(|id| {
                                    !self.projects.iter().any(|p| {
                                        p["id"] == *id
                                            && p["isChats"] != true
                                            && p["isBots"] != true
                                            && *id != NO_PROJECT
                                            && !id.eq_ignore_ascii_case(BOTS_PROJECT_ID)
                                    })
                                }))
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.open_project_form(
                                        project_management::Mode::Manage,
                                        this.selected_project.clone(),
                                        window,
                                        cx,
                                    )
                                })),
                        )
                        .child(
                            Button::new("project-recovery")
                                .label("Removed projects…")
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.open_project_form(
                                        project_management::Mode::Recovery,
                                        None,
                                        window,
                                        cx,
                                    )
                                })),
                        )
                        .when(
                            !self.thread_bulk.mode && self.thread_bulk.status.is_empty(),
                            |view| {
                                view.child(
                                    Button::new("sidebar-select-conversations-menu")
                                        .ghost()
                                        .compact()
                                        .label("Select conversations…")
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.project_picker_open = false;
                                            this.sync_thread_bulk(cx);
                                            if this.bulk_sidebar_binding(cx).available {
                                                this.thread_bulk.mode = true;
                                                this.thread_bulk.invalidate();
                                            }
                                            cx.notify();
                                        })),
                                )
                            },
                        )
                        .when_some(self.project_management_form(cx), |view, form| {
                            view.child(form)
                        }),
                )
            })
            .when(
                self.project_picker_open || self.show_archived || self.show_snoozed,
                |view| {
                    view.child(
                        div()
                            .flex()
                            .flex_wrap()
                            .gap_2()
                            .child(
                                Button::new("archived")
                                    .ghost()
                                    .compact()
                                    .label(if self.show_archived {
                                        "Hide archived"
                                    } else {
                                        "Show archived"
                                    })
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.thread_bulk.invalidate();
                                        this.show_archived = !this.show_archived;
                                        this.refresh(cx);
                                    })),
                            )
                            .child(
                                Button::new("snoozed")
                                    .ghost()
                                    .compact()
                                    .label(if self.show_snoozed {
                                        "Hide snoozed"
                                    } else {
                                        "Show snoozed"
                                    })
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.thread_bulk.invalidate();
                                        this.show_snoozed = !this.show_snoozed;
                                        cx.notify();
                                    })),
                            ),
                    )
                },
            )
            .when(
                self.thread_bulk.mode || !self.thread_bulk.status.is_empty(),
                |view| view.child(self.bulk_controls(cx)),
            )
            .child(conversations)
            .when_some(self.sidebar_resize.error(), |view, error| {
                view.child(div().text_xs().child(error))
            })
            .child(resize)
            .into_any_element()
    }

    pub(super) fn begin_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref() else {
            return;
        };
        self.rename_target = Some(text(thread, "id"));
        let title = text(thread, "title");
        self.rename_input
            .update(cx, |input, cx| input.set_value(title, window, cx));
        self.rename_input
            .read(cx)
            .focus_handle(cx)
            .focus(window, cx);
        cx.notify();
    }

    fn patch_navigation(
        &mut self,
        id: &str,
        patch: Value,
        success: &str,
        cx: &mut Context<Self>,
    ) -> bool {
        match call(
            &self.engine,
            "threads.patch",
            json!({"threadId":id,"patch":patch}),
        ) {
            Ok(thread) => {
                if self.selected.as_ref().is_some_and(|v| v["id"] == id) {
                    self.selected = Some(thread);
                }
                self.status = success.into();
                self.refresh(cx);
                true
            }
            Err(error) => {
                self.status = format!("Conversation could not be updated: {error}");
                cx.notify();
                false
            }
        }
    }

    pub(super) fn save_rename(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.rename_target.clone() else {
            return;
        };
        let title = self.rename_input.read(cx).value().trim().to_owned();
        if title.is_empty() || title.len() > 512 || title.chars().any(char::is_control) {
            self.status = "Use a nonempty title up to 512 bytes without control characters.".into();
            cx.notify();
            return;
        }
        if self.patch_navigation(&id, json!({"title":title}), "Conversation renamed.", cx) {
            self.rename_target = None;
        }
    }

    pub(super) fn request_archive(&mut self, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref() else {
            return;
        };
        let id = text(thread, "id");
        if thread["isArchived"] == true {
            self.patch_navigation(
                &id,
                json!({"isArchived":false}),
                "Conversation restored.",
                cx,
            );
        } else if self.settings["confirmBeforeArchivingThreads"]
            .as_bool()
            .unwrap_or(true)
        {
            self.archive_confirmation = Some(id);
            cx.notify();
        } else {
            self.patch_navigation(
                &id,
                json!({"isArchived":true}),
                "Conversation archived.",
                cx,
            );
        }
    }

    fn snooze_selected(&mut self, seconds: Option<f64>, cx: &mut Context<Self>) {
        let Some(id) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        let date = seconds.map(|seconds| coincide_core::store::swift_timestamp() + seconds);
        self.patch_navigation(
            &id,
            json!({"snoozedUntil":date}),
            if date.is_some() {
                "Conversation snoozed in the sidebar."
            } else {
                "Conversation unsnoozed."
            },
            cx,
        );
    }

    pub(super) fn thread_management(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let thread = self.selected.as_ref()?;
        if !self.thread_actions_open
            && self.rename_target.is_none()
            && self.archive_confirmation.is_none()
        {
            return None;
        }
        let mut pane = div()
            .flex()
            .flex_col()
            .gap_2()
            .px_4()
            .py_2()
            .border_b_1()
            .border_color(self.color(0x29303d));
        if self.rename_target.is_some() {
            pane = pane.child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .child(Input::new(&self.rename_input)),
                    )
                    .child(
                        Button::new("rename-save")
                            .label("Save title")
                            .on_click(cx.listener(|this, _, _, cx| this.save_rename(cx))),
                    )
                    .child(
                        Button::new("rename-cancel")
                            .label("Cancel rename")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.rename_target = None;
                                cx.notify();
                            })),
                    ),
            );
        }
        if let Some(id) = self.archive_confirmation.clone() {
            pane = pane.child(
                div()
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .gap_2()
                    .child(div().child("Archive this conversation?"))
                    .child(
                        Button::new(SharedString::from(format!("archive-confirm-{id}")))
                            .accessibility_id(SharedString::from(format!("archive-confirm-{id}")))
                            .label("Confirm archive")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if this.archive_confirmation.as_deref() != Some(id.as_str())
                                    || this
                                        .selected
                                        .as_ref()
                                        .is_none_or(|thread| thread["id"] != id)
                                {
                                    return;
                                }
                                if this.patch_navigation(
                                    &id,
                                    json!({"isArchived":true}),
                                    "Conversation archived.",
                                    cx,
                                ) {
                                    this.archive_confirmation = None;
                                }
                            })),
                    )
                    .child(
                        Button::new("archive-cancel")
                            .label("Cancel")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.archive_confirmation = None;
                                cx.notify();
                            })),
                    ),
            );
        }
        let snoozed = coincide_core::scheduling::parse_date(&thread["snoozedUntil"])
            .ok()
            .is_some_and(|date| {
                date.timestamp() as f64 > coincide_core::store::swift_timestamp() + 978307200.
            });
        if self.thread_actions_open {
            pane = pane.child(
                div()
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .gap_2()
                    .child(Button::new("snooze-hour").label("Snooze 1 hour").on_click(
                        cx.listener(|this, _, _, cx| this.snooze_selected(Some(3600.), cx)),
                    ))
                    .child(Button::new("snooze-day").label("Snooze 1 day").on_click(
                        cx.listener(|this, _, _, cx| this.snooze_selected(Some(86400.), cx)),
                    ))
                    .when(snoozed, |row| {
                        row.child(
                            Button::new("snooze-clear").label("Unsnooze").on_click(
                                cx.listener(|this, _, _, cx| this.snooze_selected(None, cx)),
                            ),
                        )
                        .child(
                            div()
                                .text_sm()
                                .child(format!("Until {}", schedule_date(&thread["snoozedUntil"]))),
                        )
                    }),
            );
        }
        Some(pane.into_any_element())
    }
}
