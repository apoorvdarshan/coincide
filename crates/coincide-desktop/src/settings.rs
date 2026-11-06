use super::*;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum SettingsSection {
    #[default]
    General,
    All,
    Appearance,
    Keyboard,
    Conversation,
    Automation,
    Voice,
    Accounts,
    Browser,
    Media,
    ComputerUse,
    Usage,
}
impl SettingsSection {
    fn id(self) -> &'static str {
        match self {
            Self::General => "general",
            Self::All => "all",
            Self::Appearance => "appearance",
            Self::Keyboard => "keyboard",
            Self::Conversation => "conversation",
            Self::Automation => "automation",
            Self::Voice => "voice",
            Self::Accounts => "accounts",
            Self::Browser => "browser",
            Self::Media => "media",
            Self::ComputerUse => "computer-use",
            Self::Usage => "usage",
        }
    }
    pub(super) fn label(self) -> &'static str {
        match self {
            Self::General => "General",
            Self::All => "Search results",
            Self::Appearance => "Appearance",
            Self::Keyboard => "Keyboard",
            Self::Conversation => "Conversation",
            Self::Automation => "Automation and alerts",
            Self::Voice => "Voice",
            Self::Accounts => "Providers",
            Self::Browser => "Browser",
            Self::Media => "Historical images",
            Self::ComputerUse => "Computer Use",
            Self::Usage => "Usage and limits",
        }
    }
}
fn settings_match(
    selected: SettingsSection,
    section: SettingsSection,
    query: &str,
    terms: &str,
) -> bool {
    let general = selected == SettingsSection::General
        && matches!(
            section,
            SettingsSection::Appearance
                | SettingsSection::Conversation
                | SettingsSection::Automation
        );
    if selected != SettingsSection::All && selected != section && !general {
        return false;
    }
    let text = format!("{} {terms}", section.label()).to_lowercase();
    query
        .chars()
        .take(256)
        .collect::<String>()
        .to_lowercase()
        .split_whitespace()
        .all(|term| text.contains(term))
}

fn find_escape_routes(
    key: &str,
    plain: bool,
    find_open: bool,
    terminal_owns: bool,
    browser_visible: bool,
) -> bool {
    key == "escape" && plain && find_open && !terminal_owns && !browser_visible
}

