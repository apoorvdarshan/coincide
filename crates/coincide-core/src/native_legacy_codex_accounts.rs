//! Native label review for existing Rust subscription profiles. This creates no
//! account/key/session grant and preserves the legacy subscription document.
use super::*;
use crate::codex_login_profiles as legacy;
#[derive(Clone)]
pub struct NativeLegacyCodexAccount {
    pub id: String,
    pub name: String,
    pub revision: String,
}
pub struct PreparedLegacyCodexRename {
    source: (PathBuf, crate::private_fs::Identity),
    configuration: Value,
    id: String,
    name: String,
    home: PathBuf,
    home_identity: crate::private_fs::Identity,
}
fn revision_at(
    source: &(PathBuf, crate::private_fs::Identity),
    configuration: &Value,
) -> Result<String> {
    let (path, identity) = source;
    Ok(crate::digest_hex::lower_hex(Sha256::digest(
        serde_json::to_vec(
            &json!({"source":path,"identity":identity,"configuration":configuration}),
        )?,
    )))
}
fn revision(engine: &Engine, configuration: &Value) -> Result<String> {
    revision_at(&source(&engine.store)?, configuration)
}

impl Engine {
    pub fn native_legacy_codex_accounts(&self) -> Result<Vec<NativeLegacyCodexAccount>> {
        let configuration = legacy::configuration(&self.store)?;
        let revision = revision(self, &configuration)?;
        legacy::ordered_accounts(&configuration)?
            .into_iter()
            .map(|id| {
                let row = legacy::account(&configuration, &id)?;
                Ok(NativeLegacyCodexAccount {
                    id: id.clone(),
                    name: row["name"].as_str().unwrap().into(),
                    revision: revision.clone(),
                })
            })
            .collect()
    }
    pub fn prepare_native_legacy_codex_rename(
        &self,
        id: &str,
        expected: &str,
        name: &str,
    ) -> Result<PreparedLegacyCodexRename> {
        self.require_admissions()?;
        let name = name.trim();
        ensure!(
            !name.is_empty() && name.len() <= 120 && !name.chars().any(char::is_control),
            "Invalid Codex profile name"
        );
        let configuration = legacy::configuration(&self.store)?;
        legacy::account(&configuration, id)?;
        ensure!(
            revision(self, &configuration)? == expected,
            "Codex profiles changed; reload before renaming"
        );
        let home = legacy::managed_home(&self.store.data_directory()?, id, false)?;
        let home_identity = crate::private_fs::identity(&home)?;
        Ok(PreparedLegacyCodexRename {
            source: source(&self.store)?,
            configuration,
            id: id.into(),
            name: name.into(),
            home,
            home_identity,
        })
    }
    pub fn apply_native_legacy_codex_rename(
        &mut self,
        plan: PreparedLegacyCodexRename,
    ) -> Result<String> {
        self.require_admissions()?;
        ensure!(
            source(&self.store)? == plan.source
                && legacy::managed_home(&self.store.data_directory()?, &plan.id, false)?
                    == plan.home
                && crate::private_fs::identity(&plan.home)? == plan.home_identity,
            "Codex profile source or home changed"
        );
        self.store
            .rename_legacy_codex_profile(&plan.configuration, &plan.id, &plan.name)?;
        self.revision += 1;
        let mut renamed = plan.configuration;
        renamed["accounts"][&plan.id]["name"] = json!(plan.name);
        revision_at(&plan.source, &renamed)
    }
}
pub struct PreparedLegacyCodexRemoval {
    source: Value,
    configuration: Value,
    registry: Option<String>,
    account: Account,
    threads: Vec<Value>,
    _exclusive: LoginHome,
}
impl PreparedLegacyCodexRemoval {
    pub fn name(&self) -> &str {
        &self.account.name
    }
    pub fn conversation_count(&self) -> usize {
        self.threads.len()
    }
}
impl Engine {
    pub fn prepare_native_legacy_codex_removal(
        &mut self,
        id: &str,
        expected: &str,
    ) -> Result<PreparedLegacyCodexRemoval> {
        self.require_admissions()?;
        let configuration = legacy::configuration(&self.store)?;
        let row = legacy::account(&configuration, id)?;
        ensure!(
            revision(self, &configuration)? == expected,
            "Codex profiles changed; review removal again"
        );
        let threads = self.store.native_account_removal_threads("codex", id)?;
        removal::ready(self, &threads)?;
        let owner =
            Private::open(&self.store, true)?.context("Native account authority missing")?;
        let registry = self.store.native_accounts_payload("codex")?;
        let payload = read(&owner, "codex", registry.as_deref())?;
        ensure!(
            payload["accounts"].get(id).is_none(),
            "This profile already uses native account settings"
        );
        let home = legacy::managed_home(&self.store.data_directory()?, id, false)?;
        let pin = CodexHomeLease::capture(&home)?;
        pin.validate()?;
        let account = Account {
            id: id.into(),
            provider: "codex".into(),
            name: row["name"].as_str().unwrap().into(),
            revision: Uuid::new_v4().to_string(),
            launch_revision: Uuid::new_v4().to_string(),
            authentication: Authentication::Login,
            key_variable: None,
            key: None,
            admin_key: None,
            codex_enrollment: None,
            home_identity: crate::private_fs::identity(&home)?,
            guard_identity: crate::private_fs::identity(&home.join(GUARD))?,
            home,
        };
        let exclusive =
            LoginHome::capture_mode(&self.store.data_directory()?, account.clone(), true, true)?;
        exclusive.validate()?;
        Ok(PreparedLegacyCodexRemoval {
            source: owner.source.clone(),
            configuration,
            registry,
            account,
            threads,
            _exclusive: exclusive,
        })
    }
    pub fn apply_native_legacy_codex_removal(
        &mut self,
        plan: PreparedLegacyCodexRemoval,
    ) -> Result<NativeAccountRemoval> {
        removal::ready(self, &plan.threads)?;
        plan._exclusive.validate()?;
        let owner =
            Private::open(&self.store, false)?.context("Native account authority missing")?;
        ensure!(
            owner.source == plan.source,
            "Codex removal belongs to another Store"
        );
        let mut payload = read(&owner, "codex", plan.registry.as_deref())?;
        removal::tombstone(&mut payload, &plan.account)?;
        if payload.get("revoked_accounts").is_none() {
            payload["revoked_accounts"] = json!({});
        }
        let revoked = payload["revoked_accounts"]
            .as_object_mut()
            .context("Account revocations malformed")?;
        ensure!(
            revoked.len() < 10_000,
            "Account revocations exceed their bound"
        );
        revoked.insert(plan.account.id.clone(), json!(true));
        let committed = encoded(&owner, &payload)?;
        self.store.revoke_legacy_codex_profile(
            &plan.configuration,
            &plan.account.id,
            plan.registry.as_deref(),
            &committed,
            &plan.threads,
        )?;
        self.revision += 1;
        let count = plan.threads.len();
        drop(plan._exclusive);
        // Revocation is durable before private-home deletion. Retain its exact
        // tombstone on any failure; normal native cleanup can retry it later.
        let mut pending = true;
        if removal::remove_home(&self.store.data_directory()?, &plan.account).is_ok() {
            payload["removed_accounts"]
                .as_object_mut()
                .unwrap()
                .remove(&plan.account.id);
            pending = self
                .store
                .save_native_accounts_payload(
                    "codex",
                    Some(&committed),
                    &encoded(&owner, &payload)?,
                )
                .is_err();
        }
        Ok(NativeAccountRemoval {
            conversations: count,
            cleanup_pending: pending,
        })
    }
}

