//! Native API-key account metadata and immutable-secret CAS. No JSON setting
//! can populate this signed registry or turn a saved key into provider authority.
use super::*;
use account_secret_store::{NativeSecretStore, SecretPurpose, SecretSlot};
#[derive(Clone)]
pub struct NativeKeyAccount {
    pub id: String,
    pub provider: String,
    pub name: String,
    pub revision: String,
    pub key_variable: String,
    /// Signed saved-slot presence only. Rendering never opens the OS vault.
    pub has_key: bool,
}
pub struct NativeKeySave {
    pub account: NativeKeyAccount,
    pub cleanup_pending: bool,
}
pub fn key_choices(provider: &str) -> Result<&'static [(&'static str, &'static str)]> {
    Ok(match provider {
        "claude" => &[("ANTHROPIC_API_KEY", "Anthropic")],
        "codex" => &[("OPENAI_API_KEY", "OpenAI")],
        "cursor" => &[("CURSOR_API_KEY", "Cursor")],
        "grok" => &[("XAI_API_KEY", "xAI")],
        "antigravity" => &[("GEMINI_API_KEY", "Gemini")],
        "opencode" => &[
            ("OPENCODE_API_KEY", "OpenCode Zen"),
            ("ANTHROPIC_API_KEY", "Anthropic"),
            ("OPENAI_API_KEY", "OpenAI"),
            ("OPENROUTER_API_KEY", "OpenRouter"),
            ("GOOGLE_GENERATIVE_AI_API_KEY", "Google"),
            ("XAI_API_KEY", "xAI"),
            ("GROQ_API_KEY", "Groq"),
            ("DEEPSEEK_API_KEY", "DeepSeek"),
            ("MISTRAL_API_KEY", "Mistral"),
        ],
        _ => anyhow::bail!("Unknown provider"),
    })
}
fn summary(account: &Account) -> Result<NativeKeyAccount> {
    ensure!(
        account.authentication == Authentication::ApiKey,
        "This account uses native login"
    );
    let variable = account
        .key_variable
        .as_deref()
        .context("Account key service is missing")?;
    ensure!(
        key_choices(&account.provider)?
            .iter()
            .any(|(key, _)| *key == variable),
        "Account key service is unsupported"
    );
    if let Some(slot) = &account.key {
        ensure!(
            slot.belongs_to(&account.provider, &account.id, SecretPurpose::ApiKey),
            "Account key belongs to another account"
        );
    }
    Ok(NativeKeyAccount {
        id: account.id.clone(),
        provider: account.provider.clone(),
        name: account.name.clone(),
        revision: account.revision.clone(),
        key_variable: variable.into(),
        has_key: account.key.is_some(),
    })
}
pub(super) fn cleanup(payload: &mut Value, slot: &SecretSlot) -> Result<()> {
    if payload.get("secret_cleanup").is_none() {
        payload["secret_cleanup"] = json!({});
    }
    let cleanup = payload["secret_cleanup"]
        .as_object_mut()
        .context("Secret cleanup registry is malformed")?;
    ensure!(
        cleanup.len() < 128 || cleanup.contains_key(slot.id()),
        "Retry pending account secret cleanup before saving more keys"
    );
    cleanup.insert(slot.id().into(), serde_json::to_value(slot)?);
    Ok(())
}
impl Engine {
    pub fn native_key_accounts(&self, provider: &str) -> Result<Vec<NativeKeyAccount>> {
        provider_id(provider)?;
        let Some(owner) = Private::open(&self.store, false)? else {
            return Ok(Vec::new());
        };
        let raw = self.store.native_accounts_payload(provider)?;
        let payload = read(&owner, provider, raw.as_deref())?;
        ordered_ids(&payload)?
            .iter()
            .map(|id| account(&payload, provider, id))
            .collect::<Result<Vec<_>>>()?
            .into_iter()
            .filter(|account| account.authentication == Authentication::ApiKey)
            .map(|account| summary(&account))
            .collect()
    }
    pub fn create_native_key_account(
        &mut self,
        provider: &str,
        name: &str,
        variable: &str,
    ) -> Result<NativeKeyAccount> {
        self.require_admissions()?;
        ensure!(
            key_choices(provider)?
                .iter()
                .any(|(key, _)| *key == variable),
            "Choose a supported API key service"
        );
        let name = name.trim();
        ensure!(
            !name.is_empty() && name.len() <= 120 && !name.chars().any(char::is_control),
            "Enter a valid account name"
        );
        let owner =
            Private::open(&self.store, true)?.context("Native account authority unavailable")?;
        let raw = self.store.native_accounts_payload(provider)?;
        let mut payload = read(&owner, provider, raw.as_deref())?;
        ensure!(
            payload["accounts"].as_object().unwrap().len() < 32,
            "Native account limit reached"
        );
        let id = Uuid::new_v4().to_string();
        if provider == "codex" {
            legacy_codex_accounts::note_creation_order(&self.store, &mut payload, &id)?;
        }
        append_order(&mut payload, &id)?;
        let (home, home_identity, guard_identity) =
            create_home(&self.store.data_directory()?, provider, &id)?;
        let account = Account {
            id: id.clone(),
            provider: provider.into(),
            name: name.into(),
            revision: Uuid::new_v4().to_string(),
            launch_revision: Uuid::new_v4().to_string(),
            authentication: Authentication::ApiKey,
            key_variable: Some(variable.into()),
            key: None,
            codex_enrollment: None,
            admin_key: None,
            home,
            home_identity,
            guard_identity,
        };
        payload["accounts"][&id] = serde_json::to_value(&account)?;
        if let Err(error) = self.store.save_native_accounts_payload(
            provider,
            raw.as_deref(),
            &encoded(&owner, &payload)?,
        ) {
            rollback_empty_home(&account.home);
            return Err(error);
        }
        self.revision += 1;
        summary(&account)
    }
    pub fn rename_native_key_account(
        &mut self,
        provider: &str,
        id: &str,
        expected: &str,
        name: &str,
    ) -> Result<NativeKeyAccount> {
        self.require_admissions()?;
        let name = name.trim();
        ensure!(
            !name.is_empty() && name.len() <= 120 && !name.chars().any(char::is_control),
            "Enter a valid account name"
        );
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        let raw = self.store.native_accounts_payload(provider)?;
        let mut payload = read(&owner, provider, raw.as_deref())?;
        let current = account(&payload, provider, id)?;
        summary(&current)?;
        ensure!(
            current.revision == expected,
            "Account changed; reload before renaming"
        );
        payload["accounts"][id]["name"] = json!(name);
        payload["accounts"][id]["revision"] = json!(Uuid::new_v4().to_string());
        self.store.save_native_accounts_payload(
            provider,
            raw.as_deref(),
            &encoded(&owner, &payload)?,
        )?;
        self.revision += 1;
        summary(&account(&payload, provider, id)?)
    }
    pub fn set_native_provider_account_auth(
        &mut self,
        provider: &str,
        id: &str,
        expected: &str,
        auth: &str,
        variable: Option<&str>,
    ) -> Result<()> {
        self.require_admissions()?;
        ensure!(
            provider != "codex",
            "Review Codex authentication changes in native Settings"
        );
        let mode = match auth {
            "login" => {
                supported(provider)?;
                Authentication::Login
            }
            "apiKey" => Authentication::ApiKey,
            _ => anyhow::bail!("Choose a supported account authentication method"),
        };
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        let raw = self.store.native_accounts_payload(provider)?;
        let mut payload = read(&owner, provider, raw.as_deref())?;
        let current = account(&payload, provider, id)?;
        ensure!(
            current.revision == expected,
            "Account changed; reload before changing authentication"
        );
        let variable = variable
            .or(current.key_variable.as_deref())
            .unwrap_or(key_choices(provider)?[0].0);
        ensure!(
            key_choices(provider)?
                .iter()
                .any(|(key, _)| *key == variable),
            "Choose a supported key service"
        );
        payload["accounts"][id]["authentication"] = serde_json::to_value(mode)?;
        payload["accounts"][id]["key_variable"] = json!(variable);
        payload["accounts"][id]["revision"] = json!(Uuid::new_v4().to_string());
        payload["accounts"][id]["launch_revision"] = json!(Uuid::new_v4().to_string());
        self.store.save_native_accounts_payload(
            provider,
            raw.as_deref(),
            &encoded(&owner, &payload)?,
        )?;
        self.revision += 1;
        Ok(())
    }
    pub fn save_native_account_key(
        &mut self,
        provider: &str,
        id: &str,
        expected: &str,
        value: &str,
    ) -> Result<NativeKeySave> {
        self.require_admissions()?;
        let owner = Private::open(&self.store, false)?
            .context("Add this account in native Settings first")?;
        let secrets = NativeSecretStore::from_owner(&owner)?;
        self.save_account_key_with(&owner, &secrets, provider, id, expected, value)
    }
    fn save_account_key_with(
        &mut self,
        owner: &Private,
        secrets: &NativeSecretStore,
        provider: &str,
        id: &str,
        expected: &str,
        value: &str,
    ) -> Result<NativeKeySave> {
        let raw = self.store.native_accounts_payload(provider)?;
        let mut payload = read(owner, provider, raw.as_deref())?;
        let current = account(&payload, provider, id)?;
        summary(&current)?;
        ensure!(
            current.revision == expected,
            "Account changed; reload before saving the key"
        );
        let plan = secrets.prepare(provider, id, SecretPurpose::ApiKey, value)?;
        // Durable cleanup BEFORE OS mutation covers ambiguous failed writes and
        // final account CAS failure without ever replacing the previous slot.
        cleanup(&mut payload, &plan.cleanup_receipt())?;
        let pending = encoded(owner, &payload)?;
        self.store
            .save_native_accounts_payload(provider, raw.as_deref(), &pending)?;
        let slot = secrets.write(&plan)?;
        let mut changed = current.clone();
        changed.key = Some(slot.clone());
        changed.revision = Uuid::new_v4().to_string();
        changed.launch_revision = Uuid::new_v4().to_string();
        // Mutate only the known fields so future account metadata survives.
        payload["accounts"][id]["key"] = serde_json::to_value(&slot)?;
        payload["accounts"][id]["revision"] = json!(changed.revision);
        payload["accounts"][id]["launch_revision"] = json!(changed.launch_revision);
        payload["secret_cleanup"]
            .as_object_mut()
            .unwrap()
            .remove(slot.id());
        if let Some(old) = &current.key {
            cleanup(&mut payload, old)?;
        }
        self.store.save_native_accounts_payload(
            provider,
            Some(&pending),
            &encoded(owner, &payload)?,
        )?;
        self.revision += 1;
        // Cleanup is a separate, retryable native action. A deletion failure
        // cannot roll back the saved pointer or resurrect a revoked key.
        Ok(NativeKeySave {
            account: summary(&changed)?,
            cleanup_pending: payload["secret_cleanup"]
                .as_object()
                .is_some_and(|pending| !pending.is_empty()),
        })
    }
    pub fn remove_native_account_key(
        &mut self,
        provider: &str,
        id: &str,
        expected: &str,
    ) -> Result<NativeKeySave> {
        self.require_admissions()?;
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        let raw = self.store.native_accounts_payload(provider)?;
        let mut payload = read(&owner, provider, raw.as_deref())?;
        let mut current = account(&payload, provider, id)?;
        summary(&current)?;
        ensure!(
            current.revision == expected,
            "Account changed; reload before removing the key"
        );
        if let Some(slot) = current.key.take() {
            cleanup(&mut payload, &slot)?;
        }
        current.revision = Uuid::new_v4().to_string();
        current.launch_revision = Uuid::new_v4().to_string();
        payload["accounts"][id]
            .as_object_mut()
            .context("Invalid native account")?
            .remove("key");
        payload["accounts"][id]["revision"] = json!(current.revision);
        payload["accounts"][id]["launch_revision"] = json!(current.launch_revision);
        self.store.save_native_accounts_payload(
            provider,
            raw.as_deref(),
            &encoded(&owner, &payload)?,
        )?;
        self.revision += 1;
        Ok(NativeKeySave {
            account: summary(&current)?,
            cleanup_pending: payload["secret_cleanup"]
                .as_object()
                .is_some_and(|pending| !pending.is_empty()),
        })
    }
    pub fn retry_native_account_secret_cleanup(&mut self, provider: &str) -> Result<usize> {
        self.require_admissions()?;
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        let secrets = NativeSecretStore::from_owner(&owner)?;
        let raw = self.store.native_accounts_payload(provider)?;
        let mut payload = read(&owner, provider, raw.as_deref())?;
        let Some(cleanup) = payload.get("secret_cleanup").and_then(Value::as_object) else {
            return Ok(0);
        };
        ensure!(cleanup.len() <= 128, "Secret cleanup exceeds its bound");
        let slots = cleanup
            .iter()
            .map(|(id, value)| {
                Ok((
                    id.clone(),
                    serde_json::from_value::<SecretSlot>(value.clone())?,
                ))
            })
            .collect::<Result<Vec<_>>>()?;
        let mut deleted = 0;
        for (id, slot) in slots {
            ensure!(slot.id() == id, "Secret cleanup identity mismatch");
            ensure!(
                !payload["accounts"]
                    .as_object()
                    .unwrap()
                    .values()
                    .any(|account| account["key"]["id"] == id || account["admin_key"]["id"] == id),
                "Active account key cannot be cleaned"
            );
            secrets.delete(&slot)?;
            payload["secret_cleanup"]
                .as_object_mut()
                .unwrap()
                .remove(&id);
            deleted += 1;
        }
        self.store.save_native_accounts_payload(
            provider,
            raw.as_deref(),
            &encoded(&owner, &payload)?,
        )?;
        Ok(deleted)
    }
}

