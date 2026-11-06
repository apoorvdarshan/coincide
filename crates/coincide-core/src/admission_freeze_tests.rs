//! Trusted admission freeze with synthetic stores/workers, no provider processes.
use super::*;
use crate::schedule_service::{Outcome, ScheduleService, TargetState};
use std::sync::mpsc;
use std::time::Duration;

fn fixture() -> (tempfile::TempDir, Engine, String) {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("data/state.sqlite")).unwrap();
    let project = store.create_project(dir.path(), Some("fixture")).unwrap();
    let mut thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
    // Even a regressed dispatch guard must never launch a real provider.
    thread["selection"] = json!({"provider":"unsupported-freeze-fixture","modelID":"default"});
    store.save(&thread).unwrap();
    let id = text(&thread, "id");
    let mut engine = Engine::fixture(store);
    engine.schedule_initialized = true;
    engine.schedule_last_poll = Instant::now();
    (dir, engine, id)
}
fn assert_frozen(error: &Value) {
    assert_eq!(
        error["error"]["message"], "Engine admissions are frozen",
        "{error}"
    );
}
fn due_schedule(engine: &mut Engine, owner: &str) -> crate::schedule_service::DueJob {
    let thread = engine.store.thread(owner).unwrap();
    let old = chrono::Utc::now() - chrono::Duration::hours(1);
    let mut service = ScheduleService::new(&mut engine.store);
    let task = service
        .create(
            &json!({
                "name":"fixture", "prompt":"never submit", "threadID":owner,
                "projectID":thread["projectID"],
                "recurrence":{"kind":"interval","timeZoneID":"UTC","date":old,
                    "hour":0,"minute":0,"weekday":1,"intervalMinutes":5}
            }),
            old,
        )
        .unwrap();
    service.approve(task["id"].as_str().unwrap(), old).unwrap();
    service.plan_due(chrono::Utc::now()).unwrap().remove(0)
}
fn insert_worker(engine: &mut Engine, id: &str, session: Session) {
    engine.insert_running(
        id.into(),
        Running {
            configuration: None,
            resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
            usage_context: None,
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
}
fn wait_worker(observer: &agent::WorkerCompletion) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while observer.status() == agent::WorkerThreadStatus::Running {
        assert!(Instant::now() < deadline, "fake worker did not return");
        std::thread::yield_now();
    }
}

#[test]
fn freeze_is_irreversible_and_all_json_rejects_before_poll_or_routing() {
    let (_dir, mut engine, id) = fixture();
    assert!(!engine.admissions_frozen());
    let stored = engine.store.thread(&id).unwrap();
    let mut overlay = stored.clone();
    overlay["draft"] = json!("must not flush from rejected JSON");
    engine.unsaved_threads.insert(id.clone(), overlay.clone());
    engine.schedule_last_poll = Instant::now() - Duration::from_secs(2);
    let revision = engine.revision;
    engine.freeze_admissions();
    engine.freeze_admissions();
    engine.shutdown = true;
    engine.shutdown = false;
    assert!(engine.admissions_frozen());
    for method in [
        "app.status",
        "app.quit",
        "threads.read",
        "threads.patch",
        "agent.send",
        "agent.stop",
        "agent.queue.list",
        "workspace.result",
        "agent.models.status",
        "computer_use.result",
        "unknown",
    ] {
        let request = json!({"id":"freeze","method":method,"params":{}});
        let reply = engine.dispatch(request.clone());
        assert_frozen(&reply);
        assert_eq!(reply["id"], "freeze");
        assert_frozen(&engine.dispatch_scoped(request.clone(), Uuid::parse_str(&id).unwrap()));
        assert_frozen(
            &engine.dispatch_provider(request.clone(), Some(Uuid::parse_str(&id).unwrap())),
        );
        assert_frozen(&engine.dispatch_provider(request, None));
        assert_eq!(
            engine.execute(method, &json!({})).unwrap_err().to_string(),
            "Engine admissions are frozen"
        );
    }
    assert_eq!(engine.store.thread(&id).unwrap(), stored);
    assert_eq!(engine.unsaved_threads[&id], overlay);
    assert_eq!(engine.revision, revision);
    assert!(!engine.shutdown);
    assert!(engine.runs.is_empty());
    assert_eq!(engine.provider_workers_status().running, 0);
}

#[test]
fn frozen_queue_schedule_and_direct_launch_paths_create_no_new_work() {
    let (_dir, mut engine, id) = fixture();
    let mut thread = engine.store.thread(&id).unwrap();
    crate::message_queue::add(&mut thread, "never submit").unwrap();
    engine.store.save(&thread).unwrap();
    engine.enabled_queues.insert(id.clone());
    let job = due_schedule(&mut engine, &id);
    let schedules = engine.store.document("scheduled-tasks.json").unwrap();
    let revision = engine.revision;
    engine.freeze_admissions();
    for _ in 0..3 {
        engine.poll_message_queues();
        engine.poll_schedules(false).unwrap();
        engine.poll();
    }
    for error in [
        engine
            .send_turn(&json!({"threadId":id,"text":"never submit"}), false)
            .unwrap_err(),
        engine
            .queue_command("agent.queue.resume", &json!({"threadId":id}))
            .unwrap_err(),
        engine.launch_schedule(&job).unwrap_err(),
        engine.approve_schedule(&job.schedule_id).unwrap_err(),
    ] {
        assert_eq!(error.to_string(), "Engine admissions are frozen");
    }
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    assert_eq!(
        engine.store.document("scheduled-tasks.json").unwrap(),
        schedules
    );
    assert_eq!(engine.revision, revision);
    assert!(engine.enabled_queues.contains(&id));
    assert!(engine.runs.is_empty());
    assert_eq!(engine.provider_workers_status().running, 0);
    assert!(engine.schedule_completions.is_empty());
}

#[test]
fn frozen_draft_flush_is_narrow_bounded_and_retains_failed_input() {
    let (_dir, mut engine, id) = fixture();
    let mut pending = "unsent\nexact draft".to_owned();
    assert!(engine.persist_frozen_draft(&id, &pending).is_err());
    let before = engine.store.thread(&id).unwrap();
    let revision = engine.revision;
    engine.freeze_admissions();
    engine.unsaved_threads.insert(id.clone(), before.clone());
    assert!(engine.persist_frozen_draft(&id, &pending).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    assert_eq!(engine.revision, revision);
    engine.unsaved_threads.clear();
    let oversized = "x".repeat(1_048_577);
    assert!(engine.persist_frozen_draft(&id, &oversized).is_err());
    assert_eq!(engine.store.thread(&id).unwrap(), before);
    assert!(engine.persist_frozen_draft("missing", &pending).is_err());
    assert_eq!(pending, "unsent\nexact draft");
    engine.persist_frozen_draft(&id, &pending).unwrap();
    pending.clear(); // Caller relinquishes its copy only after persistence succeeds.
    let mut expected = before;
    expected["draft"] = json!("unsent\nexact draft");
    assert_eq!(engine.store.thread(&id).unwrap(), expected);
    assert_eq!(engine.revision, revision + 1);
    let boundary = "x".repeat(1_048_576);
    engine.persist_frozen_draft(&id, &boundary).unwrap();
    assert_eq!(engine.store.thread(&id).unwrap()["draft"], boundary);
    assert!(engine.admissions_frozen());
    assert_frozen(&engine.dispatch(json!({"method":"threads.patch"})));
}

#[test]
fn frozen_poll_retains_and_recovers_transcript_and_schedule_completions() {
    let (_dir, mut engine, id) = fixture();
    let job = due_schedule(&mut engine, &id);
    let claim = ScheduleService::new(&mut engine.store)
        .claim(&job, TargetState::Ready, chrono::Utc::now())
        .unwrap()
        .unwrap();
    let schedules = engine
        .store
        .document("scheduled-tasks.json")
        .unwrap()
        .unwrap();
    engine.schedule_completions.push((
        claim.claim_id,
        Outcome::Interrupted,
        Some("stopped".into()),
    ));
    engine
        .store
        .save_document(
            "scheduled-tasks.json",
            &json!({"version":1,"tasks":"invalid"}),
        )
        .unwrap();
    let mut overlay = engine.store.thread(&id).unwrap();
    overlay["items"] = Value::Null; // Real Store validation failure, no disk/OS fault injection.
    engine.unsaved_threads.insert(id.clone(), overlay.clone());
    engine.freeze_admissions();
    engine.schedule_last_poll = Instant::now() - Duration::from_secs(2);
    engine.poll();
    assert_eq!(engine.unsaved_threads[&id], overlay);
    assert_eq!(engine.schedule_completions.len(), 1);
    assert!(engine.schedule_error.is_some());
    engine
        .store
        .save_document("scheduled-tasks.json", &schedules)
        .unwrap();
    overlay["items"] = json!([]);
    overlay["draft"] = json!("recovered exact draft");
    engine.unsaved_threads.insert(id.clone(), overlay);
    engine.schedule_last_poll = Instant::now() - Duration::from_secs(2);
    engine.poll();
    assert!(engine.unsaved_threads.is_empty());
    assert!(engine.schedule_completions.is_empty());
    assert_eq!(
        engine.store.thread(&id).unwrap()["draft"],
        "recovered exact draft"
    );
    let task = ScheduleService::new(&mut engine.store)
        .list()
        .unwrap()
        .remove(0);
    assert!(task["rustClaim"].is_null());
    assert_eq!(task["lastOutcome"], "interrupted");
    assert!(engine.runs.is_empty());
    assert!(engine.admissions_frozen());
}

#[test]
fn trusted_stop_after_freeze_drains_fake_turn_without_claiming_thread_exit() {
    let (_dir, mut engine, id) = fixture();
    let (stopped_tx, stopped_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let session = Session::fixture_worker(move |commands, events| {
        assert!(matches!(commands.recv().unwrap(), agent::Control::Stop));
        events.send(Event::Finished).unwrap();
        stopped_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    });
    let observer = session.worker_completion();
    insert_worker(&mut engine, &id, session);
    engine.enabled_queues.insert(id.clone());
    engine.freeze_admissions();
    assert_frozen(&engine.dispatch(json!({"method":"agent.stop","params":{"threadId":id}})));
    assert!(!engine.runs[&id].cancelled);
    engine.request_provider_stop(&id).unwrap();
    assert!(engine.runs[&id].cancelled);
    assert!(!engine.enabled_queues.contains(&id));
    stopped_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    engine.poll();
    assert!(engine.runs.is_empty());
    assert_eq!(engine.provider_workers_status().running, 1);
    release_tx.send(()).unwrap();
    wait_worker(&observer);
    assert_eq!(engine.provider_workers_status().returned, 1);
    assert!(engine.admissions_frozen());
}

#[test]
fn frozen_poll_drains_saturated_attachment_and_persists_existing_admitted_work() {
    let (dir, mut engine, id) = fixture();
    let source = dir.path().join("source.png");
    image::RgbaImage::from_pixel(2, 2, image::Rgba([1, 2, 3, 255]))
        .save(&source)
        .unwrap();
    let root = engine.store.data_directory().unwrap();
    let operation = Uuid::new_v4().to_string();
    engine
        .workspace_pending
        .insert(operation.clone(), (id.clone(), Instant::now()));
    engine.attachment_operations.insert(operation.clone());
    let (tx, rx) = mpsc::sync_channel(32);
    engine.workspace_tx = tx.clone();
    engine.workspace_rx = rx;
    for index in 0..32 {
        tx.try_send((format!("unrelated-{index}"), json!({})))
            .unwrap();
    }
    let (saturated_tx, saturated_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let imported = operation.clone();
    let worker = std::thread::spawn(move || {
        import_attachment(root, source, tx, imported, || {
            saturated_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        });
    });
    saturated_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    engine.freeze_admissions();
    engine.poll();
    assert!(engine.attachment_operations.contains(&operation));
    release_tx.send(()).unwrap();
    worker.join().unwrap(); // Fixture owner only; Engine never joins this worker.
    engine.poll();
    assert!(!engine.attachment_operations.contains(&operation));
    assert!(engine.workspace_results[&operation]["error"].is_null());
    assert_eq!(
        engine.store.thread(&id).unwrap()["rustDraftImages"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(engine.admissions_frozen());
    assert_frozen(&engine.dispatch(json!({"method":"workspace.result"})));
}
