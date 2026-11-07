//! Rust-owned Codex subscription-login profiles. Names are not account identity.
//! No credential bytes are copied/read here. Only the selected CLI reads its own auth.
use anyhow::{Context as _, Result, ensure};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};
use uuid::Uuid;

pub(crate) const DOCUMENT: &str = "rust-codex-login-profiles.json";
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub(crate) struct LaunchContext {
    account: String,
    home: PathBuf,
    root: PathBuf,
    home_identity: crate::private_fs::Identity,
    executable: PathBuf,
    executable_identity: (crate::private_fs::Identity, u64, std::time::SystemTime),
    #[serde(skip_serializing_if = "Option::is_none")]
    native_api_key: Option<crate::provider_configuration::NativeCodexApiContext>,
    #[serde(skip)]
    home_lease: Option<crate::provider_configuration::CodexHomeLease>,
}
impl LaunchContext {
    pub(crate) fn capture(root: &Path, account: &str, executable: &Path) -> Result<Self> {
        canonical_id(account)?;
        ensure!(
            executable.is_absolute(),
            "Configure an absolute Codex executable first"
        );
        let executable = executable.canonicalize()?;
        let metadata = fs::metadata(&executable)?;
        ensure!(metadata.is_file(), "Codex executable is not a file");
        let home = managed_home(root, account, false)?;
        let value = Self {
            account: account.into(),
            native_api_key: None,
            home_lease: Some(crate::provider_configuration::CodexHomeLease::capture(
                &home,
            )?),
            root: root.into(),
            home: home.clone(),
            home_identity: crate::private_fs::identity(&home)?,
            executable: executable.clone(),
            executable_identity: {
                (
                    crate::private_fs::identity(&executable)?,
                    metadata.len(),
                    metadata.modified()?,
                )
            },
        };
        value.validate()?;
        Ok(value)
    }
    pub(crate) fn capture_native_key(
        root: &Path,
        account: &str,
        executable: &Path,
    ) -> Result<Self> {
        canonical_id(account)?;
        let grant = crate::provider_configuration::NativeCodexApiContext::capture(
            root, account, executable,
        )?;
        let executable = executable.canonicalize()?;
        let metadata = fs::metadata(&executable)?;
        let home = grant.home().to_path_buf();
        let value = Self {
            account: account.into(),
            root: root.into(),
            home_identity: crate::private_fs::identity(&home)?,
            home,
            executable: executable.clone(),
            executable_identity: (
                crate::private_fs::identity(&executable)?,
                metadata.len(),
                metadata.modified()?,
            ),
            native_api_key: Some(grant),
            home_lease: None,
        };
        value.validate()?;
        Ok(value)
    }
    pub(crate) fn account(&self) -> &str {
        &self.account
    }
    pub(crate) fn executable(&self) -> &Path {
        &self.executable
    }
    pub(crate) fn home(&self) -> &Path {
        &self.home
    }
    pub(crate) fn validate(&self) -> Result<()> {
        if let Some(lease) = &self.home_lease {
            lease.validate()?;
        }
        if let Some(native) = &self.native_api_key {
            native.validate()?;
            ensure!(native.home() == self.home, "Codex API profile home changed");
        } else {
            ensure!(
                managed_home(&self.root, &self.account, false)? == self.home,
                "Codex profile home changed"
            );
        }
        ensure!(
            crate::private_fs::identity(&self.home)? == self.home_identity,
            "Codex profile home was replaced"
        );
        // This first slice admits only a dedicated auth home, never a provider
        // config capable of replacing the selected login or endpoint.
        ensure!(
            fs::symlink_metadata(self.home.join("config.toml"))
                .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound),
            "Named Codex profile config overrides are not supported"
        );
        if let Ok(auth) = fs::symlink_metadata(self.home.join("auth.json")) {
            ensure!(
                auth.is_file() && !auth.file_type().is_symlink() && auth.len() <= 1_048_576,
                "Codex profile auth file is not a bounded private regular file"
            );
            #[cfg(unix)]
            {
                use std::os::unix::fs::{MetadataExt, PermissionsExt};
                // SAFETY: geteuid is a side-effect-free OS account identity query.
                ensure!(
                    auth.uid() == unsafe { libc::geteuid() }
                        && auth.permissions().mode() & 0o077 == 0
                        && auth.nlink() == 1,
                    "Codex profile auth file has unsafe owner or permissions"
                );
            }
            #[cfg(windows)]
            crate::private_fs::windows::verify_inherited(&self.home.join("auth.json"), false)?;
        } else {
            ensure!(
                fs::symlink_metadata(self.home.join("auth.json"))
                    .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound),
                "Codex profile auth file cannot be inspected"
            );
        }
        let metadata = fs::metadata(&self.executable)?;
        let identity = crate::private_fs::identity(&self.executable)?;
        ensure!(
            metadata.is_file()
                && self.executable_identity == (identity, metadata.len(), metadata.modified()?),
            "Codex executable changed after profile admission"
        );
        Ok(())
    }
    pub(crate) fn arguments(&self) -> Vec<String> {
        if self.native_api_key.is_some() {
            return [
                "-c",
                "cli_auth_credentials_store=\"file\"",
                "-c",
                "forced_login_method=\"api\"",
                "-c",
                "model_provider=\"openai\"",
                "-c",
                "openai_base_url=\"https://api.openai.com/v1\"",
                "app-server",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect();
        }
        [
            "-c",
            "cli_auth_credentials_store=\"file\"",
            "-c",
            "forced_login_method=\"chatgpt\"",
            "-c",
            "model_provider=\"openai\"",
            "-c",
            "openai_base_url=\"https://chatgpt.com/backend-api/codex\"",
            "-c",
            "chatgpt_base_url=\"https://chatgpt.com/backend-api/\"",
            "app-server",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect()
    }
    pub(crate) fn configure(&self, command: &mut Command) -> Result<()> {
        self.validate()?;
        if self.native_api_key.is_some() {
            return Ok(());
        } // captured native child scope applies next
        // An allowlist avoids inherited API keys, endpoint/proxy overrides,
        // external bearer tokens and arbitrary configured auth-command variables.
        command.env_clear();
        for key in [
            "PATH",
            "HOME",
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
                command.env(key, value);
            }
        }
        command.env("CODEX_HOME", &self.home);
        Ok(())
    }
    pub(crate) fn admit_account(&self, result: &Value) -> Result<()> {
        self.validate()?;
        if self.native_api_key.is_some() {
            ensure!(
                result["requiresOpenaiAuth"] == true && result["account"]["type"] == "apiKey",
                "Selected Codex API profile is not enrolled as an API key"
            );
            return Ok(());
        }
        ensure!(
            result["requiresOpenaiAuth"] == true
                && result["account"].is_object()
                && result["account"]["type"] == "chatgpt",
            "Selected Codex login profile is not authenticated as a ChatGPT subscription"
        );
        Ok(())
    }
}

