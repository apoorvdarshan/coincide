//! Git action and branch toolbar routes against the real Engine and a fixture repository.
use super::*;

fn git_in(root: &Path, args: &[&str]) {
    let status = std::process::Command::new("git")
        .args([
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
        ])
        .args(args)
        .current_dir(root)
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?}");
}

fn fixture() -> (tempfile::TempDir, Engine, String, String, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("repo");
    std::fs::create_dir(&root).unwrap();
    git_in(&root, &["init", "-q", "-b", "main"]);
    for (key, value) in [
        ("user.name", "Fixture"),
        ("user.email", "fixture@example.invalid"),
        ("commit.gpgSign", "false"),
    ] {
        git_in(&root, &["config", key, value]);
    }
    std::fs::write(root.join("readme.md"), "hello\n").unwrap();
    git_in(&root, &["add", "-A"]);
    git_in(&root, &["commit", "-q", "-m", "Initial"]);
    let mut store = Store::open(&dir.path().join("data/state.sqlite")).unwrap();
    let project = store.create_project(&root, Some("fixture")).unwrap();
    let project = project["id"].as_str().unwrap().to_owned();
    let first = text(&store.new_thread(&project).unwrap(), "id");
    let second = text(&store.new_thread(&project).unwrap(), "id");
    (
        dir,
        Engine::fixture(store),
        first,
        second,
        root.canonicalize().unwrap(),
    )
}

fn call(engine: &mut Engine, method: &str, params: Value) -> Value {
    let reply = engine.dispatch(json!({"id":"git","method":method,"params":params}));
    assert!(reply["error"].is_null(), "{method}: {reply}");
    reply["result"].clone()
}

