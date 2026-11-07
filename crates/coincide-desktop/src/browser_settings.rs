//! Native profiles, metadata preview and explicit saved bookmark import. No cookies,
//! passwords, keys, login grants or original Swift website stores are imported.
use crate::worker_owner::{ShutdownStatus as WorkerOwnerStatus, WorkerOwner};
use anyhow::{Result, ensure};
use coincide_core::{
    api::SharedEngine,
    browser_bookmarks::{self, Library, Plan},
};
use gpui_kit::{
    AnyElement, AppContext, Context, Entity, InteractiveElement, IntoElement, ParentElement,
    PathPromptOptions, Render, ScrollHandle, SharedString, Styled, Window,
    component::{
        Disableable,
        button::Button,
        input::{Input, InputState},
    },
    div,
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashSet},
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
        mpsc::{self, Receiver, SyncSender},
    },
};
use uuid::Uuid;
const MAX_DOCUMENT: u64 = 1_048_576;
#[path = "cookie_import_flow.rs"]
pub(crate) mod cookie_flow;
#[path = "browser_history_flow.rs"]
pub(crate) mod history_flow;
#[path = "browser_search_settings.rs"]
mod search_settings;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CookieImportMarker {
    Incomplete,
    ReadbackVerified,
}
impl CookieImportMarker {
    fn raw(&self) -> &'static str {
        match self {
            Self::Incomplete => "incomplete_or_uncertain",
            Self::ReadbackVerified => "readback_verified",
        }
    }
}
pub(crate) struct FreshCookieProfile {
    id: Uuid,
    name: String,
    thread: String,
    revision: u64,
}
impl FreshCookieProfile {
    pub(crate) fn id(&self) -> Uuid {
        self.id
    }
    pub(crate) fn name(&self) -> &str {
        &self.name
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProfileMetadata {
    pub id: Uuid,
    pub name: String,
    pub is_default: bool,
    pub cookie_import: Option<CookieImportMarker>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProfileChoice {
    Persistent(Uuid),
    Private,
}
impl ProfileChoice {
    pub(crate) fn key(&self, thread: &str) -> String {
        match self {
            Self::Persistent(id) => id.to_string(),
            Self::Private => format!("private-{thread}"),
        }
    }
}
#[derive(Clone, PartialEq, Eq)]
pub struct ProfileSnapshot {
    pub thread: String,
    pub revision: u64,
    pub profiles: Vec<ProfileMetadata>,
    pub selected: ProfileChoice,
    pub open_tabs: usize,
    pub persistent_profiles_available: bool,
}
#[derive(Clone)]
pub enum ProfileOperation {
    Select(ProfileChoice),
    CreateFresh(String),
}
pub struct ProfileRequest {
    pub thread: String,
    pub revision: u64,
    pub operation: ProfileOperation,
}
/// Catalog stores names, fresh Rust IDs and thread choices only. No secret data.
pub(crate) struct ProfileCatalog {
    root: PathBuf,
    pub revision: u64,
    pub profiles: Vec<ProfileMetadata>,
    selections: BTreeMap<String, ProfileChoice>,
    raw_document: Value,
}
impl ProfileCatalog {
    pub fn open(root: PathBuf, legacy_rust_default: Option<Uuid>) -> Result<Self> {
        let path = root.join("profiles.json");
        let existed = fs::symlink_metadata(&path).is_ok();
        let mut catalog = if existed {
            let value: Value = serde_json::from_slice(&read_document(&path)?)?;
            ensure!(
                value["version"] == 1,
                "Unsupported browser profile metadata version"
            );
            let profiles = value["profiles"]
                .as_array()
                .ok_or_else(|| anyhow::anyhow!("Invalid profile metadata"))?;
            ensure!(
                !profiles.is_empty() && profiles.len() <= 32,
                "Invalid browser profile count"
            );
            let mut ids = HashSet::new();
            let mut parsed = Vec::new();
            for profile in profiles {
                let id = Uuid::parse_str(
                    profile["id"]
                        .as_str()
                        .ok_or_else(|| anyhow::anyhow!("Invalid profile ID"))?,
                )?;
                ensure!(ids.insert(id), "Duplicate browser profile ID");
                let name = profile["name"]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("Invalid profile name"))?;
                validate_name(name)?;
                parsed.push(ProfileMetadata {
                    id,
                    name: name.into(),
                    is_default: profile["default"].as_bool().unwrap_or(false),
                    cookie_import: match profile.get("cookieImport") {
                        None | Some(Value::Null) => None,
                        Some(value) if value == "incomplete_or_uncertain" => {
                            Some(CookieImportMarker::Incomplete)
                        }
                        Some(value) if value == "readback_verified" => {
                            Some(CookieImportMarker::ReadbackVerified)
                        }
                        _ => anyhow::bail!("Unsupported cookie import marker"),
                    },
                });
            }
            ensure!(
                parsed.iter().filter(|p| p.is_default).count() == 1,
                "Exactly one default profile required"
            );
            if let Some(id) = legacy_rust_default {
                ensure!(
                    parsed.iter().any(|p| p.is_default && p.id == id),
                    "Rust default profile identity mismatch"
                );
            }
            ensure!(
                value.get("threads").is_none_or(Value::is_object),
                "Invalid browser thread choices"
            );
            let mut selections = BTreeMap::new();
            if let Some(threads) = value["threads"].as_object() {
                ensure!(threads.len() <= 4096, "Too many profile selections");
                for (thread, choice) in threads {
                    validate_thread(thread)?;
                    let choice = choice
                        .as_str()
                        .ok_or_else(|| anyhow::anyhow!("Invalid profile selection"))?;
                    let choice = if choice == "private" {
                        ProfileChoice::Private
                    } else {
                        let id = Uuid::parse_str(choice)?;
                        ensure!(ids.contains(&id), "Unknown profile selection");
                        ProfileChoice::Persistent(id)
                    };
                    selections.insert(thread.clone(), choice);
                }
            }
            Self {
                root,
                revision: 0,
                profiles: parsed,
                selections,
                raw_document: value,
            }
        } else {
            Self {
                root,
                revision: 0,
                profiles: vec![ProfileMetadata {
                    id: legacy_rust_default.unwrap_or_else(Uuid::new_v4),
                    name: "Default".into(),
                    is_default: true,
                    cookie_import: None,
                }],
                selections: BTreeMap::new(),
                raw_document: json!({"version":1,"profiles":[],"threads":{}}),
            }
        };
        if !existed {
            catalog.save()?;
        }
        Ok(catalog)
    }
    pub fn selected(&self, thread: &str) -> ProfileChoice {
        self.selections.get(thread).cloned().unwrap_or_else(|| {
            ProfileChoice::Persistent(self.profiles.iter().find(|p| p.is_default).unwrap().id)
        })
    }
    pub fn snapshot(&self, thread: &str, open_tabs: usize) -> ProfileSnapshot {
        ProfileSnapshot {
            thread: thread.into(),
            revision: self.revision,
            profiles: self.profiles.clone(),
            selected: self.selected(thread),
            open_tabs,
            persistent_profiles_available: true,
        }
    }
    pub fn apply(
        &mut self,
        current_thread: &str,
        request: ProfileRequest,
        open_tabs: usize,
    ) -> Result<()> {
        validate_thread(current_thread)?;
        ensure!(
            current_thread == request.thread && request.revision == self.revision,
            "Thread or profile metadata changed. Retry this action."
        );
        let old_profiles = self.profiles.clone();
        let old_selections = self.selections.clone();
        match request.operation {
            ProfileOperation::Select(choice) => {
                ensure!(
                    open_tabs == 0,
                    "Close this thread's tabs before switching profiles. Other threads stay open."
                );
                if let ProfileChoice::Persistent(id) = &choice {
                    ensure!(
                        self.profiles.iter().any(|p| p.id == *id),
                        "No such Rust browser profile"
                    );
                }
                ensure!(
                    self.selections.contains_key(current_thread) || self.selections.len() < 4096,
                    "Too many profile selections"
                );
                self.selections.insert(current_thread.into(), choice);
            }
            ProfileOperation::CreateFresh(name) => {
                validate_name(&name)?;
                ensure!(self.profiles.len() < 32, "Browser profile limit reached");
                ensure!(
                    !self
                        .profiles
                        .iter()
                        .any(|p| p.name.eq_ignore_ascii_case(&name)),
                    "A profile with this name exists"
                );
                self.profiles.push(ProfileMetadata {
                    id: Uuid::new_v4(),
                    name,
                    is_default: false,
                    cookie_import: None,
                });
            }
        }
        if let Err(error) = self.save() {
            self.profiles = old_profiles;
            self.selections = old_selections;
            return Err(error);
        }
        self.revision = self.revision.wrapping_add(1);
        Ok(())
    }
    pub(crate) fn reserve_cookie_profile(
        &self,
        thread: &str,
        revision: u64,
        name: &str,
    ) -> Result<FreshCookieProfile> {
        validate_thread(thread)?;
        validate_name(name)?;
        ensure!(
            revision == self.revision && self.profiles.len() < 32,
            "Profile metadata changed or profile limit reached"
        );
        ensure!(
            !self
                .profiles
                .iter()
                .any(|profile| profile.name.eq_ignore_ascii_case(name)),
            "A profile with this name exists"
        );
        Ok(FreshCookieProfile {
            id: Uuid::new_v4(),
            name: name.into(),
            thread: thread.into(),
            revision,
        })
    }
    pub(crate) fn commit_cookie_profile(
        &mut self,
        thread: &str,
        fresh: &FreshCookieProfile,
    ) -> Result<()> {
        ensure!(
            thread == fresh.thread && self.revision == fresh.revision,
            "Browser profile changed before import"
        );
        ensure!(
            self.profiles.len() < 32
                && !self.profiles.iter().any(|profile| profile.id == fresh.id
                    || profile.name.eq_ignore_ascii_case(&fresh.name)),
            "Cookie destination is no longer fresh"
        );
        let next_revision = self
            .revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("Profile revision exhausted"))?;
        self.profiles.push(ProfileMetadata {
            id: fresh.id,
            name: fresh.name.clone(),
            is_default: false,
            cookie_import: Some(CookieImportMarker::Incomplete),
        });
        if let Err(error) = self.save() {
            self.profiles.pop();
            return Err(error);
        }
        self.revision = next_revision;
        // No native dispatch before the incomplete marker's directory entry sync.
        fs::File::open(&self.root)?.sync_all()?;
        Ok(())
    }
    pub(crate) fn mark_cookie_readback_verified(&mut self, id: Uuid) -> Result<()> {
        let next_revision = self
            .revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("Profile revision exhausted"))?;
        let index = self
            .profiles
            .iter()
            .position(|profile| {
                profile.id == id && profile.cookie_import == Some(CookieImportMarker::Incomplete)
            })
            .ok_or_else(|| anyhow::anyhow!("Cookie import marker changed"))?;
        self.profiles[index].cookie_import = Some(CookieImportMarker::ReadbackVerified);
        if let Err(error) = self.save() {
            self.profiles[index].cookie_import = Some(CookieImportMarker::Incomplete);
            return Err(error);
        }
        self.revision = next_revision;
        fs::File::open(&self.root)?.sync_all()?;
        Ok(())
    }
    /// A fresh native runtime scaffold, never a persisted private profile.
    /// WebView2 still needs a user-data root in InPrivate mode. Never give it
    /// None (the SDK's default user profile), reuse a prior session, or remove
    /// these directories while native teardown remains unconfirmed.
    #[cfg(any(target_os = "windows", test))]
    pub(crate) fn new_private_runtime_directory(&self) -> Result<PathBuf> {
        let root = self.root.join("private-runtime");
        coincide_core::native_file::private_directory(&root)?;
        let directory = root.join(Uuid::new_v4().to_string());
        ensure!(
            !directory.try_exists()?,
            "Private runtime generation already exists"
        );
        coincide_core::native_file::private_directory(&directory)?;
        Ok(directory)
    }
    pub fn storage_directory(&self, choice: &ProfileChoice) -> Result<Option<PathBuf>> {
        match choice {
            ProfileChoice::Private => Ok(None),
            ProfileChoice::Persistent(id) => {
                let profile = self
                    .profiles
                    .iter()
                    .find(|p| p.id == *id)
                    .ok_or_else(|| anyhow::anyhow!("No such profile"))?;
                if profile.is_default {
                    return Ok(Some(self.root.join("web-context")));
                }
                let profiles = self.root.join("profiles");
                private_directory(&profiles)?;
                let directory = profiles.join(id.to_string());
                private_directory(&directory)?;
                Ok(Some(directory.join("web-context")))
            }
        }
    }
    fn save(&mut self) -> Result<()> {
        // Unknown fields remain opaque data; only existing owned fields/new rows
        // are patched. They never become profile/path/runtime authority.
        let mut value = self.raw_document.clone();
        let old = value["profiles"].as_array().cloned().unwrap_or_default();
        let profiles=self.profiles.iter().map(|profile| {
            let mut row=old.iter().find(|row|row["id"].as_str().and_then(|id|Uuid::parse_str(id).ok())==Some(profile.id)).cloned()
                .unwrap_or_else(||json!({"id":profile.id,"name":profile.name,"default":profile.is_default}));
            if row["name"]!=profile.name {row["name"]=json!(profile.name);}
            if row["default"].as_bool().unwrap_or(false)!=profile.is_default {row["default"]=json!(profile.is_default);}
            if let Some(marker)=&profile.cookie_import {row["cookieImport"]=json!(marker.raw());}
            row
        }).collect::<Vec<_>>();
        value["profiles"] = json!(profiles);
        if !self.selections.is_empty() {
            if value.get("threads").is_none() {
                value["threads"] = json!({});
            }
            for (thread, choice) in &self.selections {
                let previous = value["threads"][thread].as_str();
                let same = match choice {
                    ProfileChoice::Private => previous == Some("private"),
                    ProfileChoice::Persistent(id) => {
                        previous.and_then(|value| Uuid::parse_str(value).ok()) == Some(*id)
                    }
                };
                if !same {
                    value["threads"][thread] = json!(match choice {
                        ProfileChoice::Private => "private".into(),
                        ProfileChoice::Persistent(id) => id.to_string(),
                    });
                }
            }
        }
        let bytes = serde_json::to_vec_pretty(&value)?;
        ensure!(
            bytes.len() as u64 <= MAX_DOCUMENT,
            "Profile metadata too large"
        );
        let target = self.root.join("profiles.json");
        if fs::symlink_metadata(&target).is_ok() {
            ensure!(
                !fs::symlink_metadata(&target)?.file_type().is_symlink(),
                "Profile metadata cannot be a symlink"
            );
        }
        let temporary = self.root.join(format!(".profiles-{}.tmp", Uuid::new_v4()));
        let result = (|| -> Result<()> {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temporary, target)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        } else {
            self.raw_document = value;
        }
        result
    }
}
fn private_directory(path: &Path) -> Result<()> {
    if path.exists() {
        ensure!(
            fs::symlink_metadata(path)?.is_dir()
                && !fs::symlink_metadata(path)?.file_type().is_symlink(),
            "Profile directory is not a real directory"
        );
    } else {
        let mut builder = fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(path)?;
    }
    Ok(())
}
fn validate_name(name: &str) -> Result<()> {
    ensure!(
        !name.trim().is_empty()
            && name == name.trim()
            && name.chars().count() <= 80
            && !name.chars().any(char::is_control),
        "Use a profile name of 1 to 80 characters without control characters"
    );
    Ok(())
}
fn validate_thread(thread: &str) -> Result<()> {
    ensure!(
        !thread.is_empty()
            && thread.len() <= 128
            && thread
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b)),
        "Invalid thread ID"
    );
    Ok(())
}
fn read_document(path: &Path) -> Result<Vec<u8>> {
    ensure!(
        !fs::symlink_metadata(path)?.file_type().is_symlink(),
        "Choose a regular JSON file, not a symbolic link"
    );
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(0x100 | 0x4);
    }
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(0x20000 | 0x800);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000);
    }
    let file = options.open(path)?;
    ensure!(
        file.metadata()?.is_file() && file.metadata()?.len() <= MAX_DOCUMENT,
        "Choose a regular JSON file under 1 MB"
    );
    let mut bytes = Vec::new();
    file.take(MAX_DOCUMENT + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= MAX_DOCUMENT,
        "JSON document too large"
    );
    Ok(bytes)
}
#[derive(Clone)]
pub struct ImportPreview {
    pub profiles: usize,
    pub bookmarks: usize,
    pub history: usize,
    pub cookies_not_imported: usize,
    pub legacy_profile: bool,
    pub bookmark_plan: Option<Plan>,
    pub bookmark_problem: Option<String>,
}
pub fn preview_import(bytes: &[u8]) -> Result<ImportPreview> {
    ensure!(
        bytes.len() as u64 <= MAX_DOCUMENT,
        "Import preview exceeds 1 MB"
    );
    let value: Value = serde_json::from_slice(bytes)
        .map_err(|_| anyhow::anyhow!("Choose a browser metadata JSON export"))?;
    ensure!(value.is_object(), "Browser metadata must be an object");
    fn sensitive(value: &Value) -> bool {
        match value {
            Value::Object(fields) => fields.iter().any(|(key, value)| {
                [
                    "password",
                    "totp",
                    "privatekey",
                    "accesstoken",
                    "refreshtoken",
                    "authorization",
                ]
                .contains(&key.to_ascii_lowercase().as_str())
                    || sensitive(value)
            }),
            Value::Array(items) => items.iter().any(sensitive),
            _ => false,
        }
    }
    ensure!(
        !sensitive(&value),
        "Credential-bearing exports are not supported by browser metadata preview"
    );
    let legacy = value["profileID"]
        .as_str()
        .map(Uuid::parse_str)
        .transpose()
        .map_err(|_| anyhow::anyhow!("Invalid legacy profile reference"))?
        .is_some();
    let profiles = value["profiles"].as_array().map_or(0, Vec::len);
    ensure!(
        legacy || profiles > 0 || value["bookmarks"].is_array() || value["history"].is_array(),
        "Unsupported browser metadata export"
    );
    let bookmark_result = browser_bookmarks::preview(bytes);
    let bookmark_plan = bookmark_result.as_ref().ok().cloned();
    Ok(ImportPreview {
        profiles: if legacy { 1 } else { profiles },
        bookmarks: value["bookmarks"].as_array().map_or(0, Vec::len),
        history: value["history"].as_array().map_or(0, Vec::len),
        cookies_not_imported: value["cookies"].as_array().map_or(0, Vec::len),
        legacy_profile: legacy,
        bookmark_plan,
        bookmark_problem: if value["bookmarks"]
            .as_array()
            .is_some_and(|items| !items.is_empty())
        {
            bookmark_result.err().map(|error| error.to_string())
        } else {
            None
        },
    })
}

