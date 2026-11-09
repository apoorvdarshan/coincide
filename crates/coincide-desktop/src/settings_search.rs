//! Settings search from Swift's SettingsSearchResults: one entry per pane,
//! provider page, subpage or General row, titled with its pane underneath.
//! Choosing a row opens its pane, scrolls to the row and highlights it.
use super::*;
use settings::SettingsSection as Section;
use std::{cell::RefCell, collections::HashMap};

/// General rows a search can reveal, as Swift's `SettingsRowID`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) enum Row {
    Appearance,
    FontSize,
    DarkTheme,
    LightTheme,
    ReplyTypeface,
    TerminalPlacement,
    OpenIn,
    UserMessageSide,
    ShowReasoning,
    SendShortcut,
    FollowUpBehavior,
    AccessMode,
    NewThreadChat,
    HoldToQuit,
    ConfirmDelete,
    ConfirmArchive,
    Notifications,
    KeepAwake,
    Remote,
    CommandLine,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Destination {
    Pane(Section, Option<Row>),
    /// A page opened from a pane, by its Settings button id.
    Subpage(Section, &'static str),
}
impl Destination {
    fn pane(self) -> Section {
        match self {
            Self::Pane(section, _) | Self::Subpage(section, _) => section,
        }
    }
}

pub(super) struct Entry {
    pub(super) title: SharedString,
    pub(super) destination: Destination,
    keywords: Vec<&'static str>,
}
impl Entry {
    fn new(title: &'static str, destination: Destination, keywords: &[&'static str]) -> Self {
        Self {
            title: title.into(),
            destination,
            keywords: keywords.to_vec(),
        }
    }
    /// Swift's `localizedStandardContains`: the whole query, ignoring case.
    pub(super) fn matches(&self, query: &str) -> bool {
        let query = query
            .trim()
            .chars()
            .take(256)
            .collect::<String>()
            .to_lowercase();
        !query.is_empty()
            && std::iter::once(self.title.as_ref())
                .chain(self.keywords.iter().copied())
                .any(|text| text.to_lowercase().contains(&query))
    }
    /// The pane shown under the title; none for a pane's own entry, whose
    /// title already names it.
    pub(super) fn subtitle(&self) -> Option<&'static str> {
        let pane = self.destination.pane().label();
        (pane != self.title.as_ref()).then_some(pane)
    }
}

#[cfg(target_os = "macos")]
const HOLD_TO_QUIT: &str = "Hold Command + Q to quit";
#[cfg(not(target_os = "macos"))]
const HOLD_TO_QUIT: &str = "Hold Control + Q to quit";

