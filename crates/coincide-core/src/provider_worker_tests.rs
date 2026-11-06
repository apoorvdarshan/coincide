//! Headless Engine/provider-thread ownership regressions. No provider processes.
use super::*;
use std::sync::mpsc;
use std::time::Duration;

struct GatedWorker {
    session: Session,
    observer: agent::WorkerCompletion,
    release: mpsc::Sender<()>,
    stopped: mpsc::Receiver<()>,
}
fn gated_worker(panic_after_release: bool) -> GatedWorker {
    let (ready_tx, ready_rx) = mpsc::channel();
    let (release, release_rx) = mpsc::channel();
    let (stopped_tx, stopped) = mpsc::channel();
    let session = Session::fixture_worker(move |commands, events| {
        events.send(Event::Finished).unwrap();
        ready_tx.send(()).unwrap();
        assert!(matches!(commands.recv().unwrap(), agent::Control::Stop));
        stopped_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        assert!(!panic_after_release, "synthetic provider worker panic");
    });
    ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let observer = session.worker_completion();
    GatedWorker {
        session,
        observer,
        release,
        stopped,
    }
}
fn fixture() -> (tempfile::TempDir, Engine, String) {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(&dir.path().join("data/state.sqlite")).unwrap();
    let project = store.create_project(dir.path(), Some("fixture")).unwrap();
    let thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
    let id = thread["id"].as_str().unwrap().to_owned();
    let mut engine = Engine::fixture(store);
    engine.schedule_last_poll = Instant::now();
    (dir, engine, id)
}
fn retire(engine: &mut Engine, id: &str, session: Session) {
    engine.insert_running(
        id.to_owned(),
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
    engine.poll();
    assert!(
        engine.runs.is_empty(),
        "the semantic Finished must retire the turn"
    );
}
fn wait_exit(observer: &agent::WorkerCompletion) -> agent::WorkerThreadStatus {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let status = observer.status();
        if status != agent::WorkerThreadStatus::Running {
            return status;
        }
        assert!(Instant::now() < deadline, "fake worker did not exit");
        std::thread::yield_now();
    }
}

#[test]
fn retired_finished_turn_keeps_worker_ownership_after_session_drop() {
    let (_dir, mut engine, id) = fixture();
    let GatedWorker {
        session,
        observer,
        release,
        stopped,
    } = gated_worker(false);
    retire(&mut engine, &id, session);
    // Explicit receipt of Session::drop's Stop proves retirement has happened;
    // the worker cannot return until this test releases its independent gate.
    stopped.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(observer.status(), agent::WorkerThreadStatus::Running);
    assert_eq!(
        engine.provider_workers_status(),
        ProviderWorkersStatus {
            running: 1,
            ..ProviderWorkersStatus::default()
        }
    );
    release.send(()).unwrap();
    assert_eq!(wait_exit(&observer), agent::WorkerThreadStatus::Returned);
    engine.poll();
    let expected = ProviderWorkersStatus {
        returned: 1,
        ..ProviderWorkersStatus::default()
    };
    assert_eq!(engine.provider_workers_status(), expected);
    assert_eq!(
        engine.provider_workers_status(),
        expected,
        "counts must not duplicate"
    );
}

#[test]
fn retired_panicked_worker_is_sticky_failure_instead_of_returned() {
    let (_dir, mut engine, id) = fixture();
    let GatedWorker {
        session,
        observer,
        release,
        stopped,
    } = gated_worker(true);
    retire(&mut engine, &id, session);
    stopped.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(engine.provider_workers_status().running, 1);
    release.send(()).unwrap();
    assert_eq!(wait_exit(&observer), agent::WorkerThreadStatus::Panicked);
    let expected = ProviderWorkersStatus {
        panicked: 1,
        ..ProviderWorkersStatus::default()
    };
    assert_eq!(engine.provider_workers_status(), expected);
    engine.poll();
    assert_eq!(engine.provider_workers_status(), expected);
    assert_eq!(observer.status(), agent::WorkerThreadStatus::Panicked);
}