fn finish_import_choice(workers: &mut WorkerOwner, expected: u64, current: u64) -> bool {
    workers.finish_picker() && expected == current
}
#[derive(Clone)]
struct ChosenBookmarks {
    path: PathBuf,
    fingerprint: String,
    plan: Plan,
    expected_revision: Option<u64>,
}
fn verify_chosen_bookmarks(chosen: &ChosenBookmarks) -> Result<()> {
    let bytes = read_document(&chosen.path).map_err(|_| {
        anyhow::anyhow!("The chosen export is unavailable; choose and review it again")
    })?;
    ensure!(
        browser_bookmarks::fingerprint(&bytes) == chosen.fingerprint,
        "The export changed after preview; choose and review it again. Nothing imported"
    );
    chosen.plan.validate()?;
    Ok(())
}
pub struct BookmarkOpen {
    pub thread: String,
    pub prepared: coincide_core::api::PreparedBookmarkOpen,
}
enum LibraryReply {
    Preview(ImportPreview, Option<ChosenBookmarks>, Option<Library>),
    Reloaded(Library),
    Saved(browser_bookmarks::ImportResult),
    OpenPrepared(BookmarkOpen),
}
type LibraryCompletion = (u64, Result<LibraryReply, String>);
fn library_context_allowed(
    admission: &crate::worker_owner::Admission,
    epoch: &AtomicU64,
    generation: u64,
) -> Result<()> {
    ensure!(
        admission.allowed() && epoch.load(Ordering::Acquire) == generation,
        "Browser settings changed; action was not admitted"
    );
    Ok(())
}
// Route transitions are recorded synchronously by the parent, not inferred from
// the next profile poll. Closing and reopening the same thread is a new route.
fn update_route_epoch(
    route: &mut Option<String>,
    next: Option<&str>,
    generation: &mut u64,
    epoch: &AtomicU64,
) -> bool {
    if route.as_deref() == next {
        return false;
    }
    *route = next.map(str::to_owned);
    *generation = generation.wrapping_add(1);
    epoch.store(*generation, Ordering::Release);
    true
}
pub struct BrowserSettings {
    workers: WorkerOwner,
    history: history_flow::State,
    cookie_flow: cookie_flow::Flow,
    form_scroll: ScrollHandle,
    engine: Option<SharedEngine>,
    epoch: Arc<AtomicU64>,
    route: Option<String>,
    chosen: Option<ChosenBookmarks>,
    library: Option<Library>,
    library_page: usize,
    preview_page: usize,
    bookmark_open: Option<BookmarkOpen>,
    snapshot: Option<ProfileSnapshot>,
    name: Entity<InputState>,
    sender: SyncSender<ProfileRequest>,
    preview: Option<ImportPreview>,
    import_busy: bool,
    profile_pending: bool,
    generation: u64,
    imports: Receiver<LibraryCompletion>,
    import_sender: SyncSender<LibraryCompletion>,
    status: String,
    /// The address bar's engine; None until read from the trusted engine.
    search_engine: Option<coincide_core::browser_address::SearchEngine>,
}
impl BrowserSettings {
    pub fn request_shutdown(&mut self) {
        self.cookie_flow.close();
        self.history.close();
        if self.workers.close() {
            self.generation = self.generation.wrapping_add(1);
            self.epoch.store(self.generation, Ordering::Release);
        }
        self.preview = None;
        self.chosen = None;
        self.bookmark_open = None;
        self.discard_shutdown_results();
    }
    fn discard_shutdown_results(&mut self) {
        for result in self.imports.try_iter() {
            drop(result);
        }
    }
    pub fn shutdown_status(&mut self) -> WorkerOwnerStatus {
        if self.workers.closed() {
            self.discard_shutdown_results();
        }
        let mut status = self.workers.status();
        let cookie = self.cookie_flow.shutdown_status();
        status.closed &= cookie.closed;
        status.unjoined += cookie.unjoined;
        status.returned += cookie.returned;
        status.panicked += cookie.panicked;
        status.unclassified += cookie.unclassified;
        status.pending_pickers += cookie.pending_pickers;
        if status.spawn_error.is_none() {
            status.spawn_error = cookie.spawn_error;
        }
        let history = self.history.shutdown_status();
        status.closed &= history.closed;
        status.unjoined += history.unjoined;
        status.returned += history.returned;
        status.panicked += history.panicked;
        status.unclassified += history.unclassified;
        status.pending_pickers += history.pending_pickers;
        if status.spawn_error.is_none() {
            status.spawn_error = history.spawn_error;
        }
        status
    }
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> (Self, Receiver<ProfileRequest>) {
        let name = cx.new(|cx| InputState::new(window, cx).placeholder("New Rust profile name"));
        let (sender, requests) = mpsc::sync_channel(8);
        let (import_sender, imports) = mpsc::sync_channel(1);
        (
            Self {
                workers: WorkerOwner::default(),
                history: history_flow::State::default(),
                cookie_flow: cookie_flow::Flow::default(),
                form_scroll: ScrollHandle::default(),
                engine: None,
                epoch: Arc::new(AtomicU64::new(0)),
                route: None,
                chosen: None,
                library: None,
                library_page: 0,
                preview_page: 0,
                bookmark_open: None,
                snapshot: None,
                name,
                sender,
                preview: None,
                import_busy: false,
                profile_pending: false,
                generation: 0,
                imports,
                import_sender,
                status: "Choose a thread to view its browser profile.".into(),
                search_engine: None,
            },
            requests,
        )
    }
    pub fn form_scroll(&self) -> ScrollHandle {
        self.form_scroll.clone()
    }
    /// Parent injects only its existing trusted Engine; no path or global lookup.
    pub fn set_library_engine(&mut self, engine: SharedEngine) {
        if self.workers.closed()
            || self
                .engine
                .as_ref()
                .is_some_and(|old| Arc::ptr_eq(old, &engine))
        {
            return;
        }
        self.engine = Some(engine);
        self.search_engine = None;
        self.history.set_binding(None);
        self.generation = self.generation.wrapping_add(1);
        self.epoch.store(self.generation, Ordering::Release);
        self.chosen = None;
        self.preview = None;
        self.library = None;
        self.bookmark_open = None;
    }
    /// Parent admits this opaque preparation only after fresh visibility/thread
    /// checks, then registers returned operation IDs and closes Settings.
    pub fn take_bookmark_open(&mut self) -> Option<BookmarkOpen> {
        self.bookmark_open.take()
    }
    pub fn set_bookmark_open_error(&mut self, error: String, cx: &mut Context<Self>) {
        if !self.workers.closed() {
            self.status = error;
            cx.notify();
        }
    }

