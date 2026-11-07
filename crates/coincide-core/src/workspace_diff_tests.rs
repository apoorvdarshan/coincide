//! Parser regressions follow Swift's GitParsing/SplitDiff tests; review tests run
//! real Git in private temporary repositories only.
use super::*;
use std::process::Command;

fn line(kind: LineKind, text: &str) -> DiffLine {
    DiffLine {
        kind,
        text: text.into(),
        old_line: None,
        new_line: None,
    }
}

#[test]
fn hunk_headers_follow_swift_bounds_and_keep_section_spacing() {
    let hunk = hunk_header("@@ -10,7 +12,8 @@     def method(self):").unwrap();
    assert_eq!(
        (
            hunk.old_start,
            hunk.old_count,
            hunk.new_start,
            hunk.new_count
        ),
        (10, 7, 12, 8)
    );
    assert_eq!(hunk.section, "    def method(self):");
    assert_eq!(hunk.header(), "@@ -10,7 +12,8 @@     def method(self):");
    let single = hunk_header("@@ -1 +1 @@").unwrap();
    assert_eq!((single.old_count, single.new_count), (1, 1));
    assert_eq!(single.header(), "@@ -1,1 +1,1 @@");
    assert!(hunk_header("@@ -1,-2 +1 @@").is_none());
    assert!(hunk_header("@@ -99999999999 +1 @@").is_none());
    assert!(hunk_header("@@ -1 +1").is_none());
    assert!(hunk_header("@@@ -1 +1 @@@").is_none());
}

#[test]
fn patch_parsing_covers_renames_modes_binaries_quotes_and_eof_markers() {
    let patch = concat!(
        "diff --git a/src/old name.rs b/src/new name.rs\n",
        "similarity index 90%\n",
        "rename from src/old name.rs\n",
        "rename to src/new name.rs\n",
        "--- a/src/old name.rs\t\n",
        "+++ b/src/new name.rs\t\n",
        "@@ -1,2 +1,2 @@ fn main()\n",
        " keep\n",
        "-old\n",
        "+new\n",
        "\\ No newline at end of file\n",
        "diff --git a/run.sh b/run.sh\n",
        "old mode 100644\n",
        "new mode 100755\n",
        "diff --git a/image.png b/image.png\n",
        "new file mode 100644\n",
        "index 0000000..1234567\n",
        "Binary files /dev/null and b/image.png differ\n",
        "diff --git \"a/tab\\there\" \"b/tab\\there\"\n",
        "deleted file mode 100644\n",
        "--- \"a/tab\\there\"\n",
        "+++ /dev/null\n",
        "@@ -1 +0,0 @@\n",
        "-gone\n",
        "diff --git a/caf\\303\\251.txt b/caf\\303\\251.txt\n",
        "--- \"a/caf\\303\\251.txt\"\n",
        "+++ \"b/caf\\303\\251.txt\"\n",
        "@@ -1 +1 @@\n",
        "-x\r\n",
        "+y\r\n",
    );
    let files = parse_patch(patch);
    assert_eq!(files.len(), 5);
    let renamed = &files[0];
    assert_eq!(renamed.path, "src/new name.rs");
    assert_eq!(renamed.old_path.as_deref(), Some("src/old name.rs"));
    assert_eq!(renamed.status, ChangeStatus::Renamed);
    let lines = &renamed.hunks[0].lines;
    assert_eq!(renamed.hunks[0].section, "fn main()");
    assert_eq!(
        lines.iter().map(|line| line.kind).collect::<Vec<_>>(),
        [
            LineKind::Context,
            LineKind::Deletion,
            LineKind::Addition,
            LineKind::NoNewline
        ]
    );
    assert_eq!((lines[0].old_line, lines[0].new_line), (Some(1), Some(1)));
    assert_eq!((lines[1].old_line, lines[1].new_line), (Some(2), None));
    assert_eq!((lines[2].old_line, lines[2].new_line), (None, Some(2)));
    assert_eq!(lines[3].text, "\\ No newline at end of file");
    assert_eq!(files[1].mode_change.as_deref(), Some("100644 → 100755"));
    assert!(files[1].hunks.is_empty());
    assert!(files[2].is_binary);
    assert_eq!(files[2].status, ChangeStatus::Added);
    assert_eq!(files[3].path, "tab\there");
    assert_eq!(files[3].status, ChangeStatus::Deleted);
    assert_eq!(files[3].deletions, 1);
    assert_eq!(files[4].path, "café.txt");
    assert_eq!(files[4].hunks[0].lines[1].text, "y");
}

