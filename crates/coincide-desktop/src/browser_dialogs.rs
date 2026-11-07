//! Native page dialogs. Each responder is one-use and owned by one actual tab.
use anyhow::{Result, ensure};
use serde::Serialize;
use std::{
    cell::RefCell,
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};
use uuid::Uuid;

#[cfg(target_os = "macos")]
#[path = "browser_dialogs_macos.rs"]
mod platform;
#[cfg(target_os = "linux")]
#[path = "browser_dialogs_linux.rs"]
mod platform;
#[cfg(target_os = "windows")]
#[path = "browser_dialogs_windows.rs"]
mod platform;

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Alert,
    Confirm,
    Prompt,
    BeforeUnload,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub id: String,
    pub kind: Kind,
    pub message: String,
    pub default_text: Option<String>,
}
struct Pending {
    snapshot: Snapshot,
    epoch: u64,
    respond: Option<Box<dyn FnOnce(bool, Option<String>) -> Result<()>>>,
}
impl Drop for Pending {
    fn drop(&mut self) {
        if let Some(respond) = self.respond.take() {
            let _ = respond(false, None);
        }
    }
}
struct State {
    pending: Option<Pending>,
    closed: bool,
    navigation: Arc<AtomicU64>,
    owner_closed: Arc<AtomicBool>,
    changed: Rc<dyn Fn()>,
}
#[derive(Clone)]
pub(super) struct Sink(Rc<RefCell<State>>);
impl Sink {
    fn new(
        navigation: Arc<AtomicU64>,
        owner_closed: Arc<AtomicBool>,
        changed: impl Fn() + 'static,
    ) -> Self {
        Self(Rc::new(RefCell::new(State {
            pending: None,
            closed: false,
            navigation,
            owner_closed,
            changed: Rc::new(changed),
        })))
    }
    pub(super) fn open(
        &self,
        kind: Kind,
        message: String,
        default_text: Option<String>,
        respond: impl FnOnce(bool, Option<String>) -> Result<()> + 'static,
    ) {
        let mut incoming = Pending {
            snapshot: Snapshot {
                id: Uuid::new_v4().to_string(),
                kind,
                message,
                default_text,
            },
            epoch: 0,
            respond: Some(Box::new(respond)),
        };
        let admitted = {
            let mut state = self.0.borrow_mut();
            if state.closed
                || state.owner_closed.load(Ordering::Acquire)
                || state.pending.is_some()
                || incoming.snapshot.message.len() > 16 * 1024
                || incoming
                    .snapshot
                    .default_text
                    .as_ref()
                    .is_some_and(|text| text.len() > 64 * 1024)
            {
                false
            } else {
                incoming.epoch = state.navigation.load(Ordering::Acquire);
                state.pending = Some(incoming);
                true
            }
        };
        // Neither native completion nor notification may run under RefCell's
        // mutable borrow: completing a dialog can synchronously reenter WebKit.
        if admitted {
            let changed = self.0.borrow().changed.clone();
            changed();
        }
    }
    fn take_stale(&self) -> Option<Pending> {
        let mut state = self.0.borrow_mut();
        let stale = state.closed
            || state.owner_closed.load(Ordering::Acquire)
            || state
                .pending
                .as_ref()
                .is_some_and(|p| p.epoch != state.navigation.load(Ordering::Acquire));
        if stale { state.pending.take() } else { None }
    }
    fn snapshot(&self) -> Option<Snapshot> {
        drop(self.take_stale());
        self.0.borrow().pending.as_ref().map(|p| p.snapshot.clone())
    }
    fn answer(&self, id: &str, accept: bool, text: Option<String>) -> Result<Kind> {
        ensure!(
            text.as_ref().is_none_or(|text| text.len() <= 64 * 1024),
            "Dialog response exceeds 64 KiB"
        );
        drop(self.take_stale());
        let mut pending = {
            let mut state = self.0.borrow_mut();
            ensure!(
                state.pending.as_ref().is_some_and(|p| p.snapshot.id == id),
                "Page dialog changed or closed"
            );
            state.pending.take().expect("checked dialog")
        };
        let kind = pending.snapshot.kind;
        let text = if kind == Kind::Prompt && accept {
            Some(
                text.or(pending.snapshot.default_text.take())
                    .unwrap_or_default(),
            )
        } else {
            None
        };
        let result = pending.respond.take().expect("owned responder")(accept, text);
        let changed = self.0.borrow().changed.clone();
        changed();
        result?;
        Ok(kind)
    }
    fn close(&self) {
        let pending = {
            let mut state = self.0.borrow_mut();
            state.closed = true;
            state.pending.take()
        };
        drop(pending);
    }
}

