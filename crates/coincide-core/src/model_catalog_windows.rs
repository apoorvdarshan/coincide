//! Windows uses the owned threaded transport, never blocking catalog-owner I/O.
use super::*;
pub(super) struct ProcessRpc<'a> {
    transport: crate::agent::CatalogTransport,
    started: Instant,
    timeout: Duration,
    cancelled: &'a AtomicBool,
    total: usize,
    frames: usize,
    pub(super) named_account_admitted: bool,
}
impl<'a> ProcessRpc<'a> {
    pub(super) fn spawn(
        provider: &str,
        executable: PathBuf,
        timeout: Duration,
        cancelled: &'a AtomicBool,
    ) -> Result<Self> {
        Self::spawn_scoped(provider, executable, timeout, cancelled, None)
    }
    pub(super) fn spawn_scoped(
        provider: &str,
        executable: PathBuf,
        timeout: Duration,
        cancelled: &'a AtomicBool,
        named: Option<&NamedBinding>,
    ) -> Result<Self> {
        ensure!(
            executable.is_absolute(),
            "Model discovery requires an absolute configured executable"
        );
        ensure!(
            !cancelled.load(Ordering::Acquire),
            "Model discovery cancelled"
        );
        let (args, remove, environment): (
            Vec<String>,
            Vec<&str>,
            Vec<(std::ffi::OsString, std::ffi::OsString)>,
        ) = match provider {
            "codex" => (
                named.map_or_else(
                    || vec!["app-server".into()],
                    |binding| binding.profile.arguments(),
                ),
                vec![],
                vec![],
            ),
            "claude" => (
                [
                    "--output-format",
                    "stream-json",
                    "--verbose",
                    "--input-format",
                    "stream-json",
                    "--setting-sources=user,project,local",
                    "--no-session-persistence",
                    "--settings",
                    r#"{"disableAllHooks":true}"#,
                    "--strict-mcp-config",
                ]
                .into_iter()
                .map(str::to_owned)
                .collect(),
                vec![
                    "CLAUDECODE",
                    "CLAUDE_CODE_ENTRYPOINT",
                    "CLAUDE_CODE_SESSION_ID",
                    "CLAUDE_CODE_CHILD_SESSION",
                    "CLAUDE_CODE_BRIDGE_SESSION_ID",
                    "CLAUDE_CODE_MESSAGING_SOCKET",
                    "CLAUDE_CODE_MESSAGING_TOKEN",
                    "CLAUDE_CODE_SESSION_ATTENDED",
                    "CLAUDE_CODE_EXECPATH",
                    "CLAUDE_PID",
                    "CLAUDE_EFFORT",
                ],
                [
                    ("ENABLE_CLAUDEAI_MCP_SERVERS", "false"),
                    ("CLAUDE_CODE_AUTO_CONNECT_IDE", "0"),
                    ("CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL", "1"),
                ]
                .into_iter()
                .map(|(k, v)| (k.into(), v.into()))
                .collect(),
            ),
            _ => bail!("Read-only model discovery is unsupported for this provider"),
        };
        if let Some(binding) = named {
            binding.validate()?;
        }
        let launch = crate::agent::Launch {
            executable,
            cwd: named.map_or_else(std::env::temp_dir, |binding| binding.cwd.clone()),
            session: None,
            prompt: String::new(),
            model: None,
        };
        Ok(Self {
            transport: crate::agent::CatalogTransport::spawn(
                &launch,
                &args,
                &remove,
                &environment,
                named.map(|binding| &binding.profile),
            )?,
            started: Instant::now(),
            timeout,
            cancelled,
            total: 0,
            frames: 0,
            named_account_admitted: false,
        })
    }
    fn check(&self) -> Result<()> {
        ensure!(
            !self.cancelled.load(Ordering::Acquire),
            "Model discovery cancelled"
        );
        ensure!(
            self.started.elapsed() < self.timeout,
            "Model discovery timed out"
        );
        Ok(())
    }
    pub(super) fn frame(&mut self) -> Result<Value> {
        loop {
            self.check()?;
            if let Some(frame) = self.transport.next()? {
                let bytes = serde_json::to_vec(&frame)?;
                ensure!(
                    bytes.len() < MAX_FRAME,
                    "Model discovery frame exceeds 1 MiB"
                );
                self.total = self
                    .total
                    .checked_add(bytes.len())
                    .context("Catalog size overflow")?;
                self.frames += 1;
                ensure!(
                    self.total <= MAX_OUTPUT && self.frames <= MAX_FRAMES,
                    "Model discovery exceeded its output bound"
                );
                return Ok(frame);
            }
        }
    }
}
impl Rpc for ProcessRpc<'_> {
    fn write(&mut self, value: &Value) -> Result<()> {
        ensure!(
            serde_json::to_vec(value)?.len() < 8192,
            "Model discovery request is too large"
        );
        self.check()?;
        self.transport.write(value.clone())?;
        while !self.transport.flushed()? {
            self.check()?;
            std::thread::sleep(Duration::from_millis(2));
        }
        Ok(())
    }
    fn response(&mut self, id: u64) -> Result<Value> {
        loop {
            let frame = self.frame()?;
            if frame.get("id").is_some() {
                ensure!(
                    frame.get("method").is_none(),
                    "Codex requested an action during read-only discovery"
                );
                ensure!(
                    frame["id"].as_u64() == Some(id),
                    "Unexpected model discovery response ID"
                );
                ensure!(
                    frame.get("error").is_none(),
                    "Provider rejected model discovery"
                );
                return frame
                    .get("result")
                    .cloned()
                    .context("Missing model discovery result");
            }
            ensure!(
                frame["method"].is_string(),
                "Malformed model discovery notification"
            );
            if self.named_account_admitted {
                profile::validate_notification(&frame)?;
            }
        }
    }
}
