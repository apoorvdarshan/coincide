//! Atomic reviewed bot/config/task/conversation lifecycle; imports grant no Undo.
use super::*;
use std::collections::BTreeMap;
pub(crate) struct BotLifecycle {
    pub bot: Value,
    pub rows: Vec<DeleteRow>,
    pub targets: Vec<Value>,
    pub deleting: bool,
    before: BTreeMap<String, Option<Value>>,
    after: BTreeMap<String, Option<Value>>,
    version: DeleteVersion,
    pub chats_folder: Option<std::path::PathBuf>,
    pub task_count: usize,
}
pub(crate) struct BotLifecycleUndo {
    plan: BotLifecycle,
    token: String,
}
fn document_cas(db: &Connection, expected: &BTreeMap<String, Option<Value>>) -> Result<()> {
    for (name, expected) in expected {
        let raw: Option<String> = db
            .query_row(
                "SELECT document FROM documents WHERE name=?1",
                [name],
                |r| r.get(0),
            )
            .optional()?;
        let local = raw.map(|v| serde_json::from_str::<Value>(&v)).transpose()?;
        // Original/import fallback is captured in a separate effective snapshot;
        // callers validate it before the transaction. Local overlay CAS remains
        // presence-aware and guarded by the connection's data_version.
        ensure!(
            &local == expected,
            "Bot lifecycle configuration changed after review"
        );
    }
    Ok(())
}
fn write_documents(db: &Connection, values: &BTreeMap<String, Option<Value>>) -> Result<()> {
    for (name, value) in values {
        match value {
            Some(value) => {
                db.execute("INSERT INTO documents(name,document) VALUES(?1,?2) ON CONFLICT(name) DO UPDATE SET document=excluded.document", params![name,value.to_string()])?;
            }
            None => {
                db.execute("DELETE FROM documents WHERE name=?1", [name])?;
            }
        }
    }
    Ok(())
}
impl Store {
    /// A bot's own folder, Swift's `Bot.workingDirectory`: the folder the user
    /// chose for it, or home when none is set. A conversation of a bot that no
    /// longer exists also falls back to home, as Swift's `bot(id)?.workingDirectory`.
    pub fn bot_working_directory(&self, id: &str) -> Result<Option<std::path::PathBuf>> {
        let bots = self.document("bots.json")?;
        let folder = bots
            .as_ref()
            .and_then(|bots| bots["bots"].as_array())
            .and_then(|bots| bots.iter().find(|bot| bot["id"] == id))
            .and_then(|bot| bot["folder"].as_str())
            .filter(|folder| !folder.is_empty())
            .map(std::path::PathBuf::from)
            .filter(|folder| folder.is_absolute());
        Ok(Some(folder.unwrap_or_else(crate::terminal::launch::home)))
    }
    pub(crate) fn prepare_bot_lifecycle(&self, id: &str, deleting: bool) -> Result<BotLifecycle> {
        let id = Uuid::parse_str(id)?;
        let start = version(self.connection()?)?;
        let bots_source = self.local_document("bots.json")?;
        let mut bots = self
            .document("bots.json")?
            .context("Bot configuration is unavailable")?;
        let entries = bots["bots"]
            .as_array_mut()
            .context("Malformed bot configuration")?;
        ensure!(
            entries.len() <= 1024 && serde_json::to_vec(&entries)?.len() <= 4 * 1024 * 1024,
            "Bot configuration exceeds native review bound"
        );
        let mut seen = HashSet::new();
        for bot in entries.iter() {
            ensure!(
                seen.insert(Uuid::parse_str(text(bot, "id").as_str())?),
                "Duplicate bot identity"
            );
        }
        let position = entries
            .iter()
            .position(|bot| Uuid::parse_str(&text(bot, "id")).ok() == Some(id))
            .context("Bot is no longer available")?;
        let bot = entries.remove(position);
        let mut statement = self.connection()?.prepare("SELECT id FROM threads WHERE lower(json_extract(document,'$.botID'))=lower(?1) OR lower(json_extract(document,'$.rustBotContext.botId'))=lower(?1) ORDER BY id LIMIT 129")?;
        let ids = statement
            .query_map([id.to_string()], |row| row.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        ensure!(
            ids.len() <= 128,
            "Review at most 128 bot conversations at a time"
        );
        let rows = if ids.is_empty() {
            Vec::new()
        } else {
            self.prepare_any_delete_rows(&ids)?.1
        };
        let mut before = BTreeMap::new();
        let mut after = BTreeMap::new();
        before.insert("bots.json".into(), bots_source);
        after.insert("bots.json".into(), Some(bots));
        let tasks_source = self.local_document("scheduled-tasks.json")?;
        let mut tasks = self
            .document("scheduled-tasks.json")?
            .unwrap_or(json!({"tasks":[]}));
        let entries = tasks["tasks"]
            .as_array_mut()
            .context("Scheduled tasks are malformed")?;
        let previous = entries.len();
        entries.retain(|task| {
            Uuid::parse_str(&text(task, "botID")).ok() != Some(id)
                && Uuid::parse_str(&text(task, "botId")).ok() != Some(id)
                && !ids
                    .iter()
                    .any(|id| text(task, "threadID").eq_ignore_ascii_case(id))
        });
        let task_count = previous - entries.len();
        if task_count > 0 {
            before.insert("scheduled-tasks.json".into(), tasks_source);
            after.insert("scheduled-tasks.json".into(), Some(tasks));
        }
        let mut chats_folder = None;
        let mut targets = Vec::new();
        if !deleting && !rows.is_empty() {
            let projects_source = self.local_document("projects.json")?;
            let mut projects = self.projects()?;
            let entries = projects.as_array_mut().unwrap();
            let chats = if let Some(project) = entries.iter().find(|p| p["isChats"] == true) {
                text(project, "id")
            } else {
                let folder = self.data_directory()?.join("Chats");
                ensure!(
                    !folder.exists(),
                    "An unconfigured Chats folder already exists; choose/configure Chats before keeping conversations"
                );
                let id = Uuid::new_v4().to_string().to_uppercase();
                entries.push(json!({"id":id,"name":"Chats","path":folder,"isChats":true,"isExpanded":true,"createdAt":swift_timestamp()}));
                chats_folder = Some(folder);
                id
            };
            before.insert("projects.json".into(), projects_source);
            after.insert("projects.json".into(), Some(projects));
            for row in &rows {
                let mut target: Value = serde_json::from_str(&row.raw)?;
                target["projectID"] = json!(chats);
                target["sessions"] = json!({});
                for key in [
                    "botID",
                    "rustBotContext",
                    "accountSessions",
                    "branch",
                    "worktreePath",
                ] {
                    target.as_object_mut().unwrap().remove(key);
                }
                targets.push(target);
            }
        }
        // Include locally authorized snapshots of already-deleted conversations:
        // an older Archive Undo must not resurrect execution of a removed bot.
        let mut context_query = self.connection()?.prepare("SELECT name,document FROM documents WHERE name GLOB 'rust-bot-context-*.json' LIMIT 8193")?;
        let contexts = context_query
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        ensure!(
            contexts.len() <= 8192,
            "Bot authorization cleanup exceeds its review bound"
        );
        let mut context_bytes = 0usize;
        for (name, raw) in contexts {
            ensure!(
                raw.len() <= 512 * 1024,
                "A bot authorization record exceeds its safe bound"
            );
            let context: Value = serde_json::from_str(&raw)?;
            if Uuid::parse_str(&text(&context, "botId")).ok() == Some(id) {
                ensure!(
                    crate::bot_runtime::context_document_name(&context)? == name,
                    "Bot authorization record identity changed"
                );
                context_bytes = context_bytes.saturating_add(raw.len());
                ensure!(
                    context_bytes <= 32 * 1024 * 1024,
                    "Bot authorization Undo exceeds its review bound"
                );
                before.insert(name.clone(), Some(context));
                after.insert(name, None);
            }
        }
        // Remove only previously local, exact authorization records for this
        // bot, never materialize imported context claims into local authority.
        for row in &rows {
            let source: Value = serde_json::from_str(&row.raw)?;
            if let Some(context) = source.get("rustBotContext").filter(|v| v.is_object()) {
                let name = crate::bot_runtime::context_document_name(context)?;
                if self.local_document(&name)?.as_ref() == Some(context) {
                    before.insert(name.clone(), Some(context.clone()));
                    after.insert(name, None);
                }
            }
        }
        ensure!(
            version(self.connection()?)? == start,
            "Store changed while preparing bot review"
        );
        Ok(BotLifecycle {
            bot,
            rows,
            targets,
            deleting,
            before,
            after,
            version: start,
            chats_folder,
            task_count,
        })
    }
    pub(crate) fn validate_bot_lifecycle(&self, plan: &BotLifecycle) -> Result<()> {
        ensure!(
            version(self.connection()?)? == plan.version,
            "Store changed after bot review"
        );
        document_cas(self.connection()?, &plan.before)?;
        rows_match(self.connection()?, &plan.rows)
    }
    pub(crate) fn apply_bot_lifecycle(&mut self, plan: BotLifecycle) -> Result<BotLifecycleUndo> {
        self.validate_bot_lifecycle(&plan)?;
        let token = Uuid::new_v4().to_string();
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure!(
            version(&tx)? == plan.version,
            "Store changed after bot review"
        );
        document_cas(&tx, &plan.before)?;
        rows_match(&tx, &plan.rows)?;
        if plan.deleting {
            delete_rows_in_transaction(&tx, &plan.rows, &token)?;
        } else {
            // Old native IDs stay denied even when Undo restores metadata.
            tx.execute_batch("CREATE TABLE IF NOT EXISTS revoked_native_sessions(thread_id TEXT NOT NULL COLLATE NOCASE,native_hash BLOB NOT NULL CHECK(length(native_hash)=32),PRIMARY KEY(thread_id,native_hash));")?;
            for (row, target) in plan.rows.iter().zip(&plan.targets) {
                for hash in &row.native {
                    tx.execute("INSERT OR IGNORE INTO revoked_native_sessions(thread_id,native_hash) VALUES(?1,?2)",params![Uuid::parse_str(&row.id)?.to_string(),hash.as_slice()])?;
                }
                ensure!(
                    tx.execute(
                        "UPDATE threads SET document=?3 WHERE id=?1 AND document=?2",
                        params![row.id, row.raw, target.to_string()]
                    )? == 1,
                    "Conversation changed after bot review"
                );
                cache_thread(&tx, target, true)?;
            }
        }
        write_documents(&tx, &plan.after)?;
        tx.commit()?;
        for target in &plan.targets {
            self.note_selection_scope(target);
        }
        if let Some(Some(projects)) = plan.after.get("projects.json") {
            self.note_project_scopes(projects);
        }
        Ok(BotLifecycleUndo { plan, token })
    }
    pub(crate) fn undo_bot_lifecycle(&mut self, undo: &BotLifecycleUndo) -> Result<()> {
        let plan = &undo.plan;
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        document_cas(&tx, &plan.after)?;
        if plan.deleting {
            restore_rows_in_transaction(&tx, &plan.rows, &undo.token)?;
        } else {
            for (row, target) in plan.rows.iter().zip(&plan.targets) {
                let raw: String =
                    tx.query_row("SELECT document FROM threads WHERE id=?1", [&row.id], |r| {
                        r.get(0)
                    })?;
                let expected_raw = target.to_string();
                ensure!(
                    raw == expected_raw,
                    "A kept conversation changed; bot Undo was refused"
                );
            }
            for row in &plan.rows {
                let target: Value = serde_json::from_str(&row.raw)?;
                tx.execute(
                    "UPDATE threads SET document=?2 WHERE id=?1",
                    params![row.id, row.raw],
                )?;
                cache_thread(&tx, &target, true)?;
            }
        }
        write_documents(&tx, &plan.before)?;
        tx.commit()?;
        for row in &plan.rows {
            self.note_selection_scope(&serde_json::from_str(&row.raw)?);
        }
        if let Some(Some(projects)) = plan.before.get("projects.json") {
            self.note_project_scopes(projects);
        }
        Ok(())
    }
}
impl BotLifecycleUndo {
    pub(crate) fn thread_ids(&self) -> Vec<String> {
        self.plan.rows.iter().map(|row| row.id.clone()).collect()
    }
}
