//! Settings › General presentation from Swift's GeneralSettingsView: appearance
//! thumbnails, theme swatch grids (picking a theme of the mode not shown
//! switches to it), the font-size slider, background notifications and
//! Restore Defaults…, which keeps providers, custom models and the default
//! model for new threads.
use super::*;
use crate::notifications::Permission;
use gpui_kit::component::slider::{Slider, SliderEvent, SliderState};
use settings::{PALETTES, Palette};

/// Swift's FontSizeRow slider range. Keyboard commands keep their own steps.
const FONT_RANGE: (f32, f32) = (11., 20.);

/// What Swift's `restoreDefaults(in:)` resets. Clearing a key lets each app read
/// its own default, so this app keeps its safer access fallback.
const RESTORED_KEYS: &[&str] = &[
    "appearance",
    "numberFormat",
    "fontSize",
    "replyTypeface",
    "userMessageSide",
    "darkTheme",
    "lightTheme",
    "showsPointingHand",
    "terminalPlacement",
    "terminalGPURendering",
    "terminalTranslucentBackground",
    "preferredOpenTarget",
    "sendOnReturn",
    "followUpBehavior",
    "generatesThreadTitles",
    "updatesThreadTitles",
    "newThreadStartsChat",
    "resumesAfterUsageLimit",
    "showReasoning",
    "opensLinksInDefaultBrowser",
    "confirmBeforeDeletingThreads",
    "confirmBeforeArchivingThreads",
    "commandLineControl",
    "holdToQuit",
    "defaultAccessMode",
    "notifyWhenInBackground",
    "checkpointsEnabled",
    "worktreeBranchPrefix",
    "idleSessionTimeoutMinutes",
    "approvesAgentSchedules",
];

pub(super) fn restore_defaults_patch() -> Value {
    Value::Object(
        RESTORED_KEYS
            .iter()
            .map(|key| ((*key).to_owned(), Value::Null))
            .collect(),
    )
}

/// The patch for picking `theme`. A theme of the mode the app isn't showing
/// also switches to that mode, so the choice shows right away.
pub(super) fn theme_patch(theme: &Palette, showing_dark: bool) -> Value {
    let key = if theme.dark {
        "darkTheme"
    } else {
        "lightTheme"
    };
    let mut patch = json!({ key: theme.id });
    if theme.dark != showing_dark {
        patch["appearance"] = json!(if theme.dark { "dark" } else { "light" });
    }
    patch
}

fn slider_size(size: f32) -> f32 {
    size.round().clamp(FONT_RANGE.0, FONT_RANGE.1)
}

/// The theme a stored id names, or the first of its kind for an id this
/// version does not know.
fn theme(id: Option<&str>, dark: bool) -> &'static Palette {
    PALETTES
        .iter()
        .find(|p| p.dark == dark && Some(p.id) == id)
        .or_else(|| PALETTES.iter().find(|p| p.dark == dark))
        .expect("both theme kinds exist")
}

/// Where the `coincide-rs` command is and whether a shell finds it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum CommandLineTool {
    OnPath(std::path::PathBuf),
    Installed(std::path::PathBuf),
    Missing,
}
const TOOL: &str = if cfg!(windows) {
    "coincide-rs.exe"
} else {
    "coincide-rs"
};
/// The tool beside this app, preferring one already on `PATH`.
fn command_line_tool(
    app: Option<&std::path::Path>,
    path: Option<&std::ffi::OsStr>,
) -> CommandLineTool {
    let bundled = app
        .and_then(std::path::Path::parent)
        .map(|folder| folder.join(TOOL))
        .filter(|tool| tool.is_file());
    let on_path = path
        .into_iter()
        .flat_map(std::env::split_paths)
        .filter(|folder| folder.is_absolute())
        .map(|folder| folder.join(TOOL))
        .find(|tool| tool.is_file());
    match (on_path, bundled) {
        (Some(tool), _) => CommandLineTool::OnPath(tool),
        (None, Some(tool)) => CommandLineTool::Installed(tool),
        (None, None) => CommandLineTool::Missing,
    }
}
fn display_path(path: &std::path::Path) -> String {
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" });
    match home.and_then(|home| path.strip_prefix(home).ok().map(std::path::Path::to_owned)) {
        Some(relative) if !cfg!(windows) => format!("~/{}", relative.display()),
        _ => path.display().to_string(),
    }
}

