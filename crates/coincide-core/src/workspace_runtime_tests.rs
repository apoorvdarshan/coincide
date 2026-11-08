//! Workspace dispatcher regressions against the real Engine.
use super::*;
use std::path::Path;

fn git(root: &Path, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args([
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "-c",
            "commit.gpgSign=false",
        ])
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().into()
}
fn fixture() -> (tempfile::TempDir, Engine, String, PathBuf, String) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("repo");
    std::fs::create_dir(&root).unwrap();
    git(&root, &["init", "-q"]);
    std::fs::write(root.join("file.txt"), "original\n").unwrap();
    git(&root, &["add", "."]);
    git(&root, &["commit", "-qm", "fixture"]);
    let head = git(&root, &["rev-parse", "HEAD"]);
    let mut store = Store::open(&dir.path().join("data.sqlite")).unwrap();
    let project = store.create_project(&root, Some("fixture")).unwrap();
    let thread = store.new_thread(project["id"].as_str().unwrap()).unwrap();
    (
        dir,
        Engine::new(store),
        thread["id"].as_str().unwrap().into(),
        root.canonicalize().unwrap(),
        head,
    )
}
fn call(engine: &mut Engine, method: &str, params: Value) -> Value {
    let reply = engine.dispatch(json!({"id":"fixture-request","method":method,"params":params}));
    assert_eq!(reply["id"], "fixture-request");
    reply
}
fn complete(engine: &mut Engine, owner: &str, reply: Value) -> Value {
    assert!(reply["error"].is_null(), "{reply}");
    assert_eq!(reply["result"]["resultMethod"], "git.workspace.result");
    let id = &reply["result"]["operationId"];
    let deadline = Instant::now() + Duration::from_secs(110);
    loop {
        let value = call(
            engine,
            "git.workspace.result",
            json!({"threadId":owner,"operationId":id}),
        );
        assert!(value["error"].is_null(), "{value}");
        if value["result"]["ready"] == true {
            return value["result"]["result"].clone();
        }
        assert!(Instant::now() < deadline, "fixture timed out");
        std::thread::sleep(Duration::from_millis(10));
    }
}
#[test]
fn checkpoint_routes_preserve_files_and_worktree_routes_reserve_in_app_storage() {
    let (dir, mut engine, owner, root, head) = fixture();
    std::fs::write(root.join("file.txt"), "staged\n").unwrap();
    git(&root, &["add", "."]);
    std::fs::write(root.join("file.txt"), "unstaged\n").unwrap();
    std::fs::write(root.join("untracked.txt"), "keep untracked\n").unwrap();
    let original_index = git(&root, &["write-tree"]);
    let original_status = git(&root, &["status", "--porcelain=v1", "-z"]);
    let reply = call(
        &mut engine,
        "git.checkpoints.create",
        json!({"threadId":owner,"expectedRoot":root,"expectedHead":head,"label":"Dispatch fixture"}),
    );
    let snapshot = complete(&mut engine, &owner, reply);
    assert!(snapshot["error"].is_null(), "{snapshot}");
    let reply = call(
        &mut engine,
        "git.checkpoints.list",
        json!({"threadId":owner,"expectedRoot":root}),
    );
    let list = complete(&mut engine, &owner, reply);
    assert_eq!(list["checkpoints"][0]["id"], snapshot["id"]);
    let reply = call(
        &mut engine,
        "git.checkpoints.diff",
        json!({"threadId":owner,"expectedRoot":root,"checkpointId":snapshot["id"]}),
    );
    let diff = complete(&mut engine, &owner, reply);
    assert!(diff["diff"].as_str().unwrap().contains("+staged"));
    assert_eq!(git(&root, &["rev-parse", "HEAD"]), head);
    assert_eq!(
        std::fs::read_to_string(root.join("file.txt")).unwrap(),
        "unstaged\n"
    );
    let reply = call(
        &mut engine,
        "git.worktrees.reserve",
        json!({"threadId":owner,"expectedRoot":root,"base":head,"name":"fixture-tree","branch":"fixture/dispatch"}),
    );
    let reserved = complete(&mut engine, &owner, reply);
    assert!(reserved["error"].is_null(), "{reserved}");
    let data = engine
        .store
        .data_directory()
        .unwrap()
        .canonicalize()
        .unwrap();
    let destination = Path::new(reserved["path"].as_str().unwrap());
    // Git uses ordinary drive/UNC syntax while Rust canonicalizes Windows paths
    // with a verbatim prefix. Compare the exact existing filesystem targets.
    assert_eq!(
        destination.canonicalize().unwrap(),
        data.join("worktrees/fixture-tree").canonicalize().unwrap()
    );
    assert_eq!(reserved["populated"], false);
    assert!(destination.join(".git").is_file());
    assert!(!destination.join("file.txt").exists());
    assert!(!destination.join("untracked.txt").exists());
    assert_eq!(git(destination, &["rev-parse", "HEAD"]), head);
    assert_eq!(
        git(destination, &["symbolic-ref", "HEAD"]),
        "refs/heads/fixture/dispatch"
    );
    assert_eq!(git(&root, &["rev-parse", "HEAD"]), head);
    assert_eq!(git(&root, &["write-tree"]), original_index);
    assert_eq!(
        git(&root, &["status", "--porcelain=v1", "-z"]),
        original_status
    );
    assert_eq!(std::fs::read(root.join("file.txt")).unwrap(), b"unstaged\n");
    assert_eq!(
        std::fs::read(root.join("untracked.txt")).unwrap(),
        b"keep untracked\n"
    );
    let reply = call(
        &mut engine,
        "git.worktrees.list",
        json!({"threadId":owner,"expectedRoot":root}),
    );
    assert_eq!(
        complete(&mut engine, &owner, reply)["worktrees"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert!(dir.path().exists());
}
#[test]
fn invalid_inputs_root_rebinding_busy_and_capacity_fail_before_dispatch() {
    let (_dir, mut engine, owner, root, head) = fixture();
    let params =
        json!({"threadId":owner,"expectedRoot":root,"expectedHead":head,"label":"fixture"});
    for (key, value) in [
        ("threadId", json!("missing")),
        ("expectedRoot", json!("/nonexistent-fixture-root")),
        ("expectedHead", json!("HEAD")),
        ("label", json!("x".repeat(501))),
        ("cwd", json!(root)),
    ] {
        let mut p = params.clone();
        p[key] = value;
        assert!(!call(&mut engine, "git.checkpoints.create", p)["error"].is_null());
        assert!(engine.workspace_pending.is_empty());
    }
    engine.runs.insert(
        owner.clone(),
        Running {
            configuration: None,
            resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
            usage_context: None,
            session: Session::start(Launch {
                executable: root.join("nonexistent-fixture-provider"),
                cwd: root.clone(),
                session: None,
                prompt: String::new(),
                model: None,
                variant: None,
            }),
            provider: "codex".into(),
            transcript_start: 0,
            pending: HashMap::new(),
            schedule_claim: None,
            queue_claim: None,
            cancelled: false,
            events: VecDeque::new(),
            persistence_error: None,
        },
    );
    // Bypass polling only for this guard: the intentionally missing executable
    // must never launch a provider, and its failure must not erase our busy state.
    assert!(
        engine
            .execute("git.checkpoints.create", &params)
            .unwrap_err()
            .to_string()
            .contains("active turn")
    );
    engine.runs.clear();
    engine.unsaved_threads.insert(owner.clone(), json!({}));
    assert!(!call(&mut engine, "git.checkpoints.create", params.clone())["error"].is_null());
    engine.unsaved_threads.clear();
    for index in 0..32 {
        engine
            .workspace_pending
            .insert(index.to_string(), (owner.clone(), Instant::now()));
    }
    assert!(
        !call(
            &mut engine,
            "git.checkpoints.list",
            json!({"threadId":owner,"expectedRoot":root})
        )["error"]
            .is_null()
    );
}
#[test]
fn results_are_owned_single_consumption_and_timeout_is_explicit() {
    let (_dir, mut engine, owner, _root, _head) = fixture();
    let other = engine
        .store
        .new_thread("00000000-0000-0000-0000-000000000000")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let id = Uuid::new_v4().to_string();
    engine.workspace_git_operations.insert(id.clone());
    engine
        .workspace_pending
        .insert(id.clone(), (owner.clone(), Instant::now()));
    engine
        .workspace_results
        .insert(id.clone(), json!({"fixture":true}));
    assert!(
        !call(
            &mut engine,
            "git.workspace.result",
            json!({"threadId":other,"operationId":id})
        )["error"]
            .is_null()
    );
    assert!(engine.workspace_results.contains_key(&id));
    assert_eq!(
        call(
            &mut engine,
            "git.workspace.result",
            json!({"threadId":owner,"operationId":id})
        )["result"]["result"]["fixture"],
        true
    );
    assert!(
        !call(
            &mut engine,
            "git.workspace.result",
            json!({"threadId":owner,"operationId":id})
        )["error"]
            .is_null()
    );
    engine.workspace_git_operations.insert(id.clone());
    engine.workspace_pending.insert(
        id.clone(),
        (owner.clone(), Instant::now() - Duration::from_secs(121)),
    );
    let timeout = call(
        &mut engine,
        "git.workspace.result",
        json!({"threadId":owner,"operationId":id}),
    );
    assert_eq!(timeout["result"]["ready"], true);
    assert!(!timeout["result"]["result"]["error"].is_null());
    assert!(!engine.workspace_pending.contains_key(&id));
}
#[test]
fn imported_threads_cannot_mutate_git_but_can_inspect() {
    let (dir, mut engine, owner, root, head) = fixture();
    let source = dir.path().join("legacy");
    std::fs::create_dir_all(source.join("threads")).unwrap();
    std::fs::write(
        source.join("threads/imported.json"),
        serde_json::to_vec(&engine.store.thread(&owner).unwrap()).unwrap(),
    )
    .unwrap();
    // Import into a separate database because imports reject colliding thread IDs.
    engine = Engine::new(Store::open(&dir.path().join("imported.sqlite")).unwrap());
    engine.store.import_legacy(&source).unwrap();
    let mut imported = engine.store.thread(&owner).unwrap();
    imported["worktreePath"] = json!(root);
    engine.store.save(&imported).unwrap();
    let denied = call(
        &mut engine,
        "git.checkpoints.create",
        json!({"threadId":owner,"expectedRoot":root,"expectedHead":head,"label":"deny"}),
    );
    assert!(
        denied["error"]["message"]
            .as_str()
            .unwrap()
            .contains("Fork")
    );
    let reply = call(
        &mut engine,
        "git.checkpoints.list",
        json!({"threadId":owner,"expectedRoot":root}),
    );
    assert_eq!(
        complete(&mut engine, &owner, reply)["checkpoints"],
        json!([])
    );
}

#[test]
fn stored_worktree_override_rejects_stale_project_root() {
    let (dir, mut engine, owner, root, _head) = fixture();
    let other = dir.path().join("other-repo");
    std::fs::create_dir(&other).unwrap();
    git(&other, &["init", "-q"]);
    let other = other.canonicalize().unwrap();
    let mut thread = engine.store.thread(&owner).unwrap();
    thread["worktreePath"] = json!(other);
    engine.store.save(&thread).unwrap();
    let denied = call(
        &mut engine,
        "git.checkpoints.list",
        json!({"threadId":owner,"expectedRoot":root}),
    );
    assert!(
        denied["error"]["message"]
            .as_str()
            .unwrap()
            .contains("changed")
    );
    assert!(engine.workspace_pending.is_empty());
    let reply = call(
        &mut engine,
        "git.checkpoints.list",
        json!({"threadId":owner,"expectedRoot":other}),
    );
    assert_eq!(
        complete(&mut engine, &owner, reply)["checkpoints"],
        json!([])
    );
}

#[test]
fn stale_head_and_invalid_worktree_names_fail_without_changing_git_state() {
    let (_dir, mut engine, owner, root, head) = fixture();
    let reply = call(
        &mut engine,
        "git.checkpoints.create",
        json!({"threadId":owner,"expectedRoot":root,"expectedHead":"0".repeat(40),"label":"stale"}),
    );
    assert!(
        complete(&mut engine, &owner, reply)["error"]
            .as_str()
            .unwrap()
            .contains("HEAD changed")
    );
    assert_eq!(git(&root, &["rev-parse", "HEAD"]), head);
    assert!(git(&root, &["for-each-ref", "refs/coincide/checkpoints/"]).is_empty());
    for name in ["../escape", "CON", "new/tree", "has space", "-option"] {
        let reply = call(
            &mut engine,
            "git.worktrees.reserve",
            json!({"threadId":owner,"expectedRoot":root,"base":head,"name":name,"branch":"fixture/rejected"}),
        );
        assert!(
            !complete(&mut engine, &owner, reply)["error"].is_null(),
            "{name}"
        );
    }
    assert!(git(&root, &["for-each-ref", "refs/heads/fixture/rejected"]).is_empty());
    assert_eq!(
        git(&root, &["worktree", "list", "--porcelain"])
            .matches("worktree ")
            .count(),
        1
    );
    let reply = call(
        &mut engine,
        "git.worktrees.reserve",
        json!({"threadId":owner,"expectedRoot":root,"base":head,"name":"safe","branch":"fixture/safe","parentPath":root.parent()}),
    );
    assert!(!reply["error"].is_null());
    assert!(engine.workspace_pending.is_empty());
}

#[cfg(unix)]
#[test]
fn symlinked_worktree_storage_is_refused_without_touching_target() {
    let (dir, mut engine, owner, root, head) = fixture();
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("sentinel"), "preserve").unwrap();
    std::os::unix::fs::symlink(outside.path(), dir.path().join("worktrees")).unwrap();
    let reply = call(
        &mut engine,
        "git.worktrees.reserve",
        json!({"threadId":owner,"expectedRoot":root,"base":head,"name":"fixture-tree","branch":"fixture/denied"}),
    );
    assert!(
        complete(&mut engine, &owner, reply)["error"]
            .as_str()
            .unwrap()
            .contains("real directory")
    );
    assert_eq!(
        std::fs::read_to_string(outside.path().join("sentinel")).unwrap(),
        "preserve"
    );
    assert!(!outside.path().join("fixture-tree").exists());
    assert!(git(&root, &["for-each-ref", "refs/heads/fixture/denied"]).is_empty());
}

fn synthetic_mutation(engine: &mut Engine, owner: &str, age: Duration) -> String {
    let id = Uuid::new_v4().to_string();
    engine
        .workspace_pending
        .insert(id.clone(), (owner.into(), Instant::now() - age));
    engine.workspace_git_operations.insert(id.clone());
    engine.workspace_mutations.insert(id.clone());
    id
}

#[test]
fn mutation_timeout_keeps_exclusion_until_worker_completion_and_types_result_routes() {
    let (_dir, mut engine, owner, root, head) = fixture();
    let id = synthetic_mutation(&mut engine, &owner, Duration::from_secs(121));
    let query = json!({"threadId":owner,"operationId":id});
    assert!(
        engine
            .execute("workspace.result", &query)
            .unwrap_err()
            .to_string()
            .contains("Use git.workspace.result")
    );
    assert!(engine.workspace_pending.contains_key(&id));
    let timeout = engine.execute("git.workspace.result", &query).unwrap();
    assert_eq!(timeout["ready"], true);
    assert!(
        timeout["result"]["error"]
            .as_str()
            .unwrap()
            .contains("still be running")
    );
    assert!(!engine.workspace_pending.contains_key(&id));
    assert!(engine.workspace_mutations.contains(&id));
    let retry = json!({"threadId":owner,"expectedRoot":root,"expectedHead":head,"label":"retry"});
    assert!(
        engine
            .execute("git.checkpoints.create", &retry)
            .unwrap_err()
            .to_string()
            .contains("still running")
    );
    engine
        .workspace_tx
        .send((id.clone(), json!({"completed":true})))
        .unwrap();
    engine.poll();
    assert!(!engine.workspace_mutations.contains(&id));
    assert!(
        !engine.workspace_results.contains_key(&id),
        "expired results stay bounded"
    );
    let retry = engine.execute("git.checkpoints.create", &retry).unwrap();
    let result = complete(&mut engine, &owner, json!({"result":retry}));
    assert!(result["error"].is_null(), "{result}");

    let legacy = Uuid::new_v4().to_string();
    engine
        .workspace_pending
        .insert(legacy.clone(), (owner.clone(), Instant::now()));
    engine
        .workspace_results
        .insert(legacy.clone(), json!({"legacy":true}));
    let query = json!({"threadId":owner,"operationId":legacy});
    assert!(
        engine
            .execute("git.workspace.result", &query)
            .unwrap_err()
            .to_string()
            .contains("Use workspace.result")
    );
    assert_eq!(
        engine.execute("workspace.result", &query).unwrap()["result"]["legacy"],
        true
    );
}

#[test]
fn abandoned_mutation_expiry_does_not_release_running_work() {
    let (_dir, mut engine, owner, root, head) = fixture();
    let id = synthetic_mutation(&mut engine, &owner, Duration::from_secs(301));
    engine.poll();
    assert!(!engine.workspace_pending.contains_key(&id));
    assert!(!engine.workspace_git_operations.contains(&id));
    assert!(engine.workspace_mutations.contains(&id));
    let retry = json!({"threadId":owner,"expectedRoot":root,"expectedHead":head,"label":"retry"});
    assert!(
        engine
            .execute("git.checkpoints.create", &retry)
            .unwrap_err()
            .to_string()
            .contains("still running")
    );
    engine
        .workspace_tx
        .send((id.clone(), json!({"error":"worker failed"})))
        .unwrap();
    engine.poll();
    assert!(engine.workspace_mutations.is_empty());
    assert!(engine.workspace_results.is_empty());
}

#[test]
fn full_result_channel_preserves_mutation_completion_and_releases_after_poll() {
    let (_dir, mut engine, owner, _root, _head) = fixture();
    // Replace discovery's channel so capacity is deterministic without waiting
    // for or modifying the real discovery worker/environment.
    let (tx, rx) = std::sync::mpsc::sync_channel(32);
    engine.workspace_tx = tx.clone();
    engine.workspace_rx = rx;
    for index in 0..32 {
        tx.try_send((format!("unrelated-{index}"), json!({})))
            .unwrap();
    }
    let id = synthetic_mutation(&mut engine, &owner, Duration::ZERO);
    let operation = id.clone();
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        workspace_api::publish_completion(tx, operation, json!({"completed":true}));
        done_tx.send(()).unwrap();
    });
    assert_eq!(
        done_rx.recv_timeout(Duration::from_millis(50)),
        Err(std::sync::mpsc::RecvTimeoutError::Timeout)
    );
    assert!(engine.workspace_mutations.contains(&id));
    engine.poll();
    done_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    worker.join().unwrap();
    engine.poll();
    assert!(!engine.workspace_mutations.contains(&id));
    let result = engine
        .execute(
            "git.workspace.result",
            &json!({"threadId":owner,"operationId":id}),
        )
        .unwrap();
    assert_eq!(result["result"]["completed"], true);
    assert!(engine.workspace_pending.is_empty());
    assert!(engine.workspace_git_operations.is_empty());
}
#[test]
fn review_diff_route_validates_scope_and_reads_untracked_changes() {
    let (_dir, mut engine, owner, root, _) = fixture();
    std::fs::write(root.join("file.txt"), "original\nchanged\n").unwrap();
    std::fs::write(root.join("new.txt"), "fresh\n").unwrap();
    let status = git(&root, &["status", "--porcelain=v1", "-z"]);
    for params in [
        json!({"threadId":owner,"expectedRoot":root,"scope":"turn"}),
        json!({"threadId":owner,"expectedRoot":root,"ignoreWhitespace":1}),
        json!({"threadId":owner,"expectedRoot":root,"path":"file.txt"}),
    ] {
        let reply = call(&mut engine, "git.review.diff", params);
        assert!(!reply["error"].is_null(), "{reply}");
    }
    assert!(engine.workspace_pending.is_empty());
    let reply = call(
        &mut engine,
        "git.review.diff",
        json!({"threadId":owner,"expectedRoot":root,"scope":"uncommitted","ignoreWhitespace":false}),
    );
    let review = complete(&mut engine, &owner, reply);
    let crate::workspace_diff::Review::Diff { diff, .. } =
        crate::workspace_diff::decode(&review).unwrap()
    else {
        panic!("fixture is a repository");
    };
    assert_eq!(
        diff.files
            .iter()
            .map(|file| (file.path.as_str(), file.status))
            .collect::<Vec<_>>(),
        [
            ("file.txt", crate::workspace_diff::ChangeStatus::Modified),
            ("new.txt", crate::workspace_diff::ChangeStatus::Untracked),
        ]
    );
    assert_eq!(git(&root, &["status", "--porcelain=v1", "-z"]), status);
}

