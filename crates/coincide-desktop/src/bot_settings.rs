//! Parent: create/render Entity<BotSettingsPanel>; subscribe to BotSettingsEvent
//! for saved IDs if needed. Like Swift's BotEditor, this editor persists a bot's
//! look, name, personality, instructions (bot.persona) and folder; nothing is
//! saved until Save. The agent, model and modes stay as saved.
use crate::bot_avatar;
use crate::worker_owner::{Admission, ShutdownStatus as WorkerOwnerStatus, WorkerOwner};
use anyhow::{Context as _, Result, ensure};
use coincide_core::{
    api::{SharedEngine, call},
    bot_artwork::{Character, Tint},
    bot_personality::{self, CUSTOM_LIMIT, PRESETS},
};
use gpui_kit::base::{Disableable, Selectable};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::{
    assets::IconName,
    component::{
        ActiveTheme,
        button::*,
        input::{Input, InputEvent, InputState, Textarea, TextareaState},
        menu::{DropdownMenu, PopupMenuItem},
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
/// A bot's look: a character in one of the tints (Swift's `BotAvatar`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Look {
    shape: Character,
    tint: Tint,
}
impl Look {
    /// A character in its own color.
    fn character(shape: Character) -> Self {
        Self {
            shape,
            tint: shape.default_tint(),
        }
    }
    /// Anything this version cannot read reads as the defaults, as in Swift.
    fn from_bot(bot: &Value) -> Self {
        let shape = bot["avatar"]["shape"]
            .as_str()
            .and_then(Character::from_raw)
            .unwrap_or(Character::Alien);
        let tint = bot["avatar"]["tint"]
            .as_str()
            .and_then(Tint::from_raw)
            .unwrap_or(shape.default_tint());
        Self { shape, tint }
    }
    fn value(self) -> Value {
        json!({"shape":self.shape.raw(),"tint":self.tint.raw()})
    }
}
/// How the bot talks: a preset, or the user's description (Swift's `BotPersonality`).
/// The description is kept beside a preset, so switching back to Custom finds it.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Personality {
    preset: Option<String>,
    custom: String,
}
impl Personality {
    fn from_bot(bot: &Value) -> Option<Self> {
        let value = &bot["personality"];
        if !value.is_object() {
            return None;
        }
        let preset = value["preset"]
            .as_str()
            .filter(|id| !id.is_empty())
            .map(str::to_owned);
        let custom = bot_personality::custom_text(value["custom"].as_str().unwrap_or(""));
        (preset.is_some() || !custom.is_empty()).then_some(Self { preset, custom })
    }
    fn value(&self) -> Value {
        match &self.preset {
            Some(preset) => json!({"preset":preset,"custom":self.custom}),
            None => json!({"custom":self.custom}),
        }
    }
}
/// What the personality chips choose between. A preset this version doesn't
/// have (a newer version's) stays chosen, but no chip shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Choice {
    None,
    Preset(String),
    Custom,
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Fields {
    name: String,
    persona: String,
    look: Look,
    personality: Option<Personality>,
    /// None for the home folder.
    folder: Option<String>,
}
impl Fields {
    fn from_bot(bot: &Value) -> Self {
        Self {
            name: bot["name"].as_str().unwrap_or("").into(),
            persona: bot["persona"].as_str().unwrap_or("").into(),
            look: Look::from_bot(bot),
            personality: Personality::from_bot(bot),
            folder: bot["folder"]
                .as_str()
                .filter(|folder| !folder.is_empty())
                .map(str::to_owned),
        }
    }
    /// A fresh bot as Swift's `BotEditor.newBot` makes it: a character none of the
    /// bots is yet when one is left, with its color, name and personality.
    fn new_bot(used: &[Character], pick: usize) -> Self {
        let free = Character::ALL
            .into_iter()
            .filter(|character| !used.contains(character))
            .collect::<Vec<_>>();
        let choices = if free.is_empty() {
            Character::ALL.to_vec()
        } else {
            free
        };
        let character = choices[pick % choices.len()];
        Self {
            name: character.default_name().into(),
            persona: String::new(),
            look: Look::character(character),
            personality: character.default_personality().map(|preset| Personality {
                preset: Some(preset.into()),
                custom: String::new(),
            }),
            folder: None,
        }
    }
    /// Name and instructions always; look, personality and folder only when they
    /// differ from `saved` (or for a new bot), so fields this version cannot
    /// read stay exactly as saved.
    fn patch(&self, saved: Option<&Fields>) -> Result<Value> {
        let name = self.name.trim();
        ensure!(
            !name.is_empty() && name.chars().count() <= 200,
            "Name must contain 1–200 characters"
        );
        ensure!(
            self.persona.chars().count() <= 20_000,
            "Bot instructions must fit within 20,000 characters"
        );
        ensure!(
            self.personality
                .as_ref()
                .is_none_or(|personality| personality.custom.chars().count() <= CUSTOM_LIMIT),
            "A custom personality must fit within 4,000 characters"
        );
        let mut patch = json!({"name":name,"persona":self.persona});
        if saved.is_none_or(|saved| saved.look != self.look) {
            patch["avatar"] = self.look.value();
        }
        if saved.is_none_or(|saved| saved.personality != self.personality) {
            patch["personality"] = self
                .personality
                .as_ref()
                .map_or(Value::Null, Personality::value);
        }
        if saved.is_none_or(|saved| saved.folder != self.folder) {
            patch["folder"] = json!(self.folder);
        }
        Ok(patch)
    }
}
#[derive(Clone)]
struct Write {
    key: String,
    id: Option<String>,
    baseline: String,
    fields: Fields,
    /// The saved values the draft started from; None for a new bot.
    saved: Option<Fields>,
}
impl Write {
    fn params(&self) -> Result<Value> {
        let mut params =
            json!({"baseline":self.baseline,"patch":self.fields.patch(self.saved.as_ref())?});
        if let Some(id) = &self.id {
            params["botId"] = json!(id);
        }
        Ok(params)
    }
}
/// The user's home folder, where a bot works unless it has a folder of its own.
fn home_folder() -> Option<std::path::PathBuf> {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(std::path::PathBuf::from)
        .filter(|home| home.is_absolute())
}
/// The folder as shown: the home folder and paths inside it start with `~`.
fn folder_label(folder: Option<&str>, home: Option<&std::path::Path>) -> String {
    let Some(folder) = folder else {
        return "~".into();
    };
    if let Some(home) = home
        && let Ok(inside) = std::path::Path::new(folder).strip_prefix(home)
    {
        let inside = inside.to_string_lossy();
        return if inside.is_empty() {
            "~".into()
        } else {
            format!("~{}{inside}", std::path::MAIN_SEPARATOR)
        };
    }
    folder.into()
}
/// The folder a picked directory saves as: None for the home folder.
fn chosen_folder(path: &std::path::Path, home: Option<&std::path::Path>) -> Option<String> {
    let same = |a: &std::path::Path, b: &std::path::Path| {
        a == b
            || a.canonicalize()
                .ok()
                .zip(b.canonicalize().ok())
                .is_some_and(|(a, b)| a == b)
    };
    if home.is_some_and(|home| same(path, home)) {
        None
    } else {
        Some(path.to_string_lossy().into_owned())
    }
}
/// The lucide icon each personality chip shows, after Swift's SF Symbols.
fn personality_icon(choice: &Choice) -> IconName {
    match choice {
        Choice::None => IconName::CircleSlash,
        Choice::Custom => IconName::PencilLine,
        Choice::Preset(id) => match id.as_str() {
            "cheerful" => IconName::Sun,
            "calm" => IconName::Leaf,
            "witty" => IconName::Drama,
            "mentor" => IconName::GraduationCap,
            "coach" => IconName::Footprints,
            "candid" => IconName::Crosshair,
            "curious" => IconName::Binoculars,
            "professional" => IconName::Briefcase,
            "gentle" => IconName::Heart,
            "creative" => IconName::Palette,
            _ => IconName::CircleSlash,
        },
    }
}
const NO_PERSONALITY: &str = "No personality of its own: it talks as its instructions say.";
/// The name a new character brings: its own, while the bot still has the
/// previous character's name or none. A name the user wrote stays.
fn suggested_name(current: &str, previous: Character, next: Character) -> Option<&'static str> {
    let current = current.trim();
    (current.is_empty() || current == previous.default_name()).then_some(next.default_name())
}
/// The personality a new character brings: its own, while the user hasn't
/// picked one and the bot has none or the previous character's.
fn suggested_personality(
    current: &Choice,
    picked: bool,
    previous: Character,
    next: Character,
) -> Option<Choice> {
    let suggests = match current {
        Choice::None => true,
        Choice::Preset(id) => previous.default_personality() == Some(id.as_str()),
        Choice::Custom => false,
    };
    (!picked && suggests).then(|| {
        next.default_personality()
            .map_or(Choice::None, |id| Choice::Preset(id.into()))
    })
}
#[derive(Clone)]
struct Conversation {
    bot_id: String,
    baseline: String,
}
impl Conversation {
    fn from_saved(bound: &Bound) -> Result<Self> {
        let bot_id = bound.bot["id"]
            .as_str()
            .context("Save this bot before creating a conversation")?;
        uuid::Uuid::parse_str(bot_id)?;
        Ok(Self {
            bot_id: bot_id.into(),
            baseline: bound.baseline.clone(),
        })
    }
    fn params(&self) -> Value {
        json!({"botId":self.bot_id,"baseline":self.baseline})
    }
}
enum Action {
    List,
    Read(String),
    Write(Write),
    Conversation(Conversation),
}
enum Outcome {
    List(Value),
    Read(Bound),
    Saved(Write, Bound),
    ConversationCreated(String),
}
fn run_admitted(
    api: &mut impl FnMut(&str, Value) -> Result<Value>,
    action: Action,
    admission: &Admission,
) -> Result<Outcome> {
    run(
        &mut |method, params| {
            ensure!(admission.allowed(), "Workflow is shutting down");
            api(method, params)
        },
        action,
    )
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
        Action::Conversation(request) => {
            let reply = api("bots.conversations.create", request.params())?;
            ensure!(
                reply["created"] == true
                    && reply["executionStarted"] == false
                    && reply["instructionsScope"] == "bot-local",
                "Conversation creation outcome unknown; refresh conversations before retrying"
            );
            ensure!(
                reply["botId"]
                    .as_str()
                    .is_some_and(|id| id.eq_ignore_ascii_case(&request.bot_id)),
                "Conversation was created for another bot; refresh before retrying"
            );
            let thread = reply["threadId"]
                .as_str()
                .context("Created conversation has no thread ID; refresh before retrying")?;
            uuid::Uuid::parse_str(thread)?;
            Ok(Outcome::ConversationCreated(thread.into()))
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
    /// The custom personality's description.
    custom: Entity<TextareaState>,
    look: Look,
    choice: Choice,
    /// Whether the user picked a personality. Until then a new character brings
    /// its own, as it brings its name (Swift's `BotPersonalitySection.suggest`).
    picked_personality: bool,
    folder: Option<String>,
    blocked: bool,
    _subscriptions: Vec<Subscription>,
}
impl Editor {
    /// An editor over `bound`, starting from `draft` when given (a new bot's
    /// suggested look, name and personality), else from the saved values.
    fn new(
        bound: Bound,
        draft: Option<Fields>,
        window: &mut Window,
        cx: &mut Context<BotSettingsPanel>,
    ) -> Self {
        let fields = draft.unwrap_or_else(|| Fields::from_bot(&bound.bot));
        let name = cx.new(|cx| InputState::new(window, cx).placeholder("Name"));
        name.update(cx, |input, cx| input.set_value(fields.name, window, cx));
        let persona = cx.new(|cx| {
            TextareaState::new(window, cx)
                .placeholder("What the bot does and how it works")
                .submit_on_enter(false)
        });
        persona.update(cx, |input, cx| input.set_value(fields.persona, window, cx));
        let custom = cx.new(|cx| {
            TextareaState::new(window, cx)
                .placeholder("Describe the personality…")
                .submit_on_enter(false)
        });
        let choice = match &fields.personality {
            None => Choice::None,
            Some(Personality {
                preset: Some(id), ..
            }) => Choice::Preset(id.clone()),
            Some(_) => Choice::Custom,
        };
        let text = fields
            .personality
            .as_ref()
            .map(|personality| personality.custom.clone())
            .unwrap_or_default();
        custom.update(cx, |input, cx| input.set_value(text, window, cx));
        let mut subscriptions = vec![cx.subscribe(&name, |_, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        })];
        for input in [&persona, &custom] {
            subscriptions.push(cx.subscribe(input, |_, _, event, cx| {
                if matches!(event, InputEvent::Change) {
                    cx.notify();
                }
            }));
        }
        Self {
            bound,
            name,
            persona,
            custom,
            look: fields.look,
            choice,
            picked_personality: false,
            folder: fields.folder,
            blocked: false,
            _subscriptions: subscriptions,
        }
    }
    fn personality(&self, cx: &App) -> Option<Personality> {
        let custom = self.custom.read(cx).value().trim().to_owned();
        match &self.choice {
            Choice::None => None,
            Choice::Preset(id) => Some(Personality {
                preset: Some(id.clone()),
                custom,
            }),
            // Custom without a description is no personality.
            Choice::Custom => (!custom.is_empty()).then_some(Personality {
                preset: None,
                custom,
            }),
        }
    }
    fn fields(&self, cx: &App) -> Fields {
        Fields {
            name: self.name.read(cx).value().to_string(),
            persona: self.persona.read(cx).value().to_string(),
            look: self.look,
            personality: self.personality(cx),
            folder: self.folder.clone(),
        }
    }
    fn is_new(&self) -> bool {
        self.bound.bot["id"].as_str().is_none()
    }
    /// A character comes in its own color, and brings its name while the bot still
    /// has the previous character's (or none); a name the user wrote stays. Its
    /// personality comes along the same way, unless the user picked one.
    fn pick_shape(&mut self, shape: Character, window: &mut Window, cx: &mut App) {
        let previous = self.look.shape;
        if shape == previous {
            return;
        }
        let name = self.name.read(cx).value().to_string();
        if let Some(name) = suggested_name(&name, previous, shape) {
            self.name
                .update(cx, |input, cx| input.set_value(name, window, cx));
        }
        if let Some(choice) =
            suggested_personality(&self.choice, self.picked_personality, previous, shape)
        {
            self.choice = choice;
        }
        self.look = Look::character(shape);
    }
    fn pick_personality(&mut self, choice: Choice, window: &mut Window, cx: &mut App) {
        self.picked_personality = true;
        let custom = choice == Choice::Custom;
        self.choice = choice;
        if custom {
            self.custom.update(cx, |input, cx| input.focus(window, cx));
        }
    }
    /// Replaces the description with a preset's text, for the user to make their own.
    fn start_from(&mut self, preset: &str, window: &mut Window, cx: &mut App) {
        let Some(preset) = bot_personality::preset(preset) else {
            return;
        };
        self.picked_personality = true;
        self.choice = Choice::Custom;
        self.custom.update(cx, |input, cx| {
            input.set_value(preset.prompt, window, cx);
            input.focus(window, cx);
        });
    }
}
pub enum BotSettingsEvent {
    Saved { bot_id: String },
    ConversationCreated { thread_id: String },
}
pub struct BotSettingsPanel {
    workers: WorkerOwner,
    engine: SharedEngine,
    bots: Vec<Value>,
    baseline: Option<String>,
    selected: Option<String>,
    editors: HashMap<String, Editor>,
    generation: u64,
    busy: bool,
    pending_key: Option<String>,
    pending_write: bool,
    pending_conversation: bool,
    choosing_folder: bool,
    notice: String,
    tx: mpsc::Sender<(u64, Result<Outcome>)>,
    rx: mpsc::Receiver<(u64, Result<Outcome>)>,
    _poll: Task<()>,
}
impl EventEmitter<BotSettingsEvent> for BotSettingsPanel {}
impl BotSettingsPanel {
    pub fn request_shutdown(&mut self) {
        if self.workers.close() {
            self.generation = self.generation.wrapping_add(1);
        }
        self.pending_key = None;
        self.pending_write = false;
        self.pending_conversation = false;
        self.discard_shutdown_results();
    }
    fn discard_shutdown_results(&mut self) {
        for result in self.rx.try_iter() {
            drop(result);
        }
    }
    pub fn shutdown_status(&mut self) -> WorkerOwnerStatus {
        if self.workers.closed() {
            self.discard_shutdown_results();
        }
        self.workers.status()
    }
    pub fn new(engine: SharedEngine, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (tx, rx) = mpsc::channel();
        let owner_window = window.window_handle();
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
                if crate::main_window_poll::update_visible_or_owner(
                    owner_window,
                    &this,
                    cx,
                    |this, window, cx| this.poll(window, cx),
                )
                .is_err()
                {
                    break;
                }
            }
        });
        let mut panel = Self {
            workers: WorkerOwner::default(),
            engine,
            bots: Vec::new(),
            baseline: None,
            selected: None,
            editors: HashMap::new(),
            generation: 0,
            busy: false,
            pending_key: None,
            pending_write: false,
            pending_conversation: false,
            choosing_folder: false,
            notice: String::new(),
            tx,
            rx,
            _poll: poll,
        };
        panel.start(Action::List, cx);
        panel
    }
    fn start(&mut self, action: Action, cx: &mut Context<Self>) {
        if self.busy || !self.workers.can_start() {
            return;
        }
        self.busy = true;
        self.pending_write = matches!(&action, Action::Write(_));
        self.pending_conversation = matches!(&action, Action::Conversation(_));
        self.pending_key = match &action {
            Action::Write(w) => Some(w.key.clone()),
            Action::Read(id) => Some(id.clone()),
            Action::List => None,
            Action::Conversation(request) => Some(request.bot_id.clone()),
        };
        self.notice = if self.pending_conversation {
            "Creating an empty conversation from saved settings… Editor drafts are retained; no message is sent."
        } else if self.pending_write {
            "Saving bot… You can keep editing; edits made now will remain unsaved."
        } else {
            "Loading saved bot data… Drafts are retained."
        }
        .into();
        let (engine, tx, generation) = (self.engine.clone(), self.tx.clone(), self.generation);
        if !self.workers.spawn(move |admission| {
            let result = run_admitted(
                &mut |method, params| call(&engine, method, params),
                action,
                &admission,
            );
            let _ = tx.send((generation, result));
        }) {
            self.busy = false;
            self.notice = "Background worker could not start.".into();
        }
        cx.notify();
    }
    pub(super) fn select(&mut self, id: String, cx: &mut Context<Self>) {
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
    pub(super) fn create(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(baseline) = self.baseline.clone() else {
            return;
        };
        self.generation = self.generation.wrapping_add(1);
        self.selected = Some(NEW.into());
        if !self.editors.contains_key(NEW) {
            let used = self
                .bots
                .iter()
                .map(|bot| Look::from_bot(bot).shape)
                .collect::<Vec<_>>();
            let pick = usize::from(uuid::Uuid::new_v4().as_bytes()[0]);
            let editor = Editor::new(
                Bound {
                    bot: json!({"name":"","persona":""}),
                    baseline,
                    origin: "empty".into(),
                },
                Some(Fields::new_bot(&used, pick)),
                window,
                cx,
            );
            self.editors.insert(NEW.into(), editor);
        }
        self.notice =
            "New bot draft. Save creates one stable server ID. Creating a conversation is a separate action.".into();
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
        let saved = (!editor.is_new()).then(|| Fields::from_bot(&editor.bound.bot));
        if let Err(error) = fields.patch(saved.as_ref()) {
            self.notice = error.to_string();
            cx.notify();
            return;
        }
        let write = Write {
            key,
            id: editor.bound.bot["id"].as_str().map(str::to_owned),
            baseline: editor.bound.baseline.clone(),
            fields,
            saved,
        };
        self.start(Action::Write(write), cx);
    }
    /// Swift's Cancel: closes the editor without saving, dropping its draft.
    fn cancel(&mut self, cx: &mut Context<Self>) {
        let Some(key) = self.selected.take() else {
            return;
        };
        if self.pending_key.as_deref() != Some(key.as_str()) {
            self.editors.remove(&key);
        }
        self.generation = self.generation.wrapping_add(1);
        self.notice = "Closed without saving.".into();
        cx.notify();
    }
    fn editor_mut(&mut self) -> Option<&mut Editor> {
        let key = self.selected.as_ref()?;
        self.editors.get_mut(key).filter(|editor| !editor.blocked)
    }
    fn choose_folder(&mut self, cx: &mut Context<Self>) {
        if self.choosing_folder || !self.workers.begin_picker() {
            return;
        }
        let Some(key) = self.selected.clone() else {
            self.workers.finish_picker();
            return;
        };
        self.choosing_folder = true;
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Choose".into()),
        });
        cx.spawn(async move |this, cx| {
            let result: Result<_> = async { picker.await? }.await;
            let _ = this.update(cx, |this, cx| {
                this.choosing_folder = false;
                if !this.workers.finish_picker() {
                    return;
                }
                match result {
                    Ok(Some(paths)) if paths.len() == 1 => {
                        let home = home_folder();
                        if let Some(editor) = this.editors.get_mut(&key) {
                            editor.folder = chosen_folder(&paths[0], home.as_deref());
                        }
                    }
                    Ok(_) => {}
                    Err(error) => this.notice = format!("Folder selection failed: {error}"),
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    fn key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let modifiers = event.keystroke.modifiers;
        let primary = if cfg!(target_os = "macos") {
            modifiers.platform && !modifiers.control
        } else {
            modifiers.control && !modifiers.platform
        };
        let plain = !modifiers.alt && !modifiers.shift && !modifiers.function;
        match event.keystroke.key.as_str() {
            // Swift's Save key equivalent: Command-Return (Control-Enter elsewhere).
            "enter" if primary && plain => self.save(cx),
            "escape" if !primary && !modifiers.control && plain => self.cancel(cx),
            _ => return,
        }
        window.prevent_default();
        cx.stop_propagation();
    }
    fn new_conversation(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some(editor) = self
            .selected
            .as_ref()
            .and_then(|id| self.editors.get(id))
            .filter(|editor| !editor.blocked)
        else {
            return;
        };
        match Conversation::from_saved(&editor.bound) {
            Ok(request) => self.start(Action::Conversation(request), cx),
            Err(error) => {
                self.notice = error.to_string();
                cx.notify();
            }
        }
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
        self.workers.poll();
        if self.workers.closed() {
            self.discard_shutdown_results();
            return;
        }
        let Ok((generation, result)) = self.rx.try_recv() else {
            return;
        };
        self.busy = false;
        let key = self.pending_key.take();
        let was_write = std::mem::take(&mut self.pending_write);
        let was_conversation = std::mem::take(&mut self.pending_conversation);
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
                    self.editors
                        .insert(id, Editor::new(bound, None, window, cx));
                    self.notice = "Edit this bot, then Save.".into();
                }
            }
            Ok(Outcome::Read(_)) => {
                self.notice = "Selection changed; stale read discarded. Drafts retained.".into();
            }
            Ok(Outcome::ConversationCreated(thread_id)) => {
                // Durable creation is independent of selection generation. Keep all
                // input entities/baselines untouched; parent opens/focuses this ID.
                self.notice = "Created an empty conversation from saved bot settings. No message was sent. Editor drafts are retained; later bot edits apply to later new conversations.".into();
                cx.emit(BotSettingsEvent::ConversationCreated { thread_id });
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
                        editor.look = saved.look;
                        editor.folder = saved.folder;
                        if let Some(personality) = saved.personality {
                            editor.custom.update(cx, |input, cx| {
                                input.set_value(personality.custom, window, cx)
                            });
                        }
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
                self.notice="Saved bot settings. Any edits typed during Save remain in the draft. Existing conversation instruction snapshots stay unchanged.".into();
                cx.emit(BotSettingsEvent::Saved { bot_id: id });
            }
            Err(error) => {
                if was_write && let Some(editor) = key.and_then(|key| self.editors.get_mut(&key)) {
                    editor.blocked = true;
                }
                self.notice = if was_conversation {
                    format!(
                        "{error}. Bot editor drafts retained. No fallback or automatic retry. Reload saved baseline for conflicts; refresh conversations before retrying an uncertain creation."
                    )
                } else {
                    format!(
                        "{error}. Draft retained. Reload the saved baseline before retrying; after uncertain creation, refresh the list and check for a created bot first."
                    )
                };
            }
        }
        cx.notify();
    }
}
impl Drop for BotSettingsPanel {
    fn drop(&mut self) {
        self.request_shutdown();
    }
}
/// A section label in the editor, as Swift's: small, medium weight, secondary.
fn section_label(text: &'static str, cx: &App) -> Div {
    div()
        .mt_3()
        .text_xs()
        .font_weight(FontWeight::MEDIUM)
        .text_color(cx.theme().muted_foreground)
        .child(text)
}
/// A hint under a section, as Swift's: small and secondary.
fn hint(text: impl Into<SharedString>, cx: &App) -> Div {
    div()
        .text_xs()
        .text_color(cx.theme().muted_foreground)
        .child(text.into())
}
impl BotSettingsPanel {
    /// Swift BotEditor's content, top down: who it is and how it looks, its
    /// personality, instructions, agent and folder, then Cancel and Save.
    fn editor_view(&self, editor: &Editor, cx: &mut Context<Self>) -> AnyElement {
        let fields = editor.fields(cx);
        let saved = Fields::from_bot(&editor.bound.bot);
        let new = editor.is_new();
        let dirty = new || fields != saved;
        let locked = self.busy || editor.blocked;
        let look = editor.look;
        let theme = cx.theme();
        let (accent, raised) = (theme.ring, theme.secondary);
        let shapes = Character::ALL.into_iter().map(|shape| {
            // Each character shows in its own color, the chosen one in the bot's.
            let chosen = shape == look.shape;
            let tint = if chosen {
                look.tint
            } else {
                shape.default_tint()
            };
            Button::new(SharedString::from(format!(
                "bot-look-shape-{}",
                shape.raw()
            )))
            .ghost()
            .selected(chosen)
            .accessibility_label(shape.default_name())
            .tooltip(shape.default_name())
            .disabled(locked)
            .w(px(40.))
            .h(px(40.))
            .p_0()
            .rounded(px(9.))
            .when(chosen, |button| {
                button.bg(raised).border_2().border_color(accent)
            })
            .child(bot_avatar::avatar(shape, tint, 26.))
            .on_click(cx.listener(move |this, _, window, cx| {
                if let Some(editor) = this.editor_mut() {
                    editor.pick_shape(shape, window, cx);
                }
                cx.notify();
            }))
        });
        let tints = Tint::ALL.into_iter().map(|tint| {
            let chosen = tint == look.tint;
            Button::new(SharedString::from(format!("bot-look-tint-{}", tint.raw())))
                .ghost()
                .selected(chosen)
                .accessibility_label(tint.name())
                .tooltip(tint.name())
                .disabled(locked)
                .w(px(24.))
                .h(px(24.))
                .p_0()
                .rounded_full()
                .when(chosen, |button| button.border_2().border_color(accent))
                .child(
                    div()
                        .size(px(if chosen { 15. } else { 18. }))
                        .rounded_full()
                        .bg(rgb(tint.rgb())),
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    if let Some(editor) = this.editor_mut() {
                        editor.look.tint = tint;
                    }
                    cx.notify();
                }))
        });
        let choices = std::iter::once((Choice::None, "None", NO_PERSONALITY))
            .chain(PRESETS.iter().map(|preset| {
                (
                    Choice::Preset(preset.id.into()),
                    preset.name,
                    preset.summary,
                )
            }))
            .chain(std::iter::once((
                Choice::Custom,
                "Custom",
                "Describe a personality in your own words.",
            )));
        let chips = choices.enumerate().map(|(index, (choice, name, summary))| {
            let chosen = choice == editor.choice;
            Button::new(SharedString::from(format!("bot-personality-{index}")))
                .outline()
                .compact()
                .selected(chosen)
                .icon(personality_icon(&choice))
                .label(name)
                .tooltip(summary)
                .disabled(locked)
                .h(px(26.))
                .rounded(px(8.))
                .when(chosen, |button| {
                    button.bg(raised).border_2().border_color(accent)
                })
                .on_click(cx.listener(move |this, _, window, cx| {
                    if let Some(editor) = this.editor_mut() {
                        editor.pick_personality(choice.clone(), window, cx);
                    }
                    cx.notify();
                }))
        });
        let preset = match &editor.choice {
            Choice::Preset(id) => bot_personality::preset(id),
            _ => None,
        };
        let summary = match &editor.choice {
            Choice::None => NO_PERSONALITY,
            Choice::Preset(_) => preset.map_or("", |preset| preset.summary),
            Choice::Custom => "",
        };
        let custom_count = editor.custom.read(cx).value().trim().chars().count();
        let parent = cx.entity().downgrade();
        let start_menu = Button::new("bot-personality-start")
            .icon(IconName::ListPlus)
            .label("Start from Preset")
            .accessibility_label("Start from Preset")
            .compact()
            .disabled(locked)
            .dropdown_caret(true)
            .dropdown_menu(move |mut menu, _, _| {
                for preset in &PRESETS {
                    let parent = parent.clone();
                    let (name, summary, id) = (preset.name, preset.summary, preset.id);
                    menu = menu.item(
                        PopupMenuItem::element(move |_, _| {
                            div()
                                .flex()
                                .flex_col()
                                .child(name)
                                .child(div().text_xs().opacity(0.7).child(summary))
                        })
                        .icon(personality_icon(&Choice::Preset(id.into())))
                        .on_click(move |_, window, cx| {
                            let _ = parent.update(cx, |this, cx| {
                                if let Some(editor) = this.editor_mut() {
                                    editor.start_from(id, window, cx);
                                }
                                cx.notify();
                            });
                        }),
                    );
                }
                menu
            });
        let home = home_folder();
        let folder = folder_label(editor.folder.as_deref(), home.as_deref());
        let folder_path = editor
            .folder
            .clone()
            .or_else(|| {
                home.as_ref()
                    .map(|home| home.to_string_lossy().into_owned())
            })
            .unwrap_or_default();
        let selection = &editor.bound.bot["selection"];
        let agent = [
            selection["provider"]
                .as_str()
                .map(|provider| match provider {
                    "codex" => "Codex".to_owned(),
                    "claude" => "Claude".to_owned(),
                    other => other.to_owned(),
                }),
            selection["modelID"].as_str().map(str::to_owned),
            Some(
                match editor.bound.bot["accessMode"].as_str() {
                    Some("fullAccess") => "Full access",
                    _ => "Ask before changes",
                }
                .to_owned(),
            ),
            Some(
                match editor.bound.bot["interactionMode"].as_str() {
                    Some("plan") => "Plan",
                    _ => "Build",
                }
                .to_owned(),
            ),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" · ");
        div()
            .id("bot-editor")
            .flex()
            .flex_col()
            .gap(px(7.))
            .max_w(px(520.))
            .p_1()
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                this.key(event, window, cx)
            }))
            .child(
                div()
                    .text_lg()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(if new { "New Bot" } else { "Edit Bot" }),
            )
            .child(hint(
                "A bot is an ongoing conversation with its own personality and job. It runs on your agents like any thread.",
                cx,
            ))
            .child(
                div()
                    .mt_3()
                    .flex()
                    .items_end()
                    .gap(px(14.))
                    .child(bot_avatar::avatar(look.shape, look.tint, 56.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(6.))
                            .child(section_label("Name", cx).mt_0())
                            .child(Input::new(&editor.name)),
                    ),
            )
            .child(section_label("Look", cx))
            .child(div().flex().flex_wrap().gap(px(6.)).children(shapes))
            .child(div().mt_1().flex().flex_wrap().gap(px(10.)).children(tints))
            .child(section_label("Personality", cx))
            .child(div().flex().flex_wrap().gap(px(6.)).children(chips))
            .when(!summary.is_empty(), |view| view.child(hint(summary, cx).mt_1()))
            .when_some(preset, |view, preset| {
                view.child(
                    div()
                        .flex()
                        .items_baseline()
                        .gap_2()
                        .child(
                            div()
                                .flex_none()
                                .text_xs()
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(cx.theme().muted_foreground)
                                .child("Preview"),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .font_family(crate::settings::reply_font())
                                .child(preset.greeting),
                        ),
                )
            })
            .when(editor.choice == Choice::Custom, |view| {
                view.child(Textarea::new(&editor.custom).h(px(84.))).child(
                    div()
                        .flex()
                        .items_center()
                        .justify_between()
                        .gap_2()
                        .child(start_menu)
                        .child(hint(
                            if custom_count > CUSTOM_LIMIT {
                                format!("Up to 4,000 characters. This one has {custom_count}.")
                            } else {
                                "Up to 4,000 characters.".to_owned()
                            },
                            cx,
                        )),
                )
            })
            .child(hint(
                "How the bot talks and behaves, apart from its job. A change reaches its conversations with their next message.",
                cx,
            ))
            .child(section_label("Instructions", cx))
            .child(Textarea::new(&editor.persona).h(px(120.)))
            .child(hint(
                format!(
                    "What the bot does and how it works. Its agent gets this and the personality at the start of each session; neither shows in the conversation. ({}/20,000 characters)",
                    fields.persona.chars().count()
                ),
                cx,
            ))
            .child(section_label("Agent", cx))
            .child(div().text_sm().child(agent))
            .child(hint(
                "New conversations start on this agent and model, asking before changes. This editor doesn't change them yet.",
                cx,
            ))
            .child(section_label("Folder", cx))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .id("bot-folder-path")
                            .flex_1()
                            .min_w_0()
                            .text_sm()
                            .truncate()
                            .tooltip(move |window, cx| {
                                gpui_kit::component::tooltip::Tooltip::new(folder_path.clone())
                                    .build(window, cx)
                            })
                            .child(folder),
                    )
                    .when(editor.folder.is_some(), |row| {
                        row.child(
                            Button::new("bot-folder-home")
                                .label("Use Home Folder")
                                .ghost()
                                .disabled(locked)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    if let Some(editor) = this.editor_mut() {
                                        editor.folder = None;
                                    }
                                    cx.notify();
                                })),
                        )
                    })
                    .child(
                        Button::new("bot-folder-choose")
                            .label("Choose…")
                            .disabled(locked || self.choosing_folder)
                            .on_click(cx.listener(|this, _, _, cx| this.choose_folder(cx))),
                    ),
            )
            .child(hint(
                "Its conversations run here and can work with everything inside.",
                cx,
            ))
            .child(
                div()
                    .mt_4()
                    .flex()
                    .justify_end()
                    .gap_2()
                    .child(
                        Button::new("bots-cancel")
                            .label("Cancel")
                            .on_click(cx.listener(|this, _, _, cx| this.cancel(cx))),
                    )
                    .child(
                        Button::new("bots-save")
                            .label(if new { "Create Bot" } else { "Save" })
                            .primary()
                            .disabled(locked || !dirty || fields.name.trim().is_empty())
                            .on_click(cx.listener(|this, _, _, cx| this.save(cx))),
                    ),
            )
            .child(hint(
                format!(
                    "{} Saved source: {}.",
                    if dirty { "Unsaved draft." } else { "Matches saved settings." },
                    editor.bound.origin
                ),
                cx,
            ))
            .into_any_element()
    }
}
impl Render for BotSettingsPanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mut pane=div().id("bot-settings-panel").size_full().flex().flex_col().gap_2().p_3()
            .child("Bots")
            .child("Save edits this bot locally. New conversation uses saved settings and never sends a message. Global instructions and existing conversation snapshots stay unchanged.")
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
            let look = Look::from_bot(bot);
            body = body.child(
                Button::new(SharedString::from(format!("bot-settings-select-{id}")))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(bot_avatar::avatar(look.shape, look.tint, 20.))
                            .child(name.clone()),
                    )
                    .accessibility_label(name)
                    .selected(self.selected.as_deref() == Some(id.as_str()))
                    .disabled(self.busy)
                    .on_click(cx.listener(move |this, _, _, cx| this.select(selected.clone(), cx))),
            );
        }
        if self.bots.len() > 200 {
            body = body.child("Showing the first 200 bots.");
        }
        if let Some(editor) = self.selected.as_ref().and_then(|id| self.editors.get(id)) {
            pane = pane.child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        Button::new("bots-reload-baseline")
                            .label("Reload saved baseline (keep edits)")
                            .disabled(self.busy)
                            .on_click(cx.listener(|this, _, _, cx| this.reload(cx))),
                    )
                    .child(
                        Button::new("bots-new-conversation")
                            .label("New conversation (saved settings)")
                            .disabled(
                                self.busy
                                    || editor.blocked
                                    || editor.bound.bot["id"].as_str().is_none(),
                            )
                            .on_click(cx.listener(|this, _, _, cx| this.new_conversation(cx))),
                    ),
            );
            let saved = Fields::from_bot(&editor.bound.bot);
            body = body
                .child("New conversations use the saved settings shown below. Unsaved editor text stays here until you Save it.")
                .child(self.editor_view(editor, cx))
                .child(format!(
                    "Saved name: {}",
                    saved.name.chars().take(200).collect::<String>()
                ))
                .child(format!(
                    "Saved instructions: {}",
                    saved.persona.chars().take(1500).collect::<String>()
                ));
        }
        pane.child(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const ID: &str = "00000000-0000-4000-8000-000000000001";
    /// A draft that changes only text: the default look, no personality, home folder.
    pub(super) fn text_fields(name: String, persona: String) -> Fields {
        Fields {
            name,
            persona,
            ..Fields::from_bot(&json!({}))
        }
    }
    #[::core::prelude::v1::test]
    fn saved_look_personality_and_folder_read_leniently_like_swift() {
        let fields = Fields::from_bot(&json!({"name":"Old","persona":"",
            "avatar":{"shape":"cloud","tint":"future-tint"},
            "personality":{"preset":"","custom":"  Be brief.  "},"folder":""}));
        // Earlier body shapes read as their closest character, in its own color.
        assert_eq!(fields.look, Look::character(Character::Teddy));
        assert_eq!(
            fields.personality,
            Some(Personality {
                preset: None,
                custom: "Be brief.".into()
            })
        );
        assert_eq!(fields.folder, None);
        let empty = Fields::from_bot(&json!({"personality":{"custom":"   "},"avatar":"bad"}));
        assert_eq!(empty.look, Look::character(Character::Alien));
        assert_eq!(empty.personality, None);
        let future = Fields::from_bot(&json!({"personality":{"preset":"future","custom":"kept"}}));
        assert_eq!(
            future.personality.unwrap().preset.as_deref(),
            Some("future")
        );
    }
    #[::core::prelude::v1::test]
    fn patch_sends_look_personality_and_folder_only_when_changed() {
        let saved = Fields::from_bot(&json!({"name":"Teddy","persona":"Job",
            "avatar":{"shape":"teddy","tint":"caramel"},"personality":{"preset":"mentor","custom":""},
            "folder":"/work"}));
        assert_eq!(
            saved.patch(Some(&saved)).unwrap(),
            json!({"name":"Teddy","persona":"Job"})
        );
        let mut draft = saved.clone();
        draft.look.tint = Tint::Sky;
        draft.personality = None;
        draft.folder = None;
        assert_eq!(
            draft.patch(Some(&saved)).unwrap(),
            json!({"name":"Teddy","persona":"Job","avatar":{"shape":"teddy","tint":"sky"},
                "personality":null,"folder":null})
        );
        draft.personality = Some(Personality {
            preset: Some("calm".into()),
            custom: "Mine".into(),
        });
        assert_eq!(
            draft.patch(Some(&saved)).unwrap()["personality"],
            json!({"preset":"calm","custom":"Mine"})
        );
        draft.personality = Some(Personality {
            preset: None,
            custom: "🦀".repeat(CUSTOM_LIMIT + 1),
        });
        assert!(draft.patch(Some(&saved)).is_err());
        // A new bot sends everything, so it is saved with the look it was shown.
        let new = Fields::new_bot(&[], 0);
        let patch = new.patch(None).unwrap();
        assert_eq!(patch["avatar"], json!({"shape":"alien","tint":"leaf"}));
        assert_eq!(
            patch["personality"],
            json!({"preset":"curious","custom":""})
        );
        assert!(patch["folder"].is_null());
    }
    #[::core::prelude::v1::test]
    fn new_bots_take_a_character_none_of_the_bots_is_yet() {
        let used = Character::ALL[..6].to_vec();
        for pick in 0..20 {
            let fields = Fields::new_bot(&used, pick);
            assert_eq!(fields.look, Look::character(Character::Brulee));
            assert_eq!(fields.name, "Brulee");
            assert_eq!(
                fields.personality.unwrap().preset.as_deref(),
                Some("cheerful")
            );
        }
        let all = Fields::new_bot(&Character::ALL, 3);
        assert_eq!(all.look.shape, Character::ALL[3]);
    }
    #[::core::prelude::v1::test]
    fn a_new_character_brings_its_name_and_personality_until_the_user_picks() {
        let (alien, star) = (Character::Alien, Character::Star);
        assert_eq!(suggested_name("Alien", alien, star), Some("Star"));
        assert_eq!(suggested_name("  ", alien, star), Some("Star"));
        assert_eq!(suggested_name("Fetch", alien, star), None);
        let curious = Choice::Preset("curious".into());
        assert_eq!(
            suggested_personality(&curious, false, alien, star),
            Some(Choice::Preset("coach".into()))
        );
        assert_eq!(
            suggested_personality(&Choice::None, false, alien, star),
            Some(Choice::Preset("coach".into()))
        );
        assert_eq!(suggested_personality(&curious, true, alien, star), None);
        assert_eq!(
            suggested_personality(&Choice::Preset("witty".into()), false, alien, star),
            None
        );
        assert_eq!(
            suggested_personality(&Choice::Custom, false, alien, star),
            None
        );
    }
    #[::core::prelude::v1::test]
    fn folders_show_with_a_tilde_and_home_saves_as_none() {
        let home = std::env::temp_dir().canonicalize().unwrap();
        let inside = home.join("work");
        assert_eq!(folder_label(None, Some(&home)), "~");
        assert_eq!(
            folder_label(inside.to_str(), Some(&home)),
            format!("~{}work", std::path::MAIN_SEPARATOR)
        );
        assert_eq!(folder_label(Some("/elsewhere"), None), "/elsewhere");
        assert_eq!(chosen_folder(&home, Some(&home)), None);
        assert_eq!(
            chosen_folder(&inside, Some(&home)).as_deref(),
            inside.to_str()
        );
    }
    fn reply() -> Value {
        json!({"bot":{"id":ID,"name":"Saved","persona":"Instructions","unknown":{"keep":true}},
        "baseline":"a".repeat(64),"origin":"local","instructionsScope":"bot-local","executionConnected":false})
    }
    #[::core::prelude::v1::test]
    fn existing_save_sends_only_name_persona_and_captured_baseline() {
        let write = Write {
            key: ID.into(),
            id: Some(ID.into()),
            baseline: "b".repeat(64),
            fields: text_fields(" New name ".into(), "Local bot text".into()),
            saved: Some(text_fields(String::new(), String::new())),
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
    #[::core::prelude::v1::test]
    fn new_bot_uses_save_without_client_identity() {
        let write = Write {
            key: NEW.into(),
            id: None,
            baseline: "b".repeat(64),
            fields: text_fields("New".into(), String::new()),
            saved: None,
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
    #[::core::prelude::v1::test]
    fn conflict_returns_error_without_retry_or_draft_mutation() {
        let fields = text_fields("Draft".into(), "Keep unsaved".into());
        let write = Write {
            key: ID.into(),
            id: Some(ID.into()),
            baseline: "b".repeat(64),
            fields: fields.clone(),
            saved: Some(text_fields(String::new(), String::new())),
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
    #[::core::prelude::v1::test]
    fn local_validation_bounds_unicode_and_read_checks_identity() {
        assert!(text_fields("  ".into(), String::new()).patch(None).is_err());
        assert!(
            text_fields("Name".into(), "🦀".repeat(20_001))
                .patch(None)
                .is_err()
        );
        assert!(
            text_fields("Name".into(), "🦀".repeat(20_000))
                .patch(None)
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
    #[::core::prelude::v1::test]
    fn conversation_creation_uses_saved_baseline_only_and_never_sends_or_saves() {
        let bound = Bound::parse(reply()).unwrap();
        let draft = text_fields("Unsaved name".into(), "Unsaved instructions".into());
        let before = draft.clone();
        let request = Conversation::from_saved(&bound).unwrap();
        let mut calls = Vec::new();
        let outcome=run(&mut|method,params|{
            calls.push((method.to_owned(),params));
            Ok(json!({"created":true,"executionStarted":false,"instructionsScope":"bot-local","botId":ID,"threadId":uuid::Uuid::nil().to_string()}))
        },Action::Conversation(request)).unwrap();
        assert!(matches!(outcome, Outcome::ConversationCreated(_)));
        assert_eq!(
            calls,
            vec![(
                "bots.conversations.create".into(),
                json!({"botId":ID,"baseline":"a".repeat(64)})
            )]
        );
        assert_eq!(draft, before);
        assert_eq!(bound.bot["name"], "Saved");
    }
    #[::core::prelude::v1::test]
    fn unsupported_conversation_creation_errors_without_fallback_or_retry() {
        let bound = Bound::parse(reply()).unwrap();
        let mut calls = 0;
        let error = run(
            &mut |method, _| {
                assert_eq!(method, "bots.conversations.create");
                calls += 1;
                anyhow::bail!("Unsupported provider/account/mode")
            },
            Action::Conversation(Conversation::from_saved(&bound).unwrap()),
        );
        assert!(error.is_err());
        assert_eq!(calls, 1);
        assert_eq!(bound.bot["persona"], "Instructions");
        assert!(run(&mut|_,_|Ok(json!({"created":true,"executionStarted":true,"instructionsScope":"bot-local","botId":ID,"threadId":uuid::Uuid::nil().to_string()})),
            Action::Conversation(Conversation::from_saved(&bound).unwrap())).is_err());
    }
}

#[cfg(all(test, unix))]
mod fixture_tests {
    use super::tests::text_fields;
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
    #[::core::prelude::v1::test]
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
            fields: text_fields(
                "Synthetic bot".into(),
                "Synthetic bot-local instructions".into(),
            ),
            saved: None,
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
            fields: text_fields("Synthetic renamed".into(), "Changed local text".into()),
            saved: Some(text_fields(String::new(), String::new())),
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
    #[::core::prelude::v1::test]
    fn real_api_preserves_imported_envelope_unknown_fields_casing_and_whitespace() {
        let fixture = Fixture::new();
        let source = fixture.0.join("synthetic-source");
        fs::create_dir_all(source.join("threads")).unwrap();
        let id = "ABCD1234-0000-4000-8000-000000000001";
        let envelope = json!({"addedStarters":true,"starterLineup":7,"futureEnvelope":{"keep":42},"bots":[{
            "id":id,"name":"Original","persona":"Original instructions","avatar":{"futureLook":true},
            "personality":{"preset":"unknown-future-preset","custom":"preserved"},
            "selection":{"provider":"claude","modelID":"future-model","unknown":true},
            "accessMode":"approval","interactionMode":"build","folder":"/synthetic/bot-folder","futureBot":{"keep":true}
        }]});
        let original = serde_json::to_vec_pretty(&envelope).unwrap();
        fs::write(source.join("bots.json"), &original).unwrap();
        let mut store = Store::open(&fixture.0.join("rust/state.sqlite")).unwrap();
        store.import_legacy(&source).unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(store)));
        let mut api = |method: &str, params| call(&engine, method, params);
        let Outcome::Read(read) = run(&mut api, Action::Read(id.to_lowercase())).unwrap() else {
            panic!("read")
        };
        assert_eq!(read.origin, "imported");
        let persona = "  \nKeep exact whitespace\n  ";
        let Outcome::Saved(_, saved) = run(
            &mut api,
            Action::Write(Write {
                key: id.into(),
                id: Some(id.to_lowercase()),
                baseline: read.baseline,
                fields: Fields {
                    name: "  Renamed  ".into(),
                    persona: persona.into(),
                    ..Fields::from_bot(&read.bot)
                },
                saved: Some(Fields::from_bot(&read.bot)),
            }),
        )
        .unwrap() else {
            panic!("save")
        };
        assert_eq!(saved.bot["id"], id);
        assert_eq!(saved.bot["name"], "Renamed");
        assert_eq!(saved.bot["persona"], persona);
        let mut expected = envelope.clone();
        expected["bots"][0]["name"] = json!("Renamed");
        expected["bots"][0]["persona"] = json!(persona);
        let store = &engine.lock().unwrap().store;
        assert_eq!(store.document("bots.json").unwrap().unwrap(), expected);
        assert_eq!(store.original("bots.json").unwrap().unwrap(), original);
        assert_eq!(fs::read(source.join("bots.json")).unwrap(), original);
    }
    #[::core::prelude::v1::test]
    fn real_api_new_conversation_preserves_drafts_and_does_not_execute() {
        let fixture = Fixture::new();
        let mut store = Store::open(&fixture.0.join("rust/state.sqlite")).unwrap();
        let bot_id = uuid::Uuid::new_v4().to_string();
        let persona = "  saved instruction snapshot\n";
        let bots = json!({"addedStarters":false,"starterLineup":1,"bots":[{"id":bot_id,"name":"Saved bot","persona":persona,
            "selection":{"provider":"codex","modelID":"default"},"accessMode":"approval","interactionMode":"build","folder":fixture.0.to_str().unwrap()}]});
        store.save_document("bots.json", &bots).unwrap();
        let mut existing = store
            .new_thread("00000000-0000-0000-0000-000000000000")
            .unwrap();
        existing["draft"] = json!("Keep this unsent chat draft");
        store.save(&existing).unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(store)));
        let mut api = |method: &str, params| call(&engine, method, params);
        let Outcome::Read(bound) = run(&mut api, Action::Read(bot_id.clone())).unwrap() else {
            panic!("read")
        };
        let editor_draft = text_fields(
            "Unsaved editor name".into(),
            "Keep unsaved editor text".into(),
        );
        let before = editor_draft.clone();
        let Outcome::ConversationCreated(thread_id) = run(
            &mut api,
            Action::Conversation(Conversation::from_saved(&bound).unwrap()),
        )
        .unwrap() else {
            panic!("create")
        };
        assert_eq!(editor_draft, before);
        let created = api("threads.read", json!({"threadId":thread_id})).unwrap();
        assert_eq!(created["botID"], bot_id);
        assert_eq!(created["draft"], "");
        assert!(created["items"].as_array().unwrap().is_empty());
        assert!(created["sessions"].as_object().unwrap().is_empty());
        assert_eq!(created["rustBotContext"]["persona"], persona);
        assert!(
            api("app.status", json!({})).unwrap()["running"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            engine
                .lock()
                .unwrap()
                .store
                .thread(existing["id"].as_str().unwrap())
                .unwrap(),
            existing
        );
        assert_eq!(
            engine
                .lock()
                .unwrap()
                .store
                .document("bots.json")
                .unwrap()
                .unwrap(),
            bots
        );
        api(
            "bots.patch",
            json!({"botId":bot_id,"baseline":bound.baseline,"patch":{"persona":"Edited later"}}),
        )
        .unwrap();
        assert_eq!(
            api("threads.read", json!({"threadId":thread_id})).unwrap()["rustBotContext"],
            created["rustBotContext"]
        );
    }
}

#[cfg(test)]
mod shutdown_tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn closed_admitted_worker_does_not_dispatch_and_retains_actual_join_ownership() {
        let mut owner = WorkerOwner::default();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let probe = calls.clone();
        assert!(owner.spawn(move |admission| {
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            assert!(
                run_admitted(
                    &mut |_, _| {
                        probe.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        Ok(json!({}))
                    },
                    Action::List,
                    &admission
                )
                .is_err()
            );
        }));
        entered_rx
            .recv_timeout(std::time::Duration::from_secs(3))
            .unwrap();
        owner.close();
        assert_eq!(owner.status().unjoined, 1);
        release_tx.send(()).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while owner.status().unjoined != 0 {
            assert!(std::time::Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(owner.status().returned, 1);
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 0);
        assert!(!owner.spawn(|_| panic!("closed owner cannot restart")));
    }
}
