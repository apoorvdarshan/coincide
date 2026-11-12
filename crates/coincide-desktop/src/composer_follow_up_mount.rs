//! Native composer choices and owner-bound delivery tickets. Nothing here is a
//! command/RPC route; only the visible editor's actions create a delivery.
use super::*;
use coincide_core::{
    api::{NativeFollowUpStatus, NativeFollowUpTicket},
    composer_follow_up::{self as choice, Behavior, Dispatch},
};
#[derive(Debug, PartialEq, Eq)]
pub(super) enum SendRoute {
    WaitForImages,
    FollowUp,
    WaitForSelection,
    Send,
}

pub(super) fn send_route(running: bool, importing: bool, changing_selection: bool) -> SendRoute {
    if importing {
        SendRoute::WaitForImages
    } else if running {
        SendRoute::FollowUp
    } else if changing_selection {
        SendRoute::WaitForSelection
    } else {
        SendRoute::Send
    }
}
pub(super) struct PendingDelivery {
    ticket: Option<NativeFollowUpTicket>,
    thread: String,
    draft: String,
    queued: bool,
    image_send: Option<u64>,
}
/// A send waiting for a local prerequisite, bound to the original settings.
#[derive(Clone)]
pub(super) struct PendingSend {
    pub thread: String,
    pub draft: String,
    pub alternate: bool,
    pub selection: Value,
    pub waiting_for_import: bool,
    pub import_failed: bool,
    pub captured: Value,
    pub last_error: Option<String>,
}
impl PendingSend {
    pub fn new(thread: &Value, draft: String, alternate: bool) -> Self {
        let mut captured = pending_scope(thread, false);
        captured["id"] = thread["id"].clone();
        captured["draft"] = json!(draft);
        captured["rustDraftImages"] = thread["rustDraftImages"].clone();
        Self {
            thread: text(thread, "id"),
            draft,
            alternate,
            selection: pending_scope(thread, false),
            waiting_for_import: false,
            import_failed: false,
            captured,
            last_error: None,
        }
    }
    pub fn during_import(thread: &Value, draft: String, alternate: bool) -> Self {
        let mut pending = Self::new(thread, draft, alternate);
        pending.selection = pending_scope(thread, true);
        pending.waiting_for_import = true;
        pending
    }
    pub fn finish_import(&mut self, thread: &Value) {
        let mut images = self.captured["rustDraftImages"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        for image in thread["rustDraftImages"].as_array().into_iter().flatten() {
            if !images.contains(image) {
                images.push(image.clone());
            }
        }
        self.captured["rustDraftImages"] = json!(images);
        self.selection["images"] = self.captured["rustDraftImages"].clone();
        self.waiting_for_import = false;
    }
    pub fn matches(&self, thread: &Value, draft: &str) -> bool {
        self.thread == text(thread, "id")
            && self.draft == draft
            && self.selection == pending_scope(thread, self.waiting_for_import)
    }
}
fn pending_scope(thread: &Value, ignore_images: bool) -> Value {
    let mut scope = json!({"selection":thread["selection"],"accessMode":thread["accessMode"],
        "interactionMode":thread["interactionMode"],"projectID":thread["projectID"],
        "projectPath":thread["projectPath"],"worktreePath":thread["worktreePath"],
        "draftContext":thread["draftContext"],"followUpBehavior":thread["followUpBehavior"],
        "botID":thread["botID"],"rustBotContext":thread["rustBotContext"]});
    if !ignore_images {
        scope["images"] = thread["rustDraftImages"].clone();
    }
    scope
}
#[derive(Clone, Default, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_follow_up, no_json, no_register)]
struct ModifiedSend;
#[derive(Clone, Default, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_follow_up, no_json, no_register)]
struct ShiftModifiedSend;
pub(super) fn init(cx: &mut App) {
    let (send, alternate) = if cfg!(target_os = "macos") {
        ("cmd-enter", "cmd-shift-enter")
    } else {
        ("ctrl-enter", "ctrl-shift-enter")
    };
    cx.bind_keys([
        KeyBinding::new(send, ModifiedSend, Some("CoincideFileSuggestions > Input")),
        KeyBinding::new(
            alternate,
            ShiftModifiedSend,
            Some("CoincideFileSuggestions > Input"),
        ),
    ]);
}
impl Coincide {
    pub(super) fn track_queued_delivery(&mut self, ticket: NativeFollowUpTicket, thread: String) {
        self.follow_up_deliveries.push(PendingDelivery {
            ticket: Some(ticket),
            thread,
            draft: String::new(),
            queued: true,
            image_send: None,
        });
    }

