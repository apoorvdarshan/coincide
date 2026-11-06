//! Explicit enrollment against temporary fake app-server children only.
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
fn codex_enrollment_owns_actual_isolated_login_child_and_never_starts_a_turn() {
    let root = tempfile::tempdir().unwrap();
    let executable = root.path().join("fake-codex");
    fs::write(&executable,r#"#!/usr/bin/env python3
import json,sys,os,selectors
from pathlib import Path
root=Path(__file__).parent
home=Path(os.environ['CODEX_HOME'])
assert home.parent.name=='codex' and home.parent.parent.name=='providers'
for key in ['CODEX_API_KEY','OPENAI_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','HTTPS_PROXY','CODEX_APP_SERVER_LOGIN_ISSUER','CODEX_APP_SERVER_DEV_OPEN_APP_URL','COINCIDE_ENROLLMENT_FIXTURE_ROOT']:
 assert key not in os.environ,key
assert 'cli_auth_credentials_store="file"' in sys.argv
assert 'forced_login_method="chatgpt"' in sys.argv
assert 'coincide-unbound-' in os.environ['COINCIDE_CONTROL_SOCKET']
mode=(home/'fixture-mode').read_text() if (home/'fixture-mode').exists() else 'complete'
def record(value):
 with (root/'calls.jsonl').open('a') as out:out.write(json.dumps({'home':str(home),**value})+'\n')
def read():
 raw=sys.stdin.readline()
 if not raw:sys.exit(0)
 value=json.loads(raw);record({'method':value.get('method')});return value
def write(value):print(json.dumps(value),flush=True)
record({'pid':os.getpid()})
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read();assert r['method']=='account/login/start' and r['params']=={'type':'chatgptDeviceCode'}
login='00000000-0000-4000-8000-000000000001'
url='https://auth.openai.com/codex/device'
if mode=='bad-url':url=url.replace('auth.openai.com','auth.openai.com.invalid')
write({'id':r['id'],'result':{'type':'chatgptDeviceCode','loginId':login,'verificationUrl':url,'userCode':'SYNTHETIC-CODE' if mode!='bad-code' else 'bad\ncode'}})
if mode in ['bad-url','bad-code']:sys.stdin.readline();sys.exit(0)
selector=selectors.DefaultSelector();selector.register(sys.stdin,selectors.EVENT_READ)
while not (home/'complete').exists():
 if selector.select(.01):
  r=read();assert r['method']=='account/login/cancel' and r['params']=={'loginId':login}
  write({'id':r['id'],'result':{'status':'canceled'}})
  sys.stdin.readline();sys.exit(0)
selector.close()
write({'method':'account/login/completed','params':{'loginId':'00000000-0000-4000-8000-000000000099' if mode=='wrong-completion' else login,'success':True,'error':None}})
if mode=='wrong-completion':sys.stdin.readline();sys.exit(0)
r=read();assert r['method']=='account/read' and r['params']=={'refreshToken':False}
write({'id':r['id'],'result':{'requiresOpenaiAuth':True,'account':None if mode=='unauthenticated' else {'type':'chatgpt','email':'synthetic@example.invalid','planType':'plus'}}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let result = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "codex_enrollment_fixture_child",
            "--nocapture",
        ])
        .env("COINCIDE_ENROLLMENT_FIXTURE_ROOT", root.path())
        .env("COINCIDE_CODEX_EXECUTABLE", &executable)
        .env("CODEX_HOME", root.path().join("untouched-default"))
        .env("CODEX_API_KEY", "synthetic-hostile-key")
        .env("OPENAI_API_KEY", "synthetic-hostile-key")
        .env("CODEX_ACCESS_TOKEN", "synthetic-hostile-token")
        .env("OPENAI_BASE_URL", "https://invalid.invalid")
        .env("HTTPS_PROXY", "http://invalid.invalid")
        .env("CODEX_APP_SERVER_LOGIN_ISSUER", "https://invalid.invalid")
        .env(
            "CODEX_APP_SERVER_DEV_OPEN_APP_URL",
            "https://invalid.invalid",
        )
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{} {}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(!root.path().join("untouched-default").exists());
}

fn call(engine: &mut Engine, method: &str, params: Value) -> Value {
    let value = engine.dispatch(json!({"method":method,"params":params}));
    assert!(value.get("error").is_none(), "{value}");
    value["result"].clone()
}
fn await_status(engine: &mut Engine, operation: &Value, done: bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let status = call(
            engine,
            "providers.codex.profiles.login.status",
            json!({"accountId":operation["accountId"],"operationId":operation["operationId"]}),
        );
        if if done {
            status["workerReturned"] == true
        } else {
            status["state"] == "waiting"
        } {
            return status;
        }
        assert!(
            Instant::now() < deadline,
            "Enrollment fixture did not reach its owned state: {}",
            status["state"]
        );
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn records(root: &Path) -> Vec<Value> {
    fs::read_to_string(root.join("calls.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

#[test]
#[ignore = "Scoped temporary fake enrollment child; parent supplies synthetic environment"]
fn codex_enrollment_fixture_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_ENROLLMENT_FIXTURE_ROOT").unwrap());
    let mut engine = Engine::new(Store::open(&root.join("state/state.sqlite")).unwrap());
    let thread = call(&mut engine, "threads.create", json!({"cwd":root}));
    let thread_id = text(&thread, "id");
    engine.set_active_thread(Some(thread_id.clone())).unwrap();
    call(
        &mut engine,
        "agent.select",
        json!({"threadId":thread_id,"provider":"codex","model":"default"}),
    );
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
    let data = engine.store.data_directory().unwrap();
    let home_a = data.join("providers/codex").join(a["id"].as_str().unwrap());
    let home_b = data.join("providers/codex").join(b["id"].as_str().unwrap());
    let snapshot = engine.store.thread(&thread_id).unwrap();
    let operation = call(
        &mut engine,
        "providers.codex.profiles.login.start",
        json!({"accountId":a["id"]}),
    );
    let waiting = await_status(&mut engine, &operation, false);
    assert_eq!(
        waiting["verificationUrl"],
        "https://auth.openai.com/codex/device"
    );
    assert_eq!(waiting["userCode"], "SYNTHETIC-CODE");
    assert_eq!(waiting["accountIdentityVerified"], false);
    assert!(engine.dispatch(json!({"method":"providers.codex.profiles.login.status","params":{"accountId":b["id"],"operationId":operation["operationId"]}})).get("error").is_some());
    assert!(engine.dispatch(json!({"method":"providers.codex.profiles.login.start","params":{"accountId":b["id"]}})).get("error").is_some());
    let selected = call(
        &mut engine,
        "providers.codex.profiles.select",
        json!({"threadId":thread_id,"accountId":a["id"],"expectedSelection":snapshot["selection"]}),
    );
    assert!(engine.dispatch(json!({"method":"agent.send","params":{"threadId":thread_id,"text":"must not send during enrollment"}})).get("error").is_some());
    assert_eq!(engine.store.thread(&thread_id).unwrap(), selected);
    fs::write(home_a.join("complete"), "ready").unwrap();
    let complete = await_status(&mut engine, &operation, true);
    assert_eq!(complete["state"], "authenticated");
    assert!(complete["verificationUrl"].is_null());
    assert!(complete["userCode"].is_null());
    assert_eq!(engine.store.thread(&thread_id).unwrap(), selected);

    // Cancellation requires the exact operation/profile and waits for actual
    // worker cleanup, including the same owned process/pipe joins as turns.
    let operation = call(
        &mut engine,
        "providers.codex.profiles.login.start",
        json!({"accountId":b["id"]}),
    );
    await_status(&mut engine, &operation, false);
    call(
        &mut engine,
        "providers.codex.profiles.login.cancel",
        json!({"accountId":b["id"],"operationId":operation["operationId"]}),
    );
    let cancelled = await_status(&mut engine, &operation, true);
    assert_eq!(cancelled["state"], "cancelled");
    assert_eq!(cancelled["cancelAcknowledged"], true);

    for mode in ["bad-url", "bad-code", "wrong-completion", "unauthenticated"] {
        fs::write(home_a.join("fixture-mode"), mode).unwrap();
        let start = records(&root).len();
        let operation = call(
            &mut engine,
            "providers.codex.profiles.login.start",
            json!({"accountId":a["id"]}),
        );
        let failed = await_status(&mut engine, &operation, true);
        assert_eq!(failed["state"], "failed");
        assert!(failed["verificationUrl"].is_null());
        assert!(failed["userCode"].is_null());
        if mode != "unauthenticated" {
            assert!(
                !records(&root)
                    .iter()
                    .skip(start)
                    .any(|record| record["method"] == "account/read")
            );
        }
        assert_eq!(engine.store.thread(&thread_id).unwrap(), selected);
    }

    // Frozen owner shutdown cancels enrollment through the trusted seam; JSON
    // stays closed, while the retained worker still drains and is joined.
    let operation = call(
        &mut engine,
        "providers.codex.profiles.login.start",
        json!({"accountId":b["id"]}),
    );
    await_status(&mut engine, &operation, false);
    engine.request_core_owner_shutdown().unwrap();
    assert!(engine.dispatch(json!({"method":"providers.codex.profiles.login.start","params":{"accountId":a["id"]}})).get("error").is_some());
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let status = engine.poll_core_owner_shutdown().unwrap();
        if status.providers.running == 0 {
            assert_eq!(status.providers.panicked, 0);
            assert_eq!(status.providers.unclassified, 0);
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
    let calls = records(&root);
    assert!(
        calls
            .iter()
            .all(|record| record["home"] == json!(home_a) || record["home"] == json!(home_b))
    );
    assert!(calls.iter().any(
        |record| record["home"] == json!(home_b) && record["method"] == "account/login/cancel"
    ));
    assert!(
        !calls
            .iter()
            .any(|record| record["home"] == json!(home_b) && record["method"] == "account/read")
    );
    assert!(!calls.iter().any(|record| matches!(
        record["method"].as_str(),
        Some("thread/start" | "thread/resume" | "turn/start" | "model/list")
    )));
    for record in calls.iter().filter(|record| record["pid"].is_number()) {
        let pid = record["pid"].as_i64().unwrap() as i32;
        let mut status = 0;
        // SAFETY: asks only whether this exact synthetic owned PID remains our
        // child; no process is signalled and status points to initialized memory.
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
