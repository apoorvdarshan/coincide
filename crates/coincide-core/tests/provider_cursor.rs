//! Cursor fixtures run in an isolated test subprocess so no environment changes
//! affect other tests or access the user's real Cursor account/configuration.
#![cfg(unix)]
use coincide_core::agent::{Event, Launch, Provider, Session};
use coincide_core::{api::Engine, store::Store};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    process::Command,
    time::{Duration, Instant},
};
const SCRIPT: &str = r#"
import json,os,sys,time
from pathlib import Path
read=lambda:json.loads(sys.stdin.readline())
def send(value):print(json.dumps(value),flush=True)
def reply(request,value):send({'jsonrpc':'2.0','id':request['id'],'result':value})
profile=Path(os.environ['CURSOR_CONFIG_DIR']);original=Path('original').resolve()
assert profile.resolve()!=original
open('profile-used','w').write(str(profile))
assert os.environ['AGENT_CLI_CREDENTIAL_STORE']=='memory'
assert os.environ['CURSOR_AUTH_TOKEN']=='synthetic-token-not-a-real-credential'
assert os.environ['CURSOR_DATA_DIR']==str(profile/'artifacts')
assert os.environ['DIRENV_DISABLE']=='1'
target='user-default' if MODE.startswith('inherited-model') else 'chosen-model'
assert sys.argv[1:]==['--disable-project-configs','--model',target,'acp']
config=json.loads((profile/'cli-config.json').read_text());assert config['approvalMode']=='allowlist'
assert config['permissions']['allow']==[]
config['selectedModel']={'modelId':'CLI changed its model default'}
(profile/'cli-config.json').write_text(json.dumps(config))
open('pid','w').write(str(os.getpid()))
r=read();assert r['method']=='initialize'
assert r['params']['clientCapabilities']=={'fs':{'readTextFile':False,'writeTextFile':False},'terminal':False,'_meta':{'parameterizedModelPicker':True}}
parameterized=r['params']['clientCapabilities']['_meta']['parameterizedModelPicker']
reply(r,{'protocolVersion':1,'agentCapabilities':{'loadSession':True,'promptCapabilities':{'image':True}}})
r=read();assert r['method']==('session/load' if RESUME else 'session/new')
if RESUME:
 assert r['params']['sessionId']=='native'
 import sqlite3
 db=sqlite3.connect(profile/'acp-sessions/native/store.db');metadata=json.loads(bytes.fromhex(db.execute("SELECT value FROM meta WHERE key='0'").fetchone()[0]))
 assert metadata['agentId']=='native' and metadata['isRunEverything']==False
 assert metadata['future']=={'keep':True}
 assert db.execute('SELECT data FROM blobs').fetchone()[0]==b'history'
 db.close()
 send({'method':'session/update','params':{'sessionId':'native','update':{'sessionUpdate':'agent_message_chunk','content':{'text':'OLD REPLAY'}}}})
 if MODE=='resume-failed':send({'id':r['id'],'error':{'code':-32602,'message':'cannot load'}});sys.stdin.readline();sys.exit(0)
if MODE.startswith('inherited-model'):
 # Match installed Cursor: parameterized mode exposes base IDs; its default
 # variant picker exposes distinct opaque variant IDs instead.
 advertised='other-base' if MODE=='inherited-model-unavailable' else ('user-default' if parameterized else 'opaque-variant')
 reply(r,{'sessionId':'native','models':{'currentModelId':advertised,'availableModels':[{'modelId':advertised}]},'configOptions':[{'id':'model','category':'model','currentValue':advertised,'options':[{'value':advertised}]}]})
 if MODE=='inherited-model-unavailable':
  if sys.stdin.readline():open('unexpected-after-unavailable','w').write('request')
  sys.exit(0)
 r=read();assert r['method']=='session/set_mode' and r['params']['modeId']=='agent';reply(r,{})
 r=read();assert r['method']=='session/prompt' and r['params']['prompt']==[{'type':'text','text':'fixture prompt'}]
 open('prompt-ready','w').write('ready')
 send({'method':'session/update','params':{'sessionId':'native','update':{'sessionUpdate':'agent_message_chunk','content':{'text':'NEW ANSWER'}}}})
 reply(r,{'stopReason':'end_turn'});sys.stdin.readline();sys.exit(0)
