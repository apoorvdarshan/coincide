use super::*;

#[derive(Clone, PartialEq)]
pub(super) enum PendingQueueAction {
    Send {
        expected: Value,
        message: Value,
    },
    Edit {
        thread: String,
        message: Value,
    },
    Change {
        thread: String,
        method: &'static str,
        message: Option<String>,
    },
}

impl PendingQueueAction {
    fn thread(&self) -> &str {
        match self {
            Self::Send { expected, .. } => expected["id"].as_str().unwrap_or(""),
            Self::Edit { thread, .. } | Self::Change { thread, .. } => thread,
        }
    }
}

fn retain_pending_action(
    queue: &mut std::collections::VecDeque<PendingQueueAction>,
    action: PendingQueueAction,
) {
    if !queue.contains(&action) && queue.len() < 32 {
        queue.push_back(action);
    }
}

fn take_ready_action(
    queue: &mut std::collections::VecDeque<PendingQueueAction>,
    selected: Option<&str>,
    busy: bool,
) -> Option<PendingQueueAction> {
    let action = queue.pop_front()?;
    if busy {
        queue.push_front(action);
        return None;
    }
    if selected != Some(action.thread()) {
        queue.push_back(action);
        return None;
    }
    Some(action)
}

/// The native queue operation verifies only these fields. Capturing the full
/// transcript in every queue-row callback made long chats expensive to render.
fn queue_expected_scope(thread: &Value) -> Value {
    let mut scope = serde_json::Map::new();
    for key in [
        "id",
        "rustMessageQueue",
        "selection",
        "projectID",
        "projectPath",
        "worktreePath",
        "botID",
        "rustBotContext",
        "accessMode",
        "interactionMode",
    ] {
        if let Some(value) = thread.get(key) {
            scope.insert(key.into(), value.clone());
        }
    }
    Value::Object(scope)
}

impl Coincide {
    fn defer_queue_action(&mut self, action: PendingQueueAction) {
        retain_pending_action(&mut self.pending_queue_actions, action);
        self.status = "Updating the queued message…".into();
    }

    pub(super) fn poll_queue_action(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.pending_queue_actions.is_empty() {
            return;
        }
        let selected = self
            .selected
            .as_ref()
            .and_then(|thread| thread["id"].as_str());
        let busy = self.engine.try_lock().is_err();
        let Some(action) = take_ready_action(&mut self.pending_queue_actions, selected, busy)
        else {
            return;
        };
        match action {
            PendingQueueAction::Send { expected, message } => {
                self.send_queued_now(&expected, &message, cx)
            }
            PendingQueueAction::Edit { message, .. } => {
                self.edit_queued_message(&message, window, cx)
            }
            PendingQueueAction::Change {
                method, message, ..
            } => self.queue_action(method, message, cx),
        }
    }

    fn send_queued_now(&mut self, expected: &Value, message: &Value, cx: &mut Context<Self>) {
        if self.media.close_requested || self.media.shutdown_requested {
            return;
        }
        // The source captured by this row is authoritative; refreshing selection
        // here would let an old click send into another conversation.
        if self
            .selected
            .as_ref()
            .is_none_or(|thread| thread["id"] != expected["id"])
        {
            return;
        }
        let result = try_state(&self.engine)
            .and_then(|mut engine| engine.native_send_queued_now(expected, message));
        match result {
            Ok(ticket) => {
                self.track_queued_delivery(ticket, text(expected, "id"));
                self.status = "Delivering queued message; separate draft retained.".into();
                self.refresh_queue(cx);
            }
            Err(error)
                if engine_busy(&error)
                    || error
                        .to_string()
                        .contains("another native delivery is pending") =>
            {
                self.defer_queue_action(PendingQueueAction::Send {
                    expected: expected.clone(),
                    message: message.clone(),
                })
            }
            Err(error) => {
                self.queue_error = format!("Could not send queued message: {error}");
            }
        }
        cx.notify();
    }
    pub(super) fn send_next_queued_now(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(thread) = self.selected.as_ref().map(queue_expected_scope) else {
            return false;
        };
        if !self.running.contains(&text(&thread, "id")) {
            return false;
        }
        let Some(message) = self
            .queued_messages
            .iter()
            .find(|message| message["state"] == "pending")
            .cloned()
        else {
            return false;
        };
        self.send_queued_now(&thread, &message, cx);
        true
    }

