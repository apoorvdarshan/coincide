//! Real isolated fake app-server; environment changes are child-local only.
use super::*;
#[cfg(unix)]
#[test]
fn catalog_speed_admission_and_actual_protocol_standard_reset() {
    use std::{os::unix::fs::PermissionsExt, process::Command};
    let root = tempfile::tempdir().unwrap();
    let exe = root.path().join("codex-speed-fixture");
    std::fs::write(&exe, r#"#!/usr/bin/env python3
import json,sys
from pathlib import Path
root=Path(__file__).parent
def read():return json.loads(sys.stdin.readline())
def write(v):print(json.dumps(v),flush=True)
r=read();assert r['method']=='initialize';write({'id':r['id'],'result':{}})
assert read()['method']=='initialized'
r=read()
if r['method']=='model/list':
 if (root/'fail-catalog').exists():
  write({'id':r['id'],'error':{'code':-32603,'message':'synthetic failure'}});sys.exit(0)
 write({'id':r['id'],'result':{'data':[{'model':'reported-model','supportedReasoningEfforts':[{'reasoningEffort':'high'}],'serviceTiers':[{'id':'default'},{'id':'priority','name':'Fast'}]}],'nextCursor':None}});sys.exit(0)
assert r['method'] in ['thread/start','thread/resume']
ack={'thread':{'id':'speed-source'},'model':'reported-model'}
if (root/'tier').exists():ack['serviceTier']=(root/'tier').read_text()
write({'id':r['id'],'result':ack})
r=read();assert r['method']=='turn/start'
with (root/'turns.jsonl').open('a') as f:f.write(json.dumps(r['params'])+'\n')
if 'serviceTier' in r['params']:(root/'tier').write_text(r['params']['serviceTier'])
write({'id':r['id'],'result':{'turn':{'id':'speed-turn'}}})
write({'method':'turn/completed','params':{'threadId':'speed-source','turn':{'id':'speed-turn','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o700)).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "api::composer_speed_api_tests::speed_fixture_child",
            "--nocapture",
        ])
        .env("COINCIDE_SPEED_FIXTURE_ROOT", root.path())
        .env("COINCIDE_CODEX_EXECUTABLE", &exe)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let turns = std::fs::read_to_string(root.path().join("turns.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(turns.len(), 3);
    assert!(
        turns[0].get("serviceTier").is_none(),
        "fresh Standard must omit tier"
    );
    assert_eq!(turns[1]["serviceTier"], "priority");
    assert_eq!(
        turns[2]["serviceTier"], "default",
        "resumed faster tier must be explicitly cleared"
    );
    for turn in turns {
        assert_eq!(turn["threadId"], "speed-source");
        assert_eq!(turn["model"], "reported-model");
        assert!(turn.get("effort").is_none());
    }
}
#[test]
fn speed_only_repair_preserves_raw_fields_and_rejects_other_mutations() {
    let thread = json!({"id":"synthetic","selection":{"provider":"codex","modelID":"reported-model","accountID":"default","speed":"old-unsupported"},"draft":"exact unsent","draftContext":[{"future":true}],"rustDraftImages":[{"future":true}],"accessMode":"approval","interactionMode":"build","sessions":{"codex":{"sessionID":"synthetic-source"}},"future":{"keep":true}});
    let minimal = json!({"threadId":"synthetic","speed":null});
    let selection = crate::composer_selection::repair_clear_speed(&minimal, &thread).unwrap();
    let mut expected = thread["selection"].clone();
    expected.as_object_mut().unwrap().remove("speed");
    assert_eq!(selection, expected);
    for (key, value) in [
        ("model", json!("other")),
        ("accountId", Value::Null),
        ("effort", json!("high")),
        ("interactionMode", json!("plan")),
        ("proof", json!(true)),
    ] {
        let mut bad = minimal.clone();
        bad[key] = value;
        assert!(crate::composer_selection::repair_clear_speed(&bad, &thread).is_err());
    }
    let mut bot = thread.clone();
    bot["botID"] = json!("bot");
    assert!(crate::composer_selection::repair_clear_speed(&minimal, &bot).is_err());
    let mut effort = thread.clone();
    effort["selection"]["effort"] = json!("high");
    assert!(crate::composer_selection::repair_clear_speed(&minimal, &effort).is_err());
}

#[test]
fn combined_repair_obeys_existing_bot_import_running_recovery_and_freeze_gates() {
    let dir = tempfile::tempdir().unwrap();
    let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    let mut thread = engine.execute("threads.create", &json!({})).unwrap();
    let id = text(&thread, "id");
    thread["selection"] = json!({"provider":"codex","modelID":"reported-model","accountID":"default","effort":"high","speed":"priority"});
    thread["draft"] = json!("exact café\n");
    thread["draftContext"] = json!([{"future":"preserve"}]);
    thread["rustDraftImages"] = json!([{"future":"preserve"}]);
    let clear = json!({"threadId":id,"effort":null,"speed":null});
    for field in ["botID", "rustBotContext"] {
        let mut blocked = thread.clone();
        blocked[field] = json!("fixed");
        engine.store.save(&blocked).unwrap();
        let revision = engine.revision;
        assert_eq!(
            engine
                .execute("agent.selection.capabilities", &json!({"threadId":id}))
                .unwrap()["repairOptionsClearAvailable"],
            false
        );
        assert!(engine.execute("agent.select", &clear).is_err());
        assert_eq!(engine.store.thread(&id).unwrap(), blocked);
        assert_eq!(engine.revision, revision);
    }
    engine.store.save(&thread).unwrap();
    engine.runs.insert(
        id.clone(),
        Running {
            configuration: None,
            usage_context: None,
            session: Session::fixture_worker(|_, _| {}),
            provider: "codex".into(),
            transcript_start: 0,
            pending: HashMap::new(),
            schedule_claim: None,
            queue_claim: None,
            cancelled: false,
            events: VecDeque::new(),
            persistence_error: None,
        },
    );
    let revision = engine.revision;
    assert_eq!(
        engine
            .execute("agent.selection.capabilities", &json!({"threadId":id}))
            .unwrap()["repairOptionsClearAvailable"],
        false
    );
    assert!(engine.execute("agent.select", &clear).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    assert_eq!(engine.revision, revision);
    engine.runs.remove(&id);
    engine.unsaved_threads.insert(id.clone(), thread.clone());
    assert_eq!(
        engine
            .execute("agent.selection.capabilities", &json!({"threadId":id}))
            .unwrap()["repairOptionsClearAvailable"],
        false
    );
    assert!(engine.execute("agent.select", &clear).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    assert_eq!(engine.revision, revision);
    engine.unsaved_threads.remove(&id);
    let mut imported = thread.clone();
    imported["id"] = json!(Uuid::new_v4().to_string());
    engine
        .store
        .import_cli_session(
            &imported,
            "ImportedSessions/options-repair-fixture.json",
            b"synthetic source",
        )
        .unwrap();
    let imported_id = text(&imported, "id");
    assert_eq!(
        engine
            .execute(
                "agent.selection.capabilities",
                &json!({"threadId":imported_id})
            )
            .unwrap()["repairOptionsClearAvailable"],
        false
    );
    assert!(
        engine
            .execute(
                "agent.select",
                &json!({"threadId":imported_id,"effort":null,"speed":null})
            )
            .is_err()
    );
    assert_eq!(engine.store.thread(&imported_id).unwrap(), imported);
    assert_eq!(engine.revision, revision);
    engine.freeze_admissions();
    assert!(engine.execute("agent.select", &clear).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    assert_eq!(engine.revision, revision);
}

#[cfg(unix)]
#[test]
#[ignore = "Scoped fake provider child; parent supplies isolated fixture environment"]
fn speed_fixture_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_SPEED_FIXTURE_ROOT").unwrap());
    let mut engine = Engine::fixture(Store::open(&root.join("state.sqlite")).unwrap());
    let id = engine
        .execute("threads.create", &json!({"cwd":root}))
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let params = json!({"threadId":id,"provider":"codex","model":"reported-model","effort":null,"speed":"priority","accessMode":"approval","interactionMode":"build"});
    let before = engine.store.thread(&id).unwrap();
    let revision = engine.revision;
    assert!(engine.execute("agent.select", &params).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    assert_eq!(engine.revision, revision);
    let mut standard = params.clone();
    standard["speed"] = Value::Null;
    engine.execute("agent.select", &standard).unwrap();
    fn send(engine: &mut Engine, id: &str) {
        engine
            .execute(
                "agent.send",
                &json!({"threadId":id,"text":"synthetic test"}),
            )
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while engine.runs.contains_key(id) {
            engine.poll();
            assert!(Instant::now() < deadline, "fake turn did not finish");
            std::thread::yield_now();
        }
    }
    send(&mut engine, &id);
    let refresh = |engine: &mut Engine, expected: &str| {
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
                assert_eq!(response["state"], expected, "{response}");
                break;
            }
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        while engine.model_catalog.shutdown_status().running != 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
    };
    refresh(&mut engine, "ready");
    for (field, value) in [
        ("speed", json!("fast")),
        ("speed", json!("default")),
        ("speed", json!(" priority ")),
        ("speed", json!(true)),
        ("provider", json!("claude")),
        ("model", json!("default")),
        ("model", json!("unknown")),
        ("accountId", json!("named")),
        ("proof", json!(true)),
    ] {
        let mut bad = params.clone();
        bad[field] = value;
        let before = engine.store.thread(&id).unwrap();
        let revision = engine.revision;
        assert!(engine.execute("agent.select", &bad).is_err(), "{bad}");
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        assert_eq!(engine.revision, revision);
    }
    let mut selected = engine.execute("agent.select", &params).unwrap();
    selected["draft"] = json!("exact unsent café\n");
    selected["draftContext"] = json!([]);
    selected["rustDraftImages"] = json!([]);
    selected["future"] = json!({"keep":true});
    engine.store.save(&selected).unwrap();
    let caps = engine
        .execute("agent.selection.capabilities", &json!({"threadId":id}))
        .unwrap();
    let codex = caps["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["provider"] == "codex")
        .unwrap();
    assert_eq!(codex["speed"]["supported"], true);
    assert_eq!(
        codex["speed"]["choices"],
        json!([{"id":"priority","name":"Fast","detail":null}])
    );
    let mut omitted = params.clone();
    omitted.as_object_mut().unwrap().remove("speed");
    let revision = engine.revision;
    assert!(engine.execute("agent.select", &omitted).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), selected);
    assert_eq!(engine.revision, revision);
    send(&mut engine, &id);
    engine.execute("agent.select", &standard).unwrap();
    send(&mut engine, &id);
    let mut combined = params.clone();
    combined["effort"] = json!("high");
    engine.execute("agent.select", &combined).unwrap();
    std::fs::write(root.join("fail-catalog"), b"synthetic").unwrap();
    refresh(&mut engine, "failed");
    let before = engine.store.thread(&id).unwrap();
    let revision = engine.revision;
    assert!(
        engine
            .execute(
                "agent.send",
                &json!({"threadId":id,"text":"must not launch"})
            )
            .is_err()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    assert_eq!(engine.revision, revision);
    let caps = engine
        .execute("agent.selection.capabilities", &json!({"threadId":id}))
        .unwrap();
    assert_eq!(caps["locked"], true);
    assert_eq!(caps["repairSpeedClearAvailable"], false);
    assert_eq!(caps["repairClearAvailable"], false);
    assert_eq!(caps["repairOptionsClearAvailable"], true);
    for bad in [
        json!({"threadId":id,"effort":null}),
        json!({"threadId":id,"speed":null}),
        json!({"threadId":id,"effort":null,"speed":null,"model":"other"}),
        json!({"threadId":id,"effort":null,"speed":null,"interactionMode":"plan"}),
        json!({"threadId":id,"effort":null,"speed":null,"provider":"claude"}),
        json!({"threadId":id,"effort":null,"speed":null,"extra":true}),
    ] {
        assert!(engine.execute("agent.select", &bad).is_err());
        assert_eq!(engine.store.thread(&id).unwrap(), before);
        assert_eq!(engine.revision, revision);
    }
    let repaired = engine
        .execute(
            "agent.select",
            &json!({"threadId":id,"effort":null,"speed":null}),
        )
        .unwrap();
    let mut expected = before;
    expected["selection"]
        .as_object_mut()
        .unwrap()
        .remove("speed");
    expected["selection"]
        .as_object_mut()
        .unwrap()
        .remove("effort");
    // Explicit Automatic/Standard choices clear this account's remembered
    // desired options too. Every unrelated field remains in the exact compare.
    expected["modelPreferences"]["codex/default"]["effort"] = Value::Null;
    expected["modelPreferences"]["codex/default"]["speed"] = Value::Null;
    // save updates timestamp; all other thread data remains exact.
    expected["updatedAt"] = repaired["updatedAt"].clone();
    assert_eq!(repaired, expected);
    assert!(!engine.runs.contains_key(&id));
}
