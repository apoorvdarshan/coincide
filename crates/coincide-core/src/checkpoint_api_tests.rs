//! Per-turn checkpoints and in-place rewind against the real Engine and Git.
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
            "-c",
            "core.autocrlf=false",
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
fn fixture() -> (tempfile::TempDir, Engine, String, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    // The Store's private continuation journal requires a private data folder.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let root = dir.path().join("repo");
    std::fs::create_dir(&root).unwrap();
    git(&root, &["init", "-q"]);
    // Git for Windows converts line endings on restore unless told not to.
    git(&root, &["config", "core.autocrlf", "false"]);
    std::fs::write(root.join("file.txt"), "original\n").unwrap();
    git(&root, &["add", "."]);
    git(&root, &["commit", "-qm", "fixture"]);
    let root = root.canonicalize().unwrap();
    let mut engine = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
    let thread = engine
        .execute("threads.create", &json!({"cwd":root}))
        .unwrap();
    (dir, engine, text(&thread, "id"), root)
}
fn item(kind: &str, body: &str) -> Value {
    json!({"id":Uuid::new_v4().to_string().to_uppercase(),"kind":kind,"text":body,"createdAt":swift_timestamp()})
}
fn seed(engine: &mut Engine, id: &str, items: &[Value]) {
    let mut thread = engine.store.thread(id).unwrap();
    thread["items"] = json!(items);
    thread["sessions"] = json!({"codex":{"id":"native-session","seenItemCount":items.len()}});
    engine.store.save(&thread).unwrap();
}
fn turns(engine: &mut Engine, id: &str) -> Vec<Value> {
    engine
        .execute("checkpoints.list", &json!({"threadId":id}))
        .unwrap()["turns"]
        .as_array()
        .unwrap()
        .clone()
}
/// Runs a turn's checkpoint lifecycle the way the provider worker and poll do.
fn run_turn(engine: &mut Engine, id: &str, user: &str, root: &Path, edit: impl FnOnce()) {
    let prelude = engine
        .prepare_turn_checkpoint(id, user, root)
        .expect("checkpoints are on by default");
    prelude();
    engine.poll_turn_checkpoints();
    assert_eq!(turns(engine, id)[0]["complete"], false);
    edit();
    engine.finish_turn_checkpoint(id);
    let deadline = Instant::now() + Duration::from_secs(60);
    while turns(engine, id)
        .iter()
        .all(|turn| turn["complete"] != true)
    {
        assert!(Instant::now() < deadline, "after checkpoint timed out");
        std::thread::sleep(Duration::from_millis(10));
        engine.poll_turn_checkpoints();
    }
}

#[test]
fn rewind_truncates_in_place_and_returns_the_message_to_the_draft() {
    let (_dir, mut engine, id, root) = fixture();
    let first = item("user", "first");
    let mut second = item("user", "second message");
    second["context"] = json!([{"kind":"quote","text":"quoted"}]);
    seed(
        &mut engine,
        &id,
        &[
            first.clone(),
            item("assistant", "one"),
            second.clone(),
            item("assistant", "two"),
        ],
    );
    let revision = engine.revision;
    let reply = engine
        .execute(
            "threads.rewind",
            &json!({"threadId":id,"itemId":second["id"],"revertFiles":false}),
        )
        .unwrap();
    assert_eq!(reply["filesRestored"], false);
    let stored = engine.store.thread(&id).unwrap();
    assert_eq!(stored, reply["thread"]);
    assert_eq!(stored["id"], id, "the same conversation, not a branch");
    assert_eq!(stored["items"].as_array().unwrap().len(), 2);
    assert_eq!(stored["items"][0]["id"], first["id"]);
    assert_eq!(stored["draft"], "second message");
    assert_eq!(stored["draftContext"], second["context"]);
    assert_eq!(stored["sessions"], json!({}));
    assert!(engine.revision > revision);
    assert_eq!(
        std::fs::read_to_string(root.join("file.txt")).unwrap(),
        "original\n"
    );
}