fn complete(engine: &mut Engine, owner: &str, started: Value) -> Value {
    assert_eq!(started["resultMethod"], "git.actions.result");
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let reply = call(
            engine,
            "git.actions.result",
            json!({"threadId":owner,"operationId":started["operationId"]}),
        );
        if reply["ready"] == true {
            return reply["result"].clone();
        }
        assert!(Instant::now() < deadline, "Git fixture timed out");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn run(engine: &mut Engine, owner: &str, method: &str, params: Value) -> Value {
    let mut params = params;
    params["threadId"] = json!(owner);
    let started = call(engine, method, params);
    complete(engine, owner, started)
}

/// Lets queued discards and renames finish.
fn settle(engine: &mut Engine) {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        engine.git_actions.last_watch = Instant::now() - Duration::from_secs(2);
        engine.poll_git_actions();
        if engine.git_actions.pending.is_empty() {
            return;
        }
        assert!(Instant::now() < deadline, "Git fixture did not settle");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn bar_routes_commit_branch_and_follow_the_checkout() {
    let (_dir, mut engine, owner, _, root) = fixture();
    let status = run(&mut engine, &owner, "git.actions.status", json!({}));
    assert_eq!(status["status"]["branch"], "main");
    assert_eq!(status["changeRequestTerm"], "pullRequest");
    // An unstarted thread in the checkout follows the folder's branch.
    assert_eq!(engine.store.thread(&owner).unwrap()["branch"], "main");

    std::fs::write(root.join("notes.txt"), "one\n").unwrap();
    let committed = run(
        &mut engine,
        &owner,
        "git.actions.run",
        json!({"action":"commit","paths":["notes.txt"]}),
    );
    assert!(committed["error"].is_null(), "{committed}");
    assert_eq!(committed["result"]["commit"]["subject"], "Add notes.txt");
    assert_eq!(
        committed["result"]["followUp"],
        json!({"kind":"run","value":"push"})
    );

    let created = run(
        &mut engine,
        &owner,
        "git.branches.create",
        json!({"name":"topic one"}),
    );
    assert_eq!(created["branch"], "topic-one");
    assert_eq!(engine.store.thread(&owner).unwrap()["branch"], "topic-one");
    let listed = run(
        &mut engine,
        &owner,
        "git.branches.list",
        json!({"scope":"thread"}),
    );
    let first = &listed["branches"]["branches"][0];
    assert_eq!(
        (first["name"].as_str(), first["isCurrent"].as_bool()),
        (Some("topic-one"), Some(true))
    );
    let back = run(
        &mut engine,
        &owner,
        "git.branches.checkout",
        json!({"name":"main"}),
    );
    assert_eq!(back["branch"], "main");

    let failed = run(
        &mut engine,
        &owner,
        "git.actions.run",
        json!({"action":"push"}),
    );
    assert_eq!(
        failed["error"],
        "Cannot push because this repository has no remote."
    );
    let invalid = run(
        &mut engine,
        &owner,
        "git.branches.create",
        json!({"name":"bad..name"}),
    );
    assert_eq!(invalid["error"], "“bad..name” is not a valid branch name.");
    let unknown = engine.dispatch(
        json!({"method":"git.actions.run","params":{"threadId":owner,"action":"commit","cwd":"/"}}),
    );
    assert_eq!(unknown["error"]["message"], "Unknown Git parameter");
}

#[test]
fn toolbar_moves_unstarted_threads_between_checkout_and_worktrees() {
    let (dir, mut engine, owner, other, root) = fixture();
    let state = call(&mut engine, "git.toolbar.state", json!({"threadId":owner}));
    assert_eq!(
        state,
        json!({"baseBranch":null,"preparing":false,"previousWorktree":null})
    );

    let made = run(&mut engine, &owner, "git.worktrees.useNew", json!({}));
    assert!(made["error"].is_null(), "{made}");
    let thread = engine.store.thread(&owner).unwrap();
    let path = thread["worktreePath"].as_str().unwrap().to_owned();
    let branch = thread["branch"].as_str().unwrap().to_owned();
    assert!(
        path.starts_with(
            dir.path()
                .canonicalize()
                .unwrap()
                .join("data")
                .to_str()
                .unwrap()
        )
    );
    assert!(git::names::is_temporary_worktree_branch(
        &branch,
        "coincide/"
    ));
    assert!(Path::new(&path).join("readme.md").is_file());
    let state = call(&mut engine, "git.toolbar.state", json!({"threadId":owner}));
    assert_eq!(
        (state["baseBranch"].as_str(), state["preparing"].as_bool()),
        (Some("main"), Some(false))
    );

    // Another unstarted thread can reuse it, and returning to the checkout keeps a
    // worktree another thread is in.
    let state = call(&mut engine, "git.toolbar.state", json!({"threadId":other}));
    assert_eq!(state["previousWorktree"]["path"], path.as_str());
    let reused = run(
        &mut engine,
        &other,
        "git.worktrees.useExisting",
        json!({"path":path,"branch":branch}),
    );
    assert!(reused["error"].is_null(), "{reused}");
    assert_eq!(
        engine.store.thread(&other).unwrap()["worktreePath"],
        path.as_str()
    );
    let outside = run(
        &mut engine,
        &other,
        "git.worktrees.useExisting",
        json!({"path":dir.path()}),
    );
    assert_eq!(
        outside["error"],
        "That folder is not a worktree of this project."
    );
    call(
        &mut engine,
        "git.worktrees.useCheckout",
        json!({"threadId":owner}),
    );
    settle(&mut engine);
    assert!(engine.store.thread(&owner).unwrap()["worktreePath"].is_null());
    assert!(Path::new(&path).is_dir(), "kept for the thread using it");

    // The first message names the temporary branch for every thread in the worktree.
    let mut started = engine.store.thread(&other).unwrap();
    started["items"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id":"FIXTURE-ITEM","kind":"user","text":"Fix the parser"}));
    engine.store.save(&started).unwrap();
    settle(&mut engine);
    settle(&mut engine);
    assert_eq!(
        engine.store.thread(&other).unwrap()["branch"],
        "coincide/fix-parser"
    );
    let moved =
        engine.dispatch(json!({"method":"git.worktrees.useCheckout","params":{"threadId":other}}));
    assert_eq!(
        moved["error"]["message"],
        "A thread's workspace can only change before its first message"
    );

    // An unused worktree is removed when its thread goes back to the checkout.
    let made = run(
        &mut engine,
        &owner,
        "git.worktrees.useNew",
        json!({"baseBranch":"main"}),
    );
    assert!(made["error"].is_null(), "{made}");
    let unused = engine.store.thread(&owner).unwrap()["worktreePath"]
        .as_str()
        .unwrap()
        .to_owned();
    call(
        &mut engine,
        "git.worktrees.useCheckout",
        json!({"threadId":owner}),
    );
    settle(&mut engine);
    assert!(!Path::new(&unused).exists());
    assert!(root.join("readme.md").is_file());
}

#[test]
fn another_thread_cannot_consume_a_finished_git_result() {
    let (_dir, mut engine, owner, other, _) = fixture();
    let id = Uuid::new_v4().to_string();
    engine.git_actions.results.insert(
        id.clone(),
        (Instant::now(), json!({"_thread":owner,"value":"retained"})),
    );
    assert!(engine.git_actions_result(&other, &id).is_err());
    let reply = engine.git_actions_result(&owner, &id).unwrap();
    assert_eq!(reply, json!({"ready":true,"result":{"value":"retained"}}));
    assert!(engine.git_actions_result(&owner, &id).is_err());
}

#[test]
fn elapsed_time_does_not_release_an_unfinished_git_mutation() {
    let (_dir, mut engine, owner, _, _) = fixture();
    let id = Uuid::new_v4().to_string();
    engine.git_actions.mutating.insert(owner.clone());
    engine.git_actions.pending.insert(
        id.clone(),
        Pending {
            thread: owner.clone(),
            started: Instant::now() - OPERATION_LIFETIME - Duration::from_secs(1),
            progress: Arc::new(Mutex::new(String::new())),
            completion: Completion::None,
            mutation: true,
        },
    );
    engine.poll_git_actions();
    assert!(engine.git_actions.pending.contains_key(&id));
    assert!(engine.git_actions.mutating.contains(&owner));
    engine
        .git_actions
        .tx
        .send((id.clone(), json!({"done":true})))
        .unwrap();
    engine.poll_git_actions();
    assert!(!engine.git_actions.pending.contains_key(&id));
    assert!(!engine.git_actions.mutating.contains(&owner));
}
