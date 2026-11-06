//! Shared Settings navigation follows the Swift pane hierarchy. The retained
//! detail owner changes independently; entering a subpage never removes the
//! sidebar or recreates provider, browser, or editor owners.
use super::*;
use coincide_core::provider_catalog::ProviderId;
use settings::SettingsSection as Section;

#[derive(Default)]
pub(super) struct State {
    width: Option<f32>,
    drag: Option<(f32, f32)>,
}
impl State {
    pub(super) fn cancel_drag(&mut self) {
        self.drag = None;
    }
    fn width(&self) -> f32 {
        self.width.unwrap_or(220.)
    }
    fn move_to(&mut self, pointer: f32) -> bool {
        let Some((start, width)) = self.drag else {
            return false;
        };
        if !pointer.is_finite() {
            return false;
        }
        let target = (width + pointer - start).clamp(200., 280.);
        if (self.width() - target).abs() < 0.5 {
            return false;
        }
        self.width = Some(target);
        true
    }
}
#[derive(Clone)]
struct ResizeSettings;
impl Render for ResizeSettings {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        Empty
    }
}

pub(super) fn provider_key(provider: ProviderId) -> &'static str {
    match provider {
        ProviderId::Claude => "claude",
        ProviderId::Codex => "codex",
        ProviderId::Cursor => "cursor",
        ProviderId::Grok => "grok",
        ProviderId::Opencode => "opencode",
        ProviderId::Antigravity => "antigravity",
    }
}

fn section_icon(section: Section) -> (gpui_kit::assets::IconName, u32) {
    use gpui_kit::assets::IconName as I;
    match section {
        Section::General => (I::Settings, 0x737780),
        Section::Models => (I::Boxes, 0x8b5ac7),
        Section::Usage => (I::ChartColumn, 0x278349),
        Section::Instructions => (I::BookOpen, 0x238b91),
        Section::Archive => (I::Archive, 0x936b48),
        Section::Keyboard => (I::Keyboard, 0x53575d),
        Section::Voice => (I::Mic, 0xc74444),
        Section::Browser => (I::Globe, 0x1c8caa),
        Section::ComputerUse => (I::Monitor, 0x347cc4),
        Section::Media => (I::GalleryVerticalEnd, 0xb77927),
        Section::Accounts => (I::LayoutDashboard, 0x5d64bb),
        Section::Provider(_) => (I::Cpu, 0x717782),
        Section::About => (I::Info, 0x347cc4),
        _ => (I::Settings2, 0x737780),
    }
}

fn icon_tile(section: Section, size: f32) -> AnyElement {
    let (icon, tint) = section_icon(section);
    div()
        .w(px(size))
        .h(px(size))
        .flex_shrink_0()
        .rounded(px(size * 0.26))
        .bg(rgb(tint))
        .text_color(rgb(0xffffff))
        .flex()
        .items_center()
        .justify_center()
        .child(Icon::new(icon).xsmall())
        .into_any_element()
}

fn provider_enabled(settings: &Value, provider: ProviderId) -> bool {
    if provider == ProviderId::Antigravity
        && models_settings::provider_value(settings, provider_key(provider))["isEnabled"].is_null()
    {
        return false;
    }
    coincide_core::provider_preferences::enabled(settings, provider_key(provider)).unwrap_or(false)
}

fn enabled_patch(
    settings: &Value,
    provider: ProviderId,
    expected: bool,
    enabled: bool,
) -> Result<Value> {
    anyhow::ensure!(
        provider != ProviderId::Antigravity,
        "Use the Antigravity account-risk controls"
    );
    anyhow::ensure!(settings.is_object(), "Saved settings are malformed");
    let current = coincide_core::provider_preferences::enabled(settings, provider_key(provider))?;
    anyhow::ensure!(
        current == expected,
        "Provider settings changed; review the current value"
    );
    let key = provider_key(provider);
    let value = models_settings::provider_value(settings, key);
    anyhow::ensure!(
        value.is_null() || value.is_object(),
        "Saved provider settings are malformed"
    );
    let mut value = if value.is_null() {
        json!({})
    } else {
        value.clone()
    };
    value["isEnabled"] = json!(enabled);
    let mut entries = if settings["providers"].is_null() {
        json!({})
    } else {
        settings["providers"].clone()
    };
    models_settings::replace_provider(&mut entries, key, value)?;
    Ok(json!({"providers":entries}))
}

