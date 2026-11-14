//! Settings › Archive from Swift's ArchiveSettingsView: archived threads,
//! newest first, grouped by project and kept current as threads are archived
//! and deleted. Each row unarchives or deletes in one click; Delete follows
//! the confirmation setting, and Delete All…/Delete Shown… always asks.
//! Permanent deletion uses opaque Core plans/Undo; no deletion intent or
//! confirmation can be supplied through JSON settings.
use super::*;
use coincide_core::api::{PreparedThreadDeletion, ThreadDeletionUndo, ThreadFlagAction};
use coincide_core::store::ArchivedConversation;
const PAGE: usize = 50;
pub(super) struct ArchiveSettings {
    query: Entity<InputState>,
    rows: Vec<ArchivedConversation>,
    total: usize,
    offset: usize,
    /// The threads the pending review deletes.
    reviewing: Vec<String>,
    review: Option<PreparedThreadDeletion>,
    undo: Option<ThreadDeletionUndo>,
    status: String,
    loaded: bool,
}
impl ArchiveSettings {
    pub(super) fn new(window: &mut Window, cx: &mut Context<Coincide>) -> Self {
        Self {
            query: cx.new(|cx| InputState::new(window, cx).placeholder("Filter archived threads")),
            rows: Vec::new(),
            total: 0,
            offset: 0,
            reviewing: Vec::new(),
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
        self.close_review();
        self.offset = 0;
        self.rows.clear();
        self.loaded = false;
    }
    pub(super) fn close_review(&mut self) {
        self.review = None;
        self.reviewing.clear();
    }
}
/// Only threads shown, at most a page of them, can be deleted together.
fn visible_selection(rows: &[ArchivedConversation], ids: &[String]) -> Result<Vec<String>> {
    anyhow::ensure!(
        !ids.is_empty() && ids.len() <= PAGE,
        "Choose 1–50 archived threads"
    );
    anyhow::ensure!(
        ids.iter().all(|id| rows.iter().any(|row| &row.id == id)),
        "The archive changed; try again"
    );
    Ok(ids.to_vec())
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
/// Swift's named relative date: "now", "5 minutes ago", "yesterday", "last week".
fn last_active(updated: f64, now: f64) -> String {
    let seconds = if updated.is_finite() && now.is_finite() {
        (now - updated).max(0.)
    } else {
        0.
    };
    let ago =
        |count: u64, unit: &str| format!("{count} {unit}{} ago", if count == 1 { "" } else { "s" });
    let days = (seconds / 86_400.) as u64;
    match seconds as u64 {
        0 => "now".into(),
        n @ 1..60 => ago(n, "second"),
        n @ 60..3_600 => ago(n / 60, "minute"),
        n @ 3_600..86_400 => ago(n / 3_600, "hour"),
        _ if days == 1 => "yesterday".into(),
        _ if days < 7 => ago(days, "day"),
        _ if days < 14 => "last week".into(),
        _ if days < 30 => ago(days / 7, "week"),
        _ if days < 60 => "last month".into(),
        _ if days < 365 => ago(days / 30, "month"),
        _ if days < 730 => "last year".into(),
        _ => ago(days / 365, "year"),
    }
}
/// The page's threads grouped by project, groups ordered by their newest
/// thread; rows arrive newest first.
fn grouped<'a>(
    rows: &'a [ArchivedConversation],
    projects: &[Value],
) -> Vec<(String, Vec<&'a ArchivedConversation>)> {
    let mut groups: Vec<(String, Vec<&ArchivedConversation>)> = Vec::new();
    for row in rows {
        let project = if row.project_id.is_empty() {
            navigation::NO_PROJECT_ID
        } else {
            row.project_id.as_str()
        };
        match groups
            .iter_mut()
            .find(|(id, _)| id.eq_ignore_ascii_case(project))
        {
            Some((_, threads)) => threads.push(row),
            None => groups.push((project.to_owned(), vec![row])),
        }
    }
    groups
        .into_iter()
        .map(|(id, threads)| {
            let name = if id.eq_ignore_ascii_case(navigation::NO_PROJECT_ID) {
                "Chats".to_owned()
            } else if id.eq_ignore_ascii_case(coincide_core::bot_runtime::BOTS_PROJECT_ID) {
                "Bots".to_owned()
            } else {
                projects
                    .iter()
                    .find(|project| {
                        project["id"]
                            .as_str()
                            .is_some_and(|other| other.eq_ignore_ascii_case(&id))
                    })
                    .and_then(|project| project["name"].as_str())
                    .unwrap_or("Unavailable project")
                    .to_owned()
            };
            (name, threads)
        })
        .collect()
}
impl Coincide {
    pub(super) fn refresh_archive_settings(&mut self, cx: &mut Context<Self>) {
        let state = &self.archive_settings;
        let query = state.query.read(cx).value().to_string();
        let result = (|| -> Result<_> {
            let owner = try_state(&self.engine)?;
            anyhow::ensure!(!owner.admissions_frozen(), "App is closing");
            owner.native_archived_conversations_for_project(&query, None, state.offset, PAGE)
        })();
        match result {
            Ok(page) => {
                let state = &mut self.archive_settings;
                if page.rows.is_empty() && page.offset > 0 && page.total > 0 {
                    // Deleting the last thread of a later page shows the one before.
                    state.offset = (page.total - 1) / PAGE * PAGE;
                    return self.refresh_archive_settings(cx);
                }
                state.rows = page.rows;
                state.total = page.total;
                state.offset = page.offset;
                state.loaded = true;
                if !state
                    .reviewing
                    .iter()
                    .all(|id| state.rows.iter().any(|row| &row.id == id))
                {
                    state.close_review();
                }
            }
            Err(error) => {
                // Keep showing the last rows; a busy engine retries on the next change.
                if !engine_busy(&error) {
                    self.archive_settings.loaded = false;
                    self.archive_settings.status = format!("Archive could not be loaded: {error}");
                }
            }
        }
        cx.notify();
    }
    /// Delete for one row, or every row shown. One thread follows the
    /// confirmation setting unless it is running; several always ask.
    fn delete_archived(
        &mut self,
        ids: Vec<String>,
        always_confirm: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let result = (|| -> Result<_> {
            anyhow::ensure!(self.archive_settings.loaded, "The archive is still loading");
            let ids = visible_selection(&self.archive_settings.rows, &ids)?;
            anyhow::ensure!(
                !ids.iter().any(|id| self.pending_drafts.contains_key(id)),
                "Save this thread's pending draft before deleting it"
            );
            Ok((prepare_delete(&self.engine, &ids)?, ids))
        })();
        match result {
            Ok((review, ids)) => {
                let running = ids.iter().any(|id| {
                    self.running
                        .iter()
                        .any(|other| other.eq_ignore_ascii_case(id))
                });
                let confirm = always_confirm
                    || running
                    || self.settings["confirmBeforeDeletingThreads"]
                        .as_bool()
                        .unwrap_or(true);
                self.archive_settings.status.clear();
                self.archive_settings.review = Some(review);
                self.archive_settings.reviewing = ids;
                if !confirm {
                    return self.confirm_archive_deletion(window, cx);
                }
            }
            Err(error) => self.archive_settings.status = format!("Nothing was deleted: {error}"),
        };
        cx.notify();
    }
    fn confirm_archive_deletion(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(review) = self.archive_settings.review.take() else {
            return;
        };
        let ids = std::mem::take(&mut self.archive_settings.reviewing);
        let result = (|| -> Result<_> {
            anyhow::ensure!(
                !ids.iter().any(|id| self.pending_drafts.contains_key(id)),
                "A thread has a pending draft"
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
                    self.replace_selected_thread(None);
                    self.transcript_count = 0;
                    self.transcript_list.reset(0);
                    self.expanded.clear();
                    self.composer
                        .update(cx, |input, cx| input.set_value("", window, cx));
                    self.sync_workspace_context(cx);
                }
                self.archive_settings.status = match undo.count() {
                    1 => "Deleted 1 thread. You can undo this until Coincide quits or you delete again.".into(),
                    count => format!("Deleted {count} threads. You can undo this until Coincide quits or you delete again."),
                };
                self.archive_settings.undo = Some(undo);
                self.refresh(cx);
                self.refresh_archive_settings(cx);
            }
            Err(error) => {
                self.archive_settings.status = format!("Nothing was deleted: {error}");
                cx.notify();
            }
        }
    }
    fn unarchive(&mut self, id: String, cx: &mut Context<Self>) {
        self.archive_settings.close_review();
        match restore(&self.engine, std::slice::from_ref(&id)) {
            Ok(()) => {
                self.archive_settings.status.clear();
                self.refresh(cx);
                self.refresh_archive_settings(cx);
            }
            Err(error) => {
                self.archive_settings.status =
                    format!("The thread could not be unarchived: {error}");
                cx.notify();
            }
        }
    }
    fn undo_archive_deletion(&mut self, cx: &mut Context<Self>) {
        self.archive_settings.close_review();
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
                self.archive_settings.status = "Deletion undone.".into();
                self.refresh(cx);
                self.refresh_archive_settings(cx);
            }
            Err(error) => {
                self.archive_settings.status = format!("Deletion could not be undone: {error}");
                cx.notify();
            }
        }
    }
    fn archive_review(
        &self,
        review: &PreparedThreadDeletion,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = &self.archive_settings;
        let title = match (review.count(), review.titles().first()) {
            (1, Some(title)) => format!("Delete “{title}”?"),
            (count, _) => format!("Delete Threads ({count})?"),
        };
        let running = state.reviewing.iter().any(|id| {
            self.running
                .iter()
                .any(|other| other.eq_ignore_ascii_case(id))
        });
        let mut text = String::from(
            "You can undo this deletion until Coincide quits or you delete again. Files in your project are not changed.",
        );
        if running {
            text.push_str("\n\nRunning agents in these threads will stop. Undo restores conversations, but does not restart stopped work.");
        }
        if state.undo.is_some() {
            text.push_str("\n\nThis replaces Undo for the previous deletion.");
        }
        div()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .rounded_md()
            .border_1()
            .border_color(self.color(0x29303d))
            .child(div().font_weight(FontWeight::SEMIBOLD).child(title))
            .child(div().text_sm().child(text))
            .child(
                div()
                    .flex()
                    .justify_end()
                    .gap_2()
                    .child(
                        Button::new("archive-delete-cancel")
                            .label("Cancel")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.archive_settings.close_review();
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("archive-delete-confirm")
                            .label("Delete")
                            .danger()
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.confirm_archive_deletion(window, cx)
                            })),
                    ),
            )
            .into_any_element()
    }
    pub(super) fn archive_settings_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        let state = &self.archive_settings;
        let filtering = !state.query.read(cx).value().trim().is_empty();
        let reviewing = state.review.is_some();
        let shown = state
            .rows
            .iter()
            .map(|row| row.id.clone())
            .collect::<Vec<_>>();
        let mut pane = div()
            .flex()
            .flex_col()
            .gap_3()
            .child(div().text_sm().text_color(self.color(0x98a6ba).opacity(0.8)).child(
                "Threads you archive with a thread's archive button wait here. Unarchive one to bring it back to the sidebar.",
            ))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1().child(Input::new(&state.query)))
                    .child(
                        Button::new("archive-delete-all")
                            .label(if filtering { "Delete Shown…" } else { "Delete All…" })
                            .danger()
                            .disabled(state.rows.is_empty() || reviewing)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.delete_archived(shown.clone(), true, window, cx)
                            })),
                    ),
            );
        if let Some(review) = &state.review {
            pane = pane.child(self.archive_review(review, cx));
        }
        if state.rows.is_empty() {
            let query = state.query.read(cx).value().trim().to_owned();
            pane = pane.child(
                div()
                    .p_4()
                    .flex()
                    .justify_center()
                    .text_color(self.color(0x98a6ba).opacity(0.8))
                    .child(if !state.loaded {
                        "Loading archived threads…".to_owned()
                    } else if filtering {
                        format!("No Results for “{query}”")
                    } else {
                        "No Archived Threads".to_owned()
                    }),
            );
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0., |elapsed| elapsed.as_secs_f64());
        for (project, threads) in grouped(&state.rows, &self.projects) {
            let mut group = div()
                .flex()
                .flex_col()
                .rounded(px(10.))
                .border_1()
                .border_color(self.color(0x29303d))
                .bg(self.color(0x111722));
            for (index, row) in threads.into_iter().enumerate() {
                let id = row.id.clone();
                let delete = row.id.clone();
                let title = if row.title.is_empty() {
                    "Untitled conversation".to_owned()
                } else {
                    row.title.clone()
                };
                group = group.child(
                    div()
                        .flex()
                        .items_center()
                        .gap_2()
                        .p_3()
                        .when(index > 0, |row| {
                            row.border_t_1().border_color(self.color(0x29303d))
                        })
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .child(div().truncate().child(title))
                                .child(
                                    div()
                                        .text_xs()
                                        .truncate()
                                        .text_color(self.color(0x98a6ba).opacity(0.7))
                                        .child(format!(
                                            "Last active {}",
                                            last_active(row.updated_at, now)
                                        )),
                                ),
                        )
                        .child(
                            Button::new(SharedString::from(format!("archive-unarchive-{id}")))
                                .label("Unarchive")
                                .disabled(reviewing)
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.unarchive(id.clone(), cx)
                                })),
                        )
                        .child(
                            Button::new(SharedString::from(format!("archive-delete-{delete}")))
                                .label("Delete")
                                .danger()
                                .disabled(reviewing)
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.delete_archived(vec![delete.clone()], false, window, cx)
                                })),
                        ),
                );
            }
            pane = pane.child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_sm()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(project),
                    )
                    .child(group),
            );
        }
        if state.total > PAGE {
            pane = pane.child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1().text_sm().child(format!(
                        "Showing {}–{} of {} archived threads",
                        state.offset + 1,
                        state.offset + state.rows.len(),
                        state.total
                    )))
                    .child(
                        Button::new("archive-previous")
                            .label("Previous")
                            .disabled(state.offset == 0 || reviewing)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.archive_settings.offset =
                                    this.archive_settings.offset.saturating_sub(PAGE);
                                this.refresh_archive_settings(cx);
                            })),
                    )
                    .child(
                        Button::new("archive-next")
                            .label("Next")
                            .disabled(state.offset + PAGE >= state.total || reviewing)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.archive_settings.offset += PAGE;
                                this.refresh_archive_settings(cx);
                            })),
                    ),
            );
        }
        if state.undo.is_some() || !state.status.is_empty() {
            pane = pane.child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child(div().flex_1().text_sm().child(state.status.clone()))
                    .when(state.undo.is_some(), |row| {
                        row.child(
                            Button::new("archive-undo-delete")
                                .label("Undo Delete")
                                .disabled(reviewing)
                                .on_click(
                                    cx.listener(|this, _, _, cx| this.undo_archive_deletion(cx)),
                                ),
                        )
                    }),
            );
        }
        pane.into_any_element()
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
        assert!(visible_selection(&rows, &[]).is_err());
        assert!(visible_selection(&rows, &["unseen".into()]).is_err());
        assert_eq!(
            visible_selection(&rows, &["two".into()]).unwrap(),
            vec!["two".to_owned()]
        );
        let too_many = (0..51).map(|n| n.to_string()).collect::<Vec<_>>();
        assert!(visible_selection(&[], &too_many).is_err());
    }
    #[::core::prelude::v1::test]
    fn last_active_reads_like_named_relative_dates() {
        let now = 1_000_000_000.;
        assert_eq!(last_active(now, now), "now");
        assert_eq!(last_active(now + 30., now), "now");
        assert_eq!(last_active(now - 1., now), "1 second ago");
        assert_eq!(last_active(now - 125., now), "2 minutes ago");
        assert_eq!(last_active(now - 3. * 3_600., now), "3 hours ago");
        assert_eq!(last_active(now - 30. * 3_600., now), "yesterday");
        assert_eq!(last_active(now - 3. * 86_400., now), "3 days ago");
        assert_eq!(last_active(now - 8. * 86_400., now), "last week");
        assert_eq!(last_active(now - 21. * 86_400., now), "3 weeks ago");
        assert_eq!(last_active(now - 40. * 86_400., now), "last month");
        assert_eq!(last_active(now - 100. * 86_400., now), "3 months ago");
        assert_eq!(last_active(now - 400. * 86_400., now), "last year");
        assert_eq!(last_active(now - 800. * 86_400., now), "2 years ago");
        assert_eq!(last_active(f64::NAN, now), "now");
    }
    #[::core::prelude::v1::test]
    fn rows_group_by_project_in_newest_first_order() {
        let project = "6F1C6C8A-7C51-4F7E-9A55-0D7E0D7F0A01";
        let mut first = row("one");
        first.project_id = project.into();
        let mut chat = row("two");
        chat.project_id = String::new();
        let mut second = row("three");
        second.project_id = project.to_lowercase();
        let rows = [first, chat, second];
        let projects = [json!({"id":project,"name":"Coincide"})];
        let groups = grouped(&rows, &projects)
            .into_iter()
            .map(|(name, threads)| {
                (
                    name,
                    threads.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(),
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(
            groups,
            [
                ("Coincide".to_owned(), vec!["one", "three"]),
                ("Chats".to_owned(), vec!["two"]),
            ]
        );
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
