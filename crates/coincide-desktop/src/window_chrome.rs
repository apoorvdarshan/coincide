//! Main-window chrome the Swift `MainWindowController` keeps: the window's
//! frame and the thread list's visibility across launches (`UIState`
//! `windowFrame` and `isSidebarCollapsed`), the open thread's folder as the
//! title bar's proxy icon, and the toolbar's run status for the open thread.
//!
//! The frame is GPUI's own window bounds with its display's UUID, so it is kept
//! under `rustWindowFrame` rather than in Swift's AppKit frame descriptor.
use super::*;
use std::collections::HashMap;

const FRAME_KEY: &str = "rustWindowFrame";
const SIDEBAR_KEY: &str = "isSidebarCollapsed";
/// Moves and resizes arrive continuously; the frame is saved once they stop.
const FRAME_SETTLE: Duration = Duration::from_millis(500);
pub(super) const DEFAULT_SIZE: (f32, f32) = (1280., 820.);
pub(super) const MIN_SIZE: (f32, f32) = (820., 520.);

#[derive(Clone, Debug, PartialEq)]
pub(super) struct SavedFrame {
    display: Option<String>,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    maximized: bool,
}

impl SavedFrame {
    fn decode(document: &Value) -> Option<Self> {
        let frame = document.get(FRAME_KEY)?;
        let number = |key: &str| frame[key].as_f64().filter(|value| value.is_finite());
        let saved = Self {
            display: frame["display"].as_str().map(str::to_owned),
            x: number("x")?,
            y: number("y")?,
            width: number("width")?,
            height: number("height")?
                + if cfg!(target_os = "macos") && frame["unifiedTitlebar"] != true {
                    32.
                } else {
                    0.
                },
            maximized: frame["maximized"] == true,
        };
        (saved.width >= f64::from(MIN_SIZE.0) && saved.height >= f64::from(MIN_SIZE.1))
            .then_some(saved)
    }
    fn encode(&self) -> Value {
        json!({"display":self.display,"x":self.x,"y":self.y,"width":self.width,"height":self.height,"maximized":self.maximized,"unifiedTitlebar":cfg!(target_os = "macos")})
    }
    fn bounds(&self) -> Bounds<Pixels> {
        Bounds::new(
            point(px(self.x as f32), px(self.y as f32)),
            size(px(self.width as f32), px(self.height as f32)),
        )
    }
}

fn interface_state(store: &Store) -> Option<Value> {
    store
        .document("ui-state.json")
        .ok()
        .flatten()
        .filter(Value::is_object)
}

/// The frame saved by the last launch, if it is readable.
pub(super) fn saved_frame(store: &Store) -> Option<SavedFrame> {
    SavedFrame::decode(&interface_state(store)?)
}

/// Whether the thread list shows at launch: unless it was hidden last time.
pub(super) fn sidebar_open(engine: &SharedEngine) -> bool {
    try_state(engine)
        .ok()
        .and_then(|engine| interface_state(&engine.store))
        .is_none_or(|state| state[SIDEBAR_KEY] != true)
}

pub(super) fn terminal_bottom_open(engine: &SharedEngine) -> bool {
    try_state(engine)
        .ok()
        .and_then(|engine| interface_state(&engine.store))
        .is_some_and(|state| state["rustTerminalBottomOpen"] == true)
}

/// Where the main window opens: its saved frame on the display it was on,
/// else centred at the default size. A display that is gone, or a frame larger
/// than it, falls back to the default.
pub(super) fn opening_bounds(
    saved: Option<&SavedFrame>,
    cx: &App,
) -> (WindowBounds, Option<DisplayId>) {
    let fallback = || {
        (
            WindowBounds::Windowed(Bounds::centered(
                None,
                size(px(DEFAULT_SIZE.0), px(DEFAULT_SIZE.1)),
                cx,
            )),
            None,
        )
    };
    let Some(saved) = saved else {
        return fallback();
    };
    let display = match &saved.display {
        Some(uuid) => cx.displays().into_iter().find(|display| {
            display
                .uuid()
                .is_ok_and(|known| known.to_string().eq_ignore_ascii_case(uuid))
        }),
        None => cx.primary_display(),
    };
    let Some(display) = display else {
        return fallback();
    };
    let area = display.bounds().size;
    if f64::from(f32::from(area.width)) < saved.width
        || f64::from(f32::from(area.height)) < saved.height
    {
        return fallback();
    }
    let bounds = saved.bounds();
    (
        if saved.maximized {
            WindowBounds::Maximized(bounds)
        } else {
            WindowBounds::Windowed(bounds)
        },
        Some(display.id()),
    )
}

