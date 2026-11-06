//! One-use native setup handoff. Only native UI can mint a sealed plan; the
//! external terminal helper consumes it and owns its child through actual return.
use super::*;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
const TTL: u64 = 120;
const PURPOSE: &str = "native-provider-setup-v1";
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SetupAction {
    Install,
    SignIn,
}
pub struct SetupCommand {
    pub action: SetupAction,
    pub label: &'static str,
    pub display: String,
}
#[derive(Serialize, Deserialize)]
struct Plan {
    source: Value,
    purpose: String,
    nonce: String,
    provider: String,
    action: SetupAction,
    expires: u64,
    revision: Option<String>,
    launch: Binary,
    helper: Binary,
    brew: bool,
}
pub struct SetupHandoff {
    pending: PathBuf,
    receipt: PathBuf,
    script: Option<PathBuf>,
    expires: u64,
    nonce: String,
    source: PathBuf,
}
fn now() -> Result<u64> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs())
}
fn find(names: &[&str]) -> Option<PathBuf> {
    names
        .iter()
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .find(|path| path.is_file())
        .or_else(|| {
            std::env::var_os("PATH")
                .into_iter()
                .flat_map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
                .flat_map(|directory| {
                    names
                        .iter()
                        .filter(|name| !Path::new(name).is_absolute())
                        .map(move |name| directory.join(name))
                })
                .find(|path| path.is_file())
        })
}
fn brew() -> Option<PathBuf> {
    if cfg!(windows) {
        None
    } else {
        find(&[
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
            "/home/linuxbrew/.linuxbrew/bin/brew",
            "brew",
        ])
    }
}
fn login(provider: &str) -> Result<&'static [&'static str]> {
    match provider {
        "claude" => Ok(&["auth", "login"]),
        "codex" | "cursor" | "grok" => Ok(&["login"]),
        "opencode" => Ok(&["auth", "login"]),
        _ => anyhow::bail!("Use this provider's managed account setup"),
    }
}
fn brew_arguments(provider: &str) -> Result<&'static [&'static str]> {
    match provider {
        "claude" => Ok(&["install", "--cask", "claude-code"]),
        "codex" => Ok(&["install", "--cask", "codex"]),
        "cursor" => Ok(&["install", "--cask", "cursor-cli"]),
        "opencode" => Ok(&["install", "opencode"]),
        _ => anyhow::bail!("Use this provider's setup website"),
    }
}
fn installer(provider: &str) -> Result<&'static str> {
    match (cfg!(windows), provider) {
        (true, "claude") => Ok("irm https://claude.ai/install.ps1 | iex"),
        (true, "cursor") => Ok("irm 'https://cursor.com/install?win32=true' | iex"),
        (true, "codex") => Ok("npm install -g @openai/codex"),
        (true, "opencode") => Ok("npm install -g @opencode/cli"),
        (false, "claude") => Ok("curl -fsSL https://claude.ai/install.sh | bash"),
        (false, "codex") => Ok("curl -fsSL https://chatgpt.com/codex/install.sh | sh"),
        (false, "cursor") => Ok("curl https://cursor.com/install -fsS | bash"),
        (false, "opencode") => Ok("curl -fsSL https://opencode.ai/v2/install | bash"),
        _ => anyhow::bail!("Use this provider's setup website"),
    }
}
fn quote(path: &Path) -> String {
    let value = path.to_string_lossy();
    if cfg!(windows) {
        format!("& '{}'", value.replace('\'', "''"))
    } else {
        format!("'{}'", value.replace('\'', "'\"'\"'"))
    }
}
/// Display only: this never creates a plan or grants launch authority.
pub fn setup_commands(provider: &str, executable: Option<&Path>) -> Vec<SetupCommand> {
    let mut commands = Vec::new();
    let install = brew()
        .and_then(|path| {
            brew_arguments(provider)
                .ok()
                .map(|args| format!("{} {}", quote(&path), args.join(" ")))
        })
        .or_else(|| installer(provider).ok().map(str::to_owned));
    if let Some(display) = install {
        commands.push(SetupCommand {
            action: SetupAction::Install,
            label: "Install",
            display,
        });
    }
    if let Ok(arguments) = login(provider) {
        let executable = executable.map(quote).unwrap_or_else(|| {
            if provider == "cursor" {
                "cursor-agent".into()
            } else {
                provider.into()
            }
        });
        commands.push(SetupCommand {
            action: SetupAction::SignIn,
            label: "Sign in",
            display: format!("{executable} {}", arguments.join(" ")),
        });
    }
    commands
}
fn sealed(owner: &Private, payload: &Value) -> Result<Vec<u8>> {
    let bytes = serde_json::to_vec(payload)?;
    let tag = hmac::sign(&owner.key, &bytes);
    Ok(serde_json::to_vec(
        &json!({"payload":payload,"tag":crate::digest_hex::lower_hex(tag.as_ref())}),
    )?)
}
fn authenticated(owner: &Private, path: &Path) -> Result<Value> {
    private(path, false)?;
    ensure!(
        fs::metadata(path)?.len() <= 64 * 1024,
        "Setup handoff exceeds its bound"
    );
    let envelope: Value = serde_json::from_slice(&fs::read(path)?)?;
    let encoded = envelope["tag"].as_str().context("Setup seal is missing")?;
    ensure!(
        encoded.len() == 64 && encoded.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "Invalid setup seal"
    );
    let tag = (0..32)
        .map(|i| u8::from_str_radix(&encoded[i * 2..i * 2 + 2], 16))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    hmac::verify(&owner.key, &serde_json::to_vec(&envelope["payload"])?, &tag)
        .map_err(|_| anyhow::anyhow!("Setup seal is invalid"))?;
    ensure!(
        envelope["payload"]["source"] == owner.source,
        "Setup belongs to another Store"
    );
    Ok(envelope["payload"].clone())
}
fn write(owner: &Private, path: &Path, payload: &Value) -> Result<()> {
    let bytes = sealed(owner, payload)?;
    ensure!(bytes.len() <= 64 * 1024, "Setup handoff exceeds its bound");
    let mut file = open_file(path, true)?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    drop(file);
    private(path, false)
}
fn owner_for(path: &Path) -> Result<Private> {
    private(path, false)?;
    ensure!(
        fs::metadata(path)?.len() <= 64 * 1024,
        "Setup handoff exceeds its bound"
    );
    let untrusted: Value = serde_json::from_slice(&fs::read(path)?)?;
    let source = PathBuf::from(
        untrusted["payload"]["source"]["path"]
            .as_str()
            .context("Setup source missing")?,
    );
    ensure!(
        path.parent() == Some(directory(&source)?.as_path()),
        "Setup path does not belong to its source"
    );
    Private::open_path(&source, false)?.context("Setup authority is missing")
}
fn cleanup_expired(owner: &Private) -> Result<()> {
    for entry in fs::read_dir(&owner.directory)?.take(256) {
        let path = entry?.path();
        let name = path
            .file_stem()
            .and_then(|name| name.to_str())
            .unwrap_or("");
        if !name
            .strip_prefix("setup-")
            .is_some_and(|id| Uuid::parse_str(id).is_ok())
        {
            continue;
        }
        if !matches!(
            path.extension().and_then(|ext| ext.to_str()),
            Some("pending" | "receipt" | "claimed")
        ) {
            continue;
        }
        let Ok(payload) = authenticated(owner, &path) else {
            continue;
        };
        if !matches!(
            payload["purpose"].as_str(),
            Some(PURPOSE | "native-provider-setup-accepted-v1")
        ) || !payload["expires"]
            .as_u64()
            .is_some_and(|expires| now().is_ok_and(|now| expires < now))
        {
            continue;
        }
        let Ok(file) = open_file(&path, false) else {
            continue;
        };
        if file.try_lock().is_err() {
            continue;
        }
        let _ = file.unlock();
        drop(file);
        if path
            .extension()
            .is_some_and(|extension| extension == "pending")
        {
            let script = path.with_extension("command");
            if private(&script, false).is_ok() {
                let _ = fs::remove_file(script);
            }
        }
        let _ = fs::remove_file(path);
    }
    Ok(())
}
impl Engine {
    pub fn prepare_native_provider_setup(
        &self,
        provider: &str,
        action: SetupAction,
        helper: &Path,
    ) -> Result<SetupHandoff> {
        self.require_admissions()?;
        provider_id(provider)?;
        let owner = Private::open(&self.store, true)?.context("Setup authority unavailable")?;
        cleanup_expired(&owner)?;
        let payload = owner.read()?;
        let record = read_record(&payload, provider)?;
        let (launch, use_brew) = match action {
            SetupAction::SignIn => {
                login(provider)?;
                let path = record
                    .as_ref()
                    .and_then(|record| {
                        record
                            .executable
                            .as_ref()
                            .map(|binary| binary.requested.clone())
                    })
                    .or_else(|| default_executable(provider))
                    .context("Install this provider or choose an executable first")?;
                if let Some(record) = &record {
                    validate_environment(&record.environment)?;
                    if let Some(binary) = &record.executable {
                        binary.validate()?;
                    }
                }
                (Binary::capture(&path)?, false)
            }
            SetupAction::Install => {
                installer(provider)?;
                if let Some(path) = brew() {
                    brew_arguments(provider)?;
                    (Binary::capture(&path)?, true)
                } else {
                    let shell = if cfg!(windows) {
                        PathBuf::from(
                            std::env::var_os("SystemRoot")
                                .context("Windows directory unavailable")?,
                        )
                        .join("System32/WindowsPowerShell/v1.0/powershell.exe")
                    } else {
                        PathBuf::from("/bin/sh")
                    };
                    (Binary::capture(&shell)?, false)
                }
            }
        };
        let nonce = Uuid::new_v4().to_string();
        let expires = now()? + TTL;
        let plan = Plan {
            source: owner.source.clone(),
            purpose: PURPOSE.into(),
            nonce: nonce.clone(),
            provider: provider.into(),
            action,
            expires,
            revision: record.map(|record| record.revision),
            launch,
            helper: Binary::capture(helper)?,
            brew: use_brew,
        };
        let pending = owner.directory.join(format!("setup-{nonce}.pending"));
        write(&owner, &pending, &serde_json::to_value(plan)?)?;
        Ok(SetupHandoff {
            receipt: pending.with_extension("receipt"),
            pending,
            script: None,
            expires,
            nonce,
            source: source(&self.store)?.0,
        })
    }
}
impl SetupHandoff {
    pub fn path(&self) -> &Path {
        &self.pending
    }
    /// The receipt acknowledges external ownership, never authentication or completion.
    pub fn wait_for_transfer(&self, allowed: &impl Fn() -> bool) -> Result<()> {
        loop {
            if self.receipt.try_exists()?
                && let Ok(Some(owner)) = Private::open_path(&self.source, false)
            {
                let receipt = authenticated(&owner, &self.receipt)?;
                ensure!(
                    receipt["purpose"] == "native-provider-setup-accepted-v1"
                        && receipt["nonce"] == self.nonce,
                    "Setup receipt does not match"
                );
                return Ok(());
            }
            ensure!(
                allowed(),
                "Setup handoff stopped; check the external terminal before retrying"
            );
            ensure!(
                now()? <= self.expires,
                "Terminal did not acknowledge setup before expiry; check it before retrying"
            );
            std::thread::sleep(Duration::from_millis(100));
        }
    }
    /// macOS Terminal needs a .command entry point. It contains only quoted
    /// helper/handoff paths; no provider command, environment or credential.
    pub fn terminal_script(&mut self, helper: &Path) -> Result<&Path> {
        let script = self.pending.with_extension("command");
        let helper = format!("'{}'", helper.to_string_lossy().replace('\'', "'\"'\"'"));
        let pending = format!(
            "'{}'",
            self.pending.to_string_lossy().replace('\'', "'\"'\"'")
        );
        let mut file = open_file(&script, true)?;
        write!(
            file,
            "#!/bin/sh\nrm -f -- \"$0\"\nexec {helper} --native-provider-setup {pending}\n"
        )?;
        file.sync_all()?;
        drop(file);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&script, fs::Permissions::from_mode(0o700))?;
        }
        self.script = Some(script);
        Ok(self.script.as_deref().unwrap())
    }
}
impl Drop for SetupHandoff {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.pending);
        let _ = fs::remove_file(&self.receipt);
        if let Some(script) = &self.script {
            let _ = fs::remove_file(script);
        }
    }
}
struct Claimed {
    path: PathBuf,
    lease: Option<File>,
}
impl Drop for Claimed {
    fn drop(&mut self) {
        if let Some(lease) = self.lease.take() {
            let _ = lease.unlock();
            drop(lease);
        }
        let _ = fs::remove_file(&self.path);
    }
}
fn consume_with(
    path: &Path,
    helper: &Path,
    run: impl FnOnce(&mut Command) -> Result<i32>,
) -> Result<i32> {
    let owner = owner_for(path)?;
    let plan: Plan = serde_json::from_value(authenticated(&owner, path)?)?;
    ensure!(
        plan.purpose == PURPOSE
            && Uuid::parse_str(&plan.nonce).is_ok()
            && path.file_name()
                == Some(std::ffi::OsStr::new(&format!(
                    "setup-{}.pending",
                    plan.nonce
                ))),
        "Invalid native setup plan"
    );
    ensure!(
        now()? <= plan.expires && plan.expires <= now()? + TTL,
        "Setup request expired"
    );
    ensure!(
        Binary::capture(helper)? == plan.helper,
        "Setup helper changed since native approval"
    );
    plan.launch.validate()?;
    let payload = owner.read()?;
    let record = read_record(&payload, &plan.provider)?;
    ensure!(
        record.as_ref().map(|record| &record.revision) == plan.revision.as_ref(),
        "Provider configuration changed; request setup again"
    );
    let mut command = Command::new(&plan.launch.requested);
    let configuration = if plan.action == SetupAction::SignIn {
        command.args(login(&plan.provider)?);
        record
            .map(|record| {
                let digest =
                    crate::digest_hex::lower_hex(Sha256::digest(serde_json::to_vec(&record)?));
                let path = owner.source["path"]
                    .as_str()
                    .context("Setup source missing")?;
                let stamp = Stamp {
                    source: path.into(),
                    identity: serde_json::from_value(owner.source["identity"].clone())?,
                    provider: plan.provider.clone(),
                    revision: record.revision.clone(),
                    digest,
                };
                Ok::<_, anyhow::Error>(LaunchConfiguration {
                    stamp,
                    record,
                    derived_executable: None,
                    derived_companion: None,
                })
            })
            .transpose()?
    } else {
        if plan.brew {
            command.args(brew_arguments(&plan.provider)?);
        } else if cfg!(windows) {
            command.args(["-NoProfile", "-Command", installer(&plan.provider)?]);
        } else {
            command.args(["-c", installer(&plan.provider)?]);
        }
        None
    };
    let _scope = enter(configuration);
    apply_to_child(&mut command, false)?;
    let claimed = path.with_extension("claimed");
    fs::rename(path, &claimed)?;
    let lease = match open_file(&claimed, false) {
        Ok(lease) => lease,
        Err(error) => {
            let _ = fs::remove_file(&claimed);
            return Err(error);
        }
    };
    let claimed = Claimed {
        path: claimed,
        lease: Some(lease),
    };
    claimed.lease.as_ref().unwrap().try_lock()?;
    write(
        &owner,
        &path.with_extension("receipt"),
        &json!({"source":owner.source,"purpose":"native-provider-setup-accepted-v1","nonce":plan.nonce,"expires":plan.expires}),
    )?;
    drop(owner);
    let result = run(&mut command);
    drop(claimed);
    result
}
pub fn run_native_provider_setup(path: &Path) -> Result<i32> {
    consume_with(
        path,
        &std::env::current_exe()?,
        crate::agent::setup_process::run,
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_setup_consumes_once_and_never_puts_private_values_in_arguments() {
        let (_root, mut engine, binary) = super::super::tests::fixture();
        super::super::tests::save(&mut engine, "codex", &binary, "synthetic-only");
        let handoff = engine
            .prepare_native_provider_setup("codex", SetupAction::SignIn, &binary)
            .unwrap();
        let result = consume_with(handoff.path(), &binary, |command| {
            assert_eq!(command.get_program(), binary.as_os_str());
            assert_eq!(
                command.get_args().collect::<Vec<_>>(),
                vec![std::ffi::OsStr::new("login")]
            );
            assert!(
                command
                    .get_envs()
                    .any(|(key, value)| key == "SYNTHETIC_API_KEY"
                        && value == Some(std::ffi::OsStr::new("synthetic-only")))
            );
            Ok(0)
        })
        .unwrap();
        assert_eq!(result, 0);
        handoff.wait_for_transfer(&|| true).unwrap();
        assert!(consume_with(handoff.path(), &binary, |_| panic!("replay launched")).is_err());
    }
    #[test]
    fn configuration_change_or_forged_handoff_never_invokes_setup_child() {
        let (_root, mut engine, binary) = super::super::tests::fixture();
        super::super::tests::save(&mut engine, "codex", &binary, "first");
        let handoff = engine
            .prepare_native_provider_setup("codex", SetupAction::SignIn, &binary)
            .unwrap();
        super::super::tests::save(&mut engine, "codex", &binary, "second");
        assert!(
            consume_with(handoff.path(), &binary, |_| panic!(
                "stale configuration launched"
            ))
            .is_err()
        );
        let mut envelope: Value =
            serde_json::from_slice(&fs::read(handoff.path()).unwrap()).unwrap();
        envelope["payload"]["provider"] = json!("grok");
        fs::write(handoff.path(), serde_json::to_vec(&envelope).unwrap()).unwrap();
        assert!(consume_with(handoff.path(), &binary, |_| panic!("forged plan launched")).is_err());
        assert!(
            engine
                .execute("providers.setup", &json!({"provider":"codex"}))
                .is_err()
        );
    }
    #[test]
    fn expired_handoff_is_inert_and_its_owned_files_are_cleaned() {
        let (_root, mut engine, binary) = super::super::tests::fixture();
        super::super::tests::save(&mut engine, "codex", &binary, "synthetic");
        let mut handoff = engine
            .prepare_native_provider_setup("codex", SetupAction::SignIn, &binary)
            .unwrap();
        let script = handoff.terminal_script(&binary).unwrap().to_owned();
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        let mut payload = authenticated(&owner, handoff.path()).unwrap();
        payload["expires"] = json!(0);
        fs::remove_file(handoff.path()).unwrap();
        write(&owner, handoff.path(), &payload).unwrap();
        drop(owner);
        assert!(
            consume_with(handoff.path(), &binary, |_| panic!("expired plan launched")).is_err()
        );
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        cleanup_expired(&owner).unwrap();
        assert!(!handoff.path().exists());
        assert!(!script.exists());
    }
}