fn search_matches(section: Section, query: &str) -> bool {
    let keywords = match section {
        Section::General => {
            "appearance dark light theme colors font text zoom messages terminal layout awake number locale"
        }
        Section::Models => "favorite hidden custom model catalog",
        Section::Usage => "account limits tokens cost credits history",
        Section::Instructions => "global shared master agents rules git sync",
        Section::Archive => "archived conversations restore delete undo",
        Section::Keyboard => "shortcuts keys bindings",
        Section::Voice => "dictation speech microphone transcription",
        Section::Browser => "web passwords profile cookies",
        Section::ComputerUse => "screen accessibility permissions control",
        Section::Media => "historical images attachments media",
        Section::Accounts => "providers overview agents accounts login",
        Section::Provider(_) => "provider accounts login models executable",
        Section::About => "version help community website support license privacy terms",
        _ => "",
    };
    let text = format!("{} {keywords}", section.label()).to_lowercase();
    query.split_whitespace().all(|term| text.contains(term))
}

impl Coincide {
    fn navigate_settings_section(
        &mut self,
        section: Section,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.archive_settings.close_review();
        self.credential_panel
            .update(cx, |panel, cx| panel.cancel(cx));
        self.bots_open = false;
        self.notifications_open = false;
        self.transcription_open = section == Section::Voice;
        self.credentials_open = false;
        self.browser_settings_open = section == Section::Browser;
        self.media.opened = section == Section::Media;
        self.computer_use_open = section == Section::ComputerUse;
        self.session_import_open = false;
        self.provider_settings.open = false;
        self.settings_section = section;
        self.models_settings.focus_provider(match section {
            Section::Provider(provider) => Some(provider_key(provider).to_owned()),
            _ => None,
        });
        self.settings_search
            .update(cx, |search, cx| search.set_value("", window, cx));
        if section == Section::Archive {
            self.refresh_archive_settings(cx);
        }
        self.focus_settings_route(window, cx);
        self.sync_transcription_binding(cx);
        cx.notify();
    }

