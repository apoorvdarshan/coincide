//! Exact-object WebView2 downloads. Wry's URL-keyed download callbacks are never
//! installed on Windows: each DownloadStarting operation gets its own receipt and
//! StateChanged registration. Cancel() is a request; only the operation's actual
//! completed or interrupted state completes it.
use super::shutdown::{CallbackAck, Callbacks, NativeLease};
use anyhow::{Context, Result};
use coincide_core::browser_protocol::{
    DownloadRegistry, NativeDownloadOutcome, NativeDownloadReceipt, validate_native_download,
};
use std::{
    cell::{Cell, RefCell},
    path::Path,
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};
use webview2_com::{
    DownloadStartingEventHandler, Microsoft::Web::WebView2::Win32::*,
    PermissionRequestedEventHandler, StateChangedEventHandler, take_pwstr,
};
use windows::core::{HSTRING, Interface, PWSTR};
use wry::WebViewExtWindows;

pub(super) struct Owner {
    shared: Rc<Shared>,
}
struct Shared {
    // A closed tab keeps its native view until every transfer reports an
    // outcome; closing WebView2 first could leave a cancellation unanswered.
    view: RefCell<Option<gpui_webview::WebViewHandle>>,
    thread: String,
    tab: String,
    registry: Rc<RefCell<DownloadRegistry>>,
    callbacks: Callbacks,
    suppressed: Arc<AtomicBool>,
    closed: Cell<bool>,
    active: RefCell<Vec<Rc<Transfer>>>,
    changed: Rc<dyn Fn()>,
    _target: NativeLease,
}
struct Transfer {
    operation: ICoreWebView2DownloadOperation,
    owner: std::rc::Weak<Shared>,
    receipt: RefCell<Option<NativeDownloadReceipt>>,
    token: Cell<Option<i64>>,
    cancelled: Cell<bool>,
    finished: Cell<bool>,
    ack: CallbackAck,
}
impl Owner {
    pub(super) fn install(
        view: &gpui_webview::WebView,
        thread: &str,
        tab: &str,
        registry: Rc<RefCell<DownloadRegistry>>,
        callbacks: Callbacks,
        suppressed: Arc<AtomicBool>,
        _navigation: Arc<AtomicU64>,
        changed: impl Fn() + 'static,
    ) -> Result<Rc<Self>> {
        let native = view.raw().webview();
        let events: ICoreWebView2_4 = native
            .cast()
            .context("Native download events require WebView2 1.0.902 or later")?;
        let shared = Rc::new(Shared {
            view: RefCell::new(Some(view.handle())),
            thread: thread.into(),
            tab: tab.into(),
            registry,
            _target: callbacks.lifetimes().target(),
            callbacks,
            suppressed,
            closed: Cell::new(false),
            active: RefCell::new(Vec::new()),
            changed: Rc::new(changed),
        });
        let weak = Rc::downgrade(&shared);
        let block = shared.callbacks.lifetimes().block();
        let handler = DownloadStartingEventHandler::create(Box::new(move |_, args| {
            let _held = &block;
            let Some(args) = args else { return Ok(()) };
            match weak.upgrade() {
                Some(shared) => shared.receive(&args),
                None => unsafe { args.SetCancel(true) },
            }
        }));
        let mut token = 0;
        // Deliberately never removed: after this owner drains, a late start on
        // a still-live view is cancelled instead of reaching WebView2's own UI.
        unsafe { events.add_DownloadStarting(&handler, &mut token)? };
        // Agent clicks are script clicks, not user gestures. Chromium would ask
        // before every later download from one page, and nobody can answer that
        // prompt here; Swift's WebKit has no such limit. Every start is still
        // admitted individually above, within the registry's bounds.
        let weak = Rc::downgrade(&shared);
        let block = shared.callbacks.lifetimes().block();
        let permission = PermissionRequestedEventHandler::create(Box::new(move |_, args| {
            let _held = &block;
            let Some(args) = args else { return Ok(()) };
            let mut kind = COREWEBVIEW2_PERMISSION_KIND::default();
            unsafe { args.PermissionKind(&mut kind)? };
            if kind != COREWEBVIEW2_PERMISSION_KIND_MULTIPLE_AUTOMATIC_DOWNLOADS {
                return Ok(());
            }
            let allowed = weak.upgrade().is_some_and(|shared| shared.admitting());
            unsafe {
                args.SetState(if allowed {
                    COREWEBVIEW2_PERMISSION_STATE_ALLOW
                } else {
                    COREWEBVIEW2_PERMISSION_STATE_DENY
                })
            }
        }));
        let mut token = 0;
        unsafe { native.add_PermissionRequested(&permission, &mut token)? };
        Ok(Rc::new(Self { shared }))
    }
    pub(super) fn is_tab(&self, thread: &str, tab: &str) -> bool {
        self.shared.thread == thread && self.shared.tab == tab
    }
    pub(super) fn close(&self) {
        if self.shared.closed.replace(true) {
            return;
        }
        let active = self.shared.active.borrow().clone();
        for transfer in active {
            transfer.cancel();
        }
    }
    pub(super) fn drained(&self) -> bool {
        self.shared
            .active
            .borrow_mut()
            .retain(|transfer| !transfer.finished.get());
        if !self.shared.closed.get() || !self.shared.active.borrow().is_empty() {
            return false;
        }
        // Every outcome returned; now the closed view may actually close.
        self.shared.view.borrow_mut().take();
        true
    }
    pub(super) fn retained_closed_view(&self) -> usize {
        usize::from(self.shared.closed.get() && self.shared.view.borrow().is_some())
    }
    pub(super) fn pending(&self) -> usize {
        self.shared
            .active
            .borrow()
            .iter()
            .filter(|transfer| !transfer.finished.get())
            .count()
    }
}
impl Shared {
    fn admitting(&self) -> bool {
        !self.closed.get() && !self.callbacks.closed() && !self.suppressed.load(Ordering::Acquire)
    }
    fn source(&self) -> Option<String> {
        if self.closed.get() {
            return None;
        }
        let view = self.view.borrow().as_ref()?.raw().webview();
        let mut raw = PWSTR::null();
        unsafe { view.Source(&mut raw) }.ok()?;
        Some(take_pwstr(raw))
    }
    /// Every refusal here is synchronous: a cancelled start never begins a
    /// transfer and never raises StateChanged, so nothing is left pending.
    fn receive(
        self: &Rc<Self>,
        args: &ICoreWebView2DownloadStartingEventArgs,
    ) -> windows::core::Result<()> {
        let result = match self.admit(args) {
            Ok(Some(transfer)) => {
                self.active.borrow_mut().push(transfer);
                Ok(())
            }
            // An SDK error is a refusal too; the cancellation must still apply.
            Ok(None) | Err(_) => unsafe { args.SetCancel(true) },
        };
        (self.changed)();
        result
    }
    fn admit(
        self: &Rc<Self>,
        args: &ICoreWebView2DownloadStartingEventArgs,
    ) -> windows::core::Result<Option<Rc<Transfer>>> {
        self.active
            .borrow_mut()
            .retain(|transfer| !transfer.finished.get());
        let operation = unsafe { args.DownloadOperation()? };
        let mut raw = PWSTR::null();
        unsafe { operation.Uri(&mut raw)? };
        let address = take_pwstr(raw);
        let mut raw = PWSTR::null();
        unsafe { args.ResultFilePath(&mut raw)? };
        let suggested = take_pwstr(raw);
        let Some(source) = self.source() else {
            return Ok(None);
        };
        if !self.admitting() {
            return Ok(None);
        }
        if self.active.borrow().len() >= 128 {
            self.registry
                .borrow_mut()
                .refuse(&self.thread, "Too many native downloads are still running");
            return Ok(None);
        }
        if validate_native_download(&address, &source).is_err() {
            self.registry.borrow_mut().refuse(
                &self.thread,
                "Download refused: only HTTP(S) addresses or blobs from this page can be saved",
            );
            return Ok(None);
        }
        let Ok(receipt) = self.registry.borrow_mut().start_native(
            &self.thread,
            &self.tab,
            &address,
            &source,
            Path::new(&suggested),
        ) else {
            return Ok(None);
        };
        let destination = HSTRING::from(receipt.native_destination().as_path());
        let transfer = Rc::new(Transfer {
            operation: operation.clone(),
            owner: Rc::downgrade(self),
            receipt: RefCell::new(Some(receipt)),
            token: Cell::new(None),
            cancelled: Cell::new(false),
            finished: Cell::new(false),
            ack: self.callbacks.begin(),
        });
        let accepted = (|| -> windows::core::Result<()> {
            let weak = Rc::downgrade(&transfer);
            let block = self.callbacks.lifetimes().block();
            let handler = StateChangedEventHandler::create(Box::new(move |operation, _| {
                let _held = &block;
                if let (Some(transfer), Some(operation)) = (weak.upgrade(), operation) {
                    transfer.state_changed(&operation);
                }
                Ok(())
            }));
            let mut token = 0;
            unsafe { operation.add_StateChanged(&handler, &mut token)? };
            transfer.token.set(Some(token));
            unsafe {
                args.SetResultFilePath(&destination)?;
                // Handled hides WebView2's own download UI; files are never opened.
                args.SetHandled(true)?;
            }
            Ok(())
        })();
        if let Err(error) = accepted {
            // The start is cancelled below, so no StateChanged can complete it.
            transfer.release(NativeDownloadOutcome::Failed);
            return Err(error);
        }
        Ok(Some(transfer))
    }
}
impl Transfer {
    fn cancel(&self) {
        if !self.finished.get() && !self.cancelled.replace(true) {
            // Interrupted StateChanged is the receipt; the request itself is not.
            let _ = unsafe { self.operation.Cancel() };
        }
    }
    fn state_changed(&self, operation: &ICoreWebView2DownloadOperation) {
        let mut state = COREWEBVIEW2_DOWNLOAD_STATE::default();
        if unsafe { operation.State(&mut state) }.is_err()
            || state == COREWEBVIEW2_DOWNLOAD_STATE_IN_PROGRESS
        {
            return;
        }
        // Nothing here resumes an interrupted operation, so it is terminal.
        let outcome = if state == COREWEBVIEW2_DOWNLOAD_STATE_COMPLETED {
            NativeDownloadOutcome::Finished
        } else if self.cancelled.get() {
            NativeDownloadOutcome::Cancelled
        } else {
            NativeDownloadOutcome::Failed
        };
        self.release(outcome);
    }
    fn release(&self, outcome: NativeDownloadOutcome) {
        if self.finished.replace(true) {
            return;
        }
        if let Some(token) = self.token.take() {
            let _ = unsafe { self.operation.remove_StateChanged(token) };
        }
        if let Some(owner) = self.owner.upgrade() {
            if let Some(receipt) = self.receipt.borrow_mut().take() {
                owner
                    .registry
                    .borrow_mut()
                    .complete_native(&receipt, outcome);
            }
            (owner.changed)();
        }
        self.ack.ack();
    }
}
