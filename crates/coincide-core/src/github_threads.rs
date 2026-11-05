//! Fixed, read-only GitHub review-thread queries. Pagination is explicit: one
//! bounded subprocess per page. No viewer/authentication inference or mutations.
use crate::github_api::GhRunner;
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

pub const THREAD_PAGE: usize = 10;
pub const COMMENT_PAGE: usize = 20;
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Scope {
    pub thread_id: String,
    pub expected_root: String,
    pub repository: String,
    pub number: u64,
    pub expected_head: String,
}
impl Scope {
    pub fn validate(&self) -> Result<()> {
        uuid::Uuid::parse_str(&self.thread_id)?;
        ensure!(
            Path::new(&self.expected_root).is_absolute() && self.expected_root.len() <= 4096,
            "Absolute root required"
        );
        let parts: Vec<_> = self.repository.split('/').collect();
        ensure!(
            parts.len() == 2
                && parts.iter().all(|s| !s.is_empty()
                    && s.len() <= 100
                    && !matches!(*s, "." | "..")
                    && !s.starts_with('-')
                    && s.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))),
            "Explicit owner/repository required"
        );
        ensure!(
            self.number > 0 && self.number <= i32::MAX as u64,
            "Invalid PR number"
        );
        head(&self.expected_head)
    }
    pub fn params(&self) -> Value {
        json!({"threadId":self.thread_id,"expectedRoot":self.expected_root,"repository":self.repository,"number":self.number,"expectedHead":self.expected_head})
    }
}
#[derive(Clone)]
struct Bound {
    scope: Scope,
    root: PathBuf,
    identity: (u64, u64),
}
impl Bound {
    fn new(thread: &str, stored: &Path, params: &Value) -> Result<Self> {
        let scope: Scope = serde_json::from_value(params.clone())?;
        scope.validate()?;
        ensure!(scope.thread_id == thread, "Thread scope mismatch");
        ensure!(stored.is_absolute(), "Authoritative stored root required");
        let root = stored.canonicalize()?;
        ensure!(
            root.is_dir() && Path::new(&scope.expected_root).canonicalize()? == root,
            "Project root changed"
        );
        #[cfg(unix)]
        let identity = {
            use std::os::unix::fs::MetadataExt;
            let m = std::fs::metadata(&root)?;
            (m.dev(), m.ino())
        };
        #[cfg(not(unix))]
        let identity = (0, 0);
        ensure!(
            root.to_str() == Some(scope.expected_root.as_str()),
            "Expected canonical stored root"
        );
        Ok(Self {
            scope,
            root,
            identity,
        })
    }
    fn same(&self, other: &Self) -> bool {
        self.scope == other.scope && self.root == other.root && self.identity == other.identity
    }
    fn recheck(&self) -> Result<()> {
        ensure!(
            self.same(&Self::new(
                &self.scope.thread_id,
                &self.root,
                &self.scope.params()
            )?),
            "Project root changed"
        );
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Actor {
    pub login: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ReplyTarget {
    pub node_id: String,
    pub database_id: Option<u64>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Mention {
    pub text: String,
    pub kind: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InlineComment {
    pub id: String,
    pub database_id: Option<u64>,
    pub body: String,
    pub body_truncated: bool,
    pub diff_hunk: String,
    pub diff_hunk_truncated: bool,
    pub author: Option<Actor>,
    pub url: String,
    pub created_at: String,
    pub updated_at: String,
    pub commit: Option<String>,
    pub reply_to: Option<ReplyTarget>,
    pub mentions: Vec<Mention>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewThread {
    pub id: String,
    pub path: String,
    pub line: Option<u64>,
    pub start_line: Option<u64>,
    pub original_line: Option<u64>,
    pub diff_side: String,
    pub is_resolved: bool,
    pub is_outdated: bool,
    pub resolved_by: Option<Actor>,
    pub comments: Vec<InlineComment>,
    pub next_cursor: Option<String>,
    pub has_next_page: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Page {
    pub kind: String,
    #[serde(flatten)]
    pub scope: Scope,
    pub review_thread_id: Option<String>,
    pub cursor: Option<String>,
    pub next_cursor: Option<String>,
    pub has_next_page: bool,
    pub threads: Vec<ReviewThread>,
    pub comments: Vec<InlineComment>,
}
fn head(s: &str) -> Result<()> {
    ensure!(
        s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit()),
        "Full head SHA required"
    );
    Ok(())
}
fn text(value: &Value, key: &str, max: usize) -> Result<String> {
    let s = value[key].as_str().context("Missing GitHub text")?;
    ensure!(s.len() <= max && !s.contains('\0'), "Invalid GitHub text");
    Ok(s.into())
}
fn handle(value: &str, max: usize) -> Result<()> {
    ensure!(
        !value.is_empty() && value.len() <= max && !value.chars().any(char::is_control),
        "Invalid GitHub handle"
    );
    Ok(())
}
fn optional_cursor(value: Option<&Value>) -> Result<Option<String>> {
    if value.is_none_or(Value::is_null) {
        return Ok(None);
    }
    let s = value.and_then(Value::as_str).context("Invalid cursor")?;
    handle(s, 1024)?;
    Ok(Some(s.into()))
}
fn flag(value: &Value, key: &str) -> Result<bool> {
    value[key].as_bool().context("Missing GitHub boolean")
}
fn line(value: &Value, key: &str) -> Result<Option<u64>> {
    if value[key].is_null() {
        return Ok(None);
    }
    Ok(Some(
        value[key]
            .as_u64()
            .filter(|n| *n > 0 && *n <= i32::MAX as u64)
            .context("Invalid diff line")?,
    ))
}
fn actor(value: &Value) -> Result<Option<Actor>> {
    if value.is_null() {
        return Ok(None);
    }
    let login = text(value, "login", 100)?;
    ensure!(!login.is_empty(), "Empty actor login");
    Ok(Some(Actor { login }))
}
fn target(value: &Value) -> Result<ReplyTarget> {
    let node_id = text(value, "id", 256)?;
    handle(&node_id, 256)?;
    let database_id = if value["databaseId"].is_null() {
        None
    } else {
        Some(
            value["databaseId"]
                .as_u64()
                .or_else(|| {
                    value["databaseId"]
                        .as_str()
                        .and_then(|s| s.parse::<u64>().ok())
                })
                .filter(|n| *n > 0)
                .context("Invalid comment database ID")?,
        )
    };
    Ok(ReplyTarget {
        node_id,
        database_id,
    })
}
fn clipped(s: &str, max: usize) -> (String, bool) {
    if s.len() <= max {
        return (s.into(), false);
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    (s[..end].into(), true)
}
/// Text references only, never proof an account/team exists or was notified.
/// Skip code spans/fences and email-like tokens; cap 100 unique references.
pub fn mention_text(body: &str) -> Vec<Mention> {
    let mut found = Vec::new();
    let mut seen = HashSet::new();
    let bytes = body.as_bytes();
    let mut i = 0;
    let mut fence = false;
    let mut inline = false;
    while i < bytes.len() && found.len() < 100 {
        if bytes[i..].starts_with(b"```") {
            fence = !fence;
            i += 3;
            continue;
        }
        if bytes[i] == b'`' && !fence {
            inline = !inline;
            i += 1;
            continue;
        }
        if !fence
            && !inline
            && bytes[i] == b'@'
            && (i == 0
                || (!bytes[i - 1].is_ascii_alphanumeric() && !b"._/%+-@".contains(&bytes[i - 1])))
        {
            let start = i;
            i += 1;
            let user = i;
            while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'-') {
                i += 1;
            }
            let valid = i > user
                && i - user <= 39
                && bytes[user].is_ascii_alphanumeric()
                && bytes[i - 1].is_ascii_alphanumeric();
            let mut kind = "user";
            if valid && i < bytes.len() && bytes[i] == b'/' {
                let slash = i;
                i += 1;
                let team = i;
                while i < bytes.len()
                    && (bytes[i].is_ascii_alphanumeric() || b"-_".contains(&bytes[i]))
                {
                    i += 1;
                }
                if i > team && i - team <= 100 {
                    kind = "team";
                } else {
                    i = slash;
                }
            }
            if valid {
                let token = &body[start..i];
                if seen.insert(token.to_ascii_lowercase()) {
                    found.push(Mention {
                        text: token.into(),
                        kind: kind.into(),
                    });
                }
            }
            continue;
        }
        i += 1;
    }
    found
}
fn page_info(connection: &Value, requested: Option<&str>) -> Result<(Option<String>, bool)> {
    let more = flag(&connection["pageInfo"], "hasNextPage")?;
    let next = optional_cursor(connection["pageInfo"].get("endCursor"))?;
    if more {
        ensure!(
            next.is_some() && next.as_deref() != requested,
            "Pagination did not advance"
        );
    }
    Ok((if more { next } else { None }, more))
}
fn verify_pr(pr: &Value, scope: &Scope) -> Result<()> {
    ensure!(
        pr["number"].as_u64() == Some(scope.number)
            && pr["url"]
                .as_str()
                .is_some_and(|s| s.eq_ignore_ascii_case(&format!(
                    "https://github.com/{}/pull/{}",
                    scope.repository, scope.number
                ))),
        "PR scope mismatch"
    );
    ensure!(
        pr["headRefOid"]
            .as_str()
            .is_some_and(|s| s.eq_ignore_ascii_case(&scope.expected_head)),
        "PR head changed"
    );
    ensure!(
        pr["repository"]["nameWithOwner"]
            .as_str()
            .is_some_and(|s| s.eq_ignore_ascii_case(&scope.repository)),
        "Repository mismatch"
    );
    Ok(())
}
fn comments(connection: &Value, scope: &Scope) -> Result<Vec<InlineComment>> {
    let nodes = connection["nodes"]
        .as_array()
        .context("Missing inline comments")?;
    ensure!(nodes.len() <= COMMENT_PAGE, "Comment page limit exceeded");
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for raw in nodes {
        let t = target(raw)?;
        ensure!(seen.insert(t.node_id.clone()), "Duplicate inline comment");
        let body = text(raw, "body", MAX_BODY_INPUT)?;
        let (body, body_truncated) = clipped(&body, 32768);
        let diff = text(raw, "diffHunk", MAX_BODY_INPUT)?;
        let (diff_hunk, diff_hunk_truncated) = clipped(&diff, 16384);
        let commit = if raw["commit"].is_null() {
            None
        } else {
            let oid = text(&raw["commit"], "oid", 40)?;
            head(&oid)?;
            Some(oid)
        };
        let url = text(raw, "url", 8192)?;
        let parsed = url::Url::parse(&url)?;
        ensure!(
            parsed.scheme() == "https"
                && parsed.host_str() == Some("github.com")
                && parsed.username().is_empty()
                && parsed.password().is_none()
                && parsed.query().is_none()
                && parsed
                    .path()
                    .eq_ignore_ascii_case(&format!("/{}/pull/{}", scope.repository, scope.number)),
            "Unsafe comment permalink"
        );
        let fragment = parsed.fragment().context("Missing comment fragment")?;
        let suffix = fragment
            .strip_prefix("discussion_r")
            .context("Unexpected comment permalink")?;
        ensure!(
            !suffix.is_empty() && suffix.bytes().all(|b| b.is_ascii_digit()),
            "Invalid comment permalink"
        );
        if let Some(id) = t.database_id {
            ensure!(suffix == id.to_string(), "Comment URL ID mismatch");
        }
        out.push(InlineComment {
            id: t.node_id,
            database_id: t.database_id,
            mentions: mention_text(&body),
            body,
            body_truncated,
            diff_hunk,
            diff_hunk_truncated,
            author: actor(&raw["author"])?,
            url,
            created_at: text(raw, "createdAt", 100)?,
            updated_at: text(raw, "updatedAt", 100)?,
            commit,
            reply_to: if raw["replyTo"].is_null() {
                None
            } else {
                Some(target(&raw["replyTo"])?)
            },
        });
    }
    Ok(out)
}
const MAX_BODY_INPUT: usize = 128 * 1024;

const FRAGMENT: &str = r#"fragment CoincideComment on PullRequestReviewComment { id databaseId: fullDatabaseId body diffHunk url createdAt updatedAt author { login } commit { oid } replyTo { id databaseId: fullDatabaseId } }"#;
const THREAD_QUERY: &str = r#"query CoincideReviewThreads($owner:String!,$name:String!,$number:Int!,$cursor:String) { repository(owner:$owner,name:$name) { pullRequest(number:$number) { number url headRefOid repository { nameWithOwner } reviewThreads(first:10,after:$cursor) { nodes { id path line startLine originalLine diffSide isResolved isOutdated resolvedBy { login } comments(first:20) { nodes { ...CoincideComment } pageInfo { hasNextPage endCursor } } } pageInfo { hasNextPage endCursor } } } } }"#;
const COMMENT_QUERY: &str = r#"query CoincideReviewComments($id:ID!,$cursor:String) { node(id:$id) { ... on PullRequestReviewThread { id pullRequest { number url headRefOid repository { nameWithOwner } } comments(first:20,after:$cursor) { nodes { ...CoincideComment } pageInfo { hasNextPage endCursor } } } } }"#;
#[derive(Clone)]
enum Request {
    Threads { cursor: Option<String> },
    Comments { id: String, cursor: Option<String> },
}
impl Request {
    fn cursor(&self) -> Option<&str> {
        match self {
            Self::Threads { cursor } | Self::Comments { cursor, .. } => cursor.as_deref(),
        }
    }
    fn argv(&self, scope: &Scope) -> Vec<String> {
        let query = match self {
            Self::Threads { .. } => THREAD_QUERY,
            Self::Comments { .. } => COMMENT_QUERY,
        };
        let mut args = vec![
            "api".into(),
            "graphql".into(),
            "--hostname".into(),
            "github.com".into(),
            "--method".into(),
            "POST".into(),
            "--raw-field".into(),
            format!("query={query}\n{FRAGMENT}"),
        ];
        match self {
            Self::Threads { .. } => {
                let (owner, name) = scope
                    .repository
                    .split_once('/')
                    .expect("validated repository");
                args.extend([
                    "--raw-field".into(),
                    format!("owner={owner}"),
                    "--raw-field".into(),
                    format!("name={name}"),
                    "--field".into(),
                    format!("number={}", scope.number),
                ]);
            }
            Self::Comments { id, .. } => args.extend(["--raw-field".into(), format!("id={id}")]),
        };
        if let Some(cursor) = self.cursor() {
            args.extend(["--raw-field".into(), format!("cursor={cursor}")]);
        }
        args
    }
}
fn decode(bytes: &[u8], scope: &Scope, request: &Request) -> Result<Page> {
    ensure!(
        bytes.len() <= 3 * 1024 * 1024,
        "Thread response exceeds 3 MiB"
    );
    let raw: Value = serde_json::from_slice(bytes)?;
    ensure!(
        raw.get("errors")
            .is_none_or(|v| v.is_null() || v.as_array().is_some_and(Vec::is_empty)),
        "GitHub GraphQL query failed"
    );
    let mut page = Page {
        kind: String::new(),
        scope: scope.clone(),
        review_thread_id: None,
        cursor: request.cursor().map(str::to_owned),
        next_cursor: None,
        has_next_page: false,
        threads: vec![],
        comments: vec![],
    };
    match request {
        Request::Threads { .. } => {
            let pr = &raw["data"]["repository"]["pullRequest"];
            verify_pr(pr, scope)?;
            let connection = &pr["reviewThreads"];
            let (next, more) = page_info(connection, request.cursor())?;
            page.kind = "threads".into();
            page.next_cursor = next;
            page.has_next_page = more;
            let nodes = connection["nodes"]
                .as_array()
                .context("Missing review threads")?;
            ensure!(nodes.len() <= THREAD_PAGE, "Thread page limit exceeded");
            let mut seen = HashSet::new();
            for thread in nodes {
                let id = text(thread, "id", 256)?;
                handle(&id, 256)?;
                ensure!(seen.insert(id.clone()), "Duplicate review thread");
                let path = text(thread, "path", 4096)?;
                ensure!(!path.is_empty(), "Missing diff path");
                let side = text(thread, "diffSide", 16)?;
                ensure!(
                    ["LEFT", "RIGHT"].contains(&side.as_str()),
                    "Invalid diff side"
                );
                let (next_cursor, has_next_page) = page_info(&thread["comments"], None)?;
                page.threads.push(ReviewThread {
                    id,
                    path,
                    line: line(thread, "line")?,
                    start_line: line(thread, "startLine")?,
                    original_line: line(thread, "originalLine")?,
                    diff_side: side,
                    is_resolved: flag(thread, "isResolved")?,
                    is_outdated: flag(thread, "isOutdated")?,
                    resolved_by: actor(&thread["resolvedBy"])?,
                    comments: comments(&thread["comments"], scope)?,
                    next_cursor,
                    has_next_page,
                });
            }
        }
        Request::Comments { id, .. } => {
            let node = &raw["data"]["node"];
            ensure!(
                node["id"].as_str() == Some(id.as_str()),
                "Review thread handle changed"
            );
            verify_pr(&node["pullRequest"], scope)?;
            let (next, more) = page_info(&node["comments"], request.cursor())?;
            page.kind = "comments".into();
            page.review_thread_id = Some(id.clone());
            page.next_cursor = next;
            page.has_next_page = more;
            page.comments = comments(&node["comments"], scope)?;
        }
    }
    Ok(page)
}
struct Slot(Arc<AtomicUsize>);
impl Drop for Slot {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}
const RETAINED_BYTES: usize = 8 * 1024 * 1024;
struct Payload {
    value: Value,
    bytes: usize,
    quota: Arc<AtomicUsize>,
}
impl Payload {
    fn new(mut value: Value, quota: Arc<AtomicUsize>) -> Self {
        let bytes = serde_json::to_vec(&value)
            .map(|v| v.len())
            .unwrap_or(usize::MAX);
        let mut current = quota.load(Ordering::Acquire);
        if bytes <= 3 * 1024 * 1024 {
            loop {
                if current.saturating_add(bytes) > RETAINED_BYTES {
                    break;
                }
                match quota.compare_exchange(
                    current,
                    current + bytes,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                ) {
                    Ok(_) => {
                        return Self {
                            value,
                            bytes,
                            quota,
                        };
                    }
                    Err(next) => current = next,
                }
            }
        }
        value = json!({"code":"payload_limit","error":"Inline review payload budget reached; refresh fewer pages"});
        // Error envelopes are constant-sized and independently bounded by 16 slots.
        Self {
            value,
            bytes: 0,
            quota,
        }
    }
    fn error(code: &str, message: &str, quota: Arc<AtomicUsize>) -> Self {
        Self {
            value: json!({"code":code,"error":message}),
            bytes: 0,
            quota,
        }
    }
}
impl Drop for Payload {
    fn drop(&mut self) {
        self.quota.fetch_sub(self.bytes, Ordering::AcqRel);
    }
}
struct Pending {
    binding: Bound,
    cancel: Arc<AtomicBool>,
    started: Instant,
    receiver: mpsc::Receiver<Payload>,
    result: Option<Payload>,
}
pub struct GithubThreadsService {
    runner: GhRunner,
    operations: HashMap<String, Pending>,
    slots: Arc<AtomicUsize>,
    payload_bytes: Arc<AtomicUsize>,
    known_threads: HashMap<(String, String), (Bound, Instant)>,
}
impl GithubThreadsService {
    pub fn new(runner: GhRunner) -> Self {
        Self {
            runner,
            operations: HashMap::new(),
            slots: Arc::new(AtomicUsize::new(0)),
            payload_bytes: Arc::new(AtomicUsize::new(0)),
            known_threads: HashMap::new(),
        }
    }
    fn reserve(&self) -> Result<Slot> {
        let mut n = self.slots.load(Ordering::Acquire);
        loop {
            ensure!(n < 2, "Two thread reads already active");
            match self
                .slots
                .compare_exchange(n, n + 1, Ordering::AcqRel, Ordering::Acquire)
            {
                Ok(_) => return Ok(Slot(self.slots.clone())),
                Err(current) => n = current,
            }
        }
    }
    fn collect(&mut self) {
        self.known_threads
            .retain(|_, (_, issued)| issued.elapsed() < Duration::from_secs(120));
        self.operations.retain(|_, op| {
            if op.started.elapsed() >= Duration::from_secs(120) {
                op.cancel.store(true, Ordering::Release);
                return false;
            }
            if op.result.is_none() {
                if op.started.elapsed() >= Duration::from_secs(20) {
                    op.cancel.store(true, Ordering::Release);
                    op.result = Some(Payload::error(
                        "timeout",
                        "Inline review read timed out",
                        self.payload_bytes.clone(),
                    ));
                } else {
                    match op.receiver.try_recv() {
                        Ok(v) => op.result = Some(v),
                        Err(mpsc::TryRecvError::Disconnected) => {
                            op.result = Some(Payload::error(
                                "read_failed",
                                "Inline review worker stopped",
                                self.payload_bytes.clone(),
                            ))
                        }
                        Err(mpsc::TryRecvError::Empty) => {}
                    }
                }
            }
            true
        });
    }
    /// Parent resolves authoritative stored root from its thread store, not JSON.
    pub fn start(
        &mut self,
        thread: &str,
        stored_root: &Path,
        method: &str,
        params: &Value,
    ) -> Result<Value> {
        let binding = Bound::new(thread, stored_root, params)?;
        let cursor = optional_cursor(params.get("cursor"))?;
        self.collect();
        let request = match method {
            "github.threads.list" => Request::Threads { cursor },
            "github.threads.comments" => {
                let id = params["reviewThreadId"]
                    .as_str()
                    .context("reviewThreadId required")?
                    .to_owned();
                handle(&id, 256)?;
                ensure!(
                    self.known_threads
                        .get(&(thread.to_owned(), id.clone()))
                        .is_some_and(|(known, _)| known.same(&binding)),
                    "List threads in this exact scope before requesting comments"
                );
                Request::Comments { id, cursor }
            }
            _ => bail!("Unsupported read-only review-thread method"),
        };
        self.collect();
        // Keep reads usable after many pages: evict only completed results,
        // oldest first. Active requests are never evicted to make room.
        while self.operations.len() >= 16
            || self.payload_bytes.load(Ordering::Acquire) > RETAINED_BYTES - 3 * 1024 * 1024
        {
            let oldest = self
                .operations
                .iter()
                .filter(|(_, op)| op.result.is_some())
                .max_by_key(|(_, op)| op.started.elapsed())
                .map(|(id, _)| id.clone());
            if let Some(id) = oldest {
                self.operations.remove(&id);
            } else {
                break;
            }
        }
        ensure!(
            self.operations.len() < 16,
            "Too many active inline review operations"
        );
        let slot = self.reserve()?;
        let id = uuid::Uuid::new_v4().to_string();
        let (sender, receiver) = mpsc::sync_channel(1);
        let cancel = Arc::new(AtomicBool::new(false));
        let worker_cancel = cancel.clone();
        let runner = self.runner.clone();
        let payload_quota = self.payload_bytes.clone();
        let worker_binding = binding.clone();
        std::thread::Builder::new().name("github-threads".into()).spawn(move||{let _slot=slot;let result=(||{worker_binding.recheck()?;let bytes=runner.capture(&worker_binding.root,&request.argv(&worker_binding.scope),&worker_cancel)?;ensure!(!worker_cancel.load(Ordering::Acquire),"Read cancelled");worker_binding.recheck()?;serde_json::to_value(decode(&bytes,&worker_binding.scope,&request)?).map_err(Into::into)})();let result=match result{Ok(value)=>value,Err(error)=>{let changed=error.to_string()=="PR head changed";json!({"code":if changed{"head_changed"}else{"read_failed"},"error":if changed{"PR head changed; refresh the selected PR"}else{"Unable to read validated inline review data"}})}};let _=sender.try_send(Payload::new(result,payload_quota));})?;
        self.operations.insert(
            id.clone(),
            Pending {
                binding,
                cancel,
                started: Instant::now(),
                receiver,
                result: None,
            },
        );
        Ok(json!({"operationId":id}))
    }
    fn checked(&mut self, thread: &str, stored_root: &Path, params: &Value) -> Result<String> {
        self.collect();
        let binding = Bound::new(thread, stored_root, params)?;
        let id = params["operationId"]
            .as_str()
            .context("operationId required")?;
        let op = self
            .operations
            .get(id)
            .context("Inline review operation unknown or expired")?;
        ensure!(
            op.binding.same(&binding),
            "Inline review result belongs to another scope"
        );
        Ok(id.into())
    }
    /// Non-consuming; retained for 120 seconds from start, with a 16-operation cap.
    pub fn result(&mut self, thread: &str, stored_root: &Path, params: &Value) -> Result<Value> {
        let id = self.checked(thread, stored_root, params)?;
        let op = &self.operations[&id];
        let response = json!({"ready":op.result.is_some(),"result":op.result.as_ref().map(|payload|&payload.value)});
        let binding = op.binding.clone();
        let ids = op
            .result
            .as_ref()
            .filter(|p| p.value["kind"] == "threads")
            .and_then(|p| p.value["threads"].as_array())
            .map(|rows| {
                rows.iter()
                    .filter_map(|t| t["id"].as_str().map(str::to_owned))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        for id in ids {
            if self.known_threads.len() >= 1000 {
                if let Some(oldest) = self
                    .known_threads
                    .iter()
                    .max_by_key(|(_, (_, issued))| issued.elapsed())
                    .map(|(key, _)| key.clone())
                {
                    self.known_threads.remove(&oldest);
                }
            }
            self.known_threads
                .insert((thread.into(), id), (binding.clone(), Instant::now()));
        }
        Ok(response)
    }
    pub fn cancel(&mut self, thread: &str, stored_root: &Path, params: &Value) -> Result<Value> {
        let id = self.checked(thread, stored_root, params)?;
        let op = self.operations.get_mut(&id).expect("checked operation");
        op.cancel.store(true, Ordering::Release);
        op.result = Some(Payload::error(
            "cancelled",
            "Inline review read cancelled",
            self.payload_bytes.clone(),
        ));
        Ok(json!({"cancelled":true}))
    }
}
impl Drop for GithubThreadsService {
    fn drop(&mut self) {
        for op in self.operations.values() {
            op.cancel.store(true, Ordering::Release);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn scope(root: &Path) -> Scope {
        Scope {
            thread_id: uuid::Uuid::new_v4().to_string(),
            expected_root: root.to_str().unwrap().into(),
            repository: "owner/project".into(),
            number: 7,
            expected_head: "a".repeat(40),
        }
    }
    fn pr() -> Value {
        json!({"number":7,"url":"https://github.com/owner/project/pull/7","headRefOid":"a".repeat(40),"repository":{"nameWithOwner":"owner/project"}})
    }
    fn comment(id: u64, reply: bool) -> Value {
        json!({"id":format!("comment-{id}"),"databaseId":id,"body":"Hello @octocat and @org/team; mail user@example.com; `@code`\n```\n@hidden\n```","diffHunk":"@@ -1 +1 @@\n-old\n+new","url":format!("https://github.com/owner/project/pull/7#discussion_r{id}"),"createdAt":"2026-11-05T00:00:00Z","updatedAt":"2026-11-05T00:00:01Z","author":null,"commit":{"oid":"a".repeat(40)},"replyTo":if reply{json!({"id":"comment-11","databaseId":11})}else{Value::Null}})
    }
    fn connection(nodes: Vec<Value>, next: Option<&str>) -> Value {
        json!({"nodes":nodes,"pageInfo":{"hasNextPage":next.is_some(),"endCursor":next}})
    }
    fn thread(id: &str) -> Value {
        json!({"id":id,"path":"src/界.rs","line":4,"startLine":null,"originalLine":3,"diffSide":"RIGHT","isResolved":false,"isOutdated":true,"resolvedBy":null,"comments":connection(vec![comment(11,false)],Some("reply-cursor"))})
    }
    fn response(next: Option<&str>) -> Value {
        let mut p = pr();
        p["reviewThreads"] = connection(vec![thread("thread-1")], next);
        json!({"data":{"repository":{"pullRequest":p}}})
    }
    #[test]
    fn typed_comments_reply_targets_resolution_and_mention_text_have_truthful_limits() {
        let dir = tempfile::tempdir().unwrap();
        let scope = scope(dir.path());
        let page = decode(
            &serde_json::to_vec(&response(None)).unwrap(),
            &scope,
            &Request::Threads { cursor: None },
        )
        .unwrap();
        assert_eq!(page.threads[0].path, "src/界.rs");
        assert!(page.threads[0].is_outdated && !page.threads[0].is_resolved);
        assert_eq!(
            page.threads[0].comments[0].mentions,
            vec![
                Mention {
                    text: "@octocat".into(),
                    kind: "user".into()
                },
                Mention {
                    text: "@org/team".into(),
                    kind: "team".into()
                }
            ]
        );
        assert!(page.threads[0].comments[0].author.is_none());
        let mut nullable = response(None);
        nullable["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"][0]["comments"]["nodes"]
            [0]["commit"] = Value::Null;
        nullable["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"][0]["comments"]["nodes"]
            [0]["databaseId"] = json!("11");
        let nullable = decode(
            &serde_json::to_vec(&nullable).unwrap(),
            &scope,
            &Request::Threads { cursor: None },
        )
        .unwrap();
        assert!(nullable.threads[0].comments[0].commit.is_none());
        let raw = json!({"data":{"node":{"id":"thread-1","pullRequest":pr(),"comments":connection(vec![comment(12,true)],None)}}});
        let page = decode(
            &serde_json::to_vec(&raw).unwrap(),
            &scope,
            &Request::Comments {
                id: "thread-1".into(),
                cursor: Some("reply-cursor".into()),
            },
        )
        .unwrap();
        assert_eq!(
            page.comments[0].reply_to.as_ref().unwrap().database_id,
            Some(11)
        );
    }
    #[test]
    fn partial_errors_stale_head_wrong_repo_host_and_nonadvancing_pages_fail_closed() {
        let dir = tempfile::tempdir().unwrap();
        let scope = scope(dir.path());
        for change in 0..5 {
            let mut value = response(None);
            match change {
                0 => value["errors"] = json!([{"message":"partial private diagnostic"}]),
                1 => {
                    value["data"]["repository"]["pullRequest"]["headRefOid"] = json!("b".repeat(40))
                }
                2 => {
                    value["data"]["repository"]["pullRequest"]["repository"]["nameWithOwner"] =
                        json!("other/project")
                }
                3 => {
                    value["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"][0]["comments"]
                        ["nodes"][0]["url"] = json!("javascript:alert(1)")
                }
                _ => {
                    value["data"]["repository"]["pullRequest"]["reviewThreads"]["pageInfo"] =
                        json!({"hasNextPage":true,"endCursor":null})
                }
            };
            assert!(
                decode(
                    &serde_json::to_vec(&value).unwrap(),
                    &scope,
                    &Request::Threads { cursor: None }
                )
                .is_err()
            );
        }
        assert!(
            decode(
                &serde_json::to_vec(&response(Some("same"))).unwrap(),
                &scope,
                &Request::Threads {
                    cursor: Some("same".into())
                }
            )
            .is_err()
        );
    }
    #[test]
    fn clipped_text_stays_utf8_and_queued_payloads_share_byte_budget() {
        let (clipped, truncated) = clipped(&"界".repeat(12000), 32768);
        assert!(truncated && clipped.len() <= 32768);
        assert!(std::str::from_utf8(clipped.as_bytes()).is_ok());
        let quota = Arc::new(AtomicUsize::new(0));
        let one = Payload::new(json!({"data":"x".repeat(3*1024*1024-100)}), quota.clone());
        let two = Payload::new(json!({"data":"x".repeat(3*1024*1024-100)}), quota.clone());
        let rejected = Payload::new(json!({"data":"x".repeat(3*1024*1024-100)}), quota.clone());
        assert_eq!(rejected.value["code"], "payload_limit");
        assert!(quota.load(Ordering::Acquire) <= RETAINED_BYTES);
        drop(one);
        drop(two);
        drop(rejected);
        assert_eq!(quota.load(Ordering::Acquire), 0);
    }
    #[cfg(unix)]
    fn fixture(script: &str) -> (tempfile::TempDir, GithubThreadsService, Scope) {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let exe = root.join("fake-gh");
        std::fs::write(&exe, script).unwrap();
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o700)).unwrap();
        let service = GithubThreadsService::new(GhRunner::new(exe).unwrap());
        let scope = scope(&root);
        (dir, service, scope)
    }
    #[cfg(unix)]
    fn wait(service: &mut GithubThreadsService, scope: &Scope, id: &str) -> Value {
        let mut p = scope.params();
        p["operationId"] = json!(id);
        let deadline = Instant::now() + Duration::from_secs(4);
        loop {
            let value = service
                .result(&scope.thread_id, Path::new(&scope.expected_root), &p)
                .unwrap();
            if value["ready"] == true {
                return value["result"].clone();
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    #[cfg(unix)]
    const FAKE: &str = r#"#!/usr/bin/env python3
import json,sys,os
args=sys.argv[1:]
assert args[:2]==['api','graphql'] and args[args.index('--hostname')+1]=='github.com'
assert args[args.index('--method')+1]=='POST' and os.environ['GH_HOST']=='github.com'
fields={}
for i,arg in enumerate(args):
 if arg in ['--raw-field','--field']:
  key,value=args[i+1].split('=',1);fields[key]=value
query=fields['query']
assert 'mutation ' not in query and 'CoincideComment' in query
with open('calls.jsonl','a') as log:log.write(json.dumps(fields)+'\n')
if query.startswith('query CoincideReviewComments'):
 assert fields['id']=='thread-1' and fields['cursor']=='reply-cursor'
 name='replies.json'
else:
 assert query.startswith('query CoincideReviewThreads') and fields['owner']=='owner' and fields['name']=='project' and fields['number']=='7'
 if 'cursor' in fields:
  assert fields['cursor']==open('cursor.txt').read();name='more.json'
 else:name='first.json'
print(open(name).read(),flush=True)
"#;
    #[cfg(unix)]
    #[test]
    fn actual_fake_process_pages_threads_and_replies_without_query_interpolation() {
        let (dir, mut service, scope) = fixture(FAKE);
        let cursor = "opaque\"; $(touch forbidden)";
        std::fs::write(dir.path().join("cursor.txt"), cursor).unwrap();
        std::fs::write(
            dir.path().join("first.json"),
            serde_json::to_vec(&response(Some(cursor))).unwrap(),
        )
        .unwrap();
        let mut more = response(None);
        more["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"][0]["id"] =
            json!("thread-2");
        std::fs::write(
            dir.path().join("more.json"),
            serde_json::to_vec(&more).unwrap(),
        )
        .unwrap();
        let replies = json!({"data":{"node":{"id":"thread-1","pullRequest":pr(),"comments":connection(vec![comment(12,true)],None)}}});
        std::fs::write(
            dir.path().join("replies.json"),
            serde_json::to_vec(&replies).unwrap(),
        )
        .unwrap();
        let mut p = scope.params();
        let id = service
            .start(&scope.thread_id, dir.path(), "github.threads.list", &p)
            .unwrap()["operationId"]
            .as_str()
            .unwrap()
            .to_string();
        let first = wait(&mut service, &scope, &id);
        assert_eq!(first["nextCursor"], cursor);
        assert_eq!(first["threads"][0]["id"], "thread-1");
        assert_eq!(wait(&mut service, &scope, &id), first);
        p["cursor"] = json!(cursor);
        let id = service
            .start(&scope.thread_id, dir.path(), "github.threads.list", &p)
            .unwrap()["operationId"]
            .as_str()
            .unwrap()
            .to_string();
        assert_eq!(
            wait(&mut service, &scope, &id)["threads"][0]["id"],
            "thread-2"
        );
        p["reviewThreadId"] = json!("thread-1");
        p["cursor"] = json!("reply-cursor");
        let id = service
            .start(&scope.thread_id, dir.path(), "github.threads.comments", &p)
            .unwrap()["operationId"]
            .as_str()
            .unwrap()
            .to_string();
        let replies = wait(&mut service, &scope, &id);
        assert_eq!(replies["comments"][0]["replyTo"]["nodeId"], "comment-11");
        assert!(!dir.path().join("forbidden").exists());
        let calls = std::fs::read_to_string(dir.path().join("calls.jsonl")).unwrap();
        assert_eq!(calls.lines().count(), 3);
        assert!(
            calls
                .lines()
                .map(|v| serde_json::from_str::<Value>(v).unwrap())
                .all(|v| !v["query"].as_str().unwrap().contains(cursor))
        );
    }
    #[cfg(unix)]
    #[test]
    fn cancellation_kills_fake_process_and_refuses_cross_scope_results() {
        let (dir, mut service, scope) = fixture(
            "#!/usr/bin/env python3\nimport time\nopen('started','w').write('yes')\ntime.sleep(10)\n",
        );
        let id = service
            .start(
                &scope.thread_id,
                dir.path(),
                "github.threads.list",
                &scope.params(),
            )
            .unwrap()["operationId"]
            .as_str()
            .unwrap()
            .to_string();
        let deadline = Instant::now() + Duration::from_secs(2);
        while !dir.path().join("started").exists() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
        let mut p = scope.params();
        p["operationId"] = json!(id);
        let mut other = p.clone();
        let other_id = uuid::Uuid::new_v4().to_string();
        other["threadId"] = json!(other_id);
        assert!(service.result(&other_id, dir.path(), &other).is_err());
        other = p.clone();
        other["expectedHead"] = json!("b".repeat(40));
        assert!(
            service
                .result(&scope.thread_id, dir.path(), &other)
                .is_err()
        );
        assert_eq!(
            service.cancel(&scope.thread_id, dir.path(), &p).unwrap()["cancelled"],
            true
        );
        assert_eq!(wait(&mut service, &scope, &id)["code"], "cancelled");
        let deadline = Instant::now() + Duration::from_secs(2);
        while service.slots.load(Ordering::Acquire) > 0 {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
