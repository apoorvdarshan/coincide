//! Existing default-login reuse for an isolated Cursor process. No usage API,
//! credential/profile writes, interactive login or process-global environment mutation.
use anyhow::{Result, bail, ensure};
use std::ffi::OsString;

const TOKEN_LIMIT: usize = 64 * 1024;
const OFFICIAL_ENDPOINT: &str = "https://api2.cursor.sh";

pub(super) struct Authentication {
    // Intentionally no Debug/Serialize/Clone; this value is never a transcript,
    // profile document, public selection or durable credential cache.
    token: Option<OsString>,
    reused_stored_login: bool,
}
impl Authentication {
    pub fn inherited() -> Self {
        Self {
            token: None,
            reused_stored_login: false,
        }
    }
    pub fn resolve(selected_team: Option<u64>) -> Result<Self> {
        let token = crate::provider_configuration::effective_var("CURSOR_AUTH_TOKEN");
        let key = crate::provider_configuration::effective_var("CURSOR_API_KEY");
        let explicit_token = credential_present(token.as_deref())?;
        let explicit_key = !explicit_token && credential_present(key.as_deref())?;
        if explicit_token || explicit_key {
            return Self::explicit(selected_team);
        }
        let store = crate::provider_configuration::effective_var("AGENT_CLI_CREDENTIAL_STORE");
        let endpoint = crate::provider_configuration::effective_var("CURSOR_API_ENDPOINT");
        let base = crate::provider_configuration::effective_var("CURSOR_API_BASE_URL");
        let inputs = Inputs {
            explicit_token,
            explicit_key,
            store: text(store.as_deref())?,
            endpoint: text(endpoint.as_deref())?,
            base_url: text(base.as_deref())?,
            macos: cfg!(target_os = "macos"),
        };
        Self::resolve_with(inputs, selected_team, native_access_token)
    }
    fn resolve_with(
        inputs: Inputs<'_>,
        selected_team: Option<u64>,
        reader: impl FnOnce() -> Result<Option<Vec<u8>>>,
    ) -> Result<Self> {
        // Never substitute stored login for an explicit token/key identity.
        if inputs.explicit_token || inputs.explicit_key {
            return Self::explicit(selected_team);
        }
        match inputs.store {
            None | Some("") | Some("default") => {}
            Some("memory") => bail!(
                "Cursor explicit memory credential store has no login; configure CURSOR_AUTH_TOKEN or CURSOR_API_KEY"
            ),
            Some("file") => bail!(
                "Cursor file credential login reuse is not connected; configure an explicit credential"
            ),
            Some(_) => bail!("Cursor credential store choice is unsupported"),
        }
        ensure!(
            inputs.macos,
            "Cursor existing default login reuse is available only on macOS; configure an explicit credential on this platform"
        );
        for endpoint in [inputs.endpoint, inputs.base_url].into_iter().flatten() {
            ensure!(
                endpoint == OFFICIAL_ENDPOINT || endpoint == "https://api2.cursor.sh/",
                "Cursor stored login cannot be forwarded to a custom or invalid endpoint; configure an explicit credential for that endpoint"
            );
        }
        // Reader errors must not carry OS output, profile paths or credential data.
        let bytes = reader().map_err(|_| anyhow::anyhow!("Cursor existing login is unavailable (missing, denied or timed out); no sign-in was started"))?
            .ok_or_else(|| anyhow::anyhow!("Cursor existing login is unavailable; run cursor-agent login separately or configure an explicit credential"))?;
        let token = validate_token(bytes)?;
        Ok(Self {
            token: Some(token),
            reused_stored_login: true,
        })
    }
    fn explicit(selected_team: Option<u64>) -> Result<Self> {
        ensure!(
            selected_team.is_none(),
            "Cursor selected team belongs to an unproven explicit credential identity; no stored team was inherited"
        );
        Ok(Self::inherited())
    }
    pub(super) fn reused_stored_login(&self) -> bool {
        self.reused_stored_login
    }
    #[cfg(test)]
    pub(super) fn synthetic(bytes: Vec<u8>) -> Result<Self> {
        Ok(Self {
            token: Some(validate_token(bytes)?),
            reused_stored_login: true,
        })
    }
    pub fn append_environment(&self, environment: &mut Vec<(OsString, OsString)>) {
        if let Some(token) = &self.token {
            environment.push(("CURSOR_AUTH_TOKEN".into(), token.clone()));
            // Pin the effective native API target for the implicitly reused
            // login; explicit credential paths retain their existing behavior.
            environment.push(("CURSOR_API_ENDPOINT".into(), OFFICIAL_ENDPOINT.into()));
            environment.push(("CURSOR_API_BASE_URL".into(), OFFICIAL_ENDPOINT.into()));
        }
    }
}
struct Inputs<'a> {
    explicit_token: bool,
    explicit_key: bool,
    store: Option<&'a str>,
    endpoint: Option<&'a str>,
    base_url: Option<&'a str>,
    macos: bool,
}
fn text(value: Option<&std::ffi::OsStr>) -> Result<Option<&str>> {
    value
        .map(|value| {
            value
                .to_str()
                .ok_or_else(|| anyhow::anyhow!("Cursor authentication environment is invalid"))
        })
        .transpose()
}
fn credential_present(value: Option<&std::ffi::OsStr>) -> Result<bool> {
    Ok(text(value)?.is_some_and(|value| !value.trim().is_empty()))
}
fn validate_token(mut bytes: Vec<u8>) -> Result<OsString> {
    // /usr/bin/security -w appends a newline. Do not otherwise normalize or
    // accept embedded whitespace/control characters in credential material.
    let result = (|| {
        ensure!(
            bytes.len() <= TOKEN_LIMIT,
            "Cursor existing login has invalid credential data"
        );
        let text = std::str::from_utf8(&bytes)
            .map_err(|_| anyhow::anyhow!("Cursor existing login has invalid credential data"))?;
        let token = text.strip_suffix('\n').unwrap_or(text);
        ensure!(
            !token.is_empty() && !token.chars().any(|c| c.is_whitespace() || c.is_control()),
            "Cursor existing login has invalid credential data"
        );
        Ok(token.into())
    })();
    bytes.fill(0);
    result
}

