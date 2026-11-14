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
        Section::Appshots => (I::Camera, 0x386dc2),
        Section::Media => (I::GalleryVerticalEnd, 0xb77927),
        Section::Accounts => (I::LayoutDashboard, 0x5d64bb),
        Section::Provider(_) => (I::Cpu, 0x717782),
        Section::About => (I::Info, 0x347cc4),
        _ => (I::Settings2, 0x737780),
    }
}

fn icon_tile(section: Section, size: f32) -> AnyElement {
    if let Section::Provider(provider) = section
        && let Some(logo) = chat_layout::provider_mark(provider_key(provider), size)
    {
        return logo.into_any_element();
    }
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

pub(super) fn provider_enabled(settings: &Value, provider: ProviderId) -> bool {
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
    enabled_value_patch(settings, provider, expected, enabled)
}

fn enabled_value_patch(
    settings: &Value,
    provider: ProviderId,
    expected: bool,
    enabled: bool,
) -> Result<Value> {
    anyhow::ensure!(settings.is_object(), "Saved settings are malformed");
    let current = if provider == ProviderId::Antigravity
        && models_settings::provider_value(settings, provider_key(provider))["isEnabled"].is_null()
    {
        false
    } else {
        coincide_core::provider_preferences::enabled(settings, provider_key(provider))?
    };
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

impl Coincide {
    pub(super) fn navigate_settings_section(
        &mut self,
        section: Section,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if section != Section::Appshots && self.appshots.recording {
            self.appshots.recording = false;
            self.appshots.invalidate();
        }
        if section == Section::Appshots {
            self.appshots.permissions = appshots_platform::permissions(0);
        }
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
        if let Section::Provider(provider) = section {
            let enabled = provider_enabled(&self.settings, provider);
            self.provider_configuration_panel.update(cx, |panel, cx| {
                panel.select(provider_key(provider), enabled, window, cx)
            });
        }
        self.models_settings.focus_provider(match section {
            Section::Provider(provider) => Some(provider_key(provider).to_owned()),
            _ => None,
        });
        self.settings_search
            .update(cx, |search, cx| search.set_value("", window, cx));
        if section == Section::Archive {
            self.refresh_archive_settings(cx);
        }
        if section == Section::General {
            self.general_settings.refresh_command_line_tool();
        }
        if section == Section::Voice {
            self.refresh_voice_environment(cx);
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
        let status = match section {
            Section::Provider(provider) => Some(
                self.provider_configuration_panel
                    .read(cx)
                    .status_dot(provider_key(provider), enabled),
            ),
            _ => None,
        };
        Button::new(SharedString::from(format!(
            "settings-section-{}",
            section.id()
        )))
        .accessibility_label(match status {
            Some((headline, _)) => SharedString::from(format!("{label}, {headline}")),
            None => label.into(),
        })
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
                .when_some(status, |row, (headline, tint)| {
                    row.child(
                        div()
                            .id(SharedString::from(format!(
                                "settings-status-{}",
                                section.id()
                            )))
                            .w(px(7.))
                            .h(px(7.))
                            .rounded(px(4.))
                            .bg(rgb(tint))
                            .tooltip(move |window, cx| {
                                gpui_kit::component::tooltip::Tooltip::new(headline)
                                    .build(window, cx)
                            }),
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
            Section::Appshots,
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
        let query = self.settings_search.read(cx).value().to_string();
        if !query.trim().is_empty() {
            navigation = div().child(self.settings_search_results(&query, cx));
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
            .text_size(px(13.))
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
                        self.settings_scroll.frame(
                            "navigation",
                            div()
                                .id("settings-destinations")
                                .flex_1()
                                .min_h_0()
                                .overflow_y_scroll()
                                .child(navigation),
                        ),
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
        if self
            .provider_enable_prompt
            .as_ref()
            .is_some_and(|task| !task.is_ready())
        {
            return;
        }
        if provider == ProviderId::Antigravity && enabled {
            match call(&self.engine, "providers.antigravity.status", json!({})) {
                Ok(status) if status["riskAcknowledged"] != true => {
                    let answer = window.prompt(
                        PromptLevel::Warning,
                        "Use Antigravity?",
                        Some(provider_settings::RISK_NOTICE),
                        &["I Understand", "Cancel"],
                        cx,
                    );
                    let custody = self
                        .provider_configuration_panel
                        .read(cx)
                        .native_action_custody();
                    self.provider_enable_prompt =
                        Some(cx.spawn_in(window, async move |this, cx| {
                            let _custody = custody;
                            let accepted = answer.await.unwrap_or(1) == 0;
                            if accepted {
                                this.update_in(cx, |this, window, cx| {
                                    // The prompt is now resolved; this direct continuation
                                    // performs acknowledgement and the original CAS once.
                                    match call(
                                        &this.engine,
                                        "providers.antigravity.acknowledge",
                                        json!({"key":provider_settings::RISK_KEY,"accepted":true}),
                                    ) {
                                        Ok(_) => this.apply_settings_provider_enabled(
                                            provider, expected, enabled, window, cx,
                                        ),
                                        Err(error) => {
                                            this.settings_status = error.to_string();
                                            cx.notify();
                                        }
                                    }
                                })
                                .ok();
                            }
                        }));
                    return;
                }
                Err(error) => {
                    self.settings_status = error.to_string();
                    cx.notify();
                    return;
                }
                _ => {}
            }
        }
        self.apply_settings_provider_enabled(provider, expected, enabled, window, cx);
    }

    fn apply_settings_provider_enabled(
        &mut self,
        provider: ProviderId,
        expected: bool,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let result = (|| -> Result<Value> {
            let mut owner = try_state(&self.engine)?;
            let current = owner
                .store
                .document("settings.json")?
                .unwrap_or_else(|| json!({}));
            let patch = if provider == ProviderId::Antigravity {
                if enabled {
                    let status = owner
                        .dispatch(json!({"method":"providers.antigravity.status","params":{}}));
                    anyhow::ensure!(
                        status["result"]["riskAcknowledged"] == true,
                        "Acknowledge the Antigravity account risk first"
                    );
                }
                enabled_value_patch(&current, provider, expected, enabled)?
            } else {
                enabled_patch(&current, provider, expected, enabled)?
            };
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

    pub(super) fn sync_provider_configuration_settings(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let context = match self.settings_section {
            Section::Provider(provider) => Some(provider_key(provider)),
            _ => None,
        };
        self.provider_configuration_panel
            .update(cx, |panel, _| panel.set_account_context(context));
        if let Some(account) = self
            .provider_configuration_panel
            .update(cx, |panel, _| panel.take_legacy_codex_sign_in())
        {
            self.open_codex_profile_settings_for(account, window, cx);
        }
        if self.settings_section == Section::Usage {
            for provider in [ProviderId::Claude, ProviderId::Opencode] {
                let enabled = provider_enabled(&self.settings, provider);
                self.provider_configuration_panel.update(cx, |panel, cx| {
                    panel.select(provider_key(provider), enabled, window, cx)
                });
            }
        }
        if let Section::Provider(provider) = self.settings_section {
            let enabled = provider_enabled(&self.settings, provider);
            self.provider_configuration_panel.update(cx, |panel, cx| {
                panel.select(provider_key(provider), enabled, window, cx)
            });
        }
    }

    pub(super) fn block_provider_configuration_close(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let provider = self
            .provider_configuration_panel
            .read(cx)
            .dirty_provider(cx);
        let pending = self
            .provider_enable_prompt
            .as_ref()
            .is_some_and(|task| !task.is_ready())
            || self
                .provider_configuration_panel
                .read(cx)
                .has_pending_write();
        if provider.is_none() && !pending {
            return false;
        }
        if let Some(guard) = &self.native_quit {
            guard.cancel_request();
        }
        self.native_quit_observed = false;
        self.open_settings_panel(window, cx);
        if let Some(provider) = provider.and_then(|key| {
            coincide_core::provider_catalog::PROVIDERS
                .iter()
                .find(|provider| provider_key(provider.id) == key)
                .map(|provider| provider.id)
        }) {
            self.settings_open = true;
            self.navigate_settings_section(Section::Provider(provider), window, cx);
        }
        self.settings_status = if pending {
            "Wait for the provider operation or executable chooser to finish before closing."
        } else {
            "Save or discard provider changes before closing."
        }
        .into();
        cx.notify();
        true
    }

    pub(super) fn providers_overview_pane(&self, cx: &mut Context<Self>) -> AnyElement {
        let panel = self.provider_configuration_panel.read(cx);
        let mut pane = div()
            .id("providers-overview")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p_5()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .text_sm()
                    .text_color(self.color(0xe4e9f2).opacity(0.68))
                    .child("Choose which agents are available in Coincide."),
            );
        for descriptor in coincide_core::provider_catalog::PROVIDERS {
            let provider = descriptor.id;
            let section = Section::Provider(provider);
            let enabled = provider_enabled(&self.settings, provider);
            let summary = if enabled {
                panel.summary(provider_key(provider))
            } else {
                "Off".into()
            };
            pane = pane.child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .p_4()
                    .rounded(px(10.))
                    .border_1()
                    .border_color(self.color(0x29303d))
                    .bg(self.color(0x111722))
                    .child(icon_tile(section, 30.))
                    .child(
                        div().flex_1().child(descriptor.display_name).child(
                            div()
                                .text_xs()
                                .text_color(self.color(0xe4e9f2).opacity(0.65))
                                .child(summary),
                        ),
                    )
                    .child(
                        gpui_kit::component::switch::Switch::new(SharedString::from(format!(
                            "provider-overview-use-{}",
                            provider_key(provider)
                        )))
                        .accessibility_label(format!("Use {}", descriptor.display_name))
                        .checked(enabled)
                        .color(self.color(0xe4e9f2))
                        .on_click(cx.listener(
                            move |this, value: &bool, window, cx| {
                                this.set_settings_provider_enabled(
                                    provider, enabled, *value, window, cx,
                                )
                            },
                        )),
                    )
                    .child(
                        Button::new(SharedString::from(format!(
                            "provider-overview-open-{}",
                            provider_key(provider)
                        )))
                        .icon(gpui_kit::assets::IconName::ChevronRight)
                        .ghost()
                        .small()
                        .accessibility_label(format!("Show {} settings", descriptor.display_name))
                        .tooltip("Show settings")
                        .on_click(cx.listener(
                            move |this, _, window, cx| {
                                this.navigate_settings_section(section, window, cx)
                            },
                        )),
                    ),
            );
        }
        let content = pane
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(panel.last_checked())
                    .child(
                        Button::new("providers-check-all")
                            .label("Check All Again")
                            .disabled(panel.checking_all())
                            .on_click(cx.listener(|this, _, window, cx| {
                                let providers = coincide_core::provider_catalog::PROVIDERS
                                    .iter()
                                    .filter(|descriptor| {
                                        provider_enabled(&this.settings, descriptor.id)
                                    })
                                    .map(|descriptor| provider_key(descriptor.id).to_owned())
                                    .collect::<Vec<_>>();
                                this.provider_configuration_panel.update(cx, |panel, cx| {
                                    panel.check_all(&providers, window, cx)
                                });
                            })),
                    ),
            )
            .child(div().text_sm().child(self.settings_status.clone()));
        div()
            .flex_1()
            .min_h_0()
            .min_w_0()
            .flex()
            .flex_col()
            .child(self.settings_subpage_header("Providers", "providers-overview-done", cx))
            .child(self.settings_scroll.frame("providers-overview", content))
            .into_any_element()
    }

    pub(super) fn provider_preferences_pane(
        &self,
        provider: ProviderId,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let section = Section::Provider(provider);
        let enabled = provider_enabled(&self.settings, provider);
        let parts = if self
            .provider_configuration_panel
            .read(cx)
            .is_selected(provider_key(provider))
        {
            self.provider_configuration_panel.update(cx, |panel, cx| {
                [
                    provider_configuration_ui::Part::Status,
                    provider_configuration_ui::Part::Executable,
                    provider_configuration_ui::Part::Environment,
                    provider_configuration_ui::Part::Setup,
                    provider_configuration_ui::Part::Accounts,
                ]
                .map(|part| panel.render_part(part, cx))
            })
        } else {
            std::array::from_fn(|_| div().child("Loading provider settings…").into_any_element())
        };
        let [status, executable, environment, setup, accounts] = parts;
        let header = div()
            .flex_none()
            .min_w_0()
            .flex()
            .items_center()
            .gap_3()
            .p_4()
            .border_b_1()
            .border_color(self.color(0x29303d))
            .child(icon_tile(section, 44.))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .text_xl()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(section.label()),
            )
            .child(
                Button::new("provider-preferences-done")
                    .label("Done")
                    .on_click(
                        cx.listener(|this, _, window, cx| this.close_settings_panel(window, cx)),
                    ),
            );
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
                    .rounded(px(10.))
                    .bg(self.color(0x111722))
                    .child(status),
            )
            .child(
                div()
                    .rounded(px(10.))
                    .border_1()
                    .border_color(self.color(0x29303d))
                    .bg(self.color(0x111722))
                    .p_4()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_3()
                    .child(div().flex_1().child(format!("Use {}", section.label())))
                    .child(
                        gpui_kit::component::switch::Switch::new("provider-preferences-enabled")
                            .accessibility_label(format!("Use {}", section.label()))
                            .checked(enabled)
                            .color(self.color(0xe4e9f2))
                            .on_click(cx.listener(move |this, value: &bool, window, cx| {
                                this.set_settings_provider_enabled(
                                    provider, enabled, *value, window, cx,
                                )
                            })),
                    ),
            )
            .child(
                div()
                    .text_xs()
                    .text_color(self.color(0x98a6ba))
                    .child("Uses the provider’s command-line tool and your existing sign-in."),
            );
        if enabled {
            pane = pane.child(
                div()
                    .rounded(px(10.))
                    .bg(self.color(0x111722))
                    .child(accounts),
            );
        }
        if enabled && provider == ProviderId::Cursor && cfg!(target_os = "macos") {
            pane = pane.child(self.settings_group(
                "Account usage",
                self.setting_toggle(
                    "Show Cursor plan limits",
                    "Read the Cursor CLI sign-in from Keychain to show its usage. macOS may ask to allow access.",
                    "cursorKeychainUsageEnabled",
                    false,
                    "cursor-keychain-usage",
                    cx,
                ),
            ));
        }
        match provider {
            ProviderId::Codex => {
                pane = pane.child(
                    Button::new("provider-codex-accounts")
                        .label("Legacy account settings…")
                        .small()
                        .ghost()
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
        let mut catalogs = self.provider_configuration_panel.read(cx).catalogs();
        catalogs.push(self.selection_ui.catalog.clone());
        let content = self.settings_scroll.frame(
            provider_key(provider),
            pane.child(
                div()
                    .rounded(px(10.))
                    .bg(self.color(0x111722))
                    .child(executable),
            )
            .child(self.models_settings_panel(&catalogs, cx))
            .child(
                div()
                    .rounded(px(10.))
                    .bg(self.color(0x111722))
                    .child(environment),
            )
            .child(div().rounded(px(10.)).bg(self.color(0x111722)).child(setup))
            .child(div().text_sm().child(self.settings_status.clone())),
        );
        div()
            .flex_1()
            .min_h_0()
            .min_w_0()
            .flex()
            .flex_col()
            .child(header)
            .child(content)
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::{State, enabled_patch, provider_enabled};
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
    fn sidebar_resize_stays_within_bounds() {
        let mut state = State::default();
        state.drag = Some((100., state.width()));
        assert!(state.move_to(-500.));
        assert_eq!(state.width(), 200.);
        assert!(state.move_to(500.));
        assert_eq!(state.width(), 280.);
        assert!(!state.move_to(f32::NAN));
        state.drag = None;
        assert!(!state.move_to(100.));
    }

    #[::core::prelude::v1::test]
    fn native_antigravity_toggle_round_trip_preserves_provider_values_and_rejects_stale_state() {
        for providers in [
            json!({"antigravity":{"opaque":42,"environment":{"SYNTHETIC_TEST_MODE":"fixture"}}}),
            json!(["antigravity",{"opaque":42,"environment":{"SYNTHETIC_TEST_MODE":"fixture"}}]),
        ] {
            let initial = json!({"providers":providers});
            let on = super::enabled_value_patch(&initial, P::Antigravity, false, true).unwrap();
            let value = super::models_settings::provider_value(&on, "antigravity");
            assert_eq!(value["isEnabled"], true);
            assert_eq!(value["opaque"], 42);
            assert_eq!(
                value["environment"],
                json!({"SYNTHETIC_TEST_MODE":"fixture"})
            );
            assert!(super::enabled_value_patch(&on, P::Antigravity, false, true).is_err());
            let off = super::enabled_value_patch(&on, P::Antigravity, true, false).unwrap();
            assert!(!provider_enabled(&off, P::Antigravity));
            assert_eq!(
                super::models_settings::provider_value(&off, "antigravity")["opaque"],
                42
            );
            assert!(enabled_patch(&initial, P::Antigravity, false, true).is_err());
        }
    }
    #[::core::prelude::v1::test]
    fn generic_toggle_cannot_bypass_antigravity_risk_controls() {
        assert!(!provider_enabled(&json!({}), P::Antigravity));
        assert!(enabled_patch(&json!({}), P::Antigravity, false, true).is_err());
    }
}
