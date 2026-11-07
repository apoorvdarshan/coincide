//! Working-tree snapshots taken around each turn, so a turn's changes can be
//! listed, diffed and reverted. Ported from Swift's CheckpointService (itself
//! T3 Code's GitVcsDriver checkpoints): each snapshot is a commit built in a
//! scratch index, so the user's index, branches and stash are never touched,
//! with HEAD as its parent, kept alive by a hidden ref under
//! refs/coincide/checkpoints/<thread>/<turn>/. Capture and diff never change
//! files; restore is the only writer and runs only after the user confirms.
use crate::workspace::{GitOutput, GitRequest, git_output};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap};
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FileStatus {
    Added,
    Modified,
    Deleted,
    Renamed,
    Untracked,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangedFile {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub old_path: Option<String>,
    pub status: FileStatus,
    #[serde(default)]
    pub additions: u64,
    #[serde(default)]
    pub deletions: u64,
}

/// The snapshots taken around one turn. Times are Swift reference seconds.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnCheckpoint {
    #[serde(rename = "userItemID")]
    pub user_item_id: String,
    /// Folder the snapshots cover: the thread's worktree or project folder.
    pub cwd: String,
    /// Snapshot commit taken before the turn ran.
    #[serde(default)]
    pub before: Option<String>,
    #[serde(default)]
    pub before_at: Option<f64>,
    /// Snapshot commit taken when the turn ended.
    #[serde(default)]
    pub after: Option<String>,
    #[serde(default)]
    pub after_at: Option<f64>,
    /// What the turn changed, once both snapshots exist.
    #[serde(default)]
    pub files: Vec<ChangedFile>,
}
impl TurnCheckpoint {
    pub fn is_complete(&self) -> bool {
        self.before.is_some() && self.after.is_some()
    }
}

/// Reads a Swift checkpoint index (`checkpoints/<thread>.json`, ISO 8601
/// dates). Dates are dropped: they only gate restores, which imported
/// conversations never offer. Malformed entries are skipped, not guessed.
pub fn parse_swift_index(bytes: &[u8]) -> Vec<TurnCheckpoint> {
    let Ok(serde_json::Value::Array(entries)) = serde_json::from_slice(bytes) else {
        return Vec::new();
    };
    entries
        .into_iter()
        .filter_map(|mut entry| {
            let fields = entry.as_object_mut()?;
            fields.remove("beforeAt");
            fields.remove("afterAt");
            serde_json::from_value(entry).ok()
        })
        .collect()
}

pub fn reference(thread_id: &str, user_item_id: &str, phase: &str) -> Result<String> {
    ensure!(
        matches!(phase, "before" | "after"),
        "Invalid checkpoint phase"
    );
    let thread = Uuid::parse_str(thread_id).context("Invalid thread ID")?;
    let item = Uuid::parse_str(user_item_id).context("Invalid transcript item ID")?;
    Ok(format!(
        "refs/coincide/checkpoints/{}/{}/{phase}",
        thread.hyphenated(),
        item.hyphenated()
    ))
}

fn validate_object(oid: &str) -> Result<()> {
    ensure!(
        matches!(oid.len(), 40 | 64) && oid.bytes().all(|b| b.is_ascii_hexdigit()),
        "Git returned an invalid object ID"
    );
    Ok(())
}

// MARK: Git

const TIMEOUT: Duration = Duration::from_secs(300);
const AUTHOR: [(&str, &str); 4] = [
    ("GIT_AUTHOR_NAME", "Coincide"),
    ("GIT_AUTHOR_EMAIL", "coincide@users.noreply.github.com"),
    ("GIT_COMMITTER_NAME", "Coincide"),
    ("GIT_COMMITTER_EMAIL", "coincide@users.noreply.github.com"),
];
/// A scratch split index could expire shared index files the real index uses.
const INDEX_CONFIG: [&str; 8] = [
    "-c",
    "core.fsmonitor=false",
    "-c",
    "sparse.expectFilesOutsideOfPatterns=false",
    "-c",
    "core.splitIndex=false",
    "-c",
    "splitIndex.sharedIndexExpire=never",
];
const FULL_FSYNC: &str = "core.fsyncMethod=fsync";
const BATCH_FSYNC: &str = "core.fsyncMethod=batch";
const WRITEOUT_FSYNC: &str = "core.fsyncMethod=writeout-only";
/// Flush objects and refs before publishing them, so a crash cannot leave empty
/// refs. fsync is set first because Git versions without batch ignore it.
const DURABLE: [&str; 6] = [
    "-c",
    "core.fsync=objects,reference",
    "-c",
    FULL_FSYNC,
    "-c",
    BATCH_FSYNC,
];
const MAX_PATCH: usize = 8 * 1024 * 1024;

