use anyhow::Result;
use coincide_core::{
    api::{Engine, SharedEngine, call},
    control,
    store::{Store, ThreadSummary, text},
};
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
    threads: Vec<ThreadSummary>,
    selected: Option<Value>,
    composer: Entity<TextareaState>,
    search: Entity<InputState>,
    status: String,
    show_archived: bool,
    _subscriptions: Vec<Subscription>,
}

impl Coincide {
    fn new(engine: SharedEngine, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let composer = cx.new(|cx| TextareaState::new(window, cx).placeholder("Write a message…"));
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search conversations"));
        let subscriptions = vec![
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
        let poll = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(150))
                    .await;
                if this.update(cx, |this, cx| this.tick(cx)).is_err() {
                    break;
                }
            }
        });
        let mut this = Self {
            engine,
            revision: 0,
            running: Vec::new(),
            _poll: poll,
            threads,
            selected: None,
            composer,
            search,
            status: "Rust preview · separate data store".into(),
            show_archived: false,
            _subscriptions: subscriptions,
        };
        if let Some(id) = this.threads.first().map(|t| t.id.clone()) {
            this.select(&id, window, cx);
        }
        this
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
                self.selected = Some(v);
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
    fn tick(&mut self, cx: &mut Context<Self>) {
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
                    self.status = "Codex · approval required for changes".into();
                    self.composer
                        .update(cx, |input, cx| input.set_value("", window, cx));
                }
                Err(e) => self.status = e.to_string(),
            }
        }
        cx.notify();
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
        let items = self
            .selected
            .as_ref()
            .and_then(|v| v["items"].as_array())
            .cloned()
            .unwrap_or_default();
        let transcript = div()
            .id("transcript")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p_6()
            .children(items.iter().enumerate().map(|(i, item)| {
                div()
                    .mb_5()
                    .p_4()
                    .rounded_lg()
                    .bg(rgb(if item["kind"] == "user" {
                        0x222c3d
                    } else {
                        0x181d28
                    }))
                    .child(
                        div()
                            .text_sm()
                            .text_color(rgb(0x98b1d4))
                            .mb_2()
                            .child(format!("{} {}", text(item, "kind"), text(item, "provider"))),
                    )
                    .child(TextView::markdown(("message", i), text(item, "text")))
            }));
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
                            .items_center()
                            .gap_3()
                            .p_4()
                            .border_b_1()
                            .border_color(rgb(0x29303d))
                            .child(div().flex_1().text_lg().child(title))
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
                    .child(
                        div()
                            .p_4()
                            .border_t_1()
                            .border_color(rgb(0x29303d))
                            .child(Textarea::new(&self.composer).h(px(110.)))
                            .child(
                                div()
                                    .flex()
                                    .gap_2()
                                    .mt_2()
                                    .child(
                                        Button::new("send")
                                            .primary()
                                            .label("Send to Codex")
                                            .on_click(cx.listener(|this, _, window, cx| {
                                                this.send(window, cx)
                                            })),
                                    )
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
    }
}
fn main() -> Result<()> {
    let data = control::data_directory()?;
    let engine = Arc::new(Mutex::new(Engine::new(Store::open(
        &data.join("coincide.sqlite"),
    )?)));
    let _server = control::serve(data.join("control.sock"), engine.clone())?;
    gpui_kit::application().run(move |cx| {
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
                cx.new(|cx| Coincide::new(engine, window, cx))
            },
        )
        .expect("Unable to open Coincide window");
        cx.activate(true);
    });
    Ok(())
}
