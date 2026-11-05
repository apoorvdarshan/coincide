//! Real PTY process with Alacritty's terminal state, shared by API and renderer.
use alacritty_terminal::{
    event::{Event, EventListener},
    grid::Dimensions,
    index::{Column, Line},
    term::{Config, Term, cell::Flags, color::Colors},
    vte::ansi::{Color, CursorShape, Processor},
};
use anyhow::{Result, ensure};
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};
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
            json!({"title":self.title.chars().take(MAX_TITLE_CHARS).collect::<String>(),"lines":lines,"rows":self.term.screen_lines(),"cols":self.term.columns(),"revision":self.revision,"exitCode":exited}),
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
            "nextRowOffset": (row_offset + row_count < rows).then_some(row_offset + row_count),
        }))
    }
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
