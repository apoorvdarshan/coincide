use super::{host::*, names::*, ops::*, *};
use std::process::Command;

fn status(files: usize, branch: Option<&str>) -> GitStatus {
    GitStatus {
        is_repository: true,
        branch: branch.map(str::to_owned),
        files: (0..files)
            .map(|index| ChangedFile {
                path: format!("file{index}"),
                old_path: None,
                status: FileStatus::Modified,
                additions: 1,
                deletions: 0,
            })
            .collect(),
        ..GitStatus::default()
    }
}

fn quick(status: &GitStatus, open: bool) -> (String, QuickKind) {
    let action = QuickAction::resolve(Some(status), false, open, Term::PullRequest);
    (action.title, action.kind)
}

#[test]
fn quick_action_follows_t3_rules() {
    // Changes without a remote only commit.
    assert_eq!(
        quick(&status(1, Some("main")), false).1,
        QuickKind::Run(StackedAction::Commit)
    );
    let mut remote = status(1, Some("feature"));
    remote.has_remote = true;
    assert_eq!(
        quick(&remote, false),
        (
            "Commit, Push & Create PR".into(),
            QuickKind::Run(StackedAction::CommitPushPr)
        )
    );
    assert_eq!(
        quick(&remote, true).1,
        QuickKind::Run(StackedAction::CommitPush)
    );
    remote.is_default_branch = true;
    assert_eq!(
        quick(&remote, false).1,
        QuickKind::Run(StackedAction::CommitPush)
    );

    // Clean, unpublished branch: push and create, or explain.
    let mut clean = status(0, Some("feature"));
    clean.has_remote = true;
    assert_eq!(
        quick(&clean, false),
        (
            "Push".into(),
            QuickKind::Hint("No local commits to push.".into())
        )
    );
    clean.ahead = 2;
    assert_eq!(
        quick(&clean, false),
        (
            "Push & Create PR".into(),
            QuickKind::Run(StackedAction::CreatePr)
        )
    );
    assert_eq!(
        quick(&clean, true),
        ("Push".into(), QuickKind::Run(StackedAction::Push))
    );

    // Tracking branches.
    clean.upstream = Some("origin/feature".into());
    clean.behind = 1;
    assert_eq!(quick(&clean, false).0, "Sync Branch");
    clean.ahead = 0;
    assert_eq!(quick(&clean, false), ("Pull".into(), QuickKind::Pull));
    clean.behind = 0;
    clean.ahead_of_default = 3;
    assert_eq!(
        quick(&clean, false),
        ("Create PR".into(), QuickKind::Run(StackedAction::CreatePr))
    );
    assert_eq!(
        quick(&clean, true).1,
        QuickKind::Hint("The branch is up to date. Nothing to do.".into())
    );

    // Hints for detached heads, busy bars and GitLab's words.
    let detached = status(1, None);
    assert_eq!(
        QuickAction::resolve(Some(&detached), false, false, Term::MergeRequest).kind,
        QuickKind::Hint("Check out a branch before pushing or opening a merge request.".into())
    );
    assert!(!QuickAction::resolve(Some(&remote), true, false, Term::PullRequest).is_enabled);
    assert_eq!(
        QuickAction::resolve(None, false, false, Term::PullRequest).kind,
        QuickKind::Hint("Git status is unavailable.".into())
    );
    let mut gitlab = status(1, Some("feature"));
    gitlab.has_remote = true;
    assert_eq!(
        QuickAction::resolve(Some(&gitlab), false, false, Term::MergeRequest).title,
        "Commit, Push & Create MR"
    );
    assert!(QuickAction::requires_default_branch_confirmation(
        StackedAction::Push,
        true
    ));
    assert!(!QuickAction::requires_default_branch_confirmation(
        StackedAction::Commit,
        true
    ));
    assert!(!QuickAction::requires_default_branch_confirmation(
        StackedAction::Push,
        false
    ));
}

