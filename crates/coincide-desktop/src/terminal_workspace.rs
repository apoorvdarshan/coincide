//! Thread-bound terminal tabs and binary splits. Parent mount:
//! `cx.new(|cx| TerminalWorkspace::new(engine.clone(), thread_id, window, cx))`.
//! Cache the Entity per thread to retain layouts. Recreating it adopts existing
//! PTYs as tabs; dropping it never closes shells. Only explicit Close does.
//!
//! Uses the parent's coherent styled-frame reader and cell renderer conventions,
//! and the existing TerminalSelection/Alacritty projection (never ANSI stripping).
//! All engine calls run on one serialized worker. No shell commands are generated.
//! Mode-sensitive input is encoded by terminal.input in core; native IME preedit
//! is local to a revocable per-pane focus session and never edits shell output.
//! Swift's shell integration: ⌘↑/⌘↓ (Ctrl+↑/↓ elsewhere) jump between the
//! prompts the shell marked, and ⇧⌘L (Ctrl+Shift+L) or the context menu sends
//! the last command's output to the composer.
use crate::terminal_selection::TerminalSelection;
#[path = "terminal_context.rs"]
mod context;
use anyhow::{Result, ensure};
use coincide_core::{
    api::SharedEngine,
    store::text,
    terminal::{KeyModifiers, TerminalInput, TerminalPoint, TerminalScroll},
};
pub(crate) use context::{ComposerBaseline, SelectionRequest, TerminalContextEvent};
use gpui_kit::{
    base::Disableable,
    component::{
        button::*,
        menu::{ContextMenuExt, PopupMenuItem},
    },
    prelude::FluentBuilder,
    *,
};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    ops::Range,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, SyncSender},
    },
    time::{Duration, Instant},
};

const MAX_PANES: usize = 32;
const CELL_W: f32 = 8.;
const CELL_H: f32 = 18.;
type PaneId = u64;

