//! Closed native dictation source owner. No document/control API constructor.
use super::*;
use gpui_base::input::{NativeTextRevision, TransientEditError, TransientReplacement};
use transcription_settings::{ComposerBinding, TextReady};
pub(super) struct Preview {
    binding: ComposerBinding,
    execution: Value,
    generation: u64,
    original: String,
    original_selection: std::ops::Range<usize>,
    original_reversed: bool,
    expected: String,
    range: std::ops::Range<usize>,
    receipt: NativeTextRevision,
    last_partial: Option<String>,
    fallback: bool,
    pub inline: bool,
}
pub(super) enum Applied {
    Updated,
    Unchanged,
    Fallback,
    Changed,
}
impl Preview {
    pub(super) fn capture(
        input: &Entity<TextareaState>,
        binding: ComposerBinding,
        generation: u64,
        cx: &mut App,
    ) -> Self {
        let (original, selection, reversed, receipt) = input.update(cx, |state, cx| {
            (
                state.value().to_string(),
                state.selected_range(),
                state.is_selection_reversed(),
                state.native_text_revision(cx),
            )
        });
        Self {
            range: selection.clone(),
            expected: original.clone(),
            original,
            original_selection: selection,
            original_reversed: reversed,
            receipt,
            binding,
            execution: Value::Null,
            generation,
            last_partial: None,
            fallback: false,
            inline: false,
        }
    }
    pub(super) fn matches_event(&self, event: &TextReady) -> bool {
        self.generation == event.generation && self.binding == event.binding
    }
    pub(super) fn current(&self, input: &Entity<TextareaState>, cx: &App) -> bool {
        let state = input.read(cx);
        state.is_native_text_revision(&self.receipt, input.entity_id())
            && state.value().as_ref() == self.expected
    }
    fn active(&self, input: &Entity<TextareaState>, cx: &App) -> bool {
        let state = input.read(cx);
        self.inline
            && state.has_native_preview_revision(&self.receipt, input.entity_id())
            && state.value().as_ref() == self.expected
    }
    pub(super) fn restore(
        &self,
        input: &Entity<TextareaState>,
        cx: &mut App,
    ) -> (bool, Option<NativeTextRevision>) {
        let current = self.current(input, cx);
        let receipt = input.update(cx, |state, cx| {
            state
                .restore_native_preview(cx)
                .then(|| state.native_text_revision(cx))
        });
        (current, receipt)
    }
    pub(super) fn apply(
        &mut self,
        input: &Entity<TextareaState>,
        partial: &str,
        window: &mut Window,
        cx: &mut App,
    ) -> Applied {
        if partial.len() > 1_048_576 || !self.current(input, cx) {
            return Applied::Changed;
        }
        if partial.trim().is_empty()
            || self.fallback
            || self.last_partial.as_deref() == Some(partial)
        {
            return Applied::Unchanged;
        }
        let mut next = self.original.clone();
        let proposed = coincide_core::dictation::DictationSession::start(
            &next,
            self.original_selection.clone(),
        )
        .and_then(|mut session| session.update(&mut next, partial));
        let Ok(caret) = proposed else {
            return Applied::Changed;
        };
        let replacement = next[self.original_selection.start..caret].to_owned();
        let result = input.update(cx, |state, cx| {
            state.replace_without_undo(
                &self.receipt,
                TransientReplacement {
                    expected: &self.expected,
                    range: self.range.clone(),
                    replacement: &replacement,
                    selection_after: caret..caret,
                    reversed: false,
                },
                window,
                cx,
            )
        });
        match result {
            Ok(receipt) => {
                self.receipt = receipt;
                self.expected = next;
                self.range = self.original_selection.start..caret;
                self.last_partial = Some(partial.to_owned());
                self.inline = true;
                Applied::Updated
            }
            Err(
                TransientEditError::Unsupported
                | TransientEditError::NotEditable
                | TransientEditError::Composition,
            ) => {
                self.fallback = true;
                Applied::Fallback
            }
            Err(_) => Applied::Changed,
        }
    }
}
impl Coincide {
    pub(super) fn capture_dictation_preview(
        &mut self,
        binding: ComposerBinding,
        generation: u64,
        cx: &mut Context<Self>,
    ) {
        let mut preview = Preview::capture(&self.composer, binding, generation, cx);
        preview.execution = self.dictation_execution_snapshot();
        self.voice.preview = Some(preview);
    }
    fn dictation_execution_snapshot(&self) -> Value {
        self.selected
            .as_ref()
            .map(|thread| execution_snapshot(thread, &self.projects))
            .unwrap_or(Value::Null)
    }
    fn dictation_execution_current(&self, preview: &Preview) -> bool {
        let Ok(owner) = try_state(&self.engine) else {
            return false;
        };
        if owner.admissions_frozen()
            || owner
                .store
                .is_imported(&preview.binding.thread_id)
                .unwrap_or(true)
        {
            return false;
        }
        let Ok(thread) = owner.store.thread(&preview.binding.thread_id) else {
            return false;
        };
        if !thread
            .get("draft")
            .is_none_or(|draft| draft.is_string() || draft.is_null())
            || text(&thread, "draft") != preview.original
        {
            return false;
        }
        let Ok(projects) = owner.store.projects() else {
            return false;
        };
        projects
            .as_array()
            .is_some_and(|projects| execution_snapshot(&thread, projects) == preview.execution)
    }
    fn dictation_preview_context_current(&self, preview: &Preview, cx: &App) -> bool {
        preview.execution == self.dictation_execution_snapshot()
            && self.chat_visible()
            && !self.settings_open
            && !self.media.shutdown_requested
            && !self.media.close_requested
            && !self.command_palette.read(cx).is_open()
            && self
                .selected
                .as_ref()
                .is_some_and(|thread| text(thread, "id") == preview.binding.thread_id)
            && self.voice.ticket.as_ref().is_some_and(|ticket| {
                ticket.producer_matches(
                    preview.generation,
                    &preview.binding,
                    self.settings.get("voice").unwrap_or(&Value::Null),
                )
            })
    }
    /// Only a real native revision may explain a layout-only notification.
    /// A normal user mutation restores/clears the widget snapshot first.
    pub(super) fn owns_dictation_preview_notification(&mut self, cx: &mut Context<Self>) -> bool {
        if let Some(preview) = &self.voice.preview
            && self.dictation_preview_context_current(preview, cx)
            && preview.active(&self.composer, cx)
        {
            return true;
        }
        if let Some(receipt) = self.voice.restored_preview.take() {
            return self.composer.update(cx, |state, cx| {
                state.matches_native_text_revision(&receipt, cx)
            });
        }
        false
    }
    pub(super) fn dictation_original_source(
        &self,
        cx: &App,
    ) -> Option<(String, std::ops::Range<usize>, bool)> {
        let preview = self.voice.preview.as_ref()?;
        // Data projection is distinct from admission: even a just-revoked
        // producer's recognized transient text must not become a draft/send.
        (self
            .selected
            .as_ref()
            .is_some_and(|thread| text(thread, "id") == preview.binding.thread_id)
            && preview.active(&self.composer, cx))
        .then(|| {
            (
                preview.original.clone(),
                preview.original_selection.clone(),
                preview.original_reversed,
            )
        })
    }
    pub(super) fn committed_composer_draft(&self, cx: &App) -> String {
        self.dictation_original_source(cx)
            .map(|source| source.0)
            .unwrap_or_else(|| self.composer.read(cx).value().to_string())
    }
    pub(super) fn committed_composer_source(
        &self,
        cx: &App,
    ) -> (String, std::ops::Range<usize>, bool) {
        self.dictation_original_source(cx).unwrap_or_else(|| {
            let input = self.composer.read(cx);
            (
                input.value().to_string(),
                input.selected_range(),
                input.is_selection_reversed(),
            )
        })
    }
    fn restore_owned_dictation_preview(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(preview) = self.voice.preview.take() else {
            return true;
        };
        let current = preview.current(&self.composer, cx)
            && self
                .selected
                .as_ref()
                .is_some_and(|thread| text(thread, "id") == preview.binding.thread_id);
        let (_, receipt) = preview.restore(&self.composer, cx);
        if let Some(receipt) = receipt {
            self.voice.restored_preview = Some(receipt);
        }
        current
    }
    pub(super) fn cancel_composer_dictation(&mut self, cx: &mut Context<Self>) {
        self.restore_owned_dictation_preview(cx);
        self.voice.ticket = None;
        self.voice.recording_ended();
        self.microphone_panel
            .update(cx, |panel, cx| panel.cancel(cx));
    }
    /// A stale/cancelled producer never lends a final event its native source.
    pub(super) fn prepare_dictation_final_source(
        &mut self,
        from_microphone: bool,
        event: &TextReady,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(preview) = self.voice.preview.as_ref() else {
            return true;
        };
        if !from_microphone {
            self.cancel_composer_dictation(cx);
            return true;
        }
        let admitted = preview.matches_event(event)
            && self.dictation_preview_context_current(preview, cx)
            && self.dictation_execution_current(preview);
        let current = self.restore_owned_dictation_preview(cx);
        if !admitted || !current {
            self.voice.ticket = None;
            self.microphone_panel
                .update(cx, |panel, cx| panel.cancel(cx));
            return false;
        }
        true
    }
    pub(super) fn close_dictation_preview(&mut self, cx: &mut Context<Self>) {
        self.restore_owned_dictation_preview(cx);
    }
    pub(super) fn poll_dictation_preview(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(preview) = self.voice.preview.as_ref() else {
            return;
        };
        let current = self.dictation_preview_context_current(preview, cx)
            && self.dictation_execution_current(preview)
            && self.microphone_panel.read(cx).intent_generation() == Some(preview.generation)
            && preview.current(&self.composer, cx);
        if !current {
            self.cancel_composer_dictation(cx);
            return;
        }
        let Some(partial) = self
            .microphone_panel
            .read(cx)
            .partial_preview()
            .map(str::to_owned)
        else {
            return;
        };
        let Some(mut preview) = self.voice.preview.take() else {
            return;
        };
        match preview.apply(&self.composer, &partial, window, cx) {
            Applied::Updated => {
                self.voice.preview = Some(preview);
                cx.notify();
            }
            Applied::Unchanged => self.voice.preview = Some(preview),
            Applied::Fallback => {
                self.voice.preview = Some(preview);
                self.status="Live insertion is unavailable while this field has tokens, composition or editing restrictions. Dictation remains in the preview until its final source check.".into();
                cx.notify();
            }
            Applied::Changed => {
                self.voice.preview = Some(preview);
                self.cancel_composer_dictation(cx);
                self.status = "Dictation source changed; its partial text was discarded.".into();
                cx.notify();
            }
        }
    }
}

