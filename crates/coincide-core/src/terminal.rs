//! Real PTY process with Alacritty's terminal state, shared by API and renderer.
use alacritty_terminal::{
    event::{Event, EventListener},
    grid::{Dimensions, Scroll},
    index::{Column, Line},
    term::{Config, Term, TermMode, cell::Flags, color::Colors},
    vte::ansi::{Color, CursorShape, Processor},
};
use anyhow::{Result, ensure};
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    path::Path,
    sync::mpsc::{self, Receiver, Sender},
    thread,
};
struct Size {
    rows: u16,
    cols: u16,
}
impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.rows as usize
    }
    fn screen_lines(&self) -> usize {
        self.rows as usize
    }
    fn columns(&self) -> usize {
        self.cols as usize
    }
}
struct Listener(Sender<Event>);
impl EventListener for Listener {
    fn send_event(&self, event: Event) {
        let _ = self.0.send(event);
    }
}
pub struct Terminal {
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
    writer: mpsc::SyncSender<Vec<u8>>,
    output: Receiver<Vec<u8>>,
    events: Receiver<Event>,
    term: Term<Listener>,
    processor: Processor,
    pub revision: u64,
    pub title: String,
}
impl Terminal {
    pub fn spawn(cwd: &Path, shell: &str, rows: u16, cols: u16) -> Result<Self> {
        ensure!(cwd.is_dir(), "Terminal working directory does not exist");
        check_size(rows, cols)?;
        let pty = native_pty_system().openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        let mut command = CommandBuilder::new(shell);
        // A terminal opened by the candidate must never address its parent
        // Swift conversation through inherited agent-control bindings.
        for (name, _) in std::env::vars_os() {
            if name.to_str().is_some_and(|name| {
                name.starts_with("COINCIDE_") && name != "COINCIDE_RUST_DATA_DIR"
            }) {
                command.env_remove(name);
            }
        }
        for name in [
            "CODEX_SESSION_ID",
            "CODEX_THREAD_ID",
            "CODEX_TOOL_CALL_ID",
            "CLAUDECODE",
            "CLAUDE_CODE_SESSION_ID",
        ] {
            command.env_remove(name);
        }
        command.env(
            "COINCIDE_CONTROL_SOCKET",
            std::env::temp_dir().join(format!("coincide-unbound-{}.sock", uuid::Uuid::new_v4())),
        );
        command.cwd(cwd);
        command.env("TERM", "xterm-256color");
        let child = pty.slave.spawn_command(command)?;
        drop(pty.slave);
        let mut pty_writer = pty.master.take_writer()?;
        let (writer, input) = mpsc::sync_channel::<Vec<u8>>(32);
        thread::spawn(move || {
            while let Ok(bytes) = input.recv() {
                if pty_writer
                    .write_all(&bytes)
                    .and_then(|_| pty_writer.flush())
                    .is_err()
                {
                    break;
                }
            }
        });
        let mut reader = pty.master.try_clone_reader()?;
        let (tx, output) = mpsc::sync_channel(64);
        thread::spawn(move || {
            let mut buffer = [0u8; 8192];
            while let Ok(n) = reader.read(&mut buffer) {
                if n == 0 || tx.send(buffer[..n].to_vec()).is_err() {
                    break;
                }
            }
        });
        let (sender, events) = mpsc::channel();
        Ok(Self {
            master: pty.master,
            child,
            writer,
            output,
            events,
            term: Term::new(Config::default(), &Size { rows, cols }, Listener(sender)),
            processor: Processor::new(),
            revision: 0,
            title: "Terminal".into(),
        })
    }
    pub fn poll(&mut self) -> Result<bool> {
        let mut changed = false;
        for bytes in self.output.try_iter().take(64) {
            self.processor.advance(&mut self.term, &bytes);
            changed = true;
        }
        for event in self.events.try_iter() {
            match event {
                Event::PtyWrite(text) => self.writer.try_send(text.into_bytes())?,
                Event::Title(title) => self.title = title,
                _ => {}
            }
        }
        if changed {
            self.revision += 1;
        }
        Ok(changed)
    }
    pub fn write(&mut self, text: &str) -> Result<()> {
        ensure!(text.len() <= 32 * 1024, "Terminal input exceeds 32 KiB");
        self.writer.try_send(text.as_bytes().to_vec())?;
        Ok(())
    }
    pub fn resize(&mut self, rows: u16, cols: u16) -> Result<()> {
        check_size(rows, cols)?;
        self.master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        self.term.resize(Size { rows, cols });
        self.revision += 1;
        Ok(())
    }
    /// Move the viewport without sending escape sequences or keys to the PTY.
    /// Positive lines move toward older history. Requests clamp at both ends;
    /// the alternate screen has no scrollback and never scrolls the main grid.
    /// A changed viewport invalidates existing selection and paged frame revisions.
    pub fn scroll(&mut self, request: TerminalScroll) -> Result<bool> {
        self.poll()?;
        self.scroll_current(request)
    }

