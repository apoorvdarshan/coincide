#![cfg(unix)]
//! Exercise the shipped CLI and a separate headless engine process, not direct
//! library calls. Every process uses an isolated data directory and clean env.
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Stdio},
    sync::atomic::{AtomicUsize, Ordering},
    thread,
    time::{Duration, Instant},
};

const BINARY: &str = env!("CARGO_BIN_EXE_coincide-rs");
const COMMAND_TIMEOUT: Duration = Duration::from_secs(10);

struct ChildGuard(Child);
impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
struct Reply {
    status: ExitStatus,
    value: Option<Value>,
    stdout: String,
    stderr: String,
}
impl Reply {
    fn success(self) -> Value {
        assert!(
            self.status.success(),
            "CLI failed: stdout={} stderr={}",
            self.stdout,
            self.stderr
        );
        let value = self.value.expect("Successful CLI command must return JSON");
        assert!(value.get("error").is_none(), "{value}");
        value["result"].clone()
    }
    fn failure(self) -> Value {
        assert!(
            !self.status.success(),
            "Expected CLI error, got {}",
            self.stdout
        );
        self.value
            .unwrap_or_else(|| json!({"error":{"message":self.stderr}}))
    }
}
struct Fixture {
    dir: tempfile::TempDir,
    data: PathBuf,
    sequence: AtomicUsize,
}
impl Fixture {
    fn new() -> Self {
        // macOS's default per-user temp path can exceed Unix socket limits.
        let dir = tempfile::Builder::new()
            .prefix("coincide-cli-")
            .tempdir_in("/tmp")
            .unwrap();
        let data = dir.path().join("data");
        Self {
            dir,
            data,
            sequence: AtomicUsize::new(0),
        }
    }
    fn command(&self) -> Command {
        let mut command = Command::new(BINARY);
        command
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("SHELL", "/bin/sh")
            .env("COINCIDE_RUST_DATA_DIR", &self.data)
            .current_dir(self.dir.path());
        command
    }
    fn logs(&self, prefix: &str) -> (PathBuf, PathBuf) {
        let n = self.sequence.fetch_add(1, Ordering::Relaxed);
        (
            self.dir.path().join(format!("{prefix}-{n}.stdout")),
            self.dir.path().join(format!("{prefix}-{n}.stderr")),
        )
    }
    fn run(&self, args: &[&str], input: Option<Value>) -> Reply {
        let (out, err) = self.logs("cli");
        let mut child = ChildGuard(
            self.command()
                .args(args)
                .stdin(if input.is_some() {
                    Stdio::piped()
                } else {
                    Stdio::null()
                })
                .stdout(fs::File::create(&out).unwrap())
                .stderr(fs::File::create(&err).unwrap())
                .spawn()
                .unwrap(),
        );
        if let Some(input) = input {
            let mut stdin = child.0.stdin.take().unwrap();
            stdin
                .write_all(serde_json::to_string(&input).unwrap().as_bytes())
                .unwrap();
        }
        let deadline = Instant::now() + COMMAND_TIMEOUT;
        let status = loop {
            if let Some(status) = child.0.try_wait().unwrap() {
                break status;
            }
            assert!(
                Instant::now() < deadline,
                "CLI timed out for {args:?}: {}",
                fs::read_to_string(&err).unwrap_or_default()
            );
            thread::sleep(Duration::from_millis(20));
        };
        let stdout = fs::read_to_string(out).unwrap();
        let stderr = fs::read_to_string(err).unwrap();
        Reply {
            status,
            value: serde_json::from_str(&stdout).ok(),
            stdout,
            stderr,
        }
    }
    fn cli(&self, args: &[&str]) -> Value {
        self.run(args, None).success()
    }
    fn api(&self, method: &str, params: Value) -> Value {
        self.run(
            &["api"],
            Some(json!({"id":"integration-request","method":method,"params":params})),
        )
        .success()
    }
    fn start(&self) -> Server {
        let (out, err) = self.logs("server");
        let child = self
            .command()
            .arg("serve")
            .stdin(Stdio::null())
            .stdout(fs::File::create(out).unwrap())
            .stderr(fs::File::create(&err).unwrap())
            .spawn()
            .unwrap();
        let mut server = Server {
            child: ChildGuard(child),
            socket: self.data.join("control.sock"),
        };
        let deadline = Instant::now() + COMMAND_TIMEOUT;
        loop {
            assert!(
                server.child.0.try_wait().unwrap().is_none(),
                "Server exited before readiness: {}",
                fs::read_to_string(&err).unwrap_or_default()
            );
            if server.socket.exists() && UnixStream::connect(&server.socket).is_ok() {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "Server did not create socket: {}",
                fs::read_to_string(&err).unwrap_or_default()
            );
            thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(self.cli(&["status"])["preview"], true);
        server
    }
}
struct Server {
    child: ChildGuard,
    socket: PathBuf,
}
impl Server {
    fn wait_stopped(&mut self) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = self.child.0.try_wait().unwrap() {
                assert!(status.success(), "Server exited unsuccessfully: {status}");
                break;
            }
            assert!(Instant::now() < deadline, "Server ignored quit");
            thread::sleep(Duration::from_millis(20));
        }
        assert!(
            !self.socket.exists(),
            "Server left its control socket behind"
        );
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        // Cleanup on assertion failure too: allow normal terminal/process cleanup
        // before ChildGuard's final bounded kill/reap fallback.
        if self.child.0.try_wait().ok().flatten().is_some() {
            return;
        }
        if let Ok(mut socket) = UnixStream::connect(&self.socket) {
            let _ = socket.set_write_timeout(Some(Duration::from_millis(500)));
            let _ = socket.write_all(b"{\"method\":\"app.quit\",\"params\":{}}\n");
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if self.child.0.try_wait().ok().flatten().is_some() {
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
}
fn mode(path: &Path) -> u32 {
    fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn headless_cli_project_thread_edits_survive_server_restart() {
    let fixture = Fixture::new();
    let mut server = fixture.start();
    assert_eq!(mode(&fixture.data), 0o700);
    assert_eq!(mode(&server.socket), 0o600);
    assert_eq!(mode(&fixture.data.join("coincide.sqlite")), 0o600);
    let project_path = fixture.dir.path().join("project with spaces");
    fs::create_dir(&project_path).unwrap();
    let project = fixture.api(
        "projects.create",
        json!({"path":project_path,"name":"Original"}),
    );
    let project_id = project["id"].as_str().unwrap();
    fixture.api(
        "projects.patch",
        json!({"projectId":project_id,"patch":{"name":"Renamed"}}),
    );
    let thread = fixture.api("threads.create", json!({"projectId":project_id}));
    let id = thread["id"].as_str().unwrap();
    let draft = "Unsent draft — quotes: \"hello\"\nSecond line";
    fixture.cli(&["draft", id, draft]);
    fixture.api(
        "threads.patch",
        json!({"threadId":id,"patch":{"title":"Durable CLI thread","isPinned":true}}),
    );
    let listed = fixture.cli(&["threads", "Durable CLI"]);
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["pinned"], true);
    fixture.cli(&["archive", id]);
    assert!(
        fixture
            .api("threads.list", json!({}))
            .as_array()
            .unwrap()
            .is_empty()
    );
    fixture.cli(&["restore", id]);
    let rejected=fixture.run(&["api"],Some(json!({"method":"threads.patch","params":{"threadId":id,"patch":{"draft":"discard this","sessions":{}}}}))).failure();
    assert!(
        rejected["error"]["message"]
            .as_str()
            .unwrap()
            .contains("Unsupported")
    );
    assert_eq!(fixture.cli(&["read", id])["draft"], draft);
    let empty_path = fixture.dir.path().join("empty project");
    fs::create_dir(&empty_path).unwrap();
    let empty = fixture.api("projects.create", json!({"path":empty_path}));
    fixture.api("projects.remove", json!({"projectId":empty["id"]}));
    assert_eq!(fixture.cli(&["projects"]).as_array().unwrap().len(), 1);
    fixture.cli(&["quit"]);
    server.wait_stopped();
    drop(server);
    let mut server = fixture.start();
    let restored = fixture.cli(&["read", id]);
    assert_eq!(restored["draft"], draft);
    assert_eq!(restored["isPinned"], true);
    assert_eq!(restored["isArchived"], false);
    assert_eq!(restored["projectID"], project_id);
    assert_eq!(fixture.cli(&["projects"])[0]["name"], "Renamed");
    fixture.cli(&["quit"]);
    server.wait_stopped();
    assert!(!fixture.run(&["status"], None).status.success());
}

#[test]
fn headless_cli_pty_output_and_browser_refusal_are_explicit() {
    let fixture = Fixture::new();
    let mut server = fixture.start();
    let thread = fixture.cli(&["new", fixture.dir.path().to_str().unwrap()]);
    let id = thread["id"].as_str().unwrap();
    let error = fixture
        .run(&["browser", id, r#"{"action":"read"}"#], None)
        .failure();
    let message = error["error"]["message"].as_str().unwrap();
    assert!(
        message.contains("desktop") || message.contains("UI") || message.contains("headless"),
        "Unexpected browser refusal: {message}"
    );
    let terminal = fixture.api("terminal.create", json!({"threadId":id}));
    let terminal_id = terminal["terminalId"].as_str().unwrap();
    fixture.api(
        "terminal.resize",
        json!({"terminalId":terminal_id,"rows":12,"cols":80}),
    );
    // The complete marker never appears in the input, so echoed shell input
    // cannot make this test pass without actually executing printf.
    fixture.api(
        "terminal.write",
        json!({"terminalId":terminal_id,"text":"printf '%s%s\\n' 'COINCIDE_' 'PTY_OK'; exit\n"}),
    );
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        let snapshot = fixture.api("terminal.read", json!({"terminalId":terminal_id}));
        let output = snapshot["lines"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join("\n");
        if output.contains("COINCIDE_PTY_OK") && snapshot["exitCode"] == 0 {
            assert_eq!(snapshot["rows"], 12);
            assert_eq!(snapshot["cols"], 80);
            break;
        }
        assert!(
            Instant::now() < deadline,
            "PTY did not produce expected output and exit: {snapshot}"
        );
        thread::sleep(Duration::from_millis(40));
    }
    fixture.api("terminal.close", json!({"terminalId":terminal_id}));
    assert!(
        fixture
            .api("terminal.list", json!({"threadId":id}))
            .as_array()
            .unwrap()
            .is_empty()
    );
    fixture.cli(&["quit"]);
    server.wait_stopped();
}
