use anyhow::Result;
mod browser;
use browser::BrowserController;
use coincide_core::{
    api::{Engine, SharedEngine, call},
    browser_protocol::BrowserAction,
    control,
    store::{Store, ThreadSummary, text},
};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::{
    component::{
        button::*,
        input::{Input, InputEvent, InputState, Textarea, TextareaState},
        text::TextView,
        *,
    },
    *,
};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct Coincide {
    engine: SharedEngine,
    revision: u64,
    running: Vec<String>,
    _poll: Task<()>,
    terminal_id: Option<String>,
    terminal_text: String,
    terminal_focus: FocusHandle,
    transcript_list: ListState,
    transcript_count: usize,
    expanded: std::collections::HashSet<usize>,
    threads: Vec<ThreadSummary>,
    selected: Option<Value>,
    composer: Entity<TextareaState>,
    search: Entity<InputState>,
    status: String,
    show_archived: bool,
    browser: Option<BrowserController>,
    browser_address: Entity<InputState>,
    browser_address_page: Option<(String, String)>,
    browser_panels: std::collections::HashSet<String>,
    browser_ui_operations: std::collections::HashMap<String, String>,
    _subscriptions: Vec<Subscription>,
}

impl Coincide {
    fn new(
        engine: SharedEngine,
        profile_dir: std::path::PathBuf,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let composer = cx.new(|cx| TextareaState::new(window, cx).placeholder("Write a message…"));
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search conversations"));
        let browser_address =
            cx.new(|cx| InputState::new(window, cx).placeholder("https://example.com"));
        let (browser, browser_error) = match BrowserController::new(profile_dir) {
            Ok(browser) => (Some(browser), None),
            Err(error) => (None, Some(format!("Browser unavailable: {error}"))),
        };
        if let Ok(mut engine) = engine.lock() {
            engine.ui_available = browser.is_some();
        }
        let subscriptions = vec![
            cx.subscribe(&browser_address, |this, _, event, cx| {
                if matches!(event, InputEvent::PressEnter { .. }) {
                    this.browser_go(cx);
                }
            }),
            cx.subscribe(&search, |this, _, event, cx| {
                if matches!(event, InputEvent::Change) {
                    this.refresh(cx);
                }
            }),
            cx.subscribe(&composer, |this, _, event, cx| {
                if matches!(event, InputEvent::Change) {
                    if let Some(v) = this.selected.as_mut() {
                        let draft=this.composer.read(cx).value().to_string();
                        if v["draft"].as_str()==Some(draft.as_str()) {return;}
                        v["draft"]=json!(draft);
                        if let Err(e) = call(&this.engine,"threads.patch",json!({"threadId":v["id"],"patch":{"draft":this.composer.read(cx).value().to_string()}})) {
                            this.status=format!("Draft could not be saved: {e}");
                        }
                    }
                }
            }),
        ];
        let threads = call(&engine, "threads.list", json!({}))
            .and_then(|v| Ok(serde_json::from_value(v)?))
            .unwrap_or_default();
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(150))
                    .await;
                if this
                    .update_in(cx, |this, window, cx| this.tick(window, cx))
                    .is_err()
                {
                    break;
                }
            }
        });
        let mut this = Self {
            engine,
            revision: 0,
            running: Vec::new(),
            _poll: poll,
            terminal_id: None,
            terminal_text: String::new(),
            terminal_focus: cx.focus_handle(),
            transcript_list: ListState::new(0, ListAlignment::Bottom, px(500.)),
            transcript_count: 0,
            expanded: Default::default(),
            threads,
            selected: None,
            composer,
            search,
            status: browser_error.unwrap_or_else(|| "Rust preview · separate data store".into()),
            show_archived: false,
            browser,
            browser_address,
            browser_address_page: None,
            browser_panels: Default::default(),
            browser_ui_operations: Default::default(),
            _subscriptions: subscriptions,
        };
        if let Some(id) = this.threads.first().map(|t| t.id.clone()) {
            this.select(&id, window, cx);
        }
        this
    }
    fn browser_action(
        &mut self,
        action: BrowserAction,
        tab: Option<String>,
        cx: &mut Context<Self>,
    ) {
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        let mut params = serde_json::to_value(action).unwrap_or_default();
        params["threadId"] = json!(thread);
        if let Some(tab) = tab {
            params["tab"] = json!(tab);
        }
        match call(&self.engine, "browser.request", params) {
            Ok(result) => {
                self.browser_ui_operations
                    .insert(text(&result, "operationId"), thread);
            }
            Err(error) => self.status = format!("Browser: {error}"),
        }
        cx.notify();
    }
    fn browser_go(&mut self, cx: &mut Context<Self>) {
        let url = self.browser_address.read(cx).value().to_string();
        self.browser_action(BrowserAction::Navigate { url }, None, cx);
    }
    fn toggle_browser(&mut self, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        let action = if self.browser_panels.contains(&thread) {
            BrowserAction::Hide
        } else {
            BrowserAction::Show
        };
        self.browser_action(action, None, cx);
    }
    fn poll_browser(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let requests = self
            .engine
            .lock()
            .map(|mut engine| engine.browser_requests.drain(..).collect::<Vec<_>>())
            .unwrap_or_default();
        let Some(browser) = &mut self.browser else {
            return;
        };
        let mut changed = !requests.is_empty();
        for request in requests {
            match &request.action {
                BrowserAction::Show => {
                    self.browser_panels.insert(request.thread_id.clone());
                }
                BrowserAction::Hide => {
                    self.browser_panels.remove(&request.thread_id);
                }
                _ => {}
            }
            browser.execute(request, window, cx);
        }
        changed |= browser.poll(window, cx);
        let selected = self.selected.as_ref().map(|v| text(v, "id"));
        let visible = selected
            .as_deref()
            .filter(|thread| self.browser_panels.contains(*thread));
        // API work for another thread may create a native surface; reconcile it
        // before yielding to the run loop so it never covers this conversation.
        browser.set_thread_visible(visible, cx);
        let replies = browser.drain_replies();
        for reply in replies {
            if let Ok(mut engine) = self.engine.lock() {
                engine.browser_reply(reply);
            }
        }
        for (id, thread) in self.browser_ui_operations.clone() {
            match call(
                &self.engine,
                "browser.result",
                json!({"operationId":id,"threadId":thread}),
            ) {
                Ok(result) if result["ready"] == true => {
                    self.browser_ui_operations.remove(&id);
                    if let Some(error) = result["result"]["error"].as_str() {
                        self.status = format!("Browser: {error}");
                    }
                    changed = true;
                }
                Err(error) => {
                    self.browser_ui_operations.remove(&id);
                    self.status = format!("Browser: {error}");
                    changed = true;
                }
                _ => {}
            }
        }
        // Track the actual page, not each render, so an unsubmitted address is
        // retained until navigation/tab selection changes it. Never replace text
        // while the user is working in the address field.
        if !self
            .browser_address
            .read(cx)
            .focus_handle(cx)
            .is_focused(window)
        {
            let current_page = selected.as_deref().and_then(|thread| {
                let tabs = browser.tab_list(thread);
                tabs["tabs"]
                    .as_array()?
                    .iter()
                    .find(|tab| tab["active"] == true)
                    .map(|tab| (text(tab, "id"), text(tab, "url")))
            });
            if current_page != self.browser_address_page {
                let address = current_page
                    .as_ref()
                    .map(|(_, url)| url.as_str())
                    .unwrap_or("");
                self.browser_address
                    .update(cx, |input, cx| input.set_value(address, window, cx));
                self.browser_address_page = current_page;
                changed = true;
            }
        }
        if changed {
            cx.notify();
        }
    }
    fn browser_pane(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let thread = self.selected.as_ref().map(|v| text(v, "id"))?;
        let browser = self.browser.as_ref()?;
        if !browser.is_visible(&thread) {
            return None;
        }
        let tabs = browser.tab_list(&thread);
        let webview = browser.active_view(&thread);
        let active = tabs["tabs"]
            .as_array()
            .and_then(|tabs| tabs.iter().find(|t| t["active"] == true))
            .cloned();
        let url = active
            .as_ref()
            .map(|tab| text(tab, "url"))
            .unwrap_or_default();
        let tab_buttons = tabs["tabs"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|tab| {
                let id = text(tab, "id");
                let title: String = text(tab, "title").chars().take(24).collect();
                Button::new(SharedString::from(format!("browser-tab-{id}")))
                    .label(title)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.browser_action(BrowserAction::SelectTab, Some(id.clone()), cx)
                    }))
            })
            .collect::<Vec<_>>();
        let active_id = active.as_ref().map(|tab| text(tab, "id"));
        Some(
            div()
                .flex()
                .flex_col()
                .w(px(500.))
                .flex_shrink_0()
                .h_full()
                .border_l_1()
                .border_color(rgb(0x29303d))
                .child(
                    div()
                        .flex()
                        .flex_wrap()
                        .flex_shrink_0()
                        .gap_1()
                        .p_2()
                        .child(Button::new("browser-back").label("←").on_click(cx.listener(
                            |this, _, _, cx| this.browser_action(BrowserAction::Back, None, cx),
                        )))
                        .child(
                            Button::new("browser-forward")
                                .label("→")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.browser_action(BrowserAction::Forward, None, cx)
                                })),
                        )
                        .child(
                            Button::new("browser-reload")
                                .label("Reload")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.browser_action(BrowserAction::Reload, None, cx)
                                })),
                        )
                        .child(
                            Button::new("browser-new-tab")
                                .label("+")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.browser_action(
                                        BrowserAction::NewTab { url: None },
                                        None,
                                        cx,
                                    )
                                })),
                        )
                        .child(
                            Button::new("browser-close-tab")
                                .label("Close tab")
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if let Some(id) = active_id.clone() {
                                        this.browser_action(BrowserAction::CloseTab, Some(id), cx);
                                    }
                                })),
                        )
                        .child(
                            Button::new("browser-hide")
                                .label("Hide")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.browser_action(BrowserAction::Hide, None, cx)
                                })),
                        ),
                )
                .child(
                    div()
                        .id("browser-tabs")
                        .flex()
                        .gap_1()
                        .px_2()
                        .overflow_x_scroll()
                        .children(tab_buttons),
                )
                .child(
                    div()
                        .flex()
                        .gap_1()
                        .p_2()
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .child(Input::new(&self.browser_address)),
                        )
                        .child(
                            Button::new("browser-go")
                                .label("Go")
                                .on_click(cx.listener(|this, _, _, cx| this.browser_go(cx))),
                        ),
                )
                .child(
                    div()
                        .px_2()
                        .pb_2()
                        .min_w_0()
                        .truncate()
                        .text_xs()
                        .child(url),
                )
                .child(
                    div()
                        .flex_1()
                        .min_h_0()
                        .when_some(webview, |pane, view| pane.child(view)),
                )
                .into_any_element(),
        )
    }
    fn refresh(&mut self, cx: &mut Context<Self>) {
        match call(&self.engine,"threads.list",json!({"query":self.search.read(cx).value().to_string(),"includeArchived":self.show_archived})).and_then(|v|Ok(serde_json::from_value(v)?)) {
            Ok(threads) => self.threads = threads,
            Err(e) => self.status = format!("Unable to load conversations: {e}"),
        }
        cx.notify();
    }
    fn select(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        match call(&self.engine, "threads.read", json!({"threadId":id})) {
            Ok(v) => {
                let draft = text(&v, "draft");
                self.transcript_count = v["items"].as_array().map_or(0, Vec::len);
                self.transcript_list.reset(self.transcript_count);
                self.expanded.clear();
                self.selected = Some(v);
                let visible = self.browser_panels.contains(id).then_some(id);
                if let Some(browser) = &mut self.browser {
                    browser.set_thread_visible(visible, cx);
                    let tabs = browser.tab_list(id);
                    let url = tabs["tabs"]
                        .as_array()
                        .and_then(|tabs| tabs.iter().find(|t| t["active"] == true))
                        .map(|tab| text(tab, "url"))
                        .unwrap_or_default();
                    self.browser_address
                        .update(cx, |input, cx| input.set_value(url, window, cx));
                }
                if let Ok(mut engine) = self.engine.lock() {
                    engine.active_thread = Some(id.into());
                }
                self.terminal_id = None;
                self.terminal_text.clear();
                self.composer
                    .update(cx, |input, cx| input.set_value(draft, window, cx));
            }
            Err(e) => self.status = format!("Unable to open conversation: {e}"),
        }
        cx.notify();
    }
    fn new_thread(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let project = self
            .selected
            .as_ref()
            .map(|v| text(v, "projectID"))
            .unwrap_or_else(|| "00000000-0000-0000-0000-000000000000".into());
        match call(
            &self.engine,
            "threads.create",
            json!({"projectId":project,"cwd":std::env::current_dir().ok()}),
        ) {
            Ok(v) => {
                self.refresh(cx);
                self.select(&text(&v, "id"), window, cx);
            }
            Err(e) => self.status = e.to_string(),
        }
    }
    fn toggle(&mut self, key: &str, cx: &mut Context<Self>) {
        if let Some(v) = self.selected.as_ref() {
            let mut patch = json!({});
            patch[key] = json!(!v[key].as_bool().unwrap_or(false));
            match call(
                &self.engine,
                "threads.patch",
                json!({"threadId":v["id"],"patch":patch}),
            ) {
                Ok(v) => self.selected = Some(v),
                Err(e) => self.status = e.to_string(),
            }
            self.refresh(cx);
        }
    }
    fn tick(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.engine.lock().is_ok_and(|engine| engine.shutdown) {
            cx.quit();
            return;
        }
        self.poll_browser(window, cx);
        if let Some(id) = self.terminal_id.as_ref() {
            if let Ok(snapshot) = call(&self.engine, "terminal.read", json!({"terminalId":id})) {
                let text = snapshot["lines"]
                    .as_array()
                    .map(|lines| {
                        lines
                            .iter()
                            .filter_map(|s| s.as_str())
                            .collect::<Vec<_>>()
                            .join("\n")
                    })
                    .unwrap_or_default();
                if self.terminal_text != text {
                    self.terminal_text = text;
                    cx.notify();
                }
            }
        }
        if let Ok(status) = call(&self.engine, "app.status", json!({})) {
            self.running = status["running"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default();
            let revision = status["revision"].as_u64().unwrap_or(0);
            if revision != self.revision {
                self.revision = revision;
                if let Some(id) = self.selected.as_ref().map(|v| text(v, "id")) {
                    if let Ok(v) = call(&self.engine, "threads.read", json!({"threadId":id})) {
                        let count = v["items"].as_array().map_or(0, Vec::len);
                        let start = self.transcript_count.saturating_sub(1).min(count);
                        self.transcript_list
                            .splice(start..self.transcript_count, count - start);
                        self.transcript_count = count;
                        self.selected = Some(v);
                    }
                }
                self.refresh(cx);
            }
        }
    }
    fn send(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(v) = self.selected.as_ref() {
            match call(
                &self.engine,
                "agent.send",
                json!({"threadId":v["id"],"text":self.composer.read(cx).value().to_string()}),
            ) {
                Ok(_) => {
                    self.status = "Agent running · approval required for changes".into();
                    self.composer
                        .update(cx, |input, cx| input.set_value("", window, cx));
                }
                Err(e) => self.status = e.to_string(),
            }
        }
        cx.notify();
    }
    fn select_provider(&mut self, provider: &str, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        match call(
            &self.engine,
            "agent.select",
            json!({"threadId":thread,"provider":provider}),
        ) {
            Ok(thread) => {
                self.selected = Some(thread);
                self.status = format!("Selected {provider}");
            }
            Err(error) => self.status = error.to_string(),
        }
        cx.notify();
    }
    fn message(
        &mut self,
        index: usize,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(item) = self
            .selected
            .as_ref()
            .and_then(|v| v["items"].as_array())
            .and_then(|items| items.get(index))
        else {
            return div().into_any_element();
        };
        let kind = text(item, "kind");
        let body = text(item, "text");
        let collapsible = kind != "user" && kind != "assistant";
        let expanded = self.expanded.contains(&index);
        let shown = if collapsible && !expanded {
            body.chars().take(180).collect()
        } else {
            body
        };
        let label = format!("{} {}", kind, text(item, "provider"));
        div()
            .mx_6()
            .my_2()
            .p_4()
            .rounded_lg()
            .bg(rgb(if kind == "user" { 0x222c3d } else { 0x181d28 }))
            .child(
                div()
                    .text_sm()
                    .text_color(rgb(0x98b1d4))
                    .mb_2()
                    .child(label),
            )
            .when(collapsible, |view| {
                view.child(
                    Button::new(("expand", index))
                        .label(if expanded { "Collapse" } else { "Expand" })
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if !this.expanded.remove(&index) {
                                this.expanded.insert(index);
                            }
                            this.transcript_list.splice(index..index + 1, 1);
                            cx.notify();
                        })),
                )
            })
            .child(TextView::markdown(("message", index), shown))
            .into_any_element()
    }
    fn terminal(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.terminal_id.is_some() {
            self.terminal_id = None;
            cx.notify();
            return;
        }
        if let Some(v) = self.selected.as_ref() {
            let params = json!({"threadId":v["id"]});
            let existing = call(&self.engine, "terminal.list", params.clone())
                .ok()
                .and_then(|v| v[0]["terminalId"].as_str().map(str::to_owned));
            match existing.map(Ok).unwrap_or_else(|| {
                call(&self.engine, "terminal.create", params).map(|v| text(&v, "terminalId"))
            }) {
                Ok(id) => {
                    self.terminal_id = Some(id);
                    window.focus(&self.terminal_focus, cx);
                }
                Err(e) => self.status = e.to_string(),
            }
        }
        cx.notify();
    }
    fn terminal_key(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) {
        let Some(id) = self.terminal_id.as_ref() else {
            return;
        };
        let key = &event.keystroke;
        if key.modifiers.platform {
            return;
        }
        let input = if key.modifiers.control && key.key.len() == 1 {
            let b = key.key.as_bytes()[0].to_ascii_uppercase();
            if (b'@'..=b'_').contains(&b) {
                String::from((b - 64) as char)
            } else {
                return;
            }
        } else {
            match key.key.as_str() {
                "enter" => "\r".into(),
                "backspace" => "\x7f".into(),
                "tab" => "\t".into(),
                "escape" => "\x1b".into(),
                "up" => "\x1b[A".into(),
                "down" => "\x1b[B".into(),
                "right" => "\x1b[C".into(),
                "left" => "\x1b[D".into(),
                _ => match &key.key_char {
                    Some(text) => text.clone(),
                    None => return,
                },
            }
        };
        if let Err(e) = call(
            &self.engine,
            "terminal.write",
            json!({"terminalId":id,"text":input}),
        ) {
            self.status = e.to_string();
        }
        cx.stop_propagation();
    }
    fn fork(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(v) = self.selected.as_ref() {
            match call(&self.engine, "threads.fork", json!({"threadId":v["id"]})) {
                Ok(v) => {
                    self.select(&text(&v, "id"), window, cx);
                    self.refresh(cx);
                }
                Err(e) => self.status = e.to_string(),
            }
        }
    }
}
impl Render for Coincide {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let open = self
            .engine
            .lock()
            .ok()
            .and_then(|mut engine| engine.requested_open.take());
        if let Some(id) = open {
            self.select(&id, window, cx);
        }
        if let Some(v) = self.selected.as_ref() {
            let draft = text(v, "draft");
            if self.composer.read(cx).value().as_ref() != draft {
                self.composer
                    .update(cx, |input, cx| input.set_value(draft, window, cx));
            }
        }
        let selected_id = self
            .selected
            .as_ref()
            .map(|v| text(v, "id"))
            .unwrap_or_default();
        let sidebar = div()
            .flex()
            .flex_col()
            .w(px(280.))
            .h_full()
            .bg(rgb(0x151922))
            .border_r_1()
            .border_color(rgb(0x29303d))
            .p_3()
            .gap_3()
            .child(div().text_xl().child("Coincide"))
            .child(
                Button::new("new")
                    .label("New conversation")
                    .on_click(cx.listener(|this, _, window, cx| this.new_thread(window, cx))),
            )
            .child(Input::new(&self.search))
            .child(
                Button::new("archived")
                    .label(if self.show_archived {
                        "Hide archived"
                    } else {
                        "Show archived"
                    })
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.show_archived = !this.show_archived;
                        this.refresh(cx);
                    })),
            )
            .child(div().id("threads").flex_1().overflow_y_scroll().children(
                self.threads.iter().map(|thread| {
                    let id = thread.id.clone();
                    div()
                        .id(SharedString::from(id.clone()))
                        .p_3()
                        .rounded_md()
                        .cursor_pointer()
                        .bg(if id == selected_id {
                            rgb(0x2b3549)
                        } else {
                            rgb(0x151922)
                        })
                        .child(format!(
                            "{}{}",
                            if thread.pinned { "★ " } else { "" },
                            thread.title
                        ))
                        .on_click(
                            cx.listener(move |this, _, window, cx| this.select(&id, window, cx)),
                        )
                }),
            ));
        let title = self
            .selected
            .as_ref()
            .map(|v| text(v, "title"))
            .unwrap_or_else(|| "Welcome to Coincide".into());
        let entity = cx.entity();
        let transcript = list(self.transcript_list.clone(), move |index, window, cx| {
            entity.update(cx, |this, cx| this.message(index, window, cx))
        })
        .flex_1()
        .min_h_0();
        let browser_pane = self.browser_pane(cx);
        div()
            .flex()
            .size_full()
            .bg(rgb(0x10141c))
            .text_color(rgb(0xe4e9f2))
            .child(sidebar)
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .child(
                        div()
                            .flex()
                            .flex_wrap()
                            .flex_shrink_0()
                            .w_full()
                            .overflow_hidden()
                            .items_center()
                            .gap_3()
                            .p_4()
                            .border_b_1()
                            .border_color(rgb(0x29303d))
                            .child(div().w_full().min_w_0().truncate().text_lg().child(title))
                            .child(Button::new("terminal").label("Terminal").on_click(
                                cx.listener(|this, _, window, cx| this.terminal(window, cx)),
                            ))
                            .child(
                                Button::new("browser").label("Browser").on_click(
                                    cx.listener(|this, _, _, cx| this.toggle_browser(cx)),
                                ),
                            )
                            .child(
                                Button::new("fork").label("Fork").on_click(
                                    cx.listener(|this, _, window, cx| this.fork(window, cx)),
                                ),
                            )
                            .child(Button::new("pin").label("Pin / unpin").on_click(
                                cx.listener(|this, _, _, cx| this.toggle("isPinned", cx)),
                            ))
                            .child(Button::new("archive").label("Archive / restore").on_click(
                                cx.listener(|this, _, _, cx| this.toggle("isArchived", cx)),
                            )),
                    )
                    .child(transcript)
                    .when(self.terminal_id.is_some(), |view| {
                        view.child(
                            div()
                                .id("terminal-pane")
                                .h(px(250.))
                                .overflow_y_scroll()
                                .p_3()
                                .bg(rgb(0x090d13))
                                .track_focus(&self.terminal_focus)
                                .on_mouse_down(
                                    MouseButton::Left,
                                    cx.listener(|this, _, window, cx| {
                                        window.focus(&this.terminal_focus, cx)
                                    }),
                                )
                                .on_key_down(
                                    cx.listener(|this, event, _, cx| this.terminal_key(event, cx)),
                                )
                                .font_family(if cfg!(target_os = "macos") {
                                    "Menlo"
                                } else {
                                    "monospace"
                                })
                                .text_size(px(12.))
                                .child(self.terminal_text.clone()),
                        )
                    })
                    .child(
                        div()
                            .p_4()
                            .border_t_1()
                            .border_color(rgb(0x29303d))
                            .child(
                                div()
                                    .flex()
                                    .gap_2()
                                    .mb_2()
                                    .child(Button::new("provider-codex").label("Codex").on_click(
                                        cx.listener(|this, _, _, cx| {
                                            this.select_provider("codex", cx)
                                        }),
                                    ))
                                    .child(Button::new("provider-claude").label("Claude").on_click(
                                        cx.listener(|this, _, _, cx| {
                                            this.select_provider("claude", cx)
                                        }),
                                    ))
                                    .child(
                                        div().text_sm().child(
                                            self.selected
                                                .as_ref()
                                                .map(|v| text(&v["selection"], "provider"))
                                                .unwrap_or_default(),
                                        ),
                                    ),
                            )
                            .child(Textarea::new(&self.composer).h(px(110.)))
                            .child(
                                div()
                                    .flex()
                                    .gap_2()
                                    .mt_2()
                                    .child(Button::new("send").primary().label("Send").on_click(
                                        cx.listener(|this, _, window, cx| this.send(window, cx)),
                                    ))
                                    .child(Button::new("stop").label("Stop").on_click(
                                        cx.listener(|this, _, _, cx| {
                                            if let Some(v) = this.selected.as_ref() {
                                                if let Err(e) = call(
                                                    &this.engine,
                                                    "agent.stop",
                                                    json!({"threadId":v["id"]}),
                                                ) {
                                                    this.status = e.to_string();
                                                }
                                            }
                                            cx.notify();
                                        }),
                                    )),
                            )
                            .child(
                                div()
                                    .mt_2()
                                    .text_sm()
                                    .text_color(rgb(0x98a6ba))
                                    .child(self.status.clone()),
                            ),
                    ),
            )
            .when_some(browser_pane, |view, pane| view.child(pane))
    }
}
fn main() -> Result<()> {
    let data = control::data_directory()?;
    let engine = Arc::new(Mutex::new(Engine::new(Store::open(
        &data.join("coincide.sqlite"),
    )?)));
    let _server = control::serve(data.join("control.sock"), engine.clone())?;
    #[cfg(target_os = "linux")]
    let application = gpui_kit::platform::linux(WindowingModes::X11);
    #[cfg(not(target_os = "linux"))]
    let application = gpui_kit::application();
    application.run(move |cx| {
        gpui_kit::init(cx);
        Theme::change(ThemeMode::Dark, None, cx);
        let bounds = Bounds::centered(None, size(px(1180.), px(820.)), cx);
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                ..Default::default()
            },
            cx,
            |window, cx| {
                window.set_window_title("Coincide Rust Preview");
                cx.new(|cx| Coincide::new(engine, data.join("browser-profile"), window, cx))
            },
        )
        .expect("Unable to open Coincide window");
        cx.activate(true);
    });
    Ok(())
}
