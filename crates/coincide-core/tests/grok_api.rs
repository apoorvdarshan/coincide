//! Named Grok routing uses a synthetic executable in an isolated test process.
#![cfg(unix)]
use coincide_core::{agent, api::Engine, store::Store};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    process::Command,
    time::{Duration, Instant},
};

#[test]
fn grok_selection_sends_and_resumes_without_replaying_seen_history() {
    let dir = tempfile::tempdir().unwrap();
    let executable = dir.path().join("grok-fixture");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,sys
read=lambda:json.loads(sys.stdin.readline())
def reply(r,result): print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result}),flush=True)
assert sys.argv[1:]==['--permission-mode','default','agent','stdio']
r=read();assert r['method']=='initialize'
assert r['params']['_meta']['clientType']=='extension'
reply(r,{'protocolVersion':1,'agentCapabilities':{'loadSession':True}})
r=read();assert r['method'] in ['session/new','session/load']
if r['method']=='session/load': assert r['params']['sessionId']=='grok-fixture-session'
reply(r,{'sessionId':'grok-fixture-session'})
r=read();assert r['method']=='session/prompt'
prompt=r['params']['prompt'];assert len(prompt)==1 and prompt[0]['type']=='text'
text=prompt[0]['text'];assert text in ['first turn','second turn','after restart']
with open('grok-prompts.jsonl','a') as f: f.write(json.dumps(text)+'\n')
print(json.dumps({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'grok-fixture-session','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'Completed '+text}}}}),flush=True)
reply(r,{'stopReason':'end_turn'})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "grok_api_fixture_child",
            "--nocapture",
        ])
        .env("COINCIDE_GROK_EXECUTABLE", &executable)
        .env("GROK_API_FIXTURE_DIRECTORY", dir.path())
        .env_remove("XAI_API_KEY")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let prompts = fs::read_to_string(dir.path().join("grok-prompts.jsonl")).unwrap();
    assert_eq!(
        prompts
            .lines()
            .map(|line| serde_json::from_str::<String>(line).unwrap())
            .collect::<Vec<_>>(),
        ["first turn", "second turn", "after restart"]
    );
}

fn call(engine: &mut Engine, method: &str, params: Value) -> Value {
    let result = engine.dispatch(json!({"method":method,"params":params}));
    assert!(result.get("error").is_none(), "{method}: {result}");
    result["result"].clone()
}
fn turn(engine: &mut Engine, id: &str, prompt: &str) {
    call(engine, "agent.send", json!({"threadId":id,"text":prompt}));
    let deadline = Instant::now() + Duration::from_secs(10);
    while !call(engine, "app.status", json!({}))["running"]
        .as_array()
        .unwrap()
        .is_empty()
    {
        assert!(Instant::now() < deadline, "Grok fixture did not complete");
        std::thread::sleep(Duration::from_millis(10));
    }
    let thread = engine.store.thread(id).unwrap();
    assert!(
        thread["items"].as_array().unwrap().iter().any(
            |item| item["kind"] == "assistant" && item["text"] == format!("Completed {prompt}")
        ),
        "{thread}"
    );
    assert_eq!(
        agent::provider_session(&thread, "grok").as_deref(),
        Some("grok-fixture-session")
    );
    assert_eq!(
        agent::provider_seen_count(&thread, "grok"),
        thread["items"].as_array().unwrap().len()
    );
}
#[test]
#[ignore = "invoked by isolated parent fixture test"]
fn grok_api_fixture_child() {
    let Some(directory) = std::env::var_os("GROK_API_FIXTURE_DIRECTORY") else {
        return;
    };
    let root = std::path::PathBuf::from(directory);
    let db = root.join("data/fixture.sqlite");
    let mut engine = Engine::new(Store::open(&db).unwrap());
    let thread = call(&mut engine, "threads.create", json!({"cwd":root}));
    let id = thread["id"].as_str().unwrap().to_owned();
    call(
        &mut engine,
        "agent.select",
        json!({"threadId":id,"provider":"grok","model":"grok-build"}),
    );
    turn(&mut engine, &id, "first turn");
    turn(&mut engine, &id, "second turn");
    drop(engine);
    let mut engine = Engine::new(Store::open(&db).unwrap());
    assert_eq!(
        engine.store.thread(&id).unwrap()["selection"]["provider"],
        "grok"
    );
    turn(&mut engine, &id, "after restart");
}
