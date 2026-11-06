//! Attachment protocol fixtures. File validation/normalization is exercised by
//! the attachment store's tests; these verify exact provider bytes and ordering.
#![cfg(unix)]
use base64::{Engine as _, engine::general_purpose::STANDARD};
use coincide_core::agent::{Event, ImageAttachment, Launch, Provider, Session, validate_images};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    time::{Duration, Instant},
};

fn png() -> Vec<u8> {
    STANDARD.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=").unwrap()
}

fn prepared(path: &std::path::Path, bytes: &[u8]) -> ImageAttachment {
    fs::write(path, bytes).unwrap();
    ImageAttachment::new(path.into(), "image/png".into(), bytes.to_vec()).unwrap()
}

const SCRIPT: &str = r#"#!/usr/bin/env python3
import base64,json,sys,os,pathlib
def read(): return json.loads(sys.stdin.readline())
def write(value): print(json.dumps(value),flush=True)
def complete(value):
 open('verified','w').write('yes')
 write(value)
def verify(blocks,claude=False):
 for i,block in enumerate(blocks):
  assert block['type']=='image'
  source=block['source'] if claude else block
  assert source['media_type' if claude else 'mimeType']=='image/png'
  if claude: assert source['type']=='base64'
  assert base64.b64decode(source['data'])==open('image '+str(i)+'.png','rb').read()
expected=open('expected-text').read()
if sys.argv[1:]==['app-server']:
 r=read();write({'id':r['id'],'result':{}})
 assert read()['method']=='initialized'
 r=read();write({'id':r['id'],'result':{'thread':{'id':'image-codex'}}})
 r=read();assert r['method']=='turn/start'
 blocks=r['params']['input']
 if expected:
  assert blocks[0]['type']=='text' and blocks[0]['text']==expected
  blocks=blocks[1:]
 assert len(blocks)==2
 for i,block in enumerate(blocks):
  assert set(block)=={'type','path'} and block['type']=='localImage'
  # macOS temporary paths may start with /var while cwd resolves /private/var.
  # Both must designate exactly this fixture image, not an unrelated path.
  assert pathlib.Path(block['path']).resolve()==pathlib.Path('image '+str(i)+'.png').resolve()
 write({'id':r['id'],'result':{'turn':{'id':'image-turn'}}})
 complete({'method':'turn/completed','params':{'threadId':'image-codex','turn':{'id':'image-turn','status':'completed'}}})
elif '--input-format' in sys.argv:
 r=read();write({'type':'control_response','response':{'subtype':'success','request_id':r['request_id']}})
 r=read();assert r['type']=='user'
 blocks=r['message']['content'];assert isinstance(blocks,list)
 if expected:
  assert blocks[-1]=={'type':'text','text':expected}
  blocks=blocks[:-1]
 assert len(blocks)==2
 verify(blocks,True)
 # Some agent versions echo image-bearing user frames. Large valid echoes must
 # not trip a smaller inbound transport limit or become assistant replies.
 write({'type':'user','message':{'role':'user','content':blocks}})
 complete({'type':'result','subtype':'success','is_error':False,'result':'image fixture complete'})
else:
 r=read();write({'id':r['id'],'result':{'protocolVersion':1,'agentCapabilities':{'promptCapabilities':{'image':True}}}})
 r=read();write({'id':r['id'],'result':{'sessionId':'image-acp'}})
 r=read();assert r['method']=='session/prompt'
 blocks=r['params']['prompt']
 if expected:
  assert blocks[0]=={'type':'text','text':expected}
  blocks=blocks[1:]
 assert len(blocks)==2
 verify(blocks)
 complete({'id':r['id'],'result':{'stopReason':'end_turn'}})
sys.stdin.readline()
"#;

