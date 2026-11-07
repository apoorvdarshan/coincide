//! Explicit CLI enrollment of a saved native Codex API key, source/home/slot
//! bound. Success is a local CLI-file enrollment, never a provider auth claim.
use super::*;
use account_secret_store::{NativeSecretStore, SecretPurpose};
pub struct NativeCodexKeyEnrollment {
    source: Value,
    account: Account,
    global: String,
    configuration: LaunchConfiguration,
    key: zeroize::Zeroizing<Vec<u8>>,
}
pub struct NativeCodexKeyEnrollmentReceipt {
    source: Value,
    account: Account,
    global: String,
    auth: Value,
    configuration: LaunchConfiguration,
}
fn global(owner: &Private, record: &Option<Record>) -> Result<String> {
    let bytes = zeroize::Zeroizing::new(serde_json::to_vec(record)?);
    Ok(crate::digest_hex::lower_hex(
        hmac::sign(&owner.key, bytes.as_slice()).as_ref(),
    ))
}
fn auth(home: &Path) -> Result<(Value, zeroize::Zeroizing<Vec<u8>>)> {
    private(home, true)?;
    let path = home.join("auth.json");
    private(&path, false)?;
    let mut file = open_file(&path, false)?;
    let identity = crate::private_fs::file_identity(&file)?;
    ensure!(
        identity == crate::private_fs::identity(&path)?,
        "Codex key enrollment file changed"
    );
    let mut bytes = zeroize::Zeroizing::new(Vec::new());
    (&mut file).take(1024 * 1024 + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= 1024 * 1024,
        "Codex key enrollment exceeds its bound"
    );
    ensure!(
        identity == crate::private_fs::identity(&path)?,
        "Codex key enrollment file was replaced"
    );
    let value = json!({"identity":identity,"length":bytes.len(),"modified":file.metadata()?.modified()?.duration_since(std::time::UNIX_EPOCH)?.as_nanos(),"digest":crate::digest_hex::lower_hex(Sha256::digest(bytes.as_slice()))});
    Ok((value, bytes))
}
impl Engine {
    /// Explicit local enrollment verification, not remote authentication. This
    /// reads only the selected native account's owned CLI auth file.
    pub fn verify_native_codex_key_enrollment(&self, id: &str, expected: &str) -> Result<()> {
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        let raw = self.store.native_accounts_payload("codex")?;
        let payload = read(&owner, "codex", raw.as_deref())?;
        let account = account(&payload, "codex", id)?;
        ensure!(
            account.revision == expected,
            "Account changed; reload before checking enrollment"
        );
        validate(&owner, &account)
    }
    pub fn prepare_native_codex_key_enrollment(
        &self,
        id: &str,
        expected: &str,
    ) -> Result<NativeCodexKeyEnrollment> {
        self.require_admissions()?;
        self.require_provider_enabled("codex")?;
        let owner = Private::open(&self.store, false)?
            .context("Add this account in native Settings first")?;
        let raw = self.store.native_accounts_payload("codex")?;
        let payload = read(&owner, "codex", raw.as_deref())?;
        let account = account(&payload, "codex", id)?;
        ensure!(
            account.revision == expected
                && account.authentication == Authentication::ApiKey
                && account.key_variable.as_deref() == Some("OPENAI_API_KEY"),
            "Codex key account changed; reload before applying its key"
        );
        let slot = account
            .key
            .as_ref()
            .context("Save the account's API key first")?;
        ensure!(
            slot.belongs_to("codex", id, SecretPurpose::ApiKey),
            "Saved key belongs to another account"
        );
        let secrets = NativeSecretStore::from_owner(&owner)?;
        let key = secrets.read(slot)?;
        let profile =
            LoginHome::capture_with_lock(&self.store.data_directory()?, account.clone(), true)?;
        let record = read_record(&owner.read()?, "codex")?;
        ensure!(
            record.is_some() || !self.store.requires_native_provider_configuration("codex")?,
            "Approved Codex configuration is missing"
        );
        if let Some(record) = &record {
            validate_environment(&record.environment)?;
        }
        let binding = global(&owner, &record)?;
        let configuration = build_configuration(&owner, profile, record, None)?;
        Ok(NativeCodexKeyEnrollment {
            source: owner.source.clone(),
            account,
            global: binding,
            configuration,
            key,
        })
    }
    pub fn apply_native_codex_key_enrollment(
        &mut self,
        receipt: NativeCodexKeyEnrollmentReceipt,
    ) -> Result<NativeKeyAccount> {
        self.require_admissions()?;
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        ensure!(
            owner.source == receipt.source,
            "Codex enrollment belongs to another Store"
        );
        receipt.configuration.validate_launch()?;
        ensure!(
            global(&owner, &read_record(&owner.read()?, "codex")?)? == receipt.global,
            "Codex configuration changed; apply the saved key again"
        );
        ensure!(
            auth(&receipt.account.home)?.0 == receipt.auth,
            "Codex enrollment changed before confirmation"
        );
        let raw = self.store.native_accounts_payload("codex")?;
        let mut payload = read(&owner, "codex", raw.as_deref())?;
        let current = account(&payload, "codex", &receipt.account.id)?;
        ensure!(
            serde_json::to_value(&current)? == serde_json::to_value(&receipt.account)?,
            "Account changed before Codex enrollment confirmation"
        );
        let id = &current.id;
        payload["accounts"][id]["codex_enrollment"] = json!({"slot":current.key.as_ref().context("Saved key missing")?.id(),"global":receipt.global,"auth":receipt.auth});
        payload["accounts"][id]["revision"] = json!(Uuid::new_v4().to_string());
        payload["accounts"][id]["launch_revision"] = json!(Uuid::new_v4().to_string());
        self.store.save_native_accounts_payload(
            "codex",
            raw.as_deref(),
            &encoded(&owner, &payload)?,
        )?;
        self.revision += 1;
        let row = account(&payload, "codex", id)?;
        Ok(NativeKeyAccount {
            id: row.id,
            provider: row.provider,
            name: row.name,
            revision: row.revision,
            key_variable: "OPENAI_API_KEY".into(),
            has_key: true,
        })
    }
}
impl NativeCodexKeyEnrollment {
    pub fn run(self, allowed: &impl Fn() -> bool) -> Result<NativeCodexKeyEnrollmentReceipt> {
        self.run_with(allowed, |executable, key| {
            crate::agent::key_enrollment_process::codex(executable, key, allowed)
        })
    }
    fn run_with(
        self,
        allowed: &impl Fn() -> bool,
        run: impl FnOnce(&Path, zeroize::Zeroizing<Vec<u8>>) -> Result<()>,
    ) -> Result<NativeCodexKeyEnrollmentReceipt> {
        let _scope = enter(Some(self.configuration.clone()));
        let executable = self
            .configuration
            .approved_executable()
            .context("Codex executable missing")?;
        run(&executable, self.key.clone())?;
        ensure!(allowed(), "Codex key enrollment cancelled");
        let (auth, bytes) = auth(&self.account.home)?;
        let value: Value = serde_json::from_slice(&bytes)
            .context("Codex did not create a valid API-key enrollment")?;
        ensure!(
            value["OPENAI_API_KEY"]
                .as_str()
                .is_some_and(|key| key.as_bytes() == self.key.as_slice())
                && value["tokens"].is_null(),
            "Codex did not enroll this account's saved API key"
        );
        Ok(NativeCodexKeyEnrollmentReceipt {
            source: self.source,
            account: self.account,
            global: self.global,
            auth,
            configuration: self.configuration,
        })
    }
}
pub(super) fn validate_auth_metadata(account: &Account) -> Result<()> {
    let proof = &account
        .codex_enrollment
        .as_ref()
        .context("Apply the saved Codex key before use")?["auth"];
    let path = account.home.join("auth.json");
    private(&path, false)?;
    let metadata = fs::symlink_metadata(&path)?;
    ensure!(
        proof["identity"] == serde_json::to_value(crate::private_fs::identity(&path)?)?
            && proof["length"] == metadata.len()
            && proof["modified"]
                == json!(
                    metadata
                        .modified()?
                        .duration_since(std::time::UNIX_EPOCH)?
                        .as_nanos()
                ),
        "Codex enrollment metadata changed; apply the saved key again"
    );
    Ok(())
}
pub(super) fn validate_metadata(owner: &Private, account: &Account) -> Result<()> {
    let enrollment = account
        .codex_enrollment
        .as_ref()
        .context("Apply the saved Codex key before use")?;
    ensure!(
        enrollment["slot"]
            == account
                .key
                .as_ref()
                .context("Saved Codex key missing")?
                .id()
            && enrollment["global"] == global(owner, &read_record(&owner.read()?, "codex")?)?,
        "Saved Codex configuration changed; apply its key again"
    );
    validate_auth_metadata(account)
}
pub(super) fn validate_auth(account: &Account) -> Result<()> {
    let enrollment = account
        .codex_enrollment
        .as_ref()
        .context("Apply the saved Codex API key before use")?;
    ensure!(
        enrollment["auth"] == auth(&account.home)?.0,
        "Codex API-key enrollment changed; apply the saved key again"
    );
    Ok(())
}
pub(super) fn validate(owner: &Private, account: &Account) -> Result<()> {
    let enrollment = account
        .codex_enrollment
        .as_ref()
        .context("Apply this saved Codex key in native Settings before use")?;
    ensure!(
        enrollment["slot"]
            == account
                .key
                .as_ref()
                .context("Saved Codex key missing")?
                .id(),
        "The saved key changed; apply it in native Settings before use"
    );
    ensure!(
        enrollment["global"] == global(owner, &read_record(&owner.read()?, "codex")?)?,
        "Codex configuration changed; apply the saved key again"
    );
    ensure!(
        enrollment["auth"] == auth(&account.home)?.0,
        "Codex API-key enrollment changed; apply the saved key again"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Engine, NativeCodexKeyEnrollment, PathBuf) {
        let (root, mut engine, binary) = super::super::super::tests::fixture();
        super::super::super::tests::save(&mut engine, "codex", &binary, "synthetic-global");
        let summary = engine
            .create_native_key_account("codex", "API account", "OPENAI_API_KEY")
            .unwrap();
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        let raw = engine.store.native_accounts_payload("codex").unwrap();
        let mut payload = read(&owner, "codex", raw.as_deref()).unwrap();
        let secrets = NativeSecretStore::from_owner(&owner).unwrap();
        let key = secrets
            .prepare(
                "codex",
                &summary.id,
                SecretPurpose::ApiKey,
                "synthetic-codex-account-key",
            )
            .unwrap();
        payload["accounts"][&summary.id]["key"] =
            serde_json::to_value(key.cleanup_receipt()).unwrap();
        engine
            .store
            .save_native_accounts_payload(
                "codex",
                raw.as_deref(),
                &encoded(&owner, &payload).unwrap(),
            )
            .unwrap();
        let account = account(&payload, "codex", &summary.id).unwrap();
        let profile = LoginHome::capture_with_lock(
            &engine.store.data_directory().unwrap(),
            account.clone(),
            true,
        )
        .unwrap();
        let record = read_record(&owner.read().unwrap(), "codex").unwrap();
        let global = global(&owner, &record).unwrap();
        let configuration = build_configuration(&owner, profile, record, None).unwrap();
        let plan = NativeCodexKeyEnrollment {
            source: owner.source.clone(),
            account,
            global,
            configuration,
            key: zeroize::Zeroizing::new(b"synthetic-codex-account-key".to_vec()),
        };
        drop(owner);
        (root, engine, plan, binary)
    }
    fn local_cli(plan: NativeCodexKeyEnrollment, binary: &Path) -> NativeCodexKeyEnrollmentReceipt {
        let home = plan.account.home.clone();
        plan.run_with(&|| true, |executable, key| {
            assert_eq!(executable, binary);
            let mut file = open_file(&home.join("auth.json"), true).unwrap();
            file.write_all(
                &serde_json::to_vec(
                    &json!({"OPENAI_API_KEY":std::str::from_utf8(&key).unwrap(),"tokens":null}),
                )
                .unwrap(),
            )
            .unwrap();
            Ok(())
        })
        .unwrap()
    }
    #[test]
    fn local_enrollment_binds_exact_saved_slot_and_file_without_authentication_claim() {
        let (_root, mut engine, plan, binary) = fixture();
        let receipt = local_cli(plan, &binary);
        let home = receipt.account.home.clone();
        let saved = engine.apply_native_codex_key_enrollment(receipt).unwrap();
        engine
            .verify_native_codex_key_enrollment(&saved.id, &saved.revision)
            .unwrap();
        let raw = engine
            .store
            .native_accounts_payload("codex")
            .unwrap()
            .unwrap();
        assert!(!raw.contains("synthetic-codex-account-key"));
        fs::write(home.join("auth.json"), b"synthetic-changed-auth").unwrap();
        assert!(
            engine
                .verify_native_codex_key_enrollment(&saved.id, &saved.revision)
                .is_err()
        );
    }
    #[test]
    fn api_context_requires_native_capture_and_actual_api_account_shape() {
        struct Fake;
        impl account_secret_store::Backend for Fake {
            fn write(&self, _service: &str, _id: &str, _value: &[u8]) -> Result<()> {
                anyhow::bail!("Unused synthetic write")
            }
            fn read(&self, _service: &str, _id: &str) -> Result<zeroize::Zeroizing<Vec<u8>>> {
                Ok(zeroize::Zeroizing::new(
                    b"synthetic-codex-account-key".to_vec(),
                ))
            }
            fn delete(&self, _service: &str, _id: &str) -> Result<()> {
                anyhow::bail!("Unused synthetic delete")
            }
        }
        let (_root, mut engine, plan, binary) = fixture();
        let receipt = local_cli(plan, &binary);
        let saved = engine.apply_native_codex_key_enrollment(receipt).unwrap();
        let root = engine.store.data_directory().unwrap();
        assert!(
            crate::codex_login_profiles::LaunchContext::capture_native_key(
                &root, &saved.id, &binary
            )
            .is_err()
        );
        let configuration = {
            let owner = Private::open(&engine.store, false).unwrap().unwrap();
            let raw = engine.store.native_accounts_payload("codex").unwrap();
            let row = account(
                &read(&owner, "codex", raw.as_deref()).unwrap(),
                "codex",
                &saved.id,
            )
            .unwrap();
            let secrets = NativeSecretStore::from_owner(&owner)
                .unwrap()
                .with_backend(std::sync::Arc::new(Fake));
            keys::launch_with_secrets(&owner, &engine.store, row, &secrets).unwrap()
        };
        let context = {
            let _scope = enter(Some(configuration));
            let context = crate::codex_login_profiles::LaunchContext::capture_native_key(
                &root, &saved.id, &binary,
            )
            .unwrap();
            assert!(
                context
                    .admit_account(&json!({"requiresOpenaiAuth":true,"account":{"type":"apiKey"}}))
                    .is_ok()
            );
            assert!(
                context
                    .admit_account(&json!({"requiresOpenaiAuth":true,"account":{"type":"chatgpt"}}))
                    .is_err()
            );
            assert!(
                context
                    .arguments()
                    .iter()
                    .any(|argument| argument == "forced_login_method=\"api\"")
            );
            context
        };
        assert!(context.validate().is_err());
    }
    #[test]
    fn configuration_change_rejects_enrollment_receipt_without_losing_saved_key() {
        let (_root, mut engine, plan, binary) = fixture();
        let id = plan.account.id.clone();
        let receipt = local_cli(plan, &binary);
        super::super::super::tests::save(&mut engine, "codex", &binary, "changed-global");
        assert!(engine.apply_native_codex_key_enrollment(receipt).is_err());
        let owner = Private::open(&engine.store, false).unwrap().unwrap();
        let raw = engine.store.native_accounts_payload("codex").unwrap();
        let row = account(
            &read(&owner, "codex", raw.as_deref()).unwrap(),
            "codex",
            &id,
        )
        .unwrap();
        assert!(row.key.is_some() && row.codex_enrollment.is_none());
    }
}
