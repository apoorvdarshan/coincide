//! One owned metadata read at a time. Readiness polling never runs a provider,
//! reassigns the selected conversation, or performs filesystem reads on GPUI.
use super::*;
use crate::worker_owner::{ShutdownStatus, WorkerOwner};
use std::{
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
const CADENCE: Duration = Duration::from_secs(1);
enum Outcome {
    Retry(&'static str),
    Ready(Result<Value>),
}
struct Pending {
    generation: u64,
    scope: Scope,
    receiver: mpsc::Receiver<Outcome>,
}
#[derive(Default)]
pub(super) struct Reader {
    workers: WorkerOwner,
    epoch: Arc<AtomicU64>,
    pending: Option<Pending>,
    last_attempt: Option<Instant>,
}
fn waiting(cached: bool, reason: &'static str) -> Read {
    if cached {
        Read::Cached
    } else {
        Read::Pending(reason)
    }
}
fn handoff_pending(engine: &Engine, scope: &Scope) -> Option<&'static str> {
    if engine
        .requested_open
        .as_ref()
        .is_some_and(|id| id != &scope.0)
    {
        Some("Selection is waiting for the requested conversation to open")
    } else if engine.active_thread() != Some(scope.0.as_str()) {
        Some("Selection is waiting for the conversation owner to acknowledge this thread")
    } else {
        None
    }
}
impl Reader {
    pub(super) fn invalidate(&mut self) {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        self.last_attempt = None;
        // Keep the channel and actual worker owner until the worker has joined.
    }
    pub(super) fn refresh_due(&self) -> bool {
        self.pending.is_some()
            || self
                .last_attempt
                .is_none_or(|started| started.elapsed() >= CADENCE)
    }
    pub(super) fn request_shutdown(&mut self) {
        if self.workers.close() {
            self.invalidate();
        }
    }
    pub(super) fn shutdown_status(&mut self) -> ShutdownStatus {
        self.workers.status()
    }
    pub(super) fn read_with(
        &mut self,
        shared: &SharedEngine,
        scope: &Scope,
        cached: bool,
        load: impl FnOnce(&mut Engine, &str) -> Result<Value> + Send + 'static,
    ) -> Read {
        let status = self.workers.status();
        if status.closed {
            return Read::Pending("Application admission is closed");
        }
        if self.pending.is_some() {
            if status.unjoined != 0 {
                return waiting(cached, "Selection capabilities are being refreshed");
            }
            let pending = self.pending.as_ref().unwrap();
            if pending.generation == self.epoch.load(Ordering::Acquire) && &pending.scope == scope {
                let engine = match shared.try_lock() {
                    Ok(engine) => engine,
                    Err(TryLockError::WouldBlock) => {
                        return waiting(cached, "Selection is waiting for the conversation owner");
                    }
                    Err(TryLockError::Poisoned(_)) => {
                        self.pending = None;
                        return Read::Ready(Err(anyhow::anyhow!(
                            "Conversation state is unavailable"
                        )));
                    }
                };
                if let Some(reason) = handoff_pending(&engine, scope) {
                    self.pending = None;
                    self.last_attempt = None;
                    return Read::Pending(reason);
                }
                if engine.admissions_frozen() {
                    self.pending = None;
                    return Read::Ready(Err(anyhow::anyhow!("Application admission is closed")));
                }
            }
            let completed = self.pending.take().unwrap();
            if completed.generation == self.epoch.load(Ordering::Acquire)
                && &completed.scope == scope
            {
                self.last_attempt = Some(Instant::now());
                return match completed.receiver.try_recv() {
                    Ok(Outcome::Ready(result)) => Read::Ready(result),
                    Ok(Outcome::Retry(reason)) => waiting(cached, reason),
                    Err(_) => Read::Ready(Err(anyhow::anyhow!(
                        "Capability reader returned without a complete response"
                    ))),
                };
            }
        }
        if status.panicked != 0 || status.unclassified != 0 || status.spawn_error.is_some() {
            return Read::Ready(Err(anyhow::anyhow!(
                "Capability reader ownership failed; close and reopen this app"
            )));
        }
        if !self.refresh_due() {
            return waiting(cached, "Selection capabilities are waiting to refresh");
        }
        // Only in-memory handoff flags are read on the UI thread. The Store,
        // auth/executable stamps, and instruction hashes are read by the worker.
        {
            let engine = match shared.try_lock() {
                Ok(engine) => engine,
                Err(TryLockError::WouldBlock) => {
                    return waiting(cached, "Selection is waiting for the conversation owner");
                }
                Err(TryLockError::Poisoned(_)) => {
                    return Read::Ready(Err(anyhow::anyhow!("Conversation state is unavailable")));
                }
            };
            if engine.admissions_frozen() {
                return Read::Ready(Err(anyhow::anyhow!("Application admission is closed")));
            }
            if let Some(reason) = handoff_pending(&engine, scope) {
                return Read::Pending(reason);
            }
        }
        let shared = shared.clone();
        let epoch = self.epoch.clone();
        let generation = epoch.load(Ordering::Acquire);
        let target = scope.clone();
        let (sender, receiver) = mpsc::channel();
        let started = self.workers.spawn(move |admission| {
            let allowed = || admission.allowed() && epoch.load(Ordering::Acquire) == generation;
            let outcome = (|| {
                if !allowed() {
                    return Outcome::Retry("Capability refresh was superseded");
                }
                let mut engine = match shared.try_lock() {
                    Ok(engine) => engine,
                    Err(TryLockError::WouldBlock) => {
                        return Outcome::Retry("Selection is waiting for the conversation owner");
                    }
                    Err(TryLockError::Poisoned(_)) => {
                        return Outcome::Ready(Err(anyhow::anyhow!(
                            "Conversation state is unavailable"
                        )));
                    }
                };
                if let Some(reason) = handoff_pending(&engine, &target) {
                    return Outcome::Retry(reason);
                }
                let result = (|| {
                    anyhow::ensure!(
                        allowed() && !engine.admissions_frozen(),
                        "Capability refresh was superseded"
                    );
                    let current = engine.store.thread(&target.0)?;
                    anyhow::ensure!(
                        selection_envelope(&current) == target.1,
                        "Saved selection changed; reload before refreshing capabilities"
                    );
                    let value = load(&mut engine, &target.0)?;
                    anyhow::ensure!(
                        allowed() && !engine.admissions_frozen(),
                        "Capability refresh was superseded"
                    );
                    anyhow::ensure!(
                        handoff_pending(&engine, &target).is_none(),
                        "Selected conversation changed during capability refresh"
                    );
                    anyhow::ensure!(
                        selection_envelope(&engine.store.thread(&target.0)?) == target.1,
                        "Saved selection changed during capability refresh"
                    );
                    Ok(value)
                })();
                Outcome::Ready(result)
            })();
            let _ = sender.send(outcome);
        });
        if started {
            self.last_attempt = Some(Instant::now());
            self.pending = Some(Pending {
                generation,
                scope: scope.clone(),
                receiver,
            });
            waiting(cached, "Selection capabilities are being refreshed")
        } else {
            Read::Ready(Err(anyhow::anyhow!("Capability reader could not start")))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        cell::RefCell,
        path::PathBuf,
        sync::{Mutex, atomic::AtomicUsize},
    };
    struct Fixture(PathBuf);
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn fixture() -> (Fixture, SharedEngine, Scope, Scope) {
        let dir = Fixture(std::env::temp_dir().join(format!(
            "coincide-named-capability-reader-{}",
            uuid::Uuid::new_v4()
        )));
        coincide_core::native_file::private_directory(&dir.0).unwrap();
        let mut engine = Engine::new(Store::open(&dir.0.join("state.sqlite")).unwrap());
        let mut a = selection_response(&mut engine, "threads.create", json!({})).unwrap();
        let b = selection_response(&mut engine, "threads.create", json!({})).unwrap();
        engine.set_active_thread(Some(text(&a, "id"))).unwrap();
        a["selection"]["provider"] = json!("codex");
        a["selection"]["accountID"] = json!(uuid::Uuid::new_v4().to_string());
        engine.store.save(&a).unwrap();
        let a = (text(&a, "id"), selection_envelope(&a), false);
        let b = (text(&b, "id"), selection_envelope(&b), false);
        (dir, Arc::new(Mutex::new(engine)), a, b)
    }
    fn until_ready(
        reader: &mut Reader,
        shared: &SharedEngine,
        scope: &Scope,
        value: &str,
    ) -> Value {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let expected = value.to_owned();
            if let Read::Ready(result) =
                reader.read_with(shared, scope, false, move |_, _| Ok(json!(expected)))
            {
                return result.unwrap();
            }
            assert!(
                Instant::now() < deadline,
                "Owned capability read did not finish"
            );
            std::thread::yield_now();
        }
    }
    #[::core::prelude::v1::test]
    fn named_read_waits_for_native_handoff_without_claiming_another_active_thread() {
        let (_dir, shared, a, b) = fixture();
        let mut reader = Reader::default();
        assert!(matches!(
            reader.read_with(&shared, &b, false, |_, _| panic!(
                "Unacknowledged target must not read"
            )),
            Read::Pending(_)
        ));
        assert_eq!(shared.lock().unwrap().active_thread(), Some(a.0.as_str()));
        assert_eq!(reader.shutdown_status().returned, 0);
        shared.lock().unwrap().requested_open = Some(b.0.clone());
        assert!(matches!(
            reader.read_with(&shared, &a, false, |_, _| panic!(
                "Pending open must not read"
            )),
            Read::Pending(_)
        ));
        assert_eq!(shared.lock().unwrap().active_thread(), Some(a.0.as_str()));
        assert_eq!(reader.shutdown_status().unjoined, 0);
        shared.lock().unwrap().requested_open = None;
        assert_eq!(
            until_ready(&mut reader, &shared, &a, "acknowledged"),
            json!("acknowledged")
        );
    }
    #[::core::prelude::v1::test]
    fn named_metadata_runs_off_ui_once_and_keeps_same_scope_cache_during_refresh() {
        let (_dir, shared, a, _b) = fixture();
        let mut reader = Reader::default();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let ui_thread = std::thread::current().id();
        let calls = Arc::new(AtomicUsize::new(0));
        let observed = calls.clone();
        assert!(matches!(
            reader.read_with(&shared, &a, false, move |_, _| {
                assert_ne!(std::thread::current().id(), ui_thread);
                observed.fetch_add(1, Ordering::SeqCst);
                entered_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                Ok(json!("ready"))
            }),
            Read::Pending(_)
        ));
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        for _ in 0..8 {
            assert!(matches!(
                reader.read_with(&shared, &a, true, |_, _| panic!(
                    "Only one read may own the slot"
                )),
                Read::Cached
            ));
            assert_eq!(reader.shutdown_status().unjoined, 1);
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        release_tx.send(()).unwrap();
        assert_eq!(
            until_ready(&mut reader, &shared, &a, "unexpected"),
            json!("ready")
        );
        assert!(!reader.refresh_due());
        assert!(matches!(
            reader.read_with(&shared, &a, true, |_, _| panic!(
                "Cadence must prevent per-frame reads"
            )),
            Read::Cached
        ));
        reader.last_attempt = Some(Instant::now() - CADENCE);
        assert!(reader.refresh_due());
        assert_eq!(
            until_ready(&mut reader, &shared, &a, "after cadence"),
            json!("after cadence")
        );
        reader.request_shutdown();
        assert_eq!(reader.shutdown_status().returned, 2);
    }
    #[::core::prelude::v1::test]
    fn invalidation_a_b_a_discards_old_reply_and_retains_worker_custody() {
        let (_dir, shared, a, _b) = fixture();
        let mut reader = Reader::default();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        assert!(matches!(
            reader.read_with(&shared, &a, false, move |_, _| {
                entered_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                Ok(json!("old reply must not publish"))
            }),
            Read::Pending(_)
        ));
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        reader.invalidate();
        reader.invalidate();
        assert!(matches!(
            reader.read_with(&shared, &a, false, |_, _| panic!(
                "Old actual worker has not joined"
            )),
            Read::Pending(_)
        ));
        assert_eq!(reader.shutdown_status().unjoined, 1);
        release_tx.send(()).unwrap();
        assert_eq!(
            until_ready(&mut reader, &shared, &a, "new reply"),
            json!("new reply")
        );
        assert_eq!(reader.shutdown_status().returned, 2);
    }
    struct TlsGate {
        entered: mpsc::Sender<()>,
        release: mpsc::Receiver<()>,
    }
    impl Drop for TlsGate {
        fn drop(&mut self) {
            self.entered.send(()).unwrap();
            self.release.recv().unwrap();
        }
    }
    thread_local! { static TLS_GATE:RefCell<Option<TlsGate>>=const {RefCell::new(None)}; }
    #[::core::prelude::v1::test]
    fn completed_reply_cannot_publish_after_another_native_open_was_requested() {
        let (_dir, shared, a, b) = fixture();
        let mut reader = Reader::default();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        assert!(matches!(
            reader.read_with(&shared, &a, false, move |_, _| {
                TLS_GATE.with(|gate| {
                    *gate.borrow_mut() = Some(TlsGate {
                        entered: entered_tx,
                        release: release_rx,
                    })
                });
                Ok(json!("stale target"))
            }),
            Read::Pending(_)
        ));
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        shared.lock().unwrap().requested_open = Some(b.0.clone());
        release_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while reader.shutdown_status().unjoined != 0 {
            assert!(Instant::now() < deadline, "Actual reader did not return");
            std::thread::yield_now();
        }
        assert!(matches!(
            reader.read_with(&shared, &a, true, |_, _| panic!(
                "Pending native open must not admit a replacement read"
            )),
            Read::Pending(_)
        ));
        assert_eq!(shared.lock().unwrap().active_thread(), Some(a.0.as_str()));
        assert_eq!(reader.shutdown_status().returned, 1);
        reader.request_shutdown();
    }
    #[::core::prelude::v1::test]
    fn quit_waits_for_actual_tls_return_even_after_capability_reply_is_ready() {
        let (_dir, shared, a, _b) = fixture();
        let mut reader = Reader::default();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        assert!(matches!(
            reader.read_with(&shared, &a, false, move |_, _| {
                TLS_GATE.with(|gate| {
                    *gate.borrow_mut() = Some(TlsGate {
                        entered: entered_tx,
                        release: release_rx,
                    })
                });
                Ok(json!("ready before actual TLS return"))
            }),
            Read::Pending(_)
        ));
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(matches!(
            reader.read_with(&shared, &a, false, |_, _| panic!("TLS is still owned")),
            Read::Pending(_)
        ));
        reader.request_shutdown();
        assert_eq!(reader.shutdown_status().unjoined, 1);
        assert!(reader.shutdown_status().closed);
        release_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while reader.shutdown_status().unjoined != 0 {
            assert!(Instant::now() < deadline, "TLS worker did not return");
            std::thread::yield_now();
        }
        let status = reader.shutdown_status();
        assert_eq!(status.returned, 1);
        assert_eq!(status.panicked, 0);
        assert!(matches!(
            reader.read_with(&shared, &a, false, |_, _| panic!(
                "Closed reader must not spawn"
            )),
            Read::Pending(_)
        ));
    }
}
