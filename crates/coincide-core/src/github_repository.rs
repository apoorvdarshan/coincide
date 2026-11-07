//! Which github.com repository a thread's folder lists pull requests from, and
//! why it can't when it can't (Swift `PullRequestService.availability`). Reads
//! only local Git configuration; whether `gh` is signed in is the caller's check.
//! Remote addresses are read as Swift `GitRemoteURL` and `SourceControlHost`
//! read them; user names and passwords in an address are dropped, never kept.
use serde_json::{Value, json};
use std::{collections::HashMap, path::Path};

/// Swift `PullRequestService.Availability`, decided in its order. Ready names the
/// `owner/name` that `gh` would list without `--repo`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Availability {
    Ready(String),
    NotRepository,
    /// No remote, or one that names no host (a local path).
    NoRemote,
    /// The primary remote is on another host. `self_hosted` marks a host Swift
    /// would hand to `gh` (GitHub Enterprise or a name no host claims), which the
    /// read service, pinned to github.com, can't list.
    UnsupportedHost {
        host: String,
        self_hosted: bool,
    },
    NeedsGitHubCli,
}

impl Availability {
    pub fn to_json(&self) -> Value {
        match self {
            Self::Ready(repository) => json!({"state":"ready","repository":repository}),
            Self::NotRepository => json!({"state":"notRepository"}),
            Self::NoRemote => json!({"state":"noRemote"}),
            Self::UnsupportedHost { host, self_hosted } => {
                json!({"state":"unsupportedHost","host":host,"selfHosted":self_hosted})
            }
            Self::NeedsGitHubCli => json!({"state":"needsGitHubCli"}),
        }
    }
}

/// Reads the folder's repository and remotes with local Git only. A ready result
/// still needs the caller's `gh` sign-in check.
pub(crate) fn inspect(root: &Path) -> Availability {
    // Swift treats any failure here, Git missing included, as not a repository.
    if crate::workspace::git(root, &["rev-parse", "--show-toplevel"]).is_err() {
        return Availability::NotRepository;
    }
    let remotes = crate::workspace::git(root, &["remote", "-v"])
        .map(|bytes| fetch_remotes(&String::from_utf8_lossy(&bytes)))
        .unwrap_or_default();
    // Exit status 1 means no repository default was set with `gh repo set-default`.
    let resolved = crate::workspace::git(
        root,
        &["config", "--get-regexp", r"^remote\..+\.gh-resolved$"],
    )
    .map(|bytes| resolutions(&String::from_utf8_lossy(&bytes)))
    .unwrap_or_default();
    decide(&remotes, &resolved)
}

/// `git remote -v` fetch lines as (name, address), in Git's name order.
fn fetch_remotes(output: &str) -> Vec<(String, String)> {
    output
        .lines()
        .filter_map(|line| {
            let (name, rest) = line.split_once('\t')?;
            // A partial clone appends ` [filter]` after `(fetch)`.
            let (address, _) = rest.rsplit_once(" (fetch)")?;
            (!name.is_empty() && !address.is_empty()).then(|| (name.into(), address.into()))
        })
        .take(64)
        .collect()
}

/// `remote.<name>.gh-resolved <value>` lines, as `gh repo set-default` writes them.
fn resolutions(output: &str) -> HashMap<String, String> {
    output
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once(' ')?;
            let name = key.strip_prefix("remote.")?.strip_suffix(".gh-resolved")?;
            Some((name.into(), value.trim().into()))
        })
        .collect()
}

fn decide(remotes: &[(String, String)], resolved: &HashMap<String, String>) -> Availability {
    // Swift: `origin` when it exists, otherwise the first remote.
    let Some((_, primary)) = remotes
        .iter()
        .find(|(name, _)| name == "origin")
        .or(remotes.first())
    else {
        return Availability::NoRemote;
    };
    let Some(primary) = RemoteUrl::parse(primary) else {
        return Availability::NoRemote;
    };
    let kind = Kind::recognize(&primary.hostname);
    if !matches!(kind, Kind::Github | Kind::Unknown) {
        return Availability::UnsupportedHost {
            host: kind.display_name(&primary.hostname),
            self_hosted: false,
        };
    }
    if !is_github_dot_com(&primary.hostname) {
        return Availability::UnsupportedHost {
            host: primary.hostname,
            self_hosted: true,
        };
    }
    base_repository(remotes, resolved).map_or(Availability::NoRemote, Availability::Ready)
}

