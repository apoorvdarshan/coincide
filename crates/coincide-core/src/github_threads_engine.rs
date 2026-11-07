//! Engine integration for scoped, read-only inline review data. Only stored
//! project/thread roots and the host's configured gh executable reach the service.
use super::*;
use crate::{github_api::GhRunner, github_threads::GithubThreadsService};

pub(super) const METHODS: &[&str] = &[
    "github.threads.list",
    "github.threads.comments",
    "github.threads.result",
    "github.threads.cancel",
];
#[derive(Default)]
pub(super) struct State {
    service: Option<GithubThreadsService>,
    closed: bool,
}
impl State {
    pub(super) fn request_shutdown(&mut self) {
        self.closed = true;
        if let Some(service) = &mut self.service {
            service.request_shutdown();
        }
    }
    pub(super) fn shutdown_status(&mut self) -> crate::github_api::ReadShutdownStatus {
        self.service.as_mut().map_or(
            crate::github_api::ReadShutdownStatus {
                closed: self.closed,
                ..Default::default()
            },
            GithubThreadsService::shutdown_status,
        )
    }
}
impl Engine {
    pub(super) fn github_threads_command(&mut self, method: &str, params: &Value) -> Result<Value> {
        ensure!(
            !self.github_threads.closed,
            "GitHub reads are shutting down"
        );
        ensure!(
            cfg!(any(unix, windows)),
            "Inline GitHub review reads are not supported on this platform"
        );
        ensure!(!self.shutdown, "Application is shutting down");
        let keys: &[&str] = match method {
            "github.threads.list" => &[
                "threadId",
                "expectedRoot",
                "repository",
                "number",
                "expectedHead",
                "cursor",
            ],
            "github.threads.comments" => &[
                "threadId",
                "expectedRoot",
                "repository",
                "number",
                "expectedHead",
                "cursor",
                "reviewThreadId",
            ],
            "github.threads.result" | "github.threads.cancel" => &[
                "threadId",
                "expectedRoot",
                "repository",
                "number",
                "expectedHead",
                "operationId",
            ],
            _ => bail!("Unsupported inline GitHub review method"),
        };
        let object = params
            .as_object()
            .context("Inline review parameters must be an object")?;
        ensure!(
            object.keys().all(|key| keys.contains(&key.as_str())),
            "Unsupported inline review parameter"
        );
        let thread = required(params, "threadId")?;
        Uuid::parse_str(thread).context("Invalid thread ID")?;
        let root = self.working_directory(&self.store.thread(thread)?)?;
        // Strict scope validation precedes lazy host configuration and worker
        // creation. Agent JSON never supplies an executable or stored root.
        let scope: crate::github_threads::Scope = serde_json::from_value(params.clone())?;
        scope.validate()?;
        if matches!(method, "github.threads.result" | "github.threads.cancel") {
            Uuid::parse_str(required(params, "operationId")?)
                .context("Invalid inline review operation ID")?;
        }
        if self.github_threads.service.is_none() {
            let runner = GhRunner::new(self.github_cli_path()?)?;
            self.github_threads.service = Some(GithubThreadsService::new(runner));
        }
        let service = self
            .github_threads
            .service
            .as_mut()
            .context("Inline review service unavailable")?;
        // start validates local binding and schedules capture; it never waits
        // for gh. The subprocess runs on the service-owned worker, not under
        // the Engine/UI lock. result/cancel perform bounded local collection.
        match method {
            "github.threads.result" => service.result(thread, &root, params),
            "github.threads.cancel" => service.cancel(thread, &root, params),
            _ => service.start(thread, &root, method, params),
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{os::unix::fs::PermissionsExt, path::Path};
    struct Fixture {
        dir: tempfile::TempDir,
        engine: Engine,
        root: PathBuf,
        owner: String,
        other: String,
    }
    fn fixture(slow: bool) -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("project");
        std::fs::create_dir(&root).unwrap();
        let root = root.canonicalize().unwrap();
        let pr = json!({"number":7,"url":"https://github.com/owner/project/pull/7","headRefOid":"a".repeat(40),"repository":{"nameWithOwner":"owner/project"}});
        let connection = json!({"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}});
        let mut listed = pr.clone();
        listed["reviewThreads"] = json!({"nodes":[{"id":"thread-fixture","path":"src/fixture.rs","line":4,"startLine":null,"originalLine":4,"diffSide":"RIGHT","isResolved":false,"isOutdated":false,"resolvedBy":null,"comments":connection}],"pageInfo":{"hasNextPage":false,"endCursor":null}});
        let list = json!({"data":{"repository":{"pullRequest":listed}}});
        let comments =
            json!({"data":{"node":{"id":"thread-fixture","pullRequest":pr,"comments":connection}}});
        let gh = dir.path().join("fake-gh");
        let delay = if slow { "sleep 5" } else { "" };
        std::fs::write(
            &gh,
            format!(
                r#"#!/bin/sh
printf '%s\n' "$@" >> argv.txt
printf 'started' > started.txt
{delay}
case "$*" in
  *CoincideReviewComments*) printf '%s' '{comments}' ;;
  *) printf '%s' '{list}' ;;
esac
printf 'completed' > completed.txt
"#
            ),
        )
        .unwrap();
        std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        engine.github_threads.service = Some(GithubThreadsService::new(GhRunner::new(gh).unwrap()));
        let project = engine
            .execute("projects.create", &json!({"path":root}))
            .unwrap();
        let owner = text(
            &engine
                .execute("threads.create", &json!({"projectId":project["id"]}))
                .unwrap(),
            "id",
        );
        let other = text(
            &engine
                .execute("threads.create", &json!({"projectId":project["id"]}))
                .unwrap(),
            "id",
        );
        Fixture {
            dir,
            engine,
            root,
            owner,
            other,
        }
    }
    fn params(thread: &str, root: &Path) -> Value {
        json!({"threadId":thread,"expectedRoot":root,"repository":"owner/project","number":7,"expectedHead":"a".repeat(40)})
    }
    fn wait(engine: &mut Engine, params: &Value) -> Value {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let result = engine.execute("github.threads.result", params).unwrap();
            if result["ready"] == true {
                return result["result"].clone();
            }
            assert!(Instant::now() < deadline, "synthetic thread read timed out");
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    #[test]
    fn public_routes_list_comment_pages_and_keep_full_scope_without_state_mutations() {
        let mut f = fixture(false);
        let scope = params(&f.owner, &f.root);
        let before = f.engine.store.thread(&f.owner).unwrap();
        let revision = f.engine.revision;
        let advertised = f.engine.execute("app.capabilities", &json!({})).unwrap();
        assert!(
            METHODS
                .iter()
                .all(|method| advertised.as_array().unwrap().contains(&json!(method)))
        );
        assert!(!f.root.join("argv.txt").exists());
        let start = f.engine.execute("github.threads.list", &scope).unwrap();
        let mut operation = scope.clone();
        operation["operationId"] = start["operationId"].clone();
        let page = wait(&mut f.engine, &operation);
        assert_eq!(page["kind"], "threads");
        assert_eq!(page["threadId"], f.owner);
        assert_eq!(page["expectedRoot"], json!(f.root));
        assert_eq!(page["threads"][0]["id"], "thread-fixture");
        assert_eq!(
            wait(&mut f.engine, &operation),
            page,
            "results are nonconsuming"
        );
        let mut comments = scope.clone();
        comments["reviewThreadId"] = json!("thread-fixture");
        let start = f
            .engine
            .execute("github.threads.comments", &comments)
            .unwrap();
        operation["operationId"] = start["operationId"].clone();
        let page = wait(&mut f.engine, &operation);
        assert_eq!(page["kind"], "comments");
        assert_eq!(page["reviewThreadId"], "thread-fixture");
        assert_eq!(f.engine.store.thread(&f.owner).unwrap(), before);
        assert_eq!(f.engine.revision, revision);
        let argv = std::fs::read_to_string(f.root.join("argv.txt")).unwrap();
        assert!(argv.contains("CoincideReviewThreads"));
        assert!(argv.contains("CoincideReviewComments"));
        assert!(argv.starts_with("api\ngraphql\n--hostname\ngithub.com\n--method\nPOST\n"));
        assert!(!argv.contains("mutation "));
        assert!(f.dir.path().exists());
    }
    #[test]
    fn invalid_scope_unknown_fields_and_foreign_operations_never_override_stored_root() {
        let mut f = fixture(false);
        let scope = params(&f.owner, &f.root);
        for (key, value) in [
            ("cwd", json!(f.dir.path())),
            ("executable", json!("/untrusted")),
            ("expectedHead", json!("short")),
            ("expectedRoot", json!(f.dir.path())),
            ("repository", json!("--repo")),
            ("threadId", json!("missing")),
        ] {
            let mut bad = scope.clone();
            bad[key] = value;
            assert!(
                f.engine.execute("github.threads.list", &bad).is_err(),
                "accepted {bad}"
            );
        }
        let mut comments = scope.clone();
        comments["reviewThreadId"] = json!("unknown-thread");
        assert!(
            f.engine
                .execute("github.threads.comments", &comments)
                .is_err()
        );
        assert!(!f.root.join("argv.txt").exists());
        let start = f.engine.execute("github.threads.list", &scope).unwrap();
        let mut foreign = params(&f.other, &f.root);
        foreign["operationId"] = start["operationId"].clone();
        assert!(f.engine.execute("github.threads.result", &foreign).is_err());
        assert!(f.engine.execute("github.threads.cancel", &foreign).is_err());
        let mut valid = scope;
        valid["operationId"] = start["operationId"].clone();
        assert_eq!(wait(&mut f.engine, &valid)["kind"], "threads");
    }
    #[test]
    fn slow_capture_runs_outside_engine_and_can_be_cancelled_without_waiting_for_gh() {
        let mut f = fixture(true);
        let scope = params(&f.owner, &f.root);
        let start = f.engine.execute("github.threads.list", &scope).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while !f.root.join("started.txt").exists() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
        // The fixture is still blocked in its subprocess while ordinary Engine
        // requests remain usable. No capture wait runs in the dispatch call.
        assert!(!f.root.join("completed.txt").exists());
        assert!(f.engine.execute("app.status", &json!({})).is_ok());
        let mut operation = scope;
        operation["operationId"] = start["operationId"].clone();
        assert_eq!(
            f.engine
                .execute("github.threads.cancel", &operation)
                .unwrap()["cancelled"],
            true
        );
        assert_eq!(wait(&mut f.engine, &operation)["code"], "cancelled");
        std::thread::sleep(Duration::from_millis(100));
        assert!(!f.root.join("completed.txt").exists());
    }
    #[test]
    fn results_revalidate_changed_authoritative_stored_root_and_shutdown_rejects() {
        let mut f = fixture(false);
        let scope = params(&f.owner, &f.root);
        let start = f.engine.execute("github.threads.list", &scope).unwrap();
        let mut operation = scope;
        operation["operationId"] = start["operationId"].clone();
        let replacement = f.dir.path().join("replacement");
        std::fs::create_dir(&replacement).unwrap();
        let mut thread = f.engine.store.thread(&f.owner).unwrap();
        thread["worktreePath"] = json!(replacement);
        f.engine.store.save(&thread).unwrap();
        assert!(
            f.engine
                .execute("github.threads.result", &operation)
                .is_err()
        );
        f.engine.shutdown = true;
        assert!(
            f.engine
                .execute("github.threads.list", &params(&f.owner, &f.root))
                .is_err()
        );
    }
}
