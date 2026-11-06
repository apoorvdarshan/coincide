//! One-field reply quote commit; original files and every other draft/history
//! field survive an exact raw-row compare in the same SQLite transaction.
use super::*;
impl Store {
    pub(crate) fn native_reply_context_source(&self, id: &str) -> Result<String> {
        let raw:Option<String>=self.connection()?.query_row("SELECT CASE WHEN length(CAST(document AS BLOB))<=8388608 THEN document ELSE NULL END FROM threads WHERE id=?1",[id],|row|row.get(0))?;
        raw.context("Reply source conversation exceeds 8 MiB")
    }
    pub(crate) fn commit_native_reply_context(
        &mut self,
        id: &str,
        source: &str,
        context: &Value,
    ) -> Result<()> {
        crate::composer_context::validate(context)?;
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let raw: String =
            tx.query_row("SELECT document FROM threads WHERE id=?1", [id], |row| {
                row.get(0)
            })?;
        ensure!(
            raw == source,
            "Conversation changed; select the reply text again"
        );
        ensure!(
            !tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1 COLLATE NOCASE)",
                [id],
                |row| row.get::<_, bool>(0)
            )?,
            "Imported history cannot receive reply context"
        );
        let mut thread: Value = serde_json::from_str(&raw)?;
        ensure!(
            validate_thread(&thread)? == id,
            "Conversation identity changed"
        );
        ensure_not_deleted(&tx, id)?;
        thread["draftContext"] = context.clone();
        ensure!(
            tx.execute(
                "UPDATE threads SET document=?2 WHERE id=?1 AND document=?3",
                params![id, thread.to_string(), raw]
            )? == 1,
            "Reply source changed during context commit"
        );
        cache_thread(&tx, &thread, false)?;
        tx.commit()?;
        Ok(())
    }
}
