//! Atomic folder-project edits and recoverable removal. Files are never moved or deleted.
use super::*;
use serde::{Deserialize, Serialize};

const RECOVERY: &str = "project-recovery.json";
const MAX_ARCHIVE_BYTES: usize = 64 * 1024 * 1024;
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum ProjectAction {
    Rename,
    Relocate,
    Remove,
    Restore,
}
#[derive(Clone)]
pub(crate) struct PreparedProject {
    pub action: ProjectAction,
    pub target: String,
    pub project: Value,
    pub threads: Vec<(String, String)>,
    projects_raw: String,
    recovery_raw: Option<String>,
    index: usize,
}
fn document_raw(db: &Connection, name: &str) -> Result<Option<String>> {
    let local: Option<String> = db
        .query_row(
            "SELECT document FROM documents WHERE name=?1",
            [name],
            |r| r.get(0),
        )
        .optional()?;
    if local.is_some() {
        return Ok(local);
    }
    let original: Option<Vec<u8>> = db
        .query_row(
            "SELECT data FROM original_files WHERE path=?1",
            [name],
            |r| r.get(0),
        )
        .optional()?;
    original
        .map(|raw| String::from_utf8(raw).context("Stored document is not UTF-8"))
        .transpose()
}
fn projects(db: &Connection) -> Result<(String, Vec<Value>)> {
    let raw = document_raw(db, "projects.json")?.unwrap_or_else(|| "[]".into());
    let entries: Vec<Value> =
        serde_json::from_str(&raw).context("Projects document must be an array")?;
    let mut ids = std::collections::HashSet::new();
    for p in &entries {
        let id = p["id"].as_str().context("Project identity is missing")?;
        let id = Uuid::parse_str(id)?;
        ensure!(ids.insert(id), "Projects contain duplicate identities");
    }
    Ok((raw, entries))
}
fn recovery(db: &Connection) -> Result<(Option<String>, Vec<Value>)> {
    let raw = document_raw(db, RECOVERY)?;
    let entries: Vec<Value> = raw
        .as_deref()
        .map(serde_json::from_str)
        .transpose()
        .context("Project recovery document is malformed")?
        .unwrap_or_default();
    Ok((raw, entries))
}
fn thread_rows(db: &Connection, id: &str) -> Result<Vec<(String, String)>> {
    let mut query=db.prepare("SELECT id,document FROM threads WHERE lower(json_extract(document,'$.projectID'))=lower(?1) ORDER BY id")?;
    let rows = query
        .query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    Ok(rows)
}
fn folder_project(p: &Value) -> Result<()> {
    ensure!(
        p.is_object() && p["isChats"] != true && p["isBots"] != true,
        "Only folder projects can be managed"
    );
    ensure!(
        p["name"]
            .as_str()
            .is_some_and(|v| !v.trim().is_empty() && v.len() <= 1024)
            && p["path"].as_str().is_some_and(|v| !v.is_empty()),
        "Stored project name or folder is malformed"
    );
    let id = p["id"].as_str().context("Project identity missing")?;
    ensure!(
        !id.eq_ignore_ascii_case(crate::bot_runtime::BOTS_PROJECT_ID)
            && Uuid::parse_str(id)? != Uuid::nil(),
        "Cannot change a system project"
    );
    Ok(())
}
fn store_document(db: &Connection, name: &str, v: &Value) -> Result<()> {
    db.execute("INSERT INTO documents(name,document) VALUES (?1,?2) ON CONFLICT(name) DO UPDATE SET document=excluded.document",params![name,v.to_string()])?;
    Ok(())
}
impl Store {
    pub(crate) fn latest_project_thread(&self, id: &str) -> Result<Option<String>> {
        let (_, entries) = projects(self.connection()?)?;
        ensure!(
            entries.iter().any(|p| p["id"]
                .as_str()
                .is_some_and(|project| project.eq_ignore_ascii_case(id))),
            "Project no longer exists"
        );
        Ok(self.connection()?.query_row("SELECT id FROM thread_summaries WHERE project_id=?1 COLLATE NOCASE AND archived=0 ORDER BY updated_at DESC,id LIMIT 1",[id],|r|r.get(0)).optional()?)
    }

