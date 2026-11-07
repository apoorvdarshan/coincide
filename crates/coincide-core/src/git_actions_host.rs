//! The host a repository's remote is on and its web pages (Swift GitRemoteURL and
//! SourceControlHost, from T3 Code's `source-control-*` packages). User names and
//! passwords in a remote address are dropped and never kept.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Github,
    Gitlab,
    Gitcafe,
    Forgejo,
    Bitbucket,
    AzureDevOps,
    /// A host none of the others claims. Left to `gh`, since GitHub Enterprise runs
    /// on any host name.
    Unknown,
}

/// GitLab's merge requests and everyone else's pull requests.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Term {
    #[default]
    PullRequest,
    MergeRequest,
}

impl Kind {
    pub fn change_request(self) -> Term {
        if self == Self::Gitlab {
            Term::MergeRequest
        } else {
            Term::PullRequest
        }
    }
}

impl Term {
    /// `#12` for a pull request, `!12` for a GitLab merge request.
    pub fn reference(self, number: u64) -> String {
        match self {
            Self::PullRequest => format!("#{number}"),
            Self::MergeRequest => format!("!{number}"),
        }
    }
    /// "View Pull Request #12" or "View Merge Request !12".
    pub fn view_title(self, number: u64) -> String {
        match self {
            Self::PullRequest => format!("View Pull Request #{number}"),
            Self::MergeRequest => format!("View Merge Request !{number}"),
        }
    }
    /// The follow-up button after a pull request was created or found.
    pub fn view_button_title(self) -> &'static str {
        match self {
            Self::PullRequest => "View PR",
            Self::MergeRequest => "View MR",
        }
    }
    pub fn create_menu_title(self) -> &'static str {
        match self {
            Self::PullRequest => "Create Pull Request",
            Self::MergeRequest => "Create Merge Request",
        }
    }
    /// Tooltip line for the branch: "Pull request #12: Fix the parser".
    pub fn summary(self, number: u64, title: &str) -> String {
        match self {
            Self::PullRequest => format!("Pull request #{number}: {title}"),
            Self::MergeRequest => format!("Merge request !{number}: {title}"),
        }
    }
    pub fn detached_head_note(self) -> &'static str {
        match self {
            Self::PullRequest => "Check out a branch to push or open a pull request.",
            Self::MergeRequest => "Check out a branch to push or open a merge request.",
        }
    }
    pub fn default_branch_question(self, commits: bool) -> &'static str {
        match (self, commits) {
            (Self::PullRequest, true) => {
                "Commit, push and open a pull request from the default branch?"
            }
            (Self::PullRequest, false) => "Push and open a pull request from the default branch?",
            (Self::MergeRequest, true) => {
                "Commit, push and open a merge request from the default branch?"
            }
            (Self::MergeRequest, false) => "Push and open a merge request from the default branch?",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Transport {
    Https,
    Http,
    /// `ssh://`, `git+ssh://`, or scp-like `user@host:path`.
    Ssh,
    Git,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteUrl {
    pub transport: Transport,
    /// Lower case, without a port.
    pub hostname: String,
    pub port: Option<u16>,
    /// Percent-decoded segments without a trailing `.git`.
    pub path: Vec<String>,
}

impl RemoteUrl {
    /// Keeps the port of an HTTP remote, never an SSH one's.
    pub fn host(&self) -> String {
        match (self.port, self.transport) {
            (Some(port), Transport::Https | Transport::Http) => format!("{}:{port}", self.hostname),
            _ => self.hostname.clone(),
        }
    }

    /// None for a remote that names no host, such as a local path or `file://` URL.
    pub fn parse(remote: &str) -> Option<Self> {
        let trimmed = remote.trim();
        if trimmed.is_empty() || trimmed.contains(['\n', '\r']) {
            return None;
        }
        if let Some((scheme, rest)) = trimmed.split_once("://") {
            return Self::parse_url(&scheme.to_lowercase(), rest);
        }
        Self::parse_scp(trimmed)
    }

    fn parse_url(scheme: &str, rest: &str) -> Option<Self> {
        let transport = match scheme {
            "https" => Transport::Https,
            "http" => Transport::Http,
            "ssh" | "git+ssh" | "ssh+git" => Transport::Ssh,
            "git" => Transport::Git,
            _ => return None,
        };
        let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
        let mut authority = &rest[..end];
        // Credentials end at the last `@`; a password may contain an escaped one.
        if let Some(at) = authority.rfind('@') {
            authority = &authority[at + 1..];
        }
        let (hostname, port) = split_host_and_port(authority)?;
        let mut path = &rest[end..];
        if let Some(stop) = path.find(['?', '#']) {
            path = &path[..stop];
        }
        Some(Self {
            transport,
            hostname,
            port,
            path: segments(path),
        })
    }

    /// `[user@]host:path`, which git reads as SSH when a colon comes before any slash.
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
        if !has_user && path.len() < 2 {
            return None;
        }
        Some(Self {
            transport: Transport::Ssh,
            hostname,
            port: None,
            path,
        })
    }
}

fn split_host_and_port(authority: &str) -> Option<(String, Option<u16>)> {
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
    match port.filter(|port| !port.is_empty()) {
        None => Some((hostname, None)),
        Some(port) => {
            if !port.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            let port: u16 = port.parse().ok().filter(|port| *port > 0)?;
            Some((hostname, Some(port)))
        }
    }
}

/// Host names as git accepts them, SSH aliases included, or a bracketed IPv6 address.
fn is_host_name(value: &str) -> bool {
    if let Some(inner) = value.strip_prefix('[') {
        return value.len() > 2
            && inner.ends_with(']')
            && inner[..inner.len() - 1]
                .chars()
                .all(|c| c.is_ascii_hexdigit() || c == ':' || c == '.');
    }
    !value.is_empty()
        && !value.starts_with(['-', '.'])
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = value.get(index + 1..index + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn segments(path: &str) -> Vec<String> {
    let mut parts: Vec<String> = path
        .split('/')
        .filter(|part| !part.is_empty())
        .map(|part| percent_decode(part).unwrap_or_else(|| part.to_owned()))
        .collect();
    if let Some(last) = parts.last_mut()
        && last.to_lowercase().ends_with(".git")
    {
        last.truncate(last.len() - 4);
        if last.is_empty() {
            parts.pop();
        }
    }
    parts.retain(|part| !part.is_empty());
    parts
}

const GITCAFE_HOSTS: &[&str] = &["git.cafe", "staging.git.cafe"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Host {
    pub kind: Kind,
    pub remote: RemoteUrl,
}

impl Host {
    /// The host a remote is on, or None for a remote that names no host.
    pub fn recognize_url(remote: &str) -> Option<Self> {
        RemoteUrl::parse(remote).map(Self::recognize)
    }

    /// T3 Code's recognition order: a name can carry several hosts' labels.
    pub fn recognize(remote: RemoteUrl) -> Self {
        let hostname = remote.hostname.as_str();
        let labels: Vec<&str> = hostname.split('.').collect();
        let kind = if GITCAFE_HOSTS.contains(&hostname) {
            Kind::Gitcafe
        } else if hostname == "codeberg.org"
            || labels.contains(&"forgejo")
            || labels.contains(&"gitea")
        {
            Kind::Forgejo
        } else if hostname == "github.com"
            || hostname.ends_with(".ghe.com")
            || labels.contains(&"github")
        {
            Kind::Github
        } else if hostname == "gitlab.com" || labels.contains(&"gitlab") {
            Kind::Gitlab
        } else if hostname == "dev.azure.com"
            || hostname.ends_with(".dev.azure.com")
            || hostname.ends_with(".visualstudio.com")
        {
            Kind::AzureDevOps
        } else if hostname == "bitbucket.org" || labels.contains(&"bitbucket") {
            Kind::Bitbucket
        } else {
            Kind::Unknown
        };
        Self { kind, remote }
    }

    pub fn display_name(&self) -> String {
        match self.kind {
            Kind::Github => "GitHub".into(),
            Kind::Gitlab => "GitLab".into(),
            Kind::Gitcafe => "GitCafe".into(),
            Kind::Bitbucket => "Bitbucket".into(),
            Kind::AzureDevOps => "Azure DevOps".into(),
            Kind::Forgejo if self.remote.hostname == "codeberg.org" => "Codeberg".into(),
            Kind::Forgejo
                if self
                    .remote
                    .hostname
                    .split('.')
                    .any(|label| label == "gitea") =>
            {
                "Gitea".into()
            }
            Kind::Forgejo => "Forgejo".into(),
            Kind::Unknown => self.remote.hostname.clone(),
        }
    }

    fn web_host_and_port(&self) -> Option<(String, Option<u16>)> {
        let remote = &self.remote;
        // Azure names one repository differently over SSH and on the web.
        if self.kind == Kind::AzureDevOps && remote.path.len() == 4 && remote.path[0] == "v3" {
            if remote.hostname == "ssh.dev.azure.com" {
                return Some(("dev.azure.com".into(), None));
            }
            if remote.hostname == "vs-ssh.visualstudio.com" {
                return Some((
                    format!("{}.visualstudio.com", remote.path[1].to_lowercase()),
                    None,
                ));
            }
        }
        match remote.transport {
            Transport::Https => Some((
                remote.hostname.clone(),
                remote.port.filter(|port| *port != 443),
            )),
            Transport::Http => match remote.port {
                None | Some(80) => Some((remote.hostname.clone(), None)),
                Some(_) => None,
            },
            Transport::Ssh | Transport::Git => Some((remote.hostname.clone(), None)),
        }
    }

    /// Always `https`; None when the web address can't be named.
    pub fn web_origin(&self) -> Option<String> {
        let (hostname, port) = self.web_host_and_port()?;
        if hostname.starts_with('[') || hostname.contains('_') {
            return None;
        }
        Some(match port {
            Some(port) => format!("https://{hostname}:{port}"),
            None => format!("https://{hostname}"),
        })
    }

    fn is_bitbucket_server(&self) -> bool {
        self.kind == Kind::Bitbucket
            && self.remote.hostname != "bitbucket.org"
            && !self.remote.hostname.ends_with(".bitbucket.org")
    }

    /// The repository's path on the host's web pages, or None when the remote's path is
    /// not one the host serves.
    pub fn repository_web_path(&self) -> Option<Vec<String>> {
        let path = &self.remote.path;
        if path.iter().any(|part| part == "." || part == "..") {
            return None;
        }
        match self.kind {
            Kind::Github | Kind::Gitcafe => (path.len() == 2).then(|| path.clone()),
            Kind::Gitlab | Kind::Forgejo | Kind::Unknown => (path.len() >= 2).then(|| path.clone()),
            Kind::Bitbucket => {
                if !self.is_bitbucket_server() {
                    return (path.len() == 2).then(|| path.clone());
                }
                // Data Center clones over `<context>/scm/<project>/<repo>` or `<project>/<repo>`.
                let scm = path
                    .iter()
                    .position(|part| part.eq_ignore_ascii_case("scm"));
                let (context, rest) = match scm {
                    Some(index) => (path[..index].to_vec(), path[index + 1..].to_vec()),
                    None => (Vec::new(), path.clone()),
                };
                let [project, repository] = rest.as_slice() else {
                    return None;
                };
                let mut web = context;
                if let Some(user) = project.strip_prefix('~') {
                    web.extend([
                        "users".into(),
                        user.into(),
                        "repos".into(),
                        repository.clone(),
                    ]);
                } else {
                    web.extend([
                        "projects".into(),
                        project.clone(),
                        "repos".into(),
                        repository.clone(),
                    ]);
                }
                Some(web)
            }
            Kind::AzureDevOps => {
                if path.len() == 4 && path[0] == "v3" {
                    if self.remote.hostname == "ssh.dev.azure.com" {
                        return Some(vec![
                            path[1].clone(),
                            path[2].clone(),
                            "_git".into(),
                            path[3].clone(),
                        ]);
                    }
                    if self.remote.hostname == "vs-ssh.visualstudio.com" {
                        return Some(vec![path[2].clone(), "_git".into(), path[3].clone()]);
                    }
                }
                (path.len() >= 3 && path[path.len() - 2] == "_git").then(|| path.clone())
            }
        }
    }

    pub fn repository_url(&self) -> Option<String> {
        self.web_url(&[], None, &[])
    }

    /// The host's page for opening a change request from `head` into `base`, as the
    /// host itself links to after a push. None for GitCafe and unknown hosts.
    pub fn new_change_request_url(&self, base: &str, head: &str) -> Option<String> {
        if !is_branch_name(base) || !is_branch_name(head) {
            return None;
        }
        let compare = format!("{}...{}", encode_branch(base), encode_branch(head));
        match self.kind {
            Kind::Github => self.web_url(&["compare"], Some(&compare), &[("expand", Some("1"))]),
            Kind::Forgejo => self.web_url(&["compare"], Some(&compare), &[]),
            Kind::Gitlab => self.web_url(
                &["-", "merge_requests", "new"],
                None,
                &[
                    ("merge_request[source_branch]", Some(head)),
                    ("merge_request[target_branch]", Some(base)),
                ],
            ),
            Kind::Bitbucket if self.is_bitbucket_server() => {
                let source = format!("refs/heads/{head}");
                let target = format!("refs/heads/{base}");
                self.web_url(
                    &["pull-requests"],
                    None,
                    &[
                        ("create", None),
                        ("sourceBranch", Some(&source)),
                        ("targetBranch", Some(&target)),
                    ],
                )
            }
            Kind::Bitbucket => self.web_url(
                &["pull-requests", "new"],
                None,
                &[
                    ("source", Some(head)),
                    ("dest", Some(base)),
                    ("t", Some("1")),
                ],
            ),
            Kind::AzureDevOps => self.web_url(
                &["pullrequestcreate"],
                None,
                &[("sourceRef", Some(head)), ("targetRef", Some(base))],
            ),
            Kind::Gitcafe | Kind::Unknown => None,
        }
    }

    fn web_url(
        &self,
        route: &[&str],
        raw_tail: Option<&str>,
        query: &[(&str, Option<&str>)],
    ) -> Option<String> {
        let origin = self.web_origin()?;
        let path = self.repository_web_path().filter(|path| !path.is_empty())?;
        let mut encoded: Vec<String> = path
            .iter()
            .map(String::as_str)
            .chain(route.iter().copied())
            .map(|segment| encode(segment, PATH_SEGMENT))
            .collect();
        if let Some(tail) = raw_tail {
            encoded.push(tail.into());
        }
        let mut url = format!("{origin}/{}", encoded.join("/"));
        if !query.is_empty() {
            let pairs: Vec<String> = query
                .iter()
                .map(|(name, value)| match value {
                    Some(value) => format!("{}={}", encode(name, ""), encode(value, "")),
                    None => encode(name, ""),
                })
                .collect();
            url.push('?');
            url.push_str(&pairs.join("&"));
        }
        let parsed = url::Url::parse(&url).ok()?;
        (parsed.scheme() == "https").then_some(url)
    }
}

/// Branch names as git allows them, so `..` can't step out of the repository's pages.
fn is_branch_name(name: &str) -> bool {
    !name.is_empty()
        && !name.contains("..")
        && !name.starts_with('/')
        && !name.ends_with('/')
        && !name.contains(['\n', '\r', '\\'])
}

const PATH_SEGMENT: &str = "!$&'()*+,;=:@";

fn encode(value: &str, extra: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        let c = byte as char;
        if byte.is_ascii_alphanumeric() || matches!(c, '-' | '.' | '_' | '~') || extra.contains(c) {
            out.push(c);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// A branch in a path keeps its slashes, as hosts write `compare/main...feature/x`.
fn encode_branch(value: &str) -> String {
    encode(value, "!$&'()*+,;=:@/")
}
