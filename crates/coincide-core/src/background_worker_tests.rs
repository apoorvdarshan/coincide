//! Synthetic Engine worker ownership; no subprocess, provider, or native host.
use super::*;
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::Duration;

fn fixture() -> (tempfile::TempDir, Engine, String) {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("data/state.sqlite")).unwrap();
    let project = store.create_project(dir.path(), Some("fixture")).unwrap();
    let thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
    let mut engine = Engine::fixture(store);
    engine.schedule_last_poll = Instant::now();
    (dir, engine, text(&thread, "id"))
}
fn wait(engine: &mut Engine) -> BackgroundShutdownStatus {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let status = engine.background_shutdown_status().unwrap();
        if status.running == 0 {
            return status;
        }
        assert!(Instant::now() < deadline, "fake worker did not join");
        std::thread::yield_now();
    }
}
#[test]
fn frozen_background_adapters_drain_actual_file_worker_without_json_bypass() {
    let (dir, mut engine, id) = fixture();
    assert!(engine.request_background_shutdown().is_err());
    assert!(engine.background_shutdown_status().is_err());
    std::fs::write(dir.path().join("fixture.txt"), "retained fixture text\n").unwrap();
    let response = engine
        .execute("files.read", &json!({"threadId":id,"path":"fixture.txt"}))
        .unwrap();
    let op = response["operationId"].as_str().unwrap();
    engine.freeze_admissions();
    engine.request_background_shutdown().unwrap();
    engine.request_background_shutdown().unwrap();
    let status = wait(&mut engine);
    assert!(status.closed);
    assert_eq!(status.returned, 1);
    assert_eq!(status.panicked, 0);
    assert!(engine.workspace_results[op]["error"].is_null());
    assert!(
        engine.workspace_results[op]
            .to_string()
            .contains("retained fixture text")
    );
    assert!(engine.require_background_admission().is_err());
    assert_eq!(
        engine.dispatch(json!({"method":"workspace.result"}))["error"]["message"],
        "Engine admissions are frozen"
    );
}
#[test]
fn frozen_background_adapters_drain_actual_attachment_worker_and_persistence() {
    let (dir, mut engine, id) = fixture();
    let source = dir.path().join("source.png");
    image::RgbaImage::from_pixel(2, 2, image::Rgba([1, 2, 3, 255]))
        .save(&source)
        .unwrap();
    let response = engine
        .execute("attachments.add", &json!({"threadId":id,"path":source}))
        .unwrap();
    let op = response["operationId"].as_str().unwrap();
    engine.freeze_admissions();
    engine.request_background_shutdown().unwrap();
    let status = wait(&mut engine);
    assert_eq!(status.returned, 1);
    assert_eq!(status.pending_attachment_completions, 0);
    assert!(engine.workspace_results[op]["error"].is_null());
    assert_eq!(
        engine.store.thread(&id).unwrap()["rustDraftImages"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}
struct TlsGate {
    entered: mpsc::Sender<()>,
    release: mpsc::Receiver<()>,
}
impl Drop for TlsGate {
    fn drop(&mut self) {
        let _ = self.entered.send(());
        let _ = self.release.recv();
    }
}
thread_local! { static TLS_GATE:std::cell::RefCell<Option<TlsGate>> = const { std::cell::RefCell::new(None) }; }
#[test]
fn expired_mutation_keeps_ownership_through_backpressure_and_thread_through_tls() {
    let (_dir, mut engine, id) = fixture();
    let (tx, rx) = mpsc::sync_channel(32);
    engine.workspace_tx = tx.clone();
    engine.workspace_rx = rx;
    for index in 0..32 {
        tx.try_send((format!("unrelated-{index}"), json!({})))
            .unwrap();
    }
    let op = Uuid::new_v4().to_string();
    engine
        .workspace_pending
        .insert(op.clone(), (id, Instant::now() - Duration::from_secs(301)));
    engine.workspace_mutations.insert(op.clone());
    let operation = op.clone();
    let (full_tx, full_rx) = mpsc::channel();
    let (publish_tx, publish_rx) = mpsc::channel();
    let (tls_tx, tls_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        TLS_GATE.with(|slot| {
            *slot.borrow_mut() = Some(TlsGate {
                entered: tls_tx,
                release: release_rx,
            })
        });
        let completion = (operation, json!({"completed":true}));
        let Err(mpsc::TrySendError::Full((operation, result))) = tx.try_send(completion) else {
            panic!("fixture mailbox must actually be full")
        };
        full_tx.send(()).unwrap();
        publish_rx.recv().unwrap();
        workspace_api::publish_completion(tx, operation, result);
    });
    engine.background_workers.track(worker);
    full_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    engine.freeze_admissions();
    engine.request_background_shutdown().unwrap();
    let pending = engine.background_shutdown_status().unwrap();
    assert_eq!(pending.running, 1);
    assert_eq!(pending.pending_mutation_completions, 1);
    assert!(!engine.workspace_pending.contains_key(&op));
    publish_tx.send(()).unwrap();
    tls_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let published = engine.background_shutdown_status().unwrap();
    assert_eq!(published.pending_mutation_completions, 0);
    assert_eq!(
        published.running, 1,
        "mailbox completion cannot acknowledge TLS exit"
    );
    assert!(!engine.workspace_results.contains_key(&op));
    release_tx.send(()).unwrap();
    assert_eq!(wait(&mut engine).returned, 1);
}
#[test]
fn panicked_background_worker_retains_sticky_diagnostic_and_unresolved_mutation() {
    let (_dir, mut engine, id) = fixture();
    let op = Uuid::new_v4().to_string();
    engine
        .workspace_pending
        .insert(op.clone(), (id, Instant::now()));
    engine.workspace_mutations.insert(op);
    let (tls_tx, tls_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        TLS_GATE.with(|slot| {
            *slot.borrow_mut() = Some(TlsGate {
                entered: tls_tx,
                release: release_rx,
            })
        });
        panic!("synthetic workspace panic before completion");
    });
    engine.background_workers.track(worker);
    tls_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    engine.freeze_admissions();
    engine.request_background_shutdown().unwrap();
    assert_eq!(engine.background_shutdown_status().unwrap().running, 1);
    release_tx.send(()).unwrap();
    let status = wait(&mut engine);
    assert_eq!(status.panicked, 1);
    assert_eq!(status.returned, 0);
    assert_eq!(status.pending_mutation_completions, 1);
    assert_eq!(engine.background_shutdown_status().unwrap(), status);
}
#[test]
fn actual_worker_capacity_outlives_client_expiry_and_closes_irreversibly() {
    let (_dir, mut engine, _id) = fixture();
    struct ReleaseOnDrop(Arc<(Mutex<bool>, Condvar)>);
    impl Drop for ReleaseOnDrop {
        fn drop(&mut self) {
            let (lock, changed) = &*self.0;
            *lock.lock().unwrap_or_else(|error| error.into_inner()) = true;
            changed.notify_all();
        }
    }
    let release = Arc::new((Mutex::new(false), Condvar::new()));
    let _cleanup = ReleaseOnDrop(release.clone());
    let (started_tx, started_rx) = mpsc::channel();
    for _ in 0..MAX_WORKERS {
        engine.require_background_admission().unwrap();
        let gate = release.clone();
        let started = started_tx.clone();
        engine.background_workers.track(std::thread::spawn(move || {
            started.send(()).unwrap();
            let (lock, changed) = &*gate;
            let mut ready = lock.lock().unwrap();
            while !*ready {
                ready = changed.wait(ready).unwrap();
            }
        }));
    }
    for _ in 0..MAX_WORKERS {
        started_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    }
    assert!(engine.workspace_pending.is_empty());
    assert!(engine.require_background_admission().is_err());
    engine.freeze_admissions();
    engine.request_background_shutdown().unwrap();
    assert_eq!(
        engine.background_shutdown_status().unwrap().running,
        MAX_WORKERS
    );
    let (lock, changed) = &*release;
    *lock.lock().unwrap() = true;
    changed.notify_all();
    let status = wait(&mut engine);
    assert_eq!(status.returned, MAX_WORKERS as u64);
    assert!(status.closed);
    assert!(engine.background_workers.check_admission().is_err());
}
