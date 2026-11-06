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
            let allowed = || admission.allowed() && generation == stamp.load(Ordering::Acquire);
            let result = (|| -> Result<_> {
                anyhow::ensure!(allowed(), "Appshot cancelled");
                let capture = appshots_platform::capture(read_text, &allowed)?;
                anyhow::ensure!(allowed(), "Appshot cancelled");
                PreparedAppshot::prepare(
                    &root,
                    &capture.png,
                    capture.app,
                    capture.title,
                    if read_text { capture.text } else { None },
                )
            })();
            if allowed() {
                let _ = tx.try_send((generation, ticket, result));
            }
        });
        cx.notify();
    }
}
