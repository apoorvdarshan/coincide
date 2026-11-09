//! Explicit CLI-session capture. Parent API registers `preview` and `import`.
//! Captures source bytes into Store; never resumes a source provider session.
use crate::{
    cli_session_import::{
        ImportProvider, MAX_BYTES, SessionPreview, detect_provider, preview_claude, preview_codex,
    },
    store::{Store, swift_timestamp},
};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{fs::File, io::Read, path::Path};
use uuid::Uuid;

fn required<'a>(params: &'a Value, field: &str) -> Result<&'a str> {
    params[field]
        .as_str()
        .filter(|s| !s.is_empty())
        .with_context(|| format!("Missing {field}"))
}

// Resolve each component relative to an already-open directory descriptor. A
// renamed parent or symlink swap cannot redirect a later open through a link.
#[cfg(unix)]
fn open_source(path: &Path) -> Result<File> {
    use std::{
        ffi::CString,
        os::{
            fd::{AsRawFd, FromRawFd},
            unix::ffi::OsStrExt,
        },
        path::Component,
    };
    ensure!(path.is_absolute(), "Source path must be absolute");
    let parts = path.components().collect::<Vec<_>>();
    ensure!(parts.len() > 1, "Source path must name a file");
    let mut directory = File::open("/")?;
    for (index, part) in parts.iter().enumerate().skip(1) {
        let Component::Normal(name) = part else {
            anyhow::bail!("Source path must not contain traversal")
        };
        let name = CString::new(name.as_bytes())?;
        let last = index == parts.len() - 1;
        let flags = libc::O_RDONLY
            | libc::O_CLOEXEC
            | libc::O_NOFOLLOW
            | libc::O_NONBLOCK
            | if last { 0 } else { libc::O_DIRECTORY };
        // SAFETY: valid directory FD and NUL-terminated component; ownership of
        // a successful returned descriptor is immediately transferred to File.
        let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let next = unsafe { File::from_raw_fd(fd) };
        if last {
            return Ok(next);
        }
        directory = next;
    }
    anyhow::bail!("Missing source file")
}
// Windows has no openat. Each ancestor directory is opened as a handle that
// denies delete sharing, so while the file is opened none of them can be renamed
// or replaced by a junction; a reparse point anywhere on the path is refused.
#[cfg(windows)]
fn open_source(path: &Path) -> Result<File> {
    use std::{
        fs::OpenOptions,
        os::windows::fs::{MetadataExt, OpenOptionsExt},
        path::{Component, PathBuf},
    };
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
        FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    };
    ensure!(path.is_absolute(), "Source path must be absolute");
    let parts = path.components().collect::<Vec<_>>();
    let mut current = PathBuf::new();
    let mut held = Vec::new();
    for (index, part) in parts.iter().enumerate() {
        let name = match part {
            Component::Prefix(_) | Component::RootDir if held.is_empty() => {
                current.push(part.as_os_str());
                continue;
            }
            Component::Normal(name) => name,
            _ => anyhow::bail!("Source path must not contain traversal"),
        };
        current.push(name);
        let last = index == parts.len() - 1;
        // Read access makes the share mode binding; attribute-only opens are
        // exempt from sharing checks and would not pin the directory.
        let file = OpenOptions::new()
            .read(true)
            .share_mode(
                FILE_SHARE_READ | FILE_SHARE_WRITE | if last { FILE_SHARE_DELETE } else { 0 },
            )
            .custom_flags(
                FILE_FLAG_OPEN_REPARSE_POINT | if last { 0 } else { FILE_FLAG_BACKUP_SEMANTICS },
            )
            .open(&current)?;
        let metadata = file.metadata()?;
        ensure!(
            metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0,
            "Source path must not contain links"
        );
        if last {
            ensure!(metadata.is_file(), "Source must be a regular file");
            return Ok(file);
        }
        ensure!(metadata.is_dir(), "Source path must name a file");
        held.push(file);
    }
    anyhow::bail!("Source path must name a file")
}
#[cfg(not(any(unix, windows)))]
fn open_source(_path: &Path) -> Result<File> {
    anyhow::bail!(
        "CLI-session file import requires secure relative-handle opening; this platform is not supported yet"
    )
}

