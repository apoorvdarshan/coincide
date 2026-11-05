//! Standalone import panel. Parent: `mod session_import;`, create an
//! Entity<SessionImportPanel>, call set_project on destination changes, render it,
//! and subscribe to SessionImportEvent::Imported to select the persisted thread.
//! Every API call runs on a single background worker, never on the GPUI thread.
use anyhow::{Context as _, Result, ensure};
use coincide_core::api::{SharedEngine, call};
use gpui_kit::base::Disableable;
use gpui_kit::{component::button::*, *};
use serde_json::{Value, json};
use std::{path::PathBuf, sync::mpsc, time::Duration};

const VISIBLE_MESSAGES: usize = 12;
const VISIBLE_CHARS: usize = 1500;
#[derive(Clone, Debug, PartialEq, Eq)]
struct Selection {
    path: PathBuf,
    provider: String,
    project: Option<String>,
}
impl Selection {
    fn params(&self) -> Result<Value> {
        ensure!(self.path.is_absolute(), "Choose an absolute source file");
        ensure!(
            matches!(self.provider.as_str(), "codex" | "claude"),
            "Choose Codex or Claude"
        );
        Ok(
            json!({"path":self.path.to_str().context("Source path must be UTF-8")?,
            "provider":self.provider,"projectId":self.project}),
        )
    }
}
#[derive(Clone)]
struct Preview {
    selection: Selection,
    sha256: String,
    title: String,
    count: u64,
    omissions: u64,
    shortened: bool,
    messages: Vec<(String, String)>,
    display_shortened: bool,
}
impl Preview {
    fn from_reply(selection: Selection, reply: Value) -> Result<Self> {
        let sha256 = reply["sha256"]
            .as_str()
            .context("Preview has no fingerprint")?;
        ensure!(
            sha256.len() == 64 && sha256.bytes().all(|c| c.is_ascii_hexdigit()),
            "Invalid preview fingerprint"
        );
        ensure!(
            reply["provider"] == selection.provider && reply["executable"] == false,
            "Invalid preview provider or execution state"
        );
        let count = reply["messageCount"]
            .as_u64()
            .context("Preview has no message count")?;
        ensure!(
            count > 0 && count <= 100_000,
            "Invalid preview message count"
        );
        let messages = reply["messages"]
            .as_array()
            .context("Preview has no messages")?;
        ensure!(
            messages.len() <= 20,
            "Preview response exceeds message bound"
        );
        let mut display_shortened = count > messages.len().min(VISIBLE_MESSAGES) as u64;
        let messages = messages
            .iter()
            .take(VISIBLE_MESSAGES)
            .map(|message| {
                let role = message["role"].as_str().context("Invalid preview role")?;
                ensure!(
                    matches!(role, "user" | "assistant"),
                    "Unsupported preview role"
                );
                let text = message["text"].as_str().context("Invalid preview text")?;
                let shortened = text.chars().count() > VISIBLE_CHARS;
                display_shortened |= shortened;
                Ok((
                    role.to_owned(),
                    if shortened {
                        text.chars().take(VISIBLE_CHARS).collect::<String>() + "\n…"
                    } else {
                        text.to_owned()
                    },
                ))
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Self {
            selection,
            sha256: sha256.to_owned(),
            title: reply["title"]
                .as_str()
                .unwrap_or("Imported conversation")
                .chars()
                .take(100)
                .collect(),
            count,
            omissions: reply["omittedRecords"]
                .as_u64()
                .context("Preview has no omission count")?,
            shortened: reply["shortenedText"] == true,
            messages,
            display_shortened,
        })
    }
    fn import_params(&self) -> Result<Value> {
        let mut params = self.selection.params()?;
        params["sha256"] = json!(self.sha256);
        Ok(params)
    }
}
enum Action {
    Preview(Selection),
    Import(Preview),
}
enum Outcome {
    Preview(Preview),
    Imported(String),
}
fn run(api: &mut impl FnMut(&str, Value) -> Result<Value>, action: Action) -> Result<Outcome> {
    match action {
        Action::Preview(selection) => {
            let reply = api("cli.sessions.preview", selection.params()?)?;
            Ok(Outcome::Preview(Preview::from_reply(selection, reply)?))
        }
        Action::Import(preview) => {
            let reply = api("cli.sessions.import", preview.import_params()?)?;
            let id = reply["threadId"]
                .as_str()
                .context("Import outcome unknown: refresh conversations before retrying")?;
            uuid::Uuid::parse_str(id).context("Import returned an invalid thread ID")?;
            Ok(Outcome::Imported(id.to_owned()))
        }
    }
}

pub enum SessionImportEvent {
    Imported { thread_id: String },
}
pub struct SessionImportPanel {
    engine: SharedEngine,
    provider: String,
    project: Option<String>,
    generation: u64,
    busy: bool,
    choosing: bool,
    preview: Option<Preview>,
    notice: String,
    tx: mpsc::Sender<(u64, Result<Outcome>)>,
    rx: mpsc::Receiver<(u64, Result<Outcome>)>,
    _poll: Task<()>,
}
impl EventEmitter<SessionImportEvent> for SessionImportPanel {}
impl SessionImportPanel {
    pub fn new(engine: SharedEngine, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (tx, rx) = mpsc::channel();
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
                if this.update_in(cx, |this, _, cx| this.poll(cx)).is_err() {
                    break;
                }
            }
        });
        Self {
            engine,
            provider: "codex".into(),
            project: None,
            generation: 0,
            busy: false,
            choosing: false,
            preview: None,
            notice: "Choose a CLI provider and a session JSONL file.".into(),
            tx,
            rx,
            _poll: poll,
        }
    }
    /// Capture destination at preview time; never silently import into a newly
    /// selected project. An in-flight import still emits its actual persisted ID.
    pub fn set_project(&mut self, project: Option<String>, cx: &mut Context<Self>) {
        if self.project == project {
            return;
        }
        self.project = project;
        self.generation = self.generation.wrapping_add(1);
        self.preview = None;
        self.notice = if self.busy { "Destination changed. Waiting for the previous operation; an import already started may complete." }
            else { "Destination changed. Choose a source again to preview for this destination." }.into();
        cx.notify();
    }
    fn provider(&mut self, provider: &str, cx: &mut Context<Self>) {
        if self.busy || self.choosing || self.provider == provider {
            return;
        }
        self.provider = provider.into();
        self.generation = self.generation.wrapping_add(1);
        self.preview = None;
        self.notice = "Provider changed. Choose its session JSONL file.".into();
        cx.notify();
    }
    fn choose(&mut self, cx: &mut Context<Self>) {
        if self.busy || self.choosing {
            return;
        }
        self.choosing = true;
        self.preview = None;
        let generation = self.generation;
        let selection = Selection {
            path: PathBuf::new(),
            provider: self.provider.clone(),
            project: self.project.clone(),
        };
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Preview CLI session".into()),
        });
        self.notice =
            "Choose a Codex rollout or Claude Code JSONL file. Originals are preserved.".into();
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result: Result<_> = async { Ok(picker.await??) }.await;
            let _ = this.update(cx, |this, cx| {
                this.choosing = false;
                if generation != this.generation {
                    cx.notify();
                    return;
                }
                match result {
                    Ok(Some(paths)) if paths.len() == 1 => {
                        let mut selection = selection;
                        selection.path = paths[0].clone();
                        this.start(Action::Preview(selection), cx);
                    }
                    Ok(_) => {
                        this.notice = "File selection cancelled.".into();
                        cx.notify();
                    }
                    Err(error) => {
                        this.notice = format!("File selection failed: {error}");
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }
    fn start(&mut self, action: Action, cx: &mut Context<Self>) {
        if self.busy || self.choosing {
            return;
        }
        self.busy = true;
        self.notice = match action {
            Action::Preview(_) => "Reading bounded session preview…",
            Action::Import(_) => "Importing the reviewed source…",
        }
        .into();
        let tx = self.tx.clone();
        let generation = self.generation;
        let engine = self.engine.clone();
        // Worker owns every Engine lock and source parse. GPUI polls only a channel.
        std::thread::spawn(move || {
            let result = run(&mut |method, params| call(&engine, method, params), action);
            let _ = tx.send((generation, result));
        });
        cx.notify();
    }
    fn poll(&mut self, cx: &mut Context<Self>) {
        let Ok((generation, result)) = self.rx.try_recv() else {
            return;
        };
        self.busy = false;
        match result {
            Ok(Outcome::Imported(thread_id)) => {
                self.preview = None;
                self.notice =
                    "Imported as a read-only conversation. Fork it before sending messages.".into();
                // Do not discard a durable success after the destination changes.
                cx.emit(SessionImportEvent::Imported { thread_id });
            }
            Ok(Outcome::Preview(preview)) if generation == self.generation => {
                self.preview = Some(preview);
                self.notice = "Review the preview, then confirm import.".into();
            }
            Ok(_) => {
                self.notice = "Preview destination changed. Choose the source again.".into();
            }
            Err(error) => {
                self.preview = None;
                self.notice = format!(
                    "{error}. No automatic retry. Refresh conversations before retrying an import."
                );
            }
        }
        cx.notify();
    }
}
impl Render for SessionImportPanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let disabled = self.busy || self.choosing;
        let mut pane = div().id("session-import-panel").size_full().flex().flex_col().gap_2().p_3()
            .child("Import CLI session")
            .child("Choose a provider explicitly. Only text is shown; unsupported records stay in the preserved original.")
            .child(div().flex().gap_2()
                .child(Button::new("session-import-codex").label(if self.provider == "codex" {"✓ Codex"} else {"Codex"}).disabled(disabled)
                    .on_click(cx.listener(|this,_,_,cx|this.provider("codex",cx))))
                .child(Button::new("session-import-claude").label(if self.provider == "claude" {"✓ Claude Code"} else {"Claude Code"}).disabled(disabled)
                    .on_click(cx.listener(|this,_,_,cx|this.provider("claude",cx))))
                .child(Button::new("session-import-choose").label("Choose session file…").disabled(disabled || !cfg!(unix))
                    .on_click(cx.listener(|this,_,_,cx|this.choose(cx)))))
            .child(format!("Destination: {}",self.project.as_deref().unwrap_or("Chats (projectless)")))
            .child(div().text_sm().child(self.notice.clone()));
        if !cfg!(unix) {
            pane = pane.child("Session file import is not supported on this platform yet.");
        }
        let mut body = div()
            .id("session-import-preview")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_2();
        if let Some(preview) = &self.preview {
            pane = pane.child(div().id("session-import-confirmation").flex().flex_col().gap_2()
                .child("Import this reviewed file? This creates a separate read-only conversation. It cannot execute the original provider session; fork it to continue.")
                .child(Button::new("session-import-confirm").label("Import reviewed session").primary().disabled(disabled)
                    .on_click(cx.listener(|this,_,_,cx| {if let Some(preview) = this.preview.clone() { this.start(Action::Import(preview),cx); }}))));
            body = body
                .child(preview.title.clone())
                .child(format!(
                    "File: {}",
                    preview
                        .selection
                        .path
                        .to_string_lossy()
                        .chars()
                        .take(500)
                        .collect::<String>()
                ))
                .child(format!(
                    "{} messages · {} omitted records or content blocks",
                    preview.count, preview.omissions
                ));
            if preview.shortened {
                body = body.child("Some imported message text was shortened to the import limit. Exact originals remain preserved.");
            }
            if preview.display_shortened {
                body = body.child(
                    "Showing an excerpt of the first messages; this panel limits text for display.",
                );
            }
            for (index, (role, text)) in preview.messages.iter().enumerate() {
                body = body.child(
                    div()
                        .id(SharedString::from(format!(
                            "session-import-message-{index}"
                        )))
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(role.clone())
                        .child(div().text_sm().child(text.clone())),
                );
            }
        }
        pane.child(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn selection() -> Selection {
        Selection {
            path: PathBuf::from("/synthetic/source.jsonl"),
            provider: "codex".into(),
            project: None,
        }
    }
    fn reply() -> Value {
        json!({"provider":"codex","executable":false,"sha256":"a".repeat(64),"title":"Synthetic",
        "messageCount":1,"omittedRecords":3,"shortenedText":false,"messages":[{"role":"user","text":"hello"}]})
    }
    #[::core::prelude::v1::test]
    fn confirmation_uses_exact_preview_binding_and_never_repreviews() {
        let mut calls = Vec::new();
        let preview = match run(
            &mut |method, params| {
                calls.push((method.to_owned(), params));
                Ok(reply())
            },
            Action::Preview(selection()),
        )
        .unwrap()
        {
            Outcome::Preview(p) => p,
            _ => panic!("preview"),
        };
        let outcome = run(
            &mut |method, params| {
                calls.push((method.to_owned(), params));
                Ok(json!({"threadId":"00000000-0000-4000-8000-000000000001"}))
            },
            Action::Import(preview),
        )
        .unwrap();
        assert!(matches!(outcome, Outcome::Imported(_)));
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].0, "cli.sessions.preview");
        assert_eq!(calls[1].0, "cli.sessions.import");
        assert_eq!(calls[1].1["sha256"], "a".repeat(64));
        assert_eq!(calls[1].1["path"], "/synthetic/source.jsonl");
        assert!(calls[1].1["projectId"].is_null());
    }
    #[::core::prelude::v1::test]
    fn display_is_bounded_and_omissions_preserved() {
        let mut value = reply();
        value["messages"][0]["text"] = json!("🦀".repeat(5000));
        let preview = Preview::from_reply(selection(), value).unwrap();
        assert_eq!(preview.omissions, 3);
        assert!(preview.display_shortened);
        assert_eq!(preview.messages[0].1.chars().count(), VISIBLE_CHARS + 2);
        let mut value = reply();
        value["provider"] = json!("claude");
        assert!(Preview::from_reply(selection(), value).is_err());
    }
    #[::core::prelude::v1::test]
    fn failed_import_is_never_retried() {
        let preview = Preview::from_reply(selection(), reply()).unwrap();
        let mut count = 0;
        assert!(
            run(
                &mut |_, _| {
                    count += 1;
                    anyhow::bail!("synthetic source changed")
                },
                Action::Import(preview)
            )
            .is_err()
        );
        assert_eq!(count, 1);
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
    struct FixtureDirectory(PathBuf);
    impl FixtureDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "coincide-session-panel-test-{}",
                uuid::Uuid::new_v4()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for FixtureDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[::core::prelude::v1::test]
    fn worker_uses_real_api_to_preview_and_import_synthetic_sources() {
        let fixture = FixtureDirectory::new();
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&fixture.0.join("rust/state.sqlite")).unwrap(),
        )));
        for provider in ["codex", "claude"] {
            let path = fixture.0.join(format!("{provider}.jsonl"));
            let id = uuid::Uuid::new_v4().to_string();
            let source = if provider == "codex" {
                [json!({"type":"session_meta","payload":{"id":id,"cwd":"/synthetic","unknown":"kept"}}),
                json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"synthetic panel fixture"}]}})].iter().map(Value::to_string).collect::<Vec<_>>().join("\n")
            } else {
                json!({"sessionId":id,"cwd":"/synthetic","uuid":"message-one","parentUuid":null,"type":"user","message":{"role":"user","content":"synthetic panel fixture"},"unknown":"kept"}).to_string()
            };
            fs::write(&path, source.as_bytes()).unwrap();
            let mut api = |method: &str, params| call(&engine, method, params);
            let Outcome::Preview(preview) = run(
                &mut api,
                Action::Preview(Selection {
                    path: path.clone(),
                    provider: provider.into(),
                    project: None,
                }),
            )
            .unwrap() else {
                panic!("expected preview")
            };
            assert_eq!(preview.count, 1);
            let Outcome::Imported(thread) = run(&mut api, Action::Import(preview)).unwrap() else {
                panic!("expected import")
            };
            assert!(engine.lock().unwrap().store.is_imported(&thread).unwrap());
            assert_eq!(fs::read(&path).unwrap(), source.as_bytes());
            assert_eq!(
                engine
                    .lock()
                    .unwrap()
                    .store
                    .original(&format!("ImportedSessions/{provider}/{id}.jsonl"))
                    .unwrap()
                    .unwrap(),
                source.as_bytes()
            );
        }
    }
    #[::core::prelude::v1::test]
    fn worker_real_api_rejects_changed_source_after_review() {
        let fixture = FixtureDirectory::new();
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&fixture.0.join("rust/state.sqlite")).unwrap(),
        )));
        let path = fixture.0.join("claude.jsonl");
        let source = json!({"sessionId":uuid::Uuid::new_v4().to_string(),"cwd":"/synthetic","uuid":"message-one","type":"user","message":{"role":"user","content":"before"}}).to_string();
        fs::write(&path, source).unwrap();
        let mut api = |method: &str, params| call(&engine, method, params);
        let Outcome::Preview(preview) = run(
            &mut api,
            Action::Preview(Selection {
                path: path.clone(),
                provider: "claude".into(),
                project: None,
            }),
        )
        .unwrap() else {
            panic!("preview")
        };
        fs::write(&path, b"changed after review").unwrap();
        assert!(run(&mut api, Action::Import(preview)).is_err());
        assert!(
            engine
                .lock()
                .unwrap()
                .store
                .summaries("", true)
                .unwrap()
                .is_empty()
        );
    }
}
