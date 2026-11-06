//! Private continuation journal, deliberately outside Store documents/imports.
//! This authenticates app-minted receipts; it is not a defence against a local
//! user who can replace both this database and its private authentication key.
#[cfg(any(unix, windows))]
use anyhow::Context as _;
use anyhow::{Result, ensure};
use ring::hmac;
#[cfg(any(unix, windows))]
use ring::rand::{SecureRandom, SystemRandom};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;
use std::{
    collections::HashMap,
    fs::{self, File},
    io::{Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

#[cfg(any(unix, windows))]
use std::io::Read;
const MAX_RECORD: usize = 32 * 1024;
pub(super) struct Journal {
    db: Connection,
    key: hmac::Key,
    // The key file doubles as an exclusive process/Engine lease. It is never
    // removed: unlinking a lock would let another process lock a new inode.
    lease: File,
    key_path: PathBuf,
    db_path: PathBuf,
    key_identity: crate::private_fs::Identity,
    db_identity: crate::private_fs::Identity,
    source: Value,
    tickets: HashMap<String, String>,
}
impl Journal {
    #[cfg(any(unix, windows))]
    pub(super) fn open(store: &crate::store::Store) -> Result<Self> {
        let source_path = store.resume_source_path()?;
        let source_identity = crate::private_fs::identity(&source_path)?;
        let parent = source_path.parent().context("Missing Store directory")?;
        #[cfg(unix)]
        private(parent, true)?;
        #[cfg(windows)]
        crate::private_fs::windows::verify_inherited(parent, true)?;
        // Full filename is included: independent Stores in one directory must
        // never share a key, lease, namespace or continuation receipt.
        let name = source_path
            .file_name()
            .context("Missing Store filename")?
            .to_str()
            .context("Invalid Store filename")?;
        let directory = parent.join(format!(".{name}.native-resume-v1"));
        create_directory(&directory)?;
        private(&directory, true)?;
        let key_path = directory.join("authority.key");
        let db_path = directory.join("receipts.sqlite");
        let mut lease = match open_file(&key_path, true) {
            Ok(mut file) => {
                // A missing key beside an old journal is never permission to
                // adopt it. Keep the old bytes for diagnosis; start fresh only.
                ensure!(!db_path.exists(), "Continuation key is missing");
                let mut secret = [0u8; 32];
                SystemRandom::new()
                    .fill(&mut secret)
                    .map_err(|_| anyhow::anyhow!("Could not create continuation key"))?;
                file.write_all(&secret)?;
                file.write_all(b"{}")?;
                file.sync_all()?;
                file
            }
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|error| error.kind() == std::io::ErrorKind::AlreadyExists) =>
            {
                open_file(&key_path, false)?
            }
            Err(error) => return Err(error),
        };
        private(&key_path, false)?;
        lock(&lease)?;
        ensure!(
            (34..=MAX_RECORD as u64).contains(&lease.metadata()?.len()),
            "Invalid continuation authority state"
        );
        lease.seek(SeekFrom::Start(0))?;
        let mut secret = [0u8; 32];
        lease.read_exact(&mut secret)?;
        let mut state = Vec::new();
        std::io::Read::by_ref(&mut lease)
            .take(MAX_RECORD as u64)
            .read_to_end(&mut state)?;
        let tickets: HashMap<String, String> = serde_json::from_slice(&state)?;
        ensure!(
            tickets.len() <= 128,
            "Continuation authority state exceeds its bound"
        );
        let key = hmac::Key::new(hmac::HMAC_SHA256, &secret);
        secret.fill(0);
        let key_identity = crate::private_fs::file_identity(&lease)?;
        let file = match open_file(&db_path, true) {
            Ok(file) => file,
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|error| error.kind() == std::io::ErrorKind::AlreadyExists) =>
            {
                open_file(&db_path, false)?
            }
            Err(error) => return Err(error),
        };
        private(&db_path, false)?;
        let db_identity = crate::private_fs::file_identity(&file)?;
        let db = Connection::open(&db_path)?;
        db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS receipts(id TEXT PRIMARY KEY, document BLOB NOT NULL, mac BLOB NOT NULL);")?;
        let source = serde_json::json!({"path":source_path,"identity":source_identity,"version":1});
        Ok(Self {
            db,
            key,
            lease,
            key_path,
            db_path,
            key_identity,
            db_identity,
            source,
            tickets,
        })
    }
    // Unknown platforms cannot substitute unverified file ownership for authority.
    #[cfg(not(any(unix, windows)))]
    pub(super) fn open(_: &crate::store::Store) -> Result<Self> {
        anyhow::bail!("Durable named continuation requires private file ownership support")
    }
    fn validate(&self) -> Result<()> {
        private(&self.key_path, false)?;
        private(&self.db_path, false)?;
        ensure!(
            crate::private_fs::file_identity(&self.lease)? == self.key_identity
                && crate::private_fs::identity(&self.key_path)? == self.key_identity
                && crate::private_fs::identity(&self.db_path)? == self.db_identity,
            "Continuation journal identity changed"
        );
        Ok(())
    }
    pub(super) fn put(&mut self, id: &str, receipt: &Value) -> Result<()> {
        self.validate()?;
        let ticket = uuid::Uuid::new_v4().to_string();
        let document = serde_json::to_vec(
            &serde_json::json!({"source":self.source,"receipt":receipt,"ticket":ticket}),
        )?;
        ensure!(
            document.len() <= MAX_RECORD,
            "Continuation receipt exceeds its bound"
        );
        let mac = hmac::sign(&self.key, &document);
        // This independent private state prevents replay of copied journal
        // rows. Persist before minting; a crash may lose an opportunity only.
        if self.tickets.len() >= 128 {
            self.tickets.clear();
        }
        self.tickets.insert(id.into(), ticket);
        self.save_tickets()?;
        let tx = self.db.transaction()?;
        // Bound persistent state as well as the in-memory registry.
        let count: i64 = tx.query_row("SELECT count(*) FROM receipts", [], |row| row.get(0))?;
        if count >= 128 {
            tx.execute("DELETE FROM receipts", [])?;
        }
        tx.execute(
            "INSERT OR REPLACE INTO receipts(id,document,mac) VALUES (?1,?2,?3)",
            params![id, document, mac.as_ref()],
        )?;
        tx.commit()?;
        Ok(())
    }
    pub(super) fn take(&mut self, id: &str) -> Result<Option<Value>> {
        self.validate()?;
        let ticket = self.tickets.remove(id);
        // Consume before the DELETE and launch. Restoring a MAC-valid old row
        // cannot resurrect an already consumed ticket.
        self.save_tickets()?;
        let tx = self.db.transaction()?;
        // Bound before SQLite allocates the payload. Oversized/corrupt records
        // are still deleted atomically, so restoring old JSON cannot retry one.
        let row: Option<(Vec<u8>, Vec<u8>)> = tx.query_row(
            "SELECT document,mac FROM receipts WHERE id=?1 AND length(document)<=?2 AND length(mac)=32",
            params![id, MAX_RECORD as i64], |row| Ok((row.get(0)?, row.get(1)?))).optional()?;
        tx.execute("DELETE FROM receipts WHERE id=?1", [id])?;
        tx.commit()?; // Must reach durable commit before any provider launch.
        let Some((document, mac)) = row else {
            return Ok(None);
        };
        if hmac::verify(&self.key, &document, &mac).is_err() {
            return Ok(None);
        }
        let Ok(value) = serde_json::from_slice::<Value>(&document) else {
            return Ok(None);
        };
        if value["source"] != self.source {
            return Ok(None);
        }
        if ticket.is_none() || ticket.as_deref() != value["ticket"].as_str() {
            return Ok(None);
        }
        Ok(value.get("receipt").cloned())
    }
    fn save_tickets(&mut self) -> Result<()> {
        let bytes = serde_json::to_vec(&self.tickets)?;
        ensure!(
            bytes.len() + 32 <= MAX_RECORD,
            "Continuation authority state exceeds its bound"
        );
        self.lease.seek(SeekFrom::Start(32))?;
        self.lease.write_all(&bytes)?;
        self.lease.set_len((32 + bytes.len()) as u64)?;
        self.lease.sync_all()?;
        Ok(())
    }
}
fn create_directory(path: &Path) -> Result<()> {
    #[cfg(windows)]
    {
        crate::private_fs::windows::create_directory(path)
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        let mut builder = fs::DirBuilder::new();
        builder.mode(0o700);
        match builder.create(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
        Ok(())
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = path;
        anyhow::bail!("Private authority unavailable")
    }
}
fn open_file(path: &Path, new: bool) -> Result<File> {
    #[cfg(windows)]
    {
        crate::private_fs::windows::open_file(path, new)
    }
    #[cfg(unix)]
    {
        use std::{fs::OpenOptions, os::unix::fs::OpenOptionsExt};
        let mut options = OpenOptions::new();
        options
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .create_new(new);
        Ok(options.open(path)?)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = (path, new);
        anyhow::bail!("Private authority unavailable")
    }
}
fn lock(file: &File) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        ensure!(
            unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
            "Continuation journal belongs to another Engine"
        );
    }
    #[cfg(windows)]
    file.try_lock()
        .context("Continuation journal belongs to another Engine")?;
    Ok(())
}
#[cfg(windows)]
fn private(path: &Path, directory: bool) -> Result<()> {
    crate::private_fs::windows::verify(path, directory)
}
#[cfg(not(windows))]
fn private(path: &Path, directory: bool) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    ensure!(
        !metadata.file_type().is_symlink()
            && if directory {
                metadata.is_dir()
            } else {
                metadata.is_file()
            },
        "Invalid private continuation path"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        // SAFETY: geteuid only reads the effective OS account identity.
        ensure!(
            metadata.uid() == unsafe { libc::geteuid() }
                && metadata.permissions().mode() & 0o077 == 0
                && (directory || metadata.nlink() == 1),
            "Unsafe private continuation ownership or permissions"
        );
    }
    Ok(())
}

