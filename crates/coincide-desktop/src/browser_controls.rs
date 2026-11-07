//! Native pane controls. Agent-control provenance never grants credential approval.
use super::*;
use gpui_kit::component::Disableable;

pub(super) fn agent_request_allowed(settings: &Value, thread: &str, native: bool) -> bool {
    if native {
        return true;
    }
    let overrides = match settings.get("agentControl") {
        None => None,
        Some(value) => match value.as_object() {
            Some(overrides) => Some(overrides),
            None => return false,
        },
    };
    // Swift UUID.uuidString uses uppercase; imported thread IDs may be canonical lowercase.
    let matching = overrides
        .into_iter()
        .flat_map(|choices| choices.iter())
        .filter(|(id, _)| id.eq_ignore_ascii_case(thread))
        .map(|(_, value)| value);
    let choices = matching.collect::<Vec<_>>();
    if !choices.is_empty() {
        return choices.iter().all(|value| value.as_bool() == Some(true));
    }
    settings
        .get("agentControlByDefault")
        .map_or(true, |value| value.as_bool().unwrap_or(false))
}

impl Coincide {
    pub(super) fn browser_pane_controls_visible(&self) -> bool {
        !self.settings_open
            && self.chat_visible()
            && !self.historical_image_is_open()
            && self.chat_inspector_panel() == Some(chat_inspector::Panel::Browser)
            && self.selected.as_ref().is_some_and(|thread| {
                self.browser
                    .as_ref()
                    .is_some_and(|browser| browser.is_visible(&text(thread, "id")))
            })
    }
    pub(super) fn browser_library_visible(&self) -> bool {
        self.browser_pane_controls_visible()
            && self.selected.as_ref().is_some_and(|thread| {
                self.browser_library_thread.as_deref() == thread["id"].as_str()
            })
    }
    fn toggle_browser_control(&mut self, thread: &str, cx: &mut Context<Self>) {
        if self
            .selected
            .as_ref()
            .and_then(|value| value["id"].as_str())
            != Some(thread)
        {
            return;
        }
        let enabled = !agent_request_allowed(&self.browser_control, thread, false);
        let native = self.browser_ui_operations.keys().cloned().collect();
        let result = self
            .engine
            .try_lock()
            .map_err(|_| anyhow::anyhow!("The app is busy"))
            .and_then(|mut engine| engine.set_browser_agent_control(thread, enabled, &native));
        match result {
            Ok(settings) => {
                self.browser_control = settings;
                if !enabled {
                    if let Some(browser) = &mut self.browser {
                        browser.revoke_agent_control(thread);
                    }
                    self.credential_panel
                        .update(cx, |panel, cx| panel.cancel(cx));
                }
            }
            Err(error) => self.status = format!("Agent Control was not changed: {error}"),
        }
        cx.notify();
    }
    fn open_pane_logins(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.dismiss_palette(window, cx);
        self.settings_open = true;
        self.navigate_settings_section(settings::SettingsSection::Browser, window, cx);
        self.browser_settings_open = false;
        self.credentials_open = true;
        self.sync_credentials(cx);
        self.show_settings_window(cx);
        cx.notify();
    }
    pub(super) fn browser_pane_controls(
        &mut self,
        thread: &str,
        active: Option<&Value>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let url = active.map(|tab| text(tab, "url")).unwrap_or_default();
        let mut title = active
            .map(|tab| text(tab, "title"))
            .unwrap_or_else(|| url.clone());
        if title.trim().is_empty() {
            title = url.clone();
        }
        title = title.chars().take(500).collect();
        let persistent = self.browser.as_ref().is_some_and(|browser| {
            browser.profile_snapshot(thread).selected != browser_settings::ProfileChoice::Private
        });
        let valid_page = persistent && coincide_core::browser_bookmarks::validate_url(&url).is_ok();
        let bookmark_busy = self.browser_settings_panel.read(cx).bookmark_busy();
        let marked = self
            .browser_settings_panel
            .read(cx)
            .page_is_bookmarked(&url);
        let enabled = agent_request_allowed(&self.browser_control, thread, false);
        let control_thread = thread.to_owned();
        let library_thread = thread.to_owned();
        let bookmark_thread = thread.to_owned();
        let bookmark_tab = active.map(|tab| text(tab, "id"));
        div()
            .flex()
            .flex_wrap()
            .gap_1()
            .px_2()
            .pb_2()
            .child(
                Button::new("browser-agent-control")
                    .label(if enabled {
                        "Agent Control: On"
                    } else {
                        "Agent Control: Off"
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.toggle_browser_control(&control_thread, cx)
                    })),
            )
            .child(
                Button::new("browser-bookmark-toggle")
                    .label(if marked {
                        "Remove bookmark"
                    } else {
                        "Bookmark page"
                    })
                    .disabled(!valid_page || bookmark_busy)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        // Bind the existing settings worker owner to this exact native destination.
                        if this
                            .selected
                            .as_ref()
                            .and_then(|thread| thread["id"].as_str())
                            != Some(bookmark_thread.as_str())
                        {
                            return;
                        }
                        let Some(browser) = this.browser.as_ref() else {
                            return;
                        };
                        let tabs = browser.tab_list(&bookmark_thread);
                        let current = tabs["tabs"]
                            .as_array()
                            .and_then(|tabs| tabs.iter().find(|tab| tab["active"] == true));
                        if !current.is_some_and(|tab| {
                            Some(text(tab, "id")) == bookmark_tab && text(tab, "url") == url
                        }) {
                            return;
                        }
                        this.sync_browser_settings(window, cx);
                        this.browser_settings_panel.update(cx, |panel, cx| {
                            panel.toggle_page_bookmark(url.clone(), title.clone(), cx)
                        });
                    })),
            )
            .child(
                Button::new("browser-bookmark-library")
                    .label("Bookmark library")
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if this.browser_library_visible() {
                            this.browser_library_thread = None;
                        } else {
                            this.browser_library_thread = Some(library_thread.clone());
                            this.sync_browser_settings(window, cx);
                            this.browser_settings_panel
                                .update(cx, |panel, cx| panel.open_pane_library(cx));
                        }
                        this.sync_browser_settings_route(cx);
                        cx.notify();
                    })),
            )
            .child(
                Button::new("browser-fill-saved-login")
                    .label("Fill Saved Login")
                    .disabled(!self.browser.as_ref().is_some_and(|browser| {
                        browser.credential_fill_available()
                            && browser.credential_page(thread, cx).is_some()
                    }))
                    .on_click(cx.listener(|this, _, window, cx| this.open_pane_logins(window, cx))),
            )
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn malformed_saved_choices_fail_closed_without_affecting_native_browsing() {
        for settings in [
            json!({"agentControl":false}),
            json!({"agentControl":{"one":"yes"}}),
            json!({"agentControlByDefault":"yes"}),
        ] {
            assert!(!agent_request_allowed(&settings, "one", false));
            assert!(agent_request_allowed(&settings, "one", true));
        }
    }
    #[::core::prelude::v1::test]
    fn per_thread_control_preserves_default_and_native_provenance() {
        let settings = json!({"agentControl":{"one":false,"two":true}});
        assert!(!agent_request_allowed(&settings, "one", false));
        assert!(agent_request_allowed(&settings, "two", false));
        assert!(!agent_request_allowed(
            &json!({"agentControl":{"ABC":false}}),
            "abc",
            false
        ));
        assert!(agent_request_allowed(&settings, "new", false));
        assert!(agent_request_allowed(&settings, "one", true));
        let settings = json!({"agentControlByDefault":false,"agentControl":{"two":true}});
        assert!(!agent_request_allowed(&settings, "new", false));
        assert!(agent_request_allowed(&settings, "two", false));
    }
}
