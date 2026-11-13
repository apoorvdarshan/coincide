//! Shared chat structure and geometry, following the Swift desktop reference.
use super::*;

// Provider marks stay local and embedded. Claude and Antigravity use the
// original colored marks from Coincide's existing asset catalog.
pub(super) const PROVIDER_LOGOS: [(&str, &[u8]); 6] = [
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

pub(super) fn provider_logo(provider: &str) -> Option<Arc<Image>> {
    static IMAGES: std::sync::OnceLock<std::collections::HashMap<&str, Arc<Image>>> =
        std::sync::OnceLock::new();
    IMAGES
        .get_or_init(|| {
            PROVIDER_LOGOS
                .into_iter()
                .map(|(name, bytes)| {
                    (
                        name,
                        Arc::new(Image::from_bytes(ImageFormat::Png, bytes.to_vec())),
                    )
                })
                .collect()
        })
        .get(provider)
        .cloned()
}

/// Give monochrome marks a consistent provider-colored tile while preserving
/// the original colored Claude and Antigravity artwork.
pub(super) fn provider_badge(provider: &str, size: f32) -> Option<Div> {
    let logo = provider_logo(provider)?;
    let background = provider_badge_color(provider)?;
    let mark = if matches!(provider, "claude" | "antigravity") {
        0.82
    } else {
        0.72
    };
    Some(
        div()
            .size(px(size))
            .flex_shrink_0()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(size * 0.23))
            .bg(rgb(background))
            .child(img(logo).size(px(size * mark))),
    )
}

fn provider_badge_color(provider: &str) -> Option<u32> {
    Some(match provider {
        "codex" => 0x0e8067,
        "claude" => 0x482b27,
        "cursor" => 0x5959a9,
        "grok" => 0x695581,
        "opencode" => 0x9a641c,
        "antigravity" => 0x202b43,
        _ => return None,
    })
}

