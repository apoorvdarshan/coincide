//! Native-only browser sink. No agent JSON, page IPC, JavaScript source or logging.
//! Existing Wry backends cannot atomically check a Rust permit at DOM mutation.
//! Keep the capability off until a backend and its native acceptance prove that.
use crate::credentials::{FillPermit, PrivateBrowserHook};
use coincide_core::credentials::{Failure, PageBinding};

pub fn credential_fill_available() -> bool {
    false
}

/// A fresh UI-thread lookup, restricted to the parent's selected thread/tab.
/// The closure returns metadata only; it must never return page field values.
pub struct BrowserCredentialSink<F> {
    lookup: F,
}
impl<F> BrowserCredentialSink<F> {
    pub fn new(lookup: F) -> Self {
        Self { lookup }
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
        _username: &str,
        _password: &str,
        _totp: Option<&str>,
        completion: Box<dyn FnOnce(Result<(), Failure>)>,
    ) {
        // Do not format, copy, evaluate, or log the supplied secrets, even on
        // error. Availability is checked again at the sink, not only in UI.
        let result = validate_delivery(binding, permit.is_valid(), (self.lookup)(&binding.tab));
        completion(result);
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
    // This must remain unconditional until native mutation can atomically
    // validate BOTH original document identity and the revocable FillPermit.
    // A URL/epoch check followed by delayed Wry evaluation is insufficient.
    Err(Failure::Unavailable)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn page(tab: &str, navigation: u64, url: &str) -> PageBinding {
        PageBinding::new(tab.into(), navigation, url).unwrap()
    }
    #[test]
    fn matching_binding_cannot_enable_unsupported_backend() {
        assert!(!credential_fill_available());
        let expected = page("tab-a", 4, "https://example.test/login");
        assert_eq!(
            validate_delivery(&expected, true, Ok(expected.clone())),
            Err(Failure::Unavailable)
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
