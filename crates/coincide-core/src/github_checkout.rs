//! Native-only GitHub PR checkout (Swift PullRequestService.prepareWorktree).
//! No dispatcher route or serialized authority. A worktree that already has the
//! PR's branch is reused as it is, unless a checkout never finished it; the
//! project folder having it is an error. Otherwise the PR head is fetched the
//! way `gh pr checkout` does (the head repository's remote, else the base
//! repository's `refs/pull/<n>/head`) and a new linked worktree is created on
//! the branch. Neither the project folder nor a reused worktree is ever
//! switched, reset or cleaned, so their changes stay.
use crate::{
    agent::{OwnedChild, native_instruction_git::StoreSource},
    workspace::{external_git_directory, external_git_path},
};
use anyhow::{Context, Result, bail, ensure};
use serde_json::Value;
use std::{
    ffi::{OsStr, OsString},
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Mutex, PoisonError,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
#[cfg(test)]
#[path = "github_checkout_tests.rs"]
mod tests;

const OUTPUT: usize = 3 * 1024 * 1024;
const QUICK: Duration = Duration::from_secs(30);
// Swift gives `worktree add` and `worktree remove` 300 s, `gh pr checkout` 600 s.
const CREATE: Duration = Duration::from_secs(300);
const NETWORK: Duration = Duration::from_secs(600);
const FIELDS: &str = "number,url,state,headRefOid,headRefName,baseRefName,isCrossRepository,headRepository,headRepositoryOwner,maintainerCanModify";
/// Swift's branch prefix default (AppSettings.worktreeBranchPrefix).
pub(crate) const DEFAULT_PREFIX: &str = "coincide/";
pub const NOT_REPOSITORY: &str = "This folder is not a Git repository.";
pub const SETUP: &str =
    "Install the GitHub CLI (gh) and run “gh auth login” to see this repository’s pull requests.";
const INDEX_LOCKED: &str =
    "Git's index is locked. Wait for other Git operations to finish, then try again.";
/// The lock `worktree add` keeps until the checkout is finished. A worktree
/// still carrying it was never handed to a thread (the app quit or Git was
/// killed partway), so the next checkout of its branch replaces it.
const UNFINISHED: &str = "Coincide is still checking out this pull request";

/// Native Engine capture: the conversation's project and repository root, the
/// GitHub CLI captured by read-service configuration and the branch prefix.
pub struct Source {
    pub(crate) store: StoreSource,
    pub(crate) project_id: String,
    pub(crate) project_path: Value,
    pub(crate) root: PathBuf,
    pub(crate) storage: PathBuf,
    pub(crate) repository: String,
    pub(crate) number: u64,
    pub(crate) head: String,
    pub(crate) gh: PathBuf,
    pub(crate) prefix: String,
    pub(crate) _activity: Option<Box<dyn std::any::Any + Send>>,
}
impl Source {
    pub fn number(&self) -> u64 {
        self.number
    }
}
/// The worktree a new thread opens in. `reused` matches Swift's banner case.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Checkout {
    pub path: PathBuf,
    pub branch: String,
    pub reused: bool,
    pub number: u64,
}
/// Swift GitError: a message and, when Git explained itself, its last lines.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    pub message: String,
    pub detail: Option<String>,
}
impl Failure {
    fn new(message: impl Into<String>, detail: Option<String>) -> Self {
        Self {
            message: message.into(),
            detail: detail.filter(|text| !text.is_empty()),
        }
    }
    fn checkout(number: u64, detail: impl Into<String>) -> Self {
        Self::new(
            format!("Could not check out pull request #{number}."),
            Some(detail.into()),
        )
    }
    fn changed(number: u64) -> Self {
        Self::new(
            format!("Pull request #{number} has new commits since it was loaded."),
            Some("Refresh the pull request, then check it out again.".into()),
        )
    }
    fn create(detail: String) -> Self {
        Self::new("Could not create the worktree.", Some(detail))
    }
}
impl std::fmt::Display for Failure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.detail {
            Some(detail) => write!(formatter, "{}\n{detail}", self.message),
            None => formatter.write_str(&self.message),
        }
    }
}
impl std::error::Error for Failure {}

pub(crate) fn validate_repository(repo: &str) -> Result<()> {
    let parts: Vec<_> = repo.split('/').collect();
    ensure!(
        parts.len() == 2
            && parts.iter().all(|p| !p.is_empty()
                && p.len() <= 100
                && p.as_bytes()[0].is_ascii_alphanumeric()
                && p.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b)))
            && !parts.contains(&".."),
        "Expected explicit GitHub owner/repository"
    );
    Ok(())
}
pub(crate) fn validate_head(head: &str) -> Result<()> {
    ensure!(
        head.len() == 40 && head.bytes().all(|b| b.is_ascii_hexdigit()),
        "Expected full GitHub PR commit identity"
    );
    Ok(())
}

