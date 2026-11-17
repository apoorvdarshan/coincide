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
    Archive(String, String),
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
    /// When `undo` was made, among the inbox's Undo receipts (`inbox_undo`).
    undo_stamp: u64,
    stopping: bool,
    auto_apply: bool,
    notice_visible: bool,
    notice_undo: bool,
    archive_notice_undo: Option<String>,
    status: String,
    restore_focus: Option<FocusHandle>,
    anchor: Option<Point<Pixels>>,
}
impl State {
    fn initial_delete(&self) -> bool {
        !self.stopping && !matches!(self.review, Some(Review::Waiting(_)))
    }
    pub(super) fn undo_stamp(&self) -> Option<u64> {
        self.undo.as_ref().map(|_| self.undo_stamp)
    }
    pub(super) fn review_visible(&self) -> bool {
        self.review.is_some() && !self.auto_apply
    }
    fn cancel_review(&mut self) {
        self.review = None;
        self.stopping = false;
        self.auto_apply = false;
        self.notice_visible = false;
        self.notice_undo = false;
        self.archive_notice_undo = None;
        self.status.clear();
        self.anchor = None;
    }
    pub(super) fn archive_for_other(&self, id: &str) -> bool {
        matches!(&self.review, Some(Review::Archive(current, _)) if current != id)
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
    /// Use the actual row's last painted bounds, including its scroll offset.
    pub(super) fn sidebar_review_anchor(
        &self,
        kind: &str,
        id: &str,
        window: &Window,
    ) -> Point<Pixels> {
        self.sidebar_row_bounds
            .lock()
            .ok()
            .and_then(|rows| rows.get(&format!("{kind}:{id}")).copied())
            .map(|bounds| point(bounds.right() + px(6.), bounds.top()))
            .unwrap_or_else(|| window.mouse_position())
    }
    /// The move review for a destination already chosen: a Move to Project
    /// submenu item, or threads dropped on a project.
    pub(super) fn sidebar_move_to(
        &mut self,
        id: String,
        target: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.sidebar_lifecycle.anchor = Some(self.sidebar_review_anchor("thread", &id, window));
        self.prepare_sidebar_lifecycle(Intent::Move(id, target), cx);
        self.focus_sidebar_lifecycle(window, cx);
    }
    pub(super) fn sidebar_delete_review(
        &mut self,
        id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.sidebar_delete_threads(vec![id], window, cx);
    }
    /// Swift's `ThreadActions.delete(_:in:)` for every selected conversation.
    pub(super) fn sidebar_delete_threads(
        &mut self,
        ids: Vec<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !ids.is_empty() {
            self.sidebar_lifecycle.anchor =
                Some(self.sidebar_review_anchor("thread", &ids[0], window));
            self.prepare_sidebar_lifecycle(Intent::Delete(ids), cx);
            self.focus_sidebar_lifecycle(window, cx);
        }
    }
    pub(super) fn sidebar_bot_delete_review(
        &mut self,
        id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        self.sidebar_lifecycle.anchor = Some(self.sidebar_review_anchor("bot", &id, window));
        self.sidebar_lifecycle.review = Some(Review::ChooseBot(id));
        self.sidebar_lifecycle.stopping = false;
        self.sidebar_lifecycle.notice_visible = false;
        self.sidebar_lifecycle.archive_notice_undo = None;
        self.sidebar_lifecycle.status.clear();
        self.focus_sidebar_lifecycle(window, cx);
        cx.notify();
    }
    pub(super) fn sidebar_archive_review(
        &mut self,
        id: String,
        title: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.sidebar_lifecycle.anchor = Some(self.sidebar_review_anchor("thread", &id, window));
        self.sidebar_lifecycle.review = Some(Review::Archive(id, title));
        self.sidebar_lifecycle.auto_apply = false;
        self.sidebar_lifecycle.stopping = false;
        self.sidebar_lifecycle.notice_visible = false;
        self.sidebar_lifecycle.archive_notice_undo = None;
        self.sidebar_lifecycle.status.clear();
        self.focus_sidebar_lifecycle(window, cx);
        cx.notify();
    }
    fn focus_sidebar_lifecycle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.sidebar_lifecycle.review_visible() {
            self.sidebar_lifecycle.restore_focus = window.focused(cx);
            self.sidebar_lifecycle_focus.focus(window, cx);
        }
    }
    fn prepare_sidebar_lifecycle(&mut self, intent: Intent, cx: &mut Context<Self>) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        let previously_waiting = !self.sidebar_lifecycle.initial_delete();
        self.sidebar_lifecycle.auto_apply = false;
        self.sidebar_lifecycle.notice_visible = false;
        self.sidebar_lifecycle.archive_notice_undo = None;
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
        if let Review::Archive(id, _) = &review {
            let archived = if self
                .selected
                .as_ref()
                .is_some_and(|thread| thread["id"] == *id)
                && !self.running.contains(id)
            {
                self.archive_open_thread(id, window, cx)
            } else {
                self.status =
                    "The conversation changed or is still running; archive was not applied.".into();
                false
            };
            self.sidebar_lifecycle.status = self.status.clone();
            self.sidebar_lifecycle.notice_visible = !self.status.is_empty();
            self.sidebar_lifecycle.notice_undo = false;
            self.sidebar_lifecycle.archive_notice_undo = archived.then(|| id.clone());
            self.sidebar_lifecycle.anchor = None;
            self.sidebar_lifecycle.restore_focus = None;
            self.thread_list_focus.focus(window, cx);
            cx.notify();
            return;
        }
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
        self.sidebar_lifecycle.archive_notice_undo = None;
        match result {
            Ok(undo) => {
                self.sidebar_lifecycle.undo = Some(undo);
                self.sidebar_lifecycle.undo_stamp = inbox_undo::stamp();
                self.sidebar_lifecycle.notice_visible = true;
                self.sidebar_lifecycle.notice_undo = true;
                self.sidebar_lifecycle.status =
                    "Completed. Undo is available while the reviewed content remains unchanged."
                        .into();
                self.refresh(cx);
                if let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) {
                    if self.threads.iter().any(|thread| thread.id == id) {
                        self.select(&id, window, cx);
                    } else {
                        self.replace_selected_thread(None);
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
                self.sidebar_lifecycle.notice_visible = true;
                self.sidebar_lifecycle.notice_undo = false;
                self.sidebar_lifecycle.status = format!(
                    "Operation was refused: {error}. Review again; no stale confirmation was reused."
                )
            }
        };
        if self.sidebar_lifecycle.review.is_none()
            && let Some(focus) = self.sidebar_lifecycle.restore_focus.take()
        {
            focus.focus(window, cx);
        }
        cx.notify();
    }
    pub(super) fn undo_sidebar_lifecycle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.media.shutdown_requested || self.media.close_requested {
            return;
        }
        if !self.flush_pending_drafts() {
            self.sidebar_lifecycle.status = "Save pending drafts before Undo.".into();
            self.sidebar_lifecycle.notice_visible = true;
            self.sidebar_lifecycle.notice_undo = self.sidebar_lifecycle.undo.is_some();
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
        self.sidebar_lifecycle.notice_visible = true;
        self.sidebar_lifecycle.notice_undo = self.sidebar_lifecycle.undo.is_some();
        cx.notify();
    }
    pub(super) fn cancel_sidebar_lifecycle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.sidebar_lifecycle.cancel_review();
        if let Some(focus) = self.sidebar_lifecycle.restore_focus.take() {
            focus.focus(window, cx);
        }
        cx.notify();
    }

    /// Reviews are modal and never take space away from the navigation list.
    pub(super) fn sidebar_lifecycle_dialog(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        use gpui_kit::base::FocusTrapElement;
        if !self.sidebar_lifecycle.review_visible() {
            return None;
        }
        let review = self.sidebar_lifecycle.review.as_ref()?;
        let (title, detail) = match review {
            Review::ChooseBot(id) => {
                let name = self
                    .sidebar_bots
                    .iter()
                    .find(|bot| text(bot, "id") == *id)
                    .and_then(|bot| bot["name"].as_str())
                    .filter(|name| !name.is_empty())
                    .unwrap_or("this bot");
                (format!("Delete {name}?"),
                 "Choose what happens to its conversations. Linked scheduled tasks will be removed.".to_owned())
            }
            Review::Waiting(_) => (
                "Review unavailable".into(),
                self.sidebar_lifecycle.status.clone(),
            ),
            Review::Archive(_, title) => (
                "Archive conversation?".into(),
                format!("{title} can be restored from Archive."),
            ),
            Review::Move(plan) => (
                "Move conversation?".into(),
                format!(
                    "Move {} to {}. Conversation content will be kept; the new folder starts a fresh session.",
                    plan.title(),
                    plan.destination().display()
                ),
            ),
            Review::Delete(plan) => (
                "Delete conversations?".into(),
                format!(
                    "Delete {} conversation(s): {}. Transcripts and drafts will be removed. Undo remains available for this app session.",
                    plan.count(),
                    plan.titles().join(", ")
                ),
            ),
            Review::Bot(plan) => (
                format!("Delete {}?", plan.name()),
                format!(
                    "{} conversation(s), {} scheduled task(s). {}.{}",
                    plan.conversation_count(),
                    plan.task_count(),
                    if plan.disposition() == Disposition::Delete {
                        "Conversations will be deleted"
                    } else {
                        "Conversations will be kept as Chats"
                    },
                    plan.chats_folder()
                        .map(|path| format!(" Chats folder: {}", path.display()))
                        .unwrap_or_default()
                ),
            ),
        };
        let mut actions = div().flex().flex_col().gap_2();
        match review {
            Review::ChooseBot(id) => {
                for (label, mode) in [
                    ("Keep conversations as chats", Disposition::KeepAsChats),
                    ("Delete conversations", Disposition::Delete),
                ] {
                    let id = id.clone();
                    actions = actions.child(
                        Button::new(SharedString::from(format!("sidebar-bot-mode-{mode:?}")))
                            .w_full()
                            .label(label)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.prepare_sidebar_lifecycle(Intent::Bot(id.clone(), mode), cx)
                            })),
                    );
                }
            }
            Review::Waiting(intent) => {
                let intent = intent.clone();
                actions = actions
                    .child(
                        Button::new("sidebar-lifecycle-retry")
                            .label("Retry review")
                            .disabled(self.sidebar_lifecycle.stopping)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.prepare_sidebar_lifecycle(intent.clone(), cx)
                            })),
                    )
                    .child(
                        Button::new("sidebar-lifecycle-stop")
                            .label("Stop and wait for cleanup")
                            .disabled(self.sidebar_lifecycle.stopping)
                            .on_click(
                                cx.listener(|this, _, _, cx| this.stop_sidebar_lifecycle(cx)),
                            ),
                    );
            }
            _ => {
                let is_delete = matches!(review, Review::Delete(_) | Review::Bot(_));
                let label = if matches!(review, Review::Bot(_)) {
                    "Delete bot"
                } else if matches!(review, Review::Archive(_, _)) {
                    "Archive"
                } else if is_delete {
                    "Delete"
                } else {
                    "Move"
                };
                actions = actions.child(
                    Button::new("sidebar-lifecycle-confirm")
                        .label(label)
                        .when(is_delete, |button| button.danger())
                        .when(!is_delete, |button| button.primary())
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.apply_sidebar_lifecycle(window, cx)
                        })),
                );
            }
        }
        let panel = div()
            .id("sidebar-lifecycle-dialog")
            .role(Role::Dialog)
            .track_focus(&self.sidebar_lifecycle_focus)
            .focus_trap("sidebar-lifecycle-focus", &self.sidebar_lifecycle_focus)
            .aria_label(title.clone())
            .w(px(300.))
            .max_w_full()
            .max_h_full()
            .rounded(px(14.))
            .border_1()
            .border_color(self.color(0x29303d))
            .bg(self.color(0x151922))
            .flex()
            .flex_col()
            .overflow_hidden()
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(
                div()
                    .px_3()
                    .pt_3()
                    .pb_2()
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(
                        div()
                            .flex_1()
                            .text_lg()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(title),
                    )
                    .child(
                        Button::new("sidebar-lifecycle-close")
                            .ghost()
                            .compact()
                            .icon(gpui_kit::assets::IconName::X)
                            .accessibility_label("Close review")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.cancel_sidebar_lifecycle(window, cx)
                            })),
                    ),
            )
            .child(
                div()
                    .id("sidebar-lifecycle-detail")
                    .px_3()
                    .pb_3()
                    .max_h(px(140.))
                    .overflow_y_scroll()
                    .text_sm()
                    .text_color(self.color(0xe4e9f2).opacity(0.78))
                    .child(detail)
                    .when(
                        !matches!(review, Review::ChooseBot(_) | Review::Waiting(_))
                            && !self.sidebar_lifecycle.status.is_empty()
                            && self.sidebar_lifecycle.status
                                != "Review the exact scope, then confirm. Nothing has changed yet.",
                        |view| {
                            view.child(div().pt_2().child(self.sidebar_lifecycle.status.clone()))
                        },
                    ),
            )
            .child(
                div()
                    .px_3()
                    .pb_3()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(actions)
                    .child(
                        Button::new("sidebar-lifecycle-cancel")
                            .ghost()
                            .label("Cancel")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.cancel_sidebar_lifecycle(window, cx)
                            })),
                    ),
            );
        Some(
            div()
                .id("sidebar-lifecycle-overlay")
                .absolute()
                .inset_0()
                .occlude()
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|this, _, window, cx| {
                        cx.stop_propagation();
                        this.cancel_sidebar_lifecycle(window, cx);
                    }),
                )
                .child(
                    anchored()
                        .position(
                            self.sidebar_lifecycle
                                .anchor
                                .unwrap_or(point(px(180.), px(90.))),
                        )
                        .snap_to_window_with_margin(px(8.))
                        .child(panel),
                )
                .into_any_element(),
        )
    }

    /// Completion and errors stay dismissible, while Undo retains its receipt.
    pub(super) fn sidebar_lifecycle_notice(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        if !self.sidebar_lifecycle.notice_visible || self.sidebar_lifecycle.review_visible() {
            return None;
        }
        let archive_undo = self.sidebar_lifecycle.archive_notice_undo.clone();
        Some(
            div()
                .id("sidebar-lifecycle-notice")
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
                        .child(self.sidebar_lifecycle.status.clone()),
                )
                .when(
                    (self.sidebar_lifecycle.notice_undo && self.sidebar_lifecycle.undo.is_some())
                        || archive_undo.is_some(),
                    |view| {
                        view.child(
                            Button::new("sidebar-lifecycle-undo")
                                .ghost()
                                .compact()
                                .label("Undo")
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    if let Some(id) = &archive_undo {
                                        this.undo_archive_from_notice(id, cx);
                                        this.sidebar_lifecycle.status = this.status.clone();
                                        this.sidebar_lifecycle.archive_notice_undo = None;
                                        cx.notify();
                                    } else {
                                        this.undo_sidebar_lifecycle(window, cx);
                                    }
                                })),
                        )
                    },
                )
                .child(
                    Button::new("sidebar-lifecycle-dismiss")
                        .ghost()
                        .compact()
                        .icon(gpui_kit::assets::IconName::X)
                        .accessibility_label("Dismiss notification")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.sidebar_lifecycle.notice_visible = false;
                            cx.notify();
                        })),
                )
                .into_any_element(),
        )
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

    #[::core::prelude::v1::test]
    fn cancelling_a_bot_review_dismisses_the_entire_notice() {
        let mut state = State::default();
        state.review = Some(Review::ChooseBot("synthetic-bot".into()));
        state.status = "A review was pending".into();
        state.notice_visible = true;
        state.stopping = true;
        state.auto_apply = true;
        state.cancel_review();
        assert!(state.review.is_none());
        assert!(!state.review_visible());
        assert!(!state.notice_visible);
        assert!(state.status.is_empty());
        assert!(!state.stopping && !state.auto_apply);
    }

    #[::core::prelude::v1::test]
    fn archive_review_is_bound_to_the_conversation_it_opened_for() {
        let mut state = State::default();
        state.review = Some(Review::Archive("thread-a".into(), "A".into()));
        assert!(!state.archive_for_other("thread-a"));
        assert!(state.archive_for_other("thread-b"));
        state.cancel_review();
        assert!(!state.review_visible());
        assert!(!state.archive_for_other("thread-b"));
    }
}
