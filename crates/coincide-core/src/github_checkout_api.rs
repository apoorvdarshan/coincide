//! Native source capture and exact revalidation only. No JSON checkout method.
use super::*;
use crate::github_checkout::{Source, validate_head, validate_repository};
impl Engine {
    pub fn native_github_checkout_source(
        &mut self,
        thread_id: &str,
        expected_root: &std::path::Path,
        repository: &str,
        number: u64,
        head: &str,
    ) -> Result<Source> {
        self.require_background_admission()?;
        validate_repository(repository)?;
        validate_head(head)?;
        ensure!(number > 0, "Positive PR number required");
        ensure!(
            !self.store.is_imported(thread_id)?
                && !self.runs.contains_key(thread_id)
                && !self.unsaved_threads.contains_key(thread_id),
            "Checkout source must be an idle writable conversation"
        );
        ensure!(
            self.workspace_pending.is_empty() && self.workspace_mutations.is_empty(),
            "Wait for existing workspace operations before checkout"
        );
        let thread = self.store.thread(thread_id)?;
        ensure!(thread["isArchived"] != true, "Checkout source is archived");
        let project_id = thread["projectID"]
            .as_str()
            .context("Checkout requires an existing project")?;
        let projects = self.store.projects()?;
        let project = projects
            .as_array()
            .context("Invalid stored projects")?
            .iter()
            .find(|project| project["id"] == project_id)
            .context("Checkout project no longer exists")?
            .clone();
        let root = self.working_directory(&thread)?.canonicalize()?;
        ensure!(
            expected_root.is_absolute() && expected_root.canonicalize()? == root,
            "Checkout source directory changed"
        );
        Ok(Source {
            store: agent::native_instruction_git::StoreSource::capture(&self.store)?,
            thread,
            project,
            root,
            storage: self.store.data_directory()?.canonicalize()?,
            repository: repository.into(),
            number,
            head: head.to_ascii_lowercase(),
        })
    }
    /// Recheck immediately before any future ref/thread admission, AFTER actual
    /// worker/descendant return. This alone never creates or modifies a thread.
    pub fn native_validate_github_checkout_source(&mut self, source: &Source) -> Result<()> {
        source.store.validate(&self.store)?;
        let id = source.thread["id"]
            .as_str()
            .context("Checkout source has no ID")?;
        let current = self.native_github_checkout_source(
            id,
            &source.root,
            &source.repository,
            source.number,
            &source.head,
        )?;
        ensure!(
            current.thread == source.thread
                && current.project == source.project
                && current.root == source.root
                && current.storage == source.storage,
            "Checkout source changed; review it again"
        );
        Ok(())
    }
}
