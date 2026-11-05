//! Trusted native credential delivery; never an agent/browser JSON operation.
//! macOS uses a private WebKit content world and argument dictionaries. The
//! final native dispatch is the commit boundary; see the native bridge contract.
use crate::credentials::{FillPermit, PrivateBrowserHook};
use coincide_core::credentials::{Failure, PageBinding};

#[cfg(target_os = "macos")]
#[path = "browser_credentials_macos.rs"]
mod native;
#[cfg(target_os = "macos")]
pub use native::NativeCredentialTarget;
#[cfg(not(target_os = "macos"))]
pub struct NativeCredentialTarget;
#[cfg(not(target_os = "macos"))]
impl NativeCredentialTarget {
    pub fn new(
        _view: &wry::WebView,
        _navigation: std::sync::Arc<std::sync::atomic::AtomicU64>,
    ) -> Option<Self> {
        None
    }
}
pub fn credential_fill_available() -> bool {
    #[cfg(target_os = "macos")]
    {
        native::available()
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

/// Both arguments come from the selected thread/tab on the UI thread. The
/// lookup exposes metadata only. The retained native target is never public IPC.
type CompletionAck = Box<dyn FnOnce()>;
type CompletionTracker = Box<dyn Fn() -> CompletionAck>;

pub struct BrowserCredentialSink<F> {
    lookup: F,
    target: Option<NativeCredentialTarget>,
    completion_tracker: Option<CompletionTracker>,
}
impl<F> BrowserCredentialSink<F> {
    pub fn new(lookup: F) -> Self {
        Self {
            lookup,
            target: None,
            completion_tracker: None,
        }
    }
    pub fn with_completion_tracker(
        mut self,
        tracker: impl Fn() -> CompletionAck + 'static,
    ) -> Self {
        self.completion_tracker = Some(Box::new(tracker));
        self
    }
    pub fn with_target(mut self, target: Option<NativeCredentialTarget>) -> Self {
        self.target = target;
        self
    }
}
impl<F: Fn(&str) -> Result<PageBinding, Failure>> PrivateBrowserHook for BrowserCredentialSink<F> {
    fn current_binding(&self, tab: &str) -> Result<PageBinding, Failure> {
        (self.lookup)(tab)
    }
    fn fill_bound_document(
        &mut self,
        binding: &PageBinding,
        permit: FillPermit,
        username: &str,
        password: &str,
        totp: Option<&str>,
        completion: Box<dyn FnOnce(Result<(), Failure>)>,
    ) {
        let ack = self.completion_tracker.as_ref().map(|tracker| tracker());
        let completion: Box<dyn FnOnce(Result<(), Failure>)> = Box::new(move |result| {
            completion(result);
            if let Some(ack) = ack {
                ack();
            }
        });
        if let Err(error) =
            validate_delivery(binding, permit.is_valid(), (self.lookup)(&binding.tab))
        {
            completion(Err(error));
            return;
        }
        #[cfg(target_os = "macos")]
        if let Some(target) = &self.target {
            target.fill(
                binding.clone(),
                permit,
                username,
                password,
                totp,
                completion,
            );
            return;
        }
        #[cfg(not(target_os = "macos"))]
        let _ = (&self.target, username, password, totp);
        completion(Err(Failure::Unavailable));
    }
}
fn validate_delivery(
    expected: &PageBinding,
    permit_valid: bool,
    current: Result<PageBinding, Failure>,
) -> Result<(), Failure> {
    if !permit_valid {
        return Err(Failure::FillFailed);
    }
    if current.as_ref() != Ok(expected) {
        return Err(Failure::StalePage);
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn page(tab: &str, navigation: u64, url: &str) -> PageBinding {
        PageBinding::new(tab.into(), navigation, url).unwrap()
    }
    #[test]
    fn matching_binding_is_only_a_delivery_precondition() {
        let expected = page("tab-a", 4, "https://example.test/login");
        assert_eq!(
            validate_delivery(&expected, true, Ok(expected.clone())),
            Ok(())
        );
    }
    #[test]
    fn redirects_reload_history_other_tab_and_close_fail_closed() {
        let expected = page("tab-a", 4, "https://example.test/login");
        for current in [
            Ok(page("tab-a", 5, "https://example.test/login")),
            Ok(page("tab-a", 4, "https://other.test/login")),
            Ok(page("tab-b", 4, "https://example.test/login")),
            Err(Failure::StalePage),
        ] {
            assert_eq!(
                validate_delivery(&expected, true, current),
                Err(Failure::StalePage)
            );
        }
    }
    #[test]
    fn revoked_or_expired_permit_fails_even_with_matching_document() {
        let expected = page("tab-a", 4, "https://example.test/login");
        assert_eq!(
            validate_delivery(&expected, false, Ok(expected.clone())),
            Err(Failure::FillFailed)
        );
    }
}