#[test]
fn availability_enables_menu_items() {
    let mut clean = status(0, Some("feature"));
    clean.has_remote = true;
    clean.ahead = 1;
    let available = Availability::resolve(Some(&clean), false, false);
    assert!(!available.can_commit && available.can_push && available.can_create_pr);
    assert!(available.shows_remote_actions);
    assert!(!Availability::resolve(Some(&clean), false, true).can_create_pr);
    assert!(!Availability::resolve(Some(&clean), true, false).can_push);
    clean.behind = 1;
    clean.upstream = Some("origin/feature".into());
    let behind = Availability::resolve(Some(&clean), false, false);
    assert!(!behind.can_push && !behind.can_create_pr);
    assert_eq!(
        Availability::resolve(None, false, false),
        Availability::default()
    );
}

#[test]
fn branch_names_match_swift() {
    assert_eq!(
        sanitize_fragment("  Fix the Login: redirect!! "),
        "fix-the-login-redirect"
    );
    assert_eq!(sanitize_fragment("feat//x--y"), "feat/x-y");
    assert_eq!(sanitize_fragment("“quoted” 'text'"), "quoted-text");
    assert_eq!(sanitize_fragment("..."), "update");
    assert_eq!(sanitize_fragment(&"a".repeat(80)).len(), 64);
    assert_eq!(feature_branch_name("Add parser"), "feature/add-parser");
    assert_eq!(feature_branch_name("fix/parser"), "fix/parser");
    assert_eq!(sanitize_new_ref_name("  my  new\tbranch "), "my-new-branch");
    assert_eq!(local_name_from_remote_ref("origin/feature/x"), "feature/x");
    assert_eq!(local_name_from_remote_ref("main"), "main");
    let existing = vec!["feature/add-parser".to_owned(), "feature/x/y".to_owned()];
    assert_eq!(
        available_feature_branch_name("Add parser", &existing),
        "feature/add-parser-2"
    );
    assert_eq!(available_feature_branch_name("x", &existing), "feature/x-2");
    assert_eq!(
        available_feature_branch_name("new", &existing),
        "feature/new"
    );
    let temporary = temporary_worktree_branch("coincide/");
    assert!(is_temporary_worktree_branch(&temporary, "coincide/"));
    let flat = flattened_temporary_branch(&temporary, "coincide/");
    assert!(flat.starts_with("coincide-") && is_temporary_worktree_branch(&flat, "coincide/"));
    assert!(!is_temporary_worktree_branch(
        "coincide/fix-login",
        "coincide/"
    ));
    assert!(is_temporary_worktree_branch("0123abcd", ""));
    assert_eq!(
        descriptive_branch(
            "Please fix the login redirect when the session expires\nmore",
            "coincide/"
        ),
        "coincide/fix-login-redirect-when-session"
    );
    assert_eq!(descriptive_branch("???", "coincide/"), "coincide/update");
    assert_eq!(merge_base_config_key("x"), "branch.x.coincide-merge-base");
}

#[test]
fn fallback_messages_match_swift() {
    assert_eq!(
        fallback_commit_message("A\tsrc/new.rs").subject,
        "Add new.rs"
    );
    assert_eq!(
        fallback_commit_message("R100\told/a.rs\tnew/b.rs").subject,
        "Rename a.rs to b.rs"
    );
    let several = fallback_commit_message("M\ta.rs\nM\tb.rs");
    assert_eq!(several.subject, "Update 2 files");
    assert_eq!(several.body, "- Update a.rs\n- Update b.rs");
    assert_eq!(
        fallback_commit_message("A\ta\nD\tb").subject,
        "Update 2 files"
    );
    assert_eq!(fallback_commit_message("").subject, FALLBACK_SUBJECT);
    let custom = custom_commit_message(Some("  Subject line\r\n\r\nBody text\n")).unwrap();
    assert_eq!(
        (custom.subject.as_str(), custom.body.as_str()),
        ("Subject line", "Body text")
    );
    assert!(custom_commit_message(Some(" \n ")).is_none());
    assert_eq!(
        sanitized_commit_message("Done...", "", None).subject,
        "Done"
    );
    let single = fallback_pull_request("feature/x", "abc123 Fix the parser");
    assert_eq!(single.title, "Fix the parser");
    assert!(
        single.body.contains("## Summary\n- Fix the parser") && single.body.ends_with("- Not run")
    );
    let named = fallback_pull_request("feature/fix-login_page", "a One\nb Two");
    assert_eq!(named.title, "Fix login page");
    assert_eq!(
        fallback_pull_request("", "").title,
        "Update project changes"
    );
}

