//! Profile-bound, explicitly confirmed data deletion. Native completion is
//! acknowledged before the settings UI reports success or pages are reloaded.
use super::*;
use crate::browser_settings::{ClearDataKind, ProfileOperation};
use coincide_core::api::SharedEngine;

type Completion = std::result::Result<(), String>;
pub(super) struct PendingClear {
    thread: String,
    profile: ProfileChoice,
    kind: ClearDataKind,
    receiver: Receiver<Completion>,
    native_started: bool,
}
impl BrowserController {
    pub(crate) fn begin_data_clear(
        &mut self,
        current: &str,
        request: &ProfileRequest,
        engine: &SharedEngine,
    ) -> Result<()> {
        ensure!(
            !self.shutdown.callbacks.closed() && self.data_clear.is_none(),
            "Browsing data is already being cleared or the browser is closing"
        );
        ensure!(
            request.thread == current && request.revision == self.profiles.revision,
            "Browser profile changed; review Clear Browsing Data again"
        );
        ensure!(
            self.cookie_import_drained(),
            "Cookie import is still finishing; try clearing again shortly"
        );
        let ProfileOperation::ClearData {
            kind,
            history_revision,
        } = request.operation
        else {
            anyhow::bail!("Invalid clear request");
        };
        let profile = self.profiles.selected(current);
        let (sender, receiver) = mpsc::sync_channel(1);
        if kind.history()
            && let ProfileChoice::Persistent(id) = profile
        {
            let expected =
                history_revision.context("History is still loading; refresh it before clearing")?;
            let engine = engine.clone();
            let closed = self.shutdown.callbacks.closed.clone();
            let thread = current.to_owned();
            let worker = std::thread::Builder::new()
                .name("browser-history-clear".into())
                .spawn(move || {
                    let result = (|| -> Result<()> {
                        let deadline = Instant::now() + Duration::from_secs(2);
                        loop {
                            ensure!(
                                !closed.load(Ordering::Acquire),
                                "Browser is closing; history was not cleared"
                            );
                            match engine.try_lock() {
                                Ok(mut engine) => {
                                    ensure!(
                                        !closed.load(Ordering::Acquire),
                                        "Browser is closing; history was not cleared"
                                    );
                                    engine.clear_browser_history(&thread, id, expected)?;
                                    return Ok(());
                                }
                                Err(std::sync::TryLockError::WouldBlock)
                                    if Instant::now() < deadline =>
                                {
                                    std::thread::sleep(Duration::from_millis(5))
                                }
                                _ => anyhow::bail!("App is busy; history was not cleared"),
                            }
                        }
                    })()
                    .map_err(|error| error.to_string());
                    let _ = sender.send(result);
                })?;
            self.shutdown.track(worker);
        } else {
            let _ = sender.send(Ok(()));
        }
        self.data_clear = Some(PendingClear {
            thread: current.into(),
            profile,
            kind,
            receiver,
            native_started: false,
        });
        Ok(())
    }
    pub fn poll_data_clear(&mut self, cx: &mut App) -> Option<(String, Completion)> {
        let mut pending = self.data_clear.take()?;
        let result = match pending.receiver.try_recv() {
            Ok(result) => result,
            Err(mpsc::TryRecvError::Empty) => {
                self.data_clear = Some(pending);
                return None;
            }
            Err(mpsc::TryRecvError::Disconnected) => {
                Err("Browsing-data clearing ended without confirmation".into())
            }
        };
        if result.is_ok() && pending.kind.site_data() && !pending.native_started {
            if self.profiles.selected(&pending.thread) != pending.profile {
                return Some((
                    pending.thread,
                    Err("Browser profile changed before site data could be cleared".into()),
                ));
            }
            match self.clear_native_site_data(&pending.thread, &pending.profile, cx) {
                Ok(receiver) => {
                    pending.receiver = receiver;
                    pending.native_started = true;
                    self.data_clear = Some(pending);
                    return None;
                }
                Err(error) => return Some((pending.thread, Err(error.to_string()))),
            }
        }
        if result.is_ok() && pending.native_started && !self.shutdown.callbacks.closed() {
            let owners: Vec<_> = self
                .tabs
                .keys()
                .filter(|thread| match &pending.profile {
                    ProfileChoice::Persistent(_) => {
                        self.profiles.selected(thread) == pending.profile
                    }
                    ProfileChoice::Private => **thread == pending.thread,
                })
                .cloned()
                .collect();
            for owner in owners {
                if let Some(tabs) = self.tabs.get_mut(&owner) {
                    for tab in tabs {
                        tab.navigation.fetch_add(1, Ordering::AcqRel);
                        let _ = tab.view.read(cx).raw().reload();
                        tab.loading = true;
                    }
                }
            }
        }
        Some((pending.thread, result))
    }
    fn clear_native_site_data(
        &mut self,
        thread: &str,
        profile: &ProfileChoice,
        cx: &mut App,
    ) -> Result<Receiver<Completion>> {
        ensure!(
            !self.shutdown.callbacks.closed(),
            "Browser is closing; site data was not cleared"
        );
        let (sender, receiver) = mpsc::sync_channel(1);
        #[cfg(target_os = "macos")]
        {
            let _ = cx;
            let mtm = MainThreadMarker::new()
                .context("Browser data must be cleared on the native UI thread")?;
            let store = match profile {
                ProfileChoice::Persistent(id) if persistent_profiles_available() => unsafe {
                    WKWebsiteDataStore::dataStoreForIdentifier(
                        &objc2_foundation::NSUUID::from_bytes(*id.as_bytes()),
                        mtm,
                    )
                },
                ProfileChoice::Persistent(_) => unsafe {
                    WKWebsiteDataStore::defaultDataStore(mtm)
                },
                ProfileChoice::Private => {
                    let Some(store) = self.private_stores.get(&profile.key(thread)).cloned() else {
                        let _ = sender.send(Ok(()));
                        return Ok(receiver);
                    };
                    store
                }
            };
            let ack = self.shutdown.callbacks.begin();
            let lease = self.shutdown.callbacks.lifetimes().block();
            let callback = block2::RcBlock::new(move || {
                let _held = &lease;
                let _ = sender.try_send(Ok(()));
                ack.ack();
            });
            unsafe {
                let types = WKWebsiteDataStore::allWebsiteDataTypes(mtm);
                let date = objc2_foundation::NSDate::dateWithTimeIntervalSince1970(0.);
                store.removeDataOfTypes_modifiedSince_completionHandler(&types, &date, &callback);
            }
        }
        #[cfg(any(target_os = "windows", target_os = "linux"))]
        {
            let tab = self
                .tabs
                .iter()
                .find(|(owner, _)| match profile {
                    ProfileChoice::Persistent(_) => self.profiles.selected(owner) == *profile,
                    ProfileChoice::Private => owner.as_str() == thread,
                })
                .and_then(|(_, tabs)| tabs.first())
                .context("Open a browser tab in this profile before clearing its site data")?;
            let raw = tab.view.read(cx).raw();
            let ack = self.shutdown.callbacks.begin();
            let lease = self.shutdown.callbacks.lifetimes().block();
            #[cfg(target_os = "windows")]
            {
                use webview2_com::{
                    ClearBrowsingDataCompletedHandler,
                    Microsoft::Web::WebView2::Win32::{ICoreWebView2_13, ICoreWebView2Profile2},
                };
                use windows::core::Interface;
                use wry::WebViewExtWindows;
                let profile = unsafe {
                    raw.webview()
                        .cast::<ICoreWebView2_13>()?
                        .Profile()?
                        .cast::<ICoreWebView2Profile2>()?
                };
                let handler = ClearBrowsingDataCompletedHandler::create(Box::new(move |result| {
                    let _held = &lease;
                    let _ = sender.try_send(result.map_err(|error| error.to_string()));
                    ack.ack();
                    Ok(())
                }));
                if let Err(error) = unsafe { profile.ClearBrowsingDataAll(&handler) } {
                    ack.ack();
                    return Err(error.into());
                }
            }
            #[cfg(target_os = "linux")]
            {
                use webkit2gtk::{WebContextExt, WebViewExt, WebsiteDataManagerExtManual};
                use wry::WebViewExtUnix;
                let manager = raw
                    .webview()
                    .context()
                    .and_then(|context| context.website_data_manager())
                    .context("Browser profile data manager is unavailable")?;
                manager.clear(
                    webkit2gtk::WebsiteDataTypes::ALL,
                    gtk::glib::TimeSpan::from_seconds(0),
                    None::<&gtk::gio::Cancellable>,
                    move |result| {
                        let _held = &lease;
                        let _ = sender.try_send(result.map_err(|error| error.to_string()));
                        ack.ack();
                    },
                );
            }
        }
        Ok(receiver)
    }
}
