//! Fresh-runner-only native WebView screenshot acceptance. Not a production
//! command. Run explicitly with COINCIDE_SYNTHETIC_SCREENSHOT=1 on an isolated
//! GitHub-hosted runner. It loads only its own fixed document in a private
//! WebView and drives the production snapshot owner, mask transaction, native
//! SDK adapter, redaction worker and artifact directory.
#[allow(dead_code)] // Reuse the production boundary without its unrelated app callers.
#[path = "../src/worker_owner.rs"]
mod worker_owner;

#[allow(dead_code)]
#[path = "../src/browser_screenshot_native.rs"]
mod screenshot_native;
#[allow(dead_code)]
#[path = "../src/browser_screenshots.rs"]
mod screenshots;
#[allow(dead_code)]
#[path = "../src/browser_shutdown.rs"]
mod shutdown;

mod fixture {
    use super::{screenshots, shutdown};
    use coincide_core::browser_protocol::{BrowserAction, BrowserRequest};
    use gpui_kit::{App, AppContext, Context, Entity, IntoElement, ParentElement, Render, Styled};
    use serde::Deserialize;
    use serde_json::Value;
    use shutdown::TrackedEvaluation;
    use std::{
        path::Path,
        sync::{
            Arc, Mutex,
            atomic::{AtomicBool, AtomicU64},
            mpsc,
        },
        time::{Duration, Instant},
    };