struct Git<'a> {
    cwd: &'a Path,
    env: Vec<(&'static str, std::ffi::OsString)>,
}
impl<'a> Git<'a> {
    fn new(cwd: &'a Path) -> Self {
        Self {
            cwd,
            env: Vec::new(),
        }
    }
    fn with_index(cwd: &'a Path, index: &Path) -> Self {
        let mut env = AUTHOR
            .iter()
            .map(|(name, value)| (*name, std::ffi::OsString::from(value)))
            .collect::<Vec<_>>();
        env.push(("GIT_INDEX_FILE", index.as_os_str().to_owned()));
        Self { cwd, env }
    }
    fn raw(&self, arguments: &[&str], input: Option<&[u8]>, max: usize) -> Result<GitOutput> {
        let env = self
            .env
            .iter()
            .map(|(name, value)| (*name, value.as_os_str()))
            .collect::<Vec<(&str, &OsStr)>>();
        git_output(
            self.cwd,
            arguments,
            &GitRequest {
                env: &env,
                input,
                timeout: TIMEOUT,
                max_output: max,
                literal_pathspecs: false,
                ..Default::default()
            },
        )
    }
    /// One checkpoint step. Lock races are retried twice; volumes that reject
    /// full fsync are retried with writeout-only syncing.
    fn run(&self, arguments: &[&str], input: Option<&[u8]>) -> Result<GitOutput> {
        let mut arguments = arguments.to_vec();
        let mut result = self.raw(&arguments, input, 64 * 1024 * 1024)?;
        let mut retries = 0;
        while !result.success {
            let stderr = String::from_utf8_lossy(&result.stderr).to_lowercase();
            if arguments
                .iter()
                .any(|argument| *argument == FULL_FSYNC || *argument == BATCH_FSYNC)
                && fsync_unsupported(&stderr)
            {
                for argument in &mut arguments {
                    if *argument == FULL_FSYNC || *argument == BATCH_FSYNC {
                        *argument = WRITEOUT_FSYNC;
                    }
                }
            } else if retries < 2 && transient(&stderr) {
                retries += 1;
                std::thread::sleep(Duration::from_millis(75));
            } else {
                break;
            }
            result = self.raw(&arguments, input, 64 * 1024 * 1024)?;
        }
        Ok(result)
    }
    fn checked(&self, arguments: &[&str], input: Option<&[u8]>, failure: &str) -> Result<String> {
        let result = self.run(arguments, input)?;
        ensure!(
            result.success && !result.overflowed,
            "{failure} {}",
            result.stderr_text().trim()
        );
        Ok(String::from_utf8_lossy(&result.stdout).into_owned())
    }
    fn succeeds(&self, arguments: &[&str]) -> bool {
        self.raw(arguments, None, 1024 * 1024)
            .is_ok_and(|output| output.success)
    }
    fn text(&self, arguments: &[&str]) -> Option<String> {
        self.raw(arguments, None, 1024 * 1024)
            .ok()
            .filter(|output| output.success && !output.overflowed)
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
    }
}

fn transient(stderr: &str) -> bool {
    (stderr.contains("unable to create")
        && stderr.contains(".lock")
        && stderr.contains("file exists"))
        || ((stderr.contains("unable to stat")
            || stderr.contains("lstat(")
            || stderr.contains("error: open("))
            && stderr.contains("no such file or directory"))
}

