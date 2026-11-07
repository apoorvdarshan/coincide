//! Executed only by the separately invoked terminal helper. The helper owns and
//! reaps the complete provider/installer process group; the GUI never runs this.
use super::*;
#[cfg(unix)]
static STOP: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
#[cfg(unix)]
extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, std::sync::atomic::Ordering::Release);
}
#[cfg(unix)]
struct Signals(Vec<(libc::c_int, libc::sigaction)>);
#[cfg(unix)]
impl Signals {
    fn install() -> Result<Self> {
        let mut owner = Self(Vec::new());
        STOP.store(false, std::sync::atomic::Ordering::Release);
        for signal in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP, libc::SIGTTOU] {
            let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
            action.sa_sigaction = if signal == libc::SIGTTOU {
                libc::SIG_IGN
            } else {
                stop as *const () as usize
            };
            unsafe {
                libc::sigemptyset(&mut action.sa_mask);
            }
            let mut previous = unsafe { std::mem::zeroed() };
            ensure!(
                unsafe { libc::sigaction(signal, &action, &mut previous) } == 0,
                "Setup signal custody unavailable"
            );
            owner.0.push((signal, previous));
        }
        Ok(owner)
    }
}
#[cfg(unix)]
impl Drop for Signals {
    fn drop(&mut self) {
        for (signal, previous) in self.0.iter().rev() {
            unsafe {
                libc::sigaction(*signal, previous, std::ptr::null_mut());
            }
        }
    }
}
#[cfg(unix)]
struct Foreground(Option<libc::pid_t>);
#[cfg(unix)]
impl Drop for Foreground {
    fn drop(&mut self) {
        if let Some(group) = self.0 {
            unsafe {
                libc::tcsetpgrp(libc::STDIN_FILENO, group);
            }
        }
    }
}
pub(crate) fn run(command: &mut Command) -> Result<i32> {
    transport::isolate_environment(command);
    for key in [
        "CLAUDECODE",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
    ] {
        command.env_remove(key);
    }
    #[cfg(unix)]
    let _signals = Signals::install()?;
    let child = OwnedChild::spawn(command).context("Setup child could not start")?;
    #[cfg(unix)]
    let _foreground = {
        let previous = if unsafe { libc::isatty(libc::STDIN_FILENO) } == 1 {
            Some(unsafe { libc::tcgetpgrp(libc::STDIN_FILENO) })
        } else {
            None
        };
        let foreground = Foreground(previous.filter(|group| *group > 0));
        if foreground.0.is_some() {
            ensure!(
                unsafe { libc::tcsetpgrp(libc::STDIN_FILENO, child.0.id() as libc::pid_t) } == 0,
                "Setup terminal foreground unavailable"
            );
            unsafe {
                libc::kill(-(child.0.id() as libc::pid_t), libc::SIGCONT);
            }
        }
        foreground
    };
    loop {
        #[cfg(unix)]
        ensure!(
            !STOP.load(std::sync::atomic::Ordering::Acquire),
            "Setup cancelled in terminal"
        );
        // Do not reap the leader before OwnedChild drops: its process-group ID
        // must remain reserved until descendants have been killed and reaped.
        if let Some(success) = metadata_capture::exited(&child)? {
            return Ok(if success { 0 } else { 1 });
        }
        thread::sleep(Duration::from_millis(50));
    }
}
