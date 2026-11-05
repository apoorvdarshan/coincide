//! Subscription profiles and runtime pairs belong exclusively to this Rust client.
//! Originals are opened as ordinary read-only files, never as SQLite connections.
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
            directory.is_absolute(),
            "Antigravity profile must be absolute"
        );
        check_components(directory)?;
        let directory = resolve(directory)?;
        let original = original.map(resolve).transpose()?;
        if let Some(source) = &original {
            ensure!(
                !directory.starts_with(source) && !source.starts_with(&directory),
                "Antigravity private profile must be separate from the original"
            );
        }
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
        if let Some(source) = &original {
            let binding = directory.join(".source-profile");
            let expected = source
                .to_str()
                .context("Antigravity source profile path must be UTF-8")?
                .as_bytes();
            if binding.exists() {
                ensure!(
                    read(&binding, 16 * 1024)? == expected,
                    "Antigravity private profile belongs to another source account"
                );
            } else {
                ensure!(
                    !directory.join("antigravity-acp/acp_token.json").exists(),
                    "An existing Antigravity profile cannot be silently rebound to another account"
                );
                write_new(&binding, expected, 0o600)?;
            }
        }
        let acp = directory.join("antigravity-acp");
        make_directory(&acp)?;
        let token = acp.join("acp_token.json");
        if !token.exists() {
            let source = original
                .as_ref()
                .context(AUTH_FAILURE)?
                .join("antigravity-acp/acp_token.json");
            check_components(&source)?;
            let bytes = read(&source, 1024 * 1024).map_err(|_| anyhow::anyhow!(AUTH_FAILURE))?;
            validate_token(&bytes)?;
            write_new(&token, &bytes, 0o600)?;
        } else {
            safe_file(&token, true)?;
            validate_token(&read(&token, 1024 * 1024)?)?;
        }
        replace(
            &acp.join("settings.json"),
            b"{\"auth\":{\"type\":\"oauth-personal\"}}\n",
            0o600,
        )?;
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
            import_session(&directory, original.as_deref(), id)?;
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
        vec![
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
        ]
    }
}
impl Drop for Profile {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.temporary);
    }
}
fn validate_token(bytes: &[u8]) -> Result<()> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| anyhow::anyhow!(AUTH_FAILURE))?;
    ensure!(
        ["client_id", "client_secret", "refresh_token"]
            .iter()
            .all(|key| value[key].as_str().is_some_and(|s| !s.is_empty())),
        "{AUTH_FAILURE}"
    );
    Ok(())
}
fn import_session(directory: &Path, source: Option<&Path>, id: &str) -> Result<()> {
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
    let source = source
        .context("Antigravity native session is missing; no replacement was created")?
        .join("antigravity-acp");
    let conversations = source.join("conversations");
    let original = conversations.join(format!("{id}.db"));
    check_components(&original)?;
    let inactive = || -> Result<()> {
        for suffix in [".db-wal", ".db-journal"] {
            ensure!(
                fs::symlink_metadata(conversations.join(format!("{id}{suffix}")))
                    .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound),
                "Antigravity native session has live SQLite sidecars; close/checkpoint the original before importing"
            );
        }
        Ok(())
    };
    inactive()?;
    let bytes = read(&original, 64 * 1024 * 1024)?;
    let second = read(&original, 64 * 1024 * 1024)?;
    inactive()?;
    ensure!(
        bytes == second,
        "Antigravity native session changed while importing"
    );
    let metadata = read(&conversations.join(format!("{id}.meta")), 64 * 1024)?;
    let value: Value = serde_json::from_slice(&metadata)
        .context("Antigravity native session metadata is invalid")?;
    ensure!(
        value.is_object(),
        "Antigravity native metadata is not an object"
    );
    let brain = source.join("brain").join(id);
    if brain.exists() {
        let root = acp.join("brain");
        make_directory(&root)?;
        let dest = root.join(id);
        ensure!(!dest.exists(), "Partial Antigravity session import exists");
        let mut budget = 64 * 1024 * 1024;
        let mut files = 0;
        copy_tree(&brain, &dest, &mut budget, &mut files, 0)?;
    }
    write_new(&target.join(format!("{id}.meta")), &metadata, 0o600)?;
    write_new(&db, &bytes, 0o600)?;
    Ok(())
}
fn copy_tree(
    source: &Path,
    target: &Path,
    budget: &mut usize,
    files: &mut usize,
    depth: usize,
) -> Result<()> {
    ensure!(
        depth < 16 && *files < 2048,
        "Antigravity session artifacts exceed import limits"
    );
    check_components(source)?;
    ensure!(
        source.is_dir(),
        "Antigravity session artifacts are not a directory"
    );
    make_directory(target)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let path = entry.path();
        *files += 1;
        ensure!(*files <= 2048, "Antigravity session has too many artifacts");
        safe_file(&path, false)?;
        if path.is_dir() {
            copy_tree(
                &path,
                &target.join(entry.file_name()),
                budget,
                files,
                depth + 1,
            )?;
        } else {
            let bytes = read(&path, *budget)?;
            *budget -= bytes.len();
            write_new(&target.join(entry.file_name()), &bytes, 0o600)?;
        }
    }
    Ok(())
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
        "GEMINI_HOME",
        "AGY_ACP_FORCE_FILE_STORAGE",
        "ANTIGRAVITY_HARNESS_PATH",
        "BROWSER",
        "PYTHONUNBUFFERED",
        "ELECTRON_RUN_AS_NODE",
    ];
    std::env::vars_os()
        .filter_map(|(key, _)| key.into_string().ok())
        .filter(|key| KEYS.contains(&key.to_ascii_uppercase().as_str()))
        .collect()
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
    Ok(format!("{:x}", hash.finalize()))
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
    fn source(root: &Path) -> PathBuf {
        let source = root.join("source");
        fs::create_dir_all(source.join("antigravity-acp/conversations")).unwrap();
        fs::write(
            source.join("antigravity-acp/acp_token.json"),
            json!({"client_id":"fixture","client_secret":"fixture","refresh_token":"fixture"})
                .to_string(),
        )
        .unwrap();
        source
    }
    #[test]
    fn antigravity_profile_rejects_overlap_and_account_rebinding_before_source_writes() {
        let root = tempfile::tempdir().unwrap();
        let original = source(root.path());
        let target = root.path().join("private");
        assert!(
            Profile::prepare(&original.join("must-not-create"), Some(&original), None).is_err()
        );
        assert!(!original.join("must-not-create").exists());
        let first = Profile::prepare(&target, Some(&original), None).unwrap();
        assert!(Profile::prepare(&target, Some(&original), None).is_err());
        drop(first);
        let second = root.path().join("second");
        fs::create_dir(&second).unwrap();
        assert!(Profile::prepare(&target, Some(&second), None).is_err());
        let token = target.join("antigravity-acp/acp_token.json");
        fs::remove_file(&token).unwrap();
        fs::hard_link(original.join("antigravity-acp/acp_token.json"), &token).unwrap();
        assert!(Profile::prepare(&target, Some(&original), None).is_err());
    }
    #[test]
    fn antigravity_live_native_sqlite_import_is_rejected_without_modifying_source() {
        let root = tempfile::tempdir().unwrap();
        let original = source(root.path());
        let id = "3f2b8c1e-9d4a-4b6f-8e2d-1c0a9b8f7e6d";
        let conversations = original.join("antigravity-acp/conversations");
        let db = conversations.join(format!("{id}.db"));
        let wal = conversations.join(format!("{id}.db-wal"));
        fs::write(&db, b"original").unwrap();
        fs::write(&wal, b"uncheckpointed").unwrap();
        let error = Profile::prepare(&root.path().join("private"), Some(&original), Some(id))
            .err()
            .unwrap();
        assert!(error.to_string().contains("live SQLite sidecars"));
        assert_eq!(fs::read(db).unwrap(), b"original");
        assert_eq!(fs::read(wal).unwrap(), b"uncheckpointed");
        assert_eq!(fs::read_dir(conversations).unwrap().count(), 2);
    }
}
