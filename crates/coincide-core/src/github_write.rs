//! Private, durable GitHub write boundary. Register only through a parent adapter
//! which resolves authoritative stored thread roots and runs prepare off UI locks.
//! Official semantics: docs.github.com/en/rest/pulls/{pulls,reviews}.
//! No CLI merge/review convenience command: fixed REST routes, explicit host,
//! JSON stdin, no auto-merge/admin/queue or retries. COMMENT targets a commit;
//! APPROVE/REQUEST_CHANGES remain disabled (no atomic current-head condition).
use anyhow::{Context, Result, bail, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs::{self, File},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const NOTICE: &str = "Reviews target the specified commit; GitHub does not atomically require it to remain the current PR head.";
const FIELDS: &str = "number,title,url,state,isDraft,headRefOid,headRefName,baseRefName,mergeable,mergeStateStatus,reviewDecision,reviews,statusCheckRollup,mergeCommit";
const MAX_OUTPUT: usize = 3 * 1024 * 1024;
fn digest(value: &impl Serialize) -> Result<String> {
    Ok(format!("{:x}", Sha256::digest(serde_json::to_vec(value)?)))
}
fn uuid(value: &str) -> Result<()> {
    ensure!(
        uuid::Uuid::parse_str(value)?.to_string() == value,
        "Expected canonical lowercase UUID"
    );
    Ok(())
}
fn head(value: &str) -> Result<()> {
    ensure!(
        value.len() == 40 && value.bytes().all(|b| b.is_ascii_hexdigit()),
        "Expected full 40-character head SHA"
    );
    Ok(())
}
fn repository(value: &str) -> Result<()> {
    let p: Vec<_> = value.split('/').collect();
    ensure!(
        p.len() == 2
            && p.iter().all(|s| !s.is_empty()
                && s.len() <= 100
                && s.as_bytes()[0].is_ascii_alphanumeric()
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))),
        "Explicit owner/repository required"
    );
    Ok(())
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct Scope {
    thread_id: String,
    expected_root: PathBuf,
    repository: String,
    number: u64,
    expected_head: String,
    device: u64,
    inode: u64,
}
impl Scope {
    fn bind(thread: &str, stored: &Path, p: &Value, require_head: bool) -> Result<Self> {
        uuid::Uuid::parse_str(thread)?;
        ensure!(
            p["threadId"].as_str() == Some(thread),
            "Thread scope mismatch"
        );
        let expected = Path::new(
            p["expectedRoot"]
                .as_str()
                .context("expectedRoot required")?,
        );
        ensure!(
            stored.is_absolute() && expected.is_absolute(),
            "Absolute stored root required"
        );
        let root = stored.canonicalize()?;
        ensure!(
            root.is_dir() && expected.canonicalize()? == root,
            "Project root changed"
        );
        let repo = p["repository"].as_str().context("repository required")?;
        repository(repo)?;
        let number = p["number"]
            .as_u64()
            .filter(|n| *n > 0)
            .context("Positive PR number required")?;
        let expected_head = if require_head {
            let h = p["expectedHead"]
                .as_str()
                .context("expectedHead required")?;
            head(h)?;
            h.to_ascii_lowercase()
        } else {
            String::new()
        };
        #[cfg(unix)]
        let (device, inode) = {
            use std::os::unix::fs::MetadataExt;
            let m = fs::metadata(&root)?;
            (m.dev(), m.ino())
        };
        #[cfg(not(unix))]
        let (device, inode) = (0, 0);
        Ok(Self {
            thread_id: thread.into(),
            expected_root: root,
            repository: repo.into(),
            number,
            expected_head,
            device,
            inode,
        })
    }
    fn key(&self) -> String {
        format!("{}/{}", self.repository.to_ascii_lowercase(), self.number)
    }
    fn same_pr(&self, other: &Self) -> bool {
        self.thread_id == other.thread_id
            && self.expected_root == other.expected_root
            && self.repository.eq_ignore_ascii_case(&other.repository)
            && self.number == other.number
            && self.device == other.device
            && self.inode == other.inode
    }
    fn wire(&self) -> Value {
        json!({"threadId":self.thread_id,"expectedRoot":self.expected_root,"repository":self.repository,"number":self.number,"expectedHead":self.expected_head})
    }
    fn recheck(&self) -> Result<()> {
        let current = Self::bind(&self.thread_id, &self.expected_root, &self.wire(), true)?;
        ensure!(*self == current, "Project root changed");
        Ok(())
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
enum Action {
    Review { event: String, body: String },
    Merge { method: String },
}
impl Action {
    fn validate(&self) -> Result<()> {
        match self {
            Self::Review { event, body } => {
                ensure!(
                    event == "COMMENT",
                    "Only commit-targeted COMMENT reviews are supported"
                );
                ensure!(
                    !body.trim().is_empty() && body.len() <= 32768 && !body.contains('\0'),
                    "Review body must contain 1–32768 bytes without NUL"
                );
            }
            Self::Merge { method } => ensure!(
                ["merge", "squash", "rebase"].contains(&method.as_str()),
                "Invalid merge method"
            ),
        }
        Ok(())
    }
}
struct Baseline {
    scope: Scope,
    snapshot: Value,
    fingerprint: String,
    issued: Instant,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    mutation_id: String,
    expected_head: String,
    started_at: u64,
    status: String,
    result: Value,
    error: Value,
}
impl Record {
    fn pending(id: &str, head: &str) -> Self {
        Self {
            mutation_id: id.into(),
            expected_head: head.into(),
            started_at: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
            status: "pending".into(),
            result: Value::Null,
            error: Value::Null,
        }
    }
    fn finish(&mut self, status: &str, result: Value, code: &str, message: &str) {
        self.status = status.into();
        self.result = result;
        self.error = if code.is_empty() {
            Value::Null
        } else {
            json!({"code":code,"message":message})
        };
    }
    fn wire(&self) -> Value {
        json!({"mutationId":self.mutation_id,"status":self.status,"result":self.result,"error":self.error})
    }
}
/// Thread ownership is independent of semantic results and the concurrency Slot.
#[derive(Debug, Clone, Copy, Default)]
pub struct WriteShutdownStatus {
    pub closed: bool,
    pub active_calls: usize,
    pub running: usize,
    pub returned: u64,
    pub panicked: u64,
    pub unclassified: u64,
}
impl WriteShutdownStatus {
    pub fn ready(&self) -> bool {
        self.closed
            && self.active_calls == 0
            && self.running == 0
            && self.panicked == 0
            && self.unclassified == 0
    }
}
#[derive(Default)]
struct WriteWorkerState {
    totals: WriteShutdownStatus,
    workers: Vec<crate::agent::WorkerCompletion>,
}
#[derive(Clone, Default)]
pub struct WriteWorkers(Arc<Mutex<WriteWorkerState>>);
pub struct WriteCallGuard(WriteWorkers);
impl Drop for WriteCallGuard {
    fn drop(&mut self) {
        let mut state = self.0.0.lock().unwrap_or_else(|e| e.into_inner());
        state.totals.active_calls -= 1;
    }
}
impl WriteWorkers {
    /// Admission and active-call reservation are atomic with closing the gate.
    pub fn begin(&self) -> Result<WriteCallGuard> {
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        ensure!(!state.totals.closed, "GitHub writes are shutting down");
        state.totals.active_calls += 1;
        Ok(WriteCallGuard(self.clone()))
    }
    /// Callers retain their admission guard through this registration.
    pub fn track(&self, worker: std::thread::JoinHandle<()>) {
        let completion = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            crate::agent::WorkerCompletion::observe(worker)
        }));
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        match completion {
            Ok(completion) => state.workers.push(completion),
            // The shared observer could not start. Never infer exit from a
            // dropped JoinHandle, semantic result, or the Slot counter.
            Err(_) => state.totals.unclassified += 1,
        }
    }
    pub fn request_shutdown(&self) {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .totals
            .closed = true;
    }
    pub fn status(&self) -> WriteShutdownStatus {
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let workers = std::mem::take(&mut state.workers);
        for completion in workers {
            use crate::agent::WorkerThreadStatus;
            match completion.status() {
                WorkerThreadStatus::Running => state.workers.push(completion),
                WorkerThreadStatus::Returned => state.totals.returned += 1,
                WorkerThreadStatus::Panicked => state.totals.panicked += 1,
                WorkerThreadStatus::Unclassified => state.totals.unclassified += 1,
            }
        }
        WriteShutdownStatus {
            running: state.workers.len(),
            ..state.totals
        }
    }
}
struct Inner {
    gh: Gh,
    db: Mutex<Connection>,
    baselines: Mutex<HashMap<String, Baseline>>,
    slots: Arc<AtomicUsize>,
    _lease: LedgerLease,
    workers: WriteWorkers,
}
#[derive(Clone)]
pub struct GithubWriteService(Arc<Inner>);
struct Slot(Arc<AtomicUsize>);
// Explicitly unlock before closing. A concurrently forked subprocess can
// temporarily inherit this open-file description until its CLOEXEC takes effect;
// close alone would leave the lease held until that child closes its copy.
struct LedgerLease {
    _file: File,
}
impl Drop for LedgerLease {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            while unsafe { libc::flock(self._file.as_raw_fd(), libc::LOCK_UN) } != 0 {
                if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                    break;
                }
            }
        }
    }
}
impl Drop for Slot {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}
impl GithubWriteService {
    /// Paths come only from trusted parent configuration, never request JSON.
    /// Holds an exclusive ledger lease; do not construct a second instance per UI.
    /// Explicit FIRST-TIME initialization only. Never call as fallback when open fails.
    pub fn create(gh: PathBuf, ledger_directory: PathBuf) -> Result<Self> {
        Self::construct(gh, ledger_directory, true)
    }
    /// Normal startup: missing/replaced ledger is an error, never an empty history.
    pub fn open(gh: PathBuf, ledger_directory: PathBuf) -> Result<Self> {
        Self::construct(gh, ledger_directory, false)
    }
    fn construct(gh: PathBuf, ledger_directory: PathBuf, initialize: bool) -> Result<Self> {
        ensure!(
            gh.is_absolute() && gh.is_file(),
            "Configured absolute gh executable required"
        );
        ensure!(
            ledger_directory.is_absolute(),
            "Absolute trusted ledger directory required"
        );
        if initialize {
            fs::create_dir_all(&ledger_directory)?;
        }
        ensure!(
            ledger_directory.is_dir(),
            "Ledger missing; do not recreate automatically"
        );
        ensure!(
            !fs::symlink_metadata(&ledger_directory)?
                .file_type()
                .is_symlink(),
            "Ledger directory cannot be symlink"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::{MetadataExt, PermissionsExt};
            ensure!(
                fs::metadata(&ledger_directory)?.uid() == unsafe { libc::geteuid() },
                "Ledger directory owner mismatch"
            );
            fs::set_permissions(&ledger_directory, fs::Permissions::from_mode(0o700))?;
        }
        let lease_path = ledger_directory.join("writer.lock");
        let mut options = fs::OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let lease = LedgerLease {
            _file: options.open(lease_path)?,
        };
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            ensure!(
                unsafe { libc::flock(lease._file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
                "GitHub ledger already in use"
            );
        }
        let path = ledger_directory.join("mutations.sqlite3");
        let identity_path = ledger_directory.join("identity");
        if initialize {
            ensure!(
                !path.exists() && !identity_path.exists(),
                "Ledger already initialized"
            );
        } else {
            ensure!(
                path.is_file() && identity_path.is_file(),
                "Ledger missing; do not retry writes"
            );
        }
        let identity = if initialize {
            let value = uuid::Uuid::new_v4().to_string();
            let mut options = fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            use std::io::Write;
            let mut file = options.open(&identity_path)?;
            file.write_all(value.as_bytes())?;
            file.sync_all()?;
            value
        } else {
            ensure!(
                !fs::symlink_metadata(&identity_path)?
                    .file_type()
                    .is_symlink(),
                "Ledger identity cannot be symlink"
            );
            let value = fs::read_to_string(&identity_path)?;
            uuid(&value)?;
            value
        };
        if path.exists() {
            ensure!(
                !fs::symlink_metadata(&path)?.file_type().is_symlink(),
                "Ledger cannot be symlink"
            );
        } else {
            let mut o = fs::OpenOptions::new();
            o.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                o.mode(0o600);
            }
            o.open(&path)?.sync_all()?;
        }
        let db = Connection::open(path)?;
        db.busy_timeout(Duration::from_secs(1))?;
        db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")?;
        if initialize {
            db.execute_batch("CREATE TABLE meta(identity TEXT NOT NULL); CREATE TABLE mutations(id TEXT PRIMARY KEY,scope TEXT NOT NULL CHECK(length(scope)<16384),fingerprint TEXT NOT NULL,record TEXT NOT NULL CHECK(length(record)<65536),dispatched INTEGER NOT NULL DEFAULT 0); CREATE TABLE pr_locks(pr TEXT PRIMARY KEY,id TEXT NOT NULL);")?;
            db.execute("INSERT INTO meta(identity) VALUES(?1)", [&identity])?;
            #[cfg(unix)]
            File::open(&ledger_directory)?.sync_all()?;
        } else {
            let stored: String = db.query_row("SELECT identity FROM meta", [], |r| r.get(0))?;
            ensure!(
                stored == identity,
                "Ledger identity mismatch; reconcile storage explicitly"
            );
        }
        let count: i64 = db.query_row("SELECT count(*) FROM mutations", [], |r| r.get(0))?;
        ensure!(count <= 4096, "Ledger exceeds record bound");
        // A restarted process never replays unfinished writes. Even pre-dispatch
        // pending records are conservatively uncertain until explicit reconciliation.
        let old: Vec<(String, String, String)> = {
            let mut query = db.prepare("SELECT id,scope,record FROM mutations LIMIT 4097")?;
            query
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                .collect::<rusqlite::Result<_>>()?
        };
        for (id, binding, text) in old {
            let mut record: Record = serde_json::from_str(&text)?;
            let scope: Scope = serde_json::from_str(&binding)?;
            if record.status == "pending" {
                record.finish(
                    "uncertain",
                    Value::Null,
                    "restart_uncertain",
                    "Process stopped before a verified result; reconcile explicitly",
                );
                db.execute(
                    "UPDATE mutations SET record=?1 WHERE id=?2",
                    params![serde_json::to_string(&record)?, id],
                )?;
            }
            if matches!(record.status.as_str(), "pending" | "uncertain") {
                db.execute(
                    "INSERT OR IGNORE INTO pr_locks(pr,id) VALUES(?1,?2)",
                    params![scope.key(), id],
                )?;
                let owner: String =
                    db.query_row("SELECT id FROM pr_locks WHERE pr=?1", [scope.key()], |r| {
                        r.get(0)
                    })?;
                ensure!(
                    owner == id,
                    "Conflicting unresolved records; reconcile explicitly"
                );
            }
        }
        Ok(Self(Arc::new(Inner {
            gh: Gh {
                executable: gh.canonicalize()?,
                timeout: Duration::from_secs(15),
                #[cfg(test)]
                _expire_after_dispatch_marker: false,
            },
            db: Mutex::new(db),
            baselines: Mutex::new(HashMap::new()),
            slots: Arc::new(AtomicUsize::new(0)),
            _lease: lease,
            workers: WriteWorkers::default(),
        })))
    }
    /// Close admission without cancelling or retrying any dispatched mutation.
    pub fn request_shutdown(&self) {
        self.0.workers.request_shutdown();
    }
    pub fn shutdown_status(&self) -> WriteShutdownStatus {
        self.0.workers.status()
    }
    fn slot(&self) -> Result<Slot> {
        let mut n = self.0.slots.load(Ordering::Acquire);
        loop {
            ensure!(n < 2, "At most two GitHub operations may execute");
            match self
                .0
                .slots
                .compare_exchange(n, n + 1, Ordering::AcqRel, Ordering::Acquire)
            {
                Ok(_) => return Ok(Slot(self.0.slots.clone())),
                Err(current) => n = current,
            }
        }
    }
    fn blocked(&self, scope: &Scope) -> Result<bool> {
        let db = self
            .0
            .db
            .lock()
            .map_err(|_| anyhow::anyhow!("Ledger lock failed"))?;
        Ok(db
            .query_row("SELECT 1 FROM pr_locks WHERE pr=?1", [scope.key()], |_| {
                Ok(())
            })
            .optional()?
            .is_some())
    }
    /// Blocking read-only network preparation. Parent MUST call outside Engine/UI locks.
    pub fn prepare(&self, thread: &str, stored_root: &Path, p: &Value) -> Result<Value> {
        let _admission = self.0.workers.begin()?;
        let scope = Scope::bind(thread, stored_root, p, true)?;
        ensure!(
            !self.blocked(&scope)?,
            "PR has unresolved mutation; query history"
        );
        let _slot = self.slot()?;
        let snapshot = self.read(&scope)?.0;
        let fingerprint = digest(&snapshot)?;
        let mut baselines = self
            .0
            .baselines
            .lock()
            .map_err(|_| anyhow::anyhow!("Baseline lock failed"))?;
        baselines.retain(|_, b| b.issued.elapsed() < Duration::from_secs(60));
        ensure!(baselines.len() < 32, "Too many confirmation baselines");
        let id = uuid::Uuid::new_v4().to_string();
        let mut result = scope.wire();
        result["baselineId"] = json!(id);
        result["fingerprint"] = json!(fingerprint);
        result["expiresAt"] = json!(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() + 60);
        result["snapshot"] = snapshot.clone();
        result["availability"] = availability(&snapshot)?;
        baselines.insert(
            id,
            Baseline {
                scope,
                snapshot,
                fingerprint,
                issued: Instant::now(),
            },
        );
        Ok(result)
    }
    /// Durable acceptance is synchronous; preflight and one write execute on a worker.
    /// All duplicate IDs return the immutable existing result; never redispatch.
    pub fn submit(&self, thread: &str, stored_root: &Path, p: &Value) -> Result<Value> {
        let _admission = self.0.workers.begin()?;
        let scope = Scope::bind(thread, stored_root, p, true)?;
        let id = p["mutationId"].as_str().context("mutationId required")?;
        uuid(id)?;
        let baseline_id = p["baselineId"].as_str().context("baselineId required")?;
        uuid(baseline_id)?;
        let action: Action = serde_json::from_value(p["action"].clone())?;
        action.validate()?;
        let fingerprint = digest(&(scope.clone(), baseline_id, &action))?;
        let mut db = self
            .0
            .db
            .lock()
            .map_err(|_| anyhow::anyhow!("Ledger lock failed"))?;
        if let Some((old_fingerprint, text)) = db
            .query_row(
                "SELECT fingerprint,record FROM mutations WHERE id=?1",
                [id],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()?
        {
            ensure!(
                old_fingerprint == fingerprint,
                "Mutation ID reused with different payload"
            );
            return Ok(serde_json::from_str::<Record>(&text)?.wire());
        }
        let baseline = {
            let mut baselines = self
                .0
                .baselines
                .lock()
                .map_err(|_| anyhow::anyhow!("Baseline lock failed"))?;
            let b = baselines
                .remove(baseline_id)
                .context("Baseline unknown or consumed; prepare again")?;
            ensure!(
                b.scope == scope && b.issued.elapsed() < Duration::from_secs(60),
                "Baseline expired or scope changed"
            );
            b
        };
        ensure!(
            permitted(&action, &baseline.snapshot)?,
            "Action unavailable for confirmed snapshot"
        );
        let slot = self.slot()?;
        let tx = db.transaction()?;
        let count: i64 = tx.query_row("SELECT count(*) FROM mutations", [], |r| r.get(0))?;
        ensure!(
            count < 4096,
            "Mutation ledger full; explicit maintenance required"
        );
        tx.execute(
            "INSERT INTO pr_locks(pr,id) VALUES(?1,?2)",
            params![scope.key(), id],
        )
        .context("PR has unresolved mutation")?;
        let record = Record::pending(id, &scope.expected_head);
        tx.execute(
            "INSERT INTO mutations(id,scope,fingerprint,record) VALUES(?1,?2,?3,?4)",
            params![
                id,
                serde_json::to_string(&scope)?,
                fingerprint,
                serde_json::to_string(&record)?
            ],
        )?;
        tx.commit()?;
        drop(db);
        let service = self.clone();
        let worker_id = id.to_owned();
        let worker_scope = scope.clone();
        let spawn = std::thread::Builder::new()
            .name("github-write".into())
            .spawn(move || {
                let _slot = slot;
                service.execute(&worker_id, &worker_scope, &baseline, &action);
            });
        if let Ok(worker) = spawn {
            self.0.workers.track(worker);
        } else {
            self.finish(
                id,
                "rejected",
                Value::Null,
                "not_dispatched",
                "Unable to start write worker",
                true,
            )?;
        }
        self.result(thread, stored_root, p)
    }
    fn finish(
        &self,
        id: &str,
        status: &str,
        value: Value,
        code: &str,
        message: &str,
        unlock: bool,
    ) -> Result<()> {
        let mut db = self
            .0
            .db
            .lock()
            .map_err(|_| anyhow::anyhow!("Ledger lock failed"))?;
        let tx = db.transaction()?;
        let text: String = tx.query_row("SELECT record FROM mutations WHERE id=?1", [id], |r| {
            r.get(0)
        })?;
        let mut r: Record = serde_json::from_str(&text)?;
        if r.status != "pending" {
            return Ok(());
        }
        r.finish(status, value, code, message);
        tx.execute(
            "UPDATE mutations SET record=?1 WHERE id=?2",
            params![serde_json::to_string(&r)?, id],
        )?;
        if unlock {
            tx.execute("DELETE FROM pr_locks WHERE id=?1", [id])?;
        }
        tx.commit()?;
        Ok(())
    }
    fn execute(&self, id: &str, scope: &Scope, baseline: &Baseline, action: &Action) {
        let preflight = (|| {
            scope.recheck()?;
            ensure!(
                baseline.issued.elapsed() < Duration::from_secs(60),
                "Baseline expired"
            );
            let (snapshot, _) = self.read(scope)?;
            ensure!(
                digest(&snapshot)? == baseline.fingerprint,
                "Confirmed snapshot changed"
            );
            ensure!(permitted(action, &snapshot)?, "Action unavailable");
            scope.recheck()?;
            ensure!(
                baseline.issued.elapsed() < Duration::from_secs(60),
                "Baseline expired"
            );
            Ok::<_, anyhow::Error>(())
        })();
        if preflight.is_err() {
            let _ = self.finish(
                id,
                "rejected",
                Value::Null,
                "preflight_changed",
                "Fresh preflight no longer matches confirmation; prepare again",
                true,
            );
            return;
        }
        // Durably arm BEFORE any subprocess capable of transmitting a write. Any
        // error from this point is uncertain, including spawn/nonzero/timeout/parse.
        let armed = (|| {
            let db = self
                .0
                .db
                .lock()
                .map_err(|_| anyhow::anyhow!("Ledger lock failed"))?;
            let text: String =
                db.query_row("SELECT record FROM mutations WHERE id=?1", [id], |row| {
                    row.get(0)
                })?;
            let record: Record = serde_json::from_str(&text)?;
            ensure!(
                record.status == "pending" && baseline.issued.elapsed() < Duration::from_secs(60),
                "Mutation no longer dispatchable"
            );
            db.execute("UPDATE mutations SET dispatched=1 WHERE id=?1", [id])?;
            Ok::<_, anyhow::Error>(())
        })();
        if armed.is_err() {
            return;
        }
        let result = self.write_and_verify(scope, action);
        match result {
            Ok(value) => {
                let _ = self.finish(id, "succeeded", value, "", "", true);
            }
            Err(_) => {
                let _ = self.finish(
                    id,
                    "uncertain",
                    Value::Null,
                    "dispatch_uncertain",
                    "Write may have reached GitHub; query this ID/history and reconcile explicitly",
                    false,
                );
            }
        }
    }
    /// Non-consuming. Unknown ID or changed binding is a hard error, never retry-safe.
    pub fn result(&self, thread: &str, stored_root: &Path, p: &Value) -> Result<Value> {
        let scope = Scope::bind(thread, stored_root, p, true)?;
        let id = p["mutationId"].as_str().context("mutationId required")?;
        uuid(id)?;
        let db = self
            .0
            .db
            .lock()
            .map_err(|_| anyhow::anyhow!("Ledger lock failed"))?;
        let (binding, text): (String, String) = db
            .query_row(
                "SELECT scope,record FROM mutations WHERE id=?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?
            .context("Unknown mutation ID; do not retry automatically")?;
        ensure!(
            serde_json::from_str::<Scope>(&binding)? == scope,
            "Mutation scope mismatch"
        );
        let mut record: Record = serde_json::from_str(&text)?;
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        if record.status == "pending" && now.saturating_sub(record.started_at) >= 60 {
            record.finish(
                "uncertain",
                Value::Null,
                "deadline_uncertain",
                "No verified result before deadline; reconcile explicitly",
            );
            db.execute(
                "UPDATE mutations SET record=?1 WHERE id=?2",
                params![serde_json::to_string(&record)?, id],
            )?;
        }
        Ok(record.wire())
    }
    /// Includes ALL unresolved records and 50 most recent terminal rows for this
    /// thread/root/repository/PR across old heads. Ledger never auto-purges IDs.
    pub fn history(&self, thread: &str, stored_root: &Path, p: &Value) -> Result<Value> {
        let scope = Scope::bind(thread, stored_root, p, false)?;
        let db = self
            .0
            .db
            .lock()
            .map_err(|_| anyhow::anyhow!("Ledger lock failed"))?;
        let mut q =
            db.prepare("SELECT scope,record FROM mutations ORDER BY rowid DESC LIMIT 4097")?;
        let rows = q.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        let mut mutations = Vec::new();
        let mut terminal = 0;
        let mut truncated = false;
        for row in rows {
            let (binding, text) = row?;
            let old: Scope = serde_json::from_str(&binding)?;
            if scope.same_pr(&old) {
                let record: Record = serde_json::from_str(&text)?;
                let unresolved = matches!(record.status.as_str(), "pending" | "uncertain");
                if unresolved || terminal < 50 {
                    let mut value = record.wire();
                    value["expectedHead"] = json!(record.expected_head);
                    mutations.push(value);
                    if !unresolved {
                        terminal += 1;
                    }
                } else {
                    truncated = true;
                }
            }
        }
        let blocked = db
            .query_row("SELECT 1 FROM pr_locks WHERE pr=?1", [scope.key()], |_| {
                Ok(())
            })
            .optional()?
            .is_some();
        let mut value = scope.wire();
        value.as_object_mut().unwrap().remove("expectedHead");
        value["mutations"] = json!(mutations);
        value["blocked"] = json!(blocked);
        value["truncated"] = json!(truncated);
        Ok(value)
    }
    fn read(&self, scope: &Scope) -> Result<(Value, Value)> {
        scope.recheck()?;
        let raw = self.0.gh.run(
            &scope.expected_root,
            &[
                "pr".into(),
                "view".into(),
                scope.number.to_string(),
                "--repo".into(),
                format!("github.com/{}", scope.repository),
                "--json".into(),
                FIELDS.into(),
            ],
            None,
        )?;
        let mut source: Value = serde_json::from_slice(&raw)?;
        for field in ["mergeable", "mergeStateStatus", "reviewDecision"] {
            if source[field].is_null() {
                source[field] = json!("");
            }
        }
        for field in ["reviews", "statusCheckRollup"] {
            if source[field].is_null() {
                source[field] = json!([]);
            }
            ensure!(
                source[field].as_array().is_some_and(|a| a.len() <= 500),
                "Oversize metadata array"
            );
        }
        let parsed = crate::workspace_github::parse_snapshot(&serde_json::to_vec(&source)?)?;
        ensure!(
            parsed.number == scope.number
                && parsed
                    .head_ref_oid
                    .eq_ignore_ascii_case(&scope.expected_head),
            "PR head changed"
        );
        ensure!(
            parsed.url.eq_ignore_ascii_case(&format!(
                "https://github.com/{}/pull/{}",
                scope.repository, scope.number
            )),
            "PR repository mismatch"
        );
        ensure!(
            parsed.title.len() <= 4096
                && parsed.head_ref_name.len() <= 1024
                && parsed.base_ref_name.len() <= 1024,
            "PR text too large"
        );
        for review in &parsed.reviews {
            ensure!(review.body.len() <= 128 * 1024, "Review body too large");
        }
        scope.recheck()?;
        Ok((serde_json::to_value(parsed)?, source["mergeCommit"].clone()))
    }
    fn write_and_verify(&self, scope: &Scope, action: &Action) -> Result<Value> {
        let endpoint = format!("repos/{}/pulls/{}", scope.repository, scope.number);
        match action {
            Action::Review { event, body } => {
                let bytes = self.0.gh.run(
                    &scope.expected_root,
                    &api("POST", &format!("{endpoint}/reviews"), true),
                    Some(&json!({"commit_id":scope.expected_head,"event":event,"body":body})),
                )?;
                let response: Value = serde_json::from_slice(&bytes)?;
                let id = response["id"]
                    .as_u64()
                    .filter(|id| *id > 0)
                    .context("Missing review id")?;
                let bytes = self.0.gh.run(
                    &scope.expected_root,
                    &api("GET", &format!("{endpoint}/reviews/{id}"), false),
                    None,
                )?;
                let verified: Value = serde_json::from_slice(&bytes)?;
                let url = format!(
                    "https://github.com/{}/pull/{}#pullrequestreview-{id}",
                    scope.repository, scope.number
                );
                ensure!(
                    verified["id"].as_u64() == Some(id)
                        && verified["commit_id"].as_str() == Some(scope.expected_head.as_str())
                        && verified["state"] == "COMMENTED"
                        && verified["body"].as_str() == Some(body.as_str())
                        && verified["html_url"]
                            .as_str()
                            .is_some_and(|s| s.eq_ignore_ascii_case(&url)),
                    "Review verification mismatch"
                );
                Ok(
                    json!({"kind":"review","reviewId":id,"url":url,"commit":scope.expected_head,"state":"COMMENTED"}),
                )
            }
            Action::Merge { method } => {
                let bytes = self.0.gh.run(
                    &scope.expected_root,
                    &api("PUT", &format!("{endpoint}/merge"), true),
                    Some(&json!({"sha":scope.expected_head,"merge_method":method})),
                )?;
                let response: Value = serde_json::from_slice(&bytes)?;
                let commit = response["sha"].as_str().context("Missing merge commit")?;
                head(commit)?;
                ensure!(response["merged"] == true, "Merge not confirmed");
                let (snapshot, merge) = self.read(scope)?;
                ensure!(
                    snapshot["state"] == "MERGED" && merge["oid"].as_str() == Some(commit),
                    "Merged state not verified"
                );
                Ok(json!({"kind":"merge","merged":true,"commit":commit}))
            }
        }
    }
}
fn api(method: &str, endpoint: &str, input: bool) -> Vec<String> {
    let mut args = vec![
        "api".into(),
        "--hostname".into(),
        "github.com".into(),
        "--method".into(),
        method.into(),
        "--header".into(),
        "Accept: application/vnd.github+json".into(),
        "--header".into(),
        "X-GitHub-Api-Version: 2026-03-10".into(),
        endpoint.into(),
    ];
    if input {
        args.extend(["--input".into(), "-".into()]);
    }
    args
}
fn availability(snapshot: &Value) -> Result<Value> {
    let bytes = serde_json::to_vec(snapshot)?;
    let pr = crate::workspace_github::parse_snapshot(&bytes)?;
    let merge = cfg!(unix) && pr.preflight(&pr.head_ref_oid)?["eligible"] == true;
    let comment = cfg!(unix) && pr.state == "OPEN";
    Ok(
        json!({"review":{"COMMENT":{"available":comment,"reason":if comment{Value::Null}else{json!("PR not open or backend unavailable")}},"APPROVE":{"available":false,"reason":"Atomic current-head review condition unavailable"},"REQUEST_CHANGES":{"available":false,"reason":"Atomic current-head review condition unavailable"}},"merge":{"available":merge,"reason":if merge{Value::Null}else{json!("Fresh checks/review/mergeability preflight is not eligible")},"methods":["merge","squash","rebase"]},"notice":NOTICE}),
    )
}
fn permitted(action: &Action, snapshot: &Value) -> Result<bool> {
    let value = availability(snapshot)?;
    Ok(match action {
        Action::Review { .. } => value["review"]["COMMENT"]["available"] == true,
        Action::Merge { .. } => value["merge"]["available"] == true,
    })
}

struct Gh {
    executable: PathBuf,
    timeout: Duration,
    #[cfg(test)]
    _expire_after_dispatch_marker: bool,
}
impl Gh {
    #[cfg(not(unix))]
    fn run(&self, _: &Path, _: &[String], _: Option<&Value>) -> Result<Vec<u8>> {
        bail!("Write backend unavailable on this platform")
    }
    #[cfg(unix)]
    fn run(&self, root: &Path, args: &[String], input: Option<&Value>) -> Result<Vec<u8>> {
        use std::{
            io::{Read, Write},
            os::{fd::AsRawFd, unix::process::CommandExt},
            process::{Command, Stdio},
        };
        let body = input
            .map(serde_json::to_vec)
            .transpose()?
            .unwrap_or_default();
        ensure!(body.len() <= 256 * 1024, "Request body too large");
        let child = Command::new(&self.executable)
            .args(args)
            .current_dir(root)
            .process_group(0)
            .env("GH_HOST", "github.com")
            .env("GH_PROMPT_DISABLED", "1")
            .env("GH_PAGER", "cat")
            .env("PAGER", "cat")
            .env("NO_COLOR", "1")
            .env("GH_NO_UPDATE_NOTIFIER", "1")
            .env_remove("GH_DEBUG")
            .env_remove("GH_REPO")
            .env_remove("GH_FORCE_TTY")
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .context("Unable to start gh")?;
        let mut group = Group(child);
        let mut output = group.0.stdout.take().context("No gh stdout")?;
        let mut stdin = group.0.stdin.take();
        fn nonblocking(fd: i32) -> Result<()> {
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            ensure!(
                flags >= 0
                    && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } >= 0,
                "Nonblocking transport unavailable"
            );
            Ok(())
        }
        nonblocking(output.as_raw_fd())?;
        if let Some(pipe) = &stdin {
            nonblocking(pipe.as_raw_fd())?;
        }
        let mut offset = 0;
        let mut bytes = Vec::new();
        let mut eof = false;
        let started = Instant::now();
        loop {
            let expired = started.elapsed() >= self.timeout;
            // Exercise the real deadline cleanup only after the synthetic child
            // confirms dispatch. Read/preflight startup keeps its normal budget.
            #[cfg(test)]
            let expired = expired
                || (self._expire_after_dispatch_marker
                    && input.is_some()
                    && bytes.starts_with(b"fixture-dispatch-complete\n"));
            ensure!(!expired, "gh operation timed out");
            if offset == body.len() {
                stdin.take();
            } else if let Some(pipe) = &mut stdin {
                match pipe.write(&body[offset..]) {
                    Ok(0) => bail!("gh stdin closed"),
                    Ok(n) => offset += n,
                    Err(e)
                        if matches!(
                            e.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                        ) => {}
                    Err(_) => bail!("gh stdin failed"),
                }
            }
            let mut chunk = [0u8; 16384];
            match output.read(&mut chunk) {
                Ok(0) => eof = true,
                Ok(n) => {
                    ensure!(bytes.len() + n <= MAX_OUTPUT, "gh output limit exceeded");
                    bytes.extend_from_slice(&chunk[..n]);
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                    ) => {}
                Err(_) => bail!("gh stdout failed"),
            }
            if let Some(success) = group.exited()? {
                ensure!(success, "gh request failed");
                if eof {
                    return Ok(bytes);
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
#[cfg(unix)]
struct Group(std::process::Child);
#[cfg(unix)]
impl Group {
    fn exited(&self) -> Result<Option<bool>> {
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let rc = unsafe {
            libc::waitid(
                libc::P_PID,
                self.0.id(),
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if rc != 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                return Ok(None);
            }
            bail!("gh process observation failed");
        }
        if unsafe { info.si_pid() } == 0 {
            return Ok(None);
        }
        Ok(Some(
            info.si_code == libc::CLD_EXITED && unsafe { info.si_status() } == 0,
        ))
    }
}
#[cfg(unix)]
impl Drop for Group {
    fn drop(&mut self) {
        unsafe {
            libc::kill(-(self.0.id() as i32), libc::SIGKILL);
        }
        let _ = self.0.wait();
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    fn snapshot() -> Value {
        json!({"number":7,"title":"Synthetic PR","url":"https://github.com/owner/project/pull/7","state":"OPEN","isDraft":false,"headRefOid":"a".repeat(40),"headRefName":"feature","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","reviews":[],"statusCheckRollup":[{"__typename":"CheckRun","name":"fixture","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeCommit":null})
    }
    const FAKE: &str = r#"#!/usr/bin/env python3
import json,sys,os,time,signal
args=sys.argv[1:]
body=json.load(sys.stdin) if '--input' in args else None
with open('calls.jsonl','a') as f: f.write(json.dumps({'args':args,'body':body})+'\n')
assert '--admin' not in args and '--auto' not in args and 'merge-async' not in ' '.join(args)
if args[0]=='pr':
 assert args[:2]==['pr','view'] and args[2]=='7' and args[args.index('--repo')+1]=='github.com/owner/project'
 print(open('snapshot.json').read(),flush=True)
else:
 assert args[0]=='api' and args[args.index('--hostname')+1]=='github.com'
 method=args[args.index('--method')+1]
 endpoint=next(v for v in args if v.startswith('repos/'))
 if method=='POST':
  assert endpoint=='repos/owner/project/pulls/7/reviews'
  assert set(body)=={'commit_id','event','body'} and body['event']=='COMMENT' and body['commit_id']=='a'*40
  value={'id':19,'state':'COMMENTED','body':body['body'],'commit_id':body['commit_id'],'html_url':'https://github.com/owner/project/pull/7#pullrequestreview-19'}
  json.dump(value,open('review.json','w'))
  if os.path.exists('timeout-response'):
   with open('timeout-pid','w') as f:f.write(str(os.getpid()))
   print('fixture-dispatch-complete',flush=True)
   signal.pause()
   raise AssertionError('Timeout child must be killed and reaped')
  if os.path.exists('lost-response'):sys.exit(3)
  if os.path.exists('slow-response'):time.sleep(3)
  print(json.dumps(value),flush=True)
 elif method=='GET':
  assert endpoint=='repos/owner/project/pulls/7/reviews/19'
  print(open('review.json').read(),flush=True)
 elif method=='PUT':
  assert endpoint=='repos/owner/project/pulls/7/merge'
  assert set(body)=={'sha','merge_method'} and body['sha']=='a'*40 and body['merge_method'] in ['merge','squash','rebase']
  value=json.load(open('snapshot.json'));assert value['headRefOid']==body['sha']
  value['state']='MERGED';value['mergeCommit']={'oid':'b'*40};json.dump(value,open('snapshot.json','w'))
  print(json.dumps({'merged':True,'sha':'b'*40}),flush=True)
 else:raise AssertionError('Unexpected method')
"#;
    #[test]
    fn shutdown_preserves_dispatched_write_and_never_retries_it() {
        let (dir, service, scope) = fixture();
        let request = request(&service, &scope, comment());
        submit(&service, &request).unwrap();
        service.request_shutdown();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !service.shutdown_status().ready() {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(result(&service, &request).unwrap()["status"], "succeeded");
        assert_eq!(writes(dir.path()), 1);
        assert!(
            submit(&service, &request).is_err(),
            "closed admission never redispatches even duplicate IDs"
        );
        assert_eq!(writes(dir.path()), 1);
    }
    #[test]
    fn closed_service_rejects_new_work_without_touching_ledger() {
        let (dir, service, _) = fixture();
        service.request_shutdown();
        assert!(service.shutdown_status().ready());
        for result in [
            service.prepare("bad", dir.path(), &json!({})),
            service.submit("bad", dir.path(), &json!({})),
        ] {
            assert!(result.unwrap_err().to_string().contains("shutting down"));
        }
        assert!(!dir.path().join("calls.jsonl").exists());
    }
    fn fixture() -> (tempfile::TempDir, GithubWriteService, Value) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let exe = root.join("fake-gh");
        fs::write(&exe, FAKE).unwrap();
        fs::set_permissions(&exe, fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(
            root.join("snapshot.json"),
            serde_json::to_vec(&snapshot()).unwrap(),
        )
        .unwrap();
        let service = GithubWriteService::create(exe, root.join("ledger")).unwrap();
        let scope = json!({"threadId":uuid::Uuid::new_v4().to_string(),"expectedRoot":root,"repository":"owner/project","number":7,"expectedHead":"a".repeat(40)});
        (dir, service, scope)
    }
    fn prepare(service: &GithubWriteService, p: &Value) -> Value {
        service
            .prepare(
                p["threadId"].as_str().unwrap(),
                Path::new(p["expectedRoot"].as_str().unwrap()),
                p,
            )
            .unwrap()
    }
    fn request(service: &GithubWriteService, p: &Value, action: Value) -> Value {
        let b = prepare(service, p);
        let mut r = p.clone();
        r["baselineId"] = b["baselineId"].clone();
        r["mutationId"] = json!(uuid::Uuid::new_v4().to_string());
        r["action"] = action;
        r
    }
    fn submit(service: &GithubWriteService, p: &Value) -> Result<Value> {
        service.submit(
            p["threadId"].as_str().unwrap(),
            Path::new(p["expectedRoot"].as_str().unwrap()),
            p,
        )
    }
    fn result(service: &GithubWriteService, p: &Value) -> Result<Value> {
        service.result(
            p["threadId"].as_str().unwrap(),
            Path::new(p["expectedRoot"].as_str().unwrap()),
            p,
        )
    }
    fn wait(service: &GithubWriteService, p: &Value) -> Value {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let v = result(service, p).unwrap();
            if v["status"] != "pending" {
                return v;
            }
            assert!(Instant::now() < deadline, "fake mutation timed out");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    fn history(service: &GithubWriteService, p: &Value) -> Value {
        service
            .history(
                p["threadId"].as_str().unwrap(),
                Path::new(p["expectedRoot"].as_str().unwrap()),
                p,
            )
            .unwrap()
    }
    fn calls(root: &Path) -> Vec<Value> {
        fs::read_to_string(root.join("calls.jsonl"))
            .unwrap_or_default()
            .lines()
            .map(|v| serde_json::from_str(v).unwrap())
            .collect()
    }
    fn writes(root: &Path) -> usize {
        calls(root)
            .iter()
            .filter(|v| {
                v["args"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|s| s == "POST" || s == "PUT")
            })
            .count()
    }
    fn comment() -> Value {
        json!({"kind":"review","event":"COMMENT","body":"Literal @file $(touch unsafe) `touch unsafe2`\nFixture only"})
    }
    fn idle(service: &GithubWriteService) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while Arc::strong_count(&service.0) > 1 {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    #[test]
    fn dropping_service_releases_lease_even_with_inherited_open_description() {
        let (dir, service, _) = fixture();
        // dup and fork share the same open-file description and flock lifetime.
        // Hold the duplicate across destruction to make the race deterministic.
        let inherited = service.0._lease._file.try_clone().unwrap();
        assert!(
            GithubWriteService::open(dir.path().join("fake-gh"), dir.path().join("ledger"),)
                .is_err()
        );
        drop(service);
        let reopened =
            GithubWriteService::open(dir.path().join("fake-gh"), dir.path().join("ledger"))
                .unwrap();
        assert!(inherited.metadata().is_ok());
        // Closing the old duplicate must not release the new service's lease.
        drop(inherited);
        assert!(
            GithubWriteService::open(dir.path().join("fake-gh"), dir.path().join("ledger"),)
                .is_err()
        );
        drop(reopened);
    }
    #[test]
    fn comment_verified_fixed_rest_payload_is_durable_nonconsuming_and_never_reposted() {
        let (dir, service, p) = fixture();
        let request = request(&service, &p, comment());
        submit(&service, &request).unwrap();
        let verified = wait(&service, &request);
        assert_eq!(verified["status"], "succeeded");
        assert_eq!(verified["result"]["reviewId"], 19);
        assert_eq!(result(&service, &request).unwrap(), verified);
        assert_eq!(submit(&service, &request).unwrap(), verified);
        assert_eq!(writes(dir.path()), 1);
        assert!(!dir.path().join("unsafe").exists());
        assert!(!dir.path().join("unsafe2").exists());
        let mut changed = request.clone();
        changed["action"]["body"] = json!("Changed");
        assert!(submit(&service, &changed).is_err());
        idle(&service);
        drop(service);
        let reopened =
            GithubWriteService::open(dir.path().join("fake-gh"), dir.path().join("ledger"))
                .unwrap();
        assert_eq!(result(&reopened, &request).unwrap(), verified);
        assert_eq!(submit(&reopened, &request).unwrap(), verified);
        assert_eq!(writes(dir.path()), 1);
    }
    #[test]
    fn synchronous_merge_has_server_head_condition_no_queue_and_verified_merge_commit() {
        let (dir, service, p) = fixture();
        let request = request(&service, &p, json!({"kind":"merge","method":"squash"}));
        submit(&service, &request).unwrap();
        let verified = wait(&service, &request);
        assert_eq!(verified["status"], "succeeded");
        assert_eq!(
            verified["result"],
            json!({"kind":"merge","merged":true,"commit":"b".repeat(40)})
        );
        assert_eq!(writes(dir.path()), 1);
        let write = calls(dir.path())
            .into_iter()
            .find(|v| v["body"].get("sha").is_some())
            .unwrap();
        assert_eq!(
            write["body"],
            json!({"sha":"a".repeat(40),"merge_method":"squash"})
        );
    }
    #[test]
    fn changed_checks_on_same_head_or_expired_baseline_never_dispatch() {
        let (dir, service, p) = fixture();
        let request = request(&service, &p, comment());
        let mut changed = snapshot();
        changed["statusCheckRollup"][0]["conclusion"] = json!("FAILURE");
        fs::write(
            dir.path().join("snapshot.json"),
            serde_json::to_vec(&changed).unwrap(),
        )
        .unwrap();
        submit(&service, &request).unwrap();
        assert_eq!(wait(&service, &request)["status"], "rejected");
        assert_eq!(writes(dir.path()), 0);
        fs::write(
            dir.path().join("snapshot.json"),
            serde_json::to_vec(&snapshot()).unwrap(),
        )
        .unwrap();
        let expired = self::request(&service, &p, comment());
        service
            .0
            .baselines
            .lock()
            .unwrap()
            .get_mut(expired["baselineId"].as_str().unwrap())
            .unwrap()
            .issued = Instant::now() - Duration::from_secs(61);
        assert!(submit(&service, &expired).is_err());
        assert_eq!(writes(dir.path()), 0);
    }
    #[test]
    fn uncertain_after_dispatch_locks_prior_head_and_survives_reopen_without_retry() {
        let (dir, service, p) = fixture();
        let request = request(&service, &p, comment());
        fs::write(dir.path().join("lost-response"), []).unwrap();
        submit(&service, &request).unwrap();
        assert_eq!(wait(&service, &request)["status"], "uncertain");
        assert_eq!(writes(dir.path()), 1);
        assert_eq!(submit(&service, &request).unwrap()["status"], "uncertain");
        let mut moved = p.clone();
        moved["expectedHead"] = json!("c".repeat(40));
        assert!(
            service
                .prepare(moved["threadId"].as_str().unwrap(), dir.path(), &moved)
                .is_err()
        );
        let recovered = history(&service, &moved);
        assert_eq!(recovered["blocked"], true);
        assert_eq!(recovered["mutations"][0]["expectedHead"], "a".repeat(40));
        idle(&service);
        drop(service);
        let reopened =
            GithubWriteService::open(dir.path().join("fake-gh"), dir.path().join("ledger"))
                .unwrap();
        assert_eq!(result(&reopened, &request).unwrap()["status"], "uncertain");
        assert_eq!(history(&reopened, &moved)["blocked"], true);
        assert_eq!(writes(dir.path()), 1);
    }
    #[test]
    fn capability_exclusion_unknown_ids_missing_ledger_and_scope_changes_fail_closed() {
        let (dir, service, p) = fixture();
        let baseline = prepare(&service, &p);
        assert_eq!(
            baseline["availability"]["review"]["APPROVE"]["available"],
            false
        );
        assert_eq!(baseline["availability"]["notice"], NOTICE);
        let mut request = p.clone();
        request["baselineId"] = baseline["baselineId"].clone();
        request["mutationId"] = json!(uuid::Uuid::new_v4().to_string());
        request["action"] = json!({"kind":"review","event":"APPROVE","body":""});
        assert!(submit(&service, &request).is_err());
        assert!(result(&service, &request).is_err());
        let wrong = tempfile::tempdir().unwrap();
        assert!(
            service
                .prepare(p["threadId"].as_str().unwrap(), wrong.path(), &p)
                .is_err()
        );
        assert_eq!(writes(dir.path()), 0);
        drop(service);
        fs::remove_file(dir.path().join("ledger/mutations.sqlite3")).unwrap();
        assert!(
            GithubWriteService::open(dir.path().join("fake-gh"), dir.path().join("ledger"))
                .is_err()
        );
        assert!(
            GithubWriteService::create(dir.path().join("fake-gh"), dir.path().join("ledger"))
                .is_err()
        );
    }
    #[test]
    fn per_pr_exclusion_and_restart_of_pending_record_are_conservative() {
        let (dir, service, p) = fixture();
        let first = request(&service, &p, comment());
        let second = request(&service, &p, comment());
        fs::write(dir.path().join("slow-response"), []).unwrap();
        submit(&service, &first).unwrap();
        assert!(submit(&service, &second).is_err());
        assert_eq!(history(&service, &p)["blocked"], true);
        // Confirm the first accepted POST owns the lock while its response waits.
        let deadline = Instant::now() + Duration::from_secs(5);
        while writes(dir.path()) == 0 {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        let verified = wait(&service, &first);
        assert_eq!(verified["status"], "succeeded");
        // Simulate durable pending state left by a terminated process, with no live worker.
        idle(&service);
        {
            let db = service.0.db.lock().unwrap();
            let id = first["mutationId"].as_str().unwrap();
            let text: String = db
                .query_row("SELECT record FROM mutations WHERE id=?1", [id], |r| {
                    r.get(0)
                })
                .unwrap();
            let mut record: Record = serde_json::from_str(&text).unwrap();
            record.status = "pending".into();
            db.execute(
                "UPDATE mutations SET record=?1 WHERE id=?2",
                params![serde_json::to_string(&record).unwrap(), id],
            )
            .unwrap();
        }
        drop(service);
        let reopened =
            GithubWriteService::open(dir.path().join("fake-gh"), dir.path().join("ledger"))
                .unwrap();
        assert_eq!(result(&reopened, &first).unwrap()["status"], "uncertain");
        assert_eq!(history(&reopened, &p)["blocked"], true);
        assert_eq!(writes(dir.path()), 1);
    }
    #[test]
    fn write_timeout_is_terminal_uncertain_and_never_replayed() {
        let (dir, mut service, p) = fixture();
        Arc::get_mut(&mut service.0)
            .unwrap()
            .gh
            ._expire_after_dispatch_marker = true;
        let request = request(&service, &p, comment());
        fs::write(dir.path().join("timeout-response"), []).unwrap();
        submit(&service, &request).unwrap();
        assert_eq!(wait(&service, &request)["status"], "uncertain");
        assert_eq!(writes(dir.path()), 1);
        let dispatched: bool = service
            .0
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT dispatched FROM mutations WHERE id=?1",
                [request["mutationId"].as_str().unwrap()],
                |row| row.get(0),
            )
            .unwrap();
        assert!(dispatched);
        let pid: i32 = fs::read_to_string(dir.path().join("timeout-pid"))
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ESRCH)
        );
        assert_eq!(submit(&service, &request).unwrap()["status"], "uncertain");
        assert_eq!(writes(dir.path()), 1);
        assert_eq!(history(&service, &p)["blocked"], true);
        // A late worker response cannot change a terminal uncertain outcome.
        service
            .finish(
                request["mutationId"].as_str().unwrap(),
                "succeeded",
                json!({"unexpected":true}),
                "",
                "",
                true,
            )
            .unwrap();
        assert_eq!(result(&service, &request).unwrap()["status"], "uncertain");
        assert_eq!(history(&service, &p)["blocked"], true);
    }
}

#[cfg(test)]
mod shutdown_tests {
    use super::*;
    use std::sync::{Condvar, atomic::AtomicBool};
    #[test]
    fn write_shutdown_waits_for_registration_and_tls_join_after_semantic_completion() {
        struct Gate(Arc<(Mutex<bool>, Condvar)>, Arc<AtomicBool>);
        impl Drop for Gate {
            fn drop(&mut self) {
                self.1.store(true, Ordering::SeqCst);
                let lock = self.0.0.lock().unwrap();
                drop(self.0.1.wait_while(lock, |blocked| *blocked).unwrap());
            }
        }
        thread_local! { static EXIT:std::cell::RefCell<Option<Gate>>=const {std::cell::RefCell::new(None)}; }
        let workers = WriteWorkers::default();
        let permit = workers.begin().unwrap();
        workers.request_shutdown();
        assert!(
            !workers.status().ready(),
            "admitted call may still register worker"
        );
        assert!(workers.begin().is_err());
        let gate = Arc::new((Mutex::new(true), Condvar::new()));
        struct Release(Arc<(Mutex<bool>, Condvar)>);
        impl Drop for Release {
            fn drop(&mut self) {
                *self.0.0.lock().unwrap() = false;
                self.0.1.notify_all();
            }
        }
        let _release = Release(gate.clone());
        let entered = Arc::new(AtomicBool::new(false));
        let (tx, rx) = std::sync::mpsc::channel();
        let g = gate.clone();
        let e = entered.clone();
        let worker = std::thread::spawn(move || {
            EXIT.with(|slot| *slot.borrow_mut() = Some(Gate(g, e)));
            let _ = tx.send("semantic result published / Slot dropped");
        });
        workers.track(worker);
        drop(permit);
        rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while !entered.load(Ordering::SeqCst) {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(workers.status().running, 1);
        assert!(!workers.status().ready());
        *gate.0.lock().unwrap() = false;
        gate.1.notify_all();
        while !workers.status().ready() {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(workers.status().returned, 1);
    }
    #[test]
    fn write_shutdown_retains_panicked_outcome_as_not_ready() {
        let workers = WriteWorkers::default();
        let permit = workers.begin().unwrap();
        workers.track(std::thread::spawn(|| {
            panic!("synthetic write worker panic")
        }));
        drop(permit);
        workers.request_shutdown();
        let deadline = Instant::now() + Duration::from_secs(3);
        while workers.status().running != 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(workers.status().panicked, 1);
        assert!(!workers.status().ready());
    }
}