fn patch_interface_state(engine: &SharedEngine, key: &str, value: Value) -> Result<()> {
    let mut engine = try_state(engine)?;
    anyhow::ensure!(!engine.admissions_frozen(), "App is closing");
    // A malformed document is kept as it is rather than replaced.
    anyhow::ensure!(
        engine
            .store
            .document("ui-state.json")?
            .is_none_or(|state| state.is_object()),
        "Saved interface state is malformed"
    );
    let mut patch = json!({});
    patch[key] = value;
    engine.store.patch_document("ui-state.json", &patch)?;
    Ok(())
}

/// The open thread's run as the toolbar shows it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum RunStatus {
    Idle,
    /// Started, but the provider has not answered yet: "Connecting…".
    Starting,
    /// "Working m:ss" since this Swift reference time.
    Running {
        since: f64,
    },
    /// "Needs approval", or "<n> approvals needed".
    Approval(usize),
}

impl RunStatus {
    pub(super) fn label(self, now: f64) -> Option<String> {
        match self {
            Self::Idle => None,
            Self::Starting => Some("Connecting…".into()),
            Self::Running { since } => Some(format!("Working {}", elapsed(now - since))),
            Self::Approval(1) => Some("Needs approval".into()),
            Self::Approval(count) => Some(format!("{count} approvals needed")),
        }
    }
}

fn run_status(running: bool, clock: Option<RunClock>, approvals: usize, now: f64) -> RunStatus {
    if approvals > 0 {
        RunStatus::Approval(approvals)
    } else if !running {
        RunStatus::Idle
    } else if clock.is_some_and(|clock| clock.connecting) {
        RunStatus::Starting
    } else {
        RunStatus::Running {
            since: clock.map_or(now, |clock| clock.started_at),
        }
    }
}

