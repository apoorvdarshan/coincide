use super::*;
use gpui_kit::component::tooltip::Tooltip;

use coincide_core::bot_runtime::BOTS_PROJECT_ID;

#[path = "navigation_sections.rs"]
mod sections;
use crate::native_menu::AccessibleMenuExt as _;
use gpui_kit::assets::IconName;
use gpui_kit::component::menu::{ContextMenuExt, PopupMenuItem};
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

pub(super) fn adjacent_sidebar_row<'a>(
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

fn is_bots_project(project: &Value) -> bool {
    project["isBots"] == true
        || project["id"]
            .as_str()
            .is_some_and(|id| id.eq_ignore_ascii_case(BOTS_PROJECT_ID))
}

/// Folders of the user's projects that no longer exist, by project ID.
pub(super) fn missing_project_folders(projects: &[Value]) -> std::collections::HashSet<String> {
    projects
        .iter()
        .filter(|project| project["isChats"] != true && !is_bots_project(project))
        .filter(|project| {
            project["path"]
                .as_str()
                .is_some_and(|path| !path.is_empty() && !std::path::Path::new(path).exists())
        })
        .map(|project| text(project, "id"))
        .collect()
}

/// A path with the home folder written as "~", as Swift's `Formatting.abbreviatedPath`.
fn abbreviated_path(path: &str, home: Option<&str>) -> String {
    match home.filter(|home| !home.is_empty()) {
        Some(home) if path == home => "~".into(),
        Some(home) => path
            .strip_prefix(home)
            .filter(|rest| rest.starts_with(['/', '\\']))
            .map_or_else(|| path.to_owned(), |rest| format!("~{rest}")),
        None => path.to_owned(),
    }
}

fn home_folder() -> Option<String> {
    std::env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).ok()
}

/// The project a new thread starts in, as Swift's `currentProjectID`: the
/// sidebar's project filter (a Rust-only view), else the open thread's project
/// but never Bots, else the first project. Projectless chats stand in for
/// Swift's Chats project. None when there is no project to start in.
pub(super) fn new_thread_project(
    filter: Option<&str>,
    selected: Option<&Value>,
    projects: &[Value],
    threads: &[ThreadSummary],
) -> Option<String> {
    let known = |id: &str| {
        id == NO_PROJECT
            || projects.iter().any(|project| {
                project["id"]
                    .as_str()
                    .is_some_and(|known| known.eq_ignore_ascii_case(id))
            })
    };
    if let Some(filter) = filter.filter(|id| known(id) || id.eq_ignore_ascii_case(BOTS_PROJECT_ID))
    {
        return Some(filter.to_owned());
    }
    if let Some(project) = selected
        .map(|thread| sections::project_key(thread["projectID"].as_str().unwrap_or("")))
        .filter(|id| !id.eq_ignore_ascii_case(BOTS_PROJECT_ID) && known(id))
    {
        return Some(project.to_owned());
    }
    if let Some(first) = projects.iter().find(|project| !is_bots_project(project)) {
        return Some(text(first, "id"));
    }
    threads
        .iter()
        .any(|thread| sections::project_key(&thread.project_id) == NO_PROJECT)
        .then(|| NO_PROJECT.to_owned())
}

