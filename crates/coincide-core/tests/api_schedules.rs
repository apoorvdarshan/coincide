//! Headless engine/runner integration. Executable overrides are confined to an
//! isolated child test process, so parallel tests cannot launch this fixture.
#![cfg(unix)]
use chrono::{Duration as ChronoDuration, Utc};
use coincide_core::{api::Engine, store::Store};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::Path,
    process::Command,
    time::{Duration, Instant},
};

#[test]
fn schedule_engine_approval_execution_busy_cancel_and_restart() {
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
if prompt=='hold-restart': assert 'hold-cancel' in raw_prompt, 'cancelled history was silently omitted'
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
        .args([
            "--ignored",
            "--exact",
            "schedule_engine_fixture_child",
            "--nocapture",
        ])
        .env("COINCIDE_CLAUDE_EXECUTABLE", &executable)
        .env("SCHEDULE_ENGINE_FIXTURE_DIRECTORY", directory.path())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "schedule fixture failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn call(engine: &mut Engine, method: &str, params: Value) -> Value {
    let response = engine.dispatch(json!({"id":1,"method":method,"params":params}));
    assert!(response.get("error").is_none(), "{method}: {response}");
    response["result"].clone()
}
fn reject(engine: &mut Engine, method: &str, params: Value) {
    let response = engine.dispatch(json!({"id":1,"method":method,"params":params}));
    assert!(
        response.get("error").is_some(),
        "{method} unexpectedly accepted: {response}"
    );
}
fn scheduled(engine: &mut Engine, id: &str) -> Value {
    call(engine, "schedules.list", json!({}))["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|task| task["id"] == id)
        .unwrap()
        .clone()
}
fn create(engine: &mut Engine, thread: &Value, prompt: &str) -> String {
    let result = call(
        engine,
        "schedules.create",
        json!({"task":{
        "name":prompt,"prompt":prompt,"projectID":thread["projectID"],"threadID":thread["id"],
        "recurrence":{"kind":"interval","timeZoneID":"UTC","date":Utc::now()+ChronoDuration::hours(1),
            "hour":0,"minute":0,"weekday":1,"intervalMinutes":5}}}),
    );
    result["task"]["id"].as_str().unwrap().to_owned()
}
fn prompts(directory: &Path) -> Vec<String> {
    fs::read_to_string(directory.join("submitted-prompts.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}
fn wait_for(
    engine: &mut Engine,
    description: &str,
    mut condition: impl FnMut(&mut Engine) -> bool,
) {
    let deadline = Instant::now() + Duration::from_secs(12);
    while !condition(engine) {
        assert!(Instant::now() < deadline, "Timed out: {description}");
        std::thread::sleep(Duration::from_millis(15));
    }
}
fn wait_submission(engine: &mut Engine, directory: &Path, expected: &str) {
    wait_for(engine, "provider submission", |engine| {
        call(engine, "app.status", json!({}));
        prompts(directory).iter().any(|prompt| prompt == expected)
    });
}
fn wait_outcome(engine: &mut Engine, id: &str, outcome: &str) -> Value {
    wait_for(engine, outcome, |engine| {
        scheduled(engine, id)["lastOutcome"] == outcome
    });
    let task = scheduled(engine, id);
    assert!(
        task["rustClaim"].is_null(),
        "completed claim was not released"
    );
    assert!(task["activeThreadID"].is_null());
    task
}

#[test]
#[ignore = "invoked by isolated parent fixture test"]
fn schedule_engine_fixture_child() {
    let Some(directory) = std::env::var_os("SCHEDULE_ENGINE_FIXTURE_DIRECTORY") else {
        return;
    };
    let directory = std::path::PathBuf::from(directory);
    let database = directory.join("data/fixture.sqlite");
    let mut engine = Engine::new(Store::open(&database).unwrap());
    let project = call(
        &mut engine,
        "projects.create",
        json!({"path":directory,"name":"Synthetic schedule fixture"}),
    );
    let thread = call(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"],"cwd":directory}),
    );
    let thread_id = thread["id"].as_str().unwrap().to_owned();
    call(
        &mut engine,
        "agent.select",
        json!({"threadId":thread_id,"provider":"claude"}),
    );
    assert_eq!(
        call(&mut engine, "schedules.list", json!({}))["executionAvailable"],
        true
    );

    // Agent-facing methods cannot grant approval or forge approval metadata.
    let first = create(&mut engine, &thread, "scheduled-one");
    assert_ne!(scheduled(&mut engine, &first)["approvalState"], "approved");
    reject(
        &mut engine,
        "schedules.run-now",
        json!({"scheduleId":first}),
    );
    reject(
        &mut engine,
        "schedules.approve",
        json!({"scheduleId":first}),
    );
    reject(
        &mut engine,
        "schedules.patch",
        json!({"scheduleId":first,"patch":{"rustApprovedRevision":"forged"}}),
    );
    assert!(prompts(&directory).is_empty());
    engine.approve_schedule(&first).unwrap();
    assert_eq!(scheduled(&mut engine, &first)["approvalState"], "approved");
    call(
        &mut engine,
        "schedules.run-now",
        json!({"scheduleId":first}),
    );
    wait_outcome(&mut engine, &first, "completed");
    assert_eq!(prompts(&directory), ["scheduled-one"]);
    for _ in 0..5 {
        call(&mut engine, "app.status", json!({}));
    }
    assert_eq!(
        prompts(&directory),
        ["scheduled-one"],
        "poll replayed completed claim"
    );

    // An ordinary active turn defers one schedule; releasing it starts exactly
    // one scheduled turn without interrupting the user's current conversation.
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":thread_id,"text":"hold-busy"}),
    );
    wait_submission(&mut engine, &directory, "hold-busy");
    let deferred = create(&mut engine, &thread, "after-busy");
    engine.approve_schedule(&deferred).unwrap();
    call(
        &mut engine,
        "schedules.run-now",
        json!({"scheduleId":deferred}),
    );
    let task = scheduled(&mut engine, &deferred);
    assert!(!task["pendingDelivery"].is_null());
    assert!(task["rustClaim"].is_null());
    assert_eq!(prompts(&directory), ["scheduled-one", "hold-busy"]);
    fs::write(directory.join("release-hold-busy"), b"release").unwrap();
    wait_outcome(&mut engine, &deferred, "completed");
    assert_eq!(
        prompts(&directory),
        ["scheduled-one", "hold-busy", "after-busy"]
    );

    // Cancelling an active scheduled turn records interruption, never success.
    let cancelled = create(&mut engine, &thread, "hold-cancel");
    engine.approve_schedule(&cancelled).unwrap();
    call(
        &mut engine,
        "schedules.run-now",
        json!({"scheduleId":cancelled}),
    );
    wait_submission(&mut engine, &directory, "hold-cancel");
    reject(
        &mut engine,
        "schedules.run-now",
        json!({"scheduleId":cancelled}),
    );
    call(&mut engine, "agent.stop", json!({"threadId":thread_id}));
    wait_outcome(&mut engine, &cancelled, "interrupted");

    // Dropping the engine simulates shutdown with a persisted active claim.
    // Recovery must mark it interrupted and must not replay it on startup.
    let restarted = create(&mut engine, &thread, "hold-restart");
    engine.approve_schedule(&restarted).unwrap();
    call(
        &mut engine,
        "schedules.run-now",
        json!({"scheduleId":restarted}),
    );
    wait_submission(&mut engine, &directory, "hold-restart");
    assert!(!scheduled(&mut engine, &restarted)["rustClaim"].is_null());
    drop(engine);
    let mut recovered = Engine::new(Store::open(&database).unwrap());
    let task = scheduled(&mut recovered, &restarted);
    assert_eq!(task["lastOutcome"], "interrupted");
    assert!(task["rustClaim"].is_null());
    assert!(task["activeThreadID"].is_null());
    assert!(
        call(&mut recovered, "app.status", json!({}))["running"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        prompts(&directory),
        [
            "scheduled-one",
            "hold-busy",
            "after-busy",
            "hold-cancel",
            "hold-restart"
        ]
    );
}
