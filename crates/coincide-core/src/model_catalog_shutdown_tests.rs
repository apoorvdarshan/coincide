//! No provider processes: all reads use the production worker/publisher seam.
#![cfg(unix)]
use super::*;
use crate::agent::{WorkerCompletion, WorkerThreadStatus};

fn joined(observer: &WorkerCompletion) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while observer.status() == WorkerThreadStatus::Running {
        assert!(
            Instant::now() < deadline,
            "fake catalog worker did not join"
        );
        std::thread::yield_now();
    }
}
#[test]
fn shutdown_is_inert_idempotent_and_rejects_all_refreshes() {
    let mut catalog = ModelCatalog::default();
    assert_eq!(catalog.shutdown_status(), ShutdownStatus::default());
    catalog.request_shutdown();
    catalog.request_shutdown();
    assert!(catalog.refresh("codex", None).is_err());
    assert!(catalog.refresh("grok", None).is_err());
    assert!(catalog.refresh("unknown", None).is_err());
    assert!(catalog.jobs.is_empty());
    assert_eq!(
        catalog.shutdown_status(),
        ShutdownStatus {
            closed: true,
            ..ShutdownStatus::default()
        }
    );
}
#[test]
fn shutdown_sets_cancel_bit_and_drains_response_and_join_ack() {
    let mut catalog = ModelCatalog::default();
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let response = catalog
        .refresh_with("codex", move |cancelled| {
            assert!(!cancelled.load(Ordering::Acquire));
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            assert!(cancelled.load(Ordering::Acquire));
            Err("synthetic cancellation".into())
        })
        .unwrap();
    started_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let id = response["requestId"].as_str().unwrap();
    let observer = catalog.workers[id].completion.clone();
    catalog.request_shutdown();
    assert!(catalog.jobs[id].cancelled.load(Ordering::Acquire));
    assert_eq!(catalog.shutdown_status().running, 1);
    // Closure is checked before loading-job deduplication.
    assert!(catalog.refresh("codex", None).is_err());
    release_tx.send(()).unwrap();
    joined(&observer);
    let status = catalog.shutdown_status();
    assert_eq!(
        status,
        ShutdownStatus {
            closed: true,
            returned: 1,
            ..ShutdownStatus::default()
        }
    );
    assert_eq!(catalog.status(id).unwrap()["state"], "failed");
    assert_eq!(
        catalog.status(id).unwrap()["error"],
        "synthetic cancellation"
    );
    assert_eq!(catalog.shutdown_status(), status);
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
thread_local! {
    static TLS_GATE: std::cell::RefCell<Option<TlsGate>> = const { std::cell::RefCell::new(None) };
}
fn gated_tls_read(
    catalog: &mut ModelCatalog,
    provider: &str,
    panic: bool,
) -> (String, WorkerCompletion, mpsc::Sender<()>) {
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let response = catalog
        .refresh_with(provider, move |_| {
            TLS_GATE.with(|slot| {
                *slot.borrow_mut() = Some(TlsGate {
                    entered: entered_tx,
                    release: release_rx,
                })
            });
            assert!(!panic, "synthetic catalog worker panic");
            Ok(vec![
                json!({"id":"synthetic-model","displayName":"Synthetic"}),
            ])
        })
        .unwrap();
    // Body/publisher has returned or unwound, but actual thread exit is gated.
    entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let id = response["requestId"].as_str().unwrap().to_owned();
    let observer = catalog.workers[&id].completion.clone();
    (id, observer, release_tx)
}
#[test]
fn active_cap_and_cancellation_survive_ready_result_eviction_and_tls_exit() {
    let mut catalog = ModelCatalog::default();
    let (first, first_observer, release_first) = gated_tls_read(&mut catalog, "codex", false);
    let (second, second_observer, release_second) = gated_tls_read(&mut catalog, "claude", false);
    catalog.poll();
    assert_eq!(catalog.status(&first).unwrap()["state"], "ready");
    assert_eq!(catalog.status(&second).unwrap()["state"], "ready");
    assert_eq!(catalog.shutdown_status().running, MAX_ACTIVE);
    // Ready results do not release actual worker capacity while TLS is gated.
    assert!(
        catalog
            .refresh_with("codex", |_| panic!("must not start"))
            .is_err()
    );
    for _ in 0..MAX_JOBS + 2 {
        catalog
            .refresh_with("grok", |_| panic!("unsupported must not spawn"))
            .unwrap();
    }
    assert!(catalog.status(&first).is_err());
    assert!(catalog.status(&second).is_err());
    assert_eq!(catalog.jobs.len(), MAX_JOBS);
    assert_eq!(catalog.shutdown_status().running, MAX_ACTIVE);
    assert!(
        catalog
            .refresh_with("codex", |_| panic!("eviction must not free a worker slot"))
            .is_err()
    );
    catalog.request_shutdown();
    assert!(
        catalog
            .workers
            .values()
            .all(|worker| worker.cancelled.load(Ordering::Acquire))
    );
    assert_eq!(first_observer.status(), WorkerThreadStatus::Running);
    assert_eq!(second_observer.status(), WorkerThreadStatus::Running);
    release_first.send(()).unwrap();
    release_second.send(()).unwrap();
    joined(&first_observer);
    joined(&second_observer);
    assert_eq!(
        catalog.shutdown_status(),
        ShutdownStatus {
            closed: true,
            returned: 2,
            ..ShutdownStatus::default()
        }
    );
    assert!(catalog.workers.is_empty());
}
#[test]
fn panicked_catalog_worker_is_counted_only_after_tls_join_and_stays_failure() {
    let mut catalog = ModelCatalog::default();
    let (id, observer, release) = gated_tls_read(&mut catalog, "codex", true);
    catalog.request_shutdown();
    assert_eq!(catalog.shutdown_status().running, 1);
    assert_eq!(catalog.status(&id).unwrap()["state"], "loading");
    release.send(()).unwrap();
    joined(&observer);
    let expected = ShutdownStatus {
        closed: true,
        panicked: 1,
        ..ShutdownStatus::default()
    };
    assert_eq!(catalog.shutdown_status(), expected);
    assert_eq!(catalog.status(&id).unwrap()["state"], "failed");
    assert_eq!(catalog.shutdown_status(), expected);
}
