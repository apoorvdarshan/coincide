//! Native archive review. Permanent deletion uses opaque Core plans/Undo;
//! no deletion intent or confirmation can be supplied through JSON settings.
use super::*;
use coincide_core::api::{PreparedThreadDeletion, ThreadDeletionUndo, ThreadFlagAction};
use coincide_core::store::ArchivedConversation;
use std::collections::BTreeSet;
const PAGE: usize = 50;
pub(super) struct ArchiveSettings {
    query: Entity<InputState>,
    project: Option<String>,
    rows: Vec<ArchivedConversation>,
    total: usize,
    offset: usize,
    picked: BTreeSet<String>,
    review: Option<PreparedThreadDeletion>,
    undo: Option<ThreadDeletionUndo>,
    status: String,
    loaded: bool,
}
impl ArchiveSettings {
    pub(super) fn new(window: &mut Window, cx: &mut Context<Coincide>) -> Self {
        Self {
            query: cx
                .new(|cx| InputState::new(window, cx).placeholder("Search archived conversations")),
            project: None,
            rows: Vec::new(),
            total: 0,
            offset: 0,
            picked: BTreeSet::new(),
            review: None,
            undo: None,
            status: String::new(),
            loaded: false,
        }
    }
    pub(super) fn subscriptions(&self, cx: &mut Context<Coincide>) -> Vec<Subscription> {
        vec![cx.subscribe(&self.query, |this, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                this.archive_settings.invalidate_filter();
                this.refresh_archive_settings(cx);
            }
        })]
    }
    fn invalidate_filter(&mut self) {
        self.review = None;
        self.picked.clear();
        self.offset = 0;
        self.rows.clear();
        self.loaded = false;
    }
    pub(super) fn close_review(&mut self) {
        self.review = None;
    }
}
fn visible_selection(
    rows: &[ArchivedConversation],
    picked: &BTreeSet<String>,
) -> Result<Vec<String>> {
    anyhow::ensure!(
        !picked.is_empty() && picked.len() <= PAGE,
        "Select 1–50 archived conversations"
    );
    anyhow::ensure!(
        picked.iter().all(|id| rows.iter().any(|row| &row.id == id)),
        "Archive view changed; select conversations again"
    );
    Ok(picked.iter().cloned().collect())
}
fn prepare_delete(engine: &SharedEngine, ids: &[String]) -> Result<PreparedThreadDeletion> {
    try_state(engine)?.prepare_native_thread_deletion(ids)
}
fn restore(engine: &SharedEngine, ids: &[String]) -> Result<()> {
    let mut owner = try_state(engine)?;
    let prepared = owner.prepare_thread_flags(ids, ThreadFlagAction::Restore)?;
    owner.apply_thread_flags(&prepared)?;
    Ok(())
}
impl Coincide {
    pub(super) fn refresh_archive_settings(&mut self, cx: &mut Context<Self>) {
        let state = &self.archive_settings;
        let query = state.query.read(cx).value().to_string();
        let result = (|| -> Result<_> {
            let owner = try_state(&self.engine)?;
            anyhow::ensure!(!owner.admissions_frozen(), "App is closing");
            owner.native_archived_conversations_for_project(
                &query,
                state.project.as_deref(),
                state.offset,
                PAGE,
            )
        })();
        match result {
            Ok(page) => {
                let state = &mut self.archive_settings;
                state.rows = page.rows;
                state.total = page.total;
                state.offset = page.offset;
                state.loaded = true;
                state
                    .picked
                    .retain(|id| state.rows.iter().any(|r| &r.id == id));
            }
            Err(error) => {
                self.archive_settings.loaded = false;
                self.archive_settings.status = format!("Archive could not be loaded: {error}");
            }
        }
        cx.notify();
    }
    fn prepare_archive_deletion(&mut self, cx: &mut Context<Self>) {
        let result = (|| -> Result<_> {
            anyhow::ensure!(
                self.archive_settings.loaded,
                "Refresh the archive before deleting"
            );
            let ids =
                visible_selection(&self.archive_settings.rows, &self.archive_settings.picked)?;
            anyhow::ensure!(
                !ids.iter().any(|id| self.pending_drafts.contains_key(id)),
                "Save this conversation's pending draft before deleting it"
            );
            prepare_delete(&self.engine, &ids)
        })();
        match result {
            Ok(review) => {
                self.archive_settings.review = Some(review);
                self.archive_settings.status.clear();
            }
            Err(error) => {
                self.archive_settings.status =
                    format!("Delete review could not be prepared: {error}")
            }
        };
        cx.notify();
    }
    fn confirm_archive_deletion(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(review) = self.archive_settings.review.take() else {
            return;
        };
        let ids = self
            .archive_settings
            .picked
            .iter()
            .cloned()
            .collect::<Vec<_>>();
        let result = (|| -> Result<_> {
            anyhow::ensure!(
                !ids.iter().any(|id| self.pending_drafts.contains_key(id)),
                "A selected conversation has a pending draft; nothing was deleted"
            );
            try_state(&self.engine)?.apply_native_thread_deletion(review)
        })();
        match result {
            Ok(undo) => {
                let deleted = undo.thread_ids();
                if self
                    .selected
                    .as_ref()
                    .and_then(|t| t["id"].as_str())
                    .is_some_and(|id| deleted.iter().any(|other| other.eq_ignore_ascii_case(id)))
                {
                    self.selected = None;
                    self.transcript_count = 0;
                    self.transcript_list.reset(0);
                    self.expanded.clear();
                    self.composer
                        .update(cx, |input, cx| input.set_value("", window, cx));
                    self.sync_workspace_context(cx);
                }
                self.archive_settings.status = format!(
                    "Deleted {} conversation(s). Undo is available until you quit or delete another batch.",
                    undo.count()
                );
                self.archive_settings.undo = Some(undo);
                self.archive_settings.picked.clear();
                self.refresh(cx);
                self.refresh_archive_settings(cx);
            }
            Err(error) => {
                self.archive_settings.status =
                    format!("Nothing was deleted: {error}. Review the selection again.");
                cx.notify();
            }
        }
    }
    fn restore_archive_selection(&mut self, cx: &mut Context<Self>) {
        self.archive_settings.review = None;
        let result = visible_selection(&self.archive_settings.rows, &self.archive_settings.picked)
            .and_then(|ids| restore(&self.engine, &ids));
        match result {
            Ok(()) => {
                self.archive_settings.status = "Conversations restored".into();
                self.archive_settings.picked.clear();
                self.refresh(cx);
                self.refresh_archive_settings(cx);
            }
            Err(error) => {
                self.archive_settings.status =
                    format!("Conversations could not be restored: {error}");
                cx.notify();
            }
        }
    }
    fn undo_archive_deletion(&mut self, cx: &mut Context<Self>) {
        self.archive_settings.review = None;
        let result = (|| -> Result<()> {
            let undo = self
                .archive_settings
                .undo
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("No deletion to undo"))?;
            try_state(&self.engine)?.undo_native_thread_deletion(undo)
        })();
        match result {
            Ok(()) => {
                self.archive_settings.undo = None;
                self.archive_settings.status =
                    "Deletion undone. Conversation content is restored.".into();
                self.refresh(cx);
                self.refresh_archive_settings(cx);
            }
            Err(error) => {
                self.archive_settings.status = format!("Deletion could not be undone: {error}");
                cx.notify();
            }
        }
    }
    pub(super) fn archive_settings_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        let state = &self.archive_settings;
        let mut filters = div().flex().flex_wrap().gap_1().child(
            Button::new("archive-all-projects")
                .label("All Projects")
                .when(state.project.is_none(), |b| b.primary())
                .on_click(cx.listener(|this, _, _, cx| {
                    this.archive_settings.project = None;
                    this.archive_settings.invalidate_filter();
                    this.refresh_archive_settings(cx);
                })),
        );
        for project in self.projects.iter().take(200) {
            let Some(id) = project["id"].as_str() else {
                continue;
            };
            let id = id.to_owned();
            let name = project["name"].as_str().unwrap_or("Project").to_owned();
            let selected = state.project.as_ref() == Some(&id);
            filters = filters.child(
                Button::new(SharedString::from(format!("archive-project-{id}")))
                    .label(name)
                    .when(selected, |b| b.primary())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.archive_settings.project = Some(id.clone());
                        this.archive_settings.invalidate_filter();
                        this.refresh_archive_settings(cx);
                    })),
            )
        }
        let mut list = div()
            .id("archive-settings-list")
            .max_h(px(420.))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_2();
        for row in &state.rows {
            let id = row.id.clone();
            let selected = state.picked.contains(&id);
            let open = id.clone();
            let title = if row.title.is_empty() {
                "Untitled conversation".to_owned()
            } else {
                row.title.clone()
            };
            list = list.child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(
                        Button::new(SharedString::from(format!("archive-pick-{id}")))
                            .label(if selected { "Selected" } else { "Select" })
                            .when(selected, |b| b.primary())
                            .disabled(state.review.is_some())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if !this.archive_settings.picked.remove(&id) {
                                    this.archive_settings.picked.insert(id.clone());
                                }
                                cx.notify();
                            })),
                    )
                    .child(div().flex_1().child(title))
                    .child(
                        Button::new(SharedString::from(format!("archive-open-{open}")))
                            .label("Open")
                            .disabled(state.review.is_some())
                            .on_click(cx.listener(move |this, _, _, cx| {
                                match call(&this.engine, "threads.open", json!({"threadId":open})) {
                                    Ok(_) => {
                                        this.archive_settings.status =
                                            "Opening conversation in the main window…".into()
                                    }
                                    Err(error) => {
                                        this.archive_settings.status =
                                            format!("Conversation could not be opened: {error}")
                                    }
                                };
                                cx.notify();
                            })),
                    ),
            );
        }
        if state.rows.is_empty() {
            list = list.child(if state.loaded {
                "No archived conversations match this filter."
            } else {
                "Refresh to load archived conversations."
            });
        }
        let mut pane = div()
            .flex()
            .flex_col()
            .gap_3()
            .child(div().text_lg().child("Archive"))
            .child(filters)
            .child(Input::new(&state.query))
            .child(
                Button::new("archive-refresh")
                    .label("Refresh")
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.archive_settings.review = None;
                        this.refresh_archive_settings(cx);
                    })),
            )
            .child(list)
            .child(format!(
                "{} archived conversation(s) · {} selected",
                state.total,
                state.picked.len()
            ))
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .child(
                        Button::new("archive-previous")
                            .label("Previous")
                            .disabled(state.offset == 0 || state.review.is_some())
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.archive_settings.offset =
                                    this.archive_settings.offset.saturating_sub(PAGE);
                                this.archive_settings.picked.clear();
                                this.refresh_archive_settings(cx);
                            })),
                    )
                    .child(
                        Button::new("archive-next")
                            .label("Next")
                            .disabled(state.offset + PAGE >= state.total || state.review.is_some())
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.archive_settings.offset += PAGE;
                                this.archive_settings.picked.clear();
                                this.refresh_archive_settings(cx);
                            })),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .child(
                        Button::new("archive-restore")
                            .label("Restore Selected")
                            .disabled(
                                !state.loaded || state.picked.is_empty() || state.review.is_some(),
                            )
                            .on_click(
                                cx.listener(|this, _, _, cx| this.restore_archive_selection(cx)),
                            ),
                    )
                    .child(
                        Button::new("archive-delete-review")
                            .label("Delete Selected…")
                            .disabled(
                                !state.loaded || state.picked.is_empty() || state.review.is_some(),
                            )
                            .on_click(
                                cx.listener(|this, _, _, cx| this.prepare_archive_deletion(cx)),
                            ),
                    )
                    .child(
                        Button::new("archive-undo-delete")
                            .label("Undo Delete")
                            .disabled(state.undo.is_none() || state.review.is_some())
                            .on_click(cx.listener(|this, _, _, cx| this.undo_archive_deletion(cx))),
                    ),
            );
        if let Some(review) = &state.review {
            let mut confirmation=div().flex().flex_col().gap_2().p_3().child(format!("Delete {} archived conversation(s)?",review.count())).child("This removes their local conversation content. Undo is available for this batch until Quit or the next deletion.");
            for title in review.titles() {
                confirmation = confirmation.child(title);
            }
            if state.undo.is_some() {
                confirmation =
                    confirmation.child("This deletion replaces the previous batch's Undo.");
            }
            pane = pane.child(
                confirmation.child(
                    div()
                        .flex()
                        .gap_2()
                        .child(
                            Button::new("archive-delete-cancel")
                                .label("Cancel")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.archive_settings.review = None;
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new("archive-delete-confirm")
                                .label("Delete Conversations")
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.confirm_archive_deletion(window, cx)
                                })),
                        ),
                ),
            );
        }
        pane.child(state.status.clone()).into_any_element()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn row(id: &str) -> ArchivedConversation {
        ArchivedConversation {
            id: id.into(),
            title: "Synthetic archived".into(),
            project_id: "project".into(),
            updated_at: 0.,
        }
    }
    #[::core::prelude::v1::test]
    fn selection_cannot_delete_an_unseen_or_unbounded_batch() {
        let rows = vec![row("one"), row("two")];
        assert!(visible_selection(&rows, &BTreeSet::new()).is_err());
        assert!(visible_selection(&rows, &BTreeSet::from(["unseen".into()])).is_err());
        assert_eq!(
            visible_selection(&rows, &BTreeSet::from(["two".into()])).unwrap(),
            vec!["two".to_owned()]
        );
        let too_many = (0..51).map(|n| n.to_string()).collect::<BTreeSet<_>>();
        assert!(visible_selection(&[], &too_many).is_err());
    }
    #[::core::prelude::v1::test]
    fn typed_native_delete_requires_review_and_undo_preserves_full_content() {
        let root =
            std::env::temp_dir().join(format!("coincide-archive-pane-{}", uuid::Uuid::new_v4()));
        coincide_core::native_file::private_directory(&root).unwrap();
        let mut store = coincide_core::store::Store::open(&root.join("state.sqlite")).unwrap();
        let mut thread = store.new_thread("").unwrap();
        thread["isArchived"] = json!(true);
        thread["draft"] = json!("Exact synthetic café draft\n");
        thread["future"] = json!({"opaque":7});
        store.save(&thread).unwrap();
        let id = thread["id"].as_str().unwrap().to_owned();
        let engine = Arc::new(std::sync::Mutex::new(coincide_core::api::Engine::new(
            store,
        )));
        // The UI adapter never waits on an owner already processing work.
        let held = try_state(&engine).unwrap();
        assert!(
            prepare_delete(&engine, std::slice::from_ref(&id))
                .err()
                .unwrap()
                .to_string()
                .contains("busy")
        );
        drop(held);
        let plan = prepare_delete(&engine, std::slice::from_ref(&id)).unwrap();
        assert_eq!(plan.count(), 1);
        assert!(try_state(&engine).unwrap().store.thread(&id).is_ok());
        let undo = try_state(&engine)
            .unwrap()
            .apply_native_thread_deletion(plan)
            .unwrap();
        assert!(try_state(&engine).unwrap().store.thread(&id).is_err());
        try_state(&engine)
            .unwrap()
            .undo_native_thread_deletion(&undo)
            .unwrap();
        assert_eq!(
            try_state(&engine).unwrap().store.thread(&id).unwrap(),
            thread
        );
        assert!(
            try_state(&engine)
                .unwrap()
                .undo_native_thread_deletion(&undo)
                .is_err()
        );
        restore(&engine, std::slice::from_ref(&id)).unwrap();
        let restored = try_state(&engine).unwrap().store.thread(&id).unwrap();
        let mut expected = thread.clone();
        expected["isArchived"] = json!(false);
        assert_eq!(restored, expected, "Restore changes only archived state");
        try_state(&engine)
            .unwrap()
            .store
            .close_for_shutdown()
            .unwrap();
        drop(engine);
        std::fs::remove_dir_all(root).unwrap();
    }
}
