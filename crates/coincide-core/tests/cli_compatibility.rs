//! Shipped CLI against task-owned Unix peers only. No real Swift/app/provider state.
#![cfg(unix)]
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs,
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixListener,
    path::PathBuf,
    process::{Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};
const BINARY: &str = env!("CARGO_BIN_EXE_coincide-rs");
const THREAD: &str = "AAAA0000-0000-4000-8000-000000000001";
struct Peer {
    directory: tempfile::TempDir,
    socket: PathBuf,
    data: PathBuf,
    rust_decoy: UnixListener,
    swift_socket: PathBuf,
    swift_decoy: UnixListener,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<Result<()>>>,
    requests: Arc<Mutex<Vec<Value>>>,
    replies: Arc<Mutex<HashMap<String, Value>>>,
}
impl Peer {
    fn new() -> Self {
        let directory = tempfile::Builder::new()
            .prefix("cc-")
            .tempdir_in("/tmp")
            .unwrap();
        let socket = directory.path().join("explicit.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let data = directory.path().join("data");
        fs::create_dir(&data).unwrap();
        let rust_decoy = UnixListener::bind(data.join("control.sock")).unwrap();
        rust_decoy.set_nonblocking(true).unwrap();
        let swift_socket = directory.path().join("swift.sock");
        let swift_decoy = UnixListener::bind(&swift_socket).unwrap();
        swift_decoy.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let recorded = requests.clone();
        let replies = Arc::new(Mutex::new(HashMap::<String, Value>::new()));
        let scripted = replies.clone();
        let worker = thread::spawn(move || -> Result<()> {
            while !stopping.load(Ordering::Acquire) {
                let (mut stream, _) = match listener.accept() {
                    Ok(value) => value,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::yield_now();
                        continue;
                    }
                    Err(error) => return Err(error.into()),
                };
                stream.set_nonblocking(false)?;
                stream.set_read_timeout(Some(Duration::from_secs(2)))?;
                stream.set_write_timeout(Some(Duration::from_secs(2)))?;
                let mut line = String::new();
                BufReader::new(&stream).read_line(&mut line)?;
                let request: Value =
                    serde_json::from_str(&line).context("fake Rust control frame")?;
                recorded.lock().unwrap().push(request.clone());
                if let Some(mut response) = scripted
                    .lock()
                    .unwrap()
                    .get(request["method"].as_str().unwrap())
                    .cloned()
                {
                    response["id"] = request["id"].clone();
                    writeln!(stream, "{response}")?;
                    continue;
                }
                let result = match request["method"].as_str() {
                    Some("app.status") => json!({"running":[],"future":{"keep":[true,"café"]}}),
                    Some("threads.resolve_id") => json!({"threadId":THREAD}),
                    Some("agent.send") => json!({"accepted":true,"future":"unchanged"}),
                    Some("threads.read") => {
                        json!({"id":THREAD,"items":[{"kind":"assistant","text":"synthetic settled reply"}]})
                    }
                    Some("agent.pending") => json!([]),
                    Some("files.list" | "attachments.add" | "browser.request") => {
                        json!({"operationId":"synthetic-operation"})
                    }
                    Some("workspace.result") => {
                        json!({"ready":true,"result":{"path":"synthetic.txt","future":[1,true]}})
                    }
                    Some("browser.result") => {
                        json!({"ready":true,"result":{"title":"SYNTHETIC browser"}})
                    }
                    Some("opaque.synthetic") => request["params"].clone(),
                    Some("opaque.error") => {
                        writeln!(
                            stream,
                            "{}",
                            json!({"id":request["id"],"error":{"code":"notAllowed","message":"synthetic refusal","future":42}})
                        )?;
                        continue;
                    }
                    _ => bail!("Unexpected CLI request at isolated peer"),
                };
                writeln!(stream, "{}", json!({"id":request["id"],"result":result}))?;
            }
            Ok(())
        });
        Self {
            directory,
            socket,
            data,
            rust_decoy,
            swift_socket,
            swift_decoy,
            stop,
            worker: Some(worker),
            requests,
            replies,
        }
    }
    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(BINARY);
        command
            .args(args)
            .env_clear()
            .env("COINCIDE_RUST_DATA_DIR", &self.data)
            .env("COINCIDE_CONTROL_SOCKET", &self.swift_socket)
            .current_dir(self.directory.path());
        command
    }
    fn requests(&self) -> Vec<Value> {
        self.requests.lock().unwrap().clone()
    }
    fn reply(&self, method: &str, response: Value) {
        self.replies.lock().unwrap().insert(method.into(), response);
    }
    fn finish(mut self) {
        self.stop.store(true, Ordering::Release);
        self.worker.take().unwrap().join().unwrap().unwrap();
        for listener in [&self.rust_decoy, &self.swift_decoy] {
            assert_eq!(
                listener.accept().unwrap_err().kind(),
                std::io::ErrorKind::WouldBlock,
                "CLI contacted a default or inherited Swift decoy"
            );
        }
        assert!(
            !self.data.join("coincide.sqlite").exists(),
            "Client command opened a local Engine"
        );
    }
}
impl Drop for Peer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
fn run(mut command: Command, body: Option<&[u8]>) -> (i32, Value) {
    let mut child = command
        .stdin(if body.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    if let Some(body) = body {
        child.stdin.take().unwrap().write_all(body).unwrap();
    }
    let output = child.wait_with_output().unwrap();
    let value = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|_| json!({"stderr":String::from_utf8_lossy(&output.stderr),"stdout":String::from_utf8_lossy(&output.stdout)}));
    (output.status.code().unwrap(), value)
}
#[test]
fn global_json_and_socket_override_preserve_json_without_default_or_swift_contact() {
    let peer = Peer::new();
    let socket = peer.socket.to_str().unwrap();
    let equals = format!("--socket={socket}");
    for args in [
        vec!["--json", "--socket", socket, "status"],
        vec!["status", &equals, "--json"],
        vec!["--socket", "explicit.sock", "status", "--json"],
    ] {
        let (code, value) = run(peer.command(&args), None);
        assert_eq!(code, 0, "{value}");
        assert_eq!(
            value,
            json!({"id":1,"result":{"running":[],"future":{"keep":[true,"café"]}}})
        );
    }
    let mut no_default = peer.command(&["--json", "status", "--socket", socket]);
    no_default.env_remove("COINCIDE_RUST_DATA_DIR");
    assert_eq!(
        run(no_default, None).0,
        0,
        "Explicit socket must work without HOME/LOCALAPPDATA/default data"
    );
    let raw=b"{\"id\":7,\"method\":\"opaque.synthetic\",\"params\":{\"text\":\"preserve raw API\",\"future\":[true,42]}}";
    let (code, value) = run(
        peer.command(&["--socket", socket, "api", "--json"]),
        Some(raw),
    );
    assert_eq!(code, 0);
    assert_eq!(
        value,
        json!({"id":7,"result":{"text":"preserve raw API","future":[true,42]}})
    );
    let (code, value) = run(
        peer.command(&["api", &equals, "--json"]),
        Some(b"{\"id\":9,\"method\":\"opaque.error\",\"params\":{}}"),
    );
    assert_eq!(code, 1);
    assert_eq!(
        value,
        json!({"id":9,"error":{"code":"notAllowed","message":"synthetic refusal","future":42}})
    );
    assert_eq!(peer.requests().len(), 6);
    peer.finish();
}
#[test]
fn explicit_socket_routes_async_helpers_and_wait_with_one_send() {
    let peer = Peer::new();
    let socket = peer.socket.to_str().unwrap();
    let (code, files) = run(
        peer.command(&["files", THREAD, "query", "--socket", socket, "--json"]),
        None,
    );
    assert_eq!(code, 0, "{files}");
    assert_eq!(
        files["result"],
        json!({"path":"synthetic.txt","future":[1,true]})
    );
    let (code, attachment) = run(
        peer.command(&["attach", THREAD, "/synthetic.png", "--socket", socket]),
        None,
    );
    assert_eq!(code, 0, "{attachment}");
    assert_eq!(attachment["result"], files["result"]);
    let (code, browser) = run(
        peer.command(&[
            "--socket",
            socket,
            "browser",
            THREAD,
            "{\"action\":\"read\"}",
            "--json",
        ]),
        None,
    );
    assert_eq!(code, 0, "{browser}");
    assert_eq!(browser["result"], json!({"title":"SYNTHETIC browser"}));
    let (code, wait) = run(
        peer.command(&[
            "--json",
            "send",
            THREAD,
            "one",
            "actual",
            "send",
            "--wait",
            "--timeout",
            "1",
            "--socket",
            socket,
        ]),
        None,
    );
    assert_eq!(code, 0, "{wait}");
    assert_eq!(wait["result"]["state"], "done");
    assert_eq!(
        wait["result"]["transcript"]["items"][0]["text"],
        "synthetic settled reply"
    );
    let calls = peer.requests();
    assert_eq!(
        calls.iter().filter(|v| v["method"] == "agent.send").count(),
        1
    );
    assert_eq!(
        calls.iter().find(|v| v["method"] == "agent.send").unwrap()["params"],
        json!({"threadId":THREAD,"text":"one actual send"})
    );
    assert!(!calls.iter().any(|v| v["method"] == "threads.list"));
    peer.finish();
}
#[test]
fn send_words_literal_flags_and_stdin_preserve_exact_message_once() {
    let peer = Peer::new();
    let socket = peer.socket.to_str().unwrap();
    for (args, body, expected) in [
        (
            vec![
                "--socket", socket, "--json", "send", THREAD, "hello", "café", "world",
            ],
            None,
            "hello café world",
        ),
        (
            vec!["send", THREAD, "-", "--socket", socket, "--json"],
            Some("café 中文\n  keep trailing spaces  \n".as_bytes()),
            "café 中文\n  keep trailing spaces  \n",
        ),
        (
            vec![
                "--socket", socket, "send", THREAD, "--", "--wait", "--json", "-",
            ],
            None,
            "--wait --json -",
        ),
        (
            vec!["send", THREAD, "hello", "-", "--socket", socket],
            None,
            "hello -",
        ),
        // Only Core can decide whether attached context/images admit a turn.
        (vec!["send", THREAD, "", "--socket", socket], None, ""),
        (
            vec!["send", THREAD, "-", "--socket", socket],
            Some("".as_bytes()),
            "",
        ),
        (
            vec!["send", THREAD, "  \t", "--socket", socket],
            None,
            "  \t",
        ),
        (
            vec!["send", THREAD, "-", "--socket", socket],
            Some(" \n\t ".as_bytes()),
            " \n\t ",
        ),
    ] {
        let before = peer.requests().len();
        let (code, value) = run(peer.command(&args), body);
        assert_eq!(code, 0, "{value}");
        let calls = peer.requests();
        assert_eq!(calls.len() - before, 2);
        assert_eq!(calls.last().unwrap()["method"], "agent.send");
        assert_eq!(
            calls.last().unwrap()["params"],
            json!({"threadId":THREAD,"text":expected})
        );
    }
    peer.finish();
}
#[test]
fn malformed_global_or_stdin_input_never_connects_to_any_socket() {
    let peer = Peer::new();
    let socket = peer.socket.to_str().unwrap();
    let equals = format!("--socket={socket}");
    for args in [
        vec!["--socket"],
        vec!["status", "--socket="],
        vec!["status", "--socket", socket, &equals],
        vec!["--json", "status", "--json", "--socket", socket],
        vec!["send", THREAD, "hello", "--alternate", &equals],
        vec!["status", "--socket=bad\npath"],
    ] {
        let (code, value) = run(peer.command(&args), None);
        assert_eq!(code, 2, "{args:?}: {value}");
    }
    let oversized = vec![b'x'; 1024 * 1024 + 1];
    for body in [vec![0xff], oversized] {
        let (code, value) = run(
            peer.command(&["--socket", socket, "send", THREAD, "-"]),
            Some(&body),
        );
        assert_eq!(code, 2, "{value}");
    }
    assert!(peer.requests().is_empty());
    peer.finish();
}
#[test]
fn missing_rust_default_does_not_fall_back_to_inherited_swift_socket() {
    let directory = tempfile::Builder::new()
        .prefix("cd-")
        .tempdir_in("/tmp")
        .unwrap();
    let swift = directory.path().join("swift.sock");
    let listener = UnixListener::bind(&swift).unwrap();
    listener.set_nonblocking(true).unwrap();
    let missing = directory.path().join("never-created");
    let mut command = Command::new(BINARY);
    command
        .args(["status", "--json"])
        .env_clear()
        .env("COINCIDE_RUST_DATA_DIR", &missing)
        .env("COINCIDE_CONTROL_SOCKET", &swift);
    assert_eq!(run(command, None).0, 1);
    assert!(!missing.exists());
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
}