pub(super) fn provider_label(provider: &str, label: String) -> AnyElement {
    let image = provider_badge(provider, 15.);
    div()
        .flex()
        .items_center()
        .gap(px(5.))
        .min_w_0()
        .when_some(image, |view, image| view.child(image))
        .when(provider_logo(provider).is_none(), |view| {
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

/// Earlier Rust builds stored a "Turn ended" notice at the end of every turn;
/// Swift never did. Keep the stored items for exact transcripts and search, but
/// do not draw a divider Swift has no equivalent for.
pub(super) fn is_synthetic_turn_end(body: &str) -> bool {
    notice_label(body) == "Turn ended"
}

fn notice_label(body: &str) -> &str {
    body.split([
        '\n', '\r', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}',
    ])
    .find(|line| !line.is_empty())
    .unwrap_or(body)
}

impl Coincide {
    pub(super) fn composer_stop_button(&self, cx: &mut Context<Self>) -> Button {
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
    use super::{
        ComposerSizing, PROVIDER_LOGOS, composer_height, is_synthetic_turn_end, notice_label,
        provider_badge_color,
    };

    #[test]
    fn all_supported_provider_logos_are_local_png_assets() {
        let mut names = std::collections::HashSet::new();
        for (provider, bytes) in PROVIDER_LOGOS {
            assert!(names.insert(provider));
            assert!(bytes.starts_with(b"\x89PNG\r\n\x1a\n"), "{provider}");
            assert!(provider_badge_color(provider).is_some(), "{provider}");
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
    fn synthetic_turn_end_remains_stored_but_is_not_drawn() {
        assert!(is_synthetic_turn_end("Turn ended"));
        assert!(is_synthetic_turn_end("\nTurn ended\n"));
        assert!(!is_synthetic_turn_end("Interrupted"));
        assert!(!is_synthetic_turn_end("Turn ended early"));
    }

    #[::core::prelude::v1::test]
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

impl Coincide {
    /// Swift's approval card: what the agent wants to do, and once answered,
    /// the answer. The choices themselves stay in the banner above the composer.
    pub(super) fn approval_transcript_card(
        &mut self,
        thread: &str,
        item: &str,
        value: &Value,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> AnyElement {
        let payload = serde_json::from_str::<Value>(value["text"].as_str().unwrap_or(""))
            .unwrap_or(Value::Null);
        let status = value["status"].as_str();
        let waiting = !matches!(status, Some("completed" | "declined"));
        let declined = status == Some("declined");
        let warning = rgb(if self.appearance_dark {
            0xFF9F0A
        } else {
            0xFF9500
        });
        let success = rgb(0x34C759);
        let failure = rgb(0xE5645C);
        let secondary = self.color(0xe4e9f2).opacity(0.6);
        let tertiary = self.color(0xe4e9f2).opacity(0.42);
        let (kind_label, title) = presentation::approval_summary(&payload);
        let resolution = value["approval"]["resolution"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| {
                if declined {
                    "Declined".into()
                } else {
                    "Approved".into()
                }
            });
        let reply = value["approval"]["responseText"]
            .as_str()
            .map(str::trim)
            .filter(|reply| !reply.is_empty());
        let status_text = if waiting {
            "Waiting for your answer below".to_owned()
        } else if let Some(reply) = reply {
            format!("{resolution}: “{reply}”")
        } else {
            resolution
        };
        let status_color = if waiting {
            Hsla::from(warning)
        } else if declined {
            Hsla::from(failure)
        } else {
            Hsla::from(success)
        };
        let status_icon = if waiting {
            gpui_kit::assets::IconName::Hourglass
        } else if declined {
            gpui_kit::assets::IconName::CircleX
        } else {
            gpui_kit::assets::IconName::CircleCheck
        };
        div()
            .id(SharedString::from(format!("message-row-{thread}-{item}")))
            .w_full()
            .px(px(presentation::CONTENT_GUTTER))
            .my_3()
            .flex()
            .justify_center()
            .child(
                div()
                    .w_full()
                    .max_w(px(presentation::CONTENT_WIDTH))
                    .pl(px(presentation::RAIL_GUTTER))
                    .p_3()
                    .rounded(px(12.))
                    .bg(self.color(0x181d28))
                    .border_1()
                    .border_color(if waiting {
                        Hsla::from(warning).opacity(0.3)
                    } else {
                        Hsla::from(self.color(0x29303d))
                    })
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(
                                Icon::new(if waiting {
                                    gpui_kit::assets::IconName::Hourglass
                                } else {
                                    gpui_kit::assets::IconName::ShieldCheck
                                })
                                .xsmall()
                                .text_color(if waiting {
                                    Hsla::from(warning)
                                } else {
                                    Hsla::from(secondary)
                                }),
                            )
                            .child(
                                div()
                                    .flex_shrink_0()
                                    .text_size(px((self.conversation_font_size() - 2.).max(10.)))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(if waiting {
                                        Hsla::from(warning)
                                    } else {
                                        Hsla::from(secondary)
                                    })
                                    .child(kind_label),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px((self.conversation_font_size() - 1.).max(10.)))
                            .child(title),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_1()
                            .text_size(px((self.conversation_font_size() - 2.).max(10.)))
                            .child(Icon::new(status_icon).xsmall().text_color(status_color))
                            .child(
                                div()
                                    .min_w_0()
                                    .truncate()
                                    .text_color(if waiting {
                                        Hsla::from(warning)
                                    } else {
                                        Hsla::from(tertiary)
                                    })
                                    .child(status_text),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// Swift's plan card: the checklist an agent wrote, with its progress.
    pub(super) fn plan_transcript_card(
        &mut self,
        thread: &str,
        item: &str,
        value: &Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let body = text(value, "text");
        let (done, total) = presentation::plan_progress(&body);
        let progress = (total > 0).then(|| format!("{done} of {total} done"));
        let secondary = self.color(0xe4e9f2).opacity(0.6);
        let tertiary = self.color(0xe4e9f2).opacity(0.42);
        let native = self.find_body(thread, item, body, true, window, cx);
        div()
            .id(SharedString::from(format!("message-row-{thread}-{item}")))
            .w_full()
            .px(px(presentation::CONTENT_GUTTER))
            .my_3()
            .flex()
            .justify_center()
            .child(
                div()
                    .w_full()
                    .max_w(px(presentation::CONTENT_WIDTH))
                    .pl(px(presentation::RAIL_GUTTER))
                    .p_3()
                    .rounded(px(12.))
                    .bg(self.color(0x181d28))
                    .border_1()
                    .border_color(self.color(0x29303d))
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .child(
                                Icon::new(gpui_kit::assets::IconName::ListChecks)
                                    .xsmall()
                                    .text_color(Hsla::from(secondary)),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .text_size(px((self.conversation_font_size() - 1.).max(10.)))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child("Plan"),
                            )
                            .when_some(progress, |row, progress| {
                                row.child(
                                    div()
                                        .flex_shrink_0()
                                        .text_size(
                                            px((self.conversation_font_size() - 2.).max(10.)),
                                        )
                                        .text_color(Hsla::from(tertiary))
                                        .child(progress),
                                )
                            }),
                    )
                    .child(transcript::preserve_selected_copy(
                        thread,
                        item,
                        native.text_size(px(self.conversation_font_size())),
                    )),
            )
            .into_any_element()
    }
}