pub(super) fn launch_configuration(
    owner: &Private,
    store: &Store,
    account: Account,
) -> Result<LaunchConfiguration> {
    let secrets = NativeSecretStore::from_owner(owner)?;
    launch_with_secrets(owner, store, account, &secrets)
}
pub(super) fn launch_with_secrets(
    owner: &Private,
    store: &Store,
    account: Account,
    secrets: &NativeSecretStore,
) -> Result<LaunchConfiguration> {
    key_configuration_mode(owner, store, account, Some(secrets))
}
pub(super) fn metadata_configuration(
    owner: &Private,
    store: &Store,
    account: Account,
) -> Result<LaunchConfiguration> {
    key_configuration_mode(owner, store, account, None)
}
fn key_configuration_mode(
    owner: &Private,
    store: &Store,
    account: Account,
    secrets: Option<&NativeSecretStore>,
) -> Result<LaunchConfiguration> {
    let summary = summary(&account)?;
    ensure!(
        matches!(
            account.provider.as_str(),
            "claude" | "cursor" | "grok" | "opencode" | "antigravity" | "codex"
        ),
        "This API-key provider still requires its guarded native runtime enrollment"
    );
    if account.provider == "codex" {
        if secrets.is_some() {
            codex_key_enrollment::validate(owner, &account)?;
        } else {
            codex_key_enrollment::validate_metadata(owner, &account)?;
        }
    }
    let slot = account
        .key
        .as_ref()
        .context("Save this account's API key in native Settings before use")?
        .clone();
    let value = secrets.map(|secrets| secrets.read(&slot)).transpose()?;
    let value = value
        .as_ref()
        .map(|value| {
            std::str::from_utf8(value).context("The saved API key has unsupported encoding")
        })
        .transpose()?;
    if let Some(value) = value {
        ensure!(
            !value.is_empty() && !value.chars().any(char::is_control),
            "Replace the invalid saved account key"
        );
    }
    let provider = account.provider.clone();
    let profile =
        LoginHome::capture_mode(&store.data_directory()?, account, false, secrets.is_none())?;
    let record = read_record(&owner.read()?, &provider)?;
    ensure!(
        record.is_some() || !store.requires_native_provider_configuration(&provider)?,
        "Approved provider configuration is missing; save it again in native Settings"
    );
    if let Some(record) = &record {
        validate_environment(&record.environment)?;
    }
    let mut configuration = build_configuration(owner, profile, record, None)?;
    let mut effective = configuration.record.clone();
    effective
        .environment
        .insert(summary.key_variable.clone(), serde_json::to_string(&slot)?);
    if let Some(value) = value {
        configuration
            .record
            .environment
            .insert(summary.key_variable, value.into());
    }
    let bytes = zeroize::Zeroizing::new(serde_json::to_vec(
        &json!({"captured":configuration.stamp,"keySlot":slot,"effective":effective}),
    )?);
    configuration.stamp.digest = crate::digest_hex::lower_hex(Sha256::digest(bytes.as_slice()));
    Ok(configuration)
}