    /// Apply a viewport operation only to the frame the caller observed. Poll
    /// before checking so newly arrived output also invalidates stale requests.
    pub fn scroll_checked(&mut self, revision: u64, request: TerminalScroll) -> Result<bool> {
        self.poll()?;
        ensure!(
            revision == self.revision,
            "Terminal revision changed; read a fresh frame"
        );
        self.scroll_current(request)
    }

    fn scroll_current(&mut self, request: TerminalScroll) -> Result<bool> {
        let before = self.term.grid().display_offset();
        let scroll = match request {
            // Alacritty adds an i32 offset to this value; clamp first to prevent
            // overflow from untrusted API values, including i32::MAX.
            TerminalScroll::Lines(lines) => {
                let bound = self.term.grid().history_size().min(i32::MAX as usize / 2) as i32;
                Scroll::Delta(lines.clamp(-bound, bound))
            }
            TerminalScroll::PageUp => Scroll::PageUp,
            TerminalScroll::PageDown => Scroll::PageDown,
            TerminalScroll::Top => Scroll::Top,
            TerminalScroll::Bottom => Scroll::Bottom,
        };
        self.term.scroll_display(scroll);
        let changed = before != self.term.grid().display_offset();
        if changed {
            self.revision += 1;
        }
        Ok(changed)
    }

    /// Metadata shared by plain and styled reads. `rowOffset` remains a page
    /// within this viewport; `displayOffset` is the number of rows above live.
    fn viewport(&self) -> Value {
        json!({
            "displayOffset": self.term.grid().display_offset(),
            "historySize": self.term.grid().history_size(),
            "atBottom": self.term.grid().display_offset() == 0,
            "alternateScreen": self.term.mode().contains(TermMode::ALT_SCREEN),
        })
    }

