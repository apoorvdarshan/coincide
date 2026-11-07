//! Engine routes for the git action bar and the branch toolbar. Work runs on
//! background workers; `git.actions.result` collects it with the step it is on.
//! The folder is always the stored thread's, never a caller-supplied path. Thread
//! records change only here, on the engine, after a worker reports: the branch a
//! checkout or commit left, and where a thread that has not started runs (Swift
//! WorktreeService, kept for this engine's lifetime as Swift keeps it per launch).
use super::*;
use crate::git_actions::{self as git, ActionRequest, GitError, ops};
use std::path::Path;

pub(super) const METHODS: &[&str] = &[
    "git.actions.status",
    "git.actions.pullRequest",
    "git.actions.run",
    "git.actions.pull",
    "git.branches.list",
    "git.branches.checkout",
    "git.branches.create",
    "git.toolbar.state",
    "git.worktrees.useCheckout",
    "git.worktrees.useNew",
    "git.worktrees.useExisting",
    "git.actions.result",
];

/// A push can wait on hooks and the network for minutes.
const OPERATION_LIFETIME: Duration = Duration::from_secs(45 * 60);
const RESULT_LIFETIME: Duration = Duration::from_secs(10 * 60);
const MAX_PENDING: usize = 64;

#[cfg(test)]
#[path = "git_actions_api_tests.rs"]
mod tests;

#[derive(Clone)]
enum Completion {
    None,
    /// A thread that has not started follows the branch its folder is on.
    FollowBranch(PathBuf),
    /// A checkout, new branch or feature branch moved the thread's branch.
    Branch,
    /// A new worktree for a thread with no messages.
    NewWorktree,
    /// An existing worktree of the project, checked on the worker.
    ExistingWorktree(Option<String>),
    /// A temporary worktree branch was renamed after the first message.
    Renamed {
        path: String,
        branch: String,
    },
}

struct Pending {
    thread: String,
    started: Instant,
    progress: Arc<Mutex<String>>,
    completion: Completion,
    mutation: bool,
}

#[derive(Clone)]
struct Unused {
    path: String,
    branch: Option<String>,
}

pub(super) struct State {
    pending: HashMap<String, Pending>,
    results: HashMap<String, (Instant, Value)>,
    tx: std::sync::mpsc::SyncSender<(String, Value)>,
    rx: std::sync::mpsc::Receiver<(String, Value)>,
    /// Threads with a git mutation running; one at a time per thread.
    mutating: HashSet<String>,
    preparing: HashSet<String>,
    /// Worktrees made for threads that have not sent a message yet.
    unused: HashMap<String, Unused>,
    /// The branch each new worktree started from, by thread.
    bases: HashMap<String, String>,
    /// Threads moved into a worktree here, watched for their first message.
    watched: HashSet<String>,
    last_watch: Instant,
}

impl Default for State {
    fn default() -> Self {
        let (tx, rx) = std::sync::mpsc::sync_channel(MAX_PENDING);
        Self {
            pending: HashMap::new(),
            results: HashMap::new(),
            tx,
            rx,
            mutating: HashSet::new(),
            preparing: HashSet::new(),
            unused: HashMap::new(),
            bases: HashMap::new(),
            watched: HashSet::new(),
            last_watch: Instant::now(),
        }
    }
}

fn error_value(error: &anyhow::Error) -> Value {
    match error.downcast_ref::<GitError>() {
        Some(git) => json!({"error":git.message,"detail":git.detail}),
        None => json!({"error":error.to_string()}),
    }
}

fn git_fail(message: &str) -> Result<Value> {
    Err(GitError::new(message).into())
}

fn has_user_messages(thread: &Value) -> bool {
    thread["items"]
        .as_array()
        .is_some_and(|items| items.iter().any(|item| item["kind"] == "user"))
}

