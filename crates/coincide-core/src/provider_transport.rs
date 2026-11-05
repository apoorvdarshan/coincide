//! A process owns its pipes and is reaped even when initialization or decoding fails.
use super::*;
use std::{collections::VecDeque, process::Command, sync::mpsc::SyncSender};

const MAX_OUTBOUND_FRAME: usize = 32 * 1024 * 1024;
const MAX_INBOUND_FRAME: usize = 32 * 1024 * 1024;
const MAX_QUEUED_BYTES: usize = 64 * 1024 * 1024;
const WRITE_DEADLINE: Duration = Duration::from_secs(10);

struct PendingWrite {
    sequence: u64,
    bytes: usize,
    queued: Instant,
}

/// A candidate launched by another Coincide thread must not address that thread's
/// live Swift control server. Provider credentials and configured homes survive.
pub(super) fn isolate_environment(command: &mut Command) {
    let names = std::env::vars_os()
        .map(|(key, _)| key)
        .chain(command.get_envs().map(|(key, _)| key.to_os_string()))
        .collect::<Vec<_>>();
    for name in names {
        if name
            .to_str()
            .is_some_and(|name| name.starts_with("COINCIDE_"))
        {
            command.env_remove(name);
        }
    }
    for name in ["CODEX_SESSION_ID", "CODEX_THREAD_ID", "CODEX_TOOL_CALL_ID"] {
        command.env_remove(name);
    }
    // Removing the variable alone would make the CLI fall back to the running
    // Swift app's default socket. Until this process has its own registered tool
    // bridge, direct it to a unique, deliberately unbound socket instead.
    command.env(
        "COINCIDE_CONTROL_SOCKET",
        std::env::temp_dir().join(format!("coincide-unbound-{}.sock", uuid::Uuid::new_v4())),
    );
}

pub(super) struct Transport {
    child: OwnedChild,
    writes: SyncSender<(u64, Vec<u8>)>,
    written: Receiver<(u64, std::result::Result<(), String>)>,
    pending: VecDeque<PendingWrite>,
    queued_bytes: usize,
    sequence: u64,
    frames: Receiver<std::result::Result<Value, String>>,
}

