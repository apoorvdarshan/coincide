//! Native-only executable/environment grants. Settings/import JSON is display
//! data and can never mint these HMAC-authenticated, Store-inode-bound grants.
//! Private environment values are neither Debug nor exposed by any JSON method.
use super::*;
use ring::{
    hmac,
    rand::{SecureRandom, SystemRandom},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    cell::RefCell,
    collections::BTreeMap,
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    process::Command,
};
const LIMIT: usize = 4 * 1024 * 1024;
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Stamp {
    source: PathBuf,
    identity: crate::private_fs::Identity,
    provider: String,
    revision: String,
    digest: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Binary {
    requested: PathBuf,
    canonical: PathBuf,
    link: crate::private_fs::Identity,
    target: crate::private_fs::Identity,
    length: u64,
    modified: u128,
    digest: String,
}
impl Binary {
    fn capture(path: &Path) -> Result<Self> {
        ensure!(path.is_absolute(), "Choose an absolute executable path");
        let canonical = path.canonicalize().context("Executable is unavailable")?;
        let file = File::open(&canonical).context("Executable cannot be opened")?;
        let metadata = file.metadata()?;
        ensure!(
            metadata.is_file() && metadata.len() <= 512 * 1024 * 1024,
            "Executable is not a bounded regular file"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            ensure!(
                metadata.permissions().mode() & 0o111 != 0,
                "File is not executable"
            );
        }
        #[cfg(windows)]
        ensure!(
            canonical
                .extension()
                .and_then(|value| value.to_str())
                .is_some_and(
                    |value| value.eq_ignore_ascii_case("exe") || value.eq_ignore_ascii_case("com")
                ),
            "Choose the native executable, not a command-shell wrapper"
        );
        let mut digest = Sha256::new();
        let mut reader = file.take(512 * 1024 * 1024 + 1);
        let mut buffer = [0u8; 32768];
        loop {
            let n = reader.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            digest.update(&buffer[..n]);
        }
        Ok(Self {
            requested: path.into(),
            canonical: canonical.clone(),
            link: crate::private_fs::identity(path)?,
            target: crate::private_fs::identity(&canonical)?,
            length: metadata.len(),
            modified: metadata
                .modified()?
                .duration_since(std::time::UNIX_EPOCH)?
                .as_nanos(),
            digest: crate::digest_hex::lower_hex(digest.finalize()),
        })
    }
    fn validate_metadata(&self) -> Result<()> {
        let canonical = self.requested.canonicalize()?;
        let metadata = fs::metadata(&canonical)?;
        ensure!(
            canonical == self.canonical
                && crate::private_fs::identity(&self.requested)? == self.link
                && crate::private_fs::identity(&canonical)? == self.target
                && metadata.is_file()
                && metadata.len() == self.length
                && metadata
                    .modified()?
                    .duration_since(std::time::UNIX_EPOCH)?
                    .as_nanos()
                    == self.modified,
            "Approved executable changed; choose and save it again"
        );
        Ok(())
    }
    fn validate(&self) -> Result<()> {
        ensure!(
            Self::capture(&self.requested)? == *self,
            "Approved executable changed; choose and save it again"
        );
        Ok(())
    }
}
#[derive(Clone, Serialize, Deserialize)]
struct Record {
    revision: String,
    executable: Option<Binary>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    companion: Option<Binary>,
    custom: bool,
    environment: BTreeMap<String, String>,
}
/// Native editor data only. Deliberately not Debug or Serialize.
pub struct Snapshot {
    pub executable: Option<PathBuf>,
    pub environment: BTreeMap<String, String>,
    pub baseline: String,
    pub approved: bool,
    /// Imported preferences are native display drafts only, never launch grants.
    pub imported: bool,
}
/// Opaque native prepare/apply proof. Never accepted through agent JSON.
pub struct Prepared {
    source: PathBuf,
    identity: crate::private_fs::Identity,
    provider: String,
    baseline: String,
    record: Record,
}
#[derive(Clone)]
pub(crate) struct LaunchConfiguration {
    stamp: Stamp,
    record: Record,
    profile: Option<accounts::LoginHome>,
    metadata_only: bool,
    derived_executable: Option<Binary>,
    derived_companion: Option<Binary>,
}
thread_local! { static CURRENT: RefCell<Option<LaunchConfiguration>>=const {RefCell::new(None)}; }
pub(crate) struct Scope(Option<LaunchConfiguration>);
impl Drop for Scope {
    fn drop(&mut self) {
        CURRENT.with(|slot| *slot.borrow_mut() = self.0.take());
    }
}
pub(crate) fn enter(configuration: Option<LaunchConfiguration>) -> Scope {
    Scope(CURRENT.with(|slot| std::mem::replace(&mut *slot.borrow_mut(), configuration)))
}
pub(crate) fn current() -> Option<LaunchConfiguration> {
    CURRENT.with(|slot| slot.borrow().clone())
}
pub(crate) fn native_account_matches(selection: &Value) -> bool {
    CURRENT.with(|slot| {
        slot.borrow()
            .as_ref()
            .and_then(|configuration| configuration.profile.as_ref())
            .is_some_and(|profile| profile.matches(selection))
    })
}
pub(crate) fn native_key_profile(provider: &str) -> bool {
    current()
        .as_ref()
        .and_then(|configuration| configuration.profile.as_ref())
        .is_some_and(|profile| profile.is_key_for(provider))
}
pub(crate) fn current_stamp() -> Option<Stamp> {
    CURRENT.with(|slot| slot.borrow().as_ref().map(|value| value.stamp.clone()))
}
pub(crate) fn apply_to_child(command: &mut Command, named: bool) -> Result<()> {
    let Some(configuration) = current() else {
        return Ok(());
    };
    configuration.validate_launch()?;
    configuration
        .derived_companion
        .as_ref()
        .map(Binary::validate)
        .transpose()?;
    if let Some(binary) = configuration
        .derived_executable
        .as_ref()
        .or(configuration.record.executable.as_ref())
    {
        binary.validate()?;
        ensure!(
            Path::new(command.get_program()) == binary.requested
                || Path::new(command.get_program()) == binary.canonical,
            "Child executable differs from the approved provider executable"
        );
    }
    if let Some(profile) = &configuration.profile {
        profile.configure_base(command)?;
    }
    for (key, value) in &configuration.record.environment {
        if named
            && !configuration
                .profile
                .as_ref()
                .is_some_and(|profile| profile.is_key_for(&configuration.stamp.provider))
        {
            ensure!(
                !sensitive_for_profile(key),
                "A named subscription profile cannot accept provider auth, endpoint or proxy overrides"
            );
        }
        command.env(key, value);
    }
    Ok(())
}
fn sensitive_for_profile(key: &str) -> bool {
    let key = key.to_ascii_uppercase();
    [
        "KEY",
        "TOKEN",
        "SECRET",
        "PASSWORD",
        "CREDENTIAL",
        "PROXY",
        "BASE_URL",
        "ENDPOINT",
    ]
    .iter()
    .any(|part| key.contains(part))
        || key.starts_with("OPENAI_")
        || key.starts_with("CODEX_")
}
fn validate_environment(values: &BTreeMap<String, String>) -> Result<()> {
    ensure!(
        values.len() <= 128
            && values
                .iter()
                .map(|(key, value)| key.len() + value.len())
                .sum::<usize>()
                <= 64 * 1024,
        "Environment exceeds its private storage bound"
    );
    let mut folded = std::collections::HashSet::new();
    for (key, value) in values {
        ensure!(
            !key.is_empty()
                && key.len() <= 256
                && key.bytes().enumerate().all(|(i, c)| c == b'_'
                    || c.is_ascii_alphabetic()
                    || (i > 0 && c.is_ascii_digit()))
                && !value.contains('\0'),
            "Environment names must use letters, digits and underscores"
        );
        let upper = key.to_ascii_uppercase();
        ensure!(
            folded.insert(upper.clone()),
            "Duplicate environment variable name"
        );
        ensure!(
            !upper.starts_with("COINCIDE_")
                && !matches!(
                    upper.as_str(),
                    "HOME"
                        | "USERPROFILE"
                        | "CODEX_HOME"
                        | "CLAUDE_CONFIG_DIR"
                        | "GROK_HOME"
                        | "XDG_DATA_HOME"
                        | "XDG_CONFIG_HOME"
                        | "CODEX_SESSION_ID"
                        | "CODEX_THREAD_ID"
                        | "CODEX_TOOL_CALL_ID"
                ),
            "Account homes and Coincide control variables are managed by their own trusted owners"
        );
    }
    Ok(())
}
fn source(store: &Store) -> Result<(PathBuf, crate::private_fs::Identity)> {
    let path = store.resume_source_path()?;
    Ok((path.clone(), crate::private_fs::identity(&path)?))
}
fn directory(path: &Path) -> Result<PathBuf> {
    Ok(path
        .parent()
        .context("Store directory is unavailable")?
        .join(format!(
            ".{}.native-provider-configuration-v1",
            path.file_name()
                .context("Store filename is unavailable")?
                .to_str()
                .context("Store filename is invalid")?
        )))
}
fn private(path: &Path, directory: bool) -> Result<()> {
    #[cfg(windows)]
    {
        return crate::private_fs::windows::verify(path, directory);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let meta = fs::symlink_metadata(path)?;
        ensure!(
            !meta.file_type().is_symlink()
                && if directory {
                    meta.is_dir()
                } else {
                    meta.is_file() && meta.nlink() == 1
                },
            "Invalid private provider configuration path"
        );
        ensure!(
            meta.uid() == unsafe { libc::geteuid() } && meta.mode() & 0o077 == 0,
            "Provider configuration ownership or permissions are unsafe"
        );
        Ok(())
    }
    #[cfg(not(any(unix, windows)))]
    anyhow::bail!("Private provider configuration is unavailable")
}
fn open_file(path: &Path, new: bool) -> Result<File> {
    #[cfg(windows)]
    {
        return crate::private_fs::windows::open_file(path, new);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        Ok(fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(new)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?)
    }
    #[cfg(not(any(unix, windows)))]
    anyhow::bail!("Private provider configuration is unavailable")
}
struct Private {
    directory: PathBuf,
    lease: File,
    key: hmac::Key,
    source: Value,
}
impl Private {
    fn open(store: &Store, create: bool) -> Result<Option<Self>> {
        let (path, _) = source(store)?;
        Self::open_path(&path, create)
    }
    fn open_path(path: &Path, create: bool) -> Result<Option<Self>> {
        ensure!(
            path.is_absolute() && path.is_file(),
            "Provider source is unavailable"
        );
        let path = path.to_path_buf();
        let identity = crate::private_fs::identity(&path)?;
        let directory = directory(&path)?;
        if fs::symlink_metadata(&directory)
            .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound)
        {
            if !create {
                return Ok(None);
            }
            private(path.parent().context("Store directory missing")?, true)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                fs::DirBuilder::new().mode(0o700).create(&directory)?;
            }
            #[cfg(windows)]
            crate::private_fs::windows::create_directory(&directory)?;
        }
        private(path.parent().context("Store directory missing")?, true)?;
        private(&directory, true)?;
        let key_path = directory.join("authority.key");
        let record = directory.join("configuration.json");
        let mut lease = if key_path.try_exists()? {
            open_file(&key_path, false)?
        } else {
            ensure!(
                create && !record.try_exists()?,
                "Provider configuration authority key is missing"
            );
            let mut file = open_file(&key_path, true)?;
            let mut secret = [0u8; 32];
            SystemRandom::new()
                .fill(&mut secret)
                .map_err(|_| anyhow::anyhow!("Could not create provider configuration key"))?;
            file.write_all(&secret)?;
            file.sync_all()?;
            secret.fill(0);
            file
        };
        private(&key_path, false)?;
        lease
            .try_lock()
            .context("Provider configuration is busy in another owner")?;
        ensure!(
            lease.metadata()?.len() == 32,
            "Invalid provider configuration key"
        );
        use std::io::{Seek, SeekFrom};
        lease.seek(SeekFrom::Start(0))?;
        let mut secret = [0u8; 32];
        lease.read_exact(&mut secret)?;
        let key = hmac::Key::new(hmac::HMAC_SHA256, &secret);
        secret.fill(0);
        Ok(Some(Self {
            directory,
            lease,
            key,
            source: json!({"path":path,"identity":identity,"version":1}),
        }))
    }
    fn read(&self) -> Result<Value> {
        let path = self.directory.join("configuration.json");
        if !path.try_exists()? {
            return Ok(json!({"source":self.source,"providers":{},"sessions":{}}));
        }
        private(&path, false)?;
        ensure!(
            fs::metadata(&path)?.len() <= LIMIT as u64,
            "Provider configuration exceeds its bound"
        );
        let bytes = fs::read(&path)?;
        let envelope: Value =
            serde_json::from_slice(&bytes).context("Private provider configuration is invalid")?;
        let payload = serde_json::to_vec(&envelope["payload"])?;
        let tag = envelope["tag"]
            .as_str()
            .context("Provider configuration seal missing")?;
        ensure!(
            tag.len() == 64 && tag.bytes().all(|byte| byte.is_ascii_hexdigit()),
            "Invalid provider configuration seal"
        );
        let tag = (0..32)
            .map(|i| u8::from_str_radix(&tag[i * 2..i * 2 + 2], 16))
            .collect::<std::result::Result<Vec<_>, _>>()?;
        hmac::verify(&self.key, &payload, &tag)
            .map_err(|_| anyhow::anyhow!("Provider configuration seal is invalid"))?;
        ensure!(
            envelope["payload"]["source"] == self.source,
            "Provider configuration belongs to another Store"
        );
        Ok(envelope["payload"].clone())
    }
    fn write(&self, payload: &Value) -> Result<()> {
        let data = serde_json::to_vec(payload)?;
        let tag = hmac::sign(&self.key, &data);
        let bytes = serde_json::to_vec(
            &json!({"payload":payload,"tag":crate::digest_hex::lower_hex(tag.as_ref())}),
        )?;
        ensure!(
            bytes.len() <= LIMIT,
            "Provider configuration exceeds its bound"
        );
        let temporary = self.directory.join(format!(".save-{}", Uuid::new_v4()));
        let mut file = open_file(&temporary, true)?;
        let result = (|| -> Result<()> {
            file.write_all(&bytes)?;
            file.sync_all()?;
            private(&temporary, false)?;
            let identity = crate::private_fs::identity(&temporary)?;
            // The Windows private-file opener deliberately denies delete sharing.
            // Close only this new payload handle before rename; the authority-key
            // lease stays locked and nonreplaceable for the entire transaction.
            drop(file);
            private(&temporary, false)?;
            ensure!(
                crate::private_fs::identity(&temporary)? == identity,
                "Provider configuration payload changed before commit"
            );
            fs::rename(&temporary, self.directory.join("configuration.json"))?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }
}
impl Drop for Private {
    fn drop(&mut self) {
        let _ = self.lease.unlock();
    }
}
fn read_record(payload: &Value, provider: &str) -> Result<Option<Record>> {
    payload["providers"]
        .get(provider)
        .map(|value| {
            serde_json::from_value(value.clone()).context("Private provider record is invalid")
        })
        .transpose()
}
/// Public JSON responses never return legacy provider environment values. Native
/// editing reads its separate typed private store; raw imported documents stay intact.
fn redact_provider_environment(provider: &mut Value) {
    if let Some(fields) = provider.as_object_mut() {
        fields.remove("environment");
        if let Some(accounts) = fields.get_mut("accounts").and_then(Value::as_array_mut) {
            for account in accounts {
                if let Some(fields) = account.as_object_mut() {
                    fields.remove("environment");
                }
            }
        }
    }
}
pub(super) fn public_settings(mut settings: Value) -> Value {
    match settings.get_mut("providers") {
        Some(Value::Object(providers)) => {
            for provider in providers.values_mut() {
                redact_provider_environment(provider);
            }
        }
        Some(Value::Array(providers)) => {
            for provider in providers {
                redact_provider_environment(provider);
            }
        }
        _ => {}
    }
    settings
}
fn legacy_provider<'a>(settings: &'a Value, provider: &str) -> Option<&'a Value> {
    let providers = &settings["providers"];
    if let Some(providers) = providers.as_object() {
        providers.get(provider)
    } else {
        providers
            .as_array()?
            .chunks(2)
            .find(|pair| pair.len() == 2 && pair[0].as_str() == Some(provider))
            .map(|pair| &pair[1])
    }
}
#[cfg(test)]
fn legacy_environment(settings: &Value, provider: &str) -> Option<Value> {
    legacy_provider(settings, provider)?
        .get("environment")
        .cloned()
}
/// Retain omitted legacy secrets when clients edit a redacted provider response,
/// including Swift's whole-array dictionary encoding. An explicit environment
/// field remains caller-supplied inert legacy data, never a native launch grant.
pub(super) fn retain_legacy_environment(current: &Value, patch: &Value) -> Result<Value> {
    let mut patch = patch.clone();
    let retain = |id: &str, configuration: &mut Value| -> Result<()> {
        let Some(fields) = configuration.as_object_mut() else {
            return Ok(());
        };
        let previous = legacy_provider(current, id);
        if !fields.contains_key("environment")
            && let Some(environment) = previous
                .and_then(|provider| provider.get("environment"))
                .cloned()
        {
            fields.insert("environment".into(), environment);
        }
        if let Some(accounts) = fields.get_mut("accounts").and_then(Value::as_array_mut) {
            for account in accounts {
                let Some(fields) = account.as_object_mut() else {
                    continue;
                };
                if fields.contains_key("environment") {
                    continue;
                }
                let Some(id) = fields.get("id").and_then(Value::as_str) else {
                    continue;
                };
                let mut matching = previous
                    .and_then(|provider| provider["accounts"].as_array())
                    .into_iter()
                    .flatten()
                    .filter(|account| account["id"] == id);
                let saved = matching.next();
                ensure!(
                    matching.next().is_none(),
                    "Saved account identity is ambiguous; preserve its raw environment before editing"
                );
                if let Some(environment) = saved
                    .and_then(|account| account.get("environment"))
                    .cloned()
                {
                    fields.insert("environment".into(), environment);
                }
            }
        }
        Ok(())
    };
    match patch.get_mut("providers") {
        Some(Value::Object(providers)) => {
            for (id, configuration) in providers {
                retain(id, configuration)?;
            }
        }
        Some(Value::Array(providers)) => {
            for pair in providers.chunks_mut(2) {
                if pair.len() == 2 {
                    let (id, configuration) = pair.split_first_mut().unwrap();
                    if let Some(id) = id.as_str() {
                        retain(id, &mut configuration[0])?;
                    }
                }
            }
        }
        _ => {}
    }
    Ok(patch)
}

