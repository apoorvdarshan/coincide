use super::*;
use crate::{api::Engine, store::Store};
use serde_json::json;
use std::collections::HashMap;

/// Fixture Git: a fixed identity and no signing; never the production runner.
fn git(directory: &Path, args: &[&str]) -> String {
    let mut command = Command::new("git");
    for (name, _) in std::env::vars_os() {
        if name.to_string_lossy().starts_with("GIT_") {
            command.env_remove(name);
        }
    }
    let output = command
        .args([
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "-c",
            "commit.gpgSign=false",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "protocol.file.allow=always",
        ])
        .arg("-C")
        .arg(external_git_directory(directory).unwrap())
        .args(args)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}
fn commit(directory: &Path, file: &str, text: &str) -> String {
    fs::write(directory.join(file), text).unwrap();
    git(directory, &["add", "--", file]);
    git(directory, &["commit", "-q", "-m", file]);
    git(directory, &["rev-parse", "HEAD"])
}
/// Git's own spelling (drive/UNC, forward slashes) for URLs and arguments.
fn slash(path: &Path) -> String {
    external_git_path(path)
        .unwrap()
        .to_str()
        .unwrap()
        .replace('\\', "/")
}
struct Fixture {
    _directory: tempfile::TempDir,
    store: Store,
    project: PathBuf,
    base: PathBuf,
    main: String,
    feature: String,
    fork: String,
}
/// `base.git` plays github.com/fixture/repo: branches plus GitHub's pull refs.
/// The project clone names it by its GitHub URL, which local config rewrites.
fn fixture(submodule: bool) -> Fixture {
    let directory = tempfile::tempdir().unwrap();
    let top = directory.path().canonicalize().unwrap();
    let seed = top.join("seed");
    fs::create_dir(&seed).unwrap();
    git(&seed, &["init", "-q", "-b", "main"]);
    fs::write(seed.join("README.md"), "base\n").unwrap();
    git(&seed, &["add", "README.md"]);
    if submodule {
        let missing = slash(&top.join("missing-submodule.git"));
        fs::write(
            seed.join(".gitmodules"),
            format!("[submodule \"vendor\"]\n\tpath = vendor\n\turl = {missing}\n"),
        )
        .unwrap();
        git(&seed, &["add", ".gitmodules"]);
        let gitlink = format!("160000,{},vendor", "1".repeat(40));
        git(&seed, &["update-index", "--add", "--cacheinfo", &gitlink]);
    }
    git(&seed, &["commit", "-q", "-m", "base"]);
    let main = git(&seed, &["rev-parse", "HEAD"]);
    git(&seed, &["checkout", "-q", "-b", "feature"]);
    let feature = commit(&seed, "feature.txt", "feature\n");
    git(&seed, &["checkout", "-q", "-b", "fork-main", "main"]);
    let fork = commit(&seed, "fork.txt", "fork\n");
    let base = top.join("base.git");
    git(&top, &["init", "-q", "--bare", "-b", "main", "base.git"]);
    let base_text = slash(&base);
    for spec in [
        "main:refs/heads/main".to_owned(),
        "feature:refs/heads/feature".to_owned(),
        format!("{feature}:refs/pull/7/head"),
        format!("{fork}:refs/pull/8/head"),
        format!("{fork}:refs/pull/9/head"),
        format!("{main}:refs/pull/12/head"),
    ] {
        git(&seed, &["push", "-q", &base_text, &spec]);
    }
    git(&top, &["clone", "-q", &base_text, "project"]);
    let project = top.join("project");
    let rewrite = format!("url.{base_text}.insteadOf");
    for (key, value) in [
        ("remote.origin.url", "https://github.com/fixture/repo.git"),
        (rewrite.as_str(), "https://github.com/fixture/repo.git"),
        ("protocol.file.allow", "always"),
    ] {
        git(&project, &["config", key, value]);
    }
    // The project folder's own work is never touched by a checkout.
    fs::write(project.join("README.md"), "uncommitted edit\n").unwrap();
    fs::write(project.join("scratch.txt"), "untracked\n").unwrap();
    let data = top.join("data");
    fs::create_dir(&data).unwrap();
    let store = Store::open(&data.join("data.sqlite")).unwrap();
    Fixture {
        _directory: directory,
        store,
        project,
        base,
        main,
        feature,
        fork,
    }
}
fn source(fixture: &Fixture, number: u64, head: &str) -> Source {
    Source {
        store: StoreSource::capture(&fixture.store).unwrap(),
        project_id: "00000000-0000-0000-0000-00000000000A".into(),
        project_path: json!(fixture.project),
        root: fixture.project.clone(),
        storage: fixture.store.data_directory().unwrap(),
        repository: "fixture/repo".into(),
        number,
        head: head.into(),
        gh: std::env::current_exe().unwrap(),
        prefix: DEFAULT_PREFIX.into(),
        _activity: None,
    }
}
fn pr(number: u64, head: &str, branch: &str, fork: Option<(&str, bool)>) -> Value {
    json!({
        "number":number,"url":format!("https://github.com/fixture/repo/pull/{number}"),"state":"OPEN",
        "headRefOid":head,"headRefName":branch,"baseRefName":"main",
        "isCrossRepository":fork.is_some(),
        "headRepository":{"id":"R","name":"repo"},
        "headRepositoryOwner":{"id":"U","login":fork.map_or("fixture",|(owner,_)|owner)},
        "maintainerCanModify":fork.is_some_and(|(_,can)|can),
    })
}
/// A local stand-in for gh: PR metadata and git_protocol, recording calls.
struct Gh {
    pulls: HashMap<u64, Value>,
    protocol: &'static str,
    calls: Vec<Vec<String>>,
}
impl Gh {
    fn new(pulls: impl IntoIterator<Item = Value>) -> Self {
        Self {
            pulls: pulls
                .into_iter()
                .map(|pr| (pr["number"].as_u64().unwrap(), pr))
                .collect(),
            protocol: "https",
            calls: Vec::new(),
        }
    }
    fn answer(&mut self, args: &[String]) -> Result<Vec<u8>> {
        self.calls.push(args.to_vec());
        match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
            [
                "pr",
                "view",
                number,
                "--json",
                FIELDS,
                "--repo",
                "github.com/fixture/repo",
            ] => {
                let pr = self
                    .pulls
                    .get(&number.parse::<u64>()?)
                    .context("no such fixture PR")?;
                Ok(serde_json::to_vec(pr)?)
            }
            ["config", "get", "git_protocol", "--host", "github.com"] => {
                Ok(format!("{}\n", self.protocol).into_bytes())
            }
            _ => bail!("unexpected gh arguments {args:?}"),
        }
    }
}
fn run(source: &Source, gh: &mut Gh) -> Result<Checkout> {
    check_out(source, &mut |args| gh.answer(args), &AtomicBool::new(false))
}
fn failure(result: Result<Checkout>) -> Failure {
    result
        .expect_err("checkout must fail")
        .downcast::<Failure>()
        .expect("checkout failures are Swift-style messages")
}
fn worktree_count(project: &Path) -> usize {
    git(project, &["worktree", "list", "--porcelain"])
        .lines()
        .filter(|line| line.starts_with("worktree "))
        .count()
}
fn config(directory: &Path, key: &str) -> String {
    git(directory, &["config", "--get", key])
}
fn assert_project_untouched(fixture: &Fixture) {
    assert_eq!(git(&fixture.project, &["rev-parse", "HEAD"]), fixture.main);
    assert_eq!(
        git(&fixture.project, &["symbolic-ref", "--short", "HEAD"]),
        "main"
    );
    // The fixture helper trims, so the first record loses its leading space.
    let status = git(&fixture.project, &["status", "--porcelain=v1"]);
    let status = status.lines().map(str::trim).collect::<Vec<_>>();
    assert_eq!(status, ["M README.md", "?? scratch.txt"]);
    assert_eq!(
        fs::read_to_string(fixture.project.join("README.md")).unwrap(),
        "uncommitted edit\n"
    );
}

