//! Real PTY process with Alacritty's terminal state, shared by API and renderer.
use alacritty_terminal::{
    event::{Event, EventListener},
    grid::Dimensions,
    term::{Config, Term},
    vte::ansi::Processor,
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
            json!({"title":self.title,"lines":lines,"rows":self.term.screen_lines(),"cols":self.term.columns(),"revision":self.revision,"exitCode":exited}),
        )
    }
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
