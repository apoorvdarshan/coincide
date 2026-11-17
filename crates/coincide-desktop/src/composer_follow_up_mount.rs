//! Native composer choices and owner-bound delivery tickets. Nothing here is a
//! command/RPC route; only the visible editor's actions create a delivery.
use super::*;
use coincide_core::{
    api::{NativeFollowUpStatus, NativeFollowUpTicket},
    composer_follow_up::{self as choice, Behavior, Dispatch},
};
/// A follow-up is bound to composer metadata, not the entire transcript.
#[cfg(test)]
fn follow_up_source(thread: &Value) -> Value {
    let mut source = serde_json::Map::new();
    for key in [
        "id",
        "draft",
        "selection",
        "accessMode",
        "interactionMode",
        "projectID",
        "projectPath",
        "worktreePath",
        "botID",
        "rustBotContext",
        "rustDraftImages",
        "draftContext",
        "followUpBehavior",
    ] {
        if let Some(value) = thread.get(key) {
            source.insert(key.into(), value.clone());
        }
    }
    Value::Object(source)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SelectionWait {
    None,
    Waiting,
    Failed,
}
pub(super) struct PendingDelivery {
    ticket: Option<NativeFollowUpTicket>,
    thread: String,
}
/// Retain a local queue row until its saved row or accepted transcript is visible.
pub(super) struct AdmittedPreview {
    pub pending: PendingSend,
    pub queue_id: String,
}
fn preview_handed_off(preview: &AdmittedPreview, thread: &Value, visible_queue: &[Value]) -> bool {
    if text(thread, "id") != preview.pending.thread {
        return false;
    }
    let visible = visible_queue
        .iter()
        .find(|row| row["id"] == preview.queue_id);
    if visible.is_some_and(|row| row["state"] != "completed") {
        return true;
    }
    let completed = thread["rustMessageQueue"].as_array().is_some_and(|rows| {
        rows.iter()
            .any(|row| row["id"] == preview.queue_id && row["state"] == "completed")
    });
    if !completed {
        return false;
    }
    thread["items"].as_array().is_some_and(|items| {
        items
            .iter()
            .filter(|item| {
                item["kind"] == "user"
                    && item["bufferedSend"] != true
                    && item["pendingSend"] != true
            })
            .skip(preview.pending.baseline_user_messages)
            .any(|item| {
                if item["rustAwaitingQueueDelivery"] == true {
                    return false;
                }
                if let Some(id) = item["rustQueueMessageID"].as_str() {
                    return id == preview.queue_id;
                }
                let captured = &preview.pending.captured;
                let same_context = item["context"] == captured["draftContext"]
                    || (!coincide_core::composer_context::has_context(&item["context"])
                        && !coincide_core::composer_context::has_context(
                            &captured["draftContext"],
                        ));
                let images = item["rustImages"]
                    .as_array()
                    .map(Vec::as_slice)
                    .unwrap_or(&[]);
                let captured_images = captured["rustDraftImages"]
                    .as_array()
                    .map(Vec::as_slice)
                    .unwrap_or(&[]);
                item["text"].as_str() == Some(preview.pending.draft.as_str())
                    && same_context
                    && images == captured_images
            })
    })
}
/// A send waiting for a local prerequisite, bound to the original settings.
#[derive(Clone)]
pub(super) struct PendingSend {
    pub thread: String,
    pub draft: String,
    pub alternate: bool,
    pub behavior: Behavior,
    pub selection: Value,
    pub waiting_for_import: bool,
    pub selection_wait: SelectionWait,
    pub wait_for_stopped_turn: bool,
    pub import_jobs: Vec<u64>,
    pub import_failed: bool,
    pub edited: bool,
    pub captured: Value,
    pub last_error: Option<String>,
    /// The first deferred message may still be visible until another Send.
    pub original_visible: bool,
    /// Local-only row shown until this buffered message reaches the queue.
    pub buffer_id: Option<String>,
    /// Number of actual user messages visible when this send was captured.
    pub baseline_user_messages: usize,
    /// Keeps this submission's previews hidden while it is being saved.
    pub image_send: Option<u64>,
    admission: Option<Arc<CapturedAdmission>>,
}
#[derive(Default)]
struct CapturedAdmission {
    /// 0 waits for the Engine, 1 owns admission, and 2 was recalled.
    state: std::sync::atomic::AtomicU8,
    result: Mutex<Option<Result<coincide_core::api::CapturedNativeSend>>>,
}
impl CapturedAdmission {
    fn claim(&self, next: u8) -> bool {
        use std::sync::atomic::Ordering;
        self.state
            .compare_exchange(0, next, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }
}

impl PendingSend {
    pub fn new(thread: &Value, draft: String, alternate: bool) -> Self {
        let mut captured = pending_scope(thread, false);
        captured["id"] = thread["id"].clone();
        captured["draft"] = json!(draft);
        captured["rustDraftImages"] = thread["rustDraftImages"].clone();
        Self {
            thread: text(thread, "id"),
            draft,
            alternate,
            behavior: choice::selected(thread, &Value::Null),
            selection: pending_scope(thread, false),
            waiting_for_import: false,
            selection_wait: SelectionWait::None,
            wait_for_stopped_turn: false,
            import_jobs: Vec::new(),
            import_failed: false,
            edited: false,
            captured,
            last_error: None,
            original_visible: true,
            buffer_id: None,
            baseline_user_messages: thread["items"].as_array().map_or(0, |items| {
                items
                    .iter()
                    .filter(|item| {
                        item["kind"] == "user"
                            && item["bufferedSend"] != true
                            && item["pendingSend"] != true
                    })
                    .count()
            }),
            image_send: None,
            admission: None,
        }
    }
    pub(super) fn can_recall(&self) -> bool {
        self.admission
            .as_ref()
            .is_none_or(|slot| slot.state.load(std::sync::atomic::Ordering::Acquire) == 0)
    }
    pub(super) fn recall(&self) -> bool {
        self.admission.as_ref().is_none_or(|slot| slot.claim(2))
    }
    pub fn with_behavior(mut self, behavior: Behavior) -> Self {
        self.behavior = behavior;
        self
    }
    /// Adopt only the acknowledged execution choice; the submitted text,
    /// attachments, references and workspace remain the captured snapshot.
    pub fn finish_selection(&mut self, thread: Option<&Value>) {
        if self.selection_wait != SelectionWait::Waiting {
            return;
        }
        let Some(thread) = thread.filter(|thread| text(thread, "id") == self.thread) else {
            self.selection_wait = SelectionWait::Failed;
            return;
        };
        for key in ["selection", "accessMode", "interactionMode"] {
            self.selection[key] = thread[key].clone();
            self.captured[key] = thread[key].clone();
        }
        self.selection_wait = SelectionWait::None;
    }
    pub fn add_imports(&mut self, jobs: Vec<u64>) {
        self.import_jobs.extend(jobs);
        self.waiting_for_import = !self.import_jobs.is_empty();
    }
    #[cfg(test)]
    pub fn complete_import(&mut self, job: u64, imported: &[Value], failed: bool) -> bool {
        self.complete_attachment_import(job, imported, &[], failed)
    }
    pub fn complete_attachment_import(
        &mut self,
        job: u64,
        imported: &[Value],
        references: &[Value],
        failed: bool,
    ) -> bool {
        let Some(index) = self.import_jobs.iter().position(|owned| *owned == job) else {
            return false;
        };
        self.import_jobs.remove(index);
        let mut images = self.captured["rustDraftImages"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        for image in imported {
            if !images.contains(image) {
                images.push(image.clone());
            }
        }
        self.captured["rustDraftImages"] = json!(images);
        self.selection["images"] = self.captured["rustDraftImages"].clone();
        if !references.is_empty() {
            let mut context = self.captured["draftContext"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            for reference in references {
                if !context.iter().any(|row| row["id"] == reference["id"]) {
                    context.push(reference.clone());
                }
            }
            self.captured["draftContext"] = json!(context);
            self.selection["draftContext"] = self.captured["draftContext"].clone();
        }
        self.import_failed |= failed;
        self.waiting_for_import = !self.import_jobs.is_empty();
        true
    }
    #[cfg(test)]
    pub fn during_import(thread: &Value, draft: String, alternate: bool) -> Self {
        let mut pending = Self::new(thread, draft, alternate);
        pending.selection = pending_scope(thread, true);
        pending.waiting_for_import = true;
        pending
    }
    pub fn matches(&self, thread: &Value, draft: &str) -> bool {
        self.thread == text(thread, "id")
            && self.draft == draft
            && self.selection == pending_scope(thread, self.waiting_for_import)
    }
}

/// If the previous submission is still visible, retain only newly appended
/// text as the next message. A deliberately retyped identical message remains
/// a separate send. An unchanged second click is the same pending intent.
pub(super) fn buffered_text(first: &PendingSend, thread: &str, current: &str) -> Option<String> {
    if first.thread != thread || !first.original_visible {
        return Some(current.to_owned());
    }
    if !first.edited && current == first.draft {
        return None;
    }
    if first.edited
        && !first.draft.is_empty()
        && let Some(tail) = current.strip_prefix(&first.draft)
        && !tail.trim().is_empty()
    {
        return Some(tail.to_owned());
    }
    Some(current.to_owned())
}

/// Earlier submissions own their images and references; do not attach them a
/// second time merely because their previews are still awaiting admission.
pub(super) fn separate_buffered_payload(next: &mut PendingSend, earlier: &[PendingSend]) {
    let images = next.captured["rustDraftImages"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let contexts = next.captured["draftContext"].as_array().cloned();
    let prior = earlier
        .iter()
        .filter(|entry| entry.thread == next.thread)
        .collect::<Vec<_>>();
    let images: Vec<Value> = images
        .into_iter()
        .filter(|image| {
            !prior.iter().any(|entry| {
                entry.captured["rustDraftImages"]
                    .as_array()
                    .is_some_and(|rows| rows.contains(image))
            })
        })
        .collect();
    next.captured["rustDraftImages"] = json!(images);
    next.selection["images"] = next.captured["rustDraftImages"].clone();
    if let Some(contexts) = contexts {
        let remaining: Vec<Value> = contexts
            .into_iter()
            .filter(|context| {
                !prior.iter().any(|entry| {
                    entry.captured["draftContext"]
                        .as_array()
                        .is_some_and(|rows| rows.contains(context))
                })
            })
            .collect();
        next.captured["draftContext"] = json!(remaining);
        next.selection["draftContext"] = next.captured["draftContext"].clone();
    }
}
fn pending_scope(thread: &Value, ignore_images: bool) -> Value {
    let mut scope = json!({"selection":thread["selection"],"accessMode":thread["accessMode"],
        "interactionMode":thread["interactionMode"],"projectID":thread["projectID"],
        "projectPath":thread["projectPath"],"worktreePath":thread["worktreePath"],
        "draftContext":thread["draftContext"],"followUpBehavior":thread["followUpBehavior"],
        "botID":thread["botID"],"rustBotContext":thread["rustBotContext"]});
    if !ignore_images {
        scope["images"] = thread["rustDraftImages"].clone();
    }
    scope
}
#[derive(Clone, Default, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_follow_up, no_json, no_register)]
struct ModifiedSend;
#[derive(Clone, Default, PartialEq, gpui_kit::Action)]
#[action(namespace = coincide_follow_up, no_json, no_register)]
struct ShiftModifiedSend;
pub(super) fn init(cx: &mut App) {
    let (send, alternate) = if cfg!(target_os = "macos") {
        ("cmd-enter", "cmd-shift-enter")
    } else {
        ("ctrl-enter", "ctrl-shift-enter")
    };
    cx.bind_keys([
        KeyBinding::new(send, ModifiedSend, Some("CoincideFileSuggestions > Input")),
        KeyBinding::new(
            alternate,
            ShiftModifiedSend,
            Some("CoincideFileSuggestions > Input"),
        ),
    ]);
}
impl Coincide {
    /// A captured send may require reading a very long transcript and writing
    /// the queue. Keep that work off the window thread and submit it once.
    pub(super) fn poll_captured_admission(
        &mut self,
        pending: &mut PendingSend,
        clear_original: bool,
        cx: &mut Context<Self>,
    ) -> Option<Result<coincide_core::api::CapturedNativeSend>> {
        if let Some(slot) = &pending.admission {
            let result = slot.result.lock().ok()?.take();
            if result.is_some() {
                pending.admission = None;
            }
            return result;
        }
        let slot = Arc::new(CapturedAdmission::default());
        let worker_slot = slot.clone();
        pending.admission = Some(slot.clone());
        let engine = self.engine.clone();
        let captured = pending.captured.clone();
        let behavior = pending.behavior;
        let alternate = pending.alternate;
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let mut engine = engine
                        .lock()
                        .map_err(|_| anyhow::anyhow!("App engine is unavailable"))?;
                    if !worker_slot.claim(1) {
                        return Ok(coincide_core::api::CapturedNativeSend::Waiting);
                    }
                    engine.admit_captured_native_send(
                        &captured,
                        clear_original,
                        behavior,
                        alternate,
                    )
                })
                .await;
            if let Ok(mut value) = slot.result.lock() {
                *value = Some(result);
            }
            let _ = this.update(cx, |_, cx| cx.notify());
        })
        .detach();
        None
    }
    pub(super) fn has_buffered_selection_send(&self, thread_id: &str) -> bool {
        self.pending_follow_up
            .iter()
            .chain(self.pending_follow_up_backlog.iter())
            .any(|pending| {
                pending.thread == thread_id
                    && pending.buffer_id.is_some()
                    && pending.selection_wait == SelectionWait::Waiting
            })
    }
    pub(super) fn cancel_pending_selection_waits(&mut self) {
        for pending in self
            .pending_follow_up
            .iter_mut()
            .chain(self.pending_follow_up_backlog.iter_mut())
        {
            pending.finish_selection(None);
        }
    }
    pub(super) fn finish_pending_selection(&mut self, thread_id: &str, success: bool) {
        if !self
            .pending_follow_up
            .iter()
            .chain(self.pending_follow_up_backlog.iter())
            .any(|pending| {
                pending.thread == thread_id && pending.selection_wait == SelectionWait::Waiting
            })
        {
            return;
        }
        let selected = self
            .selected
            .as_ref()
            .filter(|thread| text(thread, "id") == thread_id && success)
            .map(|thread| {
                json!({"id":thread["id"],"selection":thread["selection"],
                "accessMode":thread["accessMode"],"interactionMode":thread["interactionMode"]})
            });
        for pending in self
            .pending_follow_up
            .iter_mut()
            .chain(self.pending_follow_up_backlog.iter_mut())
            .filter(|pending| pending.thread == thread_id)
        {
            pending.finish_selection(selected.as_ref());
        }
    }
    pub(super) fn captured_follow_up_behavior(&self, thread: &Value) -> Behavior {
        self.pending_follow_up_choice
            .as_ref()
            .filter(|(id, _)| *id == text(thread, "id"))
            .map(|(_, behavior)| *behavior)
            .unwrap_or_else(|| choice::selected(thread, &self.settings))
    }
    /// The previous send can still own stored images while awaiting its ACK.
    pub(super) fn exclude_submitted_images(&self, pending: &mut PendingSend) {
        let images = pending.captured["rustDraftImages"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let visible = self.pending_images.visible(&pending.thread, &images);
        if visible != images {
            pending.captured["rustDraftImages"] = json!(visible);
            if !pending.waiting_for_import {
                pending.selection["images"] = pending.captured["rustDraftImages"].clone();
            }
        }
    }
    pub(super) fn buffer_composer_send(
        &mut self,
        alternate: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.record_composer_draft(cx);
        if self.pending_follow_up_backlog.len() >= 32 {
            self.show_local_error("The message queue is full. Your draft is still here.");
            cx.notify();
            return;
        }
        let Some(thread) = self.selected.as_ref() else {
            return;
        };
        let id = text(thread, "id");
        let visible = self.composer.read(cx).value().to_string();
        let previous = self
            .pending_follow_up
            .as_ref()
            .filter(|entry| entry.thread == id)
            .or_else(|| {
                self.pending_follow_up_backlog
                    .iter()
                    .find(|entry| entry.thread == id)
            });
        let draft = previous
            .map(|entry| buffered_text(entry, &id, &visible))
            .unwrap_or_else(|| Some(visible.clone()))
            .unwrap_or_default();
        let mut next = PendingSend::new(thread, draft, alternate)
            .with_behavior(self.captured_follow_up_behavior(thread));
        if (!self.running.contains(&id) && self.selection_change_pending())
            || self.pending_follow_up.as_ref().is_some_and(|pending| {
                pending.thread == id && pending.selection_wait == SelectionWait::Waiting
            })
        {
            next.selection_wait = SelectionWait::Waiting;
        }
        self.exclude_submitted_images(&mut next);
        let earlier = self
            .pending_follow_up
            .iter()
            .chain(self.pending_follow_up_backlog.iter())
            .cloned()
            .collect::<Vec<_>>();
        separate_buffered_payload(&mut next, &earlier);
        if let Err(error) =
            coincide_core::composer_context::validate(&next.captured["draftContext"])
        {
            self.show_local_error(&format!("Message not queued: {error}"));
            cx.notify();
            return;
        }
        next.add_imports(self.attachment_imports.claim(&id));
        if next.draft.trim().is_empty()
            && !coincide_core::composer_context::has_context(&next.captured["draftContext"])
            && next.captured["rustDraftImages"]
                .as_array()
                .is_none_or(Vec::is_empty)
            && !next.waiting_for_import
        {
            return;
        }
        next.original_visible = false;
        next.edited = true; // The visible composer is now a different draft.
        let queue_id = uuid::Uuid::new_v4().to_string();
        next.captured["nativeQueueID"] = json!(queue_id);
        next.buffer_id = Some(queue_id);
        let images = next.captured["rustDraftImages"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        if !images.is_empty() {
            self.pending_seq = self.pending_seq.wrapping_add(1);
            self.pending_images.begin(self.pending_seq, &id, images);
            next.image_send = Some(self.pending_seq);
        }
        if let Some(first) = self
            .pending_follow_up
            .as_mut()
            .filter(|entry| entry.thread == id)
        {
            first.original_visible = false;
        }
        self.pending_follow_up_backlog.push_back(next);
        self.buffered_send_lease.set_dirty(true);
        self.draft_saver.invalidate();
        if let Some(thread) = self.selected.as_mut() {
            thread["draft"] = json!("");
        }
        self.pending_drafts.insert(
            id,
            PendingDraft {
                text: String::new(),
                retry: true,
                failed: false,
            },
        );
        self.composer
            .update(cx, |input, cx| input.set_value("", window, cx));
        self.reconcile_buffered_sends();
        self.status = "Preparing your message.".into();
        cx.notify();
    }

    pub(super) fn reconcile_buffered_sends(&mut self) {
        let finished = self
            .selected
            .as_ref()
            .map(|thread| {
                self.admitted_previews
                    .iter()
                    .enumerate()
                    .filter_map(|(index, preview)| {
                        preview_handed_off(preview, thread, &self.queued_messages).then_some(index)
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        for index in finished.into_iter().rev() {
            self.admitted_previews.remove(index);
        }
    }

    pub(super) fn track_queued_delivery(&mut self, ticket: NativeFollowUpTicket, thread: String) {
        self.follow_up_deliveries.push(PendingDelivery {
            ticket: Some(ticket),
            thread,
        });
    }

    pub(super) fn follow_up_key_scope(&self, scope: Div, cx: &mut Context<Self>) -> Div {
        scope
            .capture_action(cx.listener(|this, _: &ModifiedSend, window, cx| {
                if !this.composer_send_visible() {
                    return;
                }
                let alternate = this.settings["sendOnReturn"].as_bool().unwrap_or(true);
                this.send_selected(alternate, window, cx);
                window.prevent_default();
                cx.stop_propagation();
            }))
            .capture_action(cx.listener(|this, _: &ShiftModifiedSend, window, cx| {
                if !this.composer_send_visible() {
                    return;
                }
                if !this.settings["sendOnReturn"].as_bool().unwrap_or(true) {
                    this.send_selected(true, window, cx);
                } else if !this.send_next_queued_now(cx) {
                    return;
                }
                window.prevent_default();
                cx.stop_propagation();
            }))
    }
    fn composer_send_visible(&self) -> bool {
        self.chat_visible()
    }
    pub(super) fn follow_up_button(&self, compact: bool, cx: &mut Context<Self>) -> AnyElement {
        let Some(thread) = self.selected.as_ref() else {
            return div().into_any_element();
        };
        let behavior = choice::effective(
            choice::selected(thread, &self.settings),
            matches!(
                thread["selection"]["provider"].as_str(),
                Some("codex" | "opencode" | "lithos" | "claude")
            ),
        );
        Button::new("selection-follow-up-disclosure")
            .flex_shrink_0()
            .when(!compact, |button| button.label(behavior.label()))
            .when(compact, |button| button.w(px(28.)).p_0())
            .icon(behavior_icon(behavior))
            .dropdown_caret(!compact)
            .accessibility_label(format!("While the agent works: {}", behavior.label()))
            .tooltip("Choose what Send does while the agent works")
            .ghost()
            .compact()
            .h(px(28.))
            .rounded(px(8.))
            .on_click(cx.listener(|this, event: &gpui_kit::ClickEvent, _, cx| {
                this.follow_up_picker = !this.follow_up_picker;
                this.follow_up_anchor = Some(event.position());
                if this.follow_up_picker {
                    this.selection_ui.expanded = false;
                }
                cx.notify();
            }))
            .into_any_element()
    }
    /// Swift's follow-up menu: a small popover above the chip with Queue,
    /// Steer and Interrupt and what each does.
    pub(super) fn follow_up_menu(&self, cx: &mut Context<Self>) -> AnyElement {
        let Some(thread) = self.selected.as_ref() else {
            return div().into_any_element();
        };
        let chosen = choice::selected(thread, &self.settings);
        let mut menu = div().flex().flex_col().gap_1().p_2();
        for behavior in [Behavior::Queue, Behavior::Steer, Behavior::Interrupt] {
            let unsupported = behavior == Behavior::Steer
                && !matches!(
                    thread["selection"]["provider"].as_str(),
                    Some("codex" | "opencode" | "lithos" | "claude")
                );
            menu = menu.child(self.picker_menu_row(
                format!("follow-up-{}", behavior.key()),
                behavior.label().into(),
                Some(behavior_help(behavior).into()),
                Some(behavior_icon(behavior)),
                chosen == behavior,
                unsupported,
                move |this, _, cx| {
                    this.choose_follow_up(behavior, cx);
                    this.follow_up_picker = false;
                    cx.notify();
                },
                cx,
            ));
        }
        menu.into_any_element()
    }
    pub(super) fn follow_up_pane(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        if !self.follow_up_picker {
            return None;
        }
        let thread = self.selected.as_ref()?;
        let chosen = choice::selected(thread, &self.settings);
        let mut pane = div()
            .flex()
            .flex_col()
            .gap_1()
            .child("While the agent works");
        for behavior in [Behavior::Steer, Behavior::Queue, Behavior::Interrupt] {
            let unsupported = behavior == Behavior::Steer
                && !matches!(
                    thread["selection"]["provider"].as_str(),
                    Some("codex" | "opencode" | "lithos" | "claude")
                );
            pane = pane.child(
                Button::new(SharedString::from(format!("follow-up-{}", behavior.key())))
                    .label(behavior.label())
                    .icon(behavior_icon(behavior))
                    .selected(chosen == behavior)
                    .disabled(unsupported)
                    .tooltip(if unsupported {
                        "This provider does not support native steering yet"
                    } else {
                        behavior_help(behavior)
                    })
                    .on_click(
                        cx.listener(move |this, _, _, cx| this.choose_follow_up(behavior, cx)),
                    ),
            );
        }
        Some(pane.into_any_element())
    }
    pub(super) fn choose_follow_up(&mut self, behavior: Behavior, cx: &mut Context<Self>) {
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return;
        };
        if let Some(thread) = self.selected.as_mut() {
            thread["followUpBehavior"] = json!(behavior.key());
        }
        self.follow_up_picker = false;
        self.pending_follow_up_choice = Some((id, behavior));
        self.start_follow_up_choice(cx);
        cx.notify();
    }

    fn start_follow_up_choice(&mut self, cx: &mut Context<Self>) {
        if self.follow_up_choice_inflight {
            return;
        }
        let Some((id, behavior)) = self.pending_follow_up_choice.clone() else {
            return;
        };
        let Some(selection) = self
            .selected
            .as_ref()
            .filter(|thread| text(thread, "id") == id)
            .map(|thread| thread["selection"].clone())
        else {
            self.pending_follow_up_choice = None;
            return;
        };
        self.follow_up_choice_inflight = true;
        self.buffered_send_lease.set_dirty(true);
        let engine = self.engine.clone();
        let worker_id = id.clone();
        let worker_selection = selection.clone();
        cx.spawn(async move |this, cx| {
            let result: Result<(Option<Value>, Result<Value>)> = cx
                .background_executor()
                .spawn(async move {
                    let mut engine = engine
                        .lock()
                        .map_err(|_| anyhow::anyhow!("Conversation state is unavailable"))?;
                    let current = engine.store.thread(&worker_id)?;
                    let previous = current.get("followUpBehavior").cloned();
                    let saved = (|| -> Result<Value> {
                        anyhow::ensure!(
                            current["selection"] == worker_selection,
                            "Conversation selection changed; choose follow-up behavior again"
                        );
                        engine.choose_native_follow_up(&current, behavior)?;
                        Ok(engine
                            .store
                            .document("settings.json")?
                            .unwrap_or_else(|| json!({})))
                    })();
                    Ok((previous, saved))
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.follow_up_choice_inflight = false;
                if this.pending_follow_up_choice != Some((id.clone(), behavior)) {
                    this.start_follow_up_choice(cx);
                    return;
                }
                this.pending_follow_up_choice = None;
                match result {
                    Ok((_, Ok(settings))) => {
                        if let Some(target) = this.settings.as_object_mut() {
                            for key in ["followUpBehavior", "existingThreadsFollowUpBehavior"] {
                                if let Some(value) = settings.get(key) {
                                    target.insert(key.into(), value.clone());
                                }
                            }
                        }
                    }
                    Ok((previous, Err(error))) => {
                        if let Some(thread) = this
                            .selected
                            .as_mut()
                            .filter(|thread| {
                                text(thread, "id") == id
                                    && thread["selection"] == selection
                                    && thread["followUpBehavior"] == behavior.key()
                            })
                            .and_then(Value::as_object_mut)
                        {
                            match previous {
                                Some(value) => {
                                    thread.insert("followUpBehavior".into(), value);
                                }
                                None => {
                                    thread.remove("followUpBehavior");
                                }
                            }
                        }
                        if this
                            .selected
                            .as_ref()
                            .is_some_and(|thread| text(thread, "id") == id)
                        {
                            this.show_local_error(&format!("Follow-up choice not saved: {error}"));
                        }
                        this.status = error.to_string();
                    }
                    Err(error) => {
                        if this
                            .selected
                            .as_ref()
                            .is_some_and(|thread| text(thread, "id") == id)
                        {
                            this.show_local_error(&format!("Follow-up choice not saved: {error}"));
                        }
                        this.status = error.to_string();
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
    pub(super) fn poll_composer_follow_ups(&mut self, cx: &mut Context<Self>) {
        let mut retained = Vec::new();
        for mut delivery in std::mem::take(&mut self.follow_up_deliveries) {
            let result = match self.engine.try_lock() {
                Err(_) => None,
                Ok(mut engine) => match engine
                    .native_follow_up_status(delivery.ticket.as_ref().expect("owned native ticket"))
                {
                    Ok(NativeFollowUpStatus::Pending) => Some(NativeFollowUpStatus::Pending),
                    Ok(status) => {
                        let ticket = delivery.ticket.take().expect("owned native ticket");
                        match engine.collect_native_follow_up(ticket) {
                            Ok(()) => Some(status),
                            Err(error) => Some(NativeFollowUpStatus::Retained(error.to_string())),
                        }
                    }
                    Err(error) => Some(NativeFollowUpStatus::Retained(error.to_string())),
                },
            };
            match result {
                None | Some(NativeFollowUpStatus::Pending) => retained.push(delivery),
                Some(status) => {
                    self.status = match status {
                        NativeFollowUpStatus::Retained(reason) => reason,
                        NativeFollowUpStatus::Delivered { dispatch, .. } => {
                            dispatch_label(dispatch).into()
                        }
                        NativeFollowUpStatus::Pending => unreachable!(),
                    };
                    if self
                        .selected
                        .as_ref()
                        .is_some_and(|thread| thread["id"] == delivery.thread)
                    {
                        self.refresh_queue(cx);
                    }
                    cx.notify();
                }
            }
        }
        self.follow_up_deliveries = retained;
    }
    pub(super) fn composer_send_dispatch(&self, alternate: bool) -> Dispatch {
        let Some(thread) = self.selected.as_ref() else {
            return Dispatch::Send;
        };
        let id = text(thread, "id");
        if let Some(dispatch) = self
            .engine
            .try_lock()
            .ok()
            .and_then(|engine| engine.native_follow_up_dispatch(thread, alternate).ok())
        {
            // Remember what the engine said so a busy frame cannot flip the
            // button between Send, Queue and Steer while it is being read.
            self.dispatch_cache
                .borrow_mut()
                .insert(id.clone(), dispatch);
            return dispatch;
        }
        if let Some(dispatch) = self.dispatch_cache.borrow().get(&id) {
            return *dispatch;
        }
        if self.running.contains(&id) {
            Dispatch::Queue
        } else {
            Dispatch::Send
        }
    }
}
pub(super) fn dispatch_icon(dispatch: Dispatch) -> gpui_kit::assets::IconName {
    use gpui_kit::assets::IconName;
    match dispatch {
        Dispatch::Send => IconName::ArrowUp,
        Dispatch::Steer => IconName::CornerUpRight,
        Dispatch::Queue => IconName::ListPlus,
        Dispatch::Interrupt => IconName::SkipForward,
    }
}
pub(super) fn dispatch_label(dispatch: Dispatch) -> &'static str {
    match dispatch {
        Dispatch::Send => "Send message",
        Dispatch::Steer => "Steer message",
        Dispatch::Queue => "Queue message",
        Dispatch::Interrupt => "Stop the turn and send message",
    }
}
fn behavior_icon(behavior: Behavior) -> gpui_kit::assets::IconName {
    dispatch_icon(match behavior {
        Behavior::Steer => Dispatch::Steer,
        Behavior::Queue => Dispatch::Queue,
        Behavior::Interrupt => Dispatch::Interrupt,
    })
}
fn behavior_help(behavior: Behavior) -> &'static str {
    match behavior {
        Behavior::Steer => {
            "Send text into the running turn; if it cannot receive now, send it next"
        }
        Behavior::Queue => "Wait for this turn to finish before sending",
        Behavior::Interrupt => {
            "Stop the current turn, wait for its worker to return and save, then send"
        }
    }
}

#[cfg(test)]
mod send_route_tests {
    use super::{
        AdmittedPreview, PendingSend, SelectionWait, buffered_text, follow_up_source,
        preview_handed_off, separate_buffered_payload,
    };
    use serde_json::json;

    #[test]
    fn admitted_preview_stays_until_its_queue_or_accepted_transcript_is_visible() {
        let thread = json!({"id":"t","selection":{"provider":"codex"},
            "items":[{"kind":"user","text":"same"}], "draftContext":[]});
        let preview = AdmittedPreview {
            pending: PendingSend::new(&thread, "same".into(), false),
            queue_id: "queue-1".into(),
        };
        let mut snapshot = thread.clone();
        snapshot["rustMessageQueue"] = json!([{"id":"queue-1","state":"dispatching"}]);
        let queue = vec![json!({"id":"queue-1","state":"dispatching"})];
        assert!(preview_handed_off(&preview, &snapshot, &queue));
        snapshot["rustMessageQueue"][0]["state"] = json!("completed");
        assert!(
            !preview_handed_off(&preview, &snapshot, &[]),
            "an earlier identical message is not the new one"
        );
        snapshot["items"]
            .as_array_mut()
            .unwrap()
            .push(json!({"kind":"user","text":"same","rustQueueMessageID":"queue-1","rustAwaitingQueueDelivery":true}));
        assert!(!preview_handed_off(&preview, &snapshot, &[]));
        snapshot["items"][1]
            .as_object_mut()
            .unwrap()
            .remove("rustAwaitingQueueDelivery");
        assert!(preview_handed_off(&preview, &snapshot, &[]));
        let queued = AdmittedPreview { ..preview };
        assert!(preview_handed_off(&queued, &thread, &queue));
    }

    #[test]
    fn follow_up_capture_preserves_scope_without_copying_history() {
        let thread = json!({"id":"t","draft":"hi","selection":{"provider":"codex"},
            "draftContext":[{"kind":"file","path":"src/main.rs"}],"items":[{"text":"history"}]});
        let captured = follow_up_source(&thread);
        assert_eq!(captured["id"], "t");
        assert_eq!(captured["draft"], "hi");
        assert_eq!(captured["draftContext"], thread["draftContext"]);
        assert!(captured.get("items").is_none());
        assert!(captured.get("rustDraftImages").is_none());
    }

    #[test]
    fn a_recalled_message_cannot_claim_admission() {
        let slot = super::CapturedAdmission::default();
        assert!(slot.claim(2));
        assert!(!slot.claim(1));
        let slot = super::CapturedAdmission::default();
        assert!(slot.claim(1));
        assert!(!slot.claim(2));
    }
    #[test]
    fn waiting_send_uses_the_acknowledged_selection_without_changing_its_payload() {
        for provider in [
            "codex",
            "claude",
            "opencode",
            "cursor",
            "grok",
            "antigravity",
        ] {
            let old = json!({"id":"a", "selection":{"provider":"codex","modelID":"old"},
                "draftContext":[{"path":"file"}],"rustDraftImages":[{"id":"image"}]});
            let mut pending = PendingSend::new(&old, "message".into(), false);
            pending.selection_wait = SelectionWait::Waiting;
            let mut selected = old.clone();
            selected["selection"] = json!({"provider":provider,"modelID":"new"});
            pending.finish_selection(Some(&selected));
            assert_eq!(pending.selection_wait, SelectionWait::None);
            assert_eq!(pending.captured["selection"], selected["selection"]);
            assert_eq!(pending.captured["draft"], "message");
            assert_eq!(pending.captured["draftContext"], old["draftContext"]);
            assert_eq!(pending.captured["rustDraftImages"], old["rustDraftImages"]);
            assert!(pending.matches(&selected, "message"));
            assert!(!pending.matches(&selected, "newer draft"));
        }
    }

    #[test]
    fn failed_or_foreign_selection_cannot_retarget_a_waiting_message() {
        let thread = json!({"id":"a", "selection":{"provider":"codex","modelID":"old"}});
        let other = json!({"id":"b", "selection":{"provider":"claude","modelID":"other"}});
        for result in [None, Some(&other)] {
            let mut pending = PendingSend::new(&thread, "message".into(), false);
            pending.selection_wait = SelectionWait::Waiting;
            pending.finish_selection(result);
            assert_eq!(pending.selection_wait, SelectionWait::Failed);
            assert_eq!(pending.captured["selection"], thread["selection"]);
            assert_eq!(pending.captured["draft"], "message");
        }
    }

    #[test]
    fn deferred_send_never_follows_a_changed_draft_or_model() {
        let mut thread = json!({"id":"conversation", "selection":{"provider":"codex","modelID":"one"}, "accessMode":"approval", "interactionMode":"build"});
        let pending = PendingSend::new(&thread, "message".into(), false);
        assert!(pending.matches(&thread, "message"));
        assert!(!pending.matches(&thread, "new message"));
        thread["selection"]["modelID"] = json!("two");
        assert!(!pending.matches(&thread, "message"));
        thread["selection"]["modelID"] = json!("one");
        thread["draftContext"] = json!([{"id":"new reference"}]);
        assert!(!pending.matches(&thread, "message"));
        thread["draftContext"] = json!(null);
        let importing = PendingSend::during_import(&thread, "message".into(), false);
        thread["rustDraftImages"] = json!([{"id":"new image"}]);
        assert!(importing.matches(&thread, "message"));
        assert!(!pending.matches(&thread, "message"));
    }

    #[test]
    fn deferred_send_captures_original_text_model_and_imported_images() {
        let mut thread = json!({"id":"conversation", "selection":{"provider":"codex","modelID":"one"}, "rustDraftImages":[{"id":"before"}]});
        let mut pending = PendingSend::during_import(&thread, "original".into(), false);
        thread["draft"] = json!("next message");
        thread["rustDraftImages"] = json!([{"id":"before"},{"id":"imported"}]);
        pending.add_imports(vec![1]);
        assert!(pending.complete_import(1, &[json!({"id":"imported"})], false));
        thread["rustDraftImages"] = json!([{"id":"before"},{"id":"imported"},{"id":"next-import"}]);
        thread["selection"]["modelID"] = json!("two");
        assert!(!pending.matches(&thread, "next message"));
        assert_eq!(pending.captured["draft"], "original");
        assert_eq!(pending.captured["selection"]["modelID"], "one");
        assert_eq!(
            pending.captured["rustDraftImages"],
            json!([{"id":"before"},{"id":"imported"}])
        );
    }

    #[test]
    fn a_second_send_keeps_only_new_text_but_preserves_an_intentional_retype() {
        let thread = json!({"id":"a","selection":{"provider":"codex"}});
        let mut first = PendingSend::new(&thread, "first".into(), false);
        assert_eq!(buffered_text(&first, "a", "first"), None);
        first.edited = true;
        assert_eq!(
            buffered_text(&first, "a", "first second"),
            Some(" second".into())
        );
        assert_eq!(buffered_text(&first, "a", "first"), Some("first".into()));
        first.original_visible = false;
        assert_eq!(
            buffered_text(&first, "a", "first again"),
            Some("first again".into())
        );
        assert_eq!(
            buffered_text(&first, "another", "new thread"),
            Some("new thread".into())
        );
    }

    #[test]
    fn buffered_messages_do_not_reuse_earlier_images_or_references() {
        let mut thread = json!({"id":"a","selection":{"provider":"codex"},
            "rustDraftImages":[{"id":"first"}],
            "draftContext":[{"id":"reference-one"}]});
        let first = PendingSend::new(&thread, "first".into(), false);
        thread["rustDraftImages"] = json!([{"id":"first"},{"id":"second"}]);
        thread["draftContext"] = json!([{"id":"reference-one"},{"id":"reference-two"}]);
        let mut next = PendingSend::new(&thread, "second".into(), false);
        separate_buffered_payload(&mut next, &[first]);
        assert_eq!(next.captured["rustDraftImages"], json!([{"id":"second"}]));
        assert_eq!(
            next.captured["draftContext"],
            json!([{"id":"reference-two"}])
        );
        assert_eq!(next.captured["draft"], "second");
    }
}
