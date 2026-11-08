//! Synthetic provider executables only: no accounts, vaults, network or global config.
#![cfg(unix)]
use coincide_core::agent::{Event, Launch, MAX_INSTRUCTIONS_BYTES, Provider, Session};
use serde_json::Value;
use std::{fs, os::unix::fs::PermissionsExt, path::Path, time::Duration};

const INSTRUCTIONS: &str = "Bot-local instructions\nKeep literal: \"quotes\", 'apostrophe', $(touch shell-side-effect), `touch backtick-side-effect`; --model unsafe\n界";
fn fixture(source: &str) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let exe = dir.path().join("fixture");
    fs::write(&exe,format!("#!/usr/bin/env python3\nimport json,sys,os\ndef read():\n return json.loads(sys.stdin.readline())\ndef write(value):\n print(json.dumps(value),flush=True)\n{source}")).unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(
        dir.path().join("AGENTS.md"),
        "unchanged fixture project instructions",
    )
    .unwrap();
    dir
}
fn launch(root: &Path, session: Option<&str>) -> Launch {
    Launch {
        executable: root.join("fixture"),
        cwd: root.into(),
        session: session.map(str::to_owned),
        prompt: "fixture user prompt".into(),
        model: Some("fixture-model".into()),
        variant: None,
    }
}
fn settle(session: &Session) -> Result<Vec<String>, String> {
    let mut sessions = Vec::new();
    loop {
        match session
            .events
            .recv_timeout(Duration::from_secs(5))
            .expect("synthetic provider timed out")
        {
            Event::Session(id) => sessions.push(id),
            Event::Finished => return Ok(sessions),
            Event::Failed(error) => return Err(error),
            Event::Frame(_) => {}
        }
    }
}
fn assert_no_side_effects(root: &Path) {
    assert!(!root.join("shell-side-effect").exists());
    assert!(!root.join("backtick-side-effect").exists());
    assert_eq!(
        fs::read_to_string(root.join("AGENTS.md")).unwrap(),
        "unchanged fixture project instructions"
    );
}
const CODEX: &str = r#"
with open('launches','a') as log: log.write('launch\n')
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read();p=r['params']
expected=json.load(open('expected.json'))
if expected is None: assert 'developerInstructions' not in p
else: assert p['developerInstructions']==expected
assert p['model']=='fixture-model' and p['approvalPolicy']=='untrusted' and p['sandbox']=='read-only'
assert r['method'] in ['thread/start','thread/resume']
if r['method']=='thread/resume': assert p['threadId']=='fixture-session' and p['excludeTurns'] is True
with open('thread-methods','a') as log: log.write(r['method']+'\n')
write({'id':r['id'],'result':{'thread':{'id':'fixture-session'}}})
r=read();assert r['method']=='turn/start';p=r['params']
assert p['model']=='fixture-model' and p['approvalPolicy']=='untrusted' and p['sandboxPolicy']=={'type':'readOnly'}
assert p['input'][0]['text']=='fixture user prompt'
write({'id':r['id'],'result':{'turn':{'id':'turn'}}})
write({'method':'turn/completed','params':{'threadId':'fixture-session','turn':{'id':'turn','status':'completed'}}})
sys.stdin.readline()
"#;
#[test]
fn codex_start_resume_and_repeated_resume_preserve_instruction_snapshot_and_defaults() {
    let dir = fixture(CODEX);
    fs::write(
        dir.path().join("expected.json"),
        serde_json::to_vec(INSTRUCTIONS).unwrap(),
    )
    .unwrap();
    for resume in [None, Some("fixture-session"), Some("fixture-session")] {
        let session = Session::start_with_images_and_instructions(
            Provider::Codex,
            launch(dir.path(), resume),
            vec![],
            Some(INSTRUCTIONS.into()),
        );
        assert_eq!(settle(&session).unwrap(), vec!["fixture-session"]);
    }
    // Legacy entry must preserve ordinary thread behavior and omit the key.
    fs::write(dir.path().join("expected.json"), b"null").unwrap();
    let ordinary = Session::start_with_images(Provider::Codex, launch(dir.path(), None), vec![]);
    settle(&ordinary).unwrap();
    assert_eq!(
        fs::read_to_string(dir.path().join("thread-methods")).unwrap(),
        "thread/start\nthread/resume\nthread/resume\nthread/start\n"
    );
    assert_no_side_effects(dir.path());
}
const CLAUDE: &str = r#"
args=sys.argv[1:]
with open('launches','a') as log: log.write(json.dumps(args)+'\n')
expected=json.load(open('expected.json'))
if expected is None: assert '--append-system-prompt' not in args
else:
 assert args.count('--append-system-prompt')==1
 assert args[args.index('--append-system-prompt')+1]==expected