fn provider_id(provider: &str) -> Result<()> {
    agent::Provider::from_name(provider)?;
    ensure!(
        matches!(
            provider,
            "codex" | "claude" | "cursor" | "grok" | "opencode" | "antigravity"
        ),
        "Unsupported provider"
    );
    Ok(())
}
fn legacy_snapshot(store: &Store, provider: &str) -> Result<Snapshot> {
    let settings = store
        .document("settings.json")?
        .unwrap_or_else(|| json!({}));
    let providers = &settings["providers"];
    let entry = if providers.is_null() {
        &Value::Null
    } else if let Some(providers) = providers.as_object() {
        providers.get(provider).unwrap_or(&Value::Null)
    } else {
        let providers = providers
            .as_array()
            .context("Imported provider preferences are malformed")?;
        let (pairs, remainder) = providers.as_chunks::<2>();
        ensure!(
            remainder.is_empty() && pairs.iter().all(|pair| pair[0].is_string()),
            "Imported provider preferences are malformed"
        );
        let mut entries = pairs.iter().filter(|pair| pair[0] == provider);
        let entry = entries.next().map(|pair| &pair[1]).unwrap_or(&Value::Null);
        ensure!(
            entries.next().is_none(),
            "Imported provider preferences contain duplicate entries"
        );
        entry
    };
    ensure!(
        entry.is_null() || entry.is_object(),
        "Imported provider preferences are malformed"
    );
    let executable = entry
        .get("executablePath")
        .filter(|value| !value.is_null())
        .map(|value| {
            let value = value
                .as_str()
                .context("Imported executable path must be text")?;
            ensure!(
                value.len() <= 4096 && !value.contains('\0'),
                "Imported executable path is invalid"
            );
            Ok::<_, anyhow::Error>((!value.trim().is_empty()).then(|| PathBuf::from(value)))
        })
        .transpose()?
        .flatten();
    let environment = if entry["environment"].is_null() {
        BTreeMap::new()
    } else {
        let values = entry["environment"]
            .as_object()
            .context("Imported environment must be a name/value dictionary")?;
        ensure!(
            values.len() <= 128,
            "Imported environment exceeds the editor bound"
        );
        let values = values
            .iter()
            .map(|(key, value)| {
                Ok((
                    key.clone(),
                    value
                        .as_str()
                        .context("Imported environment values must be text")?
                        .to_owned(),
                ))
            })
            .collect::<Result<BTreeMap<_, _>>>()?;
        ensure!(
            values
                .iter()
                .map(|(key, value)| key.len() + value.len())
                .sum::<usize>()
                <= 64 * 1024,
            "Imported environment exceeds the editor bound"
        );
        values
    };
    let imported = executable.is_some() || !environment.is_empty();
    Ok(Snapshot {
        executable,
        environment,
        baseline: "unconfigured".into(),
        approved: false,
        imported,
    })
}

