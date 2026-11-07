//! Fresh-runner-only acceptance of production native shortcut callbacks.
//! Never run on a personal desktop: the guard precedes all UI and key APIs.
#[allow(dead_code)]
#[path = "../src/browser_tab_shortcuts.rs"]
mod browser_tab_shortcuts;
#[allow(dead_code)]
#[path = "../src/browser_tab_shortcuts_native.rs"]
mod native_shortcuts;
#[allow(dead_code)]
#[path = "../src/browser_shutdown.rs"]
mod shutdown;
use browser_tab_shortcuts::Command;
use gpui_kit::{
    AppContext, Context, Entity, IntoElement, ParentElement, Render, Styled, Window, div,
};
use std::{
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
const PASS: &str = "synthetic native tab shortcuts: PASS (four fixed chords, exact focused view, hidden sibling, plain-key refusal, shutdown fence, captured callback owners returned; native SDK deallocation unconfirmed)";
#[derive(Clone, Copy)]
struct Case {
    view: usize,
    command: Command,
    primary: bool,
    expected: bool,
}
fn cases() -> Vec<Case> {
    vec![
        Case {
            view: 0,
            command: Command::New,
            primary: true,
            expected: true,
        },
        Case {
            view: 0,
            command: Command::Next,
            primary: true,
            expected: true,
        },
        Case {
            view: 0,
            command: Command::Previous,
            primary: true,
            expected: true,
        },
        Case {
            view: 0,
            command: Command::Close,
            primary: true,
            expected: true,
        },
        Case {
            view: 1,
            command: Command::New,
            primary: true,
            expected: true,
        },
        Case {
            view: 1,
            command: Command::Close,
            primary: true,
            expected: true,
        },
        Case {
            view: 1,
            command: Command::New,
            primary: false,
            expected: false,
        },
        Case {
            view: 1,
            command: Command::New,
            primary: true,
            expected: false,
        },
    ]
}
struct Waiting {
    case: Case,
    started: Instant,
    guard: Option<KeyGuard>,
}
struct Fixture {
    views: Vec<Entity<gpui_webview::WebView>>,
    _context: wry::WebContext,
    loaded: Vec<Arc<AtomicBool>>,
    targets: Vec<native_shortcuts::Target>,
    shutdown: shutdown::Shutdown,
    received: mpsc::Receiver<(usize, Command, u64, Option<String>)>,
    cases: Vec<Case>,
    index: usize,
    focused: Option<Instant>,
    waiting: Option<Waiting>,
    started: Instant,
    draining: Option<Instant>,
    failure: Option<String>,
    result: Arc<Mutex<Option<Result<(), String>>>>,
}
impl Fixture {
    fn new(
        root: &Path,
        result: Arc<Mutex<Option<Result<(), String>>>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        #[cfg(target_os = "linux")]
        gtk::init().expect("owned GTK initialization failed");
        let mut context = wry::WebContext::new(Some(root.join("runtime")));
        let (sender, received) = mpsc::sync_channel(16);
        let mut shutdown = shutdown::Shutdown::default();
        shutdown.ever_native = true;
        let mut views = vec![];
        let mut targets = vec![];
        let mut loaded = vec![];
        for index in 0..2 {
            let ready = Arc::new(AtomicBool::new(false));
            let done = ready.clone();
            let builder = wry::WebViewBuilder::new_with_web_context(&mut context)
                .with_incognito(true)
                .with_devtools(false)
                .with_clipboard(false)
                .with_autoplay(false)
                .with_navigation_handler(|url| url == "about:blank")
                .with_new_window_req_handler(|_, _| wry::NewWindowResponse::Deny)
                .with_on_page_load_handler(move |event, _| {
                    if matches!(event, wry::PageLoadEvent::Finished) {
                        done.store(true, Ordering::Release);
                    }
                })
                .with_url("about:blank");
            let view = gpui_webview::WebView::build(builder, window, cx)
                .expect("owned native view failed");
            let sender = sender.clone();
            let target = native_shortcuts::Target::install(
                view.raw(),
                &shutdown.callbacks,
                Arc::new(AtomicU64::new(1)),
                move |command, epoch, url| sender.try_send((index, command, epoch, url)).is_ok(),
            )
            .expect("production native shortcut callback unavailable");
            targets.push(target);
            loaded.push(ready);
            views.push(cx.new(|_| view));
        }
        cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(25))
                    .await;
                if this.update(cx, |this, cx| this.poll(cx)).unwrap_or(true) {
                    break;
                }
            }
        })
        .detach();
        Self {
            views,
            _context: context,
            loaded,
            targets,
            shutdown,
            received,
            cases: cases(),
            index: 0,
            focused: None,
            waiting: None,
            started: Instant::now(),
            draining: None,
            failure: None,
            result,
        }
    }
    fn fail(&mut self, reason: impl Into<String>) {
        if self.failure.is_none() {
            self.failure = Some(reason.into());
        }
        self.drain();
    }
    fn drain(&mut self) {
        self.waiting = None;
        self.shutdown
            .callbacks
            .closed
            .store(true, Ordering::Release);
        self.targets.clear();
        self.draining.get_or_insert_with(Instant::now);
    }
    fn poll(&mut self, cx: &mut Context<Self>) -> bool {
        if self.started.elapsed() > Duration::from_secs(60) && self.draining.is_none() {
            self.fail("owned shortcut fixture deadline");
        }
        if let Some(since) = self.draining {
            let status = self.shutdown.status(0, self.views.len(), 1);
            if status.callback_blocks_pending == 0 && status.native_targets_pending == 0 {
                let result = self.failure.take().map_or(Ok(()), Err);
                if result.is_ok() {
                    println!("{PASS}");
                } else {
                    println!(
                        "synthetic native tab shortcuts: FAIL ({})",
                        result.as_ref().unwrap_err()
                    );
                }
                *self.result.lock().unwrap() = Some(result);
                cx.quit();
                return true;
            }
            if since.elapsed() > Duration::from_secs(4) {
                *self.result.lock().unwrap() =
                    Some(Err("native callback ownership remained unconfirmed".into()));
                println!(
                    "synthetic native tab shortcuts: FAIL (native callback ownership retained)"
                );
                cx.quit();
                return true;
            }
            return false;
        }
        if self.started.elapsed() < Duration::from_millis(500)
            || !self
                .loaded
                .iter()
                .all(|loaded| loaded.load(Ordering::Acquire))
        {
            return false;
        }
        if let Some(waiting) = &mut self.waiting {
            match self.received.try_recv() {
                Ok((index, command, epoch, url)) => {
                    if !waiting.case.expected
                        || index != waiting.case.view
                        || command != waiting.case.command
                        || epoch != 1
                        || url.as_deref() != Some("about:blank")
                    {
                        self.fail(
                            "native callback crossed its focused view, chord or document binding",
                        );
                        return false;
                    }
                    waiting.guard = None;
                    self.waiting = None;
                    self.focused = None;
                    self.index += 1;
                }
                Err(mpsc::TryRecvError::Empty)
                    if !waiting.case.expected
                        && waiting.started.elapsed() > Duration::from_millis(250) =>
                {
                    waiting.guard = None;
                    self.waiting = None;
                    self.focused = None;
                    self.index += 1;
                }
                Err(mpsc::TryRecvError::Empty)
                    if waiting.started.elapsed() > Duration::from_secs(5) =>
                {
                    self.fail("focused native shortcut returned no receipt");
                }
                Err(mpsc::TryRecvError::Disconnected) => {
                    self.fail("native shortcut channel disconnected")
                }
                _ => {}
            }
            return false;
        }
        if self.index == self.cases.len() {
            self.drain();
            return false;
        }
        let case = self.cases[self.index];
        if self.focused.is_none() {
            if self.index == 4 {
                self.views[0].update(cx, |view, _| view.hide());
            }
            if self.index == 7 {
                self.shutdown
                    .callbacks
                    .closed
                    .store(true, Ordering::Release);
            }
            match focus(self.views[case.view].read(cx).raw()) {
                Ok(()) => self.focused = Some(Instant::now()),
                Err(error) => self.fail(format!("owned view focus failed: {error}")),
            }
        } else if self.focused.unwrap().elapsed() > Duration::from_millis(100) {
            // Exercise the same current-focus predicate production dispatch uses,
            // independently of merely receiving an accelerator callback.
            if !self.targets[case.view].focused(self.views[case.view].read(cx).raw())
                || self.targets[1 - case.view].focused(self.views[1 - case.view].read(cx).raw())
            {
                self.fail(
                    "current native focus did not belong exclusively to the owned selected view",
                );
                return false;
            }
            match key(self.views[case.view].read(cx).raw(), case) {
                Ok(guard) => {
                    self.waiting = Some(Waiting {
                        case,
                        started: Instant::now(),
                        guard: Some(guard),
                    })
                }
                Err(error) => self.fail(format!("owned native key failed: {error}")),
            }
        }
        false
    }
}
impl Render for Fixture {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        div().flex().flex_col().size_full().children(
            self.views
                .iter()
                .map(|view| div().flex_1().min_h_0().w_full().child(view.clone())),
        )
    }
}
#[cfg(not(target_os = "windows"))]
struct KeyGuard;
#[cfg(target_os = "macos")]
fn focus(view: &wry::WebView) -> anyhow::Result<()> {
    use wry::WebViewExtMacOS;
    let window = view
        .webview()
        .window()
        .ok_or_else(|| anyhow::anyhow!("owned native window missing"))?;
    window.makeKeyAndOrderFront(None);
    view.focus()?;
    Ok(())
}
#[cfg(target_os = "macos")]
fn key(view: &wry::WebView, case: Case) -> anyhow::Result<KeyGuard> {
    use objc2::MainThreadMarker;
    use objc2_app_kit::{NSApplication, NSEvent, NSEventModifierFlags, NSEventType};
    use objc2_foundation::{NSPoint, NSString};
    use wry::WebViewExtMacOS;
    let native = view.webview();
    let window = native
        .window()
        .ok_or_else(|| anyhow::anyhow!("owned native window missing"))?;
    let (text, code) = match case.command {
        Command::New => ("t", 17),
        Command::Close => ("w", 13),
        Command::Next => ("]", 30),
        Command::Previous => ("[", 33),
    };
    let mut flags = NSEventModifierFlags::empty();
    if case.primary {
        flags |= NSEventModifierFlags::Command;
    }
    if matches!(case.command, Command::Next | Command::Previous) {
        flags |= NSEventModifierFlags::Shift;
    }
    let event=NSEvent::keyEventWithType_location_modifierFlags_timestamp_windowNumber_context_characters_charactersIgnoringModifiers_isARepeat_keyCode(NSEventType::KeyDown,NSPoint::new(0.,0.),flags,0.,window.windowNumber(),None,&NSString::from_str(text),&NSString::from_str(text),false,code).ok_or_else(||anyhow::anyhow!("owned native key unavailable"))?;
    NSApplication::sharedApplication(MainThreadMarker::new().unwrap())
        .postEvent_atStart(&event, false);
    Ok(KeyGuard)
}
#[cfg(target_os = "linux")]
fn focus(view: &wry::WebView) -> anyhow::Result<()> {
    view.focus()?;
    Ok(())
}
#[cfg(target_os = "linux")]
fn key(view: &wry::WebView, case: Case) -> anyhow::Result<KeyGuard> {
    use gtk::{gdk, glib::translate::*, prelude::*};
    use wry::WebViewExtUnix;
    let view = view.webview();
    let window = view
        .window()
        .ok_or_else(|| anyhow::anyhow!("owned GDK window unavailable"))?;
    let value = match case.command {
        Command::New => gdk::keys::constants::t,
        Command::Close => gdk::keys::constants::w,
        Command::Next => gdk::keys::constants::braceright,
        Command::Previous => gdk::keys::constants::braceleft,
    };
    let mut state = gdk::ModifierType::empty();
    if case.primary {
        state |= gdk::ModifierType::CONTROL_MASK;
    }
    if matches!(case.command, Command::Next | Command::Previous) {
        state |= gdk::ModifierType::SHIFT_MASK;
    }
    let mut event = gdk::Event::new(gdk::EventType::KeyPress);
    let device = view
        .display()
        .default_seat()
        .and_then(|seat| seat.keyboard())
        .ok_or_else(|| anyhow::anyhow!("owned GDK keyboard unavailable"))?;
    event.set_device(Some(&device));
    unsafe {
        let raw: *mut gdk::ffi::GdkEvent = event.to_glib_none().0;
        let key = &mut (*raw).key;
        key.window = window.to_glib_full();
        key.state = state.bits();
        key.keyval = value.into_glib();
        key.time = gdk::ffi::GDK_CURRENT_TIME as u32;
        key.send_event = 0;
    }
    view.event(&event);
    Ok(KeyGuard)
}
#[cfg(target_os = "windows")]
fn focus(view: &wry::WebView) -> anyhow::Result<()> {
    use windows::Win32::{
        Foundation::HWND,
        UI::WindowsAndMessaging::{
            GetForegroundWindow, GetWindowThreadProcessId, SetForegroundWindow,
        },
    };
    use wry::WebViewExtWindows;
    let mut parent = HWND::default();
    unsafe {
        view.controller().ParentWindow(&mut parent)?;
        let _ = SetForegroundWindow(parent);
    }
    view.focus()?;
    let mut pid = 0;
    unsafe {
        GetWindowThreadProcessId(GetForegroundWindow(), Some(&mut pid));
    }
    anyhow::ensure!(
        pid == std::process::id(),
        "keyboard must remain in the owned fixture process"
    );
    Ok(())
}
#[cfg(target_os = "windows")]
struct KeyGuard {
    keys: Vec<windows::Win32::UI::Input::KeyboardAndMouse::VIRTUAL_KEY>,
}
#[cfg(target_os = "windows")]
fn key(_view: &wry::WebView, case: Case) -> anyhow::Result<KeyGuard> {
    use windows::Win32::UI::Input::KeyboardAndMouse::*;
    let mut keys = vec![];
    if case.primary {
        keys.push(VK_CONTROL);
    }
    if matches!(case.command, Command::Next | Command::Previous) {
        keys.push(VK_SHIFT);
    }
    keys.push(match case.command {
        Command::New => VIRTUAL_KEY(0x54),
        Command::Close => VIRTUAL_KEY(0x57),
        Command::Next => VK_OEM_6,
        Command::Previous => VK_OEM_4,
    });
    let guard = KeyGuard { keys };
    let inputs = guard
        .keys
        .iter()
        .map(|key| INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: *key,
                    ..Default::default()
                },
            },
        })
        .collect::<Vec<_>>();
    anyhow::ensure!(
        unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) } == inputs.len() as u32,
        "owned key injection incomplete"
    );
    Ok(guard)
}
#[cfg(target_os = "windows")]
impl Drop for KeyGuard {
    fn drop(&mut self) {
        use windows::Win32::UI::Input::KeyboardAndMouse::*;
        let inputs = self
            .keys
            .iter()
            .rev()
            .map(|key| INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: *key,
                        dwFlags: KEYEVENTF_KEYUP,
                        ..Default::default()
                    },
                },
            })
            .collect::<Vec<_>>();
        unsafe {
            SendInput(&inputs, std::mem::size_of::<INPUT>() as i32);
        }
    }
}
fn fresh_root() -> anyhow::Result<PathBuf> {
    anyhow::ensure!(
        std::env::var("COINCIDE_SYNTHETIC_TAB_SHORTCUTS").as_deref() == Ok("1")
            && std::env::var("GITHUB_ACTIONS").as_deref() == Ok("true")
            && std::env::var("RUNNER_ENVIRONMENT").as_deref() == Ok("github-hosted"),
        "explicit fresh GitHub-hosted fixture opt-in required"
    );
    for chord in [
        "Control+t",
        "Control+w",
        "Control+Shift+]",
        "Control+Shift+[",
        "Meta+t",
        "Meta+w",
    ] {
        anyhow::ensure!(
            coincide_core::browser_protocol::keys::KeyPress::admitted(chord).is_err(),
            "agent page-key policy must reject host tab chords"
        );
    }
    let runner = std::fs::canonicalize(
        std::env::var_os("RUNNER_TEMP").ok_or_else(|| anyhow::anyhow!("runner temp required"))?,
    )?;
    Ok(tempfile::Builder::new()
        .prefix("owned-synthetic-tab-shortcuts-")
        .tempdir_in(runner)?
        .keep())
}
fn main() -> anyhow::Result<()> {
    let root = fresh_root()?;
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
        .expect("owned shortcut window unavailable");
        cx.activate(true);
    });
    match observed.lock().unwrap().take() {
        Some(Ok(())) => Ok(()),
        Some(Err(error)) => anyhow::bail!("synthetic native tab shortcuts failed: {error}"),
        None => anyhow::bail!("native shortcut fixture returned no verdict"),
    }
}
