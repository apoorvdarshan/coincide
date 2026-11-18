use super::*;
use gpui_kit::component::tooltip::Tooltip;

use coincide_core::bot_runtime::BOTS_PROJECT_ID;

#[path = "navigation_sections.rs"]
mod sections;
use crate::native_menu::AccessibleMenuExt as _;
use gpui_kit::assets::IconName;
use gpui_kit::base::{ElementExt as _, Placement};
use gpui_kit::component::menu::{ContextMenuExt, PopupMenuItem};
use sections::NO_PROJECT;
pub(super) const NO_PROJECT_ID: &str = NO_PROJECT;

// Button's root alignment does not reach its independently centered label slot.
// A full-width content child keeps the real Button and aligns/truncates its text.
fn sidebar_button_label(label: String) -> Div {
    div().w_full().min_w_0().truncate().text_left().child(label)
}

// Index once per sidebar render instead of scanning every schedule for each
// conversation. Preserve the source order used in the schedule tooltip.
fn scheduled_threads(tasks: &[Value]) -> std::collections::HashMap<&str, Vec<String>> {
    let mut result = std::collections::HashMap::<&str, Vec<String>>::new();
    for task in tasks {
        if task["isPaused"] != true
            && task["approvalState"] == "approved"
            && let Some(id) = task["threadID"].as_str()
        {
            result.entry(id).or_default().push(text(task, "name"));
        }
    }
    result
}

fn pinned_positions(ids: &[String]) -> std::collections::HashMap<String, usize> {
    let mut result = std::collections::HashMap::new();
    for (index, id) in ids.iter().enumerate() {
        result.entry(id.to_ascii_lowercase()).or_insert(index + 1);
    }
    result
}

// The whole project header is a drop target as well as a click target. Keep
// the expandable button and its adjacent New Thread control inside that row.
fn project_row<F>(id: &str, enabled: bool, on_click: F) -> Stateful<Div>
where
    F: Fn(&ClickEvent, &mut Window, &mut App) + 'static,
{
    div()
        .id(SharedString::from(format!("sidebar-project-drag-{id}")))
        .w_full()
        .flex()
        .items_center()
        .group("sidebar-project-row")
        .capture_any_mouse_down(keep_sidebar_focus_on_context_click)
        .when(enabled, |row| row.on_click(on_click))
}

// Let the menu take focus without first focusing the row's button. Keyboard
// navigation retains the button's normal focus indicator.
fn keep_sidebar_focus_on_context_click(event: &MouseDownEvent, window: &mut Window, _: &mut App) {
    if event.button == MouseButton::Right {
        window.prevent_default();
    }
}

fn without_parent_click<F>(on_click: F) -> impl Fn(&ClickEvent, &mut Window, &mut App) + 'static
where
    F: Fn(&ClickEvent, &mut Window, &mut App) + 'static,
{
    move |event, window, cx| {
        cx.stop_propagation();
        on_click(event, window, cx);
    }
}

