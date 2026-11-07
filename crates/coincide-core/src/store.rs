#[path = "store_codex_profile_lifecycle.rs"]
mod codex_profile_lifecycle;
pub(crate) use codex_profile_lifecycle::CodexAuthChange;
#[path = "reply_selection_store.rs"]
mod reply_selection_store;
#[path = "store_thread_idle.rs"]
mod thread_idle;
pub(crate) use thread_idle::NewThreadRow;
#[path = "thread_navigation_cache.rs"]
mod navigation_cache;
#[path = "store_project_defaults.rs"]
mod project_defaults;
#[path = "store_project_scripts.rs"]
mod store_project_scripts;
pub use store_project_scripts::ScriptEdit;
#[path = "project_management.rs"]
mod project_management;
#[path = "store_provider_account_removal.rs"]
mod provider_account_removal;
#[path = "store_provider_accounts.rs"]
mod provider_accounts;
#[path = "store_follow_up.rs"]
mod store_follow_up;
#[path = "store_git_worktrees.rs"]
mod store_git_worktrees;
use anyhow::{Context, Result, bail, ensure};
pub(crate) use project_management::{PreparedProject, ProjectAction};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};
pub(crate) use store_follow_up::NativeUncertainty;
use uuid::Uuid;
#[path = "browser_history_store.rs"]
mod browser_history_store;
#[path = "composer_scope_store.rs"]
mod composer_scope_store;
pub(crate) use composer_scope_store::same_scope as same_composer_scope;
#[path = "composer_file_reference_store.rs"]
mod composer_file_reference_store;
#[path = "terminal_context_store.rs"]
mod terminal_context_store;
#[path = "thread_bulk_store.rs"]
mod thread_bulk_store;
pub(crate) use thread_bulk_store::FlagRow;
#[path = "store_inspector_preferences.rs"]
mod inspector_preferences;
#[path = "store_native_ui_selection.rs"]
mod native_ui_selection;
#[path = "store_sidebar_lifecycle.rs"]
mod sidebar_lifecycle;
pub(crate) use sidebar_lifecycle::SidebarRow;
#[path = "store_thread_delete.rs"]
mod store_thread_delete;
pub(crate) use store_thread_delete::bot_lifecycle::{BotLifecycle, BotLifecycleUndo};
use store_thread_delete::ensure_not_deleted;
pub use store_thread_delete::{ArchivedConversation, ArchivedConversations};
pub(crate) use store_thread_delete::{DeleteRow, DeleteVersion};

/// A new database is always independent of the Swift app. Unknown JSON fields and
/// original file bytes are retained, including provider/account session identity.
pub struct Store {
    db: Option<Connection>,
    selection_scopes: composer_scope_store::Scopes,
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
    /// Descriptive navigation only. Missing metadata preserves legacy summary JSON.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub navigation: Option<ThreadNavigation>,
}
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ThreadNavigation {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bot_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_count: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_draft: Option<bool>,
}

#[derive(Debug, Default, Serialize)]
pub struct ImportReport {
    pub threads: usize,
    pub files: usize,
    pub bytes: usize,
}

impl Store {
    /// Connection-local monotonic write counter for asynchronous compare-and-set
    /// intents. Detects a source/target changed and restored between polls.
    pub(crate) fn mutation_serial(&self) -> Result<u64> {
        Ok(self.connection()?.total_changes())
    }

    /// Runtime-only durable authority binding. Never exposed as a document or
    /// populated by imports; the journal also binds the live Store inode.
    #[cfg(any(unix, windows))]
    pub(crate) fn resume_source_path(&self) -> Result<std::path::PathBuf> {
        let path = self
            .connection()?
            .path()
            .context("Store has no filesystem location")?;
        Ok(Path::new(path).canonicalize()?)
    }
    fn connection(&self) -> Result<&Connection> {
        self.db.as_ref().context("Store is closed")
    }
    fn connection_mut(&mut self) -> Result<&mut Connection> {
        self.db.as_mut().context("Store is closed")
    }
    pub fn is_closed(&self) -> bool {
        self.db.is_none()
    }
    /// Trusted shutdown owner only. Failure retains the exact live connection;
    /// callers may explicitly retry after resolving outstanding SQLite handles.
    pub fn close_for_shutdown(&mut self) -> Result<()> {
        let Some(connection) = self.db.take() else {
            return Ok(());
        };
        match connection.close() {
            Ok(()) => Ok(()),
            Err((connection, error)) => {
                self.db = Some(connection);
                Err(error).context("Store close failed; connection retained")
            }
        }
    }