pub struct Dialogs {
    sink: Sink,
    // Retains native handlers. Drop cancels the responder before disconnecting
    // or restoring the existing delegate; it never replaces popup/permission policy.
    adapter: Option<platform::Adapter>,
}
impl Dialogs {
    pub fn install(
        view: &wry::WebView,
        navigation: Arc<AtomicU64>,
        owner_closed: Arc<AtomicBool>,
        changed: impl Fn() + 'static,
    ) -> Self {
        let sink = Sink::new(navigation, owner_closed, changed);
        let adapter = platform::Adapter::install(view, sink.clone()).ok();
        Self { sink, adapter }
    }
    pub fn supported(&self) -> bool {
        self.adapter.is_some()
    }
    pub fn snapshot(&self) -> Option<Snapshot> {
        self.sink.snapshot()
    }
    pub fn answer(&self, id: &str, accept: bool, text: Option<String>) -> Result<Kind> {
        ensure!(self.supported(), "Native page dialogs unavailable");
        self.sink.answer(id, accept, text)
    }
    pub fn cancel(&self) {
        let pending = self.sink.0.borrow_mut().pending.take();
        drop(pending);
    }
}
impl Drop for Dialogs {
    fn drop(&mut self) {
        self.sink.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn native_completion_is_exactly_once_across_duplicate_stale_and_owner_close() {
        let epoch = Arc::new(AtomicU64::new(4));
        let closed = Arc::new(AtomicBool::new(false));
        let calls = Rc::new(RefCell::new(Vec::new()));
        let sink = Sink::new(epoch.clone(), closed.clone(), || {});
        let completed = calls.clone();
        sink.open(
            Kind::Prompt,
            "Synthetic prompt".into(),
            Some("initial".into()),
            move |accept, text| {
                completed.borrow_mut().push((accept, text));
                Ok(())
            },
        );
        let first = sink.snapshot().unwrap();
        assert!(sink.answer("stale-id", true, Some("wrong".into())).is_err());
        assert!(calls.borrow().is_empty());
        sink.answer(&first.id, true, None).unwrap();
        assert!(sink.answer(&first.id, true, None).is_err());
        assert_eq!(*calls.borrow(), vec![(true, Some("initial".into()))]);
        let completed = calls.clone();
        sink.open(Kind::Confirm, "Next".into(), None, move |accept, text| {
            completed.borrow_mut().push((accept, text));
            Ok(())
        });
        epoch.fetch_add(1, Ordering::AcqRel);
        assert!(sink.snapshot().is_none());
        let completed = calls.clone();
        sink.open(Kind::Alert, "Last".into(), None, move |accept, text| {
            completed.borrow_mut().push((accept, text));
            Ok(())
        });
        closed.store(true, Ordering::Release);
        assert!(sink.snapshot().is_none());
        sink.close();
        assert_eq!(calls.borrow().len(), 3);
        assert_eq!(calls.borrow()[1], (false, None));
        assert_eq!(calls.borrow()[2], (false, None));
    }
    #[::core::prelude::v1::test]
    fn reentrant_completion_releases_borrow_and_duplicate_dialog_is_cancelled() {
        let sink = Sink::new(
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicBool::new(false)),
            || {},
        );
        let again = sink.clone();
        sink.open(Kind::Confirm, "First".into(), None, move |_, _| {
            assert!(again.snapshot().is_none());
            Ok(())
        });
        let cancelled = Rc::new(RefCell::new(0));
        let count = cancelled.clone();
        sink.open(Kind::Confirm, "Duplicate".into(), None, move |accept, _| {
            assert!(!accept);
            *count.borrow_mut() += 1;
            Ok(())
        });
        assert_eq!(*cancelled.borrow(), 1);
        let id = sink.snapshot().unwrap().id;
        sink.answer(&id, true, None).unwrap();
    }
    #[::core::prelude::v1::test]
    fn cross_tab_ids_oversize_and_native_failure_never_replay_or_release_another_dialog() {
        let sink = || {
            Sink::new(
                Arc::new(AtomicU64::new(0)),
                Arc::new(AtomicBool::new(false)),
                || {},
            )
        };
        let a = sink();
        let b = sink();
        let calls = Rc::new(RefCell::new(0));
        let count = calls.clone();
        a.open(Kind::Prompt, "A".into(), None, move |_, _| {
            *count.borrow_mut() += 1;
            anyhow::bail!("synthetic native failure")
        });
        b.open(Kind::Confirm, "B".into(), None, |_, _| Ok(()));
        let id = a.snapshot().unwrap().id;
        assert!(b.answer(&id, true, None).is_err());
        assert!(b.snapshot().is_some());
        assert!(a.answer(&id, true, Some("x".repeat(65537))).is_err());
        assert_eq!(*calls.borrow(), 0);
        assert!(a.answer(&id, true, None).is_err());
        assert_eq!(*calls.borrow(), 1);
        assert!(a.answer(&id, true, None).is_err());
        assert_eq!(*calls.borrow(), 1);
    }
    #[::core::prelude::v1::test]
    fn oversized_incoming_dialog_and_closed_sink_complete_cancelled_without_public_snapshot() {
        let sink = Sink::new(
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicBool::new(false)),
            || {},
        );
        let calls = Rc::new(RefCell::new(0));
        let count = calls.clone();
        sink.open(Kind::Alert, "x".repeat(16385), None, move |accept, text| {
            assert!(!accept && text.is_none());
            *count.borrow_mut() += 1;
            Ok(())
        });
        assert!(sink.snapshot().is_none());
        sink.close();
        let count = calls.clone();
        sink.open(Kind::Confirm, "closed".into(), None, move |accept, text| {
            assert!(!accept && text.is_none());
            *count.borrow_mut() += 1;
            Ok(())
        });
        assert!(sink.snapshot().is_none());
        assert_eq!(*calls.borrow(), 2);
    }
}
