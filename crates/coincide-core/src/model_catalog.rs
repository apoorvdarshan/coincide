//! Explicit, read-only model discovery. Static runtime support remains separate:
//! reported model efforts/speeds do not enable unsupported turn options.
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

const MAX_JOBS: usize = 8;
const MAX_ACTIVE: usize = 2;
const MAX_MODELS: usize = 1000;
const MAX_PAGES: usize = 16;
const MAX_FRAME: usize = 1024 * 1024;
const MAX_OUTPUT: usize = 2 * 1024 * 1024;
const MAX_FRAMES: usize = 2048;
const DEADLINE: Duration = Duration::from_secs(15);

type Completion = (String, Result<Vec<Value>, String>);

struct Job {
    response: Value,
    cancelled: Arc<AtomicBool>,
}
/// Construction does not discover executables, read credentials, or start work.
pub struct ModelCatalog {
    jobs: HashMap<String, Job>,
    order: VecDeque<String>,
    tx: mpsc::SyncSender<Completion>,
    rx: mpsc::Receiver<Completion>,
}
impl Default for ModelCatalog {
    fn default() -> Self {
        let (tx, rx) = mpsc::sync_channel(MAX_JOBS);
        Self {
            jobs: HashMap::new(),
            order: VecDeque::new(),
            tx,
            rx,
        }
    }
}
impl Drop for ModelCatalog {
    fn drop(&mut self) {
        for job in self.jobs.values() {
            job.cancelled.store(true, Ordering::Release);
        }
    }
}
impl ModelCatalog {
    pub fn poll(&mut self) -> bool {
        let mut changed = false;
        for (id, outcome) in self.rx.try_iter() {
            if let Some(job) = self.jobs.get_mut(&id) {
                match outcome {
                    Ok(models) => {
                        job.response["state"] = json!("ready");
                        job.response["models"] = json!(models);
                    }
                    Err(error) => {
                        job.response["state"] = json!("failed");
                        job.response["error"] = json!(error);
                    }
                }
                changed = true;
            }
        }
        changed
    }
    /// `executable` is selected by the host from trusted configuration/discovery,
    /// never accepted from a request, model response, or conversation document.
    pub fn refresh(&mut self, provider: &str, executable: Option<PathBuf>) -> Result<Value> {
        crate::agent::Provider::from_name(provider)?;
        if let Some(job) = self
            .jobs
            .values()
            .find(|job| job.response["provider"] == provider && job.response["state"] == "loading")
        {
            return Ok(job.response.clone());
        }
        let supported = supported(provider);
        ensure!(
            !supported
                || self
                    .jobs
                    .values()
                    .filter(|job| job.response["state"] == "loading")
                    .count()
                    < MAX_ACTIVE,
            "Too many model catalog reads; wait for the current refresh"
        );
        while self.order.len() >= MAX_JOBS {
            let index = self
                .order
                .iter()
                .position(|id| self.jobs[id].response["state"] != "loading")
                .context("Too many pending model catalog reads")?;
            let id = self.order.remove(index).unwrap();
            self.jobs.remove(&id);
        }
        let id = uuid::Uuid::new_v4().to_string();
        let mut response = json!({"requestId":id,"provider":provider,"accountID":"default",
            "state":if supported {"loading"} else {"unsupported"},"provenance":"provider_model_list",
            "authenticationChecked":false,"models":[],"error":null});
        if !supported {
            response["error"] =
                json!("Read-only model discovery is not implemented for this provider/platform");
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        self.jobs.insert(
            id.clone(),
            Job {
                response: response.clone(),
                cancelled: cancelled.clone(),
            },
        );
        self.order.push_back(id.clone());
        if supported {
            let provider = provider.to_owned();
            let tx = self.tx.clone();
            std::thread::spawn(move || {
                let result = executable.context("Provider executable is unavailable; configure or discover its installation first")
                    .and_then(|path| discover(&provider, path, DEADLINE, &cancelled))
                    .map_err(|error| error.to_string());
                let _ = tx.try_send((id, result));
            });
        }
        Ok(response)
    }
    pub fn status(&self, id: &str) -> Result<Value> {
        self.jobs
            .get(id)
            .map(|job| job.response.clone())
            .context("Model catalog request not found or expired")
    }
}

/// Strict public request contract; only the existing default account may be read.
pub fn refresh_provider(params: &Value) -> Result<&str> {
    let fields = params
        .as_object()
        .context("Model refresh request must be an object")?;
    ensure!(
        fields
            .keys()
            .all(|key| matches!(key.as_str(), "provider" | "accountId")),
        "Unsupported model refresh option"
    );
    ensure!(
        crate::composer_selection::default_account(&params["accountId"]),
        "Alternate-account model discovery is unsupported"
    );
    let provider = params["provider"]
        .as_str()
        .context("Provider must be text")?;
    crate::agent::Provider::from_name(provider)?;
    Ok(provider)
}
pub fn status_id(params: &Value) -> Result<&str> {
    let fields = params
        .as_object()
        .context("Model status request must be an object")?;
    ensure!(
        fields.len() == 1 && fields.contains_key("requestId"),
        "Model status requires requestId only"
    );
    let id = params["requestId"]
        .as_str()
        .context("requestId must be text")?;
    ensure!(id.len() <= 128, "Invalid model catalog requestId");
    Ok(id)
}

pub fn supported(provider: &str) -> bool {
    cfg!(unix) && matches!(provider, "codex" | "claude")
}

fn text_field<'a>(entry: &'a Value, field: &str, limit: usize) -> Result<Option<&'a str>> {
    let Some(value) = entry.get(field).filter(|value| !value.is_null()) else {
        return Ok(None);
    };
    let value = value.as_str().context("Invalid model catalog text field")?;
    if value.is_empty() {
        return Ok(None);
    }
    ensure!(
        value.len() <= limit && !value.chars().any(char::is_control),
        "Invalid model catalog text field"
    );
    Ok(Some(value))
}
fn parse_model(entry: &Value) -> Result<Option<Value>> {
    ensure!(entry.is_object(), "Invalid model catalog entry");
    if entry["hidden"] == true {
        return Ok(None);
    }
    let id = text_field(entry, "model", 512)?
        .or(text_field(entry, "id", 512)?)
        .context("Model catalog entry has no ID")?;
    crate::composer_selection::validate_model(id)?;
    let name = text_field(entry, "displayName", 512)?.unwrap_or(id);
    let mut efforts = Vec::new();
    if let Some(values) = entry.get("supportedReasoningEfforts") {
        let values = values.as_array().context("Invalid model efforts")?;
        ensure!(values.len() <= 64, "Too many model efforts");
        for value in values {
            efforts
                .push(text_field(value, "reasoningEffort", 128)?.context("Invalid model effort")?);
        }
    }
    let default_effort = text_field(entry, "defaultReasoningEffort", 128)?;
    let mut speeds = Vec::new();
    if let Some(values) = entry.get("serviceTiers") {
        let values = values.as_array().context("Invalid model service tiers")?;
        ensure!(values.len() <= 32, "Too many model service tiers");
        for value in values {
            let id = text_field(value, "id", 128)?.context("Invalid model service tier")?;
            speeds.push(json!({"id":id,"name":text_field(value,"name",256)?.unwrap_or(id),"detail":text_field(value,"description",2048)?}));
        }
    } else if let Some(values) = entry.get("additionalSpeedTiers") {
        let values = values.as_array().context("Invalid model speed tiers")?;
        ensure!(values.len() <= 32, "Too many model speed tiers");
        for id in values {
            let id = id.as_str().context("Invalid model speed tier")?;
            ensure!(
                !id.is_empty() && id.len() <= 128 && !id.chars().any(char::is_control),
                "Invalid model speed tier"
            );
            speeds.push(json!({"id":id,"name":id,"detail":null}));
        }
    }
    let supports_images = if let Some(values) = entry.get("inputModalities") {
        let values = values
            .as_array()
            .context("Invalid model input modalities")?;
        ensure!(
            values.len() <= 32 && values.iter().all(Value::is_string),
            "Invalid model input modalities"
        );
        Some(values.iter().any(|value| value == "image"))
    } else {
        None
    };
    Ok(Some(
        json!({"id":id,"displayName":name,"reportedEfforts":efforts,"reportedDefaultEffort":default_effort,
        "reportedSpeeds":speeds,"supportsImages":supports_images}),
    ))
}