fn name(p: &Value, key: &str) -> Result<String> {
    let value = required(p, key)?;
    ensure!(
        !value.is_empty() && value.len() <= 255 && !value.chars().any(char::is_control),
        "Invalid {key}"
    );
    Ok(value.to_owned())
}

impl Engine {
    fn worktree_prefix(&self) -> String {
        self.store
            .document("settings.json")
            .ok()
            .flatten()
            .and_then(|settings| settings["worktreeBranchPrefix"].as_str().map(str::to_owned))
            .unwrap_or_else(|| "coincide/".into())
    }

    fn project_folder(&self, thread: &Value) -> Result<PathBuf> {
        let projects = self.store.projects()?;
        projects
            .as_array()
            .and_then(|projects| {
                projects
                    .iter()
                    .find(|project| project["id"] == thread["projectID"])
                    .and_then(|project| project["path"].as_str())
                    .map(PathBuf::from)
            })
            .context("Choose a project working directory first")
    }

    /// Whether a thread other than `besides` runs in `path`.
    fn worktree_in_use(&self, path: &str, besides: Option<&str>) -> bool {
        self.store.worktree_threads().is_ok_and(|threads| {
            threads
                .iter()
                .any(|thread| Some(thread.id.as_str()) != besides && thread.path == path)
        })
    }

    /// Changes a thread record after a git step. Imported and recovering threads keep
    /// their record; their folder already changed.
    fn update_git_thread(&mut self, id: &str, update: impl FnOnce(&mut Value)) -> bool {
        if self.unsaved_threads.contains_key(id) || self.store.is_imported(id).unwrap_or(true) {
            return false;
        }
        let Ok(mut thread) = self.store.thread(id) else {
            return false;
        };
        let before = thread.clone();
        update(&mut thread);
        if thread == before || self.store.save(&thread).is_err() {
            return false;
        }
        self.revision += 1;
        true
    }

    fn set_thread_place(&mut self, id: &str, path: Option<&str>, branch: Option<&str>) -> bool {
        self.update_git_thread(id, |thread| {
            let Some(object) = thread.as_object_mut() else {
                return;
            };
            match path {
                Some(path) => object.insert("worktreePath".into(), json!(path)),
                None => object.remove("worktreePath"),
            };
            match branch {
                Some(branch) => object.insert("branch".into(), json!(branch)),
                None => object.remove("branch"),
            };
        })
    }

    fn spawn_git(
        &mut self,
        thread: &str,
        mutation: bool,
        completion: Completion,
        work: impl FnOnce(&dyn Fn(&str)) -> Result<Value> + Send + 'static,
    ) -> Result<Value> {
        self.require_background_admission()?;
        ensure!(
            self.git_actions.pending.len() < MAX_PENDING,
            "Too many Git operations; collect results first"
        );
        if mutation {
            ensure!(
                self.git_actions.mutating.insert(thread.to_owned()),
                "A Git action is running."
            );
        }
        let id = Uuid::new_v4().to_string();
        let progress = Arc::new(Mutex::new(String::new()));
        self.git_actions.pending.insert(
            id.clone(),
            Pending {
                thread: thread.to_owned(),
                started: Instant::now(),
                progress: progress.clone(),
                completion,
                mutation,
            },
        );
        let tx = self.git_actions.tx.clone();
        let operation = id.clone();
        let activity = self.idle_sleep.background_job();
        let worker = std::thread::spawn(move || {
            let _activity = activity;
            let report = |label: &str| {
                if let Ok(mut current) = progress.lock() {
                    *current = label.to_owned();
                }
            };
            let result = work(&report).unwrap_or_else(|error| error_value(&error));
            // Backpressure, never a dropped completion: it releases the mutation.
            let _ = tx.send((operation, result));
        });
        self.background_workers.track(worker);
        Ok(json!({"operationId":id,"resultMethod":"git.actions.result"}))
    }

