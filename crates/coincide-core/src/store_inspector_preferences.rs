//! Native presentation preferences compare the full effective UIState inside
//! one transaction. Captured original bytes and all thread rows stay untouched.
use super::*;
use crate::inspector_preferences::{self as preferences, Panel};
const DOCUMENT: &str = "ui-state.json";
pub(super) fn read_ui_state(db: &Connection) -> Result<Option<Value>> {
    const LIMIT: i64 = 2 * 1024 * 1024;
    let local:Option<(Option<Vec<u8>>,i64)>=db.query_row("SELECT CASE WHEN length(CAST(document AS BLOB))<=?1 THEN CAST(document AS BLOB) ELSE NULL END,length(CAST(document AS BLOB)) FROM documents WHERE name='ui-state.json'",[LIMIT],|row|Ok((row.get(0)?,row.get(1)?))).optional()?;
    let captured = if local.is_some() {
        local
    } else {
        db.query_row("SELECT CASE WHEN length(data)<=?1 THEN data ELSE NULL END,length(data) FROM original_files WHERE path='ui-state.json'",[LIMIT],|row|Ok((row.get(0)?,row.get(1)?))).optional()?
    };
    let Some((raw, length)) = captured else {
        return Ok(None);
    };
    ensure!(
        length <= LIMIT,
        "Saved window state exceeds safe inspector limit"
    );
    let raw = raw.context("Saved window state is unavailable")?;
    Ok(Some(serde_json::from_slice(&raw)?))
}
impl Store {
    pub fn native_inspector_document(&self) -> Result<Option<Value>> {
        read_ui_state(self.connection()?)
    }
    pub fn remember_native_inspector_panel(
        &mut self,
        expected: Option<&Value>,
        thread: &str,
        panel: Option<Panel>,
    ) -> Result<Value> {
        let id = self
            .resolve_thread_id(Uuid::parse_str(thread)?)?
            .context("Inspector conversation no longer exists")?;
        let source = expected.cloned().unwrap_or_else(|| json!({}));
        if panel.is_some_and(Panel::window_wide) {
            return Ok(source);
        }
        let next = preferences::updated(&source, &id, panel)?;
        self.save_native_ui_document_if_unchanged(expected, &next, Some(&id))?;
        Ok(next)
    }
    pub(crate) fn save_native_ui_document_if_unchanged(
        &mut self,
        expected: Option<&Value>,
        next: &Value,
        thread: Option<&str>,
    ) -> Result<()> {
        ensure!(
            next.is_object() && serde_json::to_vec(next)?.len() <= 2 * 1024 * 1024,
            "Saved window state exceeds safe metadata limits"
        );
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        if let Some(id) = thread {
            ensure_not_deleted(&tx, id)?;
            ensure!(
                tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM threads WHERE id=?1)",
                    [id],
                    |row| row.get::<_, bool>(0)
                )?,
                "Inspector conversation disappeared"
            );
        }
        let actual = read_ui_state(&tx)?;
        ensure!(
            actual.as_ref() == expected,
            "Saved inspector state changed; reload before remembering the panel"
        );
        if expected != Some(next) {
            tx.execute("INSERT INTO documents(name,document) VALUES (?1,?2) ON CONFLICT(name) DO UPDATE SET document=excluded.document",params![DOCUMENT,next.to_string()])?;
        }
        tx.commit()?;
        Ok(())
    }
}
#[cfg(test)]
#[path = "store_inspector_preferences_tests.rs"]
mod tests;
