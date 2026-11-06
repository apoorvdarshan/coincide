//! Real temporary fake children only; no live credentials, sign-in or provider.
#![cfg(unix)]
use coincide_core::{
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
fn named_codex_profiles_reach_actual_isolated_child_and_gate_authentication() {
    let dir = tempfile::tempdir().unwrap();
    let executable = dir.path().join("fake-codex");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,sys,os
from pathlib import Path
root=Path(__file__).parent
home=Path(os.environ['CODEX_HOME'])
named='-c' in sys.argv
if named:
 assert home.parent.name=='codex' and home.parent.parent.name=='providers'
 for key in ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','CHATGPT_BASE_URL','HTTPS_PROXY','COINCIDE_PROFILE_FIXTURE_ROOT']:
  assert key not in os.environ,key
 for value in ['cli_auth_credentials_store="file"','forced_login_method="chatgpt"','model_provider="openai"','openai_base_url="https://chatgpt.com/backend-api/codex"','chatgpt_base_url="https://chatgpt.com/backend-api/"']:
  assert value in sys.argv,value
 assert 'coincide-unbound-' in os.environ['COINCIDE_CONTROL_SOCKET']
else:
 assert home==root/'inherited-default'
 assert os.environ['OPENAI_API_KEY']=='synthetic-hostile-key'
mode=(home/'fixture-mode').read_text() if (home/'fixture-mode').exists() else 'allow'
def record(value):
 with (root/'calls.jsonl').open('a') as file:file.write(json.dumps({'home':str(home),'named':named,**value})+'\n')
def read():
 line=sys.stdin.readline()
 if not line:sys.exit(0)
 value=json.loads(line);record({'method':value.get('method')});return value
def write(value):print(json.dumps(value),flush=True)
record({'pid':os.getpid(),'arguments':sys.argv[1:]})
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read()
if named:
 assert r['method']=='account/read' and r['params']=={'refreshToken':False}
 if mode=='block':
  (home/'auth-waiting').write_text('ready')
  sys.stdin.readline();sys.exit(0)
 account=None if mode=='deny' else {'type':'chatgpt','email':'synthetic@example.invalid','planType':'plus'}
 write({'id':r['id'],'result':{'requiresOpenaiAuth':True,'account':account}})
 r=read()
assert r['method'] in ['thread/start','thread/resume']
if named:assert r['method']=='thread/start'
serial=int((home/'serial').read_text())+1 if (home/'serial').exists() else 1
(home/'serial').write_text(str(serial))
native=(home.name+'-'+str(serial)) if r['method']=='thread/start' else r['params']['threadId']
record({'native':native,'threadMethod':r['method']})
write({'id':r['id'],'result':{'thread':{'id':native},'model':'reported-default'}})
r=read();assert r['method']=='turn/start';record({'turn':r['params']})
turn='turn-'+str(serial)
write({'id':r['id'],'result':{'turn':{'id':turn}}})
write({'method':'item/completed','params':{'threadId':native,'turnId':turn,'item':{'type':'agentMessage','id':native+'-reply-'+str(serial),'text':'Synthetic reply'}}})
write({'method':'turn/completed','params':{'threadId':native,'turn':{'id':turn,'status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    fs::create_dir(dir.path().join("inherited-default")).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "codex_profile_fixture_child",
            "--nocapture",
        ])
        .env("COINCIDE_PROFILE_FIXTURE_ROOT", dir.path())
        .env("COINCIDE_CODEX_EXECUTABLE", &executable)
        .env("CODEX_HOME", dir.path().join("inherited-default"))
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
    let response = engine.dispatch(json!({"method":method,"params":params}));
    assert!(response.get("error").is_none(), "{response}");
    response["result"].clone()
}
fn settle(engine: &mut Engine) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let status = call(engine, "app.status", json!({}));
        if status["running"].as_array().unwrap().is_empty()
            && engine.provider_workers_status().running == 0
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "fake profile worker did not finish"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn records(root: &Path) -> Vec<Value> {
    fs::read_to_string(root.join("calls.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}
#[test]
#[ignore = "Isolated fake account child; parent supplies dummy environment only"]
fn codex_profile_fixture_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_PROFILE_FIXTURE_ROOT").unwrap());
    let mut engine = Engine::new(Store::open(&root.join("state/state.sqlite")).unwrap());
    let thread = call(&mut engine, "threads.create", json!({"cwd":root}));
    let id = text(&thread, "id");
    engine.set_active_thread(Some(id.clone())).unwrap();
    call(
        &mut engine,
        "agent.select",
        json!({"threadId":id,"provider":"codex","model":"default"}),
    );
    let mut thread = engine.store.thread(&id).unwrap();
    thread["future"] = json!({"keep":42});
    engine.store.save(&thread).unwrap();
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
    let a_id = a["id"].as_str().unwrap();
    let b_id = b["id"].as_str().unwrap();
    let data = engine.store.data_directory().unwrap();
    let home_a = data.join("providers/codex").join(a_id);
    let home_b = data.join("providers/codex").join(b_id);
    // Default then A/B/A then explicit default: each named turn is a fresh
    // native thread with full context, never a cross-profile resume.
    let mut previous_a = None;
    for (number, account) in ["default", a_id, b_id, a_id, "default"].iter().enumerate() {
        let prior = engine.store.thread(&id).unwrap();
        call(
            &mut engine,
            "providers.codex.profiles.select",
            json!({"threadId":id,"accountId":account,"expectedSelection":prior["selection"]}),
        );
        call(
            &mut engine,
            "agent.send",
            json!({"threadId":id,"text":format!("synthetic prompt {number}")}),
        );
        settle(&mut engine);
        let saved = engine.store.thread(&id).unwrap();
        assert_eq!(saved["future"], json!({"keep":42}));
        assert!(!saved.to_string().contains("synthetic@example.invalid"));
        assert_eq!(
            text(&saved["sessions"]["codex"], "accountID"),
            if *account == "default" { "" } else { *account }
        );
        if *account == a_id {
            let native = text(&saved["sessions"]["codex"], "sessionID");
            if let Some(previous) = previous_a {
                assert_ne!(native, previous);
            }
            previous_a = Some(native);
        }
    }
    let saved = engine.store.thread(&id).unwrap();
    assert!(saved["accountSessions"][format!("codex/{a_id}")]["sessionID"].is_string());
    assert!(saved["accountSessions"][format!("codex/{b_id}")]["sessionID"].is_string());
    let calls = records(&root);
    assert!(
        calls
            .iter()
            .any(|v| v["home"] == json!(home_a) && v["method"] == "account/read")
    );
    assert!(
        calls
            .iter()
            .any(|v| v["home"] == json!(home_b) && v["method"] == "account/read")
    );
    let repeated = calls
        .iter()
        .filter(|v| v["home"] == json!(home_a) && v.get("turn").is_some())
        .last()
        .unwrap();
    assert!(
        repeated["turn"]["input"][0]["text"]
            .as_str()
            .unwrap()
            .contains("synthetic prompt 0")
    );
    // Rejected authentication cannot fall back or send thread/turn methods.
    fs::write(home_a.join("fixture-mode"), "deny").unwrap();
    let prior = engine.store.thread(&id).unwrap();
    call(
        &mut engine,
        "providers.codex.profiles.select",
        json!({"threadId":id,"accountId":a_id,"expectedSelection":prior["selection"]}),
    );
    let before = records(&root).len();
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"refused synthetic prompt"}),
    );
    settle(&mut engine);
    let after = records(&root);
    assert!(!after.iter().skip(before).any(|v| matches!(
        v["method"].as_str(),
        Some("thread/start" | "thread/resume" | "turn/start")
    )));
    // Cancellation while account/read waits uses the existing real worker and
    // owned child cleanup path, not a fabricated authentication completion.
    fs::write(home_a.join("fixture-mode"), "block").unwrap();
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"cancel synthetic auth"}),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    while !home_a.join("auth-waiting").exists() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
    let active = engine.store.thread(&id).unwrap();
    let refused = engine.dispatch(json!({"method":"providers.codex.profiles.select","params":{"threadId":id,"accountId":"default","expectedSelection":active["selection"]}}));
    assert!(refused.get("error").is_some());
    assert_eq!(
        engine.store.thread(&id).unwrap()["selection"],
        active["selection"]
    );
    engine.request_provider_stop(&id).unwrap();
    settle(&mut engine);
    assert!(engine.provider_workers_status().returned >= 7);
    for record in records(&root)
        .iter()
        .filter(|record| record["pid"].is_number())
    {
        let pid = record["pid"].as_i64().unwrap() as i32;
        let mut status = 0;
        assert_eq!(
            unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) },
            -1
        );
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ECHILD)
        );
    }
}
