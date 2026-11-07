//! Typed reviewed account removal. Registry revocation/fallback is atomic;
//! filesystem/OS-secret cleanup follows durable tombstones and is retryable.
use super::*;
pub struct PreparedNativeAccountRemoval {
    source: Value,
    provider: String,
    account: Account,
    registry: String,
    threads: Vec<Value>,
}
pub struct NativeAccountRemoval {
    pub conversations: usize,
    pub cleanup_pending: bool,
}
impl PreparedNativeAccountRemoval {
    pub fn name(&self) -> &str {
        &self.account.name
    }
    pub fn conversation_count(&self) -> usize {
        self.threads.len()
    }
}
fn ready(engine: &mut Engine, threads: &[Value]) -> Result<()> {
    engine.require_admissions()?;
    let workers = engine.provider_workers_status();
    ensure!(
        engine.runs.is_empty()
            && workers.running == 0
            && workers.panicked == 0
            && workers.unclassified == 0,
        "Stop provider turns and wait for their actual cleanup before removing an account"
    );
    ensure!(
        engine.steering_operations.is_empty()
            && !engine.native_follow_up.has_pending()
            && engine.schedule_completions.is_empty(),
        "Wait for pending provider results before removing an account"
    );
    ensure!(
        engine
            .codex_profile_login
            .as_ref()
            .is_none_or(|operation| !operation.active()),
        "Wait for sign-in cleanup before removing an account"
    );
    for thread in threads {
        let id = required(thread, "id")?;
        ensure!(
            !engine.unsaved_threads.contains_key(id)
                && !engine.pending_usage.contains_key(id)
                && !engine.attachment_operations.contains(id),
            "Wait for conversation persistence before removing this account"
        );
        ensure!(
            crate::message_queue::read(thread)?
                .iter()
                .all(|row| !matches!(
                    row.state,
                    crate::message_queue::State::Pending | crate::message_queue::State::Dispatching
                )),
            "Finish queued messages before removing their account"
        );
        ensure!(
            thread["rustBotContext"].is_null() && thread["botID"].is_null(),
            "A frozen bot still references this account"
        );
    }
    Ok(())
}
fn tombstone(payload: &mut Value, account: &Account) -> Result<()> {
    if payload.get("removed_accounts").is_none() {
        payload["removed_accounts"] = json!({});
    }
    let rows = payload["removed_accounts"]
        .as_object_mut()
        .context("Account cleanup registry is malformed")?;
    ensure!(
        rows.len() < 32,
        "Retry removed account cleanup before removing more accounts"
    );
    rows.insert(account.id.clone(), serde_json::to_value(account)?);
    Ok(())
}
fn remove_home(root: &Path, account: &Account) -> Result<()> {
    ensure!(
        account.home == home(root, &account.provider, &account.id)?,
        "Removed account path changed"
    );
    if fs::symlink_metadata(&account.home)
        .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound)
    {
        return Ok(());
    }
    private(root, true)?;
    private(&root.join("providers"), true)?;
    private(&root.join("providers").join(&account.provider), true)?;
    private(&account.home, true)?;
    ensure!(
        crate::private_fs::identity(&account.home)? == account.home_identity,
        "Removed account home was replaced; cleanup retained"
    );
    let guard = account.home.join(GUARD);
    if guard.try_exists()? {
        private(&guard, false)?;
        ensure!(
            crate::private_fs::identity(&guard)? == account.guard_identity,
            "Removed account owner was replaced; cleanup retained"
        );
        let lease = open_file(&guard, false)?;
        lease
            .try_lock()
            .context("Removed account is still in use")?;
        // No registry grant remains, and the authority lease excludes other
        // native account operations. Close the Windows handle before deletion.
        drop(lease);
    }
    ensure!(
        crate::private_fs::identity(&account.home)? == account.home_identity,
        "Removed account home changed before cleanup"
    );
    fs::remove_dir_all(&account.home)
        .context("Account was revoked; its private home cleanup must be retried")
}
impl Engine {
    pub fn prepare_native_provider_account_removal(
        &mut self,
        provider: &str,
        id: &str,
        expected: &str,
    ) -> Result<PreparedNativeAccountRemoval> {
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        let registry = self
            .store
            .native_accounts_payload(provider)?
            .context("Native account registry missing")?;
        let payload = read(&owner, provider, Some(&registry))?;
        let account = account(&payload, provider, id)?;
        ensure!(
            account.revision == expected,
            "Account changed; review removal again"
        );
        let threads = self.store.native_account_removal_threads(provider, id)?;
        ready(self, &threads)?;
        let _exclusive =
            LoginHome::capture_with_lock(&self.store.data_directory()?, account.clone(), true)?;
        Ok(PreparedNativeAccountRemoval {
            source: owner.source.clone(),
            provider: provider.into(),
            account,
            registry,
            threads,
        })
    }
    pub fn apply_native_provider_account_removal(
        &mut self,
        plan: PreparedNativeAccountRemoval,
    ) -> Result<NativeAccountRemoval> {
        ready(self, &plan.threads)?;
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        ensure!(
            owner.source == plan.source,
            "Account removal belongs to another Store"
        );
        let mut payload = read(&owner, &plan.provider, Some(&plan.registry))?;
        let exclusive = LoginHome::capture_with_lock(
            &self.store.data_directory()?,
            plan.account.clone(),
            true,
        )?;
        payload["accounts"]
            .as_object_mut()
            .unwrap()
            .remove(&plan.account.id);
        tombstone(&mut payload, &plan.account)?;
        if payload.get("revoked_accounts").is_none() {
            payload["revoked_accounts"] = json!({});
        }
        let revoked = payload["revoked_accounts"]
            .as_object_mut()
            .context("Account revocations are malformed")?;
        ensure!(
            revoked.len() < 10_000,
            "Native account revocation registry is full"
        );
        revoked.insert(plan.account.id.clone(), json!(true));
        self.store.revoke_native_account(
            &plan.provider,
            &plan.account.id,
            &plan.registry,
            &encoded(&owner, &payload)?,
            &plan.threads,
        )?;
        self.revision += 1;
        drop(exclusive);
        // Revocation succeeded independently of cleanup. Preserve tombstones on
        // failure; the UI reports cleanup pending and offers a real retry.
        let home_clean = remove_home(&self.store.data_directory()?, &plan.account).is_ok();
        let no_secret = plan.account.key.is_none() && plan.account.admin_key.is_none();
        let mut cleanup_pending = !home_clean || !no_secret;
        if home_clean && no_secret {
            cleanup_pending = (|| -> Result<()> {
                let raw = self.store.native_accounts_payload(&plan.provider)?;
                let mut current = read(&owner, &plan.provider, raw.as_deref())?;
                current["removed_accounts"]
                    .as_object_mut()
                    .context("Account cleanup registry changed")?
                    .remove(&plan.account.id);
                self.store.save_native_accounts_payload(
                    &plan.provider,
                    raw.as_deref(),
                    &encoded(&owner, &current)?,
                )
            })()
            .is_err();
        }
        Ok(NativeAccountRemoval {
            conversations: plan.threads.len(),
            cleanup_pending,
        })
    }
    pub fn native_provider_account_cleanup_pending(&self, provider: &str) -> Result<usize> {
        let Some(owner) = Private::open(&self.store, false)? else {
            return Ok(0);
        };
        let raw = self.store.native_accounts_payload(provider)?;
        let payload = read(&owner, provider, raw.as_deref())?;
        Ok(payload["removed_accounts"]
            .as_object()
            .map_or(0, serde_json::Map::len)
            + payload["secret_cleanup"]
                .as_object()
                .map_or(0, serde_json::Map::len))
    }
    pub fn retry_native_removed_account_cleanup(&mut self, provider: &str) -> Result<usize> {
        self.require_admissions()?;
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        let raw = self.store.native_accounts_payload(provider)?;
        let mut payload = read(&owner, provider, raw.as_deref())?;
        let Some(removed) = payload.get("removed_accounts").and_then(Value::as_object) else {
            return Ok(0);
        };
        ensure!(removed.len() <= 32, "Account cleanup exceeds its bound");
        let accounts = removed
            .values()
            .map(|value| {
                serde_json::from_value::<Account>(value.clone()).map_err(anyhow::Error::from)
            })
            .collect::<Result<Vec<_>>>()?;
        let secrets = account_secret_store::NativeSecretStore::from_owner(&owner)?;
        let mut cleaned = 0;
        for account in accounts {
            ensure!(
                account.provider == provider && payload["accounts"].get(&account.id).is_none(),
                "An active account cannot be cleaned"
            );
            if let Some(slot) = &account.key {
                ensure!(
                    slot.belongs_to(
                        provider,
                        &account.id,
                        account_secret_store::SecretPurpose::ApiKey
                    ),
                    "Removed key belongs to another account"
                );
                secrets.delete(slot)?;
            }
            if let Some(slot) = &account.admin_key {
                ensure!(
                    slot.belongs_to(
                        provider,
                        &account.id,
                        account_secret_store::SecretPurpose::AdminKey
                    ),
                    "Removed Admin key belongs to another account"
                );
                secrets.delete(slot)?;
            }
            remove_home(&self.store.data_directory()?, &account)?;
            payload["removed_accounts"]
                .as_object_mut()
                .unwrap()
                .remove(&account.id);
            cleaned += 1;
        }
        self.store.save_native_accounts_payload(
            provider,
            raw.as_deref(),
            &encoded(&owner, &payload)?,
        )?;
        Ok(cleaned)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Engine, NativeLoginAccount, Value) {
        let (root, mut engine, binary) = super::super::super::tests::fixture();
        super::super::super::tests::save(&mut engine, "grok", &binary, "synthetic-only");
        let account = engine.create_native_login_account("grok", "Work").unwrap();
        let id = Uuid::new_v4().to_string();
        let thread = json!({"id":id,"title":"Keep conversation","createdAt":0,"updatedAt":0,"draft":"Keep exact draft","items":[{"kind":"user","text":"Keep exact history"}],"selection":{"provider":"grok","modelID":"default"},"sessions":{"grok":{"sessionID":"untrusted descriptive history","seenItemCount":1}},"unknown":{"keep":[1,2]}});
        engine.store.save(&thread).unwrap();
        engine.active_thread = Some(id);
        let selected = engine
            .select_native_provider_account(&thread, Some(&account.id))
            .unwrap();
        (root, engine, account, selected)
    }
    #[test]
    fn removal_atomically_revokes_account_and_only_changes_native_account_selection() {
        let (_root, mut engine, account, selected) = fixture();
        let plan = engine
            .prepare_native_provider_account_removal("grok", &account.id, &account.revision)
            .unwrap();
        assert_eq!(plan.conversation_count(), 1);
        let result = engine.apply_native_provider_account_removal(plan).unwrap();
        assert_eq!(result.conversations, 1);
        assert!(!result.cleanup_pending);
        assert!(!account.home.exists());
        let mut expected = selected.clone();
        expected["selection"]
            .as_object_mut()
            .unwrap()
            .remove("accountID");
        assert_eq!(
            engine
                .store
                .thread(selected["id"].as_str().unwrap())
                .unwrap(),
            expected
        );
        assert!(engine.native_login_accounts("grok").unwrap().is_empty());
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        let raw = engine.store.native_accounts_payload("grok").unwrap();
        assert_eq!(
            read(&owner, "grok", raw.as_deref()).unwrap()["revoked_accounts"][&account.id],
            true
        );
    }
    #[test]
    fn stale_removal_review_keeps_account_home_and_newer_conversation_draft() {
        let (_root, mut engine, account, selected) = fixture();
        let plan = engine
            .prepare_native_provider_account_removal("grok", &account.id, &account.revision)
            .unwrap();
        let mut changed = selected;
        changed["draft"] = json!("Newer retained draft");
        engine.store.save(&changed).unwrap();
        assert!(engine.apply_native_provider_account_removal(plan).is_err());
        assert!(account.home.exists());
        assert_eq!(
            engine
                .store
                .thread(changed["id"].as_str().unwrap())
                .unwrap(),
            changed
        );
        assert_eq!(engine.native_login_accounts("grok").unwrap().len(), 1);
    }
    #[test]
    fn held_profile_blocks_removal_until_actual_owner_releases_it() {
        let (_root, mut engine, account, _selected) = fixture();
        let held = engine
            .native_login_launch_configuration("grok", &account.id)
            .unwrap();
        assert!(
            engine
                .prepare_native_provider_account_removal("grok", &account.id, &account.revision)
                .is_err()
        );
        drop(held);
        let plan = engine
            .prepare_native_provider_account_removal("grok", &account.id, &account.revision)
            .unwrap();
        engine.apply_native_provider_account_removal(plan).unwrap();
    }
}
