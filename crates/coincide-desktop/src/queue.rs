use super::*;

#[derive(Clone, PartialEq)]
pub(super) enum PendingQueueAction {
    Send {
        expected: Value,
        message: Value,
    },
    Interrupt {
        expected: Value,
        message: Value,
    },
    StopDelivery {
        thread: String,
        message: String,
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
            Self::Send { expected, .. } | Self::Interrupt { expected, .. } => {
                expected["id"].as_str().unwrap_or("")
            }
            Self::Edit { thread, .. }
            | Self::Change { thread, .. }
            | Self::StopDelivery { thread, .. } => thread,
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

fn edit_last_queued_key_routes(
    event: &KeyDownEvent,
    window_active: bool,
    route: chat_inspector::ChatRoute,
    picker_open: bool,
    composer_focused: bool,
) -> bool {
    let key = &event.keystroke;
    !event.is_held
        && window_active
        && matches!(key.key.as_str(), "up" | "arrowup")
        && key.modifiers.alt
        && !key.modifiers.platform
        && !key.modifiers.control
        && !key.modifiers.shift
        && route.visible()
        && !picker_open
        && composer_focused
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

fn hold_queue_completion_for_transcript(messages: &mut [Value], previous: &[Value]) {
    for row in messages {
        if row["state"] == "completed"
            && previous
                .iter()
                .any(|item| item["id"] == row["id"] && item["state"] != "completed")
        {
            row["state"] = json!("dispatching");
            row["deliveryCommitted"] = json!(true);
        }
    }
}

fn pending_row(pending: &composer_follow_up_mount::PendingSend, id: &str, state: &str) -> Value {
    json!({"id":id, "state":state, "text":pending.draft, "error":pending.last_error,
        "rustImages":pending.captured["rustDraftImages"], "context":pending.captured["draftContext"]})
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
            PendingQueueAction::Interrupt { expected, message } => {
                self.send_queued(&expected, &message, true, cx)
            }
            PendingQueueAction::StopDelivery { thread, message } => {
                self.stop_queue_delivery(thread, message, cx)
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
        self.send_queued(expected, message, false, cx);
    }
    fn send_queued(
        &mut self,
        expected: &Value,
        message: &Value,
        interrupt: bool,
        cx: &mut Context<Self>,
    ) {
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
        let result = try_state(&self.engine).and_then(|mut engine| {
            if interrupt {
                engine.native_interrupt_and_send_queued(expected, message)
            } else {
                engine.native_send_queued_now(expected, message)
            }
        });
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
                let expected = expected.clone();
                let message = message.clone();
                self.defer_queue_action(if interrupt {
                    PendingQueueAction::Interrupt { expected, message }
                } else {
                    PendingQueueAction::Send { expected, message }
                });
            }
            Err(error) => {
                self.queue_error = format!("Could not send queued message: {error}");
            }
        }
        cx.notify();
    }
    fn stop_queue_delivery(&mut self, thread: String, message: String, cx: &mut Context<Self>) {
        match try_state(&self.engine)
            .and_then(|mut engine| engine.native_stop_unaccepted_queued_turn(&thread, &message))
        {
            Ok(()) => self.refresh_queue(cx),
            Err(error) if engine_busy(&error) => {
                self.defer_queue_action(PendingQueueAction::StopDelivery { thread, message })
            }
            Err(error) => self.queue_error = error.to_string(),
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
                self.replace_selected_thread(Some(thread));
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
        if !edit_last_queued_key_routes(
            event,
            window.is_window_active(),
            self.chat_route(),
            self.composer_files.opened,
            self.composer.read(cx).focus_handle(cx).is_focused(window),
        ) {
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
        let result = match try_state(&self.engine) {
            Ok(engine) => engine
                .native_queue_read(&id)
                .map_err(|error| error.to_string()),
            Err(_) => return,
        };
        self.accept_queue_read(&id, result, false, cx);
    }
    pub(super) fn accept_queue_read(
        &mut self,
        id: &str,
        result: Result<Value, String>,
        transcript_updated: bool,
        cx: &mut Context<Self>,
    ) {
        if self
            .selected
            .as_ref()
            .is_none_or(|thread| thread["id"] != id)
        {
            return;
        }
        match result {
            Ok(value) => {
                let mut messages = value["messages"].as_array().cloned().unwrap_or_default();
                // A small queue read can finish before the matching transcript
                // refresh. Keep the row until both views can advance together.
                if !transcript_updated {
                    hold_queue_completion_for_transcript(&mut messages, &self.queued_messages);
                }
                let enabled = value["enabled"] == true;
                let error = value["error"].as_str().unwrap_or_default().to_owned();
                if self.queued_messages != messages
                    || self.queue_enabled != enabled
                    || self.queue_error != error
                {
                    self.selected_generation = self.selected_generation.wrapping_add(1);
                }
                self.queued_messages = messages;
                self.queue_enabled = enabled;
                self.queue_error = error;
                // Keep the raw queue source (including future row metadata) for
                // exact native Send now admission; list returns typed previews.
                if let Some(raw_queue) = value.get("rawQueue")
                    && self.selected.as_ref().is_some_and(|selected| {
                        selected["id"] == id && selected.get("rustMessageQueue") != Some(raw_queue)
                    })
                    && let Some(selected) = self.selected.as_mut()
                {
                    selected["rustMessageQueue"] = raw_queue.clone();
                }
            }
            Err(error) => {
                // Selection clears another thread's rows. Keep this thread's
                // last valid queue across snapshot or persistence recovery.
                self.queue_error = format!("Unable to load queued messages: {error}");
            }
        }
        self.reconcile_buffered_sends();
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

    fn recall_buffered_queue(
        &mut self,
        id: &str,
        edit: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.chat_visible() || self.media.close_requested || self.media.shutdown_requested {
            return;
        }
        let Some(thread) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return;
        };
        let matches = |entry: &composer_follow_up_mount::PendingSend| {
            entry.thread == thread && entry.buffer_id.as_deref() == Some(id)
        };
        if edit && !self.composer.read(cx).value().is_empty() {
            self.queue_error = "Finish the current draft before editing this message.".into();
            cx.notify();
            return;
        }
        let pending = if let Some(entry) = self
            .pending_follow_up
            .as_ref()
            .filter(|entry| matches(entry))
        {
            if !entry.recall() {
                return;
            }
            self.pending_follow_up.take()
        } else if let Some(index) = self.pending_follow_up_backlog.iter().position(matches) {
            if !self.pending_follow_up_backlog[index].recall() {
                return;
            }
            self.pending_follow_up_backlog.remove(index)
        } else {
            None
        };
        let Some(pending) = pending else { return };
        self.attachment_imports.release_claims(&pending.import_jobs);
        self.finish_pending_images(pending.image_send, false);
        self.queue_error.clear();
        if edit {
            self.composer
                .update(cx, |input, cx| input.set_value(pending.draft, window, cx));
            self.composer.read(cx).focus_handle(cx).focus(window, cx);
        }
        cx.notify();
    }

    pub(super) fn queue_pane(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        use gpui_kit::assets::IconName;
        let current = self.selected.as_ref()?;
        let thread = text(current, "id");
        let source = queue_expected_scope(current);
        let running = self.running.contains(&thread);
        let mut messages = self
            .queued_messages
            .iter()
            .filter(|row| row["state"] != "completed")
            .cloned()
            .map(|row| (row, false, Vec::new()))
            .collect::<Vec<_>>();
        let stoppable = if messages
            .iter()
            .any(|(row, _, _)| row["state"] == "dispatching")
        {
            current["items"]
                .as_array()
                .and_then(|items| {
                    items.iter().rev().find_map(|item| {
                        (item["rustAwaitingQueueDelivery"] == true)
                            .then(|| item["rustQueueMessageID"].as_str())
                            .flatten()
                    })
                })
                .map(str::to_owned)
        } else {
            None
        };
        let show_queue_toggle = !messages.is_empty();
        for preview in self
            .admitted_previews
            .iter()
            .filter(|preview| preview.pending.thread == thread)
        {
            if !messages
                .iter()
                .any(|(row, _, _)| row["id"] == preview.queue_id)
            {
                messages.push((
                    pending_row(&preview.pending, &preview.queue_id, "dispatching"),
                    true,
                    Vec::new(),
                ));
            }
        }
        for pending in self
            .pending_follow_up
            .iter()
            .chain(&self.pending_follow_up_backlog)
        {
            if let Some(id) = pending.buffer_id.as_deref().filter(|id| {
                pending.thread == thread && !messages.iter().any(|(row, _, _)| row["id"] == *id)
            }) {
                let state = if pending.can_recall() {
                    "pending"
                } else {
                    "dispatching"
                };
                messages.push((
                    pending_row(pending, id, state),
                    true,
                    pending.import_jobs.clone(),
                ));
            }
        }
        if messages.is_empty() && self.queue_error.is_empty() {
            return None;
        }
        let mut pane = div()
            .id("message-queue")
            .w_full()
            .max_h(px(190.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_1()
            .px_2()
            .py_1()
            .rounded_md()
            .bg(self.color(0x181d28));
        if !self.queue_error.is_empty() {
            pane = pane.child(
                div()
                    .px_2()
                    .py_1()
                    .text_xs()
                    .child(self.queue_error.clone()),
            );
        }
        for (index, (message, local, importing)) in messages.into_iter().enumerate() {
            let id = text(&message, "id");
            let state = text(&message, "state");
            let in_flight = state == "dispatching";
            let can_stop =
                !local && message["deliveryCommitted"] != true && stoppable.as_deref() == Some(&id);
            let editable = matches!(state.as_str(), "pending" | "failed" | "interrupted")
                && message["codexQuestionSession"].is_null();
            let sendable = !local && state == "pending" && running;
            let body = text(&message, "text");
            let body = coincide_core::async_questions::display_reply(&body).unwrap_or(body);
            let images = message["rustImages"]
                .as_array()
                .map(Vec::as_slice)
                .unwrap_or_default();
            let files = message["context"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|row| row["kind"] == "file" || row["kind"] == "folder")
                .filter_map(|row| row["displayName"].as_str().or_else(|| row["name"].as_str()))
                .take(3)
                .map(str::to_owned)
                .collect::<Vec<_>>();
            let count =
                images.len() + message["context"].as_array().map_or(0, Vec::len) + importing.len();
            let mut thumbs = images
                .iter()
                .take(3)
                .map(|image| self.image_preview(image, None, 30., 26., window, cx))
                .collect::<Vec<_>>();
            for preview in self
                .attachment_imports
                .claimed_previews(&importing)
                .into_iter()
                .take(3 - thumbs.len())
            {
                use composer_attachments::ImportPreview;
                thumbs.push(match preview {
                    ImportPreview::Clipboard(image) => img(image)
                        .w(px(30.))
                        .h(px(26.))
                        .rounded_md()
                        .object_fit(ObjectFit::Cover)
                        .into_any_element(),
                    ImportPreview::Path(path) => div()
                        .id(("queued-import-file", thumbs.len()))
                        .w(px(30.))
                        .h(px(26.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(Icon::new(IconName::FileText).small())
                        .tooltip(move |window, cx| {
                            gpui_kit::component::tooltip::Tooltip::new(
                                path.file_name().map_or_else(
                                    || "Attachment".into(),
                                    |name| name.to_string_lossy().into_owned(),
                                ),
                            )
                            .build(window, cx)
                        })
                        .into_any_element(),
                });
            }
            let row_error = message["error"]
                .as_str()
                .filter(|error| !error.is_empty())
                .map(str::to_owned);
            let caption = if count == 1 {
                "1 attachment".into()
            } else {
                format!("{count} attachments")
            };
            let action_source = source.clone();
            let steer_message = message.clone();
            let interrupt_source = source.clone();
            let interrupt_message = message.clone();
            let edit_message = message.clone();
            let edit_id = id.clone();
            let remove_id = id.clone();
            let stop_thread = thread.clone();
            pane = pane.child(
                div()
                    .id(("queued-message", index))
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_2()
                    .py_1()
                    .child(
                        Icon::new(IconName::Clock)
                            .size(px(13.))
                            .text_color(self.color(0x96a0b2)),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_1()
                            .min_w_0()
                            .flex_col()
                            .gap_1()
                            .when(!body.is_empty(), |label| {
                                label.child(div().truncate().text_sm().child(body))
                            })
                            .when(count > 0, |label| {
                                label.child(
                                    div()
                                        .flex()
                                        .items_center()
                                        .gap_1p5()
                                        .min_w_0()
                                        .children(thumbs)
                                        .child(
                                            div()
                                                .min_w_0()
                                                .truncate()
                                                .text_xs()
                                                .text_color(self.color(0x98a6ba))
                                                .child(if files.is_empty() {
                                                    caption
                                                } else {
                                                    format!("{caption} · {}", files.join(", "))
                                                }),
                                        ),
                                )
                            })
                            .when_some(row_error, |label, error| {
                                label.child(
                                    div()
                                        .text_xs()
                                        .truncate()
                                        .text_color(self.color(0xe4e9f2).opacity(0.7))
                                        .child(error),
                                )
                            }),
                    )
                    .when(index == 0 && show_queue_toggle, |row| {
                        let enabled = self.queue_enabled;
                        row.child(
                            Button::new("queue-toggle-compact")
                                .icon(if enabled {
                                    IconName::Pause
                                } else {
                                    IconName::Play
                                })
                                .tooltip(if enabled {
                                    "Pause queue"
                                } else {
                                    "Resume queue"
                                })
                                .accessibility_label(if enabled {
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
                                    );
                                })),
                        )
                    })
                    .when(sendable, |row| {
                        row.child(
                            Button::new(SharedString::from(format!("send-queued-now-{id}")))
                                .icon(IconName::CornerUpRight)
                                .tooltip("Send now")
                                .accessibility_label("Send queued message now")
                                .ghost()
                                .xsmall()
                                .compact()
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.send_queued_now(&action_source, &steer_message, cx)
                                })),
                        )
                        .when(
                            message["codexQuestionSession"].is_null(),
                            |row| {
                                row.child(
                                    Button::new(SharedString::from(format!(
                                        "interrupt-for-queued-{id}"
                                    )))
                                    .icon(IconName::SkipForward)
                                    .tooltip("Stop current turn and send")
                                    .accessibility_label("Stop current turn and send this message")
                                    .ghost()
                                    .xsmall()
                                    .compact()
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.send_queued(
                                            &interrupt_source,
                                            &interrupt_message,
                                            true,
                                            cx,
                                        )
                                    })),
                                )
                            },
                        )
                    })
                    .child(
                        Button::new(SharedString::from(format!("edit-queued-{id}")))
                            .icon(IconName::Pencil)
                            .tooltip("Edit queued message")
                            .accessibility_label("Edit queued message")
                            .ghost()
                            .xsmall()
                            .compact()
                            .disabled(!editable)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                if local {
                                    this.recall_buffered_queue(&edit_id, true, window, cx);
                                } else {
                                    this.edit_queued_message(&edit_message, window, cx);
                                }
                            })),
                    )
                    .child(
                        Button::new(SharedString::from(format!("remove-queued-{id}")))
                            .icon(IconName::Close)
                            .tooltip(if in_flight {
                                "Stop delivery"
                            } else {
                                "Cancel queued message"
                            })
                            .accessibility_label(if in_flight {
                                "Stop delivery"
                            } else {
                                "Cancel queued message"
                            })
                            .ghost()
                            .xsmall()
                            .compact()
                            .disabled(in_flight && !can_stop)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                if local {
                                    this.recall_buffered_queue(&remove_id, false, window, cx);
                                } else if in_flight {
                                    this.stop_queue_delivery(
                                        stop_thread.clone(),
                                        remove_id.clone(),
                                        cx,
                                    );
                                } else {
                                    this.queue_action(
                                        "agent.queue.remove",
                                        Some(remove_id.clone()),
                                        cx,
                                    );
                                }
                            })),
                    ),
            );
        }
        Some(pane.into_any_element())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn early_queue_completion_keeps_the_visible_row_until_transcript_refresh() {
        let previous = vec![json!({"id":"send","state":"dispatching"})];
        let mut incoming = vec![
            json!({"id":"send","state":"completed"}),
            json!({"id":"older","state":"completed"}),
        ];
        hold_queue_completion_for_transcript(&mut incoming, &previous);
        assert_eq!(incoming[0]["state"], "dispatching");
        assert_eq!(incoming[0]["deliveryCommitted"], true);
        assert_eq!(incoming[1]["state"], "completed");
    }

    #[::core::prelude::v1::test]
    fn option_up_edits_queue_only_in_a_visible_focused_composer() {
        let mut event = KeyDownEvent {
            keystroke: gpui_kit::Keystroke {
                key: "up".into(),
                modifiers: gpui_kit::Modifiers {
                    alt: true,
                    ..Default::default()
                },
                ..Default::default()
            },
            is_held: false,
            prefer_character_input: false,
        };
        let route = chat_inspector::ChatRoute {
            selected: true,
            settings: settings_window::settings_rendered_inline(true, true, false),
            ..Default::default()
        };
        assert!(edit_last_queued_key_routes(
            &event, true, route, false, true
        ));
        assert!(!edit_last_queued_key_routes(
            &event, false, route, false, true
        ));
        assert!(!edit_last_queued_key_routes(
            &event, true, route, true, true
        ));
        assert!(!edit_last_queued_key_routes(
            &event, true, route, false, false
        ));
        assert!(!edit_last_queued_key_routes(
            &event,
            true,
            chat_inspector::ChatRoute {
                settings: true,
                ..route
            },
            false,
            true,
        ));
        assert!(!edit_last_queued_key_routes(
            &event,
            true,
            chat_inspector::ChatRoute {
                navigating: true,
                ..route
            },
            false,
            true,
        ));
        event.keystroke.modifiers.shift = true;
        assert!(!edit_last_queued_key_routes(
            &event, true, route, false, true
        ));
        event.keystroke.modifiers.shift = false;
        event.is_held = true;
        assert!(!edit_last_queued_key_routes(
            &event, true, route, false, true
        ));
    }

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
