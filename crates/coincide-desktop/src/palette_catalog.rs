//! What the command palette lists, built from the window's state as Swift's
//! `PaletteCatalog`: the everyday actions, every thread (the most recent first,
//! with its project, branch and age), projects, Settings sections, and the
//! nested lists New Thread in…, Go to File… and Search in Project…. Also runs
//! the folder searches the palette asks for, off the UI thread.
use super::*;
use crate::app_menu::AppAction;
use coincide_core::project_search;
use command_palette::{
    MenuContent, PaletteCommand as C, PaletteEntry as E, PaletteGroup as G, PaletteIcon,
    PaletteList, PaletteMenu, SearchKind, SearchRequest, ThreadFacts,
};
use gpui_kit::assets::IconName;
use keyboard_settings::Command as K;
use settings::SettingsSection as S;
use std::path::{Path, PathBuf};

const NEW_THREAD_MENU: &str = "new-thread-in";
const FILES_MENU: &str = "go-to-file";
const TEXT_MENU: &str = "search-project";
/// Swift `PaletteCatalog.settings()`.
pub(super) const SETTINGS: [(&str, &str, IconName, S, &[&str]); 7] = [
    (
        "setting:general",
        "General Settings",
        IconName::Settings,
        S::General,
        &["appearance", "notifications", "font", "confirm"],
    ),
    (
        "setting:providers",
        "Agent Settings",
        IconName::User,
        S::Accounts,
        &["providers", "claude", "codex", "cursor", "cli", "login"],
    ),
    (
        "setting:models",
        "Model Settings",
        IconName::Cpu,
        S::Models,
        &["models", "effort", "custom", "default"],
    ),
    (
        "setting:instructions",
        "Global Instructions",
        IconName::BookOpen,
        S::Instructions,
        &["agents.md", "claude.md", "rules", "memory"],
    ),
    (
        "setting:keyboard",
        "Keyboard Shortcuts",
        IconName::Keyboard,
        S::Keyboard,
        &["shortcuts", "keybindings", "keys"],
    ),
    (
        "setting:voice",
        "Voice Settings",
        IconName::Mic,
        S::Voice,
        &[
            "dictation",
            "voice",
            "speech",
            "microphone",
            "whisper",
            "transcription",
        ],
    ),
    (
        "setting:about",
        "About Coincide",
        IconName::Info,
        S::About,
        &["version", "license", "credits"],
    ),
];

fn home() -> PathBuf {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .unwrap_or_default()
}
fn bounded(text: &str, max: usize) -> String {
    text.chars().filter(|c| *c != '\0').take(max).collect()
}
/// A project the user added, not Coincide's own Chats and Bots containers.
fn user_project(project: &Value) -> bool {
    let id = text(project, "id");
    !id.is_empty()
        && project["isChats"] != true
        && project["isBots"] != true
        && id != navigation::NO_PROJECT_ID
        && !id.eq_ignore_ascii_case(coincide_core::bot_runtime::BOTS_PROJECT_ID)
}
fn project_entry(command: C, project: &Value, home: &Path) -> E {
    let path = text(project, "path");
    let mut entry = E::new(command, bounded(&text(project, "name"), 512), G::Projects)
        .subtitle(bounded(
            &project_search::abbreviated(Path::new(&path), home),
            1024,
        ))
        .icon(IconName::Folder);
    if !path.is_empty() {
        entry.keywords.push(bounded(&path, 128));
    }
    entry
}

