use super::*;
fn fixture() -> (tempfile::TempDir, Engine, String) {
    let dir = tempfile::tempdir().unwrap();
    let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    let id = engine
        .execute("threads.create", &json!({"cwd":dir.path()}))
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    (dir, engine, id)
}
#[test]
fn codex_modes_selection_persists_exactly_and_unsupported_choices_reject_atomically() {
    let (_dir, mut engine, id) = fixture();
    let selected=engine.execute("agent.select",&json!({"threadId":id,"provider":"codex","model":"fixture-model","accessMode":"fullAccess","interactionMode":"plan"})).unwrap();
    assert_eq!(selected["accessMode"], "fullAccess");
    assert_eq!(selected["interactionMode"], "plan");
    let revision = engine.revision;
    for params in [
        json!({"provider":"claude","model":"fixture-model"}),
        json!({"provider":"codex","model":"default","interactionMode":"plan"}),
        json!({"provider":"codex","model":"fixture-model","effort":"high"}),
        json!({"provider":"codex","model":"fixture-model","accessMode":null}),
    ] {
        let mut params = params;
        params["threadId"] = json!(id);
        assert!(engine.execute("agent.select", &params).is_err());
        assert_eq!(engine.store.thread(&id).unwrap(), selected);
        assert_eq!(engine.revision, revision);
    }
    let build=engine.execute("agent.select",&json!({"threadId":id,"provider":"codex","model":"default","accessMode":"approval","interactionMode":"build"})).unwrap();
    assert_eq!(build["interactionMode"], "build");
}
#[test]
fn project_defaults_accept_only_connected_modes_and_reject_default_plan_without_orphan() {
    let (_dir, mut engine, _id) = fixture();
    let project = Uuid::new_v4().to_string();
    let defaults = json!({"selection":{"provider":"codex","modelID":"fixture-model"},"accessMode":"fullAccess","interactionMode":"plan"});
    engine
        .store
        .save_document(
            "projects.json",
            &json!([{"id":project,"threadDefaults":defaults}]),
        )
        .unwrap();
    let created = engine
        .execute("threads.create", &json!({"projectId":project}))
        .unwrap();
    assert_eq!(created["accessMode"], "fullAccess");
    assert_eq!(created["interactionMode"], "plan");
    let before = engine.execute("threads.list", &json!({})).unwrap();
    let revision = engine.revision;
    for provider in ["codex", "claude"] {
        let mut invalid = defaults.clone();
        invalid["selection"]["provider"] = json!(provider);
        invalid["selection"]["modelID"] = json!("default");
        engine
            .store
            .save_document(
                "projects.json",
                &json!([{"id":project,"threadDefaults":invalid}]),
            )
            .unwrap();
        assert!(
            engine
                .execute("threads.create", &json!({"projectId":project}))
                .is_err()
        );
        assert_eq!(engine.execute("threads.list", &json!({})).unwrap(), before);
        assert_eq!(engine.revision, revision);
    }
}
#[test]
fn rejected_default_plan_send_preserves_draft_context_and_ignores_forged_model_proof() {
    let (_dir, mut engine, id) = fixture();
    let mut thread = engine.store.thread(&id).unwrap();
    thread["draft"] = json!("keep exact");
    thread["interactionMode"] = json!("plan");
    thread["rustResolvedModel"] = json!({"model":"forged","trusted":true});
    engine.store.save(&thread).unwrap();
    let revision = engine.revision;
    assert!(
        engine
            .execute("agent.send", &json!({"threadId":id,"text":"keep exact"}))
            .is_err()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    assert_eq!(engine.revision, revision);
    assert!(engine.runs.is_empty());
}

#[cfg(unix)]
#[test]
fn actual_engine_codex_plan_then_build_resets_policy_without_model_substitution() {
    use std::{os::unix::fs::PermissionsExt, process::Command};
    let dir = tempfile::tempdir().unwrap();
    let exe = dir.path().join("fixture-provider");
    std::fs::write(&exe,r#"#!/usr/bin/env python3
import json,sys
def read():return json.loads(sys.stdin.readline())
def write(v):print(json.dumps(v),flush=True)
r=read();write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read();assert r['method'] in ['thread/start','thread/resume']
write({'id':r['id'],'result':{'thread':{'id':'source-session'},'model':'source-resolved-model'}})
r=read();assert r['method']=='turn/start'
with open('policy-launches.jsonl','a') as f:f.write(json.dumps(r['params'])+'\n')
write({'id':r['id'],'result':{'turn':{'id':'source-turn'}}})
write({'method':'turn/completed','params':{'threadId':'source-session','turn':{'id':'source-turn','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o700)).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "api::composer_policy_api_tests::mode_provider_fixture_child",
            "--nocapture",
        ])
        .env("COINCIDE_MODE_FIXTURE_ROOT", dir.path())
        .env("COINCIDE_CODEX_EXECUTABLE", &exe)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "child failed: {} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let launches = std::fs::read_to_string(dir.path().join("policy-launches.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(launches.len(), 2);
    assert_eq!(launches[0]["approvalPolicy"], "never");
    assert_eq!(
        launches[0]["sandboxPolicy"],
        json!({"type":"dangerFullAccess"})
    );
    assert_eq!(launches[0]["collaborationMode"]["mode"], "plan");
    assert_eq!(launches[0]["model"], "fixture-explicit-model");
    assert_eq!(launches[1]["approvalPolicy"], "untrusted");
    assert_eq!(launches[1]["sandboxPolicy"], json!({"type":"readOnly"}));
    assert_eq!(launches[1]["collaborationMode"]["mode"], "default");
    assert_eq!(launches[1]["model"], "source-resolved-model");
}
#[cfg(unix)]
#[test]
#[ignore = "Scoped synthetic provider child; parent supplies fixture-only environment"]
fn mode_provider_fixture_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_MODE_FIXTURE_ROOT").unwrap());
    let mut engine = Engine::fixture(Store::open(&root.join("state.sqlite")).unwrap());
    let id = engine
        .execute("threads.create", &json!({"cwd":root}))
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    for (access, interaction, model) in [
        ("fullAccess", "plan", "fixture-explicit-model"),
        ("approval", "build", "default"),
    ] {
        engine.execute("agent.select",&json!({"threadId":id,"provider":"codex","model":model,"accessMode":access,"interactionMode":interaction})).unwrap();
        engine
            .execute(
                "agent.send",
                &json!({"threadId":id,"text":"synthetic mode turn"}),
            )
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while engine.runs.contains_key(&id) {
            engine.poll();
            assert!(
                Instant::now() < deadline,
                "synthetic provider did not finish"
            );
            std::thread::yield_now();
        }
        let stored = engine.store.thread(&id).unwrap();
        assert!(
            !stored["items"]
                .as_array()
                .unwrap()
                .iter()
                .any(|item| item["kind"] == "error"),
            "{stored}"
        );
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    while engine.provider_workers_status().running != 0 {
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
}