pub(crate) fn canonical_id(id: &str) -> Result<()> {
    ensure!(
        Uuid::parse_str(id).is_ok_and(|uuid| uuid.to_string() == id),
        "Codex profile ID must be a canonical UUID"
    );
    Ok(())
}
pub(crate) fn configuration(store: &crate::store::Store) -> Result<Value> {
    let value = store
        .local_document(DOCUMENT)?
        .unwrap_or_else(|| json!({"version":1,"accounts":{}}));
    ensure!(
        value.is_object() && value["version"] == 1 && value["accounts"].is_object(),
        "Invalid Rust Codex profile configuration"
    );
    Ok(value)
}
pub(crate) fn account<'a>(configuration: &'a Value, id: &str) -> Result<&'a Value> {
    canonical_id(id)?;
    let value = configuration["accounts"]
        .get(id)
        .context("Selected Codex profile is not configured")?;
    ensure!(
        value.is_object()
            && value["auth"] == "login"
            && value["name"]
                .as_str()
                .is_some_and(|name| !name.trim().is_empty()
                    && name.len() <= 120
                    && !name.chars().any(char::is_control)),
        "Invalid Codex login profile metadata"
    );
    Ok(value)
}
/// The default CLI account precedes named accounts; named order is the user's
/// creation order. Older registries without an order retain their stored order.
pub(crate) fn ordered_accounts(configuration: &Value) -> Result<Vec<String>> {
    let accounts = configuration["accounts"]
        .as_object()
        .context("Invalid profile registry")?;
    let mut result = Vec::new();
    if let Some(order) = configuration.get("order") {
        for id in order.as_array().context("Invalid account order")? {
            let id = id.as_str().context("Invalid ordered account identity")?;
            ensure!(
                accounts.contains_key(id) && !result.iter().any(|value| value == id),
                "Invalid or duplicate ordered account"
            );
            result.push(id.to_owned());
        }
    }
    for id in accounts.keys() {
        if !result.contains(id) {
            result.push(id.clone());
        }
    }
    Ok(result)
}

