//! Live composer ownership and UTF-8 insertion, independent of the UI renderer.
use super::transcription_settings::{ComposerBinding, TextReady};
use anyhow::{Result, ensure};
use coincide_core::dictation::DictationSession;
use std::ops::Range;

#[derive(PartialEq, Eq)]
struct Snapshot {
    thread: String,
    text: String,
    selection: Range<usize>,
    reversed: bool,
}
#[derive(Default)]
pub(super) struct ComposerTarget {
    revision: u64,
    snapshot: Option<Snapshot>,
}
impl ComposerTarget {
    /// Notifications invalidate even if edits or caret moves return to the same
    /// state before observation. Thread selection calls this synchronously too.
    pub fn changed(&mut self) {
        self.revision = self.revision.wrapping_add(1);
    }
    pub fn bind(
        &mut self,
        thread: Option<&str>,
        text: &str,
        selection: Range<usize>,
        reversed: bool,
    ) -> Option<ComposerBinding> {
        let snapshot = thread
            .filter(|_| {
                selection.start <= selection.end
                    && text.is_char_boundary(selection.start)
                    && text.is_char_boundary(selection.end)
            })
            .map(|thread| Snapshot {
                thread: thread.into(),
                text: text.into(),
                selection,
                reversed,
            });
        if self.snapshot != snapshot {
            self.changed();
            self.snapshot = snapshot;
        }
        self.snapshot.as_ref().map(|snapshot| ComposerBinding {
            thread_id: snapshot.thread.clone(),
            composer_revision: self.revision,
            selection: snapshot.selection.clone(),
        })
    }
}

/// Caller must also check the panel's generation immediately before insertion.
pub(super) fn insert(
    current: &ComposerBinding,
    event: &TextReady,
    text: &str,
) -> Result<(String, usize)> {
    ensure!(
        event.binding == *current,
        "Composer changed; transcript discarded"
    );
    let mut session = DictationSession::start(text, current.selection.clone())
        .map_err(|_| anyhow::anyhow!("Composer selection is not a valid UTF-8 range"))?;
    let mut updated = text.to_owned();
    let caret = session
        .update(&mut updated, &event.text)
        .map_err(|_| anyhow::anyhow!("Composer changed; transcript discarded"))?;
    Ok((updated, caret))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn same_text_round_trip_edits_and_conversation_away_back_invalidate() {
        let mut target = ComposerTarget::default();
        let original = target.bind(Some("a"), "draft", 1..3, false).unwrap();
        target.changed(); // Input observed, even if final text/caret returned to original.
        assert!(target.bind(Some("a"), "draft", 1..3, false).unwrap() != original);
        let before = target.bind(Some("a"), "draft", 1..3, false).unwrap();
        target.bind(Some("b"), "draft", 1..3, false);
        assert!(target.bind(Some("a"), "draft", 1..3, false).unwrap() != before);
    }
    #[test]
    fn live_changes_invalidate_before_observer_delivery_and_hidden_panel_revokes() {
        let mut target = ComposerTarget::default();
        let old = target.bind(Some("a"), "draft", 1..3, false).unwrap();
        assert!(target.bind(Some("a"), "new draft", 1..3, false).unwrap() != old);
        let old = target.bind(Some("a"), "new draft", 1..3, false).unwrap();
        assert!(target.bind(Some("a"), "new draft", 1..3, true).unwrap() != old);
        let old = target.bind(Some("a"), "new draft", 1..3, true).unwrap();
        assert!(target.bind(None, "new draft", 1..3, true).is_none());
        assert!(target.bind(Some("a"), "new draft", 1..3, true).unwrap() != old);
    }
    #[test]
    fn unicode_selection_inserts_once_and_stale_bindings_cannot_replace_text() {
        let mut target = ComposerTarget::default();
        let original = "Hello 🌍!";
        let binding = target.bind(Some("a"), original, 6..10, false).unwrap();
        let event = TextReady {
            generation: 1,
            binding: binding.clone(),
            text: "世界".into(),
        };
        let (updated, caret) = insert(&binding, &event, original).unwrap();
        assert_eq!(updated, "Hello 世界!");
        assert_eq!(caret, "Hello 世界".len());
        let now = target
            .bind(Some("a"), &updated, caret..caret, false)
            .unwrap();
        assert!(insert(&now, &event, &updated).is_err());
        assert!(target.bind(Some("a"), original, 7..9, false).is_none());
        assert!(target.bind(Some("a"), original, 0..99, false).is_none());
    }
}
