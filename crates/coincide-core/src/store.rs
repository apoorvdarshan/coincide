use anyhow::{Context, Result, bail, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

/// A new database is always independent of the Swift app. Unknown JSON fields and
/// original file bytes are retained, including provider/account session identity.
pub struct Store {
    db: Connection,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThreadSummary {
    pub id: String,
    pub title: String,
    pub project_id: String,
    pub archived: bool,
    pub pinned: bool,
    #[serde(default)]
    pub snoozed_until: Option<f64>,
}

#[derive(Debug, Default, Serialize)]
pub struct ImportReport {
    pub threads: usize,
    pub files: usize,
    pub bytes: usize,
}

impl Store {
    /// The directory of this isolated store, never the legacy application root.
    pub fn data_directory(&self) -> Result<std::path::PathBuf> {
        let path = self.db.path().context("Store has no filesystem location")?;
        let parent = Path::new(path)
            .parent()
            .context("Store has no parent directory")?;
        Ok(parent.canonicalize()?)
    }

    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            let existed = parent.exists();
            fs::create_dir_all(parent)?;
            #[cfg(unix)]
            if !existed {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
            }
        }
        if let Ok(meta) = fs::symlink_metadata(path) {
            ensure!(
                !meta.file_type().is_symlink(),
                "Database cannot be a symlink"
            );
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            fs::OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .mode(0o600)
                .open(path)?;
        }
        let mut db = Connection::open(path)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        // Inspect the version before any schema/journal write. A newer or unrelated
        // database is never silently adopted or partially changed.
        let has_metadata: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='metadata')",
            [],
            |r| r.get(0),
        )?;
        let version = if has_metadata {
            let version: String =
                db.query_row("SELECT value FROM metadata WHERE key='schema'", [], |r| {
                    r.get(0)
                })?;
            ensure!(
                matches!(version.as_str(), "1" | "2" | "3"),
                "Unsupported Coincide database version: {version}"
            );
            version
        } else {
            let count:i64=db.query_row("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",[],|r|r.get(0))?;
            ensure!(count == 0, "This is not a Coincide database");
            "0".to_owned()
        };
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")?;
        if version != "2" && version != "3" {
            let tx = db.transaction()?;
            tx.execute_batch("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS original_files(path TEXT PRIMARY KEY, data BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS threads(id TEXT PRIMARY KEY, document TEXT NOT NULL CHECK(json_valid(document)));
                CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(thread_id UNINDEXED, title, body);
                CREATE TABLE IF NOT EXISTS thread_summaries(id TEXT PRIMARY KEY COLLATE NOCASE, title TEXT NOT NULL, project_id TEXT NOT NULL, archived INTEGER NOT NULL, pinned INTEGER NOT NULL, updated_at REAL NOT NULL, search_body TEXT NOT NULL, snoozed_until REAL);
                CREATE INDEX IF NOT EXISTS thread_summaries_order ON thread_summaries(archived,pinned DESC,updated_at DESC);
                CREATE INDEX IF NOT EXISTS thread_summaries_project ON thread_summaries(project_id);
                CREATE VIRTUAL TABLE IF NOT EXISTS search_trigram USING fts5(thread_id UNINDEXED, body, tokenize='trigram case_sensitive 1');
                CREATE TABLE IF NOT EXISTS documents(name TEXT PRIMARY KEY, document TEXT NOT NULL CHECK(json_valid(document)));
                CREATE TABLE IF NOT EXISTS imported_threads(id TEXT PRIMARY KEY COLLATE NOCASE);")?;
            let duplicates: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM threads GROUP BY lower(id) HAVING count(*)>1)",
                [],
                |r| r.get(0),
            )?;
            ensure!(!duplicates, "Thread IDs differ only by letter case");
            let mut stmt = tx.prepare("SELECT id,document FROM threads")?;
            let rows =
                stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
            for row in rows {
                let (stored_id, document) = row?;
                let value: Value = serde_json::from_str(&document)?;
                ensure!(
                    validate_thread(&value)? == stored_id,
                    "Thread row ID differs from its document"
                );
                cache_thread(&tx, &value, true)?;
            }
            drop(stmt);
            // Capture import identity once; runtime checks no longer scan every
            // original transcript BLOB to decide whether a session is imported.
            tx.execute("INSERT INTO imported_threads(id) SELECT json_extract(CAST(data AS TEXT),'$.id') FROM original_files WHERE path LIKE 'threads/%.json' AND json_valid(CAST(data AS TEXT)) AND json_type(CAST(data AS TEXT),'$.id')='text'",[])?;
            tx.execute("INSERT INTO metadata(key,value) VALUES ('schema','3') ON CONFLICT(key) DO UPDATE SET value='3'",[])?;
            tx.commit()?;
        }
        if version == "2" {
            let tx = db.transaction()?;
            tx.execute(
                "ALTER TABLE thread_summaries ADD COLUMN snoozed_until REAL",
                [],
            )?;
            {
                let mut stmt = tx.prepare("SELECT id,document FROM threads")?;
                let rows =
                    stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
                for row in rows {
                    let (id, document) = row?;
                    let value: Value = serde_json::from_str(&document)?;
                    ensure!(
                        validate_thread(&value)? == id,
                        "Thread row ID differs from its document"
                    );
                    tx.execute(
                        "UPDATE thread_summaries SET snoozed_until=?2 WHERE id=?1",
                        params![id, snooze_timestamp(&value["snoozedUntil"])],
                    )?;
                }
            }
            tx.execute("UPDATE metadata SET value='3' WHERE key='schema'", [])?;
            tx.commit()?;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        }
        Ok(Self { db })
    }

    /// Import into an empty database only. Repeating this never overwrites Rust edits.
    /// All selected files are captured in a single transaction; any invalid thread
    /// rolls it back. The source is never opened for writing. Runtime sockets and
    /// running process directories are deliberately excluded.
    pub fn import_legacy(&mut self, source: &Path) -> Result<ImportReport> {
        ensure!(
            !fs::symlink_metadata(source)?.file_type().is_symlink(),
            "Migration source cannot be a symlink"
        );
        ensure!(
            source.join("threads").is_dir(),
            "Source has no threads directory"
        );
        let count: i64 = self
            .db
            .query_row("SELECT count(*) FROM threads", [], |r| r.get(0))?;
        let imported: bool = self.db.query_row(
            "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='legacy_source')",
            [],
            |r| r.get(0),
        )?;
        ensure!(
            count == 0 && !imported,
            "Import requires a new empty Rust database"
        );
        let tx = self.db.transaction()?;
        let mut report = ImportReport::default();
        let mut paths = Vec::new();
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.ends_with(".json") {
                let kind = entry.file_type()?;
                ensure!(!kind.is_symlink(), "Migration refuses symlink: {name}");
                if kind.is_file() {
                    paths.push(entry.path());
                }
            }
        }
        for name in [
            "threads",
            "attachments",
            "ImportedSessions",
            "checkpoints",
            "task-records",
        ] {
            let path = source.join(name);
            if path.exists() {
                collect_files(&path, &mut paths)?;
            }
        }
        paths.sort();
        for path in paths {
            let relative = path
                .strip_prefix(source)?
                .to_str()
                .context("Non UTF-8 source filename")?
                .replace('\\', "/");
            let bytes = fs::read(&path).with_context(|| format!("Reading {relative}"))?;
            if relative.starts_with("threads/") && relative.ends_with(".json") {
                let value: Value = serde_json::from_slice(&bytes)
                    .with_context(|| format!("Invalid thread {relative}"))?;
                let id = validate_thread(&value)?;
                // Duplicate identities are a migration error, never last-file-wins.
                tx.execute(
                    "INSERT INTO threads(id, document) VALUES (?1, ?2)",
                    params![id, value.to_string()],
                )?;
                index_thread(&tx, &value)?;
                cache_thread(&tx, &value, true)?;
                tx.execute("INSERT INTO imported_threads(id) VALUES (?1)", [id])?;
                report.threads += 1;
            }
            tx.execute(
                "INSERT INTO original_files(path,data) VALUES (?1,?2)",
                params![relative, bytes],
            )?;
            report.files += 1;
            report.bytes += bytes.len();
        }
        tx.execute(
            "INSERT INTO metadata VALUES ('legacy_source', ?1)",
            [source.canonicalize()?.to_string_lossy().as_ref()],
        )?;
        tx.commit()?;
        Ok(report)
    }

    /// Sidebar reads touch only cached scalar metadata. Search uses the trigram
    /// index for queries of three or more Unicode characters, with a literal
    /// substring recheck; short queries scan cached text, never JSON transcripts.
    pub fn summaries(&self, query: &str, include_archived: bool) -> Result<Vec<ThreadSummary>> {
        let query = query.trim().to_lowercase();
        let indexed = query.chars().count() >= 3;
        let filter = if query.is_empty() {
            ""
        } else if indexed {
            " AND id IN (SELECT thread_id FROM search_trigram WHERE body MATCH ?2) AND instr(search_body,?3)>0"
        } else {
            " AND instr(search_body,?2)>0"
        };
        let sql = format!(
            "SELECT id,title,project_id,archived,pinned,snoozed_until FROM thread_summaries WHERE (?1 OR archived=0){filter} ORDER BY pinned DESC,updated_at DESC,id"
        );
        let mut stmt = self.db.prepare(&sql)?;
        let mapper = |r: &rusqlite::Row<'_>| {
            Ok(ThreadSummary {
                id: r.get(0)?,
                title: r.get(1)?,
                project_id: r.get(2)?,
                archived: r.get(3)?,
                pinned: r.get(4)?,
                snoozed_until: r.get(5)?,
            })
        };
        let result = if query.is_empty() {
            stmt.query_map([include_archived], mapper)?
                .collect::<rusqlite::Result<Vec<_>>>()?
        } else if indexed {
            let phrase = format!("\"{}\"", query.replace('"', "\"\""));
            stmt.query_map(params![include_archived, phrase, query], mapper)?
                .collect::<rusqlite::Result<Vec<_>>>()?
        } else {
            stmt.query_map(params![include_archived, query], mapper)?
                .collect::<rusqlite::Result<Vec<_>>>()?
        };
        Ok(result)
    }

    pub fn thread(&self, id: &str) -> Result<Value> {
        let document: String =
            self.db
                .query_row("SELECT document FROM threads WHERE id=?1", [id], |r| {
                    r.get(0)
                })?;
        Ok(serde_json::from_str(&document)?)
    }

    pub fn save(&mut self, document: &Value) -> Result<()> {
        let id = validate_thread(document)?;
        let existing: Option<String> = self
            .db
            .query_row(
                "SELECT id FROM threads WHERE id=?1 COLLATE NOCASE",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        ensure!(
            existing.as_deref().is_none_or(|stored| stored == id),
            "Thread ID differs only by letter case from an existing thread"
        );
        let tx = self.db.transaction()?;
        tx.execute("INSERT INTO threads(id,document) VALUES (?1,?2) ON CONFLICT(id) DO UPDATE SET document=excluded.document", params![id,document.to_string()])?;
        let body = search_text(document).to_lowercase();
        let indexed: Option<String> = tx
            .query_row(
                "SELECT search_body FROM thread_summaries WHERE id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        let reindex = indexed.as_deref() != Some(body.as_str());
        if reindex {
            tx.execute("DELETE FROM search WHERE thread_id=?1", [id])?;
            index_thread(&tx, document)?;
        }
        cache_thread(&tx, document, reindex)?;
        tx.commit()?;
        Ok(())
    }

    pub fn new_thread(&mut self, project_id: &str) -> Result<Value> {
        let id = Uuid::new_v4().to_string().to_uppercase();
        let now = swift_timestamp();
        let v = json!({"id":id,"projectID":project_id,"title":"New conversation","createdAt":now,"updatedAt":now,
            "selection":{"provider":"claude","modelID":"default"},"accessMode":"approval","interactionMode":"build",
            "items":[],"sessions":{},"isPinned":false,"isArchived":false,"draft":""});
        self.save(&v)?;
        Ok(v)
    }

    pub fn is_imported(&self, id: &str) -> Result<bool> {
        Ok(self.db.query_row(
            "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1)",
            [id],
            |r| r.get(0),
        )?)
    }

    pub fn original(&self, path: &str) -> Result<Option<Vec<u8>>> {
        Ok(self
            .db
            .query_row(
                "SELECT data FROM original_files WHERE path=?1",
                [path],
                |r| r.get(0),
            )
            .optional()?)
    }

    /// Patch supported fields without rebuilding transcript search indexes for
    /// drafts and flags.
    pub fn patch_thread(&mut self, id: &str, patch: &Value) -> Result<Value> {
        let patch = patch
            .as_object()
            .context("Thread patch must be an object")?;
        validate_patch(patch)?;
        let mut value = self.thread(id)?;
        for (key, next) in patch {
            value[key] = next.clone();
        }
        let reindex = patch.contains_key("title");
        let tx = self.db.transaction()?;
        tx.execute(
            "UPDATE threads SET document=?2 WHERE id=?1",
            params![id, value.to_string()],
        )?;
        cache_thread(&tx, &value, reindex)?;
        if reindex {
            tx.execute("DELETE FROM search WHERE thread_id=?1", [id])?;
            index_thread(&tx, &value)?;
        }
        tx.commit()?;
        Ok(value)
    }

    pub fn document(&self, name: &str) -> Result<Option<Value>> {
        validate_document_name(name)?;
        let current: Option<String> = self
            .db
            .query_row(
                "SELECT document FROM documents WHERE name=?1",
                [name],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(current) = current {
            return Ok(Some(serde_json::from_str(&current)?));
        }
        self.original(name)?
            .map(|bytes| {
                serde_json::from_slice(&bytes)
                    .context("Original document is invalid; refusing to replace it")
            })
            .transpose()
    }
    pub fn save_document(&mut self, name: &str, value: &Value) -> Result<()> {
        validate_document_name(name)?;
        // An unreadable original must never be silently discarded by a save.
        self.document(name)?;
        self.db.execute("INSERT INTO documents(name,document) VALUES (?1,?2) ON CONFLICT(name) DO UPDATE SET document=excluded.document",params![name,value.to_string()])?;
        Ok(())
    }
    pub fn patch_document(&mut self, name: &str, patch: &Value) -> Result<Value> {
        let patch = patch
            .as_object()
            .context("Document patch must be an object")?;
        let mut value = self.document(name)?.unwrap_or_else(|| json!({}));
        let object = value
            .as_object_mut()
            .context("Stored document is not an object")?;
        for (key, next) in patch {
            object.insert(key.clone(), next.clone());
        }
        self.save_document(name, &value)?;
        Ok(value)
    }
    pub fn projects(&self) -> Result<Value> {
        let projects = self.document("projects.json")?.unwrap_or_else(|| json!([]));
        ensure!(
            projects.is_array(),
            "Stored projects document is not an array"
        );
        Ok(projects)
    }
    pub fn create_project(&mut self, path: &Path, name: Option<&str>) -> Result<Value> {
        ensure!(path.is_dir(), "Project directory does not exist");
        let canonical = path.canonicalize()?;
        let path = canonical.to_str().context("Project path is not UTF-8")?;
        let mut projects = self.projects()?;
        let entries = projects.as_array_mut().context("Invalid projects")?;
        if let Some(existing) = entries.iter().find(|p| {
            p["path"]
                .as_str()
                .is_some_and(|old| Path::new(old).canonicalize().is_ok_and(|p| p == canonical))
        }) {
            return Ok(existing.clone());
        }
        let name = name
            .unwrap_or_else(|| {
                canonical
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("Project")
            })
            .trim();
        ensure!(
            !name.is_empty() && name.len() <= 1024,
            "Project name must be 1–1024 bytes"
        );
        let project = json!({"id":Uuid::new_v4().to_string().to_uppercase(),"name":name,"path":path,"createdAt":swift_timestamp(),"isExpanded":true,"scripts":[],"isChats":false,"isBots":false});
        let index = entries
            .iter()
            .position(|p| p["isChats"] == true)
            .unwrap_or(entries.len());
        entries.insert(index, project.clone());
        self.save_document("projects.json", &projects)?;
        Ok(project)
    }
    pub fn patch_project(&mut self, id: &str, patch: &Value) -> Result<Value> {
        let patch = patch
            .as_object()
            .context("Project patch must be an object")?;
        for (key, value) in patch {
            match key.as_str() {
                "name" => ensure!(
                    value
                        .as_str()
                        .is_some_and(|s| !s.trim().is_empty() && s.len() <= 1024),
                    "Invalid project name"
                ),
                "isExpanded" => ensure!(value.is_boolean(), "isExpanded must be boolean"),
                // Path changes require orchestration of live sessions and worktrees;
                // this storage endpoint deliberately does not move running projects.
                _ => bail!("Unsupported project patch field: {key}"),
            }
        }
        let mut projects = self.projects()?;
        let project = projects
            .as_array_mut()
            .context("Invalid projects")?
            .iter_mut()
            .find(|p| p["id"] == id)
            .context("Project not found")?;
        for (key, value) in patch {
            project[key] = value.clone();
        }
        let result = project.clone();
        self.save_document("projects.json", &projects)?;
        Ok(result)
    }
    pub fn remove_project(&mut self, id: &str) -> Result<()> {
        let count: i64 = self.db.query_row(
            "SELECT count(*) FROM thread_summaries WHERE project_id=?1",
            [id],
            |r| r.get(0),
        )?;
        ensure!(
            count == 0,
            "Move or remove the project's conversations first"
        );
        let mut projects = self.projects()?;
        let entries = projects.as_array_mut().context("Invalid projects")?;
        let index = entries
            .iter()
            .position(|p| p["id"] == id)
            .context("Project not found")?;
        ensure!(
            entries[index]["isChats"] != true && entries[index]["isBots"] != true,
            "Cannot remove a system project"
        );
        entries.remove(index);
        self.save_document("projects.json", &projects)
    }
}

fn validate_document_name(name: &str) -> Result<()> {
    ensure!(
        name.len() <= 128
            && name.ends_with(".json")
            && !name.starts_with('.')
            && name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c)),
        "Invalid document name"
    );
    Ok(())
}
fn validate_patch(patch: &serde_json::Map<String, Value>) -> Result<()> {
    for (key, value) in patch {
        match key.as_str() {
            "title" | "draft" => ensure!(value.is_string(), "{key} must be text"),
            "isPinned" | "isArchived" => ensure!(value.is_boolean(), "{key} must be boolean"),
            "snoozedUntil" => ensure!(
                value.is_null() || snooze_timestamp(value).is_some(),
                "Invalid snooze date"
            ),
            _ => bail!("Unsupported thread patch field: {key}"),
        }
    }
    Ok(())
}
fn snooze_timestamp(value: &Value) -> Option<f64> {
    value.as_f64().filter(|n| n.is_finite()).or_else(|| {
        chrono::DateTime::parse_from_rfc3339(value.as_str()?)
            .ok()
            .map(|date| date.timestamp_millis() as f64 / 1000.0 - 978307200.0)
    })
}
fn cache_thread(db: &Connection, v: &Value, reindex: bool) -> Result<()> {
    let id = validate_thread(v)?;
    let updated = if let Some(n) = v["updatedAt"].as_f64() {
        n + 978307200.0
    } else if let Some(date) = v["updatedAt"].as_str() {
        db.query_row("SELECT coalesce(unixepoch(?1),0)", [date], |r| {
            r.get::<_, f64>(0)
        })?
    } else {
        0.0
    };
    if reindex {
        let body = search_text(v).to_lowercase();
        db.execute("INSERT INTO thread_summaries(id,title,project_id,archived,pinned,updated_at,search_body,snoozed_until) VALUES (?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT(id) DO UPDATE SET title=excluded.title,project_id=excluded.project_id,archived=excluded.archived,pinned=excluded.pinned,updated_at=excluded.updated_at,search_body=excluded.search_body,snoozed_until=excluded.snoozed_until",params![id,text(v,"title"),text(v,"projectID"),v["isArchived"].as_bool().unwrap_or(false),v["isPinned"].as_bool().unwrap_or(false),updated,body,snooze_timestamp(&v["snoozedUntil"])])?;
        db.execute("DELETE FROM search_trigram WHERE thread_id=?1", [id])?;
        db.execute(
            "INSERT INTO search_trigram(thread_id,body) VALUES (?1,?2)",
            params![id, body],
        )?;
    } else {
        db.execute("UPDATE thread_summaries SET title=?2,project_id=?3,archived=?4,pinned=?5,updated_at=?6,snoozed_until=?7 WHERE id=?1",params![id,text(v,"title"),text(v,"projectID"),v["isArchived"].as_bool().unwrap_or(false),v["isPinned"].as_bool().unwrap_or(false),updated,snooze_timestamp(&v["snoozedUntil"])])?;
    }
    Ok(())
}

