//! Native-only fixed Git operations. No JSON route, arbitrary shell or stderr
//! payload is exposed. OwnedChild retains its group/Job through pipe/TLS join.
use super::*;
use std::{
    path::{Component, Path},
    sync::atomic::AtomicBool,
};
#[derive(Clone)]
pub struct StoreSource {
    path: PathBuf,
    identity: crate::native_file::Identity,
    root: PathBuf,
    root_identity: crate::native_file::Identity,
}
impl StoreSource {
    pub fn capture(store: &crate::store::Store) -> Result<Self> {
        #[cfg(any(unix, windows))]
        {
            let path = store.resume_source_path()?;
            let root = store.data_directory()?;
            Ok(Self {
                identity: crate::native_file::path_identity(&path)?,
                path,
                root_identity: crate::native_file::path_identity(&root)?,
                root,
            })
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = store;
            bail!("Native Git source ownership is unavailable on this platform")
        }
    }
    pub fn validate(&self, store: &crate::store::Store) -> Result<()> {
        let current = Self::capture(store)?;
        ensure!(
            current.path == self.path
                && current.identity == self.identity
                && current.root == self.root
                && current.root_identity == self.root_identity,
            "Git review belongs to another or replaced Store"
        );
        Ok(())
    }
}
const OUTPUT: usize = 4 * 1024 * 1024;
#[derive(Clone)]
pub struct Runner {
    isolated: bool,
    executable: PathBuf,
    identity: crate::native_file::Identity,
    size: u64,
    modified: std::time::SystemTime,
}
pub struct Captured {
    pub code: i32,
    pub stdout: Vec<u8>,
}
/// All variable arguments are data with strict syntax, never Git flags or shell.
pub enum Operation {
    Root,
    GitDirectory,
    CommonDirectory,
    Head,
    Branch,
    Status,
    Configuration,
    IndexEntries,
    Parents(String),
    Remotes,
    RemoteUrl(String),
    PushUrl(String),
    Upstream,
    CopyStatus(String),
    StageCopy(String),
    CommitCopy(String),
    Blob { oid: String, path: String },
    FetchHeads { remote: String, token: String },
    RemoteHeads(String),
    AheadBehind { head: String, upstream: String },
    FastForward(String),
    Rebase(String),
    AbortRebase,
    Revisions { head: String, excluded: Vec<String> },
    ChangedPaths(String),
    Push { remote: String, branch: String },
    DeletePrivateRef { reference: String, oid: String },
}
fn oid(value: &str) -> Result<()> {
    ensure!(
        matches!(value.len(), 40 | 64) && value.bytes().all(|c| c.is_ascii_hexdigit()),
        "Invalid captured Git object identity"
    );
    Ok(())
}
fn remote(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.len() <= 128
            && !value.starts_with('-')
            && value
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c)),
        "Unsupported Git remote name"
    );
    Ok(())
}
fn branch(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.len() <= 4096
            && value != "@"
            && !value.starts_with('-')
            && !value.ends_with('.')
            && !value.contains("..")
            && !value.contains("@{")
            && value
                .split('/')
                .all(|part| !part.is_empty() && !part.starts_with('.') && !part.ends_with(".lock"))
            && !value
                .chars()
                .any(|c| c.is_control() || c.is_whitespace() || "~^:?*[\\".contains(c)),
        "Unsupported Git branch name"
    );
    Ok(())
}