    /// The directory of this isolated store, never the legacy application root.
    pub fn data_directory(&self) -> Result<std::path::PathBuf> {
        self.connection()?;
        let path = self
            .connection()?
            .path()
            .context("Store has no filesystem location")?;
        let parent = Path::new(path)
            .parent()
            .context("Store has no parent directory")?;
        Ok(parent.canonicalize()?)
    }

    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            let existed = parent.exists();
            #[cfg(windows)]
            if !existed {
                if let Some(ancestor) = parent.parent() {
                    fs::create_dir_all(ancestor)?;
                }
                crate::private_fs::windows::create_directory(parent)?;
            }
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
        #[cfg(windows)]
        if fs::symlink_metadata(path)
            .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound)
        {
            // SQLite's default creator may assign Administrators ownership to
            // elevated Windows files. New native DBs use the same explicit
            // current-user owner/private DACL as other authority files.
            // Existing databases retain their exact permissions and contents.
            match crate::private_fs::windows::open_file(path, true) {
                Ok(file) => drop(file),
                Err(error)
                    if error
                        .downcast_ref::<std::io::Error>()
                        .is_some_and(|error| error.kind() == std::io::ErrorKind::AlreadyExists) =>
                {
                    crate::private_fs::windows::verify(path, false)?
                }
                Err(error) => return Err(error),
            }
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
            navigation_cache::create(&tx)?;
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
        navigation_cache::install(&mut db)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        }
        db.execute_batch("CREATE INDEX IF NOT EXISTS thread_summaries_snooze ON thread_summaries(snoozed_until) WHERE snoozed_until IS NOT NULL;")?;
        Ok(Self {
            db: Some(db),
            selection_scopes: Default::default(),
        })
    }

    /// Import into an empty database only. Repeating this never overwrites Rust edits.
    /// All selected files are captured in a single transaction; any invalid thread
    /// rolls it back. The source is never opened for writing. Runtime sockets and
    /// running process directories are deliberately excluded.
    pub fn import_legacy(&mut self, source: &Path) -> Result<ImportReport> {
        self.connection()?;
        ensure!(
            !fs::symlink_metadata(source)?.file_type().is_symlink(),
            "Migration source cannot be a symlink"
        );
        ensure!(
            source.join("threads").is_dir(),
            "Source has no threads directory"
        );
        let count: i64 = self
            .connection()?
            .query_row("SELECT count(*) FROM threads", [], |r| r.get(0))?;
        let imported: bool = self.connection()?.query_row(
            "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='legacy_source')",
            [],
            |r| r.get(0),
        )?;
        ensure!(
            count == 0 && !imported,
            "Import requires a new empty Rust database"
        );
        let tx = self.connection_mut()?.transaction()?;
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
                ensure_not_deleted(&tx, id)?;
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

    /// Add a captured CLI conversation without replacing existing data. The
    /// caller supplies the validated preview and exact captured source bytes;
    /// filesystem discovery and source freshness checks belong to that caller.
    /// Original bytes, transcript, execution barrier, and indexes commit together.
    pub fn import_cli_session(
        &mut self,
        document: &Value,
        source_key: &str,
        source: &[u8],
    ) -> Result<()> {
        self.connection()?;
        validate_cli_source_key(source_key)?;
        ensure!(
            !source.is_empty() && source.len() <= CLI_IMPORT_BYTES,
            "CLI source must contain 1 byte to 32 MiB of captured bytes"
        );
        validate_cli_thread(document)?;
        let id = validate_thread(document)?;
        let mut writer = ImportDocumentWriter(Vec::new());
        serde_json::to_writer(&mut writer, document)
            .context("CLI thread document exceeds its bounds or cannot be serialized")?;
        let serialized = String::from_utf8(writer.0)?;
        // Acquire the writer before duplicate checks. Two imports cannot race
        // through the case-insensitive check on the existing case-sensitive tables.
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure_not_deleted(&tx, id)?;
        let duplicate_id: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM threads WHERE id=?1 COLLATE NOCASE) OR EXISTS(SELECT 1 FROM imported_threads WHERE id=?1 COLLATE NOCASE) OR EXISTS(SELECT 1 FROM thread_summaries WHERE id=?1 COLLATE NOCASE)",
            [id], |row| row.get(0),
        )?;
        ensure!(
            !duplicate_id,
            "A conversation with this UUID already exists"
        );
        let duplicate_source: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM original_files WHERE path=?1 COLLATE NOCASE)",
            [source_key],
            |row| row.get(0),
        )?;
        ensure!(
            !duplicate_source,
            "This CLI source key was already imported"
        );
        tx.execute(
            "INSERT INTO original_files(path,data) VALUES (?1,?2)",
            params![source_key, source],
        )?;
        tx.execute(
            "INSERT INTO threads(id,document) VALUES (?1,?2)",
            params![id, serialized],
        )?;
        tx.execute("INSERT INTO imported_threads(id) VALUES (?1)", [id])?;
        index_thread(&tx, document)?;
        cache_thread(&tx, document, true)?;
        tx.commit()?;
        Ok(())
    }

    /// Sidebar reads touch only cached scalar metadata. Search uses the trigram
    /// index for queries of three or more Unicode characters, with a literal
    /// substring recheck; short queries scan cached text, never JSON transcripts.
    pub fn summaries(&self, query: &str, include_archived: bool) -> Result<Vec<ThreadSummary>> {
        self.connection()?;
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
            "SELECT id,title,project_id,archived,pinned,snoozed_until,
             (SELECT metadata FROM thread_navigation WHERE thread_navigation.id=thread_summaries.id COLLATE NOCASE)
             FROM thread_summaries WHERE (?1 OR archived=0){filter} ORDER BY pinned DESC,updated_at DESC,id"
        );
        let mut stmt = self.connection()?.prepare(&sql)?;
        let mapper = |r: &rusqlite::Row<'_>| {
            Ok(ThreadSummary {
                id: r.get(0)?,
                title: r.get(1)?,
                project_id: r.get(2)?,
                archived: r.get(3)?,
                pinned: r.get(4)?,
                snoozed_until: r.get(5)?,
                navigation: r
                    .get::<_, Option<String>>(6)?
                    .and_then(|raw| serde_json::from_str::<ThreadNavigation>(&raw).ok()),
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
        self.connection()?;
        let document: String = self.connection()?.query_row(
            "SELECT document FROM threads WHERE id=?1",
            [id],
            |r| r.get(0),
        )?;
        Ok(serde_json::from_str(&document)?)
    }

    /// Bounded exact UUID identity lookup. Read only scalar IDs, never decode
    /// transcripts/metadata. Normalized forms require a scan (no schema change),
    /// but at most two rows are retained so legacy aliases fail closed.
    pub fn resolve_thread_id(&self, id: Uuid) -> Result<Option<String>> {
        self.connection()?;
        let mut statement = self.connection()?.prepare(
            "SELECT id FROM threads WHERE replace(replace(replace(replace(lower(id),'urn:uuid:',''),'-',''),'{',''),'}','')=?1 LIMIT 2"
        )?;
        let matches = statement
            .query_map([id.simple().to_string()], |row| row.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        ensure!(
            matches.len() <= 1,
            "Thread UUID is ambiguous in stored identities"
        );
        let Some(stored) = matches.into_iter().next() else {
            return Ok(None);
        };
        ensure!(
            Uuid::parse_str(&stored).context("Invalid stored thread UUID")? == id,
            "Stored thread UUID does not match the requested identity"
        );
        Ok(Some(stored))
    }

    pub fn save(&mut self, document: &Value) -> Result<()> {
        self.save_with_usage(document, None)
    }
    pub(crate) fn save_with_usage(
        &mut self,
        document: &Value,
        record: Option<&Value>,
    ) -> Result<()> {
        self.save_with_usage_and_settings(document, record, None, None)
    }
    pub(crate) fn save_composer_choice(
        &mut self,
        document: &Value,
        settings: Option<&Value>,
    ) -> Result<()> {
        self.save_with_usage_and_settings(document, None, settings, None)
    }
    fn save_with_usage_and_settings(
        &mut self,
        document: &Value,
        record: Option<&Value>,
        settings: Option<&Value>,
        expected: Option<&Value>,
    ) -> Result<()> {
        self.connection()?;
        let id = validate_thread(document)?;
        let existing: Option<String> = self
            .connection()?
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
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure_not_deleted(&tx, id)?;
        if let Some(expected) = expected {
            ensure!(expected["id"] == id, "Native turn source identity mismatch");
            let raw: String =
                tx.query_row("SELECT document FROM threads WHERE id=?1", [id], |row| {
                    row.get(0)
                })?;
            ensure!(
                &serde_json::from_str::<Value>(&raw)? == expected,
                "Conversation changed before replacement admission; draft retained"
            );
            ensure!(
                !tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1)",
                    [id],
                    |row| row.get::<_, bool>(0)
                )?,
                "Imported conversation cannot admit a native turn"
            );
        }
        if let Some(record) = record {
            ensure!(
                record["threadID"]
                    .as_str()
                    .and_then(|id| Uuid::parse_str(id).ok())
                    == Some(Uuid::parse_str(id)?),
                "Usage record thread identity mismatch"
            );
            let local_size: Option<i64> = tx.query_row("SELECT length(CAST(document AS BLOB)) FROM documents WHERE name='usage-history.json'", [], |r|r.get(0)).optional()?;
            let old: Option<Value> = if let Some(size) = local_size {
                ensure!(
                    size <= crate::organization::DOCUMENT_LIMIT as i64,
                    "Usage history exceeds limit"
                );
                let raw: String = tx.query_row(
                    "SELECT document FROM documents WHERE name='usage-history.json'",
                    [],
                    |r| r.get(0),
                )?;
                Some(serde_json::from_str(&raw)?)
            } else {
                let size: Option<i64> = tx
                    .query_row(
                        "SELECT length(data) FROM original_files WHERE path='usage-history.json'",
                        [],
                        |r| r.get(0),
                    )
                    .optional()?;
                if let Some(size) = size {
                    ensure!(
                        size <= crate::organization::DOCUMENT_LIMIT as i64,
                        "Captured usage history exceeds limit"
                    );
                    let raw: Vec<u8> = tx.query_row(
                        "SELECT data FROM original_files WHERE path='usage-history.json'",
                        [],
                        |r| r.get(0),
                    )?;
                    Some(serde_json::from_slice(&raw)?)
                } else {
                    None
                }
            };
            let next = crate::agent::usage_capture::append_history(old.as_ref(), record)?;
            tx.execute("INSERT INTO documents(name,document) VALUES ('usage-history.json',?1) ON CONFLICT(name) DO UPDATE SET document=excluded.document", [next.to_string()])?;
        }
        provider_accounts::invalidate_changed_selection(&tx, document)?;
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
        if let Some(settings) = settings {
            tx.execute("INSERT INTO documents(name,document) VALUES ('settings.json',?1) ON CONFLICT(name) DO UPDATE SET document=excluded.document", [settings.to_string()])?;
        }
        tx.commit()?;
        self.note_selection_scope(document);
        Ok(())
    }

    /// Create one native bot chat only if the complete source envelope still
    /// matches. Source documents/original bytes and imported markers stay untouched.
    pub fn create_bot_thread_if_unchanged(
        &mut self,
        expected_bots: Option<&Value>,
        thread: &Value,
    ) -> Result<()> {
        self.connection()?;
        let id = validate_thread(thread)?;
        ensure!(
            thread["items"].as_array().is_some_and(Vec::is_empty)
                && thread["sessions"]
                    .as_object()
                    .is_some_and(serde_json::Map::is_empty)
                && thread["draft"] == ""
                && thread["rustBotContext"].is_object(),
            "Bot conversation must start empty with a context snapshot"
        );
        let bytes = serde_json::to_vec(thread)?;
        ensure!(
            bytes.len() <= 512 * 1024,
            "Bot conversation snapshot too large"
        );
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure_not_deleted(&tx, id)?;
        let local: Option<String> = tx
            .query_row(
                "SELECT document FROM documents WHERE name='bots.json'",
                [],
                |r| r.get(0),
            )
            .optional()?;
        let current: Option<Value> = if let Some(local) = local {
            Some(serde_json::from_str(&local)?)
        } else {
            let source: Option<Vec<u8>> = tx
                .query_row(
                    "SELECT data FROM original_files WHERE path='bots.json'",
                    [],
                    |r| r.get(0),
                )
                .optional()?;
            source.as_deref().map(serde_json::from_slice).transpose()?
        };
        ensure!(
            current.as_ref() == expected_bots,
            "Bot document changed; reload before creating a conversation"
        );
        let duplicate: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM threads WHERE id=?1 COLLATE NOCASE) OR EXISTS(SELECT 1 FROM imported_threads WHERE id=?1 COLLATE NOCASE) OR EXISTS(SELECT 1 FROM thread_summaries WHERE id=?1 COLLATE NOCASE)", [id], |r| r.get(0))?;
        ensure!(!duplicate, "Bot conversation UUID already exists");
        tx.execute(
            "INSERT INTO threads(id,document) VALUES (?1,?2)",
            params![id, String::from_utf8(bytes)?],
        )?;
        index_thread(&tx, thread)?;
        cache_thread(&tx, thread, true)?;
        let context = &thread["rustBotContext"];
        let name = crate::bot_runtime::context_document_name(context)?;
        let existing: Option<String> = tx
            .query_row(
                "SELECT document FROM documents WHERE name=?1",
                [&name],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(existing) = existing {
            ensure!(
                serde_json::from_str::<Value>(&existing)? == *context,
                "Bot context authorization record differs"
            );
        } else {
            tx.execute(
                "INSERT INTO documents(name,document) VALUES (?1,?2)",
                params![name, context.to_string()],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Private native service connection: existing schema3 only, no CREATE,
    /// directory creation, migration, journal-mode or schema writes.
    pub fn open_existing_for_legacy_media(path: &Path, expected_data_dir: &Path) -> Result<Self> {
        use crate::legacy_media_service::{open_regular_existing, verify_database_identity};
        let held = open_regular_existing(path)?;
        ensure!(
            expected_data_dir.is_absolute()
                && expected_data_dir.canonicalize()? == expected_data_dir,
            "Expected data directory must be canonical"
        );
        ensure!(
            path.parent() == Some(expected_data_dir),
            "Database data directory mismatch"
        );
        let db = Connection::open_with_flags(
            path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        verify_database_identity(path, &held, &db)?;
        let verify_schema = |db: &Connection| -> Result<()> {
            let version: String =
                db.query_row("SELECT value FROM metadata WHERE key='schema'", [], |r| {
                    r.get(0)
                })?;
            ensure!(
                version == "3",
                "Legacy media service requires existing schema3"
            );
            for sql in [
                "SELECT id,document FROM threads LIMIT 0",
                "SELECT name,document FROM documents LIMIT 0",
                "SELECT path,data FROM original_files LIMIT 0",
                "SELECT id,title,project_id,archived,pinned,updated_at,search_body,snoozed_until FROM thread_summaries LIMIT 0",
                "SELECT thread_id,title,body FROM search LIMIT 0",
                "SELECT thread_id,body FROM search_trigram LIMIT 0",
                "SELECT id FROM imported_threads LIMIT 0",
            ] {
                db.prepare(sql)?;
            }
            Ok(())
        };
        verify_schema(&db)?;
        drop(db);
        let db = Connection::open_with_flags(
            path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        verify_database_identity(path, &held, &db)?;
        verify_schema(&db)?;
        ensure!(
            !db.is_readonly("main")?,
            "Media service database must be writable"
        );
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        Ok(Self {
            db: Some(db),
            selection_scopes: Default::default(),
        })
    }

    /// Atomically compare the complete current thread AND local-only overlay,
    /// then write one Rust-owned overlay document. Never changes source threads.
    pub fn commit_legacy_media_overlay_if_unchanged(
        &mut self,
        expected_thread: &Value,
        expected_local_overlay: Option<&Value>,
        next_overlay: &Value,
    ) -> Result<()> {
        self.connection()?;
        use crate::legacy_media_service::{overlay_name, validate_overlay};
        let id = validate_thread(expected_thread)?;
        validate_overlay(expected_thread, next_overlay)?;
        let name = overlay_name(id)?;
        let serialized = serde_json::to_string(next_overlay)?;
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let size: i64 = tx.query_row(
            "SELECT length(CAST(document AS BLOB)) FROM threads WHERE id=?1",
            [id],
            |r| r.get(0),
        )?;
        ensure!(
            size <= 16_000_000,
            "Legacy media thread changed or exceeds limit"
        );
        let current: String =
            tx.query_row("SELECT document FROM threads WHERE id=?1", [id], |r| {
                r.get(0)
            })?;
        ensure!(
            &serde_json::from_str::<Value>(&current)? == expected_thread,
            "Legacy media thread changed"
        );
        let local: Option<String> = tx
            .query_row(
                "SELECT document FROM documents WHERE name=?1",
                [&name],
                |r| r.get(0),
            )
            .optional()?;
        ensure!(
            local.as_ref().is_none_or(|v| v.len() <= 4 * 1024 * 1024),
            "Legacy media overlay limit"
        );
        let local: Option<Value> = local.as_deref().map(serde_json::from_str).transpose()?;
        ensure!(
            local.as_ref() == expected_local_overlay,
            "Legacy media overlay changed"
        );
        tx.execute("INSERT INTO documents(name,document) VALUES (?1,?2) ON CONFLICT(name) DO UPDATE SET document=excluded.document", params![name,serialized])?;
        tx.commit()?;
        Ok(())
    }

    pub(crate) fn prepare_new_thread(&self, project_id: &str) -> Result<Value> {
        self.connection()?;
        let id = Uuid::new_v4().to_string().to_uppercase();
        let now = swift_timestamp();
        let mut thread = json!({"id":id,"projectID":project_id,"title":"New conversation","createdAt":now,"updatedAt":now,
            "selection":{"provider":"claude","modelID":"default"},"accessMode":"approval","interactionMode":"build",
            "items":[],"sessions":{},"isPinned":false,"isArchived":false,"draft":""});
        if let Some(follow_up) = self
            .document("settings.json")?
            .as_ref()
            .and_then(|settings| {
                crate::composer_follow_up::Behavior::parse(&settings["followUpBehavior"])
            })
        {
            thread["followUpBehavior"] = json!(follow_up.key());
        }
        Ok(thread)
    }
    pub fn new_thread(&mut self, project_id: &str) -> Result<Value> {
        let thread = self.prepare_new_thread(project_id)?;
        self.save(&thread)?;
        Ok(thread)
    }

    pub fn is_imported(&self, id: &str) -> Result<bool> {
        self.connection()?;
        Ok(self.connection()?.query_row(
            "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1)",
            [id],
            |r| r.get(0),
        )?)
    }

    pub fn original(&self, path: &str) -> Result<Option<Vec<u8>>> {
        self.connection()?;
        Ok(self
            .connection()?
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
        self.connection()?;
        let patch = patch
            .as_object()
            .context("Thread patch must be an object")?;
        validate_patch(patch)?;
        let mut value = self.thread(id)?;
        for (key, next) in patch {
            value[key] = next.clone();
        }
        let reindex = patch.contains_key("title");
        let tx = self.connection_mut()?.transaction()?;
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
        self.note_selection_scope(&value);
        Ok(value)
    }

    /// Rust-owned settings only. Imported original files never grant runtime
    /// authorization merely by containing the same document or field names.
    pub fn local_document(&self, name: &str) -> Result<Option<Value>> {
        self.connection()?;
        validate_document_name(name)?;
        let current: Option<String> = self
            .connection()?
            .query_row(
                "SELECT document FROM documents WHERE name=?1",
                [name],
                |row| row.get(0),
            )
            .optional()?;
        current
            .map(|text| serde_json::from_str(&text).map_err(Into::into))
            .transpose()
    }
    /// Trusted bounded saved usage read. The Rust overlay is a complete document,
    /// not an append fragment; a malformed overlay never falls back to originals.
    pub fn saved_usage_snapshot(&self) -> Result<(Vec<u8>, crate::local_usage::Source)> {
        use crate::{
            local_usage::Source,
            organization::{DOCUMENT_LIMIT, Records},
        };
        let db = self.connection()?;
        let select = |sql: &str| -> Result<Option<Vec<u8>>> {
            let row: Option<(Option<Vec<u8>>, i64)> = db
                .query_row(sql, params![DOCUMENT_LIMIT as i64], |row| {
                    Ok((row.get(0)?, row.get(1)?))
                })
                .optional()?;
            row.map(|(bytes, length)| {
                ensure!(
                    length >= 0 && length <= DOCUMENT_LIMIT as i64,
                    "Saved usage exceeds size limit"
                );
                bytes.context("Saved usage bytes unavailable")
            })
            .transpose()
        };
        let (bytes, source) = if let Some(bytes) = select(
            "SELECT CASE WHEN length(CAST(document AS BLOB))<=?1 THEN CAST(document AS BLOB) ELSE NULL END, length(CAST(document AS BLOB)) FROM documents WHERE name='usage-history.json'",
        )? {
            (bytes, Source::LocalDocument)
        } else if let Some(bytes) = select(
            "SELECT CASE WHEN length(data)<=?1 THEN data ELSE NULL END, length(data) FROM original_files WHERE path='usage-history.json'",
        )? {
            (bytes, Source::CapturedOriginal)
        } else {
            (b"[]".to_vec(), Source::LocalDocument)
        };
        Records::parse(&bytes).context("Saved usage history is invalid")?;
        Ok((bytes, source))
    }
    pub fn document(&self, name: &str) -> Result<Option<Value>> {
        self.connection()?;
        validate_document_name(name)?;
        let current: Option<String> = self
            .connection()?
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
        self.connection()?;
        validate_document_name(name)?;
        // An unreadable original must never be silently discarded by a save.
        self.document(name)?;
        self.connection()?.execute("INSERT INTO documents(name,document) VALUES (?1,?2) ON CONFLICT(name) DO UPDATE SET document=excluded.document",params![name,value.to_string()])?;
        if name == "projects.json" {
            self.note_project_scopes(value);
        }
        Ok(())
    }
    /// Compare-and-save only the Rust bot overlay. The original captured file
    /// remains immutable. An immediate transaction excludes competing writers
    /// across Store connections, not just callers sharing one Engine mutex.
    pub fn save_bots_document_if_unchanged(
        &mut self,
        expected: Option<&Value>,
        value: &Value,
    ) -> Result<()> {
        self.connection()?;
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let local: Option<String> = tx
            .query_row(
                "SELECT document FROM documents WHERE name='bots.json'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        let current: Option<Value> = if let Some(local) = local {
            Some(serde_json::from_str(&local)?)
        } else {
            let original: Option<Vec<u8>> = tx
                .query_row(
                    "SELECT data FROM original_files WHERE path='bots.json'",
                    [],
                    |row| row.get(0),
                )
                .optional()?;
            original
                .as_deref()
                .map(serde_json::from_slice)
                .transpose()?
        };
        ensure!(
            current.as_ref() == expected,
            "Bot document changed; reload before saving"
        );
        tx.execute("INSERT INTO documents(name,document) VALUES ('bots.json',?1) ON CONFLICT(name) DO UPDATE SET document=excluded.document", [value.to_string()])?;
        tx.commit()?;
        Ok(())
    }

    /// Typed native Voice edit against the exact effective document. Imported
    /// settings retain unknowns and never become capture/credential authority.
    pub fn save_native_voice_settings_if_unchanged(
        &mut self,
        expected: Option<&Value>,
        edit: crate::voice::Edit,
    ) -> Result<Value> {
        self.connection()?;
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        // Reject oversized documents before SQLite copies the text/blob into
        // memory. Never fall back to the captured original over an overlay.
        for query in [
            "SELECT length(CAST(document AS BLOB)) FROM documents WHERE name='settings.json'",
            "SELECT length(data) FROM original_files WHERE path='settings.json' AND NOT EXISTS(SELECT 1 FROM documents WHERE name='settings.json')",
        ] {
            let bytes: Option<i64> = tx.query_row(query, [], |row| row.get(0)).optional()?;
            ensure!(
                bytes.is_none_or(|bytes| (0..=2 * 1024 * 1024).contains(&bytes)),
                "Voice settings document is too large"
            );
        }
        let local: Option<String> = tx
            .query_row(
                "SELECT document FROM documents WHERE name='settings.json'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        let current: Option<Value> = if let Some(local) = local {
            Some(serde_json::from_str(&local)?)
        } else {
            let original: Option<Vec<u8>> = tx
                .query_row(
                    "SELECT data FROM original_files WHERE path='settings.json'",
                    [],
                    |row| row.get(0),
                )
                .optional()?;
            original
                .as_deref()
                .map(serde_json::from_slice)
                .transpose()?
        };
        ensure!(
            current.as_ref() == expected,
            "Voice settings changed; reload before saving"
        );
        let mut value = current.unwrap_or_else(|| json!({}));
        edit.apply(&mut value)?;
        tx.execute("INSERT INTO documents(name,document) VALUES ('settings.json',?1) ON CONFLICT(name) DO UPDATE SET document=excluded.document", [value.to_string()])?;
        tx.commit()?;
        Ok(value)
    }

    pub fn patch_document(&mut self, name: &str, patch: &Value) -> Result<Value> {
        self.connection()?;
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
    /// Native runtime authority marker; never a document/import/settings field.
    pub(crate) fn mark_native_provider_configuration(&mut self, provider: &str) -> Result<()> {
        self.connection()?.execute("INSERT INTO metadata(key,value) VALUES (?1,'1') ON CONFLICT(key) DO UPDATE SET value='1'",[format!("native-provider-configuration-v1/{provider}")])?;
        Ok(())
    }
    pub(crate) fn requires_native_provider_configuration(&self, provider: &str) -> Result<bool> {
        let marker: Option<String> = self
            .connection()?
            .query_row(
                "SELECT value FROM metadata WHERE key=?1",
                [format!("native-provider-configuration-v1/{provider}")],
                |row| row.get(0),
            )
            .optional()?;
        ensure!(
            marker.as_deref().is_none_or(|value| value == "1"),
            "Invalid native provider configuration marker"
        );
        Ok(marker.is_some())
    }
    pub fn projects(&self) -> Result<Value> {
        self.connection()?;
        let projects = self.document("projects.json")?.unwrap_or_else(|| json!([]));
        ensure!(
            projects.is_array(),
            "Stored projects document is not an array"
        );
        Ok(projects)
    }
    /// Native manual ordering is an exact permutation of a reviewed array.
    /// No project fields, folders, threads or session authority are changed.
    pub fn reorder_projects_if_unchanged(
        &mut self,
        expected: &Value,
        ids: &[String],
    ) -> Result<Value> {
        let projects = expected
            .as_array()
            .context("Project order source is not an array")?;
        ensure!(
            projects.len() <= 10_000
                && ids.len() == projects.len()
                && serde_json::to_vec(expected)?.len() <= 16 * 1024 * 1024,
            "Project reorder exceeds bounds or omits projects"
        );
        let mut seen = std::collections::HashSet::new();
        let mut ordered = Vec::with_capacity(ids.len());
        for id in ids {
            let identity = canonical_uuid(id)?;
            ensure!(seen.insert(identity), "Duplicate project in reorder");
            ordered.push(
                projects
                    .iter()
                    .find(|project| {
                        project["id"]
                            .as_str()
                            .and_then(|id| canonical_uuid(id).ok())
                            == Some(identity)
                    })
                    .context("Unknown project in reorder")?
                    .clone(),
            );
        }
        let value = json!(ordered);
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let local: Option<String> = tx
            .query_row(
                "SELECT document FROM documents WHERE name='projects.json'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        let current: Value = if let Some(local) = local {
            serde_json::from_str(&local)?
        } else {
            let original: Option<Vec<u8>> = tx
                .query_row(
                    "SELECT data FROM original_files WHERE path='projects.json'",
                    [],
                    |row| row.get(0),
                )
                .optional()?;
            original
                .as_deref()
                .map(serde_json::from_slice)
                .transpose()?
                .unwrap_or(json!([]))
        };
        ensure!(
            &current == expected,
            "Projects changed; refresh before reordering"
        );
        tx.execute("INSERT INTO documents(name,document) VALUES ('projects.json',?1) ON CONFLICT(name) DO UPDATE SET document=excluded.document",[value.to_string()])?;
        tx.commit()?;
        Ok(value)
    }
    pub fn create_project(&mut self, path: &Path, name: Option<&str>) -> Result<Value> {
        self.connection()?;
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
        self.connection()?;
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
        self.connection()?;
        let count: i64 = self.connection()?.query_row(
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
        let prepared = self.prepare_project_action(id, ProjectAction::Remove)?;
        self.apply_project_action(&prepared, None)?;
        Ok(())
    }
}

const CLI_IMPORT_BYTES: usize = 32 * 1024 * 1024;
const CLI_IMPORT_NODES: usize = 1_000_000;

fn validate_cli_source_key(key: &str) -> Result<()> {
    ensure!(
        key.len() <= 1024
            && key.starts_with("ImportedSessions/")
            && key
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"-._/".contains(&byte)),
        "CLI source key must be an ASCII relative key under ImportedSessions/"
    );
    ensure!(
        key.split('/').all(|part| !part.is_empty()
            && part.len() <= 255
            && !part.starts_with('.')
            && !part.ends_with('.')),
        "CLI source key contains an invalid path segment"
    );
    Ok(())
}

fn canonical_uuid(value: &str) -> Result<Uuid> {
    let id = Uuid::parse_str(value).context("Invalid imported UUID")?;
    ensure!(
        id.hyphenated().to_string().eq_ignore_ascii_case(value),
        "Imported UUID must use hyphenated form"
    );
    Ok(id)
}

fn validate_cli_thread(value: &Value) -> Result<()> {
    canonical_uuid(validate_thread(value)?)?;
    // Bound recursion and structural overhead before serialization. Unknown
    // fields remain intact, but cannot bypass the resource budget.
    fn visit(value: &Value, depth: usize, nodes: &mut usize) -> Result<()> {
        ensure!(
            depth <= 128 && *nodes < CLI_IMPORT_NODES,
            "CLI thread structure exceeds its bounds"
        );
        *nodes += 1;
        match value {
            Value::Array(items) => {
                ensure!(
                    items.len() <= CLI_IMPORT_NODES - *nodes,
                    "Too many CLI thread values"
                );
                for item in items {
                    visit(item, depth + 1, nodes)?;
                }
            }
            Value::Object(fields) => {
                ensure!(
                    fields.len() <= CLI_IMPORT_NODES - *nodes,
                    "Too many CLI thread fields"
                );
                for (key, value) in fields {
                    ensure!(key.len() <= 4096, "CLI thread field name is too long");
                    visit(value, depth + 1, nodes)?;
                }
            }
            Value::String(text) => ensure!(
                text.len() <= CLI_IMPORT_BYTES,
                "CLI thread text is too large"
            ),
            _ => {}
        }
        Ok(())
    }
    let mut nodes = 0;
    visit(value, 0, &mut nodes)?;
    for (field, limit) in [("title", 1024), ("draft", 1_048_576)] {
        if let Some(text) = value.get(field) {
            ensure!(
                text.as_str().is_some_and(|s| s.len() <= limit),
                "Invalid imported {field}"
            );
        }
    }
    for field in ["isPinned", "isArchived"] {
        if let Some(flag) = value.get(field) {
            ensure!(flag.is_boolean(), "Invalid imported {field}");
        }
    }
    if let Some(project) = value.get("projectID").filter(|id| !id.is_null()) {
        let project = project
            .as_str()
            .context("Imported projectID must be text")?;
        if !project.is_empty() {
            canonical_uuid(project)?;
        }
    }
    for field in ["createdAt", "updatedAt", "snoozedUntil"] {
        if let Some(date) = value.get(field).filter(|v| !v.is_null()) {
            crate::scheduling::parse_date(date)
                .with_context(|| format!("Invalid imported {field}"))?;
        }
    }
    let items = value["items"]
        .as_array()
        .context("Thread has no items array")?;
    ensure!(items.len() <= 100_000, "CLI thread has too many items");
    let mut ids = std::collections::HashSet::new();
    for item in items {
        ensure!(
            item.is_object(),
            "Imported transcript items must be objects"
        );
        if let Some(id) = item.get("id") {
            let id = canonical_uuid(id.as_str().context("Imported item ID must be text")?)?;
            ensure!(ids.insert(id), "Duplicate imported item UUID");
        }
        if let Some(kind) = item.get("kind") {
            ensure!(
                kind.as_str()
                    .is_some_and(|s| !s.is_empty() && s.len() <= 64),
                "Invalid imported item kind"
            );
        }
        if let Some(text) = item.get("text") {
            ensure!(text.is_string(), "Imported item text must be text");
        }
    }
    Ok(())
}

/// JSON escaping can expand input strings. Bound the encoded output while
/// writing rather than allocating an unbounded Vec and checking it afterwards.
struct ImportDocumentWriter(Vec<u8>);
impl std::io::Write for ImportDocumentWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > CLI_IMPORT_BYTES.saturating_sub(self.0.len()) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "CLI thread JSON exceeds 32 MiB",
            ));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod cli_import_tests {
    use super::*;
    const ID: &str = "A1111111-1111-4111-8111-111111111111";
    const OTHER: &str = "C3333333-3333-4333-8333-333333333333";
    const ITEM: &str = "B2222222-2222-4222-8222-222222222222";
    const KEY: &str = "ImportedSessions/codex/source.jsonl";
    fn fixture() -> (tempfile::TempDir, Store) {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(&dir.path().join("data/db.sqlite")).unwrap();
        (dir, store)
    }
    fn document(id: &str) -> Value {
        json!({"id":id,"title":"Captured conversation","projectID":"", "draft":"preserved draft",
            "createdAt":"2026-11-05T09:30:17.125+05:30","updatedAt":815544017.125,
            "items":[{"id":ITEM,"kind":"assistant","text":"searchable import needle 日本語","futureItem":{"opaque":true}}],
            "selection":{"provider":"codex","modelID":"source-model"},
            "sessions":{"codex":{"sessionID":"captured-only"}},
            "isPinned":false,"isArchived":false,"futureField":[1,{"bytes":"preserve"}]})
    }
    fn counts(store: &Store) -> Vec<i64> {
        [
            "original_files",
            "threads",
            "imported_threads",
            "thread_summaries",
            "search",
            "search_trigram",
        ]
        .iter()
        .map(|table| {
            store
                .connection()
                .unwrap()
                .query_row(&format!("SELECT count(*) FROM {table}"), [], |row| {
                    row.get(0)
                })
                .unwrap()
        })
        .collect()
    }
    #[test]
    fn cli_import_preserves_source_unknown_fields_indexes_and_execution_barrier() {
        let (dir, mut store) = fixture();
        let raw = b" \r\n{\"source\":true}\n\xff\0";
        let expected = document(ID);
        store.import_cli_session(&expected, KEY, raw).unwrap();
        assert_eq!(store.original(KEY).unwrap().unwrap(), raw);
        assert_eq!(store.thread(ID).unwrap(), expected);
        assert!(store.is_imported(&ID.to_lowercase()).unwrap());
        assert_eq!(store.summaries("import needle", false).unwrap()[0].id, ID);
        assert_eq!(counts(&store), vec![1, 1, 1, 1, 1, 1]);
        drop(store);
        let reopened = Store::open(&dir.path().join("data/db.sqlite")).unwrap();
        assert!(reopened.is_imported(ID).unwrap());
        assert_eq!(reopened.thread(ID).unwrap(), expected);
        assert_eq!(reopened.original(KEY).unwrap().unwrap(), raw);
    }
    #[test]
    fn cli_import_refuses_case_aliases_without_overwriting_original_or_local_thread() {
        let (_dir, mut store) = fixture();
        let expected = document(ID);
        store
            .import_cli_session(&expected, KEY, b"original bytes")
            .unwrap();
        let before = counts(&store);
        assert!(
            store
                .import_cli_session(
                    &document(&ID.to_lowercase()),
                    "ImportedSessions/codex/another.jsonl",
                    b"replacement"
                )
                .is_err()
        );
        assert!(
            store
                .import_cli_session(
                    &document(OTHER),
                    "ImportedSessions/CODEX/SOURCE.JSONL",
                    b"replacement"
                )
                .is_err()
        );
        assert_eq!(counts(&store), before);
        assert_eq!(store.thread(ID).unwrap(), expected);
        assert_eq!(store.original(KEY).unwrap().unwrap(), b"original bytes");
        assert!(
            store
                .original("ImportedSessions/codex/another.jsonl")
                .unwrap()
                .is_none()
        );
        assert!(store.thread(OTHER).is_err());
        let local = store.new_thread("").unwrap();
        let id = local["id"].as_str().unwrap();
        assert!(
            store
                .import_cli_session(
                    &document(id),
                    "ImportedSessions/codex/local.jsonl",
                    b"source"
                )
                .is_err()
        );
        assert_eq!(store.thread(id).unwrap(), local);
        assert!(!store.is_imported(id).unwrap());
    }
    #[test]
    fn cli_import_late_cache_failure_rolls_back_original_thread_marker_and_both_indexes() {
        let (_dir, mut store) = fixture();
        let local = store.new_thread("").unwrap();
        let before = counts(&store);
        store.connection().unwrap().execute_batch(&format!("CREATE TRIGGER reject_cli_cache BEFORE INSERT ON thread_summaries WHEN NEW.id='{ID}' BEGIN SELECT RAISE(ABORT,'synthetic cache failure'); END;")).unwrap();
        assert!(
            store
                .import_cli_session(&document(ID), KEY, b"captured bytes")
                .is_err()
        );
        assert_eq!(counts(&store), before);
        assert!(store.original(KEY).unwrap().is_none());
        assert!(store.thread(ID).is_err());
        assert!(!store.is_imported(ID).unwrap());
        assert!(store.summaries("import needle", true).unwrap().is_empty());
        assert_eq!(store.thread(local["id"].as_str().unwrap()).unwrap(), local);
        store
            .connection()
            .unwrap()
            .execute_batch("DROP TRIGGER reject_cli_cache")
            .unwrap();
        store
            .import_cli_session(&document(ID), KEY, b"captured bytes")
            .unwrap();
        assert_eq!(store.summaries("import needle", true).unwrap().len(), 1);
    }
    #[test]
    fn cli_import_rejects_reserved_source_paths_and_malformed_documents_atomically() {
        let (_dir, mut store) = fixture();
        for key in [
            "",
            "settings.json",
            "/ImportedSessions/a",
            "ImportedSessions/",
            "ImportedSessions/../settings.json",
            "ImportedSessions/./a",
            "ImportedSessions//a",
            "ImportedSessions/a\\b",
            "ImportedSessions/a\0b",
            "ImportedSessions/a.",
        ] {
            assert!(
                store
                    .import_cli_session(&document(ID), key, b"source")
                    .is_err(),
                "{key:?}"
            );
        }
        assert!(store.import_cli_session(&document(ID), KEY, b"").is_err());
        for (key, invalid) in [
            (
                "id",
                json!(Uuid::parse_str(ID).unwrap().simple().to_string()),
            ),
            ("items", json!([null])),
            ("title", json!(12)),
            ("projectID", json!("../../path")),
            ("isPinned", json!("true")),
            ("updatedAt", json!("invalid date")),
        ] {
            let mut bad = document(ID);
            bad[key] = invalid;
            assert!(
                store.import_cli_session(&bad, KEY, b"source").is_err(),
                "{key}"
            );
        }
        let mut duplicate = document(ID);
        duplicate["items"]
            .as_array_mut()
            .unwrap()
            .push(json!({"id":ITEM.to_lowercase(),"kind":"user","text":"duplicate"}));
        assert!(
            store
                .import_cli_session(&duplicate, KEY, b"source")
                .is_err()
        );
        assert_eq!(counts(&store), vec![0; 6]);
    }
    #[test]
    fn cli_import_bounds_source_structure_and_serialized_document() {
        let (_dir, mut store) = fixture();
        assert!(
            store
                .import_cli_session(&document(ID), KEY, &vec![0; CLI_IMPORT_BYTES + 1])
                .is_err()
        );
        let mut bad = document(ID);
        // Raw string fits, but JSON framing pushes the encoded document over.
        bad["futureField"] = json!("x".repeat(CLI_IMPORT_BYTES));
        assert!(store.import_cli_session(&bad, KEY, b"source").is_err());
        let mut nested = Value::Null;
        for _ in 0..129 {
            nested = json!([nested]);
        }
        bad["futureField"] = nested;
        assert!(store.import_cli_session(&bad, KEY, b"source").is_err());
        assert_eq!(counts(&store), vec![0; 6]);
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
    navigation_cache::write(db, v)?;
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
        // Observe the exact legitimate writes instead of assuming the derived
        // cache has no maintenance. Any extra FTS writes still fail the bound.
        db.connection().unwrap().execute_batch("CREATE TEMP TABLE patch_write_audit(table_name TEXT, operation TEXT);
            CREATE TEMP TRIGGER audit_patch_thread AFTER UPDATE ON main.threads BEGIN
                INSERT INTO patch_write_audit VALUES ('threads','update'); END;
            CREATE TEMP TRIGGER audit_patch_summary AFTER UPDATE ON main.thread_summaries BEGIN
                INSERT INTO patch_write_audit VALUES ('thread_summaries','update'); END;
            CREATE TEMP TRIGGER audit_patch_navigation_delete AFTER DELETE ON main.thread_navigation BEGIN
                INSERT INTO patch_write_audit VALUES ('thread_navigation','delete'); END;
            CREATE TEMP TRIGGER audit_patch_navigation_insert AFTER INSERT ON main.thread_navigation BEGIN
                INSERT INTO patch_write_audit VALUES ('thread_navigation','insert'); END;").unwrap();
        let before = db.connection().unwrap().total_changes();
        let changed = db
            .patch_thread(ID, &json!({"draft":"new draft","isPinned":true}))
            .unwrap();
        let audit: Vec<(String, String)> = db
            .connection()
            .unwrap()
            .prepare(
                "SELECT table_name,operation FROM patch_write_audit ORDER BY table_name,operation",
            )
            .unwrap()
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        assert_eq!(
            audit,
            vec![
                ("thread_navigation".into(), "delete".into()),
                ("thread_navigation".into(), "insert".into()),
                ("thread_summaries".into(), "update".into()),
                ("threads".into(), "update".into()),
            ]
        );
        // Four observed writes plus their four temporary audit rows. Search
        // maintenance would add unaccounted writes and violate this assertion.
        assert_eq!(db.connection().unwrap().total_changes() - before, 8);
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
        db.connection()
            .unwrap()
            .execute("DROP TABLE threads", [])
            .unwrap();
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
        store.connection().unwrap().execute_batch("DROP INDEX thread_summaries_snooze; ALTER TABLE thread_summaries DROP COLUMN snoozed_until; UPDATE metadata SET value='2' WHERE key='schema';").unwrap();
        // This index was introduced after schema v2; the old fixture has none.
        assert_eq!(
            store
                .connection()
                .unwrap()
                .query_row(
                    "SELECT count(*) FROM sqlite_master WHERE name='thread_summaries_snooze'",
                    [],
                    |row| row.get::<_, u32>(0)
                )
                .unwrap(),
            0
        );
        let original = store.thread(ID).unwrap();
        drop(store);
        let mut store = Store::open(&path).unwrap();
        assert_eq!(
            store
                .connection()
                .unwrap()
                .query_row(
                    "SELECT count(*) FROM sqlite_master WHERE name='thread_summaries_snooze'",
                    [],
                    |row| row.get::<_, u32>(0)
                )
                .unwrap(),
            1
        );
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
        store
            .connection()
            .unwrap()
            .execute("DROP TABLE threads", [])
            .unwrap();
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
        store.connection().unwrap().execute_batch("DROP INDEX thread_summaries_snooze; ALTER TABLE thread_summaries DROP COLUMN snoozed_until; UPDATE metadata SET value='2' WHERE key='schema'; UPDATE threads SET document='{}';").unwrap();
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
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM sqlite_master WHERE name='thread_summaries_snooze'",
                [],
                |row| row.get::<_, u32>(0)
            )
            .unwrap(),
            0
        );
    }
}

#[cfg(test)]
mod shutdown_tests {
    use super::*;
    #[test]
    fn close_retains_exact_data_and_closed_operations_never_reopen_database() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("data.sqlite");
        let source = dir.path().join("source.bin");
        let source_bytes = b"source bytes\0unchanged";
        fs::write(&source, source_bytes).unwrap();
        let mut store = Store::open(&path).unwrap();
        let id = Uuid::new_v4().to_string();
        let document = json!({"id":id,"title":"Exact","items":[],"draft":"  café 中文 👩🏽‍💻\n\n","future":{"unknown":[null,{"x":"y"}]}});
        store.save(&document).unwrap();
        store
            .save_document("future.json", &json!({"unknown":true}))
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "INSERT INTO original_files(path,data) VALUES (?1,?2)",
                params!["source.bin", source_bytes.as_slice()],
            )
            .unwrap();
        assert!(!store.is_closed());
        store.close_for_shutdown().unwrap();
        assert!(store.is_closed());
        store.close_for_shutdown().unwrap();
        let archived = dir.path().join("closed.sqlite");
        fs::rename(&path, &archived).unwrap();
        let empty = json!({});
        let results = vec![
            store.data_directory().map(|_| ()),
            store.summaries("", false).map(|_| ()),
            store.thread(&id).map(|_| ()),
            store.resolve_thread_id(Uuid::new_v4()).map(|_| ()),
            store.save(&empty),
            store.import_legacy(&source).map(|_| ()),
            store.import_cli_session(&empty, "invalid", b"").map(|_| ()),
            store.create_bot_thread_if_unchanged(None, &empty),
            store.commit_legacy_media_overlay_if_unchanged(&empty, None, &empty),
            store.new_thread("missing").map(|_| ()),
            store.is_imported(&id).map(|_| ()),
            store.original("source.bin").map(|_| ()),
            store.patch_thread(&id, &empty).map(|_| ()),
            store.local_document("future.json").map(|_| ()),
            store.document("future.json").map(|_| ()),
            store.save_document("future.json", &empty),
            store.save_bots_document_if_unchanged(None, &empty),
            store.patch_document("future.json", &empty).map(|_| ()),
            store.projects().map(|_| ()),
            store.create_project(dir.path(), None).map(|_| ()),
            store.patch_project("missing", &empty).map(|_| ()),
            store.remove_project("missing"),
        ];
        for result in results {
            assert_eq!(result.unwrap_err().to_string(), "Store is closed");
        }
        assert!(
            !path.exists(),
            "closed methods must not recreate the database"
        );
        assert_eq!(fs::read(&source).unwrap(), source_bytes);
        fs::rename(&archived, &path).unwrap();
        let reopened = Store::open(&path).unwrap();
        assert_eq!(reopened.thread(&id).unwrap(), document);
        assert_eq!(
            reopened.document("future.json").unwrap(),
            Some(json!({"unknown":true}))
        );
        assert_eq!(
            reopened.original("source.bin").unwrap().unwrap(),
            source_bytes
        );
    }
    #[test]
    fn failed_close_restores_connection_until_outstanding_statement_is_finalized() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("busy.sqlite")).unwrap();
        let mut statement = std::ptr::null_mut();
        // Deliberately retain a native SQLite statement without a Rust borrow,
        // reproducing SQLITE_BUSY from close. No statement execution or raw data.
        let code = unsafe {
            rusqlite::ffi::sqlite3_prepare_v2(
                store.connection().unwrap().handle(),
                c"SELECT 1".as_ptr(),
                -1,
                &mut statement,
                std::ptr::null_mut(),
            )
        };
        assert_eq!(code, rusqlite::ffi::SQLITE_OK);
        struct Finalize(*mut rusqlite::ffi::sqlite3_stmt);
        impl Drop for Finalize {
            fn drop(&mut self) {
                unsafe {
                    rusqlite::ffi::sqlite3_finalize(self.0);
                }
            }
        }
        let held = Finalize(statement);
        assert!(store.close_for_shutdown().is_err());
        assert!(!store.is_closed());
        assert!(store.projects().is_ok());
        drop(held);
        store.close_for_shutdown().unwrap();
        assert!(store.is_closed());
    }
}