/// "0:42", "12:05", then "1:02:03", as Swift's minute-second duration.
pub(super) fn elapsed(seconds: f64) -> String {
    let seconds = seconds.max(0.) as u64;
    if seconds >= 3600 {
        format!(
            "{}:{:02}:{:02}",
            seconds / 3600,
            seconds / 60 % 60,
            seconds % 60
        )
    } else {
        format!("{}:{:02}", seconds / 60, seconds % 60)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct RunClock {
    started_at: f64,
    connecting: bool,
}

#[derive(Default)]
pub(super) struct State {
    frame_changed: Option<Instant>,
    saved_frame: Option<SavedFrame>,
    document_path: Option<Option<std::path::PathBuf>>,
    title: Option<String>,
    run_clocks: HashMap<String, RunClock>,
    /// The second the run status last showed, so it redraws once a second.
    shown_second: Option<u64>,
}

/// macOS opens NSWindow with a content rect, but reports the outer frame.
/// Persisting that outer size as the next content size adds the titlebar on
/// every reopen. Other platforms' constructors use their reported bounds.
pub(super) fn restorable_size(
    outer: gpui_kit::Size<Pixels>,
    content: gpui_kit::Size<Pixels>,
) -> gpui_kit::Size<Pixels> {
    if cfg!(target_os = "macos") {
        content
    } else {
        outer
    }
}

/// Use AppKit's content rect rather than the drawable view: the view can have
/// border insets and must not make a saved window shrink on every reopen.
pub(super) fn restorable_window_size(window: &Window) -> gpui_kit::Size<Pixels> {
    #[cfg(target_os = "macos")]
    {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        if let Ok(handle) = HasWindowHandle::window_handle(window)
            && let RawWindowHandle::AppKit(handle) = handle.as_raw()
        {
            let view = unsafe { &*handle.ns_view.as_ptr().cast::<objc2_app_kit::NSView>() };
            if let Some(native) = view.window() {
                let content = native.contentRectForFrameRect(native.frame()).size;
                return size(px(content.width as f32), px(content.height as f32));
            }
        }
    }
    match window.window_bounds() {
        WindowBounds::Windowed(bounds)
        | WindowBounds::Maximized(bounds)
        | WindowBounds::Fullscreen(bounds) => restorable_size(bounds.size, window.viewport_size()),
    }
}

impl State {
    pub(super) fn new(saved: Option<SavedFrame>) -> Self {
        Self {
            saved_frame: saved,
            ..Self::default()
        }
    }
    /// The window moved or resized; it is saved once that stops.
    pub(super) fn frame_changed(&mut self) {
        self.frame_changed = Some(Instant::now());
    }
    /// `app.status` `runClocks`: each run's start and whether it is connecting.
    pub(super) fn observe_status(&mut self, status: &Value) {
        self.run_clocks = status["runClocks"]
            .as_object()
            .into_iter()
            .flatten()
            .filter_map(|(id, clock)| {
                Some((
                    id.clone(),
                    RunClock {
                        started_at: clock["startedAt"].as_f64()?,
                        connecting: clock["connecting"] == true,
                    },
                ))
            })
            .collect();
    }
}

impl Coincide {
    /// Remembers whether the thread list shows, for the next launch.
    pub(super) fn remember_sidebar_visibility(&mut self) {
        if let Err(error) =
            patch_interface_state(&self.engine, SIDEBAR_KEY, json!(!self.thread_list_open))
        {
            self.status = format!("Thread list visibility could not be saved: {error}");
        }
    }
    pub(super) fn remember_terminal_visibility(&mut self) {
        if !self.terminal_on_right() {
            if let Err(error) = patch_interface_state(
                &self.engine,
                "rustTerminalBottomOpen",
                json!(self.terminal_open),
            ) {
                self.status = format!("Terminal visibility could not be saved: {error}");
            }
        }
    }
    /// Saves the window's frame once moving or resizing has stopped. Full
    /// screen is not a frame to come back to, as in Swift.
    fn save_window_frame(&mut self, window: &Window, cx: &App) {
        let Some(changed) = self.window_chrome.frame_changed else {
            return;
        };
        if changed.elapsed() < FRAME_SETTLE || self.media.close_requested {
            return;
        }
        self.window_chrome.frame_changed = None;
        let (bounds, maximized) = match window.window_bounds() {
            WindowBounds::Windowed(bounds) => (bounds, false),
            WindowBounds::Maximized(bounds) => (bounds, true),
            WindowBounds::Fullscreen(_) => return,
        };
        let restored_size = restorable_window_size(window);
        let frame = SavedFrame {
            display: window
                .display(cx)
                .and_then(|display| display.uuid().ok())
                .map(|uuid| uuid.to_string()),
            x: f64::from(f32::from(bounds.origin.x)),
            y: f64::from(f32::from(bounds.origin.y)),
            width: f64::from(f32::from(restored_size.width)),
            height: f64::from(f32::from(restored_size.height)),
            maximized,
        };
        if self.window_chrome.saved_frame.as_ref() == Some(&frame) {
            return;
        }
        // Busy or closing: the next move or resize saves it.
        if patch_interface_state(&self.engine, FRAME_KEY, frame.encode()).is_ok() {
            self.window_chrome.saved_frame = Some(frame);
        }
    }
    /// The open thread's working folder, the title bar's proxy icon on macOS.
    fn sync_document_path(&mut self, window: &mut Window) {
        let title = self
            .selected
            .as_ref()
            .and_then(|thread| thread["title"].as_str())
            .filter(|title| !title.trim().is_empty())
            .unwrap_or("Coincide");
        if self.window_chrome.title.as_deref() != Some(title) {
            window.set_window_title(title);
            self.window_chrome.title = Some(title.to_owned());
        }
        let folder = self.selected.as_ref().and_then(|thread| {
            thread["worktreePath"]
                .as_str()
                .filter(|path| !path.is_empty())
                .map(str::to_owned)
                .or_else(|| {
                    self.projects
                        .iter()
                        .find(|project| project["id"] == thread["projectID"])
                        .filter(|project| project["isChats"] != true)
                        .and_then(|project| project["path"].as_str())
                        .filter(|path| !path.is_empty())
                        .map(str::to_owned)
                })
                .map(std::path::PathBuf::from)
        });
        if self.window_chrome.document_path.as_ref() != Some(&folder) {
            window.set_document_path(folder.as_deref());
            self.window_chrome.document_path = Some(folder);
        }
    }
    pub(super) fn poll_window_chrome(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.save_window_frame(window, cx);
        self.sync_document_path(window);
        // "Working m:ss" counts up while the open thread runs.
        let second = matches!(self.run_status(), RunStatus::Running { .. })
            .then(|| coincide_core::store::swift_timestamp() as u64);
        if second != self.window_chrome.shown_second {
            self.window_chrome.shown_second = second;
            cx.notify();
        }
    }
    pub(super) fn run_status(&self) -> RunStatus {
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return RunStatus::Idle;
        };
        // Questions the agent asks are answered in the chat; approvals wait here.
        let approvals = if self.running.contains(&id) {
            self.pending_requests
                .iter()
                .filter(|request| request["method"] != "item/tool/requestUserInput")
                .count()
        } else {
            0
        };
        run_status(
            self.running.contains(&id),
            self.window_chrome.run_clocks.get(&id).copied(),
            approvals,
            coincide_core::store::swift_timestamp(),
        )
    }
}

pub(super) fn titlebar_mouse_down(event: &MouseDownEvent, window: &mut Window, _: &mut App) {
    if event.click_count == 2 {
        window.titlebar_double_click();
    } else {
        window.start_window_move();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn frames_round_trip_and_unreadable_or_tiny_ones_are_ignored() {
        let frame = SavedFrame {
            display: Some("A1B2".into()),
            x: 40.,
            y: 60.,
            width: 1400.,
            height: 900.,
            maximized: true,
        };
        let mut document = json!({"listWidth":300});
        document[FRAME_KEY] = frame.encode();
        assert_eq!(SavedFrame::decode(&document), Some(frame));
        for broken in [
            json!({}),
            json!({FRAME_KEY: "100 100 800 600"}),
            json!({FRAME_KEY: {"x":0,"y":0,"width":400,"height":300}}),
            json!({FRAME_KEY: {"x":"0","y":0,"width":1280,"height":820}}),
        ] {
            assert!(SavedFrame::decode(&broken).is_none(), "{broken}");
        }
    }

    #[::core::prelude::v1::test]
    fn legacy_content_frame_migrates_once_to_the_unified_window() {
        let legacy = json!({FRAME_KEY:{"x":0,"y":0,"width":1280,"height":788}});
        let migrated = SavedFrame::decode(&legacy).unwrap();
        assert_eq!(
            migrated.height,
            if cfg!(target_os = "macos") {
                820.
            } else {
                788.
            }
        );
        let reopened = SavedFrame::decode(&json!({FRAME_KEY:migrated.encode()})).unwrap();
        assert_eq!(reopened, migrated);
    }

    #[::core::prelude::v1::test]
    fn run_status_prefers_approvals_then_connecting_then_working() {
        let clock = |connecting| {
            Some(RunClock {
                started_at: 100.,
                connecting,
            })
        };
        assert_eq!(run_status(false, None, 0, 200.), RunStatus::Idle);
        assert_eq!(
            run_status(true, clock(true), 2, 200.),
            RunStatus::Approval(2)
        );
        assert_eq!(run_status(true, clock(true), 0, 200.), RunStatus::Starting);
        assert_eq!(
            run_status(true, clock(false), 0, 200.),
            RunStatus::Running { since: 100. }
        );
        // A run the engine has not reported a clock for counts from now.
        assert_eq!(
            run_status(true, None, 0, 200.),
            RunStatus::Running { since: 200. }
        );
        assert_eq!(
            RunStatus::Running { since: 100. }.label(142.).as_deref(),
            Some("Working 0:42")
        );
        assert_eq!(
            RunStatus::Approval(1).label(0.).as_deref(),
            Some("Needs approval")
        );
        assert_eq!(
            RunStatus::Approval(3).label(0.).as_deref(),
            Some("3 approvals needed")
        );
        assert_eq!(
            RunStatus::Starting.label(0.).as_deref(),
            Some("Connecting…")
        );
        assert_eq!(elapsed(725.), "12:05");
        assert_eq!(elapsed(3723.), "1:02:03");
        assert_eq!(elapsed(-5.), "0:00");
    }

    #[::core::prelude::v1::test]
    fn status_clocks_are_read_from_app_status() {
        let mut state = State::default();
        state.observe_status(&json!({"runClocks":{"T":{"startedAt":5.5,"connecting":false},"bad":{"connecting":true}}}));
        assert_eq!(
            state.run_clocks.get("T"),
            Some(&RunClock {
                started_at: 5.5,
                connecting: false
            })
        );
        assert!(!state.run_clocks.contains_key("bad"));
    }
}

#[cfg(test)]
mod restore_size_regression {
    use super::*;
    #[::core::prelude::v1::test]
    fn repeated_macos_reopens_do_not_accumulate_titlebar_height() {
        let requested = size(px(860.), px(640.));
        let mut saved = requested;
        for _ in 0..5 {
            let outer = if cfg!(target_os = "macos") {
                size(saved.width, saved.height + px(32.))
            } else {
                saved
            };
            saved = restorable_size(outer, requested);
        }
        assert_eq!(saved, requested);
    }
}