    pub(super) fn follow_up_key_scope(&self, scope: Div, cx: &mut Context<Self>) -> Div {
        scope
            .capture_action(cx.listener(|this, _: &ModifiedSend, window, cx| {
                if !this.composer_send_visible() {
                    return;
                }
                let alternate = this.settings["sendOnReturn"].as_bool().unwrap_or(true);
                this.send_selected(alternate, window, cx);
                window.prevent_default();
                cx.stop_propagation();
            }))
            .capture_action(cx.listener(|this, _: &ShiftModifiedSend, window, cx| {
                if !this.composer_send_visible() {
                    return;
                }
                if !this.settings["sendOnReturn"].as_bool().unwrap_or(true) {
                    this.send_selected(true, window, cx);
                } else if !this.send_next_queued_now(cx) {
                    return;
                }
                window.prevent_default();
                cx.stop_propagation();
            }))
    }
    fn composer_send_visible(&self) -> bool {
        self.chat_visible() && !self.composer_files.opened
    }
    pub(super) fn follow_up_button(&self, compact: bool, cx: &mut Context<Self>) -> AnyElement {
        let Some(thread) = self.selected.as_ref() else {
            return div().into_any_element();
        };
        let behavior = choice::effective(
            choice::selected(thread, &self.settings),
            matches!(
                thread["selection"]["provider"].as_str(),
                Some("codex" | "opencode" | "claude")
            ),
        );
        Button::new("selection-follow-up-disclosure")
            .when(!compact, |button| button.label(behavior.label()))
            .when(compact, |button| button.w(px(28.)).p_0())
            .icon(behavior_icon(behavior))
            .dropdown_caret(!compact)
            .accessibility_label(format!("While the agent works: {}", behavior.label()))
            .tooltip("Choose what Send does while the agent works")
            .ghost()
            .compact()
            .h(px(28.))
            .rounded(px(8.))
            .on_click(cx.listener(|this, event: &gpui_kit::ClickEvent, _, cx| {
                this.follow_up_picker = !this.follow_up_picker;
                this.follow_up_anchor = Some(event.position());
                if this.follow_up_picker {
                    this.selection_ui.expanded = false;
                }
                cx.notify();
            }))
            .into_any_element()
    }
    /// Swift's follow-up menu: a small popover above the chip with Queue,
    /// Steer and Interrupt and what each does.
    pub(super) fn follow_up_menu(&self, cx: &mut Context<Self>) -> AnyElement {
        let Some(thread) = self.selected.as_ref() else {
            return div().into_any_element();
        };
        let chosen = choice::selected(thread, &self.settings);
        let mut menu = div().flex().flex_col().gap_1().p_2();
        for behavior in [Behavior::Queue, Behavior::Steer, Behavior::Interrupt] {
            let unsupported = behavior == Behavior::Steer
                && !matches!(
                    thread["selection"]["provider"].as_str(),
                    Some("codex" | "opencode" | "claude")
                );
            menu = menu.child(self.picker_menu_row(
                format!("follow-up-{}", behavior.key()),
                behavior.label().into(),
                Some(behavior_help(behavior).into()),
                Some(behavior_icon(behavior)),
                chosen == behavior,
                unsupported,
                move |this, _, cx| {
                    this.choose_follow_up(behavior, cx);
                    this.follow_up_picker = false;
                    cx.notify();
                },
                cx,
            ));
        }
        menu.into_any_element()
    }
    pub(super) fn follow_up_pane(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        if !self.follow_up_picker {
            return None;
        }
        let thread = self.selected.as_ref()?;
        let chosen = choice::selected(thread, &self.settings);
        let mut pane = div()
            .flex()
            .flex_col()
            .gap_1()
            .child("While the agent works");
        for behavior in [Behavior::Steer, Behavior::Queue, Behavior::Interrupt] {
            let unsupported = behavior == Behavior::Steer
                && !matches!(
                    thread["selection"]["provider"].as_str(),
                    Some("codex" | "opencode" | "claude")
                );
            pane = pane.child(
                Button::new(SharedString::from(format!("follow-up-{}", behavior.key())))
                    .label(behavior.label())
                    .icon(behavior_icon(behavior))
                    .selected(chosen == behavior)
                    .disabled(unsupported)
                    .tooltip(if unsupported {
                        "This provider does not support native steering yet"
                    } else {
                        behavior_help(behavior)
                    })
                    .on_click(
                        cx.listener(move |this, _, _, cx| this.choose_follow_up(behavior, cx)),
                    ),
            );
        }
        Some(pane.into_any_element())
    }
    pub(super) fn choose_follow_up(&mut self, behavior: Behavior, cx: &mut Context<Self>) {
        // Show the choice at once and write it when the engine is free: the
        // picker used to fail silently while a turn held the lock.
        let Some(thread) = self.selected.clone() else {
            return;
        };
        let id = text(&thread, "id");
        if let Some(thread) = self.selected.as_mut() {
            thread["followUpBehavior"] = json!(behavior.key());
        }
        self.follow_up_picker = false;
        if !self.flush_pending_drafts() || self.engine.try_lock().is_err() {
            self.pending_follow_up_choice = Some((id, behavior));
            cx.notify();
            return;
        }
        let result = (|| -> Result<(Value, Value)> {
            let mut engine = self.engine.try_lock().map_err(|_| EngineBusy)?;
            let current = engine.store.thread(&text(&thread, "id"))?;
            let saved = engine.choose_native_follow_up(&current, behavior)?;
            let settings = engine
                .store
                .document("settings.json")?
                .unwrap_or_else(|| json!({}));
            Ok((saved, settings))
        })();
        match result {
            Ok((thread, settings)) => {
                self.selected = Some(thread);
                self.settings = settings;
                self.follow_up_picker = false;
            }
            Err(error) => {
                if engine_busy(&error) {
                    self.pending_follow_up_choice = Some((id, behavior));
                } else {
                    self.show_local_error(&format!("Follow-up choice not saved: {error}"));
                    self.status = error.to_string();
                }
            }
        }
        cx.notify();
    }
    pub(super) fn send_follow_up(
        &mut self,
        alternate: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.voice.preview.is_some() {
            self.cancel_composer_dictation(cx);
        }

        self.record_composer_draft(cx);
        let Some(thread) = self.selected.clone() else {
            return;
        };
        let id = text(&thread, "id");
        if self.attachment_import_threads.contains(&id) {
            self.show_local_error("Wait for image imports to finish before sending a follow-up.");
            cx.notify();
            return;
        }
        let draft = self.composer.read(cx).value().to_string();
        // The Engine validates the saved draft and selection atomically. Keep
        // the visible draft until that exact payload has been saved and admitted.
        // In particular, never retry by replacing text the user typed meanwhile.
        self.save_pending_draft(&id);
        if self
            .pending_drafts
            .get(&id)
            .is_some_and(|draft| draft.failed)
        {
            self.pending_follow_up = None;
            self.show_local_error("The draft could not be saved. It remains in the composer; retry saving before sending.");
            cx.notify();
            return;
        }
        if self.pending_drafts.contains_key(&id)
            || self
                .pending_follow_up_choice
                .as_ref()
                .is_some_and(|(owner, _)| owner == &id)
        {
            self.pending_follow_up = Some(PendingSend::new(&thread, draft, alternate));
            cx.notify();
            return;
        }
        // The saved source is now owned by the follow-up operation. Revoke
        // its debounced write before the provider can acknowledge and clear it.
        self.draft_saver.invalidate();
        let result = self
            .engine
            .try_lock()
            .map_err(|_| anyhow::anyhow!(EngineBusy))
            .and_then(|mut engine| engine.send_native_follow_up(&thread, alternate));
        match result {
            Ok(ticket) => {
                self.pending_follow_up = None;
                let image_send = self.show_pending_send(&id, &draft);
                self.pending_drafts.remove(&id);
                if let Some(thread) = self.selected.as_mut()
                    && text(thread, "id") == id
                {
                    thread["draft"] = json!("");
                }
                self.composer
                    .update(cx, |input, cx| input.set_value("", window, cx));
                self.follow_up_deliveries.push(PendingDelivery {
                    ticket: Some(ticket),
                    thread: id,
                    draft,
                    queued: false,
                    image_send,
                });
            }
            Err(error)
                if engine_busy(&error)
                    || error.to_string().contains("Collect the previous follow-up") =>
            {
                self.pending_follow_up = Some(PendingSend::new(&thread, draft, alternate));
            }
            Err(error) => {
                self.pending_follow_up = None;
                let reason = error.to_string();
                self.show_local_error(&send_error_message(&reason));
                self.status = reason;
            }
        }
        cx.notify();
    }
    /// Put a follow-up back in the composer after the engine withheld it, but
    /// never over text the user has started typing since.
    fn restore_follow_up_draft(
        &mut self,
        id: &str,
        draft: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self
            .selected
            .as_ref()
            .is_some_and(|thread| text(thread, "id") == id)
            || !self.composer.read(cx).value().is_empty()
        {
            return false;
        }
        self.composer
            .update(cx, |input, cx| input.set_value(draft, window, cx));
        if let Some(thread) = self.selected.as_mut() {
            thread["draft"] = json!(draft);
        }
        true
    }
    pub(super) fn poll_composer_follow_ups(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let mut retained = Vec::new();
        for mut delivery in std::mem::take(&mut self.follow_up_deliveries) {
            let result = match self.engine.try_lock() {
                Err(_) => None,
                Ok(mut engine) => match engine
                    .native_follow_up_status(delivery.ticket.as_ref().expect("owned native ticket"))
                {
                    Ok(NativeFollowUpStatus::Pending) => Some(NativeFollowUpStatus::Pending),
                    Ok(status) => {
                        let ticket = delivery.ticket.take().expect("owned native ticket");
                        match engine.collect_native_follow_up(ticket) {
                            Ok(()) => Some(status),
                            Err(error) => Some(NativeFollowUpStatus::Retained(error.to_string())),
                        }
                    }
                    Err(error) => Some(NativeFollowUpStatus::Retained(error.to_string())),
                },
            };
            match result {
                None | Some(NativeFollowUpStatus::Pending) => retained.push(delivery),
                Some(status) => {
                    let delivered = matches!(status, NativeFollowUpStatus::Delivered { .. });
                    let draft_cleared = matches!(
                        status,
                        NativeFollowUpStatus::Delivered {
                            draft_cleared: true,
                            ..
                        }
                    );
                    self.record_composer_draft(cx);
                    self.finish_pending_images(delivery.image_send, delivered);
                    self.finish_submitted_draft(delivery.image_send, delivered && draft_cleared);
                    let restored = matches!(status, NativeFollowUpStatus::Retained(_))
                        && !delivery.queued
                        && self.restore_follow_up_draft(
                            &delivery.thread,
                            &delivery.draft,
                            window,
                            cx,
                        );
                    let queued = matches!(
                        status,
                        NativeFollowUpStatus::Delivered {
                            dispatch: Dispatch::Queue,
                            ..
                        }
                    ) && !delivery.queued;
                    // Queue entries have their own UI, and a restored draft is
                    // back in the composer. Remove only this optimistic row.
                    if (restored || queued)
                        && self
                            .pending_sent
                            .as_ref()
                            .is_some_and(|(thread, draft, ..)| {
                                thread == &delivery.thread && draft == &delivery.draft
                            })
                    {
                        self.drop_pending_send(&delivery.thread);
                    }
                    if let NativeFollowUpStatus::Retained(reason) = &status {
                        if reason.contains("delivery is unknown") {
                            self.show_local_error(&format!("Delivery status unknown: {reason}"));
                        } else {
                            self.show_local_error(&format!("Message not delivered: {reason}"));
                        }
                    }
                    self.status = match &status {
                        NativeFollowUpStatus::Retained(reason) => reason.clone(),
                        NativeFollowUpStatus::Delivered {
                            dispatch,
                            draft_cleared,
                        } => format!(
                            "{}{}",
                            dispatch_label(*dispatch),
                            if delivery.queued {
                                "; separate draft preserved"
                            } else if *draft_cleared {
                                ""
                            } else {
                                "; draft cleanup did not complete. Do not submit it again."
                            }
                        ),
                        NativeFollowUpStatus::Pending => unreachable!(),
                    };
                    self.refresh_queue(cx);
                    cx.notify();
                }
            }
        }
        self.follow_up_deliveries = retained;
    }
    pub(super) fn composer_send_dispatch(&self, alternate: bool) -> Dispatch {
        let Some(thread) = self.selected.as_ref() else {
            return Dispatch::Send;
        };
        let id = text(thread, "id");
        if let Some(dispatch) = self
            .engine
            .try_lock()
            .ok()
            .and_then(|engine| engine.native_follow_up_dispatch(thread, alternate).ok())
        {
            // Remember what the engine said so a busy frame cannot flip the
            // button between Send, Queue and Steer while it is being read.
            self.dispatch_cache
                .borrow_mut()
                .insert(id.clone(), dispatch);
            return dispatch;
        }
        if let Some(dispatch) = self.dispatch_cache.borrow().get(&id) {
            return *dispatch;
        }
        if self.running.contains(&id) {
            Dispatch::Queue
        } else {
            Dispatch::Send
        }
    }
}
pub(super) fn dispatch_icon(dispatch: Dispatch) -> gpui_kit::assets::IconName {
    use gpui_kit::assets::IconName;
    match dispatch {
        Dispatch::Send => IconName::ArrowUp,
        Dispatch::Steer => IconName::CornerUpRight,
        Dispatch::Queue => IconName::ListPlus,
        Dispatch::Interrupt => IconName::SkipForward,
    }
}
pub(super) fn dispatch_label(dispatch: Dispatch) -> &'static str {
    match dispatch {
        Dispatch::Send => "Send message",
        Dispatch::Steer => "Steer message",
        Dispatch::Queue => "Queue message",
        Dispatch::Interrupt => "Stop the turn and send message",
    }
}
fn behavior_icon(behavior: Behavior) -> gpui_kit::assets::IconName {
    dispatch_icon(match behavior {
        Behavior::Steer => Dispatch::Steer,
        Behavior::Queue => Dispatch::Queue,
        Behavior::Interrupt => Dispatch::Interrupt,
    })
}
fn behavior_help(behavior: Behavior) -> &'static str {
    match behavior {
        Behavior::Steer => {
            "Send text into the running turn; if it cannot receive now, send it next"
        }
        Behavior::Queue => "Wait for this turn to finish before sending",
        Behavior::Interrupt => {
            "Stop the current turn, wait for its worker to return and save, then send"
        }
    }
}