pub(super) struct State {
    font: Entity<SliderState>,
    command_line_tool: CommandLineTool,
    /// Theme grids opened by their row: dark, light.
    expanded: [bool; 2],
    restore_prompt: Option<Task<()>>,
    /// Settings › About's T3 Code License disclosure.
    pub(super) t3_license_open: bool,
}
impl State {
    pub(super) fn new(cx: &mut Context<Coincide>) -> Self {
        let mut state = Self {
            font: cx.new(|_| {
                SliderState::new()
                    .min(FONT_RANGE.0)
                    .max(FONT_RANGE.1)
                    .step(1.)
                    .default_value(13.)
            }),
            expanded: [false; 2],
            command_line_tool: CommandLineTool::Missing,
            restore_prompt: None,
            t3_license_open: false,
        };
        state.refresh_command_line_tool();
        state
    }
    pub(super) fn subscriptions(
        &self,
        window: &mut Window,
        cx: &mut Context<Coincide>,
    ) -> Vec<Subscription> {
        vec![cx.subscribe_in(
            &self.font,
            window,
            |this, _, event: &SliderEvent, window, cx| {
                let value = match event {
                    SliderEvent::Change(value) | SliderEvent::Release(value) => value,
                };
                let size = slider_size(value.start());
                if (size - this.conversation_font_size()).abs() >= 0.5 {
                    this.change_setting("fontSize", json!(size), window, cx);
                }
            },
        )]
    }
    /// Checks again where the command-line tool is, as Swift does when
    /// Settings opens.
    pub(super) fn refresh_command_line_tool(&mut self) {
        self.command_line_tool = command_line_tool(
            std::env::current_exe().ok().as_deref(),
            std::env::var_os("PATH").as_deref(),
        );
    }
    /// Opens the grid a settings search led to.
    pub(super) fn reveal_theme(&mut self, dark: bool) {
        self.expanded[usize::from(!dark)] = true;
    }
}