#[cfg(all(test, any(unix, windows)))]
mod tests {
    use super::*;
    use crate::store::Store;
    use serde_json::json;
    fn fixture() -> (tempfile::TempDir, Store, Journal) {
        let dir = tempfile::tempdir().unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        }
        let store = Store::open(&dir.path().join("data/state.sqlite")).unwrap();
        let journal = Journal::open(&store).unwrap();
        (dir, store, journal)
    }
    #[test]
    fn restart_retains_only_app_minted_one_attempt_receipts() {
        let (_dir, store, mut journal) = fixture();
        let receipt = json!({"native":"synthetic-owned","context":{"opaque":42}});
        journal.put("thread", &receipt).unwrap();
        let copied: (Vec<u8>, Vec<u8>) = journal
            .db
            .query_row("SELECT document,mac FROM receipts", [], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .unwrap();
        drop(journal);
        let mut journal = Journal::open(&store).unwrap();
        assert_eq!(journal.take("thread").unwrap(), Some(receipt));
        journal
            .db
            .execute(
                "INSERT INTO receipts VALUES (?1,?2,?3)",
                params!["thread", copied.0, copied.1],
            )
            .unwrap();
        drop(journal);
        let mut journal = Journal::open(&store).unwrap();
        assert!(
            journal.take("thread").unwrap().is_none(),
            "Copied MAC-valid row cannot restore a consumed private ticket"
        );
        assert!(journal.take("thread").unwrap().is_none());
    }
    #[test]
    fn corruption_and_oversized_payloads_are_consumed_without_authority() {
        let (_dir, _store, mut journal) = fixture();
        for body in [b"{}".to_vec(), vec![b'x'; MAX_RECORD + 1]] {
            journal
                .put("thread", &json!({"native":"synthetic-owned"}))
                .unwrap();
            journal
                .db
                .execute("UPDATE receipts SET document=?1", [body])
                .unwrap();
            assert!(journal.take("thread").unwrap().is_none());
            assert_eq!(
                journal
                    .db
                    .query_row("SELECT count(*) FROM receipts", [], |row| row
                        .get::<_, i64>(0))
                    .unwrap(),
                0
            );
        }
    }
    #[test]
    fn independent_store_identity_and_exclusive_engine_lease() {
        let (_dir, store, mut a) = fixture();
        assert!(Journal::open(&store).is_err());
        let other = Store::open(&store.data_directory().unwrap().join("other.sqlite")).unwrap();
        let mut b = Journal::open(&other).unwrap();
        a.put("thread", &json!({"native":"synthetic-a"})).unwrap();
        b.put("thread", &json!({"native":"synthetic-b"})).unwrap();
        assert_eq!(a.take("thread").unwrap().unwrap()["native"], "synthetic-a");
        assert_eq!(b.take("thread").unwrap().unwrap()["native"], "synthetic-b");
    }
    #[test]
    fn copied_whole_journal_cannot_bind_another_store() {
        let (_dir, store, mut journal) = fixture();
        journal
            .put("thread", &json!({"native":"synthetic-owned"}))
            .unwrap();
        let original_key = journal.key_path.clone();
        let original_db = journal.db_path.clone();
        let other = Store::open(&store.data_directory().unwrap().join("other.sqlite")).unwrap();
        let b = Journal::open(&other).unwrap();
        let key = b.key_path.clone();
        let db = b.db_path.clone();
        drop(b);
        fs::copy(original_key, &key).unwrap();
        fs::copy(original_db, &db).unwrap();
        let mut b = Journal::open(&other).unwrap();
        assert!(
            b.take("thread").unwrap().is_none(),
            "Authenticated bytes still belong to the source Store inode/path"
        );
    }
    #[test]
    fn failed_mint_and_failed_consume_never_leave_reusable_authority() {
        let (_dir, store, mut journal) = fixture();
        journal.db.execute_batch("CREATE TRIGGER reject_mint BEFORE INSERT ON receipts BEGIN SELECT RAISE(FAIL,'synthetic failure'); END;").unwrap();
        assert!(
            journal
                .put("thread", &json!({"native":"synthetic-owned"}))
                .is_err()
        );
        assert!(journal.take("thread").unwrap().is_none());
        journal
            .db
            .execute_batch("DROP TRIGGER reject_mint;")
            .unwrap();
        journal
            .put("thread", &json!({"native":"synthetic-owned"}))
            .unwrap();
        journal.db.execute_batch("CREATE TRIGGER reject_consume BEFORE DELETE ON receipts BEGIN SELECT RAISE(FAIL,'synthetic failure'); END;").unwrap();
        assert!(journal.take("thread").is_err());
        journal
            .db
            .execute_batch("DROP TRIGGER reject_consume;")
            .unwrap();
        drop(journal);
        let mut journal = Journal::open(&store).unwrap();
        assert!(
            journal.take("thread").unwrap().is_none(),
            "Private ticket was already durably consumed before failed DELETE"
        );
    }
    #[cfg(unix)]
    #[test]
    fn missing_key_unsafe_permissions_and_symlinks_fail_closed() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let (_dir, store, journal) = fixture();
        let key = journal.key_path.clone();
        drop(journal);
        fs::set_permissions(&key, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(Journal::open(&store).is_err());
        fs::set_permissions(&key, fs::Permissions::from_mode(0o600)).unwrap();
        let saved = key.with_extension("saved");
        fs::rename(&key, &saved).unwrap();
        symlink(&saved, &key).unwrap();
        assert!(Journal::open(&store).is_err());
        fs::remove_file(&key).unwrap();
        assert!(
            Journal::open(&store).is_err(),
            "Missing key must not adopt the old journal"
        );
        assert!(
            Journal::open(&store).is_err(),
            "A partial replacement cannot become a trusted key on retry"
        );
    }
}