/// Horizontal = side by side; Vertical = stacked. Each split has equal shares.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SplitAxis {
    Horizontal,
    Vertical,
}
#[derive(Clone, Debug, PartialEq, Eq)]
enum Layout {
    Pane(PaneId),
    Split(SplitAxis, Box<Layout>, Box<Layout>),
}
impl Layout {
    fn panes(&self, out: &mut Vec<PaneId>) {
        match self {
            Self::Pane(id) => out.push(*id),
            Self::Split(_, a, b) => {
                a.panes(out);
                b.panes(out);
            }
        }
    }
    fn split(&mut self, target: PaneId, next: PaneId, axis: SplitAxis) -> bool {
        match self {
            Self::Pane(id) if *id == target => {
                *self = Self::Split(
                    axis,
                    Box::new(Self::Pane(target)),
                    Box::new(Self::Pane(next)),
                );
                true
            }
            Self::Split(_, a, b) => a.split(target, next, axis) || b.split(target, next, axis),
            _ => false,
        }
    }
    fn without(self, target: PaneId) -> Option<Self> {
        match self {
            Self::Pane(id) => (id != target).then_some(Self::Pane(id)),
            Self::Split(axis, a, b) => match (a.without(target), b.without(target)) {
                (Some(a), Some(b)) => Some(Self::Split(axis, Box::new(a), Box::new(b))),
                (a, b) => a.or(b),
            },
        }
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
                    .map(|p| (p.ime_epoch, !p.closing && p.terminal.is_some())),
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
        window.text_system().shape_line(text, px(12.), &[run], None)
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
            .min((element.bottom() - px(CELL_H)).max(element.top()));
        Some(Bounds::from_corners(
            point(x, y),
            point(right, y + px(CELL_H)),
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
        }
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
    /// To the previous (-1) or next (+1) marked prompt, from the frame of this
    /// revision and display offset.
    JumpPrompt {
        revision: u64,
        offset: u64,
        direction: i32,
    },
    /// Swift's Clear: the scrollback goes and the shell redraws its prompt.
    Clear,
    Close,
}
/// Swift jumpToCommand: the nearest marked prompt above the top of the view
/// (-1) or below it (+1), and past the last one the live bottom. A mark's
/// displayOffset is the one that puts its prompt at the top of the view.
fn prompt_jump(marks: &Value, current: u64, direction: i32) -> Option<TerminalScroll> {
    let offsets = marks
        .as_array()?
        .iter()
        .filter_map(|mark| mark["displayOffset"].as_u64());
    let target = if direction < 0 {
        offsets.filter(|offset| *offset > current).min()
    } else {
        offsets.filter(|offset| *offset < current).max()
    };
    match target {
        Some(target) => Some(TerminalScroll::Lines(
            i32::try_from(i64::try_from(target).ok()? - i64::try_from(current).ok()?).ok()?,
        )),
        None if direction > 0 && current > 0 => Some(TerminalScroll::Bottom),
        None => None,
    }
}
/// ⌘↑ and ⌘↓ on macOS, Ctrl+↑ and Ctrl+↓ elsewhere (as VS Code's terminal).
fn prompt_jump_key(keystroke: &Keystroke) -> Option<i32> {
    let m = &keystroke.modifiers;
    let held = if cfg!(target_os = "macos") {
        m.platform && !m.control
    } else {
        m.control && !m.platform
    };
    if !held || m.shift || m.alt {
        return None;
    }
    match keystroke.key.as_str() {
        "up" => Some(-1),
        "down" => Some(1),
        _ => None,
    }
}
/// ⇧⌘L on macOS, Ctrl+Shift+L elsewhere.
fn send_output_key(keystroke: &Keystroke) -> bool {
    let m = &keystroke.modifiers;
    let held = if cfg!(target_os = "macos") {
        m.platform && !m.control
    } else {
        m.control && !m.platform
    };
    held && m.shift && !m.alt && keystroke.key.eq_ignore_ascii_case("l")
}
enum Command {
    Adopt(PaneId, String),
    /// A new shell; with a project script id it also types that script.
    Create(PaneId, Option<String>),
    Watch(Vec<PaneId>),
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
        |id| match crate::read_terminal_frame(&engine, id, 0) {
            Err(error) if crate::engine_busy(&error) => Ok(None),
            result => result,
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
            Ok(Command::Act(key, ticket, action)) => {
                let closing = matches!(action, Action::Close);
                let failure = match &action {
                    Action::Input(_) => "Terminal input was not sent",
                    Action::Resize(_, _) => "Terminal resize failed",
                    Action::Scroll(_, _) | Action::JumpPrompt { .. } => "Terminal scroll failed",
                    Action::Clear => "Terminal clear failed",
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
                        Action::JumpPrompt {
                            revision,
                            offset,
                            direction,
                        } => {
                            let marks = call(
                                "terminal.prompt_marks",
                                json!({"terminalId":id,"revision":revision}),
                            )?;
                            if let Some(scroll) = prompt_jump(&marks["marks"], offset, direction) {
                                call(
                                    "terminal.scroll",
                                    json!({"terminalId":id,"revision":revision,"scroll":scroll}),
                                )?;
                            }
                        }
                        Action::Clear => {
                            call("terminal.clear", json!({"terminalId":id}))?;
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
        let worker =
            std::thread::spawn(move || worker(engine, worker_thread, commands, updates, stop));
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
            _poll: poll,
        }
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
            layout: Layout::Pane(key),
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
                        if let Some(p) = self.panes.get_mut(&key) {
                            p.terminal = Some(id);
                            clear_creation_notice(&mut p.notice, p.closing);
                        }
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
            self.panes.get(&key).map(|p| {
                (
                    p.ime_epoch,
                    p.focus.is_focused(window) && !p.closing && p.terminal.is_some(),
                )
            }),
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
        let delta = event.delta.pixel_delta(px(CELL_H));
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
        pane.wheel += (dy / CELL_H).clamp(-40., 40.);
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
            self.paste(key, window, cx);
            cx.stop_propagation();
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
        // Only a shell that marks its prompts has prompts to jump to.
        let marked = pane
            .frame
            .as_ref()
            .is_some_and(|f| f["shell"]["hasMarks"] == true);
        if marked
            && !alternate
            && let Some(direction) = prompt_jump_key(k)
        {
            self.jump_prompt(key, direction, cx);
            cx.stop_propagation();
            return;
        }
        if marked && send_output_key(k) {
            self.request_last_output(key, cx);
            cx.stop_propagation();
            return;
        }
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
    fn paste(&mut self, key: PaneId, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(input) = cx.read_from_clipboard().and_then(|c| c.text()) {
            if valid_payload(&input, true).is_ok() {
                if self.act(key, Action::Input(TerminalInput::Paste { text: input }), cx)
                    && let Some(p) = self.panes.get_mut(&key)
                    && let Some(ime) = &p.ime
                {
                    ime.update(cx, |i, cx| i.cancel(window, cx));
                }
            } else if let Some(p) = self.panes.get_mut(&key) {
                p.notice =
                    "Paste contains control framing or exceeds encoded 32 KiB limit; nothing sent"
                        .into();
            }
        }
        cx.notify();
    }
    fn jump_prompt(&mut self, key: PaneId, direction: i32, cx: &mut Context<Self>) {
        let Some(frame) = self.panes.get(&key).and_then(|pane| pane.frame.as_ref()) else {
            return;
        };
        let (Some(revision), Some(offset)) = (
            frame["revision"].as_u64(),
            frame["viewport"]["displayOffset"].as_u64(),
        ) else {
            return;
        };
        self.act(
            key,
            Action::JumpPrompt {
                revision,
                offset,
                direction,
            },
            cx,
        );
    }
    fn select_all(&mut self, key: PaneId, cx: &mut Context<Self>) {
        if let Some(pane) = self.panes.get_mut(&key)
            && let (Some(id), Some(frame)) = (&pane.terminal, &pane.frame)
        {
            pane.selection.select_all(id, frame);
            self.context_epoch.fetch_add(1, Ordering::AcqRel);
            cx.notify();
        }
    }
    fn clear(&mut self, key: PaneId, cx: &mut Context<Self>) {
        if let Some(pane) = self.panes.get_mut(&key) {
            pane.selection.clear();
        }
        self.act(key, Action::Clear, cx);
    }
    /// Swift's terminal context menu, for the pane that was right-clicked.
    fn context_menu(
        weak: WeakEntity<Self>,
        key: PaneId,
        menu: gpui_kit::component::menu::PopupMenu,
        cx: &App,
    ) -> gpui_kit::component::menu::PopupMenu {
        let Some(this) = weak.upgrade() else {
            return menu;
        };
        let this = this.read(cx);
        let Some(pane) = this.panes.get(&key) else {
            return menu;
        };
        let id = pane.terminal.clone().unwrap_or_default();
        let frame = pane.frame.as_ref();
        let selected = frame.is_some_and(|f| pane.selection.has_selection(&id, f));
        let running = !pane.closing
            && pane.terminal.is_some()
            && frame.is_some_and(|f| f["exitCode"].is_null());
        let attachable = this.visible && !this.context_pending && !pane.closing;
        let marked = frame.is_some_and(|f| f["shell"]["hasMarks"] == true);
        let has_command = frame.is_some_and(|f| f["shell"]["command"].is_string());
        let scrolled_up = frame.is_some_and(|f| {
            f["viewport"]["displayOffset"].as_u64().unwrap_or(0) > 0
                && f["viewport"]["alternateScreen"] != true
        });
        let can_split = this.panes.len() < MAX_PANES;
        let item =
            |label: &'static str,
             enabled: bool,
             run: fn(&mut Self, PaneId, &mut Window, &mut Context<Self>)| {
                let weak = weak.clone();
                PopupMenuItem::new(label)
                    .disabled(!enabled)
                    .on_click(move |_, window, cx| {
                        let _ = weak.update(cx, |this, cx| run(this, key, window, cx));
                    })
            };
        let mut menu = menu
            .item(item("Copy", selected, |this, key, _, cx| {
                this.copy(key, cx)
            }))
            .item(item("Paste", running, |this, key, window, cx| {
                this.paste(key, window, cx)
            }))
            .item(item("Select All", frame.is_some(), |this, key, _, cx| {
                this.select_all(key, cx)
            }))
            .separator()
            .item(item(
                "Add Selection to Composer",
                attachable && selected,
                |this, key, _, cx| this.request_context_selection(key, cx),
            ));
        if marked {
            menu = menu.item(item(
                "Send Last Command’s Output to Agent",
                attachable && has_command,
                |this, key, _, cx| this.request_last_output(key, cx),
            ));
        }
        menu = menu
            .separator()
            .item(item("Clear", running, |this, key, _, cx| {
                this.clear(key, cx)
            }));
        if scrolled_up {
            menu = menu.item(item("Jump to Bottom", true, |this, key, _, cx| {
                this.scroll(key, TerminalScroll::Bottom, cx)
            }));
        }
        menu.separator()
            .item(item("New Terminal", can_split, |this, _, window, cx| {
                this.create(None, window, cx)
            }))
            .item(item("Split Right", can_split, |this, key, window, cx| {
                this.create(Some((key, SplitAxis::Horizontal)), window, cx)
            }))
            .item(item("Split Down", can_split, |this, key, window, cx| {
                this.create(Some((key, SplitAxis::Vertical)), window, cx)
            }))
            .separator()
            .item(item(
                "Close Terminal",
                !pane.closing && pane.terminal.is_some(),
                |this, key, _, cx| {
                    this.act(key, Action::Close, cx);
                },
            ))
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
        let title = pane
            .frame
            .as_ref()
            .map(|f| text(f, "title"))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "Terminal".into());
        let mut header = div().flex().items_center().gap_1().flex_wrap().child(
            div()
                .flex_1()
                .child(title.chars().take(28).collect::<String>()),
        );
        for (name, label, axis) in [
            ("horizontal", "Split ↔", SplitAxis::Horizontal),
            ("vertical", "Split ↕", SplitAxis::Vertical),
        ] {
            header = header.child(
                Button::new(SharedString::from(format!("{name}-{key}")))
                    .label(label)
                    .disabled(pane.closing)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.create(Some((key, axis)), None, window, cx)
                    })),
            );
        }
        header = header
            .child(
                Button::new(SharedString::from(format!("focus-{key}")))
                    .label("Focus")
                    .on_click(cx.listener(move |this, _, window, cx| this.focus(key, window, cx))),
            )
            .child(
                Button::new(SharedString::from(format!("close-{key}")))
                    .label("Close")
                    .disabled(pane.closing || pane.terminal.is_none())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.act(key, Action::Close, cx);
                    })),
            );
        let mut body = div()
            .id(SharedString::from(format!("terminal-body-{key}")))
            .relative()
            .flex_1()
            .min_h_0()
            .min_w_0()
            .overflow_scroll()
            .track_scroll(&pane.scroll)
            .track_focus(&pane.focus)
            .bg(rgb(0x0c0c0c))
            .font_family(if cfg!(target_os = "macos") {
                "Menlo"
            } else {
                "monospace"
            })
            .text_size(px(12.))
            .line_height(px(CELL_H))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, _, window, cx| this.focus(key, window, cx)),
            )
            // The context menu acts on the pane that was clicked, so it takes focus.
            .on_mouse_down(
                MouseButton::Right,
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
                .w(px(cols as f32 * CELL_W));
            if let Some(grid) = frame["grid"].as_array() {
                for (row_index, row_cells) in grid.iter().enumerate() {
                    let mut row = div()
                        .relative()
                        .flex()
                        .flex_shrink_0()
                        .h(px(CELL_H))
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
                                    .w(px(width as f32 * CELL_W))
                                    .h(px(CELL_H))
                                    .overflow_hidden()
                                    .bg(crate::terminal_rgb(&cell["background"], 0x0c0c0c))
                                    .text_color(crate::terminal_rgb(&cell["foreground"], 0xd4d4d4))
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
                        row = row.child(
                            div()
                                .absolute()
                                .left(px(cursor["col"].as_u64().unwrap_or(0) as f32 * CELL_W))
                                .bottom_0()
                                .w(px(if shape == "beam" { 2. } else { CELL_W }))
                                .h(px(if shape == "underline" { 2. } else { CELL_H }))
                                .when(shape == "hollowBlock", |view| {
                                    view.border_1().border_color(rgb(0xb4cbff))
                                })
                                .when(shape != "hollowBlock", |view| {
                                    view.bg(rgba(if shape == "block" {
                                        0xb4cbff70
                                    } else {
                                        0xb4cbffff
                                    }))
                                }),
                        );
                    }
                    grid_view = grid_view.child(row);
                }
            }
            body = body.child(grid_view);
        } else {
            body = body.child(if pane.terminal.is_some() {
                "Reading terminal…"
            } else {
                "Creating terminal…"
            });
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
                    "{}×{} · {} rows above live{}",
                    frame["cols"],
                    frame["rows"],
                    frame["viewport"]["displayOffset"],
                    frame["exitCode"]
                        .as_i64()
                        .map(|v| format!(" · exited {v}"))
                        .unwrap_or_default()
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
                point(px(col as f32 * CELL_W), px(row as f32 * CELL_H))
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
                        .bg(rgb(0x0c0c0c))
                        .text_color(rgb(0xd4d4d4))
                        .underline()
                        .child(input.composition.display()),
                );
            }
        }
        div()
            .relative()
            .flex()
            .flex_col()
            .flex_1()
            .min_h_0()
            .min_w_0()
            .border_1()
            .border_color(if pane.focus.is_focused(window) {
                rgb(0x648ce6)
            } else {
                rgb(0x303540)
            })
            .child(header)
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
                                        input.bounds = Some(bounds);
                                        input.anchor = point(
                                            (bounds.left() + caret.x + offset.x)
                                                .max(bounds.left())
                                                .min(bounds.right()),
                                            (bounds.top() + caret.y + offset.y)
                                                .max(bounds.top())
                                                .min(
                                                    (bounds.bottom() - px(CELL_H))
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
                    .child({
                        let weak = cx.entity().downgrade();
                        body.context_menu(move |menu, _, cx| {
                            Self::context_menu(weak.clone(), key, menu, cx)
                        })
                    }),
            )
            .child(footer)
            .child(div().text_sm().child(pane.notice.clone()))
            .child(div().text_sm().child(composition_notice))
            .into_any_element()
    }
    fn layout_view(&self, layout: &Layout, window: &Window, cx: &mut Context<Self>) -> AnyElement {
        match layout {
            Layout::Pane(key) => self.pane_view(*key, window, cx),
            Layout::Split(axis, a, b) => div()
                .flex()
                .flex_1()
                .min_w_0()
                .min_h_0()
                .gap_1()
                .when(*axis == SplitAxis::Vertical, |view| view.flex_col())
                .child(self.layout_view(a, window, cx))
                .child(self.layout_view(b, window, cx))
                .into_any_element(),
        }
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
        let mut tabs = div().flex().gap_1().items_center().flex_wrap();
        for tab in &self.tabs {
            let key = tab.key;
            let title = self
                .panes
                .get(&tab.focus)
                .and_then(|p| p.frame.as_ref())
                .map(|f| text(f, "title"))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "Terminal".into());
            tabs = tabs.child(
                Button::new(SharedString::from(format!("terminal-tab-{key}")))
                    .label(format!(
                        "{}{}",
                        if Some(key) == self.active { "● " } else { "" },
                        title.chars().take(20).collect::<String>()
                    ))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.active = Some(key);
                        this.watch();
                        if let Some(tab) = this.tabs.iter().find(|t| t.key == key) {
                            let focus = tab.focus;
                            this.focus(focus, window, cx);
                        }
                        cx.notify();
                    })),
            );
        }
        tabs = tabs.child(
            Button::new("terminal-workspace-new")
                .label("New terminal")
                .on_click(cx.listener(|this, _, window, cx| this.create(None, None, window, cx))),
        );
        let mut root = div()
            .flex()
            .flex_col()
            .size_full()
            .min_h_0()
            .min_w_0()
            .gap_1()
            .child(tabs);
        if let Some(tab) = self.tabs.iter().find(|t| Some(t.key) == self.active) {
            root = root.child(self.layout_view(&tab.layout, window, cx));
        } else {
            root = root.child(div().child(
                "Open a terminal to start. Existing PTYs remain running when this view is hidden.",
            ));
        }
        root.child(div().text_sm().child(self.notice.clone()))
    }
}

