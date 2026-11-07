//! Own-view native key callbacks, bounded by the browser's shutdown fence.
//! No global keyboard hook, focus mutation, page script or arbitrary key API.
use super::shutdown::{Callbacks, NativeLease};
use crate::browser_tab_shortcuts::{self as shortcuts, Command};
use anyhow::Result;
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
#[cfg(target_os = "macos")]
#[path = "browser_tab_shortcuts_macos.rs"]
mod platform;
#[cfg(target_os = "windows")]
#[path = "browser_tab_shortcuts_windows.rs"]
mod platform;
#[cfg(target_os = "linux")]
#[path = "browser_tab_shortcuts_linux.rs"]
mod platform;
pub(super) struct Target {
    _adapter: platform::Adapter,
    _target: NativeLease,
}
impl Target {
    pub fn install(
        view: &wry::WebView,
        callbacks: &Callbacks,
        navigation: Arc<AtomicU64>,
        emit: impl Fn(Command, u64, Option<String>) -> bool + 'static,
    ) -> Result<Self> {
        let closed = callbacks.closed.clone();
        let adapter = platform::Adapter::install(
            view,
            callbacks,
            navigation.clone(),
            move |command, epoch, url| {
                // A recognized local key never falls through to a global command
                // when its old document closes, changes, or the queue is full.
                if !closed.load(Ordering::Acquire) && navigation.load(Ordering::Acquire) == epoch {
                    let _ = emit(command, epoch, url);
                }
                true
            },
        )?;
        Ok(Self {
            _adapter: adapter,
            _target: callbacks.lifetimes().target(),
        })
    }
}