#[test]
fn numstat_assembly_marks_untracked_renames_binaries_and_sorts_naturally() {
    let stats = parse_numstat(
        &[
            "1\t0\tfile10.txt",
            "3\t1\t",
            "old.rs",
            "new.rs",
            "-\t-\tFile2.bin",
            "2\t0\tnew.txt",
            "",
        ]
        .join("\0"),
    );
    assert_eq!(stats.len(), 4);
    assert_eq!(stats[1].old_path.as_deref(), Some("old.rs"));
    assert!(stats[2].is_binary);
    let patch = concat!(
        "diff --git a/new.txt b/new.txt\n",
        "new file mode 100644\n",
        "--- /dev/null\n",
        "+++ b/new.txt\n",
        "@@ -0,0 +1,2 @@\n",
        "+a\n",
        "+b\n",
    );
    let untracked = HashSet::from(["new.txt".to_owned()]);
    let diff = assemble(patch, &stats, &untracked);
    assert_eq!(
        diff.files
            .iter()
            .map(|file| file.path.as_str())
            .collect::<Vec<_>>(),
        ["File2.bin", "file10.txt", "new.rs", "new.txt"]
    );
    assert!(diff.files[0].is_binary);
    assert_eq!(diff.files[2].status, ChangeStatus::Renamed);
    assert_eq!(diff.files[3].status, ChangeStatus::Untracked);
    assert_eq!(diff.files[3].hunks[0].lines.len(), 2);
    assert_eq!((diff.additions(), diff.deletions()), (6, 1));
    assert!(!diff.is_truncated);
    assert_eq!(natural_cmp("a2", "a10"), Ordering::Less);
    assert_eq!(natural_cmp("B", "a"), Ordering::Greater);
}

#[test]
fn oversized_patches_are_cut_at_a_file_boundary() {
    let body = "+x\n".repeat(MAX_PATCH_BYTES / 3);
    let patch = format!(
        "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1,1 @@\n+first\ndiff --git a/b b/b\n--- a/b\n+++ b/b\n@@ -0,0 +1,{} @@\n{body}",
        MAX_PATCH_BYTES / 3
    );
    let stats = [
        Numstat {
            path: "a".into(),
            old_path: None,
            additions: 1,
            deletions: 0,
            is_binary: false,
        },
        Numstat {
            path: "b".into(),
            old_path: None,
            additions: MAX_PATCH_BYTES / 3,
            deletions: 0,
            is_binary: false,
        },
    ];
    let diff = assemble(&patch, &stats, &HashSet::new());
    assert!(diff.is_truncated);
    assert_eq!(diff.files[0].hunks.len(), 1);
    assert!(diff.files[1].hunks.is_empty());
    assert_eq!(diff.files[1].additions, MAX_PATCH_BYTES / 3);
}

#[test]
fn split_alignment_pairs_replacements_and_keeps_eof_markers_with_their_line() {
    let lines = [
        line(LineKind::Context, "a"),
        line(LineKind::Deletion, "b"),
        line(LineKind::Deletion, "c"),
        line(LineKind::NoNewline, "\\"),
        line(LineKind::Addition, "B"),
        line(LineKind::Context, "d"),
        line(LineKind::Addition, "e"),
        line(LineKind::NoNewline, "\\"),
    ];
    let pairs: Vec<(Option<usize>, Option<usize>)> = align(&lines)
        .into_iter()
        .map(|pair| (pair.before, pair.after))
        .collect();
    assert_eq!(
        pairs,
        [
            (Some(0), Some(0)),
            (Some(1), Some(4)),
            (Some(2), None),
            (Some(3), None),
            (Some(5), Some(5)),
            (None, Some(6)),
            (None, Some(7)),
        ]
    );
}

#[test]
fn changed_ranges_highlight_only_meaningful_middles_in_bytes() {
    assert_eq!(
        changed_ranges("let value = 1;", "let value = 22;"),
        Some((12..13, 12..14))
    );
    assert_eq!(changed_ranges("café = 1", "café = 2"), Some((8..9, 8..9)));
    assert_eq!(changed_ranges("abc", "xyz"), None);
    assert_eq!(changed_ranges("", ""), None);
    assert_eq!(changed_ranges(&"a".repeat(2_000), "b"), None);
    let mut diff = GitDiff::default();
    let mut file = FileDiff::new("f", ChangeStatus::Modified);
    file.hunks.push(DiffHunk {
        old_start: 1,
        old_count: 1,
        new_start: 120,
        new_count: 1,
        section: String::new(),
        lines: vec![
            line(LineKind::Deletion, "let value = 1;"),
            line(LineKind::Addition, "let value = 22;\t"),
        ],
    });
    diff.files.push(file);
    let presentation = Presentation::make(&diff);
    // The trailing tab differs too, so the changed middle runs to the end.
    assert_eq!(presentation.highlights[&(0, 0, 0)], 12..14);
    assert_eq!(presentation.highlights[&(0, 0, 1)], 12..16);
    assert_eq!(presentation.max_line_number, 121);
    assert_eq!(presentation.max_columns, 19);
    assert_eq!(presentation.split_lines[0][0].len(), 1);
}

