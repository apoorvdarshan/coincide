//! Private WebKit fill bridge (macOS 11+).
//!
//! No secret is interpolated into executable source, returned from JavaScript,
//! passed through Wry IPC, or included in NSError/error logging. A named isolated
//! world prevents page overrides of DOM prototypes from intercepting arguments.
//!
//! The secret-free probe binds a random ticket to this exact Document and field
//! objects. Its callback checks native origin, navigation epoch and permit again.
//! The final callAsyncJavaScript dispatch is the commit boundary: revocation
//! before dispatch prevents delivery; revocation after dispatch cannot retract
//! work already sent to WebKit. Renderer work additionally checks the original
//! document, origin, field identities and remaining deadline in one JS turn.
//! Success means values were assigned and checked, never that a form submitted.
//!
//! A filled website necessarily owns its DOM values. This is not protection from
//! a hostile destination exfiltrating its own fields. Native browser capture must
//! separately suppress/redact credential-bearing page output after approved fill.
use crate::credentials::FillPermit;
use block2::RcBlock;
use coincide_core::credentials::{Failure, PageBinding};
use objc2::{
    MainThreadMarker,
    rc::Retained,
    runtime::{AnyClass, AnyObject},
};
use objc2_foundation::{NSDictionary, NSError, NSNumber, NSString};
use objc2_web_kit::{WKContentWorld, WKWebView};
use std::{
    cell::RefCell,
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};
use wry::WebViewExtMacOS;

