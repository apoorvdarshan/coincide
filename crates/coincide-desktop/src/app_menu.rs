//! The native menu bar (Swift's MainMenu) and coalesced app commands. Global
//! handlers only queue requests for the parent's ordinary tick; they never
//! change an Engine, Store, draft, focus, window or retained shutdown driver.
use crate::keyboard_settings::Command;
use gpui_kit::{
    App, Global, KeyBinding, KeyBindingContextPredicate, Menu, MenuItem, OsAction, SystemMenuType,
    actions, base::input,
};
use std::{
    rc::Rc,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

actions!(
    coincide_app_menu,
    [Quit, AddSelectionToComposer, UnavailableEdit]
);
/// A rebindable command (Swift's `KeyCommand` menu items).
#[derive(Clone, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_app_menu, no_json)]
pub struct RunCommand(pub Command);
/// A menu item with a fixed shortcut or none.
#[derive(Clone, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_app_menu, no_json)]
pub struct RunApp(pub AppAction);
/// A menu item that cannot run now. AppKit enables items from GPUI action
/// availability, not from `disabled`, so these have no handler anywhere and
/// their key equivalents never fire.
#[derive(Clone, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_app_menu, no_json)]
pub struct Unavailable(Item);
#[derive(Clone, Debug, PartialEq, Eq)]
enum Item {
    Command(Command),
    App(AppAction),
    AddSelection,
}

/// No dispatch path has this key context, so its bindings only give native
/// menu items their key equivalents. Keys still reach the parent's routing.
const DISPLAY_CONTEXT: &str = "CoincideMenuKeyEquivalent";

/// The parent supplies actual focus ownership. This module never guesses from
/// visibility or stale GPUI focus when a terminal/native responder owns input.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum EditContext {
    #[default]
    Unverified,
    StandardResponder,
    Terminal,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AppAction {
    About,
    Settings,
    CheckForUpdates,
    Hide,
    HideOthers,
    ShowAll,
    NewBot,
    NewThreadIn(String),
    ImportSession,
    OpenIn(String),
    EditInstructions,
    CloseWindow,
    Find,
    FindNext,
    FindPrevious,
    BrowserPreview,
    PullRequests,
    FullScreen,
    Schedule,
    Minimize,
    Zoom,
    BringAllToFront,
    Link(&'static str),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MenuRequest {
    Command(Command),
    App(AppAction),
}
/// Help & Community, as Swift's Help menu lists `CommunityLink.offered(on: .mac)`:
/// help and reports, then the developer's accounts, then contact and legal.
pub const HELP_LINKS: [&[(&str, &str, Option<Command>)]; 3] = [
    &[
        (
            "Get Help on Discord",
            "https://discord.com/channels/1566352780862427258/1566353949336797275",
            None,
        ),
        (
            "Report an Issue…",
            "https://github.com/apoorvdarshan/coincide/issues/new?template=bug_report.yml",
            Some(Command::ReportIssue),
        ),
        (
            "Request a Feature…",
            "https://github.com/apoorvdarshan/coincide/issues/new?template=feature_request.yml",
            Some(Command::RequestFeature),
        ),
        ("Join the Discord", "https://discord.gg/DETrbhDVqw", None),
        (
            "Star on GitHub",
            "https://github.com/apoorvdarshan/coincide",
            None,
        ),
        (
            "Upvote Coincide on Product Hunt",
            "https://www.producthunt.com/products/coincide",
            None,
        ),
        (
            "Support Coincide on Ko-fi",
            "https://ko-fi.com/apoorvdarshan",
            None,
        ),
    ],
    &[
        ("X: @apoorvdarshan", "https://x.com/apoorvdarshan", None),
        (
            "Instagram: @apoorvcodes",
            "https://instagram.com/apoorvcodes",
            None,
        ),
        (
            "LinkedIn",
            "https://www.linkedin.com/showcase/coincide-dev",
            None,
        ),
    ],
    &[
        (
            "Contact: apoorv@fud-ai.app",
            "mailto:apoorv@fud-ai.app",
            None,
        ),
        ("Privacy Policy", "https://coincide.dev/privacy", None),
        ("Terms of Service", "https://coincide.dev/terms", None),
    ],
];
/// Everything the menu bar shows, so it is rebuilt only when this changes.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MenuSnapshot {
    pub context: EditContext,
    pub selection_available: bool,
    /// Native key equivalents as GPUI keystroke text, for commands that run.
    pub keys: Vec<(Command, String)>,
    /// Add Selection to Composer's shortcut, which a focused TextView needs.
    pub add_selection_key: Option<String>,
    /// Fixed items keep their key equivalents unless a native page owns keys.
    pub fixed_keys: bool,
    pub enabled: Vec<Command>,
    pub sidebar: bool,
    pub terminal: bool,
    pub diff: bool,
    pub schedules: bool,
    pub browser: bool,
    pub pull_requests: bool,
    pub pinned: bool,
    pub archived: bool,
    pub thread: bool,
    pub find: bool,
    pub settings_window: bool,
    pub projects: Vec<(String, String)>,
    pub open_targets: Vec<(String, String)>,
}
#[derive(Clone, Default)]
struct Pending(Arc<Mutex<Vec<MenuRequest>>>);
impl Pending {
    fn request(&self, request: MenuRequest) {
        if let Ok(mut queue) = self.0.lock()
            && !queue.contains(&request)
        {
            queue.push(request);
        }
    }
    fn take(&self) -> Vec<MenuRequest> {
        self.0
            .lock()
            .map(|mut queue| std::mem::take(&mut *queue))
            .unwrap_or_default()
    }
}
struct MenuState {
    pending: Pending,
    shown: Option<MenuSnapshot>,
}
impl Global for MenuState {}

// AppKit revalidates native responder selectors when opening a menu and can
// re-enable a disabled Copy item. An unavailable action has neither an OS
// selector nor a registered GPUI handler, so validation stays fail-closed.
fn edit_item(
    context: EditContext,
    name: &str,
    action: impl gpui_kit::Action,
    os: OsAction,
) -> MenuItem {
    if context == EditContext::StandardResponder {
        MenuItem::os_action(name, action, os)
    } else {
        MenuItem::action(name, UnavailableEdit).disabled(true)
    }
}
fn command(s: &MenuSnapshot, title: &str, command: Command) -> MenuItem {
    if s.enabled.contains(&command) {
        MenuItem::action(title.to_owned(), RunCommand(command))
    } else {
        MenuItem::action(title.to_owned(), Unavailable(Item::Command(command))).disabled(true)
    }
}
fn app(title: &str, action: AppAction, enabled: bool) -> MenuItem {
    if enabled {
        MenuItem::action(title.to_owned(), RunApp(action))
    } else {
        MenuItem::action(title.to_owned(), Unavailable(Item::App(action))).disabled(true)
    }
}
fn shown(open: bool, show: &str, hide: &str) -> String {
    if open { hide } else { show }.to_owned()
}
fn menus(s: &MenuSnapshot) -> Vec<Menu> {
    let mut application = vec![
        app("About Coincide Rust", AppAction::About, true),
        MenuItem::separator(),
        app("Settings…", AppAction::Settings, true),
        app("Check for Updates…", AppAction::CheckForUpdates, true),
        MenuItem::separator(),
    ];
    if cfg!(target_os = "macos") {
        application.extend([
            MenuItem::os_submenu("Services", SystemMenuType::Services),
            MenuItem::separator(),
            app("Hide Coincide Rust", AppAction::Hide, true),
            app("Hide Others", AppAction::HideOthers, true),
            app("Show All", AppAction::ShowAll, true),
            MenuItem::separator(),
        ]);
    }
    application.push(MenuItem::action("Quit Coincide Rust", Quit));

    let mut new_in: Vec<_> = s
        .projects
        .iter()
        .map(|(id, name)| app(name, AppAction::NewThreadIn(id.clone()), true))
        .collect();
    if new_in.is_empty() {
        new_in.push(app(
            "No Projects",
            AppAction::NewThreadIn(String::new()),
            false,
        ));
    }
    let open_in: Vec<_> = s
        .open_targets
        .iter()
        .map(|(id, name)| app(name, AppAction::OpenIn(id.clone()), s.thread))
        .collect();
    let file = vec![
        command(s, "New Thread", Command::NewThread),
        command(s, "New Chat", Command::NewChat),
        app("New Bot…", AppAction::NewBot, true),
        MenuItem::submenu(Menu::new("New Thread in Project").items(new_in)),
        command(s, "Add Project…", Command::AddProject),
        app("Import CLI Session…", AppAction::ImportSession, true),
        MenuItem::separator(),
        command(s, "Open in Editor", Command::OpenInEditor),
        MenuItem::submenu(
            Menu::new("Open In")
                .items(open_in)
                .disabled(s.open_targets.is_empty() || !s.thread),
        ),
        command(s, Command::RevealInFinder.title(), Command::RevealInFinder),
        MenuItem::separator(),
        app("Edit Instructions…", AppAction::EditInstructions, true),
        MenuItem::separator(),
        app("Close Window", AppAction::CloseWindow, s.settings_window),
    ];
    let find_enabled = s.find && s.context != EditContext::Terminal;
    let edit = vec![
        edit_item(s.context, "Undo", input::Undo, OsAction::Undo),
        edit_item(s.context, "Redo", input::Redo, OsAction::Redo),
        MenuItem::separator(),
        edit_item(s.context, "Cut", input::Cut, OsAction::Cut),
        edit_item(s.context, "Copy", input::Copy, OsAction::Copy),
        edit_item(s.context, "Paste", input::Paste, OsAction::Paste),
        edit_item(
            s.context,
            "Select All",
            input::SelectAll,
            OsAction::SelectAll,
        ),
        MenuItem::separator(),
        // Quotes a reply or takes terminal output, whichever has focus.
        if s.selection_available {
            MenuItem::action("Add Selection to Composer", AddSelectionToComposer)
        } else {
            MenuItem::action("Add Selection to Composer", Unavailable(Item::AddSelection))
                .disabled(true)
        },
        MenuItem::separator(),
        MenuItem::submenu(Menu::new("Find").items([
            app("Find…", AppAction::Find, find_enabled),
            app("Find Next", AppAction::FindNext, find_enabled),
            app("Find Previous", AppAction::FindPrevious, find_enabled),
            MenuItem::separator(),
            command(s, "Search Threads", Command::SearchThreads),
        ])),
    ];
    let mut view = vec![
        command(
            s,
            &shown(s.sidebar, "Show Sidebar", "Hide Sidebar"),
            Command::Sidebar,
        ),
        command(
            s,
            &shown(s.terminal, "Show Terminal", "Hide Terminal"),
            Command::Terminal,
        ),
        command(s, &shown(s.diff, "Show Diff", "Hide Diff"), Command::Diff),
        command(
            s,
            &shown(s.schedules, "Show Scheduled Tasks", "Hide Scheduled Tasks"),
            Command::Schedules,
        ),
        app(
            &shown(s.browser, "Show Browser Preview", "Hide Browser Preview"),
            AppAction::BrowserPreview,
            s.thread,
        ),
        app(
            &shown(s.pull_requests, "Show Pull Requests", "Hide Pull Requests"),
            AppAction::PullRequests,
            s.thread,
        ),
        command(s, "Archived Threads…", Command::ShowArchive),
        MenuItem::separator(),
        command(s, "Command Palette…", Command::Palette),
        MenuItem::separator(),
        command(s, "Increase Font Size", Command::Larger),
        command(s, "Decrease Font Size", Command::Smaller),
        command(s, "Reset Font Size", Command::FontReset),
    ];
    if cfg!(target_os = "macos") {
        view.extend([
            MenuItem::separator(),
            app("Enter Full Screen", AppAction::FullScreen, true),
        ]);
    }
    let thread = vec![
        command(s, "Stop", Command::Stop),
        MenuItem::separator(),
        command(s, "Previous Thread", Command::PreviousThread),
        command(s, "Next Thread", Command::NextThread),
        MenuItem::separator(),
        command(s, "Choose Agent and Model…", Command::ChooseModel),
        command(s, "Reasoning Effort…", Command::ReasoningEffort),
        command(s, "Access…", Command::AccessMode),
        command(s, "Plan Mode", Command::PlanMode),
        MenuItem::separator(),
        command(s, "Rename…", Command::Rename),
        command(
            s,
            &shown(s.pinned, "Pin Thread", "Unpin Thread"),
            Command::Pin,
        ),
        command(
            s,
            &shown(s.archived, "Archive Thread", "Unarchive Thread"),
            Command::Archive,
        ),
        command(s, "Copy Path", Command::CopyPath),
        app("Schedule…", AppAction::Schedule, s.thread),
        MenuItem::separator(),
        command(s, "Delete Thread…", Command::Delete),
    ];
    let window = vec![
        app("Minimize", AppAction::Minimize, true),
        app("Zoom", AppAction::Zoom, true),
        MenuItem::separator(),
        app("Bring All to Front", AppAction::BringAllToFront, true),
    ];
    let mut help = Vec::new();
    for group in HELP_LINKS {
        if !help.is_empty() {
            help.push(MenuItem::separator());
        }
        for (title, url, bound) in group {
            help.push(match bound {
                Some(bound) => command(s, title, *bound),
                None => app(title, AppAction::Link(url), true),
            });
        }
    }
    vec![
        Menu::new("Coincide Rust").items(application),
        Menu::new("File").items(file),
        Menu::new("Edit").items(edit),
        Menu::new("View").items(view),
        Menu::new("Thread").items(thread),
        Menu::new("Window").items(window),
        Menu::new("Help").items(help),
    ]
}
/// Key equivalents shown beside fixed menu items.
fn fixed_bindings(s: &MenuSnapshot) -> Vec<(&'static str, AppAction)> {
    if !cfg!(target_os = "macos") || !s.fixed_keys {
        return vec![];
    }
    vec![
        ("cmd-,", AppAction::Settings),
        ("shift-cmd-w", AppAction::CloseWindow),
        ("cmd-f", AppAction::Find),
        ("cmd-g", AppAction::FindNext),
        ("shift-cmd-g", AppAction::FindPrevious),
        ("ctrl-cmd-f", AppAction::FullScreen),
        ("cmd-m", AppAction::Minimize),
        ("cmd-h", AppAction::Hide),
        ("alt-cmd-h", AppAction::HideOthers),
    ]
}
/// Replace this module's display bindings and the shared Add Selection key,
/// keeping every other binding in its original order.
fn rebind(s: &MenuSnapshot, cx: &mut App) {
    let display = Rc::new(KeyBindingContextPredicate::parse(DISPLAY_CONTEXT).unwrap());
    let text_view = Rc::new(KeyBindingContextPredicate::parse("TextView").unwrap());
    let mut added = Vec::new();
    // A focused read-only TextView consumes keys before the app capture
    // handler sees them, so this binding also dispatches there. Its menu item
    // shows the same key.
    let mut display_keys: Vec<(String, Box<dyn gpui_kit::Action>, Item)> = Vec::new();
    if let Some(keys) = &s.add_selection_key {
        if let Ok(binding) = KeyBinding::load(
            keys,
            Box::new(AddSelectionToComposer),
            Some(text_view),
            false,
            None,
            cx,
        ) {
            added.push(binding);
        }
        display_keys.push((
            keys.clone(),
            Box::new(AddSelectionToComposer),
            Item::AddSelection,
        ));
    }
    if cfg!(target_os = "macos") {
        for (bound, keys) in &s.keys {
            display_keys.push((
                keys.clone(),
                Box::new(RunCommand(*bound)),
                Item::Command(*bound),
            ));
        }
        for (keys, action) in fixed_bindings(s) {
            display_keys.push((
                keys.into(),
                Box::new(RunApp(action.clone())),
                Item::App(action),
            ));
        }
    }
    // An unavailable item shows the same key equivalent, greyed out.
    for (keys, action, item) in display_keys {
        for action in [
            action,
            Box::new(Unavailable(item)) as Box<dyn gpui_kit::Action>,
        ] {
            if action.as_any().is::<AddSelectionToComposer>() {
                continue;
            }
            if let Ok(binding) =
                KeyBinding::load(&keys, action, Some(display.clone()), false, None, cx)
            {
                added.push(binding);
            }
        }
    }
    let keymap = cx.key_bindings();
    let mut keymap = keymap.borrow_mut();
    let kept: Vec<KeyBinding> = keymap
        .bindings()
        .filter(|binding| {
            let action = binding.action().as_any();
            !action.is::<RunCommand>()
                && !action.is::<RunApp>()
                && !action.is::<Unavailable>()
                && !action.is::<AddSelectionToComposer>()
        })
        .cloned()
        .collect();
    keymap.clear();
    keymap.add_bindings(kept.into_iter().chain(added));
}
/// Coalesced Quit admission signal, unchanged. Other menu requests are also
/// retained in App Global until the parent's ordinary tick consumes them.
pub fn install(cx: &mut App) -> Arc<AtomicBool> {
    let requested = Arc::new(AtomicBool::new(false));
    let signal = requested.clone();
    cx.on_action(move |_: &Quit, cx| {
        crate::quit_shortcut::cancel(cx);
        signal.store(true, Ordering::Release);
    });
    let pending = Pending::default();
    let signal = pending.clone();
    cx.on_action(move |action: &RunCommand, _| signal.request(MenuRequest::Command(action.0)));
    let signal = pending.clone();
    cx.on_action(move |action: &RunApp, _| signal.request(MenuRequest::App(action.0.clone())));
    #[cfg(target_os = "macos")]
    cx.bind_keys([KeyBinding::new("cmd-q", Quit, None)]);
    #[cfg(not(target_os = "macos"))]
    cx.bind_keys([KeyBinding::new("ctrl-q", Quit, None)]);
    cx.set_global(MenuState {
        pending,
        shown: None,
    });
    update(cx, MenuSnapshot::default());
    crate::quit_shortcut::install(requested.clone(), cx);
    requested
}
/// Parent calls outside any Engine guard; consumption itself has no effects.
/// Duplicate requests coalesce, and Quit remains its separate retained signal.
pub fn take_requests(cx: &mut App) -> Vec<MenuRequest> {
    if !cx.has_global::<MenuState>() {
        return Vec::new();
    }
    cx.global::<MenuState>().pending.take()
}
/// Rebuild only when what the menu bar shows changes. Terminal Edit stays
/// disabled until its own narrow action listeners are separately wired.
pub fn update(cx: &mut App, snapshot: MenuSnapshot) {
    if !cx.has_global::<MenuState>() {
        return;
    }
    let state = cx.global::<MenuState>();
    if state.shown.as_ref() == Some(&snapshot) {
        return;
    }
    let keys_changed = state.shown.as_ref().is_none_or(|shown| {
        shown.keys != snapshot.keys
            || shown.fixed_keys != snapshot.fixed_keys
            || shown.add_selection_key != snapshot.add_selection_key
    });
    if keys_changed {
        rebind(&snapshot, cx);
    }
    cx.set_menus(menus(&snapshot));
    cx.global_mut::<MenuState>().shown = Some(snapshot);
}

#[cfg(test)]
mod tests {
    use super::*;
    fn snapshot() -> MenuSnapshot {
        MenuSnapshot {
            context: EditContext::StandardResponder,
            selection_available: true,
            enabled: Command::ALL.to_vec(),
            thread: true,
            find: true,
            ..Default::default()
        }
    }
    fn items<'a>(menus: &'a [Menu], name: &str) -> &'a [MenuItem] {
        &menus.iter().find(|m| m.name == name).unwrap().items
    }
    fn titles(items: &[MenuItem]) -> Vec<String> {
        items
            .iter()
            .map(|item| match item {
                MenuItem::Action { name, .. } => name.to_string(),
                MenuItem::Submenu(menu) => format!("{} ▸", menu.name),
                MenuItem::SystemMenu(menu) => format!("{} ▸", menu.name),
                MenuItem::Separator => "-".into(),
            })
            .collect()
    }
    #[::core::prelude::v1::test]
    fn native_selector_menu_uses_real_focused_input_actions_and_omits_unsafe_fallbacks() {
        let menu = menus(&snapshot());
        let mut count = 0;
        for item in items(&menu, "Edit") {
            let MenuItem::Action {
                name,
                action,
                os_action,
                disabled,
                ..
            } = item
            else {
                continue;
            };
            assert!(!*disabled);
            match name.as_ref() {
                "Undo" => assert!(matches!(os_action, Some(OsAction::Undo))),
                "Redo" => assert!(matches!(os_action, Some(OsAction::Redo))),
                "Cut" => {
                    assert!(action.as_any().is::<input::Cut>());
                    assert!(matches!(os_action, Some(OsAction::Cut)));
                }
                "Copy" => {
                    assert!(action.as_any().is::<input::Copy>());
                    assert!(matches!(os_action, Some(OsAction::Copy)));
                }
                "Paste" => {
                    assert!(action.as_any().is::<input::Paste>());
                    assert!(matches!(os_action, Some(OsAction::Paste)));
                }
                "Select All" => {
                    assert!(action.as_any().is::<input::SelectAll>());
                    assert!(matches!(os_action, Some(OsAction::SelectAll)));
                }
                "Add Selection to Composer" => {
                    assert!(action.as_any().is::<AddSelectionToComposer>());
                    assert!(os_action.is_none());
                }
                other => panic!("Unsupported Edit menu action: {other}"),
            }
            count += 1;
        }
        assert_eq!(count, 7);
    }
    #[::core::prelude::v1::test]
    fn unverified_or_terminal_focus_never_enables_stale_composer_edits() {
        for context in [EditContext::Unverified, EditContext::Terminal] {
            let mut state = snapshot();
            state.context = context;
            state.selection_available = false;
            let menu = menus(&state);
            for item in items(&menu, "Edit") {
                if let MenuItem::Action {
                    disabled,
                    action,
                    os_action,
                    ..
                } = item
                {
                    assert!(*disabled);
                    assert!(
                        os_action.is_none(),
                        "native validation must not restore a terminal selector"
                    );
                    if action.as_any().is::<Unavailable>() {
                        continue;
                    }
                    assert!(action.as_any().is::<UnavailableEdit>());
                }
            }
            // A focused terminal keeps its own find keys.
            let MenuItem::Submenu(find) = items(&menu, "Edit").last().unwrap() else {
                panic!("Find submenu")
            };
            assert_eq!(
                find.items[0].is_disabled(),
                context == EditContext::Terminal
            );
        }
    }
    #[::core::prelude::v1::test]
    fn menus_follow_swift_order_titles_and_state() {
        let mut state = snapshot();
        state.projects = vec![("p1".into(), "Coincide".into())];
        let menu = menus(&state);
        assert_eq!(
            menu.iter().map(|m| m.name.to_string()).collect::<Vec<_>>(),
            [
                "Coincide Rust",
                "File",
                "Edit",
                "View",
                "Thread",
                "Window",
                "Help"
            ]
        );
        assert_eq!(
            titles(items(&menu, "File")),
            [
                "New Thread",
                "New Chat",
                "New Bot…",
                "New Thread in Project ▸",
                "Add Project…",
                "Import CLI Session…",
                "-",
                "Open in Editor",
                "Open In ▸",
                crate::keyboard_settings::REVEAL_TITLE,
                "-",
                "Edit Instructions…",
                "-",
                "Close Window",
            ]
        );
        assert_eq!(
            titles(items(&menu, "Thread")),
            [
                "Stop",
                "-",
                "Previous Thread",
                "Next Thread",
                "-",
                "Choose Agent and Model…",
                "Reasoning Effort…",
                "Access…",
                "Plan Mode",
                "-",
                "Rename…",
                "Pin Thread",
                "Archive Thread",
                "Copy Path",
                "Schedule…",
                "-",
                "Delete Thread…",
            ]
        );
        assert_eq!(titles(items(&menu, "View"))[0], "Show Sidebar");
        state.sidebar = true;
        state.terminal = true;
        state.pinned = true;
        state.archived = true;
        state.enabled.retain(|command| *command != Command::Stop);
        let menu = menus(&state);
        let view = titles(items(&menu, "View"));
        assert_eq!(&view[..2], ["Hide Sidebar", "Hide Terminal"]);
        let thread = items(&menu, "Thread");
        assert!(thread[0].is_disabled());
        assert_eq!(titles(thread)[11..13], ["Unpin Thread", "Unarchive Thread"]);
        let help = titles(items(&menu, "Help"));
        assert_eq!(help[0], "Get Help on Discord");
        assert_eq!(help.last().unwrap(), "Terms of Service");
        assert_eq!(help.iter().filter(|title| *title == "-").count(), 2);
    }
    #[::core::prelude::v1::test]
    fn menu_requests_coalesce_and_drain_once() {
        let pending = Pending::default();
        let producer = pending.clone();
        producer.request(MenuRequest::App(AppAction::Settings));
        producer.request(MenuRequest::App(AppAction::Settings));
        producer.request(MenuRequest::Command(Command::NewThread));
        assert_eq!(
            pending.take(),
            vec![
                MenuRequest::App(AppAction::Settings),
                MenuRequest::Command(Command::NewThread)
            ]
        );
        assert!(pending.take().is_empty());
        producer.request(MenuRequest::App(AppAction::Hide));
        producer.request(MenuRequest::App(AppAction::HideOthers));
        producer.request(MenuRequest::App(AppAction::ShowAll));
        assert_eq!(
            pending.take(),
            vec![
                MenuRequest::App(AppAction::Hide),
                MenuRequest::App(AppAction::HideOthers),
                MenuRequest::App(AppAction::ShowAll)
            ]
        );
    }
}
