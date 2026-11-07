//! Fresh-runner-only native upload acceptance. Not a production command.
//! Run explicitly with COINCIDE_SYNTHETIC_UPLOAD_SDK=1 on an isolated GitHub runner.
//! Owned synthetic files reach an owned page only through the production probe,
//! worker and attachment scripts. The page's own file chooser then runs through
//! the production dialog adapter: a hidden tab declines without any panel, and a
//! visible page in the key window gets the standard chooser, which is cancelled
//! here and never confirmed. No user file, profile or picker choice is touched.
#[allow(dead_code)] // Reuse the production boundary without its unrelated app callers.
#[path = "../src/browser_dialogs.rs"]
mod dialogs;
#[allow(dead_code)] // Reuse the production boundary without its unrelated app callers.
#[path = "../src/browser_shutdown.rs"]
mod shutdown;

use coincide_core::browser_protocol::{
    BrowserAction, BrowserRequest, prepare_upload_script, upload, upload_probe_script,
};
use gpui_kit::{
    App, AppContext, Context, Entity, IntoElement, ParentElement, Render, Styled, Window, div,
};
use serde_json::{Value, json};
use shutdown::TrackedEvaluation;
use std::{
    collections::VecDeque,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64},
        mpsc,
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

const URL: &str = "https://upload-fixture.invalid/upload.html";
const HTML: &str = r#"<!doctype html><meta charset=utf-8><title>Owned synthetic upload fixture</title>
<input id=single type=file><input id=multi type=file multiple><input id=text>
<input id=hidden-chooser type=file><input id=visible-chooser type=file multiple>
<script>
window.fixture={events:[],files:{},values:{}};
for(const el of document.querySelectorAll('input[type=file]')){
  for(const kind of ['input','change','cancel'])el.addEventListener(kind,()=>fixture.events.push(el.id+':'+kind));
  el.addEventListener('change',async()=>{const files=[...el.files];fixture.values[el.id]=el.value;
    fixture.files[el.id]=await Promise.all(files.map(async f=>({name:f.name,type:f.type,size:f.size,bytes:Array.from(new Uint8Array(await f.arrayBuffer()))})));});
}
window.fixtureReady=true;
</script>"#;
const BINARY_NAME: &str = "界 upload.bin";
const BINARY: &[u8] = &[0, 255, 10, 65, 0xc3, 0xa9];
const TEXT_NAME: &str = "second.txt";
const TEXT: &[u8] = b"owned second file\n";
const STEP_LIMIT: Duration = Duration::from_secs(15);

