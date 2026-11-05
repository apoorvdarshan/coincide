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
}

#[derive(Debug, Default, Serialize)]
pub struct ImportReport {
    pub threads: usize,
    pub files: usize,
    pub bytes: usize,
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let db = Connection::open(path)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS original_files(path TEXT PRIMARY KEY, data BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS threads(id TEXT PRIMARY KEY, document TEXT NOT NULL CHECK(json_valid(document)));
            CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(thread_id UNINDEXED, title, body);
            INSERT OR IGNORE INTO metadata VALUES ('schema', '1');")?;
        let schema: String =
            db.query_row("SELECT value FROM metadata WHERE key='schema'", [], |r| {
                r.get(0)
            })?;
        ensure!(schema == "1", "Unsupported Coincide database version");
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
            if name.ends_with(".json") && entry.file_type()?.is_file() {
                paths.push(entry.path());
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

    pub fn summaries(&self, query: &str, include_archived: bool) -> Result<Vec<ThreadSummary>> {
        let mut stmt = self.db.prepare("SELECT document FROM threads ORDER BY json_extract(document,'$.isPinned') DESC, json_extract(document,'$.updatedAt') DESC")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        let query = query.trim().to_lowercase();
        let mut result = Vec::new();
        for row in rows {
            let v: Value = serde_json::from_str(&row?)?;
            let archived = v["isArchived"].as_bool().unwrap_or(false);
            if archived && !include_archived {
                continue;
            }
            if !query.is_empty() && !search_text(&v).to_lowercase().contains(&query) {
                continue;
            }
            result.push(ThreadSummary {
                id: text(&v, "id"),
                title: text(&v, "title"),
                project_id: text(&v, "projectID"),
                archived,
                pinned: v["isPinned"].as_bool().unwrap_or(false),
            });
        }
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
        let tx = self.db.transaction()?;
        tx.execute("INSERT INTO threads(id,document) VALUES (?1,?2) ON CONFLICT(id) DO UPDATE SET document=excluded.document", params![id,document.to_string()])?;
        tx.execute("DELETE FROM search WHERE thread_id=?1", [id])?;
        index_thread(&tx, document)?;
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
        Ok(self.db.query_row("SELECT EXISTS(SELECT 1 FROM original_files WHERE path LIKE 'threads/%.json' AND json_extract(CAST(data AS TEXT),'$.id')=?1)", [id], |r| r.get(0))?)
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

    pub fn projects(&self) -> Result<Value> {
        match self.original("projects.json")? {
            Some(bytes) => Ok(serde_json::from_slice(&bytes)?),
            None => Ok(json!([])),
        }
    }
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
}