#[test]
fn remotes_and_hosts_match_swift() {
    let ssh = RemoteUrl::parse("git@github.com:owner/repo.git").unwrap();
    assert_eq!(
        (ssh.transport, ssh.hostname.as_str()),
        (Transport::Ssh, "github.com")
    );
    assert_eq!(ssh.path, ["owner", "repo"]);
    let https =
        RemoteUrl::parse("https://user:p%40ss@GitLab.example.com:8443/group/sub/project.git")
            .unwrap();
    assert_eq!(
        (https.host(), https.path.len()),
        ("gitlab.example.com:8443".into(), 3)
    );
    assert!(RemoteUrl::parse("/local/path").is_none());
    assert!(RemoteUrl::parse("C:/repo").is_none());
    assert!(RemoteUrl::parse("file:///tmp/repo").is_none());

    let github = Host::recognize(ssh);
    assert_eq!(github.kind, Kind::Github);
    assert_eq!(
        github.repository_url().as_deref(),
        Some("https://github.com/owner/repo")
    );
    assert_eq!(
        github
            .new_change_request_url("main", "feature/x")
            .as_deref(),
        Some("https://github.com/owner/repo/compare/main...feature/x?expand=1")
    );
    assert!(github.new_change_request_url("main", "../x").is_none());

    let gitlab = Host::recognize(https);
    assert_eq!(
        (gitlab.kind, gitlab.display_name().as_str()),
        (Kind::Gitlab, "GitLab")
    );
    assert_eq!(gitlab.kind.change_request(), Term::MergeRequest);
    assert_eq!(
        gitlab.new_change_request_url("main", "fix it").as_deref(),
        Some(
            "https://gitlab.example.com:8443/group/sub/project/-/merge_requests/new?merge_request%5Bsource_branch%5D=fix%20it&merge_request%5Btarget_branch%5D=main"
        )
    );
    let codeberg = Host::recognize_url("https://codeberg.org/a/b").unwrap();
    assert_eq!(
        (codeberg.kind, codeberg.display_name().as_str()),
        (Kind::Forgejo, "Codeberg")
    );
    let azure = Host::recognize_url("git@ssh.dev.azure.com:v3/org/project/repo").unwrap();
    assert_eq!(
        azure.repository_url().as_deref(),
        Some("https://dev.azure.com/org/project/_git/repo")
    );
    let server = Host::recognize_url("https://bitbucket.example.com/scm/PROJ/repo.git").unwrap();
    assert_eq!(
        server.repository_url().as_deref(),
        Some("https://bitbucket.example.com/projects/PROJ/repos/repo")
    );
    let unknown = Host::recognize_url("git@git.example.com:team/repo").unwrap();
    assert_eq!(unknown.kind, Kind::Unknown);
    assert!(unknown.new_change_request_url("main", "x").is_none());
    assert!(uses_gh(Some(&unknown)) && uses_gh(None) && !uses_gh(Some(&gitlab)));
    assert_eq!(Term::MergeRequest.reference(4), "!4");
    assert_eq!(Term::PullRequest.view_title(12), "View Pull Request #12");
}

#[test]
fn parses_git_machine_output() {
    let output = "# branch.oid 0123\0# branch.head feature\0# branch.upstream origin/feature\0# branch.ab +2 -1\0\
1 .M N... 100644 100644 100644 a b src/main.rs\0\
2 R. N... 100644 100644 100644 a b R100 new name.rs\0old name.rs\0\
u UU N... 100644 100644 100644 100644 a b c conflict.rs\0\
? untracked file.txt\0";
    let parsed = parse_porcelain_v2(output);
    assert_eq!(parsed.head.as_deref(), Some("feature"));
    assert_eq!((parsed.ahead, parsed.behind), (2, 1));
    assert_eq!(parsed.entries.len(), 4);
    assert_eq!(parsed.entries[1].path, "new name.rs");
    assert_eq!(
        parsed.entries[1].original_path.as_deref(),
        Some("old name.rs")
    );
    assert_eq!(parsed.entries[3].path, "untracked file.txt");
    let detached = parse_porcelain_v2("# branch.oid (initial)\0# branch.head (detached)\0");
    assert!(detached.oid.is_none() && detached.head.is_none());

    let stats = parse_numstat("3\t1\tsrc/a.rs\0-\t-\timage.png\x000\t0\t\0old.rs\0new.rs\0");
    assert_eq!(stats.len(), 3);
    assert_eq!((stats[0].additions, stats[0].deletions), (3, 1));
    assert_eq!(stats[2].path, "new.rs");

    let trees = parse_worktrees(
        "worktree /repo\0HEAD abc\0branch refs/heads/main\0\0worktree /tmp/wt\0HEAD def\0detached\0prunable gone\0\0",
    );
    assert_eq!(trees.len(), 2);
    assert!(trees[0].is_main && trees[0].branch.as_deref() == Some("main"));
    assert!(!trees[1].is_main && trees[1].is_prunable && trees[1].branch.is_none());
    assert_eq!(natural_cmp("file2", "file10"), std::cmp::Ordering::Less);
    assert_eq!(natural_cmp("B", "a"), std::cmp::Ordering::Greater);
}

