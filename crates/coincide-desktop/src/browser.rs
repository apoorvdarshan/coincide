//! UI-thread browser owner. The portable engine queues typed requests; native
//! callbacks return bounded payloads without holding an engine mutex.
use anyhow::{Context, Result, ensure};
use coincide_core::browser_protocol::{
    BrowserAction, BrowserReply, BrowserRequest, DownloadRegistry, allow_native_navigation,
    script_for_request, validate_url,
};
use gpui_kit::{App, AppContext, Entity, Window};
use gpui_webview::WebView;
use serde_json::{Value, json};
use std::{
    cell::RefCell,
    collections::{HashMap, VecDeque},
    fs,
    path::PathBuf,
    rc::Rc,
    sync::mpsc::{self, Receiver, SyncSender},
};
use uuid::Uuid;
#[cfg(target_os = "macos")]
use wry::WebViewBuilderExtDarwin;

struct Tab {
    id: String,
    view: Entity<WebView>,
    title: String,
    url: String,
    loading: bool,
}
enum NativeEvent {
    DownloadsChanged,
    Reply(BrowserReply),
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
    context: wry::WebContext,
    downloads: Rc<RefCell<DownloadRegistry>>,
    #[cfg(target_os = "macos")]
    profile_id: [u8; 16],
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
        let (sender, events) = mpsc::sync_channel(512);
        Ok(Self {
            tabs: HashMap::new(),
            active: HashMap::new(),
            visible: None,
            replies: VecDeque::new(),
            events,
            sender,
            context: wry::WebContext::new(Some(profile_dir.join("web-context"))),
            downloads: Rc::new(RefCell::new(DownloadRegistry::new(
                profile_dir.join("downloads"),
            )?)),
            #[cfg(target_os = "macos")]
            profile_id,
        })
    }

    pub fn execute(&mut self, request: BrowserRequest, window: &mut Window, cx: &mut App) {
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
        match &request.action {
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
                tab.view.read(cx).raw().load_url(url)?;
                tab.url = url.clone();
                tab.loading = true;
                Ok(Some(json!({"tab":target,"url":url,"loading":true})))
            }
            _ => {
                let source = script_for_request(&request)?.context("Unsupported browser action")?;
                let sender = self.sender.clone();
                let id = request.id.clone();
                let thread_id = request.thread_id.clone();
                self.tabs[thread][index]
                    .view
                    .read(cx)
                    .raw()
                    .evaluate_script_with_callback(&source, move |payload| {
                        let result = if payload.len() > 1024 * 1024 {
                            json!({"error":"Browser result exceeds 1 MiB"})
                        } else {
                            serde_json::from_str(&payload).unwrap_or_else(
                                |_| json!({"error":"Browser returned invalid JSON"}),
                            )
                        };
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
        let builder = wry::WebViewBuilder::new_with_web_context(&mut self.context)
            .with_url(url)
            .with_devtools(false)
            .with_autoplay(false)
            .with_clipboard(false)
            .with_navigation_handler(|url| allow_native_navigation(&url))
            .with_download_started_handler(move |url, destination| {
                // Wry 0.53 registers GTK callbacks on the shared context without
                // matching the source webview. Fail closed until that is fixed.
                if cfg!(target_os = "linux") {
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
                let _ = title_sender.try_send(NativeEvent::Title {
                    thread: title_thread.clone(),
                    tab: title_id.clone(),
                    title,
                });
            })
            .with_on_page_load_handler(move |event, url| {
                let _ = load_sender.try_send(NativeEvent::Load {
                    thread: load_thread.clone(),
                    tab: load_id.clone(),
                    url,
                    loading: matches!(event, wry::PageLoadEvent::Started),
                });
            })
            .with_new_window_req_handler(move |url, _| {
                if validate_url(&url).is_ok() {
                    let _ = popup_sender.try_send(NativeEvent::Popup {
                        thread: popup_thread.clone(),
                        url,
                    });
                }
                wry::NewWindowResponse::Deny
            });
        #[cfg(target_os = "macos")]
        let builder = builder.with_data_store_identifier(self.profile_id);
        let view = WebView::build(builder, window, cx)?;
        let view = cx.new(|_| view);
        self.tabs.entry(thread.into()).or_default().push(Tab {
            id: id.clone(),
            view,
            title: "New tab".into(),
            url: url.into(),
            loading: url != "about:blank",
        });
        self.active.insert(thread.into(), id.clone());
        // New background tabs must not steal another thread's browser pane.
        let visible = self.visible.clone();
        self.set_thread_visible(visible.as_deref(), cx);
        Ok(id)
    }

    pub fn poll(&mut self, window: &mut Window, cx: &mut App) -> bool {
        let events = self.events.try_iter().take(512).collect::<Vec<_>>();
        let changed = !events.is_empty();
        for event in events {
            match event {
                NativeEvent::DownloadsChanged => {}
                NativeEvent::Reply(reply) => self.replies.push_back(reply),
                NativeEvent::Title { thread, tab, title } => {
                    if let Some(tab) = self
                        .tabs
                        .get_mut(&thread)
                        .and_then(|tabs| tabs.iter_mut().find(|t| t.id == tab))
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
        changed
    }
    pub fn drain_replies(&mut self) -> Vec<BrowserReply> {
        self.replies.drain(..).collect()
    }
    pub fn active_view(&self, thread: &str) -> Option<Entity<WebView>> {
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
        json!({"tabs":self.tabs.get(thread).map(|tabs|tabs.iter().map(|tab|json!({"id":tab.id,"title":tab.title,"url":tab.url,"loading":tab.loading,"active":self.active.get(thread)==Some(&tab.id)})).collect::<Vec<_>>()).unwrap_or_default(),
            "visible":self.visible.as_deref()==Some(thread),"unsupported":["download-progress","download-cancel","download-resume","blob-downloads","upload","cross-origin-frame-actions","password-manager","dialogs","native-key-events","screenshots"]})
    }
}
