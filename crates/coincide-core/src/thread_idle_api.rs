//! Native-only lifecycle parity with Swift ThreadActions and ThreadSnooze.
//! Generic threads.create remains explicitly fresh for CLI/API consumers.
use super::*;
pub struct NativeNewThread {
    owner: Uuid,
    row: crate::store::NewThreadRow,
}
fn no_draft(thread: &Value) -> bool {
    thread
        .get("draft")
        .is_none_or(|v| v.is_null() || v.as_str() == Some(""))
        && ["draftContext", "rustDraftImages"].iter().all(|key| {
            thread
                .get(*key)
                .is_none_or(|v| v.is_null() || v.as_array().is_some_and(Vec::is_empty))
        })
}
fn untouched(
    thread: &Value,
    fresh: &Value,
    ui: &Value,
    now: chrono::DateTime<chrono::Utc>,
) -> bool {
    let id = text(thread, "id");
    let settled = ui["settledThreads"]
        .as_object()
        .and_then(|rows| rows.iter().find(|(key, _)| same_uuid(key, &id)))
        .and_then(|(_, date)| crate::scheduling::parse_date(date).ok())
        .is_some_and(|date| {
            crate::scheduling::parse_date(&thread["updatedAt"])
                .map_or(true, |updated| date >= updated)
        });
    thread["items"].as_array().is_some_and(Vec::is_empty)
        && no_draft(thread)
        && thread["isArchived"] != true
        && !settled
        && thread["botID"].is_null()
        && (thread["snoozedUntil"].is_null()
            || crate::scheduling::parse_date(&thread["snoozedUntil"]).is_ok_and(|date| date <= now))
        && thread["worktreePath"] == fresh["worktreePath"]
        && ["selection", "accessMode", "interactionMode"]
            .iter()
            .all(|key| thread[*key] == fresh[*key])
}
fn same_uuid(left: &str, right: &str) -> bool {
    match (Uuid::parse_str(left), Uuid::parse_str(right)) {
        (Ok(a), Ok(b)) => a == b,
        _ => left == right,
    }
}
fn same_project(left: &str, right: &str) -> bool {
    let projectless = |id: &str| id.is_empty() || Uuid::parse_str(id).is_ok_and(|id| id.is_nil());
    (projectless(left) && projectless(right)) || same_uuid(left, right)
}
impl Engine {
    pub fn prepare_native_new_thread(&mut self, params: &Value) -> Result<NativeNewThread> {
        self.require_admissions()?;
        ensure!(
            params.as_object().is_some_and(|fields| fields
                .keys()
                .all(|key| matches!(key.as_str(), "projectId" | "cwd" | "branch"))),
            "Native New Thread accepts only a project, folder and branch"
        );
        // Swift's "New Thread on <branch>" records the source thread's branch;
        // it never checks anything out.
        let branch = params
            .get("branch")
            .filter(|value| !value.is_null())
            .map(|value| {
                value
                    .as_str()
                    .filter(|branch| {
                        !branch.trim().is_empty()
                            && branch.len() <= 512
                            && !branch.chars().any(char::is_control)
                    })
                    .map(str::to_owned)
                    .context("Branch must be nonblank text without control characters")
            })
            .transpose()?;
        let mut ordinary = params.clone();
        if let Some(fields) = ordinary.as_object_mut() {
            fields.remove("branch");
        }
        let changes = self.store.mutation_serial()?;
        let external = self.store.sidebar_external_version()?;
        let mut fresh = self.prepare_ordinary_thread(&ordinary)?;
        if let Some(branch) = &branch {
            fresh["branch"] = json!(branch);
        }
        let project = text(&fresh, "projectID");
        ensure!(
            !project.eq_ignore_ascii_case(crate::bot_runtime::BOTS_PROJECT_ID),
            "Choose a saved bot for a bot conversation"
        );
        if !same_project(&project, "") {
            ensure!(
                self.store
                    .projects()?
                    .as_array()
                    .is_some_and(|projects| projects.iter().any(|item| item["id"]
                        .as_str()
                        .is_some_and(|id| same_uuid(id, &project))
                        && item["isBots"] != true)),
                "The project no longer exists"
            );
        }
        let ui = self
            .store
            .document("ui-state.json")?
            .unwrap_or_else(|| json!({}));
        ensure!(
            ui.is_object(),
            "Window preferences are malformed; existing chats were retained"
        );
        let now = crate::scheduling::parse_date(&json!(swift_timestamp()))?;
        let mut reusable = None;
        for summary in self.store.summaries("", false)? {
            if !same_project(&summary.project_id, &project) || summary.archived {
                continue;
            }
            if summary.navigation.as_ref().is_some_and(|meta| {
                meta.item_count.is_some_and(|count| count > 0) || meta.has_draft == Some(true)
            }) {
                continue;
            }
            if self
                .runs
                .keys()
                .chain(self.unsaved_threads.keys())
                .any(|id| same_uuid(id, &summary.id))
                || self.store.is_imported(&summary.id)?
            {
                continue;
            }
            if self
                .workspace_pending
                .values()
                .any(|(id, _)| same_uuid(id, &summary.id))
            {
                continue;
            }
            let Some(thread) = self.store.native_idle_candidate(&summary.id)? else {
                continue;
            };
            // A thread reused for a branch must already be on that branch.
            if untouched(&thread, &fresh, &ui, now)
                && (branch.is_none() || thread["branch"] == fresh["branch"])
            {
                reusable = Some(thread);
                break;
            }
        }
        let row = self
            .store
            .prepare_native_new_row(reusable.as_ref(), fresh, changes, external)?;
        Ok(NativeNewThread {
            owner: self.thread_bulk_owner,
            row,
        })
    }
    pub fn apply_native_new_thread(&mut self, intent: NativeNewThread) -> Result<Value> {
        self.require_admissions()?;
        ensure!(
            intent.owner == self.thread_bulk_owner,
            "New Thread admission belongs to another app owner"
        );
        let id = intent.row.id();
        ensure!(
            !self
                .runs
                .keys()
                .chain(self.unsaved_threads.keys())
                .any(|key| same_uuid(key, id))
                && !self
                    .workspace_pending
                    .values()
                    .any(|(key, _)| same_uuid(key, id)),
            "New Thread candidate became busy; retry"
        );
        let (thread, created) = self.store.apply_native_new_row(intent.row)?;
        if created {
            self.revision += 1;
        }
        Ok(thread)
    }
    pub fn native_wake_due_snoozes(&mut self) -> Result<usize> {
        self.native_wake_due_snoozes_at(swift_timestamp())
    }
    fn native_wake_due_snoozes_at(&mut self, now: f64) -> Result<usize> {
        self.require_admissions()?;
        let blocked = self
            .unsaved_threads
            .keys()
            .map(|id| id.to_ascii_lowercase())
            .collect();
        let count = self.store.wake_due_snoozes(now, &blocked)?;
        if count > 0 {
            self.revision += 1;
        }
        Ok(count)
    }
}

#[cfg(test)]
#[path = "thread_idle_tests.rs"]
mod tests;