#[test]
fn only_settled_user_messages_can_be_rewound() {
    let (_dir, mut engine, id, _root) = fixture();
    let user = item("user", "hello");
    let reply = item("assistant", "hi");
    seed(&mut engine, &id, &[user.clone(), reply.clone()]);
    let error = engine
        .execute(
            "threads.rewind",
            &json!({"threadId":id,"itemId":reply["id"]}),
        )
        .unwrap_err();
    assert_eq!(error.to_string(), "Select a user message to edit");
    let session = Session::fixture_worker(|commands, _| {
        let _ = commands.recv();
    });
    engine.insert_running(
        id.clone(),
        Running {
            configuration: None,
            resume_safe: Arc::new(std::sync::atomic::AtomicBool::new(true)),
            usage_context: None,
            session,
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
    let error = engine
        .execute(
            "threads.rewind",
            &json!({"threadId":id,"itemId":user["id"]}),
        )
        .unwrap_err();
    assert_eq!(
        error.to_string(),
        "Stop the running turn before editing an earlier message"
    );
    engine.runs.get(&id).unwrap().session.stop();
    engine.runs.remove(&id);
    assert_eq!(
        engine.store.thread(&id).unwrap()["items"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
}

#[test]
fn turn_changes_are_listed_diffed_and_reverted_with_the_conversation() {
    let (_dir, mut engine, id, root) = fixture();
    let user = item("user", "change things");
    seed(&mut engine, &id, &[user.clone(), item("assistant", "done")]);
    let user_id = text(&user, "id");
    run_turn(&mut engine, &id, &user_id, &root, || {
        std::fs::write(root.join("file.txt"), "changed\n").unwrap();
        std::fs::write(root.join("new.txt"), "new\n").unwrap();
    });
    let listed = turns(&mut engine, &id);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0]["userItemID"], user["id"]);
    assert_eq!(
        listed[0]["files"],
        json!([
            {"path":"file.txt","status":"modified","additions":1,"deletions":1},
            {"path":"new.txt","status":"added","additions":1,"deletions":0},
        ])
    );
    let diff = engine
        .execute(
            "checkpoints.diff",
            &json!({"threadId":id,"userItemId":user_id}),
        )
        .unwrap();
    assert!(diff["diff"].as_str().unwrap().contains("+changed"));
    let one = engine
        .execute(
            "checkpoints.diff",
            &json!({"threadId":id,"userItemId":user_id,"path":"new.txt"}),
        )
        .unwrap();
    let one = one["diff"].as_str().unwrap();
    assert!(one.contains("new.txt") && !one.contains("file.txt"));
    assert!(
        engine
            .execute(
                "checkpoints.diff",
                &json!({"threadId":id,"userItemId":user_id,"path":"elsewhere.txt"}),
            )
            .is_err()
    );
    assert_eq!(
        engine
            .execute(
                "checkpoints.canRestore",
                &json!({"threadId":id,"userItemId":user_id})
            )
            .unwrap()["canRestore"],
        true
    );

    let reply = engine
        .execute(
            "threads.rewind",
            &json!({"threadId":id,"itemId":user_id,"revertFiles":true}),
        )
        .unwrap();
    assert_eq!(reply["filesRestored"], true);
    assert_eq!(
        std::fs::read_to_string(root.join("file.txt")).unwrap(),
        "original\n"
    );
    assert!(!root.join("new.txt").exists());
    let stored = engine.store.thread(&id).unwrap();
    assert_eq!(stored["items"], json!([]));
    assert_eq!(stored["draft"], "change things");
    assert!(turns(&mut engine, &id).is_empty());
    // The restored turn's snapshots are dropped with the history they describe.
    let deadline = Instant::now() + Duration::from_secs(30);
    while !git(&root, &["for-each-ref", "refs/coincide/checkpoints/"]).is_empty() {
        assert!(Instant::now() < deadline, "snapshot refs were not removed");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn files_are_not_restored_when_another_thread_worked_in_the_folder() {
    let (_dir, mut engine, id, root) = fixture();
    let user = item("user", "change");
    seed(&mut engine, &id, std::slice::from_ref(&user));
    let user_id = text(&user, "id");
    run_turn(&mut engine, &id, &user_id, &root, || {
        std::fs::write(root.join("file.txt"), "changed\n").unwrap();
    });
    let other = engine
        .execute("threads.create", &json!({"cwd":root}))
        .unwrap();
    let mut other = engine.store.thread(&text(&other, "id")).unwrap();
    other["updatedAt"] = json!(swift_timestamp() + 5.);
    engine.store.save(&other).unwrap();
    assert_eq!(
        engine
            .execute(
                "checkpoints.canRestore",
                &json!({"threadId":id,"userItemId":user_id})
            )
            .unwrap()["canRestore"],
        false
    );
    let error = engine
        .execute(
            "threads.rewind",
            &json!({"threadId":id,"itemId":user_id,"revertFiles":true}),
        )
        .unwrap_err();
    assert!(
        error
            .to_string()
            .starts_with("Another thread has worked in this folder")
    );
    assert_eq!(
        engine.store.thread(&id).unwrap()["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        std::fs::read_to_string(root.join("file.txt")).unwrap(),
        "changed\n"
    );
    // The conversation alone can still be rewound; files stay as they are.
    engine
        .execute("threads.rewind", &json!({"threadId":id,"itemId":user_id}))
        .unwrap();
    assert_eq!(
        std::fs::read_to_string(root.join("file.txt")).unwrap(),
        "changed\n"
    );
}

#[test]
fn checkpoints_follow_the_setting_and_skip_folders_outside_git() {
    let (dir, mut engine, id, root) = fixture();
    engine
        .store
        .save_document("settings.json", &json!({"checkpointsEnabled":false}))
        .unwrap();
    assert!(
        engine
            .prepare_turn_checkpoint(&id, &text(&item("user", "x"), "id"), &root)
            .is_none()
    );
    engine
        .store
        .save_document("settings.json", &json!({}))
        .unwrap();
    let plain = dir.path().join("plain");
    std::fs::create_dir(&plain).unwrap();
    let user = item("user", "outside git");
    seed(&mut engine, &id, std::slice::from_ref(&user));
    let prelude = engine
        .prepare_turn_checkpoint(&id, &text(&user, "id"), &plain)
        .unwrap();
    prelude();
    engine.finish_turn_checkpoint(&id);
    engine.poll_turn_checkpoints();
    assert!(turns(&mut engine, &id).is_empty());
}

#[test]
fn a_stop_during_the_prelude_ends_the_turn_without_launching_the_agent() {
    let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
    let (started_tx, started_rx) = std::sync::mpsc::channel::<()>();
    let session = Session::start_with_mode_policy_and_profile(
        Provider::Codex,
        Launch {
            executable: PathBuf::from("/nonexistent/coincide-fixture-provider"),
            cwd: std::env::temp_dir(),
            session: None,
            prompt: String::new(),
            model: None,
            variant: None,
        },
        Vec::new(),
        None,
        None,
        None,
        Some(Box::new(move || {
            started_tx.send(()).unwrap();
            let _ = release_rx.recv();
        })),
    );
    started_rx.recv().unwrap();
    session.stop();
    release_tx.send(()).unwrap();
    let event = session
        .events
        .recv_timeout(Duration::from_secs(30))
        .unwrap();
    assert!(matches!(event, Event::Finished), "{event:?}");
}
