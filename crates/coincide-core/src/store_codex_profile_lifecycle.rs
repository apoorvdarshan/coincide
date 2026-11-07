//! CAS for the Rust-only legacy subscription profile document. Originals stay immutable.
use super::*;
pub(crate) struct CodexAuthChange<'a> {
    pub before: Option<&'a str>,
    pub after: &'a str,
    pub legacy: Option<&'a Value>,
    pub id: &'a str,
    pub threads: &'a [Value],
    pub grants: Option<&'a [(String, String)]>,
}
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

impl Store {
    pub(crate) fn change_native_codex_auth(
        &mut self,
        plan: CodexAuthChange<'_>,
        change_owner: impl FnOnce() -> Result<()>,
    ) -> Result<()> {
        let CodexAuthChange {
            before,
            after,
            legacy,
            id,
            threads,
            grants,
        } = plan;
        ensure!(
            after.len() <= 1024 * 1024,
            "Native account registry exceeds its bound"
        );
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let current: Option<String> = tx
            .query_row(
                "SELECT value FROM metadata WHERE key='native-login-accounts-v1/codex'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        ensure!(
            current.as_deref() == before,
            "Native accounts changed; review authentication again"
        );
        ensure!(
            provider_account_removal::affected(&tx, "codex", id)? == threads,
            "Account conversations changed; review authentication again"
        );
        if let Some(legacy) = legacy {
            let raw: String = tx.query_row(
                "SELECT document FROM documents WHERE name=?1",
                [crate::codex_login_profiles::DOCUMENT],
                |row| row.get(0),
            )?;
            let mut current: Value = serde_json::from_str(&raw)?;
            ensure!(
                &current == legacy,
                "Subscription profiles changed; review authentication again"
            );
            crate::codex_login_profiles::account(&current, id)?;
            current["accounts"].as_object_mut().unwrap().remove(id);
            if let Some(order) = current["order"].as_array_mut() {
                order.retain(|row| row.as_str() != Some(id));
            }
            tx.execute(
                "UPDATE documents SET document=?2 WHERE name=?1",
                params![crate::codex_login_profiles::DOCUMENT, current.to_string()],
            )?;
            let grants =
                grants.context("Legacy conversion requires exact native selection grants")?;
            ensure!(
                grants.len() == threads.len(),
                "Converted selection set changed"
            );
            for (thread, (thread_id, grant)) in threads.iter().zip(grants) {
                ensure!(
                    thread["id"].as_str() == Some(thread_id.as_str()) && grant.len() <= 16_384,
                    "Converted selection identity or size is invalid"
                );
                ensure_not_deleted(&tx, thread_id)?;
                tx.execute("INSERT INTO metadata(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![format!("native-account-selection-v1/{thread_id}"), grant])?;
            }
        } else {
            ensure!(
                grants.is_none(),
                "Native method changes cannot mint selection grants"
            );
        }
        // Every document/thread/registry CAS succeeded while IMMEDIATE holds.
        // A stale review never touches its private owner-file generation.
        change_owner()?;
        tx.execute("INSERT INTO metadata(key,value) VALUES('native-login-accounts-v1/codex',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [after])?;
        tx.commit()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn owner_failure_rolls_back_legacy_row_and_selection_grants() {
        let root = tempfile::tempdir().unwrap();
        let mut store = Store::open(&root.path().join("private/state.sqlite")).unwrap();
        let account = uuid::Uuid::new_v4().to_string();
        let thread = json!({"id":uuid::Uuid::new_v4().to_string(),"title":"Keep","items":[],"selection":{"provider":"codex","modelID":"default","accountID":account}});
        store.save(&thread).unwrap();
        let configuration = json!({"version":1,"accounts":{&account:{"name":"Synthetic","auth":"login"}},"future":true});
        store
            .save_document(crate::codex_login_profiles::DOCUMENT, &configuration)
            .unwrap();
        let grants = vec![(
            thread["id"].as_str().unwrap().to_owned(),
            "synthetic-grant".into(),
        )];
        let called = std::cell::Cell::new(false);
        assert!(
            store
                .change_native_codex_auth(
                    CodexAuthChange {
                        before: None,
                        after: "synthetic-registry",
                        legacy: Some(&configuration),
                        id: &account,
                        threads: std::slice::from_ref(&thread),
                        grants: Some(&grants)
                    },
                    || {
                        called.set(true);
                        anyhow::bail!("Synthetic owner write failure")
                    }
                )
                .is_err()
        );
        assert!(called.get());
        assert_eq!(
            store
                .local_document(crate::codex_login_profiles::DOCUMENT)
                .unwrap(),
            Some(configuration)
        );
        assert!(store.native_accounts_payload("codex").unwrap().is_none());
        assert!(
            store
                .native_account_selection(thread["id"].as_str().unwrap())
                .unwrap()
                .is_none()
        );
        assert_eq!(
            store.thread(thread["id"].as_str().unwrap()).unwrap(),
            thread
        );
    }
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
        let original = br#"{ "version": 1, "accounts": {}, "syntheticOriginal": true }"#;
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
                std::slice::from_ref(&before),
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
