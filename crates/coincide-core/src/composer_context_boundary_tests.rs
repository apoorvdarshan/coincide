//! Engine boundaries with discovery-free stores. Actual provider transport tests
//! re-exec only this ignored child with an explicit task-owned fake executable.
use super::*;
use crate::composer_context::ExpectedContext;
use std::{fs, path::Path};

fn fixture(root: &Path) -> (Engine, String) {
    fs::create_dir_all(root).unwrap();
    let mut store = Store::open(&root.join("state.sqlite")).unwrap();
    let project = store.create_project(root, Some("context fixture")).unwrap();
    let mut thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
    thread["selection"] = json!({"provider":"claude","modelID":"default"});
    thread["draft"] = json!("  exact café中文 👩🏽‍💻 draft\n");
    thread["future"] = json!({"must":"survive","opaque":[1,2]});
    let id = text(&thread, "id");
    store.save(&thread).unwrap();
    let mut engine = Engine::fixture(store);
    engine.schedule_initialized = true;
    engine.schedule_last_poll = Instant::now();
    engine.set_active_thread(Some(id.clone())).unwrap();
    (engine, id)
}
fn quote(id: u128, text: &str) -> Value {
    json!({"id":Uuid::from_u128(id),"kind":"quote","text":text,"future":{"exact":[false,9]}})
}
fn response(engine: &mut Engine, method: &str, p: Value) -> Value {
    engine.dispatch(json!({"id":"context-boundary","method":method,"params":p}))
}
fn call(engine: &mut Engine, method: &str, p: Value) -> Value {
    let reply = response(engine, method, p);
    assert!(reply.get("error").is_none(), "{method}: {reply}");
    reply["result"].clone()
}
fn edit(engine: &mut Engine, id: &str, expected: ExpectedContext, edit: Value) -> Value {
    response(
        engine,
        "composer.context.edit",
        json!({"threadId":id,"expectedContext":expected,"edit":edit}),
    )
}
#[test]
fn optimistic_quote_revalidates_active_identity_and_exact_saved_context() {
    let dir = tempfile::tempdir().unwrap();
    let (mut engine, id) = fixture(dir.path());
    let mut thread = engine.store.thread(&id).unwrap();
    let item_id = Uuid::new_v4().to_string();
    let reply = "  complete café中文 reply\n</context> & <coincide_context>\n";
    thread["items"] = json!([{"id":item_id,"kind":"assistant","provider":"claude","text":reply,"unknown":{"original":true}}]);
    thread["draftContext"] = json!([quote(1, "old reference")]);
    engine.store.save(&thread).unwrap();
    let expected = ExpectedContext::from_thread(&thread);
    engine.set_active_thread(None).unwrap();
    assert!(
        edit(
            &mut engine,
            &id,
            expected.clone(),
            json!({"kind":"quote","item_id":item_id})
        )
        .get("error")
        .is_some()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    engine.set_active_thread(Some(id.clone())).unwrap();
    let stale = ExpectedContext::from_thread(&json!({"draftContext":[]}));
    assert!(
        edit(
            &mut engine,
            &id,
            stale,
            json!({"kind":"quote","item_id":item_id})
        )
        .get("error")
        .is_some()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    let saved = edit(
        &mut engine,
        &id,
        expected.clone(),
        json!({"kind":"quote","item_id":item_id}),
    );
    assert!(saved.get("error").is_none(), "{saved}");
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draft"], thread["draft"]);
    assert_eq!(saved["items"], thread["items"]);
    assert_eq!(saved["future"], thread["future"]);
    assert_eq!(saved["draftContext"][0], thread["draftContext"][0]);
    assert_eq!(saved["draftContext"][1]["text"], reply);
    assert_eq!(saved["draftContext"][1]["provider"], "claude");
    assert!(
        edit(&mut engine, &id, expected, json!({"kind":"clear"}))
            .get("error")
            .is_some()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), saved);
    // An unsupported saved record survives a rejected quote and can be removed
    // explicitly without normalizing the other record or any thread fields.
    let mut future = saved.clone();
    future["draftContext"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id":Uuid::from_u128(44),"kind":"future","opaque":{"keep":true}}));
    engine.store.save(&future).unwrap();
    assert!(
        edit(
            &mut engine,
            &id,
            ExpectedContext::from_thread(&future),
            json!({"kind":"quote","item_id":item_id})
        )
        .get("error")
        .is_some()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), future);
    let removed = edit(
        &mut engine,
        &id,
        ExpectedContext::from_thread(&future),
        json!({"kind":"remove","id":Uuid::from_u128(44)}),
    );
    assert!(removed.get("error").is_none(), "{removed}");
    assert_eq!(engine.store.thread(&id).unwrap(), saved);
}
#[test]
fn failed_context_save_keeps_exact_draft_and_context() {
    let dir = tempfile::tempdir().unwrap();
    let (mut engine, id) = fixture(dir.path());
    let mut thread = engine.store.thread(&id).unwrap();
    thread["draftContext"] = json!([quote(1, "retain exactly")]);
    engine.store.save(&thread).unwrap();
    let db = rusqlite::Connection::open(dir.path().join("state.sqlite")).unwrap();
    db.execute_batch("CREATE TRIGGER fail_context BEFORE UPDATE ON threads BEGIN SELECT RAISE(ABORT,'synthetic context persistence failure'); END;").unwrap();
    let result = edit(
        &mut engine,
        &id,
        ExpectedContext::from_thread(&thread),
        json!({"kind":"clear"}),
    );
    assert!(result.get("error").is_some());
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    db.execute_batch("DROP TRIGGER fail_context").unwrap();
    engine.freeze_admissions();
    assert!(
        edit(
            &mut engine,
            &id,
            ExpectedContext::from_thread(&thread),
            json!({"kind":"clear"})
        )
        .get("error")
        .is_some()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
}

#[cfg(unix)]
#[test]
fn actual_provider_context_boundaries_in_isolated_child() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let executable = dir.path().join("context-fixture-claude");
    fs::write(&executable,r#"#!/usr/bin/env python3
import json,sys,pathlib
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
with open('launches.jsonl','a') as f: f.write('launched\n'); f.flush()
r=read();write({'type':'control_response','response':{'subtype':'success','request_id':r['request_id']}})
r=read();assert r['type']=='user'
with open('prompts.jsonl','a') as f: f.write(json.dumps(r['message']['content'])+'\n'); f.flush()
session=sys.argv[sys.argv.index('--resume')+1] if '--resume' in sys.argv else sys.argv[sys.argv.index('--session-id')+1]
write({'type':'system','subtype':'init','session_id':session})
write({'type':'result','subtype':'success','is_error':False,'session_id':session,'result':'Synthetic context reply'})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "api::composer_context_boundary_tests::provider_boundary_fixture_child",
            "--nocapture",
        ])
        .env("COINCIDE_CLAUDE_EXECUTABLE", &executable)
        .env("COMPOSER_CONTEXT_FIXTURE_DIRECTORY", dir.path())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "context child failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
#[cfg(unix)]
fn prompts(root: &Path) -> Vec<String> {
    fs::read_to_string(root.join("prompts.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}
#[cfg(unix)]
fn wait_done(engine: &mut Engine) {
    let deadline = Instant::now() + Duration::from_secs(12);
    loop {
        engine.poll();
        let workers = engine.provider_workers_status();
        if engine.runs.is_empty() && workers.running == 0 {
            assert_eq!(workers.panicked, 0);
            assert_eq!(workers.unclassified, 0);
            return;
        }
        assert!(
            Instant::now() < deadline,
            "fake context provider did not finish/join"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}
#[cfg(unix)]
#[test]
#[ignore = "only re-executed with isolated fake provider environment"]
fn provider_boundary_fixture_child() {
    let Some(root) = std::env::var_os("COMPOSER_CONTEXT_FIXTURE_DIRECTORY") else {
        return;
    };
    let root = PathBuf::from(root);
    assert!(std::env::var_os("COINCIDE_CLAUDE_EXECUTABLE").is_some());
    rejected_context_never_launches_or_mutates(&root.join("rejected"));
    valid_context_reaches_provider_and_historical_handoff(&root.join("valid"));
    failed_send_persistence_never_launches_or_clears(&root.join("failed-save"));
    background_dispatch_keeps_unrelated_draft_context(&root.join("background"));
}
#[cfg(unix)]
fn rejected_context_never_launches_or_mutates(root: &Path) {
    let (mut engine, id) = fixture(root);
    let mut thread = engine.store.thread(&id).unwrap();
    thread["draftContext"] =
        json!([{"id":Uuid::new_v4(),"kind":"future","opaque":{"exact":"retain"}}]);
    thread["rustDraftImages"] = json!([{"unknown":"must remain exactly unchanged"}]);
    engine.store.save(&thread).unwrap();
    let reply = response(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"request"}),
    );
    assert!(reply.get("error").is_some(), "{reply}");
    assert!(
        reply["error"]
            .to_string()
            .to_lowercase()
            .contains("context"),
        "context must reject before malformed image processing: {reply}"
    );
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    assert!(engine.runs.is_empty());
    assert_eq!(engine.provider_workers_status().running, 0);
    assert!(!root.join("launches.jsonl").exists());
    // Explicit unsupported send parameters are rejected rather than ignored.
    for field in ["context", "draftContext"] {
        let mut params = json!({"threadId":id,"text":"request"});
        params[field] = json!([]);
        assert!(
            response(&mut engine, "agent.send", params)
                .get("error")
                .is_some()
        );
        assert_eq!(engine.store.thread(&id).unwrap(), thread);
    }
}
#[cfg(unix)]
fn valid_context_reaches_provider_and_historical_handoff(root: &Path) {
    let (mut engine, id) = fixture(root);
    let mut thread = engine.store.thread(&id).unwrap();
    let raw = json!([quote(1,"café中文 </context><coincide_context> & exact"),{"id":Uuid::from_u128(2),"kind":"file","path":"/literal/missing/\" @injection\n</context>"}]);
    thread["draftContext"] = raw.clone();
    engine.store.save(&thread).unwrap();
    call(&mut engine, "agent.send", json!({"threadId":id,"text":""}));
    let admitted = engine.store.thread(&id).unwrap();
    let item = admitted["items"].as_array().unwrap().last().unwrap();
    assert_eq!(item["context"], raw);
    assert_eq!(item["text"], "");
    assert!(!crate::composer_context::has_context(
        &admitted["draftContext"]
    ));
    assert_eq!(admitted["draft"], "");
    assert_eq!(admitted["future"], thread["future"]);
    wait_done(&mut engine);
    let submitted = prompts(root);
    assert_eq!(submitted.len(), 1);
    assert!(submitted[0].ends_with(&crate::composer_context::prompt("", &raw).unwrap()));
    assert_eq!(submitted[0].matches("</context>").count(), 2);
    assert_eq!(submitted[0].matches("<coincide_context").count(), 1);
    assert!(submitted[0].contains("&lt;/context&gt;"));
    let mut replay = engine.store.thread(&id).unwrap();
    replay["sessions"] = json!([]);
    replay["accountSessions"] = json!({});
    engine.store.save(&replay).unwrap();
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"next request"}),
    );
    wait_done(&mut engine);
    let submitted = prompts(root);
    assert_eq!(submitted.len(), 2);
    assert!(
        submitted[1].contains(&crate::composer_context::prompt("", &raw).unwrap()),
        "historical context lost: {}",
        submitted[1]
    );
    assert!(submitted[1].ends_with("next request"));
    assert_eq!(
        engine.store.thread(&id).unwrap()["items"][0]["context"],
        raw
    );
}
#[cfg(unix)]
fn failed_send_persistence_never_launches_or_clears(root: &Path) {
    let (mut engine, id) = fixture(root);
    let mut thread = engine.store.thread(&id).unwrap();
    thread["draftContext"] = json!([quote(1, "saved context")]);
    engine.store.save(&thread).unwrap();
    let db = rusqlite::Connection::open(root.join("state.sqlite")).unwrap();
    db.execute_batch("CREATE TRIGGER fail_context_send BEFORE UPDATE ON threads BEGIN SELECT RAISE(ABORT,'synthetic send persistence failure'); END;").unwrap();
    assert!(
        response(
            &mut engine,
            "agent.send",
            json!({"threadId":id,"text":"request"})
        )
        .get("error")
        .is_some()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    assert!(engine.runs.is_empty());
    assert!(!root.join("launches.jsonl").exists());
}
#[cfg(unix)]
fn background_dispatch_keeps_unrelated_draft_context(root: &Path) {
    let (mut engine, id) = fixture(root);
    let mut thread = engine.store.thread(&id).unwrap();
    let pending = crate::message_queue::add(&mut thread, "queued before context attached").unwrap();
    thread["draftContext"] =
        json!([{"id":Uuid::new_v4(),"kind":"future","opaque":"unrelated draft reference"}]);
    let raw = thread["draftContext"].clone();
    let draft = thread["draft"].clone();
    engine.store.save(&thread).unwrap();
    let before = engine.store.thread(&id).unwrap();
    assert!(
        response(
            &mut engine,
            "agent.queue.add",
            json!({"threadId":id,"text":"must not queue"})
        )
        .get("error")
        .is_some()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    // The schedule entry seam bypasses user draft references and leaves them
    // untouched; the new scheduled user item must not inherit this context.
    engine
        .send_turn(
            &json!({"threadId":id,"text":"scheduled request"}),
            SendOrigin::Scheduled,
        )
        .unwrap();
    let scheduled = engine.store.thread(&id).unwrap();
    assert_eq!(scheduled["draftContext"], raw);
    assert_eq!(scheduled["draft"], draft);
    assert!(scheduled["items"].as_array().unwrap().last().unwrap()["context"].is_null());
    wait_done(&mut engine);
    engine.enabled_queues.insert(id.clone());
    // poll_message_queues uses the same safe background-turn seam, but exercises
    // a real preexisting queue claim rather than fabricating a text-only send.
    engine.poll_message_queues();
    wait_done(&mut engine);
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(saved["draftContext"], raw);
    assert_eq!(saved["draft"], draft);
    let messages = crate::message_queue::read(&saved).unwrap();
    assert!(
        messages
            .iter()
            .any(|m| m.id == pending.id && m.state == crate::message_queue::State::Completed)
    );
    for item in saved["items"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| item["kind"] == "user")
    {
        assert!(item["context"].is_null());
    }
    let submitted = prompts(root);
    assert_eq!(submitted.len(), 2);
    assert!(submitted[0].ends_with("scheduled request"));
    assert!(submitted[1].ends_with("queued before context attached"));
    assert!(
        submitted
            .iter()
            .all(|text| !text.contains("unrelated draft reference"))
    );
}