pub(super) fn codex_order(payload: &Value, legacy: &Value) -> Result<Vec<String>> {
    let mut live = legacy::ordered_accounts(legacy)?;
    for id in ordered_ids(payload)? {
        if !live.contains(&id) {
            live.push(id);
        }
    }
    let mut result = Vec::new();
    if let Some(order) = payload.get("codex_order") {
        let order = order.as_array().context("Codex account order is invalid")?;
        ensure!(order.len() <= 256, "Codex account order exceeds its bound");
        let mut seen = std::collections::HashSet::new();
        for id in order {
            let id = id
                .as_str()
                .context("Codex account order identity is invalid")?;
            ensure!(
                Uuid::parse_str(id)?.to_string() == id && seen.insert(id),
                "Codex account order is duplicated or invalid"
            );
            if live.iter().any(|live| live == id) {
                result.push(id.to_owned());
            }
        }
    }
    for id in live {
        if !result.contains(&id) {
            result.push(id);
        }
    }
    Ok(result)
}
pub(super) fn note_creation_order(store: &Store, payload: &mut Value, id: &str) -> Result<()> {
    let mut order = codex_order(payload, &legacy::configuration(store)?)?;
    ensure!(
        !order.iter().any(|existing| existing == id),
        "Codex account already exists"
    );
    order.push(id.into());
    payload["codex_order"] = json!(order);
    Ok(())
}
impl Engine {
    pub fn native_codex_account_order(&self) -> Result<Vec<String>> {
        let payload = if let Some(owner) = Private::open(&self.store, false)? {
            read(
                &owner,
                "codex",
                self.store.native_accounts_payload("codex")?.as_deref(),
            )?
        } else {
            json!({"accounts":{}})
        };
        codex_order(&payload, &legacy::configuration(&self.store)?)
    }
}

