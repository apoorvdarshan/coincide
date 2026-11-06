//! AppKit reference geometry for macOS chat chrome only.
use super::*;

/// ComposerTextView reserves two actual wrapped lines and six points of text
/// inset; ComposerViewController caps the text viewport at 40% of the window.
pub(super) fn composer_height(rows: usize, line_height: f32, window_height: f32) -> f32 {
    let maximum = (window_height * 0.4).round().max(60.);
    ((rows.max(2) as f32 * line_height).ceil() + 6.).min(maximum)
}

fn notice_label(body: &str) -> &str {
    body.split([
        '\n', '\r', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}',
    ])
    .find(|line| !line.is_empty())
    .unwrap_or(body)
}

impl Coincide {
    pub(super) fn notice_row(
        &mut self,
        thread: &str,
        item: &str,
        body: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // Retain the complete native text/find state and full-message copy.
        // The clipped one-line viewport matches NoticeCell; unlike a work-log
        // card, a notice has no title, disclosure, background or border.
        let finding = self.find_context_available() && self.transcript_find.read(cx).is_open();
        let shown = if finding {
            body.clone()
        } else {
            notice_label(&body).to_owned()
        };
        let native = self.find_body(thread, item, shown, finding, window, cx);
        let source = thread.to_owned();
        let item_id = item.to_owned();
        let copy = Button::new(SharedString::from(format!("copy-message-{thread}-{item}")))
            .accessibility_id(SharedString::from(format!("copy-message-{thread}-{item}")))
            .accessibility_label("Copy complete notice")
            .icon(gpui_kit::assets::IconName::Copy)
            .ghost()
            .compact()
            .xsmall()
            .disabled(body.is_empty())
            .tooltip("Copy the complete notice text")
            .on_click(cx.listener(move |this, _, _, cx| this.copy_message(&source, &item_id, cx)));
        let rule = || {
            div()
                .flex_1()
                .min_w_0()
                .h(px(1.))
                .bg(self.color(0xe4e9f2).opacity(0.18))
        };
        div()
            .id(SharedString::from(format!("message-row-{thread}-{item}")))
            .w_full()
            .h(px(36.))
            .px(px(presentation::CONTENT_GUTTER))
            .flex()
            .justify_center()
            .child(
                div()
                    .w_full()
                    .max_w(px(presentation::CONTENT_WIDTH))
                    .pl(px(presentation::RAIL_GUTTER))
                    .pt(px(3.))
                    .flex()
                    .items_start()
                    .gap(px(10.))
                    .child(div().mt(px(8.)).flex_1().child(rule()))
                    .child(
                        div()
                            .min_w_0()
                            .max_w(relative(0.8))
                            .h(px(16.))
                            .overflow_hidden()
                            .text_center()
                            .text_color(self.color(0xe4e9f2).opacity(0.6))
                            .child(transcript::preserve_selected_copy(
                                thread,
                                item,
                                native.text_size(px((self.conversation_font_size() - 2.).max(10.))),
                            )),
                    )
                    .child(div().mt(px(8.)).flex_1().child(rule()))
                    .child(copy),
            )
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::{composer_height, notice_label};

    #[test]
    fn notice_matches_swift_first_nonempty_line_without_changing_copy_source() {
        let full = "\n\rTurn ended\nComplete synthetic detail";
        assert_eq!(notice_label(full), "Turn ended");
        assert_eq!(notice_label("端末終了\u{2028}details"), "端末終了");
        assert_eq!(notice_label(""), "");
        assert_eq!(notice_label("\n\r"), "\n\r");
    }

    #[test]
    fn composer_uses_wrapped_lines_and_window_relative_limit() {
        assert_eq!(composer_height(0, 18., 800.), 42.);
        assert_eq!(composer_height(2, 18., 800.), 42.);
        assert_eq!(composer_height(5, 18., 800.), 96.);
        assert_eq!(composer_height(100, 18., 800.), 320.);
        assert_eq!(composer_height(100, 18., 1200.), 480.);
        assert_eq!(composer_height(100, 18., 100.), 60.);
    }
}
