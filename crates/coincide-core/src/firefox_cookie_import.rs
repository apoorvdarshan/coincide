//! Native-selected Firefox cookie snapshots. Secrets never enter JSON or Debug.
//! No source scanning, decryption, source writes, navigation or native insertion.
use rusqlite::{Connection, OpenFlags};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::Read,
    path::{Path, PathBuf},
};
use uuid::Uuid;
const MAX_SOURCE: u64 = 16 * 1024 * 1024;
const MAX_ROWS: usize = 1000;
const MAX_VALUES: usize = 1024 * 1024;
#[must_use = "Retain cleanup-pending custody until explicit cleanup succeeds"]
pub enum Failure {
    SourceUnavailable,
    SourceChanged,
    LiveSource,
    InvalidSnapshot,
    LimitExceeded,
    InvalidSelection,
    StaleContext,
    CleanupPending(Box<CleanupCustody>),
}
impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::SourceUnavailable => "Choose a readable regular Firefox cookie snapshot",
            Self::SourceChanged => "Cookie source changed; choose and review it again",
            Self::LiveSource => "Choose a standalone cookie snapshot without live SQLite sidecars",
            Self::InvalidSnapshot => "Unsupported Firefox cookie snapshot",
            Self::LimitExceeded => "Cookie snapshot exceeds import limits",
            Self::InvalidSelection => "Choose only reviewed cookie hosts",
            Self::StaleContext => "Browser import context changed",
            Self::CleanupPending(_) => "Private cookie snapshot cleanup is pending",
        })
    }
}
impl std::fmt::Debug for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(self, f)
    }
}
impl std::error::Error for Failure {}
type Result<T> = std::result::Result<T, Failure>;
/// Construct only from a native chooser. Not an agent-path or JSON authority.
pub struct NativeSource {
    path: PathBuf,
}
impl NativeSource {
    pub fn from_native_choice(path: PathBuf) -> Self {
        Self { path }
    }
}
#[derive(Clone, PartialEq, Eq)]
pub struct Binding {
    pub thread: Uuid,
    pub profile: Uuid,
    pub epoch: u64,
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum SameSite {
    Unspecified,
    None,
    Lax,
    Strict,
}
/// No Debug, Serialize or Clone: only the trusted native sink may read values.
pub struct Cookie {
    domain: String,
    name: String,
    value: String,
    path: String,
    expires: Option<i64>,
    secure: bool,
    http_only: bool,
    same_site: SameSite,
}
impl Cookie {
    pub fn domain(&self) -> &str {
        &self.domain
    }
    pub fn name(&self) -> &str {
        &self.name
    }
    pub fn value(&self) -> &str {
        &self.value
    }
    pub fn path(&self) -> &str {
        &self.path
    }
    pub fn expires(&self) -> Option<i64> {
        self.expires
    }
    pub fn secure(&self) -> bool {
        self.secure
    }
    pub fn http_only(&self) -> bool {
        self.http_only
    }
    pub fn same_site(&self) -> SameSite {
        self.same_site
    }
}
/// Metadata intentionally contains neither names/values nor source file paths.
pub struct HostCount {
    pub host: String,
    pub cookies: usize,
}
pub struct Preview {
    pub hosts: Vec<HostCount>,
    pub expired: usize,
    pub unsupported: usize,
}
pub struct Plan {
    source: NativeSource,
    identity: SourceIdentity,
    fingerprint: [u8; 32],
    cookies: Vec<Cookie>,
    preview: Preview,
}
pub struct ApprovedPlan {
    binding: Binding,
    cookies: std::vec::IntoIter<Cookie>,
}
fn sidecars(path: &Path) -> Result<()> {
    for suffix in ["-wal", "-shm", "-journal"] {
        let mut name = path.as_os_str().to_os_string();
        name.push(suffix);
        match fs::symlink_metadata(PathBuf::from(name)) {
            Ok(_) => return Err(Failure::LiveSource),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(Failure::SourceUnavailable),
        }
    }
    Ok(())
}
fn source_file(path: &Path) -> Result<File> {
    sidecars(path)?;
    if fs::symlink_metadata(path)
        .map_err(|_| Failure::SourceUnavailable)?
        .file_type()
        .is_symlink()
    {
        return Err(Failure::SourceUnavailable);
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000);
    }
    let file = options.open(path).map_err(|_| Failure::SourceUnavailable)?;
    let metadata = file.metadata().map_err(|_| Failure::SourceUnavailable)?;
    if !metadata.is_file() {
        return Err(Failure::SourceUnavailable);
    }
    if metadata.len() > MAX_SOURCE {
        return Err(Failure::LimitExceeded);
    }
    Ok(file)
}
#[derive(PartialEq, Eq)]
struct SourceIdentity {
    len: u64,
    modified: Option<std::time::SystemTime>,
    device: u64,
    inode: u64,
}
fn identity(metadata: &fs::Metadata) -> SourceIdentity {
    #[cfg(unix)]
    let (device, inode) = {
        use std::os::unix::fs::MetadataExt;
        (metadata.dev(), metadata.ino())
    };
    #[cfg(not(unix))]
    let (device, inode) = (0, 0);
    SourceIdentity {
        len: metadata.len(),
        modified: metadata.modified().ok(),
        device,
        inode,
    }
}
fn source_bytes(path: &Path) -> Result<(Vec<u8>, SourceIdentity)> {
    let file = source_file(path)?;
    let before = identity(&file.metadata().map_err(|_| Failure::SourceUnavailable)?);
    let mut data = Vec::new();
    file.take(MAX_SOURCE + 1)
        .read_to_end(&mut data)
        .map_err(|_| Failure::SourceUnavailable)?;
    if data.len() as u64 > MAX_SOURCE {
        return Err(Failure::LimitExceeded);
    }
    sidecars(path)?;
    let after = identity(&fs::symlink_metadata(path).map_err(|_| Failure::SourceUnavailable)?);
    if before != after {
        return Err(Failure::SourceChanged);
    }
    Ok((data, before))
}
// Only this task-created private directory is removed. Source paths are never
// passed to SQLite, including readonly opens that might touch WAL/SHM files.
/// Private cleanup ownership, never serialized or path-bearing in diagnostics.
/// Parent MUST retain this record on its worker owner until retry returns true.
#[must_use = "Retain this owner until retry confirms cleanup"]
pub struct CleanupCustody {
    id: Uuid,
    directory: PathBuf,
    database: PathBuf,
    directory_identity: Option<SourceIdentity>,
    connection: Option<Connection>,
    original_error: Option<Box<Failure>>,
}
type PrivateCopy = CleanupCustody;
impl CleanupCustody {
    pub fn id(&self) -> Uuid {
        self.id
    }
    pub fn original_error(&self) -> Option<&Failure> {
        self.original_error.as_deref()
    }
    /// Off UI only. No source paths are retained here. Never retry insertion.
    pub fn retry(&mut self) -> bool {
        self.cleanup_with(|path| fs::remove_dir_all(path))
    }
    fn cleanup_with(&mut self, mut remove: impl FnMut(&Path) -> std::io::Result<()>) -> bool {
        if let Some(connection) = self.connection.take()
            && let Err((connection, _)) = connection.close()
        {
            self.connection = Some(connection);
            return false;
        }
        match fs::symlink_metadata(&self.directory) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return true,
            Err(_) => return false,
            Ok(metadata) => {
                let Some(expected) = self.directory_identity.as_ref() else {
                    return false;
                };
                let actual = identity(&metadata);
                if !metadata.is_dir()
                    || metadata.file_type().is_symlink()
                    || actual.device != expected.device
                    || actual.inode != expected.inode
                {
                    return false;
                }
            }
        }
        if remove(&self.directory).is_err() {
            return false;
        }
        matches!(fs::symlink_metadata(&self.directory),Err(error) if error.kind()==std::io::ErrorKind::NotFound)
    }
    fn finish<T>(
        mut self,
        result: Result<T>,
        remove: impl FnMut(&Path) -> std::io::Result<()>,
    ) -> Result<T> {
        if self.cleanup_with(remove) {
            return result;
        }
        self.original_error = result.err().map(Box::new);
        Err(Failure::CleanupPending(Box::new(self)))
    }
    fn create(bytes: &[u8]) -> Result<Self> {
        if !cfg!(unix) {
            return Err(Failure::SourceUnavailable);
        }
        let id = Uuid::new_v4();
        let directory = std::env::temp_dir().join(format!("coincide-cookie-snapshot-{id}"));
        let mut builder = fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder
            .create(&directory)
            .map_err(|_| Failure::SourceUnavailable)?;
        let mut copy = Self {
            id,
            database: directory.join("snapshot.sqlite"),
            directory,
            directory_identity: None,
            connection: None,
            original_error: None,
        };
        let result = (|| {
            copy.directory_identity = Some(identity(
                &fs::symlink_metadata(&copy.directory).map_err(|_| Failure::SourceUnavailable)?,
            ));
            // SQLite NOFOLLOW rejects symlinks in ANY path component. macOS
            // temp roots commonly use /var or /tmp aliases. Resolve only our
            // newly created private directory, then verify its owned inode.
            let physical =
                fs::canonicalize(&copy.directory).map_err(|_| Failure::SourceUnavailable)?;
            let actual =
                identity(&fs::symlink_metadata(&physical).map_err(|_| Failure::SourceUnavailable)?);
            let expected = copy
                .directory_identity
                .as_ref()
                .ok_or(Failure::SourceUnavailable)?;
            if actual.device != expected.device || actual.inode != expected.inode {
                return Err(Failure::SourceChanged);
            }
            copy.directory = physical;
            copy.database = copy.directory.join("snapshot.sqlite");
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options
                .open(&copy.database)
                .map_err(|_| Failure::SourceUnavailable)?;
            std::io::Write::write_all(&mut file, bytes).map_err(|_| Failure::SourceUnavailable)
        })();
        match result {
            Ok(()) => Ok(copy),
            Err(error) => copy.finish(Err(error), |path| fs::remove_dir_all(path)),
        }
    }
}
fn valid_cookie(c: &Cookie) -> bool {
    let host = c.domain.strip_prefix('.').unwrap_or(&c.domain);
    let host_valid = url::Host::parse(host)
        .ok()
        .is_some_and(|parsed| parsed.to_string() == host && !host.is_empty());
    host_valid
        && !c.domain.ends_with('.')
        && c.domain.len() <= 253
        && !c.name.is_empty()
        && c.name.len() + c.value.len() <= 4096
        && c.name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
        && c.value.bytes().all(|b| b >= 0x20 && b != 0x7f && b != b';')
        && c.path.starts_with('/')
        && c.path.len() <= 2048
        && !c.path.chars().any(char::is_control)
        && (c.same_site != SameSite::None || c.secure)
        && (!c.name.starts_with("__Secure-") || c.secure)
        && (!c.name.starts_with("__Host-")
            || (c.secure && !c.domain.starts_with('.') && c.path == "/"))
}
impl Plan {
    /// Off UI only. Closed-file snapshot, not a live-browser consistency claim.
    /// Source bytes are read with no-follow; SQLite opens ONLY our private copy.
    pub fn read(source: NativeSource, now: i64) -> Result<Self> {
        Self::read_with_cleanup(source, now, |path| fs::remove_dir_all(path))
    }
    fn read_with_cleanup(
        source: NativeSource,
        now: i64,
        remove: impl FnMut(&Path) -> std::io::Result<()>,
    ) -> Result<Self> {
        let (bytes, identity) = source_bytes(&source.path)?;
        let before = Sha256::digest(&bytes).into();
        let mut copy = PrivateCopy::create(&bytes)?;
        let result = (|| {
            let db = Connection::open_with_flags(
                &copy.database,
                OpenFlags::SQLITE_OPEN_READ_ONLY
                    | OpenFlags::SQLITE_OPEN_NO_MUTEX
                    | OpenFlags::SQLITE_OPEN_NOFOLLOW,
            )
            .map_err(|_| Failure::InvalidSnapshot)?;
            copy.connection = Some(db);
            let (cookies, preview) = Self::decode_copy(
                copy.connection.as_ref().ok_or(Failure::InvalidSnapshot)?,
                now,
            )?;
            let (after, after_identity) = source_bytes(&source.path)?;
            if bytes != after || identity != after_identity {
                return Err(Failure::SourceChanged);
            }
            Ok(Self {
                source,
                identity,
                fingerprint: before,
                cookies,
                preview,
            })
        })();
        // Even decode/source-validation failures explicitly close SQLite first.
        // A close or deletion failure returns its exact private cleanup owner.
        copy.finish(result, remove)
    }
    fn decode_copy(db: &Connection, now: i64) -> Result<(Vec<Cookie>, Preview)> {
        db.busy_timeout(std::time::Duration::ZERO)
            .map_err(|_| Failure::InvalidSnapshot)?;
        db.execute_batch("PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; BEGIN;")
            .map_err(|_| Failure::InvalidSnapshot)?;
        let schema: String = db
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name='moz_cookies'",
                [],
                |r| r.get(0),
            )
            .map_err(|_| Failure::InvalidSnapshot)?;
        if schema.to_ascii_lowercase().contains("virtual") {
            return Err(Failure::InvalidSnapshot);
        }
        let columns: BTreeSet<String> = db
            .prepare("PRAGMA table_info(moz_cookies)")
            .map_err(|_| Failure::InvalidSnapshot)?
            .query_map([], |r| r.get(1))
            .map_err(|_| Failure::InvalidSnapshot)?
            .collect::<std::result::Result<_, _>>()
            .map_err(|_| Failure::InvalidSnapshot)?;
        for required in [
            "host",
            "name",
            "value",
            "path",
            "expiry",
            "isSecure",
            "isHttpOnly",
            "originAttributes",
            "sameSite",
        ] {
            if !columns.contains(required) {
                return Err(Failure::InvalidSnapshot);
            }
        }
        // Known partition markers are checked per row; unknown partition schema
        // is refused rather than silently widening its cookies into shared scope.
        if columns.iter().any(|name| {
            name.to_ascii_lowercase().contains("partition")
                && name != "isPartitionedAttributeSet"
                && name != "partitionKey"
        }) {
            return Err(Failure::InvalidSnapshot);
        }
        let partition_flag = if columns.contains("isPartitionedAttributeSet") {
            "isPartitionedAttributeSet"
        } else {
            "0"
        };
        let partition_key = if columns.contains("partitionKey") {
            "partitionKey"
        } else {
            "''"
        };
        let count: i64 = db
            .query_row("SELECT count(*) FROM moz_cookies", [], |r| r.get(0))
            .map_err(|_| Failure::InvalidSnapshot)?;
        if count < 0 || count as usize > MAX_ROWS {
            return Err(Failure::LimitExceeded);
        }
        let query = format!(
            "SELECT host,name,value,path,expiry,isSecure,isHttpOnly,sameSite,originAttributes,{partition_flag},{partition_key} FROM moz_cookies LIMIT 1001"
        );
        let mut statement = db.prepare(&query).map_err(|_| Failure::InvalidSnapshot)?;
        let mut rows = statement.query([]).map_err(|_| Failure::InvalidSnapshot)?;
        let mut cookies = Vec::new();
        let mut keys = BTreeSet::new();
        let mut hosts = BTreeMap::new();
        let (mut expired, mut unsupported, mut total) = (0, 0, 0usize);
        while let Some(row) = rows.next().map_err(|_| Failure::InvalidSnapshot)? {
            let read = || -> rusqlite::Result<(Cookie, String, i64)> {
                let same: i64 = row.get(7)?;
                let secure: i64 = row.get(5)?;
                let http_only: i64 = row.get(6)?;
                let expiry: i64 = row.get(4)?;
                let partition_flag: i64 = row.get(9)?;
                let partition_key: String = row.get(10)?;
                Ok((
                    Cookie {
                        domain: row.get(0)?,
                        name: row.get(1)?,
                        value: row.get(2)?,
                        path: row.get(3)?,
                        expires: Some(expiry),
                        secure: secure == 1,
                        http_only: http_only == 1,
                        same_site: match same {
                            0 => SameSite::None,
                            1 => SameSite::Lax,
                            2 => SameSite::Strict,
                            _ => SameSite::Unspecified,
                        },
                    },
                    row.get(8)?,
                    if partition_flag == 0
                        && partition_key.is_empty()
                        && expiry <= 253402300799
                        && (0..=2).contains(&same)
                        && (0..=1).contains(&secure)
                        && (0..=1).contains(&http_only)
                    {
                        expiry
                    } else {
                        -1
                    },
                ))
            };
            let (cookie, attributes, expiry) = read().map_err(|_| Failure::InvalidSnapshot)?;
            total = total
                .checked_add(cookie.value.len())
                .ok_or(Failure::LimitExceeded)?;
            if total > MAX_VALUES {
                return Err(Failure::LimitExceeded);
            }
            if expiry < 0 || !attributes.is_empty() || !valid_cookie(&cookie) {
                unsupported += 1;
                continue;
            }
            // Firefox persists expiry as Unix seconds. No guessed session expiry.
            if expiry <= now {
                expired += 1;
                continue;
            }
            if !keys.insert((
                cookie.domain.clone(),
                cookie.path.clone(),
                cookie.name.clone(),
            )) {
                return Err(Failure::InvalidSnapshot);
            }
            *hosts
                .entry(cookie.domain.trim_start_matches('.').to_owned())
                .or_insert(0) += 1;
            cookies.push(cookie);
        }
        drop(rows);
        drop(statement);
        db.execute_batch("COMMIT")
            .map_err(|_| Failure::InvalidSnapshot)?;
        Ok((
            cookies,
            Preview {
                hosts: hosts
                    .into_iter()
                    .map(|(host, cookies)| HostCount { host, cookies })
                    .collect(),
                expired,
                unsupported,
            },
        ))
    }
    pub fn preview(&self) -> &Preview {
        &self.preview
    }
    /// Explicit native review only, off UI. Consumes the secret plan and checks
    /// the exact selected source again; never performs navigation or insertion.
    pub fn approve(self, hosts: &[String], binding: Binding) -> Result<ApprovedPlan> {
        if hosts.is_empty() || hosts.len() > MAX_ROWS {
            return Err(Failure::InvalidSelection);
        }
        let selected: BTreeSet<&str> = hosts.iter().map(String::as_str).collect();
        if selected.len() != hosts.len()
            || selected
                .iter()
                .any(|host| !self.preview.hosts.iter().any(|row| row.host == *host))
        {
            return Err(Failure::InvalidSelection);
        }
        let (bytes, identity) = source_bytes(&self.source.path)?;
        let digest: [u8; 32] = Sha256::digest(&bytes).into();
        if digest != self.fingerprint || identity != self.identity {
            return Err(Failure::SourceChanged);
        }
        let cookies = self
            .cookies
            .into_iter()
            .filter(|c| selected.contains(c.domain.trim_start_matches('.')))
            .collect::<Vec<_>>()
            .into_iter();
        Ok(ApprovedPlan { binding, cookies })
    }
}
impl ApprovedPlan {
    /// A stale route consumes no cookie. Parent admission still must close on
    /// shutdown; this binding is typed context, never imported authorization.
    pub fn next(&mut self, current: &Binding, now: i64) -> Result<Option<Cookie>> {
        if *current != self.binding {
            return Err(Failure::StaleContext);
        }
        Ok(self
            .cookies
            .by_ref()
            .find(|cookie| cookie.expires.is_some_and(|expiry| expiry > now)))
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("cookies.sqlite");
        let db = Connection::open(&path).unwrap();
        db.execute_batch("CREATE TABLE moz_cookies(host TEXT,name TEXT,value TEXT,path TEXT,expiry INTEGER,isSecure INTEGER,isHttpOnly INTEGER,sameSite INTEGER,originAttributes TEXT);").unwrap();
        db.execute("INSERT INTO moz_cookies VALUES('.example.test','session','synthetic-private-value','/',2000000000,1,1,1,'')",[]).unwrap();
        drop(db);
        (root, path)
    }
    fn binding() -> Binding {
        Binding {
            thread: Uuid::new_v4(),
            profile: Uuid::new_v4(),
            epoch: 1,
        }
    }
    #[test]
    fn exact_closed_source_survives_preview_approval_and_context_fenced_consumption() {
        let (_root, path) = fixture();
        let bytes = fs::read(&path).unwrap();
        let plan = Plan::read(NativeSource::from_native_choice(path.clone()), 100).unwrap();
        assert_eq!(plan.preview().hosts.len(), 1);
        assert_eq!(plan.preview().hosts[0].host, "example.test");
        let bound = binding();
        let mut approved = plan
            .approve(&["example.test".into()], bound.clone())
            .unwrap();
        let mut stale = bound.clone();
        stale.epoch += 1;
        assert!(matches!(
            approved.next(&stale, 100),
            Err(Failure::StaleContext)
        ));
        let cookie = approved.next(&bound, 100).unwrap().unwrap();
        assert_eq!(cookie.value(), "synthetic-private-value");
        assert!(cookie.http_only());
        assert!(matches!(cookie.same_site(), SameSite::Lax));
        assert!(approved.next(&bound, 100).unwrap().is_none());
        assert_eq!(fs::read(&path).unwrap(), bytes);
        for suffix in ["-wal", "-shm", "-journal"] {
            assert!(!PathBuf::from(format!("{}{suffix}", path.display())).exists())
        }
    }
    #[test]
    fn changed_source_or_unknown_host_never_yields_approved_cookies() {
        let (_root, path) = fixture();
        let plan = Plan::read(NativeSource::from_native_choice(path.clone()), 100).unwrap();
        assert!(matches!(
            plan.approve(&["other.test".into()], binding()),
            Err(Failure::InvalidSelection)
        ));
        let plan = Plan::read(NativeSource::from_native_choice(path.clone()), 100).unwrap();
        let db = Connection::open(&path).unwrap();
        db.execute("UPDATE moz_cookies SET value='changed synthetic'", [])
            .unwrap();
        drop(db);
        assert!(matches!(
            plan.approve(&["example.test".into()], binding()),
            Err(Failure::SourceChanged)
        ));
    }
    #[test]
    fn sidecars_and_nonregular_source_are_refused_without_sqlite_source_open() {
        let (root, path) = fixture();
        let bytes = fs::read(&path).unwrap();
        for suffix in ["-wal", "-shm", "-journal"] {
            let side = PathBuf::from(format!("{}{suffix}", path.display()));
            fs::write(&side, b"synthetic").unwrap();
            assert!(matches!(
                Plan::read(NativeSource::from_native_choice(path.clone()), 100),
                Err(Failure::LiveSource)
            ));
            fs::remove_file(side).unwrap();
        }
        assert!(matches!(
            Plan::read(
                NativeSource::from_native_choice(root.path().to_path_buf()),
                100
            ),
            Err(Failure::SourceUnavailable)
        ));
        assert_eq!(fs::read(path).unwrap(), bytes);
    }
    #[cfg(unix)]
    #[test]
    fn symlink_source_is_refused_and_private_copy_permissions_are_restricted() {
        use std::os::unix::{
            fs::MetadataExt,
            fs::{PermissionsExt, symlink},
        };
        let (root, path) = fixture();
        let link = root.path().join("link");
        symlink(&path, &link).unwrap();
        assert!(matches!(
            Plan::read(NativeSource::from_native_choice(link), 100),
            Err(Failure::SourceUnavailable)
        ));
        let bytes = fs::read(path).unwrap();
        let copy = PrivateCopy::create(&bytes).unwrap();
        assert_eq!(
            fs::metadata(&copy.directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(fs::metadata(&copy.database).unwrap().mode() & 0o777, 0o600);
        let directory = copy.directory.clone();
        let mut copy = copy;
        assert!(copy.retry());
        assert!(!directory.exists());
    }
    #[test]
    fn partitioned_expired_unsafe_and_future_policy_rows_are_not_shared() {
        let (_root, path) = fixture();
        let db = Connection::open(&path).unwrap();
        for (name, value, expiry, secure, same, attrs) in [
            ("partition", "x", 2000000000, 1, 1, "^userContextId=1"),
            ("expired", "x", 1, 1, 1, ""),
            ("future", "x", 2000000000, 1, 9, ""),
            ("insecureNone", "x", 2000000000, 0, 0, ""),
            ("bad;name", "x", 2000000000, 1, 1, ""),
            ("control", "x\n", 2000000000, 1, 1, ""),
        ] {
            db.execute(
                "INSERT INTO moz_cookies VALUES('example.test',?1,?2,'/',?3,?4,0,?5,?6)",
                rusqlite::params![name, value, expiry, secure, same, attrs],
            )
            .unwrap();
        }
        drop(db);
        let plan = Plan::read(NativeSource::from_native_choice(path), 100).unwrap();
        assert_eq!(plan.preview().hosts[0].cookies, 1);
        assert_eq!(plan.preview().expired, 1);
        assert_eq!(plan.preview().unsupported, 5);
    }
    #[test]
    fn limits_and_malformed_schema_fail_with_static_secret_free_errors() {
        let (_root, path) = fixture();
        let db = Connection::open(&path).unwrap();
        db.execute_batch("WITH RECURSIVE count(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM count WHERE x<1001) INSERT INTO moz_cookies SELECT 'example.test',x,'private','/',2000000000,1,0,1,'' FROM count;").unwrap();
        drop(db);
        assert!(matches!(
            Plan::read(NativeSource::from_native_choice(path.clone()), 100),
            Err(Failure::LimitExceeded)
        ));
        fs::write(&path, b"synthetic secret malformed database").unwrap();
        let failure = Plan::read(NativeSource::from_native_choice(path.clone()), 100)
            .err()
            .unwrap();
        let message = format!("{failure:?}: {failure}");
        assert!(!message.contains("synthetic secret"));
        assert!(!message.contains(path.to_str().unwrap()));
    }
    #[test]
    fn approved_cookie_expired_since_review_is_not_dispatched() {
        let (_root, path) = fixture();
        let plan = Plan::read(NativeSource::from_native_choice(path), 100).unwrap();
        let bound = binding();
        let mut approved = plan
            .approve(&["example.test".into()], bound.clone())
            .unwrap();
        assert!(approved.next(&bound, 2000000001).unwrap().is_none());
    }
    #[test]
    fn explicit_partition_columns_do_not_widen_scopes_and_duplicate_keys_refuse() {
        let (_root, path) = fixture();
        let db = Connection::open(&path).unwrap();
        db.execute_batch("ALTER TABLE moz_cookies ADD COLUMN isPartitionedAttributeSet INTEGER NOT NULL DEFAULT 0; ALTER TABLE moz_cookies ADD COLUMN partitionKey TEXT NOT NULL DEFAULT ''; INSERT INTO moz_cookies VALUES('example.test','partitioned','private','/',2000000000,1,0,1,'',1,'');").unwrap();
        drop(db);
        let plan = Plan::read(NativeSource::from_native_choice(path.clone()), 100).unwrap();
        assert_eq!(plan.preview().hosts[0].cookies, 1);
        assert_eq!(plan.preview().unsupported, 1);
        let db = Connection::open(&path).unwrap();
        db.execute(
            "INSERT INTO moz_cookies SELECT * FROM moz_cookies WHERE name='session'",
            [],
        )
        .unwrap();
        drop(db);
        assert!(matches!(
            Plan::read(NativeSource::from_native_choice(path), 100),
            Err(Failure::InvalidSnapshot)
        ));
    }
    #[test]
    fn source_size_and_total_private_value_bounds_fail_closed() {
        let (_root, path) = fixture();
        let file = OpenOptions::new().write(true).open(&path).unwrap();
        file.set_len(MAX_SOURCE + 1).unwrap();
        drop(file);
        assert!(matches!(
            Plan::read(NativeSource::from_native_choice(path.clone()), 100),
            Err(Failure::LimitExceeded)
        ));
        fs::remove_file(&path).unwrap();
        let db = Connection::open(&path).unwrap();
        db.execute_batch("CREATE TABLE moz_cookies(host TEXT,name TEXT,value TEXT,path TEXT,expiry INTEGER,isSecure INTEGER,isHttpOnly INTEGER,sameSite INTEGER,originAttributes TEXT); WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<300) INSERT INTO moz_cookies SELECT 'example.test',x,replace(hex(zeroblob(2000)),'0','x'),'/',2000000000,1,0,1,'' FROM n;").unwrap();
        drop(db);
        assert!(matches!(
            Plan::read(NativeSource::from_native_choice(path), 100),
            Err(Failure::LimitExceeded)
        ));
    }
    #[test]
    fn view_or_virtual_cookie_table_is_not_accepted() {
        let (_root, path) = fixture();
        let db = Connection::open(&path).unwrap();
        db.execute_batch("ALTER TABLE moz_cookies RENAME TO other; CREATE VIEW moz_cookies AS SELECT * FROM other;").unwrap();
        drop(db);
        assert!(matches!(
            Plan::read(NativeSource::from_native_choice(path), 100),
            Err(Failure::InvalidSnapshot)
        ));
    }
    #[test]
    fn successful_decode_cannot_escape_before_explicit_cleanup_and_custody_retry() {
        let (_root, path) = fixture();
        let original = fs::read(&path).unwrap();
        let error =
            Plan::read_with_cleanup(NativeSource::from_native_choice(path.clone()), 100, |_| {
                Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied))
            })
            .err()
            .unwrap();
        let message = format!("{error:?}: {error}");
        let Failure::CleanupPending(mut custody) = error else {
            panic!("cleanup custody missing")
        };
        assert!(
            custody.connection.is_none(),
            "SQLite must be explicitly closed before deletion"
        );
        assert!(custody.database.is_file());
        assert!(custody.original_error().is_none());
        assert!(!message.contains(custody.directory.to_str().unwrap()));
        assert!(!message.contains("synthetic-private-value"));
        let id = custody.id();
        assert_eq!(custody.id(), id);
        assert!(custody.retry());
        assert!(!custody.directory.exists());
        assert_eq!(fs::read(path).unwrap(), original);
    }
    #[test]
    fn decode_failure_retains_original_error_and_exact_cleanup_owner() {
        let (_root, path) = fixture();
        fs::write(&path, b"synthetic private invalid SQLite").unwrap();
        let error =
            Plan::read_with_cleanup(NativeSource::from_native_choice(path), 100, |_| Ok(()))
                .err()
                .unwrap();
        let Failure::CleanupPending(mut custody) = error else {
            panic!("no-op deletion must not count as cleanup")
        };
        assert!(matches!(
            custody.original_error(),
            Some(Failure::InvalidSnapshot)
        ));
        assert!(custody.connection.is_none());
        assert!(custody.database.exists());
        assert!(custody.retry());
        assert!(
            custody.retry(),
            "cleanup retry is idempotent once absence is verified"
        );
    }
    #[test]
    fn cleanup_refuses_replaced_directory_without_deleting_unowned_files() {
        let (_root, path) = fixture();
        let mut copy = PrivateCopy::create(&fs::read(path).unwrap()).unwrap();
        let owned = copy.directory.with_extension("retained");
        fs::rename(&copy.directory, &owned).unwrap();
        fs::create_dir(&copy.directory).unwrap();
        let unowned = copy.directory.join("must-not-delete");
        fs::write(&unowned, b"synthetic unchanged").unwrap();
        assert!(!copy.retry());
        assert_eq!(fs::read(&unowned).unwrap(), b"synthetic unchanged");
        fs::remove_file(unowned).unwrap();
        fs::remove_dir(&copy.directory).unwrap();
        fs::rename(owned, &copy.directory).unwrap();
        assert!(copy.retry());
    }
    #[test]
    fn private_copy_uses_physical_owned_path_for_sqlite_nofollow() {
        let (_root, path) = fixture();
        let mut copy = PrivateCopy::create(&fs::read(path).unwrap()).unwrap();
        assert_eq!(copy.database.canonicalize().unwrap(), copy.database);
        let connection = Connection::open_with_flags(
            &copy.database,
            OpenFlags::SQLITE_OPEN_READ_ONLY
                | OpenFlags::SQLITE_OPEN_NO_MUTEX
                | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )
        .unwrap();
        let count: i64 = connection
            .query_row("SELECT count(*) FROM moz_cookies", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1);
        copy.connection = Some(connection);
        let directory = copy.directory.clone();
        assert!(copy.retry());
        assert!(!directory.exists());
    }
}
