//! Closed native page-key dispatch. No arbitrary scripts, CDP methods or global input.
use super::shutdown::{Callbacks, NativeLease};
use anyhow::{Context, Result};
use coincide_core::browser_protocol::keys::KeyPress;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Phase {
    Down,
    Up,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Delivered {
    Event,
    Equivalent,
}
#[cfg(target_os = "macos")]
#[path = "browser_native_keys_macos.rs"]
mod platform;
#[cfg(target_os = "linux")]
#[path = "browser_native_keys_linux.rs"]
mod platform;
#[cfg(target_os = "windows")]
#[path = "browser_native_keys_windows.rs"]
mod platform;
pub(super) struct Target {
    adapter: Option<platform::Adapter>,
    lease: Option<NativeLease>,
}
impl Target {
    pub(super) fn install(view: &wry::WebView, callbacks: &Callbacks) -> Self {
        let adapter = platform::Adapter::install(view).ok();
        let lease = adapter.as_ref().map(|_| callbacks.lifetimes().target());
        Self { adapter, lease }
    }
    pub(super) fn available(&self) -> bool {
        self.adapter.is_some()
    }
    pub(super) fn close(&mut self) {
        self.adapter = None;
        self.lease = None;
    }
    pub(super) fn dispatch(
        &self,
        key: &KeyPress,
        phase: Phase,
        callbacks: &Callbacks,
        finished: impl FnOnce(Result<Delivered>) + Send + 'static,
    ) -> Result<()> {
        key.admit_page_key()?;
        let adapter = self
            .adapter
            .as_ref()
            .context("Native page keys unavailable")?;
        anyhow::ensure!(!callbacks.closed(), "Browser is shutting down");
        let target = self
            .lease
            .as_ref()
            .context("Native page-key owner missing")?
            .clone();
        let ack = callbacks.begin();
        let block = callbacks.lifetimes().block();
        adapter.dispatch(key, phase, move |result| {
            // The native SDK, not the API reply or a timeout, returns custody.
            let _held = (&target, &block);
            finished(result);
            ack.ack();
        })
    }
}
