//! Register in api.rs with #[path = "workspace_api.rs"] mod workspace_api;
//! Route METHODS to self.workspace_command(method, p), and append METHODS to
//! capabilities. Completion uses git.workspace.result (120s vs legacy 20s).
//! Owner authentication remains the control transport's responsibility. Repository
//! roots come exclusively from stored threads, never a caller-supplied cwd.
use super::*;
use crate::workspace_git;
use std::path::Path;

pub(super) const METHODS: &[&str] = &[
    "git.checkpoints.create",
    "git.checkpoints.list",
    "git.checkpoints.diff",
    "git.worktrees.reserve",
    "git.worktrees.list",
    "git.workspace.result",
];

fn bounded<'a>(p: &'a Value, key: &str, max: usize) -> Result<&'a str> {
    let value = required(p, key)?;
    ensure!(
        !value.is_empty() && value.len() <= max && !value.contains('\0'),
        "Invalid {key}"
    );
    Ok(value)
}

impl Engine {
    pub(super) fn workspace_command(&mut self, method: &str, p: &Value) -> Result<Value> {
        ensure!(METHODS.contains(&method), "Unknown workspace method");
        let object = p
            .as_object()
            .context("Workspace params must be an object")?;
        let allowed: &[&str] = match method {
            "git.checkpoints.create" => &["threadId", "expectedRoot", "expectedHead", "label"],
            "git.checkpoints.diff" => &["threadId", "expectedRoot", "checkpointId"],
            "git.worktrees.reserve" => &["threadId", "expectedRoot", "base", "name", "branch"],
            "git.workspace.result" => &["threadId", "operationId"],
            _ => &["threadId", "expectedRoot"],
        };
        ensure!(
            object.keys().all(|key| allowed.contains(&key.as_str())),
            "Unknown workspace parameter"
        );
        let owner = bounded(p, "threadId", 128)?.to_owned();
        let thread = self.store.thread(&owner)?;
        if method == "git.workspace.result" {
            let id = bounded(p, "operationId", 36)?;
            ensure!(
                self.workspace_git_operations.contains(id),
                "Use workspace.result for this operation, or refresh if it has expired"
            );
            let (thread, started) = self
                .workspace_pending
                .get(id)
                .context("Workspace operation not found")?;
            ensure!(
                thread == &owner,
                "Workspace operation belongs to another thread"
            );
            ensure!(
                !self.attachment_operations.contains(id),
                "Use workspace.result for attachments"
            );
            if let Some(result) = self.workspace_results.remove(id) {
                self.workspace_pending.remove(id);
                self.workspace_git_operations.remove(id);
                return Ok(json!({"ready":true,"result":result}));
            }
            if started.elapsed() > Duration::from_secs(120) {
                self.workspace_pending.remove(id);
                self.workspace_git_operations.remove(id);
                return Ok(
                    json!({"ready":true,"result":{"error":"Workspace operation timed out; work may still be running. Mutations remain blocked until it finishes; refresh before retrying"}}),
                );
            }
            return Ok(json!({"ready":false}));
        }
        ensure!(
            self.workspace_pending.len() < 32,
            "Too many workspace operations; collect results first"
        );
        let mutating = matches!(method, "git.checkpoints.create" | "git.worktrees.reserve");
        if mutating {
            ensure!(
                self.workspace_mutations.is_empty(),
                "A workspace mutation is still running; wait for completion and refresh before retrying"
            );
            ensure!(
                !self.store.is_imported(&owner)?,
                "Fork an imported thread before changing Git state"
            );
            ensure!(
                !self.unsaved_threads.contains_key(&owner),
                "Transcript persistence is recovering; retry after recovery"
            );
            ensure!(
                !self.runs.contains_key(&owner),
                "Stop the thread's active turn before changing Git state"
            );
            // No competing workspace mutation through this dispatcher. External Git
            // processes still require the primitive's ref/index locks and stale checks.
            ensure!(
                self.workspace_pending.is_empty(),
                "Collect outstanding workspace operations before changing Git state"
            );
        }
        let directory = self.working_directory(&thread)?;
        ensure!(
            directory.is_absolute(),
            "Stored working directory must be absolute"
        );
        let directory = directory.canonicalize()?;
        let expected = Path::new(bounded(p, "expectedRoot", 4096)?);
        ensure!(
            expected.is_absolute() && expected.canonicalize()? == directory,
            "Working directory changed; refresh before operating"
        );
        // Parse completely before reserving an operation or creating directories.
        let head = if method == "git.checkpoints.create" {
            Some(bounded(p, "expectedHead", 64)?.to_owned())
        } else {
            None
        };
        if let Some(head) = &head {
            workspace_git::validate_oid(head)?;
        }
        let label = if method == "git.checkpoints.create" {
            Some(bounded(p, "label", 500)?.to_owned())
        } else {
            None
        };
        let checkpoint = if method == "git.checkpoints.diff" {
            let id = bounded(p, "checkpointId", 36)?;
            ensure!(
                Uuid::parse_str(id).is_ok_and(|value| value.to_string() == id),
                "Invalid checkpoint ID"
            );
            Some(id.to_owned())
        } else {
            None
        };
        let reservation = if method == "git.worktrees.reserve" {
            let base = bounded(p, "base", 64)?.to_owned();
            workspace_git::validate_oid(&base)?;
            let name = bounded(p, "name", 128)?.to_owned();
            let branch = bounded(p, "branch", 200)?.to_owned();
            Some((self.store.data_directory()?, name, branch, base))
        } else {
            None
        };
        let id = Uuid::new_v4().to_string();
        self.workspace_pending
            .insert(id.clone(), (owner, Instant::now()));
        self.workspace_git_operations.insert(id.clone());
        if mutating {
            self.workspace_mutations.insert(id.clone());
        }
        let tx = self.workspace_tx.clone();
        let operation = id.clone();
        let method = method.to_owned();
        let activity = self.idle_sleep.background_job();
        std::thread::spawn(move || {
            let _activity = activity;
            let result = (|| -> Result<Value> {
                match method.as_str() {
                    "git.checkpoints.create" => workspace_git::create_checkpoint(
                        &directory,
                        head.as_deref().context("Missing head")?,
                        label.as_deref().context("Missing label")?,
                    ),
                    "git.checkpoints.list" => workspace_git::checkpoints(&directory),
                    "git.checkpoints.diff" => workspace_git::checkpoint_diff(
                        &directory,
                        checkpoint.as_deref().context("Missing checkpoint")?,
                    ),
                    "git.worktrees.list" => workspace_git::worktrees(&directory),
                    "git.worktrees.reserve" => {
                        let (data, name, branch, base) =
                            reservation.context("Missing reservation")?;
                        let data = data.canonicalize()?;
                        let parent = data.join("worktrees");
                        // A caller cannot choose an arbitrary destination parent.
                        // Refuse symlinks before creating an app-owned directory.
                        match std::fs::symlink_metadata(&parent) {
                            Ok(meta) => ensure!(
                                meta.is_dir() && !meta.file_type().is_symlink(),
                                "Worktree storage must be a real directory"
                            ),
                            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                                #[cfg(unix)]
                                let mut builder = std::fs::DirBuilder::new();
                                #[cfg(not(unix))]
                                let builder = std::fs::DirBuilder::new();
                                #[cfg(unix)]
                                {
                                    use std::os::unix::fs::DirBuilderExt;
                                    builder.mode(0o700);
                                }
                                builder.create(&parent)?;
                            }
                            Err(error) => return Err(error.into()),
                        }
                        workspace_git::create_worktree(&directory, &parent, &name, &branch, &base)
                    }
                    _ => bail!("Unknown workspace method"),
                }
            })()
            .unwrap_or_else(|error| json!({"error":error.to_string()}));
            // A full bounded channel must apply backpressure, never discard a
            // mutation completion and strand its exclusion. Engine::poll drains
            // it; dropping the engine disconnects and releases waiting workers.
            publish_completion(tx, operation, result);
        });
        Ok(json!({"operationId":id,"resultMethod":"git.workspace.result"}))
    }
}

pub(super) fn publish_completion(
    tx: std::sync::mpsc::SyncSender<(String, Value)>,
    operation: String,
    result: Value,
) {
    let _ = tx.send((operation, result));
}
