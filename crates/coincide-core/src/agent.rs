//! Owned provider processes and bounded JSON transports.
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Read, Write},
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::mpsc::{self, Receiver, Sender},
    thread,
    time::{Duration, Instant},
};

#[path = "provider_acp.rs"]
mod acp;
#[path = "provider_claude.rs"]
mod claude;
#[path = "provider_grok.rs"]
mod grok;
#[path = "provider_images.rs"]
mod images;
#[path = "provider_transport.rs"]
mod transport;
pub use images::{ImageAttachment, validate_images};

/// Protocol selection is separate from executable discovery and account selection.
/// Launches inherit the caller's environment; no adapter switches accounts or permissions.
#[derive(Clone, Debug)]
pub enum Provider {
    Codex,
    Claude,
    Grok,
    /// An explicitly configured ACP v1 server. Provider-specific discovery, login,
    /// modes and extensions are not implied by support for its wire protocol.
    AcpV1 {
        arguments: Vec<String>,
    },
}

impl Provider {
    pub fn supported_names() -> &'static [&'static str] {
        &["codex", "claude", "grok"]
    }
    pub fn from_name(name: &str) -> Result<Self> {
        match name {
            "codex" => Ok(Self::Codex),
            "claude" => Ok(Self::Claude),
            "grok" => Ok(Self::Grok),
            "cursor" => bail!(
                "Cursor requires an isolated configuration before its Rust adapter can run without changing the existing app's model defaults"
            ),
            "opencode" => bail!(
                "OpenCode requires its authenticated HTTP/SSE transport; the Rust adapter is not connected yet"
            ),
            "antigravity" => bail!(
                "Antigravity requires its private signed-in profile, runtime and ACP extensions; the Rust adapter is not connected yet"
            ),
            _ => bail!("Unknown provider: {name}"),
        }
    }
    pub fn id(&self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
            Self::Grok => "grok",
            Self::AcpV1 { .. } => "acp",
        }
    }
}

pub struct Launch {
    pub executable: PathBuf,
    pub cwd: PathBuf,
    pub session: Option<String>,
    pub prompt: String,
    pub model: Option<String>,
}
#[derive(Debug)]
pub enum Event {
    Session(String),
    Frame(Value),
    Finished,
    Failed(String),
}
pub enum Control {
    Stop,
    Reply { id: Value, result: Value },
}
pub struct Session {
    pub events: Receiver<Event>,
    control: Sender<Control>,
}
impl Session {
    pub fn start(launch: Launch) -> Self {
        Self::start_with(Provider::Codex, launch)
    }
    pub fn start_with(provider: Provider, launch: Launch) -> Self {
        Self::start_with_images(provider, launch, Vec::new())
    }
    /// Images are validated/materialized by the caller before launch. Existing
    /// text-only callers keep the same Launch and Session interfaces.
    pub fn start_with_images(
        provider: Provider,
        launch: Launch,
        images: Vec<ImageAttachment>,
    ) -> Self {
        let (events_tx, events) = mpsc::channel();
        let (control, commands) = mpsc::channel();
        thread::spawn(move || {
            let result = validate_images(&provider, &images).and_then(|()| match provider {
                Provider::Codex => run(launch, images, commands, &events_tx),
                Provider::Claude => claude::run(launch, images, commands, &events_tx),
                Provider::Grok => grok::run(launch, images, commands, &events_tx),
                Provider::AcpV1 { arguments } => {
                    acp::run(launch, arguments, images, commands, &events_tx)
                }
            });
            if let Err(e) = result {
                let _ = events_tx.send(Event::Failed(e.to_string()));
            }
        });
        Self { events, control }
    }
    pub fn stop(&self) {
        let _ = self.control.send(Control::Stop);
    }
    pub fn reply(&self, id: Value, result: Value) -> Result<()> {
        Ok(self.control.send(Control::Reply { id, result })?)
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.stop();
    }
}
struct OwnedChild(Child);
impl OwnedChild {
    fn spawn(command: &mut Command) -> Result<Self> {
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            // A dedicated group lets cancellation terminate tools and shells too.
            command.process_group(0);
        }
        Ok(Self(command.spawn()?))
    }
}
impl Drop for OwnedChild {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            // Only groups created by OwnedChild::spawn are owned here. Negative
            // PID targets this child's process group, never the host app's group.
            if let Ok(pid) = i32::try_from(self.0.id()) {
                unsafe {
                    libc::kill(-pid, libc::SIGKILL);
                }
            }
        }
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn request(id: u64, method: &str, params: Value) -> Value {
    json!({"id":id,"method":method,"params":params})
}