fn collect_files(path: &Path, result: &mut Vec<std::path::PathBuf>) -> Result<()> {
    let meta = fs::symlink_metadata(path)?;
    ensure!(
        !meta.file_type().is_symlink(),
        "Migration refuses symlink: {}",
        path.display()
    );
    if meta.is_file() {
        result.push(path.to_owned());
    } else if meta.is_dir() {
        for e in fs::read_dir(path)? {
            collect_files(&e?.path(), result)?;
        }
    } else {
        bail!("Unsupported migration file: {}", path.display());
    }
    Ok(())
}

fn validate_thread(v: &Value) -> Result<&str> {
    let id = v["id"].as_str().context("Thread has no ID")?;
    Uuid::parse_str(id).context("Thread ID is not a UUID")?;
    ensure!(v["items"].is_array(), "Thread has no items array");
    Ok(id)
}

fn index_thread(db: &Connection, v: &Value) -> Result<()> {
    db.execute(
        "INSERT INTO search(thread_id,title,body) VALUES (?1,?2,?3)",
        params![text(v, "id"), text(v, "title"), search_text(v)],
    )?;
    Ok(())
}

fn search_text(v: &Value) -> String {
    let mut text = text(v, "title");
    if let Some(items) = v["items"].as_array() {
        for item in items {
            text.push('\n');
            text.push_str(item["text"].as_str().unwrap_or(""));
        }
    }
    text
}