#[test]
fn checkout_same_repository_pr_tracks_its_branch_and_reuses_the_worktree() {
    let fixture = fixture(false);
    let mut gh = Gh::new([pr(7, &fixture.feature, "feature", None)]);
    let source = source(&fixture, 7, &fixture.feature);
    let checkout = run(&source, &mut gh).unwrap();
    let expected = source
        .storage
        .join("worktrees")
        .join("project")
        .join("feature");
    assert_eq!(
        checkout,
        Checkout {
            path: expected.canonicalize().unwrap(),
            branch: "feature".into(),
            reused: false,
            number: 7,
        }
    );
    let path = &checkout.path;
    assert_eq!(git(path, &["rev-parse", "HEAD"]), fixture.feature);
    assert_eq!(git(path, &["symbolic-ref", "--short", "HEAD"]), "feature");
    // Windows runners check text out with core.autocrlf.
    assert_eq!(
        fs::read_to_string(path.join("feature.txt"))
            .unwrap()
            .trim_end(),
        "feature"
    );
    assert_eq!(config(path, "branch.feature.remote"), "origin");
    assert_eq!(config(path, "branch.feature.merge"), "refs/heads/feature");
    assert_eq!(config(path, "branch.feature.coincide-merge-base"), "main");
    assert_project_untouched(&fixture);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(source.storage.join("worktrees"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o077, 0, "worktrees folder must be owner-only");
    }
    // An existing remote answers the fetch; gh is asked only for metadata.
    assert_eq!(gh.calls.len(), 1);
    // A worktree that already has the branch is used as it is, even when the
    // pull request has moved on since: Swift never refetches into it.
    fs::write(path.join("feature.txt"), "local work\n").unwrap();
    let mut moved = Gh::new([pr(7, &fixture.fork, "feature", None)]);
    let reused = run(&source, &mut moved).unwrap();
    assert_eq!(
        reused,
        Checkout {
            reused: true,
            ..checkout.clone()
        }
    );
    assert_eq!(
        fs::read_to_string(path.join("feature.txt")).unwrap(),
        "local work\n"
    );
    assert_eq!(worktree_count(&fixture.project), 2);
}

