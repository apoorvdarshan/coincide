use super::*;

struct ExitGate(mpsc::Sender<()>, mpsc::Receiver<()>);
impl Drop for ExitGate {
    fn drop(&mut self) {
        let _ = self.0.send(());
        let _ = self.1.recv();
    }
}
thread_local! {
    static EXIT_GATE: std::cell::RefCell<Option<ExitGate>> = const {std::cell::RefCell::new(None)};
}
#[test]
fn cancellation_and_join_ownership_survive_result_retirement_and_tls_exit() {
    for panic in [false, true] {
        let mut service = GithubService::new(GhRunner {
            executable: PathBuf::from("/synthetic-never-launched"),
            timeout: Duration::from_secs(1),
        });
        let cancel = Arc::new(AtomicBool::new(false));
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            EXIT_GATE.with(|slot| *slot.borrow_mut() = Some(ExitGate(entered_tx, release_rx)));
            assert!(!panic, "synthetic read panic");
        });
        service.workers.track(cancel.clone(), worker);
        entered_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        assert!(
            service.operations.is_empty(),
            "result ownership is independent"
        );
        service.request_shutdown();
        service.request_shutdown();
        assert!(cancel.load(Ordering::Acquire));
        let before = service.shutdown_status();
        assert!(before.closed);
        assert_eq!(before.running, 1);
        assert_eq!(before.returned + before.panicked, 0);
        assert!(
            service
                .start("invalid", Path::new("/"), "invalid", &json!({}))
                .unwrap_err()
                .to_string()
                .contains("shutting down")
        );
        release_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        let after = loop {
            let status = service.shutdown_status();
            if status.running == 0 {
                break status;
            }
            assert!(Instant::now() < deadline, "read worker did not join");
            std::thread::yield_now();
        };
        assert_eq!(after.panicked, u64::from(panic));
        assert_eq!(after.returned, u64::from(!panic));
        assert_eq!(service.shutdown_status(), after);
    }
}
