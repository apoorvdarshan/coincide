#[cfg(target_os = "macos")]
mod macos {
    use anyhow::{Context, Result, bail, ensure};
    use coincide_awake_helper::{
        AudioState, LidHardware, LidWatcher, Preferences, battery_change, journal::FileJournal,
    };
    use rusqlite::{Connection, OpenFlags, OptionalExtension};
    use std::{
        ffi::{CStr, CString, c_char, c_int, c_void},
        fs,
        os::unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, PermissionsExt},
        },
        path::{Path, PathBuf},
        process::{Command, Stdio},
        time::{Duration, Instant},
    };

    unsafe extern "C" {
        fn coincide_awake_lid_state() -> c_int;
        fn coincide_awake_sleep_disabled() -> c_int;
        fn coincide_awake_on_battery() -> c_int;
        fn coincide_awake_idle_seconds() -> f64;
        fn coincide_awake_default_output(
            uid: *mut c_char,
            capacity: usize,
            muted: *mut c_int,
        ) -> c_int;
        fn coincide_awake_output_muted(uid: *const c_char, muted: *mut c_int) -> c_int;
        fn coincide_awake_set_output_muted(uid: *const c_char, muted: c_int) -> c_int;
        fn coincide_awake_run_lid(
            context: *mut c_void,
            callback: unsafe extern "C" fn(*mut c_void, c_int) -> c_int,
        ) -> c_int;
        fn coincide_awake_run_power(
            context: *mut c_void,
            callback: unsafe extern "C" fn(*mut c_void, c_int) -> c_int,
        ) -> c_int;
    }

    fn observed(value: c_int) -> Option<bool> {
        match value {
            0 => Some(false),
            1 => Some(true),
            _ => None,
        }
    }

    fn run_pmset(arguments: &[&str]) -> Result<()> {
        let mut child = Command::new("/usr/bin/pmset")
            .args(arguments)
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .context("Could not start macOS power control")?;
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = child.try_wait()? {
                ensure!(status.success(), "macOS rejected the power change");
                return Ok(());
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                bail!("macOS power control timed out");
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    struct Hardware;
    impl LidHardware for Hardware {
        fn sleep_displays(&mut self) -> Result<()> {
            run_pmset(&["displaysleepnow"])
        }
        fn idle_seconds(&mut self) -> Result<Option<f64>> {
            let value = unsafe { coincide_awake_idle_seconds() };
            Ok((value.is_finite() && value >= 0.).then_some(value))
        }
        fn default_output(&mut self) -> Result<Option<AudioState>> {
            let mut uid = [0u8; 1025];
            let mut muted = 0;
            if unsafe {
                coincide_awake_default_output(uid.as_mut_ptr().cast(), uid.len(), &mut muted)
            } != 1
            {
                return Ok(None);
            }
            let uid = CStr::from_bytes_until_nul(&uid)?.to_str()?.to_owned();
            ensure!(
                !uid.is_empty() && uid.len() <= 1024,
                "Invalid output device identity"
            );
            Ok(Some(AudioState {
                uid,
                muted: muted != 0,
            }))
        }
        fn output_muted(&mut self, uid: &str) -> Result<Option<bool>> {
            let uid = CString::new(uid)?;
            let mut muted = 0;
            Ok(
                (unsafe { coincide_awake_output_muted(uid.as_ptr(), &mut muted) } == 1)
                    .then_some(muted != 0),
            )
        }
        fn set_output_muted(&mut self, uid: &str, muted: bool) -> Result<bool> {
            let uid = CString::new(uid)?;
            Ok(unsafe { coincide_awake_set_output_muted(uid.as_ptr(), i32::from(muted)) } == 1)
        }
    }

    fn data_directory() -> Result<PathBuf> {
        // launchd may not provide HOME. Resolve the account from the real UID;
        // do not accept a caller-supplied path or the root account's home.
        let uid = unsafe { libc::getuid() };
        ensure!(
            uid != 0 && unsafe { libc::geteuid() } == uid,
            "Lid helper requires the logged-in user"
        );
        let mut record: libc::passwd = unsafe { std::mem::zeroed() };
        let mut storage = vec![0u8; 32 * 1024];
        let mut result = std::ptr::null_mut();
        let code = unsafe {
            libc::getpwuid_r(
                uid,
                &mut record,
                storage.as_mut_ptr().cast(),
                storage.len(),
                &mut result,
            )
        };
        ensure!(
            code == 0 && !result.is_null() && !record.pw_dir.is_null(),
            "Could not locate the user's home directory"
        );
        let home = unsafe { CStr::from_ptr(record.pw_dir) }.to_bytes();
        let home = PathBuf::from(std::ffi::OsStr::from_bytes(home));
        ensure!(home.is_absolute(), "Invalid home directory");
        Ok(home.join("Library/Application Support/Coincide Rust"))
    }

    fn read_preferences(directory: &Path) -> Result<Preferences> {
        let path = directory.join("coincide.sqlite");
        let metadata = fs::symlink_metadata(&path)?;
        ensure!(
            metadata.is_file()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.permissions().mode() & 0o077 == 0,
            "Keep Awake database is not private"
        );
        let connection = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        connection.busy_timeout(Duration::from_millis(250))?;
        let raw: Option<String> = connection
            .query_row(
                "SELECT document FROM documents WHERE name = ?1",
                ["rust-persistent-awake.json"],
                |row| row.get(0),
            )
            .optional()?;
        ensure!(
            raw.as_ref().is_none_or(|raw| raw.len() <= 64 * 1024),
            "Keep Awake settings are too large"
        );
        let document = raw.as_deref().map(serde_json::from_str).transpose()?;
        Preferences::from_document(document.as_ref())
    }

    struct LidContext {
        directory: PathBuf,
        journal: FileJournal,
        watcher: LidWatcher,
        hardware: Hardware,
    }
    impl LidContext {
        fn event(&mut self, event: c_int) -> Result<c_int> {
            if event == 3 {
                let _ = self.watcher.stop(&mut self.hardware, &mut self.journal)?;
                return Ok(-1);
            }
            let preferences = read_preferences(&self.directory)?;
            if !preferences.enabled {
                let _ = self.watcher.stop(&mut self.hardware, &mut self.journal)?;
                return Ok(-1);
            }
            let lid = observed(unsafe { coincide_awake_lid_state() });
            Ok(i32::from(self.watcher.update(
                &mut self.hardware,
                &mut self.journal,
                preferences,
                lid,
                event == 2,
            )?))
        }
    }
    unsafe extern "C" fn lid_callback(context: *mut c_void, event: c_int) -> c_int {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let context = unsafe { &mut *context.cast::<LidContext>() };
            context.event(event)
        }));
        match result {
            Ok(Ok(value)) => value,
            Ok(Err(_)) => {
                eprintln!("Keep Awake could not observe or restore its state; it will retry.");
                1
            }
            Err(_) => {
                eprintln!("Keep Awake helper stopped unexpectedly.");
                -1
            }
        }
    }
    unsafe extern "C" fn battery_callback(_: *mut c_void, _: c_int) -> c_int {
        let result = std::panic::catch_unwind(|| {
            let battery = observed(unsafe { coincide_awake_on_battery() });
            let current = observed(unsafe { coincide_awake_sleep_disabled() });
            if let Some(disabled) = battery_change(battery, current) {
                run_pmset(&["-a", "disablesleep", if disabled { "1" } else { "0" }])?;
            }
            Ok::<_, anyhow::Error>(())
        });
        if !matches!(result, Ok(Ok(()))) {
            eprintln!("Keep Awake could not update the battery sleep policy; it will retry.");
        }
        0
    }

    pub fn run(mode: &str) -> Result<()> {
        match mode {
            "--battery" => {
                ensure!(
                    unsafe { libc::getuid() } == 0 && unsafe { libc::geteuid() } == 0,
                    "Battery helper requires its approved system service"
                );
                ensure!(
                    unsafe { coincide_awake_run_power(std::ptr::null_mut(), battery_callback) }
                        == 0,
                    "Could not observe the power source"
                );
            }
            "--lid" | "--restore-audio" => {
                let directory = data_directory()?;
                let journal = FileJournal::new(&directory)?;
                let mut context = LidContext {
                    directory,
                    journal,
                    watcher: LidWatcher::default(),
                    hardware: Hardware,
                };
                if mode == "--restore-audio" {
                    ensure!(
                        context
                            .watcher
                            .stop(&mut context.hardware, &mut context.journal)?,
                        "An audio device is unavailable; its saved mute state is retained"
                    );
                } else {
                    ensure!(
                        unsafe {
                            coincide_awake_run_lid(
                                (&mut context as *mut LidContext).cast(),
                                lid_callback,
                            )
                        } == 0,
                        "Could not observe the Mac's lid"
                    );
                }
            }
            _ => bail!("Unknown Keep Awake helper mode"),
        }
        Ok(())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn preferences_are_read_from_a_private_fixture_database() {
            let temp = tempfile::tempdir().unwrap();
            fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
            let path = temp.path().join("coincide.sqlite");
            let db = Connection::open(&path).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            db.execute_batch(
                "CREATE TABLE documents(name TEXT PRIMARY KEY, document TEXT NOT NULL)",
            )
            .unwrap();
            db.execute(
                "INSERT INTO documents VALUES (?1, ?2)",
                [
                    "rust-persistent-awake.json",
                    r#"{"version":1,"stage":"enabled","options":{"muteWhileClosed":true}}"#,
                ],
            )
            .unwrap();
            let prefs = read_preferences(temp.path()).unwrap();
            assert!(prefs.enabled && prefs.display_off_on_close && prefs.mute_while_closed);
            fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
            assert!(read_preferences(temp.path()).is_err());
        }

        #[test]
        fn privileged_service_rejects_a_normal_user() {
            if unsafe { libc::getuid() } != 0 {
                assert!(run("--battery").is_err());
            }
        }
    }
}

fn main() {
    #[cfg(target_os = "macos")]
    {
        let args: Vec<_> = std::env::args().collect();
        if args.len() != 2 {
            eprintln!("Keep Awake helper requires one fixed service mode.");
            std::process::exit(2);
        }
        if let Err(error) = macos::run(&args[1]) {
            eprintln!("Keep Awake helper: {error}");
            std::process::exit(1);
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        eprintln!("The Keep Awake helper is available only on macOS.");
        std::process::exit(1);
    }
}
