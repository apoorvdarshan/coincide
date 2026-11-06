//! Actual Engine/Store and owned fake processes. No live CLI, login or credentials.
#![cfg(unix)]
use coincide_core::{
    api::Engine,
    store::{Store, text},
};
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant},
};

const REFRESH: &str = "providers.codex.profiles.models.refresh";
const SELECT: &str = "providers.codex.profiles.models.select";
#[test]
fn named_resume_requires_saved_owned_same_context_and_reauthenticates() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    let executable = root.join("fake-resume");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(__file__).parent
home=Path(os.environ['CODEX_HOME'])
assert home.parent.name=='codex' and home.parent.parent.name=='providers'
for key in ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','CHATGPT_BASE_URL','HTTPS_PROXY','COINCIDE_RESUME_ROOT']:
 assert key not in os.environ,key
for flag in ['cli_auth_credentials_store="file"','forced_login_method="chatgpt"','model_provider="openai"']:
 assert flag in sys.argv,flag
assert 'coincide-unbound-' in os.environ['COINCIDE_CONTROL_SOCKET']
cfg=json.loads((home/'fixture.json').read_text())
def record(v):
 with (root/'calls.jsonl').open('a') as f:f.write(json.dumps({'home':str(home),'pid':os.getpid(),**v})+'\n')
def read():
 line=sys.stdin.readline()
 if not line:sys.exit(0)
 v=json.loads(line);record({'method':v.get('method'),'params':v.get('params')});return v
def write(v):print(json.dumps(v),flush=True)
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read();assert r['method']=='account/read' and r['params']=={'refreshToken':False}
write({'id':r['id'],'result':{'requiresOpenaiAuth':True,'account':None if cfg.get('behavior')=='deny' else {'type':'chatgpt'}}})
r=read()
if r['method']=='model/list':
 write({'id':r['id'],'result':{'data':[{'model':cfg['model'],'supportedReasoningEfforts':[{'reasoningEffort':'high'}],'serviceTiers':[{'id':'priority','name':'Synthetic Priority'}]}],'nextCursor':None}})
 sys.stdin.readline();sys.exit(0)
assert r['method']==cfg['method'],r
assert r['params']['cwd']==os.getcwd()
assert r['params']['approvalPolicy']=='untrusted' and r['params']['sandbox']=='read-only'
if cfg['model']=='default':assert 'model' not in r['params']
else:assert r['params']['model']==cfg['model']
if cfg['method']=='thread/resume':
 assert r['params']['threadId']==cfg['native'] and r['params']['excludeTurns'] is True
 native=cfg['native']
else:
 assert 'threadId' not in r['params']
 native=home.name+'-'+str(os.getpid())
resolved=cfg.get('resolved','synthetic-resolved') if cfg['model']=='default' else cfg['model']
result={'thread':{'id':'wrong-native' if cfg.get('behavior')=='wrong-id' else native},'model':'wrong-model' if cfg.get('behavior')=='wrong-model' else resolved}
write({'id':r['id'],'result':result})
r=read();assert r['method']=='turn/start'
assert r['params']['threadId']==native
assert r['params']['model']==resolved
assert r['params']['approvalPolicy']==('never' if cfg.get('access')=='fullAccess' else 'untrusted')
assert r['params']['sandboxPolicy']=={'type':'dangerFullAccess' if cfg.get('access')=='fullAccess' else 'readOnly'}
effort=cfg.get('effort')
assert r['params']['collaborationMode']=={'mode':'default','settings':{'model':resolved,'reasoning_effort':effort,'developer_instructions':None}}
if effort is None:assert 'effort' not in r['params']
else:assert r['params']['effort']==effort
if cfg.get('speed') is None:assert 'serviceTier' not in r['params']
else:assert r['params']['serviceTier']==cfg['speed']
record({'native':native,'turn':r['params']})
write({'id':r['id'],'result':{'turn':{'id':'synthetic-turn'}}})
if cfg.get('behavior') in ['hold','gate']:
 (root/'turn-held').write_text('ready')
 if cfg['behavior']=='hold':sys.stdin.readline();sys.exit(0)
 with (root/'release').open('rb') as release:assert release.read(1)==b'1'
