//! Thread-bound terminal tabs of up to four panes. Parent mount:
//! `cx.new(|cx| TerminalWorkspace::new(engine.clone(), thread_id, window, cx))`.
//! Cache the Entity per thread to retain layouts. Recreating it adopts existing
//! PTYs as tabs; dropping it never closes shells. Only explicit Close does.
//!
//! Uses the parent's coherent styled-frame reader and cell renderer conventions,
//! and the existing TerminalSelection/Alacritty projection (never ANSI stripping).
//! All engine calls run on one serialized worker. No shell commands are generated.
//! Mode-sensitive input is encoded by terminal.input in core; native IME preedit
//! is local to a revocable per-pane focus session and never edits shell output.
use crate::terminal_selection::TerminalSelection;
#[path = "terminal_context.rs"]
mod context;
#[path = "terminal_tabs.rs"]
mod tabs;
use anyhow::{Result, ensure};
use coincide_core::{
    api::SharedEngine,
    store::text,
    terminal::{KeyModifiers, Palette, TerminalInput, TerminalPoint, TerminalScroll},
};
pub(crate) use context::{ComposerBaseline, SelectionRequest, TerminalContextEvent};
use gpui_kit::{
    assets::IconName,
    base::Disableable,
    component::{
        ActiveTheme, Icon, Sizable,
        button::*,
        menu::{ContextMenuExt, PopupMenuItem},
        progress::ProgressCircle,
        tooltip::Tooltip,
    },
    prelude::FluentBuilder,
    *,
};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    ops::Range,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, SyncSender},
    },
    time::{Duration, Instant},
};
use tabs::{Layout, PaneStatus, ProgressState};

const MAX_PANES: usize = 32;
/// How often the tabs re-read each terminal's job, folder, progress and exit.
const STATUS_INTERVAL: Duration = Duration::from_millis(500);
/// Input typed before the shell exists waits for it, up to this many events.
const MAX_PENDING_INPUT: usize = 256;
type PaneId = u64;