struct Files {
    root: PathBuf,
    binary: PathBuf,
    text: PathBuf,
    directory: PathBuf,
    oversized: PathBuf,
    #[cfg(unix)]
    symlink: PathBuf,
}
enum Expect {
    Attached(usize),
    ProbeError(&'static str),
    ScriptError(&'static str),
}
struct Case {
    label: &'static str,
    selector: &'static str,
    files: Vec<PathBuf>,
    stale_ticket: bool,
    expect: Expect,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Step {
    Ready,
    Refusals,
    Probe,
    Prepare,
    Attach,
    Verify,
    HiddenClick,
    HiddenDeclined,
    ShowForChooser,
    VisibleClick,
    VisibleChooser,
    VisibleCancelled,
    Drain,
}
struct Fixture {
    view: Entity<gpui_webview::WebView>,
    _context: wry::WebContext,
    dialogs: Option<dialogs::Dialogs>,
    shutdown: shutdown::Shutdown,
    files: Arc<Files>,
    cases: VecDeque<Case>,
    case: Option<Case>,
    request: Option<BrowserRequest>,
    ticket: String,
    read: Option<mpsc::Receiver<String>>,
    worker: Option<JoinHandle<Result<String, String>>>,
    step: Step,
    step_started: Instant,
    failure: Option<String>,
    result: Arc<Mutex<Option<Result<(), String>>>>,
}
impl Fixture {
    fn new(
        files: Arc<Files>,
        result: Arc<Mutex<Option<Result<(), String>>>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut context = wry::WebContext::new(Some(files.root.join("runtime")));
        let builder = wry::WebViewBuilder::new_with_web_context(&mut context)
            .with_incognito(true)
            .with_devtools(false)
            .with_clipboard(false)
            .with_autoplay(false)
            .with_navigation_handler(|url| url == URL || url == "about:blank")
            .with_url("about:blank");
        // The runtime path is fresh and runner-owned; never use a personal WebView2 profile.
        let view = gpui_webview::WebView::build(builder, window, cx)
            .expect("synthetic native view construction failed");
        let dialogs = dialogs::Dialogs::install(
            view.raw(),
            Arc::new(AtomicU64::new(1)),
            Arc::new(AtomicBool::new(false)),
            || {},
        );
        assert!(dialogs.supported(), "production dialog adapter unavailable");
        load_fixture(view.raw(), &files.root).expect("owned HTTPS fixture setup failed");
        let mut shutdown = shutdown::Shutdown::default();
        shutdown.ever_native = true;
        let view = cx.new(|_| view);
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
        let cases = cases(&files);
        Self {
            view,
            _context: context,
            dialogs: Some(dialogs),
            shutdown,
            files,
            cases,
            case: None,
            request: None,
            ticket: String::new(),
            read: None,
            worker: None,
            step: Step::Ready,
            step_started: Instant::now(),
            failure: None,
            result,
        }
    }
    fn advance(&mut self, step: Step) {
        self.step = step;
        self.step_started = Instant::now();
    }
    fn fail(&mut self, reason: String) {
        if self.failure.is_none() {
            eprintln!(
                "synthetic native upload failed at {:?}: {reason}",
                self.step
            );
            self.failure = Some(reason);
        }
        self.advance(Step::Drain);
    }
    fn evaluate(&mut self, script: &str, cx: &App) {
        let (sender, receiver) = mpsc::sync_channel(1);
        self.read = Some(receiver);
        if let Err(error) = self.view.read(cx).raw().evaluate_script_tracked(
            script,
            &self.shutdown.callbacks,
            move |payload| {
                let _ = sender.try_send(payload);
            },
        ) {
            self.fail(format!("native evaluation failed: {error}"));
        }
    }
    /// One returned evaluation, parsed like production replies. Paths never
    /// appear in page-visible results.
    fn returned(&mut self) -> Option<Value> {
        let payload = self.read.as_ref()?.try_recv().ok()?;
        self.read = None;
        let root = self.files.root.to_string_lossy().into_owned();
        let escaped = serde_json::to_string(&root).unwrap_or_default();
        if payload.contains(&root) || payload.contains(escaped.trim_matches('"')) {
            self.fail("page-visible result exposed the owned file path".into());
            return None;
        }
        Some(serde_json::from_str(&payload).unwrap_or(Value::Null))
    }
    fn next_case(&mut self, cx: &App) {
        let Some(case) = self.cases.pop_front() else {
            self.case = None;
            self.advance(Step::Verify);
            return;
        };
        let request = BrowserRequest {
            id: uuid::Uuid::new_v4().to_string(),
            thread_id: uuid::Uuid::new_v4().to_string(),
            tab: None,
            frame: None,
            action: BrowserAction::Upload {
                selector: case.selector.into(),
                files: case
                    .files
                    .iter()
                    .map(|path| path.to_string_lossy().into_owned())
                    .collect(),
            },
        };
        self.ticket = uuid::Uuid::new_v4().to_string();
        match upload_probe_script(&request, &self.ticket) {
            Ok(source) => {
                self.request = Some(request);
                self.case = Some(case);
                self.advance(Step::Probe);
                self.evaluate(&source, cx);
            }
            Err(error) => self.fail(format!("{}: probe rejected: {error}", case.label)),
        }
    }
    fn poll(&mut self, cx: &mut Context<Self>) -> bool {
        if self.step != Step::Drain && self.step_started.elapsed() > STEP_LIMIT {
            self.fail("step deadline exceeded".into());
        }
        match self.step {
            Step::Ready => {
                if self.read.is_none() {
                    self.evaluate("window.fixtureReady===true", cx);
                } else if let Some(value) = self.returned()
                    && value == json!(true)
                {
                    let files = self.files.clone();
                    self.worker = Some(std::thread::spawn(move || {
                        refusals(&files).map(|()| String::new())
                    }));
                    self.advance(Step::Refusals);
                }
            }
            Step::Refusals => {
                if self.worker.as_ref().is_some_and(JoinHandle::is_finished) {
                    match self.worker.take().unwrap().join() {
                        Ok(Ok(_)) => self.next_case(cx),
                        Ok(Err(reason)) => self.fail(reason),
                        Err(_) => self.fail("refusal worker panicked".into()),
                    }
                }
            }
            Step::Probe => {
                if let Some(value) = self.returned() {
                    let case = self.case.as_ref().expect("active case");
                    let label = case.label;
                    if let Expect::ProbeError(text) = case.expect {
                        if error_contains(&value, text) {
                            self.next_case(cx);
                        } else {
                            self.fail(format!("{label}: probe returned {value}"));
                        }
                    } else if value["ready"] == true {
                        let request = self.request.clone().expect("active request");
                        let ticket = if case.stale_ticket {
                            uuid::Uuid::new_v4().to_string()
                        } else {
                            self.ticket.clone()
                        };
                        let work = upload::UploadWork::new(Duration::from_secs(10));
                        self.worker = Some(std::thread::spawn(move || {
                            prepare_upload_script(&request, &ticket, &work)
                                .map_err(|error| error.to_string())
                        }));
                        self.advance(Step::Prepare);
                    } else {
                        self.fail(format!("{label}: probe returned {value}"));
                    }
                }
            }
            Step::Prepare => {
                if self.worker.as_ref().is_some_and(JoinHandle::is_finished) {
                    let label = self.case.as_ref().expect("active case").label;
                    match self.worker.take().unwrap().join() {
                        Ok(Ok(source)) => {
                            self.advance(Step::Attach);
                            self.evaluate(&source, cx);
                        }
                        Ok(Err(error)) => self.fail(format!("{label}: worker refused: {error}")),
                        Err(_) => self.fail(format!("{label}: worker panicked")),
                    }
                }
            }
            Step::Attach => {
                if let Some(value) = self.returned() {
                    let case = self.case.as_ref().expect("active case");
                    let passed = match case.expect {
                        Expect::Attached(count) => {
                            value["attached"] == true
                                && value["count"] == count
                                && value["submissionRequested"] == false
                        }
                        Expect::ScriptError(text) => error_contains(&value, text),
                        Expect::ProbeError(_) => false,
                    };
                    if passed {
                        self.next_case(cx);
                    } else {
                        let label = case.label;
                        self.fail(format!("{label}: attachment returned {value}"));
                    }
                }
            }
            Step::Verify => {
                if self.read.is_none() {
                    self.evaluate("(()=>window.fixture)()", cx);
                } else if let Some(value) = self.returned() {
                    // File bytes are read asynchronously by the page itself.
                    if value["files"]["single"].is_array() && value["files"]["multi"].is_array() {
                        match verify_page(&value) {
                            Ok(()) if cfg!(target_os = "windows") => {
                                println!(
                                    "WebView2 shows its own built-in chooser for a user's click; it has no interception API and is not driven here"
                                );
                                self.advance(Step::Drain);
                            }
                            Ok(()) => self.advance(Step::HiddenClick),
                            Err(reason) => self.fail(reason),
                        }
                    }
                }
            }
            Step::HiddenClick => {
                if self.read.is_none() {
                    self.view.update(cx, |view, _| view.hide());
                    self.evaluate(
                        "(()=>{document.getElementById('hidden-chooser').click();return true})()",
                        cx,
                    );
                } else if self.returned().is_some() {
                    self.advance(Step::HiddenDeclined);
                }
            }
            Step::HiddenDeclined => {
                if native::chooser(self.view.read(cx).raw()).is_some() {
                    native::dismiss(self.view.read(cx).raw());
                    self.fail("a hidden tab opened a native file chooser".into());
                } else if self.read.is_none() {
                    self.evaluate(
                        "window.fixture.events.includes('hidden-chooser:cancel')",
                        cx,
                    );
                } else if self.returned() == Some(json!(true)) {
                    self.view.update(cx, |view, _| view.show());
                    native::make_key(self.view.read(cx).raw());
                    self.advance(Step::ShowForChooser);
                }
            }
            Step::ShowForChooser => {
                // A few frames of real geometry before the user-path click.
                if self.step_started.elapsed() > Duration::from_millis(500) {
                    self.advance(Step::VisibleClick);
                }
            }
            Step::VisibleClick => {
                if self.read.is_none() {
                    self.evaluate(
                        "(()=>{document.getElementById('visible-chooser').click();return true})()",
                        cx,
                    );
                } else if self.returned().is_some() {
                    self.advance(Step::VisibleChooser);
                }
            }
            Step::VisibleChooser => match native::chooser(self.view.read(cx).raw()) {
                Some(true) => {
                    native::dismiss(self.view.read(cx).raw());
                    self.advance(Step::VisibleCancelled);
                }
                Some(false) => {
                    native::dismiss(self.view.read(cx).raw());
                    self.fail("standard chooser ignored the input's multiple attribute".into());
                }
                None => {}
            },
            Step::VisibleCancelled => {
                if self.read.is_none() {
                    self.evaluate(
                        "window.fixture.events.includes('visible-chooser:cancel') && !window.fixture.events.includes('visible-chooser:change')",
                        cx,
                    );
                } else if self.returned() == Some(json!(true))
                    && native::chooser(self.view.read(cx).raw()).is_none()
                {
                    self.advance(Step::Drain);
                }
            }
            Step::Drain => {
                // Restore the original native delegate before any owner accounting.
                self.dialogs = None;
                if self.worker.as_ref().is_some_and(JoinHandle::is_finished) {
                    let _ = self.worker.take().unwrap().join();
                }
                let status = self.shutdown.status(0, 1, 1);
                let drained = self.worker.is_none()
                    && status.callbacks_pending == 0
                    && status.callback_blocks_pending == 0;
                if drained || self.step_started.elapsed() > STEP_LIMIT {
                    let outcome = match (&self.failure, drained) {
                        (Some(reason), _) => Err(reason.clone()),
                        (None, true) => Ok(()),
                        (None, false) => Err("native callback owners did not return".into()),
                    };
                    *self.result.lock().unwrap() = Some(outcome);
                    // Only Rust callback/worker owners are drained. SDK view/context
                    // deallocation remains Unknown; runner teardown owns the profile.
                    cx.quit();
                    return true;
                }
            }
        }
        false
    }
}
impl Render for Fixture {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(self.view.clone())
    }
}
fn error_contains(value: &Value, text: &str) -> bool {
    value["error"]
        .as_str()
        .is_some_and(|error| error.contains(text))
}
fn cases(files: &Files) -> VecDeque<Case> {
    VecDeque::from([
        Case {
            label: "single owned binary file",
            selector: "#single",
            files: vec![files.binary.clone()],
            stale_ticket: false,
            expect: Expect::Attached(1),
        },
        Case {
            label: "two owned files on a multiple input",
            selector: "#multi",
            files: vec![files.binary.clone(), files.text.clone()],
            stale_ticket: false,
            expect: Expect::Attached(2),
        },
        Case {
            label: "attachment under a changed document ticket",
            selector: "#single",
            files: vec![files.text.clone()],
            stale_ticket: true,
            expect: Expect::ScriptError("Upload document or input changed"),
        },
        Case {
            label: "selector naming a text field",
            selector: "#text",
            files: vec![files.text.clone()],
            stale_ticket: false,
            expect: Expect::ProbeError("must name a file input directly"),
        },
        Case {
            label: "two files on a single-file input",
            selector: "#single",
            files: vec![files.binary.clone(), files.text.clone()],
            stale_ticket: false,
            expect: Expect::ScriptError("does not allow multiple files"),
        },
    ])
}
/// Production reader refusals, never reaching the page.
fn refusals(files: &Files) -> Result<(), String> {
    let path = |path: &Path| path.to_string_lossy().into_owned();
    let refuse = |label: &str, paths: Vec<String>| match upload::prepare_controlled(
        &paths,
        &upload::UploadWork::new(Duration::from_secs(10)),
    ) {
        Ok(_) => Err(format!("{label} was admitted")),
        Err(_) => Ok(()),
    };
    refuse("a directory", vec![path(&files.directory)])?;
    refuse(
        "a missing file",
        vec![path(&files.directory.join("missing.txt"))],
    )?;
    refuse("a relative path", vec![TEXT_NAME.into()])?;
    refuse(
        "parent traversal",
        vec![path(&files.directory.join("..").join(TEXT_NAME))],
    )?;
    refuse("nine files", vec![path(&files.text); 9])?;
    refuse(
        "files over the combined 4 MiB limit",
        vec![path(&files.oversized), path(&files.text)],
    )?;
    #[cfg(unix)]
    refuse("a final symlink", vec![path(&files.symlink)])?;
    let cancelled = upload::UploadWork::new(Duration::from_secs(10));
    cancelled.cancel();
    if upload::prepare_controlled(&[path(&files.text)], &cancelled).is_ok() {
        return Err("cancelled work read a file".into());
    }
    Ok(())
}
fn verify_page(value: &Value) -> Result<(), String> {
    let file = |name: &str, mime: &str, bytes: &[u8]| json!({"name":name,"type":mime,"size":bytes.len(),"bytes":bytes});
    let binary = file(BINARY_NAME, "application/octet-stream", BINARY);
    let expected = json!({
        "single": [binary.clone()],
        "multi": [binary, file(TEXT_NAME, "text/plain", TEXT)],
    });
    if value["files"] != expected {
        return Err(format!("page received {}", value["files"]));
    }
    let events = json!([
        "single:input",
        "single:change",
        "multi:input",
        "multi:change"
    ]);
    if value["events"] != events {
        return Err(format!("page events were {}", value["events"]));
    }
    if !value["values"]["single"]
        .as_str()
        .is_some_and(|text| text.ends_with(BINARY_NAME))
    {
        return Err(format!(
            "file input value was {}",
            value["values"]["single"]
        ));
    }
    Ok(())
}
#[cfg(target_os = "macos")]
mod native {
    use objc2::rc::Retained;
    use objc2_app_kit::{NSOpenPanel, NSWindow};
    use objc2_web_kit::WKWebView;
    use wry::WebViewExtMacOS;
    fn window(view: &wry::WebView) -> Option<Retained<NSWindow>> {
        let native: Retained<WKWebView> = view.webview().into_super();
        native.window()
    }
    fn panel(view: &wry::WebView) -> Option<Retained<NSOpenPanel>> {
        window(view)?
            .attachedSheet()?
            .downcast::<NSOpenPanel>()
            .ok()
    }
    pub fn make_key(view: &wry::WebView) {
        if let Some(window) = window(view) {
            window.makeKeyAndOrderFront(None);
        }
    }
    /// An open panel attached as a sheet to the page's own window, and whether
    /// it allows multiple selection.
    pub fn chooser(view: &wry::WebView) -> Option<bool> {
        panel(view).map(|panel| panel.allowsMultipleSelection())
    }
    pub fn dismiss(view: &wry::WebView) {
        if let Some(panel) = panel(view) {
            unsafe { panel.cancel(None) };
        }
    }
}
#[cfg(target_os = "linux")]
mod native {
    use gtk::prelude::{Cast, DialogExt, FileChooserExt, WidgetExt};
    fn dialogs() -> Vec<gtk::FileChooserDialog> {
        gtk::Window::list_toplevels()
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::FileChooserDialog>().ok())
            .filter(|dialog| dialog.is_visible())
            .collect()
    }
    pub fn make_key(_: &wry::WebView) {}
    /// A shown WebKitGTK standard chooser, and whether it allows multiple selection.
    pub fn chooser(_: &wry::WebView) -> Option<bool> {
        dialogs().first().map(|dialog| dialog.selects_multiple())
    }
    pub fn dismiss(_: &wry::WebView) {
        for dialog in dialogs() {
            dialog.response(gtk::ResponseType::Cancel);
        }
    }
}
#[cfg(target_os = "windows")]
mod native {
    pub fn make_key(_: &wry::WebView) {}
    pub fn chooser(_: &wry::WebView) -> Option<bool> {
        None
    }
    pub fn dismiss(_: &wry::WebView) {}
}
#[cfg(target_os = "linux")]
fn load_fixture(view: &wry::WebView, _: &Path) -> anyhow::Result<()> {
    use webkit2gtk::WebViewExt;
    use wry::WebViewExtUnix;
    view.webview().load_html(HTML, Some(URL));
    Ok(())
}
#[cfg(target_os = "macos")]
fn load_fixture(view: &wry::WebView, _: &Path) -> anyhow::Result<()> {
    use objc2::rc::Retained;
    use objc2_foundation::{NSString, NSURL};
    use objc2_web_kit::WKWebView;
    use wry::WebViewExtMacOS;
    let native: Retained<WKWebView> = view.webview().into_super();
    let url = NSURL::URLWithString(&NSString::from_str(URL))
        .ok_or_else(|| anyhow::anyhow!("fixed HTTPS URL unavailable"))?;
    unsafe {
        native.loadHTMLString_baseURL(&NSString::from_str(HTML), Some(&url));
    }
    Ok(())
}
#[cfg(target_os = "windows")]
fn load_fixture(view: &wry::WebView, root: &Path) -> anyhow::Result<()> {
    use webview2_com::Microsoft::Web::WebView2::Win32::{
        COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS, ICoreWebView2_3,
    };
    use windows::core::{HSTRING, Interface};
    use wry::WebViewExtWindows;
    // Map only the page folder, never the folder holding the owned files.
    let page = root.join("page");
    std::fs::create_dir(&page)?;
    std::fs::write(page.join("upload.html"), HTML)?;
    let native: ICoreWebView2_3 = view.webview().cast()?;
    unsafe {
        native.SetVirtualHostNameToFolderMapping(
            &HSTRING::from("upload-fixture.invalid"),
            &HSTRING::from(page.to_string_lossy().as_ref()),
            COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS,
        )?;
    }
    view.load_url(URL)?;
    Ok(())
}
fn owned_files(root: &Path) -> anyhow::Result<Files> {
    let directory = root.join("files");
    std::fs::create_dir(&directory)?;
    let binary = directory.join(BINARY_NAME);
    std::fs::write(&binary, BINARY)?;
    let text = directory.join(TEXT_NAME);
    std::fs::write(&text, TEXT)?;
    let oversized = directory.join("oversized.bin");
    std::fs::File::create(&oversized)?.set_len(4 * 1024 * 1024)?;
    #[cfg(unix)]
    let symlink = directory.join("link.txt");
    #[cfg(unix)]
    std::os::unix::fs::symlink(&text, &symlink)?;
    Ok(Files {
        root: root.to_owned(),
        binary,
        text,
        directory,
        oversized,
        #[cfg(unix)]
        symlink,
    })
}
fn fresh_runner_root() -> anyhow::Result<PathBuf> {
    anyhow::ensure!(
        std::env::var("COINCIDE_SYNTHETIC_UPLOAD_SDK").as_deref() == Ok("1")
            && std::env::var("GITHUB_ACTIONS").as_deref() == Ok("true")
            && std::env::var("RUNNER_ENVIRONMENT").as_deref() == Ok("github-hosted"),
        "explicit fresh GitHub-hosted fixture opt-in required"
    );
    anyhow::ensure!(
        upload::available(),
        "native uploads are not enabled on this platform"
    );
    let runner = std::fs::canonicalize(
        std::env::var_os("RUNNER_TEMP").ok_or_else(|| anyhow::anyhow!("runner temp required"))?,
    )?;
    let root = tempfile::Builder::new()
        .prefix("owned-synthetic-upload-")
        .tempdir_in(&runner)?;
    anyhow::ensure!(
        root.path().canonicalize()?.parent() == Some(runner.as_path()),
        "owned runner root required"
    );
    // Do not delete an SDK profile while its native release is unconfirmed.
    // Fresh hosted-runner destruction cleans this owned scaffold after process return.
    Ok(root.keep())
}
fn main() -> anyhow::Result<()> {
    let root = fresh_runner_root()?;
    let files = Arc::new(owned_files(&root)?);
    let result = Arc::new(Mutex::new(None));
    let observed = result.clone();
    #[cfg(target_os = "linux")]
    let app = gpui_kit::platform::linux(gpui_kit::WindowingModes::X11);
    #[cfg(not(target_os = "linux"))]
    let app = gpui_kit::application();
    app.run(move |cx| {
        gpui_kit::init(cx);
        gpui_kit::open_window(Default::default(), cx, |window, cx| {
            cx.new(|cx| Fixture::new(files, result, window, cx))
        })
        .expect("owned fixture window unavailable");
        cx.activate(true);
    });
    let outcome = observed.lock().unwrap().take();
    match outcome {
        Some(Ok(())) => {
            println!(
                "synthetic native upload: PASS (production probe/worker/attachment scripts, exact bytes, reader refusals, stale-ticket refusal{}; native SDK deallocation unconfirmed)",
                if cfg!(target_os = "windows") {
                    ""
                } else {
                    ", hidden-tab chooser declined, visible key-window chooser shown and cancelled"
                }
            );
            Ok(())
        }
        Some(Err(reason)) => anyhow::bail!("synthetic native upload fixture failed: {reason}"),
        None => anyhow::bail!("synthetic native upload fixture returned no result"),
    }
}