fn default_executable(provider: &str) -> Option<PathBuf> {
    let variable = format!("COINCIDE_{}_EXECUTABLE", provider.to_ascii_uppercase());
    std::env::var_os(variable).map(PathBuf::from).or_else(|| {
        crate::provider_catalog::discover_installed_tools()
            .providers
            .into_iter()
            .find(|entry| {
                serde_json::to_value(entry.provider)
                    .ok()
                    .as_ref()
                    .and_then(Value::as_str)
                    == Some(provider)
            })
            .and_then(|entry| entry.executable)
    })
}
impl Engine {
    pub fn native_provider_configuration(&self, provider: &str) -> Result<Snapshot> {
        provider_id(provider)?;
        let record = Private::open(&self.store, false)?
            .map(|owner| owner.read())
            .transpose()?
            .map(|payload| read_record(&payload, provider))
            .transpose()?
            .flatten();
        Ok(match record {
            Some(record) => Snapshot {
                executable: record
                    .executable
                    .filter(|_| record.custom)
                    .map(|binary| binary.requested),
                environment: record.environment,
                baseline: record.revision,
                approved: true,
                imported: false,
            },
            None => legacy_snapshot(&self.store, provider)?,
        })
    }
    pub fn prepare_native_provider_configuration(
        &self,
        provider: &str,
        baseline: &str,
        executable: Option<&Path>,
        environment: BTreeMap<String, String>,
    ) -> Result<Prepared> {
        self.require_admissions()?;
        provider_id(provider)?;
        validate_environment(&environment)?;
        let current = self.native_provider_configuration(provider)?;
        ensure!(
            current.baseline == baseline,
            "Provider configuration changed; reload before saving"
        );
        let binary = if let Some(path) = executable {
            Some(Binary::capture(path)?)
        } else if !environment.is_empty() {
            Some(Binary::capture(&default_executable(provider).context(
                "Choose an executable before configuring its environment",
            )?)?)
        } else {
            None
        };
        let companion = if provider == "antigravity" {
            binary
                .as_ref()
                .map(|binary| {
                    Binary::capture(
                        &binary
                            .canonical
                            .with_file_name(antigravity_companion_name()),
                    )
                })
                .transpose()?
        } else {
            None
        };
        let (source, identity) = source(&self.store)?;
        Ok(Prepared {
            source,
            identity,
            provider: provider.into(),
            baseline: baseline.into(),
            record: Record {
                revision: Uuid::new_v4().to_string(),
                executable: binary,
                companion,
                custom: executable.is_some(),
                environment,
            },
        })
    }
    pub fn apply_native_provider_configuration(&mut self, prepared: Prepared) -> Result<Snapshot> {
        self.require_admissions()?;
        ensure!(
            source(&self.store)? == (prepared.source.clone(), prepared.identity),
            "Provider configuration review belongs to another Store"
        );
        prepared
            .record
            .executable
            .as_ref()
            .map(Binary::validate)
            .transpose()?;
        prepared
            .record
            .companion
            .as_ref()
            .map(Binary::validate)
            .transpose()?;
        let owner = Private::open(&self.store, true)?
            .context("Provider configuration store unavailable")?;
        let mut payload = owner.read()?;
        let baseline = read_record(&payload, &prepared.provider)?
            .map(|record| record.revision)
            .unwrap_or_else(|| "unconfigured".into());
        ensure!(
            baseline == prepared.baseline,
            "Provider configuration changed; drafts were retained"
        );
        payload["providers"][&prepared.provider] = serde_json::to_value(&prepared.record)?;
        self.store
            .mark_native_provider_configuration(&prepared.provider)?;
        owner.write(&payload)?;
        drop(owner);
        self.revision += 1;
        self.native_provider_configuration(&prepared.provider)
    }
    pub(crate) fn provider_launch_configuration(
        &self,
        provider: &str,
    ) -> Result<Option<LaunchConfiguration>> {
        provider_id(provider)?;
        let Some(owner) = Private::open(&self.store, false)? else {
            ensure!(
                !self
                    .store
                    .requires_native_provider_configuration(provider)?,
                "Approved provider configuration is missing; save it again in native Settings before running"
            );
            return Ok(None);
        };
        let payload = owner.read()?;
        let Some(record) = read_record(&payload, provider)? else {
            ensure!(
                !self
                    .store
                    .requires_native_provider_configuration(provider)?,
                "Approved provider configuration is missing; save it again in native Settings before running"
            );
            return Ok(None);
        };
        validate_environment(&record.environment)?;
        record
            .executable
            .as_ref()
            .map(Binary::validate_metadata)
            .transpose()?;
        let (source, identity) = source(&self.store)?;
        let digest = crate::digest_hex::lower_hex(Sha256::digest(serde_json::to_vec(&record)?));
        Ok(Some(LaunchConfiguration {
            stamp: Stamp {
                source,
                identity,
                provider: provider.into(),
                revision: record.revision.clone(),
                digest,
            },
            record,
            profile: None,
            metadata_only: false,
            derived_executable: None,
            derived_companion: None,
        }))
    }
    pub(crate) fn provider_launch_configuration_for_thread(
        &self,
        thread: &Value,
    ) -> Result<Option<LaunchConfiguration>> {
        self.provider_launch_configuration_for_thread_mode(thread, false)
    }
    fn provider_launch_configuration_for_thread_mode(
        &self,
        thread: &Value,
        metadata: bool,
    ) -> Result<Option<LaunchConfiguration>> {
        let provider = text(&thread["selection"], "provider");
        if !crate::composer_selection::default_account(&thread["selection"]["accountID"])
            && (matches!(provider.as_str(), "claude" | "cursor" | "grok" | "opencode")
                || (matches!(provider.as_str(), "codex" | "antigravity")
                    && self.routes_native_provider_account(thread)?))
        {
            let id = thread["id"]
                .as_str()
                .context("Native account thread identity is missing")?;
            ensure!(
                !self.store.is_imported(id)?,
                "Imported conversations cannot use native account authority"
            );
            self.validate_native_account_selection(thread)?;
            let account = thread["selection"]["accountID"]
                .as_str()
                .context("Native account identity must be text")?;
            return self
                .native_account_configuration_mode(&provider, account, metadata)
                .map(Some);
        }
        self.provider_launch_configuration(&provider)
    }
    pub(crate) fn native_provider_scope_for_command(
        &self,
        method: &str,
        params: &Value,
    ) -> Result<Scope> {
        if (method.starts_with("providers.codex.profiles.")
            || matches!(
                method,
                "agent.models.refresh" | "agent.models.status" | "agent.selection.capabilities"
            ))
            && let Some(id) = params["threadId"].as_str()
        {
            let thread = self.store.thread(id)?;
            let same_provider = if method.starts_with("providers.codex.") {
                thread["selection"]["provider"] == "codex"
            } else {
                params["provider"].is_null()
                    || params["provider"] == thread["selection"]["provider"]
            };
            if same_provider
                && !crate::composer_selection::default_account(&thread["selection"]["accountID"])
                && self.routes_native_provider_account(&thread)?
            {
                return Ok(enter(self.provider_launch_configuration_for_thread_mode(
                    &thread,
                    !method.ends_with(".refresh"),
                )?));
            }
        }
        let provider = if method.starts_with("providers.codex.")
            || method.starts_with("usage.codex")
        {
            Some("codex".to_owned())
        } else if matches!(
            method,
            "agent.models.refresh"
                | "agent.models.status"
                | "agent.select"
                | "agent.provider.select"
                | "agent.selection.capabilities"
        ) {
            params["provider"].as_str().map(str::to_owned).or_else(|| {
                params["threadId"]
                    .as_str()
                    .and_then(|id| self.store.thread(id).ok())
                    .and_then(|thread| thread["selection"]["provider"].as_str().map(str::to_owned))
            })
        } else {
            None
        };
        Ok(enter(
            provider
                .as_deref()
                .map(|provider| self.provider_launch_configuration(provider))
                .transpose()?
                .flatten(),
        ))
    }
}
impl LaunchConfiguration {
    pub(crate) fn stamp(&self) -> &Stamp {
        &self.stamp
    }
    pub(crate) fn validate_named_profile(&self, named: bool) -> Result<()> {
        ensure!(
            !named
                || self
                    .profile
                    .as_ref()
                    .is_some_and(|profile| profile.is_key_for(&self.stamp.provider))
                || !self
                    .record
                    .environment
                    .keys()
                    .any(|key| sensitive_for_profile(key)),
            "A named subscription profile cannot accept provider auth, endpoint or proxy overrides"
        );
        Ok(())
    }
    pub(crate) fn validate_launch(&self) -> Result<()> {
        ensure!(
            !self.metadata_only,
            "Account metadata cannot authorize a provider child; capture an owned launch first"
        );
        if let Some(profile) = &self.profile {
            profile.validate()?;
        }
        if self.stamp.provider == "antigravity" && self.record.executable.is_some() {
            self.record
                .companion
                .as_ref()
                .context("Save Antigravity configuration again to approve its runtime helper")?
                .validate()?;
        }
        self.record
            .executable
            .as_ref()
            .map(Binary::validate)
            .transpose()?;
        Ok(())
    }
    pub(crate) fn approved_executable(&self) -> Option<PathBuf> {
        self.record
            .executable
            .as_ref()
            .map(|binary| binary.requested.clone())
    }
    pub(crate) fn executable(&self, fallback: PathBuf) -> PathBuf {
        self.record
            .executable
            .as_ref()
            .map(|binary| binary.requested.clone())
            .unwrap_or(fallback)
    }
}

