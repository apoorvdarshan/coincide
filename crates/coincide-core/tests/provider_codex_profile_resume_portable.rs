//! A real Rust fixture executable works on Windows, Linux and macOS without a
//! shell, Python, script launcher, credentials or platform-skipped assertions.
use coincide_core::{
    api::Engine,
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
    let reply = engine.dispatch(json!({"id":1,"method":method,"params":params}));
    assert!(reply.get("error").is_none(), "{method}: {reply}");
    reply["result"].clone()
}
fn wait(engine: &mut Engine, description: &str, mut condition: impl FnMut(&mut Engine) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while !condition(engine) {
        assert!(Instant::now() < deadline, "Timed out: {description}");
        engine.poll();
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn refresh(engine: &mut Engine, id: &str) {
    let thread = engine.store.thread(id).unwrap();
    let request = call(
        engine,
        "providers.codex.profiles.models.refresh",
        json!({"threadId":id,"accountId":thread["selection"]["accountID"],"expectedSelection":thread["selection"]}),
    );
    let mut ready = Value::Null;
    wait(engine, "fresh authenticated catalog", |engine| {
        let response = call(
            engine,
            "providers.codex.profiles.models.status",
            json!({"threadId":id,"accountId":thread["selection"]["accountID"],"requestId":request["requestId"]}),
        );
        if response["state"] == "loading" {
            return false;
        }
        assert_eq!(response["state"], "ready", "{response}");
        ready = response;
        true
    });
    call(
        engine,
        "providers.codex.profiles.models.select",
        json!({"threadId":id,"accountId":thread["selection"]["accountID"],"requestId":ready["requestId"],"expectedSelection":thread["selection"],"expectedAccessMode":thread["accessMode"],"expectedInteractionMode":thread["interactionMode"],"model":"portable-model","effort":null,"speed":null,"accessMode":"approval"}),
    );
}
fn phase(root: &Path, phase: &str) {
    let dbpath = root.join("state/state.sqlite");
    let mut engine = Engine::new(Store::open(&dbpath).unwrap());
    let metadata = root.join("fixture.json");
    let id = if phase == "seed" {
        let project = call(
            &mut engine,
            "projects.create",
            json!({"path":root,"name":"Portable owned continuation"}),
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
            json!({"name":"Portable private fixture"}),
        );
        call(
            &mut engine,
            "providers.codex.profiles.select",
            json!({"threadId":id,"accountId":account["id"],"expectedSelection":thread["selection"]}),
        );
        fs::write(
            &metadata,
            serde_json::to_vec(&json!({"id":id,"expected":"thread/start","turn":"seed only"}))
                .unwrap(),
        )
        .unwrap();
        id
    } else {
        let old: Value = serde_json::from_slice(&fs::read(&metadata).unwrap()).unwrap();
        let id = text(&old, "id");
        engine.set_active_thread(Some(id.clone())).unwrap();
        let before = engine.store.thread(&id).unwrap();
        assert!(engine.dispatch(json!({"method":"agent.send","params":{"threadId":id,"text":"must refuse before fresh catalog"}})).get("error").is_some());
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        fs::write(&metadata,serde_json::to_vec(&json!({"id":id,"native":old["native"],"expected":"thread/resume","turn":"new prompt after separate process restart"})).unwrap()).unwrap();
        id
    };
    refresh(&mut engine, &id);
    let expected: Value = serde_json::from_slice(&fs::read(&metadata).unwrap()).unwrap();
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":expected["turn"]}),
    );
    // Deliberately request clean shutdown as soon as the semantic turn retires,
    // before waiting for provider-thread return. Catalog revocation must wait
    // for exact join and durable mint rather than invalidate the pending proof.
    wait(&mut engine, "semantic turn completion", |engine| {
        call(engine, "app.status", json!({}))["running"]
            .as_array()
            .unwrap()
            .is_empty()
    });
    engine.freeze_admissions();
    engine.request_core_owner_shutdown().unwrap();
    wait(&mut engine, "all actual owners drained", |engine| {
        engine
            .poll_core_owner_shutdown()
            .unwrap()
            .rust_owners_drained()
    });
    let saved = engine.store.thread(&id).unwrap();
    assert!(
        saved["items"]
            .as_array()
            .unwrap()
            .iter()
            .all(|item| item["kind"] != "error"),
        "{saved}"
    );
    let native = text(&saved["sessions"]["codex"], "sessionID");
    assert!(!native.is_empty());
    if phase == "seed" {
        fs::write(
            &metadata,
            serde_json::to_vec(&json!({"id":id,"native":native})).unwrap(),
        )
        .unwrap();
    } else {
        assert_eq!(native, expected["native"]);
        assert_eq!(engine.provider_workers_status().returned, 1);
    }
    engine.close_store_after_core_shutdown().unwrap();
}
fn provider() {
    let home = PathBuf::from(std::env::var_os("CODEX_HOME").expect("private home"));
    let root = home.ancestors().nth(4).unwrap();
    for key in [
        "OPENAI_API_KEY",
        "CODEX_API_KEY",
        "CODEX_ACCESS_TOKEN",
        "OPENAI_BASE_URL",
        "COINCIDE_PORTABLE_PHASE",
    ] {
        assert!(
            std::env::var_os(key).is_none(),
            "Ambient provider variable {key}"
        );
    }
    let args = std::env::args().collect::<Vec<_>>();
    assert!(
        args.iter()
            .any(|arg| arg == "forced_login_method=\"chatgpt\"")
    );
    let config: Value =
        serde_json::from_slice(&fs::read(root.join("fixture.json")).unwrap()).unwrap();
    let mut native = String::new();
    let read = io::stdin().lock().lines();
    for line in read {
        let frame: Value = serde_json::from_str(&line.unwrap()).unwrap();
        let method = frame["method"].as_str().unwrap();
        let result = match method {
            "initialize" => json!({}),
            "initialized" => continue,
            "account/read" => json!({"requiresOpenaiAuth":true,"account":{"type":"chatgpt"}}),
            "model/list" => {
                json!({"data":[{"model":"portable-model","supportedReasoningEfforts":[{"reasoningEffort":"high"}]}],"nextCursor":null})
            }
            "thread/start" | "thread/resume" => {
                assert_eq!(
                    method, config["expected"],
                    "No start-or-resume alternative is accepted"
                );
                native = if method == "thread/start" {
                    let value = format!("portable-{}", uuid::Uuid::new_v4());
                    fs::write(root.join("native-session"), &value).unwrap();
                    value
                } else {
                    let value = fs::read_to_string(root.join("native-session")).unwrap();
                    assert_eq!(frame["params"]["threadId"], value);
                    assert_eq!(config["native"], value);
                    value
                };
                json!({"thread":{"id":native},"model":"portable-model"})
            }
            "turn/start" => {
                assert_eq!(frame["params"]["threadId"], native);
                assert_eq!(
                    frame["params"]["input"][0]["text"], config["turn"],
                    "Native resume must dispatch only the new input"
                );
                println!(
                    "{}",
                    json!({"id":frame["id"],"result":{"turn":{"id":"portable-turn"}}})
                );
                println!(
                    "{}",
                    json!({"method":"turn/completed","params":{"threadId":native,"turn":{"id":"portable-turn","status":"completed"}}})
                );
                io::stdout().flush().unwrap();
                continue;
            }
            _ => panic!("Unexpected fixture protocol method {method}"),
        };
        println!("{}", json!({"id":frame["id"],"result":result}));
        io::stdout().flush().unwrap();
    }
}
fn main() {
    if std::env::args().nth(1).as_deref() == Some("-c") {
        provider();
        return;
    }
    if let Some(phase_name) = std::env::var_os("COINCIDE_PORTABLE_PHASE") {
        phase(
            &PathBuf::from(std::env::var_os("COINCIDE_PORTABLE_ROOT").unwrap()),
            phase_name.to_str().unwrap(),
        );
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    }
    let root = dir.path().canonicalize().unwrap();
    let executable = std::env::current_exe().unwrap();
    for stage in ["seed", "resume"] {
        let mut command = Command::new(&executable);
        command.env_clear();
        for name in ["PATH", "SystemRoot", "SYSTEMROOT", "WINDIR", "TMP", "TEMP"] {
            if let Some(value) = std::env::var_os(name) {
                command.env(name, value);
            }
        }
        let output = command
            .env("HOME", &root)
            .env("COINCIDE_PORTABLE_ROOT", &root)
            .env("COINCIDE_PORTABLE_PHASE", stage)
            .env("COINCIDE_CODEX_EXECUTABLE", &executable)
            .env("OPENAI_API_KEY", "synthetic-must-not-inherit")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{stage}: {} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    println!(
        "portable native continuation: two fresh OS processes, exact resume ID, only new input, saved/joined shutdown: PASS"
    );
}
