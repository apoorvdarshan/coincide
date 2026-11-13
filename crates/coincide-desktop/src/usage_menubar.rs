//! macOS status item, retained independently of the main window.
//! The UI receives presentation-only data; provider reads stay owned by Core.
use crate::{
    Coincide, MainWindow, call, codex_limits_mount, codex_limits_view::Phase, engine_busy,
    reopen_main_window, settings, usage_dashboard::LimitState, usage_dashboard_ui,
    usage_history_mount, usage_menubar_model as model, worker_owner,
};
use coincide_core::api::SharedEngine;
use gpui_kit::{App, Global};
use serde_json::{Value, json};
use std::{
    cell::RefCell,
    collections::{HashMap, VecDeque},
    rc::Rc,
    time::{Duration, Instant},
};

struct GlobalBar(Rc<RefCell<Bar>>);
impl Global for GlobalBar {}

struct Bar {
    engine: SharedEngine,
    history: usage_history_mount::Mount,
    codex: codex_limits_mount::Mount,
    settings: Value,
    selected: Option<Value>,
    running: bool,
    was_running: bool,
    last_refresh: Option<Instant>,
    retry_codex: bool,
    retry_claude: bool,
    last_retry: Option<Instant>,
    last_settings: Option<Instant>,
    last_snapshot: Option<Value>,
    last_draw: Option<Instant>,
    cached: HashMap<(String, String), coincide_core::usage_limits::Limits>,
    account_revision: Option<u64>,
    pending_settings: VecDeque<(String, Value)>,
    closed: bool,
}

fn codex_target(thread: Option<&Value>) -> Option<Value> {
    thread
        .filter(|thread| {
            thread["selection"]["provider"] == "codex"
                && thread["selection"]["accountID"]
                    .as_str()
                    .is_some_and(|id| id != "default")
        })
        .cloned()
}

