//! A thread's terminals on the Engine: where they start, their numbers, what
//! each tab shows and restarting an exited shell (Swift ThreadTerminals,
//! TerminalLaunch and TerminalSession).
use super::*;
use crate::terminal::{
    Palette, Terminal,
    launch::{self, StartDirectory},
};

/// Methods routed here before the Engine's main dispatch.
pub(super) const METHODS: &[&str] = &["terminal.status", "terminal.restart", "terminal.close"];

/// The shell a terminal runs: `$SHELL`, else the platform's own.
fn terminal_shell() -> String {
    std::env::var("SHELL").unwrap_or_else(|_| {
        if cfg!(windows) {
            "powershell.exe".into()
        } else {
            "/bin/sh".into()
        }
    })
}

impl Engine {
    pub(super) fn terminal_command(&mut self, method: &str, p: &Value) -> Result<Value> {
        match method {
            "terminal.status" => Ok(self.terminal_listing(p["threadId"].as_str())),
            "terminal.restart" => self.restart_terminal(p, &terminal_shell()),
            "terminal.close" => self.close_terminal(p),
            _ => bail!("Unknown terminal method {method}"),
        }
    }
    /// Remove the pane immediately, retaining every retired native/I/O owner
    /// in the collector until its actual exit and joins are confirmed.
    fn close_terminal(&mut self, params: &Value) -> Result<Value> {
        ensure!(!self.admissions_frozen(), "Application is closing");
        let id = required(params, "terminalId")?.to_owned();
        let (thread, mut terminal) = self.terminals.remove(&id).context("Terminal not found")?;
        match terminal.request_shutdown() {
            Ok(pending) => self.retain_terminal_owner(id, thread, pending),
            Err(error) => {
                self.terminals.insert(id, (thread, terminal));
                return Err(error);
            }
        }
        self.revision += 1;
        Ok(json!({"closed":true}))
    }