    pub const URL: &str = "https://screenshot-fixture.invalid/page.html";
    pub const HTML: &str = r#"<!doctype html><meta charset=utf-8><title>Owned screenshot fixture</title>
<style>
html,body{margin:0;background:#fff}
body{position:relative;height:6000px}
#top{height:200px;background:rgb(255,0,0)}
input{display:block;box-sizing:border-box;width:300px;height:44px;margin:10px;font:20px sans-serif;color:#000;background:#fff;border:2px solid #000}
.block{position:absolute;left:0;width:100%;height:200px}
#middle{top:3000px;background:rgb(0,0,255)}
#bottom{top:5790px;background:rgb(0,160,0)}
</style>
<div id=top></div>
<form><input id=user autocomplete=username value="synthetic-user"><input id=pass type=password value="SYNTHETIC-ONLY-secret"><input id=otp autocomplete=one-time-code value="135790"></form>
<input id=search value="visible search text">
<div id=middle class=block></div><div id=bottom class=block></div>
<script>window.fixtureReady=true;</script>"#;
    const LAYOUT: &str = r#"JSON.stringify((()=>{const r=id=>{const b=document.getElementById(id).getBoundingClientRect();return {x:b.x+scrollX,y:b.y+scrollY,width:b.width,height:b.height};};return {innerWidth,innerHeight,user:r('user'),pass:r('pass'),otp:r('otp'),search:r('search')};})())"#;
    const RESTORED: &str = r#"scrollY===2950 && [...document.querySelectorAll('input')].every(el=>el.style.opacity===''&&el.style.transition==='')"#;

    pub type Outcome = Arc<Mutex<Option<Result<Vec<String>, String>>>>;
    #[derive(Clone, Copy, Deserialize)]
    struct Box2 {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    }
    #[derive(Clone, Copy, Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Layout {
        inner_width: f64,
        inner_height: f64,
        user: Box2,
        pass: Box2,
        otp: Box2,
        search: Box2,
    }

    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    enum Stage {
        Ready,
        Layout,
        Viewport,
        Scroll,
        Scrolled,
        FullPage,
        Restored,
        Grow,
        Truncated,
        Drain,
    }

    pub struct Fixture {
        view: Entity<gpui_webview::WebView>,
        _context: wry::WebContext,
        owner: screenshots::Owner,
        shutdown: shutdown::Shutdown,
        navigation: Arc<AtomicU64>,
        protected: Arc<AtomicBool>,
        console: Arc<AtomicBool>,
        read: Option<mpsc::Receiver<String>>,
        layout: Option<Layout>,
        stage: Stage,
        reported: Option<Stage>,
        pending: bool,
        started: Instant,
        waited: Instant,
        checks: Vec<String>,
        failure: Option<String>,
        result: Outcome,
    }
    impl Fixture {
        pub fn new(
            root: &Path,
            result: Outcome,
            window: &mut gpui_kit::Window,
            cx: &mut Context<Self>,
        ) -> Self {
            // As in BrowserController::new: WebKitGTK contexts need GTK first.
            #[cfg(target_os = "linux")]
            gtk::init().expect("GTK initialization failed");
            let mut context = wry::WebContext::new(Some(root.join("runtime")));
            let builder = wry::WebViewBuilder::new_with_web_context(&mut context)
                .with_incognito(true)
                .with_devtools(false)
                .with_clipboard(false)
                .with_autoplay(false)
                .with_navigation_handler(|url| url == URL || url == "about:blank")
                .with_url("about:blank");
            // The runtime path is fresh and runner-owned; never a personal profile.
            let view = gpui_webview::WebView::build(builder, window, cx)
                .expect("synthetic native view construction failed");
            super::load_fixture(view.raw(), root).expect("owned fixture setup failed");
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
            let mut shutdown = shutdown::Shutdown::default();
            shutdown.ever_native = true;
            Self {
                view,
                _context: context,
                owner: screenshots::Owner::new(root.join("screenshots")),
                shutdown,
                navigation: Arc::new(AtomicU64::new(1)),
                protected: Arc::new(AtomicBool::new(false)),
                console: Arc::new(AtomicBool::new(false)),
                read: None,
                layout: None,
                stage: Stage::Ready,
                reported: None,
                pending: false,
                started: Instant::now(),
                waited: Instant::now(),
                checks: Vec::new(),
                failure: None,
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
                    let _ = sender.try_send(value);
                })
                .is_err()
            {
                self.fail("fixture evaluation dispatch failed");
            }
        }
        fn evaluated(&mut self) -> Option<String> {
            let value = self.read.as_ref()?.try_recv().ok()?;
            self.read = None;
            Some(value)
        }
        fn fail(&mut self, error: impl Into<String>) {
            if self.failure.is_none() {
                let failure = format!("{:?}: {}", self.stage, error.into());
                eprintln!("synthetic native screenshot failure: {failure}");
                self.failure = Some(failure);
            }
            self.stage = Stage::Drain;
        }
        fn shoot(&mut self, full_page: bool, cx: &App) {
            let request = BrowserRequest {
                id: uuid::Uuid::new_v4().to_string(),
                thread_id: uuid::Uuid::new_v4().to_string(),
                tab: None,
                frame: None,
                action: BrowserAction::Screenshot { full_page },
            };
            let started = self.owner.begin(
                request,
                "fixture-tab".into(),
                URL.into(),
                self.view.read(cx).raw(),
                self.navigation.clone(),
                self.protected.clone(),
                self.shutdown.callbacks.clone(),
                self.console.clone(),
                full_page,
            );
            match started {
                Ok(()) => self.pending = true,
                Err(error) => self.fail(format!("screenshot admission: {error}")),
            }
        }
        /// Some(reply) once the production owner published or refused.
        fn reply(&mut self) -> Option<Value> {
            let reply = self.owner.poll(&self.shutdown.callbacks, |binding| {
                binding.url == URL && binding.tab == "fixture-tab"
            })?;
            self.pending = false;
            Some(reply.result)
        }
        fn verify(&mut self, result: &Value, full_page: bool, scrolled: f64, truncated: bool) {
            match check(
                result,
                self.layout.expect("layout"),
                full_page,
                scrolled,
                truncated,
            ) {
                Ok(note) => self.checks.push(note),
                Err(error) => self.fail(error),
            }
        }
        fn poll(&mut self, cx: &mut Context<Self>) -> bool {
            if self.reported != Some(self.stage) {
                self.reported = Some(self.stage);
                println!(
                    "synthetic native screenshot stage {:?} at {:.1}s",
                    self.stage,
                    self.started.elapsed().as_secs_f64()
                );
            }
            if self.started.elapsed() > Duration::from_secs(90) && self.stage != Stage::Drain {
                // A deadline is a failure, never a native callback ACK.
                self.fail(format!(
                    "fixture deadline exceeded (evaluation pending: {}, screenshot pending: {}); retaining pending callback owners",
                    self.read.is_some(),
                    self.pending
                ));
            }
            match self.stage {
                Stage::Ready => {
                    if self.read.is_none() && super::native_loaded(self.view.read(cx).raw()) {
                        self.evaluate(
                            "window.fixtureReady===true&&document.readyState==='complete'&&location.href==='https://screenshot-fixture.invalid/page.html'",
                            cx,
                        );
                    } else if let Some(value) = self.evaluated()
                        && parsed(&value) == Value::Bool(true)
                    {
                        self.stage = Stage::Layout;
                    }
                }
                Stage::Layout => {
                    if self.read.is_none() {
                        self.evaluate(LAYOUT, cx);
                    } else if let Some(value) = self.evaluated() {
                        match decode::<Layout>(&value) {
                            Some(layout) => {
                                self.layout = Some(layout);
                                self.stage = Stage::Viewport;
                            }
                            None => self.fail(format!("fixture layout unreadable: {value}")),
                        }
                    }
                }
                Stage::Viewport | Stage::Scrolled | Stage::FullPage | Stage::Truncated => {
                    let (full_page, scrolled, truncated) = match self.stage {
                        Stage::Viewport => (false, 0., false),
                        Stage::Scrolled => (false, 2950., false),
                        Stage::FullPage => (true, 0., false),
                        _ => (true, 0., true),
                    };
                    if !self.pending {
                        self.shoot(full_page, cx);
                    } else if let Some(result) = self.reply() {
                        self.verify(&result, full_page, scrolled, truncated);
                        self.waited = Instant::now();
                        self.stage = match self.stage {
                            Stage::Viewport => Stage::Scroll,
                            Stage::Scrolled => Stage::FullPage,
                            Stage::FullPage => Stage::Restored,
                            Stage::Truncated => Stage::Drain,
                            stage => stage,
                        };
                    }
                }
                Stage::Scroll => {
                    if self.read.is_none() {
                        self.evaluate("scrollTo(0,2950);scrollY", cx);
                    } else if let Some(value) = self.evaluated() {
                        if parsed(&value).as_f64() == Some(2950.) {
                            self.stage = Stage::Scrolled;
                        } else {
                            self.fail(format!("fixture scroll failed: {value}"));
                        }
                    }
                }
                Stage::Restored => {
                    // The reader's scroll position and every masked style
                    // return after a full-page capture.
                    if self.read.is_none() {
                        self.evaluate(RESTORED, cx);
                    } else if let Some(value) = self.evaluated() {
                        if parsed(&value) == Value::Bool(true) {
                            self.checks.push("scroll and field styles restored".into());
                            self.stage = Stage::Grow;
                        } else if self.waited.elapsed() > Duration::from_secs(5) {
                            self.fail("scroll position or field styles were not restored");
                        }
                    }
                }
                Stage::Grow => {
                    if self.read.is_none() {
                        self.evaluate(
                            "scrollTo(0,0);document.body.style.height='30000px';document.documentElement.scrollHeight",
                            cx,
                        );
                    } else if let Some(value) = self.evaluated() {
                        if parsed(&value).as_f64() == Some(30000.) {
                            self.stage = Stage::Truncated;
                        } else {
                            self.fail(format!("fixture growth failed: {value}"));
                        }
                    }
                }
                Stage::Drain => {
                    self.owner.close();
                    if self
                        .owner
                        .poll(&self.shutdown.callbacks, |_| false)
                        .is_some()
                    {
                        self.pending = false;
                    }
                    let status = self.shutdown.status(0, 1, 1);
                    if !self.pending
                        && self.read.is_none()
                        && status.callbacks_pending == 0
                        && status.callback_blocks_pending == 0
                        && status.native_targets_pending == 0
                    {
                        *self.result.lock().unwrap() = Some(match self.failure.take() {
                            Some(error) => Err(error),
                            None => Ok(std::mem::take(&mut self.checks)),
                        });
                        // Only Rust callback/worker owners are drained. SDK view/context
                        // deallocation remains Unknown; runner teardown owns the profile.
                        cx.quit();
                        return true;
                    }
                    if self.read.is_some() {
                        let _ = self.evaluated();
                    }
                    if self.started.elapsed() > Duration::from_secs(150) {
                        // Report the retained owners and fail; exiting is never a
                        // claimed native return.
                        eprintln!(
                            "synthetic native screenshot: FAIL, owners still pending after the deadline: {status:?}"
                        );
                        std::process::exit(2);
                    }
                }
            }
            false
        }
    }
    impl Render for Fixture {
        fn render(&mut self, _: &mut gpui_kit::Window, _: &mut Context<Self>) -> impl IntoElement {
            gpui_kit::div().size_full().child(self.view.clone())
        }
    }
    /// Native evaluation results arrive JSON-encoded on every host.
    fn parsed(value: &str) -> Value {
        serde_json::from_str(value).unwrap_or(Value::Null)
    }
    fn decode<T: for<'de> Deserialize<'de>>(value: &str) -> Option<T> {
        // The layout script returns a JSON string inside that encoding.
        let text = serde_json::from_str::<String>(value).ok()?;
        serde_json::from_str(&text).ok()
    }
    fn check(
        result: &Value,
        layout: Layout,
        full_page: bool,
        scrolled: f64,
        truncated: bool,
    ) -> Result<String, String> {
        let path = result["path"]
            .as_str()
            .ok_or_else(|| format!("no screenshot: {result}"))?;
        if result["mimeType"] != "image/png"
            || result["fullPage"] != full_page
            || result["truncated"] != truncated
        {
            return Err(format!("unexpected reply fields: {result}"));
        }
        let image = image::open(path)
            .map_err(|error| format!("unreadable PNG: {error}"))?
            .into_rgba8();
        let (width, height) = image.dimensions();
        if Some(u64::from(width)) != result["width"].as_u64()
            || Some(u64::from(height)) != result["height"].as_u64()
            || width > 1600
        {
            return Err(format!("PNG size {width}x{height} disagrees: {result}"));
        }
        // Device pixels per CSS pixel, from the image width and viewport.
        let scale = f64::from(width) / layout.inner_width;
        let css_height = if truncated {
            20_000.
        } else if full_page {
            6000.
        } else {
            layout.inner_height
        };
        let expected = css_height * scale;
        if (f64::from(height) - expected).abs() > 2. + 0.02 * expected {
            return Err(format!(
                "PNG height {height} is not {css_height} CSS px at {scale:.3}x ({width}x{height})"
            ));
        }
        let pixel = |x: f64, y: f64| {
            let (x, y) = ((x * scale) as u32, ((y - scrolled) * scale) as u32);
            (x < width && y < height).then(|| image.get_pixel(x, y).0)
        };
        let center = |b: Box2| (b.x + b.width / 2., b.y + b.height / 2.);
        if scrolled == 0. {
            let red = pixel(100., 100.).ok_or("red sample outside image")?;
            if red[0] < 180 || red[1] > 90 || red[2] > 90 {
                return Err(format!("expected the red top block, saw {red:?}"));
            }
            for (name, field) in [
                ("username", layout.user),
                ("password", layout.pass),
                ("one-time code", layout.otp),
            ] {
                let (x, y) = center(field);
                for (dx, dy) in [(0., 0.), (-field.width / 3., 0.), (field.width / 3., 0.)] {
                    let seen = pixel(x + dx, y + dy).ok_or("field sample outside image")?;
                    if seen != [32, 32, 32, 255] {
                        return Err(format!("{name} field was not redacted: {seen:?}"));
                    }
                }
            }
            // An ordinary field stays visible: its white interior, right of its text.
            let search = layout.search;
            let seen = pixel(search.x + search.width - 20., search.y + search.height / 2.)
                .ok_or("search sample outside image")?;
            if seen.iter().take(3).any(|channel| *channel < 200) {
                return Err(format!("ordinary field was masked or missing: {seen:?}"));
            }
        }
        if full_page || scrolled > 0. {
            let blue = pixel(100., 3100.).ok_or("blue sample outside image")?;
            if blue[2] < 180 || blue[0] > 90 || blue[1] > 90 {
                return Err(format!("expected the blue middle block, saw {blue:?}"));
            }
        }
        if full_page && !truncated {
            let green = pixel(100., 5890.).ok_or("green sample outside image")?;
            if green[1] < 120 || green[0] > 90 || green[2] > 90 {
                return Err(format!("expected the green bottom block, saw {green:?}"));
            }
        }
        Ok(format!(
            "{} {}x{} truncated={truncated}",
            match (full_page, scrolled > 0.) {
                (true, _) => "full-page",
                (false, true) => "scrolled-viewport",
                (false, false) => "viewport",
            },
            width,
            height
        ))
    }
}

