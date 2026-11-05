use super::*;

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

    fn accept_settings(&mut self, settings: Value, window: &mut Window, cx: &mut Context<Self>) {
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

    pub(super) fn settings_pane(&self, cx: &mut Context<Self>) -> AnyElement {
        let setting =
            |key: &str, fallback: Value| self.settings.get(key).cloned().unwrap_or(fallback);
        let mode = setting("appearance", json!("system"));
        let mut pane = div()
            .id("settings-pane")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p_4()
            .child(
                div()
                    .flex()
                    .justify_between()
                    .items_center()
                    .child(div().text_xl().child("Settings"))
                    .child(
                        Button::new("settings-done")
                            .label("Done")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.settings_open = false;
                                cx.notify();
                            })),
                    ),
            )
            .child(self.setting_choices(
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
                pane = pane.child(
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
        let size = self.conversation_font_size();
        pane = pane.child(div().flex().items_center().gap_3().p_3().border_b_1().border_color(self.color(0x29303d))
            .child(div().flex_1().child(format!("Conversation font size: {size:.0}")))
            .child(Button::new("font-smaller").label("Smaller").disabled(size <= 10.).on_click(cx.listener(|this, _, window, cx| this.change_setting("fontSize", json!((this.conversation_font_size()-1.).max(10.)), window, cx))))
            .child(Button::new("font-larger").label("Larger").disabled(size >= 24.).on_click(cx.listener(|this, _, window, cx| this.change_setting("fontSize", json!((this.conversation_font_size()+1.).min(24.)), window, cx)))))
            .child(self.setting_choices("Reply font", "replyTypeface", setting("replyTypeface",json!("newYork")), vec![("Serif",json!("newYork")),("System",json!("system"))],cx))
            .child(self.setting_choices("Your messages", "userMessageSide", setting("userMessageSide",json!("right")), vec![("Right",json!("right")),("Left",json!("left"))],cx))
            .child(self.setting_choices("Reasoning", "showReasoning", setting("showReasoning",json!(true)), vec![("Show",json!(true)),("Hide",json!(false))],cx))
            .child(self.setting_choices("Send messages with", "sendOnReturn", setting("sendOnReturn",json!(true)), vec![("Return",json!(true)),("Command / Control + Return",json!(false))],cx))
            .child(div().p_3().child("Shift-Return always inserts a new line. Command / Control + Return sends from the message composer."))
            .child(div().p_3().child("Shortcuts: Command / Control + N — new conversation; + F — search; + comma — settings."))
            .child(div().p_3().text_sm().child(self.settings_status.clone()));
        pane.into_any_element()
    }

    pub(super) fn app_shortcut(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let key = &event.keystroke;
        #[cfg(target_os = "macos")]
        let command = key.modifiers.platform;
        #[cfg(not(target_os = "macos"))]
        let command = key.modifiers.control;
        if !command || key.modifiers.alt || key.modifiers.shift || event.is_held {
            return;
        }
        // Keep terminal control sequences (Ctrl+N/F etc.) in the PTY.
        if self.terminal_focus.is_focused(window) {
            return;
        }
        match key.key.as_str() {
            "," => {
                self.settings_open = !self.settings_open;
                cx.notify();
            }
            "n" => self.new_thread(window, cx),
            "f" => self.search.read(cx).focus_handle(cx).focus(window, cx),
            "enter"
                if !self.settings_open
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
