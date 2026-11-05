//! Parent: create/render Entity<BotSettingsPanel>; subscribe to BotSettingsEvent
//! for saved IDs if needed. This editor only persists name and bot.persona.
use anyhow::{Context as _, Result, ensure};
use coincide_core::api::{SharedEngine, call};
use gpui_kit::base::Disableable;
use gpui_kit::{
    component::{
        button::*,
        input::{Input, InputEvent, InputState, Textarea, TextareaState},
    },
    *,
};
use serde_json::{Value, json};
use std::{collections::HashMap, sync::mpsc, time::Duration};
const NEW: &str = "new-local-draft";
#[derive(Clone, Debug)]
struct Bound {
    bot: Value,
    baseline: String,
    origin: String,
}
fn metadata(reply: &Value) -> Result<(String, String)> {
    let baseline = reply["baseline"].as_str().context("Missing bot baseline")?;
    ensure!(
        baseline.len() == 64 && baseline.bytes().all(|b| b.is_ascii_hexdigit()),
        "Invalid bot baseline"
    );
    ensure!(
        reply["instructionsScope"] == "bot-local" && reply["executionConnected"] == false,
        "Unsupported bot editing scope"
    );
    let origin = reply["origin"].as_str().context("Missing bot origin")?;
    ensure!(
        matches!(origin, "local" | "imported" | "empty"),
        "Invalid bot origin"
    );
    Ok((baseline.into(), origin.into()))
}
impl Bound {
    fn parse(reply: Value) -> Result<Self> {
        let (baseline, origin) = metadata(&reply)?;
        ensure!(reply["bot"].is_object(), "Missing saved bot");
        uuid::Uuid::parse_str(reply["bot"]["id"].as_str().context("Missing bot ID")?)?;
        Ok(Self {
            bot: reply["bot"].clone(),
            baseline,
            origin,
        })
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Fields {
    name: String,
    persona: String,
}
impl Fields {
    fn from_bot(bot: &Value) -> Self {
        Self {
            name: bot["name"].as_str().unwrap_or("").into(),
            persona: bot["persona"].as_str().unwrap_or("").into(),
        }
    }
    fn patch(&self) -> Result<Value> {
        let name = self.name.trim();
        ensure!(
            !name.is_empty() && name.chars().count() <= 200,
            "Name must contain 1–200 characters"
        );
        ensure!(
            self.persona.chars().count() <= 20_000,
            "Bot instructions must fit within 20,000 characters"
        );
        Ok(json!({"name":name,"persona":self.persona}))
    }
}
#[derive(Clone)]
struct Write {
    key: String,
    id: Option<String>,
    baseline: String,
    fields: Fields,
}
impl Write {
    fn params(&self) -> Result<Value> {
        let mut params = json!({"baseline":self.baseline,"patch":self.fields.patch()?});
        if let Some(id) = &self.id {
            params["botId"] = json!(id);
        }
        Ok(params)
    }
}
enum Action {
    List,
    Read(String),
    Write(Write),
}
enum Outcome {
    List(Value),
    Read(Bound),
    Saved(Write, Bound),
}
fn run(api: &mut impl FnMut(&str, Value) -> Result<Value>, action: Action) -> Result<Outcome> {
    match action {
        Action::List => {
            let reply = api("bots.list", json!({}))?;
            metadata(&reply)?;
            let bots = reply["bots"].as_array().context("Missing bot list")?;
            ensure!(bots.len() <= 10_000, "Bot list exceeds limit");
            Ok(Outcome::List(reply))
        }
        Action::Read(id) => {
            let bound = Bound::parse(api("bots.read", json!({"botId":id}))?)?;
            ensure!(
                bound.bot["id"]
                    .as_str()
                    .is_some_and(|s| s.eq_ignore_ascii_case(&id)),
                "Bot read returned another bot"
            );
            Ok(Outcome::Read(bound))
        }
        Action::Write(write) => {
            let method = if write.id.is_some() {
                "bots.patch"
            } else {
                "bots.save"
            };
            let bound = Bound::parse(api(method, write.params()?)?)?;
            if let Some(id) = &write.id {
                ensure!(
                    bound.bot["id"]
                        .as_str()
                        .is_some_and(|s| s.eq_ignore_ascii_case(id)),
                    "Bot save returned another bot"
                );
            }
            Ok(Outcome::Saved(write, bound))
        }
    }
}
struct Editor {
    bound: Bound,
    name: Entity<InputState>,
    persona: Entity<TextareaState>,
    blocked: bool,
    _subscriptions: Vec<Subscription>,
}
impl Editor {
    fn new(bound: Bound, window: &mut Window, cx: &mut Context<BotSettingsPanel>) -> Self {
        let fields = Fields::from_bot(&bound.bot);
        let name = cx.new(|cx| InputState::new(window, cx).placeholder("Bot name"));
        name.update(cx, |input, cx| input.set_value(fields.name, window, cx));
        let persona = cx.new(|cx| {
            TextareaState::new(window, cx)
                .placeholder("This bot’s instructions")
                .submit_on_enter(false)
        });
        persona.update(cx, |input, cx| input.set_value(fields.persona, window, cx));
        let subscriptions = vec![
            cx.subscribe(&name, |_, _, event, cx| {
                if matches!(event, InputEvent::Change) {
                    cx.notify();
                }
            }),
            cx.subscribe(&persona, |_, _, event, cx| {
                if matches!(event, InputEvent::Change) {
                    cx.notify();
                }
            }),
        ];
        Self {
            bound,
            name,
            persona,
            blocked: false,
            _subscriptions: subscriptions,
        }
    }
    fn fields(&self, cx: &App) -> Fields {
        Fields {
            name: self.name.read(cx).value().to_string(),
            persona: self.persona.read(cx).value().to_string(),
        }
    }
}
pub enum BotSettingsEvent {
    Saved { bot_id: String },
}
pub struct BotSettingsPanel {
    engine: SharedEngine,
    bots: Vec<Value>,
    baseline: Option<String>,
    selected: Option<String>,
    editors: HashMap<String, Editor>,
    generation: u64,
    busy: bool,
    pending_key: Option<String>,
    pending_write: bool,
    notice: String,
    tx: mpsc::Sender<(u64, Result<Outcome>)>,
    rx: mpsc::Receiver<(u64, Result<Outcome>)>,
    _poll: Task<()>,
}
impl EventEmitter<BotSettingsEvent> for BotSettingsPanel {}
impl BotSettingsPanel {
    pub fn new(engine: SharedEngine, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (tx, rx) = mpsc::channel();
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
                if this
                    .update_in(cx, |this, window, cx| this.poll(window, cx))
                    .is_err()
                {
                    break;
                }
            }
        });
        let mut panel = Self {
            engine,
            bots: Vec::new(),
            baseline: None,
            selected: None,
            editors: HashMap::new(),
            generation: 0,
            busy: false,
            pending_key: None,
            pending_write: false,
            notice: String::new(),
            tx,
            rx,
            _poll: poll,
        };
        panel.start(Action::List, cx);
        panel
    }
    fn start(&mut self, action: Action, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        self.busy = true;
        self.pending_write = matches!(&action, Action::Write(_));
        self.pending_key = match &action {
            Action::Write(w) => Some(w.key.clone()),
            Action::Read(id) => Some(id.clone()),
            Action::List => None,
        };
        self.notice = if self.pending_write {
            "Saving bot… You can keep editing; edits made now will remain unsaved."
        } else {
            "Loading saved bot data… Drafts are retained."
        }
        .into();
        let (engine, tx, generation) = (self.engine.clone(), self.tx.clone(), self.generation);
        std::thread::spawn(move || {
            let result = run(&mut |method, params| call(&engine, method, params), action);
            let _ = tx.send((generation, result));
        });
        cx.notify();
    }
    fn select(&mut self, id: String, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        self.generation = self.generation.wrapping_add(1);
        self.selected = Some(id.clone());
        if !self.editors.contains_key(&id) {
            self.start(Action::Read(id), cx);
        } else {
            self.notice="Draft restored. Reload the saved baseline if another bot was saved since this draft was opened.".into();
        }
        cx.notify();
    }
    fn create(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(baseline) = self.baseline.clone() else {
            return;
        };
        self.generation = self.generation.wrapping_add(1);
        self.selected = Some(NEW.into());
        self.editors.entry(NEW.into()).or_insert_with(|| {
            Editor::new(
                Bound {
                    bot: json!({"name":"","persona":""}),
                    baseline,
                    origin: "empty".into(),
                },
                window,
                cx,
            )
        });
        self.notice =
            "New bot draft. Save creates one stable server ID. Execution is unavailable.".into();
        cx.notify();
    }
    fn save(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(key) = self.selected.clone() else {
            return;
        };
        let Some(editor) = self.editors.get(&key).filter(|e| !e.blocked) else {
            return;
        };
        let fields = editor.fields(cx);
        if let Err(error) = fields.patch() {
            self.notice = error.to_string();
            cx.notify();
            return;
        }
        let write = Write {
            key,
            id: editor.bound.bot["id"].as_str().map(str::to_owned),
            baseline: editor.bound.baseline.clone(),
            fields,
        };
        self.start(Action::Write(write), cx);
    }
    fn reload(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        if let Some(key) = self.selected.clone() {
            if key == NEW {
                self.start(Action::List, cx);
            } else {
                self.start(Action::Read(key), cx);
            }
        }
    }
    fn poll(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Ok((generation, result)) = self.rx.try_recv() else {
            return;
        };
        self.busy = false;
        let key = self.pending_key.take();
        let was_write = std::mem::take(&mut self.pending_write);
        match result {
            Ok(Outcome::List(reply)) => {
                self.baseline = reply["baseline"].as_str().map(str::to_owned);
                self.bots = reply["bots"].as_array().cloned().unwrap_or_default();
                if let Some(editor) = self.editors.get_mut(NEW) {
                    editor.bound.baseline = self.baseline.clone().unwrap_or_default();
                    editor.blocked = false;
                }
                self.notice =
                    "Saved bot list refreshed. Drafts retained. Choose a bot or create one.".into();
            }
            Ok(Outcome::Read(bound)) if generation == self.generation => {
                let id = key.unwrap_or_default();
                self.baseline = Some(bound.baseline.clone());
                if let Some(editor) = self.editors.get_mut(&id) {
                    editor.bound = bound;
                    editor.blocked = false;
                    self.notice="Saved baseline reloaded; your draft is retained. Compare the saved values below before saving again.".into();
                } else {
                    self.editors.insert(id, Editor::new(bound, window, cx));
                    self.notice = "Edit this bot’s name or instructions, then Save.".into();
                }
            }
            Ok(Outcome::Read(_)) => {
                self.notice = "Selection changed; stale read discarded. Drafts retained.".into();
            }
            Ok(Outcome::Saved(write, bound)) => {
                let id = bound.bot["id"].as_str().unwrap_or_default().to_owned();
                self.baseline = Some(bound.baseline.clone());
                if let Some(mut editor) = self.editors.remove(&write.key) {
                    // Normalize server-trimmed fields only if no text changed while saving.
                    // Otherwise keep the native input entities and their newer draft intact.
                    if editor.fields(cx) == write.fields {
                        let saved = Fields::from_bot(&bound.bot);
                        editor
                            .name
                            .update(cx, |input, cx| input.set_value(saved.name, window, cx));
                        editor
                            .persona
                            .update(cx, |input, cx| input.set_value(saved.persona, window, cx));
                    }
                    editor.bound = bound.clone();
                    editor.blocked = false;
                    self.editors.insert(id.clone(), editor);
                }
                if self.selected.as_deref() == Some(write.key.as_str()) {
                    self.selected = Some(id.clone());
                }
                if let Some(bot) = self.bots.iter_mut().find(|b| {
                    b["id"]
                        .as_str()
                        .is_some_and(|s| s.eq_ignore_ascii_case(&id))
                }) {
                    *bot = bound.bot;
                } else {
                    self.bots.push(bound.bot);
                }
                self.notice="Saved bot settings. Any edits typed during Save remain in the draft. Bot execution is unavailable.".into();
                cx.emit(BotSettingsEvent::Saved { bot_id: id });
            }
            Err(error) => {
                if was_write && let Some(editor) = key.and_then(|key| self.editors.get_mut(&key)) {
                    editor.blocked = true;
                }
                self.notice = format!(
                    "{error}. Draft retained. Reload the saved baseline before retrying; after uncertain creation, refresh the list and check for a created bot first."
                );
            }
        }
        cx.notify();
    }
}
impl Render for BotSettingsPanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mut pane=div().id("bot-settings-panel").size_full().flex().flex_col().gap_2().p_3()
            .child("Bots")
            .child("Name and instructions are saved in Coincide Rust. Bot execution is unavailable; these edits do not activate a provider or change global instructions.")
            .child(div().flex().gap_2()
                .child(Button::new("bots-refresh").label("Refresh list").disabled(self.busy).on_click(cx.listener(|this,_,_,cx|this.start(Action::List,cx))))
                .child(Button::new("bots-new").label("New bot").disabled(self.busy||self.baseline.is_none()).on_click(cx.listener(|this,_,window,cx|this.create(window,cx)))))
            .child(div().text_sm().child(self.notice.clone()));
        let mut body = div()
            .id("bot-settings-content")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_2();
        for bot in self.bots.iter().take(200) {
            let Some(id) = bot["id"].as_str() else {
                continue;
            };
            let id = id.to_owned();
            let selected = id.clone();
            let name = bot["name"]
                .as_str()
                .unwrap_or("Bot")
                .chars()
                .take(200)
                .collect::<String>();
            body = body.child(
                Button::new(SharedString::from(format!("bot-settings-select-{id}")))
                    .label(name)
                    .disabled(self.busy)
                    .on_click(cx.listener(move |this, _, _, cx| this.select(selected.clone(), cx))),
            );
        }
        if self.bots.len() > 200 {
            body = body.child("Showing the first 200 bots.");
        }
        if let Some(editor) = self.selected.as_ref().and_then(|id| self.editors.get(id)) {
            let fields = editor.fields(cx);
            let saved = Fields::from_bot(&editor.bound.bot);
            let dirty = fields != saved;
            pane = pane.child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        Button::new("bots-save")
                            .label("Save bot")
                            .primary()
                            .disabled(self.busy || editor.blocked || !dirty)
                            .on_click(cx.listener(|this, _, _, cx| this.save(cx))),
                    )
                    .child(
                        Button::new("bots-reload-baseline")
                            .label("Reload saved baseline (keep edits)")
                            .disabled(self.busy)
                            .on_click(cx.listener(|this, _, _, cx| this.reload(cx))),
                    ),
            );
            body = body
                .child(if dirty {
                    "Unsaved draft"
                } else {
                    "Matches saved settings"
                })
                .child("Name (1–200 characters)")
                .child(Input::new(&editor.name))
                .child(format!(
                    "Bot instructions ({}/20,000 characters)",
                    fields.persona.chars().count()
                ))
                .child(Textarea::new(&editor.persona).h(px(240.)))
                .child(format!(
                    "Saved source: {}. Other settings are read-only in this editor.",
                    editor.bound.origin
                ))
                .child(format!(
                    "Saved name: {}",
                    saved.name.chars().take(200).collect::<String>()
                ))
                .child(format!(
                    "Saved instructions: {}",
                    saved.persona.chars().take(1500).collect::<String>()
                ))
                .child(format!(
                    "Provider: {} · Model: {} · Access: {} · Interaction: {}",
                    editor.bound.bot["selection"]["provider"]
                        .as_str()
                        .unwrap_or("unspecified"),
                    editor.bound.bot["selection"]["modelID"]
                        .as_str()
                        .unwrap_or("default"),
                    editor.bound.bot["accessMode"]
                        .as_str()
                        .unwrap_or("unspecified"),
                    editor.bound.bot["interactionMode"]
                        .as_str()
                        .unwrap_or("unspecified")
                ))
                .child(format!(
                    "Folder (read-only): {}",
                    editor.bound.bot["folder"]
                        .as_str()
                        .unwrap_or("Home")
                        .chars()
                        .take(500)
                        .collect::<String>()
                ))
                .child(format!(
                    "Avatar (read-only): {}",
                    editor.bound.bot["avatar"]
                        .to_string()
                        .chars()
                        .take(500)
                        .collect::<String>()
                ))
                .child(format!(
                    "Personality (read-only): {}",
                    editor.bound.bot["personality"]
                        .to_string()
                        .chars()
                        .take(1000)
                        .collect::<String>()
                ));
        }
        pane.child(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const ID: &str = "00000000-0000-4000-8000-000000000001";
    fn reply() -> Value {
        json!({"bot":{"id":ID,"name":"Saved","persona":"Instructions","unknown":{"keep":true}},
        "baseline":"a".repeat(64),"origin":"local","instructionsScope":"bot-local","executionConnected":false})
    }
    #[test]
    fn existing_save_sends_only_name_persona_and_captured_baseline() {
        let write = Write {
            key: ID.into(),
            id: Some(ID.into()),
            baseline: "b".repeat(64),
            fields: Fields {
                name: " New name ".into(),
                persona: "Local bot text".into(),
            },
        };
        let mut calls = Vec::new();
        let outcome = run(
            &mut |method, params| {
                calls.push((method.to_owned(), params));
                Ok(reply())
            },
            Action::Write(write),
        )
        .unwrap();
        assert!(matches!(outcome, Outcome::Saved(_, _)));
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, "bots.patch");
        assert_eq!(
            calls[0].1,
            json!({"botId":ID,"baseline":"b".repeat(64),"patch":{"name":"New name","persona":"Local bot text"}})
        );
    }
    #[test]
    fn new_bot_uses_save_without_client_identity() {
        let write = Write {
            key: NEW.into(),
            id: None,
            baseline: "b".repeat(64),
            fields: Fields {
                name: "New".into(),
                persona: String::new(),
            },
        };
        let mut method = String::new();
        let Outcome::Saved(_, bound) = run(
            &mut |m, params| {
                method = m.into();
                assert!(params.get("botId").is_none());
                Ok(reply())
            },
            Action::Write(write),
        )
        .unwrap() else {
            panic!("save")
        };
        assert_eq!(method, "bots.save");
        assert_eq!(bound.bot["id"], ID);
    }
    #[test]
    fn conflict_returns_error_without_retry_or_draft_mutation() {
        let fields = Fields {
            name: "Draft".into(),
            persona: "Keep unsaved".into(),
        };
        let write = Write {
            key: ID.into(),
            id: Some(ID.into()),
            baseline: "b".repeat(64),
            fields: fields.clone(),
        };
        let mut count = 0;
        assert!(
            run(
                &mut |_, _| {
                    count += 1;
                    anyhow::bail!("baseline conflict")
                },
                Action::Write(write.clone())
            )
            .is_err()
        );
        assert_eq!(count, 1);
        assert_eq!(write.fields, fields);
    }
    #[test]
    fn local_validation_bounds_unicode_and_read_checks_identity() {
        assert!(
            Fields {
                name: "  ".into(),
                persona: String::new()
            }
            .patch()
            .is_err()
        );
        assert!(
            Fields {
                name: "Name".into(),
                persona: "🦀".repeat(20_001)
            }
            .patch()
            .is_err()
        );
        assert!(
            Fields {
                name: "Name".into(),
                persona: "🦀".repeat(20_000)
            }
            .patch()
            .is_ok()
        );
        assert!(
            run(
                &mut |_, _| Ok(reply()),
                Action::Read(uuid::Uuid::nil().to_string())
            )
            .is_err()
        );
    }
}

