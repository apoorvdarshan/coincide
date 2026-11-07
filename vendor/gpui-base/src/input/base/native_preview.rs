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
struct TransientScope<'a, M: InputModeKind> {
    state: &'a mut InputBaseState<M>,
    history: Option<UndoManager>,
    emit_events: bool,
    silent: bool,
    edits: Vec<(InputEdit, Rope)>,
}
impl<'a, M: InputModeKind> TransientScope<'a, M> {
    fn new(state: &'a mut InputBaseState<M>) -> Self {
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
impl<M: InputModeKind> Deref for TransientScope<'_, M> {
    type Target = InputBaseState<M>;
    fn deref(&self) -> &Self::Target {
        self.state
    }
}
impl<M: InputModeKind> DerefMut for TransientScope<'_, M> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.state
    }
}
impl<M: InputModeKind> Drop for TransientScope<'_, M> {
    fn drop(&mut self) {
        self.state.undo_manager = self.history.take().expect("Owned transient history");
        self.state.emit_events = self.emit_events;
        self.state.silent_replace_text = self.silent;
        self.state.last_input_edits = std::mem::take(&mut self.edits);
    }
}
pub(super) struct NativeTransient {
    original: Rope,
    original_selection: Range<usize>,
    original_reversed: bool,
    original_range: Range<usize>,
    expected: Rope,
    expected_revision: u64,
    expected_selection: Range<usize>,
    inserted: Range<usize>,
}
pub(in crate::input) struct RestoredSource {
    original: Range<usize>,
    inserted: Range<usize>,
    original_utf16: Range<usize>,
    inserted_utf16: Range<usize>,
    previous_selection_utf16: Range<usize>,
    original_selection_utf16: Range<usize>,
}
impl RestoredSource {
    fn offset(
        original: &Range<usize>,
        inserted: &Range<usize>,
        offset: usize,
        right: bool,
    ) -> usize {
        if offset < inserted.start {
            return offset;
        }
        if offset > inserted.end {
            return original.end.saturating_add(offset - inserted.end);
        }
        if offset == inserted.start && !right {
            return original.start;
        }
        if right || offset == inserted.end {
            original.end
        } else {
            original.start
        }
    }
    pub(in crate::input) fn map_range(&self, range: Range<usize>) -> Range<usize> {
        if range.is_empty() {
            let offset = Self::offset(&self.original, &self.inserted, range.start, true);
            return offset..offset;
        }
        Self::offset(&self.original, &self.inserted, range.start, false)
            ..Self::offset(&self.original, &self.inserted, range.end, true)
    }
    pub(in crate::input) fn map_utf16(&self, range: Range<usize>) -> Range<usize> {
        if range == self.previous_selection_utf16 {
            return self.original_selection_utf16.clone();
        }
        if range.is_empty() {
            let offset = Self::offset(
                &self.original_utf16,
                &self.inserted_utf16,
                range.start,
                true,
            );
            return offset..offset;
        }
        Self::offset(
            &self.original_utf16,
            &self.inserted_utf16,
            range.start,
            false,
        )..Self::offset(&self.original_utf16, &self.inserted_utf16, range.end, true)
    }
}
impl<M: InputModeKind> InputBaseState<M> {
    /// Internal pre-mutation hook. Only the textarea's native API can mint the
    /// snapshot. A changed source drops custody without overwriting new text.
    pub(in crate::input) fn restore_native_transient(
        &mut self,
        cx: &mut Context<Self>,
    ) -> Option<RestoredSource> {
        if self.undo_manager.is_ignoring() {
            return None;
        }
        let source = self.native_transient.take()?;
        if self.document_revision != source.expected_revision || self.text != source.expected {
            return None;
        }
        let utf16 = |text: &Rope, range: &Range<usize>| {
            text.offset_to_offset_utf16(range.start)..text.offset_to_offset_utf16(range.end)
        };
        let map = RestoredSource {
            original: source.original_range.clone(),
            inserted: source.inserted.clone(),
            original_utf16: utf16(&source.original, &source.original_range),
            inserted_utf16: utf16(&source.expected, &source.inserted),
            previous_selection_utf16: utf16(&source.expected, &source.expected_selection),
            original_selection_utf16: utf16(&source.original, &source.original_selection),
        };
        let selected = if self.selected_range() == source.expected_selection {
            source.original_selection.clone()
        } else {
            map.map_range(self.selected_range())
        };
        let reversed = if self.selected_range() == source.expected_selection {
            source.original_reversed
        } else {
            self.is_selection_reversed()
        };
        let old = self.text.clone();
        let mut scope = TransientScope::new(self);
        scope.text = source.original;
        scope.document_revision = scope.document_revision.wrapping_add(1);
        let restored = scope.text.clone();
        scope
            .display_map
            .on_text_changed(&restored, &(0..old.len()), &restored, cx);
        scope.update_search(cx);
        scope.set_selected_range_with_direction(selected, reversed, cx);
        scope.update_preferred_column();
        if scope.is_multi_line() {
            let state = &mut *scope;
            state.mode.update_auto_grow(&state.display_map);
        }
        cx.notify();
        drop(scope);
        Some(map)
    }
}
impl InputBaseState<TextareaMode> {
    /// Restore an owned native source before cancellation/final/user admission.
    /// A newer unrecognized document is never changed.
    pub fn restore_native_preview(&mut self, cx: &mut Context<Self>) -> bool {
        self.restore_native_transient(cx).is_some()
    }
    /// Read-only native metadata for retained render/context owners. No OS API
    /// or mutable edit is performed, and no revision value can be constructed.
    pub fn has_native_preview_revision(
        &self,
        receipt: &NativeTextRevision,
        owner: EntityId,
    ) -> bool {
        self.native_transient.is_some() && self.is_native_text_revision(receipt, owner)
    }
    pub fn is_native_text_revision(&self, receipt: &NativeTextRevision, owner: EntityId) -> bool {
        owner == self.native_owner
            && receipt.owner == self.native_owner
            && receipt.revision == self.document_revision
            && receipt.selection == self.selected_range()
            && receipt.reversed == self.is_selection_reversed()
    }
    pub fn has_native_preview(&self, receipt: &NativeTextRevision, cx: &Context<Self>) -> bool {
        self.native_owner == cx.entity_id()
            && self.has_native_preview_revision(receipt, cx.entity_id())
    }
    /// Fixed synthetic unwind probe for private TestPlatform fixtures only.
    /// No callback or source/authority constructor is exposed.
    #[cfg(feature = "native-edit-test-support")]
    #[doc(hidden)]
    pub fn native_transient_unwind_fixture(&mut self) -> bool {
        let emit = self.emit_events;
        let silent = self.silent_replace_text;
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let scope = TransientScope::new(self);
            assert!(scope.undo_manager.is_ignoring());
            assert!(!scope.state.emit_events);
            panic!("synthetic native transient unwind");
        }));
        result.is_err()
            && self.emit_events == emit
            && self.silent_replace_text == silent
            && !self.undo_manager.is_ignoring()
    }
    /// Native text/selection identity, bound to this actual entity. An edit away
    /// and back invalidates it even when the resulting string is identical.
    pub fn native_text_revision(&self, cx: &Context<Self>) -> NativeTextRevision {
        assert_eq!(
            self.native_owner,
            cx.entity_id(),
            "Native textarea belongs to another entity"
        );
        NativeTextRevision {
            owner: self.native_owner,
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
        self.native_owner == cx.entity_id()
            && self.is_native_text_revision(revision, cx.entity_id())
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
        if self.selecting
            || self.column_select_start.is_some()
            || self.replaying_history
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
        if self
            .native_transient
            .as_ref()
            .is_some_and(|source| source.inserted != range)
        {
            return Err(TransientEditError::Unsupported);
        }
        let original = self.native_transient.take().unwrap_or_else(|| {
            Box::new(NativeTransient {
                original: self.text.clone(),
                original_selection: self.selected_range(),
                original_reversed: self.is_selection_reversed(),
                original_range: range.clone(),
                expected: self.text.clone(),
                expected_revision: self.document_revision,
                expected_selection: self.selected_range(),
                inserted: range.clone(),
            })
        });
        let inserted = range.start..range.start + replacement.len();
        let mut scope = TransientScope::new(self);
        scope.replace_text_in_ranges(&[(range, replacement.to_owned())], window, cx);
        scope.set_selected_range_with_direction(selection_after, reversed, cx);
        let receipt = scope.native_text_revision(cx);
        drop(scope);
        if self.text != original.original {
            let mut original = original;
            original.expected = self.text.clone();
            original.expected_revision = self.document_revision;
            original.expected_selection = self.selected_range();
            original.inserted = inserted;
            self.native_transient = Some(original);
        }
        Ok(receipt)
    }
}

#[cfg(test)]
#[path = "native_preview_tests.rs"]
mod tests;
