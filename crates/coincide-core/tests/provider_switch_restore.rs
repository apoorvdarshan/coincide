//! Real Engine/Store and bounded fake catalog; no authentication or turn runs.
#![cfg(unix)]
use coincide_core::{api::Engine, store::Store};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::Path,
    process::Command,
    time::{Duration, Instant},
};

#[test]
fn previous_model_restoration_requires_current_private_default_catalog() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    for name in ["home", "tmp"] {
        fs::create_dir(root.join(name)).unwrap();
    }
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    let executable = root.join("catalog-fixture");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,sys
from pathlib import Path
root=Path(__file__).parent
def read():
 r=json.loads(sys.stdin.readline())
 with (root/'calls.jsonl').open('a') as f:f.write(json.dumps(r)+'\n')
 return r
def write(v):print(json.dumps(v),flush=True)
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read();assert r['method']=='model/list' and r['params']=={}
if (root/'fail').exists():write({'id':r['id'],'error':{'code':-32603,'message':'synthetic catalog failure'}})
else:write({'id':r['id'],'result':{'data':[{'model':'synthetic-last-model'}],'nextCursor':None}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let out = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "restore_fixture_child",
            "--nocapture",
        ])
        .env_clear()
        .env("HOME", root.join("home"))
        .env("TMPDIR", root.join("tmp"))
        .env("PATH", "/usr/bin:/bin")
        .env("COINCIDE_CODEX_EXECUTABLE", &executable)
        .env("COINCIDE_RESTORE_FIXTURE", &root)
        .current_dir(&root)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(String::from_utf8_lossy(&out.stdout).contains("1 passed"));
    let calls = fs::read_to_string(root.join("calls.jsonl"))
        .unwrap()
        .lines()
        .map(|row| {
            serde_json::from_str::<Value>(row).unwrap()["method"]
                .as_str()
                .unwrap()
                .to_owned()
        })
        .collect::<Vec<_>>();
    assert_eq!(calls, ["initialize", "initialized", "model/list"].repeat(3));
}

fn call(engine: &mut Engine, method: &str, params: Value) -> Value {
    let response = engine.dispatch(json!({"method":method,"params":params}));
    assert!(response.get("error").is_none(), "{response}");
    response["result"].clone()
}
fn params(thread: &Value, provider: &str) -> Value {
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
    .map(|key| (key.into(), thread[key].clone()))
    .collect::<serde_json::Map<_, _>>();
    json!({"threadId":thread["id"],"provider":provider,"expected":expected})
}
fn raw(root: &Path, id: &str) -> String {
    rusqlite::Connection::open(root.join("state.sqlite"))
        .unwrap()
        .query_row("SELECT document FROM threads WHERE id=?1", [id], |row| {
            row.get(0)
        })
        .unwrap()
}
fn refused(engine: &mut Engine, root: &Path, id: &str, params: Value) {
    let before = raw(root, id);
    let revision = engine.revision;
    let result = engine.dispatch(json!({"method":"agent.provider.select","params":params}));
    assert!(result.get("error").is_some(), "{result}");
    assert_eq!(raw(root, id), before);
    assert_eq!(engine.revision, revision);
}
fn refresh(engine: &mut Engine, expected_state: &str) {
    let request = call(engine, "agent.models.refresh", json!({"provider":"codex"}));
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let result = call(
            engine,
            "agent.models.status",
            json!({"requestId":request["requestId"]}),
        );
        if result["state"] != "loading" {
            assert_eq!(result["state"], expected_state, "{result}");
            assert_eq!(result["authenticationChecked"], false);
            return;
        }
        assert!(Instant::now() < deadline, "fake catalog did not finish");
        std::thread::yield_now();
    }
}
fn selected(engine: &mut Engine, original: &Value, model: &str) {
    engine.store.save(original).unwrap();
    let result = call(engine, "agent.provider.select", params(original, "codex"));
    let restored = model != "default";
    assert_eq!(result["restored"], restored);
    assert_eq!(result["model"], model);
    assert_eq!(
        result["provenance"],
        if restored {
            "latest_default_catalog"
        } else {
            "provider_default"
        }
    );
    assert_eq!(result["authenticationChecked"], false);
    assert_eq!(result["accountRestored"], false);
    let mut expected = original.clone();
    expected["selection"]["provider"] = json!("codex");
    expected["selection"]["modelID"] = json!(model);
    expected["selection"]
        .as_object_mut()
        .unwrap()
        .remove("accountID");
    assert_eq!(result["thread"], expected);
    assert_eq!(
        engine
            .store
            .thread(original["id"].as_str().unwrap())
            .unwrap(),
        expected
    );
}

