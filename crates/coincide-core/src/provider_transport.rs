//! A process owns its pipes and is reaped even when initialization or decoding fails.
use super::*;
use std::process::{ChildStdin, Command};

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
    stdin: ChildStdin,
    frames: Receiver<std::result::Result<Value, String>>,
}

impl Transport {
    pub(super) fn spawn(launch: &Launch, args: &[String], remove_env: &[&str]) -> Result<Self> {
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
        let mut child = OwnedChild::spawn(&mut command).context("Unable to launch provider")?;
        let stdin = child.0.stdin.take().context("Missing provider stdin")?;
        let stdout = child.0.stdout.take().context("Missing provider stdout")?;
        if let Some(stderr) = child.0.stderr.take() {
            thread::spawn(move || {
                let _ = std::io::copy(&mut BufReader::new(stderr), &mut std::io::sink());
            });
        }
        let (tx, frames) = mpsc::sync_channel(256);
        thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let mut line = Vec::new();
                let result = match reader
                    .by_ref()
                    .take(4 * 1024 * 1024 + 1)
                    .read_until(b'\n', &mut line)
                {
                    Ok(0) => break,
                    Ok(n) if n <= 4 * 1024 * 1024 => {
                        if line.iter().all(u8::is_ascii_whitespace) {
                            continue;
                        }
                        serde_json::from_slice(&line)
                            .map_err(|_| "Invalid provider JSON frame".to_owned())
                    }
                    _ => Err("Invalid or oversized provider frame".into()),
                };
                let failed = result.is_err();
                if tx.send(result).is_err() || failed {
                    break;
                }
            }
        });
        Ok(Self {
            child,
            stdin,
            frames,
        })
    }

    pub(super) fn write(&mut self, frame: &Value) -> Result<()> {
        write_frame(&mut self.stdin, frame)
    }

    /// None means no frame yet, not a successful provider completion.
    pub(super) fn next(&mut self) -> Result<Option<Value>> {
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
