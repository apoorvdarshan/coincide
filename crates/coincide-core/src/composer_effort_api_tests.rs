//! Isolated fake app-server boundary; no real account or provider discovery.
use super::*;

#[cfg(unix)]
#[test]
fn actual_catalog_gates_effort_and_provider_receives_exact_effort_and_clear() {
    use std::{os::unix::fs::PermissionsExt, process::Command};
    let dir = tempfile::tempdir().unwrap();
    let exe = dir.path().join("codex-effort-fixture");
    std::fs::write(&exe,r#"#!/usr/bin/env python3
import json,sys
from pathlib import Path
root=Path(__file__).parent
def read():return json.loads(sys.stdin.readline())
def write(v):print(json.dumps(v),flush=True)
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read()
if r['method']=='model/list':
 write({'id':r['id'],'result':{'data':[{'model':'reported-model','supportedReasoningEfforts':[{'reasoningEffort':'low'},{'reasoningEffort':'high'}],'defaultReasoningEffort':'low'}],'nextCursor':None}})
 sys.exit(0)
assert r['method'] in ['thread/start','thread/resume']
write({'id':r['id'],'result':{'thread':{'id':'effort-source'},'model':'reported-model'}})
r=read();assert r['method']=='turn/start'
with (root/'turns.jsonl').open('a') as f:f.write(json.dumps(r['params'])+'\n')
write({'id':r['id'],'result':{'turn':{'id':'effort-turn'}}})
write({'method':'turn/completed','params':{'threadId':'effort-source','turn':{'id':'effort-turn','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o700)).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "api::composer_effort_api_tests::effort_provider_fixture_child",
            "--nocapture",
        ])
        .env("COINCIDE_EFFORT_FIXTURE_ROOT", dir.path())
        .env("COINCIDE_CODEX_EXECUTABLE", &exe)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let turns = std::fs::read_to_string(dir.path().join("turns.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[0]["effort"], "high");
    assert_eq!(
        turns[0]["collaborationMode"]["settings"]["reasoning_effort"],
        "high"
    );
    assert_eq!(turns[0]["collaborationMode"]["mode"], "plan");
    assert!(turns[1].get("effort").is_none());
    assert!(turns[1]["collaborationMode"]["settings"]["reasoning_effort"].is_null());
    assert_eq!(turns[1]["collaborationMode"]["mode"], "default");
    for turn in turns {
        assert_eq!(turn["model"], "reported-model");
        assert!(turn.get("serviceTier").is_none());
    }
}
#[cfg(unix)]
#[test]
#[ignore = "Scoped fake provider child; parent supplies isolated fixture environment"]
fn effort_provider_fixture_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_EFFORT_FIXTURE_ROOT").unwrap());
    let mut engine = Engine::fixture(Store::open(&root.join("state.sqlite")).unwrap());
    let id = engine
        .execute("threads.create", &json!({"cwd":root}))
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let params = json!({"threadId":id,"provider":"codex","model":"reported-model","effort":"high","speed":null,"accessMode":"approval","interactionMode":"plan"});
    let before = engine.store.thread(&id).unwrap();
    let revision = engine.revision;
    assert!(engine.execute("agent.select", &params).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    assert_eq!(engine.revision, revision);
    let refresh = |engine: &mut Engine| {
        let request = engine
            .execute("agent.models.refresh", &json!({"provider":"codex"}))
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let response = engine
                .execute(
                    "agent.models.status",
                    &json!({"requestId":request["requestId"]}),
                )
                .unwrap();
            if response["state"] != "loading" {
                assert_eq!(response["state"], "ready", "{response}");
                break;
            }
            assert!(Instant::now() < deadline, "catalog did not finish");
            std::thread::yield_now();
        }
        while engine.model_catalog.shutdown_status().running != 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
    };
    refresh(&mut engine);
    for (key, value) in [
        ("effort", json!("unknown")),
        ("effort", json!(" high ")),
        ("effort", json!(true)),
        ("model", json!("unknown-model")),
        ("model", json!("default")),
        ("provider", json!("claude")),
        ("accountId", json!("other")),
        ("speed", json!("fast")),
        ("proof", json!(true)),
    ] {
        let mut rejected = params.clone();
        rejected[key] = value;
        let before = engine.store.thread(&id).unwrap();
        let revision = engine.revision;
        assert!(
            engine.execute("agent.select", &rejected).is_err(),
            "{rejected}"
        );
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        assert_eq!(engine.revision, revision);
    }
    let selected = engine.execute("agent.select", &params).unwrap();
    assert_eq!(selected["selection"]["effort"], "high");
    let mut omitted = params.clone();
    omitted.as_object_mut().unwrap().remove("effort");
    let revision = engine.revision;
    assert!(engine.execute("agent.select", &omitted).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), selected);
    assert_eq!(engine.revision, revision);

    let caps = engine
        .execute("agent.selection.capabilities", &json!({"threadId":id}))
        .unwrap();
    let codex = caps["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["provider"] == "codex")
        .unwrap();
    assert_eq!(caps["locked"], false);
    assert_eq!(codex["effort"]["choices"], json!(["low", "high"]));
    let mut invalid = selected.clone();
    invalid["selection"]["effort"] = json!("not-reported");
    invalid["draft"] = json!("exact unsent café\n");
    invalid["draftContext"] = json!([]);
    invalid["rustDraftImages"] = json!([]);
    engine.store.save(&invalid).unwrap();
    let revision = engine.revision;
    assert!(
        engine
            .execute(
                "agent.send",
                &json!({"threadId":id,"text":"must never launch"})
            )
            .is_err()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), invalid);
    assert_eq!(engine.revision, revision);
    assert!(engine.runs.is_empty());
    engine.store.save(&selected).unwrap();
    for effort in [json!("high"), Value::Null] {
        let mut choice = params.clone();
        choice["effort"] = effort.clone();
        if effort.is_null() {
            choice["interactionMode"] = json!("build");
        }
        engine.execute("agent.select", &choice).unwrap();
        engine
            .execute(
                "agent.send",
                &json!({"threadId":id,"text":"synthetic effort turn"}),
            )
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while engine.runs.contains_key(&id) {
            engine.poll();
            assert!(Instant::now() < deadline);
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
    engine.execute("agent.select", &params).unwrap();
    let stored = engine.store.thread(&id).unwrap();
    let proof = engine
        .composer_effort_proof(&stored["selection"])
        .unwrap()
        .unwrap();
    engine
        .execute("agent.models.refresh", &json!({"provider":"codex"}))
        .unwrap();
    assert!(
        proof.validate(&stored["selection"]).is_err(),
        "refresh must revoke existing proof before a result"
    );
    let revision = engine.revision;
    assert!(
        engine
            .execute(
                "agent.send",
                &json!({"threadId":id,"text":"revoked must not launch"})
            )
            .is_err()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), stored);
    assert_eq!(engine.revision, revision);
    let deadline = Instant::now() + Duration::from_secs(10);
    engine.model_catalog.request_shutdown();
    while engine.model_catalog.shutdown_status().running != 0
        || engine.provider_workers_status().running != 0
    {
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
}
