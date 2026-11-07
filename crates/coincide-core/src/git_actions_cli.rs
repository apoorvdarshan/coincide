//! Runs git and gh for user-initiated actions (Swift GitCLI). Unlike
//! `workspace::git`, hooks, credential helpers and network remotes work as they do
//! in Terminal; only variables that would point git at another repository are
//! removed, and nothing ever waits on a prompt nobody can answer.
use anyhow::Result;
use std::{
    ffi::{OsStr, OsString},
    fmt,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

/// A failed git or gh step: a short sentence for the user, and git's own explanation
/// when it gave one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitError {
    pub message: String,
    pub detail: Option<String>,
}

impl GitError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            detail: None,
        }
    }
    pub fn with_detail(message: impl Into<String>, detail: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            detail: Some(detail.into()),
        }
    }
    /// Keeps git's diagnostic lines, without its hints.
    pub(crate) fn failed(action: &str, output: &Output) -> Self {
        if output.stderr.contains("index.lock': File exists") {
            return Self::with_detail(
                action,
                "Git's index is locked. Wait for other Git operations to finish, then try again.",
            );
        }
        let source = if output.stderr.trim().is_empty() {
            &output.stdout
        } else {
            &output.stderr
        };
        let lines: Vec<&str> = source
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with("hint:"))
            .collect();
        let detail = lines[lines.len().saturating_sub(12)..].join("\n");
        Self::with_detail(
            action,
            if detail.is_empty() {
                match output.code {
                    Some(code) => format!("Exit status {code}."),
                    None => "Git did not finish.".into(),
                }
            } else {
                detail
            },
        )
    }
}

impl fmt::Display for GitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for GitError {}

pub(crate) fn fail<T>(message: impl Into<String>) -> Result<T> {
    Err(GitError::new(message).into())
}

#[derive(Clone, Debug, Default)]
pub(crate) struct Output {
    pub success: bool,
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

/// Variables that would point git at another repository or index than `cwd`'s.
const REPOSITORY_OVERRIDES: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_PREFIX",
    "GIT_NAMESPACE",
];

const MAX_STDOUT: usize = 8 * 1024 * 1024;
const MAX_STDERR: usize = 64 * 1024;

pub(crate) const SHORT: Duration = Duration::from_secs(10);
pub(crate) const NORMAL: Duration = Duration::from_secs(30);

pub(crate) struct Invocation<'a> {
    pub cwd: &'a Path,
    pub args: &'a [&'a str],
    pub env: &'a [(&'a str, &'a OsStr)],
    pub timeout: Duration,
    pub max_stdout: usize,
}

impl<'a> Invocation<'a> {
    pub fn new(cwd: &'a Path, args: &'a [&'a str], timeout: Duration) -> Self {
        Self {
            cwd,
            args,
            env: &[],
            timeout,
            max_stdout: MAX_STDOUT,
        }
    }
}

fn read_pipe(pipe: impl Read + Send + 'static, limit: usize) -> mpsc::Receiver<(Vec<u8>, bool)> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = pipe.take(limit as u64 + 1).read_to_end(&mut bytes);
        let over = bytes.len() > limit;
        bytes.truncate(limit);
        let _ = tx.send((bytes, over));
    });
    rx
}

