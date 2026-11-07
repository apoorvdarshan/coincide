//! Closed native WebView snapshot dispatch, never a desktop capture API.
use super::shutdown::Callbacks;
use coincide_core::browser_screenshot::Channels;
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64},
};

pub(super) struct Pixels {
    pub data: Data,
    pub geometry: coincide_core::browser_screenshot::Geometry,
    /// A full page longer than the captured document height.
    pub truncated: bool,
}
pub(super) enum Data {
    Png(Vec<u8>),
    /// Row-strided native pixels, converted on the owned encoder worker.
    Raw {
        width: u32,
        height: u32,
        stride: usize,
        bytes: Vec<u8>,
        channels: Channels,
    },
}
pub(super) type Completion = Box<dyn FnOnce(Result<Pixels, &'static str>)>;
type Capture = fn(
    &wry::WebView,
    Arc<AtomicU64>,
    Arc<AtomicBool>,
    Arc<AtomicBool>,
    Callbacks,
    bool,
    Completion,
);
#[cfg(target_os = "macos")]
#[path = "browser_screenshot_macos.rs"]
mod platform;
#[cfg(target_os = "linux")]
#[path = "browser_screenshot_linux.rs"]
mod platform;
#[cfg(target_os = "windows")]
#[path = "browser_screenshot_windows.rs"]
mod platform;
#[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
pub(super) use platform::capture;
#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
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
const _: Capture = capture;
