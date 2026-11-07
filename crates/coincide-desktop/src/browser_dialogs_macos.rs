use super::{Kind, Sink};
use anyhow::{Context, Result};
use block2::Block;
use objc2::{
    DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send,
    rc::Retained,
    runtime::{AnyObject, Bool, NSObject, NSObjectProtocol, ProtocolObject, Sel},
};
use objc2_foundation::NSString;
use objc2_web_kit::{WKFrameInfo, WKUIDelegate, WKWebView};
use wry::WebViewExtMacOS;

pub(super) struct Ivars {
    sink: Sink,
    original: Option<Retained<ProtocolObject<dyn WKUIDelegate>>>,
}
define_class!(
    #[unsafe(super(NSObject))]
    #[name = "CoincideBrowserDialogDelegateV1"]
    #[thread_kind = MainThreadOnly]
    #[ivars = Ivars]
    struct Delegate;
    unsafe impl NSObjectProtocol for Delegate {
        #[unsafe(method(respondsToSelector:))]
        fn responds(&self, selector: Sel) -> Bool {
            unsafe {
                let own: Bool = msg_send![super(self), respondsToSelector: selector];
                if own.as_bool() { return own; }
                self.ivars().original.as_ref().map_or(Bool::NO, |original| msg_send![&**original, respondsToSelector: selector])
            }
        }
    }
    impl Delegate {
        #[unsafe(method(forwardingTargetForSelector:))]
        fn forward(&self, _selector: Sel) -> *mut AnyObject {
            self.ivars().original.as_ref().map_or(std::ptr::null_mut(), |original| Retained::as_ptr(original).cast_mut().cast())
        }
    }
    unsafe impl WKUIDelegate for Delegate {
        #[unsafe(method(webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:))]
        fn alert(&self, _view: &WKWebView, message: &NSString, _frame: &WKFrameInfo, handler: &Block<dyn Fn()>) {
            let handler = handler.copy();
            self.ivars().sink.open(Kind::Alert, message.to_string(), None, move |_, _| { handler.call(()); Ok(()) });
        }
        #[unsafe(method(webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:))]
        fn confirm(&self, _view: &WKWebView, message: &NSString, _frame: &WKFrameInfo, handler: &Block<dyn Fn(Bool)>) {
            let handler = handler.copy();
            self.ivars().sink.open(Kind::Confirm, message.to_string(), None, move |accept, _| { handler.call((Bool::new(accept),)); Ok(()) });
        }
        #[unsafe(method(webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:))]
        fn prompt(&self, _view: &WKWebView, message: &NSString, default: Option<&NSString>, _frame: &WKFrameInfo, handler: &Block<dyn Fn(*mut NSString)>) {
            let handler = handler.copy();
            self.ivars().sink.open(Kind::Prompt, message.to_string(), default.map(ToString::to_string), move |accept, text| {
                let value = accept.then(|| NSString::from_str(text.as_deref().unwrap_or_default()));
                handler.call((value.as_ref().map_or(std::ptr::null_mut(), |value| Retained::as_ptr(value).cast_mut()),));
                Ok(())
            });
        }
    }
);
pub(super) struct Adapter {
    view: Retained<WKWebView>,
    delegate: Retained<Delegate>,
}
impl Adapter {
    pub(super) fn install(view: &wry::WebView, sink: Sink) -> Result<Self> {
        let mtm = MainThreadMarker::new().context("Native dialogs require the UI thread")?;
        let view: Retained<WKWebView> = unsafe { Retained::cast_unchecked(view.webview()) };
        let original = unsafe { view.UIDelegate() };
        let this = Delegate::alloc(mtm).set_ivars(Ivars { sink, original });
        let delegate: Retained<Delegate> = unsafe { msg_send![super(this), init] };
        unsafe {
            view.setUIDelegate(Some(ProtocolObject::from_ref(&*delegate)));
        }
        Ok(Self { view, delegate })
    }
}
impl Drop for Adapter {
    fn drop(&mut self) {
        unsafe {
            // Do not overwrite a delegate another native owner installed later.
            if self.view.UIDelegate().is_some_and(|current| {
                Retained::as_ptr(&current).cast::<AnyObject>()
                    == Retained::as_ptr(&self.delegate).cast::<AnyObject>()
            }) {
                self.view
                    .setUIDelegate(self.delegate.ivars().original.as_deref());
            }
        }
    }
}