pub(super) fn entries() -> Vec<Entry> {
    use Destination::{Pane, Subpage};
    use Section as S;
    let general = |row| Pane(S::General, Some(row));
    let mut entries = vec![
        Entry::new(
            "Usage",
            Pane(S::Usage, None),
            &[
                "Account limits",
                "Tokens",
                "Cost",
                "Credits",
                "Codex limits",
            ],
        ),
        Entry::new(
            "Appearance",
            general(Row::Appearance),
            &["Dark mode", "Light mode", "Theme", "System"],
        ),
        Entry::new("Font size", general(Row::FontSize), &["Text size", "Zoom"]),
        Entry::new(
            "Dark theme",
            general(Row::DarkTheme),
            &["Theme", "Colors", "Dark mode"],
        ),
        Entry::new(
            "Light theme",
            general(Row::LightTheme),
            &["Theme", "Colors", "Light mode"],
        ),
        Entry::new(
            "Reply font",
            general(Row::ReplyTypeface),
            &["Serif", "Typeface", "New York"],
        ),
        Entry::new(
            "Your messages",
            general(Row::UserMessageSide),
            &["Chat layout", "Message alignment", "Right", "Left"],
        ),
        Entry::new(
            "Terminal",
            general(Row::TerminalPlacement),
            &["Bottom panel", "Right panel", "Shell", "Layout"],
        ),
        Entry::new(
            "Open project folders in",
            general(Row::OpenIn),
            &[
                "Open In",
                "Editor",
                "VS Code",
                "Cursor",
                "Finder",
                "File manager",
                "Terminal",
            ],
        ),
        Entry::new(
            "Send messages with",
            general(Row::SendShortcut),
            &["Return", "Enter", "New line"],
        ),
        Entry::new(
            "Follow-up behavior for new threads",
            general(Row::FollowUpBehavior),
            &["Steer", "Queue", "Interrupt", "Follow-ups"],
        ),
        Entry::new(
            "Reasoning",
            general(Row::ShowReasoning),
            &["Show reasoning", "Thinking"],
        ),
        Entry::new(
            "Access for new threads",
            general(Row::AccessMode),
            &["Approval", "Permissions", "Full access"],
        ),
        Entry::new(
            "Confirm before deleting threads",
            general(Row::ConfirmDelete),
            &[],
        ),
        Entry::new(
            "Confirm before archiving threads",
            general(Row::ConfirmArchive),
            &[],
        ),
        Entry::new(
            HOLD_TO_QUIT,
            general(Row::HoldToQuit),
            &["Quit", "Keyboard"],
        ),
        Entry::new(
            "New Thread starts a chat",
            general(Row::NewThreadChat),
            &["Chats", "No project", "Shortcut"],
        ),
        Entry::new(
            "Notifications",
            general(Row::Notifications),
            &["Background", "Alerts"],
        ),
        Entry::new(
            "Keep awake during work",
            general(Row::KeepAwake),
            &["Keep Awake", "Sleep", "Display", "Power", "Battery"],
        ),
        Entry::new(
            "Remote",
            Pane(S::Automation, Some(Row::Remote)),
            &[
                "Coincide Remote",
                "iPhone",
                "iPad",
                "Pairing",
                "Tailscale",
                "Network",
            ],
        ),
        Entry::new(
            "Command-line control",
            general(Row::CommandLine),
            &[
                "coincide-rs",
                "Terminal",
                "Command line",
                "CLI",
                "Automation",
            ],
        ),
        Entry::new(
            "Desktop notifications",
            Subpage(S::General, "notifications"),
            &["Allow notifications", "Permission", "Alerts", "Sound"],
        ),
        Entry::new(
            "Bots",
            Subpage(S::General, "bots"),
            &["Bot instructions", "Automation"],
        ),
        Entry::new(
            "Providers",
            Pane(S::Accounts, None),
            &["Agents", "Check again", "Status"],
        ),
        Entry::new(
            "Models",
            Pane(S::Models, None),
            &["Custom model", "Context window", "Favorite", "Hidden"],
        ),
        Entry::new(
            "Instructions",
            Pane(S::Instructions, None),
            &["AGENTS.md", "CLAUDE.md", "GEMINI.md", "Rules", "Memory"],
        ),
        Entry::new(
            "Archive",
            Pane(S::Archive, None),
            &["Archived threads", "Unarchive", "Delete All"],
        ),
        Entry::new(
            "Keyboard shortcuts",
            Pane(S::Keyboard, None),
            &["Keybindings", "Hotkeys"],
        ),
        Entry::new(
            "Voice",
            Pane(S::Voice, None),
            &[
                "Dictation",
                "Speech to text",
                "Microphone",
                "Voice input",
                "dictate",
                "speech",
                "mic",
            ],
        ),
        Entry::new(
            "Dictation engine",
            Pane(S::Voice, None),
            &[
                "Speech recognition",
                "On device",
                "Apple",
                "OpenAI",
                "Groq",
                "Whisper",
            ],
        ),
        Entry::new(
            "Dictation keyboard shortcut",
            Pane(S::Voice, None),
            &[
                "Push to talk",
                "Hold to talk",
                "Tap to toggle",
                "Fn",
                "Hotkey",
            ],
        ),
        Entry::new(
            "Microphone",
            Pane(S::Voice, None),
            &["Input device", "Test microphone", "Level"],
        ),
        Entry::new(
            "OpenAI API key for dictation",
            Pane(S::Voice, None),
            &[
                "OpenAI",
                "whisper-1",
                "Codex",
                "API key",
                "Bring your own key",
                "BYOK",
            ],
        ),
        Entry::new(
            "Groq API key for dictation",
            Pane(S::Voice, None),
            &["Groq", "whisper-large-v3", "API key", "BYOK"],
        ),
        Entry::new(
            "Whisper models",
            Pane(S::Voice, None),
            &[
                "Whisper",
                "Offline",
                "Download",
                "tiny",
                "base",
                "small",
                "Local model",
            ],
        ),
        Entry::new(
            "Browser",
            Pane(S::Browser, None),
            &[
                "Cookies",
                "History",
                "Bookmarks",
                "Import",
                "Profiles",
                "Chrome",
                "Safari",
                "Firefox",
            ],
        ),
        Entry::new(
            "Passwords",
            Subpage(S::Browser, "passwords"),
            &[
                "Password managers",
                "Saved Logins",
                "1Password",
                "Bitwarden",
                "Credentials",
                "Vault",
            ],
        ),
        Entry::new(
            "Computer Use",
            Pane(S::ComputerUse, None),
            &[
                "Accessibility",
                "Screen Recording",
                "Permissions",
                "Automation",
                "desktop",
                "screen",
                "control",
            ],
        ),
        Entry::new(
            "Appshots",
            Pane(S::Appshots, None),
            &[
                "Screenshot",
                "Capture",
                "Window",
                "Shortcut",
                "Window text",
                "Screen Recording",
                "Accessibility",
                "Play a sound",
            ],
        ),
        Entry::new(
            "Historical images",
            Pane(S::Media, None),
            &["Legacy images", "Photos", "Attachments", "Recovery"],
        ),
        Entry::new(
            "About Coincide",
            Pane(S::About, None),
            &["Version", "License", "GitHub", "T3 Code", "X", "Instagram"],
        ),
    ];
    // Help & Community, Follow, and Contact & Legal, in About.
    entries.extend(community_links::LINKS.iter().map(|link| Entry {
        title: link.title.into(),
        destination: Pane(S::About, None),
        keywords: link.keywords.iter().copied().chain(["Help"]).collect(),
    }));
    for provider in coincide_core::provider_catalog::provider_catalog() {
        entries.push(Entry {
            title: provider.display_name.into(),
            destination: Pane(S::Provider(provider.id), None),
            keywords: vec![
                "Install",
                "Sign in",
                "Executable path",
                "Environment variables",
            ],
        });
    }
    entries
}

