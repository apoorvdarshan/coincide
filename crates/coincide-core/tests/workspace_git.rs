use coincide_core::{workspace, workspace_git as git};
use std::{path::Path, process::Command};

fn run(root: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
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
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}
fn repo() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    run(dir.path(), &["init", "-q"]);
    run(dir.path(), &["config", "user.name", "Fixture"]);
    run(
        dir.path(),
        &["config", "user.email", "fixture@example.invalid"],
    );
    std::fs::write(dir.path().join("[literal].txt"), "original\n").unwrap();
    run(dir.path(), &["add", "."]);
    run(dir.path(), &["commit", "-qm", "initial"]);
    dir
}

#[test]
fn staged_checkpoint_preserves_index_head_and_unstaged_work() {
    let dir = repo();
    let root = dir.path();
    let head = run(root, &["rev-parse", "HEAD"]);
    std::fs::write(root.join("[literal].txt"), "staged\n").unwrap();
    run(root, &["add", "."]);
    std::fs::write(root.join("[literal].txt"), "unstaged\n").unwrap();
    std::fs::write(root.join("untracked"), "private untracked\n").unwrap();
    let index = run(root, &["write-tree"]);
    let before = workspace::status(root).unwrap();
    let checkpoint = git::create_checkpoint(root, &head, "fixture staged snapshot").unwrap();
    assert_eq!(run(root, &["rev-parse", "HEAD"]), head);
    assert_eq!(run(root, &["write-tree"]), index);
    assert_eq!(workspace::status(root).unwrap(), before);
    assert_eq!(
        std::fs::read_to_string(root.join("[literal].txt")).unwrap(),
        "unstaged\n"
    );
    let id = checkpoint["id"].as_str().unwrap();
    let diff = git::checkpoint_diff(root, id).unwrap();
    assert!(diff["diff"].as_str().unwrap().contains("+staged"));
    assert!(!diff["diff"].as_str().unwrap().contains("unstaged"));
    assert!(!diff["diff"].as_str().unwrap().contains("private untracked"));
    assert_eq!(git::checkpoints(root).unwrap()["checkpoints"][0]["id"], id);
    assert!(git::create_checkpoint(root, &"0".repeat(40), "stale").is_err());
    assert!(git::checkpoint_diff(root, "../../HEAD").is_err());
}

#[test]
fn worktree_reservation_is_exact_and_does_not_touch_source_or_existing_paths() {
    let dir = repo();
    let root = dir.path();
    let parent = tempfile::tempdir().unwrap();
    let head = run(root, &["rev-parse", "HEAD"]);
    let before = workspace::status(root).unwrap();
    let result =
        git::create_worktree(root, parent.path(), "new-tree", "feature/fixture", &head).unwrap();
    let destination = Path::new(result["path"].as_str().unwrap());
    assert_eq!(run(destination, &["rev-parse", "HEAD"]), head);
    assert!(!destination.join("[literal].txt").exists());
    assert_eq!(workspace::status(root).unwrap(), before);
    assert_eq!(
        git::worktrees(root).unwrap()["worktrees"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert!(git::create_worktree(root, parent.path(), "new-tree", "other", &head).is_err());
    assert!(git::create_worktree(root, parent.path(), "../escape", "other", &head).is_err());
    assert!(git::create_worktree(root, root, "nested", "other", &head).is_err());
    assert!(
        git::create_worktree(root, parent.path(), "another", "feature/fixture", &head).is_err()
    );
    assert!(!parent.path().join("another").exists());
    for bad in ["-x", "../x", "x..y", "HEAD@{1}", "x\ny", "x.lock"] {
        assert!(git::validate_branch(root, bad).is_err(), "{bad}");
    }
}

#[test]
fn unmerged_index_cannot_be_checkpointed() {
    let dir = repo();
    let root = dir.path();
    run(root, &["checkout", "-qb", "side"]);
    std::fs::write(root.join("[literal].txt"), "side\n").unwrap();
    run(root, &["commit", "-qam", "side"]);
    run(root, &["checkout", "-qb", "other", "HEAD^"]);
    std::fs::write(root.join("[literal].txt"), "other\n").unwrap();
    run(root, &["commit", "-qam", "other"]);
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["merge", "side"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    let head = run(root, &["rev-parse", "HEAD"]);
    assert!(git::create_checkpoint(root, &head, "conflict").is_err());
    assert!(
        git::checkpoints(root).unwrap()["checkpoints"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[cfg(unix)]
#[test]
fn checkpoint_does_not_execute_reference_transaction_hooks() {
    use std::os::unix::fs::PermissionsExt;
    let dir = repo();
    let root = dir.path();
    let hooks = root.join(".git/hooks");
    let hook = hooks.join("reference-transaction");
    std::fs::write(&hook, "#!/bin/sh\nexit 99\n").unwrap();
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o700)).unwrap();
    let head = run(root, &["rev-parse", "HEAD"]);
    git::create_checkpoint(root, &head, "must bypass hooks").unwrap();
    assert_eq!(run(root, &["rev-parse", "HEAD"]), head);
}

#[cfg(windows)]
#[test]
fn canonical_windows_paths_support_git_worktrees_beyond_max_path() {
    let source = repo();
    let root = source.path().canonicalize().unwrap();
    assert!(root.to_str().unwrap().starts_with(r"\\?\"));
    let head = run(source.path(), &["rev-parse", "HEAD"]);
    let target = tempfile::tempdir().unwrap();
    let mut parent = target.path().canonicalize().unwrap();
    for number in 0..20 {
        parent.push(format!("long fixture directory {number}"));
    }
    std::fs::create_dir_all(&parent).unwrap();
    assert!(parent.as_os_str().len() > 260);
    let before = workspace::status(&root).unwrap();
    let reserved =
        git::create_worktree(&root, &parent, "child", "feature/long-path", &head).unwrap();
    let path = reserved["path"].as_str().unwrap();
    assert!(!path.starts_with(r"\\?\") && !path.starts_with("//?/"));
    let destination = Path::new(path);
    assert!(destination.join(".git").is_file());
    assert!(!destination.join("[literal].txt").exists());
    assert_eq!(workspace::status(&root).unwrap(), before);
    // All reads also pass their canonical directory through the shared helper.
    assert!(
        git::worktrees(&destination.canonicalize().unwrap()).unwrap()["worktrees"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["branch"] == "refs/heads/feature/long-path")
    );
}
