//! UI-thread browser owner. The portable engine queues typed requests; native
//! callbacks return bounded payloads without holding an engine mutex.
#[path = "browser_cookie_actor.rs"]
mod cookie_actor;
#[cfg(any(target_os = "macos", test))]
#[path = "browser_cookie_import.rs"]
mod cookie_import;
#[path = "browser_credentials.rs"]
mod credential_bridge;
#[path = "browser_native_history.rs"]
mod native_history;
#[path = "browser_shutdown.rs"]
mod shutdown;
pub use shutdown::BrowserShutdownStatus;
use shutdown::TrackedEvaluation;

use crate::browser_settings::{ProfileCatalog, ProfileChoice, ProfileRequest, ProfileSnapshot};
use crate::credentials::{FillJob, deliver_fill};
use anyhow::{Context, Result, ensure};
use coincide_core::browser_protocol::{
    BrowserAction, BrowserConsole, BrowserReply, BrowserRequest, CONSOLE_SCRIPT, DownloadRegistry,
    allow_native_navigation, prepare_upload_script, script_for_request,
    upload::{UploadPermit, UploadSlots, UploadWork},
    upload_probe_script, validate_url,
};
use coincide_core::credentials::{Failure, PageBinding};
use gpui_kit::{App, AppContext, Entity, Window};
use gpui_webview::WebView;
#[cfg(target_os = "macos")]
use objc2::{MainThreadMarker, rc::Retained};
#[cfg(target_os = "macos")]
use objc2_web_kit::{WKWebViewConfiguration, WKWebsiteDataStore};
use serde_json::{Value, json};
use std::{
    cell::RefCell,
    collections::{HashMap, VecDeque},
    fs,
    path::PathBuf,
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, SyncSender},
    },
    time::{Duration, Instant},
};
use uuid::Uuid;
#[cfg(target_os = "macos")]
use wry::{WebViewBuilderExtDarwin, WebViewBuilderExtMacos, WebViewExtMacOS};

struct Tab {
    id: String,
    view: Entity<WebView>,
    title: String,
    url: String,
    loading: bool,
    console: Rc<RefCell<BrowserConsole>>,
    credential_console_suppressed: Arc<AtomicBool>,
    navigation: Arc<AtomicU64>,
    /// Linux Wry queues scripts before the first commit and drops their
    /// callbacks, so tracked evaluations wait for that commit.
    scripts_ready: Arc<AtomicBool>,
}
impl Tab {
    fn ensure_scripts_ready(&self) -> Result<()> {
        ensure!(
            self.scripts_ready.load(Ordering::Acquire),
            "The page has not started loading yet; use wait-for before inspecting it"
        );
        Ok(())
    }
}
struct PendingWait {
    request: BrowserRequest,
    tab: String,
    started: Instant,
    deadline: Instant,
    next_probe: Instant,
    in_flight: bool,
}
struct PendingUpload {
    request: BrowserRequest,
    tab: String,
    ticket: String,
    epoch: u64,
    work: UploadWork,
    permit: Option<UploadPermit>,
    prepared: Option<Receiver<std::result::Result<String, String>>>,
}
impl Drop for PendingUpload {
    fn drop(&mut self) {
        self.work.cancel();
    }
}
enum NativeEvent {
    DownloadsChanged,
    UploadProbe {
        id: String,
        ticket: String,
        result: Value,
    },
    Reply(BrowserReply),
    WaitReply {
        id: String,
        thread: String,
        tab: String,
        /// The probed document was replaced before it answered.
        stale: bool,
        result: Value,
    },
    Title {
        thread: String,
        tab: String,
        title: String,
    },
    Load {
        thread: String,
        tab: String,
        url: String,
        loading: bool,
    },
    Popup {
        thread: String,
        url: String,
    },
}

pub struct BrowserController {
    tabs: HashMap<String, Vec<Tab>>,
    active: HashMap<String, String>,
    visible: Option<String>,
    replies: VecDeque<BrowserReply>,
    events: Receiver<NativeEvent>,
    sender: SyncSender<NativeEvent>,
    contexts: HashMap<String, wry::WebContext>,
    profiles: ProfileCatalog,
    #[cfg(target_os = "macos")]
    cookie_actor: Option<cookie_actor::Actor>,
    #[cfg(target_os = "macos")]
    private_stores: HashMap<String, Retained<WKWebsiteDataStore>>,
    downloads: Rc<RefCell<DownloadRegistry>>,
    waits: HashMap<String, PendingWait>,
    uploads: HashMap<String, PendingUpload>,
    upload_slots: UploadSlots,
    shutdown: shutdown::Shutdown,
}

