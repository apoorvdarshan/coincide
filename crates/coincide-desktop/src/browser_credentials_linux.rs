//! GTK2.40 named-world, argument-only native credential delivery. No page-world
//! evaluation, secret source interpolation, browser IPC, raw errors or submission.
use super::super::shutdown::{NativeLease, NativeLifetimes};
use super::scripts::{Attempt, Completion, FILL, FillSlot, PROBE, Secrets, string_argument};
use crate::credentials::FillPermit;
use coincide_core::credentials::{Failure, PageBinding};
use java_script_core::ValueExt;
use std::{
    cell::RefCell,
    rc::{Rc, Weak},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};
use webkit2gtk::{
    UserContentInjectedFrames, UserScript, UserScriptInjectionTime, WebView, WebViewExt,
};
use wry::WebViewExtUnix;
const WORLD: &str = "CoincidePrivateCredentialFillV1";
// Native renderer/private-channel acceptance must precede public enablement.
const NATIVE_FILL_VALIDATED: bool = false;
pub fn available() -> bool {
    NATIVE_FILL_VALIDATED
}
struct Pending {
    permit: FillPermit,
    attempt: Option<Attempt>,
}
#[derive(Clone)]
pub struct NativeCredentialTarget {
    view: WebView,
    // WebKitGTK maps a world name to one shared world only while something
    // retains it; an unretained name gets a fresh world on every call, which
    // would drop the probe's binding before the fill. This inert script holds
    // the named world and is never added to a content manager or page.
    _world: UserScript,
    navigation: Arc<AtomicU64>,
    closed: Arc<AtomicBool>,
    pending: Rc<RefCell<Vec<Weak<RefCell<Pending>>>>>,
    lifetimes: Option<NativeLifetimes>,
    _view_lease: Option<NativeLease>,
}
impl NativeCredentialTarget {
    pub fn new(view: &wry::WebView, navigation: Arc<AtomicU64>) -> Option<Self> {
        gtk::is_initialized_main_thread().then(|| Self {
            view: view.webview(),
            _world: UserScript::for_world(
                "",
                UserContentInjectedFrames::TopFrame,
                UserScriptInjectionTime::End,
                WORLD,
                &[],
                &[],
            ),
            navigation,
            closed: Arc::new(AtomicBool::new(false)),
            pending: Rc::new(RefCell::new(Vec::new())),
            lifetimes: None,
            _view_lease: None,
        })
    }
    pub(in super::super) fn with_lifetimes(mut self, lifetimes: NativeLifetimes) -> Self {
        if self.lifetimes.is_none() {
            self._view_lease = Some(lifetimes.target());
            self.lifetimes = Some(lifetimes);
        }
        self
    }
    pub(in super::super) fn close(&self) {
        self.closed.store(true, Ordering::Release);
    }
    pub(in super::super) fn poll_ownership(&self) -> bool {
        let pending = self.pending.borrow().clone();
        for weak in pending {
            if let Some(state) = weak.upgrade() {
                let mut state = state.borrow_mut();
                let valid = state.permit.is_valid() && !self.closed.load(Ordering::Acquire);
                if let Some(attempt) = &mut state.attempt {
                    attempt.expire(valid);
                }
            }
        }
        self.pending
            .borrow_mut()
            .retain(|state| state.strong_count() != 0);
        self.pending.borrow().is_empty()
    }
    fn track(&self, permit: FillPermit, attempt: Attempt) -> Rc<RefCell<Pending>> {
        let state = Rc::new(RefCell::new(Pending {
            permit,
            attempt: Some(attempt),
        }));
        self.pending.borrow_mut().push(Rc::downgrade(&state));
        state
    }
    fn matches(&self, binding: &PageBinding) -> bool {
        if self.closed.load(Ordering::Acquire) {
            return false;
        }
        if self.navigation.load(Ordering::Acquire) != binding.navigation {
            return false;
        }
        let current = self.view.uri().and_then(|uri| {
            PageBinding::new(binding.tab.clone(), binding.navigation, uri.as_str()).ok()
        });
        current.as_ref() == Some(binding)
            && self.navigation.load(Ordering::Acquire) == binding.navigation
    }
    pub fn fill(
        &self,
        binding: PageBinding,
        permit: FillPermit,
        username: &str,
        password: &str,
        totp: Option<&str>,
        completion: Completion,
    ) {
        if !gtk::is_initialized_main_thread() {
            completion(Err(Failure::Unavailable));
            return;
        }
        if !permit.is_valid() {
            completion(Err(Failure::FillFailed));
            return;
        }
        if !self.matches(&binding) {
            completion(Err(Failure::StalePage));
            return;
        }
        if self.pending.borrow().iter().any(|weak| {
            weak.upgrade()
                .is_some_and(|state| state.borrow().attempt.is_some())
        }) {
            completion(Err(Failure::FillFailed));
            return;
        }
        let Some(slot) = FillSlot::reserve() else {
            completion(Err(Failure::FillFailed));
            return;
        };
        let ticket = uuid::Uuid::new_v4().to_string();
        let args = arguments(&[
            ("ticket", &ticket),
            ("expectedOrigin", binding.origin()),
            ("hasOtp", if totp.is_some() { "yes" } else { "no" }),
        ]);
        let state = self.track(
            permit.clone(),
            Attempt::new(slot, Secrets::new(username, password, totp), completion),
        );
        let target = self.clone();
        let probe_lease = self.lifetimes.as_ref().map(NativeLifetimes::block);
        self.view.call_async_javascript_function(
            PROBE,
            Some(&args),
            Some(WORLD),
            None,
            None::<&webkit2gtk::gio::Cancellable>,
            move |result| {
                let _held_probe = &probe_lease;
                let Some(mut attempt) = state.borrow_mut().attempt.take() else {
                    return;
                };
                if !boolean_reply(result) {
                    attempt.finish(Err(Failure::FillFailed));
                    return;
                }
                let Some(remaining) = permit.remaining() else {
                    attempt.finish(Err(Failure::FillFailed));
                    return;
                };
                if !target.matches(&binding) {
                    attempt.finish(Err(Failure::StalePage));
                    return;
                }
                let Ok(now) = SystemTime::now().duration_since(UNIX_EPOCH) else {
                    attempt.finish(Err(Failure::FillFailed));
                    return;
                };
                let Some(secrets) = attempt.take_for_dispatch() else {
                    attempt.finish(Err(Failure::FillFailed));
                    return;
                };
                let deadline = (now + remaining).as_millis().to_string();
                let encoded=(|| {
                    Ok::<_,Failure>((string_argument(&secrets.username)?,string_argument(&secrets.password)?,string_argument(secrets.totp.as_ref().map(|value|value.as_str()).unwrap_or(""))?))
                })();
                let Ok((username,password,totp))=encoded else {attempt.finish(Err(Failure::FillFailed));return;};
                let args = arguments(&[
                    ("ticket", &ticket),
                    ("expectedOrigin", binding.origin()),
                    ("deadline", &deadline),
                    ("usernameJSON", &username),
                    ("passwordJSON", &password),
                    ("totpJSON", &totp),
                ]);
                let final_state = target.track(permit.clone(), attempt);
                let final_target = target.clone();
                let mutation_lease = target.lifetimes.as_ref().map(NativeLifetimes::block);
                // Last reversible check; no await/user callback separates it from
                // the exact retained view's private-world SDK dispatch.
                if !permit.is_valid() || !target.matches(&binding) {
                    complete_state(&final_state, Err(Failure::StalePage));
                    return;
                }
                // Only these constant bodies form executable source. Secret
                // strings (including NUL/Unicode) remain typed native arguments.
                let body=format!("try {{ const username=JSON.parse(usernameJSON), password=JSON.parse(passwordJSON), totp=JSON.parse(totpJSON);\n{FILL}\n }} catch (_) {{ return false; }}");
                target.view.call_async_javascript_function(
                    &body,
                    Some(&args),
                    Some(WORLD),
                    None,
                    None::<&webkit2gtk::gio::Cancellable>,
                    move |result| {
                        let _held = (&mutation_lease, &final_target);
                        complete_state(
                            &final_state,
                            if boolean_reply(result) {
                                Ok(())
                            } else {
                                Err(Failure::FillFailed)
                            },
                        );
                    },
                );
            },
        );
    }
}
fn complete_state(state: &Rc<RefCell<Pending>>, result: Result<(), Failure>) {
    let attempt = state.borrow_mut().attempt.take();
    if let Some(attempt) = attempt {
        attempt.finish(result);
    }
}
fn arguments(pairs: &[(&str, &str)]) -> webkit2gtk::glib::Variant {
    let dict = webkit2gtk::glib::VariantDict::new(None);
    for (name, value) in pairs {
        dict.insert(name, *value);
    }
    dict.end()
}
fn boolean_reply(result: Result<java_script_core::Value, webkit2gtk::glib::Error>) -> bool {
    result.is_ok_and(|value| value.is_boolean() && value.to_boolean())
}
