//! Project scripts on the Engine: native edits of one reviewed project, and
//! the script a new terminal of a thread types (`terminal.create`'s `scriptId`).
use super::*;
use crate::{project_scripts, store::ScriptEdit};

/// What a new terminal runs for one script of its thread's project.
pub(super) struct ScriptLaunch {
    pub project: Uuid,
    pub script: Uuid,
    pub command: String,
    pub environment: Vec<(String, String)>,
}

impl Engine {
    /// Applies one edit when the project still equals the reviewed copy, and
    /// returns the saved project.
    pub fn native_edit_project_scripts(
        &mut self,
        expected: &Value,
        edit: &ScriptEdit,
    ) -> Result<Value> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let project = self
            .store
            .save_project_scripts_if_unchanged(expected, edit)?;
        self.revision += 1;
        Ok(project)
    }

    /// `terminal.create`: a shell in the thread's worktree or project folder.
    /// With `scriptId` it also types that project script, with its locations
    /// in the environment, and remembers it as the project's last-run script.
    pub(super) fn create_terminal(&mut self, p: &Value, shell: &str) -> Result<Value> {
        self.create_project_terminal(p, shell, true)
    }

    fn create_project_terminal(&mut self, p: &Value, shell: &str, remember: bool) -> Result<Value> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        ensure!(self.terminals.len() < 32, "Too many terminal panes");
        let thread = required(p, "threadId")?;
        let v = self.store.thread(thread)?;
        let launch = match p.get("scriptId") {
            None | Some(Value::Null) => None,
            Some(id) => Some(self.project_script_launch(&v, id)?),
        };
        let environment = launch
            .as_ref()
            .map_or(&[][..], |launch| &launch.environment);
        let mut terminal = if launch.is_some() {
            self.spawn_thread_terminal_with_environment(thread, &v, shell, environment)?
        } else {
            self.spawn_thread_terminal(thread, &v, shell)?
        };
        let id = Uuid::new_v4().to_string();
        if let Some(launch) = &launch {
            // Swift TerminalSession.run: the command and Return, queued until
            // the shell reads its terminal. A failed first write must retire
            // the complete live owner, never detach its I/O workers via Drop.
            if let Err(error) = terminal.write(&format!("{}\r", launch.command)) {
                match terminal.request_shutdown() {
                    Ok(pending) => self.retain_terminal_owner(id, thread.into(), pending),
                    Err(retire_error) => {
                        self.terminals.insert(id, (thread.into(), terminal));
                        self.revision += 1;
                        return Err(error.context(format!(
                            "Initial script input failed; terminal owner retained after cleanup transfer failed: {retire_error}"
                        )));
                    }
                }
                return Err(error);
            }
        }
        self.terminals.insert(id.clone(), (thread.into(), terminal));
        self.revision += 1;
        if let Some(launch) = launch.as_ref().filter(|_| remember) {
            // The script already runs; a hint that could not be saved only
            // leaves the toolbar's one-click script as it was.
            let _ = self
                .store
                .remember_last_project_script(launch.project, launch.script);
        }
        Ok(json!({"terminalId":id}))
    }

    /// Swift ProjectScripts.runSetupScripts: only after a newly created
    /// worktree was admitted to this thread. Each opted-in script gets its own
    /// numbered pane; automatic setup never changes the one-click last script.
    pub(super) fn run_worktree_setup_scripts(
        &mut self,
        thread: &str,
        expected_worktree: &str,
        shell: &str,
    ) -> Result<Value> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is closing");
        let document = self.store.thread(thread)?;
        ensure!(
            document["worktreePath"].as_str() == Some(expected_worktree),
            "Setup worktree changed before launch"
        );
        let project = self
            .store
            .project_scripts_target(required(&document, "projectID")?)?;
        let scripts = project_scripts::scripts(&project)
            .into_iter()
            .filter(|script| script.run_on_worktree_create)
            .collect::<Vec<_>>();
        let mut terminals = Vec::new();
        let mut errors = Vec::new();
        for script in scripts {
            match self.create_project_terminal(
                &json!({"threadId":thread,"scriptId":script.id}),
                shell,
                false,
            ) {
                Ok(created) => terminals.push(created["terminalId"].clone()),
                Err(error) => errors.push(json!({"name":script.name,"error":error.to_string()})),
            }
        }
        Ok(json!({"terminalIds":terminals,"errors":errors}))
    }

    /// Finds `script_id` in the thread's own project. The terminal starts in
    /// the thread's worktree or project folder like any other.
    pub(super) fn project_script_launch(
        &self,
        thread: &Value,
        script_id: &Value,
    ) -> Result<ScriptLaunch> {
        let script = script_id
            .as_str()
            .and_then(|id| Uuid::parse_str(id).ok())
            .context("Script identity must be a UUID")?;
        let project_id = thread["projectID"]
            .as_str()
            .context("This conversation has no project scripts")?;
        let project = self.store.project_scripts_target(project_id)?;
        let found = project_scripts::scripts(&project)
            .into_iter()
            .find(|candidate| candidate.uuid() == script)
            .context("Script no longer exists; reopen the menu")?;
        let path = project["path"]
            .as_str()
            .filter(|path| !path.is_empty())
            .context("Project has no folder")?;
        Ok(ScriptLaunch {
            project: Uuid::parse_str(project_id)?,
            script,
            environment: project_scripts::environment(path, thread["worktreePath"].as_str()),
            command: found.command,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (tempfile::TempDir, Engine, Value, String) {
        let root = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&root.path().join("state.sqlite")).unwrap());
        let project = engine
            .store
            .create_project(root.path(), Some("Synthetic project"))
            .unwrap();
        let project = engine
            .native_edit_project_scripts(
                &project,
                &ScriptEdit::Save {
                    id: None,
                    draft: project_scripts::ScriptDraft {
                        name: "Marker".into(),
                        command: "true".into(),
                        ..Default::default()
                    },
                },
            )
            .unwrap();
        let thread = engine.dispatch(
            json!({"method":"threads.create","params":{"projectId":text(&project,"id")}}),
        )["result"]
            .clone();
        (root, engine, project, text(&thread, "id"))
    }

    #[test]
    fn launch_resolves_only_the_threads_own_project_script_and_its_locations() {
        let (root, engine, project, thread) = fixture();
        let script = &project_scripts::scripts(&project)[0];
        let mut thread = engine.store.thread(&thread).unwrap();
        let launch = engine
            .project_script_launch(&thread, &json!(script.id.to_lowercase()))
            .unwrap();
        assert_eq!(launch.command, "true");
        assert_eq!(launch.script, script.uuid());
        let folder = root.path().canonicalize().unwrap();
        assert_eq!(
            launch.environment,
            project_scripts::environment(folder.to_str().unwrap(), None)
        );
        thread["worktreePath"] = json!("/synthetic/worktree");
        let launch = engine
            .project_script_launch(&thread, &json!(script.id))
            .unwrap();
        assert!(launch.environment.contains(&(
            "COINCIDE_WORKTREE_PATH".into(),
            "/synthetic/worktree".into()
        )));
        for id in [json!(Uuid::new_v4().to_string()), json!(5), json!("nope")] {
            assert!(engine.project_script_launch(&thread, &id).is_err());
        }
        thread["projectID"] = json!(crate::bot_runtime::BOTS_PROJECT_ID);
        assert!(
            engine
                .project_script_launch(&thread, &json!(script.id))
                .is_err()
        );
    }

    #[cfg(unix)]
    #[test]
    fn failed_initial_script_write_retires_live_terminal_without_remembering_a_run() {
        let (_root, mut engine, project, thread) = fixture();
        let script = project_scripts::scripts(&project)[0].id.clone();
        // Imported project documents are read leniently. This oversized legacy
        // command deterministically fails Terminal::write before any input is
        // delivered, after a private shell has actually been created.
        let mut projects = engine.store.projects().unwrap();
        let project = projects
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|candidate| candidate["id"] == project["id"])
            .unwrap();
        project["scripts"][0]["command"] = json!("x".repeat(32 * 1024 + 1));
        engine
            .store
            .save_document("projects.json", &projects)
            .unwrap();
        let before = engine.store.document("ui-state.json").unwrap();
        let error = engine
            .create_terminal(&json!({"threadId":thread,"scriptId":script}), "/bin/sh")
            .unwrap_err();
        assert!(error.to_string().contains("Terminal input exceeds 32 KiB"));
        assert!(engine.terminals.is_empty());
        assert_eq!(engine.store.document("ui-state.json").unwrap(), before);
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let retired = engine.poll_terminals_shutdown();
            assert_eq!(retired.panes.len(), 1);
            assert_eq!(retired.panes[0].thread_id, thread);
            assert!(!retired.panes[0].terminal_id.is_empty());
            assert!(!retired.requested);
            assert!(!retired.ready());
            if retired.panes[0].status.ready() {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "failed-write terminal owners did not join"
            );
            std::thread::yield_now();
        }
        engine.freeze_admissions();
        engine.request_terminals_shutdown().unwrap();
        assert!(engine.poll_terminals_shutdown().ready());
    }

    #[cfg(unix)]
    #[test]
    fn script_fallback_numbering_and_restart_keep_locations_without_replaying_command() {
        let (root, mut engine, project, thread) = fixture();
        let missing = root.path().join("missing-worktree");
        let count = root.path().join("launch-count");
        let marker = root.path().join("restart-locations");
        let mut saved = engine.store.thread(&thread).unwrap();
        saved["worktreePath"] = json!(missing.display().to_string());
        engine.store.save(&saved).unwrap();
        let original = project_scripts::scripts(&project)[0].clone();
        engine
            .native_edit_project_scripts(
                &project,
                &ScriptEdit::Save {
                    id: Some(original.uuid()),
                    draft: project_scripts::ScriptDraft {
                        name: "Exit fixture".into(),
                        command: format!("printf x >> '{}'; exit 3", count.display()),
                        ..Default::default()
                    },
                },
            )
            .unwrap();
        let created = engine
            .create_terminal(
                &json!({"threadId":thread,"scriptId":original.id}),
                "/bin/sh",
            )
            .unwrap();
        let id = created["terminalId"].as_str().unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !engine.terminals.get(id).unwrap().1.exited() {
            engine.terminal_listing(Some(&thread));
            assert!(
                Instant::now() < deadline,
                "private exiting script did not finish"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        let terminal = &engine.terminals[id].1;
        assert_eq!(terminal.number, 1);
        assert_eq!(
            terminal.directory().canonicalize().unwrap(),
            root.path().canonicalize().unwrap()
        );
        let frame = engine.terminals.get_mut(id).unwrap().1.snapshot().unwrap();
        let screen = frame["lines"]
            .as_array()
            .unwrap()
            .iter()
            .map(|line| line.as_str().unwrap())
            .collect::<Vec<_>>()
            .join("");
        assert!(screen.contains("no longer exists. Starting in"));
        let ui = engine.store.document("ui-state.json").unwrap();
        engine
            .restart_terminal(&json!({"terminalId":id}), "/bin/sh")
            .unwrap();
        assert_eq!(engine.terminals[id].1.number, 1);
        let command = format!(
            r#"printf '%s\n' "$COINCIDE_PROJECT_ROOT" "$T3CODE_PROJECT_ROOT" "$COINCIDE_WORKTREE_PATH" "$T3CODE_WORKTREE_PATH" > '{}'"#,
            marker.display()
        );
        engine
            .terminals
            .get_mut(id)
            .unwrap()
            .1
            .write(&(command + "\r"))
            .unwrap();
        let root_folder = root.path().canonicalize().unwrap().display().to_string();
        let missing = missing.display().to_string();
        let expected = format!("{root_folder}\n{root_folder}\n{missing}\n{missing}\n");
        let deadline = Instant::now() + Duration::from_secs(5);
        while std::fs::read_to_string(&marker).ok().as_deref() != Some(expected.as_str()) {
            assert!(
                Instant::now() < deadline,
                "restarted private shell lost project locations"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(std::fs::read_to_string(count).unwrap(), "x");
        assert_eq!(engine.store.document("ui-state.json").unwrap(), ui);
        assert_eq!(engine.poll_terminals_shutdown().panes.len(), 1);
        engine.freeze_admissions();
        engine.request_terminals_shutdown().unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while !engine.poll_terminals_shutdown().ready() {
            assert!(
                Instant::now() < deadline,
                "private restart owners did not join: {:?}",
                engine.poll_terminals_shutdown()
            );
            std::thread::yield_now();
        }
    }

    #[cfg(unix)]
    #[test]
    fn script_terminal_types_the_command_with_its_locations_and_remembers_it() {
        let (root, mut engine, project, thread) = fixture();
        let marker = root.path().join("script-marker");
        let project = engine
            .native_edit_project_scripts(
                &project,
                &ScriptEdit::Save {
                    id: None,
                    draft: project_scripts::ScriptDraft {
                        name: "Locations".into(),
                        command: format!(
                            "printf '%s|%s|%s' \"$COINCIDE_PROJECT_ROOT\" \"$T3CODE_PROJECT_ROOT\" \"${{COINCIDE_WORKTREE_PATH-none}}\" > '{}'",
                            marker.display()
                        ),
                        ..Default::default()
                    },
                },
            )
            .unwrap();
        let script = project_scripts::scripts(&project)[1].clone();
        let created = engine
            .create_terminal(&json!({"threadId":thread,"scriptId":script.id}), "/bin/sh")
            .unwrap();
        assert!(created["terminalId"].is_string());
        let deadline = Instant::now() + Duration::from_secs(5);
        let folder = root.path().canonicalize().unwrap();
        let expected = format!("{0}|{0}|none", folder.display());
        while std::fs::read_to_string(&marker).ok().as_deref() != Some(expected.as_str()) {
            assert!(Instant::now() < deadline, "script did not run in its shell");
            std::thread::sleep(Duration::from_millis(10));
        }
        let ui = engine.store.document("ui-state.json").unwrap().unwrap();
        assert_eq!(
            project_scripts::last_scripts(&ui)[&Uuid::parse_str(&text(&project, "id")).unwrap()],
            script.uuid()
        );
        let missing = engine.create_terminal(
            &json!({"threadId":thread,"scriptId":Uuid::new_v4().to_string()}),
            "/bin/sh",
        );
        assert!(missing.is_err());
        let plain = engine
            .create_terminal(&json!({"threadId":thread}), "/bin/sh")
            .unwrap();
        assert_ne!(plain["terminalId"], created["terminalId"]);
        let listed =
            engine.dispatch(json!({"method":"terminal.list","params":{"threadId":thread}}));
        assert_eq!(listed["result"].as_array().unwrap().len(), 2);
        let after = engine.store.document("ui-state.json").unwrap().unwrap();
        assert_eq!(after, ui);
    }
}