fn allowed_setting(snapshot: Option<&Value>, key: &str, value: &Value) -> bool {
    let offered = |list: &str| {
        snapshot.is_some_and(|snapshot| {
            snapshot[list]
                .as_array()
                .is_some_and(|options| options.iter().any(|option| option["value"] == *value))
        })
    };
    match key {
        "usageDisplayMode" => matches!(value.as_str(), Some("used" | "remaining")),
        "usageRefresh" => matches!(
            value.as_str(),
            Some(
                "automatic"
                    | "everyMinute"
                    | "every5Minutes"
                    | "every15Minutes"
                    | "every30Minutes"
                    | "everyHour"
                    | "manual"
            )
        ),
        "menuBarUsage" => model::Choice::decode(value).is_some() && offered("primaryOptions"),
        "menuBarSecondaryUsage" => {
            value.is_null()
                || (model::Choice::decode(value).is_some() && offered("secondaryOptions"))
        }
        _ => false,
    }
}
impl Bar {
    fn new(engine: SharedEngine, cx: &mut App) -> Self {
        let settings = call(&engine, "settings.read", json!({})).unwrap_or_else(|_| json!({}));
        Self {
            history: usage_history_mount::Mount::new(engine.clone(), cx),
            codex: codex_limits_mount::Mount::new(engine.clone(), cx),
            engine,
            settings,
            selected: None,
            running: false,
            was_running: false,
            last_refresh: None,
            retry_codex: false,
            retry_claude: false,
            last_retry: None,
            last_settings: None,
            last_snapshot: None,
            last_draw: None,
            cached: HashMap::new(),
            account_revision: None,
            pending_settings: VecDeque::new(),
            closed: false,
        }
    }
    fn visible(&self) -> bool {
        self.settings["showsUsageInMenuBar"]
            .as_bool()
            .unwrap_or(true)
    }
    fn receive_settings(&mut self, settings: Value, now: Instant) {
        if self.settings != settings {
            let was_visible = self.visible();
            if self.settings["providers"] != settings["providers"] {
                self.cached.clear();
                self.last_refresh = None;
            }
            self.settings = settings;
            if !was_visible && self.visible() {
                self.last_refresh = None;
            }
            self.last_draw = None;
        }
        self.last_settings = Some(now);
    }
    fn refresh(&mut self, cx: &mut App, now: Instant) {
        if self.closed || !self.visible() {
            return;
        }
        self.last_refresh = Some(now);
        self.history.load_dashboard();
        if usage_dashboard_ui::provider_id("codex")
            .is_some_and(|id| crate::settings_navigation::provider_enabled(&self.settings, id))
            && !matches!(self.codex.panel.read(cx).phase(), Phase::Loading)
        {
            self.codex.set_context(self.selected.as_ref(), cx);
            self.retry_codex = !self.codex.try_refresh(cx);
        }
        if usage_dashboard_ui::provider_id("claude")
            .is_some_and(|id| crate::settings_navigation::provider_enabled(&self.settings, id))
            && self.history.dashboard.claude.state != Some(LimitState::Reading)
        {
            self.retry_claude = !self.history.dashboard.claude.try_refresh(&self.engine);
        }
    }
    fn tick(
        &mut self,
        cx: &mut App,
        selected: Option<Value>,
        running: bool,
        settings: Option<Value>,
        account_revision: Option<u64>,
    ) -> bool {
        if self.closed {
            return false;
        }
        let now = Instant::now();
        if let Some(settings) = settings {
            self.receive_settings(settings, now);
        } else if self
            .last_settings
            .is_none_or(|at| now.duration_since(at) >= Duration::from_secs(5))
        {
            if let Ok(value) = call(&self.engine, "settings.read", json!({})) {
                self.receive_settings(value, now);
            }
        }
        if let Some(revision) = account_revision {
            if self.account_revision.is_some_and(|old| old != revision) {
                self.cached.clear();
                self.last_refresh = None;
            }
            self.account_revision = Some(revision);
        }
        // Keep the last target while the main window is closed. A switch of a
        // named account invalidates its old view before the next read.
        let target_changed = selected.is_some()
            && codex_target(self.selected.as_ref()) != codex_target(selected.as_ref());
        if running != self.running
            || selected
                .as_ref()
                .is_some_and(|next| self.selected.as_ref() != Some(next))
        {
            self.last_draw = None;
        }
        if let Some(selected) = selected {
            self.selected = Some(selected);
        }
        self.running = running;
        native::visible(self.visible());
        if !self.visible() {
            return false;
        }
        if self.was_running && !running {
            self.history.load_dashboard();
        }
        self.was_running = running;
        if target_changed {
            self.codex.set_context(self.selected.as_ref(), cx);
            self.retry_codex = false;
            self.last_refresh = None;
        }
        let due = self.last_refresh.is_none_or(|at| {
            model::interval(&self.settings["usageRefresh"], running)
                .is_some_and(|interval| now.duration_since(at) >= interval)
        });
        if due {
            self.refresh(cx, now);
        }
        let history_changed = self.history.poll(cx);
        let history_busy = self.history.dashboard.data.is_none()
            && self.history.dashboard.error.as_deref() == Some(crate::usage_dashboard::USAGE_BUSY);
        if (self.retry_codex || self.retry_claude || history_busy)
            && self
                .last_retry
                .is_none_or(|at| now.duration_since(at) >= Duration::from_secs(2))
        {
            self.last_retry = Some(now);
            if history_busy && !self.history.dashboard.loading {
                self.history.load_dashboard();
            }
            if self.retry_codex {
                self.retry_codex = usage_dashboard_ui::provider_id("codex").is_some_and(|id| {
                    crate::settings_navigation::provider_enabled(&self.settings, id)
                }) && !self.codex.try_refresh(cx);
            }
            if self.retry_claude {
                self.retry_claude = usage_dashboard_ui::provider_id("claude").is_some_and(|id| {
                    crate::settings_navigation::provider_enabled(&self.settings, id)
                }) && !self.history.dashboard.claude.try_refresh(&self.engine);
            }
        }
        let prior = self.codex.panel.read(cx).phase().clone();
        self.codex.poll(cx);
        let changed = history_changed || prior != *self.codex.panel.read(cx).phase();
        let mut cards = usage_dashboard_ui::cards_for(
            &self.settings,
            &self.history.dashboard,
            self.codex.panel.read(cx).account(),
            crate::usage_dashboard::codex_state(self.codex.panel.read(cx).phase()),
        );
        for card in &mut cards {
            let key = (card.account.provider.to_owned(), card.account.id.clone());
            if let LimitState::Ready(limits) = &card.state {
                self.cached.insert(key, limits.clone());
            } else if let Some(previous) = self.cached.get(&key) {
                card.state = LimitState::Ready(previous.clone());
            }
        }
        if changed
            || self
                .last_draw
                .is_none_or(|at| now.duration_since(at) >= Duration::from_secs(15))
            || self.last_snapshot.is_none()
        {
            let active = self
                .selected
                .as_ref()
                .filter(|_| running)
                .and_then(|thread| {
                    Some((
                        thread["selection"]["provider"].as_str()?,
                        thread["selection"]["accountID"]
                            .as_str()
                            .unwrap_or("default"),
                    ))
                });
            let snapshot = model::snapshot(
                &cards,
                self.history.dashboard.data.as_ref(),
                &self.settings,
                active,
                chrono::Utc::now(),
            );
            if self.last_snapshot.as_ref() != Some(&snapshot) {
                native::update(&snapshot);
                self.last_snapshot = Some(snapshot);
            }
            self.last_draw = Some(now);
        }
        changed
    }
    fn event(&mut self, event: &Value) -> Option<&'static str> {
        match event["action"].as_str()? {
            "opened"
                if self
                    .last_refresh
                    .is_none_or(|at| at.elapsed() >= Duration::from_secs(60)) =>
            {
                Some("refresh")
            }
            "refresh" => Some("refresh"),
            "open" => Some("open"),
            "usage" => Some("usage"),
            "setting" => {
                let key = event["key"].as_str()?;
                let value = event.get("value")?.clone();
                let valid = allowed_setting(self.last_snapshot.as_ref(), key, &value);
                if valid && self.pending_settings.len() < 32 {
                    self.pending_settings.push_back((key.to_owned(), value));
                }
                None
            }
            _ => None,
        }
    }
    fn apply_setting(&mut self) -> Option<Value> {
        let (key, value) = self.pending_settings.front()?.clone();
        let mut patch = json!({});
        patch[key] = value;
        match call(&self.engine, "settings.patch", json!({"patch":patch})) {
            Ok(settings) => {
                self.pending_settings.pop_front();
                self.settings = settings.clone();
                self.last_draw = None;
                Some(settings)
            }
            Err(error) if engine_busy(&error) => None,
            Err(_) => {
                self.pending_settings.pop_front();
                self.last_draw = None;
                None
            }
        }
    }
    fn close(&mut self) {
        if self.closed {
            return;
        }
        self.closed = true;
        self.pending_settings.clear();
        self.history.request_shutdown();
        self.codex.request_shutdown();
        native::destroy();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn named_codex_targets_cannot_survive_a_switch_to_default_or_another_provider() {
        let named =
            json!({"id":"a","selection":{"provider":"codex","accountID":"work","modelID":"x"}});
        let other_thread =
            json!({"id":"b","selection":{"provider":"codex","accountID":"work","modelID":"x"}});
        let default = json!({"id":"b","selection":{"provider":"codex","accountID":null}});
        let claude = json!({"id":"b","selection":{"provider":"claude","accountID":"work"}});
        assert_ne!(
            codex_target(Some(&named)),
            codex_target(Some(&other_thread))
        );
        assert_ne!(codex_target(Some(&named)), codex_target(Some(&default)));
        assert_eq!(codex_target(Some(&default)), codex_target(Some(&claude)));
    }

    #[test]
    fn actions_can_change_only_offered_usage_preferences() {
        let auto = model::Choice::LastActive.encode();
        let closest = model::Choice::Closest.encode();
        let snapshot = json!({"primaryOptions":[{"value":auto}],"secondaryOptions":[{"value":null},{"value":closest}]});
        assert!(allowed_setting(
            Some(&snapshot),
            "menuBarUsage",
            &model::Choice::LastActive.encode()
        ));
        assert!(!allowed_setting(
            Some(&snapshot),
            "menuBarUsage",
            &model::Choice::Closest.encode()
        ));
        assert!(allowed_setting(
            Some(&snapshot),
            "menuBarSecondaryUsage",
            &Value::Null
        ));
        assert!(allowed_setting(
            Some(&snapshot),
            "usageDisplayMode",
            &json!("remaining")
        ));
        assert!(!allowed_setting(
            Some(&snapshot),
            "usageDisplayMode",
            &json!("unknown")
        ));
        assert!(!allowed_setting(Some(&snapshot), "providers", &json!({})));
    }
}

