use super::*;

fn remotes(entries: &[(&str, &str)]) -> Vec<(String, String)> {
    entries
        .iter()
        .map(|(name, address)| ((*name).into(), (*address).into()))
        .collect()
}
fn ready(repository: &str) -> Availability {
    Availability::Ready(repository.into())
}

#[test]
fn remote_addresses_read_like_swift_git_remote_url() {
    for (address, host, path) in [
        (
            "https://github.com/owner/repo.git",
            "github.com",
            "owner/repo",
        ),
        (
            "https://user:p%40ss@GitHub.com:443/owner/repo",
            "github.com",
            "owner/repo",
        ),
        (
            "ssh://git@github.com:22/owner/repo.git",
            "github.com",
            "owner/repo",
        ),
        (
            "git+ssh://git@github.com/owner/repo",
            "github.com",
            "owner/repo",
        ),
        ("git@github.com:owner/repo.git", "github.com", "owner/repo"),
        ("github.com:owner/repo", "github.com", "owner/repo"),
        (
            "git://example.org/group/sub/project.git",
            "example.org",
            "group/sub/project",
        ),
        ("https://[::1]:8080/owner/repo", "[::1]", "owner/repo"),
        (
            "https://github.com/owner/my%20repo?x=1#top",
            "github.com",
            "owner/my repo",
        ),
        (
            "https://github.com/owner/repo/.git",
            "github.com",
            "owner/repo",
        ),
    ] {
        let parsed = RemoteUrl::parse(address).unwrap_or_else(|| panic!("{address}"));
        assert_eq!(parsed.hostname, host, "{address}");
        assert_eq!(parsed.path.join("/"), path, "{address}");
    }
    for address in [
        "",
        "/Users/me/repo",
        "../repo",
        "file:///Users/me/repo",
        "C:\\Users\\me\\repo",
        "C:/Users/me/repo",
        "host:repo",
        "https://github.com:99999/owner/repo",
        "https://github.com:12ab/owner/repo",
        "https://-github.com/owner/repo",
        "ftp://github.com/owner/repo",
        "https://github.com/owner/repo\nhttps://evil.example/owner/repo",
    ] {
        assert_eq!(RemoteUrl::parse(address), None, "{address}");
    }
}

#[test]
fn hosts_are_recognized_and_named_like_swift_source_control_host() {
    for (host, kind, name) in [
        ("github.com", Kind::Github, "GitHub"),
        ("github.example.com", Kind::Github, "GitHub"),
        ("acme.ghe.com", Kind::Github, "GitHub"),
        ("gitlab.com", Kind::Gitlab, "GitLab"),
        ("gitlab.example.com", Kind::Gitlab, "GitLab"),
        ("codeberg.org", Kind::Forgejo, "Codeberg"),
        ("gitea.example.com", Kind::Forgejo, "Gitea"),
        ("forgejo.example.com", Kind::Forgejo, "Forgejo"),
        // A name carrying several hosts' labels goes to the first in recognition order.
        ("gitea.github.example", Kind::Forgejo, "Gitea"),
        ("git.cafe", Kind::Gitcafe, "GitCafe"),
        ("bitbucket.org", Kind::Bitbucket, "Bitbucket"),
        ("dev.azure.com", Kind::AzureDevOps, "Azure DevOps"),
        ("acme.visualstudio.com", Kind::AzureDevOps, "Azure DevOps"),
        ("git.example.com", Kind::Unknown, "git.example.com"),
    ] {
        let recognized = Kind::recognize(host);
        assert_eq!(recognized, kind, "{host}");
        assert_eq!(recognized.display_name(host), name, "{host}");
    }
}

#[test]
fn states_follow_swift_order_for_the_primary_remote() {
    let none = HashMap::new();
    assert_eq!(decide(&[], &none), Availability::NoRemote);
    assert_eq!(
        decide(&remotes(&[("origin", "/srv/git/repo.git")]), &none),
        Availability::NoRemote
    );
    assert_eq!(
        decide(
            &remotes(&[("origin", "git@gitlab.com:group/project.git")]),
            &none
        ),
        Availability::UnsupportedHost {
            host: "GitLab".into(),
            self_hosted: false
        }
    );
    // Swift leaves these to gh; the read service lists github.com only.
    for (address, host) in [
        (
            "https://github.example.com/owner/repo",
            "github.example.com",
        ),
        ("git@git.example.com:owner/repo.git", "git.example.com"),
    ] {
        assert_eq!(
            decide(&remotes(&[("origin", address)]), &none),
            Availability::UnsupportedHost {
                host: host.into(),
                self_hosted: true
            }
        );
    }
    // gh reads every *.github.com host as github.com.
    assert_eq!(
        decide(
            &remotes(&[("origin", "ssh://git@ssh.github.com:443/owner/repo.git")]),
            &none
        ),
        ready("owner/repo")
    );
    // Without origin the first remote in Git's order decides the host.
    assert_eq!(
        decide(
            &remotes(&[
                ("fork", "https://gitlab.com/me/repo"),
                ("upstream", "https://github.com/org/repo"),
            ]),
            &none
        ),
        Availability::UnsupportedHost {
            host: "GitLab".into(),
            self_hosted: false
        }
    );
    // A GitHub primary remote whose path names no owner/name lists nothing.
    assert_eq!(
        decide(
            &remotes(&[("origin", "https://github.com/owner/repo/extra")]),
            &none
        ),
        Availability::NoRemote
    );
}

