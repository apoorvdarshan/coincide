//! Real Git repositories in temporary folders; no user repository is touched.
use super::*;

fn git(root: &Path, args: &[&str]) -> String {
    git_env(root, args, &[])
}
fn git_env(root: &Path, args: &[&str], env: &[(&str, &str)]) -> String {
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
        .envs(env.iter().copied())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().into()
}
fn repository() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("repo");
    std::fs::create_dir(&root).unwrap();
    git(&root, &["init", "-q", "-b", "main"]);
    git(&root, &["config", "core.autocrlf", "false"]);
    std::fs::write(root.join("keep.txt"), "one\ntwo\nthree\n").unwrap();
    std::fs::write(root.join("remove.txt"), "gone soon\n").unwrap();
    std::fs::write(root.join(".gitignore"), "ignored.log\n").unwrap();
    git(&root, &["add", "."]);
    git(&root, &["commit", "-qm", "fixture"]);
    let root = root.canonicalize().unwrap();
    (dir, root)
}
const THREAD: &str = "6B0F8F5E-7C1A-4C3B-9E2D-1A2B3C4D5E6F";
const TURN: &str = "0F1E2D3C-4B5A-4968-8776-655443322110";

#[test]
fn references_are_lowercase_and_reject_unknown_identities() {
    assert_eq!(
        reference(THREAD, TURN, "before").unwrap(),
        "refs/coincide/checkpoints/6b0f8f5e-7c1a-4c3b-9e2d-1a2b3c4d5e6f/0f1e2d3c-4b5a-4968-8776-655443322110/before"
    );
    assert!(reference("../x", TURN, "before").is_err());
    assert!(reference(THREAD, TURN, "during").is_err());
}

