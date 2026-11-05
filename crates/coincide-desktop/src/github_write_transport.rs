//! Native-only GitHub action transport. No arbitrary API route can initialize
//! the durable ledger, supply its location, or replace the configured gh path.
use crate::github_actions::WriteTransport;
use anyhow::{Context as _, Result, bail, ensure};
use coincide_core::{api::SharedEngine, github_write::GithubWriteService, store::Store};
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
};

const MARKER: &str = "rust-github-write-ledger.json";
const DIRECTORY: &str = "github-write-ledger";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Status {
    Opening,
    FirstSetup,
    Initializing,
    Ready,
    Failed(String),
}
struct State {
    service: Option<GithubWriteService>,
    data: Option<PathBuf>,
    status: Status,
}
#[derive(Clone)]
pub struct NativeWrites {
    engine: SharedEngine,
    state: Arc<Mutex<State>>,
}

fn registered(marker: Option<&Value>) -> Result<bool> {
    let Some(marker) = marker else {
        return Ok(false);
    };
    ensure!(
        marker["version"] == 1 && marker["creationReserved"] == true,
        "GitHub ledger setup marker is invalid; restore its original storage"
    );
    Ok(true)
}

fn ledger_absent(data: &std::path::Path) -> Result<bool> {
    match std::fs::symlink_metadata(data.join(DIRECTORY)) {
        Ok(_) => Ok(false), // Includes dangling symlinks: never treat as empty.
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
        Err(error) => Err(error.into()),
    }
}

/// Persist the reservation BEFORE creating files. A crash or lost whole ledger
/// must never make this look like first setup again. Only the explicit native
/// setup button reaches this function, under the Engine lock.
fn reserve_setup(store: &mut Store) -> Result<PathBuf> {
    ensure!(
        !registered(store.local_document(MARKER)?.as_ref())?,
        "GitHub ledger setup already attempted; restore existing storage, never recreate it"
    );
    let data = store.data_directory()?;
    ensure!(
        ledger_absent(&data)?,
        "Existing GitHub ledger needs recovery, not initialization"
    );
    store.save_document(MARKER, &json!({"version":1,"creationReserved":true}))?;
    Ok(data)
}

