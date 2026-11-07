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
        ensure!(self.terminals.len() < 32, "Too many terminal panes");
        let thread = required(p, "threadId")?;
        let v = self.store.thread(thread)?;
        let cwd = self.working_directory(&v)?;
        let launch = match p.get("scriptId") {
            None | Some(Value::Null) => None,
            Some(id) => Some(self.project_script_launch(&v, id)?),
        };
        let environment = launch
            .as_ref()
            .map_or(&[][..], |launch| &launch.environment);
        let mut terminal =
            crate::terminal::Terminal::spawn_with_environment(&cwd, shell, 24, 100, environment)?;
        if let Some(launch) = &launch {
            // Swift TerminalSession.run: the command and Return, queued until
            // the shell reads its terminal.
            terminal.write(&format!("{}\r", launch.command))?;
        }
        let id = Uuid::new_v4().to_string();
        self.terminals.insert(id.clone(), (thread.into(), terminal));
        self.revision += 1;
        if let Some(launch) = &launch {
            // The script already runs; a hint that could not be saved only
            // leaves the toolbar's one-click script as it was.
            let _ = self
                .store
                .remember_last_project_script(launch.project, launch.script);
        }
        Ok(json!({"terminalId":id}))
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
