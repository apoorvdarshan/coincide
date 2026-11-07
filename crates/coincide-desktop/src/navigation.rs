use super::*;
use gpui_kit::component::tooltip::Tooltip;

use coincide_core::bot_runtime::BOTS_PROJECT_ID;

#[path = "navigation_sections.rs"]
mod sections;
use gpui_kit::assets::IconName;
use gpui_kit::component::menu::ContextMenuExt;
use sections::NO_PROJECT;
pub(super) const NO_PROJECT_ID: &str = NO_PROJECT;

// Button's root alignment does not reach its independently centered label slot.
// A full-width content child keeps the real Button and aligns/truncates its text.
fn sidebar_button_label(label: String) -> Div {
    div().w_full().min_w_0().truncate().text_left().child(label)
}

#[derive(Clone)]
struct ProjectDrag(String);
impl Render for ProjectDrag {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().child("Move project")
    }
}

fn adjacent_sidebar_row<'a>(
    rows: &[&'a str],
    selected: Option<&str>,
    step: i32,
) -> Option<&'a str> {
    if rows.is_empty() {
        return None;
    }
    let current = selected.and_then(|id| rows.iter().position(|row| *row == id));
    let index = match current {
        Some(index) => (index as i32 + step).clamp(0, rows.len() as i32 - 1) as usize,
        None => {
            if step < 0 {
                rows.len() - 1
            } else {
                0
            }
        }
    };
    rows.get(index).copied()
}
pub(super) fn sidebar_age(date: Option<f64>, now: f64) -> String {
    let Some(date) = date else {
        return String::new();
    };
    let age = (now - date).max(0.) as u64;
    match age {
        0..=59 => "now".into(),
        60..=3599 => format!("{}m", age / 60),
        3600..=86399 => format!("{}h", age / 3600),
        86400..=604799 => format!("{}d", age / 86400),
        604800..=2629799 => format!("{}w", age / 604800),
        2629800..=31557599 => format!("{}mo", age / 2629800),
        _ => format!("{}y", age / 31557600),
    }
}
pub(super) fn automatic_sidebar_limit(height: f32) -> usize {
    sections::automatic_limit(height)
}

