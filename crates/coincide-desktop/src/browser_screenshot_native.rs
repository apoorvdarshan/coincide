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

#[cfg(target_os = "linux")]
#[path = "browser_screenshot_linux.rs"]
mod linux;
#[cfg(target_os = "macos")]
#[path = "browser_screenshot_macos.rs"]
mod platform;
#[cfg(target_os = "windows")]
#[path = "browser_screenshot_windows.rs"]
mod windows;
#[cfg(any(target_os = "windows", test))]
#[path = "browser_screenshot_windows_plan.rs"]
mod windows_plan;

#[derive(Default)]
pub(super) struct Handle {
    #[cfg(target_os = "windows")]
    poll: Option<Box<dyn Fn()>>,
}
impl Handle {
    pub fn poll(&self) {
        #[cfg(target_os = "windows")]
        if let Some(poll) = &self.poll {
            poll();
        }
    }
}
pub(super) fn capture(
    view: &wry::WebView,
    navigation: Arc<AtomicU64>,
    protected: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
    callbacks: Callbacks,
    full_page: bool,
    completion: Completion,
) -> Handle {
    #[cfg(target_os = "windows")]
    {
        windows::capture(
            view, navigation, protected, cancelled, callbacks, full_page, completion,
        )
    }
    #[cfg(target_os = "macos")]
    {
        platform::capture(
            view, navigation, protected, cancelled, callbacks, full_page, completion,
        );
        Handle::default()
    }
    #[cfg(target_os = "linux")]
    {
        linux::capture(
            view, navigation, protected, cancelled, callbacks, full_page, completion,
        );
        Handle::default()
    }
}
