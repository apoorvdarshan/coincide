//! One field CAS; drafts, unknown objects and all original bytes stay owned.
use super::*;
fn projects(db: &Connection) -> Result<Value> {
    let local: Option<String> = db
        .query_row(
            "SELECT document FROM documents WHERE name='projects.json'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(raw) = local {
        return Ok(serde_json::from_str(&raw)?);
    }
    let original: Option<Vec<u8>> = db
        .query_row(
            "SELECT data FROM original_files WHERE path='projects.json'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    original
        .map(|raw| serde_json::from_slice(&raw).map_err(Into::into))
        .unwrap_or_else(|| Ok(json!([])))
}
impl Store {
    pub(crate) fn file_reference_source(&self, id: &str) -> Result<String> {
        Ok(self
            .connection()?
            .query_row("SELECT document FROM threads WHERE id=?1", [id], |r| {
                r.get(0)
            })?)
    }
    pub(crate) fn commit_file_reference(
        &mut self,
        id: &str,
        source: &str,
        expected_projects: &Value,
        context: &Value,
    ) -> Result<bool> {
        crate::composer_context::validate(context)?;
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let current: String =
            tx.query_row("SELECT document FROM threads WHERE id=?1", [id], |r| {
                r.get(0)
            })?;
        ensure!(
            current == source && projects(&tx)? == *expected_projects,
            "Conversation or project changed; search again"
        );
        let mut value: Value = serde_json::from_str(&current)?;
        ensure!(
            validate_thread(&value)? == id,
            "Conversation identity changed"
        );
        if value.get("draftContext").unwrap_or(&Value::Null) == context {
            return Ok(false);
        }
        value["draftContext"] = context.clone();
        ensure!(
            tx.execute(
                "UPDATE threads SET document=?2 WHERE id=?1",
                params![id, value.to_string()]
            )? == 1,
            "Conversation is unavailable"
        );
        cache_thread(&tx, &value, false)?;
        tx.commit()?;
        Ok(true)
    }
}
