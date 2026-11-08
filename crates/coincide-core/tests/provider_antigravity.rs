//! Synthetic subprocesses only: no installed Antigravity runtime or credentials.
#![cfg(unix)]
use coincide_core::agent::{Event, Launch, Provider, Session};
use coincide_core::{api::Engine, store::Store};
use serde_json::json;
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    process::Command,
    time::{Duration, Instant},
};
const ID: &str = "3f2b8c1e-9d4a-4b6f-8e2d-1c0a9b8f7e6d";
const SCRIPT: &str = r#"
import json,os,sys,subprocess
from pathlib import Path
read=lambda:json.loads(sys.stdin.readline())
def send(v): print(json.dumps(v),flush=True)
def reply(r,v): send({'jsonrpc':'2.0','id':r['id'],'result':v})
root=Path.cwd();profile=Path(os.environ['GEMINI_HOME']); original=root/'original'
assert profile!=original and profile.is_relative_to(root)
assert Path(__file__).resolve().is_relative_to(profile/'runtime')
assert Path(os.environ['ANTIGRAVITY_HARNESS_PATH']).parent==Path(__file__).resolve().parent
assert os.environ['AGY_ACP_FORCE_FILE_STORAGE']=='1'
assert Path(os.environ['TMPDIR']).is_relative_to(profile/'runtime')
# Model an extracted runtime tree so completion must wait for real cleanup.
for index in range(32):
 extracted=Path(os.environ['TMPDIR'])/str(index);extracted.mkdir()
 (extracted/'runtime-part').write_bytes(b'fixture extraction')
for key in ['GEMINI_API_KEY','GOOGLE_API_KEY','GOOGLE_APPLICATION_CREDENTIALS','AGY_ACP_ENABLE_OAUTH']:
 assert key not in os.environ
assert json.loads((profile/'antigravity-acp/settings.json').read_text())=={'auth':{'type':'oauth-personal'}}
(profile/'antigravity-acp/acp_token.json').write_text(json.dumps({'client_id':'fixture-client','client_secret':'fixture-secret','refresh_token':'private-refresh'}))
(root/'pid').write_text(str(os.getpid()))
print('Antigravity diagnostic startup',flush=True)
r=read();assert r['method']=='initialize'
reply(r,{'protocolVersion':1,'agentCapabilities':{'loadSession':True,'sessionCapabilities':{'resume':{}},'promptCapabilities':{'image':True}},'authMethods':[{'id':'oauth-personal'}]})
r=read();assert r['method']=='authenticate' and r['params']=={'methodId':'oauth-personal'}
if MODE=='auth-stdout':
 print('Open the following link to authenticate the ACP server: https://accounts.google.com/?secret-must-not-leak',flush=True);sys.stdin.readline();sys.exit(0)
if MODE=='auth-stderr':
 subprocess.run(['/bin/sh',str(profile/'browser-suppressed.sh'),'https://accounts.google.com/?secret-must-not-leak']);sys.stdin.readline();sys.exit(0)
reply(r,{'secret':'secret-must-not-leak'})
r=read();assert r['method']==('session/resume' if MODE.startswith('resume') else 'session/new')
if MODE.startswith('resume'):
 assert r['params']['sessionId']==ID
 assert (profile/'antigravity-acp/conversations'/f'{ID}.db').read_bytes()==b'native history'
 assert (profile/'antigravity-acp/brain'/ID/'artifact.txt').read_text()=='preserve artifact'
 send({'method':'session/update','params':{'sessionId':ID,'update':{'sessionUpdate':'agent_message_chunk','content':{'text':'OLD REPLAY'}}}})
 if MODE=='resume-failed':send({'id':r['id'],'error':{'code':-32602,'message':'secret-must-not-leak'}});sys.stdin.readline();sys.exit(0)