#[cfg(test)]
mod saved_usage_tests {
    use super::*;
    use crate::{local_usage::Source, organization::DOCUMENT_LIMIT};
    #[test]
    fn saved_usage_snapshot_preserves_original_and_prefers_complete_overlay() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("saved.sqlite")).unwrap();
        assert_eq!(store.saved_usage_snapshot().unwrap().0, b"[]");
        let original =
            br#"[ {"id":"00000000-0000-0000-0000-000000000001","unknown":{"keep":true}} ]"#;
        store
            .connection()
            .unwrap()
            .execute(
                "INSERT INTO original_files(path,data) VALUES('usage-history.json',?1)",
                [original.as_slice()],
            )
            .unwrap();
        let (bytes, source) = store.saved_usage_snapshot().unwrap();
        assert_eq!(bytes, original);
        assert_eq!(source, Source::CapturedOriginal);
        let overlay = json!([{"id":Uuid::from_u128(1),"unknown":{"keep":true}},{"id":Uuid::from_u128(2),"usage":{"outputTokens":0}}]);
        store.save_document("usage-history.json", &overlay).unwrap();
        let (bytes, source) = store.saved_usage_snapshot().unwrap();
        assert_eq!(source, Source::LocalDocument);
        assert_eq!(serde_json::from_slice::<Value>(&bytes).unwrap(), overlay);
        assert_eq!(
            store.original("usage-history.json").unwrap().unwrap(),
            original
        );
        store.close_for_shutdown().unwrap();
        assert!(
            store
                .saved_usage_snapshot()
                .unwrap_err()
                .to_string()
                .contains("Store is closed")
        );
    }
    #[test]
    fn saved_usage_snapshot_rejects_malformed_or_oversize_without_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(&dir.path().join("saved.sqlite")).unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "INSERT INTO original_files(path,data) VALUES('usage-history.json',?1)",
                [b"not-json".as_slice()],
            )
            .unwrap();
        assert!(store.saved_usage_snapshot().is_err());
        store
            .connection()
            .unwrap()
            .execute(
                "INSERT INTO documents(name,document) VALUES('usage-history.json','[]')",
                [],
            )
            .unwrap();
        assert_eq!(store.saved_usage_snapshot().unwrap().0, b"[]");
        // Inject corruption into this private fixture only; normal writes are
        // protected by the schema's json_valid CHECK. Reads must still reject
        // malformed/oversized legacy or externally damaged rows without fallback.
        store
            .connection()
            .unwrap()
            .execute_batch("PRAGMA ignore_check_constraints=ON")
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute("UPDATE documents SET document='broken'", [])
            .unwrap();
        assert!(store.saved_usage_snapshot().is_err());
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE documents SET document=zeroblob(?1)",
                [(DOCUMENT_LIMIT + 1) as i64],
            )
            .unwrap();
        assert!(
            store
                .saved_usage_snapshot()
                .unwrap_err()
                .to_string()
                .contains("size limit")
        );
        store
            .connection()
            .unwrap()
            .execute("DELETE FROM documents", [])
            .unwrap();
        store
            .connection()
            .unwrap()
            .execute(
                "UPDATE original_files SET data=zeroblob(?1)",
                [(DOCUMENT_LIMIT + 1) as i64],
            )
            .unwrap();
        assert!(store.saved_usage_snapshot().is_err());
    }
}

