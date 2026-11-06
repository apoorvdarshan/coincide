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
    pub(super) fn composer_context_pane(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let thread = self.selected.as_ref()?;
        let raw = thread.get("draftContext").unwrap_or(&Value::Null);
        if !composer_context::has_context(raw) {
            return self.composer_file_pane(cx);
        }
        let source = text(thread, "id");
        let mut pane = div()
            .id("composer-context-cards")
            .max_h(px(170.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_1();
        if let Err(error) = composer_context::validate(raw) {
            pane = pane.child(format!("Attached references retained: {error}"));
        }
        pane=pane.child("References are included when sending. File cards contain paths only; no file content is read or attached.");
        for (index, card) in composer_context_view::cards(raw).into_iter().enumerate() {
            let mut row = div().flex().gap_2().items_center().child(
                div()
                    .flex_1()
                    .min_w_0()
                    .child(card.title)
                    .child(div().text_xs().child(card.preview)),
            );
            if let Some(id) = card.id {
                let source = source.clone();
                row = row.child(
                    Button::new(("remove-composer-context", index))
                        .label("Remove")
                        .ghost()
                        .compact()
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.edit_context(&source, Edit::Remove { id: id.clone() }, cx)
                        })),
                );
            }
            pane = pane.child(row);
        }
        let source = source.clone();
        pane = pane.child(
            Button::new("clear-composer-context")
                .label("Remove all attached references")
                .ghost()
                .compact()
                .on_click(
                    cx.listener(move |this, _, _, cx| this.edit_context(&source, Edit::Clear, cx)),
                ),
        );
        if let Some(files) = self.composer_file_pane(cx) {
            pane = pane.child(files);
        }
        Some(pane.into_any_element())
    }
    pub(super) fn transcript_context_pane(&self, raw: &Value) -> Option<AnyElement> {
        if !composer_context::has_context(raw) {
            return None;
        }
        let mut pane = div()
            .flex()
            .flex_col()
            .gap_1()
            .text_xs()
            .child("Attached references");
        if composer_context::validate(raw).is_err() {
            pane = pane.child("Some saved context is unsupported; its original data is retained.");
        }
        for card in composer_context_view::cards(raw) {
            pane = pane.child(format!("{}: {}", card.title, card.preview));
        }
        Some(pane.into_any_element())
    }
}
