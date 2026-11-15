//! Disposable runs only: Remote must never hide an active conversation.
use super::*;
use crate::remote::{
    adapter::Adapter,
    protocol::{ErrorCode, ThreadAction},
};

#[test]
fn remote_settle_and_archive_refuse_an_active_run_without_losing_markers() {
    let dir = tempfile::tempdir().unwrap();
    let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    let thread = engine
        .execute("threads.create", &json!({"cwd":dir.path()}))
        .unwrap();
    let id = text(&thread, "id");
    let thread_id = Uuid::parse_str(&id).unwrap();
    engine
        .store
        .save_document(
            "ui-state.json",
            &json!({
                "settledThreads": {(&id): crate::store::swift_timestamp() + 3600.},
                "future": {"keep": true}
            }),
        )
        .unwrap();
    let session = Session::fixture_worker(|commands, _| {
        let _ = commands.recv();
    });
    engine.insert_running(
        id.clone(),
        Running {
            configuration: None,
            usage_context: None,
            resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
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
    let shared = Arc::new(Mutex::new(engine));
    let adapter = Adapter::new(shared.clone(), "fixture");
    let before = shared
        .lock()
        .unwrap()
        .store
        .document("ui-state.json")
        .unwrap()
        .unwrap();
    assert_eq!(
        adapter
            .perform(thread_id, &ThreadAction::Settle(true))
            .unwrap_err()
            .code,
        ErrorCode::NotAllowed
    );
    assert_eq!(
        adapter
            .perform(thread_id, &ThreadAction::Archive(true))
            .unwrap_err()
            .code,
        ErrorCode::NotAllowed
    );
    assert_eq!(
        shared
            .lock()
            .unwrap()
            .store
            .document("ui-state.json")
            .unwrap()
            .unwrap(),
        before
    );
    assert_eq!(before["future"]["keep"], true);
    let runs = adapter.runs().unwrap();
    let workspace = adapter.workspace(false, &runs).unwrap();
    let visible = workspace
        .threads
        .iter()
        .find(|thread| thread.id == id)
        .unwrap();
    assert!(visible.is_running && visible.is_settled && !visible.is_hidden);
    assert_ne!(
        shared.lock().unwrap().store.thread(&id).unwrap()["isArchived"],
        true
    );
    adapter
        .perform(thread_id, &ThreadAction::MarkUnread)
        .unwrap();
    assert_eq!(
        shared
            .lock()
            .unwrap()
            .store
            .document("ui-state.json")
            .unwrap()
            .unwrap()["unseen"][&id],
        "completed"
    );
}