write({'method':'turn/completed','params':{'threadId':native,'turn':{'id':'synthetic-turn','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "resume_fixture_child",
            "--nocapture",
        ])
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap())
        .env("HOME", &root)
        .env("COINCIDE_RESUME_ROOT", &root)
        .env("COINCIDE_CODEX_EXECUTABLE", &executable)
        .env("OPENAI_API_KEY", "synthetic-hostile")
        .env("HTTPS_PROXY", "http://invalid.invalid")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    // Separate OS processes: no Engine memory, Arc or receipt object can cross
    // either boundary. The original cleared environment remains enforced.
    for stage in ["default", "explicit"] {
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--ignored",
                "--exact",
                "durable_restart_child",
                "--nocapture",
            ])
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap())
            .env("HOME", &root)
            .env("COINCIDE_RESUME_ROOT", &root)
            .env("COINCIDE_CODEX_EXECUTABLE", &executable)
            .env("COINCIDE_RESUME_STAGE", stage)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{stage}: {} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
fn call(e: &mut Engine, method: &str, params: Value) -> Value {
    let response = e.dispatch(json!({"method":method,"params":params}));
    assert!(response.get("error").is_none(), "{method}: {response}");
    response["result"].clone()
}
fn calls(root: &Path) -> Vec<Value> {
    fs::read_to_string(root.join("calls.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}
fn raw(root: &Path) -> Vec<(String, String)> {
    let db = rusqlite::Connection::open(root.join("state/state.sqlite")).unwrap();
    let mut out = Vec::new();
    for (table, query) in [
        ("threads", "SELECT id,document FROM threads ORDER BY id"),
        (
            "summaries",
            "SELECT id,json_array(title,project_id,archived,pinned,updated_at,search_body,snoozed_until) FROM thread_summaries ORDER BY id",
        ),
        (
            "search",
            "SELECT thread_id,json_array(title,body) FROM search ORDER BY thread_id,title,body",
        ),
        (
            "trigram",
            "SELECT thread_id,body FROM search_trigram ORDER BY thread_id,body",
        ),
        (
            "documents",
            "SELECT name,document FROM documents ORDER BY name",
        ),
        (
            "original_files",
            "SELECT path,hex(data) FROM original_files ORDER BY path",
        ),
    ] {
        let mut query = db.prepare(query).unwrap();
        for row in query
            .query_map([], |r| {
                Ok((
                    format!("{table}/{}", r.get::<_, String>(0)?),
                    r.get::<_, String>(1)?,
                ))
            })
            .unwrap()
        {
            out.push(row.unwrap());
        }
    }
    out
}
fn refuse(e: &mut Engine, root: &Path, id: &str) {
    let before = raw(root);
    let rpc = calls(root);
    assert!(e.dispatch(json!({"method":"agent.send","params":{"threadId":id,"text":"Must refuse without effects"}})).get("error").is_some());
    assert_eq!(raw(root), before);
    assert_eq!(calls(root), rpc);
}
fn settle(e: &mut Engine) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let status = call(e, "app.status", json!({}));
        if status["running"].as_array().unwrap().is_empty()
            && e.provider_workers_status().running == 0
        {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "Owned fake worker did not finish"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn config(
    home: &Path,
    model: &str,
    method: &str,
    native: Option<&str>,
    behavior: &str,
    access: &str,
) {
    fs::write(home.join("fixture.json"),serde_json::to_vec(&json!({"model":model,"method":method,"native":native,"behavior":behavior,"access":access,"effort":if model=="synthetic-a"{Some("high")}else{None},"speed":if model=="synthetic-a"{Some("priority")}else{None}})).unwrap()).unwrap();
}
fn refresh(e: &mut Engine, id: &str) -> Value {
    let t = e.store.thread(id).unwrap();
    let result = call(
        e,
        REFRESH,
        json!({"threadId":id,"accountId":t["selection"]["accountID"],"expectedSelection":t["selection"]}),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let value = call(
            e,
            "providers.codex.profiles.models.status",
            json!({"threadId":id,"accountId":t["selection"]["accountID"],"requestId":result["requestId"]}),
        );
        if value["state"] != "loading" {
            assert_eq!(value["state"], "ready");
            return value;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn select(e: &mut Engine, id: &str, model: &str, request: Option<&Value>, access: &str) {
    let t = e.store.thread(id).unwrap();
    let mut params = json!({"threadId":id,"accountId":t["selection"]["accountID"],"expectedSelection":t["selection"],"expectedAccessMode":t["accessMode"],"expectedInteractionMode":t["interactionMode"],"model":model,"accessMode":access,"effort":if model=="synthetic-a"{Some("high")}else{None},"speed":if model=="synthetic-a"{Some("priority")}else{None}});
    if let Some(request) = request {
        params["requestId"] = request["requestId"].clone();
    }
    call(e, SELECT, params);
}
fn send(e: &mut Engine, id: &str, prompt: &str) {
    call(e, "agent.send", json!({"threadId":id,"text":prompt}));
    settle(e);
    let t = e.store.thread(id).unwrap();
    assert!(
        t["items"]
            .as_array()
            .unwrap()
            .last()
            .is_some_and(|item| item["kind"] == "notice"),
        "{t}"
    );
}
fn native(e: &Engine, id: &str) -> String {
    text(
        &e.store.thread(id).unwrap()["sessions"]["codex"],
        "sessionID",
    )
}
fn marker(root: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !root.join("turn-held").exists() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn finish(e: &mut Engine, expected: u64) {
    e.freeze_admissions();
    e.request_model_catalog_shutdown().unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let state = e.model_catalog_shutdown_status().unwrap();
        if state.running == 0 {
            assert_eq!((state.panicked, state.unclassified), (0, 0));
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
    let workers = e.provider_workers_status();
    assert_eq!(
        (
            workers.running,
            workers.returned,
            workers.panicked,
            workers.unclassified
        ),
        (0, expected, 0, 0)
    );
}
#[test]
#[ignore = "Outer owns the cleared environment, private HOME and fake executable"]
fn resume_fixture_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_RESUME_ROOT").unwrap());
    let dbpath = root.join("state/state.sqlite");
    let mut e = Engine::new(Store::open(&dbpath).unwrap());
    let project = call(
        &mut e,
        "projects.create",
        json!({"path":root,"name":"Synthetic resume"}),
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
    let a = call(
        &mut e,
        "providers.codex.profiles.create",
        json!({"name":"Synthetic A"}),
    );
    let b = call(
        &mut e,
        "providers.codex.profiles.create",
        json!({"name":"Synthetic B"}),
    );
    let data = e.store.data_directory().unwrap();
    let ha = data.join("providers/codex").join(text(&a, "id"));
    let hb = data.join("providers/codex").join(text(&b, "id"));
    for home in [&ha, &hb] {
        config(
            home,
            "synthetic-a",
            "thread/start",
            None,
            "allow",
            "approval",
        );
    }
    let mut t = e.store.thread(&id).unwrap();
    t["future"] = json!({"opaque":[42,"keep"]});
    t["sessions"] = json!({"codex":{"sessionID":"unproved-restored","seenItemCount":99999},"claude":{"sessionID":"other-provider","future":43}});
    t["items"] = json!([{"id":"seed","kind":"user","text":"Original synthetic seed","future":44}]);
    t["draft"] = json!("saved synthetic draft");
    e.store.save(&t).unwrap();
    e.store
        .save_document("resume-fixture.json", &json!({"future":[42]}))
        .unwrap();
    let unrelated = e.store.thread(&text(&other, "id")).unwrap();
    let documents = e.store.document("resume-fixture.json").unwrap();
    call(
        &mut e,
        "providers.codex.profiles.select",
        json!({"threadId":id,"accountId":a["id"],"expectedSelection":t["selection"]}),
    );
    let catalog = refresh(&mut e, &id);
    select(&mut e, &id, "synthetic-a", Some(&catalog), "approval");
    send(&mut e, &id, "first owned A turn");
    let first = native(&e, &id);
    let mut t = e.store.thread(&id).unwrap();
    t["sessions"]["codex"]["seenItemCount"] = json!(0);
    e.store.save(&t).unwrap();
    config(
        &ha,
        "synthetic-a",
        "thread/resume",
        Some(&first),
        "allow",
        "approval",
    );
    send(&mut e, &id, "second owned A turn");
    assert_eq!(native(&e, &id), first);
    let rows = calls(&root);
    let turns: Vec<_> = rows.iter().filter(|r| r.get("turn").is_some()).collect();
    assert_eq!(turns.len(), 2);
    assert!(
        turns[0]["turn"]["input"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Original synthetic seed")
    );
    assert_eq!(turns[1]["turn"]["input"][0]["text"], "second owned A turn");
    // A real prefix edit cannot reuse even this Engine's private seen boundary.
    let mut t = e.store.thread(&id).unwrap();
    t["items"][0]["text"] = json!("Edited synthetic seed");
    e.store.save(&t).unwrap();
    config(
        &ha,
        "synthetic-a",
        "thread/start",
        None,
        "allow",
        "approval",
    );
    send(&mut e, &id, "after prefix edit");
    // Changing modes and replacing the catalog generation each force fresh ownership.
    select(&mut e, &id, "synthetic-a", Some(&catalog), "fullAccess");
    config(
        &ha,
        "synthetic-a",
        "thread/start",
        None,
        "allow",
        "fullAccess",
    );
    send(&mut e, &id, "changed access");
    let catalog = refresh(&mut e, &id);
    select(&mut e, &id, "synthetic-a", Some(&catalog), "fullAccess");
    send(&mut e, &id, "new catalog generation");
    // A changed auth file is not account identity; reauthentication/catalog is required.
    fs::write(
        ha.join("auth.json"),
        "Synthetic metadata marker, not credentials",
    )
    .unwrap();
    fs::set_permissions(ha.join("auth.json"), fs::Permissions::from_mode(0o600)).unwrap();
    refuse(&mut e, &root, &id);
    let catalog = refresh(&mut e, &id);
    select(&mut e, &id, "synthetic-a", Some(&catalog), "fullAccess");
    send(&mut e, &id, "new auth context");
    let exe = root.join("fake-resume");
    let old = fs::read(&exe).unwrap();
    let mut changed = old.clone();
    changed.extend_from_slice(b"\n# synthetic executable revision\n");
    fs::write(&exe, changed).unwrap();
    refuse(&mut e, &root, &id);
    let catalog = refresh(&mut e, &id);
    select(&mut e, &id, "synthetic-a", Some(&catalog), "fullAccess");
    send(&mut e, &id, "new executable context");
    let before = e.store.thread(&id).unwrap();
    let other_cwd = root.join("changed-cwd");
    fs::create_dir(&other_cwd).unwrap();
    let mut changed = before.clone();
    changed["worktreePath"] = json!(other_cwd);
    e.store.save(&changed).unwrap();
    refuse(&mut e, &root, &id);
    e.store.save(&before).unwrap();
    // B never borrows A's native ID, even if hostile stored JSON supplies it.
    select(&mut e, &id, "default", None, "approval");
    let t = e.store.thread(&id).unwrap();
    call(
        &mut e,
        "providers.codex.profiles.select",
        json!({"threadId":id,"accountId":b["id"],"expectedSelection":t["selection"]}),
    );
    config(
        &hb,
        "synthetic-b",
        "thread/start",
        None,
        "allow",
        "approval",
    );
    let catalog = refresh(&mut e, &id);
    select(&mut e, &id, "synthetic-b", Some(&catalog), "approval");
    let mut t = e.store.thread(&id).unwrap();
    t["sessions"]["codex"] = json!({"sessionID":first,"accountID":b["id"],"seenItemCount":99999});
    e.store.save(&t).unwrap();
    send(&mut e, &id, "first owned B turn");
    let bn = native(&e, &id);
    config(
        &hb,
        "synthetic-b",
        "thread/resume",
        Some(&bn),
        "allow",
        "approval",
    );
    send(&mut e, &id, "second owned B turn");
    // An actual resume ACK for another native ID cannot send a turn or mint proof.
    let before = calls(&root)
        .iter()
        .filter(|r| r.get("turn").is_some())
        .count();
    config(
        &hb,
        "synthetic-b",
        "thread/resume",
        Some(&bn),
        "wrong-id",
        "approval",
    );
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"reject wrong native ACK"}),
    );
    settle(&mut e);
    assert_eq!(
        calls(&root)
            .iter()
            .filter(|r| r.get("turn").is_some())
            .count(),
        before
    );
    assert!(
        e.store.thread(&id).unwrap()["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["kind"] == "error"
                && i["text"]
                    .as_str()
                    .unwrap_or("")
                    .contains("another session or resolved model"))
    );
    config(
        &hb,
        "synthetic-b",
        "thread/start",
        None,
        "allow",
        "approval",
    );
    send(&mut e, &id, "fresh after wrong ACK");
    let bn = native(&e, &id);
    config(
        &hb,
        "synthetic-b",
        "thread/resume",
        Some(&bn),
        "wrong-model",
        "approval",
    );
    let before = calls(&root)
        .iter()
        .filter(|r| r.get("turn").is_some())
        .count();
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"reject wrong resolved model ACK"}),
    );
    settle(&mut e);
    assert_eq!(
        calls(&root)
            .iter()
            .filter(|r| r.get("turn").is_some())
            .count(),
        before
    );
    config(
        &hb,
        "synthetic-b",
        "thread/start",
        None,
        "allow",
        "approval",
    );
    send(&mut e, &id, "fresh after wrong resolved model");
    let bn = native(&e, &id);
    config(
        &hb,
        "synthetic-b",
        "thread/resume",
        Some(&bn),
        "deny",
        "approval",
    );
    let before = calls(&root).len();
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"deny fresh account admission"}),
    );
    settle(&mut e);
    assert!(calls(&root)[before..].iter().all(|r| !matches!(
        r["method"].as_str(),
        Some("thread/start" | "thread/resume" | "turn/start")
    )));
    config(
        &hb,
        "synthetic-b",
        "thread/start",
        None,
        "allow",
        "approval",
    );
    send(&mut e, &id, "fresh after denied auth");
    let bn = native(&e, &id);
    config(
        &hb,
        "synthetic-b",
        "thread/resume",
        Some(&bn),
        "hold",
        "approval",
    );
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"partial cancelled turn"}),
    );
    marker(&root);
    call(&mut e, "agent.stop", json!({"threadId":id}));
    settle(&mut e);
    fs::remove_file(root.join("turn-held")).unwrap();
    config(
        &hb,
        "synthetic-b",
        "thread/start",
        None,
        "allow",
        "approval",
    );
    send(&mut e, &id, "fresh after cancellation");
    let bn = native(&e, &id);
    // Fail only the final transcript save after the actual turn has started.
    let fifo = std::ffi::CString::new(root.join("release").as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: this private fixture owns a new NUL-free path and creates one FIFO.
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    config(
        &hb,
        "synthetic-b",
        "thread/resume",
        Some(&bn),
        "gate",
        "approval",
    );
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"final persistence failure"}),
    );
    marker(&root);
    let db = rusqlite::Connection::open(&dbpath).unwrap();
    db.execute_batch("CREATE TRIGGER reject_completion BEFORE UPDATE ON threads BEGIN SELECT RAISE(ABORT,'synthetic completion persistence failure'); END;").unwrap();
    fs::OpenOptions::new()
        .write(true)
        .open(root.join("release"))
        .unwrap()
        .write_all(b"1")
        .unwrap();
    settle(&mut e);
    assert_eq!(
        call(&mut e, "app.status", json!({}))["persistencePending"],
        1
    );
    db.execute_batch("DROP TRIGGER reject_completion").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if call(&mut e, "app.status", json!({}))["persistencePending"] == 0 {
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
    config(
        &hb,
        "synthetic-b",
        "thread/start",
        None,
        "allow",
        "approval",
    );
    send(&mut e, &id, "fresh after recovered persistence");
    assert_eq!(e.store.thread(&text(&other, "id")).unwrap(), unrelated);
    assert_eq!(e.store.document("resume-fixture.json").unwrap(), documents);
    let saved = e.store.thread(&id).unwrap();
    assert_eq!(saved["future"], t["future"]);
    assert_eq!(saved["sessions"]["claude"]["future"], 43);
    let before_restart = native(&e, &id);
    finish(&mut e, 19);
    drop(e);
    // Model proof still requires fresh admission; the independent journal can
    // restore joined-worker authority once that NEW catalog proof is captured.
    let mut e = Engine::new(Store::open(&dbpath).unwrap());
    e.set_active_thread(Some(id.clone())).unwrap();
    refuse(&mut e, &root, &id);
    let catalog = refresh(&mut e, &id);
    select(&mut e, &id, "synthetic-b", Some(&catalog), "approval");
    config(
        &hb,
        "synthetic-b",
        "thread/resume",
        Some(&before_restart),
        "allow",
        "approval",
    );
    send(&mut e, &id, "resumed after Engine restart");
    assert_eq!(native(&e, &id), before_restart);
    // Provider-default profiles have no catalog model proof. Only their actual
    // resolved-model ACK plus the private journal authorizes continuation.
    select(&mut e, &id, "default", None, "approval");
    config(&hb, "default", "thread/start", None, "allow", "approval");
    send(&mut e, &id, "first default-model owned turn");
    let dn = native(&e, &id);
    config(
        &hb,
        "default",
        "thread/resume",
        Some(&dn),
        "allow",
        "approval",
    );
    send(&mut e, &id, "second default-model owned turn");
    assert_eq!(native(&e, &id), dn);
    finish(&mut e, 3);
    let rows = calls(&root);
    let resumes: Vec<_> = rows
        .iter()
        .filter(|r| r["method"] == "thread/resume")
        .collect();
    assert_eq!(resumes.len(), 8);
    assert!(
        resumes
            .iter()
            .all(|r| r["params"]["threadId"] != "unproved-restored")
    );
    assert_eq!(rows.iter().filter(|r| r.get("turn").is_some()).count(), 19);
    fs::write(
        root.join("restart-fixture.json"),
        serde_json::to_vec(&json!({"id":id,"native":dn,"home":hb})).unwrap(),
    )
    .unwrap();
}