/// Swift BranchNames.sanitizeFragment: lowercase, hyphenated and ref-safe, at
/// most 64 characters.
pub fn sanitize_fragment(raw: &str) -> String {
    let lowered = raw.trim().to_lowercase();
    let mut value = String::new();
    let mut replaced = false;
    for character in lowered.chars().filter(|c| !matches!(c, '\'' | '"' | '`')) {
        if character.is_ascii_lowercase()
            || character.is_ascii_digit()
            || matches!(character, '/' | '_' | '-')
        {
            value.push(character);
            replaced = false;
        } else if !replaced {
            value.push('-');
            replaced = true;
        }
    }
    let mut collapsed = String::new();
    for character in value.chars() {
        if matches!(character, '/' | '-') && collapsed.ends_with(character) {
            continue;
        }
        collapsed.push(character);
    }
    let edge = |c: char| matches!(c, '.' | '/' | '_' | '-');
    let trimmed = collapsed.trim_matches(edge);
    let limited = trimmed
        .chars()
        .take(64)
        .collect::<String>()
        .trim_end_matches(edge)
        .to_owned();
    if limited.is_empty() {
        "update".into()
    } else {
        limited
    }
}
/// Swift PullRequestCheckout.localBranch: the PR's own head branch when it
/// lives in this repository, `<prefix>pr-<number>/<head>` for one from a fork,
/// whose branch name could be anything, such as `main`.
pub fn local_branch(cross_repository: bool, number: u64, head: &str, prefix: &str) -> String {
    if !cross_repository {
        return head.to_owned();
    }
    format!("{prefix}pr-{number}/{}", sanitize_fragment(head))
}

struct Metadata {
    open: bool,
    head: String,
    head_branch: String,
    base_branch: String,
    cross: bool,
    head_repository: Option<(String, String)>,
    maintainer_can_modify: bool,
}
fn branch_text(value: &Value, key: &str) -> Result<String> {
    let text = value[key]
        .as_str()
        .context("Incomplete pull request metadata")?;
    ensure!(
        !text.is_empty() && text.len() <= 255 && !text.chars().any(char::is_control),
        "Invalid pull request branch"
    );
    Ok(text.into())
}
fn metadata(bytes: &[u8], repository: &str, number: u64) -> Result<Metadata> {
    ensure!(bytes.len() <= OUTPUT, "GitHub output exceeds 3 MiB");
    let value: Value = serde_json::from_slice(bytes).context("Invalid GitHub JSON")?;
    ensure!(
        value["number"].as_u64() == Some(number),
        "GitHub returned another pull request"
    );
    let expected = format!("https://github.com/{repository}/pull/{number}");
    ensure!(
        value["url"]
            .as_str()
            .is_some_and(|url| url.eq_ignore_ascii_case(&expected)),
        "Pull request URL does not match repository/number"
    );
    let head = value["headRefOid"]
        .as_str()
        .context("Incomplete pull request metadata")?
        .to_ascii_lowercase();
    validate_head(&head)?;
    let owner = value["headRepositoryOwner"]["login"].as_str();
    let name = value["headRepository"]["name"].as_str();
    let head_repository = match (owner, name) {
        (Some(owner), Some(name)) => {
            validate_repository(&format!("{owner}/{name}"))?;
            Some((owner.to_owned(), name.to_owned()))
        }
        // A deleted fork leaves only the base repository's pull ref.
        _ => None,
    };
    Ok(Metadata {
        open: value["state"] == "OPEN",
        head,
        head_branch: branch_text(&value, "headRefName")?,
        base_branch: branch_text(&value, "baseRefName")?,
        cross: value["isCrossRepository"]
            .as_bool()
            .context("Incomplete pull request metadata")?,
        head_repository,
        maintainer_can_modify: value["maintainerCanModify"] == true,
    })
}

