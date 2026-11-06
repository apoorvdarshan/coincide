//! Fixed native provider metadata commands. Owned process group/job, bounded
//! nonblocking pipes, cancellation/deadline, and no raw output in errors/logs.
use super::*;
const BYTES: usize = 64 * 1024;
pub(crate) fn capture(
    executable: &std::path::Path,
    args: &[&str],
    allowed: &impl Fn() -> bool,
) -> Result<(bool, Vec<u8>, Vec<u8>)> {
    let mut command = Command::new(executable);
    crate::provider_configuration::apply_to_child(&mut command, false)?;
    transport::isolate_environment(&mut command);
    command
        .args(args)
        .env("GROK_DISABLE_AUTOUPDATER", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for key in [
        "CLAUDECODE",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_PID",
        "CLAUDE_EFFORT",
    ] {
        command.env_remove(key);
    }
    ensure!(allowed(), "Provider check cancelled");
    let mut child =
        OwnedChild::spawn(&mut command).context("Provider metadata command could not start")?;
    let mut stdout = child
        .0
        .stdout
        .take()
        .context("Provider metadata stdout unavailable")?;
    let mut stderr = child
        .0
        .stderr
        .take()
        .context("Provider metadata stderr unavailable")?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        for fd in [stdout.as_raw_fd(), stderr.as_raw_fd()] {
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            ensure!(
                flags >= 0
                    && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } >= 0,
                "Could not bound provider metadata pipe"
            );
        }
    }
    let started = Instant::now();
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let (mut out_eof, mut err_eof) = (false, false);
    loop {
        ensure!(allowed(), "Provider check cancelled");
        ensure!(
            started.elapsed() < Duration::from_secs(10),
            "Provider metadata check timed out"
        );
        if !out_eof {
            out_eof = read_available(&mut stdout, &mut out)?;
        }
        if !err_eof {
            err_eof = read_available(&mut stderr, &mut err)?;
        }
        if let Some(success) = exited(&child)?
            && out_eof
            && err_eof
        {
            return Ok((success, out, err));
        }
        thread::sleep(Duration::from_millis(10));
    }
}
#[cfg(unix)]
pub(super) fn read_available<T: Read>(pipe: &mut T, bytes: &mut Vec<u8>) -> Result<bool> {
    let mut buffer = [0u8; 8192];
    match pipe.read(&mut buffer) {
        Ok(0) => Ok(true),
        Ok(n) => {
            ensure!(
                bytes.len() + n <= BYTES,
                "Provider metadata response exceeds its bound"
            );
            bytes.extend_from_slice(&buffer[..n]);
            Ok(false)
        }
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => Ok(false),
        Err(_) => bail!("Provider metadata pipe failed"),
    }
}
#[cfg(windows)]
pub(super) fn read_available<T: Read + std::os::windows::io::AsRawHandle>(
    pipe: &mut T,
    bytes: &mut Vec<u8>,
) -> Result<bool> {
    use windows_sys::Win32::{
        Foundation::{ERROR_BROKEN_PIPE, GetLastError},
        System::Pipes::PeekNamedPipe,
    };
    let mut available = 0;
    let result = unsafe {
        PeekNamedPipe(
            pipe.as_raw_handle(),
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            &mut available,
            std::ptr::null_mut(),
        )
    };
    if result == 0 {
        ensure!(
            unsafe { GetLastError() } == ERROR_BROKEN_PIPE,
            "Provider metadata pipe failed"
        );
        return Ok(true);
    }
    if available == 0 {
        return Ok(false);
    }
    let mut buffer = [0u8; 8192];
    let length = (available as usize).min(buffer.len());
    let n = pipe
        .read(&mut buffer[..length])
        .context("Provider metadata pipe failed")?;
    ensure!(
        bytes.len() + n <= BYTES,
        "Provider metadata response exceeds its bound"
    );
    bytes.extend_from_slice(&buffer[..n]);
    Ok(n == 0)
}
#[cfg(unix)]
pub(super) fn exited(child: &OwnedChild) -> Result<Option<bool>> {
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    ensure!(
        unsafe {
            libc::waitid(
                libc::P_PID,
                child.0.id(),
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        } == 0,
        "Provider metadata process status unavailable"
    );
    if unsafe { info.si_pid() } == 0 {
        Ok(None)
    } else {
        Ok(Some(
            info.si_code == libc::CLD_EXITED && unsafe { info.si_status() } == 0,
        ))
    }
}
#[cfg(windows)]
pub(super) fn exited(child: &OwnedChild) -> Result<Option<bool>> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::{
        Foundation::WAIT_OBJECT_0,
        System::Threading::{GetExitCodeProcess, WaitForSingleObject},
    };
    if unsafe { WaitForSingleObject(child.0.as_raw_handle(), 0) } != WAIT_OBJECT_0 {
        return Ok(None);
    }
    let mut code = 1;
    ensure!(
        unsafe { GetExitCodeProcess(child.0.as_raw_handle(), &mut code) } != 0,
        "Provider metadata process status unavailable"
    );
    Ok(Some(code == 0))
}
