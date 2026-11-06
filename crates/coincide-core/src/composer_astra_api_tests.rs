//! Astra defaults use admitted actual fake model/list data, never static rows.
use super::*;
#[cfg(unix)]
#[test]
fn actual_astra_default_preserves_null_and_forwards_only_proven_effective_effort() {
    use std::{os::unix::fs::PermissionsExt, process::Command};
    let root = tempfile::tempdir().unwrap();
    let exe = root.path().join("codex-astra-fixture");
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
 if (root/'fail-catalog').exists():
  write({'id':r['id'],'error':{'code':-32603,'message':'synthetic failure'}});sys.exit(0)
 efforts=['high'] if (root/'no-medium').exists() else ['low','medium','high']
 rows=[{'model':model,'supportedReasoningEfforts':[{'reasoningEffort':e} for e in efforts],'defaultReasoningEffort':'low','serviceTiers':[{'id':'priority','name':'Fast'}]} for model in ['gpt-6-astra','openai.gpt-6-astra']]
 write({'id':r['id'],'result':{'data':rows,'nextCursor':None}});sys.exit(0)
assert r['method'] in ['thread/start','thread/resume']
write({'id':r['id'],'result':{'thread':{'id':'astra-source'},'model':'gpt-6-astra'}})
r=read();assert r['method']=='turn/start'
with (root/'turns.jsonl').open('a') as f:f.write(json.dumps(r['params'])+'\n')
write({'id':r['id'],'result':{'turn':{'id':'astra-turn'}}})
write({'method':'turn/completed','params':{'threadId':'astra-source','turn':{'id':'astra-turn','status':'completed'}}})
sys.stdin.readline()
"#).unwrap();
    std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o700)).unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "api::composer_astra_api_tests::astra_fixture_child",
            "--nocapture",
        ])
        .env("COINCIDE_ASTRA_FIXTURE_ROOT", root.path())
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
    assert_eq!(turns.len(), 6);
    for (index, expected) in [
        Some("medium"),
        Some("high"),
        Some("medium"),
        Some("medium"),
        None,
        Some("high"),
    ]
    .iter()
    .enumerate()
    {
        assert_eq!(turns[index]["effort"].as_str(), *expected, "turn {index}");
        assert_eq!(
            turns[index]["collaborationMode"]["settings"]["reasoning_effort"].as_str(),
            *expected
        );
    }
    assert_eq!(turns[3]["model"], "openai.gpt-6-astra");
    assert_eq!(turns[4]["model"], "gpt-6-astra");
}
#[cfg(unix)]
#[test]
#[ignore = "Scoped fake app-server child; no actual provider"]
fn astra_fixture_child() {
    let root = PathBuf::from(std::env::var_os("COINCIDE_ASTRA_FIXTURE_ROOT").unwrap());
    let mut engine = Engine::fixture(Store::open(&root.join("state.sqlite")).unwrap());
    let mut initial = engine
        .execute("threads.create", &json!({"cwd":root}))
        .unwrap();
    let id = text(&initial, "id");
    initial["selection"]["effort"] = Value::Null;
    initial["future"] = json!({"preserve":true});
    engine.store.save(&initial).unwrap();
    let params = json!({"threadId":id,"provider":"codex","model":"gpt-6-astra","effort":null,"speed":null,"accessMode":"approval","interactionMode":"build"});
    let revision = engine.revision;
    assert!(engine.execute("agent.select", &params).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), initial);
    assert_eq!(engine.revision, revision);
    let refresh = |engine: &mut Engine, expected: &str| {
        let request = engine
            .execute("agent.models.refresh", &json!({"provider":"codex"}))
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let result = engine
                .execute(
                    "agent.models.status",
                    &json!({"requestId":request["requestId"]}),
                )
                .unwrap();
            if result["state"] != "loading" {
                assert_eq!(result["state"], expected);
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
    fn send(engine: &mut Engine, id: &str) {
        let saved = engine.store.thread(id).unwrap()["selection"].clone();
        engine
            .execute(
                "agent.send",
                &json!({"threadId":id,"text":"synthetic default test"}),
            )
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while engine.runs.contains_key(id) {
            engine.poll();
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(engine.store.thread(id).unwrap()["selection"], saved);
    }
    refresh(&mut engine, "ready");
    let selected = engine.execute("agent.select", &params).unwrap();
    assert_eq!(selected["selection"].get("effort"), Some(&Value::Null));
    assert_eq!(selected["future"], initial["future"]);
    let caps = engine
        .execute("agent.selection.capabilities", &json!({"threadId":id}))
        .unwrap();
    let codex = caps["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["provider"] == "codex")
        .unwrap();
    assert_eq!(codex["effort"]["reportedDefault"], "low");
    assert_eq!(codex["effort"]["effectiveDefault"], "medium");
    assert_eq!(caps["canReplaceUnprovedAutomaticDefault"], false);
    send(&mut engine, &id);
    let mut high = params.clone();
    high["effort"] = json!("high");
    engine.execute("agent.select", &high).unwrap();
    send(&mut engine, &id);
    let cleared = engine
        .execute("agent.select", &json!({"threadId":id,"effort":null}))
        .unwrap();
    assert!(cleared["selection"]["effort"].is_null());
    send(&mut engine, &id);
    let mut prefix = params.clone();
    prefix["model"] = json!("openai.gpt-6-astra");
    engine.execute("agent.select", &prefix).unwrap();
    send(&mut engine, &id);
    let mut provider_default = params.clone();
    provider_default["model"] = json!("default");
    engine.execute("agent.select", &provider_default).unwrap();
    send(&mut engine, &id);
    let mut both = high.clone();
    both["speed"] = json!("priority");
    engine.execute("agent.select", &both).unwrap();
    std::fs::write(root.join("fail-catalog"), b"synthetic").unwrap();
    refresh(&mut engine, "failed");
    engine
        .execute(
            "agent.select",
            &json!({"threadId":id,"effort":null,"speed":null}),
        )
        .unwrap();
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
    assert_eq!(caps["canReplaceUnprovedAutomaticDefault"], true);
    std::fs::remove_file(root.join("fail-catalog")).unwrap();
    std::fs::write(root.join("no-medium"), b"synthetic").unwrap();
    refresh(&mut engine, "ready");
    assert!(
        engine
            .execute(
                "agent.send",
                &json!({"threadId":id,"text":"no invented medium"})
            )
            .is_err()
    );
    engine.execute("agent.select", &high).unwrap();
    send(&mut engine, &id);
    engine
        .execute("agent.select", &json!({"threadId":id,"effort":null}))
        .unwrap();
    assert!(
        engine
            .execute(
                "agent.send",
                &json!({"threadId":id,"text":"still no invented medium"})
            )
            .is_err()
    );
    engine.execute("agent.select", &provider_default).unwrap();
    assert_eq!(
        engine.store.thread(&id).unwrap()["selection"]["modelID"],
        "default"
    );
}
#[test]
fn unproved_automatic_default_replacement_flag_never_unlocks_other_states() {
    let root = tempfile::tempdir().unwrap();
    let mut engine = Engine::fixture(Store::open(&root.path().join("state.sqlite")).unwrap());
    let mut thread = engine.execute("threads.create", &json!({})).unwrap();
    let id = text(&thread, "id");
    thread["selection"] =
        json!({"provider":"codex","modelID":"gpt-6-astra","effort":null,"speed":null});
    engine.store.save(&thread).unwrap();
    let caps = engine
        .execute("agent.selection.capabilities", &json!({"threadId":id}))
        .unwrap();
    assert_eq!(caps["locked"], true);
    assert_eq!(caps["canReplaceUnprovedAutomaticDefault"], true);
    for (key, value) in [
        ("botID", json!("frozen")),
        ("rustBotContext", json!({"selection":thread["selection"]})),
        ("accessMode", json!("unknown")),
    ] {
        let mut blocked = thread.clone();
        blocked[key] = value;
        engine.store.save(&blocked).unwrap();
        assert_eq!(
            engine
                .execute("agent.selection.capabilities", &json!({"threadId":id}))
                .unwrap()["canReplaceUnprovedAutomaticDefault"],
            false
        );
    }
    let mut named = thread.clone();
    named["selection"]["accountID"] = json!("named");
    engine.store.save(&named).unwrap();
    assert_eq!(
        engine
            .execute("agent.selection.capabilities", &json!({"threadId":id}))
            .unwrap()["canReplaceUnprovedAutomaticDefault"],
        false
    );
    engine.store.save(&thread).unwrap();
    engine.unsaved_threads.insert(id.clone(), thread.clone());
    assert_eq!(
        engine
            .execute("agent.selection.capabilities", &json!({"threadId":id}))
            .unwrap()["canReplaceUnprovedAutomaticDefault"],
        false
    );
    engine.unsaved_threads.remove(&id);
    engine.runs.insert(
        id.clone(),
        Running {
            resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
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
    assert_eq!(
        engine
            .execute("agent.selection.capabilities", &json!({"threadId":id}))
            .unwrap()["canReplaceUnprovedAutomaticDefault"],
        false
    );
    engine.runs.remove(&id);
    let mut imported = thread.clone();
    imported["id"] = json!(Uuid::new_v4().to_string());
    engine
        .store
        .import_cli_session(
            &imported,
            "ImportedSessions/astra-default-fixture.json",
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
            .unwrap()["canReplaceUnprovedAutomaticDefault"],
        false
    );
    assert!(
        engine
            .composer_thread_effort_proof(&imported)
            .unwrap()
            .is_none()
    );
    let mut bot = thread.clone();
    bot["rustBotContext"] = json!({"selection":thread["selection"]});
    assert!(engine.composer_thread_effort_proof(&bot).unwrap().is_none());
    engine.freeze_admissions();
    assert!(
        engine
            .execute("agent.selection.capabilities", &json!({"threadId":id}))
            .is_err()
    );
}