fn fsync_unsupported(stderr: &str) -> bool {
    (stderr.contains("fsync error on") && stderr.contains("operation not supported"))
        || (stderr.contains("cannot update ref")
            && stderr.contains("couldn't write")
            && stderr.contains(".lock"))
}

/// Git work for one folder runs one capture or restore at a time, in call
/// order, across every engine worker in this process.
fn folder_lock(cwd: &Path) -> Arc<Mutex<()>> {
    static LOCKS: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>> = OnceLock::new();
    let key = cwd.canonicalize().unwrap_or_else(|_| cwd.to_path_buf());
    let mut locks = LOCKS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    locks.retain(|_, lock| Arc::strong_count(lock) > 1);
    locks.entry(key).or_default().clone()
}

struct ScratchIndex(PathBuf);
impl ScratchIndex {
    fn clear(&self) {
        let _ = std::fs::remove_file(&self.0);
        let mut lock = self.0.clone().into_os_string();
        lock.push(".lock");
        let _ = std::fs::remove_file(PathBuf::from(lock));
    }
}
impl Drop for ScratchIndex {
    fn drop(&mut self) {
        self.clear();
    }
}

const SAVE_FAILURE: &str = "Could not save a checkpoint.";

/// Snapshots the folder's working tree (tracked and untracked files, minus
/// ignored ones) into a commit `reference` points to. With no reference, only
/// the tree is written and nothing is recorded.
pub fn capture(cwd: &Path, reference: Option<&str>) -> Result<String> {
    let lock = folder_lock(cwd);
    let _serialized = lock.lock().unwrap_or_else(|error| error.into_inner());
    capture_unserialized(cwd, reference)
}

fn capture_unserialized(cwd: &Path, reference: Option<&str>) -> Result<String> {
    let plain = Git::new(cwd);
    // Absolute, so a relative answer never meets a verbatim Windows path.
    let common = PathBuf::from(
        plain
            .text(&["rev-parse", "--path-format=absolute", "--git-common-dir"])
            .filter(|common| Path::new(common).is_absolute())
            .context("The folder is not in a Git repository")?,
    );
    let index = ScratchIndex(common.join(format!(
        "coincide-checkpoint-index-{}",
        Uuid::new_v4().hyphenated()
    )));
    let git = Git::with_index(cwd, &index.0);
    let head_exists = plain.succeeds(&["rev-parse", "--verify", "--quiet", "HEAD"]);
    if plain
        .text(&["config", "--bool", "core.sparseCheckout"])
        .as_deref()
        == Some("true")
    {
        // Rebuilding a sparse index can record false deletions; never guess.
        bail!("{SAVE_FAILURE} Sparse checkouts are not snapshotted.");
    }
    if head_exists && !seed_index(&plain, &git, &index.0) {
        index.clear();
        let mut arguments = INDEX_CONFIG.to_vec();
        arguments.extend(["read-tree", "HEAD"]);
        git.checked(&arguments, None, SAVE_FAILURE)?;
    }
    let ignored = folder_ignored(&plain);
    if ignored {
        let mut arguments = INDEX_CONFIG.to_vec();
        arguments.extend(["ls-files", "--cached", "-z", "--", "."]);
        let tracked = git.checked(&arguments, None, SAVE_FAILURE)?;
        ensure!(
            !tracked.is_empty(),
            "{SAVE_FAILURE} The folder is ignored by its Git repository."
        );
    }
    let stage = |exclusions: &[String]| {
        let mut arguments = INDEX_CONFIG.to_vec();
        arguments.extend(DURABLE);
        // add -A rejects ignored folders even when they contain tracked files.
        arguments.extend(["add", if ignored { "-u" } else { "-A" }, "--", "."]);
        arguments.extend(exclusions.iter().map(String::as_str));
        git.run(&arguments, None)
    };
    let mut staged = stage(&[])?;
    if !staged.success {
        // Git cannot stage nested repositories without a commit; look for them
        // only after staging fails.
        let untracked = git.checked(
            &[
                "ls-files",
                "--others",
                "--exclude-standard",
                "-z",
                "--",
                ".",
            ],
            None,
            SAVE_FAILURE,
        )?;
        let candidates = untracked
            .split('\0')
            .filter(|entry| entry.ends_with('/'))
            .collect::<Vec<_>>();
        let mut exclusions = Vec::new();
        if candidates.len() <= 1000 {
            for entry in candidates {
                let nested = cwd.join(entry);
                if nested.join(".git").exists()
                    && !Git::new(&nested).succeeds(&["rev-parse", "--verify", "--quiet", "HEAD"])
                {
                    exclusions.push(format!(":(exclude,literal){entry}"));
                }
            }
        }
        if !exclusions.is_empty() {
            staged = stage(&exclusions)?;
        }
        ensure!(
            staged.success,
            "{SAVE_FAILURE} {}",
            staged.stderr_text().trim()
        );
    }
    let mut arguments = INDEX_CONFIG.to_vec();
    arguments.extend(DURABLE);
    arguments.push("write-tree");
    let tree = git
        .checked(&arguments, None, SAVE_FAILURE)?
        .trim()
        .to_owned();
    validate_object(&tree)?;
    let Some(reference) = reference else {
        return Ok(tree);
    };
    // HEAD is the parent so a later diff can tell how HEAD moved between
    // snapshots. Snapshots never leave the machine, so they are not signed.
    let message = format!("coincide checkpoint ref={reference}");
    let mut arguments = DURABLE.to_vec();
    arguments.extend(["commit-tree", "--no-gpg-sign", tree.as_str()]);
    if head_exists {
        arguments.extend(["-p", "HEAD"]);
    }
    arguments.extend(["-m", message.as_str()]);
    let commit = git
        .checked(&arguments, None, SAVE_FAILURE)?
        .trim()
        .to_owned();
    validate_object(&commit)?;
    let mut arguments = DURABLE.to_vec();
    arguments.extend(["update-ref", reference, commit.as_str()]);
    plain.checked(&arguments, None, SAVE_FAILURE)?;
    Ok(commit)
}

