//! Explicit CLI-session capture. Parent API registers `preview` and `import`.
//! Captures source bytes into Store and, as Swift's `importSession` does, saves
//! a thread that continues the source's native session in approval mode. Neither
//! route starts a provider; the session resumes only with the user's next message.
use crate::{
    cli_session_import::{
        ImportProvider, MAX_BYTES, SessionPreview, preview_claude, preview_codex,
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
#[cfg(not(unix))]
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
fn parse(provider: &str, bytes: &[u8]) -> Result<SessionPreview> {
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

/// Params: absolute `path` (no symlinks in any component), `provider`.
/// The fingerprint is a source-change guard, not an authorization credential.
/// `existingThreadId` names the conversation already holding this session, which
/// Import then opens instead of copying it again.
pub fn preview(store: &Store, params: &Value) -> Result<Value> {
    let bytes = read_source(Path::new(required(params, "path")?))?;
    let parsed = parse(required(params, "provider")?, &bytes)?;
    let existing = store.thread_for_native_session(
        provider_name(parsed.provider),
        &parsed.session_id.to_string(),
    )?;
    Ok(
        json!({"provider":provider_name(parsed.provider),"sessionId":parsed.session_id.to_string(),
        "sourceKey":source_key(&parsed),"sha256":fingerprint(&bytes),"bytes":bytes.len(),
        "title":title(&parsed),"directory":parsed.directory,"model":parsed.model,
        "messageCount":parsed.messages.len(),"omittedRecords":parsed.omitted_records,
        "shortenedText":parsed.shortened_text,"continuesSession":true,"existingThreadId":existing,
        "messages":parsed.messages.iter().take(20).map(|m| json!({"role":m.role,"text":m.text})).collect::<Vec<_>>() }),
    )
}

/// The project a session continues in: the explicit `projectId`, else the
/// project for the session's folder, added when the folder exists and no project
/// has it yet (Swift's `importSession`). A missing folder imports into Chats.
fn project(store: &mut Store, params: &Value, directory: &str) -> Result<String> {
    ensure!(
        params["projectId"].is_null() || params["projectId"].is_string(),
        "projectId must be a UUID string"
    );
    if let Some(project) = params["projectId"].as_str() {
        let project = Uuid::parse_str(project)?.to_string().to_uppercase();
        if project != CHATS {
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
        return Ok(project);
    }
    let folder = Path::new(directory);
    if !folder.is_absolute() || !folder.is_dir() {
        return Ok(CHATS.into());
    }
    let project = store.create_project(folder, None)?;
    Ok(project["id"]
        .as_str()
        .context("Created project has no ID")?
        .to_owned())
}
const CHATS: &str = "00000000-0000-0000-0000-000000000000";

/// Params: preview's `path`, `provider`, `sha256`, and optional `projectId`.
/// Rereads immediately before the Store transaction; duplicates never overwrite.
/// A session already in a conversation returns that thread with `existing`.
/// Parent increments engine revision only for a new import.
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
    let provider = provider_name(parsed.provider);
    let session = parsed.session_id.to_string();
    if let Some(existing) = store.thread_for_native_session(provider, &session)? {
        return Ok(json!({"threadId":existing,"existing":true,"continuesSession":true}));
    }
    let source_key = source_key(&parsed);
    ensure!(
        store.original(&source_key)?.is_none(),
        "This CLI source key was already imported"
    );
    // Validated before the project so a rejected import adds no project. A
    // failure in the Store transaction itself can leave only that empty project.
    let project = project(store, params, &parsed.directory)?;
    let id = Uuid::new_v4().to_string().to_uppercase();
    let now = swift_timestamp();
    let items = parsed.messages.iter().map(|message| json!({
        "id":Uuid::new_v4().to_string().to_uppercase(),"kind":message.role,"text":message.text,
        "provider":provider,"createdAt":now,"completedAt":now,"status":"completed",
        "importedTimestamp":message.timestamp,"externalID":message.external_id
    })).collect::<Vec<_>>();
    // The native session has seen every imported item, so continuing sends only
    // what the user writes next.
    let mut document = json!({"id":id,"projectID":project,"title":title(&parsed),
        "createdAt":now,"updatedAt":now,"items":items,
        "sessions":{(provider):{"sessionID":session,"seenItemCount":parsed.messages.len()}},"draft":"",
        "selection":{"provider":provider,"modelID":parsed.model.as_deref().unwrap_or("default")},
        "accessMode":"approval","interactionMode":"build","isPinned":false,"isArchived":false,
        "importedSession":{"sourceKey":source_key,"sha256":expected,"provider":provider,
            "sessionID":session,"directory":parsed.directory,
            "omittedRecords":parsed.omitted_records,"shortenedText":parsed.shortened_text}});
    if let Some(follow_up) = store
        .document("settings.json")?
        .as_ref()
        .and_then(|settings| {
            crate::composer_follow_up::Behavior::parse(&settings["followUpBehavior"])
        })
    {
        document["followUpBehavior"] = json!(follow_up.key());
    }
    store.import_resumable_cli_session(&document, &source_key, &bytes)?;
    Ok(
        json!({"threadId":id,"existing":false,"sourceKey":source_key,"projectId":project,
        "messageCount":parsed.messages.len(),"omittedRecords":parsed.omitted_records,
        "shortenedText":parsed.shortened_text,"continuesSession":true}),
    )
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::fs;
    const SESSION: &str = "00000000-0000-4000-8000-000000000001";
    fn fixture_in(provider: &str, cwd: &str) -> Vec<u8> {
        let records = if provider == "codex" {
            vec![
                json!({"type":"session_meta","payload":{"id":SESSION,"cwd":cwd,"unknown":{"preserve":true}}}),
                json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fixture unique question"}]}}),
            ]
        } else {
            vec![
                json!({"sessionId":SESSION,"cwd":cwd,"uuid":"one","parentUuid":null,
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
    fn fixture(provider: &str) -> Vec<u8> {
        fixture_in(provider, "/synthetic")
    }
    fn setup(provider: &str) -> (tempfile::TempDir, std::path::PathBuf, Store, Value, Vec<u8>) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let path = root.join("source.jsonl");
        let bytes = fixture(provider);
        fs::write(&path, &bytes).unwrap();
        let store = Store::open(&root.join("rust/state.sqlite")).unwrap();
        let mut params = json!({"provider":provider,"path":path.to_str().unwrap()});
        params["sha256"] = preview(&store, &params).unwrap()["sha256"].clone();
        (dir, path, store, params, bytes)
    }
    #[test]
    fn persisted_import_preserves_source_and_continues_the_native_session_after_restart() {
        for provider in ["codex", "claude"] {
            let (dir, path, mut store, params, bytes) = setup(provider);
            assert!(store.summaries("", true).unwrap().is_empty());
            let result = import(&mut store, &params).unwrap();
            assert_eq!(result["existing"], false);
            let id = result["threadId"].as_str().unwrap().to_owned();
            let source = result["sourceKey"].as_str().unwrap();
            assert_eq!(store.original(source).unwrap().unwrap(), bytes);
            assert_eq!(fs::read(path).unwrap(), bytes);
            assert_eq!(store.summaries("unique", true).unwrap().len(), 1);
            drop(store);
            let store = Store::open(&dir.path().join("rust/state.sqlite")).unwrap();
            // No execution barrier: the thread runs like any other, resuming the
            // source's own session after the items it has already seen.
            assert!(!store.is_imported(&id).unwrap());
            let thread = store.thread(&id).unwrap();
            assert_eq!(
                crate::agent::provider_session(&thread, provider).as_deref(),
                Some(SESSION)
            );
            assert_eq!(crate::agent::provider_seen_count(&thread, provider), 1);
            assert_eq!(thread["accessMode"], "approval");
            assert_eq!(thread["interactionMode"], "build");
            assert_eq!(thread["importedSession"]["sessionID"], SESSION);
            // The synthetic folder does not exist, so no project is added for it.
            assert_eq!(thread["projectID"], CHATS);
            assert!(store.projects().unwrap().as_array().unwrap().is_empty());
        }
    }
    #[test]
    fn existing_session_folder_becomes_or_reuses_the_threads_project() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let folder = root.join("work/app");
        fs::create_dir_all(&folder).unwrap();
        let mut store = Store::open(&root.join("rust/state.sqlite")).unwrap();
        let mut ids = Vec::new();
        for provider in ["codex", "claude"] {
            let path = root.join(format!("{provider}.jsonl"));
            fs::write(&path, fixture_in(provider, folder.to_str().unwrap())).unwrap();
            let mut params = json!({"provider":provider,"path":path.to_str().unwrap()});
            params["sha256"] = preview(&store, &params).unwrap()["sha256"].clone();
            let result = import(&mut store, &params).unwrap();
            ids.push(result["projectId"].as_str().unwrap().to_owned());
        }
        assert_eq!(ids[0], ids[1]);
        let projects = store.projects().unwrap();
        let projects = projects.as_array().unwrap();
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0]["path"], folder.to_str().unwrap());
        assert_eq!(projects[0]["name"], "app");
        assert_eq!(projects[0]["id"], ids[0].as_str());
    }
    #[test]
    fn changed_source_leaves_no_partial_thread_and_a_second_import_opens_the_first() {
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
        let id = imported["threadId"].as_str().unwrap();
        assert_eq!(
            preview(&store, &params).unwrap()["existingThreadId"],
            json!(id)
        );
        let again = import(&mut store, &params).unwrap();
        assert_eq!(again["existing"], true);
        assert_eq!(again["threadId"], json!(id));
        assert_eq!(store.summaries("", true).unwrap().len(), 1);
    }
    #[test]
    fn sessions_already_in_a_conversation_are_found_in_either_saved_form() {
        let (_dir, _path, mut store, params, _bytes) = setup("claude");
        assert!(preview(&store, &params).unwrap()["existingThreadId"].is_null());
        // Swift writes enum-keyed dictionaries as alternating key/value arrays.
        let mut swift = store
            .new_thread("00000000-0000-0000-0000-000000000000")
            .unwrap();
        swift["sessions"] =
            json!(["codex",{"sessionID":"other"},"claude",{"sessionID":SESSION.to_uppercase()}]);
        store.save(&swift).unwrap();
        assert_eq!(
            preview(&store, &params).unwrap()["existingThreadId"],
            swift["id"]
        );
        let opened = import(&mut store, &params).unwrap();
        assert_eq!(opened["existing"], true);
        assert_eq!(opened["threadId"], swift["id"]);
        let mut rust = swift.clone();
        rust["sessions"] = json!({"codex":{"sessionID":SESSION}});
        store.save(&rust).unwrap();
        // The same ID under another provider is a different session.
        assert!(preview(&store, &params).unwrap()["existingThreadId"].is_null());
        assert_eq!(
            store.thread_for_native_session("codex", SESSION).unwrap(),
            rust["id"].as_str().map(str::to_owned)
        );
        assert!(
            store
                .thread_for_native_session("antigravity", SESSION)
                .is_err()
        );
    }
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
}
