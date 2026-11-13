//! Native controller/panel for legacy image restoration. Parent retains this entity
//! across hide and durably reconciles receipts before acknowledge_reconciled/drop.
//! All file/Store/hash/prepare work belongs to LegacyMediaService's worker.
use coincide_core::{
    legacy_media::{ApprovedRoot, Candidate, CheckedReference, MediaBatch, Status},
    legacy_media_service::{
        CancelAck, CompletionReceipt, LegacyMediaService, OperationId, PlanId, PreviewId,
        ReceiptId, RenderFailure, RootCapability, SelectionToken, ServiceConfig, ServiceEvent,
        ServiceResult, ValidatedRenderEntry,
    },
};
use gpui_kit::{
    AppContext, Context, Entity, EventEmitter, InteractiveElement, IntoElement, ParentElement,
    PathPromptOptions, Render, SharedString, StatefulInteractiveElement, Styled, Subscription,
    Task, Window,
    base::Disableable,
    component::{
        button::{Button, ButtonVariants},
        input::{Input, InputEvent, InputState},
    },
    div,
};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};

const MAX_ROWS: usize = 100;
const MAX_SELECTED: usize = 20;
fn short(text: &str, limit: usize) -> String {
    let mut chars = text.chars();
    let mut result = chars.by_ref().take(limit).collect::<String>();
    if chars.next().is_some() {
        result.push('…');
    }
    result
}
#[derive(Clone, Debug)]
struct Row {
    id: String,
    label: String,
    status: Status,
    detail: String,
}
impl Row {
    fn candidate(c: &Candidate) -> Self {
        Self {
            id: c.candidate_id.clone(),
            label: short(
                c.raw_reference
                    .as_str()
                    .unwrap_or("Unknown attachment shape"),
                100,
            ),
            status: c.status.clone(),
            detail: format!(
                "Item {} · attachment {}",
                c.item_index + 1,
                c.attachment_index + 1
            ),
        }
    }
    fn checked(r: &CheckedReference) -> Self {
        let mut row = Self::candidate(&r.candidate);
        row.status = r.status.clone();
        row.detail = format!(
            "{} bytes · {}",
            r.byte_len.unwrap_or(0),
            r.mime_type.as_deref().unwrap_or("unavailable")
        );
        row
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Empty,
    Inspected,
    Preview,
}
/// Pure UI workflow; fake-service fixtures exercise the same event/selection gates.
struct Flow {
    phase: Phase,
    rows: Vec<Row>,
    selected: HashSet<String>,
    source_hash: Option<String>,
    next_offset: Option<usize>,
    page_offset: usize,
    notice: String,
}
impl Flow {
    fn new() -> Self {
        Self {
            phase: Phase::Empty,
            rows: Vec::new(),
            selected: HashSet::new(),
            source_hash: None,
            next_offset: None,
            page_offset: 0,
            notice: "Select a conversation, then explicitly approve a source folder mapping."
                .into(),
        }
    }
    fn clear(&mut self) {
        self.phase = Phase::Empty;
        self.rows.clear();
        self.selected.clear();
        self.source_hash = None;
        self.next_offset = None;
        self.page_offset = 0;
    }
    fn inspected(
        &mut self,
        hash: String,
        rows: Vec<Row>,
        next: Option<usize>,
        offset: usize,
    ) -> bool {
        if offset != 0 && self.source_hash.as_ref() != Some(&hash) {
            self.clear();
            self.notice =
                "Conversation changed between pages. Inspect again from the first page.".into();
            return false;
        }
        self.phase = Phase::Inspected;
        self.rows = rows.into_iter().take(MAX_ROWS).collect();
        self.selected.clear();
        self.source_hash = Some(hash);
        self.next_offset = next;
        self.page_offset = offset;
        self.notice =
            "Select mapped references to validate. No image copies have been created.".into();
        true
    }
    fn previewed(&mut self, hash: String, rows: Vec<Row>) -> bool {
        if self.source_hash.as_ref() != Some(&hash) {
            self.clear();
            self.notice = "Preview source changed. Inspect again.".into();
            return false;
        }
        self.phase = Phase::Preview;
        self.rows = rows.into_iter().take(MAX_SELECTED).collect();
        self.selected.clear();
        self.notice =
            "Review hashes and outcomes. Select Ready images, then explicitly confirm copying."
                .into();
        true
    }
    fn toggle(&mut self, id: &str) {
        let selectable = self.rows.iter().any(|r| {
            r.id == id
                && match self.phase {
                    Phase::Inspected => r.status == Status::Mapped,
                    Phase::Preview => r.status == Status::Ready,
                    Phase::Empty => false,
                }
        });
        if !selectable {
            return;
        }
        if !self.selected.remove(id) && self.selected.len() < MAX_SELECTED {
            self.selected.insert(id.into());
        }
    }
    fn ids(&self, phase: Phase) -> Option<Vec<String>> {
        if self.phase != phase || self.selected.is_empty() || self.selected.len() > MAX_SELECTED {
            return None;
        }
        Some(
            self.rows
                .iter()
                .filter(|r| self.selected.contains(&r.id))
                .map(|r| r.id.clone())
                .collect(),
        )
    }
}
#[derive(Debug, PartialEq, Eq)]
struct OutcomeSummary {
    outcomes: usize,
    unresolved_image_ids: Vec<String>,
}
impl OutcomeSummary {
    fn from_batch(batch: &MediaBatch, committed: &[String]) -> Self {
        let mut unresolved_image_ids = batch
            .references
            .iter()
            .filter(|entry| !committed.contains(&entry.reference.candidate.candidate_id))
            .filter_map(|entry| entry.image.as_ref().map(|image| image.id.clone()))
            .collect::<Vec<_>>();
        unresolved_image_ids.sort();
        unresolved_image_ids.dedup();
        Self {
            outcomes: batch.references.len(),
            unresolved_image_ids,
        }
    }
}
fn cancel_notice(ack: CancelAck) -> &'static str {
    match ack {
        CancelAck::Requested => {
            "Cancellation requested; a bounded copy may finish. Retain the completion receipt."
        }
        CancelAck::TooLateMayCommit => {
            "Commit may already be underway. Wait for the actual result; do not retry."
        }
        CancelAck::Finished => "Worker finished; waiting for its result.",
        CancelAck::UnknownOperation => "Operation result is pending.",
    }
}
#[derive(Clone, Copy)]
enum PendingKind {
    Inspect(usize),
    Validate,
    Confirm,
}
struct Pending {
    id: OperationId,
    revision: u64,
    kind: PendingKind,
}