/// Starts the scratch index from a copy of the real one, so `git add` reuses
/// its stat cache instead of hashing every file. False when the copy cannot be
/// used and the caller should build a fresh index from HEAD.
fn seed_index(plain: &Git<'_>, git: &Git<'_>, index: &Path) -> bool {
    let Some(real) = plain.text(&["rev-parse", "--path-format=absolute", "--git-path", "index"])
    else {
        return false;
    };
    let Ok(modified) = std::fs::metadata(&real).and_then(|metadata| metadata.modified()) else {
        return false;
    };
    // Stay below the source timestamp, preserving Git's racy-clean check.
    let Some(stamp) = modified
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|since| since.as_secs_f64() - 0.001)
        .filter(|seconds| *seconds > 1.0)
        .map(|seconds| std::time::UNIX_EPOCH + Duration::from_secs(seconds.floor() as u64))
    else {
        return false;
    };
    if std::fs::copy(&real, index).is_err() {
        return false;
    }
    let mut arguments = INDEX_CONFIG.to_vec();
    arguments.extend(["read-tree", "--reset", "HEAD"]);
    if !git.run(&arguments, None).is_ok_and(|output| output.success) {
        return false;
    }
    // read-tree can rewrite the index, so restore its racy timestamp.
    if std::fs::File::options()
        .write(true)
        .open(index)
        .and_then(|file| file.set_modified(stamp))
        .is_err()
    {
        return false;
    }
    // Assume-unchanged (lowercase tags) and skip-worktree entries need a fresh
    // index; their working files may not match what the index says.
    let mut arguments = INDEX_CONFIG.to_vec();
    arguments.extend(["ls-files", "--full-name", "-v", "-z"]);
    let Ok(listing) = git.raw(&arguments, None, 256 * 1024 * 1024) else {
        return false;
    };
    if !listing.success || listing.overflowed {
        return false;
    }
    !listing.stdout.split(|byte| *byte == 0).any(|record| {
        record
            .first()
            .is_some_and(|tag| tag.is_ascii_lowercase() || *tag == b'S')
    })
}

