use super::*;

impl Coincide {
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
            Err(error) => self.status = error.to_string(),
        }
        cx.notify();
    }
    pub(super) fn send_next_queued_now(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(thread) = self.selected.clone() else {
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
        if self.media.close_requested || self.media.shutdown_requested {
            return;
        }
        let composing = self.composer.update(cx, |input, cx| {
            gpui_kit::EntityInputHandler::marked_text_range(input, window, cx).is_some()
        });
        if composing || !self.flush_pending_drafts() {
            self.status =
                "Finish composing and save the current draft before editing a queued message."
                    .into();
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
            Err(error) => self.status = error.to_string(),
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
            Err(error) => {
                self.status = format!("Queue could not be changed: {error}");
                cx.notify();
            }
        }
    }

    pub(super) fn queue_pane(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        if self.queued_messages.is_empty() && self.queue_error.is_empty() {
            return None;
        }
        let pending = self
            .queued_messages
            .iter()
            .filter(|m| m["state"] == "pending")
            .count();
        Some(
            div()
                .id("message-queue")
                .max_h(px(180.))
                .overflow_y_scroll()
                .flex()
                .flex_col()
                .gap_2()
                .mb_2()
                .p_2()
                .border_1()
                .border_color(self.color(0x29303d))
                .rounded_md()
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap_2()
                        .child(div().flex_1().child(format!(
                            "Queued messages · {pending} pending · {}",
                            if self.queue_enabled {
                                "active"
                            } else {
                                "paused"
                            }
                        )))
                        .child(
                            Button::new("queue-toggle")
                                .label(if self.queue_enabled {
                                    "Pause"
                                } else {
                                    "Resume"
                                })
                                .disabled(self.queued_messages.is_empty())
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
                        ),
                )
                .when(!self.queue_error.is_empty(), |pane| {
                    pane.child(div().text_sm().child(self.queue_error.clone()))
                })
                .children(self.queued_messages.iter().map(|message| {
                    let id = text(message, "id");
                    let state = text(message, "state");
                    let full_text = text(message, "text");
                    let image_count = message["rustImages"].as_array().map_or(0, Vec::len);
                    let context_count = message["context"].as_array().map_or(0, Vec::len);
                    let edit_message = message.clone();
                    let send_message = message.clone();
                    let source = self.selected.clone();
                    let editable = matches!(state.as_str(), "pending" | "failed" | "interrupted");
                    let mut preview: String = full_text.chars().take(400).collect();
                    if preview.len() < full_text.len() {
                        preview.push('…');
                    }
                    div()
                        .flex()
                        .gap_2()
                        .items_start()
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .child(div().text_sm().child(format!(
                                    "{state} · {}",
                                    text(&message["selection"], "provider")
                                )))
                                .child(div().truncate().child(preview))
                                .when(image_count + context_count > 0, |row| row.child(div().text_sm().child(format!("{image_count} images · {context_count} references"))))
                                .when_some(message["error"].as_str(), |row, error| {
                                    row.child(div().text_sm().child(error.to_owned()))
                                }),
                        )
                        .child(
                            Button::new(SharedString::from(format!("send-queued-now-{id}")))
                                .label("Send now")
                                .accessibility_label("Send this queued message now")
                                .tooltip("Send into the current turn when ready; otherwise stop it and send after its worker returns. Keep the separate draft.")
                                .disabled(state != "pending")
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if let Some(source) = &source { this.send_queued_now(source, &send_message, cx); }
                                })),
                        )
                        .child(
                            Button::new(SharedString::from(format!("edit-queued-{id}")))
                                .label("Edit")
                                .accessibility_label("Edit queued message")
                                .tooltip("Move this message back into the composer")
                                .disabled(!editable)
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.edit_queued_message(&edit_message, window, cx)
                                })),
                        )
                        .child(
                            Button::new(SharedString::from(format!("remove-queued-{id}")))
                                .label("Remove")
                                .disabled(state == "dispatching")
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.queue_action("agent.queue.remove", Some(id.clone()), cx)
                                })),
                        )
                }))
                .into_any_element(),
        )
    }
}
