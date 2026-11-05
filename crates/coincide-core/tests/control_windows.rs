#![cfg(windows)]
//! The actual Windows CLI and a separate headless process share the named-pipe
//! transport. All files are isolated fixtures; no existing app is contacted.
use coincide_core::control;
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Stdio},
    thread,
    time::{Duration, Instant},
};

const BINARY: &str = env!("CARGO_BIN_EXE_coincide-rs");
const TIMEOUT: Duration = Duration::from_secs(20);

struct ChildGuard(Child);
impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn wait(child: &mut Child) -> ExitStatus {
    let deadline = Instant::now() + TIMEOUT;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        assert!(Instant::now() < deadline, "Windows CLI process timed out");
        thread::sleep(Duration::from_millis(20));
    }
}
fn command(data: &Path) -> Command {
    let mut command = Command::new(BINARY);
    // Preserve SystemRoot and other Windows loader requirements. Override only
    // the app's data root; this test never sends a provider/terminal command.
    command
        .env("COINCIDE_RUST_DATA_DIR", data)
        .stdin(Stdio::null());
    command
}
fn start(data: &Path, log: &Path) -> ChildGuard {
    let stdout = fs::File::create(log.with_extension("stdout")).unwrap();
    let stderr = fs::File::create(log.with_extension("stderr")).unwrap();
    let mut process = ChildGuard(
        command(data)
            .arg("serve")
            .stdout(stdout)
            .stderr(stderr)
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + TIMEOUT;
    loop {
        if let Some(status) = process.0.try_wait().unwrap() {
            panic!(
                "Headless Windows server exited {status}: {}",
                fs::read_to_string(log.with_extension("stderr")).unwrap()
            );
        }
        if let Ok(reply) = control::request(
            &data.join("control.sock"),
            &json!({"method":"app.status","params":{}}),
        ) && reply.get("error").is_none()
        {
            return process;
        }
        assert!(
            Instant::now() < deadline,
            "Windows control server never became ready"
        );
        thread::sleep(Duration::from_millis(20));
    }
}
fn cli(data: &Path, log: &Path, args: &[&str], body: Option<Value>) -> Value {
    let stdout = fs::File::create(log.with_extension("stdout")).unwrap();
    let stderr = fs::File::create(log.with_extension("stderr")).unwrap();
    let mut process = ChildGuard(
        command(data)
            .args(args)
            .stdin(if body.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(stdout)
            .stderr(stderr)
            .spawn()
            .unwrap(),
    );
    if let Some(body) = body {
        process
            .0
            .stdin
            .take()
            .unwrap()
            .write_all(&serde_json::to_vec(&body).unwrap())
            .unwrap();
    }
    let status = wait(&mut process.0);
    let stdout = fs::read_to_string(log.with_extension("stdout")).unwrap();
    let stderr = fs::read_to_string(log.with_extension("stderr")).unwrap();
    assert!(status.success(), "CLI {args:?} failed: {stdout} {stderr}");
    let reply: Value = serde_json::from_str(&stdout).unwrap();
    assert!(reply.get("error").is_none(), "{reply}");
    reply["result"].clone()
}

#[test]
fn windows_cli_preserves_edits_across_graceful_quit_and_abrupt_restart() {
    let fixture = tempfile::tempdir().unwrap();
    let data: PathBuf = fixture.path().join("isolated data");
    let log = fixture.path().join("cli");
    let mut server = start(&data, &fixture.path().join("server-one"));
    let thread = cli(
        &data,
        &log,
        &["api"],
        Some(json!({"method":"threads.create","params":{}})),
    );
    let id = thread["id"].as_str().unwrap();
    cli(
        &data,
        &log,
        &["draft", id, "Persisted Windows draft 🪟"],
        None,
    );
    cli(
        &data,
        &log,
        &["api"],
        Some(json!({"method":"threads.patch","params":{
            "threadId":id,"patch":{"title":"Windows pipe fixture","isPinned":true}
        }})),
    );
    // A successful quit must contain the complete response before disconnect.
    cli(&data, &log, &["quit"], None);
    assert!(wait(&mut server.0).success());
    drop(server);

    let mut server = start(&data, &fixture.path().join("server-two"));
    let restored = cli(&data, &log, &["read", id], None);
    assert_eq!(restored["draft"], "Persisted Windows draft 🪟");
    assert_eq!(restored["title"], "Windows pipe fixture");
    assert_eq!(restored["isPinned"], true);
    server.0.kill().unwrap();
    wait(&mut server.0);
    drop(server);

    let mut server = start(&data, &fixture.path().join("server-three"));
    assert_eq!(
        cli(&data, &log, &["read", id], None)["draft"],
        restored["draft"]
    );
    cli(&data, &log, &["quit"], None);
    assert!(wait(&mut server.0).success());
}