/// A configured remote's GitHub repository, parsed the way gh matches remotes.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Remote {
    name: String,
    owner: String,
    repository: String,
}
fn github_repository(url: &str) -> Option<(String, String)> {
    let url = url.trim();
    let path = if url.contains("://") {
        let parsed = url::Url::parse(url).ok()?;
        if !matches!(parsed.scheme(), "https" | "http" | "ssh" | "git") {
            return None;
        }
        let host = parsed.host_str()?.to_ascii_lowercase();
        if host != "github.com" && host != "www.github.com" {
            return None;
        }
        parsed.path().to_owned()
    } else {
        // scp-like `[user@]github.com:owner/name.git`.
        let (host, path) = url.split_once(':')?;
        let host = host.rsplit('@').next()?.to_ascii_lowercase();
        if host != "github.com" {
            return None;
        }
        path.to_owned()
    };
    let path = path.trim_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let (owner, name) = path.split_once('/')?;
    validate_repository(&format!("{owner}/{name}")).ok()?;
    Some((owner.to_owned(), name.to_owned()))
}
fn remote_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && !name.starts_with('-')
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}
/// gh's remote order: upstream, github, origin, then the rest as configured.
fn parse_remotes(bytes: &[u8]) -> Vec<Remote> {
    let mut remotes = Vec::new();
    for record in bytes.split(|b| *b == 0).filter(|r| !r.is_empty()) {
        let Ok(record) = std::str::from_utf8(record) else {
            continue;
        };
        let Some((key, url)) = record.split_once('\n') else {
            continue;
        };
        let Some(name) = key
            .strip_prefix("remote.")
            .and_then(|key| key.strip_suffix(".url"))
        else {
            continue;
        };
        if !remote_name(name) || remotes.iter().any(|r: &Remote| r.name == name) {
            continue;
        }
        if let Some((owner, repository)) = github_repository(url) {
            remotes.push(Remote {
                name: name.into(),
                owner,
                repository,
            });
        }
    }
    let score = |name: &str| match name.to_ascii_lowercase().as_str() {
        "upstream" => 3,
        "github" => 2,
        "origin" => 1,
        _ => 0,
    };
    remotes.sort_by_key(|remote| std::cmp::Reverse(score(&remote.name)));
    remotes
}
fn find_remote<'a>(remotes: &'a [Remote], owner: &str, repository: &str) -> Option<&'a Remote> {
    remotes.iter().find(|remote| {
        remote.owner.eq_ignore_ascii_case(owner)
            && remote.repository.eq_ignore_ascii_case(repository)
    })
}
/// gh's ghrepo.FormatRemoteURL for its configured git_protocol.
fn remote_url(owner: &str, repository: &str, ssh: bool) -> String {
    if ssh {
        format!("git@github.com:{owner}/{repository}.git")
    } else {
        format!("https://github.com/{owner}/{repository}.git")
    }
}

#[derive(Debug)]
struct Worktree {
    path: PathBuf,
    head: Option<String>,
    branch: Option<String>,
    locked: Option<String>,
    main: bool,
}
fn parse_worktrees(bytes: &[u8]) -> Result<Vec<Worktree>> {
    let mut worktrees: Vec<Worktree> = Vec::new();
    for field in bytes.split(|b| *b == 0).filter(|f| !f.is_empty()) {
        let field = std::str::from_utf8(field).context("Worktree path is not UTF-8")?;
        if let Some(path) = field.strip_prefix("worktree ") {
            let main = worktrees.is_empty();
            worktrees.push(Worktree {
                path: PathBuf::from(path),
                head: None,
                branch: None,
                locked: None,
                main,
            });
        } else if let Some(current) = worktrees.last_mut() {
            if let Some(head) = field.strip_prefix("HEAD ") {
                current.head = Some(head.to_owned());
            } else if let Some(branch) = field.strip_prefix("branch ") {
                current.branch = Some(branch.strip_prefix("refs/heads/").unwrap_or(branch).into());
            } else if field == "locked" {
                current.locked = Some(String::new());
            } else if let Some(reason) = field.strip_prefix("locked ") {
                current.locked = Some(reason.to_owned());
            }
        }
    }
    Ok(worktrees)
}

/// Checkouts running in this process, by repository and branch. A second one
/// of the same branch is refused, so it never replaces a worktree the first is
/// still making.
static CLAIMS: Mutex<Vec<(PathBuf, String)>> = Mutex::new(Vec::new());
struct Claim((PathBuf, String));
impl Claim {
    fn take(repository: &Path, branch: &str) -> Option<Self> {
        let key = (repository.to_owned(), branch.to_owned());
        let mut claims = CLAIMS.lock().unwrap_or_else(PoisonError::into_inner);
        if claims.contains(&key) {
            return None;
        }
        claims.push(key.clone());
        Some(Self(key))
    }
}
impl Drop for Claim {
    fn drop(&mut self) {
        let mut claims = CLAIMS.lock().unwrap_or_else(PoisonError::into_inner);
        claims.retain(|claim| claim != &self.0);
    }
}

/// Swift GitCLI.failed: Git's own diagnostic lines, without hints, and with
/// any URL credentials removed before they reach the UI.
fn failure_detail(output: &Output) -> String {
    let text = String::from_utf8_lossy(if output.stderr.is_empty() {
        &output.stdout
    } else {
        &output.stderr
    });
    if text.contains("unable to create '") && text.contains("index.lock': File exists") {
        return INDEX_LOCKED.into();
    }
    let lines = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with("hint:"))
        .map(redact)
        .collect::<Vec<_>>();
    let detail = lines[lines.len().saturating_sub(12)..].join("\n");
    if detail.is_empty() {
        format!("Exit status {}.", output.code)
    } else {
        detail
    }
}
fn redact(line: &str) -> String {
    let mut result = String::new();
    let mut rest = line;
    while let Some(index) = rest.find("://") {
        let (before, after) = rest.split_at(index + 3);
        result.push_str(before);
        let end = after
            .find(|c: char| c == '/' || c.is_whitespace())
            .unwrap_or(after.len());
        rest = match after[..end].rfind('@') {
            Some(at) => &after[at + 1..],
            None => after,
        };
    }
    result.push_str(rest);
    result
}