/// Horizontal = side by side; Vertical = stacked. Panes have equal shares.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SplitAxis {
    Horizontal,
    Vertical,
}
/// One terminal cell for the mono font, which follows the conversation font
/// size one point smaller (Swift Theme.monoFont).
#[derive(Clone, Copy, Debug, PartialEq)]
struct Metrics {
    font: f32,
    cell_w: f32,
    cell_h: f32,
}
impl Metrics {
    fn for_font(font: f32) -> Self {
        let font = if font.is_finite() {
            font.clamp(9., 23.)
        } else {
            12.
        };
        Self {
            font,
            cell_w: font * 2. / 3.,
            cell_h: font * 1.5,
        }
    }
}
impl Default for Metrics {
    fn default() -> Self {
        Self::for_font(12.)
    }
}
/// The terminal's colors and font from the app's theme (Swift TerminalTheme):
/// the conversation's background and text, and the light or dark palette.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TerminalAppearance {
    pub dark: bool,
    pub foreground: u32,
    pub background: u32,
    pub font_size: f32,
}
impl Default for TerminalAppearance {
    fn default() -> Self {
        Self {
            dark: true,
            foreground: 0xd4d4d4,
            background: 0x0c0c0c,
            font_size: 12.,
        }
    }
}
impl TerminalAppearance {
    fn palette(&self) -> Palette {
        let channels = |rgb: u32| [(rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8];
        Palette {
            dark: self.dark,
            foreground: channels(self.foreground),
            background: channels(self.background),
        }
    }
    fn cursor(&self) -> u32 {
        if self.dark { 0xb4cbff } else { 0x26384e }
    }
}
struct Tab {
    key: PaneId,
    layout: Layout,
    focus: PaneId,
}

// Native text services can only edit this local, uncommitted composition buffer.
// Every range uses UTF-16; no callback is allowed to edit echoed shell output.
#[derive(Default, Clone, Debug)]
struct Composition {
    text: String,
    selected: Range<usize>,
    marked: bool,
}
// The platform input context belongs to the native view, not a GPUI pane.
// Keep its cancellation ownership beside the pane-local composition so a new
// pane can never inherit the old context's pending dead-key/IME state.
struct PreeditContext<C>(Option<C>);
impl<C> Default for PreeditContext<C> {
    fn default() -> Self {
        Self(None)
    }
}
impl<C> PreeditContext<C> {
    fn stage(&mut self, capture: impl FnOnce() -> Option<C>) {
        if self.0.is_none() {
            self.0 = capture();
        }
    }
    fn cancel(&mut self, discard: impl FnOnce(C)) {
        if let Some(context) = self.0.take() {
            discard(context);
        }
    }
    fn committed(&mut self) {
        self.0 = None;
    }
}
#[cfg(target_os = "macos")]
struct NativePreeditContext(objc2::rc::Retained<objc2::runtime::AnyObject>);
#[cfg(target_os = "macos")]
impl NativePreeditContext {
    fn capture(window: &Window) -> Option<Self> {
        if !window.is_window_active() {
            return None;
        }
        use objc2::{
            class, msg_send,
            runtime::{AnyObject, Bool},
            sel,
        };
        // This runs only in an accepted marked-text callback on the active
        // terminal. Capture that responder's exact context now; cancellation
        // must not look up a later pane/window's first responder.
        unsafe {
            let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
            let window: *mut AnyObject = msg_send![app, keyWindow];
            if window.is_null() {
                return None;
            }
            let responder: *mut AnyObject = msg_send![window, firstResponder];
            if responder.is_null() {
                return None;
            }
            let supports: Bool = msg_send![responder, respondsToSelector: sel!(inputContext)];
            if !supports.as_bool() {
                return None;
            }
            let context: *mut AnyObject = msg_send![responder, inputContext];
            if context.is_null() {
                return None;
            }
            let supports: Bool = msg_send![context, respondsToSelector: sel!(discardMarkedText)];
            if !supports.as_bool() {
                return None;
            }
            objc2::rc::Retained::retain(context).map(Self)
        }
    }
    fn discard(self, cx: &mut App) {
        // discardMarkedText may synchronously call unmarkText back into GPUI.
        // Wait only for the current effect cycle, not a timer or another input,
        // so Entity borrows are released before any native callback occurs.
        cx.defer(move |_| unsafe {
            let _: () = objc2::msg_send![&*self.0, discardMarkedText];
        });
    }
}
#[cfg(not(target_os = "macos"))]
struct NativePreeditContext;
#[cfg(not(target_os = "macos"))]
impl NativePreeditContext {
    fn capture(_: &Window) -> Option<Self> {
        None
    }
    fn discard(self, _: &mut App) {}
}
fn utf16_byte(text: &str, offset: usize) -> Option<usize> {
    let mut units = 0;
    for (byte, ch) in text.char_indices() {
        if units == offset {
            return Some(byte);
        }
        units += ch.len_utf16();
    }
    (units == offset).then_some(text.len())
}
fn byte_range(text: &str, range: Range<usize>) -> Option<Range<usize>> {
    if range.start > range.end {
        return None;
    }
    Some(utf16_byte(text, range.start)?..utf16_byte(text, range.end)?)
}
fn valid_payload(text: &str, _paste: bool) -> Result<()> {
    // Core chooses the current mode and enforces the whole encoded-frame bound,
    // including paste delimiters. UI never frames or retries input itself.
    ensure!(text.len() <= 32768, "Encoded terminal input exceeds 32 KiB");
    ensure!(
        !text
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\t' | '\r' | '\n')),
        "Terminal text contains control framing"
    );
    Ok(())
}
fn valid_input(input: &TerminalInput) -> bool {
    match input {
        TerminalInput::Text { text } | TerminalInput::Paste { text } => {
            valid_payload(text, false).is_ok()
        }
        TerminalInput::Key { .. } => true,
    }
}
/// Return, which restarts an exited shell (Swift looks for a carriage return).
fn submits(input: &TerminalInput) -> bool {
    match input {
        TerminalInput::Key { key, .. } => key == "enter",
        TerminalInput::Text { text } | TerminalInput::Paste { text } => text.contains('\r'),
    }
}
impl Composition {
    fn replacement(&self, range: Option<Range<usize>>, text: &str) -> Result<(String, usize)> {
        valid_payload(text, false)?;
        let range = range.unwrap_or_else(|| {
            if self.marked {
                0..self.text.encode_utf16().count()
            } else {
                self.selected.clone()
            }
        });
        let bytes = byte_range(&self.text, range.clone())
            .ok_or_else(|| anyhow::anyhow!("IME range is outside uncommitted text"))?;
        let mut next = self.text.clone();
        next.replace_range(bytes, text);
        valid_payload(&next, false)?;
        Ok((next, range.start))
    }
    fn stage(
        &mut self,
        range: Option<Range<usize>>,
        text: &str,
        selected: Option<Range<usize>>,
    ) -> Result<()> {
        let (next, start) = self.replacement(range, text)?;
        let relative = selected.unwrap_or_else(|| {
            let end = text.encode_utf16().count();
            end..end
        });
        ensure!(
            byte_range(text, relative.clone()).is_some(),
            "IME selection splits a UTF-16 character"
        );
        self.text = next;
        self.selected = start + relative.start..start + relative.end;
        self.marked = true;
        Ok(())
    }
    fn clear(&mut self) {
        *self = Self::default();
    }
    fn cancel<C>(&mut self, context: &mut PreeditContext<C>, discard: impl FnOnce(C)) {
        self.clear();
        context.cancel(discard);
    }
    fn display(&self) -> String {
        self.text.replace(['\t', '\r', '\n'], " ")
    }
}
fn native_scope(
    key: PaneId,
    epoch: u64,
    visible: bool,
    panes: &[PaneId],
    binding: Option<(u64, bool)>,
) -> bool {
    visible
        && panes.contains(&key)
        && binding.is_some_and(|(current, enabled)| current == epoch && enabled)
}
struct PaneInput {
    owner: WeakEntity<TerminalWorkspace>,
    key: PaneId,
    epoch: u64,
    focus: FocusHandle,
    active: bool,
    composition: Composition,
    native_preedit: PreeditContext<NativePreeditContext>,
    notice: String,
    anchor: Point<Pixels>,
    bounds: Option<Bounds<Pixels>>,
    metrics: Metrics,
    _blur: Subscription,
    _activation: Subscription,
}
impl PaneInput {
    fn current(&self, window: &Window, cx: &App) -> bool {
        if !self.active || !window.is_window_active() || !self.focus.is_focused(window) {
            return false;
        }
        self.owner.upgrade().is_some_and(|owner| {
            let workspace = owner.read(cx);
            native_scope(
                self.key,
                self.epoch,
                workspace.visible,
                &workspace.ids(),
                workspace
                    .panes
                    .get(&self.key)
                    // Text typed while the shell starts waits for it.
                    .map(|p| (p.ime_epoch, !p.closing)),
            )
        })
    }
    fn clear_preedit(&mut self, cx: &mut Context<Self>) {
        self.composition
            .cancel(&mut self.native_preedit, |context| context.discard(cx));
    }
    fn revoke(&mut self, cx: &mut Context<Self>) {
        self.active = false;
        self.clear_preedit(cx);
        cx.notify();
    }
    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.clear_preedit(cx);
        window.notify_text_input_changed(&self.focus);
        cx.notify();
    }
    fn submit(
        &mut self,
        input: TerminalInput,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.current(window, cx) {
            self.clear_preedit(cx);
            return false;
        }
        self.owner
            .update(cx, |workspace, cx| {
                workspace.submit_native(self.key, self.epoch, input, window, cx)
            })
            .unwrap_or(false)
    }
    fn changed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        window.notify_text_input_changed(&self.focus);
        window.notify_text_selection_changed(&self.focus);
        cx.notify();
    }
    fn line(&self, window: &Window) -> ShapedLine {
        let text: SharedString = self.composition.display().into();
        let run = TextRun {
            len: text.len(),
            font: font(if cfg!(target_os = "macos") {
                "Menlo"
            } else {
                "monospace"
            }),
            color: rgb(0xd4d4d4).into(),
            background_color: None,
            underline: None,
            strikethrough: None,
        };
        window
            .text_system()
            .shape_line(text, px(self.metrics.font), &[run], None)
    }
}
impl EntityInputHandler for PaneInput {
    fn accepts_text_input(&self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        self.current(window, cx)
    }
    fn text_for_range(
        &mut self,
        range: Range<usize>,
        adjusted: &mut Option<Range<usize>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<String> {
        if !self.current(window, cx) {
            return None;
        }
        let bytes = byte_range(&self.composition.text, range.clone())?;
        *adjusted = Some(range);
        Some(self.composition.text[bytes].into())
    }
    fn selected_text_range(
        &mut self,
        _ignore: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        self.current(window, cx).then(|| UTF16Selection {
            range: self.composition.selected.clone(),
            reversed: false,
        })
    }
    fn marked_text_range(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<Range<usize>> {
        (self.current(window, cx) && self.composition.marked)
            .then(|| 0..self.composition.text.encode_utf16().count())
    }
    fn unmark_text(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.cancel(window, cx);
    }
    fn replace_and_mark_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        text: &str,
        selected: Option<Range<usize>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.current(window, cx) {
            self.clear_preedit(cx);
            return;
        }
        match self.composition.stage(range, text, selected) {
            Ok(()) => {
                self.native_preedit
                    .stage(|| NativePreeditContext::capture(window));
                self.notice.clear();
            }
            Err(error) => self.notice = error.to_string(),
        }
        self.changed(window, cx);
    }
    fn replace_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.current(window, cx) {
            self.clear_preedit(cx);
            return;
        }
        match self.composition.replacement(range, text) {
            Ok((text, _)) => {
                if self.submit(TerminalInput::Text { text }, window, cx) {
                    self.composition.clear();
                    self.native_preedit.committed();
                    self.notice.clear();
                }
            }
            Err(error) => self.notice = error.to_string(),
        }
        self.changed(window, cx);
    }
    fn paste(&mut self, item: ClipboardItem, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(text) = item.text() {
            match valid_payload(&text, true) {
                Ok(()) => {
                    if self.submit(TerminalInput::Paste { text }, window, cx) {
                        self.clear_preedit(cx);
                        self.notice.clear();
                    }
                }
                Err(error) => self.notice = error.to_string(),
            }
            self.changed(window, cx);
        }
    }
    fn bounds_for_range(
        &mut self,
        range: Range<usize>,
        element: Bounds<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        if !self.current(window, cx) {
            return None;
        }
        let bytes = byte_range(&self.composition.text, range)?;
        let line = self.line(window);
        let x = (self.anchor.x + line.x_for_index(bytes.start))
            .max(element.left())
            .min(element.right());
        let right = (self.anchor.x + line.x_for_index(bytes.end))
            .max(x)
            .min(element.right());
        let y = self
            .anchor
            .y
            .max(element.top())
            .min((element.bottom() - px(self.metrics.cell_h)).max(element.top()));
        Some(Bounds::from_corners(
            point(x, y),
            point(right, y + px(self.metrics.cell_h)),
        ))
    }
    fn character_index_for_point(
        &mut self,
        point: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<usize> {
        if !self.current(window, cx) || !self.bounds?.contains(&point) {
            return None;
        }
        let byte = self
            .line(window)
            .closest_index_for_x(point.x - self.anchor.x);
        self.composition
            .text
            .get(..byte)
            .map(|text| text.encode_utf16().count())
    }
    fn set_selected_text_range(
        &mut self,
        range: Range<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.current(window, cx) && byte_range(&self.composition.text, range.clone()).is_some() {
            self.composition.selected = range;
            self.changed(window, cx);
        }
    }
    fn text_length_utf16(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Option<usize> {
        self.current(window, cx)
            .then(|| self.composition.text.encode_utf16().count())
    }
}

const WAIT_FOR_TERMINAL_CREATION: &str = "Wait for terminal creation";

fn clear_creation_notice(notice: &mut String, closing: bool) {
    if !closing && notice == WAIT_FOR_TERMINAL_CREATION {
        notice.clear();
    }
}

struct Pane {
    terminal: Option<String>,
    frame: Option<Value>,
    selection: TerminalSelection,
    focus: FocusHandle,
    scroll: ScrollHandle,
    ticket: u64,
    size: (u16, u16),
    closing: bool,
    notice: String,
    wheel: f32,
    blink: Instant,
    ime: Option<Entity<PaneInput>>,
    ime_epoch: u64,
    ime_observer: Option<Subscription>,
    /// What `terminal.status` last said about this pane's shell.
    status: Option<PaneStatus>,
    /// Typed before the shell existed; sent once it does (Swift pendingInput).
    pending: Vec<TerminalInput>,
    restarting: bool,
}
impl Pane {
    fn new(cx: &mut Context<TerminalWorkspace>) -> Self {
        Self {
            terminal: None,
            frame: None,
            selection: Default::default(),
            focus: cx.focus_handle(),
            scroll: ScrollHandle::new(),
            ticket: 0,
            size: (0, 0),
            closing: false,
            notice: String::new(),
            wheel: 0.,
            blink: Instant::now(),
            ime: None,
            ime_epoch: 0,
            ime_observer: None,
            status: None,
            pending: vec![],
            restarting: false,
        }
    }
    /// The shell failed at once and its pane waits for Restart or Close.
    fn stopped(&self) -> bool {
        self.status.as_ref().is_some_and(|status| status.exited)
    }
    fn matches(&self, terminal: &str, expected: Option<Stamp>) -> bool {
        !self.closing
            && self.terminal.as_deref() == Some(terminal)
            && expected.is_some()
            && self.frame.as_ref().and_then(stamp) == expected
    }
}
#[derive(Clone)]
enum Action {
    Input(TerminalInput),
    Resize(u16, u16),
    Scroll(u64, TerminalScroll),
    Close,
}
enum Command {
    Adopt(PaneId, String),
    /// A new shell; with a project script id it also types that script.
    Create(PaneId, Option<String>),
    Watch(Vec<PaneId>),
    /// Re-read every terminal of the thread for its tab.
    Status,
    /// A new shell in an exited pane (Swift TerminalSession.restart).
    Restart(PaneId),
    Copy(PaneId, u64, u64, TerminalPoint, TerminalPoint),
    AttachSelection(SelectionRequest, ComposerBaseline),
    Act(PaneId, u64, Action),
}
enum Update {
    Listed(Result<Vec<Value>>),
    Bound(PaneId, Result<String>),
    Frame(PaneId, u64, Result<Option<Value>>),
    Closed(PaneId, u64, Result<()>),
    Copied(PaneId, u64, u64, Result<String>),
    ContextAttached(
        SelectionRequest,
        ComposerBaseline,
        std::result::Result<Value, String>,
    ),
    // Command failure is not a frame: later input tickets must not hide it.
    ActionFailed(PaneId, String),
    Status(Result<Vec<Value>>),
    Restarted(PaneId, Result<()>),
}
struct Binding {
    terminal: String,
    ticket: u64,
}
fn send(tx: &SyncSender<Update>, update: Update) -> bool {
    tx.send(update).is_ok()
}

fn worker(
    engine: SharedEngine,
    thread: String,
    rx: Receiver<Command>,
    tx: SyncSender<Update>,
    stop: Arc<AtomicBool>,
    palette: Arc<Mutex<Palette>>,
) {
    let context_engine = engine.clone();
    run_worker(
        thread,
        rx,
        tx,
        &stop,
        // This serialized worker is off the UI thread. Wait for Engine ownership
        // rather than dropping a keystroke/list/create during normal contention.
        |method, params| coincide_core::api::call(&engine, method, params),
        |id| {
            let palette = *palette.lock().unwrap_or_else(|error| error.into_inner());
            match crate::read_terminal_frame(&engine, id, &palette) {
                Err(error) if crate::engine_busy(&error) => Ok(None),
                result => result,
            }
        },
        |request, baseline| {
            let mut engine = context_engine
                .lock()
                .map_err(|_| anyhow::anyhow!("App owner is unavailable"))?;
            // Recheck revocation after Engine acquisition, immediately before admission.
            ensure!(
                request.current(),
                "Terminal or composer changed; select again"
            );
            engine.attach_terminal_selection(&request.params(baseline))
        },
    );
}

fn run_worker(
    thread: String,
    rx: Receiver<Command>,
    tx: SyncSender<Update>,
    stop: &AtomicBool,
    mut call: impl FnMut(&str, Value) -> Result<Value>,
    mut read: impl FnMut(&str) -> Result<Option<Value>>,
    mut attach: impl FnMut(&SelectionRequest, &ComposerBaseline) -> Result<Value>,
) {
    if stop.load(Ordering::Acquire) {
        return;
    }
    let list = call("terminal.list", json!({"threadId":thread})).and_then(|v| {
        v.as_array()
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("Invalid terminal list"))
    });
    if !send(&tx, Update::Listed(list)) {
        return;
    }
    let mut bound: HashMap<PaneId, Binding> = HashMap::new();
    let mut visible = HashSet::new();
    let mut last = Instant::now();
    loop {
        if stop.load(Ordering::Acquire) {
            return;
        }
        let command = rx.recv_timeout(Duration::from_millis(30));
        if stop.load(Ordering::Acquire) {
            return;
        }
        match command {
            Ok(Command::Adopt(key, id)) => {
                bound.insert(
                    key,
                    Binding {
                        terminal: id,
                        ticket: 0,
                    },
                );
            }
            Ok(Command::Create(key, script)) => {
                let params = match script {
                    Some(script) => json!({"threadId":thread,"scriptId":script}),
                    None => json!({"threadId":thread}),
                };
                let result = call("terminal.create", params).and_then(|v| {
                    v["terminalId"]
                        .as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| anyhow::anyhow!("Missing terminal ID"))
                });
                if let Ok(id) = &result {
                    bound.insert(
                        key,
                        Binding {
                            terminal: id.clone(),
                            ticket: 0,
                        },
                    );
                }
                if !send(&tx, Update::Bound(key, result)) {
                    return;
                }
            }
            Ok(Command::AttachSelection(request, baseline)) => {
                let result = (|| -> Result<Value> {
                    let binding = bound
                        .get(&request.pane)
                        .ok_or_else(|| anyhow::anyhow!("Pane has no terminal"))?;
                    ensure!(
                        baseline.thread == thread
                            && request.thread == thread
                            && binding.terminal == request.terminal
                            && binding.ticket == request.ticket
                            && request.current(),
                        "Terminal pane or composer changed; select again"
                    );
                    attach(&request, &baseline)
                })()
                .map_err(|error| error.to_string());
                // A successful commit is always returned, even after later revocation.
                if !send(&tx, Update::ContextAttached(request, baseline, result)) {
                    return;
                }
            }
            Ok(Command::Copy(key, ticket, revision, start, end)) => {
                let result = (|| -> Result<String> {
                    let binding = bound
                        .get(&key)
                        .ok_or_else(|| anyhow::anyhow!("Pane has no terminal"))?;
                    ensure!(
                        binding.ticket == ticket,
                        "Terminal input changed; select again"
                    );
                    let result = call(
                        "terminal.selection",
                        json!({"terminalId":binding.terminal,"revision":revision,"start":start,"end":end}),
                    )?;
                    result["text"]
                        .as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| anyhow::anyhow!("Missing selection text"))
                })();
                if !send(&tx, Update::Copied(key, ticket, revision, result)) {
                    return;
                }
            }
            Ok(Command::Watch(keys)) => {
                visible = keys.into_iter().collect();
            }
            Ok(Command::Status) => {
                let list = call("terminal.status", json!({"threadId":thread})).and_then(|v| {
                    v.as_array()
                        .cloned()
                        .ok_or_else(|| anyhow::anyhow!("Invalid terminal status"))
                });
                if !send(&tx, Update::Status(list)) {
                    return;
                }
            }
            Ok(Command::Restart(key)) => {
                let result = bound
                    .get(&key)
                    .ok_or_else(|| anyhow::anyhow!("Pane has no terminal"))
                    .and_then(|binding| {
                        call("terminal.restart", json!({"terminalId":binding.terminal}))
                    })
                    .map(|_| ());
                if !send(&tx, Update::Restarted(key, result)) {
                    return;
                }
            }
            Ok(Command::Act(key, ticket, action)) => {
                let closing = matches!(action, Action::Close);
                let failure = match &action {
                    Action::Input(_) => "Terminal input was not sent",
                    Action::Resize(_, _) => "Terminal resize failed",
                    Action::Scroll(_, _) => "Terminal scroll failed",
                    Action::Close => "Terminal close failed",
                };
                let result = (|| -> Result<()> {
                    let binding = bound
                        .get_mut(&key)
                        .ok_or_else(|| anyhow::anyhow!("Pane has no terminal"))?;
                    binding.ticket = ticket;
                    let id = &binding.terminal;
                    match action {
                        Action::Input(input) => {
                            call("terminal.input", json!({"terminalId":id,"input":input}))?;
                        }
                        Action::Resize(rows, cols) => {
                            call(
                                "terminal.resize",
                                json!({"terminalId":id,"rows":rows,"cols":cols}),
                            )?;
                        }
                        Action::Scroll(revision, scroll) => {
                            call(
                                "terminal.scroll",
                                json!({"terminalId":id,"revision":revision,"scroll":scroll}),
                            )?;
                        }
                        Action::Close => {
                            call("terminal.close", json!({"terminalId":id}))?;
                        }
                    }
                    Ok(())
                })();
                if closing {
                    if result.is_ok() {
                        bound.remove(&key);
                        visible.remove(&key);
                    }
                    if !send(&tx, Update::Closed(key, ticket, result)) {
                        return;
                    }
                } else if let Err(error) = result
                    && !send(
                        &tx,
                        Update::ActionFailed(key, format!("{failure}: {error}")),
                    )
                {
                    return;
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
        // Poll even during an input burst, without spawning competing API workers.
        if last.elapsed() >= Duration::from_millis(80) {
            for key in &visible {
                if let Some(binding) = bound.get(key) {
                    let frame = read(&binding.terminal);
                    if !send(&tx, Update::Frame(*key, binding.ticket, frame)) {
                        return;
                    }
                }
            }
            last = Instant::now();
        }
    }
}

#[derive(Default)]
struct Activation {
    listed: Option<bool>,
    requested: bool,
}
#[derive(Debug, PartialEq, Eq)]
enum Activate {
    None,
    Focus,
    Create,
}
impl Activation {
    fn take(&mut self, visible: bool, panes: bool, stopping: bool) -> Activate {
        if !visible || stopping || self.listed == Some(false) {
            self.requested = false;
            return Activate::None;
        }
        if self.listed != Some(true) || !self.requested {
            return Activate::None;
        }
        self.requested = false;
        if panes {
            Activate::Focus
        } else {
            Activate::Create
        }
    }
}
pub struct TerminalWorkspace {
    thread: String,
    tabs: Vec<Tab>,
    active: Option<PaneId>,
    panes: HashMap<PaneId, Pane>,
    next: PaneId,
    tx: SyncSender<Command>,
    rx: Receiver<Update>,
    notice: String,
    context_epoch: Arc<AtomicU64>,
    context_pending: bool,
    context_shutdown_receipts: Vec<std::result::Result<Value, String>>,
    visible: bool,
    watch_dirty: bool,
    activation: Activation,
    stopping: Arc<AtomicBool>,
    completion: coincide_core::agent::WorkerCompletion,
    appearance: TerminalAppearance,
    /// The worker's copy of the colors frames are read with.
    palette: Arc<Mutex<Palette>>,
    /// When the outstanding status request was sent, and when the next is due.
    status_requested: Option<Instant>,
    status_due: Instant,
    /// The pending "still running" confirmation (Swift confirmClosing).
    close_prompt: Option<Task<()>>,
    _poll: Task<()>,
}
impl TerminalWorkspace {
    pub fn new(
        engine: SharedEngine,
        thread_id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let (tx, commands) = mpsc::sync_channel(64);
        let (updates, rx) = mpsc::sync_channel(32);
        let worker_thread = thread_id.clone();
        let stopping = Arc::new(AtomicBool::new(false));
        let stop = stopping.clone();
        let appearance = TerminalAppearance::default();
        let palette = Arc::new(Mutex::new(appearance.palette()));
        let worker_palette = palette.clone();
        let worker = std::thread::spawn(move || {
            worker(
                engine,
                worker_thread,
                commands,
                updates,
                stop,
                worker_palette,
            )
        });
        let completion = coincide_core::agent::WorkerCompletion::observe(worker);
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(50))
                    .await;
                if this
                    .update_in(cx, |this, window, cx| this.drain(window, cx))
                    .is_err()
                {
                    break;
                }
            }
        });
        Self {
            thread: thread_id,
            tabs: vec![],
            active: None,
            panes: HashMap::new(),
            next: 1,
            tx,
            rx,
            notice: String::new(),
            context_epoch: Arc::new(AtomicU64::new(0)),
            context_pending: false,
            context_shutdown_receipts: vec![],
            visible: true,
            watch_dirty: false,
            activation: Activation::default(),
            stopping,
            completion,
            appearance,
            palette,
            status_requested: None,
            status_due: Instant::now(),
            close_prompt: None,
            _poll: poll,
        }
    }
    /// The parent's theme colors and font; frames are re-read with them.
    pub fn set_appearance(&mut self, appearance: TerminalAppearance, cx: &mut Context<Self>) {
        if self.appearance == appearance {
            return;
        }
        self.appearance = appearance;
        *self
            .palette
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = appearance.palette();
        cx.notify();
    }
    fn metrics(&self) -> Metrics {
        Metrics::for_font(self.appearance.font_size)
    }
    /// Explicit panel-open action only. Existing PTYs are discovered before a
    /// first shell can be created, so reopening cannot duplicate a running tab.
    pub fn activate(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.activation.requested = true;
        self.activate_pending(window, cx);
    }
    fn activate_pending(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.activation.take(
            self.visible,
            !self.panes.is_empty(),
            self.stopping.load(Ordering::Acquire),
        ) {
            Activate::None => (),
            Activate::Focus => self.focus_active(window, cx),
            Activate::Create => self.create(None, None, window, cx),
        }
    }
    /// Stops only this UI transport. Engine owns the actual PTY children and IO.
    pub fn request_shutdown(&mut self, cx: &mut Context<Self>) {
        self.stopping.store(true, Ordering::Release);
        self.set_visible(false, cx);
        self.drain_context_shutdown();
    }
    pub fn shutdown_status(&mut self) -> coincide_core::agent::WorkerThreadStatus {
        // Release a publisher blocked by the bounded mailbox without applying
        // old frames, copy commands or input callbacks during shutdown.
        self.drain_context_shutdown();
        let status = self.completion.status();
        if status == coincide_core::agent::WorkerThreadStatus::Returned {
            // A normal joined worker cannot still publish. Any unexecuted queued
            // request was revoked before admission; preserve this classified receipt.
            self.drain_context_shutdown();
            if self.context_pending {
                self.context_shutdown_receipts.push(Err(
                    "Queued terminal selection cancelled before admission".into(),
                ));
                self.context_pending = false;
            }
        }
        status
    }
    /// Parent must not rebind this entity to another thread. Cache one entity per
    /// thread; old queued input can only address that entity's original PTYs.
    pub fn thread_id(&self) -> &str {
        &self.thread
    }
    /// App shortcuts must leave control sequences with the visible PTY pane.
    pub fn is_focused(&self, window: &Window) -> bool {
        self.visible
            && window.is_window_active()
            && self.ids().iter().any(|id| {
                self.panes
                    .get(id)
                    .is_some_and(|pane| !pane.closing && pane.focus.is_focused(window))
            })
    }
    fn ids(&self) -> Vec<PaneId> {
        let mut ids = vec![];
        if let Some(tab) = self.tabs.iter().find(|t| Some(t.key) == self.active) {
            tab.layout.panes(&mut ids);
        }
        ids
    }
    /// Parent calls false when hiding a cached entity, true when mounting it.
    pub fn set_visible(&mut self, visible: bool, cx: &mut Context<Self>) {
        let visible = visible && !self.stopping.load(Ordering::Acquire);
        if !visible {
            self.activation.requested = false;
            self.invalidate_context();
            self.revoke_inputs(cx);
        }
        self.visible = visible;
        self.watch();
        cx.notify();
    }
    fn watch(&mut self) {
        if self.stopping.load(Ordering::Acquire) {
            return;
        }
        let ids = if self.visible { self.ids() } else { vec![] };
        self.watch_dirty = self.tx.try_send(Command::Watch(ids)).is_err();
    }
    fn allocate(&mut self, cx: &mut Context<Self>) -> PaneId {
        let key = self.next;
        self.next += 1;
        self.panes.insert(key, Pane::new(cx));
        key
    }
    fn tab_for(&mut self, key: PaneId) {
        self.tabs.push(Tab {
            key,
            layout: Layout::single(key),
            focus: key,
        });
        self.active = Some(key);
    }
    /// Swift ThreadTerminals.run: a project script gets a new tab that comes
    /// to the front. Existing shells are still adopted beside it, and this
    /// panel-open does not also start a plain shell.
    pub fn run_script(&mut self, script: String, window: &mut Window, cx: &mut Context<Self>) {
        self.activation.requested = false;
        self.create(None, Some(script), window, cx);
    }
    fn create(
        &mut self,
        split: Option<(PaneId, SplitAxis)>,
        script: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.stopping.load(Ordering::Acquire) {
            return;
        }
        if self.panes.len() >= MAX_PANES {
            self.notice = "At most 32 terminal panes".into();
            cx.notify();
            return;
        }
        // Swift beeps when a split would put a fifth terminal in the tab.
        if let Some((target, _)) = split
            && self.tabs.iter().any(|tab| {
                Some(tab.key) == self.active
                    && tab.layout.panes.contains(&target)
                    && tab.layout.full()
            })
        {
            tabs::beep();
            return;
        }
        let key = self.allocate(cx);
        if self.tx.try_send(Command::Create(key, script)).is_err() {
            self.panes.remove(&key);
            self.notice = "Terminal worker busy; try again".into();
            cx.notify();
            return;
        }
        if let Some((target, axis)) = split {
            if let Some(tab) = self.tabs.iter_mut().find(|t| Some(t.key) == self.active) {
                if tab.layout.split(target, key, axis) {
                    tab.focus = key;
                } else {
                    self.tab_for(key);
                }
            } else {
                self.tab_for(key);
            }
        } else {
            self.tab_for(key);
        }
        self.focus(key, window, cx);
        self.watch();
        cx.notify();
    }
    fn act(&mut self, key: PaneId, action: Action, cx: &mut Context<Self>) -> bool {
        if self.stopping.load(Ordering::Acquire) {
            return false;
        }
        let Some(pane) = self.panes.get_mut(&key) else {
            return false;
        };
        if let Action::Input(input) = &action
            && !pane.closing
            && (pane.terminal.is_none() || pane.restarting)
        {
            // The shell gets what was typed once it starts (Swift pendingInput).
            if pane.pending.len() < MAX_PENDING_INPUT && valid_input(input) {
                pane.pending.push(input.clone());
                return true;
            }
            pane.notice = WAIT_FOR_TERMINAL_CREATION.into();
            cx.notify();
            return false;
        }
        if let Action::Input(input) = &action
            && pane.stopped()
        {
            // Swift inputWhileStopped: Return restarts an exited shell; other
            // keys go nowhere.
            if submits(input) {
                self.restart(key, cx);
            }
            return false;
        }
        if pane.closing || pane.terminal.is_none() {
            pane.notice = WAIT_FOR_TERMINAL_CREATION.into();
            cx.notify();
            return false;
        }
        if let Action::Input(TerminalInput::Text { text } | TerminalInput::Paste { text }) = &action
            && let Err(error) = valid_payload(text, false)
        {
            pane.notice = error.to_string();
            cx.notify();
            return false;
        }
        let ticket = pane.ticket + 1;
        if self
            .tx
            .try_send(Command::Act(key, ticket, action.clone()))
            .is_err()
        {
            pane.notice = "Input not sent: terminal worker queue full".into();
            cx.notify();
            return false;
        }
        self.context_epoch.fetch_add(1, Ordering::AcqRel);
        pane.ticket = ticket;
        pane.selection.clear();
        pane.blink = Instant::now();
        if matches!(action, Action::Close) {
            if let Some(input) = pane.ime.take() {
                input.update(cx, |input, cx| input.revoke(cx));
            }
            pane.closing = true;
            pane.ime_epoch += 1;
            pane.ime_observer = None;
        }
        if let Action::Resize(rows, cols) = action {
            pane.size = (rows, cols);
            // Keep the last coherent frame until the resized frame arrives.
            // Removing it also removes footer metrics, which can unwrap the
            // footer and change the viewport height again in narrow splits.
            // The advanced ticket rejects old replies; selection is cleared above.
        }
        cx.notify();
        true
    }
    /// Swift TerminalSession.restart from the exit banner or Return.
    fn restart(&mut self, key: PaneId, cx: &mut Context<Self>) {
        if self.stopping.load(Ordering::Acquire) {
            return;
        }
        let Some(pane) = self.panes.get_mut(&key) else {
            return;
        };
        if pane.closing || pane.restarting || !pane.stopped() || pane.terminal.is_none() {
            return;
        }
        if self.tx.try_send(Command::Restart(key)).is_err() {
            pane.notice = "Terminal worker busy; try again".into();
        } else {
            pane.restarting = true;
            pane.selection.clear();
        }
        cx.notify();
    }
    /// Swift TerminalLinks.open for a Command-click (Control-click elsewhere):
    /// web and mail links open; paths, relative to the shell's folder, show in
    /// the file manager. False when the click is on no link at all.
    fn open_link(&mut self, key: PaneId, row: usize, col: usize, cx: &mut Context<Self>) -> bool {
        let Some(pane) = self.panes.get(&key) else {
            return false;
        };
        let Some(frame) = &pane.frame else {
            return false;
        };
        let Some(cells) = frame["grid"][row].as_array() else {
            return false;
        };
        let Some(link) = tabs::link_at(frame, cells, col) else {
            return false;
        };
        let directory = pane
            .status
            .as_ref()
            .and_then(|status| status.directory.as_deref())
            .map(std::path::Path::new);
        let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
            .map(std::path::PathBuf::from);
        match tabs::resolve_link(&link, directory, home.as_deref()) {
            Some(tabs::Link::Web(url)) => cx.open_url(&url),
            Some(tabs::Link::File(path)) => cx.reveal_path(&path),
            None if tabs::looks_like_link(&link) => tabs::beep(),
            None => return false,
        }
        true
    }
    /// Closes panes, first asking when one still runs a job, as Terminal does
    /// (Swift confirmClosing). Idle and exited shells close right away.
    fn request_close(&mut self, keys: Vec<PaneId>, window: &mut Window, cx: &mut Context<Self>) {
        let keys = keys
            .into_iter()
            .filter(|key| self.panes.get(key).is_some_and(|pane| !pane.closing))
            .collect::<Vec<_>>();
        let busy = keys
            .iter()
            .filter_map(|key| self.panes[key].status.as_ref())
            .filter(|status| status.busy && !status.exited)
            .map(|status| status.name.clone())
            .collect::<Vec<_>>();
        let Some((title, detail)) = tabs::close_confirmation(&busy) else {
            for key in keys {
                self.act(key, Action::Close, cx);
            }
            return;
        };
        if self.close_prompt.is_some() {
            return;
        }
        let answer = window.prompt(
            PromptLevel::Warning,
            &title,
            Some(&detail),
            &["Close", "Cancel"],
            cx,
        );
        self.close_prompt = Some(cx.spawn_in(window, async move |this, cx| {
            let close = answer.await.is_ok_and(|answer| answer == 0);
            this.update_in(cx, |this, window, cx| {
                this.close_prompt = None;
                if close {
                    for key in keys {
                        this.act(key, Action::Close, cx);
                    }
                    this.focus_active(window, cx);
                }
                cx.notify();
            })
            .ok();
        }));
    }
    fn remove(&mut self, key: PaneId) {
        self.invalidate_context();
        self.panes.remove(&key);
        self.tabs = self
            .tabs
            .drain(..)
            .filter_map(|tab| {
                tab.layout.without(key).map(|layout| {
                    let mut ids = vec![];
                    layout.panes(&mut ids);
                    Tab {
                        key: tab.key,
                        focus: if ids.contains(&tab.focus) {
                            tab.focus
                        } else {
                            ids[0]
                        },
                        layout,
                    }
                })
            })
            .collect();
        if !self.tabs.iter().any(|t| Some(t.key) == self.active) {
            self.active = self.tabs.first().map(|t| t.key);
        }
        self.watch();
    }
    fn drain(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.stopping.load(Ordering::Acquire) {
            self.drain_context_shutdown();
            return;
        }
        let mut changed = false;
        for _ in 0..64 {
            let Ok(update) = self.rx.try_recv() else {
                break;
            };
            changed = true;
            match update {
                Update::ContextAttached(request, baseline, result) => {
                    self.context_pending = false;
                    let fresh = self.selection_request_current(&request);
                    self.notice = match &result {
                        Ok(_) => "Terminal selection attached to its original conversation.".into(),
                        Err(error) => format!("Terminal selection was not attached: {error}"),
                    };
                    cx.emit(TerminalContextEvent::Completed {
                        request,
                        baseline,
                        result,
                        fresh,
                    });
                }
                Update::ActionFailed(key, message) => {
                    if let Some(pane) = self.panes.get_mut(&key) {
                        // Do not discard a lost-input warning because newer
                        // keystrokes or resize operations advanced this pane.
                        pane.notice = message;
                    }
                }
                Update::Listed(Ok(tabs)) => {
                    // Only a script run can open a tab before listing; it
                    // stays in front of the shells adopted after it.
                    let front = self.active;
                    let mut adoption_ready = true;
                    for tab in tabs.iter().take(MAX_PANES) {
                        if let Some(id) = tab["terminalId"].as_str() {
                            if self
                                .panes
                                .values()
                                .any(|p| p.terminal.as_deref() == Some(id))
                            {
                                continue;
                            }
                            let key = self.allocate(cx);
                            if self.tx.try_send(Command::Adopt(key, id.into())).is_ok() {
                                self.panes.get_mut(&key).unwrap().terminal = Some(id.into());
                                self.tab_for(key);
                            } else {
                                self.panes.remove(&key);
                                self.notice = "Could not attach existing terminal".into();
                                adoption_ready = false;
                            }
                        } else {
                            adoption_ready = false;
                        }
                    }
                    if front.is_some() {
                        self.active = front;
                    }
                    self.activation.listed = Some(adoption_ready);
                    self.watch();
                }
                Update::Listed(Err(error)) => {
                    self.activation.listed = Some(false);
                    self.notice = error.to_string();
                }
                Update::Bound(key, result) => match result {
                    Ok(id) => {
                        let mut pending = vec![];
                        if let Some(p) = self.panes.get_mut(&key) {
                            p.terminal = Some(id);
                            clear_creation_notice(&mut p.notice, p.closing);
                            pending = std::mem::take(&mut p.pending);
                        }
                        for input in pending {
                            self.act(key, Action::Input(input), cx);
                        }
                        self.status_due = Instant::now();
                    }
                    Err(error) => {
                        self.notice = error.to_string();
                        self.remove(key);
                        self.focus_active(window, cx);
                    }
                },
                Update::Copied(key, ticket, revision, result) => {
                    let Some(pane) = self.panes.get_mut(&key) else {
                        continue;
                    };
                    if pane.ticket != ticket
                        || pane.closing
                        || pane
                            .frame
                            .as_ref()
                            .is_none_or(|f| f["revision"].as_u64() != Some(revision))
                    {
                        continue;
                    }
                    match result {
                        Ok(text) => {
                            let bytes = text.len();
                            cx.write_to_clipboard(ClipboardItem::new_string(text));
                            pane.notice = format!("Copied {bytes} bytes");
                        }
                        Err(error) => {
                            pane.selection.clear();
                            pane.notice = error.to_string();
                        }
                    }
                }
                Update::Closed(key, ticket, result) => {
                    if self.panes.get(&key).is_none_or(|p| p.ticket != ticket) {
                        continue;
                    }
                    match result {
                        Ok(()) => {
                            self.remove(key);
                            if self.panes.is_empty() {
                                cx.emit(TerminalContextEvent::LastClosed);
                            }
                            self.focus_active(window, cx);
                        }
                        Err(error) => {
                            let p = self.panes.get_mut(&key).unwrap();
                            p.closing = false;
                            p.notice = error.to_string();
                        }
                    }
                }
                Update::Status(list) => {
                    self.status_requested = None;
                    self.status_due = Instant::now() + STATUS_INTERVAL;
                    // A busy Engine or a failed listing only delays the tabs.
                    if let Ok(list) = list {
                        self.apply_status(&list, cx);
                    }
                }
                Update::Restarted(key, result) => {
                    let mut pending = vec![];
                    if let Some(pane) = self.panes.get_mut(&key) {
                        pane.restarting = false;
                        match result {
                            Ok(()) => {
                                pane.status = None;
                                pane.notice.clear();
                                pending = std::mem::take(&mut pane.pending);
                            }
                            Err(error) => {
                                pane.pending.clear();
                                pane.notice = format!("Terminal did not restart: {error}");
                            }
                        }
                    }
                    for input in pending {
                        self.act(key, Action::Input(input), cx);
                    }
                    self.status_due = Instant::now();
                    self.focus(key, window, cx);
                }
                Update::Frame(key, ticket, result) => {
                    let Some(pane) = self.panes.get_mut(&key) else {
                        continue;
                    };
                    if pane.ticket != ticket || pane.closing {
                        continue;
                    }
                    match result {
                        Ok(Some(frame)) => {
                            if pane.frame.as_ref().is_none_or(|old| old != &frame) {
                                let id = pane.terminal.as_deref().unwrap_or("");
                                pane.selection.sync(id, &frame);
                                pane.size = (
                                    frame["rows"].as_u64().unwrap_or(0) as u16,
                                    frame["cols"].as_u64().unwrap_or(0) as u16,
                                );
                                pane.frame = Some(frame);
                                pane.blink = Instant::now();
                            }
                        }
                        Ok(None) => {} // Never splice pages from different revisions.
                        Err(error) => {
                            pane.selection.clear();
                            pane.notice = error.to_string();
                        }
                    }
                }
            }
        }
        self.activate_pending(window, cx);
        if self.watch_dirty {
            self.watch();
        }
        // Hidden tabs keep their titles, folders and exits current too.
        if self
            .status_requested
            .is_none_or(|at| at.elapsed() >= STATUS_INTERVAL * 4)
            && Instant::now() >= self.status_due
            && self.panes.values().any(|pane| pane.terminal.is_some())
            && self.tx.try_send(Command::Status).is_ok()
        {
            self.status_requested = Some(Instant::now());
        }
        // Cursor blink uses retained frames, never synchronous engine reads.
        if changed
            || (self.visible
                && self.panes.values().any(|p| {
                    p.frame
                        .as_ref()
                        .is_some_and(|v| v["cursor"]["blinking"] == true)
                }))
        {
            cx.notify();
        }
    }
    /// Applies `terminal.status` to the panes: tab titles and folders, a bell
    /// from a visible terminal, and closing shells that exited on their own.
    fn apply_status(&mut self, list: &[Value], cx: &mut Context<Self>) {
        let visible = if self.visible { self.ids() } else { vec![] };
        let mut ring = false;
        let mut exited = vec![];
        for (key, pane) in &mut self.panes {
            let Some(id) = pane.terminal.as_deref() else {
                continue;
            };
            let Some(status) = list
                .iter()
                .find(|entry| entry["terminalId"] == id)
                .and_then(PaneStatus::parse)
            else {
                continue;
            };
            // A bell from a terminal the user can't see stays silent.
            ring |= visible.contains(key)
                && pane
                    .status
                    .as_ref()
                    .is_some_and(|old| status.bells > old.bells);
            // As in T3 Code, a shell that exits closes its terminal, unless
            // it failed right away; that pane stays to show why.
            if status.exited && !status.keep_open && !pane.closing && !pane.restarting {
                exited.push(*key);
            }
            if pane.status.as_ref() != Some(&status) {
                pane.status = Some(status);
                cx.notify();
            }
        }
        if ring {
            tabs::beep();
        }
        for key in exited {
            self.act(key, Action::Close, cx);
        }
    }
    fn revoke_inputs(&mut self, cx: &mut Context<Self>) {
        for pane in self.panes.values_mut() {
            if let Some(input) = pane.ime.take() {
                input.update(cx, |input, cx| input.revoke(cx));
            }
            pane.ime_epoch += 1;
            pane.ime_observer = None;
        }
    }
    fn submit_native(
        &mut self,
        key: PaneId,
        epoch: u64,
        input: TerminalInput,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !native_scope(
            key,
            epoch,
            self.visible,
            &self.ids(),
            self.panes
                .get(&key)
                .map(|p| (p.ime_epoch, p.focus.is_focused(window) && !p.closing)),
        ) {
            return false;
        }
        self.act(key, Action::Input(input), cx)
    }
    fn focus_active(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(tab) = self.tabs.iter().find(|t| Some(t.key) == self.active) {
            let key = tab.focus;
            self.focus(key, window, cx);
        }
    }
    fn focus(&mut self, key: PaneId, window: &mut Window, cx: &mut Context<Self>) {
        self.invalidate_context();
        if !self.visible || !self.ids().contains(&key) {
            return;
        }
        let same = self.panes.get(&key).is_some_and(|p| {
            p.focus.is_focused(window) && p.ime.as_ref().is_some_and(|ime| ime.read(cx).active)
        });
        if !same {
            self.revoke_inputs(cx);
            let owner = cx.entity().downgrade();
            let metrics = self.metrics();
            let pane = self.panes.get_mut(&key).unwrap();
            let epoch = pane.ime_epoch;
            let focus = pane.focus.clone();
            let input = cx.new(|cx| {
                let blur = cx.on_blur(&focus, window, |this: &mut PaneInput, window, cx| {
                    this.active = false;
                    this.cancel(window, cx);
                });
                let activation =
                    cx.observe_window_activation(window, |this: &mut PaneInput, window, cx| {
                        if !window.is_window_active() {
                            this.active = false;
                            this.cancel(window, cx);
                        }
                    });
                PaneInput {
                    owner,
                    key,
                    epoch,
                    focus: focus.clone(),
                    active: true,
                    composition: Default::default(),
                    native_preedit: Default::default(),
                    notice: String::new(),
                    anchor: point(px(0.), px(0.)),
                    bounds: None,
                    metrics,
                    _blur: blur,
                    _activation: activation,
                }
            });
            pane.ime_observer = Some(cx.observe(&input, |_, _, cx| cx.notify()));
            pane.ime = Some(input);
        }
        if let Some(pane) = self.panes.get(&key) {
            window.focus(&pane.focus, cx);
        }
        if let Some(tab) = self.tabs.iter_mut().find(|t| Some(t.key) == self.active) {
            tab.focus = key;
        }
        cx.notify();
    }
    fn scroll(&mut self, key: PaneId, scroll: TerminalScroll, cx: &mut Context<Self>) {
        let Some(pane) = self.panes.get(&key) else {
            return;
        };
        let Some(frame) = &pane.frame else {
            return;
        };
        if frame["viewport"]["alternateScreen"] == true {
            return;
        }
        if let Some(revision) = frame["revision"].as_u64() {
            self.act(key, Action::Scroll(revision, scroll), cx);
        }
    }
    fn wheel(&mut self, key: PaneId, event: &ScrollEvent, cx: &mut Context<Self>) {
        if event.modifiers.control || event.modifiers.platform || event.modifiers.alt {
            return;
        }
        let cell_h = self.metrics().cell_h;
        let Some(pane) = self.panes.get_mut(&key) else {
            return;
        };
        if pane
            .frame
            .as_ref()
            .is_none_or(|f| f["viewport"]["alternateScreen"] == true)
        {
            return;
        }
        let delta = event.delta.pixel_delta(px(cell_h));
        let dy = f32::from(delta.y);
        if !dy.is_finite() || dy == 0. || delta.x.abs() > delta.y.abs() {
            return;
        }
        let edge = if dy > 0. {
            pane.scroll.offset().y >= px(-1.)
        } else {
            pane.scroll.offset().y <= -pane.scroll.max_offset().y + px(1.)
        };
        if !edge && !event.modifiers.shift {
            pane.wheel = 0.;
            return;
        }
        if pane.wheel.signum() != dy.signum() {
            pane.wheel = 0.;
        }
        pane.wheel += (dy / cell_h).clamp(-40., 40.);
        let lines = pane.wheel.trunc() as i32;
        pane.wheel -= lines as f32;
        cx.stop_propagation();
        if lines != 0 {
            self.scroll(key, TerminalScroll::Lines(lines), cx);
        }
    }
    fn key(
        &mut self,
        key: PaneId,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.visible || !self.ids().contains(&key) {
            return;
        }
        self.invalidate_context();
        let k = &event.keystroke;
        let command = k.modifiers.platform || (k.modifiers.control && k.modifiers.shift);
        if command && !k.modifiers.alt && k.key.eq_ignore_ascii_case("v") {
            if let Some(input) = cx.read_from_clipboard().and_then(|c| c.text()) {
                if valid_payload(&input, true).is_ok() {
                    if self.act(key, Action::Input(TerminalInput::Paste { text: input }), cx)
                        && let Some(p) = self.panes.get_mut(&key)
                        && let Some(ime) = &p.ime
                    {
                        ime.update(cx, |i, cx| i.cancel(window, cx));
                    }
                } else if let Some(p) = self.panes.get_mut(&key) {
                    p.notice="Paste contains control framing or exceeds encoded 32 KiB limit; nothing sent".into();
                }
            }
            cx.stop_propagation();
            cx.notify();
            return;
        }
        if command && !k.modifiers.alt && k.key.eq_ignore_ascii_case("c") {
            self.copy(key, cx);
            cx.stop_propagation();
            return;
        }
        let Some(pane) = self.panes.get_mut(&key) else {
            return;
        };
        if pane
            .ime
            .as_ref()
            .is_some_and(|ime| ime.read(cx).composition.marked)
            && !command
            && !k.modifiers.control
        {
            // Candidate navigation/commit/cancel belongs to native text services.
            return;
        }
        let alternate = pane
            .frame
            .as_ref()
            .is_some_and(|f| f["viewport"]["alternateScreen"] == true);
        if k.modifiers.control
            && k.modifiers.shift
            && !k.modifiers.alt
            && !k.modifiers.platform
            && !alternate
        {
            let scroll = match k.key.as_str() {
                "pageup" => Some(TerminalScroll::PageUp),
                "pagedown" => Some(TerminalScroll::PageDown),
                "home" => Some(TerminalScroll::Top),
                "end" => Some(TerminalScroll::Bottom),
                _ => None,
            };
            if let Some(scroll) = scroll {
                self.scroll(key, scroll, cx);
                cx.stop_propagation();
                return;
            }
        }
        // Preserve Shift+navigation for alternate-screen apps. Copy/select-all
        // remain explicit UI operations; plain Ctrl+C remains a PTY interrupt.
        let navigation = matches!(
            k.key.as_str(),
            "left" | "right" | "up" | "down" | "home" | "end"
        );
        if !(alternate && navigation && !command) {
            if let (Some(id), Some(frame)) = (&pane.terminal, &pane.frame) {
                match pane.selection.key(id, frame, event, cx) {
                    Ok(true) => {
                        cx.stop_propagation();
                        cx.notify();
                        return;
                    }
                    Err(error) => {
                        pane.notice = error.to_string();
                        cx.stop_propagation();
                        cx.notify();
                        return;
                    }
                    Ok(false) => {}
                }
            } else if command && matches!(k.key.to_ascii_lowercase().as_str(), "c" | "a") {
                cx.stop_propagation();
                return;
            }
        }
        if let Some(input) = key_input(event) {
            self.act(key, Action::Input(input), cx);
            cx.stop_propagation();
        }
    }
    fn copy(&mut self, key: PaneId, cx: &mut Context<Self>) {
        if self.stopping.load(Ordering::Acquire) {
            return;
        }
        let Some(pane) = self.panes.get_mut(&key) else {
            return;
        };
        let result = (|| -> Result<Command> {
            ensure!(!pane.closing, "Terminal is closing");
            let id = pane
                .terminal
                .as_deref()
                .ok_or_else(|| anyhow::anyhow!("Wait for terminal"))?;
            let frame = pane
                .frame
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("Wait for terminal output"))?;
            let (start, end) = selection_bounds(&pane.selection, id, frame)?;
            Ok(Command::Copy(
                key,
                pane.ticket,
                frame["revision"]
                    .as_u64()
                    .ok_or_else(|| anyhow::anyhow!("Invalid revision"))?,
                start,
                end,
            ))
        })();
        match result {
            Ok(command) => {
                if self.tx.try_send(command).is_err() {
                    pane.notice = "Copy not queued; worker busy".into();
                }
            }
            Err(error) => pane.notice = error.to_string(),
        }
        cx.notify();
    }
    fn pane_view(&self, key: PaneId, window: &Window, cx: &mut Context<Self>) -> AnyElement {
        let Some(pane) = self.panes.get(&key) else {
            return div().into_any_element();
        };
        let id = pane.terminal.clone().unwrap_or_default();
        let appearance = self.appearance;
        let metrics = self.metrics();
        let (cell_w, cell_h) = (metrics.cell_w, metrics.cell_h);
        let name = pane
            .status
            .as_ref()
            .map(|status| status.name.clone())
            .unwrap_or_else(|| "Terminal".into());
        let mut body = div()
            .id(SharedString::from(format!("terminal-body-{key}")))
            .relative()
            .flex_1()
            .min_h_0()
            .min_w_0()
            .overflow_scroll()
            .track_scroll(&pane.scroll)
            .track_focus(&pane.focus)
            .role(Role::Terminal)
            .aria_label(name.clone())
            .bg(rgb(appearance.background))
            .text_color(rgb(appearance.foreground))
            .font_family(if cfg!(target_os = "macos") {
                "Menlo"
            } else {
                "monospace"
            })
            .text_size(px(metrics.font))
            .line_height(px(cell_h))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, _, window, cx| this.focus(key, window, cx)),
            )
            .on_key_down(
                cx.listener(move |this, event, window, cx| this.key(key, event, window, cx)),
            )
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(move |this, _, _, _| {
                    if let Some(p) = this.panes.get_mut(&key) {
                        p.selection.end_drag();
                    }
                }),
            )
            .on_mouse_up_out(
                MouseButton::Left,
                cx.listener(move |this, _, _, _| {
                    if let Some(p) = this.panes.get_mut(&key) {
                        p.selection.end_drag();
                    }
                }),
            )
            .on_scroll(
                cx.listener(move |this, event: &ScrollEvent, _, cx| this.wheel(key, event, cx)),
            );
        if let Some(frame) = &pane.frame {
            let stamp = stamp(frame);
            let cols = frame["cols"].as_u64().unwrap_or(0) as usize;
            let offset = frame["rowOffset"].as_u64().unwrap_or(0) as usize;
            let focused = pane.focus.is_focused(window);
            let mut grid_view = div()
                .flex()
                .flex_col()
                .flex_shrink_0()
                .w(px(cols as f32 * cell_w));
            if let Some(grid) = frame["grid"].as_array() {
                for (row_index, row_cells) in grid.iter().enumerate() {
                    let mut row = div()
                        .relative()
                        .flex()
                        .flex_shrink_0()
                        .h(px(cell_h))
                        .w_full();
                    if let Some(cells) = row_cells.as_array() {
                        for (col, cell) in cells.iter().enumerate() {
                            if cell["continuation"] == true
                                && col > 0
                                && cells[col - 1]["width"] == 2
                            {
                                continue;
                            }
                            let width = cell["width"].as_u64().unwrap_or(1).clamp(1, 2) as usize;
                            let selected = pane.selection.is_selected(
                                &id,
                                frame,
                                offset + row_index,
                                col,
                                width,
                            );
                            let down_id = id.clone();
                            let drag_id = id.clone();
                            row = row.child(
                                div()
                                    .relative()
                                    .flex_shrink_0()
                                    .w(px(width as f32 * cell_w))
                                    .h(px(cell_h))
                                    .overflow_hidden()
                                    .bg(crate::terminal_rgb(
                                        &cell["background"],
                                        appearance.background,
                                    ))
                                    .text_color(crate::terminal_rgb(
                                        &cell["foreground"],
                                        appearance.foreground,
                                    ))
                                    .when(cell["bold"] == true, |view| {
                                        view.font_weight(FontWeight::BOLD)
                                    })
                                    .when(cell["italic"] == true, |view| view.italic())
                                    .when(cell["underline"] == true, |view| view.underline())
                                    .when(cell["strikethrough"] == true, |view| view.line_through())
                                    .child(if cell["hidden"] == true {
                                        " ".repeat(width)
                                    } else {
                                        text(cell, "text")
                                    })
                                    .when(selected, |view| {
                                        view.child(div().absolute().inset_0().bg(rgba(0x648ce670)))
                                    })
                                    .on_mouse_down(
                                        MouseButton::Left,
                                        cx.listener(
                                            move |this, event: &MouseDownEvent, window, cx| {
                                                let opens = if cfg!(target_os = "macos") {
                                                    event.modifiers.platform
                                                } else {
                                                    event.modifiers.control
                                                };
                                                if opens
                                                    && !event.modifiers.shift
                                                    && this.open_link(key, row_index, col, cx)
                                                {
                                                    cx.stop_propagation();
                                                    return;
                                                }
                                                let Some(p) = this.panes.get_mut(&key) else {
                                                    return;
                                                };
                                                if !p.matches(&down_id, stamp) {
                                                    return;
                                                }
                                                p.selection.begin(
                                                    &down_id,
                                                    p.frame.as_ref().unwrap(),
                                                    offset + row_index,
                                                    col,
                                                    event.modifiers.shift,
                                                );
                                                this.focus(key, window, cx);
                                                cx.stop_propagation();
                                                cx.notify();
                                            },
                                        ),
                                    )
                                    .on_mouse_move(cx.listener(
                                        move |this, event: &MouseMoveEvent, _, cx| {
                                            if event.pressed_button != Some(MouseButton::Left) {
                                                return;
                                            }
                                            let Some(p) = this.panes.get_mut(&key) else {
                                                return;
                                            };
                                            if !p.matches(&drag_id, stamp) {
                                                return;
                                            }
                                            if p.selection.drag(
                                                &drag_id,
                                                p.frame.as_ref().unwrap(),
                                                offset + row_index,
                                                col,
                                            ) {
                                                this.context_epoch.fetch_add(1, Ordering::AcqRel);
                                                cx.notify();
                                            }
                                        },
                                    )),
                            );
                        }
                    }
                    let cursor = &frame["cursor"];
                    let blink = (pane.blink.elapsed().as_millis() / 500).is_multiple_of(2);
                    if cursor["visible"] == true
                        && cursor["row"].as_u64() == Some((offset + row_index) as u64)
                        && (!focused || cursor["blinking"] != true || blink)
                    {
                        let shape = if focused {
                            cursor["shape"].as_str().unwrap_or("block")
                        } else {
                            "hollowBlock"
                        };
                        let caret = appearance.cursor();
                        row = row.child(
                            div()
                                .absolute()
                                .left(px(cursor["col"].as_u64().unwrap_or(0) as f32 * cell_w))
                                .bottom_0()
                                .w(px(if shape == "beam" { 2. } else { cell_w }))
                                .h(px(if shape == "underline" { 2. } else { cell_h }))
                                .when(shape == "hollowBlock", |view| {
                                    view.border_1().border_color(rgb(caret))
                                })
                                .when(shape != "hollowBlock", |view| {
                                    view.bg(rgba(if shape == "block" {
                                        (caret << 8) | 0x70
                                    } else {
                                        (caret << 8) | 0xff
                                    }))
                                }),
                        );
                    }
                    grid_view = grid_view.child(row);
                }
            }
            body = body.child(grid_view);
        } else {
            body = body.child(div().p_2().child(if pane.terminal.is_some() {
                "Reading terminal…"
            } else {
                "Creating terminal…"
            }));
        }
        let mut footer = div().flex().flex_wrap().gap_1().items_center();
        let alternate = pane
            .frame
            .as_ref()
            .is_some_and(|f| f["viewport"]["alternateScreen"] == true);
        for (name, label, scroll) in [
            ("top", "History", TerminalScroll::Top),
            ("up", "Page ↑", TerminalScroll::PageUp),
            ("down", "Page ↓", TerminalScroll::PageDown),
            ("bottom", "Live", TerminalScroll::Bottom),
        ] {
            footer = footer.child(
                Button::new(SharedString::from(format!("{name}-{key}")))
                    .label(label)
                    .disabled(alternate || pane.closing || pane.frame.is_none())
                    .on_click(cx.listener(move |this, _, _, cx| this.scroll(key, scroll, cx))),
            );
        }
        footer = footer.child(
            Button::new(SharedString::from(format!("copy-{key}")))
                .label("Copy selection")
                .disabled(
                    pane.frame
                        .as_ref()
                        .is_none_or(|f| !pane.selection.has_selection(&id, f)),
                )
                .on_click(cx.listener(move |this, _, _, cx| this.copy(key, cx))),
        );
        footer = footer.child(
            Button::new(SharedString::from(format!("use-selection-{key}")))
                .label("Use selection in message")
                .tooltip(
                    "Attach selected visible terminal output as a reference; no message is sent",
                )
                .disabled(
                    self.context_pending
                        || !self.visible
                        || pane.closing
                        || pane
                            .frame
                            .as_ref()
                            .is_none_or(|f| !pane.selection.has_selection(&id, f)),
                )
                .on_click(
                    cx.listener(move |this, _, _, cx| this.request_context_selection(key, cx)),
                ),
        );
        if let Some(frame) = &pane.frame {
            footer = footer.child(div().child(format!(
                "{}×{} · {} rows above live",
                frame["cols"], frame["rows"], frame["viewport"]["displayOffset"],
            )));
        }
        let weak = cx.entity().downgrade();
        let ime = pane.ime.clone();
        let native_focus = pane.focus.clone();
        let local_scroll = pane.scroll.clone();
        let caret = pane
            .frame
            .as_ref()
            .map(|frame| {
                let row = frame["cursor"]["row"]
                    .as_i64()
                    .unwrap_or(0)
                    .clamp(0, i64::from(pane.size.0.saturating_sub(1)));
                let col = frame["cursor"]["insertionCol"]
                    .as_u64()
                    .or_else(|| frame["cursor"]["col"].as_u64())
                    .unwrap_or(0)
                    .min(u64::from(pane.size.1.saturating_sub(1)));
                point(px(col as f32 * cell_w), px(row as f32 * cell_h))
            })
            .unwrap_or_else(|| point(px(0.), px(0.)));
        let mut composition_notice = String::new();
        if let Some(input) = &ime {
            let input = input.read(cx);
            composition_notice = input.notice.clone();
            if input.active
                && input.epoch == pane.ime_epoch
                && input.composition.marked
                && pane.focus.is_focused(window)
            {
                body = body.child(
                    div()
                        .absolute()
                        .left(caret.x)
                        .top(caret.y)
                        .bg(rgb(appearance.background))
                        .text_color(rgb(appearance.foreground))
                        .underline()
                        .child(input.composition.display()),
                );
            }
        }
        // Swift's glass bar after a failed start: why, with Restart and Close.
        let banner = pane
            .status
            .as_ref()
            .filter(|status| status.exited && status.keep_open && !pane.restarting)
            .map(|status| {
                let message = status
                    .exit_message
                    .clone()
                    .unwrap_or_else(|| "Process terminated.".into());
                div()
                    .absolute()
                    .left_0()
                    .right_0()
                    .bottom(px(14.))
                    .flex()
                    .justify_center()
                    .child(
                        div()
                            .id(SharedString::from(format!("terminal-exit-{key}")))
                            .role(Role::Group)
                            .aria_label(message.clone())
                            .flex()
                            .items_center()
                            .gap_2()
                            .pl(px(14.))
                            .pr(px(8.))
                            .py(px(6.))
                            .rounded(px(16.))
                            .bg(cx.theme().popover)
                            .border_1()
                            .border_color(cx.theme().border)
                            .shadow_md()
                            .text_size(px(11.))
                            .text_color(cx.theme().muted_foreground)
                            .child(message)
                            .child(
                                Button::new(SharedString::from(format!("terminal-restart-{key}")))
                                    .label("Restart")
                                    .primary()
                                    .small()
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.focus(key, window, cx);
                                        this.restart(key, cx);
                                    })),
                            )
                            .child(
                                Button::new(SharedString::from(format!(
                                    "terminal-exit-close-{key}"
                                )))
                                .label("Close")
                                .small()
                                .on_click(cx.listener(
                                    move |this, _, window, cx| {
                                        this.request_close(vec![key], window, cx)
                                    },
                                )),
                            ),
                    )
            });
        // Swift panes have no chrome; a split tab still needs to close one.
        let close = (self.ids().len() > 1).then(|| {
            div().absolute().top(px(2.)).right(px(2.)).child(
                Button::new(SharedString::from(format!("close-{key}")))
                    .icon(IconName::Close)
                    .ghost()
                    .xsmall()
                    .accessibility_label(format!("Close {name}"))
                    .tooltip("Close Terminal")
                    .disabled(pane.closing)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.request_close(vec![key], window, cx)
                    })),
            )
        });
        div()
            .relative()
            .flex()
            .flex_col()
            .flex_1()
            .min_h_0()
            .min_w_0()
            .child(
                div()
                    .relative()
                    .flex()
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .child(
                        canvas(
                            move |bounds, _, cx| {
                                let size = viewport_size(
                                    f32::from(bounds.size.width),
                                    f32::from(bounds.size.height),
                                    metrics,
                                );
                                cx.defer(move |cx| {
                                    let _ = weak.update(cx, |this, cx| {
                                        if this.panes.get(&key).is_some_and(|p| p.size != size) {
                                            this.act(key, Action::Resize(size.0, size.1), cx);
                                        }
                                    });
                                });
                            },
                            move |bounds, _, window, cx| {
                                if native_focus.is_focused(window)
                                    && let Some(input) = ime
                                {
                                    let offset = local_scroll.offset();
                                    input.update(cx, |input, _| {
                                        input.metrics = metrics;
                                        input.bounds = Some(bounds);
                                        input.anchor = point(
                                            (bounds.left() + caret.x + offset.x)
                                                .max(bounds.left())
                                                .min(bounds.right()),
                                            (bounds.top() + caret.y + offset.y)
                                                .max(bounds.top())
                                                .min(
                                                    (bounds.bottom() - px(cell_h))
                                                        .max(bounds.top()),
                                                ),
                                        );
                                    });
                                    window.handle_input(
                                        &native_focus,
                                        ElementInputHandler::new(bounds, input),
                                        cx,
                                    );
                                }
                            },
                        )
                        .absolute()
                        .size_full(),
                    )
                    .child(body)
                    .children(banner)
                    .children(close),
            )
            .child(footer)
            .child(div().text_sm().child(pane.notice.clone()))
            .child(div().text_sm().child(composition_notice))
            .into_any_element()
    }
    /// Swift TerminalTabContentView: the tab's panes side by side or stacked
    /// with thin dividers, sharing the space equally.
    fn layout_view(&self, layout: &Layout, window: &Window, cx: &mut Context<Self>) -> AnyElement {
        let stacked = layout.axis == SplitAxis::Vertical;
        let border = cx.theme().border;
        let mut view = div()
            .flex()
            .flex_1()
            .min_w_0()
            .min_h_0()
            .when(stacked, |view| view.flex_col());
        for (index, key) in layout.panes.iter().enumerate() {
            if index > 0 {
                view = view.child(
                    div()
                        .flex_shrink_0()
                        .bg(border)
                        .when(stacked, |divider| divider.h(px(1.)).w_full())
                        .when(!stacked, |divider| divider.w(px(1.)).h_full()),
                );
            }
            view = view.child(self.pane_view(*key, window, cx));
        }
        view.into_any_element()
    }
    fn activate_tab(&mut self, key: PaneId, window: &mut Window, cx: &mut Context<Self>) {
        self.active = Some(key);
        self.watch();
        if let Some(tab) = self.tabs.iter().find(|t| t.key == key) {
            let focus = tab.focus;
            self.focus(focus, window, cx);
        }
        cx.notify();
    }
    /// The tab's ×, a middle click or its Close: every pane of the tab.
    fn close_tab(&mut self, key: PaneId, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(tab) = self.tabs.iter().find(|t| t.key == key) {
            let panes = tab.layout.panes.clone();
            self.request_close(panes, window, cx);
        }
    }
    /// Swift TerminalHeaderView: the tabs and New Terminal on the left; the
    /// working directory, the splits and Hide on the right.
    fn header(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut strip = div()
            .id("terminal-tabs")
            .role(Role::TabList)
            .aria_label("Terminal tabs")
            .flex()
            .items_center()
            .gap(px(2.))
            .min_w_0()
            .overflow_x_hidden();
        for tab in &self.tabs {
            strip = strip.child(self.tab_item(tab, cx));
        }
        let active = self.tabs.iter().find(|t| Some(t.key) == self.active);
        let directory = active
            .and_then(|tab| self.panes.get(&tab.focus))
            .and_then(|pane| pane.status.as_ref())
            .and_then(|status| status.directory.clone());
        let mut row = div()
            .id("terminal-header")
            .flex()
            .flex_shrink_0()
            .items_center()
            .h(px(30.))
            .px(px(6.))
            .gap_1()
            .border_b_1()
            .border_color(cx.theme().border)
            .child(strip)
            .child(
                Button::new("terminal-workspace-new")
                    .icon(IconName::Plus)
                    .ghost()
                    .compact()
                    .accessibility_label("New Terminal")
                    .tooltip(format!("New Terminal ({})", tabs::new_terminal_shortcut()))
                    .on_click(cx.listener(|this, _, window, cx| this.create(None, window, cx))),
            )
            .child(div().flex_1().min_w_0());
        if let Some(directory) = directory {
            row = row.child(self.directory_label(directory, cx));
        }
        if let Some(tab) = active {
            let (focus, can_split) = (tab.focus, !tab.layout.full());
            for (id, icon, label, axis) in [
                (
                    "terminal-split-right",
                    IconName::PanelRight,
                    "Split Right",
                    SplitAxis::Horizontal,
                ),
                (
                    "terminal-split-down",
                    IconName::PanelBottom,
                    "Split Down",
                    SplitAxis::Vertical,
                ),
            ] {
                row = row.child(
                    Button::new(id)
                        .icon(icon)
                        .ghost()
                        .compact()
                        .accessibility_label(label)
                        .tooltip(if can_split {
                            format!("{label} ({})", tabs::split_shortcut(axis))
                        } else {
                            tabs::TAB_FULL.into()
                        })
                        .disabled(!can_split)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.create(Some((focus, axis)), window, cx)
                        })),
                );
            }
        }
        row.child(
            Button::new("terminal-hide")
                .icon(IconName::ChevronDown)
                .ghost()
                .compact()
                .accessibility_label("Hide Terminal")
                .tooltip("Hide Terminal")
                .on_click(cx.listener(|_, _, _, cx| cx.emit(TerminalContextEvent::HideRequested))),
        )
        .into_any_element()
    }
    /// One tab: an icon (or its progress), the title and a close button that
    /// shows on hover. The title dims once the shell exits.
    fn tab_item(&self, tab: &Tab, cx: &mut Context<Self>) -> AnyElement {
        let key = tab.key;
        let selected = Some(key) == self.active;
        let theme = cx.theme();
        let (foreground, muted) = (theme.foreground, theme.muted_foreground);
        let (danger, warning) = (theme.danger, theme.warning);
        let status = self
            .panes
            .get(&tab.focus)
            .and_then(|pane| pane.status.as_ref());
        let title = status
            .map(|status| status.name.clone())
            .unwrap_or_else(|| "Terminal".into());
        let exited = status.is_some_and(|status| status.exited);
        let progress = status.and_then(|status| status.progress);
        let tooltip = tabs::tab_tooltip(
            tab.layout
                .panes
                .iter()
                .filter_map(|id| self.panes.get(id)?.status.as_ref()),
            progress,
        );
        let label = progress
            .map(|progress| format!("{title}, {}", progress.description()))
            .unwrap_or_else(|| title.clone());
        let icon = match (tab.layout.panes.len(), tab.layout.axis) {
            (1, _) => IconName::SquareTerminal,
            (_, SplitAxis::Horizontal) => IconName::PanelRight,
            (_, SplitAxis::Vertical) => IconName::PanelBottom,
        };
        let glyph = match progress {
            Some(progress) if progress.ring() => {
                ProgressCircle::new(SharedString::from(format!("terminal-tab-progress-{key}")))
                    .loading(progress.state == ProgressState::Indeterminate)
                    .value(f32::from(progress.percent.unwrap_or(0)))
                    .xsmall()
                    .into_any_element()
            }
            Some(progress) if progress.state == ProgressState::Error => {
                Icon::new(IconName::TriangleAlert)
                    .xsmall()
                    .text_color(danger)
                    .into_any_element()
            }
            Some(_) => Icon::new(IconName::Pause)
                .xsmall()
                .text_color(warning)
                .into_any_element(),
            None => Icon::new(icon)
                .xsmall()
                .text_color(if selected { foreground } else { muted })
                .into_any_element(),
        };
        let group = SharedString::from(format!("terminal-tab-{key}"));
        div()
            .id(group.clone())
            .group(group.clone())
            .role(Role::Tab)
            .aria_label(label)
            .aria_selected(selected)
            .flex()
            .items_center()
            .gap(px(5.))
            .h(px(22.))
            .min_w(px(72.))
            .max_w(px(200.))
            .pl(px(8.))
            .pr(px(4.))
            .rounded(px(4.))
            .cursor_pointer()
            .when(selected, |item| item.bg(foreground.opacity(0.1)))
            .when(!selected, |item| {
                item.hover(|style| style.bg(foreground.opacity(0.05)))
            })
            .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
            .on_click(cx.listener(move |this, _, window, cx| this.activate_tab(key, window, cx)))
            // Middle-click closes, as in browsers and editors.
            .on_mouse_up(
                MouseButton::Middle,
                cx.listener(move |this, _, window, cx| this.close_tab(key, window, cx)),
            )
            .child(glyph)
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(px(11.))
                    .text_color(if exited {
                        muted.opacity(0.6)
                    } else if selected {
                        foreground
                    } else {
                        muted
                    })
                    .child(title.clone()),
            )
            .child(
                Button::new(SharedString::from(format!("terminal-tab-close-{key}")))
                    .icon(IconName::Close)
                    .ghost()
                    .xsmall()
                    .accessibility_label(format!("Close {title}"))
                    .tooltip(format!("Close {title}"))
                    .when(!selected, |button| {
                        button
                            .opacity(0.)
                            .group_hover(group, |button| button.opacity(1.))
                    })
                    .on_click(cx.listener(move |this, _, window, cx| {
                        cx.stop_propagation();
                        this.close_tab(key, window, cx)
                    })),
            )
            .into_any_element()
    }
    /// The active terminal's folder, with Copy Path and Reveal in Finder.
    fn directory_label(&self, directory: String, cx: &mut Context<Self>) -> AnyElement {
        let muted = cx.theme().muted_foreground;
        let shown = tabs::abbreviate(&directory);
        let tooltip = directory.clone();
        let copy = directory.clone();
        let reveal = std::path::PathBuf::from(&directory);
        div()
            .id("terminal-directory")
            .role(Role::Label)
            .aria_label(format!("Working directory {directory}"))
            .flex()
            .items_center()
            .gap_1()
            .min_w_0()
            .mr(px(6.))
            .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
            .child(
                Icon::new(IconName::Folder)
                    .xsmall()
                    .text_color(muted.opacity(0.7)),
            )
            .child(
                div()
                    .min_w_0()
                    .truncate()
                    .text_size(px(11.))
                    .text_color(muted)
                    .child(shown),
            )
            .context_menu(move |menu, _, _| {
                let copy = copy.clone();
                let reveal = reveal.clone();
                menu.item(PopupMenuItem::new("Copy Path").on_click(move |_, _, cx| {
                    cx.write_to_clipboard(ClipboardItem::new_string(copy.clone()))
                }))
                .item(
                    PopupMenuItem::new(tabs::reveal_label())
                        .on_click(move |_, _, cx| cx.reveal_path(&reveal)),
                )
            })
            .into_any_element()
    }
}
impl Drop for TerminalWorkspace {
    fn drop(&mut self) {
        // This transport owns no shell. Receiver destruction releases blocked
        // bounded publishers; the background observer retains its actual join.
        self.stopping.store(true, Ordering::Release);
    }
}
impl Render for TerminalWorkspace {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.visible
            && window.is_window_active()
            && let Some(key) = self.ids().into_iter().find(|key| {
                self.panes.get(key).is_some_and(|p| {
                    p.focus.is_focused(window)
                        && p.ime.as_ref().is_none_or(|ime| !ime.read(cx).active)
                })
            })
        {
            self.focus(key, window, cx);
        }
        let mut root = div()
            .flex()
            .flex_col()
            .size_full()
            .min_h_0()
            .min_w_0()
            .bg(rgb(self.appearance.background))
            .child(self.header(cx));
        if let Some(tab) = self.tabs.iter().find(|t| Some(t.key) == self.active) {
            root = root.child(self.layout_view(&tab.layout, window, cx));
        } else {
            // Swift TerminalEmptyStateView.
            let muted = cx.theme().muted_foreground;
            root = root.child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .items_center()
                    .justify_center()
                    .gap(px(10.))
                    .child(
                        Icon::new(IconName::SquareTerminal)
                            .large()
                            .text_color(muted.opacity(0.6)),
                    )
                    .child(
                        div()
                            .text_color(muted)
                            .child("No terminal sessions for this thread yet."),
                    )
                    .child(
                        Button::new("terminal-empty-new")
                            .label("New Terminal")
                            .primary()
                            .tooltip(format!("New Terminal ({})", tabs::new_terminal_shortcut()))
                            .on_click(
                                cx.listener(|this, _, window, cx| this.create(None, window, cx)),
                            ),
                    ),
            );
        }
        root.child(div().text_sm().child(self.notice.clone()))
    }
}

