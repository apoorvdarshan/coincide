use super::*;
use context_details::{Details, Selection, Source};
#[derive(Default)]
pub(super) struct State {
    opened: Option<Opened>,
    generation: u64,
}
struct Opened {
    selection: Selection,
    details: Details,
    body: Entity<TextareaState>,
    comment: Entity<TextareaState>,
    restore: Option<FocusHandle>,
}
impl State {
    pub(super) fn invalidate(&mut self) {
        self.opened = None;
        self.generation = self.generation.wrapping_add(1);
    }
}
impl Coincide {
    pub(super) fn open_context_details(
        &mut self,
        source_thread: String,
        source: Source,
        card: String,
        expected: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.media.close_requested || self.media.shutdown_requested {
            return;
        }
        let result = (|| -> Result<_> {
            let thread = self
                .selected
                .as_ref()
                .filter(|thread| thread["id"] == source_thread)
                .ok_or_else(|| anyhow::anyhow!("The conversation changed; open the card again"))?;
            Selection::open(thread, source, card, expected)
        })();
        match result {
            Ok((selection, details)) => {
                let body = cx.new(|cx| {
                    let mut state = TextareaState::new(window, cx);
                    state.set_value(details.body.clone(), window, cx);
                    state
                });
                let comment = cx.new(|cx| {
                    let mut state = TextareaState::new(window, cx);
                    state.set_value(details.comment.clone().unwrap_or_default(), window, cx);
                    state
                });
                let restore = window.focused(cx);
                body.read(cx).focus_handle(cx).focus(window, cx);
                self.context_details.generation = self.context_details.generation.wrapping_add(1);
                self.context_details.opened = Some(Opened {
                    selection,
                    details,
                    body,
                    comment,
                    restore,
                });
            }
            Err(error) => self.status = error.to_string(),
        }
        cx.notify();
    }
    pub(super) fn sync_context_details(&mut self) {
        if self.context_details.opened.is_none() {
            return;
        }
        let current = !self.settings_open
            && !self.schedules_open
            && !self.workspace_open
            && !self.session_import_open
            && !self.media.close_requested
            && !self.media.shutdown_requested
            && self.context_details.opened.as_ref().is_none_or(|opened| {
                opened
                    .selection
                    .current(self.selected.as_ref())
                    .ok()
                    .flatten()
                    .as_ref()
                    == Some(&opened.details)
            });
        if !current {
            self.context_details.invalidate();
        }
    }
    fn close_context_details(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let restore = self
            .context_details
            .opened
            .as_ref()
            .and_then(|opened| opened.restore.clone());
        self.context_details.invalidate();
        if let Some(restore) = restore {
            restore.focus(window, cx);
        }
        cx.notify();
    }
    pub(super) fn context_details_shortcut(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.context_details.opened.is_none() {
            return false;
        }
        let key = &event.keystroke;
        if key.key == "escape"
            && !key.modifiers.platform
            && !key.modifiers.control
            && !key.modifiers.alt
            && !key.modifiers.shift
        {
            self.close_context_details(window, cx);
            cx.stop_propagation();
            return true;
        }
        false
    }
    fn copy_context_details(&mut self, generation: u64, cx: &mut Context<Self>) {
        if generation != self.context_details.generation
            || self.media.close_requested
            || self.media.shutdown_requested
        {
            return;
        }
        let result = self.context_details.opened.as_ref().and_then(|opened| {
            opened
                .selection
                .current(self.selected.as_ref())
                .ok()
                .flatten()
        });
        if let Some(details) = result {
            cx.write_to_clipboard(ClipboardItem::new_string(details.copy));
            self.status = "Copied the complete attached reference.".into();
        } else {
            self.context_details.invalidate();
            self.status = "The attached reference changed; open it again before copying.".into();
        }
        cx.notify();
    }
    pub(super) fn context_details_overlay(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let opened = self.context_details.opened.as_ref()?;
        // Recheck again at render, so an outdated source never remains visible
        // while the next normal Engine/UI refresh is pending.
        if opened
            .selection
            .current(self.selected.as_ref())
            .ok()
            .flatten()
            .as_ref()
            != Some(&opened.details)
        {
            return None;
        }
        let generation = self.context_details.generation;
        let details = &opened.details;
        let mut panel = div()
            .id("context-details-panel")
            .w_full()
            .max_w(px(480.))
            .max_h_full()
            .min_h_0()
            .overflow_y_scroll()
            .rounded_lg()
            .border_1()
            .border_color(self.color(0x29303d))
            .bg(self.color(0x181d28))
            .p_4()
            .flex()
            .flex_col()
            .gap_2()
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|_, _, _, cx| cx.stop_propagation()),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1().text_lg().child(details.title.clone()))
                    .child(
                        Button::new("context-details-copy")
                            .label(if details.file_path_only {
                                "Copy path"
                            } else {
                                "Copy"
                            })
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.copy_context_details(generation, cx)
                            })),
                    )
                    .child(
                        Button::new("context-details-close")
                            .label("Close")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.close_context_details(window, cx)
                            })),
                    ),
            );
        if let Some(subtitle) = &details.subtitle {
            panel = panel.child(div().text_sm().child(subtitle.clone()));
        }
        if details.comment.is_some() {
            panel = panel.child(readonly_reference_text(
                &opened.comment,
                false,
                "Diff comment",
                80.,
            ));
        }
        if details.file_path_only {
            panel = panel
                .child("File path reference only. No file content is read or opened by this view.");
        }
        panel = panel.child(readonly_reference_text(
            &opened.body,
            details.code,
            if details.file_path_only {
                "Attached file path"
            } else {
                "Attached text"
            },
            300.,
        ));
        Some(
            div()
                .id("context-details-overlay")
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .p_4()
                .bg(rgba(0x00000066))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(|this, _, window, cx| {
                        this.close_context_details(window, cx);
                        cx.stop_propagation();
                    }),
                )
                .child(panel)
                .into_any_element(),
        )
    }
}

/// Production and the private headless fixture use this exact readonly input.
/// It retains native focus/selection/copy while rejecting text edits.
pub(super) fn readonly_reference_text(
    state: &Entity<TextareaState>,
    code: bool,
    label: &'static str,
    height: f32,
) -> AnyElement {
    div()
        .min_h_0()
        .when(code, |view| view.font_family("monospace"))
        .child(
            Textarea::new(state)
                .readonly(true)
                .aria_label(label)
                .h(px(height)),
        )
        .into_any_element()
}
#[cfg(test)]
#[path = "context_details_ui_tests.rs"]
mod tests;
