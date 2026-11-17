use super::*;
use coincide_core::composer_context::{self, Edit, ExpectedContext};
impl Coincide {
    fn clear_context(&mut self, source: &str, cx: &mut Context<Self>) {
        if self.media.shutdown_requested {
            return;
        }
        self.composer_files.invalidate();
        let Some(thread) = self
            .selected
            .as_ref()
            .filter(|thread| thread["id"] == source)
        else {
            return;
        };
        let expected = ExpectedContext::from_thread(thread);
        let original = thread["draftContext"].clone();
        let Some(job) = self.attachment_imports.reserve_removal(source) else {
            self.show_local_error(
                "Too many attachment changes are in progress. Try again shortly.",
            );
            cx.notify();
            return;
        };
        let source = source.to_owned();
        if let Some(thread) = self
            .selected
            .as_mut()
            .filter(|thread| thread["id"] == source)
        {
            thread["draftContext"] = json!([]);
        }
        self.selected_generation = self.selected_generation.wrapping_add(1);
        let engine = self.engine.clone();
        let owner = source.clone();
        cx.spawn(async move |this, cx| {
            let result = cx.background_executor().spawn(async move {
                engine.lock().map_err(|_| anyhow::anyhow!("Application state is unavailable"))?
                    .edit_composer_context(&json!({"threadId":owner,"expectedContext":expected,"edit":Edit::Clear}))
                    .map(|_| ())
            }).await;
            let _ = this.update(cx, |this, cx| {
                if result.is_err()
                    && let Some(thread) = this.selected.as_mut().filter(|thread| thread["id"] == source)
                    && thread["draftContext"] == json!([])
                {
                    thread["draftContext"] = original;
                    this.selected_generation = this.selected_generation.wrapping_add(1);
                }
                this.finish_image_import(job, &source, Vec::new(), result.err(), cx);
            });
        }).detach();
        cx.notify();
    }
    fn remove_context_reference(&mut self, source: String, card: Value, cx: &mut Context<Self>) {
        if self.media.shutdown_requested {
            return;
        }
        self.composer_files.invalidate();
        let Some(job) = self.attachment_imports.reserve_removal(&source) else {
            self.show_local_error(
                "Too many attachment changes are in progress. Try again shortly.",
            );
            cx.notify();
            return;
        };
        let position = self
            .selected
            .as_mut()
            .filter(|thread| thread["id"] == source)
            .and_then(|thread| thread["draftContext"].as_array_mut())
            .and_then(|rows| {
                let index = rows.iter().position(|row| *row == card)?;
                rows.remove(index);
                Some(index)
            });
        let Some(position) = position else {
            self.finish_image_import(job, &source, Vec::new(), None, cx);
            return;
        };
        let expected_after = self
            .selected
            .as_ref()
            .map(|thread| thread["draftContext"].clone());
        self.selected_generation = self.selected_generation.wrapping_add(1);
        let engine = self.engine.clone();
        let owner = source.clone();
        let expected = card.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    engine
                        .lock()
                        .map_err(|_| anyhow::anyhow!("Application state is unavailable"))?
                        .remove_draft_context_card(&owner, &expected)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if result.is_err() {
                    if let Some(thread) = this
                        .selected
                        .as_mut()
                        .filter(|thread| thread["id"] == source)
                        && expected_after.as_ref() == Some(&thread["draftContext"])
                        && let Some(rows) = thread["draftContext"].as_array_mut()
                        && !rows.iter().any(|row| row["id"] == card["id"])
                    {
                        rows.insert(position.min(rows.len()), card);
                        this.selected_generation = this.selected_generation.wrapping_add(1);
                    }
                }
                this.finish_image_import(job, &source, Vec::new(), result.err(), cx);
            });
        })
        .detach();
        cx.notify();
    }
    fn file_reference_preview(
        &mut self,
        card: &Value,
        row: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if let Some(image) = card.get("previewImage").filter(|image| image.is_object()) {
            return self.image_preview(image, row, 48., 60., window, cx);
        }
        let mut tile = div()
            .w(px(48.))
            .h(px(60.))
            .flex_shrink_0()
            .rounded(px(6.))
            .bg(cx.theme().background)
            .border_1()
            .border_color(cx.theme().border)
            .overflow_hidden();
        if let Some(preview) = card["previewText"].as_str().filter(|text| !text.is_empty()) {
            tile = tile.child(
                div()
                    .p_1()
                    .text_size(px(8.))
                    .text_color(cx.theme().muted_foreground)
                    .line_clamp(4)
                    .child(preview.to_owned()),
            );
        } else {
            tile = tile.flex().items_center().justify_center().child(
                Icon::new(if card["isDirectory"] == true {
                    gpui_kit::assets::IconName::Folder
                } else {
                    gpui_kit::assets::IconName::FileText
                })
                .size(px(22.)),
            );
        }
        tile.into_any_element()
    }

    pub(super) fn composer_context_pane(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let thread = self.selected.as_ref()?;
        let raw = thread.get("draftContext").cloned().unwrap_or(Value::Null);
        if !composer_context::has_context(&raw) {
            return None;
        }
        let source = text(thread, "id");
        let mut pane = div()
            .id("composer-context-cards")
            .max_h(px(170.))
            .overflow_y_scroll()
            .flex()
            .flex_wrap()
            .items_start()
            .gap_2();
        if let Err(error) = composer_context::validate(&raw) {
            pane = pane.child(format!("Attached references retained: {error}"));
        }
        for (index, card) in composer_context_view::cards(&raw).into_iter().enumerate() {
            let row_value = raw.as_array().and_then(|rows| rows.get(index)).cloned();
            let thumbnail = if card.is_file {
                row_value
                    .as_ref()
                    .map(|value| self.file_reference_preview(value, None, window, cx))
            } else {
                None
            };
            let icon = if card.is_directory {
                gpui_kit::assets::IconName::Folder
            } else {
                gpui_kit::assets::IconName::FileText
            };
            let mut title = div().child(card.title.clone()).into_any_element();
            if let Some(id) = card.id.clone() {
                let source = source.clone();
                let expected = raw.clone();
                title = Button::new(("open-composer-context", index))
                    .child(div().w_full().truncate().child(card.title.clone()))
                    .when(!card.is_file, |button| button.icon(icon))
                    .w_full()
                    .accessibility_label(format!("Open {}", card.title))
                    .ghost()
                    .xsmall()
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.open_context_details(
                            source.clone(),
                            context_details::Source::Draft,
                            id.clone(),
                            expected.clone(),
                            window,
                            cx,
                        )
                    }))
                    .into_any_element();
            }
            let content = div().flex_1().min_w_0().child(title).child(
                div()
                    .px_1()
                    .line_clamp(2)
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .child(card.preview),
            );
            let mut row = div()
                .flex()
                .gap_2()
                .items_center()
                .min_w_0()
                .when(card.is_file, |row| row.w(px(250.)).max_w_full())
                .when(!card.is_file, |row| row.w_full())
                .rounded(px(8.))
                .bg(cx.theme().muted)
                .border_1()
                .border_color(cx.theme().border)
                .px_1()
                .py_1()
                .when_some(thumbnail, |row, thumbnail| row.child(thumbnail))
                .child(content);
            if card.id.is_some() {
                let source = source.clone();
                row = row.child(
                    Button::new(("remove-composer-context", index))
                        .icon(gpui_kit::assets::IconName::Close)
                        .accessibility_label(format!("Remove {}", card.title))
                        .tooltip("Remove attachment")
                        .ghost()
                        .xsmall()
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(row) = row_value.clone() {
                                this.remove_context_reference(source.clone(), row, cx);
                            }
                        })),
                );
            }
            pane = pane.child(row);
        }
        let source = source.clone();
        if raw.as_array().is_some_and(|rows| rows.len() > 1) {
            pane = pane.child(
                Button::new("clear-composer-context")
                    .label("Clear references")
                    .ghost()
                    .xsmall()
                    .text_color(cx.theme().muted_foreground)
                    .on_click(cx.listener(move |this, _, _, cx| this.clear_context(&source, cx))),
            );
        }
        Some(pane.into_any_element())
    }
    pub(super) fn transcript_context_pane(
        &mut self,
        thread_id: &str,
        item_id: &str,
        item: &Value,
        row_index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let raw = &item["context"];
        if !composer_context::has_context(raw) {
            return None;
        }
        let mut pane = div().flex().flex_wrap().items_start().gap_2().text_xs();
        if composer_context::validate(raw).is_err() {
            pane = pane.child("Some saved context is unsupported; its original data is retained.");
        }
        for (index, card) in composer_context_view::cards(raw).into_iter().enumerate() {
            let title = card.title.clone();
            let thumbnail = if card.is_file {
                raw.as_array()
                    .and_then(|rows| rows.get(index))
                    .map(|value| self.file_reference_preview(value, Some(row_index), window, cx))
            } else {
                None
            };
            let mut pill = div().child(title.clone()).into_any_element();
            if let Some(id) = card.id {
                let thread = thread_id.to_owned();
                let source = context_details::Source::Message(item_id.to_owned());
                let expected = item.clone();
                pill = Button::new(("transcript-context-card", index))
                    .child(div().w_full().truncate().child(title))
                    .when(!card.is_file, |button| {
                        button.icon(gpui_kit::assets::IconName::FileText)
                    })
                    .w_full()
                    .accessibility_label(format!("Open {}", card.title))
                    .ghost()
                    .xsmall()
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.open_context_details(
                            thread.clone(),
                            source.clone(),
                            id.clone(),
                            expected.clone(),
                            window,
                            cx,
                        )
                    }))
                    .into_any_element();
            }
            pane = pane.child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .min_w_0()
                    .when(card.is_file, |row| row.w(px(250.)).max_w_full())
                    .when(!card.is_file, |row| row.w_full())
                    .rounded(px(8.))
                    .bg(cx.theme().muted)
                    .border_1()
                    .border_color(cx.theme().border)
                    .px_1()
                    .py_1()
                    .when_some(thumbnail, |row, thumbnail| row.child(thumbnail))
                    .child(
                        div().flex_1().min_w_0().child(pill).child(
                            div()
                                .px_1()
                                .line_clamp(2)
                                .text_xs()
                                .text_color(cx.theme().muted_foreground)
                                .child(card.preview),
                        ),
                    ),
            );
        }
        Some(pane.into_any_element())
    }
}