// The PTY takes the whole pane (Swift sizes the terminal to it), within Core's
// 300-row, 500-column bound; the coherent reader returns every visible row.
fn viewport_size(width: f32, height: f32, metrics: Metrics) -> (u16, u16) {
    let width = if width.is_finite() { width } else { 0. };
    let height = if height.is_finite() { height } else { 0. };
    let rows = (height / metrics.cell_h).floor().clamp(2., 300.) as u16;
    let cols = (width / metrics.cell_w).floor().clamp(2., 500.) as u16;
    (rows, cols)
}
type Stamp = (u64, u64, u64, u64);
fn stamp(frame: &Value) -> Option<Stamp> {
    Some((
        frame["revision"].as_u64()?,
        frame["rowOffset"].as_u64()?,
        frame["cols"].as_u64()?,
        frame["grid"].as_array()?.len() as u64,
    ))
}

fn key_input(event: &KeyDownEvent) -> Option<TerminalInput> {
    let k = &event.keystroke;
    // Printable characters (including AltGr) are committed by native text input.
    // Sending key_char here as well would duplicate insertText/IME commits.
    if event.prefer_character_input || k.modifiers.platform {
        return None;
    }
    let name = match k.key.as_str() {
        "pageup" => "pageUp",
        "pagedown" => "pageDown",
        other => other,
    };
    let special = matches!(
        name,
        "up" | "down"
            | "left"
            | "right"
            | "home"
            | "end"
            | "pageUp"
            | "pageDown"
            | "insert"
            | "delete"
            | "enter"
            | "backspace"
            | "tab"
            | "escape"
    );
    if !special
        && !(k.modifiers.control
            && name.len() == 1
            && (b'@'..=b'_').contains(&name.as_bytes()[0].to_ascii_uppercase()))
    {
        return None;
    }
    Some(TerminalInput::Key {
        key: name.into(),
        modifiers: KeyModifiers {
            shift: k.modifiers.shift,
            alt: k.modifiers.alt,
            control: k.modifiers.control,
        },
    })
}

