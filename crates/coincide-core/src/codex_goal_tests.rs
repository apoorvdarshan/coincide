use super::*;
use std::{fs, os::unix::fs::PermissionsExt};

#[test]
fn native_goal_continues_across_turns_and_accepts_a_follow_up() {
    let directory = tempfile::tempdir().unwrap();
    let executable = directory.path().join("codex-fixture");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,sys
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
def goal(status): return {'threadId':'native-thread','objective':'finish the task','status':status}
def notice(status): write({'method':'thread/goal/updated','params':{'threadId':'native-thread','goal':goal(status)}})
def usage(turn,n): write({'method':'thread/tokenUsage/updated','params':{'threadId':'native-thread','turnId':turn,'tokenUsage':{'last':{'totalTokens':n}}}})
def done(turn): write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':turn,'status':'completed'}}})
r=read(); assert r['method']=='initialize'; write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read(); assert r['method']=='thread/start'; write({'id':r['id'],'result':{'thread':{'id':'native-thread'}}})
r=read(); assert r['method']=='turn/start'; write({'id':r['id'],'result':{'turn':{'id':'first'}}})
r=read(); assert r['method']=='thread/goal/set' and r['params']=={'threadId':'native-thread','objective':'finish the task','status':'active','origin':'user'}
write({'id':r['id'],'result':{'goal':goal('active')}}); notice('active')
usage('first',10); done('first')
write({'method':'turn/started','params':{'threadId':'native-thread','turn':{'id':'second'}}})
write({'id':900,'method':'item/commandExecution/requestApproval','params':{}})
r=read(); assert r['method']=='turn/steer' and r['params']['expectedTurnId']=='second'
assert r['params']['input']==[{'type':'text','text':'new direction'}]
write({'id':r['id'],'result':{'turnId':'second'}})
notice('complete'); usage('second',20); done('second')
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let session = Session::start_with_mode_policy_and_profile(
        Provider::Codex,
        Launch {
            executable,
            cwd: directory.path().into(),
            session: None,
            prompt: "finish the task".into(),
            model: None,
            variant: None,
            full_access: false,
        },
        Vec::new(),
        None,
        None,
        LaunchOptions {
            codex_goal: Some(codex_goals::Command::Set("finish the task".into())),
            ..Default::default()
        },
    );
    let mut boundary = false;
    let mut receipts = 0;
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::TurnBoundary => boundary = true,
            Event::Usage => {
                receipts += 1;
                assert!(session.take_usage().is_some());
            }
            Event::Frame(frame) if frame["id"] == 900 => break,
            Event::Finished => panic!("goal stopped before its continuation"),
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    assert!(boundary);
    let ticket = session.steer("new direction").unwrap();
    assert_eq!(
        ticket
            .receiver
            .recv_timeout(Duration::from_secs(5))
            .unwrap(),
        codex_steering::Outcome::Accepted
    );
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Usage => {
                receipts += 1;
                assert!(session.take_usage().is_some());
            }
            Event::Finished => break,
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    assert_eq!(receipts, 2);
}

#[test]
fn live_goal_control_leaves_unrelated_approval_pending() {
    let directory = tempfile::tempdir().unwrap();
    let executable = directory.path().join("codex-fixture");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,sys
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
def goal(status): return {'threadId':'native-thread','objective':'test','status':status}
r=read(); write({'id':r['id'],'result':{}}); assert read()['method']=='initialized'
r=read(); write({'id':r['id'],'result':{'thread':{'id':'native-thread'}}})
r=read(); assert r['method']=='turn/start'; write({'id':r['id'],'result':{'turn':{'id':'first'}}})
r=read(); assert r['method']=='thread/goal/set'; write({'id':r['id'],'result':{'goal':goal('active')}})
write({'id':900,'method':'item/commandExecution/requestApproval','params':{}})
r=read(); assert r['method']=='thread/goal/set' and r['params']=={'threadId':'native-thread','status':'paused','origin':'user'}
write({'id':r['id'],'result':{'goal':goal('paused')}})
r=read(); assert r=={'id':900,'result':{'decision':'decline'}}
write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'first','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let session = Session::start_with_mode_policy_and_profile(
        Provider::Codex,
        Launch {
            executable,
            cwd: directory.path().into(),
            session: None,
            prompt: "test".into(),
            model: None,
            variant: None,
            full_access: false,
        },
        Vec::new(),
        None,
        None,
        LaunchOptions {
            codex_goal: Some(codex_goals::Command::Set("test".into())),
            ..Default::default()
        },
    );
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Frame(frame) if frame["id"] == 900 => break,
            Event::Finished => panic!("ended before the approval"),
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    let reply = session.begin_steer_text("/goal pause").unwrap();
    assert!(reply.recv_timeout(Duration::from_secs(5)).unwrap().is_ok());
    session
        .reply(json!(900), json!({"decision":"decline"}))
        .unwrap();
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Finished => break,
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
}