fn read_source(path: &Path) -> Result<Vec<u8>> {
    let file = open_source(path)?;
    let before = file.metadata()?;
    ensure!(before.is_file(), "Source must be a regular file");
    ensure!(
        before.len() <= MAX_BYTES as u64,
        "Source exceeds import limit"
    );
    let mut bytes = Vec::new();
    let mut reader = file.take(MAX_BYTES as u64 + 1);
    reader.read_to_end(&mut bytes)?;
    ensure!(
        !bytes.is_empty() && bytes.len() <= MAX_BYTES,
        "Empty or oversized source"
    );
    let after = reader.get_ref().metadata()?;
    ensure!(
        before.len() == after.len()
            && after.len() == bytes.len() as u64
            && before.modified()? == after.modified()?,
        "Source changed during capture"
    );
    Ok(bytes)
}
fn fingerprint(bytes: &[u8]) -> String {
    crate::digest_hex::lower_hex(Sha256::digest(bytes))
}
/// `auto` detects the format as Swift does, for a file the user chose directly.
fn parse(provider: &str, bytes: &[u8]) -> Result<SessionPreview> {
    let provider = match provider {
        "auto" => provider_name(detect_provider(bytes)?),
        provider => provider,
    };
    match provider {
        "codex" => preview_codex(bytes),
        "claude" => preview_claude(bytes),
        _ => anyhow::bail!("Import supports codex or claude text sessions"),
    }
}
fn provider_name(provider: ImportProvider) -> &'static str {
    match provider {
        ImportProvider::Codex => "codex",
        ImportProvider::Claude => "claude",
    }
}
fn source_key(preview: &SessionPreview) -> String {
    format!(
        "ImportedSessions/{}/{}.jsonl",
        provider_name(preview.provider),
        preview.session_id
    )
}
fn title(preview: &SessionPreview) -> String {
    preview
        .messages
        .iter()
        .find(|m| m.role == "user")
        .or_else(|| preview.messages.first())
        .map(|m| m.text.trim().chars().take(100).collect())
        .unwrap_or_else(|| "Imported conversation".into())
}

/// Params: absolute `path` (no symlinks in any component), `provider` (`codex`,
/// `claude` or `auto`). The fingerprint is a source-change guard, not an
/// authorization credential. `existingThreadId` names an earlier import of the
/// same session, which the sheet opens instead of importing again.
pub fn preview(store: &Store, params: &Value) -> Result<Value> {
    let bytes = read_source(Path::new(required(params, "path")?))?;
    let parsed = parse(required(params, "provider")?, &bytes)?;
    let existing = store.imported_thread_for_source(&source_key(&parsed))?;
    Ok(
        json!({"provider":provider_name(parsed.provider),"sessionId":parsed.session_id.to_string(),
        "existingThreadId":existing,
        // Imported CLI sessions continue their provider session in the new thread.
        "continuesSession":true,
        "sourceKey":source_key(&parsed),"sha256":fingerprint(&bytes),"bytes":bytes.len(),
        "title":title(&parsed),"directory":parsed.directory,"model":parsed.model,
        "messageCount":parsed.messages.len(),"omittedRecords":parsed.omitted_records,
        "shortenedText":parsed.shortened_text,"executable":false,
        "messages":parsed.messages.iter().take(20).map(|m| json!({"role":m.role,"text":m.text})).collect::<Vec<_>>() }),
    )
}

