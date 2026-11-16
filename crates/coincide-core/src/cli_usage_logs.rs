//! Local, incremental Claude Code and Codex usage-log projection.
//!
//! Only token counts, dates, models and hashed response identities survive a
//! scan. Prompts, replies, credentials and the original files are never saved
//! or sent anywhere. A partial scan is not authority to replace saved usage.
use crate::{
    cli_session_import::ImportProvider,
    usage_report::{Event, TokenTotals},
};
use chrono::{DateTime, Duration, Utc};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::{BufRead, BufReader, Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    time::SystemTime,
};

const MAX_VISITED: usize = 100_000;
const MAX_FILES: usize = 20_000;
const MAX_EVENTS: usize = 500_000;
const MAX_LINE: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Source {
    pub provider: ImportProvider,
    pub account_id: String,
    pub roots: Vec<PathBuf>,
}

#[derive(Clone, Debug, Default)]
pub struct Scan {
    pub events: Vec<LoggedEvent>,
    /// Only providers scanned without an IO/bounds failure and with log files.
    pub complete_providers: Vec<&'static str>,
    pub incomplete_providers: Vec<&'static str>,
    pub files_read: usize,
    pub bytes_read: u64,
}

#[derive(Clone, Debug)]
pub struct LoggedEvent {
    pub event: Event,
    pub is_from_coincide: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionOwner {
    pub project_id: Option<String>,
    pub account_id: String,
}

/// A known session maps to its owner; None records an ambiguous shared ID.
pub type SessionOwners = HashMap<(String, String), Option<SessionOwner>>;

/// Windows SQLite does not implement SQLITE_FCNTL_HAS_MOVED. Hold the actual
/// database open without FILE_SHARE_DELETE there, so it cannot be replaced or
/// renamed while SQLite opens and reads it. Other platforms use their normal
/// no-follow handle plus SQLite's own moved-file check.
fn open_usage_database(path: &Path) -> anyhow::Result<fs::File> {
    #[cfg(windows)]
    {
        use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
        use windows_sys::Win32::Storage::FileSystem::{
            FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
            FILE_SHARE_WRITE,
        };
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .open(path)?;
        let metadata = file.metadata()?;
        anyhow::ensure!(
            metadata.is_file() && metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0,
            "Usage store is not a regular file"
        );
        Ok(file)
    }
    #[cfg(not(windows))]
    {
        crate::native_file::open_regular(path, false)
    }
}

fn owner(
    owners: &mut SessionOwners,
    provider: &str,
    reference: &Value,
    project: &Option<String>,
    fallback_account: Option<&str>,
) {
    if !matches!(provider, "codex" | "claude") {
        return;
    }
    let Some(session) = name(&reference["sessionID"]) else {
        return;
    };
    let account = name(&reference["accountID"])
        .or_else(|| {
            fallback_account
                .filter(|value| {
                    !value.is_empty() && value.len() <= 512 && !value.chars().any(char::is_control)
                })
                .map(str::to_owned)
        })
        .unwrap_or_else(|| "default".into());
    let owner = SessionOwner {
        project_id: project.clone(),
        account_id: account,
    };
    let key = (provider.to_owned(), session.to_lowercase());
    owners
        .entry(key)
        .and_modify(|old| {
            if old.as_ref() != Some(&owner) {
                *old = None;
            }
        })
        .or_insert(Some(owner));
}

/// Read only session/project metadata using a separate read-only connection;
/// conversation messages and drafts never leave SQLite.
pub fn session_owners(path: &Path, cancelled: &dyn Fn() -> bool) -> anyhow::Result<SessionOwners> {
    let held = open_usage_database(path)?;
    let identity = crate::native_file::file_identity(&held)?;
    let db = rusqlite::Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )?;
    anyhow::ensure!(
        db.path().map(Path::new) == Some(path)
            && crate::native_file::path_identity(path)? == identity,
        "Usage store identity changed"
    );
    let verify = || -> anyhow::Result<()> {
        let mut moved: std::ffi::c_int = 0;
        // SAFETY: db is live and `moved` is writable for this SQLite call.
        let code = unsafe {
            rusqlite::ffi::sqlite3_file_control(
                db.handle(),
                c"main".as_ptr(),
                rusqlite::ffi::SQLITE_FCNTL_HAS_MOVED,
                (&mut moved as *mut std::ffi::c_int).cast(),
            )
        };
        let verified = code == rusqlite::ffi::SQLITE_OK && moved == 0;
        #[cfg(windows)]
        let verified = verified || code == rusqlite::ffi::SQLITE_NOTFOUND;
        anyhow::ensure!(verified, "Usage store moved");
        Ok(())
    };
    verify()?;
    db.busy_timeout(std::time::Duration::from_secs(2))?;
    let mut statement = db.prepare("SELECT json_extract(document,'$.projectID'), json_extract(document,'$.sessions'), json_extract(document,'$.accountSessions'), json_extract(document,'$.importedSession') FROM threads LIMIT 100001")?;
    let mut rows = statement.query([])?;
    let mut owners = SessionOwners::new();
    let mut visited = 0;
    while let Some(row) = rows.next()? {
        if cancelled() {
            anyhow::bail!("Usage scan was cancelled");
        }
        visited += 1;
        anyhow::ensure!(
            visited <= 100_000,
            "Too many conversations for usage association"
        );
        let project: Option<String> = row.get(0)?;
        let parse = |value: Option<String>| -> anyhow::Result<Value> {
            match value {
                Some(value) => {
                    anyhow::ensure!(value.len() <= 1024 * 1024, "Session metadata is too large");
                    Ok(serde_json::from_str(&value)?)
                }
                None => Ok(Value::Null),
            }
        };
        let sessions = parse(row.get(1)?)?;
        if let Some(values) = sessions.as_object() {
            for (provider, reference) in values {
                owner(&mut owners, provider, reference, &project, None);
            }
        } else if let Some(values) = sessions.as_array() {
            anyhow::ensure!(values.len() % 2 == 0, "Invalid saved session metadata");
            for pair in values.as_chunks::<2>().0 {
                if let Some(provider) = pair[0].as_str() {
                    owner(&mut owners, provider, &pair[1], &project, None);
                }
            }
        } else {
            anyhow::ensure!(sessions.is_null(), "Invalid saved session metadata");
        }
        let accounts = parse(row.get(2)?)?;
        if let Some(accounts) = accounts.as_object() {
            for (key, reference) in accounts {
                if let Some((provider, account)) = key.split_once('/') {
                    owner(&mut owners, provider, reference, &project, Some(account));
                }
            }
        } else {
            anyhow::ensure!(accounts.is_null(), "Invalid account session metadata");
        }
        let imported = parse(row.get(3)?)?;
        if let Some(provider) = imported["provider"].as_str() {
            owner(&mut owners, provider, &imported, &project, None);
        }
    }
    anyhow::ensure!(
        crate::native_file::path_identity(path)? == identity,
        "Usage store changed"
    );
    verify()?;
    Ok(owners)
}

