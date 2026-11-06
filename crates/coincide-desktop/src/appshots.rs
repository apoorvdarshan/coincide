//! Main-thread Appshots owner. Native hooks are scoped to enabled settings;
//! captures run in one owned, bounded worker with generation cancellation.
use super::*;
use coincide_core::{
    api::{AppshotTicket, PreparedAppshot},
    appshots::{Destination, Settings},
};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
    mpsc::{self, Receiver, SyncSender},
};

pub(super) struct State {
    applied: Option<Settings>,
    pub permissions: appshots_platform::Permissions,
    pub status: String,
    pub outcome: String,
    pub recording: bool,
    pub shortcut_focus: FocusHandle,
    destination: Destination,
    generation: Arc<AtomicU64>,
    workers: worker_owner::WorkerOwner,
    tx: SyncSender<(u64, AppshotTicket, Result<PreparedAppshot>)>,
    rx: Receiver<(u64, AppshotTicket, Result<PreparedAppshot>)>,
    closed: bool,
}
impl State {
    pub fn new(cx: &mut App) -> Self {
        let (tx, rx) = mpsc::sync_channel(1);
        Self {
            applied: None,
            permissions: Default::default(),
            status: "Off".into(),
            outcome: String::new(),
            recording: false,
            shortcut_focus: cx.focus_handle(),
            destination: Default::default(),
            generation: Arc::new(AtomicU64::new(0)),
            workers: Default::default(),
            tx,
            rx,
            closed: false,
        }
    }
    pub fn sync(&mut self, raw: &Value) {
        if self.closed {
            return;
        }
        let settings = Settings::read(raw);
        if self.applied.as_ref() == Some(&settings) {
            return;
        }
        self.generation.fetch_add(1, Ordering::AcqRel);
        appshots_platform::stop();
        self.applied = Some(settings.clone());
        if !settings.enabled {
            self.status = "Off".into();
            return;
        }
        self.permissions = appshots_platform::permissions(0);
        if self.recording {
            self.status = "Recording a shortcut…".into();
            return;
        }
        let shortcut = if settings.custom {
            let Some(shortcut) = settings.shortcut.as_deref() else {
                self.status = "Record a shortcut".into();
                return;
            };
            Some(shortcut)
        } else {
            None
        };
        self.status = match appshots_platform::configure(shortcut) {
            Ok(()) => {
                if !self.permissions.screen {
                    "Waiting for Screen Recording access".into()
                } else {
                    format!(
                        "Ready: press {}",
                        shortcut.unwrap_or(if cfg!(target_os = "macos") {
                            "both ⌘ keys"
                        } else {
                            "both primary modifier keys"
                        })
                    )
                }
            }
            Err(error) => error.to_string(),
        };
    }
    pub fn invalidate(&mut self) {
        self.applied = None;
    }
    pub fn close(&mut self) {
        if !self.closed {
            self.closed = true;
            self.generation.fetch_add(1, Ordering::AcqRel);
            appshots_platform::stop();
            self.workers.close();
        }
    }
    pub fn drained(&mut self) -> bool {
        let status = self.workers.status();
        self.closed && status.unjoined == 0 && status.panicked == 0 && status.unclassified == 0
    }
}
impl Drop for State {
    fn drop(&mut self) {
        self.close();
    }
}
impl Coincide {
    pub(super) fn record_appshot_interaction(&mut self) {
        if self.settings_open || self.media.close_requested || self.media.shutdown_requested {
            return;
        }
        let target = self
            .selected
            .as_ref()
            .filter(|thread| thread["isArchived"] != true)
            .map(|thread| text(thread, "id"));
        self.appshots
            .destination
            .interact(target, std::time::Instant::now());
    }
    pub(super) fn poll_appshots(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.media.shutdown_requested || self.media.close_requested {
            self.appshots.close();
        }
        self.appshots.workers.poll();
        while let Ok((generation, ticket, result)) = self.appshots.rx.try_recv() {
            if generation != self.appshots.generation.load(Ordering::Acquire)
                || self.appshots.closed
            {
                continue;
            }
            let result = result.and_then(|prepared| {
                try_state(&self.engine)?.native_appshot_deliver(ticket, prepared)
            });
            match result {
                Ok(thread) => {
                    let id = text(&thread, "id");
                    self.appshots
                        .destination
                        .interact(Some(id.clone()), std::time::Instant::now());
                    self.refresh(cx);
                    self.select(&id, window, cx);
                    if Settings::read(&self.settings).sound {
                        appshots_platform::sound();
                    }
                    self.appshots.outcome =
                        "Appshot added to the draft. It has not been sent.".into();
                    window.activate_window();
                    self.composer.read(cx).focus_handle(cx).focus(window, cx);
                }
                Err(error) => self.appshots.outcome = error.to_string(),
            }
            self.status = self.appshots.outcome.clone();
            cx.notify();
        }
        if self.appshots.closed {
            return;
        }
        self.appshots.sync(&self.settings);
        if !appshots_platform::triggered() {
            return;
        }
        if !self.appshots.workers.can_start() {
            self.appshots.outcome = "An appshot is already being captured".into();
            return;
        }
        let admitted = (|| -> Result<_> {
            let mut owner = try_state(&self.engine)?;
            let ticket = owner.native_appshot_admit(
                self.appshots.destination.target(std::time::Instant::now()),
            )?;
            Ok((ticket, owner.store.data_directory()?))
        })();
        let (ticket, root) = match admitted {
            Ok(value) => value,
            Err(error) => {
                self.appshots.outcome = error.to_string();
                return;
            }
        };
        let generation = self.appshots.generation.load(Ordering::Acquire);
        let stamp = self.appshots.generation.clone();
        let tx = self.appshots.tx.clone();
        let read_text = Settings::read(&self.settings).includes_text;
        self.appshots.workers.spawn(move |admission| {
            let result = admitted_capture(&admission, generation, &stamp, |allowed| {
                let capture = appshots_platform::capture(read_text, allowed)?;
                anyhow::ensure!(allowed(), "Appshot cancelled");
                PreparedAppshot::prepare(
                    &root,
                    &capture.png,
                    capture.app,
                    capture.title,
                    if read_text { capture.text } else { None },
                )
            });
            if let Some(result) = result {
                let _ = tx.try_send((generation, ticket, result));
            }
        });
        cx.notify();
    }
}

