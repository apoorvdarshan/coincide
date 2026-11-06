use super::*;
fn snapshot() -> agent::usage_capture::Snapshot {
    let mut capture = agent::usage_capture::Capture::default();
    capture.bind_thread("existing-native-session");
    capture.bind_turn(&json!("turn-fixture"));
    capture.update(&json!({"threadId":"existing-native-session","turnId":"turn-fixture","tokenUsage":{"last":{"totalTokens":15},"total":{"totalTokens":500},"future":42}}));
    capture.complete(&json!({"threadId":"existing-native-session","turn":{"id":"turn-fixture","status":"completed"}})).unwrap()
}
#[test]
fn failed_atomic_finish_retains_usage_after_run_retirement_and_shutdown_retry_deduplicates() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("state.sqlite");
    let mut engine = Engine::fixture(Store::open(&path).unwrap());
    let mut before = engine.execute("threads.create", &json!({})).unwrap();
    before["future"] = json!({"keep":true});
    engine.store.save(&before).unwrap();
    let id = before["id"].as_str().unwrap().to_owned();
    let old = json!([{"id":Uuid::new_v4(),"unknown":{"keep":"exact"}}]);
    engine
        .store
        .save_document("usage-history.json", &old)
        .unwrap();
    let db = rusqlite::Connection::open(&path).unwrap();
    db.execute_batch("CREATE TRIGGER fail_usage BEFORE INSERT ON documents WHEN NEW.name='usage-history.json' BEGIN SELECT RAISE(ABORT,'synthetic usage failure'); END;").unwrap();
    let (sent, ready) = std::sync::mpsc::channel();
    let session = Session::fixture_worker(move |_, events| {
        events.send(Event::Finished).unwrap();
        sent.send(()).unwrap();
    });
    session.fixture_usage(snapshot());
    ready.recv().unwrap();
    engine.insert_running(
        id.clone(),
        Running {
            resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
            usage_context: Some(agent::usage_capture::TurnContext::new(&before)),
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
    engine.freeze_admissions();
    engine.poll();
    assert!(!engine.runs.contains_key(&id));
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    assert_eq!(
        engine.store.document("usage-history.json").unwrap(),
        Some(old.clone())
    );
    assert_eq!(engine.unsaved_threads.len(), 1);
    assert_eq!(engine.pending_usage.len(), 1);
    let retained = engine.pending_usage[&id].0.clone();
    assert!(
        !engine
            .poll_core_owner_shutdown()
            .unwrap()
            .rust_owners_drained()
    );
    assert!(engine.close_store_after_core_shutdown().is_err());
    db.execute_batch("DROP TRIGGER fail_usage;").unwrap();
    engine.schedule_last_poll = Instant::now() - Duration::from_secs(2);
    engine.poll();
    assert!(engine.pending_usage.is_empty());
    assert!(engine.unsaved_threads.is_empty());
    let history = engine
        .store
        .document("usage-history.json")
        .unwrap()
        .unwrap();
    assert_eq!(history, json!([old[0], retained]));
    assert_eq!(
        engine.store.thread(&id).unwrap()["future"],
        before["future"]
    );
    engine.schedule_last_poll = Instant::now() - Duration::from_secs(2);
    engine.poll();
    assert_eq!(
        engine.store.document("usage-history.json").unwrap(),
        Some(history)
    );
}
#[test]
fn unknown_thread_marker_cannot_authorize_history_write() {
    let dir = tempfile::tempdir().unwrap();
    let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    let mut thread = engine.execute("threads.create", &json!({})).unwrap();
    thread["rustPendingUsageRecord"] =
        json!({"id":Uuid::new_v4(),"usage":{"turnTotals":{"input":999}}});
    engine.store.save(&thread).unwrap();
    engine
        .unsaved_threads
        .insert(thread["id"].as_str().unwrap().into(), thread.clone());
    engine.freeze_admissions();
    engine.schedule_last_poll = Instant::now() - Duration::from_secs(2);
    engine.poll();
    assert!(
        engine
            .store
            .document("usage-history.json")
            .unwrap()
            .is_none()
    );
    assert_eq!(
        engine.store.thread(thread["id"].as_str().unwrap()).unwrap(),
        thread
    );
}

#[test]
fn history_append_rolls_back_with_thread_failure_preserves_captured_bytes_and_retries_exact_uuid() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("state.sqlite");
    let mut store = Store::open(&path).unwrap();
    let before = store.new_thread("").unwrap();
    let db = rusqlite::Connection::open(&path).unwrap();
    let captured = format!(
        "[ {{ \"id\": \"{}\", \"unknown\": {{\"keep\":true}} }} ]\n",
        Uuid::new_v4()
    )
    .into_bytes();
    db.execute(
        "INSERT INTO original_files(path,data) VALUES ('usage-history.json',?1)",
        [&captured],
    )
    .unwrap();
    let record = agent::usage_capture::TurnContext::new(&before)
        .finish(snapshot())
        .0;
    let mut changed = before.clone();
    changed["draft"] = json!("synthetic changed draft");
    db.execute_batch("CREATE TRIGGER fail_thread BEFORE UPDATE ON threads BEGIN SELECT RAISE(ABORT,'synthetic thread failure'); END;").unwrap();
    assert!(store.save_with_usage(&changed, Some(&record)).is_err());
    assert_eq!(
        store.thread(before["id"].as_str().unwrap()).unwrap(),
        before
    );
    assert!(
        store
            .local_document("usage-history.json")
            .unwrap()
            .is_none()
    );
    assert_eq!(
        store.original("usage-history.json").unwrap(),
        Some(captured.clone())
    );
    db.execute_batch("DROP TRIGGER fail_thread;").unwrap();
    store.save_with_usage(&changed, Some(&record)).unwrap();
    let history = store.document("usage-history.json").unwrap().unwrap();
    assert_eq!(history.as_array().unwrap().len(), 2);
    assert_eq!(history[1], record);
    store.save_with_usage(&changed, Some(&record)).unwrap();
    assert_eq!(
        store.document("usage-history.json").unwrap(),
        Some(history.clone())
    );
    let mut wrong = record.clone();
    wrong["usage"] = json!({"inputTokens":999});
    assert!(store.save_with_usage(&before, Some(&wrong)).is_err());
    assert_eq!(
        store.thread(before["id"].as_str().unwrap()).unwrap(),
        changed
    );
    assert_eq!(store.document("usage-history.json").unwrap(), Some(history));
    assert_eq!(
        store.original("usage-history.json").unwrap(),
        Some(captured)
    );
}
