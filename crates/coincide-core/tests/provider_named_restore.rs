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
    fs::create_dir(root.join("home/.codex")).unwrap();
    fs::write(
        root.join("home/.codex/models.json"),
        json!([{"model":"synthetic-default"}]).to_string(),
    )
    .unwrap();
    let executable = root.join("fake-catalog");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,os,sys,time
from pathlib import Path
root=Path(__file__).parent
home=Path(os.environ.get('CODEX_HOME',str(Path(os.environ['HOME'])/'.codex')))
named=home.parent.name=='codex' and home.parent.parent.name=='providers'
if named:
 for key in ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','CHATGPT_BASE_URL','HTTPS_PROXY']:
  assert key not in os.environ,key
 assert 'cli_auth_credentials_store="file"' in sys.argv
 assert 'forced_login_method="chatgpt"' in sys.argv
 assert 'model_provider="openai"' in sys.argv
else:assert sys.argv[1:]==['app-server']
mode=(root/'default-mode').read_text() if not named and (root/'default-mode').exists() else ('deny' if not named else 'allow')
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
if (home/'block').exists() or mode=='block':
 (home/'blocked').write_text('ready');sys.stdin.readline();sys.exit(0)
if (home/'hold').exists():
 (home/'held').write_text('ready')
 while (home/'hold').exists():time.sleep(0.002)