#[test]
#[ignore = "Outer owns private state and launches two distinct restart processes"]
fn durable_restart_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_RESUME_ROOT").unwrap());
    let fixture: Value =
        serde_json::from_slice(&fs::read(root.join("restart-fixture.json")).unwrap()).unwrap();
    let id = text(&fixture, "id");
    let home = PathBuf::from(text(&fixture, "home"));
    let mut e = Engine::new(Store::open(&root.join("state/state.sqlite")).unwrap());
    e.set_active_thread(Some(id.clone())).unwrap();
    let stage = std::env::var("COINCIDE_RESUME_STAGE").unwrap();
    let selected = if stage == "default" {
        "default"
    } else {
        "synthetic-b"
    };
    config(
        &home,
        selected,
        "thread/resume",
        Some(&text(&fixture, "native")),
        "allow",
        "approval",
    );
    // Both explicit and Provider-default cold receipts wait for current private
    // account/catalog admission without consuming the saved ticket or history.
    refuse(&mut e, &root, &id);
    let catalog = refresh(&mut e, &id);
    if stage == "explicit" {
        select(&mut e, &id, selected, Some(&catalog), "approval");
    }
    let prompt = format!("only new prompt after process restart {stage}");
    send(&mut e, &id, &prompt);
    assert_eq!(native(&e, &id), fixture["native"]);
    let rows = calls(&root);
    let last = rows
        .iter()
        .rev()
        .find(|row| row.get("turn").is_some())
        .unwrap();
    assert_eq!(
        last["turn"]["input"][0]["text"], prompt,
        "Native continuation must not replay saved transcript"
    );
    let mut count = 1;
    if stage == "default" {
        config(
            &home,
            "synthetic-b",
            "thread/start",
            None,
            "allow",
            "approval",
        );
        let catalog = refresh(&mut e, &id);
        select(&mut e, &id, "synthetic-b", Some(&catalog), "approval");
        send(
            &mut e,
            &id,
            "new explicit-model source before second restart",
        );
        fs::write(
            root.join("restart-fixture.json"),
            serde_json::to_vec(&json!({"id":id,"native":native(&e,&id),"home":home})).unwrap(),
        )
        .unwrap();
        count += 1;
    }
    finish(&mut e, count);
}