    fn settings_navigation_row(
        &self,
        section: Section,
        label: &'static str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let selected = self.settings_section == section;
        let enabled = match section {
            Section::Provider(provider) => provider_enabled(&self.settings, provider),
            _ => true,
        };
        Button::new(SharedString::from(format!(
            "settings-section-{}",
            section.id()
        )))
        .accessibility_label(label)
        .w_full()
        .h(px(30.))
        .ghost()
        .when(selected, |button| button.bg(self.color(0x202a3b)))
        .child(
            div()
                .flex()
                .items_center()
                .w_full()
                .gap_2()
                .child(icon_tile(section, 20.))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_color(self.color(0xe4e9f2).opacity(if enabled { 1. } else { 0.5 }))
                        .child(label),
                )
                .when(matches!(section, Section::Provider(_)), |row| {
                    row.child(
                        div()
                            .w(px(7.))
                            .h(px(7.))
                            .rounded(px(4.))
                            .bg(rgb(if enabled { 0x8b8f97 } else { 0x696c71 })),
                    )
                }),
        )
        .on_click(cx.listener(move |this, _, window, cx| {
            this.navigate_settings_section(section, window, cx)
        }))
        .into_any_element()
    }

    pub(super) fn settings_surface(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut navigation = div().flex().flex_col().gap_1();
        for section in [
            Section::General,
            Section::Models,
            Section::Usage,
            Section::Instructions,
            Section::Archive,
            Section::Keyboard,
            Section::Voice,
            Section::Browser,
            Section::ComputerUse,
            Section::Media,
        ] {
            navigation =
                navigation.child(self.settings_navigation_row(section, section.label(), cx));
        }
        navigation = navigation
            .child(
                div()
                    .mt_3()
                    .px_2()
                    .text_xs()
                    .text_color(self.color(0xe4e9f2).opacity(0.6))
                    .child("Providers"),
            )
            .child(self.settings_navigation_row(Section::Accounts, "Overview", cx));
        for provider in coincide_core::provider_catalog::provider_catalog() {
            navigation = navigation.child(self.settings_navigation_row(
                Section::Provider(provider.id),
                provider.display_name,
                cx,
            ));
        }
        navigation = navigation.child(div().mt_3().child(self.settings_navigation_row(
            Section::About,
            "About",
            cx,
        )));
        let query = self.settings_search.read(cx).value().trim().to_lowercase();
        if !query.is_empty() {
            navigation = div()
                .flex()
                .flex_col()
                .gap_1()
                .child(div().px_2().text_xs().child("Results"));
            let mut count = 0;
            for section in [
                Section::General,
                Section::Models,
                Section::Usage,
                Section::Instructions,
                Section::Archive,
                Section::Keyboard,
                Section::Voice,
                Section::Browser,
                Section::ComputerUse,
                Section::Media,
                Section::Accounts,
                Section::About,
            ]
            .into_iter()
            .chain(
                coincide_core::provider_catalog::provider_catalog()
                    .iter()
                    .map(|p| Section::Provider(p.id)),
            ) {
                if search_matches(section, &query) {
                    count += 1;
                    navigation = navigation.child(self.settings_navigation_row(
                        section,
                        section.label(),
                        cx,
                    ));
                }
            }
            if count == 0 {
                navigation = navigation.child(div().p_2().child("No results"));
            }
        }
        let parent = cx.entity().downgrade();
        let resize = gpui_kit::component::resizable::resize_handle(
            "settings-sidebar-resize",
            Axis::Horizontal,
        )
        .inside(gpui_kit::component::resizable::HandleEdge::Trailing)
        .role(Role::Splitter)
        .aria_label("Resize Settings sidebar")
        .on_drag(ResizeSettings, move |drag, _, window, cx| {
            let pointer = f32::from(window.mouse_position().x);
            let active = window.is_window_active();
            let _ = parent.update(cx, |owner, _| {
                if active {
                    owner.settings_navigation.drag =
                        Some((pointer, owner.settings_navigation.width()));
                }
            });
            cx.new(|_| drag.clone())
        });
        div()
            .id("settings-pane")
            .flex_1()
            .min_w_0()
            .min_h_0()
            .overflow_hidden()
            .flex()
            .on_drag_move(cx.listener(
                |owner, event: &DragMoveEvent<ResizeSettings>, window, cx| {
                    if window.is_window_active()
                        && owner
                            .settings_navigation
                            .move_to(f32::from(event.event.position.x))
                    {
                        cx.notify();
                    }
                },
            ))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|owner, _, _, _| owner.settings_navigation.drag = None),
            )
            .on_mouse_up_out(
                MouseButton::Left,
                cx.listener(|owner, _, _, _| owner.settings_navigation.drag = None),
            )
            .child(
                div()
                    .id("settings-sidebar")
                    .relative()
                    .w(px(self.settings_navigation.width()))
                    .min_w(px(200.))
                    .flex_shrink_0()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .p_3()
                    .bg(self.color(0x151922))
                    .border_r_1()
                    .border_color(self.color(0x29303d))
                    .child(Input::new(&self.settings_search))
                    .child(
                        div()
                            .id("settings-destinations")
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .child(navigation),
                    )
                    .child(resize),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .min_h_0()
                    .overflow_hidden()
                    .flex()
                    .flex_col()
                    .child(self.settings_detail_surface(cx)),
            )
            .into_any_element()
    }

    fn set_settings_provider_enabled(
        &mut self,
        provider: ProviderId,
        expected: bool,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if provider == ProviderId::Antigravity {
            self.open_antigravity_settings(window, cx);
            return;
        }
        let result = (|| -> Result<Value> {
            let mut owner = try_state(&self.engine)?;
            let current = owner
                .store
                .document("settings.json")?
                .unwrap_or_else(|| json!({}));
            let patch = enabled_patch(&current, provider, expected, enabled)?;
            let reply = owner.dispatch(json!({"method":"settings.patch","params":{"patch":patch}}));
            if let Some(error) = reply.get("error") {
                anyhow::bail!(
                    "{}",
                    error["message"]
                        .as_str()
                        .unwrap_or("Provider settings could not be saved")
                );
            }
            Ok(reply["result"].clone())
        })();
        match result {
            Ok(settings) => {
                self.settings_status = "Saved".into();
                self.accept_settings(settings, window, cx);
            }
            Err(error) => {
                self.settings_status = error.to_string();
                cx.notify();
            }
        }
    }

    pub(super) fn provider_preferences_pane(
        &self,
        provider: ProviderId,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let section = Section::Provider(provider);
        let enabled = provider_enabled(&self.settings, provider);
        let mut pane = div()
            .id("provider-preferences")
            .flex_1()
            .min_w_0()
            .min_h_0()
            .overflow_y_scroll()
            .p_5()
            .flex()
            .flex_col()
            .gap_4()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(icon_tile(section, 44.))
                    .child(div().flex_1().text_xl().child(section.label()))
                    .child(
                        Button::new("provider-preferences-done")
                            .label("Done")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.close_settings_panel(window, cx)
                            })),
                    ),
            )
            .child(
                div()
                    .rounded_md()
                    .border_1()
                    .border_color(self.color(0x29303d))
                    .p_4()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_3()
                    .child(div().flex_1().child(format!("Use {}", section.label())))
                    .child(
                        Button::new("provider-preferences-enabled")
                            .label(if enabled { "On" } else { "Off" })
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.set_settings_provider_enabled(
                                    provider, enabled, !enabled, window, cx,
                                )
                            })),
                    ),
            )
            .child(div().text_sm().child(
                "Coincide uses this provider’s command-line tool and your existing sign-in.",
            ));
        match provider {
            ProviderId::Codex => {
                pane = pane.child(
                    Button::new("provider-codex-accounts")
                        .label("Accounts and sign-in")
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.open_codex_account_settings(window, cx)
                        })),
                )
            }
            ProviderId::Antigravity => {
                pane = pane.child(
                    Button::new("provider-antigravity-accounts")
                        .label("Account setup and risk information")
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.open_antigravity_settings(window, cx)
                        })),
                )
            }
            _ => {}
        }
        pane.child(self.models_settings_panel(&[self.selection_ui.catalog.clone()], cx))
            .child(div().text_sm().child(self.settings_status.clone()))
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::{State, enabled_patch, provider_enabled, search_matches};
    use coincide_core::provider_catalog::ProviderId as P;
    use serde_json::json;

    #[::core::prelude::v1::test]
    fn provider_toggle_preserves_unknown_fields_and_other_provider_records() {
        let current = json!({"providers":{"claude":{"future":{"keep":1},"customModels":["x"]},"codex":{"isEnabled":false,"future":2}},"future":3});
        let patch = enabled_patch(&current, P::Claude, true, false).unwrap();
        assert_eq!(
            patch,
            json!({"providers":{"claude":{"future":{"keep":1},"customModels":["x"],"isEnabled":false},"codex":{"isEnabled":false,"future":2}}})
        );
        assert!(provider_enabled(&current, P::Claude));
    }

    #[::core::prelude::v1::test]
    fn provider_toggle_preserves_swift_alternating_dictionary_and_rejects_stale_state() {
        let current =
            json!({"providers":["future",{"keep":7},"codex",{"isEnabled":false,"future":8}]});
        assert_eq!(
            enabled_patch(&current, P::Codex, false, true).unwrap(),
            json!({"providers":["future",{"keep":7},"codex",{"isEnabled":true,"future":8}]})
        );
        assert!(enabled_patch(&current, P::Codex, true, false).is_err());
        assert!(enabled_patch(&json!({"providers":["codex"]}), P::Codex, true, false).is_err());
    }

    #[::core::prelude::v1::test]
    fn sidebar_resize_bounds_and_search_route_to_real_destinations() {
        let mut state = State::default();
        state.drag = Some((100., state.width()));
        assert!(state.move_to(-500.));
        assert_eq!(state.width(), 200.);
        assert!(state.move_to(500.));
        assert_eq!(state.width(), 280.);
        assert!(!state.move_to(f32::NAN));
        state.drag = None;
        assert!(!state.move_to(100.));
        assert!(search_matches(
            super::Section::Provider(P::Claude),
            "claude models"
        ));
        assert!(search_matches(super::Section::General, "dark theme"));
        assert!(!search_matches(super::Section::Browser, "claude"));
    }

    #[::core::prelude::v1::test]
    fn generic_toggle_cannot_bypass_antigravity_risk_controls() {
        assert!(!provider_enabled(&json!({}), P::Antigravity));
        assert!(enabled_patch(&json!({}), P::Antigravity, false, true).is_err());
    }
}