    fn library_work(
        &mut self,
        status: &str,
        cx: &mut Context<Self>,
        work: impl FnOnce(
            SharedEngine,
            crate::worker_owner::Admission,
            Arc<AtomicU64>,
            u64,
            ProfileSnapshot,
        ) -> Result<LibraryReply>
        + Send
        + 'static,
    ) {
        if self.import_busy
            || self.profile_pending
            || self.history.busy()
            || !self.workers.can_start()
        {
            self.status = "A browser settings action is still finishing.".into();
            cx.notify();
            return;
        }
        let (Some(engine), Some(snapshot)) = (self.engine.clone(), self.snapshot.clone()) else {
            self.status = "Select a thread in the desktop browser first.".into();
            cx.notify();
            return;
        };
        self.import_busy = true;
        self.status = status.into();
        let generation = self.generation;
        let epoch = self.epoch.clone();
        let sender = self.import_sender.clone();
        if !self.workers.spawn(move |admission| {
            let result = work(engine, admission, epoch, generation, snapshot)
                .map_err(|error| error.to_string());
            let _ = sender.send((generation, result));
        }) {
            self.import_busy = false;
            self.status = "Browser settings worker could not start.".into();
        }
        cx.notify();
    }
    fn reload_bookmarks(&mut self, cx: &mut Context<Self>) {
        self.library_work(
            "Loading saved Rust bookmarks…",
            cx,
            |engine, admission, epoch, generation, snapshot| {
                library_context_allowed(&admission, &epoch, generation)?;
                let engine = engine.try_lock().map_err(|_| {
                    anyhow::anyhow!("The app is busy; reload saved bookmarks to try again")
                })?;
                library_context_allowed(&admission, &epoch, generation)?;
                ensure!(
                    engine.active_thread() == Some(snapshot.thread.as_str()),
                    "Selected conversation changed; reload bookmarks"
                );
                Ok(LibraryReply::Reloaded(engine.saved_browser_bookmarks()?))
            },
        );
    }
    fn save_bookmarks(&mut self, cx: &mut Context<Self>) {
        let Some(chosen) = self.chosen.clone() else {
            return;
        };
        let Some(expected) = chosen.expected_revision else {
            self.status = "Reload saved bookmarks before saving this preview.".into();
            cx.notify();
            return;
        };
        self.library_work("Saving only the reviewed bookmarks…",cx,move|engine,admission,epoch,generation,snapshot|{
            library_context_allowed(&admission,&epoch,generation)?;
            verify_chosen_bookmarks(&chosen)?;
            let mut engine=engine.try_lock().map_err(|_|anyhow::anyhow!("The app is busy; saved bookmarks were not changed"))?;
            library_context_allowed(&admission,&epoch,generation)?;
            ensure!(engine.active_thread()==Some(snapshot.thread.as_str()),"Selected conversation changed; import was not admitted");
            engine.import_browser_bookmarks(expected,&chosen.plan).map(LibraryReply::Saved).map_err(|_|anyhow::anyhow!("Save could not be confirmed. Reload saved bookmarks before trying again; the existing library is retained"))
        });
    }
    fn open_bookmark(&mut self, id: Uuid, revision: u64, cx: &mut Context<Self>) {
        self.library_work(
            "Sending this bookmark to the thread browser…",
            cx,
            move |engine, admission, epoch, generation, snapshot| {
                library_context_allowed(&admission, &epoch, generation)?;
                let engine = engine
                    .try_lock()
                    .map_err(|_| anyhow::anyhow!("The app is busy; bookmark was not opened"))?;
                library_context_allowed(&admission, &epoch, generation)?;
                let prepared = engine.prepare_browser_bookmark(&snapshot.thread, id, revision)?;
                Ok(LibraryReply::OpenPrepared(BookmarkOpen {
                    thread: snapshot.thread,
                    prepared,
                }))
            },
        );
    }
    pub fn sync_route_context(&mut self, thread: Option<&str>, cx: &mut Context<Self>) {
        if update_route_epoch(&mut self.route, thread, &mut self.generation, &self.epoch) {
            self.history.set_binding(None);
            self.cookie_flow.route_changed();
            self.snapshot = None;
            self.preview = None;
            self.chosen = None;
            self.bookmark_open = None;
            self.status =
                "Browser Settings changed. Previous import previews were discarded.".into();
            cx.notify();
        }
    }
    pub fn set_snapshot(&mut self, snapshot: Option<ProfileSnapshot>, cx: &mut Context<Self>) {
        self.cookie_flow.set_snapshot(snapshot.clone());
        if self.workers.closed() {
            return;
        }
        if self.snapshot != snapshot {
            if self.snapshot.as_ref().map(|s| (&s.thread, s.revision))
                != snapshot.as_ref().map(|s| (&s.thread, s.revision))
            {
                self.generation = self.generation.wrapping_add(1);
                self.epoch.store(self.generation, Ordering::Release);
                self.preview = None;
                self.chosen = None;
                self.bookmark_open = None;
                self.status =
                    "Thread/profile metadata changed. Previous import previews were discarded."
                        .into();
            }
            self.snapshot = snapshot;
            cx.notify();
        }
    }
    pub fn set_result(&mut self, result: Result<(), String>, cx: &mut Context<Self>) {
        if self.workers.closed() {
            return;
        }
        self.profile_pending = false;
        self.status = result.err().unwrap_or_else(|| {
            "Browser profile metadata updated. Existing tabs were preserved.".into()
        });
        cx.notify();
    }
    pub fn poll(&mut self, cx: &mut Context<Self>) {
        self.poll_history(cx);
        self.cookie_flow.poll();
        // Worker completion and cleanup custody can change without any input or
        // profile snapshot change. Publish only actual UI-state transitions.
        if self.cookie_flow.take_presentation_changed() {
            cx.notify();
        }
        self.workers.poll();
        if self.workers.closed() {
            self.discard_shutdown_results();
            return;
        }
        while let Ok((generation, result)) = self.imports.try_recv() {
            self.import_busy = false;
            if generation == self.generation {
                match result {
                    Ok(LibraryReply::Preview(preview, chosen, library)) => {
                        self.preview = Some(preview);
                        self.chosen = chosen;
                        self.preview_page = 0;
                        if let Some(library) = library {
                            self.library = Some(library);
                            self.library_page = 0;
                        }
                        self.status="Preview ready. Only the reviewed HTTP(S) bookmarks can be saved; other metadata stays untouched.".into();
                    }
                    Ok(LibraryReply::Reloaded(library)) => {
                        if let Some(chosen) = &mut self.chosen {
                            chosen.expected_revision = Some(library.revision);
                        }
                        self.library = Some(library);
                        self.library_page = 0;
                        self.status =
                            "Saved Rust bookmarks reloaded. Source files were not changed.".into();
                    }
                    Ok(LibraryReply::Saved(result)) => {
                        self.status = format!(
                            "Saved {} bookmark(s); {} duplicate URL(s) skipped. No page was opened.",
                            result.added, result.duplicates
                        );
                        self.library = Some(result.library);
                        self.library_page = 0;
                        self.chosen = None;
                        self.preview = None;
                    }
                    Ok(LibraryReply::OpenPrepared(open)) => {
                        self.status = "Opening bookmark…".into();
                        self.bookmark_open = Some(open);
                    }
                    Err(error) => {
                        // No replay after an uncertain save or stale read.
                        // A separate explicit reload restores the CAS baseline.
                        if let Some(chosen) = &mut self.chosen {
                            chosen.expected_revision = None;
                        }
                        self.status = error;
                    }
                }
            }
            cx.notify();
        }
    }
    fn request(&mut self, operation: ProfileOperation, cx: &mut Context<Self>) {
        if self.workers.closed()
            || self.import_busy
            || self.profile_pending
            || self.history.busy()
            || !self.workers.can_start()
        {
            return;
        }
        let Some(snapshot) = &self.snapshot else {
            return;
        };
        let request = ProfileRequest {
            thread: snapshot.thread.clone(),
            revision: snapshot.revision,
            operation,
        };
        self.status = if self.sender.try_send(request).is_ok() {
            self.profile_pending = true;
            "Native profile action requested…"
        } else {
            "Browser settings request queue is busy. Try again."
        }
        .into();
        cx.notify();
    }
    fn choose_import(&mut self, cx: &mut Context<Self>) {
        if self.import_busy
            || self.profile_pending
            || self.history.busy()
            || !self.workers.begin_picker()
        {
            return;
        }
        self.import_busy = true;
        self.generation = self.generation.wrapping_add(1);
        self.epoch.store(self.generation, Ordering::Release);
        self.preview = None;
        self.chosen = None;
        self.bookmark_open = None;
        let generation = self.generation;
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Preview browser metadata JSON".into()),
        });
        cx.spawn(async move |this, cx| {
            let paths: Result<_> = async { picker.await? }.await;
            let _ = this.update(cx, |this, cx| {
                if !finish_import_choice(&mut this.workers, generation, this.generation) {
                    this.import_busy = false;
                    this.status =
                        "Preview selection discarded after a thread/profile change.".into();
                    cx.notify();
                    return;
                }
                match paths {
                    Ok(Some(paths)) if paths.len() == 1 => {
                        let path = paths[0].clone();
                        let sender = this.import_sender.clone();
                        let epoch = this.epoch.clone();
                        let engine = this.engine.clone();
                        if !this.workers.spawn(move |admission| {
                            let result = (|| -> Result<LibraryReply> {
                                library_context_allowed(&admission, &epoch, generation)?;
                                let bytes = read_document(&path).map_err(|_| {
                                    anyhow::anyhow!(
                                        "Could not read the chosen regular JSON export under 1 MiB"
                                    )
                                })?;
                                let preview = preview_import(&bytes)?;
                                let library = engine.and_then(|engine| {
                                    let guard = engine.try_lock().ok()?;
                                    guard.saved_browser_bookmarks().ok()
                                });
                                let chosen =
                                    preview.bookmark_plan.clone().map(|plan| ChosenBookmarks {
                                        path,
                                        fingerprint: browser_bookmarks::fingerprint(&bytes),
                                        plan,
                                        expected_revision: library
                                            .as_ref()
                                            .map(|library| library.revision),
                                    });
                                library_context_allowed(&admission, &epoch, generation)?;
                                Ok(LibraryReply::Preview(preview, chosen, library))
                            })()
                            .map_err(|error| error.to_string());
                            let _ = sender.send((generation, result));
                        }) {
                            this.import_busy = false;
                            this.status = "Browser preview worker could not start.".into();
                        }
                    }
                    Ok(None) => {
                        this.import_busy = false;
                        this.status = "Import preview cancelled. Nothing was imported.".into();
                    }
                    _ => {
                        this.import_busy = false;
                        this.status = "Could not choose an import preview file.".into();
                    }
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
}
impl Drop for BrowserSettings {
    fn drop(&mut self) {
        self.request_shutdown();
    }
}
impl Render for BrowserSettings {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let busy = self.import_busy
            || self.profile_pending
            || self.history.busy()
            || self.workers.closed();
        let search_engine = self.search_engine_row(cx);
        let mut panel = div()
            .flex()
            .flex_col()
            .gap_2()
            .p_4()
            .child(search_engine)
            .child("Browser profiles");
        if let Some(snapshot) = &self.snapshot {
            panel=panel.child(SharedString::from(format!("{} tab(s) in selected thread. Profile switching requires closing only this thread's tabs.",snapshot.open_tabs)));
            for profile in &snapshot.profiles {
                let id = profile.id;
                panel = panel.child(
                    Button::new(SharedString::from(format!("browser-profile-{id}")))
                        .label(format!(
                            "{}{}",
                            profile.name,
                            if snapshot.selected == ProfileChoice::Persistent(id) {
                                " · selected"
                            } else {
                                ""
                            }
                        ))
                        .disabled(
                            busy || snapshot.open_tabs > 0
                                || (!profile.is_default && !snapshot.persistent_profiles_available),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.request(
                                ProfileOperation::Select(ProfileChoice::Persistent(id)),
                                cx,
                            )
                        })),
                );
            }
            panel = panel.child(
                Button::new("browser-profile-private")
                    .label(if snapshot.selected == ProfileChoice::Private {
                        "Temporary profile · selected"
                    } else {
                        "Use temporary profile for this thread"
                    })
                    .disabled(busy || snapshot.open_tabs > 0)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.request(ProfileOperation::Select(ProfileChoice::Private), cx)
                    })),
            );
        }
        panel = panel
            .child(Input::new(&self.name))
            .child(
                Button::new("browser-profile-create")
                    .label("Create fresh Rust profile")
                    .disabled(
                        busy || self
                            .snapshot
                            .as_ref()
                            .is_none_or(|snapshot| !snapshot.persistent_profiles_available),
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        let name = this.name.read(cx).value().to_string();
                        this.request(ProfileOperation::CreateFresh(name), cx)
                    })),
            )
            .child(
                Button::new("browser-import-preview")
                    .label("Choose metadata export to preview")
                    .disabled(busy || self.snapshot.is_none())
                    .on_click(cx.listener(|this, _, _, cx| this.choose_import(cx))),
            );
        panel = panel.child(Button::new("browser-import-discard").label("Discard import preview").disabled(!self.import_busy && self.preview.is_none()).on_click(cx.listener(|this,_,_,cx| {this.generation=this.generation.wrapping_add(1);this.epoch.store(this.generation,Ordering::Release);this.preview=None;this.chosen=None;this.status="Preview discarded. An existing file dialog may still need to be cancelled.".into();cx.notify();})));
        if let Some(preview) = &self.preview {
            panel=panel.child(SharedString::from(format!("Preview: {} profile reference(s), {} bookmarks, {} history entries; {} cookies will not be imported. {}",preview.profiles,preview.bookmarks,preview.history,preview.cookies_not_imported,if preview.legacy_profile{"Legacy Swift store remains untouched. Create a fresh Rust profile above to start separately."}else{"Source IDs are never reused for a new profile."})));
        }

        if let Some(preview) = &self.preview {
            if let Some(problem) = &preview.bookmark_problem {
                panel = panel.child(SharedString::from(format!(
                    "Bookmarks cannot be saved: {problem}"
                )));
            }
        }
        if let Some(chosen) = &self.chosen {
            let count = chosen.plan.bookmarks.len();
            let page = self.preview_page;
            let pages = count.div_ceil(10);
            let mut review = div()
                .id("browser-bookmark-review")
                .flex()
                .flex_col()
                .gap_1();
            for bookmark in chosen.plan.bookmarks.iter().skip(page * 10).take(10) {
                review = review.child(SharedString::from(format!(
                    "{} · {}",
                    bookmark.title, bookmark.url
                )));
            }
            panel=panel.child(SharedString::from(format!("Review all {count} bookmarks — page {} of {pages}. Save imports every reviewed export row; duplicate URLs keep the saved bookmark.",page+1))).child(review)
                .child(div().flex().gap_2()
                    .child(Button::new("bookmark-preview-prev").label("Previous preview page").disabled(busy||page==0).on_click(cx.listener(|this,_,_,cx|{this.preview_page=this.preview_page.saturating_sub(1);cx.notify();})))
                    .child(Button::new("bookmark-preview-next").label("Next preview page").disabled(busy||page+1>=pages).on_click(cx.listener(|this,_,_,cx|{this.preview_page+=1;cx.notify();}))))
                .child(Button::new("bookmark-import-save").label(format!("Save {count} bookmarks to Rust library")).disabled(busy||self.engine.is_none()||chosen.expected_revision.is_none()).on_click(cx.listener(|this,_,_,cx|this.save_bookmarks(cx))));
        }
        panel = panel.child(
            Button::new("bookmark-library-reload")
                .label("Reload saved Rust bookmarks")
                .disabled(busy || self.engine.is_none() || self.snapshot.is_none())
                .on_click(cx.listener(|this, _, _, cx| this.reload_bookmarks(cx))),
        );
        if let Some(library) = &self.library {
            let count = library.bookmarks.len();
            let page = self.library_page;
            let pages = count.div_ceil(10).max(1);
            panel = panel.child(SharedString::from(format!(
                "Saved Rust bookmarks: {count} · page {} of {pages}",
                page + 1
            )));
            let mut rows = div()
                .id("browser-bookmark-library")
                .flex()
                .flex_col()
                .gap_2();
            for bookmark in library.bookmarks.iter().skip(page * 10).take(10) {
                let id = bookmark.id;
                let revision = library.revision;
                rows = rows.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(SharedString::from(bookmark.title.clone()))
                        .child(SharedString::from(bookmark.url.clone()))
                        .child(
                            Button::new(SharedString::from(format!("bookmark-open-{id}")))
                                .label("Open in this thread's browser")
                                .disabled(busy || self.snapshot.is_none())
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.open_bookmark(id, revision, cx)
                                })),
                        ),
                );
            }
            panel = panel.child(rows).child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        Button::new("bookmark-library-prev")
                            .label("Previous saved page")
                            .disabled(busy || page == 0)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.library_page = this.library_page.saturating_sub(1);
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("bookmark-library-next")
                            .label("Next saved page")
                            .disabled(busy || page + 1 >= pages)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.library_page += 1;
                                cx.notify();
                            })),
                    ),
            );
        }
        panel.child(self.render_history(cx)).child(self.cookie_import_panel(cx)).child(SharedString::from(self.status.clone())).child("Chromium/Safari cookie migration, password CSV import and native passkey ceremonies are unavailable. Closed Firefox snapshot import uses a new unselected profile; imported cookies may grant site access. No account, keychain or Swift store is accessed.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            let root =
                std::env::temp_dir().join(format!("coincide-profile-fixture-{}", Uuid::new_v4()));
            private_directory(&root).unwrap();
            Self(root)
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn request(
        catalog: &ProfileCatalog,
        thread: &str,
        operation: ProfileOperation,
    ) -> ProfileRequest {
        ProfileRequest {
            thread: thread.into(),
            revision: catalog.revision,
            operation,
        }
    }
    #[::core::prelude::v1::test]
    fn fresh_profiles_preserve_default_and_thread_choices_across_restart() {
        let scratch = Scratch::new();
        let original = Uuid::new_v4();
        let mut catalog = ProfileCatalog::open(scratch.0.clone(), Some(original)).unwrap();
        let create = request(
            &catalog,
            "thread-a",
            ProfileOperation::CreateFresh("Work".into()),
        );
        catalog.apply("thread-a", create, 3).unwrap();
        let fresh = catalog.profiles[1].id;
        assert_ne!(fresh, original);
        assert_eq!(
            catalog
                .storage_directory(&ProfileChoice::Persistent(original))
                .unwrap(),
            Some(scratch.0.join("web-context"))
        );
        let select = request(
            &catalog,
            "thread-a",
            ProfileOperation::Select(ProfileChoice::Persistent(fresh)),
        );
        catalog.apply("thread-a", select, 0).unwrap();
        assert_eq!(
            catalog.selected("thread-b"),
            ProfileChoice::Persistent(original)
        );
        let restarted = ProfileCatalog::open(scratch.0.clone(), Some(original)).unwrap();
        assert_eq!(
            restarted.selected("thread-a"),
            ProfileChoice::Persistent(fresh)
        );
        assert!(
            restarted
                .storage_directory(&ProfileChoice::Persistent(fresh))
                .unwrap()
                .unwrap()
                .starts_with(scratch.0.join("profiles").join(fresh.to_string()))
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(scratch.0.join("profiles.json"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
    }
    #[::core::prelude::v1::test]
    fn open_tabs_stale_revision_other_thread_and_duplicate_names_do_not_mutate() {
        let scratch = Scratch::new();
        let mut catalog = ProfileCatalog::open(scratch.0.clone(), None).unwrap();
        let select = request(
            &catalog,
            "thread-a",
            ProfileOperation::Select(ProfileChoice::Private),
        );
        assert!(catalog.apply("thread-a", select, 1).is_err());
        let other = request(
            &catalog,
            "thread-a",
            ProfileOperation::Select(ProfileChoice::Private),
        );
        assert!(catalog.apply("thread-b", other, 0).is_err());
        let stale = request(
            &catalog,
            "thread-a",
            ProfileOperation::Select(ProfileChoice::Private),
        );
        let create = request(
            &catalog,
            "thread-a",
            ProfileOperation::CreateFresh("Work".into()),
        );
        catalog.apply("thread-a", create, 0).unwrap();
        assert!(catalog.apply("thread-a", stale, 0).is_err());
        let duplicate = request(
            &catalog,
            "thread-a",
            ProfileOperation::CreateFresh("work".into()),
        );
        assert!(catalog.apply("thread-a", duplicate, 0).is_err());
        assert_eq!(catalog.profiles.len(), 2);
    }
    #[::core::prelude::v1::test]
    fn private_choice_is_thread_keyed_and_has_no_persistent_directory() {
        let scratch = Scratch::new();
        let mut catalog = ProfileCatalog::open(scratch.0.clone(), None).unwrap();
        let select = request(
            &catalog,
            "thread-a",
            ProfileOperation::Select(ProfileChoice::Private),
        );
        catalog.apply("thread-a", select, 0).unwrap();
        assert_eq!(
            catalog.storage_directory(&ProfileChoice::Private).unwrap(),
            None
        );
        assert_ne!(
            ProfileChoice::Private.key("thread-a"),
            ProfileChoice::Private.key("thread-b")
        );
        assert_eq!(
            ProfileCatalog::open(scratch.0.clone(), None)
                .unwrap()
                .selected("thread-a"),
            ProfileChoice::Private
        );
    }
    #[::core::prelude::v1::test]
    fn legacy_and_export_previews_keep_only_counts_never_reuse_source_id() {
        let original = Uuid::new_v4();
        let bytes=serde_json::to_vec(&json!({"profileID":original,"usesPrivateSessions":true,"bookmarks":[{"title":"synthetic","url":"https://example.test/?private=not-retained"}],"history":[],"cookies":[{"value":"synthetic-only"}]})).unwrap();
        let preview = preview_import(&bytes).unwrap();
        assert_eq!(preview.profiles, 1);
        assert_eq!(preview.bookmarks, 1);
        assert_eq!(preview.cookies_not_imported, 1);
        assert!(preview.legacy_profile);
        let scratch = Scratch::new();
        let mut catalog = ProfileCatalog::open(scratch.0.clone(), None).unwrap();
        let create = request(
            &catalog,
            "thread-a",
            ProfileOperation::CreateFresh("Imported metadata".into()),
        );
        catalog.apply("thread-a", create, 0).unwrap();
        assert!(
            catalog
                .profiles
                .iter()
                .all(|profile| profile.id != original)
        );
        assert!(
            !fs::read_to_string(scratch.0.join("profiles.json"))
                .unwrap()
                .contains("synthetic-only")
        );
    }
    #[::core::prelude::v1::test]
    fn credential_exports_oversize_and_unsupported_documents_are_refused() {
        assert!(preview_import(br#"{"profiles":[{"password":"synthetic-secret"}]}"#).is_err());
        assert!(
            preview_import(br#"{"profiles":[{"nested":{"privateKey":"synthetic-secret"}}]}"#)
                .is_err()
        );
        assert!(preview_import(br#"{"unrelated":true}"#).is_err());
        assert!(preview_import(&vec![b' '; MAX_DOCUMENT as usize + 1]).is_err());
    }
    #[cfg(unix)]
    #[::core::prelude::v1::test]
    fn metadata_and_import_symlinks_are_refused_and_failed_save_rolls_back() {
        use std::os::unix::fs::symlink;
        let scratch = Scratch::new();
        let mut catalog = ProfileCatalog::open(scratch.0.clone(), None).unwrap();
        let original = catalog.profiles.len();
        let outside = scratch.0.join("synthetic-source.json");
        fs::write(&outside, b"{}").unwrap();
        fs::remove_file(scratch.0.join("profiles.json")).unwrap();
        symlink(&outside, scratch.0.join("profiles.json")).unwrap();
        let create = request(
            &catalog,
            "thread-a",
            ProfileOperation::CreateFresh("No write".into()),
        );
        assert!(catalog.apply("thread-a", create, 0).is_err());
        assert_eq!(catalog.profiles.len(), original);
        assert_eq!(fs::read(&outside).unwrap(), b"{}");
        assert!(ProfileCatalog::open(scratch.0.clone(), None).is_err());
        assert!(read_document(&scratch.0.join("profiles.json")).is_err());
    }
    #[::core::prelude::v1::test]
    fn late_or_stale_picker_finishes_custody_without_starting_parser() {
        let mut workers = WorkerOwner::default();
        assert!(workers.begin_picker());
        workers.close();
        assert_eq!(workers.status().pending_pickers, 1);
        assert!(!finish_import_choice(&mut workers, 3, 4));
        assert_eq!(workers.status().pending_pickers, 0);
        assert!(!workers.spawn(|_| panic!("closed chooser must not read metadata file")));
        let mut workers = WorkerOwner::default();
        assert!(workers.begin_picker());
        assert!(!finish_import_choice(&mut workers, 2, 3));
        assert_eq!(workers.status().pending_pickers, 0);
        assert!(workers.begin_picker());
        assert!(finish_import_choice(&mut workers, 3, 3));
    }
    #[::core::prelude::v1::test]
    fn bookmark_save_rechecks_exact_chosen_bytes_and_never_writes_source() {
        let scratch = Scratch::new();
        let path = scratch.0.join("bookmarks.json");
        let source=r#"{"bookmarks":[{"url":"https://example.com/?q=rust#installation","title":"Saved café"}]}"#.as_bytes();
        fs::write(&path, source).unwrap();
        let chosen = ChosenBookmarks {
            path: path.clone(),
            fingerprint: browser_bookmarks::fingerprint(source),
            plan: browser_bookmarks::preview(source).unwrap(),
            expected_revision: Some(0),
        };
        verify_chosen_bookmarks(&chosen).unwrap();
        assert_eq!(fs::read(&path).unwrap(), source);
        fs::write(
            &path,
            br#"{"bookmarks":[{"url":"https://changed.example/","title":"Changed"}]}"#,
        )
        .unwrap();
        let changed = fs::read(&path).unwrap();
        assert!(verify_chosen_bookmarks(&chosen).is_err());
        assert_eq!(fs::read(&path).unwrap(), changed);
        fs::write(&path, vec![b' '; MAX_DOCUMENT as usize + 1]).unwrap();
        assert!(verify_chosen_bookmarks(&chosen).is_err());
    }
    #[cfg(unix)]
    #[::core::prelude::v1::test]
    fn bookmark_save_refuses_a_replaced_symlink_and_keeps_target_untouched() {
        use std::os::unix::fs::symlink;
        let scratch = Scratch::new();
        let path = scratch.0.join("chosen.json");
        let target = scratch.0.join("other.json");
        let bytes = br#"{"bookmarks":[{"url":"https://example.com/","title":"Saved"}]}"#;
        fs::write(&path, bytes).unwrap();
        fs::write(&target, bytes).unwrap();
        let chosen = ChosenBookmarks {
            path: path.clone(),
            fingerprint: browser_bookmarks::fingerprint(bytes),
            plan: browser_bookmarks::preview(bytes).unwrap(),
            expected_revision: Some(0),
        };
        fs::remove_file(&path).unwrap();
        symlink(&target, &path).unwrap();
        assert!(verify_chosen_bookmarks(&chosen).is_err());
        assert_eq!(fs::read(&target).unwrap(), bytes);
    }
    #[::core::prelude::v1::test]
    fn changed_context_or_shutdown_blocks_late_bookmark_worker_admission() {
        for close in [false, true] {
            let mut owner = WorkerOwner::default();
            let epoch = Arc::new(AtomicU64::new(7));
            let (release, gate) = mpsc::sync_channel(0);
            let (send, result) = mpsc::sync_channel(1);
            let checked = epoch.clone();
            assert!(owner.spawn(move |admission| {
                gate.recv().unwrap();
                let allowed = library_context_allowed(&admission, &checked, 7).is_ok();
                send.send(allowed).unwrap();
            }));
            if close {
                owner.close();
            } else {
                epoch.store(8, Ordering::Release);
            }
            release.send(()).unwrap();
            assert!(!result.recv().unwrap());
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            while owner.status().unjoined != 0 {
                assert!(std::time::Instant::now() < deadline);
                std::thread::yield_now();
            }
            assert_eq!(owner.status().panicked, 0);
            assert_eq!(owner.status().returned, 1);
        }
    }
    #[::core::prelude::v1::test]
    fn close_reopen_before_poll_invalidates_old_route_without_repeated_epoch_changes() {
        let epoch = AtomicU64::new(0);
        let mut generation = 0;
        let mut route = None;
        assert!(update_route_epoch(
            &mut route,
            Some("thread"),
            &mut generation,
            &epoch
        ));
        let previous = generation;
        assert!(update_route_epoch(
            &mut route,
            None,
            &mut generation,
            &epoch
        ));
        assert!(update_route_epoch(
            &mut route,
            Some("thread"),
            &mut generation,
            &epoch
        ));
        let mut owner = WorkerOwner::default();
        let (send, receive) = mpsc::sync_channel(1);
        assert!(owner.spawn(move |admission| {
            send.send(library_context_allowed(&admission, &epoch, previous).is_ok())
                .unwrap();
        }));
        assert!(!receive.recv().unwrap());
        let current = generation;
        let epoch = AtomicU64::new(current);
        assert!(!update_route_epoch(
            &mut route,
            Some("thread"),
            &mut generation,
            &epoch
        ));
        assert_eq!(generation, current);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while owner.status().unjoined != 0 {
            assert!(std::time::Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(owner.status().returned, 1);
    }
    #[::core::prelude::v1::test]
    fn fresh_cookie_profile_marker_survives_partial_restart_without_selection_or_other_changes() {
        let scratch = Scratch::new();
        let thread = Uuid::new_v4().to_string();
        let mut catalog = ProfileCatalog::open(scratch.0.clone(), None).unwrap();
        let selected = catalog.snapshot(&thread, 0).selected;
        let before: Value =
            serde_json::from_slice(&fs::read(scratch.0.join("profiles.json")).unwrap()).unwrap();
        let fresh = catalog
            .reserve_cookie_profile(&thread, catalog.revision, "Synthetic cookie destination")
            .unwrap();
        assert_eq!(
            catalog.profiles.len(),
            1,
            "reservation cannot persist a profile"
        );
        catalog.commit_cookie_profile(&thread, &fresh).unwrap();
        assert_eq!(catalog.snapshot(&thread, 0).selected, selected);
        let after: Value =
            serde_json::from_slice(&fs::read(scratch.0.join("profiles.json")).unwrap()).unwrap();
        assert_eq!(after["profiles"][0], before["profiles"][0]);
        assert_eq!(after["threads"], before["threads"]);
        assert_eq!(
            after["profiles"][1]["cookieImport"],
            "incomplete_or_uncertain"
        );
        drop(catalog);
        let mut reopened = ProfileCatalog::open(scratch.0.clone(), None).unwrap();
        assert_eq!(reopened.snapshot(&thread, 0).selected, selected);
        assert_eq!(
            reopened.profiles[1].cookie_import,
            Some(CookieImportMarker::Incomplete)
        );
        reopened.mark_cookie_readback_verified(fresh.id()).unwrap();
        drop(reopened);
        let reopened = ProfileCatalog::open(scratch.0.clone(), None).unwrap();
        assert_eq!(
            reopened.profiles[1].cookie_import,
            Some(CookieImportMarker::ReadbackVerified)
        );
        assert_eq!(reopened.snapshot(&thread, 0).selected, selected);
    }
    #[::core::prelude::v1::test]
    fn stale_cookie_reservation_cannot_append_or_reuse_an_existing_profile() {
        let scratch = Scratch::new();
        let thread = Uuid::new_v4().to_string();
        let mut catalog = ProfileCatalog::open(scratch.0.clone(), None).unwrap();
        let fresh = catalog
            .reserve_cookie_profile(&thread, catalog.revision, "Cookie new")
            .unwrap();
        catalog
            .apply(
                &thread,
                request(
                    &catalog,
                    &thread,
                    ProfileOperation::CreateFresh("Other new".into()),
                ),
                0,
            )
            .unwrap();
        let before = fs::read(scratch.0.join("profiles.json")).unwrap();
        assert!(catalog.commit_cookie_profile(&thread, &fresh).is_err());
        assert_eq!(fs::read(scratch.0.join("profiles.json")).unwrap(), before);
        assert!(
            !catalog
                .profiles
                .iter()
                .any(|profile| profile.id == fresh.id())
        );
        assert!(
            catalog
                .reserve_cookie_profile(&thread, catalog.revision, "Default")
                .is_err()
        );
    }
    #[::core::prelude::v1::test]
    fn cookie_marker_merge_preserves_opaque_existing_profile_top_and_choice_metadata() {
        let scratch = Scratch::new();
        let thread = Uuid::new_v4().to_string();
        let default = Uuid::new_v4();
        let source = json!({"version":1,"futureTop":{"exact":[null,true,"opaque"]},"profiles":[{"id":default.to_string().to_uppercase(),"name":"Existing","default":true,"futureProfile":{"opaque":[7,"keep"]}}],"threads":{thread.clone():default.to_string().to_uppercase()},"threadChoiceMetadata":{thread.clone():{"futureChoice":{"opaque":[true,91]}}}});
        fs::write(
            scratch.0.join("profiles.json"),
            serde_json::to_vec(&source).unwrap(),
        )
        .unwrap();
        let mut catalog = ProfileCatalog::open(scratch.0.clone(), Some(default)).unwrap();
        let fresh = catalog
            .reserve_cookie_profile(&thread, 0, "New cookie profile")
            .unwrap();
        catalog.commit_cookie_profile(&thread, &fresh).unwrap();
        catalog.mark_cookie_readback_verified(fresh.id()).unwrap();
        let after: Value =
            serde_json::from_slice(&fs::read(scratch.0.join("profiles.json")).unwrap()).unwrap();
        for key in ["futureTop", "threads", "threadChoiceMetadata"] {
            assert_eq!(after[key], source[key]);
        }
        assert_eq!(after["profiles"][0], source["profiles"][0]);
        assert_eq!(after["profiles"][1]["cookieImport"], "readback_verified");
    }
    #[::core::prelude::v1::test]
    fn future_version_or_malformed_choice_refuses_without_rewriting_source() {
        let scratch = Scratch::new();
        let id = Uuid::new_v4();
        let thread = Uuid::new_v4().to_string();
        for source in [
            json!({"version":2,"profiles":[{"id":id,"name":"Existing","default":true}],"future":{"keep":true}}),
            json!({"version":1,"profiles":[{"id":id,"name":"Existing","default":true}],"threads":{thread.clone():{"profile":id,"futureChoice":"opaque"}}}),
            json!({"version":1,"profiles":[{"id":id,"name":"Existing","default":true}],"threads":["future unsupported shape"]}),
        ] {
            let bytes = serde_json::to_vec(&source).unwrap();
            let path = scratch.0.join("profiles.json");
            fs::write(&path, &bytes).unwrap();
            assert!(ProfileCatalog::open(scratch.0.clone(), Some(id)).is_err());
            assert_eq!(fs::read(path).unwrap(), bytes);
        }
    }
}

#[cfg(test)]
mod private_runtime_directory_tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn private_native_runtime_generations_never_reopen_persisted_profile_or_previous_root() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("owned-browser");
        coincide_core::native_file::private_directory(&root).unwrap();
        let catalog = ProfileCatalog::open(root.clone(), None).unwrap();
        let one = catalog.new_private_runtime_directory().unwrap();
        fs::write(one.join("synthetic-native-residue"), b"synthetic only").unwrap();
        let two = catalog.new_private_runtime_directory().unwrap();
        assert_ne!(one, two);
        assert!(one.starts_with(&root) && two.starts_with(&root));
        assert!(!two.join("synthetic-native-residue").exists());
        assert_eq!(
            catalog.storage_directory(&ProfileChoice::Private).unwrap(),
            None
        );
        assert_eq!(
            fs::read(one.join("synthetic-native-residue")).unwrap(),
            b"synthetic only"
        );
        coincide_core::native_file::private_directory(&one).unwrap();
        coincide_core::native_file::private_directory(&two).unwrap();
    }
}
