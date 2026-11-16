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

/// A native click is retained until the engine can persist it. While a change
/// is unsettled, agent requests fail closed; native browser controls continue
/// to work. A non-contention error remains queued but is not retried silently.
#[derive(Default)]
pub(super) struct PendingControls {
    choices: std::collections::BTreeMap<String, bool>,
    failed: std::collections::BTreeSet<String>,
}

enum PersistControl {
    Waiting,
    Saved(Value),
    Failed(anyhow::Error),
}

impl PendingControls {
    fn choice(&self, thread: &str) -> Option<bool> {
        self.choices
            .iter()
            .find_map(|(id, choice)| id.eq_ignore_ascii_case(thread).then_some(*choice))
    }

    fn displayed(&self, settings: &Value, thread: &str) -> bool {
        if self.failed.iter().any(|id| id.eq_ignore_ascii_case(thread)) {
            return false;
        }
        self.choice(thread)
            .unwrap_or_else(|| agent_request_allowed(settings, thread, false))
    }

    pub(super) fn request_allowed(&self, settings: &Value, thread: &str, native: bool) -> bool {
        native || (self.choice(thread).is_none() && agent_request_allowed(settings, thread, false))
    }

    fn queue(&mut self, thread: &str, enabled: bool) {
        self.choices
            .retain(|id, _| !id.eq_ignore_ascii_case(thread));
        self.failed.retain(|id| !id.eq_ignore_ascii_case(thread));
        self.choices.insert(thread.to_owned(), enabled);
    }