pub fn install(engine: SharedEngine, cx: &mut App) {
    native::install();
    let state = Rc::new(RefCell::new(Bar::new(engine, cx)));
    cx.set_global(GlobalBar(state));
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor()
                .timer(Duration::from_millis(500))
                .await;
            if !cx.update(tick) {
                break;
            }
        }
    })
    .detach();
}
fn tick(cx: &mut App) -> bool {
    let Some(state) = cx.try_global::<GlobalBar>().map(|bar| bar.0.clone()) else {
        return false;
    };
    let root = cx
        .try_global::<MainWindow>()
        .and_then(|main| main.1.upgrade());
    let (selected, running, settings, revision) = root
        .as_ref()
        .map(|root| {
            let app = root.read(cx);
            let selected = app
                .selected
                .as_ref()
                .map(|t| json!({"id":t["id"],"selection":t["selection"]}));
            let running = selected
                .as_ref()
                .is_some_and(|t| app.running.contains(&crate::text(t, "id")));
            (
                selected,
                running,
                Some(app.settings.clone()),
                Some(app.provider_configuration_panel.read(cx).account_revision()),
            )
        })
        .unwrap_or((None, false, None, None));
    let mut requests = Vec::new();
    let mut changed_settings = Vec::new();
    let usage_changed;
    {
        let Ok(mut bar) = state.try_borrow_mut() else {
            return true;
        };
        if bar.closed {
            return false;
        }
        for event in native::events() {
            if let Some(request) = bar.event(&event) {
                requests.push(request);
            }
        }
        if requests.contains(&"refresh") {
            bar.refresh(cx, Instant::now());
        }
        if let Some(settings) = bar.apply_setting() {
            changed_settings.push(settings);
        }
        // A setting just saved by this manager is newer than the root's copy.
        let root_settings = if changed_settings.is_empty() {
            settings
        } else {
            None
        };
        usage_changed = bar.tick(cx, selected, running, root_settings, revision);
    }
    for settings in changed_settings {
        with_window(cx, move |app, window, cx| {
            app.accept_settings(settings, window, cx)
        });
    }
    if usage_changed {
        with_window(cx, |app, _, cx| {
            if app.settings_open && app.settings_section == settings::SettingsSection::Usage {
                cx.notify();
            }
        });
    }
    if requests.contains(&"open") || requests.contains(&"usage") {
        reopen_main_window(cx);
        if requests.contains(&"usage") {
            with_window(cx, |app, window, cx| {
                app.open_settings_panel(window, cx);
                app.navigate_settings_section(settings::SettingsSection::Usage, window, cx);
            });
        }
    }
    true
}
fn with_window(
    cx: &mut App,
    f: impl FnOnce(&mut Coincide, &mut gpui_kit::Window, &mut gpui_kit::Context<Coincide>) + 'static,
) {
    let Some((window, root)) = cx
        .try_global::<MainWindow>()
        .map(|main| (main.0, main.1.clone()))
    else {
        return;
    };
    let _ = window.update(cx, move |_, window, cx| {
        let _ = root.update(cx, |app, cx| f(app, window, cx));
    });
}
pub fn request_shutdown(cx: &mut App) {
    if let Some(state) = cx.try_global::<GlobalBar>().map(|bar| bar.0.clone())
        && let Ok(mut bar) = state.try_borrow_mut()
    {
        bar.close();
    }
}

