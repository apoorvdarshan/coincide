//! AppKit reference geometry for macOS chat chrome only.
use super::*;

// Existing provider-owned branding, already used by the Coincide website.
// Keep bytes local and embedded; rendering never downloads an image.
const PROVIDER_LOGOS: [(&str, &[u8]); 6] = [
    (
        "codex",
        include_bytes!("../assets/providers/logo-codex.png"),
    ),
    (
        "claude",
        include_bytes!("../assets/providers/logo-claude.png"),
    ),
    (
        "cursor",
        include_bytes!("../assets/providers/logo-cursor.png"),
    ),
    ("grok", include_bytes!("../assets/providers/logo-grok.png")),
    (
        "opencode",
        include_bytes!("../assets/providers/logo-opencode.png"),
    ),
    (
        "antigravity",
        include_bytes!("../assets/providers/logo-antigravity.png"),
    ),
];

pub(super) fn provider_label(provider: &str, label: String) -> AnyElement {
    static IMAGES: std::sync::OnceLock<std::collections::HashMap<&str, Arc<Image>>> =
        std::sync::OnceLock::new();
    let images = IMAGES.get_or_init(|| {
        PROVIDER_LOGOS
            .into_iter()
            .map(|(name, bytes)| {
                (
                    name,
                    Arc::new(Image::from_bytes(ImageFormat::Png, bytes.to_vec())),
                )
            })
            .collect()
    });
    div()
        .flex()
        .items_center()
        .gap(px(5.))
        .min_w_0()
        .when_some(images.get(provider), |view, image| {
            // Original monochrome branding is black on transparency. A small
            // light backing preserves its pixels in either app appearance.
            view.child(
                img(image.clone())
                    .w(px(13.))
                    .h(px(13.))
                    .rounded(px(2.))
                    .bg(rgb(0xffffff)),
            )
        })
        .when(!images.contains_key(provider), |view| {
            view.child(Icon::new(gpui_kit::assets::IconName::Cpu).xsmall())
        })
        .child(div().truncate().child(label))
        .into_any_element()
}

/// ComposerTextView reserves two actual wrapped lines and six points of text
/// inset; ComposerViewController caps the text viewport at 40% of the window.
pub(super) fn composer_height(rows: usize, line_height: f32, window_height: f32) -> f32 {
    let maximum = (window_height * 0.4).round().max(60.);
    content_height(rows, line_height).min(maximum)
}

fn content_height(rows: usize, line_height: f32) -> f32 {
    (rows.max(2) as f32 * line_height).ceil() + 6.
}

#[derive(Default)]
pub(super) struct ComposerSizing {
    last_height: Option<f32>,
}
impl ComposerSizing {
    pub(super) fn changed(&mut self, rows: usize, line_height: f32) -> bool {
        let height = content_height(rows, line_height);
        if self.last_height == Some(height) {
            return false;
        }
        self.last_height = Some(height);
        true
    }
}

fn notice_label(body: &str) -> &str {
    body.split([
        '\n', '\r', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}',
    ])
    .find(|line| !line.is_empty())
    .unwrap_or(body)
}

impl Coincide {
    pub(super) fn macos_stop_button(&self, cx: &mut Context<Self>) -> Button {
        Button::new("stop")
            .icon(gpui_kit::assets::IconName::Square)
            .accessibility_label("Stop agent")
            .tooltip("Stop agent")
            .primary()
            .w(px(28.))
            .h(px(28.))
            .rounded(px(14.))
            .p_0()
            .on_click(cx.listener(|this, _, _, cx| {
                if let Some(thread) = this.selected.as_ref()
                    && let Err(error) =
                        call(&this.engine, "agent.stop", json!({"threadId":thread["id"]}))
                {
                    this.status = error.to_string();
                }
                cx.notify();
            }))
    }
    pub(super) fn notice_row(
        &mut self,
        thread: &str,
        item: &str,
        body: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // Only non-target notices enter this compact renderer. The selected
        // find target takes message()'s expanded, complete native-text path.
        // Full-message copy still resolves the original stored item below.
        let native = self.find_body(
            thread,
            item,
            notice_label(&body).to_owned(),
            false,
            window,
            cx,
        );
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
    use super::{ComposerSizing, PROVIDER_LOGOS, composer_height, notice_label};

    #[test]
    fn all_supported_provider_logos_are_local_png_assets() {
        let mut names = std::collections::HashSet::new();
        for (provider, bytes) in PROVIDER_LOGOS {
            assert!(names.insert(provider));
            assert!(bytes.starts_with(b"\x89PNG\r\n\x1a\n"), "{provider}");
        }
        assert_eq!(names.len(), 6);
    }

    #[test]
    fn repeated_geometry_and_selection_notifications_do_not_refit_parent() {
        let mut sizing = ComposerSizing::default();
        assert!(sizing.changed(1, 18.));
        assert!(!sizing.changed(1, 18.));
        assert!(!sizing.changed(2, 18.)); // Still the two-line minimum.
        assert!(sizing.changed(3, 18.));
        assert!(!sizing.changed(3, 18.));
        assert!(sizing.changed(3, 20.));
        assert!(!sizing.changed(3, 20.));
    }

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