/// The visible sidebar row after `id`, else the one before it, as Swift's
/// `handOffSelectionIfNeeded` prefers.
fn sidebar_sibling(rows: &[(String, bool, bool)], id: &str) -> Option<String> {
    let index = rows.iter().position(|row| row.0 == id)?;
    rows.get(index + 1)
        .or_else(|| index.checked_sub(1).and_then(|before| rows.get(before)))
        .map(|row| row.0.clone())
}
impl Coincide {
    /// Add Project…: the folder chooser, from the empty sidebar or New Thread.
    pub(super) fn add_project_from_sidebar(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.open_project_form(project_management::Mode::Add, None, window, cx);
        if self.project_management.session.open {
            self.choose_project_folder(window, cx);
        }
    }
    /// Folders dropped on the empty sidebar become projects, as Swift's
    /// `ThreadActions.addProjects`.
    fn add_dropped_project_folders(
        &mut self,
        paths: &ExternalPaths,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let folders: Vec<std::path::PathBuf> = paths
            .paths()
            .iter()
            .filter(|path| path.is_dir())
            .cloned()
            .collect();
        let Some(first) = folders
            .first()
            .and_then(|path| path.to_str())
            .map(str::to_owned)
        else {
            return;
        };
        self.open_project_form(project_management::Mode::Add, None, window, cx);
        if !self.project_management.session.open {
            return;
        }
        self.project_path
            .update(cx, |input, cx| input.set_value(first, window, cx));
        self.project_management.folders = folders;
        self.add_project(window, cx);
    }
    /// The row's tooltip while searching also quotes the message that matched.
    fn sidebar_search_tooltip(&self, tooltip: String, id: &str, searching: bool) -> String {
        match self.sidebar_message_search.line(id).filter(|_| searching) {
            Some(line) => format!("{tooltip}\n“{line}”"),
            None => tooltip,
        }
    }
    /// Inbox Undo shares the batch-aware settle receipt used by sidebar menus.
    pub(super) fn undo_sidebar_settle(&mut self, cx: &mut Context<Self>) {
        self.undo_settle(cx);
    }
    /// Archives or restores the open conversation, keeping Undo for it.
    pub(super) fn set_archived(
        &mut self,
        id: &str,
        archived: bool,
        cx: &mut Context<Self>,
    ) -> bool {
        let done = self.patch_navigation(
            id,
            json!({"isArchived":archived}),
            if archived {
                "Conversation archived."
            } else {
                "Conversation restored."
            },
            cx,
        );
        if done {
            self.remember_archive(id, archived);
        }
        done
    }
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