fn antigravity_companion_name() -> &'static str {
    if cfg!(windows) {
        "localharness_external.exe"
    } else {
        "localharness_external"
    }
}
/// Authorize only the byte-identical private copy made by the Antigravity profile owner.
/// The source configuration stamp remains unchanged and the original pin is revalidated
/// again at spawn. This never grants another provider or an arbitrary copied program.
pub(crate) fn antigravity_runtime_copy(source: &Path, copied: &Path) -> Result<Scope> {
    let mut configuration = current();
    if let Some(configuration) = &mut configuration {
        ensure!(
            configuration.stamp.provider == "antigravity",
            "Runtime copy requires Antigravity configuration"
        );
        let Some(original) = configuration.record.executable.as_ref() else {
            return Ok(enter(Some(configuration.clone())));
        };
        original.validate()?;
        ensure!(
            source == original.requested || source == original.canonical,
            "Runtime copy source differs from approved executable"
        );
        let derived = Binary::capture(copied)?;
        ensure!(
            derived.digest == original.digest && derived.length == original.length,
            "Private runtime copy differs from approved executable"
        );
        let companion = configuration
            .record
            .companion
            .as_ref()
            .context("Approved runtime helper is missing; save configuration again")?;
        companion.validate()?;
        let derived_companion =
            Binary::capture(&copied.with_file_name(antigravity_companion_name()))?;
        ensure!(
            derived_companion.digest == companion.digest
                && derived_companion.length == companion.length,
            "Private runtime helper differs from approved helper"
        );
        configuration.derived_executable = Some(derived);
        configuration.derived_companion = Some(derived_companion);
    }
    Ok(enter(configuration))
}

