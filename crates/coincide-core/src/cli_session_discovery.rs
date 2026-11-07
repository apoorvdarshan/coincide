//! Lists Claude Code and Codex session files in the CLIs' own history roots for
//! the Import CLI Session sheet, like Swift's `CLISessionScanner`. Read-only: it
//! never imports, writes, or follows symlinks or reparse points. Each listed file
//! is read again through the secure import path when the user previews it.
use crate::cli_session_import::ImportProvider;
use serde_json::{Value, json};
use std::{
    ffi::OsString,
    fs,
    io::Read,
    path::{Path, PathBuf},
    time::SystemTime,
};

/// Bounds the walk, so large or custom CLI roots cannot stall the sheet.
pub const MAX_VISITED: usize = 20_000;
pub const MAX_CANDIDATES: usize = 2_000;
const HEAD_BYTES: u64 = 128 * 1024;
const HEAD_RECORDS: usize = 100;
const TITLE_CHARS: usize = 100;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub path: PathBuf,
    pub provider: ImportProvider,
    pub title: String,
    pub directory: String,
    pub modified: SystemTime,
}

#[derive(Debug, Default)]
pub struct Scan {
    pub candidates: Vec<Candidate>,
    /// Some entries could not be read, or a limit was reached.
    pub incomplete: bool,
}

pub fn provider_name(provider: ImportProvider) -> &'static str {
    match provider {
        ImportProvider::Codex => "codex",
        ImportProvider::Claude => "claude",
    }
}

/// `CLAUDE_CONFIG_DIR`/projects, and `CODEX_HOME`/sessions and archived_sessions,
/// falling back to `~/.claude` and `~/.codex` as the CLIs do.
pub fn default_roots(
    variable: impl Fn(&str) -> Option<OsString>,
    home: Option<PathBuf>,
) -> Vec<(ImportProvider, PathBuf)> {
    let base = |name: &str, folder: &str| {
        variable(name)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .or_else(|| home.as_ref().map(|home| home.join(folder)))
    };
    let mut roots = Vec::new();
    if let Some(claude) = base("CLAUDE_CONFIG_DIR", ".claude") {
        roots.push((ImportProvider::Claude, claude.join("projects")));
    }
    if let Some(codex) = base("CODEX_HOME", ".codex") {
        roots.push((ImportProvider::Codex, codex.join("sessions")));
        roots.push((ImportProvider::Codex, codex.join("archived_sessions")));
    }
    roots
}

