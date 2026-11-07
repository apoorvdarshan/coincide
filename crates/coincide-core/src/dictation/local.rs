//! Local whisper.cpp `whisper-cli` backend. No installation, model download,
//! microphone capture, networking or implicit executable/model discovery.
#[cfg(any(unix, windows))]
use super::transcription::{self, Response};
use super::{DictationError, Transcriber};
#[cfg(unix)]
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    os::unix::{
        fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
        process::CommandExt,
    },
    process::{Command, Stdio},
    time::Instant,
};
use std::{path::PathBuf, time::Duration};

#[cfg(any(unix, windows))]
const MAX_WAV: usize = 25_000_000;
#[cfg(any(unix, windows))]
const MAX_OUTPUT: usize = 1_048_576;
#[derive(Debug, PartialEq, Eq)]
pub enum LocalError {
    UnsupportedPlatform,
    InvalidConfiguration,
    InvalidAudio,
    TooLarge,
    Unavailable,
    TimedOut,
    ProcessFailed,
    InvalidOutput,
    Cancelled,
    CleanupPending,
}
/// A configuration check is not proof that a model loads or inference works.
pub struct LocalWhisper {
    executable: PathBuf,
    model: PathBuf,
    language: String,
    threads: usize,
    timeout: Duration,
}
impl LocalWhisper {
    pub fn new(
        executable: PathBuf,
        model: PathBuf,
        language: String,
        threads: usize,
        timeout: Duration,
    ) -> Result<Self, LocalError> {
        let backend = Self {
            executable,
            model,
            language,
            threads,
            timeout,
        };
        backend.check_configuration()?;
        Ok(backend)
    }
    pub fn check_configuration(&self) -> Result<(), LocalError> {
        if !cfg!(any(unix, windows)) {
            return Err(LocalError::UnsupportedPlatform);
        }
        if !self.executable.is_absolute()
            || !self.model.is_absolute()
            || !self.executable.is_file()
            || !self.model.is_file()
            || self.threads == 0
            || self.threads > 64
            || self.timeout < Duration::from_millis(10)
            || self.timeout > Duration::from_secs(600)
            || self.language.is_empty()
            || self.language.len() > 16
            || !self
                .language
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b == b'-')
        {
            return Err(LocalError::InvalidConfiguration);
        }
        #[cfg(unix)]
        if fs::metadata(&self.executable)
            .map_err(|_| LocalError::Unavailable)?
            .permissions()
            .mode()
            & 0o111
            == 0
        {
            return Err(LocalError::InvalidConfiguration);
        }
        #[cfg(windows)]
        windows::configuration(self)?;
        Ok(())
    }
    #[cfg(not(any(unix, windows)))]
    pub fn transcribe_local(&mut self, _wav: &[u8]) -> Result<String, LocalError> {
        Err(LocalError::UnsupportedPlatform)
    }
    #[cfg(any(unix, windows))]
    pub fn transcribe_local(&mut self, wav: &[u8]) -> Result<String, LocalError> {
        self.transcribe_local_cancellable(wav, || false)
    }
    /// Cancellation is checked before launch and while waiting. Success,
    /// cancellation and timeout require owned child teardown. CleanupPending
    /// explicitly retains private audio if teardown/removal cannot be confirmed.
    pub fn transcribe_local_cancellable(
        &self,
        wav: &[u8],
        cancelled: impl Fn() -> bool,
    ) -> Result<String, LocalError> {
        if cancelled() {
            return Err(LocalError::Cancelled);
        }
        let lease =
            super::model_assets::acquire_model_path(&self.model, &cancelled).map_err(|error| {
                if error == super::model_assets::Error::Cancelled {
                    LocalError::Cancelled
                } else {
                    LocalError::Unavailable
                }
            })?;
        let result = self.transcribe_local_with_lease(wav, &lease, cancelled);
        if result == Err(LocalError::CleanupPending) {
            super::model_assets::retain_uncertain(lease);
        }
        result
    }
    /// The native owner retains this same physical-file lease through capture,
    /// inference and eventual transcript admission/discard.
    pub fn transcribe_local_with_lease(
        &self,
        wav: &[u8],
        lease: &super::model_assets::ModelReadLease,
        cancelled: impl Fn() -> bool,
    ) -> Result<String, LocalError> {
        self.check_configuration()?;
        if cancelled() {
            return Err(LocalError::Cancelled);
        }
        if !lease.matches_path(&self.model) {
            return Err(LocalError::InvalidConfiguration);
        }
        #[cfg(unix)]
        {
            self.transcribe_after_spawn_cancellable(wav, || Ok(()), &cancelled)
        }
        #[cfg(windows)]
        {
            windows::transcribe(self, wav, &cancelled)
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (wav, cancelled);
            Err(LocalError::UnsupportedPlatform)
        }
    }
    #[cfg(all(test, unix))]
    fn transcribe_after_spawn(
        &self,
        wav: &[u8],
        after_spawn: impl FnOnce() -> Result<(), LocalError>,
    ) -> Result<String, LocalError> {
        self.transcribe_after_spawn_cancellable(wav, after_spawn, &|| false)
    }
    #[cfg(unix)]
    fn transcribe_after_spawn_cancellable(
        &self,
        wav: &[u8],
        after_spawn: impl FnOnce() -> Result<(), LocalError>,
        cancelled: &impl Fn() -> bool,
    ) -> Result<String, LocalError> {
        self.check_configuration()?;
        validate_input(wav)?;
        if cancelled() {
            return Err(LocalError::Cancelled);
        }
        // Drop order matters: process group is always torn down/reaped before
        // this directory is removed, on success and on every failure path.
        let directory = PrivateDirectory::create()?;
        let result = self.run_in_directory(wav, &directory, after_spawn, cancelled);
        directory.cleanup()?;
        result
    }
    #[cfg(unix)]
    fn run_in_directory(
        &self,
        wav: &[u8],
        directory: &PrivateDirectory,
        after_spawn: impl FnOnce() -> Result<(), LocalError>,
        cancelled: &impl Fn() -> bool,
    ) -> Result<String, LocalError> {
        let input = directory.0.join("dictation.wav");
        let prefix = directory.0.join("transcript");
        let output = prefix.with_extension("json");
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&input)
            .map_err(|_| LocalError::Unavailable)?;
        file.write_all(wav).map_err(|_| LocalError::Unavailable)?;
        drop(file);
        let mut command = Command::new(&self.executable);
        command
            .args(["-m"])
            .arg(&self.model)
            .arg("-f")
            .arg(&input)
            .arg("-oj")
            .arg("-of")
            .arg(&prefix)
            .arg("-l")
            .arg(&self.language)
            .arg("-t")
            .arg(self.threads.to_string())
            .arg("-np")
            .current_dir(&directory.0)
            .process_group(0)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        // No inherited provider/vault tokens are needed by an offline tool.
        // Keep only platform library/tool environment necessities.
        let allowed: Vec<_> = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "SYSTEMROOT"]
            .into_iter()
            .filter_map(|key| std::env::var_os(key).map(|value| (key, value)))
            .collect();
        command.env_clear().envs(allowed);
        unsafe {
            command.pre_exec(|| {
                libc::umask(0o077);
                let limit = libc::rlimit {
                    rlim_cur: MAX_OUTPUT as libc::rlim_t,
                    rlim_max: MAX_OUTPUT as libc::rlim_t,
                };
                if libc::setrlimit(libc::RLIMIT_FSIZE, &limit) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        if cancelled() {
            return Err(LocalError::Cancelled);
        }
        let group = OwnedProcess(command.spawn().map_err(|_| LocalError::Unavailable)?);
        after_spawn()?;
        let started = Instant::now();
        loop {
            if cancelled() {
                return Err(LocalError::Cancelled);
            }
            if started.elapsed() >= self.timeout {
                return Err(LocalError::TimedOut);
            }
            match group.exited()? {
                Some(true) => break,
                Some(false) => return Err(LocalError::ProcessFailed),
                None => std::thread::sleep(Duration::from_millis(10)),
            }
        }
        // Kill surviving group members before reading a result they could alter.
        drop(group);
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&output)
            .map_err(|_| LocalError::InvalidOutput)?;
        let metadata = file.metadata().map_err(|_| LocalError::InvalidOutput)?;
        if !metadata.is_file()
            || metadata.nlink() != 1
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.permissions().mode() & 0o077 != 0
        {
            return Err(LocalError::InvalidOutput);
        }
        if metadata.len() > MAX_OUTPUT as u64 {
            return Err(LocalError::TooLarge);
        }
        let mut bytes = Vec::new();
        (&mut file)
            .take(MAX_OUTPUT as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| LocalError::InvalidOutput)?;
        if cancelled() {
            return Err(LocalError::Cancelled);
        }
        parse_output(&bytes)
    }
}
impl Transcriber for LocalWhisper {
    fn transcribe(&mut self, wav: &[u8]) -> Result<String, DictationError> {
        self.transcribe_local(wav)
            .map_err(|_| DictationError::Unavailable)
    }
}
#[cfg(any(unix, windows))]
fn validate_input(wav: &[u8]) -> Result<(), LocalError> {
    if wav.len() > MAX_WAV {
        return Err(LocalError::TooLarge);
    }
    // whisper.cpp's portable path consumes 16 kHz mono 16-bit PCM. Do not
    // silently relabel/resample another rate; capture must supply this format.
    if wav.len() < 46
        || &wav[..4] != b"RIFF"
        || &wav[8..16] != b"WAVEfmt "
        || &wav[36..40] != b"data"
    {
        return Err(LocalError::InvalidAudio);
    }
    let read32 = |i| u32::from_le_bytes(wav[i..i + 4].try_into().unwrap());
    let read16 = |i| u16::from_le_bytes(wav[i..i + 2].try_into().unwrap());
    if read32(4) as usize != wav.len() - 8
        || read32(16) != 16
        || read16(20) != 1
        || read16(22) != 1
        || read32(24) != 16_000
        || read32(28) != 32_000
        || read16(32) != 2
        || read16(34) != 16
        || read32(40) as usize != wav.len() - 44
        || !(wav.len() - 44).is_multiple_of(2)
    {
        return Err(LocalError::InvalidAudio);
    }
    Ok(())
}
#[cfg(any(unix, windows))]
fn parse_output(bytes: &[u8]) -> Result<String, LocalError> {
    if bytes.len() > MAX_OUTPUT {
        return Err(LocalError::TooLarge);
    }
    let value: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|_| LocalError::InvalidOutput)?;
    let segments = value["transcription"]
        .as_array()
        .ok_or(LocalError::InvalidOutput)?;
    let mut text = String::new();
    for segment in segments {
        let piece = segment["text"]
            .as_str()
            .ok_or(LocalError::InvalidOutput)?
            .trim();
        if !piece.is_empty() {
            if !text.is_empty() {
                text.push(' ');
            }
            text.push_str(piece);
        }
    }
    let body = serde_json::to_vec(&serde_json::json!({"text": text}))
        .map_err(|_| LocalError::InvalidOutput)?;
    transcription::transcript(Response { status: 200, body }).map_err(|_| LocalError::InvalidOutput)
}
#[cfg(unix)]
struct PrivateDirectory(PathBuf);
#[cfg(unix)]
impl PrivateDirectory {
    fn cleanup(&self) -> Result<(), LocalError> {
        fs::remove_dir_all(&self.0).map_err(|_| LocalError::Unavailable)
    }
    fn create() -> Result<Self, LocalError> {
        let path = std::env::temp_dir().join(format!("coincide-whisper-{}", uuid::Uuid::new_v4()));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .map_err(|_| LocalError::Unavailable)?;
        Ok(Self(path))
    }
}
#[cfg(unix)]
impl Drop for PrivateDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
#[cfg(unix)]
struct OwnedProcess(std::process::Child);
#[cfg(unix)]
impl OwnedProcess {
    fn exited(&self) -> Result<Option<bool>, LocalError> {
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        if unsafe {
            libc::waitid(
                libc::P_PID,
                self.0.id() as libc::id_t,
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        } != 0
        {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                return Ok(None);
            }
            return Err(LocalError::Unavailable);
        }
        if unsafe { info.si_pid() } == 0 {
            return Ok(None);
        }
        Ok(Some(
            info.si_code == libc::CLD_EXITED && unsafe { info.si_status() } == 0,
        ))
    }
}
#[cfg(unix)]
impl Drop for OwnedProcess {
    fn drop(&mut self) {
        unsafe {
            libc::kill(-(self.0.id() as i32), libc::SIGKILL);
        }
        let _ = self.0.wait();
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::path::Path;
    fn fixture(script: &str) -> (tempfile::TempDir, LocalWhisper) {
        let root = tempfile::tempdir().unwrap();
        let executable = root.path().join("fake whisper; no interpolation");
        let model = root.path().join("synthetic model.bin");
        fs::write(&model, b"not a real model").unwrap();
        fs::write(&executable, format!("#!/bin/sh\n{script}\n")).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let backend =
            LocalWhisper::new(executable, model, "en".into(), 2, Duration::from_secs(2)).unwrap();
        (root, backend)
    }
    const PARSE: &str = r#"
[ "$1" = '-m' ] || exit 10
model=$2
[ "$3" = '-f' ] || exit 11
input=$4
[ "$5" = '-oj' ] || exit 12
[ "$6" = '-of' ] || exit 13
prefix=$7
[ "$8" = '-l' ] || exit 14
[ "$9" = 'en' ] || exit 15
shift 9
[ "$1" = '-t' ] && [ "$2" = '2' ] && [ "$3" = '-np' ] || exit 16
[ -z "$BW_SESSION" ] && [ -z "$OPENAI_API_KEY" ] || exit 17
# Store only synthetic fixture locations for cleanup assertions, outside job dir.
printf '%s' "$(dirname "$input")" > "$(dirname "$model")/job-path"
"#;
    fn wav() -> Vec<u8> {
        transcription::encode_wav(&[0.0, 0.5, -0.5], 16_000).unwrap()
    }
    fn assert_removed(root: &Path) {
        let job = fs::read_to_string(root.join("job-path")).unwrap();
        assert!(
            !Path::new(&job).exists(),
            "temporary audio directory was retained"
        );
    }
    #[test]
    fn fake_whisper_executes_and_inserts_transcript_with_private_files() {
        let script = format!(
            r#"{PARSE}
# Observe exact modes without depending on platform-specific stat syntax.
ls -ld "$(dirname "$input")" | cut -c1-10 > "$(dirname "$model")/dir-mode"
ls -l "$input" | cut -c1-10 > "$(dirname "$model")/file-mode"
printf '%s' '{{"transcription":[{{"text":" world "}},{{"text":" fixture"}}]}}' > "$prefix.json"
"#
        );
        let (root, mut backend) = fixture(&script);
        let mut composer = "Hello!".to_owned();
        let mut session = super::super::DictationSession::start(&composer, 5..5).unwrap();
        session.finish(&mut composer, &wav(), &mut backend).unwrap();
        assert_eq!(composer, "Hello world fixture!");
        assert_eq!(
            fs::read_to_string(root.path().join("dir-mode"))
                .unwrap()
                .trim(),
            "drwx------"
        );
        assert_eq!(
            fs::read_to_string(root.path().join("file-mode"))
                .unwrap()
                .trim(),
            "-rw-------"
        );
        assert_removed(root.path());
    }
    #[test]
    fn nonzero_and_invalid_output_fail_and_remove_audio() {
        for suffix in ["exit 7", "printf malformed > \"$prefix.json\""] {
            let (root, mut backend) = fixture(&format!("{PARSE}\n{suffix}"));
            assert!(backend.transcribe_local(&wav()).is_err());
            assert_removed(root.path());
        }
    }
    #[test]
    fn timeout_kills_descendants_and_removes_audio() {
        let (root, mut backend) = fixture(&format!(
            "{PARSE}\nsleep 60 &\necho $! > \"$(dirname \"$model\")/child-pid\"\nwait"
        ));
        backend.timeout = Duration::from_millis(200);
        let start = Instant::now();
        // Exercise timeout cleanup only after this fixture's descendant exists.
        // Scheduling under the full parallel suite may exceed the runtime budget
        // before /bin/sh reaches PARSE; elapsed time alone is not readiness.
        let pid_path = root.path().join("child-pid");
        let result = backend.transcribe_after_spawn(&wav(), || {
            let deadline = Instant::now() + Duration::from_secs(2);
            while !fs::read_to_string(&pid_path).is_ok_and(|s| s.trim().parse::<i32>().is_ok()) {
                if Instant::now() >= deadline {
                    return Err(LocalError::Unavailable);
                }
                std::thread::yield_now();
            }
            Ok(())
        });
        assert_eq!(result, Err(LocalError::TimedOut));
        assert!(start.elapsed() < Duration::from_secs(3));
        assert_removed(root.path());
        let pid: i32 = fs::read_to_string(root.path().join("child-pid"))
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if unsafe { libc::kill(pid, 0) } != 0 {
                break;
            }
            #[cfg(target_os = "linux")]
            if fs::read_to_string(format!("/proc/{pid}/stat"))
                .is_ok_and(|s| s.split_whitespace().nth(2) == Some("Z"))
            {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "synthetic descendant survived cleanup"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    #[test]
    fn output_limit_and_symlink_are_rejected() {
        for suffix in [
            "yes synthetic | head -c 2097152 > \"$prefix.json\"",
            "ln -s \"$model\" \"$prefix.json\"",
        ] {
            let (root, mut backend) = fixture(&format!("{PARSE}\n{suffix}"));
            assert!(backend.transcribe_local(&wav()).is_err());
            assert_removed(root.path());
        }
    }
    #[test]
    fn configuration_and_audio_reject_before_spawn() {
        let (root, mut backend) = fixture(&format!("{PARSE}\nexit 0"));
        assert_eq!(
            backend.transcribe_local(b"not audio"),
            Err(LocalError::InvalidAudio)
        );
        let wrong_rate = transcription::encode_wav(&[0.0], 44_100).unwrap();
        assert_eq!(
            backend.transcribe_local(&wrong_rate),
            Err(LocalError::InvalidAudio)
        );
        backend.language = "en; touch injected".into();
        assert_eq!(
            backend.transcribe_local(&wav()),
            Err(LocalError::InvalidConfiguration)
        );
        assert!(!root.path().join("job-path").exists());
    }
}

#[cfg(all(test, not(any(unix, windows))))]
mod platform_tests {
    use super::*;
    #[test]
    fn unsupported_platform_cannot_report_ready() {
        assert!(matches!(
            LocalWhisper::new(
                PathBuf::from("whisper-cli"),
                PathBuf::from("model.bin"),
                "en".into(),
                2,
                Duration::from_secs(1)
            ),
            Err(LocalError::UnsupportedPlatform)
        ));
    }
}

#[cfg(windows)]
#[path = "local_windows.rs"]
mod windows;
