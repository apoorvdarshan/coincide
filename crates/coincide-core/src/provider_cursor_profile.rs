//! A private Cursor profile keeps model writes and native-session resumes away
//! from the active app's profile. Inactive native databases are copied before SQLite opens them.
use super::*;
#[path = "provider_cursor_auth.rs"]
mod auth;
#[cfg(target_os = "macos")]
pub(crate) use auth::capture as usage_keychain_capture;
pub(crate) use auth::native_access_token as usage_keychain_access_token;
use rusqlite::{
    Connection, OpenFlags,
    backup::{Backup, StepResult},
};
use std::{
    ffi::OsString,
    fs::{self, File, OpenOptions},
    path::{Component, Path},
};

pub(super) struct Profile {
    pub directory: PathBuf,
    pub default_model: Option<String>,
    _lock: File,
    authentication: auth::Authentication,
}
impl Profile {
    pub fn prepare(directory: &Path, session: Option<&str>) -> Result<Self> {
        let source = source_directory()?;
        Self::prepare_with_auth(directory, &source, session, auth::Authentication::resolve)
    }
    #[cfg(test)]
    fn prepare_from(directory: &Path, source: &Path, session: Option<&str>) -> Result<Self> {
        Self::prepare_with_auth(directory, source, session, |_| {
            Ok(auth::Authentication::inherited())
        })
    }
    fn prepare_with_auth(
        directory: &Path,
        source: &Path,
        session: Option<&str>,
        resolve: impl FnOnce(Option<u64>) -> Result<auth::Authentication>,
    ) -> Result<Self> {
        ensure!(
            directory.is_absolute() && source.is_absolute(),
            "Cursor profile paths must be absolute"
        );
        check_components(directory)?;
        let directory = resolve_without_creation(directory)?;
        let source = resolve_without_creation(source)?;
        ensure!(
            !directory.starts_with(&source) && !source.starts_with(&directory),
            "Cursor private profile must be separate from the original profile"
        );
        // One bounded source snapshot fixes both model and routing selection.
        // Validate identity/routing before creating or mutating a private profile.
        let (mut config, selected_team) = source_config(&source)?;
        let authentication = resolve(selected_team)?;
        if let Some(team) = selected_team {
            ensure!(
                authentication.reused_stored_login(),
                "Cursor selected team cannot be inherited without the existing stored CLI login"
            );
            config["authInfo"] = json!({"activeTeamId": team});
        }
        if !directory.exists() {
            fs::create_dir_all(&directory)?;
            private_permissions(&directory, 0o700)?;
        }
        check_private(&directory)?;
        let marker = directory.join(".coincide-profile");
        if !marker.exists() {
            ensure!(
                fs::read_dir(&directory)?.next().is_none(),
                "Cursor profile directory already contains unrelated files"
            );
            write_new(&marker, b"Coincide isolated Cursor profile v1\n")?;
        } else {
            ensure!(
                read_bounded(&marker, 128)? == b"Coincide isolated Cursor profile v1\n",
                "Cursor profile marker is invalid"
            );
        }
        let lock_path = directory.join(".lock");
        check_no_symlink(&lock_path)?;
        check_single_link(&lock_path)?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let lock = options.open(&lock_path)?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            ensure!(
                unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
                "Cursor private profile is already in use"
            );
        }
        #[cfg(not(unix))]
        {
            lock.try_lock()
                .context("Cursor private profile is already in use")?;
        }
        // Global/project allowlists and unrestricted defaults are deliberately
        // excluded; every new process starts with approval-only defaults.
        config["approvalMode"] = json!("allowlist");
        config["permissions"] = json!({"allow":[],"deny":[]});
        let default_model = config["selectedModel"]["modelId"]
            .as_str()
            .filter(|model| !model.is_empty())
            .or_else(|| {
                config["model"]["modelId"]
                    .as_str()
                    .filter(|model| !model.is_empty())
            })
            .map(str::to_owned);
        replace_private(
            &directory.join("cli-config.json"),
            &serde_json::to_vec(&config)?,
        )?;
        private_directory(&directory.join("artifacts"))?;
        private_directory(&directory.join("acp-sessions"))?;
        if let Some(session) = session {
            ensure!(
                valid_session_id(session),
                "Cursor session ID is not a safe native identifier"
            );
            let target = directory.join("acp-sessions").join(session);
            check_no_symlink(&target)?;
            let db = target.join("store.db");
            if !db.exists() {
                let original = source.join("acp-sessions").join(session).join("store.db");
                check_components(&original)?;
                ensure!(
                    original.is_file(),
                    "Cursor native session is unavailable; no replacement was created"
                );
                ensure!(
                    original.metadata()?.len() <= 64 * 1024 * 1024,
                    "Cursor session exceeds the 64 MiB import limit"
                );
                let snapshot = source_snapshot(&original)?;
                private_directory(&target)?;
                let staged = target.join(format!(".source-{}.db", uuid::Uuid::new_v4()));
                write_new(&staged, &snapshot)?;
                drop(snapshot);
                let temporary = target.join(format!(".import-{}.db", uuid::Uuid::new_v4()));
                write_new(&temporary, b"")?;
                let imported = (|| -> Result<()> {
                    let source = Connection::open_with_flags(
                        &staged,
                        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
                    )?;
                    source.busy_timeout(Duration::from_millis(100))?;
                    let mut destination = Connection::open(&temporary)?;
                    {
                        let backup = Backup::new(&source, &mut destination)?;
                        let deadline = Instant::now() + Duration::from_secs(3);
                        loop {
                            ensure!(
                                Instant::now() < deadline,
                                "Cursor session snapshot timed out; original was not changed"
                            );
                            match backup.step(128)? {
                                StepResult::Done => break,
                                StepResult::More => {}
                                StepResult::Busy | StepResult::Locked => {
                                    thread::sleep(Duration::from_millis(10))
                                }
                                _ => bail!("Cursor session backup returned an unknown state"),
                            }
                        }
                    }
                    ensure!(
                        temporary.metadata()?.len() <= 64 * 1024 * 1024,
                        "Cursor session snapshot exceeds 64 MiB"
                    );
                    approval_metadata(&destination, session)?;
                    drop(destination);
                    fs::rename(&temporary, &db)?;
                    Ok(())
                })();
                if imported.is_err() {
                    let _ = fs::remove_file(&temporary);
                }
                for path in [
                    staged.clone(),
                    PathBuf::from(format!("{}-wal", staged.display())),
                    PathBuf::from(format!("{}-shm", staged.display())),
                    PathBuf::from(format!("{}-journal", staged.display())),
                ] {
                    let _ = fs::remove_file(path);
                }
                imported?;
                let meta = source.join("acp-sessions").join(session).join("meta.json");
                if meta.exists() {
                    replace_private(
                        &target.join("meta.json"),
                        &read_bounded(&meta, 1024 * 1024)?,
                    )?;
                }
            } else {
                check_no_symlink(&db)?;
                check_single_link(&db)?;
                for name in ["store.db-wal", "store.db-shm", "store.db-journal"] {
                    let sidecar = db.with_file_name(name);
                    check_no_symlink(&sidecar)?;
                    check_single_link(&sidecar)?;
                }
                #[cfg(not(unix))]
                bail!(
                    "Cursor private session alias verification is not available on this platform yet"
                );
                #[cfg(unix)]
                {
                    ensure!(
                        db.metadata()?.len() <= 64 * 1024 * 1024,
                        "Cursor private session exceeds 64 MiB"
                    );
                    approval_metadata(&Connection::open(&db)?, session)?;
                }
            }
        }
        Ok(Self {
            directory,
            default_model,
            _lock: lock,
            authentication,
        })
    }
    pub fn environment(&self) -> Vec<(OsString, OsString)> {
        let mut environment = vec![
            (
                "CURSOR_CONFIG_DIR".into(),
                self.directory.as_os_str().to_owned(),
            ),
            (
                "CURSOR_DATA_DIR".into(),
                self.directory.join("artifacts").into_os_string(),
            ),
            ("AGENT_CLI_CREDENTIAL_STORE".into(), "memory".into()),
            ("DIRENV_DISABLE".into(), "1".into()),
        ];
        self.authentication.append_environment(&mut environment);
        environment
    }
}
fn source_config(source: &Path) -> Result<(Value, Option<u64>)> {
    let mut config = json!({});
    let path = source.join("cli-config.json");
    if !path.exists() {
        return Ok((config, None));
    }
    let value: Value = serde_json::from_slice(&read_bounded(&path, 1024 * 1024)?)
        .context("Cursor model settings are invalid JSON")?;
    ensure!(value.is_object(), "Cursor model settings must be an object");
    let selected_team = match value.get("authInfo") {
        None | Some(Value::Null) => None,
        Some(Value::Object(info)) => match info.get("activeTeamId") {
            None | Some(Value::Null) => None,
            Some(Value::Number(number)) => {
                const JS_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
                let team = number
                    .as_u64()
                    .filter(|n| *n > 0 && *n <= JS_SAFE_INTEGER)
                    .or_else(|| {
                        number
                            .as_f64()
                            .filter(|n| {
                                n.is_finite()
                                    && *n >= 1.0
                                    && *n <= JS_SAFE_INTEGER as f64
                                    && n.fract() == 0.0
                            })
                            .map(|n| n as u64)
                    });
                Some(team.context("Cursor selected team routing is invalid")?)
            }
            Some(_) => bail!("Cursor selected team routing is invalid"),
        },
        Some(_) => bail!("Cursor selected team routing is invalid"),
    };
    for key in [
        "model",
        "selectedModel",
        "modelParameters",
        "hasChangedDefaultModel",
        "maxMode",
        "maxModeAutoEnabled",
        "modelSelectionHistory",
    ] {
        if let Some(value) = value.get(key) {
            config[key] = value.clone();
        }
    }
    Ok((config, selected_team))
}
fn source_directory() -> Result<PathBuf> {
    for name in ["CURSOR_CONFIG_DIR", "XDG_CONFIG_HOME", "HOME"] {
        if let Some(value) = std::env::var_os(name).filter(|value| !value.is_empty()) {
            let path = PathBuf::from(value);
            return Ok(match name {
                "XDG_CONFIG_HOME" => path.join("cursor"),
                "HOME" => path.join(".cursor"),
                _ => path,
            });
        }
    }
    bail!("Cursor original profile location is unavailable")
}
fn valid_session_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && !matches!(id, "." | "..")
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}
fn resolve_without_creation(path: &Path) -> Result<PathBuf> {
    if path.exists() {
        return Ok(path.canonicalize()?);
    }
    let name = path
        .file_name()
        .context("Cursor path has no final component")?;
    let parent = path.parent().context("Cursor path has no parent")?;
    Ok(resolve_without_creation(parent)?.join(name))
}
fn check_single_link(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        match fs::symlink_metadata(path) {
            Ok(metadata) => ensure!(
                metadata.nlink() == 1,
                "Cursor private file has multiple hard links"
            ),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}
fn check_no_symlink(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(meta) => ensure!(
            !meta.file_type().is_symlink(),
            "Cursor profile contains a symbolic link"
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    };
    Ok(())
}
fn check_components(path: &Path) -> Result<()> {
    let mut current = PathBuf::new();
    for component in path.components() {
        ensure!(
            !matches!(component, Component::ParentDir),
            "Cursor profile path may not contain parent traversal"
        );
        current.push(component);
        // A Windows canonical path begins with a verbatim disk prefix (\\?\C:).
        // It is not an addressable filesystem path until RootDir is appended.
        // Inspecting the incomplete prefix fails with ERROR_INVALID_FUNCTION.
        if matches!(component, Component::Prefix(_)) {
            continue;
        }
        // macOS's standard /var and /tmp aliases are system-owned roots.
        #[cfg(target_os = "macos")]
        if current == Path::new("/var") || current == Path::new("/tmp") {
            continue;
        }
        check_no_symlink(&current)?;
    }
    Ok(())
}
fn check_private(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = fs::metadata(path)?;
        ensure!(
            metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o077 == 0,
            "Cursor profile must be owned by this user with private permissions"
        );
    }
    Ok(())
}
fn private_permissions(path: &Path, mode: u32) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
    }
    #[cfg(not(unix))]
    let _ = (path, mode);
    Ok(())
}
fn private_directory(path: &Path) -> Result<()> {
    check_no_symlink(path)?;
    if !path.exists() {
        fs::create_dir(path)?;
        private_permissions(path, 0o700)?;
    }
    ensure!(path.is_dir(), "Cursor profile path is not a directory");
    check_private(path)
}
fn write_new(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}
fn replace_private(path: &Path, bytes: &[u8]) -> Result<()> {
    check_no_symlink(path)?;
    let temporary = path.with_file_name(format!(".settings-{}.tmp", uuid::Uuid::new_v4()));
    write_new(&temporary, bytes)?;
    let result = fs::rename(&temporary, path);
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result?;
    Ok(())
}
fn read_bounded(path: &Path, limit: usize) -> Result<Vec<u8>> {
    check_no_symlink(path)?;
    let file = File::open(path)?;
    ensure!(
        file.metadata()?.is_file() && file.metadata()?.len() <= limit as u64,
        "Cursor profile file exceeds its size limit"
    );
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= limit,
        "Cursor profile file grew beyond its size limit"
    );
    Ok(bytes)
}
fn source_snapshot(path: &Path) -> Result<Vec<u8>> {
    let check_inactive = || -> Result<()> {
        for name in ["store.db-wal", "store.db-journal"] {
            match fs::symlink_metadata(path.with_file_name(name)) {
                Ok(_) => bail!(
                    "Cursor native session has live SQLite sidecars; close/checkpoint it in its original client before importing"
                ),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }
        Ok(())
    };
    check_inactive()?;
    let first = read_bounded(path, 64 * 1024 * 1024)?;
    let second = read_bounded(path, 64 * 1024 * 1024)?;
    check_inactive()?;
    ensure!(
        first == second,
        "Cursor native session changed during import; retry after its original client closes it"
    );
    Ok(first)
}
fn approval_metadata(connection: &Connection, session: &str) -> Result<()> {
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    ensure!(
        version == 1,
        "Cursor native session schema is unsupported; no prompt was sent"
    );
    let encoded: String = connection
        .query_row("SELECT value FROM meta WHERE key='0'", [], |row| row.get(0))
        .context("Cursor native session metadata is missing")?;
    ensure!(
        encoded.len() <= 2 * 1024 * 1024 && encoded.len().is_multiple_of(2),
        "Cursor native metadata has an unsupported size"
    );
    let bytes = encoded
        .as_bytes()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| {
            let text = std::str::from_utf8(pair)?;
            u8::from_str_radix(text, 16).context("Cursor native metadata is not hexadecimal")
        })
        .collect::<Result<Vec<_>>>()?;
    let mut value: Value =
        serde_json::from_slice(&bytes).context("Cursor native metadata encoding is unsupported")?;
    ensure!(
        value.is_object() && value["agentId"].as_str() == Some(session),
        "Cursor native metadata is unsupported"
    );
    value["isRunEverything"] = json!(false);
    value["approvalMode"] = json!("allowlist");
    if value["mode"] == "auto-run" {
        value["mode"] = json!("default");
    }
    let encoded = serde_json::to_vec(&value)?
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    connection.execute("UPDATE meta SET value=?1 WHERE key='0'", [encoded])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    #[test]
    #[ignore = "requires COINCIDE_TEST_NATIVE_CURSOR pointing at an installed Cursor CLI"]
    fn native_cursor_discovers_user_and_project_mcps_with_the_private_profile() {
        let cli = std::env::var("COINCIDE_TEST_NATIVE_CURSOR").expect("set the test CLI path");
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let private = dir.path().join("private");
        let work = dir.path().join("work");
        fs::create_dir_all(home.join(".cursor")).unwrap();
        fs::create_dir_all(work.join(".cursor")).unwrap();
        fs::create_dir_all(&private).unwrap();
        fs::write(
            home.join(".cursor/mcp.json"),
            serde_json::to_vec(
                &json!({"mcpServers":{"SYNTHETIC_GLOBAL":{"command":"/nonexistent/synthetic"}}}),
            )
            .unwrap(),
        )
        .unwrap();
        fs::write(
            work.join(".cursor/mcp.json"),
            serde_json::to_vec(
                &json!({"mcpServers":{"SYNTHETIC_PROJECT":{"command":"/nonexistent/synthetic"}}}),
            )
            .unwrap(),
        )
        .unwrap();
        let output = std::process::Command::new(cli)
            .args(["--disable-project-configs", "mcp", "list"])
            .current_dir(&work)
            .env_clear()
            .env("PATH", "/opt/homebrew/bin:/usr/bin:/bin")
            .env("HOME", &home)
            .env("CURSOR_CONFIG_DIR", &private)
            .env("CURSOR_DATA_DIR", private.join("artifacts"))
            .env("AGENT_CLI_CREDENTIAL_STORE", "memory")
            .env("TERM", "dumb")
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert!(stdout.contains("SYNTHETIC_GLOBAL"));
        assert!(stdout.contains("SYNTHETIC_PROJECT"));
    }
    fn source() -> (tempfile::TempDir, PathBuf, Vec<u8>) {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("original");
        fs::create_dir(&source).unwrap();
        let bytes=br#"{"selectedModel":{"modelId":"user-model"},"approvalMode":"unrestricted","unknown":{"keep":true}}"#.to_vec();
        fs::write(source.join("cli-config.json"), &bytes).unwrap();
        (dir, source, bytes)
    }
    #[test]
    fn private_model_writes_and_locks_never_touch_original() {
        let (dir, source, bytes) = source();
        let target = dir.path().join("private");
        let profile = Profile::prepare_from(&target, &source, None).unwrap();
        assert_eq!(profile.default_model.as_deref(), Some("user-model"));
        assert!(Profile::prepare_from(&target, &source, None).is_err());
        fs::write(
            profile.directory.join("cli-config.json"),
            b"changed by provider",
        )
        .unwrap();
        assert_eq!(fs::read(source.join("cli-config.json")).unwrap(), bytes);
        assert!(
            profile
                .environment()
                .iter()
                .any(|(key, value)| key == "AGENT_CLI_CREDENTIAL_STORE" && value == "memory")
        );
        drop(profile);
        assert!(Profile::prepare_from(&target, &source, None).is_ok());
    }
    #[test]
    fn reused_login_is_child_environment_only_never_a_private_or_original_profile_write() {
        let (dir, source, config) = source();
        let original_auth = br#"{"accessToken":"synthetic-original-login","unknown":true}"#;
        fs::write(source.join("auth.json"), original_auth).unwrap();
        let target = dir.path().join("private");
        let mut profile = Profile::prepare_from(&target, &source, None).unwrap();
        profile.authentication =
            auth::Authentication::synthetic(b"synthetic-scoped-token".to_vec()).unwrap();
        let environment = profile.environment();
        assert!(environment.iter().any(|(key,value)| key=="CURSOR_AUTH_TOKEN" && value=="synthetic-scoped-token"));
        assert!(
            environment
                .iter()
                .any(|(key, value)| key == "AGENT_CLI_CREDENTIAL_STORE" && value == "memory")
        );
        assert!(!target.join("auth.json").exists());
        let private_config = fs::read(target.join("cli-config.json")).unwrap();
        assert!(
            !String::from_utf8(private_config)
                .unwrap()
                .contains("synthetic-scoped-token")
        );
        assert_eq!(fs::read(source.join("cli-config.json")).unwrap(), config);
        assert_eq!(fs::read(source.join("auth.json")).unwrap(), original_auth);
    }
    #[test]
    fn stored_login_preserves_only_explicit_safe_team_header_selection() {
        for team in [1, 42, 9_007_199_254_740_991u64] {
            let (dir, source, _) = source();
            let original = serde_json::to_vec(&json!({"selectedModel":{"modelId":"user-model"},
                "authInfo":{"activeTeamId":team,"teamId":999,"email":"synthetic@example.invalid","teamName":"private synthetic name","unknown":{"keep":true}},
                "unknown":{"unchanged":true}})).unwrap();
            fs::write(source.join("cli-config.json"), &original).unwrap();
            let target = dir.path().join("private");
            let profile = Profile::prepare_with_auth(&target, &source, None, |selected| {
                assert_eq!(selected, Some(team));
                auth::Authentication::synthetic(b"synthetic-stored-login".to_vec())
            })
            .unwrap();
            let private: Value =
                serde_json::from_slice(&fs::read(target.join("cli-config.json")).unwrap()).unwrap();
            // The installed CLI converts ONLY this field into x-cursor-team-id.
            // Cached teamId/display metadata must never become routing input.
            assert_eq!(private["authInfo"], json!({"activeTeamId":team}));
            assert_eq!(profile.default_model.as_deref(), Some("user-model"));
            assert_eq!(private["permissions"], json!({"allow":[],"deny":[]}));
            assert_eq!(fs::read(source.join("cli-config.json")).unwrap(), original);
        }
    }
    #[test]
    fn absent_or_null_team_never_promotes_cached_team_metadata_to_header() {
        for info in [
            Value::Null,
            json!({}),
            json!({"teamId":42}),
            json!({"activeTeamId":null,"teamId":42}),
        ] {
            let (dir, source, _) = source();
            let original = serde_json::to_vec(&json!({"authInfo":info})).unwrap();
            fs::write(source.join("cli-config.json"), &original).unwrap();
            let target = dir.path().join("private");
            let _profile = Profile::prepare_with_auth(&target, &source, None, |selected| {
                assert_eq!(selected, None);
                Ok(auth::Authentication::inherited())
            })
            .unwrap();
            let private: Value =
                serde_json::from_slice(&fs::read(target.join("cli-config.json")).unwrap()).unwrap();
            assert!(private.get("authInfo").is_none());
            assert_eq!(fs::read(source.join("cli-config.json")).unwrap(), original);
        }
    }
    #[test]
    fn invalid_or_unsafe_selected_team_fails_before_identity_read_or_profile_write() {
        for selected in [
            json!(0),
            json!(-1),
            json!(1.5),
            json!(9_007_199_254_740_992u64),
            json!(u64::MAX),
            json!("42"),
            json!(true),
            json!({}),
            json!([]),
        ] {
            let (dir, source, _) = source();
            let original =
                serde_json::to_vec(&json!({"authInfo":{"activeTeamId":selected}})).unwrap();
            fs::write(source.join("cli-config.json"), &original).unwrap();
            let target = dir.path().join("private");
            assert!(
                Profile::prepare_with_auth(&target, &source, None, |_| panic!(
                    "invalid routing must not invoke identity resolver"
                ))
                .is_err()
            );
            assert!(!target.exists());
            assert_eq!(fs::read(source.join("cli-config.json")).unwrap(), original);
        }
    }
    #[test]
    fn selected_team_requires_stored_login_provenance_before_any_private_write() {
        let (dir, source, _) = source();
        let original = br#"{"authInfo":{"activeTeamId":42,"teamId":42}}"#;
        fs::write(source.join("cli-config.json"), original).unwrap();
        let target = dir.path().join("private");
        assert!(
            Profile::prepare_with_auth(&target, &source, None, |_| Ok(
                auth::Authentication::inherited()
            ))
            .is_err()
        );
        assert!(!target.exists());
        assert_eq!(fs::read(source.join("cli-config.json")).unwrap(), original);
    }
    #[test]
    fn snapshot_preserves_native_id_blobs_unknown_metadata_and_original_permissions() {
        let (dir, source, config) = source();
        let session = source.join("acp-sessions/native");
        fs::create_dir_all(&session).unwrap();
        let db = Connection::open(session.join("store.db")).unwrap();
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA user_version=1; CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT); CREATE TABLE blobs(id TEXT PRIMARY KEY,data BLOB);").unwrap();
        let original=json!({"agentId":"native","isRunEverything":true,"mode":"auto-run","future":{"keep":true}}).to_string();
        let encoded = original
            .as_bytes()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        db.execute("INSERT INTO meta VALUES('0',?1)", [&encoded])
            .unwrap();
        db.execute(
            "INSERT INTO blobs VALUES('history',?1)",
            [b"preserved".as_slice()],
        )
        .unwrap();
        drop(db);
        let before = directory_files(&session);
        let profile =
            Profile::prepare_from(&dir.path().join("private"), &source, Some("native")).unwrap();
        let copy =
            Connection::open(profile.directory.join("acp-sessions/native/store.db")).unwrap();
        assert_eq!(
            copy.query_row("SELECT data FROM blobs", [], |row| row.get::<_, Vec<u8>>(0))
                .unwrap(),
            b"preserved"
        );
        assert_eq!(directory_files(&session), before);
        let changed = copy
            .query_row("SELECT value FROM meta", [], |row| row.get::<_, String>(0))
            .unwrap();
        let bytes = changed
            .as_bytes()
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
            .collect::<Vec<_>>();
        let metadata: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(metadata["agentId"], "native");
        assert_eq!(metadata["future"]["keep"], true);
        assert_eq!(metadata["isRunEverything"], false);
        assert_eq!(fs::read(source.join("cli-config.json")).unwrap(), config);
    }

    fn directory_files(directory: &Path) -> std::collections::BTreeMap<String, Vec<u8>> {
        fs::read_dir(directory)
            .unwrap()
            .map(|entry| {
                let path = entry.unwrap().path();
                (
                    path.file_name().unwrap().to_str().unwrap().to_owned(),
                    fs::read(path).unwrap(),
                )
            })
            .collect()
    }
    #[test]
    fn live_wal_import_does_not_modify_original_file_set_or_bytes() {
        let (dir, source, _) = source();
        let session = source.join("acp-sessions/native");
        fs::create_dir_all(&session).unwrap();
        let db = Connection::open(session.join("store.db")).unwrap();
        db.execute_batch("PRAGMA journal_mode=WAL;CREATE TABLE sample(value TEXT);INSERT INTO sample VALUES('live');").unwrap();
        let before = directory_files(&session);
        let result = Profile::prepare_from(&dir.path().join("private"), &source, Some("native"));
        assert!(
            result
                .err()
                .unwrap()
                .to_string()
                .contains("live SQLite sidecars")
        );
        assert_eq!(directory_files(&session), before);
    }
    #[cfg(unix)]
    #[test]
    fn writable_native_database_rejects_hardlinks_and_sidecar_symlinks() {
        use std::os::unix::fs::symlink;
        for alias in [
            "database",
            "store.db-wal",
            "store.db-shm",
            "store.db-journal",
        ] {
            let (dir, source, _) = source();
            let target = dir.path().join("private");
            drop(Profile::prepare_from(&target, &source, None).unwrap());
            let session = target.join("acp-sessions/native");
            fs::create_dir(&session).unwrap();
            let original = source.join("original.db");
            let db = Connection::open(&original).unwrap();
            db.execute_batch(
                "PRAGMA user_version=1; CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT);",
            )
            .unwrap();
            let encoded = json!({"agentId":"native","isRunEverything":true})
                .to_string()
                .as_bytes()
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>();
            db.execute("INSERT INTO meta VALUES('0',?1)", [&encoded])
                .unwrap();
            drop(db);
            let before = fs::read(&original).unwrap();
            if alias == "database" {
                fs::hard_link(&original, session.join("store.db")).unwrap();
            } else {
                fs::copy(&original, session.join("store.db")).unwrap();
                symlink(&original, session.join(alias)).unwrap();
            }
            assert!(Profile::prepare_from(&target, &source, Some("native")).is_err());
            assert_eq!(fs::read(&original).unwrap(), before);
        }
    }
    #[test]
    fn legacy_model_fallback_skips_empty_selected_model() {
        let (dir, source, _) = source();
        fs::write(
            source.join("cli-config.json"),
            br#"{"selectedModel":{"modelId":""},"model":{"modelId":"legacy"}}"#,
        )
        .unwrap();
        let profile = Profile::prepare_from(&dir.path().join("private"), &source, None).unwrap();
        assert_eq!(profile.default_model.as_deref(), Some("legacy"));
    }
    #[test]
    fn native_metadata_identity_must_match_the_requested_session() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "PRAGMA user_version=1;CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT);",
            )
            .unwrap();
        let encoded = json!({"agentId":"different","isRunEverything":true})
            .to_string()
            .as_bytes()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        connection
            .execute("INSERT INTO meta VALUES('0',?1)", [&encoded])
            .unwrap();
        assert!(approval_metadata(&connection, "expected").is_err());
        assert_eq!(
            connection
                .query_row("SELECT value FROM meta", [], |row| row.get::<_, String>(0))
                .unwrap(),
            encoded
        );
    }
    #[test]
    fn unknown_schema_and_profile_aliases_fail_closed() {
        let (dir, source, _) = source();
        assert!(Profile::prepare_from(&source, &source, None).is_err());
        let nested = source.join("must-not-create");
        assert!(Profile::prepare_from(&nested, &source, None).is_err());
        assert!(!nested.exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let target = dir.path().join("alias");
            symlink(&source, &target).unwrap();
            assert!(Profile::prepare_from(&target, &source, None).is_err());
        }
        let session = source.join("acp-sessions/native");
        fs::create_dir_all(&session).unwrap();
        let db = Connection::open(session.join("store.db")).unwrap();
        db.execute_batch("PRAGMA user_version=99").unwrap();
        assert!(
            Profile::prepare_from(&dir.path().join("private"), &source, Some("native")).is_err()
        );
        assert!(
            !dir.path()
                .join("private/acp-sessions/native/store.db")
                .exists()
        );
    }
}