fn execution_snapshot(thread: &Value, projects: &[Value]) -> Value {
    let mut snapshot = serde_json::Map::new();
    for key in [
        "id",
        "selection",
        "accessMode",
        "interactionMode",
        "projectID",
        "worktreePath",
        "draftContext",
        "rustDraftImages",
    ] {
        snapshot.insert(key.into(), thread[key].clone());
        snapshot.insert(
            format!("{key}:present"),
            Value::Bool(thread.get(key).is_some()),
        );
    }
    let project = projects
        .iter()
        .find(|project| project["id"] == thread["projectID"]);
    snapshot.insert(
        "projectDirectory".into(),
        project
            .map(|project| project["path"].clone())
            .unwrap_or(Value::Null),
    );
    Value::Object(snapshot)
}

#[cfg(test)]
mod tests {
    use super::execution_snapshot;
    use serde_json::json;
    #[::core::prelude::v1::test]
    fn voice_execution_source_tracks_provider_account_policy_directory_and_context_not_background_time()
     {
        let original = json!({"id":"one","selection":{"provider":"codex","model":"native-proof-model","cliProfileID":"private-profile"},"projectID":"project","accessMode":"read-only","interactionMode":"build","draftContext":[{"future":"preserve"}],"items":[{"text":"synthetic history"}],"updatedAt":"old"});
        let projects = vec![json!({"id":"project","path":"/synthetic/project"})];
        let stamp = execution_snapshot(&original, &projects);
        let mut background = original.clone();
        background["updatedAt"] = json!("new");
        background["title"] = json!("renamed");
        background["items"] = json!([{"text":"new synthetic output"}]);
        assert_eq!(execution_snapshot(&background, &projects), stamp);
        for key in [
            "selection",
            "accessMode",
            "interactionMode",
            "worktreePath",
            "draftContext",
            "rustDraftImages",
        ] {
            let mut changed = original.clone();
            changed[key] = json!("changed");
            assert_ne!(execution_snapshot(&changed, &projects), stamp);
        }
        let mut directory = projects.clone();
        directory[0]["path"] = json!("/synthetic/other");
        assert_ne!(execution_snapshot(&original, &directory), stamp);
        let mut absent = original.clone();
        absent.as_object_mut().unwrap().remove("draftContext");
        let mut null = absent.clone();
        null["draftContext"] = serde_json::Value::Null;
        assert_ne!(
            execution_snapshot(&absent, &projects),
            execution_snapshot(&null, &projects)
        );
        assert_eq!(original["draftContext"], json!([{"future":"preserve"}]));
    }
}
