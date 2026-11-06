//! Typed native deletion transactions. Captured originals/import provenance are
//! immutable. Persistent tombstones deny resurrection and old native sessions;
//! neither table can grant execution or Undo authority.
use super::*;
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashSet};
const ROW_LIMIT: usize = 128;
const ROW_BYTES: usize = 8 * 1024 * 1024;
const BATCH_BYTES: usize = 32 * 1024 * 1024;
#[derive(Clone)]
pub(crate) struct DeleteRow {
    pub id: String,
    pub title: String,
    pub raw: String,
    pub imported: bool,
    pub native: BTreeSet<[u8; 32]>,
}
impl DeleteRow {
    pub(crate) fn revoke_native(&mut self, native: &str) -> Result<()> {
        ensure!(
            !native.is_empty() && native.len() <= 512 && !native.chars().any(char::is_control),
            "Invalid private native-session identity"
        );
        self.native.insert(native_hash(native));
        ensure!(
            self.native.len() <= 1024,
            "Conversation native-session metadata exceeds its safe bound"
        );
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct DeleteVersion {
    changes: u64,
    external: i64,
}
pub struct ArchivedConversation {
    pub id: String,
    pub title: String,
    pub project_id: String,
    pub updated_at: f64,
}
pub struct ArchivedConversations {
    pub rows: Vec<ArchivedConversation>,
    pub total: usize,
    pub offset: usize,
}
fn exists(db: &Connection, table: &str) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
        [table],
        |row| row.get(0),
    )?)
}
pub(super) fn ensure_not_deleted(db: &Connection, id: &str) -> Result<()> {
    let id = Uuid::parse_str(id)?.to_string();
    if exists(db, "deleted_threads")? {
        let deleted: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM deleted_threads WHERE id=?1 COLLATE NOCASE)",
            [&id],
            |row| row.get(0),
        )?;
        ensure!(
            !deleted,
            "This conversation was deleted; only its native Undo receipt can restore it"
        );
    }
    Ok(())
}
fn version(db: &Connection) -> Result<DeleteVersion> {
    Ok(DeleteVersion {
        changes: db.total_changes(),
        external: db.query_row("PRAGMA data_version", [], |row| row.get(0))?,
    })
}
fn native_hash(id: &str) -> [u8; 32] {
    let mut hash = Sha256::new();
    hash.update(b"Coincide deleted native session v1\0");
    hash.update(id.as_bytes());
    hash.finalize().into()
}
fn native_ids(thread: &Value) -> Result<BTreeSet<[u8; 32]>> {
    let mut result = BTreeSet::new();
    for field in ["sessions", "accountSessions"] {
        let references: Box<dyn Iterator<Item = &Value> + '_> = match &thread[field] {
            Value::Object(values) => Box::new(values.values()),
            Value::Array(values) => Box::new(values.iter()),
            _ => Box::new(std::iter::empty()),
        };
        for reference in references {
            if let Some(id) = reference.get("sessionID").and_then(Value::as_str) {
                result.insert(native_hash(id));
                ensure!(
                    result.len() <= 1024,
                    "Conversation native-session metadata exceeds its safe bound"
                );
            }
        }
    }
    Ok(result)
}
fn rows_match(db: &Connection, rows: &[DeleteRow]) -> Result<()> {
    for row in rows {
        ensure_not_deleted(db, &row.id)?;
        let matches: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM threads WHERE id=?1 AND document=?2)",
            params![row.id, row.raw],
            |row| row.get(0),
        )?;
        let imported: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1 COLLATE NOCASE)",
            [&row.id],
            |row| row.get(0),
        )?;
        ensure!(
            matches && imported == row.imported,
            "An archived conversation changed after review; review it again"
        );
    }
    Ok(())
}
impl Store {
    pub(crate) fn delete_source_identity(
        &self,
    ) -> Result<(std::path::PathBuf, crate::private_fs::Identity)> {
        let path = Path::new(
            self.connection()?
                .path()
                .context("Store has no filesystem location")?,
        )
        .canonicalize()?;
        let identity = crate::private_fs::identity(&path)?;
        Ok((path, identity))
    }
    pub(crate) fn archived_conversations(
        &self,
        query: &str,
        offset: usize,
        limit: usize,
    ) -> Result<ArchivedConversations> {
        self.archived_conversations_for_project(query, None, offset, limit)
    }
    pub(crate) fn archived_conversations_for_project(
        &self,
        query: &str,
        project: Option<&str>,
        offset: usize,
        limit: usize,
    ) -> Result<ArchivedConversations> {
        ensure!(
            query.len() <= 1024 && (1..=100).contains(&limit),
            "Invalid archive filter or page size"
        );
        let query = query.trim().to_lowercase();
        let project = project
            .map(|id| {
                if id.is_empty() {
                    Ok(Uuid::nil())
                } else {
                    Uuid::parse_str(id)
                }
            })
            .transpose()?;
        let mut total = 0usize;
        let mut rows = Vec::new();
        let mut statement=self.connection()?.prepare("SELECT id,substr(title,1,1024),project_id,updated_at FROM thread_summaries WHERE archived=1 ORDER BY updated_at DESC,id")?;
        for row in statement.query_map([], |row| {
            Ok(ArchivedConversation {
                id: row.get(0)?,
                title: row.get(1)?,
                project_id: row.get(2)?,
                updated_at: row.get(3)?,
            })
        })? {
            let row = row?;
            if project.is_some_and(|project| {
                let actual = if row.project_id.is_empty() {
                    Some(Uuid::nil())
                } else {
                    Uuid::parse_str(&row.project_id).ok()
                };
                actual != Some(project)
            }) {
                continue;
            }
            if !query.is_empty() && !row.title.to_lowercase().contains(&query) {
                continue;
            }
            if total >= offset && rows.len() < limit {
                rows.push(row)
            }
            total = total.checked_add(1).context("Archive count overflow")?;
        }
        Ok(ArchivedConversations {
            rows,
            total,
            offset,
        })
    }
    pub(crate) fn prepare_delete_rows(
        &self,
        ids: &[String],
    ) -> Result<(DeleteVersion, Vec<DeleteRow>)> {
        ensure!(
            !ids.is_empty() && ids.len() <= ROW_LIMIT,
            "Review 1–128 archived conversations at a time"
        );
        let start = version(self.connection()?)?;
        let mut unique = HashSet::new();
        let mut rows = Vec::new();
        let mut bytes = 0usize;
        for id in ids {
            ensure!(
                unique.insert(Uuid::parse_str(id)?),
                "Duplicate conversation selection"
            );
            let (stored,raw):(String,Option<String>)=self.connection()?.query_row("SELECT id,CASE WHEN length(CAST(document AS BLOB))<=?2 THEN document ELSE NULL END FROM threads WHERE id=?1 COLLATE NOCASE",params![id,ROW_BYTES as i64],|row|Ok((row.get(0)?,row.get(1)?)))?;
            let raw = raw.context("An archived conversation exceeds the 8 MiB deletion bound")?;
            bytes = bytes
                .checked_add(raw.len())
                .context("Archive batch size overflow")?;
            ensure!(
                bytes <= BATCH_BYTES,
                "Reviewed conversation data exceeds the 32 MiB Undo bound"
            );
            let value: Value = serde_json::from_str(&raw)?;
            ensure!(
                validate_thread(&value)? == stored && value["isArchived"] == true,
                "Only current archived conversations can be deleted here"
            );
            rows.push(DeleteRow {
                id: stored.clone(),
                title: text(&value, "title").chars().take(120).collect(),
                native: native_ids(&value)?,
                raw,
                imported: self.is_imported(&stored)?,
            });
        }
        ensure!(
            version(self.connection()?)? == start,
            "Archive changed while preparing confirmation"
        );
        rows_match(self.connection()?, &rows)?;
        Ok((start, rows))
    }
    pub(crate) fn validate_delete_rows(
        &self,
        expected: DeleteVersion,
        rows: &[DeleteRow],
    ) -> Result<()> {
        ensure!(
            version(self.connection()?)? == expected,
            "Store changed after deletion review; review the shown conversations again"
        );
        rows_match(self.connection()?, rows)
    }
    pub(crate) fn delete_archived_rows(
        &mut self,
        expected: DeleteVersion,
        rows: &[DeleteRow],
        receipt: &str,
    ) -> Result<()> {
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure!(
            version(&tx)? == expected,
            "Store changed after deletion review"
        );
        rows_match(&tx, rows)?;
        tx.execute_batch("CREATE TABLE IF NOT EXISTS deleted_threads(id TEXT PRIMARY KEY COLLATE NOCASE,receipt TEXT NOT NULL); CREATE TABLE IF NOT EXISTS revoked_native_sessions(thread_id TEXT NOT NULL COLLATE NOCASE,native_hash BLOB NOT NULL CHECK(length(native_hash)=32),PRIMARY KEY(thread_id,native_hash));")?;
        for row in rows {
            tx.execute(
                "INSERT INTO deleted_threads(id,receipt) VALUES(?1,?2)",
                params![Uuid::parse_str(&row.id)?.to_string(), receipt],
            )?;
            for hash in &row.native {
                tx.execute("INSERT OR IGNORE INTO revoked_native_sessions(thread_id,native_hash) VALUES(?1,?2)",params![Uuid::parse_str(&row.id)?.to_string(),hash.as_slice()])?;
            }
            tx.execute(
                "DELETE FROM search WHERE thread_id=?1 COLLATE NOCASE",
                [&row.id],
            )?;
            tx.execute(
                "DELETE FROM search_trigram WHERE thread_id=?1 COLLATE NOCASE",
                [&row.id],
            )?;
            tx.execute(
                "DELETE FROM thread_summaries WHERE id=?1 COLLATE NOCASE",
                [&row.id],
            )?;
            ensure!(
                tx.execute(
                    "DELETE FROM threads WHERE id=?1 AND document=?2",
                    params![row.id, row.raw]
                )? == 1,
                "Conversation changed during deletion"
            );
        }
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn restore_deleted_rows(&mut self, rows: &[DeleteRow], receipt: &str) -> Result<()> {
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure!(
            exists(&tx, "deleted_threads")?,
            "Delete Undo receipt is no longer current"
        );
        for row in rows {
            let matches:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM deleted_threads WHERE id=?3 AND receipt=?2) AND NOT EXISTS(SELECT 1 FROM threads WHERE id=?1 COLLATE NOCASE) AND NOT EXISTS(SELECT 1 FROM thread_summaries WHERE id=?1 COLLATE NOCASE) AND NOT EXISTS(SELECT 1 FROM search WHERE thread_id=?1 COLLATE NOCASE) AND NOT EXISTS(SELECT 1 FROM search_trigram WHERE thread_id=?1 COLLATE NOCASE)",params![row.id,receipt,Uuid::parse_str(&row.id)?.to_string()],|row|row.get(0))?;
            let imported: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1 COLLATE NOCASE)",
                [&row.id],
                |row| row.get(0),
            )?;
            ensure!(
                matches && imported == row.imported,
                "Deleted conversation identity or provenance changed; Undo was refused"
            );
        }
        for row in rows {
            let value: Value = serde_json::from_str(&row.raw)?;
            tx.execute(
                "INSERT INTO threads(id,document) VALUES(?1,?2)",
                params![row.id, row.raw],
            )?;
            index_thread(&tx, &value)?;
            cache_thread(&tx, &value, true)?;
            ensure!(
                tx.execute(
                    "DELETE FROM deleted_threads WHERE id=?1 AND receipt=?2",
                    params![Uuid::parse_str(&row.id)?.to_string(), receipt]
                )? == 1,
                "Delete Undo receipt changed"
            );
        }
        tx.commit()?;
        Ok(())
    }
    /// Deny-only native history guard, deliberately outside thread/import JSON.
    /// An Undo restores exact content while old provider session IDs stay denied.
    pub(crate) fn is_native_session_revoked(&self, thread: &str, native: &str) -> Result<bool> {
        let thread = Uuid::parse_str(thread)?.to_string();
        if !exists(self.connection()?, "revoked_native_sessions")? {
            return Ok(false);
        }
        Ok(self.connection()?.query_row("SELECT EXISTS(SELECT 1 FROM revoked_native_sessions WHERE thread_id=?1 COLLATE NOCASE AND native_hash=?2)",params![thread,native_hash(native).as_slice()],|row|row.get(0))?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Store, Vec<Value>) {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("data/state.sqlite")).unwrap();
        let mut threads = Vec::new();
        for index in 0..3 {
            let mut thread = store.new_thread("").unwrap();
            thread["title"] = json!(format!("Synthetic archive {index}"));
            thread["isArchived"] = json!(index < 2);
            thread["items"] =
                json!([{"kind":"user","text":"synthetic searchable prefix","future":42}]);
            thread["future"] = json!({"unknown":[true,42]});
            thread["sessions"] = json!(["codex",{"sessionID":format!("old-codex-{index}"),"future":44},"claude",{"sessionID":format!("old-claude-{index}")}]);
            thread["accountSessions"] = json!({"codex/synthetic-account":{"sessionID":format!("old-account-{index}"),"seenItemCount":99}});
            store.save(&thread).unwrap();
            let raw = format!(" {}\n", thread);
            store
                .connection()
                .unwrap()
                .execute(
                    "UPDATE threads SET document=?2 WHERE id=?1",
                    params![thread["id"].as_str().unwrap(), raw],
                )
                .unwrap();
            threads.push(thread);
        }
        (dir, store, threads)
    }
    fn raw(store: &Store, id: &str) -> String {
        store
            .connection()
            .unwrap()
            .query_row("SELECT document FROM threads WHERE id=?1", [id], |row| {
                row.get(0)
            })
            .unwrap()
    }
    fn indexes(store: &Store) -> Vec<(String, String, String)> {
        let mut result = Vec::new();
        for (table, query) in [
            ("threads", "SELECT id,document FROM threads ORDER BY id"),
            (
                "summaries",
                "SELECT id,json_array(title,project_id,archived,pinned,updated_at,search_body,snoozed_until) FROM thread_summaries ORDER BY id",
            ),
            (
                "search",
                "SELECT thread_id,json_array(title,body) FROM search ORDER BY thread_id",
            ),
            (
                "trigram",
                "SELECT thread_id,body FROM search_trigram ORDER BY thread_id",
            ),
        ] {
            let mut stmt = store.connection().unwrap().prepare(query).unwrap();
            for row in stmt
                .query_map([], |row| Ok((table.to_owned(), row.get(0)?, row.get(1)?)))
                .unwrap()
            {
                result.push(row.unwrap());
            }
        }
        result
    }
    #[test]
    fn atomic_delete_and_undo_preserve_raw_unknowns_indexes_and_deny_all_old_sessions() {
        let (_dir, mut store, threads) = fixture();
        let id = threads[0]["id"].as_str().unwrap();
        let before = indexes(&store);
        let source = raw(&store, id);
        let (version, rows) = store.prepare_delete_rows(&[id.into()]).unwrap();
        store
            .delete_archived_rows(version, &rows, "synthetic-token")
            .unwrap();
        assert!(store.thread(id).is_err());
        assert!(ensure_not_deleted(store.connection().unwrap(), id).is_err());
        for native in ["old-codex-0", "old-claude-0", "old-account-0"] {
            assert!(store.is_native_session_revoked(id, native).unwrap());
        }
        assert!(
            !store
                .is_native_session_revoked(id, "new-owned-native")
                .unwrap()
        );
        store
            .restore_deleted_rows(&rows, "synthetic-token")
            .unwrap();
        assert_eq!(raw(&store, id), source);
        assert_eq!(indexes(&store), before);
        assert!(
            store.is_native_session_revoked(id, "old-codex-0").unwrap(),
            "Undo restores content without reviving native continuation"
        );
        assert!(
            store
                .restore_deleted_rows(&rows, "synthetic-token")
                .is_err(),
            "Undo cannot replay after consuming its tombstones"
        );
    }
    #[test]
    fn stale_confirmation_detects_local_and_external_aba_writes() {
        let (dir, mut store, threads) = fixture();
        let id = threads[0]["id"].as_str().unwrap();
        let source = raw(&store, id);
        let (version, rows) = store.prepare_delete_rows(&[id.into()]).unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE threads SET document=?2 WHERE id=?1",
                params![id, threads[1].to_string()],
            )
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE threads SET document=?2 WHERE id=?1",
                params![id, source],
            )
            .unwrap();
        assert!(
            store
                .delete_archived_rows(version, &rows, "must-not-delete")
                .is_err()
        );
        let (version, rows) = store.prepare_delete_rows(&[id.into()]).unwrap();
        let other = Connection::open(dir.path().join("data/state.sqlite")).unwrap();
        other
            .execute(
                "UPDATE threads SET document=?2 WHERE id=?1",
                params![id, threads[1].to_string()],
            )
            .unwrap();
        other
            .execute(
                "UPDATE threads SET document=?2 WHERE id=?1",
                params![id, source],
            )
            .unwrap();
        drop(other);
        assert!(
            store
                .delete_archived_rows(version, &rows, "must-not-delete")
                .is_err()
        );
        assert_eq!(raw(&store, id), source);
        assert!(!exists(store.connection().unwrap(), "deleted_threads").unwrap());
    }
    #[test]
    fn late_sql_failure_rolls_back_entire_batch_indexes_and_deny_metadata() {
        let (_dir, mut store, threads) = fixture();
        let ids = threads[..2]
            .iter()
            .map(|thread| text(thread, "id"))
            .collect::<Vec<_>>();
        let before = indexes(&store);
        let (version, rows) = store.prepare_delete_rows(&ids).unwrap();
        store.connection().unwrap().execute_batch(&format!("CREATE TRIGGER fail_second_delete BEFORE DELETE ON threads WHEN OLD.id='{}' BEGIN SELECT RAISE(FAIL,'synthetic late failure'); END;",ids[1])).unwrap();
        assert!(
            store
                .delete_archived_rows(version, &rows, "synthetic-token")
                .is_err()
        );
        assert_eq!(indexes(&store), before);
        assert!(!exists(store.connection().unwrap(), "deleted_threads").unwrap());
        assert!(!exists(store.connection().unwrap(), "revoked_native_sessions").unwrap());
    }
    #[test]
    fn undo_failure_is_atomic_and_an_opaque_receipt_can_retry_after_repair() {
        let (_dir, mut store, threads) = fixture();
        let ids = threads[..2]
            .iter()
            .map(|thread| text(thread, "id"))
            .collect::<Vec<_>>();
        let before = indexes(&store);
        let (version, rows) = store.prepare_delete_rows(&ids).unwrap();
        store
            .delete_archived_rows(version, &rows, "synthetic-token")
            .unwrap();
        let deleted = indexes(&store);
        store.connection().unwrap().execute_batch(&format!("CREATE TRIGGER fail_second_restore BEFORE INSERT ON threads WHEN NEW.id='{}' BEGIN SELECT RAISE(FAIL,'synthetic restore failure'); END;",ids[1])).unwrap();
        assert!(
            store
                .restore_deleted_rows(&rows, "synthetic-token")
                .is_err()
        );
        assert_eq!(indexes(&store), deleted);
        store
            .connection()
            .unwrap()
            .execute_batch("DROP TRIGGER fail_second_restore;")
            .unwrap();
        store
            .restore_deleted_rows(&rows, "synthetic-token")
            .unwrap();
        assert_eq!(indexes(&store), before);
    }
    #[test]
    fn captured_import_bytes_and_provenance_survive_native_delete_and_undo() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source");
        fs::create_dir_all(source.join("threads")).unwrap();
        let id = Uuid::new_v4().to_string();
        let original = format!(
            " {{ \"id\":\"{id}\", \"title\":\"Captured synthetic import\",\"isArchived\":true,\"items\":[],\"future\":{{\"keep\":42}} }}\n"
        );
        let path = source.join("threads/captured.json");
        fs::write(&path, &original).unwrap();
        let mut store = Store::open(&dir.path().join("data/state.sqlite")).unwrap();
        store.import_legacy(&source).unwrap();
        let before = store.original("threads/captured.json").unwrap().unwrap();
        let (version, rows) = store
            .prepare_delete_rows(std::slice::from_ref(&id))
            .unwrap();
        store
            .delete_archived_rows(version, &rows, "synthetic-token")
            .unwrap();
        assert!(store.is_imported(&id).unwrap());
        assert_eq!(
            store.original("threads/captured.json").unwrap().unwrap(),
            before
        );
        assert_eq!(fs::read(&path).unwrap(), original.as_bytes());
        store
            .restore_deleted_rows(&rows, "synthetic-token")
            .unwrap();
        assert!(store.is_imported(&id).unwrap());
        assert_eq!(fs::read(&path).unwrap(), original.as_bytes());
    }
    #[test]
    fn archive_title_filter_paginates_all_projects_and_live_rows_cannot_be_deleted() {
        let (_dir, store, threads) = fixture();
        let page = store.archived_conversations("ARCHIVE", 0, 1).unwrap();
        assert_eq!(page.total, 2);
        assert_eq!(page.rows.len(), 1);
        let next = store.archived_conversations("archive", 1, 1).unwrap();
        assert_eq!(next.total, 2);
        assert_ne!(page.rows[0].id, next.rows[0].id);
        assert!(
            store
                .prepare_delete_rows(&[text(&threads[2], "id")])
                .is_err()
        );
        assert_eq!(
            store
                .archived_conversations("no match", 0, 50)
                .unwrap()
                .total,
            0
        );
    }
    #[test]
    fn deleted_uuid_aliases_cannot_recreate_rows_and_denials_survive_reopen() {
        let (dir, mut store, threads) = fixture();
        let original = threads[0].clone();
        let id = Uuid::parse_str(original["id"].as_str().unwrap()).unwrap();
        let (version, rows) = store.prepare_delete_rows(&[id.to_string()]).unwrap();
        store
            .delete_archived_rows(version, &rows, "synthetic-token")
            .unwrap();
        let before = indexes(&store);
        for alias in [
            id.to_string(),
            id.simple().to_string(),
            format!("{{{id}}}"),
            format!("urn:uuid:{id}"),
        ] {
            let mut candidate = original.clone();
            candidate["id"] = json!(alias);
            assert!(
                store.save(&candidate).is_err(),
                "A UUID spelling must not bypass deletion"
            );
            assert!(
                store
                    .is_native_session_revoked(&alias, "old-codex-0")
                    .unwrap()
            );
        }
        assert_eq!(indexes(&store), before);
        store.close_for_shutdown().unwrap();
        let mut reopened = Store::open(&dir.path().join("data/state.sqlite")).unwrap();
        assert!(reopened.save(&original).is_err());
        assert!(
            reopened
                .is_native_session_revoked(&id.to_string(), "old-codex-0")
                .unwrap()
        );
    }
    #[test]
    fn archive_project_filter_is_applied_before_page_counts_and_preserves_global_listing() {
        let (_dir, mut store, mut threads) = fixture();
        let project = Uuid::new_v4();
        let other = Uuid::new_v4();
        threads[0]["projectID"] = json!(project.to_string());
        threads[1]["projectID"] = json!(other.to_string());
        threads[2]["projectID"] = json!(project.to_string());
        for thread in &threads {
            store.save(thread).unwrap();
        }
        let mut extra = store.new_thread("").unwrap();
        extra["projectID"] = json!(project.to_string());
        extra["title"] = json!("Another synthetic archive");
        extra["isArchived"] = json!(true);
        store.save(&extra).unwrap();
        let first = store
            .archived_conversations_for_project(
                "archive",
                Some(&project.simple().to_string()),
                0,
                1,
            )
            .unwrap();
        let second = store
            .archived_conversations_for_project("archive", Some(&project.to_string()), 1, 1)
            .unwrap();
        assert_eq!(
            (
                first.total,
                second.total,
                first.rows.len(),
                second.rows.len()
            ),
            (2, 2, 1, 1)
        );
        assert_ne!(first.rows[0].id, second.rows[0].id);
        assert!(
            first
                .rows
                .iter()
                .chain(&second.rows)
                .all(|row| Uuid::parse_str(&row.project_id).unwrap() == project)
        );
        assert_eq!(
            store
                .archived_conversations_for_project("archive", Some(&other.to_string()), 0, 10)
                .unwrap()
                .total,
            1
        );
        assert_eq!(
            store
                .archived_conversations("archive", 0, 10)
                .unwrap()
                .total,
            3
        );
        assert_eq!(
            store
                .archived_conversations_for_project("no match", Some(&project.to_string()), 0, 10)
                .unwrap()
                .total,
            0
        );
        assert!(
            store
                .archived_conversations_for_project("", Some("not-a-project"), 0, 10)
                .is_err()
        );
    }
}