#[test]
fn checkout_fork_pr_fetches_the_pull_ref_and_pushes_back_like_gh() {
    let fixture = fixture(false);
    let mut gh = Gh::new([
        pr(8, &fixture.fork, "Main", Some(("forker", true))),
        pr(9, &fixture.fork, "Main", Some(("forker", false))),
    ]);
    gh.protocol = "ssh";
    let checkout = run(&source(&fixture, 8, &fixture.fork), &mut gh).unwrap();
    assert_eq!(checkout.branch, "coincide/pr-8/main");
    assert!(!checkout.reused);
    assert_eq!(
        checkout.path.file_name().unwrap().to_str().unwrap(),
        "coincide-pr-8-main"
    );
    let path = &checkout.path;
    assert_eq!(git(path, &["rev-parse", "HEAD"]), fixture.fork);
    assert_eq!(
        git(path, &["symbolic-ref", "--short", "HEAD"]),
        "coincide/pr-8/main"
    );
    // Maintainers may push: the fork's own branch, in gh's configured protocol.
    let fork = "git@github.com:forker/repo.git";
    assert_eq!(config(path, "branch.coincide/pr-8/main.remote"), fork);
    assert_eq!(config(path, "branch.coincide/pr-8/main.pushRemote"), fork);
    assert_eq!(
        config(path, "branch.coincide/pr-8/main.merge"),
        "refs/heads/Main"
    );
    // Otherwise the base remote's pull ref, which `git pull` can still follow.
    let other = run(&source(&fixture, 9, &fixture.fork), &mut gh).unwrap();
    assert_eq!(other.branch, "coincide/pr-9/main");
    assert_eq!(
        config(&other.path, "branch.coincide/pr-9/main.remote"),
        "origin"
    );
    assert_eq!(
        config(&other.path, "branch.coincide/pr-9/main.merge"),
        "refs/pull/9/head"
    );
    assert_eq!(
        git(&fixture.project, &["for-each-ref", "refs/coincide/"]),
        ""
    );
    assert_project_untouched(&fixture);
    // Only the maintainer-writable fork needed gh's protocol, and only once.
    let protocol = gh
        .calls
        .iter()
        .filter(|call| call.first().is_some_and(|c| c == "config"))
        .count();
    assert_eq!(protocol, 1);
}