    pub(super) fn git_actions_command(&mut self, method: &str, p: &Value) -> Result<Value> {
        self.require_admissions()?;
        let object = p.as_object().context("Git parameters must be an object")?;
        let allowed: &[&str] = match method {
            "git.actions.pullRequest" => &["threadId", "branch"],
            "git.actions.run" => &["threadId", "action", "message", "paths", "featureBranch"],
            "git.branches.list" => &["threadId", "scope"],
            "git.branches.checkout" | "git.branches.create" => &["threadId", "name"],
            "git.worktrees.useNew" => &["threadId", "baseBranch"],
            "git.worktrees.useExisting" => &["threadId", "path", "branch"],
            "git.actions.result" => &["threadId", "operationId"],
            _ => &["threadId"],
        };
        ensure!(
            object.keys().all(|key| allowed.contains(&key.as_str())),
            "Unknown Git parameter"
        );
        let owner = required(p, "threadId")?.to_owned();
        ensure!(owner.len() <= 128, "Invalid threadId");
        if method == "git.actions.result" {
            return self.git_actions_result(&owner, required(p, "operationId")?);
        }
        let thread = self
            .unsaved_threads
            .get(&owner)
            .cloned()
            .map_or_else(|| self.store.thread(&owner), Ok)?;
        let started = has_user_messages(&thread);
        let cwd = self.working_directory(&thread)?;
        ensure!(
            cwd.is_absolute(),
            "Stored working directory must be absolute"
        );
        match method {
            "git.toolbar.state" => Ok(self.git_toolbar_state(&owner, &thread)),
            "git.actions.status" => {
                let follow = thread["worktreePath"].is_null() && !started;
                let completion = if follow {
                    Completion::FollowBranch(cwd.clone())
                } else {
                    Completion::None
                };
                self.spawn_git(&owner, false, completion, move |_| {
                    let status = ops::status(&cwd)?;
                    let host = status
                        .has_remote
                        .then(|| ops::remote_host(&cwd, status.branch.as_deref()))
                        .flatten();
                    Ok(json!({
                        "status": status,
                        "hostName": host.as_ref().map(git::host::Host::display_name),
                        "changeRequestTerm": host.map_or(git::host::Term::PullRequest, |h| h.kind.change_request()),
                    }))
                })
            }
            "git.actions.pullRequest" => {
                let branch = name(p, "branch")?;
                self.spawn_git(&owner, false, Completion::None, move |_| {
                    Ok(json!({"pullRequest": ops::open_pull_request(&branch, &cwd, false)}))
                })
            }
            "git.actions.run" => {
                let action: git::StackedAction =
                    serde_json::from_value(p["action"].clone()).context("Unknown Git action")?;
                let message = p["message"].as_str().map(str::to_owned);
                ensure!(
                    message.as_ref().is_none_or(|m| m.len() <= 64 * 1024),
                    "Commit message is too long"
                );
                let paths = match &p["paths"] {
                    Value::Null => None,
                    value => {
                        let paths: Vec<String> =
                            serde_json::from_value(value.clone()).context("Invalid paths")?;
                        ensure!(
                            paths.len() <= 10_000
                                && paths.iter().all(|path| !path.is_empty()
                                    && path.len() <= 4096
                                    && !path.contains('\0')),
                            "Invalid paths"
                        );
                        Some(paths)
                    }
                };
                let request = ActionRequest {
                    action: Some(action),
                    commit_message: message,
                    file_paths: paths,
                    feature_branch: p["featureBranch"].as_bool().unwrap_or(false),
                };
                self.spawn_git(&owner, true, Completion::Branch, move |progress| {
                    let result = git::run(&request, &cwd, progress)?;
                    Ok(json!({"result": result, "branch": result.created_branch}))
                })
            }
            "git.actions.pull" => self.spawn_git(&owner, true, Completion::None, move |progress| {
                progress("Pulling…");
                Ok(json!({"pulled": ops::pull(&cwd)? == git::PullResult::Pulled}))
            }),
            "git.branches.list" => {
                // A new worktree's base comes from the project's branches, not the worktree's.
                let folder = if p["scope"] == "project" {
                    self.project_folder(&thread)?
                } else {
                    cwd
                };
                self.spawn_git(&owner, false, Completion::None, move |_| {
                    Ok(json!({"branches": ops::branches(&folder)?}))
                })
            }
            "git.branches.checkout" | "git.branches.create" => {
                ensure!(
                    !self.runs.contains_key(&owner),
                    "Stop the thread's active turn before changing its branch"
                );
                let branch = name(p, "name")?;
                let create = method == "git.branches.create";
                self.spawn_git(&owner, true, Completion::Branch, move |_| {
                    let branch = if create {
                        Some(ops::create_branch(&branch, &cwd, true)?)
                    } else {
                        ops::checkout(&branch, &cwd)?
                    };
                    Ok(json!({"branch": branch}))
                })
            }
            "git.worktrees.useCheckout" => self.use_project_checkout(&owner, &thread),
            "git.worktrees.useNew" => {
                let base = p["baseBranch"].as_str().map(str::to_owned);
                if let Some(base) = &base {
                    ensure!(
                        !base.is_empty() && base.len() <= 255 && !base.starts_with('-'),
                        "Invalid baseBranch"
                    );
                }
                self.use_new_worktree(&owner, &thread, base)
            }
            "git.worktrees.useExisting" => {
                let path = name(p, "path")?;
                let branch = p["branch"].as_str().map(str::to_owned);
                self.use_existing_worktree(&owner, &thread, path, branch)
            }
            _ => bail!("Unknown Git method"),
        }
    }