#[test]
#[ignore = "Outer test supplies a cleared private HOME and only a synthetic executable"]
fn restore_fixture_child() {
    let root = std::path::PathBuf::from(std::env::var_os("COINCIDE_RESTORE_FIXTURE").unwrap());
    let mut engine = Engine::new(Store::open(&root.join("state.sqlite")).unwrap());
    let project = call(
        &mut engine,
        "projects.create",
        json!({"path":root,"name":"Synthetic restore"}),
    );
    let mut original = call(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    );
    let other = call(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    );
    let id = original["id"].as_str().unwrap().to_owned();
    let other_id = other["id"].as_str().unwrap();
    let other_raw = raw(&root, other_id);
    original["selection"] = json!({"provider":"claude","modelID":"synthetic-current"});
    original["draft"] = json!(" /codex\n");
    original["draftContext"] = json!([]);
    original["rustDraftImages"] = json!([]);
    original["items"] = json!([{"id":uuid::Uuid::new_v4(),"kind":"assistant","provider":"codex","modelID":"synthetic-last-model","accountID":null,"text":"Synthetic 👩🏽‍💻 café 中文","future":{"keep":true}}]);
    original["sessions"] = json!({"codex":{"sessionID":"synthetic-retained","seenItemCount":1,"future":{"keep":true}}});
    original["future"] = json!({"unknown":[true,42]});
    engine
        .store
        .save_document("restore-sentinel.json", &json!({"future":{"exact":true}}))
        .unwrap();
    engine.set_active_thread(Some(id.clone())).unwrap();

    // History and discovery metadata alone do not restore a model.
    selected(&mut engine, &original, "default");
    assert!(!root.join("calls.jsonl").exists());
    refresh(&mut engine, "ready");
    let catalog_calls = fs::read(root.join("calls.jsonl")).unwrap();
    selected(&mut engine, &original, "synthetic-last-model");
    assert_eq!(fs::read(root.join("calls.jsonl")).unwrap(), catalog_calls);
    let current = engine.store.thread(&id).unwrap();
    refused(&mut engine, &root, &id, params(&current, "codex"));

    for field in [
        "selection",
        "draft",
        "accessMode",
        "interactionMode",
        "draftContext",
        "rustDraftImages",
    ] {
        engine.store.save(&original).unwrap();
        let mut p = params(&original, "codex");
        p["expected"][field] = json!({"stale":true});
        refused(&mut engine, &root, &id, p);
    }
    engine.store.save(&original).unwrap();
    let mut injected = params(&original, "codex");
    injected["model"] = json!("injected");
    refused(&mut engine, &root, &id, injected);
    engine.set_active_thread(Some(other_id.to_owned())).unwrap();
    refused(&mut engine, &root, &id, params(&original, "codex"));
    engine.set_active_thread(Some(id.clone())).unwrap();
    for (field, value) in [
        ("effort", json!("high")),
        ("speed", json!("priority")),
        ("accountID", json!(uuid::Uuid::new_v4())),
    ] {
        let mut changed = original.clone();
        changed["selection"][field] = value;
        engine.store.save(&changed).unwrap();
        refused(&mut engine, &root, &id, params(&changed, "codex"));
    }
    for key in ["botID", "rustBotContext", "draftContext", "rustDraftImages"] {
        let mut changed = original.clone();
        changed[key] = json!([{"synthetic":true}]);
        engine.store.save(&changed).unwrap();
        refused(&mut engine, &root, &id, params(&changed, "codex"));
    }
    let mut changed = original.clone();
    changed["selection"]["futureOption"] = json!(true);
    engine.store.save(&changed).unwrap();
    refused(&mut engine, &root, &id, params(&changed, "codex"));

    // Never borrow a named account's historical model or an older matching row.
    let mut named = original.clone();
    named["items"][0]["accountID"] = json!(uuid::Uuid::new_v4());
    selected(&mut engine, &named, "default");
    let mut unreported = original.clone();
    unreported["items"]
        .as_array_mut()
        .unwrap()
        .push(json!({"provider":"codex","modelID":"unreported","accountID":null}));
    selected(&mut engine, &unreported, "default");
    let mut legacy = original.clone();
    legacy["items"][0]
        .as_object_mut()
        .unwrap()
        .remove("accountID");
    selected(&mut engine, &legacy, "synthetic-last-model");
    legacy["sessions"]["codex"]["accountID"] = json!(uuid::Uuid::new_v4());
    selected(&mut engine, &legacy, "default");
    let mut no_history = original.clone();
    no_history["items"] = json!([]);
    selected(&mut engine, &no_history, "default");

    // Imported status is the actual Store marker, never a client JSON claim.
    let source = root.join("legacy");
    fs::create_dir_all(source.join("threads")).unwrap();
    let imported_id = uuid::Uuid::new_v4().to_string();
    let mut imported = original.clone();
    imported["id"] = json!(imported_id);
    let source_bytes = serde_json::to_vec_pretty(&imported).unwrap();
    let source_file = source.join("threads").join(format!("{imported_id}.json"));
    fs::write(&source_file, &source_bytes).unwrap();
    let primary_before_import = raw(&root, &id);
    let calls_before_import = fs::read(root.join("calls.jsonl")).unwrap();
    let imported_root = root.join("imported-case");
    fs::create_dir(&imported_root).unwrap();
    fs::set_permissions(&imported_root, fs::Permissions::from_mode(0o700)).unwrap();
    let mut imported_store = Store::open(&imported_root.join("state.sqlite")).unwrap();
    imported_store.import_legacy(&source).unwrap();
    let mut imported_engine = Engine::new(imported_store);
    imported_engine
        .set_active_thread(Some(imported_id.clone()))
        .unwrap();
    // Dispatch normally polls before executing a request. Establish this new
    // Engine's initial runtime-context revision before measuring the refusal;
    // the rejected selection itself must still leave revision/raw data exact.
    imported_engine.poll();
    assert!(imported_engine.store.is_imported(&imported_id).unwrap());
    let imported_before = imported_engine.store.thread(&imported_id).unwrap();
    refused(
        &mut imported_engine,
        &imported_root,
        &imported_id,
        params(&imported_before, "codex"),
    );
    assert_eq!(fs::read(source_file).unwrap(), source_bytes);
    assert_eq!(raw(&root, &id), primary_before_import);
    assert_eq!(
        fs::read(root.join("calls.jsonl")).unwrap(),
        calls_before_import
    );
    let providers = imported_engine.provider_workers_status();
    assert_eq!(
        (
            providers.running,
            providers.returned,
            providers.panicked,
            providers.unclassified
        ),
        (0, 0, 0, 0)
    );
    imported_engine.freeze_admissions();
    let catalog = imported_engine.model_catalog_shutdown_status().unwrap();
    assert_eq!(
        (
            catalog.running,
            catalog.returned,
            catalog.panicked,
            catalog.unclassified
        ),
        (0, 0, 0, 0)
    );
    drop(imported_engine);

    // A later failed read revokes the successful catalog; no stale fallback.
    fs::write(root.join("fail"), "synthetic failure").unwrap();
    refresh(&mut engine, "failed");
    selected(&mut engine, &original, "default");
    fs::remove_file(root.join("fail")).unwrap();
    refresh(&mut engine, "ready");
    selected(&mut engine, &original, "synthetic-last-model");
    let executable = root.join("catalog-fixture");
    let mut bytes = fs::read(&executable).unwrap();
    bytes.extend_from_slice(b"\n# identity changed\n");
    fs::write(executable, bytes).unwrap();
    selected(&mut engine, &original, "default");
    assert_eq!(raw(&root, other_id), other_raw);
    assert_eq!(
        engine.store.document("restore-sentinel.json").unwrap(),
        Some(json!({"future":{"exact":true}}))
    );
    let providers = engine.provider_workers_status();
    assert_eq!(
        (
            providers.running,
            providers.returned,
            providers.panicked,
            providers.unclassified
        ),
        (0, 0, 0, 0)
    );
    engine.freeze_admissions();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        engine.poll();
        let status = engine.model_catalog_shutdown_status().unwrap();
        if status.running == 0 {
            assert_eq!(
                (status.returned, status.panicked, status.unclassified),
                (3, 0, 0)
            );
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
    drop(engine);
    let mut restarted = Engine::new(Store::open(&root.join("state.sqlite")).unwrap());
    restarted.set_active_thread(Some(id.clone())).unwrap();
    selected(&mut restarted, &original, "default");
    restarted.freeze_admissions();
    let status = restarted.model_catalog_shutdown_status().unwrap();
    assert_eq!(
        (
            status.running,
            status.returned,
            status.panicked,
            status.unclassified
        ),
        (0, 0, 0, 0)
    );
}