impl BrowserController {
    pub fn new(profile_dir: PathBuf) -> Result<Self> {
        #[cfg(target_os = "linux")]
        gtk::init().context("Initialize GTK for the native browser")?;
        fs::create_dir_all(&profile_dir)?;
        ensure!(
            !fs::symlink_metadata(&profile_dir)?.file_type().is_symlink(),
            "Browser profile directory cannot be a symlink"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&profile_dir, fs::Permissions::from_mode(0o700))?;
        }
        #[cfg(target_os = "macos")]
        let profile_id = {
            let path = profile_dir.join("profile-id");
            if path.exists() {
                ensure!(
                    !fs::symlink_metadata(&path)?.file_type().is_symlink(),
                    "Browser profile ID cannot be a symlink"
                );
                *Uuid::parse_str(fs::read_to_string(path)?.trim())?.as_bytes()
            } else {
                let id = Uuid::new_v4();
                use std::io::Write;
                use std::os::unix::fs::OpenOptionsExt;
                let mut file = fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(path)?;
                file.write_all(id.to_string().as_bytes())?;
                file.sync_all()?;
                *id.as_bytes()
            }
        };
        #[cfg(target_os = "macos")]
        let default_id = Some(Uuid::from_bytes(profile_id));
        #[cfg(not(target_os = "macos"))]
        let default_id = None;
        let profiles = ProfileCatalog::open(profile_dir.clone(), default_id)?;
        let (sender, events) = mpsc::sync_channel(512);
        Ok(Self {
            tabs: HashMap::new(),
            active: HashMap::new(),
            visible: None,
            replies: VecDeque::new(),
            events,
            sender,
            contexts: HashMap::new(),
            profiles,
            #[cfg(target_os = "macos")]
            cookie_actor: None,
            #[cfg(target_os = "macos")]
            private_stores: HashMap::new(),
            downloads: Rc::new(RefCell::new(DownloadRegistry::new(
                profile_dir.join("downloads"),
            )?)),
            waits: HashMap::new(),
            uploads: HashMap::new(),
            upload_slots: UploadSlots::default(),
            shutdown: shutdown::Shutdown::default(),
        })
    }

    /// Revoke access and close admission; keep native owners alive for real callbacks.
    pub fn request_shutdown(&mut self, cx: &mut App) {
        if self.shutdown.callbacks.closed() {
            return;
        }
        self.shutdown.close();
        #[cfg(target_os = "macos")]
        if let Some(actor) = self.cookie_actor.as_mut() {
            actor.stop();
        }
        for tabs in self.tabs.values() {
            for tab in tabs {
                tab.navigation.fetch_add(1, Ordering::AcqRel);
                tab.credential_console_suppressed
                    .store(true, Ordering::Release);
                let _ = tab.console.borrow_mut().read(true);
            }
        }
        self.set_thread_visible(None, cx);
        for upload in self.uploads.values() {
            upload.work.cancel();
        }
        self.uploads.clear();
        self.waits.clear();
        self.replies.clear();
        for _ in self.events.try_iter() {}
    }
    /// Native release is deliberately unconfirmed; no file/profile deletion or
    /// semantic cancellation is used as completion evidence.
    pub fn poll_shutdown(&mut self) -> BrowserShutdownStatus {
        self.poll_cookie_import();
        let downloads_pending = self
            .tabs
            .keys()
            .map(|thread| {
                let list = self.downloads.borrow().list(thread, None);
                list["downloads"].as_array().map_or(0, |rows| {
                    rows.iter()
                        .filter(|row| {
                            matches!(row["state"].as_str(), Some("downloading" | "unconfirmed"))
                        })
                        .count()
                })
            })
            .sum();
        let views = self.tabs.values().map(Vec::len).sum();
        self.shutdown
            .status(downloads_pending, views, self.contexts.len())
    }
    pub fn execute(&mut self, request: BrowserRequest, window: &mut Window, cx: &mut App) {
        if self.shutdown.callbacks.closed() {
            return;
        }
        let id = request.id.clone();
        let thread_id = request.thread_id.clone();
        match self.handle(request, window, cx) {
            Ok(Some(result)) => self.replies.push_back(BrowserReply {
                id,
                thread_id,
                result,
            }),
            Ok(None) => {} // An evaluate-script callback will produce the reply.
            Err(error) => self.replies.push_back(BrowserReply {
                id,
                thread_id,
                result: json!({"error":error.to_string()}),
            }),
        }
    }

    fn handle(
        &mut self,
        request: BrowserRequest,
        window: &mut Window,
        cx: &mut App,
    ) -> Result<Option<Value>> {
        ensure!(
            !self.shutdown.callbacks.closed(),
            "Browser is shutting down"
        );
        request.validate()?;
        let thread = &request.thread_id;
        match &request.action {
            BrowserAction::Tabs => return Ok(Some(self.tab_list(thread))),
            BrowserAction::Downloads => {
                // No tab means all of this thread's retained downloads, including
                // closed tabs. Explicit tab filtering never crosses thread ownership.
                let mut result = self.downloads.borrow().list(thread, request.tab.as_deref());
                if cfg!(target_os = "linux") {
                    result["acceptingDownloads"] = json!(false);
                    result["platformLimitation"] = json!(
                        "Native downloads are disabled on Linux: this Wry version cannot safely attribute downloads to tabs sharing a browser profile."
                    );
                }
                return Ok(Some(result));
            }
            BrowserAction::NewTab { url } => {
                let id =
                    self.create_tab(thread, url.as_deref().unwrap_or("about:blank"), window, cx)?;
                return Ok(Some(json!({"tab":id,"tabs":self.tab_list(thread)})));
            }
            BrowserAction::Show => {
                if self.tabs.get(thread).is_none_or(Vec::is_empty) {
                    self.create_tab(thread, "about:blank", window, cx)?;
                }
                self.set_thread_visible(Some(thread), cx);
                return Ok(Some(json!({"visible":true})));
            }
            BrowserAction::Hide => {
                if self.visible.as_deref() == Some(thread) {
                    self.set_thread_visible(None, cx);
                }
                return Ok(Some(json!({"visible":false})));
            }
            _ => {}
        }
        if self.tabs.get(thread).is_none_or(Vec::is_empty) {
            ensure!(request.tab.is_none(), "No such tab in this thread");
            self.create_tab(thread, "about:blank", window, cx)?;
        }
        let target = request
            .tab
            .clone()
            .or_else(|| self.active.get(thread).cloned())
            .context("No active browser tab")?;
        let index = self
            .tabs
            .get(thread)
            .and_then(|tabs| tabs.iter().position(|tab| tab.id == target))
            .context("No such tab in this thread")?;
        ensure!(
            !self.tabs[thread][index]
                .credential_console_suppressed
                .load(Ordering::Acquire)
                || private_document_action_allowed(&request.action),
            "Page inspection is paused during a saved-login request. Navigate or reload before inspecting this document again."
        );
        match &request.action {
            BrowserAction::Back | BrowserAction::Forward | BrowserAction::Reload => {
                let action = native_history::Action::from_request(&request.action)
                    .context("Unsupported native history action")?;
                let tab = &mut self.tabs.get_mut(thread).context("No such thread")?[index];
                let navigation = tab.navigation.clone();
                let epoch = navigation.load(Ordering::Acquire);
                let callbacks = &self.shutdown.callbacks;
                let mut result =
                    native_history::dispatch(tab.view.read(cx).raw(), action, callbacks, || {
                        ensure!(!callbacks.closed(), "Browser is shutting down");
                        ensure!(
                            navigation.load(Ordering::Acquire) == epoch,
                            "Document changed before native history dispatch"
                        );
                        // Invalidate old document grants immediately before the one
                        // native SDK dispatch, including an uncertain SDK error.
                        navigation.fetch_add(1, Ordering::AcqRel);
                        Ok(())
                    })?;
                if result["dispatched"] == true {
                    tab.loading = true;
                }
                result["tab"] = json!(target);
                Ok(Some(result))
            }
            BrowserAction::Upload { .. } => {
                ensure!(
                    !cfg!(windows),
                    "Browser uploads are disabled on Windows until safe reparse-point handling is implemented"
                );
                ensure!(
                    !self.uploads.contains_key(&request.id),
                    "Upload operation already active"
                );
                ensure!(
                    !self.uploads.values().any(|upload| upload.tab == target),
                    "An upload is already active in this tab"
                );
                ensure!(
                    self.uploads.len() < 2,
                    "At most two upload requests may be pending"
                );
                let permit = self.upload_slots.reserve()?;
                let ticket = Uuid::new_v4().to_string();
                let source = upload_probe_script(&request, &ticket)?;
                let tab = &self.tabs[thread][index];
                ensure!(
                    !tab.loading,
                    "Wait for navigation to finish before uploading"
                );
                tab.ensure_scripts_ready()?;
                let epoch = tab.navigation.load(Ordering::Acquire);
                let sender = self.sender.clone();
                let id = request.id.clone();
                let probe_ticket = ticket.clone();
                let protected = tab.credential_console_suppressed.clone();
                let navigation = tab.navigation.clone();
                tab.view.read(cx).raw().evaluate_script_tracked(
                    &source,
                    &self.shutdown.callbacks,
                    move |payload| {
                        let _ = sender.try_send(NativeEvent::UploadProbe {
                            id: id.clone(),
                            ticket: probe_ticket.clone(),
                            result: public_script_reply(
                                &payload,
                                navigation.load(Ordering::Acquire) == epoch,
                                protected.load(Ordering::Acquire),
                                false,
                            ),
                        });
                    },
                )?;
                self.uploads.insert(
                    request.id.clone(),
                    PendingUpload {
                        request,
                        tab: target,
                        ticket,
                        epoch,
                        work: UploadWork::new(Duration::from_secs(10)),
                        permit: Some(permit),
                        prepared: None,
                    },
                );
                Ok(None)
            }
            BrowserAction::Console { clear } => {
                let tab = &self.tabs[thread][index];
                let mut result = tab.console.borrow_mut().read(*clear);
                result["credentialCaptureSuppressed"] =
                    json!(tab.credential_console_suppressed.load(Ordering::Acquire));
                Ok(Some(result))
            }
            BrowserAction::WaitFor { timeout, .. } => {
                ensure!(
                    self.waits.len() < 32,
                    "At most 32 browser waits may be active"
                );
                let now = Instant::now();
                self.waits.insert(
                    request.id.clone(),
                    PendingWait {
                        tab: target,
                        started: now,
                        deadline: now + Duration::from_secs(*timeout),
                        next_probe: now,
                        in_flight: false,
                        request,
                    },
                );
                Ok(None)
            }
            BrowserAction::SelectTab => {
                self.active.insert(thread.clone(), target);
                if self.visible.as_deref() == Some(thread) {
                    self.set_thread_visible(Some(thread), cx);
                }
                Ok(Some(self.tab_list(thread)))
            }
            BrowserAction::CloseTab => {
                self.downloads.borrow_mut().tab_closed(thread, &target);
                let tabs = self.tabs.get_mut(thread).context("No such thread")?;
                let removed = tabs.remove(index);
                removed.navigation.fetch_add(1, Ordering::AcqRel);
                removed.view.update(cx, |view, _| view.hide());
                if self.active.get(thread) == Some(&target) {
                    if let Some(tab) = tabs.last() {
                        self.active.insert(thread.clone(), tab.id.clone());
                    } else {
                        self.active.remove(thread);
                    }
                }
                if self.visible.as_deref() == Some(thread) {
                    self.set_thread_visible(Some(thread), cx);
                }
                Ok(Some(self.tab_list(thread)))
            }
            BrowserAction::Navigate { url } => {
                let tab = &mut self.tabs.get_mut(thread).context("No such thread")?[index];
                tab.navigation.fetch_add(1, Ordering::AcqRel);
                tab.view.read(cx).raw().load_url(url)?;
                tab.url = url.clone();
                tab.loading = true;
                Ok(Some(json!({"tab":target,"url":url,"loading":true})))
            }
            _ => {
                self.tabs[thread][index].ensure_scripts_ready()?;
                let source = script_for_request(&request)?.context("Unsupported browser action")?;
                let sender = self.sender.clone();
                let id = request.id.clone();
                let thread_id = request.thread_id.clone();
                let protected = self.tabs[thread][index]
                    .credential_console_suppressed
                    .clone();
                let navigation = self.tabs[thread][index].navigation.clone();
                let epoch = navigation.load(Ordering::Acquire);
                let click = matches!(&request.action, BrowserAction::Click { .. });
                self.tabs[thread][index]
                    .view
                    .read(cx)
                    .raw()
                    .evaluate_script_tracked(&source, &self.shutdown.callbacks, move |payload| {
                        let result = public_script_reply(
                            &payload,
                            navigation.load(Ordering::Acquire) == epoch,
                            protected.load(Ordering::Acquire),
                            click,
                        );
                        let _ = sender.try_send(NativeEvent::Reply(BrowserReply {
                            id: id.clone(),
                            thread_id: thread_id.clone(),
                            result,
                        }));
                    })?;
                Ok(None)
            }
        }
    }

    fn create_tab(
        &mut self,
        thread: &str,
        url: &str,
        window: &mut Window,
        cx: &mut App,
    ) -> Result<String> {
        ensure!(
            !self.shutdown.callbacks.closed(),
            "Browser is shutting down"
        );
        ensure!(
            self.tabs.values().map(Vec::len).sum::<usize>() < 128,
            "Browser has reached its 128-tab limit"
        );
        ensure!(
            self.tabs.get(thread).map_or(0, Vec::len) < 20,
            "This thread already has 20 tabs"
        );
        let id = Uuid::new_v4().to_string();
        let title_sender = self.sender.clone();
        let title_thread = thread.to_owned();
        let title_id = id.clone();
        let load_sender = self.sender.clone();
        let load_thread = thread.to_owned();
        let load_id = id.clone();
        let popup_sender = self.sender.clone();
        let popup_thread = thread.to_owned();
        let start_downloads = self.downloads.clone();
        let start_thread = thread.to_owned();
        let start_tab = id.clone();
        let start_sender = self.sender.clone();
        let completed_downloads = self.downloads.clone();
        let completed_thread = thread.to_owned();
        let completed_tab = id.clone();
        let completed_sender = self.sender.clone();
        let console = Rc::new(RefCell::new(BrowserConsole::default()));
        let console_handler = console.clone();
        let credential_console_suppressed = Arc::new(AtomicBool::new(false));
        let console_suppressed = credential_console_suppressed.clone();
        let title_suppressed = credential_console_suppressed.clone();
        let popup_suppressed = credential_console_suppressed.clone();
        let download_suppressed = credential_console_suppressed.clone();
        let load_console_suppressed = credential_console_suppressed.clone();
        let load_console = console.clone();
        let navigation = Arc::new(AtomicU64::new(0));
        let scripts_ready = Arc::new(AtomicBool::new(!cfg!(target_os = "linux")));
        let navigation_handler = navigation.clone();
        let navigation_closed = self.shutdown.callbacks.closed.clone();
        let download_closed = self.shutdown.callbacks.closed.clone();
        let load_navigation = navigation.clone();
        let load_closed = self.shutdown.callbacks.closed.clone();
        let profile = self.profiles.selected(thread);
        let profile_key = profile.key(thread);
        if let ProfileChoice::Persistent(id) = &profile {
            ensure!(
                persistent_profiles_available()
                    || self
                        .profiles
                        .profiles
                        .iter()
                        .any(|p| p.id == *id && p.is_default),
                "Multiple persistent profiles require a native named-store backend (macOS 14 or later)"
            );
        }
        if !self.contexts.contains_key(&profile_key) {
            let directory = self.profiles.storage_directory(&profile)?;
            self.contexts
                .insert(profile_key.clone(), wry::WebContext::new(directory));
        }
        let context = self
            .contexts
            .get_mut(&profile_key)
            .context("Browser profile context unavailable")?;
        let builder = wry::WebViewBuilder::new_with_web_context(context)
            .with_incognito(matches!(profile, ProfileChoice::Private))
            .with_url(url)
            .with_devtools(false)
            .with_autoplay(false)
            .with_clipboard(false)
            .with_initialization_script_for_main_only(CONSOLE_SCRIPT, false)
            .with_ipc_handler(move |message| {
                if console_suppressed.load(Ordering::Acquire) {
                    return;
                }
                console_handler
                    .borrow_mut()
                    .receive(message.body(), &message.uri().to_string());
            })
            .with_navigation_handler(move |url| {
                let allowed =
                    !navigation_closed.load(Ordering::Acquire) && allow_native_navigation(&url);
                if allowed {
                    navigation_handler.fetch_add(1, Ordering::AcqRel);
                }
                allowed
            })
            .with_download_started_handler(move |url, destination| {
                // Wry 0.53 registers GTK callbacks on the shared context without
                // matching the source webview. Fail closed until that is fixed.
                if cfg!(target_os = "linux")
                    || download_closed.load(Ordering::Acquire)
                    || download_suppressed.load(Ordering::Acquire)
                {
                    return false;
                }
                let result = start_downloads.borrow_mut().start(
                    &start_thread,
                    &start_tab,
                    &url,
                    destination,
                );
                let _ = start_sender.try_send(NativeEvent::DownloadsChanged);
                match result {
                    Ok(path) => {
                        *destination = path;
                        true
                    }
                    Err(_) => false,
                }
            })
            .with_download_completed_handler(move |url, path, success| {
                if cfg!(target_os = "linux") {
                    return;
                }
                completed_downloads.borrow_mut().complete(
                    &completed_thread,
                    &completed_tab,
                    &url,
                    path.as_deref(),
                    success,
                );
                let _ = completed_sender.try_send(NativeEvent::DownloadsChanged);
            })
            .with_document_title_changed_handler(move |title| {
                if title_suppressed.load(Ordering::Acquire) {
                    return;
                }
                let _ = title_sender.try_send(NativeEvent::Title {
                    thread: title_thread.clone(),
                    tab: title_id.clone(),
                    title,
                });
            })
            .with_on_page_load_handler(move |event, url| {
                if load_closed.load(Ordering::Acquire) {
                    return;
                }
                if matches!(event, wry::PageLoadEvent::Started) {
                    load_navigation.fetch_add(1, Ordering::AcqRel);
                } else if load_console_suppressed.swap(false, Ordering::AcqRel) {
                    // Keep old-document messages out while navigation is in
                    // flight. Start the new committed page with an empty log.
                    let _ = load_console.borrow_mut().read(true);
                }
                let _ = load_sender.try_send(NativeEvent::Load {
                    thread: load_thread.clone(),
                    tab: load_id.clone(),
                    url,
                    loading: matches!(event, wry::PageLoadEvent::Started),
                });
            })
            .with_new_window_req_handler(move |url, _| {
                if !popup_suppressed.load(Ordering::Acquire) && validate_url(&url).is_ok() {
                    let _ = popup_sender.try_send(NativeEvent::Popup {
                        thread: popup_thread.clone(),
                        url,
                    });
                }
                wry::NewWindowResponse::Deny
            });
        #[cfg(target_os = "macos")]
        let builder = match &profile {
            ProfileChoice::Persistent(id) => builder.with_data_store_identifier(*id.as_bytes()),
            ProfileChoice::Private => {
                let mtm = MainThreadMarker::new()
                    .context("Private browser store requires the native UI thread")?;
                // Wry's ordinary incognito option creates a separate store per
                // view. Retain one native ephemeral store for this thread.
                let store = self
                    .private_stores
                    .entry(profile_key.clone())
                    .or_insert_with(|| unsafe { WKWebsiteDataStore::nonPersistentDataStore(mtm) });
                let configuration = unsafe { WKWebViewConfiguration::new(mtm) };
                unsafe {
                    configuration.setWebsiteDataStore(store);
                }
                builder.with_webview_configuration(configuration)
            }
        };
        let view = WebView::build(builder, window, cx)?;
        #[cfg(target_os = "linux")]
        {
            use webkit2gtk::{LoadEvent, WebViewExt};
            use wry::WebViewExtUnix;
            // Connected after Wry's own handler, which flushes its pre-commit
            // queue first; later evaluations deliver their callbacks.
            let ready = scripts_ready.clone();
            view.raw().webview().connect_load_changed(move |_, event| {
                if matches!(event, LoadEvent::Committed) {
                    ready.store(true, Ordering::Release);
                }
            });
        }
        let view = cx.new(|_| view);
        self.tabs.entry(thread.into()).or_default().push(Tab {
            id: id.clone(),
            view,
            title: "New tab".into(),
            url: url.into(),
            loading: url != "about:blank",
            console,
            credential_console_suppressed,
            navigation,
            scripts_ready,
        });
        self.shutdown.ever_native = true;
        self.active.insert(thread.into(), id.clone());
        // New background tabs must not steal another thread's browser pane.
        let visible = self.visible.clone();
        self.set_thread_visible(visible.as_deref(), cx);
        Ok(id)
    }

    pub fn poll(&mut self, window: &mut Window, cx: &mut App) -> bool {
        if self.shutdown.callbacks.closed() {
            let discarded = self.events.try_iter().take(512).count();
            self.replies.clear();
            return discarded > 0;
        }
        let events = self.events.try_iter().take(512).collect::<Vec<_>>();
        let mut changed = !events.is_empty();
        for event in events {
            match event {
                NativeEvent::DownloadsChanged => {}
                NativeEvent::UploadProbe { id, ticket, result } => {
                    if let Some(upload) = self.uploads.get_mut(&id) {
                        if upload.ticket != ticket {
                            continue;
                        }
                        let current = self
                            .tabs
                            .get(&upload.request.thread_id)
                            .and_then(|tabs| tabs.iter().find(|tab| tab.id == upload.tab))
                            .is_some_and(|tab| {
                                tab.navigation.load(Ordering::Acquire) == upload.epoch
                            });
                        if !current {
                            upload.work.cancel();
                        }
                        if result["ready"] == true && upload.work.check().is_ok() {
                            if let Some(permit) = upload.permit.take() {
                                let (sender, receiver) = mpsc::sync_channel(1);
                                upload.prepared = Some(receiver);
                                let request = upload.request.clone();
                                let ticket = upload.ticket.clone();
                                let work = upload.work.clone();
                                let worker = std::thread::spawn(move || {
                                    let _permit = permit;
                                    let result = prepare_upload_script(&request, &ticket, &work)
                                        .map_err(|e| e.to_string());
                                    let _ = sender.try_send(result);
                                });
                                self.shutdown.track(worker);
                            }
                        } else {
                            let upload = self.uploads.remove(&id).expect("existing upload");
                            self.replies.push_back(BrowserReply { id: upload.request.id.clone(), thread_id: upload.request.thread_id.clone(),
                                result: json!({"error":result["error"].as_str().unwrap_or("Upload document probe failed")}) });
                        }
                    }
                }
                NativeEvent::Reply(reply) => self.replies.push_back(reply),
                NativeEvent::WaitReply {
                    id,
                    thread,
                    tab,
                    stale,
                    result,
                } => {
                    if let Some(wait) = self.waits.get_mut(&id) {
                        if wait.request.thread_id != thread || wait.tab != tab {
                            continue;
                        }
                        wait.in_flight = false;
                        if Instant::now() >= wait.deadline {
                            let wait = self.waits.remove(&id).expect("existing wait");
                            self.finish_wait(wait, json!({"found":false,"error":"Timed out waiting for the browser condition"}));
                        } else if stale {
                            // Like Swift, a wait spans navigation: a replaced
                            // document's answer is no evidence, so probe the new one.
                            wait.next_probe = Instant::now();
                        } else if result.get("error").is_some() || result["found"] == true {
                            let wait = self.waits.remove(&id).expect("existing wait");
                            self.finish_wait(wait, result);
                        } else {
                            wait.next_probe = Instant::now() + Duration::from_millis(250);
                        }
                    }
                }
                NativeEvent::Title { thread, tab, title } => {
                    if let Some(tab) = self
                        .tabs
                        .get_mut(&thread)
                        .and_then(|tabs| tabs.iter_mut().find(|t| t.id == tab))
                        && !tab.credential_console_suppressed.load(Ordering::Acquire)
                    {
                        tab.title = title;
                    }
                }
                NativeEvent::Load {
                    thread,
                    tab,
                    url,
                    loading,
                } => {
                    if let Some(tab) = self
                        .tabs
                        .get_mut(&thread)
                        .and_then(|tabs| tabs.iter_mut().find(|t| t.id == tab))
                    {
                        tab.url = url;
                        tab.loading = loading;
                    }
                }
                NativeEvent::Popup { thread, url } => {
                    let _ = self.create_tab(&thread, &url, window, cx);
                }
            }
        }
        changed |= self.poll_uploads(cx);
        changed |= self.poll_waits(cx);
        changed
    }

    fn poll_uploads(&mut self, cx: &App) -> bool {
        let mut changed = false;
        for (id, upload) in std::mem::take(&mut self.uploads) {
            let tab = self
                .tabs
                .get(&upload.request.thread_id)
                .and_then(|tabs| tabs.iter().find(|tab| tab.id == upload.tab));
            let status = upload.work.check().and_then(|_| {
                let tab = tab.context("Upload tab closed")?;
                ensure!(
                    tab.navigation.load(Ordering::Acquire) == upload.epoch
                        && !tab.credential_console_suppressed.load(Ordering::Acquire),
                    "Upload cancelled because document access changed"
                );
                Ok(())
            });
            let prepared = upload.prepared.as_ref().map(|receiver| receiver.try_recv());
            let outcome = match (status, prepared) {
                (Err(error), _) => Some(Err(error.to_string())),
                (Ok(()), Some(Ok(result))) => Some(result),
                (Ok(()), Some(Err(mpsc::TryRecvError::Disconnected))) => {
                    Some(Err("Upload worker stopped".into()))
                }
                _ => None,
            };
            if let Some(outcome) = outcome {
                changed = true;
                let result = outcome.and_then(|source| {
                    let sender = self.sender.clone();
                    let id = id.clone();
                    let thread_id = upload.request.thread_id.clone();
                    let tab = tab.expect("checked tab");
                    let protected = tab.credential_console_suppressed.clone();
                    let navigation = tab.navigation.clone();
                    let epoch = upload.epoch;
                    tab.view
                        .read(cx)
                        .raw()
                        .evaluate_script_tracked(
                            &source,
                            &self.shutdown.callbacks,
                            move |payload| {
                                let _ = sender.try_send(NativeEvent::Reply(BrowserReply {
                                    id: id.clone(),
                                    thread_id: thread_id.clone(),
                                    result: public_script_reply(
                                        &payload,
                                        navigation.load(Ordering::Acquire) == epoch,
                                        protected.load(Ordering::Acquire),
                                        false,
                                    ),
                                }));
                            },
                        )
                        .map_err(|e| e.to_string())
                });
                if let Err(error) = result {
                    self.replies.push_back(BrowserReply {
                        id,
                        thread_id: upload.request.thread_id.clone(),
                        result: json!({"error":error}),
                    });
                }
            } else {
                self.uploads.insert(id, upload);
            }
        }
        changed
    }

    fn finish_wait(&mut self, wait: PendingWait, mut result: Value) {
        if let Some(object) = result.as_object_mut() {
            object.insert(
                "waited".into(),
                json!((wait.started.elapsed().as_secs_f64() * 10.0).round() / 10.0),
            );
            object.insert("tab".into(), json!(wait.tab));
        }
        self.replies.push_back(BrowserReply {
            id: wait.request.id,
            thread_id: wait.request.thread_id,
            result,
        });
    }

    fn poll_waits(&mut self, cx: &App) -> bool {
        let mut changed = false;
        for (id, mut wait) in std::mem::take(&mut self.waits) {
            let now = Instant::now();
            if now >= wait.deadline {
                self.finish_wait(
                    wait,
                    json!({"found":false,"error":"Timed out waiting for the browser condition"}),
                );
                changed = true;
                continue;
            }
            let tab = self
                .tabs
                .get(&wait.request.thread_id)
                .and_then(|tabs| tabs.iter().find(|tab| tab.id == wait.tab));
            let Some(tab) = tab else {
                self.finish_wait(
                    wait,
                    json!({"found":false,"error":"Browser tab closed while waiting"}),
                );
                changed = true;
                continue;
            };
            if !wait.in_flight
                && now >= wait.next_probe
                && tab.scripts_ready.load(Ordering::Acquire)
            {
                let source = script_for_request(&wait.request)
                    .and_then(|script| script.context("Unsupported wait operation"));
                let result = source.and_then(|source| {
                    let sender = self.sender.clone();
                    let id = id.clone();
                    let thread = wait.request.thread_id.clone();
                    let tab_id = wait.tab.clone();
                    let protected = tab.credential_console_suppressed.clone();
                    let navigation = tab.navigation.clone();
                    let epoch = navigation.load(Ordering::Acquire);
                    tab.view
                        .read(cx)
                        .raw()
                        .evaluate_script_tracked(
                            &source,
                            &self.shutdown.callbacks,
                            move |payload| {
                                let same = navigation.load(Ordering::Acquire) == epoch;
                                let _ = sender.try_send(NativeEvent::WaitReply {
                                    id: id.clone(),
                                    thread: thread.clone(),
                                    tab: tab_id.clone(),
                                    stale: !same,
                                    result: public_script_reply(
                                        &payload,
                                        same,
                                        protected.load(Ordering::Acquire),
                                        false,
                                    ),
                                });
                            },
                        )
                        .map_err(Into::into)
                });
                if let Err(error) = result {
                    self.finish_wait(wait, json!({"error":error.to_string()}));
                    changed = true;
                    continue;
                }
                wait.in_flight = true;
            }
            self.waits.insert(id, wait);
        }
        changed
    }
    /// Native settings only: metadata contains no page/credential contents.
    pub fn profile_snapshot(&self, thread: &str) -> ProfileSnapshot {
        let mut snapshot = self
            .profiles
            .snapshot(thread, self.tabs.get(thread).map_or(0, Vec::len));
        snapshot.persistent_profiles_available = persistent_profiles_available();
        snapshot
    }
    pub(crate) fn history_binding(
        &self,
        thread: &str,
    ) -> crate::browser_settings::history_flow::Binding {
        crate::browser_settings::history_flow::Binding {
            snapshot: self.profile_snapshot(thread),
            active: self.active.get(thread).cloned(),
            tabs: self
                .tabs
                .get(thread)
                .into_iter()
                .flatten()
                .map(|tab| (tab.id.clone(), tab.navigation.load(Ordering::Acquire)))
                .collect(),
        }
    }
    /// One explicit native Open after off-UI saved-row resolution. There is no
    /// queued gap in which a profile or tab can change before creating the tab.
    pub(crate) fn open_saved_history(
        &mut self,
        binding: &crate::browser_settings::history_flow::Binding,
        open: coincide_core::api::AdmittedHistoryOpen,
        window: &mut Window,
        cx: &mut App,
    ) -> Result<()> {
        let (thread, profile, url) = open.into_parts();
        ensure!(
            !self.shutdown.callbacks.closed(),
            "Browser is shutting down"
        );
        binding.require_destination(&self.history_binding(&thread), &thread, profile)?;
        coincide_core::browser_bookmarks::validate_url(&url)?;
        self.create_tab(&thread, &url, window, cx)?;
        self.set_thread_visible(Some(&thread), cx);
        Ok(())
    }
    /// Apply only requests from the parent's CURRENT selected thread. Never
    /// close tabs implicitly or attach a Swift/imported website store.
    pub fn apply_profile_request(
        &mut self,
        current_thread: &str,
        request: ProfileRequest,
    ) -> Result<()> {
        ensure!(
            !self.shutdown.callbacks.closed(),
            "Browser is shutting down"
        );
        #[cfg(target_os = "macos")]
        if let Some(actor) = self.cookie_actor.as_mut() {
            actor.stop();
        }
        if let crate::browser_settings::ProfileOperation::Select(ProfileChoice::Persistent(id)) =
            &request.operation
        {
            ensure!(
                persistent_profiles_available()
                    || self
                        .profiles
                        .profiles
                        .iter()
                        .any(|p| p.id == *id && p.is_default),
                "Multiple persistent profiles require macOS 14 or later"
            );
        }
        let old = self.profiles.selected(current_thread);
        let switching = matches!(
            &request.operation,
            crate::browser_settings::ProfileOperation::Select(_)
        );
        self.profiles.apply(
            current_thread,
            request,
            self.tabs.get(current_thread).map_or(0, Vec::len),
        )?;
        if switching && old == ProfileChoice::Private {
            self.contexts.remove(&old.key(current_thread));
            #[cfg(target_os = "macos")]
            self.private_stores.remove(&old.key(current_thread));
        }
        Ok(())
    }

    /// Native parent hook only. Do not register this capability as an agent action.
    pub fn credential_fill_available(&self) -> bool {
        !self.shutdown.callbacks.closed() && credential_bridge::credential_fill_available()
    }

    /// Metadata for the selected tab of the native parent's selected thread.
    /// Native URL access avoids trusting a JavaScript location/IPC response.
    pub fn credential_page(&self, thread: &str, cx: &App) -> Option<PageBinding> {
        if self.shutdown.callbacks.closed() {
            return None;
        }
        let id = self.active.get(thread)?;
        let tab = self.tabs.get(thread)?.iter().find(|tab| &tab.id == id)?;
        if tab.loading {
            return None;
        }
        let epoch = tab.navigation.load(Ordering::Acquire);
        let address = credential_native_address(tab.view.read(cx).raw());
        credential_binding(
            &tab.id,
            epoch,
            tab.navigation.load(Ordering::Acquire),
            address.as_deref(),
        )
    }

    /// Drain only the selected thread's native workflow receiver. Never return
    /// FillJob or completion errors through BrowserReply or console machinery.
    pub fn drain_credential_fills(
        &mut self,
        thread: &str,
        jobs: &Receiver<FillJob>,
        cx: &App,
    ) -> bool {
        if self.shutdown.callbacks.closed() {
            return jobs.try_iter().take(2).count() > 0;
        }
        let mut changed = false;
        for job in jobs.try_iter().take(2) {
            if let Some(active) = self.active.get(thread).cloned() {
                let pending: Vec<_> = self
                    .waits
                    .iter()
                    .filter(|(_, wait)| wait.request.thread_id == thread && wait.tab == active)
                    .map(|(id, _)| id.clone())
                    .collect();
                for id in pending {
                    if let Some(wait) = self.waits.remove(&id) {
                        self.finish_wait(wait, json!({"error":"Browser wait cancelled by a native saved-login request"}));
                    }
                }
            }
            let target = self.active.get(thread).and_then(|id| {
                let tab = self.tabs.get(thread)?.iter().find(|tab| &tab.id == id)?;
                if tab.loading {
                    return None;
                }
                // A native approved job may trigger site input handlers that
                // log its fields. Clear and suppress page console capture
                // before any private renderer work, until the next navigation.
                tab.credential_console_suppressed
                    .store(true, Ordering::Release);
                let _ = tab.console.borrow_mut().read(true);
                credential_bridge::NativeCredentialTarget::new(
                    tab.view.read(cx).raw(),
                    tab.navigation.clone(),
                )
                .map(|target| target.with_lifetimes(self.shutdown.callbacks.lifetimes()))
            });
            let mut sink = credential_bridge::BrowserCredentialSink::new(|tab: &str| {
                self.credential_page(thread, cx)
                    .filter(|page| page.tab == tab)
                    .ok_or(Failure::StalePage)
            })
            .with_target(target)
            .with_completion_tracker({
                let callbacks = self.shutdown.callbacks.clone();
                move || {
                    let ack = callbacks.begin();
                    Box::new(move || ack.ack())
                }
            });
            deliver_fill(job, &mut sink);
            changed = true;
        }
        changed
    }

    pub fn drain_replies(&mut self) -> Vec<BrowserReply> {
        self.replies.drain(..).collect()
    }
    pub fn active_view(&self, thread: &str) -> Option<Entity<WebView>> {
        if self.shutdown.callbacks.closed() {
            return None;
        }
        let id = self.active.get(thread)?;
        self.tabs
            .get(thread)?
            .iter()
            .find(|tab| &tab.id == id)
            .map(|tab| tab.view.clone())
    }
    pub fn is_visible(&self, thread: &str) -> bool {
        self.visible.as_deref() == Some(thread)
    }
    pub fn set_thread_visible(&mut self, thread: Option<&str>, cx: &mut App) {
        let thread = if self.shutdown.callbacks.closed() {
            None
        } else {
            thread
        };
        self.visible = thread.map(str::to_owned);
        for (owner, tabs) in &self.tabs {
            for tab in tabs {
                let visible =
                    thread == Some(owner.as_str()) && self.active.get(owner) == Some(&tab.id);
                tab.view.update(
                    cx,
                    |view, _| if visible { view.show() } else { view.hide() },
                );
            }
        }
    }
    pub fn tab_list(&self, thread: &str) -> Value {
        let native_password_manager = credential_bridge::credential_fill_available();
        let mut unsupported = vec![
            "download-progress",
            "download-cancel",
            "download-resume",
            "blob-downloads",
            "cross-origin-frame-actions",
            "dialogs",
            "native-key-events",
            "screenshots",
            "passkeys",
        ];
        if cfg!(windows) {
            unsupported.push("upload");
        }
        if !native_password_manager {
            unsupported.push("password-manager");
        }
        json!({"tabs":self.tabs.get(thread).map(|tabs|tabs.iter().map(|tab|json!({"id":tab.id,"title":public_tab_title(&tab.title,tab.credential_console_suppressed.load(Ordering::Acquire)),"url":tab.url,"loading":tab.loading,"active":self.active.get(thread)==Some(&tab.id)})).collect::<Vec<_>>()).unwrap_or_default(),
            "visible":self.visible.as_deref()==Some(thread),"unsupported":unsupported,
            "nativePasswordManagerAvailable":native_password_manager,
            "passwordManagerRequiresNativeApproval":true})
    }
}

