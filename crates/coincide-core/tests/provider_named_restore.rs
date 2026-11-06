//! One bounded fake account/read + model/list process; no live account or turn.
#![cfg(unix)]
use coincide_core::{api::Engine, store::Store};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant},
};

#[test]
fn automatic_named_restore_is_authenticated_atomic_and_cancellable() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    for name in ["home", "tmp"] {
        fs::create_dir(root.join(name)).unwrap();
    }
    let executable = root.join("fake-catalog");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,os,sys,time
from pathlib import Path
root=Path(__file__).parent
home=Path(os.environ['CODEX_HOME'])
assert home.parent.name=='codex' and home.parent.parent.name=='providers'
for key in ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','CHATGPT_BASE_URL','HTTPS_PROXY']:
 assert key not in os.environ,key
assert 'cli_auth_credentials_store="file"' in sys.argv
assert 'forced_login_method="chatgpt"' in sys.argv
assert 'model_provider="openai"' in sys.argv
def read():
 line=sys.stdin.readline()
 if not line:sys.exit(0)
 r=json.loads(line)
 with (root/'calls.jsonl').open('a') as f:f.write(json.dumps({'method':r.get('method'),'params':r.get('params'),'home':str(home),'cwd':os.getcwd()})+'\n')
 return r
def write(v):print(json.dumps(v),flush=True)
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read();assert r['method']=='account/read' and r['params']=={'refreshToken':False}
if (home/'block').exists():
 (home/'blocked').write_text('ready');sys.stdin.readline();sys.exit(0)