    pub fn snapshot(&mut self) -> Result<Value> {
        self.poll()?;
        let mut lines = vec![String::new(); self.term.screen_lines()];
        for cell in self.term.grid().display_iter() {
            let row = (cell.point.line.0 + self.term.grid().display_offset() as i32) as usize;
            if row < lines.len() {
                lines[row].push(cell.c);
            }
        }
        for line in &mut lines {
            *line = line.trim_end().to_owned();
        }
        let exited = self.child.try_wait()?.map(|s| s.exit_code());
        Ok(
            json!({"title":self.title.chars().take(MAX_TITLE_CHARS).collect::<String>(),"lines":lines,"rows":self.term.screen_lines(),"cols":self.term.columns(),"revision":self.revision,"exitCode":exited,"viewport":self.viewport()}),
        )
    }
    /// At most ten styled viewport rows per response. Cursor coordinates remain
    /// absolute viewport coordinates; grid/lines indices start at rowOffset.
    pub fn styled_snapshot(&mut self, row_offset: usize, row_limit: usize) -> Result<Value> {
        ensure!(
            (1..=MAX_STYLED_ROWS).contains(&row_limit),
            "Styled row limit must be 1–10"
        );
        self.poll()?;
        let rows = self.term.screen_lines();
        let cols = self.term.columns();
        ensure!(row_offset <= rows, "Styled row offset exceeds viewport");
        let row_count = row_limit.min(rows - row_offset);
        let mut lines = vec![String::new(); row_count];
        let mut grid = vec![Vec::with_capacity(cols); row_count];
        let content = self.term.renderable_content();
        let mut truncated = self.title.chars().count() > MAX_TITLE_CHARS;
        for row in row_offset..row_offset + row_count {
            let line = Line(row as i32 - content.display_offset as i32);
            for col in 0..cols {
                let cell = &self.term.grid()[line][Column(col)];
                let page_row = row - row_offset;
                // Preserve the existing plain-text projection, including spacer cells.
                lines[page_row].push(cell.c);
                let flags = cell.flags;
                let continuation =
                    flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER);
                let mut text = if continuation {
                    String::new()
                } else {
                    cell.c.to_string()
                };
                if !continuation && let Some(marks) = cell.zerowidth() {
                    text.extend(marks.iter().take(MAX_COMBINING_CHARS).copied());
                    truncated |= marks.len() > MAX_COMBINING_CHARS;
                }
                let mut foreground = resolve_color(cell.fg, content.colors);
                let mut background = resolve_color(cell.bg, content.colors);
                if flags.contains(Flags::DIM) {
                    foreground = foreground.map(|channel| (u16::from(channel) * 2 / 3) as u8);
                }
                if flags.contains(Flags::INVERSE) {
                    std::mem::swap(&mut foreground, &mut background);
                }
                if flags.contains(Flags::HIDDEN) {
                    foreground = background;
                }
                grid[page_row].push(json!({
                "text": text,
                "width": if continuation { 0 } else if flags.contains(Flags::WIDE_CHAR) { 2 } else { 1 },
                "continuation": continuation,
                "wrapline": flags.contains(Flags::WRAPLINE),
                "foreground": foreground, "background": background,
                "bold": flags.contains(Flags::BOLD),
                "italic": flags.contains(Flags::ITALIC),
                "underline": flags.intersects(Flags::ALL_UNDERLINES),
                "inverse": flags.contains(Flags::INVERSE),
                "dim": flags.contains(Flags::DIM),
                "hidden": flags.contains(Flags::HIDDEN),
                "strikethrough": flags.contains(Flags::STRIKEOUT),
            }));
            }
        }
        for line in &mut lines {
            *line = line.trim_end().to_owned();
        }
        let cursor_row = content.cursor.point.line.0 + content.display_offset as i32;
        let cursor_col = content.cursor.point.column.0;
        let shape = match content.cursor.shape {
            CursorShape::Block => "block",
            CursorShape::Underline => "underline",
            CursorShape::Beam => "beam",
            CursorShape::HollowBlock => "hollowBlock",
            CursorShape::Hidden => "hidden",
        };
        let cursor = json!({
            "row": cursor_row, "col": cursor_col,
            "insertionCol": cursor_col+usize::from(self.term.grid().cursor.input_needs_wrap),
            "visible": shape != "hidden" && (0..rows as i32).contains(&cursor_row) && cursor_col < cols,
            "shape": shape, "blinking": self.term.cursor_style().blinking,
        });
        let exited = self.child.try_wait()?.map(|s| s.exit_code());
        Ok(json!({
            "title": self.title.chars().take(MAX_TITLE_CHARS).collect::<String>(),
            "lines": lines, "rows": rows, "cols": cols,
            "revision": self.revision, "exitCode": exited,
            "grid": grid, "cursor": cursor, "truncated": truncated,
            "rowOffset": row_offset, "rowCount": row_count,
            "viewport": self.viewport(),
            "nextRowOffset": (row_offset + row_count < rows).then_some(row_offset + row_count),
        }))
    }

    /// Copy from a known viewport revision, including visible scrollback.
    /// Output, resize and scroll changes invalidate the selected coordinates.
    pub fn copy_selection(
        &mut self,
        revision: u64,
        start: TerminalPoint,
        end: TerminalPoint,
    ) -> Result<String> {
        self.poll()?;
        ensure!(
            revision == self.revision,
            "Terminal output changed; select the text again"
        );
        let rows = self.term.screen_lines();
        let cols = self.term.columns();
        let offset = self.term.grid().display_offset();
        copy_cells(0, rows, cols, start, end, |row, col| {
            let cell = &self.term.grid()[Line(row as i32 - offset as i32)][Column(col)];
            let flags = cell.flags;
            let continuation =
                flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER);
            let mut text = if continuation {
                String::new()
            } else {
                cell.c.to_string()
            };
            if !continuation && let Some(marks) = cell.zerowidth() {
                text.extend(marks.iter().take(MAX_COMBINING_CHARS).copied());
            }
            Ok(CopyCell {
                text,
                width: if continuation {
                    0
                } else if flags.contains(Flags::WIDE_CHAR) {
                    2
                } else {
                    1
                },
                continuation,
                hidden: flags.contains(Flags::HIDDEN),
                wrapline: flags.contains(Flags::WRAPLINE),
            })
        })
    }
}

