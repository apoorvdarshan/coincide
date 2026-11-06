//! Explicit, scoped command-backed idle sleep leases. Construction has no effects.
//! Only `acquire` spawns a utility. No privileged helpers or persistent settings.
use super::power::SleepInhibitor;
use anyhow::{Context, Result, bail};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    MacOs,
    Linux,
    Unsupported,
}
impl Platform {
    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            Self::MacOs
        } else if cfg!(target_os = "linux") {
            Self::Linux
        } else {
            Self::Unsupported
        }
    }
}

// The lease helper lives until its private stdin closes. A parent crash closes
// the pipe too. Fixed script only: no user text, paths or shell interpolation.
const HELPER: &str = "printf 'coincide-idle-lease-ready\\n'; exec /bin/cat >/dev/null";
#[cfg(any(target_os = "macos", target_os = "linux"))]
const READY: &[u8] = b"coincide-idle-lease-ready\n";
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandSpec {
    pub program: &'static str,
    pub arguments: Vec<&'static str>,
}
impl CommandSpec {
    pub fn for_platform(platform: Platform) -> Result<Self> {
        match platform {
            Platform::MacOs => Ok(Self {
                program: "/usr/bin/caffeinate",
                arguments: vec!["-i", "/bin/sh", "-c", HELPER],
            }),
            Platform::Linux => Ok(Self {
                program: "/usr/bin/systemd-inhibit",
                arguments: vec![
                    "--what=idle",
                    "--mode=block",
                    "--who=Coincide Rust",
                    "--why=Agent work is active",
                    "/bin/sh",
                    "-c",
                    HELPER,
                ],
            }),
            Platform::Unsupported => bail!("idle sleep inhibition is unsupported on this platform"),
        }
    }
}

/// Injectable launch boundary. A successful launch waits for the fixed utility
/// helper handshake. This verifies command startup, not an independent OS power
/// assertion query. Missing utility/logind, permission errors and early exits fail.
pub trait CommandRunner {
    fn launch(&mut self, spec: &CommandSpec) -> Result<Box<dyn LeaseProcess>>;
}
pub trait LeaseProcess: Send {
    fn check_running(&mut self) -> Result<()>;
    /// Idempotent. Errors retain the lease; lost cleanup authority stays failed.
    fn stop(&mut self) -> Result<()>;
}

