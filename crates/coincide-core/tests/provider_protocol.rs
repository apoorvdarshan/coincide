//! Real pipe/process fixtures: no provider accounts, network calls or model quota.
#![cfg(unix)]
use coincide_core::agent::{Event, Launch, Provider, Session, set_provider_session};
use serde_json::json;
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    time::{Duration, Instant},
};

fn fixture(
    source: &str,
    provider: Provider,
    resume: Option<&str>,
    model: Option<&str>,
) -> (tempfile::TempDir, Session) {
    fixture_with_prompt(source, provider, resume, model, "fixture prompt")
}

fn fixture_with_prompt(
    source: &str,
    provider: Provider,
    resume: Option<&str>,
    model: Option<&str>,
    prompt: &str,
) -> (tempfile::TempDir, Session) {
    let dir = tempfile::tempdir().unwrap();
    let executable = dir.path().join("fixture");
    fs::write(&executable, format!("#!/usr/bin/env python3\nimport json,sys,os\ndef read():\n return json.loads(sys.stdin.readline())\ndef write(value):\n print(json.dumps(value),flush=True)\n{source}")).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let session = Session::start_with(
        provider,
        Launch {
            executable,
            cwd: dir.path().into(),
            session: resume.map(str::to_owned),
            prompt: prompt.into(),
            model: model.map(str::to_owned),
        },
    );
    (dir, session)
}

fn receive(session: &Session) -> Event {
    session
        .events
        .recv_timeout(Duration::from_secs(5))
        .expect("fixture timed out")
}

const HUNG_INPUT_FIXTURE: &str = r#"
open('pid','w').write(str(os.getpid()))
if sys.argv[1:] == ['app-server']:
 r=read();write({'id':r['id'],'result':{}})
 assert read()['method']=='initialized'
 r=read();assert r['method']=='thread/start'
 write({'id':r['id'],'result':{'thread':{'id':'hung-codex'}}})
elif '--input-format' in sys.argv:
 r=read();write({'type':'control_response','response':{'subtype':'success','request_id':r['request_id']}})
else:
 r=read();write({'id':r['id'],'result':{'protocolVersion':1,'agentCapabilities':{}}})
 r=read();assert r['method']=='session/new'
 write({'id':r['id'],'result':{'sessionId':'hung-acp'}})
# Confirm the large prompt is entering the pipe, then deliberately stop reading.
assert sys.stdin.buffer.read(1)==b'{'
open('blocked-input','w').write('yes')
import time;time.sleep(30)
"#;

