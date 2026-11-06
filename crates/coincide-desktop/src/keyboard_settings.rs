//! Native shortcut recording for existing Rust commands. Persistence uses Swift's
//! shortcutOverrides IDs/syntax; unsupported imported commands remain untouched.
use super::*;

const MOD: u8 = 1;
const CTRL: u8 = 2;
const ALT: u8 = 4;
const SHIFT: u8 = 8;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    NewThread,
    Palette,
    Sidebar,
    Terminal,
    Schedules,
    Larger,
    Smaller,
    FontReset,
}
impl Command {
    pub const ALL: [Self; 8] = [
        Self::NewThread,
        Self::Palette,
        Self::Sidebar,
        Self::Terminal,
        Self::Schedules,
        Self::Larger,
        Self::Smaller,
        Self::FontReset,
    ];
    fn spec(self) -> (&'static str, &'static str, &'static str) {
        match self {
            Self::NewThread => ("chat.new", "New conversation", "mod+n"),
            Self::Palette => ("commandPalette.toggle", "Command palette", "mod+k"),
            Self::Sidebar => ("sidebar.toggle", "Show or hide conversations", "mod+b"),
            Self::Terminal => ("terminal.toggle", "Show or hide terminal", "mod+j"),
            Self::Schedules => (
                "schedules.show",
                "Show or hide scheduled tasks",
                "mod+alt+s",
            ),
            Self::Larger => (
                "view.increaseFontSize",
                "Increase conversation font size",
                "mod++",
            ),
            Self::Smaller => (
                "view.decreaseFontSize",
                "Decrease conversation font size",
                "mod+-",
            ),
            Self::FontReset => (
                "view.resetFontSize",
                "Reset conversation font size",
                "mod+0",
            ),
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
        Some(Self {
            key: normalized_key(&key.key)?,
            modifiers: modifiers
                | (u8::from(key.modifiers.alt) * ALT)
                | (u8::from(key.modifiers.shift) * SHIFT),
        })
    }
    fn physical(&self) -> (String, u8) {
        let mut modifiers = self.modifiers;
        if !cfg!(target_os = "macos") && modifiers & MOD != 0 {
            modifiers = (modifiers & !MOD) | CTRL;
        }
        // The default Swift Command-Plus is typed as Shift-Equals on these
        // native keyboard events. Explicit Shift-Equals resolves identically.
        if self.key == "+" {
            ("=".into(), modifiers | SHIFT)
        } else {
            (self.key.clone(), modifiers)
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
    fn reserved(&self) -> bool {
        // Fixed application, standard editing, browser Find and composer keys
        // keep their existing native routing, including their shifted variants.
        self.modifiers & (MOD | CTRL) != 0
            && matches!(
                self.key.as_str(),
                "q" | "w"
                    | "h"
                    | "m"
                    | "c"
                    | "x"
                    | "v"
                    | "a"
                    | "z"
                    | "f"
                    | ","
                    | "enter"
                    | "tab"
                    | "space"
            )
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
            (ALT, "Alt"),
            (SHIFT, "Shift"),
        ] {
            if self.modifiers & flag != 0 {
                parts.push(text.to_owned());
            }
        }
        parts.push(self.key.to_uppercase());
        parts.join(" + ")
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
fn binding(settings: &Value, command: Command) -> Binding {
    let (id, _, default) = command.spec();
    let fallback = Shortcut::parse(default);
    let value = overrides(settings)
        .ok()
        .flatten()
        .and_then(|map| map.get(id));
    let Some(value) = value else {
        return Binding {
            shortcut: fallback,
            customized: false,
            issue: None,
        };
    };
    if value.as_str().is_some_and(|s| s.trim().is_empty()) {
        return Binding {
            shortcut: None,
            customized: true,
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
    matches
        .iter()
        .find(|(_, customized)| *customized)
        .or(matches.first())
        .map(|(command, _)| *command)
}
// A native WebKit responder is not represented by a GPUI focus handle. Only
// the two existing app commands keep their former browser-visible ownership.
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
    if terminal
        && !(command == Command::Palette
            && key.physical() == Shortcut::parse("mod+k").unwrap().physical())
    {
        return None;
    }
    if browser && !matches!(command, Command::NewThread | Command::Palette) {
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
            let (id, _, default) = command.spec();
            if raw.is_empty() {
                map.insert(id.into(), json!(""));
            } else {
                let shortcut = Shortcut::parse(raw)
                    .ok_or_else(|| anyhow::anyhow!("That is not a shortcut"))?;
                anyhow::ensure!(
                    shortcut.usable() && !shortcut.reserved(),
                    "That shortcut belongs to typing or a fixed command"
                );
                if shortcut.physical() == Shortcut::parse(default).unwrap().physical() {
                    map.remove(id);
                } else {
                    map.insert(id.into(), json!(shortcut.encoded()));
                }
            }
        }
        Change::Reset(command) => {
            map.remove(command.spec().0);
        }
        Change::ResetSupported => {
            for command in Command::ALL {
                map.remove(command.spec().0);
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
        if key.key == "escape"
            && !key.modifiers.platform
            && !key.modifiers.control
            && !key.modifiers.alt
            && !key.modifiers.shift
        {
            self.cancel_shortcut_recording(window, cx);
            self.settings_status = "Shortcut recording cancelled".into();
        } else if let Some(shortcut) = Shortcut::event(key) {
            if shortcut.reserved() {
                self.cancel_shortcut_recording(window, cx);
                self.settings_status =
                    "That shortcut belongs to a fixed command and was not changed.".into();
                cx.notify();
                return false;
            } else if !shortcut.usable() {
                self.settings_status = "Use Command or Control with a key, or a function key. Fixed editing, Find, Settings, Send and OS keys stay reserved. Escape cancels.".into();
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
    pub(super) fn keyboard_settings(&self, cx: &mut Context<Self>) -> AnyElement {
        let writable = overrides(&self.settings).is_ok();
        let mut panel = div().id("keyboard-settings").track_focus(&self.keyboard.focus).p_3().flex().flex_col().gap_3()
            .child(div().text_lg().child("Keyboard shortcuts"))
            .child(div().text_sm().child("Choose Record, then press a shortcut. Escape cancels. Custom shortcuts take precedence over unchanged defaults; the first customized command below wins a conflict. Focused terminals retain their keys, including custom assignments (the existing Command/Control-K palette shortcut is kept). Browser views retain local keys except New conversation and Palette. Fixed Find, Settings, Send, editing and OS shortcuts stay unchanged."));
        if let Err(error) = overrides(&self.settings) {
            panel = panel.child(div().text_sm().child(error.to_string()));
        }
        let retained = overrides(&self.settings).ok().flatten().map_or(0, |map| {
            map.keys()
                .filter(|id| {
                    !Command::ALL
                        .iter()
                        .any(|command| command.spec().0 == id.as_str())
                })
                .count()
        });
        if retained > 0 {
            panel = panel.child(div().text_sm().child(format!("{retained} imported command override(s) are not available in this preview and are retained unchanged.")));
        }
        for command in Command::ALL {
            let (id, title, _) = command.spec();
            let current = binding(&self.settings, command);
            let recording = self.keyboard.recording == Some(command);
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
                                    format!(
                                        "Record: {}",
                                        current
                                            .shortcut
                                            .as_ref()
                                            .map(Shortcut::label)
                                            .unwrap_or_else(|| "No shortcut".into())
                                    )
                                })
                                .disabled(!writable)
                                .accessibility_label(format!("Record shortcut for {title}"))
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.keyboard.restore = window.focused(cx);
                                    this.keyboard.recording = Some(command);
                                    this.keyboard.reset_confirm = false;
                                    this.keyboard.focus.focus(window, cx);
                                    this.settings_status =
                                        "Press the new shortcut. Escape cancels.".into();
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new(SharedString::from(format!("shortcut-disable-{id}")))
                                .label("Disable")
                                .disabled(!writable || current.shortcut.is_none())
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.save_shortcut(Change::Set(command, ""), window, cx)
                                })),
                        )
                        .child(
                            Button::new(SharedString::from(format!("shortcut-reset-{id}")))
                                .label("Reset")
                                .disabled(
                                    !writable
                                        || overrides(&self.settings)
                                            .ok()
                                            .flatten()
                                            .is_none_or(|map| !map.contains_key(id)),
                                )
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.save_shortcut(Change::Reset(command), window, cx)
                                })),
                        ),
                );
            if let Some(issue) = current.issue {
                row = row.child(div().text_sm().child(issue));
            }
            if let Some(shortcut) = current.shortcut {
                let others: Vec<_> = Command::ALL
                    .into_iter()
                    .filter(|other| {
                        *other != command
                            && binding(&self.settings, *other)
                                .shortcut
                                .is_some_and(|key| key.physical() == shortcut.physical())
                    })
                    .map(|other| other.spec().1)
                    .collect();
                if !others.is_empty() {
                    let winner = resolve(&self.settings, &shortcut).unwrap();
                    row = row.child(div().text_sm().child(format!(
                        "Also assigned to {}. Runs: {}.",
                        others.join(", "),
                        winner.spec().1
                    )));
                }
            }
            panel = panel.child(row);
        }
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
        panel = panel.child(
            Button::new("shortcuts-reset-supported")
                .label("Reset these shortcuts…")
                .disabled(!writable)
                .on_click(cx.listener(|this, _, _, cx| {
                    this.keyboard.reset_confirm = true;
                    cx.notify();
                })),
        );
        if self.keyboard.reset_confirm {
            panel = panel.child(div().flex().flex_wrap().items_center().gap_2().child("Restore defaults for the eight commands above? Other imported shortcuts are kept.")
                .child(Button::new("shortcuts-reset-confirm").label("Restore defaults").on_click(cx.listener(|this,_,window,cx| {this.keyboard.reset_confirm=false; this.save_shortcut(Change::ResetSupported,window,cx); })))
                .child(Button::new("shortcuts-reset-cancel").label("Cancel").on_click(cx.listener(|this,_,_,cx| {this.keyboard.reset_confirm=false; cx.notify();}))));
        }
        panel.into_any_element()
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
            "mod+w",
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
        assert_eq!(
            route(Some(Command::Palette), &key("mod+k"), true, false, false),
            Some(Command::Palette)
        );
        assert_eq!(
            route(Some(Command::Palette), &key("mod+t"), true, false, false),
            None
        );
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
        let source = json!({"appearance":"dark","futureSetting":{"keep":[1,2]},"shortcutOverrides":{"chat.new":"mod+l","terminal.toggle":"","future.command":{"opaque":[7]},"sidebar.search":"mod+alt+f"}});
        let original = source.clone();
        let reset = changed_overrides(&source, Change::ResetSupported).unwrap();
        assert_eq!(
            reset,
            json!({"future.command":{"opaque":[7]},"sidebar.search":"mod+alt+f"})
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
}
