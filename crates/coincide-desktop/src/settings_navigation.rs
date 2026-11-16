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
    pub(super) agent_view: Value,
    last_agent_read: Option<Instant>,
    last_agent_scan: Option<Instant>,
    agent_read_pending: bool,
    agent_add_pending: bool,
    logo_requests: std::collections::HashMap<String, Instant>,
    logo_pending: bool,
    show_more_agents: bool,
    show_custom_agent: bool,
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
        ProviderId::Lithos => "lithos",
        ProviderId::Antigravity => "antigravity",
    }
}

fn section_icon(section: Section) -> gpui_kit::assets::IconName {
    use gpui_kit::assets::IconName as I;
    match section {
        Section::General => I::Settings,
        Section::Models => I::Boxes,
        Section::Usage => I::ChartColumn,
        Section::Instructions => I::BookOpen,
        Section::Archive => I::Archive,
        Section::Keyboard => I::Keyboard,
        Section::Voice => I::Mic,
        Section::Browser => I::Globe,
        Section::ComputerUse => I::Monitor,
        Section::Appshots => I::Camera,
        Section::Media => I::GalleryVerticalEnd,
        Section::Accounts => I::LayoutDashboard,
        Section::Provider(_) => I::Cpu,
        Section::About => I::Info,
        _ => I::Settings2,
    }
}

pub(super) fn icon_tile(section: Section, size: f32, surface: Rgba, ink: Rgba) -> AnyElement {
    if let Section::Provider(provider) = section
        && let Some(logo) = chat_layout::provider_mark(provider_key(provider), size)
    {
        return logo.into_any_element();
    }
    div()
        .w(px(size))
        .h(px(size))
        .flex_shrink_0()
        .rounded(px(size * 0.3))
        .bg(surface)
        .text_color(ink)
        .flex()
        .items_center()
        .justify_center()
        .child(Icon::new(section_icon(section)).size(px(size * 0.55)))
        .into_any_element()
}

pub(super) fn provider_enabled(settings: &Value, provider: ProviderId) -> bool {
    coincide_core::provider_preferences::enabled(settings, provider_key(provider)).unwrap_or(false)
}

/// Presentation only: an absent or temporarily unreadable executable never
/// changes saved preferences, nor does it invalidate an existing thread.
pub(super) fn provider_is_shown(
    settings: &Value,
    view: &Value,
    provider: ProviderId,
    selected: Option<&str>,
) -> bool {
    let key = provider_key(provider);
    let explicit = models_settings::provider_value(settings, key)["isEnabled"] == true;
    let configured = view["configured"]
        .as_array()
        .is_some_and(|rows| rows.iter().any(|row| row == key));
    if explicit || configured || selected == Some(key) {
        return true;
    }
    if provider == ProviderId::Lithos {
        // OpenCode is its runtime, not evidence that Lithos has been set up.
        return false;
    }
    view["discovery"]["providers"]
        .as_array()
        .is_some_and(|rows| {
            rows.iter()
                .any(|row| row["provider"] == key && row["state"] == "found")
        })
}

pub(super) fn registry_agent_rows(view: &Value, include_extra: bool, query: &str) -> Vec<Value> {
    let mut rows = view["agents"].as_array().cloned().unwrap_or_default();
    for registered in view["registered"].as_array().into_iter().flatten() {
        let Some(id) = registered["provider"]
            .as_str()
            .and_then(coincide_core::acp_registry::registry_id)
        else {
            continue;
        };
        if let Some(row) = rows.iter_mut().find(|row| row["id"] == id) {
            row["registered"] = json!(true);
        } else {
            rows.push(json!({"id":id,"name":registered["displayName"],"registered":true}));
        }
    }
    let query = query.to_lowercase();
    rows.retain(|row| {
        (include_extra || row["executable"].is_string() || row["registered"] == true)
            && (query.is_empty() || text(row, "name").to_lowercase().contains(&query))
    });
    rows.sort_by_key(|row| {
        (
            row["executable"].is_null() && row["registered"] != true,
            text(row, "name").to_lowercase(),
        )
    });
    rows
}

fn enabled_patch(
    settings: &Value,
    provider: ProviderId,
    expected: bool,
    enabled: bool,
) -> Result<Value> {
    enabled_value_patch(settings, provider, expected, enabled)
}