struct Output {
    code: i32,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}
impl Output {
    fn success(&self) -> bool {
        self.code == 0
    }
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).trim().to_owned()
    }
}
static NEVER: AtomicBool = AtomicBool::new(false);
/// Fixed hardening shared with workspace::git: no inherited GIT_* redirection,
/// no hooks (a regular file is never a hook directory), no fsmonitor, and only
/// HTTPS and SSH transports unless the user's own config allows another.
struct Git<'a> {
    cancelled: &'a AtomicBool,
    hooks: OsString,
    credentials: Vec<OsString>,
}
impl<'a> Git<'a> {
    fn new(cancelled: &'a AtomicBool, gh: &Path) -> Result<Self> {
        let mut hooks = OsString::from("core.hooksPath=");
        hooks.push(external_git_path(&std::env::current_exe()?)?);
        let gh = external_git_path(gh)?;
        let gh = gh.to_str().context("Native GH path is not UTF-8")?;
        // gh's AuthenticatedCommand: fetches answer credentials from gh only.
        let credentials = vec![
            "-c".into(),
            "credential.helper=".into(),
            "-c".into(),
            format!(
                "credential.helper=!'{}' auth git-credential",
                gh.replace('\'', "'\\''")
            )
            .into(),
        ];
        Ok(Self {
            cancelled,
            hooks,
            credentials,
        })
    }
    /// Cleanup after cancellation or a timeout must still run, briefly.
    fn uncancellable(&self) -> Git<'static> {
        Git {
            cancelled: &NEVER,
            hooks: self.hooks.clone(),
            credentials: self.credentials.clone(),
        }
    }
    fn run(&self, directory: &Path, args: &[&str], timeout: Duration) -> Result<Output> {
        let args = args.iter().map(OsStr::new).collect::<Vec<_>>();
        self.execute(directory, &[], &args, timeout)
    }
    fn fetch(&self, directory: &Path, args: &[&str]) -> Result<Output> {
        let args = args.iter().map(OsStr::new).collect::<Vec<_>>();
        self.execute(directory, &self.credentials, &args, NETWORK)
    }
    fn execute(
        &self,
        directory: &Path,
        options: &[OsString],
        args: &[&OsStr],
        timeout: Duration,
    ) -> Result<Output> {
        ensure!(
            !self.cancelled.load(Ordering::Acquire),
            "Checkout cancelled"
        );
        ensure!(directory.is_dir(), "Repository directory does not exist");
        let mut command = Command::new("git");
        for (name, _) in std::env::vars_os() {
            if name.to_string_lossy().starts_with("GIT_") {
                command.env_remove(name);
            }
        }
        #[cfg(windows)]
        command.args(["-c", "core.longpaths=true"]);
        command
            .arg("-c")
            .arg(&self.hooks)
            .args([
                "--no-pager",
                "--literal-pathspecs",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "protocol.allow=never",
                "-c",
                "protocol.https.allow=always",
                "-c",
                "protocol.ssh.allow=always",
            ])
            .args(options)
            .arg("-C")
            .arg(external_git_directory(directory)?)
            .args(args)
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_MERGE_AUTOEDIT", "no")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = OwnedChild::spawn(&mut command).context("Unable to start git")?;
        let (stdout, stderr) = child.pipes();
        let stdout = drain(stdout.context("Missing git stdout")?)?;
        let stderr = drain(stderr.context("Missing git stderr")?)?;
        let deadline = Instant::now() + timeout;
        let outcome = loop {
            if self.cancelled.load(Ordering::Acquire) {
                break Err(anyhow::anyhow!("Checkout cancelled"));
            }
            if Instant::now() >= deadline {
                break Err(anyhow::anyhow!("Git operation timed out"));
            }
            match child.exit_code() {
                Ok(Some(code)) => break Ok(code),
                Ok(None) => thread::sleep(Duration::from_millis(20)),
                Err(error) => break Err(error),
            }
        };
        // Kill and reap the whole owned group/Job before joining its pipes.
        drop(child);
        let stdout = join(stdout)?;
        let stderr = join(stderr)?;
        Ok(Output {
            code: outcome?,
            stdout,
            stderr,
        })
    }
    fn checked(
        &self,
        directory: &Path,
        args: &[&str],
        failure: impl FnOnce(String) -> Failure,
    ) -> Result<String> {
        let output = self.run(directory, args, QUICK)?;
        if !output.success() {
            return Err(failure(failure_detail(&output)).into());
        }
        Ok(output.text())
    }
    fn commit(&self, directory: &Path, reference: &str) -> Result<Option<String>> {
        let spec = format!("{reference}^{{commit}}");
        let output = self.run(
            directory,
            &["rev-parse", "--verify", "--quiet", &spec],
            QUICK,
        )?;
        if !output.success() {
            return Ok(None);
        }
        let oid = output.text().to_ascii_lowercase();
        crate::workspace_git::validate_oid(&oid)?;
        Ok(Some(oid))
    }
    fn reference_name(&self, directory: &Path, reference: &str) -> Result<bool> {
        Ok(self
            .run(directory, &["check-ref-format", reference], QUICK)?
            .success())
    }
    fn ancestor(&self, directory: &Path, ancestor: &str, descendant: &str) -> Result<bool> {
        let output = self.run(
            directory,
            &["merge-base", "--is-ancestor", ancestor, descendant],
            QUICK,
        )?;
        match output.code {
            0 => Ok(true),
            1 => Ok(false),
            _ => bail!("{}", failure_detail(&output)),
        }
    }
    /// None when the key is unset (git config exits 1).
    fn config(&self, directory: &Path, key: &str) -> Result<Option<String>> {
        let output = self.run(directory, &["config", "--get", key], QUICK)?;
        match output.code {
            0 => Ok(Some(output.text())),
            1 => Ok(None),
            _ => bail!("{}", failure_detail(&output)),
        }
    }
}
fn drain<R: Read + Send + 'static>(mut pipe: R) -> Result<thread::JoinHandle<Vec<u8>>> {
    thread::Builder::new()
        .name("coincide-checkout-git-output".into())
        .spawn(move || {
            let mut kept = Vec::new();
            let mut chunk = [0u8; 16384];
            loop {
                match pipe.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(n) => {
                        // Keep draining past the bound so Git never blocks on a full pipe.
                        let room = OUTPUT.saturating_sub(kept.len());
                        kept.extend_from_slice(&chunk[..n.min(room)]);
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(_) => break,
                }
            }
            kept
        })
        .context("Unable to read git output")
}
fn join(reader: thread::JoinHandle<Vec<u8>>) -> Result<Vec<u8>> {
    reader
        .join()
        .map_err(|_| anyhow::anyhow!("Git output reader panicked"))
}