/// The row a search revealed, highlighted until it fades, and the scroll
/// anchors rows report their positions through.
#[derive(Default)]
pub(super) struct Reveal {
    highlighted: Option<Row>,
    anchors: RefCell<HashMap<(&'static str, Row), ScrollAnchor>>,
    fade: Option<Task<()>>,
}

impl Coincide {
    pub(super) fn settings_search_results(
        &self,
        query: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let results = entries()
            .into_iter()
            .filter(|entry| entry.matches(query))
            .collect::<Vec<_>>();
        let mut list = div().flex().flex_col().gap_1();
        if results.is_empty() {
            return list
                .child(
                    div()
                        .p_2()
                        .child(format!("No Results for “{}”", query.trim())),
                )
                .into_any_element();
        }
        list = list.child(div().px_2().text_xs().child("Results"));
        for (index, entry) in results.into_iter().enumerate() {
            let destination = entry.destination;
            list = list.child(
                Button::new(SharedString::from(format!("settings-result-{index}")))
                    .ghost()
                    .w_full()
                    .h_auto()
                    .accessibility_label(entry.title.clone())
                    .child(
                        div()
                            .w_full()
                            .py_0p5()
                            .flex()
                            .flex_col()
                            .child(entry.title.clone())
                            .when_some(entry.subtitle(), |row, pane| {
                                row.child(
                                    div()
                                        .text_xs()
                                        .text_color(self.color(0x98a6ba).opacity(0.7))
                                        .child(pane),
                                )
                            }),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.open_settings_destination(destination, window, cx)
                    })),
            );
        }
        list.into_any_element()
    }

    fn open_settings_destination(
        &mut self,
        destination: Destination,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match destination {
            Destination::Pane(section, row) => {
                self.navigate_settings_section(section, window, cx);
                if let Some(row) = row {
                    self.reveal_settings_row(row, window, cx);
                }
            }
            Destination::Subpage(section, id) => {
                self.navigate_settings_section(section, window, cx);
                self.open_settings_subpage(id, window, cx);
            }
        }
    }

    /// Scrolls to the row and highlights it, then fades the highlight, as
    /// Swift's SettingsRevealHandler.
    fn reveal_settings_row(&mut self, row: Row, window: &mut Window, cx: &mut Context<Self>) {
        match row {
            Row::DarkTheme => self.general_settings.reveal_theme(true),
            Row::LightTheme => self.general_settings.reveal_theme(false),
            _ => {}
        }
        self.settings_reveal.highlighted = Some(row);
        let anchor = self.settings_row_anchor(row);
        // The pane renders on the next frame; the anchor scrolls on the one after.
        window.on_next_frame(move |window, cx| anchor.scroll_to(window, cx));
        self.settings_reveal.fade = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(1_680))
                .await;
            this.update(cx, |this, cx| {
                if this.settings_reveal.highlighted == Some(row) {
                    this.settings_reveal.highlighted = None;
                    cx.notify();
                }
            })
            .ok();
        }));
        cx.notify();
    }

    /// Whether a search is revealing `row`, which shows it even where the
    /// current appearance would hide it.
    pub(super) fn settings_reveal_targets(&self, row: Row) -> bool {
        self.settings_reveal.highlighted == Some(row)
    }

    fn settings_row_anchor(&self, row: Row) -> ScrollAnchor {
        let frame = self.settings_section.id();
        self.settings_reveal
            .anchors
            .borrow_mut()
            .entry((frame, row))
            .or_insert_with(|| ScrollAnchor::for_handle(self.settings_scroll.handle(frame)))
            .clone()
    }

    /// A General row a search can scroll to and highlight.
    pub(super) fn revealable(&self, row: Row, element: impl IntoElement) -> AnyElement {
        let highlighted = self.settings_reveal.highlighted == Some(row);
        div()
            .id(SharedString::from(format!("settings-row-{row:?}")))
            .anchor_scroll(Some(self.settings_row_anchor(row)))
            .rounded(px(6.))
            .when(highlighted, |row| row.bg(self.color(0x202a3b)))
            .child(element)
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn titles(query: &str) -> Vec<String> {
        entries()
            .into_iter()
            .filter(|entry| entry.matches(query))
            .map(|entry| entry.title.to_string())
            .collect()
    }

    #[::core::prelude::v1::test]
    fn rows_match_titles_and_keywords_with_their_pane() {
        assert_eq!(titles("font"), ["Font size", "Reply font"]);
        let zoom = entries()
            .into_iter()
            .find(|entry| entry.matches("ZOOM"))
            .unwrap();
        assert_eq!(zoom.title.as_ref(), "Font size");
        assert_eq!(zoom.subtitle(), Some("General"));
        assert_eq!(
            zoom.destination,
            Destination::Pane(Section::General, Some(Row::FontSize))
        );
        assert!(titles("dark mode").contains(&"Dark theme".to_owned()));
        assert!(titles("bitwarden").contains(&"Passwords".to_owned()));
        assert!(titles("Report").contains(&"Report an Issue".to_owned()));
        assert!(titles("claude").contains(&"Claude Code".to_owned()));
        assert!(titles("   ").is_empty());
        assert!(titles("no such setting at all").is_empty());
    }

    #[::core::prelude::v1::test]
    fn whole_query_must_appear_in_one_title_or_keyword() {
        // "dark light" appears in no single title or keyword.
        assert!(titles("dark light").is_empty());
        assert!(titles("light mode").contains(&"Appearance".to_owned()));
        let pane = |title: &str| {
            entries()
                .into_iter()
                .find(|entry| entry.title.as_ref() == title)
                .unwrap()
        };
        // A pane's own entry doesn't repeat its name underneath.
        assert_eq!(pane("Models").subtitle(), None);
        assert_eq!(pane("Codex").subtitle(), None);
        assert_eq!(pane("Passwords").subtitle(), Some("Browser"));
        assert_eq!(pane("Keyboard shortcuts").subtitle(), Some("Keyboard"));
    }
}