    fn git_actions_result(&mut self, owner: &str, id: &str) -> Result<Value> {
        self.poll_git_actions();
        if let Some(pending) = self.git_actions.pending.get(id) {
            ensure!(
                pending.thread == owner,
                "Git operation belongs to another thread"
            );
            let progress = pending
                .progress
                .lock()
                .map(|p| p.clone())
                .unwrap_or_default();
            return Ok(
                json!({"ready":false,"progress":(!progress.is_empty()).then_some(progress)}),
            );
        }
        let (_, result) = self
            .git_actions
            .results
            .get(id)
            .context("Git operation not found")?;
        ensure!(
            result["_thread"] == owner,
            "Git operation belongs to another thread"
        );
        // Verify the owner before consuming its one-shot result.
        let (_, mut result) = self.git_actions.results.remove(id).unwrap();
        if let Some(object) = result.as_object_mut() {
            object.remove("_thread");
        }
        Ok(json!({"ready":true,"result":result}))
    }

    fn git_toolbar_state(&self, owner: &str, thread: &Value) -> Value {
        let current = thread["worktreePath"].as_str();
        let previous = self.store.worktree_threads().ok().and_then(|threads| {
            threads
                .into_iter()
                .filter(|other| {
                    other.id != owner
                        && other
                            .project_id
                            .eq_ignore_ascii_case(thread["projectID"].as_str().unwrap_or(""))
                        && Some(other.path.as_str()) != current
                        && Path::new(&other.path).is_dir()
                })
                .max_by(|a, b| a.updated_at.total_cmp(&b.updated_at))
        });
        json!({
            "baseBranch": self.git_actions.bases.get(owner),
            "preparing": self.git_actions.preparing.contains(owner),
            "previousWorktree": previous.map(|p| json!({"path":p.path,"branch":p.branch})),
        })
    }

    fn require_unstarted(&self, owner: &str, thread: &Value) -> Result<()> {
        ensure!(
            !has_user_messages(thread),
            "A thread's workspace can only change before its first message"
        );
        ensure!(
            !self.git_actions.preparing.contains(owner),
            "A worktree is being prepared for this thread"
        );
        ensure!(
            !self.store.is_imported(owner)? && !self.unsaved_threads.contains_key(owner),
            "Fork an imported thread before changing Git state"
        );
        Ok(())
    }

