//! Swift ThreadTerminals and TerminalHeaderView for the Rust terminal: a tab
//! holds up to four panes in one layout, and each tab shows its terminal's
//! number or job, folder, progress and exit. Pure state; no PTY access.
use super::{PaneId, SplitAxis};
use serde_json::Value;
use std::path::{Path, PathBuf};

/// Swift ThreadTerminals.maximumSessionsPerTab.
pub(super) const MAX_TAB_PANES: usize = 4;
pub(super) const TAB_FULL: &str = "A tab holds at most 4 terminals";

/// One tab's panes, all side by side or all stacked with equal shares. The
/// whole tab takes the layout of its newest split, as in T3 Code.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Layout {
    pub axis: SplitAxis,
    pub panes: Vec<PaneId>,
}
impl Layout {
    pub fn single(pane: PaneId) -> Self {
        Self {
            axis: SplitAxis::Horizontal,
            panes: vec![pane],
        }
    }
    pub fn panes(&self, out: &mut Vec<PaneId>) {
        out.extend_from_slice(&self.panes);
    }
    pub fn full(&self) -> bool {
        self.panes.len() >= MAX_TAB_PANES
    }
    /// Adds `next` right after `target`. False when the tab is full or does
    /// not hold `target`; nothing changes then.
    pub fn split(&mut self, target: PaneId, next: PaneId, axis: SplitAxis) -> bool {
        let Some(index) = self.panes.iter().position(|pane| *pane == target) else {
            return false;
        };
        if self.full() {
            return false;
        }
        self.panes.insert(index + 1, next);
        self.axis = axis;
        true
    }
    pub fn without(mut self, target: PaneId) -> Option<Self> {
        self.panes.retain(|pane| *pane != target);
        (!self.panes.is_empty()).then_some(self)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ProgressState {
    Normal,
    Error,
    Indeterminate,
    Paused,
}
/// An OSC 9;4 report as Core reports it (Swift TerminalProgress).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Progress {
    pub state: ProgressState,
    pub percent: Option<u8>,
}
impl Progress {
    fn parse(value: &Value) -> Option<Self> {
        let state = match value["state"].as_str()? {
            "normal" => ProgressState::Normal,
            "error" => ProgressState::Error,
            "indeterminate" => ProgressState::Indeterminate,
            "paused" => ProgressState::Paused,
            _ => return None,
        };
        let percent = value["percent"]
            .as_u64()
            .map(|percent| percent.min(100) as u8);
        Some(Self { state, percent })
    }
    /// For the tab's tooltip and screen readers.
    pub fn description(&self) -> String {
        match (self.state, self.percent) {
            (ProgressState::Normal, Some(percent)) => format!("{percent}% done"),
            (ProgressState::Normal | ProgressState::Indeterminate, _) => "Working".into(),
            (ProgressState::Error, Some(percent)) => format!("Failed at {percent}%"),
            (ProgressState::Error, None) => "Failed".into(),
            (ProgressState::Paused, Some(percent)) => format!("Paused at {percent}%"),
            (ProgressState::Paused, None) => "Paused".into(),
        }
    }
    /// A ring in place of the tab's icon while working.
    pub fn ring(&self) -> bool {
        matches!(
            self.state,
            ProgressState::Normal | ProgressState::Indeterminate
        )
    }
}

/// What `terminal.status` reports for one terminal (Swift TerminalSession's
/// title, isBusy, directory, progress and state).
#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct PaneStatus {
    pub number: u64,
    /// The foreground job, else "Terminal N".
    pub name: String,
    pub busy: bool,
    pub directory: Option<String>,
    pub exited: bool,
    /// The shell failed right after starting: its pane stays to show why.
    pub keep_open: bool,
    pub exit_message: Option<String>,
    pub progress: Option<Progress>,
    pub bells: u64,
}
impl PaneStatus {
    pub fn parse(entry: &Value) -> Option<Self> {
        Some(Self {
            number: entry["number"].as_u64()?,
            name: entry["name"].as_str()?.to_owned(),
            busy: entry["busy"] == true,
            directory: entry["directory"]
                .as_str()
                .filter(|path| !path.is_empty())
                .map(str::to_owned),
            exited: entry["exited"] == true,
            keep_open: entry["keepOpen"] == true,
            exit_message: entry["exitMessage"].as_str().map(str::to_owned),
            progress: Progress::parse(&entry["progress"]),
            bells: entry["bells"].as_u64().unwrap_or(0),
        })
    }
}