    pub(crate) fn prepare_project_action(
        &self,
        target: &str,
        action: ProjectAction,
    ) -> Result<PreparedProject> {
        Uuid::parse_str(target).context("Project or recovery identity must be a UUID")?;
        let db = self.connection()?;
        let (projects_raw, entries) = projects(db)?;
        let (recovery_raw, archives) =
            if matches!(action, ProjectAction::Remove | ProjectAction::Restore) {
                recovery(db)?
            } else {
                (None, Vec::new())
            };
        let (index, project, threads) = if action == ProjectAction::Restore {
            let archive = archives
                .iter()
                .find(|a| a["id"] == target && a["restoredAt"].is_null())
                .context("Recovery entry is no longer available")?;
            let project = archive["project"].clone();
            folder_project(&project)?;
            let rows: Vec<(String, String)> = serde_json::from_value(archive["threads"].clone())
                .context("Recovery thread envelope is malformed")?;
            (
                archive["index"]
                    .as_u64()
                    .context("Recovery project order missing")? as usize,
                project,
                rows,
            )
        } else {
            let (i, p) = entries
                .iter()
                .enumerate()
                .find(|(_, p)| {
                    p["id"]
                        .as_str()
                        .is_some_and(|id| id.eq_ignore_ascii_case(target))
                })
                .context("Project no longer exists")?;
            folder_project(p)?;
            (i, p.clone(), thread_rows(db, p["id"].as_str().unwrap())?)
        };
        let prepared = PreparedProject {
            action,
            target: target.into(),
            project,
            threads,
            projects_raw,
            recovery_raw,
            index,
        };
        ensure!(
            prepared
                .threads
                .iter()
                .map(|(_, raw)| raw.len())
                .sum::<usize>()
                <= MAX_ARCHIVE_BYTES,
            "Project recovery exceeds 64 MiB; no changes made"
        );
        Ok(prepared)
    }
    pub(crate) fn project_recoveries(&self) -> Result<Value> {
        let (_, archives) = recovery(self.connection()?)?;
        Ok(json!(archives.iter().filter(|a|a["restoredAt"].is_null()).map(|a|json!({"id":a["id"],"projectId":a["project"]["id"],"name":a["project"]["name"],"path":a["project"]["path"],"threadCount":a["threads"].as_array().map(Vec::len).unwrap_or(0),"removedAt":a["removedAt"]})).collect::<Vec<_>>()))
    }
    pub(crate) fn apply_project_action(
        &mut self,
        expected: &PreparedProject,
        value: Option<&str>,
    ) -> Result<Value> {
        // Resolve only the chosen replacement directory. There is no fs mutation.
        let destination = if expected.action == ProjectAction::Relocate {
            let path = Path::new(value.context("Choose the project's new folder")?);
            ensure!(path.is_dir(), "Replacement project folder does not exist");
            Some(
                path.canonicalize()?
                    .to_str()
                    .context("Project path is not UTF-8")?
                    .to_owned(),
            )
        } else {
            None
        };
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let (raw, mut entries) = projects(&tx)?;
        let (recovery_raw, mut archives) = if matches!(
            expected.action,
            ProjectAction::Remove | ProjectAction::Restore
        ) {
            recovery(&tx)?
        } else {
            (None, Vec::new())
        };
        ensure!(
            raw == expected.projects_raw,
            "Projects changed; review the target again"
        );
        if matches!(
            expected.action,
            ProjectAction::Remove | ProjectAction::Restore
        ) {
            ensure!(
                recovery_raw == expected.recovery_raw,
                "Project recovery changed; review again"
            );
        }
        let id = expected.project["id"]
            .as_str()
            .context("Project identity missing")?;
        if expected.action != ProjectAction::Restore {
            ensure!(
                thread_rows(&tx, id)? == expected.threads,
                "Project conversations changed; review again"
            );
        }
        let mut result = expected.project.clone();
        let mut archive_id = None;
        match expected.action {
            ProjectAction::Rename => {
                let name = value.context("Project name is required")?.trim();
                ensure!(
                    !name.is_empty() && name.len() <= 1024,
                    "Project name must be 1–1024 bytes"
                );
                result["name"] = json!(name);
                entries[expected.index] = result.clone();
            }
            ProjectAction::Relocate => {
                let path = destination.unwrap();
                ensure!(
                    !entries.iter().any(|p| p["id"] != id
                        && p["path"].as_str().is_some_and(|other| other == path
                            || Path::new(other)
                                .canonicalize()
                                .is_ok_and(|v| v.to_str() == Some(path.as_str())))),
                    "Another project already uses that folder"
                );
                let old = expected.project["path"]
                    .as_str()
                    .context("Stored project folder is missing")?;
                if expected.project["name"].as_str()
                    == Path::new(old).file_name().and_then(|v| v.to_str())
                {
                    result["name"] = json!(
                        Path::new(&path)
                            .file_name()
                            .and_then(|v| v.to_str())
                            .unwrap_or("Project")
                    );
                }
                result["path"] = json!(path);
                entries[expected.index] = result.clone();
            }
            ProjectAction::Remove => {
                let aid = Uuid::new_v4().to_string().to_uppercase();
                archives.push(json!({"id":aid,"removedAt":swift_timestamp(),"index":expected.index,"project":expected.project,"sourceProjectsRaw":expected.projects_raw,"threads":expected.threads}));
                ensure!(
                    serde_json::to_vec(&archives)?.len() <= MAX_ARCHIVE_BYTES,
                    "Project recovery archive exceeds 64 MiB; no changes made"
                );
                store_document(&tx, RECOVERY, &json!(archives))?;
                for (thread, _) in &expected.threads {
                    for table in ["search", "search_trigram"] {
                        tx.execute(&format!("DELETE FROM {table} WHERE thread_id=?1"), [thread])?;
                    }
                    tx.execute("DELETE FROM thread_summaries WHERE id=?1", [thread])?;
                    tx.execute("DELETE FROM threads WHERE id=?1", [thread])?;
                }
                entries.remove(expected.index);
                archive_id = Some(aid);
            }
            ProjectAction::Restore => {
                ensure!(
                    !entries.iter().any(|p| p["id"]
                        .as_str()
                        .is_some_and(|other| other.eq_ignore_ascii_case(id))),
                    "A project with that identity already exists"
                );
                let restored_path = expected.project["path"]
                    .as_str()
                    .context("Recovery folder missing")?;
                let restored_canonical = Path::new(restored_path).canonicalize().ok();
                ensure!(
                    !entries
                        .iter()
                        .any(|p| p["path"].as_str().is_some_and(|path| {
                            path == restored_path
                                || restored_canonical.as_ref().is_some_and(|canonical| {
                                    Path::new(path)
                                        .canonicalize()
                                        .is_ok_and(|other| other == *canonical)
                                })
                        })),
                    "A project already uses the restored folder"
                );
                for (thread, document) in &expected.threads {
                    ensure_not_deleted(&tx, thread)?;
                    let exists: bool = tx.query_row(
                        "SELECT EXISTS(SELECT 1 FROM threads WHERE id=?1 COLLATE NOCASE)",
                        [thread],
                        |r| r.get(0),
                    )?;
                    ensure!(
                        !exists,
                        "A recovery conversation ID already exists; nothing was overwritten"
                    );
                    let v: Value = serde_json::from_str(document)?;
                    ensure!(
                        validate_thread(&v)? == thread
                            && v["projectID"]
                                .as_str()
                                .is_some_and(|project| project.eq_ignore_ascii_case(id)),
                        "Recovery conversation identity mismatch"
                    );
                    tx.execute(
                        "INSERT INTO threads(id,document) VALUES (?1,?2)",
                        params![thread, document],
                    )?;
                    cache_thread(&tx, &v, true)?;
                    index_thread(&tx, &v)?;
                }
                let index = expected.index.min(
                    entries
                        .iter()
                        .position(|p| p["isChats"] == true)
                        .unwrap_or(entries.len()),
                );
                entries.insert(index, result.clone());
                let archive = archives
                    .iter_mut()
                    .find(|a| a["id"] == expected.target && a["restoredAt"].is_null())
                    .context("Recovery entry changed")?;
                archive["restoredAt"] = json!(swift_timestamp());
                store_document(&tx, RECOVERY, &json!(archives))?;
            }
        }
        let project_scopes = json!(entries);
        store_document(&tx, "projects.json", &project_scopes)?;
        tx.commit()?;
        self.note_project_scopes(&project_scopes);
        Ok(
            json!({"project":result,"projectId":id,"archiveId":archive_id,"threadIds":expected.threads.iter().map(|(id,_)|id).collect::<Vec<_>>(),"action":expected.action,"filesUnchanged":true}),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Store, Value, Value) {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("old");
        fs::create_dir(&folder).unwrap();
        fs::write(folder.join("keep.txt"), b"working directory stays exact").unwrap();
        let mut store = Store::open(&root.path().join("data/state.sqlite")).unwrap();
        let project = store.create_project(&folder, None).unwrap();
        let other = store.create_project(root.path(), Some("Other")).unwrap();
        let mut projects = store.projects().unwrap();
        projects[0]["future"] = json!({"opaque":[1,"café"]});
        store.save_document("projects.json", &projects).unwrap();
        let mut thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
        thread["draft"] = json!("  unsent café 中文\n");
        thread["sessions"] = json!({"codex":"session-opaque"});
        thread["draftContext"] = json!([{"opaque":true}]);
        thread["isArchived"] = json!(true);
        thread["items"] = json!([{"id":Uuid::new_v4().to_string(),"kind":"assistant","text":"search needle","future":42}]);
        store.save(&thread).unwrap();
        let mut sibling = store.new_thread(other["id"].as_str().unwrap()).unwrap();
        sibling["draft"] = json!("unrelated");
        store.save(&sibling).unwrap();
        (root, store, project, thread)
    }
    #[test]
    fn rename_and_relocate_preserve_all_thread_bytes_and_unknown_project_metadata() {
        let (root, mut store, p, t) = fixture();
        let id = p["id"].as_str().unwrap();
        let raw = thread_rows(store.connection().unwrap(), id).unwrap();
        let folder = root.path().join("new");
        fs::create_dir(&folder).unwrap();
        let preview = store
            .prepare_project_action(id, ProjectAction::Relocate)
            .unwrap();
        let out = store
            .apply_project_action(&preview, Some(folder.to_str().unwrap()))
            .unwrap();
        assert_eq!(out["project"]["name"], "new");
        assert_eq!(out["project"]["future"]["opaque"][1], "café");
        assert_eq!(thread_rows(store.connection().unwrap(), id).unwrap(), raw);
        assert_eq!(store.thread(t["id"].as_str().unwrap()).unwrap(), t);
        let preview = store
            .prepare_project_action(id, ProjectAction::Rename)
            .unwrap();
        store
            .apply_project_action(&preview, Some("  Custom title  "))
            .unwrap();
        let third = root.path().join("third");
        fs::create_dir(&third).unwrap();
        let preview = store
            .prepare_project_action(id, ProjectAction::Relocate)
            .unwrap();
        let out = store
            .apply_project_action(&preview, Some(third.to_str().unwrap()))
            .unwrap();
        assert_eq!(out["project"]["name"], "Custom title");
        assert_eq!(thread_rows(store.connection().unwrap(), id).unwrap(), raw);
        let preview = store
            .prepare_project_action(id, ProjectAction::Relocate)
            .unwrap();
        let out = store.apply_project_action(&preview, Some(root.path().to_str().unwrap()));
        assert!(
            out.is_err(),
            "existing project directory collision must fail"
        );
        assert_eq!(
            fs::read(root.path().join("old/keep.txt")).unwrap(),
            b"working directory stays exact"
        );
    }
    #[test]
    fn removal_is_atomic_recoverable_and_restore_preserves_exact_raw_threads_and_indexes() {
        let (root, mut store, p, t) = fixture();
        let id = p["id"].as_str().unwrap();
        let tid = t["id"].as_str().unwrap();
        let raw = format!("  {}\n", t);
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE threads SET document=?2 WHERE id=?1",
                params![tid, raw],
            )
            .unwrap();
        let before = store
            .prepare_project_action(id, ProjectAction::Remove)
            .unwrap();
        let out = store.apply_project_action(&before, None).unwrap();
        assert!(store.thread(tid).is_err());
        assert_eq!(store.projects().unwrap().as_array().unwrap().len(), 1);
        assert_eq!(store.summaries("search needle", true).unwrap().len(), 0);
        assert!(root.path().join("old/keep.txt").is_file());
        let archive = out["archiveId"].as_str().unwrap();
        let restore = store
            .prepare_project_action(archive, ProjectAction::Restore)
            .unwrap();
        store.apply_project_action(&restore, None).unwrap();
        assert_eq!(
            thread_rows(store.connection().unwrap(), id).unwrap(),
            before.threads
        );
        assert_eq!(store.thread(tid).unwrap(), t);
        assert_eq!(store.summaries("search needle", true).unwrap().len(), 1);
        assert!(
            store
                .project_recoveries()
                .unwrap()
                .as_array()
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn project_or_conversation_changes_reject_a_stale_review_without_partial_write() {
        let (_root, mut store, p, _t) = fixture();
        let id = p["id"].as_str().unwrap();
        let preview = store
            .prepare_project_action(id, ProjectAction::Remove)
            .unwrap();
        store.new_thread(id).unwrap();
        let rows = thread_rows(store.connection().unwrap(), id).unwrap();
        assert!(store.apply_project_action(&preview, None).is_err());
        assert_eq!(thread_rows(store.connection().unwrap(), id).unwrap(), rows);
        assert!(store.document(RECOVERY).unwrap().is_none());
        let preview = store
            .prepare_project_action(id, ProjectAction::Rename)
            .unwrap();
        store
            .patch_project(id, &json!({"name":"Concurrent"}))
            .unwrap();
        assert!(
            store
                .apply_project_action(&preview, Some("Lost update"))
                .is_err()
        );
        assert_eq!(store.projects().unwrap()[0]["name"], "Concurrent");
    }
    #[test]
    fn transaction_failure_keeps_project_threads_and_recovery_document_unchanged() {
        let (_root, mut store, p, t) = fixture();
        let id = p["id"].as_str().unwrap();
        let before = store.projects().unwrap();
        let preview = store
            .prepare_project_action(id, ProjectAction::Remove)
            .unwrap();
        store.connection().unwrap().execute_batch("CREATE TRIGGER fail_remove BEFORE DELETE ON threads BEGIN SELECT RAISE(ABORT,'fixture failure'); END;").unwrap();
        assert!(store.apply_project_action(&preview, None).is_err());
        assert_eq!(store.projects().unwrap(), before);
        assert_eq!(store.thread(t["id"].as_str().unwrap()).unwrap(), t);
        assert!(store.document(RECOVERY).unwrap().is_none());
    }
    #[test]
    fn restore_conflict_refuses_case_alias_and_never_overwrites() {
        let (_root, mut store, p, t) = fixture();
        let preview = store
            .prepare_project_action(p["id"].as_str().unwrap(), ProjectAction::Remove)
            .unwrap();
        let removed = store.apply_project_action(&preview, None).unwrap();
        let aid = removed["archiveId"].as_str().unwrap();
        let mut conflict = t.clone();
        conflict["id"] = json!(t["id"].as_str().unwrap().to_lowercase());
        conflict["draft"] = json!("keep conflicting thread");
        store.save(&conflict).unwrap();
        let restore = store
            .prepare_project_action(aid, ProjectAction::Restore)
            .unwrap();
        assert!(store.apply_project_action(&restore, None).is_err());
        assert_eq!(
            store.thread(conflict["id"].as_str().unwrap()).unwrap(),
            conflict
        );
        assert_eq!(
            store
                .project_recoveries()
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(store.projects().unwrap().as_array().unwrap().len(), 1);
    }
    #[test]
    fn malformed_recovery_and_system_project_are_never_replaced() {
        let (root, mut store, p, _) = fixture();
        store
            .save_document(RECOVERY, &json!({"futureEnvelope":true}))
            .unwrap();
        let original = store.document(RECOVERY).unwrap();
        assert!(
            store
                .prepare_project_action(p["id"].as_str().unwrap(), ProjectAction::Remove)
                .is_err()
        );
        assert_eq!(store.document(RECOVERY).unwrap(), original);
        let rename = store
            .prepare_project_action(p["id"].as_str().unwrap(), ProjectAction::Rename)
            .unwrap();
        store
            .apply_project_action(&rename, Some("Still manageable"))
            .unwrap();
        assert_eq!(store.document(RECOVERY).unwrap(), original);
        store.save_document(RECOVERY, &json!([])).unwrap();
        let mut projects = store.projects().unwrap();
        projects[0]["isChats"] = json!(true);
        store.save_document("projects.json", &projects).unwrap();
        assert!(
            store
                .prepare_project_action(p["id"].as_str().unwrap(), ProjectAction::Rename)
                .is_err()
        );
        assert!(root.path().join("old/keep.txt").is_file());
    }
    #[test]
    fn empty_project_removal_has_real_recovery_and_restore_rolls_back_on_insert_failure() {
        let (root, mut store, p, t) = fixture();
        let remove = store
            .prepare_project_action(p["id"].as_str().unwrap(), ProjectAction::Remove)
            .unwrap();
        let removed = store.apply_project_action(&remove, None).unwrap();
        let recovery_before = store.document(RECOVERY).unwrap();
        let projects_before = store.projects().unwrap();
        let restore = store
            .prepare_project_action(
                removed["archiveId"].as_str().unwrap(),
                ProjectAction::Restore,
            )
            .unwrap();
        store.connection().unwrap().execute_batch("CREATE TRIGGER fail_restore BEFORE INSERT ON thread_summaries BEGIN SELECT RAISE(ABORT,'fixture restore failure'); END;").unwrap();
        assert!(store.apply_project_action(&restore, None).is_err());
        assert!(store.thread(t["id"].as_str().unwrap()).is_err());
        assert_eq!(store.document(RECOVERY).unwrap(), recovery_before);
        assert_eq!(store.projects().unwrap(), projects_before);
        store
            .connection()
            .unwrap()
            .execute_batch("DROP TRIGGER fail_restore")
            .unwrap();
        let empty = store
            .create_project(&root.path().join("old"), Some("Empty"))
            .unwrap();
        store.remove_project(empty["id"].as_str().unwrap()).unwrap();
        let entries = store.project_recoveries().unwrap();
        let entry = entries
            .as_array()
            .unwrap()
            .iter()
            .find(|a| a["projectId"] == empty["id"])
            .unwrap();
        assert_eq!(entry["threadCount"], 0);
        let restore = store
            .prepare_project_action(entry["id"].as_str().unwrap(), ProjectAction::Restore)
            .unwrap();
        store.apply_project_action(&restore, None).unwrap();
        assert!(
            store
                .projects()
                .unwrap()
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v["id"] == empty["id"])
        );
    }
    #[test]
    fn imported_swift_originals_and_external_files_stay_exact_through_remove_restore() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("swift");
        fs::create_dir_all(source.join("threads")).unwrap();
        fs::create_dir(source.join("attachments")).unwrap();
        let project_id = Uuid::new_v4().to_string().to_uppercase();
        let thread_id = Uuid::new_v4().to_string().to_uppercase();
        let projects = format!(
            " [{{\"id\":\"{project_id}\",\"name\":\"Imported\",\"path\":{},\"future\":{{\"keep\":true}}}}] \n",
            json!(source.to_str().unwrap())
        );
        let thread = format!(
            " {{\"id\":\"{thread_id}\",\"projectID\":\"{}\",\"draft\":\"unsent café 中文\",\"sessions\":[{{\"opaque\":7}}],\"draftContext\":[{{\"keep\":true}}],\"items\":[],\"unknown\":[9]}}\n",
            project_id.to_lowercase()
        );
        fs::write(source.join("projects.json"), &projects).unwrap();
        fs::write(source.join("threads/source.json"), &thread).unwrap();
        fs::write(source.join("attachments/source.bin"), [0, 255, 7]).unwrap();
        let mut store = Store::open(&root.path().join("rust/state.sqlite")).unwrap();
        store.import_legacy(&source).unwrap();
        let before = thread_rows(store.connection().unwrap(), &project_id).unwrap();
        let remove = store
            .prepare_project_action(&project_id, ProjectAction::Remove)
            .unwrap();
        let removed = store.apply_project_action(&remove, None).unwrap();
        assert!(store.thread(&thread_id).is_err());
        assert!(
            store
                .connection()
                .unwrap()
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1)",
                    [&thread_id],
                    |r| r.get::<_, bool>(0)
                )
                .unwrap()
        );
        let restore = store
            .prepare_project_action(
                removed["archiveId"].as_str().unwrap(),
                ProjectAction::Restore,
            )
            .unwrap();
        store.apply_project_action(&restore, None).unwrap();
        assert_eq!(
            thread_rows(store.connection().unwrap(), &project_id).unwrap(),
            before
        );
        assert_eq!(
            store.original("projects.json").unwrap().unwrap(),
            projects.as_bytes()
        );
        assert_eq!(
            store.original("threads/source.json").unwrap().unwrap(),
            thread.as_bytes()
        );
        assert_eq!(
            store.original("attachments/source.bin").unwrap().unwrap(),
            [0, 255, 7]
        );
        assert_eq!(
            fs::read(source.join("projects.json")).unwrap(),
            projects.as_bytes()
        );
        assert_eq!(
            fs::read(source.join("threads/source.json")).unwrap(),
            thread.as_bytes()
        );
        assert_eq!(
            fs::read(source.join("attachments/source.bin")).unwrap(),
            [0, 255, 7]
        );
        assert_eq!(store.projects().unwrap()[0]["future"], json!({"keep":true}));
    }
    #[cfg(unix)]
    #[test]
    fn restore_refuses_an_existing_project_folder_symlink_alias() {
        let (root, mut store, p, _) = fixture();
        let remove = store
            .prepare_project_action(p["id"].as_str().unwrap(), ProjectAction::Remove)
            .unwrap();
        let removed = store.apply_project_action(&remove, None).unwrap();
        let alias = root.path().join("alias");
        std::os::unix::fs::symlink(root.path().join("old"), &alias).unwrap();
        let mut projects = store.projects().unwrap();
        projects[0]["path"] = json!(alias.to_str().unwrap());
        store.save_document("projects.json", &projects).unwrap();
        let restore = store
            .prepare_project_action(
                removed["archiveId"].as_str().unwrap(),
                ProjectAction::Restore,
            )
            .unwrap();
        let before = store.projects().unwrap();
        assert!(store.apply_project_action(&restore, None).is_err());
        assert_eq!(store.projects().unwrap(), before);
        assert_eq!(
            store
                .project_recoveries()
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }
}
