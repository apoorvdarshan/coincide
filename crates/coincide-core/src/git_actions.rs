//! User-initiated Git actions behind the commit / push / pull request bar and the
//! branch toolbar under the composer (Swift GitService, GitOps, GitActions,
//! BranchNames, SourceControlHost and GitHubCLI). Unlike `workspace`'s inspection
//! primitives these run the user's own git, with its hooks, credential helpers and
//! remotes, as Swift and Terminal do. Only fixed argument shapes run; names are
//! validated by git first. Commit messages and pull request text the user leaves
//! blank use Swift's plain fallbacks: no agent writes them here yet.
#[path = "git_actions_cli.rs"]
mod cli;
#[path = "git_actions_host.rs"]
pub mod host;
#[path = "git_actions_names.rs"]
pub mod names;
#[path = "git_actions_ops.rs"]
pub mod ops;
#[cfg(test)]
#[path = "git_actions_tests.rs"]
mod tests;

pub use cli::GitError;
use host::{Host, Term};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FileStatus {
    Added,
    Modified,
    Deleted,
    Renamed,
    Untracked,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangedFile {
    pub path: String,
    pub old_path: Option<String>,
    pub status: FileStatus,
    pub additions: u64,
    pub deletions: u64,
}

/// Working tree state as `git status --porcelain=2` reports it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitStatus {
    pub is_repository: bool,
    pub root_path: Option<String>,
    /// None while HEAD is detached.
    pub branch: Option<String>,
    pub head_oid: Option<String>,
    /// Such as `origin/main`.
    pub upstream: Option<String>,
    pub ahead: u64,
    pub behind: u64,
    /// Commits on this branch that its base branch does not have.
    pub ahead_of_default: u64,
    pub default_branch: Option<String>,
    pub is_default_branch: bool,
    pub has_remote: bool,
    pub files: Vec<ChangedFile>,
    pub conflicted_paths: Vec<String>,
}