// Bound to the shared coherent-frame reader's 40-row page. Resizing the PTY to
// the actual pane (up to that bound) avoids cropping live output after splitting.
fn viewport_size(width: f32, height: f32) -> (u16, u16) {
    let width = if width.is_finite() { width } else { 0. };
    let height = if height.is_finite() { height } else { 0. };
    let rows = (height / CELL_H).floor().clamp(2., 40.) as u16;
    let cols = (width / CELL_W).floor().clamp(2., 500.) as u16;
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
        count <= 40 && cols <= 500,
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

    fn leaves(layout: &Layout) -> Vec<PaneId> {
        let mut out = vec![];
        layout.panes(&mut out);
        out
    }
    #[::core::prelude::v1::test]
    fn nested_splits_close_only_target_and_collapse_empty_branches() {
        let mut layout = Layout::Pane(1);
        assert!(layout.split(1, 2, SplitAxis::Horizontal));
        assert!(layout.split(2, 3, SplitAxis::Vertical));
        assert_eq!(leaves(&layout), vec![1, 2, 3]);
        let layout = layout.without(2).unwrap();
        assert_eq!(
            layout,
            Layout::Split(
                SplitAxis::Horizontal,
                Box::new(Layout::Pane(1)),
                Box::new(Layout::Pane(3))
            )
        );
        let layout = layout.without(1).unwrap();
        assert_eq!(layout, Layout::Pane(3));
        assert!(layout.without(3).is_none());
    }
    #[::core::prelude::v1::test]
    fn splitting_missing_pane_does_not_change_other_tabs() {
        let mut a = Layout::Pane(1);
        let b = Layout::Pane(7);
        assert!(!a.split(7, 8, SplitAxis::Vertical));
        assert_eq!(a, Layout::Pane(1));
        assert_eq!(b, Layout::Pane(7));
    }
    #[::core::prelude::v1::test]
    fn prompt_jumps_go_to_the_nearest_marked_prompt_then_the_live_bottom() {
        let marks = json!([
            {"line":-40,"col":0,"displayOffset":40},
            {"line":-12,"col":0,"displayOffset":12},
            {"line":3,"col":0,"displayOffset":0}
        ]);
        let lines = |scroll: Option<TerminalScroll>| match scroll {
            Some(TerminalScroll::Lines(lines)) => Some(lines),
            Some(TerminalScroll::Bottom) => Some(i32::MIN),
            _ => None,
        };
        // From the live bottom, up to the newest earlier prompt, then the next.
        assert_eq!(lines(prompt_jump(&marks, 0, -1)), Some(12));
        assert_eq!(lines(prompt_jump(&marks, 12, -1)), Some(28));
        assert_eq!(lines(prompt_jump(&marks, 40, -1)), None);
        // Down from a prompt to the next one, which is live.
        assert_eq!(lines(prompt_jump(&marks, 40, 1)), Some(-28));
        assert_eq!(lines(prompt_jump(&marks, 12, 1)), Some(-12));
        assert_eq!(lines(prompt_jump(&marks, 0, 1)), None);
        // Past the last mark, down goes to the bottom.
        assert_eq!(lines(prompt_jump(&json!([]), 7, 1)), Some(i32::MIN));
        assert_eq!(lines(prompt_jump(&json!([]), 7, -1)), None);
    }
    #[::core::prelude::v1::test]
    fn shell_integration_shortcuts_follow_each_platform() {
        let key = |key: &str, modifiers: Modifiers| Keystroke {
            modifiers,
            key: key.into(),
            key_char: None,
        };
        let command = if cfg!(target_os = "macos") {
            Modifiers::command()
        } else {
            Modifiers::control()
        };
        assert_eq!(prompt_jump_key(&key("up", command)), Some(-1));
        assert_eq!(prompt_jump_key(&key("down", command)), Some(1));
        assert_eq!(prompt_jump_key(&key("up", Modifiers::none())), None);
        assert_eq!(
            prompt_jump_key(&key(
                "up",
                Modifiers {
                    shift: true,
                    ..command
                }
            )),
            None
        );
        assert!(send_output_key(&key(
            "l",
            Modifiers {
                shift: true,
                ..command
            }
        )));
        assert!(!send_output_key(&key("l", command)));
        assert!(!send_output_key(&key(
            "k",
            Modifiers {
                shift: true,
                ..command
            }
        )));
    }
    #[::core::prelude::v1::test]
    fn split_viewports_use_cell_metrics_and_stay_inside_parser_limits() {
        assert_eq!(viewport_size(800., 432.), (24, 100));
        assert_eq!(viewport_size(400., 216.), (12, 50));
        assert_eq!(viewport_size(0., 0.), (2, 2));
        assert_eq!(viewport_size(f32::NAN, f32::INFINITY), (2, 2));
        assert_eq!(viewport_size(99999., 99999.), (40, 500));
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
