//! Native-only explicit post-copy ownership. Not an ingestion journal or cleanup authority.
//! Records contain private paths. Never route them through Engine, providers or drafts.
use crate::legacy_media_service::{CompletionReceipt, ReceiptId, ServiceConfig};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::path::PathBuf;

pub const MAX_RECORD_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_RETAINED_BYTES: u64 = 64 * 1024 * 1024;
pub const MAX_RETAINED_FILES: usize = 256;
const DIRECTORY: &str = "legacy-media-recovery-v1";

/// Deliberately path-free errors, suitable for native status UI.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecoveryError {
    Unsupported,
    Busy,
    Io,
    InvalidRecord,
    IdentityChanged,
    Conflict,
    Quota,
    CommitUnknown,
}
pub type RecoveryResult<T> = Result<T, RecoveryError>;

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Identity {
    device: u64,
    inode: u64,
}
#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct Payload {
    version: u32,
    data_directory: PathBuf,
    database_path: PathBuf,
    database_identity: Identity,
    receipt: Value,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u32,
    sha256: String,
    payload: Payload,
}

/// No Debug/Serialize: source paths stay private; this is diagnostic data, never a grant.
pub struct RecoveryRecord {
    payload: Payload,
    digest: String,
    database_identity_current: bool,
}
impl RecoveryRecord {
    pub fn receipt_id(&self) -> &str {
        self.payload.receipt["receiptId"].as_str().unwrap_or("")
    }
    pub fn operation_id(&self) -> &str {
        self.payload.receipt["operationId"].as_str().unwrap_or("")
    }
    pub fn thread_id(&self) -> &str {
        self.payload.receipt["threadId"].as_str().unwrap_or("")
    }
    pub fn digest(&self) -> &str {
        &self.digest
    }
    /// Historical DB replacement is explicit, not record loss or automatic rebinding.
    pub fn database_identity_current(&self) -> bool {
        self.database_identity_current
    }
    /// Private native reconciliation only. Does not authorize opening any path.
    pub fn private_receipt(&self) -> &Value {
        &self.payload.receipt
    }
}

/// Constructed only after verified readback plus successful file/directory sync.
/// Opaque persisted strings never reconstruct live service IDs after restart.
#[derive(Clone)]
pub struct DurableOwnership {
    receipt_id: String,
    operation_id: String,
    thread_id: String,
    digest: String,
}
impl DurableOwnership {
    pub fn receipt_id(&self) -> &str {
        &self.receipt_id
    }
    pub fn operation_id(&self) -> &str {
        &self.operation_id
    }
    pub fn thread_id(&self) -> &str {
        &self.thread_id
    }
    pub fn digest(&self) -> &str {
        &self.digest
    }
    pub fn matches(&self, id: ReceiptId, receipt: &CompletionReceipt) -> bool {
        self.receipt_id == id.to_string()
            && self.operation_id == receipt.operation_id.to_string()
            && self.thread_id == receipt.thread_id
            && snapshot(id, receipt).is_ok_and(|v| digest_value(&v).is_ok_and(|d| d == self.digest))
    }
}
fn digest_value(value: &Value) -> RecoveryResult<String> {
    let bytes = serde_json::to_vec(value).map_err(|_| RecoveryError::InvalidRecord)?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}