#[test]
fn checkout_without_a_base_remote_fetches_the_github_url_and_names_the_prefix() {
    let fixture = fixture(false);
    git(
        &fixture.project,
        &["remote", "rename", "origin", "elsewhere"],
    );
    git(
        &fixture.project,
        &["config", "remote.elsewhere.url", &slash(&fixture.base)],
    );
    let mut gh = Gh::new([pr(9, &fixture.fork, "Main", Some(("forker", false)))]);
    let mut source = source(&fixture, 9, &fixture.fork);
    source.prefix = String::new();
    let checkout = run(&source, &mut gh).unwrap();
    assert_eq!(checkout.branch, "pr-9/main");
    assert_eq!(git(&checkout.path, &["rev-parse", "HEAD"]), fixture.fork);
    assert_eq!(
        config(&checkout.path, "branch.pr-9/main.remote"),
        "https://github.com/fixture/repo.git"
    );
}

#[test]
fn checkout_refuses_the_project_folder_branch_and_moved_heads_without_making_anything() {
    let fixture = fixture(false);
    let storage = fixture.store.data_directory().unwrap();
    let mut gh = Gh::new([
        pr(11, &fixture.main, "main", None),
        pr(7, &fixture.fork, "feature", None),
        pr(12, &fixture.fork, "Main", Some(("forker", false))),
    ]);
    let refused = failure(run(&source(&fixture, 11, &fixture.main), &mut gh));
    assert_eq!(
        refused,
        Failure {
            message: "Pull request #11’s branch is checked out in the project folder.".into(),
            detail: Some("Switch the project folder to another branch, or start a thread in the project folder instead.".into()),
        }
    );
    // GitHub reports a newer head than the one displayed.
    let moved = failure(run(&source(&fixture, 7, &fixture.feature), &mut gh));
    assert_eq!(moved, Failure::changed(7));
    // GitHub's metadata agrees with the display, but the fetched ref does not.
    let fetched = failure(run(&source(&fixture, 12, &fixture.fork), &mut gh));
    assert_eq!(fetched, Failure::changed(12));
    assert!(git(&fixture.project, &["branch", "--list", "coincide/pr-12/*"]).is_empty());
    assert_eq!(
        git(&fixture.project, &["for-each-ref", "refs/coincide/"]),
        ""
    );
    let mut closed = pr(7, &fixture.feature, "feature", None);
    closed["state"] = json!("CLOSED");
    let closed = failure(run(
        &source(&fixture, 7, &fixture.feature),
        &mut Gh::new([closed]),
    ));
    assert_eq!(closed.message, "Pull request #7 is no longer open.");
    let mut unrelated = pr(7, &fixture.feature, "feature", None);
    unrelated["url"] = json!("https://github.com/attacker/repo/pull/7");
    let unrelated = failure(run(
        &source(&fixture, 7, &fixture.feature),
        &mut Gh::new([unrelated]),
    ));
    assert_eq!(unrelated.message, "Could not check out pull request #7.");
    let mut plain = source(&fixture, 7, &fixture.feature);
    plain.root = storage.clone();
    assert_eq!(
        failure(run(&plain, &mut Gh::new([]))),
        Failure::new(NOT_REPOSITORY, None)
    );
    assert_eq!(worktree_count(&fixture.project), 1);
    assert!(!storage.join("worktrees").join("project").exists());
    assert_project_untouched(&fixture);
}

