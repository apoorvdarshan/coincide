//! Native profiles, metadata preview and explicit saved bookmark import. No cookies,
//! passwords, keys, login grants or original Swift website stores are imported.
use crate::worker_owner::{ShutdownStatus as WorkerOwnerStatus, WorkerOwner};
use anyhow::{Result, ensure};
use coincide_core::{
    api::SharedEngine,
    browser_bookmarks::{self, Library, Plan},
};
use gpui_kit::{
    AppContext, Context, Entity, InteractiveElement, IntoElement, ParentElement, PathPromptOptions,
    Render, ScrollHandle, SharedString, Styled, Window,
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
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProfileMetadata {
    pub id: Uuid,
    pub name: String,
    pub is_default: bool,
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
            }
        } else {
            Self {
                root,
                revision: 0,
                profiles: vec![ProfileMetadata {
                    id: legacy_rust_default.unwrap_or_else(Uuid::new_v4),
                    name: "Default".into(),
                    is_default: true,
                }],
                selections: BTreeMap::new(),
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
        let threads: BTreeMap<_, _> = self
            .selections
            .iter()
            .map(|(thread, choice)| {
                (
                    thread,
                    match choice {
                        ProfileChoice::Private => "private".into(),
                        ProfileChoice::Persistent(id) => id.to_string(),
                    },
                )
            })
            .collect();
        let value = json!({"version":1,"profiles":self.profiles.iter().map(|p|json!({"id":p.id,"name":p.name,"default":p.is_default})).collect::<Vec<_>>(),"threads":threads});
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
pub struct BrowserSettings {
    workers: WorkerOwner,
    form_scroll: ScrollHandle,
    engine: Option<SharedEngine>,
    epoch: Arc<AtomicU64>,
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
}
impl BrowserSettings {
    pub fn request_shutdown(&mut self) {
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
        self.workers.status()
    }
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> (Self, Receiver<ProfileRequest>) {
        let name = cx.new(|cx| InputState::new(window, cx).placeholder("New Rust profile name"));
        let (sender, requests) = mpsc::sync_channel(8);
        let (import_sender, imports) = mpsc::sync_channel(1);
        (
            Self {
                workers: WorkerOwner::default(),
                form_scroll: ScrollHandle::default(),
                engine: None,
                epoch: Arc::new(AtomicU64::new(0)),
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
        if self.import_busy || self.profile_pending || !self.workers.can_start() {
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
    pub fn set_snapshot(&mut self, snapshot: Option<ProfileSnapshot>, cx: &mut Context<Self>) {
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
        if self.import_busy || self.profile_pending || !self.workers.begin_picker() {
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
        let busy = self.import_busy || self.profile_pending || self.workers.closed();
        let mut panel = div()
            .flex()
            .flex_col()
            .gap_2()
            .p_4()
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
        panel.child(SharedString::from(self.status.clone())).child("Cookie/keychain migration, password CSV import, native passkey enrollment/assertion and Bitwarden passkey ceremonies are not implemented in this Rust settings slice. Only explicit Save imports validated bookmarks. Profile, history, cookie and credential data are not imported; no account or keychain is accessed.")
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
}

#[cfg(test)]
mod shutdown_tests {
    use super::*;
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
}