/// Mirrors Swift's prepareWorktreesRoot (owner-only) beside Rust's reserved
/// worktrees, refusing a symbolic link in place of either folder.
fn private_folder(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            ensure!(
                metadata.is_dir() && !metadata.file_type().is_symlink(),
                "Worktree storage must be a real directory"
            );
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                // Best effort, like Swift: an odd volume must not block checkout.
                let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o700));
            }
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            #[cfg(unix)]
            let builder = {
                use std::os::unix::fs::DirBuilderExt;
                let mut builder = fs::DirBuilder::new();
                builder.mode(0o700);
                builder
            };
            #[cfg(not(unix))]
            let builder = fs::DirBuilder::new();
            builder.create(path)?;
            Ok(())
        }
        Err(error) => Err(error.into()),
    }
}
/// A folder name that is valid on every desktop platform.
fn portable(name: &str) -> String {
    let mut value = name
        .chars()
        .map(|c| {
            if c.is_control() || "<>:\"|?*\\/".contains(c) {
                '-'
            } else {
                c
            }
        })
        .collect::<String>()
        .trim_end_matches(['.', ' '])
        .to_owned();
    if value.is_empty() || value == "." || value == ".." {
        value = "worktree".into();
    }
    let stem = value.split('.').next().unwrap_or("").to_ascii_uppercase();
    let reserved = matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (stem.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && stem.as_bytes()[3].is_ascii_digit());
    if reserved {
        value.insert(0, '_');
    }
    value.chars().take(120).collect()
}
/// Swift GitService.newWorktreePath: `<worktrees>/<repository>/<branch with
/// slashes as hyphens>`, with `-2`, `-3`… when that folder is taken.
fn destination(storage: &Path, repository: &str, branch: &str) -> Result<PathBuf> {
    let worktrees = storage.join("worktrees");
    private_folder(&worktrees)?;
    let folder = worktrees.join(portable(repository));
    private_folder(&folder)?;
    let name = portable(&branch.replace('/', "-"));
    let mut candidate = folder.join(&name);
    let mut suffix = 2;
    while fs::symlink_metadata(&candidate).is_ok() {
        ensure!(suffix < 10_000, "No free worktree folder");
        candidate = folder.join(format!("{name}-{suffix}"));
        suffix += 1;
    }
    Ok(candidate)
}