/// `~/project` for a folder under the home folder, as AppKit abbreviates.
pub(super) fn abbreviate(path: &str) -> String {
    let home = std::env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .ok()
        .filter(|home| home.len() > 1);
    abbreviate_under(path, home.as_deref())
}
fn abbreviate_under(path: &str, home: Option<&str>) -> String {
    let Some(home) = home.map(|home| home.trim_end_matches(['/', '\\'])) else {
        return path.into();
    };
    match path.strip_prefix(home) {
        Some("") => "~".into(),
        Some(rest) if rest.starts_with(['/', '\\']) => format!("~{rest}"),
        _ => path.into(),
    }
}

/// The tab's tooltip: every terminal of the tab with its folder, then the
/// active terminal's progress.
pub(super) fn tab_tooltip<'a>(
    panes: impl IntoIterator<Item = &'a PaneStatus>,
    progress: Option<Progress>,
) -> String {
    let mut lines = panes
        .into_iter()
        .map(|pane| match &pane.directory {
            Some(directory) => format!("{} — {}", pane.name, abbreviate(directory)),
            None => pane.name.clone(),
        })
        .collect::<Vec<_>>();
    if let Some(progress) = progress {
        lines.push(progress.description());
    }
    lines.join("\n")
}

/// Swift confirmClosing: the alert's title and text when closing would stop
/// running jobs, or None when every shell is idle.
pub(super) fn close_confirmation(busy: &[String]) -> Option<(String, String)> {
    match busy {
        [] => None,
        [name] => Some((
            "Close this terminal?".into(),
            format!("“{name}” is still running. Closing the terminal stops it."),
        )),
        names => Some((
            "Close these terminals?".into(),
            format!(
                "{} are still running. Closing the terminals stops them.",
                list(names)
            ),
        )),
    }
}
/// ListFormatter's English conjunction of quoted names.
fn list(names: &[String]) -> String {
    let quoted = names
        .iter()
        .map(|name| format!("“{name}”"))
        .collect::<Vec<_>>();
    match quoted.as_slice() {
        [] => String::new(),
        [one] => one.clone(),
        [first, second] => format!("{first} and {second}"),
        [rest @ .., last] => format!("{}, and {last}", rest.join(", ")),
    }
}

/// The terminal's own keys, for its buttons' tooltips.
pub(super) fn new_terminal_shortcut() -> &'static str {
    if cfg!(target_os = "macos") {
        "⌘T"
    } else {
        "Ctrl+Shift+T"
    }
}
pub(super) fn split_shortcut(axis: SplitAxis) -> &'static str {
    match (axis, cfg!(target_os = "macos")) {
        (SplitAxis::Horizontal, true) => "⌘D",
        (SplitAxis::Vertical, true) => "⇧⌘D",
        (SplitAxis::Horizontal, false) => "Ctrl+Shift+D",
        (SplitAxis::Vertical, false) => "Ctrl+Alt+Shift+D",
    }
}
/// Swift's Reveal in Finder, named for the platform's file manager.
pub(super) fn reveal_label() -> &'static str {
    if cfg!(target_os = "macos") {
        "Reveal in Finder"
    } else if cfg!(windows) {
        "Show in File Explorer"
    } else {
        "Show in File Manager"
    }
}

