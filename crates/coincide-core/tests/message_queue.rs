#![cfg(unix)]
use coincide_core::{api::Engine, store::Store};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    process::Command,
    time::{Duration, Instant},
};
#[test]
fn queue_runs_fifo_preserves_drafts_and_recovers_without_replay() {
    let directory = tempfile::tempdir().unwrap();
    let executable = directory.path().join("fixture-schedule-provider");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,sys,time,pathlib
read=lambda:json.loads(sys.stdin.readline())
def write(value): print(json.dumps(value),flush=True)
request=read()
write({'type':'control_response','response':{'subtype':'success','request_id':request['request_id']}})
request=read();assert request['type']=='user'
prompt=request['message']['content'];assert isinstance(prompt,str)
raw_prompt=prompt
prompt=prompt.rsplit('\nCurrent user request:\n',1)[-1]

with open('submitted-prompts.jsonl','a') as log:
 log.write(json.dumps(prompt)+'\n');log.flush()
session=sys.argv[sys.argv.index('--resume')+1] if '--resume' in sys.argv else sys.argv[sys.argv.index('--session-id')+1]
write({'type':'system','subtype':'init','session_id':session})
if prompt.startswith('hold-'):
 deadline=time.monotonic()+30
 while not pathlib.Path('release-'+prompt).exists():
  assert time.monotonic()<deadline,'fixture release timed out'
  time.sleep(0.01)
write({'type':'result','subtype':'success','is_error':False,'session_id':session,'result':'Completed '+prompt})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args(["--ignored", "--exact", "queue_fixture_child", "--nocapture"])
        .env("COINCIDE_CLAUDE_EXECUTABLE", &executable)
        .env("QUEUE_FIXTURE_DIRECTORY", directory.path())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "schedule fixture failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
fn call(e: &mut Engine, method: &str, params: Value) -> Value {
    let v = e.dispatch(json!({"method":method,"params":params}));
    assert!(v.get("error").is_none(), "{method}: {v}");
    v["result"].clone()
}
fn wait(e: &mut Engine, mut done: impl FnMut(&mut Engine) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(12);
    while !done(e) {
        assert!(Instant::now() < deadline, "queue fixture timed out");
        std::thread::sleep(Duration::from_millis(10));
    }
}
fn list(e: &mut Engine, id: &str) -> Value {
    call(e, "agent.queue.list", json!({"threadId":id}))
}
#[test]
#[ignore = "isolated child fixture"]
fn queue_fixture_child() {
    let Some(root) = std::env::var_os("QUEUE_FIXTURE_DIRECTORY") else {
        return;
    };
    let root = std::path::PathBuf::from(root);
    let db = root.join("queue.sqlite");
    let mut e = Engine::new(Store::open(&db).unwrap());
    let t = call(&mut e, "threads.create", json!({"cwd":root}));
    let id = t["id"].as_str().unwrap();
    call(
        &mut e,
        "agent.select",
        json!({"threadId":id,"provider":"claude"}),
    );
    call(
        &mut e,
        "threads.patch",
        json!({"threadId":id,"patch":{"draft":"unsent"}}),
    );
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"hold-first"}),
    );
    call(
        &mut e,
        "threads.patch",
        json!({"threadId":id,"patch":{"draft":"preserved draft"}}),
    );
    call(
        &mut e,
        "agent.queue.add",
        json!({"threadId":id,"text":"second"}),
    );
    let removed = call(
        &mut e,
        "agent.queue.add",
        json!({"threadId":id,"text":"remove-me"}),
    );
    call(
        &mut e,
        "agent.queue.remove",
        json!({"threadId":id,"messageId":removed["message"]["id"]}),
    );
    call(
        &mut e,
        "agent.queue.add",
        json!({"threadId":id,"text":"third"}),
    );
    assert_eq!(list(&mut e, id)["messages"].as_array().unwrap().len(), 2);
    fs::write(root.join("release-hold-first"), "").unwrap();
    wait(&mut e, |e| {
        list(e, id)["messages"]
            .as_array()
            .unwrap()
            .iter()
            .all(|m| m["state"] == "completed")
    });
    assert_eq!(e.store.thread(id).unwrap()["draft"], "preserved draft");
    let prompts = fs::read_to_string(root.join("submitted-prompts.jsonl")).unwrap();
    assert_eq!(
        prompts
            .lines()
            .map(|s| serde_json::from_str::<String>(s).unwrap())
            .collect::<Vec<_>>(),
        ["hold-first", "second", "third"]
    );
    // Stop pauses the queue and does not consume the follow-up.
    call(
        &mut e,
        "agent.send",
        json!({"threadId":id,"text":"hold-stop"}),
    );
    call(
        &mut e,
        "agent.queue.add",
        json!({"threadId":id,"text":"after-stop"}),
    );
    call(&mut e, "agent.stop", json!({"threadId":id}));
    wait(&mut e, |e| {
        call(e, "app.status", json!({}))["running"]
            .as_array()
            .unwrap()
            .is_empty()
    });
    assert_eq!(list(&mut e, id)["enabled"], false);
    assert_eq!(
        list(&mut e, id)["messages"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["state"],
        "pending"
    );
    // Persisted pending work needs an explicit resume after app restart.
    drop(e);
    let mut e = Engine::new(Store::open(&db).unwrap());
    assert_eq!(list(&mut e, id)["enabled"], false);
    call(&mut e, "agent.queue.resume", json!({"threadId":id}));
    wait(&mut e, |e| {
        list(e, id)["messages"].as_array().unwrap().last().unwrap()["state"] == "completed"
    });
    // Crash-window claim is retained as interrupted, never sent twice.
    let mut t = e.store.thread(id).unwrap();
    let m = coincide_core::message_queue::add(&mut t, "uncertain").unwrap();
    let mut q = coincide_core::message_queue::read(&t).unwrap();
    q.last_mut().unwrap().state = coincide_core::message_queue::State::Dispatching;
    coincide_core::message_queue::write(&mut t, &q).unwrap();
    e.store.save(&t).unwrap();
    drop(e);
    let mut e = Engine::new(Store::open(&db).unwrap());
    call(&mut e, "agent.queue.resume", json!({"threadId":id}));
    assert_eq!(
        list(&mut e, id)["messages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["id"] == m.id)
            .unwrap()["state"],
        "interrupted"
    );
    assert!(
        !fs::read_to_string(root.join("submitted-prompts.jsonl"))
            .unwrap()
            .contains("uncertain")
    );
    // Selection changes cannot redirect queued prompts.
    let mut t = e.store.thread(id).unwrap();
    coincide_core::message_queue::add(&mut t, "wrong-model").unwrap();
    e.store.save(&t).unwrap();
    call(
        &mut e,
        "agent.select",
        json!({"threadId":id,"provider":"claude","model":"different"}),
    );
    call(&mut e, "agent.queue.resume", json!({"threadId":id}));
    let state = list(&mut e, id);
    assert_eq!(state["enabled"], false);
    assert!(
        state["error"]
            .as_str()
            .unwrap()
            .contains("selection changed")
    );
    assert_eq!(
        state["messages"].as_array().unwrap().last().unwrap()["state"],
        "pending"
    );
}