pub fn text(v: &Value, key: &str) -> String {
    v[key].as_str().unwrap_or("").to_owned()
}
pub fn swift_timestamp() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
        - 978307200.0
}

#[cfg(test)]
mod tests {
    use super::*;
    const ID: &str = "52F19AE7-6B00-45C6-B4C7-13F03E3A3EF2";
    fn setup() -> (tempfile::TempDir, std::path::PathBuf, Store) {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("swift");
        fs::create_dir_all(source.join("threads")).unwrap();
        let db = Store::open(&dir.path().join("rust/store.sqlite")).unwrap();
        (dir, source, db)
    }
    #[test]
    fn import_preserves_bytes_unknown_fields_sessions_and_source() {
        let (_dir, source, mut db) = setup();
        let raw = format!(
            r#"{{ "id":"{ID}", "title":"Test", "items":[{{"kind":"future","text":"searchable"}}], "sessions":["codex",{{"sessionID":"native-1","seenItemCount":1}}], "unknown":{{"a":2}}, "draft":"unsent" }}"#
        );
        fs::write(source.join("threads/test.json"), &raw).unwrap();
        fs::create_dir(source.join("attachments")).unwrap();
        fs::write(source.join("attachments/photo.bin"), [0, 255, 3]).unwrap();
        let report = db.import_legacy(&source).unwrap();
        assert_eq!(report.threads, 1);
        assert_eq!(
            db.original("threads/test.json").unwrap().unwrap(),
            raw.as_bytes()
        );
        assert_eq!(
            db.original("attachments/photo.bin").unwrap().unwrap(),
            [0, 255, 3]
        );
        let mut v = db.thread(ID).unwrap();
        v["draft"] = json!("edited");
        db.save(&v).unwrap();
        assert_eq!(db.thread(ID).unwrap()["unknown"], json!({"a":2}));
        assert_eq!(
            db.thread(ID).unwrap()["sessions"][1]["sessionID"],
            "native-1"
        );
        assert_eq!(
            fs::read_to_string(source.join("threads/test.json")).unwrap(),
            raw
        );
        assert_eq!(db.summaries("searchable", false).unwrap().len(), 1);
        assert!(db.import_legacy(&source).is_err());
        assert_eq!(db.thread(ID).unwrap()["draft"], "edited");
    }
    #[test]
    fn malformed_thread_rolls_back_entire_import() {
        let (_dir, source, mut db) = setup();
        fs::write(
            source.join("threads/a.json"),
            json!({"id":ID,"items":[]}).to_string(),
        )
        .unwrap();
        fs::write(source.join("threads/z.json"), "broken").unwrap();
        assert!(db.import_legacy(&source).is_err());
        assert!(db.summaries("", true).unwrap().is_empty());
        assert!(db.original("threads/a.json").unwrap().is_none());
    }
    #[test]
    fn duplicate_thread_id_is_never_silently_overwritten() {
        let (_dir, source, mut db) = setup();
        for name in ["a.json", "b.json"] {
            fs::write(
                source.join("threads").join(name),
                json!({"id":ID,"items":[]}).to_string(),
            )
            .unwrap();
        }
        assert!(db.import_legacy(&source).is_err());
        assert!(db.summaries("", true).unwrap().is_empty());
    }
    #[cfg(unix)]
    #[test]
    fn refuses_symlinked_attachments() {
        let (dir, source, mut db) = setup();
        fs::write(dir.path().join("private"), "not an attachment").unwrap();
        fs::create_dir(source.join("attachments")).unwrap();
        std::os::unix::fs::symlink(dir.path().join("private"), source.join("attachments/link"))
            .unwrap();
        assert!(db.import_legacy(&source).is_err());
    }
    #[test]
    fn metadata_patch_preserves_unknown_content_without_touching_search() {
        let (_dir, _source, mut db) = setup();
        let v = json!({"id":ID,"items":[{"kind":"future","text":"Durable searchable transcript","future":42}],"title":"Before","draftContext":[{"kind":"new-kind","opaque":true}],"sessions":["codex",{"sessionID":"native","future":3}]});
        db.save(&v).unwrap();
        let before = db.db.total_changes();
        let changed = db
            .patch_thread(ID, &json!({"draft":"new draft","isPinned":true}))
            .unwrap();
        // Two ordinary row updates; FTS maintenance would change additional rows.
        assert_eq!(db.db.total_changes() - before, 2);
        assert_eq!(changed["items"], v["items"]);
        assert_eq!(changed["sessions"], v["sessions"]);
        assert_eq!(changed["draftContext"], v["draftContext"]);
        assert_eq!(db.summaries("searchable", false).unwrap().len(), 1);
        assert!(
            db.patch_thread(ID, &json!({"draft":"lost","sessions":{}}))
                .is_err()
        );
        assert_eq!(db.thread(ID).unwrap()["draft"], "new draft");
    }