trait Rpc {
    fn write(&mut self, value: &Value) -> Result<()>;
    fn response(&mut self, id: u64) -> Result<Value>;
}
fn codex_models(rpc: &mut impl Rpc) -> Result<Vec<Value>> {
    rpc.write(&json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"coincide","title":"Coincide","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}}))?;
    rpc.response(1)?;
    rpc.write(&json!({"method":"initialized"}))?;
    let mut cursor: Option<String> = None;
    let mut cursors = HashSet::new();
    let mut models = Vec::new();
    let mut ids = HashSet::new();
    let mut entries = 0usize;
    for page_index in 0..MAX_PAGES {
        let id = page_index as u64 + 2;
        let params = cursor
            .as_ref()
            .map(|cursor| json!({"cursor":cursor}))
            .unwrap_or_else(|| json!({}));
        rpc.write(&json!({"id":id,"method":"model/list","params":params}))?;
        let page = rpc.response(id)?;
        let values = page["data"]
            .as_array()
            .context("Invalid model/list result")?;
        entries = entries
            .checked_add(values.len())
            .context("Too many model entries")?;
        ensure!(entries <= MAX_MODELS, "Model catalog exceeds 1000 entries");
        for entry in values {
            if let Some(model) = parse_model(entry)?
                && ids.insert(model["id"].as_str().unwrap().to_owned())
            {
                models.push(model);
            }
        }
        cursor = match page.get("nextCursor") {
            None | Some(Value::Null) => None,
            Some(Value::String(value))
                if !value.is_empty()
                    && value.len() <= 4096
                    && !value.chars().any(char::is_control) =>
            {
                Some(value.clone())
            }
            _ => bail!("Invalid model catalog cursor"),
        };
        let Some(next) = &cursor else {
            return Ok(models);
        };
        ensure!(
            cursors.insert(next.clone()),
            "Model catalog repeated a pagination cursor"
        );
    }
    bail!("Model catalog exceeds 16 pages")
}

#[cfg(not(unix))]
fn discover(_: &str, _: PathBuf, _: Duration, _: &AtomicBool) -> Result<Vec<Value>> {
    bail!("Bounded model discovery is unsupported on this platform")
}
#[cfg(unix)]
fn discover(
    provider: &str,
    executable: PathBuf,
    timeout: Duration,
    cancelled: &AtomicBool,
) -> Result<Vec<Value>> {
    let mut rpc = ProcessRpc::spawn(provider, executable, timeout, cancelled)?;
    match provider {
        "codex" => codex_models(&mut rpc),
        "claude" => claude_models(&mut rpc),
        _ => bail!("Read-only model discovery is unsupported for this provider"),
    }
}

#[cfg(unix)]
fn claude_models(rpc: &mut ProcessRpc<'_>) -> Result<Vec<Value>> {
    const ID: &str = "coincide-model-catalog";
    rpc.write(
        &json!({"type":"control_request","request_id":ID,"request":{"subtype":"initialize"}}),
    )?;
    let result = loop {
        let frame = rpc.frame()?;
        ensure!(
            frame["type"] != "control_request",
            "Claude requested an action during read-only model discovery"
        );
        if frame["type"] == "control_response" {
            ensure!(
                frame["response"]["request_id"] == ID,
                "Unexpected Claude model discovery response ID"
            );
            ensure!(
                frame["response"]["subtype"] == "success",
                "Claude rejected model discovery; check provider configuration/authentication"
            );
            break frame["response"]["response"].clone();
        }
        ensure!(
            matches!(frame["type"].as_str(), Some("system" | "rate_limit_event")),
            "Unexpected Claude model discovery frame"
        );
    };
    let entries = result["models"]
        .as_array()
        .context("Invalid Claude initialize models")?;
    ensure!(
        entries.len() <= MAX_MODELS,
        "Model catalog exceeds 1000 entries"
    );
    let mut models = Vec::new();
    let mut ids = HashSet::new();
    for entry in entries {
        let id = text_field(entry, "value", 512)?.context("Claude model has no ID")?;
        crate::composer_selection::validate_model(id)?;
        let mut efforts = Vec::new();
        if entry["supportsEffort"] != false
            && let Some(values) = entry.get("supportedEffortLevels")
        {
            let values = values.as_array().context("Invalid Claude model efforts")?;
            ensure!(values.len() <= 64, "Too many Claude model efforts");
            for value in values {
                let value = value.as_str().context("Invalid Claude model effort")?;
                ensure!(
                    !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control),
                    "Invalid Claude model effort"
                );
                efforts.push(value);
            }
        }
        if ids.insert(id.to_owned()) {
            models.push(json!({"id":id,"displayName":text_field(entry,"displayName",512)?.unwrap_or(id),
                "reportedEfforts":efforts,"reportedDefaultEffort":null,"reportedSpeeds":[],"supportsImages":null}));
        }
    }
    Ok(models)
}