#[cfg(test)]
mod navigation_metadata_tests {
    use super::*;
    #[test]
    fn optional_summary_metadata_preserves_legacy_json_and_describes_bot_without_changing_source() {
        let legacy = json!({"id":"legacy","title":"Legacy","project_id":"","archived":false,"pinned":false,"snoozed_until":null});
        let summary: ThreadSummary = serde_json::from_value(legacy.clone()).unwrap();
        assert!(summary.navigation.is_none());
        assert_eq!(serde_json::to_value(summary).unwrap(), legacy);
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("navigation.sqlite")).unwrap();
        let mut thread = store
            .new_thread("00000000-0000-0000-0000-000000000000")
            .unwrap();
        thread["botID"] = json!("117E51F1-9D63-43DD-AF75-A5709E1B0123");
        thread["branch"] = json!("feature/sidebar");
        thread["updatedAt"] = json!(100.);
        thread["items"] = json!([{ "id": "017E51F1-9D63-43DD-AF75-A5709E1B0123", "kind":"assistant", "text":" Hello\n\tfrom the bot " }]);
        store.save(&thread).unwrap();
        let before = store.thread(thread["id"].as_str().unwrap()).unwrap();
        let rows = store.summaries("", false).unwrap();
        let metadata = rows[0].navigation.as_ref().unwrap();
        assert_eq!(metadata.bot_id.as_deref(), thread["botID"].as_str());
        assert_eq!(metadata.branch.as_deref(), Some("feature/sidebar"));
        assert_eq!(metadata.preview.as_deref(), Some("Hello from the bot"));
        assert_eq!(metadata.item_count, Some(1));
        assert_eq!(metadata.has_draft, Some(false));
        assert_eq!(metadata.updated_at, Some(100.));
        assert_eq!(
            store.thread(thread["id"].as_str().unwrap()).unwrap(),
            before
        );
        assert!(before.get("rustBotContext").is_none());
        let mut drafted = before.clone();
        drafted["draftContext"] = json!([{"futureAttachment":"retained"}]);
        store.save(&drafted).unwrap();
        assert_eq!(
            store.summaries("", false).unwrap()[0]
                .navigation
                .as_ref()
                .unwrap()
                .has_draft,
            Some(true)
        );
    }
}