impl Coincide {
    pub(super) fn sync_general_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let size = slider_size(self.conversation_font_size());
        self.general_settings.font.update(cx, |slider, cx| {
            if (slider.value().start() - size).abs() >= 0.5 {
                slider.set_value(size, window, cx);
            }
        });
    }

    pub(super) fn change_settings(
        &mut self,
        patch: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match call(&self.engine, "settings.patch", json!({ "patch": patch })) {
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

    fn setting_text(&self, key: &str, fallback: &'static str) -> String {
        self.settings[key].as_str().unwrap_or(fallback).to_owned()
    }

    /// A row with Swift's title and caption beside its control.
    pub(super) fn labeled_row(
        &self,
        title: impl Into<SharedString>,
        caption: Option<SharedString>,
        control: impl IntoElement,
    ) -> Div {
        div()
            .flex()
            .items_center()
            .gap_3()
            .p_3()
            .border_b_1()
            .border_color(self.color(0x29303d))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap_0p5()
                    .child(title.into())
                    .when_some(caption, |row, caption| {
                        row.child(
                            div()
                                .text_xs()
                                .text_color(self.color(0x98a6ba).opacity(0.7))
                                .child(caption),
                        )
                    }),
            )
            .child(control)
    }

    fn mini_window(&self, theme: &Palette, width: f32, height: f32) -> Div {
        let ink = rgb(theme.ink);
        let line = |w: f32, alpha: f32| {
            div()
                .w(px(w))
                .h(px(2.))
                .rounded_full()
                .bg(ink.opacity(alpha))
        };
        div()
            .w(px(width))
            .h(px(height))
            .flex()
            .overflow_hidden()
            .rounded(px(7.))
            .child(
                div()
                    .h_full()
                    .p(px(4.))
                    .flex()
                    .flex_col()
                    .gap(px(3.))
                    .bg(rgb(theme.sidebar))
                    .children((0..4).map(|index| {
                        div()
                            .w(px(7.))
                            .h(px(7.))
                            .rounded(px(1.5))
                            .bg(ink.opacity(if index == 0 { 0.55 } else { 0.22 }))
                    })),
            )
            .child(
                div()
                    .flex_1()
                    .h_full()
                    .p(px(5.))
                    .flex()
                    .flex_col()
                    .gap(px(3.))
                    .bg(rgb(theme.content))
                    .child(line(26., 0.75))
                    .child(line(34., 0.3))
                    .child(line(22., 0.3))
                    .child(div().flex_1())
                    .child(
                        div()
                            .h(px(9.))
                            .rounded(px(3.))
                            .border_1()
                            .border_color(rgb(theme.border))
                            .bg(rgb(theme.surface)),
                    ),
            )
    }

    /// Swift's theme swatch: the rail, the conversation and a composer.
    fn theme_swatch(&self, theme: &Palette, width: f32, height: f32) -> Div {
        div()
            .relative()
            .w(px(width))
            .h(px(height))
            .flex_shrink_0()
            .overflow_hidden()
            .rounded(px(4.))
            .border_1()
            .border_color(rgb(theme.border))
            .bg(rgb(theme.content))
            .child(
                div()
                    .absolute()
                    .left_0()
                    .top_0()
                    .w(px(width * 0.32))
                    .h_full()
                    .bg(rgb(theme.sidebar)),
            )
            .child(
                div()
                    .absolute()
                    .left(px(width * 0.42))
                    .top(px(4.5))
                    .w(px(width * 0.4))
                    .h(px(1.5))
                    .bg(rgb(theme.ink).opacity(0.8)),
            )
            .child(
                div()
                    .absolute()
                    .left(px(width * 0.42))
                    .bottom(px(3.))
                    .w(px(width * 0.5))
                    .h(px(5.))
                    .rounded(px(2.))
                    .bg(rgb(theme.surface)),
            )
    }

    /// System, Light and Dark as miniature windows in the chosen themes.
    /// System shows the light theme with the dark one over its right half.
    pub(super) fn appearance_picker(&self, cx: &mut Context<Self>) -> AnyElement {
        let mode = self.setting_text("appearance", "system");
        let dark = theme(self.settings["darkTheme"].as_str(), true);
        let light = theme(self.settings["lightTheme"].as_str(), false);
        let mut picker = div().flex().gap(px(14.)).py(px(2.));
        for (value, label) in [("system", "System"), ("light", "Light"), ("dark", "Dark")] {
            let selected = mode == value;
            let thumbnail = match value {
                "light" => self.mini_window(light, 68., 46.),
                "dark" => self.mini_window(dark, 68., 46.),
                _ => div()
                    .relative()
                    .w(px(68.))
                    .h(px(46.))
                    .child(self.mini_window(light, 68., 46.))
                    .child(
                        div()
                            .absolute()
                            .top_0()
                            .right_0()
                            .w(px(34.))
                            .h(px(46.))
                            .overflow_hidden()
                            .child(
                                div()
                                    .absolute()
                                    .top_0()
                                    .right_0()
                                    .child(self.mini_window(dark, 68., 46.)),
                            ),
                    ),
            };
            picker = picker.child(
                Button::new(SharedString::from(format!("appearance-{value}")))
                    .ghost()
                    .accessibility_label(label)
                    .selected(selected)
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .items_center()
                            .gap(px(5.))
                            .py_1()
                            .child(
                                div()
                                    .rounded(px(9.))
                                    .when(selected, |frame| {
                                        frame.border_2().border_color(self.color(0xe4e9f2))
                                    })
                                    .when(!selected, |frame| {
                                        frame.border_1().border_color(self.color(0x29303d))
                                    })
                                    .child(thumbnail),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(self.color(0xe4e9f2).opacity(if selected {
                                        1.
                                    } else {
                                        0.6
                                    }))
                                    .child(label),
                            ),
                    )
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.change_setting("appearance", json!(value), window, cx)
                    })),
            );
        }
        self.labeled_row("Appearance", None, picker)
            .into_any_element()
    }

    /// One appearance's themes: the current theme's swatch and name, opening a
    /// grid of all of them.
    pub(super) fn theme_grid_row(&self, dark: bool, cx: &mut Context<Self>) -> AnyElement {
        let (key, title) = if dark {
            ("darkTheme", "Dark theme")
        } else {
            ("lightTheme", "Light theme")
        };
        let current = theme(self.settings[key].as_str(), dark);
        let expanded = self.general_settings.expanded[usize::from(!dark)];
        let header = Button::new(SharedString::from(format!("theme-grid-{key}")))
            .ghost()
            .w_full()
            .accessibility_label(format!("{title}: {}", current.name))
            .child(
                div()
                    .w_full()
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .child(div().flex_1().child(title))
                    .child(self.theme_swatch(current, 34., 22.))
                    .child(
                        div()
                            .text_color(self.color(0x98a6ba).opacity(0.8))
                            .child(current.name),
                    )
                    .child(
                        Icon::new(if expanded {
                            gpui_kit::assets::IconName::ChevronDown
                        } else {
                            gpui_kit::assets::IconName::ChevronRight
                        })
                        .xsmall(),
                    ),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                let open = &mut this.general_settings.expanded[usize::from(!dark)];
                *open = !*open;
                cx.notify();
            }));
        let mut row = div()
            .flex()
            .flex_col()
            .gap(px(10.))
            .p_3()
            .border_b_1()
            .border_color(self.color(0x29303d))
            .child(header);
        if expanded {
            let mut grid = div().flex().flex_wrap().gap(px(10.));
            for palette in PALETTES.iter().filter(|p| p.dark == dark) {
                let selected = palette.id == current.id;
                grid = grid.child(
                    Button::new(SharedString::from(format!("theme-tile-{}", palette.id)))
                        .ghost()
                        .w(px(96.))
                        .h_auto()
                        .accessibility_label(palette.name)
                        .selected(selected)
                        .child(
                            div()
                                .flex()
                                .flex_col()
                                .items_center()
                                .gap(px(6.))
                                .py_1()
                                .child(
                                    div()
                                        .p(px(3.))
                                        .rounded(px(7.))
                                        .border_2()
                                        .border_color(if selected {
                                            Hsla::from(self.color(0xe4e9f2))
                                        } else {
                                            transparent_black()
                                        })
                                        .child(self.theme_swatch(palette, 84., 52.)),
                                )
                                .child(
                                    div()
                                        .text_size(px(11.))
                                        .when(selected, |text| {
                                            text.font_weight(FontWeight::SEMIBOLD)
                                        })
                                        .text_color(self.color(0xe4e9f2).opacity(if selected {
                                            1.
                                        } else {
                                            0.6
                                        }))
                                        .child(palette.name),
                                ),
                        )
                        .on_click(cx.listener(move |this, _, window, cx| {
                            let patch = theme_patch(palette, this.appearance_dark);
                            this.change_settings(patch, window, cx)
                        })),
                );
            }
            row = row.child(grid);
        }
        row.into_any_element()
    }

    pub(super) fn font_size_row(&self) -> AnyElement {
        let size = self.conversation_font_size();
        self.labeled_row(
            "Font size",
            Some("Used for the transcript and the composer.".into()),
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(div().text_size(px(10.)).child("A"))
                .child(
                    div().w(px(170.)).child(
                        Slider::new(&self.general_settings.font)
                            .accessibility_label(format!("Font size, {size:.0} points")),
                    ),
                )
                .child(div().text_size(px(16.)).child("A"))
                .child(
                    div()
                        .min_w(px(38.))
                        .flex()
                        .justify_end()
                        .text_color(self.color(0x98a6ba).opacity(0.8))
                        .child(format!("{size:.0} pt")),
                ),
        )
        .into_any_element()
    }

    /// Swift's "Notify when Coincide is in the background" row over the native
    /// notification opt-in, with its warning when the system turned them off.
    pub(super) fn notifications_row(&self, cx: &mut Context<Self>) -> AnyElement {
        let status = self.notification_panel.read(cx).status().clone();
        let enabled = status.enabled;
        let unavailable = !status.native_compiled;
        let controls = div()
            .flex()
            .gap_2()
            .children([(true, "On"), (false, "Off")].map(|(value, label)| {
                Button::new(SharedString::from(format!("notify-background-{label}")))
                    .label(label)
                    .when(value == enabled, |button| button.primary())
                    .disabled(status.busy || status.stopped || (value && unavailable))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.notification_panel.update(cx, |panel, cx| {
                            panel.set_background_notifications(value, cx)
                        });
                    }))
            }));
        let caption = if unavailable {
            "Desktop notifications are unavailable in this build."
        } else {
            "Post a notification when a turn finishes, fails or needs your approval."
        };
        let mut row = div().flex().flex_col().child(self.labeled_row(
            "Notify when Coincide is in the background",
            Some(caption.into()),
            controls,
        ));
        if enabled && status.permission == Permission::Denied {
            let (warning, button) = notification_denied_guidance();
            row = row.child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .p_3()
                    .border_b_1()
                    .border_color(self.color(0x29303d))
                    .child(
                        Icon::new(gpui_kit::assets::IconName::TriangleAlert)
                            .xsmall()
                            .text_color(rgb(0xf0a030)),
                    )
                    .child(
                        div()
                            .flex_1()
                            .text_sm()
                            .text_color(self.color(0x98a6ba).opacity(0.8))
                            .child(warning),
                    )
                    .when_some(button, |row, (label, url)| {
                        row.child(
                            Button::new("notification-system-settings")
                                .label(label)
                                .on_click(cx.listener(move |_, _, _, cx| cx.open_url(url))),
                        )
                    }),
            );
        }
        row.into_any_element()
    }

    /// Swift's Command Line section: whether `coincide-rs` may drive this app,
    /// and where Terminal finds it.
    pub(super) fn command_line_rows(&self, cx: &mut Context<Self>) -> AnyElement {
        let enabled = self.settings["commandLineControl"]
            .as_bool()
            .unwrap_or(true);
        let controls = div()
            .flex()
            .gap_2()
            .children([(true, "On"), (false, "Off")].map(|(value, label)| {
                Button::new(SharedString::from(format!("command-line-control-{label}")))
                    .label(label)
                    .when(value == enabled, |button| button.primary())
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.change_setting("commandLineControl", json!(value), window, cx)
                    }))
            }));
        let (status, ok, captions) = match &self.general_settings.command_line_tool {
            CommandLineTool::OnPath(tool) => (
                "Ready",
                true,
                vec![format!(
                    "Installed at {}. Run coincide-rs help to see what it does.",
                    display_path(tool)
                )],
            ),
            CommandLineTool::Installed(tool) => (
                "Not on PATH",
                false,
                vec![
                    format!(
                        "Installed at {}. Run coincide-rs help to see what it does.",
                        display_path(tool)
                    ),
                    format!(
                        "Add {} to your shell’s PATH to use coincide-rs in Terminal.",
                        tool.parent().map(display_path).unwrap_or_default()
                    ),
                ],
            ),
            CommandLineTool::Missing => (
                "Unavailable",
                false,
                vec!["The coincide-rs command wasn’t found beside Coincide.".to_owned()],
            ),
        };
        div()
            .flex()
            .flex_col()
            .child(self.labeled_row(
                "Command-line control",
                Some("The coincide-rs command lists, starts and steers threads, and answers their approvals and questions, through a private connection on this computer. Agents Coincide starts can run it, so they can start other agents, as you can.".into()),
                controls,
            ))
            .child(
                self.labeled_row(
                    "Use it in Terminal",
                    Some(captions.join(" ").into()),
                    div()
                        .flex()
                        .items_center()
                        .gap_1()
                        .text_sm()
                        .text_color(if ok {
                            self.color(0x98a6ba).opacity(0.8)
                        } else {
                            rgb(0xff6b5f)
                        })
                        .child(
                            Icon::new(if ok {
                                gpui_kit::assets::IconName::CircleCheck
                            } else {
                                gpui_kit::assets::IconName::CircleAlert
                            })
                            .xsmall(),
                        )
                        .child(status),
                ),
            )
            .into_any_element()
    }

    pub(super) fn restore_general_defaults_row(&self, cx: &mut Context<Self>) -> AnyElement {
        div()
            .flex()
            .justify_end()
            .p_3()
            .child(
                Button::new("general-restore-defaults")
                    .label("Restore Defaults…")
                    .disabled(
                        self.general_settings
                            .restore_prompt
                            .as_ref()
                            .is_some_and(|task| !task.is_ready()),
                    )
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.confirm_restore_general_defaults(window, cx)
                    })),
            )
            .into_any_element()
    }

    fn confirm_restore_general_defaults(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let answer = window.prompt(
            PromptLevel::Warning,
            "Restore general settings to their defaults?",
            Some("Providers, custom models and the default model for new threads are kept."),
            &["Restore Defaults", "Cancel"],
            cx,
        );
        self.general_settings.restore_prompt = Some(cx.spawn_in(window, async move |this, cx| {
            if answer.await.unwrap_or(1) != 0 {
                return;
            }
            this.update_in(cx, |this, window, cx| {
                this.general_settings.expanded = [false; 2];
                this.change_settings(restore_defaults_patch(), window, cx);
            })
            .ok();
        }));
        cx.notify();
    }
}