// IDs and surface colors match the original macOS AppTheme catalog. Unknown
// imported theme IDs fall back for display without rewriting the stored value.
struct Palette {
    id: &'static str,
    name: &'static str,
    dark: bool,
    sidebar: u32,
    content: u32,
    surface: u32,
    raised: u32,
    border: u32,
    ink: u32,
    accent: u32,
}
const PALETTES: &[Palette] = &[
    Palette {
        id: "carbon",
        name: "Carbon",
        dark: true,
        sidebar: 0x0B0B0B,
        content: 0x000000,
        surface: 0x161616,
        raised: 0x141414,
        border: 0x2A2A2A,
        ink: 0xe4e9f2,
        accent: 0xFF8A3D,
    },
    Palette {
        id: "graphite",
        name: "Graphite",
        dark: true,
        sidebar: 0x181818,
        content: 0x212121,
        surface: 0x2B2B2B,
        raised: 0x282828,
        border: 0x333333,
        ink: 0xe4e9f2,
        accent: 0x9DB4FF,
    },
    Palette {
        id: "midnight",
        name: "Midnight",
        dark: true,
        sidebar: 0x0E1320,
        content: 0x141A28,
        surface: 0x1C2333,
        raised: 0x1A2130,
        border: 0x2A3347,
        ink: 0xDCE3F0,
        accent: 0x6FA8FF,
    },
    Palette {
        id: "slate",
        name: "Slate",
        dark: true,
        sidebar: 0x23262B,
        content: 0x2A2E34,
        surface: 0x333840,
        raised: 0x31353C,
        border: 0x40464F,
        ink: 0xD8DCE2,
        accent: 0x7FB8C9,
    },
    Palette {
        id: "forest",
        name: "Forest",
        dark: true,
        sidebar: 0x0D1410,
        content: 0x111A15,
        surface: 0x18241D,
        raised: 0x16211A,
        border: 0x26362C,
        ink: 0xD4E2D8,
        accent: 0x6FD08C,
    },
    Palette {
        id: "plum",
        name: "Plum",
        dark: true,
        sidebar: 0x140F18,
        content: 0x1A1420,
        surface: 0x241B2C,
        raised: 0x211928,
        border: 0x352841,
        ink: 0xE6DDF0,
        accent: 0xC58BF2,
    },
    Palette {
        id: "ocean",
        name: "Ocean",
        dark: true,
        sidebar: 0x08161B,
        content: 0x0C1D23,
        surface: 0x12292F,
        raised: 0x10252B,
        border: 0x1E3B43,
        ink: 0xD3EBEF,
        accent: 0x3FC5D6,
    },
    Palette {
        id: "ember",
        name: "Ember",
        dark: true,
        sidebar: 0x15100D,
        content: 0x1B1512,
        surface: 0x261D18,
        raised: 0x231B16,
        border: 0x3A2C24,
        ink: 0xEDE2D6,
        accent: 0xFF7A45,
    },
    Palette {
        id: "dusk",
        name: "Dusk",
        dark: true,
        sidebar: 0x12111F,
        content: 0x171627,
        surface: 0x201F35,
        raised: 0x1D1C31,
        border: 0x2F2D4A,
        ink: 0xDEDCF5,
        accent: 0xA08CFF,
    },
    Palette {
        id: "phosphor",
        name: "Phosphor",
        dark: true,
        sidebar: 0x040805,
        content: 0x060B07,
        surface: 0x0D150F,
        raised: 0x0B130D,
        border: 0x1C2B1F,
        ink: 0xB7F5C2,
        accent: 0x5CF07A,
    },
    Palette {
        id: "high-contrast",
        name: "High Contrast",
        dark: true,
        sidebar: 0x000000,
        content: 0x000000,
        surface: 0x000000,
        raised: 0x000000,
        border: 0xFFFFFF,
        ink: 0xFFFFFF,
        accent: 0xFFD400,
    },
    Palette {
        id: "carbon-light",
        name: "Carbon Light",
        dark: false,
        sidebar: 0xF5F5F5,
        content: 0xFFFFFF,
        surface: 0xFFFFFF,
        raised: 0xF5F5F5,
        border: 0xE1E1E1,
        ink: 0x111111,
        accent: 0xE8660F,
    },
    Palette {
        id: "paper",
        name: "Paper",
        dark: false,
        sidebar: 0xF2F0EC,
        content: 0xFBFAF8,
        surface: 0xFFFFFF,
        raised: 0xF2F0EC,
        border: 0xE4E0D8,
        ink: 0x111111,
        accent: 0xC26A2E,
    },
    Palette {
        id: "arctic",
        name: "Arctic",
        dark: false,
        sidebar: 0xEDF2F6,
        content: 0xF7FAFC,
        surface: 0xFFFFFF,
        raised: 0xEDF2F6,
        border: 0xD9E2EA,
        ink: 0x1E2A36,
        accent: 0x2F7FD6,
    },
    Palette {
        id: "sepia",
        name: "Sepia",
        dark: false,
        sidebar: 0xEEE5D3,
        content: 0xF6EFE1,
        surface: 0xFBF6EC,
        raised: 0xEEE5D3,
        border: 0xDDD0B8,
        ink: 0x3B2F22,
        accent: 0xA0602A,
    },
    Palette {
        id: "rose",
        name: "Rose",
        dark: false,
        sidebar: 0xF5EBED,
        content: 0xFCF6F7,
        surface: 0xFFFFFF,
        raised: 0xF5EBED,
        border: 0xEBD8DC,
        ink: 0x2E1D24,
        accent: 0xD14D72,
    },
    Palette {
        id: "lavender",
        name: "Lavender",
        dark: false,
        sidebar: 0xEFEBF8,
        content: 0xF8F6FC,
        surface: 0xFFFFFF,
        raised: 0xEFEBF8,
        border: 0xDDD6EE,
        ink: 0x241F33,
        accent: 0x7A5AE0,
    },
    Palette {
        id: "sand",
        name: "Sand",
        dark: false,
        sidebar: 0xEDE9E1,
        content: 0xF7F5F0,
        surface: 0xFFFFFF,
        raised: 0xEDE9E1,
        border: 0xDDD7CB,
        ink: 0x2B2A24,
        accent: 0xB8862E,
    },
    Palette {
        id: "mint",
        name: "Mint",
        dark: false,
        sidebar: 0xEAF4EE,
        content: 0xF5FAF7,
        surface: 0xFFFFFF,
        raised: 0xEAF4EE,
        border: 0xD3E6DA,
        ink: 0x1C2A22,
        accent: 0x1F9D6A,
    },
];

