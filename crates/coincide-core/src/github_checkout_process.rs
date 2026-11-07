//! One native checkout child at a time. No detached worker or arbitrary command
//! API: parent builds only closed Plan invocations. Output is private and bounded.
//! Teardown is sampled until the owned group/Job actually has no running child;
//! a deadline is a stop request, never an exit receipt.
use super::*;
use std::{
    io,
    process::{Command, Stdio},
};
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StopReason {
    Cancelled,
    TimedOut,
    OutputLimit,
    DiskLimit,
    Native,
    ProcessFailed,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProcessStatus {
    Running,
    Stopping,
    Returned,
}
pub struct Returned {
    bytes: Vec<u8>,
    code: i32,
}
impl Returned {
    pub fn output(&self) -> &[u8] {
        &self.bytes
    }
    pub fn exit_code(&self) -> i32 {
        self.code
    }
}
struct Limits {
    output: usize,
    file: u64,
    total: u64,
    entries: usize,
    time: Duration,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            output: MAX_TREE,
            file: 128 * 1024 * 1024,
            total: 256 * 1024 * 1024,
            entries: 4096,
            time: TIMEOUT,
        }
    }
}
struct Owner {
    #[cfg(unix)]
    child: std::process::Child,
    #[cfg(windows)]
    child: crate::github_api::windows::Process,
    stdout: std::process::ChildStdout,
    bytes: Vec<u8>,
    eof: bool,
    code: Option<i32>,
    joined: bool,
}
impl Owner {
    fn start(
        mut command: Command,
        directory: &filesystem::Directory,
        file_limit: u64,
    ) -> Result<Self> {
        ensure!(
            cfg!(any(target_os = "macos", target_os = "linux", windows)),
            "Native checkout return receipts unavailable"
        );
        #[cfg(unix)]
        {
            use std::os::{fd::AsRawFd, unix::process::CommandExt};
            command.process_group(0);
            let cwd = directory.child_cwd()?;
            // SAFETY: the pre-exec closure uses only async-signal-safe libc
            // syscalls and fixed values, never allocation or inherited locks.
            unsafe {
                command.pre_exec(move || {
                    if libc::fchdir(cwd.as_raw_fd()) != 0 {
                        return Err(io::Error::last_os_error());
                    }
                    libc::umask(0o077);
                    let limit = libc::rlimit {
                        rlim_cur: file_limit as libc::rlim_t,
                        rlim_max: file_limit as libc::rlim_t,
                    };
                    if libc::setrlimit(libc::RLIMIT_FSIZE, &limit) != 0 {
                        return Err(io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
            let mut child = command
                .spawn()
                .context("Native checkout child could not start")?;
            let stdout = child
                .stdout
                .take()
                .context("Native checkout output unavailable")?;
            let owner = Self {
                child,
                stdout,
                bytes: Vec::new(),
                eof: false,
                code: None,
                joined: false,
            };
            let fd = owner.stdout.as_raw_fd();
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            ensure!(
                flags >= 0
                    && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } >= 0,
                "Native checkout output cannot be bounded"
            );
            Ok(owner)
        }
        #[cfg(windows)]
        {
            let _ = (file_limit, directory);
            let mut child = crate::github_api::windows::Process::spawn(&mut command)?;
            let stdout = child
                .child
                .stdout
                .take()
                .context("Native checkout output unavailable")?;
            Ok(Self {
                child,
                stdout,
                bytes: Vec::new(),
                eof: false,
                code: None,
                joined: false,
            })
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (command, file_limit);
            anyhow::bail!("Native checkout process custody unavailable")
        }
    }
    fn read(&mut self, limit: usize) -> Result<()> {
        // Bound work per poll too: a noisy child must not starve disk/cancel checks.
        for _ in 0..32 {
            #[cfg(windows)]
            {
                use std::os::windows::io::AsRawHandle;
                let mut available = 0u32;
                let status = unsafe {
                    windows_sys::Win32::System::Pipes::PeekNamedPipe(
                        self.stdout.as_raw_handle(),
                        std::ptr::null_mut(),
                        0,
                        std::ptr::null_mut(),
                        &mut available,
                        std::ptr::null_mut(),
                    )
                };
                if status == 0 {
                    let error = io::Error::last_os_error();
                    if error.raw_os_error()
                        == Some(windows_sys::Win32::Foundation::ERROR_BROKEN_PIPE as i32)
                    {
                        self.eof = true;
                        return Ok(());
                    }
                    return Err(error.into());
                }
                if available == 0 {
                    return Ok(());
                }
            }
            let mut chunk = [0u8; 16384];
            match self.stdout.read(&mut chunk) {
                Ok(0) => {
                    self.eof = true;
                    return Ok(());
                }
                Ok(n) => {
                    ensure!(
                        self.bytes.len() + n <= limit,
                        "Native checkout output limit"
                    );
                    self.bytes.extend_from_slice(&chunk[..n]);
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    ) =>
                {
                    return Ok(());
                }
                Err(_) => anyhow::bail!("Native checkout output failed"),
            }
        }
        Ok(())
    }
    fn exited(&mut self) -> Result<Option<i32>> {
        if self.code.is_some() {
            return Ok(self.code);
        }
        #[cfg(unix)]
        {
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            let status = unsafe {
                libc::waitid(
                    libc::P_PID,
                    self.child.id(),
                    &mut info,
                    libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
                )
            };
            if status != 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    return Ok(None);
                }
                return Err(error.into());
            }
            if unsafe { info.si_pid() } == 0 {
                return Ok(None);
            }
            self.code = Some(if info.si_code == libc::CLD_EXITED {
                unsafe { info.si_status() }
            } else {
                128 + unsafe { info.si_status() }
            });
        }
        #[cfg(windows)]
        {
            self.code = self
                .child
                .exited()?
                .map(|success| if success { 0 } else { 1 });
        }
        Ok(self.code)
    }
    fn stop(&mut self) -> Result<()> {
        #[cfg(unix)]
        {
            let status = unsafe { libc::kill(-(self.child.id() as i32), libc::SIGKILL) };
            if status != 0 && io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH) {
                return Err(io::Error::last_os_error().into());
            }
            Ok(())
        }
        #[cfg(windows)]
        {
            self.child.request_stop()
        }
        #[cfg(not(any(unix, windows)))]
        {
            anyhow::bail!("Native process stop unavailable")
        }
    }
    fn drain(&mut self) -> Result<bool> {
        if self.joined {
            return Ok(true);
        }
        self.stop()?;
        if self.exited()?.is_none() {
            return Ok(false);
        }
        #[cfg(unix)]
        {
            // Retain the unreaped leader so PGID/PID cannot be reused while
            // checking only its group. Zombies have actually exited; their
            // adoption/reap is not confused with a running descendant.
            if !group_exited(self.child.id())? {
                return Ok(false);
            }
            self.child
                .wait()
                .context("Native checkout leader has not returned")?;
        }
        #[cfg(windows)]
        {
            if !self.child.stopped()? {
                return Ok(false);
            }
            self.child
                .child
                .wait()
                .context("Native checkout leader has not returned")?;
        }
        self.joined = true;
        Ok(true)
    }
}
impl Drop for Owner {
    fn drop(&mut self) {
        // Exceptional unwinding retains the owned leader/Job until teardown is
        // real. Normal callers keep polling Stopping rather than dropping it.
        while !self.joined {
            if matches!(self.drain(), Ok(true)) {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
#[cfg(target_os = "macos")]
fn group_exited(leader: u32) -> Result<bool> {
    const LIMIT: usize = 4096;
    let mut pids = [0i32; LIMIT];
    // Native constants/ABI are from the current SDK sys/proc_info.h and the
    // already locked libc definitions. Query ONLY this owned process group.
    // Owner::drain has already observed this exact owned Child through
    // waitid(WNOWAIT), and has not reaped it. That is the PID/PGID anchor.
    // Darwin getpgid(zombie) returns ESRCH, so it cannot revalidate a returned
    // leader. Native group enumeration still includes its retained PID.
    // Zero entries is valid only with a successful native query and the owned
    // unreaped Child; it never follows a semantic stdout success marker.
    unsafe {
        *libc::__error() = 0;
    }
    let bytes = unsafe {
        libc::proc_listpids(
            2,
            leader,
            pids.as_mut_ptr().cast(),
            std::mem::size_of_val(&pids) as i32,
        )
    };
    ensure!(
        bytes >= 0
            && (bytes != 0 || io::Error::last_os_error().raw_os_error() == Some(0))
            && (bytes as usize) < std::mem::size_of_val(&pids)
            && (bytes as usize).is_multiple_of(std::mem::size_of::<i32>()),
        "Owned checkout group cannot be classified"
    );
    for pid in pids
        .into_iter()
        .take(bytes as usize / std::mem::size_of::<i32>())
        .filter(|pid| *pid > 0)
    {
        if pid == leader as i32 {
            continue;
        }
        let mut info: libc::proc_bsdshortinfo = unsafe { std::mem::zeroed() };
        let read = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDT_SHORTBSDINFO,
                0,
                (&mut info as *mut libc::proc_bsdshortinfo).cast(),
                std::mem::size_of_val(&info) as i32,
            )
        };
        if read == 0 && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
            continue;
        }
        ensure!(
            read as usize == std::mem::size_of_val(&info)
                && info.pbsi_pid == pid as u32
                && info.pbsi_pgid == leader,
            "Owned checkout descendant cannot be classified"
        );
        if info.pbsi_status != libc::SZOMB {
            return Ok(false);
        }
    }
    Ok(true)
}
#[cfg(target_os = "linux")]
fn group_exited(leader: u32) -> Result<bool> {
    let mut count = 0usize;
    let mut saw_leader = false;
    for entry in fs::read_dir("/proc")? {
        count += 1;
        ensure!(
            count <= 65536,
            "Owned checkout group enumeration exceeds bound"
        );
        let entry = entry?;
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|name| name.parse::<u32>().ok())
        else {
            continue;
        };
        // No unrelated process metadata is opened; native getpgid filters first.
        if unsafe { libc::getpgid(pid as i32) } != leader as i32 {
            continue;
        }
        if pid == leader {
            saw_leader = true;
            continue;
        }
        let path = entry.path().join("stat");
        let file = match File::open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };
        let mut stat = String::new();
        file.take(8193).read_to_string(&mut stat)?;
        ensure!(
            stat.len() <= 8192,
            "Owned checkout process identity too large"
        );
        let (head, tail) = stat
            .rsplit_once(')')
            .context("Owned checkout process identity unavailable")?;
        ensure!(
            head.split_once('(')
                .and_then(|(pid, _)| pid.trim().parse::<u32>().ok())
                == Some(pid),
            "Owned checkout descendant changed"
        );
        let fields = tail.split_whitespace().collect::<Vec<_>>();
        ensure!(
            fields.get(2).and_then(|value| value.parse::<u32>().ok()) == Some(leader),
            "Owned checkout descendant group changed"
        );
        if !fields
            .first()
            .is_some_and(|state| matches!(*state, "Z" | "X" | "x"))
        {
            return Ok(false);
        }
    }
    ensure!(saw_leader, "Owned checkout group leader disappeared");
    Ok(true)
}
#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn group_exited(_: u32) -> Result<bool> {
    anyhow::bail!("Native checkout group receipts unavailable")
}
/// Owner sampled on the one checkout worker. Stopping remains owned, never a
/// successful reply. All files are retained until the actual Returned receipt.
pub(super) struct Run {
    owner: Owner,
    limits: Limits,
    started: Instant,
    reason: Option<StopReason>,
}
impl Run {
    fn start(command: Command, directory: &filesystem::Directory) -> Result<Self> {
        Self::start_with_limits(command, directory, Limits::default())
    }
    fn start_with_limits(
        command: Command,
        directory: &filesystem::Directory,
        limits: Limits,
    ) -> Result<Self> {
        Ok(Self {
            owner: Owner::start(command, directory, limits.file)?,
            limits,
            started: Instant::now(),
            reason: None,
        })
    }
    fn poll(&mut self, directory: &filesystem::Directory, cancelled: &AtomicBool) -> ProcessStatus {
        if self.owner.joined {
            if self.owner.read(self.limits.output).is_err() {
                self.reason = Some(StopReason::OutputLimit);
                self.owner.eof = true;
            }
            return if self.owner.eof {
                ProcessStatus::Returned
            } else {
                ProcessStatus::Stopping
            };
        }
        if self.reason.is_none() {
            self.reason = if cancelled.load(Ordering::Acquire) {
                Some(StopReason::Cancelled)
            } else if self.started.elapsed() >= self.limits.time {
                Some(StopReason::TimedOut)
            } else if self.owner.read(self.limits.output).is_err() {
                Some(StopReason::OutputLimit)
            } else {
                match directory.inventory(self.limits.entries) {
                    Ok((bytes, largest))
                        if bytes <= self.limits.total && largest <= self.limits.file =>
                    {
                        None
                    }
                    _ => Some(StopReason::DiskLimit),
                }
            };
        }
        if self.owner.exited().is_err() {
            self.reason = Some(StopReason::Native);
        }
        if self.reason.is_some() || self.owner.code.is_some() {
            match self.owner.drain() {
                Ok(true) => {
                    if self.owner.read(self.limits.output).is_err() {
                        self.reason = Some(StopReason::OutputLimit);
                    }
                    if self.owner.code.is_some_and(|code| code != 0) && self.reason.is_none() {
                        self.reason = Some(StopReason::ProcessFailed);
                    }
                    return if self.owner.eof {
                        ProcessStatus::Returned
                    } else {
                        ProcessStatus::Stopping
                    };
                }
                _ => return ProcessStatus::Stopping,
            }
        }
        ProcessStatus::Running
    }
    fn take(&mut self) -> Result<Returned> {
        ensure!(
            self.owner.joined && self.owner.eof,
            "Native checkout child/descendants/output have not returned"
        );
        ensure!(
            self.reason.is_none(),
            "Native checkout process stopped: {:?}",
            self.reason
        );
        Ok(Returned {
            bytes: std::mem::take(&mut self.owner.bytes),
            code: self.owner.code.context("Native child exit unavailable")?,
        })
    }
}
/// Fixed local operations only. FetchPull deliberately stays unavailable until
/// incoming-pack cap/closure admission is reviewed; no credentials are queried.
pub struct LocalRunner {
    plan: Plan,
    tools: Tools,
    directory: filesystem::Directory,
    active: Option<Run>,
    initialized: bool,
    failed: bool,
    operation: Option<Operation>,
    _configuration: [File; 2],
}
impl LocalRunner {
    pub(super) fn open(plan: Plan, tools: Tools) -> Result<Self> {
        plan.check()?;
        tools.validate()?;
        let path = plan.execution_directory();
        let directory = plan.storage.create_directory(
            path.file_name()
                .unwrap()
                .to_str()
                .context("Invalid private Git directory")?,
        )?;
        directory.create_file("empty-config")?.sync_all()?;
        directory.create_file("disabled-hooks")?.sync_all()?;
        let configuration = [
            directory.hold_read_only("empty-config")?,
            directory.hold_read_only("disabled-hooks")?,
        ];
        Ok(Self {
            plan,
            tools,
            directory,
            active: None,
            initialized: false,
            failed: false,
            operation: None,
            _configuration: configuration,
        })
    }
    pub fn start(&mut self, operation: Operation) -> Result<()> {
        ensure!(
            !self.failed,
            "Prepare a fresh checkout after a failed or cancelled process"
        );
        ensure!(
            !self.initialized || operation != Operation::Initialize,
            "The private repository is already initialized"
        );
        ensure!(
            self.active.is_none(),
            "A checkout process still owns its return receipt"
        );
        ensure!(
            operation != Operation::FetchPull,
            "Live PR fetch is unavailable until incoming-pack/closure custody is verified"
        );
        ensure!(
            self.initialized || operation == Operation::Initialize,
            "Initialize the owned private bare repository first"
        );
        self.plan.check()?;
        self.tools.validate()?;
        self.directory.check()?;
        let invocation = self.plan.invocation(&self.tools, operation.clone())?;
        ensure!(
            !invocation.network(),
            "Local checkout runner cannot access the network"
        );
        let mut command = Command::new(self.tools.git_executable());
        command
            .env_clear()
            .envs(
                invocation
                    .environment()
                    .iter()
                    .map(|(key, value)| (key, value)),
            )
            .args(invocation.arguments())
            .current_dir(&self.directory.path)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        // Required loader/OS process environment only; no token/proxy/Git config
        // inheritance. Native executable/helper paths are captured separately.
        for key in [
            "SystemRoot",
            "WINDIR",
            "TMP",
            "TEMP",
            "TMPDIR",
            "LANG",
            "LC_ALL",
        ] {
            if let Some(value) = std::env::var_os(key) {
                command.env(key, value);
            }
        }
        self.active = Some(Run::start(command, &self.directory)?);
        self.operation = Some(operation);
        Ok(())
    }
    pub fn poll(&mut self, cancelled: &AtomicBool) -> ProcessStatus {
        let Some(run) = self.active.as_mut() else {
            return ProcessStatus::Returned;
        };
        if self.plan.check().is_err() || self.tools.validate().is_err() {
            run.reason = Some(StopReason::Native);
        }
        run.poll(&self.directory, cancelled)
    }
    pub fn stop_reason(&self) -> Option<StopReason> {
        self.active.as_ref().and_then(|run| run.reason)
    }
    pub fn take_returned(&mut self) -> Result<Returned> {
        let run = self.active.as_mut().context("No owned checkout process")?;
        let result = run.take();
        if run.owner.joined && run.owner.eof {
            self.active = None;
            let operation = self.operation.take();
            if result.is_ok() && operation == Some(Operation::Initialize) {
                self.initialized = true;
            }
            self.failed = result.is_err();
        }
        result
    }
    pub fn directory(&self) -> &Path {
        &self.directory.path
    }
    pub fn plan(&self) -> &Plan {
        &self.plan
    }
}
#[cfg(test)]
#[path = "github_checkout_process_tests.rs"]
mod tests;
