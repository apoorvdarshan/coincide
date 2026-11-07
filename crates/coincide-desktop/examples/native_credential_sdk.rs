//! Fresh-runner-only native SDK acceptance. Not a production command or approval route.
//! Run explicitly with COINCIDE_SYNTHETIC_FILL_SDK=1 on an isolated GitHub runner.
//! No password manager is instantiated; the command backend below is synthetic.
#[allow(dead_code)] // Reuse the production boundary without its unrelated app callers.
#[path = "../src/browser_credentials.rs"]
mod browser_credentials;
#[allow(dead_code)] // Reuse the production boundary without its unrelated app callers.
#[path = "../src/credentials.rs"]
mod credentials;
#[cfg(target_os = "linux")]
#[allow(dead_code)] // Only the secret-free probe body is mirrored for diagnostics.
#[path = "../src/browser_credential_scripts.rs"]
mod probe_scripts;
#[allow(dead_code)] // Reuse the production boundary without its unrelated app callers.
#[path = "../src/browser_shutdown.rs"]
mod shutdown;

use browser_credentials::{BrowserCredentialSink, NativeCredentialTarget};
use coincide_core::credentials::{Failure, Login, Manager, PageBinding, Vault, VaultCommand};
use credentials::{FillJob, deliver_fill, private_fill_channel};
use gpui_kit::{
    App, AppContext, Context, Entity, IntoElement, ParentElement, Render, Styled, Window, div,
};
use shutdown::TrackedEvaluation;
use std::{
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, TryRecvError},
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};
const PASS: &str = "synthetic native fill: PASS (private channel, native isolated world, changed-source denial, actual callback owners returned; native SDK deallocation unconfirmed)";
const URL: &str = "https://credential-fixture.invalid/login.html";
const HTML: &str = r#"<!doctype html><meta charset=utf-8><title>Owned synthetic fill fixture</title>
<form><input id=u autocomplete=username><input id=p type=password autocomplete=current-password></form>
<script>
window.fixture={inputs:0,changes:0,submits:0,setters:0};
const original=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value');
Object.defineProperty(HTMLInputElement.prototype,'value',{configurable:true,get:original.get,set(v){fixture.setters++;original.set.call(this,v)}});
for(const el of document.querySelectorAll('input')) {el.addEventListener('input',()=>fixture.inputs++);el.addEventListener('change',()=>fixture.changes++);}
document.querySelector('form').addEventListener('submit',e=>{e.preventDefault();fixture.submits++});
window.fixtureReady=true;
</script>"#;
// The password carries quote, backslash, template, markup and non-BMP text
// through the typed arguments. It avoids NUL because WebKit's input value
// sanitization may strip control characters, which no fill could confirm.
const VERIFY: &str = r#"(()=>location.href==='https://credential-fixture.invalid/login.html' && document.querySelector('#u').value==='synthetic-user' && document.querySelector('#p').value==='SYNTHETIC-ONLY-"\'\\${x}</script>-\u03bb-\u{1F511}' && fixture.inputs===2 && fixture.changes===2 && fixture.submits===0 && fixture.setters===0)()"#;
struct SyntheticVault;
impl VaultCommand for SyntheticVault {
    fn run(&self, args: &[&str]) -> Result<Vec<u8>, Failure> {
        // Approval and fill both recheck membership through the origin listing.
        if args
            == [
                "list",
                "items",
                "--url",
                "https://credential-fixture.invalid",
                "--nointeraction",
            ]
        {
            return Ok(br#"[{"id":"synthetic-owned-entry","type":1,"name":"Synthetic","login":{"username":"synthetic-user","uris":[{"uri":"https://credential-fixture.invalid"}]}}]"#.to_vec());
        }
        if args != ["get", "item", "synthetic-owned-entry", "--nointeraction"] {
            return Err(Failure::Unavailable);
        }
        Ok(br#"{"login":{"username":"synthetic-user","password":"SYNTHETIC-ONLY-\"'\\${x}</script>-\u03bb-\ud83d\udd11","uris":[{"uri":"https://credential-fixture.invalid"}]}}"#.to_vec())
    }
}
fn binding(navigation: u64) -> PageBinding {
    PageBinding::new("synthetic-owned-tab".into(), navigation, URL).expect("fixed HTTPS fixture")
}
fn worker() -> (mpsc::Receiver<FillJob>, JoinHandle<Result<(), Failure>>) {
    let (mut sink, receiver) = private_fill_channel();
    let handle = std::thread::spawn(move || {
        let vault = Vault::new(Manager::Bitwarden, SyntheticVault);
        // Consent is synthetic, local and unreachable from production IPC. The
        // production human approval UI is not claimed to be tested by this seam.
        let approved = vault.approve(
            &binding(1),
            &Login {
                id: "synthetic-owned-entry".into(),
                title: "Synthetic".into(),
                username: "synthetic-user".into(),
            },
            true,
        )?;
        vault.fill(approved, &binding(1), &mut sink)
    });
    (receiver, handle)
}
struct Fixture {
    view: Entity<gpui_webview::WebView>,
    _context: wry::WebContext,
    target: Option<NativeCredentialTarget>,
    shutdown: shutdown::Shutdown,
    worker: Option<JoinHandle<Result<(), Failure>>>,
    jobs: Option<mpsc::Receiver<FillJob>>,
    read: Option<mpsc::Receiver<bool>>,
    loaded: Arc<AtomicBool>,
    /// Secret-free precondition reports still owed before the fill starts.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    diagnostics: Option<Arc<std::sync::atomic::AtomicUsize>>,
    /// Secret-free post-failure reports (presence and emptiness only).
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    post_diagnostics: Option<Arc<std::sync::atomic::AtomicUsize>>,
    pending_failure: Option<String>,
    stage: u8,
    started: Instant,
    failed: bool,
    deadline_reported: bool,
    result: Arc<Mutex<Option<bool>>>,
}
impl Fixture {
    fn new(
        root: &Path,
        result: Arc<Mutex<Option<bool>>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        // WebKitGTK contexts require GTK first; the view build reuses this init.
        #[cfg(target_os = "linux")]
        {
            gtk::gdk::set_allowed_backends("x11");
            gtk::init().expect("GTK initialization for the owned fixture failed");
        }
        let mut context = wry::WebContext::new(Some(root.join("runtime")));
        // Wry queues scripts evaluated before a view's first commit on macOS and
        // Linux and drops their callbacks, so probe only after the fixture loads.
        let loaded = Arc::new(AtomicBool::new(false));
        let page_loaded = loaded.clone();
        let builder = wry::WebViewBuilder::new_with_web_context(&mut context)
            .with_incognito(true)
            .with_devtools(false)
            .with_clipboard(false)
            .with_autoplay(false)
            .with_navigation_handler(|url| url == URL || url == "about:blank")
            .with_on_page_load_handler(move |event, url| {
                if matches!(event, wry::PageLoadEvent::Finished) && url == URL {
                    page_loaded.store(true, Ordering::Release);
                }
            })
            .with_url("about:blank");
        // The runtime path is fresh and runner-owned; never use a personal WebView2 profile.
        let view = gpui_webview::WebView::build(builder, window, cx)
            .expect("synthetic native view construction failed");
        verify_private(view.raw(), root).expect("owned native private context verification failed");
        let target = NativeCredentialTarget::new(view.raw(), Arc::new(AtomicU64::new(1)))
            .expect("native isolated-world SDK unavailable");
        let mut shutdown = shutdown::Shutdown::default();
        shutdown.ever_native = true;
        let target = target.with_lifetimes(shutdown.callbacks.lifetimes());
        load_fixture(view.raw(), root).expect("owned HTTPS fixture setup failed");
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
        Self {
            view,
            _context: context,
            target: Some(target),
            shutdown,
            worker: None,
            jobs: None,
            read: None,
            loaded,
            diagnostics: None,
            post_diagnostics: None,
            pending_failure: None,
            stage: 0,
            started: Instant::now(),
            failed: false,
            deadline_reported: false,
            result,
        }
    }
    fn evaluate(&mut self, script: &str, cx: &App) {
        let (sender, receiver) = mpsc::sync_channel(1);
        self.read = Some(receiver);
        if self
            .view
            .read(cx)
            .raw()
            .evaluate_script_tracked(script, &self.shutdown.callbacks, move |value| {
                let _ = sender.try_send(serde_json::from_str::<bool>(&value).unwrap_or(false));
            })
            .is_err()
        {
            self.failed = true;
            self.stage = 4;
        }
    }
    /// Diagnostics name a stage only; never a value, page text or secret.
    fn fail(&mut self, reason: &str) {
        eprintln!("synthetic fill failed at stage {}: {reason}", self.stage);
        self.failed = true;
        self.stage = 4;
    }
    /// The sink lives on the worker, so a closed queue means it returned
    /// before queueing its job and will never deliver one.
    fn take_job(&mut self) -> Option<FillJob> {
        match self.jobs.as_ref()?.try_recv() {
            Ok(job) => Some(job),
            Err(TryRecvError::Empty) => None,
            Err(TryRecvError::Disconnected) => {
                let outcome = self.worker.take().map(|worker| worker.join());
                self.jobs = None;
                self.fail(&format!("worker ended before delivery: {outcome:?}"));
                None
            }
        }
    }
    /// Linux reports the probe's preconditions in the page and private worlds
    /// once, before any secret exists, so a failed fill names its cause.
    #[cfg(target_os = "linux")]
    fn diagnosed(&mut self, cx: &App) -> bool {
        use std::sync::atomic::AtomicUsize;
        use webkit2gtk::WebViewExt;
        use wry::WebViewExtUnix;
        if let Some(pending) = &self.diagnostics {
            return pending.load(Ordering::Acquire) == 0;
        }
        let pending = Arc::new(AtomicUsize::new(2));
        self.diagnostics = Some(pending.clone());
        let body = format!(
            r#"const inputs=[...document.querySelectorAll('input')];
const facts={{origin:location.origin, originMatches:location.origin===expectedOrigin, top:window.top===window, pageReady:window.fixtureReady===true,
  inputs:inputs.map(el=>[el instanceof HTMLInputElement, el.type, el.autocomplete, el.disabled, el.readOnly, el.isConnected, el.getClientRects().length, getComputedStyle(el).visibility])}};
facts.probe=await (async()=>{{ {} }})();
delete globalThis.__coincidePrivateFill;
return JSON.stringify(facts);"#,
            probe_scripts::PROBE
        );
        let arguments = webkit2gtk::glib::VariantDict::new(None);
        arguments.insert("ticket", "diagnostic-only");
        arguments.insert("expectedOrigin", "https://credential-fixture.invalid");
        arguments.insert("hasOtp", "no");
        let arguments = arguments.end();
        let view = self.view.read(cx).raw().webview();
        for (label, world) in [
            ("page", None),
            ("private", Some("CoincidePrivateCredentialFillV1")),
        ] {
            let pending = pending.clone();
            view.call_async_javascript_function(
                &body,
                Some(&arguments),
                world,
                None,
                None::<&webkit2gtk::gio::Cancellable>,
                move |result| {
                    match result {
                        Ok(value) => {
                            use java_script_core::ValueExt;
                            eprintln!("linux probe preconditions ({label}): {}", value.to_str())
                        }
                        Err(error) => {
                            eprintln!("linux probe preconditions ({label}) error: {error}")
                        }
                    }
                    pending.fetch_sub(1, Ordering::AcqRel);
                },
            );
        }
        false
    }
    #[cfg(not(target_os = "linux"))]
    fn diagnosed(&mut self, _: &App) -> bool {
        true
    }
    /// After a failed Linux fill, report whether the private probe binding
    /// survived and whether each field is still empty; never a field value.
    #[cfg(target_os = "linux")]
    fn reported_after_failure(&mut self, cx: &App) -> bool {
        use std::sync::atomic::AtomicUsize;
        use webkit2gtk::WebViewExt;
        use wry::WebViewExtUnix;
        if let Some(pending) = &self.post_diagnostics {
            return pending.load(Ordering::Acquire) == 0;
        }
        let pending = Arc::new(AtomicUsize::new(2));
        self.post_diagnostics = Some(pending.clone());
        let view = self.view.read(cx).raw().webview();
        for (label, world, body) in [
            (
                "private",
                Some("CoincidePrivateCredentialFillV1"),
                "return JSON.stringify({bindingPresent:!!globalThis.__coincidePrivateFill, userEmpty:document.querySelector('#u').value==='', passwordEmpty:document.querySelector('#p').value===''});",
            ),
            ("page", None, "return JSON.stringify(window.fixture);"),
        ] {
            let pending = pending.clone();
            view.call_async_javascript_function(
                body,
                None,
                world,
                None,
                None::<&webkit2gtk::gio::Cancellable>,
                move |result| {
                    match result {
                        Ok(value) => {
                            use java_script_core::ValueExt;
                            eprintln!(
                                "linux state after failed fill ({label}): {}",
                                value.to_str()
                            )
                        }
                        Err(error) => {
                            eprintln!("linux state after failed fill ({label}) error: {error}")
                        }
                    }
                    pending.fetch_sub(1, Ordering::AcqRel);
                },
            );
        }
        false
    }
    #[cfg(not(target_os = "linux"))]
    fn reported_after_failure(&mut self, _: &App) -> bool {
        true
    }
    fn poll(&mut self, cx: &mut Context<Self>) -> bool {
        if let Some(target) = &self.target {
            target.poll_ownership();
        }
        if self.started.elapsed() > Duration::from_secs(30) && !self.deadline_reported {
            // A deadline is a failure, never a native callback/deallocation ACK.
            self.deadline_reported = true;
            eprintln!(
                "synthetic fill deadline exceeded at stage {} (fixture loaded: {}); retaining pending callback owners",
                self.stage,
                self.loaded.load(Ordering::Acquire)
            );
            self.failed = true;
            self.stage = 4;
            self.jobs = None;
            if let Some(target) = &self.target {
                target.close();
            }
        }
        match self.stage {
            0 => {
                if self.read.is_none() {
                    if self.loaded.load(Ordering::Acquire) {
                        self.evaluate("window.fixtureReady===true", cx);
                    }
                } else {
                    match self.read.as_ref().unwrap().try_recv() {
                        Ok(ready) => {
                            self.read = None;
                            if ready && self.diagnosed(cx) {
                                let (jobs, worker) = worker();
                                self.jobs = Some(jobs);
                                self.worker = Some(worker);
                                self.stage = 1;
                            }
                        }
                        Err(TryRecvError::Disconnected) => self.fail("readiness callback dropped"),
                        Err(TryRecvError::Empty) => {}
                    }
                }
            }
            1 => {
                if let Some(job) = self.take_job() {
                    let mut hook = BrowserCredentialSink::new(|_: &str| Ok(binding(1)))
                        .with_target(self.target.clone());
                    let callbacks = self.shutdown.callbacks.clone();
                    hook = hook.with_completion_tracker(move || {
                        let ack = callbacks.begin();
                        Box::new(move || ack.ack())
                    });
                    deliver_fill(job, &mut hook);
                    self.stage = 2;
                }
            }
            2 => {
                if self
                    .worker
                    .as_ref()
                    .is_some_and(|worker| worker.is_finished())
                {
                    let outcome = self.worker.take().unwrap().join().ok();
                    if outcome != Some(Ok(())) {
                        self.pending_failure = Some(format!("fill returned {outcome:?}"));
                        self.stage = 7;
                    } else {
                        self.evaluate(VERIFY, cx);
                        self.stage = 3;
                    }
                }
            }
            3 => match self.read.as_ref().map(|read| read.try_recv()) {
                Some(Ok(value)) => {
                    self.read = None;
                    if !value {
                        eprintln!("synthetic fill verification returned false");
                    }
                    self.failed |= !value;
                    // Exercise the real channel's native source recheck without dispatching a second secret.
                    let (jobs, worker) = worker();
                    self.jobs = Some(jobs);
                    self.worker = Some(worker);
                    self.stage = 5;
                }
                Some(Err(TryRecvError::Disconnected)) => self.fail("verification callback dropped"),
                _ => {}
            },
            5 => {
                if let Some(job) = self.take_job() {
                    let mut hook = BrowserCredentialSink::new(|_: &str| Ok(binding(2)))
                        .with_target(self.target.clone());
                    deliver_fill(job, &mut hook);
                    self.stage = 6;
                }
            }
            6 => {
                if self
                    .worker
                    .as_ref()
                    .is_some_and(|worker| worker.is_finished())
                {
                    let outcome = self.worker.take().unwrap().join().ok();
                    if outcome != Some(Err(Failure::StalePage)) {
                        self.fail(&format!("changed source returned {outcome:?}"));
                    }
                    self.stage = 4;
                }
            }
            7 => {
                if self.reported_after_failure(cx) {
                    let reason = self.pending_failure.take().unwrap_or_default();
                    self.fail(&reason);
                }
            }
            _ => {}
        }
        if self.stage == 4 {
            if let Some(target) = &self.target {
                target.close();
            }
            if self
                .worker
                .as_ref()
                .is_some_and(|worker| worker.is_finished())
            {
                let _ = self.worker.take().unwrap().join();
            }
            if self
                .target
                .as_ref()
                .is_some_and(|target| target.poll_ownership())
            {
                self.target = None;
            }
            let status = self.shutdown.status(0, 1, 1);
            if self.worker.is_none()
                && self.target.is_none()
                && status.callbacks_pending == 0
                && status.callback_blocks_pending == 0
                && status.native_targets_pending == 0
            {
                *self.result.lock().unwrap() = Some(!self.failed);
                // macOS quits through NSApplication terminate, which exits inside
                // the run loop, so report here rather than after `run` returns.
                if self.failed {
                    eprintln!("synthetic native fill fixture did not pass");
                } else {
                    println!("{PASS}");
                }
                // Only Rust callback/worker owners are drained. SDK view/context
                // deallocation remains Unknown; runner teardown owns the profile.
                cx.quit();
                return true;
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
#[cfg(target_os = "linux")]
fn verify_private(view: &wry::WebView, _: &Path) -> anyhow::Result<()> {
    use webkit2gtk::{WebContextExt, WebViewExt};
    use wry::WebViewExtUnix;
    let context = view
        .webview()
        .context()
        .ok_or_else(|| anyhow::anyhow!("native context missing"))?;
    anyhow::ensure!(context.is_ephemeral(), "native context is not ephemeral");
    Ok(())
}
#[cfg(target_os = "macos")]
fn verify_private(view: &wry::WebView, _: &Path) -> anyhow::Result<()> {
    use objc2::rc::Retained;
    use objc2_web_kit::WKWebView;
    use wry::WebViewExtMacOS;
    let native: Retained<WKWebView> = view.webview().into_super();
    anyhow::ensure!(
        !unsafe { native.configuration().websiteDataStore().isPersistent() },
        "native store is persistent"
    );
    Ok(())
}
#[cfg(target_os = "windows")]
fn verify_private(view: &wry::WebView, root: &Path) -> anyhow::Result<()> {
    use webview2_com::Microsoft::Web::WebView2::Win32::ICoreWebView2_13;
    use windows::core::{BOOL, Interface, PWSTR};
    use wry::WebViewExtWindows;
    unsafe {
        let profile = view.webview().cast::<ICoreWebView2_13>()?.Profile()?;
        let mut private = BOOL::default();
        profile.IsInPrivateModeEnabled(&mut private)?;
        anyhow::ensure!(private.as_bool(), "native profile is not private");
        let mut raw = PWSTR::null();
        profile.ProfilePath(&mut raw)?;
        let path =
            PathBuf::from(webview2_com::CoTaskMemPWSTR::from(raw).to_string()).canonicalize()?;
        anyhow::ensure!(
            path.starts_with(root.canonicalize()?),
            "native profile escaped the owned runtime"
        );
    }
    Ok(())
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
    std::fs::write(root.join("login.html"), HTML)?;
    let native: ICoreWebView2_3 = view.webview().cast()?;
    unsafe {
        native.SetVirtualHostNameToFolderMapping(
            &HSTRING::from("credential-fixture.invalid"),
            &HSTRING::from(root.to_string_lossy().as_ref()),
            COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS,
        )?;
    }
    view.load_url(URL)?;
    Ok(())
}
fn fresh_runner_root() -> anyhow::Result<PathBuf> {
    anyhow::ensure!(
        std::env::var("COINCIDE_SYNTHETIC_FILL_SDK").as_deref() == Ok("1")
            && std::env::var("GITHUB_ACTIONS").as_deref() == Ok("true")
            && std::env::var("RUNNER_ENVIRONMENT").as_deref() == Ok("github-hosted"),
        "explicit fresh GitHub-hosted fixture opt-in required"
    );
    let runner = std::fs::canonicalize(
        std::env::var_os("RUNNER_TEMP").ok_or_else(|| anyhow::anyhow!("runner temp required"))?,
    )?;
    let root = tempfile::Builder::new()
        .prefix("owned-synthetic-fill-")
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
    let result = Arc::new(Mutex::new(None));
    let observed = result.clone();
    #[cfg(target_os = "linux")]
    let app = gpui_kit::platform::linux(gpui_kit::WindowingModes::X11);
    #[cfg(not(target_os = "linux"))]
    let app = gpui_kit::application();
    app.run(move |cx| {
        gpui_kit::init(cx);
        gpui_kit::open_window(Default::default(), cx, |window, cx| {
            cx.new(|cx| Fixture::new(&root, result, window, cx))
        })
        .expect("owned fixture window unavailable");
        cx.activate(true);
    });
    // Reached on Linux and Windows only; the fixture already printed its result.
    anyhow::ensure!(
        *observed.lock().unwrap() == Some(true),
        "synthetic native fill fixture did not pass"
    );
    Ok(())
}