impl NativeWrites {
    /// Starts only metadata/SQLite work; never runs gh or queries an account.
    pub fn new(engine: SharedEngine) -> Self {
        let this = Self {
            engine,
            state: Arc::new(Mutex::new(State {
                service: None,
                data: None,
                status: Status::Opening,
            })),
        };
        let worker = this.clone();
        let spawned = std::thread::Builder::new()
            .name("github-ledger-open".into())
            .spawn(move || {
                let result = (|| -> Result<(PathBuf, Option<GithubWriteService>)> {
                    ensure!(
                        cfg!(unix),
                        "GitHub actions are unavailable on this platform"
                    );
                    let (data, gh, marker) = {
                        let engine = worker
                            .engine
                            .lock()
                            .map_err(|_| anyhow::anyhow!("Engine unavailable"))?;
                        ensure!(!engine.shutdown, "Application is shutting down");
                        (
                            engine.store.data_directory()?,
                            engine.github_cli_path()?,
                            engine.store.local_document(MARKER)?,
                        )
                    };
                    if !registered(marker.as_ref())? {
                        ensure!(
                            ledger_absent(&data)?,
                            "Unregistered GitHub ledger exists; restore its original setup marker"
                        );
                        return Ok((data, None));
                    }
                    // Missing/corrupt/replaced storage is an error. NEVER create as
                    // a fallback after open fails, even when the directory is gone.
                    let service = GithubWriteService::open(gh, data.join(DIRECTORY))?;
                    Ok((data, Some(service)))
                })();
                worker.finish(result);
            });
        if let Err(error) = spawned {
            this.fail(error.to_string());
        }
        this
    }
    fn fail(&self, error: String) {
        if let Ok(mut state) = self.state.lock() {
            state.service = None;
            state.status = Status::Failed(error.chars().take(512).collect());
        }
    }
    fn finish(&self, result: Result<(PathBuf, Option<GithubWriteService>)>) {
        match result {
            Ok((data, service)) => {
                if let Ok(mut state) = self.state.lock() {
                    state.status = if service.is_some() {
                        Status::Ready
                    } else {
                        Status::FirstSetup
                    };
                    state.data = Some(data);
                    state.service = service;
                }
            }
            Err(error) => self.fail(error.to_string()),
        }
    }
    pub fn status(&self) -> Option<Status> {
        self.state.try_lock().ok().map(|state| state.status.clone())
    }
    /// Explicit native first-setup action only. No retry/reinitialize API.
    pub fn initialize_from_user_action(&self) -> bool {
        let Ok(mut state) = self.state.try_lock() else {
            return false;
        };
        if state.status != Status::FirstSetup {
            return false;
        }
        state.status = Status::Initializing;
        drop(state);
        let worker = self.clone();
        let spawned = std::thread::Builder::new()
            .name("github-ledger-create".into())
            .spawn(move || {
                let result = (|| -> Result<(PathBuf, Option<GithubWriteService>)> {
                    let (data, gh) = {
                        let mut engine = worker
                            .engine
                            .lock()
                            .map_err(|_| anyhow::anyhow!("Engine unavailable"))?;
                        ensure!(!engine.shutdown, "Application is shutting down");
                        let gh = engine.github_cli_path()?;
                        let data = reserve_setup(&mut engine.store)?;
                        (data, gh)
                    };
                    let service = GithubWriteService::create(gh, data.join(DIRECTORY))?;
                    Ok((data, Some(service)))
                })();
                worker.finish(result);
            });
        if let Err(error) = spawned {
            self.fail(error.to_string());
        }
        true
    }
    pub fn transport(&self) -> WriteTransport {
        let this = self.clone();
        Arc::new(move |method, params| this.call(method, params))
    }
    fn call(&self, method: &str, params: Value) -> Result<Value> {
        let allowed: &[&str] = match method {
            "github.write.history" => &["threadId", "expectedRoot", "repository", "number"],
            "github.write.prepare" => &[
                "threadId",
                "expectedRoot",
                "repository",
                "number",
                "expectedHead",
            ],
            "github.write.submit" => &[
                "threadId",
                "expectedRoot",
                "repository",
                "number",
                "expectedHead",
                "baselineId",
                "mutationId",
                "action",
            ],
            "github.write.result" => &[
                "threadId",
                "expectedRoot",
                "repository",
                "number",
                "expectedHead",
                "mutationId",
            ],
            _ => bail!("Unsupported native GitHub write operation"),
        };
        ensure!(
            params
                .as_object()
                .is_some_and(|object| object.keys().all(|key| allowed.contains(&key.as_str()))),
            "Unexpected GitHub write parameter"
        );
        let thread = params["threadId"].as_str().context("Thread ID required")?;
        let (service, root) = {
            let engine = self
                .engine
                .lock()
                .map_err(|_| anyhow::anyhow!("Engine unavailable"))?;
            let root = engine.github_write_root(thread)?;
            let data = engine.store.data_directory()?;
            ensure!(
                registered(engine.store.local_document(MARKER)?.as_ref())?,
                "GitHub ledger setup marker missing; restore original storage"
            );
            let state = self
                .state
                .lock()
                .map_err(|_| anyhow::anyhow!("GitHub ledger unavailable"))?;
            ensure!(
                state.data.as_ref() == Some(&data),
                "GitHub ledger storage context changed"
            );
            let service = state
                .service
                .clone()
                .context("Initialize or restore the GitHub action ledger before writing")?;
            (service, root)
        }; // No Engine or service-state guard crosses filesystem/network work.
        match method {
            "github.write.prepare" => service.prepare(thread, &root, &params),
            "github.write.submit" => service.submit(thread, &root, &params),
            "github.write.result" => service.result(thread, &root, &params),
            "github.write.history" => service.history(thread, &root, &params),
            _ => unreachable!(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir()
                .join(format!("coincide-github-ledger-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn store(&self) -> Store {
            Store::open(&self.0.join("store.sqlite3")).unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn setup_reservation_survives_restart_and_missing_whole_ledger() {
        let fixture = Fixture::new();
        let mut store = fixture.store();
        let data = reserve_setup(&mut store).unwrap();
        assert!(ledger_absent(&data).unwrap());
        drop(store); // Crash before create: first setup cannot be repeated.
        let mut reopened = fixture.store();
        assert!(registered(reopened.local_document(MARKER).unwrap().as_ref()).unwrap());
        assert!(reserve_setup(&mut reopened).is_err());
    }
    #[test]
    fn unknown_marker_and_unregistered_directory_never_become_first_setup() {
        let fixture = Fixture::new();
        let mut store = fixture.store();
        std::fs::create_dir(fixture.0.join(DIRECTORY)).unwrap();
        assert!(reserve_setup(&mut store).is_err());
        assert!(store.local_document(MARKER).unwrap().is_none());
        store
            .save_document(MARKER, &json!({"version":2,"creationReserved":true}))
            .unwrap();
        assert!(registered(store.local_document(MARKER).unwrap().as_ref()).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn dangling_ledger_alias_is_not_missing_storage() {
        let fixture = Fixture::new();
        let mut store = fixture.store();
        std::os::unix::fs::symlink(fixture.0.join("missing"), fixture.0.join(DIRECTORY)).unwrap();
        assert!(reserve_setup(&mut store).is_err());
        assert!(store.local_document(MARKER).unwrap().is_none());
    }

    #[cfg(unix)]
    #[test]
    fn prepare_releases_engine_and_all_routes_bind_stored_root() {
        use std::{
            os::unix::fs::PermissionsExt,
            time::{Duration, Instant},
        };
        let fixture = Fixture::new();
        let root = fixture.0.join("project");
        let other = fixture.0.join("other");
        std::fs::create_dir(&root).unwrap();
        std::fs::create_dir(&other).unwrap();
        let root = root.canonicalize().unwrap();
        let other = other.canonicalize().unwrap();
        let gh = fixture.0.join("fake-gh");
        std::fs::write(
            &gh,
            r#"#!/bin/sh
test "$1" = pr && test "$2" = view || exit 81
printf x >> calls
: > entered
n=0
while test ! -f release; do
  n=$((n+1)); test "$n" -lt 500 || exit 82
  sleep 0.01
done
cat snapshot.json
"#,
        )
        .unwrap();
        std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o700)).unwrap();
        let snapshot = json!({"number":7,"title":"Fixture","url":"https://github.com/owner/project/pull/7","state":"OPEN","isDraft":false,"headRefOid":"a".repeat(40),"headRefName":"feature","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","reviews":[],"statusCheckRollup":[],"mergeCommit":null});
        std::fs::write(root.join("snapshot.json"), snapshot.to_string()).unwrap();
        let mut store = fixture.store();
        let project = store.create_project(&root, None).unwrap();
        let thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
        let data = reserve_setup(&mut store).unwrap();
        let service = GithubWriteService::create(gh, data.join(DIRECTORY)).unwrap();
        let engine = Arc::new(Mutex::new(coincide_core::api::Engine::new(store)));
        let transport = NativeWrites {
            engine: engine.clone(),
            state: Arc::new(Mutex::new(State {
                service: Some(service),
                data: Some(data),
                status: Status::Ready,
            })),
        };
        let scope = json!({"threadId":thread["id"],"expectedRoot":root,"repository":"owner/project","number":7,"expectedHead":"a".repeat(40)});
        let worker = transport.clone();
        let request = scope.clone();
        let job = std::thread::spawn(move || worker.call("github.write.prepare", request));
        let deadline = Instant::now() + Duration::from_secs(5);
        while !root.join("entered").is_file() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        // Always release the fixture child before assertions or joining.
        let entered = root.join("entered").is_file();
        let engine_available = engine.try_lock().is_ok();
        std::fs::write(root.join("release"), "").unwrap();
        let result = job.join().unwrap();
        assert!(entered, "fake gh must actually enter its read");
        assert!(engine_available, "network read must not hold Engine");
        assert!(result.is_ok(), "{result:?}");
        assert_eq!(std::fs::read_to_string(root.join("calls")).unwrap(), "x");

        let mut forged = scope.clone();
        forged["ledgerDirectory"] = json!(other);
        assert!(transport.call("github.write.prepare", forged).is_err());
        let mut wrong_root = scope.clone();
        wrong_root["expectedRoot"] = json!(other);
        assert!(transport.call("github.write.prepare", wrong_root).is_err());
        // A later stored-root edit invalidates the old UI scope even though
        // its expectedRoot still exists and is a valid directory.
        {
            let mut changed = thread.clone();
            changed["worktreePath"] = json!(other);
            engine.lock().unwrap().store.save(&changed).unwrap();
        }
        let mut history = scope;
        history.as_object_mut().unwrap().remove("expectedHead");
        assert!(transport.call("github.write.history", history).is_err());
        assert_eq!(std::fs::read_to_string(root.join("calls")).unwrap(), "x");
    }
}
