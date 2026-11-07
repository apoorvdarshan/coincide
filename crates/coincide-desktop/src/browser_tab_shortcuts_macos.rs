use super::*;
use anyhow::Context as _;
use block2::RcBlock;
use objc2::{
    ClassType, MainThreadMarker,
    rc::{Retained, Weak},
    runtime::{AnyObject, NSObjectProtocol},
};
use objc2_app_kit::{NSEvent, NSEventMask, NSEventModifierFlags, NSView};
use objc2_web_kit::WKWebView;
use std::ptr::NonNull;
use wry::WebViewExtMacOS;
pub(super) struct Adapter {
    monitor: Retained<AnyObject>,
    _main: MainThreadMarker,
}
impl Adapter {
    pub fn focused(&self, view: &wry::WebView) -> bool {
        let native: Retained<WKWebView> = unsafe { Retained::cast_unchecked(view.webview()) };
        let Some(window) = native.window() else {
            return false;
        };
        if !window.isKeyWindow() || native.isHiddenOrHasHiddenAncestor() {
            return false;
        }
        let Some(responder) = window.firstResponder() else {
            return false;
        };
        if !responder.isKindOfClass(NSView::class()) {
            return false;
        }
        let responder: Retained<NSView> = unsafe { Retained::cast_unchecked(responder) };
        responder.isDescendantOf(&native)
    }
    pub fn install(
        view: &wry::WebView,
        callbacks: &Callbacks,
        navigation: Arc<AtomicU64>,
        emit: impl Fn(Command, u64, Option<String>) -> bool + 'static,
    ) -> Result<Self> {
        let main =
            MainThreadMarker::new().context("Browser shortcuts require the native UI thread")?;
        let native: Retained<WKWebView> = unsafe { Retained::cast_unchecked(view.webview()) };
        let weak = Weak::from_retained(&native);
        let block = callbacks.lifetimes().block();
        let handler = RcBlock::new(move |event: NonNull<NSEvent>| -> *mut NSEvent {
            let _held = &block;
            let epoch = navigation.load(Ordering::Acquire);
            let event_ref = unsafe { event.as_ref() };
            let Some(view) = weak.load() else {
                return event.as_ptr();
            };
            let Some(window) = view.window() else {
                return event.as_ptr();
            };
            if !window.isKeyWindow()
                || event_ref.windowNumber() != window.windowNumber()
                || view.isHiddenOrHasHiddenAncestor()
            {
                return event.as_ptr();
            }
            let Some(responder) = window.firstResponder() else {
                return event.as_ptr();
            };
            if !responder.isKindOfClass(NSView::class()) {
                return event.as_ptr();
            }
            let responder: Retained<NSView> = unsafe { Retained::cast_unchecked(responder) };
            if !responder.isDescendantOf(&view) {
                return event.as_ptr();
            }
            let flags = event_ref.modifierFlags();
            let Some(key) = event_ref.charactersIgnoringModifiers() else {
                return event.as_ptr();
            };
            let Some(command) = shortcuts::recognize(
                &key.to_string(),
                flags.contains(NSEventModifierFlags::Command),
                flags.contains(NSEventModifierFlags::Control),
                flags.contains(NSEventModifierFlags::Option),
                flags.contains(NSEventModifierFlags::Shift),
            ) else {
                return event.as_ptr();
            };
            let url = unsafe { view.URL() }
                .and_then(|url| url.absoluteString())
                .filter(|url| url.length() <= 16384)
                .map(|url| url.to_string());
            if emit(command, epoch, url) {
                std::ptr::null_mut()
            } else {
                event.as_ptr()
            }
        });
        let monitor = unsafe {
            NSEvent::addLocalMonitorForEventsMatchingMask_handler(NSEventMask::KeyDown, &handler)
        }
        .context("Native browser shortcut monitor unavailable")?;
        Ok(Self {
            monitor,
            _main: main,
        })
    }
}
impl Drop for Adapter {
    fn drop(&mut self) {
        unsafe { NSEvent::removeMonitor(&self.monitor) }
    }
}
