//! Temporary fake processes only. Never reads live credentials or runs Codex.
#![cfg(unix)]
use coincide_core::{
    agent::provider_session,
    api::Engine,
    store::{Store, text},
};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant},
};
#[test]
fn named_profile_models_use_actual_isolated_auth_catalog_and_turn_paths() {
    run_fixture_child("profile_models_fixture_child");
}
#[test]
fn named_profile_full_access_uses_captured_policy_and_exact_catalog() {
    run_fixture_child("profile_access_fixture_child");
}
fn run_fixture_child(child: &str) {
    let dir = tempfile::tempdir().unwrap();
    let executable = dir.path().join("fake-profile-models");
    fs::write(&executable,r#"#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(__file__).parent
home=Path(os.environ['CODEX_HOME'])
assert home.parent.name=='codex' and home.parent.parent.name=='providers'
for key in ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','CHATGPT_BASE_URL','HTTPS_PROXY','COINCIDE_MODEL_FIXTURE_ROOT']:
 assert key not in os.environ,key
assert 'cli_auth_credentials_store="file"' in sys.argv
assert 'forced_login_method="chatgpt"' in sys.argv
assert 'model_provider="openai"' in sys.argv
assert 'coincide-unbound-' in os.environ['COINCIDE_CONTROL_SOCKET']
mode=(home/'fixture-mode').read_text() if (home/'fixture-mode').exists() else 'allow'
access=(home/'fixture-access').read_text() if (home/'fixture-access').exists() else 'approval'
model=(home/'fixture-model').read_text()
def record(value):
 with (root/'models-calls.jsonl').open('a') as out:out.write(json.dumps({'home':str(home),'cwd':os.getcwd(),**value})+'\n')
def read():
 line=sys.stdin.readline()
 if not line:sys.exit(0)
 value=json.loads(line);record({'method':value.get('method'),'params':value.get('params')});return value
def write(value):print(json.dumps(value),flush=True)
record({'pid':os.getpid()})
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read();assert r['method']=='account/read' and r['params']=={'refreshToken':False}
if mode=='block':
 (home/'catalog-blocked').write_text('ready');sys.stdin.readline();sys.exit(0)
write({'id':r['id'],'result':{'requiresOpenaiAuth':True,'account':None if mode=='deny' else {'type':'chatgpt','email':'synthetic@example.invalid','planType':'plus'}}})
r=read()
if r['method']=='model/list':
 if mode=='auth-change':write({'method':'account/updated','params':{}})
 else:write({'method':'account/rateLimits/updated','params':{}})
 write({'id':r['id'],'result':{'data':[{'id':model,'model':model,'displayName':'Synthetic '+model},{'model':'hidden-fixture','hidden':True}],'nextCursor':'page-two'}})
 r=read();assert r['method']=='model/list' and r['params']=={'cursor':'page-two'}
 write({'id':r['id'],'result':{'data':[{'model':model},{'model':'gpt-6-astra','supportedReasoningEfforts':[{'reasoningEffort':'medium'}]}],'nextCursor':None}})
 sys.stdin.readline();sys.exit(0)
assert r['method']=='thread/start' and r['params']['model']==model
assert r['params']['approvalPolicy']=='untrusted' and r['params']['sandbox']=='read-only'
native=home.name+'-fresh-model-thread'
if mode=='revoke-after-start':
 (home/'auth.json').write_text('synthetic revocation marker, not credentials');(home/'auth.json').chmod(0o600)
write({'id':r['id'],'result':{'thread':{'id':native},'model':'wrong-resolved' if mode=='wrong-model' else model}})
r=read();assert r['method']=='turn/start' and r['params']['model']==model
assert r['params']['approvalPolicy']==('never' if access=='fullAccess' else 'untrusted')
assert r['params']['sandboxPolicy']=={'type':'dangerFullAccess' if access=='fullAccess' else 'readOnly'}
assert r['params']['approvalsReviewer']=='user'
assert r['params']['collaborationMode']=={'mode':'default','settings':{'model':model,'reasoning_effort':None,'developer_instructions':None}}
assert 'effort' not in r['params']
write({'id':r['id'],'result':{'turn':{'id':'synthetic-turn'}}})
if mode=='hold-turn':
 (home/'turn-held').write_text('ready');sys.stdin.readline();sys.exit(0)
write({'method':'turn/completed','params':{'threadId':native,'turn':{'id':'synthetic-turn','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args(["--ignored", "--exact", child, "--nocapture"])
        .env("COINCIDE_MODEL_FIXTURE_ROOT", dir.path())
        .env("COINCIDE_CODEX_EXECUTABLE", &executable)
        .env("CODEX_HOME", dir.path().join("hostile-default-home"))
        .env("OPENAI_API_KEY", "synthetic-hostile-key")
        .env("CODEX_API_KEY", "synthetic-hostile-key")
        .env("CODEX_ACCESS_TOKEN", "synthetic-hostile-token")
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
    let value = engine.dispatch(json!({"method":method,"params":params}));
    assert!(value.get("error").is_none(), "{value}");
    value["result"].clone()
}
fn denied(engine: &mut Engine, method: &str, params: Value) {
    assert!(
        engine
            .dispatch(json!({"method":method,"params":params}))
            .get("error")
            .is_some()
    );
}
fn select_profile(engine: &mut Engine, id: &str, account: &str) {
    let current = engine.store.thread(id).unwrap();
    call(
        engine,
        "providers.codex.profiles.select",
        json!({"threadId":id,"accountId":account,"expectedSelection":current["selection"]}),
    );
}
fn choose(
    engine: &mut Engine,
    id: &str,
    account: &str,
    model: &str,
    request: Option<&str>,
) -> Value {
    let current = engine.store.thread(id).unwrap();
    let mut p = json!({"threadId":id,"accountId":account,"model":model,"expectedSelection":current["selection"]});
    if let Some(request) = request {
        p["requestId"] = json!(request);
    }
    call(engine, "providers.codex.profiles.models.select", p)
}
fn start_catalog(engine: &mut Engine, id: &str, account: &str) -> Value {
    let current = engine.store.thread(id).unwrap();
    call(
        engine,
        "providers.codex.profiles.models.refresh",
        json!({"threadId":id,"accountId":account,"expectedSelection":current["selection"]}),
    )
}
fn wait_catalog(engine: &mut Engine, id: &str, account: &str, request: &Value) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let result = call(
            engine,
            "providers.codex.profiles.models.status",
            json!({"threadId":id,"accountId":account,"requestId":request["requestId"]}),
        );
        if result["state"] != "loading" {
            return result;
        }
        assert!(Instant::now() < deadline, "fake catalog did not finish");
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn records(root: &Path) -> Vec<Value> {
    fs::read_to_string(root.join("models-calls.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}
fn assert_profile_sessions(thread: &Value, a: &str, b: &str) {
    // Persistence keeps one current native reference and caches other accounts.
    // Resolve through the public account-aware lookup, independent of location.
    for account in [a, b] {
        let mut view = thread.clone();
        view["selection"]["accountID"] = json!(account);
        assert_eq!(
            provider_session(&view, "codex"),
            Some(format!("{account}-fresh-model-thread")),
        );
    }
}
fn settle(engine: &mut Engine) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let status = call(engine, "app.status", json!({}));
        if status["running"].as_array().unwrap().is_empty()
            && engine.provider_workers_status().running == 0
        {
            return;
        }
        assert!(Instant::now() < deadline, "fake turn did not finish");
        std::thread::sleep(Duration::from_millis(2));
    }
}
#[test]
#[ignore = "Isolated fake child; outer test supplies only synthetic environment"]
fn profile_models_fixture_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_MODEL_FIXTURE_ROOT").unwrap());
    let mut engine = Engine::new(Store::open(&root.join("state/state.sqlite")).unwrap());
    let project = call(
        &mut engine,
        "projects.create",
        json!({"path":root,"name":"Synthetic model catalog project"}),
    );
    let thread = call(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    );
    assert_eq!(thread["projectID"], project["id"]);
    assert_eq!(project["path"], json!(root.canonicalize().unwrap()));
    assert!(thread["worktreePath"].is_null());
    let id = text(&thread, "id");
    engine.set_active_thread(Some(id.clone())).unwrap();
    call(
        &mut engine,
        "agent.select",
        json!({"threadId":id,"provider":"codex","model":"default"}),
    );
    let mut original = engine.store.thread(&id).unwrap();
    original["future"] = json!({"keep":42});
    original["draft"] = json!("retained draft");
    engine.store.save(&original).unwrap();
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
    fs::write(home_a.join("fixture-model"), "synthetic-a").unwrap();
    fs::write(home_b.join("fixture-model"), "synthetic-b").unwrap();
    select_profile(&mut engine, &id, &a);
    let first = start_catalog(&mut engine, &id, &a);
    let ready_a = wait_catalog(&mut engine, &id, &a, &first);
    assert_eq!(ready_a["state"], "ready");
    assert_eq!(ready_a["authenticationChecked"], true);
    assert_eq!(ready_a["models"].as_array().unwrap().len(), 2);
    assert_eq!(ready_a["models"][0]["id"], "synthetic-a");
    let before = engine.store.thread(&id).unwrap();
    let picked = choose(
        &mut engine,
        &id,
        &a,
        "synthetic-a",
        first["requestId"].as_str(),
    );
    let mut expected = before.clone();
    expected["selection"]["modelID"] = json!("synthetic-a");
    assert_eq!(picked, expected);
    denied(
        &mut engine,
        "providers.codex.profiles.models.select",
        json!({"threadId":id,"accountId":a,"model":"default","expectedSelection":before["selection"]}),
    );
    engine.set_active_thread(None).unwrap();
    denied(
        &mut engine,
        "providers.codex.profiles.models.refresh",
        json!({"threadId":id,"accountId":a,"expectedSelection":picked["selection"]}),
    );
    engine.set_active_thread(Some(id.clone())).unwrap();
    denied(
        &mut engine,
        "providers.codex.profiles.models.select",
        json!({"threadId":id,"accountId":a,"model":"gpt-6-astra","requestId":first["requestId"],"expectedSelection":picked["selection"]}),
    );
    denied(
        &mut engine,
        "agent.models.refresh",
        json!({"provider":"codex","accountId":a}),
    );
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"Synthetic named model turn"}),
    );
    settle(&mut engine);
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["selection"]["accountID"], a);
    assert_eq!(saved["future"], json!({"keep":42}));
    choose(&mut engine, &id, &a, "default", None);
    select_profile(&mut engine, &id, &b);
    denied(
        &mut engine,
        "providers.codex.profiles.models.status",
        json!({"threadId":id,"accountId":b,"requestId":first["requestId"]}),
    );
    let second = start_catalog(&mut engine, &id, &b);
    let ready_b = wait_catalog(&mut engine, &id, &b, &second);
    assert_eq!(ready_b["models"][0]["id"], "synthetic-b");
    let current = engine.store.thread(&id).unwrap();
    denied(
        &mut engine,
        "providers.codex.profiles.models.select",
        json!({"threadId":id,"accountId":b,"model":"synthetic-a","requestId":first["requestId"],"expectedSelection":current["selection"]}),
    );
    choose(
        &mut engine,
        &id,
        &b,
        "synthetic-b",
        second["requestId"].as_str(),
    );
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"Other profile model turn"}),
    );
    settle(&mut engine);
    assert_profile_sessions(&engine.store.thread(&id).unwrap(), &a, &b);
    choose(&mut engine, &id, &b, "default", None);
    select_profile(&mut engine, &id, &a);
    choose(
        &mut engine,
        &id,
        &a,
        "synthetic-a",
        first["requestId"].as_str(),
    );
    let nested = root.join("different-cwd");
    fs::create_dir(&nested).unwrap();
    let mut current = engine.store.thread(&id).unwrap();
    current["worktreePath"] = json!(nested);
    engine.store.save(&current).unwrap();
    let items = current["items"].clone();
    denied(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"Must not cross cwd"}),
    );
    assert_eq!(engine.store.thread(&id).unwrap()["items"], items);
    current.as_object_mut().unwrap().remove("worktreePath");
    engine.store.save(&current).unwrap();
    fs::write(home_a.join("fixture-mode"), "deny").unwrap();
    let refused = start_catalog(&mut engine, &id, &a);
    assert_eq!(
        wait_catalog(&mut engine, &id, &a, &refused)["state"],
        "failed"
    );
    denied(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"No fallback after failed refresh"}),
    );
    assert_eq!(engine.store.thread(&id).unwrap()["items"], items);
    fs::write(home_a.join("fixture-mode"), "auth-change").unwrap();
    let changed = start_catalog(&mut engine, &id, &a);
    assert_eq!(
        wait_catalog(&mut engine, &id, &a, &changed)["state"],
        "failed"
    );
    fs::write(home_a.join("fixture-mode"), "allow").unwrap();
    let refresh = start_catalog(&mut engine, &id, &a);
    assert_eq!(
        wait_catalog(&mut engine, &id, &a, &refresh)["state"],
        "ready"
    );
    choose(
        &mut engine,
        &id,
        &a,
        "synthetic-a",
        refresh["requestId"].as_str(),
    );
    fs::write(home_a.join("fixture-mode"), "wrong-model").unwrap();
    let turn_count = records(&root)
        .iter()
        .filter(|v| v["method"] == "turn/start")
        .count();
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"Reject wrong resolved model"}),
    );
    settle(&mut engine);
    assert_eq!(
        records(&root)
            .iter()
            .filter(|v| v["method"] == "turn/start")
            .count(),
        turn_count
    );
    fs::write(home_a.join("fixture-mode"), "block").unwrap();
    let blocked = start_catalog(&mut engine, &id, &a);
    assert_eq!(blocked["state"], "loading");
    let deadline = Instant::now() + Duration::from_secs(10);
    while !home_a.join("catalog-blocked").exists() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
    engine.freeze_admissions();
    engine.request_model_catalog_shutdown().unwrap();
    loop {
        let status = engine.model_catalog_shutdown_status().unwrap();
        if status.running == 0 {
            assert_eq!(status.panicked, 0);
            assert_eq!(status.unclassified, 0);
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
    let calls = records(&root);
    assert!(
        calls
            .iter()
            .any(|v| v["home"] == json!(home_a) && v["method"] == "model/list")
    );
    assert!(
        calls
            .iter()
            .any(|v| v["home"] == json!(home_b) && v["method"] == "model/list")
    );
    let b_turn = calls
        .iter()
        .find(|v| v["home"] == json!(home_b) && v["method"] == "turn/start")
        .unwrap();
    assert!(
        b_turn["params"]["input"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Synthetic named model turn")
    );
    assert!(!calls.iter().any(|v| v["method"] == "thread/resume"));
    assert_eq!(
        calls.iter().filter(|v| v["method"] == "turn/start").count(),
        2
    );
    // A/B native session IDs and full-replay launches remain separate.
    let saved = engine.store.thread(&id).unwrap();
    assert_profile_sessions(&saved, &a, &b);
}

fn access_request(
    thread: &Value,
    account: &str,
    model: &str,
    request: Option<&str>,
    access: &str,
) -> Value {
    let mut p = json!({"threadId":thread["id"],"accountId":account,"expectedSelection":thread["selection"],"model":model,
        "accessMode":access,"expectedAccessMode":thread["accessMode"],"expectedInteractionMode":thread["interactionMode"]});
    if let Some(request) = request {
        p["requestId"] = json!(request);
    }
    p
}
#[test]
#[ignore = "Isolated fake child; outer test supplies only synthetic environment"]
fn profile_access_fixture_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_MODEL_FIXTURE_ROOT").unwrap());
    let db = root.join("state/state.sqlite");
    let mut engine = Engine::new(Store::open(&db).unwrap());
    let project = call(
        &mut engine,
        "projects.create",
        json!({"path":root,"name":"Owned access project"}),
    );
    let original = call(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    );
    let id = text(&original, "id");
    engine.set_active_thread(Some(id.clone())).unwrap();
    let account = call(
        &mut engine,
        "providers.codex.profiles.create",
        json!({"name":"Synthetic access A"}),
    );
    let account = text(&account, "id");
    let other = call(
        &mut engine,
        "providers.codex.profiles.create",
        json!({"name":"Synthetic access B"}),
    );
    let other = text(&other, "id");
    let data = engine.store.data_directory().unwrap();
    let home = data.join("providers/codex").join(&account);
    let home_b = data.join("providers/codex").join(&other);
    fs::write(home.join("fixture-model"), "synthetic-access").unwrap();
    fs::write(home_b.join("fixture-model"), "synthetic-other").unwrap();
    select_profile(&mut engine, &id, &account);
    let mut seeded = engine.store.thread(&id).unwrap();
    seeded["draft"] = json!("  exact unsent café\n  ");
    seeded["future"] = json!({"retain":[true,"中文"]});
    engine.store.save(&seeded).unwrap();
    let before = engine.store.thread(&id).unwrap();
    denied(
        &mut engine,
        "providers.codex.profiles.models.select",
        access_request(
            &before,
            &account,
            "synthetic-access",
            Some("forged"),
            "fullAccess",
        ),
    );
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    let first = start_catalog(&mut engine, &id, &account);
    assert_eq!(
        wait_catalog(&mut engine, &id, &account, &first)["state"],
        "ready"
    );
    choose(
        &mut engine,
        &id,
        &account,
        "synthetic-access",
        first["requestId"].as_str(),
    );
    let before = engine.store.thread(&id).unwrap();
    let request = access_request(
        &before,
        &account,
        "synthetic-access",
        first["requestId"].as_str(),
        "fullAccess",
    );
    let external_before = records(&root).len();
    let elevated = call(
        &mut engine,
        "providers.codex.profiles.models.select",
        request.clone(),
    );
    let mut expected = before.clone();
    expected["accessMode"] = json!("fullAccess");
    assert_eq!(
        elevated, expected,
        "Changing access must preserve the full conversation/draft envelope"
    );
    assert_eq!(
        records(&root).len(),
        external_before,
        "A mode edit must not start a provider or send"
    );
    let caps = call(
        &mut engine,
        "agent.selection.capabilities",
        json!({"threadId":id}),
    );
    assert_eq!(caps["locked"], false);
    assert_eq!(caps["namedModels"]["fullAccessSupported"], true);
    assert_eq!(caps["namedModels"]["effortSupported"], false);
    let codex = caps["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["provider"] == "codex")
        .unwrap();
    assert_eq!(codex["interactionModes"], json!(["build"]));
    for stale in [
        request,
        access_request(
            &elevated,
            &other,
            "synthetic-access",
            first["requestId"].as_str(),
            "approval",
        ),
        access_request(
            &elevated,
            &account,
            "synthetic-other",
            first["requestId"].as_str(),
            "fullAccess",
        ),
        access_request(
            &elevated,
            &account,
            "synthetic-access",
            Some("wrong-generation"),
            "approval",
        ),
        access_request(&elevated, &account, "default", None, "fullAccess"),
    ] {
        // The first request still has the pre-edit expected approval mode.
        denied(&mut engine, "providers.codex.profiles.models.select", stale);
        assert_eq!(engine.store.thread(&id).unwrap(), elevated);
    }
    for field in ["expectedAccessMode", "expectedInteractionMode"] {
        let mut missing = access_request(
            &elevated,
            &account,
            "synthetic-access",
            first["requestId"].as_str(),
            "approval",
        );
        missing.as_object_mut().unwrap().remove(field);
        denied(
            &mut engine,
            "providers.codex.profiles.models.select",
            missing,
        );
    }
    for (field, value) in [
        ("interactionMode", json!("plan")),
        ("effort", json!("high")),
        ("speed", json!("priority")),
    ] {
        let mut unsupported = access_request(
            &elevated,
            &account,
            "synthetic-access",
            first["requestId"].as_str(),
            "fullAccess",
        );
        unsupported[field] = value;
        denied(
            &mut engine,
            "providers.codex.profiles.models.select",
            unsupported,
        );
    }
    assert_eq!(engine.store.thread(&id).unwrap(), elevated);
    fs::write(home.join("fixture-access"), "fullAccess").unwrap();
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"Explicit synthetic full access turn"}),
    );
    settle(&mut engine);
    let calls = records(&root);
    let actual = calls
        .iter()
        .find(|row| row["method"] == "turn/start")
        .unwrap();
    assert_eq!(actual["home"], json!(home));
    assert_eq!(actual["params"]["approvalPolicy"], "never");
    assert_eq!(
        actual["params"]["sandboxPolicy"],
        json!({"type":"dangerFullAccess"})
    );
    assert!(!calls.iter().any(|row| row["method"] == "thread/resume"));
    assert_eq!(
        engine.store.thread(&id).unwrap()["selection"]["accountID"],
        account
    );
    drop(engine);
    // Saved full access survives restart but cannot send or borrow a default proof.
    let mut engine = Engine::new(Store::open(&db).unwrap());
    engine.set_active_thread(Some(id.clone())).unwrap();
    let restored = engine.store.thread(&id).unwrap();
    assert_eq!(restored["accessMode"], "fullAccess");
    let caps = call(
        &mut engine,
        "agent.selection.capabilities",
        json!({"threadId":id}),
    );
    assert_eq!(caps["locked"], true);
    assert_eq!(caps["namedModels"]["refreshAllowed"], true);
    assert_eq!(caps["namedModels"]["fullAccessSupported"], false);
    let count = records(&root).len();
    denied(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"Must not send before fresh profile proof"}),
    );
    assert_eq!(engine.store.thread(&id).unwrap(), restored);
    assert_eq!(records(&root).len(), count);
    let restarted_refresh = start_catalog(&mut engine, &id, &account);
    assert_eq!(
        wait_catalog(&mut engine, &id, &account, &restarted_refresh)["state"],
        "ready"
    );
    let recovered = call(
        &mut engine,
        "agent.selection.capabilities",
        json!({"threadId":id}),
    );
    assert_eq!(recovered["locked"], false);
    assert_eq!(recovered["namedModels"]["fullAccessSupported"], true);
    assert_eq!(engine.store.thread(&id).unwrap(), restored);
    // A failed later generation revokes that recovered proof, and still
    // permits the explicit reduction to approval/provider default.
    fs::write(home.join("fixture-mode"), "deny").unwrap();
    let failed = start_catalog(&mut engine, &id, &account);
    assert_eq!(
        wait_catalog(&mut engine, &id, &account, &failed)["state"],
        "failed"
    );
    let count = records(&root).len();
    // Explicit combined approval/default repair is available without new RPC.
    let repaired = call(
        &mut engine,
        "providers.codex.profiles.models.select",
        access_request(&restored, &account, "default", None, "approval"),
    );
    let mut expected = restored;
    expected["accessMode"] = json!("approval");
    expected["selection"]["modelID"] = json!("default");
    assert_eq!(repaired, expected);
    assert_eq!(records(&root).len(), count);
    fs::write(home.join("fixture-mode"), "allow").unwrap();
    let refreshed = start_catalog(&mut engine, &id, &account);
    assert_eq!(
        wait_catalog(&mut engine, &id, &account, &refreshed)["state"],
        "ready"
    );
    let elevated = call(
        &mut engine,
        "providers.codex.profiles.models.select",
        access_request(
            &repaired,
            &account,
            "synthetic-access",
            refreshed["requestId"].as_str(),
            "fullAccess",
        ),
    );
    // A captured auth-generation change after thread/start stops before turn/start.
    fs::write(home.join("fixture-mode"), "revoke-after-start").unwrap();
    let turns = records(&root)
        .iter()
        .filter(|row| row["method"] == "turn/start")
        .count();
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"Reject changed profile auth before full access"}),
    );
    settle(&mut engine);
    assert_eq!(
        records(&root)
            .iter()
            .filter(|row| row["method"] == "turn/start")
            .count(),
        turns
    );
    fs::remove_file(home.join("auth.json")).unwrap();
    fs::write(home.join("fixture-mode"), "hold-turn").unwrap();
    let refreshed = start_catalog(&mut engine, &id, &account);
    assert_eq!(
        wait_catalog(&mut engine, &id, &account, &refreshed)["state"],
        "ready"
    );
    let before = engine.store.thread(&id).unwrap();
    assert_eq!(before["selection"], elevated["selection"]);
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"Owned full access cancellation"}),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    while !home.join("turn-held").exists() {
        engine.poll();
        assert!(
            Instant::now() < deadline,
            "fake full-access turn was not held"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
    let running = engine.store.thread(&id).unwrap();
    denied(
        &mut engine,
        "providers.codex.profiles.models.select",
        access_request(
            &running,
            &account,
            "synthetic-access",
            refreshed["requestId"].as_str(),
            "approval",
        ),
    );
    call(&mut engine, "agent.stop", json!({"threadId":id}));
    settle(&mut engine);
    let workers = engine.provider_workers_status();
    assert_eq!(workers.running, 0);
    assert_eq!(workers.panicked, 0);
    assert_eq!(workers.unclassified, 0);
    let calls = records(&root);
    assert_eq!(
        calls
            .iter()
            .filter(|row| row["method"] == "turn/start")
            .count(),
        2
    );
    assert!(
        calls
            .iter()
            .filter(|row| row["method"] == "turn/start")
            .all(|row| row["home"] == json!(home) && row["params"]["approvalPolicy"] == "never")
    );
    assert!(
        !calls
            .iter()
            .any(|row| row["home"] == json!(home_b) || row["method"] == "thread/resume")
    );
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["future"], seeded["future"]);
    assert_eq!(saved["selection"]["accountID"], account);
}
