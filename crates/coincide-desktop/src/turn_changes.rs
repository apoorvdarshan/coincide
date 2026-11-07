//! The changed-files card under each turn that changed files (Swift
//! TranscriptChangedFilesCell). Up to six files with their status and line
//! counts, then "N more files…"; a file or View Diff opens that turn's diff in
//! the Git workspace inspector. Files come from the Core's per-turn checkpoints.
use super::*;
use coincide_core::turn_checkpoints::{ChangedFile, FileStatus};
use gpui_kit::assets::IconName;

const VISIBLE_FILES: usize = 6;

#[derive(Default)]
pub(super) struct TurnChanges {
    thread: Option<String>,
    /// Files by the user message that opened each finished turn.
    files: std::collections::HashMap<String, Vec<ChangedFile>>,
    /// Imported conversations stay read-only until cutover, so their
    /// messages edit in a new branch instead of rewinding in place.
    imported: bool,
}
impl TurnChanges {
    pub(super) fn rewinds_in_place(&self, thread: &str) -> bool {
        self.thread.as_deref() == Some(thread) && !self.imported
    }
}

/// Rows the card shows: up to six files, plus a "more" row past seven, so a
/// seventh file never hides behind "1 more file".
pub(super) fn shown_rows(files: usize) -> (usize, Option<usize>) {
    if files <= VISIBLE_FILES + 1 {
        (files, None)
    } else {
        (VISIBLE_FILES, Some(files - VISIBLE_FILES))
    }
}

pub(super) fn title(files: usize) -> String {
    if files == 1 {
        "1 changed file".into()
    } else {
        format!("{files} changed files")
    }
}

/// "+3 −1": additions show even at zero when nothing was deleted.
pub(super) fn stats(additions: u64, deletions: u64) -> (Option<String>, Option<String>) {
    (
        (additions > 0 || deletions == 0).then(|| format!("+{additions}")),
        (deletions > 0).then(|| format!("−{deletions}")),
    )
}

/// Which item of a turn carries its card: the turn's last reply, else its
/// last row that is not a notice or reasoning, and the user message that
/// opened the turn.
pub(super) fn anchor(items: &[Value], index: usize) -> Option<(usize, String)> {
    let opens = |item: &Value| item["kind"] == "user" && item["steered"] != true;
    let opener = (0..=index.min(items.len().checked_sub(1)?))
        .rev()
        .find(|position| opens(&items[*position]))?;
    let end = (opener + 1..items.len())
        .find(|position| opens(&items[*position]))
        .unwrap_or(items.len());
    let turn = opener..end;
    let anchor = turn
        .clone()
        .rev()
        .find(|position| items[*position]["kind"] == "assistant")
        .or_else(|| {
            turn.rev().find(|position| {
                !matches!(
                    items[*position]["kind"].as_str(),
                    Some("notice" | "reasoning")
                )
            })
        })?;
    Some((anchor, items[opener]["id"].as_str()?.to_owned()))
}