/// Runs off the UI/Engine lock with the user's own gh credentials. The fresh
/// metadata read rebinds the displayed head before anything is fetched.
pub fn run(source: &Source, cancelled: &AtomicBool) -> Result<Checkout> {
    let runner = crate::github_api::GhRunner::new(source.gh.clone())
        .map_err(|_| Failure::new(SETUP, None))?;
    let root = source.root.clone();
    check_out(
        source,
        &mut |args: &[String]| runner.capture(&root, args, cancelled),
        cancelled,
    )
}
/// gh is injected so tests use local bare repositories without network.
pub(crate) fn check_out(
    source: &Source,
    gh: &mut dyn FnMut(&[String]) -> Result<Vec<u8>>,
    cancelled: &AtomicBool,
) -> Result<Checkout> {
    let number = source.number;
    let result = Git::new(cancelled, &source.gh).and_then(|git| prepare(source, &git, gh));
    result.map_err(|error| match error.downcast::<Failure>() {
        Ok(failure) => failure.into(),
        Err(error) => Failure::checkout(number, error.to_string()).into(),
    })
}
fn prepare(
    source: &Source,
    git: &Git<'_>,
    gh: &mut dyn FnMut(&[String]) -> Result<Vec<u8>>,
) -> Result<Checkout> {
    let number = source.number;
    let top = git.run(&source.root, &["rev-parse", "--show-toplevel"], QUICK)?;
    if !top.success() || top.text().is_empty() {
        return Err(Failure::new(NOT_REPOSITORY, None).into());
    }
    let root = PathBuf::from(top.text()).canonicalize()?;
    let listed = git.checked(
        &root,
        &["worktree", "list", "--porcelain", "-z"],
        |detail| Failure::new("Could not list worktrees.", Some(detail)),
    )?;
    let worktrees = parse_worktrees(listed.as_bytes())?;
    let main = worktrees.first().context("Git reported no worktrees")?;
    let arguments = [
        "pr".to_owned(),
        "view".to_owned(),
        number.to_string(),
        "--json".to_owned(),
        FIELDS.to_owned(),
        "--repo".to_owned(),
        format!("github.com/{}", source.repository),
    ];
    let pr = gh(&arguments)
        .and_then(|bytes| metadata(&bytes, &source.repository, number))
        .map_err(|error| Failure::checkout(number, error.to_string()))?;
    if !pr.open {
        return Err(Failure::new(
            format!("Pull request #{number} is no longer open."),
            Some("Refresh the pull request list.".into()),
        )
        .into());
    }
    let branch = local_branch(pr.cross, number, &pr.head_branch, &source.prefix);
    let _claim = Claim::take(&main.path, &branch).ok_or_else(|| {
        Failure::new(
            format!("Pull request #{number} is already being checked out."),
            Some("Wait for it to finish, then try again.".into()),
        )
    })?;
    if let Some(existing) = worktrees
        .iter()
        .find(|worktree| worktree.branch.as_deref() == Some(branch.as_str()))
    {
        // git checks a branch out in one place only.
        if existing.main {
            return Err(Failure::new(
                format!("Pull request #{number}’s branch is checked out in the project folder."),
                Some("Switch the project folder to another branch, or start a thread in the project folder instead.".into()),
            )
            .into());
        }
        match existing.locked.as_deref() {
            // A checkout that never finished: nothing in it was handed out.
            Some(UNFINISHED) => {
                let args = ["remove", "--force", "--force"];
                let removed = worktree(git, &root, &args, existing.path.as_os_str(), CREATE)?;
                if !removed.success() {
                    return Err(Failure::checkout(number, failure_detail(&removed)).into());
                }
            }
            // Git's own lock while a `worktree add` outside Coincide runs.
            Some("initializing") => {
                return Err(Failure::new(
                    format!(
                        "Pull request #{number}’s branch is in a worktree Git is still creating."
                    ),
                    Some(format!(
                        "Wait for Git to finish, or remove the worktree at {}, then try again.",
                        existing.path.display()
                    )),
                )
                .into());
            }
            _ => {
                let path = existing.path.canonicalize().map_err(|_| {
                    Failure::new(
                        format!("Pull request #{number}’s branch is checked out in a worktree that no longer exists."),
                        Some(format!("Remove or prune the worktree at {}, then try again.", existing.path.display())),
                    )
                })?;
                return Ok(Checkout {
                    path,
                    branch,
                    reused: true,
                    number,
                });
            }
        }
    }
    if pr.head != source.head {
        return Err(Failure::changed(number).into());
    }
    for reference in [
        format!("refs/heads/{branch}"),
        format!("refs/heads/{}", pr.head_branch),
    ] {
        if !git.reference_name(&root, &reference)? {
            let name = reference.trim_start_matches("refs/heads/");
            return Err(
                Failure::checkout(number, format!("“{name}” is not a valid branch name.")).into(),
            );
        }
    }
    let remotes = git.run(
        &root,
        &["config", "-z", "--get-regexp", r"^remote\..+\.url$"],
        QUICK,
    )?;
    let remotes = parse_remotes(&remotes.stdout);
    let (owner, name) = source
        .repository
        .split_once('/')
        .context("Expected explicit GitHub owner/repository")?;
    let base = find_remote(&remotes, owner, name);
    let head_remote = if pr.cross {
        pr.head_repository
            .as_ref()
            .and_then(|(owner, name)| find_remote(&remotes, owner, name))
    } else {
        base
    };
    let repository_name = main
        .path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "repository".into());
    let mut protocol = Protocol(None);
    // gh pr checkout: the head repository's remote when one is configured,
    // otherwise the base repository's pull ref (its remote, else its URL).
    let (fetch_source, spec, fetched_ref, temporary) = match head_remote {
        Some(remote) => {
            let tracking = format!("refs/remotes/{}/{}", remote.name, pr.head_branch);
            if !git.reference_name(&root, &tracking)? {
                return Err(Failure::checkout(number, "Invalid remote-tracking branch.").into());
            }
            let spec = format!("+refs/heads/{}:{tracking}", pr.head_branch);
            (remote.name.clone(), spec, tracking, None)
        }
        None => {
            let url = match base {
                Some(remote) => remote.name.clone(),
                None => remote_url(owner, name, protocol.ssh(gh)),
            };
            let temporary = format!("refs/coincide/pr-checkout/{}", uuid::Uuid::new_v4());
            let spec = format!("+refs/pull/{number}/head:{temporary}");
            (url, spec, temporary.clone(), Some(temporary))
        }
    };
    let target = Target {
        git,
        root: &root,
        storage: &source.storage,
        repository_name: &repository_name,
        branch: &branch,
        number,
        expected: &source.head,
        pr: &pr,
        tracking: head_remote.is_some(),
        fetch_source: &fetch_source,
        fetched_ref: &fetched_ref,
        main_head: main.head.as_deref(),
    };
    let result = fetch(git, &root, &fetch_source, &spec, number)
        .and_then(|()| target.create(gh, &mut protocol));
    if let Some(temporary) = temporary {
        let _ = git
            .uncancellable()
            .run(&root, &["update-ref", "-d", &temporary], QUICK);
    }
    result
}
/// gh's configured git_protocol, read only when a URL has to be written.
struct Protocol(Option<bool>);
impl Protocol {
    fn ssh(&mut self, gh: &mut dyn FnMut(&[String]) -> Result<Vec<u8>>) -> bool {
        *self.0.get_or_insert_with(|| {
            let arguments =
                ["config", "get", "git_protocol", "--host", "github.com"].map(str::to_owned);
            gh(&arguments).is_ok_and(|bytes| String::from_utf8_lossy(&bytes).trim() == "ssh")
        })
    }
}
fn fetch(git: &Git<'_>, root: &Path, source: &str, spec: &str, number: u64) -> Result<()> {
    let output = git.fetch(
        root,
        &[
            "fetch",
            "--no-write-fetch-head",
            "--no-recurse-submodules",
            "--",
            source,
            spec,
        ],
    )?;
    if !output.success() {
        return Err(Failure::checkout(number, failure_detail(&output)).into());
    }
    Ok(())
}
struct Target<'a> {
    git: &'a Git<'a>,
    root: &'a Path,
    storage: &'a Path,
    repository_name: &'a str,
    branch: &'a str,
    number: u64,
    expected: &'a str,
    pr: &'a Metadata,
    tracking: bool,
    fetch_source: &'a str,
    fetched_ref: &'a str,
    main_head: Option<&'a str>,
}
impl Target<'_> {
    fn create(
        &self,
        gh: &mut dyn FnMut(&[String]) -> Result<Vec<u8>>,
        protocol: &mut Protocol,
    ) -> Result<Checkout> {
        let (git, root, branch, number) = (self.git, self.root, self.branch, self.number);
        let fetched = git.commit(root, self.fetched_ref)?.ok_or_else(|| {
            Failure::checkout(number, "The fetched pull request head is unavailable.")
        })?;
        if fetched != self.expected {
            return Err(Failure::changed(number).into());
        }
        let reference = format!("refs/heads/{branch}");
        let local = git.commit(root, &reference)?;
        if let Some(local) = &local
            && local != &fetched
        {
            if git.ancestor(root, local, &fetched)? {
                // The fast-forward `git merge --ff-only` or a non-forced fetch makes.
                let reason = format!("coincide: check out pull request #{number}");
                git.checked(
                    root,
                    &["update-ref", "-m", &reason, &reference, &fetched, local],
                    |detail| Failure::checkout(number, detail),
                )?;
            } else if !self.tracking || !git.ancestor(root, &fetched, local)? {
                // A remote-tracking checkout keeps a branch that is already ahead
                // ("Already up to date"); a pull ref fetch refuses any non-fast-forward.
                return Err(Failure::checkout(
                    number,
                    if self.tracking {
                        "fatal: Not possible to fast-forward, aborting.".to_owned()
                    } else {
                        format!(
                            "! [rejected] refs/pull/{number}/head -> {branch} (non-fast-forward)"
                        )
                    },
                )
                .into());
            }
        }
        let path = destination(self.storage, self.repository_name, branch)?;
        let destination = external_git_path(&path)?;
        let (options, start) = match (&local, self.tracking) {
            (Some(_), _) => (&[][..], branch),
            (None, true) => (&["--track", "-b", branch][..], self.fetched_ref),
            (None, false) => (&["--no-track", "-b", branch][..], fetched.as_str()),
        };
        let mut add = ["worktree", "add", "--lock", "--reason", UNFINISHED]
            .iter()
            .chain(options)
            .map(OsStr::new)
            .collect::<Vec<_>>();
        add.extend([OsStr::new("--"), &destination, OsStr::new(start)]);
        let added = match git.execute(root, &[], &add, CREATE) {
            Ok(output) => output,
            Err(error) => {
                // Killed mid-checkout: Git could not remove its partial worktree.
                discard(git, root, &destination);
                return Err(error);
            }
        };
        if !added.success() {
            return Err(Failure::create(failure_detail(&added)).into());
        }
        // Unlocked only once it is ready, so a checkout that stops before then
        // leaves a worktree the next one replaces rather than reuses.
        let finished = self.finish(&path, gh, protocol).and_then(|()| {
            let unlocked = worktree(git, root, &["unlock"], &destination, QUICK)?;
            if !unlocked.success() {
                return Err(Failure::create(failure_detail(&unlocked)).into());
            }
            Ok(())
        });
        if let Err(error) = finished {
            // Nothing was made in it yet, so it goes without asking.
            discard(git, root, &destination);
            return Err(error);
        }
        // The branch diff compares against the pull request's base rather than guessing one.
        let key = format!("branch.{branch}.coincide-merge-base");
        if matches!(git.config(root, &key), Ok(None)) {
            let _ = git.run(root, &["config", &key, &self.pr.base_branch], QUICK);
        }
        Ok(Checkout {
            path: path.canonicalize()?,
            branch: branch.to_owned(),
            reused: false,
            number,
        })
    }
    fn finish(
        &self,
        path: &Path,
        gh: &mut dyn FnMut(&[String]) -> Result<Vec<u8>>,
        protocol: &mut Protocol,
    ) -> Result<()> {
        let (git, root, branch, number) = (self.git, self.root, self.branch, self.number);
        if !self.tracking
            && git
                .config(root, &format!("branch.{branch}.merge"))?
                .is_none()
        {
            // gh: .remote for `git pull`, .pushRemote for `git push` under
            // remote.pushDefault, and the fork's branch when maintainers may push.
            let (remote, merge) = match (&self.pr.head_repository, self.pr.maintainer_can_modify) {
                (Some((owner, name)), true) => (
                    remote_url(owner, name, protocol.ssh(gh)),
                    format!("refs/heads/{}", self.pr.head_branch),
                ),
                _ => (
                    self.fetch_source.to_owned(),
                    format!("refs/pull/{number}/head"),
                ),
            };
            for (key, value) in [
                ("remote", &remote),
                ("pushRemote", &remote),
                ("merge", &merge),
            ] {
                let key = format!("branch.{branch}.{key}");
                git.checked(root, &["config", &key, value], |detail| {
                    Failure::checkout(number, detail)
                })?;
            }
        }
        // Swift passes --recurse-submodules when the new worktree, made from the
        // project folder's HEAD, has a .gitmodules file.
        let modules = match self.main_head {
            Some(head) => {
                let spec = format!("{head}:.gitmodules");
                git.run(root, &["rev-parse", "--verify", "--quiet", &spec], QUICK)?
                    .success()
            }
            None => false,
        };
        if modules {
            for args in [
                &["submodule", "sync", "--recursive"][..],
                &["submodule", "update", "--init", "--recursive"][..],
            ] {
                let output = git.run(path, args, NETWORK)?;
                if !output.success() {
                    return Err(Failure::checkout(number, failure_detail(&output)).into());
                }
            }
        }
        Ok(())
    }
}
/// `git worktree <args> -- <path>` from the repository root.
fn worktree(
    git: &Git<'_>,
    root: &Path,
    args: &[&str],
    path: &OsStr,
    timeout: Duration,
) -> Result<Output> {
    let mut all = ["worktree"]
        .iter()
        .chain(args)
        .map(OsStr::new)
        .collect::<Vec<_>>();
    all.extend([OsStr::new("--"), path]);
    git.execute(root, &[], &all, timeout)
}
fn discard(git: &Git<'_>, root: &Path, destination: &OsStr) {
    // The second --force overrides the lock a killed `worktree add` leaves.
    let args = ["remove", "--force", "--force"];
    let _ = worktree(&git.uncancellable(), root, &args, destination, CREATE);
}
