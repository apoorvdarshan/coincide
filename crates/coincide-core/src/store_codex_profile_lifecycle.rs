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
impl Store {
    pub(crate) fn revoke_legacy_codex_profile(
        &mut self,
        expected: &Value,
        id: &str,
        before: Option<&str>,
        after: &str,
        threads: &[Value],
    ) -> Result<()> {
        ensure!(
            after.len() <= 1024 * 1024,
            "Native account registry exceeds its bound"
        );
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
            "Codex profiles changed; review removal again"
        );
        crate::codex_login_profiles::account(&current, id)?;
        let native: Option<String> = tx
            .query_row(
                "SELECT value FROM metadata WHERE key='native-login-accounts-v1/codex'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        ensure!(
            native.as_deref() == before,
            "Native accounts changed; review removal again"
        );
        let affected = provider_account_removal::affected(&tx, "codex", id)?;
        ensure!(
            affected == threads,
            "Profile conversations changed; review removal again"
        );
        let mut changed = Vec::new();
        for mut thread in affected {
            let thread_id = validate_thread(&thread)?.to_owned();
            ensure_not_deleted(&tx, &thread_id)?;
            thread["selection"]
                .as_object_mut()
                .context("Malformed profile selection")?
                .remove("accountID");
            tx.execute(
                "UPDATE threads SET document=?2 WHERE id=?1",
                params![thread_id, thread.to_string()],
            )?;
            cache_thread(&tx, &thread, false)?;
            tx.execute(
                "DELETE FROM metadata WHERE key=?1",
                [format!("native-account-selection-v1/{thread_id}")],
            )?;
            changed.push(thread);
        }
        current["accounts"].as_object_mut().unwrap().remove(id);
        if let Some(order) = current["order"].as_array_mut() {
            order.retain(|row| row.as_str() != Some(id));
        }
        tx.execute(
            "UPDATE documents SET document=?2 WHERE name=?1",
            params![crate::codex_login_profiles::DOCUMENT, current.to_string()],
        )?;
        tx.execute("INSERT INTO metadata(key,value) VALUES('native-login-accounts-v1/codex',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [after])?;
        tx.commit()?;
        for thread in changed {
            self.note_selection_scope(&thread);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_removal_changes_only_native_account_choice_and_preserves_imported_originals() {
        let root = tempfile::tempdir().unwrap();
        let mut store = Store::open(&root.path().join("private/state.sqlite")).unwrap();
        let account = uuid::Uuid::new_v4().to_string();
        let native = uuid::Uuid::new_v4().to_string();
        let imported = uuid::Uuid::new_v4().to_string();
        let make = |id: &str| json!({"id":id,"title":"Keep","draft":"Keep draft","items":[{"text":"Keep"}],"selection":{"provider":"codex","accountID":account,"modelID":"default"},"unknown":true});
        let before = make(&native);
        let imported_before = make(&imported);
        store.save(&before).unwrap();
        store.save(&imported_before).unwrap();
        store
            .connection_mut()
            .unwrap()
            .execute("INSERT INTO imported_threads(id) VALUES(?1)", [&imported])
            .unwrap();
        let original = b"synthetic original profile bytes";
        store
            .connection_mut()
            .unwrap()
            .execute(
                "INSERT INTO original_files(path,data) VALUES(?1,?2)",
                params!["rust-codex-login-profiles.json", original.as_slice()],
            )
            .unwrap();
        let configuration = json!({"version":1,"accounts":{&account:{"name":"Synthetic","auth":"login"}},"order":[account],"future":{"keep":true}});
        store
            .save_document(crate::codex_login_profiles::DOCUMENT, &configuration)
            .unwrap();
        store
            .revoke_legacy_codex_profile(
                &configuration,
                &account,
                None,
                "synthetic native tombstone",
                &[before.clone()],
            )
            .unwrap();
        let mut expected = before;
        expected["selection"]
            .as_object_mut()
            .unwrap()
            .remove("accountID");
        assert_eq!(store.thread(&native).unwrap(), expected);
        assert_eq!(store.thread(&imported).unwrap(), imported_before);
        assert_eq!(
            store
                .original(crate::codex_login_profiles::DOCUMENT)
                .unwrap()
                .unwrap(),
            original
        );
        let mut expected = configuration;
        expected["accounts"]
            .as_object_mut()
            .unwrap()
            .remove(&account);
        expected["order"] = json!([]);
        assert_eq!(
            store
                .local_document(crate::codex_login_profiles::DOCUMENT)
                .unwrap(),
            Some(expected)
        );
    }
}