#[cfg(test)]
mod send_route_tests {
    use super::{PendingSend, SendRoute, send_route};
    use serde_json::json;

    #[test]
    fn running_turn_routes_to_follow_up_even_while_selection_is_refreshing() {
        assert_eq!(send_route(true, false, true), SendRoute::FollowUp);
        assert_eq!(send_route(true, false, false), SendRoute::FollowUp);
    }

    #[test]
    fn image_import_finishes_before_either_send_path() {
        assert_eq!(send_route(true, true, true), SendRoute::WaitForImages);
        assert_eq!(send_route(false, true, false), SendRoute::WaitForImages);
        assert_eq!(send_route(false, false, true), SendRoute::WaitForSelection);
        assert_eq!(send_route(false, false, false), SendRoute::Send);
    }

    #[test]
    fn deferred_send_never_follows_a_changed_draft_or_model() {
        let mut thread = json!({"id":"conversation", "selection":{"provider":"codex","modelID":"one"}, "accessMode":"approval", "interactionMode":"build"});
        let pending = PendingSend::new(&thread, "message".into(), false);
        assert!(pending.matches(&thread, "message"));
        assert!(!pending.matches(&thread, "new message"));
        thread["selection"]["modelID"] = json!("two");
        assert!(!pending.matches(&thread, "message"));
        thread["selection"]["modelID"] = json!("one");
        thread["draftContext"] = json!([{"id":"new reference"}]);
        assert!(!pending.matches(&thread, "message"));
        thread["draftContext"] = json!(null);
        let importing = PendingSend::during_import(&thread, "message".into(), false);
        thread["rustDraftImages"] = json!([{"id":"new image"}]);
        assert!(importing.matches(&thread, "message"));
        assert!(!pending.matches(&thread, "message"));
    }

    #[test]
    fn deferred_send_captures_original_text_model_and_imported_images() {
        let mut thread = json!({"id":"conversation", "selection":{"provider":"codex","modelID":"one"}, "rustDraftImages":[{"id":"before"}]});
        let mut pending = PendingSend::during_import(&thread, "original".into(), false);
        thread["draft"] = json!("next message");
        thread["rustDraftImages"] = json!([{"id":"before"},{"id":"imported"}]);
        pending.finish_import(&thread);
        thread["rustDraftImages"] = json!([{"id":"before"},{"id":"imported"},{"id":"next-import"}]);
        thread["selection"]["modelID"] = json!("two");
        assert!(!pending.matches(&thread, "next message"));
        assert_eq!(pending.captured["draft"], "original");
        assert_eq!(pending.captured["selection"]["modelID"], "one");
        assert_eq!(
            pending.captured["rustDraftImages"],
            json!([{"id":"before"},{"id":"imported"}])
        );
    }
}
