//! Exact-object GTK downloads. Wry's shared-context download callbacks are never
//! installed on Linux. Cancellation requests are not native completion receipts.
use super::shutdown::{CallbackAck, Callbacks, NativeLease};
use anyhow::{Context, Result};
use coincide_core::browser_protocol::{
    DownloadRegistry, NativeDownloadOutcome, NativeDownloadReceipt, allow_native_navigation,
    validate_native_download,
};
use gtk::glib::{
    self, SignalHandlerId,
    prelude::{Cast, ObjectExt},
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
use webkit2gtk::{
    Download, DownloadExt, LoadEvent, NavigationPolicyDecision, NavigationPolicyDecisionExt,
    PolicyDecisionExt, PolicyDecisionType, ResponsePolicyDecision, ResponsePolicyDecisionExt,
    URIRequestExt, URIResponseExt, WebContext, WebContextExt, WebView, WebViewExt,
};
use wry::WebViewExtUnix;

pub(super) struct Owner {
    view: RefCell<Option<WebView>>,
    // Wry destroys its GTK view when the tab drops, which would abort the
    // closed page's blank load and leave that receipt unanswered forever.
    handle: RefCell<Option<gpui_webview::WebViewHandle>>,
    weak_view: glib::WeakRef<WebView>,
    blank_returned: Cell<bool>,
    blank_ack: RefCell<Option<CallbackAck>>,
    context: WebContext,
    thread: String,
    tab: String,
    registry: Rc<RefCell<DownloadRegistry>>,
    callbacks: Callbacks,
    suppressed: Arc<AtomicBool>,
    navigation: Arc<AtomicU64>,
    closed: Cell<bool>,
    poisoned: Cell<bool>,
    signals: RefCell<Option<(SignalHandlerId, SignalHandlerId, SignalHandlerId)>>,
    active: RefCell<Vec<Rc<Transfer>>>,
    changed: Rc<dyn Fn()>,
    _target: NativeLease,
}
struct Transfer {
    download: Download,
    owner: std::rc::Weak<Owner>,
    source: String,
    address: String,
    epoch: u64,
    receipt: RefCell<Option<NativeDownloadReceipt>>,
    signals: RefCell<Vec<SignalHandlerId>>,
    failed: Cell<bool>,
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
        navigation: Arc<AtomicU64>,
        changed: impl Fn() + 'static,
    ) -> Result<Rc<Self>> {
        let handle = view.handle();
        let view = view.raw().webview();
        let context = view
            .context()
            .context("Native download context unavailable")?;
        let owner = Rc::new(Self {
            weak_view: view.downgrade(),
            view: RefCell::new(Some(view.clone())),
            handle: RefCell::new(Some(handle)),
            blank_returned: Cell::new(false),
            blank_ack: RefCell::new(None),
            context,
            thread: thread.into(),
            tab: tab.into(),
            registry,
            _target: callbacks.lifetimes().target(),
            callbacks,
            suppressed,
            navigation,
            closed: Cell::new(false),
            poisoned: Cell::new(false),
            signals: RefCell::new(None),
            active: RefCell::new(Vec::new()),
            changed: Rc::new(changed),
        });
        let weak = Rc::downgrade(&owner);
        let block = owner.callbacks.lifetimes().block();
        let started = owner
            .context
            .connect_download_started(move |context, download| {
                let _held = &block;
                let Some(owner) = weak.upgrade() else {
                    return;
                };
                // Other tabs sharing this context must neither receive nor cancel it.
                if context != &owner.context {
                    return;
                }
                let source = download.web_view();
                if source.is_none() {
                    // No attributable view can ever receive a destination.
                    owner.receive(download);
                } else if source == owner.weak_view.upgrade() {
                    owner.receive(download);
                }
            });
        let weak = Rc::downgrade(&owner);
        let block = owner.callbacks.lifetimes().block();
        let policy = view.connect_decide_policy(move |view, decision, kind| {
            let _held = &block;
            let Some(owner) = weak.upgrade() else {
                decision.ignore();
                return true;
            };
            if Some(view) != owner.weak_view.upgrade().as_ref() {
                decision.ignore();
                return true;
            }
            if kind == PolicyDecisionType::NavigationAction {
                let address = decision
                    .downcast_ref::<NavigationPolicyDecision>()
                    .and_then(|policy| policy.navigation_action())
                    .and_then(|action| action.request())
                    .and_then(|request| request.uri());
                if let Some(address) = address {
                    if address.starts_with("blob:") {
                        // Blob is a download decision, never general navigation.
                        if owner.admitting()
                            && view.uri().is_some_and(|source| {
                                validate_native_download(&address, &source).is_ok()
                            })
                        {
                            decision.download();
                        } else {
                            decision.ignore();
                        }
                    } else if owner.closed.get() && address == "about:blank" {
                        decision.use_();
                    } else if !owner.closed.get()
                        && !owner.callbacks.closed()
                        && allow_native_navigation(&address)
                    {
                        owner.navigation.fetch_add(1, Ordering::AcqRel);
                        decision.use_();
                    } else {
                        decision.ignore();
                    }
                } else {
                    decision.ignore();
                }
                return true;
            }
            if kind == PolicyDecisionType::Response {
                let response = decision.downcast_ref::<ResponsePolicyDecision>();
                if let Some(response) = response {
                    if response.is_mime_type_supported() {
                        return false;
                    }
                    let address = response.response().and_then(|response| response.uri());
                    if owner.admitting()
                        && address.is_some_and(|address| {
                            view.uri().is_some_and(|source| {
                                validate_native_download(&address, &source).is_ok()
                            })
                        })
                    {
                        decision.download();
                    } else {
                        decision.ignore();
                    }
                    return true;
                }
            }
            false
        });
        let weak = Rc::downgrade(&owner);
        let block = owner.callbacks.lifetimes().block();
        let blank = view.connect_load_changed(move |view, event| {
            let _held = &block;
            if let Some(owner) = weak.upgrade()
                && owner.closed.get()
                && event == LoadEvent::Finished
                && view.uri().as_deref() == Some("about:blank")
            {
                owner.blank_returned.set(true);
                if let Some(ack) = owner.blank_ack.borrow_mut().take() {
                    ack.ack();
                }
            }
        });
        *owner.signals.borrow_mut() = Some((started, policy, blank));
        Ok(owner)
    }
    fn admitting(&self) -> bool {
        !self.closed.get()
            && !self.callbacks.closed()
            && !self.poisoned.get()
            && !self.suppressed.load(Ordering::Acquire)
    }
    fn receive(self: &Rc<Self>, download: &Download) {
        self.active
            .borrow_mut()
            .retain(|transfer| !transfer.finished.get());
        if self.active.borrow().len() >= 128 {
            // Bound retained native objects. Overflow remains an explicit unknown
            // callback owner; do not invent an acknowledgement for cancel().
            if !self.poisoned.replace(true) {
                let _unknown = self.callbacks.begin();
            }
            download.cancel();
            return;
        }
        let source = self
            .weak_view
            .upgrade()
            .and_then(|view| view.uri())
            .map(|value| value.to_string())
            .unwrap_or_default();
        let address = download
            .request()
            .and_then(|request| request.uri())
            .map(|value| value.to_string())
            .unwrap_or_default();
        let transfer = Rc::new(Transfer {
            download: download.clone(),
            owner: Rc::downgrade(self),
            source,
            address,
            epoch: self.navigation.load(Ordering::Acquire),
            receipt: RefCell::new(None),
            signals: RefCell::new(Vec::new()),
            failed: Cell::new(false),
            cancelled: Cell::new(false),
            finished: Cell::new(false),
            ack: self.callbacks.begin(),
        });
        let weak = Rc::downgrade(&transfer);
        let block = self.callbacks.lifetimes().block();
        let destination = download.connect_decide_destination(move |_, suggested| {
            let _held = &block;
            if let Some(transfer) = weak.upgrade() {
                transfer.destination(suggested);
            }
            // Always handled; never let WebKit select a default Downloads path.
            true
        });
        let weak = Rc::downgrade(&transfer);
        let block = self.callbacks.lifetimes().block();
        let failed = download.connect_failed(move |_, _| {
            let _held = &block;
            if let Some(transfer) = weak.upgrade() {
                transfer.failed.set(true);
            }
        });
        let weak = Rc::downgrade(&transfer);
        let block = self.callbacks.lifetimes().block();
        let finished = download.connect_finished(move |_| {
            let _held = &block;
            if let Some(transfer) = weak.upgrade() {
                transfer.finish();
            }
        });
        *transfer.signals.borrow_mut() = vec![destination, failed, finished];
        self.active.borrow_mut().push(transfer.clone());
        if !self.admitting()
            || download.web_view().is_none()
            || validate_native_download(&transfer.address, &transfer.source).is_err()
        {
            transfer.cancel();
        }
        (self.changed)();
    }
    pub(super) fn is_tab(&self, thread: &str, tab: &str) -> bool {
        self.thread == thread && self.tab == tab
    }
    pub(super) fn close(&self) {
        if self.closed.replace(true) {
            return;
        }
        // Neutralize the closed page before releasing its native view owner.
        // Only this owned blank document may navigate after the admission fence.
        *self.blank_ack.borrow_mut() = Some(self.callbacks.begin());
        if let Some(view) = self.weak_view.upgrade() {
            view.stop_loading();
            view.load_uri("about:blank");
        }
        let active = self.active.borrow().clone();
        for transfer in active {
            transfer.cancel();
        }
    }
    pub(super) fn drained(&self) -> bool {
        self.active
            .borrow_mut()
            .retain(|transfer| !transfer.finished.get());
        if self.closed.get()
            && self.blank_returned.get()
            && self.active.borrow().is_empty()
            && !self.poisoned.get()
        {
            // A weak native view keeps late starts attributable without retaining
            // the old document or a blank view as a permanent anchor.
            self.view.borrow_mut().take();
            // Release outside the borrow: Wry's drop destroys the view now.
            let handle = self.handle.borrow_mut().take();
            drop(handle);
            if self.weak_view.upgrade().is_none() {
                if let Some((started, _policy, _blank)) = self.signals.borrow_mut().take() {
                    self.context.disconnect(started);
                    // The view's finalization already destroyed its two closures.
                }
                return true;
            }
        }
        false
    }
    pub(super) fn retained_closed_view(&self) -> usize {
        usize::from(self.closed.get() && self.view.borrow().is_some())
    }
    pub(super) fn pending(&self) -> usize {
        self.active
            .borrow()
            .iter()
            .filter(|transfer| !transfer.finished.get())
            .count()
            + usize::from(self.poisoned.get())
    }
}
impl Transfer {
    fn cancel(&self) {
        if !self.finished.get() && !self.cancelled.replace(true) {
            self.download.cancel();
        }
    }
    fn destination(&self, suggested: &str) {
        let Some(owner) = self.owner.upgrade() else {
            self.cancel();
            return;
        };
        // A response download briefly makes its own URL the view's active URI,
        // so the navigation epoch, not the URI, proves the initiating page remains.
        if self.receipt.borrow().is_some()
            || self.cancelled.get()
            || !owner.admitting()
            || owner.navigation.load(Ordering::Acquire) != self.epoch
            || self.download.web_view() != owner.weak_view.upgrade()
        {
            self.cancel();
            return;
        }
        let response = self.download.response().and_then(|response| response.uri());
        if response
            .as_deref()
            .is_some_and(|address| validate_native_download(address, &self.source).is_err())
        {
            self.cancel();
            return;
        }
        let receipt = owner.registry.borrow_mut().start_native(
            &owner.thread,
            &owner.tab,
            &self.address,
            &self.source,
            Path::new(suggested),
        );
        match receipt {
            Ok(receipt) => {
                let destination = glib::filename_to_uri(receipt.destination(), None);
                if let Ok(destination) = destination {
                    *self.receipt.borrow_mut() = Some(receipt);
                    self.download.set_allow_overwrite(false);
                    self.download.set_destination(&destination);
                } else {
                    owner
                        .registry
                        .borrow_mut()
                        .complete_native(&receipt, NativeDownloadOutcome::Failed);
                    self.cancel();
                }
            }
            Err(_) => self.cancel(),
        }
        (owner.changed)();
    }
    fn finish(&self) {
        if self.finished.replace(true) {
            return;
        }
        if let Some(owner) = self.owner.upgrade() {
            if let Some(receipt) = self.receipt.borrow_mut().take() {
                // WebKitGTK emits finished after every outcome; only an accepted
                // transfer is cancelled after its receipt, when its tab closes.
                let outcome = if self.cancelled.get() {
                    NativeDownloadOutcome::Cancelled
                } else if self.failed.get() {
                    NativeDownloadOutcome::Failed
                } else {
                    NativeDownloadOutcome::Finished
                };
                owner
                    .registry
                    .borrow_mut()
                    .complete_native(&receipt, outcome);
            }
            (owner.changed)();
        }
        self.ack.ack();
        let signals = std::mem::take(&mut *self.signals.borrow_mut());
        for signal in signals {
            self.download.disconnect(signal);
        }
    }
}