#[test]
fn aliases_preserve_exact_target_payloads_and_wire_errors() {
    let peer = Peer::new();
    let socket = peer.socket.to_str().unwrap();
    peer.reply(
        "threads.patch",
        json!({"result":{"restored":true,"future":[1,"café"]}}),
    );
    for verb in ["restore", "unarchive"] {
        let before = peer.requests().len();
        let (code, reply) = run(peer.command(&[verb, THREAD, "--socket", socket]), None);
        assert_eq!(code, 0, "{reply}");
        assert_eq!(
            reply,
            json!({"id":1,"result":{"restored":true,"future":[1,"café"]}})
        );
        let calls = peer.requests();
        assert_eq!(calls.len() - before, 2);
        assert_eq!(
            calls.last().unwrap(),
            &json!({"id":1,"method":"threads.patch","params":{"threadId":THREAD,"patch":{"isArchived":false}}})
        );
    }
    let opaque = "\"approval::café\"";
    let item = format!("--item={opaque}");
    peer.reply(
        "agent.respond",
        json!({"result":{"answered":true,"future":{"keep":1}}}),
    );
    for args in [
        vec!["decline", THREAD, opaque],
        vec!["deny", THREAD, opaque],
        vec!["deny", THREAD, "--item", opaque],
        vec!["deny", THREAD, &item],
    ] {
        let before = peer.requests().len();
        let mut args = args;
        args.extend(["--socket", socket, "--json"]);
        let (code, reply) = run(peer.command(&args), None);
        assert_eq!(code, 0, "{reply}");
        assert_eq!(
            reply,
            json!({"id":1,"result":{"answered":true,"future":{"keep":1}}})
        );
        let calls = peer.requests();
        assert_eq!(
            calls.len() - before,
            2,
            "Aliases must not select a pending request implicitly"
        );
        assert_eq!(
            calls.last().unwrap(),
            &json!({"id":1,"method":"agent.respond","params":{"threadId":THREAD,"requestId":opaque,"decision":"decline"}})
        );
    }
    let failure =
        json!({"error":{"code":"conflict","message":"synthetic stale approval","future":42}});
    peer.reply("agent.respond", failure.clone());
    let before = peer.requests().len();
    let (code, reply) = run(
        peer.command(&["deny", THREAD, opaque, "--socket", socket]),
        None,
    );
    assert_eq!(code, 1);
    assert_eq!(reply, json!({"id":1,"error":failure["error"]}));
    assert_eq!(
        peer.requests().len() - before,
        2,
        "No fallback/retry after refusal"
    );
    peer.reply(
        "threads.resolve_id",
        json!({"result":{"threadId":"AAAA0000-0000-4000-8000-000000000002"}}),
    );
    for args in [
        vec!["unarchive", THREAD],
        vec!["deny", THREAD, opaque],
        vec!["questions", THREAD],
    ] {
        let before = peer.requests().len();
        let mut args = args;
        args.extend(["--socket", socket]);
        assert_eq!(run(peer.command(&args), None).0, 1);
        let calls = peer.requests();
        assert_eq!(calls.len() - before, 1);
        assert_eq!(calls.last().unwrap()["method"], "threads.resolve_id");
    }
    peer.finish();
}

