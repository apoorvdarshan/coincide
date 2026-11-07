//! Shared actual native capture-thread custody. Stop failure or panic never
//! allows a caller to detach a native thread whose TLS/destructors are running.
pub(crate) fn join_after_stop<T>(
    worker: std::thread::JoinHandle<T>,
    signal: impl FnOnce() -> Result<(), ()>,
) -> Result<T, ()> {
    let stopped = std::panic::catch_unwind(std::panic::AssertUnwindSafe(signal));
    let returned = worker.join().map_err(|_| ());
    if !matches!(stopped, Ok(Ok(()))) {
        return Err(());
    }
    returned
}
#[cfg(test)]
mod tests {
    #[test]
    fn failed_or_panicked_stop_keeps_custody_through_actual_worker_tls_return() {
        use std::sync::mpsc;
        for panic in [false, true] {
            let (entered, entered_rx) = mpsc::channel();
            let (release, release_rx) = mpsc::channel();
            struct Exit(mpsc::Receiver<()>);
            impl Drop for Exit {
                fn drop(&mut self) {
                    self.0.recv().unwrap();
                }
            }
            thread_local! {static EXIT: std::cell::RefCell<Option<Exit>>=const{std::cell::RefCell::new(None)};}
            let worker = std::thread::spawn(move || {
                EXIT.with(|v| *v.borrow_mut() = Some(Exit(release_rx)));
                7
            });
            let (done, done_rx) = mpsc::channel();
            let owner = std::thread::spawn(move || {
                let result = super::join_after_stop(worker, || {
                    entered.send(()).unwrap();
                    assert!(!panic, "synthetic stop panic");
                    Err(())
                });
                done.send(result).unwrap();
            });
            entered_rx.recv().unwrap();
            assert!(matches!(done_rx.try_recv(), Err(mpsc::TryRecvError::Empty)));
            release.send(()).unwrap();
            assert_eq!(done_rx.recv().unwrap(), Err(()));
            owner.join().unwrap();
        }
    }
}
