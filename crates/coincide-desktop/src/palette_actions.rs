//! Swift's PaletteCatalog: actions, recent threads, projects, Settings sections
//! and Help & Community. Actions run the same commands as the menu bar, and
//! rows show the menu shortcut the user gave them.
use super::*;
use command_palette::{PaletteCommand as C, PaletteEntry as E};
use keyboard_settings::Command as K;
use settings::SettingsSection as S;

/// Recent threads listed between the core actions and the rest, as Swift.
const RECENT_THREADS: usize = 12;
const SETTINGS: [(&str, &str, S, &[&str]); 7] = [
    (
        "setting:general",
        "General Settings",
        S::General,
        &["appearance", "notifications", "font", "confirm"],
    ),
    (
        "setting:providers",
        "Agent Settings",
        S::Accounts,
        &["providers", "claude", "codex", "cursor", "cli", "login"],
    ),
    (
        "setting:models",
        "Model Settings",
        S::Models,
        &["models", "effort", "custom", "default"],
    ),
    (
        "setting:instructions",
        "Global Instructions",
        S::Instructions,
        &["agents.md", "claude.md", "rules", "memory"],
    ),
    (
        "setting:keyboard",
        "Keyboard Shortcuts",
        S::Keyboard,
        &["shortcuts", "keybindings", "keys"],
    ),
    (
        "setting:voice",
        "Voice Settings",
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
        S::About,
        &["version", "license", "credits"],
    ),
];
fn row(command: C, title: impl Into<String>, keywords: &[&str], trailing: Option<String>) -> E {
    E {
        command,
        title: title.into(),
        subtitle: None,
        keywords: keywords.iter().map(|word| (*word).into()).collect(),
        trailing,
        enabled: true,
        disabled_reason: None,
    }
}
fn action(id: &str, title: impl Into<String>, keywords: &[&str], trailing: Option<String>) -> E {
    row(C::Action { id: id.into() }, title, keywords, trailing)
}
fn toggle(open: bool, show: &str, hide: &str) -> String {
    if open { hide } else { show }.into()
}