pub fn home_directory() -> Option<PathBuf> {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

pub fn scan_default(cancelled: &dyn Fn() -> bool) -> Scan {
    scan(
        &default_roots(|name| std::env::var_os(name), home_directory()),
        MAX_CANDIDATES,
        cancelled,
    )
}

/// Newest first. Hidden files, symlinks, reparse points and `subagents` folders
/// are skipped; unreadable entries mark the scan incomplete.
pub fn scan(
    roots: &[(ImportProvider, PathBuf)],
    limit: usize,
    cancelled: &dyn Fn() -> bool,
) -> Scan {
    let mut found = Vec::new();
    let mut incomplete = false;
    let mut visited = 0;
    'roots: for (provider, root) in roots {
        let Ok(metadata) = fs::symlink_metadata(root) else {
            continue;
        };
        if linked(&metadata) || !metadata.is_dir() {
            incomplete = true;
            continue;
        }
        let mut pending = vec![root.clone()];
        while let Some(directory) = pending.pop() {
            if cancelled() {
                return Scan::default();
            }
            let Ok(entries) = fs::read_dir(&directory) else {
                incomplete = true;
                continue;
            };
            for entry in entries {
                visited += 1;
                if visited > MAX_VISITED {
                    incomplete = true;
                    break 'roots;
                }
                let Ok(entry) = entry else {
                    incomplete = true;
                    continue;
                };
                let name = entry.file_name();
                if name.to_string_lossy().starts_with('.') {
                    continue;
                }
                let Ok(metadata) = entry.metadata() else {
                    incomplete = true;
                    continue;
                };
                if linked(&metadata) || name == "subagents" {
                    continue;
                }
                let path = entry.path();
                if metadata.is_dir() {
                    pending.push(path);
                } else if metadata.is_file()
                    && path
                        .extension()
                        .is_some_and(|extension| extension == "jsonl")
                {
                    let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
                    found.push((path, *provider, modified));
                }
            }
        }
    }
    found.sort_by(|a, b| b.2.cmp(&a.2).then_with(|| a.0.cmp(&b.0)));
    if found.len() > limit {
        incomplete = true;
        found.truncate(limit);
    }
    let mut candidates = Vec::with_capacity(found.len());
    for (path, provider, modified) in found {
        if cancelled() {
            return Scan::default();
        }
        match head(&path) {
            Ok(bytes) => {
                let (title, directory) = summary(provider, &bytes);
                let title = title.unwrap_or_else(|| {
                    path.file_stem()
                        .map(|stem| stem.to_string_lossy().into_owned())
                        .unwrap_or_default()
                });
                candidates.push(Candidate {
                    title: title.chars().take(TITLE_CHARS).collect(),
                    path,
                    provider,
                    directory,
                    modified,
                });
            }
            Err(_) => incomplete = true,
        }
    }
    Scan {
        candidates,
        incomplete,
    }
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

fn head(path: &Path) -> anyhow::Result<Vec<u8>> {
    let file = crate::native_file::open_regular(path, false)?;
    let mut bytes = Vec::new();
    file.take(HEAD_BYTES).read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// The title and working directory Swift shows for a session: Claude's
/// `aiTitle` or first real prompt, or Codex's first user message.
pub fn summary(provider: ImportProvider, bytes: &[u8]) -> (Option<String>, String) {
    let mut title = None;
    let mut directory = String::new();
    for line in bytes.split(|byte| *byte == b'\n').take(HEAD_RECORDS) {
        let Ok(record) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        match provider {
            ImportProvider::Claude => {
                if let Some(cwd) = record["cwd"].as_str() {
                    directory = cwd.to_owned();
                }
                if let Some(ai) = record["aiTitle"].as_str() {
                    title = Some(ai.to_owned());
                }
                if title.is_none() && record["type"] == "user" && record["isMeta"] != true {
                    title = prompt(&record["message"]["content"]);
                }
            }
            ImportProvider::Codex => {
                let payload = &record["payload"];
                if !payload.is_object() {
                    continue;
                }
                if record["type"] == "session_meta"
                    && let Some(cwd) = payload["cwd"].as_str()
                {
                    directory = cwd.to_owned();
                }
                if title.is_none() && record["type"] == "response_item" && payload["role"] == "user"
                {
                    title = prompt(&payload["content"]);
                }
            }
        }
    }
    (title, directory)
}

fn prompt(content: &Value) -> Option<String> {
    let text = match content {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(|part| part["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n"),
        _ => return None,
    };
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

/// Swift's sheet search: title, directory and provider name, case-insensitive.
pub fn matches(candidate: &Candidate, query: &str) -> bool {
    let query = query.trim().to_lowercase();
    query.is_empty()
        || format!(
            "{} {} {}",
            candidate.title,
            candidate.directory,
            display_name(candidate.provider)
        )
        .to_lowercase()
        .contains(&query)
}

pub fn display_name(provider: ImportProvider) -> &'static str {
    match provider {
        ImportProvider::Codex => "Codex",
        ImportProvider::Claude => "Claude Code",
    }
}

pub fn candidate_json(candidate: &Candidate) -> Value {
    let modified = chrono::DateTime::<chrono::Utc>::from(candidate.modified).to_rfc3339();
    json!({"path":candidate.path.to_string_lossy(),"provider":provider_name(candidate.provider),
        "title":candidate.title,"directory":candidate.directory,"modifiedAt":modified})
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn write(path: &Path, records: &[Value], age: u64) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let text = records
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n");
        fs::write(path, text).unwrap();
        let time = SystemTime::now() - Duration::from_secs(age);
        fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(time)
            .unwrap();
    }

    #[test]
    fn roots_follow_cli_environment_overrides_and_home() {
        let home = PathBuf::from("/home/fixture");
        let roots = default_roots(|_| None, Some(home.clone()));
        assert_eq!(
            roots,
            vec![
                (ImportProvider::Claude, home.join(".claude/projects")),
                (ImportProvider::Codex, home.join(".codex/sessions")),
                (ImportProvider::Codex, home.join(".codex/archived_sessions")),
            ]
        );
        let roots = default_roots(
            |name| (name == "CODEX_HOME").then(|| OsString::from("/custom/codex")),
            None,
        );
        assert_eq!(
            roots,
            vec![
                (
                    ImportProvider::Codex,
                    PathBuf::from("/custom/codex/sessions")
                ),
                (
                    ImportProvider::Codex,
                    PathBuf::from("/custom/codex/archived_sessions")
                ),
            ]
        );
    }

    #[test]
    fn scan_lists_newest_first_and_skips_hidden_subagents_and_other_files() {
        let dir = tempfile::tempdir().unwrap();
        let claude = dir.path().join("claude");
        let codex = dir.path().join("codex");
        write(
            &claude.join("project/one.jsonl"),
            &[
                json!({"type":"user","isMeta":true,"cwd":"/work/app","message":{"content":"meta"}}),
                json!({"type":"user","cwd":"/work/app","message":{"content":[{"type":"text","text":"  Fix the login  "}]}}),
            ],
            300,
        );
        write(
            &claude.join("project/titled.jsonl"),
            &[
                json!({"type":"user","cwd":"/work/titled","message":{"content":"first prompt"}}),
                json!({"aiTitle":"Generated title"}),
            ],
            200,
        );
        write(
            &claude.join("project/subagents/agent.jsonl"),
            &[json!({"cwd":"/x"})],
            1,
        );
        write(&claude.join(".hidden/secret.jsonl"), &[json!({})], 1);
        write(&claude.join("project/notes.txt"), &[json!({})], 1);
        write(
            &codex.join("2026/11/rollout.jsonl"),
            &[
                json!({"type":"session_meta","payload":{"cwd":"/work/codex"}}),
                json!({"type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"Codex question"}]}}),
            ],
            100,
        );
        write(&codex.join("empty.jsonl"), &[], 400);
        let scan = scan(
            &[
                (ImportProvider::Claude, claude),
                (ImportProvider::Codex, codex),
                (ImportProvider::Codex, dir.path().join("missing")),
            ],
            10,
            &|| false,
        );
        assert!(!scan.incomplete);
        let rows = scan
            .candidates
            .iter()
            .map(|c| (c.title.as_str(), c.directory.as_str(), c.provider))
            .collect::<Vec<_>>();
        assert_eq!(
            rows,
            vec![
                ("Codex question", "/work/codex", ImportProvider::Codex),
                ("Generated title", "/work/titled", ImportProvider::Claude),
                ("Fix the login", "/work/app", ImportProvider::Claude),
                ("empty", "", ImportProvider::Codex),
            ]
        );
    }

    #[test]
    fn scan_limit_marks_incomplete_and_cancellation_returns_nothing() {
        let dir = tempfile::tempdir().unwrap();
        for index in 0..3 {
            write(
                &dir.path().join(format!("{index}.jsonl")),
                &[json!({"cwd":"/w"})],
                index,
            );
        }
        let roots = [(ImportProvider::Claude, dir.path().to_path_buf())];
        let limited = scan(&roots, 2, &|| false);
        assert!(limited.incomplete);
        assert_eq!(limited.candidates.len(), 2);
        assert_eq!(limited.candidates[0].title, "0");
        let cancelled = scan(&roots, 10, &|| true);
        assert!(cancelled.candidates.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn scan_never_follows_symlinked_roots_files_or_folders() {
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let outside = dir.path().join("outside");
        write(&outside.join("secret.jsonl"), &[json!({"cwd":"/x"})], 1);
        let root = dir.path().join("root");
        fs::create_dir(&root).unwrap();
        symlink(&outside, root.join("folder")).unwrap();
        symlink(outside.join("secret.jsonl"), root.join("file.jsonl")).unwrap();
        symlink(&outside, dir.path().join("linked-root")).unwrap();
        let listed = scan(&[(ImportProvider::Claude, root)], 10, &|| false);
        assert!(listed.candidates.is_empty());
        let linked = scan(
            &[(ImportProvider::Claude, dir.path().join("linked-root"))],
            10,
            &|| false,
        );
        assert!(linked.candidates.is_empty() && linked.incomplete);
    }

    #[test]
    fn search_matches_title_directory_and_provider_name() {
        let candidate = Candidate {
            path: PathBuf::from("/s.jsonl"),
            provider: ImportProvider::Claude,
            title: "Fix Login".into(),
            directory: "/work/app".into(),
            modified: SystemTime::UNIX_EPOCH,
        };
        for query in ["", "fix login", "WORK/APP", "claude code", "  login "] {
            assert!(matches(&candidate, query), "{query}");
        }
        assert!(!matches(&candidate, "codex"));
    }
}