impl Transport {
    pub(super) fn spawn(launch: &Launch, args: &[String], remove_env: &[&str]) -> Result<Self> {
        Self::spawn_with_environment(launch, args, remove_env, &[])
    }
    pub(super) fn spawn_with_environment(
        launch: &Launch,
        args: &[String],
        remove_env: &[&str],
        environment: &[(std::ffi::OsString, std::ffi::OsString)],
    ) -> Result<Self> {
        Self::spawn_policy(launch, args, remove_env, environment, false)
    }
    pub(super) fn spawn_antigravity(
        launch: &Launch,
        remove_env: &[&str],
        environment: &[(std::ffi::OsString, std::ffi::OsString)],
    ) -> Result<Self> {
        Self::spawn_policy(launch, &[], remove_env, environment, true)
    }
    fn spawn_policy(
        launch: &Launch,
        args: &[String],
        remove_env: &[&str],
        environment: &[(std::ffi::OsString, std::ffi::OsString)],
        antigravity: bool,
    ) -> Result<Self> {
        ensure!(
            launch.cwd.is_dir(),
            "Agent working directory does not exist"
        );
        let mut command = Command::new(&launch.executable);
        isolate_environment(&mut command);
        command
            .args(args)
            .current_dir(&launch.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for key in remove_env {
            command.env_remove(key);
        }
        command.envs(environment.iter().map(|(key, value)| (key, value)));
        let mut child = OwnedChild::spawn(&mut command).context("Unable to launch provider")?;
        let mut stdin = child.0.stdin.take().context("Missing provider stdin")?;
        let stdout = child.0.stdout.take().context("Missing provider stdout")?;
        // A small bounded queue prevents an agent from flooding retained output.
        let (tx, frames) = mpsc::sync_channel(8);
        if let Some(stderr) = child.0.stderr.take() {
            let errors = tx.clone();
            thread::spawn(move || {
                if !antigravity {
                    let _ = std::io::copy(&mut BufReader::new(stderr), &mut std::io::sink());
                    return;
                }
                let mut reader = BufReader::new(stderr);
                loop {
                    let mut line = Vec::new();
                    match reader.by_ref().take(8193).read_until(b'\n', &mut line) {
                        Ok(0) | Err(_) => break,
                        Ok(_) if antigravity_auth_line(&line) => {
                            let _ = errors.send(Err(super::antigravity::AUTH_FAILURE.into()));
                            break;
                        }
                        Ok(n) if n > 8192 => {
                            let _ = errors
                                .send(Err("Antigravity diagnostic exceeds its size limit".into()));
                            break;
                        }
                        _ => {}
                    }
                }
            });
        }
        thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let mut line = Vec::new();
                let result = match reader
                    .by_ref()
                    .take(MAX_INBOUND_FRAME as u64 + 1)
                    .read_until(b'\n', &mut line)
                {
                    Ok(0) => break,
                    Ok(n) if n <= MAX_INBOUND_FRAME => {
                        if line.iter().all(u8::is_ascii_whitespace) {
                            continue;
                        }
                        if antigravity && antigravity_auth_line(&line) {
                            Err(super::antigravity::AUTH_FAILURE.into())
                        } else if antigravity
                            && line.len() <= 8192
                            && !line
                                .iter()
                                .copied()
                                .find(|byte| !byte.is_ascii_whitespace())
                                .is_some_and(|byte| matches!(byte, b'{' | b'['))
                        {
                            continue;
                        } else {
                            serde_json::from_slice(&line)
                                .map_err(|_| "Invalid provider JSON frame".to_owned())
                        }
                    }
                    _ => Err("Invalid or oversized provider frame".into()),
                };
                let failed = result.is_err();
                if tx.send(result).is_err() || failed {
                    break;
                }
            }
        });
        // The worker owning the child never performs blocking pipe writes. Stop
        // and deadlines remain observable even when the agent stops reading stdin.
        let (writes, queued) = mpsc::sync_channel::<(u64, Vec<u8>)>(4);
        let (acknowledge, written) = mpsc::channel();
        thread::spawn(move || {
            while let Ok((sequence, bytes)) = queued.recv() {
                let result = stdin
                    .write_all(&bytes)
                    .and_then(|()| stdin.flush())
                    .map_err(|error| format!("Provider stdin write failed: {error}"));
                let failed = result.is_err();
                if acknowledge.send((sequence, result)).is_err() || failed {
                    break;
                }
            }
        });
        Ok(Self {
            child,
            writes,
            written,
            pending: VecDeque::new(),
            queued_bytes: 0,
            sequence: 0,
            frames,
        })
    }

    pub(super) fn write(&mut self, frame: &Value) -> Result<()> {
        self.poll_writes()?;
        let mut bytes = serde_json::to_vec(frame)?;
        bytes.push(b'\n');
        ensure!(
            bytes.len() <= MAX_OUTBOUND_FRAME,
            "Provider input frame exceeds 32 MiB"
        );
        ensure!(
            self.queued_bytes + bytes.len() <= MAX_QUEUED_BYTES,
            "Provider input queue exceeds 64 MiB"
        );
        self.sequence += 1;
        let pending = PendingWrite {
            sequence: self.sequence,
            bytes: bytes.len(),
            queued: Instant::now(),
        };
        match self.writes.try_send((self.sequence, bytes)) {
            Ok(()) => {
                self.queued_bytes += pending.bytes;
                self.pending.push_back(pending);
                Ok(())
            }
            Err(mpsc::TrySendError::Full(_)) => bail!("Provider input queue is full"),
            Err(mpsc::TrySendError::Disconnected(_)) => bail!("Provider stdin writer disconnected"),
        }
    }

    fn poll_writes(&mut self) -> Result<()> {
        loop {
            match self.written.try_recv() {
                Ok((sequence, result)) => {
                    result.map_err(anyhow::Error::msg)?;
                    let pending = self
                        .pending
                        .pop_front()
                        .context("Unexpected provider write acknowledgement")?;
                    ensure!(
                        pending.sequence == sequence,
                        "Provider write acknowledgement out of order"
                    );
                    self.queued_bytes -= pending.bytes;
                }
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => {
                    bail!("Provider stdin writer disconnected")
                }
            }
        }
        ensure!(
            self.pending
                .front()
                .is_none_or(|write| write.queued.elapsed() < WRITE_DEADLINE),
            "Provider stdin write timed out"
        );
        Ok(())
    }

    /// A provider's terminal response is not success until queued input was sent.
    /// This is nonblocking so cancellation still works while awaiting receipts.
    pub(super) fn is_flushed(&mut self) -> Result<bool> {
        self.poll_writes()?;
        Ok(self.pending.is_empty())
    }

    /// None means no frame yet, not a successful provider completion.
    pub(super) fn next(&mut self) -> Result<Option<Value>> {
        self.poll_writes()?;
        match self.frames.recv_timeout(Duration::from_millis(30)) {
            Ok(Ok(frame)) => Ok(Some(frame)),
            Ok(Err(error)) => bail!("{error}"),
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                bail!("Provider disconnected before completing the turn")
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if let Some(status) = self.child.0.try_wait()? {
                    bail!("Provider exited before completing the turn: {status}");
                }
                Ok(None)
            }
        }
    }
}

