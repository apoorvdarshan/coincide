//! Where a terminal's shell starts, what it inherits and what the kernel says it
//! is doing (Swift TerminalLaunch and TerminalProcess). Nothing here runs output.
use std::{
    ffi::OsStr,
    path::{Path, PathBuf},
};

/// The folder a new terminal starts in and, when that is a fallback, the
/// preferred folder that could not be used.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartDirectory {
    pub path: PathBuf,
    pub missing: Option<PathBuf>,
}
impl StartDirectory {
    /// Swift TerminalLaunch.directory: the thread's worktree or project folder;
    /// when that is gone, the project folder, else home. Threads without a
    /// folder start at home.
    pub fn resolve(preferred: Option<PathBuf>, project: Option<PathBuf>, home: PathBuf) -> Self {
        let Some(preferred) = preferred else {
            return Self {
                path: home,
                missing: None,
            };
        };
        if preferred.is_dir() {
            return Self {
                path: preferred,
                missing: None,
            };
        }
        match project.filter(|project| project.is_dir()) {
            Some(project) => Self {
                path: project,
                missing: Some(preferred),
            },
            None => Self {
                path: home,
                missing: Some(preferred),
            },
        }
    }
    /// The dimmed line shown above the first prompt after a fallback.
    pub fn notice(&self) -> Option<String> {
        self.missing.as_ref().map(|missing| {
            format!(
                "\x1b[2m{} no longer exists. Starting in {}.\x1b[0m\r\n",
                missing.display(),
                self.path.display()
            )
        })
    }
}

/// The user's home folder, the last place a terminal can start.
pub fn home() -> PathBuf {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .filter(|path| path.is_dir())
        .unwrap_or_else(|| PathBuf::from(if cfg!(windows) { "C:\\" } else { "/" }))
}

/// Variables that describe whatever terminal or multiplexer Coincide itself
/// was launched from (Swift's inheritedTerminalKeys and prefixes).
const INHERITED_KEYS: &[&str] = &[
    "TERM_SESSION_ID",
    "TERMINFO",
    "LC_TERMINAL",
    "LC_TERMINAL_VERSION",
    "COLORFGBG",
    "TMUX",
    "TMUX_PANE",
    "STY",
    "WINDOW",
    "SHLVL",
    "OLDPWD",
    "_",
];
const INHERITED_PREFIXES: &[&str] = &[
    "ITERM_",
    "KITTY_",
    "GHOSTTY_",
    "WEZTERM_",
    "ALACRITTY_",
    "VSCODE_",
    "WARP_",
    "ZELLIJ",
];

/// What a new shell's environment loses and gains on top of Coincide's own.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Environment {
    pub remove: Vec<String>,
    pub set: Vec<(String, String)>,
}
/// Swift TerminalLaunch.environment: the terminal's own identity, the shell and
/// its folder, and a UTF-8 locale when the app started without one.
pub fn environment<'a>(
    inherited: impl IntoIterator<Item = &'a OsStr>,
    shell: &str,
    directory: &Path,
) -> Environment {
    let mut result = Environment::default();
    let mut has_locale = false;
    for name in inherited {
        let Some(name) = name.to_str() else { continue };
        has_locale |= matches!(name, "LANG" | "LC_ALL" | "LC_CTYPE");
        if INHERITED_KEYS.contains(&name)
            || INHERITED_PREFIXES
                .iter()
                .any(|prefix| name.starts_with(prefix))
        {
            result.remove.push(name.to_owned());
        }
    }
    for (name, value) in [
        ("TERM", "xterm-256color"),
        ("COLORTERM", "truecolor"),
        ("TERM_PROGRAM", "Coincide"),
        ("TERM_PROGRAM_VERSION", env!("CARGO_PKG_VERSION")),
        ("SHELL", shell),
    ] {
        result.set.push((name.into(), value.into()));
    }
    result
        .set
        .push(("PWD".into(), directory.display().to_string()));
    if !has_locale {
        // GUI apps often start without a locale; shells and editors then
        // mangle non-ASCII text.
        result.set.push(("LANG".into(), "en_US.UTF-8".into()));
    }
    result
}

