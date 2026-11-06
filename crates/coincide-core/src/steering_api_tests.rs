use super::*;
fn fixture() -> (
    tempfile::TempDir,
    Engine,
    String,
    agent::codex_steering::Server,
) {
    let dir = tempfile::tempdir().unwrap();
    let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    let thread = engine
        .execute("threads.create", &json!({"cwd":dir.path()}))
        .unwrap();
    let id = thread["id"].as_str().unwrap().to_owned();
    let mut session = Session::fixture_worker(|commands, events| {
        let _ = commands.recv();
        let _ = events.send(Event::Finished);
    });
    let mut server = session.fixture_steering();
    server.activate("native-thread", "native-turn");
    engine.insert_running(
        id.clone(),
        Running {
            configuration: None,
            resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
            session,
            usage_context: Some(agent::usage_capture::TurnContext::new(&thread)),
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
    (dir, engine, id, server)
}
#[test]
fn pending_is_not_accepted_and_ack_text_is_persisted_once_without_touching_draft() {
    let (_dir, mut engine, id, mut server) = fixture();
    let mut thread = engine.store.thread(&id).unwrap();
    thread["draft"] = json!("retain draft");
    engine.store.save(&thread).unwrap();
    let pending = engine
        .execute("agent.steer", &json!({"threadId":id,"text":"follow-up"}))
        .unwrap();
    assert_eq!(pending["status"], "pending");
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    let request = server.next_request().unwrap();
    server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}}));
    engine.poll();
    engine.poll();
    let stored = engine.store.thread(&id).unwrap();
    assert_eq!(stored["draft"], "retain draft");
    assert_eq!(
        stored["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| item["steered"] == true)
            .count(),
        1
    );
    assert_eq!(
        engine
            .execute(
                "agent.steer.result",
                &json!({"threadId":id,"operationId":pending["operationId"]})
            )
            .unwrap()["status"],
        "accepted"
    );
}
#[test]
fn strict_identity_options_context_provider_and_frozen_guards_preserve_thread() {
    let (_dir, mut engine, id, _server) = fixture();
    let before = engine.store.thread(&id).unwrap();
    let revision = engine.revision;
    for extra in [
        json!({"model":"other"}),
        json!({"expectedTurnId":"spoof"}),
        json!({"images":[]}),
    ] {
        let mut params = json!({"threadId":id,"text":"x"});
        params
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        assert!(engine.execute("agent.steer", &params).is_err());
    }
    for key in ["draftContext", "rustDraftImages"] {
        let mut thread = before.clone();
        thread[key] = json!([{"synthetic":true}]);
        engine.store.save(&thread).unwrap();
        assert!(
            engine
                .execute("agent.steer", &json!({"threadId":id,"text":"x"}))
                .is_err()
        );
    }
    engine.store.save(&before).unwrap();
    engine.runs.get_mut(&id).unwrap().provider = "claude".into();
    assert!(
        engine
            .execute("agent.steer", &json!({"threadId":id,"text":"x"}))
            .is_err()
    );
    engine.freeze_admissions();
    assert!(
        engine
            .execute("agent.steer", &json!({"threadId":id,"text":"x"}))
            .is_err()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    assert_eq!(engine.revision, revision);
    assert!(engine.steering_operations.is_empty());
}
#[test]
fn accepted_but_unsaved_text_blocks_owner_drain_and_retries_without_duplicate_item() {
    let (dir, mut engine, id, mut server) = fixture();
    let pending = engine
        .execute(
            "agent.steer",
            &json!({"threadId":id,"text":"retained accepted text"}),
        )
        .unwrap();
    let db = rusqlite::Connection::open(dir.path().join("state.sqlite")).unwrap();
    db.execute_batch("CREATE TRIGGER fail_steer BEFORE UPDATE ON threads BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;").unwrap();
    let request = server.next_request().unwrap();
    server.response(&json!({"id":request["id"],"result":{"turnId":"native-turn"}}));
    engine.freeze_admissions();
    engine.poll();
    assert_eq!(engine.pending_steering_count(), 1);
    assert!(!engine.unsaved_threads.is_empty());
    assert!(engine.close_store_after_core_shutdown().is_err());
    db.execute_batch("DROP TRIGGER fail_steer;").unwrap();
    engine.poll();
    engine.poll();
    assert_eq!(engine.pending_steering_count(), 0);
    let stored = engine.store.thread(&id).unwrap();
    assert_eq!(
        stored["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| item["id"] == pending["operationId"])
            .count(),
        1
    );
}

#[test]
fn steering_uses_immutable_running_configuration_after_native_settings_change() {
    let (root, mut engine, binary) = provider_configuration::tests::fixture();
    provider_configuration::tests::save(&mut engine, "codex", &binary, "first-synthetic-value");
    let captured = engine
        .provider_launch_configuration("codex")
        .unwrap()
        .unwrap();
    let thread = engine
        .execute("threads.create", &json!({"cwd":root.path()}))
        .unwrap();
    let id = text(&thread, "id");
    let mut thread = thread;
    thread["selection"] =
        json!({"provider":"codex","modelID":"fixture-configured-model","effort":"high"});
    engine.store.save(&thread).unwrap();
    {
        let _scope = provider_configuration::enter(Some(captured.clone()));
        engine
            .model_catalog
            .fixture_reported_configuration_effort(&binary)
            .unwrap();
    }
    let mut session = Session::fixture_worker(|commands, events| {
        let _ = commands.recv();
        let _ = events.send(Event::Finished);
    });
    let mut server = session.fixture_steering();
    server.activate("configured-native-thread", "configured-native-turn");
    engine.insert_running(
        id.clone(),
        Running {
            configuration: Some(captured.clone()),
            resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
            usage_context: Some(agent::usage_capture::TurnContext::new(&thread)),
            session,
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
    provider_configuration::tests::save(&mut engine, "codex", &binary, "second-synthetic-value");
    let future = engine
        .provider_launch_configuration("codex")
        .unwrap()
        .unwrap();
    assert_ne!(future.stamp(), captured.stamp());
    let pending = engine
        .execute(
            "agent.steer",
            &json!({"threadId":id,"text":"synthetic follow-up"}),
        )
        .unwrap();
    assert_eq!(pending["status"], "pending");
    assert!(server.next_request().is_some());
    assert_eq!(
        engine.runs[&id].configuration.as_ref().unwrap().stamp(),
        captured.stamp()
    );
    {
        let _future = provider_configuration::enter(Some(future));
        assert!(engine.composer_thread_effort_proof(&thread).is_err());
    }
}