/// The production worker and synthetic tests share cancellation/publication
/// admission. A semantic return never releases WorkerOwner's actual join slot.
fn admitted_capture<T>(
    admission: &worker_owner::Admission,
    generation: u64,
    stamp: &AtomicU64,
    capture: impl FnOnce(&dyn Fn() -> bool) -> Result<T>,
) -> Option<Result<T>> {
    let allowed = || admission.allowed() && generation == stamp.load(Ordering::Acquire);
    if !allowed() {
        return None;
    }
    let result = capture(&allowed);
    allowed().then_some(result)
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};
    struct ExitGate {
        entered: mpsc::Sender<()>,
        release: mpsc::Receiver<()>,
    }
    impl Drop for ExitGate {
        fn drop(&mut self) {
            let _ = self.entered.send(());
            let _ = self.release.recv();
        }
    }
    thread_local! {static EXIT:std::cell::RefCell<Option<ExitGate>>=const{std::cell::RefCell::new(None)};}
    #[::core::prelude::v1::test]
    fn disable_discards_late_fake_capture_and_retains_actual_thread_custody() {
        let mut owner = worker_owner::WorkerOwner::default();
        let stamp = Arc::new(AtomicU64::new(1));
        let worker_stamp = stamp.clone();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (exit_tx, exit_rx) = mpsc::channel();
        let (join_tx, join_rx) = mpsc::channel();
        let (result_tx, result_rx) = mpsc::channel();
        assert!(owner.spawn(move |admission| {
            EXIT.with(|gate| {
                *gate.borrow_mut() = Some(ExitGate {
                    entered: exit_tx,
                    release: join_rx,
                })
            });
            let result = admitted_capture(&admission, 1, &worker_stamp, |_| {
                entered_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                Ok(7)
            });
            result_tx
                .send(result.map(|result| result.unwrap()))
                .unwrap();
        }));
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(!owner.can_start());
        stamp.fetch_add(1, Ordering::AcqRel);
        owner.close();
        assert_eq!(owner.status().unjoined, 1);
        release_tx.send(()).unwrap();
        assert_eq!(
            result_rx.recv_timeout(Duration::from_secs(5)).unwrap(),
            None
        );
        exit_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(
            owner.status().unjoined,
            1,
            "semantic cancellation is not a join"
        );
        join_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let status = owner.status();
            if status.unjoined == 0 {
                assert_eq!(status.returned, 1);
                break;
            }
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
    }
    #[::core::prelude::v1::test]
    fn unchanged_generation_publishes_one_fake_capture() {
        let mut owner = worker_owner::WorkerOwner::default();
        let stamp = AtomicU64::new(3);
        let (tx, rx) = mpsc::channel();
        assert!(owner.spawn(move |admission| {
            let result = admitted_capture(&admission, 3, &stamp, |allowed| {
                assert!(allowed());
                Ok(9)
            });
            tx.send(result.map(|value| value.unwrap())).unwrap();
        }));
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), Some(9));
        owner.close();
        let deadline = Instant::now() + Duration::from_secs(5);
        while owner.status().unjoined != 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
    }
}