#[derive(Clone)]
struct Request {
    event: Event,
    /// Claude response identity, or a Codex session/event identity.
    key: Option<[u8; 32]>,
    session: Option<String>,
    from_coincide: bool,
}

#[derive(Clone, Default)]
struct Codex {
    session: Option<String>,
    from_coincide: bool,
    model: Option<String>,
    started: Option<DateTime<Utc>>,
    fork: bool,
    last: Option<[u64; 5]>,
}

#[derive(Clone)]
struct CachedFile {
    account: String,
    provider: ImportProvider,
    identity: crate::native_file::Identity,
    size: u64,
    modified: SystemTime,
    offset: u64,
    head: [u8; 32],
    tail: [u8; 32],
    codex: Codex,
    requests: Vec<Request>,
    incomplete: bool,
}

#[derive(Default)]
pub struct Scanner {
    files: HashMap<PathBuf, CachedFile>,
}

fn provider_name(provider: ImportProvider) -> &'static str {
    match provider {
        ImportProvider::Codex => "codex",
        ImportProvider::Claude => "claude",
    }
}

fn date(value: &Value) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value.as_str()?)
        .ok()
        .map(|date| date.with_timezone(&Utc))
}

fn count(value: &Value, field: &str) -> u64 {
    value[field].as_u64().unwrap_or(0)
}

fn name(value: &Value) -> Option<String> {
    let text = value.as_str()?;
    (!text.is_empty() && text.len() <= 512 && !text.chars().any(char::is_control))
        .then(|| text.to_owned())
}

fn digest(parts: &[&[u8]]) -> [u8; 32] {
    let mut hash = Sha256::new();
    for part in parts {
        hash.update((part.len() as u64).to_le_bytes());
        hash.update(part);
    }
    hash.finalize().into()
}

