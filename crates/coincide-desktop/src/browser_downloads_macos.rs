//! Exact-object WebKit downloads. Wry's URL-keyed download callbacks are never
//! installed on macOS: this tab's navigation delegate decides download policy and
//! gives each actual WKDownload its own receipt. A requested cancellation is not a
//! completion receipt; only WebKit's finish, failure or cancel reply completes it.
use super::shutdown::{CallbackAck, Callbacks, NativeLease};
use anyhow::{Context, Result};
use block2::{Block, RcBlock};
use coincide_core::browser_protocol::{
    DownloadRegistry, NativeDownloadOutcome, NativeDownloadReceipt, validate_native_download,
    validate_url,
};
use objc2::{
    DefinedClass, MainThreadMarker, MainThreadOnly, Message, define_class, msg_send,
    rc::{Retained, Weak},
    runtime::{AnyObject, Bool, NSObject, NSObjectProtocol, ProtocolObject, Sel},
    sel,
};
use objc2_foundation::{
    NSData, NSError, NSHTTPURLResponse, NSString, NSURL, NSURLRequest, NSURLResponse,
};
use objc2_web_kit::{
    WKDownload, WKDownloadDelegate, WKDownloadRedirectPolicy, WKNavigationAction,
    WKNavigationActionPolicy, WKNavigationDelegate, WKNavigationResponse,
    WKNavigationResponsePolicy, WKWebView,
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
use wry::WebViewExtMacOS;

pub(super) struct Owner {
    shared: Rc<Shared>,
    navigation: Retained<NavigationProxy>,
}
struct Shared {
    view: Weak<WKWebView>,
    thread: String,
    tab: String,
    registry: Rc<RefCell<DownloadRegistry>>,
    callbacks: Callbacks,
    suppressed: Arc<AtomicBool>,
    navigation: Arc<AtomicU64>,
    closed: Cell<bool>,
    poisoned: Cell<bool>,
    active: RefCell<Vec<Rc<Transfer>>>,
    // WKDownload.delegate is weak; this owner retains the one it installs.
    downloads: Retained<DownloadDelegate>,
    changed: Rc<dyn Fn()>,
    _target: NativeLease,
}
struct Transfer {
    download: Retained<WKDownload>,
    owner: std::rc::Weak<Shared>,
    source: String,
    address: String,
    epoch: u64,
    receipt: RefCell<Option<NativeDownloadReceipt>>,
    cancelled: Cell<bool>,
    finished: Cell<bool>,
    ack: CallbackAck,
}
pub(super) struct NavigationIvars {
    shared: std::rc::Weak<Shared>,
    original: Option<Retained<ProtocolObject<dyn WKNavigationDelegate>>>,
}
pub(super) struct DownloadIvars {
    shared: std::rc::Weak<Shared>,
}
fn url_string(url: Option<Retained<NSURL>>) -> Option<String> {
    url.and_then(|url| url.absoluteString())
        .map(|value| value.to_string())
}
fn request_address(request: Option<Retained<NSURLRequest>>) -> Option<String> {
    url_string(request.and_then(|request| request.URL()))
}
define_class!(
    #[unsafe(super(NSObject))]
    #[name = "CoincideBrowserDownloadNavigationV1"]
    #[thread_kind = MainThreadOnly]
    #[ivars = NavigationIvars]
    struct NavigationProxy;
    unsafe impl NSObjectProtocol for NavigationProxy {
        #[unsafe(method(respondsToSelector:))]
        fn responds(&self, selector: Sel) -> Bool {
            unsafe {
                let own: Bool = msg_send![super(self), respondsToSelector: selector];
                if own.as_bool() { return own; }
                self.ivars().original.as_ref().map_or(Bool::NO, |original| msg_send![&**original, respondsToSelector: selector])
            }
        }
    }
    impl NavigationProxy {
        #[unsafe(method(forwardingTargetForSelector:))]
        fn forward(&self, _selector: Sel) -> *mut AnyObject {
            self.ivars().original.as_ref().map_or(std::ptr::null_mut(), |original| Retained::as_ptr(original).cast_mut().cast())
        }
    }
    unsafe impl WKNavigationDelegate for NavigationProxy {
        #[unsafe(method(webView:decidePolicyForNavigationAction:decisionHandler:))]
        fn action(&self, view: &WKWebView, action: &WKNavigationAction, handler: &Block<dyn Fn(WKNavigationActionPolicy)>) {
            unsafe {
                // shouldPerformDownload is macOS 11.3+, like WKDownload itself.
                if action.respondsToSelector(sel!(shouldPerformDownload)) && action.shouldPerformDownload() {
                    let address = request_address(Some(action.request()));
                    let allowed = self.ivars().shared.upgrade().is_some_and(|shared| shared.admits(view, address.as_deref()));
                    handler.call((if allowed { WKNavigationActionPolicy::Download } else { WKNavigationActionPolicy::Cancel },));
                    return;
                }
                match &self.ivars().original {
                    Some(original) if original.respondsToSelector(sel!(webView:decidePolicyForNavigationAction:decisionHandler:)) => {
                        original.webView_decidePolicyForNavigationAction_decisionHandler(view, action, handler)
                    }
                    _ => handler.call((WKNavigationActionPolicy::Cancel,)),
                }
            }
        }
        #[unsafe(method(webView:decidePolicyForNavigationResponse:decisionHandler:))]
        fn response(&self, view: &WKWebView, response: &WKNavigationResponse, handler: &Block<dyn Fn(WKNavigationResponsePolicy)>) {
            unsafe {
                if !response.canShowMIMEType() {
                    // Swift parity: a response the page cannot show becomes a download.
                    let address = url_string(response.response().URL());
                    let allowed = self.ivars().shared.upgrade().is_some_and(|shared| shared.admits(view, address.as_deref()));
                    handler.call((if allowed { WKNavigationResponsePolicy::Download } else { WKNavigationResponsePolicy::Cancel },));
                    return;
                }
                match &self.ivars().original {
                    Some(original) if original.respondsToSelector(sel!(webView:decidePolicyForNavigationResponse:decisionHandler:)) => {
                        original.webView_decidePolicyForNavigationResponse_decisionHandler(view, response, handler)
                    }
                    _ => handler.call((WKNavigationResponsePolicy::Allow,)),
                }
            }
        }
        #[unsafe(method(webView:navigationAction:didBecomeDownload:))]
        fn action_download(&self, view: &WKWebView, _action: &WKNavigationAction, download: &WKDownload) {
            self.receive(view, download);
        }
        #[unsafe(method(webView:navigationResponse:didBecomeDownload:))]
        fn response_download(&self, view: &WKWebView, _response: &WKNavigationResponse, download: &WKDownload) {
            self.receive(view, download);
        }
    }
);
impl NavigationProxy {
    fn receive(&self, view: &WKWebView, download: &WKDownload) {
        match self.ivars().shared.upgrade() {
            Some(shared) => shared.receive(view, download),
            // Without an owner no destination can ever be decided.
            None => unsafe { download.cancel(None) },
        }
    }
}
define_class!(
    #[unsafe(super(NSObject))]
    #[name = "CoincideBrowserDownloadDelegateV1"]
    #[thread_kind = MainThreadOnly]
    #[ivars = DownloadIvars]
    struct DownloadDelegate;
    unsafe impl NSObjectProtocol for DownloadDelegate {}
    unsafe impl WKDownloadDelegate for DownloadDelegate {
        #[unsafe(method(download:decideDestinationUsingResponse:suggestedFilename:completionHandler:))]
        fn destination(
            &self,
            download: &WKDownload,
            response: &NSURLResponse,
            suggested: &NSString,
            handler: &Block<dyn Fn(*mut NSURL)>,
        ) {
            let destination = self
                .transfer(download)
                .and_then(|transfer| transfer.destination(response, &suggested.to_string()));
            match destination {
                Some(path) => {
                    let url = NSURL::fileURLWithPath_isDirectory(
                        &NSString::from_str(&path.to_string_lossy()),
                        false,
                    );
                    handler.call((Retained::as_ptr(&url).cast_mut(),));
                }
                // Nil is WebKit's refusal; the transfer above already requested cancellation.
                None => handler.call((std::ptr::null_mut(),)),
            }
        }
        #[unsafe(method(download:willPerformHTTPRedirection:newRequest:decisionHandler:))]
        fn redirect(
            &self,
            download: &WKDownload,
            _response: &NSHTTPURLResponse,
            request: &NSURLRequest,
            handler: &Block<dyn Fn(WKDownloadRedirectPolicy)>,
        ) {
            let allowed = self.transfer(download).is_some_and(|transfer| {
                let admitted = transfer
                    .owner
                    .upgrade()
                    .is_some_and(|owner| owner.admitting())
                    && !transfer.cancelled.get()
                    && url_string(request.URL())
                        .is_some_and(|address| validate_url(&address).is_ok());
                if !admitted {
                    transfer.cancel();
                }
                admitted
            });
            handler.call((if allowed {
                WKDownloadRedirectPolicy::Allow
            } else {
                WKDownloadRedirectPolicy::Cancel
            },));
        }
        #[unsafe(method(downloadDidFinish:))]
        fn finished(&self, download: &WKDownload) {
            if let Some(transfer) = self.transfer(download) {
                transfer.finish(NativeDownloadOutcome::Finished);
            }
        }
        #[unsafe(method(download:didFailWithError:resumeData:))]
        fn failed(&self, download: &WKDownload, _error: &NSError, _resume: Option<&NSData>) {
            if let Some(transfer) = self.transfer(download) {
                transfer.finish(if transfer.cancelled.get() {
                    NativeDownloadOutcome::Cancelled
                } else {
                    NativeDownloadOutcome::Failed
                });
            }
        }
    }
);
impl DownloadDelegate {
    /// Identity is the retained native object, never its URL or a page value.
    fn transfer(&self, download: &WKDownload) -> Option<Rc<Transfer>> {
        let shared = self.ivars().shared.upgrade()?;
        let active = shared.active.borrow();
        active
            .iter()
            .find(|transfer| std::ptr::eq(&*transfer.download, download))
            .cloned()
    }
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
        let mtm = MainThreadMarker::new().context("Native downloads require the UI thread")?;
        let native: Retained<WKWebView> = view.raw().webview().into_super();
        let shared = Rc::new_cyclic(|weak| {
            let downloads = DownloadDelegate::alloc(mtm).set_ivars(DownloadIvars {
                shared: weak.clone(),
            });
            Shared {
                view: Weak::from_retained(&native),
                thread: thread.into(),
                tab: tab.into(),
                registry,
                _target: callbacks.lifetimes().target(),
                callbacks,
                suppressed,
                navigation,
                closed: Cell::new(false),
                poisoned: Cell::new(false),
                active: RefCell::new(Vec::new()),
                downloads: unsafe { msg_send![super(downloads), init] },
                changed: Rc::new(changed),
            }
        });
        let original = unsafe { native.navigationDelegate() };
        let proxy = NavigationProxy::alloc(mtm).set_ivars(NavigationIvars {
            shared: Rc::downgrade(&shared),
            original,
        });
        let proxy: Retained<NavigationProxy> = unsafe { msg_send![super(proxy), init] };
        unsafe {
            native.setNavigationDelegate(Some(ProtocolObject::from_ref(&*proxy)));
        }
        Ok(Rc::new(Self {
            shared,
            navigation: proxy,
        }))
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
        self.shared.closed.get()
            && self.shared.active.borrow().is_empty()
            && !self.shared.poisoned.get()
    }
    /// Views are weak here; closed tabs never retain a WKWebView for downloads.
    pub(super) fn retained_closed_view(&self) -> usize {
        0
    }
    pub(super) fn pending(&self) -> usize {
        self.shared
            .active
            .borrow()
            .iter()
            .filter(|transfer| !transfer.finished.get())
            .count()
            + usize::from(self.shared.poisoned.get())
    }
}
impl Drop for Owner {
    fn drop(&mut self) {
        // Restore Wry's delegate, which refuses downloads without its handler,
        // unless another native owner installed a later delegate.
        let Some(view) = self.shared.view.load() else {
            return;
        };
        unsafe {
            if view.navigationDelegate().is_some_and(|current| {
                Retained::as_ptr(&current).cast::<AnyObject>()
                    == Retained::as_ptr(&self.navigation).cast::<AnyObject>()
            }) {
                view.setNavigationDelegate(self.navigation.ivars().original.as_deref());
            }
        }
    }
}
impl Shared {
    fn admitting(&self) -> bool {
        !self.closed.get()
            && !self.callbacks.closed()
            && !self.poisoned.get()
            && !self.suppressed.load(Ordering::Acquire)
    }
    fn is_view(&self, view: &WKWebView) -> bool {
        self.view
            .load()
            .is_some_and(|owned| std::ptr::eq(&*owned, view))
    }
    fn source(&self) -> Option<String> {
        url_string(unsafe { self.view.load()?.URL() })
    }
    /// Blob downloads stay document-scoped; HTTP(S) never broadens navigation.
    fn admits(&self, view: &WKWebView, address: Option<&str>) -> bool {
        self.admitting()
            && self.is_view(view)
            && address.is_some_and(|address| {
                self.source()
                    .is_some_and(|source| validate_native_download(address, &source).is_ok())
            })
    }
    fn receive(self: &Rc<Self>, view: &WKWebView, download: &WKDownload) {
        self.active
            .borrow_mut()
            .retain(|transfer| !transfer.finished.get());
        if self.active.borrow().len() >= 128 {
            // Bound retained native objects. Overflow remains an explicit unknown
            // callback owner; do not invent an acknowledgement for cancel:.
            if !self.poisoned.replace(true) {
                let _unknown = self.callbacks.begin();
            }
            unsafe { download.cancel(None) };
            return;
        }
        let transfer = Rc::new(Transfer {
            download: download.retain(),
            owner: Rc::downgrade(self),
            source: self.source().unwrap_or_default(),
            address: request_address(unsafe { download.originalRequest() }).unwrap_or_default(),
            epoch: self.navigation.load(Ordering::Acquire),
            receipt: RefCell::new(None),
            cancelled: Cell::new(false),
            finished: Cell::new(false),
            ack: self.callbacks.begin(),
        });
        unsafe { download.setDelegate(Some(ProtocolObject::from_ref(&*self.downloads))) };
        self.active.borrow_mut().push(transfer.clone());
        if !self.admitting()
            || !self.is_view(view)
            || validate_native_download(&transfer.address, &transfer.source).is_err()
        {
            transfer.cancel();
        }
        (self.changed)();
    }
}
impl Transfer {
    fn cancel(self: &Rc<Self>) {
        if self.finished.get() || self.cancelled.replace(true) {
            return;
        }
        let Some(owner) = self.owner.upgrade() else {
            return;
        };
        let weak = Rc::downgrade(self);
        let lease = owner.callbacks.lifetimes().block();
        // WebKit always answers cancel:, including for a transfer that already
        // stopped; this reply is the receipt, the request itself is not.
        let reply = RcBlock::new(move |_resume: *mut NSData| {
            let _held = &lease;
            if let Some(transfer) = weak.upgrade() {
                transfer.finish(NativeDownloadOutcome::Cancelled);
            }
        });
        unsafe { self.download.cancel(Some(&reply)) };
    }
    fn destination(
        self: &Rc<Self>,
        response: &NSURLResponse,
        suggested: &str,
    ) -> Option<std::path::PathBuf> {
        let owner = self.owner.upgrade()?;
        let current = unsafe { self.download.webView() };
        // A provisional response download can briefly change WKWebView.URL, so
        // the navigation epoch, not the URL, proves the initiating page remains.
        if self.receipt.borrow().is_some()
            || self.cancelled.get()
            || !owner.admitting()
            || owner.navigation.load(Ordering::Acquire) != self.epoch
            || !current.is_some_and(|view| owner.is_view(&view))
            || url_string(response.URL())
                .is_some_and(|address| validate_native_download(&address, &self.source).is_err())
        {
            self.cancel();
            return None;
        }
        let receipt = owner.registry.borrow_mut().start_native(
            &owner.thread,
            &owner.tab,
            &self.address,
            &self.source,
            Path::new(suggested),
        );
        (owner.changed)();
        match receipt {
            Ok(receipt) => {
                let destination = receipt.native_destination();
                *self.receipt.borrow_mut() = Some(receipt);
                Some(destination)
            }
            Err(_) => {
                self.cancel();
                None
            }
        }
    }
    fn finish(&self, outcome: NativeDownloadOutcome) {
        if self.finished.replace(true) {
            return;
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
