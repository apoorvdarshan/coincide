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
    Delete(String),
    Bot(String, Disposition),
}
enum Review {
    Move(PreparedThreadMove),
    Delete(PreparedThreadDeletion),
    Bot(PreparedBotDeletion),
    ChooseMove(String),
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
    status: String,
}
impl State {
    pub(super) fn visible(&self) -> bool {
        self.review.is_some() || self.undo.is_some() || !self.status.is_empty()
    }
}
impl Coincide {
    pub(super) fn sidebar_move_review(&mut self, id: String, cx: &mut Context<Self>) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        self.sidebar_lifecycle.review = Some(Review::ChooseMove(id));
        self.sidebar_lifecycle.stopping = false;
        self.sidebar_lifecycle.status="Choose the destination project. Existing folder sessions will not move into another folder.".into();
        cx.notify();
    }
    pub(super) fn sidebar_delete_review(&mut self, id: String, cx: &mut Context<Self>) {
        self.prepare_sidebar_lifecycle(Intent::Delete(id), cx);
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
                Intent::Delete(id) => Ok(Review::Delete(
                    engine.prepare_native_conversation_deletion(std::slice::from_ref(id))?,
                )),
                Intent::Bot(id, mode) => {
                    Ok(Review::Bot(engine.prepare_native_bot_deletion(id, *mode)?))
                }
            }
        })();
        self.sidebar_lifecycle.stopping = false;
        match result {
            Ok(review) => {
                self.sidebar_lifecycle.review = Some(review);
                self.sidebar_lifecycle.status =
                    "Review the exact scope, then confirm. Nothing has changed yet.".into();
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
                Intent::Move(id, _) | Intent::Delete(id) => {
                    let status = engine.dispatch(json!({"method":"app.status","params":{}}));
                    if status["result"]["running"].as_array().is_some_and(|rows| {
                        rows.iter()
                            .any(|row| row.as_str() == Some(id.as_str()) || row["threadId"] == *id)
                    }) {
                        engine.request_provider_stop(id)?;
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
    pub(super) fn poll_sidebar_lifecycle(&mut self, cx: &mut Context<Self>) {
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
                self.sidebar_lifecycle.status="Restored. Revoked native sessions remain unavailable until current account/folder admission permits a new turn.".into();
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
            Some(Review::ChooseMove(id)) => {
                for project in &self.projects {
                    let target = text(project, "id");
                    if target == coincide_core::bot_runtime::BOTS_PROJECT_ID {
                        continue;
                    }
                    let id = id.clone();
                    pane = pane.child(
                        Button::new(SharedString::from(format!("sidebar-move-target-{target}")))
                            .label(project["name"].as_str().unwrap_or("Project").to_owned())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.prepare_sidebar_lifecycle(
                                    Intent::Move(id.clone(), target.clone()),
                                    cx,
                                )
                            })),
                    );
                }
            }
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