/// Params: preview's `path`, `provider`, `sha256`, and optional `projectId`.
/// Rereads immediately before the Store transaction; duplicates never overwrite.
/// Parent increments engine revision only after this returns successfully.
pub fn import(store: &mut Store, params: &Value) -> Result<Value> {
    let expected = required(params, "sha256")?;
    ensure!(
        expected.len() == 64 && expected.bytes().all(|b| b.is_ascii_hexdigit()),
        "Invalid preview fingerprint"
    );
    let bytes = read_source(Path::new(required(params, "path")?))?;
    ensure!(
        fingerprint(&bytes) == expected,
        "Source changed after preview; preview it again"
    );
    let parsed = parse(required(params, "provider")?, &bytes)?;
    ensure!(
        params["projectId"].is_null() || params["projectId"].is_string(),
        "projectId must be a UUID string"
    );
    let project = params["projectId"]
        .as_str()
        .unwrap_or("00000000-0000-0000-0000-000000000000");
    let project = Uuid::parse_str(project)?.to_string().to_uppercase();
    if project != "00000000-0000-0000-0000-000000000000" {
        ensure!(
            store
                .projects()?
                .as_array()
                .is_some_and(|projects| projects.iter().any(|p| p["id"]
                    .as_str()
                    .is_some_and(|id| id.eq_ignore_ascii_case(&project)))),
            "Project not found"
        );
    }
    let provider = provider_name(parsed.provider);
    let source_key = source_key(&parsed);
    // A second import opens the conversation that already holds this source.
    if let Some(existing) = store.imported_thread_for_source(&source_key)? {
        return Ok(
            json!({"threadId":existing,"sourceKey":source_key,"existing":true,
            "messageCount":parsed.messages.len(),"omittedRecords":parsed.omitted_records,
            "shortenedText":parsed.shortened_text,"executable":false}),
        );
    }
    let id = Uuid::new_v4().to_string().to_uppercase();
    let now = swift_timestamp();
    let items = parsed.messages.iter().map(|message| json!({
        "id":Uuid::new_v4().to_string().to_uppercase(),"kind":message.role,"text":message.text,
        "provider":provider,"createdAt":now,"completedAt":now,"status":"completed",
        "importedTimestamp":message.timestamp,"externalID":message.external_id
    })).collect::<Vec<_>>();
    let document = json!({"id":id,"projectID":project,"title":title(&parsed),
        "createdAt":now,"updatedAt":now,"items":items,"sessions":{},"draft":"",
        "selection":{"provider":provider,"modelID":parsed.model.as_deref().unwrap_or("default")},
        "accessMode":"approval","interactionMode":"build","isPinned":false,"isArchived":false,
        "importedSession":{"sourceKey":source_key,"sha256":expected,"provider":provider,
            "sessionID":parsed.session_id.to_string(),"directory":parsed.directory,
            // The exact file the user chose, so File › Reveal Imported Source
            // can show it, like Swift's importedSourceURL.
            "path":Path::new(required(params, "path")?).to_string_lossy().into_owned(),
            "omittedRecords":parsed.omitted_records,"shortenedText":parsed.shortened_text}});
    store.import_cli_session(&document, &source_key, &bytes)?;
    Ok(
        json!({"threadId":id,"sourceKey":source_key,"messageCount":parsed.messages.len(),
        "omittedRecords":parsed.omitted_records,"shortenedText":parsed.shortened_text,"executable":false}),
    )
}