#[test]
fn turn_changes_are_listed_diffed_and_reverted_without_touching_the_index() {
    let (_dir, root) = repository();
    // The user's own staged change must survive capture untouched.
    std::fs::write(root.join("keep.txt"), "one\ntwo\nthree\nstaged\n").unwrap();
    git(&root, &["add", "keep.txt"]);
    let staged = git(&root, &["diff", "--cached", "--name-only"]);
    let before_ref = reference(THREAD, TURN, "before").unwrap();
    let before = capture(&root, Some(&before_ref)).unwrap();
    assert_eq!(git(&root, &["rev-parse", &before_ref]), before);
    assert_eq!(git(&root, &["diff", "--cached", "--name-only"]), staged);

    // The turn edits, adds and deletes; an ignored file is never captured.
    std::fs::write(root.join("keep.txt"), "one\n2\nthree\nstaged\nmore\n").unwrap();
    std::fs::write(root.join("added 10.txt"), "new\n").unwrap();
    std::fs::write(root.join("added 9.txt"), "new\n").unwrap();
    std::fs::remove_file(root.join("remove.txt")).unwrap();
    std::fs::write(root.join("ignored.log"), "local only\n").unwrap();
    let after_ref = reference(THREAD, TURN, "after").unwrap();
    let after = capture(&root, Some(&after_ref)).unwrap();
    assert_eq!(git(&root, &["diff", "--cached", "--name-only"]), staged);

    let files = changed_files(&root, &before, &after).unwrap();
    let summary = files
        .iter()
        .map(|file| {
            (
                file.path.as_str(),
                file.status,
                file.additions,
                file.deletions,
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        summary,
        [
            ("added 9.txt", FileStatus::Added, 1, 0),
            ("added 10.txt", FileStatus::Added, 1, 0),
            ("keep.txt", FileStatus::Modified, 2, 1),
            ("remove.txt", FileStatus::Deleted, 0, 1),
        ]
    );
    let patch = diff(&root, &before, &after, None).unwrap();
    assert!(!patch.truncated);
    assert!(patch.text.contains("+more"), "{}", patch.text);
    assert!(!patch.text.contains("ignored.log"));
    let one = diff(&root, &before, &after, Some(&["keep.txt".into()])).unwrap();
    assert!(one.text.contains("keep.txt") && !one.text.contains("remove.txt"));

    restore(&root, &before).unwrap();
    assert_eq!(
        std::fs::read_to_string(root.join("keep.txt")).unwrap(),
        "one\ntwo\nthree\nstaged\n"
    );
    assert!(root.join("remove.txt").exists());
    assert!(!root.join("added 9.txt").exists());
    // Ignored files stay; the index is reset to HEAD for the folder.
    assert_eq!(
        std::fs::read_to_string(root.join("ignored.log")).unwrap(),
        "local only\n"
    );
    assert_eq!(git(&root, &["diff", "--cached", "--name-only"]), "");

    delete_refs(&root, &[before_ref.clone(), after_ref]);
    assert!(git(&root, &["for-each-ref", "refs/coincide/checkpoints/"]).is_empty());
}

#[test]
fn staged_checkpoint_listing_skips_turn_snapshots() {
    let (_dir, root) = repository();
    capture(&root, Some(&reference(THREAD, TURN, "before").unwrap())).unwrap();
    let listed = crate::workspace_git::checkpoints(&root).unwrap();
    assert_eq!(listed["checkpoints"], serde_json::json!([]));
}

#[test]
fn tree_only_capture_records_no_reference() {
    let (_dir, root) = repository();
    std::fs::write(root.join("live.txt"), "live\n").unwrap();
    let tree = capture(&root, None).unwrap();
    assert_eq!(git(&root, &["cat-file", "-t", &tree]), "tree");
    assert!(git(&root, &["for-each-ref", "refs/coincide/"]).is_empty());
}

#[test]
fn a_folder_outside_git_has_no_checkpoint() {
    let dir = tempfile::tempdir().unwrap();
    assert!(capture(dir.path(), None).is_err());
}

#[test]
fn files_that_arrive_with_a_moved_head_are_left_out() {
    let (_dir, root) = repository();
    // An upstream commit made before the turn, merged in during it.
    git(&root, &["checkout", "-q", "-b", "upstream"]);
    std::fs::write(root.join("upstream.txt"), "pulled\n").unwrap();
    git(&root, &["add", "upstream.txt"]);
    let old = [
        ("GIT_COMMITTER_DATE", "2001-01-01T00:00:00Z"),
        ("GIT_AUTHOR_DATE", "2001-01-01T00:00:00Z"),
    ];
    git_env(&root, &["commit", "-qm", "upstream"], &old);
    git(&root, &["checkout", "-q", "main"]);
    let before = capture(&root, Some(&reference(THREAD, TURN, "before").unwrap())).unwrap();
    git(&root, &["merge", "-q", "--ff-only", "upstream"]);
    std::fs::write(root.join("keep.txt"), "edited by the turn\n").unwrap();
    let after = capture(&root, Some(&reference(THREAD, TURN, "after").unwrap())).unwrap();
    let paths = changed_files(&root, &before, &after)
        .unwrap()
        .into_iter()
        .map(|file| file.path)
        .collect::<Vec<_>>();
    assert_eq!(paths, ["keep.txt"]);
}

#[test]
fn swift_indexes_are_read_leniently() {
    let bytes = br#"[
        {"userItemID":"0F1E2D3C-4B5A-4968-8776-655443322110","cwd":"/tmp/x","before":"aa","beforeAt":"2026-01-01T00:00:00Z","after":"bb","afterAt":"2026-01-01T00:00:01Z","files":[{"path":"a.swift","status":"modified","additions":3,"deletions":1},{"path":"b","oldPath":"a","status":"renamed","additions":0,"deletions":0}]},
        {"cwd":"missing identity"}
    ]"#;
    let turns = parse_swift_index(bytes);
    assert_eq!(turns.len(), 1);
    assert!(turns[0].is_complete());
    assert_eq!(turns[0].files[1].old_path.as_deref(), Some("a"));
    assert_eq!(turns[0].files[1].status, FileStatus::Renamed);
    assert!(parse_swift_index(b"{}").is_empty());
}

#[test]
fn natural_order_matches_finder() {
    let mut names = vec!["b.txt", "A10.txt", "a9.txt", "a.txt"];
    names.sort_by(|a, b| natural_order(a, b));
    assert_eq!(names, ["a.txt", "a9.txt", "A10.txt", "b.txt"]);
}

#[test]
fn broad_folders_are_never_snapshotted() {
    assert!(broad_folder(Path::new("/")));
    if let Some(home) = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }) {
        assert!(broad_folder(Path::new(&home)));
    }
    let dir = tempfile::tempdir().unwrap();
    assert!(!broad_folder(dir.path()));
}
