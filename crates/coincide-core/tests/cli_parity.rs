//! Shipped CLI against isolated synthetic state or a scripted control peer.
//! No real agent.send, provider, terminal, browser, vault or native effect.
use coincide_core::{api::Engine, control, store::Store};
use serde_json::{Value, json};
use std::{
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
    sync::{Arc, Mutex},
};

const BINARY: &str = env!("CARGO_BIN_EXE_coincide-rs");
const FIRST: &str = "AAAA0000-0000-4000-8000-000000000001";
const SECOND: &str = "AAAA0000-0000-4000-8000-000000000002";
const PROJECT: &str = "BBBB0000-0000-4000-8000-000000000001";

struct Fixture {
    _server: control::Server,
    engine: Arc<Mutex<Engine>>,
    directory: tempfile::TempDir,
    data: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let base = if cfg!(unix) {
            PathBuf::from("/tmp")
        } else {
            std::env::temp_dir()
        };
        let directory = tempfile::Builder::new()
            .prefix("cp-")
            .tempdir_in(base)
            .unwrap();
        let data = directory.path().join("data");
        let mut store = Store::open(&data.join("coincide.sqlite")).unwrap();
        let project = store
            .create_project(directory.path(), Some("Synthetic project"))
            .unwrap();
        for (id, title, archived, project_id) in [
            (
                FIRST,
                "Exact 界 title",
                false,
                "00000000-0000-0000-0000-000000000000".to_owned(),
            ),
            (
                SECOND,
                "Archived title",
                true,
                project["id"].as_str().unwrap().to_owned(),
            ),
            (
                PROJECT,
                "Exact 界 title",
                false,
                project["id"].as_str().unwrap().to_owned(),
            ),
        ] {
            let mut thread = store.new_thread(&project_id).unwrap();
            let original = thread["id"].as_str().unwrap().to_owned();
            // Keep new_thread's row; give it an inert unique title and archive it.
            thread["title"] = json!(format!("unused {original}"));
            thread["isArchived"] = json!(true);
            store.save(&thread).unwrap();
            thread["id"] = json!(id);
            thread["title"] = json!(title);
            thread["isArchived"] = json!(archived);
            thread["items"] = json!([
                {"id":"11111111-1111-4111-8111-111111111111","kind":"user","text":"one"},
                {"id":"22222222-2222-4222-8222-222222222222","kind":"assistant","text":"two"},
                {"id":"33333333-3333-4333-8333-333333333333","kind":"user","text":"three"}
            ]);
            store.save(&thread).unwrap();
        }
        let engine = Arc::new(Mutex::new(Engine::new(store)));
        let server = control::serve(data.join("control.sock"), engine.clone()).unwrap();
        Self {
            _server: server,
            engine,
            directory,
            data,
        }
    }
    fn cli(&self, args: &[&str], current: Option<&str>, body: Option<Value>) -> (i32, Value) {
        let mut command = Command::new(BINARY);
        command
            .args(args)
            .env("COINCIDE_RUST_DATA_DIR", &self.data)
            .env_remove("COINCIDE_THREAD_ID")
            .current_dir(self.directory.path());
        if let Some(current) = current {
            command.env("COINCIDE_THREAD_ID", current);
        }
        run(command, body)
    }
}
fn run(command: Command, body: Option<Value>) -> (i32, Value) {
    run_bytes(command, body.map(|body| serde_json::to_vec(&body).unwrap()))
}
fn run_bytes(mut command: Command, body: Option<Vec<u8>>) -> (i32, Value) {
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
        child.stdin.take().unwrap().write_all(&body).unwrap();
    }
    let output = child.wait_with_output().unwrap();
    let text = String::from_utf8(output.stdout).unwrap();
    let reply = serde_json::from_str(&text).unwrap_or_else(
        |_| json!({"stderr":String::from_utf8_lossy(&output.stderr),"stdout":text}),
    );
    (output.status.code().unwrap(), reply)
}

