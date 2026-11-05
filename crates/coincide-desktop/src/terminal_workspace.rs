//! Thread-bound terminal tabs and binary splits. Parent mount:
//! `cx.new(|cx| TerminalWorkspace::new(engine.clone(), thread_id, window, cx))`.
//! Cache the Entity per thread to retain layouts. Recreating it adopts existing
//! PTYs as tabs; dropping it never closes shells. Only explicit Close does.
//!
//! Uses the parent's coherent styled-frame reader and cell renderer conventions,
//! and the existing TerminalSelection/Alacritty projection (never ANSI stripping).
//! All engine calls run on one serialized worker. No shell commands are generated.
use crate::terminal_selection::TerminalSelection;
use anyhow::{Result, ensure};
use coincide_core::{
    api::SharedEngine,
    store::text,
    terminal::{TerminalPoint, TerminalScroll},
};
use gpui_kit::{base::Disableable, component::button::*, prelude::FluentBuilder, *};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    sync::mpsc::{self, Receiver, SyncSender},
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
    Write(String),
    Resize(u16, u16),
    Scroll(u64, TerminalScroll),
    Close,
}
enum Command {
    Adopt(PaneId, String),
    Create(PaneId),
    Watch(Vec<PaneId>),
    Copy(PaneId, u64, u64, TerminalPoint, TerminalPoint),
    Act(PaneId, u64, Action),
}
enum Update {
    Listed(Result<Vec<Value>>),
    Bound(PaneId, Result<String>),
    Frame(PaneId, u64, Result<Option<Value>>),
    Closed(PaneId, u64, Result<()>),
    Copied(PaneId, u64, u64, Result<String>),
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

fn worker(engine: SharedEngine, thread: String, rx: Receiver<Command>, tx: SyncSender<Update>) {
    run_worker(
        thread,
        rx,
        tx,
        // This serialized worker is off the UI thread. Wait for Engine ownership
        // rather than dropping a keystroke/list/create during normal contention.
        |method, params| coincide_core::api::call(&engine, method, params),
        |id| match crate::read_terminal_frame(&engine, id, 0) {
            Err(error) if crate::engine_busy(&error) => Ok(None),
            result => result,
        },
    );
}

fn run_worker(
    thread: String,
    rx: Receiver<Command>,
    tx: SyncSender<Update>,
    mut call: impl FnMut(&str, Value) -> Result<Value>,
    mut read: impl FnMut(&str) -> Result<Option<Value>>,
) {
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
        match rx.recv_timeout(Duration::from_millis(30)) {
            Ok(Command::Adopt(key, id)) => {
                bound.insert(
                    key,
                    Binding {
                        terminal: id,
                        ticket: 0,
                    },
                );
            }
            Ok(Command::Create(key)) => {
                let result = call("terminal.create", json!({"threadId":thread})).and_then(|v| {
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
                    Action::Write(_) => "Terminal input was not sent",
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
                        Action::Write(input) => {
                            call("terminal.write", json!({"terminalId":id,"text":input}))?;
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
                } else if let Err(error) = result {
                    if !send(
                        &tx,
                        Update::ActionFailed(key, format!("{failure}: {error}")),
                    ) {
                        return;
                    }
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

pub struct TerminalWorkspace {
    thread: String,
    tabs: Vec<Tab>,
    active: Option<PaneId>,
    panes: HashMap<PaneId, Pane>,
    next: PaneId,
    tx: SyncSender<Command>,
    rx: Receiver<Update>,
    notice: String,
    visible: bool,
    watch_dirty: bool,
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
        std::thread::spawn(move || worker(engine, worker_thread, commands, updates));
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
            visible: true,
            watch_dirty: false,
            _poll: poll,
        }
    }
    /// Parent must not rebind this entity to another thread. Cache one entity per
    /// thread; old queued input can only address that entity's original PTYs.
    pub fn thread_id(&self) -> &str {
        &self.thread
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
        self.visible = visible;
        self.watch();
        cx.notify();
    }
    fn watch(&mut self) {
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
    fn create(
        &mut self,
        split: Option<(PaneId, SplitAxis)>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.panes.len() >= MAX_PANES {
            self.notice = "At most 32 terminal panes".into();
            cx.notify();
            return;
        }
        let key = self.allocate(cx);
        if self.tx.try_send(Command::Create(key)).is_err() {
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
        window.focus(&self.panes[&key].focus, cx);
        self.watch();
        cx.notify();
    }
    fn act(&mut self, key: PaneId, action: Action, cx: &mut Context<Self>) {
        let Some(pane) = self.panes.get_mut(&key) else {
            return;
        };
        if pane.closing || pane.terminal.is_none() {
            pane.notice = "Wait for terminal creation".into();
            cx.notify();
            return;
        }
        let ticket = pane.ticket + 1;
        if self
            .tx
            .try_send(Command::Act(key, ticket, action.clone()))
            .is_err()
        {
            pane.notice = "Input not sent: terminal worker queue full".into();
            cx.notify();
            return;
        }
        pane.ticket = ticket;
        pane.selection.clear();
        pane.blink = Instant::now();
        if matches!(action, Action::Close) {
            pane.closing = true;
        }
        if let Action::Resize(rows, cols) = action {
            pane.size = (rows, cols);
            pane.frame = None;
        }
        cx.notify();
    }
    fn remove(&mut self, key: PaneId) {
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
        let mut changed = false;
        for _ in 0..64 {
            let Ok(update) = self.rx.try_recv() else {
                break;
            };
            changed = true;
            match update {
                Update::ActionFailed(key, message) => {
                    if let Some(pane) = self.panes.get_mut(&key) {
                        // Do not discard a lost-input warning because newer
                        // keystrokes or resize operations advanced this pane.
                        pane.notice = message;
                    }
                }
                Update::Listed(Ok(tabs)) => {
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
                            }
                        }
                    }
                    self.watch();
                }
                Update::Listed(Err(error)) => self.notice = error.to_string(),
                Update::Bound(key, result) => match result {
                    Ok(id) => {
                        if let Some(p) = self.panes.get_mut(&key) {
                            p.terminal = Some(id);
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
    fn focus_active(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(tab) = self.tabs.iter().find(|t| Some(t.key) == self.active) {
            let key = tab.focus;
            self.focus(key, window, cx);
        }
    }
    fn focus(&mut self, key: PaneId, window: &mut Window, cx: &mut Context<Self>) {
        if !self.visible || !self.ids().contains(&key) {
            return;
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
    fn key(&mut self, key: PaneId, event: &KeyDownEvent, cx: &mut Context<Self>) {
        if !self.visible || !self.ids().contains(&key) {
            return;
        }
        let k = &event.keystroke;
        let command = k.modifiers.platform || (k.modifiers.control && k.modifiers.shift);
        if command && !k.modifiers.alt && k.key.eq_ignore_ascii_case("v") {
            // Clipboard contents are sent literally; no command/newline is added.
            // API does not expose bracketed-paste mode; no speculative VT framing.
            if let Some(input) = cx.read_from_clipboard().and_then(|c| c.text()) {
                if input.len() <= 32 * 1024 {
                    self.act(key, Action::Write(input), cx);
                } else if let Some(p) = self.panes.get_mut(&key) {
                    p.notice = "Paste exceeds 32 KiB; nothing sent".into();
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
            self.act(key, Action::Write(input), cx);
            cx.stop_propagation();
        }
    }
    fn copy(&mut self, key: PaneId, cx: &mut Context<Self>) {
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
                        this.create(Some((key, axis)), window, cx)
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
                    .on_click(cx.listener(move |this, _, _, cx| this.act(key, Action::Close, cx))),
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
            .on_key_down(cx.listener(move |this, event, _, cx| this.key(key, event, cx)))
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
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .size_full(),
                    )
                    .child(body),
            )
            .child(footer)
            .child(div().text_sm().child(pane.notice.clone()))
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
impl Render for TerminalWorkspace {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
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
                .on_click(cx.listener(|this, _, window, cx| this.create(None, window, cx))),
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

fn key_input(event: &KeyDownEvent) -> Option<String> {
    let key = &event.keystroke;
    if event.prefer_character_input {
        return key.key_char.clone();
    }
    if key.modifiers.platform {
        return None;
    }
    if key.modifiers.control && key.key.len() == 1 {
        let byte = key.key.as_bytes()[0].to_ascii_uppercase();
        if (b'@'..=b'_').contains(&byte) {
            return Some(String::from((byte - 64) as char));
        }
        return None;
    }
    let modifier = 1
        + u8::from(key.modifiers.shift)
        + 2 * u8::from(key.modifiers.alt)
        + 4 * u8::from(key.modifiers.control);
    let input = match key.key.as_str() {
        "enter" => "\r".into(),
        "backspace" => "\x7f".into(),
        "tab" if key.modifiers.shift => "\x1b[Z".into(),
        "tab" => "\t".into(),
        "escape" => "\x1b".into(),
        "up" | "down" | "right" | "left" | "home" | "end" => {
            let suffix = match key.key.as_str() {
                "up" => 'A',
                "down" => 'B',
                "right" => 'C',
                "left" => 'D',
                "home" => 'H',
                _ => 'F',
            };
            if modifier == 1 {
                format!("\x1b[{suffix}")
            } else {
                format!("\x1b[1;{modifier}{suffix}")
            }
        }
        "pageup" | "pagedown" | "delete" | "insert" => {
            let code = match key.key.as_str() {
                "pageup" => 5,
                "pagedown" => 6,
                "delete" => 3,
                _ => 2,
            };
            if modifier == 1 {
                format!("\x1b[{code}~")
            } else {
                format!("\x1b[{code};{modifier}~")
            }
        }
        _ => {
            let value = key.key_char.clone()?;
            if key.modifiers.alt {
                format!("\x1b{value}")
            } else {
                value
            }
        }
    };
    Some(input)
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
    fn navigation_keeps_alternate_screen_modifiers_and_ctrl_c_interrupt() {
        let control_shift = Modifiers {
            control: true,
            shift: true,
            ..Default::default()
        };
        assert_eq!(
            key_input(&event("pageup", control_shift, None)),
            Some("\x1b[5;6~".into())
        );
        assert_eq!(
            key_input(&event(
                "left",
                Modifiers {
                    shift: true,
                    ..Default::default()
                },
                None
            )),
            Some("\x1b[1;2D".into())
        );
        assert_eq!(
            key_input(&event(
                "c",
                Modifiers {
                    control: true,
                    ..Default::default()
                },
                None
            )),
            Some("\x03".into())
        );
        assert_eq!(
            key_input(&event("enter", Default::default(), None)),
            Some("\r".into())
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
    fn unicode_and_altgr_characters_are_not_reinterpreted_as_commands() {
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
        assert_eq!(key_input(&altgr), Some("@".into()));
        assert_eq!(
            key_input(&event("e", Default::default(), Some("e\u{301}"))),
            Some("e\u{301}".into())
        );
        assert_eq!(
            key_input(&event(
                "x",
                Modifiers {
                    alt: true,
                    ..Default::default()
                },
                Some("x")
            )),
            Some("\x1bx".into())
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
                    move |method, params| {
                        calls
                            .lock()
                            .unwrap()
                            .push((method.to_owned(), params.clone()));
                        if method == "terminal.write" && params["text"] == "fixture-rejected-input"
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
    fn worker_create_is_explicit_and_writes_remain_independently_bound() {
        let w = FakeWorker::new();
        assert_eq!(w.log.lock().unwrap().len(), 1);
        w.tx.send(Command::Create(10)).unwrap();
        w.tx.send(Command::Create(20)).unwrap();
        assert!(matches!(w.next(),Update::Bound(10,Ok(id)) if id=="created-1"));
        assert!(matches!(w.next(),Update::Bound(20,Ok(id)) if id=="created-2"));
        w.tx.send(Command::Act(10, 1, Action::Write("literal\n".into())))
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
                "terminal.write".into(),
                json!({"terminalId":"created-1","text":"literal\n"})
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
    fn late_write_failure_survives_newer_input_and_frame_tickets_without_retry() {
        let w = FakeWorker::new();
        w.tx.send(Command::Adopt(1, "one".into())).unwrap();
        w.tx.send(Command::Act(
            1,
            1,
            Action::Write("fixture-rejected-input".into()),
        ))
        .unwrap();
        w.tx.send(Command::Act(1, 2, Action::Write("next input".into())))
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
            .filter(|(method, _)| method == "terminal.write")
            .map(|(_, params)| params["text"].clone())
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
            worker(shared, "fixture-thread".into(), rx, tx);
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
        w.tx.send(Command::Act(1, 1, Action::Write("x".into())))
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
}
