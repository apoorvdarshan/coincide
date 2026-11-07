use super::*;

#[cfg(unix)]
fn fixture() -> (tempfile::TempDir, SharedEngine, PathBuf, String, String) {
    use std::os::unix::fs::PermissionsExt;
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().join("project");
    std::fs::create_dir(&root).unwrap();
    let root = root.canonicalize().unwrap();
    let gh = directory.path().join("gh");
    let response = json!({"number":7,"title":"Fixture PR","url":"https://github.com/owner/project/pull/7","state":"OPEN","isDraft":false,"headRefOid":"a".repeat(40),"headRefName":"feature","baseRefName":"main"});
    std::fs::write(
        &gh,
        format!(
            r#"#!/bin/sh
printf '%s\n' "$@" > argv.txt
test "$1" = pr || exit 3
if test "$2" = list; then
  printf '%s' '[{response}]'
else
  printf '%s' '{response}'
fi
"#
        ),
    )
    .unwrap();
    std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut engine = Engine::new(Store::open(&directory.path().join("data.sqlite")).unwrap());
    engine.github = GithubState::configured(Some(gh.as_os_str()), None);
    let engine = Arc::new(Mutex::new(engine));
    let project = call(&engine, "projects.create", json!({"path":root})).unwrap();
    let a = call(
        &engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    )
    .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let b = call(
        &engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    )
    .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    (directory, engine, root, a, b)
}

