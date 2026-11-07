//! Explicit native authentication-method review. No credential read/copy/login
//! occurs here. The same private home is retained and prior jobs are fenced.
use super::*;
pub struct PreparedCodexAuthChange {
    source: Value,
    registry: Option<String>,
    legacy: Option<Value>,
    account: Account,
    target: Authentication,
    threads: Vec<Value>,
    _exclusive: LoginHome,
}
impl PreparedCodexAuthChange {
    pub fn name(&self) -> &str {
        &self.account.name
    }
    pub fn conversation_count(&self) -> usize {
        self.threads.len()
    }
    pub fn uses_login(&self) -> bool {
        self.target == Authentication::Login
    }
}
impl Engine {
    pub fn prepare_native_codex_auth_change(
        &mut self,
        id: &str,
        expected: &str,
        login: bool,
        from_legacy: bool,
    ) -> Result<PreparedCodexAuthChange> {
        let target = if login {
            Authentication::Login
        } else {
            Authentication::ApiKey
        };
        if from_legacy {
            ensure!(!login, "This subscription profile already uses Login");
            let plan = self.prepare_native_legacy_codex_removal(id, expected)?;
            return Ok(PreparedCodexAuthChange {
                source: plan.source,
                registry: plan.registry,
                legacy: Some(plan.configuration),
                account: plan.account,
                target,
                threads: plan.threads,
                _exclusive: plan._exclusive,
            });
        }
        self.require_admissions()?;
        let threads = self.store.native_account_removal_threads("codex", id)?;
        removal::ready(self, &threads)?;
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        let registry = self.store.native_accounts_payload("codex")?;
        let payload = read(&owner, "codex", registry.as_deref())?;
        let account = account(&payload, "codex", id)?;
        ensure!(
            account.revision == expected && account.authentication != target,
            "Account changed; review its authentication method again"
        );
        let exclusive =
            LoginHome::capture_mode(&self.store.data_directory()?, account.clone(), true, true)?;
        exclusive.validate()?;
        Ok(PreparedCodexAuthChange {
            source: owner.source.clone(),
            registry,
            legacy: None,
            account,
            target,
            threads,
            _exclusive: exclusive,
        })
    }
    pub fn apply_native_codex_auth_change(&mut self, plan: PreparedCodexAuthChange) -> Result<()> {
        removal::ready(self, &plan.threads)?;
        plan._exclusive.validate()?;
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        ensure!(
            owner.source == plan.source,
            "Account method review belongs to another Store"
        );
        let mut payload = read(&owner, "codex", plan.registry.as_deref())?;
        if let Some(legacy) = &plan.legacy {
            ensure!(
                payload["accounts"].get(&plan.account.id).is_none()
                    && payload["revoked_accounts"].get(&plan.account.id).is_none(),
                "This account identity is already native or revoked"
            );
            ensure!(
                payload["accounts"].as_object().unwrap().len() < 32,
                "Native account limit reached"
            );
            append_order(&mut payload, &plan.account.id)?;
            payload["accounts"][&plan.account.id] = serde_json::to_value(&plan.account)?;
            // Preserve legacy unknown fields as data, never as native authority.
            payload["accounts"][&plan.account.id]["legacyMetadata"] =
                legacy["accounts"][&plan.account.id].clone();
        } else {
            let current = account(&payload, "codex", &plan.account.id)?;
            ensure!(
                serde_json::to_value(current)? == serde_json::to_value(&plan.account)?,
                "Native account changed; review its method again"
            );
        }
        let row = &mut payload["accounts"][&plan.account.id];
        row["authentication"] = serde_json::to_value(plan.target)?;
        row["key_variable"] = json!("OPENAI_API_KEY");
        row["revision"] = json!(Uuid::new_v4().to_string());
        row["launch_revision"] = json!(Uuid::new_v4().to_string());
        let registry = encoded(&owner, &payload)?;
        let grants = if plan.legacy.is_some() {
            Some(plan.threads.iter().map(|thread| {
                let id = required(thread, "id")?;
                Ok((id.to_owned(), encoded(&owner, &json!({"source":owner.source,"purpose":"native-account-selection-v1","thread":id,"provider":"codex","account":plan.account.id}))?))
            }).collect::<Result<Vec<_>>>()?)
        } else {
            None
        };
        // Rotate only after the transaction has checked every CAS. Keep the old
        // bounded nonsecret bytes for recovery if a later write/commit fails.
        use std::io::{Seek, SeekFrom};
        let mut file = &*plan._exclusive._lease;
        let length = file.metadata()?.len();
        ensure!(length <= 64, "Invalid Codex account owner generation");
        let mut old = vec![0; length as usize];
        file.seek(SeekFrom::Start(0))?;
        file.read_exact(&mut old)?;
        let changed = self.store.change_native_codex_auth(
            crate::store::CodexAuthChange {
                before: plan.registry.as_deref(),
                after: &registry,
                legacy: plan.legacy.as_ref(),
                id: &plan.account.id,
                threads: &plan.threads,
                grants: grants.as_deref(),
            },
            || {
                file.seek(SeekFrom::Start(0))?;
                file.write_all(Uuid::new_v4().as_bytes())?;
                file.set_len(16)?;
                file.sync_all()?;
                Ok(())
            },
        );
        if let Err(error) = changed {
            let unchanged = self.store.native_accounts_payload("codex").ok().as_ref()
                == Some(&plan.registry)
                && plan.legacy.as_ref().is_none_or(|expected| {
                    legacy::configuration(&self.store).is_ok_and(|current| current == *expected)
                });
            if unchanged {
                let restored = (|| -> Result<()> {
                    file.seek(SeekFrom::Start(0))?;
                    file.write_all(&old)?;
                    file.set_len(old.len() as u64)?;
                    file.sync_all()?;
                    Ok(())
                })();
                ensure!(
                    restored.is_ok(),
                    "Account method was not saved; private owner recovery is required before retrying"
                );
            }
            return Err(
                error.context("Account method change failed; reload the account before retrying")
            );
        }
        self.revision += 1;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Engine, PathBuf) {
        let (root, mut engine, binary) = super::super::super::super::tests::fixture();
        super::super::super::super::tests::save(&mut engine, "codex", &binary, "synthetic-only");
        (root, engine, binary)
    }
    #[test]
    fn peer_draft_edit_rejects_review_without_rotating_owner_or_minting_grants() {
        let (_root, mut engine, binary) = fixture();
        let row = engine
            .execute(
                "providers.codex.profiles.create",
                &json!({"name":"Synthetic stale review"}),
            )
            .unwrap();
        let id = row["id"].as_str().unwrap();
        let thread = json!({"id":Uuid::new_v4().to_string(),"title":"Keep","draft":"Before","items":[],"selection":{"provider":"codex","accountID":id,"modelID":"default"}});
        engine.store.save(&thread).unwrap();
        let context =
            legacy::LaunchContext::capture(&engine.store.data_directory().unwrap(), id, &binary)
                .unwrap();
        let account = engine.native_legacy_codex_accounts().unwrap().remove(0);
        let plan = engine
            .prepare_native_codex_auth_change(id, &account.revision, false, true)
            .unwrap();
        let mut peer =
            Engine::new(Store::open(&engine.store.resume_source_path().unwrap()).unwrap());
        let mut newer = thread.clone();
        newer["draft"] = json!("Newer peer draft");
        peer.store.save(&newer).unwrap();
        assert!(engine.apply_native_codex_auth_change(plan).is_err());
        assert!(context.acquire_home_lease().is_ok());
        assert!(engine.native_provider_accounts("codex").unwrap().is_empty());
        assert!(engine.validate_native_account_selection(&thread).is_err());
        assert_eq!(
            engine.store.thread(thread["id"].as_str().unwrap()).unwrap(),
            newer
        );
        assert_eq!(engine.native_legacy_codex_accounts().unwrap()[0].id, id);
    }
    #[test]
    fn legacy_conversion_keeps_auth_and_content_but_revokes_old_jobs_and_json_authority() {
        let (_root, mut engine, binary) = fixture();
        let row = engine
            .execute(
                "providers.codex.profiles.create",
                &json!({"name":"Synthetic subscription"}),
            )
            .unwrap();
        let id = row["id"].as_str().unwrap();
        let home =
            legacy::managed_home(&engine.store.data_directory().unwrap(), id, false).unwrap();
        let auth = br#"{"OPENAI_API_KEY":null,"tokens":{"synthetic":true}}"#;
        let mut file = open_file(&home.join("auth.json"), true).unwrap();
        file.write_all(auth).unwrap();
        drop(file);
        let thread = json!({"id":Uuid::new_v4().to_string(),"title":"Keep","draft":"Keep draft","items":[{"text":"Keep history"}],"selection":{"provider":"codex","accountID":id,"modelID":"default"},"sessions":{"codex":"keep-until-explicit-session-admission"},"future":true});
        engine.store.save(&thread).unwrap();
        let old =
            legacy::LaunchContext::capture(&engine.store.data_directory().unwrap(), id, &binary)
                .unwrap();
        let account = engine.native_legacy_codex_accounts().unwrap().remove(0);
        let plan = engine
            .prepare_native_codex_auth_change(id, &account.revision, false, true)
            .unwrap();
        assert_eq!(plan.conversation_count(), 1);
        engine.apply_native_codex_auth_change(plan).unwrap();
        assert_eq!(fs::read(home.join("auth.json")).unwrap(), auth);
        assert_eq!(
            engine.store.thread(thread["id"].as_str().unwrap()).unwrap(),
            thread
        );
        assert!(old.acquire_home_lease().is_err());
        assert!(engine.native_legacy_codex_accounts().unwrap().is_empty());
        assert!(engine.validate_native_account_selection(&thread).is_ok());
        let account = engine.native_provider_accounts("codex").unwrap().remove(0);
        assert!(account.authentication == Authentication::ApiKey && !account.has_key);
        assert!(
            engine
                .execute(
                    "providers.codex.profiles.login.start",
                    &json!({"accountId":id})
                )
                .is_err()
        );
        let mut forged = thread.clone();
        forged["id"] = json!(Uuid::new_v4().to_string());
        engine.store.save(&forged).unwrap();
        assert!(engine.validate_native_account_selection(&forged).is_err());
    }
    #[test]
    fn native_mode_change_does_not_mint_missing_thread_grants_or_change_auth_bytes() {
        let (_root, mut engine, _) = fixture();
        let row = engine
            .create_native_key_account("codex", "Synthetic API", "OPENAI_API_KEY")
            .unwrap();
        let thread = json!({"id":Uuid::new_v4().to_string(),"title":"Unapproved JSON choice","items":[],"selection":{"provider":"codex","accountID":row.id,"modelID":"default"}});
        engine.store.save(&thread).unwrap();
        let plan = engine
            .prepare_native_codex_auth_change(&row.id, &row.revision, true, false)
            .unwrap();
        engine.apply_native_codex_auth_change(plan).unwrap();
        assert!(engine.validate_native_account_selection(&thread).is_err());
        let current = engine.native_provider_accounts("codex").unwrap().remove(0);
        assert!(current.authentication == Authentication::Login);
        assert!(
            !home(&engine.store.data_directory().unwrap(), "codex", &row.id)
                .unwrap()
                .join("auth.json")
                .exists()
        );
        let scope = engine
            .native_account_configuration_mode("codex", &row.id, true)
            .unwrap();
        assert!(scope.metadata_only);
        let _scope = enter(Some(scope));
        assert!(engine.codex_login_context(&thread).is_ok());
        assert!(
            engine
                .set_native_provider_account_auth(
                    "codex",
                    &row.id,
                    &current.revision,
                    "apiKey",
                    None
                )
                .is_err()
        );
    }
}
