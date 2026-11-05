//! macOS public WebKit cookie insertion, without Wry's synchronous run-loop pump.
//! Browser child module: parent supplies its existing shutdown callback registry.
//! No JSON/native picker/navigation authority and no timeout/cancellation/retry.
use super::shutdown::{Callbacks, NativeLease};
use coincide_core::firefox_cookie_import::{Binding, Cookie, SameSite};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Failure {
    Unavailable,
    ClosedOrStale,
    InvalidCookie,
    UnsupportedSameSiteNone,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Status {
    DispatchedUnknown,
    StoredBlockRetained,
    StoredBlockReleased,
}
pub(super) struct Receipt {
    stored: Arc<AtomicBool>,
    released: Arc<AtomicBool>,
}
impl Receipt {
    pub fn status(&self) -> Status {
        if !self.stored.load(Ordering::Acquire) {
            Status::DispatchedUnknown
        } else if self.released.load(Ordering::Acquire) {
            Status::StoredBlockReleased
        } else {
            Status::StoredBlockRetained
        }
    }
}
struct Released(Arc<AtomicBool>);
impl Drop for Released {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}
struct BlockOwner {
    // Fields drop in declaration order: lease release precedes receipt publication.
    _lease: NativeLease,
    _released: Released,
}
fn validate_policy(requested: SameSite, actual: Option<&str>) -> Result<(), Failure> {
    let expected = match requested {
        SameSite::Unspecified => None,
        SameSite::None => Some("none"),
        SameSite::Lax => Some("lax"),
        SameSite::Strict => Some("strict"),
    };
    if actual == expected {
        Ok(())
    } else if requested == SameSite::None {
        Err(Failure::UnsupportedSameSiteNone)
    } else {
        Err(Failure::InvalidCookie)
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct ReadbackCounts {
    pub expected: usize,
    pub observed: usize,
    pub matched: usize,
}
impl ReadbackCounts {
    pub fn exact(&self) -> bool {
        self.expected == self.observed && self.expected == self.matched
    }
}
fn readback_counts<E, A>(
    expected: &[E],
    actual: &[A],
    matches: impl Fn(&E, &A) -> bool,
) -> ReadbackCounts {
    ReadbackCounts {
        expected: expected.len(),
        observed: actual.len(),
        matched: if actual.len() > 1000 {
            0
        } else {
            expected
                .iter()
                .filter(|expected| actual.iter().any(|actual| matches(expected, actual)))
                .count()
        },
    }
}
#[cfg(target_os = "macos")]
mod native {
    use super::*;
    use block2::RcBlock;
    use objc2::{MainThreadMarker, rc::Retained, runtime::AnyObject};
    use objc2_foundation::{
        NSDate, NSDictionary, NSHTTPCookie, NSHTTPCookiePropertyKey, NSMutableDictionary, NSString,
    };
    use objc2_web_kit::{WKHTTPCookieStore, WKWebsiteDataStore};
    pub(in super::super) struct PreparedCookie {
        native: Retained<NSHTTPCookie>,
        input: Cookie,
    }
    impl PreparedCookie {
        /// Foundation representation only: no native store/profile is created.
        pub fn prepare(input: Cookie) -> Result<Self, Failure> {
            MainThreadMarker::new().ok_or(Failure::Unavailable)?;
            Ok(Self {
                native: cookie(&input)?,
                input,
            })
        }
        pub fn expired(&self, now: u64) -> bool {
            self.input
                .expires()
                .is_some_and(|expiry| expiry < 0 || expiry as u64 <= now)
        }
    }
    pub(in super::super) struct ReadbackReceipt {
        result: Arc<std::sync::Mutex<Option<ReadbackCounts>>>,
        released: Arc<AtomicBool>,
    }
    impl ReadbackReceipt {
        pub fn result(&self) -> Option<(ReadbackCounts, bool)> {
            self.result
                .try_lock()
                .ok()
                .and_then(|result| *result)
                .map(|result| (result, self.released.load(Ordering::Acquire)))
        }
    }
    pub(in super::super) struct Target {
        store: Retained<WKHTTPCookieStore>,
        _data_store: Retained<WKWebsiteDataStore>,
        binding: Binding,
        callbacks: Callbacks,
        // Store is released before its counted native-target lease.
        _lease: NativeLease,
    }
    fn cookie(input: &Cookie) -> Result<Retained<NSHTTPCookie>, Failure> {
        // Keys and values have the Foundation-declared property types. Values
        // never become executable JS, NSError text, IPC, JSON, or logs.
        let name = NSString::from_str(input.name());
        let value = NSString::from_str(input.value());
        let domain = NSString::from_str(input.domain());
        let path = NSString::from_str(input.path());
        use objc2_foundation::{
            NSHTTPCookieDiscard, NSHTTPCookieDomain, NSHTTPCookieExpires, NSHTTPCookieName,
            NSHTTPCookiePath, NSHTTPCookieSameSitePolicy, NSHTTPCookieSecure, NSHTTPCookieValue,
        };
        let properties: Retained<NSMutableDictionary<NSHTTPCookiePropertyKey, AnyObject>> = unsafe {
            NSMutableDictionary::from_slices(
                &[
                    NSHTTPCookieName,
                    NSHTTPCookieValue,
                    NSHTTPCookieDomain,
                    NSHTTPCookiePath,
                ],
                &[&name, &value, &domain, &path],
            )
        };
        let yes = NSString::from_str("TRUE");
        unsafe {
            if input.secure() {
                properties.insert(NSHTTPCookieSecure, &*yes);
            }
            if input.http_only() {
                properties.insert(&*NSString::from_str("HttpOnly"), &*yes);
            }
            if let Some(expiry) = input.expires() {
                properties.insert(
                    NSHTTPCookieExpires,
                    &*NSDate::dateWithTimeIntervalSince1970(expiry as f64),
                );
            } else {
                properties.insert(NSHTTPCookieDiscard, &*yes);
            }
            let policy = match input.same_site() {
                SameSite::Unspecified => None,
                SameSite::None => Some("none"),
                SameSite::Lax => Some("lax"),
                SameSite::Strict => Some("strict"),
            };
            if let Some(policy) = policy {
                properties.insert(NSHTTPCookieSameSitePolicy, &*NSString::from_str(policy));
            }
            let properties: &NSDictionary<NSHTTPCookiePropertyKey, AnyObject> = &properties;
            let cookie = NSHTTPCookie::cookieWithProperties(properties).ok_or(
                if input.same_site() == SameSite::None {
                    Failure::UnsupportedSameSiteNone
                } else {
                    Failure::InvalidCookie
                },
            )?;
            matches_cookie(&cookie, input)?;
            Ok(cookie)
        }
    }
    fn matches_cookie(cookie: &NSHTTPCookie, input: &Cookie) -> Result<(), Failure> {
        let actual = cookie.sameSitePolicy().map(|policy| policy.to_string());
        validate_policy(input.same_site(), actual.as_deref())?;
        if cookie.isSecure() != input.secure()
            || cookie.isHTTPOnly() != input.http_only()
            || cookie.name().to_string() != input.name()
            || cookie.value().to_string() != input.value()
            || cookie.domain().to_string() != input.domain()
            || cookie.path().to_string() != input.path()
            || cookie.isSessionOnly() != input.expires().is_none()
            || cookie
                .expiresDate()
                .map(|date| date.timeIntervalSince1970() as i64)
                != input.expires()
        {
            return Err(Failure::InvalidCookie);
        }
        Ok(())
    }
    impl Target {
        /// Parent must mark ever-native BEFORE calling this factory, including
        /// failures/zero-view contexts, and only use a freshly reserved UUID.
        pub fn for_named_profile(binding: Binding, callbacks: Callbacks) -> Result<Self, Failure> {
            let mtm = MainThreadMarker::new().ok_or(Failure::Unavailable)?;
            if callbacks.closed() || binding.profile.is_nil() {
                return Err(Failure::ClosedOrStale);
            }
            let available: bool = unsafe {
                objc2::msg_send![objc2::class!(WKWebsiteDataStore), respondsToSelector:objc2::sel!(dataStoreForIdentifier:)]
            };
            if !available {
                return Err(Failure::Unavailable);
            }
            let identifier = objc2_foundation::NSUUID::from_bytes(*binding.profile.as_bytes());
            let data_store =
                unsafe { WKWebsiteDataStore::dataStoreForIdentifier(&identifier, mtm) };
            let store = unsafe { data_store.httpCookieStore() };
            let lease = callbacks.lifetimes().target();
            Ok(Self {
                store,
                _data_store: data_store,
                binding,
                callbacks,
                _lease: lease,
            })
        }
        /// Dispatch is irreversible; callback silence remains Unknown. No timeout
        /// cancels/retries the mutation, and no store is captured by its block.
        pub fn dispatch_prepared(
            &self,
            prepared: &PreparedCookie,
            current: &Binding,
        ) -> Result<Receipt, Failure> {
            MainThreadMarker::new().ok_or(Failure::Unavailable)?;
            if self.callbacks.closed() || *current != self.binding {
                return Err(Failure::ClosedOrStale);
            }
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(|_| Failure::Unavailable)?
                .as_secs();
            if prepared.expired(now) {
                return Err(Failure::InvalidCookie);
            }
            let stored = Arc::new(AtomicBool::new(false));
            let released = Arc::new(AtomicBool::new(false));
            let held = BlockOwner {
                _released: Released(released.clone()),
                _lease: self.callbacks.lifetimes().block(),
            };
            let ack = self.callbacks.begin();
            let result = stored.clone();
            // Do not capture self, store, view, Cookie, manager or callback owner:
            // WKHTTPCookieStore may own this block until native completion.
            let block = RcBlock::new(move || {
                let _owner = &held;
                result.store(true, Ordering::Release);
                ack.ack();
            });
            unsafe {
                self.store
                    .setCookie_completionHandler(&prepared.native, Some(&block));
            }
            Ok(Receipt { stored, released })
        }
        /// Read only this freshly-created destination. Native result values stay
        /// inside the callback; no target/store/view/manager is captured.
        pub fn readback(
            &self,
            expected: Vec<PreparedCookie>,
            current: &Binding,
        ) -> Result<ReadbackReceipt, Failure> {
            MainThreadMarker::new().ok_or(Failure::Unavailable)?;
            if self.callbacks.closed() || *current != self.binding {
                return Err(Failure::ClosedOrStale);
            }
            if expected.len() > 1000 {
                return Err(Failure::InvalidCookie);
            }
            let result = Arc::new(std::sync::Mutex::new(None));
            let released = Arc::new(AtomicBool::new(false));
            let held = BlockOwner {
                _lease: self.callbacks.lifetimes().block(),
                _released: Released(released.clone()),
            };
            let ack = self.callbacks.begin();
            let output = result.clone();
            let block = RcBlock::new(
                move |cookies: std::ptr::NonNull<objc2_foundation::NSArray<NSHTTPCookie>>| {
                    let _owner = &held;
                    let cookies = unsafe { cookies.as_ref() };
                    let observed = cookies.len();
                    let counts = if observed <= 1000 {
                        let actual = cookies.to_vec();
                        readback_counts(&expected, &actual, |expected, cookie| {
                            matches_cookie(cookie, &expected.input).is_ok()
                        })
                    } else {
                        ReadbackCounts {
                            expected: expected.len(),
                            observed,
                            matched: 0,
                        }
                    };
                    if let Ok(mut result) = output.lock() {
                        *result = Some(counts);
                    }
                    ack.ack();
                },
            );
            unsafe {
                self.store.getAllCookies(&block);
            }
            Ok(ReadbackReceipt { result, released })
        }
    }
}
#[cfg(target_os = "macos")]
pub(super) use native::{PreparedCookie, ReadbackReceipt, Target};

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn callback_return_and_block_destruction_are_distinct_from_dispatch_or_drop() {
        let callbacks = Callbacks::default();
        let stored = Arc::new(AtomicBool::new(false));
        let released = Arc::new(AtomicBool::new(false));
        let receipt = Receipt {
            stored: stored.clone(),
            released: released.clone(),
        };
        let held = BlockOwner {
            _released: Released(released),
            _lease: callbacks.lifetimes().block(),
        };
        let ack = callbacks.begin();
        let callback = move || {
            let _owner = &held;
            stored.store(true, Ordering::Release);
            ack.ack();
        };
        assert_eq!(receipt.status(), Status::DispatchedUnknown);
        assert_eq!(callbacks.pending(), 1);
        callback();
        assert_eq!(receipt.status(), Status::StoredBlockRetained);
        assert_eq!(callbacks.pending(), 0);
        drop(callback);
        assert_eq!(receipt.status(), Status::StoredBlockReleased);
    }
    #[test]
    fn dropped_uninvoked_callback_stays_unknown_and_shutdown_does_not_ack() {
        let callbacks = Callbacks::default();
        let stored = Arc::new(AtomicBool::new(false));
        let released = Arc::new(AtomicBool::new(false));
        let receipt = Receipt {
            stored: stored.clone(),
            released: released.clone(),
        };
        let held = BlockOwner {
            _released: Released(released),
            _lease: callbacks.lifetimes().block(),
        };
        let ack = callbacks.begin();
        let callback = move || {
            let _owner = &held;
            stored.store(true, Ordering::Release);
            ack.ack();
        };
        callbacks.closed.store(true, Ordering::Release);
        drop(callback);
        assert_eq!(receipt.status(), Status::DispatchedUnknown);
        assert_eq!(callbacks.pending(), 1);
    }
    #[test]
    fn unsupported_none_policy_is_an_explicit_refusal_not_a_downgrade() {
        assert_eq!(
            validate_policy(SameSite::None, None),
            Err(Failure::UnsupportedSameSiteNone)
        );
        assert_eq!(
            validate_policy(SameSite::None, Some("lax")),
            Err(Failure::UnsupportedSameSiteNone)
        );
        assert_eq!(validate_policy(SameSite::None, Some("none")), Ok(()));
        assert_eq!(
            validate_policy(SameSite::Lax, Some("strict")),
            Err(Failure::InvalidCookie)
        );
    }
    #[test]
    fn readback_requires_exact_private_values_attributes_and_bounded_total_count() {
        let expected = [("name", "synthetic-value", true)];
        let exact = readback_counts(&expected, &expected, |a, b| a == b);
        assert!(exact.exact());
        let changed = [("name", "different-synthetic", true)];
        assert!(!readback_counts(&expected, &changed, |a, b| a == b).exact());
        let weak = [("name", "synthetic-value", false)];
        assert_eq!(readback_counts(&expected, &weak, |a, b| a == b).matched, 0);
        let extra = [expected[0], ("extra", "synthetic", false)];
        let counts = readback_counts(&expected, &extra, |a, b| a == b);
        assert_eq!(counts.matched, 1);
        assert!(!counts.exact());
        let oversized = vec![expected[0]; 1001];
        assert_eq!(
            readback_counts(&expected, &oversized, |a, b| a == b).matched,
            0
        );
    }
}