fn git_in(dir: &std::path::Path, args: &[&str]) {
    let status = Command::new("git")
        .args([
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "-c",
            "commit.gpgSign=false",
        ])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?}");
}

fn repository() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    git_in(dir.path(), &["init", "-q", "-b", "main"]);
    git_in(dir.path(), &["config", "user.name", "Fixture"]);
    git_in(
        dir.path(),
        &["config", "user.email", "fixture@example.invalid"],
    );
    git_in(dir.path(), &["config", "commit.gpgSign", "false"]);
    std::fs::write(dir.path().join("readme.md"), "hello\n").unwrap();
    git_in(dir.path(), &["add", "-A"]);
    git_in(dir.path(), &["commit", "-q", "-m", "Initial"]);
    dir
}

#[test]
fn status_commit_and_branches_in_a_fixture_repository() {
    let dir = repository();
    let root = dir.path();
    std::fs::write(root.join("readme.md"), "hello\nworld\n").unwrap();
    std::fs::write(root.join("new.txt"), "one\ntwo\nthree").unwrap();
    let state = ops::status(root).unwrap();
    assert!(state.is_repository && state.branch.as_deref() == Some("main"));
    assert!(state.is_default_branch && !state.has_remote);
    assert_eq!(state.files.len(), 2);
    let readme = state.files.iter().find(|f| f.path == "readme.md").unwrap();
    assert_eq!((readme.additions, readme.deletions), (1, 0));
    let untracked = state.files.iter().find(|f| f.path == "new.txt").unwrap();
    assert_eq!(
        (untracked.status, untracked.additions),
        (FileStatus::Untracked, 3)
    );

    // Only the picked file is committed; the plain message names it.
    let request = ActionRequest {
        action: Some(StackedAction::Commit),
        file_paths: Some(vec!["new.txt".into()]),
        ..ActionRequest::default()
    };
    let steps = std::cell::RefCell::new(Vec::new());
    let result = run(&request, root, &|step| {
        steps.borrow_mut().push(step.to_owned())
    })
    .unwrap();
    assert_eq!(result.commit.as_ref().unwrap().subject, "Add new.txt");
    assert!(result.title.starts_with("Committed "));
    assert_eq!(result.follow_up, Some(FollowUp::Run(StackedAction::Push)));
    assert!(steps.borrow().contains(&"Committing…".to_owned()));
    let after = ops::status(root).unwrap();
    assert_eq!(after.files.len(), 1);
    assert_eq!(after.files[0].path, "readme.md");

    // Commit on a new branch named after the typed message.
    let request = ActionRequest {
        action: Some(StackedAction::Commit),
        commit_message: Some("Explain the readme".into()),
        feature_branch: true,
        ..ActionRequest::default()
    };
    let result = run(&request, root, &|_| {}).unwrap();
    assert_eq!(
        result.created_branch.as_deref(),
        Some("feature/explain-the-readme")
    );
    assert!(ops::status(root).unwrap().files.is_empty());

    // Nothing left: committing again fails with Swift's words.
    let error = run(
        &ActionRequest {
            action: Some(StackedAction::Commit),
            ..ActionRequest::default()
        },
        root,
        &|_| {},
    )
    .unwrap_err();
    assert_eq!(error.to_string(), "There are no changes to commit.");

    let list = ops::branches(root).unwrap();
    assert_eq!(
        list.current_branch.as_deref(),
        Some("feature/explain-the-readme")
    );
    assert_eq!(list.branches[0].name, "feature/explain-the-readme");
    assert!(list.branches[0].is_current);
    assert_eq!(
        list.default_base().as_deref(),
        Some("feature/explain-the-readme")
    );
    assert_eq!(
        ops::checkout("main", root).unwrap().as_deref(),
        Some("main")
    );
    assert_eq!(
        ops::create_branch("my topic", root, true).unwrap(),
        "my-topic"
    );
    let invalid = ops::create_branch("bad..name", root, false).unwrap_err();
    assert_eq!(
        invalid.to_string(),
        "“bad..name” is not a valid branch name."
    );
    // Push without a remote explains itself.
    let error = run(
        &ActionRequest {
            action: Some(StackedAction::Push),
            ..ActionRequest::default()
        },
        root,
        &|_| {},
    )
    .unwrap_err();
    assert_eq!(
        error.to_string(),
        "Cannot push because this repository has no remote."
    );
}