#[test]
fn cli_resolver_pagination_filters_and_raw_api_remain_scoped() {
    let fixture = Fixture::new();
    let original = fixture.engine.lock().unwrap().store.thread(FIRST).unwrap();
    // Ambiguous UUID prefixes and duplicate exact titles never choose a target.
    for name in ["AAAA", "Exact 界 title", "missing", "this"] {
        assert_eq!(fixture.cli(&["archive", name], None, None).0, 1);
    }
    for current in ["AAAA", "not-a-uuid", "99999999-9999-4999-8999-999999999999"] {
        assert_eq!(fixture.cli(&["archive", "this"], Some(current), None).0, 1);
    }
    assert_eq!(
        fixture.engine.lock().unwrap().store.thread(FIRST).unwrap(),
        original
    );
    let (code, page) = fixture.cli(
        &["read", "this", "--count", "1", "--offset", "1"],
        Some(FIRST),
        None,
    );
    assert_eq!(code, 0);
    assert_eq!(page["result"]["page"], json!({"offset":1,"total":3}));
    assert_eq!(page["result"]["items"][0]["text"], "two");
    assert_eq!(
        fixture.cli(&["read", &FIRST.to_lowercase()], None, None).1["result"]["id"],
        FIRST
    );
    assert_eq!(
        fixture.cli(&["read", "BBBB"], None, None).1["result"]["id"],
        PROJECT
    );
    assert_eq!(
        fixture.cli(&["read", "Archived title"], None, None).1["result"]["id"],
        SECOND
    );
    let chats = fixture.cli(&["threads", "--chats", "--active"], None, None);
    assert_eq!(chats.0, 0);
    assert_eq!(chats.1["result"].as_array().unwrap().len(), 1);
    assert_eq!(chats.1["result"][0]["id"], FIRST);
    let projects = fixture.cli(
        &["threads", "--project", "Synthetic project", "--active"],
        None,
        None,
    );
    assert_eq!(projects.1["result"].as_array().unwrap().len(), 1);
    assert_eq!(projects.1["result"][0]["id"], PROJECT);
    assert_eq!(
        fixture.cli(&["threads", "--running"], None, None).1["result"],
        json!([])
    );
    let raw = fixture.cli(&["api"], None, Some(json!({"id":"raw-correlation","method":"threads.read","params":{"threadId":FIRST,"itemLimit":0}})));
    assert_eq!(raw.0, 0);
    assert_eq!(raw.1["id"], "raw-correlation");
    assert_eq!(raw.1["result"]["items"], json!([]));
    assert_eq!(
        fixture.cli(&["status", "BBBB"], None, None).1["result"]["running"],
        false
    );
    let done = fixture.cli(&["wait", "BBBB", "--timeout", "1"], None, None);
    assert_eq!(done.0, 0);
    assert_eq!(done.1["result"]["state"], "done");
    let literal = fixture.cli(&["draft", "BBBB", "--", "--literal draft"], None, None);
    assert_eq!(literal.0, 0);
    assert_eq!(literal.1["result"]["draft"], "--literal draft");
}

#[test]
fn cli_provider_omits_absent_model_and_preserves_explicit_model() {
    let fixture = Fixture::new();
    let (code, selected) = fixture.cli(&["provider", FIRST, "codex"], None, None);
    assert_eq!(code, 0, "{selected}");
    assert_eq!(selected["result"]["selection"]["provider"], "codex");
    assert_eq!(selected["result"]["selection"]["modelID"], "default");
    let (code, selected) = fixture.cli(
        &["provider", FIRST, "claude", "synthetic-model"],
        None,
        None,
    );
    assert_eq!(code, 0, "{selected}");
    assert_eq!(
        selected["result"]["selection"]["modelID"],
        "synthetic-model"
    );
    assert!(
        fixture.engine.lock().unwrap().store.thread(FIRST).unwrap()["items"]
            .as_array()
            .is_some()
    );
    assert_eq!(
        fixture.cli(&["status"], None, None).1["result"]["running"],
        json!([])
    );
}

