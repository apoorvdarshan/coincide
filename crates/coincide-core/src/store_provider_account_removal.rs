//! Atomic native account revocation and conversation fallback. Imported source
//! rows/original bytes stay untouched; only accountID changes in native chats.
use super::*;
fn affected(db: &Connection, provider: &str, account: &str) -> Result<Vec<Value>> {
    let mut statement=db.prepare("SELECT document FROM threads WHERE json_extract(document,'$.selection.provider')=?1 AND json_extract(document,'$.selection.accountID')=?2 AND NOT EXISTS(SELECT 1 FROM imported_threads WHERE imported_threads.id=threads.id) ORDER BY id")?;
    let rows = statement.query_map(params![provider, account], |row| row.get::<_, String>(0))?;
    let mut documents = Vec::new();
    let mut bytes = 0usize;
    for row in rows {
        let row = row?;
        bytes = bytes.saturating_add(row.len());
        ensure!(
            documents.len() < 10_000 && bytes <= 64 * 1024 * 1024,
            "Account conversations exceed this removal review's bound"
        );
        documents.push(serde_json::from_str(&row)?);
    }
    Ok(documents)
}
impl Store {
    pub(crate) fn native_account_removal_threads(
        &self,
        provider: &str,
        account: &str,
    ) -> Result<Vec<Value>> {
        affected(self.connection()?, provider, account)
    }
    pub(crate) fn revoke_native_account(
        &mut self,
        provider: &str,
        account: &str,
        expected_registry: &str,
        registry: &str,
        expected_threads: &[Value],
    ) -> Result<()> {
        ensure!(
            registry.len() <= 1024 * 1024,
            "Native account registry exceeds its bound"
        );
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let key = format!("native-login-accounts-v1/{provider}");
        let raw: String =
            tx.query_row("SELECT value FROM metadata WHERE key=?1", [&key], |row| {
                row.get(0)
            })?;
        ensure!(
            raw == expected_registry,
            "Account registry changed; review removal again"
        );
        let current = affected(&tx, provider, account)?;
        ensure!(
            current == expected_threads,
            "Account conversations changed; review removal again"
        );
        let mut changed = Vec::new();
        for old in current {
            let mut next = old.clone();
            let id = validate_thread(&old)?;
            ensure_not_deleted(&tx, id)?;
            next["selection"]
                .as_object_mut()
                .context("Malformed account selection")?
                .remove("accountID");
            tx.execute(
                "UPDATE threads SET document=?2 WHERE id=?1",
                params![id, next.to_string()],
            )?;
            cache_thread(&tx, &next, false)?;
            tx.execute(
                "DELETE FROM metadata WHERE key=?1",
                [format!("native-account-selection-v1/{id}")],
            )?;
            changed.push(next);
        }
        tx.execute(
            "UPDATE metadata SET value=?2 WHERE key=?1",
            params![key, registry],
        )?;
        tx.commit()?;
        for next in changed {
            self.note_selection_scope(&next);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn imported_rows_and_original_bytes_are_untouched_by_account_fallback() {
        let root = tempfile::tempdir().unwrap();
        let mut store = Store::open(&root.path().join("private/state.sqlite")).unwrap();
        let account = Uuid::new_v4().to_string();
        let native = Uuid::new_v4().to_string();
        let imported = Uuid::new_v4().to_string();
        for id in [&native, &imported] {
            store.save(&json!({"id":id,"title":"Keep","items":[],"selection":{"provider":"grok","accountID":account,"modelID":"default"},"draft":"Keep"})).unwrap();
        }
        store
            .connection_mut()
            .unwrap()
            .execute("INSERT INTO imported_threads(id) VALUES(?1)", [&imported])
            .unwrap();
        let original = b"synthetic original bytes, preserve exact";
        store
            .connection_mut()
            .unwrap()
            .execute(
                "INSERT INTO original_files(path,data) VALUES(?1,?2)",
                params![format!("threads/{imported}.json"), original.as_slice()],
            )
            .unwrap();
        store
            .save_native_accounts_payload("grok", None, "synthetic signed envelope boundary")
            .unwrap();
        let expected = store
            .native_account_removal_threads("grok", &account)
            .unwrap();
        assert_eq!(expected.len(), 1);
        let imported_before = store.thread(&imported).unwrap();
        store
            .revoke_native_account(
                "grok",
                &account,
                "synthetic signed envelope boundary",
                "synthetic revoked envelope",
                &expected,
            )
            .unwrap();
        assert!(store.thread(&native).unwrap()["selection"]["accountID"].is_null());
        assert_eq!(store.thread(&imported).unwrap(), imported_before);
        let after: Vec<u8> = store
            .connection()
            .unwrap()
            .query_row(
                "SELECT data FROM original_files WHERE path=?1",
                [format!("threads/{imported}.json")],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(after, original);
    }
}