impl GitStatus {
    pub fn not_repository() -> Self {
        Self::default()
    }
    pub fn has_changes(&self) -> bool {
        !self.files.is_empty()
    }
    pub fn has_upstream(&self) -> bool {
        self.upstream.is_some()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitBranch {
    /// `main` for a local branch, `origin/main` for a remote-tracking one.
    pub name: String,
    pub is_remote: bool,
    pub remote_name: Option<String>,
    pub is_current: bool,
    pub is_default: bool,
    pub upstream: Option<String>,
    /// Work tree that has this branch checked out.
    pub worktree_path: Option<String>,
    pub last_commit_date: Option<i64>,
}

impl GitBranch {
    /// The local branch name a checkout of this branch creates or uses.
    pub fn local_name(&self) -> String {
        if !self.is_remote {
            return self.name.clone();
        }
        if let Some(remote) = &self.remote_name
            && let Some(rest) = self.name.strip_prefix(&format!("{remote}/"))
        {
            return rest.into();
        }
        names::local_name_from_remote_ref(&self.name)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitBranchList {
    pub is_repository: bool,
    /// Current branch first, then the default branch, then by most recent commit.
    pub branches: Vec<GitBranch>,
    pub current_branch: Option<String>,
    pub default_branch: Option<String>,
    pub has_remote: bool,
}

impl GitBranchList {
    pub fn local(&self) -> impl Iterator<Item = &GitBranch> {
        self.branches.iter().filter(|branch| !branch.is_remote)
    }
    pub fn remote(&self) -> impl Iterator<Item = &GitBranch> {
        self.branches.iter().filter(|branch| branch.is_remote)
    }
    /// The base a new worktree starts from by default: the repository's default
    /// branch, else the checked-out branch.
    pub fn default_base(&self) -> Option<String> {
        if let Some(name) = &self.default_branch {
            if self.local().any(|branch| &branch.name == name) {
                return Some(name.clone());
            }
            if let Some(remote) = self.remote().find(|branch| branch.is_default) {
                return Some(remote.name.clone());
            }
        }
        self.current_branch.clone()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitWorktree {
    pub path: String,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub is_main: bool,
    pub is_prunable: bool,
    pub is_locked: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommit {
    pub sha: String,
    pub subject: String,
}

impl GitCommit {
    pub fn short_sha(&self) -> String {
        self.sha.chars().take(7).collect()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PushOutcome {
    Pushed,
    UpToDate,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPushResult {
    pub outcome: PushOutcome,
    pub branch: String,
    /// Where the branch was pushed, such as `origin/feature`.
    pub upstream: Option<String>,
    pub set_upstream: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PullResult {
    Pulled,
    UpToDate,
}

/// A pull request as `gh pr list/view --json` reports it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPullRequest {
    pub number: u64,
    pub url: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub state: String,
    #[serde(default, rename = "baseRefName")]
    pub base_branch: String,
    #[serde(default, rename = "headRefName")]
    pub head_branch: String,
    #[serde(default)]
    pub is_draft: bool,
}

/// A commit / push / pull request sequence, run as one action.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StackedAction {
    Commit,
    CommitPush,
    CommitPushPr,
    Push,
    CreatePr,
}

impl StackedAction {
    pub fn includes_commit(self) -> bool {
        matches!(self, Self::Commit | Self::CommitPush | Self::CommitPushPr)
    }
    /// The title in the host's words: "Create MR" for GitLab.
    pub fn title(self, term: Term) -> &'static str {
        match (self, term) {
            (Self::Commit, _) => "Commit",
            (Self::CommitPush, _) => "Commit & Push",
            (Self::CommitPushPr, Term::PullRequest) => "Commit, Push & Create PR",
            (Self::CommitPushPr, Term::MergeRequest) => "Commit, Push & Create MR",
            (Self::Push, _) => "Push",
            (Self::CreatePr, Term::PullRequest) => "Create PR",
            (Self::CreatePr, Term::MergeRequest) => "Create MR",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
pub enum QuickKind {
    Run(StackedAction),
    Pull,
    /// Nothing to do; the text explains why.
    Hint(String),
}

/// What the git action button offers for a status (T3 Code's quick action rules).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuickAction {
    pub title: String,
    pub kind: QuickKind,
    pub is_enabled: bool,
}

impl QuickAction {
    fn hint(title: &str, hint: &str) -> Self {
        Self {
            title: title.into(),
            kind: QuickKind::Hint(hint.into()),
            is_enabled: false,
        }
    }

    pub fn resolve(status: Option<&GitStatus>, busy: bool, has_open_pr: bool, term: Term) -> Self {
        const COMMIT: &str = "Commit";
        if busy {
            return Self::hint(COMMIT, "A Git action is running.");
        }
        let Some(status) = status.filter(|status| status.is_repository) else {
            return Self::hint(COMMIT, "Git status is unavailable.");
        };
        if status.branch.is_none() {
            return Self::hint(
                COMMIT,
                match term {
                    Term::MergeRequest => {
                        "Check out a branch before pushing or opening a merge request."
                    }
                    Term::PullRequest => {
                        "Check out a branch before pushing or opening a pull request."
                    }
                },
            );
        }
        let push_and_create = match term {
            Term::MergeRequest => "Push & Create MR",
            Term::PullRequest => "Push & Create PR",
        };
        let run = |action: StackedAction, title: Option<&str>| Self {
            title: title.unwrap_or(action.title(term)).into(),
            kind: QuickKind::Run(action),
            is_enabled: true,
        };
        let ahead = status.ahead > 0;
        let behind = status.behind > 0;
        let default = status.is_default_branch;
        let up_to_date = Self::hint(COMMIT, "The branch is up to date. Nothing to do.");
        let push_or_create = || {
            if has_open_pr || default {
                run(StackedAction::Push, None)
            } else {
                run(StackedAction::CreatePr, Some(push_and_create))
            }
        };
        if status.has_changes() {
            if !status.has_upstream() && !status.has_remote {
                return run(StackedAction::Commit, None);
            }
            return run(
                if has_open_pr || default {
                    StackedAction::CommitPush
                } else {
                    StackedAction::CommitPushPr
                },
                None,
            );
        }
        if !status.has_upstream() {
            if !status.has_remote {
                return Self::hint(COMMIT, "Add a remote to push this repository.");
            }
            if !ahead {
                return if has_open_pr {
                    up_to_date
                } else {
                    Self::hint("Push", "No local commits to push.")
                };
            }
            return push_or_create();
        }
        if ahead && behind {
            return Self::hint(
                "Sync Branch",
                "The branch has diverged from its upstream. Rebase or merge first.",
            );
        }
        if behind {
            return Self {
                title: "Pull".into(),
                kind: QuickKind::Pull,
                is_enabled: true,
            };
        }
        if ahead {
            return push_or_create();
        }
        if has_open_pr {
            return up_to_date;
        }
        if status.ahead_of_default > 0 && !default {
            return run(StackedAction::CreatePr, None);
        }
        up_to_date
    }

    /// Pushing to (or opening a pull request from) the default branch asks first.
    pub fn requires_default_branch_confirmation(action: StackedAction, is_default: bool) -> bool {
        is_default && action != StackedAction::Commit
    }
}

/// Which of Commit / Push / Create PR the actions menu enables.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Availability {
    pub can_commit: bool,
    pub can_push: bool,
    pub can_create_pr: bool,
    /// False when the repository has no remote: only Commit applies.
    pub shows_remote_actions: bool,
}

impl Availability {
    pub fn resolve(status: Option<&GitStatus>, busy: bool, has_open_pr: bool) -> Self {
        let Some(status) = status.filter(|status| status.is_repository) else {
            return Self::default();
        };
        let has_branch = status.branch.is_some();
        let behind = status.behind > 0;
        let can_publish = status.has_remote && !status.has_upstream();
        let ahead_of_base = status.ahead_of_default > 0 || status.ahead > 0;
        Self {
            can_commit: !busy && status.has_changes(),
            can_push: !busy
                && has_branch
                && !behind
                && status.ahead > 0
                && (status.has_upstream() || can_publish),
            can_create_pr: !busy
                && has_branch
                && !has_open_pr
                && ahead_of_base
                && !behind
                && (status.has_upstream() || can_publish),
            shows_remote_actions: status.has_remote,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionRequest {
    pub action: Option<StackedAction>,
    /// Blank to use the plain message built from the changed files.
    pub commit_message: Option<String>,
    /// Repository-relative files to commit; None for every change.
    pub file_paths: Option<Vec<String>>,
    /// Create a feature branch (named after the change) before committing.
    pub feature_branch: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
pub enum FollowUp {
    Run(StackedAction),
    OpenPullRequest(String),
    /// The host's page for opening the pull request, since no signed-in CLI could.
    OpenChangeRequestPage(String),
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionResult {
    pub created_branch: Option<String>,
    pub commit: Option<GitCommit>,
    pub push: Option<GitPushResult>,
    pub pull_request: Option<GitPullRequest>,
    pub pull_request_created: bool,
    /// One-line summary, such as "Pushed 1a2b3c4 to origin/feature".
    pub title: String,
    pub detail: Option<String>,
    pub follow_up: Option<FollowUp>,
    /// The host's name, when the action pushed or opened a pull request.
    pub host_name: Option<String>,
    pub change_request_term: Term,
}

enum PullRequestStep {
    Existing(GitPullRequest),
    Created(GitPullRequest),
    Page(String),
}

/// Runs a stacked action: optional feature branch, commit, push and pull request, in
/// order. `progress` receives a short label for each step.
pub fn run(
    request: &ActionRequest,
    cwd: &Path,
    progress: &dyn Fn(&str),
) -> anyhow::Result<ActionResult> {
    let action = request.action.unwrap_or(StackedAction::Commit);
    let initial = ops::status(cwd)?;
    if !initial.is_repository {
        return cli::fail("This folder is not a Git repository.");
    }
    let wants_commit = action.includes_commit();
    let wants_push = matches!(
        action,
        StackedAction::Push | StackedAction::CommitPush | StackedAction::CommitPushPr
    ) || (action == StackedAction::CreatePr
        && (!initial.has_upstream() || initial.ahead > 0));
    let wants_pr = matches!(
        action,
        StackedAction::CreatePr | StackedAction::CommitPushPr
    );
    if request.feature_branch && !wants_commit {
        return cli::fail("A feature branch can only be created when committing.");
    }
    if !request.feature_branch && (wants_push || wants_pr) && initial.branch.is_none() {
        return cli::fail("Cannot push from a detached HEAD.");
    }
    let paths = request.file_paths.as_deref();
    let custom = names::custom_commit_message(request.commit_message.as_deref());

    let mut message = None;
    let mut created_branch = None;
    if request.feature_branch {
        progress("Preparing feature branch…");
        let Some(summary) = ops::commit_summary(paths, cwd)? else {
            return cli::fail(
                "There are no changes to commit, so a feature branch can't be named.",
            );
        };
        let suggestion = custom
            .clone()
            .unwrap_or_else(|| names::fallback_commit_message(&summary));
        let existing: Vec<String> = ops::branches(cwd)
            .map(|list| list.local().map(|branch| branch.name.clone()).collect())
            .unwrap_or_default();
        let name = names::available_feature_branch_name(
            suggestion.branch.as_deref().unwrap_or(&suggestion.subject),
            &existing,
        );
        created_branch = Some(ops::create_branch(&name, cwd, true)?);
        message = Some(suggestion);
    }
    let branch = created_branch.clone().or_else(|| initial.branch.clone());

    let mut commit = None;
    if wants_commit {
        if message.is_none() {
            if custom.is_none() {
                progress("Generating commit message…");
            }
            if let Some(summary) = ops::commit_summary(paths, cwd)? {
                message = Some(custom.unwrap_or_else(|| names::fallback_commit_message(&summary)));
            }
        }
        match &message {
            Some(message) => {
                progress("Committing…");
                commit = Some(ops::commit(&message.subject, &message.body, paths, cwd)?);
            }
            None if action == StackedAction::Commit => {
                return cli::fail("There are no changes to commit.");
            }
            None => {}
        }
    }

    let mut push = None;
    if wants_push {
        progress("Pushing…");
        push = Some(ops::push(cwd, branch.as_deref())?);
        ops::forget_pull_requests();
    }

    // The host names the pull request step's words ("merge request" on GitLab).
    let host = if wants_push || wants_pr {
        branch
            .as_deref()
            .and_then(|branch| ops::remote_host(cwd, Some(branch)))
    } else {
        None
    };
    let term = host
        .as_ref()
        .map_or(Term::PullRequest, |host| host.kind.change_request());

    let mut pull_request = None;
    let mut created = false;
    let mut page = None;
    if wants_pr {
        progress(match term {
            Term::MergeRequest => "Preparing merge request…",
            Term::PullRequest => "Preparing pull request…",
        });
        match pull_request_step(cwd, branch.as_deref(), host.as_ref(), term, progress)? {
            PullRequestStep::Existing(found) => pull_request = Some(found),
            PullRequestStep::Created(new) => {
                pull_request = Some(new);
                created = true;
            }
            PullRequestStep::Page(url) => page = Some(url),
        }
    }

    let mut result = ActionResult {
        created_branch,
        commit,
        push,
        pull_request,
        pull_request_created: created,
        host_name: host.as_ref().map(Host::display_name),
        change_request_term: term,
        ..ActionResult::default()
    };
    summarize(&mut result, action, page, cwd);
    Ok(result)
}

/// Finds or creates the branch's pull request with gh. Without it signed in, GitHub
/// (and hosts Coincide can't name) still need gh; other hosts give their page for
/// creating one, as they link to it after a push.
fn pull_request_step(
    cwd: &Path,
    fallback_branch: Option<&str>,
    host: Option<&Host>,
    term: Term,
    progress: &dyn Fn(&str),
) -> anyhow::Result<PullRequestStep> {
    let status = ops::status(cwd)?;
    let Some(branch) = status
        .branch
        .clone()
        .or_else(|| fallback_branch.map(str::to_owned))
    else {
        return cli::fail(match term {
            Term::MergeRequest => "Cannot create a merge request from a detached HEAD.",
            Term::PullRequest => "Cannot create a pull request from a detached HEAD.",
        });
    };
    if !status.has_upstream() {
        return cli::fail(match term {
            Term::MergeRequest => {
                "This branch has not been pushed. Push it before creating a merge request."
            }
            Term::PullRequest => {
                "This branch has not been pushed. Push it before creating a pull request."
            }
        });
    }
    let gh_ready = ops::uses_gh(host) && ops::is_gh_ready(cwd);
    if !gh_ready {
        let Some(host) = host.filter(|host| !ops::uses_gh(Some(host))) else {
            return cli::fail(ops::GH_NOT_READY);
        };
        let base = ops::pull_request_base(cwd, &branch, status.upstream.as_deref(), false);
        if let Some(page) = host
            .new_change_request_url(&base, &branch)
            .or_else(|| host.repository_url())
        {
            return Ok(PullRequestStep::Page(page));
        }
        return cli::fail(format!(
            "Coincide can't find this repository’s page on {}.",
            host.display_name()
        ));
    }
    if let Some(existing) = ops::open_pull_request(&branch, cwd, true) {
        return Ok(PullRequestStep::Existing(existing));
    }
    let base = ops::pull_request_base(cwd, &branch, status.upstream.as_deref(), true);
    let remotes = ops::remote_names(cwd);
    let mut range_base = base.clone();
    if let Some(remote) = ops::primary_remote(&remotes) {
        let candidate = format!("{remote}/{base}");
        if cli::git(
            cwd,
            &[
                "show-ref",
                "--verify",
                "--quiet",
                &format!("refs/remotes/{candidate}"),
            ],
            cli::SHORT,
        )
        .success
        {
            range_base = candidate;
        }
    }
    progress("Writing pull request…");
    let content = names::fallback_pull_request(&branch, &ops::range_commits(cwd, &range_base));
    progress("Creating pull request…");
    let created = ops::create_pull_request(&content.title, &content.body, &base, &branch, cwd)?;
    Ok(PullRequestStep::Created(created))
}

fn summarize(result: &mut ActionResult, action: StackedAction, page: Option<String>, cwd: &Path) {
    let term = result.change_request_term;
    let pushed = result
        .push
        .as_ref()
        .filter(|push| push.outcome == PushOutcome::Pushed)
        .map(|push| {
            let target = push.upstream.clone().unwrap_or_else(|| push.branch.clone());
            match &result.commit {
                Some(commit) => format!("Pushed {} to {target}", commit.short_sha()),
                None => format!("Pushed to {target}"),
            }
        });
    if let Some(pull_request) = &result.pull_request {
        result.title = match (term, result.pull_request_created) {
            (Term::PullRequest, true) => format!("Created PR #{}", pull_request.number),
            (Term::PullRequest, false) => format!("Opened PR #{}", pull_request.number),
            (Term::MergeRequest, true) => format!("Created MR !{}", pull_request.number),
            (Term::MergeRequest, false) => format!("Opened MR !{}", pull_request.number),
        };
        result.detail = Some(pull_request.title.clone());
    } else if let Some(page) = page {
        let name = result.host_name.clone().unwrap_or_default();
        result.title = match term {
            Term::MergeRequest => format!("Create the merge request on {name}"),
            Term::PullRequest => format!("Create the pull request on {name}"),
        };
        result.detail = pushed;
        result.follow_up = Some(FollowUp::OpenChangeRequestPage(page));
        return;
    } else if let Some(pushed) = &pushed {
        result.title = pushed.clone();
        result.detail = result.commit.as_ref().map(|commit| commit.subject.clone());
    } else if let Some(commit) = &result.commit {
        result.title = format!("Committed {}", commit.short_sha());
        result.detail = Some(commit.subject.clone());
    } else if result
        .push
        .as_ref()
        .is_some_and(|push| push.outcome == PushOutcome::UpToDate)
    {
        result.title = "Already up to date".into();
    } else {
        result.title = "Done".into();
    }

    if action == StackedAction::Commit && result.commit.is_some() {
        result.follow_up = Some(FollowUp::Run(StackedAction::Push));
        return;
    }
    let status = ops::status(cwd).ok();
    let is_default = status
        .as_ref()
        .is_some_and(|status| status.is_default_branch);
    let did_push = result
        .push
        .as_ref()
        .is_some_and(|push| push.outcome == PushOutcome::Pushed);
    let pushes = matches!(action, StackedAction::Push | StackedAction::CommitPush);
    let mut open = result.pull_request.clone();
    if open.is_none()
        && pushes
        && did_push
        && result.created_branch.is_none()
        && !is_default
        && let Some(branch) = status.as_ref().and_then(|status| status.branch.as_deref())
    {
        open = ops::open_pull_request(branch, cwd, true);
    }
    if let Some(open) = open.filter(|open| !open.url.is_empty())
        && (!is_default || result.pull_request.is_some())
    {
        result.follow_up = Some(FollowUp::OpenPullRequest(open.url));
    } else if pushes && did_push && !is_default {
        result.follow_up = Some(FollowUp::Run(StackedAction::CreatePr));
    }
}