assert args[args.index('--model')+1]=='fixture-model'
assert args[args.index('--permission-mode')+1]=='default'
assert '--dangerously-skip-permissions' not in args
assert '--setting-sources=user,project,local' in args
flag='--resume' if '--resume' in args else '--session-id'
session=args[args.index(flag)+1]
with open('session-modes','a') as log: log.write(flag+'\n')
r=read();assert r['type']=='control_request'
write({'type':'control_response','response':{'subtype':'success','request_id':r['request_id']}})
r=read();assert r['type']=='user' and r['message']['content']=='fixture user prompt'
write({'type':'system','subtype':'init','session_id':session})
write({'type':'assistant','session_id':session,'message':{'id':'reply','content':[{'type':'text','text':'Synthetic response'}]}})
write({'type':'result','subtype':'success','session_id':session,'result':'Synthetic response','is_error':False})
sys.stdin.readline()
"#;
#[test]
fn claude_fresh_resume_repeated_launch_each_receive_one_literal_append_argument() {
    let dir = fixture(CLAUDE);
    fs::write(
        dir.path().join("expected.json"),
        serde_json::to_vec(INSTRUCTIONS).unwrap(),
    )
    .unwrap();
    let fresh = Session::start_with_images_and_instructions(
        Provider::Claude,
        launch(dir.path(), None),
        vec![],
        Some(INSTRUCTIONS.into()),
    );
    let id = settle(&fresh).unwrap().pop().unwrap();
    for _ in 0..2 {
        let session = Session::start_with_images_and_instructions(
            Provider::Claude,
            launch(dir.path(), Some(&id)),
            vec![],
            Some(INSTRUCTIONS.into()),
        );
        assert_eq!(settle(&session).unwrap(), vec![id.clone()]);
    }
    fs::write(dir.path().join("expected.json"), b"null").unwrap();
    settle(&Session::start_with_images(
        Provider::Claude,
        launch(dir.path(), None),
        vec![],
    ))
    .unwrap();
    assert_eq!(
        fs::read_to_string(dir.path().join("session-modes")).unwrap(),
        "--session-id\n--resume\n--resume\n--session-id\n"
    );
    let logs = fs::read_to_string(dir.path().join("launches")).unwrap();
    let first: Value = serde_json::from_str(logs.lines().next().unwrap()).unwrap();
    assert!(
        first
            .as_array()
            .unwrap()
            .iter()
            .any(|arg| arg.as_str() == Some(INSTRUCTIONS))
    );
    assert_no_side_effects(dir.path());
}
#[test]
fn unsupported_providers_and_invalid_instructions_fail_before_any_process_or_profile_side_effect() {
    let dir = fixture("open('spawned','w').write('unexpected')");
    for provider in [
        Provider::Grok,
        Provider::OpenCode,
        Provider::Cursor {
            profile: Some(dir.path().join("cursor-profile")),
        },
        Provider::Antigravity {
            profile: Some(dir.path().join("antigravity-profile")),
            source_profile: None,
            risk_acknowledged: true,
        },
        Provider::AcpV1 {
            arguments: vec!["synthetic".into()],
        },
    ] {
        let session = Session::start_with_images_and_instructions(
            provider,
            launch(dir.path(), None),
            vec![],
            Some(INSTRUCTIONS.into()),
        );
        assert!(settle(&session).unwrap_err().contains("unsupported"));
    }
    for provider in [Provider::Codex, Provider::Claude] {
        for content in [
            "".into(),
            " \n\t".into(),
            "invalid\0content".into(),
            "界".repeat(MAX_INSTRUCTIONS_BYTES / 3 + 1),
        ] {
            let session = Session::start_with_images_and_instructions(
                provider.clone(),
                launch(dir.path(), None),
                vec![],
                Some(content),
            );
            assert!(settle(&session).is_err());
        }
    }
    for path in ["spawned", "cursor-profile", "antigravity-profile"] {
        assert!(!dir.path().join(path).exists());
    }
    assert_no_side_effects(dir.path());
}
#[test]
fn instruction_limit_accepts_exact_boundary_through_real_codex_transport() {
    let dir = fixture(CODEX);
    let instructions = "x".repeat(MAX_INSTRUCTIONS_BYTES);
    fs::write(
        dir.path().join("expected.json"),
        serde_json::to_vec(&instructions).unwrap(),
    )
    .unwrap();
    let session = Session::start_with_images_and_instructions(
        Provider::Codex,
        launch(dir.path(), None),
        vec![],
        Some(instructions),
    );
    settle(&session).unwrap();
}
#[test]
fn provider_rejection_never_relaunches_without_instructions_or_falls_back_to_new_session() {
    for provider in [Provider::Codex, Provider::Claude] {
        let dir = fixture(
            r#"
with open('launches','a') as log: log.write('launch\n')
if sys.argv[1:]==['app-server']:
 r=read();write({'id':r['id'],'result':{}})
 assert read()['method']=='initialized'
 r=read();assert r['method']=='thread/resume' and r['params']['developerInstructions']==json.load(open('expected.json'))
 write({'id':r['id'],'error':{'message':'Synthetic instructions rejected'}})
 sys.stdin.readline()
else:
 assert '--append-system-prompt' in sys.argv
 assert sys.argv[sys.argv.index('--append-system-prompt')+1]==json.load(open('expected.json'))
 assert '--resume' in sys.argv
 sys.exit(3)
"#,
        );
        fs::write(
            dir.path().join("expected.json"),
            serde_json::to_vec(INSTRUCTIONS).unwrap(),
        )
        .unwrap();
        let resume = if matches!(provider, Provider::Claude) {
            "00000000-0000-4000-8000-000000000001"
        } else {
            "fixture-session"
        };
        let session = Session::start_with_images_and_instructions(
            provider,
            launch(dir.path(), Some(resume)),
            vec![],
            Some(INSTRUCTIONS.into()),
        );
        assert!(settle(&session).is_err());
        assert_eq!(
            fs::read_to_string(dir.path().join("launches")).unwrap(),
            "launch\n"
        );
        assert_no_side_effects(dir.path());
    }
}