// WebKit can retain an evaluation callback while its renderer is unresponsive.
// Keep its secret-bearing closures bounded even if the caller times out/retries.
static ACTIVE_FILLS: AtomicUsize = AtomicUsize::new(0);
struct FillSlot;
impl FillSlot {
    fn reserve() -> Option<Self> {
        ACTIVE_FILLS
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < 2).then_some(count + 1)
            })
            .ok()
            .map(|_| Self)
    }
}
impl Drop for FillSlot {
    fn drop(&mut self) {
        ACTIVE_FILLS.fetch_sub(1, Ordering::AcqRel);
    }
}
type Completion = Box<dyn FnOnce(Result<(), Failure>)>;
// Enable only after the synthetic native acceptance has passed.
const NATIVE_FILL_VALIDATED: bool = false;
pub fn available() -> bool {
    NATIVE_FILL_VALIDATED && runtime_supported()
}
fn runtime_supported() -> bool {
    AnyClass::get(c"WKContentWorld").is_some()
}
#[derive(Clone)]
pub struct NativeCredentialTarget {
    view: Retained<WKWebView>,
    navigation: Arc<AtomicU64>,
}
impl NativeCredentialTarget {
    pub fn new(view: &wry::WebView, navigation: Arc<AtomicU64>) -> Option<Self> {
        (runtime_supported() && MainThreadMarker::new().is_some()).then(|| Self {
            view: view.webview().into_super(),
            navigation,
        })
    }
    fn matches(&self, binding: &PageBinding) -> bool {
        if self.navigation.load(Ordering::Acquire) != binding.navigation {
            return false;
        }
        // SAFETY: retained WKWebView, UI-thread-only target and completion calls.
        let current = unsafe { self.view.URL() }
            .and_then(|url| url.absoluteString())
            .and_then(|url| {
                PageBinding::new(binding.tab.clone(), binding.navigation, &url.to_string()).ok()
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
        let Some(mtm) = MainThreadMarker::new() else {
            completion(Err(Failure::Unavailable));
            return;
        };
        if !permit.is_valid() {
            completion(Err(Failure::FillFailed));
            return;
        }
        if !self.matches(&binding) {
            completion(Err(Failure::StalePage));
            return;
        }
        // SAFETY: checked macOS 11 class availability; called on the main thread.
        let Some(slot) = FillSlot::reserve() else {
            completion(Err(Failure::FillFailed));
            return;
        };
        let world = unsafe {
            WKContentWorld::worldWithName(
                &NSString::from_str("CoincidePrivateCredentialFillV1"),
                mtm,
            )
        };
        let ticket = uuid::Uuid::new_v4().to_string();
        let args = arguments(&[
            ("ticket", &ticket),
            ("expectedOrigin", binding.origin()),
            ("hasOtp", if totp.is_some() { "yes" } else { "no" }),
        ]);
        let target = self.clone();
        let world_for_callback = world.clone();
        // One-shot state also ensures an unexpected duplicate callback cannot
        // deliver the same password twice. Nothing implements Debug/Serialize.
        let pending = Rc::new(RefCell::new(Some((
            slot,
            completion,
            username.to_owned(),
            password.to_owned(),
            totp.map(str::to_owned),
        ))));
        let callback = RcBlock::new(move |value: *mut AnyObject, error: *mut NSError| {
            let Some((slot, completion, username, password, totp)) = pending.borrow_mut().take()
            else {
                return;
            };
            if !boolean_reply(value, error) {
                completion(Err(Failure::FillFailed));
                return;
            }
            let Some(remaining) = permit.remaining() else {
                completion(Err(Failure::FillFailed));
                return;
            };
            if !target.matches(&binding) {
                completion(Err(Failure::StalePage));
                return;
            }
            let Ok(now) = SystemTime::now().duration_since(UNIX_EPOCH) else {
                completion(Err(Failure::FillFailed));
                return;
            };
            let deadline = (now + remaining).as_millis().to_string();
            let args = arguments(&[
                ("ticket", &ticket),
                ("expectedOrigin", binding.origin()),
                ("deadline", &deadline),
                ("username", &username),
                ("password", &password),
                ("totp", totp.as_deref().unwrap_or("")),
            ]);
            let completion = Rc::new(RefCell::new(Some((slot, completion))));
            let finished = RcBlock::new(move |value: *mut AnyObject, error: *mut NSError| {
                if let Some((_slot, completion)) = completion.borrow_mut().take() {
                    completion(if boolean_reply(value, error) {
                        Ok(())
                    } else {
                        Err(Failure::FillFailed)
                    });
                }
            });
            // Last reversible check. No await, user callback, or event-loop turn
            // occurs between this check and the commit to WebKit's renderer.
            if !permit.is_valid() || !target.matches(&binding) {
                finished.call((std::ptr::null_mut(), std::ptr::null_mut()));
                return;
            }
            // SAFETY: dictionary contains only NSString keys/objects, API accepts
            // JS-compatible strings; retained objects and block live through call.
            unsafe {
                target
                    .view
                    .callAsyncJavaScript_arguments_inFrame_inContentWorld_completionHandler(
                        &NSString::from_str(FILL),
                        Some(&args),
                        None,
                        &world_for_callback,
                        Some(&finished),
                    );
            }
        });
        // The probe contains no secret arguments and runs in the same isolated
        // world as the final synchronous mutation, restricted to the main frame.
        unsafe {
            self.view
                .callAsyncJavaScript_arguments_inFrame_inContentWorld_completionHandler(
                    &NSString::from_str(PROBE),
                    Some(&args),
                    None,
                    &world,
                    Some(&callback),
                );
        }
    }
}
fn arguments(pairs: &[(&str, &str)]) -> Retained<NSDictionary<NSString, AnyObject>> {
    let keys: Vec<_> = pairs
        .iter()
        .map(|(key, _)| NSString::from_str(key))
        .collect();
    let values: Vec<_> = pairs
        .iter()
        .map(|(_, value)| NSString::from_str(value))
        .collect();
    let keys: Vec<&NSString> = keys.iter().map(|key| &**key).collect();
    let values: Vec<&AnyObject> = values.iter().map(|value| -> &AnyObject { value }).collect();
    NSDictionary::from_slices(&keys, &values)
}
fn boolean_reply(value: *mut AnyObject, error: *mut NSError) -> bool {
    // Do not read an NSError description or arbitrary returned object. Only the
    // boolean created by our static isolated-world script is accepted.
    if !error.is_null() {
        return false;
    }
    unsafe { value.as_ref() }
        .and_then(|value| value.downcast_ref::<NSNumber>())
        .is_some_and(|value| value.boolValue())
}
const PROBE: &str = r#"
try {
  delete globalThis.__coincidePrivateFill;
  if (location.origin !== expectedOrigin || window.top !== window) return false;
  const usable = el => el instanceof HTMLInputElement && !el.disabled && !el.readOnly && el.isConnected && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
  const inputs = [...document.querySelectorAll('input')].filter(usable);
  const passwords = inputs.filter(el => el.type === 'password' && el.autocomplete !== 'new-password');
  if (passwords.length > 1) return false;
  const pass = passwords[0] || null;
  const otps = inputs.filter(el => el.autocomplete === 'one-time-code');
  if (hasOtp === 'yes' && otps.length > 1) return false;
  const otp = hasOtp === 'yes' ? (otps[0] || null) : null;
  if (pass && otp && pass.form !== otp.form) return false;
  if (!pass && !otp) return false;
  const scope = pass?.form || otp?.form || document;
  let users = inputs.filter(el => scope.contains(el) && ['text','email','tel'].includes(el.type) && ['username','email'].includes(el.autocomplete));
  if (!users.length) users = inputs.filter(el => scope.contains(el) && ['text','email'].includes(el.type) && el !== otp && /user|email|login/i.test(el.name+' '+el.id));
  if (users.length > 1) return false;
  const user = users[0] || null;
  globalThis.__coincidePrivateFill = {ticket, doc:document, pass, user, otp, usable,
    types:[pass,user,otp].map(el => el ? [el.type,el.autocomplete,el.form] : null), expires:performance.now()+9000};
  return true;
} catch (_) { return false; }
"#;
const FILL: &str = r#"
try {
  const binding = globalThis.__coincidePrivateFill;
  delete globalThis.__coincidePrivateFill;
  if (!binding || binding.ticket !== ticket || binding.doc !== document || location.origin !== expectedOrigin || window.top !== window || Date.now() >= Number(deadline) || performance.now() >= binding.expires) return false;
  const fields = [binding.pass,binding.user,binding.otp];
  if (fields.some((el,i) => el && (!binding.usable(el) || el.ownerDocument !== document || el.type !== binding.types[i][0] || el.autocomplete !== binding.types[i][1] || el.form !== binding.types[i][2]))) return false;
  if (binding.pass && !password) return false;
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
  const values = [password,username,totp];
  for (let i=0;i<fields.length;i++) if(fields[i]) setter.call(fields[i],values[i]);
  const confirmed = fields.every((el,i) => !el || el.value === values[i]);
  if (!confirmed) return false;
  for (const el of fields) if(el) { el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true})); }
  return binding.doc === document && location.origin === expectedOrigin && fields.every((el,i) => !el || (el.isConnected && el.ownerDocument === document && el.type === binding.types[i][0] && el.value === values[i]));
} catch (_) { return false; }
"#;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unresponsive_renderer_work_is_bounded_and_slots_recover() {
        let first = FillSlot::reserve().unwrap();
        let second = FillSlot::reserve().unwrap();
        assert!(FillSlot::reserve().is_none());
        drop(first);
        let replacement = FillSlot::reserve().unwrap();
        assert!(FillSlot::reserve().is_none());
        drop((second, replacement));
        assert_eq!(ACTIVE_FILLS.load(Ordering::Acquire), 0);
    }
    #[test]
    fn callback_accepts_only_boolean_success_and_never_inspects_error_text() {
        let success = NSNumber::numberWithBool(true);
        let failure = NSNumber::numberWithBool(false);
        let arbitrary = NSString::from_str("synthetic-only-return-must-not-be-an-acknowledgement");
        assert!(boolean_reply(
            Retained::as_ptr(&success).cast_mut().cast(),
            std::ptr::null_mut()
        ));
        assert!(!boolean_reply(
            Retained::as_ptr(&failure).cast_mut().cast(),
            std::ptr::null_mut()
        ));
        assert!(!boolean_reply(
            Retained::as_ptr(&arbitrary).cast_mut().cast(),
            std::ptr::null_mut()
        ));
        assert!(!boolean_reply(std::ptr::null_mut(), std::ptr::null_mut()));
        // SAFETY: no userInfo dictionary, and a valid Foundation string.
        let error = unsafe {
            NSError::errorWithDomain_code_userInfo(&NSString::from_str("synthetic-error"), 1, None)
        };
        assert!(!boolean_reply(
            Retained::as_ptr(&success).cast_mut().cast(),
            Retained::as_ptr(&error).cast_mut()
        ));
    }
}
