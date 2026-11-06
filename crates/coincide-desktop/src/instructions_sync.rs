//! Explicit native three-way file synchronization. No imported configuration or
//! timer can construct a write plan; every apply uses retained source custody.
use super::file::EditorFile;
use crate::instructions_scope::{NativeInstructionCreation, NativeScope};
use anyhow::{Context as _, Result, ensure};
use coincide_core::store::Store;
use sha2::{Digest, Sha256};
use std::path::PathBuf;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Step {
    Matching,
    UpdateCopy,
    UpdateMaster,
    Conflict,
}
#[derive(Clone, Copy)]
pub(super) enum Keep {
    Master,
    Copy,
}
fn digest(text: &str) -> String {
    Sha256::digest(text.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn step(master: Option<&str>, copy: Option<&str>, agreed: Option<&str>) -> Step {
    match (master, copy) {
        (None, None) => Step::Matching,
        (None, Some(_)) => Step::UpdateMaster,
        (Some(_), None) => Step::UpdateCopy,
        (Some(a), Some(b)) if a == b => Step::Matching,
        (Some(_), Some(b)) if Some(digest(b).as_str()) == agreed => Step::UpdateCopy,
        (Some(a), Some(_)) if Some(digest(a).as_str()) == agreed => Step::UpdateMaster,
        _ => Step::Conflict,
    }
}
enum Captured {
    Existing(EditorFile),
    Missing(NativeInstructionCreation),
}
impl Captured {
    fn capture(scope: &NativeScope, store: &Store) -> Result<Self> {
        let mut file = EditorFile::from_native_scope(scope)?;
        match file.load() {
            Ok(_) => Ok(Self::Existing(file)),
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
            {
                Ok(Self::Missing(scope.prepare_creation_native(store)?))
            }
            Err(error) => Err(error),
        }
    }
    fn text(&self) -> Option<&str> {
        match self {
            Self::Existing(file) => file.baseline(),
            Self::Missing(_) => None,
        }
    }
    fn validate(&self, store: &Store) -> Result<()> {
        match self {
            Self::Existing(file) => file.validate_review_source(),
            Self::Missing(creation) => creation.validate(store),
        }
    }
    fn backup(&self) -> Result<Option<PathBuf>> {
        match self {
            Self::Existing(file) => Ok(Some(file.retain_sync_backup()?)),
            Self::Missing(_) => Ok(None),
        }
    }
    fn write(self, store: &Store, text: &str) -> Result<()> {
        match self {
            Self::Existing(mut file) => file.save(text),
            Self::Missing(creation) => creation.create(store, text),
        }
    }
}
pub(super) struct Plan {
    pub master_scope: NativeScope,
    pub copy_scope: NativeScope,
    master: Captured,
    copy: Captured,
    pub step: Step,
}
#[derive(Clone)]
pub(super) struct Receipt {
    hash: String,
    master: PathBuf,
    copy: PathBuf,
}
pub(super) struct Applied {
    pub receipt: Option<Receipt>,
    pub backups: Vec<PathBuf>,
}
impl Applied {
    pub fn agreed_for_metadata(&self) -> Option<&str> {
        self.receipt.as_ref().map(|r| r.hash.as_str())
    }
}
impl Plan {
    pub fn capture(
        master: NativeScope,
        copy: NativeScope,
        store: &Store,
        agreed: Option<&Receipt>,
    ) -> Result<Self> {
        master.validate_native(store)?;
        copy.validate_native(store)?;
        ensure!(
            master.master_path() != copy.master_path(),
            "Choose a separate copy file"
        );
        if let (Ok(a), Ok(b)) = (
            master.master_path().canonicalize(),
            copy.master_path().canonicalize(),
        ) {
            ensure!(a != b, "Master and copy resolve to the same file");
        }
        if let (Ok(a), Ok(b)) = (
            coincide_core::native_file::path_identity(master.master_path()),
            coincide_core::native_file::path_identity(copy.master_path()),
        ) {
            ensure!(a != b, "Master and copy refer to the same physical file");
        }
        let master_file = Captured::capture(&master, store)?;
        let copy_file = Captured::capture(&copy, store)?;
        master_file.validate(store)?;
        copy_file.validate(store)?;
        let baseline = agreed
            .filter(|r| r.master == master.master_path() && r.copy == copy.master_path())
            .map(|r| r.hash.as_str());
        let step = step(master_file.text(), copy_file.text(), baseline);
        Ok(Self {
            master_scope: master,
            copy_scope: copy,
            master: master_file,
            copy: copy_file,
            step,
        })
    }
    pub fn master_text(&self) -> Option<&str> {
        self.master.text()
    }
    pub fn copy_text(&self) -> Option<&str> {
        self.copy.text()
    }
    pub fn apply(self, store: &Store, keep: Option<Keep>) -> Result<Applied> {
        self.master_scope.validate_native(store)?;
        self.copy_scope.validate_native(store)?;
        self.master.validate(store)?;
        self.copy.validate(store)?;
        let keep = match self.step {
            Step::Matching => None,
            Step::UpdateCopy => Some(Keep::Master),
            Step::UpdateMaster => Some(Keep::Copy),
            Step::Conflict => Some(
                keep.context("Choose which version to keep; both originals will be backed up")?,
            ),
        };
        let mut backups = Vec::new();
        // Preserve both captured versions before a conflict is resolved. Even a
        // later destination failure cannot erase the losing version.
        if self.step == Step::Conflict {
            for source in [&self.master, &self.copy] {
                let path = source.backup().map_err(|error| {
                    error.context(format!(
                        "Preserved versions before failure: {}",
                        backups
                            .iter()
                            .map(|p: &PathBuf| p.display().to_string())
                            .collect::<Vec<_>>()
                            .join(", ")
                    ))
                })?;
                if let Some(path) = path {
                    backups.push(path);
                }
            }
        }
        if self.step == Step::UpdateCopy {
            if let Some(path) = self.copy.backup()? {
                backups.push(path);
            }
        }
        if self.step == Step::UpdateMaster {
            if let Some(path) = self.master.backup()? {
                backups.push(path);
            }
        }
        let outcome = (|| -> Result<Option<String>> {
            let agreed = match keep {
                Some(Keep::Master) => {
                    let text = self.master.text().unwrap_or("").to_owned();
                    self.copy.write(store, &text)?;
                    self.master.validate(store)?;
                    Some(digest(&text))
                }
                Some(Keep::Copy) => {
                    let text = self.copy.text().unwrap_or("").to_owned();
                    self.master.write(store, &text)?;
                    self.copy.validate(store)?;
                    Some(digest(&text))
                }
                None => self.master.text().map(digest),
            };
            Ok(agreed)
        })();
        let agreed = outcome.map_err(|error| {
            if backups.is_empty() {
                error
            } else {
                error.context(format!(
                    "Captured versions retained at {}",
                    backups
                        .iter()
                        .map(|p| p.display().to_string())
                        .collect::<Vec<_>>()
                        .join(", ")
                ))
            }
        })?;
        let receipt = agreed.map(|hash| Receipt {
            hash,
            master: self.master_scope.master_path().to_owned(),
            copy: self.copy_scope.master_path().to_owned(),
        });
        Ok(Applied { receipt, backups })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        root: PathBuf,
        store: Store,
        master: NativeScope,
        copy: NativeScope,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "coincide-native-copy-sync-{}",
                uuid::Uuid::new_v4()
            ));
            coincide_core::native_file::private_directory(&root).unwrap();
            let mut store = Store::open(&root.join("state.sqlite")).unwrap();
            let project = store
                .create_project(&root, Some("Synthetic copy sync"))
                .unwrap();
            let master =
                NativeScope::project_native(&store, project["id"].as_str().unwrap()).unwrap();
            let mut copy = master.clone();
            copy.choose_master_native(root.join("copy.md"), &store)
                .unwrap();
            Self {
                root,
                store,
                master,
                copy,
            }
        }
        fn plan(&self, agreed: Option<&Receipt>) -> Plan {
            let mut plan =
                Plan::capture(self.master.clone(), self.copy.clone(), &self.store, agreed).unwrap();
            for captured in [&mut plan.master, &mut plan.copy] {
                if let Captured::Existing(file) = captured {
                    file.synthetic_recovery(self.root.join("recovery"));
                }
            }
            plan
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = self.store.close_for_shutdown();
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    #[::core::prelude::v1::test]
    fn native_copy_creates_missing_copy_then_imports_only_changed_copy_preserving_master_identity()
    {
        let fixture = Fixture::new();
        std::fs::write(fixture.master.master_path(), "Original A").unwrap();
        let identity =
            coincide_core::native_file::path_identity(fixture.master.master_path()).unwrap();
        let plan = fixture.plan(None);
        assert_eq!(plan.step, Step::UpdateCopy);
        let first = plan.apply(&fixture.store, None).unwrap();
        assert_eq!(
            std::fs::read_to_string(fixture.copy.master_path()).unwrap(),
            "Original A"
        );
        assert_eq!(
            coincide_core::native_file::path_identity(fixture.master.master_path()).unwrap(),
            identity
        );
        std::fs::write(fixture.copy.master_path(), "Changed B").unwrap();
        let plan = fixture.plan(first.receipt.as_ref());
        assert_eq!(plan.step, Step::UpdateMaster);
        let applied = plan.apply(&fixture.store, None).unwrap();
        assert_eq!(
            std::fs::read_to_string(fixture.master.master_path()).unwrap(),
            "Changed B"
        );
        assert_eq!(
            coincide_core::native_file::path_identity(fixture.master.master_path()).unwrap(),
            identity
        );
        assert!(
            applied
                .backups
                .iter()
                .any(|p| std::fs::read_to_string(p).unwrap() == "Original A")
        );
    }
    #[::core::prelude::v1::test]
    fn conflicts_require_native_choice_and_preserve_both_original_versions() {
        let fixture = Fixture::new();
        std::fs::write(fixture.master.master_path(), "Previously A").unwrap();
        std::fs::write(fixture.copy.master_path(), "Previously A").unwrap();
        let agreed = fixture
            .plan(None)
            .apply(&fixture.store, None)
            .unwrap()
            .receipt
            .unwrap();
        std::fs::write(fixture.master.master_path(), "Master B").unwrap();
        std::fs::write(fixture.copy.master_path(), "Copy C").unwrap();
        let plan = fixture.plan(Some(&agreed));
        assert_eq!(plan.step, Step::Conflict);
        assert!(plan.apply(&fixture.store, None).is_err());
        assert_eq!(
            std::fs::read_to_string(fixture.master.master_path()).unwrap(),
            "Master B"
        );
        assert_eq!(
            std::fs::read_to_string(fixture.copy.master_path()).unwrap(),
            "Copy C"
        );
        assert!(!fixture.root.join("recovery").exists());
        let applied = fixture
            .plan(Some(&agreed))
            .apply(&fixture.store, Some(Keep::Copy))
            .unwrap();
        let versions = applied
            .backups
            .iter()
            .map(|p| std::fs::read_to_string(p).unwrap())
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            versions,
            std::collections::BTreeSet::from(["Master B".to_owned(), "Copy C".to_owned()])
        );
        assert_eq!(
            std::fs::read_to_string(fixture.master.master_path()).unwrap(),
            "Copy C"
        );
        assert_eq!(
            std::fs::read_to_string(fixture.copy.master_path()).unwrap(),
            "Copy C"
        );
    }
    #[::core::prelude::v1::test]
    fn imported_agreed_digest_cannot_replace_a_trusted_native_matching_receipt() {
        let mut fixture = Fixture::new();
        std::fs::write(fixture.master.master_path(), "Master B").unwrap();
        std::fs::write(fixture.copy.master_path(), "Copy C").unwrap();
        fixture.store.save_document("instructions.json",&serde_json::json!({"projects":{(fixture.root.to_str().unwrap()):{"masterPath":fixture.master.master_path(),"fileCopy":{"path":fixture.copy.master_path(),"agreed":digest("Master B")}}},"opaque":{"preserve":true}})).unwrap();
        let plan = fixture.plan(None);
        assert_eq!(
            plan.step,
            Step::Conflict,
            "Metadata hashes are never a native receipt"
        );
        assert!(plan.apply(&fixture.store, None).is_err());
        assert_eq!(
            std::fs::read_to_string(fixture.master.master_path()).unwrap(),
            "Master B"
        );
        assert_eq!(
            std::fs::read_to_string(fixture.copy.master_path()).unwrap(),
            "Copy C"
        );
        assert!(!fixture.root.join("recovery").exists());
    }
    #[::core::prelude::v1::test]
    fn stale_same_bytes_replacement_missing_target_appearance_and_aliases_refuse_without_overwrite()
    {
        let fixture = Fixture::new();
        std::fs::write(fixture.master.master_path(), "Reviewed A").unwrap();
        let plan = fixture.plan(None);
        std::fs::write(fixture.copy.master_path(), "External appeared").unwrap();
        assert!(plan.apply(&fixture.store, None).is_err());
        assert_eq!(
            std::fs::read_to_string(fixture.copy.master_path()).unwrap(),
            "External appeared"
        );
        let plan = fixture.plan(None);
        let old = fixture.root.join("old-master.md");
        std::fs::rename(fixture.master.master_path(), &old).unwrap();
        std::fs::write(fixture.master.master_path(), "Reviewed A").unwrap();
        assert!(plan.apply(&fixture.store, None).is_err());
        assert_eq!(
            std::fs::read_to_string(fixture.master.master_path()).unwrap(),
            "Reviewed A"
        );
        assert_eq!(
            std::fs::read_to_string(fixture.copy.master_path()).unwrap(),
            "External appeared"
        );
        assert!(!fixture.root.join("recovery").exists());
        std::fs::remove_file(fixture.copy.master_path()).unwrap();
        std::fs::hard_link(fixture.master.master_path(), fixture.copy.master_path()).unwrap();
        assert!(
            Plan::capture(
                fixture.master.clone(),
                fixture.copy.clone(),
                &fixture.store,
                None
            )
            .is_err()
        );
    }
    #[::core::prelude::v1::test]
    fn three_way_decisions_match_swift_missing_equal_one_side_and_conflict_rules() {
        let a = digest("A");
        assert_eq!(
            a,
            "559aead08264d5795d3909718cdd05abd49572e84fe55590eef31a88a08fdffd"
        );
        assert_eq!(step(None, None, None), Step::Matching);
        assert_eq!(step(Some("A"), None, None), Step::UpdateCopy);
        assert_eq!(step(None, Some("A"), None), Step::UpdateMaster);
        assert_eq!(step(Some("A"), Some("A"), None), Step::Matching);
        assert_eq!(step(Some("B"), Some("A"), Some(&a)), Step::UpdateCopy);
        assert_eq!(step(Some("A"), Some("B"), Some(&a)), Step::UpdateMaster);
        assert_eq!(step(Some("B"), Some("C"), Some(&a)), Step::Conflict);
        assert_eq!(step(Some("A"), Some("B"), None), Step::Conflict);
    }
}
