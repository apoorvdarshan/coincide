//! Native-only PR checkout staging. No dispatcher route or serialized authority.
//! This first boundary validates a source, plans fixed isolated Git operations,
//! and materializes verified regular blobs. It does NOT fetch, import objects,
//! mutate source refs, populate a linked worktree or admit a new conversation.
use crate::{
    agent::native_instruction_git::StoreSource,
    native_file::{self, Identity},
};
use anyhow::{Context, Result, ensure};
use serde_json::Value;
use std::{
    collections::{BTreeMap, HashSet},
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};
#[path = "github_checkout_fs.rs"]
mod filesystem;
#[cfg(test)]
#[path = "github_checkout_tests.rs"]
mod tests;
const MAX_FILES: usize = 10_000;
const MAX_TREE: usize = 4 * 1024 * 1024;
const MAX_BLOB: usize = 4 * 1024 * 1024;
const MAX_TOTAL: u64 = 128 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(120);
/// Native Engine capture only. Entire stored source documents are retained for
/// exact later CAS, including all unknown fields; this is not JSON authority.
pub struct Source {
    pub(crate) store: StoreSource,
    pub(crate) thread: Value,
    pub(crate) project: Value,
    pub(crate) root: PathBuf,
    pub(crate) storage: PathBuf,
    pub(crate) repository: String,
    pub(crate) number: u64,
    pub(crate) head: String,
}
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
fn small_file(path: &Path) -> Result<String> {
    let mut value = String::new();
    native_file::open_regular(path, false)?
        .take(8193)
        .read_to_string(&mut value)?;
    ensure!(
        value.len() <= 8192 && !value.contains('\0'),
        "Invalid Git directory metadata"
    );
    Ok(value)
}
fn git_layout(root: &Path) -> Result<(PathBuf, PathBuf)> {
    let dot = root.join(".git");
    let metadata = fs::symlink_metadata(&dot)?;
    ensure!(
        !metadata.file_type().is_symlink(),
        "Git directory cannot be a symbolic link"
    );
    let git = if metadata.is_dir() {
        dot.canonicalize()?
    } else {
        let file = small_file(&dot)?;
        let value = file
            .strip_prefix("gitdir: ")
            .context("Invalid linked Git directory")?
            .trim_end_matches(['\r', '\n']);
        ensure!(
            !value.is_empty() && !value.chars().any(char::is_control),
            "Invalid Git directory"
        );
        root.join(value).canonicalize()?
    };
    let common = git.join("commondir");
    match fs::symlink_metadata(&common) {
        Ok(_) => {
            let value = small_file(&common)?;
            let value = value.trim_end_matches(['\r', '\n']);
            ensure!(
                !value.is_empty() && !value.chars().any(char::is_control),
                "Invalid common Git directory"
            );
            let common = git.join(value).canonicalize()?;
            Ok((git, common))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok((git.clone(), git)),
        Err(error) => Err(error.into()),
    }
}
/// Closed operation enum; all variable arguments have strict syntax. Network is
/// described, not executed: incoming pack/closure ownership still needs its own
/// reviewed adapter. No command accepts an arbitrary URL, ref, flag or cwd.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Operation {
    Initialize,
    FetchPull,
    VerifyHead,
    Tree,
    Blob(String),
}
pub struct Invocation {
    arguments: Vec<String>,
    network: bool,
    directory: PathBuf,
    environment: Vec<(String, std::ffi::OsString)>,
}
impl Invocation {
    pub fn arguments(&self) -> &[String] {
        &self.arguments
    }
    pub fn network(&self) -> bool {
        self.network
    }
    pub fn directory(&self) -> &Path {
        &self.directory
    }
    /// The future runner MUST env_clear(), then install only this captured
    /// non-secret environment plus required native loader/OS necessities.
    pub fn environment(&self) -> &[(String, std::ffi::OsString)] {
        &self.environment
    }
}
/// Captured native paths only. No credential values are read or retained here.
/// A future live runner must validate these identities and bound the incoming
/// pack DURING transfer, then prove actual child/descendant return before import.
pub struct Tools {
    git: filesystem::PinnedFile,
    gh: filesystem::PinnedFile,
    home: filesystem::Directory,
    gh_config: filesystem::Directory,
}
impl Tools {
    pub fn capture(git: &Path, gh: &Path, home: &Path, gh_config: &Path) -> Result<Self> {
        ensure!(
            home.is_absolute() && gh_config.is_absolute() && home.is_dir() && gh_config.is_dir(),
            "Native credential configuration is unavailable"
        );
        Ok(Self {
            git: filesystem::PinnedFile::open(git)?,
            gh: filesystem::PinnedFile::open(gh)?,
            home: filesystem::Directory::pin(&home.canonicalize()?)?,
            gh_config: filesystem::Directory::pin(&gh_config.canonicalize()?)?,
        })
    }
    pub fn validate(&self) -> Result<()> {
        self.git.check()?;
        self.gh.check()?;
        self.home.check()?;
        self.gh_config.check()?;
        Ok(())
    }
    pub fn git_executable(&self) -> &Path {
        &self.git.path
    }
    pub fn home(&self) -> &Path {
        &self.home.path
    }
    pub fn gh_config(&self) -> &Path {
        &self.gh_config.path
    }
}
fn shell_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}
pub struct Plan {
    source: Source,
    root: filesystem::Directory,
    common: filesystem::Directory,
    git: filesystem::Directory,
    storage: filesystem::Directory,
    nonce: uuid::Uuid,
    branch: String,
}
pub struct Review {
    pub repository: String,
    pub number: u64,
    pub expected_head: String,
    pub branch: String,
    pub destination: PathBuf,
    pub notice: &'static str,
}
impl Plan {
    /// Run off the UI/Engine lock. Preparation only pins existing paths; it does
    /// not create a destination, run Git or query credentials.
    pub fn prepare(source: Source) -> Result<Self> {
        validate_repository(&source.repository)?;
        validate_head(&source.head)?;
        ensure!(source.number > 0, "Positive PR number required");
        let root = filesystem::Directory::pin(&source.root)?;
        let (git_path, common_path) = git_layout(&source.root)?;
        let git = filesystem::Directory::pin(&git_path)?;
        let common = filesystem::Directory::pin(&common_path)?;
        let storage = filesystem::Directory::pin(&source.storage)?;
        ensure!(
            !source.storage.starts_with(&source.root),
            "Checkout staging must be outside the source repository"
        );
        let nonce = uuid::Uuid::new_v4();
        let branch = format!("coincide/pr-{}-{}", source.number, nonce.simple());
        Ok(Self {
            source,
            root,
            common,
            git,
            storage,
            nonce,
            branch,
        })
    }
    pub fn source(&self) -> &Source {
        &self.source
    }
    pub fn check(&self) -> Result<()> {
        self.root.check()?;
        self.common.check()?;
        self.git.check()?;
        self.storage.check()?;
        ensure!(
            git_layout(&self.root.path)? == (self.git.path.clone(), self.common.path.clone()),
            "Source common Git directory changed"
        );
        Ok(())
    }
    pub fn review(&self) -> Review {
        Review {
            repository: self.source.repository.clone(),
            number: self.source.number,
            expected_head: self.source.head.clone(),
            branch: self.branch.clone(),
            destination: self
                .storage
                .path
                .join(format!("pr-checkout-{}", self.nonce)),
            notice: "Verified regular files only. No network fetch, source branch change, linked-worktree admission or submodule initialization has occurred.",
        }
    }
    pub fn invocation(&self, tools: &Tools, operation: Operation) -> Result<Invocation> {
        self.check()?;
        tools.validate()?;
        let mut arguments = vec![
            "--no-pager".into(),
            "--no-replace-objects".into(),
            "--literal-pathspecs".into(),
            "-c".into(),
            "core.fsmonitor=false".into(),
            "-c".into(),
            "core.untrackedCache=false".into(),
            "-c".into(),
            "http.sslVerify=true".into(),
            "-c".into(),
            "http.followRedirects=false".into(),
            "-c".into(),
            "protocol.allow=never".into(),
        ];
        let directory = self.review().destination;
        arguments.extend([
            "-c".into(),
            format!(
                "core.hooksPath={}",
                directory
                    .join("disabled-hooks")
                    .to_str()
                    .context("Private Git path is not UTF-8")?
            ),
        ]);
        let environment = vec![
            ("HOME".into(), tools.home().as_os_str().to_owned()),
            (
                "GH_CONFIG_DIR".into(),
                tools.gh_config().as_os_str().to_owned(),
            ),
            ("GH_HOST".into(), "github.com".into()),
            ("GH_PROMPT_DISABLED".into(), "1".into()),
            ("GIT_CONFIG_NOSYSTEM".into(), "1".into()),
            (
                "GIT_CONFIG_SYSTEM".into(),
                directory.join("empty-config").into_os_string(),
            ),
            (
                "GIT_CONFIG_GLOBAL".into(),
                directory.join("empty-config").into_os_string(),
            ),
            ("GIT_TERMINAL_PROMPT".into(), "0".into()),
            ("GIT_NO_LAZY_FETCH".into(), "1".into()),
            ("GIT_OPTIONAL_LOCKS".into(), "0".into()),
        ];
        if operation != Operation::Initialize {
            arguments.push(format!(
                "--git-dir={}",
                directory
                    .join("objects.git")
                    .to_str()
                    .context("Private Git path is not UTF-8")?
            ));
        }
        let network = operation == Operation::FetchPull;
        let args: Vec<String> = match operation {
            Operation::Initialize => vec![
                "init".into(),
                "--bare".into(),
                "--template=".into(),
                "objects.git".into(),
            ],
            Operation::FetchPull => {
                let external = crate::workspace::external_git_path(&tools.gh.path)?;
                let gh = external.to_str().context("Native GH path is not UTF-8")?;
                arguments.extend([
                    "-c".into(),
                    "protocol.https.allow=always".into(),
                    "-c".into(),
                    "credential.helper=".into(),
                    "-c".into(),
                    format!(
                        "credential.helper=!{} auth git-credential",
                        shell_literal(gh)
                    ),
                    "-c".into(),
                    "credential.useHttpPath=false".into(),
                ]);
                vec![
                    "fetch".into(),
                    "--no-tags".into(),
                    "--no-recurse-submodules".into(),
                    "--no-write-fetch-head".into(),
                    "--".into(),
                    format!("https://github.com/{}", self.source.repository),
                    format!(
                        "+refs/pull/{}/head:refs/coincide/pull/head",
                        self.source.number
                    ),
                ]
            }
            Operation::VerifyHead => vec![
                "rev-parse".into(),
                "--verify".into(),
                "refs/coincide/pull/head^{commit}".into(),
            ],
            Operation::Tree => vec![
                "ls-tree".into(),
                "-r".into(),
                "-z".into(),
                "--full-tree".into(),
                "--long".into(),
                self.source.head.clone(),
                "--".into(),
            ],
            Operation::Blob(oid) => {
                validate_head(&oid)?;
                vec!["cat-file".into(), "blob".into(), oid]
            }
        };
        arguments.extend(args);
        Ok(Invocation {
            arguments,
            network,
            directory,
            environment,
        })
    }
    /// Injected, bounded object reads only. A semantic fetch reply alone cannot
    /// call this path: the future runner must own its full closure/return receipt.
    pub fn stage_regular_tree(
        &self,
        verified_head: &str,
        raw_tree: &[u8],
        reader: &mut impl BlobReader,
        cancelled: &AtomicBool,
    ) -> Result<StageOutcome> {
        self.check()?;
        ensure!(verified_head == self.source.head, "Fetched PR head changed");
        let entries = parse_tree(raw_tree)?;
        let required = entries
            .iter()
            .map(|entry| entry.size)
            .sum::<u64>()
            .checked_add(16 * 1024 * 1024)
            .context("Checkout size overflow")?;
        ensure!(
            self.storage.available_bytes()? >= required,
            "Insufficient free space for bounded checkout staging"
        );
        ensure!(
            !cancelled.load(Ordering::Acquire),
            "Checkout staging cancelled"
        );
        let started = Instant::now();
        let permit = ReadPermit {
            cancelled,
            deadline: started + TIMEOUT,
        };
        let destination = self.review().destination;
        let directory = self.storage.create_directory(
            destination
                .file_name()
                .unwrap()
                .to_str()
                .context("Invalid private destination")?,
        )?;
        let mut staged = StagedTree {
            directory,
            files: BTreeMap::new(),
            directories: BTreeMap::new(),
            complete: false,
        };
        let result = (|| -> Result<()> {
            for entry in entries {
                ensure!(
                    !cancelled.load(Ordering::Acquire),
                    "Checkout staging cancelled"
                );
                ensure!(started.elapsed() < TIMEOUT, "Checkout staging timed out");
                self.check()?;
                let bytes = reader.read_blob(&entry.oid, entry.size as usize, &permit)?;
                permit.check()?;
                ensure!(
                    bytes.len() == entry.size as usize && blob_identity(&bytes) == entry.oid,
                    "Git blob source changed"
                );
                let mut parent = staged.directory.clone_handle()?;
                let components = entry.path.split('/').collect::<Vec<_>>();
                let mut prefix = String::new();
                for name in &components[..components.len() - 1] {
                    if !prefix.is_empty() {
                        prefix.push('/');
                    }
                    prefix.push_str(name);
                    if !staged.directories.contains_key(&prefix) {
                        ensure!(
                            staged.directories.len() < MAX_FILES,
                            "Too many checkout directories"
                        );
                        let child = parent.create_directory(name)?;
                        staged.directories.insert(prefix.clone(), child);
                    }
                    parent = staged.directories.get(&prefix).unwrap().clone_handle()?;
                    parent.check()?;
                }
                let name = components.last().unwrap();
                let mut file = parent.create_file(name)?;
                file.write_all(&bytes)?;
                file.sync_all()?;
                filesystem::set_executable(&file, entry.executable)?;
                let identity = native_file::file_identity(&file)?;
                staged
                    .files
                    .insert(entry.path, (identity, entry.oid, entry.size));
            }
            self.check()?;
            ensure!(
                !cancelled.load(Ordering::Acquire),
                "Checkout staging cancelled"
            );
            Ok(())
        })();
        if let Err(error) = result {
            return Ok(StageOutcome::Retained {
                tree: staged,
                reason: error.to_string(),
            });
        }
        staged.complete = true;
        Ok(StageOutcome::Complete(staged))
    }
}
/// Closed per-materialization deadline/cancellation, handed only to the owned
/// blob adapter. It grants no network, ref mutation or thread admission.
pub struct ReadPermit<'a> {
    cancelled: &'a AtomicBool,
    deadline: Instant,
}
impl ReadPermit<'_> {
    pub fn check(&self) -> Result<()> {
        ensure!(
            !self.cancelled.load(Ordering::Acquire),
            "Checkout staging cancelled"
        );
        ensure!(Instant::now() < self.deadline, "Checkout staging timed out");
        Ok(())
    }
}
/// Private typed adapter. It receives only a validated object ID and exact size;
/// it cannot choose a path or source root. Returned bytes are independently hashed.
pub trait BlobReader {
    fn read_blob(
        &mut self,
        oid: &str,
        expected_size: usize,
        permit: &ReadPermit<'_>,
    ) -> Result<Vec<u8>>;
}
struct Entry {
    path: String,
    oid: String,
    size: u64,
    executable: bool,
}
fn portable_path(path: &str) -> Result<()> {
    ensure!(
        !path.is_empty() && path.len() <= 4096 && !path.contains('\\'),
        "Unsupported Git tree path"
    );
    ensure!(path.split('/').count() <= 32, "Checkout path is too deep");
    for part in path.split('/') {
        let upper = part.to_uppercase();
        let stem = upper.split('.').next().unwrap_or("");
        let hfs=upper.chars().filter(|ch|!matches!(*ch,'\u{200c}'..='\u{200f}'|'\u{202a}'..='\u{202e}'|'\u{206a}'..='\u{206f}'|'\u{feff}')).collect::<String>();
        ensure!(
            !part.is_empty()
                && part.len() <= 240
                && !matches!(upper.as_str(), "." | ".." | ".GIT" | ".GIT~1")
                && !part.ends_with(['.', ' '])
                && !part
                    .chars()
                    .any(|c| c.is_control() || "<>:\"|?*".contains(c))
                && !matches!(
                    stem,
                    "CON"
                        | "PRN"
                        | "AUX"
                        | "NUL"
                        | "COM1"
                        | "COM2"
                        | "COM3"
                        | "COM4"
                        | "COM5"
                        | "COM6"
                        | "COM7"
                        | "COM8"
                        | "COM9"
                        | "LPT1"
                        | "LPT2"
                        | "LPT3"
                        | "LPT4"
                        | "LPT5"
                        | "LPT6"
                        | "LPT7"
                        | "LPT8"
                        | "LPT9"
                )
                && upper != "GIT~1"
                && hfs != ".GIT",
            "Unsupported Git tree path"
        );
    }
    Ok(())
}
fn parse_tree(bytes: &[u8]) -> Result<Vec<Entry>> {
    ensure!(
        bytes.len() <= MAX_TREE && (bytes.is_empty() || bytes.ends_with(&[0])),
        "Invalid bounded Git tree"
    );
    let mut entries = Vec::new();
    let mut paths = HashSet::new();
    let mut total = 0u64;
    for raw in bytes.split(|b| *b == 0).filter(|raw| !raw.is_empty()) {
        ensure!(entries.len() < MAX_FILES, "Too many checkout files");
        let raw = std::str::from_utf8(raw).context("Non-UTF-8 Git paths are unsupported")?;
        let (metadata, path) = raw.split_once('\t').context("Invalid Git tree record")?;
        portable_path(path)?;
        let metadata = metadata.split_whitespace().collect::<Vec<_>>();
        ensure!(
            metadata.len() == 4
                && matches!(metadata[0], "100644" | "100755")
                && metadata[1] == "blob",
            "Submodules, symlinks and special Git entries are not populated"
        );
        validate_head(metadata[2])?;
        let size = metadata[3].parse::<u64>()?;
        ensure!(size <= MAX_BLOB as u64, "Git blob exceeds staging bound");
        total = total.checked_add(size).context("Checkout size overflow")?;
        ensure!(total <= MAX_TOTAL, "Checkout tree exceeds staging bound");
        let key = path.to_lowercase();
        ensure!(paths.insert(key), "Checkout paths collide");
        entries.push(Entry {
            path: path.into(),
            oid: metadata[2].into(),
            size,
            executable: metadata[0] == "100755",
        });
    }
    let files = entries
        .iter()
        .map(|entry| entry.path.to_lowercase())
        .collect::<HashSet<_>>();
    for entry in &entries {
        let mut prefix = String::new();
        let parts = entry.path.split('/').collect::<Vec<_>>();
        for part in &parts[..parts.len() - 1] {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(part);
            ensure!(
                !files.contains(&prefix.to_lowercase()),
                "Checkout file/directory paths collide"
            );
        }
    }
    Ok(entries)
}
fn blob_identity(bytes: &[u8]) -> String {
    let mut context = ring::digest::Context::new(&ring::digest::SHA1_FOR_LEGACY_USE_ONLY);
    context.update(format!("blob {}\0", bytes.len()).as_bytes());
    context.update(bytes);
    context
        .finish()
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
/// Staging custody only, deliberately not a linked-worktree/thread receipt.
/// Drop retains files. Cleanup must separately prove exact directory/file
/// identities and absence of user changes; partial/unknown state is retained.
pub struct StagedTree {
    directory: filesystem::Directory,
    files: BTreeMap<String, (Identity, String, u64)>,
    directories: BTreeMap<String, filesystem::Directory>,
    complete: bool,
}
impl StagedTree {
    pub fn path(&self) -> &Path {
        &self.directory.path
    }
    pub fn complete(&self) -> bool {
        self.complete
    }
    pub fn file_count(&self) -> usize {
        self.files.len()
    }
}

/// Failure after creating storage retains typed custody; no Drop cleanup claim.
pub enum StageOutcome {
    Complete(StagedTree),
    Retained { tree: StagedTree, reason: String },
}
