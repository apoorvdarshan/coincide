//! Fresh-runner-only native download acceptance. Not a production command.
//! Run explicitly with COINCIDE_SYNTHETIC_DOWNLOAD_SDK=1 on an isolated GitHub runner.
//! Two real views share one owned private context and use this host's production
//! exact-object download owner. An owned loopback server is the only peer; files
//! land only in a runner-owned root. Native SDK deallocation stays unconfirmed.
#[cfg(target_os = "linux")]
#[allow(dead_code)]
#[path = "../src/browser_downloads_linux.rs"]
mod native_downloads;
#[cfg(target_os = "macos")]
#[allow(dead_code)]
#[path = "../src/browser_downloads_macos.rs"]
mod native_downloads;
#[cfg(target_os = "windows")]
#[allow(dead_code)]
#[path = "../src/browser_downloads_windows.rs"]
mod native_downloads;
#[allow(dead_code)] // Reuse the production boundary without its unrelated app callers.
#[path = "../src/browser_shutdown.rs"]
mod shutdown;

use anyhow::{Context as _, Result, ensure};
use coincide_core::browser_protocol::DownloadRegistry;
#[cfg(not(target_os = "linux"))]
use coincide_core::browser_protocol::allow_native_navigation;
use gpui_kit::{
    App, AppContext, Context, Entity, IntoElement, ParentElement, Render, Styled, Window, div,
};
use serde_json::Value;
use std::{
    cell::RefCell,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    path::{Path, PathBuf},
    rc::Rc,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

const HTTP_BODY: &[u8] = b"owned synthetic HTTP download\n";
const ATTACHMENT_BODY: &[u8] = b"owned synthetic attachment response\n";
const BLOB_BODY: &[u8] = b"owned synthetic blob download\n";
const SLOW_CHUNKS: usize = 640;
const PAGE: &str = r#"<!doctype html><meta charset=utf-8><title>Owned native download fixture</title>
<a id=http href=/file download=owned-http.txt>HTTP</a>
<a id=blob download=owned-blob.txt>Blob</a>
<a id=slow href=/slow download=owned-slow.bin>Slow</a>
<script>document.querySelector('#blob').href=URL.createObjectURL(new Blob(['owned synthetic blob download\n'],{type:'text/plain'}));</script>"#;

/// Owned loopback peer. Its threads must actually return; no timeout is a receipt.
struct Server {
    port: u16,
    stop: Arc<AtomicBool>,
    slow_started: Arc<AtomicBool>,
    slow_returned: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}
impl Server {
    fn start() -> Result<Self> {
        let listener = TcpListener::bind(("127.0.0.1", 0))?;
        listener.set_nonblocking(true)?;
        let port = listener.local_addr()?.port();
        let stop = Arc::new(AtomicBool::new(false));
        let slow_started = Arc::new(AtomicBool::new(false));
        let slow_returned = Arc::new(AtomicBool::new(false));
        let (flag, started, returned) = (stop.clone(), slow_started.clone(), slow_returned.clone());
        let worker = std::thread::Builder::new()
            .name("owned-download-http".into())
            .spawn(move || {
                let mut handlers = Vec::new();
                while !flag.load(Ordering::Acquire) {
                    match listener.accept() {
                        Ok((stream, _)) if handlers.len() < 64 => {
                            let (flag, started, returned) =
                                (flag.clone(), started.clone(), returned.clone());
                            handlers.push(std::thread::spawn(move || {
                                let _ = serve(stream, &flag, &started, &returned);
                            }));
                        }
                        Ok(_) => {}
                        Err(_) => std::thread::sleep(Duration::from_millis(10)),
                    }
                }
                for handler in handlers {
                    let _ = handler.join();
                }
            })?;
        Ok(Self {
            port,
            stop,
            slow_started,
            slow_returned,
            worker: Some(worker),
        })
    }
    fn url(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{path}", self.port)
    }
    fn join(&mut self) -> bool {
        self.stop.store(true, Ordering::Release);
        self.worker
            .take()
            .is_some_and(|worker| worker.join().is_ok())
    }
}
fn serve(
    mut stream: TcpStream,
    stop: &AtomicBool,
    started: &AtomicBool,
    returned: &AtomicBool,
) -> Result<()> {
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let mut request = Vec::new();
    let mut buffer = [0; 1024];
    while !request.windows(4).any(|end| end == b"\r\n\r\n") && request.len() < 16384 {
        let read = stream.read(&mut buffer)?;
        ensure!(read > 0, "request closed early");
        request.extend_from_slice(&buffer[..read]);
    }
    let line = String::from_utf8_lossy(&request);
    let path = line.split_whitespace().nth(1).unwrap_or("/");
    let (mime, name, body): (&str, Option<&str>, &[u8]) = match path {
        "/page" => ("text/html; charset=utf-8", None, PAGE.as_bytes()),
        "/file" => (
            "application/octet-stream",
            Some("owned-http.txt"),
            HTTP_BODY,
        ),
        "/attachment" => (
            "application/octet-stream",
            Some("owned-attachment.txt"),
            ATTACHMENT_BODY,
        ),
        "/slow" => ("application/octet-stream", Some("owned-slow.bin"), &[]),
        _ => {
            stream.write_all(
                b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )?;
            return Ok(());
        }
    };
    let length = if path == "/slow" {
        SLOW_CHUNKS * 1024
    } else {
        body.len()
    };
    let disposition = name.map_or(String::new(), |name| {
        format!("Content-Disposition: attachment; filename=\"{name}\"\r\n")
    });
    write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: {mime}\r\nContent-Length: {length}\r\n{disposition}Cache-Control: no-store\r\nConnection: close\r\n\r\n"
    )?;
    if path != "/slow" {
        stream.write_all(body)?;
        return Ok(());
    }
    started.store(true, Ordering::Release);
    let chunk = [b's'; 1024];
    let result = (|| -> Result<()> {
        for _ in 0..SLOW_CHUNKS {
            if stop.load(Ordering::Acquire) {
                break;
            }
            stream.write_all(&chunk)?;
            stream.flush()?;
            std::thread::sleep(Duration::from_millis(25));
        }
        Ok(())
    })();
    // A cancelled native transfer closes its connection; this handler returns.
    returned.store(true, Ordering::Release);
    result
}

