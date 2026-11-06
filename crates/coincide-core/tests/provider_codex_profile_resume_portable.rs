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
    refresh_account_catalog(engine, id, true);
}
fn refresh_account_catalog(engine: &mut Engine, id: &str, select_explicit_model: bool) {
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
    if !select_explicit_model {
        return;
    }
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
fn ordinary_choice(
    engine: &mut Engine,
    id: &str,
    provider: &str,
    account: Option<&str>,
    warmup: bool,
) -> Value {
    let source = engine.store.thread(id).unwrap();
    let expected = [
        "id",
        "draft",
        "selection",
        "accessMode",
        "interactionMode",
        "rustDraftImages",
        "draftContext",
    ]
    .into_iter()
    .map(|field| (field.to_owned(), source[field].clone()))
    .collect::<serde_json::Map<_, _>>();
    let mut params = json!({"threadId":id,"provider":provider,"expected":expected});
    if let Some(account) = account {
        params["accountId"] = if account == "default" {
            Value::Null
        } else {
            json!(account)
        };
    }
    if warmup {
        params["restoreCurrent"] = json!(true);
    }
    let mut result = call(engine, "agent.provider.select", params.clone());
    wait(
        engine,
        "ordinary authenticated provider/account selection",
        |engine| {
            if result["pending"] != true {
                return true;
            }
            params["restoreRequestId"] = result["requestId"].clone();
            result = call(engine, "agent.provider.select", params.clone());
            result["pending"] != true
        },
    );
    if provider == "codex" {
        assert_eq!(result["authenticationChecked"], true);
    }
    if warmup {
        assert_eq!(result["selectionUnchanged"], true);
        assert_eq!(engine.store.thread(id).unwrap(), source);
    }
    result
}
fn slots_phase(root: &Path, phase: &str) {
    let seed = phase.ends_with("-seed");
    let ordinary = phase.starts_with("ordinary-");
    let explicit = phase.starts_with("ordinary-explicit-");
    let mut engine = Engine::new(Store::open(&root.join("state/state.sqlite")).unwrap());
    let metadata = root.join("fixture.json");
    let saved_path = root.join("slot-fixture.json");
    let (id, a, b) = if seed {
        let project = call(
            &mut engine,
            "projects.create",
            json!({"path":root,"name":"Private account slots"}),
        );
        let thread = call(
            &mut engine,
            "threads.create",
            json!({"projectId":project["id"]}),
        );
        let id = text(&thread, "id");
        engine.set_active_thread(Some(id.clone())).unwrap();
        let a = call(
            &mut engine,
            "providers.codex.profiles.create",
            json!({"name":"A"}),
        );
        let b = call(
            &mut engine,
            "providers.codex.profiles.create",
            json!({"name":"B"}),
        );
        (id, text(&a, "id"), text(&b, "id"))
    } else {
        let saved: Value = serde_json::from_slice(&fs::read(&saved_path).unwrap()).unwrap();
        (text(&saved, "id"), text(&saved, "a"), text(&saved, "b"))
    };
    engine.set_active_thread(Some(id.clone())).unwrap();
    let choose = |engine: &mut Engine, account: &str| {
        let thread = engine.store.thread(&id).unwrap();
        if ordinary {
            ordinary_choice(engine, &id, "codex", Some(account), false);
            if explicit && engine.store.thread(&id).unwrap()["selection"]["modelID"] == "default" {
                // The actual user's explicit model choice is made once. Return
                // selections use the ordinary authenticated restoration path.
                refresh(engine, &id);
            }
            if !explicit && !root.join(format!("native-session-{account}")).exists() {
                let selected = engine.store.thread(&id).unwrap();
                call(
                    engine,
                    "providers.codex.profiles.models.select",
                    json!({"threadId":id,"accountId":account,"expectedSelection":selected["selection"],"expectedAccessMode":selected["accessMode"],"expectedInteractionMode":selected["interactionMode"],"model":"default","effort":null,"speed":null,"accessMode":"approval"}),
                );
            }
            assert_eq!(
                engine.store.thread(&id).unwrap()["selection"]["modelID"],
                if explicit {
                    json!("portable-model")
                } else {
                    json!("default")
                }
            );
        } else {
            call(
                engine,
                "providers.codex.profiles.select",
                json!({"threadId":id,"accountId":account,"expectedSelection":thread["selection"]}),
            );
            refresh_account_catalog(engine, &id, false);
        }
    };
    let turn = |engine: &mut Engine,
                account: &str,
                request: &str,
                expected_method: &str,
                expected_native: Option<&str>,
                outgoing: &str|
     -> String {
        fs::write(&metadata,serde_json::to_vec(&json!({"expected":expected_method,"native":expected_native,"turn":outgoing,"account":account})).unwrap()).unwrap();
        call(engine, "agent.send", json!({"threadId":id,"text":request}));
        wait(engine, "slot saved and actual joined", |engine| {
            call(engine, "app.status", json!({}))["running"]
                .as_array()
                .unwrap()
                .is_empty()
                && engine.provider_workers_status().running == 0
        });
        // Poll once after the worker observer reports Returned: the registry
        // must mint only after that observation and final successful save.
        engine.poll();
        let thread = engine.store.thread(&id).unwrap();
        assert!(
            thread["items"]
                .as_array()
                .unwrap()
                .iter()
                .all(|item| item["kind"] != "error"),
            "{thread}"
        );
        let native = text(&thread["sessions"]["codex"], "sessionID");
        if let Some(expected) = expected_native {
            assert_eq!(native, expected);
        }
        native
    };
    if seed {
        fs::write(&metadata, b"{}").unwrap();
        choose(&mut engine, &a);
        let selection_a = engine.store.thread(&id).unwrap()["selection"].clone();
        let native_a = turn(&mut engine, &a, "A first", "thread/start", None, "A first");
        if ordinary {
            ordinary_choice(&mut engine, &id, "codex", None, true);
        }

        choose(&mut engine, &b);
        let selection_b = engine.store.thread(&id).unwrap()["selection"].clone();
        let native_b = turn(
            &mut engine,
            &b,
            "B first",
            "thread/start",
            None,
            "Earlier conversation context (historical messages, not a new user request):\n\nuser: A first\n\nCurrent user request:\nB first",
        );
        assert_ne!(native_a, native_b);
        choose(&mut engine, &a);
        assert_eq!(
            engine.store.thread(&id).unwrap()["selection"],
            selection_a,
            "A return preserves exact Automatic option presence despite reported high default"
        );
        turn(
            &mut engine,
            &a,
            "A second",
            "thread/resume",
            Some(&native_a),
            "Earlier conversation context (historical messages, not a new user request):\n\nuser: B first\n\nCurrent user request:\nA second",
        );
        if ordinary {
            let current = engine.store.thread(&id).unwrap();
            let other = call(
                &mut engine,
                "threads.create",
                json!({"projectId":current["projectID"]}),
            );
            call(&mut engine, "threads.open", json!({"threadId":other["id"]}));
            call(&mut engine, "threads.open", json!({"threadId":id}));
            assert_eq!(engine.active_thread(), Some(id.as_str()));
            // Provider buttons/slash commands share this exact owner API.
            ordinary_choice(&mut engine, &id, "claude", None, false);
            choose(&mut engine, &a);
            let default_account =
                ordinary_choice(&mut engine, &id, "codex", Some("default"), false);
            assert_eq!(
                default_account["model"], "default",
                "A remembered default-account tuple must remain Provider default"
            );
            choose(&mut engine, &a);
        }
        choose(&mut engine, &b);
        assert_eq!(engine.store.thread(&id).unwrap()["selection"], selection_b);
        turn(
            &mut engine,
            &b,
            "B second",
            "thread/resume",
            Some(&native_b),
            "Earlier conversation context (historical messages, not a new user request):\n\nuser: A second\n\nCurrent user request:\nB second",
        );
        choose(&mut engine, &a);
        assert_eq!(engine.store.thread(&id).unwrap()["selection"], selection_a);
        fs::write(
            &saved_path,
            serde_json::to_vec(&json!({"id":id,"a":a,"b":b,"nativeA":native_a,"nativeB":native_b,"selectionA":selection_a}))
                .unwrap(),
        )
        .unwrap();
    } else {
        let saved: Value = serde_json::from_slice(&fs::read(&saved_path).unwrap()).unwrap();
        let before = engine.store.thread(&id).unwrap();
        assert_eq!(before["selection"], saved["selectionA"]);
        let refused=engine.dispatch(json!({"method":"agent.send","params":{"threadId":id,"text":"must wait without consuming default-model receipt"}}));
        assert!(
            refused.get("error").is_some(),
            "A cold account receipt requires current private admission"
        );
        assert_eq!(
            engine.store.thread(&id).unwrap(),
            before,
            "Waiting cannot append draft/history or change selection/session metadata"
        );
        assert_eq!(
            engine.provider_workers_status().running,
            0,
            "Missing admission cannot launch a provider"
        );
        if ordinary {
            ordinary_choice(&mut engine, &id, "codex", None, true);
        } else {
            refresh_account_catalog(&mut engine, &id, false);
        }
        turn(
            &mut engine,
            &a,
            "A after restart",
            "thread/resume",
            saved["nativeA"].as_str(),
            "Earlier conversation context (historical messages, not a new user request):\n\nuser: B second\n\nCurrent user request:\nA after restart",
        );
        turn(
            &mut engine,
            &a,
            "A no duplicate",
            "thread/resume",
            saved["nativeA"].as_str(),
            "A no duplicate",
        );
    }
    engine.freeze_admissions();
    engine.request_core_owner_shutdown().unwrap();
    wait(&mut engine, "slot shutdown drained", |engine| {
        engine
            .poll_core_owner_shutdown()
            .unwrap()
            .rust_owners_drained()
    });
    engine.close_store_after_core_shutdown().unwrap();
}
fn provider_diagnostic(root: &Path, named: bool, stage: &str) {
    let role = if named { "named" } else { "default" };
    let _ = fs::write(root.join(format!("provider-diagnostic-{role}")), stage);
}
fn provider_check(root: &Path, named: bool, condition: bool, reason: &str) {
    if !condition {
        provider_diagnostic(root, named, reason);
        panic!("Synthetic provider check failed: {reason}");
    }
}
fn provider() {
    let home = std::env::var_os("CODEX_HOME").map(PathBuf::from);
    let root = home
        .as_ref()
        .map(|home| home.ancestors().nth(4).unwrap().to_path_buf())
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").expect("private fixture HOME")));
    let native_namespace = home
        .as_ref()
        .map(|h| h.file_name().unwrap().to_string_lossy().into_owned())
        .unwrap_or_else(|| "default".into());
    if home.is_none() {
        // Default CLI environments may retain their configured API-key source.
        // This fixture's parent is env_clear'ed; only its explicit synthetic
        // marker and system/path inputs are permitted, never real credentials.
        for (key, value) in std::env::vars_os() {
            let name = key
                .to_str()
                .expect("fixture environment name")
                .to_ascii_uppercase();
            provider_check(
                &root,
                false,
                matches!(
                    name.as_str(),
                    "PATH"
                        | "SYSTEMROOT"
                        | "WINDIR"
                        | "TMP"
                        | "TEMP"
                        | "HOME"
                        | "OPENAI_API_KEY"
                        | "COINCIDE_CONTROL_SOCKET"
                        | "COINCIDE_PORTABLE_ROOT"
                        | "COINCIDE_PORTABLE_PHASE"
                        | "COINCIDE_CODEX_EXECUTABLE"
                ),
                &format!("default_environment_key_{name}"),
            );
            if name == "COINCIDE_PORTABLE_ROOT" {
                provider_check(
                    &root,
                    false,
                    PathBuf::from(&value) == root,
                    "default_root_marker",
                );
            }
            if name == "COINCIDE_CODEX_EXECUTABLE" {
                provider_check(
                    &root,
                    false,
                    PathBuf::from(&value) == std::env::current_exe().unwrap(),
                    "default_executable_marker",
                );
            }
            if name == "COINCIDE_PORTABLE_PHASE" {
                provider_check(
                    &root,
                    false,
                    matches!(
                        value.to_str(),
                        Some(
                            "ordinary-default-seed"
                                | "ordinary-default-resume"
                                | "ordinary-explicit-seed"
                                | "ordinary-explicit-resume"
                        )
                    ),
                    "default_phase_marker",
                );
            }
            if name == "OPENAI_API_KEY" {
                provider_check(
                    &root,
                    false,
                    value == "synthetic-must-not-inherit",
                    "default_api_marker",
                );
            }
            if name == "COINCIDE_CONTROL_SOCKET" {
                provider_check(
                    &root,
                    false,
                    value
                        .to_str()
                        .is_some_and(|s| s.contains("coincide-unbound-")),
                    "default_control_endpoint",
                );
            }
        }
    }
    for key in [
        "OPENAI_API_KEY",
        "CODEX_API_KEY",
        "CODEX_ACCESS_TOKEN",
        "OPENAI_BASE_URL",
        "COINCIDE_PORTABLE_PHASE",
    ] {
        if matches!(key, "OPENAI_API_KEY" | "COINCIDE_PORTABLE_PHASE") && home.is_none() {
            continue;
        }
        provider_check(
            &root,
            home.is_some(),
            std::env::var_os(key).is_none(),
            &format!("forbidden_environment_{key}"),
        );
    }
    let args = std::env::args().collect::<Vec<_>>();
    provider_check(
        &root,
        home.is_some(),
        args.iter()
            .any(|arg| arg == "forced_login_method=\"chatgpt\"")
            == home.is_some(),
        "forced_login_scope",
    );
    provider_diagnostic(&root, home.is_some(), "environment_verified");
    let config: Value = fs::read(root.join("fixture.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_else(|| {
            provider_check(&root, home.is_some(), false, "fixture_config_missing");
            unreachable!()
        });
    let mut native = String::new();
    let read = io::stdin().lock().lines();
    for line in read {
        let frame: Value = serde_json::from_str(&line.unwrap()).unwrap();
        let method = frame["method"].as_str().unwrap();
        let category = match method {
            "initialize" | "initialized" | "account/read" | "model/list" | "thread/start"
            | "thread/resume" | "turn/start" => method,
            _ => "unexpected_method",
        };
        provider_diagnostic(&root, home.is_some(), category);
        let result = match method {
            "initialize" => json!({}),
            "initialized" => continue,
            "account/read" => json!({"requiresOpenaiAuth":true,"account":{"type":"chatgpt"}}),
            "model/list" => {
                json!({"data":[{"model":"portable-model","supportedReasoningEfforts":[{"reasoningEffort":"high"}],"defaultReasoningEffort":"high"}],"nextCursor":null})
            }
            "thread/start" | "thread/resume" => {
                assert_eq!(
                    method, config["expected"],
                    "No start-or-resume alternative is accepted"
                );
                native = if method == "thread/start" {
                    let value = format!("portable-{}", uuid::Uuid::new_v4());
                    fs::write(
                        root.join(format!("native-session-{}", native_namespace)),
                        &value,
                    )
                    .unwrap();
                    value
                } else {
                    let value = fs::read_to_string(
                        root.join(format!("native-session-{}", native_namespace)),
                    )
                    .unwrap();
                    assert_eq!(frame["params"]["threadId"], value);
                    assert_eq!(config["native"], value);
                    value
                };
                json!({"thread":{"id":native},"model":"portable-model"})
            }
            "turn/start" => {
                assert!(
                    frame["params"].get("effort").is_none(),
                    "Automatic must not become advertised high on the actual wire"
                );
                assert!(
                    frame["params"]["collaborationMode"]["settings"]["reasoning_effort"].is_null()
                );
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
    if matches!(
        std::env::args().nth(1).as_deref(),
        Some("-c" | "app-server")
    ) {
        provider();
        return;
    }
    if let Some(phase_name) = std::env::var_os("COINCIDE_PORTABLE_PHASE") {
        let run = if !matches!(phase_name.to_str().unwrap(), "seed" | "resume") {
            slots_phase
        } else {
            phase
        };
        run(
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
    for stage in [
        "seed",
        "resume",
        "slots-seed",
        "slots-resume",
        "ordinary-default-seed",
        "ordinary-default-resume",
        "ordinary-explicit-seed",
        "ordinary-explicit-resume",
    ] {
        let phase_root = if matches!(stage, "seed" | "resume") {
            root.clone()
        } else {
            root.join(
                stage
                    .strip_suffix("-seed")
                    .or_else(|| stage.strip_suffix("-resume"))
                    .unwrap(),
            )
        };
        if !phase_root.exists() {
            fs::create_dir(&phase_root).unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&phase_root, fs::Permissions::from_mode(0o700)).unwrap();
            }
        }
        let mut command = Command::new(&executable);
        command.env_clear();
        for name in ["PATH", "SystemRoot", "SYSTEMROOT", "WINDIR", "TMP", "TEMP"] {
            if let Some(value) = std::env::var_os(name) {
                command.env(name, value);
            }
        }
        let output = command
            .env("HOME", &phase_root)
            .env("COINCIDE_PORTABLE_ROOT", &phase_root)
            .env("COINCIDE_PORTABLE_PHASE", stage)
            .env("COINCIDE_CODEX_EXECUTABLE", &executable)
            .env("OPENAI_API_KEY", "synthetic-must-not-inherit")
            .output()
            .unwrap();
        if !output.status.success() {
            let named = fs::read_to_string(phase_root.join("provider-diagnostic-named"))
                .unwrap_or_else(|_| "no_named_diagnostic".into());
            let default = fs::read_to_string(phase_root.join("provider-diagnostic-default"))
                .unwrap_or_else(|_| "no_default_diagnostic".into());
            let retained = dir.keep();
            panic!(
                "{stage}: named={named}; default={default}; private fixture retained at {}: {} {}",
                retained.display(),
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }
    println!(
        "portable native continuation: explicit-model restart, legacy Provider-default slots, ordinary default/explicit account+provider+default-account switching and cold warmup; exact native model/ID/delta once, saved/joined shutdown: PASS"
    );
}
