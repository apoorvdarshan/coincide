//! Native-only instruction scope custody. No constructor is deserializable and
//! no method is registered on the Engine's JSON/control dispatcher.
use super::instructions_config::{self, Choice, Metadata, TargetState};
use anyhow::{Context as _, Result, ensure};
use coincide_core::{
    native_file::{self, Identity},
    store::Store,
};
use serde_json::json;
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    time::SystemTime,
};
#[path = "instructions_discovery.rs"]
mod discovery;
const LIMIT: usize = 1024 * 1024;
const NAMES: [&str; 3] = ["AGENTS.md", "CLAUDE.md", "GEMINI.md"];
#[derive(Clone, Debug, PartialEq, Eq)]
struct PathStamp {
    path: PathBuf,
    identity: Option<Identity>,
    link: Option<PathBuf>,
    modified: Option<SystemTime>,
}
fn chain(path: &Path) -> Result<Vec<PathStamp>> {
    ensure!(path.is_absolute(), "Instruction path must be absolute");
    let mut current = PathBuf::new();
    let mut result = Vec::new();
    for part in path.components() {
        current.push(part);
        if !current.is_absolute() {
            continue;
        }
        let metadata = match fs::symlink_metadata(&current) {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && current == path => break,
            Err(e) => return Err(e.into()),
        };
        let link = native_file::link_target(&current)?;
        let identity = match native_file::path_identity(&current) {
            Ok(id) => Some(id),
            Err(_) if link.is_some() => None,
            Err(e) => return Err(e),
        };
        let modified = if metadata.is_dir() && link.is_none() {
            None
        } else {
            Some(metadata.modified()?)
        };
        result.push(PathStamp {
            path: current.clone(),
            identity,
            link,
            modified,
        });
    }
    Ok(result)
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Observation {
    path: PathBuf,
    chain: Vec<PathStamp>,
    resolved: Option<PathBuf>,
    bytes: Option<Vec<u8>>,
    present: bool,
    link: bool,
}
impl Observation {
    fn capture(path: &Path) -> Result<Self> {
        let before = chain(path)?;
        let metadata = fs::symlink_metadata(path);
        let present = match &metadata {
            Ok(_) => true,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
            Err(_) => return Err(metadata.unwrap_err().into()),
        };
        let link = if present {
            native_file::link_target(path)?.is_some()
        } else {
            false
        };
        let resolved = if present {
            path.canonicalize().ok()
        } else {
            None
        };
        let bytes = if let Some(resolved) = &resolved {
            let mut file = native_file::open_regular(resolved, false)?;
            ensure!(
                file.metadata()?.len() <= LIMIT as u64,
                "Instructions exceed 1 MiB"
            );
            let mut bytes = Vec::new();
            Read::by_ref(&mut file)
                .take(LIMIT as u64 + 1)
                .read_to_end(&mut bytes)?;
            ensure!(bytes.len() <= LIMIT, "Instructions grew while reading");
            std::str::from_utf8(&bytes).context("Instructions must be UTF-8")?;
            Some(bytes)
        } else {
            None
        };
        ensure!(
            chain(path)? == before,
            "Instruction path changed while reading"
        );
        Ok(Self {
            path: path.into(),
            chain: before,
            resolved,
            bytes,
            present,
            link,
        })
    }
    fn unchanged(&self) -> Result<()> {
        ensure!(
            Self::capture(&self.path)? == *self,
            "Instructions changed after review; review again"
        );
        Ok(())
    }
    fn text(&self) -> &str {
        self.bytes
            .as_deref()
            .and_then(|b| std::str::from_utf8(b).ok())
            .unwrap_or("")
    }
}
#[derive(Clone)]
enum Kind {
    Global,
    Project { project_id: String, root: PathBuf },
}
#[derive(Clone)]
pub(super) struct NativeScope {
    kind: Kind,
    root: PathBuf,
    root_identity: Identity,
    master: PathBuf,
    managed: Vec<coincide_core::native_instruction_profiles::NativeCodexInstructionHome>,
}
#[derive(Clone, Debug)]
pub(super) struct DiscoveredFile {
    pub name: String,
    pub path: PathBuf,
    pub exists: bool,
    pub linked: bool,
    pub readable: bool,
}
impl NativeScope {
    /// Called only by the native Global destination. Does not read a master.
    pub fn global_native() -> Result<Self> {
        #[cfg(windows)]
        let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME"));
        #[cfg(not(windows))]
        let home = std::env::var_os("HOME");
        let home = PathBuf::from(home.context("Home directory is unavailable")?);
        ensure!(home.is_absolute(), "Home directory must be absolute");
        let root = home.canonicalize()?;
        let root_identity = native_file::path_identity(&root)?;
        Ok(Self {
            kind: Kind::Global,
            master: root.join(".config/coincide/AGENTS.md"),
            root,
            root_identity,
            managed: Vec::new(),
        })
    }
    /// Scope identity comes from the locked Store, never a caller's root claim.
    pub fn project_native(store: &Store, id: &str) -> Result<Self> {
        let projects = store.projects()?;
        let project = projects
            .as_array()
            .context("Projects are malformed")?
            .iter()
            .find(|p| p["id"].as_str() == Some(id))
            .context("Project no longer exists")?;
        let path = PathBuf::from(
            project["path"]
                .as_str()
                .context("Project path is missing")?,
        );
        ensure!(path.is_absolute(), "Project path must be absolute");
        let root = path.canonicalize()?;
        Ok(Self {
            kind: Kind::Project {
                project_id: id.into(),
                root: path,
            },
            root_identity: native_file::path_identity(&root)?,
            master: root.join("AGENTS.md"),
            root,
            managed: Vec::new(),
        })
    }
    pub fn validate_native(&self, store: &Store) -> Result<()> {
        self.validate(store)
    }
    fn validate(&self, store: &Store) -> Result<()> {
        for home in &self.managed {
            home.instruction_path(store)?;
        }
        ensure!(
            self.root.is_dir() && native_file::path_identity(&self.root)? == self.root_identity,
            "Instruction scope directory changed"
        );
        if let Kind::Project { project_id, root } = &self.kind {
            let projects = store.projects()?;
            let current = projects
                .as_array()
                .context("Projects are malformed")?
                .iter()
                .find(|p| p["id"].as_str() == Some(project_id))
                .context("Project no longer exists")?;
            ensure!(
                current["path"].as_str() == root.to_str() && root.canonicalize()? == self.root,
                "Project moved; reopen its Instructions"
            );
        }
        Ok(())
    }
    fn key(&self) -> Option<&Path> {
        match &self.kind {
            Kind::Global => None,
            Kind::Project { root, .. } => Some(root),
        }
    }
    pub fn label(&self) -> String {
        match &self.kind {
            Kind::Global => "Global".into(),
            Kind::Project { root, .. } => root
                .file_name()
                .unwrap_or(root.as_os_str())
                .to_string_lossy()
                .into_owned(),
        }
    }
    pub fn master_path(&self) -> &Path {
        &self.master
    }
    /// Invoke only with the result of the user's native file chooser. Merely
    /// reading configured masterPath metadata never calls this constructor.
    pub fn choose_master_native(&mut self, path: PathBuf, store: &Store) -> Result<()> {
        self.validate(store)?;
        ensure!(path.is_absolute(), "Master path must be absolute");
        ensure!(
            path.parent().is_some_and(Path::is_dir),
            "Choose a master in an existing folder"
        );
        self.master = path;
        Ok(())
    }
    /// Explicit native adoption of a displayed configured master, kept separate
    /// from metadata parsing so imports cannot cause reads/writes on launch.
    pub fn use_configured_master_native(
        &mut self,
        metadata: &Metadata,
        store: &Store,
    ) -> Result<()> {
        if let Some(config) = metadata.configuration(self.key())? {
            self.choose_master_native(config.master, store)?;
        }
        Ok(())
    }
    /// Explicit native Create action; no Reload/config import calls this.
    pub fn create_master_native(&self, store: &Store, text: &str) -> Result<()> {
        self.validate(store)?;
        ensure!(
            text.len() <= LIMIT && !text.contains('\0'),
            "Instructions must fit within 1 MiB and contain no NUL"
        );
        if matches!(self.kind, Kind::Global)
            && self.master == self.root.join(".config/coincide/AGENTS.md")
        {
            for path in [
                self.root.join(".config"),
                self.root.join(".config/coincide"),
            ] {
                if !path.exists() {
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::DirBuilderExt;
                        fs::DirBuilder::new().mode(0o700).create(&path)?;
                    }
                    #[cfg(not(unix))]
                    fs::create_dir(&path)?;
                }
                ensure!(
                    fs::symlink_metadata(&path)?.is_dir()
                        && native_file::link_target(&path)?.is_none(),
                    "Instruction folder is not a regular directory"
                );
                self.validate(store)?;
            }
        }
        create_exclusive(&self.master, text).map(|_| ())
    }
    pub fn discover_native(&self, store: &Store) -> Result<Vec<DiscoveredFile>> {
        self.validate(store)?;
        let mut paths = vec![self.master.clone()];
        match &self.kind {
            Kind::Project { .. } => paths.extend(discovery::project_paths(&self.root)),
            Kind::Global => {
                for name in [
                    ".claude/CLAUDE.md",
                    ".codex/AGENTS.md",
                    ".codex/AGENTS.override.md",
                    ".grok/AGENTS.md",
                    ".config/opencode/AGENTS.md",
                    ".gemini/GEMINI.md",
                ] {
                    paths.push(self.root.join(name));
                }
                for home in store.native_codex_instruction_homes()? {
                    paths.push(home.instruction_path(store)?);
                }
            }
        }
        paths.sort();
        paths.dedup();
        Ok(paths
            .into_iter()
            .map(|path| {
                let observation = Observation::capture(&path);
                let exists = fs::symlink_metadata(&path).is_ok();
                DiscoveredFile {
                    name: path
                        .strip_prefix(&self.root)
                        .unwrap_or(&path)
                        .display()
                        .to_string(),
                    path,
                    exists,
                    linked: observation.as_ref().is_ok_and(|o| o.link),
                    readable: observation.is_ok_and(|o| o.bytes.is_some()),
                }
            })
            .collect())
    }
    /// Configuration update is native-owned and full-document CAS under the
    /// caller's existing Store lock; no imported sync settings are activated.
    pub fn persist_configuration_native(
        &self,
        store: &mut Store,
        baseline: &Metadata,
        enabled: bool,
    ) -> Result<Metadata> {
        self.validate(store)?;
        let actual = Metadata::from_document(store.document("instructions.json")?)?;
        ensure!(
            actual.document == baseline.document,
            "Instruction configuration changed; reload it"
        );
        let mut config = baseline
            .configuration(self.key())?
            .map(|c| c.raw)
            .unwrap_or_else(|| json!({"isEnabled":false,"sync":{"off":{}}}));
        config["masterPath"] = json!(self.master);
        config["isEnabled"] = json!(enabled);
        let next = baseline.with_configuration(self.key(), &config)?;
        store.save_document("instructions.json", &next)?;
        Metadata::from_document(Some(next))
    }
    pub fn prepare_creation_native(&self, store: &Store) -> Result<NativeInstructionCreation> {
        self.validate(store)?;
        let observed = Observation::capture(&self.master)?;
        ensure!(!observed.present, "Instruction file already exists");
        Ok(NativeInstructionCreation {
            scope: self.clone(),
            observed,
        })
    }
    pub fn persist_file_copy_native(
        &self,
        store: &mut Store,
        baseline: &Metadata,
        copy: Option<&NativeScope>,
        agreed: Option<&str>,
    ) -> Result<Metadata> {
        self.validate(store)?;
        if let Some(copy) = copy {
            copy.validate(store)?;
            ensure!(
                copy.root == self.root && copy.root_identity == self.root_identity,
                "Copy belongs to another native scope"
            );
        }
        let actual = Metadata::from_document(store.document("instructions.json")?)?;
        ensure!(
            actual.document == baseline.document,
            "Instruction configuration changed; review sync again"
        );
        let mut config = baseline
            .configuration(self.key())?
            .map(|c| c.raw)
            .unwrap_or_else(
                || json!({"isEnabled":false,"sync":{"off":{}},"masterPath":self.master}),
            );
        ensure!(
            config["masterPath"] == json!(self.master),
            "Configured master changed; select it before syncing"
        );
        config["fileCopy"] = copy
            .map(|copy| json!({"path":copy.master,"agreed":agreed}))
            .unwrap_or(serde_json::Value::Null);
        let next = baseline.with_configuration(self.key(), &config)?;
        store.save_document("instructions.json", &next)?;
        Metadata::from_document(Some(next))
    }
    pub fn review_native(mut self, store: &Store) -> Result<NativeReviewPlan> {
        if matches!(self.kind, Kind::Global) {
            self.managed = store.native_codex_instruction_homes()?;
        }
        self.validate(store)?;
        let master = Observation::capture(&self.master)
            .context("Master folder must exist before reviewing links")?;
        let mut paths: Vec<PathBuf> = match &self.kind {
            Kind::Project { .. } => NAMES.iter().map(|n| self.root.join(n)).collect(),
            Kind::Global => [
                ".claude/CLAUDE.md",
                ".codex/AGENTS.md",
                ".grok/AGENTS.md",
                ".config/opencode/AGENTS.md",
                ".gemini/GEMINI.md",
            ]
            .iter()
            .map(|n| self.root.join(n))
            .collect(),
        };
        for home in &self.managed {
            let path = home.instruction_path(store)?;
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
        let mut targets = Vec::new();
        for path in paths {
            if path == self.master {
                continue;
            }
            let observation = Observation::capture(&path).ok();
            let state = match &observation {
                None => {
                    if path.parent().is_some_and(Path::is_dir) {
                        TargetState::Unreadable
                    } else {
                        TargetState::FolderMissing
                    }
                }
                Some(o) => classify(&master, o),
            };
            targets.push(ReviewTarget {
                label: path
                    .strip_prefix(&self.root)
                    .unwrap_or(&path)
                    .display()
                    .to_string(),
                path,
                state,
                observation,
            });
        }
        let seed = if master.present {
            master.text().to_owned()
        } else {
            targets
                .iter()
                .filter_map(|t| t.observation.as_ref())
                .find(|o| !o.link && o.bytes.is_some())
                .map(|o| o.text().to_owned())
                .unwrap_or_default()
        };
        // Missing masters are seeded before states are presented, matching Swift.
        for target in &mut targets {
            if let Some(o) = &target.observation {
                if !o.link && o.present {
                    target.state = if o.text() == seed {
                        TargetState::Identical
                    } else {
                        TargetState::Differs
                    };
                }
            }
        }
        Ok(NativeReviewPlan {
            scope: self,
            master,
            seed,
            targets,
        })
    }
}
pub(super) struct NativeInstructionCreation {
    scope: NativeScope,
    observed: Observation,
}
impl NativeInstructionCreation {
    pub fn validate(&self, store: &Store) -> Result<()> {
        self.scope.validate(store)?;
        self.observed.unchanged()
    }
    pub fn create(self, store: &Store, text: &str) -> Result<()> {
        self.validate(store)?;
        ensure!(
            text.len() <= LIMIT && !text.contains('\0'),
            "Instruction copy is invalid or oversized"
        );
        create_exclusive(&self.observed.path, text)?;
        Ok(())
    }
}
fn classify(master: &Observation, target: &Observation) -> TargetState {
    if target.link {
        if target.resolved.is_some() && target.resolved == master.resolved {
            TargetState::Linked
        } else if target.resolved.is_none() {
            TargetState::BrokenLink
        } else {
            TargetState::ForeignLink
        }
    } else if !target.present {
        TargetState::Missing
    } else if target.bytes.is_none() {
        TargetState::Unreadable
    } else if target.bytes == master.bytes {
        TargetState::Identical
    } else {
        TargetState::Differs
    }
}
pub(super) struct ReviewTarget {
    pub label: String,
    pub path: PathBuf,
    pub state: TargetState,
    observation: Option<Observation>,
}
pub(super) struct NativeReviewPlan {
    scope: NativeScope,
    master: Observation,
    seed: String,
    pub targets: Vec<ReviewTarget>,
}
#[derive(Debug)]
pub(super) struct LinkOutcome {
    pub path: PathBuf,
    pub backup: Option<PathBuf>,
    pub linked: bool,
    pub error: Option<String>,
}
impl NativeReviewPlan {
    pub fn master_path(&self) -> &Path {
        self.scope.master_path()
    }
    pub fn has_existing_master(&self) -> bool {
        self.master.present
    }
    pub fn preview_text(&self, choices: &[Choice]) -> Result<String> {
        ensure!(
            choices.len() == self.targets.len(),
            "Review every instruction target"
        );
        let mut text = self.seed.clone();
        for (target, choice) in self.targets.iter().zip(choices) {
            if *choice == Choice::Merge {
                ensure!(
                    target.state == TargetState::Differs,
                    "Merge requires a separate file with different text"
                );
                text = instructions_config::merged(
                    &text,
                    target
                        .observation
                        .as_ref()
                        .context("Target cannot be read")?
                        .text(),
                    &target.label,
                );
            }
        }
        ensure!(text.len() <= LIMIT, "Merged instructions exceed 1 MiB");
        Ok(text)
    }
    /// Turn off shared-master mode. Only captured links resolving to this
    /// exact master may become copies; foreign targets are always retained.
    pub fn disable_native(
        self,
        store: &Store,
        replace_with_copies: bool,
    ) -> Result<(NativeScope, Vec<LinkOutcome>)> {
        self.scope.validate(store)?;
        self.master.unchanged()?;
        for target in &self.targets {
            if let Some(observed) = &target.observation {
                observed.unchanged()?;
            }
        }
        let mut outcomes = Vec::new();
        if replace_with_copies {
            for target in &self.targets {
                if target.state != TargetState::Linked {
                    continue;
                }
                self.scope.validate(store)?;
                self.master.unchanged()?;
                let expected = target
                    .observation
                    .as_ref()
                    .context("Linked target observation missing")?;
                let (backup, result) =
                    replace_reviewed_link_with_copy(&self.master, expected, || Ok(()));
                outcomes.push(LinkOutcome {
                    path: target.path.clone(),
                    backup,
                    linked: result.is_ok(),
                    error: result.err().map(|e| e.to_string()),
                });
            }
        }
        Ok((self.scope, outcomes))
    }
    /// Native confirmation only. Existing-master writes are delegated to the
    /// retained editor's recovery/CAS writer, never a JSON/path-selected writer.
    pub fn apply_native(
        self,
        store: &Store,
        choices: &[Choice],
        write_existing: impl FnOnce(&Path, &str, &str) -> Result<()>,
    ) -> Result<(NativeScope, Vec<LinkOutcome>)> {
        ensure!(
            choices.len() == self.targets.len(),
            "Review each instruction target"
        );
        ensure!(
            self.targets
                .iter()
                .zip(choices)
                .all(|(target, choice)| *choice != Choice::Merge
                    || target.state == TargetState::Differs),
            "Merge is available only for a separate file with different text"
        );
        self.scope.validate(store)?;
        self.master.unchanged()?;
        for target in &self.targets {
            if let Some(o) = &target.observation {
                o.unchanged()?;
            }
        }
        let text = self.preview_text(choices)?;
        let saved = if self.master.present {
            if text != self.master.text() {
                write_existing(&self.master.path, self.master.text(), &text)?;
            }
            let saved = Observation::capture(&self.master.path)?;
            ensure!(
                self.master.resolved == saved.resolved
                    && self
                        .master
                        .chain
                        .iter()
                        .map(|p| (&p.path, p.identity, &p.link))
                        .eq(saved.chain.iter().map(|p| (&p.path, p.identity, &p.link))),
                "Reviewed master identity changed before link installation"
            );
            saved
        } else {
            create_exclusive(&self.master.path, &text)?
        };
        ensure!(
            saved.text() == text,
            "Master save did not match reviewed text"
        );
        let mut results = Vec::new();
        for (target, choice) in self.targets.into_iter().zip(choices) {
            if *choice == Choice::Skip
                || target.state == TargetState::Linked
                || target.observation.is_none()
            {
                results.push(LinkOutcome {
                    path: target.path,
                    backup: None,
                    linked: target.state == TargetState::Linked,
                    error: None,
                });
                continue;
            }
            let validation = (|| -> Result<()> {
                self.scope.validate(store)?;
                saved.unchanged()?;
                Ok(())
            })();
            let (backup, result) = match validation {
                Ok(()) => install_reviewed_link(
                    &self.master.path,
                    target.observation.as_ref().unwrap(),
                    || Ok(()),
                ),
                Err(error) => (None, Err(error)),
            };
            results.push(LinkOutcome {
                path: target.path,
                backup,
                linked: result.is_ok(),
                error: result.err().map(|e| e.to_string()),
            });
        }
        Ok((self.scope, results))
    }
}
/// The final symlink system call is create-only, never rename-over-target.
/// The hook is private and production always passes a no-op; fixtures can force
/// the exact external-writer window without sleeps or probabilistic races.
fn install_reviewed_link(
    master: &Path,
    expected: &Observation,
    before_install: impl FnOnce() -> Result<()>,
) -> (Option<PathBuf>, Result<()>) {
    let mut backup = None;
    let result = (|| -> Result<()> {
        expected.unchanged()?;
        if expected.present {
            let path = expected.path.with_file_name(format!(
                "{}.coincide-backup-{}",
                expected
                    .path
                    .file_name()
                    .context("Missing target filename")?
                    .to_string_lossy(),
                uuid::Uuid::new_v4()
            ));
            fs::rename(&expected.path, &path)?;
            backup = Some(path.clone());
            let moved = Observation::capture(&path)?;
            ensure!(
                same_item(expected, &moved),
                "Target changed before backup; linking was cancelled"
            );
        }
        before_install()?;
        create_link(master, &expected.path).context(
            "Target appeared or link creation failed; existing target was not overwritten",
        )?;
        ensure!(
            expected.path.canonicalize()? == master.canonicalize()?,
            "Created link does not resolve to the reviewed master"
        );
        Ok(())
    })();
    if let Err(error) = result {
        if let Some(path) = backup.as_ref() {
            // Every restore operation is also create-only. If another writer
            // owns the destination, both its file and our original backup stay.
            if restore_no_replace(path, &expected.path).is_ok() {
                backup = None;
            }
        }
        let error = if let Some(path) = &backup {
            error.context(format!("Original target retained at {}", path.display()))
        } else {
            error
        };
        return (backup, Err(error));
    }
    (backup, Ok(()))
}
fn same_item(expected: &Observation, current: &Observation) -> bool {
    expected.present == current.present
        && expected.link == current.link
        && expected.bytes == current.bytes
        && (!expected.link || expected.resolved == current.resolved)
        && expected
            .chain
            .last()
            .map(|p| (&p.identity, &p.link, p.modified))
            == current
                .chain
                .last()
                .map(|p| (&p.identity, &p.link, p.modified))
}
fn restore_no_replace(backup: &Path, target: &Path) -> Result<()> {
    let observed = Observation::capture(backup)?;
    if observed.link {
        let destination =
            native_file::link_target(backup)?.context("Original link destination unavailable")?;
        #[cfg(unix)]
        std::os::unix::fs::symlink(destination, target)?;
        #[cfg(windows)]
        std::os::windows::fs::symlink_file(destination, target)?;
        #[cfg(not(any(unix, windows)))]
        anyhow::bail!("Link restoration is unavailable");
    } else {
        fs::hard_link(backup, target)?;
    }
    // Preserve the recovery object if an external writer changed either name.
    ensure!(
        Observation::capture(backup)? == observed,
        "Backup changed during restoration"
    );
    let restored = Observation::capture(target)?;
    ensure!(
        observed.bytes == restored.bytes
            && observed.link == restored.link
            && if observed.link {
                observed.chain.last().map(|p| &p.link) == restored.chain.last().map(|p| &p.link)
            } else {
                observed.chain.last().map(|p| p.identity)
                    == restored.chain.last().map(|p| p.identity)
            },
        "Restored target needs review"
    );
    fs::remove_file(backup)?;
    Ok(())
}
fn replace_reviewed_link_with_copy(
    master: &Observation,
    expected: &Observation,
    before_install: impl FnOnce() -> Result<()>,
) -> (Option<PathBuf>, Result<()>) {
    let mut backup = None;
    let result = (|| -> Result<()> {
        master.unchanged()?;
        expected.unchanged()?;
        ensure!(
            classify(master, expected) == TargetState::Linked,
            "Only this master's captured links can become copies"
        );
        let path = expected.path.with_file_name(format!(
            "{}.coincide-backup-{}",
            expected
                .path
                .file_name()
                .context("Missing target name")?
                .to_string_lossy(),
            uuid::Uuid::new_v4()
        ));
        fs::rename(&expected.path, &path)?;
        backup = Some(path.clone());
        ensure!(
            same_item(expected, &Observation::capture(&path)?),
            "Linked file changed before backup"
        );
        before_install()?;
        create_exclusive(&expected.path, master.text())?;
        Ok(())
    })();
    if let Err(error) = result {
        if let Some(path) = &backup {
            if restore_no_replace(path, &expected.path).is_ok() {
                backup = None;
            }
        }
        let error = if let Some(path) = &backup {
            error.context(format!("Original link retained at {}", path.display()))
        } else {
            error
        };
        return (backup, Err(error));
    }
    (backup, Ok(()))
}
fn create_exclusive(path: &Path, text: &str) -> Result<Observation> {
    let mut file = native_file::create_private_file(path)?;
    let identity = native_file::file_identity(&file)?;
    if let Err(error) = (|| -> Result<()> {
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        Ok(())
    })() {
        drop(file);
        if native_file::path_identity(path).ok() == Some(identity) {
            let _ = fs::remove_file(path);
        }
        return Err(error);
    }
    drop(file);
    let saved = Observation::capture(path)?;
    ensure!(
        saved.bytes.as_deref() == Some(text.as_bytes())
            && native_file::path_identity(path)? == identity,
        "Created instructions need review; file changed during creation"
    );
    Ok(saved)
}
fn create_link(master: &Path, target: &Path) -> Result<()> {
    let parent = target
        .parent()
        .context("Missing target parent")?
        .canonicalize()?;
    let master_parent = master
        .parent()
        .context("Missing master parent")?
        .canonicalize()?;
    let master = master_parent.join(master.file_name().context("Missing master name")?);
    let from = parent.components().collect::<Vec<_>>();
    let to = master.components().collect::<Vec<_>>();
    let mut common = 0;
    while common < from.len() && common < to.len() && from[common] == to[common] {
        common += 1;
    }
    let mut relative = PathBuf::new();
    for _ in common..from.len() {
        relative.push("..");
    }
    for part in &to[common..] {
        relative.push(part.as_os_str());
    }
    // Separate Windows volumes require an absolute destination.
    let destination = if common == 0 { master } else { relative };
    #[cfg(unix)]
    std::os::unix::fs::symlink(&destination, target)?;
    #[cfg(windows)]
    std::os::windows::fs::symlink_file(&destination, target)
        .context("Creating instruction links requires Windows Developer Mode or link permission")?;
    #[cfg(not(any(unix, windows)))]
    anyhow::bail!("Instruction links are unavailable on this platform");
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        root: PathBuf,
        store: Store,
        id: String,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "coincide-native-instruction-scope-{}",
                uuid::Uuid::new_v4()
            ));
            native_file::private_directory(&root).unwrap();
            let mut store = Store::open(&root.join("state.sqlite")).unwrap();
            let project = store.create_project(&root, Some("Synthetic")).unwrap();
            Self {
                root,
                store,
                id: project["id"].as_str().unwrap().into(),
            }
        }
        fn global_scope(&self) -> NativeScope {
            let root = self.root.canonicalize().unwrap();
            NativeScope {
                kind: Kind::Global,
                root_identity: native_file::path_identity(&root).unwrap(),
                master: root.join("AGENTS.md"),
                root,
                managed: Vec::new(),
            }
        }
        fn add_managed_accounts(&mut self) -> (String, String, PathBuf, PathBuf) {
            let data = self.store.data_directory().unwrap();
            for path in [data.join("providers"), data.join("providers/codex")] {
                native_file::private_directory(&path).unwrap();
            }
            let a = uuid::Uuid::new_v4().to_string();
            let b = uuid::Uuid::new_v4().to_string();
            let ha = data.join("providers/codex").join(&a);
            let hb = data.join("providers/codex").join(&b);
            native_file::private_directory(&ha).unwrap();
            native_file::private_directory(&hb).unwrap();
            self.store.save_document("rust-codex-login-profiles.json",&json!({"version":1,"accounts":{a.clone():{"name":"Synthetic A","auth":"login","homePath":"/untrusted/ignored"},b.clone():{"name":"Synthetic B","auth":"login"}}})).unwrap();
            (a, b, ha, hb)
        }
        fn scope(&self) -> NativeScope {
            NativeScope::project_native(&self.store, &self.id).unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = self.store.close_for_shutdown();
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    #[cfg(unix)]
    #[::core::prelude::v1::test]
    fn disable_copies_only_owned_links_preserving_master_foreign_links_and_competing_targets() {
        let fixture = Fixture::new();
        let master = fixture.root.join("AGENTS.md");
        let a = fixture.root.join("CLAUDE.md");
        let b = fixture.root.join("GEMINI.md");
        fs::write(&master, "Synthetic master\n").unwrap();
        fs::write(fixture.root.join("foreign.md"), "Foreign").unwrap();
        std::os::unix::fs::symlink("AGENTS.md", &a).unwrap();
        std::os::unix::fs::symlink("foreign.md", &b).unwrap();
        let id = native_file::path_identity(&master).unwrap();
        let plan = fixture.scope().review_native(&fixture.store).unwrap();
        let (_, outcomes) = plan.disable_native(&fixture.store, true).unwrap();
        assert_eq!(outcomes.len(), 1);
        assert!(outcomes[0].error.is_none());
        assert!(!fs::symlink_metadata(&a).unwrap().file_type().is_symlink());
        assert_eq!(fs::read_to_string(&a).unwrap(), "Synthetic master\n");
        assert_eq!(native_file::path_identity(&master).unwrap(), id);
        assert_eq!(fs::read_link(&b).unwrap(), PathBuf::from("foreign.md"));
        fs::remove_file(&a).unwrap();
        std::os::unix::fs::symlink("AGENTS.md", &a).unwrap();
        let observed_master = Observation::capture(&master).unwrap();
        let observed_target = Observation::capture(&a).unwrap();
        let (backup, result) =
            replace_reviewed_link_with_copy(&observed_master, &observed_target, || {
                fs::write(&a, "External competitor")?;
                Ok(())
            });
        assert!(result.is_err());
        assert_eq!(fs::read_to_string(&a).unwrap(), "External competitor");
        assert!(
            fs::symlink_metadata(backup.unwrap())
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }
    #[cfg(unix)]
    #[::core::prelude::v1::test]
    fn global_review_includes_trusted_account_homes_and_preserves_foreign_links_and_defaults() {
        let mut fixture = Fixture::new();
        let (_a, _b, ha, hb) = fixture.add_managed_accounts();
        fs::write(fixture.root.join("AGENTS.md"), "Synthetic master\n").unwrap();
        fs::write(ha.join("AGENTS.md"), "Synthetic account A\n").unwrap();
        fs::write(fixture.root.join("foreign.md"), "Synthetic foreign content").unwrap();
        std::os::unix::fs::symlink(fixture.root.join("foreign.md"), hb.join("AGENTS.md")).unwrap();
        fs::create_dir(fixture.root.join(".codex")).unwrap();
        let scope = fixture.global_scope();
        let files = scope.discover_native(&fixture.store).unwrap();
        assert!(files.iter().any(|f| f.path == ha.join("AGENTS.md")));
        assert!(files.iter().any(|f| {
            f.path
                == fixture
                    .root
                    .canonicalize()
                    .unwrap()
                    .join(".codex/AGENTS.md")
        }));
        let plan = scope.review_native(&fixture.store).unwrap();
        assert_eq!(plan.scope.managed.len(), 2);
        assert!(
            plan.targets
                .iter()
                .any(|t| t.path == ha.join("AGENTS.md") && t.state == TargetState::Differs)
        );
        assert!(
            plan.targets
                .iter()
                .any(|t| t.path == hb.join("AGENTS.md") && t.state == TargetState::ForeignLink)
        );
        let choices = plan
            .targets
            .iter()
            .map(|t| t.state.default_choice())
            .collect::<Vec<_>>();
        let (_, outcomes) = plan
            .apply_native(&fixture.store, &choices, |path, expected, text| {
                assert_eq!(fs::read_to_string(path).unwrap(), expected);
                fs::write(path, text)?;
                Ok(())
            })
            .unwrap();
        assert!(outcomes.iter().all(|o| o.error.is_none()));
        assert_eq!(
            fs::read_link(ha.join("AGENTS.md")).unwrap(),
            PathBuf::from("../../../AGENTS.md")
        );
        assert_eq!(
            fs::read_to_string(ha.join("AGENTS.md")).unwrap(),
            fs::read_to_string(fixture.root.join("AGENTS.md")).unwrap()
        );
        assert!(
            fs::read_to_string(fixture.root.join("AGENTS.md"))
                .unwrap()
                .contains("Synthetic account A")
        );
        assert_eq!(
            fs::read_to_string(hb.join("AGENTS.md")).unwrap(),
            "Synthetic foreign content"
        );
        assert_eq!(
            fs::read_link(hb.join("AGENTS.md")).unwrap(),
            fixture.root.join("foreign.md")
        );
        assert!(
            outcomes
                .iter()
                .find(|o| o.path == ha.join("AGENTS.md"))
                .unwrap()
                .backup
                .as_ref()
                .is_some_and(|p| fs::read_to_string(p).unwrap() == "Synthetic account A\n")
        );
        assert!(!ha.join("auth.json").exists());
        assert!(!hb.join("auth.json").exists());
    }
    #[::core::prelude::v1::test]
    fn removed_account_replaced_home_and_other_store_revoke_managed_review_before_any_effect() {
        for change in ["removed", "replaced", "other-store"] {
            let mut fixture = Fixture::new();
            let (a, _b, ha, _hb) = fixture.add_managed_accounts();
            let master = fixture.root.join("AGENTS.md");
            fs::write(&master, "Synthetic master").unwrap();
            fs::write(ha.join("AGENTS.md"), "Account A").unwrap();
            let plan = fixture
                .global_scope()
                .review_native(&fixture.store)
                .unwrap();
            let choices = plan
                .targets
                .iter()
                .map(|t| t.state.default_choice())
                .collect::<Vec<_>>();
            let mut other = None;
            if change == "removed" {
                let mut configuration = fixture
                    .store
                    .document("rust-codex-login-profiles.json")
                    .unwrap()
                    .unwrap();
                configuration["accounts"]
                    .as_object_mut()
                    .unwrap()
                    .remove(&a);
                fixture
                    .store
                    .save_document("rust-codex-login-profiles.json", &configuration)
                    .unwrap();
            } else if change == "replaced" {
                fs::rename(&ha, ha.with_file_name("old-managed-home")).unwrap();
                native_file::private_directory(&ha).unwrap();
            } else {
                other = Some(Store::open(&fixture.root.join("other.sqlite")).unwrap());
            }
            let owner = other.as_ref().unwrap_or(&fixture.store);
            let error = plan
                .apply_native(owner, &choices, |_, _, _| {
                    anyhow::bail!("must not reach master save")
                })
                .err()
                .unwrap();
            assert!(!error.to_string().contains("must not reach"), "{error}");
            assert_eq!(fs::read_to_string(&master).unwrap(), "Synthetic master");
            if let Some(mut other) = other {
                other.close_for_shutdown().unwrap();
            }
        }
    }
    #[::core::prelude::v1::test]
    fn native_create_is_exclusive_and_discovery_never_creates_missing_files() {
        let mut fixture = Fixture::new();
        let scope = fixture.scope();
        let files = scope.discover_native(&fixture.store).unwrap();
        assert!(files.iter().any(|f| f.name == "AGENTS.md" && !f.exists));
        assert!(!fixture.root.join("AGENTS.md").exists());
        scope
            .create_master_native(&fixture.store, "# Synthetic project\n")
            .unwrap();
        assert!(
            scope
                .create_master_native(&fixture.store, "must not overwrite")
                .is_err()
        );
        assert_eq!(
            fs::read_to_string(scope.master_path()).unwrap(),
            "# Synthetic project\n"
        );
        let metadata = Metadata::from_document(None).unwrap();
        let saved = scope.persist_configuration_native(&mut fixture.store, &metadata, true);
        // Store is explicitly mutable only for native configuration persistence.
        assert!(saved.is_ok());
    }
    #[cfg(unix)]
    #[::core::prelude::v1::test]
    fn reviewed_link_plan_merges_once_keeps_original_backup_and_uses_relative_links() {
        let fixture = Fixture::new();
        fs::write(fixture.root.join("AGENTS.md"), "Master\n").unwrap();
        fs::write(fixture.root.join("CLAUDE.md"), "Claude-only\n").unwrap();
        let plan = fixture.scope().review_native(&fixture.store).unwrap();
        assert!(plan.targets.iter().any(|t| t.state == TargetState::Differs));
        let choices = plan
            .targets
            .iter()
            .map(|t| t.state.default_choice())
            .collect::<Vec<_>>();
        let (scope, outcomes) = plan
            .apply_native(&fixture.store, &choices, |path, expected, text| {
                assert_eq!(fs::read_to_string(path).unwrap(), expected);
                fs::write(path, text)?;
                Ok(())
            })
            .unwrap();
        assert!(outcomes.iter().all(|o| o.error.is_none() && o.linked));
        let backup = outcomes.iter().find_map(|o| o.backup.as_ref()).unwrap();
        assert_eq!(fs::read_to_string(backup).unwrap(), "Claude-only\n");
        assert_eq!(
            fs::read_link(fixture.root.join("CLAUDE.md")).unwrap(),
            PathBuf::from("AGENTS.md")
        );
        assert_eq!(
            fs::read_to_string(scope.master_path()).unwrap(),
            "Master\n\n## From CLAUDE.md\n\nClaude-only\n"
        );
        let plan = scope.review_native(&fixture.store).unwrap();
        assert!(plan.targets.iter().all(|t| t.state == TargetState::Linked));
    }
    #[::core::prelude::v1::test]
    fn stale_target_or_master_aborts_before_any_master_save_or_link() {
        let fixture = Fixture::new();
        fs::write(fixture.root.join("AGENTS.md"), "Master").unwrap();
        let plan = fixture.scope().review_native(&fixture.store).unwrap();
        fs::write(fixture.root.join("CLAUDE.md"), "External writer").unwrap();
        let choices = vec![Choice::UseMaster; plan.targets.len()];
        assert!(
            plan.apply_native(&fixture.store, &choices, |_, _, _| anyhow::bail!(
                "must not reach save"
            ))
            .is_err()
        );
        assert_eq!(
            fs::read_to_string(fixture.root.join("CLAUDE.md")).unwrap(),
            "External writer"
        );
        assert!(!fixture.root.join("GEMINI.md").exists());
        let plan = fixture.scope().review_native(&fixture.store).unwrap();
        fs::write(fixture.root.join("AGENTS.md"), "Changed master").unwrap();
        let choices = vec![Choice::UseMaster; plan.targets.len()];
        assert!(
            plan.apply_native(&fixture.store, &choices, |_, _, _| Ok(()))
                .is_err()
        );
    }
    #[cfg(unix)]
    #[::core::prelude::v1::test]
    fn foreign_and_broken_links_are_skipped_without_replacing_existing_destinations() {
        let fixture = Fixture::new();
        fs::write(fixture.root.join("AGENTS.md"), "Master").unwrap();
        fs::write(fixture.root.join("other.md"), "Foreign").unwrap();
        std::os::unix::fs::symlink("other.md", fixture.root.join("CLAUDE.md")).unwrap();
        std::os::unix::fs::symlink("missing.md", fixture.root.join("GEMINI.md")).unwrap();
        let plan = fixture.scope().review_native(&fixture.store).unwrap();
        assert_eq!(plan.targets[0].state, TargetState::ForeignLink);
        assert_eq!(plan.targets[1].state, TargetState::BrokenLink);
        let choices = plan
            .targets
            .iter()
            .map(|t| t.state.default_choice())
            .collect::<Vec<_>>();
        let (_, outcomes) = plan
            .apply_native(&fixture.store, &choices, |_, _, _| Ok(()))
            .unwrap();
        assert!(outcomes.iter().all(|o| !o.linked && o.backup.is_none()));
        assert_eq!(
            fs::read_link(fixture.root.join("CLAUDE.md")).unwrap(),
            PathBuf::from("other.md")
        );
        assert_eq!(
            fs::read_to_string(fixture.root.join("other.md")).unwrap(),
            "Foreign"
        );
    }
    #[cfg(unix)]
    #[::core::prelude::v1::test]
    fn external_target_appearing_at_install_is_never_overwritten_and_original_backup_survives() {
        let fixture = Fixture::new();
        let master = fixture.root.join("AGENTS.md");
        let target = fixture.root.join("CLAUDE.md");
        fs::write(&master, "Master").unwrap();
        // The missing-target case creates no recovery object at all.
        let expected = Observation::capture(&target).unwrap();
        let (backup, result) = install_reviewed_link(&master, &expected, || {
            fs::write(&target, "External new target")?;
            Ok(())
        });
        assert!(result.is_err());
        assert!(backup.is_none());
        assert_eq!(fs::read_to_string(&target).unwrap(), "External new target");
        // A reviewed existing original has already moved to its backup when a
        // competing writer creates a destination. Neither may be overwritten.
        fs::write(&target, "Original reviewed target").unwrap();
        let expected = Observation::capture(&target).unwrap();
        let (backup, result) = install_reviewed_link(&master, &expected, || {
            fs::write(&target, "Competing target")?;
            Ok(())
        });
        let backup = backup.unwrap();
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("Original target retained")
        );
        assert_eq!(fs::read_to_string(&target).unwrap(), "Competing target");
        assert_eq!(
            fs::read_to_string(&backup).unwrap(),
            "Original reviewed target"
        );
    }
    #[cfg(unix)]
    #[::core::prelude::v1::test]
    fn failed_install_restores_original_without_a_rename_over_destination() {
        let fixture = Fixture::new();
        let master = fixture.root.join("AGENTS.md");
        let target = fixture.root.join("CLAUDE.md");
        fs::write(&master, "Master").unwrap();
        fs::write(&target, "Original").unwrap();
        let identity = native_file::path_identity(&target).unwrap();
        let expected = Observation::capture(&target).unwrap();
        let (backup, result) = install_reviewed_link(&master, &expected, || {
            anyhow::bail!("Synthetic installation refusal")
        });
        assert!(backup.is_none());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("Synthetic installation refusal")
        );
        assert_eq!(fs::read_to_string(&target).unwrap(), "Original");
        assert_eq!(native_file::path_identity(&target).unwrap(), identity);
    }
    #[::core::prelude::v1::test]
    fn imported_configuration_never_changes_scope_until_native_adoption_and_config_cas_preserves_external_edits()
     {
        let mut fixture = Fixture::new();
        let metadata=Metadata::from_document(Some(json!({"projects":{(fixture.root.to_str().unwrap()):{"masterPath":"/synthetic/untrusted/master","isEnabled":true}},"opaque":4}))).unwrap();
        let scope = fixture.scope();
        assert_eq!(
            scope.master_path(),
            fixture.root.canonicalize().unwrap().join("AGENTS.md")
        );
        fixture
            .store
            .save_document("instructions.json", &metadata.document)
            .unwrap();
        let mut changed = metadata.document.clone();
        changed["opaque"] = json!(5);
        fixture
            .store
            .save_document("instructions.json", &changed)
            .unwrap();
        assert!(
            scope
                .persist_configuration_native(&mut fixture.store, &metadata, true)
                .is_err()
        );
        assert_eq!(
            fixture
                .store
                .document("instructions.json")
                .unwrap()
                .unwrap(),
            changed
        );
    }
}
