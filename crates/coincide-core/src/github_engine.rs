//! Read-only GitHub routes. COINCIDE_RUST_GH, when set, must name an absolute
//! executable. Otherwise discover gh through absolute PATH entries using only
//! metadata. Construction never launches gh or contacts GitHub; only explicit
//! github.pr.list/read commands do so, with the user's existing gh credentials.
use super::*;
use crate::github_api::{GhRunner, GithubService};
use std::{ffi::OsStr, path::Path};

pub(super) const METHODS: &[&str] = &["github.pr.list", "github.pr.read", "github.result"];

pub(super) struct GithubState {
    service: Option<GithubService>,
    error: String,
}
impl GithubState {
    pub fn discover() -> Self {
        Self::configured(
            std::env::var_os("COINCIDE_RUST_GH").as_deref(),
            std::env::var_os("PATH").as_deref(),
        )
    }
    fn configured(explicit: Option<&OsStr>, search: Option<&OsStr>) -> Self {
        match resolve(explicit, search).and_then(GhRunner::new) {
            Ok(runner) => Self {
                service: Some(GithubService::new(runner)),
                error: String::new(),
            },
            Err(error) => Self {
                service: None,
                error: error.to_string(),
            },
        }
    }
}

fn executable(path: &Path) -> Result<PathBuf> {
    ensure!(
        path.is_absolute(),
        "COINCIDE_RUST_GH must be an absolute executable path"
    );
    let path = path
        .canonicalize()
        .context("Configured GitHub CLI is unavailable")?;
    let metadata = path
        .metadata()
        .context("Configured GitHub CLI is unavailable")?;
    ensure!(metadata.is_file(), "Configured GitHub CLI is not a file");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        ensure!(
            metadata.permissions().mode() & 0o111 != 0,
            "Configured GitHub CLI is not executable"
        );
    }
    Ok(path)
}

fn resolve(explicit: Option<&OsStr>, search: Option<&OsStr>) -> Result<PathBuf> {
    ensure!(
        cfg!(unix),
        "GitHub PR reads are not supported on this platform yet"
    );
    if let Some(path) = explicit {
        // An invalid explicit override must never fall back to another binary.
        return executable(Path::new(path));
    }
    if let Some(search) = search {
        ensure!(
            search.len() <= 65_536,
            "GitHub executable search path is too large"
        );
        for directory in std::env::split_paths(search).take(128) {
            if directory.is_absolute()
                && let Ok(path) = executable(&directory.join("gh"))
            {
                return Ok(path);
            }
        }
    }
    bail!(
        "GitHub CLI not found; install gh or set COINCIDE_RUST_GH to its absolute executable path"
    )
}

impl Engine {
    pub(super) fn github_command(&mut self, method: &str, params: &Value) -> Result<Value> {
        ensure!(
            cfg!(unix),
            "GitHub PR reads are not supported on this platform yet"
        );
        ensure!(!self.shutdown, "Application is shutting down");
        let keys: &[&str] = match method {
            "github.pr.list" => &["threadId", "expectedRoot", "repository", "state", "limit"],
            "github.pr.read" => &[
                "threadId",
                "expectedRoot",
                "repository",
                "number",
                "expectedHead",
            ],
            "github.result" => &["threadId", "expectedRoot", "operationId"],
            _ => bail!("Unsupported read-only GitHub method"),
        };
        let object = params
            .as_object()
            .context("GitHub parameters must be an object")?;
        ensure!(
            object.keys().all(|key| keys.contains(&key.as_str())),
            "Unsupported GitHub parameter"
        );
        let thread_id = required(params, "threadId")?;
        Uuid::parse_str(thread_id).context("Invalid thread ID")?;
        let thread = self.store.thread(thread_id)?;
        let root = self.working_directory(&thread)?;
        let service = self
            .github
            .service
            .as_mut()
            .context(self.github.error.clone())?;
        if method == "github.result" {
            let operation = required(params, "operationId")?;
            Uuid::parse_str(operation).context("Invalid GitHub operation ID")?;
            service.result(
                thread_id,
                &root,
                Path::new(required(params, "expectedRoot")?),
                operation,
            )
        } else {
            service.start_with_guard(
                thread_id,
                &root,
                method,
                params,
                self.idle_sleep.background_job(),
            )
        }
    }
}

#[cfg(test)]
#[path = "github_engine_tests.rs"]
mod tests;
