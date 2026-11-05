//! Synthetic shell -> real PTY -> dispatcher/socket -> shipped CLI forwarding.
//! No profiles, real accounts, desktop windows or existing app data are used.
#![cfg(unix)]
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

struct Process(Child);
impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
struct Fixture {
    server: Process,
    dir: tempfile::TempDir,
    sequence: usize,
}
impl Fixture {
    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_coincide-rs"));
        command
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("SHELL", self.dir.path().join("fixture-shell"))
            .env("COINCIDE_RUST_DATA_DIR", self.dir.path().join("data"))
            .current_dir(self.dir.path());
        command
    }
    fn new() -> Self {
        let dir = tempfile::Builder::new()
            .prefix("terminal-scroll-")
            .tempdir_in("/tmp")
            .unwrap();
        let shell = dir.path().join("fixture-shell");
        fs::write(&shell, "#!/bin/sh\nstty -echo\nprintf '\\033]2;shell-ready\\007'\nIFS= read -r start\nprintf 'a\\r\\nb\\r\\nc\\r\\nd\\r\\ne\\r\\nf\\033]2;scroll-ready\\007'\nIFS= read -r next\nprintf '\\033[?1049hALT\\033]2;alt-ready\\007'\nIFS= read -r next\nprintf '\\033[?1049l\\033]2;main-ready\\007'\nIFS= read -r finish\n").unwrap();
        fs::set_permissions(&shell, fs::Permissions::from_mode(0o700)).unwrap();
        let mut command = Command::new(env!("CARGO_BIN_EXE_coincide-rs"));
        let server = Process(
            command
                .arg("serve")
                .env_clear()
                .env("PATH", "/usr/bin:/bin")
                .env("SHELL", &shell)
                .env("COINCIDE_RUST_DATA_DIR", dir.path().join("data"))
                .current_dir(dir.path())
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(fs::File::create(dir.path().join("server.log")).unwrap())
                .spawn()
                .unwrap(),
        );
        let mut fixture = Self {
            server,
            dir,
            sequence: 0,
        };
        let deadline = Instant::now() + Duration::from_secs(10);
        while !fixture.dir.path().join("data/control.sock").exists() {
            assert!(
                fixture.server.0.try_wait().unwrap().is_none(),
                "server exited"
            );
            assert!(Instant::now() < deadline, "server readiness timeout");
            thread::sleep(Duration::from_millis(20));
        }
        fixture
    }
    fn request(&mut self, method: &str, params: Value, success: bool) -> Value {
        self.sequence += 1;
        let out = self.dir.path().join(format!("cli-{}.out", self.sequence));
        let err = self.dir.path().join(format!("cli-{}.err", self.sequence));
        let mut child = Process(
            self.command()
                .arg("api")
                .stdin(Stdio::piped())
                .stdout(fs::File::create(&out).unwrap())
                .stderr(fs::File::create(&err).unwrap())
                .spawn()
                .unwrap(),
        );
        let request = json!({"id":self.sequence,"method":method,"params":params});
        child
            .0
            .stdin
            .take()
            .unwrap()
            .write_all(request.to_string().as_bytes())
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        let status = loop {
            if let Some(status) = child.0.try_wait().unwrap() {
                break status;
            }
            assert!(Instant::now() < deadline, "CLI timeout: {method}");
            thread::sleep(Duration::from_millis(10));
        };
        assert_eq!(
            status.success(),
            success,
            "{}",
            fs::read_to_string(err).unwrap()
        );
        let response: Value = serde_json::from_slice(&fs::read(out).unwrap()).unwrap();
        assert_eq!(response["id"], self.sequence);
        if success {
            assert!(response.get("error").is_none(), "{response}");
            response["result"].clone()
        } else {
            assert!(response["error"]["message"].is_string(), "{response}");
            response
        }
    }
    fn ready(&mut self, terminal: &Value, title: &str) -> Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let frame = self.request("terminal.read", json!({"terminalId":terminal}), true);
            if frame["title"] == title {
                return frame;
            }
            assert!(Instant::now() < deadline, "fixture output timeout: {frame}");
            thread::sleep(Duration::from_millis(20));
        }
    }
    fn terminal(&mut self) -> (Value, Value) {
        let cwd = self.dir.path().to_str().unwrap().to_owned();
        let thread = self.request("threads.create", json!({"cwd":cwd}), true);
        let terminal =
            self.request("terminal.create", json!({"threadId":thread["id"]}), true)["terminalId"]
                .clone();
        self.ready(&terminal, "shell-ready");
        self.request(
            "terminal.resize",
            json!({"terminalId":terminal,"rows":3,"cols":8}),
            true,
        );
        self.request(
            "terminal.write",
            json!({"terminalId":terminal,"text":"go\n"}),
            true,
        );
        let frame = self.ready(&terminal, "scroll-ready");
        (terminal, frame)
    }
    fn scroll(&mut self, terminal: &Value, frame: &Value, scroll: Value) -> Value {
        self.request(
            "terminal.scroll",
            json!({"terminalId":terminal,"revision":frame["revision"],"scroll":scroll}),
            true,
        )
    }
}

#[test]
fn cli_scroll_dispatches_history_and_revision_safe_selection() {
    let mut fixture = Fixture::new();
    let capabilities = fixture.request("app.capabilities", json!({}), true);
    assert!(
        capabilities
            .as_array()
            .unwrap()
            .contains(&json!("terminal.scroll"))
    );
    let (terminal, live) = fixture.terminal();
    assert_eq!(live["lines"], json!(["d", "e", "f"]));
    let top = fixture.scroll(&terminal, &live, json!({"kind":"top"}));
    assert_eq!(top["changed"], true);
    assert_eq!(top["frame"]["lines"], json!(["a", "b", "c"]));
    assert_eq!(top["frame"]["viewport"]["displayOffset"], 3);
    assert!(top["frame"]["revision"].as_u64() > live["revision"].as_u64());
    let stale = fixture.request(
        "terminal.scroll",
        json!({"terminalId":terminal,"revision":live["revision"],"scroll":{"kind":"bottom"}}),
        false,
    );
    assert!(
        stale["error"]["message"]
            .as_str()
            .unwrap()
            .contains("revision changed")
    );
    fixture.request("terminal.selection", json!({"terminalId":terminal,"revision":live["revision"],"start":{"row":0,"col":0},"end":{"row":0,"col":0}}), false);
    let copy = fixture.request("terminal.selection", json!({"terminalId":terminal,"revision":top["frame"]["revision"],"start":{"row":0,"col":0},"end":{"row":2,"col":0}}), true);
    assert_eq!(copy["text"], "a\nb\nc");
    let noop = fixture.scroll(&terminal, &top["frame"], json!({"kind":"top"}));
    assert_eq!(noop["changed"], false);
    assert_eq!(noop["frame"]["revision"], top["frame"]["revision"]);
    let down = fixture.scroll(
        &terminal,
        &noop["frame"],
        json!({"kind":"lines","lines":-1}),
    );
    assert_eq!(down["frame"]["lines"], json!(["b", "c", "d"]));
    let bottom = fixture.scroll(&terminal, &down["frame"], json!({"kind":"bottom"}));
    assert_eq!(bottom["frame"]["lines"], live["lines"]);
    assert_eq!(bottom["frame"]["viewport"]["atBottom"], true);
    fixture.request("terminal.close", json!({"terminalId":terminal}), true);
    fixture.request(
        "terminal.scroll",
        json!({"terminalId":terminal,"revision":0,"scroll":{"kind":"top"}}),
        false,
    );
    fixture.request("app.quit", json!({}), true);
}
