//! Real PTY process with Alacritty's terminal state, shared by API and renderer.
use alacritty_terminal::{
    event::{Event, EventListener},
    grid::{Dimensions, Scroll},
    index::{Column, Line},
    term::{Config, Term, TermMode, cell::Flags, color::Colors},
    vte::ansi::{Color, CursorShape, Processor},
};
use anyhow::{Context, Result, ensure};
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        mpsc::{self, Receiver, Sender},
    },
    thread,
    time::{Duration, Instant},
};
#[path = "terminal_launch.rs"]
pub mod launch;
#[path = "terminal_shell.rs"]
pub mod shell;

/// A shell that fails this soon keeps its pane to show why (Swift
/// TerminalSession.shellExited); later exits close their terminal.
const FAILED_START: Duration = Duration::from_secs(2);
/// How long a progress bar stays without another report (Swift
/// TerminalProgress.timeout), in case the program died mid-task.
pub const PROGRESS_TIMEOUT: Duration = Duration::from_secs(15);
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Exit {
    /// None when a signal ended the shell.
    code: Option<i32>,
    keep_open: bool,
}
impl Exit {
    fn message(self) -> String {
        match self.code {
            Some(code) => format!("Process exited with code {code}."),
            None => "Process terminated.".into(),
        }
    }
}

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
    master: Option<Box<dyn MasterPty + Send>>,
    child: Option<Box<dyn Child + Send + Sync>>,
    writer: Option<mpsc::SyncSender<Vec<u8>>>,
    output: Option<Receiver<Vec<u8>>>,
    events: Receiver<Event>,
    term: Term<Listener>,
    processor: Processor,
    shell: shell::ShellObserver,
    shell_anchors: shell::Anchors,
    history_limit: usize,
    _shell_launch: Option<shell::ShellLaunch>,
    reader_worker: Option<thread::JoinHandle<()>>,
    writer_worker: Option<thread::JoinHandle<()>>,
    pub revision: u64,
    pub title: String,
    /// "Terminal N", the lowest number free in its thread when it was created.
    pub number: u32,
    started: Instant,
    exit: Option<Exit>,
    /// The shell's last known folder, followed through the kernel.
    directory: PathBuf,
    progress_at: Option<Instant>,
    bells: u64,
}
impl Terminal {
    /// Test-only display engine: actual Alacritty parsing/filtering with no PTY, child or IO worker.
    #[cfg(test)]
    pub(crate) fn fixture_output(rows: u16, cols: u16, bytes: &[u8]) -> Self {
        let (output_tx, output) = mpsc::sync_channel(1);
        output_tx.send(bytes.to_vec()).unwrap();
        let (sender, events) = mpsc::channel();
        Self {
            master: None,
            child: None,
            writer: Some(mpsc::sync_channel(1).0),
            output: Some(output),
            events,
            term: Term::new(Config::default(), &Size { rows, cols }, Listener(sender)),
            processor: Processor::new(),
            shell: Default::default(),
            shell_anchors: Default::default(),
            history_limit: Config::default().scrolling_history,
            _shell_launch: None,
            reader_worker: None,
            writer_worker: None,
            revision: 0,
            title: "Terminal".into(),
            number: 0,
            started: Instant::now(),
            exit: None,
            directory: PathBuf::new(),
            progress_at: None,
            bells: 0,
        }
    }
    pub fn spawn(cwd: &Path, shell: &str, rows: u16, cols: u16) -> Result<Self> {
        Self::spawn_with_environment(cwd, shell, rows, cols, &[])
    }
    /// `environment` is set after inherited agent bindings are removed, as a
    /// project script's `COINCIDE_PROJECT_ROOT` and worktree path are.
    pub fn spawn_with_environment(
        cwd: &Path,
        shell: &str,
        rows: u16,
        cols: u16,
        environment: &[(String, String)],
    ) -> Result<Self> {
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
        for (name, value) in environment {
            ensure!(
                matches!(
                    name.as_str(),
                    "COINCIDE_PROJECT_ROOT"
                        | "COINCIDE_WORKTREE_PATH"
                        | "T3CODE_PROJECT_ROOT"
                        | "T3CODE_WORKTREE_PATH"
                ),
                "Terminal environment may name only project script locations"
            );
            command.env(name, value);
        }
        let shell_launch = shell::ShellLaunch::prepare(
            shell,
            command
                .get_env("ZDOTDIR")
                .map(std::ffi::OsStr::to_os_string),
        );
        command.args(&shell_launch.arguments);
        for (name, value) in &shell_launch.environment {
            command.env(name, value);
        }
        command.cwd(cwd);
        let inherited = command
            .iter_full_env_as_str()
            .map(|(name, _)| name.to_owned())
            .collect::<Vec<_>>();
        let environment =
            launch::environment(inherited.iter().map(std::ffi::OsStr::new), shell, cwd);
        for name in &environment.remove {
            command.env_remove(name);
        }
        for (name, value) in &environment.set {
            command.env(name, value);
        }
        let child = pty.slave.spawn_command(command)?;
        drop(pty.slave);
        let mut pty_writer = pty.master.take_writer()?;
        let (writer, input) = mpsc::sync_channel::<Vec<u8>>(32);
        let writer_worker = thread::spawn(move || {
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
        let reader_worker = thread::spawn(move || {
            let mut buffer = [0u8; 8192];
            while let Ok(n) = reader.read(&mut buffer) {
                if n == 0 || tx.send(buffer[..n].to_vec()).is_err() {
                    break;
                }
            }
        });
        let (sender, events) = mpsc::channel();
        Ok(Self {
            master: Some(pty.master),
            child: Some(child),
            writer: Some(writer),
            output: Some(output),
            reader_worker: Some(reader_worker),
            writer_worker: Some(writer_worker),
            events,
            term: Term::new(Config::default(), &Size { rows, cols }, Listener(sender)),
            processor: Processor::new(),
            shell: Default::default(),
            shell_anchors: Default::default(),
            history_limit: Config::default().scrolling_history,
            _shell_launch: Some(shell_launch),
            revision: 0,
            title: "Terminal".into(),
            number: 0,
            started: Instant::now(),
            exit: None,
            directory: cwd.to_path_buf(),
            progress_at: None,
            bells: 0,
        })
    }
    /// A shell in `start`, with the dimmed fallback notice above its first
    /// prompt when the preferred folder is gone.
    pub fn spawn_in(
        start: &launch::StartDirectory,
        shell: &str,
        rows: u16,
        cols: u16,
    ) -> Result<Self> {
        let mut terminal = Self::spawn(&start.path, shell, rows, cols)?;
        if let Some(notice) = start.notice() {
            terminal
                .processor
                .advance(&mut terminal.term, notice.as_bytes());
            terminal.revision += 1;
        }
        Ok(terminal)
    }
    /// Whether the shell has exited; its pane stays until closed or restarted.
    pub fn exited(&self) -> bool {
        self.exit.is_some()
    }
    /// The folder the shell is in, or was in when it exited.
    pub fn directory(&self) -> &Path {
        &self.directory
    }
    /// Swift TerminalSession.restart: a new shell in the same pane, below the
    /// old output, with the same number, size and title.
    pub fn restart(&mut self, cwd: &Path, shell: &str) -> Result<PendingTerminalShutdown> {
        ensure!(self.exit.is_some(), "Terminal is still running");
        let rows = self.term.screen_lines() as u16;
        let cols = self.term.columns() as u16;
        let mut fresh = Self::spawn(cwd, shell, rows, cols)?;
        // An exited shell may still have I/O workers unwinding. Transfer its
        // complete owner before replacement instead of detaching their handles.
        let retired = self.request_shutdown()?;
        // The screen and scrollback stay, with the events their listener sends.
        std::mem::swap(&mut fresh.term, &mut self.term);
        std::mem::swap(&mut fresh.events, &mut self.events);
        std::mem::swap(&mut fresh.processor, &mut self.processor);
        fresh.title = std::mem::take(&mut self.title);
        fresh.number = self.number;
        fresh.bells = self.bells;
        fresh.revision = self.revision + 1;
        fresh.processor.advance(&mut fresh.term, b"\r\n");
        // The caller retains the retired owner until actual I/O joins finish.
        *self = fresh;
        Ok(retired)
    }
    /// What the tab shows for this terminal (Swift TerminalSession.title,
    /// isBusy, directory, progress and state). Reads the kernel, not output.
    pub fn status(&mut self) -> Value {
        let shell = self.child.as_ref().and_then(|child| child.process_id());
        #[cfg(unix)]
        let foreground = if self.exit.is_none() {
            launch::foreground_command(
                shell,
                self.master
                    .as_ref()
                    .and_then(|master| master.process_group_leader()),
            )
        } else {
            None
        };
        #[cfg(not(unix))]
        let foreground: Option<String> = None;
        if self.exit.is_none()
            && let Some(directory) = shell.and_then(launch::process_directory)
        {
            self.directory = directory;
        }
        json!({
            "number": self.number,
            "name": foreground.clone().unwrap_or_else(|| format!("Terminal {}", self.number)),
            "busy": foreground.is_some(),
            "foreground": foreground,
            "directory": self.directory,
            "exited": self.exit.is_some(),
            "exitCode": self.exit.and_then(|exit| exit.code),
            "keepOpen": self.exit.is_some_and(|exit| exit.keep_open),
            "exitMessage": self.exit.map(Exit::message),
            "progress": self.shell.state.progress,
            "bells": self.bells,
        })
    }
    /// Trusted owner-only transfer. Repeated calls reject; retain the returned owner
    /// until its actual child/reader/writer joins have been accounted.
    pub fn request_shutdown(&mut self) -> Result<PendingTerminalShutdown> {
        let child = self
            .child
            .take()
            .context("Terminal shutdown already requested")?;
        // Disconnect both bounded queues before the join worker starts.
        drop(self.output.take());
        drop(self.writer.take());
        Ok(PendingTerminalShutdown::start(ShutdownResources {
            child,
            master: self.master.take(),
            shell_launch: self._shell_launch.take(),
            reader: self.reader_worker.take(),
            writer: self.writer_worker.take(),
        }))
    }
    pub fn poll(&mut self) -> Result<bool> {
        let mut changed = false;
        let mut drained = false;
        for _ in 0..64 {
            let Ok(bytes) = self
                .output
                .as_ref()
                .context("Terminal is stopping")?
                .try_recv()
            else {
                drained = true;
                break;
            };
            let mut offset = 0;
            for (end, mark) in self.shell.events(&bytes) {
                self.advance_screen(&bytes[offset..end]);
                offset = end;
                if matches!(mark, shell::Mark::Progress) {
                    self.progress_at = Some(Instant::now());
                }
                if self.term.mode().contains(TermMode::ALT_SCREEN) {
                    self.shell_anchors.invalidate();
                } else {
                    let position = self.shell_position();
                    self.shell_anchors.observe(mark, position);
                }
            }
            self.advance_screen(&bytes[offset..]);
            changed = true;
        }
        for event in self.events.try_iter() {
            match event {
                Event::PtyWrite(text) => self
                    .writer
                    .as_ref()
                    .context("Terminal is stopping")?
                    .try_send(text.into_bytes())?,
                Event::Title(title) => self.title = title,
                Event::Bell => self.bells = self.bells.wrapping_add(1),
                _ => {}
            }
        }
        if self.shell.state.progress.is_some()
            && self
                .progress_at
                .is_none_or(|at| at.elapsed() >= PROGRESS_TIMEOUT)
        {
            self.shell.state.progress = None;
            changed = true;
        }
        // Only after the shell's last output, so the notice follows it.
        if drained
            && self.exit.is_none()
            && let Some(exit) = self.observe_exit()
        {
            if exit.keep_open {
                let notice = format!("\r\n\x1b[2m[{}]\x1b[0m\r\n", exit.message());
                self.processor.advance(&mut self.term, notice.as_bytes());
            }
            self.exit = Some(exit);
            changed = true;
        }
        if changed {
            self.revision += 1;
        }
        Ok(changed)
    }
    fn observe_exit(&mut self) -> Option<Exit> {
        let status = self.child.as_mut()?.try_wait().ok()??;
        let code = status.signal().is_none().then(|| status.exit_code() as i32);
        Some(Exit {
            code,
            keep_open: code != Some(0) && self.started.elapsed() < FAILED_START,
        })
    }
    fn shell_position(&self) -> shell::Position {
        let grid = self.term.grid();
        shell::Position {
            row: grid.history_size() + grid.cursor.point.line.0.max(0) as usize,
            col: grid.cursor.point.column.0 + usize::from(grid.cursor.input_needs_wrap),
        }
    }
    fn advance_screen(&mut self, bytes: &[u8]) {
        let history = self.term.grid().history_size();
        self.processor.advance(&mut self.term, bytes);
        let now = self.term.grid().history_size();
        // Once history fills, any advance may evict old lines. Conservatively
        // refuse anchors until a fresh prompt in a non-full, non-alternate grid.
        if now < history
            || now >= self.history_limit
            || self.term.mode().contains(TermMode::ALT_SCREEN)
        {
            self.shell_anchors.invalidate();
        }
    }
    /// Explicit bounded navigation query; snapshots never carry a growing mark
    /// array. Lines are relative to the current live grid (history is negative).
    /// Apply target displayOffset through revision-checked terminal.scroll.
    pub fn prompt_marks(&mut self, revision: u64) -> Result<Value> {
        self.poll()?;
        ensure!(
            revision == self.revision,
            "Terminal revision changed; read a fresh frame"
        );
        let history = self.term.grid().history_size();
        let cols = self.term.columns();
        let marks = if self.term.mode().contains(TermMode::ALT_SCREEN) {
            vec![]
        } else {
            self.shell_anchors.prompts.iter()
                .map(|position|if position.col>=cols {(position.row+1,0)}else{(position.row,position.col)})
                .filter(|(row,_)|*row<history+self.term.screen_lines())
                .map(|(row,col)|json!({"line":row as i32-history as i32,"col":col,"displayOffset":history.saturating_sub(row)}))
                .collect::<Vec<_>>()
        };
        Ok(json!({"revision":self.revision,"marks":marks}))
    }
    /// Exact observed-revision output hook for the API owner. Never executes the
    /// text. No suffix search through arbitrary output; bash's delayed mark is
    /// verified against its original prompt-anchored command line only.
    pub fn last_command_output(&mut self, revision: u64) -> Result<Option<String>> {
        self.poll()?;
        ensure!(
            revision == self.revision,
            "Terminal revision changed; read a fresh frame"
        );
        if self.term.mode().contains(TermMode::ALT_SCREEN) {
            return Ok(None);
        }
        let Some(output) = self.shell_anchors.output.clone() else {
            return Ok(None);
        };
        if self.shell.state.command.as_deref() != Some(output.command.as_str()) {
            return Ok(None);
        }
        let history = self.term.grid().history_size();
        let cols = self.term.columns();
        let end = output.end.unwrap_or_else(|| self.shell_position());
        let mut start = if let Some(start) = output.start {
            start
        } else {
            let Some((prompt, lines)) = output.prompt else {
                return Ok(None);
            };
            let mut row = prompt.row + lines.saturating_sub(1);
            if row >= end.row {
                return Ok(None);
            }
            let mut command_line = String::new();
            loop {
                if row >= history + self.term.screen_lines() {
                    return Ok(None);
                }
                command_line.push_str(&self.shell_copy(row, 0, row, cols - 1)?);
                if command_line.len() > 32 * 1024 {
                    return Ok(None);
                }
                let wrapped = self.term.grid()[Line(row as i32 - history as i32)][Column(cols - 1)]
                    .flags
                    .contains(Flags::WRAPLINE);
                row += 1;
                if !wrapped {
                    break;
                }
            }
            if !command_line
                .trim_end_matches([' ', '\t'])
                .ends_with(&output.command)
            {
                return Ok(None);
            }
            shell::Position { row, col: 0 }
        };
        if start.col >= cols {
            start.row += 1;
            start.col = 0;
        }
        if start.row > end.row
            || (start.row == end.row && start.col > end.col)
            || end.row >= history + self.term.screen_lines()
        {
            return Ok(None);
        }
        let mut text = format!("$ {}", output.command);
        if start != end {
            let (last_row, last_col) = if end.col == 0 {
                let Some(row) = end.row.checked_sub(1) else {
                    return Ok(None);
                };
                (row, cols - 1)
            } else {
                (end.row, end.col.min(cols) - 1)
            };
            if last_row < start.row {
                return Ok(None);
            }
            let body = self.shell_copy(start.row, start.col, last_row, last_col)?;
            let body = body.trim_end_matches([' ', '\t', '\n']);
            if !body.is_empty() {
                text.push('\n');
                text.push_str(body);
            }
        }
        if text.len() > 1024 * 1024 {
            return Ok(None);
        }
        Ok(Some(text))
    }
    fn shell_copy(
        &self,
        first: usize,
        first_col: usize,
        last: usize,
        last_col: usize,
    ) -> Result<String> {
        let history = self.term.grid().history_size();
        let cols = self.term.columns();
        ensure!(
            first <= last && last < history + self.term.screen_lines(),
            "Command anchor left the buffer"
        );
        let mut result = String::new();
        let mut offset = first;
        while offset <= last {
            let end = (offset + 299).min(last);
            let part = copy_cells(
                offset,
                end - offset + 1,
                cols,
                TerminalPoint {
                    row: offset,
                    col: if offset == first { first_col } else { 0 },
                },
                TerminalPoint {
                    row: end,
                    col: if end == last { last_col } else { cols - 1 },
                },
                |row, col| {
                    let cell = &self.term.grid()[Line(row as i32 - history as i32)][Column(col)];
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
                },
            )?;
            result.push_str(&part);
            if end < last
                && !self.term.grid()[Line(end as i32 - history as i32)][Column(cols - 1)]
                    .flags
                    .contains(Flags::WRAPLINE)
            {
                result.push('\n');
            }
            ensure!(result.len() <= 1024 * 1024, "Command output exceeds 1 MiB");
            offset = end + 1;
        }
        Ok(result)
    }
    pub fn write(&mut self, text: &str) -> Result<()> {
        ensure!(text.len() <= 32 * 1024, "Terminal input exceeds 32 KiB");
        self.writer
            .as_ref()
            .context("Terminal is stopping")?
            .try_send(text.as_bytes().to_vec())?;
        Ok(())
    }
    /// Structured input uses the latest parsed modes without a UI read/write
    /// round trip. Accepted means one complete message queued, not shell delivery.
    pub fn input(&mut self, input: TerminalInput) -> Result<Value> {
        self.poll()?;
        let bytes = encode_input(input, self.input_modes())?;
        let len = bytes.len();
        self.writer
            .as_ref()
            .context("Terminal is stopping")?
            .try_send(bytes)?;
        Ok(json!({"accepted":true,"observedRevision":self.revision,"encodedBytes":len}))
    }
    fn input_modes(&self) -> InputModes {
        InputModes {
            application_cursor: self.term.mode().contains(TermMode::APP_CURSOR),
            bracketed_paste: self.term.mode().contains(TermMode::BRACKETED_PASTE),
        }
    }
    pub fn resize(&mut self, rows: u16, cols: u16) -> Result<()> {
        check_size(rows, cols)?;
        self.master
            .as_ref()
            .context("Terminal is stopping")?
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })?;
        self.shell_anchors.invalidate();
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
        let exited = self
            .child
            .as_mut()
            .context("Terminal is stopping")?
            .try_wait()?
            .map(|s| s.exit_code());
        Ok(
            json!({"title":self.title.chars().take(MAX_TITLE_CHARS).collect::<String>(),"lines":lines,"rows":self.term.screen_lines(),"cols":self.term.columns(),"revision":self.revision,"exitCode":exited,"viewport":self.viewport(),"modes":self.input_modes(),"shell":self.shell.state}),
        )
    }
    /// At most ten styled viewport rows per response. Cursor coordinates remain
    /// absolute viewport coordinates; grid/lines indices start at rowOffset.
    pub fn styled_snapshot(&mut self, row_offset: usize, row_limit: usize) -> Result<Value> {
        self.styled_snapshot_with(row_offset, row_limit, &Palette::default())
    }
    /// A page with `palette`'s default colors, as `styled_snapshot`.
    pub fn styled_snapshot_with(
        &mut self,
        row_offset: usize,
        row_limit: usize,
        palette: &Palette,
    ) -> Result<Value> {
        ensure!(
            (1..=MAX_STYLED_ROWS).contains(&row_limit),
            "Styled row limit must be 1–10"
        );
        self.poll()?;
        self.styled_rows(row_offset, row_limit, palette)
    }
    /// The whole viewport from one poll, for the in-process renderer (Swift
    /// sizes the terminal to its pane). Not bounded by the API's page size.
    pub fn styled_viewport(&mut self, palette: &Palette) -> Result<Value> {
        self.poll()?;
        self.styled_rows(0, self.term.screen_lines(), palette)
    }
    fn styled_rows(
        &mut self,
        row_offset: usize,
        row_limit: usize,
        palette: &Palette,
    ) -> Result<Value> {
        let rows = self.term.screen_lines();
        let cols = self.term.columns();
        ensure!(row_offset <= rows, "Styled row offset exceeds viewport");
        let row_count = row_limit.min(rows - row_offset);
        let mut lines = vec![String::new(); row_count];
        let mut grid = vec![Vec::with_capacity(cols); row_count];
        let content = self.term.renderable_content();
        let mut truncated = self.title.chars().count() > MAX_TITLE_CHARS;
        let mut links: Vec<String> = vec![];
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
                let mut foreground = resolve_color(cell.fg, content.colors, palette);
                let mut background = resolve_color(cell.bg, content.colors, palette);
                if flags.contains(Flags::DIM) {
                    foreground = foreground.map(|channel| (u16::from(channel) * 2 / 3) as u8);
                }
                if flags.contains(Flags::INVERSE) {
                    std::mem::swap(&mut foreground, &mut background);
                }
                if flags.contains(Flags::HIDDEN) {
                    foreground = background;
                }
                // OSC 8 targets are listed once per page and only ever opened
                // on an explicit click; past the bound a cell has no link.
                let link = cell.hyperlink().and_then(|link| {
                    let uri = link.uri();
                    if let Some(index) = links.iter().position(|known| known == uri) {
                        Some(index)
                    } else if links.len() < MAX_LINKS && uri.len() <= MAX_LINK_BYTES {
                        links.push(uri.to_owned());
                        Some(links.len() - 1)
                    } else {
                        truncated = true;
                        None
                    }
                });
                grid[page_row].push(json!({
                "text": text,
                "link": link,
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
        let exited = self
            .child
            .as_mut()
            .context("Terminal is stopping")?
            .try_wait()?
            .map(|s| s.exit_code());
        Ok(json!({
            "title": self.title.chars().take(MAX_TITLE_CHARS).collect::<String>(),
            "lines": lines, "rows": rows, "cols": cols,
            "revision": self.revision, "exitCode": exited,
            "grid": grid, "links": links, "cursor": cursor, "truncated": truncated,
            "rowOffset": row_offset, "rowCount": row_count,
            "viewport": self.viewport(), "modes": self.input_modes(), "shell":self.shell.state,
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

/// Native text commits, clipboard pastes and terminal keys are distinct. Raw
/// terminal.write remains available for callers intentionally sending VT bytes.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum TerminalInput {
    Text {
        text: String,
    },
    Paste {
        text: String,
    },
    Key {
        key: String,
        #[serde(default)]
        modifiers: KeyModifiers,
    },
}
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct KeyModifiers {
    #[serde(default)]
    pub shift: bool,
    #[serde(default)]
    pub alt: bool,
    #[serde(default)]
    pub control: bool,
}
#[derive(Clone, Copy, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct InputModes {
    application_cursor: bool,
    bracketed_paste: bool,
}
const MAX_INPUT_BYTES: usize = 32 * 1024;
fn encode_input(input: TerminalInput, modes: InputModes) -> Result<Vec<u8>> {
    let encoded = match input {
        TerminalInput::Text { text } | TerminalInput::Paste { text }
            if text.len() > MAX_INPUT_BYTES =>
        {
            anyhow::bail!("Terminal input exceeds 32 KiB");
        }
        TerminalInput::Text { text } => {
            check_structured_text(&text)?;
            text
        }
        TerminalInput::Paste { text } => {
            check_structured_text(&text)?;
            if modes.bracketed_paste {
                ensure!(
                    text.len() <= MAX_INPUT_BYTES - 12,
                    "Encoded terminal paste exceeds 32 KiB"
                );
                format!("\x1b[200~{text}\x1b[201~")
            } else {
                text
            }
        }
        TerminalInput::Key { key, modifiers: m } => encode_key(&key, m, modes.application_cursor)?,
    };
    ensure!(
        encoded.len() <= MAX_INPUT_BYTES,
        "Encoded terminal input exceeds 32 KiB"
    );
    Ok(encoded.into_bytes())
}
fn check_structured_text(text: &str) -> Result<()> {
    ensure!(
        !text
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\t' | '\r' | '\n')),
        "Structured terminal text contains control framing; use raw write for VT bytes"
    );
    Ok(())
}
fn encode_key(key: &str, m: KeyModifiers, application: bool) -> Result<String> {
    let modifier = 1 + u8::from(m.shift) + 2 * u8::from(m.alt) + 4 * u8::from(m.control);
    if m.control && key.len() == 1 {
        let byte = key.as_bytes()[0].to_ascii_uppercase();
        ensure!(
            (b'@'..=b'_').contains(&byte),
            "Unsupported terminal control key"
        );
        return Ok(format!(
            "{}{}",
            if m.alt { "\x1b" } else { "" },
            (byte - 64) as char
        ));
    }
    let result = match key {
        "up" | "down" | "left" | "right" | "home" | "end" => {
            let suffix = match key {
                "up" => 'A',
                "down" => 'B',
                "right" => 'C',
                "left" => 'D',
                "home" => 'H',
                _ => 'F',
            };
            if modifier != 1 {
                format!("\x1b[1;{modifier}{suffix}")
            } else {
                format!("\x1b{}{suffix}", if application { "O" } else { "[" })
            }
        }
        "pageUp" | "pageDown" | "insert" | "delete" => {
            let code = match key {
                "pageUp" => 5,
                "pageDown" => 6,
                "insert" => 2,
                _ => 3,
            };
            if modifier == 1 {
                format!("\x1b[{code}~")
            } else {
                format!("\x1b[{code};{modifier}~")
            }
        }
        "enter" | "backspace" | "tab" | "escape" => {
            ensure!(!m.control, "Unsupported terminal key modifier");
            let base = match key {
                "enter" => "\r",
                "backspace" => "\x7f",
                "tab" if m.shift => "\x1b[Z",
                "tab" => "\t",
                _ => "\x1b",
            };
            format!("{}{base}", if m.alt { "\x1b" } else { "" })
        }
        _ => anyhow::bail!("Unsupported terminal key; commit characters with text input"),
    };
    Ok(result)
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
// Bold is font weight; underline variants collapse to a boolean. Defaults come
// from the request's Palette (dark unless asked); OSC palette overrides apply. Each page contains at most
// 10 * 500 cells, each with 1 base + 16 combining scalars and fixed-size style
// metadata and a `links` index, safely below the control transport's 4 MiB
// frame. Title is bounded
// to 1024 scalars. `truncated` reports text/title clipping, not ordinary paging.
// Plain snapshot() never allocates a styled grid or resolves cell colors.
const MAX_STYLED_ROWS: usize = 10;
const MAX_COMBINING_CHARS: usize = 16;
const MAX_TITLE_CHARS: usize = 1024;
/// At most 64 distinct OSC 8 targets of 2 KiB per page (128 KiB).
const MAX_LINKS: usize = 64;
const MAX_LINK_BYTES: usize = 2048;

/// Default terminal colors for one appearance (Swift TerminalTheme): T3 Code's
/// ANSI palettes and caret colors, with the theme's text and background.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Palette {
    pub dark: bool,
    pub foreground: [u8; 3],
    pub background: [u8; 3],
}
impl Default for Palette {
    /// Coincide's legacy dark terminal colors.
    fn default() -> Self {
        Self {
            dark: true,
            foreground: [0xD4; 3],
            background: [0x0C; 3],
        }
    }
}
impl Palette {
    /// `{"appearance":"light"|"dark","foreground":[r,g,b],"background":[r,g,b]}`;
    /// missing parts keep the dark defaults.
    pub fn from_value(value: &Value) -> Result<Self> {
        let mut palette = Self::default();
        if value.is_null() {
            return Ok(palette);
        }
        ensure!(value.is_object(), "Terminal palette must be an object");
        palette.dark = match value["appearance"].as_str() {
            None | Some("dark") => true,
            Some("light") => false,
            Some(_) => anyhow::bail!("Terminal appearance must be light or dark"),
        };
        for (key, slot) in [
            ("foreground", &mut palette.foreground),
            ("background", &mut palette.background),
        ] {
            if value[key].is_null() {
                continue;
            }
            let channels: Vec<u8> = serde_json::from_value(value[key].clone())
                .context("Terminal palette colors are [r, g, b]")?;
            *slot = channels
                .try_into()
                .map_err(|_| anyhow::anyhow!("Terminal palette colors are [r, g, b]"))?;
        }
        Ok(palette)
    }
    /// The caret: T3 Code's light or dark cursor color.
    pub fn cursor(&self) -> [u8; 3] {
        unpack(if self.dark { 0xB4CBFF } else { 0x26384E })
    }
}
const DARK_ANSI: [u32; 16] = [
    0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5, 0x666666,
    0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5,
];
const LIGHT_ANSI: [u32; 16] = [
    0x000000, 0xCD3131, 0x107C10, 0x949800, 0x0451A5, 0xBC05BC, 0x0598BC, 0x555555, 0x666666,
    0xCD3131, 0x14CE14, 0xB5BA00, 0x0451A5, 0xBC05BC, 0x0598BC, 0xA5A5A5,
];
fn unpack(packed: u32) -> [u8; 3] {
    [(packed >> 16) as u8, (packed >> 8) as u8, packed as u8]
}
fn dim(rgb: [u8; 3]) -> [u8; 3] {
    rgb.map(|channel| (u16::from(channel) * 2 / 3) as u8)
}

fn resolve_color(color: Color, colors: &Colors, palette: &Palette) -> [u8; 3] {
    let index = match color {
        Color::Spec(rgb) => return [rgb.r, rgb.g, rgb.b],
        Color::Indexed(index) => usize::from(index),
        Color::Named(name) => name as usize,
    };
    if let Some(rgb) = colors[index] {
        return [rgb.r, rgb.g, rgb.b];
    }
    let ansi = if palette.dark {
        &DARK_ANSI
    } else {
        &LIGHT_ANSI
    };
    let packed = match index {
        0..=15 => ansi[index],
        16..=231 => {
            let cube = index - 16;
            let levels = [0u32, 95, 135, 175, 215, 255];
            (levels[cube / 36] << 16) | (levels[cube / 6 % 6] << 8) | levels[cube % 6]
        }
        232..=255 => {
            let gray = 8 + (index as u32 - 232) * 10;
            gray * 0x010101
        }
        257 => return palette.background,
        258 => return palette.cursor(),
        259..=266 => return dim(unpack(ansi[index - 259])),
        268 => return dim(palette.foreground),
        _ => return palette.foreground,
    };
    unpack(packed)
}

#[derive(Debug, Clone, Default)]
pub struct TerminalShutdownStatus {
    pub requested: bool,
    pub child_exited: bool,
    pub reader_joined: bool,
    pub writer_joined: bool,
    pub joined: bool,
    pub error: Option<String>,
}
impl TerminalShutdownStatus {
    pub fn ready(&self) -> bool {
        self.requested
            && self.child_exited
            && self.reader_joined
            && self.writer_joined
            && self.joined
            && self.error.is_none()
    }
}
struct ShutdownResources {
    child: Box<dyn Child + Send + Sync>,
    master: Option<Box<dyn MasterPty + Send>>,
    shell_launch: Option<shell::ShellLaunch>,
    reader: Option<thread::JoinHandle<()>>,
    writer: Option<thread::JoinHandle<()>>,
}
pub struct PendingTerminalShutdown {
    // Retained on join-thread spawn failure; no closure-owned Terminal Drop.
    _resources: Arc<Mutex<Option<ShutdownResources>>>,
    status: Arc<Mutex<TerminalShutdownStatus>>,
}
impl PendingTerminalShutdown {
    fn start(resources: ShutdownResources) -> Self {
        let resources = Arc::new(Mutex::new(Some(resources)));
        let status = Arc::new(Mutex::new(TerminalShutdownStatus {
            requested: true,
            ..Default::default()
        }));
        let owned = resources.clone();
        let observation = status.clone();
        let started = thread::Builder::new()
            .name("coincide-terminal-join".into())
            .spawn(move || {
                let Some(mut resources) = owned.lock().unwrap_or_else(|e| e.into_inner()).take()
                else {
                    return;
                };
                // Avoid signalling an already reaped PID. Signal only the directly
                // owned child; never a process group. Confirmed wait resolves a
                // benign kill error; a failed wait remains unknown.
                let waited = match resources.child.try_wait() {
                    Ok(Some(status)) => Ok(status),
                    _ => {
                        let _ = resources.child.kill();
                        resources.child.wait()
                    }
                };
                match waited {
                    Ok(_) => {
                        observation
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .child_exited = true
                    }
                    Err(_) => {
                        observation.lock().unwrap_or_else(|e| e.into_inner()).error =
                            Some("Terminal child wait failed; exit is unknown".into())
                    }
                }
                drop(resources.master.take());
                for (reader, worker) in [
                    (false, resources.writer.take()),
                    (true, resources.reader.take()),
                ] {
                    let result = worker.map_or(Ok(()), |worker| worker.join());
                    let mut status = observation.lock().unwrap_or_else(|e| e.into_inner());
                    match result {
                        Ok(()) if reader => status.reader_joined = true,
                        Ok(()) => status.writer_joined = true,
                        Err(_) => status.error = Some("Terminal I/O worker join failed".into()),
                    }
                }
                if observation
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .child_exited
                {
                    // Temporary shell integration files outlive every confirmed owner.
                    drop(resources.shell_launch.take());
                    drop(resources);
                } else {
                    // A failed wait must not discard the child or its launch resources.
                    *owned.lock().unwrap_or_else(|e| e.into_inner()) = Some(resources);
                }
                observation.lock().unwrap_or_else(|e| e.into_inner()).joined = true;
            });
        if started.is_err() {
            status.lock().unwrap_or_else(|e| e.into_inner()).error =
                Some("Terminal join worker could not start; ownership retained".into());
        }
        Self {
            _resources: resources,
            status,
        }
    }
    pub fn poll(&self) -> TerminalShutdownStatus {
        self.status
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        if let Some(child) = &mut self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
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

#[cfg(test)]
mod structured_input_tests {
    use super::*;
    fn key(key: &str, modifiers: KeyModifiers) -> TerminalInput {
        TerminalInput::Key {
            key: key.into(),
            modifiers,
        }
    }
    #[test]
    fn normal_application_and_modified_cursor_keys_have_exact_bytes() {
        let normal = InputModes::default();
        let app = InputModes {
            application_cursor: true,
            ..normal
        };
        for (name, suffix) in [
            ("up", "A"),
            ("down", "B"),
            ("right", "C"),
            ("left", "D"),
            ("home", "H"),
            ("end", "F"),
        ] {
            assert_eq!(
                encode_input(key(name, Default::default()), normal).unwrap(),
                format!("\x1b[{suffix}").into_bytes()
            );
            assert_eq!(
                encode_input(key(name, Default::default()), app).unwrap(),
                format!("\x1bO{suffix}").into_bytes()
            );
            assert_eq!(
                encode_input(
                    key(
                        name,
                        KeyModifiers {
                            shift: true,
                            control: true,
                            alt: false
                        }
                    ),
                    app
                )
                .unwrap(),
                format!("\x1b[1;6{suffix}").into_bytes()
            );
        }
        assert_eq!(
            encode_input(
                key(
                    "c",
                    KeyModifiers {
                        control: true,
                        ..Default::default()
                    }
                ),
                app
            )
            .unwrap(),
            b"\x03"
        );
        assert_eq!(
            encode_input(
                key(
                    "pageUp",
                    KeyModifiers {
                        alt: true,
                        ..Default::default()
                    }
                ),
                app
            )
            .unwrap(),
            b"\x1b[5;3~"
        );
        assert!(encode_input(key("a", Default::default()), normal).is_err());
        assert!(
            encode_input(
                key(
                    "enter",
                    KeyModifiers {
                        control: true,
                        ..Default::default()
                    }
                ),
                normal
            )
            .is_err()
        );
    }
    #[test]
    fn paste_and_text_preserve_unicode_and_newlines_without_generated_enter() {
        let modes = InputModes {
            bracketed_paste: true,
            ..Default::default()
        };
        let text = "界e\u{301}\r\n\t";
        assert_eq!(
            encode_input(TerminalInput::Paste { text: text.into() }, modes).unwrap(),
            format!("\x1b[200~{text}\x1b[201~").into_bytes()
        );
        assert_eq!(
            encode_input(TerminalInput::Text { text: text.into() }, modes).unwrap(),
            text.as_bytes()
        );
        assert_eq!(
            encode_input(
                TerminalInput::Paste { text: text.into() },
                Default::default()
            )
            .unwrap(),
            text.as_bytes()
        );
    }
    #[test]
    fn framing_controls_and_encoded_oversize_fail_before_queueing() {
        for text in ["\x1b[201~", "\0", "\x03", "\x7f", "\u{85}", "\u{9b}201~"] {
            assert!(
                encode_input(
                    TerminalInput::Text { text: text.into() },
                    Default::default()
                )
                .is_err()
            );
            assert!(
                encode_input(
                    TerminalInput::Paste { text: text.into() },
                    Default::default()
                )
                .is_err()
            );
        }
        let modes = InputModes {
            bracketed_paste: true,
            ..Default::default()
        };
        assert_eq!(
            encode_input(
                TerminalInput::Paste {
                    text: "a".repeat(MAX_INPUT_BYTES - 12)
                },
                modes
            )
            .unwrap()
            .len(),
            MAX_INPUT_BYTES
        );
        assert!(
            encode_input(
                TerminalInput::Paste {
                    text: "a".repeat(MAX_INPUT_BYTES - 11)
                },
                modes
            )
            .is_err()
        );
        assert!(
            encode_input(
                TerminalInput::Text {
                    text: "a".repeat(MAX_INPUT_BYTES + 1)
                },
                modes
            )
            .is_err()
        );
        assert_eq!(
            encode_input(
                TerminalInput::Text {
                    text: "a".repeat(MAX_INPUT_BYTES)
                },
                modes
            )
            .unwrap()
            .len(),
            MAX_INPUT_BYTES
        );
    }
    #[test]
    fn structured_enum_and_nested_modifiers_reject_unknown_or_wrong_fields() {
        for value in [
            json!({"kind":"unknown"}),
            json!({"kind":"text"}),
            json!({"kind":"text","text":1}),
            json!({"kind":"paste","text":"x","revision":1}),
            json!({"kind":"key","key":"up","modifiers":{"platform":true}}),
            json!({"kind":"key","key":"up","modifiers":{"control":1}}),
        ] {
            assert!(serde_json::from_value::<TerminalInput>(value).is_err());
        }
        assert!(serde_json::from_value::<TerminalInput>(json!({"kind":"key","key":"up"})).is_ok());
    }
}

#[cfg(test)]
mod shutdown_tests {
    use super::*;
    use std::sync::{
        Condvar,
        atomic::{AtomicBool, Ordering},
    };
    use std::time::{Duration, Instant};
    #[derive(Debug, Clone)]
    struct FakeChild {
        exited: Arc<AtomicBool>,
        fail_wait: bool,
    }
    impl portable_pty::ChildKiller for FakeChild {
        fn kill(&mut self) -> std::io::Result<()> {
            Err(std::io::Error::other("already exited fixture"))
        }
        fn clone_killer(&self) -> Box<dyn portable_pty::ChildKiller + Send + Sync> {
            Box::new(self.clone())
        }
    }
    impl Child for FakeChild {
        fn try_wait(&mut self) -> std::io::Result<Option<portable_pty::ExitStatus>> {
            Ok(None)
        }
        fn wait(&mut self) -> std::io::Result<portable_pty::ExitStatus> {
            if self.fail_wait {
                return Err(std::io::Error::other("fixture wait failed"));
            }
            self.exited.store(true, Ordering::SeqCst);
            Ok(portable_pty::ExitStatus::with_exit_code(0))
        }
        fn process_id(&self) -> Option<u32> {
            None
        }
        #[cfg(windows)]
        fn as_raw_handle(&self) -> Option<std::os::windows::io::RawHandle> {
            None
        }
    }
    fn resources(fail_wait: bool) -> ShutdownResources {
        ShutdownResources {
            child: Box::new(FakeChild {
                exited: Arc::new(AtomicBool::new(false)),
                fail_wait,
            }),
            master: None,
            shell_launch: None,
            reader: None,
            writer: None,
        }
    }
    fn until(mut condition: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(3);
        while !condition() {
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
    }
    #[test]
    fn terminal_shutdown_retains_pending_reader_until_actual_tls_join() {
        struct Gate(Arc<(Mutex<bool>, Condvar)>, Arc<AtomicBool>);
        impl Drop for Gate {
            fn drop(&mut self) {
                self.1.store(true, Ordering::SeqCst);
                let lock = self.0.0.lock().unwrap();
                drop(self.0.1.wait_while(lock, |blocked| *blocked).unwrap());
            }
        }
        thread_local! { static EXIT:std::cell::RefCell<Option<Gate>>=const {std::cell::RefCell::new(None)}; }
        let gate = Arc::new((Mutex::new(true), Condvar::new()));
        struct Release(Arc<(Mutex<bool>, Condvar)>);
        impl Drop for Release {
            fn drop(&mut self) {
                *self.0.0.lock().unwrap() = false;
                self.0.1.notify_all();
            }
        }
        let _release = Release(gate.clone());
        let entered = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(1);
        tx.send(vec![1]).unwrap();
        let g = gate.clone();
        let e = entered.clone();
        let reader = thread::spawn(move || {
            EXIT.with(|slot| *slot.borrow_mut() = Some(Gate(g, e)));
            let _ = tx.send(vec![2]);
        });
        let (writer_tx, writer_rx) = mpsc::sync_channel::<Vec<u8>>(1);
        let writer = thread::spawn(move || while writer_rx.recv().is_ok() {});
        let mut owned = resources(false);
        owned.reader = Some(reader);
        owned.writer = Some(writer);
        drop(rx);
        drop(writer_tx);
        let pending = PendingTerminalShutdown::start(owned);
        until(|| {
            entered.load(Ordering::SeqCst)
                && pending.poll().child_exited
                && pending.poll().writer_joined
        });
        let state = pending.poll();
        assert!(!state.reader_joined);
        assert!(!state.ready());
        *gate.0.lock().unwrap() = false;
        gate.1.notify_all();
        until(|| pending.poll().joined);
        assert!(
            pending.poll().ready(),
            "confirmed exit resolves benign kill failure"
        );
    }
    #[cfg(unix)]
    #[test]
    fn restart_retains_exited_shell_reader_until_its_actual_join() {
        let root = tempfile::tempdir().unwrap();
        let shell = root.path().join("exited-shell");
        std::fs::write(&shell, "#!/bin/sh\nexit 3\n").unwrap();
        std::fs::set_permissions(&shell, std::os::unix::fs::PermissionsExt::from_mode(0o700))
            .unwrap();
        let mut terminal = Terminal::spawn(root.path(), shell.to_str().unwrap(), 6, 40).unwrap();
        terminal.number = 7;
        until(|| {
            terminal.poll().unwrap();
            terminal.exited()
        });
        let before = terminal.revision;
        let actual_reader = terminal.reader_worker.take().unwrap();
        let entered = Arc::new(AtomicBool::new(false));
        let report = entered.clone();
        let (release_tx, release_rx) = mpsc::channel();
        struct Release(Option<mpsc::Sender<()>>);
        impl Drop for Release {
            fn drop(&mut self) {
                if let Some(tx) = self.0.take() {
                    let _ = tx.send(());
                }
            }
        }
        let release = Release(Some(release_tx));
        terminal.reader_worker = Some(thread::spawn(move || {
            actual_reader.join().unwrap();
            report.store(true, Ordering::SeqCst);
            release_rx.recv().unwrap();
        }));
        let retired = terminal.restart(root.path(), "/bin/sh").unwrap();
        assert_eq!(terminal.number, 7);
        assert!(!terminal.exited());
        assert!(terminal.revision > before);
        until(|| entered.load(Ordering::SeqCst) && retired.poll().writer_joined);
        assert!(retired.poll().child_exited);
        assert!(!retired.poll().reader_joined);
        assert!(!retired.poll().ready());
        drop(release);
        until(|| retired.poll().ready());
        let fresh = terminal.request_shutdown().unwrap();
        until(|| fresh.poll().ready());
    }

    #[test]
    fn terminal_shutdown_failed_wait_retains_child_and_blocks_ready() {
        let pending = PendingTerminalShutdown::start(resources(true));
        until(|| pending.poll().joined);
        let state = pending.poll();
        assert!(!state.child_exited);
        assert!(state.error.is_some());
        assert!(!state.ready());
        assert!(pending._resources.lock().unwrap().is_some());
    }
}

#[cfg(test)]
mod appearance_tests {
    use super::*;

    #[test]
    fn light_and_dark_palettes_resolve_ansi_defaults_and_the_caret() {
        use alacritty_terminal::vte::ansi::NamedColor;
        let light = Palette::from_value(
            &json!({"appearance":"light","foreground":[1,2,3],"background":[250,250,250]}),
        )
        .unwrap();
        let colors = Colors::default();
        let resolve = |color, palette: &Palette| resolve_color(color, &colors, palette);
        let dark = Palette::default();
        assert_eq!(
            resolve(Color::Named(NamedColor::Green), &light),
            [0x10, 0x7C, 0x10]
        );
        assert_eq!(
            resolve(Color::Named(NamedColor::Green), &dark),
            [0x0D, 0xBC, 0x79]
        );
        assert_eq!(resolve(Color::Indexed(7), &light), [0x55, 0x55, 0x55]);
        assert_eq!(
            resolve(Color::Named(NamedColor::Background), &light),
            [250, 250, 250]
        );
        assert_eq!(
            resolve(Color::Named(NamedColor::Foreground), &light),
            [1, 2, 3]
        );
        assert_eq!(
            resolve(Color::Named(NamedColor::Cursor), &light),
            [0x26, 0x38, 0x4E]
        );
        // Dim default text is two thirds of the theme's text color.
        assert_eq!(
            resolve(Color::Named(NamedColor::DimForeground), &dark),
            [0x8D; 3]
        );
        assert_eq!(
            resolve(Color::Named(NamedColor::Background), &dark),
            [12; 3]
        );
        assert_eq!(
            resolve(Color::Named(NamedColor::Foreground), &dark),
            [0xD4; 3]
        );
        assert_eq!(
            resolve(Color::Named(NamedColor::Cursor), &dark),
            [0xB4, 0xCB, 0xFF]
        );
        assert_eq!(resolve(Color::Indexed(196), &light), [255, 0, 0]);
        assert_eq!(Palette::from_value(&Value::Null).unwrap(), dark);
        for invalid in [
            json!({"appearance":"sepia"}),
            json!({"foreground":[1,2]}),
            json!({"background":"white"}),
            json!(5),
        ] {
            assert!(Palette::from_value(&invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn bells_are_counted_and_a_silent_progress_bar_times_out() {
        let mut terminal = Terminal::fixture_output(2, 10, b"\x07\x1b]9;4;1;50\x07ok\x07");
        terminal.poll().unwrap();
        let status = terminal.status();
        assert_eq!(status["bells"], 2);
        assert_eq!(status["progress"], json!({"state":"normal","percent":50}));
        assert_eq!(status["name"], "Terminal 0");
        let revision = terminal.revision;
        terminal.progress_at = Some(Instant::now() - PROGRESS_TIMEOUT);
        assert!(terminal.poll().unwrap());
        assert!(terminal.revision > revision);
        assert_eq!(terminal.status()["progress"], Value::Null);
    }
}
