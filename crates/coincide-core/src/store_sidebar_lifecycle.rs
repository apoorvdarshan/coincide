//! Source-owned full-row CAS for native sidebar moves. No caller JSON writer.
use super::*;
#[derive(Clone)]
pub(crate) struct SidebarRow {
    pub id: String,
    pub source: String,
    pub target: String,
    projects: Value,
    changes: u64,
    external: i64,
}
impl Store {
    pub(crate) fn capture_sidebar_row(&self, source: &Value, target: &Value) -> Result<SidebarRow> {
        let id = validate_thread(source)?;
        ensure!(
            validate_thread(target)? == id,
            "Conversation identity changed"
        );
        let db = self.connection()?;
        let changes = db.total_changes();
        let external = db.query_row("PRAGMA data_version", [], |row| row.get(0))?;
        let raw: String =
            db.query_row("SELECT document FROM threads WHERE id=?1", [&id], |row| {
                row.get(0)
            })?;
        ensure!(
            raw.len() <= 8 * 1024 * 1024,
            "Conversation exceeds native review bound"
        );
        ensure!(
            serde_json::from_str::<Value>(&raw)? == *source,
            "Conversation changed while preparing review"
        );
        let projects = self.projects()?;
        ensure!(
            db.total_changes() == changes
                && db.query_row("PRAGMA data_version", [], |row| row.get::<_, i64>(0))? == external,
            "Store changed while preparing review"
        );
        Ok(SidebarRow {
            id,
            source: raw,
            target: target.to_string(),
            projects,
            changes,
            external,
        })
    }
    pub(crate) fn validate_sidebar_row(&self, row: &SidebarRow) -> Result<()> {
        let db = self.connection()?;
        ensure!(
            db.total_changes() == row.changes
                && db.query_row("PRAGMA data_version", [], |r| r.get::<_, i64>(0))? == row.external,
            "Store changed after native review"
        );
        ensure!(
            self.projects()? == row.projects,
            "Projects changed after native review"
        );
        let raw: String =
            db.query_row("SELECT document FROM threads WHERE id=?1", [&row.id], |r| {
                r.get(0)
            })?;
        ensure!(
            raw == row.source,
            "Conversation changed after native review"
        );
        Ok(())
    }
    pub(crate) fn apply_sidebar_row(&mut self, row: &SidebarRow) -> Result<()> {
        self.validate_sidebar_row(row)?;
        let target: Value = serde_json::from_str(&row.target)?;
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure!(
            tx.total_changes() == row.changes
                && tx.query_row("PRAGMA data_version", [], |r| r.get::<_, i64>(0))? == row.external,
            "Store changed while applying native review"
        );
        ensure!(
            tx.execute(
                "UPDATE threads SET document=?3 WHERE id=?1 AND document=?2",
                params![row.id, row.source, row.target]
            )? == 1,
            "Conversation changed after native review"
        );
        cache_thread(&tx, &target, true)?;
        tx.commit()?;
        self.note_selection_scope(&target);
        Ok(())
    }
}