fn project_group_button(
    id: &str,
    name: String,
    collapsed: bool,
    chats: bool,
    folder: bool,
    missing: bool,
    count: usize,
    height: f32,
) -> Button {
    let id = SharedString::from(format!("project-group-{id}"));
    Button::new(id.clone())
        .ghost()
        .compact()
        .justify_start()
        .flex_1()
        .min_w_0()
        .h(px(height))
        .accessibility_id(id)
        .accessibility_label(SharedString::from(format!(
            "{} {} {name}, {count} conversations{}",
            if collapsed { "Expand" } else { "Collapse" },
            if chats { "section" } else { "project" },
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

pub(super) fn home_display_path(path: &str) -> String {
    abbreviated_path(path, home_folder().as_deref())
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
        let bots: std::collections::HashSet<_> = self
            .sidebar_bots
            .iter()
            .filter_map(|bot| bot["id"].as_str())
            .map(str::to_ascii_lowercase)
            .collect();
        let pinned = pinned_positions(&self.sidebar_preferences.strings("pinnedThreads"));
        let mut projects: Vec<_> = self
            .projects
            .iter()
            .map(|p| (text(p, "id"), text(p, "name")))
            .collect();
        match self.sidebar_preferences.sort("projectSort") {
            "name" => projects
                .sort_by(|(_, left), (_, right)| sidebar_preferences::name_order(left, right)),
            "recentActivity" => {
                let mut recent = std::collections::HashMap::<&str, f64>::new();
                for thread in &self.sidebar_all_threads {
                    if let Some(stamp) = thread.navigation.as_ref().and_then(|nav| nav.updated_at) {
                        recent
                            .entry(&thread.project_id)
                            .and_modify(|current| {
                                if stamp.total_cmp(current).is_gt() {
                                    *current = stamp;
                                }
                            })
                            .or_insert(stamp);
                    }
                }
                projects.sort_by(|left, right| {
                    let stamp = |id: &str| recent.get(id).copied().unwrap_or(0.);
                    stamp(&right.0).total_cmp(&stamp(&left.0))
                });
            }
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
                section.threads.sort_by_cached_key(|thread| {
                    pinned
                        .get(&thread.id.to_ascii_lowercase())
                        .copied()
                        .unwrap_or(0)
                });
            } else {
                let sort = self.sidebar_preferences.sort(key);
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
                    let order = match sort {
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
                let represented = bot.is_some_and(|id| bots.contains(&id.to_ascii_lowercase()));
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
        schedules: &[String],
        cx: &App,
    ) -> Div {
        let schedules = schedules.to_vec();
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
                .and_then(|meta| chat_layout::provider_mark(meta.provider.as_deref()?, 14.))
            {
                Some(logo) => leading.child(logo),
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
        if let Some((_, detail)) =
            sidebar_thread_status::work_labels(self.thread_activity.work(&thread.id))
        {
            lines.push(detail);
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
            && !self.thread_bulk.busy()
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
        if let Ok(mut bounds) = self.sidebar_row_bounds.lock() {
            bounds.clear();
        }
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
        let schedules = scheduled_threads(&self.sidebar_schedules);
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
        // Project drop handlers share their render-time comparison snapshot.
        let project_order_snapshot = std::cell::OnceCell::new();
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
                    let row_target = group_id.clone();
                    let menu_target = group_id.clone();
                    let new_project_id = group_id.clone();
                    let drag_project = group_id.clone();
                    let drop_project = group_id.clone();
                    let expected_projects = Arc::clone(
                        project_order_snapshot.get_or_init(|| Arc::new(json!(self.projects))),
                    );
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
                        let path = home_display_path(&path.to_string_lossy());
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
                        project_row(
                            &group_id,
                            !renaming && !searching,
                            cx.listener(move |this, _, _, cx| {
                                this.thread_bulk.invalidate();
                                this.sidebar_expand_project(&row_target, collapsed, cx);
                            }),
                        )
                        .when(!renaming, |row| {
                            row.on_drag(ProjectDrag(drag_project), |drag, _, _, cx| {
                                cx.new(|_| drag.clone())
                            })
                        })
                        // Conversations dropped on a project move there; the
                        // row lights up as the target, as in Swift.
                        .on_drop(cx.listener(
                            move |this, drag: &sidebar_drop::ThreadDrag, window, cx| {
                                this.sidebar_drop_on_project(drag, &thread_drop_project, window, cx)
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
                                project_group_button(
                                    &group_id,
                                    name,
                                    collapsed,
                                    chats,
                                    folder,
                                    missing,
                                    threads.len(),
                                    if chats {
                                        if section_index == 0 { 30. } else { 36. }
                                    } else {
                                        28.
                                    },
                                )
                                .disabled(searching)
                                .when(searching, |button| {
                                    button.tooltip("Clear search to collapse project groups")
                                })
                                .when_some(
                                    folder_tooltip.filter(|_| folder && !searching),
                                    |button, tooltip| {
                                        button.tooltip(tooltip).tooltip_placement(Placement::Right)
                                    },
                                )
                                .on_click(without_parent_click(cx.listener(
                                    move |this, _, _, cx| {
                                        this.thread_bulk.invalidate();
                                        this.sidebar_expand_project(&target, collapsed, cx);
                                    },
                                )))
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
                                    .group_hover("sidebar-project-row", |button| button.opacity(1.))
                                    .accessibility_label("New Thread in Project")
                                    .tooltip("New Thread")
                                    .on_click(
                                        without_parent_click(cx.listener(
                                            move |this, _, window, cx| {
                                                this.new_thread_in_project(
                                                    &new_project_id,
                                                    window,
                                                    cx,
                                                )
                                            },
                                        )),
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
                        .on_drop(cx.listener(
                            |this, drag: &sidebar_drop::ThreadDrag, window, cx| {
                                this.sidebar_drop_on_project(drag, NO_PROJECT, window, cx)
                            },
                        ))
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
                        let anchor_bounds = self.sidebar_row_bounds.clone();
                        let anchor_key = format!("thread:{}", thread.id);
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
                            .on_prepaint(move |bounds, _, _| {
                                if let Ok(mut rows) = anchor_bounds.lock() {
                                    rows.insert(anchor_key, bounds);
                                }
                            })
                            .flex()
                            .items_center()
                            .group("sidebar-thread-row")
                            .capture_any_mouse_down(keep_sidebar_focus_on_context_click)
                            .when(!self.renaming_thread(&id), |row| {
                                row.on_drag(drag, |drag, _, _, cx| cx.new(|_| drag.clone()))
                            })
                            .on_drop(cx.listener(
                                move |this, drag: &sidebar_drop::ThreadDrag, window, cx| {
                                    // Among a project's conversations a drop moves it there.
                                    if !pinned {
                                        this.sidebar_drop_on_project(
                                            drag,
                                            &drop_project,
                                            window,
                                            cx,
                                        );
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
                                    .h(px(30.))
                                    .rounded(px(9.))
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
                                    .child(
                                        self.sidebar_thread_content(
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
                                            schedules
                                                .get(id.as_str())
                                                .map(Vec::as_slice)
                                                .unwrap_or_default(),
                                            cx,
                                        ),
                                    )
                                    .tooltip(self.sidebar_search_tooltip(
                                        self.sidebar_thread_tooltip(thread, now),
                                        &thread.id,
                                        searching,
                                    ))
                                    .tooltip_placement(Placement::Right)
                                    .flex_1()
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
                                            if !selecting {
                                                this.thread_navigation
                                                    .focus_composer_when_ready(&id);
                                            }
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
                                    )),
                            )
                            .child(
                                Button::new(SharedString::from(format!(
                                    "sidebar-thread-archive-{archive_id}"
                                )))
                                .icon(IconName::Archive)
                                .ghost()
                                .compact()
                                .w(px(28.))
                                .h(px(30.))
                                .flex_shrink_0()
                                .opacity(0.65)
                                .group_hover("sidebar-thread-row", |button| button.opacity(1.))
                                .disabled(selecting || (!is_archived && thread_menu.running))
                                .accessibility_label(if is_archived {
                                    "Restore conversation"
                                } else {
                                    "Archive conversation"
                                })
                                .tooltip(if is_archived { "Restore" } else { "Archive" })
                                .tooltip_placement(Placement::Right)
                                .on_click(cx.listener(
                                    move |this, event, window, cx| {
                                        if this.thread_bulk.mode {
                                            return;
                                        }
                                        this.sidebar_thread_action(
                                            &archive_id,
                                            sidebar_menus::ThreadAction::Archive(!is_archived),
                                            window,
                                            cx,
                                        );
                                        if !is_archived {
                                            this.anchor_sidebar_review_to_click(event, cx);
                                        }
                                    },
                                )),
                            )
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
                let selected = this.thread_navigation.target().or_else(|| {
                    this.selected
                        .as_ref()
                        .and_then(|thread| thread["id"].as_str())
                });
                if let Some(id) = adjacent_sidebar_row(&ids, selected, step).map(str::to_owned) {
                    this.navigate_to_thread(&id, window, cx);
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
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.thread_bulk.invalidate();
                            if this.schedules_open {
                                this.close_chat_inspector(cx);
                            } else {
                                this.hide_inline_settings();
                                this.workspace_open = false;
                                this.session_import_open = false;
                                this.open_global_schedules(window, cx);
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
            .child(conversations)
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
                    self.replace_selected_thread(Some(thread));
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
        self.replace_selected_thread(None);
        self.transcript_count = 0;
        self.transcript_list.reset(0);
        self.expanded.clear();
        self.composer
            .update(cx, |input, cx| input.set_value("", window, cx));
        self.sync_workspace_context(cx);
        cx.notify();
    }
    /// Archives a conversation and opens its sibling if it was selected.
    pub(super) fn archive_open_thread(
        &mut self,
        id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let sibling = self
            .selected
            .as_ref()
            .filter(|thread| thread["id"] == id)
            .and_then(|_| sidebar_sibling(&self.bulk_sidebar_binding(cx).rows, id));
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
            self.sidebar_archive_review(id, text(thread, "title"), window, cx);
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
        if !self.thread_actions_open {
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
    fn sidebar_indexes_keep_original_schedule_and_pin_order() {
        let tasks = vec![
            json!({"threadID":"A","name":"First","approvalState":"approved"}),
            json!({"threadID":"A","name":"Paused","approvalState":"approved","isPaused":true}),
            json!({"threadID":"B","name":"Other","approvalState":"approved"}),
            json!({"threadID":"A","name":"Second","approvalState":"approved"}),
            json!({"threadID":"A","name":"Waiting","approvalState":"pending"}),
            json!({"name":"No conversation","approvalState":"approved"}),
        ];
        let schedules = scheduled_threads(&tasks);
        assert_eq!(schedules.get("A").unwrap(), &["First", "Second"]);
        assert_eq!(schedules.get("B").unwrap(), &["Other"]);
        assert_eq!(schedules.len(), 2);
        let positions = pinned_positions(&["A".into(), "b".into(), "a".into()]);
        assert_eq!(positions.get("a"), Some(&1));
        assert_eq!(positions.get("b"), Some(&2));
    }
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
mod project_pointer_tests {
    use super::{ProjectDrag, project_group_button, project_row, without_parent_click};
    use gpui_kit::{
        AppContext, Bounds, Context, IntoElement, Modifiers, MouseButton, ParentElement, Pixels,
        Render, Styled, Window,
        assets::IconName,
        component::button::{Button, ButtonVariants},
        point,
        prelude::*,
        px,
    };
    use std::sync::{Arc, Mutex};

    #[gpui_kit::test]
    #[ignore = "invoked in an isolated HOME by project_header_click_targets"]
    fn project_header_real_pointer_targets(cx: &mut gpui_kit::TestAppContext) {
        use gpui_base::ElementExt;
        use std::{cell::Cell, rc::Rc};

        struct HeaderProbe {
            toggles: Rc<Cell<usize>>,
            new_threads: Rc<Cell<usize>>,
            row_bounds: Arc<Mutex<Option<Bounds<Pixels>>>>,
            button_bounds: Arc<Mutex<Option<Bounds<Pixels>>>>,
        }
        impl Render for HeaderProbe {
            fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
                let row_toggles = self.toggles.clone();
                let button_toggles = self.toggles.clone();
                let new_threads = self.new_threads.clone();
                let row_bounds = self.row_bounds.clone();
                let button_bounds = self.button_bounds.clone();
                project_row("fixture", true, move |_, _, _| {
                    row_toggles.set(row_toggles.get() + 1)
                })
                .w(px(300.))
                .on_drag(ProjectDrag("fixture".into()), |drag, _, _, cx| {
                    cx.new(|_| drag.clone())
                })
                .on_prepaint(move |bounds, _, _| *row_bounds.lock().unwrap() = Some(bounds))
                .child(
                    project_group_button(
                        "fixture",
                        "coincide".into(),
                        false,
                        false,
                        true,
                        false,
                        1,
                        28.,
                    )
                    .on_click(without_parent_click(move |_, _, _| {
                        button_toggles.set(button_toggles.get() + 1)
                    }))
                    .on_prepaint(move |bounds, _, _| *button_bounds.lock().unwrap() = Some(bounds)),
                )
                .child(
                    Button::new("fixture-new-thread")
                        .icon(IconName::SquarePen)
                        .ghost()
                        .compact()
                        .w(px(24.))
                        .h(px(28.))
                        .on_click(without_parent_click(move |_, _, _| {
                            new_threads.set(new_threads.get() + 1)
                        })),
                )
            }
        }

        cx.update(gpui_kit::init);
        let toggles = Rc::new(Cell::new(0));
        let new_threads = Rc::new(Cell::new(0));
        let row_bounds = Arc::new(Mutex::new(None));
        let button_bounds = Arc::new(Mutex::new(None));
        let (_, cx) = cx.add_window_view({
            let toggles = toggles.clone();
            let new_threads = new_threads.clone();
            let row_bounds = row_bounds.clone();
            let button_bounds = button_bounds.clone();
            move |_, _| HeaderProbe {
                toggles,
                new_threads,
                row_bounds,
                button_bounds,
            }
        });
        cx.update(|window, cx| {
            window.activate_window();
            window.draw(cx).clear(cx);
        });
        let row = row_bounds.lock().unwrap().expect("project row is painted");
        let button = button_bounds
            .lock()
            .unwrap()
            .expect("project button is painted");
        assert!(
            button.size.width > px(200.),
            "the project button must fill the row"
        );
        assert!(
            button.size.width < row.size.width,
            "the new-thread button has its own space"
        );
        for x in [px(8.), px(40.), px(90.), button.size.width - px(8.)] {
            cx.simulate_click(
                point(
                    button.origin.x + x,
                    button.origin.y + button.size.height / 2.,
                ),
                Modifiers::default(),
            );
        }
        assert_eq!(
            toggles.get(),
            4,
            "arrow, folder, name and empty space each toggle once"
        );
        cx.simulate_click(
            point(
                row.origin.x + row.size.width - px(12.),
                row.origin.y + row.size.height / 2.,
            ),
            Modifiers::default(),
        );
        assert_eq!(new_threads.get(), 1);
        assert_eq!(
            toggles.get(),
            4,
            "New Thread must not also collapse the project"
        );
        let drag_start = point(button.origin.x + px(90.), button.origin.y + px(14.));
        let drag_end = point(button.origin.x + px(150.), button.origin.y + px(14.));
        cx.simulate_mouse_down(drag_start, MouseButton::Left, Modifiers::default());
        cx.simulate_mouse_move(drag_end, Some(MouseButton::Left), Modifiers::default());
        cx.simulate_mouse_up(drag_end, MouseButton::Left, Modifiers::default());
        assert_eq!(toggles.get(), 4, "dragging must not toggle the project");
    }

    #[::core::prelude::v1::test]
    fn project_header_click_targets() {
        let fixture = tempfile::tempdir().unwrap();
        let mut command = std::process::Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--ignored",
                "--exact",
                "navigation::project_pointer_tests::project_header_real_pointer_targets",
                "--nocapture",
                "--test-threads=1",
            ])
            .env_clear()
            .env("HOME", fixture.path())
            .env("USERPROFILE", fixture.path())
            .env("TMPDIR", fixture.path())
            .env("TMP", fixture.path())
            .env("TEMP", fixture.path())
            .env("PATH", "")
            .env("LANG", "en_US.UTF-8")
            .current_dir(fixture.path());
        #[cfg(windows)]
        for key in ["SystemRoot", "WINDIR"] {
            if let Some(value) = std::env::var_os(key) {
                command.env(key, value);
            }
        }
        let output = command.output().unwrap();
        assert!(
            output.status.success() && String::from_utf8_lossy(&output.stdout).contains("1 passed"),
            "Project header pointer test failed\n{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
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
