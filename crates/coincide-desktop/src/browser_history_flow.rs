//! Reviewed, profile-bound history import using the existing owned worker lane.
use super::*;
use coincide_core::browser_history::{self, Library as HistoryLibrary, Plan as HistoryPlan};

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct Binding {
    pub snapshot: ProfileSnapshot,
    pub active: Option<String>,
    pub tabs: Vec<(String, u64)>,
}
impl Binding {
    pub fn profile(&self) -> Result<Uuid> {
        match &self.snapshot.selected {
            ProfileChoice::Persistent(id) => Ok(*id),
            ProfileChoice::Private => {
                anyhow::bail!("Private browser history is not saved or imported")
            }
        }
    }
    pub fn require_destination(&self, current: &Self, thread: &str, profile: Uuid) -> Result<()> {
        ensure!(
            self.snapshot.thread == thread && self.profile()? == profile && self == current,
            "Browser profile, tab or page changed; click Open again"
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn binding() -> Binding {
        let id = Uuid::new_v4();
        Binding {
            snapshot: ProfileSnapshot {
                thread: Uuid::new_v4().to_string(),
                revision: 0,
                profiles: vec![ProfileMetadata {
                    id,
                    name: "Synthetic".into(),
                    is_default: true,
                    cookie_import: None,
                }],
                selected: ProfileChoice::Persistent(id),
                open_tabs: 1,
                persistent_profiles_available: true,
            },
            active: Some("tab-one".into()),
            tabs: vec![("tab-one".into(), 3)],
        }
    }
    fn plan() -> HistoryPlan {
        browser_history::preview(r#"{"history":[{"url":"https://example.test/","title":"Synthetic café","visitCount":2,"lastVisit":0,"future":{"keep":true}}]}"#.as_bytes()).unwrap()
    }
    #[::core::prelude::v1::test]
    fn same_count_tab_replacement_navigation_profile_and_route_changes_revoke_review() {
        let original = binding();
        let profile = original.profile().unwrap();
        original
            .require_destination(&original, &original.snapshot.thread, profile)
            .unwrap();
        let mut state = State::default();
        assert!(state.set_binding(Some(original.clone())));
        let epoch = state.generation;
        let mut changed = original.clone();
        changed.tabs[0].1 += 1;
        assert!(
            original
                .require_destination(&changed, &original.snapshot.thread, profile)
                .is_err()
        );
        state.chosen = Some(Chosen::new(PathBuf::from("not-read"), plan(), 0).unwrap());
        assert!(state.set_binding(Some(changed)));
        assert!(state.chosen.is_none() && state.generation != epoch);
        let mut changed = original.clone();
        changed.active = Some("other".into());
        assert!(
            original
                .require_destination(&changed, &original.snapshot.thread, profile)
                .is_err()
        );
        assert!(state.set_binding(Some(changed)));
        let mut changed = original.clone();
        changed.tabs[0].0 = "replacement".into();
        assert!(
            original
                .require_destination(&changed, &original.snapshot.thread, profile)
                .is_err()
        );
        assert!(state.set_binding(Some(changed)));
        let mut changed = original;
        changed.snapshot.selected = ProfileChoice::Private;
        assert!(
            changed
                .require_destination(&changed, &changed.snapshot.thread, profile)
                .is_err()
        );
        assert!(changed.profile().is_err());
        state.set_binding(Some(changed));
        assert!(!state.reload);
        state.set_binding(None);
        assert!(state.binding.is_none());
    }
    #[::core::prelude::v1::test]
    fn chosen_history_bytes_are_reverified_and_changed_or_symlinked_source_is_not_committed() {
        let root =
            std::env::temp_dir().join(format!("coincide-history-fixture-{}", Uuid::new_v4()));
        private_directory(&root).unwrap();
        let path = root.join("export.json");
        let bytes=br#"{"history":[{"url":"https://example.test/","title":"Synthetic","visitCount":1,"lastVisit":0}]}"#;
        fs::write(&path, bytes).unwrap();
        let chosen =
            Chosen::new(path.clone(), browser_history::preview(bytes).unwrap(), 0).unwrap();
        verify(&chosen).unwrap();
        assert_eq!(fs::read(&path).unwrap(), bytes);
        fs::write(&path, br#"{"history":[]}"#).unwrap();
        assert!(verify(&chosen).is_err());
        fs::remove_file(&path).unwrap();
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(root.join("missing"), &path).unwrap();
            assert!(verify(&chosen).is_err());
            fs::remove_file(&path).unwrap();
        }
        fs::remove_dir_all(root).unwrap();
    }
    #[::core::prelude::v1::test]
    fn review_uses_cached_display_rows_and_shares_the_exact_reviewed_plan() {
        let chosen = Chosen::new(PathBuf::from("not-read"), plan(), 4).unwrap();
        let copy = chosen.clone();
        assert!(Arc::ptr_eq(&chosen.plan, &copy.plan));
        assert!(Arc::ptr_eq(&chosen.rows, &copy.rows));
        assert_eq!(chosen.rows[0].title, "Synthetic café");
        assert_eq!(chosen.rows[0].last_visit, "2001-01-01 00:00 UTC");
        assert_eq!(chosen.plan.history[0]["future"], json!({"keep":true}));
    }
    #[::core::prelude::v1::test]
    fn revoked_service_work_has_no_commit_and_retains_actual_join_custody() {
        use std::time::{Duration, Instant};
        let mut state = State::default();
        state.set_binding(Some(binding()));
        let epoch = state.epoch.clone();
        let generation = state.generation;
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (result_tx, result_rx) = mpsc::channel();
        let effects = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let calls = effects.clone();
        assert!(state.workers.spawn(move |admission| {
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            let result = allowed(&admission, &epoch, generation);
            if result.is_ok() {
                calls.fetch_add(1, Ordering::SeqCst);
            }
            result_tx.send(result.is_err()).unwrap();
        }));
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        state.set_binding(None);
        state.close();
        assert_eq!(state.shutdown_status().unjoined, 1);
        release_tx.send(()).unwrap();
        assert!(result_rx.recv_timeout(Duration::from_secs(5)).unwrap());
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if state.shutdown_status().unjoined == 0 {
                break;
            }
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(effects.load(Ordering::SeqCst), 0);
        assert_eq!(state.shutdown_status().returned, 1);
        assert!(!state.workers.spawn(|_| panic!("closed history worker")));
    }
}
#[derive(Clone)]
struct Chosen {
    path: PathBuf,
    plan: Arc<HistoryPlan>,
    rows: Arc<Vec<browser_history::RecordView>>,
    revision: u64,
}
impl Chosen {
    fn new(path: PathBuf, plan: HistoryPlan, revision: u64) -> Result<Self> {
        let rows = plan
            .history
            .iter()
            .map(browser_history::record_view)
            .collect::<Result<Vec<_>>>()?;
        Ok(Self {
            path,
            plan: Arc::new(plan),
            rows: Arc::new(rows),
            revision,
        })
    }
}
struct SavedRow {
    id: Uuid,
    view: browser_history::RecordView,
}
struct Loaded {
    revision: u64,
    rows: Vec<SavedRow>,
}
impl Loaded {
    fn new(library: HistoryLibrary) -> Result<Self> {
        let rows = library
            .history
            .into_iter()
            .map(|entry| {
                Ok(SavedRow {
                    id: entry.id,
                    view: browser_history::record_view(&entry.record)?,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Self {
            revision: library.revision,
            rows,
        })
    }
}
fn verify(chosen: &Chosen) -> Result<()> {
    let bytes = read_document(&chosen.path).map_err(|_| {
        anyhow::anyhow!("Chosen history export is unavailable; choose and review it again")
    })?;
    ensure!(
        browser_bookmarks::fingerprint(&bytes) == chosen.plan.fingerprint,
        "History export changed after review; nothing imported"
    );
    chosen.plan.validate()
}
pub(crate) struct Open {
    pub binding: Binding,
    pub prepared: coincide_core::api::PreparedHistoryOpen,
}
enum Reply {
    Preview(Chosen, Loaded),
    Loaded(Loaded),
    Saved {
        library: Loaded,
        added: usize,
        duplicates: usize,
    },
    Open(Open),
}
pub(super) struct State {
    workers: WorkerOwner,
    epoch: Arc<AtomicU64>,
    generation: u64,
    binding: Option<Binding>,
    pending: bool,
    reload: bool,
    chosen: Option<Chosen>,
    library: Option<Loaded>,
    preview_page: usize,
    library_page: usize,
    open: Option<Open>,
    sender: SyncSender<(u64, Result<Reply, String>)>,
    receiver: Receiver<(u64, Result<Reply, String>)>,
    status: String,
}
impl Default for State {
    fn default() -> Self {
        let (sender, receiver) = mpsc::sync_channel(1);
        Self {
            workers: WorkerOwner::default(),
            epoch: Arc::new(AtomicU64::new(0)),
            generation: 0,
            binding: None,
            pending: false,
            reload: false,
            chosen: None,
            library: None,
            preview_page: 0,
            library_page: 0,
            open: None,
            sender,
            receiver,
            status: "Select a persistent browser profile to load its saved history.".into(),
        }
    }
}
impl State {
    pub fn busy(&self) -> bool {
        self.pending
    }
    pub fn set_binding(&mut self, binding: Option<Binding>) -> bool {
        if self.binding == binding {
            return false;
        }
        self.generation = self.generation.wrapping_add(1);
        self.epoch.store(self.generation, Ordering::Release);
        self.binding = binding;
        self.chosen = None;
        self.library = None;
        self.open = None;
        self.preview_page = 0;
        self.library_page = 0;
        self.reload = self
            .binding
            .as_ref()
            .is_some_and(|binding| binding.profile().is_ok());
        self.status = if self.reload {
            "Loading this profile's saved history…"
        } else {
            "Private or closed browser history is not saved or imported."
        }
        .into();
        true
    }
    pub fn close(&mut self) {
        self.workers.close();
        self.set_binding(None);
        self.reload = false;
        while self.receiver.try_recv().is_ok() {}
    }
    pub fn shutdown_status(&mut self) -> WorkerOwnerStatus {
        if self.workers.closed() {
            while self.receiver.try_recv().is_ok() {}
        }
        self.workers.status()
    }
}
fn allowed(
    admission: &crate::worker_owner::Admission,
    epoch: &AtomicU64,
    generation: u64,
) -> Result<()> {
    library_context_allowed(admission, epoch, generation)
}
impl BrowserSettings {
    pub(crate) fn set_history_binding(&mut self, binding: Option<Binding>, cx: &mut Context<Self>) {
        if self.history.set_binding(binding) {
            cx.notify();
        }
    }
    pub(crate) fn take_history_open(&mut self) -> Option<Open> {
        self.history.open.take()
    }
    pub(crate) fn history_open_error(&mut self, error: String, cx: &mut Context<Self>) {
        self.history.status = error;
        cx.notify();
    }
    fn history_work(
        &mut self,
        status: &str,
        cx: &mut Context<Self>,
        work: impl FnOnce(
            SharedEngine,
            crate::worker_owner::Admission,
            Arc<AtomicU64>,
            u64,
            Binding,
        ) -> Result<Reply>
        + Send
        + 'static,
    ) {
        if self.import_busy
            || self.profile_pending
            || self.history.pending
            || !self.history.workers.can_start()
        {
            return;
        }
        let (Some(engine), Some(binding)) = (self.engine.clone(), self.history.binding.clone())
        else {
            return;
        };
        if let Err(error) = binding.profile() {
            self.history.status = error.to_string();
            cx.notify();
            return;
        }
        self.history.pending = true;
        self.history.status = status.into();
        let generation = self.history.generation;
        let epoch = self.history.epoch.clone();
        let sender = self.history.sender.clone();
        if !self.history.workers.spawn(move |admission| {
            let result = work(engine, admission, epoch, generation, binding)
                .map_err(|error| error.to_string());
            let _ = sender.send((generation, result));
        }) {
            self.history.pending = false;
            self.history.status = "History worker could not start.".into();
        }
        cx.notify();
    }
    fn history_reload(&mut self, cx: &mut Context<Self>) {
        self.history_work(
            "Loading this profile's saved history…",
            cx,
            |engine, admission, epoch, generation, binding| {
                allowed(&admission, &epoch, generation)?;
                let guard = engine
                    .try_lock()
                    .map_err(|_| anyhow::anyhow!("App is busy; reload history to try again"))?;
                allowed(&admission, &epoch, generation)?;
                ensure!(
                    guard.active_thread() == Some(binding.snapshot.thread.as_str()),
                    "Conversation changed; reload history"
                );
                let library = guard.saved_browser_history(binding.profile()?)?;
                drop(guard);
                Ok(Reply::Loaded(Loaded::new(library)?))
            },
        );
    }
    fn history_save(&mut self, cx: &mut Context<Self>) {
        let Some(chosen) = self.history.chosen.clone() else {
            return;
        };
        self.history_work(
            "Saving only the reviewed history…",
            cx,
            move |engine, admission, epoch, generation, binding| {
                allowed(&admission, &epoch, generation)?;
                verify(&chosen)?;
                let mut guard = engine
                    .try_lock()
                    .map_err(|_| anyhow::anyhow!("App is busy; saved history was not changed"))?;
                allowed(&admission, &epoch, generation)?;
                let result = guard.import_browser_history(
                    &binding.snapshot.thread,
                    binding.profile()?,
                    chosen.revision,
                    &chosen.plan,
                )?;
                drop(guard);
                Ok(Reply::Saved {
                    library: Loaded::new(result.library)?,
                    added: result.added,
                    duplicates: result.duplicates,
                })
            },
        );
    }
    fn history_open(&mut self, id: Uuid, revision: u64, cx: &mut Context<Self>) {
        self.history_work(
            "Preparing the selected saved history entry…",
            cx,
            move |engine, admission, epoch, generation, binding| {
                allowed(&admission, &epoch, generation)?;
                let guard = engine
                    .try_lock()
                    .map_err(|_| anyhow::anyhow!("App is busy; history was not opened"))?;
                allowed(&admission, &epoch, generation)?;
                let prepared = guard.prepare_browser_history(
                    &binding.snapshot.thread,
                    binding.profile()?,
                    id,
                    revision,
                )?;
                Ok(Reply::Open(Open { binding, prepared }))
            },
        );
    }
    fn history_choose(&mut self, cx: &mut Context<Self>) {
        if self.import_busy
            || self.profile_pending
            || self.history.pending
            || self.engine.is_none()
            || self
                .history
                .binding
                .as_ref()
                .is_none_or(|binding| binding.profile().is_err())
            || !self.history.workers.begin_picker()
        {
            return;
        }
        self.history.pending = true;
        self.history.generation = self.history.generation.wrapping_add(1);
        self.history
            .epoch
            .store(self.history.generation, Ordering::Release);
        self.history.chosen = None;
        self.history.open = None;
        let generation = self.history.generation;
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Review browser history metadata JSON".into()),
        });
        cx.spawn(async move |this, cx| {
            let selected: Result<_> = async { picker.await? }.await;
            let _ = this.update(cx, |this, cx| {
                let fresh =
                    this.history.workers.finish_picker() && this.history.generation == generation;
                this.history.pending = false;
                if !fresh {
                    this.history.status =
                        "History selection discarded after a profile, tab or conversation change."
                            .into();
                    cx.notify();
                    return;
                }
                match selected {
                    Ok(Some(paths)) if paths.len() == 1 => {
                        let path = paths[0].clone();
                        this.history_work(
                            "Reading the chosen history export…",
                            cx,
                            move |engine, admission, epoch, generation, binding| {
                                allowed(&admission, &epoch, generation)?;
                                let bytes = read_document(&path).map_err(|_| {
                                    anyhow::anyhow!(
                                        "Choose a regular metadata JSON file under 1 MiB"
                                    )
                                })?;
                                let plan = browser_history::preview(&bytes)?;
                                let guard = engine.try_lock().map_err(|_| {
                                    anyhow::anyhow!("App is busy; choose the history export again")
                                })?;
                                allowed(&admission, &epoch, generation)?;
                                ensure!(
                                    guard.active_thread() == Some(binding.snapshot.thread.as_str()),
                                    "Conversation changed; choose the export again"
                                );
                                let library = guard.saved_browser_history(binding.profile()?)?;
                                drop(guard);
                                let chosen = Chosen::new(path, plan, library.revision)?;
                                Ok(Reply::Preview(chosen, Loaded::new(library)?))
                            },
                        );
                    }
                    Ok(None) => {
                        this.history.status =
                            "History file selection cancelled. Nothing imported.".into();
                    }
                    _ => {
                        this.history.status = "Could not choose a history export.".into();
                    }
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    pub(super) fn poll_history(&mut self, cx: &mut Context<Self>) {
        self.history.workers.poll();
        if self.history.workers.closed() {
            while self.history.receiver.try_recv().is_ok() {}
            return;
        }
        while let Ok((generation, result)) = self.history.receiver.try_recv() {
            self.history.pending = false;
            if generation == self.history.generation {
                match result {
                    Ok(Reply::Preview(chosen, library)) => {
                        self.history.chosen = Some(chosen);
                        self.history.library = Some(library);
                        self.history.preview_page = 0;
                        self.history.status="Review the destination profile and every entry before importing. No page will open.".into();
                    }
                    Ok(Reply::Loaded(library)) => {
                        if let Some(chosen) = self.history.chosen.as_mut() {
                            chosen.revision = library.revision;
                        }
                        self.history.library = Some(library);
                        self.history.library_page = 0;
                        self.history.status =
                            "Saved history loaded. Source files are unchanged.".into();
                    }
                    Ok(Reply::Saved {
                        library,
                        added,
                        duplicates,
                    }) => {
                        self.history.status = format!(
                            "Saved {} history entries; {} duplicate URLs kept their existing saved entry. No page opened.",
                            added, duplicates
                        );
                        self.history.library = Some(library);
                        self.history.library_page = 0;
                        self.history.chosen = None;
                    }
                    Ok(Reply::Open(open)) => {
                        self.history.open = Some(open);
                        self.history.status = "Opening only the selected saved URL…".into();
                    }
                    Err(error) => {
                        self.history.status = error;
                        self.history.chosen = None;
                        self.history.library = None;
                    }
                }
            }
            cx.notify();
        }
        let status = self.history.workers.status();
        if self.history.pending && status.unjoined == 0 && status.pending_pickers == 0 {
            self.history.pending = false;
            self.history.chosen = None;
            self.history.status =
                "History worker ended without a result. Reload before trying again.".into();
            cx.notify();
        }
        if self.history.reload
            && !self.history.pending
            && !self.import_busy
            && !self.profile_pending
            && self.engine.is_some()
            && self.history.workers.can_start()
        {
            self.history.reload = false;
            self.history_reload(cx);
        }
    }
    pub(super) fn render_history(&self, cx: &mut Context<Self>) -> AnyElement {
        let busy = self.import_busy
            || self.profile_pending
            || self.history.pending
            || self.history.workers.closed();
        let enabled = self.engine.is_some()
            && self
                .history
                .binding
                .as_ref()
                .is_some_and(|binding| binding.profile().is_ok());
        let destination = self
            .history
            .binding
            .as_ref()
            .and_then(|binding| {
                binding.profile().ok().and_then(|id| {
                    binding
                        .snapshot
                        .profiles
                        .iter()
                        .find(|profile| profile.id == id)
                        .map(|profile| profile.name.clone())
                })
            })
            .unwrap_or_else(|| "No persistent profile".into());
        let mut panel=div().flex().flex_col().gap_2().child("Browser history").child(format!("Destination: {destination}")).child("Import history from a browser metadata JSON export. Existing history is kept; cookies, passwords and browser databases are not imported.")
            .child(Button::new("history-import-choose").label("Choose history metadata export").disabled(busy||!enabled).on_click(cx.listener(|this,_,_,cx|this.history_choose(cx))))
            .child(Button::new("history-library-reload").label("Reload saved history").disabled(busy||!enabled).on_click(cx.listener(|this,_,_,cx|this.history_reload(cx))))
            .child(SharedString::from(self.history.status.clone()));
        if let Some(chosen) = &self.history.chosen {
            let count = chosen.rows.len();
            let pages = count.div_ceil(10).max(1);
            let page = self.history.preview_page.min(pages - 1);
            panel = panel.child(format!(
                "Review {count} history entries for {destination} — page {} of {pages}",
                page + 1
            ));
            for view in chosen.rows.iter().skip(page * 10).take(10) {
                panel = panel.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(view.title.clone())
                        .child(view.url.clone())
                        .child(format!("{} visits · {}", view.visit_count, view.last_visit)),
                );
            }
            panel = panel
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .child(
                            Button::new("history-preview-prev")
                                .label("Previous review page")
                                .disabled(busy || page == 0)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.history.preview_page =
                                        this.history.preview_page.saturating_sub(1);
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new("history-preview-next")
                                .label("Next review page")
                                .disabled(busy || page + 1 >= pages)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.history.preview_page += 1;
                                    cx.notify();
                                })),
                        ),
                )
                .child(
                    Button::new("history-import-save")
                        .label(format!(
                            "Import all {count} reviewed history entries into {destination}"
                        ))
                        .disabled(busy || !enabled)
                        .on_click(cx.listener(|this, _, _, cx| this.history_save(cx))),
                )
                .child(
                    Button::new("history-import-discard")
                        .label("Discard history review")
                        .disabled(busy)
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.history.chosen = None;
                            this.history.status =
                                "History review discarded. Nothing imported.".into();
                            cx.notify();
                        })),
                );
        }
        if let Some(library) = &self.history.library {
            let count = library.rows.len();
            let pages = count.div_ceil(10).max(1);
            let page = self.history.library_page.min(pages - 1);
            panel = panel.child(format!(
                "Saved history in {destination}: {count} · page {} of {pages}",
                page + 1
            ));
            for entry in library.rows.iter().skip(page * 10).take(10) {
                let view = &entry.view;
                let id = entry.id;
                let revision = library.revision;
                panel = panel.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(view.title.clone())
                        .child(view.url.clone())
                        .child(format!("{} visits · {}", view.visit_count, view.last_visit))
                        .child(
                            Button::new(SharedString::from(format!("history-open-{id}")))
                                .label("Open this saved URL in a new tab")
                                .disabled(busy || !enabled)
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.history_open(id, revision, cx)
                                })),
                        ),
                );
            }
            panel = panel.child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        Button::new("history-library-prev")
                            .label("Previous saved history page")
                            .disabled(busy || page == 0)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.history.library_page =
                                    this.history.library_page.saturating_sub(1);
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("history-library-next")
                            .label("Next saved history page")
                            .disabled(busy || page + 1 >= pages)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.history.library_page += 1;
                                cx.notify();
                            })),
                    ),
            );
        }
        panel.into_any_element()
    }
}