fn snapshot(id: ReceiptId, receipt: &CompletionReceipt) -> RecoveryResult<Value> {
    let value = json!({"receiptId":id.to_string(), "operationId":receipt.operation_id.to_string(),
        "threadId":receipt.thread_id, "generation":receipt.generation, "committed":receipt.committed,
        "error":receipt.error.as_ref().map(ToString::to_string), "batch":receipt.batch,
        "committedCandidateIds":receipt.committed_candidate_ids});
    validate_receipt(&value)?;
    Ok(value)
}
fn canonical_uuid(v: &Value) -> bool {
    v.as_str()
        .is_some_and(|s| uuid::Uuid::parse_str(s).is_ok_and(|id| id.to_string() == s))
}
fn validate_receipt(v: &Value) -> RecoveryResult<()> {
    let valid = canonical_uuid(&v["receiptId"])
        && canonical_uuid(&v["operationId"])
        && canonical_uuid(&v["threadId"])
        && v["generation"].is_u64()
        && v["committed"].is_boolean()
        && (v["error"].is_null() || v["error"].is_string())
        && v["committedCandidateIds"]
            .as_array()
            .is_some_and(|a| a.len() <= 20 && a.iter().all(Value::is_string));
    if !valid {
        return Err(RecoveryError::InvalidRecord);
    }
    let batch = &v["batch"];
    // Preserve Serialize output exactly; no re-keying of historical batch snapshots.
    let hash = batch
        .get("threadSha256")
        .or_else(|| batch.get("thread_sha256"))
        .and_then(Value::as_str);
    if !hash.is_some_and(|h| h.len() == 64 && h.bytes().all(|c| c.is_ascii_hexdigit())) {
        return Err(RecoveryError::InvalidRecord);
    }
    let refs = batch["references"]
        .as_array()
        .ok_or(RecoveryError::InvalidRecord)?;
    if refs.len() > 20 {
        return Err(RecoveryError::InvalidRecord);
    }
    for entry in refs {
        let candidate = &entry["reference"]["candidate"];
        if candidate["threadId"] != v["threadId"] || !candidate["candidateId"].is_string() {
            return Err(RecoveryError::InvalidRecord);
        }
        if !entry["image"].is_null() {
            let image: crate::attachments::StoredImage =
                serde_json::from_value(entry["image"].clone())
                    .map_err(|_| RecoveryError::InvalidRecord)?;
            if !canonical_uuid(&Value::String(image.id)) {
                return Err(RecoveryError::InvalidRecord);
            }
            // Do not prepare/open/revalidate media, or filter IoError/null hashes. Exact identity survives.
        }
    }
    Ok(())
}