    #[test]
    fn cached_search_is_literal_unicode_and_does_not_read_thread_documents() {
        let (_dir, _source, mut db) = setup();
        db.save(&json!({"id":ID,"title":"Привет Café","items":[{"text":"A quoted \"needle\" and foo.bar"}],"isArchived":false})).unwrap();
        for query in ["ПРИВЕТ", "CAFÉ", "foo.bar", "\"needle\"", "fé"] {
            assert_eq!(db.summaries(query, false).unwrap().len(), 1, "{query}");
        }
        assert!(db.summaries("x OR y", false).unwrap().is_empty());
        // A cache-only listing must not select/parse the transcript table.
        db.db.execute("DROP TABLE threads", []).unwrap();
        assert_eq!(db.summaries("", false).unwrap().len(), 1);
        assert_eq!(db.summaries("foo.bar", false).unwrap().len(), 1);
    }

    #[test]
    fn dates_sort_consistently_between_swift_iso_and_numeric_preview_dates() {
        let (_dir, _source, mut db) = setup();
        let later = "11111111-1111-4111-8111-111111111111";
        db.save(&json!({"id":ID,"title":"Earlier","items":[],"updatedAt":"2026-01-01T00:00:00Z"}))
            .unwrap();
        db.save(&json!({"id":later,"title":"Later","items":[],"updatedAt":788918401.0}))
            .unwrap();
        // 2026-01-01T00:00:01Z expressed relative to Apple's 2001 epoch.
        assert_eq!(db.summaries("", false).unwrap()[0].id, later);
    }