#[cfg(unix)]
fn wait(engine: &SharedEngine, owner: &str, root: &Path, operation: &Value) -> Value {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let value = call(
            engine,
            "github.result",
            json!({"threadId":owner,"expectedRoot":root,"operationId":operation}),
        )
        .unwrap();
        if value["ready"] == true {
            return value["result"].clone();
        }
        assert!(
            Instant::now() < deadline,
            "Fixture GitHub worker did not finish"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(unix)]
#[test]
fn public_engine_routes_bind_projects_threads_roots_and_full_heads() {
    let (directory, engine, root, owner, other) = fixture();
    // Constructing the Engine and inspecting capabilities must not run gh.
    let capabilities = call(&engine, "app.capabilities", json!({})).unwrap();
    assert!(
        METHODS
            .iter()
            .all(|method| capabilities.as_array().unwrap().contains(&json!(method)))
    );
    assert!(!root.join("argv.txt").exists());
    let start = call(
        &engine,
        "github.pr.list",
        json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project"}),
    )
    .unwrap();
    let operation = &start["operationId"];
    assert!(
        call(
            &engine,
            "github.result",
            json!({"threadId":other,"expectedRoot":root,"operationId":operation})
        )
        .is_err()
    );
    assert!(
        call(
            &engine,
            "github.result",
            json!({"threadId":owner,"expectedRoot":directory.path(),"operationId":operation})
        )
        .is_err()
    );
    let result = wait(&engine, &owner, &root, operation);
    assert_eq!(result["pullRequests"][0]["number"], 7);
    assert_eq!(result["threadId"], owner);
    assert!(
        call(
            &engine,
            "github.result",
            json!({"threadId":owner,"expectedRoot":root,"operationId":operation})
        )
        .is_err()
    );
    let args = std::fs::read_to_string(root.join("argv.txt")).unwrap();
    assert!(args.starts_with("pr\nlist\n--state\nopen\n"));
    assert!(args.ends_with("--repo\ngithub.com/owner/project\n"));
    let start = call(&engine, "github.pr.read", json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project","number":7,"expectedHead":"b".repeat(40)})).unwrap();
    assert_eq!(
        wait(&engine, &owner, &root, &start["operationId"])["code"],
        "head_changed"
    );
    let start = call(&engine, "github.pr.read", json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project","number":7,"expectedHead":"a".repeat(40)})).unwrap();
    assert_eq!(
        wait(&engine, &owner, &root, &start["operationId"])["pullRequest"]["headRefOid"],
        "a".repeat(40)
    );
}

#[cfg(unix)]
#[test]
fn invalid_requests_never_execute_or_override_authoritative_root() {
    let (directory, engine, root, owner, _) = fixture();
    for params in [
        json!({"threadId":owner,"expectedRoot":directory.path(),"repository":"owner/project"}),
        json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project","executable":"/bin/echo"}),
        json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project","cwd":directory.path()}),
        json!({"threadId":Uuid::new_v4().to_string(),"expectedRoot":root,"repository":"owner/project"}),
        json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project","involvement":null}),
        json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project","involvement":"mine"}),
        json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project","involvement":"review-requested:@me repo:other/repo"}),
        json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project","search":"review-requested:@me"}),
        json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project","author":"attacker"}),
    ] {
        assert!(call(&engine, "github.pr.list", params).is_err());
    }
    assert!(!root.join("argv.txt").exists());
    let mut unconfigured = engine.lock().unwrap();
    unconfigured.github = GithubState::configured(
        Some(OsStr::new("relative/gh")),
        Some(directory.path().as_os_str()),
    );
    drop(unconfigured);
    assert!(
        call(
            &engine,
            "github.pr.list",
            json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project"})
        )
        .unwrap_err()
        .to_string()
        .contains("absolute")
    );
    assert!(!root.join("argv.txt").exists());
}

#[cfg(unix)]
#[test]
fn background_activity_ends_when_worker_exits_even_without_collecting_result() {
    let (directory, engine, root, owner, _) = fixture();
    std::fs::write(directory.path().join("gh"), "#!/bin/sh\nprintf started > started\nwhile test ! -f release; do sleep 0.01; done\nprintf '[]'\n").unwrap();
    let operation = call(
        &engine,
        "github.pr.list",
        json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project"}),
    )
    .unwrap();
    let status = call(&engine, "host.awake.status", json!({})).unwrap();
    assert_eq!(status["requestedPolicy"]["backgroundJobs"], 1);
    assert_eq!(status["workerStarted"], false); // Opt-in disabled: no native helper.
    std::fs::write(root.join("release"), "release").unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let status = call(&engine, "host.awake.status", json!({})).unwrap();
        if status["requestedPolicy"]["backgroundJobs"] == 0 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "Completed worker retained its activity guard"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        wait(&engine, &owner, &root, &operation["operationId"])["pullRequests"],
        json!([])
    );
}

#[cfg(unix)]
#[test]
fn native_write_helpers_use_stored_root_and_the_read_services_original_executable() {
    let (directory, engine, root, owner, _) = fixture();
    let mut engine = engine.lock().unwrap();
    assert_eq!(engine.github_write_root(&owner).unwrap(), root);
    let configured = directory.path().join("gh").canonicalize().unwrap();
    assert_eq!(engine.github_cli_path().unwrap(), configured);
    assert!(engine.github_write_root("not-a-thread").is_err());
    assert!(
        engine
            .github_write_root(&Uuid::new_v4().to_string())
            .is_err()
    );
    // Discovery is captured, not silently substituted when installation changes.
    std::fs::remove_file(configured.clone()).unwrap();
    assert_eq!(engine.github_cli_path().unwrap(), configured);
    assert!(!root.join("argv.txt").exists());
    engine.shutdown = true;
    assert!(engine.github_write_root(&owner).is_err());
}

#[cfg(unix)]
#[test]
fn executable_discovery_is_metadata_only_and_explicit_invalid_never_falls_back() {
    let (directory, _engine, root, _, _) = fixture();
    assert!(resolve(None, Some(directory.path().as_os_str())).is_ok());
    assert!(
        resolve(
            Some(OsStr::new("/nonexistent/gh-fixture")),
            Some(directory.path().as_os_str())
        )
        .is_err()
    );
    assert!(resolve(Some(directory.path().as_os_str()), None).is_err());
    let file = directory.path().join("not-executable");
    std::fs::write(&file, "fixture").unwrap();
    assert!(resolve(Some(file.as_os_str()), None).is_err());
    assert!(!root.join("argv.txt").exists());
}

#[cfg(not(any(unix, windows)))]
#[test]
fn unavailable_platform_does_not_advertise_or_start_github() {
    let directory = tempfile::tempdir().unwrap();
    let engine = Arc::new(Mutex::new(Engine::new(
        Store::open(&directory.path().join("data.sqlite")).unwrap(),
    )));
    let capabilities = call(&engine, "app.capabilities", json!({})).unwrap();
    assert!(
        METHODS
            .iter()
            .all(|method| !capabilities.as_array().unwrap().contains(&json!(method)))
    );
    assert!(
        call(&engine, "github.pr.list", json!({}))
            .unwrap_err()
            .to_string()
            .contains("not supported")
    );
}

#[cfg(windows)]
#[test]
fn windows_missing_or_invalid_cli_does_not_fall_back_or_advertise() {
    let directory = tempfile::tempdir().unwrap();
    let missing = directory.path().join("missing-gh.exe");
    assert!(
        resolve(
            Some(missing.as_os_str()),
            Some(directory.path().as_os_str())
        )
        .is_err()
    );
    let invalid = directory.path().join("gh.exe");
    std::fs::write(&invalid, b"not a Windows executable").unwrap();
    assert!(resolve(Some(invalid.as_os_str()), None).is_err());
    let mut owner = Engine::new(Store::open(&directory.path().join("data.sqlite")).unwrap());
    owner.github = GithubState::configured(
        Some(missing.as_os_str()),
        Some(directory.path().as_os_str()),
    );
    assert!(owner.github_cli_path().is_err());
    let engine = Arc::new(Mutex::new(owner));
    let capabilities = call(&engine, "app.capabilities", json!({})).unwrap();
    assert!(
        METHODS
            .iter()
            .all(|method| !capabilities.as_array().unwrap().contains(&json!(method)))
    );
}

#[cfg(unix)]
#[test]
fn involvement_filter_actual_fake_cli_flags_and_bound_result() {
    let (_directory, engine, root, owner, _) = fixture();
    for (filter, flag, value) in [
        ("all", None, None),
        ("authored", Some("--author"), Some("@me")),
        ("assigned", Some("--assignee"), Some("@me")),
        (
            "review-requested",
            Some("--search"),
            Some("review-requested:@me"),
        ),
    ] {
        let operation=call(&engine,"github.pr.list",json!({"threadId":owner,"expectedRoot":root,"repository":"owner/project","involvement":filter})).unwrap();
        let result = wait(&engine, &owner, &root, &operation["operationId"]);
        assert_eq!(result["involvement"], filter);
        assert_eq!(result["state"], "open");
        assert_eq!(result["threadId"], owner);
        let argv = std::fs::read_to_string(root.join("argv.txt")).unwrap();
        let args = argv.lines().collect::<Vec<_>>();
        assert_eq!(
            &args[..6],
            &["pr", "list", "--state", "open", "--limit", "30"]
        );
        if let (Some(flag), Some(value)) = (flag, value) {
            assert_eq!(&args[8..10], &[flag, value]);
            assert_eq!(args.len(), 12);
        } else {
            assert_eq!(args.len(), 10);
        }
        assert_eq!(
            &args[args.len() - 2..],
            &["--repo", "github.com/owner/project"]
        );
    }
}

#[cfg(unix)]
#[test]
fn availability_route_derives_the_folder_and_binds_its_repository() {
    let (directory, engine, root, owner, other) = fixture();
    let availability = |thread: &str| {
        let reply = call(
            &engine,
            "github.pr.availability",
            json!({"threadId":thread}),
        )
        .unwrap();
        assert_eq!(reply["expectedRoot"], root.to_str().unwrap());
        wait(&engine, thread, &root, &reply["operationId"])
    };
    // The folder always comes from the stored thread, never the request.
    for params in [
        json!({"threadId":owner,"expectedRoot":root}),
        json!({"threadId":owner,"repository":"owner/project"}),
        json!({"threadId":Uuid::new_v4().to_string()}),
        json!({}),
    ] {
        assert!(call(&engine, "github.pr.availability", params).is_err());
    }
    let result = availability(&owner);
    assert_eq!(result["state"], "notRepository");
    assert_eq!(result["threadId"], owner);
    crate::workspace::git(&root, &["init", "-q"]).unwrap();
    let remote = [
        "remote",
        "add",
        "origin",
        "git@github.com:owner/project.git",
    ];
    crate::workspace::git(&root, &remote).unwrap();
    // The fixture CLI refuses everything but `pr`, so it reads as signed out.
    assert_eq!(availability(&owner)["state"], "needsGitHubCli");
    assert!(
        std::fs::read_to_string(root.join("argv.txt"))
            .unwrap()
            .starts_with("auth\nstatus\n--hostname\ngithub.com\n")
    );
    std::fs::write(
        directory.path().join("gh"),
        "#!/bin/sh\ntest \"$1\" = auth\n",
    )
    .unwrap();
    let result = availability(&other);
    assert_eq!(result["state"], "ready");
    assert_eq!(result["repository"], "owner/project");
    assert_eq!(result["threadId"], other);
    // A folder that is gone needs no worker, as Swift checks it before Git.
    std::fs::remove_dir_all(&root).unwrap();
    let reply = call(&engine, "github.pr.availability", json!({"threadId":owner})).unwrap();
    assert_eq!(
        reply,
        json!({"ready":true,"result":{"kind":"availability","threadId":owner,
            "state":"folderNotFound","path":root}})
    );
}
