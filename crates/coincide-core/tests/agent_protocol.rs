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
write({'method':'turn/completed','params':{'threadId':'existing-native-session','turn':{'id':'turn-fixture','status':'completed'}}})
sys.stdin.readline()
"##).unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o700)).unwrap();
    let session = Session::start(Launch {
        executable: exe,
        cwd: dir.path().into(),
        session: Some("existing-native-session".into()),
        prompt: "fixture prompt".into(),
        model: None,
        variant: None,
        full_access: false,
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
            Event::Usage => {}
            Event::Goal { .. } | Event::TurnBoundary => {
                panic!("unexpected goal event from ordinary turn")
            }
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

fn active_turn_fixture(body: &str) -> (tempfile::TempDir, Session) {
    let dir = tempfile::tempdir().unwrap();
    let exe = dir.path().join("fixture");
    let source = format!(
        "#!/usr/bin/env python3\nimport json,sys\ndef read(): return json.loads(sys.stdin.readline())\ndef write(v): print(json.dumps(v),flush=True)\nr=read();write({{'id':r['id'],'result':{{}}}})\nassert read()['method']=='initialized'\nr=read();write({{'id':r['id'],'result':{{'thread':{{'id':'native-thread'}}}}}})\nr=read();assert r['method']=='turn/start'\n{body}\n"
    );
    fs::write(&exe, source).unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o700)).unwrap();
    let session = Session::start(Launch {
        executable: exe,
        cwd: dir.path().into(),
        session: None,
        prompt: "synthetic".into(),
        model: None,
        variant: None,
        full_access: false,
    });
    (dir, session)
}

#[test]
fn stale_or_missing_completion_identity_cannot_retire_current_codex_turn() {
    let (_dir, session) = active_turn_fixture(
        r#"
write({'id':r['id'],'result':{'turn':{'id':'active-turn'}}})
for params in [
 {'threadId':'other-thread','turn':{'id':'active-turn','status':'completed'}},
 {'threadId':'native-thread','turn':{'id':'old-turn','status':'failed','error':'stale'}},
 {'turn':{'status':'completed'}}]:
 write({'method':'turn/completed','params':params})
# An explicit request/reply barrier proves the worker consumed stale frames and
# remains in the active loop; no timed sleep or absence-of-output proof.
write({'id':100,'method':'item/commandExecution/requestApproval','params':{}})
assert read()=={'id':100,'result':{'decision':'decline'}}
write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'active-turn','status':'completed'}}})
sys.stdin.readline()
"#,
    );
    let mut barrier = false;
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Session(id) => assert_eq!(id, "native-thread"),
            Event::Frame(frame) if frame["id"] == 100 => {
                barrier = true;
                session
                    .reply(json!(100), json!({"decision":"decline"}))
                    .unwrap();
            }
            Event::Frame(_) => {}
            Event::Finished => {
                assert!(barrier);
                break;
            }
            Event::Failed(error) => panic!("{error}"),
            Event::Usage => {}
            Event::Goal { .. } | Event::TurnBoundary => {
                panic!("unexpected goal event from ordinary turn")
            }
        }
    }
}

#[test]
fn missing_or_duplicate_turn_start_identity_fails_closed() {
    for body in [
        "write({'id':r['id'],'result':{}})\nsys.stdin.readline()",
        "write({'id':r['id'],'result':{'turn':{'id':''}}})\nsys.stdin.readline()",
        "write({'id':r['id'],'result':{'turn':{'id':'active'}}})\nwrite({'id':r['id'],'result':{'turn':{'id':'different'}}})\nsys.stdin.readline()",
    ] {
        let (_dir, session) = active_turn_fixture(body);
        loop {
            match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
                Event::Failed(error) => {
                    assert!(error.contains("identity") || error.contains("duplicate"));
                    break;
                }
                Event::Finished => panic!("invalid start cannot finish successfully"),
                _ => {}
            }
        }
    }
}

#[test]
fn owned_notifications_before_start_ack_are_replayed_after_matching_identity_validation() {
    for started in [
        "",
        "write({'method':'turn/started','params':{'threadId':'native-thread','turn':{'id':'active-turn'}}})",
    ] {
        let body = format!(
            "{started}\nwrite({{'method':'thread/tokenUsage/updated','params':{{'threadId':'native-thread','turnId':'active-turn','tokenUsage':{{'last':{{'totalTokens':15}}}}}}}})\nwrite({{'method':'turn/completed','params':{{'threadId':'native-thread','turn':{{'id':'active-turn','status':'completed'}}}}}})\nwrite({{'id':r['id'],'result':{{'turn':{{'id':'active-turn'}}}}}})\nsys.stdin.readline()"
        );
        let (_dir, session) = active_turn_fixture(&body);
        loop {
            match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
                Event::Finished => break,
                Event::Failed(error) => panic!("valid early notification ordering failed: {error}"),
                _ => {}
            }
        }
    }
}

#[test]
fn mismatching_provisional_identity_or_early_completion_overflow_fails_closed() {
    for body in [
        "write({'method':'turn/started','params':{'threadId':'native-thread','turn':{'id':'provisional'}}})\nwrite({'id':r['id'],'result':{'turn':{'id':'different'}}})\nsys.stdin.readline()",
        "for i in range(9):\n write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'early','status':'completed'}}})\nsys.stdin.readline()",
    ] {
        let (_dir, session) = active_turn_fixture(body);
        loop {
            match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
                Event::Failed(error) => {
                    assert!(error.contains("identity") || error.contains("limit"));
                    break;
                }
                Event::Finished => panic!("unvalidated completion cannot finish successfully"),
                _ => {}
            }
        }
    }
}