fn claude(value: &Value, account: &str) -> Option<Request> {
    if value["type"] != "assistant" || value["message"]["model"] == "<synthetic>" {
        return None;
    }
    let message = &value["message"];
    let usage = &message["usage"];
    usage.as_object()?;
    let tokens = TokenTotals::new(
        count(usage, "input_tokens"),
        count(usage, "cache_read_input_tokens"),
        count(usage, "cache_creation_input_tokens"),
        count(&usage["cache_creation"], "ephemeral_1h_input_tokens"),
        count(usage, "output_tokens"),
        count(&usage["output_tokens_details"], "thinking_tokens"),
    );
    if tokens.is_empty() {
        return None;
    }
    let key = message["id"]
        .as_str()
        .filter(|id| !id.is_empty())
        .map(|id| {
            digest(&[
                b"claude",
                account.as_bytes(),
                id.as_bytes(),
                value["requestId"].as_str().unwrap_or("").as_bytes(),
            ])
        });
    Some(Request {
        event: Event {
            date: date(&value["timestamp"])?,
            provider: "claude".into(),
            account_id: account.into(),
            model: name(&message["model"]),
            tokens,
            prompt_tokens: tokens
                .input
                .saturating_add(tokens.cache_read)
                .saturating_add(tokens.cache_write),
            project_id: None,
        },
        key,
        session: name(&value["sessionId"]),
        from_coincide: false,
    })
}

fn codex_counts(value: &Value) -> [u64; 5] {
    [
        count(value, "input_tokens"),
        count(value, "cached_input_tokens"),
        count(value, "cache_write_input_tokens"),
        count(value, "output_tokens"),
        count(value, "reasoning_output_tokens"),
    ]
}

impl Codex {
    fn consume(&mut self, value: &Value, account: &str) -> Option<Request> {
        let payload = &value["payload"];
        match value["type"].as_str()? {
            "session_meta" if self.session.is_none() => {
                self.session = name(&payload["id"]);
                self.from_coincide = payload["originator"]
                    .as_str()
                    .is_some_and(|value| value.eq_ignore_ascii_case("coincide"));
                self.started = date(&payload["timestamp"]).or_else(|| date(&value["timestamp"]));
                self.fork = payload["forked_from_id"].is_string();
                None
            }
            "turn_context" => {
                if let Some(model) = name(&payload["model"]) {
                    self.model = Some(model);
                }
                None
            }
            "event_msg" if payload["type"] == "token_count" => {
                let info = &payload["info"];
                let total = &info["total_token_usage"];
                total.as_object()?;
                let current = codex_counts(total);
                let previous = self.last.replace(current);
                let when = date(&value["timestamp"])?;
                if self.fork
                    && self
                        .started
                        .is_some_and(|start| when < start - Duration::seconds(1))
                {
                    return None;
                }
                let delta = match previous {
                    Some(previous) if current.iter().zip(previous).all(|(a, b)| *a >= b) => {
                        std::array::from_fn(|i| current[i] - previous[i])
                    }
                    Some(_) if info["last_token_usage"].is_object() => {
                        codex_counts(&info["last_token_usage"])
                    }
                    _ => current,
                };
                if delta.iter().all(|n| *n == 0) {
                    return None;
                }
                let cached = delta[1].min(delta[0]);
                let written = delta[2].min(delta[0] - cached);
                let tokens = TokenTotals::new(
                    delta[0] - cached - written,
                    cached,
                    written,
                    0,
                    delta[3],
                    delta[4],
                );
                if tokens.is_empty() {
                    return None;
                }
                let key = self.session.as_deref().map(|session| {
                    digest(&[
                        b"codex",
                        account.as_bytes(),
                        session.as_bytes(),
                        when.to_rfc3339().as_bytes(),
                        &current
                            .iter()
                            .flat_map(|n| n.to_le_bytes())
                            .collect::<Vec<_>>(),
                    ])
                });
                Some(Request {
                    event: Event {
                        date: when,
                        provider: "codex".into(),
                        account_id: account.into(),
                        model: self.model.clone(),
                        tokens,
                        prompt_tokens: if info["last_token_usage"].is_object() {
                            count(&info["last_token_usage"], "input_tokens")
                        } else {
                            delta[0]
                        },
                        project_id: None,
                    },
                    key,
                    session: self.session.clone(),
                    from_coincide: self.from_coincide,
                })
            }
            _ => None,
        }
    }
}

/// Read one complete line without ever allocating more than MAX_LINE. A final
/// unfinished line stays unread logically so the next scan can pick it up.
fn line(
    reader: &mut impl BufRead,
    output: &mut Vec<u8>,
    cancelled: &dyn Fn() -> bool,
) -> std::io::Result<(usize, bool, bool)> {
    output.clear();
    let mut consumed = 0;
    let mut oversized = false;
    loop {
        if cancelled() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "Usage scan cancelled",
            ));
        }
        let bytes = reader.fill_buf()?;
        if bytes.is_empty() {
            return Ok((consumed, false, oversized));
        }
        let end = bytes.iter().position(|byte| *byte == b'\n');
        let take = end.map_or(bytes.len(), |position| position + 1);
        if output.len().saturating_add(take) > MAX_LINE {
            oversized = true;
        } else if !oversized {
            output.extend_from_slice(&bytes[..take]);
        }
        reader.consume(take);
        consumed += take;
        if end.is_some() {
            return Ok((consumed, true, oversized));
        }
    }
}