pub(super) fn reply_font() -> &'static str {
    #[cfg(target_os = "macos")]
    {
        "New York"
    }
    #[cfg(target_os = "windows")]
    {
        "Georgia"
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        "DejaVu Serif"
    }
}

impl Coincide {
    fn palette(&self) -> &'static Palette {
        let (key, fallback) = if self.appearance_dark {
            ("darkTheme", "carbon")
        } else {
            ("lightTheme", "carbon-light")
        };
        let id = self.settings[key].as_str().unwrap_or(fallback);
        PALETTES
            .iter()
            .find(|p| p.id == id && p.dark == self.appearance_dark)
            .unwrap_or_else(|| PALETTES.iter().find(|p| p.id == fallback).unwrap())
    }

    pub(super) fn color(&self, original: u32) -> Rgba {
        let p = self.palette();
        rgb(match original {
            0x151922 => p.sidebar,
            0x10141c => p.content,
            0x29303d => p.border,
            0x111722 | 0x181d28 => p.surface,
            0x202a3b | 0x253046 | 0x222c3d | 0x2b3549 => p.raised,
            0x98b1d4 => p.accent,
            0xe4e9f2 | 0x98a6ba => p.ink,
            _ => original,
        })
    }

    pub(super) fn conversation_font_size(&self) -> f32 {
        self.settings["fontSize"]
            .as_f64()
            .unwrap_or(13.)
            .clamp(10., 24.) as f32
    }

    pub(super) fn apply_appearance(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.appearance_dark = match self.settings["appearance"].as_str().unwrap_or("system") {
            "light" => false,
            "dark" => true,
            _ => ThemeMode::from(window.appearance()).is_dark(),
        };
        let p = self.palette();
        let binding = (self.appearance_dark, p.id.to_owned());
        if self.applied_theme.as_ref() == Some(&binding) {
            return;
        }
        self.applied_theme = Some(binding);
        Theme::change(
            if self.appearance_dark {
                ThemeMode::Dark
            } else {
                ThemeMode::Light
            },
            Some(window),
            cx,
        );
        Theme::update(cx, |theme| {
            theme.colors.background = rgb(p.content).into();
            theme.colors.foreground = rgb(p.ink).into();
            theme.colors.border = rgb(p.border).into();
            theme.colors.primary = rgb(p.accent).into();
            theme.colors.ring = rgb(p.accent).into();
        });
        self.transcript_list
            .splice(0..self.transcript_count, self.transcript_count);
        cx.notify();
    }

    pub(super) fn refresh_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match call(&self.engine, "settings.read", json!({})) {
            Ok(settings) if settings != self.settings => self.accept_settings(settings, window, cx),
            Ok(_) => {}
            Err(error) => self.settings_status = format!("Settings could not be loaded: {error}"),
        }
    }

    pub(super) fn accept_settings(
        &mut self,
        settings: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.settings = settings;
        let submit = self.settings["sendOnReturn"].as_bool().unwrap_or(true);
        self.composer
            .update(cx, |input, cx| input.set_submit_on_enter(submit, cx));
        self.apply_appearance(window, cx);
        // Virtualized rows cache their measured height and presentation.
        self.transcript_list
            .splice(0..self.transcript_count, self.transcript_count);
        cx.notify();
    }

    fn change_setting(
        &mut self,
        key: &'static str,
        value: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let mut patch = json!({});
        patch[key] = value;
        match call(&self.engine, "settings.patch", json!({"patch":patch})) {
            Ok(settings) => {
                self.settings_status = "Saved".into();
                self.accept_settings(settings, window, cx);
            }
            Err(error) => {
                self.settings_status = format!("Settings could not be saved: {error}");
                cx.notify();
            }
        }
    }

    fn setting_choices(
        &self,
        label: &'static str,
        key: &'static str,
        current: Value,
        choices: Vec<(&'static str, Value)>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        div()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .border_b_1()
            .border_color(self.color(0x29303d))
            .child(div().font_weight(FontWeight::SEMIBOLD).child(label))
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .children(
                        choices
                            .into_iter()
                            .enumerate()
                            .map(|(index, (label, value))| {
                                Button::new(SharedString::from(format!("setting-{key}-{index}")))
                                    .label(label)
                                    .when(value == current, |button| button.primary())
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.change_setting(key, value.clone(), window, cx)
                                    }))
                            }),
                    ),
            )
            .into_any_element()
    }

    pub(super) fn refresh_awake_status(&mut self, cx: &mut Context<Self>) {
        if let Ok(status) = call(&self.engine, "host.awake.status", json!({}))
            && status != self.awake_status
        {
            self.awake_status = status;
            cx.notify();
        }
    }
    fn configure_awake(&mut self, enabled: bool, cx: &mut Context<Self>) {
        match call(
            &self.engine,
            "host.awake.configure",
            json!({"enabled":enabled}),
        ) {
            Ok(status) => {
                self.awake_status = status;
                self.settings_status =
                    "Idle-sleep preference saved. The status below shows backend acknowledgement."
                        .into();
            }
            Err(error) => {
                self.settings_status = format!("Idle-sleep preference was not saved: {error}")
            }
        }
        cx.notify();
    }
    fn awake_settings(&self, cx: &mut Context<Self>) -> AnyElement {
        let enabled = self.awake_status["enabled"] == true;
        let supported = self.awake_status["supported"] == true;
        let pending = self.awake_status["workerStarted"] == true
            && self.awake_status["requestedRevision"] != self.awake_status["acknowledgedRevision"];
        let state = if let Some(error) = self.awake_status["error"].as_str() {
            format!("Could not confirm idle-sleep state: {error}")
        } else if !supported {
            "Idle-sleep inhibition is unavailable on this platform.".into()
        } else if pending {
            "Waiting for the idle-sleep backend to acknowledge the change…".into()
        } else if self.awake_status["lease"] == "held" {
            "Temporary idle-sleep lease acknowledged by the backend.".into()
        } else if enabled {
            "Enabled. No idle-sleep lease is currently held.".into()
        } else {
            "Off. No idle-sleep lease is currently held.".into()
        };
        div().p_3().flex().flex_col().gap_2().border_b_1().border_color(self.color(0x29303d))
            .child(div().flex().items_center().gap_3()
                .child(div().flex_1().child("Keep awake during work"))
                .child(Button::new("idle-sleep-toggle").label(if enabled {"Turn off"} else {"Turn on"})
                    .disabled(!supported && !enabled)
                    .on_click(cx.listener(move |this, _, _, cx| this.configure_awake(!enabled, cx)))))
            .child(div().text_sm().child(state))
            .child(div().text_sm().child("Prevents idle sleep while a turn or tracked workspace/image job is running, including on battery. Ends when work finishes or Coincide quits."))
            .child(div().text_sm().child("24/7 operation, closed-lid behavior, battery-specific policy, and persistent power settings are not connected in this Rust preview."))
            .into_any_element()
    }

    pub(super) fn settings_surface(&self, cx: &mut Context<Self>) -> AnyElement {
        if (self.bots_open || self.transcription_open || self.notifications_open)
            && !self.provider_settings.open
        {
            div()
                    .id("extra-settings-surface")
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(
                        Button::new("extra-settings-back")
                            .label("Back to Settings")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.bots_open = false;
                                this.transcription_open = false;
                                this.notifications_open = false;
                                this.focus_settings_route(window,cx);
                                this.sync_transcription_binding(cx);
                                cx.notify();
                            })),
                    )
                    .child(if self.bots_open {
                        div()
                            .flex_1()
                            .min_h_0()
                            .child(self.bot_panel.clone())
                            .into_any_element()
                    } else if self.notifications_open {
                        div()
                            .id("notification-settings-scroll")
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .child(self.notification_panel.clone())
                            .child(div().p_3().text_sm().child("Foreground conversation visibility is observed. System idle, screen lock, display sleep and remote-device monitoring are not connected."))
                            .into_any_element()
                    } else {
                        div()
                            .id("transcription-settings-scroll")
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .child(self.transcription_panel.clone())
                            .child(self.microphone_panel.clone())
                            .child(div().p_3().text_sm().child("Recording uses the executable, model, language and CPU-thread settings above, with a 60-second limit. Native microphone acceptance is pending; recording controls remain disabled."))
                            .child(div().p_3().text_sm().child(self.status.clone()))
                            .into_any_element()
                    })
                    .into_any_element()
        } else if self.computer_use_settings_visible() {
            self.computer_use_settings_pane(cx)
        } else if self.media_settings_visible() {
            self.media_settings_pane(cx)
        } else if self.browser_settings_visible() {
            let scroll = self.browser_settings_panel.read(cx).form_scroll();
            div()
                    .id("browser-settings-surface")
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(
                        Button::new("browser-settings-back")
                            .label("Back to Settings")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.browser_settings_open = false;
                                this.focus_settings_route(window,cx);
                                this.credential_panel
                                    .update(cx, |panel, cx| panel.cancel(cx));
                                this.sync_transcription_binding(cx);
                                cx.notify();
                            })),
                    )
                    .child(
                        div().relative().flex_1().min_h_0().flex().flex_col().overflow_hidden()
                            .child(div()
                                .id("browser-settings-scroll")
                                .track_scroll(&scroll).pr_4()
                                .flex_1().min_h_0().overflow_y_scroll()
                                .when(self.browser.is_none(),|view|view.child(div().p_3().child("The browser is unavailable; profile changes and password filling are disabled.")))
                                .child(self.browser_settings_panel.clone())
                                .child(div().p_3().text_lg().child("Passwords"))
                                .child(self.credential_panel.clone()))
                            .child(gpui_kit::component::scroll::Scrollbar::vertical(&scroll)
                                .mode(gpui_kit::component::scroll::ScrollbarMode::Always)),
                    )
                    .into_any_element()
        } else if self.credentials_open {
            div()
                .id("password-settings-surface")
                .flex_1()
                .flex_basis(px(0.))
                .min_h_0()
                .min_w_0()
                .overflow_y_scroll()
                .child(
                    Button::new("password-settings-back")
                        .label("Back to Settings")
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.credentials_open = false;
                            this.focus_settings_route(window, cx);
                            this.credential_panel
                                .update(cx, |panel, cx| panel.cancel(cx));
                            this.sync_transcription_binding(cx);
                            cx.notify();
                        })),
                )
                .child(self.credential_panel.clone())
                .into_any_element()
        } else if self.provider_settings.open {
            self.antigravity_settings(cx)
        } else {
            self.settings_pane(cx)
        }
    }

    pub(super) fn settings_pane(&self, cx: &mut Context<Self>) -> AnyElement {
        use SettingsSection as S;
        let query = self.settings_search.read(cx).value().to_string();
        let filtering = if query.trim().is_empty() {
            self.settings_section
        } else {
            S::All
        };
        let matches = |section, terms| settings_match(filtering, section, &query, terms);
        let setting =
            |key: &str, fallback: Value| self.settings.get(key).cloned().unwrap_or(fallback);
        // Match the Swift Settings sidebar: destinations remain fixed while
        // the selected pane scrolls independently on every desktop platform.
        let mut nav = div().flex().flex_col().gap_1();
        for section in [
            S::General,
            S::Usage,
            S::Keyboard,
            S::Voice,
            S::Browser,
            S::ComputerUse,
            S::Media,
            S::Accounts,
        ] {
            nav = nav.child(
                Button::new(SharedString::from(format!(
                    "settings-section-{}",
                    section.id()
                )))
                .label(section.label())
                .w_full()
                .ghost()
                .when(self.settings_section == section, |button| button.primary())
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.settings_section = section;
                    cx.notify();
                })),
            );
        }
        let mut content = div().w_full().min_w_0().flex().flex_col().gap_2();
        let mut count = 0;
        if matches(
            S::Usage,
            "saved local usage history tokens provider reports cost counters live codex limits quota credits",
        ) {
            count += 1;
            if self.settings_section == S::Usage {
                content = content.child(self.codex_limits.panel.clone()).child(
                    div()
                        .h(px(460.))
                        .min_h(px(260.))
                        .child(self.usage_history.panel.clone()),
                );
            } else {
                content = content.child(
                    Button::new("settings-usage-history")
                        .label("View usage and Codex limits")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.settings_section = S::Usage;
                            cx.notify();
                        })),
                );
            }
        }
        if matches(S::Appearance, "appearance system light dark color theme") {
            count += 1;
            let mode = setting("appearance", json!("system"));
            content = content.child(self.setting_choices(
                "Appearance",
                "appearance",
                mode.clone(),
                vec![
                    ("System", json!("system")),
                    ("Light", json!("light")),
                    ("Dark", json!("dark")),
                ],
                cx,
            ));
            for (dark, key, label, fallback) in [
                (true, "darkTheme", "Dark theme", "carbon"),
                (false, "lightTheme", "Light theme", "carbon-light"),
            ] {
                if mode == "system" || (mode == "dark" && dark) || (mode == "light" && !dark) {
                    content = content.child(
                        self.setting_choices(
                            label,
                            key,
                            setting(key, json!(fallback)),
                            PALETTES
                                .iter()
                                .filter(|p| p.dark == dark)
                                .map(|p| (p.name, json!(p.id)))
                                .collect(),
                            cx,
                        ),
                    );
                }
            }
        }
        if matches(S::Appearance, "conversation font size text smaller larger") {
            count += 1;
            let size = self.conversation_font_size();
            content = content.child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .p_3()
                    .child(
                        div()
                            .flex_1()
                            .child(format!("Conversation font size: {size:.0}")),
                    )
                    .child(
                        Button::new("font-smaller")
                            .label("Smaller")
                            .disabled(size <= 10.)
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.change_setting(
                                    "fontSize",
                                    json!((this.conversation_font_size() - 1.).max(10.)),
                                    window,
                                    cx,
                                )
                            })),
                    )
                    .child(
                        Button::new("font-larger")
                            .label("Larger")
                            .disabled(size >= 24.)
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.change_setting(
                                    "fontSize",
                                    json!((this.conversation_font_size() + 1.).min(24.)),
                                    window,
                                    cx,
                                )
                            })),
                    ),
            );
        }
        for (section, terms, label, key, fallback, choices) in [
            (
                S::Appearance,
                "reply font serif system typeface",
                "Reply font",
                "replyTypeface",
                json!("newYork"),
                vec![("Serif", json!("newYork")), ("System", json!("system"))],
            ),
            (
                S::Conversation,
                "your messages left right side alignment",
                "Your messages",
                "userMessageSide",
                json!("right"),
                vec![("Right", json!("right")), ("Left", json!("left"))],
            ),
            (
                S::Conversation,
                "reasoning thinking show hide",
                "Reasoning",
                "showReasoning",
                json!(true),
                vec![("Show", json!(true)), ("Hide", json!(false))],
            ),
            (
                S::Conversation,
                "send messages return command control keyboard shortcuts",
                "Send messages with",
                "sendOnReturn",
                json!(true),
                vec![
                    ("Return", json!(true)),
                    ("Command / Control + Return", json!(false)),
                ],
            ),
        ] {
            if matches(section, terms) {
                count += 1;
                content = content.child(self.setting_choices(
                    label,
                    key,
                    setting(key, fallback),
                    choices,
                    cx,
                ));
            }
        }
        if matches(S::Conversation, "send return composer keys") {
            count += 1;
            content=content.child(div().p_3().text_sm().child("Shift-Return inserts a new line. Command / Control + Return sends from the composer. Find uses Command / Control + F; Settings uses Command / Control + comma. Customize app commands in Keyboard."));
        }
        if matches(
            S::Keyboard,
            "keyboard shortcuts record reset disable command palette terminal font",
        ) {
            count += 1;
            content = content.child(self.keyboard_settings(cx));
        }
        if matches(S::Automation, "keep awake sleep display power") {
            count += 1;
            content = content.child(self.awake_settings(cx));
        }
        for (section, id, label, terms) in [
            (
                S::Automation,
                "bots",
                "Bots and bot instructions",
                "bots bot instructions automation",
            ),
            (
                S::Voice,
                "transcription",
                "Local transcription",
                "local transcription microphone recording speech audio",
            ),
            (
                S::Automation,
                "notifications",
                "Desktop notifications",
                "desktop notifications alerts sound",
            ),
            (
                S::Accounts,
                "codex-accounts",
                "Codex login profiles",
                "codex openai chatgpt subscription login accounts profiles sign in",
            ),
            (
                S::Accounts,
                "antigravity",
                "Antigravity accounts",
                "antigravity provider configured account models",
            ),
            (
                S::ComputerUse,
                "computer-use",
                "Computer Use",
                "computer use desktop accessibility screen capture observe input permissions thread access",
            ),
            (
                S::Media,
                "media",
                "Restore historical images",
                "historical legacy images photos attachments recovery folder mapping",
            ),
            (
                S::Browser,
                "browser",
                "Browser profiles and imports",
                "browser profiles imports cookies privacy passwords passkeys",
            ),
            (
                S::Browser,
                "passwords",
                "Password managers",
                "password managers bitwarden 1password credentials vault",
            ),
        ] {
            if matches(section, terms) {
                count += 1;
                content = content.child(
                    div().p_3().child(
                        Button::new(SharedString::from(format!("settings-{id}")))
                            .label(label)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.credential_panel
                                    .update(cx, |panel, cx| panel.cancel(cx));
                                this.bots_open = id == "bots";
                                this.notifications_open = id == "notifications";
                                this.transcription_open = id == "transcription";
                                this.credentials_open = id == "passwords";
                                this.browser_settings_open = id == "browser";
                                this.media.opened = id == "media";
                                this.computer_use_open = id == "computer-use";
                                this.provider_settings.open = false;
                                if id == "antigravity" {
                                    this.open_antigravity_settings(window, cx);
                                } else if id == "codex-accounts" {
                                    this.open_codex_account_settings(window, cx);
                                } else {
                                    this.focus_settings_route(window, cx);
                                }
                                this.sync_transcription_binding(cx);
                                cx.notify();
                            })),
                    ),
                );
            }
        }
        if count == 0 {
            content = content.child(div().p_3().child(
                "No matching settings in this section. Choose All settings or change the search.",
            ));
        }
        div()
            .id("settings-pane")
            .flex_1()
            .flex_basis(px(0.))
            .min_w_0()
            .min_h_0()
            .overflow_hidden()
            .flex()
            .child(
                div()
                    .id("settings-sidebar")
                    .w(px(220.))
                    .min_w(px(200.))
                    .flex_shrink_0()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .p_3()
                    .bg(self.color(0x141821))
                    .border_r_1()
                    .border_color(self.color(0x29303d))
                    .child(Input::new(&self.settings_search))
                    .child(
                        div()
                            .id("settings-destinations")
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .child(nav),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .flex_basis(px(0.))
                    .min_w_0()
                    .overflow_hidden()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .p_4()
                    .child(
                        div()
                            .flex()
                            .justify_between()
                            .items_center()
                            .child(div().flex_1().min_w_0().text_xl().child(filtering.label()))
                            .child(Button::new("settings-done").label("Done").on_click(
                                cx.listener(|this, _, window, cx| {
                                    this.close_settings_panel(window, cx);
                                }),
                            )),
                    )
                    .child(
                        div()
                            .id("settings-results")
                            .flex_1()
                            .min_w_0()
                            .min_h_0()
                            .overflow_y_scroll()
                            .child(content),
                    )
                    .child(div().text_sm().child(self.settings_status.clone())),
            )
            .into_any_element()
    }

    pub(super) fn keyboard_panel_visible(&self, cx: &Context<Self>) -> bool {
        self.settings_open
            && !self.session_import_open
            && !self.bots_open
            && !self.transcription_open
            && !self.notifications_open
            && !self.computer_use_open
            && !self.media_settings_visible()
            && !self.browser_settings_open
            && !self.credentials_open
            && !self.provider_settings.open
            && !self.historical_image_is_open()
            && !self.command_palette.read(cx).is_open()
            && !self.media.close_requested
            && !self.media.shutdown_requested
            && settings_match(
                self.settings_section,
                SettingsSection::Keyboard,
                self.settings_search.read(cx).value().as_ref(),
                "keyboard shortcuts record reset disable command palette terminal font",
            )
    }
    pub(super) fn run_keyboard_command(
        &mut self,
        command: keyboard_settings::Command,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        use keyboard_settings::Command as K;
        match command {
            K::NewThread => self.new_thread(window, cx),
            K::Palette => self.toggle_palette(window, cx),
            K::Sidebar => self.toggle_sidebar(window, cx),
            K::Terminal => {
                if self.settings_in_main_window() || self.schedules_open || self.selected.is_none()
                {
                    return;
                }
                self.terminal(window, cx);
            }
            K::Schedules => {
                self.hide_inline_settings();
                self.workspace_open = false;
                self.session_import_open = false;
                self.schedules_open = !self.schedules_open;
                if self.schedules_open {
                    self.refresh_schedules(cx);
                }
                self.sync_transcription_binding(cx);
                cx.notify();
            }
            K::Larger | K::Smaller | K::FontReset => {
                let size = match command {
                    K::Larger => (self.conversation_font_size() + 1.).min(24.),
                    K::Smaller => (self.conversation_font_size() - 1.).max(10.),
                    _ => 13.,
                };
                self.change_setting("fontSize", json!(size), window, cx);
            }
        }
    }

    pub(super) fn app_shortcut(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.record_shortcut_event(event, window, cx) {
            return;
        }
        let key = &event.keystroke;
        let terminal_owns = self
            .terminal_visible_thread
            .as_ref()
            .and_then(|id| self.terminal_workspaces.get(id))
            .is_some_and(|workspace| workspace.read(cx).is_focused(window));
        let browser_visible = self
            .selected
            .as_ref()
            .is_some_and(|thread| self.browser_panels.contains(&text(thread, "id")));
        let plain = !key.modifiers.platform
            && !key.modifiers.control
            && !key.modifiers.alt
            && !key.modifiers.shift
            && !event.is_held
            && window.is_window_active();
        if find_escape_routes(
            &key.key,
            plain,
            self.transcript_find.read(cx).is_open(),
            terminal_owns,
            browser_visible,
        ) {
            self.dismiss_find(window, cx);
            cx.stop_propagation();
            return;
        }
        if event.is_held || !window.is_window_active() {
            return;
        }
        #[cfg(target_os = "macos")]
        let command = key.modifiers.platform;
        #[cfg(not(target_os = "macos"))]
        let command = key.modifiers.control;
        let custom = self.keyboard_command(
            key,
            terminal_owns,
            browser_visible,
            self.command_palette.read(cx).is_open(),
        );
        if custom == Some(keyboard_settings::Command::Palette) {
            self.toggle_palette(window, cx);
            cx.stop_propagation();
            return;
        }
        if self.command_palette.read(cx).is_open() {
            if command && !key.modifiers.alt && !key.modifiers.shift {
                cx.stop_propagation();
            }
            return;
        }
        // Focused terminals retain control sequences and their local bindings.
        if terminal_owns {
            return;
        }
        if let Some(command) = custom {
            self.run_keyboard_command(command, window, cx);
            cx.stop_propagation();
            return;
        }
        if !command || key.modifiers.alt || key.modifiers.shift {
            return;
        }
        match key.key.as_str() {
            "," => {
                self.credential_panel
                    .update(cx, |panel, cx| panel.cancel(cx));
                self.open_settings_panel(window, cx);
                self.sync_transcription_binding(cx);
                cx.notify();
            }
            "f" => {
                if !transcript_find_shortcut_routes(self.selected.as_ref(), &self.browser_panels) {
                    return;
                }
                self.open_find(window, cx);
            }
            "enter"
                if !self.settings_in_main_window()
                    && !self.schedules_open
                    && self.composer.read(cx).focus_handle(cx).is_focused(window) =>
            {
                self.send(window, cx)
            }
            _ => return,
        }
        cx.stop_propagation();
    }
}

