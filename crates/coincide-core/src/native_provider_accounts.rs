//! Native-issued isolated login profiles. Settings/import account rows are
//! descriptive only and cannot mint these source-bound signed home grants.
use super::*;
use rusqlite::OptionalExtension;
use std::sync::Arc;
const PURPOSE: &str = "native-login-accounts-v1";
const GUARD: &str = ".native-account-owner";
#[derive(Clone)]
pub struct NativeLoginAccount {
    pub id: String,
    pub name: String,
    pub revision: String,
    pub home: PathBuf,
}
#[derive(Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
enum Authentication {
    #[default]
    Login,
    ApiKey,
}
fn login_mode(mode: &Authentication) -> bool {
    *mode == Authentication::Login
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Account {
    id: String,
    provider: String,
    name: String,
    revision: String,
    launch_revision: String,
    #[serde(default, skip_serializing_if = "login_mode")]
    authentication: Authentication,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    key_variable: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    key: Option<account_secret_store::SecretSlot>,
    home: PathBuf,
    home_identity: crate::private_fs::Identity,
    guard_identity: crate::private_fs::Identity,
}
#[derive(Clone)]
pub(super) struct LoginHome {
    account: Account,
    root: PathBuf,
    _lease: Arc<File>,
    base_environment: BTreeMap<String, String>,
    captured_auth: Value,
}
fn supported(provider: &str) -> Result<&'static str> {
    match provider {
        "claude" => Ok("CLAUDE_CONFIG_DIR"),
        "grok" => Ok("GROK_HOME"),
        "opencode" => Ok("XDG_DATA_HOME"),
        _ => anyhow::bail!("Use this provider's existing account workflow"),
    }
}
fn home(root: &Path, provider: &str, id: &str) -> Result<PathBuf> {
    provider_id(provider)?;
    let canonical = Uuid::parse_str(id)?.to_string();
    ensure!(canonical == id, "Invalid native account identity");
    Ok(root.join("providers").join(provider).join(canonical))
}
fn ensure_parent(path: &Path) -> Result<()> {
    if !path.try_exists()? {
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            fs::DirBuilder::new().mode(0o700).create(path)?;
        }
        #[cfg(windows)]
        crate::private_fs::windows::create_directory(path)?;
    }
    private(path, true)
}
fn create_home(
    root: &Path,
    provider: &str,
    id: &str,
) -> Result<(
    PathBuf,
    crate::private_fs::Identity,
    crate::private_fs::Identity,
)> {
    private(root, true)?;
    ensure_parent(&root.join("providers"))?;
    ensure_parent(&root.join("providers").join(provider))?;
    let path = home(root, provider, id)?;
    // Never adopt an existing CLI home or imported account ID.
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        fs::DirBuilder::new().mode(0o700).create(&path)?;
    }
    #[cfg(windows)]
    crate::private_fs::windows::create_directory(&path)?;
    private(&path, true)?;
    let guard = path.join(GUARD);
    drop(open_file(&guard, true)?);
    Ok((
        path.clone(),
        crate::private_fs::identity(&path)?,
        crate::private_fs::identity(&guard)?,
    ))
}
fn rollback_empty_home(path: &Path) {
    let only_guard = fs::read_dir(path).is_ok_and(|entries| {
        entries
            .filter_map(std::result::Result::ok)
            .all(|entry| entry.file_name() == GUARD)
    });
    if only_guard {
        let _ = fs::remove_file(path.join(GUARD));
        let _ = fs::remove_dir(path);
    }
}
fn summary(account: &Account) -> NativeLoginAccount {
    NativeLoginAccount {
        id: account.id.clone(),
        name: account.name.clone(),
        revision: account.revision.clone(),
        home: account.home.clone(),
    }
}
fn read(owner: &Private, provider: &str, raw: Option<&str>) -> Result<Value> {
    provider_id(provider)?;
    let Some(raw) = raw else {
        return Ok(
            json!({"source":owner.source,"purpose":PURPOSE,"provider":provider,"accounts":{}}),
        );
    };
    ensure!(
        raw.len() <= 1024 * 1024,
        "Native account registry exceeds its bound"
    );
    let envelope: Value =
        serde_json::from_str(raw).context("Native account registry is invalid")?;
    let encoded = envelope["tag"]
        .as_str()
        .context("Native account seal missing")?;
    ensure!(
        encoded.len() == 64 && encoded.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "Invalid native account seal"
    );
    let tag = (0..32)
        .map(|i| u8::from_str_radix(&encoded[i * 2..i * 2 + 2], 16))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    hmac::verify(&owner.key, &serde_json::to_vec(&envelope["payload"])?, &tag)
        .map_err(|_| anyhow::anyhow!("Native account seal is invalid"))?;
    let payload = &envelope["payload"];
    ensure!(
        payload["source"] == owner.source
            && payload["purpose"] == PURPOSE
            && payload["provider"] == provider
            && payload["accounts"].is_object(),
        "Native account registry belongs to another source"
    );
    Ok(payload.clone())
}
fn encoded(owner: &Private, payload: &Value) -> Result<String> {
    let bytes = serde_json::to_vec(payload)?;
    let tag = hmac::sign(&owner.key, &bytes);
    Ok(serde_json::to_string(
        &json!({"payload":payload,"tag":crate::digest_hex::lower_hex(tag.as_ref())}),
    )?)
}
fn account(payload: &Value, provider: &str, id: &str) -> Result<Account> {
    let value = payload["accounts"]
        .get(id)
        .context("Native account is not configured")?;
    let account: Account =
        serde_json::from_value(value.clone()).context("Native account is invalid")?;
    ensure!(
        account.provider == provider && account.id == id,
        "Native account identity does not match"
    );
    Ok(account)
}
impl LoginHome {
    fn capture(root: &Path, account: Account) -> Result<Self> {
        Self::capture_with_lock(root, account, false)
    }
    fn capture_with_lock(root: &Path, account: Account, exclusive: bool) -> Result<Self> {
        ensure!(
            account.home == home(root, &account.provider, &account.id)?,
            "Native account home is outside its owner"
        );
        private(&account.home, true)?;
        ensure!(
            crate::private_fs::identity(&account.home)? == account.home_identity,
            "Native account home changed"
        );
        let path = account.home.join(GUARD);
        private(&path, false)?;
        ensure!(
            crate::private_fs::identity(&path)? == account.guard_identity,
            "Native account owner changed"
        );
        let lease = open_file(&path, false)?;
        if exclusive {
            lease
                .try_lock()
                .context("Native account is in use; stop its conversations before signing in")?;
        } else {
            lease
                .try_lock_shared()
                .context("Native account setup or removal is busy")?;
        }
        let mut base_environment = BTreeMap::new();
        for key in [
            "PATH",
            "HOME",
            "USERPROFILE",
            "USER",
            "LOGNAME",
            "SHELL",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "TMPDIR",
            "TMP",
            "TEMP",
            "SystemRoot",
            "SYSTEMROOT",
            "WINDIR",
        ] {
            if let Some(value) = std::env::var_os(key) {
                base_environment.insert(
                    key.into(),
                    value.into_string().map_err(|_| {
                        anyhow::anyhow!("Native account environment has unsupported encoding")
                    })?,
                );
            }
        }
        let mut captured = Self {
            account,
            root: root.into(),
            _lease: Arc::new(lease),
            base_environment,
            captured_auth: Value::Null,
        };
        captured.captured_auth = captured.auth_stamp()?;
        Ok(captured)
    }
    pub(super) fn validate(&self) -> Result<()> {
        ensure!(
            self.account.home == home(&self.root, &self.account.provider, &self.account.id)?,
            "Native account home changed"
        );
        private(&self.account.home, true)?;
        private(&self.account.home.join(GUARD), false)?;
        ensure!(
            crate::private_fs::identity(&self.account.home)? == self.account.home_identity
                && crate::private_fs::identity(&self.account.home.join(GUARD))?
                    == self.account.guard_identity,
            "Native account owner was replaced"
        );
        ensure!(
            self.auth_stamp()? == self.captured_auth,
            "Native login authentication changed; capture the account again"
        );
        Ok(())
    }
    pub(super) fn matches(&self, selection: &Value) -> bool {
        selection["provider"] == self.account.provider && selection["accountID"] == self.account.id
    }
    pub(super) fn configure_base(&self, command: &mut Command) -> Result<()> {
        self.validate()?;
        command.env_clear().envs(&self.base_environment);
        Ok(())
    }
    pub(super) fn environment_value(&self, name: &str) -> Option<std::ffi::OsString> {
        self.base_environment
            .iter()
            .find(|(key, _)| {
                if cfg!(windows) {
                    key.eq_ignore_ascii_case(name)
                } else {
                    key.as_str() == name
                }
            })
            .map(|(_, value)| value.into())
    }
    fn auth_stamp(&self) -> Result<Value> {
        let path = match self.account.provider.as_str() {
            "claude" => self.account.home.join(".credentials.json"),
            "grok" => self.account.home.join("auth.json"),
            "opencode" => self.account.home.join("opencode/auth.json"),
            _ => unreachable!(),
        };
        if self.account.provider == "opencode" {
            let parent = self.account.home.join("opencode");
            if parent.try_exists()? {
                private(&parent, true)?;
            }
        }
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Value::Null),
            Err(error) => return Err(error.into()),
        };
        ensure!(
            metadata.is_file()
                && !metadata.file_type().is_symlink()
                && metadata.len() <= 1024 * 1024,
            "Native login auth is not a bounded regular file"
        );
        #[cfg(windows)]
        crate::private_fs::windows::verify_inherited(&path, false)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            ensure!(
                metadata.uid() == unsafe { libc::geteuid() } && metadata.nlink() == 1,
                "Native login auth ownership is unsafe"
            );
        }
        private(&path, false)?;
        let mut file = open_file(&path, false)?;
        ensure!(
            crate::private_fs::file_identity(&file)? == crate::private_fs::identity(&path)?,
            "Native login auth changed while opening"
        );
        let mut bytes = Vec::new();
        (&mut file).take(1024 * 1024 + 1).read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() <= 1024 * 1024,
            "Native login auth exceeds limit"
        );
        Ok(
            json!({"identity":crate::private_fs::identity(&path)?,"length":metadata.len(),"modified":metadata.modified()?.duration_since(std::time::UNIX_EPOCH)?.as_nanos(),"digest":crate::digest_hex::lower_hex(Sha256::digest(&bytes))}),
        )
    }
}
fn auth_keys(provider: &str) -> &'static [&'static str] {
    match provider {
        "claude" => &["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"],
        "grok" => &["XAI_API_KEY"],
        "opencode" => &[
            "OPENCODE_API_KEY",
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
            "OPENROUTER_API_KEY",
            "GOOGLE_GENERATIVE_AI_API_KEY",
            "XAI_API_KEY",
            "GROQ_API_KEY",
            "DEEPSEEK_API_KEY",
            "MISTRAL_API_KEY",
        ],
        _ => &[],
    }
}
impl Engine {
    pub(super) fn validate_native_account_selection(&self, thread: &Value) -> Result<()> {
        let owner = Private::open(&self.store, false)?
            .context("Choose this account in the native composer first")?;
        let id = required(thread, "id")?;
        let raw = self
            .store
            .native_account_selection(id)?
            .context("Choose this account in the native composer first")?;
        let envelope: Value = serde_json::from_str(&raw)?;
        let tag = envelope["tag"]
            .as_str()
            .context("Native account selection seal missing")?;
        ensure!(
            tag.len() == 64 && tag.bytes().all(|byte| byte.is_ascii_hexdigit()),
            "Invalid account selection seal"
        );
        let tag = (0..32)
            .map(|i| u8::from_str_radix(&tag[i * 2..i * 2 + 2], 16))
            .collect::<std::result::Result<Vec<_>, _>>()?;
        hmac::verify(&owner.key, &serde_json::to_vec(&envelope["payload"])?, &tag)
            .map_err(|_| anyhow::anyhow!("Native account selection seal is invalid"))?;
        let value = &envelope["payload"];
        ensure!(
            value["source"] == owner.source
                && value["purpose"] == "native-account-selection-v1"
                && value["thread"] == id
                && value["provider"] == thread["selection"]["provider"]
                && value["account"] == thread["selection"]["accountID"],
            "Native account selection changed; choose the account again"
        );
        Ok(())
    }
    pub fn native_login_accounts(&self, provider: &str) -> Result<Vec<NativeLoginAccount>> {
        supported(provider)?;
        let Some(owner) = Private::open(&self.store, false)? else {
            return Ok(Vec::new());
        };
        let raw = self.store.native_accounts_payload(provider)?;
        let payload = read(&owner, provider, raw.as_deref())?;
        payload["accounts"]
            .as_object()
            .unwrap()
            .keys()
            .map(|id| account(&payload, provider, id))
            .collect::<Result<Vec<_>>>()?
            .into_iter()
            .filter(|account| account.authentication == Authentication::Login)
            .map(|account| Ok(summary(&account)))
            .collect()
    }
    pub fn create_native_login_account(
        &mut self,
        provider: &str,
        name: &str,
    ) -> Result<NativeLoginAccount> {
        self.require_admissions()?;
        supported(provider)?;
        let name = name.trim();
        ensure!(
            !name.is_empty() && name.len() <= 120 && !name.chars().any(char::is_control),
            "Enter a valid account name"
        );
        let owner =
            Private::open(&self.store, true)?.context("Native account authority unavailable")?;
        let raw = self.store.native_accounts_payload(provider)?;
        let mut payload = read(&owner, provider, raw.as_deref())?;
        ensure!(
            payload["accounts"].as_object().unwrap().len() < 32,
            "Native account limit reached"
        );
        let id = Uuid::new_v4().to_string();
        let root = self.store.data_directory()?;
        let (home, home_identity, guard_identity) = create_home(&root, provider, &id)?;
        let account = Account {
            id: id.clone(),
            provider: provider.into(),
            name: name.into(),
            revision: Uuid::new_v4().to_string(),
            launch_revision: Uuid::new_v4().to_string(),
            authentication: Authentication::Login,
            key_variable: None,
            key: None,
            home,
            home_identity,
            guard_identity,
        };
        payload["accounts"][&id] = serde_json::to_value(&account)?;
        if let Err(error) = self.store.save_native_accounts_payload(
            provider,
            raw.as_deref(),
            &encoded(&owner, &payload)?,
        ) {
            rollback_empty_home(&account.home);
            return Err(error);
        }
        self.revision += 1;
        Ok(summary(&account))
    }
    pub fn rename_native_login_account(
        &mut self,
        provider: &str,
        id: &str,
        expected: &str,
        name: &str,
    ) -> Result<NativeLoginAccount> {
        self.require_admissions()?;
        supported(provider)?;
        let name = name.trim();
        ensure!(
            !name.is_empty() && name.len() <= 120 && !name.chars().any(char::is_control),
            "Enter a valid account name"
        );
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        let raw = self.store.native_accounts_payload(provider)?;
        let mut payload = read(&owner, provider, raw.as_deref())?;
        ensure!(
            account(&payload, provider, id)?.revision == expected,
            "Native account changed; reload before renaming"
        );
        payload["accounts"][id]["name"] = json!(name);
        payload["accounts"][id]["revision"] = json!(Uuid::new_v4().to_string());
        self.store.save_native_accounts_payload(
            provider,
            raw.as_deref(),
            &encoded(&owner, &payload)?,
        )?;
        self.revision += 1;
        Ok(summary(&account(&payload, provider, id)?))
    }
    pub fn select_native_login_account(
        &mut self,
        expected: &Value,
        account: Option<&str>,
    ) -> Result<Value> {
        self.require_admissions()?;
        let id = required(expected, "id")?;
        ensure!(
            self.active_thread.as_deref() == Some(id),
            "Conversation selection changed; account choice retained"
        );
        ensure!(
            !self.runs.contains_key(id)
                && !self.unsaved_threads.contains_key(id)
                && !self.native_follow_up.pending_thread(id),
            "Stop the turn and wait for persistence before changing accounts"
        );
        ensure!(
            !self.store.is_imported(id)?,
            "Imported conversations cannot change native accounts"
        );
        let current = self.store.thread(id)?;
        ensure!(
            current == *expected,
            "Conversation changed; reload before changing accounts"
        );
        ensure!(
            current["rustBotContext"].is_null() && current["botID"].is_null(),
            "Bot account selection is fixed"
        );
        ensure!(
            crate::message_queue::read(&current)?
                .iter()
                .all(|row| !matches!(
                    row.state,
                    crate::message_queue::State::Pending | crate::message_queue::State::Dispatching
                )),
            "Finish queued messages before changing accounts"
        );
        let provider = text(&current["selection"], "provider");
        supported(&provider)?;
        let target = account.filter(|account| !account.is_empty() && *account != "default");
        let configuration = if let Some(target) = target {
            Some(self.native_login_launch_configuration(&provider, target)?)
        } else {
            self.provider_launch_configuration(&provider)?
        };
        let _scope = enter(configuration);
        let mut view = current.clone();
        view["selection"]
            .as_object_mut()
            .context("Provider selection is malformed")?
            .remove("accountID");
        crate::composer_policy::Policy::parse(&view, crate::composer_policy::Origin::Ordinary)?
            .preflight()?;
        let mut changed = current.clone();
        if let Some(target) = target {
            changed["selection"]["accountID"] = json!(target);
        } else {
            changed["selection"]
                .as_object_mut()
                .unwrap()
                .remove("accountID");
        }
        crate::composer_policy::Policy::parse(&changed, crate::composer_policy::Origin::Ordinary)?
            .preflight()?;
        let owner = Private::open(&self.store, false)?;
        let grant = target.map(|target| {
            let owner = owner.as_ref().context("Native account authority missing")?;
            encoded(owner, &json!({"source":owner.source,"purpose":"native-account-selection-v1","thread":id,"provider":provider,"account":target}))
        }).transpose()?;
        self.store
            .save_native_account_selection(&current, &changed, grant.as_deref())?;
        self.revision += 1;
        Ok(changed)
    }
    pub(super) fn native_login_launch_configuration(
        &self,
        provider: &str,
        id: &str,
    ) -> Result<LaunchConfiguration> {
        let owner = Private::open(&self.store, false)?
            .context("Add this account in native Settings first")?;
        let raw = self.store.native_accounts_payload(provider)?;
        let payload = read(&owner, provider, raw.as_deref())?;
        let account = account(&payload, provider, id)?;
        ensure!(
            account.authentication == Authentication::Login,
            "Use this account's native API key workflow"
        );
        let profile = LoginHome::capture(&self.store.data_directory()?, account)?;
        // Both native envelopes share this authority lease.
        let record = read_record(&owner.read()?, provider)?;
        ensure!(
            record.is_some()
                || !self
                    .store
                    .requires_native_provider_configuration(provider)?,
            "Approved provider configuration is missing; save it again in native Settings before running"
        );
        if let Some(record) = &record {
            validate_environment(&record.environment)?;
        }
        build_configuration(&owner, profile, record, None)
    }
}