pub(super) fn event(events: &Sender<Event>, method: &str, params: Value) -> Result<()> {
    events.send(Event::Frame(json!({"method":method,"params":params})))?;
    Ok(())
}

pub(super) fn delta(events: &Sender<Event>, id: &str, text: &str, reasoning: bool) -> Result<()> {
    if text.is_empty() {
        return Ok(());
    }
    event(
        events,
        if reasoning {
            "item/reasoning/textDelta"
        } else {
            "item/agentMessage/delta"
        },
        json!({"itemId":id,"delta":text}),
    )
}

/// Keep the original frame available for future protocol features without claiming
/// that an unknown notification is a user-visible assistant message.
pub(super) fn raw(events: &Sender<Event>, provider: &str, frame: &Value) -> Result<()> {
    event(
        events,
        "provider/event",
        json!({"provider":provider,"providerFrame":frame}),
    )
}

fn antigravity_auth_line(line: &[u8]) -> bool {
    [
        b"Open the following link to authenticate the ACP server: ".as_slice(),
        b"__COINCIDE_ANTIGRAVITY_AUTH_URL__".as_slice(),
        b"__COINCIDE_ANTIGRAVITY_SIGN_IN_REQUIRED__".as_slice(),
    ]
    .iter()
    .any(|prefix| line.starts_with(prefix))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn isolation_removes_parent_bindings_without_changing_provider_account() {
        let mut command = Command::new("unused");
        command
            .env("COINCIDE_THREAD_ID", "parent-thread")
            .env("COINCIDE_PREVIEW_CONFIG", "/private/parent-browser")
            .env("COINCIDE_CONTROL_SOCKET", "/private/parent.sock")
            .env("CODEX_THREAD_ID", "parent-native-session")
            .env("CLAUDE_CONFIG_DIR", "/fixture/selected-account");
        isolate_environment(&mut command);
        let values = command
            .get_envs()
            .collect::<std::collections::HashMap<_, _>>();
        assert!(values[std::ffi::OsStr::new("COINCIDE_THREAD_ID")].is_none());
        assert!(values[std::ffi::OsStr::new("COINCIDE_PREVIEW_CONFIG")].is_none());
        assert!(values[std::ffi::OsStr::new("CODEX_THREAD_ID")].is_none());
        assert_eq!(
            values[std::ffi::OsStr::new("CLAUDE_CONFIG_DIR")],
            Some(std::ffi::OsStr::new("/fixture/selected-account"))
        );
        let socket = values[std::ffi::OsStr::new("COINCIDE_CONTROL_SOCKET")]
            .unwrap()
            .to_string_lossy();
        assert!(socket.contains("coincide-unbound-"));
        assert!(!socket.contains("parent.sock"));
    }
}