#[test]
fn request_parameters_reject_unknown_scopes_and_types() {
    assert_eq!(
        parse_request(&json!({})).unwrap(),
        (Scope::Uncommitted, false)
    );
    assert_eq!(
        parse_request(&json!({"scope":"branch","ignoreWhitespace":true})).unwrap(),
        (Scope::Branch, true)
    );
    assert!(parse_request(&json!({"scope":"latestTurn"})).is_err());
    assert!(parse_request(&json!({"ignoreWhitespace":"yes"})).is_err());
}

fn run(root: &Path, args: &[&str]) {
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
            "-c",
            "init.defaultBranch=main",
        ])
        .args(args)
        .env_remove("GIT_DIR")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_WORK_TREE")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn loaded(directory: &Path, scope: Scope, ignore_whitespace: bool) -> GitDiff {
    match decode(&review(directory, scope, ignore_whitespace).unwrap()).unwrap() {
        Review::Diff { diff, .. } => diff,
        Review::NotRepository => panic!("fixture is a repository"),
    }
}

#[test]
fn uncommitted_review_previews_untracked_files_without_touching_the_index() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let outside = tempfile::tempdir().unwrap();
    assert_eq!(
        decode(&review(outside.path(), Scope::Uncommitted, false).unwrap()).unwrap(),
        Review::NotRepository
    );
    run(root, &["init", "-q"]);
    std::fs::write(root.join("unborn.txt"), "first\n").unwrap();
    let unborn = loaded(root, Scope::Uncommitted, false);
    assert_eq!(unborn.files[0].status, ChangeStatus::Untracked);
    assert_eq!(unborn.files[0].hunks[0].lines[0].text, "first");
    run(root, &["add", "."]);
    run(root, &["commit", "-qm", "base"]);
    std::fs::write(root.join("unborn.txt"), "first\nsecond\n").unwrap();
    std::fs::write(root.join("spaces.txt"), "a b\n").unwrap();
    run(root, &["add", "spaces.txt"]);
    run(root, &["commit", "-qm", "spaces"]);
    std::fs::write(root.join("spaces.txt"), "a  b\n").unwrap();
    std::fs::create_dir(root.join("sub")).unwrap();
    std::fs::write(root.join("sub/[new].txt"), "hello\nworld\n").unwrap();
    let index_before = std::fs::read(root.join(".git/index")).unwrap();
    let from_subdirectory = loaded(&root.join("sub"), Scope::Uncommitted, false);
    assert_eq!(
        std::fs::read(root.join(".git/index")).unwrap(),
        index_before,
        "the review index must be a private copy"
    );
    let paths: Vec<_> = from_subdirectory
        .files
        .iter()
        .map(|file| (file.path.as_str(), file.status))
        .collect();
    assert_eq!(
        paths,
        [
            ("spaces.txt", ChangeStatus::Modified),
            ("sub/[new].txt", ChangeStatus::Untracked),
            ("unborn.txt", ChangeStatus::Modified),
        ]
    );
    assert_eq!(from_subdirectory.files[1].additions, 2);
    assert_eq!(from_subdirectory.base_label.as_deref(), Some("HEAD"));
    let ignoring = loaded(root, Scope::Uncommitted, true);
    assert!(ignoring.files.iter().all(|file| file.path != "spaces.txt"));
}

#[test]
fn branch_review_compares_with_the_merge_base_including_uncommitted_work() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    run(root, &["init", "-q"]);
    std::fs::write(root.join("base.txt"), "base\n").unwrap();
    run(root, &["add", "."]);
    run(root, &["commit", "-qm", "base"]);
    let main_only = loaded(root, Scope::Branch, false);
    assert!(main_only.files.is_empty());
    assert_eq!(main_only.base_label.as_deref(), Some("HEAD"));
    run(root, &["checkout", "-qb", "feature"]);
    std::fs::write(root.join("feature.txt"), "feature\n").unwrap();
    run(root, &["add", "."]);
    run(root, &["commit", "-qm", "feature"]);
    run(root, &["checkout", "-q", "main"]);
    std::fs::write(root.join("main-later.txt"), "later\n").unwrap();
    run(root, &["add", "."]);
    run(root, &["commit", "-qm", "main later"]);
    run(root, &["checkout", "-q", "feature"]);
    std::fs::write(root.join("base.txt"), "base\nedited\n").unwrap();
    let branch = loaded(root, Scope::Branch, false);
    assert_eq!(branch.base_label.as_deref(), Some("main"));
    assert_eq!(
        branch
            .files
            .iter()
            .map(|file| file.path.as_str())
            .collect::<Vec<_>>(),
        ["base.txt", "feature.txt"],
        "changes on main after the branch point are not the branch's"
    );
    let uncommitted = loaded(root, Scope::Uncommitted, false);
    assert_eq!(uncommitted.files.len(), 1);
    run(
        root,
        &[
            "config",
            "branch.feature.coincide-merge-base",
            "missing-base",
        ],
    );
    assert_eq!(
        loaded(root, Scope::Branch, false).base_label.as_deref(),
        Some("main")
    );
}
