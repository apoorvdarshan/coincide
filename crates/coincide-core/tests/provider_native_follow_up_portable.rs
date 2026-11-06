//! Actual owned fake subprocesses only; no shell, credentials or live provider.
use coincide_core::{
    api::{Engine, NativeFollowUpStatus},
    composer_follow_up::{Behavior, Dispatch},
    native_file,
    store::{Store, text},
};
use serde_json::{Value, json};
use std::{
    fs,
    io::{self, BufRead, Write},
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant},
};
fn call(engine: &mut Engine, method: &str, params: Value) -> Value {
    let reply = engine.dispatch(json!({"method":method,"params":params}));
    assert!(reply.get("error").is_none(), "{method}: {reply}");
    reply["result"].clone()
}
fn wait(engine: &mut Engine, label: &str, mut predicate: impl FnMut(&mut Engine) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while !predicate(engine) {
        assert!(Instant::now() < deadline, "{label}");
        engine.poll();
        std::thread::yield_now();
    }
}
fn refresh_named(engine: &mut Engine, id: &str, account: &Value) {
    let thread = engine.store.thread(id).unwrap();
    let request = call(
        engine,
        "providers.codex.profiles.models.refresh",
        json!({"threadId":id,"accountId":account["id"],"expectedSelection":thread["selection"]}),
    );
    let mut ready = Value::Null;
    wait(engine, "authenticated fake catalog", |engine| {
        ready = call(
            engine,
            "providers.codex.profiles.models.status",
            json!({"threadId":id,"accountId":account["id"],"requestId":request["requestId"]}),
        );
        ready["state"] != "loading"
    });
    assert_eq!(ready["state"], "ready");
    call(
        engine,
        "providers.codex.profiles.models.select",
        json!({"threadId":id,"accountId":account["id"],"requestId":request["requestId"],"expectedSelection":thread["selection"],"expectedAccessMode":thread["accessMode"],"expectedInteractionMode":thread["interactionMode"],"model":"synthetic-follow-up","effort":null,"speed":null,"accessMode":"approval"}),
    );
}
fn fixture(root: &Path) {
    let mut engine = Engine::new(Store::open(&root.join("state/state.sqlite")).unwrap());
    let project = call(
        &mut engine,
        "projects.create",
        json!({"path":root,"name":"Synthetic native follow-ups"}),
    );
    let thread = call(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    );
    let id = text(&thread, "id");
    engine.set_active_thread(Some(id.clone())).unwrap();
    let account = call(
        &mut engine,
        "providers.codex.profiles.create",
        json!({"name":"Synthetic follow-up account"}),
    );
    call(
        &mut engine,
        "providers.codex.profiles.select",
        json!({"threadId":id,"accountId":account["id"],"expectedSelection":thread["selection"]}),
    );
    refresh_named(&mut engine, &id, &account);
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"synthetic first turn"}),
    );
    wait(&mut engine, "first fake turn acknowledged", |_| {
        root.join("first-ack").is_file()
    });
    call(
        &mut engine,
        "threads.patch",
        json!({"threadId":id,"patch":{"draft":"synthetic interrupt message"}}),
    );
    let source = engine.store.thread(&id).unwrap();
    let source = engine
        .choose_native_follow_up(&source, Behavior::Interrupt)
        .unwrap();
    let ticket = engine.send_native_follow_up(&source, false).unwrap();
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Pending
    );
    wait(
        &mut engine,
        "actual stopped-worker return and replacement admission",
        |engine| engine.native_follow_up_status(&ticket).unwrap() != NativeFollowUpStatus::Pending,
    );
    assert_eq!(
        engine.native_follow_up_status(&ticket).unwrap(),
        NativeFollowUpStatus::Delivered {
            dispatch: Dispatch::Interrupt,
            draft_cleared: true
        }
    );
    engine.collect_native_follow_up(ticket).unwrap();
    wait(
        &mut engine,
        "replacement turn saved and actual worker returned",
        |engine| {
            call(engine, "app.status", json!({}))["running"]
                .as_array()
                .unwrap()
                .is_empty()
                && engine.provider_workers_status().running == 0
        },
    );
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], "");
    assert_eq!(saved["followUpBehavior"], "interrupt");
    assert_eq!(
        saved["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| item["kind"] == "user" && item["text"] == "synthetic interrupt message")
            .count(),
        1
    );
    assert_eq!(
        saved["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| item["kind"] == "assistant"
                && item["text"] == "synthetic replacement completed")
            .count(),
        1
    );
    let wire: Vec<Value> = fs::read_to_string(root.join("wire.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let turns: Vec<_> = wire
        .iter()
        .filter(|frame| frame["method"] == "turn/start")
        .collect();
    assert_eq!(turns.len(), 2);
    assert_eq!(
        turns[0]["params"]["input"][0]["text"],
        "synthetic first turn"
    );
    let replacement = turns[1]["params"]["input"][0]["text"].as_str().unwrap();
    assert_eq!(replacement.matches("synthetic first turn").count(), 1);
    assert_eq!(
        replacement.matches("synthetic interrupt message").count(),
        1
    );
    assert_eq!(
        wire.iter()
            .filter(|frame| frame["method"] == "thread/start")
            .count(),
        2
    );
    assert!(
        !wire.iter().any(|frame| frame["method"] == "thread/resume"),
        "Interrupted native sessions must start fresh with the full prefix"
    );
    let workers = engine.provider_workers_status();
    assert_eq!(workers.returned, 2);
    assert_eq!(workers.panicked, 0);
    assert_eq!(workers.unclassified, 0);
    let first_native = coincide_core::agent::provider_session(&saved, "codex").unwrap();
    fs::write(root.join("allowed-resume"), &first_native).unwrap();
    let other = call(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    );
    let other_id = text(&other, "id");
    engine.set_active_thread(Some(other_id.clone())).unwrap();
    call(
        &mut engine,
        "agent.select",
        json!({"threadId":other_id,"provider":"codex","model":"default"}),
    );
    let other = engine.store.thread(&other_id).unwrap();
    call(
        &mut engine,
        "providers.codex.profiles.select",
        json!({"threadId":other_id,"accountId":account["id"],"expectedSelection":other["selection"]}),
    );
    refresh_named(&mut engine, &other_id, &account);
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":other_id,"text":"synthetic uncertain primary"}),
    );
    wait(&mut engine, "uncertain primary acknowledged", |_| {
        root.join("uncertain-ack").is_file()
    });
    call(
        &mut engine,
        "threads.patch",
        json!({"threadId":other_id,"patch":{"draft":"synthetic unacknowledged steering"}}),
    );
    let other = engine.store.thread(&other_id).unwrap();
    let other = engine
        .choose_native_follow_up(&other, Behavior::Steer)
        .unwrap();
    wait(
        &mut engine,
        "actual acknowledged private steering turn",
        |engine| {
            engine
                .native_follow_up_dispatch(&other, false)
                .is_ok_and(|dispatch| dispatch == Dispatch::Steer)
        },
    );
    let uncertain = engine.send_native_follow_up(&other, false).unwrap();
    // Do NOT poll Engine until the fake completed its primary and the owned
    // Rust worker actually returned. This exercises a lost steering ACK whose
    // collector runs after primary completion, never just a mocked status.
    let deadline = Instant::now() + Duration::from_secs(15);
    while engine.provider_workers_status().running != 0 {
        assert!(Instant::now() < deadline, "unknown fake did not return");
        std::thread::yield_now();
    }
    assert!(root.join("uncertain-completed").is_file());
    engine.poll();
    assert!(matches!(
        engine.native_follow_up_status(&uncertain).unwrap(),
        NativeFollowUpStatus::Retained(_)
    ));
    assert_eq!(
        engine.store.thread(&other_id).unwrap()["draft"],
        "synthetic unacknowledged steering"
    );
    engine.collect_native_follow_up(uncertain).unwrap();
    assert_eq!(engine.provider_workers_status().returned, 3);
    engine.request_core_owner_shutdown().unwrap();
    wait(&mut engine, "owned shutdown", |engine| {
        engine
            .poll_core_owner_shutdown()
            .is_ok_and(|status| status.rust_owners_drained())
    });
    engine.close_store_after_core_shutdown().unwrap();
    drop(engine);
    // Cold owner must never resume the uncertain native context. An unrelated
    // completed thread retains its independent private receipt and exact ID.
    let mut engine = Engine::new(Store::open(&root.join("state/state.sqlite")).unwrap());
    engine.set_active_thread(Some(other_id.clone())).unwrap();
    refresh_named(&mut engine, &other_id, &account);
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":other_id,"text":"synthetic unacknowledged steering"}),
    );
    wait(
        &mut engine,
        "cold uncertain context fresh fallback",
        |engine| {
            call(engine, "app.status", json!({}))["running"]
                .as_array()
                .unwrap()
                .is_empty()
                && engine.provider_workers_status().running == 0
        },
    );
    engine.set_active_thread(Some(id.clone())).unwrap();
    refresh_named(&mut engine, &id, &account);
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"synthetic unrelated original resume"}),
    );
    wait(&mut engine, "unrelated original continuation", |engine| {
        call(engine, "app.status", json!({}))["running"]
            .as_array()
            .unwrap()
            .is_empty()
            && engine.provider_workers_status().running == 0
    });
    assert_eq!(
        coincide_core::agent::provider_session(&engine.store.thread(&id).unwrap(), "codex")
            .as_deref(),
        Some(first_native.as_str())
    );
    let wire: Vec<Value> = fs::read_to_string(root.join("wire.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(
        wire.iter()
            .filter(|frame| frame["method"] == "thread/start")
            .count(),
        4
    );
    let resumes: Vec<_> = wire
        .iter()
        .filter(|frame| frame["method"] == "thread/resume")
        .collect();
    assert_eq!(resumes.len(), 1);
    assert_eq!(resumes[0]["params"]["threadId"], first_native);
    let turns: Vec<_> = wire
        .iter()
        .filter(|frame| frame["method"] == "turn/start")
        .collect();
    assert_eq!(turns.len(), 5);
    let retry = turns[3]["params"]["input"][0]["text"].as_str().unwrap();
    assert_eq!(retry.matches("synthetic uncertain primary").count(), 1);
    assert_eq!(
        retry.matches("synthetic unacknowledged steering").count(),
        1
    );
    assert_eq!(
        turns[4]["params"]["input"][0]["text"],
        "synthetic unrelated original resume"
    );
    assert_eq!(engine.provider_workers_status().returned, 2);
    engine.request_core_owner_shutdown().unwrap();
    wait(&mut engine, "cold owned shutdown", |engine| {
        engine
            .poll_core_owner_shutdown()
            .is_ok_and(|status| status.rust_owners_drained())
    });
    engine.close_store_after_core_shutdown().unwrap();
    println!(
        "Actual fake follow-ups: interrupt full prefix once; ACK-lost primary finalized before polling; cold uncertain context fresh; unrelated exact original resume; five saved/joined provider returns PASS"
    );
}
fn provider() {
    let home = PathBuf::from(std::env::var_os("CODEX_HOME").expect("isolated named home"));
    let root = home.ancestors().nth(4).unwrap();
    for key in [
        "OPENAI_API_KEY",
        "CODEX_API_KEY",
        "CODEX_ACCESS_TOKEN",
        "COINCIDE_FOLLOW_UP_FIXTURE",
    ] {
        assert!(std::env::var_os(key).is_none());
    }
    let mut native = String::new();
    let mut first = false;
    let mut uncertain = false;
    for line in io::stdin().lock().lines() {
        let frame: Value = serde_json::from_str(&line.unwrap()).unwrap();
        if frame.get("id").is_none() {
            continue;
        }
        let method = frame["method"].as_str().unwrap();
        let mut wire = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(root.join("wire.jsonl"))
            .unwrap();
        writeln!(wire, "{frame}").unwrap();
        drop(wire);
        let result = match method {
            "initialize" => json!({}),
            "account/read" => {
                json!({"requiresOpenaiAuth":true,"account":{"type":"chatgpt","email":"synthetic@example.invalid","planType":"plus"}})
            }
            "model/list" => json!({"data":[{"model":"synthetic-follow-up"}],"nextCursor":null}),
            "thread/start" => {
                native = format!("synthetic-{}", uuid::Uuid::new_v4());
                json!({"thread":{"id":native},"model":"synthetic-follow-up"})
            }
            "thread/resume" => {
                native = fs::read_to_string(root.join("allowed-resume")).unwrap();
                assert_eq!(
                    frame["params"]["threadId"], native,
                    "Only the unrelated proven original may resume"
                );
                json!({"thread":{"id":native},"model":"synthetic-follow-up"})
            }
            "turn/steer" => {
                assert!(uncertain);
                assert_eq!(
                    frame["params"]["input"][0]["text"],
                    "synthetic unacknowledged steering"
                );
                println!(
                    "{}",
                    json!({"method":"turn/completed","params":{"threadId":native,"turn":{"id":"synthetic-turn","status":"completed"}}})
                );
                io::stdout().flush().unwrap();
                fs::write(root.join("uncertain-completed"), b"synthetic").unwrap();
                return; // Deliberately lose the steering ACK.
            }
            "turn/start" => {
                uncertain = frame["params"]["input"][0]["text"] == "synthetic uncertain primary";
                first = frame["params"]["input"][0]["text"] == "synthetic first turn";
                println!(
                    "{}",
                    json!({"id":frame["id"],"result":{"turn":{"id":"synthetic-turn"}}})
                );
                io::stdout().flush().unwrap();
                if first {
                    fs::write(root.join("first-ack"), b"synthetic").unwrap();
                } else if uncertain {
                    fs::write(root.join("uncertain-ack"), b"synthetic").unwrap();
                } else {
                    println!(
                        "{}",
                        json!({"method":"item/completed","params":{"threadId":native,"turnId":"synthetic-turn","item":{"id":"synthetic-response","type":"agentMessage","text":"synthetic replacement completed"}}})
                    );
                    println!(
                        "{}",
                        json!({"method":"turn/completed","params":{"threadId":native,"turn":{"id":"synthetic-turn","status":"completed"}}})
                    );
                    io::stdout().flush().unwrap();
                }
                continue;
            }
            "turn/interrupt" => {
                assert!(first);
                json!({})
            }
            _ => panic!("Unexpected synthetic protocol method {method}"),
        };
        println!("{}", json!({"id":frame["id"],"result":result}));
        io::stdout().flush().unwrap();
        if method == "turn/interrupt" {
            return;
        }
    }
}
fn main() {
    if matches!(
        std::env::args().nth(1).as_deref(),
        Some("--version" | "version")
    ) {
        println!("synthetic-follow-up 1");
        return;
    }
    if matches!(
        std::env::args().nth(1).as_deref(),
        Some("-c" | "app-server")
    ) {
        provider();
        return;
    }
    if let Some(root) = std::env::var_os("COINCIDE_FOLLOW_UP_FIXTURE") {
        fixture(Path::new(&root));
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("private");
    native_file::private_directory(&root).unwrap();
    let executable = std::env::current_exe().unwrap();
    let mut command = Command::new(&executable);
    command.env_clear();
    for name in ["SystemRoot", "WINDIR", "COMSPEC", "PATH"] {
        if let Some(value) = std::env::var_os(name) {
            command.env(name, value);
        }
    }
    command
        .env("HOME", &root)
        .env("USERPROFILE", &root)
        .env("TMPDIR", &root)
        .env("TEMP", &root)
        .env("TMP", &root)
        .env("COINCIDE_FOLLOW_UP_FIXTURE", &root)
        .env("COINCIDE_CODEX_EXECUTABLE", &executable);
    for provider in ["CLAUDE", "CURSOR", "GROK", "OPENCODE", "ANTIGRAVITY"] {
        command.env(
            format!("COINCIDE_{provider}_EXECUTABLE"),
            root.join(format!("denied-{provider}")),
        );
    }
    let output = command.output().unwrap();
    if !output.status.success() {
        let retained = dir.keep();
        panic!(
            "Private synthetic fixture retained at {}: {} {}",
            retained.display(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    print!("{}", String::from_utf8_lossy(&output.stdout));
}
