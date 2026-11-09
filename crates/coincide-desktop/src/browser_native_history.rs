//! Closed native history dispatch. A synchronous SDK return acknowledges only
//! dispatch, never a loaded document. History does not enter script callbacks:
//! its own navigation must invalidate old-document grants without invalidating
//! a JavaScript completion receipt for the same history action.
use super::shutdown::Callbacks;
use anyhow::{Context, Result, ensure};
use coincide_core::browser_protocol::BrowserAction;
use serde_json::{Value, json};

#[derive(Clone, Copy)]
pub(super) enum Action {
    Back,
    Forward,
    Reload,
}
impl Action {
    pub(super) fn from_request(action: &BrowserAction) -> Option<Self> {
        match action {
            BrowserAction::Back => Some(Self::Back),
            BrowserAction::Forward => Some(Self::Forward),
            BrowserAction::Reload => Some(Self::Reload),
            _ => None,
        }
    }
    fn name(self) -> &'static str {
        match self {
            Self::Back => "back",
            Self::Forward => "forward",
            Self::Reload => "reload",
        }
    }
}
fn dispatch_once(
    action: Action,
    available: bool,
    admit: impl FnOnce() -> Result<()>,
    submit: impl FnOnce() -> Result<()>,
) -> Result<Value> {
    if available {
        admit()?;
        submit()?;
    }
    Ok(json!({"action":action.name(),"dispatched":available,"completion":"dispatch-only"}))
}
pub(super) fn dispatch(
    view: &wry::WebView,
    action: Action,
    callbacks: &Callbacks,
    admit: impl FnOnce() -> Result<()>,
) -> Result<Value> {
    ensure!(!callbacks.closed(), "Browser is shutting down");
    // Retain actual Rust owner custody through the synchronous native call.
    // No asynchronous evaluation callback is created or acknowledged here;
    // existing native navigation listeners retain the continuing load.
    let _target = callbacks.lifetimes().target();
    let _call = callbacks.lifetimes().block();
    platform(view, action, admit)
}
#[cfg(target_os = "macos")]
fn platform(
    view: &wry::WebView,
    action: Action,
    admit: impl FnOnce() -> Result<()>,
) -> Result<Value> {
    use objc2::rc::Retained;
    use objc2_web_kit::WKWebView;
    use wry::WebViewExtMacOS;
    let native: Retained<WKWebView> = view.webview().into_super();
    let available = unsafe {
        match action {
            Action::Back => native.canGoBack(),
            Action::Forward => native.canGoForward(),
            Action::Reload => true,
        }
    };
    dispatch_once(action, available, admit, || {
        unsafe {
            match action {
                Action::Back => native.goBack(),
                Action::Forward => native.goForward(),
                Action::Reload => native.reload(),
            }
        }
        .context("Native history dispatch was not accepted")?;
        Ok(())
    })
}
#[cfg(target_os = "linux")]
fn platform(
    view: &wry::WebView,
    action: Action,
    admit: impl FnOnce() -> Result<()>,
) -> Result<Value> {
    use webkit2gtk::WebViewExt;
    use wry::WebViewExtUnix;
    let native = view.webview();
    let available = match action {
        Action::Back => native.can_go_back(),
        Action::Forward => native.can_go_forward(),
        Action::Reload => true,
    };
    dispatch_once(action, available, admit, || {
        match action {
            Action::Back => native.go_back(),
            Action::Forward => native.go_forward(),
            Action::Reload => native.reload(),
        }
        Ok(())
    })
}
#[cfg(target_os = "windows")]
fn platform(
    view: &wry::WebView,
    action: Action,
    admit: impl FnOnce() -> Result<()>,
) -> Result<Value> {
    use windows::core::BOOL;
    use wry::WebViewExtWindows;
    let native = view.webview();
    let mut available = BOOL::from(true);
    unsafe {
        match action {
            Action::Back => native.CanGoBack(&mut available),
            Action::Forward => native.CanGoForward(&mut available),
            Action::Reload => Ok(()),
        }
    }
    .map_err(|_| anyhow::anyhow!("Native history availability unavailable"))?;
    dispatch_once(action, available.as_bool(), admit, || {
        unsafe {
            match action {
                Action::Back => native.GoBack(),
                Action::Forward => native.GoForward(),
                Action::Reload => native.Reload(),
            }
        }
        .map_err(|_| anyhow::anyhow!("Native history dispatch was not accepted"))
    })
}
#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn platform(_: &wry::WebView, _: Action, _: impl FnOnce() -> Result<()>) -> Result<Value> {
    anyhow::bail!("Native browser history is unavailable on this platform")
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};
    #[test]
    fn native_history_receipt_is_dispatch_only_and_calls_exactly_once_after_admission() {
        for action in [Action::Back, Action::Forward, Action::Reload] {
            let calls = RefCell::new(vec![]);
            let receipt = dispatch_once(
                action,
                true,
                || {
                    calls.borrow_mut().push("admit");
                    Ok(())
                },
                || {
                    calls.borrow_mut().push("native");
                    Ok(())
                },
            )
            .unwrap();
            assert_eq!(*calls.borrow(), ["admit", "native"]);
            assert_eq!(
                receipt,
                json!({"action":action.name(),"dispatched":true,"completion":"dispatch-only"})
            );
        }
    }
    #[test]
    fn native_history_stale_source_and_unavailable_history_never_dispatch() {
        let calls = Cell::new(0);
        assert!(
            dispatch_once(
                Action::Back,
                true,
                || anyhow::bail!("source changed"),
                || {
                    calls.set(calls.get() + 1);
                    Ok(())
                }
            )
            .is_err()
        );
        assert_eq!(calls.get(), 0);
        let receipt = dispatch_once(
            Action::Forward,
            false,
            || {
                calls.set(1);
                Ok(())
            },
            || {
                calls.set(2);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(calls.get(), 0);
        assert_eq!(receipt["dispatched"], false);
    }
    #[test]
    fn native_history_uncertain_sdk_error_is_not_retried_or_reported_dispatched() {
        let calls = Cell::new(0);
        assert!(
            dispatch_once(
                Action::Reload,
                true,
                || Ok(()),
                || {
                    calls.set(calls.get() + 1);
                    anyhow::bail!("native dispatch failed")
                }
            )
            .is_err()
        );
        assert_eq!(calls.get(), 1);
    }
}

/// Native history state for the visible toolbar; querying it never navigates.
pub(super) fn availability(view: &wry::WebView) -> (bool, bool) {
    #[cfg(target_os = "macos")]
    {
        use objc2::rc::Retained;
        use objc2_web_kit::WKWebView;
        use wry::WebViewExtMacOS;
        let native: Retained<WKWebView> = view.webview().into_super();
        unsafe { (native.canGoBack(), native.canGoForward()) }
    }
    #[cfg(target_os = "linux")]
    {
        use webkit2gtk::WebViewExt;
        use wry::WebViewExtUnix;
        let native = view.webview();
        (native.can_go_back(), native.can_go_forward())
    }
    #[cfg(target_os = "windows")]
    {
        use windows::core::BOOL;
        use wry::WebViewExtWindows;
        let native = view.webview();
        let (mut back, mut forward) = (BOOL::from(false), BOOL::from(false));
        let valid = unsafe {
            native.CanGoBack(&mut back).is_ok() && native.CanGoForward(&mut forward).is_ok()
        };
        (valid && back.as_bool(), valid && forward.as_bool())
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    {
        let _ = view;
        (false, false)
    }
}
