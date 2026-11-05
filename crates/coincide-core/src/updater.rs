//! Explicit, disabled-by-default Rust preview update checking and private staging.
//!
//! Concrete HTTPS/ZIP adapters are available but never run at construction.
//! No signature bypass, installer, quit integration or startup hook exists.
//! A configured caller supplies transport, decoder, disk probe and platform trust.
//! Decoders emit regular files through `ExtractionSink`; they cannot request links.
//! An operation is a pollable/awaitable background handle. Cancellation/deadlines
//! revoke publication even when an adapter is slow; adapters must also honor the
//! context and HTTP timeouts to stop their own blocking IO promptly.
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs::{self, File, OpenOptions},
    future::Future,
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    pin::Pin,
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicU8, Ordering},
    },
    task::{Context as TaskContext, Poll, Waker},
    thread,
    time::{Duration, Instant},
};
use url::Url;
use uuid::Uuid;

pub const PREVIEW_ID: &str = "com.apoorvdarshan.coincide.rust";
pub const PREVIEW_CHANNEL: &str = "rust-preview";

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    Macos,
    Windows,
    Linux,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Architecture {
    Arm64,
    X86_64,
}
impl Platform {
    fn name(self) -> &'static str {
        match self {
            Self::Macos => "macos",
            Self::Windows => "windows",
            Self::Linux => "linux",
        }
    }
}
impl Architecture {
    fn name(self) -> &'static str {
        match self {
            Self::Arm64 => "arm64",
            Self::X86_64 => "x86_64",
        }
    }
}

