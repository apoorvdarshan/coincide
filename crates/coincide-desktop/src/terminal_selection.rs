//! Visible-grid selection only. The parent renderer retains ANSI/cursor styling
//! and PTY routing; these helpers never send input to a terminal process.
use anyhow::{Result, ensure};
use coincide_core::terminal::{
    SelectionMovement, TerminalPoint, move_selection_boundary, selected_text,
    selection_from_boundaries,
};
use gpui_kit::{App, ClipboardItem, KeyDownEvent};
use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Eq)]
struct FrameKey {
    terminal: String,
    revision: u64,
    offset: usize,
    count: usize,
    cols: usize,
}

#[derive(Default)]
pub struct TerminalSelection {
    frame: Option<FrameKey>,
    anchor: Option<TerminalPoint>,
    caret: Option<TerminalPoint>,
    dragging: bool,
    keyboard: Option<(usize, usize)>,
}

impl TerminalSelection {
    pub fn clear(&mut self) {
        self.frame = None;
        self.anchor = None;
        self.caret = None;
        self.dragging = false;
        self.keyboard = None;
    }

    /// Call after frame changes; output, paging, resize, and switching terminals
    /// invalidate selection instead of copying different text at old coordinates.
    pub fn sync(&mut self, terminal: &str, frame: &Value) -> bool {
        let next = frame_key(terminal, frame);
        if next == self.frame {
            return false;
        }
        let had_selection = self.anchor.is_some();
        self.clear();
        self.frame = next;
        had_selection
    }

    pub fn begin(&mut self, terminal: &str, frame: &Value, row: usize, col: usize, extend: bool) {
        self.sync(terminal, frame);
        self.keyboard = None;
        let Some(point) = self.clamped(row, col) else {
            return;
        };
        if !extend || self.anchor.is_none() {
            self.anchor = Some(point);
        }
        self.caret = Some(point);
        self.dragging = true;
    }

    pub fn drag(&mut self, terminal: &str, frame: &Value, row: usize, col: usize) -> bool {
        if !self.matches(terminal, frame) || !self.dragging {
            return false;
        }
        let next = self.clamped(row, col);
        let changed = next != self.caret;
        self.caret = next;
        changed
    }

    pub fn end_drag(&mut self) {
        self.dragging = false;
    }

    pub fn has_selection(&self, terminal: &str, frame: &Value) -> bool {
        self.matches(terminal, frame) && self.anchor.is_some() && self.caret.is_some()
    }

    pub fn is_selected(
        &self,
        terminal: &str,
        frame: &Value,
        row: usize,
        col: usize,
        width: usize,
    ) -> bool {
        if !self.matches(terminal, frame) {
            return false;
        }
        let Some((start, end)) = self.range() else {
            return false;
        };
        let first = TerminalPoint { row, col };
        let last = TerminalPoint {
            row,
            col: col.saturating_add(width.clamp(1, 2) - 1),
        };
        first <= end && last >= start
    }

    pub fn copy(&self, terminal: &str, frame: &Value, cx: &mut App) -> Result<usize> {
        ensure!(
            self.matches(terminal, frame),
            "Terminal output changed; select the text again"
        );
        let (start, end) = self
            .range()
            .ok_or_else(|| anyhow::anyhow!("Select terminal text first"))?;
        let text = selected_text(frame, start, end)?;
        let len = text.len();
        cx.write_to_clipboard(ClipboardItem::new_string(text));
        Ok(len)
    }

