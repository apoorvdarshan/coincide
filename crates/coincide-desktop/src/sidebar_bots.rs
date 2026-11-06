//! A bot is a navigation row, not a synthetic project conversation list.
//! Creating a conversation uses the saved Core bot validator, never UI drafts.
use super::*;
use gpui_kit::assets::IconName;
use gpui_kit::component::menu::{ContextMenuExt, PopupMenuItem};
#[derive(Clone)]
struct BotDrag(String);
impl Render for BotDrag {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().child("Move bot")
    }
}
impl Coincide {
    pub(super) fn sidebar_edit_bot(
        &mut self,
        id: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.open_settings_panel(window, cx);
        self.bots_open = true;
        self.bot_panel.update(cx, |panel, cx| {
            if let Some(id) = id {
                panel.select(id, cx);
            } else {
                panel.create(window, cx);
            }
        });
        self.sync_transcription_binding(cx);
        cx.notify();
    }
    pub(super) fn sidebar_open_bot(
        &mut self,
        id: String,
        fresh: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.thread_bulk.mode
            || self.sidebar_bot_pending.is_some()
            || self.media.shutdown_requested
            || self.media.close_requested
        {
            return;
        }
        let conversations = bot_conversations(&self.sidebar_all_threads, &id);
        let existing = if fresh {
            conversations.iter().find(|thread| {
                thread
                    .navigation
                    .as_ref()
                    .is_some_and(|meta| meta.item_count == Some(0) && meta.has_draft == Some(false))
            })
        } else {
            conversations.first()
        };
        if let Some(thread) = existing {
            let target = thread.id.clone();
            let reusable = !fresh
                || (!self.pending_drafts.contains_key(&target)
                    && !self.attachment_import_threads.contains(&target)
                    && call(&self.engine, "threads.read", json!({"threadId":target}))
                        .ok()
                        .is_some_and(|saved| {
                            saved["items"].as_array().is_some_and(Vec::is_empty)
                                && saved["draft"].as_str().is_none_or(str::is_empty)
                                && saved["draftContext"].as_array().is_none_or(Vec::is_empty)
                                && saved["rustDraftImages"]
                                    .as_array()
                                    .is_none_or(Vec::is_empty)
                        }));
            if reusable {
                self.created_bot_thread_to_focus = Some(target.clone());
                self.select(&target, window, cx);
                return;
            }
        }
        if !self.sidebar_bots.iter().any(|bot| {
            bot["id"]
                .as_str()
                .is_some_and(|stored| stored.eq_ignore_ascii_case(&id))
        }) {
            self.status = "This bot is no longer available.".into();
            cx.notify();
            return;
        }
        self.sidebar_bot_pending = Some(id.clone());
        let engine = self.engine.clone();
        let create = cx.background_executor().spawn(async move {
            let saved = call(&engine, "bots.read", json!({"botId":id}))?;
            call(
                &engine,
                "bots.conversations.create",
                json!({"botId":id,"baseline":saved["baseline"]}),
            )
        });
        let completion = cx.spawn_in(window, async move |this, cx| {
            let result = create.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.sidebar_bot_pending = None;
                if this.media.shutdown_requested || this.media.close_requested {
                    return;
                }
                match result {
                    Ok(reply) => {
                        this.refresh(cx);
                        let created = text(&reply, "threadId");
                        this.created_bot_thread_to_focus = Some(created.clone());
                        this.select(&created, window, cx);
                    }
                    Err(error) => {
                        this.status = format!("Bot conversation could not be opened: {error}")
                    }
                }
                cx.notify();
            });
        });
        self.navigation_tasks.push(completion);
        cx.notify();
    }
    fn sidebar_bot_matches(&self, bot: &Value, searching: bool, cx: &Context<Self>) -> bool {
        !searching
            || sidebar_search::terms_match(&text(bot, "name"), &self.search.read(cx).value())
            || self.threads.iter().any(|thread| {
                thread
                    .navigation
                    .as_ref()
                    .and_then(|meta| meta.bot_id.as_deref())
                    .is_some_and(|id| {
                        bot["id"]
                            .as_str()
                            .is_some_and(|known| known.eq_ignore_ascii_case(id))
                    })
            })
    }
    pub(super) fn has_sidebar_bot_rows(&self, searching: bool, cx: &Context<Self>) -> bool {
        self.sidebar_bots
            .iter()
            .any(|bot| self.sidebar_bot_matches(bot, searching, cx))
    }
    pub(super) fn sidebar_bot_rows(&self, searching: bool, cx: &mut Context<Self>) -> AnyElement {
        let mut bots: Vec<_> = self
            .sidebar_bots
            .iter()
            .filter(|bot| self.sidebar_bot_matches(bot, searching, cx))
            .collect();
        match self.sidebar_preferences.sort("botSort") {
            "name" => bots.sort_by(|left, right| {
                sidebar_preferences::name_order(&text(left, "name"), &text(right, "name"))
            }),
            "recentActivity" => bots.sort_by(|left, right| {
                let stamp = |bot: &Value| {
                    bot_conversations(&self.sidebar_all_threads, &text(bot, "id"))
                        .first()
                        .and_then(|thread| thread.navigation.as_ref()?.updated_at)
                        .unwrap_or(0.)
                };
                stamp(right).total_cmp(&stamp(left))
            }),
            _ => {}
        }
        let mut rows = div().flex().flex_col();
        for bot in bots {
            let id = text(bot, "id");
            let drag_id = id.clone();
            let drop_id = id.clone();
            let baseline = self.sidebar_bot_baseline.clone();
            let click_id = id.clone();
            let menu_id = id.clone();
            let conversations = bot_conversations(&self.sidebar_all_threads, &id);
            let latest = conversations.first();
            let selected = self
                .selected
                .as_ref()
                .and_then(|thread| thread["botID"].as_str())
                .is_some_and(|current| current.eq_ignore_ascii_case(&id));
            let name = bot["name"]
                .as_str()
                .filter(|name| !name.is_empty())
                .unwrap_or("Bot")
                .to_owned();
            let preview = latest
                .and_then(|thread| thread.navigation.as_ref()?.preview.clone())
                .unwrap_or_else(|| "Say hello".into());
            let running = conversations
                .iter()
                .any(|thread| self.running.contains(&thread.id));
            let age = navigation::sidebar_age(
                latest.and_then(|thread| thread.navigation.as_ref()?.updated_at),
                coincide_core::store::swift_timestamp(),
            );
            let active_schedules = self
                .sidebar_schedules
                .iter()
                .filter(|task| {
                    task["isPaused"] != true
                        && task["awaitingApproval"] != true
                        && conversations
                            .iter()
                            .any(|thread| task["threadID"] == thread.id)
                })
                .map(|task| text(task, "name"))
                .collect::<Vec<_>>();
            let parent = cx.entity().downgrade();
            let past = conversations
                .iter()
                .map(|thread| (thread.id.clone(), thread.title.clone()))
                .collect::<Vec<_>>();
            rows = rows.child(
                div()
                    .id(SharedString::from(format!("sidebar-bot-drag-{id}")))
                    .w_full()
                    .on_drag(BotDrag(drag_id), |drag, _, _, cx| cx.new(|_| drag.clone()))
                    .on_drop(cx.listener(move |this, drag: &BotDrag, _, cx| {
                        if !this.search.read(cx).value().trim().is_empty()
                            || this.thread_bulk.mode
                            || this.sidebar_bot_pending.is_some()
                            || this.media.close_requested
                            || this.media.shutdown_requested
                        {
                            return;
                        }
                        let mut ids: Vec<_> = this
                            .sidebar_bots
                            .iter()
                            .map(|bot| text(bot, "id"))
                            .collect();
                        if !ids.iter().any(|id| id.eq_ignore_ascii_case(&drag.0)) {
                            return;
                        }
                        ids.retain(|id| !id.eq_ignore_ascii_case(&drag.0));
                        let index = ids
                            .iter()
                            .position(|id| id.eq_ignore_ascii_case(&drop_id))
                            .unwrap_or(ids.len());
                        ids.insert(index, drag.0.clone());
                        let result = try_state(&this.engine)
                            .and_then(|mut engine| engine.reorder_native_bots(&ids, &baseline));
                        match result {
                            Ok(reply) => {
                                this.sidebar_bots =
                                    reply["bots"].as_array().cloned().unwrap_or_default();
                                this.sidebar_bot_baseline = text(&reply, "baseline");
                                this.sidebar_preference("choseBotSort", json!(true), cx);
                                this.sidebar_preference("botSort", json!("manual"), cx);
                            }
                            Err(error) => {
                                this.status = format!("Bots could not be reordered: {error}")
                            }
                        }
                        cx.notify();
                    }))
                    .child(
                        Button::new(SharedString::from(format!("sidebar-bot-{id}")))
                            .ghost()
                            .compact()
                            .w_full()
                            .h(px(44.))
                            .justify_start()
                            .selected(selected)
                            .disabled(self.sidebar_bot_pending.is_some())
                            .accessibility_label(format!("{name}, {preview}"))
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .w_full()
                                    .min_w_0()
                                    .child(IconName::Bot)
                                    .child(
                                        div()
                                            .flex()
                                            .flex_col()
                                            .min_w_0()
                                            .flex_1()
                                            .child(
                                                div()
                                                    .flex()
                                                    .items_center()
                                                    .justify_between()
                                                    .gap_1()
                                                    .child(
                                                        div()
                                                            .truncate()
                                                            .text_size(px(13.))
                                                            .child(name),
                                                    )
                                                    .child(div().text_size(px(11.)).child(age)),
                                            )
                                            .child(div().truncate().text_xs().child(preview)),
                                    )
                                    .when(running, |row| {
                                        row.child(
                                            gpui_kit::component::spinner::Spinner::new().small(),
                                        )
                                    })
                                    .when(!active_schedules.is_empty(), |row| {
                                        row.child(
                                            div()
                                                .id(SharedString::from(format!(
                                                    "sidebar-bot-clock-{id}"
                                                )))
                                                .child(IconName::Clock)
                                                .tooltip(move |window, cx| {
                                                    Tooltip::new(active_schedules.join("\n"))
                                                        .build(window, cx)
                                                }),
                                        )
                                    }),
                            )
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.sidebar_open_bot(click_id.clone(), false, window, cx)
                            }))
                            .context_menu(move |mut menu, _, _| {
                                let parent_new = parent.clone();
                                let id = menu_id.clone();
                                menu = menu.item(PopupMenuItem::new("New Conversation").on_click(
                                    move |_, window, cx| {
                                        let _ = parent_new.update(cx, |this, cx| {
                                            this.sidebar_open_bot(id.clone(), true, window, cx)
                                        });
                                    },
                                ));
                                for (thread, title) in &past {
                                    let parent = parent.clone();
                                    let thread = thread.clone();
                                    menu = menu.item(
                                        PopupMenuItem::new(format!("Past Conversation: {title}"))
                                            .on_click(move |_, window, cx| {
                                                let _ = parent.update(cx, |this, cx| {
                                                    this.select(&thread, window, cx)
                                                });
                                            }),
                                    );
                                }
                                if let Some((latest, _)) = past.first() {
                                    let parent = parent.clone();
                                    let latest = latest.clone();
                                    menu = menu.item(PopupMenuItem::new("Schedule…").on_click(
                                        move |_, window, cx| {
                                            let _ =
                                                parent.update(cx, |this, cx| {
                                                    this.select(&latest, window, cx);
                                                    if this.selected.as_ref().is_some_and(
                                                        |thread| thread["id"] == latest,
                                                    ) {
                                                        this.open_conversation_schedules(cx);
                                                        this.open_schedule_editor(None, window, cx);
                                                    }
                                                });
                                        },
                                    ));
                                }
                                let parent_edit = parent.clone();
                                let id = menu_id.clone();
                                menu.item(PopupMenuItem::new("Edit Bot…").on_click(
                                    move |_, window, cx| {
                                        let _ = parent_edit.update(cx, |this, cx| {
                                            this.sidebar_edit_bot(Some(id.clone()), window, cx)
                                        });
                                    },
                                ))
                            }),
                    ),
            );
        }
        rows.into_any_element()
    }
}
pub(super) fn bot_conversations<'a>(
    threads: &'a [ThreadSummary],
    bot: &str,
) -> Vec<&'a ThreadSummary> {
    let mut rows: Vec<_> = threads
        .iter()
        .filter(|thread| {
            !thread.archived
                && thread
                    .navigation
                    .as_ref()
                    .and_then(|meta| meta.bot_id.as_deref())
                    .is_some_and(|id| id.eq_ignore_ascii_case(bot))
        })
        .collect();
    rows.sort_by(|left, right| {
        right
            .navigation
            .as_ref()
            .and_then(|meta| meta.updated_at)
            .unwrap_or(0.)
            .total_cmp(
                &left
                    .navigation
                    .as_ref()
                    .and_then(|meta| meta.updated_at)
                    .unwrap_or(0.),
            )
            .then_with(|| left.id.cmp(&right.id))
    });
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn latest_bot_routing_ignores_pinning_archived_and_other_bots_and_handles_legacy_summaries() {
        let row = |id: &str, bot: Option<&str>, date: f64, archived: bool, pinned: bool| {
            serde_json::from_value::<ThreadSummary>(json!({"id":id,"title":id,"project_id":"bots","archived":archived,"pinned":pinned,"snoozed_until":null,"navigation":{"bot_id":bot,"updated_at":date}})).unwrap()
        };
        let rows = vec![
            row("old", Some("BOT"), 1., false, true),
            row("latest", Some("bot"), 5., false, false),
            row("archived", Some("BOT"), 9., true, false),
            row("other", Some("other"), 10., false, false),
            row("legacy", None, 20., false, false),
        ];
        assert_eq!(
            bot_conversations(&rows, "Bot")
                .iter()
                .map(|row| row.id.as_str())
                .collect::<Vec<_>>(),
            ["latest", "old"]
        );
    }
}