pub struct CommandInhibitor<R: CommandRunner> {
    platform: Platform,
    runner: R,
    lease: Option<Box<dyn LeaseProcess>>,
}
impl<R: CommandRunner> CommandInhibitor<R> {
    pub fn with_runner(platform: Platform, runner: R) -> Self {
        Self {
            platform,
            runner,
            lease: None,
        }
    }
}
impl<R: CommandRunner> SleepInhibitor for CommandInhibitor<R> {
    fn acquire(&mut self) -> Result<()> {
        if self.lease.is_some() {
            return self.check();
        }
        let spec = CommandSpec::for_platform(self.platform)?;
        self.lease = Some(self.runner.launch(&spec)?);
        Ok(())
    }
    fn release(&mut self) -> Result<()> {
        if let Some(lease) = &mut self.lease {
            lease.stop()?;
        }
        self.lease = None;
        Ok(())
    }
    fn check(&mut self) -> Result<()> {
        let Some(lease) = &mut self.lease else {
            bail!("idle sleep lease is not acquired");
        };
        if let Err(error) = lease.check_running() {
            // Stop any remaining descendants before reporting lost inhibition.
            self.release()
                .context("cleanup after idle sleep utility exit")?;
            return Err(error);
        }
        Ok(())
    }
}
impl<R: CommandRunner> Drop for CommandInhibitor<R> {
    fn drop(&mut self) {
        let _ = self.release();
    }
}
#[derive(Default)]
pub struct SystemRunner;
pub type NativeSleepInhibitor = CommandInhibitor<SystemRunner>;
impl NativeSleepInhibitor {
    pub fn native() -> Self {
        Self::with_runner(Platform::current(), SystemRunner)
    }
}
impl CommandRunner for SystemRunner {
    fn launch(&mut self, spec: &CommandSpec) -> Result<Box<dyn LeaseProcess>> {
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        {
            Ok(Box::new(process::Lease::start(spec)?))
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            let _ = spec;
            bail!("idle sleep command backend is unsupported on this platform")
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
mod process {
    use super::*;
    use std::io::{ErrorKind, Read};
    use std::os::{fd::AsRawFd, unix::process::CommandExt};
    use std::process::{Child, ChildStdin, Command, Stdio};
    use std::time::{Duration, Instant};
    #[cfg(test)]
    type ReapReceipt = std::sync::Arc<std::sync::Mutex<Option<(u32, std::process::ExitStatus)>>>;

    pub(super) struct Lease {
        child: Child,
        input: Option<ChildStdin>,
        reaped: bool,
        cleanup_failure: Option<String>,
        #[cfg(test)]
        reap_receipt: Option<ReapReceipt>,
    }
    impl Lease {
        pub(super) fn start(spec: &CommandSpec) -> Result<Self> {
            Self::start_with_timeout(spec, Duration::from_secs(2))
        }
        fn start_with_timeout(spec: &CommandSpec, timeout: Duration) -> Result<Self> {
            let mut command = Command::new(spec.program);
            command
                .args(&spec.arguments)
                .env_clear()
                .env("PATH", "/usr/bin:/bin")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .process_group(0);
            let mut child = command
                .spawn()
                .with_context(|| format!("cannot start idle sleep utility {}", spec.program))?;
            let input = child.stdin.take();
            let mut lease = Self {
                child,
                input,
                reaped: false,
                cleanup_failure: None,
                #[cfg(test)]
                reap_receipt: None,
            };
            // RAII cleanup also covers all handshake errors and timeouts.
            let mut output = lease
                .child
                .stdout
                .take()
                .context("idle sleep utility has no handshake pipe")?;
            let fd = output.as_raw_fd();
            // SAFETY: fd is a live, exclusively owned pipe. No pointer arguments.
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
            {
                return Err(std::io::Error::last_os_error())
                    .context("configure idle sleep handshake");
            }
            let deadline = Instant::now() + timeout;
            let mut received = Vec::new();
            while Instant::now() < deadline {
                let mut bytes = [0; 64];
                match output.read(&mut bytes) {
                    Ok(0) => bail!(
                        "idle sleep utility exited before readiness (logind may be unavailable or deny access)"
                    ),
                    Ok(n) => {
                        received.extend_from_slice(&bytes[..n]);
                        if received == READY {
                            lease.check_running()?;
                            return Ok(lease);
                        }
                        if !READY.starts_with(&received) {
                            bail!("invalid idle sleep utility handshake");
                        }
                    }
                    Err(e)
                        if e.kind() == ErrorKind::WouldBlock
                            || e.kind() == ErrorKind::Interrupted => {}
                    Err(e) => return Err(e).context("read idle sleep handshake"),
                }
                lease.check_running()?;
                std::thread::sleep(Duration::from_millis(10));
            }
            bail!("idle sleep utility readiness timed out")
        }
        fn leader_exit_status(&mut self) -> Result<Option<i32>> {
            // Health checks must not reap the leader: its PID pins the process
            // group until stop() has signalled any surviving descendants.
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            let result = unsafe {
                libc::waitid(
                    libc::P_PID,
                    self.child.id() as libc::id_t,
                    &mut info,
                    libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
                )
            };
            if result != 0 {
                let error = std::io::Error::last_os_error();
                if error.raw_os_error() == Some(libc::ECHILD) {
                    // Ownership was lost (for example an external SIGCHLD
                    // reaper); never signal a potentially recycled group ID.
                    self.reaped = true;
                    self.cleanup_failure = Some(format!(
                        "idle sleep child ownership lost before group cleanup: {error}"
                    ));
                }
                return Err(error).context("inspect idle sleep utility");
            }
            Ok((unsafe { info.si_pid() } != 0).then(|| unsafe { info.si_status() }))
        }
        fn reap_owned(&mut self) -> Result<()> {
            let waited = self.child.wait();
            #[cfg(test)]
            if let (Ok(status), Some(receipt)) = (&waited, &self.reap_receipt) {
                *receipt.lock().unwrap() = Some((self.child.id(), *status));
            }
            if let Err(error) = waited {
                if error.raw_os_error() == Some(libc::ECHILD) {
                    self.reaped = true;
                    self.cleanup_failure = Some(format!(
                        "idle sleep child ownership lost while reaping: {error}"
                    ));
                }
                return Err(error).context("reap idle sleep utility");
            }
            self.reaped = true;
            Ok(())
        }
        fn stop_with_signal(
            &mut self,
            signal: impl FnOnce(i32) -> std::io::Result<()>,
        ) -> Result<()> {
            if let Some(failure) = &self.cleanup_failure {
                bail!("{failure}");
            }
            if self.reaped {
                return Ok(());
            }
            // Prove the child is still ours without releasing its PID/group pin.
            let _ = self.leader_exit_status()?;
            let pid = i32::try_from(self.child.id()).context("invalid idle sleep child PID")?;
            // Keep stdin held until after the signal. EOF first lets the helper
            // become a zombie-only group, for which Darwin killpg returns EPERM.
            if let Err(error) = signal(-pid) {
                // A failed group signal is never cleanup acknowledgement. Reap
                // an already-exited owned leader, but retain the group failure:
                // after reap we must neither retry that numeric group nor report
                // release. A live child keeps its input/ownership; do not wait.
                if self.leader_exit_status()?.is_some() {
                    let group_absent = error.raw_os_error() == Some(libc::ESRCH);
                    if !group_absent {
                        self.cleanup_failure =
                            Some(format!("stop idle sleep process group: {error}"));
                    }
                    self.input.take();
                    self.reap_owned()?;
                    if group_absent {
                        return Ok(());
                    }
                }
                return Err(error).context("stop idle sleep process group");
            }
            self.input.take();
            self.reap_owned()
        }
    }
    impl LeaseProcess for Lease {
        fn check_running(&mut self) -> Result<()> {
            if self.reaped {
                bail!("idle sleep utility is no longer running");
            }
            match self.leader_exit_status() {
                Ok(None) => Ok(()),
                Ok(Some(status)) => bail!("idle sleep utility exited (status {status})"),
                Err(error)
                    if error
                        .downcast_ref::<std::io::Error>()
                        .is_some_and(|error| error.kind() == ErrorKind::Interrupted) =>
                {
                    Ok(())
                }
                Err(error) => Err(error),
            }
        }
        fn stop(&mut self) -> Result<()> {
            self.stop_with_signal(|group| {
                // SAFETY: only the unreaped, owned child's isolated group is
                // signalled. No Child wait/reap occurs before this call.
                if unsafe { libc::kill(group, libc::SIGKILL) } == 0 {
                    Ok(())
                } else {
                    Err(std::io::Error::last_os_error())
                }
            })
        }
    }
    impl Drop for Lease {
        fn drop(&mut self) {
            let _ = self.stop();
        }
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        fn fixture(script: &'static str) -> CommandSpec {
            CommandSpec {
                program: "/bin/sh",
                arguments: vec!["-c", script],
            }
        }
        // These commands have no power effects: no inhibitor utility is used.
        #[test]
        fn harmless_helper_is_reaped_on_explicit_release() {
            use std::os::unix::process::ExitStatusExt;
            let mut lease = Lease::start(&fixture(HELPER)).unwrap();
            let pid = lease.child.id();
            let receipt: ReapReceipt = Default::default();
            lease.reap_receipt = Some(receipt.clone());
            lease.check_running().unwrap();
            lease.stop().unwrap();
            assert!(lease.reaped);
            assert_eq!(
                receipt.lock().unwrap().unwrap(),
                (pid, std::process::ExitStatus::from_raw(libc::SIGKILL)),
                "group signal must precede the EOF that would normally exit cat"
            );
            lease.stop().unwrap();
        }
        fn await_owned_exit(lease: &mut Lease) {
            let deadline = Instant::now() + Duration::from_secs(2);
            while lease.leader_exit_status().unwrap().is_none() {
                assert!(Instant::now() < deadline, "fixture leader did not exit");
                std::thread::yield_now();
            }
            assert!(!lease.reaped, "exit inspection must retain the child pin");
        }
        #[test]
        fn exited_leader_signal_failure_reaps_owned_child_but_stays_failed() {
            use std::os::unix::process::ExitStatusExt;
            let mut lease = Lease::start(&fixture(HELPER)).unwrap();
            let pid = lease.child.id();
            let receipt: ReapReceipt = Default::default();
            lease.reap_receipt = Some(receipt.clone());
            lease.input.take();
            await_owned_exit(&mut lease);
            // Inject only the group signal error; leader exit and Child.wait
            // are real. This deterministically covers Darwin's zombie EPERM.
            let error = lease
                .stop_with_signal(|group| {
                    assert_eq!(group, -(pid as i32));
                    Err(std::io::Error::from_raw_os_error(libc::EPERM))
                })
                .unwrap_err();
            assert_eq!(
                error
                    .downcast_ref::<std::io::Error>()
                    .unwrap()
                    .raw_os_error(),
                Some(libc::EPERM)
            );
            assert!(lease.reaped);
            assert_eq!(
                receipt.lock().unwrap().unwrap(),
                (pid, std::process::ExitStatus::from_raw(0))
            );
            assert!(
                lease
                    .stop_with_signal(|_| panic!("never signal a reaped group"))
                    .is_err()
            );
            assert!(lease.stop().is_err(), "failed group cleanup stays sticky");
        }
        #[test]
        fn absent_group_only_acknowledges_cleanup_after_owned_leader_exit() {
            use std::os::unix::process::ExitStatusExt;
            let mut lease = Lease::start(&fixture(HELPER)).unwrap();
            let pid = lease.child.id();
            let receipt: ReapReceipt = Default::default();
            lease.reap_receipt = Some(receipt.clone());
            lease.input.take();
            await_owned_exit(&mut lease);
            lease
                .stop_with_signal(|group| {
                    assert_eq!(group, -(pid as i32));
                    Err(std::io::Error::from_raw_os_error(libc::ESRCH))
                })
                .unwrap();
            assert_eq!(
                receipt.lock().unwrap().unwrap(),
                (pid, std::process::ExitStatus::from_raw(0))
            );
            assert!(lease.reaped && lease.cleanup_failure.is_none());
            lease
                .stop_with_signal(|_| panic!("never signal a reaped group"))
                .unwrap();
        }
        #[test]
        fn live_leader_signal_failure_neither_closes_input_nor_waits() {
            use std::os::unix::process::ExitStatusExt;
            let mut lease = Lease::start(&fixture(HELPER)).unwrap();
            let pid = lease.child.id();
            let receipt: ReapReceipt = Default::default();
            lease.reap_receipt = Some(receipt.clone());
            for failure in [libc::EPERM, libc::ESRCH] {
                assert!(
                    lease
                        .stop_with_signal(|group| {
                            assert_eq!(group, -(pid as i32));
                            Err(std::io::Error::from_raw_os_error(failure))
                        })
                        .is_err()
                );
                assert!(lease.input.is_some());
                assert!(!lease.reaped);
                assert!(receipt.lock().unwrap().is_none());
                lease.check_running().unwrap();
            }
            // The still-owned live group may be retried, unlike a reaped one.
            lease.stop().unwrap();
            assert_eq!(
                receipt.lock().unwrap().unwrap(),
                (pid, std::process::ExitStatus::from_raw(libc::SIGKILL))
            );
        }
        #[test]
        fn lost_child_ownership_never_signals_or_reports_cleanup_success() {
            let mut lease = Lease::start(&fixture(HELPER)).unwrap();
            lease.input.take();
            await_owned_exit(&mut lease);
            // Consume the actual Child wait outside Lease's receipt boundary to
            // model ownership loss, without a post-reap numeric PID operation.
            assert!(lease.child.wait().unwrap().success());
            assert!(
                lease
                    .stop_with_signal(|_| panic!("lost ownership must veto the signal"))
                    .is_err()
            );
            assert!(lease.reaped);
            assert!(lease.cleanup_failure.is_some());
            assert!(lease.stop().is_err());
        }
        #[test]
        fn harmless_helper_is_reaped_on_drop() {
            use std::os::unix::process::ExitStatusExt;
            // Ignore stdin EOF so the retained wait has a deterministic signal
            // status, rather than racing cat's normal exit against group kill.
            let mut lease = Lease::start(&fixture(
                "printf 'coincide-idle-lease-ready\\n'; exec /bin/sleep 60",
            ))
            .unwrap();
            let pid = lease.child.id();
            let receipt: ReapReceipt = Default::default();
            lease.reap_receipt = Some(receipt.clone());
            drop(lease);
            // Inspect the actual owned Child.wait result. A numeric PID can be
            // reused immediately after reap; waitpid here could steal a
            // different parallel fixture's child instead of checking our own.
            let (waited_pid, status) = receipt
                .lock()
                .unwrap()
                .expect("Drop must actually wait its owned child");
            assert_eq!(waited_pid, pid);
            assert_eq!(status, std::process::ExitStatus::from_raw(libc::SIGKILL));
        }
        #[test]
        fn readiness_rejects_missing_command_exit_and_invalid_output() {
            let missing = CommandSpec {
                program: "/nonexistent/coincide-idle-fixture",
                arguments: vec![],
            };
            assert!(Lease::start(&missing).is_err());
            assert!(Lease::start(&fixture("exit 7")).is_err());
            assert!(
                Lease::start(&fixture("printf 'invalid\n'; exec /bin/cat >/dev/null")).is_err()
            );
        }
        #[test]
        fn silent_helper_times_out_without_inhibiting_sleep() {
            assert!(
                Lease::start_with_timeout(
                    &fixture("exec /bin/cat >/dev/null"),
                    Duration::from_millis(30)
                )
                .is_err()
            );
        }
        #[test]
        fn exited_leader_stays_owned_until_descendant_group_teardown() {
            let temporary = tempfile::tempdir().unwrap();
            let descendant_file = temporary.path().join("descendant.pid");
            let mut child = Command::new("/bin/sh")
                .args([
                    "-c",
                    "/bin/sleep 60 </dev/null >/dev/null 2>&1 & printf '%s' \"$!\" > \"$1\"; /bin/cat >/dev/null",
                    "fixture",
                ])
                .arg(&descendant_file)
                .env_clear()
                .env("PATH", "/usr/bin:/bin")
                .process_group(0)
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            let input = child.stdin.take();
            let mut lease = Lease {
                child,
                input,
                reaped: false,
                cleanup_failure: None,
                reap_receipt: None,
            };
            let deadline = Instant::now() + Duration::from_secs(2);
            let descendant: i32 = loop {
                if let Ok(pid) = std::fs::read_to_string(&descendant_file)
                    && let Ok(pid) = pid.parse()
                {
                    break pid;
                }
                assert!(
                    Instant::now() < deadline,
                    "fixture descendant did not start"
                );
                std::thread::sleep(Duration::from_millis(10));
            };
            // The leader exits after EOF; its background sleep remains alive.
            lease.input.take();
            while lease.check_running().is_ok() {
                assert!(Instant::now() < deadline, "fixture leader did not exit");
                std::thread::sleep(Duration::from_millis(10));
            }
            assert!(
                !lease.reaped,
                "health polling must retain the exited leader"
            );
            assert!(lease.check_running().is_err());
            assert!(!lease.reaped, "repeated inspection must still use WNOWAIT");
            lease.stop().unwrap();
            assert!(lease.reaped);
            let deadline = Instant::now() + Duration::from_secs(2);
            loop {
                if unsafe { libc::kill(descendant, 0) } != 0 {
                    break;
                }
                // A killed orphan may remain a zombie until init reaps it. It
                // must be terminated, but immediate PID disappearance is not required.
                let state = Command::new("/bin/ps")
                    .args(["-o", "stat=", "-p", &descendant.to_string()])
                    .output()
                    .unwrap();
                let state = String::from_utf8_lossy(&state.stdout);
                if state.trim().is_empty() || state.trim_start().starts_with('Z') {
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "descendant survived lease teardown"
                );
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform_host::power::{AwakeController, AwakePolicy};
    use std::sync::{Arc, Mutex};
    #[derive(Default)]
    struct State {
        specs: Vec<CommandSpec>,
        stops: usize,
        fail_start: bool,
        fail_stop: bool,
        died: bool,
    }
    struct Runner(Arc<Mutex<State>>);
    struct Process(Arc<Mutex<State>>);
    impl CommandRunner for Runner {
        fn launch(&mut self, spec: &CommandSpec) -> Result<Box<dyn LeaseProcess>> {
            let mut state = self.0.lock().unwrap();
            state.specs.push(spec.clone());
            if state.fail_start {
                bail!("synthetic missing utility");
            }
            Ok(Box::new(Process(self.0.clone())))
        }
    }
    impl LeaseProcess for Process {
        fn check_running(&mut self) -> Result<()> {
            if self.0.lock().unwrap().died {
                bail!("synthetic exit");
            }
            Ok(())
        }
        fn stop(&mut self) -> Result<()> {
            let mut s = self.0.lock().unwrap();
            if s.fail_stop {
                bail!("synthetic cleanup failure");
            }
            s.stops += 1;
            Ok(())
        }
    }
    #[test]
    fn fixed_commands_only_request_idle_inhibition() {
        let mac = CommandSpec::for_platform(Platform::MacOs).unwrap();
        assert_eq!(mac.program, "/usr/bin/caffeinate");
        assert_eq!(mac.arguments, vec!["-i", "/bin/sh", "-c", HELPER]);
        let linux = CommandSpec::for_platform(Platform::Linux).unwrap();
        assert_eq!(linux.program, "/usr/bin/systemd-inhibit");
        assert_eq!(
            linux.arguments,
            vec![
                "--what=idle",
                "--mode=block",
                "--who=Coincide Rust",
                "--why=Agent work is active",
                "/bin/sh",
                "-c",
                HELPER
            ]
        );
        assert!(CommandSpec::for_platform(Platform::Unsupported).is_err());
    }
    #[test]
    fn scoped_lease_is_idempotent_and_dropped() {
        let state = Arc::new(Mutex::new(State::default()));
        {
            let mut b = CommandInhibitor::with_runner(Platform::Linux, Runner(state.clone()));
            b.acquire().unwrap();
            b.acquire().unwrap();
        }
        let state = state.lock().unwrap();
        assert_eq!(state.specs.len(), 1);
        assert_eq!(state.stops, 1);
    }
    #[test]
    fn launch_and_cleanup_failures_are_explicit_and_retryable() {
        let state = Arc::new(Mutex::new(State {
            fail_start: true,
            ..Default::default()
        }));
        let mut b = CommandInhibitor::with_runner(Platform::MacOs, Runner(state.clone()));
        assert!(b.acquire().is_err());
        state.lock().unwrap().fail_start = false;
        b.acquire().unwrap();
        state.lock().unwrap().fail_stop = true;
        assert!(b.release().is_err());
        state.lock().unwrap().fail_stop = false;
        b.release().unwrap();
        b.release().unwrap();
        assert_eq!(state.lock().unwrap().stops, 1);
    }
    #[test]
    fn controller_detects_child_exit_and_reacquires_on_next_tick() {
        let state = Arc::new(Mutex::new(State::default()));
        let mut c = AwakeController::new(CommandInhibitor::with_runner(
            Platform::Linux,
            Runner(state.clone()),
        ));
        let policy = AwakePolicy {
            enabled: true,
            active_turns: 1,
            ..Default::default()
        };
        c.reconcile(policy).unwrap();
        state.lock().unwrap().died = true;
        assert!(c.reconcile(policy).is_err());
        assert!(!c.is_held());
        state.lock().unwrap().died = false;
        c.reconcile(policy).unwrap();
        assert!(c.is_held());
        c.shutdown().unwrap();
        assert_eq!(state.lock().unwrap().specs.len(), 2);
    }
    #[test]
    fn native_controller_can_move_to_host_worker() {
        fn assert_send<T: Send>() {}
        assert_send::<AwakeController<NativeSleepInhibitor>>();
    }
    #[test]
    fn unsupported_does_not_launch() {
        let state = Arc::new(Mutex::new(State::default()));
        let mut b = CommandInhibitor::with_runner(Platform::Unsupported, Runner(state.clone()));
        assert!(b.acquire().is_err());
        assert!(state.lock().unwrap().specs.is_empty());
    }
}
