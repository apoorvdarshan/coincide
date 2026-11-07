use super::*;
use crate::{api::Engine, store::Store};
use serde_json::json;
fn execute(engine: &mut Engine, method: &str, params: Value) -> Value {
    let value = engine.dispatch(json!({"method":method,"params":params}));
    assert!(value.get("error").is_none(), "{}", value);
    value["result"].clone()
}
pub(super) fn fixture() -> (tempfile::TempDir, Engine, PathBuf, String) {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source");
    fs::create_dir(&source).unwrap();
    fs::create_dir(source.join(".git")).unwrap();
    let mut engine = Engine::new(Store::open(&directory.path().join("data.sqlite")).unwrap());
    let project = execute(&mut engine, "projects.create", json!({"path":source}));
    let thread = execute(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    );
    (
        directory,
        engine,
        source,
        thread["id"].as_str().unwrap().into(),
    )
}
pub(super) fn source(engine: &mut Engine, root: &Path, id: &str) -> Source {
    engine
        .native_github_checkout_source(id, root, "fixture/repo", 7, &"a".repeat(40))
        .unwrap()
}
fn raw(path: &str, bytes: &[u8]) -> Vec<u8> {
    format!(
        "100644 blob {} {}\t{path}\0",
        blob_identity(bytes),
        bytes.len()
    )
    .into_bytes()
}
struct Blobs {
    bytes: Vec<u8>,
    calls: usize,
}
impl BlobReader for Blobs {
    fn read_blob(&mut self, _: &str, size: usize, permit: &ReadPermit<'_>) -> Result<Vec<u8>> {
        permit.check()?;
        self.calls += 1;
        ensure!(size <= MAX_BLOB, "fake bounded read");
        Ok(self.bytes.clone())
    }
}
#[test]
fn checkout_native_source_full_cas_and_no_json_admission() {
    let (_directory, mut engine, root, id) = fixture();
    let source = source(&mut engine, &root, &id);
    engine
        .native_validate_github_checkout_source(&source)
        .unwrap();
    let mut thread = engine.store.thread(&id).unwrap();
    thread["futureUnknown"] = json!({"keep":"changed"});
    thread["draft"] = json!("retained draft 中文");
    engine.store.save(&thread).unwrap();
    assert!(
        engine
            .native_validate_github_checkout_source(&source)
            .is_err()
    );
    assert_eq!(engine.store.thread(&id).unwrap(), thread);
    let denied=engine.dispatch(json!({"method":"github.pr.checkout","params":{"threadId":id,"native":true,"source":{},"confirmed":true}}));
    assert!(denied.get("error").is_some());
    assert!(fs::read_dir(source.storage).unwrap().all(|entry| {
        !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with("pr-checkout-")
    }));
}
#[test]
fn checkout_fixed_git_plan_never_accepts_remote_flags_or_shallow_import() {
    let (directory, mut engine, root, id) = fixture();
    let plan = Plan::prepare(source(&mut engine, &root, &id)).unwrap();
    let git = directory.path().join(if cfg!(windows) {
        "native git.exe"
    } else {
        "native git"
    });
    let gh = directory.path().join(if cfg!(windows) {
        "native 'gh; path.exe"
    } else {
        "native 'gh; path"
    });
    fs::write(&git, b"MZsynthetic executable").unwrap();
    fs::write(&gh, b"MZsynthetic executable").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&git, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&gh, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let tools = Tools::capture(&git, &gh, directory.path(), directory.path()).unwrap();
    let invocation = plan.invocation(&tools, Operation::FetchPull).unwrap();
    assert!(invocation.network());
    let arguments = invocation.arguments();
    let fetch = arguments.iter().position(|arg| arg == "fetch").unwrap();
    assert_eq!(
        &arguments[fetch..],
        &[
            "fetch",
            "--no-tags",
            "--no-recurse-submodules",
            "--no-write-fetch-head",
            "--",
            "https://github.com/fixture/repo",
            "+refs/pull/7/head:refs/coincide/pull/head"
        ]
    );
    assert!(!arguments.iter().any(|arg| arg.contains("--depth")
        || arg.contains("file://")
        || arg.contains("submodule.recurse=true")));
    assert!(arguments.iter().any(|arg| arg == "credential.helper="));
    assert!(arguments.iter().any(
        |arg| arg.starts_with("credential.helper=!'") && arg.ends_with("' auth git-credential")
    ));
    assert!(
        arguments
            .iter()
            .any(|arg| arg == "http.followRedirects=false")
    );
    assert!(
        invocation
            .environment()
            .iter()
            .any(|(key, value)| key == "GIT_CONFIG_NOSYSTEM" && value == "1")
    );
    assert!(!plan.review().destination.exists());
    for repo in [
        "https://github.com/a/b",
        "a/b?token=x",
        "a/b/extra",
        "-a/b",
        "a/..",
    ] {
        assert!(validate_repository(repo).is_err());
    }
    assert!(
        plan.invocation(&tools, Operation::Blob("HEAD:private".into()))
            .is_err()
    );
    #[cfg(unix)]
    {
        fs::write(&git, b"changed executable").unwrap();
        assert!(tools.validate().is_err());
    }
    #[cfg(windows)]
    {
        assert!(
            fs::write(&git, b"changed executable").is_err(),
            "Pinned executable must deny write/replace"
        );
        tools.validate().unwrap();
    }
}
#[test]
fn checkout_portable_tree_refuses_escape_alias_links_collisions_and_limits() {
    for path in [
        "../escape",
        "/absolute",
        "a/../../escape",
        ".git/config",
        "x/.GIT/config",
        "GIT~1/config",
        "a\\b",
        "CON",
        "x:stream",
        "x.",
        "x ",
        "a\nb",
        ".g\u{200c}it/config",
    ] {
        assert!(parse_tree(&raw(path, b"x")).is_err(), "{path}");
    }
    for mode in ["120000", "160000", "040000"] {
        let input = format!("{mode} blob {} 1\tfile\0", "a".repeat(40));
        assert!(parse_tree(input.as_bytes()).is_err());
    }
    let mut collision = raw("file", b"x");
    collision.extend(raw("FILE", b"x"));
    assert!(parse_tree(&collision).is_err());
    let mut collision = raw("directory", b"x");
    collision.extend(raw("directory/child", b"x"));
    assert!(parse_tree(&collision).is_err());
    assert!(
        parse_tree(format!("100644 blob {} {}\tlarge\0", "a".repeat(40), MAX_BLOB + 1).as_bytes())
            .is_err()
    );
    assert!(parse_tree(b"missing NUL").is_err());
    assert!(parse_tree(&raw(".github/workflows/ci.yml", b"x")).is_ok());
    assert!(parse_tree(&raw("Unicode/café.txt", b"x")).is_ok());
}
#[test]
fn checkout_materializes_actual_verified_bytes_and_retains_changed_failure() {
    let (_directory, mut engine, root, id) = fixture();
    let plan = Plan::prepare(source(&mut engine, &root, &id)).unwrap();
    let original = engine.store.thread(&id).unwrap();
    let content = "synthetic café 中文 🦀\n".as_bytes();
    let mut reader = Blobs {
        bytes: content.to_vec(),
        calls: 0,
    };
    let StageOutcome::Complete(tree) = plan
        .stage_regular_tree(
            &"a".repeat(40),
            &raw("nested/file.txt", content),
            &mut reader,
            &AtomicBool::new(false),
        )
        .unwrap()
    else {
        panic!("verified tree must complete")
    };
    assert!(tree.complete());
    assert_eq!(tree.file_count(), 1);
    assert_eq!(
        fs::read(tree.path().join("nested/file.txt")).unwrap(),
        content
    );
    assert!(!tree.path().join(".git").exists());
    assert_eq!(engine.store.thread(&id).unwrap(), original);
    assert_eq!(fs::read_dir(root.join(".git")).unwrap().count(), 0);
    // No automatic adoption or overwrite of an already materialized destination.
    assert!(
        plan.stage_regular_tree(
            &"a".repeat(40),
            &raw("nested/file.txt", content),
            &mut reader,
            &AtomicBool::new(false)
        )
        .is_err()
    );
    let second = Plan::prepare(source(&mut engine, &root, &id)).unwrap();
    let mut wrong = Blobs {
        bytes: b"different".to_vec(),
        calls: 0,
    };
    let StageOutcome::Retained { tree, reason } = second
        .stage_regular_tree(
            &"a".repeat(40),
            &raw("file", b"expected"),
            &mut wrong,
            &AtomicBool::new(false),
        )
        .unwrap()
    else {
        panic!("mismatched source must retain its private directory")
    };
    assert!(!tree.complete());
    assert!(tree.path().is_dir());
    assert!(reason.contains("source changed"));
    assert_eq!(wrong.calls, 1);
}
#[test]
fn checkout_cancel_stale_common_directory_and_no_follow_are_not_admitted() {
    let (directory, mut engine, root, id) = fixture();
    let plan = Plan::prepare(source(&mut engine, &root, &id)).unwrap();
    let mut reader = Blobs {
        bytes: b"x".to_vec(),
        calls: 0,
    };
    assert!(
        plan.stage_regular_tree(
            &"b".repeat(40),
            &raw("file", b"x"),
            &mut reader,
            &AtomicBool::new(false)
        )
        .is_err()
    );
    assert!(
        plan.stage_regular_tree(
            &"a".repeat(40),
            &raw("file", b"x"),
            &mut reader,
            &AtomicBool::new(true)
        )
        .is_err()
    );
    assert_eq!(reader.calls, 0);
    assert!(!plan.review().destination.exists());
    #[cfg(unix)]
    {
        fs::rename(root.join(".git"), root.join("old-git")).unwrap();
        fs::create_dir(root.join(".git")).unwrap();
        assert!(plan.check().is_err());
    }
    #[cfg(windows)]
    {
        assert!(
            fs::rename(root.join(".git"), root.join("old-git")).is_err(),
            "Pinned native directory must deny replacement"
        );
        plan.check().unwrap();
    }
    #[cfg(unix)]
    {
        let private = filesystem::Directory::pin(directory.path()).unwrap();
        let target = directory.path().join("outside");
        fs::write(&target, b"preserve").unwrap();
        std::os::unix::fs::symlink(&target, directory.path().join("link")).unwrap();
        assert!(private.create_file("link").is_err());
        assert_eq!(fs::read(target).unwrap(), b"preserve");
    }
}