fn contains(bytes: &[u8], needle: &[u8]) -> bool {
    bytes.windows(needle.len()).any(|window| window == needle)
}

fn edges(file: &mut fs::File, offset: u64) -> std::io::Result<([u8; 32], [u8; 32])> {
    let length = offset.min(4096) as usize;
    let mut buffer = vec![0; length];
    file.seek(SeekFrom::Start(0))?;
    file.read_exact(&mut buffer)?;
    let head = Sha256::digest(&buffer).into();
    file.seek(SeekFrom::Start(offset - length as u64))?;
    file.read_exact(&mut buffer)?;
    Ok((head, Sha256::digest(&buffer).into()))
}

fn read_file(
    path: &Path,
    provider: ImportProvider,
    account: &str,
    previous: Option<CachedFile>,
    cancelled: &dyn Fn() -> bool,
) -> anyhow::Result<(CachedFile, u64)> {
    let mut file = crate::native_file::open_regular(path, false)?;
    let identity = crate::native_file::file_identity(&file)?;
    let metadata = file.metadata()?;
    let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
    let size = metadata.len();
    let resumable = previous.as_ref().is_some_and(|entry| {
        entry.provider == provider
            && entry.account == account
            && entry.identity == identity
            && entry.size < size
            && entry.offset <= size
            && entry.modified <= modified
    });
    let mut entry = if resumable {
        previous.expect("checked above")
    } else {
        CachedFile {
            account: account.into(),
            provider,
            identity,
            size: 0,
            modified,
            offset: 0,
            head: [0; 32],
            tail: [0; 32],
            codex: Codex::default(),
            requests: Vec::new(),
            incomplete: false,
        }
    };
    if entry.offset > 0 {
        if edges(&mut file, entry.offset)? != (entry.head, entry.tail) {
            return read_file(path, provider, account, None, cancelled);
        }
        file.seek(SeekFrom::Start(entry.offset - 1))?;
        let mut last = [0];
        file.read_exact(&mut last)?;
        if last[0] != b'\n' {
            return read_file(path, provider, account, None, cancelled);
        }
    }
    file.seek(SeekFrom::Start(entry.offset))?;
    let start = entry.offset;
    let mut reader = BufReader::with_capacity(64 * 1024, file.take(size.saturating_sub(start)));
    let mut bytes = Vec::new();
    loop {
        if cancelled() {
            anyhow::bail!("Usage scan was cancelled");
        }
        let (length, complete, oversized) = line(&mut reader, &mut bytes, cancelled)?;
        if !complete {
            break;
        }
        entry.offset = entry.offset.saturating_add(length as u64);
        if oversized {
            entry.incomplete = true;
            continue;
        }
        let relevant = match provider {
            ImportProvider::Claude => {
                contains(&bytes, b"\"assistant\"") && contains(&bytes, b"\"usage\"")
            }
            ImportProvider::Codex => {
                contains(&bytes, b"\"token_count\"")
                    || contains(&bytes, b"\"turn_context\"")
                    || contains(&bytes, b"\"session_meta\"")
            }
        };
        if !relevant {
            continue;
        }
        let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
            entry.incomplete = true;
            continue;
        };
        let needs_date = match provider {
            ImportProvider::Claude => {
                value["type"] == "assistant"
                    && value["message"]["model"] != "<synthetic>"
                    && value["message"]["usage"].is_object()
            }
            ImportProvider::Codex => {
                value["type"] == "event_msg"
                    && value["payload"]["type"] == "token_count"
                    && value["payload"]["info"]["total_token_usage"].is_object()
            }
        };
        if needs_date && date(&value["timestamp"]).is_none() {
            entry.incomplete = true;
            continue;
        }
        let request = match provider {
            ImportProvider::Claude => claude(&value, account),
            ImportProvider::Codex => entry.codex.consume(&value, account),
        };
        if let Some(request) = request {
            if entry.requests.len() == MAX_EVENTS {
                entry.incomplete = true;
                break;
            }
            entry.requests.push(request);
        }
    }
    let mut file = reader.into_inner().into_inner();
    (entry.head, entry.tail) = edges(&mut file, entry.offset)?;
    entry.size = size;
    entry.modified = modified;
    let read = entry.offset.saturating_sub(start);
    Ok((entry, read))
}

