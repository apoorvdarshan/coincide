use super::*;
use std::sync::mpsc;

fn fixture() -> (tempfile::TempDir, Engine, String) {
    let directory = tempfile::tempdir().unwrap();
    let mut engine = Engine::new(Store::open(&directory.path().join("data.sqlite")).unwrap());
    let id = engine
        .store
        .new_thread("00000000-0000-0000-0000-000000000000")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    (directory, engine, id)
}
fn run(engine: &mut Engine, id: &str) -> mpsc::Sender<Event> {
    // Replace only the public event receiver; no actual provider executable exists.
    let mut session = Session::start(Launch {
        executable: PathBuf::from("/nonexistent-coincide-notification-fixture"),
        cwd: std::env::temp_dir(),
        session: None,
        prompt: String::new(),
        model: None,
        variant: None,
        full_access: false,
    });
    let (sender, receiver) = mpsc::channel();
    session.events = receiver;
    let transcript_start = engine.store.thread(id).unwrap()["items"]
        .as_array()
        .unwrap()
        .len();
    engine.runs.insert(
        id.into(),
        Running {
            configuration: None,
            resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
            usage_context: None,
            session,
            provider: "codex".into(),
            transcript_start,
            pending: HashMap::new(),
            schedule_claim: None,
            queue_claim: None,
            cancelled: false,
            events: VecDeque::new(),
            persistence_error: None,
        },
    );
    sender
}
/// Swift stores no synthetic "turn ended" item, so a finished turn's alert is
/// anchored to the reply it produced. Give these fixtures that reply first.
fn seed_reply(engine: &mut Engine, id: &str) {
    let mut thread = engine.store.thread(id).unwrap();
    append(&mut thread, "assistant", "Fixture reply", None);
    engine.store.save(&thread).unwrap();
}
fn approval(id: u64) -> Event {
    Event::Frame(
        json!({"id":id,"method":"item/commandExecution/requestApproval","params":{"command":"private fixture text must not be exposed"}}),
    )
}

#[test]
fn default_disabled_native_only_opt_in_and_no_startup_backlog() {
    let (directory, mut engine, id) = fixture();
    let sender = run(&mut engine, &id);
    sender.send(Event::Finished).unwrap();
    engine.poll();
    assert!(engine.claim_notification_events(16).is_empty());
    assert_eq!(
        engine.execute("notifications.status", &json!({})).unwrap()["enabled"],
        false
    );
    assert!(
        engine
            .execute("notifications.configure", &json!({"enabled":true}))
            .is_err()
    );
    engine.configure_native_notifications(true).unwrap();
    assert!(engine.claim_notification_events(16).is_empty());
    drop(engine);
    let mut restarted = Engine::new(Store::open(&directory.path().join("data.sqlite")).unwrap());
    assert_eq!(restarted.notification_events.status()["enabled"], true);
    assert!(restarted.claim_notification_events(16).is_empty());
}