#[test]
fn later_turn_on_same_thread_does_not_replace_retired_worker_tracking() {
    let (_dir, mut engine, id) = fixture();
    let GatedWorker {
        session: first,
        observer: first_observer,
        release: first_release,
        stopped: first_stopped,
    } = gated_worker(false);
    retire(&mut engine, &id, first);
    first_stopped.recv_timeout(Duration::from_secs(5)).unwrap();
    let GatedWorker {
        session: second,
        observer: second_observer,
        release: second_release,
        stopped: second_stopped,
    } = gated_worker(false);
    retire(&mut engine, &id, second);
    second_stopped.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(engine.provider_workers_status().running, 2);
    first_release.send(()).unwrap();
    assert_eq!(
        wait_exit(&first_observer),
        agent::WorkerThreadStatus::Returned
    );
    assert_eq!(
        engine.provider_workers_status(),
        ProviderWorkersStatus {
            running: 1,
            returned: 1,
            ..ProviderWorkersStatus::default()
        }
    );
    assert_eq!(second_observer.status(), agent::WorkerThreadStatus::Running);
    second_release.send(()).unwrap();
    assert_eq!(
        wait_exit(&second_observer),
        agent::WorkerThreadStatus::Returned
    );
    assert_eq!(
        engine.provider_workers_status(),
        ProviderWorkersStatus {
            returned: 2,
            ..ProviderWorkersStatus::default()
        }
    );
}

struct TlsExitGate {
    entered: mpsc::Sender<()>,
    release: mpsc::Receiver<()>,
}
impl Drop for TlsExitGate {
    fn drop(&mut self) {
        // These cannot panic during a panicking worker's TLS destruction.
        let _ = self.entered.send(());
        let _ = self.release.recv();
    }
}
thread_local! {
    static TLS_EXIT_GATE: std::cell::RefCell<Option<TlsExitGate>> = const {
        std::cell::RefCell::new(None)
    };
}
fn joined_tls_exit(panic_after_finished: bool) {
    let (_dir, mut engine, id) = fixture();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let session = Session::fixture_worker(move |_, events| {
        TLS_EXIT_GATE.with(|slot| {
            *slot.borrow_mut() = Some(TlsExitGate {
                entered: entered_tx,
                release: release_rx,
            });
        });
        events.send(Event::Finished).unwrap();
        assert!(
            !panic_after_finished,
            "synthetic worker panic before TLS exit"
        );
    });
    let observer = session.worker_completion();
    // An explicit destructor-entry acknowledgement proves that the worker body
    // has returned/unwound. Its actual thread exit is still gated, independent
    // of scheduling, sleep duration, or JoinHandle::is_finished semantics.
    entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    retire(&mut engine, &id, session);
    assert_eq!(observer.status(), agent::WorkerThreadStatus::Running);
    assert_eq!(
        engine.provider_workers_status(),
        ProviderWorkersStatus {
            running: 1,
            ..ProviderWorkersStatus::default()
        }
    );
    release_tx.send(()).unwrap();
    let expected_status = if panic_after_finished {
        agent::WorkerThreadStatus::Panicked
    } else {
        agent::WorkerThreadStatus::Returned
    };
    assert_eq!(wait_exit(&observer), expected_status);
    let expected_counts = if panic_after_finished {
        ProviderWorkersStatus {
            panicked: 1,
            ..ProviderWorkersStatus::default()
        }
    } else {
        ProviderWorkersStatus {
            returned: 1,
            ..ProviderWorkersStatus::default()
        }
    };
    engine.poll();
    assert_eq!(engine.provider_workers_status(), expected_counts);
    assert_eq!(engine.provider_workers_status(), expected_counts);
}

#[test]
fn returned_worker_stays_running_until_tls_destructor_and_join_finish() {
    joined_tls_exit(false);
}

#[test]
fn panicked_worker_stays_running_until_tls_destructor_and_join_finish() {
    joined_tls_exit(true);
}