impl Coincide {
    /// The worktree branch prefix the palette searches branches without.
    pub(super) fn palette_branch_prefix(&self) -> String {
        bounded(
            self.settings["worktreeBranchPrefix"]
                .as_str()
                .unwrap_or("coincide/"),
            256,
        )
    }
    fn current_palette_project(&self) -> Option<&Value> {
        let id = self.selected_project.clone().or_else(|| {
            self.selected
                .as_ref()
                .map(|thread| text(thread, "projectID"))
        })?;
        self.projects
            .iter()
            .find(|project| project["id"] == id.as_str() && user_project(project))
    }
    pub(super) fn palette_catalog(&self) -> (Vec<E>, Vec<PaletteMenu>) {
        let home = home();
        let mut entries = Vec::new();
        let mut menus = Vec::new();
        let projects = self
            .projects
            .iter()
            .filter(|project| user_project(project))
            .collect::<Vec<_>>();
        if let Some(project) = self.current_palette_project() {
            let mut entry = E::new(
                C::NewThread {
                    project_id: Some(text(project, "id")),
                },
                bounded(&format!("New Thread in {}", text(project, "name")), 512),
                G::Actions,
            )
            .keywords(&["new thread", "chat", "create", "draft"])
            .icon(IconName::SquarePen);
            entry.trailing = keyboard_settings::shortcut_label(&self.settings, K::NewThread);
            entries.push(entry);
        }
        entries.push(
            E::new(C::NewThread { project_id: None }, "New Chat", G::Actions)
                .keywords(&[
                    "new chat",
                    "chat",
                    "no project",
                    "without project",
                    "conversation",
                ])
                .icon(IconName::MessagesSquare),
        );
        if !projects.is_empty() {
            entries.push(
                E::new(
                    C::OpenMenu {
                        id: NEW_THREAD_MENU.into(),
                    },
                    "New Thread in…",
                    G::Actions,
                )
                .keywords(&["new thread", "project", "pick", "choose", "select"])
                .icon(IconName::SquarePen),
            );
            menus.push(PaletteMenu {
                id: NEW_THREAD_MENU.into(),
                title: "New Thread in…".into(),
                placeholder: "Search projects…".into(),
                content: MenuContent::Lists(vec![PaletteList {
                    title: "Projects".into(),
                    entries: projects
                        .iter()
                        .map(|project| {
                            project_entry(
                                C::NewThread {
                                    project_id: Some(text(project, "id")),
                                },
                                project,
                                &home,
                            )
                        })
                        .collect(),
                }]),
            });
        }
        let mut schedules = E::new(
            C::ShowSchedules,
            if self.schedules_open {
                "Hide Scheduled Tasks"
            } else {
                "Show Scheduled Tasks"
            },
            G::Actions,
        )
        .keywords(&[
            "schedule",
            "scheduled",
            "tasks",
            "automation",
            "cron",
            "recurring",
            "daily",
            "weekly",
            "reminder",
        ])
        .icon(IconName::Clock);
        schedules.trailing = keyboard_settings::shortcut_label(&self.settings, K::Schedules);
        entries.push(schedules);
        // Go to File and Search in Project over the thread's folder.
        if let Some(root) = self
            .open_folder()
            .filter(|_| self.selected.is_some())
            .and_then(|root| root.to_str().map(str::to_owned))
            .filter(|root| root.len() <= 4096)
        {
            entries.push(
                E::new(
                    C::OpenMenu {
                        id: FILES_MENU.into(),
                    },
                    "Go to File…",
                    G::MoreActions,
                )
                .keywords(&["file", "open", "find", "quick open"])
                .icon(IconName::FileSearch),
            );
            entries.push(
                E::new(
                    C::OpenMenu {
                        id: TEXT_MENU.into(),
                    },
                    "Search in Project…",
                    G::MoreActions,
                )
                .keywords(&["search", "grep", "find", "text", "content"])
                .icon(IconName::TextSearch),
            );
            menus.push(PaletteMenu {
                id: FILES_MENU.into(),
                title: "Go to File…".into(),
                placeholder: "Search files…".into(),
                content: MenuContent::Search(SearchKind::Files { root: root.clone() }),
            });
            menus.push(PaletteMenu {
                id: TEXT_MENU.into(),
                title: "Search in Project…".into(),
                placeholder: "Search text in files…".into(),
                content: MenuContent::Search(SearchKind::Text { root }),
            });
        }
        let mut open_settings = E::new(C::OpenSettings, "Open Settings", G::MoreActions)
            .keywords(&["settings", "preferences", "configuration"])
            .icon(IconName::Settings);
        open_settings.trailing = Some(if cfg!(target_os = "macos") {
            "⌘,".into()
        } else {
            "Ctrl+,".into()
        });
        entries.push(open_settings);
        entries.extend(self.palette_threads());
        // Swift's palette also lists the open conversation's own actions.
        if self.selected.is_some() {
            let running = self
                .selected
                .as_ref()
                .map(|thread| text(thread, "id"))
                .is_some_and(|id| self.running.iter().any(|running| running == &id));
            let archived = self
                .selected
                .as_ref()
                .is_some_and(|thread| thread["isArchived"] == true);
            let pinned = self
                .selected
                .as_ref()
                .is_some_and(|thread| thread["isPinned"] == true);
            let mut thread_entries = vec![
                E::new(
                    C::Action {
                        id: "thread:find".into(),
                    },
                    "Find in Thread",
                    G::Actions,
                )
                .keywords(&["find", "search", "transcript", "text"])
                .icon(IconName::Search),
                E::new(
                    C::Action {
                        id: "thread:rename".into(),
                    },
                    "Rename Thread…",
                    G::Actions,
                )
                .keywords(&["rename", "title", "name"])
                .icon(IconName::Pencil),
                E::new(
                    C::Action {
                        id: "thread:pin".into(),
                    },
                    if pinned { "Unpin Thread" } else { "Pin Thread" },
                    G::Actions,
                )
                .keywords(&["pin", "unpin", "top"])
                .icon(IconName::Pin),
                E::new(
                    C::Action {
                        id: "thread:archive".into(),
                    },
                    if archived {
                        "Unarchive Thread"
                    } else {
                        "Archive Thread"
                    },
                    G::Actions,
                )
                .keywords(&["archive", "restore", "hide", "done"])
                .icon(IconName::Archive),
                E::new(
                    C::Action {
                        id: "action:pull-requests".into(),
                    },
                    "Pull Requests",
                    G::Actions,
                )
                .keywords(&["pr", "review", "github", "merge"])
                .icon(IconName::GitPullRequest),
                E::new(
                    C::Action {
                        id: "action:edit-instructions".into(),
                    },
                    "Edit Instructions",
                    G::Actions,
                )
                .keywords(&["agents.md", "rules", "memory", "instructions"])
                .icon(IconName::BookOpen),
                E::new(
                    C::Action {
                        id: "action:new-bot".into(),
                    },
                    "New Bot…",
                    G::Actions,
                )
                .keywords(&["bot", "agent", "assistant", "create"])
                .icon(IconName::Bot),
            ];
            if running {
                thread_entries.insert(
                    0,
                    E::new(
                        C::Action {
                            id: "thread:stop".into(),
                        },
                        "Stop",
                        G::Actions,
                    )
                    .keywords(&["stop", "cancel", "interrupt", "halt"])
                    .icon(IconName::Square),
                );
            }
            entries.extend(thread_entries);
        }
        entries.push(
            E::new(
                C::SelectProject { project_id: None },
                "All projects",
                G::Projects,
            )
            .icon(IconName::Folder),
        );
        entries.extend(projects.iter().map(|project| {
            project_entry(
                C::SelectProject {
                    project_id: Some(text(project, "id")),
                },
                project,
                &home,
            )
        }));
        entries.extend(SETTINGS.iter().map(|(id, title, icon, _, keywords)| {
            E::new(C::Action { id: (*id).into() }, *title, G::Settings)
                .subtitle("Settings")
                .keywords(keywords)
                .icon(*icon)
        }));
        (entries, menus)
    }
    /// Every thread the user hasn't archived, the most recently active first,
    /// whatever the sidebar's search shows; the open one is listed last.
    fn palette_threads(&self) -> Vec<E> {
        let now = coincide_core::store::swift_timestamp();
        let current = self.selected.as_ref().map(|thread| text(thread, "id"));
        let mut threads = self
            .sidebar_all_threads
            .iter()
            .filter(|thread| !thread.archived && !thread.id.is_empty())
            .collect::<Vec<_>>();
        let updated = |thread: &ThreadSummary| {
            thread
                .navigation
                .as_ref()
                .and_then(|meta| meta.updated_at)
                .unwrap_or(f64::MIN)
        };
        threads.sort_by(|a, b| updated(b).total_cmp(&updated(a)));
        threads
            .into_iter()
            .map(|thread| {
                let project = self
                    .projects
                    .iter()
                    .find(|project| project["id"] == thread.project_id.as_str())
                    .map(|project| text(project, "name"))
                    .unwrap_or_default();
                let branch = thread
                    .navigation
                    .as_ref()
                    .and_then(|meta| meta.branch.clone())
                    .unwrap_or_default();
                let is_current = current.as_deref() == Some(thread.id.as_str());
                let mut parts = Vec::new();
                if !project.is_empty() {
                    parts.push(project.clone());
                }
                if !branch.is_empty() {
                    parts.push(format!("#{branch}"));
                }
                if is_current {
                    parts.push("Current thread".into());
                }
                let title = if thread.title.trim().is_empty() {
                    "New conversation".into()
                } else {
                    bounded(&thread.title, 512)
                };
                let updated_at = thread.navigation.as_ref().and_then(|meta| meta.updated_at);
                let mut entry = E::new(
                    C::OpenThread {
                        thread_id: thread.id.clone(),
                    },
                    title,
                    G::Threads,
                )
                .subtitle(bounded(&parts.join(" · "), 1024))
                .icon(IconName::MessagesSquare);
                // The open thread's agent is known; others show the chat glyph
                // until the sidebar's metadata carries each thread's agent.
                if is_current
                    && let Some(provider) = self
                        .selected
                        .as_ref()
                        .and_then(|thread| thread["selection"]["provider"].as_str())
                        .filter(|provider| chat_layout::provider_known(provider))
                {
                    entry.icon = Some(PaletteIcon::Provider(provider.into()));
                }
                entry.trailing = updated_at
                    .map(|date| navigation::sidebar_age(Some(date), now))
                    .filter(|age| !age.is_empty());
                entry.thread = Some(ThreadFacts {
                    branch: bounded(&branch, 512),
                    project: bounded(&project, 512),
                    updated_at: updated_at.unwrap_or(f64::MIN / 2.0),
                });
                entry.secondary = is_current;
                entry
            })
            .collect()
    }
    pub(super) fn palette_snapshot(&self) -> command_palette::PaletteSnapshot {
        let (entries, menus) = self.palette_catalog();
        command_palette::PaletteSnapshot {
            revision: self.palette_revision,
            entries,
            menus,
            branch_prefix: self.palette_branch_prefix(),
            now: coincide_core::store::swift_timestamp(),
        }
    }
    pub(super) fn palette_colors(&self) -> command_palette::PaletteColors {
        let hex = |color: Rgba| {
            let channel = |value: f32| (value.clamp(0., 1.) * 255.).round() as u32;
            channel(color.r) << 16 | channel(color.g) << 8 | channel(color.b)
        };
        command_palette::PaletteColors {
            surface: hex(self.color(0x181d28)),
            selection: hex(self.color(0x2b3549)),
            border: hex(self.color(0x29303d)),
            ink: hex(self.color(0xe4e9f2)),
        }
    }
    /// Admission queues only the newest request; cancellation keeps the old worker owned.
    pub(super) fn run_palette_search(&mut self, request: SearchRequest, _: &mut Context<Self>) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        self.palette_search.submit(request);
    }
    pub(super) fn poll_palette_search(&mut self, cx: &mut Context<Self>) {
        if let Some((generation, lists)) = self.palette_search.poll(|request, control| {
            palette_search_lists(&request.kind, &request.query, &home(), control)
        }) {
            let _ = self
                .command_palette
                .update(cx, |palette, cx| palette.set_results(generation, lists, cx));
        }
    }
    /// The folder a palette file belongs to, when it is still the open
    /// thread's and the file stays inside it.
    pub(super) fn palette_file(&self, root: &str, path: &str) -> Option<PathBuf> {
        let current = self.open_folder()?;
        if current != Path::new(root) || path.is_empty() {
            return None;
        }
        let relative = Path::new(path);
        if relative.is_absolute()
            || relative
                .components()
                .any(|part| !matches!(part, std::path::Component::Normal(_)))
        {
            return None;
        }
        Some(current.join(relative))
    }
    pub(super) fn run_palette_action(
        &mut self,
        id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some((_, _, _, section, _)) = SETTINGS.iter().find(|setting| setting.0 == id) {
            self.open_settings_panel(window, cx);
            self.navigate_settings_section(*section, window, cx);
            return;
        }
        match id {
            "thread:find" => self.open_find(window, cx),
            "thread:rename" => self.begin_rename(window, cx),
            "thread:pin" => self.toggle("isPinned", cx),
            "thread:archive" => self.request_archive(window, cx),
            "action:pull-requests" => self.run_app_action(AppAction::PullRequests, window, cx),
            "action:edit-instructions" => {
                self.run_app_action(AppAction::EditInstructions, window, cx)
            }
            "action:new-bot" => self.run_app_action(AppAction::NewBot, window, cx),
            "thread:stop" => {
                if let Some(id) = self.selected_id()
                    && let Err(error) = call(&self.engine, "agent.stop", json!({"threadId":id}))
                {
                    self.status = error.to_string();
                }
            }
            _ => {}
        }
    }
}