pub(crate) fn effective_var(name: &str) -> Option<std::ffi::OsString> {
    let configuration = current();
    if let Some(configuration) = &configuration {
        let matches = |key: &&String| {
            if cfg!(windows) {
                key.eq_ignore_ascii_case(name)
            } else {
                key.as_str() == name
            }
        };
        if let Some((_, value)) = configuration
            .record
            .environment
            .iter()
            .find(|(key, _)| matches(key))
        {
            return Some(value.into());
        }
        if let Some(profile) = &configuration.profile {
            return profile.environment_value(name);
        }
    }
    std::env::var_os(name)
}
pub(crate) fn current_executable(fallback: PathBuf) -> PathBuf {
    current()
        .map(|scope| scope.executable(fallback.clone()))
        .unwrap_or(fallback)
}
impl Engine {
    pub(crate) fn native_configuration_session_allowed(
        &self,
        provider: &str,
        thread: &str,
        session: &str,
    ) -> Result<bool> {
        let Some(stamp) = current_stamp() else {
            return Ok(true);
        };
        let Some(owner) = Private::open(&self.store, false)? else {
            return Ok(false);
        };
        let payload = owner.read()?;
        let id = crate::digest_hex::lower_hex(Sha256::digest(format!(
            "{provider}\0{thread}\0{session}"
        )));
        Ok(payload["sessions"][id] == serde_json::to_value(stamp)?)
    }
    pub(crate) fn remember_native_configuration_session(
        &self,
        provider: &str,
        thread: &str,
        session: &str,
        stamp: Option<&Stamp>,
    ) -> Result<()> {
        let Some(stamp) = stamp else {
            return Ok(());
        };
        let owner = Private::open(&self.store, false)?.context("Provider configuration missing")?;
        let mut payload = owner.read()?;
        let id = crate::digest_hex::lower_hex(Sha256::digest(format!(
            "{provider}\0{thread}\0{session}"
        )));
        if payload["sessions"][&id] == serde_json::to_value(stamp)? {
            return Ok(());
        }
        ensure!(
            payload["sessions"]
                .as_object()
                .is_some_and(|rows| rows.len() < 4096),
            "Private provider session bindings exceed their bound"
        );
        payload["sessions"][id] = serde_json::to_value(stamp)?;
        owner.write(&payload)
    }
}

#[path = "provider_account_secret_store.rs"]
pub mod account_secret_store;

#[path = "native_provider_accounts.rs"]
mod accounts;
pub(crate) use accounts::NativeCodexApiContext;
pub use accounts::{
    NativeAccountAuthentication, NativeAccountRemoval, NativeCodexKeyEnrollment,
    NativeCodexKeyEnrollmentReceipt, NativeKeyAccount, NativeKeySave, NativeLoginAccount,
    NativeProviderAccount, PreparedNativeAccountRemoval, native_account_key_choices,
};