    /// A thread row as Swift's ThreadCell draws it: the agent's logo (a shield
    /// while approvals wait, an archive box once archived, a spinner while
    /// working), the title (semibold for an unseen result) and where it lives,
    /// then the pin, schedule clock, status badge, unseen dot and its age or
    /// running time.
    fn sidebar_thread_content(
        &self,
        thread: &ThreadSummary,
        label: String,
        place: Option<String>,
        now: f64,
        cx: &App,
    ) -> Div {
        let schedules = self
            .sidebar_schedules
            .iter()
            // Only schedules that can run: allowed and not paused.
            .filter(|task| {
                task["threadID"] == thread.id
                    && task["isPaused"] != true
                    && task["approvalState"] == "approved"
            })
            .map(|task| text(task, "name"))
            .collect::<Vec<_>>();
        let status = self.sidebar_thread_status(thread);
        let ink = self.color(0xe4e9f2);
        let theme = cx.theme();
        let badge = status.badge();
        let leading = div()
            .flex_shrink_0()
            .size(px(16.))
            .flex()
            .items_center()
            .justify_center();
        let leading = match status {
            sidebar_thread_status::RowStatus::Running { .. } => {
                leading.child(gpui_kit::component::spinner::Spinner::new().small())
            }
            sidebar_thread_status::RowStatus::Approval(_) => leading.child(
                Icon::new(IconName::ShieldAlert)
                    .xsmall()
                    .text_color(theme.warning),
            ),
            _ if thread.archived => leading.child(
                Icon::new(IconName::Archive)
                    .xsmall()
                    .text_color(ink.opacity(0.45)),
            ),
            _ => match thread
                .navigation
                .as_ref()
                .and_then(|meta| chat_layout::provider_logo(meta.provider.as_deref()?))
            {
                // Monochrome branding keeps a light backing in either appearance.
                Some(logo) => {
                    leading.child(img(logo).size(px(14.)).rounded(px(3.)).bg(rgb(0x2b2b2b)))
                }
                None => leading.child(Icon::new(IconName::Cpu).xsmall()),
            },
        };
        let time = match status {
            sidebar_thread_status::RowStatus::Running { since } => Some((
                sidebar_thread_status::elapsed(now - since),
                self.color(0x98b1d4),
            )),
            _ => Some((
                sidebar_age(
                    thread.navigation.as_ref().and_then(|meta| meta.updated_at),
                    now,
                ),
                ink.opacity(0.55),
            )),
        }
        .filter(|_| badge.is_none());
        div()
            .flex()
            .items_center()
            .gap(px(6.))
            .w_full()
            .min_w_0()
            .child(leading)
            .child(
                // The project name gives way before the title does.
                div()
                    .min_w_0()
                    .flex_shrink(1.)
                    .truncate()
                    .text_left()
                    .child(label)
                    .when(status.unseen(), |title| {
                        title.font_weight(FontWeight::SEMIBOLD)
                    })
                    .when(thread.archived, |title| title.text_color(ink.opacity(0.6))),
            )
            .when_some(place.filter(|place| !place.is_empty()), |row, place| {
                row.child(
                    div()
                        .flex_shrink(4.)
                        .min_w_0()
                        .truncate()
                        .text_size(px(11.))
                        .text_color(ink.opacity(0.45))
                        .child(place),
                )
            })
            .child(div().flex_1())
            .child(
                div()
                    .flex()
                    .flex_shrink_0()
                    .items_center()
                    .gap(px(4.))
                    .when(thread.pinned, |row| {
                        row.child(
                            Icon::new(IconName::Pin)
                                .size(px(10.))
                                .text_color(ink.opacity(0.45)),
                        )
                    })
                    .when(!schedules.is_empty(), |row| {
                        row.child(
                            div()
                                .id(SharedString::from(format!("sidebar-clock-{}", thread.id)))
                                .text_color(ink.opacity(0.45))
                                .child(Icon::new(IconName::Clock).size(px(10.)))
                                .tooltip(move |window, cx| {
                                    Tooltip::new(schedules.join("\n")).build(window, cx)
                                }),
                        )
                    })
                    .when_some(badge, |row, badge| {
                        let color = if matches!(status, sidebar_thread_status::RowStatus::Failed) {
                            theme.danger
                        } else {
                            theme.warning
                        };
                        row.child(
                            div()
                                .px(px(5.))
                                .rounded_full()
                                .bg(color.opacity(0.18))
                                .text_color(color)
                                .text_size(px(10.))
                                .font_weight(FontWeight::SEMIBOLD)
                                .child(badge),
                        )
                    })
                    .when(
                        matches!(status, sidebar_thread_status::RowStatus::Completed),
                        |row| row.child(div().size(px(7.)).rounded_full().bg(theme.success)),
                    )
                    .when_some(time, |row, (time, color)| {
                        row.child(div().text_size(px(11.)).text_color(color).child(time))
                    }),
            )
    }
    pub(super) fn sidebar_thread_status(
        &self,
        thread: &ThreadSummary,
    ) -> sidebar_thread_status::RowStatus {
        sidebar_thread_status::row_status(
            self.thread_activity.approvals(&thread.id),
            self.running
                .contains(&thread.id)
                .then(|| self.thread_activity.running_since(&thread.id))
                .flatten()
                .or_else(|| {
                    self.running
                        .contains(&thread.id)
                        .then(coincide_core::store::swift_timestamp)
                }),
            self.sidebar_preferences.document["unseen"][&thread.id].as_str(),
        )
    }
    /// Swift's row tooltip: the title, where it lives, then its status.
    fn sidebar_thread_tooltip(&self, thread: &ThreadSummary, now: f64) -> String {
        let mut lines = vec![thread.title.clone()];
        let mut place = self
            .projects
            .iter()
            .find(|project| project["id"] == thread.project_id)
            .map(|project| text(project, "name"))
            .unwrap_or_default();
        if let Some(branch) = thread
            .navigation
            .as_ref()
            .and_then(|meta| meta.branch.as_deref())
        {
            place = if place.is_empty() {
                branch.to_owned()
            } else {
                format!("{place} · {branch}")
            };
        }
        if !place.is_empty() {
            lines.push(place);
        }
        if let Some(label) = self.sidebar_thread_status(thread).label() {
            lines.push(label.into());
        }
        if thread.snoozed_until.is_some_and(|until| until > now) {
            lines.push("Snoozed".into());
        }
        lines.join("\n")
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
    /// Swift's project filter and actions, as one compact menu anchored to the
    /// sidebar's ellipsis instead of an expanded list of full-width buttons.
    pub(super) fn project_filter_menu(&self, label: String, cx: &mut Context<Self>) -> AnyElement {
        let parent = cx.entity().downgrade();
        let selected = self.selected_project.clone();
        let projects = self
            .projects
            .iter()
            .filter(|project| {
                project["id"] != NO_PROJECT
                    && !project["id"]
                        .as_str()
                        .is_some_and(|id| id.eq_ignore_ascii_case(BOTS_PROJECT_ID))
            })
            .map(|project| (text(project, "id"), text(project, "name")))
            .collect::<Vec<_>>();
        let archived = self.show_archived;
        let snoozed = self.show_snoozed;
        let can_manage = selected.as_ref().is_some_and(|id| {
            self.projects.iter().any(|project| {
                project["id"].as_str() == Some(id.as_str())
                    && project["isChats"] != true
                    && project["isBots"] != true
                    && id != NO_PROJECT
                    && !id.eq_ignore_ascii_case(BOTS_PROJECT_ID)
            })
        });
        let bulk = !self.thread_bulk.mode
            && self.thread_bulk.status.is_empty()
            && self.bulk_sidebar_binding(cx).available;
        let menu_parent = parent.clone();
        let choose = move |id: Option<String>| {
            let parent = menu_parent.clone();
            move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
                let id = id.clone();
                let _ = parent.update(cx, |this, cx| {
                    this.thread_bulk.invalidate();
                    this.selected_project = id;
                    this.project_picker_open = false;
                    cx.notify();
                });
            }
        };
        Button::new("projects-toggle")
            .icon(IconName::Ellipsis)
            .ghost()
            .compact()
            .h(px(32.))
            .accessibility_label(format!("Project: {label}"))
            .tooltip("Conversation filters and project actions")
            .accessible_menu(move |mut menu, _window, _cx| {
                menu = menu.item(
                    PopupMenuItem::new("All projects")
                        .checked(selected.is_none())
                        .on_click(choose(None)),
                );
                menu = menu.item(
                    PopupMenuItem::new("No project")
                        .checked(selected.as_deref() == Some(NO_PROJECT))
                        .on_click(choose(Some(NO_PROJECT.into()))),
                );
                menu = menu.item(
                    PopupMenuItem::new("Bots")
                        .checked(selected.as_deref() == Some(BOTS_PROJECT_ID))
                        .on_click(choose(Some(BOTS_PROJECT_ID.into()))),
                );
                for (id, name) in projects.clone() {
                    let checked = selected.as_ref() == Some(&id);
                    menu = menu.item(
                        PopupMenuItem::new(name)
                            .checked(checked)
                            .on_click(choose(Some(id))),
                    );
                }
                menu = menu.separator();
                {
                    let parent = parent.clone();
                    menu = menu.item(PopupMenuItem::new("Add folders…").on_click(
                        move |_, window, cx| {
                            let _ = parent.update(cx, |this, cx| {
                                this.open_project_form(
                                    project_management::Mode::Add,
                                    None,
                                    window,
                                    cx,
                                )
                            });
                        },
                    ));
                }
                {
                    let parent = parent.clone();
                    let selected = selected.clone();
                    menu = menu.item(
                        PopupMenuItem::new("Manage selected project…")
                            .disabled(!can_manage)
                            .on_click(move |_, window, cx| {
                                let selected = selected.clone();
                                let _ = parent.update(cx, |this, cx| {
                                    this.open_project_form(
                                        project_management::Mode::Manage,
                                        selected,
                                        window,
                                        cx,
                                    )
                                });
                            }),
                    );
                }
                {
                    let parent = parent.clone();
                    menu = menu.item(PopupMenuItem::new("Removed projects…").on_click(
                        move |_, window, cx| {
                            let _ = parent.update(cx, |this, cx| {
                                this.open_project_form(
                                    project_management::Mode::Recovery,
                                    None,
                                    window,
                                    cx,
                                )
                            });
                        },
                    ));
                }
                if bulk {
                    let parent = parent.clone();
                    menu = menu.separator().item(
                        PopupMenuItem::new("Select conversations…").on_click(move |_, _, cx| {
                            let _ = parent.update(cx, |this, cx| {
                                this.project_picker_open = false;
                                this.sync_thread_bulk(cx);
                                if this.bulk_sidebar_binding(cx).available {
                                    this.thread_bulk.mode = true;
                                    this.thread_bulk.invalidate();
                                }
                                cx.notify();
                            });
                        }),
                    );
                }
                menu = menu.separator();
                {
                    let parent = parent.clone();
                    menu = menu.item(
                        PopupMenuItem::new("Show archived")
                            .checked(archived)
                            .on_click(move |_, _, cx| {
                                let parent = parent.clone();
                                let _ = parent.update(cx, |this, cx| {
                                    this.thread_bulk.invalidate();
                                    this.show_archived = !this.show_archived;
                                    this.refresh(cx);
                                });
                            }),
                    );
                }
                {
                    let parent = parent.clone();
                    menu = menu.item(
                        PopupMenuItem::new("Show snoozed")
                            .checked(snoozed)
                            .on_click(move |_, _, cx| {
                                let _ = parent.update(cx, |this, cx| {
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
                                });
                            }),
                    );
                }
                menu
            })
            .into_any_element()
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
        // Swift shows only its "No Projects" panel until a project exists.
        let no_projects = !self
            .projects
            .iter()
            .any(|project| !is_bots_project(project))
            && !self.sidebar_all_threads.iter().any(|thread| {
                !sections::project_key(&thread.project_id).eq_ignore_ascii_case(BOTS_PROJECT_ID)
            });
        if no_projects {
            conversations = conversations.child(self.sidebar_empty_view(None, cx));
        } else if !sections
            .iter()
            .any(|section| !section.threads.is_empty() || section_key(section) == "projects")
            && !self.has_sidebar_bot_rows(searching, cx)
            && (searching || sections.is_empty())
        {
            conversations = conversations.child(if searching {
                self.sidebar_empty_view(Some(query.trim()), cx)
            } else {
                div()
                    .p_3()
                    .text_sm()
                    .child("No conversations match these filters.")
                    .into_any_element()
            });
        }
        let section_order = if no_projects {
            Vec::new()
        } else {
            self.sidebar_preferences.order()
        };
        for section_kind in section_order {
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
                    let folder = !chats && !group_id.eq_ignore_ascii_case(BOTS_PROJECT_ID);
                    // Swift's ProjectCell: a question-mark folder and "Folder not
                    // found" once the folder is gone, else its path.
                    let missing = folder && self.missing_project_folders.contains(&group_id);
                    let folder_tooltip = menu_path.as_ref().map(|path| {
                        let path =
                            abbreviated_path(&path.to_string_lossy(), home_folder().as_deref());
                        if missing {
                            format!("Folder not found: {path}")
                        } else {
                            path
                        }
                    });
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
                                        "{} {} {name}, {} conversations{}",
                                        if collapsed { "Expand" } else { "Collapse" },
                                        if chats { "section" } else { "project" },
                                        threads.len(),
                                        if missing { ", folder not found" } else { "" }
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
                                            .when(folder, |row| {
                                                row.child(if missing {
                                                    IconName::FolderX
                                                } else {
                                                    IconName::Folder
                                                })
                                            })
                                            .child(sidebar_button_label(name)),
                                    )
                                    .disabled(searching)
                                    .when(searching, |button| {
                                        button.tooltip("Clear search to collapse project groups")
                                    })
                                    .when_some(
                                        folder_tooltip.filter(|_| folder && !searching),
                                        |button, tooltip| button.tooltip(tooltip),
                                    )
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
                        let label = thread.title.clone();
                        let place = pinned
                            .then(|| {
                                self.projects
                                    .iter()
                                    .find(|project| project["id"] == thread.project_id)
                                    .map(|project| text(project, "name"))
                            })
                            .flatten();
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
                                        "{} conversation: {}{}",
                                        if self.thread_bulk.mode {
                                            "Select"
                                        } else {
                                            "Open"
                                        },
                                        thread.title,
                                        self.sidebar_thread_status(thread)
                                            .label()
                                            .map(|label| format!(", {label}"))
                                            .unwrap_or_default()
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
                                        place,
                                        now,
                                        cx,
                                    ))
                                    .tooltip(self.sidebar_search_tooltip(
                                        self.sidebar_thread_tooltip(thread, now),
                                        &thread.id,
                                        searching,
                                    ))
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
            .when(cfg!(target_os = "macos"), |view| view.pt(px(56.)))
            .gap_2()
            .when(cfg!(target_os = "macos"), |view| {
                view.child(
                    div()
                        .absolute()
                        .top_0()
                        .left_0()
                        .right_0()
                        .h(px(44.))
                        .on_mouse_down(MouseButton::Left, window_chrome::titlebar_mouse_down),
                )
            })
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
                        div()
                            .group("sidebar-new-thread-row")
                            .flex_1()
                            .min_w_0()
                            .child(
                                Button::new("sidebar-new-thread")
                                    .icon(IconName::SquarePen)
                                    .ghost()
                                    .compact()
                                    .h(px(32.))
                                    .w_full()
                                    .justify_start()
                                    .accessibility_label("New Thread")
                                    .child(self.sidebar_row_content(
                                        "New Thread",
                                        "sidebar-new-thread-row",
                                        keyboard_settings::shortcut_hint(
                                            &self.settings,
                                            keyboard_settings::Command::NewThread,
                                        ),
                                        None,
                                    ))
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.new_thread(window, cx)
                                    })),
                            ),
                    )
                    .child(self.project_filter_menu(project_label, cx)),
            )
            .child(self.sidebar_search_field(cx))
            .child(
                div().group("sidebar-scheduled-row").w_full().child(
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
                            self.sidebar_row_content(
                                "Scheduled",
                                "sidebar-scheduled-row",
                                keyboard_settings::shortcut_hint(
                                    &self.settings,
                                    keyboard_settings::Command::Schedules,
                                ),
                                Some(
                                    self.sidebar_schedules
                                        .iter()
                                        .filter(|task| {
                                            coincide_core::schedule_presentation::is_active(task)
                                        })
                                        .count(),
                                )
                                .filter(|count| *count > 0),
                            ),
                        )
                        // Lit while the Scheduled panel shows; clicking again closes it.
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.thread_bulk.invalidate();
                            if this.schedules_open {
                                this.close_schedule_surface();
                            } else {
                                this.hide_inline_settings();
                                this.workspace_open = false;
                                this.session_import_open = false;
                                this.open_global_schedules(cx);
                            }
                            this.sync_transcription_binding(cx);
                            cx.notify();
                        })),
                ),
            )
            .when(self.show_archived || self.show_snoozed, |view| {
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
            })
            .when_some(self.project_management_form(cx), |view, form| {
                view.child(form)
            })
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

    /// A top row's title with, on hover, its shortcut. A count, such as the
    /// active schedules', shows in the shortcut's place until the pointer is on
    /// the row, as Swift's `SidebarActionRow`.
    fn sidebar_row_content(
        &self,
        title: &'static str,
        group: &'static str,
        shortcut: Option<String>,
        count: Option<usize>,
    ) -> Div {
        let quiet = self.color(0xe4e9f2).opacity(0.4);
        let has_shortcut = shortcut.is_some();
        div()
            .flex()
            .items_center()
            .gap_2()
            .w_full()
            .min_w_0()
            .child(sidebar_button_label(title.into()).flex_1())
            .child(
                div()
                    .relative()
                    .flex()
                    .flex_shrink_0()
                    .items_center()
                    .text_size(px(12.))
                    .text_color(quiet)
                    .when_some(count, |slot, count| {
                        slot.child(
                            div()
                                .when(has_shortcut, |count| {
                                    count.group_hover(group, |style| style.opacity(0.))
                                })
                                .child(count.to_string()),
                        )
                    })
                    .when_some(shortcut, |slot, shortcut| {
                        slot.child(
                            div()
                                .when(count.is_some(), |hint| hint.absolute().right_0())
                                .whitespace_nowrap()
                                .opacity(0.)
                                .group_hover(group, |style| style.opacity(1.))
                                .child(shortcut),
                        )
                    }),
            )
    }

    /// Swift's `SidebarEmptyView`: "No Projects" with Add Project… and a folder
    /// drop target, or "No Results" for a search that matches nothing.
    fn sidebar_empty_view(&self, query: Option<&str>, cx: &mut Context<Self>) -> AnyElement {
        let ink = self.color(0xe4e9f2);
        let (icon, title, message) = match query {
            None => (
                IconName::FolderPlus,
                "No Projects",
                "Add a folder to start a thread with your coding agents, or drop one here."
                    .to_owned(),
            ),
            Some(query) => (
                IconName::Search,
                "No Results",
                format!("No threads or projects match “{query}”."),
            ),
        };
        let accepts_folders = query.is_none();
        div()
            .id(if accepts_folders {
                "sidebar-empty-projects"
            } else {
                "sidebar-empty-results"
            })
            .role(Role::Group)
            .aria_label(title)
            .size_full()
            .min_h(px(240.))
            .flex()
            .flex_col()
            .items_center()
            .justify_center()
            .px_4()
            .pb(px(80.))
            .m(px(8.))
            .rounded(px(8.))
            .border_1()
            .border_dashed()
            .border_color(transparent_black())
            .when(accepts_folders, |view| {
                // Lit only while what is dragged holds a folder.
                view.drag_over::<ExternalPaths>(move |style, paths, _, _| {
                    if paths.paths().iter().any(|path| path.is_dir()) {
                        style.bg(ink.opacity(0.06)).border_color(ink.opacity(0.5))
                    } else {
                        style
                    }
                })
                .on_drop(cx.listener(
                    |this, paths: &ExternalPaths, window, cx| {
                        this.add_dropped_project_folders(paths, window, cx)
                    },
                ))
            })
            .child(
                div()
                    .text_size(px(if accepts_folders { 30. } else { 26. }))
                    .text_color(ink.opacity(0.35))
                    .child(icon),
            )
            .child(
                div()
                    .mt_2()
                    .text_size(px(15.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(ink.opacity(0.65))
                    .child(title),
            )
            .child(
                div()
                    .mt_2()
                    .max_w(px(200.))
                    .text_center()
                    .text_size(px(12.))
                    .text_color(ink.opacity(0.65))
                    .child(message),
            )
            .when(accepts_folders, |view| {
                view.child(
                    div().mt(px(14.)).child(
                        Button::new("sidebar-empty-add-project")
                            .primary()
                            .label("Add Project…")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.add_project_from_sidebar(window, cx)
                            })),
                    ),
                )
            })
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

    /// After the open conversation leaves the sidebar, open its sibling, or
    /// clear the conversation like Swift does when no sibling remains.
    pub(super) fn hand_off_removed_selection(
        &mut self,
        removed: &str,
        sibling: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .selected
            .as_ref()
            .and_then(|thread| thread["id"].as_str())
            != Some(removed)
        {
            return;
        }
        if let Some(sibling) = sibling {
            self.select(&sibling, window, cx);
            return;
        }
        self.selected = None;
        self.transcript_count = 0;
        self.transcript_list.reset(0);
        self.expanded.clear();
        self.composer
            .update(cx, |input, cx| input.set_value("", window, cx));
        self.sync_workspace_context(cx);
        cx.notify();
    }
    /// Archives the open conversation and opens the next one, as Swift does.
    pub(super) fn archive_open_thread(
        &mut self,
        id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let rows = self.bulk_sidebar_binding(cx).rows;
        let sibling = sidebar_sibling(&rows, id);
        let done = self.set_archived(id, true, cx);
        if done {
            self.hand_off_removed_selection(id, sibling, window, cx);
        }
        done
    }
    pub(super) fn request_archive(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref() else {
            return;
        };
        let id = text(thread, "id");
        if thread["isArchived"] == true {
            self.set_archived(&id, false, cx);
        } else if self.settings["confirmBeforeArchivingThreads"]
            .as_bool()
            .unwrap_or(true)
        {
            self.archive_confirmation = Some(id);
            cx.notify();
        } else {
            self.archive_open_thread(&id, window, cx);
        }
    }

    fn snooze_selected(
        &mut self,
        seconds: Option<f64>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(id) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        let date = seconds.map(|seconds| coincide_core::store::swift_timestamp() + seconds);
        let leaves_sidebar = date.is_some() && !self.show_snoozed;
        let rows = self.bulk_sidebar_binding(cx).rows;
        let sibling = sidebar_sibling(&rows, &id);
        let done = self.patch_navigation(
            &id,
            json!({"snoozedUntil":date}),
            if date.is_some() {
                "Conversation snoozed in the sidebar."
            } else {
                "Conversation unsnoozed."
            },
            cx,
        );
        if done && leaves_sidebar {
            self.hand_off_removed_selection(&id, sibling, window, cx);
        }
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
                            .on_click(cx.listener(move |this, _, window, cx| {
                                if this.archive_confirmation.as_deref() != Some(id.as_str())
                                    || this
                                        .selected
                                        .as_ref()
                                        .is_none_or(|thread| thread["id"] != id)
                                {
                                    return;
                                }
                                if this.archive_open_thread(&id, window, cx) {
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
            pane =
                pane.child(
                    div()
                        .flex()
                        .flex_wrap()
                        .items_center()
                        .gap_2()
                        .child(Button::new("snooze-hour").label("Snooze 1 hour").on_click(
                            cx.listener(|this, _, window, cx| {
                                this.snooze_selected(Some(3600.), window, cx)
                            }),
                        ))
                        .child(Button::new("snooze-day").label("Snooze 1 day").on_click(
                            cx.listener(|this, _, window, cx| {
                                this.snooze_selected(Some(86400.), window, cx)
                            }),
                        ))
                        .when(snoozed, |row| {
                            row.child(Button::new("snooze-clear").label("Unsnooze").on_click(
                                cx.listener(|this, _, window, cx| {
                                    this.snooze_selected(None, window, cx)
                                }),
                            ))
                            .child(
                                div().text_sm().child(format!(
                                    "Until {}",
                                    schedule_date(&thread["snoozedUntil"])
                                )),
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

#[cfg(test)]
mod project_tests {
    use super::*;

    fn thread(project: &str) -> ThreadSummary {
        serde_json::from_value(json!({"id":"t","title":"t","project_id":project,"pinned":false,"archived":false,"snoozed_until":null,"navigation":null})).unwrap()
    }

    #[::core::prelude::v1::test]
    fn new_threads_go_to_the_filter_the_open_project_or_the_first_never_bots() {
        let projects = vec![
            json!({"id":BOTS_PROJECT_ID,"name":"Bots","isBots":true}),
            json!({"id":"A","name":"Alpha"}),
            json!({"id":"B","name":"Beta"}),
        ];
        let open_b = json!({"projectID":"b"});
        let open_bot = json!({"projectID":BOTS_PROJECT_ID,"botID":"bot"});
        let open_gone = json!({"projectID":"deleted"});
        let open_chat = json!({"projectID":""});
        assert_eq!(
            new_thread_project(Some("A"), Some(&open_b), &projects, &[]).as_deref(),
            Some("A")
        );
        assert_eq!(
            new_thread_project(None, Some(&open_b), &projects, &[]).as_deref(),
            Some("b")
        );
        for open in [&open_bot, &open_gone] {
            assert_eq!(
                new_thread_project(None, Some(open), &projects, &[]).as_deref(),
                Some("A")
            );
        }
        assert_eq!(
            new_thread_project(None, Some(&open_chat), &projects, &[]).as_deref(),
            Some(NO_PROJECT)
        );
        // A filter for a project that is gone falls through.
        assert_eq!(
            new_thread_project(Some("deleted"), None, &projects, &[]).as_deref(),
            Some("A")
        );
        // With no project, existing chats stand in for Swift's Chats project…
        let only_bots = &projects[..1];
        assert_eq!(
            new_thread_project(None, None, only_bots, &[thread("")]).as_deref(),
            Some(NO_PROJECT)
        );
        // …otherwise New Thread asks for a folder to add.
        assert!(new_thread_project(None, None, only_bots, &[thread(BOTS_PROJECT_ID)]).is_none());
        assert!(new_thread_project(None, None, &[], &[]).is_none());
    }

    #[::core::prelude::v1::test]
    fn only_project_folders_that_are_gone_are_missing() {
        let present = std::env::temp_dir();
        let gone = present.join(format!("coincide-missing-{}", uuid::Uuid::new_v4()));
        let projects = vec![
            json!({"id":"here","path":present}),
            json!({"id":"gone","path":gone}),
            json!({"id":"chats","path":gone,"isChats":true}),
            json!({"id":BOTS_PROJECT_ID,"path":gone}),
            json!({"id":"pathless"}),
        ];
        assert_eq!(
            missing_project_folders(&projects),
            std::collections::HashSet::from(["gone".to_owned()])
        );
    }

    #[::core::prelude::v1::test]
    fn removed_open_thread_hands_off_to_the_next_visible_row_then_the_previous() {
        let rows_of = |ids: &[&str]| {
            ids.iter()
                .map(|id| ((*id).to_owned(), false, false))
                .collect::<Vec<_>>()
        };
        let rows = rows_of(&["a", "b", "c"]);
        assert_eq!(sidebar_sibling(&rows, "b").as_deref(), Some("c"));
        assert_eq!(sidebar_sibling(&rows, "c").as_deref(), Some("b"));
        assert_eq!(sidebar_sibling(&rows, "a").as_deref(), Some("b"));
        assert_eq!(sidebar_sibling(&rows_of(&["only"]), "only"), None);
        assert_eq!(sidebar_sibling(&rows, "missing"), None);
    }

    #[::core::prelude::v1::test]
    fn paths_under_home_are_abbreviated() {
        assert_eq!(
            abbreviated_path("/Users/me/code", Some("/Users/me")),
            "~/code"
        );
        assert_eq!(abbreviated_path("/Users/me", Some("/Users/me")), "~");
        assert_eq!(
            abbreviated_path("/Users/meadow", Some("/Users/me")),
            "/Users/meadow"
        );
        assert_eq!(
            abbreviated_path(r"C:\Users\me\code", Some(r"C:\Users\me")),
            r"~\code"
        );
        assert_eq!(abbreviated_path("/tmp/x", None), "/tmp/x");
    }
}
