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
    workers: worker_owner::WorkerOwner,
    sender: mpsc::SyncSender<Reply>,
    receiver: mpsc::Receiver<Reply>,
    pending: bool,
    unjoined: bool,
    ambiguous: bool,
    pub status: String,
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
            workers: Default::default(),
            sender,
            receiver,
            pending: false,
            unjoined: false,
            ambiguous: false,
            status: String::new(),
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
    fn busy(&self) -> bool {
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
                    Request::Prepare(ids, action) => Ok(Effect::Prepared(Arc::new(
                        engine.prepare_thread_flags(&ids, action)?,
                    ))),
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
                self.status = format!(
                    "{} applied to {} conversation(s). Undo is available for this latest batch.",
                    undo.action().label(),
                    undo.count()
                );
                self.undo = Some(undo.clone());
                self.review = None;
                if reply.generation == self.epoch.load(Ordering::Acquire) {
                    self.picked.clear();
                    self.mode = false;
                }
                Some(Effect::Applied(undo))
            }
            Ok(Effect::Undone(undo)) => {
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
                None
            }
        }
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
        self.sync_thread_bulk(cx);
        let previous = self.thread_bulk.status.clone();
        let was_busy = self.thread_bulk.busy();
        let owned_focus = self.thread_bulk_focus.contains_focused(window, cx);
        let effect = self.thread_bulk.poll();
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
    fn bulk_drafts_clean(&self, ids: &[String]) -> bool {
        !ids.iter().any(|id| self.pending_drafts.contains_key(id))
    }
    fn review_bulk(&mut self, action: Action, cx: &mut Context<Self>) {
        self.sync_thread_bulk(cx);
        let ids: Vec<_> = self.thread_bulk.picked.iter().cloned().collect();
        if ids.is_empty() || !self.bulk_drafts_clean(&ids) {
            self.thread_bulk.status =
                "Select conversations whose drafts have finished saving.".into();
            cx.notify();
            return;
        }
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
                self.thread_bulk
                    .spawn(self.engine.clone(), Request::Apply(proof));
            }
        }
        cx.notify();
    }
    fn undo_bulk(&mut self, cx: &mut Context<Self>) {
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
                actions = actions.child(
                    Button::new(SharedString::from(format!(
                        "sidebar-bulk-{}",
                        action.label().to_lowercase()
                    )))
                    .compact()
                    .label(action.label())
                    .disabled(busy || state.picked.is_empty())
                    .on_click(cx.listener(move |this, _, _, cx| this.review_bulk(action, cx))),
                );
            }
            panel = panel.child(actions);
        }
        if let Some(proof) = &state.review {
            let mut review = div()
                .id("sidebar-bulk-review")
                .max_h(px(240.))
                .overflow_y_scroll()
                .flex()
                .flex_col()
                .gap_1()
                .p_2()
                .border_1()
                .border_color(self.color(0x29303d))
                .child(format!(
                    "{} {} conversation(s)?",
                    proof.action().label(),
                    proof.count()
                ));
            for title in proof.titles() {
                review = review.child(div().text_xs().truncate().child(title));
            }
            if proof.count() > 8 {
                review = review.child(
                    div()
                        .text_xs()
                        .child(format!("and {} more", proof.count() - 8)),
                );
            }
            review=review.child(div().text_xs().child("Only this flag changes. Undo covers the latest batch and refuses to replace later edits."))
                .child(Button::new("sidebar-bulk-apply").label("Apply reviewed change").disabled(busy || proof.count()==0).on_click(cx.listener(|this,_,_,cx|this.apply_bulk(cx))))
                .child(Button::new("sidebar-bulk-discard").ghost().compact().label("Cancel review").disabled(busy).on_click(cx.listener(|this,_,window,cx|{this.thread_bulk.invalidate();this.thread_bulk_focus.focus(window,cx);cx.notify();})));
            panel = panel.child(review);
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
}

#[cfg(test)]
#[path = "thread_bulk_tests.rs"]
mod tests;
