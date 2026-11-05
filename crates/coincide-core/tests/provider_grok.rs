//! Grok's wire contract uses real subprocess pipes, without account or network calls.
#![cfg(unix)]
use coincide_core::agent::{Event, ImageAttachment, Launch, Provider, Session};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    time::{Duration, Instant},
};

fn fixture(
    source: &str,
    resume: Option<&str>,
    model: Option<&str>,
    with_image: bool,
) -> (tempfile::TempDir, Session) {
    let dir = tempfile::tempdir().unwrap();
    let executable = dir.path().join("fixture");
    fs::write(&executable, format!("#!/usr/bin/env python3\nimport json,sys,os\ndef read(): return json.loads(sys.stdin.readline())\ndef write(v): print(json.dumps(v),flush=True)\ndef reply(r,v): write({{'jsonrpc':'2.0','id':r['id'],'result':v}})\ndef error(r): write({{'jsonrpc':'2.0','id':r['id'],'error':{{'code':-32000,'message':'authentication required'}}}})\n{source}")).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let images = if with_image {
        let path = dir.path().join("image.png");
        let bytes = vec![137, 80, 78, 71, 13, 10, 26, 10];
        fs::write(&path, &bytes).unwrap();
        vec![ImageAttachment::new(path, "image/png".into(), bytes).unwrap()]
    } else {
        vec![]
    };
    let session = Session::start_with_images(
        Provider::Grok,
        Launch {
            executable,
            cwd: dir.path().into(),
            session: resume.map(str::to_owned),
            prompt: "fixture prompt".into(),
            model: model.map(str::to_owned),
        },
        images,
    );
    (dir, session)
}
fn receive(session: &Session) -> Event {
    session
        .events
        .recv_timeout(Duration::from_secs(5))
        .expect("Grok fixture timed out")
}
fn finished(session: &Session) -> Vec<Value> {
    let mut frames = Vec::new();
    loop {
        match receive(session) {
            Event::Finished => return frames,
            Event::Failed(error) => panic!("Grok failed: {error}"),
            Event::Frame(frame) => frames.push(frame),
            Event::Session(_) => {}
        }
    }
}

#[test]
fn named_providers_never_silently_route_unsupported_transports() {
    assert_eq!(
        Provider::supported_names(),
        &[
            "codex",
            "claude",
            "grok",
            "opencode",
            "cursor",
            "antigravity"
        ]
    );
    for name in Provider::supported_names() {
        assert_eq!(Provider::from_name(name).unwrap().id(), *name);
    }
    assert!(Provider::from_name("unknown").is_err());
}

#[test]
fn grok_auth_resume_models_images_and_user_requests_follow_its_wire_contract() {
    let (_dir, session) = fixture(
        r#"
assert sys.argv[1:]==['--permission-mode','default','agent','stdio']
r=read();assert r['method']=='initialize'
assert r['params']['_meta']=={'clientType':'extension'}
assert r['params']['clientCapabilities']['terminal']==False
reply(r,{'protocolVersion':1,'agentCapabilities':{'loadSession':True,'promptCapabilities':{'image':False}},'authMethods':[{'id':'cached_token','type':'agent'},{'id':'xai.api_key','type':'agent'}]})
r=read();assert r['method']=='session/load' and r['params']['sessionId']=='native-session'
original=r;error(r)
r=read();assert r['method']=='authenticate'
assert r['params']['methodId']==('xai.api_key' if os.environ.get('XAI_API_KEY','').strip() else 'cached_token')
reply(r,{'credential_marker':'must-not-reach-transcript'})
r=read();assert r==original
reply(r,{'sessionId':'native-session'})
r=read();assert r['method']=='session/set_model' and r['params']['modelId']=='explicit-model'
reply(r,{})
r=read();assert r['method']=='session/prompt'
p=r['params'];pid=p['_meta']['promptId'];assert pid and p['_meta']['requestId']==pid
assert p['prompt']==[{'type':'text','text':'fixture prompt'},{'type':'image','mimeType':'image/png','data':'iVBORw0KGgo='}]
write({'jsonrpc':'2.0','method':'_x.ai/session/prompt_complete','params':{'sessionId':'native-session','promptId':'task-completed-background','stopReason':'end_turn'}})
write({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'native-session','_meta':{'promptId':'task-completed-background'},'update':{'sessionUpdate':'agent_message_chunk','content':{'text':'BACKGROUND'}}}})
write({'jsonrpc':'2.0','id':'permission','method':'session/request_permission','params':{'sessionId':'native-session','toolCall':{'title':'Write file'},'options':[{'optionId':'permanent','kind':'allow_always'},{'optionId':'once','kind':'allow_once'},{'optionId':'no','kind':'reject_once'}]}})
r=read();assert r['id']=='permission' and r['result']['outcome']=={'outcome':'selected','optionId':'once'}
write({'jsonrpc':'2.0','id':'question','method':'_x.ai/ask_user_question','params':{'sessionId':'native-session','questions':[{'id':'q','question':'Which approach?','options':[{'label':'A','preview':'Keep original'}]}]}})
r=read();assert r['id']=='question' and r['result']=={'outcome':'accepted','answers':{'Which approach?':['A']},'annotations':{'Which approach?':{'preview':'Keep original','notes':'Preserve threads'}}}
write({'jsonrpc':'2.0','id':'plan','method':'x.ai/exit_plan_mode','params':{'sessionId':'native-session','planContent':'The plan'}})
r=read();assert r['id']=='plan' and r['result']['outcome']=='abandoned'
write({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'native-session','_meta':{'promptId':pid},'update':{'sessionUpdate':'agent_message_chunk','content':{'text':'FOREGROUND'}}}})
write({'jsonrpc':'2.0','method':'x.ai/session_notification','params':{'sessionId':'native-session','update':{'sessionUpdate':'turn_completed','prompt_id':pid,'stop_reason':'end_turn'}}})
sys.stdin.readline()
"#,
        Some("native-session"),
        Some("explicit-model"),
        true,
    );
    let mut saw_permission = false;
    let mut saw_question = false;
    let mut saw_plan = false;
    let mut foreground = String::new();
    let mut native_session = false;
    loop {
        match receive(&session) {
            Event::Session(id) => {
                assert_eq!(id, "native-session");
                native_session = true;
            }
            Event::Frame(frame) => {
                assert!(!frame.to_string().contains("must-not-reach-transcript"));
                match frame["method"].as_str() {
                    Some("item/commandExecution/requestApproval") => {
                        saw_permission = true;
                        session
                            .reply(frame["id"].clone(), json!({"decision":"accept"}))
                            .unwrap();
                    }
                    Some("item/tool/requestUserInput") => {
                        saw_question = true;
                        session
                            .reply(
                                frame["id"].clone(),
                                json!({"answers":{"q":{"answers":["A","Preserve threads"]}}}),
                            )
                            .unwrap();
                    }
                    Some("item/agentMessage/delta") => {
                        foreground.push_str(frame["params"]["delta"].as_str().unwrap())
                    }
                    Some("item/completed") if frame["params"]["item"]["type"] == "plan" => {
                        saw_plan = true
                    }
                    _ => {}
                }
            }
            Event::Finished => break,
            Event::Failed(error) => panic!("{error}"),
        }
    }
    assert!(native_session && saw_permission && saw_question && saw_plan);
    assert_eq!(foreground, "FOREGROUND");
}

