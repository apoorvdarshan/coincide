//! Native PR checkout capture and new-thread admission only. No JSON method:
//! the fetch, branch and worktree run between these calls, off the Engine lock.
use super::*;
use crate::github_checkout::{
    Checkout, DEFAULT_PREFIX, SETUP, Source, validate_head, validate_repository,
};
impl Engine {
    /// Swift PullRequestsViewController.checkOut: the shown conversation's
    /// project, whatever that conversation is doing; it is never changed.
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
        let thread = self.store.thread(thread_id)?;
        let project_id = thread["projectID"]
            .as_str()
            .filter(|id| {
                Uuid::parse_str(id).is_ok_and(|id| !id.is_nil())
                    && !id.eq_ignore_ascii_case(crate::bot_runtime::BOTS_PROJECT_ID)
            })
            .context("Checkout requires an existing project")?
            .to_owned();
        let project = self.checkout_project(&project_id)?;
        let root = self.working_directory(&thread)?.canonicalize()?;
        ensure!(
            expected_root.is_absolute() && expected_root.canonicalize()? == root,
            "Checkout source directory changed"
        );
        let gh = self.github_cli_path().map_err(|_| anyhow::anyhow!(SETUP))?;
        let prefix = self
            .store
            .document("settings.json")?
            .and_then(|settings| settings["worktreeBranchPrefix"].as_str().map(str::to_owned))
            .unwrap_or_else(|| DEFAULT_PREFIX.into());
        Ok(Source {
            store: agent::native_instruction_git::StoreSource::capture(&self.store)?,
            project_id,
            project_path: project["path"].clone(),
            root,
            storage: self.store.data_directory()?.canonicalize()?,
            repository: repository.into(),
            number,
            head: head.to_ascii_lowercase(),
            gh,
            prefix,
            _activity: Some(Box::new(self.idle_sleep.background_job())),
        })
    }
    fn checkout_project(&self, project_id: &str) -> Result<Value> {
        let projects = self.store.projects()?;
        projects
            .as_array()
            .context("Invalid stored projects")?
            .iter()
            .find(|project| {
                project["id"]
                    .as_str()
                    .is_some_and(|id| id.eq_ignore_ascii_case(project_id))
                    && project["isBots"] != true
            })
            .cloned()
            .context("Checkout project no longer exists")
    }
    /// Swift ThreadActions.newThread(in:worktreePath:branch:): an untouched
    /// conversation already in that worktree is reused, otherwise one is made;
    /// either runs in the worktree on the branch and its project is expanded.
    pub fn native_open_github_checkout(
        &mut self,
        source: &Source,
        checkout: &Checkout,
    ) -> Result<Value> {
        self.require_admissions()?;
        source.store.validate(&self.store)?;
        let project = self.checkout_project(&source.project_id)?;
        ensure!(
            project["path"] == source.project_path,
            "Checkout project moved; check the pull request out again"
        );
        ensure!(
            checkout.path.is_absolute() && checkout.path.is_dir(),
            "The checked-out worktree no longer exists"
        );
        let cwd = checkout
            .path
            .to_str()
            .context("Worktree path is not UTF-8")?;
        let intent =
            self.prepare_native_new_thread(&json!({"projectId":source.project_id,"cwd":cwd}))?;
        let mut thread = self.apply_native_new_thread(intent)?;
        if thread["branch"] != checkout.branch.as_str() {
            thread["branch"] = json!(checkout.branch);
            self.store.save(&thread)?;
            self.revision += 1;
        }
        if project["isExpanded"] == false {
            let id = text(&project, "id");
            self.store.patch_project(&id, &json!({"isExpanded":true}))?;
            self.revision += 1;
        }
        Ok(thread)
    }
}
#[cfg(test)]
impl Engine {
    /// The read service's executable, as COINCIDE_RUST_GH would configure it.
    pub(crate) fn use_github_cli_for_checkout_tests(&mut self, path: &std::path::Path) {
        self.github = github_engine::GithubState::configured(Some(path.as_os_str()), None);
    }
}
