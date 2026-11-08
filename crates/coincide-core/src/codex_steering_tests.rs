use super::*;
#[test]
fn source_bound_request_requires_actual_matching_ack_and_stream_boundary() {
    let (client, mut server) = pair();
    assert!(client.submit("before start").is_err());
    server.activate("native-thread", "native-turn");
    server.observe(&json!({"method":"item/agentMessage/delta","params":{"threadId":"native-thread","turnId":"native-turn","itemId":"reply","delta":"streaming"}}));
    assert!(client.submit("during stream").is_err());
    server.observe(&json!({"method":"item/completed","params":{"threadId":"native-thread","turnId":"native-turn","item":{"id":"reply","type":"agentMessage"}}}));
    let ticket = client.submit("exact text").unwrap();
    assert!(ticket.receiver.try_recv().is_err());
    let request = server.next_request().unwrap();
    assert_eq!(
        request["params"],
        json!({"threadId":"native-thread","expectedTurnId":"native-turn","input":[{"type":"text","text":"exact text"}]})
    );
    assert!(!server.response(&json!({"id":"other","result":{"turnId":"native-turn"}})));
    assert!(ticket.receiver.try_recv().is_err());
    assert!(server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}})));
    assert_eq!(ticket.receiver.recv().unwrap(), Outcome::Accepted);
    let ticket = client.submit("uncertain").unwrap();
    let request = server.next_request().unwrap();
    server.response(&json!({"id":request["id"],"result":{"turnId":"different"}}));
    assert_eq!(ticket.receiver.recv().unwrap(), Outcome::Unknown);
    let ticket = client.submit("in flight").unwrap();
    server.next_request().unwrap();
    server.close();
    assert_eq!(ticket.receiver.recv().unwrap(), Outcome::Unknown);
    assert!(client.submit("after end").is_err());
}
#[cfg(unix)]
#[test]
fn actual_fake_app_server_steer_ack_targets_current_turn_without_starting_another() {
    use crate::agent::{Event, Launch, Session};
    use std::{fs, os::unix::fs::PermissionsExt};
    let dir = tempfile::tempdir().unwrap();
    let exe = dir.path().join("fixture");
    fs::write(&exe,r#"#!/usr/bin/env python3
import sys,json
def read():return json.loads(sys.stdin.readline())
def write(v):print(json.dumps(v),flush=True)
r=read();write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read();write({'id':r['id'],'result':{'thread':{'id':'native-thread'}}})
r=read();assert r['method']=='turn/start'
write({'id':r['id'],'result':{'turn':{'id':'native-turn'}}})
write({'id':900,'method':'item/commandExecution/requestApproval','params':{}})
assert read()=={'id':900,'result':{'decision':'decline'}}
r=read();assert r['method']=='turn/steer'
assert r['params']=={'threadId':'native-thread','expectedTurnId':'native-turn','input':[{'type':'text','text':'exact follow-up'}]}
write({'id':r['id'],'result':{'turnId':'native-turn'}})
write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'native-turn','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o700)).unwrap();
    let session = Session::start(Launch {
        executable: exe,
        cwd: dir.path().into(),
        session: None,
        prompt: "initial".into(),
        model: None,
        variant: None,
        full_access: false,
    });
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Frame(frame) if frame["id"] == 900 => break,
            Event::Failed(error) => panic!("{error}"),
            Event::Finished => panic!("ended before steering"),
            _ => {}
        }
    }
    let ticket = session.steer("exact follow-up").unwrap();
    session
        .reply(json!(900), json!({"decision":"decline"}))
        .unwrap();
    assert_eq!(
        ticket
            .receiver
            .recv_timeout(Duration::from_secs(5))
            .unwrap(),
        Outcome::Accepted
    );
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Finished => break,
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    assert!(session.steer("after completion").is_err());
}

#[test]
fn timeout_remains_unknown_and_late_owned_rpc_error_cannot_fail_current_turn() {
    let (client, mut server) = pair();
    server.activate("native-thread", "native-turn");
    let ticket = client.submit("uncertain text").unwrap();
    let request = server.next_request().unwrap();
    server.pending.as_mut().unwrap().started = Instant::now() - Duration::from_secs(31);
    assert!(server.next_request().is_none());
    assert_eq!(ticket.receiver.recv().unwrap(), Outcome::Unknown);
    assert!(server.response(&json!({"id":request["id"],"error":{"message":"late rejection"}})));
    assert!(server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}})));
    for _ in 0..31 {
        let ticket = client.submit("bounded").unwrap();
        let request = server.next_request().unwrap();
        server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}}));
        assert_eq!(ticket.receiver.recv().unwrap(), Outcome::Accepted);
    }
    let ticket = client.submit("over per-turn bound").unwrap();
    assert!(server.next_request().is_none());
    assert_eq!(ticket.receiver.recv().unwrap(), Outcome::Rejected);
}

#[test]
fn interleaved_tool_items_do_not_clear_open_assistant_and_client_contention_fails_busy() {
    let (client, mut server) = pair();
    server.activate("thread", "turn");
    server.observe(&json!({"method":"item/started","params":{"threadId":"thread","turnId":"turn","item":{"id":"answer","type":"agentMessage"}}}));
    for kind in ["commandExecution", "reasoning"] {
        server.observe(&json!({"method":"item/started","params":{"threadId":"thread","turnId":"turn","item":{"id":"other","type":kind}}}));
        server.observe(&json!({"method":"item/completed","params":{"threadId":"thread","turnId":"turn","item":{"id":"other","type":kind}}}));
        assert!(client.submit("must not interrupt answer").is_err());
    }
    server.observe(&json!({"method":"item/completed","params":{"threadId":"thread","turnId":"turn","item":{"id":"answer","type":"agentMessage"}}}));
    let held = client.view.lock().unwrap();
    assert!(client.submit("busy view").is_err());
    drop(held);
    assert!(client.submit("after answer boundary").is_ok());
}
