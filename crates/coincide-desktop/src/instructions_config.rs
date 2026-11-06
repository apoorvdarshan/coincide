//! Inert legacy metadata and pure review decisions. Neither persisted paths nor
//! a deserialized configuration are filesystem capabilities.
use anyhow::{Context as _, Result, ensure};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub(super) struct Metadata {
    pub document: Value,
}
impl Metadata {
    pub fn from_document(document: Option<Value>) -> Result<Self> {
        let document = document.unwrap_or_else(|| json!({"global":null,"projects":{}}));
        ensure!(
            document.is_object(),
            "Instruction settings are not an object"
        );
        ensure!(
            document["global"].is_null() || document["global"].is_object(),
            "Global instruction configuration is malformed"
        );
        ensure!(
            document["projects"].is_null() || document["projects"].is_object(),
            "Project instruction configuration is malformed"
        );
        Ok(Self { document })
    }
    pub fn configuration(&self, project: Option<&Path>) -> Result<Option<Configuration>> {
        let value = match project {
            Some(root) => {
                self.document["projects"].get(root.to_str().context("Project path is not UTF-8")?)
            }
            None => self.document.get("global"),
        };
        value
            .filter(|v| !v.is_null())
            .map(Configuration::parse)
            .transpose()
    }
    pub fn with_configuration(&self, project: Option<&Path>, config: &Value) -> Result<Value> {
        Configuration::parse(config)?;
        let mut document = self.document.clone();
        if let Some(root) = project {
            if document["projects"].is_null() {
                document["projects"] = json!({});
            }
            document["projects"][root.to_str().context("Project path is not UTF-8")?] =
                config.clone();
        } else {
            document["global"] = config.clone();
        }
        Ok(document)
    }
}
#[derive(Clone, Debug)]
pub(super) struct Configuration {
    pub raw: Value,
    pub enabled: bool,
    pub master: PathBuf,
    pub legacy_sync: bool,
}
impl Configuration {
    fn parse(value: &Value) -> Result<Self> {
        ensure!(
            value.is_object(),
            "Instruction master configuration is malformed"
        );
        let master = PathBuf::from(
            value["masterPath"]
                .as_str()
                .context("Instruction master path is missing")?,
        );
        ensure!(
            master.is_absolute(),
            "Configured master path must be absolute"
        );
        ensure!(
            value["isEnabled"].is_null() || value["isEnabled"].is_boolean(),
            "Instruction master enablement is malformed"
        );
        for key in ["iCloud", "git"] {
            ensure!(
                value[key].is_null() || value[key].is_object(),
                "Instruction copy configuration is malformed"
            );
        }
        let legacy_sync = !value["sync"].is_null()
            && value["sync"] != json!({"off":{}})
            && value["sync"] != "off";
        Ok(Self {
            raw: value.clone(),
            enabled: value["isEnabled"] == true,
            master,
            legacy_sync,
        })
    }
    pub fn copy_status(&self) -> Vec<String> {
        let mut rows = Vec::new();
        if self.legacy_sync {
            rows.push("Legacy sync configuration needs native review before migration".into());
        }
        for (key, name) in [("iCloud", "iCloud"), ("git", "Git")] {
            if !self.raw[key].is_null() {
                rows.push(format!(
                    "{name} copy configured; synchronization is not active"
                ));
            }
        }
        rows
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum TargetState {
    Linked,
    Missing,
    Identical,
    Differs,
    ForeignLink,
    BrokenLink,
    FolderMissing,
    Unreadable,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Choice {
    Merge,
    UseMaster,
    Skip,
}
impl TargetState {
    pub fn default_choice(&self) -> Choice {
        match self {
            Self::Missing | Self::Identical => Choice::UseMaster,
            Self::Differs => Choice::Merge,
            _ => Choice::Skip,
        }
    }
    pub fn label(&self) -> &'static str {
        match self {
            Self::Linked => "Linked",
            Self::Missing => "Missing",
            Self::Identical => "Same text",
            Self::Differs => "Different text",
            Self::ForeignLink => "Links elsewhere",
            Self::BrokenLink => "Broken link",
            Self::FolderMissing => "Folder missing",
            Self::Unreadable => "Cannot read",
        }
    }
}
pub(super) fn merged(master: &str, other: &str, name: &str) -> String {
    let mut result = master.to_owned();
    if !result.is_empty() {
        if !result.ends_with('\n') {
            result.push('\n');
        }
        result.push('\n');
    }
    result.push_str(&format!("## From {name}\n\n{}\n", other.trim_matches('\n')));
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn imported_paths_are_metadata_and_updates_keep_unknown_scopes_and_copy_fields() {
        let master = std::env::temp_dir().join("synthetic-instructions-master.md");
        let doc = json!({"future":7,"global":{"masterPath":master,"isEnabled":true,"git":{"repository":"/synthetic/repo","path":"/synthetic/repo/a.md","agreed":"kept"},"opaque":4},"projects":{"/synthetic/other":{"masterPath":"/synthetic/other/AGENTS.md"}}});
        let metadata = Metadata::from_document(Some(doc.clone())).unwrap();
        let config = metadata.configuration(None).unwrap().unwrap();
        assert_eq!(config.copy_status().len(), 1);
        let mut updated = config.raw;
        updated["isEnabled"] = json!(false);
        let next = metadata.with_configuration(None, &updated).unwrap();
        assert_eq!(next["projects"], doc["projects"]);
        assert_eq!(next["global"]["git"], doc["global"]["git"]);
        assert_eq!(next["future"], 7);
    }
    #[::core::prelude::v1::test]
    fn invalid_configuration_refuses_and_review_defaults_never_replace_foreign_links() {
        assert!(Metadata::from_document(Some(json!([]))).is_err());
        let metadata =
            Metadata::from_document(Some(json!({"global":{"masterPath":"relative"}}))).unwrap();
        assert!(metadata.configuration(None).is_err());
        assert_eq!(TargetState::ForeignLink.default_choice(), Choice::Skip);
        assert_eq!(TargetState::BrokenLink.default_choice(), Choice::Skip);
        assert_eq!(TargetState::Differs.default_choice(), Choice::Merge);
        assert_eq!(
            merged("one", "two\n", "CLAUDE.md"),
            "one\n\n## From CLAUDE.md\n\ntwo\n"
        );
    }
}
