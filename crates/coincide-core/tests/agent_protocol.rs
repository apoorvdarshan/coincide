#![cfg(unix)]
use coincide_core::agent::{Event, Launch, Session};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    time::{Duration, Instant},
};
#[test]
fn actual_process_handshake_resume_stream_approval_and_completion() {
    let dir = tempfile::tempdir().unwrap();
    let exe = dir.path().join("fixture");
    fs::write(&exe,r##"#!/usr/bin/env python3
import json,sys
log=open('requests.jsonl','w')
def read():
    value=json.loads(sys.stdin.readline()); log.write(json.dumps(value)+'\n');log.flush();return value
def write(value):
    print(json.dumps(value),flush=True)
r=read(); assert r['method']=='initialize'
write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read(); assert r['method']=='thread/resume' and r['params']['threadId']=='existing-native-session'
write({'id':r['id'],'result':{'thread':{'id':'existing-native-session'}}})
r=read(); assert r['method']=='turn/start';assert r['params']['approvalPolicy']=='untrusted'
write({'id':r['id'],'result':{'turn':{'id':'turn-fixture'}}})
write({'id':100,'method':'item/commandExecution/requestApproval','params':{'command':'fixture-only','availableDecisions':['accept','decline']}})
r=read();assert r=={'id':100,'result':{'decision':'accept'}}
write({'method':'item/agentMessage/delta','params':{'itemId':'message-fixture','delta':'fixture result'}})
write({'method':'turn/completed','params':{'turn':{'status':'completed'}}})
sys.stdin.readline()
"##).unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o700)).unwrap();
    let session = Session::start(Launch {
        executable: exe,
        cwd: dir.path().into(),
        session: Some("existing-native-session".into()),
        prompt: "fixture prompt".into(),
        model: None,
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut output = String::new();
    let mut approval = false;
    let mut native = false;
    loop {
        assert!(Instant::now() < deadline, "fixture timed out");
        match session.events.recv_timeout(Duration::from_secs(3)).unwrap() {
            Event::Session(id) => {
                assert_eq!(id, "existing-native-session");
                native = true;
            }
            Event::Frame(frame) if frame.get("id").is_some() => {
                assert_eq!(frame["id"], 100);
                approval = true;
                session
                    .reply(json!(100), json!({"decision":"accept"}))
                    .unwrap();
            }
            Event::Frame(frame) => {
                if let Some(delta) = frame["params"]["delta"].as_str() {
                    output.push_str(delta);
                }
            }
            Event::Finished => break,
            Event::Failed(message) => panic!("{message}"),
        }
    }
    assert!(native && approval);
    assert_eq!(output, "fixture result");
    let log = fs::read_to_string(dir.path().join("requests.jsonl")).unwrap();
    let requests = log
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(requests.len(), 5);
    assert_eq!(requests[3]["params"]["input"][0]["text"], "fixture prompt");
}
