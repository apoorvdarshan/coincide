//! Actual synthetic app-server subprocesses only; no provider/account/network.
#![cfg(unix)]
use coincide_core::{
    agent::{Event, Launch, Provider, Session},
    composer_policy::{Origin, Policy},
};
use serde_json::{Value, json};
use std::{fs, os::unix::fs::PermissionsExt, time::Duration};
fn run_case(
    access: &str,
    interaction: &str,
    selected: &str,
    resume: bool,
    resolved: Option<&str>,
) -> (tempfile::TempDir, Session) {
    let dir = tempfile::tempdir().unwrap();
    let exe = dir.path().join("fixture");
    let source = r#"#!/usr/bin/env python3
import json,sys
def read():return json.loads(sys.stdin.readline())
def write(v):print(json.dumps(v),flush=True)
expected=json.load(open('expected.json'))
r=read();write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read();assert r['method']==expected['threadMethod']
assert r['params']['approvalPolicy']==expected['threadApproval'] and r['params']['sandbox']==expected['threadSandbox']
if expected['threadMethod']=='thread/resume': assert r['params']['serviceTier']=='default'
result={'thread':{'id':'owned-source'}}
if expected['resolved'] is not None:result['model']=expected['resolved']
write({'id':r['id'],'result':result})
if expected['mustFail']:
 assert sys.stdin.readline()==''
 sys.exit(0)
r=read();assert r['method']=='turn/start'
with open('observed.json','w') as f:json.dump(r['params'],f)
for key,value in expected['policy'].items():assert r['params'][key]==value,(key,r['params'])
assert 'effort' not in r['params'] and 'serviceTier' not in r['params']
write({'id':r['id'],'result':{'turn':{'id':'owned-turn'}}})
write({'method':'turn/completed','params':{'threadId':'owned-source','turn':{'id':'owned-turn','status':'completed'}}})
sys.stdin.readline()
"#;
    fs::write(&exe, source).unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o700)).unwrap();
    let thread = json!({"selection":{"provider":"codex","modelID":selected},"accessMode":access,"interactionMode":interaction});
    let policy = Policy::parse(&thread, Origin::Ordinary).unwrap();
    policy.preflight().unwrap();
    let actual = if selected == "default" {
        resolved
    } else {
        Some(selected)
    };
    let must_fail = resume && actual.is_none();
    let mut fields = json!({"approvalPolicy":if access=="approval"{"untrusted"}else{"never"},"approvalsReviewer":"user","sandboxPolicy":{"type":if access=="approval"{"readOnly"}else{"dangerFullAccess"}}});
    if let Some(model) = actual {
        fields["model"] = json!(model);
        fields["collaborationMode"] = json!({"mode":if interaction=="plan"{"plan"}else{"default"},"settings":{"model":model,"reasoning_effort":null,"developer_instructions":null}});
    }
    fs::write(dir.path().join("expected.json"),json!({"threadMethod":if resume{"thread/resume"}else{"thread/start"},"threadApproval":if access=="approval"{"untrusted"}else{"never"},"threadSandbox":if access=="approval"{"read-only"}else{"danger-full-access"},"resolved":resolved,"policy":fields,"mustFail":must_fail}).to_string()).unwrap();
    let session = Session::start_with_mode_policy(
        Provider::Codex,
        Launch {
            executable: exe,
            cwd: dir.path().into(),
            session: resume.then(|| "owned-source".into()),
            prompt: "synthetic".into(),
            model: (selected != "default").then(|| selected.into()),
            variant: None,
            full_access: false,
        },
        Vec::new(),
        None,
        Some(policy),
    );
    (dir, session)
}
fn finish(session: &Session) -> Result<(), String> {
    loop {
        match session.events.recv_timeout(Duration::from_secs(5)).unwrap() {
            Event::Finished => return Ok(()),
            Event::Failed(error) => return Err(error),
            _ => {}
        }
    }
}
#[test]
fn ordinary_codex_modes_apply_exact_schema_and_source_resolved_build_clears_plan() {
    for (access, interaction, model, resume, resolved) in [
        ("approval", "build", "default", false, None),
        ("fullAccess", "build", "default", false, None),
        ("approval", "plan", "fixture-model", false, None),
        (
            "fullAccess",
            "plan",
            "fixture-model",
            true,
            Some("provider-default"),
        ),
        (
            "approval",
            "build",
            "default",
            true,
            Some("actual-source-model"),
        ),
    ] {
        let (dir, session) = run_case(access, interaction, model, resume, resolved);
        finish(&session).unwrap();
        let observed: Value =
            serde_json::from_slice(&fs::read(dir.path().join("observed.json")).unwrap()).unwrap();
        if interaction == "build" && resume {
            assert_eq!(observed["collaborationMode"]["mode"], "default");
            assert_eq!(observed["model"], "actual-source-model");
        }
    }
}
#[test]
fn resumed_default_without_actual_model_proof_fails_before_turn_dispatch() {
    let (dir, session) = run_case("approval", "build", "default", true, None);
    assert!(finish(&session).unwrap_err().contains("resolved model"));
    assert!(!dir.path().join("observed.json").exists());
}