/// Whether the folder itself is ignored by its repository (a tracked folder
/// inside an ignored one).
fn folder_ignored(plain: &Git<'_>) -> bool {
    if plain
        .text(&["rev-parse", "--show-prefix"])
        .is_none_or(|prefix| prefix.is_empty())
    {
        return false;
    }
    plain
        .raw(
            &["check-ignore", "--no-index", "-z", "--stdin"],
            Some(b".\0"),
            1024,
        )
        .is_ok_and(|output| {
            output.code == Some(0) && output.stdout.split(|byte| *byte == 0).any(|f| f == b".")
        })
}

const RESTORE_FAILURE: &str = "Could not restore the checkpoint.";

/// Restores the folder to `commit`: tracked files are reset, files the snapshot
/// did not have are removed (ignored files stay), and the index is reset to
/// HEAD for the folder.
pub fn restore(cwd: &Path, commit: &str) -> Result<()> {
    validate_object(commit)?;
    let lock = folder_lock(cwd);
    let _serialized = lock.lock().unwrap_or_else(|error| error.into_inner());
    let git = Git::new(cwd);
    let with_tree = format!("--with-tree={commit}");
    let tracked = git.checked(
        &["ls-files", "--cached", &with_tree, "-z", "--", "."],
        None,
        RESTORE_FAILURE,
    )?;
    // With an empty index and snapshot, `git restore` has nothing to match.
    if !tracked.is_empty() {
        git.checked(
            &[
                "restore",
                "--source",
                commit,
                "--worktree",
                "--staged",
                "--",
                ".",
            ],
            None,
            RESTORE_FAILURE,
        )?;
    }
    // Restoring away the last tracked file can remove a nested folder.
    let _ = std::fs::create_dir_all(cwd);
    let cleaned = git.run(&["clean", "-fd", "--", "."], None)?;
    if !cleaned.success {
        // Git can remove every child, then fail trying to remove './' itself.
        let stderr = String::from_utf8_lossy(&cleaned.stderr);
        let emptied = cleaned.code == Some(1)
            && stderr.trim().starts_with("warning: failed to remove ./:")
            && !stderr.trim().contains('\n')
            && std::fs::read_dir(cwd).is_ok_and(|mut entries| entries.next().is_none());
        ensure!(
            emptied,
            "{RESTORE_FAILURE} {}",
            cleaned.stderr_text().trim()
        );
    }
    let _ = std::fs::create_dir_all(cwd);
    if git.succeeds(&["rev-parse", "--verify", "--quiet", "HEAD"]) {
        git.checked(&["reset", "--quiet", "--", "."], None, RESTORE_FAILURE)?;
    }
    Ok(())
}

fn diff_arguments<'a>(numstat: bool, from: &'a str, to: &'a str) -> Vec<&'a str> {
    let mut arguments = vec![
        "-c",
        "core.quotePath=false",
        "diff",
        "--find-renames",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--src-prefix=a/",
        "--dst-prefix=b/",
    ];
    arguments.extend(if numstat {
        ["--numstat", "-z"].as_slice()
    } else {
        ["--patch"].as_slice()
    });
    arguments.extend([from, to, "--"]);
    arguments
}

pub struct Patch {
    pub text: String,
    /// The patch passed 8 MiB and was cut at the last whole file before it.
    pub truncated: bool,
}

/// Patch between two snapshots, limited to this folder or to repository
/// relative `paths`.
pub fn diff(cwd: &Path, from: &str, to: &str, paths: Option<&[String]>) -> Result<Patch> {
    validate_object(from)?;
    validate_object(to)?;
    let pathspecs = match paths {
        Some(paths) => paths
            .iter()
            .map(|path| format!(":(top,literal){path}"))
            .collect(),
        None => vec![".".to_owned()],
    };
    let mut arguments = diff_arguments(false, from, to);
    arguments.extend(pathspecs.iter().map(String::as_str));
    let output = Git::new(cwd).raw(&arguments, None, MAX_PATCH)?;
    ensure!(
        output.success,
        "Could not read the turn's changes. {}",
        output.stderr_text().trim()
    );
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    if output.overflowed {
        let mut end = MAX_PATCH.min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        let cut = text[..end]
            .rfind("\ndiff --git ")
            .map_or(0, |index| index + 1);
        text.truncate(cut);
    }
    Ok(Patch {
        text,
        truncated: output.overflowed,
    })
}