    /// Swift TerminalLaunch.directory: the thread's worktree or project folder,
    /// the project folder when the worktree is gone, else home.
    pub(super) fn terminal_start_directory(&self, thread: &Value) -> Result<StartDirectory> {
        let project = self.store.projects()?.as_array().and_then(|projects| {
            projects
                .iter()
                .find(|project| project["id"] == thread["projectID"])
                .and_then(|project| project["path"].as_str())
                .filter(|path| !path.is_empty())
                .map(PathBuf::from)
        });
        let preferred = thread["worktreePath"]
            .as_str()
            .filter(|path| !path.is_empty())
            .map(PathBuf::from)
            .or_else(|| project.clone());
        Ok(StartDirectory::resolve(preferred, project, launch::home()))
    }
    /// The lowest number no other terminal of the thread uses.
    fn next_terminal_number(&self, thread: &str) -> u32 {
        let used: HashSet<u32> = self
            .terminals
            .values()
            .filter(|(owner, _)| owner == thread)
            .map(|(_, terminal)| terminal.number)
            .collect();
        (1..).find(|number| !used.contains(number)).unwrap_or(1)
    }
    /// A new numbered shell for `thread_id`, in its start folder.
    pub(super) fn spawn_thread_terminal(
        &self,
        thread_id: &str,
        thread: &Value,
        shell: &str,
    ) -> Result<Terminal> {
        let start = self.terminal_start_directory(thread)?;
        let mut terminal = Terminal::spawn_in(&start, shell, 24, 100)?;
        terminal.number = self.next_terminal_number(thread_id);
        Ok(terminal)
    }
    /// `terminal.status`: each terminal with what its tab shows, by number.
    /// Reads pending output first, so a shell that just exited shows it.
    pub(super) fn terminal_listing(&mut self, thread: Option<&str>) -> Value {
        let mut changed = false;
        let mut listed = self
            .terminals
            .iter_mut()
            .filter(|(_, (owner, _))| thread.is_none_or(|id| owner == id))
            .map(|(id, (owner, terminal))| {
                changed |= terminal.poll().unwrap_or(false);
                let mut entry = terminal.status();
                entry["terminalId"] = json!(id);
                entry["threadId"] = json!(owner);
                entry["title"] = json!(terminal.title);
                entry
            })
            .collect::<Vec<_>>();
        listed.sort_by(|a, b| {
            (text(a, "threadId"), a["number"].as_u64())
                .cmp(&(text(b, "threadId"), b["number"].as_u64()))
        });
        if changed {
            self.revision += 1;
        }
        Value::Array(listed)
    }
    /// `terminal.restart`: a new shell for an exited terminal, in the folder
    /// its shell was last in when that still exists.
    pub(super) fn restart_terminal(&mut self, p: &Value, shell: &str) -> Result<Value> {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Request {
            terminal_id: String,
        }
        let request: Request = serde_json::from_value(p.clone())?;
        ensure!(!self.admissions_frozen(), "Application is closing");
        let (thread, terminal) = self
            .terminals
            .get(&request.terminal_id)
            .context("Terminal not found")?;
        ensure!(terminal.exited(), "Terminal is still running");
        let thread = thread.clone();
        let last = terminal.directory().to_path_buf();
        let cwd = if last.is_dir() {
            last
        } else {
            self.terminal_start_directory(&self.store.thread(&thread)?)?
                .path
        };
        let retired = self
            .terminals
            .get_mut(&request.terminal_id)
            .context("Terminal not found")?
            .1
            .restart(&cwd, shell)?;
        self.retain_terminal_owner(request.terminal_id, thread, retired);
        self.revision += 1;
        Ok(json!({"restarted":true}))
    }
    /// The whole styled viewport for the in-process renderer from one Engine
    /// lock, so a tall pane never mixes rows of different revisions.
    pub fn read_terminal_viewport(
        &mut self,
        terminal_id: &str,
        palette: &Palette,
    ) -> Result<Value> {
        self.terminals
            .get_mut(terminal_id)
            .context("Terminal not found")?
            .1
            .styled_viewport(palette)
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn engine() -> (tempfile::TempDir, Engine) {
        let root = tempfile::tempdir().unwrap();
        let engine = Engine::fixture(Store::open(&root.path().join("state.sqlite")).unwrap());
        (root, engine)
    }
    fn wait(engine: &mut Engine, id: &str, done: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let listed = engine.terminal_listing(None);
            if let Some(entry) = listed
                .as_array()
                .unwrap()
                .iter()
                .find(|entry| entry["terminalId"] == id)
                && done(entry)
            {
                return entry.clone();
            }
            assert!(Instant::now() < deadline, "terminal never reached state");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn missing_worktree_starts_in_the_project_with_a_notice_and_numbers_reuse_the_lowest() {
        let (root, mut engine) = engine();
        let project = engine
            .store
            .create_project(root.path(), Some("Synthetic project"))
            .unwrap();
        let thread = engine.dispatch(
            json!({"method":"threads.create","params":{"projectId":text(&project,"id")}}),
        )["result"]
            .clone();
        let id = text(&thread, "id");
        let mut v = engine.store.thread(&id).unwrap();
        v["worktreePath"] = json!(root.path().join("gone").display().to_string());
        let start = engine.terminal_start_directory(&v).unwrap();
        assert_eq!(
            start.path.canonicalize().unwrap(),
            root.path().canonicalize().unwrap()
        );
        assert!(
            start
                .notice()
                .unwrap()
                .contains("no longer exists. Starting in")
        );
        // Without a project the terminal still starts, at home.
        let projectless = json!({"id":"projectless","projectID":null});
        let start = engine.terminal_start_directory(&projectless).unwrap();
        assert_eq!((start.path, start.missing), (launch::home(), None));

        let create = |engine: &mut Engine| {
            let terminal = engine.spawn_thread_terminal(&id, &v, "/bin/sh").unwrap();
            let terminal_id = Uuid::new_v4().to_string();
            let number = terminal.number;
            engine
                .terminals
                .insert(terminal_id.clone(), (id.clone(), terminal));
            (terminal_id, number)
        };
        let (first, one) = create(&mut engine);
        let (_, two) = create(&mut engine);
        assert_eq!((one, two), (1, 2));
        engine.terminals.remove(&first);
        assert_eq!(create(&mut engine).1, 1);
        let listed = engine.terminal_listing(Some(&id));
        let names = listed
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| text(entry, "name"))
            .collect::<Vec<_>>();
        assert_eq!(names, ["Terminal 1", "Terminal 2"]);
        assert_eq!(engine.terminal_listing(Some("other")), json!([]));
    }

    #[test]
    fn closing_a_pane_retains_its_owner_until_actual_io_cleanup() {
        let (root, mut engine) = engine();
        let terminal = Terminal::spawn(root.path(), "/bin/sh", 6, 40).unwrap();
        engine
            .terminals
            .insert("owned".into(), ("thread".into(), terminal));
        assert_eq!(
            engine
                .close_terminal(&json!({"terminalId":"owned"}))
                .unwrap(),
            json!({"closed":true})
        );
        assert!(engine.terminals.is_empty());
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let state = engine.poll_terminals_shutdown();
            assert_eq!(state.panes.len(), 1);
            assert_eq!(state.panes[0].terminal_id, "owned");
            assert_eq!(state.panes[0].thread_id, "thread");
            assert!(!state.requested);
            assert!(!state.ready());
            if state.panes[0].status.ready() {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "closed terminal owners did not join"
            );
            std::thread::yield_now();
        }
        engine.freeze_admissions();
        engine.request_terminals_shutdown().unwrap();
        assert!(engine.poll_terminals_shutdown().ready());
    }

