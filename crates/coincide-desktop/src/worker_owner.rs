//! Bounded local workflow ownership. Closing admissions is not cancellation of
//! an already-started vault/process/filesystem action or whole-app readiness.
use coincide_core::agent::{WorkerCompletion, WorkerThreadStatus};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ShutdownStatus {
    pub closed: bool,
    pub unjoined: usize,
    pub returned: u64,
    pub panicked: u64,
    pub unclassified: usize,
    pub pending_pickers: usize,
    pub spawn_error: Option<String>,
}
#[derive(Clone)]
pub struct Admission(Arc<AtomicBool>);
impl Admission {
    pub fn allowed(&self) -> bool {
        !self.0.load(Ordering::Acquire)
    }
}
#[derive(Default)]
pub struct WorkerOwner {
    closed: Arc<AtomicBool>,
    workers: Vec<WorkerCompletion>,
    returned: u64,
    panicked: u64,
    pending_pickers: usize,
    spawn_error: Option<String>,
}
impl WorkerOwner {
    pub fn closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }
    pub fn close(&mut self) -> bool {
        !self.closed.swap(true, Ordering::AcqRel)
    }
    pub fn poll(&mut self) {
        self.workers.retain(|worker| match worker.status() {
            WorkerThreadStatus::Running | WorkerThreadStatus::Unclassified => true,
            WorkerThreadStatus::Returned => {
                self.returned = self.returned.saturating_add(1);
                false
            }
            WorkerThreadStatus::Panicked => {
                self.panicked = self.panicked.saturating_add(1);
                false
            }
        });
    }
    pub fn can_start(&mut self) -> bool {
        self.poll();
        !self.closed()
            && self.workers.is_empty()
            && self.pending_pickers == 0
            && self.spawn_error.is_none()
    }
    pub fn begin_picker(&mut self) -> bool {
        if !self.can_start() {
            return false;
        }
        self.pending_pickers += 1;
        true
    }
    pub fn finish_picker(&mut self) -> bool {
        self.pending_pickers = self.pending_pickers.saturating_sub(1);
        !self.closed()
    }
    pub fn spawn(&mut self, work: impl FnOnce(Admission) + Send + 'static) -> bool {
        if !self.can_start() {
            return false;
        }
        let admission = Admission(self.closed.clone());
        match std::thread::Builder::new()
            .name("coincide-workflow".into())
            .spawn(move || work(admission))
        {
            Ok(worker) => {
                self.workers.push(WorkerCompletion::observe(worker));
                true
            }
            Err(error) => {
                self.spawn_error = Some(error.to_string().chars().take(1024).collect());
                false
            }
        }
    }
    pub fn status(&mut self) -> ShutdownStatus {
        self.poll();
        ShutdownStatus {
            closed: self.closed(),
            unjoined: self.workers.len(),
            returned: self.returned,
            panicked: self.panicked,
            unclassified: self
                .workers
                .iter()
                .filter(|worker| worker.status() == WorkerThreadStatus::Unclassified)
                .count(),
            pending_pickers: self.pending_pickers,
            spawn_error: self.spawn_error.clone(),
        }
    }
}
impl Drop for WorkerOwner {
    fn drop(&mut self) {
        self.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};
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
    thread_local! { static TLS_GATE:std::cell::RefCell<Option<TlsGate>>=const { std::cell::RefCell::new(None) }; }
    fn wait(owner: &mut WorkerOwner) -> ShutdownStatus {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let status = owner.status();
            if status.unjoined == 0 {
                return status;
            }
            assert!(Instant::now() < deadline, "fake owner did not join");
            std::thread::yield_now();
        }
    }
    #[test]
    fn semantic_reply_does_not_release_tls_worker_slot_or_shutdown_ownership() {
        let mut owner = WorkerOwner::default();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (reply_tx, reply_rx) = mpsc::channel();
        assert!(owner.spawn(move |_| {
            TLS_GATE.with(|slot| {
                *slot.borrow_mut() = Some(TlsGate {
                    entered: entered_tx,
                    release: release_rx,
                })
            });
            reply_tx.send("synthetic private reply").unwrap();
        }));
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(reply_rx.try_recv().unwrap(), "synthetic private reply");
        assert!(!owner.can_start());
        owner.close();
        assert_eq!(owner.status().unjoined, 1);
        release_tx.send(()).unwrap();
        let status = wait(&mut owner);
        assert!(status.closed);
        assert_eq!(status.returned, 1);
        assert_eq!(status.panicked, 0);
        assert!(!owner.spawn(|_| panic!("closed owner must not spawn")));
    }
    #[test]
    fn panic_is_sticky_and_join_ack_waits_for_tls_cleanup() {
        let mut owner = WorkerOwner::default();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        assert!(owner.spawn(move |_| {
            TLS_GATE.with(|slot| {
                *slot.borrow_mut() = Some(TlsGate {
                    entered: entered_tx,
                    release: release_rx,
                })
            });
            panic!("synthetic workflow panic");
        }));
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        owner.close();
        assert_eq!(owner.status().unjoined, 1);
        release_tx.send(()).unwrap();
        let status = wait(&mut owner);
        assert_eq!(status.panicked, 1);
        assert_eq!(status.returned, 0);
        assert_eq!(owner.status(), status);
    }
    #[test]
    fn picker_completion_is_counted_after_close_and_cannot_admit_work() {
        let mut owner = WorkerOwner::default();
        assert!(owner.begin_picker());
        assert!(!owner.can_start());
        owner.close();
        assert_eq!(owner.status().pending_pickers, 1);
        assert!(!owner.finish_picker());
        assert_eq!(owner.status().pending_pickers, 0);
        assert!(!owner.begin_picker());
        assert!(!owner.spawn(|_| panic!("late picker must not spawn")));
    }
    #[test]
    fn admitted_but_not_started_effect_rechecks_closed_flag() {
        let mut owner = WorkerOwner::default();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let effects = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let calls = effects.clone();
        assert!(owner.spawn(move |admission| {
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            if admission.allowed() {
                calls.fetch_add(1, Ordering::SeqCst);
            }
        }));
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        owner.close();
        release_tx.send(()).unwrap();
        assert_eq!(wait(&mut owner).returned, 1);
        assert_eq!(effects.load(Ordering::SeqCst), 0);
    }
}