/// Wry 0.53.3's macOS url() unwraps nullable WKWebView.URL/absoluteString.
/// A newly created or provisionally loading view may have neither. Absence is
/// ineligible metadata, never a cached URL or a page-script location fallback.
fn credential_native_address(view: &wry::WebView) -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        MainThreadMarker::new()?;
        let native = view.webview();
        // SAFETY: native UI thread, retained WebKit view, nullable getters.
        unsafe {
            if native.isLoading() {
                return None;
            }
            Some(native.URL()?.absoluteString()?.to_string())
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        view.url().ok()
    }
}

fn credential_binding(
    tab: &str,
    epoch: u64,
    current_epoch: u64,
    address: Option<&str>,
) -> Option<PageBinding> {
    if epoch != current_epoch {
        return None;
    }
    PageBinding::new(tab.to_owned(), epoch, address?).ok()
}

fn public_tab_title(title: &str, protected: bool) -> &str {
    if protected {
        "Saved-login inspection paused"
    } else {
        title
    }
}

fn private_document_action_allowed(action: &BrowserAction) -> bool {
    matches!(
        action,
        BrowserAction::Console { .. }
            | BrowserAction::Navigate { .. }
            | BrowserAction::CloseTab
            | BrowserAction::SelectTab
            | BrowserAction::Click { .. }
    )
}
fn public_script_reply(
    payload: &str,
    same_navigation: bool,
    protected: bool,
    click: bool,
) -> Value {
    if !same_navigation {
        return json!({"error":"Document changed before the browser action completed"});
    }
    if protected {
        if click {
            let value = parse_script_result(payload);
            if value.get("error").is_none() && value["dispatched"] == true {
                return json!({"dispatched":true});
            }
            return json!({"error":"Click outcome could not be confirmed while saved-login inspection is paused"});
        }
        return json!({"error":"Page inspection is paused during a saved-login request; navigate or reload to resume"});
    }
    parse_script_result(payload)
}