fn section_key(section: &sections::Section<'_>) -> &'static str {
    match section.project_id.as_deref() {
        None => "pinned",
        Some(NO_PROJECT) => "chats",
        Some(id) if id.eq_ignore_ascii_case(BOTS_PROJECT_ID) => "bots",
        _ => "projects",
    }
}

impl Coincide {
    fn sidebar_sections(
        &self,
        now: f64,
        searching: bool,
        query: &str,
    ) -> Vec<sections::Section<'_>> {
        let mut projects: Vec<_> = self
            .projects
            .iter()
            .map(|p| (text(p, "id"), text(p, "name")))
            .collect();
        match self.sidebar_preferences.sort("projectSort") {
            "name" => projects
                .sort_by(|(_, left), (_, right)| sidebar_preferences::name_order(left, right)),
            "recentActivity" => projects.sort_by(|left, right| {
                let stamp = |id: &str| {
                    self.sidebar_all_threads
                        .iter()
                        .filter(|thread| thread.project_id == id)
                        .filter_map(|thread| thread.navigation.as_ref()?.updated_at)
                        .max_by(f64::total_cmp)
                        .unwrap_or(0.)
                };
                stamp(&right.0).total_cmp(&stamp(&left.0))
            }),
            _ => {}
        }
        let mut result = sections::display(
            &self.threads,
            projects,
            self.selected_project.as_deref(),
            true, // Running/approval rows stay visible even while snoozed.
            now,
            false, // Keep matching empty projects, then apply the search below.
        );
        if searching {
            result.retain(|section| {
                !section.threads.is_empty()
                    || (section_key(section) == "projects"
                        && sidebar_search::terms_match(&section.name, query))
            });
        }
        for section in &mut result {
            let key = if section.project_id.as_deref() == Some(NO_PROJECT) {
                "chatSort"
            } else {
                "threadSort"
            };
            if section.project_id.is_none() {
                let saved = self.sidebar_preferences.strings("pinnedThreads");
                section.threads.sort_by_key(|thread| {
                    saved
                        .iter()
                        .position(|id| id.eq_ignore_ascii_case(&thread.id))
                        .map(|index| index + 1)
                        .unwrap_or(0)
                });
            } else {
                section.threads.sort_by(|left, right| {
                    let date = |thread: &ThreadSummary, created: bool| {
                        thread
                            .navigation
                            .as_ref()
                            .and_then(|meta| {
                                if created {
                                    meta.created_at
                                } else {
                                    meta.updated_at
                                }
                            })
                            .unwrap_or(0.)
                    };
                    let order = match self.sidebar_preferences.sort(key) {
                        "name" => sidebar_preferences::name_order(&left.title, &right.title),
                        "created" => date(right, true).total_cmp(&date(left, true)),
                        _ => std::cmp::Ordering::Equal,
                    };
                    order
                        .then_with(|| date(right, false).total_cmp(&date(left, false)))
                        .then_with(|| left.id.cmp(&right.id))
                });
            }
            section.threads.retain(|thread| {
                let bot = thread
                    .navigation
                    .as_ref()
                    .and_then(|meta| meta.bot_id.as_deref());
                let represented = bot.is_some_and(|id| {
                    self.sidebar_bots.iter().any(|bot| {
                        bot["id"]
                            .as_str()
                            .is_some_and(|known| known.eq_ignore_ascii_case(id))
                    })
                });
                let settled = self.sidebar_preferences.document["settledThreads"][&thread.id]
                    .as_f64()
                    .is_some_and(|date| {
                        date >= thread
                            .navigation
                            .as_ref()
                            .and_then(|meta| meta.updated_at)
                            .unwrap_or(f64::MAX)
                    });
                let snoozed = thread.snoozed_until.is_some_and(|until| until > now);
                !represented
                    && (!snoozed
                        || self.show_snoozed
                        || searching
                        || self.running.contains(&thread.id))
                    && (!settled
                        || searching
                        || self.sidebar_preferences.flag("showsSettledThreads")
                        || self.running.contains(&thread.id))
            });
        }
        result
    }

    fn sidebar_thread_content(&self, thread: &ThreadSummary, label: String, now: f64) -> Div {
        let schedules = self
            .sidebar_schedules
            .iter()
            .filter(|task| {
                task["threadID"] == thread.id
                    && task["isPaused"] != true
                    && task["awaitingApproval"] != true
            })
            .map(|task| text(task, "name"))
            .collect::<Vec<_>>();
        let running = self.running.contains(&thread.id);
        div()
            .flex()
            .items_center()
            .gap_1()
            .w_full()
            .min_w_0()
            .child(sidebar_button_label(label).flex_1())
            .when(!schedules.is_empty(), |row| {
                row.child(
                    div()
                        .id(SharedString::from(format!("sidebar-clock-{}", thread.id)))
                        .child(IconName::Clock)
                        .tooltip(move |window, cx| {
                            Tooltip::new(schedules.join("\n")).build(window, cx)
                        }),
                )
            })
            .when(running, |row| {
                row.child(gpui_kit::component::spinner::Spinner::new().small())
            })
            .when(!running, |row| {
                row.child(
                    div()
                        .text_size(px(11.))
                        .text_color(self.color(0xe4e9f2).opacity(0.55))
                        .child(sidebar_age(
                            thread.navigation.as_ref().and_then(|meta| meta.updated_at),
                            now,
                        )),
                )
            })
    }
    fn sidebar_projects_heading(&self, cx: &mut Context<Self>) -> AnyElement {
        self.sidebar_section_header(
            "projects",
            "Projects",
            !self.search.read(cx).value().trim().is_empty(),
            cx,
        )
    }
    pub(super) fn bulk_sidebar_binding(&self, cx: &Context<Self>) -> thread_bulk::Binding {
        let query = self.search.read(cx).value().to_string();
        let searching = !query.trim().is_empty();
        let rows = self
            .sidebar_sections(coincide_core::store::swift_timestamp(), searching, &query)
            .into_iter()
            .filter(|section| {
                searching
                    || (!self.sidebar_preferences.collapsed(section_key(section))
                        && section
                            .project_id
                            .as_ref()
                            .is_none_or(|id| !self.collapsed_projects.contains(id)))
            })
            .flat_map(|section| {
                let expanded = section
                    .project_id
                    .as_ref()
                    .is_some_and(|id| self.expanded_sidebar_lists.contains(id));
                let limit = if section.project_id.is_none() {
                    0
                } else {
                    self.sidebar_preferences.limit(self.sidebar_list_height)
                };
                let selected = self
                    .selected
                    .as_ref()
                    .and_then(|thread| thread["id"].as_str())
                    .unwrap_or("");
                sections::visible_rows(&section.threads, limit, selected, expanded, searching)
                    .0
                    .into_iter()
                    .map(|thread| (thread.id.clone(), thread.pinned, thread.archived))
                    .collect::<Vec<_>>()
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
                && self.chat_route_available()
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
        let query = self.search.read(cx).value().to_string();
        let searching = !query.trim().is_empty();
        let now = coincide_core::store::swift_timestamp();
        let sections = self.sidebar_sections(now, searching, &query);
        let menu_context = self.sidebar_menu_context(cx);
        let mut section_index = 0usize;
        let mut conversations = div()
            .id("threads")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            // Folders dropped from the file manager become projects.
            .on_drop(cx.listener(|this, paths: &ExternalPaths, window, cx| {
                this.sidebar_drop_folders(paths, window, cx)
            }));
        if !sections
            .iter()
            .any(|section| !section.threads.is_empty() || section_key(section) == "projects")
            && !self.has_sidebar_bot_rows(searching, cx)
            && (searching || sections.is_empty())
        {
            conversations = conversations.child(
                div()
                    .p_3()
                    .text_sm()
                    .child("No conversations match these filters."),
            );
        }
        for section_kind in self.sidebar_preferences.order() {
            if section_kind == "projects" {
                if !searching
                    || sections
                        .iter()
                        .any(|section| section_key(section) == "projects")
                {
                    conversations = conversations.child(self.sidebar_projects_heading(cx));
                }
                if !searching && self.sidebar_preferences.collapsed("projects") {
                    continue;
                }
            }
            if section_kind == "bots"
                && self.has_sidebar_bot_rows(searching, cx)
                && self
                    .selected_project
                    .as_deref()
                    .is_none_or(|id| id.eq_ignore_ascii_case(BOTS_PROJECT_ID))
            {
                conversations =
                    conversations.child(self.sidebar_section_header("bots", "Bots", searching, cx));
                if searching || !self.sidebar_preferences.collapsed("bots") {
                    conversations = conversations.child(self.sidebar_bot_rows(searching, cx));
                }
            }
            for section in sections
                .iter()
                .filter(|section| section_key(section) == section_kind)
            {
                if section.threads.is_empty()
                    && (section.project_id.is_none()
                        || section
                            .project_id
                            .as_deref()
                            .is_some_and(|id| id.eq_ignore_ascii_case(BOTS_PROJECT_ID)))
                {
                    continue;
                }
                let pinned = section.project_id.is_none();
                let name = section.name.clone();
                let group_key = section.project_id.clone();
                let expanded = group_key
                    .as_ref()
                    .is_some_and(|id| self.expanded_sidebar_lists.contains(id));
                let limit = self
                    .sidebar_preferences
                    .limit((f32::from(window.viewport_size().height) - 130.).max(0.));
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
                    && (self.sidebar_preferences.collapsed(section_key(section))
                        || section
                            .project_id
                            .as_ref()
                            .is_some_and(|id| self.collapsed_projects.contains(id)));
                let mut group = div().flex().flex_col().mb_2();
                if let Some(group_id) = section.project_id.clone() {
                    let chats = group_id == NO_PROJECT;
                    let target = group_id.clone();
                    let menu_target = group_id.clone();
                    let new_project_id = group_id.clone();
                    let drag_project = group_id.clone();
                    let drop_project = group_id.clone();
                    let expected_projects = json!(self.projects);
                    let menu_path = self
                        .projects
                        .iter()
                        .find(|project| project["id"] == group_id)
                        .and_then(|project| project["path"].as_str())
                        .map(std::path::PathBuf::from);
                    let menu_context = menu_context.clone();
                    let thread_drop_project = group_id.clone();
                    let highlight_project = group_id.clone();
                    let highlight = self.color(0x29303d);
                    let renaming = self.renaming_project(&group_id);
                    let rename_field = renaming.then(|| self.sidebar_rename_field(cx));
                    group = group.child(
                        div()
                            .id(SharedString::from(format!(
                                "sidebar-project-drag-{group_id}"
                            )))
                            .w_full()
                            .flex()
                            .items_center()
                            .group("sidebar-project-row")
                            .when(!renaming, |row| {
                                row.on_drag(ProjectDrag(drag_project), |drag, _, _, cx| {
                                    cx.new(|_| drag.clone())
                                })
                            })
                            // Conversations dropped on a project move there; the
                            // row lights up as the target, as in Swift.
                            .on_drop(cx.listener(
                                move |this, drag: &sidebar_drop::ThreadDrag, _, cx| {
                                    this.sidebar_drop_on_project(drag, &thread_drop_project, cx)
                                },
                            ))
                            .drag_over::<sidebar_drop::ThreadDrag>(move |style, drag, _, _| {
                                if sidebar_drop::moves_into(drag, &highlight_project) {
                                    style.bg(highlight)
                                } else {
                                    style
                                }
                            })
                            .on_drop(cx.listener(move |this, drag: &ProjectDrag, _, cx| {
                                if drag.0.eq_ignore_ascii_case(&drop_project)
                                    || searching
                                    || chats
                                    || this.media.shutdown_requested
                                    || this.media.close_requested
                                {
                                    return;
                                }
                                let mut ids: Vec<_> = expected_projects
                                    .as_array()
                                    .into_iter()
                                    .flatten()
                                    .map(|project| text(project, "id"))
                                    .collect();
                                if !ids.iter().any(|id| id.eq_ignore_ascii_case(&drag.0)) {
                                    return;
                                }
                                ids.retain(|id| !id.eq_ignore_ascii_case(&drag.0));
                                let index = ids
                                    .iter()
                                    .position(|id| id.eq_ignore_ascii_case(&drop_project))
                                    .unwrap_or(ids.len());
                                ids.insert(index, drag.0.clone());
                                let result = try_state(&this.engine).and_then(|mut engine| {
                                    anyhow::ensure!(!engine.admissions_frozen(), "App is closing");
                                    engine
                                        .store
                                        .reorder_projects_if_unchanged(&expected_projects, &ids)
                                });
                                match result {
                                    Ok(projects) => {
                                        this.projects =
                                            projects.as_array().cloned().unwrap_or_default();
                                        this.sidebar_preference("projectSort", json!("manual"), cx);
                                    }
                                    Err(error) => {
                                        this.status =
                                            format!("Projects could not be reordered: {error}")
                                    }
                                }
                                cx.notify();
                            }))
                            .when_some(rename_field, |row, field| {
                                row.child(
                                    div()
                                        .w_full()
                                        .min_w_0()
                                        .flex()
                                        .items_center()
                                        .gap_2()
                                        .pl_2()
                                        .child(IconName::ChevronDown)
                                        .child(IconName::Folder)
                                        .child(field),
                                )
                            })
                            .when(!renaming, |row| {
                                row.child(
                                    Button::new(SharedString::from(format!(
                                        "project-group-{group_id}"
                                    )))
                                    .ghost()
                                    .compact()
                                    .justify_start()
                                    .w_full()
                                    .h(px(if chats {
                                        if section_index == 0 { 30. } else { 36. }
                                    } else {
                                        28.
                                    }))
                                    .accessibility_id(SharedString::from(format!(
                                        "project-group-{group_id}"
                                    )))
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
                                                !chats
                                                    && !group_id
                                                        .eq_ignore_ascii_case(BOTS_PROJECT_ID),
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
                                        this.sidebar_expand_project(&target, collapsed, cx);
                                    }))
                                    .context_menu(
                                        move |menu, window, cx| {
                                            sidebar_menus::project_menu(
                                                menu,
                                                &menu_target,
                                                chats,
                                                menu_path.clone(),
                                                &menu_context,
                                                window,
                                                cx,
                                            )
                                        },
                                    ),
                                )
                            })
                            .when(
                                !chats && !group_id.eq_ignore_ascii_case(BOTS_PROJECT_ID),
                                |row| {
                                    row.child(
                                        Button::new(SharedString::from(format!(
                                            "sidebar-project-new-{new_project_id}"
                                        )))
                                        .icon(IconName::SquarePen)
                                        .ghost()
                                        .compact()
                                        .w(px(24.))
                                        .h(px(28.))
                                        .opacity(0.)
                                        .group_hover("sidebar-project-row", |button| {
                                            button.opacity(1.)
                                        })
                                        .accessibility_label("New Thread in Project")
                                        .tooltip("New Thread")
                                        .on_click(
                                            cx.listener(move |this, _, window, cx| {
                                                this.new_thread_in_project(
                                                    &new_project_id,
                                                    window,
                                                    cx,
                                                )
                                            }),
                                        ),
                                    )
                                },
                            ),
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
                if pinned {
                    group = div()
                        .flex()
                        .flex_col()
                        .mb_2()
                        .child(self.sidebar_section_header("pinned", "Pinned", searching, cx));
                } else if section.project_id.as_deref() == Some(NO_PROJECT) {
                    let highlight = self.color(0x29303d);
                    group = div()
                        .flex()
                        .flex_col()
                        .mb_2()
                        // Conversations dropped on Chats move there.
                        .on_drop(cx.listener(|this, drag: &sidebar_drop::ThreadDrag, _, cx| {
                            this.sidebar_drop_on_project(drag, NO_PROJECT, cx)
                        }))
                        .drag_over::<sidebar_drop::ThreadDrag>(move |style, drag, _, _| {
                            if sidebar_drop::moves_into(drag, NO_PROJECT) {
                                style.bg(highlight)
                            } else {
                                style
                            }
                        })
                        .child(self.sidebar_section_header("chats", "Chats", searching, cx));
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
                        let archive_id = id.clone();
                        let pinned_drop = id.clone();
                        let drop_project = thread.project_id.clone();
                        let is_archived = thread.archived;
                        let was_unread =
                            self.sidebar_preferences.document["unseen"][&thread.id].is_string();
                        let was_settled = self.sidebar_preferences.document["settledThreads"]
                            [&thread.id]
                            .as_f64()
                            .is_some_and(|date| {
                                date >= thread
                                    .navigation
                                    .as_ref()
                                    .and_then(|meta| meta.updated_at)
                                    .unwrap_or(f64::MAX)
                            });
                        let snoozed = thread.snoozed_until.is_some_and(|date| date > now);
                        let thread_menu = sidebar_menus::ThreadMenu {
                            id: id.clone(),
                            project: thread.project_id.clone(),
                            pinned: thread.pinned,
                            archived: thread.archived,
                            unseen: was_unread,
                            branch: thread
                                .navigation
                                .as_ref()
                                .and_then(|meta| meta.branch.clone()),
                            // Swift's canFork: a conversation with something to fork.
                            can_fork: thread
                                .navigation
                                .as_ref()
                                .and_then(|meta| meta.item_count)
                                .is_none_or(|count| count > 0),
                            snoozed,
                            settled: was_settled,
                            running: self.running.contains(&thread.id),
                        };
                        // A right-click inside a multi-selection acts on all of it.
                        let bulk_menu = (self.thread_bulk.mode
                            && self.thread_bulk.picked.len() > 1
                            && self.thread_bulk.picked.contains(&id))
                        .then(|| {
                            let ids = self.thread_bulk.picked.iter().cloned().collect::<Vec<_>>();
                            let archived = self
                                .threads
                                .iter()
                                .any(|row| row.archived && ids.contains(&row.id));
                            let running = ids.iter().any(|id| self.running.contains(id));
                            (ids, archived, running)
                        });
                        let menu_context = menu_context.clone();
                        let drag = sidebar_drop::ThreadDrag {
                            id: id.clone(),
                            title: thread.title.clone(),
                            project: thread.project_id.clone(),
                            pinned,
                        };
                        let label = format!(
                            "{}{}{}{}",
                            if thread.pinned && !pinned { "★ " } else { "" },
                            if thread.archived { "Archived · " } else { "" },
                            if snoozed { "Snoozed · " } else { "" },
                            format!(
                                "{}{}",
                                if self.sidebar_preferences.document["unseen"][&thread.id]
                                    .is_string()
                                {
                                    "● "
                                } else {
                                    ""
                                },
                                thread.title
                            )
                        );
                        let row = div()
                            .id(SharedString::from(format!(
                                "sidebar-thread-drag-{}",
                                thread.id
                            )))
                            .w_full()
                            .flex()
                            .items_center()
                            .group("sidebar-thread-row")
                            .when(!self.renaming_thread(&id), |row| {
                                row.on_drag(drag, |drag, _, _, cx| cx.new(|_| drag.clone()))
                            })
                            .on_drop(cx.listener(
                                move |this, drag: &sidebar_drop::ThreadDrag, _, cx| {
                                    // Among a project's conversations a drop moves it there.
                                    if !pinned {
                                        this.sidebar_drop_on_project(drag, &drop_project, cx);
                                        return;
                                    }
                                    if drag.id.eq_ignore_ascii_case(&pinned_drop)
                                        || !drag.pinned
                                        || searching
                                        || !this.search.read(cx).value().trim().is_empty()
                                        || this.thread_bulk.mode
                                        || this.media.shutdown_requested
                                        || this.media.close_requested
                                    {
                                        return;
                                    }
                                    let mut ids: Vec<_> = this
                                        .sidebar_sections(
                                            coincide_core::store::swift_timestamp(),
                                            false,
                                            "",
                                        )
                                        .into_iter()
                                        .find(|section| section.project_id.is_none())
                                        .map(|section| {
                                            section
                                                .threads
                                                .iter()
                                                .map(|thread| thread.id.clone())
                                                .collect()
                                        })
                                        .unwrap_or_default();
                                    if !ids.contains(&drag.id) {
                                        return;
                                    }
                                    ids.retain(|id| id != &drag.id);
                                    let index = ids
                                        .iter()
                                        .position(|id| id == &pinned_drop)
                                        .unwrap_or(ids.len());
                                    ids.insert(index, drag.id.clone());
                                    this.sidebar_preference("pinnedThreads", json!(ids), cx);
                                },
                            ));
                        if self.renaming_thread(&id) {
                            group = group.child(row.child(self.sidebar_rename_field(cx)));
                            continue;
                        }
                        group = group.child(
                            row.child(
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
                                    .child(self.sidebar_thread_content(
                                        thread,
                                        if self.thread_bulk.mode {
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
                                        },
                                        now,
                                    ))
                                    .tooltip(thread.title.clone())
                                    .w_full()
                                    .selected(if self.thread_bulk.mode {
                                        self.thread_bulk.picked.contains(&id)
                                    } else {
                                        id == selected
                                    })
                                    .on_click(cx.listener(
                                        move |this, event: &ClickEvent, window, cx| {
                                            if this.sidebar_modified_click(&id, event, window, cx) {
                                                return;
                                            }
                                            // A second click on the open conversation's title renames it.
                                            if !selecting
                                                && this
                                                    .sidebar_title_click(&id, event.click_count())
                                            {
                                                this.begin_sidebar_rename(&id, window, cx);
                                                return;
                                            }
                                            this.bulk_row_click(&id, selecting, window, cx);
                                            if !selecting
                                                && this
                                                    .selected
                                                    .as_ref()
                                                    .is_some_and(|thread| thread["id"] == id)
                                                && this.find_context_available()
                                            {
                                                this.composer
                                                    .read(cx)
                                                    .focus_handle(cx)
                                                    .focus(window, cx);
                                            }
                                        },
                                    ))
                                    .context_menu(move |menu, window, cx| match &bulk_menu {
                                        Some((ids, archived, running)) => sidebar_menus::bulk_menu(
                                            menu,
                                            ids,
                                            *archived,
                                            *running,
                                            &menu_context.parent,
                                        ),
                                        None => sidebar_menus::thread_menu(
                                            menu,
                                            &thread_menu,
                                            &menu_context,
                                            window,
                                            cx,
                                        ),
                                    }),
                            )
                            .child(
                                Button::new(SharedString::from(format!(
                                    "sidebar-thread-archive-{archive_id}"
                                )))
                                .icon(IconName::Archive)
                                .ghost()
                                .compact()
                                .w(px(24.))
                                .h(px(28.))
                                .opacity(0.)
                                .group_hover("sidebar-thread-row", |button| button.opacity(1.))
                                .disabled(
                                    self.thread_bulk.mode || self.running.contains(&archive_id),
                                )
                                .accessibility_label(if is_archived {
                                    "Restore conversation"
                                } else {
                                    "Archive conversation"
                                })
                                .tooltip(if is_archived { "Restore" } else { "Archive" })
                                .on_click(cx.listener(
                                    move |this, _, window, cx| {
                                        if this.thread_bulk.mode
                                            || this.running.contains(&archive_id)
                                        {
                                            return;
                                        }
                                        // Acts on this row; only a confirmation opens it.
                                        this.sidebar_thread_action(
                                            &archive_id,
                                            sidebar_menus::ThreadAction::Archive(!is_archived),
                                            window,
                                            cx,
                                        );
                                    },
                                )),
                            ),
                        );
                    }
                }
                if !collapsed
                    && !searching
                    && !pinned
                    && (hidden > 0 || (expanded && total > limit))
                {
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
                section_index += 1;
            }
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
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                if this.search.read(cx).focus_handle(cx).is_focused(window)
                    || this.project_picker_open
                    || this.sidebar_renaming.is_some()
                {
                    return;
                }
                if this.sidebar_list_key(event, window, cx) {
                    cx.stop_propagation();
                    return;
                }
                if this.thread_bulk.mode {
                    return;
                }
                let modifiers = event.keystroke.modifiers;
                if modifiers.platform || modifiers.control || modifiers.alt || modifiers.shift {
                    return;
                }
                let step = match event.keystroke.key.as_str() {
                    "up" | "arrowup" => -1,
                    "down" | "arrowdown" => 1,
                    "enter" | "return" if this.thread_list_focus.is_focused(window) => {
                        if this.find_context_available() {
                            this.composer.read(cx).focus_handle(cx).focus(window, cx);
                            cx.stop_propagation();
                        }
                        return;
                    }
                    _ => return,
                };
                let rows = this.bulk_sidebar_binding(cx).rows;
                let ids = rows.iter().map(|row| row.0.as_str()).collect::<Vec<_>>();
                let selected = this
                    .selected
                    .as_ref()
                    .and_then(|thread| thread["id"].as_str());
                if let Some(id) = adjacent_sidebar_row(&ids, selected, step).map(str::to_owned) {
                    this.select(&id, window, cx);
                    this.thread_list_focus.focus(window, cx);
                    cx.stop_propagation();
                }
            }))
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
            .child(self.sidebar_search_field(cx))
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
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .w_full()
                            .min_w_0()
                            .child(sidebar_button_label("Scheduled".into()))
                            .when(
                                self.sidebar_schedules.iter().any(|task| {
                                    task["isPaused"] != true && task["awaitingApproval"] != true
                                }),
                                |row| {
                                    row.child(
                                        div().text_xs().child(
                                            self.sidebar_schedules
                                                .iter()
                                                .filter(|task| {
                                                    task["isPaused"] != true
                                                        && task["awaitingApproval"] != true
                                                })
                                                .count()
                                                .to_string(),
                                        ),
                                    )
                                },
                            ),
                    )
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
                                        let value = !this.show_snoozed;
                                        this.sidebar_preference(
                                            "showsSnoozedThreads",
                                            json!(value),
                                            cx,
                                        );
                                        this.show_snoozed =
                                            this.sidebar_preferences.flag("showsSnoozedThreads");
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
            .when(self.sidebar_lifecycle.visible(), |view| {
                view.child(self.sidebar_lifecycle_controls(cx))
            })
            .child(conversations)
            .when_some(self.sidebar_preferences.error.as_ref(), |view, error| {
                view.child(div().text_xs().child(error.clone()))
            })
            .when(self.sidebar_settle_undo.is_some(), |view| {
                view.child(
                    Button::new("sidebar-undo-settle")
                        .ghost()
                        .compact()
                        .label("Undo Settle")
                        .on_click(cx.listener(|this, _, _, cx| this.undo_settle(cx))),
                )
            })
            .when_some(self.sidebar_resize.error(), |view, error| {
                view.child(div().text_xs().child(error))
            })
            .child(resize)
            .into_any_element()
    }

    /// Rename for the open conversation, in its sidebar row as in Swift.
    pub(super) fn begin_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return;
        };
        self.begin_sidebar_rename(&id, window, cx);
    }

    pub(super) fn patch_navigation(
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
        if !self.thread_actions_open && self.archive_confirmation.is_none() {
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

#[cfg(test)]
mod keyboard_navigation_tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn arrow_navigation_uses_only_visible_rows_and_preserves_boundaries() {
        let visible = ["first", "selected", "last"];
        assert_eq!(
            adjacent_sidebar_row(&visible, Some("selected"), 1),
            Some("last")
        );
        assert_eq!(
            adjacent_sidebar_row(&visible, Some("first"), -1),
            Some("first")
        );
        assert_eq!(
            adjacent_sidebar_row(&visible, Some("hidden-by-filter"), 1),
            Some("first")
        );
        assert_eq!(adjacent_sidebar_row(&visible, None, -1), Some("last"));
        assert_eq!(adjacent_sidebar_row(&[], None, 1), None);
    }
}