#[cfg(all(test, any(unix, windows)))]
mod tests {
    use super::*;
    use std::fs;
    const SESSION: &str = "00000000-0000-4000-8000-000000000001";
    fn fixture(provider: &str) -> Vec<u8> {
        let records = if provider == "codex" {
            vec![
                json!({"type":"session_meta","payload":{"id":SESSION,"cwd":"/synthetic","unknown":{"preserve":true}}}),
                json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fixture unique question"}]}}),
            ]
        } else {
            vec![
                json!({"sessionId":SESSION,"cwd":"/synthetic","uuid":"one","parentUuid":null,
            "type":"user","message":{"role":"user","content":"fixture unique question"},"unknown":{"preserve":true}}),
            ]
        };
        records
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n")
            .into_bytes()
    }
    /// macOS temporary folders sit behind a /var symlink, which import refuses.
    /// Windows canonical paths are verbatim (`\\?\`), so keep the plain one there.
    fn root(dir: &tempfile::TempDir) -> std::path::PathBuf {
        if cfg!(windows) {
            dir.path().to_path_buf()
        } else {
            dir.path().canonicalize().unwrap()
        }
    }
    fn setup(provider: &str) -> (tempfile::TempDir, std::path::PathBuf, Store, Value, Vec<u8>) {
        let dir = tempfile::tempdir().unwrap();
        let root = root(&dir);
        let path = root.join("source.jsonl");
        let bytes = fixture(provider);
        fs::write(&path, &bytes).unwrap();
        let store = Store::open(&root.join("rust/state.sqlite")).unwrap();
        let mut params = json!({"provider":provider,"path":path.to_str().unwrap()});
        params["sha256"] = preview(&store, &params).unwrap()["sha256"].clone();
        (dir, path, store, params, bytes)
    }
    #[test]
    fn persisted_import_preserves_source_and_is_non_executable_after_restart() {
        for provider in ["codex", "claude"] {
            let (dir, path, mut store, params, bytes) = setup(provider);
            assert!(store.summaries("", true).unwrap().is_empty());
            let result = import(&mut store, &params).unwrap();
            let id = result["threadId"].as_str().unwrap();
            let source = result["sourceKey"].as_str().unwrap();
            assert!(store.is_imported(id).unwrap());
            assert_eq!(store.original(source).unwrap().unwrap(), bytes);
            assert_eq!(fs::read(path).unwrap(), bytes);
            assert!(
                store.thread(id).unwrap()["sessions"]
                    .as_object()
                    .unwrap()
                    .is_empty()
            );
            assert_eq!(store.summaries("unique", true).unwrap().len(), 1);
            drop(store);
            let store = Store::open(&dir.path().join("rust/state.sqlite")).unwrap();
            assert!(store.is_imported(id).unwrap());
            let mut engine = crate::api::Engine::new(store);
            let response = engine.dispatch(json!({"id":"test","method":"agent.send","params":{"threadId":id,"text":"must not execute"}}));
            assert!(
                response["error"]["message"]
                    .as_str()
                    .is_some_and(|message| message.contains("read-only")),
                "{response}"
            );
        }
    }
    #[test]
    fn changed_source_and_duplicate_import_leave_no_partial_thread() {
        let (_dir, path, mut store, params, bytes) = setup("codex");
        fs::write(&path, b"changed").unwrap();
        assert!(import(&mut store, &params).is_err());
        assert!(store.summaries("", true).unwrap().is_empty());
        assert!(
            store
                .original(&format!("ImportedSessions/codex/{SESSION}.jsonl"))
                .unwrap()
                .is_none()
        );
        fs::write(&path, bytes).unwrap();
        let imported = import(&mut store, &params).unwrap();
        // A repeat import opens the thread that already holds the source.
        let again = import(&mut store, &params).unwrap();
        assert_eq!(again["existing"], true);
        assert_eq!(again["threadId"], imported["threadId"]);
        assert_eq!(store.summaries("", true).unwrap().len(), 1);
        assert!(
            store
                .is_imported(imported["threadId"].as_str().unwrap())
                .unwrap()
        );
    }
    #[test]
    fn auto_detection_and_existing_import_lookup() {
        for provider in ["codex", "claude"] {
            let (_dir, _path, mut store, params, _bytes) = setup(provider);
            let mut auto = params.clone();
            auto["provider"] = json!("auto");
            let first = preview(&store, &auto).unwrap();
            assert_eq!(first["provider"], provider);
            assert!(first["existingThreadId"].is_null());
            let imported = import(&mut store, &params).unwrap();
            assert_eq!(
                preview(&store, &auto).unwrap()["existingThreadId"],
                imported["threadId"]
            );
        }
        let ambiguous = [
            json!({"type":"session_meta","payload":{}}),
            json!({"sessionId":SESSION,"cwd":"/synthetic"}),
        ]
        .iter()
        .map(Value::to_string)
        .collect::<Vec<_>>()
        .join("\n");
        assert!(detect_provider(ambiguous.as_bytes()).is_err());
        assert!(detect_provider(b"{}").is_err());
    }
    #[cfg(unix)]
    #[test]
    fn rejects_symlink_sources_parent_links_and_oversized_files() {
        use std::os::unix::fs::symlink;
        let (dir, path, store, params, _bytes) = setup("codex");
        let root = dir.path().canonicalize().unwrap();
        let link = root.join("link.jsonl");
        symlink(&path, &link).unwrap();
        let mut p = params.clone();
        p["path"] = json!(link.to_str().unwrap());
        assert!(preview(&store, &p).is_err());
        fs::create_dir(root.join("folder")).unwrap();
        fs::write(root.join("folder/source.jsonl"), fixture("codex")).unwrap();
        symlink(root.join("folder"), root.join("linked-folder")).unwrap();
        p["path"] = json!(root.join("linked-folder/source.jsonl").to_str().unwrap());
        assert!(preview(&store, &p).is_err());
        File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(MAX_BYTES as u64 + 1)
            .unwrap();
        assert!(preview(&store, &params).is_err());
        p["path"] = json!("relative.jsonl");
        assert!(preview(&store, &p).is_err());
    }
    #[cfg(windows)]
    #[test]
    fn rejects_windows_junction_parents_and_traversal() {
        let (dir, _path, store, params, _bytes) = setup("claude");
        let root = root(&dir);
        assert!(preview(&store, &params).is_ok());
        fs::create_dir(root.join("folder")).unwrap();
        fs::write(root.join("folder").join("source.jsonl"), fixture("claude")).unwrap();
        let status = std::process::Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(root.join("junction"))
            .arg(root.join("folder"))
            .status()
            .unwrap();
        assert!(status.success());
        let mut p = params.clone();
        p["path"] = json!(root.join("junction").join("source.jsonl").to_str().unwrap());
        assert!(preview(&store, &p).is_err());
        p["path"] = json!(format!("{}\\folder\\..\\source.jsonl", root.display()));
        assert!(preview(&store, &p).is_err());
    }
}
