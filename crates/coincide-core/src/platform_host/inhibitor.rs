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
pub trait LeaseProcess {
    fn check_running(&mut self) -> Result<()>;
    /// Idempotent. Errors retain ownership so release can be retried.
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

    pub(super) struct Lease {
        child: Child,
        input: Option<ChildStdin>,
        reaped: bool,
    }
    impl Lease {
        pub(super) fn start(spec: &CommandSpec) -> Result<Self> {
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
            let deadline = Instant::now() + Duration::from_secs(2);
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
    }
    impl LeaseProcess for Lease {
        fn check_running(&mut self) -> Result<()> {
            if self.reaped {
                bail!("idle sleep utility is no longer running");
            }
            if let Some(status) = self.child.try_wait()? {
                self.reaped = true;
                bail!("idle sleep utility exited: {status}");
            }
            Ok(())
        }
        fn stop(&mut self) -> Result<()> {
            // Closing stdin releases the helper even when the leader already died.
            self.input.take();
            if !self.reaped {
                let pid = i32::try_from(self.child.id()).context("invalid idle sleep child PID")?;
                // SAFETY: only our unreaped child's isolated process group is
                // signalled, never the app's or another task's process group.
                let result = unsafe { libc::kill(-pid, libc::SIGKILL) };
                if result != 0 {
                    let error = std::io::Error::last_os_error();
                    if error.raw_os_error() != Some(libc::ESRCH) {
                        return Err(error).context("stop idle sleep process group");
                    }
                }
                self.child.wait().context("reap idle sleep utility")?;
                self.reaped = true;
            }
            Ok(())
        }
    }
    impl Drop for Lease {
        fn drop(&mut self) {
            let _ = self.stop();
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
    fn unsupported_does_not_launch() {
        let state = Arc::new(Mutex::new(State::default()));
        let mut b = CommandInhibitor::with_runner(Platform::Unsupported, Runner(state.clone()));
        assert!(b.acquire().is_err());
        assert!(state.lock().unwrap().specs.is_empty());
    }
}
