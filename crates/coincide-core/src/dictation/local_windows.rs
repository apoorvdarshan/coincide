//! Offline whisper-cli.exe: private owner-only files, fixed arguments and an
//! owned suspended child admitted to a kill-on-close Job before execution.
use super::{LocalError, LocalWhisper, MAX_OUTPUT, parse_output, validate_input};
use crate::github_api::windows::Process;
use std::{
    fs,
    io::{Read, Write},
    path::PathBuf,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

pub(super) fn configuration(backend: &LocalWhisper) -> Result<(), LocalError> {
    for path in [&backend.executable, &backend.model] {
        if !matches!(path.components().next(), Some(std::path::Component::Prefix(prefix))
            if matches!(prefix.kind(), std::path::Prefix::Disk(_) | std::path::Prefix::VerbatimDisk(_)))
        {
            return Err(LocalError::InvalidConfiguration);
        }
    }
    if !backend
        .executable
        .extension()
        .and_then(|value| value.to_str())
        .is_some_and(|value| value.eq_ignore_ascii_case("exe"))
    {
        return Err(LocalError::InvalidConfiguration);
    }
    let mut executable = crate::native_file::open_regular(&backend.executable, false)
        .map_err(|_| LocalError::InvalidConfiguration)?;
    let mut signature = [0; 2];
    executable
        .read_exact(&mut signature)
        .map_err(|_| LocalError::InvalidConfiguration)?;
    if signature != *b"MZ" {
        return Err(LocalError::InvalidConfiguration);
    }
    crate::native_file::open_regular(&backend.model, false)
        .map_err(|_| LocalError::InvalidConfiguration)?;
    Ok(())
}
struct Directory {
    path: PathBuf,
    identity: crate::native_file::Identity,
    cleanup_allowed: bool,
}
impl Directory {
    fn new() -> Result<Self, LocalError> {
        let path = std::env::temp_dir().join(format!("coincide-whisper-{}", uuid::Uuid::new_v4()));
        crate::native_file::private_directory(&path).map_err(|_| LocalError::Unavailable)?;
        let identity =
            crate::native_file::path_identity(&path).map_err(|_| LocalError::Unavailable)?;
        Ok(Self {
            path,
            identity,
            cleanup_allowed: true,
        })
    }
    fn cleanup(&mut self) -> Result<(), LocalError> {
        if !self.cleanup_allowed {
            return Err(LocalError::CleanupPending);
        }
        if crate::native_file::path_identity(&self.path).ok() != Some(self.identity) {
            return Err(LocalError::CleanupPending);
        }
        fs::remove_dir_all(&self.path).map_err(|_| LocalError::CleanupPending)?;
        self.cleanup_allowed = false;
        Ok(())
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = self.cleanup();
    }
}
pub(super) fn transcribe(
    backend: &LocalWhisper,
    wav: &[u8],
    cancelled: &impl Fn() -> bool,
) -> Result<String, LocalError> {
    validate_input(wav)?;
    configuration(backend)?;
    if cancelled() {
        return Err(LocalError::Cancelled);
    }
    let mut directory = Directory::new()?;
    let input = directory.path.join("dictation.wav");
    let prefix = directory.path.join("transcript");
    let output = prefix.with_extension("json");
    let mut file =
        crate::native_file::create_private_file(&input).map_err(|_| LocalError::Unavailable)?;
    file.write_all(wav).map_err(|_| LocalError::Unavailable)?;
    drop(file);
    // Preserve a private ACL if the CLI truncates its ordinary output file.
    drop(crate::native_file::create_private_file(&output).map_err(|_| LocalError::Unavailable)?);
    let mut command = Command::new(&backend.executable);
    command
        .arg("-m")
        .arg(&backend.model)
        .arg("-f")
        .arg(&input)
        .arg("-oj")
        .arg("-of")
        .arg(&prefix)
        .arg("-l")
        .arg(&backend.language)
        .arg("-t")
        .arg(backend.threads.to_string())
        .arg("-np")
        .current_dir(&directory.path)
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    for key in [
        "SystemRoot",
        "WINDIR",
        "PATH",
        "TEMP",
        "TMP",
        "USERPROFILE",
        "LOCALAPPDATA",
        "APPDATA",
        "LANG",
    ] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    if cancelled() {
        return Err(LocalError::Cancelled);
    }
    // The shared owner retains exact descendant handles through native signal
    // waits. A Job count of zero alone can precede release of a descendant's
    // current-directory handle and is not permission to remove these files.
    directory.cleanup_allowed = false;
    let mut process = match Process::spawn(&mut command) {
        Ok(process) => process,
        Err(_) => {
            // Spawn errors return only before launch or after verified teardown.
            // Unknown custody remains inside the owner and cannot reach here.
            directory.cleanup_allowed = true;
            return Err(LocalError::Unavailable);
        }
    };
    let started = Instant::now();
    let result = loop {
        if cancelled() {
            break Err(LocalError::Cancelled);
        }
        if started.elapsed() >= backend.timeout {
            break Err(LocalError::TimedOut);
        }
        if fs::metadata(&output).is_ok_and(|metadata| metadata.len() > MAX_OUTPUT as u64) {
            break Err(LocalError::TooLarge);
        }
        match process.exited() {
            Ok(Some(true)) => break Ok(()),
            Ok(Some(false)) => break Err(LocalError::ProcessFailed),
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(_) => break Err(LocalError::Unavailable),
        }
    };
    process.finish().map_err(|_| LocalError::CleanupPending)?;
    directory.cleanup_allowed = true;
    drop(process);
    let result = result.and_then(|()| {
        if cancelled() {
            return Err(LocalError::Cancelled);
        }
        let mut file = crate::private_fs::windows::open_file(&output, false)
            .map_err(|_| LocalError::InvalidOutput)?;
        if file
            .metadata()
            .map_err(|_| LocalError::InvalidOutput)?
            .len()
            > MAX_OUTPUT as u64
        {
            return Err(LocalError::TooLarge);
        }
        let mut bytes = Vec::new();
        (&mut file)
            .take(MAX_OUTPUT as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| LocalError::InvalidOutput)?;
        parse_output(&bytes)
    });
    directory.cleanup()?;
    result
}