    /// Removes the worktree made here for a thread when it was never used, off the
    /// engine thread; the thread shows as preparing until it is gone.
    fn discard_previous(&mut self, owner: &str, keep: Option<&str>) -> Result<()> {
        let Some(previous) = self.git_actions.unused.remove(owner) else {
            return Ok(());
        };
        if Some(previous.path.as_str()) == keep || self.worktree_in_use(&previous.path, Some(owner))
        {
            return Ok(());
        }
        let prefix = self.worktree_prefix();
        self.git_actions.preparing.insert(owner.to_owned());
        let result = self.spawn_git(owner, false, Completion::None, move |_| {
            let removed = ops::discard_unused_worktree(
                Path::new(&previous.path),
                previous.branch.as_deref(),
                &prefix,
            );
            Ok(json!({"discarded":removed,"preparingDone":true}))
        });
        if result.is_err() {
            self.git_actions.preparing.remove(owner);
        }
        result.map(|_| ())
    }

    fn use_project_checkout(&mut self, owner: &str, thread: &Value) -> Result<Value> {
        self.require_unstarted(owner, thread)?;
        if thread["worktreePath"].is_null() {
            return Ok(json!({"changed":false}));
        }
        let current = thread["worktreePath"].as_str().map(str::to_owned);
        let keep = self
            .git_actions
            .unused
            .get(owner)
            .filter(|unused| Some(&unused.path) != current.as_ref())
            .map(|unused| unused.path.clone());
        self.discard_previous(owner, keep.as_deref())?;
        self.git_actions.bases.remove(owner);
        self.git_actions.watched.remove(owner);
        Ok(json!({"changed": self.set_thread_place(owner, None, None)}))
    }

    fn use_existing_worktree(
        &mut self,
        owner: &str,
        thread: &Value,
        path: String,
        branch: Option<String>,
    ) -> Result<Value> {
        self.require_unstarted(owner, thread)?;
        ensure!(
            Path::new(&path).is_absolute(),
            "That worktree no longer exists"
        );
        let project = self.project_folder(thread)?;
        self.spawn_git(
            owner,
            true,
            Completion::ExistingWorktree(branch),
            move |_| {
                let path = ops::normalize(&path);
                if !Path::new(&path).is_dir() {
                    return git_fail("That worktree no longer exists.");
                }
                // Only a worktree of this thread's repository: one another thread used,
                // or a branch's checkout the picker listed.
                if !ops::worktrees(&project)?
                    .iter()
                    .any(|tree| tree.path == path)
                {
                    return git_fail("That folder is not a worktree of this project.");
                }
                Ok(json!({"path": path}))
            },
        )
    }

    fn use_new_worktree(
        &mut self,
        owner: &str,
        thread: &Value,
        base: Option<String>,
    ) -> Result<Value> {
        self.require_unstarted(owner, thread)?;
        let project = self.project_folder(thread)?;
        ensure!(
            project.is_absolute(),
            "Stored project directory must be absolute"
        );
        let root = self.store.data_directory()?.join("worktrees");
        let prefix = self.worktree_prefix();
        let previous = self
            .git_actions
            .unused
            .remove(owner)
            .filter(|previous| !self.worktree_in_use(&previous.path, Some(owner)));
        self.git_actions.preparing.insert(owner.to_owned());
        let result = self.spawn_git(owner, true, Completion::NewWorktree, move |progress| {
            progress("Preparing worktree…");
            if let Some(previous) = previous {
                ops::discard_unused_worktree(
                    Path::new(&previous.path),
                    previous.branch.as_deref(),
                    &prefix,
                );
            }
            let base = match base {
                Some(base) => Some(base),
                None => ops::branches(&project)
                    .ok()
                    .and_then(|list| list.default_base()),
            };
            let worktree = ops::create_thread_worktree(&project, base.as_deref(), &prefix, &root)?;
            Ok(json!({"worktree":worktree,"base":base,"prefix":prefix}))
        });
        if result.is_err() {
            self.git_actions.preparing.remove(owner);
        }
        result
    }

