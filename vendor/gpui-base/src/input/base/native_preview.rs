//! Narrow native transient edits for a caller that owns the current source.
use super::*;
use crate::input::TextareaMode;
use gpui::EntityId;
use std::ops::{Deref, DerefMut};
/// Minted by the actual textarea. No value/document constructor or serialization.
#[derive(Clone, PartialEq, Eq)]
pub struct NativeTextRevision {
    owner: EntityId,
    revision: u64,
    selection: Range<usize>,
    reversed: bool,
}
/// UTF-8 byte ranges and text for one source-checked native replacement.
/// Data alone grants nothing: the actual entity revision is required as well.
pub struct TransientReplacement<'a> {
    pub expected: &'a str,
    pub range: Range<usize>,
    pub replacement: &'a str,
    pub selection_after: Range<usize>,
    pub reversed: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransientEditError {
    Changed,
    NotEditable,
    Composition,
    Unsupported,
    Bounds,
    Rejected,
}
/// Keep the original manager wholly untouched, including redo, selection
/// snapshots and coalescing. Restoration also runs during panic unwinding.
struct TransientScope<'a> {
    state: &'a mut InputBaseState<TextareaMode>,
    history: Option<UndoManager>,
    emit_events: bool,
    silent: bool,
    edits: Vec<(InputEdit, Rope)>,
}
impl<'a> TransientScope<'a> {
    fn new(state: &'a mut InputBaseState<TextareaMode>) -> Self {
        let history = std::mem::replace(&mut state.undo_manager, UndoManager::new());
        let emit_events = state.emit_events;
        let silent = state.silent_replace_text;
        let edits = std::mem::take(&mut state.last_input_edits);
        state.undo_manager.set_ignoring(true);
        state.emit_events = false;
        state.silent_replace_text = true;
        Self {
            state,
            history: Some(history),
            emit_events,
            silent,
            edits,
        }
    }
}
impl Deref for TransientScope<'_> {
    type Target = InputBaseState<TextareaMode>;
    fn deref(&self) -> &Self::Target {
        self.state
    }
}
impl DerefMut for TransientScope<'_> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.state
    }
}
impl Drop for TransientScope<'_> {
    fn drop(&mut self) {
        self.state.undo_manager = self.history.take().expect("Owned transient history");
        self.state.emit_events = self.emit_events;
        self.state.silent_replace_text = self.silent;
        self.state.last_input_edits = std::mem::take(&mut self.edits);
    }
}
impl InputBaseState<TextareaMode> {
    /// Native text/selection identity, bound to this actual entity. An edit away
    /// and back invalidates it even when the resulting string is identical.
    pub fn native_text_revision(&self, cx: &Context<Self>) -> NativeTextRevision {
        NativeTextRevision {
            owner: cx.entity_id(),
            revision: self.document_revision,
            selection: self.selected_range(),
            reversed: self.is_selection_reversed(),
        }
    }
    pub fn matches_native_text_revision(
        &self,
        revision: &NativeTextRevision,
        cx: &Context<Self>,
    ) -> bool {
        self.native_text_revision(cx) == *revision
    }
    /// Apply a source-checked native preview without recording history or
    /// emitting user `Change`/`InputEditsEvent`. Layout observers are notified.
    /// All event/history flags are restored before returning (including unwind).
    ///
    /// The owner must restore its original text with this API before one final
    /// ordinary edit, or before admitting a user edit/undo. This is not an IME
    /// composition API. Active IME, read-only/disabled fields, token metadata,
    /// multi-cursor and open history transactions are refused without changes.
    pub fn replace_without_undo(
        &mut self,
        revision: &NativeTextRevision,
        edit: TransientReplacement<'_>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<NativeTextRevision, TransientEditError> {
        let TransientReplacement {
            expected,
            range,
            replacement,
            selection_after,
            reversed,
        } = edit;
        if expected.len() > 16 * 1024 * 1024 || replacement.len() > 1024 * 1024 {
            return Err(TransientEditError::Bounds);
        }
        if self.text.len() != expected.len()
            || !self.matches_native_text_revision(revision, cx)
            || self.text.to_string() != expected
        {
            return Err(TransientEditError::Changed);
        }
        if !self.is_editable() {
            return Err(TransientEditError::NotEditable);
        }
        if self.ime_marked_range.is_some() || self.ime_original_text.is_some() {
            return Err(TransientEditError::Composition);
        }
        if self.replaying_history
            || !self.emit_events
            || self.undo_manager.is_ignoring()
            || !self.selections.is_single()
            || self.undo_manager.has_open_transaction()
            || !self.token_spans().is_empty()
            || self.pending_token.is_some()
        {
            return Err(TransientEditError::Unsupported);
        }
        if expected.len() > 16 * 1024 * 1024
            || replacement.len() > 1024 * 1024
            || range.start > range.end
            || range.end > expected.len()
        {
            return Err(TransientEditError::Bounds);
        }
        let boundary = |text: &str, offset: usize| {
            offset == text.len()
                || text
                    .grapheme_indices(true)
                    .any(|(index, _)| index == offset)
        };
        if !boundary(expected, range.start)
            || !boundary(expected, range.end)
            || self.normalize_input(replacement).as_ref() != replacement
        {
            return Err(TransientEditError::Bounds);
        }
        if expected.len() - range.len() + replacement.len() > 16 * 1024 * 1024 {
            return Err(TransientEditError::Bounds);
        }
        let mut result = expected.to_owned();
        result.replace_range(range.clone(), replacement);
        if selection_after.start > selection_after.end
            || selection_after.end > result.len()
            || !boundary(&result, selection_after.start)
            || !boundary(&result, selection_after.end)
        {
            return Err(TransientEditError::Bounds);
        }
        if !self.is_valid_input(&result, cx) {
            return Err(TransientEditError::Rejected);
        }
        let mut scope = TransientScope::new(self);
        scope.replace_text_in_ranges(&[(range, replacement.to_owned())], window, cx);
        scope.set_selected_range_with_direction(selection_after, reversed, cx);
        let receipt = scope.native_text_revision(cx);
        drop(scope);
        Ok(receipt)
    }
}

#[cfg(test)]
#[path = "native_preview_tests.rs"]
mod tests;