pub enum LegacyMediaSettingsEvent {
    ImagesInvalidated {
        thread_id: String,
        source_revision: u64,
    },
    ImagesReady {
        thread_id: String,
        generation: u64,
        source_revision: u64,
        selection: SelectionToken,
        entries: Arc<Vec<ValidatedRenderEntry>>,
        failures: Vec<RenderFailure>,
    },
    OverlayRestored {
        thread_id: String,
    },
    RecoveryOwnershipRequested {
        receipt_id: ReceiptId,
        receipt: Arc<CompletionReceipt>,
    },
}

pub struct LegacyMediaSettingsPanel {
    service: LegacyMediaService,
    selection: SelectionToken,
    thread_id: Option<String>,
    source_revision: u64,
    revision: u64,
    prefix: Entity<InputState>,
    folder: Option<PathBuf>,
    relative: bool,
    capability: Option<RootCapability>,
    plan: Option<PlanId>,
    preview: Option<PreviewId>,
    flow: Flow,
    pending: Option<Pending>,
    choosing: bool,
    awaiting_receipts: Vec<ReceiptId>,
    receipts: HashMap<ReceiptId, Arc<CompletionReceipt>>,
    visible: Vec<String>,
    render_revision: u64,
    render_pending: Option<(OperationId, u64)>,
    render_dirty: bool,
    _subscription: Subscription,
    _poll: Task<()>,
    closing: bool,
}
impl EventEmitter<LegacyMediaSettingsEvent> for LegacyMediaSettingsPanel {}
impl LegacyMediaSettingsPanel {
    pub fn new(config: ServiceConfig, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut service = LegacyMediaService::spawn(config);
        let selection = service.select_thread(None);
        let prefix = cx.new(|cx| {
            InputState::new(window, cx).placeholder("Exact original absolute folder prefix")
        });
        let subscription = cx.subscribe(&prefix, |this, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                this.mapping_changed(cx);
            }
        });
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
                if this.update(cx, |this, cx| this.poll(cx)).is_err() {
                    break;
                }
            }
        });
        Self {
            service,
            selection,
            thread_id: None,
            source_revision: 0,
            revision: 0,
            prefix,
            folder: None,
            relative: false,
            capability: None,
            plan: None,
            preview: None,
            flow: Flow::new(),
            pending: None,
            choosing: false,
            awaiting_receipts: Vec::new(),
            receipts: HashMap::new(),
            visible: Vec::new(),
            render_revision: 0,
            render_pending: None,
            render_dirty: false,
            _subscription: subscription,
            _poll: poll,
            closing: false,
        }
    }
    /// Call on actual selection changes, not render frames or panel hide.
    pub fn set_thread(&mut self, thread_id: Option<String>, cx: &mut Context<Self>) {
        if self.thread_id == thread_id {
            return;
        }
        self.selection = self.service.select_thread(thread_id.clone());
        self.thread_id = thread_id;
        self.revision = self.revision.wrapping_add(1);
        self.capability = None;
        self.plan = None;
        self.preview = None;
        self.flow.clear();
        self.flow.notice =
            "Conversation changed. Approve a folder mapping for this conversation.".into();
        self.visible.clear();
        self.render_dirty = false;
        self.render_revision = self.render_revision.wrapping_add(1);
        // In-flight results still drain and every Finished receipt is retained, even for old selection.
        cx.notify();
    }
    /// Preferred parent hook: revision must change whenever the full stored thread
    /// snapshot changes, even if its ID and visible item IDs remain the same.
    pub fn set_context(
        &mut self,
        thread_id: Option<String>,
        source_revision: u64,
        item_ids: Vec<String>,
        cx: &mut Context<Self>,
    ) {
        let edited = self.thread_id == thread_id && self.source_revision != source_revision;
        self.set_thread(thread_id, cx);
        self.source_revision = source_revision;
        if edited {
            let had_review = self.flow.phase != Phase::Empty
                || self.plan.is_some()
                || self.preview.is_some()
                || self.pending.is_some();
            self.revision = self.revision.wrapping_add(1);
            if let Some(pending) = &self.pending {
                self.service.cancel(pending.id);
            }
            self.plan = None;
            self.preview = None;
            self.flow.clear();
            self.flow.notice = if had_review {
                "The conversation changed. Inspect the images again before copying."
            } else {
                "Choose a source folder, then approve the mapping to inspect its images."
            }
            .into();
            self.render_revision = self.render_revision.wrapping_add(1);
            self.render_dirty = true;
        }
        if edited && let Some(thread_id) = &self.thread_id {
            cx.emit(LegacyMediaSettingsEvent::ImagesInvalidated {
                thread_id: thread_id.clone(),
                source_revision,
            });
        }
        self.set_visible_items(item_ids, cx);
        self.schedule_render();
        cx.notify();
    }
    /// Parent passes actual visible item IDs. Never pass attachment paths here.
    pub fn set_visible_items(&mut self, mut item_ids: Vec<String>, cx: &mut Context<Self>) {
        item_ids.truncate(20);
        item_ids.sort();
        item_ids.dedup();
        if self.visible == item_ids {
            return;
        }
        self.visible = item_ids;
        self.render_revision = self.render_revision.wrapping_add(1);
        self.render_dirty = true;
        self.schedule_render();
        cx.notify();
    }
    /// Parent calls ONLY after it has durably taken ownership/reconciled ALL created IDs.
    /// No automatic acknowledgment, deletion or crash-recovery journal exists here.
    pub fn acknowledge_reconciled(
        &mut self,
        id: ReceiptId,
        cx: &mut Context<Self>,
    ) -> ServiceResult<()> {
        self.service.acknowledge_receipt(id)?;
        self.receipts.remove(&id);
        self.awaiting_receipts.retain(|r| *r != id);
        cx.notify();
        Ok(())
    }
    pub fn retained_receipts(&self) -> Vec<(ReceiptId, Arc<CompletionReceipt>)> {
        self.receipts
            .iter()
            .map(|(id, r)| (*id, r.clone()))
            .collect()
    }
    /// Parent must keep this entity alive until false AND every retained receipt is reconciled.
    pub fn has_in_flight_work(&self) -> bool {
        self.pending.is_some()
            || self.render_pending.is_some()
            || self.choosing
            || !self.awaiting_receipts.is_empty()
    }
    pub fn request_service_shutdown(&mut self) {
        self.closing = true;
        self.service.request_shutdown();
    }
    pub fn service_shutdown_status(
        &self,
    ) -> coincide_core::legacy_media_service::ServiceShutdownStatus {
        self.service.shutdown_status()
    }
    fn mapping_changed(&mut self, cx: &mut Context<Self>) {
        self.revision = self.revision.wrapping_add(1);
        if let Some(cap) = self.capability.take() {
            self.service.revoke_roots(cap);
        }
        if let Some(pending) = &self.pending {
            self.service.cancel(pending.id);
        }
        self.plan = None;
        self.preview = None;
        self.flow.clear();
        self.flow.notice =
            "Mapping changed. Approve the exact prefix and selected folder again.".into();
        cx.notify();
    }
    fn busy(&self) -> bool {
        self.closing || self.pending.is_some() || self.choosing
    }
    fn choose(&mut self, cx: &mut Context<Self>) {
        if self.busy() || self.thread_id.is_none() {
            return;
        }
        self.choosing = true;
        let revision = self.revision;
        let picker = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Choose approved legacy image folder".into()),
        });
        cx.notify();
        cx.spawn(async move |this,cx| {
            let result: anyhow::Result<_> = async { picker.await? }.await;
            let _=this.update(cx,|this,cx| {
                this.choosing=false;
                if this.closing || revision!=this.revision { cx.notify(); return; }
                match result {
                    Ok(Some(paths)) if paths.len()==1=> { this.folder=Some(paths[0].clone()); this.mapping_changed(cx); this.flow.notice="Folder selected. Enter its exact original prefix, then approve mapping and inspect.".into(); },
                    Ok(_)=>this.flow.notice="Folder selection cancelled; nothing was approved.".into(),
                    Err(error)=>this.flow.notice=format!("Folder selection failed: {error}"),
                }
                cx.notify();
            });
        }).detach();
    }
    fn approve_and_inspect(&mut self, cx: &mut Context<Self>) {
        if self.busy() {
            return;
        }
        let Some(folder) = self.folder.clone() else {
            self.flow.notice = "Choose a source folder using the native picker.".into();
            cx.notify();
            return;
        };
        let prefix = self.prefix.read(cx).value().to_string();
        if prefix.is_empty() || prefix.len() > 1024 || prefix.chars().any(char::is_control) {
            self.flow.notice="Enter the exact original absolute prefix (at most 1,024 bytes, no control characters).".into();
            cx.notify();
            return;
        }
        // ApprovedRoot::new only validates strings/components; source IO is in service worker.
        let result = ApprovedRoot::new(
            "native-selected-folder".into(),
            PathBuf::from(prefix),
            folder,
        )
        .map_err(|e| e.to_string())
        .and_then(|root| {
            self.service
                .approve_roots_native(
                    &self.selection,
                    vec![root],
                    self.relative.then(|| "native-selected-folder".into()),
                )
                .map_err(|e| e.to_string())
        });
        match result {
            Ok(cap) => {
                if let Some(old) = self.capability.replace(cap) {
                    self.service.revoke_roots(old);
                }
                self.inspect(0, cx);
            }
            Err(error) => {
                self.flow.notice = error;
                cx.notify();
            }
        }
    }
    fn start(
        &mut self,
        result: ServiceResult<OperationId>,
        kind: PendingKind,
        cx: &mut Context<Self>,
    ) {
        match result {
            Ok(id) => {
                self.pending = Some(Pending {
                    id,
                    revision: self.revision,
                    kind,
                });
                self.flow.notice = match kind {
                    PendingKind::Inspect(_) => "Inspecting bounded attachment references…",
                    PendingKind::Validate => "Reading and validating the selected source images…",
                    PendingKind::Confirm => {
                        "Copying confirmed images and comparing the stored conversation…"
                    }
                }
                .into();
            }
            Err(error) => self.flow.notice = format!("{error}. No automatic retry."),
        }
        cx.notify();
    }
    fn inspect(&mut self, offset: usize, cx: &mut Context<Self>) {
        if self.busy() {
            return;
        }
        let Some(cap) = &self.capability else {
            return;
        };
        let op = self.service.inspect(&self.selection, cap, offset);
        self.start(op, PendingKind::Inspect(offset), cx);
    }
    fn validate(&mut self, cx: &mut Context<Self>) {
        if self.busy() {
            return;
        }
        let (Some(plan), Some(ids)) = (self.plan, self.flow.ids(Phase::Inspected)) else {
            return;
        };
        let op = self.service.validate(&self.selection, plan, ids);
        self.start(op, PendingKind::Validate, cx);
    }
    fn confirm(&mut self, cx: &mut Context<Self>) {
        if self.busy() {
            return;
        }
        let (Some(preview), Some(ids)) = (self.preview, self.flow.ids(Phase::Preview)) else {
            return;
        };
        let op = self.service.confirm(&self.selection, preview, ids);
        self.start(op, PendingKind::Confirm, cx);
    }
    fn cancel(&mut self, cx: &mut Context<Self>) {
        if let Some(p) = &self.pending {
            self.flow.notice = cancel_notice(self.service.cancel(p.id)).into();
            cx.notify();
        }
    }
    fn schedule_render(&mut self) {
        if !self.render_dirty
            || self.render_pending.is_some()
            || self.busy()
            || self.thread_id.is_none()
        {
            return;
        }
        if let Ok(op) = self
            .service
            .load_visible(&self.selection, self.visible.clone())
        {
            self.render_pending = Some((op, self.render_revision));
            self.render_dirty = false;
        }
    }
    fn poll(&mut self, cx: &mut Context<Self>) {
        let mut changed = false;
        for event in self.service.poll() {
            changed = true;
            if let ServiceEvent::Finished { receipt_id, .. } = &event {
                self.awaiting_receipts.push(*receipt_id);
            }
            let id = match &event {
                ServiceEvent::Inspected { operation_id, .. }
                | ServiceEvent::Validated { operation_id, .. }
                | ServiceEvent::Finished { operation_id, .. }
                | ServiceEvent::Rendered { operation_id, .. }
                | ServiceEvent::Failed { operation_id, .. } => *operation_id,
            };
            let pending = if self.pending.as_ref().is_some_and(|p| p.id == id) {
                self.pending.take()
            } else {
                None
            };
            let render = self.render_pending.filter(|(op, _)| *op == id);
            if render.is_some() {
                self.render_pending = None;
            }
            let current = pending
                .as_ref()
                .is_some_and(|p| p.revision == self.revision);
            match event {
                ServiceEvent::Inspected {
                    thread_id,
                    generation,
                    plan_id,
                    source_thread_sha256,
                    candidates,
                    next_item_offset,
                    limits,
                    expires_in_seconds,
                    ..
                } if current && self.selection.accepts(&thread_id, generation) => {
                    let offset = match pending.as_ref().unwrap().kind {
                        PendingKind::Inspect(offset) => offset,
                        _ => 0,
                    };
                    if self.flow.inspected(
                        source_thread_sha256,
                        candidates.iter().map(Row::candidate).collect(),
                        next_item_offset,
                        offset,
                    ) {
                        self.plan = Some(plan_id);
                        self.preview = None;
                        self.flow.notice.push_str(&format!(
                            " Expires in {expires_in_seconds}s. {} inspection limits reported.",
                            limits.len()
                        ));
                    }
                }
                ServiceEvent::Validated {
                    thread_id,
                    generation,
                    preview_id,
                    source_thread_sha256,
                    references,
                    expires_in_seconds,
                    ..
                } if current && self.selection.accepts(&thread_id, generation) => {
                    self.plan = None;
                    if self.flow.previewed(
                        source_thread_sha256,
                        references.iter().map(Row::checked).collect(),
                    ) {
                        self.preview = Some(preview_id);
                        self.flow
                            .notice
                            .push_str(&format!(" Confirmation expires in {expires_in_seconds}s."));
                    }
                }
                ServiceEvent::Rendered {
                    thread_id,
                    generation,
                    entries,
                    failures,
                    ..
                } if render.is_some_and(|(_, rev)| rev == self.render_revision)
                    && self.selection.accepts(&thread_id, generation) =>
                {
                    cx.emit(LegacyMediaSettingsEvent::ImagesReady {
                        thread_id,
                        generation,
                        source_revision: self.source_revision,
                        selection: self.selection.clone(),
                        entries: Arc::new(entries),
                        failures,
                    });
                }
                ServiceEvent::Failed { error, .. } if current => {
                    self.plan = None;
                    self.preview = None;
                    self.flow.clear();
                    self.flow.notice = format!(
                        "{error}. Inspect again explicitly; no source or draft was rewritten."
                    );
                }
                ServiceEvent::Failed { error, .. }
                    if render.is_some_and(|(_, revision)| revision == self.render_revision) =>
                {
                    self.flow.notice = format!(
                        "Historical image display unavailable: {error}. No automatic rebase."
                    );
                    if let Some(thread_id) = &self.thread_id {
                        cx.emit(LegacyMediaSettingsEvent::ImagesInvalidated {
                            thread_id: thread_id.clone(),
                            source_revision: self.source_revision,
                        });
                    }
                }
                _ => {}
            }
        }
        let mut waiting = Vec::new();
        for id in self.awaiting_receipts.drain(..) {
            if let Some(receipt) = self.service.receipt(id) {
                let fresh = self.receipts.insert(id, receipt.clone()).is_none();
                if fresh && receipt.committed {
                    cx.emit(LegacyMediaSettingsEvent::OverlayRestored {
                        thread_id: receipt.thread_id.clone(),
                    });
                }
                if fresh
                    && self
                        .selection
                        .accepts(&receipt.thread_id, receipt.generation)
                {
                    self.plan = None;
                    self.preview = None;
                    self.flow.clear();
                    self.flow.notice = format!(
                        "{} image mappings committed; {} per-reference outcomes. Result: {}. Receipt retained until explicit parent reconciliation.",
                        receipt.committed_candidate_ids.len(),
                        OutcomeSummary::from_batch(
                            &receipt.batch,
                            &receipt.committed_candidate_ids
                        )
                        .outcomes,
                        receipt
                            .error
                            .as_ref()
                            .map_or("committed".into(), ToString::to_string)
                    );
                    if receipt.committed {
                        self.render_revision = self.render_revision.wrapping_add(1);
                        self.render_dirty = true;
                    }
                }
                changed = true;
            } else {
                waiting.push(id);
            }
        }
        self.awaiting_receipts = waiting;
        self.schedule_render();
        if changed {
            cx.notify();
        }
    }
}
impl Render for LegacyMediaSettingsPanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let busy = self.busy();
        let mut pane=div().id("legacy-media-settings").size_full().flex().flex_col().gap_3().p_4()
            .child("Restore images from your previous Coincide library. Your original files and drafts stay unchanged; nothing is sent to a provider.")
            .child(Input::new(&self.prefix))
            .child(format!("Selected source folder: {}",self.folder.as_ref().map(|p|short(&p.to_string_lossy(),500)).unwrap_or_else(||"Choose with the native folder picker".into())))
            .child(div().min_w_0().flex().flex_wrap().gap_2()
                .child(Button::new("legacy-media-folder").label("Choose source folder…").disabled(busy||self.thread_id.is_none()).on_click(cx.listener(|this,_,_,cx|this.choose(cx))))
                .child(Button::new("legacy-media-relative").label(if self.relative {"Relative paths: use this folder"}else{"Relative paths: not included"}).disabled(busy).on_click(cx.listener(|this,_,_,cx|{this.relative = !this.relative;this.mapping_changed(cx);}))))
            .child(div().flex().justify_start().child(Button::new("legacy-media-approve").label("Confirm folder and find images").disabled(busy||self.folder.is_none()||self.thread_id.is_none()).on_click(cx.listener(|this,_,_,cx|this.approve_and_inspect(cx)))))
            .child(div().text_sm().child(short(&self.flow.notice,1500)))
            .child(div().min_w_0().flex().flex_wrap().gap_2()
                .child(Button::new("legacy-media-validate").label("Check selected images").disabled(busy||self.flow.ids(Phase::Inspected).is_none()).on_click(cx.listener(|this,_,_,cx|this.validate(cx))))
                .child(Button::new("legacy-media-confirm").label("Restore selected images").primary().disabled(busy||self.flow.ids(Phase::Preview).is_none()||self.receipts.len()>=8).on_click(cx.listener(|this,_,_,cx|this.confirm(cx))))
                .child(Button::new("legacy-media-cancel").label("Cancel").disabled(self.pending.is_none()).on_click(cx.listener(|this,_,_,cx|this.cancel(cx)))))
            .child(format!("{} of 20 selected",self.flow.selected.len()));
        let mut body = div()
            .id("legacy-media-rows")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_2();
        for row in self.flow.rows.iter().take(MAX_ROWS) {
            let id = row.id.clone();
            let selectable = match self.flow.phase {
                Phase::Inspected => row.status == Status::Mapped,
                Phase::Preview => row.status == Status::Ready,
                Phase::Empty => false,
            };
            body = body.child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        Button::new(SharedString::from(format!(
                            "legacy-media-candidate-{}",
                            row.id
                        )))
                        .label(format!(
                            "{} {:?}: {}",
                            if self.flow.selected.contains(&row.id) {
                                "[selected]"
                            } else {
                                "[ ]"
                            },
                            row.status,
                            row.label
                        ))
                        .disabled(busy || !selectable)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.flow.toggle(&id);
                            cx.notify();
                        })),
                    )
                    .child(div().text_sm().child(short(&row.detail, 600))),
            );
        }
        if let Some(offset) = self.flow.next_offset {
            body = body.child(
                Button::new("legacy-media-next")
                    .label("Load more")
                    .disabled(busy || self.capability.is_none())
                    .on_click(cx.listener(move |this, _, _, cx| this.inspect(offset, cx))),
            );
        }
        if self.flow.phase == Phase::Preview {
            body=body.child("Select the images marked Ready to restore. Missing, changed or unsupported files won’t be copied.");
        }
        if !self.receipts.is_empty() || !self.awaiting_receipts.is_empty() {
            body = body.child(
                "Image recovery is finishing. Keep Coincide open until the results are saved.",
            );
        }
        for (id, receipt) in &self.receipts {
            let id = *id;
            let request = receipt.clone();
            let summary =
                OutcomeSummary::from_batch(&receipt.batch, &receipt.committed_candidate_ids);
            let unresolved = summary.unresolved_image_ids.len();
            body=body.child(format!("Receipt {id} · conversation {} · committed {} · unresolved copies {unresolved} · {:?}",receipt.thread_id,receipt.committed,receipt.error));
            for entry in receipt.batch.references.iter().take(20) {
                body = body.child(div().text_sm().child(format!(
                        "{:?} · image {} · {}",
                        entry.reference.status,
                        entry
                            .image
                            .as_ref()
                            .map(|i| i.id.as_str())
                            .unwrap_or("none"),
                        short(entry.validation_error.as_deref().unwrap_or(""), 250)
                    )));
            }
            body = body.child(
                Button::new(SharedString::from(format!("legacy-media-reconcile-{id}")))
                    .label("Finish image recovery")
                    .on_click(cx.listener(move |_, _, _, cx| {
                        cx.emit(LegacyMediaSettingsEvent::RecoveryOwnershipRequested {
                            receipt_id: id,
                            receipt: request.clone(),
                        })
                    })),
            );
        }
        pane = pane.child(body);
        pane
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    /// Synthetic service output; no opaque native capability is forged and no IO runs.
    struct FakeService {
        calls: Vec<&'static str>,
    }
    impl FakeService {
        fn inspect(&mut self, flow: &mut Flow) {
            self.calls.push("inspect");
            assert!(flow.inspected(
                "fixture-hash".into(),
                vec![
                    row("mapped", Status::Mapped),
                    row("missing", Status::Missing)
                ],
                None,
                0
            ));
        }
        fn validate(&mut self, flow: &mut Flow) {
            assert_eq!(flow.ids(Phase::Inspected), Some(vec!["mapped".into()]));
            self.calls.push("validate");
            assert!(flow.previewed(
                "fixture-hash".into(),
                vec![
                    row("mapped", Status::Ready),
                    row("changed", Status::Changed)
                ]
            ));
        }
        fn confirm(&mut self, flow: &Flow) {
            assert_eq!(flow.ids(Phase::Preview), Some(vec!["mapped".into()]));
            self.calls.push("confirm");
        }
    }
    fn row(id: &str, status: Status) -> Row {
        Row {
            id: id.into(),
            label: id.into(),
            status,
            detail: String::new(),
        }
    }
    #[test]
    fn fake_service_requires_explicit_preview_ready_selection_and_confirmation() {
        let mut flow = Flow::new();
        let mut service = FakeService { calls: Vec::new() };
        assert!(flow.ids(Phase::Preview).is_none());
        service.inspect(&mut flow);
        flow.toggle("missing");
        assert!(flow.selected.is_empty());
        flow.toggle("mapped");
        service.validate(&mut flow);
        assert!(flow.selected.is_empty());
        assert!(flow.ids(Phase::Preview).is_none());
        flow.toggle("changed");
        assert!(flow.selected.is_empty());
        flow.toggle("mapped");
        service.confirm(&flow);
        assert_eq!(service.calls, vec!["inspect", "validate", "confirm"]);
    }
    #[test]
    fn workflow_refuses_cross_source_preview_and_page_rebase() {
        let mut flow = Flow::new();
        flow.inspected(
            "initial".into(),
            vec![row("one", Status::Mapped)],
            Some(1000),
            0,
        );
        assert!(!flow.inspected("changed".into(), vec![], None, 1000));
        assert_eq!(flow.phase, Phase::Empty);
        flow.inspected("initial".into(), vec![row("one", Status::Mapped)], None, 0);
        assert!(!flow.previewed("changed".into(), vec![row("one", Status::Ready)]));
        assert!(flow.selected.is_empty());
    }
    #[test]
    fn workflow_bounds_selection_and_keeps_unknown_states_explicit() {
        let mut flow = Flow::new();
        let mut rows = (0..100)
            .map(|i| row(&i.to_string(), Status::Mapped))
            .collect::<Vec<_>>();
        rows.push(row("unknown", Status::UnknownShape));
        flow.inspected("hash".into(), rows, None, 0);
        for i in 0..100 {
            flow.toggle(&i.to_string());
        }
        assert_eq!(flow.selected.len(), 20);
        assert_eq!(flow.rows.len(), 100);
        assert_eq!(short("😀abc", 2), "😀a…");
    }
    #[test]
    fn fake_partial_outcomes_keep_failed_and_reused_owned_image_identities() {
        use coincide_core::{attachments::StoredImage, legacy_media::MaterializedReference};
        let image = StoredImage {
            id: "00000000-0000-4000-8000-000000000001".into(),
            original_name: "fixture.png".into(),
            original_path: PathBuf::from("/synthetic-never-opened/original.png"),
            original_mime_type: "image/png".into(),
            path: PathBuf::from("/synthetic-never-opened/normalized.png"),
            mime_type: "image/png".into(),
            width: 1,
            height: 1,
            byte_len: 1,
            original_byte_len: 1,
        };
        let reference =
            |id: &str, status: Status, image: Option<StoredImage>| MaterializedReference {
                reference: CheckedReference {
                    candidate: Candidate {
                        candidate_id: id.into(),
                        thread_id: "fixture-thread".into(),
                        item_id: None,
                        item_index: 0,
                        attachment_index: 0,
                        raw_reference: serde_json::json!("/fixture/image.png"),
                        root_id: None,
                        relative_path: None,
                        status: Status::Mapped,
                    },
                    status,
                    byte_len: Some(1),
                    source_sha256: None,
                    mime_type: Some("image/png".into()),
                },
                image,
                normalized_sha256: None,
                validation_error: Some("synthetic managed verification failure".into()),
            };
        let batch = MediaBatch {
            thread_sha256: "fixture-hash".into(),
            references: vec![
                reference("failed", Status::IoError, Some(image.clone())),
                reference("reused", Status::Materialized, Some(image.clone())),
                reference("missing", Status::Missing, None),
            ],
        };
        let summary = OutcomeSummary::from_batch(&batch, &[]);
        assert_eq!(summary.outcomes, 3);
        assert_eq!(summary.unresolved_image_ids, vec![image.id.clone()]);
        // A committed mapping of a different reference does not erase an unresolved identity.
        assert_eq!(
            OutcomeSummary::from_batch(&batch, &["reused".into()]).unresolved_image_ids,
            vec![image.id]
        );
    }
    #[test]
    fn cancellation_is_not_treated_as_completion_or_implicit_retry() {
        let mut flow = Flow::new();
        let mut fake = FakeService { calls: Vec::new() };
        fake.inspect(&mut flow);
        flow.toggle("mapped");
        fake.validate(&mut flow);
        flow.toggle("mapped");
        flow.notice = cancel_notice(CancelAck::TooLateMayCommit).into();
        assert!(flow.notice.contains("may already"));
        assert_eq!(flow.phase, Phase::Preview);
        assert_eq!(fake.calls, vec!["inspect", "validate"]);
        assert!(cancel_notice(CancelAck::Requested).contains("may finish"));
    }
}
