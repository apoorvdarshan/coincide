//! Explicit native downloads of compatible whisper.cpp GGML weights. The
//! original Swift CoreML model directory is never adopted or modified.
//! Registry metadata was read (not weights) from the official repository API
//! at revision5359861c739e955e79d9a303bcbc70fb988958b1 on2026-11-07.
use crate::native_file::Identity;
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Condvar, Mutex, OnceLock, Weak},
    time::Duration,
};
#[path = "model_assets_fs.rs"]
mod files;
#[path = "model_assets_http.rs"]
mod http;
pub use http::HttpsDownloader;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelId {
    Tiny,
    Base,
    Small,
    Turbo,
}
#[derive(Clone, Copy)]
pub struct Spec {
    pub id: ModelId,
    pub name: &'static str,
    pub bytes: u64,
    filename: &'static str,
    sha256: &'static str,
}
const REVISION: &str = "5359861c739e955e79d9a303bcbc70fb988958b1";
pub const CATALOG: [Spec; 4] = [
    Spec {
        id: ModelId::Tiny,
        name: "Tiny",
        bytes: 77_691_713,
        filename: "ggml-tiny.bin",
        sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
    },
    Spec {
        id: ModelId::Base,
        name: "Base",
        bytes: 147_951_465,
        filename: "ggml-base.bin",
        sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
    },
    Spec {
        id: ModelId::Small,
        name: "Small",
        bytes: 487_601_967,
        filename: "ggml-small.bin",
        sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
    },
    Spec {
        id: ModelId::Turbo,
        name: "Large v3 Turbo",
        bytes: 1_624_555_275,
        filename: "ggml-large-v3-turbo.bin",
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
    },
];
impl ModelId {
    pub fn id(self) -> &'static str {
        match self {
            Self::Tiny => "tiny",
            Self::Base => "base",
            Self::Small => "small",
            Self::Turbo => "large-v3-turbo",
        }
    }
    pub fn parse(value: &str) -> Option<Self> {
        CATALOG
            .iter()
            .find(|spec| spec.id.id() == value)
            .map(|spec| spec.id)
    }
    fn index(self) -> usize {
        match self {
            Self::Tiny => 0,
            Self::Base => 1,
            Self::Small => 2,
            Self::Turbo => 3,
        }
    }
    pub fn spec(self) -> &'static Spec {
        &CATALOG[self.index()]
    }
}
impl Spec {
    pub fn url(&self) -> String {
        format!(
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/{REVISION}/{}",
            self.filename
        )
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Unavailable,
    Storage,
    Changed,
    NotDownloaded,
    ExistingPreserved,
    SizeMismatch,
    ChecksumMismatch,
    Cancelled,
    Busy,
    InsufficientSpace,
    Network,
    Rejected,
    RecoveryPending,
}
pub type Result<T> = std::result::Result<T, Error>;
pub trait Downloader: Send + Sync {
    fn fetch(
        &self,
        spec: &Spec,
        output: &mut dyn Write,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<()>;
}
#[derive(Default)]
struct UseState {
    readers: usize,
    removing: bool,
    removed: bool,
}
#[derive(Default)]
struct Usage {
    state: Mutex<UseState>,
    changed: Condvar,
}
/// No Debug/Serialize or JSON constructor. Minted only by a verified download
/// or explicit native file verification against the compiled registry.
pub struct VerifiedModel {
    authority: uuid::Uuid,
    spec: Spec,
    directory: Arc<files::Directory>,
    identity: Identity,
    usage: Arc<Usage>,
}
impl PartialEq for VerifiedModel {
    fn eq(&self, other: &Self) -> bool {
        self.authority == other.authority
    }
}
impl Eq for VerifiedModel {}
impl VerifiedModel {
    pub fn id(&self) -> ModelId {
        self.spec.id
    }
    pub fn path(&self) -> PathBuf {
        self.directory.path.join(self.spec.filename)
    }
    pub fn available_for_new_use(&self) -> bool {
        self.usage
            .state
            .lock()
            .is_ok_and(|state| !state.removing && !state.removed)
    }
    pub fn acquire(
        self: &Arc<Self>,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<Arc<ModelReadLease>> {
        self.directory.check()?;
        let file = self.directory.open_file(self.spec.filename)?;
        if files::identity(&file)? != self.identity {
            return Err(Error::Changed);
        }
        let lease = acquire_file(file, Some(self.authority), false)?;
        verify(
            lease.file.try_clone().map_err(|_| Error::Storage)?,
            &self.spec,
            cancelled,
        )?;
        let current = self.directory.open_file(self.spec.filename)?;
        if files::identity(&current)? != self.identity {
            return Err(Error::Changed);
        }
        Ok(lease)
    }
}
static READERS: OnceLock<Mutex<std::collections::HashMap<Identity, Weak<Usage>>>> = OnceLock::new();
fn usage_for(identity: Identity) -> Result<Arc<Usage>> {
    let mut registry = READERS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| Error::Busy)?;
    registry.retain(|_, usage| usage.strong_count() != 0);
    if let Some(usage) = registry.get(&identity).and_then(Weak::upgrade) {
        return Ok(usage);
    }
    if registry.len() >= 128 {
        return Err(Error::Busy);
    }
    let usage = Arc::new(Usage::default());
    registry.insert(identity, Arc::downgrade(&usage));
    Ok(usage)
}
/// All native local-file inference is tracked, including a user choosing an
/// installed artifact through the ordinary file picker instead of the catalog.
pub fn acquire_model_path(
    path: &Path,
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Result<Arc<ModelReadLease>> {
    if cancelled() {
        return Err(Error::Cancelled);
    }
    if !path.is_absolute() {
        return Err(Error::Changed);
    }
    let resolved = path.canonicalize().map_err(|_| Error::NotDownloaded)?;
    let file = crate::native_file::open_regular(&resolved, false).map_err(|_| Error::Changed)?;
    let lease = acquire_file(file, None, true)?;
    if cancelled() {
        return Err(Error::Cancelled);
    }
    Ok(lease)
}
fn acquire_file(
    file: File,
    authority: Option<uuid::Uuid>,
    explicit_file: bool,
) -> Result<Arc<ModelReadLease>> {
    let identity = files::identity(&file)?;
    let usage = usage_for(identity)?;
    {
        let mut state = usage.state.lock().map_err(|_| Error::Busy)?;
        if state.removing || (!explicit_file && state.removed) {
            return Err(Error::Busy);
        }
        if explicit_file {
            state.removed = false;
        }
        state.readers += 1;
    }
    Ok(Arc::new(ModelReadLease {
        file,
        usage,
        identity,
        authority,
    }))
}
/// Own until the actual process and its private TextReady UI callback return.
/// No Debug/Serialize: this is native custody, never document authority.
pub struct ModelReadLease {
    file: File,
    usage: Arc<Usage>,
    identity: Identity,
    authority: Option<uuid::Uuid>,
}
impl ModelReadLease {
    pub fn matches(&self, model: &VerifiedModel) -> bool {
        self.authority == Some(model.authority) && self.identity == model.identity
    }
    pub fn matches_path(&self, path: &Path) -> bool {
        let Ok(path) = path.canonicalize() else {
            return false;
        };
        let Ok(current) = crate::native_file::open_regular(&path, false) else {
            return false;
        };
        files::identity(&current).ok() == Some(self.identity)
            && files::identity(&self.file).ok() == Some(self.identity)
    }
}
impl Drop for ModelReadLease {
    fn drop(&mut self) {
        let mut state = self
            .usage
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        state.readers = state.readers.saturating_sub(1);
        self.usage.changed.notify_all();
    }
}
struct Recovery {
    name: String,
    identity: Identity,
    owned: bool,
}
struct Staging<'a> {
    repository: &'a Repository,
    name: String,
    identity: Identity,
    finished: bool,
}
impl Staging<'_> {
    fn cleanup(&mut self) -> Result<()> {
        if self.finished {
            return Ok(());
        }
        self.finished = true;
        if self
            .repository
            .directory
            .unlink_owned(&self.name, self.identity)
            .is_err()
        {
            self.repository
                .recovery
                .lock()
                .map_err(|_| Error::RecoveryPending)?
                .push(Recovery {
                    name: self.name.clone(),
                    identity: self.identity,
                    owned: true,
                });
            Err(Error::RecoveryPending)
        } else {
            Ok(())
        }
    }
}
impl Drop for Staging<'_> {
    fn drop(&mut self) {
        let _ = self.cleanup();
    }
}
pub struct Repository {
    directory: Arc<files::Directory>,
    operation: Mutex<()>,
    recovery: Mutex<Vec<Recovery>>,
}
impl Repository {
    /// Explicit worker action only. Construction of the native settings pane
    /// does not call this, scan disk, download, or authorize an executable.
    pub fn open(data_root: &Path) -> Result<Self> {
        let root = files::canonical_data_root(data_root)?;
        let directory = Arc::new(files::Directory::open(root.join("voice-models-ggml-v1"))?);
        Ok(Self {
            directory,
            operation: Mutex::new(()),
            recovery: Mutex::new(Vec::new()),
        })
    }
    pub fn verify(
        &self,
        id: ModelId,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<Arc<VerifiedModel>> {
        self.verify_spec(*id.spec(), cancelled)
    }
    fn verify_spec(
        &self,
        spec: Spec,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<Arc<VerifiedModel>> {
        let file = self.directory.open_file(spec.filename)?;
        let identity = files::identity(&file)?;
        verify(file, &spec, cancelled)?;
        self.directory.check()?;
        let current = self.directory.open_file(spec.filename)?;
        if files::identity(&current)? != identity {
            return Err(Error::Changed);
        }
        let usage = usage_for(identity)?;
        {
            let mut state = usage.state.lock().map_err(|_| Error::Busy)?;
            if state.removing {
                return Err(Error::Busy);
            }
            state.removed = false;
        }
        Ok(Arc::new(VerifiedModel {
            authority: uuid::Uuid::new_v4(),
            spec,
            directory: self.directory.clone(),
            identity,
            usage,
        }))
    }
    pub fn download(
        &self,
        id: ModelId,
        source: &dyn Downloader,
        cancelled: &(dyn Fn() -> bool + Sync),
        progress: &mut dyn FnMut(u64),
    ) -> Result<Arc<VerifiedModel>> {
        self.download_spec(*id.spec(), source, cancelled, progress)
    }
    fn download_spec(
        &self,
        spec: Spec,
        source: &dyn Downloader,
        cancelled: &(dyn Fn() -> bool + Sync),
        progress: &mut dyn FnMut(u64),
    ) -> Result<Arc<VerifiedModel>> {
        let _operation = self.operation.lock().map_err(|_| Error::Busy)?;
        if cancelled() {
            return Err(Error::Cancelled);
        }
        self.directory.check()?;
        if !self
            .recovery
            .lock()
            .map_err(|_| Error::RecoveryPending)?
            .is_empty()
        {
            return Err(Error::RecoveryPending);
        }
        match self.directory.open_file(spec.filename) {
            Ok(_) => return Err(Error::ExistingPreserved),
            Err(Error::NotDownloaded) => {}
            Err(error) => return Err(error),
        }
        if self.directory.available_bytes()? < spec.bytes.saturating_add(16 * 1024 * 1024) {
            return Err(Error::InsufficientSpace);
        }
        let temporary = format!(".download-{}", uuid::Uuid::new_v4());
        let file = self.directory.create(&temporary)?;
        let identity = files::identity(&file)?;
        let mut staging = Staging {
            repository: self,
            name: temporary.clone(),
            identity,
            finished: false,
        };
        let result = (|| {
            let mut sink = Sink {
                file,
                received: 0,
                hash: Sha256::new(),
                spec,
                progress,
                cancelled,
                fault: None,
            };
            let fetched = source.fetch(&spec, &mut sink, cancelled);
            if let Some(error) = sink.fault {
                return Err(error);
            }
            fetched?;
            if cancelled() {
                return Err(Error::Cancelled);
            }
            if sink.received != spec.bytes {
                return Err(Error::SizeMismatch);
            }
            if hex(&sink.hash.finalize()) != spec.sha256 {
                return Err(Error::ChecksumMismatch);
            }
            sink.file.sync_all().map_err(|_| Error::Storage)?;
            drop(sink.file);
            self.directory.link_no_replace(&temporary, spec.filename)?;
            Ok(())
        })();
        staging.cleanup()?;
        result?;
        self.verify_spec(spec, cancelled)
    }
    /// Destruction is admitted by the actual native receipt, waits physical
    /// readers/results, and rechecks content and directory/file identity.
    pub fn remove(
        &self,
        model: &VerifiedModel,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<()> {
        let _operation = self.operation.lock().map_err(|_| Error::Busy)?;
        if !Arc::ptr_eq(&self.directory, &model.directory) {
            return Err(Error::Changed);
        }
        let mut state = model.usage.state.lock().map_err(|_| Error::Busy)?;
        if state.removing || state.removed {
            return Err(Error::Busy);
        }
        state.removing = true;
        while state.readers != 0 {
            if cancelled() {
                state.removing = false;
                return Err(Error::Cancelled);
            }
            let waited = model
                .usage
                .changed
                .wait_timeout(state, Duration::from_millis(20))
                .map_err(|_| Error::Busy)?;
            state = waited.0;
        }
        drop(state);
        let result = (|| {
            if cancelled() {
                return Err(Error::Cancelled);
            }
            let file = self.directory.open_file(model.spec.filename)?;
            if files::identity(&file)? != model.identity {
                return Err(Error::Changed);
            }
            verify(file, &model.spec, cancelled)?;
            let temporary = format!(".remove-{}", uuid::Uuid::new_v4());
            self.directory.quarantine(model.spec.filename, &temporary)?;
            let moved = match self.directory.open_file(&temporary) {
                Ok(file) => file,
                Err(_) => {
                    self.recovery
                        .lock()
                        .map_err(|_| Error::RecoveryPending)?
                        .push(Recovery {
                            name: temporary,
                            identity: model.identity,
                            owned: false,
                        });
                    return Err(Error::RecoveryPending);
                }
            };
            let moved_identity = files::identity(&moved)?;
            drop(moved);
            if moved_identity != model.identity {
                // Restore without overwriting a newly-created name. If that
                // fails, keep the foreign content and explicit recovery receipt.
                if self
                    .directory
                    .link_no_replace(&temporary, model.spec.filename)
                    .is_ok()
                {
                    self.directory.unlink_owned(&temporary, moved_identity)?;
                    return Err(Error::Changed);
                }
                self.recovery
                    .lock()
                    .map_err(|_| Error::RecoveryPending)?
                    .push(Recovery {
                        name: temporary,
                        identity: moved_identity,
                        owned: false,
                    });
                return Err(Error::RecoveryPending);
            }
            match self.directory.unlink_owned(&temporary, model.identity) {
                Ok(()) => Ok(()),
                Err(_) => {
                    self.recovery
                        .lock()
                        .map_err(|_| Error::RecoveryPending)?
                        .push(Recovery {
                            name: temporary,
                            identity: model.identity,
                            owned: true,
                        });
                    Err(Error::RecoveryPending)
                }
            }
        })();
        let mut state = model.usage.state.lock().map_err(|_| Error::Busy)?;
        state.removing = false;
        if result.is_ok() {
            state.removed = true;
        }
        model.usage.changed.notify_all();
        result
    }
    pub fn pending_recovery(&self) -> usize {
        self.recovery.lock().map_or(1, |recovery| recovery.len())
    }
    /// Explicit cleanup retry only. Foreign/replaced content is retained.
    pub fn retry_owned_cleanup(&self, cancelled: &dyn Fn() -> bool) -> Result<()> {
        let _operation = self.operation.lock().map_err(|_| Error::Busy)?;
        self.directory.check()?;
        let mut recovery = self.recovery.lock().map_err(|_| Error::RecoveryPending)?;
        recovery.retain(|entry| {
            !entry.owned
                || cancelled()
                || self
                    .directory
                    .unlink_owned(&entry.name, entry.identity)
                    .is_err()
        });
        if recovery.is_empty() {
            Ok(())
        } else {
            Err(Error::RecoveryPending)
        }
    }
}
fn hex(value: &[u8]) -> String {
    value.iter().map(|byte| format!("{byte:02x}")).collect()
}
fn verify(mut file: File, spec: &Spec, cancelled: &(dyn Fn() -> bool + Sync)) -> Result<()> {
    if file.metadata().map_err(|_| Error::Storage)?.len() != spec.bytes {
        return Err(Error::SizeMismatch);
    }
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    let mut received = 0u64;
    loop {
        if cancelled() {
            return Err(Error::Cancelled);
        }
        let n = file.read(&mut buffer).map_err(|_| Error::Storage)?;
        if n == 0 {
            break;
        }
        received = received.checked_add(n as u64).ok_or(Error::SizeMismatch)?;
        if received > spec.bytes {
            return Err(Error::SizeMismatch);
        }
        hash.update(&buffer[..n]);
    }
    if received != spec.bytes {
        return Err(Error::SizeMismatch);
    }
    if hex(&hash.finalize()) != spec.sha256 {
        return Err(Error::ChecksumMismatch);
    }
    Ok(())
}
struct Sink<'a> {
    file: File,
    received: u64,
    hash: Sha256,
    spec: Spec,
    progress: &'a mut dyn FnMut(u64),
    cancelled: &'a (dyn Fn() -> bool + Sync),
    fault: Option<Error>,
}
impl Write for Sink<'_> {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        if (self.cancelled)() {
            self.fault = Some(Error::Cancelled);
            return Err(std::io::Error::other("Model download cancelled"));
        }
        if self.received.saturating_add(buffer.len() as u64) > self.spec.bytes {
            self.fault = Some(Error::SizeMismatch);
            return Err(std::io::ErrorKind::InvalidData.into());
        }
        let written = self.file.write(buffer)?;
        self.received += written as u64;
        self.hash.update(&buffer[..written]);
        (self.progress)(self.received);
        Ok(written)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.file.flush()
    }
}

#[cfg(test)]
#[path = "model_assets_tests.rs"]
mod tests;