/// A search's lists, as Swift's `ProjectSearch` and folder browsing show them.
fn palette_search_lists(
    kind: &SearchKind,
    query: &str,
    home: &Path,
    control: &project_search::SearchControl,
) -> Vec<PaletteList> {
    match kind {
        SearchKind::Folders => {
            let entries = project_search::folders_controlled(query, home, control)
                .into_iter()
                .filter_map(|hit| {
                    let path = hit.path.to_str()?.to_owned();
                    let mut entry = E::new(
                        C::AddProject { path },
                        bounded(&hit.title, 512),
                        G::Projects,
                    )
                    .subtitle(bounded(&hit.subtitle, 1024))
                    .icon(IconName::FolderPlus);
                    entry.completion = Some(hit.completion);
                    Some(entry)
                })
                .collect::<Vec<_>>();
            if entries.is_empty() {
                Vec::new()
            } else {
                vec![PaletteList {
                    title: "Folders".into(),
                    entries,
                }]
            }
        }
        SearchKind::Files { root } => {
            let files = project_search::files_controlled(Path::new(root), query, control)
                .unwrap_or_default();
            vec![PaletteList {
                title: "Files".into(),
                entries: files
                    .into_iter()
                    .map(|file| {
                        E::new(
                            C::OpenFile {
                                root: root.clone(),
                                path: file.path,
                                line: None,
                            },
                            bounded(&file.name, 512),
                            G::Actions,
                        )
                        .subtitle(bounded(&file.parent, 1024))
                        .icon(IconName::FileText)
                    })
                    .collect(),
            }]
        }
        SearchKind::Text { root } => {
            let matches = project_search::text_controlled(Path::new(root), query, control)
                .unwrap_or_default();
            project_search::group_by_file(matches)
                .into_iter()
                .map(|(path, lines)| PaletteList {
                    title: bounded(&path, 512),
                    entries: lines
                        .into_iter()
                        .filter(|found| !found.text.trim().is_empty())
                        .map(|found| {
                            E::new(
                                C::OpenFile {
                                    root: root.clone(),
                                    path: found.path.clone(),
                                    line: Some(found.line),
                                },
                                bounded(&found.text, 512),
                                G::Actions,
                            )
                            .subtitle(bounded(&format!("{}:{}", found.path, found.line), 1024))
                            .icon(IconName::TextSearch)
                        })
                        .collect(),
                })
                .collect()
        }
    }
}