#[test]
fn user_stop_pauses_and_interrupts_the_native_goal_before_finishing() {
    let directory = tempfile::tempdir().unwrap();
    let executable = directory.path().join("codex-fixture");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,sys
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
def goal(status): return {'threadId':'native-thread','objective':'test','status':status}
r=read(); write({'id':r['id'],'result':{}}); assert read()['method']=='initialized'
r=read(); write({'id':r['id'],'result':{'thread':{'id':'native-thread'}}})
r=read(); assert r['method']=='turn/start'; write({'id':r['id'],'result':{'turn':{'id':'first'}}})
r=read(); assert r['method']=='thread/goal/set'; write({'id':r['id'],'result':{'goal':goal('active')}})
write({'id':900,'method':'item/commandExecution/requestApproval','params':{}})
pause=read(); assert pause['method']=='thread/goal/set' and pause['params']['status']=='paused'
interrupt=read(); assert interrupt['method']=='turn/interrupt' and interrupt['params']=={'threadId':'native-thread','turnId':'first'}
write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'first','status':'interrupted'}}})
write({'id':interrupt['id'],'result':{}})
write({'id':pause['id'],'result':{'goal':goal('paused')}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let session = Session::start_with_mode_policy_and_profile(
        Provider::Codex,
        Launch {
            executable,
            cwd: directory.path().into(),
            session: None,
            prompt: "test".into(),
            model: None,
            variant: None,
            full_access: false,
        },
        Vec::new(),
        None,
        None,
        LaunchOptions {
            codex_goal: Some(codex_goals::Command::Set("test".into())),
            ..Default::default()
        },
    );
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Frame(frame) if frame["id"] == 900 => break,
            Event::Finished => panic!("ended before user stop"),
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    session.stop_for_user();
    let mut paused = false;
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Goal {
                goal: Some(goal), ..
            } if goal["status"] == "paused" => paused = true,
            Event::Finished => break,
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    assert!(
        paused,
        "must not claim completion before native pause is acknowledged"
    );
}

#[test]
fn stopping_while_goal_activation_is_unacknowledged_still_pauses_it() {
    let directory = tempfile::tempdir().unwrap();
    let executable = directory.path().join("codex-fixture");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,sys
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
def goal(status): return {'threadId':'native-thread','objective':'test','status':status}
r=read(); write({'id':r['id'],'result':{}}); assert read()['method']=='initialized'
r=read(); write({'id':r['id'],'result':{'thread':{'id':'native-thread'}}})
r=read(); assert r['method']=='turn/start'; write({'id':r['id'],'result':{'turn':{'id':'first'}}})
activation=read(); assert activation['method']=='thread/goal/set'
write({'id':900,'method':'item/commandExecution/requestApproval','params':{}})
interrupt=read(); assert interrupt['method']=='turn/interrupt'
write({'id':activation['id'],'result':{'goal':goal('active')}})
write({'id':interrupt['id'],'result':{}})
pause=read(); assert pause['method']=='thread/goal/set' and pause['params']['status']=='paused'
write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'first','status':'interrupted'}}})
write({'id':pause['id'],'result':{'goal':goal('paused')}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let session = Session::start_with_mode_policy_and_profile(
        Provider::Codex,
        Launch {
            executable,
            cwd: directory.path().into(),
            session: None,
            prompt: "test".into(),
            model: None,
            variant: None,
            full_access: false,
        },
        Vec::new(),
        None,
        None,
        LaunchOptions {
            codex_goal: Some(codex_goals::Command::Set("test".into())),
            ..Default::default()
        },
    );
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Frame(frame) if frame["id"] == 900 => break,
            Event::Finished => panic!("ended before the user stop"),
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    session.stop_for_user();
    let mut paused = false;
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Goal {
                goal: Some(goal), ..
            } if goal["status"] == "paused" => paused = true,
            Event::Finished => break,
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    assert!(paused);
}

#[test]
fn queued_turn_temporarily_pauses_and_then_resumes_the_same_goal() {
    let directory = tempfile::tempdir().unwrap();
    let first = directory.path().join("goal-running");
    fs::write(&first, r#"#!/usr/bin/env python3
import json,sys
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
def goal(status): return {'threadId':'native-thread','objective':'test','status':status}
r=read(); write({'id':r['id'],'result':{}}); assert read()['method']=='initialized'
r=read(); write({'id':r['id'],'result':{'thread':{'id':'native-thread'}}})
r=read(); assert r['method']=='turn/start'; write({'id':r['id'],'result':{'turn':{'id':'first'}}})
r=read(); assert r['method']=='thread/goal/set'; write({'id':r['id'],'result':{'goal':goal('active')}})
write({'id':900,'method':'item/commandExecution/requestApproval','params':{}})
r=read(); assert r['method']=='thread/goal/set' and r['params']=={'threadId':'native-thread','status':'paused','origin':'automatic'}
write({'id':r['id'],'result':{'goal':goal('paused')}})
write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'first','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&first, fs::Permissions::from_mode(0o700)).unwrap();
    let running = Session::start_with_mode_policy_and_profile(
        Provider::Codex,
        Launch {
            executable: first,
            cwd: directory.path().into(),
            session: None,
            prompt: "test".into(),
            model: None,
            variant: None,
            full_access: false,
        },
        Vec::new(),
        None,
        None,
        LaunchOptions {
            codex_goal: Some(codex_goals::Command::Set("test".into())),
            ..Default::default()
        },
    );
    loop {
        match running.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Frame(frame) if frame["id"] == 900 => break,
            Event::Finished => panic!("ended before queueing"),
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    running.set_goal_queue_waiting(true);
    let mut paused = false;
    loop {
        match running.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Goal {
                goal: Some(goal),
                queue_action: Some(true),
                ..
            } if goal["status"] == "paused" => paused = true,
            Event::Finished => break,
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    assert!(paused);

    let second = directory.path().join("queued-turn");
    fs::write(&second, r#"#!/usr/bin/env python3
import json,sys
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
def goal(status): return {'threadId':'native-thread','objective':'test','status':status}
r=read(); write({'id':r['id'],'result':{}}); assert read()['method']=='initialized'
r=read(); assert r['method']=='thread/resume'; write({'id':r['id'],'result':{'thread':{'id':'native-thread'}}})
write({'method':'thread/goal/updated','params':{'threadId':'native-thread','goal':goal('paused')}})
r=read(); assert r['method']=='turn/start'; write({'id':r['id'],'result':{'turn':{'id':'queued'}}})
write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'queued','status':'completed'}}})
r=read(); assert r['method']=='thread/goal/set' and r['params']=={'threadId':'native-thread','status':'active','origin':'automatic'}
write({'id':r['id'],'result':{'goal':goal('active')}})
write({'method':'turn/started','params':{'threadId':'native-thread','turn':{'id':'continued'}}})
write({'method':'thread/goal/updated','params':{'threadId':'native-thread','goal':goal('complete')}})
write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'continued','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&second, fs::Permissions::from_mode(0o700)).unwrap();
    let queued = Session::start_with_mode_policy_and_profile(
        Provider::Codex,
        Launch {
            executable: second,
            cwd: directory.path().into(),
            session: Some("native-thread".into()),
            prompt: "queued message".into(),
            model: None,
            variant: None,
            full_access: false,
        },
        Vec::new(),
        None,
        None,
        LaunchOptions {
            resume_queued_goal: Some("test".into()),
            ..Default::default()
        },
    );
    let mut resumed = false;
    let mut boundary = false;
    loop {
        match queued.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Goal {
                goal: Some(goal),
                queue_action: Some(false),
                ..
            } if goal["status"] == "active" => resumed = true,
            Event::TurnBoundary => boundary = true,
            Event::Finished => break,
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    assert!(resumed && boundary);
}

#[test]
fn cancelling_a_waiting_queue_restores_the_goal_without_ending_the_turn() {
    let directory = tempfile::tempdir().unwrap();
    let executable = directory.path().join("codex-fixture");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,sys
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
def goal(status): return {'threadId':'native-thread','objective':'test','status':status}
r=read(); write({'id':r['id'],'result':{}}); assert read()['method']=='initialized'
r=read(); write({'id':r['id'],'result':{'thread':{'id':'native-thread'}}})
r=read(); assert r['method']=='turn/start'; write({'id':r['id'],'result':{'turn':{'id':'first'}}})
r=read(); assert r['method']=='thread/goal/set'; write({'id':r['id'],'result':{'goal':goal('active')}})
write({'id':900,'method':'item/commandExecution/requestApproval','params':{}})
r=read(); assert r['method']=='thread/goal/set' and r['params']['status']=='paused'
write({'id':r['id'],'result':{'goal':goal('paused')}})
write({'id':901,'method':'item/commandExecution/requestApproval','params':{}})
r=read(); assert r['method']=='thread/goal/set' and r['params']['status']=='active'
write({'id':r['id'],'result':{'goal':goal('active')}})
write({'method':'thread/goal/updated','params':{'threadId':'native-thread','goal':goal('complete')}})
write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'first','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let session = Session::start_with_mode_policy_and_profile(
        Provider::Codex,
        Launch {
            executable,
            cwd: directory.path().into(),
            session: None,
            prompt: "test".into(),
            model: None,
            variant: None,
            full_access: false,
        },
        Vec::new(),
        None,
        None,
        LaunchOptions {
            codex_goal: Some(codex_goals::Command::Set("test".into())),
            ..Default::default()
        },
    );
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Frame(frame) if frame["id"] == 900 => break,
            Event::Finished => panic!("ended before queueing"),
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    session.set_goal_queue_waiting(true);
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Frame(frame) if frame["id"] == 901 => break,
            Event::Finished => panic!("ended before queue cancellation"),
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    session.set_goal_queue_waiting(false);
    let mut resumed = false;
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Goal {
                goal: Some(goal),
                queue_action: Some(false),
                ..
            } if goal["status"] == "active" => resumed = true,
            Event::Finished => break,
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    assert!(resumed);
}

#[test]
fn restoring_a_queue_paused_goal_checks_the_native_objective_first() {
    for mode in ["matching", "changed"] {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join(mode);
        fs::write(&executable, r#"#!/usr/bin/env python3
import json,os,sys
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
mode=os.path.basename(sys.argv[0])
objective='test' if mode=='matching' else 'different'
def goal(status): return {'threadId':'native-thread','objective':objective,'status':status}
r=read(); write({'id':r['id'],'result':{}}); assert read()['method']=='initialized'
r=read(); assert r['method']=='thread/resume'; write({'id':r['id'],'result':{'thread':{'id':'native-thread'}}})
r=read(); assert r['method']=='thread/goal/get'; write({'id':r['id'],'result':{'goal':goal('paused')}})
if mode=='matching':
 r=read(); assert r['method']=='thread/goal/set' and r['params']=={'threadId':'native-thread','status':'active','origin':'automatic'}
 write({'id':r['id'],'result':{'goal':goal('active')}})
 write({'method':'turn/started','params':{'threadId':'native-thread','turn':{'id':'continued'}}})
 write({'method':'thread/goal/updated','params':{'threadId':'native-thread','goal':goal('complete')}})
 write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'continued','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let session = Session::start_with_mode_policy_and_profile(
            Provider::Codex,
            Launch {
                executable,
                cwd: directory.path().into(),
                session: Some("native-thread".into()),
                prompt: "".into(),
                model: None,
                variant: None,
                full_access: false,
            },
            Vec::new(),
            None,
            None,
            LaunchOptions {
                restore_paused_goal: Some("test".into()),
                ..Default::default()
            },
        );
        let mut continuation = false;
        loop {
            match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
                Event::Goal {
                    goal: Some(goal),
                    queue_action: Some(false),
                    ..
                } if goal["status"] == "active" => continuation = true,
                Event::Finished => break,
                Event::Failed(error) => panic!("{mode}: {error}"),
                _ => {}
            }
        }
        assert_eq!(continuation, mode == "matching");
    }
}