/// The warning and the settings page to open when the system turned
/// notifications off for this app.
fn notification_denied_guidance() -> (&'static str, Option<(&'static str, &'static str)>) {
    if cfg!(target_os = "macos") {
        (
            "Notifications are turned off for Coincide in System Settings.",
            Some((
                "Open System Settings…",
                "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.apoorvdarshan.coincide.rust",
            )),
        )
    } else if cfg!(windows) {
        (
            "Notifications are turned off for Coincide in Windows Settings.",
            Some(("Open Windows Settings…", "ms-settings:notifications")),
        )
    } else {
        (
            "Notifications are turned off for Coincide in your desktop's settings.",
            None,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn picking_a_theme_of_the_hidden_mode_switches_appearance() {
        let midnight = PALETTES.iter().find(|p| p.id == "midnight").unwrap();
        let paper = PALETTES.iter().find(|p| p.id == "paper").unwrap();
        assert_eq!(theme_patch(midnight, true), json!({"darkTheme":"midnight"}));
        assert_eq!(
            theme_patch(midnight, false),
            json!({"darkTheme":"midnight","appearance":"dark"})
        );
        assert_eq!(
            theme_patch(paper, true),
            json!({"lightTheme":"paper","appearance":"light"})
        );
        assert_eq!(theme_patch(paper, false), json!({"lightTheme":"paper"}));
    }

    #[::core::prelude::v1::test]
    fn restore_defaults_keeps_providers_models_and_default_model() {
        let patch = restore_defaults_patch();
        let keys = patch.as_object().unwrap();
        assert_eq!(keys.len(), RESTORED_KEYS.len());
        assert!(keys.values().all(Value::is_null));
        for kept in [
            "providers",
            "defaultSelection",
            "favoriteModels",
            "hiddenModels",
            "voice",
            "appshots",
            "shortcutOverrides",
        ] {
            assert!(!keys.contains_key(kept), "{kept} must be kept");
        }
        for reset in ["appearance", "darkTheme", "fontSize", "holdToQuit"] {
            assert!(keys.contains_key(reset));
        }
    }

    #[::core::prelude::v1::test]
    fn command_line_tool_prefers_path_then_the_copy_beside_the_app() {
        let root = tempfile::tempdir().unwrap();
        let app = root.path().join("app");
        let bin = root.path().join("bin");
        std::fs::create_dir_all(&app).unwrap();
        std::fs::create_dir_all(&bin).unwrap();
        let exe = app.join("coincide-rust");
        let path = std::env::join_paths([bin.clone(), "relative".into()]).unwrap();
        assert_eq!(
            command_line_tool(Some(&exe), Some(&path)),
            CommandLineTool::Missing
        );
        std::fs::write(app.join(TOOL), b"").unwrap();
        assert_eq!(
            command_line_tool(Some(&exe), Some(&path)),
            CommandLineTool::Installed(app.join(TOOL))
        );
        std::fs::write(bin.join(TOOL), b"").unwrap();
        assert_eq!(
            command_line_tool(Some(&exe), Some(&path)),
            CommandLineTool::OnPath(bin.join(TOOL))
        );
        assert_eq!(command_line_tool(None, None), CommandLineTool::Missing);
    }

    #[::core::prelude::v1::test]
    fn unknown_theme_ids_and_out_of_range_sizes_fall_back() {
        assert_eq!(theme(Some("future-theme"), true).id, "carbon");
        assert_eq!(theme(Some("future-theme"), false).id, "carbon-light");
        assert_eq!(theme(Some("paper"), true).id, "carbon");
        assert_eq!(theme(Some("paper"), false).id, "paper");
        assert_eq!(slider_size(10.), 11.);
        assert_eq!(slider_size(24.), 20.);
        assert_eq!(slider_size(14.4), 14.);
    }
}