fn build_configuration(
    owner: &Private,
    profile: LoginHome,
    record: Option<Record>,
    executable: Option<PathBuf>,
) -> Result<LaunchConfiguration> {
    let provider = profile.account.provider.as_str();
    let id = profile.account.id.as_str();
    let executable = executable
        .or_else(|| {
            record.as_ref().and_then(|record| {
                record
                    .executable
                    .as_ref()
                    .map(|binary| binary.requested.clone())
            })
        })
        .or_else(|| default_executable(provider))
        .context("Install this provider or approve its executable in native Settings")?;
    let mut record = record.unwrap_or(Record {
        revision: "automatic".into(),
        executable: None,
        companion: None,
        custom: false,
        environment: BTreeMap::new(),
    });
    record.executable = Some(Binary::capture(&executable)?);
    // Global provider environment is not an account-specific credential grant.
    // In particular GROK_AUTH and GROK_CONFIG can select credentials outside
    // GROK_HOME, while Claude supports helper/token and endpoint overrides.
    record.environment.retain(|key, _| {
        let upper = key.to_ascii_uppercase();
        !sensitive_for_profile(key)
            && !upper.contains("AUTH")
            && !upper.starts_with("GROK_")
            && !upper.starts_with("CLAUDE_")
            && !upper.starts_with("ANTHROPIC_")
            && !upper.starts_with("OPENCODE_")
            && !auth_keys(provider)
                .iter()
                .any(|owned| key.eq_ignore_ascii_case(owned))
    });
    record.environment.insert(
        supported(provider)?.into(),
        profile.account.home.to_string_lossy().into_owned(),
    );
    let digest = crate::digest_hex::lower_hex(Sha256::digest(serde_json::to_vec(
        &json!({"configuration":record,"baseEnvironment":profile.base_environment,"account":id,"home":profile.account.home_identity,"guard":profile.account.guard_identity,"generation":profile.account.launch_revision,"auth":profile.captured_auth}),
    )?));
    let source: PathBuf = owner.source["path"]
        .as_str()
        .context("Native account source missing")?
        .into();
    let identity = serde_json::from_value(owner.source["identity"].clone())?;
    Ok(LaunchConfiguration {
        stamp: Stamp {
            source,
            identity,
            provider: provider.into(),
            revision: profile.account.launch_revision.clone(),
            digest,
        },
        record,
        profile: Some(profile),
        derived_executable: None,
        derived_companion: None,
    })
}

