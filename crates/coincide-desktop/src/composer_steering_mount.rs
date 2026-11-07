use super::*;

impl Coincide {
    pub(super) fn composer_steering_pane(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let thread = self.selected.as_ref()?;
        let id = text(thread, "id");
        let provider = text(&thread["selection"], "provider");
        let running = self.running.contains(&id);
        let message = self.steering.status(&id).cloned();
        if !(running && provider == "codex") && message.is_none() {
            return None;
        }
        let draft = self.committed_composer_draft(cx);
        let build_mode =
            thread["interactionMode"].is_null() || thread["interactionMode"] == "build";
        let has_attachments = ["draftContext", "rustDraftImages"].iter().any(|key| {
            !thread[*key].is_null() && !thread[*key].as_array().is_some_and(Vec::is_empty)
        });
        let enabled = build_mode
            && !has_attachments
            && self.steering.can_submit(&id, &draft, &provider, running);
        let mut pane = div().flex().flex_col().gap_1().child(
            Button::new("steer-active-turn")
                .icon(gpui_kit::assets::IconName::CornerUpRight).w(px(28.)).h(px(28.)).rounded(px(14.)).p_0()
                .accessibility_label("Steer active turn").tooltip("Steer active turn")
                .disabled(!enabled).on_click(cx.listener(|this,_,_,cx| {
                    if this.voice.preview.is_some(){this.cancel_composer_dictation(cx);}
                    let Some(thread) = this.selected.as_ref() else { return; };
                    let id = text(thread,"id");
                    let provider = text(&thread["selection"],"provider");
                    let draft = this.composer.read(cx).value().to_string();
                    this.steering.submit(&id,&draft,&provider,this.running.contains(&id));
                    cx.notify();
                }))
        ).child(div().text_xs().child("Text-only Codex steering waits for acknowledgement. Your draft stays here; edit or clear it before submitting it again."));
        if has_attachments {
            pane = pane
                .child("Attached references and images need a normal send after the current turn.");
        }
        if let Some(message) = message {
            pane = pane.child(format!("Last steering result: {}", message.message));
        }
        if !build_mode {
            pane = pane.child("Active-turn steering is available in Build mode.");
        }
        Some(pane.into_any_element())
    }
}
