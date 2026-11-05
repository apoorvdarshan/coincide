//! Persistent native-only cookie workflow. Typed source/cleanup ownership never
//! travels through control JSON or the generic string-error bookmark transport.
use super::*;
use coincide_core::firefox_cookie_import::{
    self as core_cookie, ApprovedPlan, Binding, CleanupCustody, NativeSource, Plan,
};
use std::{collections::BTreeSet, sync::Mutex};
#[derive(Clone)]
pub(crate) struct ImportContext {
    pub(crate) snapshot: ProfileSnapshot,
    pub(crate) epoch: Arc<AtomicU64>,
    pub(crate) generation: u64,
}
impl ImportContext {
    pub(crate) fn valid(&self) -> bool {
        self.epoch.load(Ordering::Acquire) == self.generation
    }
    pub(crate) fn binding(&self, profile: Uuid) -> Option<Binding> {
        Some(Binding {
            thread: Uuid::parse_str(&self.snapshot.thread).ok()?,
            profile,
            epoch: self.generation,
        })
    }
}
pub(crate) struct ReserveRequest {
    pub(crate) context: ImportContext,
    pub(crate) name: String,
    pub(crate) hosts: Vec<String>,
}
pub(crate) struct Reservation {
    pub(crate) context: ImportContext,
    pub(crate) fresh: FreshCookieProfile,
    pub(crate) hosts: Vec<String>,
}
pub(crate) struct PreparedImport {
    pub(crate) reservation: Reservation,
    pub(crate) cookies: ApprovedPlan,
}
#[derive(Clone, Default, PartialEq, Eq)]
pub(crate) struct ImportStatus {
    pub(crate) profile: Option<Uuid>,
    pub(crate) name: String,
    pub(crate) revision: u64,
    pub(crate) thread: String,
    pub(crate) generation: u64,
    pub(crate) applied: usize,
    pub(crate) undispatched: usize,
    pub(crate) expired: usize,
    pub(crate) refused: usize,
    pub(crate) verified: usize,
    pub(crate) pending: bool,
    pub(crate) message: String,
}
enum Completion {
    Parsed(u64, std::result::Result<Plan, String>),
    Approved(u64, std::result::Result<PreparedImport, String>),
}
#[derive(Default)]
pub(crate) struct Flow {
    workers: WorkerOwner,
    cleanup_workers: WorkerOwner,
    mailbox: Arc<Mutex<Option<Completion>>>,
    cleanup: Arc<Mutex<Vec<Box<CleanupCustody>>>>,
    epoch: Arc<AtomicU64>,
    context: Option<ImportContext>,
    plan: Option<Plan>,
    selected: BTreeSet<String>,
    page: usize,
    busy: bool,
    reserve: Option<ReserveRequest>,
    prepared: Option<PreparedImport>,
    destination: Option<Uuid>,
    pub(crate) status: ImportStatus,
}
fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_secs().min(i64::MAX as u64) as i64)
        .unwrap_or(0)
}
fn keep_failure(error: core_cookie::Failure, cleanup: &Mutex<Vec<Box<CleanupCustody>>>) -> String {
    match error {
        core_cookie::Failure::CleanupPending(custody) => {
            cleanup
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(custody);
            "Private cookie snapshot cleanup is pending. Retry cleanup before closing.".into()
        }
        error => error.to_string(),
    }
}
trait CleanupWork {
    fn retry_owned(&mut self) -> bool;
}
impl CleanupWork for Box<CleanupCustody> {
    fn retry_owned(&mut self) -> bool {
        self.retry()
    }
}
fn retry_owned<T: CleanupWork>(owners: &mut Vec<T>) {
    owners.retain_mut(|owner| !owner.retry_owned());
}
impl Flow {
    pub(crate) fn route_changed(&mut self) {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        self.context = None;
        self.plan = None;
        self.selected.clear();
        self.reserve = None;
        self.prepared = None;
        self.destination = None;
        if self.workers.status().unjoined == 0
            && self
                .mailbox
                .try_lock()
                .is_ok_and(|mailbox| mailbox.is_none())
        {
            self.busy = false;
        }
        if self.status.pending {
            self.status.message="Import context closed. Further cookies will not be dispatched; existing native work remains owned.".into();
        }
    }
    pub(crate) fn set_snapshot(&mut self, next: Option<ProfileSnapshot>) {
        if self.workers.closed() {
            return;
        }
        let same = self.context.as_ref().map(|context| {
            (
                &context.snapshot.thread,
                context.snapshot.revision,
                &context.snapshot.selected,
            )
        }) == next
            .as_ref()
            .map(|snapshot| (&snapshot.thread, snapshot.revision, &snapshot.selected));
        if same {
            return;
        }
        self.route_changed();
        self.context = next.map(|snapshot| ImportContext {
            snapshot,
            epoch: self.epoch.clone(),
            generation: self.epoch.load(Ordering::Acquire),
        });
    }
    pub(crate) fn poll(&mut self) {
        self.workers.poll();
        self.cleanup_workers.poll();
        let completion = self
            .mailbox
            .try_lock()
            .ok()
            .and_then(|mut mailbox| mailbox.take());
        if let Some(completion) = completion {
            self.busy = false;
            match completion {
                Completion::Parsed(generation, result) => match result {
                    Ok(plan) if self.current(generation) => {
                        self.plan = Some(plan);
                        self.selected.clear();
                        self.page = 0;
                        self.status.message="Review exact hosts and counts, then explicitly import into a new unselected profile.".into();
                    }
                    Ok(_) => {}
                    Err(error) => self.status.message = error,
                },
                Completion::Approved(generation, result) => match result {
                    Ok(prepared) if self.current(generation) => self.prepared = Some(prepared),
                    Ok(_) => {}
                    Err(error) => self.status.message = error,
                },
            }
        }
        let status = self.workers.status();
        if status.closed
            && status.unjoined == 0
            && status.pending_pickers == 0
            && !self.busy
            && self.cleanup_count() == 0
        {
            self.cleanup_workers.close();
        }
    }
    fn current(&self, generation: u64) -> bool {
        !self.workers.closed()
            && self
                .context
                .as_ref()
                .is_some_and(|context| context.valid() && context.generation == generation)
    }
    fn cleanup_count(&self) -> usize {
        self.cleanup
            .try_lock()
            .map(|owners| owners.len())
            .unwrap_or(1)
    }
    pub(crate) fn retry_cleanup(&mut self) {
        // Dedicated owner stays open for cleanup after general admissions close.
        // Capture only shared custody; failed thread creation cannot drop owners.
        let cleanup = self.cleanup.clone();
        self.cleanup_workers.spawn(move |_| {
            retry_owned(
                &mut cleanup
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner),
            );
        });
    }
    pub(crate) fn close(&mut self) {
        if self.workers.close() {
            self.route_changed();
        }
        self.poll();
    }
    pub(crate) fn shutdown_status(&mut self) -> WorkerOwnerStatus {
        self.poll();
        let mut status = self.workers.status();
        let other = self.cleanup_workers.status();
        status.closed &= other.closed;
        status.unjoined += other.unjoined;
        status.returned += other.returned;
        status.panicked += other.panicked;
        status.unclassified += other.unclassified
            + self.cleanup_count()
            + usize::from(self.busy)
            + usize::from(self.prepared.is_some() || self.reserve.is_some());
        status.pending_pickers += other.pending_pickers;
        if status.spawn_error.is_none() {
            status.spawn_error = other.spawn_error;
        }
        status
    }
    fn parse(&mut self, path: PathBuf, generation: u64) {
        if !self.current(generation) {
            return;
        }
        let mailbox = self.mailbox.clone();
        let cleanup = self.cleanup.clone();
        let epoch = self.epoch.clone();
        self.busy = true;
        if !self.workers.spawn(move |admission| {
            let result = if admission.allowed() && epoch.load(Ordering::Acquire) == generation {
                Plan::read(NativeSource::from_native_choice(path), now())
                    .map_err(|error| keep_failure(error, &cleanup))
            } else {
                Err("Cookie preview cancelled before source read.".into())
            };
            *mailbox
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) =
                Some(Completion::Parsed(generation, result));
        }) {
            self.busy = false;
            self.status.message = "Cookie preview worker could not start.".into();
        }
    }
    fn request_import(&mut self, name: String) {
        if self.busy
            || self.cleanup_count() != 0
            || self.plan.is_none()
            || self.selected.is_empty()
            || self.status.pending
            || self.workers.closed()
        {
            return;
        }
        let Some(context) = self.context.clone().filter(ImportContext::valid) else {
            return;
        };
        self.reserve = Some(ReserveRequest {
            context,
            name,
            hosts: self.selected.iter().cloned().collect(),
        });
        self.busy = true;
        self.status.message =
            "Preparing a new unselected destination. No cookies dispatched.".into();
    }
    pub(crate) fn reservation_result(&mut self, result: std::result::Result<Reservation, String>) {
        let reservation = match result {
            Ok(reservation) => reservation,
            Err(error) => {
                self.busy = false;
                self.status.message = error;
                return;
            }
        };
        if !self.current(reservation.context.generation) {
            return;
        }
        let Some(plan) = self.plan.take() else { return };
        let hosts = reservation.hosts.clone();
        self.destination = Some(reservation.fresh.id());
        let Some(binding) = reservation.context.binding(reservation.fresh.id()) else {
            return;
        };
        let generation = reservation.context.generation;
        let mailbox = self.mailbox.clone();
        let cleanup = self.cleanup.clone();
        self.busy = true;
        if !self.workers.spawn(move |admission| {
            let result = if admission.allowed() && reservation.context.valid() {
                plan.approve(&hosts, binding)
                    .map(|cookies| PreparedImport {
                        reservation,
                        cookies,
                    })
                    .map_err(|error| keep_failure(error, &cleanup))
            } else {
                Err("Cookie approval cancelled before source recheck.".into())
            };
            *mailbox
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) =
                Some(Completion::Approved(generation, result));
        }) {
            self.busy = false;
            self.status.message =
                "Cookie approval worker could not start. Choose the source again.".into();
        }
    }
    pub(crate) fn accept_status(&mut self, status: ImportStatus) {
        // Acknowledges only this actor's fresh profile creation/marker update;
        // ordinary snapshot reconciliation still revokes unrelated changes.
        if let Some(context) = self.context.as_mut()
            && status.profile == self.destination
            && status.profile.is_some()
            && context.generation == status.generation
            && context.snapshot.thread == status.thread
            && status.revision >= context.snapshot.revision
        {
            context.snapshot.revision = status.revision;
        }
        self.status = status;
    }
}
impl BrowserSettings {
    pub(crate) fn take_cookie_reservation_request(&mut self) -> Option<ReserveRequest> {
        self.cookie_flow.reserve.take()
    }
    pub(crate) fn cookie_reservation_result(
        &mut self,
        result: std::result::Result<Reservation, String>,
        cx: &mut Context<Self>,
    ) {
        self.cookie_flow.reservation_result(result);
        cx.notify();
    }
    pub(crate) fn take_prepared_cookie_import(&mut self) -> Option<PreparedImport> {
        self.cookie_flow.prepared.take()
    }
    pub(crate) fn set_cookie_import_error(&mut self, error: String, cx: &mut Context<Self>) {
        self.cookie_flow.busy = false;
        self.cookie_flow.status.message = error;
        cx.notify();
    }
    pub(crate) fn set_cookie_import_status(
        &mut self,
        status: ImportStatus,
        cx: &mut Context<Self>,
    ) {
        if self.cookie_flow.status != status {
            self.cookie_flow.accept_status(status);
            cx.notify();
        }
    }
    fn choose_cookie_source(&mut self, cx: &mut Context<Self>) {
        self.cookie_flow.poll();
        if !cfg!(target_os = "macos")
            || self.cookie_flow.context.is_none()
            || self.cookie_flow.status.pending
            || !self.cookie_flow.workers.begin_picker()
        {
            return;
        }
        let generation = self
            .cookie_flow
            .context
            .as_ref()
            .map(|context| context.generation)
            .unwrap_or(0);
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Choose closed Firefox cookie snapshot".into()),
        });
        cx.spawn(async move |this, cx| {
            let result = picker.await;
            let _ = this.update(cx, |this, cx| {
                let allowed = this.cookie_flow.workers.finish_picker();
                if allowed && this.cookie_flow.current(generation) {
                    match result {
                        Ok(Some(paths)) if paths.len() == 1 => {
                            this.cookie_flow.parse(paths[0].clone(), generation)
                        }
                        _ => {
                            this.cookie_flow.status.message =
                                "Cookie selection cancelled; nothing imported.".into()
                        }
                    }
                }
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }
    pub(super) fn cookie_import_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        let flow = &self.cookie_flow;
        let disabled = !cfg!(target_os = "macos")
            || flow.workers.closed()
            || flow.busy
            || flow.status.pending
            || flow.cleanup_count() != 0;
        let mut view=div().flex().flex_col().gap_2().child("Firefox cookies — closed snapshot only")
            .child("Choose a standalone cookies.sqlite with no WAL/SHM/journal. Only reviewed ordinary cookies are supported; other browser storage and partitioned sessions are not imported.")
            .child(Button::new("cookie-choose").label("Choose cookie snapshot").disabled(disabled||flow.context.is_none()).on_click(cx.listener(|this,_,_,cx|this.choose_cookie_source(cx))));
        if let Some(plan) = &flow.plan {
            let preview = plan.preview();
            let pages = preview.hosts.len().div_ceil(10).max(1);
            let page = flow.page.min(pages - 1);
            view = view.child(format!(
                "{} host(s); {} expired, {} unsupported. Host page {}/{}",
                preview.hosts.len(),
                preview.expired,
                preview.unsupported,
                page + 1,
                pages
            ));
            for row in preview.hosts.iter().skip(page * 10).take(10) {
                let host = row.host.clone();
                let chosen = flow.selected.contains(&host);
                view = view.child(
                    Button::new(SharedString::from(format!("cookie-host-{host}")))
                        .label(format!(
                            "{} {} — {} cookie(s)",
                            if chosen { "Selected" } else { "Select" },
                            host,
                            row.cookies
                        ))
                        .disabled(disabled)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if !this.cookie_flow.selected.remove(&host) {
                                this.cookie_flow.selected.insert(host.clone());
                            }
                            cx.notify();
                        })),
                );
            }
            view = view.child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        Button::new("cookie-prev")
                            .label("Previous hosts")
                            .disabled(page == 0)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.cookie_flow.page = this.cookie_flow.page.saturating_sub(1);
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("cookie-next")
                            .label("Next hosts")
                            .disabled(page + 1 >= pages)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.cookie_flow.page += 1;
                                cx.notify();
                            })),
                    ),
            );
            view=view.child("Destination uses the new profile name above, remains unselected, and may contain a partial import. No page opens automatically.")
                .child(Button::new("cookie-import").label("Import selected hosts into NEW profile").disabled(disabled||flow.selected.is_empty()).on_click(cx.listener(|this,_,_,cx|{let name=this.name.read(cx).value().to_string();this.cookie_flow.request_import(name);cx.notify();})));
        }
        if flow.cleanup_count() != 0 {
            view = view.child(
                Button::new("cookie-retry-cleanup")
                    .label("Retry private snapshot cleanup")
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.cookie_flow.retry_cleanup();
                        cx.notify();
                    })),
            );
        }
        if !flow.status.name.is_empty() {
            view=view.child(format!("New unselected profile: {} · callback-stored {} · readback-matched {} · expired {} · refused {} · undispatched {}",flow.status.name,flow.status.applied,flow.status.verified,flow.status.expired,flow.status.refused,flow.status.undispatched));
        }
        view.child(flow.status.message.clone()).child("Per-cookie operations are not atomic. Callback completion and readback do not prove disk persistence; interrupted profiles remain marked incomplete/uncertain and never resume automatically.").into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn snapshot() -> ProfileSnapshot {
        ProfileSnapshot {
            thread: Uuid::new_v4().to_string(),
            revision: 0,
            profiles: Vec::new(),
            selected: ProfileChoice::Private,
            open_tabs: 0,
            persistent_profiles_available: true,
        }
    }
    fn synthetic_plan() -> Plan {
        let path = std::env::temp_dir().join(format!(
            "coincide-cookie-flow-test-{}.sqlite",
            Uuid::new_v4()
        ));
        // Build only fixed SQLite bytes via the already-tested core fixture
        // format; no real browser profiles or credentials are accessed.
        let seed = include_bytes!("../tests/fixtures/firefox-cookie-flow.sqlite");
        fs::write(&path, seed).unwrap();
        let plan = Plan::read(NativeSource::from_native_choice(path.clone()), 1).unwrap();
        fs::remove_file(path).unwrap();
        plan
    }
    #[::core::prelude::v1::test]
    fn close_reopen_before_poll_discards_typed_late_preview_and_reservation() {
        let mut flow = Flow::default();
        let snap = snapshot();
        flow.set_snapshot(Some(snap.clone()));
        let old = flow.context.as_ref().unwrap().clone();
        flow.route_changed();
        flow.set_snapshot(Some(snap));
        assert!(!old.valid());
        assert!(flow.context.as_ref().unwrap().valid());
        *flow.mailbox.lock().unwrap() =
            Some(Completion::Parsed(old.generation, Ok(synthetic_plan())));
        flow.poll();
        assert!(flow.plan.is_none());
        assert!(flow.reserve.is_none());
        assert!(flow.prepared.is_none());
    }
    #[::core::prelude::v1::test]
    fn explicit_import_captures_reviewed_hosts_and_stale_status_cannot_ack_revision() {
        let mut flow = Flow::default();
        flow.set_snapshot(Some(snapshot()));
        flow.plan = Some(synthetic_plan());
        flow.selected.insert("example.test".into());
        flow.request_import("New synthetic profile".into());
        let request = flow.reserve.take().unwrap();
        flow.selected.clear();
        assert_eq!(request.hosts, vec!["example.test"]);
        let original = flow.context.as_ref().unwrap().clone();
        let destination = Uuid::new_v4();
        flow.destination = Some(destination);
        flow.accept_status(ImportStatus {
            profile: Some(destination),
            thread: Uuid::new_v4().to_string(),
            generation: original.generation,
            revision: 99,
            ..Default::default()
        });
        assert_eq!(flow.context.as_ref().unwrap().snapshot.revision, 0);
        flow.accept_status(ImportStatus {
            profile: Some(destination),
            thread: original.snapshot.thread.clone(),
            generation: original.generation,
            revision: 1,
            ..Default::default()
        });
        assert_eq!(flow.context.as_ref().unwrap().snapshot.revision, 1);
        let mut own_snapshot = original.snapshot;
        own_snapshot.revision = 1;
        flow.set_snapshot(Some(own_snapshot));
        assert!(original.valid());
        flow.route_changed();
        flow.set_snapshot(Some(snapshot()));
        let current = flow.context.as_ref().unwrap().generation;
        flow.accept_status(ImportStatus {
            profile: Some(destination),
            thread: request.context.snapshot.thread,
            generation: request.context.generation,
            revision: 100,
            ..Default::default()
        });
        assert_eq!(flow.context.as_ref().unwrap().generation, current);
        assert_eq!(flow.context.as_ref().unwrap().snapshot.revision, 0);
    }
    #[::core::prelude::v1::test]
    fn cleanup_only_worker_retains_failed_identity_after_general_close_and_waits_actual_join() {
        struct FakeOwned {
            id: u64,
            allow: Arc<std::sync::atomic::AtomicBool>,
        }
        impl CleanupWork for FakeOwned {
            fn retry_owned(&mut self) -> bool {
                self.allow.load(Ordering::Acquire)
            }
        }
        struct ExitGate(std::sync::mpsc::Receiver<()>);
        impl Drop for ExitGate {
            fn drop(&mut self) {
                self.0.recv().unwrap();
            }
        }
        let allow = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let owners = Arc::new(Mutex::new(vec![FakeOwned {
            id: 17,
            allow: allow.clone(),
        }]));
        let mut general = WorkerOwner::default();
        general.close();
        let mut cleanup = WorkerOwner::default();
        let (release, gate) = mpsc::sync_channel(0);
        let (sent, done) = mpsc::sync_channel(0);
        let held = owners.clone();
        assert!(cleanup.spawn(move |_| {
            let _exit = ExitGate(gate);
            retry_owned(&mut held.lock().unwrap());
            sent.send(()).unwrap();
        }));
        done.recv().unwrap();
        assert_eq!(owners.lock().unwrap()[0].id, 17);
        assert_eq!(cleanup.status().unjoined, 1);
        release.send(()).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while cleanup.status().unjoined != 0 {
            assert!(std::time::Instant::now() < deadline);
            std::thread::yield_now();
        }
        allow.store(true, Ordering::Release);
        let held = owners.clone();
        assert!(cleanup.spawn(move |_| retry_owned(&mut held.lock().unwrap())));
        while cleanup.status().unjoined != 0 {
            assert!(std::time::Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert!(owners.lock().unwrap().is_empty());
        assert!(general.status().closed);
        assert_eq!(cleanup.status().returned, 2);
    }
}
