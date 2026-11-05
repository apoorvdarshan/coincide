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
#[path = "provider_transport.rs"]
mod transport;

/// Protocol selection is separate from executable discovery and account selection.
/// Launches inherit the caller's environment; no adapter switches accounts or permissions.
#[derive(Clone, Debug)]
pub enum Provider {
    Codex,
    Claude,
    /// An explicitly configured ACP v1 server. Provider-specific discovery, login,
    /// modes and extensions are not implied by support for its wire protocol.
    AcpV1 {
        arguments: Vec<String>,
    },
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
        let (events_tx, events) = mpsc::channel();
        let (control, commands) = mpsc::channel();
        thread::spawn(move || {
            let result = match provider {
                Provider::Codex => run(launch, commands, &events_tx),
                Provider::Claude => claude::run(launch, commands, &events_tx),
                Provider::AcpV1 { arguments } => acp::run(launch, arguments, commands, &events_tx),
            };
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
fn write_frame(writer: &mut impl Write, value: &Value) -> Result<()> {
    serde_json::to_writer(&mut *writer, value)?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    Ok(())
}
fn request(id: u64, method: &str, params: Value) -> Value {
    json!({"id":id,"method":method,"params":params})
}

fn run(launch: Launch, commands: Receiver<Control>, events: &Sender<Event>) -> Result<()> {
    ensure!(
        launch.cwd.is_dir(),
        "Agent working directory does not exist"
    );
    let mut command = Command::new(&launch.executable);
    transport::isolate_environment(&mut command);
    let mut child = OwnedChild::spawn(
        command
            .arg("app-server")
            .current_dir(&launch.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
    .context("Unable to launch Codex app-server")?;
    let mut stdin = child.0.stdin.take().context("Missing stdin")?;
    let stdout = child.0.stdout.take().context("Missing stdout")?;
    // Drain stderr without ever logging provider output or allowing an unbounded buffer.
    if let Some(stderr) = child.0.stderr.take() {
        thread::spawn(move || {
            let _ = std::io::copy(&mut BufReader::new(stderr), &mut std::io::sink());
        });
    }
    let (tx, rx) = mpsc::sync_channel(256);
    thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        loop {
            let mut line = Vec::new();
            match reader
                .by_ref()
                .take(4 * 1024 * 1024 + 1)
                .read_until(b'\n', &mut line)
            {
                Ok(0) => break,
                Ok(n) if n <= 4 * 1024 * 1024 => {
                    if tx
                        .send(serde_json::from_slice::<Value>(&line).map_err(|e| e.to_string()))
                        .is_err()
                    {
                        break;
                    }
                }
                _ => {
                    let _ = tx.send(Err("Invalid or oversized provider frame".into()));
                    break;
                }
            }
        }
    });
    write_frame(
        &mut stdin,
        &request(
            1,
            "initialize",
            json!({"clientInfo":{"name":"coincide","title":"Coincide","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}),
        ),
    )?;
    let started = Instant::now();
    let mut stage = 1;
    loop {
        while let Ok(command) = commands.try_recv() {
            match command {
                Control::Stop => {
                    events.send(Event::Finished)?;
                    return Ok(());
                }
                Control::Reply { id, result } => {
                    write_frame(&mut stdin, &json!({"id":id,"result":result}))?
                }
            }
        }
        if stage < 4 && started.elapsed() > Duration::from_secs(120) {
            bail!("Codex startup timed out");
        }
        match rx.recv_timeout(Duration::from_millis(30)) {
            Ok(Ok(frame)) => {
                if frame.get("error").is_some() && frame.get("id").is_some() {
                    bail!("Codex rejected request: {}", frame["error"]);
                }
                if frame["id"].as_u64() == Some(stage) && frame.get("result").is_some() {
                    match stage {
                        1 => {
                            write_frame(&mut stdin, &json!({"method":"initialized"}))?;
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
                            write_frame(&mut stdin, &request(2, method, params))?;
                        }
                        2 => {
                            let id = frame["result"]["thread"]["id"]
                                .as_str()
                                .context("Codex returned no thread ID")?;
                            events.send(Event::Session(id.into()))?;
                            write_frame(
                                &mut stdin,
                                &request(3, "turn/start", turn_params(id, &launch)),
                            )?;
                        }
                        _ => {}
                    }
                    stage += 1;
                } else if frame["method"] == "turn/completed" {
                    if frame["params"]["turn"]["status"] == "failed" {
                        bail!("Codex turn failed: {}", frame["params"]["turn"]["error"]);
                    }
                    events.send(Event::Finished)?;
                    return Ok(());
                } else {
                    events.send(Event::Frame(frame))?;
                }
            }
            Ok(Err(error)) => bail!("{error}"),
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                bail!("Codex disconnected before completing the turn")
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if let Some(status) = child.0.try_wait()? {
                    bail!("Codex exited before completing the turn: {status}");
                }
            }
        }
    }
}
fn turn_params(id: &str, launch: &Launch) -> Value {
    let mut v = json!({"threadId":id,"cwd":launch.cwd,"input":[{"type":"text","text":launch.prompt}],"approvalPolicy":"untrusted","approvalsReviewer":"user","sandboxPolicy":{"type":"readOnly"}});
    if let Some(model) = &launch.model {
        v["model"] = json!(model);
    }
    v
}

/// Swift encodes dictionaries whose key is an enum as alternating key/value arrays.
/// Accept both representations; never replace other providers' session references.
pub fn provider_session(thread: &Value, provider: &str) -> Option<String> {
    let sessions = &thread["sessions"];
    if let Some(array) = sessions.as_array() {
        array
            .as_chunks::<2>()
            .0
            .iter()
            .find(|pair| pair[0] == provider)
            .and_then(|pair| pair[1]["sessionID"].as_str())
            .map(str::to_owned)
    } else {
        sessions[provider]["sessionID"].as_str().map(str::to_owned)
    }
}
pub fn set_provider_session(thread: &mut Value, provider: &str, id: &str) {
    let count = thread["items"].as_array().map_or(0, Vec::len);
    if let Some(array) = thread["sessions"].as_array_mut() {
        for pair in array.as_chunks_mut::<2>().0 {
            if pair[0] == provider {
                pair[1]["sessionID"] = json!(id);
                return;
            }
        }
        array.extend([
            json!(provider),
            json!({"sessionID":id,"seenItemCount":count}),
        ]);
    } else {
        if !thread["sessions"].is_object() {
            thread["sessions"] = json!({});
        }
        if !thread["sessions"][provider].is_object() {
            thread["sessions"][provider] = json!({"seenItemCount":count});
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
        );
        assert_eq!(v["approvalPolicy"], "untrusted");
        assert_eq!(v["sandboxPolicy"]["type"], "readOnly");
    }
}
