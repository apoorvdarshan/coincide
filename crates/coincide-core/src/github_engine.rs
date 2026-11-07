//! Read-only GitHub routes. COINCIDE_RUST_GH, when set, must name an absolute
//! executable. Otherwise discover gh through absolute PATH entries using only
//! metadata. Construction never launches gh or contacts GitHub; only explicit
//! github.pr.list/read and github.repo.merge-methods commands do so, with the
//! user's existing gh credentials.
use super::*;
use crate::github_api::{GhRunner, GithubService};
use std::{ffi::OsStr, path::Path};

pub(super) const METHODS: &[&str] = &[
    "github.pr.list",
    "github.pr.read",
    "github.repo.merge-methods",
    "github.result",
];

pub(super) struct GithubState {
    service: Option<GithubService>,
    error: String,
    shutdown_requested: bool,
}
impl GithubState {
    pub(super) fn unavailable() -> Self {
        Self {
            service: None,
            error: "GitHub is unavailable in this isolated engine".into(),
            shutdown_requested: false,
        }
    }

    pub fn discover() -> Self {
        Self::configured(
            std::env::var_os("COINCIDE_RUST_GH").as_deref(),
            std::env::var_os("PATH").as_deref(),
        )
    }
    pub(super) fn configured(explicit: Option<&OsStr>, search: Option<&OsStr>) -> Self {
        match resolve(explicit, search).and_then(GhRunner::new) {
            Ok(runner) => Self {
                service: Some(GithubService::new(runner)),
                error: String::new(),
                shutdown_requested: false,
            },
            Err(error) => Self {
                service: None,
                error: error.to_string(),
                shutdown_requested: false,
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
    #[cfg(windows)]
    {
        use std::io::Read;
        let mut source = crate::native_file::open_regular(&path, false)?;
        let mut signature = [0; 2];
        source.read_exact(&mut signature)?;
        ensure!(
            signature == *b"MZ",
            "Configured GitHub CLI must be a native Windows executable"
        );
    }
    Ok(path)
}

fn resolve(explicit: Option<&OsStr>, search: Option<&OsStr>) -> Result<PathBuf> {
    ensure!(
        cfg!(any(unix, windows)),
        "GitHub PR reads are not supported on this platform"
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
                && let Ok(path) =
                    executable(&directory.join(if cfg!(windows) { "gh.exe" } else { "gh" }))
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
    /// Stop read admissions and request cancellation; never waits for gh or joins.
    pub fn request_github_reads_shutdown(&mut self) -> Result<()> {
        ensure!(
            self.admissions_frozen(),
            "GitHub shutdown requires frozen admissions"
        );
        self.github.shutdown_requested = true;
        if let Some(service) = &mut self.github.service {
            service.request_shutdown();
        }
        self.github_threads.request_shutdown();
        Ok(())
    }
    /// Separate PR/inline read-worker ownership; excludes desktop write workers.
    pub fn github_reads_shutdown_status(
        &mut self,
    ) -> Result<[crate::github_api::ReadShutdownStatus; 2]> {
        ensure!(
            self.admissions_frozen(),
            "GitHub shutdown status requires frozen admissions"
        );
        let reads = self.github.service.as_mut().map_or(
            crate::github_api::ReadShutdownStatus {
                closed: self.github.shutdown_requested,
                ..Default::default()
            },
            GithubService::shutdown_status,
        );
        Ok([reads, self.github_threads.shutdown_status()])
    }
    /// Native transport preparation: derive the root from stored thread/project
    /// state while briefly locked, then perform GitHub work outside that lock.
    pub fn github_write_root(&self, thread_id: &str) -> Result<PathBuf> {
        self.require_admissions()?;
        ensure!(!self.shutdown, "Application is shutting down");
        Uuid::parse_str(thread_id).context("Invalid thread ID")?;
        self.working_directory(&self.store.thread(thread_id)?)
    }
    /// Reuse the exact executable captured by read-service configuration. Never
    /// rediscover PATH or accept an executable path from a mutation request.
    pub fn github_cli_path(&self) -> Result<PathBuf> {
        Ok(self
            .github
            .service
            .as_ref()
            .context(self.github.error.clone())?
            .executable()
            .to_owned())
    }
    pub(super) fn github_command(&mut self, method: &str, params: &Value) -> Result<Value> {
        ensure!(
            cfg!(any(unix, windows)),
            "GitHub PR reads are not supported on this platform"
        );
        ensure!(!self.shutdown, "Application is shutting down");
        let keys: &[&str] = match method {
            "github.pr.list" => &[
                "threadId",
                "expectedRoot",
                "repository",
                "state",
                "limit",
                "involvement",
            ],
            "github.pr.read" => &[
                "threadId",
                "expectedRoot",
                "repository",
                "number",
                "expectedHead",
            ],
            "github.repo.merge-methods" => &["threadId", "expectedRoot", "repository"],
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

#[cfg(test)]
mod shutdown_tests {
    use crate::github_api::ReadShutdownStatus;

    #[test]
    fn frozen_engine_closes_both_read_services_without_lazy_launch() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = crate::api::Engine::fixture(
            crate::store::Store::open(&dir.path().join("state.sqlite")).unwrap(),
        );
        assert!(engine.request_github_reads_shutdown().is_err());
        assert!(engine.github_reads_shutdown_status().is_err());
        engine.freeze_admissions();
        engine.request_github_reads_shutdown().unwrap();
        engine.request_github_reads_shutdown().unwrap();
        for status in engine.github_reads_shutdown_status().unwrap() {
            assert_eq!(
                status,
                ReadShutdownStatus {
                    closed: true,
                    ..Default::default()
                }
            );
        }
    }
}
