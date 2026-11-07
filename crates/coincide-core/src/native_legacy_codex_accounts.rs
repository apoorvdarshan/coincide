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
fn revision(engine: &Engine, configuration: &Value) -> Result<String> {
    let (path, identity) = source(&engine.store)?;
    Ok(crate::digest_hex::lower_hex(Sha256::digest(
        serde_json::to_vec(
            &json!({"source":path,"identity":identity,"configuration":configuration}),
        )?,
    )))
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
    ) -> Result<()> {
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
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rename_preserves_unknowns_and_order_and_rejects_other_source_or_changed_document() {
        let (_root, mut engine, _) = super::super::tests::fixture();
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
        engine.apply_native_legacy_codex_rename(current).unwrap();
        assert!(engine.apply_native_legacy_codex_rename(stale).is_err());
        document["accounts"][id]["name"] = json!("Renamed");
        assert_eq!(legacy::configuration(&engine.store).unwrap(), document);
        let current = engine.native_legacy_codex_accounts().unwrap().remove(0);
        let foreign = engine
            .prepare_native_legacy_codex_rename(id, &current.revision, "Wrong source")
            .unwrap();
        let (_other, mut other, _) = super::super::tests::fixture();
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