    fn persist_one(
        &mut self,
        shared: &SharedEngine,
        native: &std::collections::HashSet<String>,
    ) -> PersistControl {
        let Some((thread, enabled)) = self
            .choices
            .iter()
            .find(|(id, _)| !self.failed.contains(*id))
            .map(|(id, enabled)| (id.clone(), *enabled))
        else {
            return PersistControl::Waiting;
        };
        let result = try_state(shared)
            .and_then(|mut engine| engine.set_browser_agent_control(&thread, enabled, native));
        match result {
            Ok(settings) => {
                self.choices.remove(&thread);
                PersistControl::Saved(settings)
            }
            Err(error) if engine_busy(&error) => PersistControl::Waiting,
            Err(error) => {
                self.failed.insert(thread);
                PersistControl::Failed(error)
            }
        }
    }
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
        let enabled = !self
            .pending_browser_control
            .displayed(&self.browser_control, thread);
        self.pending_browser_control.queue(thread, enabled);
        if !enabled {
            if let Some(browser) = &mut self.browser {
                browser.revoke_agent_control(thread);
            }
            self.credential_panel
                .update(cx, |panel, cx| panel.cancel(cx));
        }
        self.poll_pending_browser_control(cx);
        cx.notify();
    }

    pub(super) fn poll_pending_browser_control(&mut self, cx: &mut Context<Self>) {
        let native = self.browser_ui_operations.keys().cloned().collect();
        match self
            .pending_browser_control
            .persist_one(&self.engine, &native)
        {
            PersistControl::Waiting => return,
            PersistControl::Saved(settings) => self.browser_control = settings,
            PersistControl::Failed(error) => {
                self.status = format!("Agent Control could not be saved: {error}");
            }
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
    pub(super) fn browser_agent_control_button(
        &self,
        thread: &str,
        cx: &mut Context<Self>,
    ) -> Button {
        let enabled = self
            .pending_browser_control
            .displayed(&self.browser_control, thread);
        let thread = thread.to_owned();
        Button::new("browser-agent-control")
            .icon(gpui_kit::assets::IconName::Hand)
            .accessibility_label(if enabled {
                "Agent Control: On"
            } else {
                "Agent Control: Off"
            })
            .tooltip(if enabled {
                "Turn off Agent Control"
            } else {
                "Turn on Agent Control"
            })
            .selected(enabled)
            .ghost()
            .compact()
            .small()
            .w(px(28.))
            .h(px(28.))
            .on_click(cx.listener(move |this, _, _, cx| this.toggle_browser_control(&thread, cx)))
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
        let library_thread = thread.to_owned();
        let bookmark_thread = thread.to_owned();
        let bookmark_tab = active.map(|tab| text(tab, "id"));
        div()
            .flex()
            .items_center()
            .gap_1()
            .child(
                Button::new("browser-bookmark-toggle")
                    .icon(if marked {
                        gpui_kit::assets::IconName::StarFill
                    } else {
                        gpui_kit::assets::IconName::Star
                    })
                    .accessibility_label(if marked {
                        "Remove bookmark"
                    } else {
                        "Bookmark this page"
                    })
                    .tooltip(if marked {
                        "Remove bookmark"
                    } else {
                        "Bookmark this page"
                    })
                    .ghost()
                    .compact()
                    .small()
                    .w(px(28.))
                    .h(px(28.))
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
                    .icon(gpui_kit::assets::IconName::BookOpen)
                    .accessibility_label("Bookmarks and History")
                    .tooltip("Bookmarks and History")
                    .ghost()
                    .compact()
                    .small()
                    .w(px(28.))
                    .h(px(28.))
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
                    .icon(gpui_kit::assets::IconName::Lock)
                    .accessibility_label("Fill Saved Login")
                    .tooltip("Fill Saved Login")
                    .ghost()
                    .compact()
                    .small()
                    .w(px(28.))
                    .h(px(28.))
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
    use std::sync::{Arc, Mutex};

    #[::core::prelude::v1::test]
    fn busy_control_click_is_kept_and_fails_closed_until_saved() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::new(Store::open(&dir.path().join("state.sqlite")).unwrap());
        let response = engine.dispatch(json!({"method":"threads.create","params":{}}));
        assert!(response.get("error").is_none(), "{response}");
        let thread = response["result"]["id"].as_str().unwrap().to_owned();
        let shared = Arc::new(Mutex::new(engine));
        let initial = shared.lock().unwrap().browser_agent_control_settings();
        let mut pending = PendingControls::default();
        pending.queue(&thread, false);
        let locked = shared.lock().unwrap();
        assert!(matches!(
            pending.persist_one(&shared, &Default::default()),
            PersistControl::Waiting
        ));
        assert!(!pending.displayed(&initial, &thread));
        assert!(!pending.request_allowed(&initial, &thread, false));
        assert!(pending.request_allowed(&initial, &thread, true));
        drop(locked);
        let PersistControl::Saved(saved) = pending.persist_one(&shared, &Default::default()) else {
            panic!("the queued click was not persisted")
        };
        assert_eq!(saved["agentControl"][&thread], false);
        assert!(!pending.request_allowed(&saved, &thread, false));

        pending.queue(&thread, true);
        assert!(!pending.request_allowed(&saved, &thread, false));
        let PersistControl::Saved(saved) = pending.persist_one(&shared, &Default::default()) else {
            panic!("the queued re-enable was not persisted")
        };
        assert!(pending.request_allowed(&saved, &thread, false));
    }

    #[::core::prelude::v1::test]
    fn newest_control_choice_is_thread_scoped_and_case_insensitive() {
        let mut pending = PendingControls::default();
        let settings = json!({"agentControl":{"other":true}});
        pending.queue("ABC", false);
        pending.queue("abc", true);
        assert_eq!(pending.choice("ABC"), Some(true));
        assert!(!pending.request_allowed(&settings, "aBc", false));
        assert!(pending.request_allowed(&settings, "other", false));
        assert!(pending.request_allowed(&settings, "abc", true));
    }

    #[::core::prelude::v1::test]
    fn failed_control_change_does_not_authorize_agent_requests() {
        let dir = tempfile::tempdir().unwrap();
        let engine = Engine::new(Store::open(&dir.path().join("state.sqlite")).unwrap());
        let shared = Arc::new(Mutex::new(engine));
        let mut pending = PendingControls::default();
        pending.queue("missing", true);
        assert!(matches!(
            pending.persist_one(&shared, &Default::default()),
            PersistControl::Failed(_)
        ));
        assert!(!pending.displayed(&json!({}), "missing"));
        assert!(!pending.request_allowed(&json!({}), "missing", false));
        assert!(pending.request_allowed(&json!({}), "missing", true));
        assert!(matches!(
            pending.persist_one(&shared, &Default::default()),
            PersistControl::Waiting
        ));
    }
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
