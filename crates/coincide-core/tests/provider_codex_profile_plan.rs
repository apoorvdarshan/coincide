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
fn named_plan_and_build_use_exact_profile_and_captured_collaboration_policy() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let exe = root.join("fake-plan");
    fs::write(&exe,r#"#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(__file__).parent
home=Path(os.environ['CODEX_HOME'])
named='-c' in sys.argv
if named:
 assert home.parent.name=='codex' and home.parent.parent.name=='providers'
 for key in ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','CHATGPT_BASE_URL','HTTPS_PROXY','COINCIDE_PLAN_ROOT']:
  assert key not in os.environ,key
 for flag in ['cli_auth_credentials_store="file"','forced_login_method="chatgpt"','model_provider="openai"']:
  assert flag in sys.argv,flag
 assert 'coincide-unbound-' in os.environ['COINCIDE_CONTROL_SOCKET']
else:assert home==root/'default-home'
mode=(home/'fixture-mode').read_text() if (home/'fixture-mode').exists() else 'allow'
model=(home/'fixture-model').read_text() if named else 'synthetic-b'
tier=(home/'fixture-speed').read_text() if named else 'priority'
collaboration=(home/'fixture-collaboration').read_text() if named else 'default'
access=(home/'fixture-access').read_text() if named else 'approval'
ack=(home/'fixture-ack').read_text() if (home/'fixture-ack').exists() else 'missing'
def record(v):
 with (root/'plan-calls.jsonl').open('a') as f:f.write(json.dumps({'home':str(home),'cwd':os.getcwd(),'named':named,**v})+'\n')
def read():
 line=sys.stdin.readline()
 if not line:sys.exit(0)
 v=json.loads(line);record({'method':v.get('method'),'params':v.get('params')});return v
def write(v):print(json.dumps(v),flush=True)
record({'pid':os.getpid()})
r=read();assert r['method']=='initialize' and r['params']['capabilities']['experimentalApi'] is True;write({'id':r['id'],'result':{}})
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
 if named:row['supportedReasoningEfforts']=[{'reasoningEffort':'high' if model=='synthetic-a' else 'medium'}]
 write({'id':r['id'],'result':{'data':[row,{'model':'default','serviceTiers':[{'id':'priority','name':'Synthetic hostile default'}]},{'model':'gpt-6-astra','serviceTiers':[{'id':'priority','name':'Synthetic hostile Astra'}]}],'nextCursor':None}})
 sys.stdin.readline();sys.exit(0)
assert named and r['method']=='thread/start' and r['params']['model']==model
assert r['params']['approvalPolicy']=='untrusted' and r['params']['sandbox']=='read-only'
native=home.name+'-plan-session'
result={'thread':{'id':native},'model':model}
if ack!='missing':result['serviceTier']=ack
write({'id':r['id'],'result':result})
r=read();assert r['method']=='turn/start'
assert r['params']['model']==model
if tier=='omit':assert 'serviceTier' not in r['params'],r['params']
else:assert r['params']['serviceTier']==tier,r['params']
expected_effort='high' if model=='synthetic-a' else 'medium'
assert r['params']['effort']==expected_effort
assert r['params']['collaborationMode']=={'mode':collaboration,'settings':{'model':model,'reasoning_effort':expected_effort,'developer_instructions':None}}
assert r['params']['approvalPolicy']==('never' if access=='fullAccess' else 'untrusted') and r['params']['sandboxPolicy']=={'type':'dangerFullAccess' if access=='fullAccess' else 'readOnly'}
write({'id':r['id'],'result':{'turn':{'id':'synthetic-plan-turn'}}})
if mode=='hold-turn':
 (home/'turn-held').write_text('ready');sys.stdin.readline();sys.exit(0)
write({'method':'turn/completed','params':{'threadId':native,'turn':{'id':'synthetic-plan-turn','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o700)).unwrap();
    let out = Command::new(std::env::current_exe().unwrap())
        .args(["--ignored", "--exact", "plan_fixture_child", "--nocapture"])
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap())
        .env("HOME", &root)
        .env("COINCIDE_PLAN_ROOT", &root)
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
    fs::read_to_string(root.join("plan-calls.jsonl"))
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
fn selection_params(e: &Engine, id: &str, catalog: Option<&Value>) -> Value {
    let t = e.store.thread(id).unwrap();
    let mut p = json!({"threadId":id,"accountId":t["selection"]["accountID"],"expectedSelection":t["selection"],"model":t["selection"]["modelID"]});
    for (saved, expected) in [
        ("accessMode", "expectedAccessMode"),
        ("interactionMode", "expectedInteractionMode"),
    ] {
        if let Some(value) = t.get(saved) {
            p[expected] = value.clone();
        }
    }
    if let Some(catalog) = catalog {
        p["requestId"] = catalog["requestId"].clone();
    }
    p
}
fn mode_params(e: &Engine, id: &str, mode: &str, catalog: Option<&Value>) -> Value {
    let mut p = selection_params(e, id, catalog);
    p["interactionMode"] = json!(mode);
    p
}
fn select_mode(e: &mut Engine, id: &str, mode: &str, catalog: Option<&Value>) -> Value {
    let mut expected = e.store.thread(id).unwrap();
    let request = mode_params(e, id, mode, catalog);
    expected["interactionMode"] = json!(mode);
    let actual = call(e, SELECT, request);
    assert_eq!(
        actual, expected,
        "Mode-only edits preserve every other field"
    );
    actual
}
fn configure(
    e: &mut Engine,
    id: &str,
    catalog: &Value,
    model: &str,
    mode: &str,
    effort: &str,
    speed: &str,
) {
    let mut expected = e.store.thread(id).unwrap();
    let mut p = mode_params(e, id, mode, Some(catalog));
    p["model"] = json!(model);
    p["effort"] = json!(effort);
    p["speed"] = json!(speed);
    expected["selection"]["modelID"] = json!(model);
    expected["selection"]["effort"] = json!(effort);
    expected["selection"]["speed"] = json!(speed);
    expected["interactionMode"] = json!(mode);
    assert_eq!(call(e, SELECT, p), expected);
}
fn send(e: &mut Engine, id: &str, home: &Path, mode: &str, access: &str, speed: &str) {
    fs::write(
        home.join("fixture-collaboration"),
        if mode == "plan" { "plan" } else { "default" },
    )
    .unwrap();
    fs::write(home.join("fixture-access"), access).unwrap();
    fs::write(home.join("fixture-speed"), speed).unwrap();
    call(
        e,
        "agent.send",
        json!({"threadId":id,"text":format!("Synthetic {mode}/{access} turn")}),
    );
    settle(e);
}
#[test]
#[ignore = "Outer test supplies cleared environment, canonical private HOME and fake executable"]
fn plan_fixture_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_PLAN_ROOT").unwrap());
    assert_eq!(root, root.canonicalize().unwrap());
    let db = root.join("state/state.sqlite");
    let mut e = Engine::new(Store::open(&db).unwrap());
    let project = call(
        &mut e,
        "projects.create",
        json!({"path":root,"name":"Synthetic Plan"}),
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
    original["draft"] = json!("Synthetic retained café Plan draft");
    original["future"] = json!({"opaque":[true,42]});
    original["draftContext"] = json!([{"id":uuid::Uuid::new_v4(),"kind":"quote","text":"Synthetic retained Plan context","future":{"keep":true}}]);
    original["sessions"] = json!({"claude":{"sessionID":"synthetic-historical","seenItemCount":0,"future":{"keep":true}}});
    e.store.save(&original).unwrap();
    e.store
        .save_document("plan-fixture.json", &json!({"future":{"keep":17}}))
        .unwrap();
    let a = text(
        &call(
            &mut e,
            "providers.codex.profiles.create",
            json!({"name":"Synthetic A"}),
        ),
        "id",
    );
    let b = text(
        &call(
            &mut e,
            "providers.codex.profiles.create",
            json!({"name":"Synthetic B"}),
        ),
        "id",
    );
    let data = e.store.data_directory().unwrap();
    let ha = data.join("providers/codex").join(&a);
    let hb = data.join("providers/codex").join(&b);
    for (h, model, tier) in [
        (&ha, "synthetic-a", "priority"),
        (&hb, "synthetic-b", "ultrafast"),
    ] {
        fs::write(h.join("fixture-model"), model).unwrap();
        fs::write(h.join("fixture-speed"), tier).unwrap();
        fs::write(h.join("fixture-collaboration"), "default").unwrap();
        fs::write(h.join("fixture-access"), "approval").unwrap();
    }
    select_profile(&mut e, &id, &a);
    let before = raw(&root);
    let first = refresh(&mut e, &id);
    assert_eq!(first["state"], "ready");
    assert_eq!(raw(&root), before, "Catalog refresh is not a thread edit");
    // Provider default cannot authorize Plan even with a real named catalog.
    let p = mode_params(&e, &id, "plan", Some(&first));
    refuse(&mut e, &root, SELECT, p);
    let second = refresh(&mut e, &id);
    assert_eq!(second["state"], "ready");
    for (model, effort, speed, mode, catalog) in [
        ("synthetic-a", "high", "priority", "plan", &first),
        ("synthetic-b", "medium", "ultrafast", "plan", &second),
        ("gpt-6-astra", "high", "priority", "plan", &second),
        ("synthetic-a", "low", "priority", "plan", &second),
        ("synthetic-a", "high", "ultrafast", "plan", &second),
        ("synthetic-a", "high", "priority", "unknown", &second),
    ] {
        let mut p = mode_params(&e, &id, mode, Some(catalog));
        p["model"] = json!(model);
        p["effort"] = json!(effort);
        p["speed"] = json!(speed);
        refuse(&mut e, &root, SELECT, p);
    }
    for field in [
        "expectedSelection",
        "expectedAccessMode",
        "expectedInteractionMode",
    ] {
        let mut p = mode_params(&e, &id, "plan", Some(&second));
        p["model"] = json!("synthetic-a");
        p.as_object_mut().unwrap().remove(field);
        refuse(&mut e, &root, SELECT, p);
    }
    // Retained ordinary rows can omit either mode. Omitted, explicit null
    // and text are three exact CAS baselines, not one normalized default.
    let mode_baseline = e.store.thread(&id).unwrap();
    let calls_before_modes = records(&root).len();
    for access in [None, Some(Value::Null), Some(json!("approval"))] {
        for interaction in [None, Some(Value::Null), Some(json!("build"))] {
            let mut shape = mode_baseline.clone();
            shape["selection"]["modelID"] = json!("synthetic-a");
            for (key, value) in [
                ("accessMode", access.clone()),
                ("interactionMode", interaction.clone()),
            ] {
                match value {
                    Some(value) => {
                        shape[key] = value;
                    }
                    None => {
                        shape.as_object_mut().unwrap().remove(key);
                    }
                }
            }
            e.store.save(&shape).unwrap();
            for (option, value) in [("effort", "high"), ("speed", "priority")] {
                let mut expected = e.store.thread(&id).unwrap();
                let mut p = selection_params(&e, &id, Some(&second));
                p[option] = json!(value);
                expected["selection"][option] = json!(value);
                assert_eq!(call(&mut e, SELECT, p), expected);
            }
            select_mode(&mut e, &id, "plan", Some(&second));
            select_mode(&mut e, &id, "build", None);
        }
    }
    assert_eq!(
        records(&root).len(),
        calls_before_modes,
        "Mode/options edits must not launch any process"
    );
    // Capture before a presence-only change, retaining the same selection.
    // Both directions, null and concrete values must fail before any write.
    for (mode, expected_key, text_value) in [
        ("accessMode", "expectedAccessMode", "approval"),
        ("interactionMode", "expectedInteractionMode", "build"),
    ] {
        for (captured, changed) in [
            (None, Some(Value::Null)),
            (None, Some(json!(text_value))),
            (Some(Value::Null), None),
            (Some(json!(text_value)), None),
            (Some(Value::Null), Some(json!(text_value))),
            (Some(json!(text_value)), Some(Value::Null)),
        ] {
            let mut shape = mode_baseline.clone();
            shape["selection"]["modelID"] = json!("synthetic-a");
            match captured {
                Some(value) => {
                    shape[mode] = value;
                }
                None => {
                    shape.as_object_mut().unwrap().remove(mode);
                }
            }
            e.store.save(&shape).unwrap();
            let p = mode_params(&e, &id, "plan", Some(&second));
            assert_eq!(p.get(expected_key), shape.get(mode));
            match changed {
                Some(value) => {
                    shape[mode] = value;
                }
                None => {
                    shape.as_object_mut().unwrap().remove(mode);
                }
            }
            e.store.save(&shape).unwrap();
            refuse(&mut e, &root, SELECT, p);
        }
    }
    e.store.save(&mode_baseline).unwrap();
    let external = records(&root).len();
    configure(
        &mut e,
        &id,
        &second,
        "synthetic-a",
        "plan",
        "high",
        "priority",
    );
    assert_eq!(
        records(&root).len(),
        external,
        "Selection must not launch or Send"
    );
    let chosen = e.store.thread(&id).unwrap();
    assert_eq!(chosen["draft"], original["draft"]);
    assert_eq!(chosen["draftContext"], original["draftContext"]);
    let caps = call(
        &mut e,
        "agent.selection.capabilities",
        json!({"threadId":id}),
    );
    assert_eq!(caps["namedModels"]["planSupported"], true);
    assert_eq!(caps["namedModels"]["fullAccessSupported"], true);
    assert_eq!(caps["namedModels"]["speedSupported"], true);
    assert_eq!(caps["namedModels"]["effortSupported"], true);
    // Whole-selection and both modes are CAS: no inferred/default expectations.
    for (field, wrong) in [
        ("expectedSelection", json!({})),
        ("expectedAccessMode", json!("fullAccess")),
        ("expectedInteractionMode", json!("build")),
    ] {
        let mut p = mode_params(&e, &id, "build", None);
        p[field] = wrong;
        refuse(&mut e, &root, SELECT, p);
    }
    // Saved Plan is revalidated at launch; unrelated options cannot piggyback
    // on the narrow no-proof Build repair route.
    let mut p = mode_params(&e, &id, "build", None);
    p["accessMode"] = json!("fullAccess");
    refuse(&mut e, &root, SELECT, p);
    // Bots and imported sources retain their own admission barriers; current
    // ordinary Plan authority cannot be borrowed by either source shape.
    let saved = e.store.thread(&id).unwrap();
    for field in ["botID", "rustBotContext"] {
        let mut bot = saved.clone();
        bot[field] = json!({"synthetic":true});
        e.store.save(&bot).unwrap();
        let p = mode_params(&e, &id, "build", None);
        refuse(&mut e, &root, SELECT, p);
        e.store.save(&saved).unwrap();
    }
    let db_scope = rusqlite::Connection::open(&db).unwrap();
    db_scope
        .execute("INSERT INTO imported_threads(id) VALUES (?1)", [&id])
        .unwrap();
    let p = mode_params(&e, &id, "build", None);
    refuse(&mut e, &root, SELECT, p);
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"Imported Plan is still read-only"}),
    );
    db_scope
        .execute("DELETE FROM imported_threads WHERE id=?1", [&id])
        .unwrap();
    drop(db_scope);
    send(&mut e, &id, &ha, "plan", "approval", "priority");
    select_mode(&mut e, &id, "build", None);
    send(&mut e, &id, &ha, "build", "approval", "priority");
    let mut p = mode_params(&e, &id, "plan", Some(&second));
    p["accessMode"] = json!("fullAccess");
    call(&mut e, SELECT, p);
    send(&mut e, &id, &ha, "plan", "fullAccess", "priority");
    select_mode(&mut e, &id, "build", None);
    // Standard clears speed only, keeps high effort and full access, and uses
    // the fresh owned ACK to clear a previous tier. Plan/Build never changes it.
    let mut p = selection_params(&e, &id, None);
    p["speed"] = Value::Null;
    call(&mut e, SELECT, p);
    assert_eq!(e.store.thread(&id).unwrap()["selection"]["effort"], "high");
    fs::write(ha.join("fixture-ack"), "priority").unwrap();
    send(&mut e, &id, &ha, "build", "fullAccess", "default");
    // Explicit default/approval/Build clears only the requested options before
    // account change. Neither A nor the default account can authorize B.
    let mut p = mode_params(&e, &id, "build", None);
    p["model"] = json!("default");
    p["accessMode"] = json!("approval");
    p["effort"] = Value::Null;
    p["speed"] = Value::Null;
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
    for catalog in [&default, &second] {
        let mut p = mode_params(&e, &id, "plan", Some(catalog));
        p["model"] = json!("synthetic-b");
        refuse(&mut e, &root, SELECT, p);
    }
    let rb = refresh(&mut e, &id);
    assert_eq!(rb["state"], "ready");
    configure(
        &mut e,
        &id,
        &rb,
        "synthetic-b",
        "plan",
        "medium",
        "ultrafast",
    );
    send(&mut e, &id, &hb, "plan", "approval", "ultrafast");
    let stored = e.store.thread(&id).unwrap();
    assert_eq!(stored["future"], original["future"]);
    assert_eq!(stored["sessions"]["claude"], original["sessions"]["claude"]);
    let saved_raw = raw(&root);
    let mut receipts = finish(&mut e, 5);
    drop(e);

    // Restart: persisted Plan/options do not mint private execution authority.
    // Identity-only normalization permits Refresh without rewriting a row.
    let mut e = Engine::new(Store::open(&db).unwrap());
    e.set_active_thread(Some(id.clone())).unwrap();
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"No persisted Plan authority"}),
    );
    let p = mode_params(&e, &id, "plan", Some(&rb));
    refuse(&mut e, &root, SELECT, p);
    let caps = call(
        &mut e,
        "agent.selection.capabilities",
        json!({"threadId":id}),
    );
    assert_eq!(caps["namedModels"]["refreshAllowed"], true);
    assert_eq!(caps["namedModels"]["planSupported"], false);
    assert_eq!(raw(&root), saved_raw);
    // Known Build-only repair is useful even with no catalog. It preserves
    // the exact model/options/permissions and cannot authorize a Send.
    let repaired = select_mode(&mut e, &id, "build", None);
    let mut expected = stored.clone();
    expected["interactionMode"] = json!("build");
    assert_eq!(repaired, expected);
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"Build repair grants no model proof"}),
    );
    let again = refresh(&mut e, &id);
    assert_eq!(again["state"], "ready");
    select_mode(&mut e, &id, "plan", Some(&again));
    let refreshed_raw = raw(&root);
    assert_eq!(refresh(&mut e, &id)["state"], "ready");
    assert_eq!(
        raw(&root),
        refreshed_raw,
        "Saved Plan refresh must not normalize persisted mode"
    );
    receipts += finish(&mut e, 0);
    drop(e);

    let mut e = Engine::new(Store::open(&db).unwrap());
    e.set_active_thread(Some(id.clone())).unwrap();
    let again = refresh(&mut e, &id);
    select_mode(&mut e, &id, "plan", Some(&again));
    e.set_active_thread(Some(text(&other, "id"))).unwrap();
    let p = mode_params(&e, &id, "build", None);
    refuse(&mut e, &root, SELECT, p);
    e.set_active_thread(Some(id.clone())).unwrap();
    let again = refresh(&mut e, &id);
    select_mode(&mut e, &id, "plan", Some(&again));
    let current = e.store.thread(&id).unwrap();
    let cwd = root.join("different-cwd");
    fs::create_dir(&cwd).unwrap();
    let mut changed = current.clone();
    changed["worktreePath"] = json!(cwd);
    e.store.save(&changed).unwrap();
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"Plan cannot borrow cwd"}),
    );
    e.store.save(&current).unwrap();
    let again = refresh(&mut e, &id);
    select_mode(&mut e, &id, "plan", Some(&again));
    let exe = root.join("fake-plan");
    let bytes = fs::read(&exe).unwrap();
    let mut changed = bytes.clone();
    changed.extend_from_slice(b"\n# synthetic executable revision\n");
    fs::write(&exe, changed).unwrap();
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"Plan cannot borrow executable"}),
    );
    fs::write(&exe, bytes).unwrap();
    fs::write(hb.join("fixture-mode"), "deny").unwrap();
    assert_eq!(refresh(&mut e, &id)["state"], "failed");
    refuse(
        &mut e,
        &root,
        "agent.send",
        json!({"threadId":id,"text":"Plan cannot borrow superseded proof"}),
    );
    fs::write(hb.join("fixture-mode"), "allow").unwrap();
    let again = refresh(&mut e, &id);
    select_mode(&mut e, &id, "plan", Some(&again));
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
        json!({"threadId":id,"text":"Plan cannot borrow auth generation"}),
    );
    let again = refresh(&mut e, &id);
    select_mode(&mut e, &id, "plan", Some(&again));
    // Current run keeps its captured Build policy after launch. No selection
    // changes are admitted while running; stop owns the only sixth receipt.
    select_mode(&mut e, &id, "build", None);
    fs::write(hb.join("fixture-collaboration"), "default").unwrap();
    fs::write(hb.join("fixture-mode"), "hold-turn").unwrap();
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"Captured Build until owned stop"}),
    );
    marker(&hb.join("turn-held"));
    call(&mut e, "app.status", json!({}));
    let p = mode_params(&e, &id, "plan", Some(&again));
    refuse(&mut e, &root, SELECT, p);
    e.request_provider_stop(&id).unwrap();
    settle(&mut e);
    fs::write(hb.join("fixture-mode"), "block").unwrap();
    let t = e.store.thread(&id).unwrap();
    call(
        &mut e,
        REFRESH,
        json!({"threadId":id,"accountId":b,"expectedSelection":t["selection"]}),
    );
    marker(&hb.join("blocked"));
    receipts += finish(&mut e, 1);
    assert_eq!(receipts, 6);
    assert_eq!(e.store.thread(&text(&other, "id")).unwrap(), other);
    assert_eq!(
        e.store.document("plan-fixture.json").unwrap(),
        Some(json!({"future":{"keep":17}}))
    );
    let stored = e.store.thread(&id).unwrap();
    for account in [&a, &b] {
        let mut scoped = stored.clone();
        scoped["selection"]["accountID"] = json!(account);
        assert_eq!(
            provider_session(&scoped, "codex"),
            Some(format!("{account}-plan-session"))
        );
    }
    let calls = records(&root);
    let turns: Vec<_> = calls
        .iter()
        .filter(|r| r["method"] == "turn/start")
        .collect();
    assert_eq!(turns.len(), 6);
    for (i, home, mode, access, effort, tier) in [
        (0, &ha, "plan", "untrusted", "high", "priority"),
        (1, &ha, "default", "untrusted", "high", "priority"),
        (2, &ha, "plan", "never", "high", "priority"),
        (3, &ha, "default", "never", "high", "default"),
        (4, &hb, "plan", "untrusted", "medium", "ultrafast"),
        (5, &hb, "default", "untrusted", "medium", "ultrafast"),
    ] {
        assert_eq!(turns[i]["home"], json!(home));
        assert_eq!(turns[i]["params"]["approvalPolicy"], access);
        assert_eq!(turns[i]["params"]["serviceTier"], tier);
        assert_eq!(turns[i]["params"]["effort"], effort);
        assert_eq!(
            turns[i]["params"]["collaborationMode"],
            json!({"mode":mode,"settings":{"model":if home==&ha {"synthetic-a"} else {"synthetic-b"},"reasoning_effort":effort,"developer_instructions":null}})
        );
    }
    assert!(
        turns[0]["params"]["input"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Synthetic retained Plan context")
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