fn linked(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes()
            & windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT
            != 0
        {
            return true;
        }
    }
    metadata.file_type().is_symlink()
}

fn max_tokens(target: &mut TokenTotals, other: &TokenTotals) {
    *target = TokenTotals::new(
        target.input.max(other.input),
        target.cache_read.max(other.cache_read),
        target.cache_write.max(other.cache_write),
        target.cache_write_long.max(other.cache_write_long),
        target.output.max(other.output),
        target.reasoning.max(other.reasoning),
    );
}

impl Scanner {
    pub fn scan(
        &mut self,
        sources: &[Source],
        owners: &SessionOwners,
        cancelled: &dyn Fn() -> bool,
    ) -> anyhow::Result<Scan> {
        let mut result = Scan::default();
        let mut seen = HashSet::new();
        let mut files = HashMap::<&'static str, usize>::new();
        let mut incomplete = HashSet::new();
        let mut visited = 0usize;
        let mut retained = 0usize;
        'sources: for source in sources {
            let provider = provider_name(source.provider);
            for root in &source.roots {
                if cancelled() {
                    anyhow::bail!("Usage scan was cancelled");
                }
                let metadata = match fs::symlink_metadata(root) {
                    Ok(metadata) => metadata,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                    Err(_) => {
                        incomplete.insert(provider);
                        continue;
                    }
                };
                if !metadata.is_dir() || linked(&metadata) {
                    incomplete.insert(provider);
                    continue;
                }
                let mut pending = vec![root.clone()];
                while let Some(directory) = pending.pop() {
                    if cancelled() {
                        anyhow::bail!("Usage scan was cancelled");
                    }
                    let entries = match fs::read_dir(directory) {
                        Ok(entries) => entries,
                        Err(_) => {
                            incomplete.insert(provider);
                            continue;
                        }
                    };
                    for entry in entries {
                        visited += 1;
                        if visited > MAX_VISITED {
                            incomplete.extend(["claude", "codex"]);
                            break 'sources;
                        }
                        let entry = match entry {
                            Ok(entry) => entry,
                            Err(_) => {
                                incomplete.insert(provider);
                                continue;
                            }
                        };
                        if entry.file_name().to_string_lossy().starts_with('.') {
                            continue;
                        }
                        let metadata = match fs::symlink_metadata(entry.path()) {
                            Ok(metadata) => metadata,
                            Err(_) => {
                                incomplete.insert(provider);
                                continue;
                            }
                        };
                        if linked(&metadata) {
                            incomplete.insert(provider);
                            continue;
                        }
                        let path = entry.path();
                        if metadata.is_dir() {
                            pending.push(path);
                            continue;
                        }
                        if !metadata.is_file()
                            || path.extension().is_none_or(|ext| ext != "jsonl")
                            || !seen.insert(path.clone())
                        {
                            continue;
                        }
                        let count = files.entry(provider).or_default();
                        *count += 1;
                        if *count > MAX_FILES {
                            incomplete.extend(["claude", "codex"]);
                            break 'sources;
                        }
                        if self.files.get(&path).is_some_and(|old| {
                            old.provider == source.provider
                                && old.account == source.account_id
                                && old.size == metadata.len()
                                && metadata.modified().ok() == Some(old.modified)
                                && crate::native_file::path_identity(&path).ok()
                                    == Some(old.identity)
                        }) {
                            let old = self.files.get(&path).expect("checked above");
                            retained = retained.saturating_add(old.requests.len());
                            if retained > MAX_EVENTS {
                                incomplete.extend(["claude", "codex"]);
                                break 'sources;
                            }
                            if old.incomplete {
                                incomplete.insert(provider);
                            }
                            continue;
                        }
                        let previous = self.files.remove(&path);
                        match read_file(
                            &path,
                            source.provider,
                            &source.account_id,
                            previous,
                            cancelled,
                        ) {
                            Ok((entry, bytes)) => {
                                retained = retained.saturating_add(entry.requests.len());
                                if retained > MAX_EVENTS {
                                    incomplete.extend(["claude", "codex"]);
                                    break 'sources;
                                }
                                if entry.incomplete {
                                    incomplete.insert(provider);
                                }
                                result.files_read += 1;
                                result.bytes_read = result.bytes_read.saturating_add(bytes);
                                self.files.insert(path, entry);
                            }
                            Err(_) if cancelled() => anyhow::bail!("Usage scan was cancelled"),
                            Err(_) => {
                                incomplete.insert(provider);
                            }
                        }
                    }
                }
            }
        }
        self.files.retain(|path, _| seen.contains(path));
        for provider in ["claude", "codex"] {
            if incomplete.contains(provider) {
                result.incomplete_providers.push(provider);
            } else if files.get(provider).copied().unwrap_or(0) > 0 {
                result.complete_providers.push(provider);
            }
        }
        let mut keyed = HashMap::<[u8; 32], usize>::new();
        for entry in self.files.values().filter(|entry| {
            result
                .complete_providers
                .contains(&provider_name(entry.provider))
        }) {
            for request in &entry.requests {
                let owner = request.session.as_ref().and_then(|session| {
                    owners.get(&(request.event.provider.clone(), session.to_lowercase()))
                });
                if let Some(index) = request.key.and_then(|key| keyed.get(&key).copied()) {
                    let logged: &mut LoggedEvent = &mut result.events[index];
                    max_tokens(&mut logged.event.tokens, &request.event.tokens);
                    logged.event.prompt_tokens =
                        logged.event.prompt_tokens.max(request.event.prompt_tokens);
                    logged.event.date = logged.event.date.min(request.event.date);
                    if logged.event.model.is_none() {
                        logged.event.model = request.event.model.clone();
                    }
                    if let Some(Some(owner)) = owner {
                        logged.event.project_id = owner.project_id.clone();
                        logged.event.account_id = owner.account_id.clone();
                    } else if matches!(owner, Some(None)) {
                        logged.event.project_id = None;
                        logged.event.account_id = "unknown".into();
                    }
                    logged.is_from_coincide |= request.from_coincide || owner.is_some();
                } else {
                    if result.events.len() == MAX_EVENTS {
                        anyhow::bail!("Usage logs contain too many requests");
                    }
                    if let Some(key) = request.key {
                        keyed.insert(key, result.events.len());
                    }
                    let mut event = request.event.clone();
                    if let Some(Some(owner)) = owner {
                        event.project_id = owner.project_id.clone();
                        event.account_id = owner.account_id.clone();
                    } else if matches!(owner, Some(None)) {
                        event.account_id = "unknown".into();
                    }
                    result.events.push(LoggedEvent {
                        event,
                        is_from_coincide: request.from_coincide || owner.is_some(),
                    });
                }
            }
        }
        result.complete_providers.retain(|provider| {
            result
                .events
                .iter()
                .any(|event| event.event.provider == *provider)
        });
        result.events.sort_by(|left, right| {
            left.event
                .date
                .cmp(&right.event.date)
                .then_with(|| left.event.provider.cmp(&right.event.provider))
                .then_with(|| left.event.account_id.cmp(&right.event.account_id))
                .then_with(|| left.event.model.cmp(&right.event.model))
        });
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Write;