fn enabled_value_patch(
    settings: &Value,
    provider: ProviderId,
    expected: bool,
    enabled: bool,
) -> Result<Value> {
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

impl Coincide {
    pub(super) fn poll_agent_discovery(&mut self, cx: &mut Context<Self>) {
        if !(self.settings_open || self.selection_ui.expanded)
            || self.settings_navigation.agent_read_pending
            || self
                .settings_navigation
                .last_agent_read
                .is_some_and(|at| at.elapsed() < Duration::from_secs(1))
        {
            return;
        }
        self.settings_navigation.agent_read_pending = true;
        self.settings_navigation.last_agent_read = Some(Instant::now());
        let rescan = self
            .settings_navigation
            .last_agent_scan
            .is_none_or(|at| at.elapsed() >= Duration::from_secs(60));
        if rescan {
            self.settings_navigation.last_agent_scan = Some(Instant::now());
        }
        let engine = self.engine.clone();
        cx.spawn(async move |this, cx| {
            let view = cx
                .background_executor()
                .spawn(async move {
                    try_state(&engine).map(|mut engine| {
                        if rescan {
                            let _ = engine.refresh_native_provider_discovery();
                            let _ = engine.refresh_native_acp_registry();
                        }
                        engine.native_acp_registry_view()
                    })
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.settings_navigation.agent_read_pending = false;
                if view.is_err() && rescan {
                    this.settings_navigation.last_agent_scan = None;
                }
                if let Ok(view) = view
                    && this.settings_navigation.agent_view != view
                {
                    this.settings_navigation.agent_view = view;
                    cx.notify();
                }
                this.refresh_new_agent_logos(cx);
            });
        })
        .detach();
    }

    fn refresh_new_agent_logos(&mut self, cx: &mut Context<Self>) {
        if self.settings_navigation.logo_pending {
            return;
        }
        let now = Instant::now();
        // Keep an unexpectedly large registry from creating unbounded network
        // requests or in-memory image state during a single app run.
        let remaining = 128usize.saturating_sub(self.settings_navigation.logo_requests.len());
        let ids = self.settings_navigation.agent_view["agents"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|agent| {
                let id = agent["id"].as_str()?;
                if agent["icon"].as_str().is_none()
                    || agent_logo_assets::logo(id).is_some()
                    || (remaining == 0 && !self.settings_navigation.logo_requests.contains_key(id))
                    || self
                        .settings_navigation
                        .logo_requests
                        .get(id)
                        .is_some_and(|at| at.elapsed() < Duration::from_secs(300))
                {
                    return None;
                }
                Some(id.to_owned())
            })
            .take(4)
            .collect::<Vec<_>>();
        if ids.is_empty() {
            return;
        }
        for id in &ids {
            self.settings_navigation
                .logo_requests
                .insert(id.clone(), now);
        }
        self.settings_navigation.logo_pending = true;
        cx.spawn(async move |this, cx| {
            let fetched = cx
                .background_executor()
                .spawn(async move {
                    ids.into_iter()
                        .filter_map(|id| {
                            coincide_core::acp_registry::fetch_icon(&id)
                                .ok()
                                .map(|bytes| (id, bytes))
                        })
                        .collect::<Vec<_>>()
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.settings_navigation.logo_pending = false;
                for (id, bytes) in fetched {
                    agent_logo_assets::remember(id, bytes);
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn refresh_agent_discovery(&mut self, cx: &mut Context<Self>) {
        self.settings_navigation.last_agent_scan = None;
        let engine = self.engine.clone();
        cx.spawn(async move |this, cx| {
            let _ = cx
                .background_executor()
                .spawn(async move {
                    if let Ok(mut engine) = try_state(&engine) {
                        let _ = engine.refresh_native_provider_discovery();
                        let _ = engine.refresh_native_acp_registry();
                    }
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.settings_navigation.last_agent_read = None;
                this.poll_agent_discovery(cx);
            });
        })
        .detach();
    }

    fn add_registry_agent_in_settings(&mut self, id: String, cx: &mut Context<Self>) {
        if self.settings_navigation.agent_add_pending {
            return;
        }
        self.settings_navigation.agent_add_pending = true;
        let engine = self.engine.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let mut owner = engine
                        .lock()
                        .map_err(|_| anyhow::anyhow!("App engine is unavailable"))?;
                    owner.add_native_registry_agent(&id)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.settings_navigation.agent_add_pending = false;
                this.settings_status = match result {
                    Ok(_) => "Agent added. You can select it in a conversation.".into(),
                    Err(error) => format!("Agent could not be added: {error}"),
                };
                this.settings_navigation.last_agent_read = None;
                this.refresh_provider_preferences(cx);
                this.poll_agent_discovery(cx);
                cx.notify();
            });
        })
        .detach();
    }

    fn add_custom_agent_in_settings(&mut self, cx: &mut Context<Self>) {
        if self.settings_navigation.agent_add_pending {
            return;
        }
        self.settings_navigation.agent_add_pending = true;
        let name = self.custom_acp_name.read(cx).value().trim().to_owned();
        let command = self
            .custom_acp_executable
            .read(cx)
            .value()
            .trim()
            .to_owned();
        let args = self.custom_acp_arguments.read(cx).value().to_string();
        let engine = self.engine.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    anyhow::ensure!(!name.is_empty(), "Enter an agent name");
                    let executable = coincide_core::acp_registry::resolve_executable(&command)
                        .context("Choose an installed command or executable path")?;
                    let arguments =
                        shell_words::split(&args).context("Check the agent arguments")?;
                    let agent = coincide_core::acp_registry::Agent {
                        icon: None,
                        id: format!("custom-{}", uuid::Uuid::new_v4().simple()),
                        name,
                        website: None,
                        executable: Some(executable),
                        arguments,
                        environment: Default::default(),
                    };
                    let mut owner = engine
                        .lock()
                        .map_err(|_| anyhow::anyhow!("App engine is unavailable"))?;
                    owner.register_native_acp_agent(&agent)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.settings_navigation.agent_add_pending = false;
                this.settings_status = match result {
                    Ok(()) => {
                        this.settings_navigation.show_custom_agent = false;
                        "Agent added. You can select it in a conversation.".into()
                    }
                    Err(error) => format!("Agent could not be added: {error}"),
                };
                this.settings_navigation.last_agent_read = None;
                this.refresh_provider_preferences(cx);
                this.poll_agent_discovery(cx);
                cx.notify();
            });
        })
        .detach();
    }

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
        .h(px(38.))
        .rounded(px(10.))
        .ghost()
        .when(selected, |button| button.bg(self.color(0x202a3b)))
        .child(
            div()
                .flex()
                .items_center()
                .w_full()
                .gap_2()
                .child(
                    div().w(px(3.)).h(px(18.)).rounded_full().bg(self
                        .color(0x98b1d4)
                        .opacity(if selected { 1.0 } else { 0.0 })),
                )
                .child(icon_tile(
                    section,
                    22.,
                    if selected {
                        self.color(0x98b1d4).opacity(0.16)
                    } else {
                        self.color(0x202a3b)
                    },
                    if selected {
                        self.color(0x98b1d4)
                    } else {
                        self.color(0xe4e9f2).opacity(0.78)
                    },
                ))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_color(self.color(0xe4e9f2).opacity(if enabled { 1. } else { 0.5 }))
                        .when(selected, |label| label.font_weight(FontWeight::SEMIBOLD))
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
        let groups: &[(&str, &[Section])] = &[
            (
                "Workspace",
                &[
                    Section::General,
                    Section::Models,
                    Section::Usage,
                    Section::Instructions,
                ],
            ),
            (
                "Tools",
                &[
                    Section::Keyboard,
                    Section::Voice,
                    Section::Browser,
                    Section::ComputerUse,
                    Section::Appshots,
                ],
            ),
            ("Saved data", &[Section::Archive, Section::Media]),
        ];
        for (title, sections) in groups {
            navigation = navigation.child(
                div()
                    .mt_2()
                    .px_2()
                    .text_xs()
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(self.color(0xe4e9f2).opacity(0.56))
                    .child(*title),
            );
            for section in *sections {
                navigation =
                    navigation.child(self.settings_navigation_row(*section, section.label(), cx));
            }
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
            let selected = self
                .selected
                .as_ref()
                .and_then(|thread| thread["selection"]["provider"].as_str());
            if !provider_is_shown(
                &self.settings,
                &self.settings_navigation.agent_view,
                provider.id,
                selected,
            ) && self.settings_section != Section::Provider(provider.id)
            {
                continue;
            }
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
        let selected = self
            .selected
            .as_ref()
            .and_then(|thread| thread["selection"]["provider"].as_str());
        for descriptor in coincide_core::provider_catalog::PROVIDERS
            .iter()
            .filter(|descriptor| {
                provider_is_shown(
                    &self.settings,
                    &self.settings_navigation.agent_view,
                    descriptor.id,
                    selected,
                )
            })
        {
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
                    .flex_shrink_0()
                    .items_center()
                    .gap_3()
                    .p_4()
                    .rounded(px(10.))
                    .border_1()
                    .border_color(self.color(0x29303d))
                    .bg(self.color(0x111722))
                    .child(icon_tile(
                        section,
                        30.,
                        self.color(0x202a3b),
                        self.color(0xe4e9f2),
                    ))
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
                        .color(self.color(0x98b1d4))
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
        let registry = &self.settings_navigation.agent_view;
        for agent in registry_agent_rows(registry, false, "") {
            let id = text(&agent, "id");
            let name = text(&agent, "name");
            let registered = agent["registered"] == true;
            let action_label = if registered {
                format!("{name} added")
            } else {
                format!("Add {name}")
            };
            let detail = if registered {
                "Added"
            } else {
                "Installed · add to use"
            };
            pane = pane.child(
                self.settings_card(
                    div()
                        .flex()
                        .items_center()
                        .gap_3()
                        .p_4()
                        .child(
                            chat_layout::provider_mark(&format!("acp-{id}"), 24.)
                                .map(|mark| mark.into_any_element())
                                .unwrap_or_else(|| {
                                    Icon::new(gpui_kit::assets::IconName::Cpu)
                                        .small()
                                        .into_any_element()
                                }),
                        )
                        .child(
                            div().flex_1().child(name).child(
                                div()
                                    .text_xs()
                                    .text_color(self.color(0xe4e9f2).opacity(0.65))
                                    .child(detail),
                            ),
                        )
                        .child(
                            Button::new(SharedString::from(format!("provider-add-{id}")))
                                .label(if registered { "Added" } else { "Add" })
                                .accessibility_label(action_label)
                                .disabled(registered || self.settings_navigation.agent_add_pending)
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.add_registry_agent_in_settings(id.clone(), cx)
                                })),
                        ),
                )
                .flex_shrink_0(),
            );
        }
        if registry.is_null() || (registry["loading"] == true && registry["agents"].is_null()) {
            pane = pane.child(
                div()
                    .text_sm()
                    .text_color(self.color(0xe4e9f2).opacity(0.65))
                    .child("Detecting installed agents…"),
            );
        }
        pane = pane.child(
            div()
                .flex()
                .flex_shrink_0()
                .items_center()
                .gap_2()
                .mt_2()
                .child(
                    Button::new("providers-browse-more")
                        .label(if self.settings_navigation.show_more_agents {
                            "Hide extra agents"
                        } else {
                            "Browse more agents"
                        })
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.settings_navigation.show_more_agents =
                                !this.settings_navigation.show_more_agents;
                            this.refresh_agent_discovery(cx);
                            cx.notify();
                        })),
                )
                .child(
                    Button::new("providers-rescan-installed")
                        .label("Detect again")
                        .ghost()
                        .on_click(cx.listener(|this, _, _, cx| this.refresh_agent_discovery(cx))),
                ),
        );
        if self.settings_navigation.show_more_agents {
            pane = pane.child(div().mt_2().text_sm().text_color(self.color(0xe4e9f2).opacity(0.65))
                .child("Set up another agent or model service. Newly installed agents appear above after detection."));
            for descriptor in
                coincide_core::provider_catalog::PROVIDERS
                    .iter()
                    .filter(|descriptor| {
                        !provider_is_shown(&self.settings, registry, descriptor.id, selected)
                    })
            {
                let provider = descriptor.id;
                let label = descriptor.display_name;
                pane =
                    pane.child(
                        self.settings_card(
                            div()
                                .flex()
                                .items_center()
                                .gap_3()
                                .p_4()
                                .child(icon_tile(
                                    Section::Provider(provider),
                                    26.,
                                    self.color(0x202a3b),
                                    self.color(0xe4e9f2),
                                ))
                                .child(
                                    div().flex_1().child(label).child(
                                        div()
                                            .text_xs()
                                            .text_color(self.color(0xe4e9f2).opacity(0.65))
                                            .child(if provider == ProviderId::Lithos {
                                                "Model service · separate setup"
                                            } else {
                                                "Not detected · setup available"
                                            }),
                                    ),
                                )
                                .child(
                                    Button::new(SharedString::from(format!(
                                        "provider-setup-extra-{}",
                                        provider_key(provider)
                                    )))
                                    .label("Set up")
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        let enabled = provider_enabled(&this.settings, provider);
                                        this.apply_settings_provider_enabled(
                                            provider, enabled, true, window, cx,
                                        );
                                        this.navigate_settings_section(
                                            Section::Provider(provider),
                                            window,
                                            cx,
                                        );
                                    })),
                                ),
                        )
                        .flex_shrink_0(),
                    );
            }
            pane = pane.child(
                Button::new("providers-custom-agent")
                    .flex_shrink_0()
                    .label(if self.settings_navigation.show_custom_agent {
                        "Close custom agent"
                    } else {
                        "Add custom ACP agent…"
                    })
                    .ghost()
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.settings_navigation.show_custom_agent =
                            !this.settings_navigation.show_custom_agent;
                        cx.notify();
                    })),
            );
            if self.settings_navigation.show_custom_agent {
                pane = pane.child(self.settings_card(
                    div().p_4().flex().flex_col().gap_2()
                        .child(div().font_weight(FontWeight::SEMIBOLD).child("Add an installed ACP agent"))
                        .child(div().text_xs().text_color(self.color(0xe4e9f2).opacity(0.65))
                            .child("Enter its name, executable or command, and any ACP arguments."))
                        .child(Input::new(&self.custom_acp_name))
                        .child(Input::new(&self.custom_acp_executable))
                        .child(Input::new(&self.custom_acp_arguments))
                        .child(Button::new("providers-custom-agent-add").label("Add agent")
                            .disabled(self.settings_navigation.agent_add_pending)
                            .on_click(cx.listener(|this, _, _, cx| this.add_custom_agent_in_settings(cx))))
                ).flex_shrink_0());
            }
            for agent in registry_agent_rows(registry, true, "")
                .into_iter()
                .filter(|agent| agent["executable"].is_null() && agent["registered"] != true)
            {
                let id = text(&agent, "id");
                let name = text(&agent, "name");
                let website = agent["website"].as_str().map(str::to_owned);
                let link = website.clone();
                let fallback_name = name.clone();
                let action_label = if link.is_some() {
                    format!("Install {name}")
                } else {
                    format!("Add {name} manually")
                };
                pane = pane.child(
                    self.settings_card(
                        div()
                            .flex()
                            .items_center()
                            .gap_3()
                            .p_4()
                            .child(
                                chat_layout::provider_mark(&format!("acp-{id}"), 24.)
                                    .map(|mark| mark.into_any_element())
                                    .unwrap_or_else(|| {
                                        Icon::new(gpui_kit::assets::IconName::Cpu)
                                            .small()
                                            .into_any_element()
                                    }),
                            )
                            .child(
                                div().flex_1().child(name).child(
                                    div()
                                        .text_xs()
                                        .text_color(self.color(0xe4e9f2).opacity(0.65))
                                        .child(if website.is_some() {
                                            "Not detected · open the agent website to install"
                                        } else {
                                            "Not detected · add an installed executable"
                                        }),
                                ),
                            )
                            .child(
                                Button::new(SharedString::from(format!("provider-install-{id}")))
                                    .label(if link.is_some() {
                                        "Install…"
                                    } else {
                                        "Add manually…"
                                    })
                                    .accessibility_label(action_label)
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        if let Some(url) = &link {
                                            cx.open_url(url);
                                        } else {
                                            this.custom_acp_name.update(cx, |input, cx| {
                                                input.set_value(fallback_name.clone(), window, cx)
                                            });
                                            this.settings_navigation.show_custom_agent = true;
                                            cx.notify();
                                        }
                                    })),
                            ),
                    )
                    .flex_shrink_0(),
                );
            }
        }
        let content = pane
            .child(
                div()
                    .flex()
                    .flex_shrink_0()
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
            .px_5()
            .py_4()
            .border_b_1()
            .border_color(self.color(0x29303d))
            .child(icon_tile(
                section,
                30.,
                self.color(0x202a3b),
                self.color(0xe4e9f2),
            ))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_xl()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(section.label()),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(self.color(0xe4e9f2).opacity(0.62))
                            .child(if provider == ProviderId::Lithos {
                                "Model service"
                            } else {
                                "Coding agent"
                            }),
                    ),
            )
            .child(
                Button::new("provider-preferences-done")
                    .label("Done")
                    .on_click(
                        cx.listener(|this, _, window, cx| this.close_settings_panel(window, cx)),
                    ),
            );
        let mut pane = div()
            .w_full()
            .max_w(px(900.))
            .min_w_0()
            .flex()
            .flex_col()
            .gap_5()
            .child(
                div()
                    .rounded(px(10.))
                    .bg(self.color(0x111722))
                    .child(status),
            )
            .child(
                self.settings_card(
                    self.labeled_row(
                        format!("Use {}", section.label()),
                        Some(
                            if provider == ProviderId::Lithos {
                                "Use Lithos models through OpenCode; no OpenCode account is needed."
                            } else if provider == ProviderId::Antigravity {
                                "Uses a saved Gemini API-key account."
                            } else {
                                "Use this agent and its existing sign-in in Coincide."
                            }
                            .into(),
                        ),
                        gpui_kit::component::switch::Switch::new("provider-preferences-enabled")
                            .accessibility_label(format!("Use {}", section.label()))
                            .checked(enabled)
                            .color(self.color(0x98b1d4))
                            .on_click(cx.listener(move |this, value: &bool, window, cx| {
                                this.set_settings_provider_enabled(
                                    provider, enabled, *value, window, cx,
                                )
                            })),
                    ),
                ),
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
            _ => {}
        }
        let mut catalogs = self.provider_configuration_panel.read(cx).catalogs();
        catalogs.push(self.selection_ui.catalog.clone());
        let content = self.settings_scroll.frame(
            provider_key(provider),
            div()
                .id("provider-preferences")
                .flex_1()
                .min_w_0()
                .min_h_0()
                .overflow_y_scroll()
                .px_5()
                .py_5()
                .child(
                    div().flex().justify_center().w_full().child(
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
                    ),
                ),
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
    use super::{State, enabled_patch, provider_enabled, provider_is_shown, registry_agent_rows};
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
            json!({"antigravity":{"isEnabled":false,"opaque":42,"environment":{"SYNTHETIC_TEST_MODE":"fixture"}}}),
            json!(["antigravity",{"isEnabled":false,"opaque":42,"environment":{"SYNTHETIC_TEST_MODE":"fixture"}}]),
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
            assert!(enabled_patch(&initial, P::Antigravity, false, true).is_ok());
        }
    }
    #[::core::prelude::v1::test]
    fn antigravity_can_be_enabled_for_api_key_setup_without_oauth_prompt() {
        assert!(provider_enabled(&json!({}), P::Antigravity));
        assert!(enabled_patch(&json!({}), P::Antigravity, true, false).is_ok());
    }

    #[::core::prelude::v1::test]
    fn installed_agents_are_shown_without_conflating_lithos_with_opencode() {
        let view = json!({"discovery":{"providers":[
            {"provider":"claude","state":"found"},
            {"provider":"opencode","state":"found"},
            {"provider":"lithos","state":"found"},
            {"provider":"codex","state":"not_found"}
        ]},"configured":["cursor"]});
        assert!(provider_is_shown(&json!({}), &view, P::Claude, None));
        assert!(provider_is_shown(&json!({}), &view, P::Opencode, None));
        assert!(provider_is_shown(&json!({}), &view, P::Cursor, None));
        assert!(!provider_is_shown(&json!({}), &view, P::Lithos, None));
        assert!(!provider_is_shown(&json!({}), &view, P::Codex, None));
        assert!(provider_is_shown(
            &json!({}),
            &view,
            P::Codex,
            Some("codex")
        ));
        assert!(provider_is_shown(
            &json!({"providers":{"lithos":{"isEnabled":true}}}),
            &view,
            P::Lithos,
            None
        ));
        // A disabled but installed agent remains in Settings so it can be enabled.
        assert!(provider_is_shown(
            &json!({"providers":{"claude":{"isEnabled":false}}}),
            &view,
            P::Claude,
            None
        ));
    }

    #[::core::prelude::v1::test]
    fn installed_and_registered_agents_precede_the_browsable_extra_catalog() {
        let view = json!({"agents":[{"id":"copilot","name":"Copilot","executable":"/bin/copilot"},
            {"id":"qwen","name":"Qwen","executable":null}],
            "registered":[{"provider":"acp-custom","displayName":"Custom"}]});
        let installed = registry_agent_rows(&view, false, "");
        assert_eq!(installed.len(), 2);
        assert!(
            installed
                .iter()
                .any(|row| row["id"] == "custom" && row["registered"] == true)
        );
        assert!(installed.iter().any(|row| row["id"] == "copilot"));
        let all = registry_agent_rows(&view, true, "");
        assert_eq!(all.len(), 3);
        assert_eq!(all[2]["id"], "qwen");
        assert_eq!(registry_agent_rows(&view, true, "qwe")[0]["id"], "qwen");
    }
}