// Recover inclusive coordinates through the actual selection helper rather than
// duplicating its wide-cell, drag, keyboard-boundary or revision semantics.
fn selection_bounds(
    selection: &TerminalSelection,
    id: &str,
    frame: &Value,
) -> Result<(TerminalPoint, TerminalPoint)> {
    ensure!(
        selection.has_selection(id, frame),
        "Select terminal text first"
    );
    let offset = frame["rowOffset"]
        .as_u64()
        .ok_or_else(|| anyhow::anyhow!("Invalid row offset"))? as usize;
    let count = frame["grid"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("Invalid grid"))?
        .len();
    let cols = frame["cols"]
        .as_u64()
        .ok_or_else(|| anyhow::anyhow!("Invalid columns"))? as usize;
    ensure!(
        count <= 300 && cols <= 500,
        "Selection exceeds viewport bound"
    );
    let mut first = None;
    let mut last = None;
    for row in offset..offset + count {
        for col in 0..cols {
            if selection.is_selected(id, frame, row, col, 1) {
                let point = TerminalPoint { row, col };
                first.get_or_insert(point);
                last = Some(point);
            }
        }
    }
    first
        .zip(last)
        .ok_or_else(|| anyhow::anyhow!("Selection changed; select again"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use coincide_core::terminal::selected_text;
    use std::sync::{Arc, Mutex};

    #[::core::prelude::v1::test]
    fn explicit_open_waits_for_listing_and_never_duplicates_adopted_or_failed_shells() {
        let mut state = Activation {
            requested: true,
            ..Activation::default()
        };
        assert_eq!(state.take(true, false, false), Activate::None);
        state.listed = Some(true);
        assert_eq!(state.take(true, true, false), Activate::Focus);
        assert_eq!(state.take(true, false, false), Activate::None);
        state.requested = true;
        assert_eq!(state.take(true, false, false), Activate::Create);
        assert_eq!(
            state.take(true, false, false),
            Activate::None,
            "only one create per explicit open"
        );
        state.requested = true;
        state.listed = Some(false);
        assert_eq!(state.take(true, false, false), Activate::None);
        state.listed = Some(true);
        assert_eq!(
            state.take(true, false, false),
            Activate::None,
            "failed discovery cannot authorize a later create"
        );
        state.requested = true;
        assert_eq!(state.take(false, false, false), Activate::None);
        assert_eq!(
            state.take(true, false, false),
            Activate::None,
            "hiding cancels first-open activation"
        );
        state.requested = true;
        assert_eq!(
            state.take(true, false, true),
            Activate::None,
            "shutdown never starts a shell"
        );
    }
    #[::core::prelude::v1::test]
    fn stopping_ui_worker_releases_bounded_publisher_and_discards_queued_create() {
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let (commands, rx) = mpsc::sync_channel(2);
        let (tx, updates) = mpsc::sync_channel(1);
        tx.send(Update::Listed(Ok(vec![]))).unwrap();
        commands.send(Command::Create(1, None)).unwrap();
        let (entered, started) = mpsc::channel();
        let (release, wait) = mpsc::channel();
        let calls = Arc::new(Mutex::new(Vec::new()));
        let log = calls.clone();
        let worker = std::thread::spawn(move || {
            run_worker(
                "synthetic".into(),
                rx,
                tx,
                &stopping,
                move |method, _| {
                    log.lock().unwrap().push(method.to_owned());
                    entered.send(()).unwrap();
                    wait.recv().unwrap();
                    Ok(json!([]))
                },
                |_| unreachable!(),
                |_, _| unreachable!(),
            );
        });
        let completion = coincide_core::agent::WorkerCompletion::observe(worker);
        started.recv_timeout(Duration::from_secs(3)).unwrap();
        stop.store(true, Ordering::Release);
        release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while completion.status() == coincide_core::agent::WorkerThreadStatus::Running {
            for _ in updates.try_iter() {}
            assert!(
                Instant::now() < deadline,
                "terminal transport failed to join"
            );
            std::thread::yield_now();
        }
        assert_eq!(
            completion.status(),
            coincide_core::agent::WorkerThreadStatus::Returned
        );
        assert_eq!(*calls.lock().unwrap(), ["terminal.list"]);
    }

    #[::core::prelude::v1::test]
    fn splitting_missing_pane_does_not_change_other_tabs() {
        let mut a = Layout::single(1);
        let b = Layout::single(7);
        assert!(!a.split(7, 8, SplitAxis::Vertical));
        assert_eq!(a, Layout::single(1));
        assert_eq!(b, Layout::single(7));
    }
    #[::core::prelude::v1::test]
    fn viewports_fill_the_pane_follow_the_font_and_stay_inside_core_limits() {
        let metrics = Metrics::default();
        assert_eq!((metrics.cell_w, metrics.cell_h), (8., 18.));
        assert_eq!(viewport_size(800., 432., metrics), (24, 100));
        assert_eq!(viewport_size(400., 216., metrics), (12, 50));
        // A tall panel shows every row it has room for, not 40.
        assert_eq!(viewport_size(800., 1080., metrics), (60, 100));
        assert_eq!(viewport_size(0., 0., metrics), (2, 2));
        assert_eq!(viewport_size(f32::NAN, f32::INFINITY, metrics), (2, 2));
        assert_eq!(viewport_size(99999., 99999., metrics), (300, 500));
        let large = Metrics::for_font(18.);
        assert_eq!((large.cell_w, large.cell_h), (12., 27.));
        assert_eq!(viewport_size(1200., 540., large), (20, 100));
        assert_eq!(Metrics::for_font(f32::NAN), metrics);
        assert_eq!(Metrics::for_font(100.).font, 23.);
    }
    #[::core::prelude::v1::test]
    fn only_return_restarts_an_exited_shell_and_framing_never_waits_for_one() {
        let key = |key: &str| TerminalInput::Key {
            key: key.into(),
            modifiers: KeyModifiers::default(),
        };
        assert!(submits(&key("enter")));
        assert!(submits(&TerminalInput::Paste {
            text: "make\r".into()
        }));
        assert!(!submits(&key("tab")));
        assert!(!submits(&TerminalInput::Text { text: "q".into() }));
        assert!(valid_input(&TerminalInput::Text {
            text: "ls\r".into()
        }));
        assert!(!valid_input(&TerminalInput::Text {
            text: "\u{1b}[2J".into()
        }));
        let light = TerminalAppearance {
            dark: false,
            foreground: 0x010203,
            background: 0xfafafa,
            font_size: 13.,
        };
        assert_eq!(
            light.palette(),
            Palette {
                dark: false,
                foreground: [1, 2, 3],
                background: [0xfa; 3],
            }
        );
        assert_eq!(light.cursor(), 0x26384e);
        assert_eq!(TerminalAppearance::default().palette(), Palette::default());
    }
    fn event(key: &str, modifiers: Modifiers, chars: Option<&str>) -> KeyDownEvent {
        KeyDownEvent {
            keystroke: Keystroke {
                key: key.into(),
                modifiers,
                key_char: chars.map(str::to_owned),
            },
            is_held: false,
            prefer_character_input: false,
        }
    }
    #[::core::prelude::v1::test]
    fn navigation_keeps_modifiers_and_defers_mode_encoding_to_core() {
        let input = key_input(&event(
            "pageup",
            Modifiers {
                control: true,
                shift: true,
                ..Default::default()
            },
            None,
        ))
        .unwrap();
        assert_eq!(
            serde_json::to_value(input).unwrap(),
            json!({"kind":"key","key":"pageUp","modifiers":{"shift":true,"control":true,"alt":false}})
        );
        let input = key_input(&event(
            "c",
            Modifiers {
                control: true,
                ..Default::default()
            },
            None,
        ))
        .unwrap();
        assert!(matches!(input,TerminalInput::Key{key,..} if key=="c"));
        assert!(
            matches!(key_input(&event("enter",Default::default(),None)),Some(TerminalInput::Key{key,..}) if key=="enter")
        );
        assert!(
            key_input(&event(
                "q",
                Modifiers {
                    platform: true,
                    ..Default::default()
                },
                None
            ))
            .is_none()
        );
    }
    #[::core::prelude::v1::test]
    fn unicode_and_altgr_characters_have_only_native_commit_path() {
        let mut altgr = event(
            "q",
            Modifiers {
                control: true,
                alt: true,
                ..Default::default()
            },
            Some("@"),
        );
        altgr.prefer_character_input = true;
        assert!(key_input(&altgr).is_none());
        assert!(key_input(&event("e", Default::default(), Some("e\u{301}"))).is_none());
        assert!(
            key_input(&event(
                "x",
                Modifiers {
                    alt: true,
                    ..Default::default()
                },
                Some("x")
            ))
            .is_none()
        );
    }
    fn frame() -> Value {
        json!({"revision":7,"rows":2,"cols":4,"rowOffset":0,"rowCount":2,"grid":[
            [{"text":"界","width":2},{"text":"","width":0,"continuation":true},{"text":"e\u{301}","width":1},{"text":"S","width":1,"hidden":true}],
            [{"text":"x","width":1},{"text":" ","width":1},{"text":" ","width":1},{"text":" ","width":1}]
        ]})
    }
    #[::core::prelude::v1::test]
    fn copy_bounds_reuse_real_selection_with_wide_combining_and_concealed_cells() {
        let frame = frame();
        let mut selection = TerminalSelection::default();
        selection.begin("first", &frame, 0, 3, false);
        selection.drag("first", &frame, 0, 1);
        let (a, b) = selection_bounds(&selection, "first", &frame).unwrap();
        assert_eq!((a.row, a.col, b.row, b.col), (0, 1, 0, 3));
        let copy = selected_text(&frame, a, b).unwrap();
        assert_eq!(copy, "界e\u{301}");
        assert!(!copy.contains('S'));
        assert!(selection_bounds(&selection, "other", &frame).is_err());
        let mut next = frame.clone();
        next["revision"] = json!(8);
        assert!(selection_bounds(&selection, "first", &next).is_err());
        assert!(selection.sync("first", &next));
        assert!(!selection.has_selection("first", &next));
    }

    struct FakeWorker {
        tx: SyncSender<Command>,
        rx: Receiver<Update>,
        log: Arc<Mutex<Vec<(String, Value)>>>,
        handle: std::thread::JoinHandle<()>,
    }
    impl FakeWorker {
        fn new() -> Self {
            let (tx, commands) = mpsc::sync_channel(64);
            let (updates, rx) = mpsc::sync_channel(32);
            let log = Arc::new(Mutex::new(vec![]));
            let calls = log.clone();
            let handle = std::thread::spawn(move || {
                let mut creates = 0;
                run_worker(
                    "thread-A".into(),
                    commands,
                    updates,
                    &AtomicBool::new(false),
                    move |method, params| {
                        calls
                            .lock()
                            .unwrap()
                            .push((method.to_owned(), params.clone()));
                        if method == "terminal.input"
                            && params["input"]["text"] == "fixture-rejected-input"
                        {
                            anyhow::bail!("fixture PTY queue full");
                        }
                        Ok(match method {
                            "terminal.list" => json!([]),
                            "terminal.create" => {
                                creates += 1;
                                json!({"terminalId":format!("created-{creates}")})
                            }
                            "terminal.selection" => {
                                ensure!(params["revision"] == 7, "Stale fixture revision");
                                json!({"text":"界e\u{301} ","revision":7})
                            }
                            _ => json!({}),
                        })
                    },
                    |terminal| Ok(Some(json!({"terminalId":terminal,"revision":7}))),
                    |_, _| anyhow::bail!("No attach allocated in this worker fixture"),
                );
            });
            let worker = Self {
                tx,
                rx,
                log,
                handle,
            };
            assert!(matches!(worker.next(), Update::Listed(Ok(_))));
            worker
        }
        fn next(&self) -> Update {
            self.rx
                .recv_timeout(Duration::from_secs(3))
                .expect("worker reply timeout")
        }
        fn finish(self) {
            drop(self.tx);
            drop(self.rx);
            self.handle.join().unwrap();
        }
    }
    #[::core::prelude::v1::test]
    fn worker_bound_clears_only_pending_creation_notice_and_keeps_real_failure() {
        let w = FakeWorker::new();
        let mut notice = WAIT_FOR_TERMINAL_CREATION.to_owned();
        w.tx.send(Command::Create(10, None)).unwrap();
        assert!(matches!(w.next(), Update::Bound(10, Ok(_))));
        clear_creation_notice(&mut notice, false);
        assert!(notice.is_empty());

        w.tx.send(Command::Act(
            10,
            1,
            Action::Input(TerminalInput::Text {
                text: "fixture-rejected-input".into(),
            }),
        ))
        .unwrap();
        let Update::ActionFailed(10, failure) = w.next() else {
            panic!("worker must report the rejected input");
        };
        assert!(failure.contains("fixture PTY queue full"));
        notice = failure.clone();
        w.tx.send(Command::Create(20, None)).unwrap();
        assert!(matches!(w.next(), Update::Bound(20, Ok(_))));
        clear_creation_notice(&mut notice, false);
        assert_eq!(notice, failure);
        // A close in flight must not lose its notice on a late Bound result.
        notice = WAIT_FOR_TERMINAL_CREATION.into();
        clear_creation_notice(&mut notice, true);
        assert_eq!(notice, WAIT_FOR_TERMINAL_CREATION);
        notice = "Terminal close failed: fixture refusal".into();
        clear_creation_notice(&mut notice, false);
        assert_eq!(notice, "Terminal close failed: fixture refusal");
        w.finish();
    }
    #[::core::prelude::v1::test]
    fn worker_create_is_explicit_and_writes_remain_independently_bound() {
        let w = FakeWorker::new();
        assert_eq!(w.log.lock().unwrap().len(), 1);
        w.tx.send(Command::Create(10, None)).unwrap();
        w.tx.send(Command::Create(20, None)).unwrap();
        assert!(matches!(w.next(),Update::Bound(10,Ok(id)) if id=="created-1"));
        assert!(matches!(w.next(),Update::Bound(20,Ok(id)) if id=="created-2"));
        w.tx.send(Command::Act(
            10,
            1,
            Action::Input(TerminalInput::Text {
                text: "literal\n".into(),
            }),
        ))
        .unwrap();
        w.tx.send(Command::Act(20, 1, Action::Resize(12, 50)))
            .unwrap();
        w.tx.send(Command::Act(10, 2, Action::Close)).unwrap();
        assert!(matches!(w.next(), Update::Closed(10, 2, Ok(()))));
        let log = w.log.lock().unwrap().clone();
        assert_eq!(
            log[1],
            ("terminal.create".into(), json!({"threadId":"thread-A"}))
        );
        assert_eq!(
            log[3],
            (
                "terminal.input".into(),
                json!({"terminalId":"created-1","input":{"kind":"text","text":"literal\n"}})
            )
        );
        assert_eq!(
            log[4],
            (
                "terminal.resize".into(),
                json!({"terminalId":"created-2","rows":12,"cols":50})
            )
        );
        assert_eq!(
            log[5],
            ("terminal.close".into(), json!({"terminalId":"created-1"}))
        );
        w.finish();
    }
    #[::core::prelude::v1::test]
    fn worker_script_create_names_its_script_and_binds_like_a_shell() {
        let w = FakeWorker::new();
        let script = "0A5C0A5C-1111-4111-8111-000000000001";
        w.tx.send(Command::Create(30, Some(script.into()))).unwrap();
        assert!(matches!(w.next(), Update::Bound(30, Ok(id)) if id == "created-1"));
        w.tx.send(Command::Create(31, None)).unwrap();
        assert!(matches!(w.next(), Update::Bound(31, Ok(id)) if id == "created-2"));
        let log = w.log.lock().unwrap().clone();
        assert_eq!(
            log[1],
            (
                "terminal.create".into(),
                json!({"threadId":"thread-A","scriptId":script})
            )
        );
        assert_eq!(
            log[2],
            ("terminal.create".into(), json!({"threadId":"thread-A"}))
        );
        w.finish();
    }
    #[::core::prelude::v1::test]
    fn late_write_failure_survives_newer_input_and_frame_tickets_without_retry() {
        let w = FakeWorker::new();
        w.tx.send(Command::Adopt(1, "one".into())).unwrap();
        w.tx.send(Command::Act(
            1,
            1,
            Action::Input(TerminalInput::Text {
                text: "fixture-rejected-input".into(),
            }),
        ))
        .unwrap();
        w.tx.send(Command::Act(
            1,
            2,
            Action::Input(TerminalInput::Text {
                text: "next input".into(),
            }),
        ))
        .unwrap();
        w.tx.send(Command::Watch(vec![1])).unwrap();
        // Even after UI advances to ticket2, the rejected write travels as an
        // independent error, not an obsolete ticket1 frame that UI discards.
        assert!(
            matches!(w.next(), Update::ActionFailed(1, message) if message == "Terminal input was not sent: fixture PTY queue full")
        );
        assert!(matches!(w.next(), Update::Frame(1, 2, Ok(Some(_)))));
        let writes = w
            .log
            .lock()
            .unwrap()
            .iter()
            .filter(|(method, _)| method == "terminal.input")
            .map(|(_, params)| params["input"]["text"].clone())
            .collect::<Vec<_>>();
        assert_eq!(
            writes,
            vec![json!("fixture-rejected-input"), json!("next input")]
        );
        w.finish();
    }
    #[::core::prelude::v1::test]
    fn real_worker_waits_for_engine_contention_before_listing_without_spawning_shells() {
        struct FixtureDirectory(std::path::PathBuf);
        impl Drop for FixtureDirectory {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let directory = FixtureDirectory(std::env::temp_dir().join(format!(
            "coincide-terminal-contention-{}",
            uuid::Uuid::new_v4()
        )));
        std::fs::create_dir(&directory.0).unwrap();
        let engine = Arc::new(Mutex::new(coincide_core::api::Engine::new(
            coincide_core::store::Store::open(&directory.0.join("data.sqlite")).unwrap(),
        )));
        let guard = engine.lock().unwrap();
        let (commands, rx) = mpsc::sync_channel(4);
        let (tx, updates) = mpsc::sync_channel(4);
        let (started, ready) = mpsc::sync_channel(1);
        let shared = engine.clone();
        let handle = std::thread::spawn(move || {
            started.send(()).unwrap();
            worker(
                shared,
                "fixture-thread".into(),
                rx,
                tx,
                Arc::new(AtomicBool::new(false)),
                Arc::new(Mutex::new(Palette::default())),
            );
        });
        ready.recv_timeout(Duration::from_secs(3)).unwrap();
        assert!(matches!(
            updates.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        drop(guard);
        assert!(
            matches!(updates.recv_timeout(Duration::from_secs(3)).unwrap(),Update::Listed(Ok(tabs)) if tabs.is_empty())
        );
        drop(commands);
        drop(updates);
        handle.join().unwrap();
    }
    #[::core::prelude::v1::test]
    fn worker_copy_uses_api_revision_and_rejects_pre_input_ticket() {
        let w = FakeWorker::new();
        let a = TerminalPoint { row: 0, col: 1 };
        let b = TerminalPoint { row: 0, col: 3 };
        w.tx.send(Command::Adopt(1, "one".into())).unwrap();
        w.tx.send(Command::Act(
            1,
            1,
            Action::Input(TerminalInput::Text { text: "x".into() }),
        ))
        .unwrap();
        w.tx.send(Command::Copy(1, 0, 7, a, b)).unwrap();
        assert!(matches!(w.next(), Update::Copied(1, 0, 7, Err(_))));
        w.tx.send(Command::Copy(1, 1, 6, a, b)).unwrap();
        assert!(matches!(w.next(), Update::Copied(1, 1, 6, Err(_))));
        w.tx.send(Command::Copy(1, 1, 7, a, b)).unwrap();
        assert!(matches!(w.next(),Update::Copied(1,1,7,Ok(text)) if text=="界e\u{301} "));
        let log = w.log.lock().unwrap().clone();
        assert_eq!(
            log.iter()
                .filter(|(method, _)| method == "terminal.selection")
                .count(),
            2
        );
        assert_eq!(
            log.last().unwrap().1,
            json!({"terminalId":"one","revision":7,"start":{"row":0,"col":1},"end":{"row":0,"col":3}})
        );
        w.finish();
    }
    #[::core::prelude::v1::test]
    fn worker_frames_carry_pane_ticket_and_closed_sibling_does_not_receive_reads() {
        let w = FakeWorker::new();
        w.tx.send(Command::Adopt(1, "one".into())).unwrap();
        w.tx.send(Command::Adopt(2, "two".into())).unwrap();
        w.tx.send(Command::Act(1, 1, Action::Close)).unwrap();
        assert!(matches!(w.next(), Update::Closed(1, 1, Ok(()))));
        w.tx.send(Command::Act(
            2,
            9,
            Action::Scroll(7, TerminalScroll::Lines(3)),
        ))
        .unwrap();
        w.tx.send(Command::Watch(vec![1, 2])).unwrap();
        assert!(
            matches!(w.next(),Update::Frame(2,9,Ok(Some(frame))) if frame["terminalId"]=="two")
        );
        let log = w.log.lock().unwrap().clone();
        assert_eq!(
            log.last().unwrap().1,
            json!({"terminalId":"two","revision":7,"scroll":{"kind":"lines","lines":3}})
        );
        w.finish();
    }
    #[::core::prelude::v1::test]
    fn composition_ranges_are_utf16_and_cannot_edit_terminal_output() {
        let mut state = Composition::default();
        state.stage(None, "A😀e\u{301}", Some(3..5)).unwrap();
        assert_eq!(state.selected, 3..5);
        assert_eq!(byte_range(&state.text, 1..3), Some(1..5));
        assert!(byte_range(&state.text, 2..3).is_none());
        let before = state.text.clone();
        assert!(state.stage(Some(2..3), "x", None).is_err());
        assert_eq!(state.text, before);
        state.stage(Some(1..3), "界", Some(0..1)).unwrap();
        assert_eq!(state.text, "A界e\u{301}");
        assert_eq!(state.selected, 1..2);
        state.clear();
        assert!(state.replacement(Some(0..1), "x").is_err());
        assert!(state.text.is_empty());
    }
    #[::core::prelude::v1::test]
    fn invalid_composition_selection_is_atomic_and_never_splits_surrogate() {
        let mut state = Composition::default();
        state.stage(None, "old", None).unwrap();
        assert!(state.stage(None, "😀", Some(1..1)).is_err());
        assert_eq!(state.text, "old");
        assert_eq!(state.selected, 3..3);
        assert!(state.stage(None, "\x1b[201~", None).is_err());
        assert_eq!(state.text, "old");
    }
    #[::core::prelude::v1::test]
    fn composition_preedit_changes_never_queue_until_one_commit() {
        let w = FakeWorker::new();
        w.tx.send(Command::Adopt(1, "one".into())).unwrap();
        let mut state = Composition::default();
        for preedit in ["n", "ni", "に", "日本"] {
            state.stage(None, preedit, None).unwrap();
        }
        assert_eq!(
            w.log
                .lock()
                .unwrap()
                .iter()
                .filter(|(method, _)| method == "terminal.input")
                .count(),
            0
        );
        let (text, _) = state.replacement(None, "日本語").unwrap();
        w.tx.send(Command::Act(
            1,
            1,
            Action::Input(TerminalInput::Text { text }),
        ))
        .unwrap();
        state.clear(); // Successful native commit clears staging; unmark sends no input.
        state.clear();
        w.tx.send(Command::Act(1, 2, Action::Close)).unwrap();
        assert!(matches!(w.next(), Update::Closed(1, 2, Ok(()))));
        let inputs = w
            .log
            .lock()
            .unwrap()
            .iter()
            .filter(|(method, _)| method == "terminal.input")
            .map(|(_, params)| params.clone())
            .collect::<Vec<_>>();
        assert_eq!(
            inputs,
            vec![json!({"terminalId":"one","input":{"kind":"text","text":"日本語"}})]
        );
        w.finish();
    }
    #[::core::prelude::v1::test]
    fn composition_cancel_clears_marking_selection_and_editable_text() {
        let mut state = Composition::default();
        state.stage(None, "私の文", Some(1..2)).unwrap();
        state.clear();
        assert!(!state.marked);
        assert!(state.text.is_empty());
        assert_eq!(state.selected, 0..0);
        assert_eq!(state.replacement(None, "次").unwrap().0, "次");
    }
    #[::core::prelude::v1::test]
    fn payload_limits_are_utf8_and_never_permit_embedded_framing() {
        assert!(valid_payload(&"💡".repeat(8192), false).is_ok());
        assert!(valid_payload(&"💡".repeat(8193), false).is_err());
        for text in ["\x1b[201~", "\x03", "\u{9b}", "\0", "\x7f"] {
            assert!(valid_payload(text, true).is_err());
        }
        assert!(valid_payload("界e\u{301}\r\n\t", true).is_ok());
        let mut state = Composition::default();
        state.stage(None, "a\nb\tc", None).unwrap();
        assert_eq!(state.display(), "a b c");
        assert_eq!(state.text, "a\nb\tc");
    }
    #[::core::prelude::v1::test]
    fn worker_preserves_text_paste_key_variants_without_ui_mode_encoding() {
        let w = FakeWorker::new();
        w.tx.send(Command::Adopt(1, "one".into())).unwrap();
        w.tx.send(Command::Act(
            1,
            1,
            Action::Input(TerminalInput::Paste {
                text: "literal\n".into(),
            }),
        ))
        .unwrap();
        let key = key_input(&event("up", Default::default(), None)).unwrap();
        w.tx.send(Command::Act(1, 2, Action::Input(key))).unwrap();
        w.tx.send(Command::Act(1, 3, Action::Close)).unwrap();
        assert!(matches!(w.next(), Update::Closed(1, 3, Ok(()))));
        let inputs = w
            .log
            .lock()
            .unwrap()
            .iter()
            .filter(|(method, _)| method == "terminal.input")
            .map(|(_, params)| params["input"].clone())
            .collect::<Vec<_>>();
        assert_eq!(
            inputs,
            vec![
                json!({"kind":"paste","text":"literal\n"}),
                json!({"kind":"key","key":"up","modifiers":{"shift":false,"alt":false,"control":false}})
            ]
        );
        w.finish();
    }
    #[::core::prelude::v1::test]
    fn revoked_or_hidden_native_sessions_cannot_route_into_another_pane() {
        assert!(native_scope(1, 4, true, &[1, 2], Some((4, true))));
        assert!(!native_scope(1, 4, true, &[1, 2], Some((5, true)))); // old focus generation
        assert!(!native_scope(1, 4, false, &[1, 2], Some((4, true)))); // hidden thread
        assert!(!native_scope(1, 4, true, &[2, 3], Some((4, true)))); // another tab
        assert!(!native_scope(1, 4, true, &[1, 2], Some((4, false)))); // closed/unfocused/unbound
        assert!(!native_scope(1, 4, true, &[1, 2], None)); // removed pane
    }
    #[::core::prelude::v1::test]
    fn native_context_belongs_to_one_preedit_session_and_cancels_exactly_once() {
        let mut native = PreeditContext::default();
        let mut state = Composition::default();
        state.stage(None, "´", None).unwrap();
        native.stage(|| Some("left-context"));
        native.stage(|| panic!("preedit updates must keep their original context"));
        let mut cancelled = Vec::new();
        state.cancel(&mut native, |context| cancelled.push(context));
        state.cancel(&mut native, |context| cancelled.push(context));
        assert_eq!(cancelled, ["left-context"]);
        assert!(!state.marked);
        assert!(state.text.is_empty());
        assert_eq!(state.selected, 0..0);
        native.stage(|| Some("next-context"));
        native.committed();
        native.cancel(|_| panic!("successful native commit must not be cancelled"));
    }
    #[::core::prelude::v1::test]
    fn pane_switch_cancels_native_dead_key_before_right_pane_commit() {
        let worker = FakeWorker::new();
        worker.tx.send(Command::Adopt(1, "left".into())).unwrap();
        worker.tx.send(Command::Adopt(2, "right".into())).unwrap();
        let pending = std::rc::Rc::new(std::cell::RefCell::new(Some("´".to_owned())));
        let mut left = Composition::default();
        let mut native = PreeditContext::default();
        left.stage(None, "´", None).unwrap();
        native.stage(|| Some(pending.clone()));
        // Use the exact cancellation operation shared by blur/hide/close/focus
        // revocation. Like App::defer, run the native reset after releasing the
        // old component's borrow but before accepting the next input event.
        let mut deferred: Vec<Box<dyn FnOnce()>> = Vec::new();
        left.cancel(&mut native, |context| {
            deferred.push(Box::new(move || {
                context.borrow_mut().take();
            }))
        });
        assert_eq!(pending.borrow().as_deref(), Some("´"));
        for reset in deferred {
            reset();
        }
        let native_commit = format!("{}c", pending.borrow().as_deref().unwrap_or_default());
        let right = Composition::default();
        let text = right.replacement(None, &native_commit).unwrap().0;
        assert_eq!(text.as_bytes(), &[99]);
        worker
            .tx
            .send(Command::Act(
                2,
                1,
                Action::Input(TerminalInput::Text { text }),
            ))
            .unwrap();
        worker.tx.send(Command::Act(2, 2, Action::Close)).unwrap();
        assert!(matches!(worker.next(), Update::Closed(2, 2, Ok(()))));
        let inputs = worker
            .log
            .lock()
            .unwrap()
            .iter()
            .filter(|(method, _)| method == "terminal.input")
            .map(|(_, params)| params.clone())
            .collect::<Vec<_>>();
        assert_eq!(
            inputs,
            vec![json!({"terminalId":"right","input":{"kind":"text","text":"c"}})]
        );
        assert!(left.text.is_empty());
        worker.finish();
    }
    #[::core::prelude::v1::test]
    fn same_pane_native_commit_preserves_accents_and_literal_prefixes() {
        for committed in ["é", "´c", "日本語", "e\u{301}"] {
            let mut state = Composition::default();
            let mut native = PreeditContext::default();
            state.stage(None, "´", None).unwrap();
            native.stage(|| Some("same-pane"));
            assert_eq!(state.replacement(None, committed).unwrap().0, committed);
            state.clear();
            native.committed();
            native.cancel(|_| panic!("a successful commit must not reset native input"));
            assert!(valid_payload(committed, false).is_ok());
        }
    }
}