#[test]
fn checkout_fast_forwards_an_existing_branch_but_never_rewinds_it() {
    let fixture = fixture(false);
    // Behind the pull request: fast-forwarded, as gh's `merge --ff-only` does.
    git(&fixture.project, &["branch", "feature", &fixture.main]);
    let mut gh = Gh::new([
        pr(7, &fixture.feature, "feature", None),
        pr(8, &fixture.fork, "Main", Some(("forker", false))),
    ]);
    let checkout = run(&source(&fixture, 7, &fixture.feature), &mut gh).unwrap();
    assert_eq!(git(&checkout.path, &["rev-parse", "HEAD"]), fixture.feature);
    // Diverged from the pull ref: refused like gh's non-forced fetch.
    let seed = fixture.base.parent().unwrap().join("seed");
    git(&seed, &["checkout", "-q", "-b", "diverged", &fixture.main]);
    let diverged = commit(&seed, "local.txt", "local\n");
    git(
        &seed,
        &[
            "push",
            "-q",
            &slash(&fixture.base),
            "diverged:refs/heads/diverged",
        ],
    );
    git(&fixture.project, &["fetch", "-q", "origin", "diverged"]);
    git(
        &fixture.project,
        &["branch", "coincide/pr-8/main", &diverged],
    );
    let refused = failure(run(&source(&fixture, 8, &fixture.fork), &mut gh));
    assert_eq!(
        refused,
        Failure::checkout(
            8,
            "! [rejected] refs/pull/8/head -> coincide/pr-8/main (non-fast-forward)"
        )
    );
    assert_eq!(
        git(&fixture.project, &["rev-parse", "coincide/pr-8/main"]),
        diverged
    );
    assert_eq!(worktree_count(&fixture.project), 2);
    assert_eq!(
        git(&fixture.project, &["for-each-ref", "refs/coincide/"]),
        ""
    );
}

#[test]
fn checkout_removes_its_worktree_when_submodules_fail_and_honors_cancellation() {
    let fixture = fixture(true);
    let mut gh = Gh::new([pr(7, &fixture.feature, "feature", None)]);
    let source = source(&fixture, 7, &fixture.feature);
    let failed = failure(run(&source, &mut gh));
    assert_eq!(failed.message, "Could not check out pull request #7.");
    assert!(failed.detail.is_some());
    assert_eq!(worktree_count(&fixture.project), 1);
    assert!(
        !source
            .storage
            .join("worktrees")
            .join("project")
            .join("feature")
            .exists()
    );
    let cancelled = AtomicBool::new(true);
    let error = check_out(&source, &mut |args| gh.answer(args), &cancelled)
        .err()
        .unwrap()
        .downcast::<Failure>()
        .unwrap();
    assert_eq!(error, Failure::checkout(7, "Checkout cancelled"));
    assert_eq!(worktree_count(&fixture.project), 1);
}