/// What a Command- or Control-click in the terminal opens (Swift TerminalLinks).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Link {
    /// A web or mail link, opened directly.
    Web(String),
    /// An existing file or folder, shown in the file manager rather than
    /// opened with its default app.
    File(PathBuf),
}
/// The link under `col` in one row of a frame: an OSC 8 target, else a URL or
/// path written in the text, which may end in a `:line` or `:line:column`.
pub(super) fn link_at(frame: &Value, cells: &[Value], col: usize) -> Option<String> {
    let cell = cells.get(col)?;
    if let Some(uri) = cell["link"]
        .as_u64()
        .and_then(|index| frame["links"][index as usize].as_str())
    {
        return Some(uri.to_owned());
    }
    let mut text = String::new();
    let mut starts = Vec::with_capacity(cells.len());
    for cell in cells {
        // A wide glyph's trailing half starts where the glyph does.
        let lead = starts
            .last()
            .copied()
            .filter(|_| cell["continuation"] == true);
        starts.push(lead.unwrap_or(text.len()));
        if cell["continuation"] != true {
            text.push_str(
                cell["text"]
                    .as_str()
                    .filter(|t| !t.is_empty())
                    .unwrap_or(" "),
            );
        }
    }
    let breaks = |c: char| {
        c.is_whitespace()
            || matches!(
                c,
                '"' | '\'' | '`' | '<' | '>' | '(' | ')' | '[' | ']' | '{' | '}' | '|'
            )
    };
    let at = starts[col];
    if text[at..].chars().next().is_none_or(breaks) {
        return None;
    }
    let start = text[..at]
        .char_indices()
        .rev()
        .find(|(_, c)| breaks(*c))
        .map_or(0, |(index, c)| index + c.len_utf8());
    let end = text[at..]
        .find(breaks)
        .map_or(text.len(), |index| at + index);
    let word = text[start..end].trim_end_matches(['.', ',', ';', ':', '!', '?']);
    (!word.is_empty()).then(|| word.to_owned())
}
/// Resolves a URL, or a path that may be relative to the shell's folder.
/// Other schemes and paths that don't exist resolve to nothing.
pub(super) fn resolve_link(
    link: &str,
    directory: Option<&Path>,
    home: Option<&Path>,
) -> Option<Link> {
    let text = link.trim();
    if let Some((scheme, rest)) = text.split_once(':')
        && scheme.len() > 1
        && scheme.starts_with(|c: char| c.is_ascii_alphabetic())
        && scheme
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    {
        let scheme = scheme.to_ascii_lowercase();
        if scheme == "file" {
            let path = rest
                .strip_prefix("//localhost")
                .or_else(|| rest.strip_prefix("//"))?;
            let path = PathBuf::from(path);
            return (path.is_absolute() && path.exists()).then_some(Link::File(path));
        }
        if rest.starts_with("//") || matches!(scheme.as_str(), "mailto" | "tel" | "news" | "magnet")
        {
            return matches!(scheme.as_str(), "http" | "https" | "mailto")
                .then(|| Link::Web(text.to_owned()));
        }
    }
    let mut candidates = vec![text];
    if let Some(location) = location_suffix(text) {
        candidates.push(&text[..location]);
    }
    for candidate in candidates {
        let expanded = match (candidate.strip_prefix('~'), home) {
            (Some(rest), Some(home)) if rest.is_empty() || rest.starts_with(['/', '\\']) => {
                home.join(rest.trim_start_matches(['/', '\\']))
            }
            _ => PathBuf::from(candidate),
        };
        let path = if expanded.is_absolute() {
            expanded
        } else {
            directory?.join(expanded)
        };
        if path.exists() {
            return Some(Link::File(path));
        }
    }
    None
}
/// A word meant as a link even when it can't be opened, which beeps.
pub(super) fn looks_like_link(word: &str) -> bool {
    word.contains("://")
        || word.contains(['/', '\\'])
        || word.starts_with(['~', '.'])
        || word.starts_with("mailto:")
}
/// Where a trailing `:line` or `:line:column` begins.
fn location_suffix(text: &str) -> Option<usize> {
    let mut end = text.len();
    for _ in 0..2 {
        let Some(colon) = text[..end].rfind(':') else {
            break;
        };
        let digits = &text[colon + 1..end];
        if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            break;
        }
        end = colon;
    }
    (end < text.len()).then_some(end)
}