#[cfg(test)]
pub(super) fn synthetic_configuration(
    engine: &mut Engine,
    provider: &str,
) -> (LaunchConfiguration, PathBuf) {
    tests::synthetic_configuration(engine, provider)
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    };
    use zeroize::Zeroizing;
    #[derive(Default)]
    struct Fake {
        values: Mutex<BTreeMap<(String, String), Vec<u8>>>,
        fail_write: AtomicBool,
        fail_delete: AtomicBool,
    }
    impl account_secret_store::Backend for Fake {
        fn write(&self, service: &str, id: &str, value: &[u8]) -> Result<()> {
            // Simulate an ambiguous SDK failure after the OS accepted the value.
            self.values
                .lock()
                .unwrap()
                .insert((service.into(), id.into()), value.into());
            ensure!(
                !self.fail_write.load(Ordering::SeqCst),
                "Synthetic save confirmation failure"
            );
            Ok(())
        }
        fn read(&self, service: &str, id: &str) -> Result<Zeroizing<Vec<u8>>> {
            self.values
                .lock()
                .unwrap()
                .get(&(service.into(), id.into()))
                .cloned()
                .map(Zeroizing::new)
                .context("Synthetic missing key")
        }
        fn delete(&self, service: &str, id: &str) -> Result<()> {
            ensure!(
                !self.fail_delete.load(Ordering::SeqCst),
                "Synthetic cleanup failure"
            );
            self.values
                .lock()
                .unwrap()
                .remove(&(service.into(), id.into()));
            Ok(())
        }
    }
    pub(super) fn synthetic_configuration(
        engine: &mut Engine,
        provider: &str,
    ) -> (LaunchConfiguration, PathBuf) {
        let variable = key_choices(provider).unwrap()[0].0;
        let account = engine
            .create_native_key_account(provider, "Synthetic native key", variable)
            .unwrap();
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        let secrets = NativeSecretStore::from_owner(&owner)
            .unwrap()
            .with_backend(Arc::new(Fake::default()));
        engine
            .save_account_key_with(
                &owner,
                &secrets,
                provider,
                &account.id,
                &account.revision,
                "synthetic-owned-account-key",
            )
            .unwrap();
        let raw = engine.store.native_accounts_payload(provider).unwrap();
        let row = super::super::account(
            &read(&owner, provider, raw.as_deref()).unwrap(),
            provider,
            &account.id,
        )
        .unwrap();
        let home = row.home.clone();
        (
            launch_with_secrets(&owner, &engine.store, row, &secrets).unwrap(),
            home,
        )
    }
    #[test]
    fn failed_secret_write_preserves_saved_pointer_and_durable_cleanup_receipt() {
        let (_root, mut engine, _binary) = super::super::super::tests::fixture();
        let account = engine
            .create_native_key_account("opencode", "Work", "OPENROUTER_API_KEY")
            .unwrap();
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        let fake = Arc::new(Fake::default());
        let secrets = NativeSecretStore::from_owner(&owner)
            .unwrap()
            .with_backend(fake.clone());
        let saved = engine
            .save_account_key_with(
                &owner,
                &secrets,
                "opencode",
                &account.id,
                &account.revision,
                "synthetic-first",
            )
            .unwrap();
        let raw = engine.store.native_accounts_payload("opencode").unwrap();
        let old = super::super::account(
            &read(&owner, "opencode", raw.as_deref()).unwrap(),
            "opencode",
            &account.id,
        )
        .unwrap()
        .key
        .unwrap();
        fake.fail_write.store(true, Ordering::SeqCst);
        assert!(
            engine
                .save_account_key_with(
                    &owner,
                    &secrets,
                    "opencode",
                    &account.id,
                    &saved.account.revision,
                    "synthetic-second"
                )
                .is_err()
        );
        let raw = engine.store.native_accounts_payload("opencode").unwrap();
        let payload = read(&owner, "opencode", raw.as_deref()).unwrap();
        assert_eq!(payload["accounts"][&account.id]["key"]["id"], old.id());
        assert_eq!(payload["secret_cleanup"].as_object().unwrap().len(), 1);
        assert_eq!(secrets.read(&old).unwrap().as_slice(), b"synthetic-first");
        assert!(!raw.unwrap().contains("synthetic-first"));
    }
    #[test]
    fn key_removal_revokes_pointer_before_retryable_secret_deletion() {
        let (_root, mut engine, _binary) = super::super::super::tests::fixture();
        let account = engine
            .create_native_key_account("claude", "Work", "ANTHROPIC_API_KEY")
            .unwrap();
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        let fake = Arc::new(Fake::default());
        let secrets = NativeSecretStore::from_owner(&owner)
            .unwrap()
            .with_backend(fake.clone());
        let saved = engine
            .save_account_key_with(
                &owner,
                &secrets,
                "claude",
                &account.id,
                &account.revision,
                "synthetic-key",
            )
            .unwrap();
        drop(owner);
        let removed = engine
            .remove_native_account_key("claude", &account.id, &saved.account.revision)
            .unwrap();
        assert!(!removed.account.has_key && removed.cleanup_pending);
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        let raw = engine.store.native_accounts_payload("claude").unwrap();
        let payload = read(&owner, "claude", raw.as_deref()).unwrap();
        let slot: SecretSlot = serde_json::from_value(
            payload["secret_cleanup"]
                .as_object()
                .unwrap()
                .values()
                .next()
                .unwrap()
                .clone(),
        )
        .unwrap();
        fake.fail_delete.store(true, Ordering::SeqCst);
        assert!(secrets.delete(&slot).is_err());
        assert!(
            super::super::account(&payload, "claude", &account.id)
                .unwrap()
                .key
                .is_none()
        );
        fake.fail_delete.store(false, Ordering::SeqCst);
        secrets.delete(&slot).unwrap();
        assert!(secrets.read(&slot).is_err());
        assert!(
            super::super::account(&payload, "claude", &account.id)
                .unwrap()
                .key
                .is_none()
        );
    }
    #[test]
    fn owned_key_runtime_captures_secret_generation_and_never_borrows_other_slots() {
        let (_root, mut engine, binary) = super::super::super::tests::fixture();
        super::super::super::tests::save(&mut engine, "grok", &binary, "global-fixture");
        let account = engine
            .create_native_key_account("grok", "Own key", "XAI_API_KEY")
            .unwrap();
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        let fake = Arc::new(Fake::default());
        let secrets = NativeSecretStore::from_owner(&owner)
            .unwrap()
            .with_backend(fake.clone());
        let saved = engine
            .save_account_key_with(
                &owner,
                &secrets,
                "grok",
                &account.id,
                &account.revision,
                "synthetic-first-key",
            )
            .unwrap();
        let raw = engine.store.native_accounts_payload("grok").unwrap();
        let row = super::super::account(
            &read(&owner, "grok", raw.as_deref()).unwrap(),
            "grok",
            &account.id,
        )
        .unwrap();
        let first = launch_with_secrets(&owner, &engine.store, row, &secrets).unwrap();
        let saved2 = engine
            .save_account_key_with(
                &owner,
                &secrets,
                "grok",
                &account.id,
                &saved.account.revision,
                "synthetic-second-key",
            )
            .unwrap();
        let raw = engine.store.native_accounts_payload("grok").unwrap();
        let row = super::super::account(
            &read(&owner, "grok", raw.as_deref()).unwrap(),
            "grok",
            &account.id,
        )
        .unwrap();
        let second = launch_with_secrets(&owner, &engine.store, row, &secrets).unwrap();
        assert_ne!(first.stamp, second.stamp);
        {
            let _scope = enter(Some(first));
            assert_eq!(
                effective_var("XAI_API_KEY"),
                Some("synthetic-first-key".into())
            );
            let mut child = Command::new(&binary);
            apply_to_child(&mut child, false).unwrap();
            assert!(child.get_envs().any(|(key, value)| key == "XAI_API_KEY"
                && value == Some(std::ffi::OsStr::new("synthetic-first-key"))));
        }
        {
            let _scope = enter(Some(second));
            assert_eq!(
                effective_var("XAI_API_KEY"),
                Some("synthetic-second-key".into())
            );
        }
        assert_ne!(saved2.account.revision, saved.account.revision);
    }
    #[test]
    fn native_authentication_changes_preserve_identity_and_reject_stale_rename() {
        let (_root, mut engine, _binary) = super::super::super::tests::fixture();
        let login = engine.create_native_login_account("grok", "Login").unwrap();
        engine
            .set_native_provider_account_auth(
                "grok",
                &login.id,
                &login.revision,
                "apiKey",
                Some("XAI_API_KEY"),
            )
            .unwrap();
        assert!(engine.native_login_accounts("grok").unwrap().is_empty());
        let key = engine.native_key_accounts("grok").unwrap().pop().unwrap();
        assert_eq!(key.id, login.id);
        assert!(!key.has_key);
        let renamed = engine
            .rename_native_key_account("grok", &key.id, &key.revision, "Renamed")
            .unwrap();
        assert!(
            engine
                .rename_native_key_account("grok", &key.id, &key.revision, "Stale")
                .is_err()
        );
        engine
            .set_native_provider_account_auth("grok", &key.id, &renamed.revision, "login", None)
            .unwrap();
        assert_eq!(
            engine.native_login_accounts("grok").unwrap()[0].home,
            login.home
        );
        assert!(engine.native_key_accounts("grok").unwrap().is_empty());
        assert!(
            engine
                .set_native_provider_account_auth(
                    "grok",
                    &key.id,
                    &renamed.revision,
                    "apiKey",
                    Some("SHELL_COMMAND")
                )
                .is_err()
        );
    }
    #[test]
    fn metadata_scope_matches_private_identity_without_reading_secret_or_authorizing_child() {
        let (_root, mut engine, binary) = super::super::super::tests::fixture();
        super::super::super::tests::save(&mut engine, "grok", &binary, "synthetic-global");
        let account = engine
            .create_native_key_account("grok", "Work", "XAI_API_KEY")
            .unwrap();
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        let secrets = NativeSecretStore::from_owner(&owner)
            .unwrap()
            .with_backend(Arc::new(Fake::default()));
        engine
            .save_account_key_with(
                &owner,
                &secrets,
                "grok",
                &account.id,
                &account.revision,
                "synthetic-launch-only-key",
            )
            .unwrap();
        let raw = engine.store.native_accounts_payload("grok").unwrap();
        let row = super::super::account(
            &read(&owner, "grok", raw.as_deref()).unwrap(),
            "grok",
            &account.id,
        )
        .unwrap();
        let actual = launch_with_secrets(&owner, &engine.store, row.clone(), &secrets).unwrap();
        // This route has no secret backend argument. Default SDK operations are
        // prohibited in unit tests, so any accidental OS access also fails.
        let metadata = metadata_configuration(&owner, &engine.store, row).unwrap();
        assert_eq!(actual.stamp, metadata.stamp);
        assert!(actual.validate_launch().is_ok());
        assert!(metadata.validate_launch().is_err());
        {
            let _scope = enter(Some(metadata));
            assert!(effective_var("XAI_API_KEY").is_none());
            assert!(apply_to_child(&mut Command::new(&binary), false).is_err());
        }
        {
            let _scope = enter(Some(actual));
            assert_eq!(
                effective_var("XAI_API_KEY"),
                Some("synthetic-launch-only-key".into())
            );
        }
    }
    #[test]
    fn all_provider_services_are_validated_without_vault_reads_or_json_authority() {
        let (_root, mut engine, _binary) = super::super::super::tests::fixture();
        for provider in [
            "claude",
            "codex",
            "cursor",
            "grok",
            "opencode",
            "antigravity",
        ] {
            for (variable, _) in key_choices(provider).unwrap() {
                let account = engine
                    .create_native_key_account(provider, "Native key", variable)
                    .unwrap();
                assert!(!account.has_key);
                assert!(
                    engine
                        .native_key_accounts(provider)
                        .unwrap()
                        .iter()
                        .any(|saved| saved.id == account.id && saved.key_variable == *variable)
                );
            }
            assert!(
                engine
                    .create_native_key_account(provider, "Bad service", "UNTRUSTED_COMMAND")
                    .is_err()
            );
        }
    }
}