impl Coincide {
    fn keys(&self, command: K) -> Option<String> {
        keyboard_settings::menu_shortcut_label(&self.settings, command)
    }
    fn current_project(&self) -> Option<Value> {
        let id = self.selected_project.clone().or_else(|| {
            self.selected
                .as_ref()
                .map(|thread| text(thread, "projectID"))
        })?;
        self.projects
            .iter()
            .find(|project| {
                project["id"] == id.as_str()
                    && project["isChats"] != true
                    && project["isBots"] != true
                    && id != navigation::NO_PROJECT_ID
                    && !id.eq_ignore_ascii_case(coincide_core::bot_runtime::BOTS_PROJECT_ID)
            })
            .cloned()
    }
    pub(super) fn palette_catalog(&self) -> Vec<E> {
        let thread = self.selected.is_some();
        let current = self.current_project().map(|project| text(&project, "id"));
        let mut core = Vec::new();
        if let Some(project) = self.current_project() {
            core.push(row(
                C::NewThread {
                    project_id: Some(text(&project, "id")),
                },
                format!("New Thread in {}", text(&project, "name")),
                &["new thread", "chat", "create", "draft"],
                self.keys(K::NewThread),
            ));
        }
        core.push(row(
            C::NewThread { project_id: None },
            "New Chat",
            &[
                "new chat",
                "chat",
                "no project",
                "without project",
                "conversation",
            ],
            self.keys(K::NewChat),
        ));
        core.push(action(
            "action:new-bot",
            "New Bot…",
            &["new bot", "bot", "assistant", "persona", "create"],
            None,
        ));
        for bot in &self.sidebar_bots {
            let id = text(bot, "id");
            if id.is_empty() {
                continue;
            }
            let name = bot["name"]
                .as_str()
                .filter(|name| !name.is_empty())
                .unwrap_or("Bot")
                .to_owned();
            let mut entry = action(
                &format!("bot:{id}"),
                format!("Talk to {name}"),
                &["bot"],
                None,
            );
            entry.subtitle = Some("Bot".into());
            entry.keywords.push(name.chars().take(128).collect());
            core.push(entry);
        }
        for project in &self.projects {
            let id = text(project, "id");
            if id.is_empty()
                || current.as_deref() == Some(id.as_str())
                || id.eq_ignore_ascii_case(coincide_core::bot_runtime::BOTS_PROJECT_ID)
            {
                continue;
            }
            let mut entry = row(
                C::NewThread {
                    project_id: Some(id),
                },
                format!("New Thread in {}", text(project, "name")),
                &["new thread", "project", "pick", "choose", "select"],
                None,
            );
            entry.subtitle = Some("Project".into());
            core.push(entry);
        }
        core.push(action(
            "action:add-project",
            "Add Project…",
            &[
                "add project",
                "open folder",
                "folder",
                "repository",
                "workspace",
            ],
            self.keys(K::AddProject),
        ));
        if let Some(target) = open_targets::preferred(&self.open_targets, &self.settings)
            && self.open_folder().is_some()
        {
            core.push(action(
                "action:open-in",
                format!("Open in {}", target.name),
                &["open", "editor", "finder", "terminal", "reveal"],
                self.keys(K::OpenInEditor),
            ));
        }
        core.push(row(
            C::ShowSchedules,
            toggle(
                self.schedules_open,
                "Show Scheduled Tasks",
                "Hide Scheduled Tasks",
            ),
            &[
                "schedule",
                "scheduled",
                "tasks",
                "automation",
                "cron",
                "recurring",
                "daily",
                "weekly",
                "reminder",
            ],
            self.keys(K::Schedules),
        ));
        if thread {
            core.push(action(
                "action:schedule-in-thread",
                "Schedule a Message in This Thread…",
                &[
                    "schedule",
                    "later",
                    "remind",
                    "recurring",
                    "every",
                    "cron",
                    "timer",
                ],
                None,
            ));
        }
        core.push(action(
            "action:edit-instructions",
            "Edit Instructions",
            &[
                "instructions",
                "agents.md",
                "claude.md",
                "gemini.md",
                "rules",
                "memory",
                "prompt",
            ],
            None,
        ));
        if thread {
            core.extend([
                action(
                    "action:terminal",
                    toggle(
                        self.terminal_visible_thread.is_some(),
                        "Show Terminal",
                        "Hide Terminal",
                    ),
                    &["terminal", "shell", "console", "toggle"],
                    self.keys(K::Terminal),
                ),
                action(
                    "action:diff",
                    toggle(self.diff_open(), "Show Diff", "Hide Diff"),
                    &["diff", "changes", "review", "git", "toggle"],
                    self.keys(K::Diff),
                ),
                action(
                    "action:pull-requests",
                    toggle(
                        self.pull_requests_open(),
                        "Show Pull Requests",
                        "Hide Pull Requests",
                    ),
                    &[
                        "pull request",
                        "pr",
                        "github",
                        "review",
                        "checks",
                        "merge",
                        "toggle",
                    ],
                    None,
                ),
                action(
                    "action:preview",
                    toggle(
                        self.browser_panel_open(),
                        "Show Browser Preview",
                        "Hide Browser Preview",
                    ),
                    &["preview", "browser", "web", "localhost"],
                    None,
                ),
            ]);
        }
        if self.selected_running() {
            core.push(action(
                "action:stop",
                "Stop Agent",
                &["stop", "interrupt", "cancel", "abort"],
                self.keys(K::Stop),
            ));
        }
        if thread {
            core.push(action(
                "action:find",
                "Find in Thread…",
                &[
                    "find",
                    "search",
                    "thread",
                    "conversation",
                    "text",
                    "match",
                    "current",
                ],
                Some(if cfg!(target_os = "macos") {
                    "⌘F".into()
                } else {
                    "Ctrl+F".into()
                }),
            ));
        }
        let mut more = Vec::new();
        if let Some(selected) = &self.selected {
            let planning = selected["interactionMode"] == "plan";
            more.extend([
                action(
                    "action:model",
                    "Choose Agent and Model…",
                    &["model", "agent", "provider", "switch", "change", "picker"],
                    self.keys(K::ChooseModel),
                ),
                action(
                    "action:effort",
                    "Choose Reasoning Effort…",
                    &["reasoning", "effort", "thinking", "think", "level"],
                    self.keys(K::ReasoningEffort),
                ),
                action(
                    "action:access",
                    "Choose Access…",
                    &[
                        "access",
                        "permissions",
                        "approval",
                        "approve",
                        "full access",
                        "ask",
                        "mode",
                    ],
                    self.keys(K::AccessMode),
                ),
                action(
                    "action:interaction-mode",
                    if planning {
                        "Switch to Build Mode"
                    } else {
                        "Switch to Plan Mode"
                    },
                    &["plan", "build", "mode", "toggle"],
                    self.keys(K::PlanMode),
                ),
            ]);
        }
        more.push(action(
            "action:sidebar",
            toggle(self.thread_list_open, "Show Sidebar", "Hide Sidebar"),
            &["sidebar", "projects", "threads", "toggle"],
            self.keys(K::Sidebar),
        ));
        if let Some(selected) = &self.selected {
            more.push(action(
                "action:pin",
                if selected["isPinned"] == true {
                    "Unpin Thread"
                } else {
                    "Pin Thread"
                },
                &["pin", "unpin", "favorite"],
                self.keys(K::Pin),
            ));
            more.push(action(
                "action:rename",
                "Rename Thread…",
                &["rename", "title"],
                self.keys(K::Rename),
            ));
            more.push(action(
                "action:archive",
                if selected["isArchived"] == true {
                    "Unarchive Thread"
                } else {
                    "Archive Thread"
                },
                &["archive", "hide", "done"],
                self.keys(K::Archive),
            ));
        }
        more.push(action(
            "action:appearance",
            "Change Appearance…",
            &["appearance", "theme", "dark", "light", "mode"],
            None,
        ));
        more.push(row(
            C::OpenSettings,
            "Open Settings",
            &["settings", "preferences", "configuration"],
            Some(if cfg!(target_os = "macos") {
                "⌘,".into()
            } else {
                "Ctrl+,".into()
            }),
        ));
        for (index, (title, _, bound)) in app_menu::HELP_LINKS
            .iter()
            .flat_map(|group| group.iter())
            .enumerate()
        {
            let mut entry = action(
                &format!("help:{index}"),
                *title,
                &["help", "community"],
                bound.and_then(|command| self.keys(command)),
            );
            entry.subtitle = Some("Help".into());
            more.push(entry);
        }
        for (id, title, _, keywords) in SETTINGS {
            let mut entry = action(id, title, keywords, None);
            entry.subtitle = Some("Settings".into());
            more.push(entry);
        }
        let mut entries = core;
        let threads = self.threads.iter().map(|thread| {
            row(
                C::OpenThread {
                    thread_id: thread.id.clone(),
                },
                thread.title.clone(),
                &[],
                None,
            )
        });
        let mut threads = threads
            .map(|mut entry| {
                entry.subtitle = Some("Conversation".into());
                entry
            })
            .collect::<Vec<_>>();
        let rest = threads.split_off(threads.len().min(RECENT_THREADS));
        entries.extend(threads);
        entries.extend(more);
        entries.push(row(
            C::SelectProject { project_id: None },
            "All projects",
            &[],
            None,
        ));
        for project in &self.projects {
            let id = text(project, "id");
            if id.is_empty() {
                continue;
            }
            let mut entry = row(
                C::SelectProject {
                    project_id: Some(id),
                },
                format!("Show project: {}", text(project, "name")),
                &[],
                None,
            );
            if let Some(path) = project["path"].as_str().filter(|path| !path.is_empty()) {
                entry.keywords.push(path.chars().take(128).collect());
            }
            entries.push(entry);
        }
        entries.extend(rest);
        entries
    }
    pub(super) fn run_palette_action(
        &mut self,
        id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        use app_menu::AppAction as A;
        if let Some(bot) = id.strip_prefix("bot:") {
            self.sidebar_open_bot(bot.to_owned(), true, window, cx);
            return;
        }
        if let Some(index) = id
            .strip_prefix("help:")
            .and_then(|index| index.parse::<usize>().ok())
        {
            if let Some((_, url, bound)) = app_menu::HELP_LINKS
                .iter()
                .flat_map(|group| group.iter())
                .nth(index)
            {
                match bound {
                    Some(command) => self.run_keyboard_command(*command, window, cx),
                    None => cx.open_url(url),
                }
            }
            return;
        }
        if let Some((_, _, section, _)) = SETTINGS.iter().find(|setting| setting.0 == id) {
            self.open_settings_panel(window, cx);
            self.navigate_settings_section(*section, window, cx);
            return;
        }
        let command = match id {
            "action:add-project" => K::AddProject,
            "action:open-in" => K::OpenInEditor,
            "action:terminal" => K::Terminal,
            "action:diff" => K::Diff,
            "action:stop" => K::Stop,
            "action:model" => K::ChooseModel,
            "action:effort" => K::ReasoningEffort,
            "action:access" => K::AccessMode,
            "action:interaction-mode" => K::PlanMode,
            "action:sidebar" => K::Sidebar,
            "action:pin" => K::Pin,
            "action:rename" => K::Rename,
            "action:archive" => K::Archive,
            other => {
                let action = match other {
                    "action:new-bot" => A::NewBot,
                    "action:schedule-in-thread" => A::Schedule,
                    "action:edit-instructions" => A::EditInstructions,
                    "action:pull-requests" => A::PullRequests,
                    "action:preview" => A::BrowserPreview,
                    "action:find" => A::Find,
                    "action:appearance" => {
                        self.open_settings_panel(window, cx);
                        self.navigate_settings_section(S::Appearance, window, cx);
                        return;
                    }
                    _ => return,
                };
                self.run_app_action(action, window, cx);
                return;
            }
        };
        self.run_keyboard_command(command, window, cx);
    }
}