#[path = "native_codex_auth_method.rs"]
mod auth_method;
pub use auth_method::PreparedCodexAuthChange;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reviewed_removal_excludes_other_child_owners_and_preserves_conversation_content() {
        let (_root, mut engine, binary) = super::super::super::tests::fixture();
        let row = engine
            .execute(
                "providers.codex.profiles.create",
                &json!({"name":"Synthetic removed profile"}),
            )
            .unwrap();
        let id = row["id"].as_str().unwrap();
        let thread = json!({"id":Uuid::new_v4().to_string(),"title":"Preserved","draft":"Keep draft","items":[{"role":"user","text":"Keep history"}],"selection":{"provider":"codex","modelID":"default","accountID":id},"future":{"keep":true}});
        engine.store.save(&thread).unwrap();
        let account = engine.native_legacy_codex_accounts().unwrap().remove(0);
        let context =
            legacy::LaunchContext::capture(&engine.store.data_directory().unwrap(), id, &binary)
                .unwrap();
        let actual_child_lease = context.acquire_home_lease().unwrap();
        assert!(
            engine
                .prepare_native_legacy_codex_removal(id, &account.revision)
                .is_err()
        );
        drop(actual_child_lease);
        let plan = engine
            .prepare_native_legacy_codex_removal(id, &account.revision)
            .unwrap();
        assert!(context.acquire_home_lease().is_err());
        let mut peer =
            Engine::new(Store::open(&engine.store.resume_source_path().unwrap()).unwrap());
        let mut changed = thread.clone();
        changed["draft"] = json!("Newer draft from peer");
        peer.store.save(&changed).unwrap();
        assert!(engine.apply_native_legacy_codex_removal(plan).is_err());
        assert_eq!(engine.native_legacy_codex_accounts().unwrap().len(), 1);
        let plan = engine
            .prepare_native_legacy_codex_removal(id, &account.revision)
            .unwrap();
        let result = engine.apply_native_legacy_codex_removal(plan).unwrap();
        assert_eq!(result.conversations, 1);
        assert!(!result.cleanup_pending);
        changed["selection"]
            .as_object_mut()
            .unwrap()
            .remove("accountID");
        assert_eq!(
            engine.store.thread(thread["id"].as_str().unwrap()).unwrap(),
            changed
        );
        assert!(engine.native_legacy_codex_accounts().unwrap().is_empty());
        assert!(engine.routes_native_provider_account(&thread).unwrap());
        assert!(engine.validate_native_account_selection(&thread).is_err());
    }
    #[test]
    fn rename_preserves_unknowns_and_order_and_rejects_other_source_or_changed_document() {
        let (_root, mut engine, _) = super::super::super::tests::fixture();
        let row = engine
            .execute(
                "providers.codex.profiles.create",
                &json!({"name":"Synthetic legacy"}),
            )
            .unwrap();
        let id = row["id"].as_str().unwrap();
        let mut document = legacy::configuration(&engine.store).unwrap();
        document["future"] = json!({"preserve":true});
        document["accounts"][id]["future"] = json!([1, 2, 3]);
        engine
            .store
            .save_document(legacy::DOCUMENT, &document)
            .unwrap();
        let account = engine.native_legacy_codex_accounts().unwrap().remove(0);
        let stale = engine
            .prepare_native_legacy_codex_rename(id, &account.revision, "Stale")
            .unwrap();
        let current = engine
            .prepare_native_legacy_codex_rename(id, &account.revision, "Renamed")
            .unwrap();
        let renamed_revision = engine.apply_native_legacy_codex_rename(current).unwrap();
        assert_eq!(
            engine.native_legacy_codex_accounts().unwrap()[0].revision,
            renamed_revision
        );
        assert!(engine.apply_native_legacy_codex_rename(stale).is_err());
        document["accounts"][id]["name"] = json!("Renamed");
        assert_eq!(legacy::configuration(&engine.store).unwrap(), document);
        let current = engine.native_legacy_codex_accounts().unwrap().remove(0);
        let foreign = engine
            .prepare_native_legacy_codex_rename(id, &current.revision, "Wrong source")
            .unwrap();
        let (_other, mut other, _) = super::super::super::tests::fixture();
        assert!(other.apply_native_legacy_codex_rename(foreign).is_err());
        let plan = engine
            .prepare_native_legacy_codex_rename(id, &current.revision, "Race overwrite")
            .unwrap();
        let mut peer =
            Engine::new(Store::open(&engine.store.resume_source_path().unwrap()).unwrap());
        let mut concurrent = legacy::configuration(&peer.store).unwrap();
        concurrent["peerFuture"] = json!("preserve competing metadata");
        peer.store
            .save_document(legacy::DOCUMENT, &concurrent)
            .unwrap();
        assert!(engine.apply_native_legacy_codex_rename(plan).is_err());
        assert_eq!(legacy::configuration(&engine.store).unwrap(), concurrent);
    }
}
