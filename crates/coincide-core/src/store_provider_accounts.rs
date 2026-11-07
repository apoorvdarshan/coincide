//! Protected native account envelopes. This namespace is not a document and
//! cannot be written through settings/import JSON. HMAC validation lives above.
use super::*;
fn key(provider: &str) -> String {
    format!("native-login-accounts-v1/{provider}")
}
impl Store {
    pub(crate) fn native_accounts_payload(&self, provider: &str) -> Result<Option<String>> {
        Ok(self
            .connection()?
            .query_row(
                "SELECT value FROM metadata WHERE key=?1",
                [key(provider)],
                |row| row.get(0),
            )
            .optional()?)
    }
    pub(crate) fn save_native_accounts_payload(
        &mut self,
        provider: &str,
        expected: Option<&str>,
        payload: &str,
    ) -> Result<()> {
        ensure!(
            payload.len() <= 1024 * 1024,
            "Native account registry exceeds its bound"
        );
        let transaction = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let current: Option<String> = transaction
            .query_row(
                "SELECT value FROM metadata WHERE key=?1",
                [key(provider)],
                |row| row.get(0),
            )
            .optional()?;
        ensure!(
            current.as_deref() == expected,
            "Native account registry changed; reload before saving"
        );
        transaction.execute("INSERT INTO metadata(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",params![key(provider),payload])?;
        transaction.commit()?;
        Ok(())
    }
}

impl Store {
    pub(crate) fn native_account_selection(&self, id: &str) -> Result<Option<String>> {
        Ok(self
            .connection()?
            .query_row(
                "SELECT value FROM metadata WHERE key=?1",
                [format!("native-account-selection-v1/{id}")],
                |row| row.get(0),
            )
            .optional()?)
    }
    pub(crate) fn save_native_account_selection(
        &mut self,
        expected: &Value,
        next: &Value,
        grant: Option<&str>,
    ) -> Result<()> {
        let id = validate_thread(next)?;
        ensure!(
            expected["id"] == id,
            "Native account selection source mismatch"
        );
        let mut allowed = expected.clone();
        allowed["selection"]["accountID"] = next["selection"]["accountID"].clone();
        if next["selection"].get("accountID").is_none() {
            allowed["selection"]
                .as_object_mut()
                .context("Invalid selection")?
                .remove("accountID");
        }
        ensure!(
            allowed == *next,
            "Account selection cannot alter other conversation state"
        );
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure_not_deleted(&tx, id)?;
        let raw: String =
            tx.query_row("SELECT document FROM threads WHERE id=?1", [id], |row| {
                row.get(0)
            })?;
        ensure!(
            serde_json::from_str::<Value>(&raw)? == *expected,
            "Conversation changed before account selection"
        );
        ensure!(
            !tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1)",
                [id],
                |row| row.get::<_, bool>(0)
            )?,
            "Imported conversation cannot select native accounts"
        );
        tx.execute(
            "UPDATE threads SET document=?2 WHERE id=?1",
            params![id, next.to_string()],
        )?;
        cache_thread(&tx, next, false)?;
        let key = format!("native-account-selection-v1/{id}");
        if let Some(grant) = grant {
            tx.execute("INSERT INTO metadata(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key,grant])?;
        } else {
            tx.execute("DELETE FROM metadata WHERE key=?1", [key])?;
        }
        tx.commit()?;
        self.note_selection_scope(next);
        Ok(())
    }
}

/// Pure thread writes may revoke an old native association but can never mint
/// one. The native selector writes its new signed marker in its own transaction.
pub(super) fn invalidate_changed_selection(db: &Connection, document: &Value) -> Result<()> {
    let id = validate_thread(document)?;
    db.execute("DELETE FROM metadata WHERE key=?1 AND EXISTS(SELECT 1 FROM threads WHERE id=?2 AND (json_extract(document,'$.selection.provider') IS NOT json_extract(?3,'$.selection.provider') OR json_extract(document,'$.selection.accountID') IS NOT json_extract(?3,'$.selection.accountID')))",params![format!("native-account-selection-v1/{id}"),id,document.to_string()])?;
    Ok(())
}