#[cfg(all(test, unix))]
mod fixture_tests {
    use super::*;
    use coincide_core::{api::Engine, store::Store};
    use std::{
        fs,
        sync::{Arc, Mutex},
    };
    struct Fixture(PathBuf);
    use std::path::PathBuf;
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("coincide-bot-panel-test-{}", uuid::Uuid::new_v4()));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn real_api_creates_reads_patches_and_rejects_stale_baseline() {
        let fixture = Fixture::new();
        let store = Store::open(&fixture.0.join("rust/state.sqlite")).unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(store)));
        let mut api = |method: &str, params| call(&engine, method, params);
        let Outcome::List(list) = run(&mut api, Action::List).unwrap() else {
            panic!("list")
        };
        let write = Write {
            key: NEW.into(),
            id: None,
            baseline: list["baseline"].as_str().unwrap().into(),
            fields: Fields {
                name: "Synthetic bot".into(),
                persona: "Synthetic bot-local instructions".into(),
            },
        };
        let Outcome::Saved(_, created) = run(&mut api, Action::Write(write)).unwrap() else {
            panic!("create")
        };
        let id = created.bot["id"].as_str().unwrap().to_owned();
        let Outcome::Read(read) = run(&mut api, Action::Read(id.clone())).unwrap() else {
            panic!("read")
        };
        assert_eq!(read.bot["persona"], "Synthetic bot-local instructions");
        let write = Write {
            key: id.clone(),
            id: Some(id.clone()),
            baseline: read.baseline.clone(),
            fields: Fields {
                name: "Synthetic renamed".into(),
                persona: "Changed local text".into(),
            },
        };
        let stale = write.clone();
        let Outcome::Saved(_, saved) = run(&mut api, Action::Write(write)).unwrap() else {
            panic!("patch")
        };
        assert_eq!(saved.bot["id"], id);
        assert_eq!(saved.bot["name"], "Synthetic renamed");
        assert!(run(&mut api, Action::Write(stale)).is_err());
        assert!(
            fs::read_dir(&fixture.0)
                .unwrap()
                .all(|entry| entry.unwrap().file_name() == "rust")
        );
    }
}