    #[test]
    fn project_edits_preserve_source_and_unknown_fields_and_refuse_orphans() {
        let (dir, source, mut db) = setup();
        let project_id = "11111111-1111-4111-8111-111111111111";
        let original=json!([{"id":project_id,"name":"Old name","path":dir.path(),"future":{"retain":true},"scripts":[{"opaque":1}]}]).to_string();
        fs::write(source.join("projects.json"), &original).unwrap();
        db.import_legacy(&source).unwrap();
        let edited = db
            .patch_project(project_id, &json!({"name":"New name"}))
            .unwrap();
        assert_eq!(edited["future"], json!({"retain":true}));
        assert_eq!(edited["scripts"], json!([{"opaque":1}]));
        assert_eq!(
            db.original("projects.json").unwrap().unwrap(),
            original.as_bytes()
        );
        assert_eq!(
            db.create_project(dir.path(), Some("Duplicate")).unwrap()["id"],
            project_id
        );
        db.new_thread(project_id).unwrap();
        assert!(db.remove_project(project_id).is_err());
        assert_eq!(db.projects().unwrap().as_array().unwrap().len(), 1);
    }

    #[test]
    fn document_patch_keeps_unknown_settings_and_refuses_malformed_original() {
        let (_dir, source, mut db) = setup();
        fs::write(
            source.join("settings.json"),
            r#"{"appearance":"system","future":{"keep":true}}"#,
        )
        .unwrap();
        fs::write(source.join("broken.json"), "invalid").unwrap();
        db.import_legacy(&source).unwrap();
        let updated = db
            .patch_document("settings.json", &json!({"appearance":"dark"}))
            .unwrap();
        assert_eq!(updated["future"], json!({"keep":true}));
        assert!(db.save_document("broken.json", &json!({})).is_err());
        assert!(db.save_document("../outside.json", &json!({})).is_err());
        assert_eq!(db.original("broken.json").unwrap().unwrap(), b"invalid");
    }