reply(r,{'sessionId':'native','models':{'currentModelId':'old-model','availableModels':[{'modelId':'chosen-model'}]}})
r=read();assert r['method']=='session/set_config_option' and r['params']['value']=='chosen-model'
if MODE=='model-unconfirmed':reply(r,{});sys.stdin.readline();sys.exit(0)
reply(r,{'configOptions':[{'id':'model','currentValue':'chosen-model','options':[{'value':'chosen-model'}]}]})
r=read();assert r['method']=='session/set_mode' and r['params']['modeId']=='agent';reply(r,{})
r=read();assert r['method']=='session/prompt';prompt=r
assert r['params']['prompt']==[{'type':'text','text':'fixture prompt'}]
open('prompt-ready','w').write('ready')
if MODE=='stop':
 r=read();assert r['method']=='session/cancel';reply(prompt,{'stopReason':'cancelled'});sys.stdin.readline();sys.exit(0)
if MODE=='provider-error':
 send({'method':'session/update','params':{'sessionId':'native','update':{'sessionUpdate':'agent_message_chunk','content':{'text':'\n\nError: ConnectError: [unavailable] fixture failure'}}}})
 reply(prompt,{'stopReason':'end_turn'});sys.stdin.readline();sys.exit(0)
if MODE=='api':
 send({'method':'session/update','params':{'sessionId':'native','update':{'sessionUpdate':'agent_message_chunk','content':{'text':'NEW ANSWER'}}}})
 reply(prompt,{'stopReason':'end_turn'});sys.stdin.readline();sys.exit(0)
