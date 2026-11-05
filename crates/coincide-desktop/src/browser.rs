//! UI-thread browser owner. The portable engine queues typed requests; native
//! callbacks return bounded payloads without holding an engine mutex.
use anyhow::{Context, Result, ensure};
use coincide_core::browser_protocol::{
    BrowserAction, BrowserConsole, BrowserReply, BrowserRequest, CONSOLE_SCRIPT, DownloadRegistry,
    allow_native_navigation, script_for_request, validate_url,
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
    time::{Duration, Instant},
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
    console: Rc<RefCell<BrowserConsole>>,
}
struct PendingWait {
    request: BrowserRequest,
    tab: String,
    started: Instant,
    deadline: Instant,
    next_probe: Instant,
    in_flight: bool,
}
enum NativeEvent {
    DownloadsChanged,
    Reply(BrowserReply),
    WaitReply {
        id: String,
        thread: String,
        tab: String,
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
    context: wry::WebContext,
    downloads: Rc<RefCell<DownloadRegistry>>,
    waits: HashMap<String, PendingWait>,
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
            waits: HashMap::new(),
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
            BrowserAction::Console { clear } => Ok(Some(
                self.tabs[thread][index].console.borrow_mut().read(*clear),
            )),
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
                        let result = parse_script_result(&payload);
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
        let console = Rc::new(RefCell::new(BrowserConsole::default()));
        let console_handler = console.clone();
        let builder = wry::WebViewBuilder::new_with_web_context(&mut self.context)
            .with_url(url)
            .with_devtools(false)
            .with_autoplay(false)
            .with_clipboard(false)
            .with_initialization_script_for_main_only(CONSOLE_SCRIPT, false)
            .with_ipc_handler(move |message| {
                console_handler
                    .borrow_mut()
                    .receive(message.body(), &message.uri().to_string());
            })
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
            console,
        });
        self.active.insert(thread.into(), id.clone());
        // New background tabs must not steal another thread's browser pane.
        let visible = self.visible.clone();
        self.set_thread_visible(visible.as_deref(), cx);
        Ok(id)
    }

    pub fn poll(&mut self, window: &mut Window, cx: &mut App) -> bool {
        let events = self.events.try_iter().take(512).collect::<Vec<_>>();
        let mut changed = !events.is_empty();
        for event in events {
            match event {
                NativeEvent::DownloadsChanged => {}
                NativeEvent::Reply(reply) => self.replies.push_back(reply),
                NativeEvent::WaitReply {
                    id,
                    thread,
                    tab,
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
        changed |= self.poll_waits(cx);
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
            if !wait.in_flight && now >= wait.next_probe {
                let source = script_for_request(&wait.request)
                    .and_then(|script| script.context("Unsupported wait operation"));
                let result = source.and_then(|source| {
                    let sender = self.sender.clone();
                    let id = id.clone();
                    let thread = wait.request.thread_id.clone();
                    let tab_id = wait.tab.clone();
                    tab.view
                        .read(cx)
                        .raw()
                        .evaluate_script_with_callback(&source, move |payload| {
                            let _ = sender.try_send(NativeEvent::WaitReply {
                                id: id.clone(),
                                thread: thread.clone(),
                                tab: tab_id.clone(),
                                result: parse_script_result(&payload),
                            });
                        })
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

fn parse_script_result(payload: &str) -> Value {
    if payload.len() > 1024 * 1024 {
        return json!({"error":"Browser result exceeds 1 MiB"});
    }
    match serde_json::from_str::<Value>(payload) {
        Ok(value) if value.is_object() => value,
        _ => json!({"error":"Browser returned invalid JSON"}),
    }
}