    /// Return true when consumed. Parent must stop propagation on both true and
    /// errors, so a copy shortcut never accidentally becomes a PTY interrupt.
    /// Plain Ctrl+C is intentionally untouched.
    pub fn key(
        &mut self,
        terminal: &str,
        frame: &Value,
        event: &KeyDownEvent,
        cx: &mut App,
    ) -> Result<bool> {
        self.sync(terminal, frame);
        let key = &event.keystroke;
        let command = key.modifiers.platform || (key.modifiers.control && key.modifiers.shift);
        if command && !key.modifiers.alt && key.key.eq_ignore_ascii_case("c") {
            self.copy(terminal, frame, cx)?;
            return Ok(true);
        }
        if command && !key.modifiers.alt && key.key.eq_ignore_ascii_case("a") {
            if let Some(frame) = &self.frame {
                self.anchor = Some(TerminalPoint {
                    row: frame.offset,
                    col: 0,
                });
                self.caret = Some(TerminalPoint {
                    row: frame.offset + frame.count - 1,
                    col: frame.cols - 1,
                });
                self.dragging = false;
                self.keyboard = Some((0, frame.count * frame.cols));
            }
            return Ok(true);
        }
        if key.key == "escape" && self.anchor.is_some() {
            self.anchor = None;
            self.caret = None;
            self.dragging = false;
            self.keyboard = None;
            return Ok(true);
        }
        if key.modifiers.shift
            && !key.modifiers.control
            && !key.modifiers.platform
            && !key.modifiers.alt
            && matches!(
                key.key.as_str(),
                "left" | "right" | "up" | "down" | "home" | "end"
            )
        {
            let Some(bounds) = &self.frame else {
                return Ok(false);
            };
            let mut initial = self
                .clamped(
                    frame["cursor"]["row"]
                        .as_u64()
                        .unwrap_or(bounds.offset as u64) as usize,
                    frame["cursor"]["col"].as_u64().unwrap_or(0) as usize,
                )
                .expect("validated bounds");
            // At a full right edge Alacritty draws the cursor on the last cell
            // while its insertion boundary is after that cell (pending wrap).
            initial.col = frame["cursor"]["insertionCol"]
                .as_u64()
                .or_else(|| frame["cursor"]["col"].as_u64())
                .unwrap_or(0)
                .min(bounds.cols as u64) as usize;
            let linear =
                |point: TerminalPoint| (point.row - bounds.offset) * bounds.cols + point.col;
            let (anchor, caret) =
                self.keyboard
                    .unwrap_or_else(|| match (self.anchor, self.caret) {
                        (Some(anchor), Some(caret)) if anchor <= caret => {
                            (linear(anchor), linear(caret) + 1)
                        }
                        (Some(anchor), Some(caret)) => (linear(anchor) + 1, linear(caret)),
                        _ => (linear(initial), linear(initial)),
                    });
            let movement = match key.key.as_str() {
                "left" => SelectionMovement::Left,
                "right" => SelectionMovement::Right,
                "up" => SelectionMovement::Up,
                "down" => SelectionMovement::Down,
                "home" => SelectionMovement::Home,
                _ => SelectionMovement::End,
            };
            let caret = move_selection_boundary(caret, movement, bounds.count, bounds.cols)?;
            self.keyboard = Some((anchor, caret));
            let range =
                selection_from_boundaries(anchor, caret, bounds.offset, bounds.count, bounds.cols)?;
            self.anchor = range.map(|(start, _)| start);
            self.caret = range.map(|(_, end)| end);
            self.dragging = false;
            return Ok(true);
        }
        Ok(false)
    }

    fn range(&self) -> Option<(TerminalPoint, TerminalPoint)> {
        let anchor = self.anchor?;
        let caret = self.caret?;
        Some(if anchor <= caret {
            (anchor, caret)
        } else {
            (caret, anchor)
        })
    }
    fn matches(&self, terminal: &str, frame: &Value) -> bool {
        self.frame.as_ref().is_some_and(|key| {
            key.terminal == terminal
                && frame["revision"].as_u64() == Some(key.revision)
                && frame["rowOffset"].as_u64() == Some(key.offset as u64)
                && frame["cols"].as_u64() == Some(key.cols as u64)
                && frame["grid"]
                    .as_array()
                    .is_some_and(|rows| rows.len() == key.count)
        })
    }
    fn clamped(&self, row: usize, col: usize) -> Option<TerminalPoint> {
        let frame = self.frame.as_ref()?;
        Some(TerminalPoint {
            row: row.clamp(frame.offset, frame.offset + frame.count - 1),
            col: col.min(frame.cols - 1),
        })
    }
}

fn frame_key(terminal: &str, frame: &Value) -> Option<FrameKey> {
    let revision = frame["revision"].as_u64()?;
    let offset = usize::try_from(frame["rowOffset"].as_u64()?).ok()?;
    let cols = usize::try_from(frame["cols"].as_u64()?).ok()?;
    let rows = usize::try_from(frame["rows"].as_u64()?).ok()?;
    let count = frame["grid"].as_array()?.len();
    if !(1..=500).contains(&cols)
        || !(1..=300).contains(&rows)
        || count == 0
        || offset > rows
        || count > rows - offset
    {
        return None;
    }
    Some(FrameKey {
        terminal: terminal.into(),
        revision,
        offset,
        count,
        cols,
    })
}
