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
fn named_speed_uses_exact_account_catalog_and_captured_turn_policy() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let exe = root.join("fake-speed");
    fs::write(&exe,r#"#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(__file__).parent
home=Path(os.environ['CODEX_HOME'])
named='-c' in sys.argv
if named:
 assert home.parent.name=='codex' and home.parent.parent.name=='providers'
 for key in ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','CHATGPT_BASE_URL','HTTPS_PROXY','COINCIDE_SPEED_ROOT']:
  assert key not in os.environ,key
 for flag in ['cli_auth_credentials_store="file"','forced_login_method="chatgpt"','model_provider="openai"']:
  assert flag in sys.argv,flag
 assert 'coincide-unbound-' in os.environ['COINCIDE_CONTROL_SOCKET']
else:assert home==root/'default-home'
mode=(home/'fixture-mode').read_text() if (home/'fixture-mode').exists() else 'allow'
model=(home/'fixture-model').read_text() if named else 'synthetic-b'
tier=(home/'fixture-speed').read_text() if named else 'priority'
ack=(home/'fixture-ack').read_text() if (home/'fixture-ack').exists() else 'missing'
def record(v):
 with (root/'speed-calls.jsonl').open('a') as f:f.write(json.dumps({'home':str(home),'cwd':os.getcwd(),'named':named,**v})+'\n')
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
 advertised='priority' if not named or model=='synthetic-a' else 'ultrafast'
 row={'model':model,'serviceTiers':[{'id':advertised,'name':'Synthetic '+advertised}]}
 if named and model=='synthetic-a':row['supportedReasoningEfforts']=[{'reasoningEffort':'high'}]
 write({'id':r['id'],'result':{'data':[row,{'model':'default','serviceTiers':[{'id':'priority','name':'Synthetic hostile default'}]},{'model':'gpt-6-astra','serviceTiers':[{'id':'priority','name':'Synthetic hostile Astra'}]}],'nextCursor':None}})
 sys.stdin.readline();sys.exit(0)
assert named and r['method']=='thread/start' and r['params']['model']==model
assert r['params']['approvalPolicy']=='untrusted' and r['params']['sandbox']=='read-only'
native=home.name+'-speed-session'
result={'thread':{'id':native},'model':model}
if ack!='missing':result['serviceTier']=ack
write({'id':r['id'],'result':result})
r=read();assert r['method']=='turn/start'
assert r['params']['model']==model
if tier=='omit':assert 'serviceTier' not in r['params'],r['params']
else:assert r['params']['serviceTier']==tier,r['params']
expected_effort='high' if model=='synthetic-a' else None
if expected_effort is None:assert 'effort' not in r['params']
else:assert r['params']['effort']==expected_effort
assert r['params']['collaborationMode']=={'mode':'default','settings':{'model':model,'reasoning_effort':expected_effort,'developer_instructions':None}}
assert r['params']['approvalPolicy']=='untrusted' and r['params']['sandboxPolicy']=={'type':'readOnly'}
write({'id':r['id'],'result':{'turn':{'id':'synthetic-speed-turn'}}})
if mode=='hold-turn':
 (home/'turn-held').write_text('ready');sys.stdin.readline();sys.exit(0)
write({'method':'turn/completed','params':{'threadId':native,'turn':{'id':'synthetic-speed-turn','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o700)).unwrap();
    let out = Command::new(std::env::current_exe().unwrap())
        .args(["--ignored", "--exact", "speed_fixture_child", "--nocapture"])
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap())
        .env("HOME", &root)
        .env("COINCIDE_SPEED_ROOT", &root)
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
    fs::read_to_string(root.join("speed-calls.jsonl"))
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
fn params(e: &Engine, id: &str, model: &str, speed: Value, request: Option<&Value>) -> Value {
    let t = e.store.thread(id).unwrap();
    let mut p = json!({"threadId":id,"accountId":t["selection"]["accountID"],"expectedSelection":t["selection"],"model":model,"speed":speed,"expectedAccessMode":t["accessMode"],"expectedInteractionMode":t["interactionMode"]});
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
fn choose(e: &mut Engine, id: &str, _root: &Path, model: &str, speed: &str, r: &Value) -> Value {
    let before = e.store.thread(id).unwrap();
    let p = params(e, id, model, json!(speed), Some(r));
    let actual = call(e, SELECT, p);
    let mut expected = before;
    expected["selection"]["modelID"] = json!(model);
    expected["selection"]["speed"] = json!(speed);
    assert_eq!(actual, expected);
    assert_eq!(
        e.store.document("speed-fixture.json").unwrap(),
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
fn speed_fixture_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_SPEED_ROOT").unwrap());
    assert_eq!(root, root.canonicalize().unwrap());
    let db = root.join("state/state.sqlite");
    let mut e = Engine::new(Store::open(&db).unwrap());
    let project = call(
        &mut e,
        "projects.create",
        json!({"path":root,"name":"Synthetic speed"}),
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
    let mut original = e.store.thread(&id).unwrap();
    original["draft"] = json!("Synthetic retained café draft");
    original["future"] = json!({"opaque":[true,42]});
    original["draftContext"] = json!([{"id":uuid::Uuid::new_v4(),"kind":"quote","text":"Synthetic retained speed context","future":{"keep":true}}]);
    original["sessions"] = json!({"claude":{"sessionID":"synthetic-historical","seenItemCount":0,"future":{"keep":true}}});
    e.store.save(&original).unwrap();
    e.store
        .save_document("speed-fixture.json", &json!({"future":{"keep":17}}))
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
    for (h, model, tier) in [
        (&ha, "synthetic-a", "priority"),
        (&hb, "synthetic-b", "ultrafast"),
    ] {
        fs::write(h.join("fixture-model"), model).unwrap();
        fs::write(h.join("fixture-speed"), tier).unwrap();
    }
    select_profile(&mut e, &id, &a);
    let baseline = raw(&root);
    let first = refresh(&mut e, &id);
    assert_eq!(first["state"], "ready");
    assert_eq!(raw(&root), baseline);
    let second = refresh(&mut e, &id);
    assert_eq!(second["state"], "ready");
    let stale = params(&e, &id, "synthetic-a", json!("priority"), Some(&first));
    refuse(&mut e, &root, SELECT, stale);
    for (model, tier) in [
        ("synthetic-a", "ultrafast"),
        ("default", "priority"),
        ("gpt-6-astra", "priority"),
        ("synthetic-b", "ultrafast"),
    ] {
        let p = params(&e, &id, model, json!(tier), Some(&second));
        refuse(&mut e, &root, SELECT, p);
    }
    for field in [
        "expectedAccessMode",
        "expectedInteractionMode",
        "expectedSelection",
    ] {
        let mut p = params(&e, &id, "synthetic-a", json!("priority"), Some(&second));
        p.as_object_mut().unwrap().remove(field);
        refuse(&mut e, &root, SELECT, p);
    }
    let mut stale = params(&e, &id, "synthetic-a", json!("priority"), Some(&second));
    stale["expectedInteractionMode"] = json!("plan");
    refuse(&mut e, &root, SELECT, stale);
    let speed_only = choose(&mut e, &id, &root, "synthetic-a", "priority", &second);
    // Combine both options through the authenticated exact-profile API before
    // the same A turns; all Standard resets retain the separately chosen effort.
    let mut combined = params(&e, &id, "synthetic-a", json!("priority"), Some(&second));
    combined["effort"] = json!("high");
    let chosen = call(&mut e, SELECT, combined);
    let mut expected = speed_only;
    expected["selection"]["effort"] = json!("high");
    assert_eq!(chosen, expected);
    let caps = call(
        &mut e,
        "agent.selection.capabilities",
        json!({"threadId":id}),
    );
    assert_eq!(caps["namedModels"]["speedSupported"], true);
    assert_eq!(caps["namedModels"]["effortSupported"], true);
    let c = caps["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["provider"] == "codex")
        .unwrap();
    assert_eq!(c["speed"]["choices"].as_array().unwrap().len(), 1);
    assert_eq!(c["speed"]["choices"][0]["id"], "priority");
    assert_eq!(c["speed"]["provenance"], "named_profile_model_list");
    assert_eq!(c["effort"]["choices"], json!(["high"]));
    let omitted = call(
        &mut e,
        SELECT,
        json!({"threadId":id,"accountId":a,"expectedSelection":chosen["selection"],"model":"synthetic-a","requestId":second["requestId"]}),
    );
    assert_eq!(omitted, chosen);
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"Synthetic A priority turn"}),
    );
    settle(&mut e);
    let after = e.store.thread(&id).unwrap();
    assert_eq!(after["future"], original["future"]);
    assert_eq!(after["sessions"]["claude"], original["sessions"]["claude"]);
    assert_eq!(after["draft"], "");
    assert!(after["draftContext"].is_null());
    // Null is Standard, never an inferred faster tier. Only the actual owned
    // thread ACK can require a literal reset. Each process is a fresh session.
    let before = e.store.thread(&id).unwrap();
    let clear = params(&e, &id, "synthetic-a", Value::Null, None);
    let cleared = call(&mut e, SELECT, clear);
    let mut expected = before;
    expected["selection"]["speed"] = Value::Null;
    assert_eq!(cleared, expected);
    assert_eq!(cleared["selection"]["effort"], "high");
    for (ack, expected_tier) in [
        ("priority", "default"),
        ("missing", "omit"),
        ("default", "omit"),
    ] {
        fs::write(ha.join("fixture-ack"), ack).unwrap();
        fs::write(ha.join("fixture-speed"), expected_tier).unwrap();
        call(
            &mut e,
            "agent.send",
            json!({"threadId":id,"text":format!("Synthetic Standard with owned ACK {ack}")}),
        );
        settle(&mut e);
    }
    let mut repair = params(&e, &id, "default", Value::Null, None);
    repair["accessMode"] = json!("approval");
    repair["effort"] = Value::Null;
    call(&mut e, SELECT, repair);
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
    let p = params(&e, &id, "synthetic-b", json!("priority"), Some(&default));
    refuse(&mut e, &root, SELECT, p);
    let rb = refresh(&mut e, &id);
    assert_eq!(rb["state"], "ready");
    let p = params(&e, &id, "synthetic-b", json!("priority"), Some(&rb));
    refuse(&mut e, &root, SELECT, p);
    let p = params(&e, &id, "synthetic-a", json!("priority"), Some(&second));
    refuse(&mut e, &root, SELECT, p);
    choose(&mut e, &id, &root, "synthetic-b", "ultrafast", &rb);
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"Synthetic B ultrafast turn"}),
    );
    settle(&mut e);
    let saved = e.store.thread(&id).unwrap();
    let saved_raw = raw(&root);
    let mut receipts = finish(&mut e, 5);
    drop(e);
    let mut e = Engine::new(Store::open(&db).unwrap());
    e.set_active_thread(Some(id.clone())).unwrap();
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"Stored speed has no restarted authority"}),
    );
    assert_eq!(raw(&root), saved_raw);
    assert_eq!(refresh(&mut e, &id)["state"], "ready");
    assert_eq!(raw(&root), saved_raw);
    receipts += finish(&mut e, 0);
    drop(e);
    let mut e = Engine::new(Store::open(&db).unwrap());
    e.set_active_thread(Some(id.clone())).unwrap();
    let wrong = params(&e, &id, "synthetic-b", Value::Null, Some(&rb));
    refuse(&mut e, &root, SELECT, wrong);
    let clear = params(&e, &id, "synthetic-b", Value::Null, None);
    let cleared = call(&mut e, SELECT, clear);
    let mut expected = saved;
    expected["selection"]["speed"] = Value::Null;
    assert_eq!(cleared, expected);
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"Standard repair cannot unlock an unproved model"}),
    );
    let again = refresh(&mut e, &id);
    choose(&mut e, &id, &root, "synthetic-b", "ultrafast", &again);
    e.set_active_thread(Some(text(&other, "id"))).unwrap();
    let p = params(&e, &id, "synthetic-b", json!("ultrafast"), Some(&again));
    refuse(&mut e, &root, SELECT, p);
    e.set_active_thread(Some(id.clone())).unwrap();
    let again = refresh(&mut e, &id);
    choose(&mut e, &id, &root, "synthetic-b", "ultrafast", &again);
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
        json!({"threadId":id,"text":"No cwd borrowing"}),
    );
    e.store.save(&current).unwrap();
    let again = refresh(&mut e, &id);
    choose(&mut e, &id, &root, "synthetic-b", "ultrafast", &again);
    let exe = root.join("fake-speed");
    let bytes = fs::read(&exe).unwrap();
    let mut changed = bytes.clone();
    changed.extend_from_slice(b"\n# synthetic executable revision\n");
    fs::write(&exe, changed).unwrap();
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"No executable borrowing"}),
    );
    fs::write(exe, bytes).unwrap();
    fs::write(hb.join("fixture-mode"), "deny").unwrap();
    assert_eq!(refresh(&mut e, &id)["state"], "failed");
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"Failed latest job cannot fall back"}),
    );
    fs::write(hb.join("fixture-mode"), "allow").unwrap();
    let again = refresh(&mut e, &id);
    choose(&mut e, &id, &root, "synthetic-b", "ultrafast", &again);
    fs::write(
        hb.join("auth.json"),
        "synthetic identity change, not credentials",
    )
    .unwrap();
    fs::set_permissions(hb.join("auth.json"), fs::Permissions::from_mode(0o600)).unwrap();
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"No auth-file borrowing"}),
    );
    let again = refresh(&mut e, &id);
    choose(&mut e, &id, &root, "synthetic-b", "ultrafast", &again);
    fs::write(hb.join("fixture-mode"), "hold-turn").unwrap();
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"Captured ultrafast until owned stop"}),
    );
    marker(&hb.join("turn-held"));
    // Drain the Session event that causally precedes turn/start before taking
    // the refusal baseline. No turn completion or alternative result is used.
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
    receipts += finish(&mut e, 1);
    assert_eq!(receipts, 6);
    assert_eq!(e.store.thread(&text(&other, "id")).unwrap(), other);
    assert_eq!(
        e.store.document("speed-fixture.json").unwrap(),
        Some(json!({"future":{"keep":17}}))
    );
    let stored = e.store.thread(&id).unwrap();
    for account in [&a, &b] {
        let mut scoped = stored.clone();
        scoped["selection"]["accountID"] = json!(account);
        assert_eq!(
            provider_session(&scoped, "codex"),
            Some(format!("{account}-speed-session"))
        );
    }
    let calls = records(&root);
    let turns: Vec<_> = calls
        .iter()
        .filter(|r| r["method"] == "turn/start")
        .collect();
    assert_eq!(turns.len(), 6);
    for (index, home, tier) in [
        (0, &ha, Some("priority")),
        (1, &ha, Some("default")),
        (2, &ha, None),
        (3, &ha, None),
        (4, &hb, Some("ultrafast")),
        (5, &hb, Some("ultrafast")),
    ] {
        assert_eq!(turns[index]["home"], json!(home));
        let expected_effort = if home == &ha { Some("high") } else { None };
        if let Some(effort) = expected_effort {
            assert_eq!(turns[index]["params"]["effort"], effort);
        } else {
            assert!(turns[index]["params"].get("effort").is_none());
        }
        assert_eq!(
            turns[index]["params"]["collaborationMode"]["settings"]["reasoning_effort"],
            json!(expected_effort)
        );
        match tier {
            Some(tier) => assert_eq!(turns[index]["params"]["serviceTier"], tier),
            None => assert!(turns[index]["params"].get("serviceTier").is_none()),
        }
    }
    assert!(
        turns[0]["params"]["input"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Synthetic retained speed context")
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
