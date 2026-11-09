//! Swift's rebindable menu commands (`KeyCommand`) and their shortcut recorder.
//! Persistence uses Swift's shortcutOverrides IDs/syntax; IDs this version does
//! not know are retained untouched.
use super::*;
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};

const MOD: u8 = 1;
const CTRL: u8 = 2;
const ALT: u8 = 4;
const SHIFT: u8 = 8;

/// The menu bar menu a command is in (Swift's `KeyCommand.Menu`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Menu {
    File,
    Edit,
    View,
    Thread,
    Help,
}
impl Menu {
    pub const ALL: [Self; 5] = [Self::File, Self::Edit, Self::View, Self::Thread, Self::Help];
    pub fn title(self) -> &'static str {
        match self {
            Self::File => "File",
            Self::Edit => "Edit",
            Self::View => "View",
            Self::Thread => "Thread",
            Self::Help => "Help",
        }
    }
}

/// The file manager's own name, as each platform's shell names the command.
pub(super) const REVEAL_TITLE: &str = if cfg!(target_os = "macos") {
    "Reveal in Finder"
} else if cfg!(target_os = "windows") {
    "Show in File Explorer"
} else {
    "Show in Files"
};
const JUMPS: [(&str, &str, &str); 9] = [
    ("thread.jump.1", "Go to Thread 1", "mod+1"),
    ("thread.jump.2", "Go to Thread 2", "mod+2"),
    ("thread.jump.3", "Go to Thread 3", "mod+3"),
    ("thread.jump.4", "Go to Thread 4", "mod+4"),
    ("thread.jump.5", "Go to Thread 5", "mod+5"),
    ("thread.jump.6", "Go to Thread 6", "mod+6"),
    ("thread.jump.7", "Go to Thread 7", "mod+7"),
    ("thread.jump.8", "Go to Thread 8", "mod+8"),
    ("thread.jump.9", "Go to Thread 9", "mod+9"),
];