#[test]
fn resuming_a_goal_applies_the_selected_model_and_mode_before_continuation() {
    let directory = tempfile::tempdir().unwrap();
    let executable = directory.path().join("codex-fixture");
    fs::write(&executable, r#"#!/usr/bin/env python3
import json,sys
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
def goal(status): return {'threadId':'native-thread','objective':'test','status':status}
r=read(); write({'id':r['id'],'result':{}}); assert read()['method']=='initialized'
r=read(); assert r['method']=='thread/resume' and r['params']['model']=='new-model'
assert r['params']['approvalPolicy']=='never' and r['params']['sandbox']=='danger-full-access'
write({'id':r['id'],'result':{'thread':{'id':'native-thread'},'model':'new-model'}})
r=read(); assert r['method']=='thread/settings/update' and r['params']['threadId']=='native-thread'
assert r['params']['model']=='new-model' and r['params']['collaborationMode']['mode']=='plan'
assert r['params']['approvalPolicy']=='never' and r['params']['sandboxPolicy']=={'type':'dangerFullAccess'}
write({'id':r['id'],'result':{}})
r=read(); assert r['method']=='thread/goal/set' and r['params']['status']=='active'
write({'id':r['id'],'result':{'goal':goal('active')}})
write({'method':'turn/started','params':{'threadId':'native-thread','turn':{'id':'continued'}}})
write({'method':'thread/goal/updated','params':{'threadId':'native-thread','goal':goal('complete')}})
write({'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'continued','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let thread = json!({"selection":{"provider":"codex","modelID":"new-model"},"accessMode":"fullAccess","interactionMode":"plan"});
    let policy =
        crate::composer_policy::Policy::parse(&thread, crate::composer_policy::Origin::Ordinary)
            .unwrap();
    let session = Session::start_with_mode_policy_and_profile(
        Provider::Codex,
        Launch {
            executable,
            cwd: directory.path().into(),
            session: Some("native-thread".into()),
            prompt: "".into(),
            model: Some("new-model".into()),
            variant: None,
            full_access: true,
        },
        Vec::new(),
        None,
        Some(policy),
        LaunchOptions {
            codex_goal: Some(codex_goals::Command::Resume),
            ..Default::default()
        },
    );
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Finished => break,
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
}

/// This deliberately uses an isolated Codex home and a loopback-only mock
/// model. It never reads the developer's Codex account or sends network data.
#[test]
#[ignore = "requires COINCIDE_TEST_NATIVE_CODEX pointing at an installed Codex CLI"]
fn installed_codex_continues_and_pauses_through_the_real_adapter() {
    let native = std::env::var("COINCIDE_TEST_NATIVE_CODEX").expect("set the test CLI path");
    let directory = tempfile::tempdir().unwrap();
    let executable = directory.path().join("native-proxy");
    let proxy = r#"#!/usr/bin/env python3
import http.server,json,os,subprocess,sys,threading
first=threading.Event(); second=threading.Event(); pending={}; count=0
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  global count
  self.rfile.read(int(self.headers.get('Content-Length','0'))); count+=1; n=count
  (first if n==1 else second).wait(20)
  ident='synthetic-'+str(n)
  events=[{'type':'response.created','response':{'id':ident}},{'type':'response.output_item.done','item':{'type':'message','role':'assistant','id':'answer-'+str(n),'content':[{'type':'output_text','text':'synthetic progress'}]}},{'type':'response.completed','response':{'id':ident,'usage':{'input_tokens':5,'input_tokens_details':None,'output_tokens':2,'output_tokens_details':None,'total_tokens':7}}}]
  body=''.join('event: '+e['type']+'\ndata: '+json.dumps(e)+'\n\n' for e in events).encode()
  try:
   self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
  except (BrokenPipeError,ConnectionResetError): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);server.daemon_threads=True
threading.Thread(target=server.serve_forever,daemon=True).start()
home=os.path.join(os.getcwd(),'isolated-home');os.makedirs(home,exist_ok=True)
open(os.path.join(home,'config.toml'),'w').write('model="mock-model"\nmodel_provider="mock"\napproval_policy="never"\nsandbox_mode="read-only"\n[features]\ngoals=true\n[model_providers.mock]\nname="Synthetic"\nbase_url="http://127.0.0.1:'+str(server.server_port)+'/v1"\nwire_api="responses"\nsupports_websockets=false\nrequest_max_retries=0\nstream_max_retries=0\n')
env={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','HOME':home,'CODEX_HOME':home,'TMPDIR':home,'LANG':'en_US.UTF-8'}
p=subprocess.Popen([__CLI_PATH__,'app-server'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,env=env)
def write_input():
 for line in sys.stdin:
  m=json.loads(line)
  if m.get('method')=='thread/goal/set': pending[m['id']]=m['params'].get('status')
  p.stdin.write(line);p.stdin.flush()
 try:p.stdin.close()
 except BrokenPipeError:pass
threading.Thread(target=write_input,daemon=True).start()
try:
 for line in p.stdout:
  m=json.loads(line); status=pending.pop(m.get('id'),None)
  print(line,end='',flush=True)
  if status=='active' and m.get('result',{}).get('goal',{}).get('status')=='active': first.set()
  if status=='paused' and m.get('result',{}).get('goal',{}).get('status')=='paused': second.set()
finally:
 first.set();second.set();p.kill();p.wait();server.shutdown();server.server_close()
"#;
    fs::write(
        &executable,
        proxy.replace("__CLI_PATH__", &serde_json::to_string(&native).unwrap()),
    )
    .unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    assert!(std::path::Path::new(&native).is_file());
    let policy = crate::composer_policy::Policy::parse(
        &json!({"selection":{"provider":"codex","modelID":"mock-model"},"accessMode":"approval","interactionMode":"build"}),
        crate::composer_policy::Origin::Ordinary,
    ).unwrap();
    let session = Session::start_with_mode_policy_and_profile(
        Provider::Codex,
        Launch {
            executable: executable.clone(),
            cwd: directory.path().into(),
            session: None,
            prompt: "Synthetic validation".into(),
            model: Some("mock-model".into()),
            variant: None,
            full_access: false,
        },
        Vec::new(),
        None,
        Some(policy.clone()),
        LaunchOptions {
            codex_goal: Some(codex_goals::Command::Set("Synthetic validation".into())),
            ..Default::default()
        },
    );
    fn pause_after_continuation(session: &Session) -> String {
        let mut native_thread = None;
        loop {
            match session
                .events
                .recv_timeout(Duration::from_secs(30))
                .unwrap()
            {
                Event::Session(id) => native_thread = Some(id),
                Event::TurnBoundary => break,
                Event::Finished => panic!("native goal ended before its continuation"),
                Event::Failed(error) => panic!("{error}"),
                _ => {}
            }
        }
        let deadline = Instant::now() + Duration::from_secs(15);
        while !session.can_steer() {
            assert!(Instant::now() < deadline, "continuation did not start");
            std::thread::sleep(Duration::from_millis(10));
        }
        session
            .begin_steer_text("/goal pause")
            .unwrap()
            .recv_timeout(Duration::from_secs(15))
            .unwrap()
            .unwrap();
        let mut paused = false;
        loop {
            match session
                .events
                .recv_timeout(Duration::from_secs(30))
                .unwrap()
            {
                Event::Goal {
                    goal: Some(goal), ..
                } if goal["status"] == "paused" => paused = true,
                Event::Finished => break,
                Event::Failed(error) => panic!("{error}"),
                _ => {}
            }
        }
        assert!(paused);
        let deadline = Instant::now() + Duration::from_secs(15);
        while session.worker_completion().status() == WorkerThreadStatus::Running {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        native_thread.expect("native thread acknowledged")
    }
    let native_thread = pause_after_continuation(&session);
    drop(session);
    let resumed = Session::start_with_mode_policy_and_profile(
        Provider::Codex,
        Launch {
            executable,
            cwd: directory.path().into(),
            session: Some(native_thread.clone()),
            prompt: String::new(),
            model: Some("mock-model".into()),
            variant: None,
            full_access: false,
        },
        Vec::new(),
        None,
        Some(policy),
        LaunchOptions {
            codex_goal: Some(codex_goals::Command::Resume),
            ..Default::default()
        },
    );
    assert_eq!(pause_after_continuation(&resumed), native_thread);
}
