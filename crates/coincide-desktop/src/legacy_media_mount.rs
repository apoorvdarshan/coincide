//! Parent-owned native image display and explicit durable receipt handoff.
//! No media path is opened here; source/copy/verification remains on the service
//! worker. GPUI images are built from verified encoded bytes on a worker too.
use super::*;
#[path = "legacy_media_visibility.rs"]
mod visibility;
use coincide_core::legacy_media_service::{
    ReceiptId, SelectionToken, ServiceConfig, ValidatedRenderEntry,
};
use std::collections::HashSet;

struct DisplayImage {
    item: String,
    candidate: String,
    name: String,
    image: Arc<Image>,
}
struct RenderRequest {
    thread: String,
    generation: u64,
    revision: u64,
    selection: SelectionToken,
    entries: Arc<Vec<ValidatedRenderEntry>>,
    failures: Vec<String>,
}
struct FreshnessCheck {
    epoch: u64,
    request: RenderRequest,
    snapshot: Value,
}
type FreshnessResult = (u64, Result<(Value, Vec<DisplayImage>)>);
pub(super) struct ParentMedia {
    pub opened: bool,
    pub close_requested: bool,
    pub shutdown_requested: bool,
    panel: Entity<legacy_media_settings::LegacyMediaSettingsPanel>,
    owner: legacy_media_recovery::ParentRecoveryOwner,
    source: Option<Value>,
    revision: u64,
    draft_pending: bool,
    context: Option<(Option<String>, u64, Vec<String>)>,
    images: Vec<DisplayImage>,
    layout_visibility: visibility::CompletedLayout,
    layout_sequence: std::rc::Rc<std::cell::Cell<u64>>,
    viewer: historical_image_view::Viewer,
    viewer_focus: FocusHandle,
    viewer_restore: Option<FocusHandle>,
    status: String,
    epoch: u64,
    pending_render: Option<RenderRequest>,
    freshness: Option<FreshnessCheck>,
    freshness_task: Option<Task<()>>,
    freshness_error: Option<String>,
    recovery_stop_requested: bool,
    owner_shutdown_requested: bool,
    shutdown_handoffs: HashSet<ReceiptId>,
    sender: std::sync::mpsc::SyncSender<FreshnessResult>,
    receiver: std::sync::mpsc::Receiver<FreshnessResult>,
    service_acknowledged: HashSet<ReceiptId>,
    _events: Subscription,
}
impl ParentMedia {
    pub fn new(config: ServiceConfig, window: &mut Window, cx: &mut Context<Coincide>) -> Self {
        let panel = cx.new(|cx| {
            legacy_media_settings::LegacyMediaSettingsPanel::new(config.clone(), window, cx)
        });
        let owner = legacy_media_recovery::ParentRecoveryOwner::spawn(config);
        let events = cx.subscribe(&panel, |this, _, event, cx| this.media_event(event, cx));
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        Self {
            opened: false,
            close_requested: false,
            shutdown_requested: false,
            panel,
            owner,
            source: None,
            revision: 0,
            draft_pending: false,
            context: None,
            images: Vec::new(),
            layout_visibility: visibility::CompletedLayout::default(),
            layout_sequence: std::rc::Rc::new(std::cell::Cell::new(0)),
            viewer: historical_image_view::Viewer::default(),
            viewer_focus: cx.focus_handle(),
            viewer_restore: None,
            status: String::new(),
            epoch: 0,
            pending_render: None,
            freshness: None,
            freshness_task: None,
            freshness_error: None,
            recovery_stop_requested: false,
            owner_shutdown_requested: false,
            shutdown_handoffs: HashSet::new(),
            sender,
            receiver,
            service_acknowledged: HashSet::new(),
            _events: events,
        }
    }
}
fn snapshot_current(
    thread: &Value,
    captured: &Value,
    id: &str,
    revision: u64,
    current_revision: u64,
    draft_pending: bool,
) -> bool {
    !draft_pending && revision == current_revision && thread["id"] == id && thread == captured
}
fn row_intersects(row: Bounds<Pixels>, viewport: Bounds<Pixels>) -> bool {
    viewport.size.height > px(0.)
        && viewport.size.width > px(0.)
        && row.bottom() > viewport.top()
        && row.top() < viewport.bottom()
        && row.right() > viewport.left()
        && row.left() < viewport.right()
}
pub(super) struct MediaOwnerShutdownStatus {
    pub requested: bool,
    pub service: coincide_core::legacy_media_service::ServiceShutdownStatus,
    pub panel_inflight: bool,
    pub panel_retained: usize,
    pub recovery_pending: usize,
    pub recovery_worker: coincide_core::agent::WorkerThreadStatus,
    pub freshness_pending: bool,
    pub error: Option<String>,
}
impl MediaOwnerShutdownStatus {
    pub fn ready(&self) -> bool {
        self.requested
            && self.service.ready()
            && !self.panel_inflight
            && self.panel_retained == 0
            && self.recovery_pending == 0
            && self.recovery_worker == coincide_core::agent::WorkerThreadStatus::Returned
            && !self.freshness_pending
            && self.error.is_none()
    }
}
impl Coincide {
    pub(super) fn request_media_owner_shutdown(&mut self, cx: &mut Context<Self>) {
        self.media.shutdown_requested = true;
        if !self.media.owner_shutdown_requested {
            self.media.owner_shutdown_requested = true;
            self.invalidate_media_images(cx);
        }
        self.media.pending_render = None;
        self.sync_media_context(cx);
        self.media
            .panel
            .update(cx, |panel, _| panel.request_service_shutdown());
        self.poll_media_parent(cx);
    }
    pub(super) fn poll_media_owner_shutdown(
        &mut self,
        cx: &mut Context<Self>,
    ) -> MediaOwnerShutdownStatus {
        self.poll_media_parent(cx);
        if self.media.shutdown_requested && !self.media.recovery_stop_requested {
            // Start each retained receipt handoff only once. Existing failed/unknown
            // writes remain pending; shutdown never automatically replays them.
            let receipts = self.media.panel.read(cx).retained_receipts();
            let pending = self
                .media
                .owner
                .pending_receipts()
                .into_iter()
                .map(|(id, _)| id)
                .collect::<HashSet<_>>();
            for (id, receipt) in receipts {
                if self.media.owner.durable_ownership(id).is_some() {
                    self.acknowledge_media_ownership(id, cx);
                } else if !pending.contains(&id)
                    && self.media.shutdown_handoffs.insert(id)
                    && let Err(error) = self.media.owner.take_ownership(id, receipt)
                {
                    self.media.status =
                        format!("Media recovery handoff remains pending: {error:?}");
                }
            }
            let panel = self.media.panel.read(cx);
            if panel.service_shutdown_status().ready()
                && self
                    .media
                    .owner
                    .shutdown_ready(panel.has_in_flight_work(), panel.retained_receipts().len())
            {
                match self.media.owner.request_worker_shutdown() {
                    Ok(()) => self.media.recovery_stop_requested = true,
                    Err(error) => {
                        self.media.freshness_error = Some(format!(
                            "Media recovery worker shutdown is unconfirmed: {error:?}"
                        ))
                    }
                }
            }
        }
        let panel = self.media.panel.read(cx);
        MediaOwnerShutdownStatus {
            requested: self.media.owner_shutdown_requested,
            service: panel.service_shutdown_status(),
            panel_inflight: panel.has_in_flight_work(),
            panel_retained: panel.retained_receipts().len(),
            recovery_pending: self.media.owner.pending_receipts().len(),
            recovery_worker: self.media.owner.worker_shutdown_status(),
            freshness_pending: self.media.freshness_task.is_some()
                || self.media.freshness.is_some()
                || self.media.pending_render.is_some(),
            error: self.media.freshness_error.clone(),
        }
    }
    pub(super) fn media_settings_visible(&self) -> bool {
        self.settings_open
            && self.media.opened
            && !self.bots_open
            && !self.notifications_open
            && !self.transcription_open
            && !self.credentials_open
            && !self.browser_settings_open
            && !self.provider_settings.open
            && !self.session_import_open
    }
    fn remove_media_images(&mut self, cx: &mut Context<Self>) {
        self.media.viewer.close();
        if self.media.shutdown_requested || self.media.close_requested {
            self.media.viewer_restore = None;
        }
        let ids = self
            .media
            .images
            .iter()
            .map(|image| image.item.clone())
            .collect::<HashSet<_>>();
        for image in self.media.images.drain(..) {
            image.image.remove_asset(cx);
        }
        if let Some(thread) = &self.selected {
            for id in ids {
                if let Some(index) = thread["items"]
                    .as_array()
                    .and_then(|items| items.iter().position(|item| item["id"] == id))
                {
                    self.transcript_list.splice(index..index + 1, 1);
                }
            }
        }
        cx.notify();
    }
    fn invalidate_media_images(&mut self, cx: &mut Context<Self>) {
        self.media.layout_visibility.clear();
        self.remove_media_images(cx);
        self.media.epoch = self.media.epoch.wrapping_add(1);
        self.media.pending_render = None;
        cx.notify();
    }
    pub(super) fn sync_media_context(&mut self, cx: &mut Context<Self>) {
        let draft_pending = self
            .selected
            .as_ref()
            .is_some_and(|thread| self.pending_drafts.contains_key(&text(thread, "id")));
        if self.media.source != self.selected || self.media.draft_pending != draft_pending {
            let Some(revision) = self.media.revision.checked_add(1) else {
                self.media.status =
                    "Historical image display revision exhausted; restart before continuing."
                        .into();
                self.media.panel.update(cx, |panel, cx| {
                    panel.set_context(None, u64::MAX, vec![], cx)
                });
                return;
            };
            self.media.revision = revision;
            self.media.source = self.selected.clone();
            self.media.draft_pending = draft_pending;
            self.invalidate_media_images(cx);
        }
        let stopping = self.media.close_requested || self.media.shutdown_requested;
        let thread = (!stopping)
            .then(|| self.selected.as_ref().map(|thread| text(thread, "id")))
            .flatten();
        // A splice deliberately makes ListState rows temporarily unmeasured.
        // Only a completed actual list layout can change the visible IDs.
        let layout_binding = self.media_layout_binding(cx);
        self.media.layout_visibility.set_context(layout_binding);
        let visible = self.media.layout_visibility.visible();
        let context = (thread, self.media.revision, visible);
        if self.media.context.as_ref() != Some(&context) {
            self.media.context = Some(context.clone());
            self.media.panel.update(cx, |panel, cx| {
                panel.set_context(context.0, context.1, context.2, cx)
            });
        }
    }
    fn media_layout_binding(&self, cx: &App) -> Option<visibility::Binding> {
        if self.media.close_requested
            || self.media.shutdown_requested
            || !self.find_context_available()
            || self.command_palette.read(cx).is_open()
            || self.media.draft_pending
            || self.media.source != self.selected
        {
            return None;
        }
        let thread = self.selected.as_ref()?.get("id")?.as_str()?;
        if self.pending_drafts.contains_key(thread) {
            return None;
        }
        Some(visibility::Binding {
            thread: thread.to_owned(),
            revision: self.media.revision,
            epoch: self.media.epoch,
        })
    }
    /// Capture the exact child prepaint identity, then defer both geometry
    /// sampling and parent mutation until its actual paint and borrows finish.
    pub(super) fn media_layout_observer(
        &self,
        cx: &mut Context<Self>,
    ) -> impl Fn(Vec<Bounds<Pixels>>, &mut Window, &mut App) + 'static {
        let binding = self.media_layout_binding(cx);
        let list = self.transcript_list.clone();
        let parent = cx.entity().downgrade();
        let sequence = self.media.layout_sequence.clone();
        move |_, _, cx| {
            let Some(binding) = binding.clone() else {
                return;
            };
            let next = sequence.get().checked_add(1);
            if let Some(next) = next {
                sequence.set(next);
            }
            let Some(layout_token) = list.prepaint_layout_token() else {
                return;
            };
            let list = list.clone();
            let parent = parent.clone();
            cx.defer(move |cx| {
                let _ = parent.update(cx, |this, cx| {
                    let current = this.media_layout_binding(cx);
                    this.media.layout_visibility.set_context(current.clone());
                    if current.as_ref() != Some(&binding) {
                        return;
                    }
                    // A transaction may have abandoned this callback's prepaint,
                    // or another frame may have superseded it. Only this exact
                    // still-current, actually painted pass authorizes geometry.
                    if !list.is_completed_layout(&layout_token) {
                        return;
                    }
                    let visible_indices = match (
                        list.completed_layout_visible_range(),
                        list.completed_layout_viewport_bounds(),
                    ) {
                        (Some(range), Some(viewport)) => range
                            .take(200)
                            .filter(|index| {
                                list.completed_layout_bounds_for_item(*index)
                                    .is_some_and(|row| row_intersects(row, viewport))
                            })
                            .take(20)
                            .collect::<Vec<_>>(),
                        _ => return,
                    };
                    // Resolve actual painted indices only after the complete
                    // source/thread/revision/epoch and layout-token checks.
                    let visible = this
                        .selected
                        .as_ref()
                        .and_then(|thread| thread["items"].as_array())
                        .map(|items| {
                            visible_indices
                                .iter()
                                .filter_map(|index| items.get(*index))
                                .map(|item| text(item, "id"))
                                .collect()
                        })
                        .unwrap_or_default();
                    let changed = if let Some(next) = next {
                        this.media
                            .layout_visibility
                            .complete(&binding, next, visible)
                    } else {
                        this.media.layout_visibility.clear();
                        true
                    };
                    if changed {
                        this.sync_media_context(cx);
                        cx.notify();
                    }
                });
            });
        }
    }
    fn start_media_freshness_check(&mut self, cx: &mut Context<Self>) {
        if self.media.close_requested
            || self.media.shutdown_requested
            || self.media.freshness.is_some()
            || self.media.freshness_task.is_some()
        {
            return;
        }
        let Some(request) = self.media.pending_render.take() else {
            return;
        };
        let Some(snapshot) = self.media.source.clone() else {
            return;
        };
        if !self.selected.as_ref().is_some_and(|thread| {
            snapshot_current(
                thread,
                &snapshot,
                &request.thread,
                request.revision,
                self.media.revision,
                self.pending_drafts.contains_key(&request.thread),
            )
        }) || !request
            .selection
            .accepts(&request.thread, request.generation)
        {
            return;
        }
        let epoch = self.media.epoch;
        let engine = self.engine.clone();
        let sender = self.media.sender.clone();
        let thread = request.thread.clone();
        let entries = request.entries.clone();
        self.media.freshness_task = Some(cx.background_executor().spawn(async move {
            let result = (|| -> Result<(Value, Vec<DisplayImage>)> {
                // Existing loaded-thread metadata only. No media/legacy path IO
                // and no Engine lock while decoding or hashing image data.
                let current =
                    coincide_core::api::call(&engine, "threads.read", json!({"threadId":thread}))?;
                let mut images = Vec::new();
                let mut seen = HashSet::new();
                for entry in entries.iter().take(8) {
                    if !seen.insert((entry.item_id.clone(), entry.candidate_id.clone())) {
                        continue;
                    }
                    let format = match entry.image.mime_type.as_str() {
                        "image/png" => ImageFormat::Png,
                        "image/jpeg" => ImageFormat::Jpeg,
                        _ => anyhow::bail!(
                            "Verified historical image has an unsupported normalized format"
                        ),
                    };
                    images.push(DisplayImage {
                        item: entry.item_id.clone(),
                        candidate: entry.candidate_id.clone(),
                        name: entry.image.original_name.clone(),
                        image: Arc::new(Image::from_bytes(
                            format,
                            entry.normalized_bytes.as_ref().clone(),
                        )),
                    });
                }
                Ok((current, images))
            })();
            let _ = sender.send((epoch, result));
        }));
        self.media.freshness = Some(FreshnessCheck {
            epoch,
            request,
            snapshot,
        });
    }
    fn acknowledge_media_ownership(&mut self, id: ReceiptId, cx: &mut Context<Self>) {
        let Some(token) = self.media.owner.durable_ownership(id).cloned() else {
            self.media.status =
                "The recovery receipt is not saved yet; no acknowledgment was made.".into();
            return;
        };
        if !self.media.service_acknowledged.contains(&id) {
            let receipt = self
                .media
                .panel
                .read(cx)
                .retained_receipts()
                .into_iter()
                .find(|(receipt_id, _)| *receipt_id == id)
                .map(|(_, receipt)| receipt);
            let Some(receipt) = receipt else {
                self.media.status =
                    "Recovery ownership needs reconciliation; the service receipt is unavailable."
                        .into();
                return;
            };
            if !token.matches(id, &receipt) {
                self.media.status =
                    "Recovery receipt changed; both owners were retained without acknowledgment."
                        .into();
                return;
            }
            if let Err(error) = self
                .media
                .panel
                .update(cx, |panel, cx| panel.acknowledge_reconciled(id, cx))
            {
                self.media.status = format!(
                    "Recovery is saved, but service acknowledgment is pending: {error}. Retry saved acknowledgments."
                );
                return;
            }
            self.media.service_acknowledged.insert(id);
        }
        match self.media.owner.acknowledged(id, &token) {
            Ok(()) => {
                self.media.service_acknowledged.remove(&id);
                self.media.status = "Recovery receipt saved and ownership acknowledged.".into();
            }
            Err(error) => {
                self.media.status = format!(
                    "Recovery is saved, but parent acknowledgment is pending: {error:?}. Retry saved acknowledgments."
                )
            }
        }
        cx.notify();
    }
    fn media_event(
        &mut self,
        event: &legacy_media_settings::LegacyMediaSettingsEvent,
        cx: &mut Context<Self>,
    ) {
        use legacy_media_settings::LegacyMediaSettingsEvent as E;
        self.sync_media_context(cx);
        match event {
            E::ImagesInvalidated {
                thread_id,
                source_revision,
            } => {
                if self
                    .selected
                    .as_ref()
                    .is_some_and(|thread| thread["id"] == *thread_id)
                    && *source_revision == self.media.revision
                {
                    self.invalidate_media_images(cx);
                }
            }
            E::ImagesReady {
                thread_id,
                generation,
                source_revision,
                selection,
                entries,
                failures,
            } => {
                if self.media.close_requested || self.media.shutdown_requested {
                    return;
                }
                if self
                    .selected
                    .as_ref()
                    .is_none_or(|thread| thread["id"] != *thread_id)
                    || *source_revision != self.media.revision
                    || !selection.accepts(thread_id, *generation)
                    || self.pending_drafts.contains_key(thread_id)
                {
                    return;
                }
                self.media.pending_render = Some(RenderRequest {
                    thread: thread_id.clone(),
                    generation: *generation,
                    revision: *source_revision,
                    selection: selection.clone(),
                    entries: entries.clone(),
                    failures: failures
                        .iter()
                        .map(|failure| format!("{}: {}", failure.candidate_id, failure.error))
                        .collect(),
                });
                self.start_media_freshness_check(cx);
            }
            E::OverlayRestored { thread_id } => {
                if self
                    .selected
                    .as_ref()
                    .is_some_and(|thread| thread["id"] == *thread_id)
                {
                    self.invalidate_media_images(cx);
                    self.media.context = None;
                    self.sync_media_context(cx);
                }
            }
            E::RecoveryOwnershipRequested {
                receipt_id,
                receipt,
            } => {
                if self.media.owner.durable_ownership(*receipt_id).is_some() {
                    self.acknowledge_media_ownership(*receipt_id, cx);
                } else {
                    self.media.status=match self.media.owner.take_ownership(*receipt_id,receipt.clone()) {
                        Ok(())=>"Saving the recovery receipt. The panel still owns it until storage confirms success.".into(),
                        Err(error)=>format!("Recovery receipt remains retained: {error:?}. Retry this same receipt when ready."),
                    };
                }
                cx.notify();
            }
        }
    }
    pub(super) fn poll_media_parent(&mut self, cx: &mut Context<Self>) {
        for _ in 0..8 {
            let Some(outcome) = self.media.owner.poll() else {
                break;
            };
            match outcome.result {
                Ok(_) => self.acknowledge_media_ownership(outcome.receipt_id, cx),
                Err(error) => {
                    self.media.status = format!(
                        "Recovery was not durably saved: {error:?}. Receipt and images remain retained; retry the same handoff explicitly."
                    );
                    cx.notify();
                }
            }
        }
        if let Ok((epoch, result)) = self.media.receiver.try_recv()
            && let Some(check) = self.media.freshness.take()
            && epoch == check.epoch
            && epoch == self.media.epoch
        {
            match result {
                Ok((stored, images)) => {
                    let valid = !self.media.close_requested
                        && !self.media.shutdown_requested
                        && self.selected.as_ref().is_some_and(|thread| {
                            snapshot_current(
                                thread,
                                &check.snapshot,
                                &check.request.thread,
                                check.request.revision,
                                self.media.revision,
                                self.pending_drafts.contains_key(&check.request.thread),
                            )
                        })
                        && stored == check.snapshot
                        && check
                            .request
                            .selection
                            .accepts(&check.request.thread, check.request.generation);
                    if valid {
                        self.remove_media_images(cx);
                        self.media.images = images;
                        self.media.status = if check.request.failures.is_empty() {
                            "Verified historical images are available for local display only."
                                .into()
                        } else {
                            format!(
                                "Some historical images are unavailable: {}",
                                check.request.failures.join("; ")
                            )
                        };
                        let ids = self
                            .media
                            .images
                            .iter()
                            .map(|image| image.item.clone())
                            .collect::<HashSet<_>>();
                        if let Some(thread) = &self.selected {
                            for id in ids {
                                if let Some(index) = find_row(thread, &check.request.thread, &id) {
                                    self.transcript_list.splice(index..index + 1, 1);
                                }
                            }
                        }
                        cx.notify();
                    } else {
                        self.invalidate_media_images(cx);
                        if self
                            .selected
                            .as_ref()
                            .is_some_and(|thread| thread["id"] == check.request.thread)
                            && !self.pending_drafts.contains_key(&check.request.thread)
                            && stored != check.snapshot
                        {
                            let count = stored["items"].as_array().map_or(0, Vec::len);
                            self.transcript_list.splice(0..self.transcript_count, count);
                            self.transcript_count = count;
                            self.selected = Some(stored);
                            self.sync_media_context(cx);
                        }
                        self.media.status="Conversation snapshot changed; stale historical images were discarded.".into();
                    }
                }
                Err(error) => {
                    self.invalidate_media_images(cx);
                    self.media.status = format!(
                        "Historical images were not installed: {error}. Inspect again when ready."
                    );
                    cx.notify();
                }
            }
        }
        if self
            .media
            .freshness_task
            .as_ref()
            .is_some_and(Task::is_ready)
        {
            self.media.freshness_task.take();
            if self.media.freshness.is_some() {
                self.media.freshness_error = Some("Historical image freshness task finished without its result; ownership is unconfirmed".into());
            }
        }
        self.start_media_freshness_check(cx);
    }
    pub(super) fn media_shutdown_ready(&self, cx: &App) -> bool {
        let panel = self.media.panel.read(cx);
        self.media
            .owner
            .shutdown_ready(panel.has_in_flight_work(), panel.retained_receipts().len())
    }
    pub(super) fn request_media_close(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        self.media.close_requested = true;
        self.sync_media_context(cx);
        if self.media_shutdown_ready(cx) {
            return true;
        }
        self.show_media_shutdown(window, cx);
        false
    }
    pub(super) fn show_media_shutdown(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.settings_open = true;
        self.media.opened = true;
        self.browser_settings_open = false;
        self.credentials_open = false;
        self.bots_open = false;
        self.transcription_open = false;
        self.notifications_open = false;
        self.provider_settings.open = false;
        self.session_import_open = false;
        self.workspace_open = false;
        self.schedules_open = false;
        self.dismiss_find(window, cx);
        self.credential_panel
            .update(cx, |panel, cx| panel.cancel(cx));
        self.sync_terminal_workspace(window, cx);
        self.sync_transcription_binding(cx);
        if self.media.status.is_empty() {
            self.media.status="Close is waiting for historical-image work and recovery receipts. Hand each finished receipt below to recovery; no unfinished work was discarded.".into();
        }
        cx.notify();
    }
    pub(super) fn historical_image_is_open(&self) -> bool {
        self.media.viewer.selection().is_some()
    }
    fn historical_image_selection_current(
        &self,
        selection: &historical_image_view::Selection,
    ) -> bool {
        selection.current(
            self.selected
                .as_ref()
                .and_then(|thread| thread["id"].as_str()),
            self.media.epoch,
            self.media.revision,
            self.media.images.iter().any(|image| {
                image.item == selection.item && image.candidate == selection.candidate
            }),
            self.media.shutdown_requested
                || self.media.close_requested
                || !self.find_context_available(),
        )
    }
    fn open_historical_image(
        &mut self,
        selection: historical_image_view::Selection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let visible = self
            .selected
            .as_ref()
            .and_then(|thread| find_row(thread, &selection.thread, &selection.item))
            .and_then(|row| self.transcript_list.completed_layout_bounds_for_item(row))
            .is_some_and(|row| {
                self.transcript_list
                    .completed_layout_viewport_bounds()
                    .is_some_and(|viewport| row_intersects(row, viewport))
            });
        let current = visible
            && window.is_window_active()
            && !self.command_palette.read(cx).is_open()
            && self.historical_image_selection_current(&selection);
        let was_open = self.historical_image_is_open();
        if !self.media.viewer.open(selection, current) {
            return;
        }
        if !was_open {
            self.media.viewer_restore = window.focused(cx);
        }
        self.media.viewer_focus.focus(window, cx);
        // Native WebViews are above GPUI; hide them before drawing this modal.
        // The selected profile/tab and the user's browser-panel choice stay intact.
        if let Some(browser) = &mut self.browser {
            browser.set_thread_visible(None, cx);
        }
        self.sync_terminal_workspace(window, cx);
        cx.notify();
    }
    fn close_historical_image(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.media.viewer.close();
        if let Some(focus) = self.media.viewer_restore.take() {
            focus.focus(window, cx);
        }
        self.sync_terminal_workspace(window, cx);
        cx.notify();
    }
    pub(super) fn sync_historical_image_view(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .media
            .viewer
            .selection()
            .is_some_and(|selection| !self.historical_image_selection_current(selection))
        {
            self.media.viewer.close();
        }
        if !self.historical_image_is_open() {
            if self.media.shutdown_requested || self.media.close_requested {
                self.media.viewer_restore = None;
            } else if let Some(focus) = self.media.viewer_restore.take() {
                focus.focus(window, cx);
            }
        }
    }
    /// While the modal owns input, root conversation shortcuts must not act on
    /// the obscured composer. Tab still reaches its native-accessible Close button.
    pub(super) fn historical_image_shortcut(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.historical_image_is_open() {
            return false;
        }
        let key = &event.keystroke;
        if key.key == "escape"
            && !key.modifiers.platform
            && !key.modifiers.control
            && !key.modifiers.alt
            && !key.modifiers.shift
            && !event.is_held
        {
            self.close_historical_image(window, cx);
            cx.stop_propagation();
        }
        true
    }
    pub(super) fn historical_image_overlay(&self, cx: &Context<Self>) -> Option<AnyElement> {
        let selection = self.media.viewer.selection()?;
        if !self.historical_image_selection_current(selection) {
            return None;
        }
        let image =
            self.media.images.iter().find(|image| {
                image.item == selection.item && image.candidate == selection.candidate
            })?;
        Some(div().id("historical-image-viewer").role(Role::Dialog).aria_label("Historical image viewer").absolute().inset_0().p_6().flex().items_center().justify_center()
            .bg(rgba(0x000000ee)).track_focus(&self.media.viewer_focus)
            .on_mouse_down(MouseButton::Left, cx.listener(|_, _, _, cx| cx.stop_propagation()))
            .child(div().w_full().h_full().max_w(px(1400.)).flex().flex_col().gap_3().min_h_0()
                .child(div().flex().items_center().gap_3()
                    .child(div().flex_1().min_w_0().truncate().child(image.name.clone()))
                    .child(Button::new("historical-image-close").label("Close image").on_click(cx.listener(|this, _, window, cx| this.close_historical_image(window, cx)))))
                // Keep the image out of flex sizing: its intrinsic aspect ratio
                // must fit the established viewport, not enlarge it and get clipped.
                .child(div().relative().flex_1().min_h_0().w_full().overflow_hidden()
                    .child(img(image.image.clone()).absolute().inset_0().size_full().object_fit(ObjectFit::Contain)
                        .with_loading(|| div().child("Loading historical image…").into_any_element())
                        .with_fallback(|| div().child("Historical image unavailable. Close this view and inspect again.").into_any_element())))
                .child(div().text_xs().child("Verified local image · Escape or Close image returns to the conversation.")))
            .into_any_element())
    }
    pub(super) fn historical_images(&self, item: &str, cx: &Context<Self>) -> Vec<AnyElement> {
        let thread = self
            .selected
            .as_ref()
            .map(|thread| text(thread, "id"))
            .unwrap_or_default();
        self.media
            .images
            .iter()
            .filter(|image| image.item == item)
            .map(|image| {
                let selection = historical_image_view::Selection {
                    thread: thread.clone(),
                    item: image.item.clone(),
                    candidate: image.candidate.clone(),
                    epoch: self.media.epoch,
                    revision: self.media.revision,
                };
                div()
                    .id(SharedString::from(format!(
                        "historical-image-{}-{}",
                        image.item, image.candidate
                    )))
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        img(image.image.clone())
                            .w(px(240.))
                            .h(px(180.))
                            .object_fit(ObjectFit::Contain)
                            .with_loading(|| {
                                div()
                                    .text_xs()
                                    .child("Loading historical image…")
                                    .into_any_element()
                            })
                            .with_fallback(|| {
                                div()
                                    .text_xs()
                                    .child("Historical image unavailable")
                                    .into_any_element()
                            }),
                    )
                    .child(
                        div()
                            .max_w(px(240.))
                            .truncate()
                            .text_xs()
                            .child(image.name.clone()),
                    )
                    .child(
                        Button::new(SharedString::from(format!(
                            "historical-image-enlarge-{}",
                            image.candidate
                        )))
                        .label("Enlarge image")
                        .compact()
                        .max_w(px(240.))
                        .on_click(cx.listener(
                            move |this, _, window, cx| {
                                this.open_historical_image(selection.clone(), window, cx)
                            },
                        )),
                    )
                    .into_any_element()
            })
            .collect()
    }
    pub(super) fn media_settings_pane(&self, cx: &mut Context<Self>) -> AnyElement {
        let retained = self.media.panel.read(cx).retained_receipts().len();
        let pending = self.media.owner.pending_receipts();
        let saved = pending
            .iter()
            .any(|(id, _)| self.media.owner.durable_ownership(*id).is_some());
        div().id("historical-media-surface").flex_1().min_h_0().min_w_0().flex().flex_col()
            .child(self.settings_subpage_header("Historical images", "historical-media-done", cx))
            .child(div().p_2().text_sm().child("Keep this app open until image recovery finishes."))
            .when(self.media.close_requested||self.media.shutdown_requested,|view|view.child(div().p_2().child("Closing is paused until image work finishes and every receipt is saved and acknowledged.")))
            .child(div().p_2().text_sm().child(format!("Retained service receipts: {retained} · parent handoffs: {}. {}",pending.len(),self.media.status)))
            .child(Button::new("historical-media-retry-saved").label("Retry saved receipt acknowledgments").disabled(!saved)
                .on_click(cx.listener(|this,_,_,cx|{
                    let ids=this.media.owner.pending_receipts().into_iter().map(|(id,_)|id).filter(|id|this.media.owner.durable_ownership(*id).is_some()).collect::<Vec<_>>();
                    for id in ids{this.acknowledge_media_ownership(id,cx);}
                })))
            .child(div().flex_1().min_h_0().child(self.media.panel.clone())).into_any_element()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn full_snapshot_edits_and_pending_drafts_reject_old_display() {
        let source = json!({"id":"t","draft":"old","title":"old","items":[{"id":"i","text":"text"}],"unknown":{"x":1}});
        assert!(snapshot_current(&source, &source, "t", 3, 3, false));
        assert!(!snapshot_current(&source, &source, "t", 3, 4, false));
        assert!(!snapshot_current(&source, &source, "other", 3, 3, false));
        assert!(!snapshot_current(&source, &source, "t", 3, 3, true));
        for key in ["draft", "title", "unknown", "items"] {
            let mut changed = source.clone();
            changed[key] = json!("changed");
            assert!(!snapshot_current(&changed, &source, "t", 3, 3, false));
        }
    }
    #[::core::prelude::v1::test]
    fn only_measured_intersecting_rows_are_visible_candidates() {
        let viewport = Bounds::from_corners(point(px(0.), px(100.)), point(px(300.), px(300.)));
        assert!(row_intersects(
            Bounds::from_corners(point(px(0.), px(150.)), point(px(300.), px(200.))),
            viewport
        ));
        assert!(!row_intersects(
            Bounds::from_corners(point(px(0.), px(10.)), point(px(300.), px(100.))),
            viewport
        ));
        assert!(!row_intersects(
            Bounds::from_corners(point(px(0.), px(300.)), point(px(300.), px(400.))),
            viewport
        ));
        assert!(!row_intersects(viewport, Bounds::default()));
    }
}