fn launch(
    source: &str,
    provider: Provider,
    prompt: &str,
    bytes: &[u8],
) -> (tempfile::TempDir, Session) {
    let directory = tempfile::tempdir().unwrap();
    fs::write(directory.path().join("expected-text"), prompt).unwrap();
    let images = (0..2)
        .map(|index| prepared(&directory.path().join(format!("image {index}.png")), bytes))
        .collect();
    let executable = directory.path().join("fixture");
    fs::write(&executable, source).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let session = Session::start_with_images(
        provider,
        Launch {
            executable,
            cwd: directory.path().into(),
            session: None,
            prompt: prompt.into(),
            model: None,
        },
        images,
    );
    (directory, session)
}

fn completed(session: &Session) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "image fixture timed out");
        match session.events.recv_timeout(remaining).unwrap() {
            Event::Finished => return,
            Event::Failed(message) => panic!("{message}"),
            _ => {}
        }
    }
}

#[test]
fn providers_send_exact_images_with_text_and_image_only_turns() {
    for prompt in ["/inspect fixture", ""] {
        for provider in [
            Provider::Codex,
            Provider::Claude,
            Provider::AcpV1 {
                arguments: vec!["fixture-acp".into()],
            },
        ] {
            let (directory, session) = launch(SCRIPT, provider, prompt, &png());
            completed(&session);
            assert_eq!(
                fs::read_to_string(directory.path().join("verified")).unwrap(),
                "yes"
            );
        }
    }
}

#[test]
fn claude_two_large_images_fit_the_bounded_transport() {
    let mut bytes = png();
    bytes.resize(3_750_000, 0); // Synthetic large byte snapshot for pipe capacity, not a decode test.
    let (directory, session) = launch(SCRIPT, Provider::Claude, "two large images", &bytes);
    completed(&session);
    assert_eq!(
        fs::read_to_string(directory.path().join("verified")).unwrap(),
        "yes"
    );
}

#[test]
fn acp_without_advertised_image_support_fails_before_creating_session_or_prompt() {
    let script = r#"#!/usr/bin/env python3
import json,sys
r=json.loads(sys.stdin.readline())
print(json.dumps({'id':r['id'],'result':{'protocolVersion':1,'agentCapabilities':{}}}),flush=True)
if sys.stdin.readline(): open('unexpected-request','w').write('sent')
"#;
    let (directory, session) = launch(
        script,
        Provider::AcpV1 { arguments: vec![] },
        "inspect images",
        &png(),
    );
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Failed(message) => {
                assert!(message.contains("does not advertise image prompt support"));
                break;
            }
            Event::Finished | Event::Session(_) => {
                panic!("unsupported images must not start a session or finish successfully")
            }
            _ => {}
        }
    }
    assert!(!directory.path().join("unexpected-request").exists());
}

#[test]
fn prepared_images_reject_wrong_mime_missing_files_and_mismatched_snapshots() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("image.png");
    let bytes = png();
    fs::write(&path, &bytes).unwrap();
    assert!(ImageAttachment::new(path.clone(), "image/jpeg".into(), bytes.clone()).is_err());
    let mut different = bytes.clone();
    different[20] ^= 1;
    assert!(ImageAttachment::new(path.clone(), "image/png".into(), different).is_err());
    fs::remove_file(&path).unwrap();
    assert!(ImageAttachment::new(path, "image/png".into(), bytes).is_err());
}

#[test]
fn claude_oversize_images_fail_preflight_without_starting_process() {
    let mut bytes = png();
    bytes.resize(3_750_001, 0);
    let directory = tempfile::tempdir().unwrap();
    let image = prepared(&directory.path().join("image.png"), &bytes);
    assert!(validate_images(&Provider::Claude, std::slice::from_ref(&image)).is_err());
    let session = Session::start_with_images(
        Provider::Claude,
        Launch {
            executable: directory.path().join("must-not-launch"),
            cwd: directory.path().into(),
            session: None,
            prompt: "inspect".into(),
            model: None,
        },
        vec![image],
    );
    match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        Event::Failed(message) => assert!(message.contains("3,750,000"), "{message}"),
        event => panic!("unexpected preflight outcome: {event:?}"),
    }
}
