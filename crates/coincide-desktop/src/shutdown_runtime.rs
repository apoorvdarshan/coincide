//! Explicit normal-quit owner. All Engine recovery, control waits and Store close
//! run off UI. External native/UI/draft drain proof belongs to the parent.
use anyhow::{Context, Result, ensure};
use coincide_core::{
    agent::{WorkerCompletion, WorkerThreadStatus},
    api::SharedEngine,
    control::{self, WorkerStatus},
};
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Starting,
    DrainingCore,
    WaitingExternal,
    StoppingControl,
    WaitingControl,
    ClosingStore,
    Complete,
    Failed,
}
#[derive(Clone, Debug)]
pub struct Status {
    pub phase: Phase,
    pub actual_worker_status: WorkerThreadStatus,
    pub error: Option<String>,
}
impl Status {
    /// Only meaningful with the parent's still-valid external-owner drain proof.
    pub fn complete(&self) -> bool {
        self.phase == Phase::Complete
            && self.actual_worker_status == WorkerThreadStatus::Returned
            && self.error.is_none()
    }
}
struct Observation {
    phase: Phase,
    error: Option<String>,
}
pub struct Runtime {
    external_drained: Arc<AtomicBool>,
    observation: Arc<Mutex<Observation>>,
    completion: WorkerCompletion,
    // Keep failed/pending owners alive; no parent/control teardown on worker error.
    _engine: SharedEngine,
    _control: Arc<Mutex<control::Server>>,
}
impl Runtime {
    /// Explicit global quit only. No automatic updater, native action or JSON route.
    pub fn start(engine: SharedEngine, control: Arc<Mutex<control::Server>>) -> Result<Self> {
        let external_drained = Arc::new(AtomicBool::new(false));
        let observation = Arc::new(Mutex::new(Observation {
            phase: Phase::Starting,
            error: None,
        }));
        let gate = external_drained.clone();
        let visible = observation.clone();
        let backend = NativeOwner {
            engine: engine.clone(),
            control: control.clone(),
            external_drained: external_drained.clone(),
        };
        let worker = thread::Builder::new()
            .name("coincide-quit-drain".into())
            .spawn(move || run(backend, &gate, &visible))
            .context("Start quit drain worker")?;
        Ok(Self {
            external_drained,
            observation,
            completion: WorkerCompletion::observe(worker),
            _engine: engine,
            _control: control,
        })
    }
    pub fn set_external_drained(&self, drained: bool) {
        self.external_drained.store(drained, Ordering::Release);
    }
    /// Never takes an Engine/control lock, waits, or joins. Failed lock is unknown.
    pub fn status(&self) -> Status {
        let mut status = observed_status(&self.observation, &self.completion);
        if status.phase == Phase::Complete && !self.external_drained.load(Ordering::Acquire) {
            status.phase = Phase::WaitingExternal;
        }
        status
    }
}
fn observed_status(observation: &Mutex<Observation>, completion: &WorkerCompletion) -> Status {
    let actual_worker_status = completion.status();
    let observation = match observation.try_lock() {
        Ok(observation) => observation,
        Err(std::sync::TryLockError::WouldBlock) => {
            return Status {
                phase: Phase::Starting,
                actual_worker_status,
                error: None,
            };
        }
        Err(std::sync::TryLockError::Poisoned(_)) => {
            return Status {
                phase: Phase::Failed,
                actual_worker_status,
                error: Some("Quit drain observation is unavailable".into()),
            };
        }
    };
    if matches!(
        actual_worker_status,
        WorkerThreadStatus::Panicked | WorkerThreadStatus::Unclassified
    ) {
        return Status {
            phase: Phase::Failed,
            actual_worker_status,
            error: Some(
                "Quit drain worker did not return with a classified join acknowledgment".into(),
            ),
        };
    }
    Status {
        phase: observation.phase,
        actual_worker_status,
        error: observation.error.clone(),
    }
}
trait Owner {
    fn request_core(&mut self) -> Result<()>;
    fn core_drained(&mut self) -> Result<bool>;
    fn request_control_stop(&mut self) -> Result<()>;
    fn control_status(&mut self) -> Result<WorkerStatus>;
    fn close_store(&mut self) -> Result<bool>;
}
struct NativeOwner {
    engine: SharedEngine,
    control: Arc<Mutex<control::Server>>,
    external_drained: Arc<AtomicBool>,
}
impl Owner for NativeOwner {
    fn request_core(&mut self) -> Result<()> {
        self.engine
            .lock()
            .map_err(|_| anyhow::anyhow!("Engine unavailable"))?
            .request_core_owner_shutdown()
    }
    fn core_drained(&mut self) -> Result<bool> {
        Ok(self
            .engine
            .lock()
            .map_err(|_| anyhow::anyhow!("Engine unavailable"))?
            .poll_core_owner_shutdown()?
            .rust_owners_drained())
    }
    fn request_control_stop(&mut self) -> Result<()> {
        self.control
            .lock()
            .map_err(|_| anyhow::anyhow!("Control owner unavailable"))?
            .request_stop();
        Ok(())
    }
    fn control_status(&mut self) -> Result<WorkerStatus> {
        Ok(self
            .control
            .lock()
            .map_err(|_| anyhow::anyhow!("Control owner unavailable"))?
            .worker_status())
    }
    fn close_store(&mut self) -> Result<bool> {
        let mut engine = self
            .engine
            .lock()
            .map_err(|_| anyhow::anyhow!("Engine unavailable"))?;
        if !self.external_drained.load(Ordering::Acquire) {
            return Ok(false);
        }
        engine.close_store_after_core_shutdown()?;
        ensure!(engine.store.is_closed(), "Store close was not acknowledged");
        Ok(true)
    }
}
struct Driver {
    requested: bool,
    control_stopped: bool,
    store_closing: bool,
}
impl Driver {
    fn step(&mut self, owner: &mut impl Owner, external: &AtomicBool) -> Result<Phase> {
        if !self.requested {
            self.requested = true;
            owner.request_core()?;
        }
        if !owner.core_drained()? {
            return Ok(Phase::DrainingCore);
        }
        if !external.load(Ordering::Acquire) {
            return Ok(Phase::WaitingExternal);
        }
        if !self.control_stopped {
            owner.request_control_stop()?;
            self.control_stopped = true;
            return Ok(Phase::StoppingControl);
        }
        match owner.control_status()? {
            WorkerStatus::Running => return Ok(Phase::WaitingControl),
            WorkerStatus::Returned => {}
            WorkerStatus::Panicked | WorkerStatus::Unclassified => {
                anyhow::bail!("Control worker did not return with a classified join acknowledgment")
            }
        }
        // The external proof can be revoked while the public control owner drains.
        if !external.load(Ordering::Acquire) {
            return Ok(Phase::WaitingExternal);
        }
        if !self.store_closing {
            self.store_closing = true;
            return Ok(Phase::ClosingStore);
        }
        if !owner.close_store()? {
            return Ok(Phase::WaitingExternal);
        }
        Ok(Phase::Complete)
    }
}
fn run(mut owner: impl Owner, external: &AtomicBool, observation: &Mutex<Observation>) {
    let mut driver = Driver {
        requested: false,
        control_stopped: false,
        store_closing: false,
    };
    loop {
        let result = driver.step(&mut owner, external);
        let mut status = observation
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        match result {
            Ok(phase) => {
                status.phase = phase;
                if phase == Phase::Complete {
                    return;
                }
            }
            Err(error) => {
                status.phase = Phase::Failed;
                status.error = Some(error.to_string().chars().take(1024).collect());
                return;
            }
        }
        drop(status);
        thread::sleep(Duration::from_millis(25));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Default)]
    struct Fake {
        requests: usize,
        polls: usize,
        core_ready: bool,
        control_requests: usize,
        control_returned: bool,
        control_failed: bool,
        closes: usize,
        close_failed: bool,
        closed: bool,
    }
    impl Owner for Fake {
        fn request_core(&mut self) -> Result<()> {
            self.requests += 1;
            Ok(())
        }
        fn core_drained(&mut self) -> Result<bool> {
            self.polls += 1;
            Ok(self.core_ready)
        }
        fn request_control_stop(&mut self) -> Result<()> {
            self.control_requests += 1;
            Ok(())
        }
        fn control_status(&mut self) -> Result<WorkerStatus> {
            Ok(if self.control_failed {
                WorkerStatus::Panicked
            } else if self.control_returned {
                WorkerStatus::Returned
            } else {
                WorkerStatus::Running
            })
        }
        fn close_store(&mut self) -> Result<bool> {
            self.closes += 1;
            ensure!(!self.close_failed, "synthetic close failure");
            self.closed = true;
            Ok(true)
        }
    }
    #[::core::prelude::v1::test]
    fn staged_driver_waits_for_core_external_and_actual_control_and_rechecks_gate() {
        let mut owner = Fake::default();
        let external = AtomicBool::new(false);
        let mut driver = Driver {
            requested: false,
            control_stopped: false,
            store_closing: false,
        };
        assert_eq!(
            driver.step(&mut owner, &external).unwrap(),
            Phase::DrainingCore
        );
        owner.core_ready = true;
        assert_eq!(
            driver.step(&mut owner, &external).unwrap(),
            Phase::WaitingExternal
        );
        assert_eq!(owner.control_requests, 0);
        assert_eq!(owner.closes, 0);
        external.store(true, Ordering::Release);
        assert_eq!(
            driver.step(&mut owner, &external).unwrap(),
            Phase::StoppingControl
        );
        assert_eq!(
            driver.step(&mut owner, &external).unwrap(),
            Phase::WaitingControl
        );
        owner.control_returned = true;
        assert_eq!(
            driver.step(&mut owner, &external).unwrap(),
            Phase::ClosingStore
        );
        external.store(false, Ordering::Release);
        assert_eq!(
            driver.step(&mut owner, &external).unwrap(),
            Phase::WaitingExternal
        );
        assert_eq!(owner.closes, 0);
        external.store(true, Ordering::Release);
        assert_eq!(driver.step(&mut owner, &external).unwrap(), Phase::Complete);
        assert!(owner.closed);
        assert_eq!(owner.requests, 1);
        assert_eq!(owner.control_requests, 1);
        assert_eq!(owner.closes, 1);
    }
    #[::core::prelude::v1::test]
    fn failed_control_never_closes_store() {
        let mut owner = Fake {
            core_ready: true,
            control_failed: true,
            ..Default::default()
        };
        let external = AtomicBool::new(true);
        let mut driver = Driver {
            requested: false,
            control_stopped: false,
            store_closing: false,
        };
        driver.step(&mut owner, &external).unwrap();
        assert!(driver.step(&mut owner, &external).is_err());
        assert_eq!(owner.closes, 0);
    }
    #[::core::prelude::v1::test]
    fn complete_phase_before_tls_exit_is_not_join_acknowledged() {
        use std::sync::mpsc;
        struct Gate(mpsc::Sender<()>, mpsc::Receiver<()>);
        impl Drop for Gate {
            fn drop(&mut self) {
                let _ = self.0.send(());
                let _ = self.1.recv();
            }
        }
        thread_local! {static EXIT:std::cell::RefCell<Option<Gate>>=const {std::cell::RefCell::new(None)};}
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        struct Release(Option<mpsc::Sender<()>>);
        impl Drop for Release {
            fn drop(&mut self) {
                if let Some(tx) = self.0.take() {
                    let _ = tx.send(());
                }
            }
        }
        let mut release = Release(Some(release_tx));
        let observation = Arc::new(Mutex::new(Observation {
            phase: Phase::Starting,
            error: None,
        }));
        let visible = observation.clone();
        let worker = thread::spawn(move || {
            EXIT.with(|slot| *slot.borrow_mut() = Some(Gate(entered_tx, release_rx)));
            run(
                Fake {
                    core_ready: true,
                    control_returned: true,
                    ..Default::default()
                },
                &AtomicBool::new(true),
                &visible,
            );
        });
        let completion = WorkerCompletion::observe(worker);
        entered_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        let status = observed_status(&observation, &completion);
        assert_eq!(status.phase, Phase::Complete);
        assert!(!status.complete());
        release.0.take().unwrap().send(()).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while !observed_status(&observation, &completion).complete() {
            assert!(std::time::Instant::now() < deadline);
            thread::yield_now();
        }
    }
    #[::core::prelude::v1::test]
    fn close_error_is_failed_and_never_retried_or_complete() {
        let observation = Mutex::new(Observation {
            phase: Phase::Starting,
            error: None,
        });
        run(
            Fake {
                core_ready: true,
                control_returned: true,
                close_failed: true,
                ..Default::default()
            },
            &AtomicBool::new(true),
            &observation,
        );
        let status = observation.lock().unwrap();
        assert_eq!(status.phase, Phase::Failed);
        assert!(
            status
                .error
                .as_ref()
                .unwrap()
                .contains("synthetic close failure")
        );
    }
}
