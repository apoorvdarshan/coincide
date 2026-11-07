//! Native private-store checks. A requested builder flag is not a privacy proof.
#[cfg(any(target_os = "linux", target_os = "windows"))]
use anyhow::Context;
use anyhow::{Result, ensure};
#[cfg(any(target_os = "linux", target_os = "windows"))]
use std::collections::HashMap;
#[cfg(target_os = "linux")]
use webkit2gtk::prelude::*;
#[cfg(target_os = "linux")]
use wry::WebViewExtUnix;

#[cfg(target_os = "linux")]
pub(super) struct Anchor {
    view: webkit2gtk::WebView,
}
#[cfg(target_os = "linux")]
impl Anchor {
    pub(super) fn native(&self) -> webkit2gtk::WebView {
        self.view.clone()
    }
}
#[cfg(target_os = "linux")]
impl Drop for Anchor {
    fn drop(&mut self) {
        // This never contained an external document and is never presented.
        // GTK destruction is not promoted to a native SDK deallocation proof.
        use gtk::prelude::WidgetExtManual;
        // The builder has finished consuming its related-view clone before
        // this guard drops. No Rust code queries the anchor after destruction.
        unsafe {
            self.view.destroy();
        }
    }
}
#[derive(Default)]
pub(super) struct PrivateProfiles {
    #[cfg(target_os = "linux")]
    contexts: HashMap<String, webkit2gtk::WebContext>,
    #[cfg(target_os = "windows")]
    runtimes: HashMap<String, WindowsRuntime>,
}
#[cfg(target_os = "windows")]
struct WindowsRuntime {
    directory: std::path::PathBuf,
    native_profile: Option<std::path::PathBuf>,
}
impl PrivateProfiles {
    #[cfg(target_os = "windows")]
    pub(super) fn runtime_directory(
        &mut self,
        thread: &str,
        catalog: &crate::browser_settings::ProfileCatalog,
    ) -> Result<std::path::PathBuf> {
        if !self.runtimes.contains_key(thread) {
            let directory = catalog.new_private_runtime_directory()?;
            self.runtimes.insert(
                thread.into(),
                WindowsRuntime {
                    directory,
                    native_profile: None,
                },
            );
        }
        Ok(self.runtimes[thread].directory.clone())
    }
    #[cfg(target_os = "linux")]
    pub(super) fn related(&mut self, thread: &str) -> Result<Anchor> {
        // Retain only the actual native ephemeral context for this thread.
        // Wry's public Unix builder cannot accept it directly. A temporary
        // blank, JavaScript-disabled related view transfers that exact context
        // to the user view, then is destroyed by its construction-scope guard.
        let context = self
            .contexts
            .entry(thread.into())
            .or_insert_with(webkit2gtk::WebContext::new_ephemeral);
        ensure!(
            context.is_ephemeral(),
            "Native browser did not create private storage"
        );
        let view = webkit2gtk::WebView::with_context(context);
        let settings = webkit2gtk::Settings::new();
        settings.set_enable_javascript(false);
        view.set_settings(&settings);
        ensure!(
            view.is_ephemeral() && view.context().as_ref() == Some(&*context),
            "Native private anchor changed its context"
        );
        Ok(Anchor { view })
    }
    pub(super) fn verify(&mut self, thread: &str, view: &wry::WebView) -> Result<()> {
        #[cfg(target_os = "linux")]
        {
            let expected = self
                .contexts
                .get(thread)
                .context("Private native browser owner missing")?;
            let native = view.webview();
            let context = native
                .context()
                .context("Private native browser context unavailable")?;
            ensure!(
                native.is_ephemeral() && context.is_ephemeral() && &context == expected,
                "Native private browser did not retain this thread's ephemeral context"
            );
        }
        #[cfg(target_os = "windows")]
        {
            use webview2_com::Microsoft::Web::WebView2::Win32::ICoreWebView2_13;
            use windows::core::{BOOL, Interface};
            use wry::WebViewExtWindows;
            let runtime = self
                .runtimes
                .get_mut(thread)
                .context("Private native browser owner missing")?;
            unsafe {
                let profile = view
                    .webview()
                    .cast::<ICoreWebView2_13>()
                    .context(
                        "Private browsing requires a runtime with native profile verification",
                    )?
                    .Profile()?;
                let mut private = BOOL::default();
                profile.IsInPrivateModeEnabled(&mut private)?;
                ensure!(
                    private.as_bool(),
                    "Native browser did not enable private mode; refusing navigation"
                );
                let mut raw = windows::core::PWSTR::null();
                profile.ProfilePath(&mut raw)?;
                let path =
                    std::path::PathBuf::from(webview2_com::CoTaskMemPWSTR::from(raw).to_string())
                        .canonicalize()
                        .context("Private native browser profile path unavailable")?;
                let root = runtime.directory.canonicalize()?;
                ensure!(
                    path.starts_with(&root) && path != root,
                    "Native private profile escaped its owned runtime"
                );
                ensure!(
                    runtime
                        .native_profile
                        .as_ref()
                        .is_none_or(|expected| expected == &path),
                    "Native private profile changed between tabs"
                );
                runtime.native_profile = Some(path);
            }
        }
        #[cfg(target_os = "macos")]
        {
            use wry::WebViewExtMacOS;
            let _ = thread;
            unsafe {
                ensure!(
                    !view
                        .webview()
                        .configuration()
                        .websiteDataStore()
                        .isPersistent(),
                    "Native browser did not create private storage"
                );
            }
        }
        Ok(())
    }
    pub(super) fn forget(&mut self, thread: &str) {
        #[cfg(target_os = "linux")]
        {
            self.contexts.remove(thread);
        }
        #[cfg(target_os = "windows")]
        {
            self.runtimes.remove(thread);
        }
        #[cfg(not(any(target_os = "linux", target_os = "windows")))]
        let _ = thread;
    }
    pub(super) fn owned_views(&self) -> usize {
        0
    }
    pub(super) fn owned_contexts(&self) -> usize {
        #[cfg(target_os = "linux")]
        {
            self.contexts.len()
        }
        #[cfg(not(target_os = "linux"))]
        {
            0
        }
    }
}