#[test]
fn cli_usage_rejects_unknown_duplicate_and_unsupported_options_before_transport() {
    for args in [
        vec!["threads", "--unknown"],
        vec!["read", FIRST, "--count", "1001"],
        vec!["read", FIRST, "--offset", "-1"],
        vec!["wait", FIRST, "--timeout", "NaN"],
        vec!["wait", FIRST, "--timeout", "0"],
        vec!["send", FIRST, "text", "--timeout", "1"],
        vec!["send", FIRST, "text", "--alternate"],
        vec!["threads", "--chats", "--project", "x"],
        vec!["threads", "--active", "--archived"],
        vec!["read", FIRST, "--count", "1", "--count", "2"],
        vec!["file", FIRST, "file.txt", "not-an-integer"],
        vec!["browser", FIRST, "{"],
        vec!["browser", FIRST, "[]"],
        vec!["answer", FIRST, "request", "{"],
        vec!["api", "--wait"],
        vec!["quit", "unexpected"],
        vec!["wait"],
    ] {
        let directory = tempfile::tempdir().unwrap();
        let mut command = Command::new(BINARY);
        command.args(&args).env(
            "COINCIDE_RUST_DATA_DIR",
            directory.path().join("never-created"),
        );
        assert_eq!(run(command, None).0, 2, "{args:?}");
        assert!(!directory.path().join("never-created").exists());
    }
}

#[test]
fn raw_api_json_is_validated_before_data_directory_resolution() {
    for body in [b"{".to_vec(), Vec::new()] {
        let directory = tempfile::tempdir().unwrap();
        let mut command = Command::new(BINARY);
        command
            .arg("api")
            .env_remove("COINCIDE_RUST_DATA_DIR")
            .env_remove("HOME")
            .env_remove("LOCALAPPDATA")
            .current_dir(directory.path());
        let (code, reply) = run_bytes(command, Some(body));
        assert_eq!(
            code, 2,
            "Expected JSON usage error before missing data directory: {reply}"
        );
    }
}

#[cfg(unix)]
#[test]
fn malformed_local_syntax_never_connects_to_control() {
    use std::{fs, os::unix::net::UnixListener};
    let directory = tempfile::Builder::new()
        .prefix("cs-")
        .tempdir_in("/tmp")
        .unwrap();
    let data = directory.path().join("data");
    fs::create_dir(&data).unwrap();
    let listener = UnixListener::bind(data.join("control.sock")).unwrap();
    listener.set_nonblocking(true).unwrap();
    for args in [
        vec!["file", FIRST, "file.txt", "bad"],
        vec!["browser", FIRST, "{"],
        vec!["answer", FIRST, "request", "{"],
    ] {
        let mut command = Command::new(BINARY);
        command.args(&args).env("COINCIDE_RUST_DATA_DIR", &data);
        assert_eq!(run(command, None).0, 2);
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
    }
    let mut command = Command::new(BINARY);
    command.arg("api").env("COINCIDE_RUST_DATA_DIR", &data);
    assert_eq!(run_bytes(command, Some(b"{".to_vec())).0, 2);
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
}

