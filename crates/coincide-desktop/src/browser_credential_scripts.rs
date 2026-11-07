//! Fixed private-world credential bodies, byte-identical to accepted macOS
//! PROBE/FILL. Values are native SDK arguments, never executable source or IPC.
use std::sync::atomic::{AtomicUsize, Ordering};
// WebKit can retain an evaluation callback while its renderer is unresponsive.
// Keep its secret-bearing closures bounded even if the caller times out/retries.
pub(super) static ACTIVE_FILLS: AtomicUsize = AtomicUsize::new(0);
pub(super) struct FillSlot;
impl FillSlot {
    pub(super) fn reserve() -> Option<Self> {
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

pub(super) const PROBE: &str = r#"
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
pub(super) const FILL: &str = r#"
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

#[cfg(any(target_os = "linux", target_os = "windows", test))]
pub(super) type Completion = Box<dyn FnOnce(Result<(), coincide_core::credentials::Failure>)>;
/// Private memory only: no Debug, Serialize, IPC or persistent representation.
#[cfg(any(target_os = "linux", target_os = "windows", test))]
pub(super) struct Secrets {
    pub(super) username: zeroize::Zeroizing<String>,
    pub(super) password: zeroize::Zeroizing<String>,
    pub(super) totp: Option<zeroize::Zeroizing<String>>,
}
#[cfg(any(target_os = "linux", target_os = "windows", test))]
impl Secrets {
    pub(super) fn new(username: &str, password: &str, totp: Option<&str>) -> Self {
        Self {
            username: username.to_owned().into(),
            password: password.to_owned().into(),
            totp: totp.map(|value| zeroize::Zeroizing::new(value.to_owned())),
        }
    }
}
/// GVariant strings cannot contain NUL. Encode a string value as JSON in a
/// private SDK argument, then decode it only inside our named isolated world.
/// This is never executable-source interpolation or a public JSON operation.
#[cfg(any(target_os = "linux", test))]
pub(super) fn string_argument(
    value: &str,
) -> Result<zeroize::Zeroizing<String>, coincide_core::credentials::Failure> {
    serde_json::to_string(value)
        .map(zeroize::Zeroizing::new)
        .map_err(|_| coincide_core::credentials::Failure::FillFailed)
}
/// Expiry may erase undelivered memory, but never acknowledges native work.
/// Only the actual SDK callback owner consumes finish and returns its custody.
#[cfg(any(target_os = "linux", target_os = "windows", test))]
pub(super) struct Attempt {
    _slot: Option<FillSlot>,
    completion: Option<Completion>,
    secrets: Option<Secrets>,
    committed: bool,
}
#[cfg(any(target_os = "linux", target_os = "windows", test))]
impl Attempt {
    #[cfg(any(target_os = "linux", target_os = "windows"))]
    pub(super) fn new(slot: FillSlot, secrets: Secrets, completion: Completion) -> Self {
        Self {
            _slot: Some(slot),
            completion: Some(completion),
            secrets: Some(secrets),
            committed: false,
        }
    }
    pub(super) fn expire(&mut self, permit_valid: bool) {
        if !permit_valid && !self.committed {
            self.secrets = None;
        }
    }
    pub(super) fn take_for_dispatch(&mut self) -> Option<Secrets> {
        let secrets = self.secrets.take()?;
        self.committed = true;
        Some(secrets)
    }
    pub(super) fn finish(mut self, result: Result<(), coincide_core::credentials::Failure>) {
        if let Some(completion) = self.completion.take() {
            completion(result);
        }
    }
}
#[cfg(test)]
mod pending_tests {
    use super::*;
    use std::{
        cell::{Cell, RefCell},
        rc::Rc,
    };
    #[::core::prelude::v1::test]
    fn private_string_arguments_round_trip_unicode_quotes_and_nul_without_truncation() {
        let original = "synthetic-only\0\"\\\nλ";
        let argument = string_argument(original).unwrap();
        assert!(!argument.contains('\0'));
        assert_eq!(serde_json::from_str::<String>(&argument).unwrap(), original);
    }
    #[::core::prelude::v1::test]
    fn expiry_erases_undelivered_memory_without_acknowledging_or_replaying_native_callback() {
        let calls = Rc::new(Cell::new(0));
        let count = calls.clone();
        let mut attempt = Attempt {
            _slot: None,
            completion: Some(Box::new(move |result| {
                assert!(result.is_err());
                count.set(count.get() + 1);
            })),
            secrets: Some(Secrets::new(
                "synthetic-user",
                "synthetic-only-password",
                None,
            )),
            committed: false,
        };
        attempt.expire(false);
        assert_eq!(calls.get(), 0);
        assert!(attempt.take_for_dispatch().is_none());
        let pending = RefCell::new(Some(attempt));
        if let Some(attempt) = pending.borrow_mut().take() {
            attempt.finish(Err(coincide_core::credentials::Failure::FillFailed));
        }
        assert!(pending.borrow_mut().take().is_none());
        assert_eq!(calls.get(), 1);
    }
    #[::core::prelude::v1::test]
    fn dispatched_attempt_does_not_invent_retraction_or_complete_on_expiry() {
        let calls = Rc::new(Cell::new(0));
        let count = calls.clone();
        let mut attempt = Attempt {
            _slot: None,
            completion: Some(Box::new(move |_| count.set(count.get() + 1))),
            secrets: Some(Secrets::new(
                "synthetic-user",
                "synthetic-only-password",
                Some("000000"),
            )),
            committed: false,
        };
        let dispatched = attempt.take_for_dispatch().unwrap();
        assert!(attempt.take_for_dispatch().is_none());
        attempt.expire(false);
        assert_eq!(calls.get(), 0);
        assert_eq!(&*dispatched.password, "synthetic-only-password");
        assert_eq!(&*dispatched.username, "synthetic-user");
        assert_eq!(
            dispatched.totp.as_deref().map(|value| value.as_str()),
            Some("000000")
        );
        attempt.finish(Err(coincide_core::credentials::Failure::FillFailed));
        assert_eq!(calls.get(), 1);
    }
}
