//! Persistent navigation beside the independently collapsible conversation list.
//! These are existing controllers only; unsupported Swift destinations are omitted.
use super::*;
use gpui_kit::assets::IconName;

impl Coincide {
    pub(super) fn navigation_rail(&self, cx: &mut Context<Self>) -> AnyElement {
        let button = |id: &'static str, icon: IconName, label: &'static str| {
            Button::new(id)
                .icon(icon)
                .accessibility_label(label)
                .tooltip(label)
                .ghost()
                .compact()
                .w(px(36.))
                .h(px(36.))
        };
        div()
            .id("navigation-rail")
            .track_focus(&self.navigation_focus)
            .flex()
            .flex_col()
            .items_center()
            .w(px(60.))
            .flex_shrink_0()
            .h_full()
            .py_3()
            .gap_2()
            .bg(self.color(0x151922))
            .border_r_1()
            .border_color(self.color(0x29303d))
            .child(
                button("navigation-threads", IconName::PanelLeft, "Threads")
                    .tooltip(if self.thread_list_open {
                        "Hide conversations"
                    } else {
                        "Show conversations"
                    })
                    .selected(self.thread_list_open)
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.thread_list_open = !this.thread_list_open;
                        // Do not leave keyboard input targeting a hidden search field.
                        if !this.thread_list_open
                            && this.thread_list_focus.contains_focused(window, cx)
                        {
                            this.navigation_focus.focus(window, cx);
                        }
                        cx.notify();
                    })),
            )
            .child(
                button("new", IconName::Plus, "New conversation")
                    .on_click(cx.listener(|this, _, window, cx| this.new_thread(window, cx))),
            )
            .child(
                button("navigation-search", IconName::Search, "Search")
                    .selected(self.command_palette.read(cx).is_open())
                    .on_click(cx.listener(|this, _, window, cx| this.toggle_palette(window, cx))),
            )
            .child(div().w(px(24.)).h(px(1.)).my_1().bg(self.color(0x29303d)))
            .child(
                button("navigation-terminal", IconName::SquareTerminal, "Terminal")
                    .selected(self.terminal_visible_thread.is_some())
                    .disabled(self.selected.is_none())
                    .on_click(cx.listener(|this, _, window, cx| this.terminal(window, cx))),
            )
            .child(div().flex_1())
            .child(
                button("navigation-usage", IconName::ChartPie, "Usage and limits")
                    .selected(
                        self.settings_open
                            && self.settings_section == settings::SettingsSection::Usage,
                    )
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.open_settings_panel(window, cx);
                        this.settings_search
                            .update(cx, |input, cx| input.set_value("", window, cx));
                        this.settings_section = settings::SettingsSection::Usage;
                        this.sync_transcription_binding(cx);
                        cx.notify();
                    })),
            )
            .child(
                button(
                    "navigation-providers",
                    IconName::Cpu,
                    "Providers and passwords",
                )
                .selected(
                    self.settings_open
                        && self.settings_section == settings::SettingsSection::Accounts,
                )
                .on_click(cx.listener(|this, _, window, cx| {
                    this.open_settings_panel(window, cx);
                    this.settings_search
                        .update(cx, |input, cx| input.set_value("", window, cx));
                    this.settings_section = settings::SettingsSection::Accounts;
                    this.sync_transcription_binding(cx);
                    cx.notify();
                })),
            )
            .child(
                button("settings", IconName::Settings, "Settings")
                    .selected(self.settings_open)
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.open_settings_panel(window, cx);
                        this.sync_transcription_binding(cx);
                        cx.notify();
                    })),
            )
            .into_any_element()
    }
}
