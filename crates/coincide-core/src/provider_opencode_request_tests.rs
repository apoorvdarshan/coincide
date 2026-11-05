//! Owned fake request threads only: no HTTP, provider processes or native calls.
use super::*;
use crate::agent::{Session, WorkerThreadStatus};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc,
};
struct TlsGate {
    entered: Sender<()>,
    release: Receiver<()>,
}
impl Drop for TlsGate {
    fn drop(&mut self) {
        self.entered.send(()).unwrap();
        self.release.recv().unwrap();
    }
}
thread_local! {static TLS_GATE:std::cell::RefCell<Option<TlsGate>>=const{std::cell::RefCell::new(None)};}
fn joined(session: &Session, expected: WorkerThreadStatus) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while session.worker_completion().status() == WorkerThreadStatus::Running {
        assert!(Instant::now() < deadline, "fake provider failed to join");
        thread::yield_now();
    }
    assert_eq!(session.worker_completion().status(), expected);
}
// Mirrors Server's OwnedChild field destruction, not just a Drop request.
struct FakeChild {
    torn: Arc<AtomicBool>,
    observed: Sender<()>,
    release_body: Sender<()>,
}
impl Drop for FakeChild {
    fn drop(&mut self) {
        self.torn.store(true, Ordering::Release);
        let _ = self.release_body.send(());
        let _ = self.observed.send(());
    }
}
struct FakeServer {
    _child: FakeChild,
}
struct Rescue {
    body: Sender<()>,
    tls: Sender<()>,
}
impl Drop for Rescue {
    fn drop(&mut self) {
        let _ = self.body.send(());
        let _ = self.tls.send(());
    }
}
fn fake_start(
    runtime: &mut Runtime<'_>,
    _child: FakeChild,
    limit: Duration,
    work: impl FnOnce() -> Result<Value> + Send + 'static,
) -> Result<Value> {
    runtime.request_with_worker(limit, work)
}
fn aborted_case(stop: bool, startup: bool, panic_worker: bool) {
    let (go, begin) = mpsc::channel();
    let (body_started, body_seen) = mpsc::channel();
    let (body_release, body_gate) = mpsc::channel();
    let (tls_entered, tls_seen) = mpsc::channel();
    let (tls_release, tls_gate) = mpsc::channel();
    let (join_entered, join_seen) = mpsc::channel();
    let (server_torn, server_seen) = mpsc::channel();
    let torn = Arc::new(AtomicBool::new(false));
    let flag = torn.clone();
    let _rescue = Rescue {
        body: body_release.clone(),
        tls: tls_release.clone(),
    };
    let session = Session::fixture_worker(move |commands, events| {
        begin.recv().unwrap();
        let mut runtime = Runtime {
            commands,
            queued: VecDeque::new(),
            events,
            aborted_requests: Vec::new(),
            request_join_entered: Some(join_entered),
        };
        let child = FakeChild {
            torn: flag,
            observed: server_torn,
            release_body: body_release,
        };
        let work = move || {
            TLS_GATE.with(|slot| {
                *slot.borrow_mut() = Some(TlsGate {
                    entered: tls_entered,
                    release: tls_gate,
                })
            });
            body_started.send(()).unwrap();
            body_gate.recv().unwrap();
            assert!(!panic_worker, "private aborted request panic payload");
            Ok(json!({"private":"fake response"}))
        };
        let limit = if stop {
            Duration::from_secs(16)
        } else {
            Duration::ZERO
        };
        let result = if startup {
            // Server::start's local child dies in the callee before Runtime.
            fake_start(&mut runtime, child, limit, work)
        } else {
            let _server = FakeServer { _child: child };
            runtime.request_with_worker(limit, work)
        };
        assert_eq!(runtime.aborted_requests.len(), 1);
        assert!(
            runtime
                .request_with_worker(Duration::from_secs(1), || -> Result<Value> {
                    panic!("must not admit another HTTP worker")
                })
                .is_err()
        );
        let error = result.unwrap_err();
        if stop {
            assert!(error.is::<Stopped>());
        } else {
            assert!(error.is::<OperationTimedOut>());
        }
        // Actual provider run_inner drops Server before Runtime; only after
        // Runtime's joined teardown does outer run map Stop to Finished.
        drop(runtime);
        if stop {
            events.send(Event::Finished).unwrap();
        } else {
            events.send(Event::Failed(error.to_string())).unwrap();
        }
    });
    if stop {
        session.stop();
    }
    go.send(()).unwrap();
    body_seen.recv().unwrap();
    join_seen.recv().unwrap();
    // Deterministic ordering proof: the old inline join signals here BEFORE
    // FakeChild can tear down, so it fails immediately, with no timed absence.
    assert!(
        torn.load(Ordering::Acquire),
        "owned child must terminate before aborted request join"
    );
    server_seen.try_recv().unwrap();
    tls_seen.recv().unwrap();
    assert_eq!(
        session.worker_completion().status(),
        WorkerThreadStatus::Running
    );
    assert!(matches!(
        session.events.try_recv(),
        Err(mpsc::TryRecvError::Empty)
    ));
    tls_release.send(()).unwrap();
    joined(
        &session,
        if panic_worker {
            WorkerThreadStatus::Panicked
        } else {
            WorkerThreadStatus::Returned
        },
    );
    if panic_worker {
        assert!(
            !session
                .events
                .try_iter()
                .any(|event| matches!(event, Event::Finished))
        );
    } else if stop {
        assert!(matches!(
            session.events.try_recv().unwrap(),
            Event::Finished
        ));
    } else {
        assert!(
            matches!(session.events.try_recv().unwrap(),Event::Failed(error) if error=="OpenCode operation timed out")
        );
    }
}
#[test]
fn stop_tears_down_server_before_gated_request_tls_join() {
    aborted_case(true, false, false);
}
#[test]
fn startup_stop_tears_down_local_child_before_caller_runtime_join() {
    aborted_case(true, true, false);
}
#[test]
fn timeout_tears_down_server_then_preserves_error_after_owned_join() {
    aborted_case(false, false, false);
}
#[test]
fn aborted_request_panic_remains_sticky_provider_panic_after_tls_join() {
    aborted_case(true, false, true);
}
#[test]
fn successful_response_delivery_does_not_finish_provider_before_request_tls_destructor() {
    let (tls_entered, tls_seen) = mpsc::channel();
    let (tls_release, tls_gate) = mpsc::channel();
    let (join_entered, join_seen) = mpsc::channel();
    let session = Session::fixture_worker(move |commands, events| {
        let mut runtime = Runtime {
            commands,
            queued: VecDeque::new(),
            events,
            aborted_requests: Vec::new(),
            request_join_entered: Some(join_entered),
        };
        let result = runtime
            .request_with_worker(Duration::from_secs(16), move || {
                TLS_GATE.with(|slot| {
                    *slot.borrow_mut() = Some(TlsGate {
                        entered: tls_entered,
                        release: tls_gate,
                    })
                });
                Ok(json!({"reported":true}))
            })
            .unwrap();
        assert_eq!(result, json!({"reported":true}));
        events.send(Event::Finished).unwrap();
    });
    tls_seen.recv().unwrap();
    join_seen.recv().unwrap();
    assert_eq!(
        session.worker_completion().status(),
        WorkerThreadStatus::Running
    );
    assert!(matches!(
        session.events.try_recv(),
        Err(mpsc::TryRecvError::Empty)
    ));
    tls_release.send(()).unwrap();
    joined(&session, WorkerThreadStatus::Returned);
    assert!(matches!(
        session.events.try_recv().unwrap(),
        Event::Finished
    ));
}
#[test]
fn ordinary_request_panic_waits_for_tls_join_and_returns_explicit_failure() {
    let (tls_entered, tls_seen) = mpsc::channel();
    let (tls_release, tls_gate) = mpsc::channel();
    let (join_entered, join_seen) = mpsc::channel();
    let session = Session::fixture_worker(move |commands, events| {
        let mut runtime = Runtime {
            commands,
            queued: VecDeque::new(),
            events,
            aborted_requests: Vec::new(),
            request_join_entered: Some(join_entered),
        };
        let result: Result<Value> =
            runtime.request_with_worker(Duration::from_secs(16), move || {
                TLS_GATE.with(|slot| {
                    *slot.borrow_mut() = Some(TlsGate {
                        entered: tls_entered,
                        release: tls_gate,
                    })
                });
                panic!("private fixture panic payload")
            });
        events
            .send(Event::Failed(result.unwrap_err().to_string()))
            .unwrap();
    });
    tls_seen.recv().unwrap();
    join_seen.recv().unwrap();
    assert_eq!(
        session.worker_completion().status(),
        WorkerThreadStatus::Running
    );
    tls_release.send(()).unwrap();
    joined(&session, WorkerThreadStatus::Returned);
    assert!(
        matches!(session.events.try_recv().unwrap(),Event::Failed(error) if error=="OpenCode HTTP request worker panicked")
    );
}