#[test]
fn repository_is_the_one_gh_would_list_without_repo() {
    let none = HashMap::new();
    let fork = remotes(&[
        ("mine", "git@github.com:someone/repo.git"),
        ("origin", "git@github.com:me/repo.git"),
        ("upstream", "https://github.com/org/repo.git"),
    ]);
    // gh ranks upstream, github, origin, then the rest.
    assert_eq!(decide(&fork, &none), ready("org/repo"));
    let named = remotes(&[
        ("github", "https://github.com/named/repo"),
        ("origin", "https://github.com/me/repo"),
    ]);
    assert_eq!(decide(&named, &none), ready("named/repo"));
    // Remotes on other hosts are never candidates, even when ranked first.
    let mixed = remotes(&[
        ("origin", "https://github.com/me/repo"),
        ("upstream", "https://gitlab.com/org/repo"),
    ]);
    assert_eq!(decide(&mixed, &none), ready("me/repo"));
    // `gh repo set-default` wins: `base` names the remote's own repository.
    let chosen = HashMap::from([("origin".to_string(), "base".to_string())]);
    assert_eq!(decide(&fork, &chosen), ready("me/repo"));
    let chosen = HashMap::from([("mine".to_string(), "parent/repo".to_string())]);
    assert_eq!(decide(&fork, &chosen), ready("parent/repo"));
    // A value the read service can't use is ignored.
    let chosen = HashMap::from([("origin".to_string(), "--repo=x/y".to_string())]);
    assert_eq!(decide(&fork, &chosen), ready("org/repo"));
    // Owner and name the read service would refuse never become a repository.
    assert_eq!(
        decide(
            &remotes(&[("origin", "https://github.com/-owner/repo")]),
            &none
        ),
        Availability::NoRemote
    );
}

#[test]
fn git_output_lines_are_read_strictly() {
    let output = "bare\t\n\
        fork\thttps://github.com/me/repo (fetch) [blob:none]\n\
        fork\thttps://github.com/me/repo (push)\n\
        origin\tgit@github.com:owner/repo.git (fetch)\n\
        origin\tgit@github.com:owner/repo.git (push)\n\
        spaced\t/Users/me/My Repo (fetch)\n";
    assert_eq!(
        fetch_remotes(output),
        remotes(&[
            ("fork", "https://github.com/me/repo"),
            ("origin", "git@github.com:owner/repo.git"),
            ("spaced", "/Users/me/My Repo"),
        ])
    );
    let resolved = resolutions(
        "remote.origin.gh-resolved base\nremote.my.fork.gh-resolved owner/repo\nremote.x.url y\n",
    );
    assert_eq!(resolved.len(), 2);
    assert_eq!(resolved["origin"], "base");
    assert_eq!(resolved["my.fork"], "owner/repo");
}

#[test]
fn json_names_each_state_for_the_panel() {
    assert_eq!(
        ready("owner/repo").to_json(),
        json!({"state":"ready","repository":"owner/repo"})
    );
    assert_eq!(
        Availability::UnsupportedHost {
            host: "GitLab".into(),
            self_hosted: false
        }
        .to_json(),
        json!({"state":"unsupportedHost","host":"GitLab","selfHosted":false})
    );
    for (state, name) in [
        (Availability::NotRepository, "notRepository"),
        (Availability::NoRemote, "noRemote"),
        (Availability::NeedsGitHubCli, "needsGitHubCli"),
    ] {
        assert_eq!(state.to_json(), json!({"state":name}));
    }
}

#[test]
fn actual_git_folder_inspection_without_network() {
    let git = |root: &Path, args: &[&str]| crate::workspace::git(root, args).unwrap();
    let directory = tempfile::tempdir().unwrap();
    let folder = directory.path().join("plain");
    std::fs::create_dir(&folder).unwrap();
    assert_eq!(inspect(&folder), Availability::NotRepository);
    let root = directory.path().join("repo");
    std::fs::create_dir(&root).unwrap();
    git(&root, &["init", "-q"]);
    // An unborn branch is still a repository.
    assert_eq!(inspect(&root), Availability::NoRemote);
    git(
        &root,
        &["remote", "add", "origin", "git@github.com:me/repo.git"],
    );
    assert_eq!(inspect(&root), ready("me/repo"));
    // A subdirectory lists its repository's pull requests, as gh does.
    let nested = root.join("src");
    std::fs::create_dir(&nested).unwrap();
    assert_eq!(inspect(&nested), ready("me/repo"));
    git(
        &root,
        &[
            "remote",
            "add",
            "upstream",
            "https://github.com/org/repo.git",
        ],
    );
    assert_eq!(inspect(&root), ready("org/repo"));
    git(&root, &["config", "remote.origin.gh-resolved", "base"]);
    assert_eq!(inspect(&root), ready("me/repo"));
    // `insteadOf` rewrites apply, as `git remote get-url` reports them.
    git(&root, &["remote", "set-url", "origin", "work:me/repo.git"]);
    git(
        &root,
        &["config", "url.https://gitlab.com/.insteadOf", "work:"],
    );
    assert_eq!(
        inspect(&root),
        Availability::UnsupportedHost {
            host: "GitLab".into(),
            self_hosted: false
        }
    );
}