    /// Collects worker reports and applies their thread changes on the engine.
    pub(super) fn poll_git_actions(&mut self) {
        let now = Instant::now();
        let mut finished = Vec::new();
        for (id, result) in self.git_actions.rx.try_iter() {
            finished.push((id, result));
        }
        for (id, mut result) in finished {
            let Some(pending) = self.git_actions.pending.remove(&id) else {
                continue;
            };
            if pending.mutation {
                self.git_actions.mutating.remove(&pending.thread);
            }
            if result["preparingDone"] == true {
                self.git_actions.preparing.remove(&pending.thread);
            }
            if result.get("error").is_none() {
                self.complete_git(&pending, &mut result);
            } else if matches!(pending.completion, Completion::NewWorktree) {
                self.git_actions.preparing.remove(&pending.thread);
            }
            if let Some(object) = result.as_object_mut() {
                object.insert("_thread".into(), json!(pending.thread));
            }
            // Only a changed thread record bumps the revision, never a read.
            self.git_actions.results.insert(id, (now, result));
        }
        let expired: Vec<String> = self
            .git_actions
            .pending
            .iter()
            .filter(|(_, pending)| {
                !pending.mutation && pending.started.elapsed() > OPERATION_LIFETIME
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in expired {
            // Expire abandoned reads only. A mutation keeps its exclusion
            // until its actual completion; elapsed time cannot prove it stopped.
            if let Some(pending) = self.git_actions.pending.remove(&id) {
                self.git_actions.mutating.remove(&pending.thread);
                self.git_actions.preparing.remove(&pending.thread);
            }
        }
        self.git_actions
            .results
            .retain(|_, (at, _)| at.elapsed() < RESULT_LIFETIME);
        if self.git_actions.last_watch.elapsed() >= Duration::from_secs(1) {
            self.git_actions.last_watch = now;
            self.watch_worktree_threads();
        }
    }

    fn complete_git(&mut self, pending: &Pending, result: &mut Value) {
        let owner = pending.thread.clone();
        match &pending.completion {
            Completion::None => {}
            Completion::FollowBranch(folder) => {
                // Until it starts, a thread in the project's checkout is on whatever
                // branch the folder is on.
                let Some(branch) = result["status"]["branch"].as_str().map(str::to_owned) else {
                    return;
                };
                let Ok(thread) = self.store.thread(&owner) else {
                    return;
                };
                if thread["worktreePath"].is_null()
                    && !has_user_messages(&thread)
                    && thread["branch"].as_str() != Some(&branch)
                    && self
                        .working_directory(&thread)
                        .is_ok_and(|cwd| &cwd == folder)
                {
                    self.update_git_thread(&owner, |thread| thread["branch"] = json!(branch));
                }
            }
            Completion::Branch => {
                if let Some(branch) = result["branch"].as_str().map(str::to_owned) {
                    self.update_git_thread(&owner, |thread| thread["branch"] = json!(branch));
                }
            }
            Completion::NewWorktree => {
                self.git_actions.preparing.remove(&owner);
                let Some(path) = result["worktree"]["path"].as_str().map(str::to_owned) else {
                    return;
                };
                let branch = result["worktree"]["branch"].as_str().map(str::to_owned);
                let prefix = result["prefix"].as_str().unwrap_or("coincide/").to_owned();
                let unstarted = self
                    .store
                    .thread(&owner)
                    .is_ok_and(|thread| !has_user_messages(&thread));
                // A message sent meanwhile already runs in the project folder; leave it there.
                if !unstarted || !self.set_thread_place(&owner, Some(&path), branch.as_deref()) {
                    let discard = Unused { path, branch };
                    let _ = self.spawn_git(&owner, false, Completion::None, move |_| {
                        ops::discard_unused_worktree(
                            Path::new(&discard.path),
                            discard.branch.as_deref(),
                            &prefix,
                        );
                        Ok(json!({}))
                    });
                    result["discarded"] = json!(true);
                    return;
                }
                if let Some(base) = result["base"].as_str() {
                    self.git_actions
                        .bases
                        .insert(owner.clone(), base.to_owned());
                }
                self.git_actions
                    .unused
                    .insert(owner.clone(), Unused { path, branch });
                self.git_actions.watched.insert(owner);
            }
            Completion::ExistingWorktree(branch) => {
                let Some(path) = result["path"].as_str().map(str::to_owned) else {
                    return;
                };
                let unstarted = self
                    .store
                    .thread(&owner)
                    .is_ok_and(|thread| !has_user_messages(&thread));
                if !unstarted {
                    return;
                }
                let _ = self.discard_previous(&owner, Some(&path));
                self.git_actions.bases.remove(&owner);
                self.git_actions.watched.insert(owner.clone());
                self.set_thread_place(&owner, Some(&path), branch.as_deref());
            }
            Completion::Renamed { path, branch } => {
                let Some(renamed) = result["renamed"].as_str().map(str::to_owned) else {
                    return;
                };
                // Threads sharing the worktree follow the rename.
                let followers: Vec<String> = self
                    .store
                    .worktree_threads()
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|thread| &thread.path == path && thread.branch.as_ref() == Some(branch))
                    .map(|thread| thread.id)
                    .collect();
                for follower in followers {
                    self.update_git_thread(&follower, |thread| thread["branch"] = json!(renamed));
                }
            }
        }
    }

    /// Names temporary worktree branches after a thread's first message, and removes
    /// worktrees made for threads that were deleted before they started.
    fn watch_worktree_threads(&mut self) {
        if self.git_actions.watched.is_empty() && self.git_actions.unused.is_empty() {
            return;
        }
        let prefix = self.worktree_prefix();
        for owner in self.git_actions.unused.keys().cloned().collect::<Vec<_>>() {
            if self.store.thread(&owner).is_err() {
                self.git_actions.bases.remove(&owner);
                self.git_actions.watched.remove(&owner);
                if let Some(unused) = self.git_actions.unused.remove(&owner)
                    && !self.worktree_in_use(&unused.path, None)
                {
                    let prefix = prefix.clone();
                    let _ = self.spawn_git(&owner, false, Completion::None, move |_| {
                        ops::discard_unused_worktree(
                            Path::new(&unused.path),
                            unused.branch.as_deref(),
                            &prefix,
                        );
                        Ok(json!({}))
                    });
                }
            }
        }
        for owner in self.git_actions.watched.iter().cloned().collect::<Vec<_>>() {
            let Ok(thread) = self.store.thread(&owner) else {
                self.git_actions.watched.remove(&owner);
                continue;
            };
            let Some(message) = thread["items"].as_array().and_then(|items| {
                items
                    .iter()
                    .find(|item| item["kind"] == "user")
                    .and_then(|item| item["text"].as_str())
                    .map(str::to_owned)
            }) else {
                continue;
            };
            self.git_actions.watched.remove(&owner);
            let Some(path) = thread["worktreePath"].as_str().map(str::to_owned) else {
                continue;
            };
            // A message in the worktree makes it used, whichever thread it was made for.
            self.git_actions
                .unused
                .retain(|_, unused| unused.path != path);
            let Some(branch) = thread["branch"].as_str().map(str::to_owned) else {
                continue;
            };
            if !git::names::is_temporary_worktree_branch(&branch, &prefix) {
                continue;
            }
            let worktree = PathBuf::from(&path);
            let (old, prefix) = (branch.clone(), prefix.clone());
            let _ = self.spawn_git(
                &owner,
                false,
                Completion::Renamed { path, branch },
                move |_| {
                    let renamed = ops::name_worktree_branch(&old, &worktree, &message, &prefix)?;
                    Ok(json!({"renamed": renamed}))
                },
            );
        }
    }
}