#[cfg(unix)]
mod scripted {
    use super::*;
    use std::fs;
    use std::{
        io::{BufRead, BufReader},
        os::unix::net::UnixListener,
        sync::atomic::{AtomicBool, Ordering},
        thread,
    };
    struct Peer {
        stop: Arc<AtomicBool>,
        worker: Option<thread::JoinHandle<()>>,
    }
    impl Drop for Peer {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            self.worker.take().unwrap().join().unwrap();
        }
    }
    fn wait_scenario(state: &str, send: bool) -> (i32, Value, Vec<String>) {
        let directory = tempfile::Builder::new()
            .prefix("cf-")
            .tempdir_in("/tmp")
            .unwrap();
        let data = directory.path().join("data");
        fs::create_dir(&data).unwrap();
        let listener = UnixListener::bind(data.join("control.sock")).unwrap();
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let methods = Arc::new(Mutex::new(Vec::new()));
        let recorded = methods.clone();
        let state = state.to_owned();
        let peer = Peer {
            stop,
            worker: Some(thread::spawn(move || {
                let mut polls = 0;
                while !stopping.load(Ordering::Relaxed) {
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            stream.set_nonblocking(false).unwrap();
                            stream
                                .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                                .unwrap();
                            let mut line = String::new();
                            BufReader::new(&stream).read_line(&mut line).unwrap();
                            let request: Value = serde_json::from_str(&line).unwrap();
                            let method = request["method"].as_str().unwrap();
                            recorded.lock().unwrap().push(method.to_owned());
                            let result = match method {
                                "threads.resolve_id" => {
                                    assert_eq!(
                                        uuid::Uuid::parse_str(
                                            request["params"]["threadId"].as_str().unwrap()
                                        )
                                        .unwrap(),
                                        uuid::Uuid::parse_str(FIRST).unwrap()
                                    );
                                    json!({"threadId":FIRST})
                                }
                                "threads.list" => {
                                    panic!("Exact-ID wait must never list the library")
                                }
                                "threads.read" => {
                                    let settled = if state == "done" {
                                        polls >= 2
                                    } else {
                                        polls >= 1
                                    };
                                    json!({"id":FIRST,"items":if settled { vec![json!({"kind":"assistant","text":"settled after status"})] } else { vec![] }})
                                }
                                "agent.send" => {
                                    assert_eq!(request["params"]["text"], "synthetic send");
                                    json!({"accepted":true})
                                }
                                "agent.pending" => {
                                    if state == "needsInput" {
                                        json!([{"requestId":"fake-question"}])
                                    } else {
                                        json!([])
                                    }
                                }
                                "app.status" => {
                                    polls += 1;
                                    json!({"running":if state == "done" && polls >= 2 {vec![]} else {vec![FIRST]}})
                                }
                                _ => panic!("Unexpected CLI request {method}"),
                            };
                            writeln!(stream, "{}", json!({"id":request["id"],"result":result}))
                                .unwrap();
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(std::time::Duration::from_millis(1))
                        }
                        Err(e) => panic!("Fake control accept: {e}"),
                    }
                }
            })),
        };
        let mut command = Command::new(BINARY);
        command
            .env("COINCIDE_RUST_DATA_DIR", &data)
            .env_remove("COINCIDE_THREAD_ID");
        if send {
            command.args(["send", FIRST, "synthetic send", "--wait", "--timeout", "1"]);
        } else {
            command.args(["wait", FIRST, "--timeout", "0.03"]);
        }
        let (code, reply) = run(command, None);
        drop(peer);
        let calls = methods.lock().unwrap().clone();
        (code, reply, calls)
    }
    fn scalar_scenario(
        args: &[&str],
        current: Option<&str>,
        resolved: Value,
    ) -> (i32, Value, Vec<String>) {
        const STORED: &str = "aAaA0000-0000-4000-8000-000000000001";
        let directory = tempfile::Builder::new()
            .prefix("ci-")
            .tempdir_in("/tmp")
            .unwrap();
        let data = directory.path().join("data");
        fs::create_dir(&data).unwrap();
        let listener = UnixListener::bind(data.join("control.sock")).unwrap();
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let methods = Arc::new(Mutex::new(Vec::new()));
        let recorded = methods.clone();
        let peer = Peer {
            stop,
            worker: Some(thread::spawn(move || {
                while !stopping.load(Ordering::Relaxed) {
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            stream.set_nonblocking(false).unwrap();
                            stream
                                .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                                .unwrap();
                            stream
                                .set_write_timeout(Some(std::time::Duration::from_secs(2)))
                                .unwrap();
                            let mut line = String::new();
                            BufReader::new(&stream).read_line(&mut line).unwrap();
                            let request: Value = serde_json::from_str(&line).unwrap();
                            let method = request["method"].as_str().unwrap();
                            recorded.lock().unwrap().push(method.to_owned());
                            let response = match method {
                                "threads.resolve_id" => {
                                    assert_eq!(
                                        uuid::Uuid::parse_str(
                                            request["params"]["threadId"].as_str().unwrap()
                                        )
                                        .unwrap(),
                                        uuid::Uuid::parse_str(FIRST).unwrap()
                                    );
                                    if resolved.get("error").is_some() {
                                        json!({"id":request["id"],"error":resolved["error"]})
                                    } else {
                                        json!({"id":request["id"],"result":resolved})
                                    }
                                }
                                // This represents a library that exceeds the control frame
                                // cap. Exact-ID and this paths must never request it.
                                "threads.list" => {
                                    json!({"id":request["id"],"result":[{"id":FIRST,"title":"x".repeat(4*1024*1024+1)}]})
                                }
                                "threads.read" | "agent.stop" | "agent.send" => {
                                    assert_eq!(request["params"]["threadId"], STORED);
                                    if method == "agent.send" {
                                        assert_eq!(request["params"]["text"], "synthetic only");
                                    }
                                    json!({"id":request["id"],"result":{"id":STORED,"items":[],"accepted":true}})
                                }
                                _ => panic!("Unexpected scalar resolver request {method}"),
                            };
                            // A broken client attempting the oversized list can close
                            // before this trap reply finishes. Still record the attempt.
                            let _ = writeln!(stream, "{response}");
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(std::time::Duration::from_millis(1))
                        }
                        Err(e) => panic!("Scalar fake peer accept: {e}"),
                    }
                }
            })),
        };
        let mut command = Command::new(BINARY);
        command
            .args(args)
            .env("COINCIDE_RUST_DATA_DIR", &data)
            .env_remove("COINCIDE_THREAD_ID");
        if let Some(current) = current {
            command.env("COINCIDE_THREAD_ID", current);
        }
        let (code, reply) = run(command, None);
        drop(peer);
        let calls = methods.lock().unwrap().clone();
        (code, reply, calls)
    }

    #[test]
    fn scalar_exact_and_current_resolution_avoids_large_library_and_validates_identity() {
        const STORED: &str = "aAaA0000-0000-4000-8000-000000000001";
        for args in [
            vec!["read", FIRST],
            vec!["read", "this"],
            vec!["stop", FIRST],
            vec!["send", FIRST, "synthetic only"],
        ] {
            let (code, reply, calls) =
                scalar_scenario(&args, Some(FIRST), json!({"threadId":STORED}));
            assert_eq!(code, 0, "{reply}");
            assert_eq!(calls[0], "threads.resolve_id");
            assert!(!calls.iter().any(|m| m == "threads.list"));
            assert_eq!(reply["result"]["id"], STORED);
        }
        for response in [
            json!({"threadId":SECOND}),
            json!({"id":FIRST}),
            json!(FIRST),
            json!({"threadId":1}),
            json!({"threadId":FIRST,"extra":true}),
            json!({"error":{"message":"missing or ambiguous"}}),
        ] {
            let (code, _, calls) = scalar_scenario(&["read", FIRST], None, response);
            assert_eq!(code, 1);
            assert_eq!(calls, vec!["threads.resolve_id"]);
        }
        for current in [None, Some("AAAA"), Some("malformed")] {
            let (code, _, calls) =
                scalar_scenario(&["read", "this"], current, json!({"threadId":STORED}));
            assert_eq!(code, 1);
            assert!(calls.is_empty());
        }
    }

    #[test]
    fn fake_control_polling_distinguishes_done_input_timeout_and_submits_once() {
        for (state, code) in [("done", 0), ("needsInput", 3), ("timedOut", 4)] {
            let (exit, reply, calls) = wait_scenario(state, state == "done");
            assert_eq!(exit, code, "{reply}");
            assert_eq!(reply["result"]["state"], state);
            assert_eq!(
                reply["result"]["transcript"]["items"][0]["text"],
                "settled after status"
            );
            assert_eq!(
                calls.iter().filter(|m| m.as_str() == "agent.send").count(),
                usize::from(state == "done")
            );
            assert!(calls.iter().filter(|m| m.as_str() == "app.status").count() >= 1);
        }
    }
}