struct Tab {
    id: String,
    view: Entity<gpui_webview::WebView>,
    owner: Rc<native_downloads::Owner>,
    loaded: Arc<AtomicBool>,
}
struct Fixture {
    thread: String,
    tabs: Vec<Tab>,
    _context: wry::WebContext,
    root: PathBuf,
    registry: Rc<RefCell<DownloadRegistry>>,
    shutdown: shutdown::Shutdown,
    server: Server,
    stage: u8,
    seen: Vec<String>,
    started: Instant,
    failure: Option<String>,
    drain_reported: bool,
    result: Arc<Mutex<Option<bool>>>,
}
impl Fixture {
    fn new(
        root: &Path,
        result: Arc<Mutex<Option<bool>>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<Self> {
        let server = Server::start()?;
        let mut context = wry::WebContext::new(Some(root.join("runtime")));
        let downloads = root.join("Downloads").join("Coincide");
        let registry = Rc::new(RefCell::new(DownloadRegistry::new(downloads.clone())?));
        let mut shutdown = shutdown::Shutdown::default();
        shutdown.ever_native = true;
        let thread = uuid::Uuid::new_v4().to_string();
        let mut tabs = Vec::new();
        for _ in 0..2 {
            let id = uuid::Uuid::new_v4().to_string();
            let navigation = Arc::new(AtomicU64::new(0));
            let loaded = Arc::new(AtomicBool::new(false));
            let page = server.url("/page");
            let (load_flag, load_page) = (loaded.clone(), page.clone());
            let builder = wry::WebViewBuilder::new_with_web_context(&mut context)
                .with_incognito(true)
                .with_devtools(false)
                .with_clipboard(false)
                .with_autoplay(false)
                .with_url("about:blank")
                .with_on_page_load_handler(move |event, url| {
                    if matches!(event, wry::PageLoadEvent::Finished) && url == load_page {
                        load_flag.store(true, Ordering::Release);
                    }
                });
            // Production's policy: Linux decides in its owner, others in Wry.
            #[cfg(not(target_os = "linux"))]
            let builder = {
                let navigation = navigation.clone();
                builder.with_navigation_handler(move |url| {
                    let allowed = allow_native_navigation(&url);
                    if allowed {
                        navigation.fetch_add(1, Ordering::AcqRel);
                    }
                    allowed
                })
            };
            let view = gpui_webview::WebView::build(builder, window, cx)
                .context("synthetic native view construction failed")?;
            let owner = native_downloads::Owner::install(
                &view,
                &thread,
                &id,
                registry.clone(),
                shutdown.callbacks.clone(),
                Arc::new(AtomicBool::new(false)),
                navigation,
                || {},
            )?;
            view.raw().load_url(&page)?;
            tabs.push(Tab {
                id,
                view: cx.new(|_| view),
                owner,
                loaded,
            });
        }
        cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(25))
                    .await;
                let done = this.update(cx, |this, cx| this.poll(cx)).unwrap_or(true);
                if done {
                    break;
                }
            }
        })
        .detach();
        Ok(Self {
            thread,
            tabs,
            _context: context,
            root: downloads,
            registry,
            shutdown,
            server,
            stage: 0,
            seen: Vec::new(),
            started: Instant::now(),
            failure: None,
            drain_reported: false,
            result,
        })
    }
    fn rows(&self, tab: usize) -> Vec<Value> {
        self.registry
            .borrow()
            .list(&self.thread, Some(&self.tabs[tab].id))["downloads"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    }
    fn click(&self, tab: usize, selector: &str, cx: &App) -> Result<()> {
        let source = format!("document.querySelector({selector:?}).click()");
        Ok(self.tabs[tab]
            .view
            .read(cx)
            .raw()
            .evaluate_script(&source)?)
    }
    fn new_finished(&mut self, tab: usize) -> Option<Value> {
        let row = self.rows(tab).into_iter().find(|row| {
            row["state"] == "finished" && !self.seen.contains(&row["id"].to_string())
        })?;
        self.seen.push(row["id"].to_string());
        Some(row)
    }
    /// The published path must be a regular file in a fresh UUID folder directly
    /// below the owned root, holding exactly the served bytes.
    fn verify(&self, row: &Value, expected: &[u8]) -> Result<()> {
        let path = PathBuf::from(row["path"].as_str().context("finished row has no path")?);
        let metadata = std::fs::symlink_metadata(&path)?;
        ensure!(metadata.is_file(), "download is not a regular file");
        let canonical = path.canonicalize()?;
        let folder = canonical.parent().context("download has no folder")?;
        ensure!(
            folder.parent() == Some(self.root.canonicalize()?.as_path()),
            "download escaped its owned UUID folder"
        );
        uuid::Uuid::parse_str(&folder.file_name().context("folder")?.to_string_lossy())?;
        ensure!(std::fs::read(&path)? == expected, "download bytes differ");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            ensure!(
                metadata.permissions().mode() & 0o777 == 0o600,
                "file not private"
            );
            ensure!(
                std::fs::metadata(folder)?.permissions().mode() & 0o777 == 0o700,
                "folder not private"
            );
        }
        Ok(())
    }
    fn step(&mut self, cx: &mut Context<Self>) -> Result<bool> {
        match self.stage {
            0 if self
                .tabs
                .iter()
                .all(|tab| tab.loaded.load(Ordering::Acquire)) =>
            {
                // API navigation to an attachment: the response-policy path, no script.
                self.tabs[0]
                    .view
                    .read(cx)
                    .raw()
                    .load_url(&self.server.url("/attachment"))?;
            }
            1 => {
                let Some(row) = self.new_finished(0) else {
                    return Ok(false);
                };
                self.verify(&row, ATTACHMENT_BODY)?;
                ensure!(row["name"] == "owned-attachment.txt", "suggested name lost");
                self.click(0, "#http", cx)?;
            }
            2 => {
                let Some(row) = self.new_finished(0) else {
                    return Ok(false);
                };
                self.verify(&row, HTTP_BODY)?;
                ensure!(
                    self.rows(1).is_empty(),
                    "sibling view in the same context received a download"
                );
                self.click(1, "#http", cx)?;
            }
            3 => {
                let Some(row) = self.new_finished(1) else {
                    return Ok(false);
                };
                self.verify(&row, HTTP_BODY)?;
                ensure!(self.rows(0).len() == 2, "first view changed");
                self.click(0, "#blob", cx)?;
            }
            4 => {
                let Some(row) = self.new_finished(0) else {
                    return Ok(false);
                };
                self.verify(&row, BLOB_BODY)?;
                ensure!(self.rows(1).len() == 1, "blob reached the sibling view");
                self.click(0, "#slow", cx)?;
            }
            5 => {
                let active = self.rows(0).iter().any(|row| row["state"] == "downloading");
                if !active || !self.server.slow_started.load(Ordering::Acquire) {
                    return Ok(false);
                }
                self.tabs[0].owner.close();
            }
            6 => {
                let rows = self.rows(0);
                let Some(row) = rows.iter().find(|row| row["name"] == "owned-slow.bin") else {
                    return Ok(false);
                };
                if row["state"] == "downloading" || row["state"] == "unconfirmed" {
                    return Ok(false);
                }
                ensure!(row["state"] == "cancelled", "closing did not cancel: {row}");
                ensure!(
                    row.get("path").is_none(),
                    "cancelled download published a path"
                );
                if !self.server.slow_returned.load(Ordering::Acquire) {
                    return Ok(false);
                }
                let sibling = self.rows(1);
                ensure!(
                    sibling.len() == 1 && sibling[0]["state"] == "finished",
                    "closing one view changed its sibling"
                );
                self.tabs[1].owner.close();
            }
            _ => return Ok(false),
        }
        println!("synthetic native download stage {} passed", self.stage);
        self.stage += 1;
        Ok(true)
    }
    fn poll(&mut self, cx: &mut Context<Self>) -> bool {
        if self.failure.is_none() {
            if self.started.elapsed() > Duration::from_secs(90) {
                // A deadline is a failure, never a native callback receipt.
                self.failure = Some(format!("deadline exceeded at stage {}", self.stage));
            } else if let Err(error) = self.step(cx) {
                self.failure = Some(format!("stage {}: {error:#}", self.stage));
            }
            if let Some(failure) = &self.failure {
                eprintln!("synthetic native download failure: {failure}");
                for tab in &self.tabs {
                    tab.owner.close();
                }
                self.stage = 7;
            }
        }
        if self.stage < 7 {
            return false;
        }
        let pending = self.tabs.iter().map(|tab| tab.owner.pending()).sum();
        let status = self.shutdown.status(pending, 0, 0);
        // The production quit condition: every native download and callback
        // owner actually returned. Owners and views stay retained until then.
        if status.downloads_pending != 0 || status.callbacks_pending != 0 {
            if self.started.elapsed() > Duration::from_secs(120) && !self.drain_reported {
                // Report once and keep waiting: unknown owners are retained.
                self.drain_reported = true;
                eprintln!(
                    "synthetic native download owners pending: downloads={} callbacks={}",
                    status.downloads_pending, status.callbacks_pending
                );
            }
            return false;
        }
        if !self.server.join() && self.failure.is_none() {
            self.failure = Some("owned HTTP server did not return".into());
        }
        *self.result.lock().unwrap() = Some(self.failure.is_none());
        cx.quit();
        true
    }
}
impl Render for Fixture {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let mut row = div().size_full().flex();
        for tab in &self.tabs {
            row = row.child(div().flex_1().h_full().child(tab.view.clone()));
        }
        row
    }
}
fn fresh_runner_root() -> Result<PathBuf> {
    ensure!(
        std::env::var("COINCIDE_SYNTHETIC_DOWNLOAD_SDK").as_deref() == Ok("1")
            && std::env::var("GITHUB_ACTIONS").as_deref() == Ok("true")
            && std::env::var("RUNNER_ENVIRONMENT").as_deref() == Ok("github-hosted"),
        "explicit fresh GitHub-hosted fixture opt-in required"
    );
    let runner =
        std::fs::canonicalize(std::env::var_os("RUNNER_TEMP").context("runner temp required")?)?;
    let root = tempfile::Builder::new()
        .prefix("owned-synthetic-downloads-")
        .tempdir_in(&runner)?;
    ensure!(
        root.path().canonicalize()?.parent() == Some(runner.as_path()),
        "owned runner root required"
    );
    // Partial files and SDK profiles stay; fresh runner destruction removes them.
    Ok(root.keep())
}
fn main() -> Result<()> {
    let root = fresh_runner_root()?;
    let result = Arc::new(Mutex::new(None));
    let observed = result.clone();
    #[cfg(target_os = "linux")]
    let app = gpui_kit::platform::linux(gpui_kit::WindowingModes::X11);
    #[cfg(not(target_os = "linux"))]
    let app = gpui_kit::application();
    app.run(move |cx| {
        gpui_kit::init(cx);
        gpui_kit::open_window(Default::default(), cx, |window, cx| {
            cx.new(|cx| {
                Fixture::new(&root, result, window, cx)
                    .expect("owned native download fixture setup failed")
            })
        })
        .expect("owned fixture window unavailable");
        cx.activate(true);
    });
    ensure!(
        *observed.lock().unwrap() == Some(true),
        "synthetic native download fixture did not pass"
    );
    println!(
        "synthetic native downloads: PASS (response, attribute and blob downloads attributed to exact views; close cancelled an active transfer with a native receipt; native SDK deallocation unconfirmed)"
    );
    Ok(())
}