#[test]
fn checkout_branch_names_remote_urls_and_messages_match_swift_and_gh() {
    assert_eq!(
        sanitize_fragment("  Fix the Login Bug! "),
        "fix-the-login-bug"
    );
    assert_eq!(sanitize_fragment("feat//Search__UI"), "feat/search__ui");
    assert_eq!(sanitize_fragment("..."), "update");
    assert_eq!(sanitize_fragment("it's `quoted`"), "its-quoted");
    assert_eq!(sanitize_fragment(&"a".repeat(70)), "a".repeat(64));
    assert_eq!(
        local_branch(false, 12, "fix-parser", "coincide/"),
        "fix-parser"
    );
    assert_eq!(
        local_branch(true, 12, "Main", "coincide/"),
        "coincide/pr-12/main"
    );
    assert_eq!(local_branch(true, 12, "Main", ""), "pr-12/main");
    for (url, expected) in [
        ("https://github.com/Owner/Repo.git", Some(("Owner", "Repo"))),
        ("https://token@github.com/o/r", Some(("o", "r"))),
        ("git@github.com:o/r.git", Some(("o", "r"))),
        ("ssh://git@github.com:22/o/r.git/", Some(("o", "r"))),
        ("https://www.github.com/o/r", Some(("o", "r"))),
        ("https://gitlab.com/o/r.git", None),
        ("https://github.com/o", None),
        ("file:///github.com/o/r", None),
        ("/tmp/github.com/o/r.git", None),
        ("ext::sh -c touch% /tmp/x", None),
    ] {
        assert_eq!(
            github_repository(url),
            expected.map(|(o, r)| (o.to_owned(), r.to_owned())),
            "{url}"
        );
    }
    let remotes = parse_remotes(
        b"remote.origin.url\nhttps://github.com/me/repo.git\0remote.upstream.url\ngit@github.com:base/repo.git\0remote.-x.url\nhttps://github.com/bad/repo\0remote.lab.url\nhttps://gitlab.com/o/r\0",
    );
    assert_eq!(
        remotes.iter().map(|r| r.name.as_str()).collect::<Vec<_>>(),
        ["upstream", "origin"]
    );
    assert_eq!(
        find_remote(&remotes, "BASE", "Repo").unwrap().name,
        "upstream"
    );
    let output = Output {
        code: 128,
        stdout: Vec::new(),
        stderr: b"hint: try again\nfatal: unable to access 'https://x-access-token:secret@github.com/o/r.git/': denied\n".to_vec(),
    };
    assert_eq!(
        failure_detail(&output),
        "fatal: unable to access 'https://github.com/o/r.git/': denied"
    );
    let locked = Output {
        code: 128,
        stdout: Vec::new(),
        stderr: b"fatal: Unable to create '/r/.git/index.lock': File exists.\n".to_vec(),
    };
    assert!(failure_detail(&locked).starts_with("fatal: Unable"));
    let locked = Output {
        code: 128,
        stdout: Vec::new(),
        stderr: b"error: unable to create '/r/.git/index.lock': File exists.\n".to_vec(),
    };
    assert_eq!(failure_detail(&locked), INDEX_LOCKED);
    assert_eq!(
        failure_detail(&Output {
            code: 3,
            stdout: Vec::new(),
            stderr: Vec::new()
        }),
        "Exit status 3."
    );
    assert_eq!(portable("a/b:c"), "a-b-c");
    assert_eq!(portable("con.d"), "_con.d");
    assert_eq!(portable("trail. "), "trail");
    assert_eq!(portable(".."), "worktree");
}

fn execute(engine: &mut Engine, method: &str, params: Value) -> Value {
    let value = engine.dispatch(json!({"method":method,"params":params}));
    assert!(value.get("error").is_none(), "{}", value);
    value["result"].clone()
}
#[test]
fn checkout_opens_one_conversation_per_worktree_and_has_no_json_route() {
    let directory = tempfile::tempdir().unwrap();
    let top = directory.path().canonicalize().unwrap();
    let project_path = top.join("project");
    let worktree = top
        .join("data")
        .join("worktrees")
        .join("project")
        .join("feature");
    fs::create_dir_all(&project_path).unwrap();
    fs::create_dir_all(&worktree).unwrap();
    let mut engine = Engine::fixture(Store::open(&top.join("data").join("data.sqlite")).unwrap());
    let project = execute(&mut engine, "projects.create", json!({"path":project_path}));
    execute(
        &mut engine,
        "projects.patch",
        json!({"projectId":project["id"],"patch":{"isExpanded":false}}),
    );
    let thread = execute(
        &mut engine,
        "threads.create",
        json!({"projectId":project["id"]}),
    );
    let id = thread["id"].as_str().unwrap();
    // This engine has no GitHub CLI, so checkout explains how to set it up.
    let setup = engine
        .native_github_checkout_source(id, &project_path, "fixture/repo", 7, &"a".repeat(40))
        .err()
        .unwrap();
    assert_eq!(setup.to_string(), SETUP);
    assert!(
        engine
            .native_github_checkout_source(id, &top, "fixture/repo", 7, &"a".repeat(40))
            .is_err()
    );
    let source = Source {
        store: StoreSource::capture(&engine.store).unwrap(),
        project_id: project["id"].as_str().unwrap().into(),
        project_path: project["path"].clone(),
        root: project_path.clone(),
        storage: engine.store.data_directory().unwrap(),
        repository: "fixture/repo".into(),
        number: 7,
        head: "a".repeat(40),
        gh: std::env::current_exe().unwrap(),
        prefix: DEFAULT_PREFIX.into(),
        _activity: None,
    };
    let checkout = Checkout {
        path: worktree.clone(),
        branch: "feature".into(),
        reused: false,
        number: 7,
    };
    let opened = engine
        .native_open_github_checkout(&source, &checkout)
        .unwrap();
    assert_ne!(opened["id"], thread["id"]);
    assert_eq!(opened["projectID"], project["id"]);
    assert_eq!(opened["worktreePath"], worktree.to_str().unwrap());
    assert_eq!(opened["branch"], "feature");
    assert_eq!(
        engine.store.thread(opened["id"].as_str().unwrap()).unwrap(),
        opened
    );
    let projects = engine.store.projects().unwrap();
    assert_eq!(projects[0]["isExpanded"], true);
    // Checking the same pull request out again reuses the untouched conversation.
    let again = engine
        .native_open_github_checkout(&source, &checkout)
        .unwrap();
    assert_eq!(again["id"], opened["id"]);
    // Once it has a draft, another conversation is opened instead.
    let mut drafted = again.clone();
    drafted["draft"] = json!("work in progress");
    engine.store.save(&drafted).unwrap();
    let third = engine
        .native_open_github_checkout(&source, &checkout)
        .unwrap();
    assert_ne!(third["id"], opened["id"]);
    // The worktree disappearing or the project moving stops admission.
    let mut moved = source;
    moved.project_path = json!(top);
    assert!(
        engine
            .native_open_github_checkout(&moved, &checkout)
            .is_err()
    );
    let denied = engine.dispatch(json!({"method":"github.pr.checkout","params":{"threadId":id,"repository":"fixture/repo","number":7}}));
    assert!(denied.get("error").is_some());
}