#[test]
fn merged_git_runner_preserves_raw_exit_status_and_authorized_output_cuts() {
    use crate::workspace::{GitOptions, GitRequest, git_output, git_with};
    let (_dir, _engine, _thread, root, _) = fixture();
    std::fs::write(root.join("large.txt"), vec![b'x'; 128 * 1024]).unwrap();
    git(&root, &["add", "large.txt"]);
    git(&root, &["commit", "-qm", "bounded output fixture"]);
    let args = ["show", "HEAD:large.txt"];
    let raw = git_output(
        &root,
        &args,
        &GitRequest {
            max_output: 1024,
            ..Default::default()
        },
    )
    .unwrap();
    assert!(raw.success);
    assert!(raw.overflowed);
    assert!(!raw.truncated);
    assert_eq!(raw.stdout.len(), 1025);
    let (bytes, cut) = git_with(
        &root,
        &args,
        &GitOptions {
            max_output: 1024,
            truncate: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert!(cut);
    assert_eq!(bytes, vec![b'x'; 1024]);
    assert!(
        git_with(
            &root,
            &args,
            &GitOptions {
                max_output: 1024,
                ..Default::default()
            }
        )
        .is_err()
    );
    let missing = git_output(
        &root,
        &["rev-parse", "--verify", "refs/heads/absent-private-fixture"],
        &GitRequest::default(),
    )
    .unwrap();
    assert!(!missing.success);
    assert!(missing.code.is_some_and(|code| code != 0));
    assert!(!missing.stderr.is_empty());
}
