//! Owned fake request threads only: no HTTP, provider processes or native calls.
use super::*;
use crate::agent::{Session, WorkerThreadStatus};
use std::sync::mpsc;
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
fn returned(session: &Session) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while session.worker_completion().status() == WorkerThreadStatus::Running {
        assert!(
            Instant::now() < deadline,
            "fake owned provider failed to join"
        );
        thread::yield_now();
    }
    assert_eq!(
        session.worker_completion().status(),
        WorkerThreadStatus::Returned
    );
}
#[test]
fn stop_during_request_keeps_provider_running_through_request_body_and_tls_exit() {
    let (go, begin) = mpsc::channel();
    let (body_started, body_seen) = mpsc::channel();
    let (body_release, body_gate) = mpsc::channel();
    let (tls_entered, tls_seen) = mpsc::channel();
    let (tls_release, tls_gate) = mpsc::channel();
    let (wait_done, wait_seen) = mpsc::channel();
    let session = Session::fixture_worker(move |commands, events| {
        begin.recv().unwrap();
        let mut runtime = Runtime {
            commands,
            queued: VecDeque::new(),
            events,
            request_join_entered: Some(wait_done),
        };
        let result = runtime.request_with_worker(Duration::from_secs(16), move || {
            TLS_GATE.with(|slot| {
                *slot.borrow_mut() = Some(TlsGate {
                    entered: tls_entered,
                    release: tls_gate,
                })
            });
            body_started.send(()).unwrap();
            body_gate.recv().unwrap();
            Ok(json!({"private":"fake response"}))
        });
        let error = result.unwrap_err();
        assert!(error.is::<Stopped>());
        events.send(Event::Failed(error.to_string())).unwrap();
    });
    // Stop is queued before Runtime.wait begins, independent of scheduling.
    session.stop();
    go.send(()).unwrap();
    body_seen.recv().unwrap();
    wait_seen.recv().unwrap();
    assert_eq!(
        session.worker_completion().status(),
        WorkerThreadStatus::Running
    );
    assert!(matches!(
        session.events.try_recv(),
        Err(mpsc::TryRecvError::Empty)
    ));
    body_release.send(()).unwrap();
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
    returned(&session);
    assert!(
        matches!(session.events.try_recv().unwrap(),Event::Failed(error) if error=="OpenCode turn stopped")
    );
}
#[test]
fn successful_response_delivery_does_not_finish_provider_before_request_tls_destructor() {
    let (tls_entered, tls_seen) = mpsc::channel();
    let (tls_release, tls_gate) = mpsc::channel();
    let (wait_done, wait_seen) = mpsc::channel();
    let session = Session::fixture_worker(move |commands, events| {
        let mut runtime = Runtime {
            commands,
            queued: VecDeque::new(),
            events,
            request_join_entered: Some(wait_done),
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
    wait_seen.recv().unwrap();
    assert_eq!(
        session.worker_completion().status(),
        WorkerThreadStatus::Running
    );
    assert!(matches!(
        session.events.try_recv(),
        Err(mpsc::TryRecvError::Empty)
    ));
    tls_release.send(()).unwrap();
    returned(&session);
    assert!(matches!(
        session.events.try_recv().unwrap(),
        Event::Finished
    ));
}
#[test]
fn timeout_result_is_preserved_but_owned_worker_must_join_first() {
    let (body_started, body_seen) = mpsc::channel();
    let (body_release, body_gate) = mpsc::channel();
    let (wait_done, wait_seen) = mpsc::channel();
    let session = Session::fixture_worker(move |commands, events| {
        let mut runtime = Runtime {
            commands,
            queued: VecDeque::new(),
            events,
            request_join_entered: Some(wait_done),
        };
        // Zero is an explicit already-expired deadline, no elapsed-time race.
        let result = runtime.request_with_worker(Duration::ZERO, move || {
            body_started.send(()).unwrap();
            body_gate.recv().unwrap();
            Ok(Value::Null)
        });
        events
            .send(Event::Failed(result.unwrap_err().to_string()))
            .unwrap();
    });
    body_seen.recv().unwrap();
    wait_seen.recv().unwrap();
    assert_eq!(
        session.worker_completion().status(),
        WorkerThreadStatus::Running
    );
    body_release.send(()).unwrap();
    returned(&session);
    assert!(
        matches!(session.events.try_recv().unwrap(),Event::Failed(error) if error=="OpenCode operation timed out")
    );
}
#[test]
fn request_panic_waits_for_tls_join_and_is_not_reported_as_request_success() {
    let (tls_entered, tls_seen) = mpsc::channel();
    let (tls_release, tls_gate) = mpsc::channel();
    let (wait_done, wait_seen) = mpsc::channel();
    let session = Session::fixture_worker(move |commands, events| {
        let mut runtime = Runtime {
            commands,
            queued: VecDeque::new(),
            events,
            request_join_entered: Some(wait_done),
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
    wait_seen.recv().unwrap();
    assert_eq!(
        session.worker_completion().status(),
        WorkerThreadStatus::Running
    );
    tls_release.send(()).unwrap();
    returned(&session);
    assert!(
        matches!(session.events.try_recv().unwrap(),Event::Failed(error) if error=="OpenCode HTTP request worker panicked")
    );
}