    fn source(provider: ImportProvider, root: &Path) -> Source {
        Source {
            provider,
            account_id: "default".into(),
            roots: vec![root.into()],
        }
    }
    fn write(path: &Path, values: &[Value]) {
        let mut file = fs::File::create(path).unwrap();
        for value in values {
            writeln!(file, "{value}").unwrap();
        }
    }
    fn codex_total(timestamp: &str, input: u64, cached: u64, output: u64) -> Value {
        json!({"timestamp":timestamp,"type":"event_msg","payload":{"type":"token_count",
            "info":{"total_token_usage":{"input_tokens":input,"cached_input_tokens":cached,
                "output_tokens":output,"reasoning_output_tokens":output / 2}}}})
    }
    fn claude_line(id: &str, output: u64) -> Value {
        json!({"type":"assistant","timestamp":"2026-11-15T10:00:00Z","requestId":"request-1","sessionId":"CLAUDE-SESSION",
            "secretResponse":"never-retain-this", "message":{"id":id,"model":"claude-sonnet-4-5",
            "usage":{"input_tokens":100,"cache_read_input_tokens":20,"cache_creation_input_tokens":10,
            "output_tokens":output}}})
    }

    #[test]
    fn claude_repeated_content_and_copied_responses_count_once() {
        let dir = tempfile::tempdir().unwrap();
        write(
            &dir.path().join("one.jsonl"),
            &[claude_line("answer", 5), claude_line("answer", 15)],
        );
        write(&dir.path().join("copy.jsonl"), &[claude_line("answer", 10)]);
        let mut scanner = Scanner::default();
        let owners = SessionOwners::from([(
            ("claude".into(), "claude-session".into()),
            Some(SessionOwner {
                project_id: Some("project".into()),
                account_id: "work".into(),
            }),
        )]);
        let scan = scanner
            .scan(
                &[source(ImportProvider::Claude, dir.path())],
                &owners,
                &|| false,
            )
            .unwrap();
        assert_eq!(scan.complete_providers, vec!["claude"]);
        assert_eq!(scan.events.len(), 1);
        assert_eq!(
            scan.events[0].event.tokens,
            TokenTotals::new(100, 20, 10, 0, 15, 0)
        );
        assert_eq!(scan.events[0].event.prompt_tokens, 130);
        assert!(scan.events[0].is_from_coincide);
        assert_eq!(scan.events[0].event.project_id.as_deref(), Some("project"));
        assert_eq!(scan.events[0].event.account_id, "work");
        assert!(!format!("{scan:?}").contains("never-retain-this"));
    }