struct Numstat {
    path: String,
    old_path: Option<String>,
    additions: u64,
    deletions: u64,
}

fn parse_numstat(output: &str) -> Vec<Numstat> {
    let fields = output.split('\0').collect::<Vec<_>>();
    let mut result = Vec::new();
    let mut index = 0;
    while index < fields.len() {
        let field = fields[index];
        index += 1;
        let parts = field.splitn(3, '\t').collect::<Vec<_>>();
        if parts.len() != 3 {
            continue;
        }
        let mut path = parts[2].to_owned();
        let mut old_path = None;
        if path.is_empty() {
            if index + 1 >= fields.len() {
                break;
            }
            old_path = Some(fields[index].to_owned());
            path = fields[index + 1].to_owned();
            index += 2;
        }
        if path.is_empty() {
            continue;
        }
        result.push(Numstat {
            path,
            old_path,
            additions: parts[0].parse().unwrap_or(0),
            deletions: parts[1].parse().unwrap_or(0),
        });
    }
    result
}

fn parse_name_status(output: &str) -> HashMap<String, FileStatus> {
    let fields = output.split('\0').collect::<Vec<_>>();
    let mut statuses = HashMap::new();
    let mut index = 0;
    while index < fields.len() {
        let code = fields[index].chars().next().unwrap_or('M');
        if matches!(code, 'R' | 'C') && index + 2 < fields.len() {
            statuses.insert(
                fields[index + 2].to_owned(),
                if code == 'R' {
                    FileStatus::Renamed
                } else {
                    FileStatus::Added
                },
            );
            index += 3;
        } else if index + 1 < fields.len() {
            statuses.insert(
                fields[index + 1].to_owned(),
                match code {
                    'A' => FileStatus::Added,
                    'D' => FileStatus::Deleted,
                    _ => FileStatus::Modified,
                },
            );
            index += 2;
        } else {
            break;
        }
    }
    statuses
}

/// What changed between two snapshots, leaving out files that only came from
/// Git itself (a pull, merge or rebase that moved HEAD during the turn).
pub fn changed_files(cwd: &Path, from: &str, to: &str) -> Result<Vec<ChangedFile>> {
    validate_object(from)?;
    validate_object(to)?;
    let git = Git::new(cwd);
    let mut arguments = diff_arguments(true, from, to);
    arguments.push(".");
    let numstat = git.checked(&arguments, None, "Could not read the turn's changes.")?;
    let statuses = git
        .text(&[
            "diff",
            "--name-status",
            "-z",
            "--find-renames",
            "--no-ext-diff",
            from,
            to,
            "--",
            ".",
        ])
        .map(|output| parse_name_status(&output))
        .unwrap_or_default();
    let authored = authored_paths(&git, from, to);
    let mut files = parse_numstat(&numstat)
        .into_iter()
        .filter(|stat| {
            authored.as_ref().is_none_or(|authored| {
                authored.contains(&stat.path)
                    || stat
                        .old_path
                        .as_ref()
                        .is_some_and(|old| authored.contains(old))
            })
        })
        .map(|stat| ChangedFile {
            status: statuses
                .get(&stat.path)
                .copied()
                .unwrap_or(FileStatus::Modified),
            path: stat.path,
            old_path: stat.old_path,
            additions: stat.additions,
            deletions: stat.deletions,
        })
        .collect::<Vec<_>>();
    files.sort_by(|a, b| natural_order(&a.path, &b.path));
    Ok(files)
}

