//! Synthetic provider sessions exercise both the phone adapter and Engine gate.
use super::*;
use crate::remote::{
    adapter::Adapter,
    pairing::{MemoryDeviceStorage, Pairing},
    protocol::ErrorCode,
    session::{Context, SeenBus, Session as PhoneSession},
};
use std::sync::{atomic::AtomicU64, mpsc};

#[test]
fn remote_question_dismissal_uses_the_active_providers_cancel_shape() {
    for (provider, expected) in [
        ("codex", json!({"answers":{}})),
        ("claude", json!({"answers":{}})),
        ("cursor", json!({"decision":"cancel"})),
        ("grok", json!({"decision":"cancel"})),
        ("opencode", json!({"decision":"cancel"})),
        ("antigravity", json!({"decision":"cancel"})),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        let thread = engine
            .execute("threads.create", &json!({"cwd":dir.path()}))
            .unwrap();
        let id = text(&thread, "id");
        let thread_id = Uuid::parse_str(&id).unwrap();
        let mut document = engine.store.thread(&id).unwrap();
        append(&mut document, "question", "Question?", Some("42"));
        let item = Uuid::parse_str(document["items"][0]["id"].as_str().unwrap()).unwrap();
        engine.store.save(&document).unwrap();
        let (sent, received) = mpsc::channel();
        let session = Session::fixture_worker(move |commands, _| {
            if let Ok(command) = commands.recv() {
                let _ = sent.send(command);
            }
        });
        let pending = HashMap::from([(
            "42".to_owned(),
            json!({
                "id":42,
                "method":"item/tool/requestUserInput",
                "params":{"questions":[{"id":"q", "question":"Question?"}]}
            }),
        )]);
        engine.insert_running(
            id.clone(),
            Running {
                configuration: None,
                usage_context: None,
                resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
                session,
                provider: provider.into(),
                transcript_start: 0,
                pending,
                schedule_claim: None,
                queue_claim: None,
                cancelled: false,
                events: VecDeque::new(),
                persistence_error: None,
            },
        );
        let shared = Arc::new(Mutex::new(engine));
        let adapter = Adapter::new(shared.clone(), "fixture");
        let runs = adapter.runs().unwrap();
        assert_eq!(
            adapter
                .dismiss_question(thread_id, Uuid::new_v4(), &runs)
                .unwrap_err()
                .code,
            ErrorCode::NotFound,
            "{provider}: an unrelated item must not dismiss the question"
        );
        assert!(received.try_recv().is_err());
        {
            let mut engine = shared.lock().unwrap();
            engine
                .runs
                .get_mut(&id)
                .unwrap()
                .pending
                .get_mut("42")
                .unwrap()["method"] = json!("item/commandExecution/requestApproval");
            assert!(
                engine
                    .execute(
                        "agent.dismissQuestion",
                        &json!({"threadId":id,"itemId":item})
                    )
                    .is_err()
            );
            engine
                .runs
                .get_mut(&id)
                .unwrap()
                .pending
                .get_mut("42")
                .unwrap()["method"] = json!("item/tool/requestUserInput");
        }
        assert!(
            received.try_recv().is_err(),
            "an approval must not be dismissed as a question"
        );
        let mut pairing = Pairing::new(Box::new(MemoryDeviceStorage::default())).unwrap();
        let secret = pairing.make_secret().value;
        let pairing = Mutex::new(pairing);
        let seen = SeenBus::default();
        let usage = Mutex::new(Vec::new());
        let sidebar_revision = AtomicU64::new(0);
        let server_info = || adapter.server_info("fixture", "Fixture");
        let context = Context {
            adapter: &adapter,
            pairing: &pairing,
            server_info: &server_info,
            seen: &seen,
            usage: &usage,
            sidebar_revision: &sidebar_revision,
        };
        let mut phone = PhoneSession::new("127.0.0.1");
        phone.receive(&serde_json::to_vec(&json!({"v":1,"id":"pair","type":"pair","body":{"secret":secret,"deviceName":"Fixture phone"}})).unwrap(), &context);
        assert_eq!(phone.take_outgoing()[0]["type"], "paired");
        phone.receive(&serde_json::to_vec(&json!({"v":1,"id":"dismiss","type":"dismissQuestion","body":{"threadID":thread_id,"itemID":item}})).unwrap(), &context);
        let response = phone.take_outgoing();
        assert_eq!(response[0]["type"], "ok", "{provider}");
        assert_eq!(response[0]["re"], "dismiss");
        match received.recv_timeout(Duration::from_secs(3)).unwrap() {
            agent::Control::Reply { id, result } => {
                assert_eq!(id, json!(42));
                assert_eq!(result, expected, "{provider}");
            }
            _ => panic!("{provider}: dismissal sent the wrong command"),
        }
        let engine = shared.lock().unwrap();
        let saved = engine.store.thread(&id).unwrap();
        assert_eq!(saved["items"][0]["status"], "declined");
        assert!(saved["items"][0]["completedAt"].is_number());
        assert!(engine.runs[&id].pending.is_empty());
        drop(engine);
        let fresh_runs = adapter.runs().unwrap();
        assert_eq!(
            adapter
                .dismiss_question(thread_id, item, &fresh_runs)
                .unwrap_err()
                .code,
            ErrorCode::NotAllowed
        );
    }
    assert!(question_dismissal("unknown-provider").is_err());
}