#[test]
fn questions_keep_authoritative_opaque_fields_and_exclude_approval_records() {
    let peer = Peer::new();
    let socket = peer.socket.to_str().unwrap();
    let first = json!({"requestId":"\"question::café\"","method":"item/tool/requestUserInput","params":{"questions":[{"id":"q1","header":"Choose","question":"Which?","options":[{"label":"A","future":1}]}],"future":[true,42]},"future":{"keep":"exact"}});
    let second = json!({"requestId":"104","method":"item/tool/requestUserInput","params":{"questions":[]},"future":"unchanged"});
    let mixed = json!([
        {"requestId":"approval-1","method":"item/commandExecution/requestApproval","params":{"availableDecisions":["accept","decline"]}},
        first,
        {"requestId":"future-unknown","method":"item/future/request","params":{"questions":[{"id":"not-authorized"}]}},
        second
    ]);
    peer.reply("agent.pending", json!({"result":mixed}));
    let (code, reply) = run(
        peer.command(&["questions", THREAD, "--socket", socket]),
        None,
    );
    assert_eq!(code, 0, "{reply}");
    assert_eq!(reply, json!({"id":1,"result":[first,second]}));
    let (code, pending) = run(peer.command(&["pending", THREAD, "--socket", socket]), None);
    assert_eq!(code, 0);
    assert_eq!(pending, json!({"id":1,"result":mixed}));
    peer.reply("agent.pending", json!({"result":[]}));
    assert_eq!(
        run(
            peer.command(&["questions", THREAD, "--socket", socket]),
            None
        ),
        (0, json!({"id":1,"result":[]}))
    );
    let failure = json!({"code":"notAllowed","message":"synthetic refusal","future":[1,true]});
    peer.reply("agent.pending", json!({"error":failure}));
    let (code, reply) = run(
        peer.command(&["questions", THREAD, "--socket", socket]),
        None,
    );
    assert_eq!(code, 1);
    assert_eq!(reply, json!({"id":1,"error":failure}));
    peer.reply("agent.pending", json!({"result":{"not":"a list"}}));
    assert_eq!(
        run(
            peer.command(&["questions", THREAD, "--socket", socket]),
            None
        )
        .0,
        1
    );
    let calls = peer.requests();
    assert_eq!(calls.len(), 10);
    assert!(calls.iter().all(|call| matches!(
        call["method"].as_str(),
        Some("threads.resolve_id" | "agent.pending")
    )));
    assert!(
        calls
            .iter()
            .all(|call| call["params"]["threadId"] == THREAD)
    );
    peer.finish();
}