#[derive(Clone, Debug)]
pub struct Limits {
    pub metadata_bytes: u64,
    pub archive_bytes: u64,
    pub expanded_bytes: u64,
    pub entry_bytes: u64,
    pub entries: usize,
    pub reserve_disk_bytes: u64,
    pub check_timeout: Duration,
    pub stage_timeout: Duration,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            metadata_bytes: 2 * 1024 * 1024,
            archive_bytes: 512 * 1024 * 1024,
            expanded_bytes: 1024 * 1024 * 1024,
            entry_bytes: 256 * 1024 * 1024,
            entries: 49_999,
            reserve_disk_bytes: 64 * 1024 * 1024,
            check_timeout: Duration::from_secs(30),
            stage_timeout: Duration::from_secs(600),
        }
    }
}
/// Explicit configuration, never inferred from the Swift install or production feed.
#[derive(Clone, Debug)]
pub struct Config {
    pub feed: Url,
    /// Artifact URL must be exactly base/<numeric version>/<platform-specific name>.
    pub artifact_base: Url,
    /// Public trust-anchor identifier understood by the injected verifier, not a secret.
    pub trust_anchor: String,
    pub current_version: String,
    pub platform: Platform,
    pub architecture: Architecture,
    /// Pre-existing owner-private directory; only new UUID jobs are written.
    pub cache_root: PathBuf,
    pub allowed_hosts: BTreeSet<String>,
    pub limits: Limits,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Release {
    pub version: String,
    pub platform: Platform,
    pub architecture: Architecture,
    pub url: String,
    pub size: u64,
    pub sha256: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Feed {
    channel: String,
    bundle_id: String,
    version: String,
    artifacts: Vec<Release>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum SignatureStatus {
    Pending { reason: String },
    Verified,
}
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct Stage {
    pub job: PathBuf,
    pub release: Release,
    pub archive_sha256_verified: bool,
    pub signature: SignatureStatus,
    /// Always false: staging is not installation authorization.
    pub install_authorized: bool,
}
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub enum State {
    Disabled,
    Idle,
    Checking,
    Current,
    Unpublished,
    Available(Release),
    Downloading { received: u64, total: u64 },
    Verifying,
    Staged(Stage),
    Cancelled,
    TimedOut,
    Failed(String),
}

/// Transport must apply policy BEFORE every request/redirect and honor the context
/// during reads. The service independently checks the complete returned redirect chain.
#[derive(Clone)]
pub struct RequestPolicy {
    hosts: BTreeSet<String>,
    pub maximum_bytes: u64,
    pub deadline: Instant,
}
impl RequestPolicy {
    pub fn allows(&self, url: &Url) -> bool {
        url.scheme() == "https"
            && url.username().is_empty()
            && url.password().is_none()
            && url.port().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
            && url.host_str().is_some_and(|host| self.hosts.contains(host))
    }
}
pub struct Response {
    pub status: u16,
    pub content_length: Option<u64>,
    /// Initial URL followed by every redirect, including final URL; at most six.
    pub chain: Vec<Url>,
}
pub trait Transport: Send + Sync {
    fn fetch(
        &self,
        url: &Url,
        policy: &RequestPolicy,
        output: &mut dyn Write,
        context: &OperationContext,
    ) -> Result<Response>;
}
pub trait Extractor: Send + Sync {
    /// Decode the verified archive; emit bytes only through the bounded regular-file sink.
    fn extract(
        &self,
        archive: &Path,
        sink: &mut ExtractionSink<'_>,
        context: &OperationContext,
    ) -> Result<()>;
}
pub trait DiskSpace: Send + Sync {
    /// Must establish owner-only access, including inherited child ACLs on Windows.
    /// The default verifies Unix ownership/mode; other platforms fail closed.
    fn verify_private(&self, directory: &Path) -> Result<()> {
        #[cfg(unix)]
        {
            private_directory(directory)
        }
        #[cfg(not(unix))]
        {
            let _ = directory;
            bail!("Native private staging ACL verification required")
        }
    }
    fn available_bytes(&self, directory: &Path) -> Result<u64>;
}
/// Verifier must independently read candidate metadata and verify against its configured
/// platform anchor. Pending signatures must never be returned as Verified.
#[derive(Clone, Debug)]
pub struct TrustReport {
    pub bundle_id: String,
    pub version: String,
    pub platform: Platform,
    pub architecture: Architecture,
    pub signature: SignatureStatus,
}
pub trait TrustVerifier: Send + Sync {
    fn verify(
        &self,
        candidate: &Path,
        release: &Release,
        anchor: &str,
        context: &OperationContext,
    ) -> Result<TrustReport>;
}
#[derive(Clone)]
pub struct Dependencies {
    pub transport: Arc<dyn Transport>,
    pub extractor: Arc<dyn Extractor>,
    pub disk: Arc<dyn DiskSpace>,
    pub trust: Arc<dyn TrustVerifier>,
}

#[derive(Clone)]
pub struct OperationContext {
    reason: Arc<AtomicU8>,
    deadline: Instant,
    signal: Arc<(Mutex<bool>, Condvar)>,
}
impl OperationContext {
    pub fn checkpoint(&self) -> Result<()> {
        if Instant::now() >= self.deadline {
            self.reason
                .compare_exchange(0, 2, Ordering::SeqCst, Ordering::SeqCst)
                .ok();
        }
        match self.reason.load(Ordering::SeqCst) {
            0 => Ok(()),
            1 => bail!("Update cancelled"),
            _ => bail!("Update timed out"),
        }
    }
    pub fn deadline(&self) -> Instant {
        self.deadline
    }
    fn notify(&self) {
        let (lock, cv) = &*self.signal;
        if let Ok(mut done) = lock.lock() {
            *done = true;
            cv.notify_all();
        }
    }
}
#[derive(Default)]
struct Completion {
    result: Option<State>,
    waker: Option<Waker>,
}
struct Active {
    id: Uuid,
    context: OperationContext,
    completion: Arc<Mutex<Completion>>,
}
struct Inner {
    state: State,
    active: Option<Active>,
}
#[derive(Clone)]
pub struct Updater {
    config: Option<Arc<Config>>,
    dependencies: Option<Dependencies>,
    inner: Arc<Mutex<Inner>>,
}
impl Default for Updater {
    fn default() -> Self {
        Self {
            config: None,
            dependencies: None,
            inner: Arc::new(Mutex::new(Inner {
                state: State::Disabled,
                active: None,
            })),
        }
    }
}
/// May be polled with `try_result`, awaited, or cancelled. Dropping a handle does
/// not authorize any action; the service still owns its bounded stage operation.
pub struct Operation {
    id: Uuid,
    inner: Arc<Mutex<Inner>>,
    completion: Arc<Mutex<Completion>>,
}
fn finish(inner: &mut Inner, id: Uuid, state: State) -> Option<Waker> {
    if inner.active.as_ref().is_none_or(|a| a.id != id) {
        return None;
    }
    let active = inner.active.take().expect("active operation");
    inner.state = state.clone();
    let waker = if let Ok(mut completion) = active.completion.lock() {
        completion.result = Some(state);
        completion.waker.take()
    } else {
        None
    };
    active.context.notify();
    waker
}
fn wake(waker: Option<Waker>) {
    if let Some(waker) = waker {
        waker.wake();
    }
}
impl Operation {
    pub fn try_result(&self) -> Option<State> {
        self.completion.lock().ok()?.result.clone()
    }
    pub fn cancel(&self) -> bool {
        let Ok(mut inner) = self.inner.lock() else {
            return false;
        };
        let Some(active) = inner.active.as_ref().filter(|a| a.id == self.id) else {
            return false;
        };
        active.context.reason.store(1, Ordering::SeqCst);
        let waker = finish(&mut inner, self.id, State::Cancelled);
        drop(inner);
        wake(waker);
        true
    }
}
impl Future for Operation {
    type Output = State;
    fn poll(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<State> {
        let mut completion = self.completion.lock().expect("completion lock");
        if let Some(state) = completion.result.clone() {
            Poll::Ready(state)
        } else {
            completion.waker = Some(cx.waker().clone());
            Poll::Pending
        }
    }
}

impl Updater {
    pub fn configured(mut config: Config, dependencies: Dependencies) -> Result<Self> {
        ensure!(
            !config.trust_anchor.trim().is_empty(),
            "A configured trust anchor is required"
        );
        version(&config.current_version)?;
        ensure!(
            !config.allowed_hosts.is_empty() && config.allowed_hosts.len() <= 16,
            "Explicit allowed hosts required"
        );
        let limits = &config.limits;
        ensure!(
            limits.metadata_bytes > 0
                && limits.metadata_bytes <= 2 * 1024 * 1024
                && limits.archive_bytes > 0
                && limits.archive_bytes <= 512 * 1024 * 1024
                && limits.expanded_bytes > 0
                && limits.expanded_bytes <= 1024 * 1024 * 1024
                && limits.entry_bytes > 0
                && limits.entry_bytes <= 256 * 1024 * 1024
                && limits.entry_bytes <= limits.expanded_bytes
                && limits.entries > 0
                && limits.entries < 50_000
                && !limits.check_timeout.is_zero()
                && limits.check_timeout <= Duration::from_secs(30)
                && !limits.stage_timeout.is_zero()
                && limits.stage_timeout <= Duration::from_secs(600),
            "Invalid update limits"
        );
        let policy = RequestPolicy {
            hosts: config.allowed_hosts.clone(),
            maximum_bytes: limits.metadata_bytes,
            deadline: Instant::now(),
        };
        ensure!(
            policy.allows(&config.feed)
                && policy.allows(&config.artifact_base)
                && config.artifact_base.path().ends_with('/'),
            "Configured feed must be allowlisted credential-free HTTPS"
        );
        // Configuration itself neither creates directories nor starts requests.
        dependencies.disk.verify_private(&config.cache_root)?;
        private_directory(&config.cache_root)?;
        config.cache_root = config.cache_root.canonicalize()?;
        Ok(Self {
            config: Some(Arc::new(config)),
            dependencies: Some(dependencies),
            inner: Arc::new(Mutex::new(Inner {
                state: State::Idle,
                active: None,
            })),
        })
    }
    pub fn state(&self) -> State {
        self.inner.lock().expect("updater state lock").state.clone()
    }
    pub fn check(&self) -> Result<Operation> {
        self.start(false)
    }
    /// Only a release returned by this service's completed explicit check can be staged.
    /// There is intentionally no caller-supplied URL/release parameter.
    pub fn download_available(&self) -> Result<Operation> {
        self.start(true)
    }
    fn start(&self, download: bool) -> Result<Operation> {
        let config = self.config.clone().context("Updates are disabled")?;
        let deps = self.dependencies.clone().context("Updates are disabled")?;
        let id = Uuid::new_v4();
        let completion = Arc::new(Mutex::new(Completion::default()));
        let timeout = if download {
            config.limits.stage_timeout
        } else {
            config.limits.check_timeout
        };
        let context = OperationContext {
            reason: Arc::new(AtomicU8::new(0)),
            deadline: Instant::now() + timeout,
            signal: Arc::new((Mutex::new(false), Condvar::new())),
        };
        let release;
        {
            let mut inner = self
                .inner
                .lock()
                .map_err(|_| anyhow::anyhow!("Updater lock failed"))?;
            ensure!(
                inner.active.is_none(),
                "An update operation is already running"
            );
            release = if download {
                match &inner.state {
                    State::Available(r) => Some(r.clone()),
                    _ => bail!("Explicit successful check required before download"),
                }
            } else {
                None
            };
            inner.state = if let Some(r) = &release {
                State::Downloading {
                    received: 0,
                    total: r.size,
                }
            } else {
                State::Checking
            };
            inner.active = Some(Active {
                id,
                context: context.clone(),
                completion: completion.clone(),
            });
        }
        let handle = Operation {
            id,
            inner: self.inner.clone(),
            completion,
        };
        let watch_inner = self.inner.clone();
        let watch_context = context.clone();
        if thread::Builder::new()
            .name("rust-update-deadline".into())
            .spawn(move || {
                let (lock, cv) = &*watch_context.signal;
                let done = lock.lock().expect("deadline signal lock");
                let (done, _) = cv
                    .wait_timeout_while(
                        done,
                        watch_context
                            .deadline
                            .saturating_duration_since(Instant::now()),
                        |done| !*done,
                    )
                    .expect("deadline signal wait");
                if !*done {
                    drop(done);
                    if let Ok(mut inner) = watch_inner.lock()
                        && inner.active.as_ref().is_some_and(|a| a.id == id)
                    {
                        watch_context.reason.store(2, Ordering::SeqCst);
                        let waker = finish(&mut inner, id, State::TimedOut);
                        drop(inner);
                        wake(waker);
                    }
                }
            })
            .is_err()
        {
            let mut inner = self.inner.lock().expect("updater lock");
            let waker = finish(
                &mut inner,
                id,
                State::Failed("Cannot start deadline worker".into()),
            );
            drop(inner);
            wake(waker);
            return Ok(handle);
        }
        let worker_inner = self.inner.clone();
        if thread::Builder::new()
            .name("rust-update-stage".into())
            .spawn(move || {
                let outcome = if let Some(release) = release {
                    stage(&config, &deps, &worker_inner, id, &context, release)
                } else {
                    check(&config, &deps, &context).map(Some)
                };
                let _ = context.checkpoint();
                if let Ok(mut inner) = worker_inner.lock() {
                    let state = match context.reason.load(Ordering::SeqCst) {
                        1 => State::Cancelled,
                        2 => State::TimedOut,
                        _ => match outcome {
                            Ok(Some(state)) => state,
                            Ok(None) => return,
                            Err(error) => State::Failed(error.to_string()),
                        },
                    };
                    let waker = finish(&mut inner, id, state);
                    drop(inner);
                    wake(waker);
                }
            })
            .is_err()
        {
            let mut inner = self.inner.lock().expect("updater lock");
            let waker = finish(
                &mut inner,
                id,
                State::Failed("Cannot start update worker".into()),
            );
            drop(inner);
            wake(waker);
        }
        Ok(handle)
    }
}

fn version(value: &str) -> Result<[u64; 3]> {
    let parts = value.split('.').collect::<Vec<_>>();
    ensure!(
        parts.len() == 3,
        "Version must have three numeric components"
    );
    let mut result = [0; 3];
    for (index, part) in parts.iter().enumerate() {
        ensure!(
            !part.is_empty()
                && part.bytes().all(|b| b.is_ascii_digit())
                && (part.len() == 1 || !part.starts_with('0')),
            "Ambiguous update version"
        );
        result[index] = part.parse().context("Version overflow")?;
    }
    Ok(result)
}
fn asset_name(config: &Config) -> String {
    format!(
        "Coincide-Rust-{}-{}.zip",
        config.platform.name(),
        config.architecture.name()
    )
}
fn policy(config: &Config, context: &OperationContext, maximum: u64) -> RequestPolicy {
    RequestPolicy {
        hosts: config.allowed_hosts.clone(),
        maximum_bytes: maximum,
        deadline: context.deadline,
    }
}
fn fetch(
    config: &Config,
    deps: &Dependencies,
    url: &Url,
    maximum: u64,
    output: &mut dyn Write,
    context: &OperationContext,
) -> Result<Response> {
    context.checkpoint()?;
    let policy = policy(config, context, maximum);
    ensure!(policy.allows(url), "Request URL rejected");
    let response = deps
        .transport
        .fetch(url, &policy, output, context)
        .map_err(|_| anyhow::anyhow!("Update transport failed"))?;
    context.checkpoint()?;
    ensure!(
        !response.chain.is_empty()
            && response.chain.len() <= 6
            && response.chain.first() == Some(url)
            && response.chain.iter().all(|u| policy.allows(u)),
        "Update redirect chain rejected"
    );
    ensure!(
        response.content_length.is_none_or(|len| len <= maximum),
        "HTTP body too large"
    );
    Ok(response)
}
fn check(config: &Config, deps: &Dependencies, context: &OperationContext) -> Result<State> {
    let mut bytes = Vec::new();
    let mut writer = BoundedWriter {
        target: &mut bytes,
        maximum: config.limits.metadata_bytes,
        written: 0,
        context,
        disk: None,
        progress: None,
    };
    let response = fetch(
        config,
        deps,
        &config.feed,
        config.limits.metadata_bytes,
        &mut writer,
        context,
    )?;
    if response.status == 404 {
        return Ok(State::Unpublished);
    }
    ensure!(response.status == 200, "Update feed HTTP failure");
    if let Some(length) = response.content_length {
        ensure!(length == bytes.len() as u64, "Feed length differs");
    }
    let feed: Feed = serde_json::from_slice(&bytes).context("Invalid Rust preview feed")?;
    ensure!(
        feed.channel == PREVIEW_CHANNEL && feed.bundle_id == PREVIEW_ID,
        "Feed is not the Rust preview channel"
    );
    let target_version = version(&feed.version)?;
    let matches = feed
        .artifacts
        .into_iter()
        .filter(|r| r.platform == config.platform && r.architecture == config.architecture)
        .collect::<Vec<_>>();
    ensure!(
        matches.len() == 1,
        "Exactly one platform/architecture artifact is required"
    );
    let release = matches.into_iter().next().expect("one artifact");
    ensure!(
        release.version == feed.version,
        "Artifact and feed versions differ"
    );
    let url = Url::parse(&release.url).context("Invalid artifact URL")?;
    let expected_url =
        config
            .artifact_base
            .join(&format!("{}/{}", release.version, asset_name(config)))?;
    ensure!(
        policy(config, context, release.size).allows(&url) && url == expected_url,
        "Not the configured platform-specific Rust preview artifact"
    );
    ensure!(
        release.size > 0 && release.size <= config.limits.archive_bytes,
        "Archive size rejected"
    );
    ensure!(
        release.sha256.len() == 64
            && release
                .sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "Invalid SHA-256"
    );
    if target_version <= version(&config.current_version)? {
        return Ok(State::Current);
    }
    Ok(State::Available(release))
}
fn private_directory(path: &Path) -> Result<()> {
    ensure!(path.is_absolute(), "Update cache must be absolute");
    ensure!(
        !path
            .ancestors()
            .any(|p| p.extension().is_some_and(|e| e.eq_ignore_ascii_case("app"))),
        "Update cache cannot be inside an app bundle"
    );
    for ancestor in path.ancestors() {
        ensure!(
            !fs::symlink_metadata(ancestor)?.file_type().is_symlink(),
            "Update cache cannot traverse symlinks"
        );
    }
    ensure!(
        path.is_dir(),
        "Pre-existing update cache directory required"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let m = fs::metadata(path)?;
        ensure!(
            m.permissions().mode() & 0o077 == 0 && m.uid() == unsafe { libc::geteuid() },
            "Update cache must be owned and private (700)"
        );
    }
    Ok(())
}
fn directory(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        fs::DirBuilder::new().mode(0o700).create(path)?;
    }
    #[cfg(not(unix))]
    fs::create_dir(path)?;
    Ok(())
}
fn new_file(path: &Path) -> Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    Ok(options.open(path)?)
}
fn space(deps: &Dependencies, root: &Path, needed: u64) -> Result<()> {
    ensure!(
        deps.disk
            .available_bytes(root)
            .map_err(|_| anyhow::anyhow!("Cannot determine free disk space"))?
            >= needed,
        "Insufficient update staging disk space"
    );
    Ok(())
}
struct Job {
    path: PathBuf,
    keep: bool,
}
impl Drop for Job {
    fn drop(&mut self) {
        if !self.keep {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}
struct BoundedWriter<'a> {
    target: &'a mut dyn Write,
    maximum: u64,
    written: u64,
    context: &'a OperationContext,
    disk: Option<(&'a Dependencies, &'a Path, u64)>,
    progress: Option<(&'a Arc<Mutex<Inner>>, Uuid, u64)>,
}
impl Write for BoundedWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let gate = (|| -> Result<()> {
            self.context.checkpoint()?;
            ensure!(
                (bytes.len() as u64) <= self.maximum.saturating_sub(self.written),
                "Update byte limit exceeded"
            );
            if let Some((deps, path, reserve)) = self.disk {
                space(deps, path, reserve.saturating_add(bytes.len() as u64))?;
            }
            Ok(())
        })();
        gate.map_err(std::io::Error::other)?;
        let size = self.target.write(bytes)?;
        self.written += size as u64;
        if let Some((inner, id, total)) = self.progress
            && let Ok(mut state) = inner.lock()
            && state.active.as_ref().is_some_and(|a| a.id == id)
        {
            state.state = State::Downloading {
                received: self.written,
                total,
            };
        }
        Ok(size)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.context.checkpoint().map_err(std::io::Error::other)?;
        self.target.flush()
    }
}

/// Decoder-facing filesystem boundary: regular files only, exact preview layout,
/// bounded count/expanded bytes/entry size, no traversal, aliases, overwrite or links.
pub struct ExtractionSink<'a> {
    root: PathBuf,
    config: &'a Config,
    deps: &'a Dependencies,
    context: &'a OperationContext,
    seen: BTreeSet<String>,
    expanded: u64,
    entries: usize,
}
impl ExtractionSink<'_> {
    pub fn file(
        &mut self,
        name: &str,
        size: u64,
        executable: bool,
        input: &mut dyn Read,
    ) -> Result<()> {
        self.context.checkpoint()?;
        safe_path(name)?;
        let prefix = if self.config.platform == Platform::Macos {
            "Coincide Rust.app/Contents/"
        } else {
            ""
        };
        ensure!(name.starts_with(prefix), "Wrong archive application root");
        if self.config.platform != Platform::Macos {
            ensure!(
                name.starts_with("bin/") || name.starts_with("resources/"),
                "Wrong portable archive layout"
            );
        }
        ensure!(
            self.seen.insert(name.to_ascii_lowercase()),
            "Duplicate or case-aliased archive path"
        );
        self.entries += 1;
        ensure!(
            self.entries <= self.config.limits.entries,
            "Too many archive files"
        );
        ensure!(
            size <= self.config.limits.entry_bytes
                && size
                    <= self
                        .config
                        .limits
                        .expanded_bytes
                        .saturating_sub(self.expanded),
            "Expanded archive limit exceeded"
        );
        self.expanded += size;
        let path = self.root.join(name);
        let parent = path.parent().context("Archive file parent missing")?;
        let relative = parent.strip_prefix(&self.root)?;
        let mut current = self.root.clone();
        for part in relative.components() {
            current.push(part);
            if !current.exists() {
                directory(&current)?;
            }
            ensure!(
                fs::symlink_metadata(&current)?.is_dir(),
                "Archive parent is not a directory"
            );
        }
        let mut output = new_file(&path)?;
        let mut remaining = size;
        let mut buffer = [0u8; 65536];
        while remaining > 0 {
            self.context.checkpoint()?;
            space(
                self.deps,
                &self.root,
                self.config
                    .limits
                    .reserve_disk_bytes
                    .saturating_add(remaining.min(buffer.len() as u64)),
            )?;
            let limit = remaining.min(buffer.len() as u64) as usize;
            let count = input.read(&mut buffer[..limit])?;
            ensure!(count > 0, "Truncated archive entry");
            output.write_all(&buffer[..count])?;
            remaining -= count as u64;
        }
        ensure!(
            input.read(&mut buffer[..1])? == 0,
            "Oversized archive entry"
        );
        output.sync_all()?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(
                &path,
                fs::Permissions::from_mode(if executable { 0o700 } else { 0o600 }),
            )?;
        }
        #[cfg(not(unix))]
        let _ = executable;
        Ok(())
    }
}
fn stage(
    config: &Config,
    deps: &Dependencies,
    inner: &Arc<Mutex<Inner>>,
    id: Uuid,
    context: &OperationContext,
    release: Release,
) -> Result<Option<State>> {
    deps.disk.verify_private(&config.cache_root)?;
    private_directory(&config.cache_root)?;
    context.checkpoint()?;
    let needed = release
        .size
        .checked_add(config.limits.expanded_bytes)
        .and_then(|n| n.checked_add(config.limits.reserve_disk_bytes))
        .context("Disk budget overflow")?;
    space(deps, &config.cache_root, needed)?;
    let job_path = config.cache_root.join(Uuid::new_v4().to_string());
    directory(&job_path)?;
    let mut job = Job {
        path: job_path,
        keep: false,
    };
    let archive = job.path.join("release.zip");
    let mut file = new_file(&archive)?;
    let mut writer = BoundedWriter {
        target: &mut file,
        maximum: release.size,
        written: 0,
        context,
        disk: Some((deps, &job.path, config.limits.reserve_disk_bytes)),
        progress: Some((inner, id, release.size)),
    };
    let url = Url::parse(&release.url)?;
    let response = fetch(config, deps, &url, release.size, &mut writer, context)?;
    ensure!(
        response.status == 200
            && writer.written == release.size
            && response.content_length.is_none_or(|n| n == release.size),
        "Archive HTTP status or length differs"
    );
    file.sync_all()?;
    drop(file);
    let mut hash = Sha256::new();
    let mut input = File::open(&archive)?;
    let mut buffer = [0u8; 65536];
    loop {
        context.checkpoint()?;
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    ensure!(
        format!("{:x}", hash.finalize()) == release.sha256,
        "Archive SHA-256 differs"
    );
    drop(input);
    {
        let mut state = inner
            .lock()
            .map_err(|_| anyhow::anyhow!("Updater lock failed"))?;
        ensure!(
            state.active.as_ref().is_some_and(|a| a.id == id),
            "Update operation revoked"
        );
        state.state = State::Verifying;
    }
    let contents = job.path.join("contents");
    directory(&contents)?;
    let mut sink = ExtractionSink {
        root: contents.clone(),
        config,
        deps,
        context,
        seen: BTreeSet::new(),
        expanded: 0,
        entries: 0,
    };
    deps.extractor
        .extract(&archive, &mut sink, context)
        .map_err(|_| anyhow::anyhow!("Archive extraction rejected"))?;
    ensure!(sink.entries > 0, "Empty archive");
    let binary_root = if config.platform == Platform::Macos {
        contents.join("Coincide Rust.app/Contents/MacOS")
    } else {
        contents.join("bin")
    };
    for binary in ["coincide-rust", "coincide-rs", "coincide-store"] {
        let path = binary_root.join(if config.platform == Platform::Windows {
            format!("{binary}.exe")
        } else {
            binary.to_owned()
        });
        let metadata = fs::symlink_metadata(path).context("Required preview executable missing")?;
        ensure!(
            metadata.is_file() && metadata.len() > 0,
            "Required preview executable invalid"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if config.platform != Platform::Windows {
                ensure!(
                    metadata.permissions().mode() & 0o111 != 0,
                    "Preview executable permission missing"
                );
            }
        }
    }
    if config.platform == Platform::Macos {
        ensure!(
            fs::symlink_metadata(contents.join("Coincide Rust.app/Contents/Info.plist"))?.is_file(),
            "Required app plist missing"
        );
    }
    context.checkpoint()?;
    let trust = deps
        .trust
        .verify(&contents, &release, &config.trust_anchor, context)
        .map_err(|_| anyhow::anyhow!("Candidate trust verification rejected"))?;
    context.checkpoint()?;
    ensure!(
        trust.bundle_id == PREVIEW_ID
            && trust.version == release.version
            && trust.platform == config.platform
            && trust.architecture == config.architecture,
        "Candidate identity/version/architecture differs"
    );
    let staged = Stage {
        job: job.path.clone(),
        release,
        archive_sha256_verified: true,
        signature: trust.signature,
        install_authorized: false,
    };
    let receipt = new_file(&job.path.join("stage.json"))?;
    serde_json::to_writer(&receipt, &staged)?;
    receipt.sync_all()?;
    // Publication and cancellation serialize on the same lock. A stale worker cannot
    // publish or retain a stage after its handle has cancelled/timed out.
    let mut state = inner
        .lock()
        .map_err(|_| anyhow::anyhow!("Updater lock failed"))?;
    context.checkpoint()?;
    ensure!(
        state.active.as_ref().is_some_and(|a| a.id == id),
        "Update operation revoked"
    );
    job.keep = true;
    let waker = finish(&mut state, id, State::Staged(staged));
    drop(state);
    wake(waker);
    Ok(None)
}

/// Crate-private owned snapshot for the installer. Not constructible from IPC flags
/// or a deserialized Stage; its original archive is rehashed and decoded afresh.
pub(crate) struct InstallCandidate {
    _job: Job,
    pub(crate) bundle: PathBuf,
    pub(crate) release: Release,
    pub(crate) current_version: String,
    pub(crate) anchor: String,
}
impl Updater {
    pub(crate) fn fresh_install_candidate(&self) -> Result<InstallCandidate> {
        let config = self.config.as_ref().context("Updates are disabled")?;
        let deps = self.dependencies.as_ref().context("Updates are disabled")?;
        ensure!(
            config.platform == Platform::Macos,
            "Native bundle installation is unavailable on this platform"
        );
        let stage = {
            let inner = self
                .inner
                .lock()
                .map_err(|_| anyhow::anyhow!("Updater lock failed"))?;
            ensure!(inner.active.is_none(), "Update operation still running");
            match &inner.state {
                State::Staged(stage) => stage.clone(),
                _ => bail!("A completed staged preview update is required"),
            }
        };
        // Derive the archive path from the service-owned cache and UUID, never a request path.
        let name = stage
            .job
            .file_name()
            .and_then(|p| p.to_str())
            .context("Invalid stage job")?;
        ensure!(
            Uuid::parse_str(name).is_ok() && stage.job == config.cache_root.join(name),
            "Stage job is outside the configured cache"
        );
        deps.disk.verify_private(&stage.job)?;
        private_directory(&stage.job)?;
        let context = OperationContext {
            reason: Arc::new(AtomicU8::new(0)),
            deadline: Instant::now() + config.limits.stage_timeout,
            signal: Arc::new((Mutex::new(false), Condvar::new())),
        };
        let original = stage.job.join("release.zip");
        let metadata = fs::symlink_metadata(&original)?;
        ensure!(
            metadata.is_file() && metadata.len() == stage.release.size,
            "Staged archive identity/size changed"
        );
        space(
            deps,
            &config.cache_root,
            stage
                .release
                .size
                .checked_add(config.limits.expanded_bytes)
                .and_then(|n| n.checked_add(config.limits.reserve_disk_bytes))
                .context("Disk budget overflow")?,
        )?;
        let path = config.cache_root.join(Uuid::new_v4().to_string());
        directory(&path)?;
        let job = Job { path, keep: false };
        let archive = job.path.join("release.zip");
        let mut source = File::open(&original)?;
        let mut target = new_file(&archive)?;
        let mut hash = Sha256::new();
        let mut count = 0u64;
        let mut buffer = [0u8; 65536];
        loop {
            context.checkpoint()?;
            let size = source.read(&mut buffer)?;
            if size == 0 {
                break;
            }
            count = count
                .checked_add(size as u64)
                .context("Archive byte count overflow")?;
            ensure!(count <= stage.release.size, "Staged archive grew");
            space(
                deps,
                &job.path,
                config.limits.reserve_disk_bytes.saturating_add(size as u64),
            )?;
            target.write_all(&buffer[..size])?;
            hash.update(&buffer[..size]);
        }
        ensure!(
            count == stage.release.size && format!("{:x}", hash.finalize()) == stage.release.sha256,
            "Staged archive digest changed"
        );
        target.sync_all()?;
        drop(target);
        drop(source);
        let contents = job.path.join("contents");
        directory(&contents)?;
        let mut sink = ExtractionSink {
            root: contents.clone(),
            config,
            deps,
            context: &context,
            seen: BTreeSet::new(),
            expanded: 0,
            entries: 0,
        };
        deps.extractor
            .extract(&archive, &mut sink, &context)
            .map_err(|_| anyhow::anyhow!("Install archive extraction rejected"))?;
        ensure!(sink.entries > 0, "Install archive is empty");
        context.checkpoint()?;
        let inner = self
            .inner
            .lock()
            .map_err(|_| anyhow::anyhow!("Updater lock failed"))?;
        ensure!(
            inner.active.is_none() && inner.state == State::Staged(stage.clone()),
            "Staged selection changed during install preparation"
        );
        Ok(InstallCandidate {
            bundle: contents.join("Coincide Rust.app"),
            release: stage.release,
            current_version: config.current_version.clone(),
            anchor: config.trust_anchor.clone(),
            _job: job,
        })
    }
}

/// Concrete HTTPS transport. No requests occur until an explicit service operation.
/// Uses rustls/webpki defaults, no ambient proxies/cookies, no automatic redirects,
/// no content decompression and a shrinking global deadline across every hop.
pub struct UreqTransport;
impl Transport for UreqTransport {
    fn fetch(
        &self,
        url: &Url,
        policy: &RequestPolicy,
        output: &mut dyn Write,
        context: &OperationContext,
    ) -> Result<Response> {
        let mut current = url.clone();
        let mut chain = Vec::new();
        loop {
            context.checkpoint()?;
            ensure!(policy.allows(&current), "HTTPS destination rejected");
            ensure!(chain.len() < 6, "Too many update redirects");
            chain.push(current.clone());
            let remaining = policy.deadline.saturating_duration_since(Instant::now());
            ensure!(!remaining.is_zero(), "Update timed out");
            let config = ureq::Agent::config_builder()
                .https_only(true)
                .proxy(None)
                .max_redirects(0)
                .http_status_as_error(false)
                .timeout_global(Some(remaining))
                .timeout_connect(Some(remaining.min(Duration::from_secs(10))))
                .timeout_resolve(Some(remaining.min(Duration::from_secs(10))))
                .timeout_recv_response(Some(remaining.min(Duration::from_secs(15))))
                .timeout_recv_body(Some(remaining.min(Duration::from_secs(15))))
                .build();
            let agent = ureq::Agent::new_with_config(config);
            let mut response = agent
                .get(current.as_str())
                .header("Accept-Encoding", "identity")
                .header("Accept", "application/json, application/zip")
                .header("User-Agent", "Coincide-Rust-Preview-Updater")
                .call()
                .map_err(|error| {
                    if matches!(&error, ureq::Error::Timeout(_))
                        || matches!(&error, ureq::Error::Io(io) if io.kind() == std::io::ErrorKind::TimedOut) {
                        context.reason.compare_exchange(0,2,Ordering::SeqCst,Ordering::SeqCst).ok();
                    }
                    anyhow::anyhow!("HTTPS request failed")
                })?;
            let status = response.status().as_u16();
            if [301, 302, 303, 307, 308].contains(&status) {
                let location = response
                    .headers()
                    .get("location")
                    .context("Redirect location missing")?
                    .to_str()?;
                current = current.join(location)?;
                ensure!(policy.allows(&current), "Update redirect rejected");
                continue;
            }
            ensure!(
                response
                    .headers()
                    .get("content-encoding")
                    .is_none_or(|v| v == "identity"),
                "Encoded update response rejected"
            );
            let length = response
                .headers()
                .get("content-length")
                .map(|v| -> Result<u64> { Ok(v.to_str()?.parse()?) })
                .transpose()?;
            ensure!(
                length.is_none_or(|n| n <= policy.maximum_bytes),
                "Update body length rejected"
            );
            let mut reader = response.body_mut().as_reader();
            let mut received = 0u64;
            let mut buffer = [0u8; 65536];
            loop {
                context.checkpoint()?;
                let remaining = policy.maximum_bytes.saturating_sub(received);
                let limit = remaining.min(buffer.len() as u64) as usize;
                // A one-byte probe detects over-limit chunked bodies without emitting that byte.
                let count = reader
                    .read(&mut buffer[..limit.max(1)])
                    .inspect_err(|error| {
                        if error.kind() == std::io::ErrorKind::TimedOut
                            || error
                                .get_ref()
                                .and_then(|inner| inner.downcast_ref::<ureq::Error>())
                                .is_some_and(|inner| matches!(inner, ureq::Error::Timeout(_)))
                        {
                            context
                                .reason
                                .compare_exchange(0, 2, Ordering::SeqCst, Ordering::SeqCst)
                                .ok();
                        }
                    })?;
                if count == 0 {
                    break;
                }
                ensure!(count as u64 <= remaining, "Update body exceeds bound");
                output.write_all(&buffer[..count])?;
                received += count as u64;
            }
            ensure!(
                length.is_none_or(|n| n == received),
                "HTTPS response length differs"
            );
            context.checkpoint()?;
            return Ok(Response {
                status,
                content_length: length,
                chain,
            });
        }
    }
}

/// OS free-space probe for Unix. Windows deliberately requires an injected native
/// disk/ACL implementation; do not assume a public directory is owner-private.
pub struct SystemDiskSpace;
impl DiskSpace for SystemDiskSpace {
    fn available_bytes(&self, directory: &Path) -> Result<u64> {
        #[cfg(unix)]
        {
            use std::os::unix::ffi::OsStrExt;
            let path = std::ffi::CString::new(directory.as_os_str().as_bytes())?;
            let mut info = std::mem::MaybeUninit::<libc::statvfs>::uninit();
            // SAFETY: valid terminated path and writable statvfs output storage.
            ensure!(
                unsafe { libc::statvfs(path.as_ptr(), info.as_mut_ptr()) } == 0,
                "Cannot read free disk space"
            );
            // SAFETY: statvfs succeeded and initialized the output.
            let info = unsafe { info.assume_init() };
            Ok(
                (u128::from(info.f_bavail) * u128::from(info.f_frsize)).min(u64::MAX as u128)
                    as u64,
            )
        }
        #[cfg(not(unix))]
        {
            let _ = directory;
            bail!("A native disk/ACL probe is required on this platform")
        }
    }
}

/// Bounded Stored/Deflate ZIP decoder; no filesystem extraction API is delegated
/// to the ZIP crate. A small central-directory preflight bounds parser allocation,
/// rejects ZIP64, links/encryption/aliases, and compares local/central names first.
pub struct ZipExtractor;
struct ZipEntry {
    name: String,
    size: u64,
    directory: bool,
    mode: u32,
}
fn u16le(bytes: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([bytes[offset], bytes[offset + 1]])
}
fn u32le(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().expect("four bytes"))
}
fn read_zip_at(
    file: &mut File,
    offset: u64,
    size: usize,
    context: &OperationContext,
) -> Result<Vec<u8>> {
    use std::io::{Seek, SeekFrom};
    context.checkpoint()?;
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = vec![0; size];
    file.read_exact(&mut bytes)?;
    Ok(bytes)
}
fn safe_path(name: &str) -> Result<()> {
    ensure!(
        !name.is_empty()
            && name.len() <= 4096
            && !name.contains(['\\', ':'])
            && name.chars().all(|c| c.is_ascii() && !c.is_ascii_control())
            && name
                .split('/')
                .all(|p| !p.is_empty() && p != "." && p != ".." && !p.ends_with(['.', ' ']))
            && Path::new(name)
                .components()
                .all(|p| matches!(p, Component::Normal(_))),
        "Unsafe archive path"
    );
    for part in name.split('/') {
        let stem = part.split('.').next().unwrap_or("").to_ascii_uppercase();
        ensure!(
            ![
                "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7",
                "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8",
                "LPT9"
            ]
            .contains(&stem.as_str()),
            "Reserved archive path"
        );
    }
    Ok(())
}
fn zip_preflight(
    file: &mut File,
    limits: &Limits,
    context: &OperationContext,
) -> Result<Vec<ZipEntry>> {
    let length = file.metadata()?.len();
    ensure!(
        (22..=limits.archive_bytes).contains(&length),
        "Invalid ZIP length"
    );
    let tail_size = length.min(65557) as usize;
    let tail = read_zip_at(file, length - tail_size as u64, tail_size, context)?;
    let end = (0..=tail.len() - 22)
        .rev()
        .find(|i| {
            u32le(&tail, *i) == 0x06054b50 && *i + 22 + u16le(&tail, *i + 20) as usize == tail.len()
        })
        .context("ZIP end record missing")?;
    ensure!(
        u16le(&tail, end + 4) == 0
            && u16le(&tail, end + 6) == 0
            && u16le(&tail, end + 8) == u16le(&tail, end + 10),
        "Split ZIP rejected"
    );
    let count = u16le(&tail, end + 10) as usize;
    ensure!(
        count > 0 && count <= limits.entries && count < 65535,
        "ZIP entry count rejected"
    );
    let start = u32le(&tail, end + 16) as u64;
    let central_size = u32le(&tail, end + 12) as u64;
    let central_end = length - tail_size as u64 + end as u64;
    ensure!(
        start + central_size == central_end,
        "ZIP central directory bounds differ"
    );
    let mut cursor = start;
    let mut names = BTreeSet::new();
    let mut entries = Vec::with_capacity(count);
    let mut expanded = 0u64;
    for _ in 0..count {
        ensure!(cursor + 46 <= central_end, "Truncated ZIP directory");
        let header = read_zip_at(file, cursor, 46, context)?;
        ensure!(
            u32le(&header, 0) == 0x02014b50,
            "Invalid ZIP central header"
        );
        let flags = u16le(&header, 8);
        let method = u16le(&header, 10);
        let compressed = u32le(&header, 20) as u64;
        let size = u32le(&header, 24) as u64;
        let name_len = u16le(&header, 28) as usize;
        let extra_len = u16le(&header, 30) as usize;
        let comment_len = u16le(&header, 32) as u64;
        let local = u32le(&header, 42) as u64;
        ensure!(
            flags & 0x41 == 0
                && [0, 8].contains(&method)
                && u16le(&header, 34) == 0
                && name_len > 0
                && name_len <= 4096
                && size < 0xffffffff
                && compressed < 0xffffffff
                && local < 0xffffffff
                && size <= limits.entry_bytes
                && cursor + 46 + name_len as u64 + extra_len as u64 + comment_len <= central_end,
            "Unsupported ZIP entry"
        );
        let name_bytes = read_zip_at(file, cursor + 46, name_len, context)?;
        let raw = std::str::from_utf8(&name_bytes)?;
        let directory = raw.ends_with('/');
        let name = raw.strip_suffix('/').unwrap_or(raw).to_owned();
        safe_path(&name)?;
        ensure!(
            names.insert(name.to_ascii_lowercase()),
            "Duplicate ZIP path"
        );
        let mode = u32le(&header, 38) >> 16;
        let kind = mode & 0o170000;
        ensure!(
            [0, 0o040000, 0o100000].contains(&kind)
                && (!directory || size == 0)
                && (directory || kind != 0o040000),
            "ZIP links/special files rejected"
        );
        let extra = read_zip_at(file, cursor + 46 + name_len as u64, extra_len, context)?;
        let mut i = 0;
        while i < extra.len() {
            ensure!(i + 4 <= extra.len(), "Truncated ZIP extra field");
            let tag = u16le(&extra, i);
            let n = u16le(&extra, i + 2) as usize;
            ensure!(
                tag != 1 && i + 4 + n <= extra.len(),
                "ZIP64 or invalid extra field rejected"
            );
            i += 4 + n;
        }
        ensure!(local + 30 <= start, "ZIP local offset rejected");
        let local_header = read_zip_at(file, local, 30, context)?;
        ensure!(
            u32le(&local_header, 0) == 0x04034b50
                && u16le(&local_header, 6) == flags
                && u16le(&local_header, 8) == method
                && u16le(&local_header, 26) as usize == name_len,
            "ZIP local header differs"
        );
        ensure!(
            local + 30 + name_len as u64 + u16le(&local_header, 28) as u64 + compressed <= start,
            "ZIP payload bounds rejected"
        );
        ensure!(
            read_zip_at(file, local + 30, name_len, context)? == name_bytes,
            "ZIP local filename differs"
        );
        expanded = expanded.checked_add(size).context("ZIP size overflow")?;
        ensure!(
            expanded <= limits.expanded_bytes,
            "ZIP expansion bound exceeded"
        );
        entries.push(ZipEntry {
            name,
            size,
            directory,
            mode,
        });
        cursor += 46 + name_len as u64 + extra_len as u64 + comment_len;
    }
    ensure!(cursor == central_end, "Unexpected ZIP directory bytes");
    let file_names = entries
        .iter()
        .filter(|e| !e.directory)
        .map(|e| e.name.to_ascii_lowercase())
        .collect::<BTreeSet<_>>();
    for entry in &entries {
        let mut parent = Path::new(&entry.name).parent();
        while let Some(path) = parent {
            if path.as_os_str().is_empty() {
                break;
            }
            ensure!(
                !file_names.contains(&path.to_string_lossy().to_ascii_lowercase()),
                "ZIP child beneath file"
            );
            parent = path.parent();
        }
    }
    Ok(entries)
}
impl Extractor for ZipExtractor {
    fn extract(
        &self,
        archive: &Path,
        sink: &mut ExtractionSink<'_>,
        context: &OperationContext,
    ) -> Result<()> {
        ensure!(
            fs::symlink_metadata(archive)?.is_file(),
            "Private regular archive required"
        );
        let mut file = File::open(archive)?;
        let entries = zip_preflight(&mut file, &sink.config.limits, context)?;
        let config = zip::read::Config {
            archive_offset: zip::read::ArchiveOffset::Known(0),
        };
        let mut archive = zip::ZipArchive::with_config(config, file)?;
        ensure!(
            archive.len() == entries.len(),
            "ZIP decoder entry count differs"
        );
        for (index, entry) in entries.iter().enumerate() {
            context.checkpoint()?;
            let mut member = archive.by_index(index)?;
            ensure!(
                member.name_raw() == entry.name.as_bytes()
                    || (entry.directory
                        && member.name_raw() == format!("{}/", entry.name).as_bytes()),
                "ZIP decoder filename differs"
            );
            ensure!(
                !member.encrypted() && !member.is_symlink() && member.size() == entry.size,
                "ZIP decoder metadata differs"
            );
            if entry.directory {
                // Only ancestors of the declared preview layout may occur as explicit directories.
                let allowed = if sink.config.platform == Platform::Macos {
                    entry.name == "Coincide Rust.app"
                        || entry.name == "Coincide Rust.app/Contents"
                        || entry.name.starts_with("Coincide Rust.app/Contents/")
                } else {
                    entry.name == "bin"
                        || entry.name == "resources"
                        || entry.name.starts_with("bin/")
                        || entry.name.starts_with("resources/")
                };
                ensure!(allowed, "Wrong archive directory root");
                continue;
            }
            sink.file(
                &entry.name,
                entry.size,
                entry.mode & 0o111 != 0,
                &mut member,
            )?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::{
        io::Cursor,
        sync::atomic::{AtomicBool, AtomicU64, AtomicUsize},
    };
    use tempfile::TempDir;
    use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};

    struct FakeHttp {
        feed: Mutex<Vec<u8>>,
        archive: Mutex<Vec<u8>>,
        status: AtomicUsize,
        calls: AtomicUsize,
        hold_archive: AtomicBool,
        archive_entered: AtomicBool,
        redirect: Mutex<Option<Url>>,
    }
    impl Transport for FakeHttp {
        fn fetch(
            &self,
            url: &Url,
            _policy: &RequestPolicy,
            out: &mut dyn Write,
            context: &OperationContext,
        ) -> Result<Response> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let feed = url.path().ends_with("feed.json");
            if !feed {
                self.archive_entered.store(true, Ordering::SeqCst);
                // Deliberately uncooperative IO fixture: cancellation/deadline must
                // revoke publication even before this fake read is released.
                while self.hold_archive.load(Ordering::SeqCst) {
                    thread::sleep(Duration::from_millis(1));
                }
            }
            context.checkpoint()?;
            let bytes = if feed {
                self.feed.lock().unwrap().clone()
            } else {
                self.archive.lock().unwrap().clone()
            };
            for chunk in bytes.chunks(7) {
                out.write_all(chunk)?;
            }
            let mut chain = vec![url.clone()];
            if let Some(url) = self.redirect.lock().unwrap().clone() {
                chain.push(url);
            }
            Ok(Response {
                status: if feed {
                    self.status.load(Ordering::SeqCst) as u16
                } else {
                    200
                },
                content_length: Some(bytes.len() as u64),
                chain,
            })
        }
    }
    struct FixtureDisk(AtomicU64);
    impl DiskSpace for FixtureDisk {
        fn available_bytes(&self, _: &Path) -> Result<u64> {
            Ok(self.0.load(Ordering::SeqCst))
        }
        fn verify_private(&self, directory: &Path) -> Result<()> {
            // TempDir is isolated test state. This fake does not establish a
            // production Windows ACL implementation.
            private_directory(directory)
        }
    }
    struct CountDecoder(AtomicUsize);
    impl Extractor for CountDecoder {
        fn extract(
            &self,
            path: &Path,
            sink: &mut ExtractionSink<'_>,
            context: &OperationContext,
        ) -> Result<()> {
            self.0.fetch_add(1, Ordering::SeqCst);
            ZipExtractor.extract(path, sink, context)
        }
    }
    struct FixtureTrust {
        calls: AtomicUsize,
        reject: AtomicBool,
        verified: AtomicBool,
        wrong_identity: AtomicBool,
    }
    impl TrustVerifier for FixtureTrust {
        fn verify(
            &self,
            path: &Path,
            _: &Release,
            anchor: &str,
            context: &OperationContext,
        ) -> Result<TrustReport> {
            context.checkpoint()?;
            ensure!(anchor == "fixture-anchor", "Wrong configured anchor");
            self.calls.fetch_add(1, Ordering::SeqCst);
            ensure!(!self.reject.load(Ordering::SeqCst), "Synthetic rejection");
            let metadata: Value = serde_json::from_slice(&fs::read(
                path.join("Coincide Rust.app/Contents/Info.plist"),
            )?)?;
            Ok(TrustReport {
                bundle_id: if self.wrong_identity.load(Ordering::SeqCst) {
                    "com.apoorvdarshan.coincide".into()
                } else {
                    metadata["bundle_id"]
                        .as_str()
                        .context("Missing fixture identity")?
                        .into()
                },
                version: metadata["version"]
                    .as_str()
                    .context("Missing fixture version")?
                    .into(),
                platform: serde_json::from_value(metadata["platform"].clone())?,
                architecture: serde_json::from_value(metadata["architecture"].clone())?,
                signature: if self.verified.load(Ordering::SeqCst) {
                    SignatureStatus::Verified
                } else {
                    SignatureStatus::Pending {
                        reason: "Synthetic platform signature pending".into(),
                    }
                },
            })
        }
    }
    struct Fixture {
        root: TempDir,
        service: Updater,
        http: Arc<FakeHttp>,
        disk: Arc<FixtureDisk>,
        decoder: Arc<CountDecoder>,
        trust: Arc<FixtureTrust>,
    }
    fn archive(extra: Option<(&str, &[u8])>, method: CompressionMethod) -> Vec<u8> {
        let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
        let options = SimpleFileOptions::default()
            .compression_method(method)
            .unix_permissions(0o755);
        for binary in ["coincide-rust", "coincide-rs", "coincide-store"] {
            zip.start_file(
                format!("Coincide Rust.app/Contents/MacOS/{binary}"),
                options,
            )
            .unwrap();
            zip.write_all(b"synthetic executable bytes; never run")
                .unwrap();
        }
        zip.start_file(
            "Coincide Rust.app/Contents/Info.plist",
            options.unix_permissions(0o644),
        )
        .unwrap();
        // JSON fixture metadata is deliberately not a real signed app plist.
        zip.write_all(&serde_json::to_vec(&json!({"bundle_id":PREVIEW_ID,"version":"0.2.0","platform":"macos","architecture":"arm64"})).unwrap()).unwrap();
        if let Some((name, bytes)) = extra {
            zip.start_file(name, options).unwrap();
            zip.write_all(bytes).unwrap();
        }
        zip.finish().unwrap().into_inner()
    }
    fn feed(bytes: &[u8]) -> Value {
        json!({"channel":PREVIEW_CHANNEL,"bundle_id":PREVIEW_ID,"version":"0.2.0",
        "artifacts":[{"version":"0.2.0","platform":"macos","architecture":"arm64",
        "url":"https://updates.example/rust-preview/0.2.0/Coincide-Rust-macos-arm64.zip",
        "size":bytes.len(),"sha256":format!("{:x}",Sha256::digest(bytes))}]})
    }
    impl Fixture {
        fn new() -> Self {
            Self::with_timeout(Duration::from_secs(5))
        }
        fn with_timeout(timeout: Duration) -> Self {
            // Tempfile directories otherwise inherit the default mkdir mode/umask;
            // request an owner-only cache at creation, matching the production gate.
            let mut builder = tempfile::Builder::new();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                builder.permissions(fs::Permissions::from_mode(0o700));
            }
            let root = builder.tempdir().unwrap();
            let bytes = archive(None, CompressionMethod::Deflated);
            let http = Arc::new(FakeHttp {
                feed: Mutex::new(serde_json::to_vec(&feed(&bytes)).unwrap()),
                archive: Mutex::new(bytes),
                status: AtomicUsize::new(200),
                calls: AtomicUsize::new(0),
                hold_archive: AtomicBool::new(false),
                archive_entered: AtomicBool::new(false),
                redirect: Mutex::new(None),
            });
            let disk = Arc::new(FixtureDisk(AtomicU64::new(1_000_000)));
            let decoder = Arc::new(CountDecoder(AtomicUsize::new(0)));
            let trust = Arc::new(FixtureTrust {
                calls: AtomicUsize::new(0),
                reject: AtomicBool::new(false),
                verified: AtomicBool::new(false),
                wrong_identity: AtomicBool::new(false),
            });
            let config = Config {
                feed: Url::parse("https://updates.example/rust-preview/feed.json").unwrap(),
                artifact_base: Url::parse("https://updates.example/rust-preview/").unwrap(),
                trust_anchor: "fixture-anchor".into(),
                current_version: "0.1.0".into(),
                platform: Platform::Macos,
                architecture: Architecture::Arm64,
                cache_root: root.path().canonicalize().unwrap(),
                allowed_hosts: BTreeSet::from(["updates.example".into()]),
                limits: Limits {
                    metadata_bytes: 16_384,
                    archive_bytes: 65_536,
                    expanded_bytes: 16_384,
                    entry_bytes: 8_192,
                    entries: 20,
                    reserve_disk_bytes: 1024,
                    check_timeout: Duration::from_secs(5),
                    stage_timeout: timeout,
                },
            };
            let service = Updater::configured(
                config,
                Dependencies {
                    transport: http.clone(),
                    extractor: decoder.clone(),
                    disk: disk.clone(),
                    trust: trust.clone(),
                },
            )
            .unwrap();
            Self {
                root,
                service,
                http,
                disk,
                decoder,
                trust,
            }
        }
        fn change_feed(&self, change: impl FnOnce(&mut Value)) {
            let mut value: Value = serde_json::from_slice(&self.http.feed.lock().unwrap()).unwrap();
            change(&mut value);
            *self.http.feed.lock().unwrap() = serde_json::to_vec(&value).unwrap();
        }
        fn set_archive(&self, bytes: Vec<u8>) {
            *self.http.feed.lock().unwrap() = serde_json::to_vec(&feed(&bytes)).unwrap();
            *self.http.archive.lock().unwrap() = bytes;
        }
        fn available(&self) {
            assert!(matches!(
                wait(self.service.check().unwrap()),
                State::Available(_)
            ));
        }
        fn failed_stage(&self) {
            self.available();
            assert!(matches!(
                wait(self.service.download_available().unwrap()),
                State::Failed(_)
            ));
            assert!(fs::read_dir(self.root.path()).unwrap().next().is_none());
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            self.http.hold_archive.store(false, Ordering::SeqCst);
        }
    }
    fn wait(operation: Operation) -> State {
        until(|| operation.try_result().is_some());
        operation.try_result().unwrap()
    }
    fn until(mut predicate: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(3);
        while !predicate() {
            assert!(Instant::now() < deadline, "Fixture wait timed out");
            thread::sleep(Duration::from_millis(1));
        }
    }

    #[test]
    fn disabled_and_configuration_never_perform_startup_network() {
        let disabled = Updater::default();
        assert_eq!(disabled.state(), State::Disabled);
        assert!(disabled.check().is_err());
        assert!(disabled.download_available().is_err());
        let fixture = Fixture::new();
        assert_eq!(fixture.service.state(), State::Idle);
        assert_eq!(fixture.http.calls.load(Ordering::SeqCst), 0);
        assert!(fixture.service.download_available().is_err());
        assert!(fs::read_dir(fixture.root.path()).unwrap().next().is_none());
    }
    #[test]
    fn explicit_check_then_download_persists_hash_verified_signature_pending_stage() {
        let f = Fixture::new();
        f.available();
        assert_eq!(f.http.calls.load(Ordering::SeqCst), 1);
        assert!(fs::read_dir(f.root.path()).unwrap().next().is_none());
        let State::Staged(stage) = wait(f.service.download_available().unwrap()) else {
            panic!("stage failed: {:?}", f.service.state());
        };
        assert!(stage.archive_sha256_verified);
        assert!(matches!(stage.signature, SignatureStatus::Pending { .. }));
        assert!(!stage.install_authorized);
        let bytes = fs::read(stage.job.join("release.zip")).unwrap();
        assert_eq!(
            format!("{:x}", Sha256::digest(&bytes)),
            stage.release.sha256
        );
        let receipt: Value =
            serde_json::from_slice(&fs::read(stage.job.join("stage.json")).unwrap()).unwrap();
        assert_eq!(receipt["install_authorized"], false);
        assert_eq!(f.decoder.0.load(Ordering::SeqCst), 1);
        assert_eq!(f.trust.calls.load(Ordering::SeqCst), 1);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&stage.job).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(
                fs::metadata(stage.job.join("release.zip"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
    }
    #[test]
    fn verified_fixture_signature_still_does_not_authorize_install() {
        let f = Fixture::new();
        f.trust.verified.store(true, Ordering::SeqCst);
        f.available();
        let State::Staged(stage) = wait(f.service.download_available().unwrap()) else {
            panic!("missing stage")
        };
        assert_eq!(stage.signature, SignatureStatus::Verified);
        assert!(!stage.install_authorized);
    }
    #[test]
    fn refuses_swift_channel_artifact_wrong_architecture_and_duplicate_target() {
        for case in 0..7 {
            let f = Fixture::new();
            f.change_feed(|feed| match case {
                0 => feed["bundle_id"] = json!("com.apoorvdarshan.coincide"),
                1 => feed["channel"] = json!("stable"),
                2 => {
                    feed["artifacts"][0]["url"] =
                        json!("https://updates.example/rust-preview/0.2.0/Coincide-macos-arm64.zip")
                }
                3 => feed["artifacts"][0]["architecture"] = json!("x86_64"),
                4 => {
                    let duplicate = feed["artifacts"][0].clone();
                    feed["artifacts"].as_array_mut().unwrap().push(duplicate);
                }
                5 => feed["version"] = json!("00.2.0"),
                _ => {
                    feed["artifacts"][0]["url"] = json!(
                        "https://updates.example/other-channel/0.2.0/Coincide-Rust-macos-arm64.zip"
                    )
                }
            });
            assert!(
                matches!(wait(f.service.check().unwrap()), State::Failed(_)),
                "case {case}"
            );
            assert!(f.service.download_available().is_err());
            assert_eq!(f.http.calls.load(Ordering::SeqCst), 1);
        }
    }
    #[test]
    fn equal_version_unpublished_and_http_error_have_distinct_states() {
        let f = Fixture::new();
        f.change_feed(|feed| {
            feed["version"] = json!("0.1.0");
            feed["artifacts"][0]["version"] = json!("0.1.0");
            feed["artifacts"][0]["url"] =
                json!("https://updates.example/rust-preview/0.1.0/Coincide-Rust-macos-arm64.zip");
        });
        assert_eq!(wait(f.service.check().unwrap()), State::Current);
        assert!(f.service.download_available().is_err());
        f.http.status.store(404, Ordering::SeqCst);
        assert_eq!(wait(f.service.check().unwrap()), State::Unpublished);
        f.http.status.store(429, Ordering::SeqCst);
        assert!(matches!(wait(f.service.check().unwrap()), State::Failed(_)));
    }
    #[test]
    fn hash_and_size_mismatch_never_reach_decoder_and_partial_jobs_are_removed() {
        for oversized in [false, true] {
            let f = Fixture::new();
            if oversized {
                f.change_feed(|feed| feed["artifacts"][0]["size"] = json!(1));
            } else {
                f.change_feed(|feed| feed["artifacts"][0]["sha256"] = json!("0".repeat(64)));
            }
            f.failed_stage();
            assert_eq!(f.decoder.0.load(Ordering::SeqCst), 0);
            assert_eq!(f.trust.calls.load(Ordering::SeqCst), 0);
        }
    }
    #[test]
    fn low_disk_refuses_before_archive_request() {
        let f = Fixture::new();
        f.disk.0.store(0, Ordering::SeqCst);
        f.failed_stage();
        assert_eq!(f.http.calls.load(Ordering::SeqCst), 1);
    }
    #[test]
    fn archive_traversal_case_collision_and_reserved_name_are_rejected() {
        for path in [
            "../outside",
            "Coincide.app/Contents/Info.plist",
            "Coincide Rust.app/Contents/MacOS/COINCIDE-RS",
            "Coincide Rust.app/Contents/NUL.txt",
            "Coincide Rust.app/Contents/Unicode-日本語.txt",
        ] {
            let f = Fixture::new();
            f.set_archive(archive(
                Some((path, b"not allowed")),
                CompressionMethod::Stored,
            ));
            f.failed_stage();
            assert_eq!(f.trust.calls.load(Ordering::SeqCst), 0);
        }
    }
    #[test]
    fn zip_symlink_and_expansion_limit_are_rejected() {
        let f = Fixture::new();
        let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
        writer
            .add_symlink(
                "Coincide Rust.app/Contents/link",
                "../../outside",
                SimpleFileOptions::default(),
            )
            .unwrap();
        f.set_archive(writer.finish().unwrap().into_inner());
        f.failed_stage();
        let f = Fixture::new();
        f.set_archive(archive(
            Some(("Coincide Rust.app/Contents/large", &vec![0; 9000])),
            CompressionMethod::Deflated,
        ));
        f.failed_stage();
    }
    #[test]
    fn verifier_rejection_removes_verified_archive_without_publishing_stage() {
        let f = Fixture::new();
        f.trust.reject.store(true, Ordering::SeqCst);
        f.failed_stage();
        assert_eq!(f.decoder.0.load(Ordering::SeqCst), 1);
    }
    #[test]
    fn cancellation_revokes_slow_worker_and_cannot_overwrite_new_check() {
        let f = Fixture::new();
        f.available();
        f.http.hold_archive.store(true, Ordering::SeqCst);
        let operation = f.service.download_available().unwrap();
        until(|| f.http.archive_entered.load(Ordering::SeqCst));
        assert!(f.service.check().is_err());
        assert!(operation.cancel());
        assert_eq!(operation.try_result(), Some(State::Cancelled));
        f.available();
        f.http.hold_archive.store(false, Ordering::SeqCst);
        until(|| fs::read_dir(f.root.path()).unwrap().next().is_none());
        assert!(matches!(f.service.state(), State::Available(_)));
        assert!(!operation.cancel());
    }
    #[test]
    fn deadline_completes_handle_even_when_transport_is_blocked() {
        let f = Fixture::with_timeout(Duration::from_millis(30));
        f.available();
        f.http.hold_archive.store(true, Ordering::SeqCst);
        let operation = f.service.download_available().unwrap();
        assert_eq!(wait(operation), State::TimedOut);
        f.http.hold_archive.store(false, Ordering::SeqCst);
        until(|| fs::read_dir(f.root.path()).unwrap().next().is_none());
        assert_eq!(f.service.state(), State::TimedOut);
    }
    #[test]
    fn concrete_https_adapter_rejects_non_https_before_any_request() {
        let context = OperationContext {
            reason: Arc::new(AtomicU8::new(0)),
            deadline: Instant::now() + Duration::from_secs(1),
            signal: Arc::new((Mutex::new(false), Condvar::new())),
        };
        let policy = RequestPolicy {
            hosts: BTreeSet::from(["updates.example".into()]),
            maximum_bytes: 10,
            deadline: context.deadline,
        };
        for url in [
            "http://updates.example/file",
            "https://other.example/file",
            "https://updates.example/file?token=fixture",
            "https://user:password@updates.example/file",
        ] {
            assert!(
                UreqTransport
                    .fetch(
                        &Url::parse(url).unwrap(),
                        &policy,
                        &mut Vec::new(),
                        &context
                    )
                    .is_err()
            );
        }
        let f = Fixture::new();
        *f.http.redirect.lock().unwrap() = Some(Url::parse("https://other.example/rogue").unwrap());
        assert!(matches!(wait(f.service.check().unwrap()), State::Failed(_)));
    }
    #[test]
    fn missing_anchor_and_insecure_feed_cannot_enable_service() {
        let f = Fixture::new();
        let deps = f.service.dependencies.clone().unwrap();
        let mut config = (**f.service.config.as_ref().unwrap()).clone();
        config.trust_anchor.clear();
        assert!(Updater::configured(config, deps.clone()).is_err());
        let mut config = (**f.service.config.as_ref().unwrap()).clone();
        config.feed = Url::parse("http://updates.example/feed.json").unwrap();
        assert!(Updater::configured(config, deps).is_err());
        assert_eq!(f.http.calls.load(Ordering::SeqCst), 0);
    }
    #[test]
    fn verified_wrong_identity_is_never_published() {
        let f = Fixture::new();
        f.trust.verified.store(true, Ordering::SeqCst);
        f.trust.wrong_identity.store(true, Ordering::SeqCst);
        f.failed_stage();
    }
    #[test]
    fn crc_corruption_is_rejected_even_with_matching_transport_sha256() {
        let f = Fixture::new();
        let mut bytes = archive(None, CompressionMethod::Stored);
        let body = 30 + u16le(&bytes, 26) as usize + u16le(&bytes, 28) as usize;
        bytes[body] ^= 0xff;
        f.set_archive(bytes);
        f.failed_stage();
        assert_eq!(f.trust.calls.load(Ordering::SeqCst), 0);
    }
    #[test]
    fn awaitable_handle_wakes_without_holding_service_locks() {
        struct Observer {
            service: Updater,
            calls: AtomicUsize,
        }
        impl std::task::Wake for Observer {
            fn wake(self: Arc<Self>) {
                let _ = self.service.state();
                self.calls.fetch_add(1, Ordering::SeqCst);
            }
        }
        let f = Fixture::new();
        f.available();
        f.http.hold_archive.store(true, Ordering::SeqCst);
        let mut operation = f.service.download_available().unwrap();
        until(|| f.http.archive_entered.load(Ordering::SeqCst));
        let observer = Arc::new(Observer {
            service: f.service.clone(),
            calls: AtomicUsize::new(0),
        });
        let waker = Waker::from(observer.clone());
        let mut cx = TaskContext::from_waker(&waker);
        assert!(Pin::new(&mut operation).poll(&mut cx).is_pending());
        assert!(operation.cancel());
        assert_eq!(observer.calls.load(Ordering::SeqCst), 1);
        assert_eq!(
            Pin::new(&mut operation).poll(&mut cx),
            Poll::Ready(State::Cancelled)
        );
        f.http.hold_archive.store(false, Ordering::SeqCst);
        until(|| fs::read_dir(f.root.path()).unwrap().next().is_none());
    }
}
