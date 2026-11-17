//! Explicit sidebar selection; reviewed flags and scoped latest-batch Undo.
use super::*;
use coincide_core::api::{PreparedThreadFlags, ThreadFlagAction as Action, ThreadFlagUndo};
use std::{
    collections::BTreeSet,
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
};
const LIMIT: usize = 50;
#[derive(Clone, Default, PartialEq, Eq)]
pub(super) struct Binding {
    pub rows: Vec<(String, bool, bool)>,
    pub project: Option<String>,
    pub query: String,
    pub archived: bool,
    pub snoozed: bool,
    pub available: bool,
}
enum Request {
    Prepare(Vec<String>, Action),
    Apply(Arc<PreparedThreadFlags>),
    Undo(Arc<ThreadFlagUndo>),
}
enum Effect {
    Prepared(Arc<PreparedThreadFlags>),
    Applied(Arc<ThreadFlagUndo>),
    Undone(Arc<ThreadFlagUndo>),
}
struct Reply {
    generation: u64,
    result: std::result::Result<Effect, String>,
}
pub(super) struct State {
    pub mode: bool,
    pub picked: BTreeSet<String>,
    binding: Binding,
    epoch: Arc<AtomicU64>,
    review: Option<Arc<PreparedThreadFlags>>,
    undo: Option<Arc<ThreadFlagUndo>>,
    /// When `undo` was made, among the inbox's Undo receipts (`inbox_undo`).
    undo_stamp: u64,
    workers: worker_owner::WorkerOwner,
    sender: mpsc::SyncSender<Reply>,
    receiver: mpsc::Receiver<Reply>,
    pending: bool,
    unjoined: bool,
    ambiguous: bool,
    pub status: String,
    notice_visible: bool,
    notice_undo: bool,
    restore_focus: Option<FocusHandle>,
    anchor: Option<Point<Pixels>>,
}
impl Default for State {
    fn default() -> Self {
        let (sender, receiver) = mpsc::sync_channel(1);
        Self {
            mode: false,
            picked: BTreeSet::new(),
            binding: Binding::default(),
            epoch: Arc::new(AtomicU64::new(0)),
            review: None,
            undo: None,
            undo_stamp: 0,
            workers: Default::default(),
            sender,
            receiver,
            pending: false,
            unjoined: false,
            ambiguous: false,
            status: String::new(),
            notice_visible: false,
            notice_undo: false,
            restore_focus: None,
            anchor: None,
        }
    }
}
fn allowed(admission: &worker_owner::Admission, epoch: &AtomicU64, generation: u64) -> Result<()> {
    anyhow::ensure!(
        admission.allowed() && epoch.load(Ordering::Acquire) == generation,
        "Selection or route changed before admission; no changes were made"
    );
    Ok(())
}
impl State {
    pub fn invalidate(&mut self) {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        if self.review.take().is_some() {
            self.status = "Selection changed; choose an action to review it again.".into();
        }
    }
    pub fn sync(&mut self, binding: Binding) {
        if self.binding == binding {
            return;
        }
        self.invalidate();
        let previous_count = self.picked.len();
        let visible: BTreeSet<_> = binding.rows.iter().map(|r| r.0.clone()).collect();
        self.picked.retain(|id| visible.contains(id));
        if !binding.available {
            self.mode = false;
            self.picked.clear();
        }
        if self.picked.len() < previous_count {
            self.status="Hidden selections were cleared. Review the visible selection before applying changes.".into();
        }
        self.binding = binding;
    }
    pub fn close_selection(&mut self) {
        self.invalidate();
        self.mode = false;
        self.picked.clear();
        self.status.clear();
        self.notice_visible = false;
        self.notice_undo = false;
    }
    fn cancel_review(&mut self) {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        self.review = None;
        self.status.clear();
        self.anchor = None;
    }
    pub fn toggle(&mut self, id: &str) -> Result<()> {
        anyhow::ensure!(
            self.binding.available && self.mode && self.binding.rows.iter().any(|r| r.0 == id),
            "Conversation is no longer in the visible selection"
        );
        if self.picked.contains(id) {
            self.picked.remove(id);
        } else {
            anyhow::ensure!(self.picked.len() < LIMIT, "Select at most 50 conversations");
            self.picked.insert(id.to_owned());
        }
        self.invalidate();
        Ok(())
    }
    fn select_visible(&mut self) -> Result<()> {
        anyhow::ensure!(
            self.binding.available && self.mode && self.binding.rows.len() <= LIMIT,
            "More than 50 conversations are visible. Select up to 50 individually or narrow the filters"
        );
        self.picked = self.binding.rows.iter().map(|r| r.0.clone()).collect();
        self.invalidate();
        Ok(())
    }
    pub(super) fn busy(&self) -> bool {
        self.pending || self.unjoined || self.ambiguous || self.workers.closed()
    }
    fn spawn(&mut self, engine: SharedEngine, request: Request) -> bool {
        if self.busy() {
            self.status = "Wait for the current selection operation to finish.".into();
            return false;
        }
        let epoch = self.epoch.clone();
        let generation = epoch.load(Ordering::Acquire);
        let sender = self.sender.clone();
        let started = self.workers.spawn(move |admission| {
            let result = (|| -> Result<Effect> {
                allowed(&admission, &epoch, generation)?;
                let mut engine = engine
                    .lock()
                    .map_err(|_| anyhow::anyhow!("App owner is unavailable"))?;
                // This is admission, not a promise of cancellation after the
                // transaction starts. A committed result is always published.
                allowed(&admission, &epoch, generation)?;
                match request {
                    Request::Prepare(ids, action) => {
                        Ok(Effect::Prepared(Arc::new(if action == Action::Archive {
                            engine.prepare_native_archive_flags(&ids)?
                        } else {
                            engine.prepare_thread_flags(&ids, action)?
                        })))
                    }
                    Request::Apply(proof) => Ok(Effect::Applied(Arc::new(
                        engine.apply_thread_flags(&proof)?,
                    ))),
                    Request::Undo(undo) => {
                        engine.undo_thread_flags(&undo)?;
                        Ok(Effect::Undone(undo))
                    }
                }
            })()
            .map_err(|error| error.to_string().chars().take(1024).collect());
            let _ = sender.send(Reply { generation, result });
        });
        if started {
            self.pending = true;
            self.unjoined = true;
            self.status = "Working…".into();
        } else {
            self.status = "Selection worker could not start; no changes were made.".into();
        }
        started
    }
    fn poll(&mut self) -> Option<Effect> {
        self.workers.poll();
        let owned = self.workers.status();
        self.unjoined = owned.unjoined != 0;
        if owned.panicked != 0 || owned.unclassified != 0 {
            self.ambiguous = true;
            self.status =
                "Sidebar worker completion is ambiguous; no further changes are admitted.".into();
        }
        let reply = self.receiver.try_recv().ok()?;
        self.pending = false;
        match reply.result {
            Ok(Effect::Prepared(preview)) => {
                if reply.generation == self.epoch.load(Ordering::Acquire)
                    && self.binding.available
                    && self.mode
                {
                    self.status = if preview.count() == 0 {
                        "All selected conversations already have that state.".into()
                    } else {
                        format!(
                            "Review {} change(s) in {} selected conversations.",
                            preview.count(),
                            preview.selected_count()
                        )
                    };
                    self.review = Some(preview);
                } else {
                    self.status = "Selection changed. Choose an action to review it again.".into();
                }
                None
            }
            Ok(Effect::Applied(undo)) => {
                self.notice_visible = true;
                self.notice_undo = true;
                self.status = format!(
                    "{} applied to {} conversation(s). Undo is available for this latest batch.",
                    undo.action().label(),
                    undo.count()
                );
                self.undo = Some(undo.clone());
                self.undo_stamp = inbox_undo::stamp();
                self.review = None;
                if reply.generation == self.epoch.load(Ordering::Acquire) {
                    self.picked.clear();
                    self.mode = false;
                }
                Some(Effect::Applied(undo))
            }
            Ok(Effect::Undone(undo)) => {
                self.notice_visible = true;
                self.notice_undo = false;
                self.status = format!(
                    "Undid {} for {} conversation(s).",
                    undo.action().label(),
                    undo.count()
                );
                self.undo = None;
                self.review = None;
                Some(Effect::Undone(undo))
            }
            Err(error) => {
                self.status = error;
                self.notice_visible = true;
                self.notice_undo = false;
                None
            }
        }
    }
    /// The stamp of the latest batch's Undo receipt, while it has one.
    pub(super) fn undo_stamp(&self) -> Option<u64> {
        self.undo.as_ref().map(|_| self.undo_stamp)
    }
    pub fn close(&mut self) {
        self.invalidate();
        self.workers.close();
        self.mode = false;
        self.picked.clear();
    }
    pub fn shutdown_status(&mut self) -> worker_owner::ShutdownStatus {
        self.workers.status()
    }
    pub fn receipts_drained(&self) -> bool {
        !self.pending
    }
    pub fn closed_and_drained(&mut self) -> bool {
        let status = self.shutdown_status();
        status.closed
            && self.receipts_drained()
            && status.unjoined == 0
            && status.panicked == 0
            && status.unclassified == 0
            && status.pending_pickers == 0
    }
}
impl Coincide {
    pub(super) fn sync_thread_bulk(&mut self, cx: &mut Context<Self>) {
        let binding = self.bulk_sidebar_binding(cx);
        self.thread_bulk.sync(binding);
        if self.media.close_requested || self.media.shutdown_requested {
            self.thread_bulk.close();
        }
    }
    pub(super) fn poll_thread_bulk(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let was_review = self.bulk_review_visible();
        self.sync_thread_bulk(cx);
        let previous = self.thread_bulk.status.clone();
        let was_busy = self.thread_bulk.busy();
        let owned_focus = self.thread_bulk_focus.contains_focused(window, cx);
        let effect = self.thread_bulk.poll();
        let is_review = self.bulk_review_visible();
        if !was_review && is_review {
            self.thread_bulk.restore_focus = window.focused(cx);
            self.bulk_review_focus.focus(window, cx);
        } else if was_review
            && !is_review
            && let Some(focus) = self.thread_bulk.restore_focus.take()
        {
            focus.focus(window, cx);
        }
        if let Some(effect) = effect {
            if owned_focus && self.thread_bulk.binding.available {
                self.thread_list_focus.focus(window, cx);
            }
            let updates = match effect {
                Effect::Applied(undo) => undo.applied_flags(),
                Effect::Undone(undo) => undo.restored_flags(),
                Effect::Prepared(_) => unreachable!(),
            };
            if let Some(selected) = self.selected.as_mut() {
                for (id, key, value) in updates {
                    if selected["id"] == id {
                        if let Some(value) = value {
                            selected[key] = value;
                        } else if let Some(object) = selected.as_object_mut() {
                            object.remove(key);
                        }
                    }
                }
            }
            self.status = self.thread_bulk.status.clone();
            self.refresh(cx);
        }
        // Only a current native plan prepared under an explicit opt-out can
        // auto-apply. Its previous worker has actually joined before this starts.
        if !self.thread_bulk.busy()
            && self
                .thread_bulk
                .review
                .as_ref()
                .is_some_and(|proof| !proof.requires_confirmation() && proof.count() > 0)
        {
            self.apply_bulk(cx);
        }
        if previous != self.thread_bulk.status || was_busy != self.thread_bulk.busy() {
            self.status = self.thread_bulk.status.clone();
            cx.notify();
        }
    }
    pub(super) fn bulk_row_click(
        &mut self,
        id: &str,
        selecting: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.sync_thread_bulk(cx);
        if selecting != self.thread_bulk.mode {
            self.thread_bulk.status = "Selection context changed; choose the row again.".into();
            cx.notify();
            return;
        }
        if self.thread_bulk.mode {
            if let Err(error) = self.thread_bulk.toggle(id) {
                self.thread_bulk.status = error.to_string();
            }
            cx.notify();
        } else {
            self.select(id, window, cx);
        }
    }
    pub(super) fn sidebar_modified_click(
        &mut self,
        id: &str,
        event: &ClickEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let modifiers = event.modifiers();
        let multiple = if cfg!(target_os = "macos") {
            modifiers.platform
        } else {
            modifiers.control
        };
        if !multiple && !modifiers.shift {
            return false;
        }
        self.sync_thread_bulk(cx);
        let binding = self.bulk_sidebar_binding(cx);
        if !binding.available {
            return true;
        }
        let rows = binding
            .rows
            .iter()
            .map(|row| row.0.as_str())
            .collect::<Vec<_>>();
        let Some(clicked) = rows.iter().position(|row| *row == id) else {
            return true;
        };
        let was_mode = self.thread_bulk.mode;
        self.thread_bulk.mode = true;
        if !was_mode && multiple {
            if let Some(current) = self
                .selected
                .as_ref()
                .and_then(|thread| thread["id"].as_str())
                .filter(|id| rows.contains(id))
            {
                self.thread_bulk.picked.insert(current.into());
            }
        }
        if modifiers.shift {
            let anchor = self
                .selected
                .as_ref()
                .and_then(|thread| thread["id"].as_str())
                .and_then(|id| rows.iter().position(|row| *row == id))
                .unwrap_or(clicked);
            let range = anchor.min(clicked)..=anchor.max(clicked);
            if range.clone().count() > LIMIT {
                self.thread_bulk.status = "Select at most 50 conversations.".into();
                cx.notify();
                return true;
            }
            self.thread_bulk.picked = range.map(|index| rows[index].to_owned()).collect();
            self.thread_bulk.invalidate();
        } else if let Err(error) = self.thread_bulk.toggle(id) {
            self.thread_bulk.status = error.to_string();
        }
        self.thread_list_focus.focus(window, cx);
        cx.notify();
        true
    }
    fn bulk_drafts_clean(&self, ids: &[String]) -> bool {
        !ids.iter().any(|id| self.pending_drafts.contains_key(id))
    }
    pub(super) fn review_bulk(&mut self, action: Action, window: &Window, cx: &mut Context<Self>) {
        self.sync_thread_bulk(cx);
        let ids: Vec<_> = self.thread_bulk.picked.iter().cloned().collect();
        if ids.is_empty() || !self.bulk_drafts_clean(&ids) {
            self.thread_bulk.status =
                "Select conversations whose drafts have finished saving.".into();
            cx.notify();
            return;
        }
        self.thread_bulk.anchor = Some(self.sidebar_review_anchor("thread", &ids[0], window));
        self.thread_bulk.review = None;
        self.thread_bulk
            .spawn(self.engine.clone(), Request::Prepare(ids, action));
        cx.notify();
    }
    fn apply_bulk(&mut self, cx: &mut Context<Self>) {
        self.sync_thread_bulk(cx);
        let ids: Vec<_> = self.thread_bulk.picked.iter().cloned().collect();
        if !self.bulk_drafts_clean(&ids) {
            self.thread_bulk.status = "Wait for selected drafts to save, then review again.".into();
            self.thread_bulk.invalidate();
            cx.notify();
            return;
        }
        if let Some(proof) = self.thread_bulk.review.clone() {
            if proof.count() > 0 {
                let unconfirmed = !proof.requires_confirmation();
                if self
                    .thread_bulk
                    .spawn(self.engine.clone(), Request::Apply(proof))
                    && unconfirmed
                {
                    // A failed opt-out transaction needs a fresh explicit action;
                    // never retry its stale proof automatically on later polls.
                    self.thread_bulk.review = None;
                }
            }
        }
        cx.notify();
    }
    pub(super) fn undo_bulk(&mut self, cx: &mut Context<Self>) {
        self.sync_thread_bulk(cx);
        if !self.thread_bulk.binding.available {
            self.thread_bulk.status = "Return to the conversation list before Undo.".into();
            cx.notify();
            return;
        }
        if let Some(undo) = self.thread_bulk.undo.clone() {
            let ids = undo.thread_ids();
            if self.bulk_drafts_clean(&ids) {
                self.thread_bulk
                    .spawn(self.engine.clone(), Request::Undo(undo));
            } else {
                self.thread_bulk.status =
                    "Wait for those drafts to finish saving before Undo.".into();
            }
        }
        cx.notify();
    }
    pub(super) fn toggle_sidebar(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.thread_bulk.close_selection();
        self.thread_list_open = !self.thread_list_open;
        self.remember_sidebar_visibility();
        if !self.thread_list_open && self.thread_list_focus.contains_focused(window, cx) {
            self.navigation_focus.focus(window, cx);
        }
        cx.notify();
    }
    pub(super) fn bulk_controls(&self, cx: &mut Context<Self>) -> AnyElement {
        let state = &self.thread_bulk;
        let busy = state.busy();
        let mut panel = div()
            .id("sidebar-bulk-controls")
            .track_focus(&self.thread_bulk_focus)
            .flex()
            .flex_col()
            .gap_2()
            .child(
                Button::new("sidebar-select-mode")
                    .ghost()
                    .compact()
                    .label(if state.mode {
                        "Done selecting"
                    } else {
                        "Select conversations…"
                    })
                    .disabled(busy || !state.binding.available)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.sync_thread_bulk(cx);
                        if this.thread_bulk.mode {
                            this.thread_bulk.close_selection();
                        } else if this.thread_bulk.binding.available {
                            this.thread_bulk.mode = true;
                            this.thread_bulk.invalidate();
                        }
                        cx.notify();
                    })),
            );
        if state.mode {
            panel = panel
                .child(div().text_xs().child(format!(
                    "{} selected · up to 50. Selecting keeps the open conversation unchanged.",
                    state.picked.len()
                )))
                .child(
                    div()
                        .flex()
                        .flex_wrap()
                        .gap_2()
                        .child(
                            Button::new("sidebar-select-visible")
                                .compact()
                                .label("Select visible")
                                .disabled(busy || state.binding.rows.len() > LIMIT)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.sync_thread_bulk(cx);
                                    if let Err(error) = this.thread_bulk.select_visible() {
                                        this.thread_bulk.status = error.to_string();
                                    }
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new("sidebar-selection-clear")
                                .compact()
                                .label("Clear")
                                .disabled(busy || state.picked.is_empty())
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.thread_bulk.picked.clear();
                                    this.thread_bulk.invalidate();
                                    cx.notify();
                                })),
                        ),
                );
            if state.binding.rows.len() > LIMIT {
                panel = panel.child(div().text_xs().child(
                    "More than 50 are visible. Narrow the filters or select up to 50 individually.",
                ));
            }
            let mut actions = div().flex().flex_wrap().gap_2();
            for action in [Action::Pin, Action::Unpin, Action::Archive, Action::Restore] {
                actions =
                    actions.child(
                        Button::new(SharedString::from(format!(
                            "sidebar-bulk-{}",
                            action.label().to_lowercase()
                        )))
                        .compact()
                        .label(action.label())
                        .disabled(busy || state.picked.is_empty())
                        .on_click(cx.listener(
                            move |this, _, window, cx| this.review_bulk(action, window, cx),
                        )),
                    );
            }
            // Swift's bulk Settle Threads, Unsettle Threads and Delete Threads.
            let running = state.picked.iter().any(|id| self.running.contains(id));
            for (id, label, action) in [
                ("settle", "Settle", sidebar_menus::BulkAction::Settle(true)),
                (
                    "unsettle",
                    "Unsettle",
                    sidebar_menus::BulkAction::Settle(false),
                ),
                ("delete", "Delete…", sidebar_menus::BulkAction::Delete),
            ] {
                actions = actions.child(
                    Button::new(SharedString::from(format!("sidebar-bulk-{id}")))
                        .compact()
                        .label(label)
                        .disabled(busy || state.picked.is_empty() || (id == "settle" && running))
                        .on_click(cx.listener(move |this, event, window, cx| {
                            let ids = this.thread_bulk.picked.iter().cloned().collect::<Vec<_>>();
                            this.sidebar_bulk_action(&ids, action, window, cx);
                            if matches!(action, sidebar_menus::BulkAction::Delete) {
                                this.anchor_sidebar_review_to_click(event, cx);
                            }
                        })),
                );
            }
            panel = panel.child(actions);
        }
        if let Some(undo) = &state.undo {
            panel = panel.child(
                Button::new("sidebar-bulk-undo")
                    .compact()
                    .label(format!("Undo {} ({})", undo.action().label(), undo.count()))
                    .disabled(busy || !state.binding.available)
                    .on_click(cx.listener(|this, _, _, cx| this.undo_bulk(cx))),
            );
        }
        if !state.status.is_empty() {
            panel = panel.child(div().text_xs().child(state.status.clone()));
        }
        panel.into_any_element()
    }

    pub(super) fn bulk_review_visible(&self) -> bool {
        self.thread_bulk
            .review
            .as_ref()
            .is_some_and(|proof| proof.requires_confirmation() || proof.count() == 0)
    }

    pub(super) fn cancel_bulk_review(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.thread_bulk.busy() {
            self.thread_bulk.cancel_review();
            if let Some(focus) = self.thread_bulk.restore_focus.take() {
                focus.focus(window, cx);
            }
            cx.notify();
        }
    }

    pub(super) fn bulk_review_dialog(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        use gpui_kit::base::FocusTrapElement;
        if !self.bulk_review_visible() {
            return None;
        }
        let proof = self.thread_bulk.review.as_ref()?;
        let busy = self.thread_bulk.busy();
        let mut titles = div().flex().flex_col().gap_1();
        for title in proof.titles() {
            titles = titles.child(div().text_sm().truncate().child(title));
        }
        if proof.count() > 8 {
            titles = titles.child(
                div()
                    .text_xs()
                    .child(format!("and {} more", proof.count() - 8)),
            );
        }
        let title = format!(
            "{} {} conversation(s)?",
            proof.action().label(),
            proof.count()
        );
        Some(div().id("bulk-review-overlay").absolute().inset_0().occlude()
            .on_mouse_down(MouseButton::Left, cx.listener(|this, _, window, cx| {
                cx.stop_propagation();
                this.cancel_bulk_review(window, cx);
            }))
            .child(anchored()
                .position(self.thread_bulk.anchor.unwrap_or(point(px(180.), px(90.))))
                .snap_to_window_with_margin(px(8.))
                .child(div().id("bulk-review-dialog").role(Role::Dialog)
                .track_focus(&self.bulk_review_focus).focus_trap("bulk-review-focus", &self.bulk_review_focus)
                .aria_label(title.clone())
                .w(px(300.)).max_w_full().max_h_full().rounded(px(12.)).border_1()
                .border_color(self.color(0x29303d)).bg(self.color(0x151922))
                .flex().flex_col().gap_3().p_3()
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(title))
                .child(div().id("bulk-review-titles").max_h(px(180.)).overflow_y_scroll().child(titles))
                .child(div().text_sm().text_color(self.color(0xe4e9f2).opacity(0.7))
                    .child("Only this setting changes. Undo is available for the latest batch."))
                .when(!self.thread_bulk.status.is_empty(), |view| view.child(div().text_sm().child(self.thread_bulk.status.clone())))
                .child(div().flex().justify_end().gap_2()
                    .child(Button::new("sidebar-bulk-discard").ghost().label("Cancel").disabled(busy)
                        .on_click(cx.listener(|this, _, window, cx| this.cancel_bulk_review(window, cx))))
                    .child(Button::new("sidebar-bulk-apply").primary().label("Apply")
                        .disabled(busy || proof.count() == 0)
                        .on_click(cx.listener(|this, _, _, cx| this.apply_bulk(cx)))))
            )).into_any_element())
    }

    pub(super) fn bulk_selection_overlay(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        self.thread_bulk.mode.then(|| {
            div()
                .id("bulk-selection-overlay")
                .absolute()
                .right(px(16.))
                .bottom(px(16.))
                .w(px(420.))
                .max_w_full()
                .p_4()
                .rounded(px(12.))
                .border_1()
                .border_color(self.color(0x29303d))
                .bg(self.color(0x151922))
                .child(self.bulk_controls(cx))
                .into_any_element()
        })
    }

    pub(super) fn bulk_notice(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        if self.thread_bulk.mode
            || !self.thread_bulk.notice_visible
            || self.thread_bulk.status.is_empty()
        {
            return None;
        }
        Some(
            div()
                .id("bulk-notice")
                .w(px(360.))
                .max_w_full()
                .p_3()
                .rounded(px(10.))
                .border_1()
                .border_color(self.color(0x29303d))
                .bg(self.color(0x151922))
                .flex()
                .items_center()
                .gap_2()
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_sm()
                        .child(self.thread_bulk.status.clone()),
                )
                .when(
                    self.thread_bulk.notice_undo && self.thread_bulk.undo.is_some(),
                    |view| {
                        view.child(
                            Button::new("bulk-notice-undo")
                                .ghost()
                                .compact()
                                .label("Undo")
                                .on_click(cx.listener(|this, _, _, cx| this.undo_bulk(cx))),
                        )
                    },
                )
                .child(
                    Button::new("bulk-notice-dismiss")
                        .ghost()
                        .compact()
                        .icon(gpui_kit::assets::IconName::X)
                        .accessibility_label("Dismiss notification")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.thread_bulk.notice_visible = false;
                            cx.notify();
                        })),
                )
                .into_any_element(),
        )
    }
}

#[cfg(test)]
#[path = "thread_bulk_tests.rs"]
mod tests;
