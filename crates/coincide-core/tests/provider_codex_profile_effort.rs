//! Real Engine, Store and owned fake app-server processes; no live provider.
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
const SELECT: &str = "providers.codex.profiles.models.select";
const REFRESH: &str = "providers.codex.profiles.models.refresh";
const STATUS: &str = "providers.codex.profiles.models.status";
#[test]
fn named_effort_uses_exact_account_catalog_and_captured_turn_policy() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let exe = root.join("fake-effort");
    fs::write(&exe,r#"#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(__file__).parent
home=Path(os.environ['CODEX_HOME'])
named='-c' in sys.argv
if named:
 assert home.parent.name=='codex' and home.parent.parent.name=='providers'
 for key in ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','CHATGPT_BASE_URL','HTTPS_PROXY','COINCIDE_EFFORT_ROOT']:
  assert key not in os.environ,key
 for flag in ['cli_auth_credentials_store="file"','forced_login_method="chatgpt"','model_provider="openai"']:
  assert flag in sys.argv,flag
 assert 'coincide-unbound-' in os.environ['COINCIDE_CONTROL_SOCKET']
else:assert home==root/'default-home'
mode=(home/'fixture-mode').read_text() if (home/'fixture-mode').exists() else 'allow'
model=(home/'fixture-model').read_text() if named else 'synthetic-default'
effort=(home/'fixture-effort').read_text() if named else 'high'
def record(v):
 with (root/'effort-calls.jsonl').open('a') as f:f.write(json.dumps({'home':str(home),'cwd':os.getcwd(),'named':named,**v})+'\n')
def read():
 line=sys.stdin.readline()
 if not line:sys.exit(0)
 v=json.loads(line);record({'method':v.get('method'),'params':v.get('params')});return v
def write(v):print(json.dumps(v),flush=True)
record({'pid':os.getpid()})
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read()
if named:
 assert r['method']=='account/read' and r['params']=={'refreshToken':False}
 if mode=='block':
  (home/'blocked').write_text('ready');sys.stdin.readline();sys.exit(0)
 write({'id':r['id'],'result':{'requiresOpenaiAuth':True,'account':None if mode=='deny' else {'type':'chatgpt','email':'synthetic@example.invalid','planType':'plus'}}})
 r=read()
if r['method']=='model/list':
 if mode=='auth-change':write({'method':'account/updated','params':{}})
 choices=['low','high'] if named and model=='synthetic-a' else ['medium'] if named else ['high']
 write({'id':r['id'],'result':{'data':[{'model':model,'supportedReasoningEfforts':[{'reasoningEffort':x} for x in choices],'defaultReasoningEffort':choices[0]},{'model':'default','supportedReasoningEfforts':[{'reasoningEffort':'high'}]},{'model':'gpt-6-astra','supportedReasoningEfforts':[{'reasoningEffort':'high'}]}],'nextCursor':None}})
 sys.stdin.readline();sys.exit(0)
assert named and r['method']=='thread/start' and r['params']['model']==model
assert r['params']['approvalPolicy']=='untrusted' and r['params']['sandbox']=='read-only'
native=home.name+'-effort-session'
write({'id':r['id'],'result':{'thread':{'id':native},'model':model}})
r=read();assert r['method']=='turn/start'
assert r['params']['model']==model and r['params']['effort']==effort
assert r['params']['collaborationMode']=={'mode':'default','settings':{'model':model,'reasoning_effort':effort,'developer_instructions':None}}
assert r['params']['approvalPolicy']=='untrusted' and r['params']['sandboxPolicy']=={'type':'readOnly'}
write({'id':r['id'],'result':{'turn':{'id':'synthetic-effort-turn'}}})
if mode=='hold-turn':
 (home/'turn-held').write_text('ready');sys.stdin.readline();sys.exit(0)
write({'method':'turn/completed','params':{'threadId':native,'turn':{'id':'synthetic-effort-turn','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o700)).unwrap();
    let out = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "effort_fixture_child",
            "--nocapture",
        ])
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap())
        .env("HOME", &root)
        .env("COINCIDE_EFFORT_ROOT", &root)
        .env("COINCIDE_CODEX_EXECUTABLE", &exe)
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
        out.status.success(),
        "{} {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
}
fn call(e: &mut Engine, m: &str, p: Value) -> Value {
    let v = e.dispatch(json!({"method":m,"params":p}));
    assert!(v.get("error").is_none(), "{v}");
    v["result"].clone()
}
fn records(root: &Path) -> Vec<Value> {
    fs::read_to_string(root.join("effort-calls.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}
type Raw = Vec<Vec<Vec<rusqlite::types::Value>>>;
fn raw(root: &Path) -> Raw {
    let db = rusqlite::Connection::open_with_flags(
        root.join("state/state.sqlite"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
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
        let mut s = db.prepare(sql).unwrap();
        let n = s.column_count();
        s.query_map([], |r| {
            (0..n)
                .map(|i| r.get(i))
                .collect::<rusqlite::Result<Vec<_>>>()
        })
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap()
    })
    .collect()
}
fn refuse(e: &mut Engine, root: &Path, m: &str, p: Value) {
    let before = raw(root);
    let count = records(root).len();
    assert!(
        e.dispatch(json!({"method":m,"params":p}))
            .get("error")
            .is_some(),
        "{m} must refuse"
    );
    assert_eq!(raw(root), before);
    assert_eq!(
        records(root).len(),
        count,
        "refusal must precede process launch"
    );
}
fn params(e: &Engine, id: &str, model: &str, effort: Value, request: Option<&Value>) -> Value {
    let t = e.store.thread(id).unwrap();
    let mut p = json!({"threadId":id,"accountId":t["selection"]["accountID"],"expectedSelection":t["selection"],"model":model,"effort":effort,"expectedAccessMode":t["accessMode"],"expectedInteractionMode":t["interactionMode"]});
    if let Some(r) = request {
        p["requestId"] = r["requestId"].clone();
    }
    p
}
fn refresh(e: &mut Engine, id: &str) -> Value {
    let t = e.store.thread(id).unwrap();
    let r = call(
        e,
        REFRESH,
        json!({"threadId":id,"accountId":t["selection"]["accountID"],"expectedSelection":t["selection"]}),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let v = call(
            e,
            STATUS,
            json!({"threadId":id,"accountId":t["selection"]["accountID"],"requestId":r["requestId"]}),
        );
        if v["state"] != "loading" {
            return v;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn select_profile(e: &mut Engine, id: &str, account: &str) {
    let t = e.store.thread(id).unwrap();
    call(
        e,
        "providers.codex.profiles.select",
        json!({"threadId":id,"accountId":account,"expectedSelection":t["selection"]}),
    );
}
fn choose(e: &mut Engine, id: &str, _root: &Path, model: &str, effort: &str, r: &Value) -> Value {
    let before = e.store.thread(id).unwrap();
    let p = params(e, id, model, json!(effort), Some(r));
    let actual = call(e, SELECT, p);
    let mut expected = before;
    expected["selection"]["modelID"] = json!(model);
    expected["selection"]["effort"] = json!(effort);
    assert_eq!(actual, expected);
    assert_eq!(
        e.store.document("effort-fixture.json").unwrap(),
        Some(json!({"future":{"keep":17}}))
    );
    actual
}
fn settle(e: &mut Engine) {
    let d = Instant::now() + Duration::from_secs(10);
    loop {
        let s = call(e, "app.status", json!({}));
        if s["running"].as_array().unwrap().is_empty() && e.provider_workers_status().running == 0 {
            break;
        }
        assert!(Instant::now() < d);
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn finish(e: &mut Engine, expected_provider_returns: u64) -> u64 {
    e.freeze_admissions();
    e.request_model_catalog_shutdown().unwrap();
    let d = Instant::now() + Duration::from_secs(10);
    loop {
        let s = e.model_catalog_shutdown_status().unwrap();
        if s.running == 0 {
            assert_eq!(s.panicked, 0);
            assert_eq!(s.unclassified, 0);
            assert!(s.returned > 0);
            break;
        }
        assert!(Instant::now() < d);
        std::thread::sleep(Duration::from_millis(2));
    }
    let workers = e.provider_workers_status();
    assert_eq!(workers.running, 0);
    assert_eq!(workers.panicked, 0);
    assert_eq!(workers.unclassified, 0);
    assert_eq!(
        workers.returned, expected_provider_returns,
        "Each Engine must retain its own exact provider join receipts"
    );
    workers.returned
}
fn marker(p: &Path) {
    let d = Instant::now() + Duration::from_secs(10);
    while !p.exists() {
        assert!(Instant::now() < d);
        std::thread::sleep(Duration::from_millis(2));
    }
}
#[test]
#[ignore = "Outer test supplies cleared environment, canonical private HOME and fake executable"]
fn effort_fixture_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_EFFORT_ROOT").unwrap());
    assert_eq!(root, root.canonicalize().unwrap());
    let db = root.join("state/state.sqlite");
    let mut e = Engine::new(Store::open(&db).unwrap());
    let project = call(
        &mut e,
        "projects.create",
        json!({"path":root,"name":"Synthetic effort"}),
    );
    let t = call(&mut e, "threads.create", json!({"projectId":project["id"]}));
    let id = text(&t, "id");
    let other = call(&mut e, "threads.create", json!({"projectId":project["id"]}));
    e.set_active_thread(Some(id.clone())).unwrap();
    call(
        &mut e,
        "agent.select",
        json!({"threadId":id,"provider":"codex","model":"default"}),
    );
    let mut t = e.store.thread(&id).unwrap();
    t["draft"] = json!("Synthetic retained café 中文 draft");
    t["future"] = json!({"opaque":[true,42]});
    t["draftContext"] = json!([{"id":uuid::Uuid::new_v4(),"kind":"quote","text":"Synthetic retained context","future":{"keep":true}}]);
    t["sessions"] = json!({"claude":{"sessionID":"synthetic-historical","seenItemCount":0,"future":{"keep":true}}});
    e.store.save(&t).unwrap();
    e.store
        .save_document("effort-fixture.json", &json!({"future":{"keep":17}}))
        .unwrap();
    let a = call(
        &mut e,
        "providers.codex.profiles.create",
        json!({"name":"Synthetic A"}),
    );
    let a = text(&a, "id");
    let b = call(
        &mut e,
        "providers.codex.profiles.create",
        json!({"name":"Synthetic B"}),
    );
    let b = text(&b, "id");
    let data = e.store.data_directory().unwrap();
    let ha = data.join("providers/codex").join(&a);
    let hb = data.join("providers/codex").join(&b);
    for (h, m, f) in [(&ha, "synthetic-a", "high"), (&hb, "synthetic-b", "medium")] {
        fs::write(h.join("fixture-model"), m).unwrap();
        fs::write(h.join("fixture-effort"), f).unwrap();
    }
    select_profile(&mut e, &id, &a);
    let baseline = raw(&root);
    let first = refresh(&mut e, &id);
    assert_eq!(first["state"], "ready");
    assert_eq!(raw(&root), baseline);
    let second = refresh(&mut e, &id);
    assert_eq!(second["state"], "ready");
    let stale = params(&e, &id, "synthetic-a", json!("high"), Some(&first));
    refuse(&mut e, &root, SELECT, stale);
    for (model, effort) in [
        ("synthetic-a", "medium"),
        ("default", "high"),
        ("gpt-6-astra", "high"),
        ("synthetic-b", "medium"),
    ] {
        let p = params(&e, &id, model, json!(effort), Some(&second));
        refuse(&mut e, &root, SELECT, p);
    }
    for field in [
        "expectedAccessMode",
        "expectedInteractionMode",
        "expectedSelection",
    ] {
        let mut p = params(&e, &id, "synthetic-a", json!("high"), Some(&second));
        p.as_object_mut().unwrap().remove(field);
        refuse(&mut e, &root, SELECT, p);
    }
    let mut stale = params(&e, &id, "synthetic-a", json!("high"), Some(&second));
    stale["expectedAccessMode"] = json!("fullAccess");
    refuse(&mut e, &root, SELECT, stale);
    let chosen = choose(&mut e, &id, &root, "synthetic-a", "high", &second);
    let caps = call(
        &mut e,
        "agent.selection.capabilities",
        json!({"threadId":id}),
    );
    assert_eq!(caps["namedModels"]["effortSupported"], true);
    let pc = caps["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["provider"] == "codex")
        .unwrap();
    assert_eq!(pc["effort"]["choices"], json!(["low", "high"]));
    assert_eq!(pc["effort"]["provenance"], "named_profile_model_list");
    // Omission is preservation, not a request to clear the selected effort.
    let same = call(
        &mut e,
        SELECT,
        json!({"threadId":id,"accountId":a,"expectedSelection":chosen["selection"],"model":"synthetic-a","requestId":second["requestId"]}),
    );
    assert_eq!(same, chosen);
    // Restored unsupported model metadata must never make advertised effort
    // buttons eligible, even when this exact private catalog reports that row.
    // Identity-only Refresh stays usable and does not mutate the saved record.
    let supported = e.store.thread(&id).unwrap();
    let supported_raw = raw(&root);
    let mut astra = supported.clone();
    astra["selection"]["modelID"] = json!("gpt-6-astra");
    e.store.save(&astra).unwrap();
    let astra_raw = raw(&root);
    for after_refresh in [false, true] {
        if after_refresh {
            assert_eq!(refresh(&mut e, &id)["state"], "ready");
        }
        let caps = call(
            &mut e,
            "agent.selection.capabilities",
            json!({"threadId":id}),
        );
        assert_eq!(caps["namedModels"]["refreshAllowed"], true);
        assert_eq!(caps["namedModels"]["effortSupported"], false);
        let effort = &caps["providers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["provider"] == "codex")
            .unwrap()["effort"];
        assert_eq!(effort["supported"], false);
        assert_eq!(effort["choices"], json!([]));
        assert_eq!(raw(&root), astra_raw);
        refuse(
            &mut e,
            &root,
            "agent.send",
            json!({"threadId":id,"text":"Restored Astra stays unavailable"}),
        );
    }
    e.store.save(&supported).unwrap();
    e.poll();
    assert_eq!(raw(&root), supported_raw);
    e.set_active_thread(Some(text(&other, "id"))).unwrap();
    let p = params(&e, &id, "synthetic-a", json!("high"), Some(&second));
    refuse(&mut e, &root, SELECT, p);
    e.set_active_thread(Some(id.clone())).unwrap();
    let fresh = refresh(&mut e, &id);
    choose(&mut e, &id, &root, "synthetic-a", "high", &fresh);
    // Each successful Send deliberately consumes its exact saved draft/context;
    // the fake validates actual payload and preserved unrelated session fields.
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"Synthetic A effort turn"}),
    );
    settle(&mut e);
    let sent = e.store.thread(&id).unwrap();
    assert_eq!(sent["future"], t["future"]);
    assert_eq!(sent["sessions"]["claude"], t["sessions"]["claude"]);
    assert_eq!(sent["draft"], "");
    assert!(sent["draftContext"].is_null());
    let p = params(&e, &id, "default", Value::Null, None);
    let mut p = p;
    p["accessMode"] = json!("approval");
    call(&mut e, SELECT, p);
    select_profile(&mut e, &id, &b);
    let default = call(&mut e, "agent.models.refresh", json!({"provider":"codex"}));
    let deadline = Instant::now() + Duration::from_secs(10);
    let default = loop {
        let v = call(
            &mut e,
            "agent.models.status",
            json!({"requestId":default["requestId"]}),
        );
        if v["state"] != "loading" {
            break v;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    };
    assert_eq!(default["state"], "ready");
    let borrowed = params(&e, &id, "synthetic-b", json!("high"), Some(&default));
    refuse(&mut e, &root, SELECT, borrowed);
    let rb = refresh(&mut e, &id);
    assert_eq!(rb["state"], "ready");
    let p = params(&e, &id, "synthetic-b", json!("high"), Some(&rb));
    refuse(&mut e, &root, SELECT, p);
    let p = params(&e, &id, "synthetic-a", json!("high"), Some(&fresh));
    refuse(&mut e, &root, SELECT, p);
    choose(&mut e, &id, &root, "synthetic-b", "medium", &rb);
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"Synthetic B effort turn"}),
    );
    settle(&mut e);
    let saved = e.store.thread(&id).unwrap();
    let saved_raw = raw(&root);
    let mut provider_returns = finish(&mut e, 2);
    drop(e);
    // Stored effort has no authority after restart; Refresh remains reachable.
    let mut e = Engine::new(Store::open(&db).unwrap());
    e.set_active_thread(Some(id.clone())).unwrap();
    let count = records(&root).len();
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"Must not borrow restart proof"}),
    );
    assert_eq!(records(&root).len(), count);
    assert_eq!(raw(&root), saved_raw);
    let reopened = refresh(&mut e, &id);
    assert_eq!(reopened["state"], "ready");
    assert_eq!(raw(&root), saved_raw);
    provider_returns += finish(&mut e, 0);
    drop(e);
    let mut e = Engine::new(Store::open(&db).unwrap());
    e.set_active_thread(Some(id.clone())).unwrap();
    let mut bad = params(&e, &id, "synthetic-b", Value::Null, Some(&rb));
    refuse(&mut e, &root, SELECT, bad.clone());
    bad.as_object_mut().unwrap().remove("requestId");
    let repaired = call(&mut e, SELECT, bad);
    let mut expected = saved.clone();
    expected["selection"]["effort"] = Value::Null;
    assert_eq!(repaired, expected);
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"Clearing effort cannot unlock unproved model"}),
    );
    let again = refresh(&mut e, &id);
    choose(&mut e, &id, &root, "synthetic-b", "medium", &again);
    // Current binding/proof cannot cross a changed cwd or executable identity.
    let cwd = root.join("different-cwd");
    fs::create_dir(&cwd).unwrap();
    let current = e.store.thread(&id).unwrap();
    let mut changed = current.clone();
    changed["worktreePath"] = json!(cwd);
    e.store.save(&changed).unwrap();
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"Must not cross cwd"}),
    );
    e.store.save(&current).unwrap();
    let again = refresh(&mut e, &id);
    choose(&mut e, &id, &root, "synthetic-b", "medium", &again);
    let exe = root.join("fake-effort");
    let bytes = fs::read(&exe).unwrap();
    let mut different = bytes.clone();
    different.extend_from_slice(b"\n# synthetic executable revision\n");
    fs::write(&exe, different).unwrap();
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"Must not cross executable identity"}),
    );
    fs::write(&exe, bytes).unwrap();
    fs::write(hb.join("fixture-mode"), "deny").unwrap();
    let failed = refresh(&mut e, &id);
    assert_eq!(failed["state"], "failed");
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"No fallback after auth denial"}),
    );
    fs::write(hb.join("fixture-mode"), "allow").unwrap();
    let again = refresh(&mut e, &id);
    choose(&mut e, &id, &root, "synthetic-b", "medium", &again);
    fs::write(
        hb.join("auth.json"),
        "synthetic auth-file identity marker, not credentials",
    )
    .unwrap();
    fs::set_permissions(hb.join("auth.json"), fs::Permissions::from_mode(0o600)).unwrap();
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"Must not cross auth-file identity"}),
    );
    let again = refresh(&mut e, &id);
    choose(&mut e, &id, &root, "synthetic-b", "medium", &again);
    fs::write(hb.join("fixture-mode"), "hold-turn").unwrap();
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"Captured medium option until cancellation"}),
    );
    marker(&hb.join("turn-held"));
    // The worker queued the new native Session before writing turn/start.
    // Drain that established boundary before the refused-edit raw baseline;
    // the fake still holds the turn, so this does not complete or retry it.
    call(&mut e, "app.status", json!({}));
    let p = params(&e, &id, "synthetic-b", Value::Null, None);
    refuse(&mut e, &root, SELECT, p);
    e.request_provider_stop(&id).unwrap();
    settle(&mut e);
    fs::write(hb.join("fixture-mode"), "block").unwrap();
    let current = e.store.thread(&id).unwrap();
    call(
        &mut e,
        REFRESH,
        json!({"threadId":id,"accountId":b,"expectedSelection":current["selection"]}),
    );
    marker(&hb.join("blocked"));
    provider_returns += finish(&mut e, 1);
    // Three actual turns across three distinct Engine owners: A+B, read-only
    // restart, then the held/cancelled B turn. Restart cannot carry counters.
    assert_eq!(provider_returns, 3);
    assert_eq!(e.store.thread(&text(&other, "id")).unwrap(), other);
    assert_eq!(
        e.store.document("effort-fixture.json").unwrap(),
        Some(json!({"future":{"keep":17}}))
    );
    let calls = records(&root);
    let stored = e.store.thread(&id).unwrap();
    for account in [&a, &b] {
        let mut scoped = stored.clone();
        scoped["selection"]["accountID"] = json!(account);
        assert_eq!(
            provider_session(&scoped, "codex"),
            Some(format!("{account}-effort-session"))
        );
    }
    let turns: Vec<_> = calls
        .iter()
        .filter(|r| r["method"] == "turn/start")
        .collect();
    assert_eq!(turns.len(), 3);
    assert_eq!(turns[0]["home"], json!(ha));
    assert_eq!(turns[0]["params"]["effort"], "high");
    assert_eq!(turns[1]["home"], json!(hb));
    assert_eq!(turns[1]["params"]["effort"], "medium");
    assert_eq!(turns[2]["params"]["effort"], "medium");
    assert!(
        turns[0]["params"]["input"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Synthetic retained context")
    );
    for r in calls {
        if let Some(m) = r["method"].as_str() {
            assert!(
                matches!(
                    m,
                    "initialize"
                        | "initialized"
                        | "account/read"
                        | "model/list"
                        | "thread/start"
                        | "turn/start"
                ),
                "unexpected RPC {m}"
            );
            if r["named"] == true {
                assert_eq!(r["cwd"], json!(root));
            }
        }
    }
}