fn persistent_profiles_available() -> bool {
    #[cfg(target_os = "macos")]
    unsafe {
        let available: bool = objc2::msg_send![objc2::class!(WKWebsiteDataStore), respondsToSelector: objc2::sel!(dataStoreForIdentifier:)];
        available
    }
    #[cfg(not(target_os = "macos"))]
    {
        true
    }
}

fn parse_script_result(payload: &str) -> Value {
    if payload.len() > 1024 * 1024 {
        return json!({"error":"Browser result exceeds 1 MiB"});
    }
    match serde_json::from_str::<Value>(payload) {
        Ok(value) if value.is_object() => value,
        _ => json!({"error":"Browser returned invalid JSON"}),
    }
}

#[cfg(test)]
mod credential_inspection_tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn credential_metadata_requires_native_url_and_stable_epoch() {
        assert!(credential_binding("new-tab", 0, 0, None).is_none());
        for address in ["", "about:blank", "http://fixture.invalid/login"] {
            assert!(credential_binding("new-tab", 1, 1, Some(address)).is_none());
        }
        let https = Some("https://credential-fixture.invalid/login");
        assert!(credential_binding("new-tab", 1, 2, https).is_none());
        let bound = credential_binding("new-tab", 2, 2, https).unwrap();
        assert_eq!(bound.tab, "new-tab");
        assert_eq!(bound.navigation, 2);
        assert_eq!(bound.origin(), "https://credential-fixture.invalid");
    }
    #[::core::prelude::v1::test]
    fn protected_page_echoes_and_errors_are_not_public_replies() {
        for payload in [
            r#"{"text":"synthetic-password-only"}"#,
            r#"{"error":"synthetic-password-only"}"#,
            r#"{"dispatched":true,"echo":"synthetic-password-only"}"#,
        ] {
            for click in [false, true] {
                let reply = public_script_reply(payload, true, true, click);
                assert!(!reply.to_string().contains("synthetic-password-only"));
            }
        }
        assert_eq!(
            public_script_reply(
                r#"{"dispatched":true,"echo":"synthetic-password-only"}"#,
                true,
                true,
                true
            ),
            json!({"dispatched":true})
        );
    }
    #[::core::prelude::v1::test]
    fn protected_tab_metadata_never_exposes_a_page_title_echo() {
        assert_eq!(
            public_tab_title("synthetic-password-only", true),
            "Saved-login inspection paused"
        );
        assert_eq!(
            public_tab_title("Synthetic public title", false),
            "Synthetic public title"
        );
    }
    #[::core::prelude::v1::test]
    fn stale_callbacks_are_discarded_even_after_navigation_reopens_inspection() {
        let result =
            public_script_reply(r#"{"text":"synthetic-password-only"}"#, false, false, false);
        assert!(result.get("error").is_some());
        assert!(!result.to_string().contains("synthetic-password-only"));
        assert_eq!(
            public_script_reply(r#"{"text":"synthetic public text"}"#, true, false, false),
            json!({"text":"synthetic public text"})
        );
    }
    #[::core::prelude::v1::test]
    fn inspection_pause_allows_navigation_and_boolean_click_only() {
        assert!(!private_document_action_allowed(&BrowserAction::Read {
            selector: None,
            page: 1
        }));
        assert!(!private_document_action_allowed(&BrowserAction::Input {
            selector: "#login".into(),
            text: "synthetic".into()
        }));
        assert!(private_document_action_allowed(&BrowserAction::Click {
            selector: "#submit".into()
        }));
        assert!(private_document_action_allowed(&BrowserAction::Navigate {
            url: "https://example.test".into()
        }));
    }
}