use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

/// Wry queues evaluations issued before the first navigation starts (macOS)
/// or commits (Linux) and drops their callbacks; evaluate only once the
/// native view finished loading the fixture page.
#[cfg(target_os = "linux")]
fn native_loaded(view: &wry::WebView) -> bool {
    use webkit2gtk::WebViewExt;
    use wry::WebViewExtUnix;
    let view = view.webview();
    !view.is_loading() && view.uri().is_some_and(|uri| uri.as_str() == fixture::URL)
}
#[cfg(target_os = "macos")]
fn native_loaded(view: &wry::WebView) -> bool {
    use objc2::rc::Retained;
    use objc2_web_kit::WKWebView;
    use wry::WebViewExtMacOS;
    let native: Retained<WKWebView> = view.webview().into_super();
    // SAFETY: UI thread, retained view, nullable getters.
    unsafe {
        !native.isLoading()
            && native
                .URL()
                .and_then(|url| url.absoluteString())
                .is_some_and(|url| url.to_string() == fixture::URL)
    }
}
#[cfg(target_os = "windows")]
fn native_loaded(_: &wry::WebView) -> bool {
    true
}
#[cfg(target_os = "linux")]
fn load_fixture(view: &wry::WebView, _: &Path) -> anyhow::Result<()> {
    use webkit2gtk::WebViewExt;
    use wry::WebViewExtUnix;
    view.webview().load_html(fixture::HTML, Some(fixture::URL));
    Ok(())
}
#[cfg(target_os = "macos")]
fn load_fixture(view: &wry::WebView, _: &Path) -> anyhow::Result<()> {
    use objc2::rc::Retained;
    use objc2_foundation::{NSString, NSURL};
    use objc2_web_kit::WKWebView;
    use wry::WebViewExtMacOS;
    let native: Retained<WKWebView> = view.webview().into_super();
    let url = NSURL::URLWithString(&NSString::from_str(fixture::URL))
        .ok_or_else(|| anyhow::anyhow!("fixed HTTPS URL unavailable"))?;
    unsafe {
        native.loadHTMLString_baseURL(&NSString::from_str(fixture::HTML), Some(&url));
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
    let pages = root.join("pages");
    std::fs::create_dir_all(&pages)?;
    std::fs::write(pages.join("page.html"), fixture::HTML)?;
    let native: ICoreWebView2_3 = view.webview().cast()?;
    unsafe {
        native.SetVirtualHostNameToFolderMapping(
            &HSTRING::from("screenshot-fixture.invalid"),
            &HSTRING::from(pages.to_string_lossy().as_ref()),
            COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS,
        )?;
    }
    view.load_url(fixture::URL)?;
    Ok(())
}
fn fresh_runner_root() -> anyhow::Result<PathBuf> {
    anyhow::ensure!(
        std::env::var("COINCIDE_SYNTHETIC_SCREENSHOT").as_deref() == Ok("1")
            && std::env::var("GITHUB_ACTIONS").as_deref() == Ok("true")
            && std::env::var("RUNNER_ENVIRONMENT").as_deref() == Ok("github-hosted"),
        "explicit fresh GitHub-hosted fixture opt-in required"
    );
    let runner = std::fs::canonicalize(
        std::env::var_os("RUNNER_TEMP").ok_or_else(|| anyhow::anyhow!("runner temp required"))?,
    )?;
    let root = tempfile::Builder::new()
        .prefix("owned-synthetic-screenshot-")
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
    use gpui_kit::AppContext;
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
            cx.new(|cx| fixture::Fixture::new(&root, result, window, cx))
        })
        .expect("owned fixture window unavailable");
        cx.activate(true);
    });
    let outcome = observed
        .lock()
        .unwrap()
        .take()
        .ok_or_else(|| anyhow::anyhow!("synthetic native screenshot fixture did not finish"))?;
    match outcome {
        Ok(checks) => {
            println!(
                "synthetic native screenshot: PASS ({}; masked fields redacted, ordinary field visible; actual callback owners returned; native SDK deallocation unconfirmed)",
                checks.join("; ")
            );
            Ok(())
        }
        Err(error) => anyhow::bail!("synthetic native screenshot fixture failed: {error}"),
    }
}
