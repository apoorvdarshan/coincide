//! Native composer choices and owner-bound delivery tickets. Nothing here is a
//! command/RPC route; only the visible editor's actions create a delivery.
use super::*;
use coincide_core::{
    api::{NativeFollowUpStatus, NativeFollowUpTicket},
    composer_follow_up::{self as choice, Behavior, Dispatch},
};
pub(super) struct PendingDelivery {
    ticket: Option<NativeFollowUpTicket>,
    thread: String,
    draft: String,
    queued: bool,
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
                Some("codex" | "opencode")
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
                    Some("codex" | "opencode")
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
                    Some("codex" | "opencode")
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
    fn choose_follow_up(&mut self, behavior: Behavior, cx: &mut Context<Self>) {
        if !self.flush_pending_drafts() {
            self.status = "Save the current draft before changing follow-up behavior.".into();
            cx.notify();
            return;
        }
        let Some(thread) = self.selected.clone() else {
            return;
        };
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
            Err(error) => self.status = error.to_string(),
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

        // The text is in hand, so a draft that is still saving must not hold the
        // message back; it saves in the background either way.
        self.flush_pending_drafts();
        let Some(thread) = self.selected.clone() else {
            return;
        };
        let id = text(&thread, "id");
        if self.attachment_import_threads.contains(&id) {
            self.status = "Wait for image imports to finish before sending a follow-up.".into();
            cx.notify();
            return;
        }
        let draft = self.composer.read(cx).value().to_string();
        // The message shows in the conversation the moment it is sent; keeping
        // it in the field until delivery is confirmed looked like a failed send.
        // A withheld follow-up puts it back below.
        self.pending_drafts.remove(&id);
        self.composer
            .update(cx, |input, cx| input.set_value("", window, cx));
        if let Some(thread) = self.selected.as_mut()
            && text(thread, "id") == id
        {
            thread["draft"] = json!("");
        }
        let result = self
            .engine
            .try_lock()
            .map_err(|_| anyhow::anyhow!(EngineBusy))
            .and_then(|mut engine| engine.send_native_follow_up(&thread, alternate));
        match result {
            Ok(ticket) => {
                self.follow_up_deliveries.push(PendingDelivery {
                    ticket: Some(ticket),
                    thread: id,
                    draft,
                    queued: false,
                });
            }
            Err(error) if engine_busy(&error) => {
                // The engine is busy for a moment; keep the message and take it
                // as soon as the lock is free instead of refusing it.
                self.pending_follow_up = Some((id, draft, alternate));
            }
            Err(error) => {
                self.restore_follow_up_draft(&id, &draft, window, cx);
                self.status = error.to_string();
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
    ) {
        if !self
            .selected
            .as_ref()
            .is_some_and(|thread| text(thread, "id") == id)
            || !self.composer.read(cx).value().is_empty()
        {
            return;
        }
        self.composer
            .update(cx, |input, cx| input.set_value(draft, window, cx));
        if let Some(thread) = self.selected.as_mut() {
            thread["draft"] = json!(draft);
        }
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
                    if let NativeFollowUpStatus::Retained(_) = &status {
                        self.restore_follow_up_draft(&delivery.thread, &delivery.draft, window, cx);
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
                    if delivered
                        && !delivery.queued
                        && self
                            .selected
                            .as_ref()
                            .is_some_and(|thread| thread["id"] == delivery.thread)
                        && self.committed_composer_draft(cx) == delivery.draft
                        && let Ok(thread) = call(
                            &self.engine,
                            "threads.read",
                            json!({"threadId":delivery.thread}),
                        )
                        && thread["draft"] == ""
                    {
                        self.pending_drafts.remove(&delivery.thread);
                        self.selected = Some(thread);
                        self.composer
                            .update(cx, |input, cx| input.set_value("", window, cx));
                    }
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