pub(super) fn setup_configuration(
    owner: &Private,
    provider: &str,
    expected: &Account,
    record: Option<Record>,
    launch: &Path,
) -> Result<LaunchConfiguration> {
    ensure!(
        expected.provider == provider,
        "Setup account belongs to another provider"
    );
    let path: PathBuf = owner.source["path"]
        .as_str()
        .context("Setup source missing")?
        .into();
    let held = setup_source::Source::open(&path)?;
    ensure!(
        serde_json::to_value(crate::private_fs::file_identity(&held.file)?)?
            == owner.source["identity"],
        "Setup source changed"
    );
    let db = rusqlite::Connection::open_with_flags(
        &path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    ensure!(
        serde_json::to_value(crate::private_fs::identity(&path)?)? == owner.source["identity"],
        "Setup source changed"
    );
    held.verify(&path, &db)?;
    let raw: Option<String> = db
        .query_row(
            "SELECT value FROM metadata WHERE key=?1",
            [format!("native-login-accounts-v1/{}", expected.provider)],
            |row| row.get(0),
        )
        .optional()?;
    held.verify(&path, &db)?;
    let payload = read(owner, &expected.provider, raw.as_deref())?;
    let current = account(&payload, &expected.provider, &expected.id)?;
    ensure!(
        serde_json::to_value(&current)? == serde_json::to_value(expected)?,
        "Native account changed; request sign in again"
    );
    let profile = LoginHome::capture_with_lock(
        path.parent().context("Setup source directory missing")?,
        current,
        true,
    )?;
    build_configuration(owner, profile, record, Some(launch.into()))
}
impl Engine {
    pub(super) fn prepare_login_setup_account(
        &mut self,
        provider: &str,
        id: &str,
        expected: &str,
    ) -> Result<Account> {
        self.require_admissions()?;
        let owner = Private::open(&self.store, false)?
            .context("Add this account in native Settings first")?;
        let raw = self.store.native_accounts_payload(provider)?;
        let mut payload = read(&owner, provider, raw.as_deref())?;
        let current = account(&payload, provider, id)?;
        ensure!(
            current.authentication == Authentication::Login,
            "Use this account's native API key workflow"
        );
        ensure!(
            current.revision == expected,
            "Account changed; reload before signing in"
        );
        let _exclusive =
            LoginHome::capture_with_lock(&self.store.data_directory()?, current, true)?;
        payload["accounts"][id]["revision"] = json!(Uuid::new_v4().to_string());
        payload["accounts"][id]["launch_revision"] = json!(Uuid::new_v4().to_string());
        self.store.save_native_accounts_payload(
            provider,
            raw.as_deref(),
            &encoded(&owner, &payload)?,
        )?;
        self.revision += 1;
        account(&payload, provider, id)
    }
}

#[path = "native_key_accounts.rs"]
mod keys;
pub use keys::{NativeKeyAccount, NativeKeySave};

#[path = "native_provider_setup_source.rs"]
mod setup_source;

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(provider: &str) -> (tempfile::TempDir, Engine, PathBuf) {
        let (root, mut engine, binary) = super::super::tests::fixture();
        super::super::tests::save(&mut engine, provider, &binary, "fixture-only");
        (root, engine, binary)
    }
    fn thread(engine: &mut Engine, provider: &str) -> Value {
        let id = Uuid::new_v4().to_string();
        let thread = json!({"id":id,"title":"Account choice","createdAt":0,"updatedAt":0,"draft":"Keep my draft","items":[],"selection":{"provider":provider,"modelID":"default"},"sessions":{"future":"preserve"},"unknown":{"keep":true}});
        engine.store.save(&thread).unwrap();
        engine.active_thread = Some(id);
        thread
    }
    #[test]
    fn native_selection_is_required_and_preserves_conversation_state() {
        let (_root, mut engine, _binary) = fixture("grok");
        let first = engine
            .create_native_login_account("grok", "Personal")
            .unwrap();
        let second = engine.create_native_login_account("grok", "Work").unwrap();
        assert_ne!(first.home, second.home);
        let source = thread(&mut engine, "grok");
        let mut injected = source.clone();
        injected["selection"]["accountID"] = json!(first.id);
        engine.store.save(&injected).unwrap();
        assert!(
            engine
                .provider_launch_configuration_for_thread(&injected)
                .is_err()
        );
        engine.store.save(&source).unwrap();
        let selected = engine
            .select_native_login_account(&source, Some(&first.id))
            .unwrap();
        let configuration = engine
            .provider_launch_configuration_for_thread(&selected)
            .unwrap()
            .unwrap();
        assert!(!super::super::native_account_matches(
            &selected["selection"]
        ));
        let _scope = enter(Some(configuration));
        assert!(super::super::native_account_matches(&selected["selection"]));
        let mut restored = selected.clone();
        restored["selection"]
            .as_object_mut()
            .unwrap()
            .remove("accountID");
        assert_eq!(restored, source);
        assert!(
            engine
                .select_native_login_account(&source, Some(&second.id))
                .is_err()
        );
        let default = engine.select_native_login_account(&selected, None).unwrap();
        assert_eq!(default, source);
        assert!(
            engine
                .provider_launch_configuration_for_thread(&selected)
                .is_err()
        );
    }
    #[test]
    fn login_child_environment_is_captured_isolated_and_home_bound() {
        let (_root, mut engine, binary) = fixture("claude");
        let account = engine
            .create_native_login_account("claude", "Work")
            .unwrap();
        let configuration = engine
            .native_login_launch_configuration("claude", &account.id)
            .unwrap();
        let _scope = enter(Some(configuration));
        let mut command = Command::new(binary);
        command.env("ARBITRARY_INHERITED_SECRET", "fixture-will-be-cleared");
        apply_to_child(&mut command, false).unwrap();
        let env: BTreeMap<_, _> = command
            .get_envs()
            .filter_map(|(key, value)| {
                value.map(|value| {
                    (
                        key.to_string_lossy().into_owned(),
                        value.to_string_lossy().into_owned(),
                    )
                })
            })
            .collect();
        assert!(!env.contains_key("ARBITRARY_INHERITED_SECRET"));
        assert_eq!(
            env.get("CLAUDE_CONFIG_DIR"),
            Some(&account.home.to_string_lossy().into_owned())
        );
        assert!(!env.contains_key("ANTHROPIC_API_KEY"));
        assert!(effective_var("ANTHROPIC_API_KEY").is_none());
        assert!(effective_var("ARBITRARY_INHERITED_SECRET").is_none());
    }
    #[test]
    fn global_grok_auth_and_configuration_cannot_override_named_login_home() {
        let (_root, mut engine, binary) = fixture("grok");
        let baseline = engine
            .native_provider_configuration("grok")
            .unwrap()
            .baseline;
        let environment = BTreeMap::from([
            ("GROK_AUTH".into(), "synthetic-other-principal".into()),
            (
                "GROK_AUTH_PROVIDER_COMMAND".into(),
                "synthetic-never-execute".into(),
            ),
            (
                "GROK_CONFIG_PATH".into(),
                "synthetic-external-config".into(),
            ),
        ]);
        let plan = engine
            .prepare_native_provider_configuration("grok", &baseline, Some(&binary), environment)
            .unwrap();
        engine.apply_native_provider_configuration(plan).unwrap();
        let default = engine.provider_launch_configuration("grok").unwrap();
        {
            let _scope = enter(default);
            assert_eq!(
                effective_var("GROK_AUTH"),
                Some("synthetic-other-principal".into())
            );
        }
        let account = engine
            .create_native_login_account("grok", "Own login")
            .unwrap();
        let configuration = engine
            .native_login_launch_configuration("grok", &account.id)
            .unwrap();
        let _scope = enter(Some(configuration));
        let mut child = Command::new(binary);
        apply_to_child(&mut child, false).unwrap();
        for key in [
            "GROK_AUTH",
            "GROK_AUTH_PROVIDER_COMMAND",
            "GROK_CONFIG_PATH",
        ] {
            assert!(effective_var(key).is_none());
            assert!(!child.get_envs().any(|(name, _)| name == key));
        }
        assert_eq!(
            effective_var("GROK_HOME"),
            Some(account.home.into_os_string())
        );
    }
    #[test]
    fn rename_preserves_launch_identity_unknown_fields_and_rejects_stale_cas() {
        let (_root, mut engine, _binary) = fixture("grok");
        let original = engine
            .create_native_login_account("grok", "Original")
            .unwrap();
        let stamp = engine
            .native_login_launch_configuration("grok", &original.id)
            .unwrap()
            .stamp;
        {
            let owner = Private::open(&engine.store, false).unwrap().unwrap();
            let raw = engine.store.native_accounts_payload("grok").unwrap();
            let mut payload = read(&owner, "grok", raw.as_deref()).unwrap();
            payload["accounts"][&original.id]["future"] = json!({"keep":[1,2]});
            engine
                .store
                .save_native_accounts_payload(
                    "grok",
                    raw.as_deref(),
                    &encoded(&owner, &payload).unwrap(),
                )
                .unwrap();
        }
        let renamed = engine
            .rename_native_login_account("grok", &original.id, &original.revision, "Renamed")
            .unwrap();
        assert_ne!(renamed.revision, original.revision);
        assert_eq!(
            engine
                .native_login_launch_configuration("grok", &original.id)
                .unwrap()
                .stamp,
            stamp
        );
        assert!(
            engine
                .rename_native_login_account("grok", &original.id, &original.revision, "Stale")
                .is_err()
        );
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        let raw = engine.store.native_accounts_payload("grok").unwrap();
        assert_eq!(
            read(&owner, "grok", raw.as_deref()).unwrap()["accounts"][&original.id]["future"],
            json!({"keep":[1,2]})
        );
    }
    #[test]
    fn replaced_home_and_changed_auth_reject_captured_configuration() {
        let (_root, mut engine, _binary) = fixture("grok");
        let account = engine.create_native_login_account("grok", "Work").unwrap();
        let configuration = engine
            .native_login_launch_configuration("grok", &account.id)
            .unwrap();
        let auth = account.home.join("auth.json");
        let mut file = open_file(&auth, true).unwrap();
        file.write_all(b"synthetic auth, never sent").unwrap();
        drop(file);
        assert!(configuration.validate_launch().is_err());
        let updated = engine
            .native_login_launch_configuration("grok", &account.id)
            .unwrap();
        assert_ne!(configuration.stamp, updated.stamp);
        #[cfg(unix)]
        {
            fs::rename(&account.home, account.home.with_extension("old")).unwrap();
            ensure_parent(&account.home).unwrap();
            assert!(updated.validate_launch().is_err());
            assert!(
                engine
                    .native_login_launch_configuration("grok", &account.id)
                    .is_err()
            );
        }
        #[cfg(windows)]
        assert!(fs::rename(&account.home, account.home.with_extension("old")).is_err());
    }
    #[test]
    fn forged_registry_and_stale_thread_cannot_mint_account_authority() {
        let (_root, mut engine, _binary) = fixture("grok");
        let account = engine.create_native_login_account("grok", "Work").unwrap();
        let source = thread(&mut engine, "grok");
        let mut changed = source.clone();
        changed["draft"] = json!("Newer draft");
        engine.store.save(&changed).unwrap();
        assert!(
            engine
                .select_native_login_account(&source, Some(&account.id))
                .is_err()
        );
        assert_eq!(
            engine.store.thread(source["id"].as_str().unwrap()).unwrap(),
            changed
        );
        let raw = engine
            .store
            .native_accounts_payload("grok")
            .unwrap()
            .unwrap();
        let mut forged: Value = serde_json::from_str(&raw).unwrap();
        forged["payload"]["accounts"][&account.id]["home"] = json!("/not-an-owned-profile");
        engine
            .store
            .save_native_accounts_payload("grok", Some(&raw), &forged.to_string())
            .unwrap();
        assert!(engine.native_login_accounts("grok").is_err());
        assert!(
            engine
                .native_login_launch_configuration("grok", &account.id)
                .is_err()
        );
    }
}
