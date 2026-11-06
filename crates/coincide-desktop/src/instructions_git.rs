//! Native Git-copy review and mutation. Only the retained native picker can
//! mint this plan; no configuration/path/remote/digest JSON grants authority.
use super::file::EditorFile;
use crate::instructions_scope::NativeScope;
use anyhow::{Context as _, Result, bail, ensure};
use coincide_core::{
    agent::native_instruction_git::{Operation as Op, Runner, StoreSource},
    native_file::{self, Identity},
};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::AtomicBool,
    time::SystemTime,
};
const COPY_LIMIT: usize = 1024 * 1024;
fn hash(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}
fn output(runner: &Runner, root: &Path, op: &Op, cancel: &AtomicBool) -> Result<Vec<u8>> {
    let result = runner.capture(root, op, cancel)?;
    ensure!(
        result.code == 0,
        "Git operation failed; repository and credential details were not logged"
    );
    Ok(result.stdout)
}
fn line(bytes: Vec<u8>) -> Result<String> {
    let text = String::from_utf8(bytes).context("Git returned non-UTF-8 metadata")?;
    let value = text.trim_end_matches(['\r', '\n']);
    ensure!(
        !value.is_empty() && value.len() <= 4096 && !value.chars().any(char::is_control),
        "Git metadata is malformed"
    );
    Ok(value.to_owned())
}
fn head(runner: &Runner, root: &Path, cancel: &AtomicBool) -> Result<Option<String>> {
    let value = runner.capture(root, &Op::Head, cancel)?;
    if value.code == 1 {
        return Ok(None);
    }
    ensure!(value.code == 0, "Git HEAD is unavailable");
    let value = line(value.stdout)?;
    ensure!(
        matches!(value.len(), 40 | 64) && value.bytes().all(|c| c.is_ascii_hexdigit()),
        "Git HEAD identity is invalid"
    );
    Ok(Some(value))
}
#[derive(Clone, PartialEq, Eq)]
struct Stamp {
    identity: Identity,
    len: u64,
    modified: SystemTime,
    digest: [u8; 32],
}
fn stamp(path: &Path) -> Result<Option<Stamp>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
    };
    ensure!(
        metadata.is_file()
            && !metadata.file_type().is_symlink()
            && metadata.len() <= 32 * 1024 * 1024,
        "Git ownership metadata is not a bounded regular file"
    );
    let bytes = fs::read(path)?;
    let result = Stamp {
        identity: native_file::path_identity(path)?,
        len: metadata.len(),
        modified: metadata.modified()?,
        digest: hash(&bytes),
    };
    ensure!(
        fs::metadata(path)?.len() == result.len
            && fs::metadata(path)?.modified()? == result.modified
            && native_file::path_identity(path)? == result.identity,
        "Git metadata changed while reading"
    );
    Ok(Some(result))
}
fn marker(path: &Path) -> Result<Option<Stamp>> {
    if fs::symlink_metadata(path).is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink()) {
        Ok(None)
    } else {
        stamp(path)
    }
}
struct Directory {
    path: PathBuf,
    identity: Identity,
}
impl Directory {
    fn capture(path: PathBuf) -> Result<Self> {
        let path = path.canonicalize()?;
        ensure!(path.is_dir(), "Git directory is unavailable");
        Ok(Self {
            identity: native_file::path_identity(&path)?,
            path,
        })
    }
    fn validate(&self) -> Result<()> {
        ensure!(
            self.path.is_dir() && native_file::path_identity(&self.path)? == self.identity,
            "Git directory was replaced; review again"
        );
        Ok(())
    }
}
struct State {
    head: Option<String>,
    index: Option<Stamp>,
    configuration: [u8; 32],
}
impl State {
    fn capture(runner: &Runner, root: &Path, git: &Path, cancel: &AtomicBool) -> Result<Self> {
        Ok(Self {
            head: head(runner, root, cancel)?,
            index: stamp(&git.join("index"))?,
            configuration: hash(&output(runner, root, &Op::Configuration, cancel)?),
        })
    }
    fn same(&self, other: &Self) -> bool {
        self.head == other.head
            && self.index == other.index
            && self.configuration == other.configuration
    }
}
fn safe_remote_digest(bytes: &[u8]) -> Result<[u8; 32]> {
    let text = std::str::from_utf8(bytes).context("Git remote configuration is invalid")?;
    for raw in text.lines() {
        let value = raw.trim();
        ensure!(
            !value.is_empty()
                && !value.contains('?')
                && !value.contains('#')
                && !value.chars().any(char::is_control),
            "Git remote must not embed query credentials"
        );
        if let Some((scheme, rest)) = value.split_once("://") {
            let authority = rest.split('/').next().unwrap_or("");
            if let Some((user, _)) = authority.rsplit_once('@') {
                ensure!(
                    scheme == "ssh" && !user.contains(':'),
                    "Use a Git credential manager instead of embedded remote credentials"
                );
            }
        }
        if let Some(rest) = value.strip_prefix("https://") {
            ensure!(
                !rest.split('/').next().unwrap_or("").contains('@'),
                "Use a Git credential manager instead of credentials in the remote URL"
            );
        } else if let Some(rest) = value.strip_prefix("ssh://") {
            let host = rest.split('/').next().unwrap_or("");
            if let Some((user, _)) = host.rsplit_once('@') {
                ensure!(
                    !user.contains(':'),
                    "SSH remote embeds unsupported credential data"
                );
            }
        } else if value.starts_with("file://") || Path::new(value).is_absolute() {
        } else {
            let Some((user_host, _)) = value.split_once(':') else {
                bail!("Unsupported Git remote protocol")
            };
            ensure!(
                user_host.contains('@')
                    && !user_host.starts_with('-')
                    && !value.starts_with("ext::"),
                "Unsupported Git remote protocol"
            );
        }
    }
    Ok(hash(bytes))
}
fn other_index(bytes: &[u8], copy: &str) -> Result<[u8; 32]> {
    let mut rows = Vec::new();
    for row in bytes.split(|b| *b == 0).filter(|r| !r.is_empty()) {
        let Some(tab) = row.iter().position(|b| *b == b'\t') else {
            bail!("Git index response is malformed")
        };
        if &row[tab + 1..] != copy.as_bytes() {
            rows.push(row.to_vec());
        }
    }
    rows.sort();
    let mut joined = Vec::new();
    for row in rows {
        joined.extend(row);
        joined.push(0);
    }
    Ok(hash(&joined))
}
fn dirty_other(bytes: &[u8], copy: &str) -> Result<bool> {
    let mut paths = bytes.split(|b| *b == 0).filter(|r| !r.is_empty());
    while let Some(row) = paths.next() {
        ensure!(
            row.len() >= 4 && row[2] == b' ',
            "Git status response is malformed"
        );
        if &row[3..] != copy.as_bytes() {
            return Ok(true);
        }
        if row[..2].contains(&b'R') || row[..2].contains(&b'C') {
            let old = paths.next().context("Git rename status is malformed")?;
            if old != copy.as_bytes() {
                return Ok(true);
            }
        }
    }
    Ok(false)
}
/// A native repository review retains opaque ownership/digests only. Raw remote
/// URLs/config output are never fields, serialized data, diagnostics or UI text.
pub(super) struct Review {
    runner: Runner,
    picked_root: PathBuf,
    root: Directory,
    git: Directory,
    common: Directory,
    marker: Option<Stamp>,
    head_file: Option<Stamp>,
    state: State,
    source: StoreSource,
    scope: NativeScope,
    file: EditorFile,
    pub relative_copy: String,
    pub branch: String,
    pub remotes: Vec<String>,
    remote_digests: Vec<[u8; 32]>,
    push_digests: Vec<[u8; 32]>,
    remote_labels: Vec<String>,
    pub upstream: Option<String>,
    index_other: [u8; 32],
}
pub(super) struct Applied {
    pub committed: bool,
    pub pulled: bool,
    pub pushed: bool,
}
impl Review {
    pub fn capture(
        picked: PathBuf,
        scope: NativeScope,
        source: StoreSource,
        runner: Runner,
        cancel: &AtomicBool,
        validate: impl Fn() -> Result<()>,
    ) -> Result<Self> {
        validate()?;
        let root = Directory::capture(picked.clone())?;
        let actual = line(output(&runner, &root.path, &Op::Root, cancel)?)?;
        ensure!(
            Path::new(&actual).canonicalize()? == root.path,
            "Choose the top of the Git working tree"
        );
        let git = Directory::capture(PathBuf::from(line(output(
            &runner,
            &root.path,
            &Op::GitDirectory,
            cancel,
        )?)?))?;
        let common = Directory::capture(PathBuf::from(line(output(
            &runner,
            &root.path,
            &Op::CommonDirectory,
            cancel,
        )?)?))?;
        let raw_relative = scope
            .master_path()
            .strip_prefix(&picked)
            .or_else(|_| scope.master_path().strip_prefix(&root.path))
            .context("Choose a copy inside the selected repository")?;
        ensure!(
            raw_relative
                .components()
                .all(|c| matches!(c, std::path::Component::Normal(_))),
            "Copy path is not repository-relative"
        );
        let mut current = root.path.clone();
        for component in raw_relative.components() {
            current.push(component);
            ensure!(
                native_file::link_target(&current)?.is_none(),
                "Git copies must use a regular file path without symbolic links"
            );
        }
        let literal_copy = raw_relative
            .to_str()
            .context("Git copy path must be UTF-8")?;
        #[cfg(windows)]
        let relative_copy = literal_copy.replace('\\', "/");
        #[cfg(not(windows))]
        let relative_copy = literal_copy.to_owned();
        let mut file = EditorFile::from_native_scope(&scope)?;
        let text = file.load()?;
        ensure!(
            text.len() <= COPY_LIMIT,
            "Instruction Git copy exceeds 1 MiB"
        );
        let branch = line(output(&runner, &root.path, &Op::Branch, cancel)?)?;
        let names = output(&runner, &root.path, &Op::Remotes, cancel)?;
        let remotes = std::str::from_utf8(&names)?
            .lines()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        ensure!(remotes.len() <= 32, "Too many Git remotes");
        let mut remote_digests = Vec::new();
        let mut push_digests = Vec::new();
        let mut remote_labels = Vec::new();
        for name in &remotes {
            let fetch = output(&runner, &root.path, &Op::RemoteUrl(name.clone()), cancel)?;
            let push = output(&runner, &root.path, &Op::PushUrl(name.clone()), cancel)?;
            remote_digests.push(safe_remote_digest(&fetch)?);
            push_digests.push(safe_remote_digest(&push)?);
            remote_labels.push(format!(
                "{name} · Fetch: {} · Push: {}",
                sanitized_hosts(&fetch)?,
                sanitized_hosts(&push)?
            ));
        }
        let upstream_reply = runner.capture(&root.path, &Op::Upstream, cancel)?;
        let upstream = if upstream_reply.code == 0 {
            Some(line(upstream_reply.stdout)?)
        } else {
            None
        };
        let state = State::capture(&runner, &root.path, &git.path, cancel)?;
        let marker = marker(&root.path.join(".git"))?;
        let head_file = stamp(&git.path.join("HEAD"))?;
        let index_other = other_index(
            &output(&runner, &root.path, &Op::IndexEntries, cancel)?,
            &relative_copy,
        )?;
        let result = Self {
            runner,
            picked_root: picked,
            root,
            git,
            common,
            marker,
            head_file,
            state,
            source,
            scope,
            file,
            relative_copy,
            branch,
            remotes,
            remote_digests,
            push_digests,
            remote_labels,
            upstream,
            index_other,
        };
        result.validate(cancel, &validate)?;
        Ok(result)
    }
    pub fn remote_label(&self, index: usize) -> &str {
        self.remote_labels
            .get(index)
            .map(String::as_str)
            .unwrap_or("Unavailable remote")
    }
    pub fn can_push(&self, index: usize) -> bool {
        self.remote_digests
            .get(index)
            .zip(self.push_digests.get(index))
            .is_some_and(|(a, b)| a == b)
    }
    pub fn owner_tokens(&self) -> (StoreSource, NativeScope) {
        (self.source.clone(), self.scope.clone())
    }
    pub fn repository_path(&self) -> &Path {
        &self.root.path
    }
    pub fn copy_text(&self) -> &str {
        self.file.baseline().unwrap_or("")
    }
    pub fn validate_source(&self, store: &coincide_core::store::Store) -> Result<()> {
        self.source.validate(store)?;
        self.scope.validate_native(store)
    }
    fn binding(&self) -> Result<()> {
        self.root.validate()?;
        self.git.validate()?;
        self.common.validate()?;
        ensure!(
            self.picked_root.canonicalize()? == self.root.path,
            "Selected Git directory changed"
        );
        ensure!(
            marker(&self.root.path.join(".git"))? == self.marker
                && stamp(&self.git.path.join("HEAD"))? == self.head_file,
            "Git working-tree binding changed"
        );
        Ok(())
    }
    fn validate(&self, cancel: &AtomicBool, owner: &impl Fn() -> Result<()>) -> Result<()> {
        owner()?;
        self.binding()?;
        self.file.validate_review_source()?;
        ensure!(
            self.state.same(&State::capture(
                &self.runner,
                &self.root.path,
                &self.git.path,
                cancel
            )?),
            "Git HEAD, index or configuration changed; review again"
        );
        Ok(())
    }
    fn remote(&self, index: usize, cancel: &AtomicBool) -> Result<&str> {
        let name = self
            .remotes
            .get(index)
            .context("Choose a current Git remote")?;
        ensure!(
            safe_remote_digest(&output(
                &self.runner,
                &self.root.path,
                &Op::RemoteUrl(name.clone()),
                cancel
            )?)? == self.remote_digests[index],
            "Git remote changed; review again"
        );
        ensure!(
            safe_remote_digest(&output(
                &self.runner,
                &self.root.path,
                &Op::PushUrl(name.clone()),
                cancel
            )?)? == self.push_digests[index],
            "Git push destination changed; review again"
        );
        Ok(name)
    }
    pub fn apply(
        mut self,
        remote_index: Option<usize>,
        push: bool,
        cancel: &AtomicBool,
        owner: impl Fn() -> Result<()>,
    ) -> Result<Applied> {
        self.validate(cancel, &owner)?;
        if push {
            ensure!(
                remote_index.is_some_and(|index| self.can_push(index)),
                "Push requires matching reviewed fetch/push destinations; use manual Git for split destinations"
            );
        }
        let lock_path = self.git.path.join("coincide-instruction-sync.lock");
        let lock = match native_file::create_private_file(&lock_path) {
            Ok(file) => file,
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|e| e.kind() == std::io::ErrorKind::AlreadyExists) =>
            {
                native_file::open_regular(&lock_path, true)?
            }
            Err(error) => return Err(error),
        };
        lock.try_lock()
            .context("Another instruction Git sync owns this repository")?;
        self.validate(cancel, &owner)?;
        let approved = self.copy_text().as_bytes().to_vec();
        let mut applied = Applied {
            committed: false,
            pulled: false,
            pushed: false,
        };
        let status = output(
            &self.runner,
            &self.root.path,
            &Op::CopyStatus(self.relative_copy.clone()),
            cancel,
        )?;
        if !status.is_empty() {
            output(
                &self.runner,
                &self.root.path,
                &Op::StageCopy(self.relative_copy.clone()),
                cancel,
            )?;
            ensure!(
                head(&self.runner, &self.root.path, cancel)? == self.state.head,
                "Git HEAD moved while staging; review again"
            );
            self.file.validate_review_source()?;
            output(
                &self.runner,
                &self.root.path,
                &Op::CommitCopy(self.relative_copy.clone()),
                cancel,
            )?;
            let new_head = head(&self.runner, &self.root.path, cancel)?
                .context("Git commit did not produce HEAD")?;
            let parents = line(output(
                &self.runner,
                &self.root.path,
                &Op::Parents(new_head.clone()),
                cancel,
            )?)?;
            let actual = parents.split_whitespace().collect::<Vec<_>>();
            ensure!(
                actual.first() == Some(&new_head.as_str())
                    && match &self.state.head {
                        Some(old) => actual.len() == 2 && actual[1] == old,
                        None => actual.len() == 1,
                    },
                "Repository changed during commit; inspect local history before retrying"
            );
            ensure!(
                output(
                    &self.runner,
                    &self.root.path,
                    &Op::Blob {
                        oid: new_head.clone(),
                        path: self.relative_copy.clone()
                    },
                    cancel
                )? == approved,
                "Committed copy differs from its native review; push was refused"
            );
            ensure!(
                other_index(
                    &output(&self.runner, &self.root.path, &Op::IndexEntries, cancel)?,
                    &self.relative_copy
                )? == self.index_other,
                "Unrelated Git index entries changed; push was refused"
            );
            let next = State::capture(&self.runner, &self.root.path, &self.git.path, cancel)?;
            ensure!(
                next.configuration == self.state.configuration
                    && line(output(&self.runner, &self.root.path, &Op::Branch, cancel)?)?
                        == self.branch,
                "Git configuration or branch changed during commit; push was refused"
            );
            self.state = next;
            self.head_file = stamp(&self.git.path.join("HEAD"))?;
            applied.committed = true;
        }
        let Some(remote_index) = remote_index else {
            return Ok(applied);
        };
        let remote = self.remote(remote_index, cancel)?.to_owned();
        let token = uuid::Uuid::new_v4().to_string();
        let result = (|| -> Result<()> {
            owner()?;
            self.binding()?;
            ensure!(
                self.state.same(&State::capture(
                    &self.runner,
                    &self.root.path,
                    &self.git.path,
                    cancel
                )?),
                "Git state changed before fetch"
            );
            output(
                &self.runner,
                &self.root.path,
                &Op::FetchHeads {
                    remote: remote.clone(),
                    token: token.clone(),
                },
                cancel,
            )?;
            let raw = output(
                &self.runner,
                &self.root.path,
                &Op::RemoteHeads(token.clone()),
                cancel,
            )?;
            let heads = parse_heads(&raw, &token)?;
            let upstream = match self.upstream.as_deref() {
                Some(value) => value
                    .strip_prefix(&format!("{remote}/"))
                    .context("Choose the repository's configured upstream remote before syncing")?
                    .to_owned(),
                None => self.branch.clone(),
            };
            ensure!(
                self.state.same(&State::capture(
                    &self.runner,
                    &self.root.path,
                    &self.git.path,
                    cancel
                )?),
                "Git state changed during fetch; branch updates were refused"
            );
            let incoming = heads
                .iter()
                .find(|(name, _)| name == &upstream)
                .map(|(_, id)| id.clone());
            if let (Some(local), Some(incoming)) = (self.state.head.clone(), incoming) {
                let counts = line(output(
                    &self.runner,
                    &self.root.path,
                    &Op::AheadBehind {
                        head: local,
                        upstream: incoming.clone(),
                    },
                    cancel,
                )?)?;
                let parts = counts
                    .split_whitespace()
                    .map(str::parse::<u64>)
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                ensure!(parts.len() == 2, "Git comparison is invalid");
                if parts[1] > 0 {
                    ensure!(
                        !dirty_other(
                            &output(&self.runner, &self.root.path, &Op::Status, cancel)?,
                            &self.relative_copy
                        )?,
                        "Unrelated local edits must be saved before pulling; nothing was stashed or discarded"
                    );
                    self.file.validate_review_source()?;
                    owner()?;
                    self.binding()?;
                    if parts[0] == 0 {
                        output(
                            &self.runner,
                            &self.root.path,
                            &Op::FastForward(incoming),
                            cancel,
                        )?;
                    } else {
                        let rebase =
                            self.runner
                                .capture(&self.root.path, &Op::Rebase(incoming), cancel);
                        if !rebase.as_ref().is_ok_and(|r| r.code == 0) {
                            let cleanup = AtomicBool::new(false);
                            let aborted =
                                self.runner
                                    .capture(&self.root.path, &Op::AbortRebase, &cleanup);
                            ensure!(
                                aborted.is_ok_and(|r| r.code == 0),
                                "Rebase did not finish and owned abort failed; inspect the selected repository"
                            );
                            bail!("Git rebase stopped; the original local state was restored");
                        }
                    }
                    applied.pulled = true;
                    let next =
                        State::capture(&self.runner, &self.root.path, &self.git.path, cancel)?;
                    ensure!(
                        next.configuration == self.state.configuration
                            && line(output(&self.runner, &self.root.path, &Op::Branch, cancel)?)?
                                == self.branch,
                        "Git configuration or branch changed while pulling; push was refused"
                    );
                    self.state = next;
                    self.head_file = stamp(&self.git.path.join("HEAD"))?;
                }
            }
            if push {
                owner()?;
                self.binding()?;
                ensure!(
                    self.state.same(&State::capture(
                        &self.runner,
                        &self.root.path,
                        &self.git.path,
                        cancel
                    )?),
                    "Git state changed before push"
                );
                self.remote(remote_index, cancel)?;
                let current = self
                    .state
                    .head
                    .clone()
                    .context("There is no Git commit to push")?;
                let excluded = heads.iter().map(|(_, id)| id.clone()).collect::<Vec<_>>();
                let revisions = output(
                    &self.runner,
                    &self.root.path,
                    &Op::Revisions {
                        head: current,
                        excluded,
                    },
                    cancel,
                )?;
                let revisions = std::str::from_utf8(&revisions)?.lines().collect::<Vec<_>>();
                ensure!(
                    revisions.len() <= 1024,
                    "Outgoing Git history exceeds the review bound"
                );
                for commit in &revisions {
                    let paths = output(
                        &self.runner,
                        &self.root.path,
                        &Op::ChangedPaths((*commit).to_owned()),
                        cancel,
                    )?;
                    ensure!(
                        paths
                            .split(|b| *b == 0)
                            .filter(|p| !p.is_empty())
                            .all(|p| p == self.relative_copy.as_bytes()),
                        "Outgoing history changes files outside the chosen instruction copy; push was refused"
                    );
                }
                if !revisions.is_empty() {
                    owner()?;
                    self.remote(remote_index, cancel)?;
                    ensure!(
                        head(&self.runner, &self.root.path, cancel)? == self.state.head,
                        "Git HEAD changed before push"
                    );
                    output(
                        &self.runner,
                        &self.root.path,
                        &Op::Push {
                            remote: remote.clone(),
                            branch: self.branch.clone(),
                        },
                        cancel,
                    )?;
                    applied.pushed = true;
                }
            }
            Ok(())
        })();
        // Every cleanup command is local, scoped to this operation's private
        // refs and owned even after cancellation; no force/history reset exists.
        let cleanup = AtomicBool::new(false);
        let cleanup_result = (|| -> Result<()> {
            self.root.validate()?;
            self.git.validate()?;
            let raw = output(
                &self.runner,
                &self.root.path,
                &Op::RemoteHeads(token.clone()),
                &cleanup,
            )?;
            for (name, id) in parse_heads(&raw, &token)? {
                output(
                    &self.runner,
                    &self.root.path,
                    &Op::DeletePrivateRef {
                        reference: format!("refs/coincide/instructions/{token}/{name}"),
                        oid: id,
                    },
                    &cleanup,
                )?;
            }
            Ok(())
        })();
        result?;
        cleanup_result?;
        drop(lock);
        Ok(applied)
    }
}
fn parse_heads(bytes: &[u8], token: &str) -> Result<Vec<(String, String)>> {
    let mut rows = Vec::new();
    for line in std::str::from_utf8(bytes)?.lines() {
        let Some((reference, oid)) = line.split_once('\0') else {
            bail!("Remote Git references are malformed")
        };
        let name = reference
            .strip_prefix(&format!("refs/coincide/instructions/{token}/"))
            .context("Remote Git reference escaped its native scope")?;
        ensure!(
            matches!(oid.len(), 40 | 64) && oid.bytes().all(|c| c.is_ascii_hexdigit()),
            "Remote Git object identity is invalid"
        );
        rows.push((name.to_owned(), oid.to_owned()));
        ensure!(rows.len() <= 1024, "Too many remote branches");
    }
    Ok(rows)
}
fn sanitized_hosts(bytes: &[u8]) -> Result<String> {
    let mut hosts = Vec::new();
    for value in std::str::from_utf8(bytes)?.lines() {
        let host = if let Some((scheme, rest)) = value.split_once("://") {
            if scheme == "file" {
                "Local file transport".to_owned()
            } else {
                let authority = rest.split('/').next().unwrap_or("");
                let host = authority.rsplit('@').next().unwrap_or("");
                format!("{scheme}://{host}")
            }
        } else if Path::new(value).is_absolute() {
            "Local file transport".into()
        } else {
            value
                .split_once(':')
                .and_then(|(authority, _)| {
                    authority
                        .rsplit_once('@')
                        .map(|(_, host)| format!("ssh://{host}"))
                })
                .context("Unsupported Git remote")?
        };
        hosts.push(host);
        ensure!(hosts.len() <= 8, "Too many Git destination URLs");
    }
    Ok(hosts.join(", "))
}

#[cfg(test)]
#[path = "instructions_git_tests.rs"]
mod tests;