fn run(
    launch: Launch,
    images: Vec<ImageAttachment>,
    commands: Receiver<Control>,
    events: &Sender<Event>,
) -> Result<()> {
    let image_paths = images
        .iter()
        .map(|image| image.path().to_path_buf())
        .collect::<Vec<_>>();
    drop(images);
    let mut transport = transport::Transport::spawn(&launch, &["app-server".into()], &[])?;
    transport.write(&request(
        1,
        "initialize",
        json!({"clientInfo":{"name":"coincide","title":"Coincide","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}),
    ))?;
    let started = Instant::now();
    let mut stage = 1;
    let mut completed = false;
    loop {
        while let Ok(command) = commands.try_recv() {
            match command {
                Control::Stop => {
                    events.send(Event::Finished)?;
                    return Ok(());
                }
                Control::Reply { id, result } => {
                    transport.write(&json!({"id":id,"result":result}))?
                }
            }
        }
        if completed {
            if transport.is_flushed()? {
                events.send(Event::Finished)?;
                return Ok(());
            }
            thread::sleep(Duration::from_millis(10));
            continue;
        }
        if stage < 4 && started.elapsed() > Duration::from_secs(120) {
            bail!("Codex startup timed out");
        }
        if let Some(frame) = transport.next()? {
            if frame.get("error").is_some() && frame.get("id").is_some() {
                bail!("Codex rejected request: {}", frame["error"]);
            }
            if frame["id"].as_u64() == Some(stage) && frame.get("result").is_some() {
                match stage {
                    1 => {
                        transport.write(&json!({"method":"initialized"}))?;
                        let mut params = json!({"cwd":launch.cwd,"approvalPolicy":"untrusted","sandbox":"read-only"});
                        if let Some(model) = &launch.model {
                            params["model"] = json!(model);
                        }
                        let method = if let Some(session) = &launch.session {
                            params["threadId"] = json!(session);
                            params["excludeTurns"] = json!(true);
                            "thread/resume"
                        } else {
                            "thread/start"
                        };
                        transport.write(&request(2, method, params))?;
                    }
                    2 => {
                        let id = frame["result"]["thread"]["id"]
                            .as_str()
                            .context("Codex returned no thread ID")?;
                        events.send(Event::Session(id.into()))?;
                        transport.write(&request(
                            3,
                            "turn/start",
                            turn_params(id, &launch, &image_paths),
                        ))?;
                    }
                    _ => {}
                }
                stage += 1;
            } else if frame["method"] == "turn/completed" {
                ensure!(stage >= 3, "Codex completed a turn before it was started");
                if frame["params"]["turn"]["status"] == "failed" {
                    bail!("Codex turn failed: {}", frame["params"]["turn"]["error"]);
                }
                ensure!(
                    matches!(
                        frame["params"]["turn"]["status"].as_str(),
                        Some("completed" | "interrupted")
                    ),
                    "Codex returned an invalid turn completion status"
                );
                completed = true;
            } else {
                events.send(Event::Frame(frame))?;
            }
        }
    }
}
fn turn_params(id: &str, launch: &Launch, image_paths: &[PathBuf]) -> Value {
    let mut input = Vec::new();
    if !launch.prompt.is_empty() {
        input.push(json!({"type":"text","text":launch.prompt}));
    }
    input.extend(
        image_paths
            .iter()
            .map(|path| json!({"type":"localImage","path":path})),
    );
    let mut v = json!({"threadId":id,"cwd":launch.cwd,"input":input,"approvalPolicy":"untrusted","approvalsReviewer":"user","sandboxPolicy":{"type":"readOnly"}});
    if let Some(model) = &launch.model {
        v["model"] = json!(model);
    }
    v
}

/// Swift encodes dictionaries whose key is an enum as alternating key/value arrays.
/// Accept both representations; never replace other providers' session references.
pub fn provider_session(thread: &Value, provider: &str) -> Option<String> {
    provider_reference(thread, provider)?["sessionID"]
        .as_str()
        .map(str::to_owned)
}

fn provider_reference<'a>(thread: &'a Value, provider: &str) -> Option<&'a Value> {
    let sessions = &thread["sessions"];
    if let Some(array) = sessions.as_array() {
        array
            .as_chunks::<2>()
            .0
            .iter()
            .find(|pair| pair[0] == provider)
            .map(|pair| &pair[1])
    } else {
        sessions.get(provider)
    }
}

/// Missing or malformed progress must replay context rather than silently skip
/// it. The index is into the complete transcript, including non-message items.
pub fn provider_seen_count(thread: &Value, provider: &str) -> usize {
    let Some(reference) = provider_reference(thread, provider) else {
        return 0;
    };
    if reference["sessionID"].as_str().is_none_or(str::is_empty) {
        return 0;
    }
    let count = reference["seenItemCount"]
        .as_u64()
        .and_then(|count| usize::try_from(count).ok());
    let length = thread["items"].as_array().map_or(0, Vec::len);
    count.filter(|count| *count <= length).unwrap_or(0)
}

/// Call only after the turn completed successfully and its transcript is ready
/// to persist. Session creation alone does not prove the prompt was delivered.
/// This never fabricates a missing session or changes another provider/account.
pub fn mark_provider_seen(thread: &mut Value, provider: &str) {
    let count = thread["items"].as_array().map_or(0, Vec::len);
    let sessions = &mut thread["sessions"];
    let reference = if sessions.is_array() {
        let array = sessions.as_array_mut().expect("array checked above");
        array
            .as_chunks_mut::<2>()
            .0
            .iter_mut()
            .find(|pair| pair[0] == provider)
            .map(|pair| &mut pair[1])
    } else {
        sessions.get_mut(provider)
    };
    if let Some(reference) = reference
        && reference.is_object()
        && reference["sessionID"]
            .as_str()
            .is_some_and(|id| !id.is_empty())
    {
        reference["seenItemCount"] = json!(count);
    }
}

pub fn set_provider_session(thread: &mut Value, provider: &str, id: &str) {
    if let Some(array) = thread["sessions"].as_array_mut() {
        for pair in array.as_chunks_mut::<2>().0 {
            if pair[0] == provider {
                pair[1]["sessionID"] = json!(id);
                return;
            }
        }
        array.extend([json!(provider), json!({"sessionID":id,"seenItemCount":0})]);
    } else {
        if !thread["sessions"].is_object() {
            thread["sessions"] = json!({});
        }
        if !thread["sessions"][provider].is_object() {
            thread["sessions"][provider] = json!({"seenItemCount":0});
        }
        thread["sessions"][provider]["sessionID"] = json!(id);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn session_update_preserves_other_accounts_and_future_fields() {
        let mut v = json!({"items":[],"sessions":["claude",{"sessionID":"a"},"codex",{"sessionID":"b","future":42}],"accountSessions":{"codex/other":{"sessionID":"c"}}});
        assert_eq!(provider_session(&v, "codex").as_deref(), Some("b"));
        set_provider_session(&mut v, "codex", "d");
        assert_eq!(v["sessions"][3]["future"], 42);
        assert_eq!(provider_session(&v, "claude").as_deref(), Some("a"));
        assert_eq!(v["accountSessions"]["codex/other"]["sessionID"], "c");
    }
    #[test]
    fn seen_progress_supports_both_encodings_and_preserves_unknown_fields() {
        for sessions in [
            json!({"claude":{"sessionID":"native","seenItemCount":1,"future":{"keep":true}},"codex":{"sessionID":"other","seenItemCount":2}}),
            json!(["claude",{"sessionID":"native","seenItemCount":1,"future":{"keep":true}},"codex",{"sessionID":"other","seenItemCount":2}]),
        ] {
            let mut thread = json!({"items":[{}, {}, {}],"sessions":sessions,"accountSessions":{"claude/other":{"sessionID":"account","seenItemCount":9}}});
            assert_eq!(provider_seen_count(&thread, "claude"), 1);
            set_provider_session(&mut thread, "claude", "native");
            assert_eq!(
                provider_seen_count(&thread, "claude"),
                1,
                "initialization must not mark a queued prompt seen"
            );
            mark_provider_seen(&mut thread, "claude");
            assert_eq!(provider_seen_count(&thread, "claude"), 3);
            assert_eq!(
                provider_reference(&thread, "claude").unwrap()["future"],
                json!({"keep":true})
            );
            assert_eq!(provider_seen_count(&thread, "codex"), 2);
            assert_eq!(
                thread["accountSessions"]["claude/other"]["seenItemCount"],
                9
            );
            let before = thread.clone();
            mark_provider_seen(&mut thread, "missing");
            assert_eq!(thread, before);
        }
    }
    #[test]
    fn newly_created_session_has_no_seen_items_until_success_is_marked() {
        for sessions in [json!({}), json!([])] {
            let mut thread = json!({"items":[{},{}],"sessions":sessions});
            set_provider_session(&mut thread, "claude", "fresh");
            assert_eq!(provider_seen_count(&thread, "claude"), 0);
            mark_provider_seen(&mut thread, "claude");
            assert_eq!(provider_seen_count(&thread, "claude"), 2);
        }
    }
    #[test]
    fn invalid_or_stale_seen_indices_replay_context_instead_of_skipping_it() {
        for value in [
            Value::Null,
            json!(-1),
            json!("2"),
            json!(3),
            json!(u64::MAX),
        ] {
            let thread = json!({"items":[{},{}],"sessions":{"claude":{"sessionID":"native","seenItemCount":value}}});
            assert_eq!(provider_seen_count(&thread, "claude"), 0);
        }
        for reference in [
            json!("opaque"),
            json!({"seenItemCount":1}),
            json!({"sessionID":"","seenItemCount":1}),
        ] {
            let mut thread = json!({"items":[{},{}],"sessions":["claude",reference]});
            let before = thread.clone();
            assert_eq!(provider_seen_count(&thread, "claude"), 0);
            mark_provider_seen(&mut thread, "claude");
            assert_eq!(thread, before);
        }
    }
    #[test]
    fn default_turn_never_grants_full_access() {
        let v = turn_params(
            "test",
            &Launch {
                executable: "codex".into(),
                cwd: "/tmp".into(),
                session: None,
                prompt: "hello".into(),
                model: None,
            },
            &[],
        );
        assert_eq!(v["approvalPolicy"], "untrusted");
        assert_eq!(v["sandboxPolicy"]["type"], "readOnly");
    }
}