reply(r,{'sessionId':ID,'configOptions':[{'id':'model','category':'model','currentValue':'old','options':[{'value':'chosen'}]},{'id':'mode','category':'mode','currentValue':'yolo','options':[{'value':'default'},{'value':'yolo'}]}]})
r=read();assert r['method']=='session/set_config_option' and r['params']['configId']=='model' and r['params']['value']=='chosen'
reply(r,{'configOptions':[{'id':'model','currentValue':'chosen'}]})
r=read();assert r['method']=='session/set_config_option' and r['params']['configId']=='mode' and r['params']['value']=='default'
reply(r,{'configOptions':[{'id':'mode','currentValue':'default'}]})
prompt=read();assert prompt['method']=='session/prompt' and prompt['params']['prompt']==[{'type':'text','text':'fixture prompt'}]
(root/'ready').write_text('ready')
if MODE=='stop':
 r=read();assert r['method']=='session/cancel';reply(prompt,{'stopReason':'cancelled'});sys.stdin.readline();sys.exit(0)
send({'id':'approval','method':'session/request_permission','params':{'sessionId':ID,'toolCall':{'toolCallId':'write-tool','title':'Write file'},'options':[{'optionId':'always','kind':'allow_always'},{'optionId':'once','kind':'allow_once'},{'optionId':'no','kind':'reject_once'}]}})
r=read();assert r['result']['outcome']=={'outcome':'selected','optionId':'once'}
send({'id':'question','method':'session/request_permission','params':{'sessionId':ID,'toolCall':{'toolCallId':'interaction_choose','title':'Choose'},'options':[{'optionId':'one','name':'First','kind':'allow_once'},{'optionId':'two','name':'Second','kind':'allow_once'}]}})
r=read();assert r['result']['outcome']=={'outcome':'selected','optionId':'one'}
send({'id':'file','method':'fs/write_text_file','params':{'sessionId':ID,'path':str(root/'output.txt'),'content':'approved output'}})
assert not (root/'output.txt').exists()
r=read();assert r['id']=='file' and r['result']=={}
send({'id':'read','method':'fs/read_text_file','params':{'sessionId':ID,'path':str(root/'output.txt')}})
r=read();assert r['result']['content']=='approved output'
send({'method':'session/update','params':{'sessionId':ID,'update':{'sessionUpdate':'agent_message_chunk','content':{'text':'NEW ANSWER'}}}})
reply(prompt,{'stopReason':'end_turn'})
sys.stdin.readline()
"#;
fn snapshot(path: &std::path::Path) -> Vec<(String, Vec<u8>)> {
    fn walk(root: &std::path::Path, path: &std::path::Path, out: &mut Vec<(String, Vec<u8>)>) {
        for e in fs::read_dir(path).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                walk(root, &p, out);
            } else {
                out.push((
                    p.strip_prefix(root).unwrap().to_string_lossy().into_owned(),
                    fs::read(p).unwrap(),
                ));
            }
        }
    }
    let mut out = vec![];
    walk(path, path, &mut out);
    out.sort();
    out
}
#[test]
fn antigravity_isolates_profiles_and_runtime_and_preserves_native_protocol() {
    for mode in [
        "new",
        "resume",
        "resume-failed",
        "auth-stdout",
        "auth-stderr",
        "stop",
        "unacknowledged",
        "missing-token",
        "missing-helper",
        "api",
    ] {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let original = root.join("original/antigravity-acp");
        fs::create_dir_all(original.join("conversations")).unwrap();
        fs::create_dir_all(original.join("brain").join(ID)).unwrap();
        if mode != "missing-token" {
            fs::write(original.join("acp_token.json"),json!({"client_id":"fixture-client","client_secret":"fixture-secret","refresh_token":"original-refresh"}).to_string()).unwrap();
        }
        fs::write(
            original.join("conversations").join(format!("{ID}.db")),
            b"native history",
        )
        .unwrap();
        fs::write(
            original.join("conversations").join(format!("{ID}.meta")),
            json!({"cwd":root,"future":true}).to_string(),
        )
        .unwrap();
        fs::write(
            original.join("brain").join(ID).join("artifact.txt"),
            b"preserve artifact",
        )
        .unwrap();
        let executable = root.join("fixture");
        fs::write(
            &executable,
            format!("#!/usr/bin/env python3\nMODE={mode:?}\nID={ID:?}\n{SCRIPT}"),
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        if mode != "missing-helper" {
            fs::write(root.join("localharness_external"), b"#!/bin/sh\nexit 0\n").unwrap();
            fs::set_permissions(
                root.join("localharness_external"),
                fs::Permissions::from_mode(0o700),
            )
            .unwrap();
        }
        fs::write(root.join("configured-unused"), b"#!/bin/sh\nexit 99\n").unwrap();
        fs::set_permissions(
            root.join("configured-unused"),
            fs::Permissions::from_mode(0o700),
        )
        .unwrap();
        let before = snapshot(&root.join("original"));
        let status = Command::new(std::env::current_exe().unwrap())
            .args([
                "--ignored",
                "--exact",
                "antigravity_fixture_child",
                "--nocapture",
            ])
            .current_dir(&root)
            .env("ANTIGRAVITY_FIXTURE_MODE", mode)
            .env("COINCIDE_ANTIGRAVITY_EXECUTABLE", root.join("fixture"))
            .env("GEMINI_API_KEY", "must-not-use-billing")
            .env("GOOGLE_API_KEY", "must-not-use-billing")
            .env("GOOGLE_APPLICATION_CREDENTIALS", "must-not-use-billing")
            .env("AGY_ACP_ENABLE_OAUTH", "must-not-inherit")
            .status()
            .unwrap();
        assert!(status.success(), "{mode}");
        assert_eq!(
            snapshot(&root.join("original")),
            before,
            "source changed in {mode}"
        );
    }
}
#[test]
#[ignore = "isolated subprocess fixture"]
fn antigravity_fixture_child() {
    let Ok(mode) = std::env::var("ANTIGRAVITY_FIXTURE_MODE") else {
        return;
    };
    let root = std::env::current_dir().unwrap();
    if mode == "api" {
        api_fixture(&root);
        return;
    }
    let profile = root.join("private");
    let session = Session::start_with(
        Provider::Antigravity {
            profile: Some(profile.clone()),
            source_profile: Some(root.join("original")),
            risk_acknowledged: mode != "unacknowledged",
        },
        Launch {
            executable: root.join("fixture"),
            cwd: root.clone(),
            session: mode.starts_with("resume").then(|| ID.to_owned()),
            prompt: "fixture prompt".into(),
            model: Some("chosen".into()),
            variant: None,
            full_access: false,
        },
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut text = String::new();
    let mut finished = false;
    let mut stopped = false;
    let mut failed = false;
    loop {
        assert!(
            Instant::now() < deadline,
            "Antigravity fixture timed out: {mode}"
        );
        if mode == "stop" && root.join("ready").exists() && !stopped {
            session.stop();
            stopped = true;
        }
        match session.events.recv_timeout(Duration::from_millis(20)) {
            Ok(Event::Frame(frame)) => {
                assert!(!frame.to_string().contains("secret-must-not-leak"));
                match frame["method"].as_str() {
                    Some("item/commandExecution/requestApproval") => {
                        if frame["id"] == "file" {
                            assert!(!root.join("output.txt").exists());
                        }
                        session
                            .reply(frame["id"].clone(), json!({"decision":"accept"}))
                            .unwrap();
                    }
                    Some("item/tool/requestUserInput") => session
                        .reply(
                            frame["id"].clone(),
                            json!({"answers":{"interaction_choose":{"answers":["First"]}}}),
                        )
                        .unwrap(),
                    Some("item/agentMessage/delta") => {
                        text.push_str(frame["params"]["delta"].as_str().unwrap())
                    }
                    _ => {}
                }
            }
            Ok(Event::Session(id)) => assert_eq!(id, ID),
            Ok(Event::Finished) => {
                assert_completed_cleanup(&root, &profile);
                finished = true;
                break;
            }
            Ok(Event::Failed(error)) => {
                assert_completed_cleanup(&root, &profile);
                assert!(!error.contains("secret-must-not-leak"));
                failed = true;
                break;
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(error) => panic!("{error}"),
        }
    }
    let success = matches!(mode.as_str(), "new" | "resume" | "stop");
    assert_eq!(finished, success, "{mode}");
    assert_eq!(failed, !success, "{mode}");
    assert!(!text.contains("OLD REPLAY"));
    if matches!(mode.as_str(), "new" | "resume") {
        assert_eq!(text, "NEW ANSWER");
    }
    if mode == "unacknowledged" {
        assert!(!profile.exists());
    }
    drop(session);
    if let Ok(pid) = fs::read_to_string(root.join("pid")) {
        let pid = pid.parse::<i32>().unwrap();
        let until = Instant::now() + Duration::from_secs(3);
        while unsafe { libc::kill(pid, 0) } == 0 && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_ne!(unsafe { libc::kill(pid, 0) }, 0, "child was not reaped");
    }
    if profile.join("runtime").exists() {
        assert!(
            !fs::read_dir(profile.join("runtime"))
                .unwrap()
                .any(|entry| entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with("extract-"))
        );
    }
}

// A terminal event promises completed teardown, not merely a queued teardown.
// Check before dropping Session or polling/waiting, so this catches the original
// Finished-before-Profile-drop race and proves immediate profile reuse is safe.
fn assert_completed_cleanup(root: &std::path::Path, profile: &std::path::Path) {
    if let Ok(lock) = fs::File::open(profile.join(".lock")) {
        use std::os::fd::AsRawFd;
        assert_eq!(
            unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0,
            "terminal event preceded profile lock release"
        );
    }
    if let Ok(pid) = fs::read_to_string(root.join("pid")) {
        let pid = pid.parse::<i32>().unwrap();
        assert_ne!(
            unsafe { libc::kill(pid, 0) },
            0,
            "terminal event preceded child reap"
        );
    }
    if let Ok(mut entries) = fs::read_dir(profile.join("runtime")) {
        assert!(
            !entries.any(|entry| entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with("extract-")),
            "terminal event preceded extraction cleanup"
        );
    }
}

fn api_call(engine: &mut Engine, method: &str, params: serde_json::Value) -> serde_json::Value {
    let result = engine.dispatch(json!({"method":method,"params":params}));
    assert!(result.get("error").is_none(), "{method}: {result}");
    result["result"].clone()
}
fn api_fixture(root: &std::path::Path) {
    let database = root.join("data/store.sqlite");
    let mut engine = Engine::new(Store::open(&database).unwrap());
    let id = api_call(&mut engine, "threads.create", json!({"cwd":root}))["id"]
        .as_str()
        .unwrap()
        .to_owned();
    api_call(
        &mut engine,
        "providers.antigravity.configure",
        json!({"auth":"login","executable":root.join("configured-unused"),"sourceProfile":root.join("original")}),
    );
    assert!(
        engine
            .dispatch(
                json!({"method":"agent.select","params":{"threadId":id,"provider":"antigravity"}})
            )
            .get("error")
            .is_some()
    );
    api_call(
        &mut engine,
        "providers.antigravity.acknowledge",
        json!({"key":"provider:antigravity-account-risk","accepted":true}),
    );
    api_call(
        &mut engine,
        "agent.select",
        json!({"threadId":id,"provider":"antigravity","model":"chosen"}),
    );
    api_call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"fixture prompt"}),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        assert!(
            Instant::now() < deadline,
            "Antigravity engine turn timed out"
        );
        let pending = api_call(&mut engine, "agent.pending", json!({"threadId":id}));
        for request in pending.as_array().unwrap() {
            if request["method"] == "item/tool/requestUserInput" {
                api_call(
                    &mut engine,
                    "agent.answer",
                    json!({"threadId":id,"requestId":request["requestId"],"answers":{"interaction_choose":{"answers":["First"]}}}),
                );
            } else {
                api_call(
                    &mut engine,
                    "agent.respond",
                    json!({"threadId":id,"requestId":request["requestId"],"decision":"accept"}),
                );
            }
        }
        if api_call(&mut engine, "app.status", json!({}))["running"]
            .as_array()
            .unwrap()
            .is_empty()
        {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let value = engine.store.thread(&id).unwrap();
    assert_eq!(
        coincide_core::agent::provider_session(&value, "antigravity").as_deref(),
        Some(ID)
    );
    assert!(
        value["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["kind"] == "assistant" && item["text"] == "NEW ANSWER"),
        "{value}"
    );
    assert!(
        engine
            .store
            .data_directory()
            .unwrap()
            .join("providers/antigravity/default/threads")
            .join(&id)
            .join("antigravity-acp/acp_token.json")
            .is_file()
    );
    assert_eq!(
        fs::read_to_string(root.join("output.txt")).unwrap(),
        "approved output"
    );
    drop(engine);
    let mut reopened = Engine::new(Store::open(&database).unwrap());
    assert_eq!(
        api_call(&mut reopened, "providers.antigravity.status", json!({}))["riskAcknowledged"],
        true
    );
}