#[cfg(test)]
mod project_order_tests {
    use super::*;
    #[test]
    fn reviewed_project_permutation_retains_unknown_fields_and_rejects_stale_or_invalid_orders() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("projects.sqlite")).unwrap();
        let first = "00000000-0000-4000-8000-000000000001";
        let second = "00000000-0000-4000-8000-000000000002";
        let original = json!([{"id":first,"name":"One","path":"/fixture/one","future":{"keep":true}},{"id":second,"name":"Two","path":"/fixture/two","threadDefaults":{"future":"keep"}}]);
        store.save_document("projects.json", &original).unwrap();
        assert!(
            store
                .reorder_projects_if_unchanged(&original, &[first.into(), first.into()])
                .is_err()
        );
        assert!(
            store
                .reorder_projects_if_unchanged(&original, &[first.into()])
                .is_err()
        );
        assert_eq!(store.projects().unwrap(), original);
        let reordered = store
            .reorder_projects_if_unchanged(&original, &[second.into(), first.into()])
            .unwrap();
        assert_eq!(reordered, json!([original[1], original[0]]));
        assert!(
            store
                .reorder_projects_if_unchanged(&original, &[first.into(), second.into()])
                .is_err()
        );
        assert_eq!(store.projects().unwrap(), reordered);
        let mut other = Store::open(&dir.path().join("projects.sqlite")).unwrap();
        other
            .patch_project(first, &json!({"name":"Changed elsewhere"}))
            .unwrap();
        assert!(
            store
                .reorder_projects_if_unchanged(&reordered, &[first.into(), second.into()])
                .is_err()
        );
        assert_eq!(store.projects().unwrap()[1]["name"], "Changed elsewhere");
    }
}
