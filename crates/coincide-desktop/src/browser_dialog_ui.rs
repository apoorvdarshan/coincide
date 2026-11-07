//! The page's actual pending alert/confirm/prompt, above the native surface.
use super::*;
impl Coincide {
    pub(super) fn browser_dialog_banner(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let thread = self.selected.as_ref().map(|thread| text(thread, "id"))?;
        let browser = self.browser.as_ref()?;
        let dialog = browser.active_dialog(&thread)?;
        let input = browser.dialog_input(&dialog.id);
        let id = dialog.id.clone();
        let accept_thread = thread.clone();
        let reject_id = dialog.id.clone();
        let prompt = input.clone();
        Some(
            div()
                .id("browser-page-dialog")
                .flex()
                .flex_col()
                .flex_shrink_0()
                .gap_2()
                .p_3()
                .border_b_1()
                .border_color(self.color(0x364152))
                .child(div().text_sm().child("This page says"))
                .child(
                    div()
                        .id("browser-page-dialog-message")
                        .max_h(px(160.))
                        .overflow_y_scroll()
                        .child(dialog.message),
                )
                .when_some(input, |pane, input| pane.child(Input::new(&input)))
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .child(Button::new("browser-page-dialog-ok").label("OK").on_click(
                            cx.listener(move |this, _, _, cx| {
                                let value = prompt
                                    .as_ref()
                                    .map(|input| input.read(cx).value().to_string());
                                if let Some(browser) = &this.browser
                                    && let Err(error) = browser.answer_native_dialog(
                                        &accept_thread,
                                        &id,
                                        true,
                                        value,
                                    )
                                {
                                    this.status = format!("Browser: {error}");
                                }
                                cx.notify();
                            }),
                        ))
                        .when(dialog.kind != browser::DialogKind::Alert, |buttons| {
                            buttons.child(
                                Button::new("browser-page-dialog-cancel")
                                    .label("Cancel")
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        if let Some(browser) = &this.browser
                                            && let Err(error) = browser.answer_native_dialog(
                                                &thread, &reject_id, false, None,
                                            )
                                        {
                                            this.status = format!("Browser: {error}");
                                        }
                                        cx.notify();
                                    })),
                            )
                        }),
                )
                .into_any_element(),
        )
    }
}
