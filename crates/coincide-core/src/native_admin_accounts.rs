//! Separate read-only reporting credentials. These never enter CLI configuration.
use super::*;
use account_secret_store::{NativeSecretStore, SecretPurpose};

pub(super) fn eligible(account: &Account) -> bool {
    matches!(account.provider.as_str(), "claude" | "opencode")
        && account.authentication == Authentication::ApiKey
        && account.key_variable.as_deref() == Some("ANTHROPIC_API_KEY")
}
impl Engine {
    pub fn save_native_account_admin_key(
        &mut self,
        provider: &str,
        id: &str,
        expected: &str,
        value: &str,
    ) -> Result<String> {
        self.require_admissions()?;
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        let secrets = NativeSecretStore::from_owner(&owner)?;
        self.save_admin_key_with(&owner, &secrets, provider, id, expected, value)
    }
    fn save_admin_key_with(
        &mut self,
        owner: &Private,
        secrets: &NativeSecretStore,
        provider: &str,
        id: &str,
        expected: &str,
        value: &str,
    ) -> Result<String> {
        let raw = self.store.native_accounts_payload(provider)?;
        let mut payload = read(owner, provider, raw.as_deref())?;
        let current = account(&payload, provider, id)?;
        ensure!(
            eligible(&current),
            "Only Anthropic API accounts support an Admin key"
        );
        ensure!(
            current.revision == expected,
            "Account changed; reload before saving the Admin key"
        );
        let plan = secrets.prepare(provider, id, SecretPurpose::AdminKey, value)?;
        keys::cleanup(&mut payload, &plan.cleanup_receipt())?;
        let pending = encoded(owner, &payload)?;
        self.store
            .save_native_accounts_payload(provider, raw.as_deref(), &pending)?;
        let slot = secrets.write(&plan)?;
        payload["secret_cleanup"]
            .as_object_mut()
            .unwrap()
            .remove(slot.id());
        if let Some(old) = &current.admin_key {
            keys::cleanup(&mut payload, old)?;
        }
        payload["accounts"][id]["admin_key"] = serde_json::to_value(slot)?;
        let revision = Uuid::new_v4().to_string();
        payload["accounts"][id]["revision"] = json!(revision);
        // launch_revision, API slot, enrollment and unknown metadata stay intact.
        self.store.save_native_accounts_payload(
            provider,
            Some(&pending),
            &encoded(owner, &payload)?,
        )?;
        self.revision += 1;
        Ok(revision)
    }
    pub fn remove_native_account_admin_key(
        &mut self,
        provider: &str,
        id: &str,
        expected: &str,
    ) -> Result<String> {
        self.require_admissions()?;
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        let raw = self.store.native_accounts_payload(provider)?;
        let mut payload = read(&owner, provider, raw.as_deref())?;
        let current = account(&payload, provider, id)?;
        ensure!(
            current.revision == expected,
            "Account changed; reload before removing the Admin key"
        );
        if let Some(slot) = &current.admin_key {
            keys::cleanup(&mut payload, slot)?;
        }
        payload["accounts"][id]
            .as_object_mut()
            .context("Native account is malformed")?
            .remove("admin_key");
        let revision = Uuid::new_v4().to_string();
        payload["accounts"][id]["revision"] = json!(revision);
        self.store.save_native_accounts_payload(
            provider,
            raw.as_deref(),
            &encoded(&owner, &payload)?,
        )?;
        self.revision += 1;
        Ok(revision)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    #[derive(Default)]
    struct Fake(Mutex<BTreeMap<(String, String), Vec<u8>>>);
    impl account_secret_store::Backend for Fake {
        fn write(&self, service: &str, id: &str, value: &[u8]) -> Result<()> {
            self.0
                .lock()
                .unwrap()
                .insert((service.into(), id.into()), value.into());
            Ok(())
        }
        fn read(&self, service: &str, id: &str) -> Result<zeroize::Zeroizing<Vec<u8>>> {
            self.0
                .lock()
                .unwrap()
                .get(&(service.into(), id.into()))
                .cloned()
                .map(zeroize::Zeroizing::new)
                .context("Synthetic missing slot")
        }
        fn delete(&self, service: &str, id: &str) -> Result<()> {
            self.0.lock().unwrap().remove(&(service.into(), id.into()));
            Ok(())
        }
    }
    #[test]
    fn admin_save_revoke_preserves_launch_identity_and_stale_cas() {
        let (_root, mut engine, _) = super::super::super::tests::fixture();
        let row = engine
            .create_native_key_account("claude", "Synthetic report", "ANTHROPIC_API_KEY")
            .unwrap();
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        let secrets = NativeSecretStore::from_owner(&owner)
            .unwrap()
            .with_backend(Arc::new(Fake::default()));
        let before = read(
            &owner,
            "claude",
            engine
                .store
                .native_accounts_payload("claude")
                .unwrap()
                .as_deref(),
        )
        .unwrap();
        let revision = engine
            .save_admin_key_with(
                &owner,
                &secrets,
                "claude",
                &row.id,
                &row.revision,
                "synthetic-admin-value",
            )
            .unwrap();
        assert!(
            engine
                .save_admin_key_with(
                    &owner,
                    &secrets,
                    "claude",
                    &row.id,
                    &row.revision,
                    "synthetic-stale"
                )
                .is_err()
        );
        let saved = read(
            &owner,
            "claude",
            engine
                .store
                .native_accounts_payload("claude")
                .unwrap()
                .as_deref(),
        )
        .unwrap();
        assert_eq!(
            before["accounts"][&row.id]["launch_revision"],
            saved["accounts"][&row.id]["launch_revision"]
        );
        assert!(saved["accounts"][&row.id]["key"].is_null());
        let slot: account_secret_store::SecretSlot =
            serde_json::from_value(saved["accounts"][&row.id]["admin_key"].clone()).unwrap();
        assert!(slot.belongs_to("claude", &row.id, SecretPurpose::AdminKey));
        assert!(!slot.belongs_to("claude", &row.id, SecretPurpose::ApiKey));
        drop(owner);
        engine
            .remove_native_account_admin_key("claude", &row.id, &revision)
            .unwrap();
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        let revoked = read(
            &owner,
            "claude",
            engine
                .store
                .native_accounts_payload("claude")
                .unwrap()
                .as_deref(),
        )
        .unwrap();
        assert!(revoked["accounts"][&row.id]["admin_key"].is_null());
        assert_eq!(
            revoked["secret_cleanup"][slot.id()],
            serde_json::to_value(slot).unwrap()
        );
        assert_eq!(
            before["accounts"][&row.id]["launch_revision"],
            revoked["accounts"][&row.id]["launch_revision"]
        );
    }
    #[test]
    fn admin_scope_is_anthropic_only_across_provider_modes() {
        let (_root, mut engine, _) = super::super::super::tests::fixture();
        for (provider, variable, allowed) in [
            ("claude", "ANTHROPIC_API_KEY", true),
            ("opencode", "ANTHROPIC_API_KEY", true),
            ("opencode", "OPENAI_API_KEY", false),
            ("codex", "OPENAI_API_KEY", false),
        ] {
            let row = engine
                .create_native_key_account(provider, "Synthetic scope", variable)
                .unwrap();
            let owner = Private::open(&engine.store, false).unwrap().unwrap();
            let secrets = NativeSecretStore::from_owner(&owner)
                .unwrap()
                .with_backend(Arc::new(Fake::default()));
            assert_eq!(
                engine
                    .save_admin_key_with(
                        &owner,
                        &secrets,
                        provider,
                        &row.id,
                        &row.revision,
                        "synthetic-admin"
                    )
                    .is_ok(),
                allowed
            );
        }
    }
}

#[path = "native_admin_usage.rs"]
mod usage;
pub use usage::{NativeAdminTokens, NativeAdminUsage, NativeAdminUsageReport};
