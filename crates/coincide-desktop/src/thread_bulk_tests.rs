use super::*;
use std::sync::atomic::AtomicUsize;
fn binding(count: usize) -> Binding {
    Binding {
        rows: (0..count)
            .map(|n| (format!("thread-{n:03}"), false, false))
            .collect(),
        available: true,
        ..Default::default()
    }
}
fn wait(state: &mut State) {
    let end = Instant::now() + Duration::from_secs(5);
    while state.shutdown_status().unjoined != 0 {
        assert!(Instant::now() < end, "fake worker did not join");
        std::thread::yield_now();
    }
}
#[::core::prelude::v1::test]
fn select_visible_never_truncates_and_manual_selection_is_bounded_to_real_visible_rows() {
    let mut state = State::default();
    state.sync(binding(51));
    state.mode = true;
    assert!(state.select_visible().is_err());
    assert!(state.picked.is_empty());
    for n in 0..50 {
        state.toggle(&format!("thread-{n:03}")).unwrap();
    }
    assert!(state.toggle("thread-050").is_err());
    assert_eq!(state.picked.len(), 50);
    assert!(state.toggle("hidden-thread").is_err());
    assert_eq!(state.picked.len(), 50);
    state.toggle("thread-000").unwrap();
    state.toggle("thread-050").unwrap();
    assert_eq!(state.picked.len(), 50);
    state.sync(binding(3));
    assert_eq!(state.picked.len(), 2);
    state.select_visible().unwrap();
    assert_eq!(state.picked.len(), 3);
}
#[::core::prelude::v1::test]
fn filter_project_route_and_summary_changes_revoke_review_without_selecting_a_conversation() {
    let mut state = State::default();
    state.sync(binding(3));
    state.mode = true;
    state.toggle("thread-000").unwrap();
    let mut current = state.binding.clone();
    let before = state.epoch.load(Ordering::Acquire);
    current.query = "different query with the same result set".into();
    state.sync(current.clone());
    assert!(state.epoch.load(Ordering::Acquire) > before);
    assert!(state.picked.contains("thread-000"));
    let before = state.epoch.load(Ordering::Acquire);
    current.project = Some("other-project".into());
    state.sync(current.clone());
    assert!(state.epoch.load(Ordering::Acquire) > before);
    current.rows[0].1 = true;
    let before = state.epoch.load(Ordering::Acquire);
    state.sync(current.clone());
    assert!(state.epoch.load(Ordering::Acquire) > before);
    current.rows.remove(0);
    state.sync(current.clone());
    assert!(state.picked.is_empty());
    current.available = false;
    state.sync(current);
    assert!(!state.mode);
    assert!(state.picked.is_empty());
}
#[::core::prelude::v1::test]
fn revoked_before_admission_has_zero_effects_and_actual_join_remains_owned() {
    let mut state = State::default();
    state.sync(binding(1));
    state.mode = true;
    let epoch = state.epoch.clone();
    let generation = epoch.load(Ordering::Acquire);
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let (result_tx, result_rx) = mpsc::channel();
    let calls = Arc::new(AtomicUsize::new(0));
    let effects = calls.clone();
    assert!(state.workers.spawn(move |admission| {
        entered_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        let result = allowed(&admission, &epoch, generation);
        if result.is_ok() {
            effects.fetch_add(1, Ordering::SeqCst);
        }
        result_tx.send(result.is_err()).unwrap();
    }));
    entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    state.close_selection();
    state.close();
    assert_eq!(state.shutdown_status().unjoined, 1);
    assert!(!state.closed_and_drained());
    release_tx.send(()).unwrap();
    assert!(result_rx.recv_timeout(Duration::from_secs(5)).unwrap());
    wait(&mut state);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    assert!(state.closed_and_drained());
}
struct Gate {
    entered: mpsc::Sender<()>,
    release: mpsc::Receiver<()>,
}
impl Drop for Gate {
    fn drop(&mut self) {
        self.entered.send(()).unwrap();
        self.release.recv().unwrap();
    }
}
thread_local! {static TLS_GATE:std::cell::RefCell<Option<Gate>>=const {std::cell::RefCell::new(None)};}
#[::core::prelude::v1::test]
fn committed_receipt_and_undo_survive_route_close_while_quit_waits_actual_tls_join() {
    let root = std::env::temp_dir().join(format!("coincide-bulk-receipt-{}", uuid::Uuid::new_v4()));
    let mut store = Store::open(&root.join("state.sqlite")).unwrap();
    let thread = store
        .new_thread("00000000-0000-0000-0000-000000000000")
        .unwrap();
    let id = text(&thread, "id");
    let engine = Arc::new(Mutex::new(Engine::new(store)));
    let prepared = engine
        .lock()
        .unwrap()
        .prepare_thread_flags(&[id.clone()], Action::Pin)
        .unwrap();
    let mut state = State::default();
    state.sync(Binding {
        rows: vec![(id.clone(), false, false)],
        available: true,
        ..Default::default()
    });
    state.mode = true;
    state.pending = true;
    let generation = state.epoch.load(Ordering::Acquire);
    let epoch = state.epoch.clone();
    let sender = state.sender.clone();
    let owner = engine.clone();
    let (committed_tx, committed_rx) = mpsc::channel();
    let (publish_tx, publish_rx) = mpsc::channel();
    let (tls_tx, tls_rx) = mpsc::channel();
    let (leave_tx, leave_rx) = mpsc::channel();
    assert!(state.workers.spawn(move |admission| {
        TLS_GATE.with(|slot| {
            *slot.borrow_mut() = Some(Gate {
                entered: tls_tx,
                release: leave_rx,
            })
        });
        allowed(&admission, &epoch, generation).unwrap();
        let undo = owner.lock().unwrap().apply_thread_flags(&prepared).unwrap();
        committed_tx.send(()).unwrap();
        publish_rx.recv().unwrap();
        // Publication follows the actual commit even after close revoked the
        // selection epoch. Rechecking here would discard a real Undo receipt.
        sender
            .send(Reply {
                generation,
                result: Ok(Effect::Applied(Arc::new(undo))),
            })
            .unwrap();
    }));
    committed_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(
        engine.lock().unwrap().store.thread(&id).unwrap()["isPinned"],
        true
    );
    state.sync(Binding::default());
    state.close();
    assert!(!state.receipts_drained());
    assert!(!state.closed_and_drained());
    publish_tx.send(()).unwrap();
    tls_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(matches!(state.poll(), Some(Effect::Applied(_))));
    assert!(state.undo.is_some());
    assert!(state.status.contains("applied"));
    assert!(state.receipts_drained());
    assert_eq!(state.shutdown_status().unjoined, 1);
    assert!(!state.closed_and_drained());
    leave_tx.send(()).unwrap();
    wait(&mut state);
    assert!(state.closed_and_drained());
    let undo = state.undo.clone().unwrap();
    engine.lock().unwrap().undo_thread_flags(&undo).unwrap();
    assert_eq!(
        engine.lock().unwrap().store.thread(&id).unwrap()["isPinned"],
        false
    );
    drop(engine);
    std::fs::remove_dir_all(root).unwrap();
}