pub(crate) fn validate_thread(thread: &Value) -> Result<()> {
    validate_model_thread(thread)?;
    ensure!(
        thread["selection"]["modelID"] == "default",
        "Choose Provider default before switching Codex profile"
    );
    Ok(())
}
pub(crate) fn validate_model_thread(thread: &Value) -> Result<()> {
    let model = thread["selection"]["modelID"]
        .as_str()
        .context("Codex model must be text")?;
    crate::composer_selection::validate_model(model)?;
    ensure!(
        thread["selection"]["provider"] == "codex"
            && (thread["selection"]["effort"].is_null()
                || (model != "default"
                    && thread["selection"]["effort"]
                        .as_str()
                        .is_some_and(|effort| !effort.is_empty()
                            && effort.len() <= 128
                            && effort.trim() == effort
                            && !effort.chars().any(char::is_control))))
            && (thread["selection"]["speed"].is_null()
                || (model != "default"
                    && thread["selection"]["speed"]
                        .as_str()
                        .is_some_and(|speed| !speed.is_empty()
                            && speed != "default"
                            && speed.len() <= 128
                            && speed.trim() == speed
                            && !speed.chars().any(char::is_control))))
            && thread["rustBotContext"].is_null()
            && thread["botID"].is_null()
            && (thread["accessMode"].is_null()
                || matches!(
                    thread["accessMode"].as_str(),
                    Some("approval" | "fullAccess")
                ))
            && (thread["interactionMode"].is_null()
                || thread["interactionMode"] == "build"
                || (thread["interactionMode"] == "plan" && model != "default")),
        "Named Codex login profiles require ordinary threads and explicit-model Plan/effort/speed"
    );
    ensure!(
        thread["accessMode"] != "fullAccess" || model != "default",
        "Named Codex full access requires an explicit profile-catalog model"
    );
    Ok(())
}
/// Internal validation view only, after Engine-owned profile admission. Never
/// persists this default alias or grants access to a default catalog proof.
pub(crate) fn validation_view(thread: &Value) -> Value {
    let mut value = thread.clone();
    value["selection"]
        .as_object_mut()
        .unwrap()
        .remove("accountID");
    value
}
#[cfg(unix)]
fn private_directory(path: &Path, create: bool) -> Result<()> {
    if create {
        match fs::create_dir(path) {
            Ok(()) => {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
    }
    let metadata = fs::symlink_metadata(path)?;
    ensure!(
        metadata.is_dir() && !metadata.file_type().is_symlink(),
        "Codex profile path must be a private directory"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        // SAFETY: geteuid only queries this process's OS account identity.
        ensure!(
            metadata.uid() == unsafe { libc::geteuid() }
                && metadata.permissions().mode() & 0o077 == 0,
            "Codex profile directory has unsafe owner or permissions"
        );
    }
    Ok(())
}
#[cfg(windows)]
fn private_directory(path: &Path, create: bool) -> Result<()> {
    if create {
        crate::private_fs::windows::create_directory(path)?;
    }
    ensure!(
        fs::symlink_metadata(path)?.is_dir(),
        "Profile container is not a directory"
    );
    crate::private_fs::windows::verify_inherited(path, true)
}
#[cfg(not(any(unix, windows)))]
fn private_directory(_: &Path, _: bool) -> Result<()> {
    anyhow::bail!("Private profiles unavailable")
}

pub(crate) fn managed_home(root: &Path, id: &str, create: bool) -> Result<PathBuf> {
    canonical_id(id)?;
    private_directory(root, false)?;
    ensure!(
        root.canonicalize()? == root,
        "Rust data root must be canonical"
    );
    let mut path = root.to_path_buf();
    for component in ["providers", "codex", id] {
        path.push(component);
        private_directory(&path, create)?;
    }
    ensure!(path.canonicalize()? == path, "Codex profile path changed");
    Ok(path)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    fn fixture() -> (tempfile::TempDir, PathBuf, String, LaunchContext) {
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let root = dir.path().canonicalize().unwrap();
        let id = Uuid::new_v4().to_string();
        managed_home(&root, &id, true).unwrap();
        let context =
            LaunchContext::capture(&root, &id, &std::env::current_exe().unwrap()).unwrap();
        (dir, root, id, context)
    }
    #[test]
    fn profile_home_rejects_noncanonical_ids_symlinks_permissions_and_replacement() {
        let (_dir, root, id, context) = fixture();
        assert!(managed_home(&root, "../default", true).is_err());
        assert!(managed_home(&root, &id.to_uppercase(), false).is_err());
        fs::set_permissions(&context.home, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(context.validate().is_err());
        fs::set_permissions(&context.home, fs::Permissions::from_mode(0o700)).unwrap();
        let old = root.join("old-profile");
        fs::rename(&context.home, &old).unwrap();
        managed_home(&root, &id, true).unwrap();
        assert!(context.validate().is_err());
        fs::remove_dir(&context.home).unwrap();
        symlink(&old, &context.home).unwrap();
        assert!(context.validate().is_err());
    }
    #[test]
    fn profile_rejects_config_and_auth_redirection_without_reading_credential_bytes() {
        let (_dir, root, _id, context) = fixture();
        fs::write(
            context.home.join("config.toml"),
            "model_provider='external'",
        )
        .unwrap();
        assert!(context.validate().is_err());
        fs::remove_file(context.home.join("config.toml")).unwrap();
        symlink(root.join("unrelated-auth"), context.home.join("auth.json")).unwrap();
        assert!(context.validate().is_err());
        fs::remove_file(context.home.join("auth.json")).unwrap();
        fs::write(context.home.join("auth.json"), "synthetic, never parsed").unwrap();
        fs::set_permissions(
            context.home.join("auth.json"),
            fs::Permissions::from_mode(0o644),
        )
        .unwrap();
        assert!(context.validate().is_err());
        fs::set_permissions(
            context.home.join("auth.json"),
            fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        assert!(context.validate().is_ok());
    }
    #[test]
    fn profile_authentication_requires_real_subscription_shape_not_display_metadata() {
        let (_dir, _root, _id, context) = fixture();
        for value in [
            json!({"name":"ChatGPT account"}),
            json!({"requiresOpenaiAuth":true,"account":null}),
            json!({"requiresOpenaiAuth":true,"account":{"type":"apiKey"}}),
            json!({"requiresOpenaiAuth":false,"account":{"type":"chatgpt"}}),
        ] {
            assert!(context.admit_account(&value).is_err());
        }
        assert!(context.admit_account(&json!({"requiresOpenaiAuth":true,"account":{"type":"chatgpt","email":"synthetic@example.invalid"}})).is_ok());
        let mut command = Command::new(context.executable());
        command
            .env("OPENAI_API_KEY", "synthetic-hostile")
            .env("OPENAI_BASE_URL", "https://invalid.invalid");
        context.configure(&mut command).unwrap();
        let overrides = command.get_envs().collect::<Vec<_>>();
        assert!(
            !overrides.iter().any(
                |(key, value)| key == &std::ffi::OsStr::new("OPENAI_API_KEY") && value.is_some()
            )
        );
        assert!(!overrides.iter().any(|(key, value)| key
            == &std::ffi::OsStr::new("OPENAI_BASE_URL")
            && value.is_some()));
        assert!(
            context
                .arguments()
                .contains(&"cli_auth_credentials_store=\"file\"".into())
        );
    }
}