    #[test]
    fn osc_8_links_are_listed_once_per_frame_and_indexed_by_cell() {
        let (root, mut engine) = engine();
        let mut terminal = Terminal::spawn(root.path(), "/bin/sh", 4, 40).unwrap();
        terminal
            .write("printf '\\033[2J\\033[H\\033]8;;https://example.com/x\\033\\\\ab\\033]8;;\\033\\\\ c'\r")
            .unwrap();
        engine
            .terminals
            .insert("linked".into(), ("thread".into(), terminal));
        let deadline = Instant::now() + Duration::from_secs(10);
        let frame = loop {
            let frame = engine
                .read_terminal_viewport("linked", &Palette::default())
                .unwrap();
            if frame["links"]
                .as_array()
                .is_some_and(|links| !links.is_empty())
            {
                break frame;
            }
            assert!(Instant::now() < deadline, "link never rendered");
            std::thread::sleep(Duration::from_millis(20));
        };
        assert_eq!(frame["links"], json!(["https://example.com/x"]));
        let row = frame["grid"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row[0]["text"] == "a")
            .unwrap();
        assert_eq!(
            (row[0]["link"].clone(), row[1]["link"].clone()),
            (json!(0), json!(0))
        );
        assert_eq!(row[2]["link"], Value::Null);
    }
    #[test]
    fn a_shell_that_fails_at_once_keeps_its_pane_and_restarts_with_the_same_number() {
        let (root, mut engine) = engine();
        let shell = root.path().join("failing-shell");
        std::fs::write(&shell, "#!/bin/sh\nexit 3\n").unwrap();
        let mut permissions = std::fs::metadata(&shell).unwrap().permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
        std::fs::set_permissions(&shell, permissions).unwrap();
        let mut terminal = Terminal::spawn(root.path(), shell.to_str().unwrap(), 6, 40).unwrap();
        terminal.number = 4;
        engine
            .terminals
            .insert("failed".into(), ("thread".into(), terminal));
        let entry = wait(&mut engine, "failed", |entry| entry["exited"] == true);
        assert_eq!(entry["exitCode"], 3);
        assert_eq!(entry["keepOpen"], true);
        assert_eq!(entry["exitMessage"], "Process exited with code 3.");
        assert_eq!(entry["busy"], false);
        let frame = engine
            .read_terminal_viewport("failed", &Palette::default())
            .unwrap();
        let screen = frame["lines"]
            .as_array()
            .unwrap()
            .iter()
            .map(|line| line.as_str().unwrap())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(screen.contains("[Process exited with code 3.]"), "{screen}");
        assert_eq!(frame["rows"], 6);
        assert_eq!(frame["grid"].as_array().unwrap().len(), 6);

        let before = frame["revision"].as_u64().unwrap();
        // A running shell is never replaced.
        let running = Terminal::spawn(root.path(), "/bin/sh", 6, 40).unwrap();
        engine
            .terminals
            .insert("running".into(), ("thread".into(), running));
        assert!(
            engine
                .restart_terminal(&json!({"terminalId":"running"}), "/bin/sh")
                .is_err()
        );
        engine
            .restart_terminal(&json!({"terminalId":"failed"}), "/bin/sh")
            .unwrap();
        let entry = wait(&mut engine, "failed", |entry| entry["exited"] == false);
        assert_eq!(entry["number"], 4);
        assert_eq!(entry["name"], "Terminal 4");
        let retired = engine.poll_terminals_shutdown();
        assert_eq!(retired.panes.len(), 1);
        assert_eq!(retired.panes[0].terminal_id, "failed");
        assert_eq!(retired.panes[0].thread_id, "thread");
        assert!(!retired.requested);
        assert_eq!(retired.live_count, 2);
        let frame = engine
            .read_terminal_viewport("failed", &Palette::default())
            .unwrap();
        assert!(frame["revision"].as_u64().unwrap() > before);
        // The old output stays above the new shell.
        assert!(frame["lines"].as_array().unwrap().iter().any(|line| {
            line.as_str()
                .unwrap()
                .contains("[Process exited with code 3.]")
        }));
    }
}
