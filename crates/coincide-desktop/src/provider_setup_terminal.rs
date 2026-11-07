//! Native user action transfers a sealed setup request to a separate terminal.
//! Launcher exit is never evidence of sign-in or setup completion.
use anyhow::{Context, Result, ensure};
use coincide_core::provider_configuration::SetupHandoff;
#[cfg(target_os = "linux")]
use std::path::PathBuf;
use std::{
    path::Path,
    process::{Child, Command},
};
#[cfg(not(target_os = "windows"))]
use std::{
    process::Stdio,
    time::{Duration, Instant},
};
struct Launcher(Option<Child>);
impl Drop for Launcher {
    fn drop(&mut self) {
        if let Some(mut child) = self.0.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}
#[cfg(not(target_os = "windows"))]
fn wait_launcher(command: &mut Command, allowed: &impl Fn() -> bool) -> Result<()> {
    let mut child = Launcher(Some(
        command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .context("Could not open a setup terminal")?,
    ));
    let start = Instant::now();
    loop {
        ensure!(
            allowed(),
            "Setup terminal handoff cancelled; check the terminal before retrying"
        );
        ensure!(
            start.elapsed() < Duration::from_secs(10),
            "Setup terminal launcher did not return"
        );
        if let Some(status) = child.0.as_mut().unwrap().try_wait()? {
            child.0.take();
            ensure!(status.success(), "Setup terminal launcher failed");
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}
#[cfg(target_os = "linux")]
fn find(names: &[&str]) -> Option<PathBuf> {
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
        .flat_map(|directory| names.iter().map(move |name| directory.join(name)))
        .find(|path| path.is_file())
}
#[cfg(target_os = "linux")]
fn linux_arguments(terminal: &Path, helper: &Path, handoff: &Path) -> Vec<std::ffi::OsString> {
    let mut args = vec!["-f".into(), terminal.as_os_str().to_owned()];
    args.push(
        if terminal
            .file_name()
            .is_some_and(|name| name == "gnome-terminal")
        {
            "--".into()
        } else {
            "-e".into()
        },
    );
    args.extend([
        helper.as_os_str().to_owned(),
        "--native-provider-setup".into(),
        handoff.as_os_str().to_owned(),
    ]);
    args
}
pub(super) fn hand_off(
    handoff: &mut SetupHandoff,
    helper: &Path,
    allowed: &impl Fn() -> bool,
) -> Result<()> {
    ensure!(allowed(), "Setup handoff cancelled");
    #[cfg(target_os = "macos")]
    {
        let script = handoff.terminal_script(helper)?.to_owned();
        wait_launcher(
            Command::new("/usr/bin/open").args([
                std::ffi::OsStr::new("-a"),
                std::ffi::OsStr::new("Terminal"),
                script.as_os_str(),
            ]),
            allowed,
        )?;
    }
    #[cfg(target_os = "linux")]
    {
        let terminal = find(&["gnome-terminal", "x-terminal-emulator", "konsole", "xterm"])
            .context("Install or select a system terminal before running setup")?;
        let launcher = ["/usr/bin/setsid", "/bin/setsid"]
            .into_iter()
            .map(PathBuf::from)
            .find(|path| path.is_file())
            .context("The system terminal session launcher is unavailable")?;
        // setsid -f hands the separate terminal to the OS; only this short-lived
        // launcher is a GUI child. The sealed helper owns the actual setup child.
        wait_launcher(
            Command::new(launcher).args(linux_arguments(&terminal, helper, handoff.path())),
            allowed,
        )?;
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        // A separate native console receives only helper and opaque handoff paths.
        let child = Command::new(helper)
            .arg("--native-provider-setup")
            .arg(handoff.path())
            .creation_flags(0x00000010)
            .spawn()
            .context("Could not open setup console")?;
        let mut pending = Launcher(Some(child));
        handoff.wait_for_transfer(allowed)?;
        // Windows has no unreaped-child zombie. Explicit external-console
        // transfer releases this handle; it does not claim helper completion.
        pending.0.take();
        return Ok(());
    }
    #[cfg(not(target_os = "windows"))]
    handoff.wait_for_transfer(allowed)
}
#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn terminal_arguments_keep_paths_literal_and_do_not_introduce_shell_commands() {
        let helper = Path::new("/synthetic/helper ' & $(false)");
        let request = Path::new("/synthetic/private/request.pending");
        let arguments = linux_arguments(Path::new("/usr/bin/gnome-terminal"), helper, request);
        assert_eq!(arguments[2], "--");
        assert_eq!(arguments[3], helper.as_os_str());
        assert_eq!(arguments.last().unwrap(), request.as_os_str());
        let arguments = linux_arguments(Path::new("/usr/bin/xterm"), helper, request);
        assert_eq!(arguments[2], "-e");
        assert!(!arguments.iter().any(|argument| argument == "-c"));
    }
}
