//! Explicit native lifecycle review. Local SQL remains bounded by Core; Stop
//! requests are observed through actual provider joins before a new review.
use super::*;
use coincide_core::api::{
    BotConversationDisposition as Disposition, BotDeletionUndo, PreparedBotDeletion,
    PreparedThreadDeletion, PreparedThreadMove, ThreadDeletionUndo, ThreadMoveUndo,
};
#[derive(Clone)]
enum Intent {
    Move(String, String),
    Delete(Vec<String>),
    Bot(String, Disposition),
}
enum Review {
    Move(PreparedThreadMove),
    Delete(PreparedThreadDeletion),
    Bot(PreparedBotDeletion),
    ChooseBot(String),
    Waiting(Intent),
}
enum Undo {
    Move(ThreadMoveUndo),
    Delete(ThreadDeletionUndo),
    Bot(BotDeletionUndo),
}
#[derive(Default)]
pub(super) struct State {
    review: Option<Review>,
    undo: Option<Undo>,
    stopping: bool,
    auto_apply: bool,
    status: String,
}
impl State {
    fn initial_delete(&self) -> bool {
        !self.stopping && !matches!(self.review, Some(Review::Waiting(_)))
    }
    pub(super) fn visible(&self) -> bool {
        self.review.is_some() || self.undo.is_some() || !self.status.is_empty()
    }
}
fn stop_if_running(engine: &mut Engine, id: &str) -> Result<()> {
    let status = engine.dispatch(json!({"method":"app.status","params":{}}));
    if status["result"]["running"].as_array().is_some_and(|rows| {
        rows.iter()
            .any(|row| row.as_str() == Some(id) || row["threadId"] == *id)
    }) {
        engine.request_provider_stop(id)?;
    }
    Ok(())
}
impl Coincide {
    /// The move review for a destination already chosen: a Move to Project
    /// submenu item, or threads dropped on a project.
    pub(super) fn sidebar_move_to(&mut self, id: String, target: String, cx: &mut Context<Self>) {
        self.prepare_sidebar_lifecycle(Intent::Move(id, target), cx);
    }
    pub(super) fn sidebar_delete_review(&mut self, id: String, cx: &mut Context<Self>) {
        self.sidebar_delete_threads(vec![id], cx);
    }
    /// Swift's `ThreadActions.delete(_:in:)` for every selected conversation.
    pub(super) fn sidebar_delete_threads(&mut self, ids: Vec<String>, cx: &mut Context<Self>) {
        if !ids.is_empty() {
            self.prepare_sidebar_lifecycle(Intent::Delete(ids), cx);
        }
    }
    pub(super) fn sidebar_bot_delete_review(&mut self, id: String, cx: &mut Context<Self>) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        self.sidebar_lifecycle.review = Some(Review::ChooseBot(id));
        self.sidebar_lifecycle.stopping = false;
        self.sidebar_lifecycle.status="Choose whether to keep this bot's conversations as ordinary chats or delete them. Linked scheduled tasks will also be removed after confirmation.".into();
        cx.notify();
    }
    fn prepare_sidebar_lifecycle(&mut self, intent: Intent, cx: &mut Context<Self>) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        let previously_waiting = !self.sidebar_lifecycle.initial_delete();
        self.sidebar_lifecycle.auto_apply = false;
        if !self.flush_pending_drafts() {
            self.sidebar_lifecycle.review = Some(Review::Waiting(intent));
            self.sidebar_lifecycle.status =
                "Pending drafts must save before preparing a lifecycle review.".into();
            cx.notify();
            return;
        }
        let result = (|| -> Result<Review> {
            let mut engine = try_state(&self.engine)?;
            match &intent {
                Intent::Move(id, target) => {
                    Ok(Review::Move(engine.prepare_native_thread_move(id, target)?))
                }
                Intent::Delete(ids) => Ok(Review::Delete(if previously_waiting {
                    engine.prepare_native_conversation_deletion(ids)?
                } else {
                    engine.prepare_native_sidebar_conversation_deletion(ids)?
                })),
                Intent::Bot(id, mode) => {
                    Ok(Review::Bot(engine.prepare_native_bot_deletion(id, *mode)?))
                }
            }
        })();
        self.sidebar_lifecycle.stopping = false;
        match result {
            Ok(review) => {
                self.sidebar_lifecycle.auto_apply =
                    matches!(&review, Review::Delete(plan) if !plan.requires_confirmation());
                self.sidebar_lifecycle.review = Some(review);
                self.sidebar_lifecycle.status = if self.sidebar_lifecycle.auto_apply {
                    "Applying your saved confirmation preference to this idle conversation.".into()
                } else {
                    "Review the exact scope, then confirm. Nothing has changed yet.".into()
                };
            }
            Err(error) => {
                self.sidebar_lifecycle.review = Some(Review::Waiting(intent));
                self.sidebar_lifecycle.status = error.to_string();
            }
        }
        cx.notify();
    }
    fn stop_sidebar_lifecycle(&mut self, cx: &mut Context<Self>) {
        let Some(Review::Waiting(intent)) = &self.sidebar_lifecycle.review else {
            return;
        };
        let intent = intent.clone();
        let result = (|| -> Result<()> {
            let mut engine = try_state(&self.engine)?;
            match &intent {
                Intent::Bot(id, _) => {
                    engine.request_native_bot_stop(id)?;
                }
                Intent::Move(id, _) => stop_if_running(&mut engine, id)?,
                Intent::Delete(ids) => {
                    for id in ids {
                        stop_if_running(&mut engine, id)?;
                    }
                }
            }
            Ok(())
        })();
        match result {
            Ok(()) => {
                self.sidebar_lifecycle.stopping = true;
                self.sidebar_lifecycle.status="Stop requested. Waiting for actual provider cleanup before preparing a fresh confirmation.".into();
            }
            Err(error) => self.sidebar_lifecycle.status = error.to_string(),
        };
        cx.notify();
    }
    pub(super) fn poll_sidebar_lifecycle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.sidebar_lifecycle.auto_apply {
            self.sidebar_lifecycle.auto_apply = false;
            if matches!(&self.sidebar_lifecycle.review, Some(Review::Delete(plan)) if !plan.requires_confirmation())
            {
                self.apply_sidebar_lifecycle(window, cx);
            }
        }
        if !self.sidebar_lifecycle.stopping {
            return;
        }
        if self.media.shutdown_requested || self.media.close_requested {
            self.sidebar_lifecycle.stopping = false;
            self.sidebar_lifecycle.review = None;
            return;
        }
        let ready = try_state(&self.engine).is_ok_and(|mut engine| {
            let status = engine.provider_workers_status();
            status.running == 0 && status.panicked == 0 && status.unclassified == 0
        });
        if ready && let Some(Review::Waiting(intent)) = &self.sidebar_lifecycle.review {
            self.prepare_sidebar_lifecycle(intent.clone(), cx);
        }
    }
    fn apply_sidebar_lifecycle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.sidebar_lifecycle.auto_apply = false;
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        if !self.flush_pending_drafts() {
            self.sidebar_lifecycle.status =
                "Save pending drafts before confirming this operation.".into();
            cx.notify();
            return;
        }
        let Some(review) = self.sidebar_lifecycle.review.take() else {
            return;
        };
        let result = (|| -> Result<Undo> {
            let mut engine = try_state(&self.engine)?;
            match review {
                Review::Move(plan) => Ok(Undo::Move(engine.apply_native_thread_move(plan)?)),
                Review::Delete(plan) => {
                    Ok(Undo::Delete(engine.apply_native_thread_deletion(plan)?))
                }
                Review::Bot(plan) => Ok(Undo::Bot(engine.apply_native_bot_deletion(plan)?)),
                other => {
                    self.sidebar_lifecycle.review = Some(other);
                    anyhow::bail!("Prepare a fresh confirmation first")
                }
            }
        })();
        match result {
            Ok(undo) => {
                self.sidebar_lifecycle.undo = Some(undo);
                self.sidebar_lifecycle.status =
                    "Completed. Undo is available while the reviewed content remains unchanged."
                        .into();
                self.refresh(cx);
                if let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) {
                    if self.threads.iter().any(|thread| thread.id == id) {
                        self.select(&id, window, cx);
                    } else {
                        self.selected = None;
                        self.pending_native_selection = Some(None);
                        self.transcript_count = 0;
                        self.transcript_list.reset(0);
                        self.expanded.clear();
                        self.composer
                            .update(cx, |input, cx| input.set_value("", window, cx));
                        self.invalidate_native_conversation_view();
                        self.sync_workspace_context(cx);
                    }
                }
            }
            Err(error) => {
                self.sidebar_lifecycle.status = format!(
                    "Operation was refused: {error}. Review again; no stale confirmation was reused."
                )
            }
        };
        cx.notify();
    }
    fn undo_sidebar_lifecycle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        if !self.flush_pending_drafts() {
            self.sidebar_lifecycle.status = "Save pending drafts before Undo.".into();
            cx.notify();
            return;
        }
        let result = (|| -> Result<()> {
            let undo = self
                .sidebar_lifecycle
                .undo
                .as_ref()
                .context("No native Undo receipt")?;
            let mut engine = try_state(&self.engine)?;
            match undo {
                Undo::Move(undo) => engine.undo_native_thread_move(undo),
                Undo::Delete(undo) => engine.undo_native_thread_deletion(undo),
                Undo::Bot(undo) => engine.undo_native_bot_deletion(undo),
            }
        })();
        match result {
            Ok(()) => {
                self.sidebar_lifecycle.undo = None;
                self.sidebar_lifecycle.status = "Restored.".into();
                self.refresh(cx);
                if let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) {
                    self.select(&id, window, cx);
                }
            }
            Err(error) => self.sidebar_lifecycle.status = format!("Undo was refused: {error}"),
        };
        cx.notify();
    }
    pub(super) fn sidebar_lifecycle_controls(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut pane = div()
            .id("sidebar-native-lifecycle")
            .flex()
            .flex_col()
            .gap_2()
            .p_2()
            .border_1()
            .border_color(cx.theme().border)
            .child(self.sidebar_lifecycle.status.clone());
        match &self.sidebar_lifecycle.review {
            Some(Review::ChooseBot(id)) => {
                for (label, mode) in [
                    ("Keep Conversations as Chats", Disposition::KeepAsChats),
                    ("Delete Bot and Conversations", Disposition::Delete),
                ] {
                    let id = id.clone();
                    pane = pane.child(
                        Button::new(SharedString::from(format!("sidebar-bot-mode-{mode:?}")))
                            .label(label)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.prepare_sidebar_lifecycle(Intent::Bot(id.clone(), mode), cx)
                            })),
                    );
                }
            }
            Some(Review::Waiting(intent)) => {
                let intent = intent.clone();
                pane = pane
                    .child(
                        Button::new("sidebar-lifecycle-retry")
                            .label("Retry Review")
                            .disabled(self.sidebar_lifecycle.stopping)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.prepare_sidebar_lifecycle(intent.clone(), cx)
                            })),
                    )
                    .child(
                        Button::new("sidebar-lifecycle-stop")
                            .label("Stop and Wait for Cleanup")
                            .disabled(self.sidebar_lifecycle.stopping)
                            .on_click(
                                cx.listener(|this, _, _, cx| this.stop_sidebar_lifecycle(cx)),
                            ),
                    );
            }
            Some(review) => {
                let (summary, label) = match review {
                    Review::Move(plan) => (
                        format!(
                            "Move {} to {}. Keep all conversation content; start fresh in the new folder.",
                            plan.title(),
                            plan.destination().display()
                        ),
                        "Confirm Move",
                    ),
                    Review::Delete(plan) => (
                        format!(
                            "Delete {} conversation(s): {}. Transcript and drafts are removed; native Undo is retained for this app session.",
                            plan.count(),
                            plan.titles().join(", ")
                        ),
                        "Confirm Delete",
                    ),
                    Review::Bot(plan) => (
                        format!(
                            "Delete bot {}: {} conversation(s), {} scheduled task(s); {}. {}",
                            plan.name(),
                            plan.conversation_count(),
                            plan.task_count(),
                            if plan.disposition() == Disposition::Delete {
                                "delete conversations"
                            } else {
                                "keep conversations as Chats"
                            },
                            plan.chats_folder()
                                .map(|path| format!("Chats folder: {}", path.display()))
                                .unwrap_or_default()
                        ),
                        "Confirm Bot Deletion",
                    ),
                    _ => unreachable!(),
                };
                pane = pane.child(summary).child(
                    Button::new("sidebar-lifecycle-confirm")
                        .label(label)
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.apply_sidebar_lifecycle(window, cx)
                        })),
                );
            }
            None => {}
        }
        if self.sidebar_lifecycle.review.is_some() {
            pane=pane.child(Button::new("sidebar-lifecycle-cancel").label("Cancel Review").on_click(cx.listener(|this,_,_,cx|{this.sidebar_lifecycle.review=None;this.sidebar_lifecycle.stopping=false;this.sidebar_lifecycle.status="Review cancelled; no metadata was changed. A requested Stop still completes its owned cleanup.".into();cx.notify();})));
        }
        if self.sidebar_lifecycle.undo.is_some() {
            pane = pane.child(
                Button::new("sidebar-lifecycle-undo")
                    .label("Undo Last Lifecycle Change")
                    .on_click(
                        cx.listener(|this, _, window, cx| this.undo_sidebar_lifecycle(window, cx)),
                    ),
            );
        }
        div()
            .id("sidebar-lifecycle-scroll")
            .h(px(220.))
            .min_h(px(100.))
            .flex_shrink_0()
            .overflow_y_scroll()
            .child(pane)
            .into_any_element()
    }
}

#[cfg(test)]
mod confirmation_policy_tests {
    use super::{Intent, Review, State};
    #[::core::prelude::v1::test]
    fn initial_delete_opt_out_is_never_reused_after_wait_or_stop() {
        let mut state = State::default();
        assert!(state.initial_delete());
        state.review = Some(Review::Waiting(Intent::Delete(vec![
            "synthetic-thread".into(),
        ])));
        assert!(
            !state.initial_delete(),
            "draft, persistence or worker recovery requires review"
        );
        state.stopping = true;
        assert!(!state.initial_delete());
        state.review = None;
        assert!(
            !state.initial_delete(),
            "a Stop path still requires fresh review after worker cleanup"
        );
    }
}