#[test]
fn grok_authentication_failure_never_restarts_a_resumed_session() {
    let (dir, session) = fixture(
        r#"
r=read();reply(r,{'protocolVersion':1,'agentCapabilities':{'loadSession':True}})
r=read();assert r['method']=='session/load';error(r)
r=read();assert r['method']=='authenticate';reply(r,{})
r=read();assert r['method']=='session/load';error(r)
# Any further request means the client retried authentication or silently forked.
if sys.stdin.readline(): open('unexpected-request','w').write('bad')
"#,
        Some("original"),
        None,
        false,
    );
    loop {
        match receive(&session) {
            Event::Failed(error) => {
                assert!(error.contains("authentication failed"));
                break;
            }
            Event::Finished => panic!("Failed authentication reported success"),
            Event::Session(_) => panic!("Failed resume changed session"),
            _ => {}
        }
    }
    assert!(!dir.path().join("unexpected-request").exists());
}

#[test]
fn grok_provider_errors_never_report_successful_completion() {
    for reason in ["error", "rate_limit", "cancelled"] {
        let source = format!(
            r#"
r=read();reply(r,{{'protocolVersion':1,'agentCapabilities':{{}}}})
r=read();reply(r,{{'sessionId':'session'}})
r=read();assert r['method']=='session/prompt'
write({{'method':'x.ai/session/prompt_complete','params':{{'sessionId':'session','promptId':r['params']['_meta']['promptId'],'stopReason':'{reason}','agentResult':'fixture failure'}}}})
sys.stdin.readline()
"#
        );
        let (_dir, session) = fixture(&source, None, Some("grok-build"), false);
        loop {
            match receive(&session) {
                Event::Failed(error) => {
                    assert!(error.contains(match reason {
                        "error" => "fixture failure",
                        "rate_limit" => "usage limit",
                        _ => "interrupted",
                    }));
                    break;
                }
                Event::Finished => panic!("Failure reported successful completion"),
                _ => {}
            }
        }
    }
}

#[test]
fn grok_stop_terminates_process_instead_of_leaving_background_wakes() {
    let (dir, session) = fixture(
        r#"
open('pid','w').write(str(os.getpid()))
r=read();reply(r,{'protocolVersion':1,'agentCapabilities':{}})
r=read();reply(r,{'sessionId':'session'})
r=read();open('prompt-ready','w').write('ready')
import time;time.sleep(30)
"#,
        None,
        None,
        false,
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while !dir.path().join("prompt-ready").exists() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    let started = Instant::now();
    session.stop();
    finished(&session);
    assert!(started.elapsed() < Duration::from_secs(2));
    let pid = fs::read_to_string(dir.path().join("pid"))
        .unwrap()
        .parse::<i32>()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(
            Instant::now() < deadline,
            "Grok child remained alive after Stop"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}