write({'id':r['id'],'result':{'requiresOpenaiAuth':True,'account':None if (home/'deny').exists() or mode=='deny' else {'type':'apiKey' if mode=='apiKey' else 'chatgpt','email':'synthetic@example.invalid','planType':'plus'}}})
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
    fs::write(a_home.join("models.json"),json!([{"model":"synthetic-a","supportedReasoningEfforts":[{"reasoningEffort":"high"}],"serviceTiers":[{"id":"priority","name":"Fast"}]},{"model":"synthetic-low","supportedReasoningEfforts":[{"reasoningEffort":"low"}],"defaultReasoningEffort":"low"},{"model":"gpt-6-astra","supportedReasoningEfforts":[{"reasoningEffort":"medium"}]},{"model":"openai.gpt-6-astra","supportedReasoningEfforts":[{"reasoningEffort":"high"}]}]).to_string()).unwrap();
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
fn finish_explicit(e: &mut Engine, source: &Value, pending: &Value, account: Value) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let mut params = retry(source, pending);
        params["accountId"] = account.clone();
        let response = call(e, "agent.provider.select", params);
        if response["pending"] != true {
            return response;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
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
    let saved_choice = f.engine.store.thread(&id).unwrap();
    let settings_before = call(&mut f.engine, "settings.read", json!({}));
    assert_eq!(
        settings_before["defaultSelection"],
        saved_choice["selection"]
    );
    let new_thread = call(
        &mut f.engine,
        "threads.create",
        json!({"projectId":f.source["projectID"]}),
    );
    assert_eq!(new_thread["selection"], saved_choice["selection"]);
    let new_id = new_thread["id"].as_str().unwrap().to_owned();
    f.engine.set_active_thread(Some(new_id.clone())).unwrap();
    let unproved = call(
        &mut f.engine,
        "agent.selection.capabilities",
        json!({"threadId":new_id}),
    );
    assert_eq!(
        unproved["namedModels"]["fullAccessSupported"], false,
        "new threads cannot borrow another thread's authenticated proof"
    );
    let mut initial = expected(&new_thread, "codex");
    initial["restoreCurrent"] = json!(true);
    let pending = call(&mut f.engine, "agent.provider.select", initial);
    assert_eq!(pending["pending"], true);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let mut p = retry(&new_thread, &pending);
        p["restoreCurrent"] = json!(true);
        let response = call(&mut f.engine, "agent.provider.select", p);
        if response["pending"] != true {
            assert_eq!(response["thread"]["selection"], saved_choice["selection"]);
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
    assert_eq!(
        call(&mut f.engine, "settings.read", json!({})),
        settings_before,
        "restoring a saved choice does not move app defaults"
    );
    assert_eq!(
        f.engine.store.thread(&id).unwrap(),
        saved_choice,
        "new thread restoration cannot mutate an existing thread"
    );
    drain(&mut f.engine);

    // Desired reasoning/speed remain isolated across A -> B -> A. Switching
    // through an incompatible same-account model uses its advertised fallback
    // without replacing the user's desired value.
    let mut f = fixture(&root, "desired-options");
    f.source["modelPreferences"] = json!({format!("codex/{}",f.a):{"effort":"high","speed":"priority","future":17},format!("codex/{}",f.b):{"effort":"low","speed":"turbo"}});
    fs::write(f.b_home.join("models.json"),json!([{"model":"synthetic-b","supportedReasoningEfforts":[{"reasoningEffort":"low"}],"defaultReasoningEffort":"low","serviceTiers":[{"id":"turbo","name":"Turbo"}]}]).to_string()).unwrap();
    f.engine.store.save(&f.source).unwrap();
    let pending = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&f.source, "codex"),
    );
    let mut a = finish(&mut f.engine, &f.source, &pending);
    let low = call(
        &mut f.engine,
        "providers.codex.profiles.models.select",
        json!({"threadId":f.source["id"],"accountId":f.a,"expectedSelection":a["thread"]["selection"],"requestId":pending["catalogRequestId"],"model":"synthetic-low","rememberComposerChoice":true}),
    );
    assert_eq!(low["selection"]["effort"], "low");
    assert_eq!(low["selection"]["speed"], Value::Null);
    assert_eq!(
        low["modelPreferences"][format!("codex/{}", f.a)]["effort"],
        "high"
    );
    assert_eq!(
        low["modelPreferences"][format!("codex/{}", f.a)]["speed"],
        "priority"
    );
    let high = call(
        &mut f.engine,
        "providers.codex.profiles.models.select",
        json!({"threadId":f.source["id"],"accountId":f.a,"expectedSelection":low["selection"],"requestId":pending["catalogRequestId"],"model":"synthetic-a","rememberComposerChoice":true}),
    );
    a["thread"] = high;
    assert_eq!(a["thread"]["selection"]["effort"], "high");
    assert_eq!(a["thread"]["selection"]["speed"], "priority");
    let mut away = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&a["thread"], "claude"),
    )["thread"]
        .clone();
    away["sessions"]["codex"]["accountID"] = json!(f.b);
    away["items"].as_array_mut().unwrap().push(json!({"id":uuid::Uuid::new_v4(),"provider":"codex","kind":"assistant","accountID":f.b,"modelID":"synthetic-b"}));
    f.engine.store.save(&away).unwrap();
    let pending = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&away, "codex"),
    );
    let b = finish(&mut f.engine, &away, &pending);
    assert_eq!(b["thread"]["selection"]["accountID"], f.b);
    assert_eq!(b["thread"]["selection"]["effort"], "low");
    assert_eq!(b["thread"]["selection"]["speed"], "turbo");
    let mut away = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&b["thread"], "claude"),
    )["thread"]
        .clone();
    away["sessions"]["codex"]["accountID"] = json!(f.a);
    away["items"].as_array_mut().unwrap().push(json!({"id":uuid::Uuid::new_v4(),"provider":"codex","kind":"assistant","accountID":f.a,"modelID":"synthetic-a"}));
    f.engine.store.save(&away).unwrap();
    let a = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&away, "codex"),
    );
    assert_eq!(a["pending"], Value::Null);
    assert_eq!(a["thread"]["selection"]["effort"], "high");
    assert_eq!(a["thread"]["selection"]["speed"], "priority");
    assert_eq!(
        a["thread"]["modelPreferences"][format!("codex/{}", f.a)]["future"],
        17
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

    // Restoring an existing conversation is observation-only. Desired high
    // must not overwrite its saved low selection (which binds native resume),
    // and Provider default remains Provider default. No metadata is rewritten.
    for saved_model in ["synthetic-a", "default", "unavailable-saved-model"] {
        let mut f = fixture(&root, &format!("exact-warmup-{saved_model}"));
        fs::write(f.a_home.join("models.json"),json!([{"model":"synthetic-a","supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"}],"defaultReasoningEffort":"high"}]).to_string()).unwrap();
        f.source["selection"] = json!({"provider":"codex","accountID":f.a,"modelID":saved_model});
        if saved_model != "default" {
            f.source["selection"]["effort"] = json!("low");
        }
        f.source["modelPreferences"] =
            json!({format!("codex/{}",f.a):{"effort":"high","speed":"priority","future":41}});
        f.engine.store.save(&f.source).unwrap();
        let settings = json!({"defaultSelection":{"provider":"claude","modelID":"retained-default"},"defaultAccessMode":"approval","future":42});
        f.engine
            .store
            .save_document("settings.json", &settings)
            .unwrap();
        let mut params = expected(&f.source, "codex");
        params["restoreCurrent"] = json!(true);
        let pending = call(&mut f.engine, "agent.provider.select", params);
        assert_eq!(pending["pending"], true);
        assert_eq!(
            f.engine
                .store
                .thread(f.source["id"].as_str().unwrap())
                .unwrap(),
            f.source
        );
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let mut params = retry(&f.source, &pending);
            params["restoreCurrent"] = json!(true);
            let response = f
                .engine
                .dispatch(json!({"method":"agent.provider.select","params":params}));
            assert!(response.get("error").is_none(), "{response}");
            if response["result"]["pending"] != true {
                assert_eq!(response["result"]["selectionUnchanged"], true);
                assert_eq!(response["result"]["thread"], f.source);
                assert_eq!(response["result"]["catalog"]["authenticationChecked"], true);
                assert_eq!(
                    response["result"]["executionReady"],
                    saved_model != "unavailable-saved-model"
                );
                if saved_model == "unavailable-saved-model" {
                    assert!(
                        response["result"]["reason"]
                            .as_str()
                            .unwrap()
                            .contains("not reported"),
                        "{response}"
                    );
                }
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
            f.source,
            "warmup must preserve native resume tuple, all content and preferences"
        );
        assert_eq!(call(&mut f.engine, "settings.read", json!({})), settings);
        {
            let capabilities = call(
                &mut f.engine,
                "agent.selection.capabilities",
                json!({"threadId":f.source["id"]}),
            );
            assert_eq!(capabilities["namedModels"]["accountCatalogReady"], true);
            assert_eq!(
                capabilities["namedModels"]["fullAccessSupported"],
                saved_model != "default" && saved_model != "unavailable-saved-model"
            );
            assert_eq!(
                capabilities["locked"],
                saved_model == "unavailable-saved-model"
            );
        }
        drain(&mut f.engine);
    }

    // Busy readers are admission pressure, not evidence an account is unready.
    // Wait for the exact ready observation instead of silently falling back.
    let mut f = fixture(&root, "busy-catalog-admission");
    for (account, home) in [(&f.a, &f.a_home), (&f.b, &f.b_home)] {
        fs::write(home.join("hold"), "synthetic").unwrap();
        let mut selected = f.source.clone();
        selected["selection"] = json!({"provider":"codex","modelID":"default","accountID":account});
        f.engine.store.save(&selected).unwrap();
        call(
            &mut f.engine,
            "providers.codex.profiles.models.refresh",
            json!({"threadId":f.source["id"],"accountId":account,"expectedSelection":selected["selection"]}),
        );
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    while !f.a_home.join("held").exists() || !f.b_home.join("held").exists() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
    f.engine.store.save(&f.source).unwrap();
    let pending = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&f.source, "codex"),
    );
    assert_eq!(pending["pending"], true);
    assert_eq!(pending["accountID"], f.a);
    assert_eq!(pending["catalogRequestId"], Value::Null);
    assert_eq!(
        f.engine
            .store
            .thread(f.source["id"].as_str().unwrap())
            .unwrap(),
        f.source
    );
    fs::remove_file(f.a_home.join("hold")).unwrap();
    fs::remove_file(f.b_home.join("hold")).unwrap();
    let response = finish(&mut f.engine, &f.source, &pending);
    assert_eq!(response["accountID"], f.a);
    assert_eq!(response["fallback"], false);
    drain(&mut f.engine);
    assert_eq!(
        f.engine.model_catalog_shutdown_status().unwrap().returned,
        2
    );

    // Explicit account picks go directly from A's active model to B after
    // B's observation, with no temporary default/wrong-account selection.
    let mut f = fixture(&root, "direct-account");
    let pending = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&f.source, "codex"),
    );
    let a = finish(&mut f.engine, &f.source, &pending)["thread"].clone();
    let mut params = expected(&a, "codex");
    params["accountId"] = json!(f.b);
    let pending = call(&mut f.engine, "agent.provider.select", params);
    assert_eq!(pending["pending"], true);
    assert_eq!(f.engine.store.thread(a["id"].as_str().unwrap()).unwrap(), a);
    let b = finish_explicit(&mut f.engine, &a, &pending, json!(f.b));
    assert_eq!(b["thread"]["selection"]["accountID"], f.b);
    assert_eq!(b["model"], "synthetic-b");
    assert_eq!(b["explicitAccount"], true);
    assert_eq!(b["fallback"], false);
    drain(&mut f.engine);

    // Cancellation is irreversible. A new explicit action must own a fresh
    // job even while the cancelled worker is still returning; stale tokens
    // cannot cancel the newer intent or reset the old job's revoked flag.
    let mut f = fixture(&root, "cancel-fresh-retry");
    fs::write(f.a_home.join("block"), "synthetic").unwrap();
    let old = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&f.source, "codex"),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    while !f.a_home.join("blocked").exists() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
    call(&mut f.engine, "agent.provider.cancelRestore", json!({}));
    fs::remove_file(f.a_home.join("block")).unwrap();
    let fresh = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&f.source, "codex"),
    );
    assert_ne!(old["requestId"], fresh["requestId"]);
    assert_ne!(
        old["catalogRequestId"], fresh["catalogRequestId"],
        "cancelled observations cannot be reused by a new intent"
    );
    refused(&mut f.engine, retry(&f.source, &old));
    let result = finish(&mut f.engine, &f.source, &fresh);
    assert_eq!(result["accountID"], f.a);
    drain(&mut f.engine);
    let ledger = f.engine.model_catalog_shutdown_status().unwrap();
    assert_eq!(ledger.returned, 2);
    assert_eq!(ledger.running, 0);
    assert_eq!(ledger.panicked, 0);
    assert_eq!(ledger.unclassified, 0);

    let mut f = fixture(&root, "cancel-default-fresh-retry");
    let blocked = root.join("home/.codex/blocked");
    if blocked.exists() {
        fs::remove_file(&blocked).unwrap();
    }
    fs::write(root.join("default-mode"), "block").unwrap();
    let mut start = expected(&f.source, "codex");
    start["accountId"] = Value::Null;
    let old = call(&mut f.engine, "agent.provider.select", start.clone());
    let deadline = Instant::now() + Duration::from_secs(10);
    while !blocked.exists() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
    call(&mut f.engine, "agent.provider.cancelRestore", json!({}));
    fs::write(root.join("default-mode"), "apiKey").unwrap();
    let fresh = call(&mut f.engine, "agent.provider.select", start);
    assert_ne!(old["requestId"], fresh["requestId"]);
    assert_ne!(old["catalogRequestId"], fresh["catalogRequestId"]);
    let result = finish_explicit(&mut f.engine, &f.source, &fresh, Value::Null);
    assert_eq!(result["model"], "synthetic-default");
    assert_eq!(result["authenticationChecked"], true);
    assert_eq!(result["accountRestored"], false);
    drain(&mut f.engine);
    assert_eq!(
        f.engine.model_catalog_shutdown_status().unwrap().returned,
        2
    );
    fs::write(root.join("default-mode"), "deny").unwrap();

    // The remembered account is tried first. If unavailable, each candidate's
    // readiness is actually checked. A default API-key account is distinct from
    // named subscription homes and can legitimately be the first ready one.
    for default_ready in [false, true] {
        let mut f = fixture(
            &root,
            if default_ready {
                "fallback-default"
            } else {
                "fallback-named"
            },
        );
        fs::write(f.a_home.join("deny"), "synthetic").unwrap();
        fs::write(
            root.join("default-mode"),
            if default_ready { "apiKey" } else { "deny" },
        )
        .unwrap();
        let before = records(&root).len();
        let pending = call(
            &mut f.engine,
            "agent.provider.select",
            expected(&f.source, "codex"),
        );
        assert_eq!(
            f.engine
                .store
                .thread(f.source["id"].as_str().unwrap())
                .unwrap(),
            f.source
        );
        let response = finish(&mut f.engine, &f.source, &pending);
        assert_eq!(response["fallback"], true);
        assert_eq!(response["requestedAccountID"], f.a);
        assert_eq!(response["authenticationChecked"], true);
        assert_eq!(
            response["accountID"],
            if default_ready {
                json!("default")
            } else {
                json!(f.b)
            }
        );
        assert_eq!(
            response["model"],
            if default_ready {
                "synthetic-default"
            } else {
                "synthetic-b"
            }
        );
        let calls = &records(&root)[before..];
        let observed = calls
            .iter()
            .filter(|row| row["method"] == "account/read")
            .map(|row| row["home"].clone())
            .collect::<Vec<_>>();
        let mut expected = vec![json!(f.a_home), json!(root.join("home/.codex"))];
        if !default_ready {
            expected.push(json!(f.b_home));
        }
        assert_eq!(
            observed, expected,
            "fallback order must come from actual bounded observations"
        );
        drain(&mut f.engine);
    }
    fs::write(root.join("default-mode"), "deny").unwrap();
    let mut f = fixture(&root, "fallback-no-ready");
    fs::write(f.a_home.join("deny"), "synthetic").unwrap();
    fs::write(f.b_home.join("deny"), "synthetic").unwrap();
    let pending = call(
        &mut f.engine,
        "agent.provider.select",
        expected(&f.source, "codex"),
    );
    let result = finish(&mut f.engine, &f.source, &pending);
    assert_eq!(result["model"], "default");
    assert_eq!(result["authenticationChecked"], false);
    assert_eq!(result["fallbackReason"], "no_authenticated_account_ready");
    assert_eq!(result["thread"]["draft"], f.source["draft"]);
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
        let mut start = expected(&f.source, "codex");
        if case == "unauthenticated" {
            start["accountId"] = json!(f.a);
        }
        let pending = call(&mut f.engine, "agent.provider.select", start);
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
                    let mut params = retry(&f.source, &pending);
                    params["accountId"] = json!(f.a);
                    let response = f
                        .engine
                        .dispatch(json!({"method":"agent.provider.select","params":params}));
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