#[cfg(test)]
mod navigation_tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn search_matches_all_tokens_and_respects_stable_section_filter() {
        use SettingsSection as S;
        assert!(settings_match(
            S::All,
            S::Accounts,
            "ANTIGRAVITY account",
            "Antigravity configured account"
        ));
        assert!(!settings_match(
            S::Conversation,
            S::Accounts,
            "account",
            "Antigravity configured account"
        ));
        assert!(!settings_match(
            S::All,
            S::Accounts,
            "account impossible",
            "Antigravity configured account"
        ));
        assert!(settings_match(
            S::All,
            S::Automation,
            "alerts",
            "notifications"
        ));
        assert_eq!(S::Accounts.id(), "accounts");
        assert_eq!(S::Browser.id(), "browser");
        assert_eq!(S::Usage.id(), "usage");
        assert!(settings_match(
            S::All,
            S::Usage,
            "tokens history",
            "saved local usage history tokens provider reports"
        ));
        assert_eq!(S::ComputerUse.id(), "computer-use");
        assert!(settings_match(
            S::ComputerUse,
            S::ComputerUse,
            "screen permissions",
            "capture screen permissions"
        ));
        assert!(settings_match(
            S::Browser,
            S::Browser,
            "cookies privacy",
            "profiles imports cookies privacy"
        ));
        assert!(!settings_match(
            S::Browser,
            S::Accounts,
            "password",
            "password managers"
        ));
    }
    #[::core::prelude::v1::test]
    fn sibling_find_escape_closes_only_plain_owned_conversation_context() {
        assert!(find_escape_routes("escape", true, true, false, false));
        assert!(!find_escape_routes("escape", false, true, false, false));
        assert!(!find_escape_routes("escape", true, false, false, false));
        assert!(!find_escape_routes("escape", true, true, true, false));
        assert!(!find_escape_routes("escape", true, true, false, true));
        assert!(!find_escape_routes("enter", true, true, false, false));
    }
}