/// The repository `gh pr list` reads without `--repo`: of the github.com remotes,
/// the one `gh repo set-default` chose, else `upstream`, `github`, `origin`, then
/// the rest in Git's order (gh's `remoteNameSortScore`, first remote when it
/// can't prompt).
fn base_repository(
    remotes: &[(String, String)],
    resolved: &HashMap<String, String>,
) -> Option<String> {
    let score = |name: &str| match name.to_ascii_lowercase().as_str() {
        "upstream" => 3,
        "github" => 2,
        "origin" => 1,
        _ => 0,
    };
    let mut candidates = remotes
        .iter()
        .filter_map(|(name, address)| {
            let remote = RemoteUrl::parse(address)?;
            if !is_github_dot_com(&remote.hostname) || remote.path.len() != 2 {
                return None;
            }
            let repository = remote.path.join("/");
            crate::github_api::valid_repository(&repository).then_some((name.as_str(), repository))
        })
        .collect::<Vec<_>>();
    candidates.sort_by_key(|(name, _)| std::cmp::Reverse(score(name)));
    for (name, repository) in &candidates {
        match resolved.get(*name).map(String::as_str) {
            Some("base") => return Some(repository.clone()),
            Some(other) if crate::github_api::valid_repository(other) => {
                return Some(other.to_owned());
            }
            _ => {}
        }
    }
    candidates
        .into_iter()
        .next()
        .map(|(_, repository)| repository)
}

/// gh's `NormalizeHostname`: every `*.github.com` host is github.com.
fn is_github_dot_com(hostname: &str) -> bool {
    hostname == "github.com" || hostname.ends_with(".github.com")
}

/// Swift `GitRemoteURL`, keeping what choosing a repository needs.
#[derive(Clone, Debug, PartialEq, Eq)]
struct RemoteUrl {
    /// Lower case, without a port.
    hostname: String,
    /// Percent-decoded segments without a trailing `.git`.
    path: Vec<String>,
}

impl RemoteUrl {
    /// None for a remote that names no host, such as a local path or `file://`.
    fn parse(remote: &str) -> Option<Self> {
        let trimmed = remote.trim();
        if trimmed.is_empty() || trimmed.contains(['\n', '\r']) {
            return None;
        }
        match trimmed.split_once("://") {
            Some((scheme, rest)) => Self::parse_url(&scheme.to_ascii_lowercase(), rest),
            None => Self::parse_scp(trimmed),
        }
    }

    fn parse_url(scheme: &str, rest: &str) -> Option<Self> {
        if !matches!(
            scheme,
            "https" | "http" | "ssh" | "git+ssh" | "ssh+git" | "git"
        ) {
            return None;
        }
        let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
        let mut authority = &rest[..authority_end];
        // Credentials end at the last `@`; a password may contain an escaped one.
        if let Some(at) = authority.rfind('@') {
            authority = &authority[at + 1..];
        }
        let hostname = host_without_port(authority)?;
        let mut path = &rest[authority_end..];
        if let Some(end) = path.find(['?', '#']) {
            path = &path[..end];
        }
        Some(Self {
            hostname,
            path: segments(path),
        })
    }

    /// `[user@]host:path`, which Git reads as SSH when a colon comes before any slash.
    fn parse_scp(value: &str) -> Option<Self> {
        let colon = value.find(':')?;
        let prefix = &value[..colon];
        if prefix.is_empty() || prefix.contains(['/', '\\']) {
            return None;
        }
        let (host, has_user) = match prefix.rfind('@') {
            Some(at) => (&prefix[at + 1..], true),
            None => (prefix, false),
        };
        // A userless one-letter prefix is a Windows drive, not a host.
        if !has_user && host.chars().count() == 1 {
            return None;
        }
        let hostname = host.to_lowercase();
        if !is_host_name(&hostname) {
            return None;
        }
        let path = segments(&value[colon + 1..]);
        // Without a user, `name:path` is only a remote when it names `owner/repository`.
        if !has_user && path.len() < 2 {
            return None;
        }
        Some(Self { hostname, path })
    }
}