#[test]
fn push_pull_and_thread_worktrees_with_a_local_remote() {
    let upstream = tempfile::tempdir().unwrap();
    git_in(upstream.path(), &["init", "-q", "--bare", "-b", "main"]);
    let dir = repository();
    let root = dir.path();
    git_in(
        root,
        &["remote", "add", "origin", upstream.path().to_str().unwrap()],
    );
    git_in(root, &["push", "-q", "-u", "origin", "main"]);
    std::fs::write(root.join("change.txt"), "x\n").unwrap();
    let state = ops::status(root).unwrap();
    assert!(state.has_remote && state.has_upstream());
    // A local path names no host: the plain status still resolves the action.
    assert_eq!(
        QuickAction::resolve(Some(&state), false, false, Term::PullRequest).kind,
        QuickKind::Run(StackedAction::CommitPush)
    );
    let result = run(
        &ActionRequest {
            action: Some(StackedAction::CommitPush),
            ..ActionRequest::default()
        },
        root,
        &|_| {},
    )
    .unwrap();
    assert!(result.title.starts_with("Pushed ") && result.title.ends_with(" to origin/main"));
    assert_eq!(result.push.unwrap().outcome, PushOutcome::Pushed);
    assert!(
        result.follow_up.is_none(),
        "the default branch offers no pull request"
    );
    assert_eq!(ops::pull(root).unwrap(), PullResult::UpToDate);

    let worktrees = tempfile::tempdir().unwrap();
    let tree = create_thread_worktree(root, Some("main"), "coincide/", worktrees.path()).unwrap();
    let branch = tree.branch.clone().unwrap();
    assert!(is_temporary_worktree_branch(&branch, "coincide/"));
    let path = std::path::PathBuf::from(&tree.path);
    assert!(
        path.join("readme.md").is_file(),
        "the worktree is checked out"
    );
    let renamed = name_worktree_branch(&branch, &path, "Fix the parser", "coincide/").unwrap();
    assert_eq!(renamed.as_deref(), Some("coincide/fix-parser"));
    // A used worktree is kept; an unused clean one is removed with its branch.
    std::fs::write(path.join("dirty.txt"), "x").unwrap();
    assert!(!discard_unused_worktree(
        &path,
        Some("coincide/fix-parser"),
        "coincide/"
    ));
    let unused = create_thread_worktree(root, None, "coincide/", worktrees.path()).unwrap();
    let unused_branch = unused.branch.clone().unwrap();
    assert!(discard_unused_worktree(
        std::path::Path::new(&unused.path),
        Some(&unused_branch),
        "coincide/"
    ));
    assert!(!std::path::Path::new(&unused.path).exists());
    let names: Vec<String> = ops::branches(root)
        .unwrap()
        .local()
        .map(|branch| branch.name.clone())
        .collect();
    assert!(!names.contains(&unused_branch));
    let used = ops::branches(root)
        .unwrap()
        .branches
        .into_iter()
        .find(|branch| branch.name == "coincide/fix-parser")
        .unwrap();
    assert_eq!(used.worktree_path.as_deref(), Some(tree.path.as_str()));
    assert!(!used.is_current);
}