/// Serializable integration hook for wheel/page/history controls. Scroll events
/// must be routed here rather than written to the shell. Typing may explicitly
/// request Bottom first; raw `write` intentionally preserves the viewing position.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    content = "lines",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum TerminalScroll {
    Lines(i32),
    PageUp,
    PageDown,
    Top,
    Bottom,
}

/// Inclusive, zero-based viewport cell coordinates (not UTF-8 byte offsets).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct TerminalPoint {
    pub row: usize,
    pub col: usize,
}

#[derive(Clone, Copy, Debug)]
pub enum SelectionMovement {
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
}

/// Keyboard selection uses insertion boundaries, unlike inclusive mouse cells.
/// Moving once from the cursor therefore selects exactly one cell.
pub fn move_selection_boundary(
    position: usize,
    movement: SelectionMovement,
    rows: usize,
    cols: usize,
) -> Result<usize> {
    ensure!(
        (1..=300).contains(&rows) && (1..=500).contains(&cols),
        "Invalid terminal selection dimensions"
    );
    let total = rows * cols;
    ensure!(
        position <= total,
        "Keyboard boundary is outside the displayed page"
    );
    Ok(match movement {
        SelectionMovement::Left => position.saturating_sub(1),
        SelectionMovement::Right => (position + 1).min(total),
        SelectionMovement::Up => position.saturating_sub(cols),
        SelectionMovement::Down => (position + cols).min(total),
        SelectionMovement::Home => (position / cols).min(rows - 1) * cols,
        SelectionMovement::End => ((position / cols + 1) * cols).min(total),
    })
}

pub fn selection_from_boundaries(
    anchor: usize,
    caret: usize,
    offset: usize,
    rows: usize,
    cols: usize,
) -> Result<Option<(TerminalPoint, TerminalPoint)>> {
    ensure!(
        (1..=300).contains(&rows) && (1..=500).contains(&cols) && offset <= 300 - rows,
        "Invalid terminal selection dimensions"
    );
    let total = rows * cols;
    ensure!(
        anchor <= total && caret <= total,
        "Keyboard boundary is outside the displayed page"
    );
    if anchor == caret {
        return Ok(None);
    }
    let start = anchor.min(caret);
    let end = anchor.max(caret) - 1;
    Ok(Some((
        TerminalPoint {
            row: offset + start / cols,
            col: start % cols,
        },
        TerminalPoint {
            row: offset + end / cols,
            col: end % cols,
        },
    )))
}

