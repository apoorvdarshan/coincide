//! Native empty-thread reuse and persisted snooze wake transactions. Only the
//! selected rows are decoded; original imported bytes are never rewritten.
use super::*;
pub(crate) struct NewThreadRow {
    changes: u64,
    external: i64,
    source: Option<String>,
    target: Value,
}
impl NewThreadRow {
    pub(crate) fn id(&self) -> &str {
        self.target["id"].as_str().unwrap_or("")
    }
}
impl Store {
    pub(crate) fn native_idle_candidate(&self, id: &str) -> Result<Option<Value>> {
        let raw:Option<String>=self.connection()?.query_row("SELECT CASE WHEN length(CAST(document AS BLOB))<=8388608 THEN document ELSE NULL END FROM threads WHERE id=?1",[id],|row|row.get(0))?;
        raw.map(|raw| Ok(serde_json::from_str(&raw)?)).transpose()
    }
    pub(crate) fn prepare_native_new_row(
        &self,
        source: Option<&Value>,
        fresh: Value,
        changes: u64,
        external: i64,
    ) -> Result<NewThreadRow> {
        let target = source.cloned().unwrap_or(fresh);
        let id = validate_thread(&target)?;
        let db = self.connection()?;
        let raw: Option<String> = db
            .query_row("SELECT document FROM threads WHERE id=?1", [id], |r| {
                r.get(0)
            })
            .optional()?;
        ensure!(
            source.is_some() == raw.is_some(),
            "New-thread candidate changed"
        );
        if let (Some(source), Some(raw)) = (source, raw.as_ref()) {
            ensure!(
                serde_json::from_str::<Value>(raw)? == *source,
                "Empty thread changed before admission"
            );
        }
        ensure!(
            db.total_changes() == changes
                && db.query_row("PRAGMA data_version", [], |r| r.get::<_, i64>(0))? == external,
            "Store changed during New Thread preparation; retry"
        );
        Ok(NewThreadRow {
            changes,
            external,
            source: raw,
            target,
        })
    }
    pub(crate) fn apply_native_new_row(&mut self, row: NewThreadRow) -> Result<(Value, bool)> {
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure!(
            tx.total_changes() == row.changes
                && tx.query_row("PRAGMA data_version", [], |r| r.get::<_, i64>(0))? == row.external,
            "Store changed after New Thread admission; retry"
        );
        let id = validate_thread(&row.target)?;
        let raw: Option<String> = tx
            .query_row("SELECT document FROM threads WHERE id=?1", [id], |r| {
                r.get(0)
            })
            .optional()?;
        ensure!(raw == row.source, "New-thread candidate changed; retry");
        let created = raw.is_none();
        if created {
            ensure_not_deleted(&tx, id)?;
            tx.execute(
                "INSERT INTO threads(id,document) VALUES (?1,?2)",
                params![id, row.target.to_string()],
            )?;
            cache_thread(&tx, &row.target, true)?;
        }
        tx.commit()?;
        Ok((row.target, created))
    }
    /// Swift ThreadSnooze.schedule: due conversations lose their snooze and move
    /// to the top at the current time. No agent starts and no future snooze is
    /// cleared merely because a running/approval row is temporarily visible.
    pub(crate) fn wake_due_snoozes(
        &mut self,
        now: f64,
        blocked: &std::collections::HashSet<String>,
    ) -> Result<usize> {
        ensure!(now.is_finite(), "Invalid snooze clock");
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let rows = {
            let mut query=tx.prepare("SELECT t.id,s.snoozed_until FROM thread_summaries s JOIN threads t ON t.id=s.id COLLATE NOCASE WHERE s.snoozed_until<=?1 AND NOT EXISTS(SELECT 1 FROM imported_threads i WHERE i.id=t.id COLLATE NOCASE) ORDER BY s.snoozed_until,t.id LIMIT 64")?;
            query
                .query_map([now], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?
        };
        let mut count = 0;
        for (id, expected) in rows {
            if blocked.contains(&id.to_ascii_lowercase()) {
                continue;
            }
            let raw:Option<String>=tx.query_row("SELECT CASE WHEN length(CAST(document AS BLOB))<=8388608 THEN document ELSE NULL END FROM threads WHERE id=?1",[&id],|row|row.get(0))?;
            let raw = raw.context("Snoozed conversation exceeds the 8 MiB wake limit")?;
            let mut thread: Value = serde_json::from_str(&raw)?;
            ensure!(
                validate_thread(&thread)? == id
                    && snooze_timestamp(&thread["snoozedUntil"]) == Some(expected),
                "Snooze cache is stale; no conversation was changed"
            );
            thread["snoozedUntil"] = Value::Null;
            thread["updatedAt"] = json!(now);
            ensure_not_deleted(&tx, &id)?;
            let changed = tx.execute(
                "UPDATE threads SET document=?2 WHERE id=?1 AND document=?3",
                params![id, thread.to_string(), raw],
            )?;
            ensure!(changed == 1, "Snoozed conversation changed during wake");
            cache_thread(&tx, &thread, false)?;
            count += 1;
        }
        tx.commit()?;
        Ok(count)
    }
}
