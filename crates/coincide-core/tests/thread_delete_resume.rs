//! Real adapter subprocess regression using only an isolated synthetic Claude.
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
fn delete_undo_starts_fresh_then_resumes_only_the_new_native_session() {
    let dir = tempfile::tempdir().unwrap();
    let executable = dir.path().join("fake-claude");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,sys,pathlib
root=pathlib.Path.cwd()
counter=root/'turn-count'
turn=int(counter.read_text())+1 if counter.exists() else 1
counter.write_text(str(turn))
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
if turn in (1,2):
 assert '--resume' not in sys.argv
 native=sys.argv[sys.argv.index('--session-id')+1]
 if turn==2: assert native!=(root/'old-native').read_text()
 (root/('old-native' if turn==1 else 'new-native')).write_text(native)
else:
 assert turn==3 and '--resume' in sys.argv
 native=sys.argv[sys.argv.index('--resume')+1]
 assert native==(root/'new-native').read_text()
init=read();write({'type':'control_response','response':{'subtype':'success','request_id':init['request_id']}})
prompt=read()['message']['content']
if turn==2:
 assert 'Earlier conversation context' in prompt
 assert prompt.count('user: synthetic-one')==1
 assert prompt.count('assistant: synthetic-answer-one')==1
 assert prompt.endswith('synthetic-two')
else: assert prompt==('synthetic-one' if turn==1 else 'synthetic-three')
write({'type':'system','subtype':'init','session_id':native})
answer={1:'synthetic-answer-one',2:'synthetic-answer-two',3:'synthetic-answer-three'}[turn]
write({'type':'result','subtype':'success','is_error':False,'session_id':native,'result':answer})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "delete_undo_fixture_child",
            "--nocapture",
        ])
        .env("COINCIDE_CLAUDE_EXECUTABLE", &executable)
        .env("COINCIDE_DELETE_UNDO_FIXTURE", dir.path())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "synthetic child failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn call(engine: &mut Engine, method: &str, params: Value) -> Value {
    let response = engine.dispatch(json!({"id":1,"method":method,"params":params}));
    assert!(response.get("error").is_none(), "{method}: {response}");
    response["result"].clone()
}
fn turn(engine: &mut Engine, id: &str, prompt: &str, expected: &str) -> String {
    call(engine, "agent.send", json!({"threadId":id,"text":prompt}));
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let status = call(engine, "app.status", json!({}));
        if status["running"].as_array().unwrap().is_empty()
            && engine.provider_workers_status().running == 0
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "synthetic provider did not finish cleanup"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    let thread = engine.store.thread(id).unwrap();
    let items = thread["items"].as_array().unwrap();
    assert!(
        !items.iter().any(|item| item["kind"] == "error"),
        "{thread}"
    );
    assert!(
        items
            .iter()
            .any(|item| item["kind"] == "assistant" && item["text"] == expected),
        "{thread}"
    );
    thread["sessions"]["claude"]["sessionID"]
        .as_str()
        .unwrap()
        .to_owned()
}
#[test]
#[ignore = "invoked by isolated parent fixture"]
fn delete_undo_fixture_child() {
    let Some(root) = std::env::var_os("COINCIDE_DELETE_UNDO_FIXTURE") else {
        return;
    };
    let root = std::path::PathBuf::from(root);
    let mut engine = Engine::new(Store::open(&root.join("data/state.sqlite")).unwrap());
    let thread = call(&mut engine, "threads.create", json!({"cwd":root}));
    let id = thread["id"].as_str().unwrap().to_owned();
    call(
        &mut engine,
        "agent.select",
        json!({"threadId":id,"provider":"claude"}),
    );
    let old = turn(&mut engine, &id, "synthetic-one", "synthetic-answer-one");
    call(
        &mut engine,
        "threads.patch",
        json!({"threadId":id,"patch":{"isArchived":true}}),
    );
    let exact = engine.store.thread(&id).unwrap();
    let plan = engine
        .prepare_native_thread_deletion(std::slice::from_ref(&id))
        .unwrap();
    let undo = engine.apply_native_thread_deletion(plan).unwrap();
    engine.undo_native_thread_deletion(&undo).unwrap();
    assert_eq!(engine.store.thread(&id).unwrap(), exact);
    call(
        &mut engine,
        "threads.patch",
        json!({"threadId":id,"patch":{"isArchived":false}}),
    );
    let new = turn(&mut engine, &id, "synthetic-two", "synthetic-answer-two");
    assert_ne!(old, new);
    assert_eq!(
        new,
        turn(
            &mut engine,
            &id,
            "synthetic-three",
            "synthetic-answer-three"
        )
    );
    assert_eq!(engine.provider_workers_status().returned, 3);
    engine.store.close_for_shutdown().unwrap();
}