#[path = "provider_setup.rs"]
mod setup;
pub use setup::{
    SetupAction, SetupCommand, SetupHandoff, run_native_provider_setup, setup_commands,
};

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub(crate) fn fixture() -> (tempfile::TempDir, Engine, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let binary = root.path().join(if cfg!(windows) {
            "synthetic-provider.exe"
        } else {
            "synthetic-provider"
        });
        fs::write(
            &binary,
            b"synthetic executable bytes, never run by this fixture",
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        }
        let companion = root.path().join(antigravity_companion_name());
        fs::copy(&binary, &companion).unwrap();
        let engine =
            Engine::fixture(Store::open(&root.path().join("private/state.sqlite")).unwrap());
        (root, engine, binary)
    }
    pub(crate) fn with_native_key_configuration<T>(
        provider: &str,
        body: impl FnOnce(&mut Engine, &Path) -> T,
    ) -> T {
        let (_root, mut engine, binary) = fixture();
        save(&mut engine, provider, &binary, "synthetic-global-key");
        let (configuration, home) = accounts::synthetic_key_configuration(&mut engine, provider);
        let _scope = enter(Some(configuration));
        body(&mut engine, &home)
    }
    pub(crate) fn save(engine: &mut Engine, provider: &str, binary: &Path, value: &str) {
        let baseline = engine
            .native_provider_configuration(provider)
            .unwrap()
            .baseline;
        let plan = engine
            .prepare_native_provider_configuration(
                provider,
                &baseline,
                Some(binary),
                BTreeMap::from([("SYNTHETIC_API_KEY".into(), value.into())]),
            )
            .unwrap();
        engine.apply_native_provider_configuration(plan).unwrap();
    }
    #[test]
    fn derived_runtime_requires_same_provider_source_and_bytes() {
        let (root, mut engine, binary) = fixture();
        save(&mut engine, "antigravity", &binary, "synthetic");
        let configuration = engine.provider_launch_configuration("antigravity").unwrap();
        let _scope = enter(configuration);
        let copied = root.path().join(if cfg!(windows) {
            "runtime.exe"
        } else {
            "runtime"
        });
        fs::copy(&binary, &copied).unwrap();
        {
            let _runtime = antigravity_runtime_copy(&binary, &copied).unwrap();
            apply_to_child(&mut Command::new(&copied), false).unwrap();
            assert_eq!(effective_var("SYNTHETIC_API_KEY").unwrap(), "synthetic");
            assert!(apply_to_child(&mut Command::new(root.path().join("other")), false).is_err());
        }
        assert!(apply_to_child(&mut Command::new(&copied), false).is_err());
        fs::write(&copied, b"unapproved changed content").unwrap();
        assert!(antigravity_runtime_copy(&binary, &copied).is_err());
        assert!(antigravity_runtime_copy(&copied, &binary).is_err());
        let _codex = enter(engine.provider_launch_configuration("codex").unwrap());
        save(&mut engine, "codex", &binary, "codex");
        let _codex = enter(engine.provider_launch_configuration("codex").unwrap());
        assert!(antigravity_runtime_copy(&binary, &binary).is_err());
    }
    #[test]
    fn antigravity_helper_replacement_cannot_reuse_approved_runtime_grant() {
        let (root, mut engine, binary) = fixture();
        let companion = root.path().join(antigravity_companion_name());
        let baseline = engine
            .native_provider_configuration("antigravity")
            .unwrap()
            .baseline;
        let plan = engine
            .prepare_native_provider_configuration(
                "antigravity",
                &baseline,
                Some(&binary),
                BTreeMap::new(),
            )
            .unwrap();
        fs::write(&companion, b"changed helper").unwrap();
        assert!(engine.apply_native_provider_configuration(plan).is_err());
        fs::copy(&binary, &companion).unwrap();
        save(&mut engine, "antigravity", &binary, "synthetic");
        let configuration = engine
            .provider_launch_configuration("antigravity")
            .unwrap()
            .unwrap();
        let runtime = root.path().join("private-runtime");
        fs::create_dir(&runtime).unwrap();
        let copied = runtime.join(binary.file_name().unwrap());
        fs::copy(&binary, &copied).unwrap();
        let copied_helper = runtime.join(antigravity_companion_name());
        fs::copy(&companion, &copied_helper).unwrap();
        {
            let _scope = enter(Some(configuration.clone()));
            let _runtime_scope = antigravity_runtime_copy(&binary, &copied).unwrap();
            apply_to_child(&mut Command::new(&copied), false).unwrap();
            fs::write(&copied_helper, b"changed copied helper").unwrap();
            assert!(apply_to_child(&mut Command::new(&copied), false).is_err());
        }
        fs::write(&companion, b"replaced helper after approval").unwrap();
        assert!(configuration.validate_launch().is_err());
        let _scope = enter(Some(configuration));
        assert!(apply_to_child(&mut Command::new(&binary), false).is_err());
    }
    #[test]
    fn public_settings_redacts_legacy_environments_without_erasing_saved_provider_data() {
        for providers in [
            json!({"codex":{"environment":{"SYNTHETIC_TEST_VALUE":"not-a-real-secret"},"customModels":["old"],"opaque":{"preserve":true}}}),
            json!(["codex",{"environment":{"SYNTHETIC_TEST_VALUE":"not-a-real-secret"},"customModels":["old"],"opaque":{"preserve":true}}]),
        ] {
            let (_root, mut engine, _binary) = fixture();
            let saved = json!({"providers":providers,"opaqueRoot":42});
            engine.store.save_document("settings.json", &saved).unwrap();
            let public = engine.execute("settings.read", &json!({})).unwrap();
            assert!(legacy_environment(&public, "codex").is_none());
            assert_eq!(
                engine.store.document("settings.json").unwrap().unwrap(),
                saved
            );
            let unrelated = engine
                .execute("settings.patch", &json!({"patch":{"sendOnReturn":false}}))
                .unwrap();
            assert!(legacy_environment(&unrelated, "codex").is_none());
            // Simulate a read/modify/write client editing the redacted full provider
            // representation: omission cannot delete the legacy environment.
            let mut edited = public["providers"].clone();
            if let Some(providers) = edited.as_object_mut() {
                providers.get_mut("codex").unwrap()["customModels"] = json!(["new"]);
            } else {
                edited[1]["customModels"] = json!(["new"]);
            }
            let response = engine
                .execute("settings.patch", &json!({"patch":{"providers":edited}}))
                .unwrap();
            assert!(legacy_environment(&response, "codex").is_none());
            assert_eq!(response["providers"], edited);
            let raw = engine.store.document("settings.json").unwrap().unwrap();
            assert_eq!(
                legacy_environment(&raw, "codex"),
                legacy_environment(&saved, "codex")
            );
            assert_eq!(raw["opaqueRoot"], 42);
            assert_eq!(public_settings(raw)["providers"], response["providers"]);
            assert!(
                engine
                    .provider_launch_configuration("codex")
                    .unwrap()
                    .is_none()
            );
        }
    }
    #[test]
    fn redacted_named_account_edits_preserve_private_legacy_environment_by_identity() {
        for array in [false, true] {
            let (_root, mut engine, _binary) = fixture();
            let account = json!({"id":"legacy-account","name":"Original","auth":"login","environment":{"SYNTHETIC_PRIVATE_VALUE":"fixture"},"opaque":47});
            let config = json!({"accounts":[account],"environment":{"SYNTHETIC_PROVIDER_VALUE":"fixture-provider"}});
            let providers = if array {
                json!(["claude", config])
            } else {
                json!({"claude":config})
            };
            let raw = json!({"providers":providers});
            engine.store.save_document("settings.json", &raw).unwrap();
            let public = engine.execute("settings.read", &json!({})).unwrap();
            assert!(
                legacy_provider(&public, "claude").unwrap()["accounts"][0]
                    .get("environment")
                    .is_none()
            );
            let mut patch = public.clone();
            if array {
                patch["providers"][1]["accounts"][0]["name"] = json!("Renamed");
            } else {
                patch["providers"]["claude"]["accounts"][0]["name"] = json!("Renamed");
            }
            let response = engine
                .execute("settings.patch", &json!({"patch":patch}))
                .unwrap();
            assert_eq!(response, patch);
            let saved = engine.store.document("settings.json").unwrap().unwrap();
            let account = &legacy_provider(&saved, "claude").unwrap()["accounts"][0];
            assert_eq!(account["name"], "Renamed");
            assert_eq!(account["opaque"], 47);
            assert_eq!(
                account["environment"],
                json!({"SYNTHETIC_PRIVATE_VALUE":"fixture"})
            );
            assert!(
                engine
                    .provider_launch_configuration("claude")
                    .unwrap()
                    .is_none()
            );
        }
    }
    #[test]
    fn ambiguous_redacted_account_replacement_never_erases_saved_environments() {
        let (_root, mut engine, _binary) = fixture();
        let raw = json!({"providers":{"claude":{"accounts":[{"id":"duplicate","environment":{"ONE":"fixture"}},{"id":"duplicate","environment":{"TWO":"fixture"}}]}}});
        engine.store.save_document("settings.json", &raw).unwrap();
        let public = engine.execute("settings.read", &json!({})).unwrap();
        assert!(
            engine
                .execute("settings.patch", &json!({"patch":public}))
                .is_err()
        );
        assert_eq!(
            engine.store.document("settings.json").unwrap().unwrap(),
            raw
        );
    }
    #[test]
    fn imported_values_are_visible_native_drafts_until_explicit_pinned_save() {
        for array in [false, true] {
            let (root, mut engine, binary) = fixture();
            let config = json!({"executablePath":binary,"environment":{"SYNTHETIC_API_KEY":"draft-not-a-real-key"},"opaque":17});
            let providers = if array {
                json!(["codex", config])
            } else {
                json!({"codex":config})
            };
            let raw = json!({"providers":providers});
            engine.store.save_document("settings.json", &raw).unwrap();
            let draft = engine.native_provider_configuration("codex").unwrap();
            assert!(draft.imported && !draft.approved);
            assert_eq!(draft.executable.as_deref(), Some(binary.as_path()));
            assert_eq!(
                draft.environment["SYNTHETIC_API_KEY"],
                "draft-not-a-real-key"
            );
            assert!(
                !directory(&root.path().join("private/state.sqlite"))
                    .unwrap()
                    .exists()
            );
            assert!(
                engine
                    .provider_launch_configuration("codex")
                    .unwrap()
                    .is_none()
            );
            assert!(
                legacy_environment(
                    &engine.execute("settings.read", &json!({})).unwrap(),
                    "codex"
                )
                .is_none()
            );
            let plan = engine
                .prepare_native_provider_configuration(
                    "codex",
                    &draft.baseline,
                    draft.executable.as_deref(),
                    draft.environment,
                )
                .unwrap();
            let saved = engine.apply_native_provider_configuration(plan).unwrap();
            assert!(saved.approved && !saved.imported);
            assert!(
                engine
                    .provider_launch_configuration("codex")
                    .unwrap()
                    .unwrap()
                    .approved_executable()
                    .is_some()
            );
            assert_eq!(
                engine.store.document("settings.json").unwrap().unwrap(),
                raw
            );
        }
    }
    #[test]
    fn native_discard_of_imported_values_preserves_raw_document_and_stays_automatic() {
        let (_root, mut engine, binary) = fixture();
        let raw = json!({"providers":{"codex":{"executablePath":binary,"environment":{"SYNTHETIC_TEST_MODE":"legacy"}}}});
        engine.store.save_document("settings.json", &raw).unwrap();
        let draft = engine.native_provider_configuration("codex").unwrap();
        let plan = engine
            .prepare_native_provider_configuration("codex", &draft.baseline, None, BTreeMap::new())
            .unwrap();
        engine.apply_native_provider_configuration(plan).unwrap();
        let next = engine.native_provider_configuration("codex").unwrap();
        assert!(
            next.approved
                && !next.imported
                && next.executable.is_none()
                && next.environment.is_empty()
        );
        assert!(
            engine
                .provider_launch_configuration("codex")
                .unwrap()
                .unwrap()
                .approved_executable()
                .is_none()
        );
        assert_eq!(
            engine.store.document("settings.json").unwrap().unwrap(),
            raw
        );
    }
    #[test]
    fn imported_settings_and_agent_json_cannot_grant_executable_or_environment_authority() {
        let (_root, mut engine, binary) = fixture();
        let settings = json!({"providers":{"codex":{"executablePath":binary,"environment":{"SYNTHETIC_API_KEY":"fixture-not-a-real-key"}}}});
        engine
            .store
            .save_document("settings.json", &settings)
            .unwrap();
        assert!(
            !engine
                .native_provider_configuration("codex")
                .unwrap()
                .approved
        );
        assert!(
            engine
                .provider_launch_configuration("codex")
                .unwrap()
                .is_none()
        );
        for method in [
            "providers.configuration.save",
            "providers.configuration.apply",
            "provider.environment.set",
        ] {
            assert!(engine.execute(method, &settings).is_err());
        }
        assert_eq!(
            engine.store.document("settings.json").unwrap(),
            Some(settings)
        );
        assert!(
            engine
                .provider_launch_configuration("codex")
                .unwrap()
                .is_none()
        );
    }
    #[test]
    fn failed_approval_marker_keeps_the_last_approved_configuration_exact() {
        let (root, mut engine, binary) = fixture();
        save(&mut engine, "codex", &binary, "original-synthetic-value");
        let before = engine.native_provider_configuration("codex").unwrap();
        let file = directory(&root.path().join("private/state.sqlite"))
            .unwrap()
            .join("configuration.json");
        let bytes = fs::read(&file).unwrap();
        let plan = engine
            .prepare_native_provider_configuration(
                "codex",
                &before.baseline,
                Some(&binary),
                BTreeMap::from([("SYNTHETIC_API_KEY".into(), "new-synthetic-value".into())]),
            )
            .unwrap();
        let database =
            rusqlite::Connection::open(root.path().join("private/state.sqlite")).unwrap();
        database.execute_batch("CREATE TRIGGER fail_native_marker BEFORE INSERT ON metadata WHEN NEW.key LIKE 'native-provider-configuration-v1/%' BEGIN SELECT RAISE(ABORT,'synthetic marker failure'); END;").unwrap();
        assert!(engine.apply_native_provider_configuration(plan).is_err());
        let after = engine.native_provider_configuration("codex").unwrap();
        assert_eq!(before.baseline, after.baseline);
        assert_eq!(before.environment, after.environment);
        assert_eq!(fs::read(file).unwrap(), bytes);
    }
    #[test]
    fn native_save_cas_keeps_private_values_out_of_settings_and_survives_restart() {
        let (root, mut first, binary) = fixture();
        let stale = first
            .prepare_native_provider_configuration(
                "codex",
                "unconfigured",
                Some(&binary),
                BTreeMap::new(),
            )
            .unwrap();
        let mut second =
            Engine::fixture(Store::open(&root.path().join("private/state.sqlite")).unwrap());
        save(&mut second, "codex", &binary, "fixture-not-a-real-key");
        assert!(first.apply_native_provider_configuration(stale).is_err());
        assert_eq!(
            first
                .native_provider_configuration("codex")
                .unwrap()
                .environment["SYNTHETIC_API_KEY"],
            "fixture-not-a-real-key"
        );
        assert!(first.store.document("settings.json").unwrap().is_none());
        let stamp = first
            .provider_launch_configuration("codex")
            .unwrap()
            .unwrap()
            .stamp
            .clone();
        drop(first);
        drop(second);
        let reopened =
            Engine::fixture(Store::open(&root.path().join("private/state.sqlite")).unwrap());
        assert_eq!(
            reopened
                .provider_launch_configuration("codex")
                .unwrap()
                .unwrap()
                .stamp
                .clone(),
            stamp
        );
    }
    #[test]
    fn all_six_providers_capture_child_only_environment_and_env_only_edits_change_proof_identity() {
        let (_root, mut engine, binary) = fixture();
        for provider in [
            "claude",
            "codex",
            "cursor",
            "grok",
            "opencode",
            "antigravity",
        ] {
            save(&mut engine, provider, &binary, "fixture-first");
            let first = engine
                .provider_launch_configuration(provider)
                .unwrap()
                .unwrap();
            let stamp = first.stamp.clone();
            {
                let _scope = enter(Some(first));
                let mut child = Command::new(&binary);
                apply_to_child(&mut child, false).unwrap();
                assert!(
                    child
                        .get_envs()
                        .any(|(key, value)| key == "SYNTHETIC_API_KEY"
                            && value == Some(std::ffi::OsStr::new("fixture-first")))
                );
                assert!(apply_to_child(&mut Command::new(&binary), true).is_err());
            }
            assert!(current().is_none());
            save(&mut engine, provider, &binary, "fixture-second");
            assert_ne!(
                engine
                    .provider_launch_configuration(provider)
                    .unwrap()
                    .unwrap()
                    .stamp
                    .clone(),
                stamp
            );
            // No global environment setter exists in production or this test.
        }
    }
    #[test]
    fn native_resume_ids_are_bound_to_the_exact_configured_endpoint_and_environment() {
        let (_root, mut engine, binary) = fixture();
        save(&mut engine, "codex", &binary, "fixture-first");
        let first = engine
            .provider_launch_configuration("codex")
            .unwrap()
            .unwrap();
        {
            let _scope = enter(Some(first.clone()));
            assert!(
                !engine
                    .native_configuration_session_allowed("codex", "thread", "native-session")
                    .unwrap()
            );
            engine
                .remember_native_configuration_session(
                    "codex",
                    "thread",
                    "native-session",
                    Some(&first.stamp.clone()),
                )
                .unwrap();
            assert!(
                engine
                    .native_configuration_session_allowed("codex", "thread", "native-session")
                    .unwrap()
            );
        }
        save(&mut engine, "codex", &binary, "fixture-second");
        let _scope = enter(engine.provider_launch_configuration("codex").unwrap());
        assert!(
            !engine
                .native_configuration_session_allowed("codex", "thread", "native-session")
                .unwrap()
        );
    }
    #[test]
    fn pin_changes_and_private_record_tampering_never_fall_back_to_path() {
        let (root, mut engine, binary) = fixture();
        save(&mut engine, "claude", &binary, "fixture-first");
        let captured = engine
            .provider_launch_configuration("claude")
            .unwrap()
            .unwrap();
        let modified = fs::metadata(&binary).unwrap().modified().unwrap();
        let before = fs::read(&binary).unwrap();
        let mut changed = before.clone();
        changed[0] ^= 1;
        fs::write(&binary, &changed).unwrap();
        File::options()
            .write(true)
            .open(&binary)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(modified))
            .unwrap();
        assert!(captured.validate_launch().is_err());
        let _scope = enter(Some(captured));
        assert!(apply_to_child(&mut Command::new(&binary), false).is_err());
        drop(_scope);
        let path = directory(&root.path().join("private/state.sqlite"))
            .unwrap()
            .join("configuration.json");
        let mut envelope: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        envelope["payload"]["providers"]["claude"]["environment"]["SYNTHETIC_API_KEY"] =
            json!("forged-fixture");
        fs::write(&path, serde_json::to_vec(&envelope).unwrap()).unwrap();
        assert!(engine.native_provider_configuration("claude").is_err());
    }
    #[test]
    fn removing_an_approved_private_record_never_restores_ambient_path_authority() {
        let (root, mut engine, binary) = fixture();
        save(&mut engine, "codex", &binary, "fixture-first");
        let directory = directory(&root.path().join("private/state.sqlite")).unwrap();
        fs::remove_file(directory.join("configuration.json")).unwrap();
        assert!(engine.provider_launch_configuration("codex").is_err());
        let snapshot = engine.native_provider_configuration("codex").unwrap();
        assert!(!snapshot.approved);
        let plan = engine
            .prepare_native_provider_configuration(
                "codex",
                &snapshot.baseline,
                Some(&binary),
                BTreeMap::new(),
            )
            .unwrap();
        engine.apply_native_provider_configuration(plan).unwrap();
        assert!(
            engine
                .provider_launch_configuration("codex")
                .unwrap()
                .is_some()
        );
    }
    #[test]
    fn reserved_homes_control_names_duplicates_and_oversized_values_are_rejected_before_private_writes()
     {
        let (root, engine, binary) = fixture();
        for key in [
            "HOME",
            "CODEX_HOME",
            "XDG_DATA_HOME",
            "COINCIDE_CONTROL_SOCKET",
            "CODEX_SESSION_ID",
            "bad=name",
        ] {
            assert!(
                engine
                    .prepare_native_provider_configuration(
                        "codex",
                        "unconfigured",
                        Some(&binary),
                        BTreeMap::from([(key.into(), "fixture".into())])
                    )
                    .is_err()
            );
        }
        assert!(
            engine
                .prepare_native_provider_configuration(
                    "codex",
                    "unconfigured",
                    Some(&binary),
                    BTreeMap::from([("FOO".into(), "one".into()), ("foo".into(), "two".into())])
                )
                .is_err()
        );
        assert!(
            !directory(&root.path().join("private/state.sqlite"))
                .unwrap()
                .exists()
        );
    }
}

#[path = "provider_configuration_probe.rs"]
mod probe;
pub use probe::{Probe, ProbeReport};