fn await_blocked_input(directory: &std::path::Path) {
    let deadline = Instant::now() + Duration::from_secs(4);
    while !directory.join("blocked-input").exists() {
        assert!(
            Instant::now() < deadline,
            "fixture did not receive prompt bytes"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn assert_reaped(directory: &std::path::Path) {
    let pid = fs::read_to_string(directory.join("pid")).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let alive = std::process::Command::new("kill")
            .args(["-0", pid.trim()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success();
        if !alive {
            return;
        }
        assert!(Instant::now() < deadline, "provider process was not reaped");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn cancellation_remains_responsive_when_each_provider_blocks_a_large_stdin_write() {
    let prompt = "x".repeat(2 * 1024 * 1024);
    for provider in [
        Provider::Codex,
        Provider::Claude,
        Provider::AcpV1 {
            arguments: vec!["fixture-acp".into()],
        },
    ] {
        let (directory, session) =
            fixture_with_prompt(HUNG_INPUT_FIXTURE, provider, None, None, &prompt);
        await_blocked_input(directory.path());
        let started = Instant::now();
        session.stop();
        loop {
            match receive(&session) {
                Event::Finished => break,
                Event::Failed(error) => panic!("explicit cancellation failed: {error}"),
                _ => {}
            }
        }
        assert!(
            started.elapsed() < Duration::from_secs(4),
            "Stop waited for a blocked pipe write"
        );
        assert_reaped(directory.path());
    }
}

#[test]
fn blocked_stdin_has_a_deadline_and_reports_failure_without_explicit_stop() {
    let (directory, session) = fixture_with_prompt(
        HUNG_INPUT_FIXTURE,
        Provider::Claude,
        None,
        None,
        &"x".repeat(2 * 1024 * 1024),
    );
    await_blocked_input(directory.path());
    let deadline = Instant::now() + Duration::from_secs(14);
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "blocked write never timed out");
        match session
            .events
            .recv_timeout(remaining)
            .expect("blocked write never timed out")
        {
            Event::Failed(error) => {
                assert!(error.contains("stdin write timed out"), "{error}");
                break;
            }
            Event::Finished => panic!("a write deadline must fail, not finish successfully"),
            _ => {}
        }
    }
    assert_reaped(directory.path());
}

#[test]
fn a_success_frame_cannot_hide_a_failed_prompt_write() {
    let source = r#"
open('pid','w').write(str(os.getpid()))
r=read();write({'type':'control_response','response':{'subtype':'success','request_id':r['request_id']}})
os.close(0)
write({'type':'result','subtype':'success','is_error':False,'result':'premature success'})
import time;time.sleep(30)
"#;
    let (directory, session) = fixture_with_prompt(
        source,
        Provider::Claude,
        None,
        None,
        &"x".repeat(2 * 1024 * 1024),
    );
    loop {
        match receive(&session) {
            Event::Failed(error) => {
                assert!(error.contains("stdin"), "{error}");
                break;
            }
            Event::Finished => panic!("provider completion hid a broken stdin pipe"),
            _ => {}
        }
    }
    assert_reaped(directory.path());
}

#[test]
fn claude_stream_resume_questions_and_once_permissions_use_real_protocol() {
    let (_dir, session) = fixture(
        r#"
assert '--permission-mode' in sys.argv and sys.argv[sys.argv.index('--permission-mode')+1]=='default'
assert '--dangerously-skip-permissions' not in sys.argv and '--allow-dangerously-skip-permissions' not in sys.argv
assert sys.argv[sys.argv.index('--resume')+1]=='existing-claude'
assert sys.argv[sys.argv.index('--model')+1]=='fixture-model'
assert 'CLAUDECODE' not in os.environ and 'CLAUDE_CODE_SESSION_ID' not in os.environ
assert 'COINCIDE_THREAD_ID' not in os.environ and 'CODEX_THREAD_ID' not in os.environ
assert 'coincide-unbound-' in os.environ['COINCIDE_CONTROL_SOCKET']
assert not os.path.exists(os.environ['COINCIDE_CONTROL_SOCKET'])
r=read();assert r['type']=='control_request' and r['request']['subtype']=='initialize'
write({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{}}})
r=read();assert r['type']=='user' and r['message']['content']=='fixture prompt'
write({'type':'system','subtype':'init','session_id':'existing-claude','future':42})
write({'type':'stream_event','event':{'type':'message_start','message':{'id':'message-1'}}})
write({'type':'stream_event','event':{'type':'content_block_start','index':0,'content_block':{'type':'text','text':''}}})
write({'type':'stream_event','event':{'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'Hello'}}})
write({'type':'assistant','message':{'id':'message-1','content':[{'type':'text','text':'Hello!'}]}})
write({'type':'control_request','request_id':'approval-1','request':{'subtype':'can_use_tool','tool_name':'Write','tool_use_id':'tool-1','input':{'file_path':'a','content':'b','future':42}}})
r=read();assert r['type']=='control_response'
v=r['response'];assert v['request_id']=='approval-1' and v['subtype']=='success'
v=v['response'];assert v=={'behavior':'allow','updatedInput':{'file_path':'a','content':'b','future':42},'decisionClassification':'user_temporary','toolUseID':'tool-1'}
write({'type':'control_request','request_id':'malformed-question','request':{'subtype':'can_use_tool','tool_name':'AskUserQuestion','input':{'questions':['not an object']}}})
r=read()['response'];assert r['request_id']=='malformed-question' and r['response']['behavior']=='deny'
write({'type':'control_request','request_id':'question-1','request':{'subtype':'can_use_tool','tool_name':'AskUserQuestion','tool_use_id':'q-1','input':{'questions':[{'question':'Which?','options':[{'label':'A'},{'label':'B'}]}]}}})
r=read()['response'];assert r['request_id']=='question-1'
assert r['response']['updatedInput']['answers']=={'Which?':'A, B'}
write({'type':'result','subtype':'success','is_error':False,'session_id':'existing-claude','result':'must not duplicate final text'})
sys.stdin.readline()
"#,
        Provider::Claude,
        Some("existing-claude"),
        Some("fixture-model"),
    );
    let mut sessions = 0;
    let mut texts = std::collections::HashMap::<String, String>::new();
    let mut approvals = 0;
    let mut questions = 0;
    loop {
        match receive(&session) {
            Event::Session(id) => {
                assert_eq!(id, "existing-claude");
                sessions += 1;
            }
            Event::Frame(frame) => match frame["method"].as_str() {
                Some("item/agentMessage/delta") => {
                    texts
                        .entry(frame["params"]["itemId"].as_str().unwrap().into())
                        .or_default()
                        .push_str(frame["params"]["delta"].as_str().unwrap());
                }
                Some("item/completed") if frame["params"]["item"]["type"] == "agentMessage" => {
                    let item = &frame["params"]["item"];
                    texts.insert(
                        item["id"].as_str().unwrap().into(),
                        item["text"].as_str().unwrap().into(),
                    );
                }
                Some("item/commandExecution/requestApproval") => {
                    approvals += 1;
                    assert_eq!(
                        frame["params"]["providerFrame"]["request"]["input"]["future"],
                        42
                    );
                    session
                        .reply(frame["id"].clone(), json!({"decision":"accept"}))
                        .unwrap();
                }
                Some("item/tool/requestUserInput") => {
                    questions += 1;
                    assert_eq!(frame["params"]["questions"][0]["id"], "Which?");
                    session
                        .reply(
                            frame["id"].clone(),
                            json!({"answers":{"Which?":{"answers":["A","B"]}}}),
                        )
                        .unwrap();
                }
                _ => {}
            },
            Event::Finished => break,
            Event::Failed(error) => panic!("{error}"),
        }
    }
    assert_eq!((sessions, approvals, questions), (1, 1, 1));
    assert_eq!(
        texts,
        std::collections::HashMap::from([("message-1:0".into(), "Hello!".into())])
    );
}

#[test]
fn claude_failed_result_does_not_report_completion() {
    let (_dir, session) = fixture(
        r#"
r=read();write({'type':'control_response','response':{'subtype':'success','request_id':r['request_id']}})
read();write({'type':'result','subtype':'error_during_execution','is_error':True,'errors':['fixture failure']})
sys.stdin.readline()
"#,
        Provider::Claude,
        None,
        None,
    );
    loop {
        match receive(&session) {
            Event::Failed(error) => {
                assert!(error.contains("fixture failure"));
                break;
            }
            Event::Finished => panic!("failure must not finish successfully"),
            _ => {}
        }
    }
}

#[test]
fn claude_cancellation_interrupts_and_reaps_unresponsive_child() {
    let (dir, session) = fixture(
        r#"
open('pid','w').write(str(os.getpid()))
import subprocess
child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'])
assert os.getpgid(child.pid)==os.getpid()
open('grandchild-pid','w').write(str(child.pid))
r=read();write({'type':'control_response','response':{'subtype':'success','request_id':r['request_id']}})
read();write({'type':'stream_event','event':{'type':'message_start','message':{'id':'ready'}}})
r=read();assert r['request']['subtype']=='interrupt' and r['request']['cancel_queued']==True
open('interrupted','w').write('yes')
import time;time.sleep(30)
"#,
        Provider::Claude,
        None,
        None,
    );
    loop {
        if let Event::Frame(frame) = receive(&session)
            && frame["params"]["providerFrame"]["event"]["message"]["id"] == "ready"
        {
            break;
        }
    }
    let started = Instant::now();
    session.stop();
    loop {
        match receive(&session) {
            Event::Finished => break,
            Event::Failed(error) => panic!("{error}"),
            _ => {}
        }
    }
    assert!(started.elapsed() < Duration::from_secs(5));
    assert_eq!(
        fs::read_to_string(dir.path().join("interrupted")).unwrap(),
        "yes"
    );
    let pid = fs::read_to_string(dir.path().join("pid")).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let alive = std::process::Command::new("kill")
            .args(["-0", pid.trim()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success();
        if !alive {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "provider child leaked after cancellation"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let grandchild = fs::read_to_string(dir.path().join("grandchild-pid")).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let status = std::process::Command::new("ps")
            .args(["-p", grandchild.trim(), "-o", "stat="])
            .output()
            .unwrap();
        let state = String::from_utf8_lossy(&status.stdout);
        // A reparented zombie is terminated, awaiting the platform's init reaper.
        if state.trim().is_empty() || state.trim().starts_with('Z') {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "provider grandchild survived cancellation"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn acp_resume_ignores_replay_and_preserves_rpc_ids_and_permission_options() {
    let (_dir, session) = fixture(
        r#"
assert sys.argv[1:]==['agent','stdio']
r=read();assert r['method']=='initialize' and r['params']['protocolVersion']==1
assert r['params']['clientCapabilities']['terminal']==False
assert r['params']['clientCapabilities']['fs']['writeTextFile']==False
write({'jsonrpc':'2.0','id':r['id'],'result':{'protocolVersion':1,'agentCapabilities':{'loadSession':True}}})
r=read();assert r['method']=='session/load' and r['params']['sessionId']=='acp-session'
write({'method':'session/update','params':{'sessionId':'acp-session','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'old replay'}}}})
write({'id':r['id'],'result':{'models':{'currentModelId':'fixture-model','availableModels':[{'modelId':'fixture-model'}]}}})
r=read();assert r['method']=='session/prompt' and r['params']['prompt'][0]['text']=='fixture prompt'
prompt_id=r['id']
write({'id':'permission/string','method':'session/request_permission','params':{'sessionId':'acp-session','toolCall':{'toolCallId':'tool-1','title':'Fixture tool','future':42},'options':[{'optionId':'permanent','kind':'allow_always'},{'optionId':'one-use','kind':'allow_once'},{'optionId':'deny','kind':'reject_once'}]}})
r=read();assert r['id']=='permission/string' and r['result']=={'outcome':{'outcome':'selected','optionId':'one-use'}}
write({'id':'unsupported','method':'fs/write_text_file','params':{'sessionId':'acp-session','path':'must-not-exist','content':'bad'}})
r=read();assert r['id']=='unsupported' and r['error']['code']==-32601
write({'method':'session/update','params':{'sessionId':'acp-session','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'new reply'}}}})
write({'id':prompt_id,'result':{'stopReason':'end_turn'}})
sys.stdin.readline()
"#,
        Provider::AcpV1 {
            arguments: vec!["agent".into(), "stdio".into()],
        },
        Some("acp-session"),
        Some("fixture-model"),
    );
    let mut output = String::new();
    let mut ids = Vec::new();
    let mut approval = false;
    loop {
        match receive(&session) {
            Event::Session(id) => ids.push(id),
            Event::Frame(frame) if frame["method"] == "item/commandExecution/requestApproval" => {
                approval = true;
                assert_eq!(
                    frame["params"]["providerFrame"]["params"]["toolCall"]["future"],
                    42
                );
                session
                    .reply(frame["id"].clone(), json!({"decision":"accept"}))
                    .unwrap();
            }
            Event::Frame(frame) if frame["method"] == "item/agentMessage/delta" => {
                output.push_str(frame["params"]["delta"].as_str().unwrap())
            }
            Event::Frame(_) => {}
            Event::Finished => break,
            Event::Failed(error) => panic!("{error}"),
        }
    }
    assert_eq!(ids, ["acp-session"]);
    assert_eq!(output, "new reply");
    assert!(approval);
}

#[test]
fn acp_rejects_v2_without_sending_prompt() {
    let (_dir, session) = fixture(
        r#"
r=read();write({'id':r['id'],'result':{'protocolVersion':2,'agentCapabilities':{}}})
r=sys.stdin.readline();assert not r
"#,
        Provider::AcpV1 { arguments: vec![] },
        None,
        None,
    );
    loop {
        match receive(&session) {
            Event::Failed(error) => {
                assert!(error.contains("protocol version 1"));
                break;
            }
            Event::Finished => panic!("unsupported protocol must not report success"),
            _ => {}
        }
    }
}

#[test]
fn acp_resume_failure_never_starts_replacement_session() {
    let (_dir, session) = fixture(
        r#"
r=read();write({'id':r['id'],'result':{'protocolVersion':1,'agentCapabilities':{'loadSession':True}}})
r=read();assert r['method']=='session/load'
write({'id':r['id'],'error':{'code':-32000,'message':'stored session unavailable'}})
r=sys.stdin.readline();assert not r
"#,
        Provider::AcpV1 { arguments: vec![] },
        Some("old-session"),
        None,
    );
    loop {
        match receive(&session) {
            Event::Failed(error) => {
                assert!(error.contains("stored session unavailable"));
                break;
            }
            Event::Session(_) | Event::Finished => panic!("failed resume must not replace session"),
            _ => {}
        }
    }
}

#[test]
fn object_session_updates_preserve_unknown_fields_and_accounts() {
    let mut thread = json!({"items":[],"sessions":{"claude":{"sessionID":"old","future":{"field":42}},"codex":{"sessionID":"other"}},"accountSessions":{"claude/second":{"sessionID":"account-specific"}}});
    set_provider_session(&mut thread, "claude", "new");
    assert_eq!(thread["sessions"]["claude"]["future"]["field"], 42);
    assert_eq!(thread["sessions"]["codex"]["sessionID"], "other");
    assert_eq!(
        thread["accountSessions"]["claude/second"]["sessionID"],
        "account-specific"
    );
    assert_eq!(thread["sessions"]["claude"]["sessionID"], "new");
}