#[cfg(not(target_os = "macos"))]
fn native_access_token() -> Result<Option<Vec<u8>>> {
    bail!("Cursor existing login is unavailable on this platform")
}

#[cfg(target_os = "macos")]
fn native_access_token() -> Result<Option<Vec<u8>>> {
    use std::process::{Command, Stdio};
    let mut command = Command::new("/usr/bin/security");
    command
        .args([
            "find-generic-password",
            "-s",
            "cursor-access-token",
            "-a",
            "cursor-user",
            "-w",
        ])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    capture(command, std::time::Duration::from_secs(10)).map(Some)
}

#[cfg(target_os = "macos")]
fn capture(mut command: std::process::Command, limit: std::time::Duration) -> Result<Vec<u8>> {
    use std::{
        io::Read, os::unix::process::CommandExt, process::Child, sync::mpsc, thread, time::Instant,
    };
    struct Reader(Option<thread::JoinHandle<()>>);
    impl Drop for Reader {
        fn drop(&mut self) {
            if let Some(worker) = self.0.take() {
                let panicked = worker.join().is_err();
                assert!(
                    !panicked || thread::panicking(),
                    "Cursor credential reader failed"
                );
            }
        }
    }
    struct Process(Option<Child>);
    impl Process {
        fn stop(&mut self) -> Result<()> {
            let Some(child) = self.0.as_mut() else {
                return Ok(());
            };
            // Only an unreaped child is retained here: its PID cannot have been
            // reused. Never kill an already-reaped PID/process group.
            if let Ok(pid) = i32::try_from(child.id()) {
                unsafe {
                    libc::kill(-pid, libc::SIGKILL);
                }
            }
            let _ = child.kill();
            child
                .wait()
                .map_err(|_| anyhow::anyhow!("Cursor credential reader cleanup unavailable"))?;
            self.0 = None;
            Ok(())
        }
    }
    impl Drop for Process {
        fn drop(&mut self) {
            let _ = self.stop();
        }
    }
    // Reader owner is declared FIRST: unexpected unwinding terminates/reaps the
    // child before joining the pipe reader. No early error detaches either one.
    let mut reader = Reader(None);
    command.process_group(0);
    let mut child =
        Process(Some(command.spawn().map_err(|_| {
            anyhow::anyhow!("Cursor credential reader unavailable")
        })?));
    let output = child
        .0
        .as_mut()
        .and_then(|child| child.stdout.take())
        .ok_or_else(|| anyhow::anyhow!("Cursor credential reader unavailable"))?;
    let (sender, receiver) = mpsc::sync_channel(1);
    reader.0 = Some(
        thread::Builder::new()
            .name("coincide-cursor-login-read".into())
            .spawn(move || {
                let mut bytes = Vec::new();
                let result = output
                    .take((TOKEN_LIMIT + 1) as u64)
                    .read_to_end(&mut bytes)
                    .map(|_| bytes)
                    .map_err(|_| ());
                let _ = sender.send(result);
            })
            .map_err(|_| anyhow::anyhow!("Cursor credential reader unavailable"))?,
    );
    let deadline = Instant::now() + limit;
    let mut bytes = None;
    let mut status = None;
    let result = loop {
        if bytes.is_none() {
            match receiver.try_recv() {
                Ok(Ok(value)) => bytes = Some(value),
                Ok(Err(())) | Err(mpsc::TryRecvError::Disconnected) => {
                    break Err(anyhow::anyhow!("Cursor credential read failed"));
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
        }
        if bytes
            .as_ref()
            .is_some_and(|bytes| bytes.len() > TOKEN_LIMIT)
        {
            break Err(anyhow::anyhow!("Cursor credential read exceeded its bound"));
        }
        if let Some(process) = child.0.as_mut() {
            match process.try_wait() {
                Ok(Some(value)) => {
                    status = Some(value);
                    child.0 = None;
                }
                Ok(None) => {}
                Err(_) => {
                    break Err(anyhow::anyhow!(
                        "Cursor credential reader status unavailable"
                    ));
                }
            }
        }
        if let (Some(_), Some(status)) = (bytes.as_ref(), status) {
            break if status.success() {
                Ok(())
            } else {
                Err(anyhow::anyhow!(
                    "Cursor credential read denied or unavailable"
                ))
            };
        }
        if Instant::now() >= deadline {
            break Err(anyhow::anyhow!("Cursor credential read timed out"));
        }
        thread::sleep(std::time::Duration::from_millis(5));
    };
    // Kill/reap our live child on deadline/overflow before actual reader join.
    // A pipe/TLS cleanup that cannot exit remains an owned provider worker;
    // deadline is not a false acknowledgement of successful shutdown.
    let cleanup = child.stop();
    let joined = reader
        .0
        .take()
        .expect("owned Cursor credential reader")
        .join();
    ensure!(joined.is_ok(), "Cursor credential reader failed");
    cleanup?;
    result?;
    bytes.ok_or_else(|| anyhow::anyhow!("Cursor credential read unavailable"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    fn defaults() -> Inputs<'static> {
        Inputs {
            explicit_token: false,
            explicit_key: false,
            store: None,
            endpoint: None,
            base_url: None,
            macos: true,
        }
    }
    fn assert_blocked(inputs: Inputs<'_>) {
        let reads = Cell::new(0);
        assert!(
            Authentication::resolve_with(inputs, None, || {
                reads.set(reads.get() + 1);
                Ok(Some(b"synthetic-token".to_vec()))
            })
            .is_err()
        );
        assert_eq!(reads.get(), 0);
    }
    #[test]
    fn explicit_token_and_api_key_never_read_or_substitute_stored_login() {
        for token in [false, true] {
            let mut inputs = defaults();
            inputs.explicit_token = token;
            inputs.explicit_key = !token;
            inputs.store = Some("file");
            inputs.endpoint = Some("https://custom.invalid");
            inputs.macos = false;
            let resolved =
                Authentication::resolve_with(inputs, None, || panic!("explicit identity must win"))
                    .unwrap();
            let mut environment = Vec::new();
            resolved.append_environment(&mut environment);
            assert!(environment.is_empty());
        }
    }
    #[test]
    fn memory_file_unknown_store_and_other_platform_never_read_another_login() {
        for store in ["memory", "file", "unknown"] {
            let mut inputs = defaults();
            inputs.store = Some(store);
            assert_blocked(inputs);
        }
        let mut inputs = defaults();
        inputs.macos = false;
        assert_blocked(inputs);
    }
    #[test]
    fn invalid_custom_or_alternate_base_endpoint_is_rejected_before_read() {
        for endpoint in [
            "",
            "http://api2.cursor.sh",
            "https://custom.invalid",
            "https://api2.cursor.sh/x",
            "https://api2.cursor.sh?token=synthetic",
            " https://api2.cursor.sh",
            "https://user@api2.cursor.sh",
        ] {
            let mut inputs = defaults();
            inputs.endpoint = Some(endpoint);
            assert_blocked(inputs);
            let mut inputs = defaults();
            inputs.base_url = Some(endpoint);
            assert_blocked(inputs);
        }
    }
    #[test]
    fn scoped_login_is_only_in_child_environment_with_canonical_target() {
        let mut inputs = defaults();
        inputs.endpoint = Some(OFFICIAL_ENDPOINT);
        inputs.base_url = Some("https://api2.cursor.sh/");
        let before = std::env::var_os("CURSOR_AUTH_TOKEN");
        let resolved = Authentication::resolve_with(inputs, None, || {
            Ok(Some(b"synthetic-private-token\n".to_vec()))
        })
        .unwrap();
        let mut environment = vec![(
            OsString::from("AGENT_CLI_CREDENTIAL_STORE"),
            OsString::from("memory"),
        )];
        resolved.append_environment(&mut environment);
        assert!(
            environment.iter().any(
                |(key, value)| key == "CURSOR_AUTH_TOKEN" && value == "synthetic-private-token"
            )
        );
        assert!(
            environment
                .iter()
                .any(|(key, value)| key == "AGENT_CLI_CREDENTIAL_STORE" && value == "memory")
        );
        assert!(
            environment
                .iter()
                .filter(|(key, _)| key == "CURSOR_API_ENDPOINT" || key == "CURSOR_API_BASE_URL")
                .all(|(_, value)| value == OFFICIAL_ENDPOINT)
        );
        assert_eq!(std::env::var_os("CURSOR_AUTH_TOKEN"), before);
    }
    #[test]
    fn denied_missing_invalid_or_oversized_login_never_exposes_reader_data() {
        let denied = Authentication::resolve_with(defaults(), None, || {
            bail!("synthetic-secret-and-path-must-not-escape")
        })
        .err()
        .unwrap()
        .to_string();
        assert!(!denied.contains("synthetic-secret"));
        assert!(Authentication::resolve_with(defaults(), None, || Ok(None)).is_err());
        for bytes in [
            Vec::new(),
            vec![0xff],
            b"synthetic\nembedded".to_vec(),
            b"synthetic\0token".to_vec(),
            b"synthetic token".to_vec(),
            vec![b'a'; TOKEN_LIMIT + 1],
        ] {
            let error = Authentication::resolve_with(defaults(), None, || Ok(Some(bytes)))
                .err()
                .unwrap()
                .to_string();
            assert!(!error.contains("synthetic"));
        }
    }
    #[test]
    fn explicit_credential_cannot_inherit_selected_team_or_read_other_identity() {
        for token in [false, true] {
            let mut inputs = defaults();
            inputs.explicit_token = token;
            inputs.explicit_key = !token;
            let error = Authentication::resolve_with(inputs, Some(42), || {
                panic!("must not read another account")
            })
            .err()
            .unwrap()
            .to_string();
            assert!(error.contains("unproven explicit credential identity"));
        }
    }
    #[test]
    fn only_successful_stored_login_resolution_proves_selection_provenance() {
        let stored = Authentication::resolve_with(defaults(), Some(42), || {
            Ok(Some(b"synthetic-stored-login".to_vec()))
        })
        .unwrap();
        assert!(stored.reused_stored_login());
        let mut inputs = defaults();
        inputs.explicit_token = true;
        let explicit =
            Authentication::resolve_with(inputs, None, || panic!("no reader for explicit token"))
                .unwrap();
        assert!(!explicit.reused_stored_login());
        assert!(!Authentication::inherited().reused_stored_login());
    }
    #[cfg(target_os = "macos")]
    fn fake_command(script: &str) -> std::process::Command {
        use std::process::{Command, Stdio};
        // Synthetic subprocess only. The production adapter never accepts an
        // executable/script/arguments from this seam or public JSON.
        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", script])
            .env_clear()
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        command
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn owned_capture_kills_and_reaps_synthetic_child_on_expired_deadline() {
        let error = capture(
            fake_command("while :; do :; done"),
            std::time::Duration::ZERO,
        )
        .unwrap_err()
        .to_string();
        assert_eq!(error, "Cursor credential read timed out");
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn owned_capture_bounds_stdout_and_never_includes_it_in_errors() {
        let error = capture(
            fake_command("printf '%065537d' 0"),
            std::time::Duration::from_secs(5),
        )
        .unwrap_err()
        .to_string();
        assert_eq!(error, "Cursor credential read exceeded its bound");
        let error = capture(
            fake_command("printf synthetic-private-data; exit 1"),
            std::time::Duration::from_secs(5),
        )
        .unwrap_err()
        .to_string();
        assert!(!error.contains("synthetic-private-data"));
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn owned_capture_returns_only_bounded_successful_synthetic_stdout() {
        let bytes = capture(
            fake_command("printf 'synthetic-login\\n'"),
            std::time::Duration::from_secs(5),
        )
        .unwrap();
        assert_eq!(bytes, b"synthetic-login\n");
    }
}
