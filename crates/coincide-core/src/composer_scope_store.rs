//! Runtime-only selection epochs for nonmutating account observation. Draft,
//! transcript and unrelated writes cannot invalidate a selected account probe.
use super::*;
use std::collections::HashMap;

#[derive(Default)]
pub(super) struct Scopes {
    entries: HashMap<String, Scope>,
}
struct Scope {
    epoch: u64,
    thread: Value,
    project_id: Option<String>,
    project: Value,
}
const FIELDS: [&str; 8] = [
    "id",
    "selection",
    "accessMode",
    "interactionMode",
    "projectID",
    "worktreePath",
    "botID",
    "rustBotContext",
];
pub(crate) fn same_scope(left: &Value, right: &Value) -> bool {
    FIELDS
        .iter()
        .all(|field| left.get(*field) == right.get(*field))
}
fn thread_scope(thread: &Value) -> Value {
    json!(
        FIELDS
            .iter()
            .map(|field| json!([thread.get(*field).is_some(), thread[*field]]))
            .collect::<Vec<_>>()
    )
}
fn project_scope(projects: &Value, id: Option<&str>) -> Value {
    json!(
        projects
            .as_array()
            .into_iter()
            .flatten()
            .filter(|project| project["id"]
                .as_str()
                .zip(id)
                .is_some_and(|(left, right)| left.eq_ignore_ascii_case(right)))
            .map(|project| json!([project.get("path").is_some(), project["path"]]))
            .collect::<Vec<_>>()
    )
}
impl Store {
    pub(crate) fn capture_selection_scope(&mut self, id: &str) -> Result<u64> {
        let thread = self.thread(id)?;
        let actual = thread["id"]
            .as_str()
            .context("Missing selection scope identity")?
            .to_owned();
        let projection = thread_scope(&thread);
        let project_id = thread["projectID"].as_str().map(str::to_owned);
        let project = project_scope(&self.projects()?, project_id.as_deref());
        if !self.selection_scopes.entries.contains_key(&actual)
            && self.selection_scopes.entries.len() >= 256
        {
            self.selection_scopes.entries.clear();
        }
        let scope = self
            .selection_scopes
            .entries
            .entry(actual)
            .or_insert_with(|| Scope {
                epoch: 0,
                thread: projection.clone(),
                project_id: project_id.clone(),
                project: project.clone(),
            });
        if scope.thread != projection || scope.project != project {
            scope.epoch = scope.epoch.wrapping_add(1);
            scope.thread = projection;
            scope.project_id = project_id;
            scope.project = project;
        }
        Ok(scope.epoch)
    }
    pub(crate) fn selection_scope_generation(&self, id: &str) -> Option<u64> {
        self.selection_scopes
            .entries
            .get(id)
            .map(|scope| scope.epoch)
    }
    pub(super) fn note_selection_scope(&mut self, thread: &Value) {
        let Some(id) = thread["id"].as_str() else {
            return;
        };
        if let Some(scope) = self.selection_scopes.entries.get_mut(id) {
            let projection = thread_scope(thread);
            if projection != scope.thread {
                scope.epoch = scope.epoch.wrapping_add(1);
                scope.thread = projection;
                let project_id = thread["projectID"].as_str().map(str::to_owned);
                if project_id != scope.project_id {
                    scope.project_id = project_id;
                    scope.project = Value::Null;
                }
            }
        }
    }
    pub(super) fn note_project_scopes(&mut self, projects: &Value) {
        for scope in self.selection_scopes.entries.values_mut() {
            let project = project_scope(projects, scope.project_id.as_deref());
            if project != scope.project {
                scope.epoch = scope.epoch.wrapping_add(1);
                scope.project = project;
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn draft_unrelated_and_project_name_changes_do_not_advance_selection_epoch_but_path_aba_does() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("state.sqlite")).unwrap();
        let project = store.create_project(dir.path(), Some("One")).unwrap();
        let thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
        let id = thread["id"].as_str().unwrap();
        let epoch = store.capture_selection_scope(id).unwrap();
        store.patch_thread(id, &json!({"draft":"typed"})).unwrap();
        store
            .patch_project(project["id"].as_str().unwrap(), &json!({"name":"Renamed"}))
            .unwrap();
        let other = store.new_thread(project["id"].as_str().unwrap()).unwrap();
        store
            .patch_thread(other["id"].as_str().unwrap(), &json!({"draft":"unrelated"}))
            .unwrap();
        assert_eq!(store.selection_scope_generation(id), Some(epoch));
        // Storage path patches remain intentionally unsupported. Orchestrated
        // relocation/full projects writes still fence every bound thread.
        assert!(
            store
                .patch_project(project["id"].as_str().unwrap(), &json!({"path":dir.path()}))
                .is_err()
        );
        let original = store.projects().unwrap();
        let mut changed = original.clone();
        let row = changed
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|row| row["id"] == project["id"])
            .unwrap();
        row["path"] = json!(dir.path().join("other"));
        store.save_document("projects.json", &changed).unwrap();
        store.save_document("projects.json", &original).unwrap();
        assert_ne!(store.selection_scope_generation(id), Some(epoch));
        let epoch = store.capture_selection_scope(id).unwrap();
        let mut changed = store.thread(id).unwrap();
        changed["selection"]["modelID"] = json!("changed");
        store.save(&changed).unwrap();
        store.save(&thread).unwrap();
        assert_ne!(store.selection_scope_generation(id), Some(epoch));
    }
}
