//! Explicit project targets, expiring one-shot previews and runtime admission.
use super::*;
use crate::store::{PreparedProject, ProjectAction};
pub(super) const METHODS: &[&str] = &[
    "projects.prepare",
    "projects.rename",
    "projects.relocate",
    "projects.remove",
    "projects.restore",
    "projects.recovery",
    "projects.latest-thread",
];
#[derive(Default)]
pub(super) struct State {
    current: Option<(String, Instant, PreparedProject)>,
}
impl Engine {
    fn project_change_admitted(&self, p: &PreparedProject) -> Result<()> {
        ensure!(!self.shutdown, "Application is closing");
        if p.action == ProjectAction::Rename {
            return Ok(());
        }
        ensure!(
            self.workspace_pending.is_empty()
                && self.workspace_mutations.is_empty()
                && self.steering_operations.is_empty(),
            "Wait for pending workspace and provider changes before managing this project"
        );
        for (id, raw) in &p.threads {
            ensure!(
                !self.runs.contains_key(id)
                    && !self.unsaved_threads.contains_key(id)
                    && !self.pending_usage.contains_key(id),
                "A project conversation is running or awaiting persistence"
            );
            ensure!(
                !self.terminals.values().any(|(thread, _)| thread == id),
                "Close this project's terminal panes before changing its folder or removing it"
            );
            ensure!(
                !self.attachment_operations.contains(id),
                "Wait for this project's attachment import to finish"
            );
            let thread: Value = serde_json::from_str(raw)?;
            ensure!(
                thread["rustMessageQueue"]
                    .as_array()
                    .is_none_or(Vec::is_empty),
                "Pause and clear queued messages before changing this project"
            );
        }
        if p.action != ProjectAction::Restore {
            let document = self
                .store
                .document("scheduled-tasks.json")?
                .unwrap_or(json!({"tasks":[]}));
            let tasks = document["tasks"]
                .as_array()
                .context("Scheduled tasks are malformed; no project change was admitted")?;
            ensure!(
                !tasks
                    .iter()
                    .any(|task| task["projectID"] == p.project["id"] && task["isPaused"] != true),
                "Pause this project's schedules before changing its folder or removing it"
            );
        }
        Ok(())
    }
    pub(super) fn project_command(&mut self, method: &str, p: &Value) -> Result<Value> {
        self.require_admissions()?;
        if method == "projects.latest-thread" {
            #[derive(serde::Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct Request {
                project_id: String,
            }
            let request: Request = serde_json::from_value(p.clone())?;
            return Ok(json!({"threadId":self.store.latest_project_thread(&request.project_id)?}));
        }
        if method == "projects.recovery" {
            ensure!(
                p.as_object().is_some_and(serde_json::Map::is_empty),
                "Recovery listing takes no parameters"
            );
            return self.store.project_recoveries();
        }
        if method == "projects.prepare" {
            self.project_management.current = None;
            #[derive(serde::Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct Request {
                project_id: String,
                action: ProjectAction,
            }
            let request: Request = serde_json::from_value(p.clone())?;
            let prepared = self
                .store
                .prepare_project_action(&request.project_id, request.action)?;
            self.project_change_admitted(&prepared)?;
            let ticket = Uuid::new_v4().to_string();
            let preview = json!({"ticket":ticket,"targetId":request.project_id,"projectId":prepared.project["id"],"name":prepared.project["name"],"path":prepared.project["path"],"threadCount":prepared.threads.len(),"action":request.action,"recoverableRemoval":true,"filesUnchanged":true});
            self.project_management.current = Some((ticket, Instant::now(), prepared));
            return Ok(preview);
        }
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Request {
            project_id: String,
            ticket: String,
            #[serde(default)]
            name: Option<String>,
            #[serde(default)]
            path: Option<String>,
            #[serde(default)]
            confirmed: bool,
            #[serde(default)]
            confirmed_thread_count: Option<usize>,
        }
        let request: Request = serde_json::from_value(p.clone())?;
        let (ticket, started, prepared) = self
            .project_management
            .current
            .take()
            .context("Project review expired; review the target again")?;
        ensure!(
            ticket == request.ticket
                && prepared.target == request.project_id
                && started.elapsed() < Duration::from_secs(600),
            "Project review changed or expired; review the target again"
        );
        let expected = match method {
            "projects.rename" => ProjectAction::Rename,
            "projects.relocate" => ProjectAction::Relocate,
            "projects.remove" => ProjectAction::Remove,
            "projects.restore" => ProjectAction::Restore,
            _ => bail!("Unknown project operation"),
        };
        ensure!(
            prepared.action == expected,
            "Project operation differs from its review"
        );
        self.project_change_admitted(&prepared)?;
        let value = match expected {
            ProjectAction::Rename => {
                ensure!(request.path.is_none(), "Rename cannot change a path");
                request.name.as_deref()
            }
            ProjectAction::Relocate => {
                ensure!(
                    request.name.is_none(),
                    "Relocation derives only folder-default names"
                );
                request.path.as_deref()
            }
            ProjectAction::Remove | ProjectAction::Restore => {
                ensure!(
                    request.name.is_none()
                        && request.path.is_none()
                        && request.confirmed
                        && request.confirmed_thread_count == Some(prepared.threads.len()),
                    "Confirm this exact project and conversation count"
                );
                None
            }
        };
        if expected == ProjectAction::Remove {
            // Journal revocation can fail: finish it before committing SQL.
            // Recovering the archived documents never recovers native grants.
            let ids = prepared
                .threads
                .iter()
                .map(|(id, _)| id.clone())
                .collect::<Vec<_>>();
            self.named_resume.invalidate_threads(&ids, &self.store)?;
            if self
                .active_thread
                .as_ref()
                .is_some_and(|id| ids.contains(id))
            {
                // Clear while the transcript still exists, before removal.
                // A later SQL failure may lose this optional selection only.
                self.set_active_thread(None)?;
                self.requested_open = None;
            }
        }
        let outcome = self.store.apply_project_action(&prepared, value)?;
        self.revision += 1;
        Ok(outcome)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Engine, String, String) {
        let dir = tempfile::tempdir().unwrap();
        let mut e = Engine::fixture(Store::open(&dir.path().join("data/state.sqlite")).unwrap());
        let p = e.store.create_project(dir.path(), None).unwrap();
        let id = text(&p, "id");
        let thread = e.store.new_thread(&id).unwrap();
        (dir, e, id, text(&thread, "id"))
    }
    #[test]
    fn preview_is_one_shot_target_bound_and_removal_requires_exact_count() {
        let (_dir, mut e, id, thread) = fixture();
        let preview = e
            .execute(
                "projects.prepare",
                &json!({"projectId":id,"action":"remove"}),
            )
            .unwrap();
        assert_eq!(preview["threadCount"], 1);
        assert!(e.execute("projects.remove",&json!({"projectId":id,"ticket":preview["ticket"],"confirmed":true,"confirmedThreadCount":0})).is_err());
        assert!(e.store.thread(&thread).is_ok());
        assert!(e.execute("projects.remove",&json!({"projectId":id,"ticket":preview["ticket"],"confirmed":true,"confirmedThreadCount":1})).is_err());
        let preview = e
            .execute(
                "projects.prepare",
                &json!({"projectId":id,"action":"remove"}),
            )
            .unwrap();
        let result=e.execute("projects.remove",&json!({"projectId":id,"ticket":preview["ticket"],"confirmed":true,"confirmedThreadCount":1})).unwrap();
        assert!(e.store.thread(&thread).is_err());
        assert!(result["archiveId"].is_string());
    }
    #[test]
    fn queued_or_unsaved_work_rejects_admission_and_commit_rechecks() {
        let (_dir, mut e, id, thread) = fixture();
        let preview = e
            .execute(
                "projects.prepare",
                &json!({"projectId":id,"action":"remove"}),
            )
            .unwrap();
        e.unsaved_threads
            .insert(thread.clone(), e.store.thread(&thread).unwrap());
        assert!(e.execute("projects.remove",&json!({"projectId":id,"ticket":preview["ticket"],"confirmed":true,"confirmedThreadCount":1})).is_err());
        assert!(e.store.thread(&thread).is_ok());
        e.unsaved_threads.clear();
        let mut value = e.store.thread(&thread).unwrap();
        value["rustMessageQueue"] = json!([{"id":"pending","text":"never replay"}]);
        e.store.save(&value).unwrap();
        assert!(
            e.execute(
                "projects.prepare",
                &json!({"projectId":id,"action":"relocate"})
            )
            .is_err()
        );
        assert_eq!(e.store.thread(&thread).unwrap(), value);
    }
    #[test]
    fn active_selection_revokes_on_remove_and_explicit_restore_is_available() {
        let (_dir, mut e, id, thread) = fixture();
        e.set_active_thread(Some(thread)).unwrap();
        let preview = e
            .execute(
                "projects.prepare",
                &json!({"projectId":id,"action":"remove"}),
            )
            .unwrap();
        let removed=e.execute("projects.remove",&json!({"projectId":id,"ticket":preview["ticket"],"confirmed":true,"confirmedThreadCount":1})).unwrap();
        assert!(e.active_thread().is_none());
        let archive = removed["archiveId"].clone();
        let preview = e
            .execute(
                "projects.prepare",
                &json!({"projectId":archive,"action":"restore"}),
            )
            .unwrap();
        e.execute("projects.restore",&json!({"projectId":archive,"ticket":preview["ticket"],"confirmed":true,"confirmedThreadCount":1})).unwrap();
        assert_eq!(e.store.projects().unwrap().as_array().unwrap().len(), 1);
    }
    #[cfg(any(unix, windows))]
    #[test]
    fn project_remove_consumes_all_private_account_slots_before_restore() {
        let (dir, mut e, project, id) = fixture();
        let root = e.store.data_directory().unwrap();
        let cwd = dir.path().canonicalize().unwrap();
        let accounts = [Uuid::new_v4().to_string(), Uuid::new_v4().to_string()];
        let mut profiles = Vec::new();
        for (index, account) in accounts.iter().enumerate() {
            crate::codex_login_profiles::managed_home(&root, account, true).unwrap();
            let profile = crate::codex_login_profiles::LaunchContext::capture(
                &root,
                account,
                &std::env::current_exe().unwrap(),
            )
            .unwrap();
            let mut thread = e.store.thread(&id).unwrap();
            thread["selection"] =
                json!({"provider":"codex","modelID":"default","accountID":account});
            thread["items"] = json!([{"kind":"user","text":"Synthetic owned prefix"}]);
            let native = format!("private-account-{index}");
            thread["sessions"] = json!({"codex":{"accountID":account,"sessionID":native}});
            e.store.save(&thread).unwrap();
            let policy = crate::composer_policy::Policy::parse_named(
                &thread,
                crate::composer_policy::Origin::Ordinary,
                None,
            )
            .unwrap();
            let authority = e
                .named_resume
                .prepare(&thread, profile.clone(), &cwd, policy)
                .unwrap();
            let ack = authority
                .acknowledge(&json!({"thread":{"id":native},"model":"actual-model"}))
                .unwrap();
            let worker = agent::WorkerCompletion::observe(std::thread::spawn(|| {}));
            let deadline = Instant::now() + Duration::from_secs(10);
            while worker.status() == agent::WorkerThreadStatus::Running {
                assert!(Instant::now() < deadline);
                std::thread::yield_now();
            }
            e.named_resume.persisted(ack, &thread, worker);
            e.named_resume.poll();
            profiles.push(profile);
        }
        e.set_active_thread(Some(id.clone())).unwrap();
        let before = e.store.thread(&id).unwrap();
        let preview = e
            .execute(
                "projects.prepare",
                &json!({"projectId":project,"action":"remove"}),
            )
            .unwrap();
        let removed=e.execute("projects.remove",&json!({"projectId":project,"ticket":preview["ticket"],"confirmed":true,"confirmedThreadCount":1})).unwrap();
        assert!(e.active_thread().is_none());
        assert!(e.store.thread(&id).is_err());
        let archive = &removed["archiveId"];
        let preview = e
            .execute(
                "projects.prepare",
                &json!({"projectId":archive,"action":"restore"}),
            )
            .unwrap();
        e.execute("projects.restore",&json!({"projectId":archive,"ticket":preview["ticket"],"confirmed":true,"confirmedThreadCount":1})).unwrap();
        assert_eq!(
            e.store.thread(&id).unwrap(),
            before,
            "Recovery preserves descriptive content exactly"
        );
        // A new registry owner must not recover either old private ticket from
        // disk, even with exact old metadata and fresh authenticated admission.
        e.named_resume = crate::named_profile_resume::Registry::default();
        let mut reopened = crate::named_profile_resume::Registry::for_store(&e.store);
        let mut catalog = crate::model_catalog::ModelCatalog::default();
        for (index, profile) in profiles.into_iter().enumerate() {
            let mut thread = before.clone();
            thread["selection"]["accountID"] = json!(profile.account());
            thread["sessions"] = json!({"codex":{"accountID":profile.account(),"sessionID":format!("private-account-{index}")}});
            let binding =
                crate::model_catalog::NamedBinding::capture(profile.clone(), &id, &cwd).unwrap();
            catalog.fixture_resume_job(binding.clone(), &format!("fresh-{index}"));
            let admission = catalog.named_resume_admission(&thread, &binding).unwrap();
            let policy = crate::composer_policy::Policy::parse_named(
                &thread,
                crate::composer_policy::Origin::Ordinary,
                None,
            )
            .unwrap();
            let fresh = reopened
                .prepare_admitted(&thread, profile, &cwd, policy, Some(admission))
                .unwrap();
            assert!(fresh.session().is_none());
            assert_eq!(fresh.seen(), 0);
        }
    }
    #[cfg(unix)]
    #[test]
    fn project_removal_journal_failure_happens_before_sql_and_preserves_rows() {
        use std::os::unix::fs::PermissionsExt;
        let (_dir, mut e, project, id) = fixture();
        e.set_active_thread(Some(id.clone())).unwrap();
        let before = e.store.thread(&id).unwrap();
        let preview = e
            .execute(
                "projects.prepare",
                &json!({"projectId":project,"action":"remove"}),
            )
            .unwrap();
        let journal = e
            .store
            .data_directory()
            .unwrap()
            .join(".state.sqlite.native-resume-v1/receipts.sqlite");
        std::fs::set_permissions(&journal, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(e.execute("projects.remove",&json!({"projectId":project,"ticket":preview["ticket"],"confirmed":true,"confirmedThreadCount":1})).is_err());
        assert_eq!(e.store.thread(&id).unwrap(), before);
        assert_eq!(e.store.projects().unwrap().as_array().unwrap().len(), 1);
        assert_eq!(e.active_thread(), Some(id.as_str()));
        std::fs::set_permissions(&journal, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    #[test]
    fn failed_new_review_expires_previous_target_and_expired_tickets_cannot_commit() {
        let (_dir, mut e, id, thread) = fixture();
        let preview = e
            .execute(
                "projects.prepare",
                &json!({"projectId":id,"action":"remove"}),
            )
            .unwrap();
        assert!(
            e.execute(
                "projects.prepare",
                &json!({"projectId":Uuid::new_v4().to_string(),"action":"remove"})
            )
            .is_err()
        );
        assert!(e.execute("projects.remove", &json!({"projectId":id,"ticket":preview["ticket"],"confirmed":true,"confirmedThreadCount":1})).is_err());
        let preview = e
            .execute(
                "projects.prepare",
                &json!({"projectId":id,"action":"remove"}),
            )
            .unwrap();
        e.project_management.current.as_mut().unwrap().1 =
            Instant::now() - Duration::from_secs(601);
        assert!(e.execute("projects.remove", &json!({"projectId":id,"ticket":preview["ticket"],"confirmed":true,"confirmedThreadCount":1})).is_err());
        assert!(e.store.thread(&thread).is_ok());
    }
    #[test]
    fn active_schedule_refuses_removal_but_paused_schedule_remains_exact_in_recovery_flow() {
        let (_dir, mut e, id, thread) = fixture();
        let schedule = json!({"tasks":[{"id":"future-schedule","projectID":id,"isPaused":false,"unknown":{"preserve":true}}],"opaque":7});
        e.store
            .save_document("scheduled-tasks.json", &schedule)
            .unwrap();
        assert!(
            e.execute(
                "projects.prepare",
                &json!({"projectId":id,"action":"remove"})
            )
            .is_err()
        );
        let mut paused = schedule;
        paused["tasks"][0]["isPaused"] = json!(true);
        e.store
            .save_document("scheduled-tasks.json", &paused)
            .unwrap();
        let preview = e
            .execute(
                "projects.prepare",
                &json!({"projectId":id,"action":"remove"}),
            )
            .unwrap();
        let removed = e.execute("projects.remove", &json!({"projectId":id,"ticket":preview["ticket"],"confirmed":true,"confirmedThreadCount":1})).unwrap();
        assert!(e.store.thread(&thread).is_err());
        assert_eq!(
            e.store.document("scheduled-tasks.json").unwrap(),
            Some(paused)
        );
        assert!(removed["archiveId"].is_string());
    }
}