send({'id':'approval','method':'session/request_permission','params':{'sessionId':'native','options':[{'optionId':'always','kind':'allow_always'},{'optionId':'once','kind':'allow_once'},{'optionId':'no','kind':'reject_once'}],'toolCall':{'title':'Fixture operation'}}})
r=read();assert r['id']=='approval' and r['result']['outcome']=={'outcome':'selected','optionId':'once'}
send({'id':'question','method':'cursor/ask_question','params':{'sessionId':'native','questions':[{'id':'q','prompt':'Choose','options':[{'id':'a','label':'First'}]}]}})
r=read();assert r['id']=='question' and r['result']=={'outcome':{'outcome':'answered','answers':[{'questionId':'q','selectedOptionIds':['a']}]}}
send({'id':'withdrawn','method':'cursor/ask_question','params':{'sessionId':'native','questions':[{'id':'q','prompt':'Withdrawn','options':[]}]}})
send({'method':'$/cancel_request','params':{'requestId':'withdrawn'}})
r=read();assert r['id']=='withdrawn' and r['error']['code']==-32800
send({'method':'session/update','params':{'sessionId':'native','update':{'sessionUpdate':'agent_message_chunk','content':{'text':'NEW ANSWER'}}}})
reply(prompt,{'stopReason':'end_turn'})
sys.stdin.readline()
"#;
fn native_database(root: &std::path::Path) {
    let dir = root.join("original/acp-sessions/native");
    fs::create_dir_all(&dir).unwrap();
    let db = rusqlite::Connection::open(dir.join("store.db")).unwrap();
    db.execute_batch("PRAGMA user_version=1;CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT);CREATE TABLE blobs(id TEXT PRIMARY KEY,data BLOB);").unwrap();
    let metadata =
        json!({"agentId":"native","isRunEverything":true,"mode":"auto-run","future":{"keep":true}})
            .to_string()
            .as_bytes()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
    db.execute("INSERT INTO meta VALUES('0',?1)", [metadata])
        .unwrap();
    db.execute(
        "INSERT INTO blobs VALUES('history',?1)",
        [b"history".as_slice()],
    )
    .unwrap();
}
#[test]
fn cursor_private_profiles_resume_approve_ask_cancel_without_global_writes() {
    for mode in [
        "new",
        "resume",
        "resume-failed",
        "provider-error",
        "stop",
        "no-auth",
        "api",
        "model-unconfirmed",
        "inherited-model-base",
        "inherited-model-unavailable",
    ] {
        let dir = tempfile::tempdir().unwrap();
        native_database(dir.path());
        let config=br#"{"selectedModel":{"modelId":"user-default"},"approvalMode":"unrestricted","permissions":{"allow":["Shell(*)"]},"keep":true}"#;
        fs::write(dir.path().join("original/cli-config.json"), config).unwrap();
        let original_db =
            fs::read(dir.path().join("original/acp-sessions/native/store.db")).unwrap();
        let fixture = dir.path().join("fixture");
        fs::write(
            &fixture,
            format!(
                "#!/usr/bin/env python3\nMODE={mode:?}\nRESUME={}\n{SCRIPT}",
                if mode.starts_with("resume") {
                    "True"
                } else {
                    "False"
                }
            ),
        )
        .unwrap();
        fs::set_permissions(&fixture, fs::Permissions::from_mode(0o700)).unwrap();
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--ignored",
                "--exact",
                "cursor_fixture_child",
                "--nocapture",
            ])
            .env("CURSOR_FIXTURE_DIRECTORY", dir.path())
            .env("CURSOR_FIXTURE_MODE", mode)
            // Never let the no-auth fixture read the real default Keychain.
            .env("AGENT_CLI_CREDENTIAL_STORE", "memory")
            .env("CURSOR_CONFIG_DIR", dir.path().join("original"))
            .env("COINCIDE_CURSOR_EXECUTABLE", &fixture)
            .env_remove("CURSOR_API_KEY")
            .env_remove("CURSOR_AUTH_TOKEN");
        if mode != "no-auth" {
            command.env("CURSOR_AUTH_TOKEN", "synthetic-token-not-a-real-credential");
        }
        let result = command.output().unwrap();
        assert!(
            result.status.success(),
            "{mode}: {}\n{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
        assert_eq!(
            fs::read(dir.path().join("original/cli-config.json")).unwrap(),
            config
        );
        assert_eq!(
            fs::read(dir.path().join("original/acp-sessions/native/store.db")).unwrap(),
            original_db
        );
        #[cfg(unix)]
        if !matches!(mode, "no-auth" | "api") {
            assert_eq!(
                fs::metadata(dir.path().join("private"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o700
            );
        }
    }
}
#[test]
#[ignore = "invoked by isolated parent fixture"]
fn cursor_fixture_child() {
    let Some(directory) = std::env::var_os("CURSOR_FIXTURE_DIRECTORY") else {
        return;
    };
    let directory = std::path::PathBuf::from(directory);
    let mode = std::env::var("CURSOR_FIXTURE_MODE").unwrap();
    if mode == "api" {
        api_fixture(&directory);
        return;
    }
    let session = Session::start_with(
        Provider::Cursor {
            profile: Some(directory.join("private")),
        },
        Launch {
            executable: directory.join("fixture"),
            cwd: directory.clone(),
            session: mode.starts_with("resume").then(|| "native".into()),
            model: (!mode.starts_with("inherited-model")).then(|| "chosen-model".into()),
            prompt: "fixture prompt".into(),
        },
    );
    if mode == "stop" {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !directory.join("prompt-ready").exists() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        session.stop();
    }
    let mut text = String::new();
    let mut settled = false;
    let mut native = false;
    loop {
        match session.events.recv_timeout(Duration::from_secs(8)).unwrap() {
            Event::Session(id) => {
                assert_eq!(id, "native");
                native = true;
            }
            Event::Frame(frame) => match frame["method"].as_str() {
                Some("item/commandExecution/requestApproval") => session
                    .reply(frame["id"].clone(), json!({"decision":"accept"}))
                    .unwrap(),
                Some("item/tool/requestUserInput") if frame["id"] == "question" => session
                    .reply(
                        frame["id"].clone(),
                        json!({"answers":{"q":{"answers":["First"]}}}),
                    )
                    .unwrap(),
                Some("provider/requestCancelled") => {
                    assert_eq!(frame["params"]["id"], "withdrawn");
                    settled = true;
                }
                Some("item/agentMessage/delta") => {
                    text.push_str(frame["params"]["delta"].as_str().unwrap())
                }
                _ => {}
            },
            Event::Finished => {
                assert!(matches!(
                    mode.as_str(),
                    "new" | "resume" | "stop" | "inherited-model-base"
                ));
                break;
            }
            Event::Failed(error) => {
                match mode.as_str() {
                    "resume-failed" => {
                        assert!(error.contains("cannot load"));
                        assert!(!native);
                    }
                    "provider-error" => assert!(error.contains("fixture failure")),
                    "no-auth" => assert!(error.contains("CURSOR_AUTH_TOKEN")),
                    "inherited-model-unavailable" => {
                        assert!(native);
                        assert!(error.contains("did not confirm or advertise the requested model"));
                        assert!(!directory.join("prompt-ready").exists());
                        assert!(!directory.join("unexpected-after-unavailable").exists());
                    }
                    "model-unconfirmed" => {
                        assert!(error.contains("did not apply the selected model"))
                    }
                    _ => panic!("{error}"),
                };
                break;
            }
        }
    }
    if matches!(mode.as_str(), "new" | "resume") {
        assert_eq!(text, "NEW ANSWER");
        assert!(settled && native);
    }
    if mode == "inherited-model-base" {
        assert!(native && directory.join("prompt-ready").exists());
        assert_eq!(text, "NEW ANSWER");
    }
    if mode == "no-auth" {
        assert!(!directory.join("pid").exists());
        return;
    }
    let pid = fs::read_to_string(directory.join("pid"))
        .unwrap()
        .parse::<i32>()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(Instant::now() < deadline, "Cursor child was not reaped");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn call(engine: &mut Engine, method: &str, params: Value) -> Value {
    let result = engine.dispatch(json!({"method":method,"params":params}));
    assert!(result.get("error").is_none(), "{method}: {result}");
    result["result"].clone()
}
fn api_fixture(directory: &std::path::Path) {
    let mut engine = Engine::new(Store::open(&directory.join("data/fixture.sqlite")).unwrap());
    let thread = call(&mut engine, "threads.create", json!({"cwd":directory}));
    let id = thread["id"].as_str().unwrap();
    call(
        &mut engine,
        "agent.select",
        json!({"threadId":id,"provider":"cursor","model":"chosen-model"}),
    );
    call(
        &mut engine,
        "agent.send",
        json!({"threadId":id,"text":"fixture prompt"}),
    );
    let deadline = Instant::now() + Duration::from_secs(8);
    while !call(&mut engine, "app.status", json!({}))["running"]
        .as_array()
        .unwrap()
        .is_empty()
    {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    let thread = engine.store.thread(id).unwrap();
    assert!(
        thread["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["kind"] == "assistant" && item["text"] == "NEW ANSWER"),
        "{thread}"
    );
    assert_eq!(
        coincide_core::agent::provider_session(&thread, "cursor").as_deref(),
        Some("native")
    );
    let actual = fs::read_to_string(directory.join("profile-used")).unwrap();
    let expected = engine
        .store
        .data_directory()
        .unwrap()
        .join("providers/cursor")
        .join(id)
        .canonicalize()
        .unwrap();
    assert_eq!(std::path::PathBuf::from(actual), expected);
    assert_eq!(
        fs::metadata(expected).unwrap().permissions().mode() & 0o777,
        0o700
    );
}