    fn edit_queued_message(
        &mut self,
        message: &Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.voice.preview.is_some() {
            self.cancel_composer_dictation(cx);
        }

        if self.media.close_requested || self.media.shutdown_requested {
            return;
        }
        if self.engine.try_lock().is_err() {
            if let Some(thread) = self.selected.as_ref().map(|value| text(value, "id")) {
                self.defer_queue_action(PendingQueueAction::Edit {
                    thread,
                    message: message.clone(),
                });
            }
            return;
        }
        let composing = self.composer.update(cx, |input, cx| {
            gpui_kit::EntityInputHandler::marked_text_range(input, window, cx).is_some()
        });
        if composing {
            self.status =
                "Finish composing and save the current draft before editing a queued message."
                    .into();
            cx.notify();
            return;
        }
        if !self.flush_pending_drafts() {
            if self
                .pending_drafts
                .values()
                .all(|draft| draft.retry && !draft.failed)
            {
                if let Some(thread) = self.selected.as_ref().map(|value| text(value, "id")) {
                    self.defer_queue_action(PendingQueueAction::Edit {
                        thread,
                        message: message.clone(),
                    });
                }
            } else {
                self.status = "Save the current draft before editing a queued message.".into();
            }
            cx.notify();
            return;
        }
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return;
        };
        let draft = self.composer.read(cx).value().to_string();
        let result = (|| -> Result<Value> {
            let mut engine = try_state(&self.engine)?;
            let current = engine.store.thread(&id)?;
            anyhow::ensure!(
                current["draft"].as_str().unwrap_or_default() == draft,
                "Saved draft changed; current draft and queue retained"
            );
            engine.edit_native_queued_message(&current, message)
        })();
        match result {
            Ok(thread) => {
                let draft = text(&thread, "draft");
                self.selected = Some(thread);
                self.composer_files.invalidate();
                self.composer
                    .update(cx, |input, cx| input.set_value(draft, window, cx));
                self.composer.read(cx).focus_handle(cx).focus(window, cx);
                self.status = "Queued message moved into the draft.".into();
                self.refresh_queue(cx);
            }
            Err(error)
                if engine_busy(&error)
                    || error.to_string().contains("Collect the pending follow-up") =>
            {
                self.defer_queue_action(PendingQueueAction::Edit {
                    thread: id,
                    message: message.clone(),
                })
            }
            Err(error) => {
                self.queue_error = format!("Could not edit queued message: {error}");
            }
        }
        cx.notify();
    }
    pub(super) fn edit_last_queued_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let key = &event.keystroke;
        if event.is_held
            || !window.is_window_active()
            || key.key != "up" && key.key != "arrowup"
            || !key.modifiers.alt
            || key.modifiers.platform
            || key.modifiers.control
            || key.modifiers.shift
            || self.settings_open
            || !self.chat_visible()
            || self.composer_files.opened
            || !self.composer.read(cx).focus_handle(cx).is_focused(window)
        {
            return false;
        }
        if self.composer.update(cx, |input, cx| {
            gpui_kit::EntityInputHandler::marked_text_range(input, window, cx).is_some()
        }) {
            return false;
        }
        let Some(message) = self
            .queued_messages
            .iter()
            .rev()
            .find(|message| {
                matches!(
                    message["state"].as_str(),
                    Some("pending" | "failed" | "interrupted")
                )
            })
            .cloned()
        else {
            return false;
        };
        self.edit_queued_message(&message, window, cx);
        window.prevent_default();
        cx.stop_propagation();
        true
    }
    pub(super) fn refresh_queue(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.selected.as_ref().map(|v| text(v, "id")) else {
            self.queued_messages.clear();
            self.queue_error.clear();
            return;
        };
        match call(&self.engine, "agent.queue.list", json!({"threadId":id})) {
            Ok(value) => {
                self.queued_messages = value["messages"].as_array().cloned().unwrap_or_default();
                self.queue_enabled = value["enabled"] == true;
                self.queue_error = value["error"].as_str().unwrap_or_default().to_owned();
                // Keep the raw queue source (including future row metadata) for
                // exact native Send now admission; list returns typed previews.
                if let Ok(current) = call(&self.engine, "threads.read", json!({"threadId":id}))
                    && let Some(selected) = self.selected.as_mut()
                    && selected["id"] == id
                {
                    selected["rustMessageQueue"] = current["rustMessageQueue"].clone();
                }
            }
            Err(error) if engine_busy(&error) => return,
            Err(error) => {
                // Never retain another thread's pending messages after selection.
                self.queued_messages.clear();
                self.queue_enabled = false;
                self.queue_error = format!("Unable to load queued messages: {error}");
            }
        }
        cx.notify();
    }

    fn queue_action(
        &mut self,
        method: &'static str,
        message: Option<String>,
        cx: &mut Context<Self>,
    ) {
        let Some(id) = self.selected.as_ref().map(|v| text(v, "id")) else {
            return;
        };
        match call(
            &self.engine,
            method,
            json!({"threadId":id,"messageId":message}),
        ) {
            Ok(_) => self.refresh_queue(cx),
            Err(error) if engine_busy(&error) => {
                self.defer_queue_action(PendingQueueAction::Change {
                    thread: id,
                    method,
                    message,
                });
            }
            Err(error) => {
                self.queue_error = format!("Queue could not be changed: {error}");
                cx.notify();
            }
        }
    }

    pub(super) fn queue_pane(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        use gpui_kit::assets::IconName;
        let messages = self
            .queued_messages
            .iter()
            .filter(|message| message["state"] != "completed")
            .collect::<Vec<_>>();
        if messages.is_empty() && self.queue_error.is_empty() {
            return None;
        }
        let running = self
            .selected
            .as_ref()
            .is_some_and(|thread| self.running.contains(&text(thread, "id")));
        let source = self.selected.as_ref().map(queue_expected_scope);
        let mut pane = div()
            .id("message-queue")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(2.))
            .px_3()
            .py_1()
            .rounded_md()
            .bg(self.color(0x181d28));
        if !self.queue_error.is_empty() {
            pane = pane.child(div().text_xs().child(self.queue_error.clone()));
        }
        for (index, message) in messages.iter().take(3).enumerate() {
            let id = text(message, "id");
            let state = text(message, "state");
            let body = text(message, "text");
            let preview = body.lines().next().unwrap_or("");
            let images = message["rustImages"].as_array().map_or(0, Vec::len);
            let context = message["context"].as_array().map_or(0, Vec::len);
            let preview = if !preview.is_empty() {
                preview.to_owned()
            } else if images != 0 {
                format!("{images} image{}", if images == 1 { "" } else { "s" })
            } else {
                format!("{context} reference{}", if context == 1 { "" } else { "s" })
            };
            let edit_message = (*message).clone();
            let send_message = (*message).clone();
            let expected = source.clone();
            let editable = matches!(state.as_str(), "pending" | "failed" | "interrupted");
            let can_send = state == "pending";
            pane = pane.child(
                div()
                    .id(("queued-message", index))
                    .h(px(26.))
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        Icon::new(IconName::Clock)
                            .size(px(12.))
                            .text_color(self.color(0x96a0b2)),
                    )
                    .child(div().flex_1().min_w_0().truncate().text_xs().child(preview))
                    .when(index == 0, |row| {
                        row.child(
                            Button::new("queue-toggle-compact")
                                .icon(if self.queue_enabled {
                                    IconName::Pause
                                } else {
                                    IconName::Play
                                })
                                .accessibility_label(if self.queue_enabled {
                                    "Pause queue"
                                } else {
                                    "Resume queue"
                                })
                                .tooltip(if self.queue_enabled {
                                    "Pause queue"
                                } else {
                                    "Resume queue"
                                })
                                .ghost()
                                .xsmall()
                                .compact()
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.queue_action(
                                        if this.queue_enabled {
                                            "agent.queue.pause"
                                        } else {
                                            "agent.queue.resume"
                                        },
                                        None,
                                        cx,
                                    )
                                })),
                        )
                    })
                    .when(running, |row| {
                        row.child(
                            Button::new(SharedString::from(format!("send-queued-now-{id}")))
                                .icon(IconName::CornerUpRight)
                                .accessibility_label("Send queued message now")
                                .tooltip("Send now")
                                .ghost()
                                .xsmall()
                                .compact()
                                .disabled(!can_send)
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if let Some(expected) = &expected {
                                        this.send_queued_now(expected, &send_message, cx);
                                    }
                                })),
                        )
                    })
                    .child(
                        Button::new(SharedString::from(format!("edit-queued-{id}")))
                            .icon(IconName::Pencil)
                            .accessibility_label("Edit queued message")
                            .tooltip("Edit queued message")
                            .ghost()
                            .xsmall()
                            .compact()
                            .disabled(!editable)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.edit_queued_message(&edit_message, window, cx)
                            })),
                    )
                    .child(
                        Button::new(SharedString::from(format!("remove-queued-{id}")))
                            .icon(IconName::Close)
                            .accessibility_label("Remove queued message")
                            .tooltip("Remove from queue")
                            .ghost()
                            .xsmall()
                            .compact()
                            .disabled(state == "dispatching")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.queue_action("agent.queue.remove", Some(id.clone()), cx)
                            })),
                    ),
            );
        }
        if messages.len() > 3 {
            pane = pane.child(
                div()
                    .text_xs()
                    .child(format!("{} more queued", messages.len() - 3)),
            );
        }
        Some(pane.into_any_element())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn queued_action_captures_exact_execution_fields_without_the_transcript() {
        let thread = json!({"id":"thread", "selection":{"provider":"codex"},
            "rustMessageQueue":[{"id":"message","future":true}],
            "accessMode":null, "projectPath":"/project", "items":[{"text":"x".repeat(9_000_000)}]});
        let scope = queue_expected_scope(&thread);
        assert_eq!(scope["rustMessageQueue"], thread["rustMessageQueue"]);
        assert_eq!(scope["selection"], thread["selection"]);
        assert_eq!(scope.get("accessMode"), Some(&Value::Null));
        assert!(scope.get("interactionMode").is_none());
        assert!(scope.get("items").is_none());
        assert!(scope.to_string().len() < 1000);
    }
    #[::core::prelude::v1::test]
    fn queue_actions_retry_when_busy_without_retargeting_or_double_clicks() {
        let action = PendingQueueAction::Change {
            thread: "one".into(),
            method: "agent.queue.remove",
            message: Some("message".into()),
        };
        let mut pending = std::collections::VecDeque::new();
        retain_pending_action(&mut pending, action.clone());
        retain_pending_action(&mut pending, action.clone());
        assert_eq!(pending.len(), 1);
        assert!(take_ready_action(&mut pending, Some("one"), true).is_none());
        assert!(take_ready_action(&mut pending, Some("other"), false).is_none());
        assert!(take_ready_action(&mut pending, Some("one"), false) == Some(action));
        assert!(pending.is_empty());
    }
}
