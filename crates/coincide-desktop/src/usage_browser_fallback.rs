//! Read only the OpenCode cookies from Coincide's default WebKit profile.
//! No cookie or account data is exposed to the transcript or browser tools.
use coincide_core::api::SharedEngine;
#[cfg(target_os = "macos")]
use std::sync::mpsc;
use std::sync::mpsc::Receiver;
use zeroize::Zeroizing;

#[cfg(target_os = "macos")]
pub(super) fn chrome_is_default() -> bool {
    unsafe extern "C" {
        fn coincide_usage_default_browser_is_chrome() -> i32;
    }
    // This is called on the desktop's main thread, like the status item.
    unsafe { coincide_usage_default_browser_is_chrome() != 0 }
}
#[cfg(not(target_os = "macos"))]
pub(super) fn chrome_is_default() -> bool {
    false
}

#[cfg(any(target_os = "macos", test))]
fn cookie_applies(domain: &str, path: &str, name: &str, expired: bool) -> bool {
    let path_matches = |target: &str| {
        target == path
            || target
                .strip_prefix(path)
                .is_some_and(|rest| path.ends_with('/') || rest.starts_with('/'))
    };
    domain
        .trim_start_matches('.')
        .eq_ignore_ascii_case("opencode.ai")
        && !expired
        && !name.is_empty()
        && name.len() <= 256
        && !name
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || c == ';' || c == '=')
        && path_matches("/console/api/orgs")
        && path_matches("/console/api/billing/drawer/status")
}

#[cfg(target_os = "macos")]
pub(super) fn opencode(engine: &SharedEngine) -> Option<Receiver<Option<Zeroizing<String>>>> {
    use block2::RcBlock;
    use objc2::MainThreadMarker;
    use objc2_foundation::{NSArray, NSHTTPCookie, NSUUID};
    use objc2_web_kit::WKWebsiteDataStore;
    let path = engine
        .try_lock()
        .ok()?
        .store
        .data_directory()
        .ok()?
        .join("browser-profile/profile-id");
    let meta = std::fs::symlink_metadata(&path).ok()?;
    if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > 64 {
        return None;
    }
    let id = uuid::Uuid::parse_str(std::fs::read_to_string(path).ok()?.trim()).ok()?;
    let mtm = MainThreadMarker::new()?;
    let named: bool = unsafe {
        objc2::msg_send![objc2::class!(WKWebsiteDataStore), respondsToSelector:objc2::sel!(dataStoreForIdentifier:)]
    };
    let data_store = if named {
        unsafe {
            WKWebsiteDataStore::dataStoreForIdentifier(&NSUUID::from_bytes(*id.as_bytes()), mtm)
        }
    } else {
        unsafe { WKWebsiteDataStore::defaultDataStore(mtm) }
    };
    let store = unsafe { data_store.httpCookieStore() };
    let (sender, receiver) = mpsc::sync_channel(1);
    let block = RcBlock::new(move |cookies: std::ptr::NonNull<NSArray<NSHTTPCookie>>| {
        let cookies = unsafe { cookies.as_ref() };
        let mut selected = Vec::new();
        let now = chrono::Utc::now().timestamp() as f64;
        if cookies.len() <= 4096 {
            for item in cookies.to_vec() {
                let domain = item.domain().to_string().to_ascii_lowercase();
                let path = item.path().to_string();
                let name = item.name().to_string();
                let expired = item
                    .expiresDate()
                    .is_some_and(|d| d.timeIntervalSince1970() <= now);
                if !cookie_applies(&domain, &path, &name, expired) {
                    continue;
                }
                // Only touch the value after its host and path have matched.
                let value = Zeroizing::new(item.value().to_string());
                if value.len() > 4096 || value.chars().any(|c| c.is_control() || c == ';') {
                    continue;
                }
                selected.push((path.len(), name, value));
                if selected.len() > 128 {
                    selected.clear();
                    break;
                }
            }
        }
        selected.sort_by_key(|row| std::cmp::Reverse(row.0));
        let signed_in = selected.iter().any(|(_, name, _)| {
            name == "__Host-console_session"
                || name == "console_session"
                || name.starts_with("__Host-console_session.")
                || name.starts_with("console_session.")
        });
        let header = if signed_in {
            let mut header = Zeroizing::new(String::new());
            for (_, name, value) in selected {
                if !header.is_empty() {
                    header.push_str("; ");
                }
                header.push_str(&name);
                header.push('=');
                header.push_str(&value);
            }
            (header.len() <= 32768).then_some(header)
        } else {
            None
        };
        let _ = sender.try_send(header);
    });
    unsafe {
        store.getAllCookies(&block);
    }
    Some(receiver)
}

#[cfg(not(target_os = "macos"))]
pub(super) fn opencode(_engine: &SharedEngine) -> Option<Receiver<Option<Zeroizing<String>>>> {
    None
}

#[cfg(test)]
mod tests {
    use super::cookie_applies;
    #[test]
    fn only_unexpired_opencode_cookies_for_both_billing_paths_are_used() {
        assert!(cookie_applies(
            ".opencode.ai",
            "/",
            "console_session",
            false
        ));
        assert!(cookie_applies(
            "opencode.ai",
            "/console/api",
            "console_session",
            false
        ));
        assert!(!cookie_applies(
            "example.com",
            "/",
            "console_session",
            false
        ));
        assert!(!cookie_applies(
            "opencode.ai.example.com",
            "/",
            "console_session",
            false
        ));
        assert!(!cookie_applies(
            "opencode.ai",
            "/con",
            "console_session",
            false
        ));
        assert!(!cookie_applies(
            "opencode.ai",
            "/console/api/billing",
            "console_session",
            false
        ));
        assert!(!cookie_applies("opencode.ai", "/", "console_session", true));
        assert!(!cookie_applies("opencode.ai", "/", "bad=name", false));
    }
}
