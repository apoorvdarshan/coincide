//! Actual Engine + owned fake app-server processes; no real credentials/provider.
#![cfg(unix)]
use coincide_core::{
    api::Engine,
    store::{Store, text},
};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::{fs::PermissionsExt, net::UnixDatagram},
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant},
};

#[test]
fn named_limits_use_captured_private_account_and_never_borrow_cached_results() {
    let dir = tempfile::tempdir().unwrap();
    // The Store/project resolver and native cwd use canonical paths. Freeze one
    // owned identity up front, including macOS /var versus /private/var aliases.
    let root = dir.path().canonicalize().unwrap();
    let executable = root.join("fake-limits");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,os,socket,sys
from pathlib import Path
root=Path(__file__).parent
home=Path(os.environ['CODEX_HOME'])
named='-c' in sys.argv
if named:
 assert home.parent.name=='codex' and home.parent.parent.name=='providers'
 for key in ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','CHATGPT_BASE_URL','HTTPS_PROXY','COINCIDE_LIMITS_FIXTURE_ROOT']:
  assert key not in os.environ,key
 for value in ['cli_auth_credentials_store="file"','forced_login_method="chatgpt"','model_provider="openai"','openai_base_url="https://chatgpt.com/backend-api/codex"','chatgpt_base_url="https://chatgpt.com/backend-api/"']:
  assert value in sys.argv,value
else:
 assert home==root/'default-home'
 assert os.environ['OPENAI_API_KEY']=='synthetic-key'
mode=(home/'fixture-mode').read_text() if (home/'fixture-mode').exists() else 'allow'
def record(value):
 with (root/'calls.jsonl').open('a') as f:f.write(json.dumps({'home':str(home),'cwd':os.getcwd(),'named':named,**value})+'\n')
def read():
 line=sys.stdin.readline()
 if not line:sys.exit(0)
 value=json.loads(line);record({'method':value.get('method'),'params':value.get('params')});return value
def write(value):print(json.dumps(value),flush=True)
record({'pid':os.getpid()})
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read()
if named:
 assert r['method']=='account/read' and r['params']=={'refreshToken':False}
 account=None if mode=='deny' else {'type':'apiKey'} if mode=='api-key' else {'type':'chatgpt','email':'synthetic@example.invalid','planType':'plus'}
 write({'id':r['id'],'result':{'requiresOpenaiAuth':True,'account':account}})
 r=read()
assert r['method']=='account/rateLimits/read' and r['params']=={}
if mode=='block':
 (home/'limits-blocked').write_text('ready')
 sys.stdin.readline();sys.exit(0)
if mode=='auth-change':write({'method':'account/updated','params':{}})
else:write({'method':'account/rateLimits/updated','params':{}})
if mode=='revoke':
 # Off-PTY gate: only Rust's completed loading receipt authorizes mutation.
 with socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM) as gate:
  gate.settimeout(10)
  gate.bind(str(root/'revoke-peer.sock'))
  gate.connect(str(root/'revoke.sock'))
  gate.send(b'waiting')
  assert gate.recv(1)==b'R'
 (home/'auth.json').write_text('synthetic file identity change, not authentication');(home/'auth.json').chmod(0o600)
result={'rateLimits':None} if mode=='missing' else {'rateLimits':{'primary':{'usedPercent':float((home/'fixture-percent').read_text()) if named else 99},'credits':{'hasCredits':True,'balance':'3.00'}}}
write({'id':r['id'],'result':result})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "limits_fixture_child",
            "--nocapture",
        ])
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap())
        .env("HOME", &root)
        .env("COINCIDE_LIMITS_FIXTURE_ROOT", &root)
        .env("COINCIDE_CODEX_EXECUTABLE", executable)
        .env("CODEX_HOME", root.join("default-home"))
        .env("OPENAI_API_KEY", "synthetic-key")
        .env("CODEX_API_KEY", "synthetic-key")
        .env("CODEX_ACCESS_TOKEN", "synthetic-token")
        .env("OPENAI_BASE_URL", "https://invalid.invalid")
        .env("CHATGPT_BASE_URL", "https://invalid.invalid")
        .env("HTTPS_PROXY", "http://invalid.invalid")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
