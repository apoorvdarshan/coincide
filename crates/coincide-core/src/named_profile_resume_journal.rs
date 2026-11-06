//! Private continuation journal, deliberately outside Store documents/imports.
//! This authenticates app-minted receipts; it is not a defence against a local
//! user who can replace both this database and its private authentication key.
#[cfg(unix)]
use anyhow::Context as _;
use anyhow::{Result, ensure};
use ring::hmac;
#[cfg(unix)]
use ring::rand::{SecureRandom, SystemRandom};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;
use std::{
    collections::HashMap,
    fs::{self, File},
    io::{Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

#[cfg(unix)]
use std::{fs::OpenOptions, io::Read};
const MAX_RECORD: usize = 32 * 1024;
pub(super) struct Journal {
    db: Connection,
    key: hmac::Key,
    // The key file doubles as an exclusive process/Engine lease. It is never
    // removed: unlinking a lock would let another process lock a new inode.
    lease: File,
    key_path: PathBuf,
    db_path: PathBuf,
    key_identity: (u64, u64),
    db_identity: (u64, u64),
    source: Value,
    tickets: HashMap<String, String>,
}
impl Journal {
    #[cfg(unix)]
    pub(super) fn open(store: &crate::store::Store) -> Result<Self> {
        use std::os::{
            fd::AsRawFd,
            unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        };
        let source_path = store.resume_source_path()?;
        let source_meta = fs::symlink_metadata(&source_path)?;
        let parent = source_path.parent().context("Missing Store directory")?;
        private(parent, true)?;
        // Full filename is included: independent Stores in one directory must
        // never share a key, lease, namespace or continuation receipt.
        let name = source_path
            .file_name()
            .context("Missing Store filename")?
            .to_str()
            .context("Invalid Store filename")?;
        let directory = parent.join(format!(".{name}.native-resume-v1"));
        match fs::create_dir(&directory) {
            Ok(()) => fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
        private(&directory, true)?;
        let key_path = directory.join("authority.key");
        let db_path = directory.join("receipts.sqlite");
        let mut options = OpenOptions::new();
        options
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
        let mut lease = match options.create_new(true).open(&key_path) {
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
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                options.create_new(false).open(&key_path)?
            }
            Err(error) => return Err(error.into()),
        };
        private(&key_path, false)?;
        // SAFETY: the descriptor is live and the nonblocking exclusive flock
        // has no borrowed pointers. Closing the retained file releases it.
        ensure!(
            unsafe { libc::flock(lease.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
            "Continuation journal belongs to another Engine"
        );
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
        let key_identity = identity(&lease.metadata()?);
        let mut options = OpenOptions::new();
        options
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
        let file = options.open(&db_path)?;
        private(&db_path, false)?;
        let db_identity = identity(&file.metadata()?);
        let db = Connection::open(&db_path)?;
        db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS receipts(id TEXT PRIMARY KEY, document BLOB NOT NULL, mac BLOB NOT NULL);")?;
        let source = serde_json::json!({"path":source_path,"device":source_meta.dev(),"inode":source_meta.ino(),"version":1});
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
    // Non-Unix file ACLs/locking have not been established for this authority
    // path. Fail closed rather than treating a permissive key as trusted.
    #[cfg(not(unix))]
    pub(super) fn open(_: &crate::store::Store) -> Result<Self> {
        anyhow::bail!("Durable named continuation requires Unix private file ownership")
    }
    fn validate(&self) -> Result<()> {
        private(&self.key_path, false)?;
        private(&self.db_path, false)?;
        ensure!(
            identity(&self.lease.metadata()?) == self.key_identity
                && identity(&fs::symlink_metadata(&self.key_path)?) == self.key_identity
                && identity(&fs::symlink_metadata(&self.db_path)?) == self.db_identity,
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
#[cfg(unix)]
fn identity(metadata: &fs::Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (metadata.dev(), metadata.ino())
}
#[cfg(not(unix))]
fn identity(_: &fs::Metadata) -> (u64, u64) {
    (0, 0)
}
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

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::store::Store;
    use serde_json::json;
    fn fixture() -> (tempfile::TempDir, Store, Journal) {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let store = Store::open(&dir.path().join("state.sqlite")).unwrap();
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
        let (dir, store, mut a) = fixture();
        assert!(Journal::open(&store).is_err());
        let other = Store::open(&dir.path().join("other.sqlite")).unwrap();
        let mut b = Journal::open(&other).unwrap();
        a.put("thread", &json!({"native":"synthetic-a"})).unwrap();
        b.put("thread", &json!({"native":"synthetic-b"})).unwrap();
        assert_eq!(a.take("thread").unwrap().unwrap()["native"], "synthetic-a");
        assert_eq!(b.take("thread").unwrap().unwrap()["native"], "synthetic-b");
    }
    #[test]
    fn copied_whole_journal_cannot_bind_another_store() {
        let (dir, _store, mut journal) = fixture();
        journal
            .put("thread", &json!({"native":"synthetic-owned"}))
            .unwrap();
        let original_key = journal.key_path.clone();
        let original_db = journal.db_path.clone();
        let other = Store::open(&dir.path().join("other.sqlite")).unwrap();
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
