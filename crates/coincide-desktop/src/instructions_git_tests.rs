//! Every Git repository/remote is synthetic and private. Git system/global
//! config is explicitly excluded; no credential manager or network is used.
use super::*;
use std::process::{Command, Stdio};
struct Fixture {
    root: PathBuf,
    repo: PathBuf,
    store: coincide_core::store::Store,
    copy: NativeScope,
}
fn git(root: &Path, args: &[&str]) -> Vec<u8> {
    let mut command = Command::new("git");
    for (name, _) in std::env::vars_os() {
        if name.to_string_lossy().starts_with("GIT_") {
            command.env_remove(name);
        }
    }
    let output = command
        .args([
            "-c",
            "protocol.allow=never",
            "-c",
            "protocol.file.allow=always",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "core.autocrlf=false",
        ])
        .args(args)
        .current_dir(root)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env(
            "GIT_CONFIG_GLOBAL",
            if cfg!(windows) { "NUL" } else { "/dev/null" },
        )
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "Synthetic local Git fixture command failed"
    );
    output.stdout
}
impl Fixture {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "coincide-git-copy-fixture-{}",
            uuid::Uuid::new_v4()
        ));
        native_file::private_directory(&root).unwrap();
        let repo = root.join("repo");
        fs::create_dir(&repo).unwrap();
        git(&repo, &["init", "--initial-branch=main"]);
        git(&repo, &["config", "user.name", "Synthetic Test"]);
        git(
            &repo,
            &["config", "user.email", "synthetic@example.invalid"],
        );
        git(&repo, &["config", "commit.gpgsign", "false"]);
        git(&repo, &["config", "core.autocrlf", "false"]);
        git(
            &repo,
            &["commit", "--allow-empty", "-m", "Synthetic initial"],
        );
        let data = root.join("data");
        native_file::private_directory(&data).unwrap();
        let mut store = coincide_core::store::Store::open(&data.join("state.sqlite")).unwrap();
        let project = store
            .create_project(&repo, Some("Synthetic instruction Git"))
            .unwrap();
        let mut copy =
            NativeScope::project_native(&store, project["id"].as_str().unwrap()).unwrap();
        copy.choose_master_native(repo.join(name), &store).unwrap();
        fs::write(copy.master_path(), "Approved instruction copy\n").unwrap();
        Self {
            root,
            repo,
            store,
            copy,
        }
    }
    fn review(&self) -> Review {
        Review::capture(
            self.repo.clone(),
            self.copy.clone(),
            StoreSource::capture(&self.store).unwrap(),
            Runner::isolated().unwrap(),
            &AtomicBool::new(false),
            || self.copy.validate_native(&self.store),
        )
        .unwrap()
    }
    fn remote(&self) -> PathBuf {
        let bare = self.root.join("origin.git");
        fs::create_dir(&bare).unwrap();
        git(&bare, &["init", "--bare", "--initial-branch=main"]);
        git(
            &self.repo,
            &["remote", "add", "origin", bare.to_str().unwrap()],
        );
        bare
    }
    fn peer(&self, bare: &Path) -> PathBuf {
        let peer = self.root.join("peer");
        git(
            &self.root,
            &[
                "clone",
                "--branch",
                "main",
                bare.to_str().unwrap(),
                peer.to_str().unwrap(),
            ],
        );
        git(&peer, &["config", "user.name", "Synthetic Peer"]);
        git(&peer, &["config", "user.email", "peer@example.invalid"]);
        git(&peer, &["config", "commit.gpgsign", "false"]);
        git(&peer, &["config", "core.autocrlf", "false"]);
        peer
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.store.close_for_shutdown();
        let _ = fs::remove_dir_all(&self.root);
    }
}
#[::core::prelude::v1::test]
fn literal_copy_commit_preserves_unrelated_staged_and_unstaged_versions() {
    let names = if cfg!(windows) {
        vec!["-copy.md"]
    } else {
        vec!["-copy.md", ":(glob)*.md", "back\\slash.md"]
    };
    for name in names {
        let fixture = Fixture::new(name);
        fs::write(fixture.repo.join("other.txt"), "original").unwrap();
        git(&fixture.repo, &["add", "other.txt"]);
        git(&fixture.repo, &["commit", "-m", "Synthetic other baseline"]);
        fs::write(fixture.repo.join("other.txt"), "staged").unwrap();
        git(&fixture.repo, &["add", "other.txt"]);
        fs::write(fixture.repo.join("other.txt"), "unstaged").unwrap();
        let applied = fixture
            .review()
            .apply(None, false, &AtomicBool::new(false), || {
                fixture.copy.validate_native(&fixture.store)
            })
            .unwrap();
        assert!(applied.committed && !applied.pushed && !applied.pulled);
        assert_eq!(
            git(&fixture.repo, &["show", &format!("HEAD:{name}")]),
            b"Approved instruction copy\n"
        );
        assert_eq!(git(&fixture.repo, &["show", "HEAD:other.txt"]), b"original");
        assert_eq!(git(&fixture.repo, &["show", ":other.txt"]), b"staged");
        assert_eq!(
            fs::read(fixture.repo.join("other.txt")).unwrap(),
            b"unstaged"
        );
    }
}
#[::core::prelude::v1::test]
fn same_destination_local_bare_push_and_incoming_fast_forward_are_real() {
    let fixture = Fixture::new("Instructions.md");
    let bare = fixture.remote();
    let first = fixture
        .review()
        .apply(Some(0), true, &AtomicBool::new(false), || {
            fixture.copy.validate_native(&fixture.store)
        })
        .unwrap();
    assert!(first.committed && first.pushed && !first.pulled);
    assert_eq!(
        git(&bare, &["show", "main:Instructions.md"]),
        b"Approved instruction copy\n"
    );
    let peer = fixture.peer(&bare);
    fs::write(peer.join("Instructions.md"), "Remote copy\n").unwrap();
    git(&peer, &["add", "Instructions.md"]);
    git(&peer, &["commit", "-m", "Synthetic remote copy"]);
    git(&peer, &["push", "origin", "HEAD:refs/heads/main"]);
    let second = fixture
        .review()
        .apply(Some(0), true, &AtomicBool::new(false), || {
            fixture.copy.validate_native(&fixture.store)
        })
        .unwrap();
    assert!(second.pulled && !second.committed && !second.pushed);
    assert_eq!(
        fs::read(fixture.copy.master_path()).unwrap(),
        b"Remote copy\n"
    );
    assert!(
        git(
            &fixture.repo,
            &["for-each-ref", "refs/coincide/instructions/"]
        )
        .is_empty()
    );
}
#[::core::prelude::v1::test]
fn every_outgoing_commit_is_checked_and_unrelated_history_is_not_pushed() {
    let fixture = Fixture::new("Instructions.md");
    let bare = fixture.remote();
    fixture
        .review()
        .apply(Some(0), true, &AtomicBool::new(false), || Ok(()))
        .unwrap();
    let remote_before = git(&bare, &["rev-parse", "main"]);
    fs::write(fixture.repo.join("unrelated.txt"), "Must remain local").unwrap();
    git(&fixture.repo, &["add", "unrelated.txt"]);
    git(
        &fixture.repo,
        &["commit", "-m", "Synthetic unrelated local commit"],
    );
    fs::write(
        fixture.copy.master_path(),
        "A later approved instruction copy\n",
    )
    .unwrap();
    let error = fixture
        .review()
        .apply(Some(0), true, &AtomicBool::new(false), || Ok(()))
        .err()
        .unwrap();
    assert!(
        error
            .to_string()
            .contains("Outgoing history changes files outside"),
        "{error}"
    );
    assert_eq!(git(&bare, &["rev-parse", "main"]), remote_before);
    assert_eq!(
        fs::read(fixture.repo.join("unrelated.txt")).unwrap(),
        b"Must remain local"
    );
    assert_eq!(
        git(&fixture.repo, &["show", "HEAD:Instructions.md"]),
        b"A later approved instruction copy\n"
    );
    assert!(
        git(
            &fixture.repo,
            &["for-each-ref", "refs/coincide/instructions/"]
        )
        .is_empty()
    );
}
#[::core::prelude::v1::test]
fn stale_copy_config_and_split_push_destination_never_gain_new_review_authority() {
    for change in ["same-bytes", "config", "split-push"] {
        let fixture = Fixture::new("Instructions.md");
        fixture.remote();
        let review = fixture.review();
        let before = git(&fixture.repo, &["rev-parse", "HEAD"]);
        if change == "same-bytes" {
            fs::rename(fixture.copy.master_path(), fixture.repo.join("old-copy.md")).unwrap();
            fs::write(fixture.copy.master_path(), "Approved instruction copy\n").unwrap();
        } else if change == "config" {
            git(
                &fixture.repo,
                &["config", "user.name", "Changed after native review"],
            );
        } else {
            let other = fixture.root.join("other.git");
            fs::create_dir(&other).unwrap();
            git(&other, &["init", "--bare"]);
            git(
                &fixture.repo,
                &[
                    "remote",
                    "set-url",
                    "--push",
                    "origin",
                    other.to_str().unwrap(),
                ],
            );
            let fresh = fixture.review();
            assert!(!fresh.can_push(0));
            assert!(
                fresh
                    .apply(Some(0), true, &AtomicBool::new(false), || Ok(()))
                    .is_err()
            );
        }
        assert!(
            review
                .apply(Some(0), true, &AtomicBool::new(false), || Ok(()))
                .is_err()
        );
        assert_eq!(git(&fixture.repo, &["rev-parse", "HEAD"]), before);
        assert_eq!(
            fs::read(fixture.copy.master_path()).unwrap(),
            b"Approved instruction copy\n"
        );
    }
}
#[::core::prelude::v1::test]
fn remote_credentials_are_refused_without_echo_and_metadata_labels_do_not_retain_repository_urls() {
    for value in [
        "https://synthetic-secret@example.invalid/repo\n",
        "https://example.invalid/repo?token=synthetic-secret\n",
        "ext::arbitrary command\n",
    ] {
        let error = safe_remote_digest(value.as_bytes())
            .err()
            .unwrap()
            .to_string();
        assert!(!error.contains("synthetic-secret") && !error.contains("arbitrary command"));
    }
    assert_eq!(
        sanitized_hosts(b"https://example.invalid/private/repository.git\n").unwrap(),
        "https://example.invalid"
    );
    assert_eq!(
        sanitized_hosts(b"git@example.invalid:private/repository.git\n").unwrap(),
        "ssh://example.invalid"
    );
}
#[::core::prelude::v1::test]
fn divergent_copy_commit_rebases_onto_remote_changes_without_publishing_unrelated_local_history() {
    let fixture = Fixture::new("Instructions.md");
    let bare = fixture.remote();
    fixture
        .review()
        .apply(Some(0), true, &AtomicBool::new(false), || Ok(()))
        .unwrap();
    let peer = fixture.peer(&bare);
    fs::write(peer.join("remote-note.txt"), "Remote repository change\n").unwrap();
    git(&peer, &["add", "remote-note.txt"]);
    git(&peer, &["commit", "-m", "Synthetic incoming other file"]);
    git(&peer, &["push", "origin", "HEAD:refs/heads/main"]);
    fs::write(fixture.copy.master_path(), "Approved local copy change\n").unwrap();
    let result = fixture
        .review()
        .apply(Some(0), true, &AtomicBool::new(false), || Ok(()))
        .unwrap();
    assert!(result.committed && result.pulled && result.pushed);
    assert_eq!(
        git(&bare, &["show", "main:Instructions.md"]),
        b"Approved local copy change\n"
    );
    assert_eq!(
        git(&bare, &["show", "main:remote-note.txt"]),
        b"Remote repository change\n"
    );
    assert!(
        git(
            &fixture.repo,
            &["for-each-ref", "refs/coincide/instructions/"]
        )
        .is_empty()
    );
}
#[::core::prelude::v1::test]
fn incoming_updates_refuse_unrelated_dirty_work_and_conflicting_rebase_is_aborted() {
    for conflict in [false, true] {
        let fixture = Fixture::new("Instructions.md");
        let bare = fixture.remote();
        fixture
            .review()
            .apply(Some(0), true, &AtomicBool::new(false), || Ok(()))
            .unwrap();
        let peer = fixture.peer(&bare);
        if conflict {
            fs::write(peer.join("Instructions.md"), "Conflicting remote copy\n").unwrap();
            git(&peer, &["add", "Instructions.md"]);
        } else {
            fs::write(peer.join("incoming.txt"), "Remote change").unwrap();
            git(&peer, &["add", "incoming.txt"]);
        }
        git(&peer, &["commit", "-m", "Synthetic remote divergence"]);
        git(&peer, &["push", "origin", "HEAD:refs/heads/main"]);
        if conflict {
            fs::write(fixture.copy.master_path(), "Conflicting local copy\n").unwrap();
        } else {
            fs::write(
                fixture.repo.join("unrelated-draft.txt"),
                "Unrelated unsaved work",
            )
            .unwrap();
        }
        let before = git(&fixture.repo, &["rev-parse", "HEAD"]);
        let error = fixture
            .review()
            .apply(Some(0), true, &AtomicBool::new(false), || Ok(()))
            .err()
            .unwrap();
        if conflict {
            assert!(error.to_string().contains("rebase stopped"), "{error}");
            assert_eq!(
                fs::read(fixture.copy.master_path()).unwrap(),
                b"Conflicting local copy\n"
            );
            assert_eq!(
                git(&fixture.repo, &["symbolic-ref", "--short", "HEAD"]),
                b"main\n"
            );
            assert!(!fixture.repo.join(".git/rebase-merge").exists());
            assert!(!fixture.repo.join(".git/rebase-apply").exists());
        } else {
            assert!(
                error.to_string().contains("Unrelated local edits"),
                "{error}"
            );
            assert_eq!(git(&fixture.repo, &["rev-parse", "HEAD"]), before);
            assert_eq!(
                fs::read(fixture.repo.join("unrelated-draft.txt")).unwrap(),
                b"Unrelated unsaved work"
            );
        }
        assert!(
            git(
                &fixture.repo,
                &["for-each-ref", "refs/coincide/instructions/"]
            )
            .is_empty()
        );
    }
}