#[cfg(unix)]
struct ProcessRpc<'a> {
    child: std::process::Child,
    stdin: std::process::ChildStdin,
    stdout: std::process::ChildStdout,
    buffer: Vec<u8>,
    total: usize,
    frames: usize,
    started: Instant,
    timeout: Duration,
    cancelled: &'a AtomicBool,
}
#[cfg(unix)]
impl Drop for ProcessRpc<'_> {
    fn drop(&mut self) {
        if let Ok(pid) = i32::try_from(self.child.id()) {
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
#[cfg(unix)]
impl<'a> ProcessRpc<'a> {
    fn spawn(
        provider: &str,
        executable: PathBuf,
        timeout: Duration,
        cancelled: &'a AtomicBool,
    ) -> Result<Self> {
        use std::{
            os::{fd::AsRawFd, unix::process::CommandExt},
            process::{Command, Stdio},
        };
        ensure!(
            executable.is_absolute(),
            "Model discovery requires an absolute configured executable"
        );
        ensure!(
            !cancelled.load(Ordering::Acquire),
            "Model discovery cancelled"
        );
        let started = Instant::now();
        let mut command = Command::new(executable);
        match provider {
            "codex" => {
                command.arg("app-server");
            }
            "claude" => {
                command.args([
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
                ]);
                command
                    .env("ENABLE_CLAUDEAI_MCP_SERVERS", "false")
                    .env("CLAUDE_CODE_AUTO_CONNECT_IDE", "0")
                    .env("CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL", "1");
                for key in [
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
                ] {
                    command.env_remove(key);
                }
            }
            _ => bail!("Read-only model discovery is unsupported for this provider"),
        }
        command
            .current_dir(std::env::temp_dir())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0);
        // Same isolation boundary as turn transports: never connect back to the
        // running Swift control server, and do not reuse another Codex thread.
        for key in std::env::vars_os().map(|(key, _)| key) {
            if key.to_str().is_some_and(|key| key.starts_with("COINCIDE_")) {
                command.env_remove(key);
            }
        }
        for key in ["CODEX_SESSION_ID", "CODEX_THREAD_ID", "CODEX_TOOL_CALL_ID"] {
            command.env_remove(key);
        }
        command.env(
            "COINCIDE_CONTROL_SOCKET",
            std::env::temp_dir().join(format!("coincide-unbound-{}.sock", uuid::Uuid::new_v4())),
        );
        let mut child = command
            .spawn()
            .context("Unable to start configured provider model discovery")?;
        let stdin = child.stdin.take();
        let stdout = child.stdout.take();
        // Install ownership before any fallible pipe configuration.
        let mut rpc = Self {
            child,
            stdin: stdin.expect("piped stdin"),
            stdout: stdout.expect("piped stdout"),
            buffer: Vec::new(),
            total: 0,
            frames: 0,
            started,
            timeout,
            cancelled,
        };
        for fd in [rpc.stdin.as_raw_fd(), rpc.stdout.as_raw_fd()] {
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            ensure!(
                flags >= 0
                    && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } >= 0,
                "Unable to bound model discovery pipes"
            );
        }
        rpc.check()?;
        Ok(rpc)
    }
    fn check(&mut self) -> Result<()> {
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
    fn frame(&mut self) -> Result<Value> {
        use std::io::Read;
        loop {
            self.check()?;
            if let Some(end) = self.buffer.iter().position(|byte| *byte == b'\n') {
                ensure!(end < MAX_FRAME, "Model discovery frame exceeds 1 MiB");
                let line = self.buffer.drain(..=end).collect::<Vec<_>>();
                self.frames += 1;
                ensure!(self.frames <= MAX_FRAMES, "Too many model discovery frames");
                return serde_json::from_slice(&line).context("Invalid model discovery JSON frame");
            }
            ensure!(
                self.buffer.len() <= MAX_FRAME,
                "Model discovery frame exceeds 1 MiB"
            );
            let mut chunk = [0u8; 8192];
            match self.stdout.read(&mut chunk) {
                Ok(0) => bail!("Codex model discovery ended before its response"),
                Ok(n) => {
                    self.total += n;
                    ensure!(
                        self.total <= MAX_OUTPUT,
                        "Model discovery output exceeds 2 MiB"
                    );
                    self.buffer.extend_from_slice(&chunk[..n]);
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(5))
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                Err(_) => bail!("Unable to read model discovery response"),
            }
        }
    }
}
#[cfg(unix)]
impl Rpc for ProcessRpc<'_> {
    fn write(&mut self, value: &Value) -> Result<()> {
        use std::io::Write;
        let mut bytes = serde_json::to_vec(value)?;
        bytes.push(b'\n');
        ensure!(bytes.len() <= 8192, "Model discovery request is too large");
        let mut offset = 0;
        while offset < bytes.len() {
            self.check()?;
            match self.stdin.write(&bytes[offset..]) {
                Ok(0) => bail!("Codex model discovery input closed"),
                Ok(n) => offset += n,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(5))
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                Err(_) => bail!("Unable to write model discovery request"),
            }
        }
        Ok(())
    }
    fn response(&mut self, id: u64) -> Result<Value> {
        loop {
            let frame = self.frame()?;
            if frame.get("id").is_some() {
                ensure!(
                    frame.get("method").is_none(),
                    "Codex requested an action during read-only model discovery"
                );
                ensure!(
                    frame["id"].as_u64() == Some(id),
                    "Unexpected model discovery response ID"
                );
                ensure!(
                    frame.get("error").is_none(),
                    "Codex rejected model discovery; check provider configuration/authentication"
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
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct ScriptedRpc {
        responses: VecDeque<Value>,
        writes: Vec<Value>,
    }
    impl Rpc for ScriptedRpc {
        fn write(&mut self, value: &Value) -> Result<()> {
            self.writes.push(value.clone());
            Ok(())
        }
        fn response(&mut self, _: u64) -> Result<Value> {
            self.responses.pop_front().context("fixture exhausted")
        }
    }
    #[test]
    fn paginated_codex_catalog_is_reported_exactly_without_turn_or_auth_calls() {
        let mut rpc = ScriptedRpc {
            responses: VecDeque::from([
                json!({}),
                json!({"data":[{"model":"fixture-a","displayName":"Fixture A","supportedReasoningEfforts":[{"reasoningEffort":"high"}],"defaultReasoningEffort":"high","inputModalities":["text","image"],"serviceTiers":[{"id":"priority","name":"Fast"}]},{"model":"hidden-fixture","hidden":true}],"nextCursor":"page-two"}),
                json!({"data":[{"id":"fixture-b"},{"model":"fixture-a"}],"nextCursor":null}),
            ]),
            writes: vec![],
        };
        let models = codex_models(&mut rpc).unwrap();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0]["id"], "fixture-a");
        assert_eq!(models[0]["reportedEfforts"], json!(["high"]));
        assert_eq!(models[0]["reportedSpeeds"][0]["id"], "priority");
        assert_eq!(models[0]["supportsImages"], true);
        assert_eq!(models[1]["supportsImages"], Value::Null);
        assert_eq!(
            rpc.writes
                .iter()
                .map(|value| value["method"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["initialize", "initialized", "model/list", "model/list"]
        );
        assert_eq!(rpc.writes[3]["params"]["cursor"], "page-two");
    }
    #[test]
    fn pagination_cycles_malformed_catalogs_and_model_limits_fail_without_partial_fallback() {
        for pages in [
            vec![
                json!({}),
                json!({"data":[],"nextCursor":"same"}),
                json!({"data":[],"nextCursor":"same"}),
            ],
            vec![json!({}), json!({"data":[{"model":"bad\nmodel"}]})],
            vec![
                json!({}),
                json!({"data":[{"model":"fixture","supportedReasoningEfforts":false}]}),
            ],
            vec![json!({}), json!({"data":false})],
            vec![
                json!({}),
                json!({"data":vec![json!({"model":"fixture"});1001]}),
            ],
        ] {
            let mut rpc = ScriptedRpc {
                responses: pages.into(),
                writes: vec![],
            };
            assert!(codex_models(&mut rpc).is_err());
            assert!(rpc.writes.iter().all(|value| matches!(
                value["method"].as_str(),
                Some("initialize" | "initialized" | "model/list")
            )));
        }
    }
    #[test]
    fn strict_refresh_contract_never_accepts_paths_accounts_or_turn_options() {
        for params in [
            json!({"provider":"codex","accountId":"named"}),
            json!({"provider":"codex","accountId":false}),
            json!({"provider":"codex","executable":"/injected"}),
            json!({"provider":"codex","effort":null}),
            json!({"provider":"unknown"}),
            json!({"provider":false}),
        ] {
            assert!(refresh_provider(&params).is_err());
        }
        for account in [Value::Null, json!(""), json!("default")] {
            assert_eq!(
                refresh_provider(&json!({"provider":"codex","accountId":account})).unwrap(),
                "codex"
            );
        }
        assert!(status_id(&json!({"requestId":"fixture","provider":"codex"})).is_err());
    }
    #[test]
    fn unsupported_providers_do_not_launch_and_retention_is_bounded() {
        let mut service = ModelCatalog::default();
        let first = service
            .refresh("cursor", Some("/synthetic/never-execute".into()))
            .unwrap();
        assert_eq!(first["state"], "unsupported");
        assert_eq!(first["models"], json!([]));
        assert_eq!(first["authenticationChecked"], false);
        for _ in 0..MAX_JOBS {
            service.refresh("cursor", None).unwrap();
        }
        assert!(
            service
                .status(first["requestId"].as_str().unwrap())
                .is_err()
        );
        assert_eq!(service.jobs.len(), MAX_JOBS);
    }

    #[cfg(unix)]
    fn executable(dir: &std::path::Path, body: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join(format!("fixture-{}", uuid::Uuid::new_v4()));
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        path
    }
    #[cfg(unix)]
    #[test]
    fn codex_subprocess_only_initializes_lists_and_reaps_its_group() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("requests");
        let late = dir.path().join("must-not-exist");
        let path = executable(
            dir.path(),
            &format!(
                r#"
printf '%s\n' "$@" > '{args}'
IFS= read -r line
printf '%s\n' "$line" >> '{log}'
printf '%s\n' '{{"id":1,"result":{{}}}}'
IFS= read -r line
printf '%s\n' "$line" >> '{log}'
IFS= read -r line
printf '%s\n' "$line" >> '{log}'
(sleep 0.2; printf 'leaked' > '{late}') &
printf '%s\n' '{{"id":2,"result":{{"data":[{{"model":"synthetic-exact","displayName":"Synthetic"}}],"nextCursor":null}}}}'
wait
"#,
                args = dir.path().join("args").display(),
                log = log.display(),
                late = late.display()
            ),
        );
        let models = discover(
            "codex",
            path,
            Duration::from_secs(2),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(models[0]["id"], "synthetic-exact");
        assert_eq!(
            std::fs::read_to_string(dir.path().join("args")).unwrap(),
            "app-server\n"
        );
        let requests = std::fs::read_to_string(log)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(requests.len(), 3);
        assert_eq!(requests[0]["method"], "initialize");
        assert_eq!(requests[1]["method"], "initialized");
        assert_eq!(requests[2]["method"], "model/list");
        std::thread::sleep(Duration::from_millis(300));
        assert!(
            !late.exists(),
            "catalog subprocess descendant survived cleanup"
        );
    }
    #[cfg(unix)]
    #[test]
    fn claude_probe_disables_persistence_hooks_mcp_and_ide_without_prompt() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("request");
        let path = executable(
            dir.path(),
            &format!(
                r#"
printf '%s\n' "$@" > '{args}'
printf '%s\n' "$ENABLE_CLAUDEAI_MCP_SERVERS" "$CLAUDE_CODE_AUTO_CONNECT_IDE" "$CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL" > '{env}'
IFS= read -r line
printf '%s\n' "$line" > '{log}'
printf '%s\n' '{{"type":"control_response","response":{{"request_id":"coincide-model-catalog","subtype":"success","response":{{"models":[{{"value":"synthetic-claude","displayName":"Synthetic Claude","supportedEffortLevels":["high"]}}]}}}}}}'
sleep 5
"#,
                args = dir.path().join("args").display(),
                env = dir.path().join("environment").display(),
                log = log.display()
            ),
        );
        let models = discover(
            "claude",
            path,
            Duration::from_secs(2),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(models[0]["id"], "synthetic-claude");
        assert_eq!(models[0]["reportedEfforts"], json!(["high"]));
        assert_eq!(models[0]["reportedDefaultEffort"], Value::Null);
        let args = std::fs::read_to_string(dir.path().join("args")).unwrap();
        assert!(args.contains("--no-session-persistence\n"));
        assert!(args.contains("{\"disableAllHooks\":true}\n"));
        assert!(args.contains("--strict-mcp-config\n"));
        assert_eq!(
            std::fs::read_to_string(dir.path().join("environment")).unwrap(),
            "false\n0\n1\n"
        );
        let request: Value = serde_json::from_str(&std::fs::read_to_string(log).unwrap()).unwrap();
        assert_eq!(request["request"]["subtype"], "initialize");
        assert!(request.get("message").is_none());
    }
    #[cfg(unix)]
    #[test]
    fn process_timeout_invalid_json_oversize_and_provider_error_are_bounded_and_private() {
        let dir = tempfile::tempdir().unwrap();
        for (body, expected) in [
            ("sleep 5", "timed out"),
            (
                "printf '%s\\n' 'not-json'; sleep 5",
                "Invalid model discovery JSON",
            ),
            (
                "printf '%s\\n' '{\"id\":1,\"error\":{\"message\":\"private-synthetic-diagnostic\"}}'; sleep 5",
                "rejected model discovery",
            ),
            ("printf '%1048600s' x; sleep 5", "frame exceeds"),
        ] {
            let path = executable(dir.path(), body);
            let started = Instant::now();
            let error = discover(
                "codex",
                path,
                Duration::from_millis(150),
                &AtomicBool::new(false),
            )
            .unwrap_err()
            .to_string();
            assert!(error.contains(expected), "unexpected error: {error}");
            assert!(!error.contains("private-synthetic-diagnostic"));
            assert!(started.elapsed() < Duration::from_secs(2));
        }
    }
    #[cfg(unix)]
    #[test]
    fn async_catalog_deduplicates_pending_reads_and_keeps_request_identity() {
        let dir = tempfile::tempdir().unwrap();
        let path = executable(dir.path(), "sleep 5");
        let mut service = ModelCatalog::default();
        let first = service.refresh("codex", Some(path.clone())).unwrap();
        let second = service.refresh("codex", Some(path)).unwrap();
        assert_eq!(first["requestId"], second["requestId"]);
        assert_eq!(first["accountID"], "default");
        assert_eq!(first["state"], "loading");
        // Drop cancels the fixture job. No user/provider process is involved.
    }
}