fn relative(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.len() <= 4096
            && !value.contains('\0')
            && Path::new(value)
                .components()
                .all(|c| matches!(c, Component::Normal(_))),
        "Git copy must be one literal repository-relative file"
    );
    Ok(())
}
fn token(value: &str) -> Result<()> {
    ensure!(
        uuid::Uuid::parse_str(value).is_ok_and(|u| u.to_string() == value),
        "Invalid native Git operation identity"
    );
    Ok(())
}
impl Operation {
    fn args(&self) -> Result<Vec<String>> {
        let values: Vec<String> = match self {
            Self::Root => vec!["rev-parse", "--show-toplevel"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            Self::GitDirectory => vec!["rev-parse", "--absolute-git-dir"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            Self::CommonDirectory => {
                vec!["rev-parse", "--path-format=absolute", "--git-common-dir"]
                    .into_iter()
                    .map(str::to_owned)
                    .collect()
            }
            Self::Head => vec!["rev-parse", "--verify", "--quiet", "HEAD"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            Self::Branch => vec!["symbolic-ref", "--quiet", "--short", "HEAD"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            Self::Status => vec!["status", "--porcelain=v1", "-z", "--untracked-files=all"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            Self::Configuration => vec![
                "config".into(),
                "--null".into(),
                "--list".into(),
                "--show-origin".into(),
            ],
            Self::IndexEntries => vec!["ls-files".into(), "--stage".into(), "-z".into()],
            Self::Parents(id) => {
                oid(id)?;
                vec![
                    "rev-list".into(),
                    "--parents".into(),
                    "-n".into(),
                    "1".into(),
                    id.clone(),
                ]
            }
            Self::Remotes => vec!["remote".into()],
            Self::RemoteUrl(name) => {
                remote(name)?;
                vec![
                    "remote".into(),
                    "get-url".into(),
                    "--all".into(),
                    name.clone(),
                ]
            }
            Self::PushUrl(name) => {
                remote(name)?;
                vec![
                    "remote".into(),
                    "get-url".into(),
                    "--push".into(),
                    "--all".into(),
                    name.clone(),
                ]
            }
            Self::Upstream => vec![
                "rev-parse",
                "--abbrev-ref",
                "--symbolic-full-name",
                "@{upstream}",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            Self::CopyStatus(path) => {
                relative(path)?;
                vec![
                    "status".into(),
                    "--porcelain=v1".into(),
                    "-z".into(),
                    "--".into(),
                    path.clone(),
                ]
            }
            Self::StageCopy(path) => {
                relative(path)?;
                vec!["add".into(), "--".into(), path.clone()]
            }
            Self::CommitCopy(path) => {
                relative(path)?;
                vec![
                    "commit".into(),
                    "--only".into(),
                    "--no-verify".into(),
                    "-m".into(),
                    "Update instruction copy".into(),
                    "--".into(),
                    path.clone(),
                ]
            }
            Self::Blob { oid: commit, path } => {
                oid(commit)?;
                relative(path)?;
                vec![
                    "show".into(),
                    "--no-ext-diff".into(),
                    "--no-textconv".into(),
                    format!("{commit}:{path}"),
                ]
            }
            Self::FetchHeads {
                remote: name,
                token: id,
            } => {
                remote(name)?;
                token(id)?;
                vec![
                    "fetch".into(),
                    "--quiet".into(),
                    "--no-tags".into(),
                    "--no-recurse-submodules".into(),
                    "--no-write-fetch-head".into(),
                    name.clone(),
                    format!("refs/heads/*:refs/coincide/instructions/{id}/*"),
                ]
            }
            Self::RemoteHeads(id) => {
                token(id)?;
                vec![
                    "for-each-ref".into(),
                    "--format=%(refname)%00%(objectname)".into(),
                    format!("refs/coincide/instructions/{id}/"),
                ]
            }
            Self::AheadBehind { head, upstream } => {
                oid(head)?;
                oid(upstream)?;
                vec![
                    "rev-list".into(),
                    "--left-right".into(),
                    "--count".into(),
                    format!("{head}...{upstream}"),
                ]
            }
            Self::FastForward(commit) => {
                oid(commit)?;
                vec![
                    "merge".into(),
                    "--ff-only".into(),
                    "--no-edit".into(),
                    commit.clone(),
                ]
            }
            Self::Rebase(commit) => {
                oid(commit)?;
                vec![
                    "rebase".into(),
                    "--merge".into(),
                    "--no-autostash".into(),
                    commit.clone(),
                ]
            }
            Self::AbortRebase => vec!["rebase".into(), "--abort".into()],
            Self::Revisions { head, excluded } => {
                oid(head)?;
                ensure!(excluded.len() <= 1024, "Too many remote Git heads");
                for id in excluded {
                    oid(id)?;
                }
                let mut args = vec!["rev-list".into(), head.clone()];
                if !excluded.is_empty() {
                    args.push("--not".into());
                    args.extend(excluded.clone());
                }
                args
            }
            Self::ChangedPaths(commit) => {
                oid(commit)?;
                vec![
                    "diff-tree".into(),
                    "--root".into(),
                    "--no-commit-id".into(),
                    "--no-renames".into(),
                    "-m".into(),
                    "-r".into(),
                    "--name-only".into(),
                    "-z".into(),
                    commit.clone(),
                    "--".into(),
                ]
            }
            Self::Push {
                remote: name,
                branch: name_branch,
            } => {
                remote(name)?;
                branch(name_branch)?;
                vec![
                    "push".into(),
                    "--porcelain".into(),
                    name.clone(),
                    format!("HEAD:refs/heads/{name_branch}"),
                ]
            }
            Self::DeletePrivateRef {
                reference,
                oid: old,
            } => {
                oid(old)?;
                let Some(rest) = reference.strip_prefix("refs/coincide/instructions/") else {
                    bail!("Invalid native Git cleanup reference")
                };
                let Some((id, suffix)) = rest.split_once('/') else {
                    bail!("Invalid native Git cleanup reference")
                };
                token(id)?;
                branch(suffix)?;
                vec![
                    "update-ref".into(),
                    "-d".into(),
                    reference.clone(),
                    old.clone(),
                ]
            }
        };
        Ok(values)
    }
}
impl Runner {
    pub fn system() -> Result<Self> {
        let name = if cfg!(windows) { "git.exe" } else { "git" };
        let path = std::env::var_os("PATH").context("Git is unavailable")?;
        for directory in std::env::split_paths(&path).filter(|p| p.is_absolute()) {
            let candidate = directory.join(name);
            if candidate.is_file() {
                return Self::bind(candidate);
            }
        }
        bail!("Install Git before using instruction repository sync")
    }
    /// Synthetic/local callers may explicitly exclude system/global Git
    /// configuration. This does not select another executable or accept argv.
    pub fn isolated() -> Result<Self> {
        let mut runner = Self::system()?;
        runner.isolated = true;
        Ok(runner)
    }
    fn bind(path: PathBuf) -> Result<Self> {
        let executable = path.canonicalize()?;
        let metadata = std::fs::metadata(&executable)?;
        ensure!(metadata.is_file(), "Git executable is unavailable");
        Ok(Self {
            isolated: false,
            identity: crate::native_file::path_identity(&executable)?,
            size: metadata.len(),
            modified: metadata.modified()?,
            executable,
        })
    }
    fn validate(&self) -> Result<()> {
        let metadata = std::fs::metadata(&self.executable)?;
        ensure!(
            crate::native_file::path_identity(&self.executable)? == self.identity
                && metadata.len() == self.size
                && metadata.modified()? == self.modified,
            "Git executable changed; review the repository again"
        );
        Ok(())
    }
    pub fn capture(
        &self,
        directory: &Path,
        operation: &Operation,
        cancelled: &AtomicBool,
    ) -> Result<Captured> {
        self.validate()?;
        ensure!(
            directory.is_absolute() && directory.is_dir(),
            "Native Git repository directory is unavailable"
        );
        let args = operation.args()?;
        let mut command = Command::new(&self.executable);
        let hooks = crate::workspace::external_git_path(&std::env::current_exe()?.canonicalize()?)?;
        let mut hook_option = std::ffi::OsString::from("core.hooksPath=");
        hook_option.push(hooks);
        command
            .args([
                "--no-pager",
                "--no-replace-objects",
                "--literal-pathspecs",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.untrackedCache=false",
                "-c",
                "protocol.allow=never",
                "-c",
                "protocol.file.allow=always",
                "-c",
                "protocol.https.allow=always",
                "-c",
                "protocol.ssh.allow=always",
                "-c",
                "rebase.autoStash=false",
                "-c",
                "rebase.updateRefs=false",
                "-c",
                "rerere.enabled=false",
            ])
            .arg("-c")
            .arg(hook_option)
            .args(args)
            .current_dir(directory)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        for (name, _) in std::env::vars_os() {
            if name.to_string_lossy().starts_with("GIT_") {
                command.env_remove(name);
            }
        }
        super::transport::isolate_environment(&mut command);
        if self.isolated {
            command.env("GIT_CONFIG_NOSYSTEM", "1").env(
                "GIT_CONFIG_GLOBAL",
                if cfg!(windows) { "NUL" } else { "/dev/null" },
            );
        }
        command
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("GIT_PAGER", "cat")
            .env("GIT_NO_LAZY_FETCH", "1")
            .env("GIT_MERGE_AUTOEDIT", "no");
        capture(command, Duration::from_secs(120), cancelled)
    }
}
struct Owner {
    child: Option<OwnedChild>,
    reader: Option<thread::JoinHandle<Result<Vec<u8>>>>,
}
impl Owner {
    fn finish(&mut self) -> Result<()> {
        drop(self.child.take());
        if let Some(reader) = self.reader.take() {
            match reader.join() {
                Ok(result) => {
                    result?;
                }
                Err(payload) => {
                    if !thread::panicking() {
                        std::panic::resume_unwind(payload);
                    }
                    bail!("Git output reader panicked during cleanup");
                }
            }
        }
        Ok(())
    }
}
impl Drop for Owner {
    fn drop(&mut self) {
        let result = self.finish();
        if result.is_err() && !thread::panicking() {
            panic!("Owned Git cleanup failed");
        }
    }
}
fn exited(child: &mut OwnedChild) -> Result<Option<i32>> {
    #[cfg(unix)]
    {
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                child.0.id(),
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result != 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                return Ok(None);
            }
            bail!("Git exit observation failed");
        }
        if unsafe { info.si_pid() } == 0 {
            return Ok(None);
        }
        Ok(Some(if info.si_code == libc::CLD_EXITED {
            unsafe { info.si_status() }
        } else {
            128 + unsafe { info.si_status() }
        }))
    }
    #[cfg(not(unix))]
    {
        Ok(child.0.try_wait()?.map(|status| status.code().unwrap_or(1)))
    }
}
fn capture(command: Command, timeout: Duration, cancelled: &AtomicBool) -> Result<Captured> {
    capture_with_reader_hook(command, timeout, cancelled, || {})
}
fn capture_with_reader_hook(
    mut command: Command,
    timeout: Duration,
    cancelled: &AtomicBool,
    reader_hook: impl FnOnce() + Send + 'static,
) -> Result<Captured> {
    ensure!(
        !cancelled.load(Ordering::Acquire),
        "Git sync cancelled before starting"
    );
    let mut owner = Owner {
        child: None,
        reader: None,
    };
    owner.child = Some(OwnedChild::spawn(&mut command).context("Unable to start Git")?);
    let stdout = owner
        .child
        .as_mut()
        .unwrap()
        .0
        .stdout
        .take()
        .context("Missing Git output pipe")?;
    let (sender, receiver) = mpsc::sync_channel(1);
    owner.reader = Some(
        thread::Builder::new()
            .name("coincide-native-git-output".into())
            .spawn(move || {
                reader_hook();
                let mut bytes = Vec::new();
                let result = stdout
                    .take((OUTPUT + 1) as u64)
                    .read_to_end(&mut bytes)
                    .map_err(|_| anyhow::anyhow!("Git output could not be read"));
                let overflow = bytes.len() > OUTPUT;
                let _ = sender.send((result.is_ok(), overflow, bytes));
                result?;
                Ok(Vec::new())
            })
            .context("Unable to own Git output reader")?,
    );
    let deadline = Instant::now() + timeout;
    let mut output = None;
    let mut code = None;
    let result = (|| -> Result<Captured> {
        loop {
            ensure!(!cancelled.load(Ordering::Acquire), "Git sync cancelled");
            ensure!(Instant::now() < deadline, "Git operation timed out");
            if output.is_none() {
                match receiver.try_recv() {
                    Ok((ok, overflow, bytes)) => {
                        ensure!(ok, "Git output could not be read");
                        ensure!(!overflow, "Git output exceeds its safe bound");
                        output = Some(bytes);
                    }
                    Err(mpsc::TryRecvError::Empty) => {}
                    Err(mpsc::TryRecvError::Disconnected) => bail!("Git output worker failed"),
                }
            }
            if code.is_none() {
                code = exited(owner.child.as_mut().unwrap())?;
            }
            if let (Some(code), Some(_)) = (code, output.as_ref()) {
                return Ok(Captured {
                    code,
                    stdout: output.take().unwrap(),
                });
            }
            thread::sleep(Duration::from_millis(5));
        }
    })();
    // Stop the entire still-owned group/Job before joining the output worker.
    // A reply or deadline never substitutes for the actual reader/TLS join.
    owner.finish()?;
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    struct TlsGate {
        entered: mpsc::Sender<()>,
        release: mpsc::Receiver<()>,
    }
    impl Drop for TlsGate {
        fn drop(&mut self) {
            let _ = self.entered.send(());
            let _ = self.release.recv();
        }
    }
    thread_local! {static GATE:std::cell::RefCell<Option<TlsGate>>=const{std::cell::RefCell::new(None)};}
    #[test]
    fn semantic_output_does_not_finish_capture_before_actual_reader_tls_join() {
        let runner = Runner::isolated().unwrap();
        let (entered, seen) = mpsc::channel();
        let (release, held) = mpsc::channel();
        let (done, returned) = mpsc::channel();
        let mut command = Command::new(runner.executable);
        command
            .arg("--version")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let worker = thread::spawn(move || {
            let result = capture_with_reader_hook(
                command,
                Duration::from_secs(10),
                &AtomicBool::new(false),
                move || {
                    GATE.with(|cell| {
                        *cell.borrow_mut() = Some(TlsGate {
                            entered,
                            release: held,
                        })
                    })
                },
            );
            done.send(result).unwrap();
        });
        seen.recv_timeout(Duration::from_secs(10)).unwrap();
        assert!(matches!(
            returned.try_recv(),
            Err(mpsc::TryRecvError::Empty)
        ));
        release.send(()).unwrap();
        let result = returned
            .recv_timeout(Duration::from_secs(10))
            .unwrap()
            .unwrap();
        assert_eq!(result.code, 0);
        assert!(result.stdout.starts_with(b"git version"));
        worker.join().unwrap();
    }
    #[test]
    #[ignore = "Only executed as an owned synthetic child by timeout regression"]
    fn owned_process_fixture_child() {
        if std::env::var_os("COINCIDE_NATIVE_GIT_HOLD").is_none() {
            return;
        }
        if let Some(marker) = std::env::var_os("COINCIDE_NATIVE_GIT_MARKER") {
            std::fs::write(marker, b"synthetic child entered").unwrap();
        }
        loop {
            thread::sleep(Duration::from_millis(50));
        }
    }
    #[test]
    fn timeout_and_prestart_cancellation_reap_owned_child_before_return() {
        let root =
            std::env::temp_dir().join(format!("coincide-native-git-stop-{}", uuid::Uuid::new_v4()));
        crate::native_file::private_directory(&root).unwrap();
        let marker = root.join("entered");
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                "agent::native_instruction_git::tests::owned_process_fixture_child",
                "--ignored",
                "--nocapture",
            ])
            .env("COINCIDE_NATIVE_GIT_HOLD", "1")
            .env("COINCIDE_NATIVE_GIT_MARKER", &marker)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let error = capture(command, Duration::from_secs(2), &AtomicBool::new(false))
            .err()
            .unwrap();
        assert!(error.to_string().contains("timed out"), "{error}");
        assert!(
            marker.is_file(),
            "The exact synthetic child fixture must actually execute"
        );
        std::fs::remove_dir_all(root).unwrap();
        let command = Command::new("must-not-be-spawned");
        let error = capture(command, Duration::from_secs(1), &AtomicBool::new(true))
            .err()
            .unwrap();
        assert!(error.to_string().contains("before starting"));
    }
    #[test]
    fn fixed_operations_reject_option_path_reference_and_cleanup_injection() {
        for operation in [
            Operation::CommitCopy("../outside".into()),
            Operation::CommitCopy("/absolute".into()),
            Operation::FetchHeads {
                remote: "--upload-pack=evil".into(),
                token: uuid::Uuid::new_v4().to_string(),
            },
            Operation::Push {
                remote: "origin".into(),
                branch: "main:other".into(),
            },
            Operation::DeletePrivateRef {
                reference: "refs/heads/main".into(),
                oid: "a".repeat(40),
            },
        ] {
            assert!(operation.args().is_err());
        }
        assert_eq!(
            Operation::CommitCopy("folder/space name.md".into())
                .args()
                .unwrap()
                .last()
                .unwrap(),
            "folder/space name.md"
        );
        let push = Operation::Push {
            remote: "origin".into(),
            branch: "main".into(),
        }
        .args()
        .unwrap();
        assert!(!push.iter().any(|arg| arg.starts_with("--force")));
        assert_eq!(push.last().unwrap(), "HEAD:refs/heads/main");
    }
}