/// The production path end to end: the Engine's configured gh (a local script
/// answering from fixture files), the owned Git runner and thread admission.
#[cfg(unix)]
#[test]
fn checkout_runs_from_engine_capture_through_a_configured_gh_to_a_new_thread() {
    use std::os::unix::fs::PermissionsExt;
    let Fixture {
        _directory,
        store,
        project,
        feature,
        ..
    } = fixture(false);
    let tools = project.parent().unwrap().join("tools");
    fs::create_dir(&tools).unwrap();
    fs::write(
        tools.join("pr-7.json"),
        serde_json::to_vec(&pr(7, &feature, "feature", None)).unwrap(),
    )
    .unwrap();
    let gh = tools.join("gh");
    fs::write(
        &gh,
        "#!/bin/sh\ncase \"$1 $2\" in\n\"pr view\") exec cat \"$(dirname \"$0\")/pr-$3.json\" ;;\n*) exit 1 ;;\nesac\n",
    )
    .unwrap();
    fs::set_permissions(&gh, fs::Permissions::from_mode(0o755)).unwrap();
    let mut engine = Engine::fixture(store);
    engine.use_github_cli_for_checkout_tests(&gh);
    let created = execute(&mut engine, "projects.create", json!({"path":project}));
    let thread = execute(
        &mut engine,
        "threads.create",
        json!({"projectId":created["id"]}),
    );
    let source = engine
        .native_github_checkout_source(
            thread["id"].as_str().unwrap(),
            &project,
            "fixture/repo",
            7,
            &feature.to_ascii_uppercase(),
        )
        .unwrap();
    assert_eq!(source.head, feature);
    let checkout = super::run(&source, &AtomicBool::new(false)).unwrap();
    assert!(!checkout.reused);
    assert_eq!(git(&checkout.path, &["rev-parse", "HEAD"]), feature);
    let opened = engine
        .native_open_github_checkout(&source, &checkout)
        .unwrap();
    assert_eq!(opened["worktreePath"], checkout.path.to_str().unwrap());
    assert_eq!(opened["branch"], "feature");
    assert_ne!(opened["id"], thread["id"]);
    // The source conversation stays where it was.
    let original = engine.store.thread(thread["id"].as_str().unwrap()).unwrap();
    assert!(original["worktreePath"].is_null());
}