#[cfg(unix)]
mod platform {
    use super::*;
    use std::{
        ffi::CString,
        fs::{self, File},
        io::{Read, Write},
        os::{
            fd::{AsRawFd, FromRawFd},
            unix::{ffi::OsStrExt, fs::MetadataExt},
        },
        path::{Component, Path},
    };
    fn io<T>(r: std::io::Result<T>) -> RecoveryResult<T> {
        r.map_err(|_| RecoveryError::Io)
    }
    fn name(s: &std::ffi::OsStr) -> RecoveryResult<CString> {
        CString::new(s.as_bytes()).map_err(|_| RecoveryError::InvalidRecord)
    }
    fn open_at(
        parent: &File,
        path: &std::ffi::OsStr,
        flags: i32,
        mode: u32,
    ) -> RecoveryResult<File> {
        let path = name(path)?;
        // SAFETY: valid directory descriptor/C string; returned descriptor uniquely owned.
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                path.as_ptr(),
                flags | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
                mode as libc::mode_t,
            )
        };
        if fd < 0 {
            return Err(RecoveryError::Io);
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    fn absolute_directory(path: &Path) -> RecoveryResult<File> {
        if !path.is_absolute() {
            return Err(RecoveryError::IdentityChanged);
        }
        let mut dir = io(File::open("/"))?;
        for part in path.components() {
            match part {
                Component::RootDir => (),
                Component::Normal(n) => {
                    dir = open_at(&dir, n, libc::O_RDONLY | libc::O_DIRECTORY, 0)?
                }
                _ => return Err(RecoveryError::IdentityChanged),
            }
        }
        Ok(dir)
    }
    fn identity(file: &File) -> RecoveryResult<Identity> {
        let m = io(file.metadata())?;
        Ok(Identity {
            device: m.dev(),
            inode: m.ino(),
        })
    }
    fn private(file: &File, directory: bool) -> RecoveryResult<()> {
        let m = io(file.metadata())?;
        if (directory && !m.is_dir())
            || (!directory && !m.is_file())
            || m.mode() & 0o777 != if directory { 0o700 } else { 0o600 }
            || m.uid() != unsafe { libc::geteuid() }
        {
            return Err(RecoveryError::IdentityChanged);
        }
        Ok(())
    }
    /// One exclusive writer per private directory. No automatic eviction/deletion, even of failed staging files.
    pub struct RecoveryStore {
        config: ServiceConfig,
        root: File,
        directory: File,
        database: File,
        _lock: File,
        #[cfg(test)]
        fail_after_publish: bool,
    }
    impl RecoveryStore {
        pub fn open(config: &ServiceConfig) -> RecoveryResult<Self> {
            let root = absolute_directory(&config.expected_data_directory)?;
            if config.database_path.parent() != Some(config.expected_data_directory.as_path()) {
                return Err(RecoveryError::IdentityChanged);
            }
            let db_name = config
                .database_path
                .file_name()
                .ok_or(RecoveryError::IdentityChanged)?;
            let database = open_at(&root, db_name, libc::O_RDONLY, 0)?;
            if !io(database.metadata())?.is_file() {
                return Err(RecoveryError::IdentityChanged);
            }
            let n = CString::new(DIRECTORY).unwrap();
            let result = unsafe { libc::mkdirat(root.as_raw_fd(), n.as_ptr(), 0o700) };
            if result < 0
                && std::io::Error::last_os_error().kind() != std::io::ErrorKind::AlreadyExists
            {
                return Err(RecoveryError::Io);
            }
            let directory = open_at(
                &root,
                DIRECTORY.as_ref(),
                libc::O_RDONLY | libc::O_DIRECTORY,
                0,
            )?;
            private(&directory, true)?;
            let lock = open_at(
                &directory,
                "owner.lock".as_ref(),
                libc::O_RDWR | libc::O_CREAT,
                0o600,
            )?;
            private(&lock, false)?;
            if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } < 0 {
                return Err(RecoveryError::Busy);
            }
            io(root.sync_all())?;
            let store = Self {
                config: config.clone(),
                root,
                directory,
                database,
                _lock: lock,
                #[cfg(test)]
                fail_after_publish: false,
            };
            store.check_identity()?;
            Ok(store)
        }
        fn check_identity(&self) -> RecoveryResult<()> {
            let root = absolute_directory(&self.config.expected_data_directory)?;
            let directory = open_at(
                &root,
                DIRECTORY.as_ref(),
                libc::O_RDONLY | libc::O_DIRECTORY,
                0,
            )?;
            private(&directory, true)?;
            let database = open_at(
                &root,
                self.config
                    .database_path
                    .file_name()
                    .ok_or(RecoveryError::IdentityChanged)?,
                libc::O_RDONLY,
                0,
            )?;
            if identity(&root)? != identity(&self.root)?
                || identity(&directory)? != identity(&self.directory)?
                || identity(&database)? != identity(&self.database)?
            {
                return Err(RecoveryError::IdentityChanged);
            }
            Ok(())
        }
        fn files(&self) -> RecoveryResult<Vec<(String, u64)>> {
            self.check_identity()?;
            let mut files = Vec::new();
            let mut bytes = 0u64;
            for entry in io(fs::read_dir(
                self.config.expected_data_directory.join(DIRECTORY),
            ))? {
                let entry = io(entry)?;
                let n = entry
                    .file_name()
                    .into_string()
                    .map_err(|_| RecoveryError::InvalidRecord)?;
                if n == "owner.lock" {
                    continue;
                }
                let f = open_at(&self.directory, n.as_ref(), libc::O_RDONLY, 0)?;
                private(&f, false)?;
                let size = io(f.metadata())?.len();
                bytes = bytes.checked_add(size).ok_or(RecoveryError::Quota)?;
                files.push((n, size));
                if files.len() > MAX_RETAINED_FILES || bytes > MAX_RETAINED_BYTES {
                    return Err(RecoveryError::Quota);
                }
            }
            self.check_identity()?;
            Ok(files)
        }
        fn read(&self, filename: &str) -> RecoveryResult<RecoveryRecord> {
            let f = open_at(&self.directory, filename.as_ref(), libc::O_RDONLY, 0)?;
            private(&f, false)?;
            let mut bytes = Vec::new();
            io(f.take(MAX_RECORD_BYTES as u64 + 1).read_to_end(&mut bytes))?;
            if bytes.len() > MAX_RECORD_BYTES {
                return Err(RecoveryError::Quota);
            }
            let envelope: Envelope =
                serde_json::from_slice(&bytes).map_err(|_| RecoveryError::InvalidRecord)?;
            let value = serde_json::to_value(&envelope.payload)
                .map_err(|_| RecoveryError::InvalidRecord)?;
            if envelope.version != 1
                || envelope.payload.version != 1
                || digest_value(&value)? != envelope.sha256
                || envelope.payload.data_directory != self.config.expected_data_directory
                || envelope.payload.database_path != self.config.database_path
            {
                return Err(RecoveryError::InvalidRecord);
            }
            validate_receipt(&envelope.payload.receipt)?;
            if filename
                != format!(
                    "{}.json",
                    envelope.payload.receipt["receiptId"].as_str().unwrap_or("")
                )
            {
                return Err(RecoveryError::InvalidRecord);
            }
            let current = envelope.payload.database_identity == identity(&self.database)?;
            let digest = digest_value(&envelope.payload.receipt)?;
            Ok(RecoveryRecord {
                payload: envelope.payload,
                digest,
                database_identity_current: current,
            })
        }
        /// Blocking IO: call only on a background worker after explicit ownership request.
        pub fn persist(
            &mut self,
            id: ReceiptId,
            receipt: &CompletionReceipt,
        ) -> RecoveryResult<DurableOwnership> {
            self.persist_value(snapshot(id, receipt)?)
        }
        fn persist_value(&mut self, receipt: Value) -> RecoveryResult<DurableOwnership> {
            validate_receipt(&receipt)?;
            let files = self.files()?;
            let filename = format!(
                "{}.json",
                receipt["receiptId"]
                    .as_str()
                    .ok_or(RecoveryError::InvalidRecord)?
            );
            let payload = Payload {
                version: 1,
                data_directory: self.config.expected_data_directory.clone(),
                database_path: self.config.database_path.clone(),
                database_identity: identity(&self.database)?,
                receipt,
            };
            let sha256 = digest_value(
                &serde_json::to_value(&payload).map_err(|_| RecoveryError::InvalidRecord)?,
            )?;
            let bytes = serde_json::to_vec(&Envelope {
                version: 1,
                sha256,
                payload: payload.clone(),
            })
            .map_err(|_| RecoveryError::InvalidRecord)?;
            if bytes.len() > MAX_RECORD_BYTES {
                return Err(RecoveryError::Quota);
            }
            if files.iter().any(|(n, _)| n == &filename) {
                let existing = self.read(&filename)?;
                if existing.payload != payload {
                    return Err(RecoveryError::Conflict);
                }
            } else {
                let used: u64 = files.iter().map(|(_, size)| size).sum();
                // Both staging and final hardlinks are retained; budget both, conservatively.
                if files.len() + 2 > MAX_RETAINED_FILES
                    || used + 2 * bytes.len() as u64 > MAX_RETAINED_BYTES
                {
                    return Err(RecoveryError::Quota);
                }
                let stage = format!("pending-{}", uuid::Uuid::new_v4());
                let mut f = open_at(
                    &self.directory,
                    stage.as_ref(),
                    libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
                    0o600,
                )?;
                io(f.write_all(&bytes))?;
                io(f.sync_all())?;
                self.check_identity()?;
                let src = CString::new(stage).unwrap();
                let dst = CString::new(filename.clone()).unwrap();
                // Atomic no-overwrite publication. Staging name is deliberately retained, never deleted.
                if unsafe {
                    libc::linkat(
                        self.directory.as_raw_fd(),
                        src.as_ptr(),
                        self.directory.as_raw_fd(),
                        dst.as_ptr(),
                        0,
                    )
                } < 0
                {
                    return Err(RecoveryError::CommitUnknown);
                }
            }
            #[cfg(test)]
            if self.fail_after_publish {
                return Err(RecoveryError::CommitUnknown);
            }
            // Including retries: do not turn an earlier uncertain sync into a success by existence alone.
            let f = open_at(&self.directory, filename.as_ref(), libc::O_RDONLY, 0)
                .map_err(|_| RecoveryError::CommitUnknown)?;
            f.sync_all().map_err(|_| RecoveryError::CommitUnknown)?;
            self.directory
                .sync_all()
                .map_err(|_| RecoveryError::CommitUnknown)?;
            self.root
                .sync_all()
                .map_err(|_| RecoveryError::CommitUnknown)?;
            let record = self
                .read(&filename)
                .map_err(|_| RecoveryError::CommitUnknown)?;
            self.check_identity()
                .map_err(|_| RecoveryError::CommitUnknown)?;
            if record.payload != payload {
                return Err(RecoveryError::CommitUnknown);
            }
            Ok(DurableOwnership {
                receipt_id: record.receipt_id().into(),
                operation_id: record.operation_id().into(),
                thread_id: record.thread_id().into(),
                digest: record.digest,
            })
        }
        pub fn retained(&self) -> RecoveryResult<Vec<RecoveryRecord>> {
            let mut records = Vec::new();
            for (name, _) in self.files()? {
                if name.ends_with(".json") {
                    records.push(self.read(&name)?);
                }
            }
            self.check_identity()?;
            Ok(records)
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        fn fixture() -> (tempfile::TempDir, ServiceConfig) {
            let temp = tempfile::tempdir().unwrap();
            let root = temp.path().canonicalize().unwrap();
            let database_path = root.join("fixture.db");
            fs::write(&database_path, b"synthetic-not-sqlite").unwrap();
            (
                temp,
                ServiceConfig {
                    database_path,
                    expected_data_directory: root,
                },
            )
        }
        fn receipt() -> Value {
            json!({"receiptId":uuid::Uuid::new_v4().to_string(),"operationId":uuid::Uuid::new_v4().to_string(),"threadId":uuid::Uuid::new_v4().to_string(),"generation":9,"committed":false,"error":"CommitUnknown","committedCandidateIds":[],"batch":{"thread_sha256":"a".repeat(64),"references":[]}})
        }
        #[test]
        fn durable_roundtrip_idempotence_conflict_and_private_modes() {
            let (_temp, cfg) = fixture();
            let mut store = RecoveryStore::open(&cfg).unwrap();
            let r = receipt();
            let token = store.persist_value(r.clone()).unwrap();
            assert_eq!(token.receipt_id(), r["receiptId"].as_str().unwrap());
            store.persist_value(r.clone()).unwrap();
            assert_eq!(store.retained().unwrap()[0].private_receipt(), &r);
            let mut changed = r;
            changed["generation"] = json!(10);
            assert!(matches!(
                store.persist_value(changed),
                Err(RecoveryError::Conflict)
            ));
            for (name, _) in store.files().unwrap() {
                assert_eq!(
                    fs::metadata(cfg.expected_data_directory.join(DIRECTORY).join(name))
                        .unwrap()
                        .mode()
                        & 0o777,
                    0o600
                );
            }
        }
        #[test]
        fn quota_never_evicts_and_replacement_is_diagnostic_after_reopen() {
            let (_temp, cfg) = fixture();
            let mut store = RecoveryStore::open(&cfg).unwrap();
            let r = receipt();
            store.persist_value(r.clone()).unwrap();
            for _ in 2..MAX_RETAINED_FILES {
                let n = format!("pending-{}", uuid::Uuid::new_v4());
                let _f = open_at(
                    &store.directory,
                    n.as_ref(),
                    libc::O_CREAT | libc::O_EXCL | libc::O_WRONLY,
                    0o600,
                )
                .unwrap();
            }
            assert!(matches!(
                store.persist_value(receipt()),
                Err(RecoveryError::Quota)
            ));
            assert_eq!(store.retained().unwrap()[0].private_receipt(), &r);
            fs::rename(&cfg.database_path, cfg.database_path.with_extension("old")).unwrap();
            fs::write(&cfg.database_path, b"replacement").unwrap();
            assert!(matches!(
                store.retained(),
                Err(RecoveryError::IdentityChanged)
            ));
            drop(store);
            let store = RecoveryStore::open(&cfg).unwrap();
            assert!(!store.retained().unwrap()[0].database_identity_current());
        }
        #[test]
        fn exact_partial_duplicate_associations_and_uncertain_sync_survive() {
            let (_temp, cfg) = fixture();
            let mut store = RecoveryStore::open(&cfg).unwrap();
            let mut r = receipt();
            let image_id = uuid::Uuid::new_v4().to_string();
            let image = json!({"id":image_id,"originalName":"fixture.png","originalPath":"/synthetic/private/original.png","originalMimeType":"image/png","path":"/synthetic/private/normalized.png","mimeType":"image/png","width":1,"height":1,"byteLen":42,"originalByteLen":55});
            let entry = json!({"reference":{"candidate":{"candidateId":"binding","threadId":r["threadId"],"itemId":null,"itemIndex":0,"attachmentIndex":0,"rawReference":{"unknown":{"path":"/synthetic/private/source.png"}},"rootId":null,"relativePath":null,"status":"mapped"},"status":"ioError","byteLen":55,"sourceSha256":null,"mimeType":"image/png"},"image":image,"normalizedSha256":null,"validationError":"synthetic final validation failure"});
            let mut second = entry.clone();
            second["reference"]["candidate"]["candidateId"] = json!("second-binding");
            r["batch"]["references"] = json!([entry, second]);
            store.fail_after_publish = true;
            assert!(matches!(
                store.persist_value(r.clone()),
                Err(RecoveryError::CommitUnknown)
            ));
            assert_eq!(store.retained().unwrap()[0].private_receipt(), &r);
            store.fail_after_publish = false;
            store.persist_value(r.clone()).unwrap();
            let records = store.retained().unwrap();
            assert_eq!(records.len(), 1);
            assert_eq!(records[0].private_receipt(), &r);
            assert_eq!(records[0].private_receipt()["error"], "CommitUnknown");
            assert_eq!(
                records[0].private_receipt()["batch"]["references"]
                    .as_array()
                    .unwrap()
                    .len(),
                2
            );
        }
        #[test]
        fn authoritative_batch_serialization_is_preserved_without_rekeying() {
            let batch = crate::legacy_media::MediaBatch {
                thread_sha256: "a".repeat(64),
                references: Vec::new(),
            };
            let value = serde_json::to_value(batch).unwrap();
            // This branch has rename_all=camelCase; use typed Serialize, not report pseudocode.
            assert_eq!(value["threadSha256"], "a".repeat(64));
            assert!(value.get("thread_sha256").is_none());
        }
        #[test]
        fn tampered_record_and_symlink_configuration_fail_closed() {
            let (temp, cfg) = fixture();
            let mut store = RecoveryStore::open(&cfg).unwrap();
            let r = receipt();
            store.persist_value(r.clone()).unwrap();
            let path = cfg
                .expected_data_directory
                .join(DIRECTORY)
                .join(format!("{}.json", r["receiptId"].as_str().unwrap()));
            fs::write(path, b"{}").unwrap();
            assert!(matches!(
                store.retained(),
                Err(RecoveryError::InvalidRecord)
            ));
            drop(store);
            let alias = temp.path().join("alias");
            std::os::unix::fs::symlink(&cfg.expected_data_directory, &alias).unwrap();
            let bad = ServiceConfig {
                database_path: alias.join("fixture.db"),
                expected_data_directory: alias,
            };
            assert!(RecoveryStore::open(&bad).is_err());
        }
    }
}
#[cfg(unix)]
pub use platform::RecoveryStore;
#[cfg(not(unix))]
pub struct RecoveryStore;
#[cfg(not(unix))]
impl RecoveryStore {
    pub fn open(_: &ServiceConfig) -> RecoveryResult<Self> {
        Err(RecoveryError::Unsupported)
    }
    pub fn persist(
        &mut self,
        _: ReceiptId,
        _: &CompletionReceipt,
    ) -> RecoveryResult<DurableOwnership> {
        Err(RecoveryError::Unsupported)
    }
    pub fn retained(&self) -> RecoveryResult<Vec<RecoveryRecord>> {
        Err(RecoveryError::Unsupported)
    }
}
