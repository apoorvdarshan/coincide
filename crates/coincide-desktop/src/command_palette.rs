//! Snapshot-only native command palette. Parent binds Cmd/Ctrl-K, supplies
//! snapshots and executes typed events after checking current revision/IDs.
//! This module never touches Engine, files, provider state or composer drafts.
use anyhow::{Result, ensure};
use gpui_kit::{
    base::Disableable,
    component::{
        button::*,
        input::{Input, InputEvent, InputState},
    },
    *,
};
use std::collections::HashSet;

const MAX_ENTRIES: usize = 10_000;
const MAX_BYTES: usize = 16 * 1024 * 1024;
const VISIBLE: usize = 50;
const QUERY_CHARS: usize = 256;
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum PaletteCommand {
    OpenThread {
        thread_id: String,
    },
    /// None means ALL projects, not projectless.
    SelectProject {
        project_id: Option<String>,
    },
    /// None means explicitly projectless, never the current project.
    NewThread {
        project_id: Option<String>,
    },
    OpenSettings,
    ShowSchedules,
    /// Show or hide the GitHub pull requests panel in the inspector.
    TogglePullRequests,
}
impl PaletteCommand {
    fn id(&self) -> Option<&str> {
        match self {
            Self::OpenThread { thread_id } => Some(thread_id),
            Self::SelectProject { project_id } | Self::NewThread { project_id } => {
                project_id.as_deref()
            }
            _ => None,
        }
    }
    fn key(&self) -> String {
        match self {
            Self::OpenThread { thread_id } => format!("thread/{}:{thread_id}", thread_id.len()),
            Self::SelectProject { project_id } => match project_id {
                Some(id) => format!("project/{}:{id}", id.len()),
                None => "project/all".into(),
            },
            Self::NewThread { project_id } => match project_id {
                Some(id) => format!("new-thread/{}:{id}", id.len()),
                None => "new-thread/projectless".into(),
            },
            Self::OpenSettings => "action/settings".into(),
            Self::ShowSchedules => "action/schedules".into(),
            Self::TogglePullRequests => "action/pull-requests".into(),
        }
    }
    fn allocated_bytes(&self) -> usize {
        match self {
            Self::OpenThread { thread_id } => thread_id.capacity(),
            Self::SelectProject { project_id } | Self::NewThread { project_id } => {
                project_id.as_ref().map_or(0, String::capacity)
            }
            _ => 0,
        }
    }
}
#[derive(Clone, Debug)]
pub struct PaletteEntry {
    pub command: PaletteCommand,
    pub title: String,
    pub subtitle: Option<String>,
    pub keywords: Vec<String>,
    pub enabled: bool,
    pub disabled_reason: Option<String>,
}
#[derive(Clone, Debug)]
pub struct PaletteSnapshot {
    pub revision: u64,
    pub entries: Vec<PaletteEntry>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PaletteEvent {
    Activated {
        revision: u64,
        command: PaletteCommand,
    },
    Dismissed,
}
fn bounded_string(s: &str, max: usize) -> bool {
    s.len() <= max * 4 && s.chars().count() <= max && !s.contains('\0')
}
fn validate(snapshot: &PaletteSnapshot) -> Result<()> {
    ensure!(
        snapshot.entries.len() <= MAX_ENTRIES,
        "Palette supports at most 10000 entries"
    );
    let mut bytes = snapshot
        .entries
        .capacity()
        .checked_mul(std::mem::size_of::<PaletteEntry>())
        .unwrap_or(MAX_BYTES + 1);
    let mut ids = HashSet::new();
    for entry in &snapshot.entries {
        ensure!(
            bounded_string(&entry.title, 512) && !entry.title.trim().is_empty(),
            "Palette title must be nonblank and at most 512 characters"
        );
        ensure!(
            entry
                .subtitle
                .as_ref()
                .is_none_or(|s| bounded_string(s, 1024))
                && entry
                    .disabled_reason
                    .as_ref()
                    .is_none_or(|s| bounded_string(s, 512)),
            "Palette subtitle/reason exceeds bounds"
        );
        ensure!(
            entry.keywords.len() <= 32 && entry.keywords.iter().all(|s| bounded_string(s, 128)),
            "Palette keywords exceed 32 x 128 characters"
        );
        ensure!(
            entry
                .command
                .id()
                .is_none_or(|id| !id.trim().is_empty() && bounded_string(id, 128)),
            "Invalid stable palette ID"
        );
        ensure!(
            ids.insert(&entry.command),
            "Duplicate palette command identity"
        );
        for size in [
            entry.title.capacity(),
            entry.subtitle.as_ref().map_or(0, String::capacity),
            entry.disabled_reason.as_ref().map_or(0, String::capacity),
            entry.command.allocated_bytes(),
            entry
                .keywords
                .capacity()
                .saturating_mul(std::mem::size_of::<String>()),
        ]
        .into_iter()
        .chain(entry.keywords.iter().map(String::capacity))
        {
            bytes = bytes.checked_add(size).unwrap_or(MAX_BYTES + 1);
            ensure!(
                bytes <= MAX_BYTES,
                "Palette snapshot exceeds 16 MiB allocated storage"
            );
        }
    }
    ensure!(
        bytes <= MAX_BYTES,
        "Palette snapshot exceeds 16 MiB allocated storage"
    );
    Ok(())
}
fn score(entry: &PaletteEntry, tokens: &[String], phrase: &str) -> Option<usize> {
    if tokens.is_empty() {
        return Some(0);
    }
    let title = entry.title.to_lowercase();
    let subtitle = entry.subtitle.as_deref().unwrap_or("").to_lowercase();
    let keywords = entry
        .keywords
        .iter()
        .map(|s| s.to_lowercase())
        .collect::<Vec<_>>();
    if !tokens.iter().all(|token| {
        title.contains(token)
            || subtitle.contains(token)
            || keywords.iter().any(|s| s.contains(token))
    }) {
        return None;
    }
    Some(if title == phrase {
        0
    } else if title.starts_with(phrase) {
        1
    } else if title.contains(phrase) {
        2
    } else if tokens.iter().all(|t| title.contains(t)) {
        3
    } else {
        4
    })
}
struct Model {
    snapshot: PaletteSnapshot,
    query: String,
    rows: Vec<usize>,
    total: usize,
    selected: Option<PaletteCommand>,
    open: bool,
}
impl Model {
    fn new(snapshot: PaletteSnapshot) -> Result<Self> {
        validate(&snapshot)?;
        let mut m = Self {
            snapshot,
            query: String::new(),
            rows: Vec::new(),
            total: 0,
            selected: None,
            open: true,
        };
        m.rebuild();
        Ok(m)
    }
    fn rebuild(&mut self) {
        let tokens = self
            .query
            .split_whitespace()
            .map(str::to_lowercase)
            .collect::<Vec<_>>();
        let phrase = tokens.join(" ");
        let mut ranked = self
            .snapshot
            .entries
            .iter()
            .enumerate()
            .filter_map(|(i, e)| score(e, &tokens, &phrase).map(|rank| (rank, i)))
            .collect::<Vec<_>>();
        ranked.sort_unstable();
        self.total = ranked.len();
        self.rows = ranked.into_iter().take(VISIBLE).map(|(_, i)| i).collect();
        if !self.selected.as_ref().is_some_and(|selected| {
            self.rows.iter().any(|&i| {
                self.snapshot.entries[i].enabled && &self.snapshot.entries[i].command == selected
            })
        }) {
            self.selected = self
                .rows
                .iter()
                .map(|&i| &self.snapshot.entries[i])
                .find(|e| e.enabled)
                .map(|e| e.command.clone());
        }
    }
    fn query(&mut self, query: &str) {
        self.query = query
            .chars()
            .filter(|ch| *ch != '\0')
            .take(QUERY_CHARS)
            .collect();
        self.selected = None;
        self.rebuild();
    }
    fn replace(&mut self, snapshot: PaletteSnapshot) -> Result<()> {
        ensure!(
            snapshot.revision > self.snapshot.revision,
            "Palette snapshot revision must advance"
        );
        validate(&snapshot)?;
        self.snapshot = snapshot;
        self.rebuild();
        Ok(())
    }
    fn move_by(&mut self, down: bool) {
        let enabled = self
            .rows
            .iter()
            .map(|&i| &self.snapshot.entries[i])
            .filter(|e| e.enabled)
            .map(|e| e.command.clone())
            .collect::<Vec<_>>();
        if enabled.is_empty() {
            self.selected = None;
            return;
        }
        let position = self
            .selected
            .as_ref()
            .and_then(|s| enabled.iter().position(|c| c == s));
        let next = match position {
            None => 0,
            Some(i) if down => (i + 1).min(enabled.len() - 1),
            Some(i) => i.saturating_sub(1),
        };
        self.selected = Some(enabled[next].clone());
    }
    fn activate(&mut self, command: &PaletteCommand) -> Option<PaletteEvent> {
        if !self.open
            || !self.rows.iter().any(|&i| {
                self.snapshot.entries[i].enabled && &self.snapshot.entries[i].command == command
            })
        {
            return None;
        }
        self.open = false;
        Some(PaletteEvent::Activated {
            revision: self.snapshot.revision,
            command: command.clone(),
        })
    }
    fn dismiss(&mut self) -> Option<PaletteEvent> {
        if !self.open {
            return None;
        }
        self.open = false;
        Some(PaletteEvent::Dismissed)
    }
}

pub struct CommandPalette {
    model: Option<Model>,
    input: Entity<InputState>,
    restore: Option<FocusHandle>,
    scroll: ScrollHandle,
    _subscription: Subscription,
}
impl EventEmitter<PaletteEvent> for CommandPalette {}
impl CommandPalette {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder("Search threads, projects and actions")
        });
        let subscription =
            cx.subscribe_in(&input, window, |this, _, event, window, cx| match event {
                InputEvent::Change => {
                    if !this.is_open() {
                        return;
                    }
                    let value = this.input.read(cx).value().to_string();
                    let bounded = value
                        .chars()
                        .filter(|ch| *ch != '\0')
                        .take(QUERY_CHARS)
                        .collect::<String>();
                    if value != bounded {
                        this.input
                            .update(cx, |input, cx| input.set_value(bounded.clone(), window, cx));
                    }
                    if let Some(model) = &mut this.model {
                        model.query(&bounded);
                    }
                    this.scroll_selected();
                    cx.notify();
                }
                InputEvent::PressEnter {
                    secondary: false,
                    shift: false,
                } => this.activate_selected(window, cx),
                _ => {}
            });
        Self {
            model: None,
            input,
            restore: None,
            scroll: ScrollHandle::new(),
            _subscription: subscription,
        }
    }
    pub fn is_open(&self) -> bool {
        self.model.as_ref().is_some_and(|m| m.open)
    }
    /// Validate before changing focus or state. Parent must preserve its draft
    /// normally; the palette never accesses/edits that draft or sends messages.
    pub fn open(
        &mut self,
        snapshot: PaletteSnapshot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<()> {
        let model = Model::new(snapshot)?;
        if !self.is_open() {
            self.restore = window.focused(cx);
        }
        self.model = Some(model);
        self.input
            .update(cx, |input, cx| input.set_value("", window, cx));
        self.input.read(cx).focus_handle(cx).focus(window, cx);
        self.scroll_selected();
        cx.notify();
        Ok(())
    }
    pub fn replace_snapshot(
        &mut self,
        snapshot: PaletteSnapshot,
        cx: &mut Context<Self>,
    ) -> Result<()> {
        let Some(model) = &mut self.model else {
            anyhow::bail!("Palette has not been opened");
        };
        model.replace(snapshot)?;
        self.scroll_selected();
        cx.notify();
        Ok(())
    }
    pub fn dismiss(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(event) = self.model.as_mut().and_then(Model::dismiss) {
            self.finish(event, window, cx);
        }
    }
    fn finish(&mut self, event: PaletteEvent, window: &mut Window, cx: &mut Context<Self>) {
        // Restore BEFORE emitting. Parent may then move focus to the destination
        // of its validated command; Escape never emits an Activated event.
        if let Some(focus) = self.restore.take() {
            focus.focus(window, cx);
        }
        cx.notify();
        cx.emit(event);
    }
    fn activate(&mut self, command: &PaletteCommand, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(event) = self
            .model
            .as_mut()
            .and_then(|model| model.activate(command))
        {
            self.finish(event, window, cx);
        }
    }
    fn activate_selected(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let selected = self.model.as_ref().and_then(|m| m.selected.clone());
        if let Some(selected) = selected {
            self.activate(&selected, window, cx);
        }
    }
    fn scroll_selected(&self) {
        if let Some(model) = &self.model
            && let Some(i) = model
                .rows
                .iter()
                .position(|&i| Some(&model.snapshot.entries[i].command) == model.selected.as_ref())
        {
            self.scroll.scroll_to_item(i);
        }
    }
    fn key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if !self.is_open() {
            return;
        }
        let key = &event.keystroke;
        if key.modifiers.control
            || key.modifiers.platform
            || key.modifiers.alt
            || key.modifiers.shift
        {
            return;
        }
        match key.key.as_str() {
            "up" | "down" => {
                if let Some(model) = &mut self.model {
                    model.move_by(key.key == "down");
                }
                self.scroll_selected();
                cx.notify();
            }
            "escape" => self.dismiss(window, cx),
            // Enter stays in native InputState and reaches PressEnter only after
            // input processing. Other text/editing keys are not intercepted.
            _ => return,
        }
        cx.stop_propagation();
    }
}
impl Render for CommandPalette {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if !self.is_open() {
            return div().into_any_element();
        }
        let mut pane = div()
            .id("command-palette")
            .w_full()
            .max_w(px(680.))
            .max_h(px(580.))
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .border_1()
            .capture_key_down(cx.listener(|this, event, window, cx| this.key(event, window, cx)))
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(div().flex_1().child("Commands, threads and projects"))
                    .child(
                        Button::new("palette-close")
                            .label("Close · Esc")
                            .on_click(cx.listener(|this, _, window, cx| this.dismiss(window, cx))),
                    ),
            )
            .child(Input::new(&self.input));
        let mut list = div()
            .id("command-palette-results")
            .flex_1()
            .min_h_0()
            .max_h(px(420.))
            .overflow_y_scroll()
            .track_scroll(&self.scroll)
            .flex()
            .flex_col()
            .gap_1();
        if let Some(model) = &self.model {
            for &index in &model.rows {
                let entry = &model.snapshot.entries[index];
                let command = entry.command.clone();
                let selected = model.selected.as_ref() == Some(&command);
                let subtitle = entry.subtitle.as_deref().unwrap_or("");
                let disabled = if entry.enabled {
                    ""
                } else {
                    entry.disabled_reason.as_deref().unwrap_or("Unavailable")
                };
                list = list.child(
                    Button::new(SharedString::from(format!("palette-{}", command.key())))
                        .label(format!(
                            "{}{}\n{}{}{}",
                            if selected { "› " } else { "" },
                            entry.title,
                            subtitle,
                            if disabled.is_empty() { "" } else { " · " },
                            disabled
                        ))
                        .disabled(!entry.enabled)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.activate(&command, window, cx)
                        })),
                );
            }
            if model.rows.is_empty() {
                list = list.child("No matching threads, projects or actions.");
            }
            pane = pane.child(list).child(div().text_sm().child(format!(
                "{} matches · showing up to 50 · ↑/↓ select · Enter opens · Esc cancels",
                model.total
            )));
        }
        pane.into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        MAX_BYTES, MAX_ENTRIES, Model, PaletteCommand as Command, PaletteEntry, PaletteEvent,
        PaletteSnapshot, validate,
    };
    fn entry(id: &str, title: &str) -> PaletteEntry {
        PaletteEntry {
            command: Command::OpenThread {
                thread_id: id.into(),
            },
            title: title.into(),
            subtitle: None,
            keywords: Vec::new(),
            enabled: true,
            disabled_reason: None,
        }
    }
    fn snapshot(revision: u64, entries: Vec<PaletteEntry>) -> PaletteSnapshot {
        PaletteSnapshot { revision, entries }
    }
    fn titles(model: &Model) -> Vec<&str> {
        model
            .rows
            .iter()
            .map(|&i| model.snapshot.entries[i].title.as_str())
            .collect()
    }
    #[::core::prelude::v1::test]
    fn unicode_case_insensitive_search_ranks_exact_then_prefix_then_substring() {
        let mut m = Model::new(snapshot(
            1,
            vec![
                entry("1", "Fix CAFÉ 中文"),
                entry("2", "Café 中文 guide"),
                entry("3", "café 中文"),
            ],
        ))
        .unwrap();
        m.query("  CAFÉ   中文 ");
        assert_eq!(
            titles(&m),
            vec!["café 中文", "Café 中文 guide", "Fix CAFÉ 中文"]
        );
        m.query("👩🏽‍💻");
        assert!(m.rows.is_empty());
        assert!(m.selected.is_none());
    }
    #[::core::prelude::v1::test]
    fn every_token_must_match_title_subtitle_or_supplied_keyword() {
        let mut target = entry("1", "Build preview");
        target.subtitle = Some("Workspace desktop".into());
        target.keywords = vec!["Swift".into(), "Rust".into()];
        let mut m = Model::new(snapshot(1, vec![target, entry("2", "Build server")])).unwrap();
        m.query("RUST desktop build");
        assert_eq!(titles(&m), vec!["Build preview"]);
        m.query("rust absent");
        assert!(m.rows.is_empty());
        m.query(&"中".repeat(300));
        assert_eq!(m.query.chars().count(), 256);
        assert!(m.query.is_char_boundary(m.query.len()));
    }
    #[::core::prelude::v1::test]
    fn revision_replacement_preserves_identity_across_reorder_and_refuses_removed_click() {
        let a = entry("a", "Same title");
        let b = entry("b", "Same title");
        let mut m = Model::new(snapshot(5, vec![a.clone(), b.clone()])).unwrap();
        m.move_by(true);
        assert_eq!(m.selected, Some(b.command.clone()));
        m.replace(snapshot(6, vec![b.clone(), a.clone()])).unwrap();
        assert_eq!(m.selected, Some(b.command.clone()));
        m.replace(snapshot(7, vec![a.clone()])).unwrap();
        assert_eq!(m.selected, Some(a.command.clone()));
        assert!(m.activate(&b.command).is_none());
        assert!(m.open);
        assert_eq!(
            m.activate(&a.command),
            Some(PaletteEvent::Activated {
                revision: 7,
                command: a.command.clone()
            })
        );
        assert!(m.activate(&a.command).is_none());
    }
    #[::core::prelude::v1::test]
    fn disabled_selection_is_replaced_and_navigation_skips_unavailable_rows() {
        let a = entry("a", "A");
        let mut disabled = entry("b", "B");
        disabled.enabled = false;
        disabled.disabled_reason = Some("Unavailable".into());
        let c = entry("c", "C");
        let mut m = Model::new(snapshot(1, vec![a.clone(), disabled.clone(), c.clone()])).unwrap();
        m.move_by(true);
        assert_eq!(m.selected, Some(c.command.clone()));
        m.move_by(true);
        assert_eq!(m.selected, Some(c.command.clone()));
        m.move_by(false);
        assert_eq!(m.selected, Some(a.command.clone()));
        m.move_by(false);
        assert_eq!(m.selected, Some(a.command.clone()));
        assert!(m.activate(&disabled.command).is_none());
        let mut changed = a;
        changed.enabled = false;
        m.replace(snapshot(2, vec![changed, disabled, c.clone()]))
            .unwrap();
        assert_eq!(m.selected, Some(c.command));
    }
    #[::core::prelude::v1::test]
    fn none_semantics_are_typed_distinct_and_never_resolve_current_project() {
        let all = Command::SelectProject { project_id: None };
        let projectless = Command::NewThread { project_id: None };
        assert_ne!(all, projectless);
        assert_ne!(all.key(), projectless.key());
        let mut item = entry("unused", "All projects");
        item.command = all.clone();
        let mut other = entry("unused", "New chat");
        other.command = projectless.clone();
        let mut m = Model::new(snapshot(9, vec![item, other])).unwrap();
        assert_eq!(
            m.activate(&all),
            Some(PaletteEvent::Activated {
                revision: 9,
                command: all
            })
        );
        assert!(matches!(
            projectless,
            Command::NewThread { project_id: None }
        ));
    }
    #[::core::prelude::v1::test]
    fn escape_dismisses_without_activation_and_empty_query_keeps_supplied_order() {
        let a = entry("a", "Z recent");
        let b = entry("b", "A older");
        let mut m = Model::new(snapshot(1, vec![a.clone(), b])).unwrap();
        assert_eq!(titles(&m), vec!["Z recent", "A older"]);
        assert_eq!(m.dismiss(), Some(PaletteEvent::Dismissed));
        assert!(m.activate(&a.command).is_none());
        assert!(m.dismiss().is_none());
        let mut m = Model::new(snapshot(1, vec![])).unwrap();
        m.move_by(true);
        m.move_by(false);
        assert!(m.selected.is_none());
    }
    #[::core::prelude::v1::test]
    fn invalid_or_stale_snapshot_replacement_is_atomic() {
        let a = entry("a", "A");
        let mut m = Model::new(snapshot(10, vec![a.clone()])).unwrap();
        assert!(m.replace(snapshot(10, vec![entry("b", "B")])).is_err());
        assert!(m.replace(snapshot(9, vec![])).is_err());
        assert!(m.replace(snapshot(11, vec![a.clone(), a.clone()])).is_err());
        assert_eq!(m.snapshot.revision, 10);
        assert_eq!(m.selected, Some(a.command));
        assert_eq!(titles(&m), vec!["A"]);
    }
    #[::core::prelude::v1::test]
    fn per_entry_strings_keywords_and_ids_are_bounded_by_unicode_characters() {
        let mut e = entry("id", &"中".repeat(512));
        assert!(validate(&snapshot(1, vec![e.clone()])).is_ok());
        e.title.push('中');
        assert!(validate(&snapshot(1, vec![e])).is_err());
        let mut e = entry("id", "title");
        e.subtitle = Some("x".repeat(1025));
        assert!(validate(&snapshot(1, vec![e])).is_err());
        let mut e = entry("id", "title");
        e.keywords = vec!["word".into(); 33];
        assert!(validate(&snapshot(1, vec![e])).is_err());
        let mut e = entry("id", "title");
        e.keywords = vec!["x".repeat(129)];
        assert!(validate(&snapshot(1, vec![e])).is_err());
        assert!(validate(&snapshot(1, vec![entry(&"x".repeat(129), "title")])).is_err());
        assert!(validate(&snapshot(1, vec![entry("id", "text\0text")])).is_err());
    }
    #[::core::prelude::v1::test]
    fn total_memory_and_row_count_bounds_include_reserved_capacity() {
        let mut e = entry("id", "small");
        let mut overallocated = String::with_capacity(MAX_BYTES + 1);
        overallocated.push('x');
        e.title = overallocated;
        assert!(validate(&snapshot(1, vec![e])).is_err());
        let rows = (0..=MAX_ENTRIES)
            .map(|i| entry(&i.to_string(), "row"))
            .collect();
        assert!(validate(&snapshot(1, rows)).is_err());
    }
    #[::core::prelude::v1::test]
    fn visible_limit_and_distinct_same_title_commands_do_not_use_row_index_identity() {
        let entries = (0..60)
            .map(|i| entry(&format!("thread-{i}"), "Same title"))
            .collect::<Vec<_>>();
        let hidden = entries[59].command.clone();
        let mut m = Model::new(snapshot(1, entries)).unwrap();
        assert_eq!(m.total, 60);
        assert_eq!(m.rows.len(), 50);
        for _ in 0..100 {
            m.move_by(true);
        }
        assert_eq!(
            m.selected,
            Some(Command::OpenThread {
                thread_id: "thread-49".into()
            })
        );
        assert!(m.activate(&hidden).is_none());
        let settings = Command::OpenSettings;
        let schedules = Command::ShowSchedules;
        assert_ne!(settings.key(), schedules.key());
    }
}
