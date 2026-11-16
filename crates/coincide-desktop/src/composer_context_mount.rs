use super::*;
use coincide_core::composer_context::{self, Edit, ExpectedContext};
impl Coincide {
    fn edit_context(&mut self, source: &str, edit: Edit, cx: &mut Context<Self>) {
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
        match call(
            &self.engine,
            "composer.context.edit",
            json!({"threadId":source,"expectedContext":expected,"edit":edit}),
        ) {
            Ok(saved) => {
                // Only this field was edited. The composer and pending unsaved
                // text remain owned by their existing draft-save path.
                if let Some(thread) = self
                    .selected
                    .as_mut()
                    .filter(|thread| thread["id"] == source)
                {
                    thread["draftContext"] = saved["draftContext"].clone();
                }
                self.status = "Attached references saved.".into();
            }
            Err(error) => self.status = error.to_string(),
        }
        cx.notify();
    }
    pub(super) fn quote_message(&mut self, source: &str, item: &str, cx: &mut Context<Self>) {
        self.edit_context(
            source,
            Edit::Quote {
                item_id: item.into(),
            },
            cx,
        );
    }

    fn remove_file_reference(&mut self, source: String, card: Value, cx: &mut Context<Self>) {
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
                        .remove_cancelled_picked_path(&owner, &expected)
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
    pub(super) fn composer_context_pane(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let thread = self.selected.as_ref()?;
        let raw = thread.get("draftContext").unwrap_or(&Value::Null);
        if !composer_context::has_context(raw) {
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
        if let Err(error) = composer_context::validate(raw) {
            pane = pane.child(format!("Attached references retained: {error}"));
        }
        for (index, card) in composer_context_view::cards(raw).into_iter().enumerate() {
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
                    .label(card.title.clone())
                    .icon(icon)
                    .accessibility_label(format!("Open {}", card.title))
                    .ghost()
                    .compact()
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
                    .px_2()
                    .truncate()
                    .text_xs()
                    .text_color(self.color(0xe4e9f2).opacity(0.6))
                    .child(card.preview),
            );
            let mut row = div()
                .flex()
                .gap_2()
                .items_center()
                .min_w_0()
                .when(card.is_file, |row| row.w(px(190.)))
                .when(!card.is_file, |row| row.w_full())
                .rounded_md()
                .bg(self.color(0x202735))
                .px_1()
                .py_1()
                .child(content);
            if let Some(id) = card.id {
                let source = source.clone();
                let row_value = raw.as_array().and_then(|rows| rows.get(index)).cloned();
                let is_file = card.is_file;
                row = row.child(
                    Button::new(("remove-composer-context", index))
                        .icon(gpui_kit::assets::IconName::Close)
                        .accessibility_label(format!("Remove {}", card.title))
                        .tooltip("Remove attachment")
                        .ghost()
                        .xsmall()
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if is_file {
                                if let Some(row) = row_value.clone() {
                                    this.remove_file_reference(source.clone(), row, cx);
                                }
                            } else {
                                this.edit_context(&source, Edit::Remove { id: id.clone() }, cx);
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
                    .label("Remove all")
                    .ghost()
                    .compact()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.edit_context(&source, Edit::Clear, cx)
                    })),
            );
        }
        Some(pane.into_any_element())
    }
    pub(super) fn transcript_context_pane(
        &self,
        thread_id: &str,
        item_id: &str,
        item: &Value,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let raw = &item["context"];
        if !composer_context::has_context(raw) {
            return None;
        }
        let mut pane = div().flex().flex_col().gap_1().text_xs();
        if composer_context::validate(raw).is_err() {
            pane = pane.child("Some saved context is unsupported; its original data is retained.");
        }
        for (index, card) in composer_context_view::cards(raw).into_iter().enumerate() {
            let title = card.title.clone();
            let mut pill = div().child(title.clone()).into_any_element();
            if let Some(id) = card.id {
                let thread = thread_id.to_owned();
                let source = context_details::Source::Message(item_id.to_owned());
                let expected = item.clone();
                pill = Button::new(("transcript-context-card", index))
                    .label(title)
                    .icon(if card.is_directory {
                        gpui_kit::assets::IconName::Folder
                    } else {
                        gpui_kit::assets::IconName::FileText
                    })
                    .accessibility_label(format!("Open {}", card.title))
                    .ghost()
                    .compact()
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
                    .rounded_md()
                    .bg(self.color(0x202735))
                    .px_1()
                    .py_1()
                    .child(pill)
                    .child(
                        div()
                            .truncate()
                            .text_xs()
                            .text_color(self.color(0xe4e9f2).opacity(0.6))
                            .child(card.preview),
                    ),
            );
        }
        Some(pane.into_any_element())
    }
}
