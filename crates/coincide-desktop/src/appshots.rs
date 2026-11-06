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

#[derive(Default)]
struct CaptureCleanup {
    pending: Vec<PreparedAppshot>,
    error: Option<String>,
}
impl CaptureCleanup {
    fn discard(&mut self, mut capture: PreparedAppshot) {
        if let Err(error) = capture.try_discard() {
            self.error = Some(error.to_string());
            self.pending.push(capture);
        }
    }
    fn retry(&mut self) {
        self.error = None;
        for capture in std::mem::take(&mut self.pending) {
            self.discard(capture);
        }
    }
    fn ready(&self) -> bool {
        self.pending.is_empty() && self.error.is_none()
    }
}
fn discard_completed<T>(
    rx: &Receiver<(u64, T, Result<PreparedAppshot>)>,
    cleanup: &mut CaptureCleanup,
) {
    while let Ok((_, _, result)) = rx.try_recv() {
        if let Ok(capture) = result {
            cleanup.discard(capture);
        }
    }
}
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
    cleanup: CaptureCleanup,
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
            cleanup: Default::default(),
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
        discard_completed(&self.rx, &mut self.cleanup);
        self.cleanup.retry();
        if let Some(error) = &self.cleanup.error {
            self.outcome = format!("Private Appshot cleanup is waiting: {error}");
        }
    }
    pub fn drained(&mut self) -> bool {
        if !self.closed {
            return false;
        }
        let status = self.workers.status();
        // A worker may publish just after close invalidated its generation.
        // Drain after observing the actual join, before advertising readiness.
        discard_completed(&self.rx, &mut self.cleanup);
        self.cleanup.retry();
        if let Some(error) = &self.cleanup.error {
            self.outcome = format!("Private Appshot cleanup is waiting: {error}");
        }
        self.closed
            && status.unjoined == 0
            && status.panicked == 0
            && status.unclassified == 0
            && self.cleanup.ready()
    }
    pub(super) fn private_cleanup_pending(&self) -> bool {
        !self.cleanup.ready()
    }
    pub(super) fn retry_private_cleanup(&mut self) {
        self.cleanup.retry();
        if self.cleanup.ready() {
            self.outcome = "Private Appshot cleanup completed.".into();
        } else if let Some(error) = &self.cleanup.error {
            self.outcome = format!("Private Appshot cleanup is waiting: {error}");
        }
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
                if let Ok(capture) = result {
                    self.appshots.cleanup.discard(capture);
                    if let Some(error) = &self.appshots.cleanup.error {
                        self.appshots.outcome =
                            format!("Private Appshot cleanup is waiting: {error}");
                        cx.notify();
                    }
                }
                continue;
            }
            let result = match result {
                Ok(mut prepared) => {
                    let delivery = (|| {
                        try_state(&self.engine)?.native_appshot_deliver_owned(ticket, &mut prepared)
                    })();
                    if delivery.is_err() {
                        self.appshots.cleanup.discard(prepared);
                    }
                    delivery
                }
                Err(error) => Err(error),
            };
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
        if !self.appshots.cleanup.ready() {
            self.appshots.outcome =
                "Finish private Appshot cleanup in Settings before taking another capture.".into();
            self.settings_open = true;
            self.navigate_settings_section(settings::SettingsSection::Appshots, window, cx);
            self.show_settings_window(cx);
            return;
        }
        self.appshots.permissions = appshots_platform::permissions(0);
        if !self.appshots.permissions.screen {
            self.settings_open = true;
            self.navigate_settings_section(settings::SettingsSection::Appshots, window, cx);
            self.show_settings_window(cx);
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
            if let Some((_admitted, result)) = result {
                // Even a revoked capture remains owned until the parent has an
                // explicit discard receipt. Bounded publication retains join
                // custody while the parent drains during ordinary shutdown.
                if let Err(error) = tx.send((generation, ticket, result)) {
                    if let Ok(mut capture) = error.0.2 {
                        let _ = capture.try_discard();
                    }
                }
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
) -> Option<(bool, Result<T>)> {
    let allowed = || admission.allowed() && generation == stamp.load(Ordering::Acquire);
    if !allowed() {
        return None;
    }
    let result = capture(&allowed);
    Some((allowed(), result))
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
                .send(
                    result
                        .map(|(admitted, result)| admitted.then_some(result.unwrap()))
                        .flatten(),
                )
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
            tx.send(
                result
                    .map(|(admitted, value)| admitted.then_some(value.unwrap()))
                    .flatten(),
            )
            .unwrap();
        }));
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), Some(9));
        owner.close();
        let deadline = Instant::now() + Duration::from_secs(5);
        while owner.status().unjoined != 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
    }
    fn private_capture() -> (std::path::PathBuf, std::path::PathBuf, PreparedAppshot) {
        let root = std::env::temp_dir().join(format!(
            "coincide-appshot-cleanup-fixture-{}",
            uuid::Uuid::new_v4()
        ));
        let store = coincide_core::store::Store::open(&root.join("state.sqlite")).unwrap();
        let data = store.data_directory().unwrap();
        let png = coincide_core::appshots::encode_rgba(2, 2, vec![0; 16]).unwrap();
        let capture =
            PreparedAppshot::prepare(&data, &png, "Private Fixture".into(), None, None).unwrap();
        let directory = std::fs::read_dir(data.join("attachments"))
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        drop(store);
        (root, directory, capture)
    }
    #[::core::prelude::v1::test]
    fn late_revoked_channel_result_is_explicitly_discarded_after_actual_join() {
        let (root, directory, capture) = private_capture();
        let mut owner = worker_owner::WorkerOwner::default();
        let stamp = Arc::new(AtomicU64::new(1));
        let worker_stamp = stamp.clone();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (exit_tx, exit_rx) = mpsc::channel();
        let (join_tx, join_rx) = mpsc::channel();
        let (tx, rx) = mpsc::sync_channel(1);
        assert!(owner.spawn(move |admission| {
            EXIT.with(|slot| {
                *slot.borrow_mut() = Some(ExitGate {
                    entered: exit_tx,
                    release: join_rx,
                })
            });
            let result = admitted_capture(&admission, 1, &worker_stamp, |_| {
                entered_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                Ok(capture)
            })
            .unwrap();
            assert!(
                !result.0,
                "revocation must reject delivery while retaining cleanup ownership"
            );
            tx.send((1, (), result.1)).ok().unwrap();
        }));
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        owner.close();
        stamp.fetch_add(1, Ordering::AcqRel);
        release_tx.send(()).unwrap();
        exit_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(owner.status().unjoined, 1);
        assert!(directory.exists());
        join_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while owner.status().unjoined != 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        let mut cleanup = CaptureCleanup::default();
        discard_completed(&rx, &mut cleanup);
        assert!(cleanup.ready());
        assert!(
            !directory.exists(),
            "receipt must verify generated files removed before readiness"
        );
        std::fs::remove_dir_all(root).unwrap();
    }
    #[::core::prelude::v1::test]
    fn replaced_private_directory_retains_cleanup_custody_until_exact_identity_returns() {
        let (root, directory, capture) = private_capture();
        let moved = directory.with_extension("held-original");
        std::fs::rename(&directory, &moved).unwrap();
        std::fs::create_dir(&directory).unwrap();
        std::fs::write(directory.join("unrelated"), b"keep").unwrap();
        let (tx, rx) = mpsc::sync_channel(1);
        tx.send((1, (), Ok(capture))).ok().unwrap();
        let mut cleanup = CaptureCleanup::default();
        discard_completed(&rx, &mut cleanup);
        assert!(!cleanup.ready());
        assert_eq!(cleanup.pending.len(), 1);
        assert!(cleanup.error.is_some());
        assert_eq!(std::fs::read(directory.join("unrelated")).unwrap(), b"keep");
        std::fs::remove_file(directory.join("unrelated")).unwrap();
        std::fs::remove_dir(&directory).unwrap();
        std::fs::rename(moved, &directory).unwrap();
        cleanup.retry();
        assert!(cleanup.ready());
        assert!(!directory.exists());
        std::fs::remove_dir_all(root).unwrap();
    }
}
