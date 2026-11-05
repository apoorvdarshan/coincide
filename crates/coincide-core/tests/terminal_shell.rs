//! Synthetic HOME/ZDOTDIR/profile shell integration. Never a user's shell/config.
//! Outer tests launch only this test's ignored child with an isolated environment;
//! the child alone spawns zsh/bash and uses literal fixture commands, not OSC data.
#![cfg(unix)]
use coincide_core::terminal::Terminal;
use serde_json::Value;
use std::{
    fs,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};
struct Guard(Child);
impl Drop for Guard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn run(shell: &str) {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let own = dir.path().join("original zsh");
    fs::create_dir(&home).unwrap();
    fs::create_dir(&own).unwrap();
    let home = fs::canonicalize(home).unwrap();
    fs::create_dir(home.join("sub dir #?% 界")).unwrap();
    fs::write(
        home.join(".bash_profile"),
        r#"printf 'profile>' >> "$HOME/load-order"
. "$HOME/.bashrc"
"#,
    )
    .unwrap();
    fs::write(
        home.join(".bashrc"),
        r#"printf 'rc>' >> "$HOME/load-order"
PS1='$ '
if (( BASH_VERSINFO[0] >= 4 )); then
  PROMPT_COMMAND=('printf "user>" >> "$HOME/load-order"')
else
  PROMPT_COMMAND='printf "user>" >> "$HOME/load-order"'
fi
"#,
    )
    .unwrap();
    for name in [".bash_login", ".profile"] {
        fs::write(home.join(name), "printf WRONG >> \"$HOME/load-order\"\n").unwrap();
    }
    for (name, body) in [
        (".zshenv", "printf 'env>' >> \"$HOME/load-order\"\n"),
        (".zprofile", "printf 'profile>' >> \"$HOME/load-order\"\n"),
        (
            ".zshrc",
            "printf 'rc>' >> \"$HOME/load-order\"\nPS1=$'first\\n$ '\n",
        ),
        (".zlogin", "printf 'login>' >> \"$HOME/load-order\"\n"),
    ] {
        fs::write(own.join(name), body).unwrap();
    }
    let out = dir.path().join("stdout");
    let err = dir.path().join("stderr");
    let mut child = Guard(
        Command::new(std::env::current_exe().unwrap())
            .args([
                "--ignored",
                "--exact",
                "isolated_shell_fixture_child",
                "--nocapture",
            ])
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", &home)
            .env("ZDOTDIR", &own)
            .env("HISTFILE", home.join("history"))
            .env("LANG", "en_US.UTF-8")
            .env("TERMINAL_FIXTURE_SHELL", shell)
            .env("TERMINAL_FIXTURE_HOME", &home)
            .current_dir(&home)
            .stdin(Stdio::null())
            .stdout(fs::File::create(&out).unwrap())
            .stderr(fs::File::create(&err).unwrap())
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        if let Some(status) = child.0.try_wait().unwrap() {
            assert!(
                status.success(),
                "{}\n{}",
                fs::read_to_string(out).unwrap(),
                fs::read_to_string(err).unwrap()
            );
            break;
        }
        assert!(
            Instant::now() < deadline,
            "isolated fixture host timed out: {}",
            fs::read_to_string(&err).unwrap_or_default()
        );
        thread::sleep(Duration::from_millis(20));
    }
}
#[test]
fn bash_launch_markers_cwd_exit_and_original_profile_order() {
    run("/bin/bash");
}
#[cfg(target_os = "macos")]
#[test]
fn zsh_launch_markers_cwd_exit_and_original_zdotdir_order() {
    run("/bin/zsh");
}

fn wait(terminal: &mut Terminal, predicate: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let frame = terminal.snapshot().unwrap();
        if predicate(&frame) {
            return frame;
        }
        assert!(Instant::now() < deadline, "shell fixture timeout: {frame}");
        thread::sleep(Duration::from_millis(10));
    }
}
#[test]
#[ignore = "invoked only by the outer tests with TEMP HOME/ZDOTDIR"]
fn isolated_shell_fixture_child() {
    let Ok(home) = std::env::var("TERMINAL_FIXTURE_HOME") else {
        return;
    };
    let shell = std::env::var("TERMINAL_FIXTURE_SHELL").unwrap();
    let home = std::path::PathBuf::from(home);
    assert_eq!(std::env::var_os("HOME").unwrap(), home.as_os_str());
    let mut terminal = Terminal::spawn(&home, &shell, 12, 35).unwrap();
    let ready = wait(&mut terminal, |frame| {
        frame["shell"]["hasMarks"] == true
            && frame["shell"]["cwd"]["path"] == home.to_str().unwrap()
            && (shell.ends_with("zsh")
                || fs::read_to_string(home.join("load-order"))
                    .unwrap_or_default()
                    .starts_with("profile>rc>user>"))
    });
    let order = fs::read_to_string(home.join("load-order")).unwrap();
    if shell.ends_with("zsh") {
        assert!(order.starts_with("env>profile>rc>login>"), "{order}");
        assert_eq!(ready["shell"]["promptLines"], 2);
    } else {
        assert!(order.starts_with("profile>rc>user>"), "{order}");
        assert!(!order.contains("WRONG"));
    }
    let command = "printf 'fixture-one\\nfixture-two\\n'; false";
    terminal.write(&format!("{command}\r")).unwrap();
    wait(&mut terminal, |frame| {
        frame["shell"]["command"] == command
            && frame["shell"]["exitStatus"] == 1
            && frame["shell"]["isRunning"] == false
    });
    let expected = format!("$ {command}\nfixture-one\nfixture-two");
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let frame = terminal.snapshot().unwrap();
        if let Ok(Some(output)) = terminal.last_command_output(frame["revision"].as_u64().unwrap())
        {
            assert_eq!(output, expected);
            break;
        }
        assert!(
            Instant::now() < deadline,
            "anchored output never became available: {frame}"
        );
        thread::sleep(Duration::from_millis(10));
    }
    let cd = "cd \"$HOME/sub dir #?% 界\"";
    // Capture the exact emitter bytes as well as the parsed PTY metadata. This
    // distinguishes bash 3.2 octet encoding from readline's wide-cell padding.
    terminal
        .write(&format!("{cd} && _coincide_cwd > \"$HOME/cwd-report\"\r"))
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let report = home.join("cwd-report");
    loop {
        if let Ok(bytes) = fs::read(&report) {
            if bytes.ends_with(&[7]) {
                let mut observer = coincide_core::terminal::shell::ShellObserver::default();
                observer.advance(&bytes);
                assert_eq!(
                    observer.state.cwd.as_ref().map(|cwd| cwd.path.as_str()),
                    home.join("sub dir #?% 界").to_str(),
                    "raw synthetic cwd OSC: {}",
                    String::from_utf8_lossy(&bytes)
                );
                break;
            }
        }
        let frame = terminal.snapshot().unwrap();
        assert!(
            Instant::now() < deadline,
            "synthetic cwd emitter did not finish: {frame}"
        );
        thread::sleep(Duration::from_millis(10));
    }
    let changed = wait(&mut terminal, |frame| {
        frame["shell"]["cwd"]["path"] == home.join("sub dir #?% 界").to_str().unwrap()
    });
    assert_eq!(changed["shell"]["cwd"]["trusted"], false);
    assert_eq!(changed["shell"]["exitStatus"], 0);
    terminal.write("exit\r").unwrap();
    wait(&mut terminal, |frame| frame["exitCode"] == 0);
}
