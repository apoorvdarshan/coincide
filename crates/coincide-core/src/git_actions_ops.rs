//! The git operations behind the action bar and branch toolbar (Swift GitOps,
//! GitParse and GitHubCLI). Each runs on a worker thread and returns plain values.
use super::{
    ChangedFile, FileStatus, GitBranch, GitBranchList, GitCommit, GitPullRequest, GitPushResult,
    GitStatus, GitWorktree, PullResult, PushOutcome,
    cli::{self, GitError, Invocation, NORMAL, SHORT, checked, fail, git, value},
    host::Host,
    names,
};
use anyhow::Result;
use std::{
    collections::{HashMap, HashSet},
    ffi::OsStr,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

// MARK: Parsing

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct PorcelainEntry {
    /// `1` ordinary, `2` renamed or copied, `u` unmerged, `?` untracked.
    pub kind: char,
    pub xy: String,
    pub path: String,
    pub original_path: Option<String>,
}

impl PorcelainEntry {
    fn status(&self) -> FileStatus {
        match self.kind {
            '?' => FileStatus::Untracked,
            '2' if self.xy.contains('C') => FileStatus::Added,
            '2' => FileStatus::Renamed,
            'u' => FileStatus::Modified,
            _ if self.xy.contains('A') => FileStatus::Added,
            _ if self.xy.contains('D') => FileStatus::Deleted,
            _ => FileStatus::Modified,
        }
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Porcelain {
    pub oid: Option<String>,
    pub head: Option<String>,
    pub upstream: Option<String>,
    pub ahead: u64,
    pub behind: u64,
    pub entries: Vec<PorcelainEntry>,
}

/// Parses `git status --porcelain=2 --branch -z`.
pub(crate) fn parse_porcelain_v2(output: &str) -> Porcelain {
    let mut status = Porcelain::default();
    let records: Vec<&str> = output.split('\0').collect();
    let mut index = 0;
    while index < records.len() {
        let record = records[index];
        index += 1;
        let Some(first) = record.chars().next() else {
            continue;
        };
        if let Some(header) = record.strip_prefix("# ") {
            let Some((key, value)) = header.split_once(' ') else {
                continue;
            };
            match key {
                "branch.oid" => status.oid = (value != "(initial)").then(|| value.into()),
                "branch.head" => status.head = (value != "(detached)").then(|| value.into()),
                "branch.upstream" => status.upstream = Some(value.into()),
                "branch.ab" => {
                    let numbers: Vec<u64> = value
                        .split(' ')
                        .map(|part| part.get(1..).and_then(|n| n.parse().ok()).unwrap_or(0))
                        .collect();
                    if let [ahead, behind] = numbers.as_slice() {
                        status.ahead = *ahead;
                        status.behind = *behind;
                    }
                }
                _ => {}
            }
            continue;
        }
        let before_path = match first {
            '1' => 8,
            '2' => 9,
            'u' => 10,
            '?' => 1,
            _ => continue,
        };
        let fields: Vec<&str> = record.splitn(before_path + 1, ' ').collect();
        if fields.len() != before_path + 1 {
            continue;
        }
        let mut entry = PorcelainEntry {
            kind: first,
            xy: if before_path > 1 {
                fields[1].into()
            } else {
                "??".into()
            },
            path: fields[before_path].into(),
            original_path: None,
        };
        // A rename record is followed by its original path as a separate record.
        if first == '2' && index < records.len() {
            entry.original_path = Some(records[index].into());
            index += 1;
        }
        status.entries.push(entry);
    }
    status
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Numstat {
    pub path: String,
    pub additions: u64,
    pub deletions: u64,
}

/// Parses `git diff --numstat -z`, including rename records (`a\td\t\0old\0new\0`).
pub(crate) fn parse_numstat(output: &str) -> Vec<Numstat> {
    let fields: Vec<&str> = output.split('\0').collect();
    let mut result = Vec::new();
    let mut index = 0;
    while index < fields.len() {
        let parts: Vec<&str> = fields[index].splitn(3, '\t').collect();
        index += 1;
        let [additions, deletions, path] = parts.as_slice() else {
            continue;
        };
        let mut path = (*path).to_owned();
        if path.is_empty() {
            if index + 1 >= fields.len() {
                break;
            }
            path = fields[index + 1].into();
            index += 2;
        }
        if path.is_empty() {
            continue;
        }
        result.push(Numstat {
            path,
            additions: additions.parse().unwrap_or(0),
            deletions: deletions.parse().unwrap_or(0),
        });
    }
    result
}

/// Parses `git worktree list --porcelain -z`.
pub(crate) fn parse_worktrees(output: &str) -> Vec<GitWorktree> {
    let mut result = Vec::new();
    let mut current: Option<GitWorktree> = None;
    for field in output.split('\0') {
        if field.is_empty() {
            result.extend(current.take());
        } else if let Some(path) = field.strip_prefix("worktree ") {
            result.extend(current.take());
            current = Some(GitWorktree {
                path: path.into(),
                is_main: result.is_empty(),
                ..GitWorktree::default()
            });
        } else if let Some(worktree) = current.as_mut() {
            if let Some(head) = field.strip_prefix("HEAD ") {
                worktree.head = Some(head.into());
            } else if let Some(reference) = field.strip_prefix("branch ") {
                worktree.branch = Some(
                    reference
                        .strip_prefix("refs/heads/")
                        .unwrap_or(reference)
                        .into(),
                );
            } else if field == "prunable" || field.starts_with("prunable ") {
                worktree.is_prunable = true;
            } else if field == "locked" || field.starts_with("locked ") {
                worktree.is_locked = true;
            }
        }
    }
    result.extend(current);
    result
}

// MARK: Repository

/// Git reports physical paths; this spells them the way the store does.
pub(crate) fn normalize(path: &str) -> String {
    Path::new(path)
        .canonicalize()
        .ok()
        .and_then(|path| path.to_str().map(str::to_owned))
        .unwrap_or_else(|| path.to_owned())
}

pub(crate) fn repository_root(cwd: &Path) -> Option<PathBuf> {
    if !cwd.is_dir() {
        return None;
    }
    value(cwd, &["rev-parse", "--show-toplevel"]).map(|path| PathBuf::from(normalize(&path)))
}

fn ref_exists(reference: &str, cwd: &Path) -> bool {
    git(cwd, &["show-ref", "--verify", "--quiet", reference], SHORT).success
}

fn config_value(key: &str, cwd: &Path) -> Option<String> {
    value(cwd, &["config", "--get", key])
}

pub(crate) fn remote_names(cwd: &Path) -> Vec<String> {
    let output = git(cwd, &["remote"], SHORT);
    if !output.success {
        return Vec::new();
    }
    output
        .stdout
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect()
}

/// `origin` when it exists, otherwise the first remote.
pub(crate) fn primary_remote(remotes: &[String]) -> Option<&str> {
    if remotes.iter().any(|remote| remote == "origin") {
        Some("origin")
    } else {
        remotes.first().map(String::as_str)
    }
}

/// The branch `<remote>/HEAD` points at, such as `main`.
fn default_branch(cwd: &Path, remote: &str) -> Option<String> {
    let reference = value(
        cwd,
        &["symbolic-ref", &format!("refs/remotes/{remote}/HEAD")],
    )?;
    reference
        .strip_prefix(&format!("refs/remotes/{remote}/"))
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
}

pub(crate) fn head_commit(cwd: &Path) -> Option<String> {
    value(cwd, &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
}

pub(crate) fn current_branch(cwd: &Path) -> Option<String> {
    value(cwd, &["symbolic-ref", "--quiet", "--short", "HEAD"])
}

// MARK: Status

/// Joins a repository-relative git path component by component, since a Windows
/// verbatim root does not treat `/` as a separator.
fn join_relative(root: &Path, path: &str) -> PathBuf {
    path.split('/')
        .filter(|part| !part.is_empty())
        .fold(root.to_path_buf(), |joined, part| joined.join(part))
}

/// Lines in a text file, counted as `git diff` counts an added file; None for
/// folders, binary files and files over a megabyte.
fn line_count(path: &Path) -> Option<u64> {
    let metadata = std::fs::symlink_metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > 1_000_000 {
        return None;
    }
    let data = std::fs::read(path).ok()?;
    if data.contains(&0) {
        return None;
    }
    let newlines = data.iter().filter(|b| **b == b'\n').count() as u64;
    Some(match data.last() {
        None => 0,
        Some(b'\n') => newlines,
        Some(_) => newlines + 1,
    })
}

fn tracked_numstat(cwd: &Path, has_head: bool) -> Vec<Numstat> {
    let env: &[(&str, &OsStr)] = &[("GIT_OPTIONAL_LOCKS", OsStr::new("0"))];
    if has_head {
        let output = cli::run_git(&Invocation {
            env,
            ..Invocation::new(
                cwd,
                &["diff-index", "-M", "--numstat", "-z", "HEAD", "--"],
                NORMAL,
            )
        });
        return if output.success {
            parse_numstat(&output.stdout)
        } else {
            Vec::new()
        };
    }
    let staged = git(cwd, &["diff", "--cached", "--numstat", "-z"], NORMAL);
    let unstaged = git(cwd, &["diff-files", "--numstat", "-z"], NORMAL);
    let mut stats = parse_numstat(&staged.stdout);
    stats.extend(parse_numstat(&unstaged.stdout));
    stats
}

fn digits(it: &mut std::iter::Peekable<std::str::Chars<'_>>) -> String {
    let mut digits = String::new();
    while let Some(c) = it.peek().copied().filter(char::is_ascii_digit) {
        digits.push(c);
        it.next();
    }
    digits
}

/// Case-insensitive, with runs of digits compared as numbers (Finder's order).
pub(crate) fn natural_cmp(left: &str, right: &str) -> std::cmp::Ordering {
    let mut a = left.chars().peekable();
    let mut b = right.chars().peekable();
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return left.cmp(right),
            (None, Some(_)) => return std::cmp::Ordering::Less,
            (Some(_), None) => return std::cmp::Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let (x, y) = (digits(&mut a), digits(&mut b));
                let (tx, ty) = (x.trim_start_matches('0'), y.trim_start_matches('0'));
                let order = tx.len().cmp(&ty.len()).then_with(|| tx.cmp(ty));
                if order != std::cmp::Ordering::Equal {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                let order = x.to_lowercase().cmp(y.to_lowercase());
                if order != std::cmp::Ordering::Equal {
                    return order;
                }
                a.next();
                b.next();
            }
        }
    }
}

pub fn status(cwd: &Path) -> Result<GitStatus> {
    if !cwd.is_dir() {
        return Ok(GitStatus::not_repository());
    }
    let output = cli::run_git(&Invocation {
        env: &[("GIT_OPTIONAL_LOCKS", OsStr::new("0"))],
        ..Invocation::new(cwd, &["status", "--porcelain=2", "--branch", "-z"], NORMAL)
    });
    if !output.success {
        if cli::is_not_repository(&output.stderr) {
            return Ok(GitStatus::not_repository());
        }
        return Err(GitError::failed("Could not read the Git status.", &output).into());
    }
    let parsed = parse_porcelain_v2(&output.stdout);
    let mut stats: HashMap<String, (u64, u64)> = HashMap::new();
    for stat in tracked_numstat(cwd, parsed.oid.is_some()) {
        let entry = stats.entry(stat.path).or_default();
        entry.0 += stat.additions;
        entry.1 += stat.deletions;
    }
    let root = repository_root(cwd);
    let remotes = remote_names(cwd);
    let default = default_branch(cwd, "origin");
    let mut untracked_counted = 0;
    let mut files: Vec<ChangedFile> = parsed
        .entries
        .iter()
        .map(|entry| {
            let (mut additions, deletions) = stats.get(&entry.path).copied().unwrap_or_default();
            // Untracked files have no numstat; count their lines like the diff would.
            if entry.kind == '?'
                && untracked_counted < 500
                && let Some(lines) = root
                    .as_ref()
                    .and_then(|root| line_count(&join_relative(root, &entry.path)))
            {
                untracked_counted += 1;
                additions = lines;
            }
            ChangedFile {
                path: entry.path.clone(),
                old_path: entry.original_path.clone(),
                status: entry.status(),
                additions,
                deletions,
            }
        })
        .collect();
    files.sort_by(|a, b| natural_cmp(&a.path, &b.path));
    let mut status = GitStatus {
        is_repository: true,
        root_path: root
            .as_ref()
            .and_then(|root| root.to_str().map(str::to_owned)),
        branch: parsed.head.clone(),
        head_oid: parsed.oid.clone(),
        upstream: parsed.upstream.clone(),
        ahead: parsed.ahead,
        behind: parsed.behind,
        default_branch: default.clone(),
        has_remote: !remotes.is_empty(),
        files,
        conflicted_paths: parsed
            .entries
            .iter()
            .filter(|entry| entry.kind == 'u')
            .map(|entry| entry.path.clone())
            .collect(),
        ..GitStatus::default()
    };
    if let Some(branch) = parsed.head.as_deref() {
        status.is_default_branch = Some(branch) == default.as_deref()
            || (default.is_none() && matches!(branch, "main" | "master"));
        if parsed.upstream.is_none() && parsed.oid.is_some() {
            // Without an upstream, "ahead" means commits the base branch does not have.
            status.ahead = ahead_of_base(cwd, branch, default.as_deref(), &remotes);
            status.behind = 0;
            status.ahead_of_default = if status.is_default_branch {
                0
            } else {
                status.ahead
            };
        } else if !status.is_default_branch && parsed.oid.is_some() {
            status.ahead_of_default = ahead_of_base(cwd, branch, default.as_deref(), &remotes);
        }
    }
    Ok(status)
}

/// Full ref to compare a branch without (or ignoring) its upstream against: the base
/// recorded when its worktree was made, then the remote's default branch, then
/// `main` / `master`.
fn base_ref(cwd: &Path, branch: &str, default: Option<&str>, remotes: &[String]) -> Option<String> {
    let primary = primary_remote(remotes);
    let mut candidates: Vec<String> = Vec::new();
    candidates.extend(config_value(&names::merge_base_config_key(branch), cwd));
    candidates.extend(default.map(str::to_owned));
    candidates.extend(["main".to_owned(), "master".to_owned()]);
    for candidate in candidates {
        let mut name = candidate.as_str();
        name = name.strip_prefix("refs/heads/").unwrap_or(name);
        name = name.strip_prefix("refs/remotes/").unwrap_or(name);
        let mut name = name.to_owned();
        if let Some(remote) = remotes
            .iter()
            .find(|remote| name.starts_with(&format!("{remote}/")))
        {
            if ref_exists(&format!("refs/remotes/{name}"), cwd) {
                if name == format!("{remote}/{branch}") {
                    continue;
                }
                return Some(format!("refs/remotes/{name}"));
            }
            name = name[remote.len() + 1..].to_owned();
        }
        if name.is_empty() || name == branch {
            continue;
        }
        if let Some(primary) = primary {
            let remote_ref = format!("refs/remotes/{primary}/{name}");
            if ref_exists(&remote_ref, cwd) {
                return Some(remote_ref);
            }
        }
        if ref_exists(&format!("refs/heads/{name}"), cwd) {
            return Some(format!("refs/heads/{name}"));
        }
    }
    None
}

fn ahead_of_base(cwd: &Path, branch: &str, default: Option<&str>, remotes: &[String]) -> u64 {
    let Some(base) = base_ref(cwd, branch, default, remotes) else {
        return 0;
    };
    value(
        cwd,
        &[
            "rev-list",
            "--count",
            "--end-of-options",
            &format!("{base}..HEAD"),
        ],
    )
    .and_then(|count| count.parse().ok())
    .unwrap_or(0)
}

// MARK: Branches

pub fn branches(cwd: &Path) -> Result<GitBranchList> {
    let Some(root) = repository_root(cwd) else {
        return Ok(GitBranchList::default());
    };
    let refs = git(
        &root,
        &[
            "for-each-ref",
            "--format=%(refname)%09%(committerdate:unix)%09%(symref)%09%(upstream:short)",
            "refs/heads",
            "refs/remotes",
        ],
        NORMAL,
    );
    if !refs.success {
        return Err(GitError::failed("Could not list branches.", &refs).into());
    }
    let current = current_branch(&root);
    let default = default_branch(&root, "origin");
    let remotes = remote_names(&root);
    let mut worktree_by_branch: HashMap<String, String> = HashMap::new();
    let worktrees = git(&root, &["worktree", "list", "--porcelain", "-z"], NORMAL);
    for worktree in parse_worktrees(&worktrees.stdout) {
        if !worktree.is_prunable
            && let Some(branch) = worktree.branch
            && Path::new(&worktree.path).exists()
        {
            worktree_by_branch.insert(branch, normalize(&worktree.path));
        }
    }
    let root_path = root.to_string_lossy().into_owned();
    let mut local = Vec::new();
    let mut remote = Vec::new();
    for line in refs.stdout.lines() {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() < 3 || !fields[2].is_empty() {
            continue;
        }
        let date = fields[1].parse::<i64>().ok();
        let upstream = fields
            .get(3)
            .filter(|v| !v.is_empty())
            .map(|v| (*v).to_owned());
        if let Some(name) = fields[0].strip_prefix("refs/heads/") {
            let worktree = worktree_by_branch.get(name).cloned();
            let is_current = match &worktree {
                Some(path) => *path == root_path,
                None => Some(name) == current.as_deref(),
            };
            local.push(GitBranch {
                name: name.into(),
                is_current,
                is_default: Some(name) == default.as_deref(),
                upstream,
                // Only another folder's checkout is worth a tag.
                worktree_path: worktree,
                last_commit_date: date,
                ..GitBranch::default()
            });
        } else if let Some(name) = fields[0].strip_prefix("refs/remotes/") {
            let remote_name = remotes
                .iter()
                .filter(|remote| name.starts_with(&format!("{remote}/")))
                .max_by_key(|remote| remote.len())
                .cloned();
            let is_default = remote_name.as_deref() == Some("origin")
                && default
                    .as_deref()
                    .is_some_and(|default| name == format!("origin/{default}"));
            remote.push(GitBranch {
                name: name.into(),
                is_remote: true,
                remote_name,
                is_default,
                last_commit_date: date,
                ..GitBranch::default()
            });
        }
    }
    let by_recency = |a: &GitBranch, b: &GitBranch| {
        b.last_commit_date
            .unwrap_or(i64::MIN)
            .cmp(&a.last_commit_date.unwrap_or(i64::MIN))
            .then_with(|| natural_cmp(&a.name, &b.name))
    };
    local.sort_by(by_recency);
    remote.sort_by(by_recency);
    // Hide origin branches that already have a local branch of the same name.
    let local_names: HashSet<String> = local.iter().map(|b| b.name.clone()).collect();
    remote.retain(|branch| {
        branch.remote_name.as_deref() != Some("origin")
            || !local_names.contains(&branch.local_name())
    });
    let mut ordered: Vec<GitBranch> = local.into_iter().chain(remote).collect();
    let rank = |branch: &GitBranch| {
        if branch.is_current {
            0
        } else if branch.is_default && !branch.is_remote {
            1
        } else {
            2
        }
    };
    ordered.sort_by_key(rank);
    Ok(GitBranchList {
        is_repository: true,
        branches: ordered,
        current_branch: current,
        default_branch: default,
        has_remote: !remotes.is_empty(),
    })
}

fn validate_branch_name(name: &str, cwd: &Path) -> Result<()> {
    if name.is_empty()
        || name.starts_with('-')
        || !git(cwd, &["check-ref-format", "--branch", name], SHORT).success
    {
        return fail(format!("“{name}” is not a valid branch name."));
    }
    Ok(())
}

/// Checks out a local branch, or a remote branch through a local tracking branch.
/// Returns the branch checked out afterwards, None when HEAD ended up detached.
pub fn checkout(name: &str, cwd: &Path) -> Result<Option<String>> {
    if name.starts_with('-') || name.is_empty() {
        return fail(format!("“{name}” is not a valid branch name."));
    }
    let mut target = vec!["checkout".to_owned(), name.to_owned()];
    if !ref_exists(&format!("refs/heads/{name}"), cwd)
        && ref_exists(&format!("refs/remotes/{name}"), cwd)
    {
        let tracking = git(
            cwd,
            &[
                "for-each-ref",
                "--format=%(refname:short)%09%(upstream:short)",
                "refs/heads",
            ],
            NORMAL,
        );
        let existing = tracking.stdout.lines().find_map(|line| {
            let (local, upstream) = line.split_once('\t')?;
            (upstream == name).then(|| local.to_owned())
        });
        if let Some(local) = existing {
            target = vec!["checkout".into(), local];
        } else if !ref_exists(
            &format!("refs/heads/{}", names::local_name_from_remote_ref(name)),
            cwd,
        ) {
            target = vec!["checkout".into(), "--track".into(), name.into()];
        }
    }
    // The trailing `--` keeps a stale ref name from turning into a path checkout.
    target.push("--".into());
    let args: Vec<&str> = target.iter().map(String::as_str).collect();
    checked(
        &format!("Could not switch to “{name}”."),
        cwd,
        &args,
        Duration::from_secs(60),
    )?;
    Ok(current_branch(cwd))
}

/// Creates a branch from HEAD (whitespace becomes hyphens), checking it out when asked.
pub fn create_branch(raw: &str, cwd: &Path, checkout_after: bool) -> Result<String> {
    let name = names::sanitize_new_ref_name(raw);
    validate_branch_name(&name, cwd)?;
    checked(
        &format!("Could not create “{name}”."),
        cwd,
        &["branch", "--", &name],
        NORMAL,
    )?;
    if checkout_after {
        checkout(&name, cwd)?;
    }
    Ok(name)
}

/// Renames a branch, adding `-1`, `-2`… when the name is taken.
pub fn rename_branch(old: &str, new: &str, cwd: &Path) -> Result<String> {
    if old == new {
        return Ok(new.into());
    }
    validate_branch_name(new, cwd)?;
    let mut target = new.to_owned();
    if ref_exists(&format!("refs/heads/{new}"), cwd) {
        for suffix in 1..=100 {
            target = format!("{new}-{suffix}");
            if !ref_exists(&format!("refs/heads/{target}"), cwd) {
                break;
            }
        }
    }
    checked(
        &format!("Could not rename “{old}”."),
        cwd,
        &["branch", "-m", "--", old, &target],
        NORMAL,
    )?;
    Ok(target)
}

// MARK: Worktrees

pub fn worktrees(cwd: &Path) -> Result<Vec<GitWorktree>> {
    let output = git(cwd, &["worktree", "list", "--porcelain", "-z"], NORMAL);
    if !output.success {
        return Err(GitError::failed("Could not list worktrees.", &output).into());
    }
    Ok(parse_worktrees(&output.stdout)
        .into_iter()
        .map(|mut worktree| {
            worktree.path = normalize(&worktree.path);
            worktree
        })
        .collect())
}

/// The main checkout of the repository `worktree` belongs to.
pub fn main_worktree(worktree: &Path) -> Option<PathBuf> {
    worktrees(worktree)
        .ok()?
        .into_iter()
        .find(|tree| tree.is_main)
        .map(|tree| PathBuf::from(tree.path))
}

/// Home folders are often group-readable; checkouts of possibly private repositories
/// are kept in an owner-only folder.
fn prepare_owner_only(path: &Path) -> Result<()> {
    std::fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
    }
    Ok(())
}

fn unique_worktree_path(root: &Path, repository: &str, branch: &str) -> PathBuf {
    let folder = root.join(repository);
    let name = branch.replace('/', "-");
    let mut candidate = folder.join(&name);
    let mut suffix = 2;
    while std::fs::symlink_metadata(&candidate).is_ok() {
        candidate = folder.join(format!("{name}-{suffix}"));
        suffix += 1;
    }
    candidate
}

/// Creates a worktree for a thread on a temporary branch named with `prefix`, started
/// from `base` (HEAD when None), in `worktrees_root/<repository>/`.
pub fn create_thread_worktree(
    project: &Path,
    base: Option<&str>,
    prefix: &str,
    worktrees_root: &Path,
) -> Result<GitWorktree> {
    let Some(root) = repository_root(project) else {
        return fail("This folder is not a Git repository.");
    };
    let mut branch = names::temporary_worktree_branch(prefix);
    // An existing branch named like the prefix blocks nested refs such as `prefix/abc`.
    if let Some(flat) = prefix.strip_suffix('/')
        && ref_exists(&format!("refs/heads/{flat}"), &root)
    {
        branch = names::flattened_temporary_branch(&branch, prefix);
    }
    if base.is_some_and(|base| base.starts_with('-')) {
        return fail(format!("“{branch}” is not a valid branch name."));
    }
    prepare_owner_only(worktrees_root)?;
    let repository = root
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or("repository")
        .to_owned();
    let destination = unique_worktree_path(worktrees_root, &repository, &branch);
    if let Some(parent) = destination.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let destination_text = crate::workspace::external_git_path(&destination)?
        .to_string_lossy()
        .into_owned();
    let workers = config_value("checkout.workers", &root).unwrap_or_else(|| "0".into());
    let workers = format!("checkout.workers={workers}");
    // The base is recorded separately; an upstream is set only when the branch is pushed.
    let mut args = vec![
        "-c",
        &workers,
        "worktree",
        "add",
        "--no-track",
        "-b",
        &branch,
        "--",
        &destination_text,
    ];
    if let Some(base) = base {
        args.push(base);
    }
    checked(
        "Could not create the worktree.",
        &root,
        &args,
        Duration::from_secs(300),
    )?;
    // `worktree add` leaves submodules empty, which can hide project tools or sources.
    if destination.join(".gitmodules").exists() {
        git(
            &destination,
            &["submodule", "update", "--init", "--recursive"],
            Duration::from_secs(600),
        );
    }
    if let Some(base) = base.filter(|base| !base.is_empty()) {
        git(
            &root,
            &["config", &names::merge_base_config_key(&branch), base],
            SHORT,
        );
    }
    Ok(GitWorktree {
        path: normalize(&destination.to_string_lossy()),
        head: head_commit(&destination),
        branch: Some(branch),
        ..GitWorktree::default()
    })
}

fn remove_worktree(path: &Path, repository: &Path) -> Result<()> {
    let path_text = crate::workspace::external_git_path(path)?
        .to_string_lossy()
        .into_owned();
    // `worktree remove` honours status.showUntrackedFiles=no and would delete untracked files.
    let output = git(
        repository,
        &[
            "-c",
            "status.showUntrackedFiles=normal",
            "worktree",
            "remove",
            "--",
            &path_text,
        ],
        Duration::from_secs(300),
    );
    if output.success {
        return Ok(());
    }
    if output
        .stderr
        .to_lowercase()
        .contains("is not a working tree")
        && !path.exists()
    {
        git(repository, &["worktree", "prune"], NORMAL);
        return Ok(());
    }
    Err(GitError::failed("Could not remove the worktree.", &output).into())
}

/// Removes a worktree made for a thread that never used it: only when it has no
/// changes and its temporary branch has no commits of its own.
pub fn discard_unused_worktree(path: &Path, branch: Option<&str>, prefix: &str) -> bool {
    let Some(root) = repository_root(path) else {
        return false;
    };
    let Ok(status) = status(&root) else {
        return false;
    };
    if !status.is_repository || status.has_changes() {
        return false;
    }
    let Some(repository) = main_worktree(&root) else {
        return false;
    };
    if remove_worktree(&root, &repository).is_err() {
        return false;
    }
    if let Some(branch) =
        branch.filter(|branch| names::is_temporary_worktree_branch(branch, prefix))
    {
        let unique = value(
            &repository,
            &[
                "rev-list",
                "--count",
                &format!("refs/heads/{branch}"),
                "--not",
                &format!("--exclude={branch}"),
                "--branches",
            ],
        );
        if unique.as_deref() == Some("0") {
            git(&repository, &["branch", "-D", "--", branch], SHORT);
        }
    }
    true
}

/// Renames a thread's temporary worktree branch after what the thread is about.
pub fn name_worktree_branch(
    branch: &str,
    worktree: &Path,
    message: &str,
    prefix: &str,
) -> Result<Option<String>> {
    if !names::is_temporary_worktree_branch(branch, prefix) {
        return Ok(None);
    }
    // A flattened `prefix-<token>` branch keeps the flat form, since nested refs are blocked.
    let name_prefix = if branch.starts_with(prefix) {
        prefix.to_owned()
    } else {
        branch
            .chars()
            .take(branch.chars().count().saturating_sub(8))
            .collect()
    };
    let name = names::descriptive_branch(message, &name_prefix);
    rename_branch(branch, &name, worktree).map(Some)
}

// MARK: Commit

fn literal_paths(paths: &[String]) -> Vec<String> {
    // Status paths are repository-relative, while cwd can be a subdirectory.
    paths
        .iter()
        .map(|path| format!(":(top,literal){path}"))
        .collect()
}

fn stage(paths: Option<&[String]>, cwd: &Path) -> Result<()> {
    match paths.filter(|paths| !paths.is_empty()) {
        Some(paths) => {
            git(cwd, &["reset", "--quiet"], NORMAL);
            let pathspecs = literal_paths(paths);
            let mut args = vec!["add", "-A", "--"];
            args.extend(pathspecs.iter().map(String::as_str));
            checked(
                "Could not stage the selected files.",
                cwd,
                &args,
                Duration::from_secs(120),
            )?;
        }
        None => {
            checked(
                "Could not stage changes.",
                cwd,
                &["add", "-A"],
                Duration::from_secs(120),
            )?;
        }
    }
    Ok(())
}

pub fn commit(
    subject: &str,
    body: &str,
    paths: Option<&[String]>,
    cwd: &Path,
) -> Result<GitCommit> {
    stage(paths, cwd)?;
    let mut args = vec!["commit", "-m", subject];
    let body = body.trim();
    if !body.is_empty() {
        args.extend(["-m", body]);
    }
    // Commit hooks can take a while.
    checked("Could not commit.", cwd, &args, Duration::from_secs(600))?;
    Ok(GitCommit {
        sha: head_commit(cwd).unwrap_or_default(),
        subject: subject.into(),
    })
}

/// What a commit of `paths` (or everything) would contain, read through a throwaway
/// index so the real one is untouched. None when there is nothing to commit.
pub fn commit_summary(paths: Option<&[String]>, cwd: &Path) -> Result<Option<String>> {
    let failure = "Could not prepare the commit.";
    let index = value(
        cwd,
        &["rev-parse", "--path-format=absolute", "--git-path", "index"],
    );
    let temporary = tempfile_path("coincide-commit-index");
    let _cleanup = RemoveOnDrop(temporary.clone());
    let env: &[(&str, &OsStr)] = &[("GIT_INDEX_FILE", temporary.as_os_str())];
    let config = [
        "-c",
        "core.splitIndex=false",
        "-c",
        "splitIndex.sharedIndexExpire=never",
    ];
    let run = |args: &[&str], timeout: Duration| -> Result<String> {
        let mut full: Vec<&str> = config.to_vec();
        full.extend_from_slice(args);
        cli::checked_with(
            failure,
            &Invocation {
                env,
                ..Invocation::new(cwd, &full, timeout)
            },
        )
    };
    match index.filter(|index| Path::new(index).is_file()) {
        Some(index) => {
            copy_index(Path::new(&index), &temporary)?;
            run(&["update-index", "--no-split-index"], NORMAL)?;
        }
        None => {
            run(&["read-tree", "--empty"], NORMAL)?;
        }
    }
    match paths.filter(|paths| !paths.is_empty()) {
        Some(paths) => {
            if head_commit(cwd).is_some() {
                run(&["read-tree", "HEAD"], NORMAL)?;
            } else {
                run(&["read-tree", "--empty"], NORMAL)?;
            }
            let pathspecs = literal_paths(paths);
            let mut args = vec!["add", "-A", "--"];
            args.extend(pathspecs.iter().map(String::as_str));
            run(&args, Duration::from_secs(120))?;
        }
        None => {
            run(&["add", "-A"], Duration::from_secs(120))?;
        }
    }
    let summary = run(&["diff", "--cached", "--name-status"], NORMAL)?;
    let summary = summary.trim();
    Ok((!summary.is_empty()).then(|| summary.to_owned()))
}

/// Copies an index keeping its timestamp (floored to whole seconds) so git's
/// racy-clean check still works on the copy.
fn copy_index(source: &Path, destination: &Path) -> Result<()> {
    let modified = std::fs::metadata(source)?.modified()?;
    std::fs::copy(source, destination)?;
    if let Ok(since) = modified.duration_since(std::time::UNIX_EPOCH) {
        let floored = std::time::UNIX_EPOCH + Duration::from_secs(since.as_secs());
        std::fs::OpenOptions::new()
            .write(true)
            .open(destination)?
            .set_modified(floored)?;
    }
    Ok(())
}

fn tempfile_path(prefix: &str) -> PathBuf {
    std::env::temp_dir().join(format!("{prefix}-{}", uuid::Uuid::new_v4()))
}

struct RemoveOnDrop(PathBuf);
impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

// MARK: Push and pull

/// `branch.<name>.pushRemote`, then `remote.pushDefault`, then the primary remote.
fn push_remote(cwd: &Path, branch: &str, remotes: &[String]) -> Option<String> {
    config_value(&format!("branch.{branch}.pushRemote"), cwd)
        .or_else(|| config_value("remote.pushDefault", cwd))
        .or_else(|| primary_remote(remotes).map(str::to_owned))
}

const PUSH_TIMEOUT: Duration = Duration::from_secs(600);

/// Pushes the current branch, publishing it with an upstream when it has none.
pub fn push(cwd: &Path, fallback_branch: Option<&str>) -> Result<GitPushResult> {
    let status = status(cwd)?;
    let Some(branch) = status
        .branch
        .clone()
        .or_else(|| fallback_branch.map(str::to_owned))
    else {
        return fail("Cannot push from a detached HEAD.");
    };
    let remotes = remote_names(cwd);
    if status.ahead == 0
        && status.behind == 0
        && let Some(upstream) = &status.upstream
    {
        return Ok(GitPushResult {
            outcome: PushOutcome::UpToDate,
            branch,
            upstream: Some(upstream.clone()),
            set_upstream: false,
        });
    }
    let action = format!("Could not push “{branch}”.");
    let refspec = format!("HEAD:refs/heads/{branch}");
    let publish = |remote: &str| -> Result<GitPushResult> {
        checked(
            &action,
            cwd,
            &["push", "-u", "--", remote, &refspec],
            PUSH_TIMEOUT,
        )?;
        Ok(GitPushResult {
            outcome: PushOutcome::Pushed,
            branch: branch.clone(),
            upstream: Some(format!("{remote}/{branch}")),
            set_upstream: true,
        })
    };
    let Some(upstream) = status.upstream.clone() else {
        let Some(remote) = push_remote(cwd, &branch, &remotes) else {
            return fail("Cannot push because this repository has no remote.");
        };
        return publish(&remote);
    };
    let remote_name = remotes
        .iter()
        .filter(|remote| upstream.starts_with(&format!("{remote}/")))
        .max_by_key(|remote| remote.len())
        .cloned()
        .unwrap_or_else(|| upstream.split('/').next().unwrap_or("").to_owned());
    let upstream_branch = upstream
        .get(remote_name.len() + 1..)
        .unwrap_or("")
        .to_owned();
    if upstream_branch != branch {
        // A differently named upstream is the branch's base (a worktree started from
        // origin/main), not where its work belongs. Publish under its own name.
        let remote = push_remote(cwd, &branch, &remotes).unwrap_or(remote_name);
        let key = names::merge_base_config_key(&branch);
        if config_value(&key, cwd).is_none() {
            git(cwd, &["config", &key, &upstream], SHORT);
        }
        return publish(&remote);
    }
    checked(
        &action,
        cwd,
        &[
            "push",
            "--",
            &remote_name,
            &format!("HEAD:refs/heads/{upstream_branch}"),
        ],
        PUSH_TIMEOUT,
    )?;
    Ok(GitPushResult {
        outcome: PushOutcome::Pushed,
        branch,
        upstream: Some(upstream),
        set_upstream: false,
    })
}

pub fn pull(cwd: &Path) -> Result<PullResult> {
    let status = status(cwd)?;
    if status.branch.is_none() {
        return fail("Cannot pull into a detached HEAD.");
    }
    if !status.has_upstream() {
        return fail("This branch has no upstream yet. Push it first.");
    }
    let before = head_commit(cwd);
    checked(
        "Could not pull.",
        cwd,
        &["pull", "--ff-only"],
        Duration::from_secs(300),
    )?;
    let after = head_commit(cwd);
    Ok(if before.is_some() && before == after {
        PullResult::UpToDate
    } else {
        PullResult::Pulled
    })
}

/// One-line commits between `base` and HEAD, for the pull request text.
pub fn range_commits(cwd: &Path, base: &str) -> String {
    let output = git(
        cwd,
        &[
            "log",
            "--oneline",
            "--no-decorate",
            "--end-of-options",
            &format!("{base}..HEAD"),
        ],
        NORMAL,
    );
    output.stdout.chars().take(19_000).collect()
}

// MARK: Hosts and pull requests

/// The host of the remote `branch` tracks, else of `origin` (or the first remote).
pub fn remote_host(cwd: &Path, branch: Option<&str>) -> Option<Host> {
    let remotes = remote_names(cwd);
    let tracked = branch
        .and_then(|branch| config_value(&format!("branch.{branch}.remote"), cwd))
        .filter(|tracked| remotes.contains(tracked));
    let name = tracked.or_else(|| primary_remote(&remotes).map(str::to_owned))?;
    let url = value(cwd, &["remote", "get-url", "--", &name])?;
    Host::recognize_url(&url)
}

/// The branch a pull request should target: the recorded base, a differently named
/// upstream, the default branch as gh knows it, else as git does, then `main`.
pub fn pull_request_base(cwd: &Path, branch: &str, upstream: Option<&str>, use_gh: bool) -> String {
    let remotes = remote_names(cwd);
    let branch_name = |reference: &str| -> String {
        let mut name = reference;
        for prefix in ["refs/heads/", "refs/remotes/"] {
            name = name.strip_prefix(prefix).unwrap_or(name);
        }
        if let Some(remote) = remotes
            .iter()
            .filter(|remote| name.starts_with(&format!("{remote}/")))
            .max_by_key(|remote| remote.len())
        {
            name = &name[remote.len() + 1..];
        }
        name.to_owned()
    };
    if let Some(configured) = config_value(&names::merge_base_config_key(branch), cwd) {
        let name = branch_name(&configured);
        if !name.is_empty() && name != branch {
            return name;
        }
    }
    if let Some(upstream) = upstream {
        let name = branch_name(upstream);
        if !name.is_empty() && name != branch {
            return name;
        }
    }
    if use_gh && let Some(name) = gh_default_branch(cwd) {
        return name;
    }
    if let Some(remote) = primary_remote(&remotes)
        && let Some(name) = default_branch(cwd, remote)
    {
        return name;
    }
    "main".into()
}

pub const GH_NOT_READY: &str =
    "Install the GitHub CLI (gh) and run “gh auth login” to create pull requests.";
const PULL_REQUEST_FIELDS: &str = "number,url,title,state,baseRefName,headRefName,isDraft";

type Cache<T> = Mutex<HashMap<String, (Instant, T)>>;

fn cache<T>(cell: &'static OnceLock<Cache<T>>) -> &'static Cache<T> {
    cell.get_or_init(Default::default)
}

fn cache_key(cwd: &Path, extra: &str) -> String {
    format!("{}\0{extra}", cwd.to_string_lossy())
}

/// Whether gh is installed and signed in, cached for five minutes.
pub fn is_gh_ready(cwd: &Path) -> bool {
    static READY: OnceLock<Cache<bool>> = OnceLock::new();
    let key = cache_key(cwd, "");
    if let Some((at, ready)) = cache(&READY).lock().ok().and_then(|c| c.get(&key).cloned())
        && at.elapsed() < Duration::from_secs(300)
    {
        return ready;
    }
    let ready =
        cli::gh(cwd, &["auth", "status"], Duration::from_secs(20)).is_some_and(|o| o.success);
    if let Ok(mut cache) = cache(&READY).lock() {
        cache.insert(key, (Instant::now(), ready));
    }
    ready
}

static PULL_REQUESTS: OnceLock<Cache<Option<GitPullRequest>>> = OnceLock::new();

/// Forgets cached pull requests after a push or a new pull request.
pub fn forget_pull_requests() {
    if let Ok(mut cache) = cache(&PULL_REQUESTS).lock() {
        cache.clear();
    }
}

fn remember_pull_request(cwd: &Path, branch: &str, pull_request: Option<GitPullRequest>) {
    if let Ok(mut cache) = cache(&PULL_REQUESTS).lock() {
        cache.insert(cache_key(cwd, branch), (Instant::now(), pull_request));
    }
}

fn gh_pull_request_for(branch: &str, cwd: &Path) -> Option<GitPullRequest> {
    let output = cli::gh(
        cwd,
        &[
            "pr",
            "list",
            "--head",
            branch,
            "--state",
            "open",
            "--limit",
            "1",
            "--json",
            PULL_REQUEST_FIELDS,
        ],
        Duration::from_secs(60),
    )?;
    if !output.success {
        return None;
    }
    serde_json::from_str::<Vec<GitPullRequest>>(&output.stdout)
        .ok()?
        .into_iter()
        .next()
}

/// The open pull request for `branch`, cached for a minute. Only gh is asked (GitHub
/// and hosts no name identifies); None without a signed-in gh.
pub fn open_pull_request(branch: &str, cwd: &Path, refresh: bool) -> Option<GitPullRequest> {
    let key = cache_key(cwd, branch);
    if !refresh
        && let Some((at, cached)) = cache(&PULL_REQUESTS)
            .lock()
            .ok()
            .and_then(|c| c.get(&key).cloned())
        && at.elapsed() < Duration::from_secs(60)
    {
        return cached;
    }
    let host = remote_host(cwd, Some(branch));
    if !uses_gh(host.as_ref()) || !is_gh_ready(cwd) {
        return None;
    }
    let found = gh_pull_request_for(branch, cwd);
    remember_pull_request(cwd, branch, found.clone());
    found
}

/// gh serves GitHub and hosts Coincide can't name. The other hosts' CLIs (glab, az,
/// tea) are not used here; their pull requests are finished on the host's page.
pub fn uses_gh(host: Option<&Host>) -> bool {
    host.is_none_or(|host| {
        matches!(
            host.kind,
            super::host::Kind::Github | super::host::Kind::Unknown
        )
    })
}

fn gh_default_branch(cwd: &Path) -> Option<String> {
    let output = cli::gh(
        cwd,
        &[
            "repo",
            "view",
            "--json",
            "defaultBranchRef",
            "--jq",
            ".defaultBranchRef.name",
        ],
        Duration::from_secs(20),
    )?;
    let name = output.stdout.trim();
    (output.success && !name.is_empty()).then(|| name.to_owned())
}

pub fn create_pull_request(
    title: &str,
    body: &str,
    base: &str,
    head: &str,
    cwd: &Path,
) -> Result<GitPullRequest> {
    if cli::gh_executable().is_none() {
        return fail(GH_NOT_READY);
    }
    let body_file = tempfile_path("coincide-pr-body");
    let _cleanup = RemoveOnDrop(body_file.clone());
    std::fs::write(&body_file, body)?;
    let body_path = body_file.to_string_lossy().into_owned();
    let Some(output) = cli::gh(
        cwd,
        &[
            "pr",
            "create",
            "--base",
            base,
            "--head",
            head,
            "--title",
            title,
            "--body-file",
            &body_path,
        ],
        Duration::from_secs(120),
    ) else {
        return fail(GH_NOT_READY);
    };
    if !output.success {
        return Err(GitError::failed("Could not create the pull request.", &output).into());
    }
    forget_pull_requests();
    let url = output
        .stdout
        .lines()
        .rev()
        .find(|line| line.starts_with("http"))
        .map(str::to_owned);
    let created = url
        .as_deref()
        .and_then(|url| {
            let output = cli::gh(
                cwd,
                &["pr", "view", url, "--json", PULL_REQUEST_FIELDS],
                Duration::from_secs(60),
            )?;
            output
                .success
                .then(|| serde_json::from_str::<GitPullRequest>(&output.stdout).ok())
                .flatten()
        })
        .or_else(|| gh_pull_request_for(head, cwd))
        .unwrap_or_else(|| GitPullRequest {
            number: url
                .as_deref()
                .and_then(|url| url.rsplit('/').next()?.parse().ok())
                .unwrap_or(0),
            url: url.clone().unwrap_or_default(),
            title: title.into(),
            state: "OPEN".into(),
            base_branch: base.into(),
            head_branch: head.into(),
            is_draft: false,
        });
    remember_pull_request(cwd, head, Some(created.clone()));
    Ok(created)
}
