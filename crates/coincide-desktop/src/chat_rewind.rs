//! Swift's "Edit from here?" (ChatViewController.rewindTurn): any message of
//! the user's can be rewound to in place, returning it to the composer and
//! keeping files as they are; when the turn's checkpoint can be restored,
//! "Revert Files Too" also puts files back the way they were before it.
use super::*;

pub(super) const TITLE: &str = "Edit from here?";
pub(super) const DETAIL_WITH_FILES: &str = "The conversation is rewound to before this message, which returns to the composer. “Revert Files Too” also puts files back the way they were before it, undoing any edits since.";
pub(super) const DETAIL_WITHOUT_FILES: &str = "The conversation is rewound to before this message, which returns to the composer. Files on disk are not changed.";

/// The dialog's buttons, in Swift's order.
pub(super) fn buttons(can_restore: bool) -> &'static [&'static str] {
    if can_restore {
        &["Revert and Keep Changes", "Revert Files Too", "Cancel"]
    } else {
        &["Edit from Here", "Cancel"]
    }
}

/// What a dialog answer asks for: Some(revert files) or None for Cancel.
pub(super) fn choice(answer: usize, can_restore: bool) -> Option<bool> {
    match (answer, can_restore) {
        (0, _) => Some(false),
        (1, true) => Some(true),
        _ => None,
    }
}

impl Coincide {
    /// Swift's pencil under the user's message, beside Copy.
    pub(super) fn edit_from_here_button(
        &self,
        source: &str,
        item: &str,
        excerpt: &str,
        running: bool,
        cx: &mut Context<Self>,
    ) -> Button {
        let (source, item_id) = (source.to_owned(), item.to_owned());
        Button::new(SharedString::from(format!(
            "edit-from-here-{source}-{item}"
        )))
        .accessibility_id(SharedString::from(format!(
            "edit-from-here-{source}-{item}"
        )))
        .accessibility_label(SharedString::from(format!("Edit from here: {excerpt}")))
        .icon(gpui_kit::assets::IconName::Pencil)
        .ghost()
        .compact()
        .xsmall()
        .disabled(running)
        .tooltip(if running {
            "Stop the current turn before editing an earlier message"
        } else {
            "Edit from Here…"
        })
        .on_click(
            cx.listener(move |this, _, window, cx| this.rewind_turn(&source, &item_id, window, cx)),
        )
    }

    pub(super) fn rewind_turn(
        &mut self,
        source: &str,
        item: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self
            .selected
            .as_ref()
            .is_none_or(|thread| thread["id"] != source)
        {
            self.status = "Conversation changed. Select the message again before editing.".into();
            cx.notify();
            return;
        }
        if self.running.iter().any(|id| id == source) {
            self.status = "Stop the current turn before editing an earlier message.".into();
            cx.notify();
            return;
        }
        let can_restore = call(
            &self.engine,
            "checkpoints.canRestore",
            json!({"threadId":source,"userItemId":item}),
        )
        .is_ok_and(|reply| reply["canRestore"] == true);
        let answer = window.prompt(
            PromptLevel::Warning,
            TITLE,
            Some(if can_restore {
                DETAIL_WITH_FILES
            } else {
                DETAIL_WITHOUT_FILES
            }),
            buttons(can_restore),
            cx,
        );
        let (source, item) = (source.to_owned(), item.to_owned());
        cx.spawn_in(window, async move |this, cx| {
            let Ok(answer) = answer.await else {
                return;
            };
            let Some(revert) = choice(answer, can_restore) else {
                return;
            };
            this.update_in(cx, |this, window, cx| {
                this.apply_rewind(&source, &item, revert, window, cx)
            })
            .ok();
        })
        .detach();
    }

    fn apply_rewind(
        &mut self,
        source: &str,
        item: &str,
        revert: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // An agent may have started a turn while the dialog was open; the
        // Core refuses that too, so this only words the common case.
        if self
            .selected
            .as_ref()
            .is_none_or(|thread| thread["id"] != source)
            || self.running.iter().any(|id| id == source)
        {
            self.status = "The conversation changed; nothing was rewound.".into();
            cx.notify();
            return;
        }
        match call(
            &self.engine,
            "threads.rewind",
            json!({"threadId":source,"itemId":item,"revertFiles":revert}),
        ) {
            Ok(reply) => {
                // The restored message replaces whatever was being typed.
                self.pending_drafts.remove(source);
                self.select(source, window, cx);
                self.refresh(cx);
                self.composer.read(cx).focus_handle(cx).focus(window, cx);
                self.status = if reply["filesRestored"] == true {
                    "Rewound to before this message and put files back the way they were."
                } else {
                    "Rewound to before this message. Files on disk are unchanged."
                }
                .into();
            }
            Err(error) => self.status = format!("Could not edit from here: {error}"),
        }
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn answers_map_to_swift_buttons() {
        assert_eq!(buttons(true)[1], "Revert Files Too");
        assert_eq!(choice(0, true), Some(false));
        assert_eq!(choice(1, true), Some(true));
        assert_eq!(choice(2, true), None);
        assert_eq!(buttons(false), ["Edit from Here", "Cancel"]);
        assert_eq!(choice(0, false), Some(false));
        assert_eq!(choice(1, false), None);
    }
}