#[test]
fn imported_opt_in_and_transcripts_do_not_enable_or_replay() {
    let directory = tempfile::tempdir().unwrap();
    let mut engine = Engine::new(Store::open(&directory.path().join("data.sqlite")).unwrap());
    let original = directory.path().join("original");
    std::fs::create_dir_all(original.join("threads")).unwrap();
    std::fs::write(original.join(DOCUMENT), br#"{"version":1,"enabled":true}"#).unwrap();
    engine.store.import_legacy(&original).unwrap();
    // Captured original must exist so this tests local-vs-imported distinction.
    assert!(engine.store.original(DOCUMENT).unwrap().is_some());
    assert!(engine.store.local_document(DOCUMENT).unwrap().is_none());
    let restored = Outbox::new(&engine.store);
    assert!(!restored.enabled);
}

#[test]
fn persisted_completion_has_exact_uuid_private_body_and_no_inflight_replay() {
    let (_directory, mut engine, id) = fixture();
    engine.configure_native_notifications(true).unwrap();
    seed_reply(&mut engine, &id);
    let sender = run(&mut engine, &id);
    sender.send(Event::Finished).unwrap();
    engine.poll();
    let claim = engine.claim_notification_events(1).pop().unwrap();
    let saved = engine.store.thread(&id).unwrap();
    assert_eq!(
        Uuid::parse_str(
            saved["items"].as_array().unwrap().last().unwrap()["id"]
                .as_str()
                .unwrap()
        )
        .unwrap(),
        claim.alert.key.item
    );
    assert_eq!(claim.alert.key.thread, Uuid::parse_str(&id).unwrap());
    assert_eq!(claim.alert.key.kind, AlertKind::Completed);
    // Swift shows the reply that arrived, not an empty body.
    assert_eq!(claim.alert.body.as_deref(), Some("Fixture reply"));
    assert!(engine.claim_notification_events(16).is_empty());
    assert!(
        engine
            .ack_notification_event(Uuid::new_v4(), claim.alert.key, NotificationAck::Suppressed)
            .is_err()
    );
    engine
        .ack_notification_event(
            claim.claim_id,
            claim.alert.key,
            NotificationAck::Delivered(Delivery::Uncertain),
        )
        .unwrap();
    assert!(engine.retry_notification_event(claim.alert.key).is_err());
    assert!(engine.claim_notification_events(16).is_empty());
    assert_eq!(engine.notification_events.status()["uncertain"], 1);
}

#[test]
fn duplicate_provider_request_keeps_persisted_item_uuid_and_cancel_removes_queued_alert() {
    let (_directory, mut engine, id) = fixture();
    engine.configure_native_notifications(true).unwrap();
    let sender = run(&mut engine, &id);
    sender.send(approval(8)).unwrap();
    engine.poll();
    let original = engine.store.thread(&id).unwrap()["items"][0]["id"].clone();
    sender.send(approval(8)).unwrap();
    engine.poll();
    let thread = engine.store.thread(&id).unwrap();
    assert_eq!(thread["items"].as_array().unwrap().len(), 1);
    assert_eq!(thread["items"][0]["id"], original);
    assert_eq!(engine.notification_events.status()["queued"], 1);
    sender
        .send(Event::Frame(
            json!({"method":"provider/requestCancelled","params":{"id":8}}),
        ))
        .unwrap();
    engine.poll();
    assert!(engine.claim_notification_events(16).is_empty());
    assert_eq!(
        engine.store.thread(&id).unwrap()["items"][0]["id"],
        original
    );
}

#[test]
fn question_and_failure_are_distinct_and_interrupted_turn_is_silent() {
    let (_directory, mut engine, id) = fixture();
    engine.configure_native_notifications(true).unwrap();
    let sender = run(&mut engine, &id);
    sender.send(Event::Frame(json!({"id":"question-fixture","method":"item/tool/requestUserInput","params":{"questions":[]}}))).unwrap();
    engine.poll();
    let claim = engine.claim_notification_events(1).pop().unwrap();
    assert_eq!(claim.alert.key.kind, AlertKind::Question);
    // This fixture asks no questions, so there is nothing to show.
    assert!(claim.alert.body.is_none());
    engine
        .ack_notification_event(claim.claim_id, claim.alert.key, NotificationAck::Suppressed)
        .unwrap();
    sender
        .send(Event::Failed("private failure message".into()))
        .unwrap();
    engine.poll();
    let failure = engine.claim_notification_events(1).pop().unwrap();
    assert_eq!(failure.alert.key.kind, AlertKind::Failed);
    assert!(!failure.alert.title.contains("private"));
    engine
        .ack_notification_event(
            failure.claim_id,
            failure.alert.key,
            NotificationAck::Delivered(Delivery::Accepted),
        )
        .unwrap();
    let sender = run(&mut engine, &id);
    engine.runs.get_mut(&id).unwrap().cancelled = true;
    sender.send(Event::Failed("stopped".into())).unwrap();
    engine.poll();
    assert!(engine.claim_notification_events(16).is_empty());
}

#[test]
fn definite_unavailable_needs_explicit_bounded_retry_and_new_attempt_id() {
    let (_directory, mut engine, id) = fixture();
    engine.configure_native_notifications(true).unwrap();
    seed_reply(&mut engine, &id);
    let sender = run(&mut engine, &id);
    sender.send(Event::Finished).unwrap();
    engine.poll();
    let mut previous = None;
    for attempt in 1..=MAX_ATTEMPTS {
        let claim = engine.claim_notification_events(1).pop().unwrap();
        if let Some(old) = previous {
            assert_ne!(old, claim.claim_id);
            assert!(
                engine
                    .ack_notification_event(old, claim.alert.key, NotificationAck::Cancelled)
                    .is_err()
            );
        }
        engine
            .ack_notification_event(
                claim.claim_id,
                claim.alert.key,
                NotificationAck::Delivered(Delivery::Unavailable),
            )
            .unwrap();
        assert!(engine.claim_notification_events(16).is_empty());
        if attempt == MAX_ATTEMPTS {
            assert!(engine.retry_notification_event(claim.alert.key).is_err());
        } else {
            engine.retry_notification_event(claim.alert.key).unwrap();
        }
        previous = Some(claim.claim_id);
    }
}

#[test]
fn persistence_failure_defers_alert_and_retry_promotes_original_uuid_once() {
    let (directory, mut engine, id) = fixture();
    engine.configure_native_notifications(true).unwrap();
    seed_reply(&mut engine, &id);
    let connection = rusqlite::Connection::open(directory.path().join("data.sqlite")).unwrap();
    connection.execute_batch("CREATE TRIGGER fail_notification_save BEFORE UPDATE ON threads BEGIN SELECT RAISE(ABORT,'fixture write unavailable'); END;").unwrap();
    let sender = run(&mut engine, &id);
    sender.send(Event::Finished).unwrap();
    engine.poll();
    assert!(engine.claim_notification_events(16).is_empty());
    assert_eq!(
        engine.notification_events.status()["awaitingPersistence"],
        1
    );
    let item = engine.unsaved_threads[&id]["items"]
        .as_array()
        .unwrap()
        .last()
        .unwrap()["id"]
        .clone();
    connection
        .execute_batch("DROP TRIGGER fail_notification_save;")
        .unwrap();
    engine.schedule_last_poll = Instant::now() - Duration::from_secs(2);
    engine.poll();
    let claim = engine.claim_notification_events(1).pop().unwrap();
    assert_eq!(
        claim.alert.key.item,
        Uuid::parse_str(item.as_str().unwrap()).unwrap()
    );
    assert!(engine.unsaved_threads.is_empty());
    engine
        .ack_notification_event(
            claim.claim_id,
            claim.alert.key,
            NotificationAck::Delivered(Delivery::Accepted),
        )
        .unwrap();
    engine.poll();
    assert!(engine.claim_notification_events(16).is_empty());
}

#[test]
fn session_queue_is_bounded_and_disabling_discards_queued_not_unknown_inflight() {
    let (_directory, mut engine, id) = fixture();
    engine.configure_native_notifications(true).unwrap();
    let mut thread = engine.store.thread(&id).unwrap();
    for _ in 0..QUEUE_LIMIT + 1 {
        append(&mut thread, "notice", "Turn ended", None);
        let item = thread["items"].as_array().unwrap().last().unwrap();
        engine
            .notification_events
            .stage(&thread, item, AlertKind::Completed, None);
    }
    engine.store.save(&thread).unwrap();
    engine.notification_events.persisted(&thread);
    assert_eq!(engine.notification_events.entries.len(), QUEUE_LIMIT);
    assert_eq!(engine.notification_events.status()["overflow"], 1);
    let claims = engine.claim_notification_events(usize::MAX);
    assert_eq!(claims.len(), 16);
    engine.configure_native_notifications(false).unwrap();
    assert_eq!(engine.notification_events.entries.len(), 16);
    for claim in claims {
        engine
            .ack_notification_event(claim.claim_id, claim.alert.key, NotificationAck::Cancelled)
            .unwrap();
    }
    engine.configure_native_notifications(true).unwrap();
    assert!(engine.claim_notification_events(16).is_empty());
}
