use super::*;

impl Coincide {
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

    pub(super) fn queue_message(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(thread) = self.selected.as_ref() else {
            return;
        };
        let id = text(thread, "id");
        if self.attachment_import_threads.contains(&id) {
            self.status = "Wait for image imports to finish before queueing.".into();
            cx.notify();
            return;
        }
        // Core also checks persisted attachments, including imports completed
        // since the last native refresh. A rejected enqueue keeps the draft.
        if thread["rustDraftImages"]
            .as_array()
            .is_some_and(|images| !images.is_empty())
        {
            self.status =
                "Queued messages currently support text only. Keep these images for a direct send."
                    .into();
            cx.notify();
            return;
        }
        let message = self.composer.read(cx).value().to_string();
        match call(
            &self.engine,
            "agent.queue.add",
            json!({"threadId":id,"text":message}),
        ) {
            Ok(result) => {
                match call(
                    &self.engine,
                    "threads.patch",
                    json!({"threadId":id,"patch":{"draft":""}}),
                ) {
                    Ok(thread) => {
                        self.pending_drafts.remove(&id);
                        self.selected = Some(thread);
                        self.composer
                            .update(cx, |input, cx| input.set_value("", window, cx));
                        self.status = if result["enabled"] == true {
                            "Message queued. It will run after the current turn finishes successfully.".into()
                        } else {
                            "Message queued. Resume the queue when ready.".into()
                        };
                    }
                    Err(error) => {
                        self.status = format!(
                            "Message queued, but draft cleanup failed: {error}. Do not queue it again."
                        )
                    }
                }
                self.refresh_queue(cx);
            }
            Err(error) => {
                self.status = format!("Message could not be queued: {error}");
                cx.notify();
            }
        }
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
                    let mut preview: String = full_text.chars().take(400).collect();
                    if preview.len() < full_text.len() {
                        preview.push_str("…");
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
                                .when_some(message["error"].as_str(), |row, error| {
                                    row.child(div().text_sm().child(error.to_owned()))
                                }),
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