impl Coincide {
    /// Reloads the selected thread's turn changes; cheap, so every revision.
    pub(super) fn refresh_turn_changes(&mut self) {
        let Some(id) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            self.turn_changes = TurnChanges::default();
            return;
        };
        let Ok(reply) = call(&self.engine, "checkpoints.list", json!({"threadId":id})) else {
            // Busy or unavailable: keep what is shown until the next revision.
            if self.turn_changes.thread.as_deref() != Some(id.as_str()) {
                self.turn_changes = TurnChanges::default();
            }
            return;
        };
        let imported = try_state(&self.engine)
            .ok()
            .and_then(|engine| engine.store.is_imported(&id).ok());
        let imported = match imported {
            Some(imported) => imported,
            None if self.turn_changes.thread.as_deref() == Some(id.as_str()) => {
                self.turn_changes.imported
            }
            // Unknown: keep the conservative separate-branch edit.
            None => true,
        };
        let files: std::collections::HashMap<String, Vec<ChangedFile>> = reply["turns"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|turn| turn["complete"] == true && turn["running"] != true)
            .filter_map(|turn| {
                let files: Vec<ChangedFile> = serde_json::from_value(turn["files"].clone()).ok()?;
                (!files.is_empty()).then(|| (text(turn, "userItemID"), files))
            })
            .collect();
        let previous = std::mem::take(&mut self.turn_changes);
        let same_thread = previous.thread.as_deref() == Some(id.as_str());
        // The virtualized list keeps measured row heights, so rows whose card
        // appeared, changed or went away are measured again.
        if same_thread
            && let Some(items) = self.selected.as_ref().and_then(|v| v["items"].as_array())
        {
            let changed = files
                .iter()
                .filter(|(turn, files)| previous.files.get(*turn) != Some(*files))
                .map(|(turn, _)| turn)
                .chain(
                    previous
                        .files
                        .keys()
                        .filter(|turn| !files.contains_key(*turn)),
                );
            let mut rows = changed
                .filter_map(|turn| {
                    let opener = items.iter().position(|item| item["id"] == turn.as_str())?;
                    anchor(items, opener).map(|(row, _)| row)
                })
                .filter(|row| *row < self.transcript_count)
                .collect::<Vec<_>>();
            rows.sort_unstable();
            rows.dedup();
            for row in rows {
                self.transcript_list.splice(row..row + 1, 1);
            }
        }
        self.turn_changes = TurnChanges {
            thread: Some(id),
            files,
            imported,
        };
    }

    /// The row for `index`, followed by its turn's changed-files card when
    /// the row anchors one.
    pub(super) fn with_turn_changes(
        &mut self,
        index: usize,
        row: AnyElement,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(card) = self.changed_files_card(index, cx) else {
            return row;
        };
        div()
            .flex()
            .flex_col()
            .w_full()
            .child(row)
            .child(
                div()
                    .flex()
                    .w_full()
                    .px(px(presentation::CONTENT_GUTTER))
                    .justify_center()
                    .child(
                        div()
                            .w_full()
                            .min_w_0()
                            .max_w(px(presentation::CONTENT_WIDTH))
                            .pl(px(presentation::RAIL_GUTTER))
                            .child(card),
                    ),
            )
            .into_any_element()
    }

    fn changed_files_card(&mut self, index: usize, cx: &mut Context<Self>) -> Option<AnyElement> {
        let thread = self.selected.as_ref()?;
        let thread_id = text(thread, "id");
        if self.turn_changes.thread.as_deref() != Some(thread_id.as_str()) {
            return None;
        }
        let (anchor, turn) = anchor(thread["items"].as_array()?, index)?;
        if anchor != index {
            return None;
        }
        let files = self.turn_changes.files.get(&turn)?.clone();
        let (additions, deletions) = files.iter().fold((0, 0), |(a, d), file| {
            (a + file.additions, d + file.deletions)
        });
        let (shown, more) = shown_rows(files.len());
        let secondary = self.color(0xe4e9f2).opacity(0.6);
        let header = div()
            .flex()
            .items_center()
            .gap_2()
            .h(px(24.))
            .pl_1()
            .child(div().font_semibold().text_sm().child(title(files.len())))
            .child(self.line_stats(additions, deletions))
            .child(div().flex_1())
            .child({
                let turn = turn.clone();
                Button::new(SharedString::from(format!("turn-diff-{turn}")))
                    .accessibility_id(SharedString::from(format!("turn-diff-{turn}")))
                    .icon(IconName::Diff)
                    .label("View Diff")
                    .ghost()
                    .compact()
                    .xsmall()
                    .text_color(secondary)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.show_turn_diff(&turn, None, window, cx)
                    }))
            });
        let rows = files
            .iter()
            .take(shown)
            .enumerate()
            .map(|(position, file)| {
                let (icon, color) = match file.status {
                    FileStatus::Added | FileStatus::Untracked => (IconName::SquarePlus, 0x34c759),
                    FileStatus::Deleted => (IconName::SquareMinus, 0xff453a),
                    FileStatus::Renamed => (IconName::SquareArrowRight, 0x0a84ff),
                    FileStatus::Modified => (IconName::SquarePen, 0xff9f0a),
                };
                let label = match &file.old_path {
                    Some(old) => format!("{old} → {}", file.path),
                    None => file.path.clone(),
                };
                let turn = turn.clone();
                let path = file.path.clone();
                div()
                    .id(SharedString::from(format!("turn-file-{turn}-{position}")))
                    .role(Role::Button)
                    .aria_label(SharedString::from(format!(
                        "{}, {} additions, {} deletions",
                        file.path, file.additions, file.deletions
                    )))
                    .tooltip({
                        let path = file.path.clone();
                        move |window, cx| {
                            gpui_kit::component::tooltip::Tooltip::new(path.clone())
                                .build(window, cx)
                        }
                    })
                    .flex()
                    .items_center()
                    .gap_2()
                    .h(px(24.))
                    .px(px(6.))
                    .rounded(px(5.))
                    .cursor_pointer()
                    .hover(|row| row.bg(self.color(0xe4e9f2).opacity(0.06)))
                    .child(div().text_color(rgb(color)).child(Icon::new(icon).xsmall()))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_xs()
                            .font_family("monospace")
                            .child(label),
                    )
                    .child(self.line_stats(file.additions, file.deletions))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.show_turn_diff(&turn, Some(&path), window, cx)
                    }))
                    .into_any_element()
            });
        let more = more.map(|count| {
            let turn = turn.clone();
            div()
                .id(SharedString::from(format!("turn-more-{turn}")))
                .role(Role::Button)
                .aria_label(SharedString::from(format!("{count} more files…")))
                .flex()
                .items_center()
                .h(px(24.))
                .px_2()
                .rounded(px(5.))
                .cursor_pointer()
                .hover(|row| row.bg(self.color(0xe4e9f2).opacity(0.06)))
                .text_xs()
                .font_weight(FontWeight::MEDIUM)
                .text_color(secondary)
                .child(format!("{count} more files…"))
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.show_turn_diff(&turn, None, window, cx)
                }))
                .into_any_element()
        });
        Some(
            div()
                .id(SharedString::from(format!("turn-changes-{turn}")))
                .role(Role::Group)
                .aria_label(SharedString::from(title(files.len())))
                .w_full()
                .mb_3()
                .p(px(10.))
                .flex()
                .flex_col()
                .gap_1()
                .rounded(px(12.))
                .bg(self.color(0x181d28))
                .border_1()
                .border_color(self.color(0x29303d))
                .child(header)
                .children(rows)
                .children(more)
                .into_any_element(),
        )
    }

    fn line_stats(&self, additions: u64, deletions: u64) -> AnyElement {
        let (added, deleted) = stats(additions, deletions);
        div()
            .flex()
            .gap_1()
            .text_xs()
            .font_weight(FontWeight::MEDIUM)
            .when_some(added, |view, added| {
                view.child(div().text_color(rgb(0x34c759)).child(added))
            })
            .when_some(deleted, |view, deleted| {
                view.child(div().text_color(rgb(0xff453a)).child(deleted))
            })
            .into_any_element()
    }

    /// Opens a turn's diff, or one file's, in the Git workspace inspector.
    pub(super) fn show_turn_diff(
        &mut self,
        turn: &str,
        path: Option<&str>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(thread) = self.selected.as_ref().map(|thread| text(thread, "id")) else {
            return;
        };
        let mut params = json!({"threadId":thread,"userItemId":turn});
        if let Some(path) = path {
            params["path"] = json!(path);
        }
        match call(&self.engine, "checkpoints.diff", params) {
            Ok(reply) => {
                let mut notice = match path {
                    Some(path) => format!("Changes to {path} in this turn"),
                    None => "Changes in this turn".to_owned(),
                };
                if reply["truncated"] == true {
                    notice.push_str(" · The diff is too long to show in full.");
                }
                let diff = text(&reply, "diff");
                // Settle the panel's binding first; a later rebinding clears it.
                self.sync_workspace_context(cx);
                self.workspace_panel
                    .update(cx, |panel, cx| panel.show_diff(notice, diff, cx));
                self.clear_inspector_placeholders();
                self.session_import_open = false;
                if !self.workspace_open {
                    self.workspace_open = true;
                    self.ensure_inspector_space(window);
                    self.hide_selected_browser_surface(cx);
                    if self.terminal_on_right() {
                        self.terminal_open = false;
                    }
                    self.close_schedule_surface();
                }
                self.settings_open = false;
                self.sync_transcription_binding(cx);
                self.remember_current_inspector(cx);
            }
            Err(error) => self.status = format!("Could not read the turn's changes: {error}"),
        }
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn six_files_then_more_but_never_one_more() {
        assert_eq!(shown_rows(1), (1, None));
        assert_eq!(shown_rows(6), (6, None));
        assert_eq!(shown_rows(7), (7, None));
        assert_eq!(shown_rows(8), (6, Some(2)));
        assert_eq!(title(1), "1 changed file");
        assert_eq!(title(3), "3 changed files");
    }

    #[::core::prelude::v1::test]
    fn stats_match_swift() {
        assert_eq!(stats(3, 1), (Some("+3".into()), Some("−1".into())));
        assert_eq!(stats(0, 0), (Some("+0".into()), None));
        assert_eq!(stats(0, 2), (None, Some("−2".into())));
    }

    #[::core::prelude::v1::test]
    fn the_card_follows_the_turns_last_reply() {
        let items = json!([
            {"id":"u1","kind":"user"},
            {"id":"t1","kind":"tool"},
            {"id":"a1","kind":"assistant"},
            {"id":"n1","kind":"notice"},
            {"id":"s","kind":"user","steered":true},
            {"id":"a2","kind":"assistant"},
            {"id":"u2","kind":"user"},
            {"id":"t2","kind":"tool"},
            {"id":"n2","kind":"notice"},
        ]);
        let items = items.as_array().unwrap();
        // A steered message stays in its turn, so its later reply anchors.
        for index in 0..6 {
            assert_eq!(anchor(items, index), Some((5, "u1".into())), "{index}");
        }
        // Without a reply, the last row that is not a notice anchors.
        assert_eq!(anchor(items, 8), Some((7, "u2".into())));
        assert_eq!(anchor(&items[1..3], 1), None);
        assert_eq!(anchor(&[], 0), None);
    }
}
