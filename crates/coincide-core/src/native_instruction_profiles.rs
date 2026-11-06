//! Native instruction review targets for existing app-managed account homes.
//! Configuration can name an account, never an arbitrary destination. These
//! values are deliberately opaque and cannot be constructed from JSON/imports.
use crate::{codex_login_profiles as profiles, private_fs, store::Store};
use anyhow::{Result, ensure};
use std::path::PathBuf;

fn source_path(store: &Store) -> Result<PathBuf> {
    #[cfg(any(unix, windows))]
    {
        store.resume_source_path()
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = store;
        anyhow::bail!("Native instruction profiles are unavailable on this platform")
    }
}

#[derive(Clone)]
pub struct NativeCodexInstructionHome {
    source: PathBuf,
    source_identity: private_fs::Identity,
    root: PathBuf,
    root_identity: private_fs::Identity,
    account: String,
    home: PathBuf,
    home_identity: private_fs::Identity,
}
impl NativeCodexInstructionHome {
    /// The native review must call this again before applying its captured plan.
    /// It grants a directory destination only; existing-file/link review and CAS
    /// remain required before any filesystem change.
    pub fn instruction_path(&self, store: &Store) -> Result<PathBuf> {
        ensure!(
            source_path(store)? == self.source
                && private_fs::identity(&self.source)? == self.source_identity
                && store.data_directory()? == self.root
                && private_fs::identity(&self.root)? == self.root_identity,
            "Instruction account target belongs to another or replaced Store"
        );
        let configuration = profiles::configuration(store)?;
        profiles::account(&configuration, &self.account)?;
        ensure!(
            profiles::managed_home(&self.root, &self.account, false)? == self.home
                && private_fs::identity(&self.home)? == self.home_identity,
            "Instruction account home changed; review its links again"
        );
        Ok(self.home.join("AGENTS.md"))
    }
}
impl Store {
    /// Read-only native setup discovery. Missing/invalid account homes are an
    /// explicit repair error; no directories, auth files or instructions are
    /// created, copied or read by this method.
    pub fn native_codex_instruction_homes(&self) -> Result<Vec<NativeCodexInstructionHome>> {
        let configuration = profiles::configuration(self)?;
        let accounts = configuration["accounts"].as_object().unwrap();
        ensure!(
            accounts.len() <= 128,
            "Too many managed Codex instruction targets"
        );
        if accounts.is_empty() {
            return Ok(Vec::new());
        }
        let source = source_path(self)?;
        let source_identity = private_fs::identity(&source)?;
        let root = self.data_directory()?;
        let root_identity = private_fs::identity(&root)?;
        let mut targets = Vec::new();
        for id in accounts.keys() {
            profiles::account(&configuration, id)?;
            let home = profiles::managed_home(&root, id, false)?;
            targets.push(NativeCodexInstructionHome {
                source: source.clone(),
                source_identity,
                root: root.clone(),
                root_identity,
                account: id.clone(),
                home_identity: private_fs::identity(&home)?,
                home,
            });
        }
        Ok(targets)
    }
}

#[cfg(all(test, any(unix, windows)))]
mod tests {
    use super::*;
    use serde_json::json;
    fn fixture() -> (tempfile::TempDir, Store, String) {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("data");
        crate::native_file::private_directory(&data).unwrap();
        let mut store = Store::open(&data.join("state.sqlite")).unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        profiles::managed_home(&store.data_directory().unwrap(), &id, true).unwrap();
        store.save_document(profiles::DOCUMENT,&json!({"version":1,"accounts":{id.clone():{"name":"Synthetic account","auth":"login","homePath":"/untrusted/ignored"}}})).unwrap();
        (dir, store, id)
    }
    #[test]
    fn target_uses_only_the_store_owned_home_without_creating_or_reading_instruction_content() {
        let (_dir, store, id) = fixture();
        let targets = store.native_codex_instruction_homes().unwrap();
        assert_eq!(targets.len(), 1);
        let expected = store
            .data_directory()
            .unwrap()
            .join("providers/codex")
            .join(id)
            .join("AGENTS.md");
        assert_eq!(targets[0].instruction_path(&store).unwrap(), expected);
        assert!(!expected.exists(), "Discovery must not create instructions");
        assert!(
            !expected.with_file_name("auth.json").exists(),
            "Discovery needs no credentials"
        );
    }
    #[test]
    fn removed_accounts_replaced_homes_other_stores_and_closed_stores_refuse_old_targets() {
        let (_dir, mut store, id) = fixture();
        let target = store.native_codex_instruction_homes().unwrap().remove(0);
        let mut other = Store::open(&store.data_directory().unwrap().join("other.sqlite")).unwrap();
        other
            .save_document(
                profiles::DOCUMENT,
                &profiles::configuration(&store).unwrap(),
            )
            .unwrap();
        assert!(target.instruction_path(&other).is_err());
        let configuration = profiles::configuration(&store).unwrap();
        store
            .save_document(profiles::DOCUMENT, &json!({"version":1,"accounts":{}}))
            .unwrap();
        assert!(target.instruction_path(&store).is_err());
        store
            .save_document(profiles::DOCUMENT, &configuration)
            .unwrap();
        let home = profiles::managed_home(&store.data_directory().unwrap(), &id, false).unwrap();
        std::fs::rename(&home, home.with_file_name("prior-home")).unwrap();
        profiles::managed_home(&store.data_directory().unwrap(), &id, true).unwrap();
        assert!(target.instruction_path(&store).is_err());
        store.close_for_shutdown().unwrap();
        assert!(target.instruction_path(&store).is_err());
    }
    #[test]
    fn imported_metadata_does_not_supply_targets_and_noncanonical_accounts_are_rejected() {
        let (_dir, mut store, _id) = fixture();
        store
            .save_document(profiles::DOCUMENT, &json!({"version":1,"accounts":{}}))
            .unwrap();
        assert!(store.native_codex_instruction_homes().unwrap().is_empty());
        store.save_document("instructions.json",&json!({"global":{"profileHomes":["/untrusted/ignored"],"masterPath":"/untrusted/ignored"}})).unwrap();
        assert!(store.native_codex_instruction_homes().unwrap().is_empty());
        store.save_document(profiles::DOCUMENT,&json!({"version":1,"accounts":{"ABCDEFAB-1234-4234-8234-ABCDEFABCDEF":{"name":"Synthetic","auth":"login"}}})).unwrap();
        assert!(store.native_codex_instruction_homes().is_err());
    }
}