fn call(engine: &mut Engine, method: &str, params: Value) -> Value {
    let response = engine.dispatch(json!({"method":method,"params":params}));
    assert!(response.get("error").is_none(), "{response}");
    response["result"].clone()
}
fn denied(engine: &mut Engine, method: &str, params: Value) {
    assert!(
        engine
            .dispatch(json!({"method":method,"params":params}))
            .get("error")
            .is_some()
    );
}
fn select(engine: &mut Engine, id: &str, account: &str) {
    let thread = engine.store.thread(id).unwrap();
    call(
        engine,
        "providers.codex.profiles.select",
        json!({"threadId":id,"accountId":account,"expectedSelection":thread["selection"]}),
    );
}
fn target(engine: &Engine, id: &str) -> Value {
    let thread = engine.store.thread(id).unwrap();
    json!({"threadId":id,"accountId":thread["selection"]["accountID"],"expectedSelection":thread["selection"]})
}
fn status_params(mut target: Value, request: &Value) -> Value {
    target["requestId"] = request["requestId"].clone();
    target
}
fn wait(engine: &mut Engine, params: Value, method: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let value = call(engine, method, params.clone());
        if value["state"] != "loading" {
            return value;
        }
        assert!(
            Instant::now() < deadline,
            "owned limits worker did not complete"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn refresh(engine: &mut Engine, id: &str) -> Value {
    let params = target(engine, id);
    let request = call(
        engine,
        "providers.codex.profiles.limits.refresh",
        params.clone(),
    );
    assert_eq!(request["state"], "loading");
    assert_eq!(request["accountScope"], "named_codex_profile");
    assert_eq!(request["threadId"], params["threadId"]);
    assert_eq!(request["accountId"], params["accountId"]);
    assert_eq!(request["expectedSelection"], params["expectedSelection"]);
    assert_eq!(request["authenticationChecked"], false);
    assert_eq!(request["accountIdentityVerified"], false);
    assert!(request["snapshot"].is_null());
    wait(
        engine,
        status_params(params, &request),
        "providers.codex.profiles.limits.status",
    )
}
fn records(root: &Path) -> Vec<Value> {
    fs::read_to_string(root.join("calls.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}
fn no_model_authority(engine: &mut Engine, id: &str, quota: &Value, root: &Path) {
    let before = engine.store.thread(id).unwrap();
    let raw = raw_state(&root.join("state/state.sqlite"));
    let count = records(root).len();
    let caps = call(
        engine,
        "agent.selection.capabilities",
        json!({"threadId":id}),
    );
    assert_eq!(caps["namedModels"]["fullAccessSupported"], false);
    assert_eq!(caps["namedModels"]["authenticationChecked"], false);
    // An actual quota request is not a model-catalog proof or a grant to change
    // access policy. Both refusals must precede any process or Store mutation.
    for params in [
        json!({"threadId":id,"accountId":before["selection"]["accountID"],
            "expectedSelection":before["selection"],"model":"synthetic-limits-only",
            "requestId":quota["requestId"]}),
        json!({"threadId":id,"accountId":before["selection"]["accountID"],
            "expectedSelection":before["selection"],"model":"default","accessMode":"fullAccess",
            "expectedAccessMode":before["accessMode"],"expectedInteractionMode":before["interactionMode"]}),
    ] {
        denied(engine, "providers.codex.profiles.models.select", params);
    }
    assert_eq!(engine.store.thread(id).unwrap(), before);
    assert_eq!(raw_state(&root.join("state/state.sqlite")), raw);
    assert_eq!(records(root).len(), count);
    let workers = engine.provider_workers_status();
    assert_eq!(workers.running, 0);
    assert_eq!(workers.returned, 0);
    assert_eq!(workers.panicked, 0);
    assert_eq!(workers.unclassified, 0);
}
type RawState = Vec<Vec<Vec<rusqlite::types::Value>>>;
fn raw_state(database: &Path) -> RawState {
    let db =
        rusqlite::Connection::open_with_flags(database, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
    [
        "SELECT id,document FROM threads ORDER BY id",
        "SELECT * FROM thread_summaries ORDER BY id",
        "SELECT rowid,thread_id,title,body FROM search ORDER BY rowid",
        "SELECT rowid,thread_id,body FROM search_trigram ORDER BY rowid",
        "SELECT name,document FROM documents ORDER BY name",
        "SELECT path,data FROM original_files ORDER BY path",
    ]
    .into_iter()
    .map(|sql| {
        let mut statement = db.prepare(sql).unwrap();
        let columns = statement.column_count();
        statement
            .query_map([], |row| {
                (0..columns)
                    .map(|index| row.get(index))
                    .collect::<rusqlite::Result<Vec<_>>>()
            })
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap()
    })
    .collect()
}
fn finish(engine: &mut Engine) {
    engine.freeze_admissions();
    engine.request_model_catalog_shutdown().unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let status = engine.model_catalog_shutdown_status().unwrap();
        if status.running == 0 {
            assert_eq!(status.panicked, 0);
            assert_eq!(status.unclassified, 0);
            assert!(status.returned > 0);
            break;
        }
        assert!(
            Instant::now() < deadline,
            "owned limits worker did not join"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
}
#[test]
#[ignore = "Outer test owns cleared synthetic environment and fake executable"]
fn limits_fixture_child() {
    const REFRESH: &str = "providers.codex.profiles.limits.refresh";
    const STATUS: &str = "providers.codex.profiles.limits.status";
    let root = PathBuf::from(std::env::var_os("COINCIDE_LIMITS_FIXTURE_ROOT").unwrap());
    let database = root.join("state/state.sqlite");
    let mut engine = Engine::new(Store::open(&database).unwrap());
    let project = call(
        &mut engine,
        "projects.create",
        json!({"path":root,"name":"Synthetic limits"}),
    );
    assert_eq!(project["path"], json!(root));
    let thread = call(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    );
    let other = call(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    );
    let id = text(&thread, "id");
    engine.set_active_thread(Some(id.clone())).unwrap();
    call(
        &mut engine,
        "agent.select",
        json!({"threadId":id,"provider":"codex","model":"default"}),
    );
    let mut original = engine.store.thread(&id).unwrap();
    original["draft"] = json!("retained λ unsent draft\n");
    original["future"] = json!({"opaque":[true,42]});
    original["composerContext"] = json!({"future":{"preserve":true}});
    original["draftContext"] = json!([{"id":uuid::Uuid::new_v4(),"kind":"quote",
        "text":"Synthetic retained quote λ","future":{"preserve":true}}]);
    original["sessions"] = json!({"claude":{"sessionID":"synthetic-retained-session",
        "seenItemCount":0,"future":{"preserve":true}}});
    engine.store.save(&original).unwrap();
    engine
        .store
        .save_document("settings.json", &json!({"future":{"unknown":17}}))
        .unwrap();
    let a = call(
        &mut engine,
        "providers.codex.profiles.create",
        json!({"name":"Synthetic A"}),
    );
    let b = call(
        &mut engine,
        "providers.codex.profiles.create",
        json!({"name":"Synthetic B"}),
    );
    let a = text(&a, "id");
    let b = text(&b, "id");
    let data = engine.store.data_directory().unwrap();
    let home_a = data.join("providers/codex").join(&a);
    let home_b = data.join("providers/codex").join(&b);
    fs::write(home_a.join("fixture-percent"), "12.5").unwrap();
    fs::write(home_b.join("fixture-percent"), "84").unwrap();
    select(&mut engine, &id, &a);
    let before_a = engine.store.thread(&id).unwrap();
    let target_a = target(&engine, &id);
    let before_a_raw = raw_state(&database);
    let ready_a = refresh(&mut engine, &id);
    assert_eq!(ready_a["state"], "ready");
    assert_eq!(ready_a["accountId"], a);
    assert_eq!(ready_a["authenticationChecked"], true);
    assert_eq!(ready_a["accountIdentityVerified"], false);
    assert!(
        ready_a["observedAtEpochMs"]
            .as_u64()
            .is_some_and(|stamp| stamp > 0)
    );
    assert_eq!(ready_a["expectedSelection"], before_a["selection"]);
    assert_eq!(
        ready_a["snapshot"]["main"]["windows"][0]["usedPercent"],
        12.5
    );
    assert!(ready_a["snapshot"]["main"]["windows"][0]["remainingPercent"].is_null());
    assert_eq!(engine.store.thread(&id).unwrap(), before_a);
    assert_eq!(raw_state(&database), before_a_raw);
    no_model_authority(&mut engine, &id, &ready_a, &root);
    let before_rejections = records(&root).len();
    let mut stale = target_a.clone();
    stale["expectedSelection"]["modelID"] = json!("stale");
    denied(&mut engine, REFRESH, stale);
    let mut injected = target_a.clone();
    injected["home"] = json!(home_b);
    denied(&mut engine, REFRESH, injected);
    assert_eq!(records(&root).len(), before_rejections);
    select(&mut engine, &id, &b);
    let target_b = target(&engine, &id);
    denied(
        &mut engine,
        STATUS,
        status_params(target_a.clone(), &ready_a),
    );
    denied(
        &mut engine,
        STATUS,
        status_params(target_b.clone(), &ready_a),
    );
    let ready_b = refresh(&mut engine, &id);
    assert_eq!(ready_b["accountId"], b);
    assert_eq!(
        ready_b["snapshot"]["main"]["windows"][0]["usedPercent"],
        84.0
    );
    engine.set_active_thread(Some(text(&other, "id"))).unwrap();
    engine.poll();
    denied(&mut engine, STATUS, status_params(target_b, &ready_b));
    engine.set_active_thread(Some(id.clone())).unwrap();
    // A later switch back cannot resurrect an earlier account observation.
    select(&mut engine, &id, &a);
    denied(&mut engine, STATUS, status_params(target_a, &ready_a));
    for mode in ["deny", "api-key", "missing", "auth-change"] {
        fs::write(home_a.join("fixture-mode"), mode).unwrap();
        let before = engine.store.thread(&id).unwrap();
        let raw_before = raw_state(&database);
        let calls_before = records(&root).len();
        let failed = refresh(&mut engine, &id);
        assert_eq!(failed["state"], "failed", "{mode}");
        assert!(failed["snapshot"].is_null());
        assert_eq!(failed["authenticationChecked"], false);
        if mode == "missing" {
            assert_eq!(failed["error"], "no_reported_limits");
        }
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        assert_eq!(raw_state(&database), raw_before);
        if matches!(mode, "deny" | "api-key") {
            assert!(
                !records(&root)[calls_before..]
                    .iter()
                    .any(|record| record["method"] == "account/rateLimits/read")
            );
        }
    }
    fs::write(home_a.join("fixture-mode"), "allow").unwrap();
    // Persisted mode changes must revoke quota observations even when the
    // complete selection CAS remains equal. These are explicit synthetic
    // external-store edits; restoring them cannot resurrect an old request.
    for (field, value) in [
        ("accessMode", json!("fullAccess")),
        ("interactionMode", json!("plan")),
    ] {
        let ready = refresh(&mut engine, &id);
        let params = target(&engine, &id);
        let saved = engine.store.thread(&id).unwrap();
        let raw = raw_state(&database);
        let calls = records(&root).len();
        let mut changed = saved.clone();
        changed[field] = value;
        assert_eq!(changed["selection"], saved["selection"]);
        engine.store.save(&changed).unwrap();
        engine.poll();
        denied(&mut engine, STATUS, status_params(params.clone(), &ready));
        assert_eq!(engine.store.thread(&id).unwrap(), changed);
        engine.store.save(&saved).unwrap();
        engine.poll();
        denied(&mut engine, STATUS, status_params(params, &ready));
        assert_eq!(raw_state(&database), raw);
        assert_eq!(records(&root).len(), calls);
    }
    // Restored explicit-model/full-access metadata remains readable for repair,
    // but quota-ready must neither mint model proof nor begin a provider turn.
    let supported = engine.store.thread(&id).unwrap();
    let supported_raw = raw_state(&database);
    let mut unproved = supported.clone();
    unproved["selection"]["modelID"] = json!("synthetic-limits-only");
    unproved["accessMode"] = json!("fullAccess");
    engine.store.save(&unproved).unwrap();
    let quota = refresh(&mut engine, &id);
    assert_eq!(quota["state"], "ready");
    let unproved_raw = raw_state(&database);
    let count = records(&root).len();
    denied(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"Synthetic refusal; never a provider turn"}),
    );
    assert_eq!(records(&root).len(), count);
    assert_eq!(raw_state(&database), unproved_raw);
    no_model_authority(&mut engine, &id, &quota, &root);
    engine.store.save(&supported).unwrap();
    engine.poll();
    assert_eq!(raw_state(&database), supported_raw);
    let last = refresh(&mut engine, &id);
    assert_eq!(last["state"], "ready");
    // Default observation is still its original, separately owned protocol/home.
    let default = call(&mut engine, "usage.codexLimits.refresh", json!({}));
    let default = wait(
        &mut engine,
        json!({"requestId":default["requestId"]}),
        "usage.codexLimits.status",
    );
    assert_eq!(
        default["accountScope"],
        "default_runtime_account_identity_unknown"
    );
    assert_eq!(
        default["snapshot"]["main"]["windows"][0]["usedPercent"],
        99.0
    );
    let current_target = target(&engine, &id);
    denied(&mut engine, STATUS, status_params(current_target, &default));
    denied(
        &mut engine,
        "usage.codexLimits.status",
        json!({"requestId":last["requestId"]}),
    );
    let retained = engine.store.thread(&id).unwrap();
    let retained_raw = raw_state(&database);
    finish(&mut engine);
    drop(engine);
    let calls_before_restart = records(&root).len();
    let mut engine = Engine::new(Store::open(&database).unwrap());
    engine.set_active_thread(Some(id.clone())).unwrap();
    engine.poll();
    assert_eq!(engine.store.thread(&id).unwrap(), retained);
    assert_eq!(engine.store.thread(&text(&other, "id")).unwrap(), other);
    assert_eq!(
        engine.store.document("settings.json").unwrap(),
        Some(json!({"future":{"unknown":17}}))
    );
    let restarted_target = target(&engine, &id);
    denied(&mut engine, STATUS, status_params(restarted_target, &last));
    assert_eq!(records(&root).len(), calls_before_restart);
    assert_eq!(refresh(&mut engine, &id)["state"], "ready");
    // Authentication-file mutation revokes the captured request, not the thread.
    let revoke_gate = UnixDatagram::bind(root.join("revoke.sock")).unwrap();
    revoke_gate
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    revoke_gate
        .set_write_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    fs::write(home_a.join("fixture-mode"), "revoke").unwrap();
    let params = target(&engine, &id);
    let revoking = call(&mut engine, REFRESH, params.clone());
    assert_eq!(revoking["state"], "loading");
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut waiting = [0u8; 7];
    let (length, peer) = revoke_gate.recv_from(&mut waiting).unwrap();
    assert_eq!(&waiting[..length], b"waiting");
    assert_eq!(
        peer.as_pathname(),
        Some(root.join("revoke-peer.sock").as_path())
    );
    assert_eq!(
        revoke_gate
            .send_to(b"R", root.join("revoke-peer.sock"))
            .unwrap(),
        1
    );
    while !home_a.join("auth.json").exists() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
    engine.poll();
    denied(&mut engine, STATUS, status_params(params, &revoking));
    fs::write(home_a.join("fixture-mode"), "block").unwrap();
    let blocked_target = target(&engine, &id);
    let blocked = call(&mut engine, REFRESH, blocked_target);
    assert_eq!(blocked["state"], "loading");
    let deadline = Instant::now() + Duration::from_secs(10);
    while !home_a.join("limits-blocked").exists() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
    finish(&mut engine);
    let workers = engine.provider_workers_status();
    assert_eq!(workers.running, 0);
    assert_eq!(workers.returned, 0);
    assert_eq!(workers.panicked, 0);
    assert_eq!(workers.unclassified, 0);
    assert_eq!(raw_state(&database), retained_raw);
    assert_eq!(engine.store.thread(&id).unwrap(), retained);
    assert_eq!(engine.store.thread(&text(&other, "id")).unwrap(), other);
    for record in records(&root) {
        if let Some(method) = record["method"].as_str() {
            assert!(
                matches!(
                    method,
                    "initialize" | "initialized" | "account/read" | "account/rateLimits/read"
                ),
                "unexpected RPC {method}"
            );
            if record["named"] == true {
                assert_eq!(record["cwd"], json!(root));
            } else {
                assert_ne!(method, "account/read");
            }
        }
    }
}