    #[test]
    fn codex_deltas_skip_repeated_totals_and_parent_history() {
        let dir = tempfile::tempdir().unwrap();
        let metadata = json!({"type":"session_meta","timestamp":"2026-11-15T10:00:00Z",
            "payload":{"id":"session","originator":"coincide","forked_from_id":"parent"}});
        let model = json!({"type":"turn_context","payload":{"model":"gpt-fixture"}});
        write(
            &dir.path().join("rollout.jsonl"),
            &[
                metadata,
                model,
                codex_total("2026-11-15T09:00:00Z", 500, 300, 50),
                codex_total("2026-11-15T10:00:10Z", 600, 360, 60),
                codex_total("2026-11-15T10:00:20Z", 600, 360, 60),
                json!({"timestamp":"2026-11-15T10:00:30Z","type":"event_msg","payload":{"type":"token_count",
                "info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":3,"output_tokens":2},
                    "last_token_usage":{"input_tokens":8,"cached_input_tokens":2,"output_tokens":1}}}}),
            ],
        );
        let scan = Scanner::default()
            .scan(
                &[source(ImportProvider::Codex, dir.path())],
                &SessionOwners::new(),
                &|| false,
            )
            .unwrap();
        assert_eq!(scan.complete_providers, vec!["codex"]);
        assert_eq!(scan.events.len(), 2);
        assert_eq!(
            scan.events[0].event.tokens,
            TokenTotals::new(40, 60, 0, 0, 10, 5)
        );
        assert_eq!(
            scan.events[1].event.tokens,
            TokenTotals::new(6, 2, 0, 0, 1, 0)
        );
        assert_eq!(scan.events[0].event.model.as_deref(), Some("gpt-fixture"));
        assert!(scan.events.iter().all(|event| event.is_from_coincide));
    }

    #[test]
    fn owner_lookup_reads_only_session_fields_and_handles_swift_and_native_shapes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.sqlite");
        let db = rusqlite::Connection::open(&path).unwrap();
        db.execute_batch("CREATE TABLE threads(id TEXT, document TEXT)")
            .unwrap();
        for (id, document) in [
            (
                "one",
                json!({"projectID":"project-one", "items":[{"text":"do-not-retain"}],
                "sessions":{"codex":{"sessionID":"CODEX-ID","accountID":"work"}},
                "accountSessions":{"claude/other":{"sessionID":"CLAUDE-ID"}}}),
            ),
            (
                "two",
                json!({"projectID":"project-two", "sessions":["claude",{"sessionID":"array-id"}],
                "importedSession":{"provider":"codex","sessionID":"imported-id"}}),
            ),
            (
                "three",
                json!({"projectID":"different", "sessions":{"codex":{"sessionID":"codex-id"}}}),
            ),
        ] {
            db.execute(
                "INSERT INTO threads(id,document) VALUES (?1,?2)",
                rusqlite::params![id, document.to_string()],
            )
            .unwrap();
        }
        drop(db);
        let owners = session_owners(&path.canonicalize().unwrap(), &|| false).unwrap();
        assert_eq!(
            owners.get(&("codex".into(), "codex-id".into())),
            Some(&None)
        );
        assert_eq!(
            owners
                .get(&("claude".into(), "claude-id".into()))
                .unwrap()
                .as_ref()
                .unwrap()
                .account_id,
            "other"
        );
        assert_eq!(
            owners
                .get(&("claude".into(), "array-id".into()))
                .unwrap()
                .as_ref()
                .unwrap()
                .project_id
                .as_deref(),
            Some("project-two")
        );
        assert!(owners.contains_key(&("codex".into(), "imported-id".into())));
        assert!(!format!("{owners:?}").contains("do-not-retain"));
    }

    #[test]
    fn incremental_scan_retries_partial_lines_and_detects_rewrites() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("one.jsonl");
        let first = format!("{}\n", claude_line("one", 2));
        let second = format!("{}\n", claude_line("two", 3));
        fs::write(&path, format!("{first}{}", &second[..second.len() / 2])).unwrap();
        let sources = [source(ImportProvider::Claude, dir.path())];
        let mut scanner = Scanner::default();
        assert_eq!(
            scanner
                .scan(&sources, &SessionOwners::new(), &|| false)
                .unwrap()
                .events
                .len(),
            1
        );
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(&second.as_bytes()[second.len() / 2..])
            .unwrap();
        let next = scanner
            .scan(&sources, &SessionOwners::new(), &|| false)
            .unwrap();
        assert_eq!(next.events.len(), 2);
        assert!(next.bytes_read < (first.len() + second.len()) as u64);
        let cached = scanner
            .scan(&sources, &SessionOwners::new(), &|| false)
            .unwrap();
        assert_eq!(cached.files_read, 0);
        write(&path, &[claude_line("replacement", 7)]);
        let rewritten = scanner
            .scan(&sources, &SessionOwners::new(), &|| false)
            .unwrap();
        assert_eq!(rewritten.events.len(), 1);
        assert_eq!(rewritten.events[0].event.tokens.output, 7);
    }

    #[test]
    fn growing_rewritten_file_does_not_keep_the_old_prefix() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("one.jsonl");
        write(&path, &[claude_line("old", 2)]);
        let sources = [source(ImportProvider::Claude, dir.path())];
        let mut scanner = Scanner::default();
        assert_eq!(
            scanner
                .scan(&sources, &SessionOwners::new(), &|| false)
                .unwrap()
                .events
                .len(),
            1
        );
        // The first replacement line has the same length and ends exactly at
        // the former offset, so a newline-only check would accept stale data.
        write(&path, &[claude_line("new", 7), claude_line("next", 9)]);
        let scan = scanner
            .scan(&sources, &SessionOwners::new(), &|| false)
            .unwrap();
        assert_eq!(scan.events.len(), 2);
        assert_eq!(
            scan.events
                .iter()
                .map(|e| e.event.tokens.output)
                .sum::<u64>(),
            16
        );
    }

    #[test]
    fn corrupt_usage_line_does_not_replace_saved_provider_data() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(
            dir.path().join("bad.jsonl"),
            b"{\"type\":\"assistant\",\"usage\":\n",
        )
        .unwrap();
        let scan = Scanner::default()
            .scan(
                &[source(ImportProvider::Claude, dir.path())],
                &SessionOwners::new(),
                &|| false,
            )
            .unwrap();
        assert_eq!(scan.incomplete_providers, vec!["claude"]);
        assert!(scan.complete_providers.is_empty());
        assert!(scan.events.is_empty());
    }

    #[test]
    fn oversized_logs_and_cancellation_never_claim_complete_usage() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("one.jsonl");
        let mut bytes = vec![b'x'; MAX_LINE + 1];
        bytes.push(b'\n');
        fs::write(&path, bytes).unwrap();
        let sources = [source(ImportProvider::Claude, dir.path())];
        let mut scanner = Scanner::default();
        let scan = scanner
            .scan(&sources, &SessionOwners::new(), &|| false)
            .unwrap();
        assert_eq!(scan.incomplete_providers, vec!["claude"]);
        assert!(scan.complete_providers.is_empty());
        assert!(
            scanner
                .scan(&sources, &SessionOwners::new(), &|| true)
                .is_err()
        );
    }

    #[cfg(windows)]
    #[test]
    fn database_handle_prevents_replacement_until_the_read_finishes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("usage.sqlite");
        let moved = dir.path().join("moved.sqlite");
        fs::write(&path, b"fixture").unwrap();
        let held = open_usage_database(&path).unwrap();
        assert!(fs::rename(&path, &moved).is_err());
        drop(held);
        fs::rename(&path, &moved).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_log_files_are_not_read() {
        let dir = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        write(
            &outside.path().join("outside.jsonl"),
            &[claude_line("outside", 5)],
        );
        std::os::unix::fs::symlink(
            outside.path().join("outside.jsonl"),
            dir.path().join("link.jsonl"),
        )
        .unwrap();
        let scan = Scanner::default()
            .scan(
                &[source(ImportProvider::Claude, dir.path())],
                &SessionOwners::new(),
                &|| false,
            )
            .unwrap();
        assert!(scan.events.is_empty());
        assert!(scan.complete_providers.is_empty());
        assert_eq!(scan.incomplete_providers, vec!["claude"]);
    }
}