/// The host of `host[:port]` or `[ipv6][:port]`; None for a malformed one.
fn host_without_port(authority: &str) -> Option<String> {
    let (host, port) = if authority.starts_with('[') {
        let close = authority.find(']')?;
        let after = &authority[close + 1..];
        let port = match after.strip_prefix(':') {
            Some(port) => Some(port),
            None if after.is_empty() => None,
            None => return None,
        };
        (&authority[..=close], port)
    } else if let Some(colon) = authority.rfind(':') {
        (&authority[..colon], Some(&authority[colon + 1..]))
    } else {
        (authority, None)
    };
    let hostname = host.to_lowercase();
    if !is_host_name(&hostname) {
        return None;
    }
    match port {
        None | Some("") => Some(hostname),
        Some(port) if port.bytes().all(|b| b.is_ascii_digit()) => {
            port.parse::<u16>().ok().filter(|port| *port > 0)?;
            Some(hostname)
        }
        Some(_) => None,
    }
}

/// Host names as Git accepts them, SSH aliases included, or a bracketed IPv6 address.
fn is_host_name(value: &str) -> bool {
    if let Some(inner) = value.strip_prefix('[') {
        return value.len() > 2
            && inner.strip_suffix(']').is_some_and(|address| {
                address
                    .chars()
                    .all(|c| c.is_ascii_hexdigit() || c == ':' || c == '.')
            });
    }
    !value.is_empty()
        && !value.starts_with(['-', '.'])
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

fn segments(path: &str) -> Vec<String> {
    let mut parts = path
        .split('/')
        .filter(|part| !part.is_empty())
        .map(|part| percent_decode(part).unwrap_or_else(|| part.to_owned()))
        .collect::<Vec<_>>();
    if let Some(last) = parts.last_mut()
        && last.to_ascii_lowercase().ends_with(".git")
    {
        last.truncate(last.len() - 4);
    }
    parts.retain(|part| !part.is_empty());
    parts
}

/// Swift `removingPercentEncoding`: None for a malformed escape or invalid UTF-8.
fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = std::str::from_utf8(bytes.get(index + 1..index + 3)?).ok()?;
            decoded.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

/// Swift `SourceControlKind`, recognized in T3 Code's order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Github,
    Gitlab,
    Gitcafe,
    Forgejo,
    Bitbucket,
    AzureDevOps,
    Unknown,
}

impl Kind {
    fn recognize(hostname: &str) -> Self {
        let labels = hostname.split('.').collect::<Vec<_>>();
        let has = |label: &str| labels.contains(&label);
        if matches!(hostname, "git.cafe" | "staging.git.cafe") {
            Self::Gitcafe
        } else if hostname == "codeberg.org" || has("forgejo") || has("gitea") {
            Self::Forgejo
        } else if hostname == "github.com" || hostname.ends_with(".ghe.com") || has("github") {
            // `*.ghe.com` is GitHub Enterprise Cloud with data residency.
            Self::Github
        } else if hostname == "gitlab.com" || has("gitlab") {
            Self::Gitlab
        } else if hostname == "dev.azure.com"
            || hostname.ends_with(".dev.azure.com")
            || hostname.ends_with(".visualstudio.com")
        {
            Self::AzureDevOps
        } else if hostname == "bitbucket.org" || has("bitbucket") {
            Self::Bitbucket
        } else {
            Self::Unknown
        }
    }

    /// Swift `SourceControlHost.displayName`.
    fn display_name(self, hostname: &str) -> String {
        match self {
            Self::Github => "GitHub",
            Self::Gitlab => "GitLab",
            Self::Gitcafe => "GitCafe",
            Self::Bitbucket => "Bitbucket",
            Self::AzureDevOps => "Azure DevOps",
            Self::Forgejo if hostname == "codeberg.org" => "Codeberg",
            Self::Forgejo if hostname.split('.').any(|label| label == "gitea") => "Gitea",
            Self::Forgejo => "Forgejo",
            Self::Unknown => hostname,
        }
        .into()
    }
}

#[cfg(test)]
#[path = "github_repository_tests.rs"]
mod tests;