/// Refresh through the menu's reader when it is active, so the Settings page
/// and the status item do not supersede each other's provider requests.
pub fn refresh_for_usage(selected: Option<&Value>, cx: &mut App) -> bool {
    let Some(state) = cx.try_global::<GlobalBar>().map(|bar| bar.0.clone()) else {
        return false;
    };
    let Ok(mut bar) = state.try_borrow_mut() else {
        return false;
    };
    if bar.closed || !bar.visible() {
        return false;
    }
    if let Some(thread) = selected {
        bar.selected = Some(json!({"id":thread["id"],"selection":thread["selection"]}));
    }
    let target = bar.selected.clone();
    bar.codex.set_context(target.as_ref(), cx);
    bar.refresh(cx, Instant::now());
    bar.last_draw = None;
    true
}

/// The full Usage page may show the last exact-account observation collected
/// by the menu bar while its own explicit reader is idle.
pub fn reuse_cached(cx: &App, cards: &mut [usage_dashboard_ui::Card]) {
    let Some(state) = cx.try_global::<GlobalBar>().map(|bar| bar.0.clone()) else {
        return;
    };
    let Ok(bar) = state.try_borrow() else {
        return;
    };
    for card in cards {
        let key = (card.account.provider.to_owned(), card.account.id.clone());
        if let Some(limits) = bar.cached.get(&key) {
            let use_cached = match &card.state {
                LimitState::Ready(current) => limits.checked_at > current.checked_at,
                LimitState::Reading => false,
                _ => true,
            };
            if use_cached {
                card.state = LimitState::Ready(limits.clone());
            }
        }
    }
}
pub fn shutdown_status(cx: &mut App) -> worker_owner::ShutdownStatus {
    let Some(state) = cx.try_global::<GlobalBar>().map(|bar| bar.0.clone()) else {
        return worker_owner::ShutdownStatus {
            closed: true,
            ..Default::default()
        };
    };
    let Ok(mut bar) = state.try_borrow_mut() else {
        return worker_owner::ShutdownStatus::default();
    };
    bar.history.shutdown_status()
}
mod native {
    use serde_json::Value;
    use std::ffi::{CStr, CString};
    unsafe extern "C" {
        fn coincide_usage_status_install();
        fn coincide_usage_status_logo(
            provider: *const std::ffi::c_char,
            bytes: *const u8,
            length: usize,
        );
        fn coincide_usage_status_visible(visible: i32);
        fn coincide_usage_status_update(json: *const std::ffi::c_char);
        fn coincide_usage_status_next_event() -> *mut std::ffi::c_char;
        fn coincide_usage_status_destroy();
        fn coincide_free(bytes: *mut std::ffi::c_void);
    }
    pub fn install() {
        unsafe {
            coincide_usage_status_install();
            for (name, bytes) in crate::chat_layout::PROVIDER_LOGOS {
                let name = CString::new(name).unwrap();
                coincide_usage_status_logo(name.as_ptr(), bytes.as_ptr(), bytes.len());
            }
        }
    }
    pub fn visible(visible: bool) {
        unsafe {
            coincide_usage_status_visible(i32::from(visible));
        }
    }
    pub fn update(snapshot: &Value) {
        if let Ok(text) = CString::new(snapshot.to_string()) {
            unsafe {
                coincide_usage_status_update(text.as_ptr());
            }
        }
    }
    pub fn events() -> Vec<Value> {
        let mut events = Vec::new();
        for _ in 0..32 {
            unsafe {
                let ptr = coincide_usage_status_next_event();
                if ptr.is_null() {
                    break;
                }
                let value = serde_json::from_slice::<Value>(CStr::from_ptr(ptr).to_bytes()).ok();
                coincide_free(ptr.cast());
                if let Some(value) = value {
                    events.push(value);
                }
            }
        }
        events
    }
    pub fn destroy() {
        unsafe {
            coincide_usage_status_destroy();
        }
    }
}