/// Extract the selection from a coherent styled frame already displayed by the
/// UI. A page cannot select coordinates outside its rowOffset/grid bounds.
pub fn selected_text(frame: &Value, start: TerminalPoint, end: TerminalPoint) -> Result<String> {
    let rows = frame["rows"]
        .as_u64()
        .and_then(|v| usize::try_from(v).ok())
        .ok_or_else(|| anyhow::anyhow!("Terminal frame has no rows"))?;
    let cols = frame["cols"]
        .as_u64()
        .and_then(|v| usize::try_from(v).ok())
        .ok_or_else(|| anyhow::anyhow!("Terminal frame has no columns"))?;
    let offset = frame["rowOffset"]
        .as_u64()
        .and_then(|v| usize::try_from(v).ok())
        .ok_or_else(|| anyhow::anyhow!("Terminal frame has no row offset"))?;
    let grid = frame["grid"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("Terminal frame has no grid"))?;
    ensure!(
        rows <= 300 && offset <= rows && grid.len() <= rows - offset,
        "Terminal frame has invalid row bounds"
    );
    ensure!(
        (1..=500).contains(&cols)
            && grid
                .iter()
                .all(|row| row.as_array().is_some_and(|cells| cells.len() == cols)),
        "Terminal frame has invalid columns"
    );
    copy_cells(offset, grid.len(), cols, start, end, |row, col| {
        let cell = &grid[row - offset][col];
        let text = cell["text"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Terminal cell has no text"))?;
        ensure!(
            text.chars().count() <= MAX_COMBINING_CHARS + 1,
            "Terminal cell text exceeds the display limit"
        );
        let width = cell["width"]
            .as_u64()
            .filter(|value| *value <= 2)
            .ok_or_else(|| anyhow::anyhow!("Terminal cell has invalid width"))?
            as usize;
        Ok(CopyCell {
            text: text.into(),
            width,
            continuation: cell["continuation"] == true,
            hidden: cell["hidden"] == true,
            wrapline: cell["wrapline"] == true,
        })
    })
}

struct CopyCell {
    text: String,
    width: usize,
    continuation: bool,
    hidden: bool,
    wrapline: bool,
}
fn copy_cells(
    offset: usize,
    rows: usize,
    cols: usize,
    start: TerminalPoint,
    end: TerminalPoint,
    mut read: impl FnMut(usize, usize) -> Result<CopyCell>,
) -> Result<String> {
    ensure!(
        (1..=300).contains(&rows) && (1..=500).contains(&cols),
        "Invalid terminal selection dimensions"
    );
    let (mut start, end) = if start <= end {
        (start, end)
    } else {
        (end, start)
    };
    ensure!(
        start.row >= offset && end.row < offset + rows && start.col < cols && end.col < cols,
        "Selection is outside the displayed terminal page"
    );
    // Selecting the trailing half of a wide glyph copies that glyph once.
    if start.col > 0
        && read(start.row, start.col)?.continuation
        && read(start.row, start.col - 1)?.width == 2
    {
        start.col -= 1;
    }
    let mut result = String::new();
    for row in start.row..=end.row {
        let first = if row == start.row { start.col } else { 0 };
        let last = if row == end.row { end.col } else { cols - 1 };
        let mut line = String::new();
        for col in first..=last {
            let cell = read(row, col)?;
            if cell.continuation {
                continue;
            }
            if cell.hidden {
                line.extend(std::iter::repeat_n(' ', cell.width));
            } else {
                ensure!(
                    !cell.text.chars().any(char::is_control),
                    "Terminal copy contains non-display control characters"
                );
                line.push_str(&cell.text);
            }
        }
        let wrapped = last == cols - 1 && read(row, last)?.wrapline;
        if last == cols - 1 && !wrapped {
            line.truncate(line.trim_end_matches(' ').len());
        }
        result.push_str(&line);
        if row < end.row && !wrapped {
            result.push('\n');
        }
        ensure!(
            result.len() <= 1024 * 1024,
            "Terminal selection exceeds 1 MiB"
        );
    }
    Ok(result)
}
// Styled wire contract: grid[page_row][col] includes blank cells; coordinates
// are zero-based and page_row starts at rowOffset. RGB arrays are final display
// colors (dim/inverse/conceal already applied); clients must not transform again.
// Bold is font weight; underline variants collapse to a boolean. Defaults are
// fixed dark colors; OSC palette overrides apply. Each page contains at most
// 10 * 500 cells, each with 1 base + 16 combining scalars and fixed-size style
// metadata, safely below the control transport's 4 MiB frame. Title is bounded
// to 1024 scalars. `truncated` reports text/title clipping, not ordinary paging.
// Plain snapshot() never allocates a styled grid or resolves cell colors.
const MAX_STYLED_ROWS: usize = 10;
const MAX_COMBINING_CHARS: usize = 16;
const MAX_TITLE_CHARS: usize = 1024;

fn resolve_color(color: Color, colors: &Colors) -> [u8; 3] {
    let index = match color {
        Color::Spec(rgb) => return [rgb.r, rgb.g, rgb.b],
        Color::Indexed(index) => usize::from(index),
        Color::Named(name) => name as usize,
    };
    if let Some(rgb) = colors[index] {
        return [rgb.r, rgb.g, rgb.b];
    }
    // Coincide's legacy macOS dark ANSI palette.
    const ANSI: [u32; 16] = [
        0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5, 0x666666,
        0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5,
    ];
    let packed = match index {
        0..=15 => ANSI[index],
        16..=231 => {
            let cube = index - 16;
            let levels = [0u32, 95, 135, 175, 215, 255];
            (levels[cube / 36] << 16) | (levels[cube / 6 % 6] << 8) | levels[cube % 6]
        }
        232..=255 => {
            let gray = 8 + (index as u32 - 232) * 10;
            gray * 0x010101
        }
        257 => 0x0C0C0C,
        258 => 0xB4CBFF,
        259..=266 => {
            let rgb = ANSI[index - 259];
            return [
                ((rgb >> 16) & 255) as u8,
                ((rgb >> 8) & 255) as u8,
                (rgb & 255) as u8,
            ]
            .map(|channel| (u16::from(channel) * 2 / 3) as u8);
        }
        268 => 0x8D8D8D,
        _ => 0xD4D4D4,
    };
    [(packed >> 16) as u8, (packed >> 8) as u8, packed as u8]
}

impl Drop for Terminal {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
fn check_size(rows: u16, cols: u16) -> Result<()> {
    ensure!(
        (2..=300).contains(&rows) && (2..=500).contains(&cols),
        "Terminal size must be 2–300 rows and 2–500 columns"
    );
    Ok(())
}
#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};
    #[test]
    fn real_pty_output_and_resize() {
        let dir = tempfile::tempdir().unwrap();
        let mut terminal = Terminal::spawn(dir.path(), "/bin/sh", 24, 80).unwrap();
        terminal
            .write("printf '\\033[2J\\033[HRUST_PTY_%s\\n' VERIFIED\r")
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let v = terminal.snapshot().unwrap();
            if v["lines"]
                .as_array()
                .unwrap()
                .iter()
                .any(|l| l.as_str().unwrap_or("").contains("RUST_PTY_VERIFIED"))
            {
                break;
            }
            assert!(Instant::now() < deadline, "PTY output did not arrive");
            thread::sleep(Duration::from_millis(20));
        }
        terminal.resize(30, 100).unwrap();
        let v = terminal.snapshot().unwrap();
        assert_eq!(v["rows"], 30);
        assert_eq!(v["cols"], 100);
        assert!(terminal.resize(0, 0).is_err());
    }
}