/// The system alert sound, for a terminal bell or a full tab.
pub(super) fn beep() {
    #[cfg(target_os = "macos")]
    {
        #[link(name = "AppKit", kind = "framework")]
        unsafe extern "C" {
            fn NSBeep();
        }
        unsafe { NSBeep() };
    }
    #[cfg(target_os = "windows")]
    unsafe {
        let _ = windows::Win32::System::Diagnostics::Debug::MessageBeep(
            windows::Win32::UI::WindowsAndMessaging::MB_OK,
        );
    }
    #[cfg(target_os = "linux")]
    if gtk::is_initialized_main_thread()
        && let Some(display) = gtk::gdk::Display::default()
    {
        display.beep();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[::core::prelude::v1::test]
    fn a_tab_holds_four_panes_in_one_layout_that_its_newest_split_sets() {
        let mut layout = Layout::single(1);
        assert!(layout.split(1, 2, SplitAxis::Horizontal));
        assert!(layout.split(1, 3, SplitAxis::Vertical));
        // The new pane goes right after the active one; the whole tab stacks.
        assert_eq!(layout.panes, [1, 3, 2]);
        assert_eq!(layout.axis, SplitAxis::Vertical);
        assert!(
            !layout.split(9, 4, SplitAxis::Horizontal),
            "not in this tab"
        );
        assert!(layout.split(2, 4, SplitAxis::Horizontal));
        assert!(layout.full());
        let before = layout.clone();
        assert!(!layout.split(4, 5, SplitAxis::Vertical));
        assert_eq!(layout, before, "a full tab is unchanged");
        let layout = layout.without(3).unwrap();
        assert_eq!(layout.panes, [1, 2, 4]);
        assert_eq!(layout.axis, SplitAxis::Horizontal);
        let mut out = vec![];
        layout.panes(&mut out);
        assert_eq!(out, [1, 2, 4]);
        let layout = layout.without(1).unwrap().without(2).unwrap();
        assert_eq!(layout.panes, [4]);
        assert!(layout.without(4).is_none());
    }

    #[::core::prelude::v1::test]
    fn listed_status_names_jobs_folders_progress_and_failed_starts() {
        let status = PaneStatus::parse(&json!({
            "number": 2, "name": "cargo", "busy": true, "directory": "/synthetic/home/project",
            "exited": false, "keepOpen": false, "exitMessage": null,
            "progress": {"state":"normal","percent":40}, "bells": 3,
        }))
        .unwrap();
        assert_eq!(status.name, "cargo");
        assert!(status.busy);
        assert_eq!(
            status.progress,
            Some(Progress {
                state: ProgressState::Normal,
                percent: Some(40)
            })
        );
        assert_eq!(status.bells, 3);
        let failed = PaneStatus::parse(&json!({
            "number": 1, "name": "Terminal 1", "exited": true, "keepOpen": true,
            "exitMessage": "Process exited with code 127.", "directory": "",
        }))
        .unwrap();
        assert!(failed.exited && failed.keep_open && !failed.busy);
        assert_eq!(failed.directory, None);
        assert!(PaneStatus::parse(&json!({"name":"no number"})).is_none());
        assert_eq!(
            tab_tooltip([&failed, &status], status.progress,),
            format!(
                "Terminal 1\ncargo — {}\n40% done",
                abbreviate("/synthetic/home/project")
            )
        );
    }

    #[::core::prelude::v1::test]
    fn progress_descriptions_and_rings_follow_swift() {
        let progress = |state, percent| Progress { state, percent };
        let cases = [
            (progress(ProgressState::Normal, Some(5)), "5% done", true),
            (progress(ProgressState::Normal, None), "Working", true),
            (
                progress(ProgressState::Indeterminate, None),
                "Working",
                true,
            ),
            (
                progress(ProgressState::Error, Some(70)),
                "Failed at 70%",
                false,
            ),
            (progress(ProgressState::Error, None), "Failed", false),
            (
                progress(ProgressState::Paused, Some(9)),
                "Paused at 9%",
                false,
            ),
            (progress(ProgressState::Paused, None), "Paused", false),
        ];
        for (progress, description, ring) in cases {
            assert_eq!(progress.description(), description);
            assert_eq!(progress.ring(), ring, "{description}");
        }
        assert_eq!(
            Progress::parse(&json!({"state":"normal","percent":400}))
                .unwrap()
                .percent,
            Some(100)
        );
        assert!(Progress::parse(&json!({"state":"other"})).is_none());
        assert!(Progress::parse(&Value::Null).is_none());
    }

    #[::core::prelude::v1::test]
    fn closing_asks_only_for_running_jobs_with_swift_wording() {
        assert_eq!(close_confirmation(&[]), None);
        assert_eq!(
            close_confirmation(&["vim".into()]).unwrap(),
            (
                "Close this terminal?".into(),
                "“vim” is still running. Closing the terminal stops it.".into()
            )
        );
        assert_eq!(
            close_confirmation(&["vim".into(), "cargo".into()])
                .unwrap()
                .1,
            "“vim” and “cargo” are still running. Closing the terminals stops them."
        );
        let (title, text) =
            close_confirmation(&["vim".into(), "cargo".into(), "npm".into()]).unwrap();
        assert_eq!(title, "Close these terminals?");
        assert_eq!(
            text,
            "“vim”, “cargo”, and “npm” are still running. Closing the terminals stops them."
        );
    }

    #[::core::prelude::v1::test]
    fn clicked_words_resolve_to_web_links_and_existing_paths_with_locations() {
        let row = |text: &str| {
            text.chars()
                .map(|c| json!({"text": c.to_string(), "width": 1}))
                .collect::<Vec<_>>()
        };
        let frame = json!({"links": ["https://example.com/osc8"]});
        let cells = row("see https://example.com/a?b=1. and (src/main.rs:12:3)");
        assert_eq!(
            link_at(&frame, &cells, 10).as_deref(),
            Some("https://example.com/a?b=1")
        );
        assert_eq!(
            link_at(&frame, &cells, 45).as_deref(),
            Some("src/main.rs:12:3")
        );
        assert_eq!(link_at(&frame, &cells, 3), None, "a space is no link");
        let mut linked = row("click");
        linked[2]["link"] = json!(0);
        assert_eq!(
            link_at(&frame, &linked, 2).as_deref(),
            Some("https://example.com/osc8")
        );
        // A wide glyph's trailing half belongs to the glyph.
        let wide = vec![
            json!({"text":"x","width":1}),
            json!({"text":"界","width":2}),
            json!({"text":"","width":0,"continuation":true}),
            json!({"text":" ","width":1}),
        ];
        assert_eq!(link_at(&frame, &wide, 2).as_deref(), Some("x界"));
        assert_eq!(link_at(&frame, &wide, 3), None);

        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir(root.path().join("src")).unwrap();
        std::fs::write(root.path().join("src/main.rs"), "").unwrap();
        let file = root.path().join("src/main.rs");
        assert_eq!(
            resolve_link("src/main.rs:12:3", Some(root.path()), None),
            Some(Link::File(root.path().join("src/main.rs")))
        );
        assert_eq!(
            resolve_link("main.rs:7", Some(&root.path().join("src")), None),
            Some(Link::File(root.path().join("src").join("main.rs")))
        );
        assert_eq!(
            resolve_link("~/main.rs", None, Some(&root.path().join("src"))),
            Some(Link::File(root.path().join("src").join("main.rs")))
        );
        let absolute = file.display().to_string();
        assert_eq!(
            resolve_link(&absolute, None, None),
            Some(Link::File(file.clone()))
        );
        assert_eq!(
            resolve_link(&format!("file://{absolute}"), None, None),
            Some(Link::File(file))
        );
        assert_eq!(resolve_link("missing.rs", Some(root.path()), None), None);
        assert_eq!(resolve_link("relative.rs", None, None), None);
        assert_eq!(
            resolve_link("https://example.com", None, None),
            Some(Link::Web("https://example.com".into()))
        );
        assert_eq!(
            resolve_link("mailto:someone@example.com", None, None),
            Some(Link::Web("mailto:someone@example.com".into()))
        );
        // Other schemes need consent Coincide's terminal doesn't ask for.
        assert_eq!(resolve_link("ssh://host", None, None), None);
        assert_eq!(resolve_link("tel:123", None, None), None);
        assert!(looks_like_link("ssh://host") && looks_like_link("./gone"));
        assert!(!looks_like_link("hello"));
    }

    #[::core::prelude::v1::test]
    fn folders_under_home_are_abbreviated_like_appkit() {
        let home = Some("/synthetic/home");
        assert_eq!(abbreviate_under("/synthetic/home", home), "~");
        assert_eq!(
            abbreviate_under("/synthetic/home/code/app", home),
            "~/code/app"
        );
        assert_eq!(
            abbreviate_under("/synthetic/homework", home),
            "/synthetic/homework"
        );
        assert_eq!(abbreviate_under("/etc", None), "/etc");
        assert_eq!(
            abbreviate_under("/synthetic/home/x", Some("/synthetic/home/")),
            "~/x"
        );
    }
}
