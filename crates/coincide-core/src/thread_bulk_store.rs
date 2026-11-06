//! Compare every reviewed row inside one transaction before changing flags.
use super::*;
const MAX_ROWS: usize = 50;
const MAX_ROW_BYTES: usize = 8 * 1024 * 1024;
const MAX_BYTES: usize = 32 * 1024 * 1024;
#[derive(Clone)]
pub(crate) struct FlagRow {
    pub id: String,
    pub title: String,
    pub source: String,
    pub target: String,
    pub before: Option<Value>,
    pub after: Option<Value>,
    changed: bool,
}
impl FlagRow {
    pub fn reversed(&self) -> Self {
        Self {
            id: self.id.clone(),
            title: self.title.clone(),
            source: self.target.clone(),
            target: self.source.clone(),
            before: self.after.clone(),
            after: self.before.clone(),
            changed: self.changed,
        }
    }
    pub fn changed(&self) -> bool {
        self.changed
    }
}
impl Store {
    pub(crate) fn prepare_flag_rows(
        &self,
        ids: &[String],
        field: &'static str,
        desired: bool,
    ) -> Result<Vec<FlagRow>> {
        ensure!(
            !ids.is_empty() && ids.len() <= MAX_ROWS,
            "Select 1–50 conversations"
        );
        ensure!(
            matches!(field, "isPinned" | "isArchived"),
            "Unsupported bulk flag"
        );
        let mut seen = std::collections::HashSet::new();
        let mut rows = Vec::with_capacity(ids.len());
        let mut bytes = 0usize;
        for id in ids {
            ensure!(
                seen.insert(Uuid::parse_str(id)?),
                "Duplicate conversation identity"
            );
            let (stored, source): (String, String) = self
                .connection()?
                .query_row(
                    "SELECT id,document FROM threads WHERE id=?1 COLLATE NOCASE",
                    [id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .context("A selected conversation is unavailable")?;
            bytes = bytes.saturating_add(source.len());
            ensure!(
                source.len() <= MAX_ROW_BYTES && bytes <= MAX_BYTES,
                "Selected conversations exceed the 8 MiB per conversation / 32 MiB batch limit"
            );
            let mut value: Value = serde_json::from_str(&source)?;
            ensure!(
                validate_thread(&value)? == stored,
                "Conversation identity changed"
            );
            let before = value.get(field).cloned();
            ensure!(
                before
                    .as_ref()
                    .is_none_or(|v| v.is_boolean() || v.is_null()),
                "A selected conversation has an invalid saved flag"
            );
            let current = before.as_ref().and_then(Value::as_bool).unwrap_or(false);
            let title = text(&value, "title").chars().take(120).collect();
            let (target, after) = if current == desired {
                (source.clone(), before.clone())
            } else {
                value[field] = json!(desired);
                (value.to_string(), Some(json!(desired)))
            };
            rows.push(FlagRow {
                id: stored,
                title,
                source,
                target,
                before,
                after,
                changed: current != desired,
            });
        }
        Ok(rows)
    }
    pub(crate) fn apply_flag_rows(&mut self, rows: &[FlagRow]) -> Result<()> {
        ensure!(rows.len() <= MAX_ROWS, "Too many conversations");
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        // All comparisons precede every write, including rows already in the
        // requested state. A failure leaves the entire batch unchanged.
        for row in rows {
            let current: String = tx
                .query_row("SELECT document FROM threads WHERE id=?1", [&row.id], |r| {
                    r.get(0)
                })
                .context("A selected conversation is unavailable")?;
            ensure!(
                current == row.source,
                "A selected conversation changed; review the selection again"
            );
        }
        for row in rows.iter().filter(|row| row.changed()) {
            let value: Value = serde_json::from_str(&row.target)?;
            ensure!(
                validate_thread(&value)? == row.id,
                "Conversation identity changed"
            );
            ensure!(
                tx.execute(
                    "UPDATE threads SET document=?2 WHERE id=?1",
                    params![row.id, row.target]
                )? == 1,
                "Conversation disappeared"
            );
            cache_thread(&tx, &value, false)?;
        }
        tx.commit()?;
        Ok(())
    }
}