write({'id':r['id'],'result':{'requiresOpenaiAuth':True,'account':None if (home/'deny').exists() else {'type':'chatgpt','email':'synthetic@example.invalid','planType':'plus'}}})
r=read();assert r['method']=='model/list'
write({'id':r['id'],'result':{'data':json.loads((home/'models.json').read_text()),'nextCursor':None}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let result = Command::new(std::env::current_exe().unwrap())
        .args(["--ignored", "--exact", "named_restore_child", "--nocapture"])
        .env_clear()
        .env("HOME", root.join("home"))
        .env("TMPDIR", root.join("tmp"))
        .env("PATH", "/usr/bin:/bin")
        .env("COINCIDE_NAMED_RESTORE_FIXTURE", &root)
        .env("COINCIDE_CODEX_EXECUTABLE", &executable)
        .env("OPENAI_API_KEY", "synthetic-never-forwarded")
        .env("HTTPS_PROXY", "http://invalid.invalid")
        .current_dir(&root)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(String::from_utf8_lossy(&result.stdout).contains("1 passed"));
    let records = records(&root);
    assert!(!records.is_empty());
    assert!(records.iter().all(|row| matches!(
        row["method"].as_str(),
        Some("initialize" | "initialized" | "account/read" | "model/list")
    )));
    assert!(
        records
            .iter()
            .filter(|row| row["method"] == "account/read")
            .all(|row| row["params"] == json!({"refreshToken":false}))
    );
}
fn call(e: &mut Engine, method: &str, params: Value) -> Value {
    let response = e.dispatch(json!({"method":method,"params":params}));
    assert!(response.get("error").is_none(), "{response}");
    response["result"].clone()
}
fn refused(e: &mut Engine, params: Value) {
    let response = e.dispatch(json!({"method":"agent.provider.select","params":params}));
    assert!(response.get("error").is_some(), "{response}");
}
fn expected(thread: &Value, provider: &str) -> Value {
    let fields = [
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
    json!({"threadId":thread["id"],"provider":provider,"expected":fields})
}
fn retry(thread: &Value, pending: &Value) -> Value {
    let mut p = expected(thread, "codex");
    p["restoreRequestId"] = pending["requestId"].clone();
    p
}
fn finish(e: &mut Engine, source: &Value, pending: &Value) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let response = call(e, "agent.provider.select", retry(source, pending));
        if response["pending"] != true {
            return response;
        }
        assert!(Instant::now() < deadline, "fake restore timed out");
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
fn drain(e: &mut Engine) {
    assert_eq!(e.provider_workers_status().running, 0);
    assert_eq!(e.provider_workers_status().returned, 0);
    e.freeze_admissions();
    e.request_model_catalog_shutdown().unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let status = e.model_catalog_shutdown_status().unwrap();
        assert_eq!(status.panicked, 0);
        assert_eq!(status.unclassified, 0);
        if status.running == 0 {
            return;
        }
        assert!(Instant::now() < deadline, "fake worker failed to return");
        std::thread::sleep(Duration::from_millis(2));
    }
}
struct Fixture {
    engine: Engine,
    source: Value,
    a: String,
    b: String,
    a_home: PathBuf,
    b_home: PathBuf,
    db: PathBuf,
}
fn fixture(root: &Path, case: &str) -> Fixture {
    let state = root.join(case);
    fs::create_dir_all(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    let db = state.join("state.sqlite");
    let mut engine = Engine::new(Store::open(&db).unwrap());
    let project = call(
        &mut engine,
        "projects.create",
        json!({"path":root,"name":"Synthetic restore"}),
    );
    let mut source = call(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    );
    let a = call(
        &mut engine,
        "providers.codex.profiles.create",
        json!({"name":"Same display name"}),
    )["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let b = call(
        &mut engine,
        "providers.codex.profiles.create",
        json!({"name":"Same display name"}),
    )["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let a_home = state.join("providers/codex").join(&a);
    let b_home = state.join("providers/codex").join(&b);
    fs::write(a_home.join("models.json"),json!([{"model":"synthetic-a","supportedReasoningEfforts":[{"reasoningEffort":"high"}],"supportedServiceTiers":["priority"]},{"model":"gpt-6-astra","supportedReasoningEfforts":[{"reasoningEffort":"medium"}]},{"model":"openai.gpt-6-astra","supportedReasoningEfforts":[{"reasoningEffort":"high"}]}]).to_string()).unwrap();
    fs::write(
        b_home.join("models.json"),
        json!([{"model":"synthetic-b"}]).to_string(),
    )
    .unwrap();
    source["selection"] = json!({"provider":"claude","modelID":"source-model"});
    source["draft"] = json!("Unsent café 中文 /codex");
    source["future"] = json!({"keep":[true,17]});
    source["draftContext"] = json!([{"future":"opaque context retained"}]);
    source["rustDraftImages"] = json!([{"future":"opaque image retained"}]);
    source["sessions"] = json!({"codex":{"sessionID":"synthetic-old-native","accountID":a,"future":{"keep":true}},"claude":{"sessionID":"other-native","future":41}});
    source["items"] = json!([{"id":uuid::Uuid::new_v4(),"kind":"assistant","provider":"codex","modelID":"synthetic-a","accountID":a,"text":"history","future":42}]);
    engine.store.save(&source).unwrap();
    engine
        .set_active_thread(Some(source["id"].as_str().unwrap().into()))
        .unwrap();
    Fixture {
        engine,
        source,
        a,
        b,
        a_home,
        b_home,
        db,
    }
}
fn assert_preserved(source: &Value, result: &Value) {
    let mut want = source.clone();
    want["selection"] = result["selection"].clone();
    want["rustProviderSelections"] = json!({"claude":source["selection"]});
    assert_eq!(result, &want);
}
#[test]
#[ignore = "Outer test supplies only synthetic credentials and a private cleared HOME"]
fn named_restore_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_NAMED_RESTORE_FIXTURE").unwrap());
    let mut f = fixture(&root, "warm-cold");
    let id = f.source["id"].as_str().unwrap().to_owned();
    let pending = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&f.source, "codex"),
    );
    assert_eq!(pending["pending"], true);
    assert_eq!(pending["accountID"], f.a);
    assert_eq!(f.engine.store.thread(&id).unwrap(), f.source);
    let restored = finish(&mut f.engine, &f.source, &pending);
    assert_eq!(restored["accountRestored"], true);
    assert_eq!(restored["authenticationChecked"], true);
    assert_eq!(
        restored["thread"]["selection"],
        json!({"provider":"codex","modelID":"synthetic-a","accountID":f.a})
    );
    assert_preserved(&f.source, &restored["thread"]);
    assert_eq!(
        call(
            &mut f.engine,
            "agent.selection.capabilities",
            json!({"threadId":id})
        )["namedModels"]["fullAccessSupported"],
        true
    );
    let calls_before = records(&root).len();
    let away = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&restored["thread"], "claude"),
    );
    assert_eq!(away["thread"]["selection"]["provider"], "claude");
    let warm = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&away["thread"], "codex"),
    );
    assert_eq!(warm["pending"], Value::Null);
    assert_eq!(warm["accountID"], f.a);
    assert_eq!(
        records(&root).len(),
        calls_before,
        "warm restore must reuse the exact existing catalog without executing a process"
    );
    drain(&mut f.engine);

    // Identical display names and another account's history never identify A.
    let mut f = fixture(&root, "account-b");
    f.source["sessions"]["codex"]["accountID"] = json!(f.b);
    f.source["items"][0]["accountID"] = json!(f.b);
    f.source["items"][0]["modelID"] = json!("synthetic-b");
    f.engine.store.save(&f.source).unwrap();
    let pending = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&f.source, "codex"),
    );
    let result = finish(&mut f.engine, &f.source, &pending);
    assert_eq!(result["accountID"], f.b);
    assert_eq!(result["model"], "synthetic-b");
    assert!(
        records(&root)
            .iter()
            .filter(|row| row["home"] == json!(f.b_home))
            .all(|row| row["home"] != json!(f.a_home))
    );
    drain(&mut f.engine);

    for case in [
        "content-revert",
        "active-revert",
        "target-config-revert",
        "target-auth",
        "superseded",
        "cancelled",
        "shutdown",
        "restart",
        "unauthenticated",
    ] {
        let mut f = fixture(&root, case);
        let id = f.source["id"].as_str().unwrap().to_owned();
        if case == "unauthenticated" {
            fs::write(f.a_home.join("deny"), "synthetic").unwrap();
        } else {
            fs::write(f.a_home.join("block"), "synthetic").unwrap();
        }
        let pending = call(
            &mut f.engine,
            "agent.provider.select",
            expected(&f.source, "codex"),
        );
        assert_eq!(pending["pending"], true);
        assert_eq!(f.engine.store.thread(&id).unwrap(), f.source);
        match case {
            "content-revert" => {
                let mut changed = f.source.clone();
                changed["draft"] = json!("newer");
                f.engine.store.save(&changed).unwrap();
                f.engine.store.save(&f.source).unwrap();
            }
            "active-revert" => {
                f.engine.set_active_thread(None).unwrap();
                f.engine.set_active_thread(Some(id.clone())).unwrap();
            }
            "target-config-revert" => {
                let original = f
                    .engine
                    .store
                    .document("rust-codex-login-profiles.json")
                    .unwrap()
                    .unwrap();
                f.engine
                    .store
                    .save_document("rust-codex-login-profiles.json", &json!({"changed":true}))
                    .unwrap();
                f.engine
                    .store
                    .save_document("rust-codex-login-profiles.json", &original)
                    .unwrap();
            }
            "target-auth" => {
                fs::write(
                    f.a_home.join("auth.json"),
                    "synthetic stamp, not a credential",
                )
                .unwrap();
                fs::set_permissions(
                    f.a_home.join("auth.json"),
                    fs::Permissions::from_mode(0o600),
                )
                .unwrap();
            }
            "superseded" => {
                let new = call(
                    &mut f.engine,
                    "agent.provider.select",
                    expected(&f.source, "cursor"),
                );
                assert_eq!(new["thread"]["selection"]["provider"], "cursor");
            }
            "cancelled" => {
                call(&mut f.engine, "agent.provider.cancelRestore", json!({}));
            }
            "shutdown" => {
                f.engine.freeze_admissions();
            }
            "restart" => {
                drain(&mut f.engine);
                f.engine = Engine::new(Store::open(&f.db).unwrap());
                f.engine.set_active_thread(Some(id.clone())).unwrap();
            }
            "unauthenticated" => {
                let deadline = Instant::now() + Duration::from_secs(10);
                loop {
                    let response=f.engine.dispatch(json!({"method":"agent.provider.select","params":retry(&f.source,&pending)}));
                    if response.get("error").is_some() {
                        break;
                    }
                    assert!(Instant::now() < deadline);
                    std::thread::sleep(Duration::from_millis(2));
                }
            }
            _ => unreachable!(),
        }
        refused(&mut f.engine, retry(&f.source, &pending));
        if case != "superseded" {
            assert_eq!(f.engine.store.thread(&id).unwrap(), f.source, "{case}");
        }
        drain(&mut f.engine);
    }

    // Latest model is unavailable: use the first exact account catalog row,
    // never skip back to an older historical model or borrow another account.
    for model in ["not-advertised", "openai.gpt-6-astra"] {
        let mut f = fixture(&root, &format!("latest-{model}"));
        f.source["items"].as_array_mut().unwrap().push(json!({"id":uuid::Uuid::new_v4(),"kind":"assistant","provider":"codex","accountID":f.a,"modelID":model}));
        f.engine.store.save(&f.source).unwrap();
        let pending = call(
            &mut f.engine,
            "agent.provider.select",
            expected(&f.source, "codex"),
        );
        if model == "not-advertised" {
            let result = finish(&mut f.engine, &f.source, &pending);
            assert_eq!(result["model"], "synthetic-a");
        } else {
            let deadline = Instant::now() + Duration::from_secs(10);
            loop {
                let response = f.engine.dispatch(
                    json!({"method":"agent.provider.select","params":retry(&f.source,&pending)}),
                );
                if response.get("error").is_some() {
                    break;
                }
                assert!(Instant::now() < deadline);
                std::thread::sleep(Duration::from_millis(2));
            }
            assert_eq!(
                f.engine
                    .store
                    .thread(f.source["id"].as_str().unwrap())
                    .unwrap(),
                f.source
            );
        }
        drain(&mut f.engine);
    }
}
