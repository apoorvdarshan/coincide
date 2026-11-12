//! Native path-reference discovery. Listings and metadata never read file bodies.
use super::*;
use crate::composer_context::{self, ExpectedContext};
use std::{
    path::{Component, Path},
    sync::Arc,
    time::SystemTime,
};
const LIMIT: usize = 80;
const MAX_ROW: usize = 8 * 1024 * 1024;
#[derive(Clone, PartialEq, Eq)]
struct Identity {
    len: u64,
    modified: SystemTime,
    #[cfg(unix)]
    dev: u64,
    #[cfg(unix)]
    ino: u64,
}
fn identity(metadata: &std::fs::Metadata) -> Result<Identity> {
    #[cfg(unix)]
    use std::os::unix::fs::MetadataExt;
    Ok(Identity {
        len: metadata.len(),
        modified: metadata.modified()?,
        #[cfg(unix)]
        dev: metadata.dev(),
        #[cfg(unix)]
        ino: metadata.ino(),
    })
}
fn path_identity(root: &Path, path: &str) -> Result<(Identity, bool)> {
    composer_context::validate_file_reference_path(path)?;
    let parts: Vec<_> = Path::new(path).components().collect();
    let mut current = root.to_owned();
    for (index, part) in parts.iter().enumerate() {
        let Component::Normal(name) = part else {
            bail!("Use a relative project file path");
        };
        current.push(name);
        let metadata =
            std::fs::symlink_metadata(&current).context("Project file is unavailable")?;
        ensure!(
            !metadata.file_type().is_symlink(),
            "Symbolic links are not attached by this picker"
        );
        if index + 1 == parts.len() {
            ensure!(
                metadata.is_file() || metadata.is_dir(),
                "Choose a regular project file or folder"
            );
            return Ok((identity(&metadata)?, metadata.is_dir()));
        }
        ensure!(metadata.is_dir(), "Project path is no longer a directory");
    }
    bail!("File path is empty")
}
#[derive(Clone)]
pub struct FileReferenceScope {
    owner: Uuid,
    thread: String,
    source: Arc<String>,
    projects: Arc<Value>,
    root: PathBuf,
    root_identity: Identity,
}
impl FileReferenceScope {
    pub fn directory(&self) -> &Path {
        &self.root
    }
    pub fn search(self: &Arc<Self>, query: &str) -> Result<FileReferenceList> {
        self.search_with(query, crate::workspace::composer_paths)
    }
    fn search_with(
        self: &Arc<Self>,
        query: &str,
        list: impl FnOnce(&Path, &str, usize) -> Result<Value>,
    ) -> Result<FileReferenceList> {
        ensure!(
            query.len() <= 256 && !query.chars().any(char::is_control),
            "Search must be at most 256 bytes without control characters"
        );
        ensure!(
            identity(&std::fs::metadata(&self.root)?)? == self.root_identity,
            "Project directory changed; search again"
        );
        let result = list(&self.root, query, LIMIT)?;
        let paths = result["files"]
            .as_array()
            .context("File listing is unavailable")?;
        ensure!(paths.len() <= LIMIT, "File listing exceeds its bound");
        let total = usize::try_from(
            result["total"]
                .as_u64()
                .context("Invalid file listing count")?,
        )?;
        ensure!(total >= paths.len(), "Invalid file listing count");
        let mut files = Vec::new();
        let mut skipped = 0;
        let mut seen = HashSet::new();
        for value in paths {
            let path = value.as_str().context("Invalid file listing path")?;
            if !seen.insert(path.to_owned()) {
                continue;
            }
            match path_identity(&self.root, path) {
                Ok((metadata, directory)) => files.push(FileReference {
                    scope: self.clone(),
                    path: path.into(),
                    identity: metadata,
                    directory,
                }),
                Err(_) => skipped += 1,
            }
        }
        Ok(FileReferenceList {
            directory: self
                .root
                .to_str()
                .context("Project directory is not UTF-8")?
                .to_owned(),
            files,
            total,
            truncated: result["truncated"] == true,
            skipped,
        })
    }
}
#[derive(Clone)]
pub struct FileReference {
    scope: Arc<FileReferenceScope>,
    path: String,
    identity: Identity,
    directory: bool,
}
impl FileReference {
    pub fn path(&self) -> &str {
        &self.path
    }
    pub fn is_directory(&self) -> bool {
        self.directory
    }
}
pub struct FileReferenceList {
    pub directory: String,
    pub files: Vec<FileReference>,
    pub total: usize,
    pub truncated: bool,
    pub skipped: usize,
}
pub struct AttachedFileReference {
    pub thread: String,
    pub context: Value,
    pub changed: bool,
}
impl Engine {
    pub fn prepare_file_reference_scope(
        &self,
        thread: &str,
        draft: &str,
        expected: &ExpectedContext,
    ) -> Result<Arc<FileReferenceScope>> {
        self.require_admissions()?;
        ensure!(
            self.active_thread() == Some(thread),
            "Selected conversation changed"
        );
        ensure!(
            !self.unsaved_threads.contains_key(thread),
            "Transcript persistence is recovering"
        );
        ensure!(
            !self.store.is_imported(thread)?,
            "Fork an imported conversation before attaching references"
        );
        let source = self.store.file_reference_scope_source(thread)?;
        ensure!(
            source.len() <= MAX_ROW,
            "File-reference context exceeds its size limit"
        );
        let value: Value = serde_json::from_str(&source)?;
        ensure!(
            value["id"].as_str() == Some(thread),
            "Stored conversation identity changed"
        );
        ensure!(
            value["draft"].as_str() == Some(draft) && expected.matches(&value),
            "Draft or attached context changed; search again"
        );
        composer_context::validate(value.get("draftContext").unwrap_or(&Value::Null))?;
        let directory = self.working_directory(&value)?;
        ensure!(
            directory.is_absolute(),
            "Choose an absolute project working directory"
        );
        let root = directory
            .canonicalize()
            .context("Project directory is unavailable")?;
        ensure!(
            root.to_str().is_some_and(|p| p.len() <= 4096),
            "Project directory name exceeds its bounds"
        );
        let metadata = std::fs::metadata(&root)?;
        ensure!(metadata.is_dir(), "Project directory is unavailable");
        let projects = self.store.projects()?;
        ensure!(
            serde_json::to_vec(&projects)?.len() <= 1024 * 1024,
            "Project catalog exceeds the 1 MiB file-picker limit"
        );
        Ok(Arc::new(FileReferenceScope {
            owner: self.composer_file_owner,
            thread: thread.into(),
            source: Arc::new(source),
            projects: Arc::new(projects),
            root,
            root_identity: identity(&metadata)?,
        }))
    }
    /// Validate a folder completion with the same private source/metadata proof
    /// as a file attachment. This grants no content read and writes no Store row.
    pub fn validate_file_reference_folder(&self, file: &FileReference) -> Result<()> {
        ensure!(file.directory, "Choose a project folder");
        self.validate_file_reference(file)?;
        Ok(())
    }
    /// Recheck Store/owner state at the native text-edit admission point. The
    /// owned background job already checked folder metadata; this read does not
    /// traverse the filesystem on the UI thread.
    pub fn validate_file_reference_folder_delivery(&self, file: &FileReference) -> Result<()> {
        let scope = &file.scope;
        self.require_admissions()?;
        ensure!(
            file.directory
                && scope.owner == self.composer_file_owner
                && self.active_thread() == Some(scope.thread.as_str())
                && !self.unsaved_threads.contains_key(&scope.thread)
                && !self.store.is_imported(&scope.thread)?,
            "Selected conversation changed; search again"
        );
        ensure!(
            self.store.file_reference_scope_source(&scope.thread)? == *scope.source
                && self.store.projects()? == *scope.projects,
            "Conversation or project changed; search again"
        );
        Ok(())
    }
    fn validate_file_reference(&self, file: &FileReference) -> Result<Value> {
        self.require_admissions()?;
        let scope = &file.scope;
        ensure!(
            scope.owner == self.composer_file_owner,
            "Conversation changed; search again"
        );
        ensure!(
            self.active_thread() == Some(scope.thread.as_str()),
            "Selected conversation changed; search again"
        );
        ensure!(
            !self.unsaved_threads.contains_key(&scope.thread),
            "Transcript persistence is recovering"
        );
        ensure!(
            !self.store.is_imported(&scope.thread)?,
            "Fork an imported conversation before attaching references"
        );
        let value: Value = serde_json::from_str(&scope.source)?;
        ensure!(
            self.working_directory(&value)?.canonicalize()? == scope.root
                && identity(&std::fs::metadata(&scope.root)?)? == scope.root_identity,
            "Project directory changed; search again"
        );
        ensure!(
            path_identity(&scope.root, &file.path)? == (file.identity.clone(), file.directory),
            "Project file metadata changed; search again"
        );
        ensure!(
            self.store.file_reference_scope_source(&scope.thread)? == *scope.source
                && self.store.projects()? == *scope.projects,
            "Conversation or project changed; search again"
        );
        Ok(value)
    }
    pub fn attach_file_reference(&mut self, file: &FileReference) -> Result<AttachedFileReference> {
        ensure!(
            !file.directory,
            "Open the folder to choose a file; folders are not attached"
        );
        let value = self.validate_file_reference(file)?;
        let scope = &file.scope;
        let context = composer_context::append_file_reference(
            value.get("draftContext").unwrap_or(&Value::Null),
            &file.path,
            scope
                .root
                .to_str()
                .context("Project directory is not UTF-8")?,
        )?;
        let changed = self.store.commit_file_reference(
            &scope.thread,
            &scope.source,
            &scope.projects,
            &context,
        )?;
        if changed {
            self.revision += 1;
        }
        Ok(AttachedFileReference {
            thread: scope.thread.clone(),
            context,
            changed,
        })
    }
}
#[cfg(test)]
#[path = "composer_file_reference_tests.rs"]
mod tests;
