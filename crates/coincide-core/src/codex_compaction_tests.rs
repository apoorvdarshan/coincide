use super::*;
use std::{fs, os::unix::fs::PermissionsExt};

#[test]
fn compact_control_waits_for_the_owned_turn_in_either_response_order() {
    for order in ["early", "late", "refused"] {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join(order);
        fs::write(&executable, r#"#!/usr/bin/env python3
import json,os,sys
def read(): return json.loads(sys.stdin.readline())
def write(v): print(json.dumps(v),flush=True)
r=read(); assert r['method']=='initialize'; write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read(); assert r['method']=='thread/resume'; assert r['params']['threadId']=='native-thread'
write({'id':r['id'],'result':{'thread':{'id':'native-thread'}}})
r=read(); assert r['method']=='thread/compact/start'; assert r['params']=={'threadId':'native-thread'}
order=os.path.basename(sys.argv[0])
if order=='refused':
    write({'id':r['id'],'error':{'message':'compaction refused'}})
else:
    started={'method':'turn/started','params':{'threadId':'native-thread','turn':{'id':'compact-turn'}}}
    completed={'method':'turn/completed','params':{'threadId':'native-thread','turn':{'id':'compact-turn','status':'completed'}}}
    if order=='early':
        write(started); write(completed); write({'id':r['id'],'result':{}})
    else:
        write({'id':r['id'],'result':{}}); write(started); write(completed)
sys.stdin.readline()
"#).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let session = Session::start_with_mode_policy_and_profile(
            Provider::Codex,
            Launch {
                executable,
                cwd: directory.path().into(),
                session: Some("native-thread".into()),
                prompt: "historical text must never be submitted as the control".into(),
                model: None,
                variant: None,
                full_access: false,
            },
            Vec::new(),
            None,
            None,
            LaunchOptions {
                compact: true,
                ..Default::default()
            },
        );
        assert!(session.is_provider_control());
        loop {
            match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
                Event::Finished if order != "refused" => break,
                Event::Failed(error) if order == "refused" => {
                    assert!(error.contains("compaction refused"));
                    break;
                }
                Event::Finished => panic!("refused compaction was reported as complete"),
                Event::Failed(error) => panic!("{order}: {error}"),
                _ => {}
            }
        }
        assert!(!session.can_steer());
    }
}

#[test]
fn only_an_exact_standalone_compact_command_is_a_control() {
    assert!(codex_compact_command(" \n/compact\t"));
    assert!(!codex_compact_command("/compact extra"));
    assert!(!codex_compact_command("please run /compact"));
}
