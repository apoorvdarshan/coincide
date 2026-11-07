//! CAS for the Rust-only legacy subscription profile document. Originals stay immutable.
use super::*;
impl Store {
    pub(crate) fn rename_legacy_codex_profile(
        &mut self,
        expected: &Value,
        id: &str,
        name: &str,
    ) -> Result<()> {
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let raw: String = tx.query_row(
            "SELECT document FROM documents WHERE name=?1",
            [crate::codex_login_profiles::DOCUMENT],
            |row| row.get(0),
        )?;
        let mut current: Value = serde_json::from_str(&raw)?;
        ensure!(
            &current == expected,
            "Codex profiles changed; reload before renaming"
        );
        crate::codex_login_profiles::account(&current, id)?;
        current["accounts"][id]["name"] = json!(name);
        tx.execute(
            "UPDATE documents SET document=?2 WHERE name=?1",
            params![crate::codex_login_profiles::DOCUMENT, current.to_string()],
        )?;
        tx.commit()?;
        Ok(())
    }
}
