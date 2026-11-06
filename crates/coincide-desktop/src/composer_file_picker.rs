//! Project-file path references with proven native @query completion; no key interception.
use super::*;
use gpui_kit::component::tooltip::Tooltip;
#[path = "composer_file_mentions.rs"]
mod mentions;
use coincide_core::{
    api::{AttachedFileReference, FileReference, FileReferenceList},
    composer_context::ExpectedContext,
};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    mpsc,
};
#[derive(Clone, PartialEq)]
pub(super) struct Binding {
    thread: String,
    draft: String,
    context: ExpectedContext,
    project: Value,
    worktree: Value,
}
enum Job {
    Search(Binding, String),
    Attach(FileReference),
}
enum Effect {
    Listed(FileReferenceList),
    Attached(AttachedFileReference),
}
struct Reply {
    generation: u64,
    result: std::result::Result<Effect, String>,
}
pub(super) struct Picker {
    pub query: Entity<InputState>,
    pub opened: bool,
    focus: FocusHandle,
    binding: Option<Binding>,
    epoch: Arc<AtomicU64>,
    files: Vec<FileReference>,
    total: usize,
    directory: String,
    truncated: bool,
    skipped: usize,
    workers: worker_owner::WorkerOwner,
    sender: mpsc::SyncSender<Reply>,
    receiver: mpsc::Receiver<Reply>,
    pending: bool,
    unjoined: bool,
    ambiguous: bool,
    status: String,
    automatic: bool,
    trigger: Option<mentions::Ticket>,
    scheduled: Option<mentions::Ticket>,
    dismissed: Option<mentions::Ticket>,
    pending_mention: Option<mentions::Ticket>,
    composer_revision: mentions::Revision,
}
fn allowed(admission: &worker_owner::Admission, epoch: &AtomicU64, generation: u64) -> Result<()> {
    anyhow::ensure!(
        admission.allowed() && epoch.load(Ordering::Acquire) == generation,
        "File picker changed before admission; no reference was attached"
    );
    Ok(())
}
impl Picker {
    pub fn new(window: &mut Window, cx: &mut Context<Coincide>) -> Self {
        let (sender, receiver) = mpsc::sync_channel(1);
        Self {
            query: cx
                .new(|cx| InputState::new(window, cx).placeholder("Search project file paths")),
            opened: false,
            focus: cx.focus_handle(),
            binding: None,
            epoch: Arc::new(AtomicU64::new(0)),
            files: Vec::new(),
            total: 0,
            directory: String::new(),
            truncated: false,
            skipped: 0,
            workers: Default::default(),
            sender,
            receiver,
            pending: false,
            unjoined: false,
            ambiguous: false,
            status: String::new(),
            automatic: false,
            trigger: None,
            scheduled: None,
            dismissed: None,
            pending_mention: None,
            composer_revision: Default::default(),
        }
    }
    pub fn text_changed(&mut self) {
        self.composer_revision.text_changed();
        self.invalidate();
    }
    pub fn observe_composer(
        &mut self,
        text: String,
        selection: std::ops::Range<usize>,
        reversed: bool,
    ) {
        if self.composer_revision.observe(text, selection, reversed) && self.automatic {
            self.invalidate();
        }
    }
    pub fn invalidate(&mut self) {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        if !self.files.is_empty() {
            self.status =
                "Draft, context or search changed. Search again for current files.".into();
        }
        self.files.clear();
        self.directory.clear();
        self.total = 0;
        self.truncated = false;
        self.skipped = 0;
    }
    fn busy(&self) -> bool {
        self.pending || self.unjoined || self.ambiguous || self.workers.closed()
    }
    pub fn close(&mut self) {
        self.invalidate();
        self.workers.close();
        self.opened = false;
        self.binding = None;
    }
    pub fn shutdown_status(&mut self) -> worker_owner::ShutdownStatus {
        self.workers.status()
    }
    pub fn receipts_drained(&self) -> bool {
        !self.pending
    }
    pub fn closed_and_drained(&mut self) -> bool {
        let status = self.shutdown_status();
        status.closed
            && status.unjoined == 0
            && status.panicked == 0
            && status.unclassified == 0
            && !self.pending
    }
    fn spawn(&mut self, engine: SharedEngine, job: Job) -> bool {
        if self.busy() {
            self.status = "Wait for the owned file operation to finish.".into();
            return false;
        }
        let epoch = self.epoch.clone();
        let generation = epoch.load(Ordering::Acquire);
        let sender = self.sender.clone();
        let started = self.workers.spawn(move |admission| {
            let result = (|| -> Result<Effect> {
                allowed(&admission, &epoch, generation)?;
                match job {
                    Job::Search(binding, query) => {
                        let scope = {
                            let engine = engine
                                .lock()
                                .map_err(|_| anyhow::anyhow!("App owner is unavailable"))?;
                            allowed(&admission, &epoch, generation)?;
                            engine.prepare_file_reference_scope(
                                &binding.thread,
                                &binding.draft,
                                &binding.context,
                            )?
                        };
                        allowed(&admission, &epoch, generation)?;
                        let result = scope.search(&query)?;
                        allowed(&admission, &epoch, generation)?;
                        Ok(Effect::Listed(result))
                    }
                    Job::Attach(file) => {
                        let mut engine = engine
                            .lock()
                            .map_err(|_| anyhow::anyhow!("App owner is unavailable"))?;
                        allowed(&admission, &epoch, generation)?;
                        // Do not discard a successful commit merely because its
                        // picker/draft epoch changed after this admission point.
                        Ok(Effect::Attached(engine.attach_file_reference(&file)?))
                    }
                }
            })()
            .map_err(|error| error.to_string().chars().take(1024).collect());
            let _ = sender.send(Reply { generation, result });
        });
        if started {
            self.pending = true;
            self.unjoined = true;
            self.status = "Working…".into();
        } else {
            self.status = "File worker could not start; no reference was attached.".into();
        }
        started
    }
    fn poll(&mut self) -> Option<(AttachedFileReference, bool, Option<mentions::Ticket>)> {
        let status = self.workers.status();
        self.unjoined = status.unjoined != 0;
        if status.panicked != 0 || status.unclassified != 0 {
            self.ambiguous = true;
            self.status =
                "File worker completion is ambiguous; further actions are disabled.".into();
        }
        let reply = self.receiver.try_recv().ok()?;
        self.pending = false;
        match reply.result {
            Ok(Effect::Listed(result)) => {
                if self.opened && reply.generation == self.epoch.load(Ordering::Acquire) {
                    self.files = result.files;
                    self.directory = result.directory;
                    self.total = result.total;
                    self.truncated = result.truncated;
                    self.skipped = result.skipped;
                    self.status = if self.files.is_empty() {
                        "No eligible project files in this result. Refine the search.".into()
                    } else {
                        "Choose Attach for the file you want to reference.".into()
                    };
                }
                None
            }
            Ok(Effect::Attached(result)) => {
                let fresh = self.opened && reply.generation == self.epoch.load(Ordering::Acquire);
                self.invalidate();
                self.status = if result.changed {
                    "Project file path reference attached. Message text is unchanged.".into()
                } else {
                    "That project path reference was already attached.".into()
                };
                Some((result, fresh, self.pending_mention.take()))
            }
            Err(error) => {
                self.pending_mention = None;
                self.status = error;
                None
            }
        }
    }
}
/// Query prefill only. It never replaces a range or interprets ordinary email text.
fn query_at_caret(text: &str, selection: std::ops::Range<usize>) -> Option<String> {
    if selection.start != selection.end
        || selection.end > text.len()
        || !text.is_char_boundary(selection.end)
    {
        return None;
    }
    let prefix = &text[..selection.end];
    let start = prefix
        .char_indices()
        .rev()
        .find(|(_, c)| c.is_whitespace())
        .map_or(0, |(index, c)| index + c.len_utf8());
    let query = prefix[start..].strip_prefix('@')?;
    (query.len() <= 256 && !query.chars().any(char::is_control)).then(|| query.to_owned())
}
impl Coincide {
    fn file_reference_binding(&self, cx: &Context<Self>) -> Option<Binding> {
        if !self.microphone_window_active
            || self.settings_open
            || self.schedules_open
            || self.workspace_open
            || self.session_import_open
            || self.command_palette.read(cx).is_open()
            || self.historical_image_is_open()
            || self.media.close_requested
            || self.media.shutdown_requested
        {
            return None;
        }
        let thread = self.selected.as_ref()?;
        let id = text(thread, "id");
        if self.pending_drafts.contains_key(&id) {
            return None;
        }
        Some(Binding {
            thread: id,
            draft: self.composer.read(cx).value().to_string(),
            context: ExpectedContext::from_thread(thread),
            project: thread["projectID"].clone(),
            worktree: thread["worktreePath"].clone(),
        })
    }
    pub(super) fn sync_composer_file_picker(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let binding = self.file_reference_binding(cx);
        if binding != self.composer_files.binding {
            let changed_thread = binding.as_ref().map(|b| &b.thread)
                != self.composer_files.binding.as_ref().map(|b| &b.thread);
            self.composer_files.invalidate();
            if binding.is_none() || changed_thread {
                if self.composer_files.opened
                    && (self.composer_files.focus.contains_focused(window, cx)
                        || self
                            .composer_files
                            .query
                            .read(cx)
                            .focus_handle(cx)
                            .is_focused(window))
                {
                    self.navigation_focus.focus(window, cx);
                }
                self.composer_files.opened = false;
                self.composer_files.automatic = false;
                self.composer_files.trigger = None;
            }
            self.composer_files.binding = binding;
        }
        if self.media.close_requested || self.media.shutdown_requested {
            self.composer_files.close();
        }
    }
    pub(super) fn poll_composer_file_picker(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.sync_composer_file_picker(window, cx);
        let was_busy = self.composer_files.busy();
        let previous = self.composer_files.status.clone();
        if let Some((result, fresh, mention)) = self.composer_files.poll() {
            let live_before_projection = if mention.is_some() {
                self.live_file_mention(window, cx, false)
            } else {
                None
            };
            if let Some(thread) = self
                .selected
                .as_mut()
                .filter(|thread| fresh && thread["id"] == result.thread)
            {
                thread["draftContext"] = result.context;
            }
            if let Some(ticket) = mention {
                if fresh && live_before_projection.as_ref() == Some(&ticket) {
                    if let Some((expected, range_utf16)) =
                        mentions::removal(&ticket.binding.draft, ticket.range.clone())
                    {
                        self.composer.update(cx, |input, cx| {
                            if input.value().as_ref() != ticket.binding.draft
                                || input.selected_range() != ticket.selection
                                || !input.is_editable()
                                || gpui_kit::EntityInputHandler::marked_text_range(
                                    input, window, cx,
                                )
                                .is_some()
                            {
                                return;
                            }
                            gpui_kit::EntityInputHandler::replace_text_in_range(
                                input,
                                Some(range_utf16),
                                "",
                                window,
                                cx,
                            )
                        });
                        if self.composer.read(cx).value().as_ref() == expected {
                            self.composer_files.status="Project path reference attached and its @query completed. Other message text is unchanged.".into();
                            self.composer_files.opened = false;
                            self.composer_files.automatic = false;
                            self.composer_files.trigger = None;
                            self.composer.read(cx).focus_handle(cx).focus(window, cx);
                        } else {
                            self.composer_files.status="Reference attached. Native text editing did not match the proven range; inspect the preserved draft before sending.".into();
                        }
                    }
                } else {
                    self.composer_files.status="Reference attached. The composer changed or is composing; newer text was kept and the @query was not removed.".into();
                }
            }
            self.status = self.composer_files.status.clone();
        }
        if was_busy != self.composer_files.busy() || previous != self.composer_files.status {
            cx.notify();
        }
    }
    fn open_composer_file_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.sync_composer_file_picker(window, cx);
        if self.composer_files.binding.is_none() {
            self.status =
                "Open a conversation and finish saving its draft before choosing a project file."
                    .into();
            cx.notify();
            return;
        }
        if self.composer_files.opened {
            self.close_composer_file_picker(window, cx);
            return;
        }
        self.composer_files.invalidate();
        self.composer_files.opened = true;
        self.composer_files.automatic = false;
        self.composer_files.trigger = None;
        let composer = self.composer.read(cx);
        let query = query_at_caret(composer.value().as_ref(), composer.selected_range())
            .unwrap_or_default();
        self.composer_files
            .query
            .update(cx, |input, cx| input.set_value(query, window, cx));
        self.composer_files
            .query
            .read(cx)
            .focus_handle(cx)
            .focus(window, cx);
        self.composer_files.status =
            "Search lists Git project paths only. No file body is read or attached.".into();
        cx.notify();
    }
    fn close_composer_file_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.composer_files.opened = false;
        let dismissed = self
            .composer_files
            .trigger
            .clone()
            .or_else(|| self.live_file_mention(window, cx, false));
        self.composer_files.dismissed = dismissed;
        self.composer_files.automatic = false;
        self.composer_files.trigger = None;
        self.composer_files.invalidate();
        if self.file_reference_binding(cx).is_some() {
            self.composer.read(cx).focus_handle(cx).focus(window, cx);
        } else {
            self.navigation_focus.focus(window, cx);
        }
        cx.notify();
    }
    fn search_composer_files(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.composer_files.automatic {
            self.composer_files.scheduled = None;
            self.sync_automatic_file_mentions(window, cx);
            cx.notify();
            return;
        }
        self.sync_composer_file_picker(window, cx);
        let Some(binding) = self
            .composer_files
            .binding
            .clone()
            .filter(|_| self.composer_files.opened)
        else {
            return;
        };
        let query = self.composer_files.query.read(cx).value().to_string();
        self.composer_files.invalidate();
        self.composer_files
            .spawn(self.engine.clone(), Job::Search(binding, query));
        cx.notify();
    }
    fn attach_composer_file(
        &mut self,
        file: FileReference,
        generation: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.sync_composer_file_picker(window, cx);
        if !self.composer_files.opened
            || self.composer_files.binding.is_none()
            || self.composer_files.epoch.load(Ordering::Acquire) != generation
        {
            self.composer_files.status =
                "Draft, context or file search changed; search again.".into();
            cx.notify();
            return;
        }
        let mention = if self.composer_files.automatic {
            let current = self.live_file_mention(window, cx, false);
            if current != self.composer_files.trigger {
                self.composer_files.status =
                    "Caret, draft or IME composition changed; choose the file again.".into();
                self.composer_files.invalidate();
                cx.notify();
                return;
            }
            current
        } else {
            None
        };
        if self
            .composer_files
            .spawn(self.engine.clone(), Job::Attach(file))
        {
            self.composer_files.pending_mention = mention;
        }

        cx.notify();
    }
    fn live_file_mention(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
        require_focus: bool,
    ) -> Option<mentions::Ticket> {
        let binding = self.file_reference_binding(cx)?;
        // A native WebKit responder is not represented by GPUI focus handles.
        // Explicit @ Files remains available; automatic caret ownership waits.
        if self.browser_panels.contains(&binding.thread) {
            return None;
        }
        if require_focus && !self.composer.read(cx).focus_handle(cx).is_focused(window) {
            return None;
        }
        let (selection, reversed, marked, editable, tokens) =
            self.composer.update(cx, |input, cx| {
                (
                    input.selected_range(),
                    input.is_selection_reversed(),
                    gpui_kit::EntityInputHandler::marked_text_range(input, window, cx).is_some(),
                    input.is_editable(),
                    input
                        .tokens()
                        .iter()
                        .map(|token| token.range())
                        .collect::<Vec<_>>(),
                )
            });
        if !editable || reversed {
            return None;
        }
        let (range, query) = mentions::detect(&binding.draft, selection.clone(), marked, &tokens)?;
        Some(mentions::Ticket {
            binding,
            selection,
            range,
            query,
            revision: self.composer_files.composer_revision.get(),
        })
    }
    pub(super) fn sync_automatic_file_mentions(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.composer_files.opened && !self.composer_files.automatic {
            return;
        }
        let owns_focus = self.composer.read(cx).focus_handle(cx).is_focused(window)
            || self.composer_files.focus.contains_focused(window, cx);
        let ticket = owns_focus
            .then(|| self.live_file_mention(window, cx, !self.composer_files.opened))
            .flatten();
        let Some(ticket) = ticket else {
            if self.composer_files.automatic && !self.composer_files.pending {
                if self.composer_files.focus.contains_focused(window, cx) {
                    self.composer.read(cx).focus_handle(cx).focus(window, cx);
                }
                self.composer_files.opened = false;
                self.composer_files.automatic = false;
                self.composer_files.trigger = None;
                self.composer_files.invalidate();
            }
            return;
        };
        if self.composer_files.dismissed.as_ref() == Some(&ticket) {
            return;
        }
        self.composer_files.opened = true;
        self.composer_files.automatic = true;
        self.composer_files.trigger = Some(ticket.clone());
        if self.composer_files.scheduled.as_ref() == Some(&ticket) || self.composer_files.busy() {
            return;
        }
        self.composer_files.invalidate();
        self.composer_files.scheduled = Some(ticket.clone());
        self.composer_files.spawn(
            self.engine.clone(),
            Job::Search(ticket.binding.clone(), ticket.query.clone()),
        );
    }
    pub(super) fn composer_file_button(&self, cx: &mut Context<Self>) -> AnyElement {
        Button::new("composer-project-files")
            .label("@ Files")
            .compact()
            .ghost()
            .tooltip("Attach a project file path reference; file contents are not read")
            .disabled(
                self.file_reference_binding(cx).is_none() || self.composer_files.workers.closed(),
            )
            .on_click(cx.listener(|this, _, window, cx| this.open_composer_file_picker(window, cx)))
            .into_any_element()
    }
    pub(super) fn composer_file_pane(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        if !self.composer_files.opened {
            return None;
        }
        let state = &self.composer_files;
        let generation = state.epoch.load(Ordering::Acquire);
        let busy = state.busy();
        let mut results = div()
            .id("composer-file-results")
            .role(Role::List)
            .aria_label("Matching project file references")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_1();
        if state.files.is_empty() {
            results = results
                .child(if state.automatic {
                    "Choose a path reference to complete this @query. File contents are not read."
                } else {
                    "Choose a path reference. Message text and file contents stay unchanged."
                })
                .child(div().text_xs().child(state.status.clone()));
        }
        if !state.directory.is_empty() {
            let counts = format!(
                "{} files / {} paths · {} skipped{}{}",
                state.files.len(),
                state.total,
                state.skipped,
                if state.truncated { " · limited" } else { "" },
                if busy { " · working…" } else { "" },
            );
            let details = format!(
                "{} eligible files shown from {} matching Git paths; {} unavailable or unsupported entries skipped. {}Project: {}",
                state.files.len(),
                state.total,
                state.skipped,
                if state.truncated {
                    "Result limit reached; refine the search for more. "
                } else {
                    ""
                },
                state.directory,
            );
            results = results.child(
                div()
                    .id("composer-file-result-summary")
                    .role(Role::Label)
                    .aria_label(details.clone())
                    .tooltip(move |window, cx| Tooltip::new(details.clone()).build(window, cx))
                    .h(px(20.))
                    .flex_shrink_0()
                    .text_xs()
                    .truncate()
                    .child(format!("{counts} · {}", state.directory)),
            );
        }
        let pane = div()
            .id("composer-file-picker")
            .track_focus(&state.focus)
            .role(Role::Group)
            .aria_label("Project file reference picker")
            .h(px(150.))
            .min_h_0()
            .flex_shrink_0()
            .overflow_hidden()
            .flex()
            .flex_col()
            .gap_1()
            .child(
                div()
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1().child("Project file references"))
                    .child(
                        Button::new("composer-file-close")
                            .label("Close")
                            .compact()
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.close_composer_file_picker(window, cx)
                            })),
                    ),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .flex()
                    .gap_2()
                    .when(!state.automatic, |view| {
                        view.child(Input::new(&state.query))
                    })
                    .when(state.automatic, |view| {
                        view.child(div().flex_1().truncate().child(format!(
                                "@{}",
                                state
                                    .trigger
                                    .as_ref()
                                    .map(|ticket| ticket.query.as_str())
                                    .unwrap_or("")
                            )))
                    })
                    .child(
                        Button::new("composer-file-search")
                            .label("Search")
                            .disabled(busy)
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.search_composer_files(window, cx)
                            })),
                    ),
            );
        for (index, file) in state.files.iter().enumerate() {
            let candidate = file.clone();
            results = results.child(
                div()
                    .id(("composer-file-row", index))
                    .role(Role::ListItem)
                    .aria_label(format!("Project file {}", file.path()))
                    .h(px(32.))
                    .flex_shrink_0()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .child(file.path().to_owned()),
                    )
                    .child(
                        Button::new(("composer-file-attach", index))
                            .label(if state.automatic {
                                "Attach and complete"
                            } else {
                                "Attach"
                            })
                            .accessibility_label(if state.automatic {format!("Attach project file reference {} and complete the current @query",file.path())} else {format!("Attach project file reference {}",file.path())})
                            .compact()
                            .disabled(busy)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.attach_composer_file(candidate.clone(), generation, window, cx)
                            })),
                    ),
            );
        }
        Some(pane.child(results).into_any_element())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn query_prefill_respects_utf8_word_boundaries_selection_and_exact_user_text() {
        let text = "café ask @src/中文";
        let before = text.to_owned();
        assert_eq!(
            query_at_caret(text, text.len()..text.len()),
            Some("src/中文".into())
        );
        assert_eq!(query_at_caret("@", 1..1), Some(String::new()));
        assert_eq!(query_at_caret("mail user@example.test", 22..22), None);
        assert_eq!(query_at_caret(text, 4..4), None);
        assert_eq!(query_at_caret(text, 0..text.len()), None);
        assert_eq!(query_at_caret(text, text.len() + 1..text.len() + 1), None);
        assert_eq!(
            query_at_caret(&format!("@{}", "a".repeat(257)), 258..258),
            None
        );
        assert_eq!(text, before);
    }
    #[::core::prelude::v1::test]
    fn binding_keeps_context_presence_unknown_values_project_and_worktree_distinct() {
        let original = Binding {
            thread: "one".into(),
            draft: "  draft @src\n".into(),
            context: ExpectedContext::from_thread(
                &json!({"draftContext":[{"kind":"future","opaque":true}]}),
            ),
            project: json!("p"),
            worktree: json!("/synthetic/worktree"),
        };
        for changed in [
            Binding {
                thread: "two".into(),
                ..original.clone()
            },
            Binding {
                draft: "draft @src".into(),
                ..original.clone()
            },
            Binding {
                context: ExpectedContext::from_thread(&json!({})),
                ..original.clone()
            },
            Binding {
                project: json!("other"),
                ..original.clone()
            },
            Binding {
                worktree: Value::Null,
                ..original.clone()
            },
        ] {
            assert!(changed != original);
        }
        assert!(
            ExpectedContext::from_thread(&json!({}))
                != ExpectedContext::from_thread(&json!({"draftContext":null}))
        );
    }
    #[::core::prelude::v1::test]
    fn generation_revocation_prevents_new_work_and_close_retains_actual_worker_join() {
        let mut owner = worker_owner::WorkerOwner::default();
        let epoch = Arc::new(AtomicU64::new(3));
        let captured = epoch.clone();
        let effects = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let calls = effects.clone();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (result_tx, result_rx) = mpsc::channel();
        assert!(owner.spawn(move |admission| {
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            let result = allowed(&admission, &captured, 3);
            if result.is_ok() {
                calls.fetch_add(1, Ordering::SeqCst);
            }
            result_tx.send(result.is_err()).unwrap();
        }));
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        epoch.fetch_add(1, Ordering::AcqRel);
        owner.close();
        assert_eq!(owner.status().unjoined, 1);
        release_tx.send(()).unwrap();
        assert!(result_rx.recv_timeout(Duration::from_secs(5)).unwrap());
        let deadline = Instant::now() + Duration::from_secs(5);
        while owner.status().unjoined != 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        assert_eq!(effects.load(Ordering::SeqCst), 0);
        assert_eq!(owner.status().returned, 1);
    }
}
