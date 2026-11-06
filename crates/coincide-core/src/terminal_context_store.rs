//! One-field terminal excerpt commit with exact raw-row CAS and cache rollback.
use super::*;
impl Store {
    pub(crate) fn terminal_context_source(&self, id: &str) -> Result<String> {
        Ok(self.connection()?.query_row(
            "SELECT document FROM threads WHERE id=?1",
            [id],
            |row| row.get(0),
        )?)
    }
    pub(crate) fn commit_terminal_context(
        &mut self,
        id: &str,
        source: &str,
        context: &Value,
    ) -> Result<()> {
        crate::composer_context::validate(context)?;
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let current: String =
            tx.query_row("SELECT document FROM threads WHERE id=?1", [id], |row| {
                row.get(0)
            })?;
        ensure!(
            current == source,
            "Conversation changed; select terminal text again"
        );
        let mut thread: Value = serde_json::from_str(&current)?;
        ensure!(
            validate_thread(&thread)? == id,
            "Conversation identity changed"
        );
        thread["draftContext"] = context.clone();
        ensure!(
            tx.execute(
                "UPDATE threads SET document=?2 WHERE id=?1",
                params![id, thread.to_string()]
            )? == 1,
            "Conversation is unavailable"
        );
        cache_thread(&tx, &thread, false)?;
        tx.commit()?;
        Ok(())
    }
}