    #[test]
    fn unknown_schema_and_foreign_database_are_rejected_without_schema_writes() {
        let dir = tempfile::tempdir().unwrap();
        for (name, sql) in [
            (
                "future",
                "CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT); INSERT INTO metadata VALUES('schema','99');",
            ),
            (
                "foreign",
                "CREATE TABLE valuable(data TEXT); INSERT INTO valuable VALUES('preserve');",
            ),
        ] {
            let path = dir.path().join(name);
            {
                let db = Connection::open(&path).unwrap();
                db.execute_batch(sql).unwrap();
            }
            let before = fs::read(&path).unwrap();
            assert!(Store::open(&path).is_err());
            assert_eq!(fs::read(&path).unwrap(), before);
        }
    }

    #[test]
    fn v1_migration_keeps_original_bytes_and_rebuilds_caches_atomically() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v1.sqlite");
        let original = format!(
            r#"{{ "id":"{ID}", "title":"Migrated", "items":[{{"kind":"future","text":"migration needle"}}], "unknown":7 }}"#
        );
        {
            let old = Connection::open(&path).unwrap();
            old.execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL); INSERT INTO metadata VALUES('schema','1'); CREATE TABLE threads(id TEXT PRIMARY KEY,document TEXT); CREATE TABLE original_files(path TEXT PRIMARY KEY,data BLOB);").unwrap();
            old.execute("INSERT INTO threads VALUES(?1,?2)", params![ID, original])
                .unwrap();
            old.execute(
                "INSERT INTO original_files VALUES('threads/source.json',?1)",
                [original.as_bytes()],
            )
            .unwrap();
        }
        let mut db = Store::open(&path).unwrap();
        assert!(db.is_imported(ID).unwrap());
        assert_eq!(db.summaries("needle", false).unwrap().len(), 1);
        assert_eq!(
            db.original("threads/source.json").unwrap().unwrap(),
            original.as_bytes()
        );
        db.patch_thread(ID, &json!({"draft":"kept"})).unwrap();
        assert_eq!(db.thread(ID).unwrap()["unknown"], 7);
        drop(db);
        let reopened = Store::open(&path).unwrap();
        assert_eq!(reopened.thread(ID).unwrap()["draft"], "kept");
    }

    #[test]
    fn invalid_v1_migration_rolls_back_schema_and_rows() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("invalid.sqlite");
        {
            let old = Connection::open(&path).unwrap();
            old.execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL); INSERT INTO metadata VALUES('schema','1'); CREATE TABLE threads(id TEXT PRIMARY KEY,document TEXT); CREATE TABLE original_files(path TEXT PRIMARY KEY,data BLOB); INSERT INTO threads VALUES('broken','{}');").unwrap();
        }
        assert!(Store::open(&path).is_err());
        let db = Connection::open(&path).unwrap();
        assert_eq!(
            db.query_row("SELECT value FROM metadata WHERE key='schema'", [], |r| {
                r.get::<_, String>(0)
            })
            .unwrap(),
            "1"
        );
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM sqlite_master WHERE name='thread_summaries'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            0
        );
        assert_eq!(
            db.query_row("SELECT document FROM threads", [], |r| r
                .get::<_, String>(0))
                .unwrap(),
            "{}"
        );
    }
    #[test]
    fn snooze_cache_migrates_v2_and_tracks_patches_without_transcript_reads() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v2.sqlite");
        let mut store = Store::open(&path).unwrap();
        store.save(&json!({"id":ID,"title":"Snoozed","items":[],"snoozedUntil":"2026-01-01T00:00:01Z","future":42})).unwrap();
        store.db.execute_batch("ALTER TABLE thread_summaries DROP COLUMN snoozed_until; UPDATE metadata SET value='2' WHERE key='schema';").unwrap();
        let original = store.thread(ID).unwrap();
        drop(store);
        let mut store = Store::open(&path).unwrap();
        assert_eq!(
            store.summaries("", false).unwrap()[0].snoozed_until,
            Some(788918401.0)
        );
        assert_eq!(store.thread(ID).unwrap(), original);
        assert!(
            store
                .patch_thread(ID, &json!({"snoozedUntil":"not a date"}))
                .is_err()
        );
        store
            .patch_thread(ID, &json!({"snoozedUntil":123.0}))
            .unwrap();
        assert_eq!(
            store.summaries("", false).unwrap()[0].snoozed_until,
            Some(123.0)
        );
        store
            .patch_thread(ID, &json!({"snoozedUntil":null}))
            .unwrap();
        store.db.execute("DROP TABLE threads", []).unwrap();
        assert_eq!(store.summaries("", false).unwrap()[0].snoozed_until, None);
    }
    #[test]
    fn failed_v2_migration_rolls_back_snooze_column_and_version() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("invalid-v2.sqlite");
        let mut store = Store::open(&path).unwrap();
        store
            .save(&json!({"id":ID,"title":"Preserve","items":[]}))
            .unwrap();
        store.db.execute_batch("ALTER TABLE thread_summaries DROP COLUMN snoozed_until; UPDATE metadata SET value='2' WHERE key='schema'; UPDATE threads SET document='{}';").unwrap();
        drop(store);
        assert!(Store::open(&path).is_err());
        let db = Connection::open(&path).unwrap();
        assert_eq!(
            db.query_row("SELECT value FROM metadata WHERE key='schema'", [], |r| {
                r.get::<_, String>(0)
            })
            .unwrap(),
            "2"
        );
        assert_eq!(db.query_row("SELECT count(*) FROM pragma_table_info('thread_summaries') WHERE name='snoozed_until'",[],|r|r.get::<_,u32>(0)).unwrap(),0);
    }
}