#[test]
fn read_equality_forms_and_help_aliases_preserve_existing_item_semantics() {
    let peer = Peer::new();
    let socket = peer.socket.to_str().unwrap();
    for (options, count, offset) in [
        (vec!["--count=0", "--offset=12"], 0, 12),
        (vec!["--count=2", "--offset", "0"], 2, 0),
        (vec!["--count", "1000", "--offset=7"], 1000, 7),
    ] {
        let before = peer.requests().len();
        let mut args = vec!["read", THREAD, "--socket", socket];
        args.extend(options);
        let (code, reply) = run(peer.command(&args), None);
        assert_eq!(code, 0, "{reply}");
        assert_eq!(
            reply,
            json!({"id":1,"result":{"id":THREAD,"items":[{"kind":"assistant","text":"synthetic settled reply"}]}})
        );
        let calls = peer.requests();
        assert_eq!(calls.len() - before, 2);
        assert_eq!(
            calls.last().unwrap(),
            &json!({"id":1,"method":"threads.read","params":{"threadId":THREAD,"itemLimit":count,"itemOffset":offset}})
        );
    }
    let before = peer.requests().len();
    for alias in ["help", "-h", "--help"] {
        let mut command = peer.command(&["--json", alias]);
        command.env_remove("COINCIDE_RUST_DATA_DIR");
        let (code, reply) = run(command, None);
        assert_eq!(code, 0, "{reply}");
        assert!(
            reply["stdout"]
                .as_str()
                .unwrap()
                .contains("Coincide Rust preview CLI")
        );
    }
    assert_eq!(
        peer.requests().len(),
        before,
        "Help needs no data directory or transport"
    );
    peer.finish();
}

#[test]
fn malformed_alias_and_read_forms_reject_before_transport() {
    let peer = Peer::new();
    let socket = peer.socket.to_str().unwrap();
    for args in [
        vec!["deny", THREAD],
        vec!["deny", THREAD, "id", "--item", "other"],
        vec!["deny", THREAD, "--item", "id", "--item=other"],
        vec!["deny", THREAD, "--item="],
        vec!["deny", THREAD, "--item", "id", "--message", "unsupported"],
        vec!["questions", THREAD, "--item", "unsupported"],
        vec!["unarchive", THREAD, "extra"],
        vec!["read", THREAD, "--count=1", "--count", "2"],
        vec!["read", THREAD, "--offset", "0", "--offset=1"],
        vec!["read", THREAD, "--count="],
        vec!["read", THREAD, "--count=1001"],
        vec!["read", THREAD, "--offset=-1"],
        vec!["read", THREAD, "--count=not-a-number"],
    ] {
        let mut args = args;
        args.extend(["--socket", socket]);
        let (code, reply) = run(peer.command(&args), None);
        assert_eq!(code, 2, "{args:?}: {reply}");
    }
    assert!(peer.requests().is_empty());
    peer.finish();
}
