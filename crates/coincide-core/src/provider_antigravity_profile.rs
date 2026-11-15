//! Isolated API-key profiles and runtime pairs belong to this Rust client.
use super::*;
use sha2::{Digest, Sha256};
use std::{
    ffi::OsString,
    fs::{self, File, OpenOptions},
    path::{Component, Path},
};

pub(super) struct Profile {
    pub directory: PathBuf,
    _lock: File,
    temporary: PathBuf,
}
impl Profile {
    pub fn prepare(
        directory: &Path,
        original: Option<&Path>,
        session: Option<&str>,
    ) -> Result<Self> {
        ensure!(
            original.is_none() && crate::provider_configuration::native_key_profile("antigravity"),
            "Antigravity requires a selected Gemini API-key account; Google-account login is unavailable"
        );
        ensure!(
            directory.is_absolute(),
            "Antigravity profile must be absolute"
        );
        check_components(directory)?;
        let directory = resolve(directory)?;
        ensure!(
            fs::symlink_metadata(directory.join("antigravity-acp/acp_token.json"))
                .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound),
            "This profile contains an older Google sign-in. Select an API-key account and start a new conversation; the old data is preserved"
        );
        if !directory.exists() {
            fs::create_dir_all(&directory)?;
            permissions(&directory, 0o700)?;
        }
        private(&directory)?;
        let marker = directory.join(".coincide-antigravity");
        if !marker.exists() {
            ensure!(
                fs::read_dir(&directory)?.next().is_none(),
                "Antigravity profile contains unrelated files"
            );
            write_new(&marker, b"Coincide Antigravity private profile v1\n", 0o600)?;
        } else {
            ensure!(
                read(&marker, 128)? == b"Coincide Antigravity private profile v1\n",
                "Invalid Antigravity profile marker"
            );
        }
        let lock_path = directory.join(".lock");
        safe_file(&lock_path, true)?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let lock = options.open(lock_path)?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            ensure!(
                unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
                "Antigravity private profile is already in use"
            );
        }
        #[cfg(not(unix))]
        lock.try_lock()
            .context("Antigravity private profile is already in use")?;
        let acp = directory.join("antigravity-acp");
        make_directory(&acp)?;
        let settings = b"{\"auth\":{\"type\":\"gemini-api-key\"}}\n".as_slice();
        replace(&acp.join("settings.json"), settings, 0o600)?;
        let helper = directory.join("browser-suppressed.sh");
        ensure!(
            !helper.to_string_lossy().contains([':', '\n', '\r'])
                && !helper.to_string_lossy().contains("%s"),
            "Antigravity profile path cannot safely suppress browser launches"
        );
        // Never print the OAuth URL, including on stderr. Python sees success and
        // cannot fall back to another browser, while the adapter sees a safe marker.
        replace(&helper,b"#!/bin/sh\ntrap '' PIPE\nprintf '%s\\n' '__COINCIDE_ANTIGRAVITY_SIGN_IN_REQUIRED__' >&2\nexit 0\n",0o700)?;
        if let Some(id) = session {
            require_existing_session(&directory, id)?;
        }
        make_directory(&directory.join("runtime"))?;
        let temporary = directory
            .join("runtime")
            .join(format!("extract-{}", uuid::Uuid::new_v4()));
        make_directory(&temporary)?;
        Ok(Self {
            directory,
            _lock: lock,
            temporary,
        })
    }
    pub fn runtime(&self, executable: &Path) -> Result<PathBuf> {
        let executable = executable
            .canonicalize()
            .context("Antigravity executable is unavailable")?;
        let harness = executable
            .parent()
            .context("Antigravity runtime has no parent")?
            .join("localharness_external");
        safe_file(&executable, false)?;
        safe_file(&harness, false)?;
        let executable_hash = hash_file(&executable)?;
        let harness_hash = hash_file(&harness)?;
        // Managed 1.3.0 pairs must match the same pinned release as the Swift app.
        if executable
            .components()
            .any(|part| part.as_os_str() == "versions")
        {
            let valid = matches!(
                (executable_hash.as_str(), harness_hash.as_str()),
                (
                    "cb1f0725183ed922079ed6cd1d2422b4d8be44c5fb60be3e9a43d8d04f99a18e",
                    "b04b00662c1821b953a409d43626b86d1229130eeb2078b4e1304c06199aa481"
                ) | (
                    "f31bd5797eeb225a5efa12e24573f1f4eb157ec00698dd6a2cda6f0d924705cf",
                    "d724f49b2c9e440c5d37925b1da203fc204c17dd9c662df45094c641f9806bc6"
                )
            );
            ensure!(
                valid,
                "Antigravity managed runtime does not match a pinned executable/helper pair"
            );
        }
        let root = self
            .directory
            .join("runtime")
            .join(format!("{executable_hash}-{harness_hash}"));
        make_directory(&root)?;
        for (source, name, hash) in [
            (&executable, "agy_acp_server.par", &executable_hash),
            (&harness, "localharness_external", &harness_hash),
        ] {
            let target = root.join(name);
            if !target.exists() {
                let temporary = root.join(format!(".copy-{}", uuid::Uuid::new_v4()));
                let result = (|| -> Result<()> {
                    let mut input = open_read(source)?;
                    let mut output = new_file(&temporary, 0o700)?;
                    let copied = std::io::copy(
                        &mut Read::by_ref(&mut input).take(512 * 1024 * 1024 + 1),
                        &mut output,
                    )?;
                    ensure!(
                        copied <= 512 * 1024 * 1024,
                        "Antigravity runtime file exceeds 512 MiB"
                    );
                    output.sync_all()?;
                    ensure!(
                        hash_file(&temporary)? == *hash,
                        "Antigravity runtime changed while copying"
                    );
                    fs::rename(&temporary, &target)?;
                    Ok(())
                })();
                if result.is_err() {
                    let _ = fs::remove_file(&temporary);
                }
                result?;
            }
            safe_file(&target, true)?;
            ensure!(
                hash_file(&target)? == *hash,
                "Antigravity private runtime failed its integrity check"
            );
        }
        Ok(root.join("agy_acp_server.par"))
    }
    pub fn environment(&self, executable: &Path) -> Vec<(OsString, OsString)> {
        let helper = self.directory.join("browser-suppressed.sh");
        let browser = format!(
            "'/bin/sh' '{}' '%s'",
            helper.to_string_lossy().replace('\'', "'\"'\"'")
        );
        let mut environment = vec![
            (
                "GEMINI_HOME".into(),
                self.directory.clone().into_os_string(),
            ),
            ("AGY_ACP_FORCE_FILE_STORAGE".into(), "1".into()),
            ("BROWSER".into(), browser.into()),
            ("PYTHONUNBUFFERED".into(), "1".into()),
            (
                "ANTIGRAVITY_HARNESS_PATH".into(),
                executable
                    .with_file_name("localharness_external")
                    .into_os_string(),
            ),
            ("TMPDIR".into(), self.temporary.as_os_str().to_owned()),
            ("TMP".into(), self.temporary.as_os_str().to_owned()),
            ("TEMP".into(), self.temporary.as_os_str().to_owned()),
        ];
        if crate::provider_configuration::native_key_profile("antigravity")
            && let Some(key) =
                crate::provider_configuration::native_key_var("antigravity", "GEMINI_API_KEY")
        {
            environment.push(("GEMINI_API_KEY".into(), key));
        }
        environment
    }
}
impl Drop for Profile {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.temporary);
    }
}
fn require_existing_session(directory: &Path, id: &str) -> Result<()> {
    let parsed =
        uuid::Uuid::parse_str(id).context("Antigravity native session ID must be a UUID")?;
    ensure!(
        parsed.to_string() == id.to_lowercase(),
        "Antigravity session ID is not canonical"
    );
    let acp = directory.join("antigravity-acp");
    let target = acp.join("conversations");
    make_directory(&target)?;
    let db = target.join(format!("{id}.db"));
    if db.exists() {
        for suffix in [".db", ".meta", ".db-wal", ".db-shm", ".db-journal"] {
            safe_file(&target.join(format!("{id}{suffix}")), true)?;
        }
        return Ok(());
    }
    bail!(
        "Antigravity native session is missing from this API-key account; no replacement was created"
    )
}
pub(super) fn removed_environment() -> Vec<String> {
    const KEYS: &[&str] = &[
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "GOOGLE_CLOUD_PROJECT",
        "GOOGLE_CLOUD_LOCATION",
        "GOOGLE_CLOUD_QUOTA_PROJECT",
        "GOOGLE_GENAI_USE_VERTEXAI",
        "GCLOUD_PROJECT",
        "CLOUDSDK_CORE_PROJECT",
        "AGY_ACP_CCPA_PROJECT",
        "AGY_ACP_ENABLE_OAUTH",
        "AGY_LLM_GATEWAY_URL",
        "AGY_LLM_GATEWAY_API_KEY",
        "AGY_LLM_GATEWAY_HEADERS",
        "AGY_LLM_GATEWAY_CA_CERT",
        "AGY_LLM_GATEWAY_MODELS",
        "AGY_LLM_GATEWAY_WIRE_PROTOCOL",
        "GEMINI_HOME",
        "AGY_ACP_FORCE_FILE_STORAGE",
        "ANTIGRAVITY_HARNESS_PATH",
        "BROWSER",
        "PYTHONUNBUFFERED",
        "ELECTRON_RUN_AS_NODE",
    ];
    let mut removed = KEYS.iter().map(|key| (*key).to_owned()).collect::<Vec<_>>();
    for key in std::env::vars_os()
        .filter_map(|(key, _)| key.into_string().ok())
        .filter(|key| KEYS.contains(&key.to_ascii_uppercase().as_str()))
    {
        if !removed.contains(&key) {
            removed.push(key);
        }
    }
    removed
}
fn hash_file(path: &Path) -> Result<String> {
    let mut file = open_read(path)?;
    ensure!(
        file.metadata()?.len() <= 512 * 1024 * 1024,
        "Antigravity runtime file exceeds 512 MiB"
    );
    let mut hash = Sha256::new();
    let mut buffer = [0; 65536];
    let mut total = 0usize;
    loop {
        let n = file.read(&mut buffer)?;
        total += n;
        ensure!(
            total <= 512 * 1024 * 1024,
            "Antigravity runtime file grew beyond 512 MiB"
        );
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    Ok(crate::digest_hex::lower_hex(hash.finalize()))
}
fn resolve(path: &Path) -> Result<PathBuf> {
    ensure!(path.is_absolute(), "Antigravity path must be absolute");
    if path.exists() {
        return Ok(path.canonicalize()?);
    }
    let name = path.file_name().context("Antigravity path has no name")?;
    Ok(resolve(path.parent().context("Antigravity path has no parent")?)?.join(name))
}
fn check_components(path: &Path) -> Result<()> {
    let mut current = PathBuf::new();
    for component in path.components() {
        ensure!(
            !matches!(component, Component::ParentDir),
            "Antigravity path contains traversal"
        );
        current.push(component);
        if matches!(component, Component::Prefix(_)) {
            continue;
        }
        #[cfg(target_os = "macos")]
        if current == Path::new("/tmp") || current == Path::new("/var") {
            continue;
        }
        safe_file(&current, false)?;
    }
    Ok(())
}
fn safe_file(path: &Path, single: bool) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(meta) => {
            ensure!(
                !meta.file_type().is_symlink(),
                "Antigravity profile contains a symbolic link"
            );
            #[cfg(unix)]
            if single {
                use std::os::unix::fs::MetadataExt;
                ensure!(
                    meta.nlink() == 1,
                    "Antigravity profile file has multiple hard links"
                );
            }
            #[cfg(not(unix))]
            let _ = single;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
    }
    Ok(())
}
fn private(path: &Path) -> Result<()> {
    ensure!(path.is_dir(), "Antigravity profile is not a directory");
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let m = fs::metadata(path)?;
        ensure!(
            m.uid() == unsafe { libc::geteuid() } && m.mode() & 0o077 == 0,
            "Antigravity profile must be privately owned"
        );
    }
    Ok(())
}
fn permissions(path: &Path, mode: u32) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
    }
    #[cfg(not(unix))]
    let _ = (path, mode);
    Ok(())
}
fn make_directory(path: &Path) -> Result<()> {
    safe_file(path, false)?;
    if !path.exists() {
        fs::create_dir(path)?;
        permissions(path, 0o700)?;
    }
    private(path)
}
fn open_read(path: &Path) -> Result<File> {
    safe_file(path, false)?;
    let mut o = OpenOptions::new();
    o.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.custom_flags(libc::O_NOFOLLOW);
    }
    let f = o.open(path)?;
    ensure!(
        f.metadata()?.is_file(),
        "Antigravity source is not a regular file"
    );
    Ok(f)
}
fn read(path: &Path, limit: usize) -> Result<Vec<u8>> {
    let f = open_read(path)?;
    ensure!(
        f.metadata()?.len() <= limit as u64,
        "Antigravity file exceeds its import limit"
    );
    let mut bytes = Vec::new();
    f.take(limit as u64 + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= limit,
        "Antigravity file grew beyond its import limit"
    );
    Ok(bytes)
}
fn new_file(path: &Path, mode: u32) -> Result<File> {
    let mut o = OpenOptions::new();
    o.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(mode).custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(not(unix))]
    let _ = mode;
    Ok(o.open(path)?)
}
fn write_new(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let mut f = new_file(path, mode)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    Ok(())
}
fn replace(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    safe_file(path, false)?;
    let temp = path.with_file_name(format!(".write-{}", uuid::Uuid::new_v4()));
    write_new(&temp, bytes, mode)?;
    let result = fs::rename(&temp, path);
    if result.is_err() {
        let _ = fs::remove_file(temp);
    }
    result?;
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[test]
    fn native_api_key_profile_requires_no_oauth_copy_and_keeps_key_in_child_environment() {
        crate::provider_configuration::tests::with_native_key_configuration(
            "antigravity",
            |_engine, home| {
                let profile =
                    Profile::prepare(&home.join("threads/synthetic"), None, None).unwrap();
                assert!(
                    !profile
                        .directory
                        .join("antigravity-acp/acp_token.json")
                        .exists()
                );
                let settings: Value = serde_json::from_slice(
                    &fs::read(profile.directory.join("antigravity-acp/settings.json")).unwrap(),
                )
                .unwrap();
                assert_eq!(settings["auth"]["type"], "gemini-api-key");
                assert!(!settings.to_string().contains("synthetic-owned-account-key"));
                let environment = profile.environment(&home.join("synthetic-runtime"));
                assert!(
                    environment
                        .iter()
                        .any(|(key, value)| key == "GEMINI_API_KEY"
                            && value == "synthetic-owned-account-key")
                );
            },
        );
        let root = tempfile::tempdir().unwrap();
        assert!(Profile::prepare(&root.path().join("without-native-grant"), None, None).is_err());
    }
    #[test]
    fn legacy_oauth_source_and_tokens_are_never_opened_or_removed() {
        crate::provider_configuration::tests::with_native_key_configuration(
            "antigravity",
            |_engine, home| {
                let source = home.join("old-profile");
                let token = source.join("antigravity-acp/acp_token.json");
                fs::create_dir_all(token.parent().unwrap()).unwrap();
                fs::write(&token, b"old account data").unwrap();
                let target = home.join("threads/new");
                assert!(Profile::prepare(&target, Some(&source), None).is_err());
                assert!(!target.exists());
                assert_eq!(fs::read(&token).unwrap(), b"old account data");
                let target_token = target.join("antigravity-acp/acp_token.json");
                fs::create_dir_all(target_token.parent().unwrap()).unwrap();
                fs::write(&target_token, b"private old data").unwrap();
                assert!(Profile::prepare(&target, None, None).is_err());
                assert_eq!(fs::read(&target_token).unwrap(), b"private old data");
            },
        );
    }
    #[test]
    fn api_key_sessions_resume_only_from_their_existing_private_profile() {
        crate::provider_configuration::tests::with_native_key_configuration(
            "antigravity",
            |_engine, home| {
                let missing = home.join("threads/missing");
                let target = home.join("threads/existing");
                let id = "3f2b8c1e-9d4a-4b6f-8e2d-1c0a9b8f7e6d";
                assert!(Profile::prepare(&missing, None, Some(id)).is_err());
                let db = target
                    .join("antigravity-acp/conversations")
                    .join(format!("{id}.db"));
                fs::create_dir_all(db.parent().unwrap()).unwrap();
                permissions(&target, 0o700).unwrap();
                permissions(&target.join("antigravity-acp"), 0o700).unwrap();
                permissions(db.parent().unwrap(), 0o700).unwrap();
                fs::write(
                    target.join(".coincide-antigravity"),
                    b"Coincide Antigravity private profile v1\n",
                )
                .unwrap();
                fs::write(&db, b"api-key session").unwrap();
                drop(Profile::prepare(&target, None, Some(id)).unwrap());
                assert_eq!(fs::read(db).unwrap(), b"api-key session");
            },
        );
    }
}
