//! Closed native WebView snapshot dispatch, never a desktop capture API.
use super::shutdown::Callbacks;
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64},
};

pub(super) struct Pixels {
    pub data: Data,
    pub geometry: coincide_core::browser_screenshot::Geometry,
}
pub(super) enum Data {
    Png(Vec<u8>),
    #[cfg(target_os = "linux")]
    Argb32 {
        width: u32,
        height: u32,
        stride: usize,
        bytes: Vec<u8>,
    },
}
pub(super) type Completion = Box<dyn FnOnce(Result<Pixels, &'static str>)>;
#[cfg(target_os = "macos")]
#[path = "browser_screenshot_macos.rs"]
mod platform;
#[cfg(target_os = "macos")]
pub(super) use platform::capture;
#[cfg(target_os = "linux")]
#[path = "browser_screenshot_linux.rs"]
mod linux;
#[cfg(target_os = "linux")]
pub(super) use linux::capture;
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(super) fn capture(
    _view: &wry::WebView,
    _navigation: Arc<AtomicU64>,
    _protected: Arc<AtomicBool>,
    _cancelled: Arc<AtomicBool>,
    _callbacks: Callbacks,
    _full_page: bool,
    completion: Completion,
) {
    completion(Err(
        "Native WebView screenshots are not yet available on this platform",
    ));
}
// Keep the facade contract identical on every host.
#[cfg(target_os = "macos")]
const _: fn(
    &wry::WebView,
    Arc<AtomicU64>,
    Arc<AtomicBool>,
    Arc<AtomicBool>,
    Callbacks,
    bool,
    Completion,
) = capture;
