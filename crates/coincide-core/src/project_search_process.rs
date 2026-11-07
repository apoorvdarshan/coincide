//! Bounded nonblocking capture using the existing GitHub transport's native
//! process owner. No shell, provider configuration, network or input pipe.
use super::*;
use anyhow::bail;

pub(super) fn capture_search(
    command: &mut Command,
    control: &SearchControl,
    limit: usize,
) -> Result<Vec<u8>> {
    capture_checked(command, control, limit, false)
}
pub(super) fn capture_checked(
    command: &mut Command,
    control: &SearchControl,
    limit: usize,
    require_success: bool,
) -> Result<Vec<u8>> {
    control.check()?;
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(unix)]
    let mut process = crate::github_api::ProcessGroup::spawn(command)?;
    #[cfg(windows)]
    let mut process = crate::github_api::windows::Process::spawn(command)?;
    let mut stdout = process.take_stdout().context("Search output unavailable")?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        let fd = stdout.as_raw_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        ensure!(
            flags >= 0 && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } >= 0,
            "Unable to bound search output"
        );
    }
    let result = (|| {
        let mut bytes = Vec::new();
        loop {
            control.check()?;
            let eof = read_available(&mut stdout, &mut bytes, limit)?;
            if eof && let Some(success) = process.exited()? {
                ensure!(!require_success || success, "Project file index failed");
                return Ok(bytes);
            }
            if bytes.len() >= limit {
                ensure!(
                    !require_success,
                    "Project file index exceeds its output bound"
                );
                return Ok(bytes);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    })();
    // Close the read endpoint before native cleanup, including inherited pipes.
    drop(stdout);
    #[cfg(windows)]
    if let Err(error) = process.finish() {
        control
            .cleanup_uncertain
            .store(true, AtomicOrdering::Release);
        return Err(error.context("Project search cleanup unconfirmed"));
    }
    // The Unix owner keeps its unreaped group leader until kill and wait finish.
    drop(process);
    result
}
#[cfg(unix)]
fn read_available<T: Read>(pipe: &mut T, bytes: &mut Vec<u8>, limit: usize) -> Result<bool> {
    let mut buffer = [0u8; 8192];
    let count = buffer.len().min(limit.saturating_sub(bytes.len()));
    match pipe.read(&mut buffer[..count]) {
        Ok(0) => Ok(true),
        Ok(n) => {
            bytes.extend_from_slice(&buffer[..n]);
            Ok(false)
        }
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => Ok(false),
        Err(error) if error.kind() == std::io::ErrorKind::Interrupted => Ok(false),
        Err(_) => bail!("Project search output failed"),
    }
}
#[cfg(windows)]
fn read_available<T: Read + std::os::windows::io::AsRawHandle>(
    pipe: &mut T,
    bytes: &mut Vec<u8>,
    limit: usize,
) -> Result<bool> {
    use windows_sys::Win32::{
        Foundation::{ERROR_BROKEN_PIPE, GetLastError},
        System::Pipes::PeekNamedPipe,
    };
    let mut available = 0;
    let readable = unsafe {
        PeekNamedPipe(
            pipe.as_raw_handle(),
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            &mut available,
            std::ptr::null_mut(),
        )
    };
    if readable == 0 {
        ensure!(
            unsafe { GetLastError() } == ERROR_BROKEN_PIPE,
            "Project search output failed"
        );
        return Ok(true);
    }
    if available == 0 {
        return Ok(false);
    }
    let mut buffer = [0u8; 8192];
    let count = (available as usize)
        .min(buffer.len())
        .min(limit.saturating_sub(bytes.len()));
    let n = pipe
        .read(&mut buffer[..count])
        .context("Project search output failed")?;
    bytes.extend_from_slice(&buffer[..n]);
    Ok(n == 0)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::sync::mpsc;
    fn child(root: &Path) -> Command {
        let mut command = Command::new("/bin/sh");
        command
            .args([
                "-c",
                "printf '%s' \"$$\" > \"$1/pid\"; while :; do :; done",
                "private-search-fixture",
            ])
            .arg(root);
        command
    }
    #[test]
    fn cancelling_a_stalled_search_reaps_its_actual_private_child() {
        let root = tempfile::tempdir().unwrap();
        let control = SearchControl::default();
        let work_control = control.clone();
        let mut command = child(root.path());
        let (tx, rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            tx.send(capture_search(&mut command, &work_control, 1024).is_err())
                .unwrap();
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        let pid = loop {
            if let Ok(text) = std::fs::read_to_string(root.path().join("pid"))
                && let Ok(pid) = text.parse::<i32>()
            {
                break pid;
            }
            assert!(Instant::now() < deadline, "private child was not admitted");
            std::thread::yield_now();
        };
        control.cancel();
        assert!(rx.recv_timeout(Duration::from_secs(5)).unwrap());
        worker.join().unwrap();
        assert_eq!(
            unsafe { libc::kill(pid, 0) },
            -1,
            "owned child still exists after worker join"
        );
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ESRCH)
        );
        assert!(control.cleanup_confirmed());
    }
    #[test]
    fn a_stalled_search_deadline_reaps_child_and_cancelled_admission_never_spawns() {
        let root = tempfile::tempdir().unwrap();
        let control = SearchControl::with_timeout(Duration::from_millis(100));
        assert!(capture_search(&mut child(root.path()), &control, 1024).is_err());
        let pid: i32 = std::fs::read_to_string(root.path().join("pid"))
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ESRCH)
        );
        std::fs::remove_file(root.path().join("pid")).unwrap();
        let control = SearchControl::default();
        control.cancel();
        assert!(capture_search(&mut child(root.path()), &control, 1024).is_err());
        assert!(!root.path().join("pid").exists());
    }
    #[test]
    fn file_index_requires_success_while_no_match_search_can_return_empty() {
        let mut failed = Command::new("/bin/sh");
        failed.args(["-c", "exit 2"]);
        assert!(capture_checked(&mut failed, &SearchControl::default(), 1024, true).is_err());
        let mut no_match = Command::new("/bin/sh");
        no_match.args(["-c", "exit 1"]);
        assert!(
            capture_search(&mut no_match, &SearchControl::default(), 1024)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn output_cap_stops_and_reaps_private_infinite_producer() {
        let root = tempfile::tempdir().unwrap();
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "printf '%s' \"$$\" > \"$1/pid\"; while :; do printf 'private-fixture-output'; done", "private-search-fixture"]).arg(root.path());
        let bytes = capture_search(&mut command, &SearchControl::default(), 1024).unwrap();
        assert_eq!(bytes.len(), 1024);
        let pid: i32 = std::fs::read_to_string(root.path().join("pid"))
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ESRCH)
        );
    }
}