fn spawn(program: &OsStr, invocation: &Invocation) -> Output {
    let mut command = Command::new(program);
    for name in REPOSITORY_OVERRIDES {
        command.env_remove(name);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
    }
    command
        .args(invocation.args)
        .current_dir(invocation.cwd)
        // Fail instead of waiting for a user name on a stdin nobody reads.
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("GH_PAGER", "cat")
        .env("NO_COLOR", "1")
        .env_remove("GH_REPO")
        .env_remove("GH_FORCE_TTY")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (name, value) in invocation.env {
        command.env(name, value);
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return Output {
                stderr: format!("Unable to start {}: {error}", program.to_string_lossy()),
                ..Output::default()
            };
        }
    };
    let (Some(stdout), Some(stderr)) = (child.stdout.take(), child.stderr.take()) else {
        let _ = child.kill();
        let _ = child.wait();
        return Output {
            stderr: "Missing process pipes".into(),
            ..Output::default()
        };
    };
    let stdout = read_pipe(stdout, invocation.max_stdout);
    let stderr = read_pipe(stderr, MAX_STDERR);
    let started = Instant::now();
    let mut captured = None;
    let mut truncated = false;
    // Most git calls finish within milliseconds; back off to 20 ms for slow ones.
    let mut pause = Duration::from_millis(1);
    let status = loop {
        if captured.is_none()
            && let Ok((bytes, over)) = stdout.try_recv()
        {
            // Past the cap the output is cut short and git stopped, so a huge
            // patch is never read in full.
            if over {
                truncated = true;
                let _ = child.kill();
            }
            captured = Some(bytes);
        }
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if started.elapsed() < invocation.timeout => {
                thread::sleep(pause);
                pause = (pause * 2).min(Duration::from_millis(20));
            }
            Ok(None) | Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let stdout = captured
        .or_else(|| {
            stdout
                .recv_timeout(Duration::from_secs(2))
                .ok()
                .map(|(b, _)| b)
        })
        .unwrap_or_default();
    let stderr = stderr
        .recv_timeout(Duration::from_secs(2))
        .map(|(b, _)| b)
        .unwrap_or_default();
    // Past the cap the output is cut short on purpose: that run counts as succeeded.
    let mut output = Output {
        success: status.is_some_and(|s| s.success()) || truncated,
        code: status.and_then(|s| s.code()),
        stdout: String::from_utf8_lossy(&stdout).into_owned(),
        stderr: String::from_utf8_lossy(&stderr).into_owned(),
    };
    if status.is_none() && !truncated {
        output.success = false;
        output.stderr = format!(
            "{} did not finish within {} seconds.",
            program.to_string_lossy(),
            invocation.timeout.as_secs()
        );
    }
    output
}

pub(crate) fn run_git(invocation: &Invocation) -> Output {
    let mut args: Vec<&str> = Vec::with_capacity(invocation.args.len() + 4);
    #[cfg(windows)]
    args.extend(["-c", "core.longpaths=true"]);
    args.push("--no-pager");
    args.extend_from_slice(invocation.args);
    let directory = crate::workspace::external_git_directory(invocation.cwd)
        .map(PathBuf::from)
        .unwrap_or_else(|_| invocation.cwd.to_path_buf());
    spawn(
        OsStr::new("git"),
        &Invocation {
            cwd: &directory,
            args: &args,
            ..*invocation
        },
    )
}

pub(crate) fn git(cwd: &Path, args: &[&str], timeout: Duration) -> Output {
    run_git(&Invocation::new(cwd, args, timeout))
}

/// Trimmed standard output of a successful run.
pub(crate) fn value(cwd: &Path, args: &[&str]) -> Option<String> {
    let output = git(cwd, args, SHORT);
    let value = output.stdout.trim();
    (output.success && !value.is_empty()).then(|| value.to_owned())
}

/// Runs git and fails with `action` and git's explanation when it fails.
pub(crate) fn checked(
    action: &str,
    cwd: &Path,
    args: &[&str],
    timeout: Duration,
) -> Result<String> {
    checked_with(action, &Invocation::new(cwd, args, timeout))
}

pub(crate) fn checked_with(action: &str, invocation: &Invocation) -> Result<String> {
    let output = run_git(invocation);
    if !output.success {
        return Err(GitError::failed(action, &output).into());
    }
    Ok(output.stdout)
}

pub(crate) fn is_not_repository(stderr: &str) -> bool {
    let lower = stderr.to_lowercase();
    lower.contains("not a git repository")
        || lower.contains("must be run in a work tree")
        || lower.contains("unable to start git")
}

/// `COINCIDE_RUST_GH`, else the first `gh` on PATH, as the GitHub reads find it.
pub(crate) fn gh_executable() -> Option<PathBuf> {
    if let Some(explicit) = std::env::var_os("COINCIDE_RUST_GH") {
        let path = PathBuf::from(explicit);
        return (path.is_absolute() && path.is_file()).then_some(path);
    }
    let search: OsString = std::env::var_os("PATH")?;
    std::env::split_paths(&search)
        .take(128)
        .filter(|directory| directory.is_absolute())
        .map(|directory| directory.join(if cfg!(windows) { "gh.exe" } else { "gh" }))
        .find(|path| path.is_file())
}

/// None when gh is not installed.
pub(crate) fn gh(cwd: &Path, args: &[&str], timeout: Duration) -> Option<Output> {
    let executable = gh_executable()?;
    let directory = crate::workspace::external_git_directory(cwd)
        .map(PathBuf::from)
        .unwrap_or_else(|_| cwd.to_path_buf());
    Some(spawn(
        executable.as_os_str(),
        &Invocation::new(&directory, args, timeout),
    ))
}