/// The job in the foreground of the terminal, or None while the shell itself
/// is (Swift TerminalProcess.foregroundCommand).
#[cfg(unix)]
pub fn foreground_command(shell: Option<u32>, group: Option<i32>) -> Option<String> {
    let group = group.filter(|group| *group > 0)?;
    if shell.is_some_and(|shell| i64::from(shell) == i64::from(group)) {
        return None;
    }
    process_name(group)
}
#[cfg(target_os = "macos")]
fn process_name(pid: i32) -> Option<String> {
    let mut buffer = [0u8; 2 * libc::MAXCOMLEN + 1];
    let length = unsafe { libc::proc_name(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    let length = usize::try_from(length).ok().filter(|length| *length > 0)?;
    name(&buffer[..length.min(buffer.len())])
}
#[cfg(target_os = "linux")]
fn process_name(pid: i32) -> Option<String> {
    name(&std::fs::read(format!("/proc/{pid}/comm")).ok()?)
}
#[cfg(all(unix, not(any(target_os = "macos", target_os = "linux"))))]
fn process_name(_: i32) -> Option<String> {
    None
}
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn name(bytes: &[u8]) -> Option<String> {
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    let name = String::from_utf8_lossy(&bytes[..end]).trim().to_owned();
    (!name.is_empty() && !name.chars().any(char::is_control)).then_some(name)
}

/// The shell's current folder, followed as the user changes it (Swift
/// TerminalProcess.currentDirectory).
#[cfg(target_os = "macos")]
pub fn process_directory(pid: u32) -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    let pid = i32::try_from(pid).ok().filter(|pid| *pid > 0)?;
    let mut info = std::mem::MaybeUninit::<libc::proc_vnodepathinfo>::zeroed();
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as i32;
    let read = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            info.as_mut_ptr().cast(),
            size,
        )
    };
    if read != size {
        return None;
    }
    let info = unsafe { info.assume_init() };
    let bytes: Vec<u8> = info
        .pvi_cdir
        .vip_path
        .iter()
        .flatten()
        .map(|c| *c as u8)
        .take_while(|b| *b != 0)
        .collect();
    (!bytes.is_empty()).then(|| PathBuf::from(OsStr::from_bytes(&bytes)))
}
#[cfg(target_os = "linux")]
pub fn process_directory(pid: u32) -> Option<PathBuf> {
    std::fs::read_link(format!("/proc/{pid}/cwd"))
        .ok()
        .filter(|path| path.is_absolute())
}
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub fn process_directory(_: u32) -> Option<PathBuf> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_directory_falls_back_from_a_missing_worktree_to_the_project_then_home() {
        let root = tempfile::tempdir().unwrap();
        let project = root.path().join("project");
        let worktree = root.path().join("worktree");
        let home = root.path().join("home");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        let start =
            StartDirectory::resolve(Some(project.clone()), Some(project.clone()), home.clone());
        assert_eq!(start.path, project);
        assert_eq!(start.notice(), None);
        let start =
            StartDirectory::resolve(Some(worktree.clone()), Some(project.clone()), home.clone());
        assert_eq!(start.path, project);
        assert_eq!(start.missing.as_ref(), Some(&worktree));
        assert_eq!(
            start.notice().unwrap(),
            format!(
                "\x1b[2m{} no longer exists. Starting in {}.\x1b[0m\r\n",
                worktree.display(),
                project.display()
            )
        );
        std::fs::remove_dir(&project).unwrap();
        let start = StartDirectory::resolve(Some(worktree.clone()), Some(project), home.clone());
        assert_eq!(start.path, home);
        assert_eq!(start.missing, Some(worktree));
        // A projectless chat starts at home without a notice.
        let start = StartDirectory::resolve(None, None, home.clone());
        assert_eq!((start.path, start.missing), (home, None));
    }

    #[test]
    fn shell_environment_sets_terminal_identity_and_drops_other_terminals_variables() {
        let inherited = [
            "PATH",
            "TERM_SESSION_ID",
            "ITERM_PROFILE",
            "KITTY_WINDOW_ID",
            "TMUX",
            "ZELLIJ_SESSION_NAME",
            "SHLVL",
            "VSCODE_PID",
            "HOME",
        ];
        let plan = environment(
            inherited.iter().map(OsStr::new),
            "/bin/zsh",
            Path::new("/synthetic/project"),
        );
        assert_eq!(
            plan.remove,
            [
                "TERM_SESSION_ID",
                "ITERM_PROFILE",
                "KITTY_WINDOW_ID",
                "TMUX",
                "ZELLIJ_SESSION_NAME",
                "SHLVL",
                "VSCODE_PID"
            ]
        );
        let value = |name: &str| {
            plan.set
                .iter()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.as_str())
        };
        assert_eq!(value("TERM"), Some("xterm-256color"));
        assert_eq!(value("COLORTERM"), Some("truecolor"));
        assert_eq!(value("TERM_PROGRAM"), Some("Coincide"));
        assert_eq!(
            value("TERM_PROGRAM_VERSION"),
            Some(env!("CARGO_PKG_VERSION"))
        );
        assert_eq!(value("SHELL"), Some("/bin/zsh"));
        assert_eq!(
            value("PWD"),
            Some(
                Path::new("/synthetic/project")
                    .display()
                    .to_string()
                    .as_str()
            )
        );
        assert_eq!(value("LANG"), Some("en_US.UTF-8"));
        // An inherited locale is kept as it is.
        for locale in ["LANG", "LC_ALL", "LC_CTYPE"] {
            let plan = environment([OsStr::new(locale)], "/bin/sh", Path::new("/"));
            assert!(plan.set.iter().all(|(key, _)| key != "LANG"), "{locale}");
            assert!(plan.remove.is_empty());
        }
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn kernel_reports_a_process_folder_and_the_shell_itself_is_never_a_job() {
        let directory = std::env::current_dir().unwrap();
        let reported = process_directory(std::process::id()).unwrap();
        assert_eq!(
            reported.canonicalize().unwrap(),
            directory.canonicalize().unwrap()
        );
        let me = std::process::id();
        assert_eq!(foreground_command(Some(me), Some(me as i32)), None);
        assert_eq!(foreground_command(Some(me), None), None);
        assert!(foreground_command(None, Some(me as i32)).is_some());
    }
}
