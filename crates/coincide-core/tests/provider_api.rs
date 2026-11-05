//! API/provider integration runs in a child test process so fixture executable
//! overrides never mutate the environment of concurrently running tests.
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
fn claude_api_roundtrips_approvals_questions_tools_and_multiple_turns() {
    let dir = tempfile::tempdir().unwrap();
    let executable = dir.path().join("fixture-claude");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,sys,os
def read(): return json.loads(sys.stdin.readline())
def write(value): print(json.dumps(value),flush=True)
run=int(open('run-count').read())+1 if os.path.exists('run-count') else 1
open('run-count','w').write(str(run))
if run==1:
 assert '--resume' not in sys.argv
 session=sys.argv[sys.argv.index('--session-id')+1]
 open('native-session','w').write(session)
else:
 assert '--resume' in sys.argv
 session=sys.argv[sys.argv.index('--resume')+1]
 assert session==open('native-session').read()
r=read();write({'type':'control_response','response':{'subtype':'success','request_id':r['request_id']}})
prompt=read();assert prompt['type']=='user'
write({'type':'system','subtype':'init','session_id':session})
if run==1:
 write({'type':'control_request','request_id':'approval-1','request':{'subtype':'can_use_tool','tool_name':'Bash','tool_use_id':'tool-1','input':{'command':'fixture only','future':42}}})
 r=read()['response'];assert r['request_id']=='approval-1' and r['response']['behavior']=='allow'
 write({'type':'control_request','request_id':'cancelled-question','request':{'subtype':'can_use_tool','tool_name':'AskUserQuestion','input':{'questions':[{'question':'Old question?'}]}}})
 write({'type':'control_cancel_request','request_id':'cancelled-question'})
 write({'type':'control_request','request_id':'question-1','request':{'subtype':'can_use_tool','tool_name':'AskUserQuestion','input':{'questions':[{'question':'Which?','options':[{'label':'A'}]}]}}})
 r=read()['response'];assert r['request_id']=='question-1' and r['response']['updatedInput']['answers']=={'Which?':'A'}
 write({'type':'stream_event','event':{'type':'message_start','message':{'id':'message-1'}}})
 write({'type':'stream_event','event':{'type':'content_block_start','index':0,'content_block':{'type':'text','text':'First'}}})
 write({'type':'assistant','message':{'id':'message-1','content':[{'type':'text','text':'First answer'},{'type':'tool_use','id':'tool-1','name':'Bash','input':{'command':'fixture only','future':42}}]}})
 write({'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'tool-1','content':'fixture output','is_error':False}]}})
 result='must not duplicate First answer'
else:
 assert prompt['message']['content']=='prompt '+str(run)
 result='Second answer' if run==2 else 'Third answer'
write({'type':'result','subtype':'success','is_error':False,'session_id':session,'result':result})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "provider_api_fixture_child",
            "--nocapture",
        ])
        .env("COINCIDE_CLAUDE_EXECUTABLE", &executable)
        .env("PROVIDER_API_FIXTURE_DIRECTORY", dir.path())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "child integration failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn call(engine: &mut Engine, method: &str, params: Value) -> Value {
    let response = engine.dispatch(json!({"id":1,"method":method,"params":params}));
    assert!(response.get("error").is_none(), "{method}: {response}");
    response["result"].clone()
}

#[test]
#[ignore = "invoked by isolated parent fixture test"]
fn provider_api_fixture_child() {
    let Some(directory) = std::env::var_os("PROVIDER_API_FIXTURE_DIRECTORY") else {
        return;
    };
    let directory = std::path::PathBuf::from(directory);
    let mut engine = Engine::new(Store::open(&directory.join("fixture.sqlite")).unwrap());
    let thread = call(&mut engine, "threads.create", json!({"cwd":directory}));
    let id = thread["id"].as_str().unwrap().to_owned();
    call(
        &mut engine,
        "agent.select",
        json!({"threadId":id,"provider":"claude"}),
    );
    let mut thread = engine.store.thread(&id).unwrap();
    thread["future"] = json!({"preserved":42});
    engine.store.save(&thread).unwrap();
    let mut approval_count = 0;
    let mut question_count = 0;
    let mut native_session = None;
    for turn in 1..=3 {
        call(
            &mut engine,
            "agent.send",
            json!({"threadId":id,"text":format!("prompt {turn}")}),
        );
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let pending = call(&mut engine, "agent.pending", json!({"threadId":id}));
            for request in pending.as_array().unwrap() {
                let request_id = request["requestId"].as_str().unwrap();
                if request_id == "\"cancelled-question\"" {
                    // A cancellation already queued immediately after its request must
                    // settle on the next poll, even if this poll raced the writer.
                    continue;
                }
                if request["method"] == "item/commandExecution/requestApproval" {
                    let invalid = engine.dispatch(json!({"method":"agent.respond","params":{"threadId":id,"requestId":request_id,"decision":"acceptForSession"}}));
                    assert!(invalid.get("error").is_some());
                    call(
                        &mut engine,
                        "agent.respond",
                        json!({"threadId":id,"requestId":request_id,"decision":"accept"}),
                    );
                    approval_count += 1;
                } else if request["method"] == "item/tool/requestUserInput" {
                    let invalid = engine.dispatch(json!({"method":"agent.answer","params":{"threadId":id,"requestId":request_id,"answers":{}}}));
                    assert!(invalid.get("error").is_some());
                    call(
                        &mut engine,
                        "agent.answer",
                        json!({"threadId":id,"requestId":request_id,"answers":{"Which?":{"answers":["A"]}}}),
                    );
                    question_count += 1;
                    let pending = call(&mut engine, "agent.pending", json!({"threadId":id}));
                    assert!(
                        !pending
                            .as_array()
                            .unwrap()
                            .iter()
                            .any(|p| p["requestId"] == "\"cancelled-question\""),
                        "cancelled request remains actionable"
                    );
                }
            }
            let status = call(&mut engine, "app.status", json!({}));
            if status["running"].as_array().unwrap().is_empty() {
                break;
            }
            assert!(Instant::now() < deadline, "API fixture timed out");
            std::thread::sleep(Duration::from_millis(15));
        }
        let thread = call(&mut engine, "threads.read", json!({"threadId":id}));
        let session = thread["sessions"]["claude"]["sessionID"]
            .as_str()
            .unwrap()
            .to_owned();
        if let Some(previous) = &native_session {
            assert_eq!(&session, previous);
        }
        native_session = Some(session);
        assert_eq!(thread["future"]["preserved"], 42);
        assert!(
            !thread["items"]
                .as_array()
                .unwrap()
                .iter()
                .any(|item| item["kind"] == "error"),
            "unexpected error: {thread}"
        );
    }
    assert_eq!((approval_count, question_count), (1, 1));
    let thread = engine.store.thread(&id).unwrap();
    let items = thread["items"].as_array().unwrap();
    let replies = items
        .iter()
        .filter(|item| item["kind"] == "assistant")
        .map(|item| item["text"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(replies, ["First answer", "Second answer", "Third answer"]);
    let tools = items
        .iter()
        .filter(|item| item["kind"] == "tool")
        .collect::<Vec<_>>();
    assert_eq!(tools.len(), 1, "tool updates must upsert the existing item");
    let tool: Value = serde_json::from_str(tools[0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(tool["name"], "Bash");
    assert_eq!(tool["input"]["future"], 42);
    assert_eq!(tool["output"], "fixture output");
}