/// Finder-like order: case-insensitive, with digit runs compared by value.
pub fn natural_order(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let (mut left, mut right) = (a.chars().peekable(), b.chars().peekable());
    let number = |chars: &mut std::iter::Peekable<std::str::Chars<'_>>| {
        let mut digits = String::new();
        while let Some(digit) = chars.peek().copied().filter(char::is_ascii_digit) {
            digits.push(digit);
            chars.next();
        }
        digits
    };
    loop {
        match (left.peek().copied(), right.peek().copied()) {
            (None, None) => return a.cmp(b),
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let (x, y) = (number(&mut left), number(&mut right));
                let (x, y) = (x.trim_start_matches('0'), y.trim_start_matches('0'));
                let order = x.len().cmp(&y.len()).then_with(|| x.cmp(y));
                if order.is_ne() {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                let order = x.to_lowercase().cmp(y.to_lowercase());
                if order.is_ne() {
                    return order;
                }
                left.next();
                right.next();
            }
        }
    }
}

/// Paths the turn itself could have written, or None when HEAD did not move
/// (then every changed path belongs to the turn).
fn authored_paths(git: &Git<'_>, from: &str, to: &str) -> Option<BTreeSet<String>> {
    let from_commit = format!("{from}^{{commit}}");
    let to_commit = format!("{to}^{{commit}}");
    let heads = git.text(&[
        "log",
        "--no-walk=unsorted",
        "--format=%P %ct",
        &from_commit,
        &to_commit,
    ])?;
    let mut lines = heads.lines();
    let mut start = lines.next()?.split(' ');
    let start_head = start.next().unwrap_or_default().to_owned();
    let captured_at = start.next().unwrap_or_default().to_owned();
    let end_head = lines
        .next()?
        .split(' ')
        .next()
        .unwrap_or_default()
        .to_owned();
    if start_head.is_empty() || end_head.is_empty() || start_head == end_head {
        return None;
    }
    let list = |arguments: &[&str]| -> Option<Vec<String>> {
        let mut arguments = arguments.to_vec();
        arguments.extend(["--name-only", "-z", "--no-renames", "--no-ext-diff"]);
        let output = git.raw(&arguments, None, 64 * 1024 * 1024).ok()?;
        (output.success && !output.overflowed).then(|| {
            String::from_utf8_lossy(&output.stdout)
                .split('\0')
                .filter(|path| !path.is_empty())
                .map(str::to_owned)
                .collect()
        })
    };
    let since = format!("--since=@{captured_at}");
    let rewound = format!("{end_head}..{start_head}");
    let committed = format!("{start_head}..{end_head}");
    // Remerge diffs keep conflict fixes while leaving out clean upstream changes.
    let mut paths = BTreeSet::new();
    paths.extend(list(&["diff", &start_head, &from_commit])?);
    paths.extend(list(&["diff", &end_head, &to_commit])?);
    paths.extend(list(&[
        "log",
        "--format=",
        "--diff-merges=remerge",
        &rewound,
    ])?);
    paths.extend(list(&[
        "log",
        "--format=",
        "--diff-merges=remerge",
        &since,
        &committed,
    ])?);
    Some(paths)
}

/// Removes snapshot refs. Missing folders and refs are ignored.
pub fn delete_refs(cwd: &Path, references: &[String]) {
    if references.is_empty() || !cwd.is_dir() {
        return;
    }
    let input = references
        .iter()
        .map(|reference| format!("delete {reference}\n"))
        .collect::<String>();
    let lock = folder_lock(cwd);
    let _serialized = lock.lock().unwrap_or_else(|error| error.into_inner());
    let _ = Git::new(cwd).raw(
        &["update-ref", "--stdin"],
        Some(input.as_bytes()),
        1024 * 1024,
    );
}

/// Whether `path` is `folder` or inside it, after resolving links.
pub fn contains(folder: &Path, path: &Path) -> bool {
    let resolve = |path: &Path| path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    resolve(path).starts_with(resolve(folder))
}

/// A bot working across the home folder is not snapshotted: a checkpoint would
/// copy all of it into Git.
pub fn broad_folder(path: &Path) -> bool {
    let path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .map(|home| home.canonicalize().unwrap_or(home));
    path.parent().is_none()
        || home.is_some_and(|home| path == home)
        || path == Path::new("/Users")
        || path == Path::new("/home")
}

#[cfg(test)]
#[path = "turn_checkpoints_tests.rs"]
mod tests;
