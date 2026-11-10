//! Swift's Up/Down recall of earlier prompts from the composer. Up in an empty
//! composer walks back through this conversation's own messages; Down walks
//! forward again and ends at the empty draft. Whenever a recall does not apply,
//! the native input keeps the key for its own caret movement.
use super::*;

/// A recall in progress: the exact text it placed and that prompt's index.
/// The text is compared with the editor, so any edit ends the walk.
pub(super) struct Recall {
    thread: String,
    text: String,
    index: usize,
}

/// What one key press does to the composer.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Step {
    /// Consumed without changing the composer: the walk passed the oldest prompt.
    Consumed,
    /// Text to place, and the index to remember; `None` restores the empty draft.
    Text { index: Option<usize>, text: String },
}

/// This conversation's prompts in order, skipping consecutive repeats the way
/// Swift does, so a re-sent message is recalled once.
pub(super) fn prompts(thread: &Value) -> Vec<String> {
    let mut prompts: Vec<String> = Vec::new();
    for item in thread["items"].as_array().into_iter().flatten() {
        if item["kind"] != "user" {
            continue;
        }
        let Some(text) = item["text"].as_str().filter(|text| !text.is_empty()) else {
            continue;
        };
        if prompts.last().map(String::as_str) == Some(text) {
            continue;
        }
        prompts.push(text.to_owned());
    }
    prompts
}

/// Up walks toward the oldest prompt, Down back toward the empty draft.
/// `None` means the key belongs to caret movement.
pub(super) fn step(prompts: &[String], index: Option<usize>, backward: bool) -> Option<Step> {
    if prompts.is_empty() {
        return None;
    }
    let next = match (index, backward) {
        (Some(0), true) => return Some(Step::Consumed),
        (Some(index), true) => index - 1,
        (Some(index), false) => index + 1,
        (None, true) => prompts.len() - 1,
        (None, false) => return None,
    };
    match prompts.get(next) {
        Some(text) => Some(Step::Text {
            index: Some(next),
            text: text.clone(),
        }),
        None => Some(Step::Text {
            index: None,
            text: String::new(),
        }),
    }
}

impl Coincide {
    /// The composer is not empty of attachments or references, which make the
    /// draft real content rather than a place to recall a prompt.
    fn composer_history_blocked(&self) -> bool {
        fn content(raw: &Value) -> bool {
            !raw.is_null() && !raw.as_array().is_some_and(Vec::is_empty)
        }
        self.selected.as_ref().is_some_and(|thread| {
            content(&thread["rustDraftImages"]) || content(&thread["draftContext"])
        })
    }

    /// The caret sits on the first or last visual line with nothing selected,
    /// Swift's condition for the key to mean history instead of movement.
    fn composer_caret_on_edge(&self, backward: bool, cx: &App) -> bool {
        let state = self.composer.read(cx);
        if !state.selected_range().is_empty() {
            return false;
        }
        let value = state.value();
        let caret = state.cursor().min(value.len());
        let (before, after) = value.split_at(caret);
        if backward {
            !before.contains('\n')
        } else {
            !after.contains('\n')
        }
    }

    /// One Up or Down from the composer. False returns the key to the input.
    pub(super) fn composer_history_key(
        &mut self,
        backward: bool,
        modified: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if modified || !window.is_window_active() {
            return false;
        }
        if self.composer_history_blocked() {
            return false;
        }
        let Some(thread) = self.selected.as_ref() else {
            return false;
        };
        let thread_id = text(thread, "id");
        let is_focused = self.composer.read(cx).focus_handle(cx).is_focused(window);
        let editable = self.composer.read(cx).is_editable();
        let ime = self.composer.update(cx, |input, cx| {
            gpui_kit::EntityInputHandler::marked_text_range(input, window, cx).is_some()
        });
        if !is_focused || !editable || ime {
            return false;
        }
        let value = self.composer.read(cx).value();
        let recalling = self
            .composer_history
            .as_ref()
            .filter(|recall| recall.thread == thread_id && recall.text == value.as_ref());
        // An empty composer starts a walk; any other text belongs to the caret.
        if recalling.is_none() && !value.is_empty() {
            return false;
        }
        if !self.composer_caret_on_edge(backward, cx) {
            return false;
        }
        let prompts = prompts(thread);
        let Some(step) = step(&prompts, recalling.map(|recall| recall.index), backward) else {
            return false;
        };
        let Step::Text { index, text } = step else {
            return true;
        };
        self.composer_history = index.map(|index| Recall {
            thread: thread_id,
            text: text.clone(),
            index,
        });
        self.composer.update(cx, |input, cx| {
            let end = text.len();
            input.set_value(text, window, cx);
            input.set_selected_range(end..end, cx);
        });
        // Placement is not a native edit, so record the draft here as typing does.
        self.record_composer_draft(cx);
        cx.notify();
        true
    }
}

#[cfg(test)]
mod tests {
    use super::{Step, prompts, step};
    use serde_json::json;

    fn prompts_of(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[::core::prelude::v1::test]
    fn up_starts_at_the_newest_prompt_and_walks_to_the_oldest() {
        let all = prompts_of(&["first", "second", "third"]);
        assert_eq!(
            step(&all, None, true),
            Some(Step::Text {
                index: Some(2),
                text: "third".into()
            })
        );
        assert_eq!(
            step(&all, Some(2), true),
            Some(Step::Text {
                index: Some(1),
                text: "second".into()
            })
        );
        assert_eq!(
            step(&all, Some(0), true),
            Some(Step::Consumed),
            "the oldest prompt keeps its text instead of wrapping"
        );
    }

    #[::core::prelude::v1::test]
    fn down_walks_back_and_ends_at_the_empty_draft() {
        let all = prompts_of(&["first", "second"]);
        assert_eq!(
            step(&all, Some(0), false),
            Some(Step::Text {
                index: Some(1),
                text: "second".into()
            })
        );
        assert_eq!(
            step(&all, Some(1), false),
            Some(Step::Text {
                index: None,
                text: String::new()
            })
        );
        assert_eq!(
            step(&all, None, false),
            None,
            "Down on a draft keeps the caret's own movement"
        );
    }

    #[::core::prelude::v1::test]
    fn a_thread_without_prompts_recalls_nothing() {
        assert_eq!(step(&[], None, true), None);
        assert_eq!(step(&[], Some(0), false), None);
    }

    #[::core::prelude::v1::test]
    fn prompts_skip_consecutive_repeats_but_keep_later_ones() {
        let thread = json!({"items": [
            {"kind": "user", "text": "one"},
            {"kind": "assistant", "text": "reply"},
            {"kind": "user", "text": "one"},
            {"kind": "user", "text": ""},
            {"kind": "user", "text": "two"},
            {"kind": "user", "text": "one"}
        ]});
        assert_eq!(prompts(&thread), prompts_of(&["one", "two", "one"]));
        assert_eq!(prompts(&json!({})), Vec::<String>::new());
    }
}