/// Cases are in Swift's menu-bar order. When commands share a shortcut, a
/// changed one wins over a default one; otherwise the earlier command runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Command {
    NewThread,
    NewChat,
    AddProject,
    OpenInEditor,
    RevealInFinder,
    AddToComposer,
    SearchThreads,
    Sidebar,
    Terminal,
    Diff,
    Schedules,
    Palette,
    Larger,
    Smaller,
    FontReset,
    ShowArchive,
    Stop,
    PreviousThread,
    NextThread,
    /// Go to Thread 1–9, counted from the top of the sidebar.
    Jump(u8),
    ChooseModel,
    ReasoningEffort,
    AccessMode,
    PlanMode,
    Rename,
    Pin,
    Archive,
    CopyPath,
    Delete,
    ReportIssue,
    RequestFeature,
}
impl Command {
    pub const ALL: [Self; 39] = [
        Self::NewThread,
        Self::NewChat,
        Self::AddProject,
        Self::OpenInEditor,
        Self::RevealInFinder,
        Self::AddToComposer,
        Self::SearchThreads,
        Self::Sidebar,
        Self::Terminal,
        Self::Diff,
        Self::Schedules,
        Self::Palette,
        Self::Larger,
        Self::Smaller,
        Self::FontReset,
        Self::ShowArchive,
        Self::Stop,
        Self::PreviousThread,
        Self::NextThread,
        Self::Jump(1),
        Self::Jump(2),
        Self::Jump(3),
        Self::Jump(4),
        Self::Jump(5),
        Self::Jump(6),
        Self::Jump(7),
        Self::Jump(8),
        Self::Jump(9),
        Self::ChooseModel,
        Self::ReasoningEffort,
        Self::AccessMode,
        Self::PlanMode,
        Self::Rename,
        Self::Pin,
        Self::Archive,
        Self::CopyPath,
        Self::Delete,
        Self::ReportIssue,
        Self::RequestFeature,
    ];
    /// Swift's id, title and default (`KeyCommand.defaults`; empty for none).
    fn spec(self) -> (&'static str, &'static str, &'static str) {
        match self {
            Self::NewThread => ("chat.new", "New Thread", "mod+n"),
            Self::NewChat => ("chat.newProjectless", "New Chat", "mod+shift+n"),
            Self::AddProject => ("project.add", "Add Project…", "mod+shift+o"),
            Self::OpenInEditor => ("editor.openFavorite", "Open in Editor", "mod+o"),
            Self::RevealInFinder => ("project.revealInFinder", REVEAL_TITLE, ""),
            Self::AddToComposer => (
                "composer.addSelection",
                "Add Selection to Composer",
                "mod+l",
            ),
            Self::SearchThreads => ("sidebar.search", "Search Threads", "mod+alt+f"),
            Self::Sidebar => ("sidebar.toggle", "Show or Hide Sidebar", "mod+b"),
            Self::Terminal => ("terminal.toggle", "Show or Hide Terminal", "mod+j"),
            Self::Diff => ("diff.toggle", "Show or Hide Diff", "mod+d"),
            Self::Schedules => (
                "schedules.show",
                "Show or Hide Scheduled Tasks",
                "mod+alt+s",
            ),
            Self::Palette => ("commandPalette.toggle", "Command Palette…", "mod+k"),
            Self::Larger => ("view.increaseFontSize", "Increase Font Size", "mod++"),
            Self::Smaller => ("view.decreaseFontSize", "Decrease Font Size", "mod+-"),
            Self::FontReset => ("view.resetFontSize", "Reset Font Size", "mod+0"),
            Self::ShowArchive => ("archive.show", "Archived Threads…", "mod+alt+a"),
            Self::Stop => ("thread.stop", "Stop", "mod+."),
            Self::PreviousThread => ("thread.previous", "Previous Thread", "mod+shift+["),
            Self::NextThread => ("thread.next", "Next Thread", "mod+shift+]"),
            Self::Jump(index) => JUMPS[usize::from(index.clamp(1, 9) - 1)],
            Self::ChooseModel => (
                "modelPicker.toggle",
                "Choose Agent and Model…",
                "mod+shift+m",
            ),
            Self::ReasoningEffort => ("composer.effort", "Reasoning Effort…", "mod+shift+e"),
            Self::AccessMode => ("composer.mode", "Access…", "mod+shift+a"),
            // No default: Shift-Tab toggles it in the composer.
            Self::PlanMode => ("composer.planMode", "Plan Mode", ""),
            Self::Rename => ("thread.rename", "Rename…", "mod+r"),
            Self::Pin => ("thread.pin", "Pin or Unpin Thread", "mod+shift+p"),
            // Command-W puts the open thread in the archive; Close Window is
            // Shift-Command-W, and other windows still close with Command-W.
            Self::Archive => ("thread.archive", "Archive or Unarchive Thread", "mod+w"),
            Self::CopyPath => ("thread.copyPath", "Copy Path", ""),
            Self::Delete => ("thread.delete", "Delete Thread…", ""),
            Self::ReportIssue => ("help.reportIssue", "Report an Issue…", ""),
            Self::RequestFeature => ("help.requestFeature", "Request a Feature…", ""),
        }
    }
    pub fn id(self) -> &'static str {
        self.spec().0
    }
    pub fn title(self) -> &'static str {
        self.spec().1
    }
    fn default_shortcut(self) -> Option<Shortcut> {
        Shortcut::parse(self.spec().2)
    }
    pub fn menu(self) -> Menu {
        match self {
            Self::NewThread
            | Self::NewChat
            | Self::AddProject
            | Self::OpenInEditor
            | Self::RevealInFinder => Menu::File,
            Self::AddToComposer | Self::SearchThreads => Menu::Edit,
            Self::Sidebar
            | Self::Terminal
            | Self::Diff
            | Self::Schedules
            | Self::Palette
            | Self::Larger
            | Self::Smaller
            | Self::FontReset
            | Self::ShowArchive => Menu::View,
            Self::ReportIssue | Self::RequestFeature => Menu::Help,
            _ => Menu::Thread,
        }
    }
    pub fn jump_index(self) -> Option<usize> {
        match self {
            Self::Jump(index) => Some(usize::from(index.clamp(1, 9))),
            _ => None,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Shortcut {
    key: String,
    modifiers: u8,
}
fn normalized_key(raw: &str) -> Option<String> {
    let lower = raw.to_lowercase();
    let key = match lower.as_str() {
        "return" => "enter",
        "escape" => "esc",
        " " => "space",
        "up" => "arrowup",
        "down" => "arrowdown",
        "left" => "arrowleft",
        "right" => "arrowright",
        other => other,
    };
    let named = matches!(
        key,
        "enter"
            | "tab"
            | "space"
            | "esc"
            | "backspace"
            | "delete"
            | "arrowup"
            | "arrowdown"
            | "arrowleft"
            | "arrowright"
            | "home"
            | "end"
            | "pageup"
            | "pagedown"
    );
    let function = key
        .strip_prefix('f')
        .and_then(|n| n.parse::<u8>().ok())
        .is_some_and(|n| (1..=20).contains(&n) && key == format!("f{n}"));
    let character = key.chars().count() == 1
        && key.chars().all(|c| {
            !c.is_control() && !c.is_whitespace() && !('\u{e000}'..='\u{f8ff}').contains(&c)
        });
    (named || function || character).then(|| key.to_owned())
}
/// The unshifted key of a US-layout shifted character. GPUI reports Shift with
/// punctuation as the shifted character, while Swift records the key the
/// layout gives with no modifiers (Shift-Command-[ is `mod+shift+[`).
fn unshifted(key: &str) -> Option<&'static str> {
    Some(match key {
        "{" => "[",
        "}" => "]",
        "+" => "=",
        "_" => "-",
        ":" => ";",
        "\"" => "'",
        "<" => ",",
        ">" => ".",
        "?" => "/",
        "|" => "\\",
        "~" => "`",
        "!" => "1",
        "@" => "2",
        "#" => "3",
        "$" => "4",
        "%" => "5",
        "^" => "6",
        "&" => "7",
        "*" => "8",
        "(" => "9",
        ")" => "0",
        _ => return None,
    })
}
impl Shortcut {
    fn parse(raw: &str) -> Option<Self> {
        if raw.len() > 128 || raw.trim().is_empty() || raw.chars().any(char::is_control) {
            return None;
        }
        let mut parts: Vec<_> = raw.split('+').map(str::trim).collect();
        if parts.last() == Some(&"") {
            while parts.last() == Some(&"") {
                parts.pop();
            }
            parts.push("+");
        }
        let mut modifiers = 0;
        let mut key = None;
        for part in parts {
            match part.to_lowercase().as_str() {
                "mod" | "cmd" | "command" | "meta" => modifiers |= MOD,
                "ctrl" | "control" => modifiers |= CTRL,
                "alt" | "option" => modifiers |= ALT,
                "shift" => modifiers |= SHIFT,
                _ => {
                    if key.is_some() {
                        return None;
                    }
                    key = Some(normalized_key(part)?);
                }
            }
        }
        Some(Self {
            key: key?,
            modifiers,
        })
    }
    fn event(key: &Keystroke) -> Option<Self> {
        if key.modifiers.function || (!cfg!(target_os = "macos") && key.modifiers.platform) {
            return None;
        }
        let modifiers = if cfg!(target_os = "macos") {
            (u8::from(key.modifiers.platform) * MOD) | (u8::from(key.modifiers.control) * CTRL)
        } else {
            u8::from(key.modifiers.control) * MOD
        };
        let mut modifiers = modifiers
            | (u8::from(key.modifiers.alt) * ALT)
            | (u8::from(key.modifiers.shift) * SHIFT);
        let mut key = normalized_key(&key.key)?;
        if let Some(base) = unshifted(&key) {
            key = base.into();
            modifiers |= SHIFT;
        }
        Some(Self { key, modifiers })
    }
    fn physical(&self) -> (String, u8) {
        let mut modifiers = self.modifiers;
        if !cfg!(target_os = "macos") && modifiers & MOD != 0 {
            modifiers = (modifiers & !MOD) | CTRL;
        }
        // The default Swift Command-Plus is typed as Shift-Equals on these
        // native keyboard events. Explicit Shift-Equals resolves identically.
        match unshifted(&self.key) {
            Some(base) => (base.into(), modifiers | SHIFT),
            None => (self.key.clone(), modifiers),
        }
    }
    fn usable(&self) -> bool {
        self.modifiers & (MOD | CTRL) != 0
            || self
                .key
                .strip_prefix('f')
                .and_then(|v| v.parse::<u8>().ok())
                .is_some_and(|v| (1..=20).contains(&v))
    }
    /// Shortcuts of fixed menu items, standard editing and the composer, which
    /// commands never take (Swift's fixed menu items keep theirs the same way).
    fn reserved(&self) -> bool {
        let (key, modifiers) = self.physical();
        if modifiers & (MOD | CTRL) == 0 {
            return false;
        }
        let primary = if cfg!(target_os = "macos") { MOD } else { CTRL };
        let exactly = |extra: u8| modifiers == primary | extra;
        match key.as_str() {
            // Quit, Hide, clipboard, undo, Settings and composer keys keep every
            // variant, including Paste and Match Style and Redo.
            "q" | "h" | "c" | "x" | "v" | "z" | "," | "enter" | "tab" | "space" => true,
            // Select All and Minimize; Shift-A and Shift-M are Access and Choose Model.
            "a" | "m" => exactly(0),
            // Close Window. Command-W itself is Archive Thread in the main window.
            "w" => exactly(SHIFT),
            // Find, and macOS Enter Full Screen; Option-Command-F is Search Threads.
            "f" => exactly(0) || (cfg!(target_os = "macos") && exactly(CTRL)),
            // Find Next and Find Previous.
            "g" => exactly(0) || exactly(SHIFT),
            _ => false,
        }
    }
    fn encoded(&self) -> String {
        let mut parts = Vec::new();
        for (flag, text) in [(MOD, "mod"), (CTRL, "ctrl"), (ALT, "alt"), (SHIFT, "shift")] {
            if self.modifiers & flag != 0 {
                parts.push(text);
            }
        }
        parts.push(&self.key);
        parts.join("+")
    }
    /// Spoken modifier and key names, for accessibility labels.
    fn label(&self) -> String {
        let mut parts = Vec::new();
        for (flag, text) in [
            (
                MOD,
                if cfg!(target_os = "macos") {
                    "Command"
                } else {
                    "Control"
                },
            ),
            (CTRL, "Control"),
            (
                ALT,
                if cfg!(target_os = "macos") {
                    "Option"
                } else {
                    "Alt"
                },
            ),
            (SHIFT, "Shift"),
        ] {
            if self.modifiers & flag != 0 && !parts.contains(&text.to_owned()) {
                parts.push(text.to_owned());
            }
        }
        parts.push(self.key_name(false));
        parts.join(" + ")
    }
    fn key_name(&self, glyph: bool) -> String {
        let named = match self.key.as_str() {
            "enter" => Some(("↩", "Enter")),
            "tab" => Some(("⇥", "Tab")),
            "space" => Some(("Space", "Space")),
            "esc" => Some(("⎋", "Esc")),
            "backspace" => Some(("⌫", "Backspace")),
            "delete" => Some(("⌦", "Delete")),
            "arrowup" => Some(("↑", "Up")),
            "arrowdown" => Some(("↓", "Down")),
            "arrowleft" => Some(("←", "Left")),
            "arrowright" => Some(("→", "Right")),
            "home" => Some(("↖", "Home")),
            "end" => Some(("↘", "End")),
            "pageup" => Some(("⇞", "Page Up")),
            "pagedown" => Some(("⇟", "Page Down")),
            _ => None,
        };
        match named {
            Some((symbol, word)) => if glyph { symbol } else { word }.into(),
            None => self.key.to_uppercase(),
        }
    }
    /// The shortcut as this platform's menus write it: ⇧⌘K on macOS (glyphs in
    /// Apple's ⌃⌥⇧⌘ order), Ctrl+Shift+K on Windows and Linux.
    pub(super) fn display(&self) -> String {
        if cfg!(target_os = "macos") {
            let mut text = String::new();
            for (flag, glyph) in [(CTRL, "⌃"), (ALT, "⌥"), (SHIFT, "⇧"), (MOD, "⌘")] {
                if self.modifiers & flag != 0 {
                    text.push_str(glyph);
                }
            }
            text + &self.key_name(true)
        } else {
            let mut parts: Vec<String> = Vec::new();
            if self.modifiers & (MOD | CTRL) != 0 {
                parts.push("Ctrl".into());
            }
            if self.modifiers & ALT != 0 {
                parts.push("Alt".into());
            }
            if self.modifiers & SHIFT != 0 {
                parts.push("Shift".into());
            }
            parts.push(self.key_name(false));
            parts.join("+")
        }
    }
    /// GPUI keystroke text for a native menu item's key equivalent.
    fn keystroke(&self) -> String {
        let mut parts: Vec<&str> = Vec::new();
        let (control, platform) = if cfg!(target_os = "macos") {
            (self.modifiers & CTRL != 0, self.modifiers & MOD != 0)
        } else {
            (self.modifiers & (MOD | CTRL) != 0, false)
        };
        if control {
            parts.push("ctrl");
        }
        if self.modifiers & ALT != 0 {
            parts.push("alt");
        }
        if self.modifiers & SHIFT != 0 {
            parts.push("shift");
        }
        if platform {
            parts.push("cmd");
        }
        let key = match self.key.as_str() {
            "esc" => "escape",
            "arrowup" => "up",
            "arrowdown" => "down",
            "arrowleft" => "left",
            "arrowright" => "right",
            other => other,
        };
        parts.push(key);
        parts.join("-")
    }
}
struct Binding {
    shortcut: Option<Shortcut>,
    customized: bool,
    issue: Option<&'static str>,
}
fn overrides(settings: &Value) -> Result<Option<&serde_json::Map<String, Value>>> {
    anyhow::ensure!(settings.is_object(), "Stored settings are not an object");
    settings
        .get("shortcutOverrides")
        .map(|value| {
            value.as_object().ok_or_else(|| {
                anyhow::anyhow!("Saved shortcut overrides are malformed; existing data is retained")
            })
        })
        .transpose()
}
/// The command's shortcut as this platform writes it (⌘B, Ctrl+B), for tooltips.
pub(super) fn shortcut_label(settings: &Value, command: Command) -> Option<String> {
    binding(settings, command)
        .shortcut
        .map(|shortcut| shortcut.display())
}
/// The shortcut a menu item or palette row shows: the command's own, unless it
/// runs another command or belongs to a fixed command (Swift `menuShortcut`).
pub(super) fn menu_shortcut(settings: &Value, command: Command) -> Option<Shortcut> {
    let shortcut = binding(settings, command).shortcut?;
    (!shortcut.reserved() && resolve(settings, &shortcut) == Some(command)).then_some(shortcut)
}
pub(super) fn menu_shortcut_label(settings: &Value, command: Command) -> Option<String> {
    menu_shortcut(settings, command).map(|shortcut| shortcut.display())
}

/// The command's shortcut as this platform writes it, for tooltips.
pub(super) fn shortcut_hint(settings: &Value, command: Command) -> Option<String> {
    shortcut_label(settings, command)
}
/// GPUI keystroke text for the command's native menu key equivalent.
pub(super) fn menu_keystroke(settings: &Value, command: Command) -> Option<String> {
    menu_shortcut(settings, command).map(|shortcut| shortcut.keystroke())
}
fn binding(settings: &Value, command: Command) -> Binding {
    let fallback = command.default_shortcut();
    let value = overrides(settings)
        .ok()
        .flatten()
        .and_then(|map| map.get(command.id()));
    let Some(value) = value else {
        return Binding {
            shortcut: fallback,
            customized: false,
            issue: None,
        };
    };
    if value.as_str().is_some_and(|s| s.trim().is_empty()) {
        return Binding {
            customized: fallback.is_some(),
            shortcut: None,
            issue: None,
        };
    }
    let parsed = value.as_str().and_then(Shortcut::parse);
    let issue = match &parsed {
        None => Some("Saved shortcut is unreadable; the default is used."),
        Some(key) if !key.usable() => {
            Some("Saved shortcut needs Command or Control; the default is used.")
        }
        Some(key) if key.reserved() => {
            Some("Saved shortcut belongs to a fixed command; the default is used.")
        }
        _ => None,
    };
    if issue.is_some() {
        Binding {
            shortcut: fallback,
            customized: false,
            issue,
        }
    } else {
        let customized =
            parsed.as_ref().map(Shortcut::physical) != fallback.as_ref().map(Shortcut::physical);
        Binding {
            shortcut: parsed,
            customized,
            issue: None,
        }
    }
}
fn resolve(settings: &Value, key: &Shortcut) -> Option<Command> {
    if key.reserved() {
        return None;
    }
    let matches: Vec<_> = Command::ALL
        .into_iter()
        .filter_map(|command| {
            let value = binding(settings, command);
            (value
                .shortcut
                .as_ref()
                .is_some_and(|saved| saved.physical() == key.physical()))
            .then_some((command, value.customized))
        })
        .collect();
    if let Some((command, _)) = matches
        .iter()
        .find(|(_, customized)| *customized)
        .or(matches.first())
    {
        return Some(*command);
    }
    // Command-= reaches Increase Font Size without Shift while it keeps its
    // default Command-+ and nothing else has Command-= (Swift's hidden item).
    let larger = binding(settings, Command::Larger);
    let equals = Shortcut {
        key: "=".into(),
        modifiers: MOD,
    };
    (key.physical() == equals.physical() && !larger.customized && larger.shortcut.is_some())
        .then_some(Command::Larger)
}
/// Keys a focused terminal keeps for itself, with the title Settings lists for
/// them. macOS follows Swift's `ShellTerminalView.handleKeyDown`; Windows and
/// Linux use Control-Shift, as their terminals do, so plain Control keys still
/// reach the shell.
pub(super) const TERMINAL_KEYS: &[(&str, &[&str])] = if cfg!(target_os = "macos") {
    &[
        ("New terminal", &["mod+t", "mod+n"]),
        ("Split right", &["mod+d"]),
        ("Split down", &["mod+shift+d"]),
        ("Close terminal", &["mod+w"]),
        ("Clear", &["mod+k"]),
        (
            "Previous and next terminal tab",
            &["mod+shift+[", "mod+shift+]"],
        ),
        (
            "Previous and next pane",
            &[
                "mod+alt+arrowleft",
                "mod+alt+arrowright",
                "mod+alt+arrowup",
                "mod+alt+arrowdown",
            ],
        ),
        (
            "Move to the start or end of the line",
            &["mod+arrowleft", "mod+arrowright"],
        ),
        ("Delete to the start of the line", &["mod+backspace"]),
        ("Move by word", &["alt+arrowleft", "alt+arrowright"]),
        ("Delete the previous word", &["alt+backspace"]),
        (
            "Previous and next command",
            &["mod+arrowup", "mod+arrowdown"],
        ),
    ]
} else {
    &[
        ("New terminal", &["ctrl+shift+t"]),
        ("Split right", &["ctrl+shift+d"]),
        ("Split down", &["ctrl+alt+shift+d"]),
        ("Close terminal", &["ctrl+shift+w"]),
        ("Clear", &["ctrl+shift+k"]),
        (
            "Previous and next terminal tab",
            &["ctrl+pageup", "ctrl+pagedown"],
        ),
        (
            "Previous and next pane",
            &[
                "ctrl+alt+arrowleft",
                "ctrl+alt+arrowright",
                "ctrl+alt+arrowup",
                "ctrl+alt+arrowdown",
            ],
        ),
        (
            "Previous and next command",
            &["ctrl+shift+arrowup", "ctrl+shift+arrowdown"],
        ),
    ]
};
/// What a focused terminal does with `key`, as a `TERMINAL_KEYS` title.
fn terminal_key_title(key: &Shortcut) -> Option<&'static str> {
    TERMINAL_KEYS.iter().find_map(|(title, keys)| {
        keys.iter()
            .filter_map(|text| Shortcut::parse(text))
            .any(|owned| owned.physical() == key.physical())
            .then_some(*title)
    })
}
/// The terminal's own action for a key press, for its key handler.
pub(super) fn terminal_key(event: &Keystroke) -> Option<&'static str> {
    Shortcut::event(event).and_then(|key| terminal_key_title(&key))
}
/// Commands that keep running while a browser panel is visible. A native
/// WebKit responder is not represented by a GPUI focus handle, so every other
/// key stays with the page.
pub(super) fn browser_command(command: Command) -> bool {
    matches!(command, Command::NewThread | Command::Palette)
}
fn route(
    command: Option<Command>,
    key: &Shortcut,
    terminal: bool,
    browser: bool,
    palette: bool,
) -> Option<Command> {
    let command = command?;
    if palette && command != Command::Palette {
        return None;
    }
    if terminal {
        if cfg!(target_os = "macos") {
            // Command keys never reach the shell: only the terminal's own keys
            // stay with it, and other menu commands still run (Swift parity).
            if terminal_key_title(key).is_some() {
                return None;
            }
        } else if !(command == Command::Palette
            && key.physical() == Shortcut::parse("mod+k").unwrap().physical())
        {
            // Control keys are shell input on Windows and Linux.
            return None;
        }
    }
    if browser && !browser_command(command) {
        return None;
    }
    Some(command)
}
#[derive(Clone, Copy)]
enum Change<'a> {
    Set(Command, &'a str),
    Reset(Command),
    ResetSupported,
}
fn changed_overrides(settings: &Value, change: Change<'_>) -> Result<Value> {
    let mut map = overrides(settings)?.cloned().unwrap_or_default();
    match change {
        Change::Set(command, raw) => {
            let id = command.id();
            let default = command.default_shortcut();
            if raw.is_empty() {
                // Removing a shortcut a command never had is no override at all.
                if default.is_some() {
                    map.insert(id.into(), json!(""));
                } else {
                    map.remove(id);
                }
            } else {
                let shortcut = Shortcut::parse(raw)
                    .ok_or_else(|| anyhow::anyhow!("That is not a shortcut"))?;
                anyhow::ensure!(
                    shortcut.usable() && !shortcut.reserved(),
                    "That shortcut belongs to typing or a fixed command"
                );
                if default.is_some_and(|default| default.physical() == shortcut.physical()) {
                    map.remove(id);
                } else {
                    map.insert(id.into(), json!(shortcut.encoded()));
                }
            }
        }
        Change::Reset(command) => {
            map.remove(command.id());
        }
        Change::ResetSupported => {
            for command in Command::ALL {
                map.remove(command.id());
            }
        }
    }
    Ok(Value::Object(map))
}
fn save(engine: &SharedEngine, change: Change<'_>) -> Result<Value> {
    // Read, merge and dispatch under one non-waiting owner lock. A stale panel
    // must never replace another command's override or an unknown imported ID.
    let mut owner = try_state(engine)?;
    anyhow::ensure!(!owner.admissions_frozen(), "App is closing");
    let response = owner.dispatch(json!({"method":"settings.read","params":{}}));
    anyhow::ensure!(
        response.get("error").is_none(),
        "Settings could not be read"
    );
    let next = changed_overrides(&response["result"], change)?;
    let response = owner
        .dispatch(json!({"method":"settings.patch","params":{"patch":{"shortcutOverrides":next}}}));
    if let Some(error) = response.get("error") {
        anyhow::bail!(
            "{}",
            error["message"]
                .as_str()
                .unwrap_or("Shortcut was not saved")
        );
    }
    Ok(response["result"].clone())
}
/// macOS shortcuts the system keeps in a standard setup (Swift's
/// `ReservedShortcut.macOS`), so a menu command never receives them.
const MACOS_RESERVED: &[(&str, &str)] = &[
    ("mod+space", "Spotlight"),
    ("mod+alt+space", "Finder search window"),
    ("ctrl+space", "Select the previous input source"),
    ("ctrl+alt+space", "Select the next input source"),
    ("mod+tab", "Switch apps"),
    ("mod+shift+tab", "Switch apps"),
    ("mod+`", "Move focus to the next window"),
    ("mod+shift+`", "Move focus to the previous window"),
    ("mod+shift+3", "Screenshot"),
    ("mod+shift+4", "Screenshot of an area"),
    ("mod+shift+5", "Screenshot and recording options"),
    ("mod+ctrl+shift+3", "Copy a screenshot"),
    ("mod+ctrl+shift+4", "Copy a screenshot of an area"),
    ("mod+ctrl+q", "Lock Screen"),
    ("mod+shift+q", "Log Out"),
    ("mod+alt+shift+q", "Log Out"),
    ("mod+alt+esc", "Force Quit"),
    ("mod+ctrl+space", "Emoji & Symbols"),
    ("mod+shift+/", "Search the Help menu"),
    ("mod+alt+d", "Show or hide the Dock"),
    ("ctrl+arrowup", "Mission Control"),
    ("ctrl+arrowdown", "Application windows"),
    ("ctrl+arrowleft", "Move left a space"),
    ("ctrl+arrowright", "Move right a space"),
    ("ctrl+f2", "Move focus to the menu bar"),
    ("ctrl+f3", "Move focus to the Dock"),
    ("ctrl+f4", "Move focus to the active or next window"),
    ("ctrl+f5", "Move focus to the window toolbar"),
    ("ctrl+f6", "Move focus to the floating window"),
    ("ctrl+f7", "Change the way Tab moves focus"),
    ("ctrl+f8", "Move focus to status menus"),
];
/// A command name inside a sentence, without its menu ellipsis.
fn sentence_name(title: &str) -> &str {
    title.strip_suffix('…').unwrap_or(title)
}
/// Swift's KeyboardSettingsView messages: warnings about other commands and
/// macOS, and notes about keys a focused terminal keeps.
fn messages(settings: &Value, command: Command) -> (Vec<String>, Vec<String>) {
    let Some(shortcut) = binding(settings, command).shortcut else {
        return (vec![], vec![]);
    };
    let keys = shortcut.display();
    let winner = resolve(settings, &shortcut);
    let mut warnings = Vec::new();
    for other in Command::ALL {
        if other == command
            || !binding(settings, other)
                .shortcut
                .is_some_and(|key| key.physical() == shortcut.physical())
        {
            continue;
        }
        warnings.push(if winner == Some(other) {
            format!("{keys} runs {} instead.", sentence_name(other.title()))
        } else {
            format!("Also assigned to {}.", sentence_name(other.title()))
        });
    }
    if cfg!(target_os = "macos") {
        for (text, owner) in MACOS_RESERVED {
            if Shortcut::parse(text).is_some_and(|key| key.physical() == shortcut.physical()) {
                warnings.push(format!("macOS uses {keys} for {owner}."));
                break;
            }
        }
    }
    let mut notes = Vec::new();
    if let Some(title) = terminal_key_title(&shortcut) {
        notes.push(format!(
            "In a focused terminal, {keys} does “{title}” instead."
        ));
    }
    (warnings, notes)
}
pub struct State {
    recording: Option<Command>,
    restore: Option<FocusHandle>,
    focus: FocusHandle,
    reset_confirm: bool,
}
impl State {
    pub fn new(cx: &mut Context<Coincide>) -> Self {
        Self {
            recording: None,
            restore: None,
            focus: cx.focus_handle(),
            reset_confirm: false,
        }
    }
}
const SUBTITLE: &str = if cfg!(target_os = "macos") {
    "Click a shortcut, then press the keys you want. Standard macOS shortcuts such as Copy and Close Window stay as they are."
} else {
    "Click a shortcut, then press the keys you want. Standard shortcuts such as Copy and Close Window stay as they are."
};
const TERMINAL_NOTE: &str = if cfg!(target_os = "macos") {
    "While a terminal has focus these keys act on it instead of the menu commands they share, as in T3 Code."
} else {
    "While a terminal has focus these keys act on it, and other Control shortcuts go to the shell; Control+K still opens the command palette."
};
impl Coincide {
    pub(super) fn cancel_settings_shortcut(&mut self) {
        self.keyboard.recording = None;
        self.keyboard.restore = None;
        self.keyboard.reset_confirm = false;
    }
    pub(super) fn focus_settings_route(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // A hidden Settings handle stays alive but is no longer in GPUI's
        // dispatch tree. Do not restore recording focus into the old subtree.
        self.cancel_settings_shortcut();
        // The rail is mounted on both sides of the route, so its focus keeps
        // the existing app capture handler reachable without focusing an editor.
        if self.settings_open {
            self.show_settings_window(cx);
            if self
                .settings_window
                .is_some_and(|handle| handle == window.window_handle())
            {
                self.settings_focus.focus(window, cx);
            }
        } else {
            self.navigation_focus.focus(window, cx);
        }
    }
    fn save_shortcut(&mut self, change: Change<'_>, window: &mut Window, cx: &mut Context<Self>) {
        match save(&self.engine, change) {
            Ok(settings) => {
                self.settings_status = "Keyboard shortcut saved".into();
                self.accept_settings(settings, window, cx);
            }
            Err(error) => self.settings_status = format!("Shortcut was not saved: {error}"),
        }
        cx.notify();
    }
    fn cancel_shortcut_recording(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.keyboard.recording = None;
        if let Some(focus) = self.keyboard.restore.take() {
            focus.focus(window, cx);
        }
    }
    pub(super) fn sync_keyboard_recording(&mut self, window: &Window, cx: &mut Context<Self>) {
        if self.keyboard.recording.is_some()
            && (!window.is_window_active()
                || !self.keyboard_panel_visible(cx)
                || !self.keyboard.focus.is_focused(window)
                || !window.visibility().is_visible())
        {
            // A click/focus or route change cancels; never refocus a hidden pane.
            self.keyboard.recording = None;
            self.keyboard.restore = None;
        }
        if !self.keyboard_panel_visible(cx) {
            self.keyboard.reset_confirm = false;
        }
    }
    pub(super) fn record_shortcut_event(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        self.sync_keyboard_recording(window, cx);
        let Some(command) = self.keyboard.recording else {
            return false;
        };
        let key = &event.keystroke;
        // Ordinary quit and OS/native standard commands retain their path.
        if key.key == "q" && (key.modifiers.platform || key.modifiers.control) {
            self.cancel_shortcut_recording(window, cx);
            return false;
        }
        if event.is_held {
            cx.stop_propagation();
            return true;
        }
        let plain = !key.modifiers.platform
            && !key.modifiers.control
            && !key.modifiers.alt
            && !key.modifiers.shift;
        if key.key == "escape" && plain {
            self.cancel_shortcut_recording(window, cx);
            self.settings_status = "Shortcut recording cancelled".into();
        } else if matches!(key.key.as_str(), "backspace" | "delete") && plain {
            // As Swift's recorder: Delete removes the shortcut.
            self.cancel_shortcut_recording(window, cx);
            self.save_shortcut(Change::Set(command, ""), window, cx);
        } else if let Some(shortcut) = Shortcut::event(key) {
            if shortcut.reserved() {
                self.cancel_shortcut_recording(window, cx);
                self.settings_status =
                    "That shortcut belongs to a fixed command and was not changed.".into();
                cx.notify();
                return false;
            } else if !shortcut.usable() {
                self.settings_status = "Use Command or Control with a key, or a function key. Fixed editing, Find, Settings, Send and OS keys stay reserved. Delete removes the shortcut; Escape cancels.".into();
            } else {
                let encoded = shortcut.encoded();
                self.cancel_shortcut_recording(window, cx);
                self.save_shortcut(Change::Set(command, &encoded), window, cx);
            }
        } else {
            self.settings_status =
                "That key combination is not supported. Try another shortcut, or Escape to cancel."
                    .into();
        }
        cx.stop_propagation();
        cx.notify();
        true
    }
    pub(super) fn keyboard_command(
        &self,
        key: &Keystroke,
        terminal_owns: bool,
        browser_visible: bool,
        palette_open: bool,
    ) -> Option<Command> {
        let key = Shortcut::event(key)?;
        route(
            resolve(&self.settings, &key),
            &key,
            terminal_owns,
            browser_visible,
            palette_open,
        )
    }
    /// The command a key press would run anywhere, before focus ownership.
    /// A native menu item has the same key equivalent, so a press the current
    /// owner declines is consumed instead of reaching that menu item.
    pub(super) fn keyboard_command_unrouted(&self, key: &Keystroke) -> Option<Command> {
        resolve(&self.settings, &Shortcut::event(key)?)
    }
    fn keyboard_row(&self, command: Command, writable: bool, cx: &mut Context<Self>) -> Div {
        let (id, title) = (command.id(), command.title());
        let current = binding(&self.settings, command);
        let recording = self.keyboard.recording == Some(command);
        let overridden = overrides(&self.settings)
            .ok()
            .flatten()
            .is_some_and(|map| map.contains_key(id));
        let owner = cx.entity().downgrade();
        let removable = current.shortcut.is_some();
        let mut row = div()
            .flex()
            .flex_col()
            .gap_1()
            .border_b_1()
            .border_color(self.color(0x29303d))
            .pb_2()
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1().min_w(px(190.)).child(title))
                    .child(
                        Button::new(SharedString::from(format!("shortcut-record-{id}")))
                            .label(if recording {
                                "Press keys…".into()
                            } else {
                                current
                                    .shortcut
                                    .as_ref()
                                    .map(Shortcut::display)
                                    .unwrap_or_else(|| "Record Shortcut".into())
                            })
                            .compact()
                            .w(px(130.))
                            .disabled(!writable)
                            .accessibility_label(format!(
                                "Record shortcut for {title}{}",
                                current
                                    .shortcut
                                    .as_ref()
                                    .map(|key| format!(", currently {}", key.label()))
                                    .unwrap_or_default()
                            ))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.keyboard.restore = window.focused(cx);
                                this.keyboard.recording = Some(command);
                                this.keyboard.reset_confirm = false;
                                this.keyboard.focus.focus(window, cx);
                                this.settings_status =
                                    "Press the new shortcut. Delete removes it; Escape cancels."
                                        .into();
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new(SharedString::from(format!("shortcut-options-{id}")))
                            .icon(gpui_kit::assets::IconName::Ellipsis)
                            .accessibility_label(format!("More options for {title}"))
                            .tooltip("Reset or remove the shortcut")
                            .ghost()
                            .compact()
                            .dropdown_menu_with_anchor(Anchor::TopRight, move |menu, _, _| {
                                let reset = owner.clone();
                                let remove = owner.clone();
                                menu.item(
                                    PopupMenuItem::new("Reset to Default")
                                        .disabled(!writable || !overridden)
                                        .on_click(move |_, window, cx| {
                                            let _ = reset.update(cx, |this, cx| {
                                                this.save_shortcut(
                                                    Change::Reset(command),
                                                    window,
                                                    cx,
                                                );
                                            });
                                        }),
                                )
                                .item(
                                    PopupMenuItem::new("Remove Shortcut")
                                        .disabled(!writable || !removable)
                                        .on_click(move |_, window, cx| {
                                            let _ = remove.update(cx, |this, cx| {
                                                this.save_shortcut(
                                                    Change::Set(command, ""),
                                                    window,
                                                    cx,
                                                );
                                            });
                                        }),
                                )
                            }),
                    ),
            );
        if recording {
            return row.child(
                div()
                    .text_sm()
                    .child("Press the new shortcut. Delete removes it; Escape cancels."),
            );
        }
        if let Some(issue) = current.issue {
            row = row.child(div().text_sm().child(issue));
        }
        let (warnings, notes) = messages(&self.settings, command);
        for line in warnings.into_iter().chain(notes) {
            row = row.child(div().text_sm().child(line));
        }
        if current.customized {
            row = row.child(div().text_sm().child(match command.default_shortcut() {
                Some(default) => format!("Default: {}", default.display()),
                None => "No shortcut by default".into(),
            }));
        }
        row
    }
    pub(super) fn keyboard_settings(&self, cx: &mut Context<Self>) -> AnyElement {
        let writable = overrides(&self.settings).is_ok();
        let mut panel = div()
            .id("keyboard-settings")
            .track_focus(&self.keyboard.focus)
            .p_3()
            .flex()
            .flex_col()
            .gap_3()
            .child(div().text_lg().child("Keyboard Shortcuts"))
            .child(div().text_sm().child(SUBTITLE));
        if let Err(error) = overrides(&self.settings) {
            panel = panel.child(div().text_sm().child(error.to_string()));
        }
        let retained = overrides(&self.settings).ok().flatten().map_or(0, |map| {
            map.keys()
                .filter(|id| {
                    !Command::ALL
                        .iter()
                        .any(|command| command.id() == id.as_str())
                })
                .count()
        });
        if retained > 0 {
            panel = panel.child(div().text_sm().child(format!("{retained} saved shortcut(s) belong to commands this version does not have and are kept unchanged.")));
        }
        let heading =
            |title: &'static str| div().mt_2().font_weight(FontWeight::SEMIBOLD).child(title);
        for menu in Menu::ALL {
            panel = panel.child(heading(menu.title()));
            for command in Command::ALL
                .into_iter()
                .filter(|command| command.menu() == menu && command.jump_index().is_none())
            {
                panel = panel.child(self.keyboard_row(command, writable, cx));
            }
        }
        panel = panel.child(heading("Go to Thread"));
        for command in Command::ALL
            .into_iter()
            .filter(|command| command.jump_index().is_some())
        {
            panel = panel.child(self.keyboard_row(command, writable, cx));
        }
        panel = panel.child(
            div()
                .text_sm()
                .child("Threads are counted from the top of the sidebar."),
        );
        if self.keyboard.recording.is_some() {
            panel = panel.child(
                Button::new("shortcut-record-cancel")
                    .label("Cancel recording")
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.cancel_shortcut_recording(window, cx);
                        cx.notify();
                    })),
            );
        }
        let customized = overrides(&self.settings).ok().flatten().is_some_and(|map| {
            Command::ALL
                .iter()
                .any(|command| map.contains_key(command.id()))
        });
        panel = panel.child(
            div()
                .flex()
                .flex_wrap()
                .items_center()
                .gap_2()
                .child(div().flex_1().min_w(px(190.)).text_sm().child("When two commands share a shortcut, a changed one wins over a default one. Fixed menu shortcuts such as Copy keep their keys."))
                .child(
                    Button::new("shortcuts-reset-supported")
                        .label("Reset All…")
                        .disabled(!writable || !customized)
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.keyboard.reset_confirm = true;
                            cx.notify();
                        })),
                ),
        );
        if self.keyboard.reset_confirm {
            panel = panel.child(div().flex().flex_wrap().items_center().gap_2()
                .child(div().font_weight(FontWeight::SEMIBOLD).child("Reset all keyboard shortcuts?"))
                .child("Every menu command goes back to its default shortcut. Shortcuts saved for commands this version does not have are kept.")
                .child(Button::new("shortcuts-reset-confirm").label("Reset All").on_click(cx.listener(|this,_,window,cx| {this.keyboard.reset_confirm=false; this.save_shortcut(Change::ResetSupported,window,cx); })))
                .child(Button::new("shortcuts-reset-cancel").label("Cancel").on_click(cx.listener(|this,_,_,cx| {this.keyboard.reset_confirm=false; cx.notify();}))));
        }
        panel = panel.child(heading("Terminal"));
        for (title, keys) in TERMINAL_KEYS {
            let keys = keys
                .iter()
                .filter_map(|text| Shortcut::parse(text))
                .map(|key| key.display())
                .collect::<Vec<_>>()
                .join(" or ");
            panel = panel.child(
                div()
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1().min_w(px(190.)).child(*title))
                    .child(div().text_sm().child(keys)),
            );
        }
        panel
            .child(div().text_sm().child(TERMINAL_NOTE))
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn key(text: &str) -> Shortcut {
        Shortcut::parse(text).unwrap()
    }
    #[::core::prelude::v1::test]
    fn swift_syntax_round_trips_aliases_plus_unicode_and_exact_modifier_keys() {
        for (source, expected) in [
            ("Command+Option+Shift+L", "mod+alt+shift+l"),
            ("ctrl+return", "ctrl+enter"),
            ("mod++", "mod++"),
            ("Mod+é", "mod+é"),
            ("f20", "f20"),
        ] {
            let parsed = key(source);
            assert_eq!(parsed.encoded(), expected);
            assert_eq!(Shortcut::parse(&parsed.encoded()), Some(parsed));
        }
        for invalid in [
            "",
            "mod",
            "mod+k+l",
            "mod++k",
            "mod+f21",
            "mod+\n",
            "mod+two",
            "mod+shift",
        ] {
            assert!(Shortcut::parse(invalid).is_none(), "{invalid:?}");
        }
        assert_eq!(key("mod++").physical(), key("mod+shift+=").physical());
        assert!(!key("alt+x").usable());
        assert!(key("f1").usable());
        let mut event = Keystroke {
            key: "k".into(),
            ..Default::default()
        };
        if cfg!(target_os = "macos") {
            event.modifiers.platform = true;
        } else {
            event.modifiers.control = true;
        }
        assert_eq!(
            Shortcut::event(&event).unwrap().physical(),
            key("mod+k").physical()
        );
        event.modifiers.function = true;
        assert!(Shortcut::event(&event).is_none());
    }
    #[::core::prelude::v1::test]
    fn fixed_keys_and_bad_imports_never_gain_command_ownership_or_silent_repairs() {
        for fixed in [
            "mod+c",
            "ctrl+c",
            "mod+shift+z",
            "mod+enter",
            "mod+shift+enter",
            "mod+f",
            "mod+,",
            "mod+q",
            "mod+alt+q",
            "mod+shift+w",
            "mod+g",
            "mod+shift+g",
            "mod+a",
            "mod+m",
            "mod+tab",
            "mod+space",
        ] {
            let settings = json!({"shortcutOverrides":{"chat.new":fixed}});
            assert!(resolve(&settings, &key(fixed)).is_none(), "{fixed}");
            assert_eq!(resolve(&settings, &key("mod+n")), Some(Command::NewThread));
            assert!(binding(&settings, Command::NewThread).issue.is_some());
        }
        for bad in [
            json!("unreadable"),
            json!("x"),
            json!(["mod+l"]),
            json!(false),
        ] {
            let settings = json!({"shortcutOverrides":{"chat.new":bad}});
            let before = settings.clone();
            assert_eq!(resolve(&settings, &key("mod+n")), Some(Command::NewThread));
            assert!(binding(&settings, Command::NewThread).issue.is_some());
            assert_eq!(settings, before);
        }
    }
    #[::core::prelude::v1::test]
    fn custom_conflicts_override_defaults_and_disabled_commands_stay_disabled() {
        let one = json!({"shortcutOverrides":{"chat.new":"mod+k"}});
        assert_eq!(resolve(&one, &key("mod+k")), Some(Command::NewThread));
        assert!(resolve(&one, &key("mod+n")).is_none());
        let two = json!({"shortcutOverrides":{"chat.new":"mod+l","commandPalette.toggle":"mod+l","sidebar.toggle":""}});
        assert_eq!(resolve(&two, &key("mod+l")), Some(Command::NewThread));
        assert!(resolve(&two, &key("mod+b")).is_none());
        assert!(binding(&two, Command::Sidebar).shortcut.is_none());
        let removed = changed_overrides(&two, Change::Reset(Command::NewThread)).unwrap();
        assert_eq!(
            resolve(&json!({"shortcutOverrides":removed}), &key("mod+l")),
            Some(Command::Palette)
        );
    }
    #[::core::prelude::v1::test]
    fn native_terminal_browser_and_palette_keep_existing_key_ownership() {
        if cfg!(target_os = "macos") {
            // Swift's focused terminal keeps only its own keys; Command-K is Clear.
            for owned in ["mod+k", "mod+t", "mod+n", "mod+d", "mod+w", "mod+shift+["] {
                assert_eq!(
                    route(Some(Command::Palette), &key(owned), true, false, false),
                    None,
                    "{owned}"
                );
            }
            assert_eq!(
                route(Some(Command::Sidebar), &key("mod+b"), true, false, false),
                Some(Command::Sidebar)
            );
            assert_eq!(
                route(Some(Command::Stop), &key("mod+."), true, false, false),
                Some(Command::Stop)
            );
        } else {
            // Control keys are shell input; only the palette keeps Control-K.
            assert_eq!(
                route(Some(Command::Palette), &key("mod+k"), true, false, false),
                Some(Command::Palette)
            );
            assert_eq!(
                route(Some(Command::Palette), &key("mod+t"), true, false, false),
                None
            );
            assert_eq!(
                route(Some(Command::Sidebar), &key("mod+b"), true, false, false),
                None
            );
        }
        assert_eq!(
            route(Some(Command::NewThread), &key("mod+n"), true, false, false),
            None
        );
        assert_eq!(
            route(Some(Command::Sidebar), &key("mod+b"), false, true, false),
            None
        );
        assert_eq!(
            route(Some(Command::NewThread), &key("mod+n"), false, true, false),
            Some(Command::NewThread)
        );
        assert_eq!(
            route(
                Some(Command::Schedules),
                &key("mod+alt+s"),
                false,
                false,
                true
            ),
            None
        );
        assert_eq!(
            route(Some(Command::Palette), &key("mod+l"), false, false, true),
            Some(Command::Palette)
        );
    }
    #[::core::prelude::v1::test]
    fn reset_and_assignment_preserve_foreign_commands_values_and_malformed_maps() {
        let source = json!({"appearance":"dark","futureSetting":{"keep":[1,2]},"shortcutOverrides":{"chat.new":"mod+l","terminal.toggle":"","future.command":{"opaque":[7]},"future.search":"mod+alt+f","thread.copyPath":"mod+alt+c"}});
        let original = source.clone();
        let reset = changed_overrides(&source, Change::ResetSupported).unwrap();
        assert_eq!(
            reset,
            json!({"future.command":{"opaque":[7]},"future.search":"mod+alt+f"})
        );
        let set = changed_overrides(&source, Change::Set(Command::NewThread, "CMD+N")).unwrap();
        assert!(set.get("chat.new").is_none());
        assert_eq!(
            set["future.command"],
            source["shortcutOverrides"]["future.command"]
        );
        assert_eq!(set["terminal.toggle"], "");
        assert_eq!(source, original);
        for broken in [
            json!([]),
            json!({"shortcutOverrides":null}),
            json!({"shortcutOverrides":[]}),
            json!({"shortcutOverrides":"opaque"}),
        ] {
            let before = broken.clone();
            assert!(changed_overrides(&broken, Change::ResetSupported).is_err());
            assert!(changed_overrides(&broken, Change::Set(Command::NewThread, "mod+l")).is_err());
            assert_eq!(broken, before);
        }
    }
    #[::core::prelude::v1::test]
    fn actual_owner_save_merges_latest_settings_and_refuses_busy_frozen_or_malformed() {
        let root = std::env::temp_dir().join(format!("coincide-keyboard-{}", uuid::Uuid::new_v4()));
        let mut store = Store::open(&root.join("coincide.sqlite")).unwrap();
        let original = json!({"appearance":"dark","future":{"keep":true},"shortcutOverrides":{"future.command":{"opaque":[1]},"sidebar.search":"mod+alt+f"}});
        store.save_document("settings.json", &original).unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(store)));
        let saved = save(&engine, Change::Set(Command::NewThread, "mod+l")).unwrap();
        assert_eq!(saved["future"], original["future"]);
        assert_eq!(
            saved["shortcutOverrides"]["future.command"],
            original["shortcutOverrides"]["future.command"]
        );
        // Another settings operation lands after the panel's snapshot. Saving
        // a second command reads the latest owner document, not that snapshot.
        engine
            .lock()
            .unwrap()
            .store
            .patch_document("settings.json", &json!({"appearance":"light"}))
            .unwrap();
        let latest = save(&engine, Change::Set(Command::Sidebar, "mod+shift+b")).unwrap();
        assert_eq!(latest["appearance"], "light");
        assert_eq!(latest["shortcutOverrides"]["chat.new"], "mod+l");
        let held = engine.lock().unwrap();
        assert!(engine_busy(
            &save(&engine, Change::ResetSupported).unwrap_err()
        ));
        assert_eq!(
            held.store.document("settings.json").unwrap(),
            Some(latest.clone())
        );
        drop(held);
        let malformed = json!({"future":true,"shortcutOverrides":["retain"]});
        engine
            .lock()
            .unwrap()
            .store
            .save_document("settings.json", &malformed)
            .unwrap();
        assert!(save(&engine, Change::ResetSupported).is_err());
        assert_eq!(
            engine
                .lock()
                .unwrap()
                .store
                .document("settings.json")
                .unwrap(),
            Some(malformed)
        );
        engine
            .lock()
            .unwrap()
            .store
            .save_document("settings.json", &latest)
            .unwrap();
        engine.lock().unwrap().freeze_admissions();
        assert!(save(&engine, Change::ResetSupported).is_err());
        assert_eq!(
            engine
                .lock()
                .unwrap()
                .store
                .document("settings.json")
                .unwrap(),
            Some(latest)
        );
        drop(engine);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[::core::prelude::v1::test]
    fn every_swift_key_command_has_its_id_title_menu_and_unshadowed_default() {
        let ids: Vec<_> = Command::ALL.iter().map(|command| command.id()).collect();
        assert_eq!(ids.len(), 39);
        assert_eq!(
            ids.iter().collect::<std::collections::HashSet<_>>().len(),
            39
        );
        for (command, id, title, menu, default) in [
            (
                Command::NewThread,
                "chat.new",
                "New Thread",
                Menu::File,
                Some("mod+n"),
            ),
            (
                Command::NewChat,
                "chat.newProjectless",
                "New Chat",
                Menu::File,
                Some("mod+shift+n"),
            ),
            (
                Command::AddProject,
                "project.add",
                "Add Project…",
                Menu::File,
                Some("mod+shift+o"),
            ),
            (
                Command::OpenInEditor,
                "editor.openFavorite",
                "Open in Editor",
                Menu::File,
                Some("mod+o"),
            ),
            (
                Command::RevealInFinder,
                "project.revealInFinder",
                REVEAL_TITLE,
                Menu::File,
                None,
            ),
            (
                Command::AddToComposer,
                "composer.addSelection",
                "Add Selection to Composer",
                Menu::Edit,
                Some("mod+l"),
            ),
            (
                Command::SearchThreads,
                "sidebar.search",
                "Search Threads",
                Menu::Edit,
                Some("mod+alt+f"),
            ),
            (
                Command::Diff,
                "diff.toggle",
                "Show or Hide Diff",
                Menu::View,
                Some("mod+d"),
            ),
            (
                Command::ShowArchive,
                "archive.show",
                "Archived Threads…",
                Menu::View,
                Some("mod+alt+a"),
            ),
            (
                Command::Stop,
                "thread.stop",
                "Stop",
                Menu::Thread,
                Some("mod+."),
            ),
            (
                Command::PreviousThread,
                "thread.previous",
                "Previous Thread",
                Menu::Thread,
                Some("mod+shift+["),
            ),
            (
                Command::NextThread,
                "thread.next",
                "Next Thread",
                Menu::Thread,
                Some("mod+shift+]"),
            ),
            (
                Command::Jump(1),
                "thread.jump.1",
                "Go to Thread 1",
                Menu::Thread,
                Some("mod+1"),
            ),
            (
                Command::Jump(9),
                "thread.jump.9",
                "Go to Thread 9",
                Menu::Thread,
                Some("mod+9"),
            ),
            (
                Command::ChooseModel,
                "modelPicker.toggle",
                "Choose Agent and Model…",
                Menu::Thread,
                Some("mod+shift+m"),
            ),
            (
                Command::ReasoningEffort,
                "composer.effort",
                "Reasoning Effort…",
                Menu::Thread,
                Some("mod+shift+e"),
            ),
            (
                Command::AccessMode,
                "composer.mode",
                "Access…",
                Menu::Thread,
                Some("mod+shift+a"),
            ),
            (
                Command::PlanMode,
                "composer.planMode",
                "Plan Mode",
                Menu::Thread,
                None,
            ),
            (
                Command::Rename,
                "thread.rename",
                "Rename…",
                Menu::Thread,
                Some("mod+r"),
            ),
            (
                Command::Pin,
                "thread.pin",
                "Pin or Unpin Thread",
                Menu::Thread,
                Some("mod+shift+p"),
            ),
            (
                Command::Archive,
                "thread.archive",
                "Archive or Unarchive Thread",
                Menu::Thread,
                Some("mod+w"),
            ),
            (
                Command::CopyPath,
                "thread.copyPath",
                "Copy Path",
                Menu::Thread,
                None,
            ),
            (
                Command::Delete,
                "thread.delete",
                "Delete Thread…",
                Menu::Thread,
                None,
            ),
            (
                Command::ReportIssue,
                "help.reportIssue",
                "Report an Issue…",
                Menu::Help,
                None,
            ),
            (
                Command::RequestFeature,
                "help.requestFeature",
                "Request a Feature…",
                Menu::Help,
                None,
            ),
        ] {
            assert_eq!(command.id(), id);
            assert_eq!(command.title(), title);
            assert_eq!(command.menu(), menu);
            assert_eq!(command.default_shortcut(), default.map(key), "{id}");
        }
        // Every default reaches its own command: none is fixed or shadowed.
        let empty = json!({});
        for command in Command::ALL {
            if let Some(default) = command.default_shortcut() {
                assert!(!default.reserved(), "{}", command.id());
                assert_eq!(resolve(&empty, &default), Some(command), "{}", command.id());
                assert_eq!(menu_shortcut(&empty, command), Some(default));
            }
        }
        assert_eq!(Command::Jump(4).jump_index(), Some(4));
        assert_eq!(Command::Stop.jump_index(), None);
    }
    #[::core::prelude::v1::test]
    fn shifted_punctuation_records_swift_spelling_and_command_equals_reaches_larger() {
        let primary = |event: &mut Keystroke| {
            if cfg!(target_os = "macos") {
                event.modifiers.platform = true;
            } else {
                event.modifiers.control = true;
            }
        };
        // GPUI reports Shift with punctuation as the shifted character.
        let mut event = Keystroke {
            key: "{".into(),
            ..Default::default()
        };
        primary(&mut event);
        let recorded = Shortcut::event(&event).unwrap();
        assert_eq!(recorded.encoded(), "mod+shift+[");
        assert_eq!(
            resolve(&json!({}), &recorded),
            Some(Command::PreviousThread)
        );
        event.key = "[".into();
        event.modifiers.shift = true;
        assert_eq!(Shortcut::event(&event), Some(recorded));
        event.key = "+".into();
        event.modifiers.shift = false;
        assert_eq!(
            resolve(&json!({}), &Shortcut::event(&event).unwrap()),
            Some(Command::Larger)
        );
        // The hidden Command-= alias, only while the default is unchanged.
        assert_eq!(resolve(&json!({}), &key("mod+=")), Some(Command::Larger));
        let moved = json!({"shortcutOverrides":{"view.increaseFontSize":"mod+u"}});
        assert!(resolve(&moved, &key("mod+=")).is_none());
        let taken = json!({"shortcutOverrides":{"thread.copyPath":"mod+="}});
        assert_eq!(resolve(&taken, &key("mod+=")), Some(Command::CopyPath));
    }
    #[::core::prelude::v1::test]
    fn commands_without_defaults_save_only_real_overrides_and_menus_skip_losers() {
        let empty = json!({});
        assert!(binding(&empty, Command::CopyPath).shortcut.is_none());
        let cleared = changed_overrides(&empty, Change::Set(Command::CopyPath, "")).unwrap();
        assert_eq!(cleared, json!({}));
        let set = changed_overrides(&empty, Change::Set(Command::CopyPath, "mod+alt+y")).unwrap();
        assert_eq!(set, json!({"thread.copyPath":"mod+alt+y"}));
        let settings = json!({"shortcutOverrides":set});
        assert!(binding(&settings, Command::CopyPath).customized);
        assert_eq!(
            resolve(&settings, &key("mod+alt+y")),
            Some(Command::CopyPath)
        );
        let blank = json!({"shortcutOverrides":{"thread.delete":""}});
        assert!(!binding(&blank, Command::Delete).customized);
        // A changed shortcut wins; the default command's menu item shows none.
        let clash = json!({"shortcutOverrides":{"thread.rename":"mod+b"}});
        assert_eq!(menu_shortcut(&clash, Command::Rename), Some(key("mod+b")));
        assert_eq!(menu_shortcut(&clash, Command::Sidebar), None);
        let (warnings, _) = messages(&clash, Command::Sidebar);
        assert_eq!(
            warnings,
            vec![format!("{} runs Rename instead.", key("mod+b").display())]
        );
        let (warnings, _) = messages(&clash, Command::Rename);
        assert_eq!(
            warnings,
            vec!["Also assigned to Show or Hide Sidebar.".to_owned()]
        );
    }
    #[::core::prelude::v1::test]
    fn shortcuts_display_and_bind_with_each_platforms_conventions() {
        if cfg!(target_os = "macos") {
            assert_eq!(key("mod+shift+[").display(), "⇧⌘[");
            assert_eq!(key("mod+ctrl+alt+shift+k").display(), "⌃⌥⇧⌘K");
            assert_eq!(key("mod++").display(), "⌘+");
            assert_eq!(key("mod+arrowup").display(), "⌘↑");
            assert_eq!(key("mod+shift+[").keystroke(), "shift-cmd-[");
            assert_eq!(key("mod+-").keystroke(), "cmd--");
            assert_eq!(key("ctrl+esc").keystroke(), "ctrl-escape");
        } else {
            assert_eq!(key("mod+shift+[").display(), "Ctrl+Shift+[");
            assert_eq!(key("mod+alt+arrowup").display(), "Ctrl+Alt+Up");
            assert_eq!(key("mod+shift+[").keystroke(), "ctrl-shift-[");
        }
        assert_eq!(key("f5").display(), "F5");
    }
    #[::core::prelude::v1::test]
    fn terminal_keys_follow_platform_terminal_conventions() {
        let event = |text: &str| {
            let shortcut = key(text);
            let (name, modifiers) = shortcut.physical();
            let mut event = Keystroke {
                key: match name.as_str() {
                    "arrowleft" => "left".into(),
                    "arrowup" => "up".into(),
                    other => other.into(),
                },
                ..Default::default()
            };
            event.modifiers.platform = cfg!(target_os = "macos") && modifiers & MOD != 0;
            event.modifiers.control = modifiers & CTRL != 0;
            event.modifiers.alt = modifiers & ALT != 0;
            event.modifiers.shift = modifiers & SHIFT != 0;
            event
        };
        if cfg!(target_os = "macos") {
            assert_eq!(terminal_key(&event("mod+d")), Some("Split right"));
            assert_eq!(terminal_key(&event("mod+shift+d")), Some("Split down"));
            assert_eq!(terminal_key(&event("mod+k")), Some("Clear"));
            assert_eq!(terminal_key(&event("alt+arrowleft")), Some("Move by word"));
            assert_eq!(terminal_key(&event("mod+b")), None);
        } else {
            assert_eq!(terminal_key(&event("ctrl+shift+t")), Some("New terminal"));
            assert_eq!(terminal_key(&event("ctrl+alt+shift+d")), Some("Split down"));
            assert_eq!(
                terminal_key(&event("ctrl+shift+arrowup")),
                Some("Previous and next command")
            );
            assert_eq!(terminal_key(&event("ctrl+d")), None);
        }
        let (_, notes) = messages(&json!({}), Command::Diff);
        assert_eq!(notes.is_empty(), !cfg!(target_os = "macos"));
    }
}
