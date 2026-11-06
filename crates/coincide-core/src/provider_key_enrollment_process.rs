//! Fixed Codex API-key enrollment. Secret bytes travel only through its private
//! stdin pipe. The operation retains child/group and writer custody to return.
use super::*;
struct Owner {
    child: Option<OwnedChild>,
    writer: Option<thread::JoinHandle<Result<()>>>,
}
impl Drop for Owner {
    fn drop(&mut self) {
        // Killing/reaping the process group closes the pipe before joining a
        // writer blocked on a CLI that stopped reading. No detached IO workers.
        drop(self.child.take());
        if let Some(writer) = self.writer.take() {
            let _ = writer.join();
        }
    }
}
pub(crate) fn codex(
    executable: &std::path::Path,
    key: zeroize::Zeroizing<Vec<u8>>,
    allowed: &impl Fn() -> bool,
) -> Result<()> {
    let mut command = Command::new(executable);
    crate::provider_configuration::apply_to_child(&mut command, false)?;
    command.args([
        "-c",
        "cli_auth_credentials_store=\"file\"",
        "-c",
        "forced_login_method=\"api\"",
        "-c",
        "model_provider=\"openai\"",
        "-c",
        "openai_base_url=\"https://api.openai.com/v1\"",
        "login",
        "--with-api-key",
    ]);
    run(&mut command, key, allowed)
}
fn run(
    command: &mut Command,
    key: zeroize::Zeroizing<Vec<u8>>,
    allowed: &impl Fn() -> bool,
) -> Result<()> {
    ensure!(
        !key.is_empty() && key.len() <= 16 * 1024,
        "Account key exceeds its enrollment limit"
    );
    ensure!(allowed(), "Account enrollment cancelled");
    transport::isolate_environment(command);
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let child = OwnedChild::spawn(command).context("Account enrollment child could not start")?;
    let mut owner = Owner {
        child: Some(child),
        writer: None,
    };
    let mut input = owner
        .child
        .as_mut()
        .unwrap()
        .0
        .stdin
        .take()
        .context("Account enrollment stdin unavailable")?;
    let mut stdout = owner
        .child
        .as_mut()
        .unwrap()
        .0
        .stdout
        .take()
        .context("Account enrollment stdout unavailable")?;
    let mut stderr = owner
        .child
        .as_mut()
        .unwrap()
        .0
        .stderr
        .take()
        .context("Account enrollment stderr unavailable")?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        for fd in [stdout.as_raw_fd(), stderr.as_raw_fd()] {
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            ensure!(
                flags >= 0
                    && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } >= 0,
                "Account enrollment pipe custody unavailable"
            );
        }
    }
    owner.writer = Some(
        thread::Builder::new()
            .name("native-key-enrollment-stdin".into())
            .spawn(move || {
                input
                    .write_all(&key)
                    .and_then(|()| input.write_all(b"\n"))
                    .and_then(|()| input.flush())
                    .map_err(|_| anyhow::anyhow!("Account enrollment stdin failed"))
            })
            .context("Account enrollment writer unavailable")?,
    );
    let started = Instant::now();
    let (mut out, mut err) = (
        zeroize::Zeroizing::new(Vec::new()),
        zeroize::Zeroizing::new(Vec::new()),
    );
    let (mut out_eof, mut err_eof) = (false, false);
    loop {
        ensure!(allowed(), "Account enrollment cancelled");
        ensure!(
            started.elapsed() < Duration::from_secs(30),
            "Account enrollment timed out"
        );
        if !out_eof {
            out_eof = metadata_capture::read_available(&mut stdout, &mut out)?;
        }
        if !err_eof {
            err_eof = metadata_capture::read_available(&mut stderr, &mut err)?;
        }
        if let Some(success) = metadata_capture::exited(owner.child.as_ref().unwrap())?
            && out_eof
            && err_eof
        {
            ensure!(
                success,
                "Account enrollment was not confirmed; the saved key is retained"
            );
            drop(owner.child.take());
            let writer = owner.writer.take().unwrap();
            writer
                .join()
                .map_err(|_| anyhow::anyhow!("Account enrollment writer failed"))??;
            return Ok(());
        }
        thread::sleep(Duration::from_millis(10));
    }
}
#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[test]
    fn synthetic_enrollment_child_receives_stdin_only_and_is_reaped_on_cancel() {
        let root = tempfile::tempdir().unwrap();
        let capture = root.path().join("captured");
        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", "cat > \"$1\"", "synthetic-enrollment"])
            .arg(&capture);
        run(
            &mut command,
            zeroize::Zeroizing::new(b"synthetic-key-input".to_vec()),
            &|| true,
        )
        .unwrap();
        assert_eq!(std::fs::read(&capture).unwrap(), b"synthetic-key-input\n");
        let pid = root.path().join("pid");
        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", "echo $$ > \"$1\"; exec sleep 30", "synthetic-cancel"])
            .arg(&pid);
        let allowed = || !pid.metadata().is_ok_and(|metadata| metadata.len() > 0);
        assert!(
            run(
                &mut command,
                zeroize::Zeroizing::new(b"synthetic-cancel-key".to_vec()),
                &allowed
            )
            .is_err()
        );
        let child: libc::pid_t = String::from_utf8(std::fs::read(&pid).unwrap())
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert_eq!(unsafe { libc::kill(child, 0) }, -1);
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ESRCH)
        );
    }
}
