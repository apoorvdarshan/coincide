//! Retained Voice-only credential editor. Rendering never opens an OS vault.
use super::*;
use coincide_core::{
    dictation::{
        transcription::Provider,
        voice_api::{self, HostedConfig},
        voice_secret::{Credential, VoiceSecrets},
    },
    native_ui_edits::{NativeUiEditLease, NativeUiEditors},
};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc,
};
use zeroize::Zeroizing;
struct Editor {
    input: Entity<InputState>,
    credential: Option<Arc<Credential>>,
    revision: u64,
    dirty: bool,
    lease: NativeUiEditLease,
    status: String,
    _change: Subscription,
}
enum Action {
    Save(Zeroizing<String>),
    Load,
    Delete,
    Test,
}
enum Outcome {
    Loaded(Arc<Credential>),
    Deleted,
    Tested(Arc<Credential>),
}
trait Service: Send + Sync {
    fn test(&self, key: &Credential, cancelled: &(dyn Fn() -> bool + Sync)) -> Result<(), ()>;
}
struct HttpsService;
impl Service for HttpsService {
    fn test(&self, key: &Credential, cancelled: &(dyn Fn() -> bool + Sync)) -> Result<(), ()> {
        voice_api::test_key(key, cancelled).map_err(|_| ())
    }
}
struct Reply {
    provider: Provider,
    generation: u64,
    revision: u64,
    result: Result<Outcome, &'static str>,
    _custody: NativeUiEditLease,
    expected_input: Zeroizing<String>,
}
/// Codex's `$CODEX_HOME/auth.json`, or `~/.codex/auth.json`.
fn codex_auth_file() -> Option<std::path::PathBuf> {
    if let Some(home) = std::env::var_os("CODEX_HOME").filter(|home| !home.is_empty()) {
        return Some(std::path::PathBuf::from(home).join("auth.json"));
    }
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .filter(|home| !home.is_empty())?;
    Some(
        std::path::PathBuf::from(home)
            .join(".codex")
            .join("auth.json"),
    )
}
/// `OPENAI_API_KEY` of a Codex signed in with an API key, when it is a
/// plausible key. A ChatGPT sign-in's tokens in the same file are never read.
fn codex_api_key(document: &[u8]) -> Option<Zeroizing<String>> {
    if document.len() >= 1_000_000 {
        return None;
    }
    let object = serde_json::from_slice::<Value>(document).ok()?;
    let key = Zeroizing::new(object.get("OPENAI_API_KEY")?.as_str()?.trim().to_owned());
    (key.chars().count() >= 20 && !key.contains(char::is_whitespace)).then_some(key)
}
fn read_codex_api_key() -> Option<Zeroizing<String>> {
    let path = codex_auth_file()?;
    if std::fs::metadata(&path).ok()?.len() >= 1_000_000 {
        return None;
    }
    codex_api_key(&Zeroizing::new(std::fs::read(path).ok()?))
}
#[cfg(target_os = "macos")]
const VAULT: &str = "Keychain";
#[cfg(windows)]
const VAULT: &str = "Windows Credential Manager";
#[cfg(not(any(target_os = "macos", windows)))]
const VAULT: &str = "secret store";
pub(super) struct Panel {
    /// Codex is signed in with an API key Voice can copy, as of the last
    /// time Voice opened.
    codex_has_key: bool,
    /// The pending save copies Codex's key.
    codex_import: bool,
    codex_prompt: Option<Task<()>>,
    editors: Vec<Editor>,
    secrets: VoiceSecrets,
    service: Arc<dyn Service>,
    workers: worker_owner::WorkerOwner,
    sender: mpsc::SyncSender<Reply>,
    receiver: mpsc::Receiver<Reply>,
    generation: u64,
    pending: Option<Provider>,
    cancellation: Arc<AtomicBool>,
}
fn index(provider: Provider) -> usize {
    if provider == Provider::OpenAi { 0 } else { 1 }
}
fn name(provider: Provider) -> &'static str {
    if provider == Provider::OpenAi {
        "OpenAI"
    } else {
        "Groq"
    }
}
impl Panel {
    pub fn new(native: NativeUiEditors, window: &mut Window, cx: &mut Context<Self>) -> Self {
        Self::with_services(
            native,
            VoiceSecrets::default(),
            Arc::new(HttpsService),
            window,
            cx,
        )
    }
    fn with_services(
        native: NativeUiEditors,
        secrets: VoiceSecrets,
        service: Arc<dyn Service>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let (sender, receiver) = mpsc::sync_channel(1);
        let mut editors = Vec::new();
        for provider in [Provider::OpenAi, Provider::Groq] {
            let input = cx.new(|cx| {
                let mut input = InputState::new(window, cx).placeholder("Paste Voice API key");
                input.set_masked(true, window, cx);
                input
            });
            let change = cx.subscribe(&input, move |this, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    let editor = &mut this.editors[index(provider)];
                    editor.revision = editor.revision.wrapping_add(1);
                    editor.dirty = !editor.input.read(cx).value().is_empty();
                    editor.lease.set_dirty(editor.dirty);
                    cx.notify();
                }
            });
            editors.push(Editor {
                input,
                credential: None,
                revision: 0,
                dirty: false,
                lease: native.editor(),
                status:
                    "Saved key has not been loaded. No secret-store access occurs on this page."
                        .into(),
                _change: change,
            });
        }
        Self {
            codex_has_key: false,
            codex_import: false,
            codex_prompt: None,
            editors,
            secrets,
            service,
            workers: Default::default(),
            sender,
            receiver,
            generation: 0,
            pending: None,
            cancellation: Arc::new(AtomicBool::new(false)),
        }
    }
    pub fn configuration(
        &self,
        provider: Provider,
        model: String,
        language: Option<String>,
        cx: &App,
    ) -> Option<HostedConfig> {
        let editor = &self.editors[index(provider)];
        if self.workers.closed()
            || self.pending.is_some()
            || editor.dirty
            || !editor.input.read(cx).value().is_empty()
        {
            return None;
        }
        Some(HostedConfig::new(
            editor.credential.clone()?,
            model,
            language,
        ))
    }
    pub fn blocks_close(&self, cx: &App) -> bool {
        self.pending.is_some()
            || self
                .editors
                .iter()
                .any(|e| e.dirty || !e.input.read(cx).value().is_empty())
    }
    pub fn request_shutdown(&mut self) {
        self.cancellation.store(true, Ordering::Release);
        self.workers.close();
        self.generation = self.generation.wrapping_add(1);
        for editor in &mut self.editors {
            editor.credential = None;
        }
    }
    pub fn shutdown_status(&mut self) -> worker_owner::ShutdownStatus {
        self.poll_workers();
        self.workers.status()
    }
    fn poll_workers(&mut self) {
        self.workers.poll();
    }
    pub fn poll(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.poll_workers();
        while let Ok(reply) = self.receiver.try_recv() {
            if self.workers.closed() || reply.generation != self.generation {
                continue;
            }
            self.pending = None;
            let editor = &mut self.editors[index(reply.provider)];
            let tested = matches!(&reply.result, Ok(Outcome::Tested(_)));
            match reply.result {
                Ok(Outcome::Loaded(key)) if std::mem::take(&mut self.codex_import) => {
                    editor.credential = Some(key);
                    editor.status = format!("Copied Codex’s key to the {VAULT}.");
                }
                Ok(Outcome::Loaded(key)) | Ok(Outcome::Tested(key)) => {
                    editor.credential = Some(key);
                    editor.status=if tested{"Voice key test succeeded. Recording sends audio only after an explicit dictation action."}else{"Voice key loaded for this session. Recording sends audio only after an explicit dictation action."}.into();
                    if editor.revision == reply.revision
                        && editor.input.read(cx).value().as_ref() == reply.expected_input.as_str()
                    {
                        editor
                            .input
                            .update(cx, |input, cx| input.set_value("", window, cx));
                        editor.dirty = false;
                        editor.lease.set_dirty(false);
                    }
                }
                Ok(Outcome::Deleted) => {
                    editor.credential = None;
                    editor.status = "Voice key removed from the OS secret store.".into();
                }
                Err(message) => {
                    self.codex_import = false;
                    editor.status = message.into()
                }
            }
            cx.notify();
        }
    }
    /// Checks whether Codex has an API key to offer, without keeping it.
    pub fn refresh_codex_key(&mut self, cx: &mut Context<Self>) {
        let has_key = read_codex_api_key().is_some();
        if has_key != self.codex_has_key {
            self.codex_has_key = has_key;
            cx.notify();
        }
    }
    fn confirm_codex_import(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let detail = format!(
            "Coincide copies OPENAI_API_KEY from ~/.codex/auth.json into its {VAULT} and sends it only to OpenAI, with your dictation audio. Changing the key in Codex later doesn’t change Coincide’s copy."
        );
        let answer = window.prompt(
            PromptLevel::Info,
            "Copy Codex’s OpenAI API key?",
            Some(&detail),
            &["Copy Key", "Cancel"],
            cx,
        );
        self.codex_prompt = Some(cx.spawn_in(window, async move |this, cx| {
            if answer.await.unwrap_or(1) != 0 {
                return;
            }
            this.update(cx, |this, cx| this.import_codex_key(cx)).ok();
        }));
    }
    fn import_codex_key(&mut self, cx: &mut Context<Self>) {
        let Some(key) = read_codex_api_key() else {
            self.codex_has_key = false;
            self.editors[index(Provider::OpenAi)].status = "Codex no longer has an API key.".into();
            cx.notify();
            return;
        };
        self.codex_import = true;
        self.action(Provider::OpenAi, Action::Save(key), cx);
        if self.pending.is_none() {
            self.codex_import = false;
        }
    }
    fn action(&mut self, provider: Provider, action: Action, cx: &mut Context<Self>) {
        if !self.workers.can_start() || self.pending.is_some() {
            return;
        }
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        self.cancellation = Arc::new(AtomicBool::new(false));
        let cancel = self.cancellation.clone();
        let store = self.secrets.clone();
        let service = self.service.clone();
        let sender = self.sender.clone();
        let editor = &mut self.editors[index(provider)];
        let revision = editor.revision;
        let expected_input = Zeroizing::new(editor.input.read(cx).value().to_string());
        let custody = editor.lease.pending_native_action();
        if matches!(action, Action::Delete) {
            editor.credential = None;
        }
        editor.status="Waiting for the owned Voice operation. OS unlock dialogs, if requested by the OS, must finish before this worker can return.".into();
        if self.workers.spawn(move|admission|{

            let cancelled=||cancel.load(Ordering::Acquire)||!admission.allowed();
            let result=(||{
                if cancelled(){return Err("Voice operation cancelled.")}
                let testing=matches!(&action,Action::Test);
                let key=match action {
                    Action::Save(key)=>store.save(provider,key).map_err(|_|"The OS did not confirm saving the Voice key. No plaintext fallback was used.")?,
                    Action::Load|Action::Test=>store.load(provider).map_err(|_|"Saved Voice key unavailable. Unlock the OS secret store or save a key.")?,
                    Action::Delete=>{store.delete(provider).map_err(|_|"Voice key removal was not confirmed. Retry Remove Key.")?;return Ok(Outcome::Deleted)}
                };
                if cancelled(){return Err("Voice operation cancelled after OS completion.")}
                if testing{service.test(&key,&cancelled).map_err(|_|"Voice key test failed or was cancelled. Check the key and network; provider responses are not logged.")?;Ok(Outcome::Tested(key))}else{Ok(Outcome::Loaded(key))}
            })();
            let _=sender.try_send(Reply{provider,generation,revision,result,_custody:custody,expected_input});
        }){self.pending=Some(provider)}else{editor.status="Could not start the Voice worker. Nothing was queued.".into();}
        cx.notify();
    }
    fn save(&mut self, provider: Provider, cx: &mut Context<Self>) {
        let editor = &mut self.editors[index(provider)];
        if editor.input.read(cx).value().len() > 4096
            || editor.input.read(cx).value().trim().is_empty()
        {
            editor.status = "Enter a Voice API key of at most 4096 bytes.".into();
            cx.notify();
            return;
        }
        let key = Zeroizing::new(
            self.editors[index(provider)]
                .input
                .read(cx)
                .value()
                .trim()
                .to_owned(),
        );
        self.action(provider, Action::Save(key), cx);
    }
    fn discard(&mut self, provider: Provider, window: &mut Window, cx: &mut Context<Self>) {
        if self.pending.is_some() || self.workers.closed() {
            return;
        }
        let editor = &mut self.editors[index(provider)];
        editor
            .input
            .update(cx, |input, cx| input.set_value("", window, cx));
        editor.dirty = false;
        editor.lease.set_dirty(false);
        cx.notify();
    }
    pub fn pane(&self, provider: Provider, cx: &mut Context<Self>) -> AnyElement {
        let editor = &self.editors[index(provider)];
        let busy = self.pending.is_some() || self.workers.closed();
        div().id(if provider==Provider::OpenAi{"voice-openai-key"}else{"voice-groq-key"}).p_3().flex().flex_col().gap_2()
            .child(format!("{} Voice API key",name(provider)))
            .child(format!("Recordings are sent to {} under your account and its data policies. This key is separate from chat provider accounts.",name(provider)))
            .child(Input::new(&editor.input))
            .child(Button::new(("voice-key-save", index(provider))).label("Save / Replace").disabled(busy||!editor.dirty).on_click(cx.listener(move|this,_,_,cx|{
                this.save(provider,cx);
            })))
            .child(Button::new(("voice-key-load", index(provider))).label("Load Saved Key").disabled(busy||editor.dirty).on_click(cx.listener(move|this,_,_,cx|this.action(provider,Action::Load,cx))))
            .child(Button::new(("voice-key-test", index(provider))).label("Test Key").disabled(busy||editor.dirty).on_click(cx.listener(move|this,_,_,cx|this.action(provider,Action::Test,cx))))
            .child(Button::new(("voice-key-remove", index(provider))).label("Remove Key").disabled(busy).on_click(cx.listener(move|this,_,_,cx|this.action(provider,Action::Delete,cx))))
            .child(Button::new(("voice-key-discard", index(provider))).label("Discard Typed Key").disabled(busy||!editor.dirty).on_click(cx.listener(move|this,_,window,cx|{this.discard(provider,window,cx);})))
            .child(Button::new(("voice-key-cancel", index(provider))).label("Cancel pending result").disabled(self.pending.is_none()).on_click(cx.listener(|this,_,_,cx|{this.cancellation.store(true,Ordering::Release);cx.notify();})))
            .when(provider == Provider::OpenAi && self.codex_has_key, |pane| {
                pane.child(div().flex().items_center().gap_3().pt_2()
                    .child(div().flex_1().flex().flex_col()
                        .child("Use the OpenAI API key from Codex")
                        .child(div().text_xs().child(format!("Codex is signed in with an API key. Coincide can copy that key to its own {VAULT} item; it never reads ChatGPT sign-ins."))))
                    .child(Button::new("voice-key-codex").label("Use Codex’s Key…").disabled(busy).on_click(cx.listener(|this, _, window, cx| this.confirm_codex_import(window, cx)))))
            })
            .child(editor.status.clone()).into_any_element()
    }
}
impl Render for Panel {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .flex_col()
            .child(self.pane(Provider::OpenAi, cx))
            .child(self.pane(Provider::Groq, cx))
    }
}

#[cfg(test)]
#[path = "voice_credentials_ui_tests.rs"]
mod native_tests;

#[cfg(test)]
mod codex_key_tests {
    use super::codex_api_key;

    #[::core::prelude::v1::test]
    fn only_a_plausible_api_key_is_copied_from_codex() {
        let key = "sk-synthetic-0123456789abcdef";
        assert_eq!(
            codex_api_key(format!(r#"{{"OPENAI_API_KEY":" {key}\n"}}"#).as_bytes())
                .as_deref()
                .map(String::as_str),
            Some(key)
        );
        // A ChatGPT sign-in has tokens and no API key; nothing is read from them.
        assert!(codex_api_key(br#"{"OPENAI_API_KEY":null,"tokens":{"access_token":"synthetic-token-value-long"}}"#).is_none());
        assert!(codex_api_key(br#"{"OPENAI_API_KEY":"sk-short"}"#).is_none());
        assert!(codex_api_key(br#"{"OPENAI_API_KEY":"sk-has a space in the middle"}"#).is_none());
        assert!(codex_api_key(b"not json").is_none());
        assert!(codex_api_key(&vec![b' '; 1_000_000]).is_none());
    }
}
